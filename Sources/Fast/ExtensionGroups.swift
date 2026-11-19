import AppKit
import Combine
import WebKit

// chrome.tabGroups and the group half of chrome.tabs, as Yab's folders.
//
// Chrome's tab group is a folder in Yab's sidebar (Kept.swift's Nest): a
// group of today's tabs is a folder among today's (as two tabs held over one
// another make), a group of kept tabs one among the kept. tabs.group puts
// tabs in one, made or named by id; tabs.ungroup takes them out, and a folder
// left with no tabs goes. A group's title is the folder's name; collapsed is
// the folder shut; its color is kept beside it, since Yab's folders wear the
// space's ink and no color of their own, and is said back as set. Its id is
// a number made from the folder's, the same for the folder's life; a tab's
// groupId is its folder's, -1 outside one.
//
// tabGroups.onCreated, onUpdated, onRemoved and onMoved come from the
// folders as they change (Folders), over a port each extension with the
// tabGroups permission opens, with what tab is in which group alongside,
// which the shim keeps to give each tab its groupId, and each tab whose
// group changed, which the shim tells tabs.onUpdated as {groupId}, before
// the group's own events, in Chrome's order. Only those extensions are
// told, and only while their worker runs.
//
// Tabs are named to the browser by where they stand in the row, as every
// tab call of the shim's is (tabs.move, tabs.discard).

@available(macOS 15.4, *)
@MainActor
final class ExtensionGroups {
    static let shared = ExtensionGroups()
    private weak var logicalBrowser: Browser?
    private var logicalProfile: String?
    init(browser: Browser? = nil, profile: String? = nil) {
        logicalBrowser = browser; logicalProfile = profile
    }
    nonisolated static let portName = ExtensionShims.application + ".groups"
    /// Chrome's nine, in the order Chrome gives a new group the next one.
    nonisolated static let colors = ["grey", "blue", "red", "yellow", "green", "pink", "purple", "cyan", "orange"]
    private static let colorsKey = "extensions.groupColors"

    /// Each extension's open ports: its worker's and its pages'.
    private var ports: [String: [WKWebExtension.MessagePort]] = [:]
    private var colors: [String: String] = Store.settings.dictionary(forKey: colorsKey) as? [String: String] ?? [:]
    /// Folders an extension made and hasn't named: their title is "".
    private static var untitledGroups: Set<UUID> = []
    private var untitled: Set<UUID> {
        get { Self.untitledGroups }
        set { Self.untitledGroups = newValue }
    }
    private var watch: AnyCancellable?
    private var nestWatches: [AnyCancellable] = []
    private var last: [Int: [String: Any]] = [:]
    private var lastMembers: [Int] = []
    /// Each tab's group when last told, by the tab, so a tab whose place in
    /// the row moved isn't taken for one whose group changed.
    private var lastByTab: [UUID: Int] = [:]
    /// The groups in the order they stand in the row, when last told.
    private var lastOrder: [Int] = []
    /// The group tabGroups.move moved: the one onMoved names, where two
    /// groups swapping places can't say which of them moved.
    private var movedByCall: Int?

    nonisolated static func id(of nest: UUID) -> Int {
        let bytes = nest.uuid
        return (Int(bytes.0) << 23 | Int(bytes.1) << 15 | Int(bytes.2) << 7 | Int(bytes.3) >> 1) + 1
    }

    private var browser: Browser? { logicalBrowser ?? Extensions.shared.browser }
    private var row: [Tab] {
        if let browser = logicalBrowser, let profile = logicalProfile {
            return browser.tabs.filter { $0.chromiumProfile == profile && !$0.shy }
        }
        return Extensions.shared.visibleTabs
    }

    /// The folders of the row, by group id.
    private func groups() -> [Int: Nest] {
        var out: [Int: Nest] = [:]
        for tab in row { if let nest = tab.nest { out[Self.id(of: nest.id)] = nest } }
        return out
    }

    private func describe(_ nest: Nest) -> [String: Any] {
        let id = Self.id(of: nest.id)
        return ["id": id, "title": untitled.contains(nest.id) ? "" : nest.name, "color": colors[nest.id.uuidString] ?? "grey",
                "collapsed": !nest.open, "shared": false]
    }

    private func group(_ value: Any?) throws -> Nest {
        let id = (value as? NSNumber)?.intValue ?? -1
        guard let nest = groups()[id] else { throw ExtensionShims.Unsupported(what: "No group with id: \(id).") }
        return nest
    }

