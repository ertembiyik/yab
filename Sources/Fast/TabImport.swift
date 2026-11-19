import AppKit
import Foundation
import SwiftUI

// Bringing over what another browser keeps, as places: each of Arc's spaces,
// each profile of Chrome, Dia and the rest. A place becomes a space here,
// with its pins, and, if asked, what it has open; Arc's spaces keep their
// emoji, color and grain, and a place signed in as a profile of its own is
// a space with sign-ins of its own (Browser.bring). One place and it goes
// into the row on screen, no space made.
//
// Arc keeps its spaces in StorableSidebar.json beside its Chromium folder,
// Dia its favorites, pinned folders and windows in each profile's tabs.db
// (DiaTabsDB), once in StorableProfileContainers.json; Chrome, Brave, Edge and the rest mark pins in the session file
// Chromium writes as it goes. All of it is read from disk, whether or not
// the browser is running.

enum TabImport {
    struct Split: Hashable {
        var first: URL
        var second: URL
        var share: Double = 0.5
    }
    struct Entry: Hashable {
        let url: URL
        let title: String
        /// A name of its own, given in the other browser (Arc's renamed
        /// tabs): the tab's name here, which the page's title never
        /// replaces (Tab.name).
        var name: String? = nil
        /// The folder it was in, among what the other browser keeps: Arc's
        /// folders in a space's pinned half, a nested one's path in its
        /// name ("Analitycs › SEO") for lists that show one line.
        var folder: String? = nil
        /// That folder and the folders it is in, by name from the top down:
        /// nil but for one in another (Arc's).
        var path: [String]? = nil
        /// When it was made there, if the browser says: Arc does.
        var added: Date? = nil
    }

    /// One of the other browser's places: an Arc space, a Chrome profile.
    struct Place: Identifiable, Hashable {
        /// Where it came from, kept with the space it becomes, so bringing
        /// it in again finds that space whatever it is called now:
        /// "Arc:<space id>", "Chrome:Profile 1".
        let id: String
        var name: String
        /// Arc's own emoji for the space; guessed from the name otherwise.
        var emoji: String?
        /// Arc's color for the space, as hex, and how much grain it wears,
        /// 0 for none.
        var color: String?
        var grain: Double?
        var colors: [String] = []
        /// The browser's profile folder it is signed in as, "Default",
        /// "Profile 1": whose cookies are its.
        var profile: String
        /// Signed in as the browser's first profile, which yab's own first
        /// space shares; any other is a space with sign-ins of its own.
        var shared: Bool
        /// A profile, not a space: the first one goes into Personal rather
        /// than a space of its own name.
        var isProfile = false
        /// Pins here, a row of marks: Arc's favorites, Chrome's and Dia's
        /// pinned tabs, all of them marks there too.
        var pinned: [Entry]
        /// Tabs that stay, rows with their titles: what Arc pins in a
        /// space, which Arc draws as rows, not marks. A space of them as
        /// marks here was a wall of a hundred icons.
        var kept: [Entry] = []
        /// What it has open now, brought only if asked.
        var open: [Entry]
        var splits: [Split] = []
        /// Its tabs that can't come: extension pages with no web address
        /// in them. Counted, so they are said, not lost without a word.
        var left = 0

        var isEmpty: Bool { pinned.isEmpty && kept.isEmpty && open.isEmpty }

        /// A profile signed in on its own: a space here even with nothing
        /// in it, as two profiles there are two spaces here.
        var apart: Bool { isProfile && !shared }

        /// The profile it is signed in as, as Space.signedInAs keeps it:
        /// "Dia:Profile 1", the browser's name from the front of `id`.
        var signIn: String { "\(id.prefix { $0 != ":" }):\(profile)" }

        /// Something to bring: pins or tabs that stay, or what is open
        /// when the open ones are wanted too.
        func holds(withOpen: Bool) -> Bool { !pinned.isEmpty || !kept.isEmpty || (withOpen && !open.isEmpty) }

        /// Brought when picked: something to bring, or a profile of its
        /// own, which comes as its space with its sign-ins.
        func comes(withOpen: Bool) -> Bool { holds(withOpen: withOpen) || apart }
    }

    /// Why a browser's tabs couldn't be read, each said in its own words
    /// (`explain`) and counted in feedback's diagnostics by its `code`.
    enum Trouble: Error, Equatable {
        /// No tab file where the browser keeps one, and no session to
        /// read them from instead.
        case missing
        /// The tab file is there, but it couldn't be opened: macOS kept
        /// it from Yab, or reading it failed.
        case unreadable
        /// The tab file isn't JSON, or not whole.
        case damaged
        /// The tab file is JSON in a shape this Yab doesn't know: Dia
        /// changed it. Its version, when it says one.
        case newer(version: Int?)
        /// The browser's data folder is there, but listing it failed:
        /// macOS kept it from Yab, or the read failed.
        case folderUnreadable

        /// 1 missing, 2 damaged, 3 unreadable, 4 folder unreadable, 1000
        /// and the version for a newer format.
        var code: Int {
            switch self {
            case .missing: return 1
            case .damaged: return 2
            case .unreadable: return 3
            case .folderUnreadable: return 4
            case .newer(let version): return 1000 + max(0, min(version ?? 0, 999))
            }
        }

        /// "its tab file is damaged", after "Couldn't read Dia's tabs: ".
        var cause: String {
            switch self {
            case .missing: return "there is no tab file or session to read"
            case .unreadable: return "its tab file is there but can't be opened"
            case .folderUnreadable: return "its data folder is there but can't be opened"
            case .damaged: return "its tab file is damaged"
            case .newer(let version):
                return "its tab file is in a format this Yab doesn't know yet" + (version.map { " (version \($0))" } ?? "")
            }
        }

        /// The same, short enough for the corner's notice: "Dia's tab
        /// file is damaged".
        func briefly(_ browser: String) -> String {
            switch self {
            case .missing: return "\(browser) has no tab file to read"
            case .unreadable: return "\(browser)'s tab file can't be opened"
            case .folderUnreadable: return "\(browser)'s folder can't be opened"
            case .damaged: return "\(browser)'s tab file is damaged"
            case .newer: return "\(browser)'s tab file is in a newer format"
            }
        }
    }

    /// A tab file's bytes, nil when there is none; one that is there and
    /// can't be read is `unreadable`, not missing.
    static func tabFile(_ file: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        do { return try Data(contentsOf: file) } catch { throw Trouble.unreadable }
    }

