import YabStore
import AppKit
import Combine
import Foundation
import SQLite3
import SyncKit
import Security

// Invite a Friend: a link a friend opens to get Yab
// (yetanotherbrowser.com/hi/CODE), the app icons friends unlock, and one
// best friend who shares a charm with you.
//
// The site keeps who invited whom (fast-web, app/api/invites): this Mac is
// a random ID made for invites alone, never Share daily activity's, and a
// first name, yours from Autofill › You, so your friend's page can say who
// sent it. A friend counts once their Yab opens with your link; for a best
// friend the site also keeps one bit, whether each of you has Yab open, and
// only while "Let them see when I'm in Yab" is on.
@MainActor
@Observable final class Invites {
    static let shared = Invites()

    /// What a friend's join unlocks, in order: the icon and how many friends it takes.
    static let ladder: [(style: AppIconStyle, friends: Int)] = [
        (.waxSeal, 1), (.bracelet, 3), (.ticket, 7), (.yearbook, 10),
    ]
    /// Invites a week: the site refills them on Monday.
    static let perWeek = 5

    /// One of the people you invited, as the site last said.
    struct Friend: Codable, Equatable, Identifiable {
        var id: String
        var name: String
        /// sent, opened (the page), joined (their Yab opened with the link)
        var state: String
        var at: Date?
        var best: Bool
    }

    /// Your best friend, once you have one.
    struct Best: Codable, Equatable {
        var name: String
        /// Their half's color; nil until they pick one.
        var color: String?
        /// Their Yab opened with your link.
        var joined: Bool
    }

    /// Who sent this Yab, when it came from someone's link.
    struct Received: Codable, Equatable {
        var from: String
        var best: Bool
        /// The sender's half, for a best friend.
        var color: String?
    }

    var message: String { didSet { save(message, "invite.message") } }
    var bestMessage: String { didSet { save(bestMessage, "invite.bestMessage") } }
    /// The color of your half, in your Dock and theirs.
    var myColor: String { didSet { save(myColor, "invite.myColor"); charmChanged(); pushColor() } }
    /// Whether your best friend may see that your Yab is open.
    var shares: Bool { didSet { save(shares, "invite.shares"); beat() } }
    /// Whether the charm parts a little while one of you is away.
    var showsAway: Bool { didSet { save(showsAway, "invite.showsAway"); charmChanged() } }
    private(set) var friends: [Friend] = []
    private(set) var joined = 0
    private(set) var left = Invites.perWeek
    private(set) var best: Best?
    private(set) var received: Received?
    /// Your best friend has Yab open, as the site said a moment ago.
    private(set) var bestHere = false
    /// The links, once the site made them.
    private(set) var friendLink: URL?
    private(set) var bestLink: URL?
    /// What went wrong the last time the site was asked, in words for the page.
    private(set) var problem: String?

    private var started = false
    @ObservationIgnored private var clock: Timer?
    /// Bumped when synced settings change what is unlocked; AppIconStyle.unlocked reads it.
    var revision = 0
    private var identityUnavailable = false
    private static var cachedInstallation: String?

    private init() {
        let settings = Store.settings
        message = settings.string(forKey: "invite.message")
            ?? "Here's Yab, the browser I was telling you about. You get an app icon nobody else can download."
        bestMessage = settings.string(forKey: "invite.bestMessage")
            ?? "Best friends in Yab? I kept the other half of the charm, this one's yours."
        myColor = settings.string(forKey: "invite.myColor") ?? "mint"
        shares = settings.object(forKey: "invite.shares") as? Bool ?? true
        showsAway = settings.object(forKey: "invite.showsAway") as? Bool ?? true
        friends = Self.decode([Friend].self, settings.data(forKey: "invite.friends")) ?? []
        joined = settings.integer(forKey: "invite.joined")
        left = settings.object(forKey: "invite.left") as? Int ?? Self.perWeek
        best = Self.decode(Best.self, settings.data(forKey: "invite.best"))
        received = Self.decode(Received.self, settings.data(forKey: "invite.received"))
        friendLink = settings.url(forKey: "invite.friendLink")
        bestLink = settings.url(forKey: "invite.bestLink")
    }

    // MARK: who is asking

