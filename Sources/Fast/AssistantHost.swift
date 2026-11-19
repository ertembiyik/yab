import YabStore
import AppKit
import IOKit.ps
import IOKit.pwr_mgt
import Security

// This Mac as a host for assistants in the cloud (docs/assistants.md): its
// own id and secret, registered with the server once, and the WebSocket it
// keeps open while any assistant is linked, which the server sends every
// call down. Nothing listens on the Mac: the line goes out from here.
//
// It has nothing to do with Sync: no account, no keys.

@MainActor
@Observable final class AssistantHost {
    static let shared = AssistantHost()

    enum State: Equatable {
        case off, connecting, online
        case offline(String)
    }

    private(set) var state: State = .off

    /// The server: YAB_ASSIST_URL (a test's `wrangler dev`), else ours.
    static var origin: URL {
        if let set = ProcessInfo.processInfo.environment["YAB_ASSIST_URL"], let url = URL(string: set) { return url }
        if Store.testing, let set = Store.settings.string(forKey: "assistants.server"), let url = URL(string: set) { return url }
        return URL(string: "https://yab-sync.21st.workers.dev")!
    }

    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var session = URLSession(configuration: .ephemeral)
    @ObservationIgnored private var pinger: Timer?
    @ObservationIgnored private var retry: DispatchWorkItem?
    @ObservationIgnored private var backoff: Double = 1
    /// When the line last came up: the backoff starts over only once it
    /// has held a while, so a server that takes and drops it isn't hammered.
    @ObservationIgnored private var upSince: Date?
    /// Bumped with each socket, so a stale one's callbacks do nothing.
    @ObservationIgnored private var generation = 0