    /// The places of the given browser, each with what it keeps now, in
    /// the browser's order. Off the main thread: files are read. A place
    /// with nothing in it only for a profile of its own.
    /// `ask`: Bring In was pressed, so a browser that keeps its tabs where
    /// only it can read them may be asked through its scripting (Dia), and
    /// macOS's question about it comes from that press, never by itself.
    static func places(in source: Chromium.Source, ask: Bool = false) throws -> [Place] {
        guard source.credentialAccess else { return [] }
        let found: [Place]
        switch source.bundle {
        case arc: found = try arcPlaces(source)
        case dia: found = try diaPlaces(source, ask: ask)
        default: found = try readSessions(source)
        }
        return found.filter { !$0.isEmpty || $0.apart }
    }

    static let arc = "company.thebrowser.Browser"
    static let dia = "company.thebrowser.dia"

    /// Host case is immaterial. Schemes, www, paths and fragments may
    /// identify different pages, especially in apps that route after #.
    static func key(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        parts.host = parts.host?.lowercased()
        parts.scheme = parts.scheme?.lowercased()
        return parts.string ?? url.absoluteString
    }

    // MARK: - Arc, from its sidebar

    private static func arcPlaces(_ source: Chromium.Source) throws -> [Place] {
        let file = source.root.deletingLastPathComponent().appendingPathComponent("StorableSidebar.json")
        guard let data = try tabFile(file) else { throw Trouble.missing }
        var codes: [Int] = []
        let places = ArcSidebar.places(in: data, names: profileNames(in: source), diagnostic: { codes.append($0) })
        if !codes.isEmpty {
            let issues = codes
            Task { @MainActor in
                for code in issues { FeedbackDiagnostics.shared.record(.importFailed, code: code) }
            }
        }
        return places
    }

    // MARK: - Dia, from its containers

    /// Dia's favorites, what it pins, and each window's tabs, by profile,
    /// from the file beside its Chromium folder; and every profile Dia
    /// lists, a window open or not, so none is left behind.
    private static func diaPlaces(_ source: Chromium.Source, ask: Bool) throws -> [Place] {
        // Dia's own database first, its folders and folders in folders
        // with it; any doubt about reading it, and its scripting and files
        // as before (DiaTabsDB).
        if let read = DiaTabsDB.places(source, ask: ask) { return read }
        let file = source.root.deletingLastPathComponent().appendingPathComponent("StorableProfileContainers.json")
        let names = profileNames(in: source)
        // Dia as it is now, from Dia itself, when Bring In was pressed and
        // Dia is open: its own file stopped being written (feedback #113).
        let read = Result { try tabFile(file) }
        let data = try? read.get()
        // An explicitly supplied folder (including a fixture) is not the
        // running Dia app's profile and must never ask that app for its tabs.
        if ask, source.dataRoot == nil, let scripted = DiaScript.places(names: names), scripted.contains(where: { !$0.isEmpty }) {
            // The script says a renamed tab's name as its title; its file
            // says which are renamed.
            let renamed = data.map(DiaContainers.names) ?? [:]
            let named = renamed.isEmpty ? scripted : scripted.map { place in
                var place = place
                func name(_ entry: Entry) -> Entry {
                    var entry = entry
                    if let given = renamed[key(entry.url)] { entry.name = given }
                    return entry
                }
                place.pinned = place.pinned.map(name)
                place.open = place.open.map(name)
                return place
            }
            return DiaContainers.adding(profileOrder(in: source), names: names, to: named)
        }
        if let data, DiaContainers.readable(data) {
            return DiaContainers.places(in: data, names: names, every: profileOrder(in: source))
        }
        // Dia's Chromium sessions can still hold its tabs when the custom
        // containers file is missing or unreadable. Keep each profile's
        // pins and sign-ins apart, as with its containers. A valid empty
        // containers file wins: don't resurrect an older Chromium session.
        let fallback = try readSessions(source)
        guard !fallback.isEmpty else {
            if case .failure(let trouble) = read { throw trouble }
            throw data.map(DiaContainers.trouble) ?? Trouble.missing
        }
        return DiaContainers.adding(profileOrder(in: source), names: names, to: fallback)
    }

    // MARK: - the others, from Chromium's session file

    private static func readSessions(_ source: Chromium.Source) throws -> [Place] {
        let info = profileInfo(in: source)
        var places: [Place] = []
        // A data folder that couldn't be listed says so, rather than the
        // browser having nothing.
        let scan = source.scan
        if scan.profiles.isEmpty, scan.trouble != nil { throw Trouble.folderUnreadable }
        // Profiles are discovered independently of saved passwords.
        // Default shares Yab's first sign-in store.
        for profile in scan.profiles {
            let folder = profile.lastPathComponent
            guard let data = session(in: profile) else { continue }
            let (pinned, open, left) = Snss.tabs(in: data)
            var seen = Set<String>()
            var place = Place(id: "\(source.name):\(folder)", name: info[folder]?.name ?? folder, color: info[folder]?.color,
                              profile: folder, shared: folder == "Default", isProfile: true,
                              pinned: once(pinned, seen: &seen), open: once(open, seen: &seen))
            place.left = left
            places.append(place)
        }
        return places
    }

    /// "Default" → "Personal", as the browser shows them, from Local State.
    static func profileNames(in source: Chromium.Source) -> [String: String] {
        profileInfo(in: source).mapValues(\.name)
    }

    /// Every profile the browser lists in Local State, in its own order
    /// (profiles_order), those it leaves out of that after, Default first
    /// and Profile 2 before Profile 10.
    static func profileOrder(in source: Chromium.Source) -> [String] {
        guard source.credentialAccess else { return source.profiles.map(\.lastPathComponent) }
        let names = profileNames(in: source)
        let state = source.root.appendingPathComponent("Local State")
        let listed = (try? Data(contentsOf: state))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .flatMap { ($0["profile"] as? [String: Any])?["profiles_order"] as? [String] } ?? []
        var order: [String] = []
        for folder in listed where names[folder] != nil && !order.contains(folder) { order.append(folder) }
        func rank(_ folder: String) -> (Int, String) {
            (folder == "Default" ? -1 : Int(folder.split(separator: " ").last ?? "") ?? Int.max, folder)
        }
        return order + names.keys.filter { !order.contains($0) }.sorted { rank($0) < rank($1) }
    }

    /// Each profile's name, and the color it was given, as hex.
    private static func profileInfo(in source: Chromium.Source) -> [String: (name: String, color: String?)] {
        guard source.credentialAccess else {
            return Dictionary(uniqueKeysWithValues: source.profiles.map { ($0.lastPathComponent, (name: $0.lastPathComponent, color: nil)) })
        }
        let state = source.root.appendingPathComponent("Local State")
        guard let data = try? Data(contentsOf: state),
              let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cache = (top["profile"] as? [String: Any])?["info_cache"] as? [String: Any]
        else { return [:] }
        var out: [String: (name: String, color: String?)] = [:]
        for (folder, raw) in cache {
            guard let info = raw as? [String: Any], let name = info["name"] as? String, !name.isEmpty else { continue }
            // A signed 32-bit ARGB; nothing when the profile has no color.
            let color = (info["profile_highlight_color"] as? NSNumber).map { number -> String in
                let argb = UInt32(bitPattern: Int32(truncatingIfNeeded: number.int64Value))
                return String(format: "%06X", argb & 0xFFFFFF)
            }
            out[folder] = (name, color)
        }
        return out
    }

