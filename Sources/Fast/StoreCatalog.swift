import AppKit
import Foundation
import UserNotifications

/// The Store's one catalog (docs/store.md): the site's catalog.json, kept
/// for six hours, over the shelf shipped with Yab. The field's Store place,
/// Site Controls' Popular row and the website all read the same items and
/// the same pinned revisions.
@MainActor
@Observable final class StoreCatalog {
    static let shared = StoreCatalog()

    struct Check: Codable, Equatable {
        var state: String
        var at: Date?
        var note: String?
    }

    struct Pictures: Codable, Equatable {
        var before: String?
        var after: String?
    }

    struct Version: Codable, Equatable {
        var commit: String?
        var date: String?
        var note: String?
    }

    /// Who passed a code release in yab-plugins, and at which commit.
    struct Reviewed: Codable, Equatable {
        var by: String
        var date: String
        var commit: String
    }

    struct Item: Codable, Identifiable, Equatable {
        let id: String
        var name: String
        var intent: String
        var sites: [String]
        var host: String
        var rung: String
        var rights: String
        var revision: String?
        var commit: String?
        var by: String
        var picks: Bool?
        var added: String?
        var fixed: String?
        var check: Check?
        var kept: Int?
        var pictures: Pictures?
        var versions: [Version]?
        var reviewed: Reviewed?

        var plugin: Bool { rung != "Look" }
    }

    private struct File: Codable {
        var format: Int
        var generated: Date?
        var items: [Item]
    }

    private(set) var items: [Item]
    /// Where these items came from: catalog.json's address as it answered,
    /// nil for the shelf shipped with Yab. Code installs only from the site.
    @ObservationIgnored private(set) var origin: URL?
    /// Bumped when items or pictures change, for the field's memo.
    private(set) var version = 0 {
        // An open Store place draws again (its rows' memo keys on the stock's version).
        didSet { for browser in BrowserWindows.shared.browsers where browser.query.place == .store { browser.query.stock.version += 1 } }
    }
    @ObservationIgnored private var fetched: Date?
    @ObservationIgnored private var fetching = false
    @ObservationIgnored private var pictures: [String: NSImage] = [:]
    @ObservationIgnored private var loading: Set<String> = []