    private init() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AssistantHost.shared.nudge() }
        }
    }

    // MARK: - identity

    var id: String {
        if let kept = Store.settings.string(forKey: "assistants.host"), !kept.isEmpty { return kept }
        let made = Assistants.newID()
        Store.settings.set(made, forKey: "assistants.host")
        return made
    }

    private var secret: String {
        if let kept = Keys.read("secret") { return kept }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let made = Data(bytes).base64URL
        Keys.write(made, "secret")
        return made
    }

    private var token: String? {
        get { Keys.read("token") }
        set { if let newValue { Keys.write(newValue, "token") } else { Keys.delete("token") } }
    }

    /// The host's token, registering this Mac first when it has none.
    func authorized() async throws -> String {
        if let token { return token }
        let name = Host.current().localizedName ?? "Mac"
        let got = try await call("POST", "/v1/hosts", ["id": id, "secret": secret, "name": name], auth: false)
        guard let made = got["token"] as? String else { throw Failure.said(got["error"] as? String ?? "the server didn't register this Mac") }
        token = made
        return made
    }

    enum Failure: LocalizedError {
        case said(String)
        case status(Int)
        var errorDescription: String? {
            switch self {
            case .said(let words): return words
            case .status(let code): return code == 404 ? "That code isn't known. Check it, or get a new one." : "The server answered \(code)."
            }
        }
    }

    /// One request to the server, as JSON both ways. A 401 registers
    /// again (the token may have been replaced) and tries once more.
    @discardableResult
    func call(_ method: String, _ path: String, _ body: [String: Any]? = nil, auth: Bool = true, again: Bool = true) async throws -> [String: Any] {
        let parts = path.split(separator: "?", maxSplits: 1).map(String.init)
        var url = Self.origin.appending(path: parts[0])
        if parts.count == 2, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.percentEncodedQuery = parts[1]
            url = components.url ?? url
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        if auth {
            let bearer = try await authorized()
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401, auth, again {
            token = nil
            return try await call(method, path, body, auth: true, again: false)
        }
        let got = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard (200..<300).contains(code) else {
            if let error = got["error"] as? String, code != 404, code != 410 { throw Failure.said(got["message"] as? String ?? error) }
            throw Failure.status(code)
        }
        return got
    }

    // MARK: - linking

    struct Link: Equatable {
        let link: String
        let client: String
        let kind: String
        let nonce: String?
        var clientID: String? = nil
        /// Where an OAuth client's tokens go; nil for a code typed in a CLI.
        var redirectHost: String? = nil

        /// Stable IDs identify known bots; dynamic OAuth clients retain
        /// their readable name instead of showing a generated client ID.
        var presentationClient: String {
            if let id = clientID, AssistantBot.allCases.contains(where: { $0.client == id }) { return id }
            return client
        }

        func matches(client expectedClient: String?, nonce expectedNonce: String?) -> Bool {
            if let expectedNonce, nonce != expectedNonce { return false }
            if let expectedClient, clientID != expectedClient { return false }
            return true
        }
    }

    /// What a code typed on the Mac stands for.
    func lookup(_ code: String) async throws -> Link {
        let plain = code.uppercased().filter { $0.isLetter || $0.isNumber }
        let got = try await call("POST", "/v1/hosts/\(id)/links/lookup", ["code": plain])
        guard let link = got["link"] as? String else { throw Failure.status(404) }
        return Link(link: link, client: got["client"] as? String ?? "", kind: got["kind"] as? String ?? "oauth",
                    nonce: got["nonce"] as? String,
                    clientID: got["client_id"] as? String,
                    redirectHost: (got["redirect"] as? String).flatMap { URL(string: $0)?.host() })
    }

    /// The user's answer. A yes keeps the grant, and the socket comes up so
    /// the assistant's first call finds this Mac.
    func decide(_ link: Link, grant: AssistantGrant?) async throws {
        var body: [String: Any] = ["link": link.link, "allow": grant != nil]
        if let grant { body["assistant"] = ["id": grant.id, "name": grant.name] }
        if let grant { Assistants.shared.keep(grant) }
        do {
            try await call("POST", "/v1/hosts/\(id)/links/decide", body)
        } catch {
            if let grant { Assistants.shared.remove(grant.id) }
            throw error
        }
        if grant != nil {
            start()
            grantsChanged()
        }
    }

    /// One line of the server's journal: which tool, when, how it went.
    struct Entry: Identifiable, Equatable {
        let id: Int
        let at: Date
        let tool: String
        let outcome: String
    }

    /// The last calls an assistant made, as the server kept them (30 days,
    /// no arguments or answers).
    func journal(_ assistant: String, limit: Int = 100) async throws -> [Entry] {
        let got = try await call("GET", "/v1/hosts/\(id)/log?assistant=\(assistant)&limit=\(limit)")
        let rows = got["entries"] as? [[String: Any]] ?? []
        return rows.enumerated().map { index, row in
            Entry(id: index, at: Date(timeIntervalSince1970: (row["at"] as? Double ?? 0) / 1000),
                  tool: row["tool"] as? String ?? "", outcome: row["outcome"] as? String ?? "")
        }
    }

    /// An assistant gone here: its tokens stop on the server too.
    func disconnect(_ assistant: String) {
        Task {
            _ = try? await call("DELETE", "/v1/hosts/\(id)/assistants/\(assistant)")
            if Assistants.shared.grants.isEmpty { stop() } else { hello() }
        }
    }

    /// Paused, resumed or renamed: what the server answers for it while
    /// the Mac is away changes with it.
    func grantsChanged() {
        sendTools()
    }

    // MARK: - the socket

    /// Up while any assistant is linked; a no-op when it already is.
    func start() {
        AssistantReach.shared.apply()
        guard !Assistants.shared.grants.isEmpty else { stop(); return }
        guard socket == nil, retry == nil else { return }
        open()
    }

    func stop() {
        AssistantReach.shared.apply()
        generation += 1
        retry?.cancel(); retry = nil
        pinger?.invalidate(); pinger = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        state = .off
    }

    private func open() {
        generation += 1
        let mine = generation
        state = .connecting
        Task {
            do {
                let token = try await authorized()
                guard mine == generation else { return }
                var url = URLComponents(url: Self.origin.appending(path: "/v1/hosts/\(id)/socket"), resolvingAgainstBaseURL: false)!
                url.scheme = url.scheme == "http" ? "ws" : "wss"
                var request = URLRequest(url: url.url!)
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                let task = session.webSocketTask(with: request)
                socket = task
                task.resume()
                hello()
                receive(task, mine)
                pinger?.invalidate()
                pinger = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.send(["t": "ping"]) }
                }
            } catch {
                failed(mine, error.localizedDescription)
            }
        }
    }

    private func receive(_ task: URLSessionWebSocketTask, _ mine: Int) {
        task.receive { [weak self] result in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, mine == self.generation else { return }
                    switch result {
                    case .failure(let error):
                        // Unauthorized: the token may be another's now.
                        if (task.response as? HTTPURLResponse)?.statusCode == 401 { self.token = nil }
                        if task.closeCode.rawValue == 4003 {
                            // Deleted on the server: what was linked is gone.
                            self.token = nil
                        }
                        self.failed(mine, error.localizedDescription)
                    case .success(let message):
                        if self.state != .online { self.state = .online; self.upSince = Date() }
                        var data: Data?
                        switch message {
                        case .string(let text): data = Data(text.utf8)
                        case .data(let bytes): data = bytes
                        @unknown default: break
                        }
                        if let data, let got = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { self.heard(got) }
                        self.receive(task, mine)
                    }
                }
            }
        }
    }

    private func failed(_ mine: Int, _ why: String) {
        guard mine == generation else { return }
        socket?.cancel(with: .abnormalClosure, reason: nil)
        socket = nil
        pinger?.invalidate(); pinger = nil
        state = .offline(why)
        guard !Assistants.shared.grants.isEmpty else { state = .off; return }
        if let upSince, Date().timeIntervalSince(upSince) > 60 { backoff = 1 }
        upSince = nil
        let wait = backoff
        backoff = min(backoff * 2, 60)
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.retry = nil
                self.open()
            }
        }
        retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + wait + Double.random(in: 0...0.5), execute: work)
    }

    /// Back after sleep or a network change: try now rather than at the
    /// end of a long backoff.
    /// A socket left from before sleep is likely dead without knowing it.
    func nudge() {
        guard !Assistants.shared.grants.isEmpty else { return }
        retry?.cancel(); retry = nil
        pinger?.invalidate(); pinger = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        backoff = 1
        open()
    }

    func send(_ message: [String: Any]) {
        guard let socket, let data = try? JSONSerialization.data(withJSONObject: message), let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { _ in }
    }

    private func hello() {
        send(["t": "hello", "v": 1, "assistants": Assistants.shared.grants.map(\.id)])
        // Its pong is the first word back, which says the line is up.
        send(["t": "ping"])
        sendTools()
    }

    /// What each assistant's tools/list and initialize say while the Mac
    /// is away, asked of its `yab mcp` as it would be.
    private func sendTools() {
        for grant in Assistants.shared.grants {
            AssistantRunner.shared.listing(grant.id) { [weak self] tools, instructions in
                self?.send(["t": "tools", "assistant": grant.id, "tools": tools, "instructions": instructions])
            }
        }
    }

    private func heard(_ message: [String: Any]) {
        switch message["t"] as? String {
        case "call":
            guard let id = message["id"], let assistant = message["assistant"] as? String else { return }
            if let body = message["body"] as? [String: Any] {
                AssistantRunner.shared.call(assistant, body) { [weak self] reply in
                    guard let reply else { return }
                    self?.send(["t": "reply", "id": id, "body": reply])
                }
            } else if let batch = message["body"] as? [[String: Any]] {
                // A batch: each answered, all sent back together.
                var replies: [Int: [String: Any]] = [:]
                var left = batch.count
                for (at, body) in batch.enumerated() {
                    AssistantRunner.shared.call(assistant, body) { [weak self] reply in
                        if let reply { replies[at] = reply }
                        left -= 1
                        guard left == 0 else { return }
                        let all = replies.keys.sorted().compactMap { replies[$0] }
                        if !all.isEmpty { self?.send(["t": "reply", "id": id, "body": all]) }
                    }
                }
            }
        default:
            break
        }
    }

    // MARK: - keychain

    /// The host's secret and token: this Mac's keychain, or a file in a
    /// test world, as SyncKey keeps its own.
    private enum Keys {
        static var service: String { "\(Store.name) · assistants" }

        static func file(_ name: String) -> URL { Store.file("assistants-\(name).test") }

        static func query(_ name: String) -> [String: Any] {
            [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
             kSecAttrAccount as String: name, kSecAttrSynchronizable as String: kCFBooleanFalse as Any]
        }

        static func read(_ name: String) -> String? {
            if Store.testing { return (try? Data(contentsOf: file(name))).flatMap { String(data: $0, encoding: .utf8) } }
            var q = query(name)
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: CFTypeRef?
            guard Keychain.copySaved(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }

        static func write(_ value: String, _ name: String) {
            let data = Data(value.utf8)
            if Store.testing { try? data.write(to: file(name), options: .atomic); return }
            Keychain.save(query(name) as CFDictionary, data: data, attributes: [
                kSecAttrLabel as String: "\(Store.name) Assistants",
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ])
        }

        static func delete(_ name: String) {
            if Store.testing { try? FileManager.default.removeItem(at: file(name)); return }
            Keychain.removeSaved(query(name) as CFDictionary)
        }
    }
}