    private func tabs(_ value: Any?) -> [Tab] {
        let row = self.row
        return ((value as? [Any]) ?? []).compactMap { ($0 as? NSNumber)?.intValue }.compactMap { row.indices.contains($0) ? row[$0] : nil }
    }

    // MARK: - the extension's calls

    func run(_ api: String, _ args: [Any], context: WKWebExtensionContext) throws -> Any? {
        // chrome.tabGroups is the permission's; tabs.group and ungroup are
        // any extension's, as in Chromium. The permission named in the
        // manifest, or optional and granted since: OneTab asks for it at its
        // button's first press (or it was ticked when it was added), and
        // every call it then made was refused as never asked for, which
        // left its sends half done (feedback #156).
        if !["tabGroups.group", "tabGroups.ungroup"].contains(api) {
            guard ExtensionShims.allowed(context.uniqueIdentifier, context: context).contains("tabGroups") else {
                throw ExtensionShims.Unsupported(what: "The extension never asked for \u{201C}tabGroups\u{201D}")
            }
        }
        return try runLogical(api, args)
    }

    /// CEF has already checked the extension API permission and profile.
    func runLogical(_ api: String, _ args: [Any]) throws -> Any? {
        colors = Store.settings.dictionary(forKey: Self.colorsKey) as? [String: String] ?? [:]
        let first = args.first
        switch api {
        case "tabGroups.membership":
            return snapshot()
        case "tabGroups.get":
            return describe(try group(first))
        case "tabGroups.query":
            let query = first as? [String: Any] ?? [:]
            return groups().values.map(describe).filter { group in
                for key in ["title", "color", "collapsed"] where query[key] != nil {
                    guard let want = query[key] else { continue }
                    if let text = want as? String, text != group[key] as? String { return false }
                    if let flag = want as? Bool, flag != group[key] as? Bool { return false }
                }
                return true
            }.sorted { ($0["id"] as? Int ?? 0) < ($1["id"] as? Int ?? 0) }
        case "tabGroups.update":
            let nest = try group(first)
            let change = args.dropFirst().first as? [String: Any] ?? [:]
            if let color = change["color"] as? String {
                guard Self.colors.contains(color) else {
                    throw ExtensionShims.Unsupported(what: "Error at property 'color': Value must be one of \(Self.colors.joined(separator: ", ")).")
                }
                colors[nest.id.uuidString] = color
                Store.settings.set(colors, forKey: Self.colorsKey)
            }
            if let title = change["title"] as? String {
                untitled.remove(nest.id)
                nest.name = title.isEmpty ? "New Folder" : title
                if title.isEmpty { untitled.insert(nest.id) }
            }
            if let collapsed = change["collapsed"] as? Bool, collapsed == nest.open { Folders.shared.toggle(nest.key) }
            browser?.writeSession(now: true)
            changed()
            return describe(nest)
        case "tabGroups.move":
            let nest = try group(first)
            let index = ((args.dropFirst().first as? [String: Any])?["index"] as? NSNumber)?.intValue ?? -1
            if let browser {
                // Chrome's index is the row's, pins counted, where the
                // group's first tab is to stand; -1 the end of its kind.
                let pins = browser.tabs.filter { $0.pin != nil }.count
                if nest.today {
                    try browser.moveToday(nest, to: index < 0 ? -1 : index - pins)
                } else {
                    let kept = browser.tabs.filter { $0.pin == nil && $0.kept }
                    let others = kept.filter { $0.nest?.within(nest) != true }.count
                    browser.move(nest, to: index < 0 ? others : min(max(0, index - pins), others), in: nest.parent)
                }
            }
            movedByCall = Self.id(of: nest.id)
            changed()
            movedByCall = nil
            return describe(nest)
        case "tabGroups.group":
            let spec = first as? [String: Any] ?? [:]
            let going = tabs(spec["indices"])
            guard let browser, !going.isEmpty else { throw ExtensionShims.Unsupported(what: "No tab with id.") }
            let nest: Nest
            if let named = spec["groupId"] {
                nest = try group(named)
            } else {
                nest = Nest(name: "New Folder")
                untitled.insert(nest.id)
                colors[nest.id.uuidString] = Self.colors.first { color in !groups().values.contains { colors[$0.id.uuidString] == color } } ?? "grey"
                Store.settings.set(colors, forKey: Self.colorsKey)
                // Among today's, unless the first of them is kept.
                if going.first?.kept != true { nest.fleeting = true }
                nest.byExtension = true
            }
            browser.gather(going, into: nest)
            changed()
            return Self.id(of: nest.id)
        case "tabGroups.ungroup":
            let going = tabs((first as? [String: Any])?["indices"])
            guard let browser else { return nil }
            for tab in going where tab.nest != nil { browser.unfile(tab) }
            changed()
            return nil
        default:
            throw ExtensionShims.Unsupported(what: "\(api) isn't available in Yab")
        }
    }

