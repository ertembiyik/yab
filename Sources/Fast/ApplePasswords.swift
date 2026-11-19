import AppKit
import CryptoKit
import Foundation
import Security
import SwiftUI
import os

// Apple Passwords without its extension: Yab talks to the helper the iCloud
// Passwords extension talks to (PasswordManagerBrowserExtensionHelper), so
// its logins come up in Yab's own list under a sign-in box, fill with the
// helper's Touch ID, and a new sign-in is kept in Passwords. The protocol,
// read from the extension's own code and two open clients, is in
// docs/evidence/apple-passwords-helper-protocol-2026-10-27.md: SRP with the
// code Passwords shows in its own window, once a helper process, then
// AES-GCM. macOS lets the helper run only under Yab signed with Apple's
// browser entitlement (dev.serafim.fast); a dev build is killed as it starts.

// MARK: - big numbers, as much as SRP's 3072-bit group needs

/// A whole number of any size, little-endian 32-bit digits. Only what SRP
/// takes: bytes in and out, +, −, ×, mod and a power mod N.
struct SRPNumber: Comparable {
    fileprivate var digits: [UInt32]

    init(_ value: UInt32) { digits = value == 0 ? [] : [value] }

    /// From big-endian bytes.
    init(_ bytes: [UInt8]) {
        var out: [UInt32] = []
        var end = bytes.count
        while end > 0 {
            let start = max(0, end - 4)
            var word: UInt32 = 0
            for byte in bytes[start..<end] { word = word << 8 | UInt32(byte) }
            out.append(word)
            end = start
        }
        digits = out
        trim()
    }

    init(hex: String) {
        var bytes: [UInt8] = []
        var text = Substring(hex)
        if text.count % 2 == 1 { text = "0" + text }
        while !text.isEmpty {
            bytes.append(UInt8(text.prefix(2), radix: 16) ?? 0)
            text = text.dropFirst(2)
        }
        self.init(bytes)
    }

    private init(digits: [UInt32]) {
        self.digits = digits
        trim()
    }

    private mutating func trim() {
        while digits.last == 0 { digits.removeLast() }
    }

    var isZero: Bool { digits.isEmpty }

    /// Big-endian, no leading zero bytes (sjcl's toBits).
    var bytes: [UInt8] {
        var out: [UInt8] = []
        for word in digits.reversed() {
            out += [UInt8(word >> 24), UInt8(word >> 16 & 0xff), UInt8(word >> 8 & 0xff), UInt8(word & 0xff)]
        }
        return Array(out.drop { $0 == 0 })
    }

    /// Left-padded with zeros to `length` bytes.
    func padded(_ length: Int) -> [UInt8] {
        let plain = bytes
        return [UInt8](repeating: 0, count: max(0, length - plain.count)) + plain
    }

    static func < (a: SRPNumber, b: SRPNumber) -> Bool {
        if a.digits.count != b.digits.count { return a.digits.count < b.digits.count }
        for i in stride(from: a.digits.count - 1, through: 0, by: -1) where a.digits[i] != b.digits[i] {
            return a.digits[i] < b.digits[i]
        }
        return false
    }

    static func + (a: SRPNumber, b: SRPNumber) -> SRPNumber {
        var out = [UInt32](repeating: 0, count: max(a.digits.count, b.digits.count) + 1)
        var carry: UInt64 = 0
        for i in 0..<(out.count - 1) {
            let sum = UInt64(i < a.digits.count ? a.digits[i] : 0) + UInt64(i < b.digits.count ? b.digits[i] : 0) + carry
            out[i] = UInt32(truncatingIfNeeded: sum)
            carry = sum >> 32
        }
        out[out.count - 1] = UInt32(carry)
        return SRPNumber(digits: out)
    }

    /// a − b, for a ≥ b.
    static func - (a: SRPNumber, b: SRPNumber) -> SRPNumber {
        precondition(!(a < b), "SRPNumber subtraction below zero")
        var out = a.digits
        var borrow: Int64 = 0
        for i in 0..<out.count {
            let difference = Int64(out[i]) - Int64(i < b.digits.count ? b.digits[i] : 0) - borrow
            out[i] = UInt32(truncatingIfNeeded: difference)
            borrow = difference < 0 ? 1 : 0
        }
        return SRPNumber(digits: out)
    }

    static func * (a: SRPNumber, b: SRPNumber) -> SRPNumber {
        guard !a.isZero, !b.isZero else { return SRPNumber(0) }
        var out = [UInt32](repeating: 0, count: a.digits.count + b.digits.count)
        for i in 0..<a.digits.count {
            var carry: UInt64 = 0
            let x = UInt64(a.digits[i])
            for j in 0..<b.digits.count {
                let product = x * UInt64(b.digits[j]) + UInt64(out[i + j]) + carry
                out[i + j] = UInt32(truncatingIfNeeded: product)
                carry = product >> 32
            }
            out[i + b.digits.count] = UInt32(carry)
        }
        return SRPNumber(digits: out)
    }

    private func shifted(left bits: Int) -> [UInt32] {
        guard bits > 0 else { return digits }
        var out = [UInt32](repeating: 0, count: digits.count + 1)
        for i in 0..<digits.count {
            out[i] |= digits[i] << bits
            out[i + 1] = digits[i] >> (32 - bits)
        }
        return out
    }