/// Keep Yab reachable (Settings › General, under Open at Login):
/// Yab opens at login and, while an assistant is linked or a routine is
/// set, the Mac doesn't fall asleep on its own while it is on power, so
/// assistants find it and routines run on time. A closed lid still sleeps,
/// as it does for everything else.
@MainActor
@Observable final class AssistantReach {
    static let shared = AssistantReach()

    var on: Bool {
        didSet {
            Store.settings.set(on, forKey: "assistants.reachable")
            if on, !OpenAtLogin.shared.on { OpenAtLogin.shared.set(true) }
            apply()
        }
    }

    @ObservationIgnored private var assertion: IOPMAssertionID = 0
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var routinesWatch: NSObjectProtocol?

    private init() {
        on = Store.settings.bool(forKey: "assistants.reachable")
        routinesWatch = NotificationCenter.default.addObserver(forName: Routines.changed, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AssistantReach.shared.apply() }
        }
    }

    /// Someone who comes back for Yab: a linked assistant, or a routine
    /// that hasn't reached its last day.
    private static var awaited: Bool {
        !Assistants.shared.grants.isEmpty || Routines.shared.all.contains { $0.until.map { $0 > Date() } ?? true }
    }

    /// Held while it should be, let go otherwise; looked at again every
    /// few minutes, as the power cable comes and goes.
    func apply() {
        let wanted = on && Self.awaited && Self.onPower
        if wanted, assertion == 0 {
            var id: IOPMAssertionID = 0
            if IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                           "Yab keeps this Mac reachable for your assistants and routines" as CFString, &id) == kIOReturnSuccess {
                assertion = id
            }
        } else if !wanted, assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
        if on, timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
                MainActor.assumeIsolated { AssistantReach.shared.apply() }
            }
        } else if !on {
            timer?.invalidate()
            timer = nil
        }
    }

    static var onPower: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let kind = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return true }
        return kind == kIOPSACPowerValue
    }
}