    /// Which group each tab of the row is in, by its place, and the groups.
    private func snapshot() -> [String: Any] {
        ["members": row.map { tab in tab.nest.map { Self.id(of: $0.id) } ?? -1 },
         "groups": groups().values.map(describe)]
    }

    // MARK: - events

    private func byTab() -> [UUID: Int] {
        Dictionary(row.map { ($0.id, $0.nest.map { Self.id(of: $0.id) } ?? -1) }, uniquingKeysWith: { first, _ in first })
    }

    /// The groups in the order they first stand in the row.
    nonisolated static func order(_ members: [Int]) -> [Int] {
        var seen = Set<Int>()
        return members.filter { $0 != -1 && seen.insert($0).inserted }
    }

    /// The groups that moved among the others between two orders: of the
    /// groups in both, those outside the longest run that kept its order.
    /// A group moved past three others is the one that moved, not the three.
    nonisolated static func moved(from before: [Int], to after: [Int]) -> [Int] {
        let common = after.filter(before.contains)
        let places = common.compactMap { id in before.firstIndex(of: id) }
        guard places != places.sorted() else { return [] }
        // The longest increasing run of places (patience sorting), by index
        // into common.
        var tails: [Int] = [], ends: [Int] = []
        var parent = [Int](repeating: -1, count: places.count)
        for (i, place) in places.enumerated() {
            var low = 0, high = tails.count
            while low < high {
                let mid = (low + high) / 2
                if tails[mid] < place { low = mid + 1 } else { high = mid }
            }
            if low > 0 { parent[i] = ends[low - 1] }
            if low == tails.count {
                tails.append(place)
                ends.append(i)
            } else {
                tails[low] = place
                ends[low] = i
            }
        }
        var stay = Set<Int>()
        var at = ends.last ?? -1
        while at >= 0 {
            stay.insert(at)
            at = parent[at]
        }
        return common.indices.filter { !stay.contains($0) }.map { common[$0] }
    }

    /// The tabs whose group changed, as [place in the row, new group id]. A
    /// tab not seen before was in none: one opened since and put in a
    /// group is told, as Chromium tells a tab inserted into a group.
    nonisolated static func regrouped(from before: [UUID: Int], to row: [(UUID, Int)]) -> [[Int]] {
        row.enumerated().compactMap { place, entry in
            guard (before[entry.0] ?? -1) != entry.1 else { return nil }
            return [place, entry.1]
        }
    }