    /// This Mac's existing invites ID, also kept through a data reinstall.
    /// A locked/unavailable backup must not silently allocate a second ID.
    static var installation: String? {
        get async {
            if !Store.testing, let cachedInstallation { return cachedInstallation }
            // Keychain can wait on securityd or another token operation. It
            // never holds up the UI thread, even on the first/recovery read.
            let resolved = await Task.detached(priority: .utility) {
                resolveInstallation(using: .current)
            }.value
            if !Store.testing, resolved.backedUp { cachedInstallation = resolved.id }
            return resolved.id
        }
    }

    enum InstallationBackup {
        case found(String), missing, unavailable
    }

    /// One transaction. Tests inject memory, never the real settings/keychain.
    struct InstallationStorage {
        var read: () -> String?
        var save: (String) -> Void
        var backup: () -> InstallationBackup
        var keep: (String) -> Bool
        var make: () -> String = { UUID().uuidString.lowercased() }
        var locked: (() -> Void) -> Void

        static var current: Self {
            let settings = Store.settings
            // A probe or unit test never needs even a synthetic keychain item.
            if Store.testing {
                return Self(read: { settings.string(forKey: "invite.installation") },
                            save: { settings.set($0, forKey: "invite.installation") },
                            backup: { .missing }, keep: { _ in false }, locked: { $0() })
            }
            return Self(read: { settings.string(forKey: "invite.installation") },
                        save: { settings.set($0, forKey: "invite.installation") },
                        backup: {
                            var query = installationItem
                            query[kSecReturnData as String] = true
                            query[kSecMatchLimit as String] = kSecMatchLimitOne
                            var found: AnyObject?
                            let status = Keychain.copySaved(query as CFDictionary, &found)
                            if status == errSecItemNotFound { return .missing }
                            guard status == errSecSuccess, let data = found as? Data,
                                  let value = String(data: data, encoding: .utf8) else { return .unavailable }
                            return .found(value)
                        }, keep: { id in
                            Keychain.save(installationItem as CFDictionary, data: Data(id.utf8)) == errSecSuccess
                        }, locked: { Keychain.quietly($0) })
        }
    }