    /// a mod m (Knuth's algorithm D, as Hacker's Delight writes it).
    static func % (a: SRPNumber, m: SRPNumber) -> SRPNumber {
        precondition(!m.isZero, "SRPNumber mod zero")
        if a < m { return a }
        if m.digits.count == 1 {
            var rest: UInt64 = 0
            let d = UInt64(m.digits[0])
            for word in a.digits.reversed() { rest = (rest << 32 | UInt64(word)) % d }
            return SRPNumber(UInt32(rest))
        }
        let shift = m.digits.last!.leadingZeroBitCount
        var v = m.shifted(left: shift)
        if v.last == 0 { v.removeLast() }
        let n = v.count
        var u = a.shifted(left: shift)
        if u.count == a.digits.count { u.append(0) }
        let base: UInt64 = 1 << 32
        for j in stride(from: u.count - n - 1, through: 0, by: -1) {
            let top = UInt64(u[j + n]) << 32 | UInt64(u[j + n - 1])
            var q = top / UInt64(v[n - 1])
            var r = top % UInt64(v[n - 1])
            while q >= base || q * UInt64(v[n - 2]) > (r << 32 | UInt64(u[j + n - 2])) {
                q -= 1
                r += UInt64(v[n - 1])
                if r >= base { break }
            }
            var k: Int64 = 0
            for i in 0..<n {
                let product = q * UInt64(v[i])
                let t = Int64(u[i + j]) - k - Int64(product & 0xffff_ffff)
                u[i + j] = UInt32(truncatingIfNeeded: t)
                k = Int64(product >> 32) - (t >> 32)
            }
            let t = Int64(u[j + n]) - k
            u[j + n] = UInt32(truncatingIfNeeded: t)
            if t < 0 {
                var carry: UInt64 = 0
                for i in 0..<n {
                    let sum = UInt64(u[i + j]) + UInt64(v[i]) + carry
                    u[i + j] = UInt32(truncatingIfNeeded: sum)
                    carry = sum >> 32
                }
                u[j + n] = UInt32(truncatingIfNeeded: UInt64(u[j + n]) + carry)
            }
        }
        var rest = [UInt32](repeating: 0, count: n)
        for i in 0..<n {
            rest[i] = shift == 0 ? u[i] : (u[i] >> shift) | (u[i + 1] << (32 - shift))
        }
        return SRPNumber(digits: rest)
    }

    /// self^exponent mod m.
    func power(_ exponent: SRPNumber, mod m: SRPNumber) -> SRPNumber {
        var result = SRPNumber(1) % m
        var base = self % m
        for word in exponent.digits {
            var bits = word
            for _ in 0..<32 {
                if bits & 1 == 1 { result = (result * base) % m }
                base = (base * base) % m
                bits >>= 1
            }
        }
        return result
    }
}

// MARK: - SRP, as the extension's SecretSession does it

/// One pairing with the helper: SRP-6a over RFC 5054's 3072-bit group,
/// SHA-256, the RFC's verification (M and HAMK), the code Passwords shows as
/// the password. Every byte as the extension's sjcl code makes it.
struct ApplePasswordsSRP {
    static let N = SRPNumber(hex: """
    FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B30\
    2B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F24117C4B1FE6492866\
    51ECE45B3DC2007CB8A163BF0598DA48361C55D39A69163FA8FD24CF5F83655D23DCA3AD961C62F356208552BB9ED529077096966D670C354E4A\
    BC9804F1746C08CA18217C32905E462E36CE3BE39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF6955817183995497CEA956A\
    E515D2261898FA051015728E5A8AAAC42DAD33170D04507A33A85521ABDF1CBA64ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7AB\
    F5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6BF12FFA06D98A0864D87602733EC86A64521F2B18177B200CBBE117577A615D6C770988\
    C0BAD946E208E24FA074E5AB3143DB5BFCE0FD108E4B82D120A93AD2CAFFFFFFFFFFFFFFFF
    """)
    static let g = SRPNumber(5)
    static let length = 384

    enum Failure: Error, Equatable {
        case wrongCode, unexpected, refused
    }

    /// Base64 (the helper's capabilities say shouldUseBase64), else 0x-hex.
    let base64: Bool
    private let I: SRPNumber
    private let a: SRPNumber
    let A: SRPNumber
    private(set) var key: SymmetricKey?
    private var hamk: [UInt8] = []
    private var salt: [UInt8] = []
    private var B = SRPNumber(0)

    init(base64: Bool, random: (Int) -> [UInt8] = ApplePasswordsSRP.random) {
        self.base64 = base64
        // A first byte of zero would be dropped by toBits and read back as
        // another number; drawn again instead.
        var tid = random(16)
        while tid.first == 0 { tid = random(16) }
        I = SRPNumber(tid)
        a = SRPNumber(random(32))
        A = Self.g.power(a, mod: Self.N)
    }

    static func random(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return bytes
    }

    func text(_ bytes: [UInt8], prefixed: Bool = true) -> String {
        base64 ? Data(bytes).base64EncodedString() : (prefixed ? "0x" : "") + bytes.map { String(format: "%02x", $0) }.joined()
    }

    func bytes(_ text: String) -> [UInt8]? {
        if base64 { return Data(base64Encoded: text).map { [UInt8]($0) } }
        var hex = Substring(text.hasPrefix("0x") ? String(text.dropFirst(2)) : text)
        if hex.count % 2 == 1 { hex = "0" + hex }
        var out: [UInt8] = []
        while !hex.isEmpty {
            guard let byte = UInt8(hex.prefix(2), radix: 16) else { return nil }
            out.append(byte)
            hex = hex.dropFirst(2)
        }
        return out
    }

    var tid: String { text(I.bytes) }

    private static func sha(_ parts: [UInt8]...) -> [UInt8] {
        var hash = SHA256()
        for part in parts { hash.update(data: part) }
        return Array(hash.finalize())
    }

    private static func pake(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return data.base64EncodedString()
    }