    func connect(_ port: WKWebExtension.MessagePort, from id: String) {
        ports[id] = (ports[id] ?? []).filter { !$0.isDisconnected } + [port]
        port.messageHandler = { [weak port] message, _ in
            MainActor.assumeIsolated {
                guard let port, let body = message as? [String: Any] else { return }
                if (body["__yabNative"] as? String) == "here?" { port.sendMessage(["__yabNative": "here"]) { _ in } }
                if body["ready"] != nil {
                    port.sendMessage(["heard": true]) { _ in }
                    port.sendMessage(["s": ExtensionGroups.shared.snapshot()]) { _ in }
                }
            }
        }
        port.disconnectHandler = { [weak self, weak port] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.ports[id] = (self.ports[id] ?? []).filter { $0 !== port && !$0.isDisconnected }
                if self.ports[id]?.isEmpty == true { self.ports[id] = nil }
                if self.ports.isEmpty { self.stopWatching() }
            }
        }
        startWatching()
    }

    /// The folders watched only while an extension listens.
    private func startWatching() {
        guard watch == nil else { return }
        last = groups().mapValues(describe)
        lastMembers = snapshot()["members"] as? [Int] ?? []
        lastByTab = byTab()
        lastOrder = Self.order(Array(lastMembers.prefix(browser?.tabs.count ?? 0)))
        watch = Folders.shared.observed(\.folders).sink { [weak self] _ in
            DispatchQueue.main.async { self?.changed() }
        }
    }

    private func stopWatching() {
        watch = nil
        nestWatches = []
    }

    /// What changed since last told: each extension hears created, updated
    /// and removed, and the row's groups afresh.
    func changed() {
        guard !ports.isEmpty else { return }
        let now = groups()
        let described = now.mapValues(describe)
        var events: [[Any]] = []
        for (id, group) in described {
            if let before = last[id] {
                if !NSDictionary(dictionary: before).isEqual(to: group) { events.append(["onUpdated", group]) }
            } else {
                events.append(["onCreated", group])
                events.append(["onUpdated", group])
            }
        }
        for (id, group) in last where described[id] == nil { events.append(["onRemoved", group]) }
        let members = snapshot()["members"] as? [Int] ?? []
        // The space on screen only: the others' rows come after it, and a
        // switch of spaces reorders them, which moves no group.
        let order = Self.order(Array(members.prefix(browser?.tabs.count ?? 0)))
        var moved = Self.moved(from: lastOrder, to: order)
        if let called = movedByCall, !moved.isEmpty, lastOrder.contains(called) { moved = [called] }
        for id in moved {
            if let group = described[id] { events.append(["onMoved", group]) }
        }
        let tabs = byTab()
        let regrouped = Self.regrouped(from: lastByTab, to: row.map { ($0.id, tabs[$0.id] ?? -1) })
        guard !events.isEmpty || !regrouped.isEmpty || members != lastMembers else { return }
        last = described
        lastMembers = members
        lastByTab = tabs
        lastOrder = order
        // A folder renamed or shut by hand changes no tab: heard from it.
        nestWatches = now.values.flatMap { nest in
            [nest.observed(\.name).dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.changed() } },
             nest.observed(\.open).dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.changed() } }]
        }
        let message: [String: Any] = ["e": events, "t": regrouped, "s":["members": members, "groups": Array(described.values)]]
        for port in ports.values.joined() where !port.isDisconnected { port.sendMessage(message) { _ in } }
    }
}

extension Browser {
    struct GroupMiddle: LocalizedError {
        var errorDescription: String? { "Cannot move the group to an index that is in the middle of another group." }
    }

    /// Where a folder of today's tabs goes when moved whole to stand at
    /// `index` among the unpinned (tabGroups.move): after the kept ones,
    /// -1 the end, never inside another folder's run, which Chrome
    /// refuses. `rest` is the unpinned row without the folder's tabs, as
    /// each one's folder (nil outside one) and whether it is kept.
    nonisolated static func todayPlace(_ index: Int, in rest: [(folder: UUID?, kept: Bool)]) throws -> Int {
        let kept = rest.filter(\.kept).count
        let at = index < 0 ? rest.count : min(max(kept, index), rest.count)
        if at > 0, at < rest.count, let before = rest[at - 1].folder, before == rest[at].folder { throw GroupMiddle() }
        return at
    }

    /// A folder of today's tabs moved whole (tabGroups.move).
    func moveToday(_ nest: Nest, to index: Int) throws {
        let members = tabs.filter { $0.nest === nest }
        guard !members.isEmpty else { return }
        var rest = tabs.filter { tab in tab.pin == nil && !members.contains { $0 === tab } }
        let at = try Self.todayPlace(index, in: rest.map { (folder: $0.nest?.id, kept: $0.kept) })
        rest.insert(contentsOf: members, at: at)
        lay(tabs.filter { $0.pin != nil } + rest)
        folderBook.refresh()
        writeSession(now: true)
    }

    /// Tabs into a folder an extension named (tabGroups): a kept folder's
    /// tabs kept in it, at the end of its run; a folder of today's tabs
    /// gathered where its first tab stands among today's.
    func gather(_ group: [Tab], into nest: Nest) {
        let going = tabs.filter { tab in tab.keepable && group.contains { $0 === tab } }
        guard !going.isEmpty else { return }
        if !nest.today {
            keepTabs(going, in: nest)
            return
        }
        let members = tabs.filter { tab in tab.nest === nest && !going.contains { $0 === tab } }
        let anchor = members.first ?? going[0]
        var loose = tabs.filter { tab in tab.pin == nil && !going.contains { $0 === tab } }
        for tab in going {
            tab.kept = false
            tab.nest = nest
        }
        let at = (loose.lastIndex { $0.nest === nest }.map { $0 + 1 }) ?? loose.firstIndex { $0 === anchor } ?? loose.count
        loose.insert(contentsOf: going, at: min(at, loose.count))
        lay(tabs.filter { $0.pin != nil } + loose)
        folderBook.refresh()
        writeSession(now: true)
    }
}