    nonisolated private static var installationItem: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "\(Store.name) Invites",
         kSecAttrAccount as String: "installation"]
    }

    struct ResolvedInstallation {
        var id: String?
        var backedUp = false
    }

    nonisolated static func installation(using storage: InstallationStorage) -> String? {
        resolveInstallation(using: storage).id
    }

    nonisolated static func resolveInstallation(using storage: InstallationStorage) -> ResolvedInstallation {
        var result: String?
        var backedUp = false
        storage.locked {
            // Preferences are authoritative for an installed copy: an update
            // must not replace them with a stale backup or a synced owner.
            if let saved = storage.read(), UUID(uuidString: saved) != nil {
                backedUp = storage.keep(saved)
                result = saved
                return
            }
            switch storage.backup() {
            case .found(let saved):
                // A malformed backup is not evidence of a fresh install.
                guard UUID(uuidString: saved) != nil else { return }
                storage.save(saved)
                result = saved
                backedUp = true
            case .missing:
                let id = storage.make()
                guard UUID(uuidString: id) != nil else { return }
                storage.save(id)
                backedUp = storage.keep(id)
                result = id
            case .unavailable:
                break
            }
        }
        return ResolvedInstallation(id: result, backedUp: backedUp)
    }

    /// Your first name: Autofill › You's, else the Mac account's.
    static var firstName: String {
        let profile = Profile.load().name.trimmingCharacters(in: .whitespaces)
        let whole = profile.isEmpty ? NSFullUserName() : profile
        return whole.split(separator: " ").first.map(String.init) ?? ""
    }

    // MARK: what is unlocked

    /// Whether an icon from friends is yours: by how many friends joined,
    /// and Wax Seal for one who came from a link too.
    func unlocks(_ style: AppIconStyle) -> Bool {
        if style == .charm { return best?.joined == true || received?.best == true }
        guard let need = Self.ladder.first(where: { $0.style == style })?.friends else { return true }
        if style == .waxSeal, received != nil { return true }
        return joined >= need
    }

    /// The next icon friends unlock, and how many more it takes.
    var next: (style: AppIconStyle, more: Int)? {
        Self.ladder.first { !unlocks($0.style) }.map { ($0.style, $0.friends - joined) }
    }

    // MARK: the charm

    /// The two halves as the Dock draws them: yours on the left, theirs on
    /// the right (nil until they pick), and whether they are apart.
    var charm: (left: String, right: String?, apart: Bool) {
        if let received, received.best {
            // Theirs is the left half here: the one who sent it.
            return (received.color ?? "mint", myColor, apart)
        }
        return (myColor, best?.color, apart)
    }

    private var apart: Bool { showsAway && !bestHere }

    /// What the Dock tile reads in the Dock's own process, and a note to it.
    private func charmChanged() {
        let charm = charm
        if unlocks(.charm) || !Store.settings.bool(forKey: AppIconCatalog.charm.grantKey) {
            Store.settings.set(charm.left, forKey: "invite.charm.left")
            Store.settings.set(charm.right, forKey: "invite.charm.right")
            Store.settings.set(charm.apart, forKey: "invite.charm.apart")
        }
        if Store.settings.string(forKey: AppIconStyle.key) == AppIconStyle.charm.rawValue {
            AppIconStyle.charm.apply()
            AppIconStyle.announce()
        }
    }

    // MARK: copying a link

    /// The message with its link, onto the pasteboard, asking the site for
    /// the link first if this Mac has none yet. False when no link came.
    func copy(best wantsBest: Bool) async -> Bool {
        guard let link = await link(best: wantsBest) else { return false }
        let words = (wantsBest ? bestMessage : message).trimmingCharacters(in: .whitespacesAndNewlines)
        let text = words.contains(link.absoluteString) ? words : words + "\n" + link.absoluteString
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        await refresh()
        return true
    }

    func link(best wantsBest: Bool) async -> URL? {
        if let known = wantsBest ? bestLink : friendLink { return known }
        guard let installation = await Self.installation else {
            problem = "Couldn't reach yetanotherbrowser.com. Check the connection and try again."
            return nil
        }
        guard let answer = await Self.ask("api/invites/link", [
            "install": installation, "kind": wantsBest ? "best" : "friend",
            "from": Self.firstName, "color": myColor,
        ]), let url = (answer["url"] as? String).flatMap(URL.init(string:)) else {
            problem = "Couldn't reach yetanotherbrowser.com. Check the connection and try again."
            return nil
        }
        problem = nil
        if wantsBest {
            bestLink = url
            Store.settings.set(url, forKey: "invite.bestLink")
        } else {
            friendLink = url
            Store.settings.set(url, forKey: "invite.friendLink")
        }
        return url
    }

    /// A new best friend link: the old best friend keeps a whole Wax Seal.
    func changeBest() async {
        guard let installation = await Self.installation else {
            problem = "Couldn't reach yetanotherbrowser.com. Check the connection and try again."
            return
        }
        _ = await Self.ask("api/invites/best/reset", ["install": installation])
        bestLink = nil
        best = nil
        Store.settings.removeObject(forKey: "invite.bestLink")
        Store.settings.removeObject(forKey: "invite.best")
        charmChanged()
        await refresh()
    }

    // MARK: the site

    func start() {
        guard !started, !Store.testing, Updater.site != nil else { return }
        started = true
        Task { await claimIfInvited() }
        Task { await refresh() }
        // While a best friend is there, each of you says once a minute
        // that Yab is open, and hears whether the other's is.
        clock = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.beat()
                self?.lookAtPost()
                // A first launch with a locked keychain still has its valid
                // preferences. Retry the quiet backup after unlock, once a
                // minute, and stop querying after a successful persistence.
                if Self.cachedInstallation == nil { Task { _ = await Self.installation } }
                if let self, self.identityUnavailable {
                    Task { await self.claimIfInvited(); await self.refresh() }
                }
            }
        }
        clock?.tolerance = 10
    }

    /// What the site knows: friends, how many joined, invites left, the best friend.
    func refresh() async {
        guard let installation = await Self.installation else { identityUnavailable = true; return }
        identityUnavailable = false
        guard let answer = await Self.ask("api/invites/status", ["install": installation]) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let list = answer["friends"], let data = try? JSONSerialization.data(withJSONObject: list),
           let friends = try? decoder.decode([Friend].self, from: data) {
            self.friends = friends
            Store.settings.set(try? Self.encoder.encode(friends), forKey: "invite.friends")
        }
        if let joined = answer["joined"] as? Int {
            let was = self.joined
            self.joined = joined
            Store.settings.set(joined, forKey: "invite.joined")
            if joined > was { unlocked(from: was) }
        }
        PostReward.shared.update(answer)
        if let left = answer["left"] as? Int {
            self.left = left
            Store.settings.set(left, forKey: "invite.left")
        }
        if let best = answer["best"] as? [String: Any], let name = best["name"] as? String {
            let was = self.best
            self.best = Best(name: name, color: best["color"] as? String, joined: best["joined"] as? Bool ?? false)
            Store.settings.set(try? Self.encoder.encode(self.best), forKey: "invite.best")
            if was?.joined != true, self.best?.joined == true { bestJoined() }
            bestHere = best["here"] as? Bool ?? false
        } else if answer["best"] is NSNull {
            best = nil
            Store.settings.removeObject(forKey: "invite.best")
        }
        charmChanged()
    }

    private var lookedAtPost = Date.distantPast

    /// While a post waits for its day: ask every half hour, and once it opens.
    private func lookAtPost() {
        guard let live = PostReward.shared.live else { return }
        let due = Date().timeIntervalSince(lookedAtPost) > 30 * 60
            || (live.opens.map { $0 < Date() && lookedAtPost < $0 } ?? false)
        guard due else { return }
        lookedAtPost = Date()
        Task { await refresh() }
    }

    /// Once a minute: I'm here (if allowed), and is my best friend?
    private func beat() {
        guard started, best != nil || received?.best == true else { return }
        Task {
            guard let installation = await Self.installation,
                  let answer = await Self.ask("api/invites/here", ["install": installation, "shares": shares]) else { return }
            let here = answer["here"] as? Bool ?? false
            if here != bestHere {
                bestHere = here
                charmChanged()
            }
        }
    }

    private func pushColor() {
        guard started else { return }
        Task {
            guard let installation = await Self.installation else { return }
            _ = await Self.ask("api/invites/color", ["install": installation, "color": myColor])
        }
    }

    /// New icons, said once in the corner, with a way to wear it.
    private func unlocked(from was: Int) {
        guard let icon = Self.ladder.last(where: { $0.friends > was && $0.friends <= joined }),
              let browser = BrowserWindows.shared.activeBrowser else { return }
        browser.announce("\(icon.style.title) is unlocked", mark: "brand.blobplus")
    }

    private func bestJoined() {
        guard let best, let browser = BrowserWindows.shared.activeBrowser else { return }
        browser.announce("\(best.name) opened Yab. Your halves are joined.", mark: "brand.blobplus")
        AppIconStyle.charm.choose()
    }

    // MARK: arriving from a link

    /// On the first launch: the link this Yab was downloaded from, as macOS
    /// kept it with the download (the quarantine event of the app itself) or
    /// the friend's page left it in the clipboard, and if it was someone's
    /// invite, tell the site and keep who sent it.
    func claimIfInvited() async {
        guard received == nil, Store.settings.object(forKey: "invite.claimed") == nil else { return }
        guard let installation = await Self.installation else { return }
        Store.settings.set(true, forKey: "invite.claimed")
        var found = Self.arrivalCode()
        if found == nil { found = await Self.clipboardCode() }
        guard let code = found else { return }
        guard let answer = await Self.ask("api/invites/claim", [
            "install": installation, "code": code, "name": Self.firstName,
        ]), let from = answer["from"] as? String else { return }
        let best = answer["kind"] as? String == "best"
        received = Received(from: from, best: best, color: answer["color"] as? String)
        Store.settings.set(try? Self.encoder.encode(received), forKey: "invite.received")
        if best {
            if let mine = answer["picked"] as? String { myColor = mine }
            // A best friend's half goes into the Dock by itself.
            AppIconStyle.charm.choose()
        }
        charmChanged()
    }

    /// The invite code in the link this app was downloaded from, if any:
    /// `/hi/CODE` in the page, or `c=CODE` on the file's own address.
    static func arrivalCode() -> String? {
        if let forced = ProcessInfo.processInfo.environment["YAB_INVITE_CODE"], !forced.isEmpty { return forced }
        for address in downloadedFrom() {
            if let code = code(in: address) { return code }
        }
        return nil
    }

    /// The friend's page copies its own address on Download, because macOS 26
    /// keeps no address with a download any more. Looked at once: only when
    /// the clipboard holds a web address, which the system tells without
    /// reading it, and only our own site's /hi/CODE counts.
    static func clipboardCode() async -> String? {
        let board = NSPasteboard.general
        guard board.accessBehavior != .alwaysDeny,
              let patterns = try? await board.detectedPatterns(for: [\.probableWebURL]),
              patterns.contains(\.probableWebURL),
              let text = board.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              text.count <= 512, let host = URL(string: text)?.host?.lowercased(),
              host == "yetanotherbrowser.com" || host == "www.yetanotherbrowser.com" || host == Updater.site?.host?.lowercased()
        else { return nil }
        return code(in: text)
    }

    static func code(in address: String) -> String? {
        guard let url = URL(string: address), let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        if let item = components.queryItems?.first(where: { $0.name == "c" })?.value, valid(item) { return item }
        let parts = url.pathComponents
        if let at = parts.firstIndex(of: "hi"), at + 1 < parts.count, valid(parts[at + 1]) { return parts[at + 1] }
        return nil
    }

    private static func valid(_ code: String) -> Bool {
        (4 ... 40).contains(code.count) && code.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
    }

    /// The addresses macOS kept for this app's download: its quarantine
    /// attribute names an event in the user's QuarantineEventsV2, which
    /// holds the file's address and the page it came from.
    private static func downloadedFrom() -> [String] {
        let path = Bundle.main.bundleURL.path
        let size = getxattr(path, "com.apple.quarantine", nil, 0, 0, 0)
        guard size > 0 else { return [] }
        var bytes = [UInt8](repeating: 0, count: size)
        guard getxattr(path, "com.apple.quarantine", &bytes, size, 0, 0) == size,
              let value = String(bytes: bytes, encoding: .utf8) else { return [] }
        let fields = value.split(separator: ";", omittingEmptySubsequences: false)
        guard fields.count >= 4 else { return [] }
        let event = String(fields[3])
        let database = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2").path
        var db: OpaquePointer?
        guard sqlite3_open_v2(database, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        let query = "select LSQuarantineDataURLString, LSQuarantineOriginURLString from LSQuarantineEvent where LSQuarantineEventIdentifier = ?"
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, event, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        var out: [String] = []
        if sqlite3_step(statement) == SQLITE_ROW {
            for column in 0 ..< 2 {
                if let text = sqlite3_column_text(statement, Int32(column)) { out.append(String(cString: text)) }
            }
        }
        return out
    }

    /// The picture that stands where Welcome's mark does: the charm for a
    /// best friend, Wax Seal for a friend.
    static func giftPicture(_ received: Received) -> CGImage? {
        let image: NSImage?
        if received.best, let resources = AppIconStyle.resources {
            image = CharmDraw.image(resources: resources, left: received.color ?? "mint",
                                    right: shared.myColor, apart: false)
        } else {
            image = AppIconStyle.waxSeal.image(dark: false)
        }
        var rect = NSRect(x: 0, y: 0, width: 1024, height: 1024)
        return image?.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    // MARK: plumbing

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return URLSession(configuration: configuration)
    }()

    /// One question to the site, as JSON both ways; nil on any failure, or
    /// on any status but those accepted (a 422 carries the reason in words).
    static func ask(_ path: String, _ body: [String: Any], accepting: Set<Int> = [200]) async -> [String: Any]? {
        guard let site = Updater.site else { return nil }
        var request = URLRequest(url: site.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpShouldHandleCookies = false
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        guard let (data, response) = try? await session.data(for: request),
              accepting.contains((response as? HTTPURLResponse)?.statusCode ?? 0) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private func save(_ value: Any, _ key: String) { Store.settings.set(value, forKey: key) }

    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data?) -> T? {
        guard let data else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }
}