    private static func session(in profile: URL) -> Data? {
        let folder = profile.appendingPathComponent("Sessions", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        let candidates = files
            .filter { $0.lastPathComponent.hasPrefix("Session_") }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a == b ? $0.lastPathComponent > $1.lastPathComponent : a > b
            } + ["Current Session", "Last Session"].map { profile.appendingPathComponent($0) }
        for file in candidates {
            guard let data = try? Data(contentsOf: file), Snss.valid(data) else { continue }
            return data
        }
        return nil
    }

    /// Off the main thread and back, for the views that ask.
    static func load(_ source: Chromium.Source, ask: Bool = false, then done: @escaping (Result<[Place], Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Result { try places(in: source, ask: ask) }
            DispatchQueue.main.async { done(outcome) }
        }
    }

    /// What to say when a browser's tabs couldn't be read, and why when
    /// it is known: "Couldn't read Dia's tabs: its tab file is damaged".
    static func explain(_ error: Error, from source: Chromium.Source) -> String {
        "Couldn't read \(source.name)'s tabs" + ((error as? Trouble).map { ": " + $0.cause } ?? "")
    }

    /// The failure counted in feedback's diagnostics, a number only.
    @MainActor static func note(_ error: Error) {
        FeedbackDiagnostics.shared.record(.importFailed, code: (error as? Trouble)?.code ?? 0)
    }

    static func entry(_ address: String, _ title: String) -> Entry? {
        if let page = suspended(address) {
            return Entry(url: page.url, title: page.title ?? title)
        }
        guard let url = URL(string: address), url.scheme == "http" || url.scheme == "https" else { return nil }
        return Entry(url: url, title: title)
    }

    /// An http or https address with a host, nothing else.
    private static func web(_ address: String) -> URL? {
        guard let url = URL(string: address), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host?.isEmpty == false else { return nil }
        return url
    }

    /// The page a tab suspender put to sleep, from the extension page that
    /// stands in for it: the address, and its title when the wrapper says
    /// one. The Great Suspender and its forks (Marvellous Suspender, The
    /// Great Suspender Original, Tiny Suspender) write
    /// `suspended.html#ttl=<title>&pos=0&uri=<address>`, the address last
    /// and as it was, `&` and `#` in it too; Tab Suspender and its kind
    /// `park.html?title=<title>&url=<encoded address>&icon=…`. Any
    /// extension page carrying an http(s) address under one of those names,
    /// in its query or after its #, is taken the same way. Nil for any
    /// other extension page, and for one whose address isn't a web page.
    static func suspended(_ address: String) -> (url: URL, title: String?)? {
        guard address.lowercased().hasPrefix("chrome-extension://") else { return nil }
        let hash = address.firstIndex(of: "#")
        let beforeHash = hash.map { String(address[..<$0]) } ?? address
        let fragment = hash.map { String(address[address.index(after: $0)...]) }
        let query = beforeHash.firstIndex(of: "?").map { String(beforeHash[beforeHash.index(after: $0)...]) }
        // After the # first: the Great Suspender's own, whose address may
        // hold a ? of its own; then the query.
        for part in [fragment, query].compactMap({ $0 }) where !part.isEmpty {
            if let found = wrapped(in: part) { return found }
        }
        return nil
    }

    private static let addressKeys = ["uri", "url", "u", "link", "href", "target"]
    private static let titleKeys = ["ttl", "title"]
    /// The wrapper's own names, which end an address written as it was
    /// when one follows it: `url=https://a.test/&title=A`.
    /// Not the one-letter ones, which pages use too (YouTube's &t=).
    private static let wrapperKeys = ["uri", "url", "link", "href", "target", "ttl", "title", "pos", "icon", "favicon", "favIconUrl", "tabId", "sessionId", "theme", "scroll"]