    private static let cache = Store.file("store-catalog.json")
    private static let originsKey = "store.origins"
    private static let sourceKey = "store.catalog.origin"
    private static let voterKey = "store.voter"
    static let picks: Set<String> = ["youtube-no-shorts", "wikipedia-readable", "github-readable-code", "hn-readable", "reddit-hide-promoted"]

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return URLSession(configuration: configuration)
    }()

    private init() {
        if let data = try? Data(contentsOf: Self.cache), let cached = Self.decode(data) {
            items = cached
            origin = Store.settings.string(forKey: Self.sourceKey).flatMap(URL.init(string:))
            fetched = (try? Self.cache.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        } else {
            items = Self.bundled
        }
    }

    /// A catalog.json's items (format 1, docs/store.md); nil for anything else.
    nonisolated static func decode(_ data: Data) -> [Item]? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(File.self, from: data), file.format == 1, !file.items.isEmpty else { return nil }
        return file.items
    }

    /// The shelf shipped with Yab, for a first launch or no network: no
    /// check and no count, so the rows say nothing about either.
    static var bundled: [Item] {
        BoostCatalog.entries.map { entry in
            let host = bare(entry.site)
            return Item(id: entry.id, name: entry.name, intent: entry.intent, sites: [entry.site], host: host, rung: "Look",
                        rights: "Change how \(host) looks. No code runs.", revision: nil, commit: nil, by: "Yab",
                        picks: picks.contains(entry.id), added: nil, fixed: nil, check: nil, kept: nil, pictures: nil, versions: nil, reviewed: nil)
        }
    }

    /// A host as the Store writes it: without its www.
    nonisolated static func bare(_ host: String) -> String { host.hasPrefix("www.") ? String(host.dropFirst(4)) : host }

    // MARK: reading

    func item(_ id: String) -> Item? { items.first { $0.id == id } }

    /// Items for a site, by Kept.
    func on(_ host: String?) -> [Item] {
        guard let host, !host.isEmpty else { return [] }
        let bare = Self.bare(host)
        return items.filter { $0.host == bare || $0.sites.contains(host) || $0.sites.map(Self.bare).contains(bare) }.sorted { ($0.kept ?? 0) > ($1.kept ?? 0) }
    }

    /// What the daily check says, in words; nothing when it never ran.
    func checked(_ item: Item) -> String? {
        guard let check = item.check else { return nil }
        switch check.state {
        case "works":
            guard let at = check.at, Date().timeIntervalSince(at) < 36 * 60 * 60 else { return nil }
            return "Works today"
        case "fix": return "Needs Fix"
        case "unchecked": return check.note.map { "Not checked: \($0)" } ?? "Not checked"
        default: return nil
        }
    }

    func kept(_ item: Item) -> String? {
        guard let kept = item.kept else { return nil }
        return kept.formatted() + (kept == 1 ? " person" : " people")
    }

    /// Where a listing lives on the website.
    func page(_ item: Item) -> URL? {
        guard let site = Updater.site ?? URL(string: "https://yetanotherbrowser.com/") else { return nil }
        return site.appendingPathComponent("store").appendingPathComponent(item.id)
    }

    // MARK: the catalog from the site

    func refresh(force: Bool = false) {
        guard !fetching, !Store.testing else { return }
        if !force, let fetched, Date().timeIntervalSince(fetched) < 6 * 60 * 60 { return }
        guard let site = Updater.site ?? URL(string: "https://yetanotherbrowser.com/") else { return }
        fetching = true
        Task {
            defer { fetching = false }
            var request = URLRequest(url: site.appendingPathComponent("store/catalog.json"), timeoutInterval: 15)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            guard let (data, response) = try? await Self.session.data(for: request),
                  let http = response as? HTTPURLResponse, http.statusCode == 200, data.count < 5_000_000,
                  let fresh = Self.decode(data) else { return }
            fetched = Date()
            try? data.write(to: Self.cache, options: .atomic)
            origin = http.url
            Store.settings.set(http.url?.absoluteString, forKey: Self.sourceKey)
            if fresh != items {
                items = fresh
            }
            // A catalog just fetched vouches for code again even when its
            // listings are unchanged. Wake sync installs waiting on age.
            version += 1
            await updateKept()
        }
    }

    /// A test run's catalog from a file (bench), as if read from `origin`:
    /// a test run never fetches the catalog itself.
    func adoptForTests(_ data: Data, origin: URL) -> Bool {
        guard Store.testing, let read = Self.decode(data) else { return false }
        items = read
        self.origin = origin
        fetched = Date()
        version += 1
        return true
    }

    /// Read from the site in the last six hours: what sync vouches code by.
    var fresh: Bool {
        guard origin != nil, let fetched else { return false }
        return Date().timeIntervalSince(fetched) < 6 * 60 * 60
    }

    /// A listing's picture, fetched once; nil until it comes.
    func picture(_ item: Item, after: Bool = true) -> NSImage? {
        _ = version
        guard let path = after ? item.pictures?.after : item.pictures?.before,
              let base = Updater.site ?? URL(string: "https://yetanotherbrowser.com/"),
              let url = URL(string: path, relativeTo: base)?.absoluteURL, url.scheme == "https" else { return nil }
        let key = url.absoluteString
        if let image = pictures[key] { return image }
        if !loading.contains(key) {
            loading.insert(key)
            Task {
                defer { loading.remove(key) }
                guard let (data, response) = try? await Self.session.data(for: URLRequest(url: url, timeoutInterval: 20)),
                      (response as? HTTPURLResponse)?.statusCode == 200, data.count < 4_000_000,
                      let image = NSImage(data: data) else { return }
                if pictures.count > 60 { pictures.removeAll() }
                pictures[key] = image
                version += 1
            }
        }
        return nil
    }

    /// The sites' own marks, from the Store's site rather than the sites
    /// themselves, so opening the Store tells no site anything. Once a launch.
    @ObservationIgnored private var iconsAsked = false
    func fetchIcons() {
        guard !iconsAsked, let base = Updater.site ?? URL(string: "https://yetanotherbrowser.com/") else { return }
        iconsAsked = true
        var seen = Set<String>()
        let wanted = items.filter { item in
            seen.insert(item.host).inserted && (item.sites + [item.host]).contains { Favicons.shared.cached($0) == nil }
        }
        guard !wanted.isEmpty else { return }
        Task {
            for item in wanted {
                let names = Array(Set([item.host, Browser.site(item.host)]))
                // The shelf shipped with Yab carries its sites' marks.
                if let file = names.lazy.compactMap({ Bundle.main.url(forResource: $0, withExtension: "png", subdirectory: "StoreIcons") }).first,
                   let data = try? Data(contentsOf: file) {
                    for host in Set(item.sites + [item.host]) { await Favicons.shared.adopt(data, for: host) }
                    continue
                }
                for name in names {
                    let url = base.appendingPathComponent("store/favicons/\(name).png")
                    guard let (data, response) = try? await Self.session.data(for: URLRequest(url: url, timeoutInterval: 15)),
                          (response as? HTTPURLResponse)?.statusCode == 200, data.count < 200_000 else { continue }
                    for host in Set(item.sites + [item.host]) { await Favicons.shared.adopt(data, for: host) }
                    break
                }
            }
            version += 1
        }
    }

    // MARK: trying

    /// Opens the listing's site in a tab of its own with the boost on trial:
    /// the Keep card there is the only way it stays. Code (Page, Tool, App)
    /// comes only as the reviewed revision this catalog names.
    func tryOn(_ item: Item, in browser: Browser) {
        Task {
            do {
                if let revision = item.revision, BoostShare.validRevision(revision) {
                    if item.plugin, let refusal = Self.codeRefusal(item, origin: origin, listed: items) { throw BoostPackage.Invalid(refusal) }
                    // Kept already: the listing's release on trial under the kept name.
                    let kept = keptPackage(item.id)
                    let package = try await BoostShare.fetch(revision, in: browser, id: kept, reviewed: item.plugin)
                    if kept == nil { note(packageID: package.id, catalogID: item.id, revision: revision) }
                    trying(package, revision: revision)
                } else if let entry = BoostCatalog.entries.first(where: { $0.id == item.id }) {
                    try await Self.stage(entry, in: browser)
                    note(packageID: entry.id, catalogID: item.id)
                } else {
                    throw BoostPackage.Invalid("This boost is not available right now.")
                }
            } catch {
                browser.announce(error.localizedDescription, mark: "exclamationmark.triangle")
            }
        }
    }

    /// Why this listing's code may not be installed, or nil when it may:
    /// it names a reviewed release, the catalog came from
    /// yetanotherbrowser.com over HTTPS, and the catalog still lists that
    /// revision. The package itself is checked against the revision when it
    /// comes (BoostShare.read).
    nonisolated static func codeRefusal(_ item: Item, origin: URL?, listed: [Item]) -> String? {
        guard let reviewed = item.reviewed, !reviewed.by.isEmpty, !reviewed.date.isEmpty, !reviewed.commit.isEmpty else {
            return "This plugin has no reviewed release in the Store yet."
        }
        guard let origin, origin.scheme == "https", origin.host == "yetanotherbrowser.com", origin.port == nil else {
            return "Plugins with code install only from the Store at yetanotherbrowser.com."
        }
        guard let revision = item.revision, BoostShare.validRevision(revision),
              listed.contains(where: { $0.id == item.id && $0.revision == revision && $0.reviewed == reviewed }) else {
            return "This release is not the one the Store lists."
        }
        return nil
    }

    /// The kept boost that came from this listing, by package id.
    func keptPackage(_ catalogID: String) -> String? {
        let origins = Store.settings.dictionary(forKey: Self.originsKey) as? [String: [String: Any]] ?? [:]
        let records = Set(Boosts.shared.records.map(\.id))
        return origins.keys.sorted().first { origins[$0]?["store"] as? String == catalogID && records.contains($0) }
    }

    /// A kept boost whose newer release asks for more: its listing, until
    /// the person keeps that release.
    func pending(_ packageID: String) -> Item? {
        let origins = Store.settings.dictionary(forKey: Self.originsKey) as? [String: [String: Any]] ?? [:]
        guard let value = origins[packageID], value["pending"] is String, let id = value["store"] as? String else { return nil }
        return item(id)
    }

    /// The newer release of a kept boost on trial, under the kept one's
    /// name, so Keep replaces it (and turns it back on).
    func review(_ packageID: String, in browser: Browser) {
        if let item = pending(packageID) { tryOn(item, in: browser) }
    }

    /// The release on trial, so a Keep of exactly those files moves the
    /// kept boost to it.
    private func trying(_ package: BoostPackage, revision: String) {
        var origins = Store.settings.dictionary(forKey: Self.originsKey) as? [String: [String: Any]] ?? [:]
        guard origins[package.id] != nil,
              let digest = try? BoostShare.digest(.init(format: 1, id: package.id, sites: package.sites, files: package.files)) else { return }
        origins[package.id]?["trying"] = revision
        origins[package.id]?["digest"] = digest
        Store.settings.set(origins, forKey: Self.originsKey)
    }

    /// Called by Keep: a Store release kept as it came is now the kept one.
    func kept(_ packageID: String, digest: String?) {
        var origins = Store.settings.dictionary(forKey: Self.originsKey) as? [String: [String: Any]] ?? [:]
        guard var value = origins[packageID], let revision = value["trying"] as? String else { return }
        if let digest, value["digest"] as? String == digest {
            value["revision"] = revision
            value["pending"] = nil
        }
        value["trying"] = nil; value["digest"] = nil
        origins[packageID] = value
        Store.settings.set(origins, forKey: Self.originsKey)
    }

    static func stage(_ entry: BoostCatalog.Entry, in browser: Browser) async throws {
        let owner = Agents.shared.scripted()
        let tab = browser.benchOpen(entry.url, space: nil)
        tab.agent = owner.id
        browser.select(tab)
        for _ in 0..<150 {
            if tab.address?.host == entry.site, !tab.page.isLoading { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        // Words for the person, not the agent's rule about sites.
        if let host = tab.address?.host, host != entry.site {
            throw BoostPackage.Invalid("\(entry.name) is for \(Browser.site(entry.site)), and the page went to \(host). Open \(Browser.site(entry.site)) and try it there")
        }
        _ = try await Boosts.shared.stage(name: entry.id, changes: entry.files.mapValues { $0 as Any }, sites: [entry.site], tab: tab, session: owner.id)
    }

    func remix(_ item: Item, in browser: Browser) {
        guard Agents.ready else { browser.boostNeedsAgent(); return }
        guard let site = item.sites.first, let url = URL(string: "https://" + site + "/") else { return }
        let tab = browser.open(url, foreground: true)
        browser.startBoost("Remix this Store boost for \(item.host) (\(item.id)): \(item.intent)\nWhat I want to change: ", about: tab)
    }

    func check(_ item: Item, in browser: Browser) {
        let source = "https://github.com/yetanotherbrowser/yab-plugins/tree/main/" + (item.plugin ? "plugins/" : "boosts/") + item.id
        browser.startBoost("Read the Store boost \(item.name) (\(source)) and tell me in plain words what it changes, what it can reach, and anything risky. \(item.rights)", about: browser.boostPage)
    }

    /// With a site in front, for that site; with none, the agent opens
    /// the one the words name (it did nothing before, register #447).
    func build(_ words: String, in browser: Browser) {
        let tab = browser.boostPage
        let site = tab?.address?.host.map { " for " + $0 } ?? ""
        browser.startBoost("Create a boost" + site + ": " + words, about: tab)
    }

    // MARK: requests

    /// An id for votes alone, apart from the daily activity's.
    var voter: String {
        if let saved = Store.settings.string(forKey: Self.voterKey) { return saved }
        let id = UUID().uuidString.lowercased()
        Store.settings.set(id, forKey: Self.voterKey)
        return id
    }

    /// Adds a request to the Store's board and votes for it.
    func ask(_ title: String, host: String?) async -> Bool {
        guard let site = Updater.site ?? URL(string: "https://yetanotherbrowser.com/") else { return false }
        var request = URLRequest(url: site.appendingPathComponent("api/store/requests"), timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(voter, forHTTPHeaderField: "X-Yab-Voter")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["title": title, "host": host.map(Browser.site) ?? ""])
        guard let (_, response) = try? await Self.session.data(for: request) else { return false }
        return (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// Once a day: requests this Mac voted for that reached the Store, each
    /// told once.
    func checkRequests() {
        guard !Store.testing, let site = Updater.site, Store.settings.string(forKey: Self.voterKey) != nil else { return }
        let day = String(Date().timeIntervalSince1970 / 86_400)
        guard Store.settings.string(forKey: "store.requests.day") != day else { return }
        Task {
            var request = URLRequest(url: site.appendingPathComponent("api/store/requests/mine"), timeoutInterval: 15)
            request.setValue(voter, forHTTPHeaderField: "X-Yab-Voter")
            guard let (data, response) = try? await Self.session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rows = body["items"] as? [[String: Any]] else { return }
            Store.settings.set(day, forKey: "store.requests.day")
            var told = Set(Store.settings.stringArray(forKey: "store.requests.told") ?? [])
            for row in rows where row["status"] as? String == "store" {
                let id = "\(row["id"] ?? "")"
                guard !told.contains(id), let title = row["title"] as? String else { continue }
                told.insert(id)
                let boost = (row["boost"] as? String).flatMap(item)
                tell(boost.map { "\($0.name) is in the Store: \(title)" } ?? "In the Store now: \(title)", id: "store.request." + id)
            }
            Store.settings.set(Array(told), forKey: "store.requests.told")
        }
    }

    /// Said in Yab when it is in front, by the Mac only where macOS already
    /// lets Yab speak (never asked for here).
    private func tell(_ words: String, id: String) {
        if NSApp.isActive, let browser = BrowserWindows.shared.browsers.first {
            browser.announce(words, mark: "storefront")
            return
        }
        Task {
            guard await MailNotifySystem().permission() == .allowed else { return }
            let content = UNMutableNotificationContent()
            content.title = "Yab Store"
            content.body = words
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }

    /// Store boosts kept here whose listing moved to a newer revision take
    /// it when it may do no more than the kept one; code only from a
    /// reviewed release. One that asks for more turns the kept one off and
    /// waits in Site Controls for Review.
    private func updateKept() async {
        let origins = Store.settings.dictionary(forKey: Self.originsKey) as? [String: [String: Any]] ?? [:]
        var updated: [String: String] = [:], held: [String: String] = [:]
        for (package, value) in origins {
            guard let id = value["store"] as? String, let listing = item(id),
                  let revision = listing.revision, BoostShare.validRevision(revision), value["revision"] as? String != revision,
                  value["pending"] as? String != revision,
                  Boosts.shared.records.contains(where: { $0.id == package && $0.enabled }) else { continue }
            let code = listing.plugin
            if code, Self.codeRefusal(listing, origin: origin, listed: items) != nil { continue }
            do {
                let fresh = try BoostShare.read(await BoostShare.download(revision), id: package, reviewed: code ? revision : nil)
                switch try await Boosts.shared.update(package, to: fresh) {
                case .applied: updated[package] = revision
                case .held: held[package] = revision
                }
            } catch {
                continue
            }
        }
        // Read again: the list may have changed while packages came.
        guard !updated.isEmpty || !held.isEmpty else { return }
        var now = Store.settings.dictionary(forKey: Self.originsKey) as? [String: [String: Any]] ?? [:]
        for (package, revision) in updated { now[package]?["revision"] = revision; now[package]?["pending"] = nil }
        for (package, revision) in held { now[package]?["pending"] = revision }
        Store.settings.set(now, forKey: Self.originsKey)
    }

    // MARK: kept

    /// Which kept boosts came from the Store, by package id, and since when.
    private func note(packageID: String, catalogID: String, revision: String? = nil) {
        var origins = Store.settings.dictionary(forKey: Self.originsKey) as? [String: [String: Any]] ?? [:]
        origins[packageID] = ["store": catalogID, "revision": revision ?? ""]
        Store.settings.set(origins, forKey: Self.originsKey)
    }

    /// The listing and release a kept boost came from, by package id, for
    /// sync to send the release instead of the files (SyncAddons).
    func origin(of packageID: String) -> (store: String, revision: String)? {
        let origins = Store.settings.dictionary(forKey: Self.originsKey) as? [String: [String: Any]] ?? [:]
        guard let value = origins[packageID], let store = value["store"] as? String,
              let revision = value["revision"] as? String, BoostShare.validRevision(revision) else { return nil }
        return (store, revision)
    }

    /// A release kept on another Mac and put in here as it came.
    func noteSynced(_ packageID: String, catalog: String, revision: String) {
        note(packageID: packageID, catalogID: catalog, revision: revision)
    }

    /// Store boosts kept at least a week and still on, for the kept count
    /// Activity sends apart from the day's (docs/store.md, Kept). Nothing
    /// else about them.
    func keptForActivity() -> [String] {
        var origins = Store.settings.dictionary(forKey: Self.originsKey) as? [String: [String: Any]] ?? [:]
        let records = Boosts.shared.records
        var out: [String] = []
        for (package, value) in origins {
            guard let store = value["store"] as? String else { continue }
            guard let record = records.first(where: { $0.id == package }) else {
                // Tried and never kept, or deleted: forgotten after a month.
                if let since = value["since"] as? Double, Date().timeIntervalSince1970 - since > 30 * 86_400 { origins[package] = nil }
                continue
            }
            var row = value
            let since = row["since"] as? Double ?? Date().timeIntervalSince1970
            row["since"] = since
            origins[package] = row
            if record.enabled, Date().timeIntervalSince1970 - since >= 7 * 86_400 { out.append(store) }
        }
        Store.settings.set(origins, forKey: Self.originsKey)
        return Array(Set(out)).sorted()
    }
}