    private static func unpake(_ text: String) -> [String: Any]? {
        guard let data = Data(base64Encoded: text) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Message 0: who asks, and A.
    var first: String {
        Self.pake(["TID": tid, "MSG": 0, "A": text(A.bytes), "VER": "1.0", "PROTO": [0, 1]])
    }

    /// Message 1 read (salt and B); message 2 made from the code typed.
    mutating func second(after reply: String, code: String) throws -> String {
        guard let message = Self.unpake(reply), message["TID"] as? String == tid,
              message["MSG"] as? Int == 1, message["ErrCode"] == nil,
              let s = (message["s"] as? String).flatMap(bytes),
              let b = (message["B"] as? String).flatMap(bytes)
        else { throw Failure.unexpected }
        // Only the RFC's verification: the old one sends v instead of M.
        let proto = message["PROTO"] as? Int ?? 0
        guard proto == 1 else { throw Failure.refused }
        let N = Self.N
        B = SRPNumber(b)
        guard !(B % N).isZero else { throw Failure.unexpected }
        salt = s
        let x = SRPNumber(Self.sha(s, Self.sha(Array((tid + ":" + code).utf8))))
        let v = Self.g.power(x, mod: N)
        let u = SRPNumber(Self.sha(A.padded(Self.length), B.padded(Self.length)))
        let k = SRPNumber(Self.sha(N.padded(Self.length), Self.g.padded(Self.length)))
        let kv = (k * v) % N
        let base = ((B % N) + N - kv) % N
        let S = base.power(a + u * x, mod: N)
        let K = Self.sha(S.bytes)
        key = SymmetricKey(data: K.prefix(16))
        let hn = Self.sha(N.bytes)
        let hg = Self.sha(Self.g.padded(Self.length))
        let xored = zip(hn, hg).map { $0 ^ $1 }
        let M = Self.sha(xored, Self.sha(Array(tid.utf8)), s, A.bytes, B.bytes, K)
        hamk = Self.sha(A.bytes, M, K)
        return Self.pake(["TID": tid, "MSG": 2, "M": text(M, prefixed: false)])
    }

    /// Message 3: the helper took the code, and proved it has the same key.
    func third(_ reply: String) throws {
        guard let message = Self.unpake(reply), message["TID"] as? String == tid else { throw Failure.unexpected }
        let error = message["ErrCode"] as? Int ?? 0
        if error == 1 { throw Failure.wrongCode }
        guard error == 0, let proof = (message["HAMK"] as? String).flatMap(bytes), proof == hamk else {
            throw Failure.wrongCode
        }
    }

    /// Client to helper: ciphertext, tag, then a 16-byte nonce.
    func seal(_ object: [String: Any]) throws -> String {
        guard let key else { throw Failure.refused }
        let plain = try JSONSerialization.data(withJSONObject: object)
        let nonce = try AES.GCM.Nonce(data: Self.random(16))
        let box = try AES.GCM.seal(plain, using: key, nonce: nonce)
        let sdata = [UInt8](box.ciphertext) + [UInt8](box.tag) + Array(nonce)
        let smsg = try JSONSerialization.data(withJSONObject: ["TID": tid, "SDATA": text(sdata, prefixed: false)])
        return String(decoding: smsg, as: UTF8.self)
    }

    /// Helper to client: the nonce first, then ciphertext and tag.
    func open(_ smsg: Any?) throws -> [String: Any] {
        guard let key else { throw Failure.refused }
        var envelope = smsg as? [String: Any]
        if envelope == nil, let text = smsg as? String, let data = text.data(using: .utf8) {
            envelope = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        guard let envelope, envelope["TID"] as? String == tid,
              let sdata = (envelope["SDATA"] as? String).flatMap(bytes), sdata.count > 32
        else { throw Failure.unexpected }
        let nonce = try AES.GCM.Nonce(data: sdata.prefix(16))
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: sdata.dropFirst(16).dropLast(16), tag: sdata.suffix(16))
        let plain = try AES.GCM.open(box, using: key)
        guard let object = (try? JSONSerialization.jsonObject(with: plain)) as? [String: Any] else { throw Failure.unexpected }
        return object
    }
}

// MARK: - the helper

/// The one helper Yab keeps for as long as it runs, and the one session
/// paired with it. Requests go one at a time: replies carry no id.
actor ApplePasswords {
    static let shared = ApplePasswords()
    /// Steps and statuses, never a code, a name or a password: `log stream
    /// --predicate 'category == "ApplePasswords"'`.
    static let log = Logger(subsystem: "dev.serafim.fast", category: "ApplePasswords")

    /// The host Apple installs for Chrome, and the origin it lets in.
    static let hostName = "com.apple.passwordmanager"
    static let origin = "chrome-extension://pejdijmoenmkgeppbflobdenhhabjlaj/"

    enum Failure: Error, Equatable {
        case noHelper, killedByMacOS, notPaired, timedOut, refused(Int), unexpected
    }

    /// Apple lets this Yab run its helper (the passkeys entitlement), or a
    /// test world stands one in (YAB_APPLE_HELPER, as YAB_BW_CLI is for bw).
    static var mayRun: Bool { Preferences.entitledToPasskeys || standIn != nil }

    /// A test world's stand-in for Apple's helper: a program at
    /// YAB_APPLE_HELPER speaking its protocol with synthetic values.
    static var standIn: URL? {
        guard Store.testing, let path = ProcessInfo.processInfo.environment["YAB_APPLE_HELPER"], !path.isEmpty,
              FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Where Apple's helper is: the path its Chrome manifest names.
    static var helper: URL? {
        if let standIn { return standIn }
        let folders = ["/Library/Google/Chrome/NativeMessagingHosts",
                       "/System/Cryptexes/App/Library/Google/Chrome/NativeMessagingHosts"]
        for folder in folders {
            let file = URL(fileURLWithPath: folder).appendingPathComponent(hostName + ".json")
            guard let data = try? Data(contentsOf: file),
                  let manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let path = manifest["path"] as? String,
                  (manifest["allowed_origins"] as? [String] ?? []).contains(origin),
                  FileManager.default.isExecutableFile(atPath: path)
            else { continue }
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    private var pipe: HostPipe?
    private var generation = UUID()
    private var pairingID = UUID()
    private let program: URL?
    private var killed = false
    private var base64 = true
    /// The helper's Hello said it hands out verification codes.
    private var fillsCodes = false
    private var session: ApplePasswordsSRP?
    private var paired = false
    private var tail: Task<Void, Never>?
    /// The code Passwords is showing: message 1, waiting for it.
    private var pending: (srp: ApplePasswordsSRP, reply: String, generation: UUID, pairing: UUID)?
    /// Requests given up on while paired, by cmd: their answers, still to
    /// come, are not the next request's. Replies carry no id.
    private var owed: [Int: Int] = [:]
    /// Scales the paired requests' waits, for tests.
    private let patience: TimeInterval
    /// What the last list for each host said of filling from it: the
    /// helper asks the person (Touch ID, the Mac's password) before it
    /// gives a password (RequiresUserAuthenticationToFill), or doesn't.
    private var asksToFill: [String: Bool] = [:]

    init(program: URL? = nil, patience: TimeInterval = 1) {
        self.program = program
        self.patience = patience
    }

    deinit { pipe?.stop() }

    var isPaired: Bool { paired }
    var canFillCodes: Bool { paired && fillsCodes }
    var macOSRefused: Bool { killed }
    var processIdentifier: Int32? { pipe?.processIdentifier }

    /// The helper, started if it isn't running.
    private func running() throws -> HostPipe {
        if let pipe { return pipe }
        guard !killed else { throw Failure.killedByMacOS }
        guard let program = program ?? Self.helper else { throw Failure.noHelper }
        let started = HostPipe(program: program, origin: Self.origin, buffersReplies: true)
        let id = UUID()
        generation = id
        owed = [:]
        started.killedAtLaunch = { [weak self] in Task { await self?.killedAtLaunch(id) } }
        started.onExit = { [weak self, weak started] in
            let stopped = started?.stoppedByUs ?? false
            Task { await self?.ended(id, stoppedByYab: stopped) }
        }
        // What the helper says by itself (a code came, passwords turned off).
        started.onMessage = { [weak self] message in
            let cmd = (message as? [String: Any])?["cmd"] as? Int
            if cmd == 9 || cmd == 10 {
                Self.log.notice("helper said cmd \(cmd ?? -1): session over")
                Task { await self?.dropSession(id) }
            }
        }
        try started.start()
        Self.log.notice("helper started")
        pipe = started
        return started
    }

    private func killedAtLaunch(_ id: UUID) {
        guard generation == id else { return }
        Self.log.error("helper killed by macOS at launch")
        killed = true
    }

    private func ended(_ id: UUID, stoppedByYab: Bool) {
        guard generation == id else { return }
        Self.log.notice("helper ended, stopped by Yab: \(stoppedByYab)")
        pipe = nil
        dropSession(id)
    }

    private func dropSession(_ id: UUID) {
        guard generation == id else { return }
        pairingID = UUID()
        session = nil
        paired = false
        pending = nil
        Task { @MainActor in ApplePasswordsPairing.ended() }
    }

    /// Writes one message and reads until a reply to `cmd` (or `also`), after
    /// every request before it: one reply read at a time. Messages cross as
    /// JSON bytes, which are Sendable.
    private func exchange(_ message: [String: Any], cmd: Int, also: Int? = nil, wait: TimeInterval) async throws -> [String: Any] {
        let sent = try JSONSerialization.data(withJSONObject: message)
        let previous = tail
        let task = Task<Data, Error> {
            _ = await previous?.value
            let pipe = try running()
            if cmd == 16 || cmd == 17 { Self.log.notice("code helper request cmd \(cmd), timeout \(wait)") }
            try pipe.write(try JSONSerialization.jsonObject(with: sent))
            let deadline = SuspendingClock.now.advanced(by: .seconds(wait))
            while true {
                let reply: Any?
                do {
                    reply = try await pipe.readOne(until: deadline, otherwise: Failure.timedOut)
                } catch Failure.timedOut {
                    noAnswer(to: cmd, from: pipe)
                    throw Failure.timedOut
                }
                guard let object = reply as? [String: Any], let got = object["cmd"] as? Int else { continue }
                if let late = owed[got], late > 0 {
                    owed[got] = late - 1
                    continue
                }
                if cmd == 16 || cmd == 17 {
                    let shape = object["payload"].map { String(describing: type(of: $0)) } ?? "missing"
                    Self.log.notice("code helper reply cmd \(got), payload type \(shape, privacy: .public)")
                }
                if got == cmd || got == also { return try JSONSerialization.data(withJSONObject: object) }
            }
        }
        tail = Task { _ = try? await task.value }
        let data: Data
        do { data = try await task.value }
        catch {
            if cmd == 16 || cmd == 17 { Self.log.error("code helper exchange failed cmd \(cmd)") }
            throw error
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw Failure.unexpected }
        return object
    }

    /// A missing answer cannot distinguish a stuck helper from a locked
    /// keychain, a slow wake or an unanswered authentication alert. Only
    /// Apple ending the session (or the process exiting) invalidates it.
    /// Killing this process to recover a query would also destroy its key.
    private func noAnswer(to cmd: Int, from pipe: HostPipe) {
        guard paired else {
            pipe.stop()
            return
        }
        Self.log.notice("no answer to cmd \(cmd) in time, helper kept")
        // Save replies may never arrive and carry no secret; other late
        // replies must not be mistaken for the next request's answer.
        if cmd != 6 { owed[cmd, default: 0] += 1 }
    }

    // MARK: pairing

    /// Asks the helper to show its code: true once Passwords shows one.
    func beginPairing() async throws {
        let hello = try await exchange(["cmd": 14], cmd: 14, wait: 5)
        let id = generation
        let pairing = pairingID
        guard pipe != nil else { throw Failure.notPaired }
        let capabilities = hello["capabilities"] as? [String: Any]
        base64 = (capabilities?["shouldUseBase64"] as? Bool) ?? true
        fillsCodes = (capabilities?["canFillOneTimeCodes"] as? Bool) ?? false
        Self.log.notice("hello: base64 \(self.base64) codes \(self.fillsCodes)")
        let srp = ApplePasswordsSRP(base64: base64)
        let m0: [String: Any] = ["QID": "m0", "PAKE": srp.first, "HSTBRSR": "Yab"]
        let text = String(decoding: try JSONSerialization.data(withJSONObject: m0), as: UTF8.self)
        let reply = try await exchange(["cmd": 2, "msg": text], cmd: 2, wait: 15)
        guard generation == id, pairingID == pairing, pipe != nil else { throw Failure.notPaired }
        guard let payload = reply["payload"] as? [String: Any], payload["QID"] as? String == "m0",
              let pake = payload["PAKE"] as? String
        else { throw Failure.unexpected }
        pending = (srp, pake, id, pairing)
        Self.log.notice("code shown by Passwords")
    }

    /// The code typed: paired, or `ApplePasswordsSRP.Failure.wrongCode`.
    func finishPairing(code: String) async throws {
        guard let waiting = pending, waiting.generation == generation,
              waiting.pairing == pairingID, pipe != nil else { throw Failure.notPaired }
        var srp = waiting.srp
        let m2 = try srp.second(after: waiting.reply, code: code)
        let text = String(decoding: try JSONSerialization.data(withJSONObject: ["QID": "m2", "PAKE": m2]), as: UTF8.self)
        let reply = try await exchange(["cmd": 2, "msg": text], cmd: 2, wait: 15)
        guard generation == waiting.generation, pairingID == waiting.pairing, pipe != nil else { throw Failure.notPaired }
        guard let payload = reply["payload"] as? [String: Any], let pake = payload["PAKE"] as? String else {
            throw Failure.unexpected
        }
        pending = nil
        do {
            try srp.third(pake)
        } catch {
            Self.log.error("pairing refused: \(String(describing: error), privacy: .public)")
            throw error
        }
        session = srp
        paired = true
        Self.log.notice("paired")
    }

    /// The person closed the card: the helper puts its code window away.
    func cancelPairing() async {
        pending = nil
        guard let pipe else { return }
        try? pipe.write(["cmd": 19])
    }

    // MARK: requests

    private func request(_ cmd: Int, qid: String, url: String?, _ body: [String: Any],
                         also: Int? = nil, wait: TimeInterval) async throws -> [String: Any] {
        guard paired, let session else { throw Failure.notPaired }
        let id = generation
        let pairing = pairingID
        let smsg = try session.seal(body)
        var message: [String: Any] = ["cmd": cmd, "tabId": 0, "frameId": 0]
        let payload = try JSONSerialization.data(withJSONObject: ["QID": qid, "SMSG": smsg])
        message["payload"] = String(decoding: payload, as: UTF8.self)
        if let url { message["url"] = url }
        let reply = try await exchange(message, cmd: cmd, also: also, wait: wait * patience)
        guard generation == id, pairingID == pairing, paired else { throw Failure.notPaired }
        var smsgBack = (reply["payload"] as? [String: Any])?["SMSG"]
        if smsgBack == nil, let text = reply["payload"] as? String, let data = text.data(using: .utf8) {
            smsgBack = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["SMSG"]
        }
        let answer = try session.open(smsgBack)
        let status = answer["STATUS"] as? Int ?? 1
        Self.log.notice("cmd \(cmd) status \(status) entries \(Self.entries(answer).count)")
        if cmd == 16 || cmd == 17 {
            let locked = answer["RequiresUserAuthenticationToFill"] as? Bool ?? false
            let shapes = Self.entries(answer).map { $0.keys.sorted().joined(separator: ",") }.joined(separator: ";")
            Self.log.notice("code helper auth required \(locked), entry fields \(shapes, privacy: .public)")
        }
        if status == 9 {
            Self.log.notice("helper said status 9: session over")
            dropSession(id)
        }
        guard status == 0 || status == 3 else { throw Failure.refused(status) }
        return answer
    }

    private static func entries(_ answer: [String: Any]) -> [[String: Any]] {
        if let list = answer["Entries"] as? [[String: Any]] { return list }
        return answer.keys.filter { $0.hasPrefix("Entry_") }.sorted().compactMap { answer[$0] as? [String: Any] }
    }

    struct Entry: Sendable, Equatable {
        let user: String
        let sites: [String]
        let title: String?
    }

    /// The site's logins, names only ("Not Included" for the password).
    func logins(for host: String) async throws -> [Entry] {
        let answer = try await request(4, qid: "CmdGetLoginNames4URL", url: host, ["ACT": 5, "URL": host], wait: 10)
        // Said only when it asks, as the extension reads it: absent is no.
        let asks = answer["RequiresUserAuthenticationToFill"] as? Bool ?? false
        asksToFill[host] = asks
        Self.log.notice("list helper auth required \(asks)")
        return Self.entries(answer).compactMap { entry in
            guard let user = entry["USR"] as? String, user != "Passwords\u{a0}not\u{a0}saved" else { return nil }
            return Entry(user: user, sites: entry["sites"] as? [String] ?? [], title: entry["customTitle"] as? String)
        }
    }

    /// Whether the helper asks the person before it gives a password for
    /// `host`, as its last list for it said; no list, no.
    func asksBeforeFilling(_ host: String) -> Bool { asksToFill[host] ?? false }

    /// One login's password: the helper asks Touch ID first.
    func password(host: String, user: String) async throws -> String {
        let answer = try await request(5, qid: "CmdGetPassword4LoginName", url: host,
                                       ["ACT": 2, "URL": host, "USR": user], wait: 120)
        let entries = Self.entries(answer)
        let entry = entries.first { ($0["sites"] as? [String] ?? []).contains(host) && $0["USR"] as? String == user }
            ?? entries.first { $0["USR"] as? String == user } ?? entries.first
        guard let password = entry?["PWD"] as? String, password != "Not Included" else { throw Failure.unexpected }
        return password
    }

    struct Code: Sendable, Equatable {
        /// Empty when the helper gives it only after Touch ID.
        let code: String
        let user: String
        let site: String
    }

    /// The page's verification codes kept in Passwords (cmd 16): the code
    /// itself when the helper gives it freely, else only whose it is.
    func codes(page: String, user: String?) async throws -> [Code] {
        guard canFillCodes, let host = URL(string: page)?.host() else { return [] }
        var body: [String: Any] = ["ACT": 5, "TYPE": "oneTimeCodes", "frameURLs": [page]]
        if let user { body["username"] = user }
        let answer = try await request(16, qid: "CmdGetOneTimeCodes", url: nil, body, wait: 10)
        let locked = answer["RequiresUserAuthenticationToFill"] as? Bool ?? false
        return Self.codes(in: answer, host: host, locked: locked, also: await Self.related(in: answer, host: host))
    }

    /// One code as it is now (cmd 17): the helper asks Touch ID first when
    /// it wants to.
    func code(page: String, user: String) async throws -> String {
        guard canFillCodes, let host = URL(string: page)?.host() else { throw Failure.notPaired }
        let answer = try await request(17, qid: "CmdDidFillOneTimeCode", url: nil,
                                       ["ACT": 2, "TYPE": "oneTimeCodes", "frameURLs": [page], "username": user], wait: 120)
        let found = Self.codes(in: answer, host: host, locked: false, also: await Self.related(in: answer, host: host))
        guard let code = found.first(where: { $0.user.lowercased() == user.lowercased() })?.code,
              !code.isEmpty else { throw Failure.unexpected }
        return code
    }

    /// Time codes for this site only: a code for another one is never offered,
    /// but for a site in `related`, one that says this page is its own.
    static func codes(in answer: [String: Any], host: String, locked: Bool, also related: Set<String> = []) -> [Code] {
        let site = Vault.registrable(host)
        return entries(answer).compactMap { entry in
            let source = entry["source"] as? String ?? "totp"
            let domain = entry["domain"] as? String ?? host
            let owner = Vault.registrable(domain)
            guard source == "totp", owner == site || related.contains(owner) else { return nil }
            let digits = (entry["code"] as? String ?? "").filter { !$0.isWhitespace }
            let code = locked || !digits.allSatisfy(\.isNumber) || !(4...10).contains(digits.count) ? "" : digits
            return Code(code: code, user: entry["username"] as? String ?? "", site: site)
        }
    }

    /// The other sites in an answer whose related origins file lists this
    /// page (RelatedOrigins): a code kept for twitter.com years ago is X's
    /// on x.com, as Passwords itself offers it there. Asked only when the
    /// answer holds a time code for another site.
    static func related(in answer: [String: Any], host: String) async -> Set<String> {
        let site = Vault.registrable(host)
        let others = Set(entries(answer).compactMap { entry -> String? in
            guard (entry["source"] as? String ?? "totp") == "totp", let domain = entry["domain"] as? String else { return nil }
            let owner = Vault.registrable(domain)
            return owner == site ? nil : owner
        })
        var found: Set<String> = []
        for other in others.sorted() where await RelatedOrigins.allow(rp: other, origin: "https://\(host.lowercased())") {
            found.insert(other)
        }
        return found
    }

    /// A new sign-in, kept in Passwords. The helper may ask with its own
    /// alert too (unconfirmed: docs/evidence, §2.2); its reply comes once
    /// that is answered, sometimes tagged as cmd 4.
    ///
    /// Already kept (status 7) is what was asked for: the iCloud Passwords
    /// extension, on beside Yab, saves the same sign-in as it leaves the page.
    /// A reply with no readable answer says nothing either way (the extension
    /// ignores this reply altogether), so Passwords' own list decides.
    func save(host: String, user: String, password: String) async throws {
        do {
            _ = try await request(6, qid: "CmdSetPassword4LoginName_URL", url: nil,
                                  ["ACT": 4, "URL": "", "USR": "", "PWD": "", "NURL": host, "NUSR": user, "NPWD": password],
                                  also: 4, wait: 120)
        } catch Failure.refused(7) {
            Self.log.notice("save: already kept")
        } catch let failure as Failure where failure != .unexpected {
            throw failure
        } catch {
            Self.log.error("save: no readable reply, reading the list")
            guard let kept = try? await logins(for: host), kept.contains(where: { $0.user == user }) else { throw error }
        }
    }
}

// MARK: - the adapter

/// Apple Passwords as a manager Yab reads itself (ManagerVault): open once
/// paired this launch; until then it asks for the code, once.
struct AppleVault: ManagerAdapter {
    let provider = PasswordManagers.apple
    let depth = ManagerVault.Depth.vault
    let saves = true
    var passwords = ApplePasswords.shared
    /// Paired by now, asking for the code if it has to.
    var connect: @Sendable () async -> Bool = { await ApplePasswordsPairing.connected() }

    func state() async -> ManagerVault.State {
        let entitled = await MainActor.run { ApplePasswords.mayRun }
        guard entitled, ApplePasswords.helper != nil else { return .noTool }
        if await passwords.macOSRefused { return .failed("macOS didn't let Passwords' helper run") }
        if await passwords.isPaired { return .open }
        // Not paired by this helper yet: the code is asked for at the sign-in
        // box the person is at (ApplePasswordsPairing.offer), not wherever
        // a page reads the managers.
        return .needsApproval
    }

    func logins(for host: String) async throws -> [ManagerVault.Login] {
        guard await passwords.isPaired else { throw ManagerVault.Failure.locked }
        let found = try await passwords.logins(for: host)
        return ManagerVault.tidy(found.map { entry in
            ManagerVault.Login(provider: provider, item: host + "\u{1}" + entry.user, title: entry.title ?? entry.user,
                               user: entry.user, urls: entry.sites.isEmpty ? [host] : entry.sites)
        })
    }

    /// Proven when the helper said it asks before filling from this site:
    /// it put its own Touch ID up for this password, as it does for the
    /// iCloud Passwords extension in Chrome.
    func secret(_ login: ManagerVault.Login) async throws -> ManagerVault.Secret {
        let host = String(login.item.split(separator: "\u{1}").first ?? "")
        let password = try await passwords.password(host: host, user: login.user)
        return ManagerVault.Secret(user: login.user, password: password, proven: await passwords.asksBeforeFilling(host))
    }

    func save(host: String, user: String, password: String) async throws {
        // Connected lasts across launches, a pairing only as long as its
        // helper: a sign-in is offered either way, and its Save pairs first.
        if !(await passwords.isPaired), !(await connect()) { throw ApplePasswords.Failure.notPaired }
        do {
            try await passwords.save(host: host, user: user, password: password)
        } catch let failure as ApplePasswords.Failure where failure == .notPaired || failure == .refused(9) {
            // The session went while this waited its turn.
            guard await connect() else { throw failure }
            try await passwords.save(host: host, user: user, password: password)
        }
    }
}

// MARK: - the code

/// The code Passwords shows, asked for on Yab's card: Passwords' icon, the
/// code in two groups of three as Settings' assistant codes are, Not Now
/// alone. The sixth digit connects; a wrong code brings a new one.
@MainActor
enum ApplePasswordsPairing {
    /// The sites whose sign-in box the person answered Not Now on, for as
    /// long as this helper's session lasts: their boxes don't ask again.
    /// Another site's sign-in does: that Not Now was for that page, and
    /// connected Apple Passwords stays reachable without a restart, as
    /// Apple's own extension offers its pairing on every box until paired.
    private static var declined: Set<String> = []
    private static var busy = false

    static func ended() { declined = [] }

    /// From a sign-in box on `host` the person is at (Browser.onField, an
    /// agent's sign_in on its tab): the code, unless this site said Not Now
    /// already or a card is up.
    static func offer(on host: String) {
        let site = Vault.registrable(host)
        guard !busy, !declined.contains(site) else { return }
        Task {
            // What the box last read may be older than a pairing just made.
            guard !(await ApplePasswords.shared.isPaired) else { return }
            if await pairing() == .declined { declined.insert(site) }
        }
    }

    /// How an ask ended: paired; the person said Not Now (or Escape); or it
    /// never reached them (a card already up, the helper didn't start),
    /// which says nothing about the site.
    enum Outcome { case paired, declined, unasked }

    /// Whether the helper is paired, after asking for the code when it isn't
    /// (and after the card already up, if one is).
    static func connected() async -> Bool {
        while busy { try? await Task.sleep(for: .milliseconds(200)) }
        if await ApplePasswords.shared.isPaired { return true }
        await pair()
        return await ApplePasswords.shared.isPaired
    }

    /// Settings' Connect: asked whatever happened before.
    @discardableResult
    static func pair(registerConnection: Bool = false) async -> Bool {
        await pairing(registerConnection: registerConnection) == .paired
    }

    private static func pairing(registerConnection: Bool = false) async -> Outcome {
        guard !busy else { return .unasked }
        busy = true
        defer { busy = false }
        // Keep the source window before Passwords brings its own forward.
        let source = NSApp.keyWindow
        let sourceNumber = (source?.parent ?? source)?.windowNumber
        do {
            try await ApplePasswords.shared.beginPairing()
        } catch {
            ApplePasswords.log.error("pairing didn't start: \(String(describing: error), privacy: .public)")
            return .unasked
        }
        let model = CodeModel()
        let anchor = QuestionAnchor(processIdentifier: await ApplePasswords.shared.processIdentifier)
        let enablement = Question.Enablement()
        let question = connectQuestion(model: model, anchor: anchor, window: sourceNumber, enablement: enablement)
        let questionID = question.id
        model.done = { [weak model, weak anchor] code in
            Task { @MainActor in
                guard let model, let anchor, !model.checking,
                      Questions.shared.current?.id == questionID else { return }
                model.checking = true
                defer { model.checking = false }
                do {
                    try await ApplePasswords.shared.finishPairing(code: code)
                    guard Questions.shared.current?.id == questionID else { return }
                    enablement.allowed = true
                    Questions.shared.answer(true)
                } catch {
                    guard Questions.shared.current?.id == questionID else { return }
                    // A wrong code ends the helper's round: a new one, shown
                    // by Passwords, and the field empty again.
                    model.code = ""
                    model.wrong = true
                    try? await ApplePasswords.shared.beginPairing()
                    guard Questions.shared.current?.id == questionID else {
                        await ApplePasswords.shared.cancelPairing()
                        return
                    }
                    anchor.processIdentifier = await ApplePasswords.shared.processIdentifier
                }
            }
        }
        let connected = await Questions.shared.ask(question)
        if connected {
            // Extension redirects connect only after the code was accepted,
            // before clearing caches and reopening the page's password list.
            if registerConnection {
                PasswordManagers.Connections.shared.connect(PasswordManagers.apple, mode: .you, pair: false)
            }
            declined = []
            PasswordManagers.quietAppleExtension()
            ManagerVaults.forget()
            ManagerLists.shared.forget()
            if let browser = Extensions.here.browser, let tab = browser.active { browser.reopenList(tab.id) }
            await PasswordsToApple.offerOnce()
        } else {
            await ApplePasswords.shared.cancelPairing()
        }
        return connected ? .paired : .declined
    }

    /// Shared with the isolated bench scene; the native pairing question's
    /// content, field, buttons and layout remain the Settings flow's own.
    static func connectQuestion(model: CodeModel, anchor: QuestionAnchor? = nil, window: Int? = nil,
                         enablement: Question.Enablement = Question.Enablement()) -> Question {
        Question(
            title: "Connect Apple Passwords",
            detail: "Enter the code Passwords shows.",
            icon: PasswordManagers.icon(PasswordManagers.apple),
            ownIcon: true,
            yes: "",
            no: "Not Now",
            place: .plain,
            anchor: anchor,
            window: window,
            accessory: AnyView(PairingField(model: model)),
            enablement: enablement
        )
    }

    @Observable final class CodeModel {
        var code = ""
        var wrong = false
        var checking = false
        @ObservationIgnored var done: (String) -> Void = { _ in }
    }

    struct PairingField: View {
        var model: CodeModel

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                CodeStrip(code: Binding(get: { model.code }, set: { typed in
                    model.code = typed
                    model.wrong = false
                    if typed.count == 6, !model.checking { model.done(typed) }
                }), editable: !model.checking, invalid: model.wrong)
                if model.wrong {
                    Text("That code didn’t match. Passwords shows a new one.")
                        .font(CardFrame.detail)
                        .foregroundStyle(Palette.muted)
                        .transition(.opacity.combined(with: .blurred(4)))
                }
            }
            .animation(Motion.settle, value: model.wrong)
        }
    }

    /// Passwords' six digits on one strip, as Passwords draws them: three,
    /// a gap, three. A digit drops in out of a blur over the dot it takes,
    /// a caret waits at the next place, and a wrong code shakes the strip
    /// and blurs its digits away.
    struct CodeStrip: View {
        @Binding var code: String
        var editable = true
        var invalid = false
        @FocusState private var focused: Bool
        @State private var shakes = 0
        @State private var typedAt = Date()
        @State private var lit = true
        @Namespace private var caretSpace

        static let count = 6

        var body: some View {
            HStack(spacing: 0) {
                ForEach(0..<Self.count, id: \.self) { slot($0).padding(.leading, $0 == 3 ? 18 : 0) }
            }
            .font(.system(size: 32, weight: .light).monospacedDigit()) // design: Passwords' own code size, matched on its strip
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(Palette.wash, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .overlay {
                if invalid || (editable && focused) {
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .strokeBorder(invalid ? Color.orange : Color.accentColor, lineWidth: 2)
                }
            }
            .modifier(Shake(travel: CGFloat(shakes)))
            .background {
                if editable {
                    // The keys go to a field no one sees; the strip draws it.
                    // Only a real change goes up: focusing writes the same
                    // text back, which would clear a wrong code's mark.
                    TextField("", text: Binding(get: { code }, set: { raw in
                        let next = CodeGroupsField.clean(raw, count: Self.count, digits: true)
                        guard next != code else { return }
                        code = next
                        typedAt = Date()
                        lit = true
                    }))
                        .textFieldStyle(.plain)
                        .focused($focused)
                        .opacity(0.01)
                        .accessibilityLabel("Code")
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { focused = true }
            .animation(.spring(response: 0.34, dampingFraction: 0.86), value: code)
            .animation(Motion.settle, value: focused)
            // The field is the card's default focus, the one SwiftUI gives
            // as the card first takes focus. Setting `focused` on appear, as
            // this did, came while the card's panel was still off screen:
            // SwiftUI's focus bridge then gave the window's first key view,
            // with keyboard navigation on the Not Now button (R2564).
            .defaultFocus($focused, true)
            .onReceive(Timer.publish(every: 0.53, on: .main, in: .common).autoconnect()) { now in
                lit = now.timeIntervalSince(typedAt) < 0.53 ? true : !lit
            }
            .onChange(of: editable) { _, on in if on { focused = true } }
            .onChange(of: invalid) { _, wrong in
                guard wrong else { return }
                withAnimation(.linear(duration: 0.42)) { shakes += 1 }
            }
        }

        private func slot(_ at: Int) -> some View {
            let typed = Array(code)
            let filled = at < typed.count
            return ZStack {
                Circle()
                    .fill(.tertiary)
                    .frame(width: 5, height: 5)
                    .scaleEffect(filled ? 2.4 : 1)
                    .blur(radius: filled ? 3 : 0)
                    .opacity(filled ? 0 : 1)
                if filled {
                    Text(String(typed[at]))
                        .id("\(at)\(typed[at])")
                        .transition(.asymmetric(
                            insertion: .offset(y: -12).combined(with: .opacity).combined(with: .blurred(6)),
                            removal: .scale(scale: 0.85).combined(with: .opacity).combined(with: .blurred(8))))
                }
            }
            .frame(width: 24, height: 40)
            .overlay(alignment: at == typed.count ? .leading : .trailing) {
                // Solid while typing, blinking at the system's rate once still.
                if editable, focused, at == min(typed.count, Self.count - 1) {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: 2, height: 28)
                        .opacity(lit ? 1 : 0)
                        .matchedGeometryEffect(id: "caret", in: caretSpace)
                        .offset(x: at == typed.count ? -1 : 2)
                }
            }
        }
    }

    /// A strip's no: a short shake, damped, as a refused password field.
    private struct Shake: GeometryEffect {
        var travel: CGFloat
        var animatableData: CGFloat {
            get { travel }
            set { travel = newValue }
        }

        func effectValue(size: CGSize) -> ProjectionTransform {
            let t = travel - travel.rounded(.down)
            let x = 7 * sin(t * .pi * 4) * (1 - t)
            return ProjectionTransform(CGAffineTransform(translationX: x, y: 0))
        }
    }
}

private struct BlurredTransition: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View { content.blur(radius: radius) }
}

extension AnyTransition {
    /// In or out of focus, as macOS blurs what it brings and takes away.
    static func blurred(_ radius: CGFloat) -> AnyTransition {
        .modifier(active: BlurredTransition(radius: radius), identity: BlurredTransition(radius: 0))
    }
}