    /// One part of a wrapper's address, `a=1&b=2`: its page and title.
    private static func wrapped(in part: String) -> (url: URL, title: String?)? {
        // Each name=value, where it starts, so a raw address can run to
        // the end of the part.
        var pairs: [(key: String, value: String, rest: String)] = []
        var start = part.startIndex
        while start < part.endIndex {
            let end = part[start...].firstIndex(of: "&") ?? part.endIndex
            let pair = part[start..<end]
            if let equals = pair.firstIndex(of: "=") {
                let key = String(pair[..<equals]).lowercased()
                let valueStart = part.index(after: equals)
                pairs.append((key, String(part[valueStart..<end]), String(part[valueStart...])))
            }
            start = end < part.endIndex ? part.index(after: end) : end
        }
        // Once, and again while it isn't an address yet: some wrappers
        // encode it twice, and the page's own encoding stays.
        func decoded(_ value: String) -> String {
            var value = value
            for _ in 0..<3 {
                guard let once = value.removingPercentEncoding, once != value else { break }
                value = once
                if value.lowercased().hasPrefix("http://") || value.lowercased().hasPrefix("https://") { break }
            }
            return value
        }
        var page: URL?
        for key in addressKeys {
            guard let pair = pairs.first(where: { $0.key == key }) else { continue }
            let raw = pair.value.lowercased()
            // Written as it was: the Great Suspender's uri is last, so
            // everything after the name is the address; another runs to
            // the wrapper's next name. Encoded: up to the next &.
            let written = raw.hasPrefix("http://") || raw.hasPrefix("https://")
            let candidate = written ? (key == "uri" ? pair.rest : asWritten(pair.rest)) : decoded(pair.value)
            if let url = web(candidate) { page = url; break }
        }
        guard let page else { return nil }
        let title = titleKeys.lazy
            .compactMap { key in pairs.first(where: { $0.key == key }) }
            .map { ($0.value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? $0.value).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return (page, title)
    }

    /// An address written as it was, up to the wrapper's next name of its
    /// own, if one follows.
    private static func asWritten(_ rest: String) -> String {
        var end = rest.endIndex
        for key in wrapperKeys {
            if let found = rest.range(of: "&" + key + "=", options: .caseInsensitive), found.lowerBound < end { end = found.lowerBound }
        }
        return String(rest[..<end])
    }

    /// An extension's page that isn't a sleeping web page: it can't come.
    static func extensionPage(_ address: String) -> Bool {
        address.lowercased().hasPrefix("chrome-extension://") && suspended(address) == nil
    }

    /// Each address once, the first time, by `key`.
    static func once(_ entries: [Entry], seen: inout Set<String>) -> [Entry] {
        entries.filter { seen.insert(key($0.url)).inserted }
    }
}

// MARK: - Arc's sidebar

/// Arc keeps its spaces in a file of its own, StorableSidebar.json, one
/// folder up from its Chromium profiles. The file holds one flat list of
/// items that point at each other, a favorite, a space's pinned half, a
/// folder inside it, a split of two tabs, each naming its children in
/// order; the list itself alternates an item's id and the item. Each
/// space: its title, its emoji (customInfo.iconType.emoji_v2), its color
/// and grain (customInfo.windowTheme), its profile, and its two halves
/// (containerIDs: "pinned", its id, "unpinned", its id). Each profile's
/// favorites, the row of icons at the top of every one of its spaces
/// (topAppsContainerIDs, a profile and its container, one after the other).
enum ArcSidebar {
    /// Every space, in Arc's order: its pinned tabs as tabs that stay,
    /// folders opened in place, and its unpinned "Today" tabs as what it
    /// has open. Each profile's favorites are the pins of the first space
    /// of that profile: yab has no row across spaces, and a copy in each
    /// would be a twin tab in each. A page comes once in each space, the
    /// first time: a favorite over a space's pin, a pin over an open tab.
    /// Import results stay the same when part of the file isn't understood.
    /// The optional diagnostic receives only fixed failure codes, once each,
    /// so feedback can distinguish that case from a genuinely empty sidebar.
    static func places(in data: Data, names: [String: String] = [:], diagnostic: ((Int) -> Void)? = nil) -> [TabImport.Place] {
        var noted: Set<Int> = []
        func note(_ trouble: TabImport.Trouble) {
            if noted.insert(trouble.code).inserted { diagnostic?(trouble.code) }
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            note(.damaged)
            return []
        }
        guard let top = json as? [String: Any],
              let containers = (top["sidebar"] as? [String: Any])?["containers"] as? [[String: Any]] else {
            note(.newer(version: nil))
            return []
        }
        var out: [TabImport.Place] = []
        for container in containers {
            var byID: [String: [String: Any]] = [:]
            for case let item as [String: Any] in container["items"] as? [Any] ?? [] {
                if let id = item["id"] as? String { byID[id] = item }
            }
            func walk(_ id: String, depth: Int = 0, in folder: [String] = []) -> [TabImport.Entry] {
                // Items name each other; a loop in a damaged file stops here.
                guard depth < 32, let item = byID[id] else { return [] }
                var found: [TabImport.Entry] = []
                let data = item["data"] as? [String: Any]
                if let tab = data?["tab"] as? [String: Any],
                   let address = tab["savedURL"] as? String {
                    // Arc keeps a title on the item only for a tab renamed
                    // there: the tab's name, over whatever the page says.
                    let named = (item["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    let saved = (tab["savedTitle"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    if var entry = TabImport.entry(address, saved ?? named ?? "") {
                        if let named, named != saved { entry.name = named }
                        entry.folder = folder.isEmpty ? nil : folder.joined(separator: " › ")
                        entry.path = folder.count > 1 ? folder : nil
                        // Seconds since 2001.
                        entry.added = (item["createdAt"] as? Double).map(Date.init(timeIntervalSinceReferenceDate:))
                        found.append(entry)
                    }
                }
                // A folder, below a half's own container: its tabs are in it.
                var inside = folder
                if depth > 0, data?["list"] != nil {
                    let name = (item["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Folder"
                    inside = folder + [name]
                }
                for child in item["childrenIds"] as? [String] ?? [] {
                    found += walk(child, depth: depth + 1, in: inside)
                }
                return found
            }

            var favorites: [String: [TabImport.Entry]] = [:]
            var order: [String] = []
            let apps = container["topAppsContainerIDs"] as? [Any] ?? []
            if container["topAppsContainerIDs"] != nil, container["topAppsContainerIDs"] as? [Any] == nil {
                note(.newer(version: nil))
            }
            if apps.count % 2 != 0 { note(.newer(version: nil)) }
            for index in stride(from: 0, to: apps.count - 1, by: 2) {
                guard let id = apps[index + 1] as? String else {
                    note(.newer(version: nil))
                    continue
                }
                if byID[id] == nil { note(.newer(version: nil)) }
                let owner = profile(apps[index])
                if !order.contains(owner) { order.append(owner) }
                favorites[owner, default: []] += walk(id)
            }
            for case let space as [String: Any] in container["spaces"] as? [Any] ?? [] {
                let owner = profile(space["profile"])
                let name = (space["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Space"
                let ids = space["containerIDs"] as? [Any] ?? []
                if space["containerIDs"] != nil, space["containerIDs"] as? [Any] == nil {
                    note(.newer(version: nil))
                }
                if ids.isEmpty, let modern = space["newContainerIDs"] as? [Any], !modern.isEmpty {
                    note(.newer(version: nil))
                }
                if ids.count % 2 != 0, let kind = ids.last as? String, ["pinned", "unpinned"].contains(kind) {
                    note(.newer(version: nil))
                }
                var pinned: [TabImport.Entry] = [], open: [TabImport.Entry] = []
                for index in stride(from: 0, to: ids.count - 1, by: 2) {
                    // Unknown kinds may be metadata Arc expects us to ignore.
                    // Only a declared import root that cannot be read is noted.
                    if let kind = ids[index] as? String, ["pinned", "unpinned"].contains(kind),
                       (ids[index + 1] as? String).map({ byID[$0] == nil }) ?? true {
                        note(.newer(version: nil))
                    }
                    guard let id = ids[index + 1] as? String else { continue }
                    switch ids[index] as? String {
                    case "pinned": pinned += walk(id)
                    case "unpinned": open += walk(id)
                    default: continue
                    }
                }
                let custom = space["customInfo"] as? [String: Any]
                let look = theme(custom?["windowTheme"])
                let emoji = ((custom?["iconType"] as? [String: Any])?["emoji_v2"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                var mine = Set<String>()
                // The profile's favorites, the pins of its first space only.
                let pins = TabImport.once(favorites.removeValue(forKey: owner) ?? [], seen: &mine)
                let kept = TabImport.once(pinned, seen: &mine)
                let rest = TabImport.once(open, seen: &mine)
                let addresses = Set((pins + kept + rest).map { TabImport.key($0.url) })
                var splits: [TabImport.Split] = []
                for id in byID.keys.sorted() {
                    guard let item = byID[id], let split = (item["data"] as? [String: Any])?["splitView"] as? [String: Any],
                          split["layoutOrientation"] as? String != "vertical",
                          let children = item["childrenIds"] as? [String], children.count == 2,
                          let a = walk(children[0]).first, let b = walk(children[1]).first,
                          addresses.contains(TabImport.key(a.url)), addresses.contains(TabImport.key(b.url)), a.url != b.url else { continue }
                    let factors = split["itemWidthFactors"] as? [Any] ?? []
                    var widths: [String: Double] = [:]
                    for index in stride(from: 0, to: max(0, factors.count - 1), by: 2) {
                        if let key = factors[index] as? String, let width = factors[index + 1] as? Double, width.isFinite, width > 0 { widths[key] = width }
                    }
                    let aWidth = widths[children[0]] ?? 1, bWidth = widths[children[1]] ?? 1
                    splits.append(TabImport.Split(first: a.url, second: b.url, share: aWidth / (aWidth + bWidth)))
                }
                out.append(TabImport.Place(id: "Arc:" + ((space["id"] as? String) ?? name), name: name, emoji: emoji,
                                           color: look.color, grain: look.grain, colors: look.colors, profile: owner, shared: owner == "Default",
                                           pinned: pins, kept: kept, open: rest, splits: splits))
            }
            // Favorites of a profile with no space of its own: a place of
            // its own, named for the profile.
            for owner in order {
                guard let entries = favorites.removeValue(forKey: owner) else { continue }
                var mine = Set<String>()
                let pins = TabImport.once(entries, seen: &mine)
                guard !pins.isEmpty else { continue }
                out.append(TabImport.Place(id: "Arc:favorites:" + owner, name: names[owner] ?? "Favorites", profile: owner,
                                           shared: owner == "Default", isProfile: true, pinned: pins, open: []))
            }
        }
        return out
    }

    /// Arc names a profile {"default": {}} or {"custom": {"_0":
    /// {"directoryBasename": "Profile 1"}}}; the folder is what matters.
    private static func profile(_ raw: Any?) -> String {
        guard let custom = (raw as? [String: Any])?["custom"] as? [String: Any],
              let folder = (custom["_0"] as? [String: Any])?["directoryBasename"] as? String
        else { return "Default" }
        return folder
    }

    /// A space's colors and grain as Arc's theme editor holds them, under
    /// windowTheme.background.single._0.style.color._0: one color
    /// (blendedSingleColor: color, modifiers) or a gradient of two or three
    /// (blendedGradient: baseColors in order, modifiers). The first is the
    /// space's color, the rest the linked ones; the grain is the noise
    /// factor of the texture over it, as rough as Arc draws it
    /// (Grain.fromArc). Only those: overlayColors (an alpha 0 black, then
    /// a mix Arc works out), primaryColorPalette and semanticColorPalette
    /// are Arc's own shades of them, and read as colors they were a stray
    /// black dot and more on every space (request #464). Nothing for a
    /// space left in Arc's own.
    static func theme(_ raw: Any?) -> (color: String?, grain: Double?, colors: [String]) {
        func dict(_ value: Any?, _ path: [String]) -> [String: Any]? {
            path.reduce(value as? [String: Any]) { $0?[$1] as? [String: Any] }
        }
        guard let style = dict(raw, ["background", "single", "_0", "style", "color", "_0"]) else { return (nil, nil, []) }
        // A component of extendedSRGB can sit past 0...1; sRGB clamps it.
        func hex(_ value: Any?) -> String? {
            guard let c = value as? [String: Any], let r = number(c["red"]), let g = number(c["green"]), let b = number(c["blue"]),
                  (number(c["alpha"]) ?? 1) > 0 else { return nil }
            func byte(_ x: Double) -> Int { Int((min(1, max(0, x)) * 255).rounded()) }
            return String(format: "%02X%02X%02X", byte(r), byte(g), byte(b))
        }
        var found: [String] = []
        var modifiers: [String: Any]?
        if let single = dict(style, ["blendedSingleColor", "_0"]) {
            found = [hex(single["color"])].compactMap { $0 }
            modifiers = single["modifiers"] as? [String: Any]
        } else if let gradient = dict(style, ["blendedGradient", "_0"]) {
            found = (gradient["baseColors"] as? [Any] ?? []).compactMap(hex)
            modifiers = gradient["modifiers"] as? [String: Any]
        }
        var colors: [String] = []
        for one in found where !colors.contains(one) && colors.count < 3 { colors.append(one) }
        guard let color = colors.first else { return (nil, nil, []) }
        // Arc's textures, grain, sand, denim and tweed, are Yab's one grain.
        var grain = 0.0
        if let overlay = modifiers?["overlay"] as? String, !overlay.isEmpty, overlay != "none" {
            grain = number(modifiers?["noiseFactor"]).map(Grain.fromArc) ?? Grain.standard
        }
        return (color, grain, Array(colors.dropFirst()))
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    /// A space brought from Arc before request #464 carries the stray
    /// black after its own colors, and Arc's shades past it, four linked
    /// colors where the editor makes two at most: its colors are the ones
    /// before that black. Any other list comes back as it is.
    static func repaired(_ colors: [String]) -> [String] {
        guard colors.count > 2, let black = colors.firstIndex(of: "000000") else { return colors }
        return Array(colors[..<black].prefix(2))
    }
}

// MARK: - Dia, asked

/// Dia as it is now, asked through its scripting (Dia.sdef): each profile of
/// its front window, the spaces Dia shows, with its tabs, pinned or not.
/// Only when Dia's tabs.db can't be read (DiaTabsDB), which has the folders:
/// StorableProfileContainers.json beside it stopped being written in 2025,
/// read it brought an old set of tabs or none (feedback #113). Folders
/// aren't in Dia's scripting: read this way their tabs come as its pins.
enum DiaScript {
    /// What Dia answers: a profile per record, "P", its name and index,
    /// then its tabs, "T", pinned, address and title, in unit separators.
    static let source = """
    with timeout of 15 seconds
    tell application id "company.thebrowser.dia"
      if (count of windows) is 0 then return ""
      set f to ASCII character 31
      set r to ASCII character 30
      set out to ""
      repeat with p in profiles of window 1
        set out to out & "P" & f & (name of p) & f & (index of p) & r
        repeat with t in tabs of p
          set out to out & "T" & f & (isPinned of t) & f & (URL of t) & f & (title of t) & r
        end repeat
      end repeat
      return out
    end tell
    end timeout
    """

    /// Its places, or nil when Dia isn't open with a window, or said no.
    /// Asked through osascript, off the main thread; macOS asks you first,
    /// once, whether Yab may.
    static func places(names: [String: String]) -> [TabImport.Place]? {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: TabImport.dia).isEmpty else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do { try process.runValidated() } catch { return nil }
        let deadline = Date().addingTimeInterval(20)
        while process.isRunning, Date() < deadline { usleep(50_000) }
        if process.isRunning { process.terminate(); return nil }
        guard process.terminationStatus == 0,
              let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else { return nil }
        return parse(text, names: names)
    }

    /// Dia's answer as places: a profile's display name back to its folder
    /// by Local State's names (Default first), so its sign-ins come with it.
    static func parse(_ text: String, names: [String: String]) -> [TabImport.Place]? {
        let folders = Dictionary(names.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
        var places: [TabImport.Place] = []
        var pinned: [TabImport.Entry] = [], open: [TabImport.Entry] = []
        var current: (name: String, folder: String)?
        // Each place's name as Dia says it.
        var said: [String] = []
        func close() {
            guard let current else { return }
            var seen = Set<String>()
            said.append(current.name)
            places.append(TabImport.Place(id: "Dia:" + current.folder, name: names[current.folder] ?? current.name,
                                          profile: current.folder, shared: current.folder == "Default", isProfile: true,
                                          pinned: TabImport.once(pinned, seen: &seen), open: TabImport.once(open, seen: &seen)))
            pinned = []; open = []
        }
        for record in text.trimmingCharacters(in: .newlines).split(separator: "\u{1E}", omittingEmptySubsequences: true) {
            let fields = record.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
            if fields.first == "P", fields.count >= 3 {
                close()
                let name = fields[1]
                let index = Int(fields[2]) ?? 1
                // Past its profiles' names, the profile in Dia's order, when
                // Local State lists that one; otherwise the first's.
                let guess = index <= 1 ? "Default" : "Profile \(index - 1)"
                current = (name, folders[name] ?? (names.isEmpty || names[guess] != nil ? guess : "Default"))
            } else if fields.first == "T", fields.count >= 4, current != nil {
                guard let entry = TabImport.entry(fields[2], fields[3...].joined(separator: "\u{1F}")) else { continue }
                if fields[1] == "true" { pinned.append(entry) } else { open.append(entry) }
            }
        }
        close()
        // A Dia space is a Chromium profile of its own ("Profile 4" for a
        // new one, named in Local State). One whose name Local State doesn't
        // have was the guess's "Profile 1", which may not be there: signed
        // in as nobody. Now it is the first profile's, and two of those are
        // a space here each, by Dia's name, rather than one place twice.
        let owners = Dictionary(grouping: places, by: \.profile)
        places = zip(places, said).map { place, name in
            guard (owners[place.profile]?.count ?? 0) > 1 else { return place }
            return TabImport.Place(id: "Dia:\(place.profile):\(name.lowercased())", name: name,
                                   profile: place.profile, shared: place.shared, pinned: place.pinned, open: place.open)
        }
        return places.isEmpty ? nil : places
    }
}

// MARK: - Dia's containers

/// Dia's StorableProfileContainers.json: containers, each a profile and
/// what it holds, its favorites or one of its windows, and in each the
/// tabs, whose contents are a list of what they show, a web page as
/// {"variant": {"webContent": {"_0": {"url", "title"}}}}.
enum DiaContainers {
    static func readable(_ data: Data) -> Bool {
        guard let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return top["containers"] is [[String: Any]]
    }

    /// Why a file that isn't `readable` isn't: not JSON at all, or JSON
    /// in a shape Dia hadn't written before, with the version it says.
    static func trouble(_ data: Data) -> TabImport.Trouble {
        guard let top = try? JSONSerialization.jsonObject(with: data) else { return .damaged }
        return .newer(version: ((top as? [String: Any])?["version"] as? NSNumber)?.intValue)
    }

    /// Each profile of `every` past the first that has no place yet, as a
    /// place of its own with nothing in it, after the others: a profile
    /// with no window open is still a profile.
    static func adding(_ every: [String], names: [String: String], to places: [TabImport.Place]) -> [TabImport.Place] {
        let have = Set(places.map(\.profile))
        return places + every.filter { $0 != "Default" && !have.contains($0) }.map { owner in
            TabImport.Place(id: "Dia:" + owner, name: names[owner] ?? owner, profile: owner, shared: false,
                            isProfile: true, pinned: [], open: [])
        }
    }

    /// The name a tab was given in Dia, its "customTitle", a string or
    /// one Swift wrote as {"_0": string}.
    static func customTitle(_ object: [String: Any]) -> String? {
        let raw = object["customTitle"]
        let title = raw as? String ?? (raw as? [String: Any])?["_0"] as? String
        return title.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }

    /// Names given in Dia, by page (TabImport.key), from its file: for
    /// what Dia's script says, which has the shown title only.
    static func names(in data: Data) -> [String: String] {
        var out: [String: String] = [:]
        for place in places(in: data) {
            for entry in place.pinned + place.open {
                if let name = entry.name { out[TabImport.key(entry.url)] = name }
            }
        }
        return out
    }

    /// `every`: the profiles Dia lists, those with nothing in its file
    /// too (`adding`).
    static func places(in data: Data, names: [String: String] = [:], every: [String] = []) -> [TabImport.Place] {
        guard let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let containers = top["containers"] as? [[String: Any]]
        else { return [] }
        var order: [String] = []
        var pinned: [String: [TabImport.Entry]] = [:], open: [String: [TabImport.Entry]] = [:]
        for container in containers {
            let id = container["id"] as? [String: Any]
            let owner = id?["profileID"] as? String ?? "Default"
            if !order.contains(owner) { order.append(owner) }
            let kind = (id?["container"] as? [String: Any])?.keys.first
            let entries: [TabImport.Entry] = (container["tabs"] as? [[String: Any]] ?? []).flatMap { tab -> [TabImport.Entry] in
                let contents = tab["contents"] as? [[String: Any]] ?? []
                return contents.compactMap { content in
                    guard let web = ((content["variant"] as? [String: Any])?["webContent"] as? [String: Any])?["_0"] as? [String: Any],
                          let address = web["url"] as? String, var entry = TabImport.entry(address, web["title"] as? String ?? "") else { return nil }
                    // Renamed in Dia (Rename Current Tab): the tab's name,
                    // for a tab of one page.
                    if contents.count == 1, let named = customTitle(tab) ?? customTitle(content), named != entry.title { entry.name = named }
                    return entry
                }
            }
            if kind == "favorites" { pinned[owner, default: []] += entries } else { open[owner, default: []] += entries }
        }
        // "Default" first: the one yab's first space shares.
        order = order.filter { $0 == "Default" } + order.filter { $0 != "Default" }
        return adding(every, names: names, to: order.map { owner in
            var seen = Set<String>()
            let pins = TabImport.once(pinned[owner] ?? [], seen: &seen)
            let rest = TabImport.once(open[owner] ?? [], seen: &seen)
            return TabImport.Place(id: "Dia:" + owner, name: names[owner] ?? owner, profile: owner, shared: owner == "Default",
                                   isProfile: true, pinned: pins, open: rest)
        })
    }
}

// MARK: - the session file

/// Chromium's "SNSS" file: a header, then one command after another, each a
/// little-endian size, a one-byte id and a body. Replaying them gives the
/// windows and tabs as they are now. Only the handful of commands that say
/// where a tab is, what it shows and whether it is pinned matter here.
enum Snss {
    private enum Command: UInt8 {
        case setTabWindow = 0
        case setTabIndexInWindow = 2
        case pruneBack = 5
        case updateTabNavigation = 6
        case setSelectedNavigationIndex = 7
        case pruneFront = 11
        case setPinnedState = 12
        case tabClosed = 16
        case windowClosed = 17
        case prune = 24
        case setTabGroup = 25
        case setTabGroupMetadata = 27
    }

    private struct Tab {
        var window: Int32 = 0
        var index: Int32 = 0
        var pinned = false
        var selected: Int32?
        var navigations: [Int32: (String, String)] = [:]
        var group: [UInt8]?

        mutating func prune(from index: Int32, count: Int32) {
            guard index >= 0, count > 0, Int64(index) + Int64(count) <= Int64(Int32.max) else { return }
            let end = index + count
            if let selected {
                if selected >= index && selected < end { self.selected = index - 1 }
                else if selected >= end { self.selected = selected - count }
            }
            navigations = Dictionary(uniqueKeysWithValues: navigations.compactMap { key, value in
                if key >= index && key < end { return nil }
                return (key >= end ? key - count : key, value)
            })
        }
    }

    static func valid(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(8))
        return bytes.count == 8 && bytes[0..<4] == [0x53, 0x4E, 0x53, 0x53]
            && (1...3).contains(int(bytes, 4))
    }

    /// Its pinned and open tabs, and how many are extension pages that
    /// can't come (`left`).
    static func tabs(in data: Data) -> (pinned: [TabImport.Entry], open: [TabImport.Entry], left: Int) {
        let bytes = [UInt8](data)
        guard valid(data) else { return ([], [], 0) }

        var tabs: [Int32: Tab] = [:]
        var closedWindows = Set<Int32>()
        var windowOrder: [Int32] = []
        var groups: [[UInt8]: String] = [:]
        var at = 8
        while at + 2 <= bytes.count {
            let size = Int(bytes[at]) | Int(bytes[at + 1]) << 8
            at += 2
            guard size > 0, at + size <= bytes.count else { break }
            let id = bytes[at]
            let body = Array(bytes[(at + 1)..<(at + size)])
            at += size

            switch Command(rawValue: id) {
            case .setTabWindow where body.count >= 8:
                let window = int(body, 0), tab = int(body, 4)
                tabs[tab, default: Tab()].window = window
                if !windowOrder.contains(window) { windowOrder.append(window) }
            case .setTabIndexInWindow where body.count >= 8:
                tabs[int(body, 0), default: Tab()].index = int(body, 4)
            case .setPinnedState where body.count >= 5:
                tabs[int(body, 0), default: Tab()].pinned = body[4] != 0
            case .setSelectedNavigationIndex where body.count >= 8:
                tabs[int(body, 0), default: Tab()].selected = int(body, 4)
            case .pruneBack where body.count >= 8:
                let id = int(body, 0), index = int(body, 4)
                guard index >= 0, var tab = tabs[id] else { continue }
                tab.navigations = tab.navigations.filter { $0.key < index }
                tabs[id] = tab
            case .pruneFront where body.count >= 8:
                tabs[int(body, 0)]?.prune(from: 0, count: int(body, 4))
            case .prune where body.count >= 12:
                tabs[int(body, 0)]?.prune(from: int(body, 4), count: int(body, 8))
            case .tabClosed where body.count >= 4:
                tabs[int(body, 0)] = nil
            case .windowClosed where body.count >= 4:
                closedWindows.insert(int(body, 0))
            case .setTabGroup where body.count >= 25:
                tabs[int(body, 0), default: Tab()].group = body[24] == 0 ? nil : Array(body[8..<24])
            case .setTabGroupMetadata where body.count >= 24:
                let count = Int(int(body, 20))
                guard count >= 0, count <= (body.count - 24) / 2 else { continue }
                let raw = stride(from: 24, to: 24 + count * 2, by: 2).map { UInt16(body[$0]) | UInt16(body[$0 + 1]) << 8 }
                let name = String(decoding: raw, as: UTF16.self)
                groups[Array(body[4..<20])] = name.isEmpty ? "Tab group" : name
            case .updateTabNavigation:
                // A pickle: its own length, then tab, index, the address as
                // UTF-8 padded to four bytes, the title as UTF-16.
                guard body.count >= 16 else { continue }
                let tab = int(body, 4), index = int(body, 8)
                var p = 12
                let urlLength = Int(int(body, p)); p += 4
                guard urlLength >= 0, p + urlLength <= body.count else { continue }
                let url = String(decoding: body[p..<(p + urlLength)], as: UTF8.self)
                p += (urlLength + 3) / 4 * 4
                var title = ""
                if p + 4 <= body.count {
                    let units = Int(int(body, p)); p += 4
                    if units >= 0, p + units * 2 <= body.count {
                        let raw = stride(from: p, to: p + units * 2, by: 2).map { UInt16(body[$0]) | UInt16(body[$0 + 1]) << 8 }
                        title = String(decoding: raw, as: UTF16.self)
                    }
                }
                tabs[tab, default: Tab()].navigations[index] = (url, title)
            default:
                continue
            }
        }

        var pinned: [TabImport.Entry] = [], open: [TabImport.Entry] = []
        var left = 0
        let live = tabs.values
            .filter { !closedWindows.contains($0.window) && !$0.navigations.isEmpty }
            .sorted {
                let a = windowOrder.firstIndex(of: $0.window) ?? .max
                let b = windowOrder.firstIndex(of: $1.window) ?? .max
                return a != b ? a < b : $0.index < $1.index
            }
        for tab in live {
            let shown: (String, String)?
            if let selected = tab.selected {
                shown = tab.navigations[selected]
                    ?? tab.navigations.filter { $0.key >= selected }.min { $0.key < $1.key }?.value
                    ?? tab.navigations.max { $0.key < $1.key }?.value
            } else {
                shown = tab.navigations.max { $0.key < $1.key }?.value
            }
            guard let (url, title) = shown, var entry = TabImport.entry(url, title) else {
                if let (url, _) = shown, TabImport.extensionPage(url) { left += 1 }
                continue
            }
            entry.folder = tab.group.flatMap { groups[$0] }
            if tab.pinned { pinned.append(entry) } else { open.append(entry) }
        }
        return (pinned, open, left)
    }

    private static func int(_ bytes: [UInt8], _ at: Int) -> Int32 {
        Int32(bitPattern: UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24)
    }
}

// MARK: - the control

/// "Bring tabs in" in Settings: a menu of browsers. One place with tabs
/// and it is done at once; otherwise each is listed, ticked, with its pins
/// and where it will go, "into Personal", "new space", and the ones ticked
/// come in together. Every profile of its own is listed, one with no tabs
/// too, and comes as the welcome brings it: its space signed in as it was
/// there, with its cookies (`take`).
struct TabBringer: View {
    var browser: Browser
    @Binding var withOpen: Bool

    private enum Stage: Equatable {
        case idle
        case asking(String)
        case choosing(Chromium.Source, [TabImport.Place])
        case said(String)
    }
    @State private var stage: Stage = .idle
    @State private var skipped: Set<String> = []
    /// Spaces off, several places: turned on for them, unless said not.
    @State private var asSpaces = true

    var body: some View {
        let sources = Chromium.installed()
        SettingsRow("Bring tabs in") {
            if case .asking = stage {
                ProgressView().controlSize(.small)
            } else if sources.isEmpty {
                Text("None on this Mac").foregroundStyle(.secondary)
            } else {
                Menu("Bring In") {
                    ForEach(sources) { source in
                        Button(source.name) { bring(from: source) }
                    }
                }
                .settingsButton()
                .fixedSize()
            }
        }
        .settingsAnchor("bring-tabs")
        // A probe pressing Bring In, for a picture of what it lists.
        .onReceive(NotificationCenter.default.publisher(for: Self.benchBring)) { note in
            if let source = note.userInfo?["source"] as? Chromium.Source { bring(from: source) }
        }
        SettingsSwitch("And the tabs that are open", isOn: $withOpen)
        switch stage {
        case .choosing(let source, let found):
            let places = found.filter { $0.comes(withOpen: withOpen) }
            if !browser.prefs.usesSpaces {
                SettingsSwitch("As spaces", isOn: $asSpaces)
            }
            ForEach(places) { place in
                let picked = places.filter { !skipped.contains($0.id) }
                SettingsRow(TabBringer.label(place), detail: TabBringer.detail(place, withOpen: withOpen) + " · "
                            + (skipped.contains(place.id) ? "left out" : browser.landingWords(of: place, among: picked, asSpaces: asSpaces))) {
                    Toggle(place.name, isOn: Binding(
                        get: { !skipped.contains(place.id) },
                        set: { on in if on { skipped.remove(place.id) } else { skipped.insert(place.id) } }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
            }
            SettingsRow("From \(source.name)") {
                Button("Bring In") {
                    let picked = places.filter { !skipped.contains($0.id) }
                    TabBringer.take(picked, withOpen: withOpen, asSpaces: asSpaces, from: source, into: browser)
                    stage = TabBringer.boosts(from: source).map { .said($0) } ?? .idle
                }
                .settingsButton()
                .disabled(places.allSatisfy { skipped.contains($0.id) })
            }
        case .said(let text):
            SettingsNote(text)
        default:
            SettingsNote("Import pinned tabs and spaces with their icons, colors and sign-ins. History is separate. Open tabs are added unloaded at the end of the tab list.")
        }
    }

    private func bring(from source: Chromium.Source) {
        let source = source.authorizingImport()
        stage = .asking(source.name)
        skipped = []
        TabImport.load(source, ask: true) { outcome in
            switch outcome {
            case .success(let places) where places.isEmpty:
                stage = .said(["\(source.name) has no pinned or open tabs", TabBringer.boosts(from: source)].compactMap { $0 }.joined(separator: " · "))
            case .success(let places) where TabBringer.atOnce(places, withOpen: withOpen):
                TabBringer.take(places, withOpen: withOpen, asSpaces: false, from: source, into: browser)
                let left = places.reduce(0) { $0 + $1.left }
                let said = [TabBringer.boosts(from: source), left > 0 ? TabBringer.leftWords(left, from: source) : nil].compactMap { $0 }
                stage = said.isEmpty ? .idle : .said(said.joined(separator: " · "))
            case .success(let places):
                stage = .choosing(source, places)
            case .failure(let error):
                TabImport.note(error)
                // Arc's boosts don't need its tabs: they come all the same.
                stage = .said([TabImport.explain(error, from: source), TabBringer.boosts(from: source)].compactMap { $0 }.joined(separator: " · "))
            }
        }
    }

    /// Posted by Bench in a test world: Bring In pressed for "source".
    static let benchBring = Notification.Name("yab.bench.bringTabs")

    /// The places picked, into their spaces, each profile of its own
    /// signed in as it was there, as the welcome brings them.
    @discardableResult
    static func take(_ places: [TabImport.Place], withOpen: Bool, asSpaces: Bool, from source: Chromium.Source,
                     into browser: Browser) -> (spaces: Int, pinned: Int, open: Int, marked: Int) {
        browser.bring(places, withOpen: withOpen, asSpaces: asSpaces, signIns: true, from: source)
    }

    /// Arc's boosts, brought with its tabs (ArcBoosts.bringIn), said as
    /// "3 boosts from Arc, in Site Controls"; nil when none came.
    static func boosts(from source: Chromium.Source) -> String? {
        let brought = ArcBoosts.bringIn(from: source)
        return brought == 0 ? nil : ArcBoosts.words(brought) + " from \(source.name), in Site Controls"
    }

    /// Brought without a list only when one place comes and it has tabs:
    /// a profile with none, which would come as an empty space and ask the
    /// keychain, is listed first.
    static func atOnce(_ places: [TabImport.Place], withOpen: Bool) -> Bool {
        let coming = places.filter { $0.comes(withOpen: withOpen) }
        return coming.count == 1 && coming[0].holds(withOpen: withOpen)
    }

    /// "2 Chrome tabs are extension pages and couldn't be imported".
    static func leftWords(_ count: Int, from source: Chromium.Source) -> String {
        count == 1 ? "1 \(source.name) tab is an extension page and couldn't be imported"
            : "\(count) \(source.name) tabs are extension pages and couldn't be imported"
    }

    /// "💼 Work", its emoji when the browser gave it one.
    static func label(_ place: TabImport.Place) -> String {
        place.emoji.map { "\($0) \(place.name)" } ?? place.name
    }

    /// "8 pins, 164 tabs", with the open ones too when they are wanted;
    /// "No tabs" for a profile that comes with its sign-ins only.
    static func detail(_ place: TabImport.Place, withOpen: Bool) -> String {
        if !place.holds(withOpen: withOpen), withOpen || place.open.isEmpty { return "No tabs" }
        var parts: [String] = []
        if !place.pinned.isEmpty { parts.append(place.pinned.count == 1 ? "1 pin" : "\(place.pinned.count) pins") }
        if !place.kept.isEmpty { parts.append(place.kept.count == 1 ? "1 tab" : "\(place.kept.count) tabs") }
        if withOpen { parts.append("\(place.open.count) open") }
        if place.left > 0 { parts.append(place.left == 1 ? "1 extension page can't come" : "\(place.left) extension pages can't come") }
        return parts.isEmpty ? "Nothing pinned" : parts.joined(separator: ", ")
    }
}
