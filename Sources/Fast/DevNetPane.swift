import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

// Network in the card, laid out as Chromium's panel (DevNet.swift): its
// toolbar, the filter row, the overview, the table with a request's
// details beside it, Search at the side, Network conditions and Request
// conditions in the drawer under it, and the status bar.

/// The design's small rounded box, using the Mac's accent in both themes.
struct NetCheckboxStyle: ToggleStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 5) { // design: match the Network reference's 5-point box-to-label gap
                RoundedRectangle(cornerRadius: 4) // design: the reference's 13-point checkbox has a 4-point corner
                    .fill(configuration.isOn ? Color(nsColor: NetInk.accent) : Palette.ink.opacity(0.025))
                    .overlay {
                        RoundedRectangle(cornerRadius: 4) // design: the border follows the checkbox's 4-point corner
                            .strokeBorder(configuration.isOn ? Color(nsColor: NetInk.accent) : Palette.muted.opacity(0.45), lineWidth: 1)
                    }
                    .overlay {
                        if configuration.isOn {
                            Image(systemName: "checkmark")
                                .font(.system(size: 8, weight: .bold)) // design: icon-sized tick inside the 13-point checkbox, not label text
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: 13, height: 13)
                configuration.label
            }
            .foregroundStyle(Palette.ink)
            .frame(minHeight: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
        .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
    }
}

/// What the panel shows of the log: the filter, the request picked and
/// its tab, the search, the drawer. One for the card, whichever tab it is
/// over.
@Observable final class NetPanel {
    var filter = NetFilter()
    var filterBar = true
    var settingsOpen = false
    var selected: Int?
    var detail: NetDetailTab = .headers
    var searchOpen = false
    var query = ""
    var matchCase = false
    var regex = false
    var searching = false
    var drawer: NetDrawer?
    var sort: NetSort?
    var hover: Int?
    var shift = false
    var shot: Double?
    /// The overrides on addresses, as yab made them: content, headers, both.
    var overridden: [String: String] = [:]
    var manageColumns = false
    /// Override headers asked for: the Headers tab opens its rows to edit.
    var editingHeaders = false
    /// Where the splits were dragged, as Chromium keeps them, apart for the
    /// card under the page and beside it: Search's width ("search.bottom"),
    /// the list's beside a request ("list.beside"), the drawer's height.
    /// None for the card's own.
    var splits: [String: CGFloat] = (Store.settings.dictionary(forKey: "net.splits") as? [String: Double] ?? [:])
        .mapValues { CGFloat($0) }
    @ObservationIgnored var focusSearch = false
    /// How wide the pane laid itself out and how wide the card let it be,
    /// for the bench: the first past the second cuts the card's edges.
    @ObservationIgnored var laid: CGFloat = 0
    @ObservationIgnored var room: CGFloat = 0

    @ObservationIgnored private var memo: (generation: Int, filter: NetFilter, sort: NetSort?, page: URL?, shown: [NetRow])?
    @ObservationIgnored private var foundMemo: (generation: Int, bodies: Int, query: String, matchCase: Bool, regex: Bool, ids: Set<Int>)?

    /// The requests Search finds its words in, lit in the list while it
    /// is open.
    func found(_ log: NetLog) -> Set<Int> {
        guard searchOpen, !query.isEmpty else { return [] }
        if let memo = foundMemo, memo.generation == log.generation, memo.bodies == log.bodies.count,
           memo.query == query, memo.matchCase == matchCase, memo.regex == regex { return memo.ids }
        let ids = Set(NetSearchSide.search(query, in: log, matchCase: matchCase, regex: regex).map(\.row.id))
        foundMemo = (log.generation, log.bodies.count, query, matchCase, regex, ids)
        return ids
    }

    /// The splits as dragged, kept for the next time, once a drag ends.
    func keepSplits() {
        Store.settings.set(splits.mapValues(Double.init), forKey: "net.splits")
    }

    /// The rows listed: filtered and in the order asked for.
    func shown(_ log: NetLog, page: URL?) -> [NetRow] {
        if let memo, memo.generation == log.generation, memo.filter == filter, memo.sort == sort, memo.page == page { return memo.shown }
        let overridden = self.overridden
        var rows = log.rows.filter { filter.admits($0, page: page, overridden: { overridden[$0] }) }
        if let sort { rows = Self.sorted(rows, by: sort) }
        memo = (log.generation, filter, sort, page, rows)
        return rows
    }

    static func sorted(_ rows: [NetRow], by sort: NetSort) -> [NetRow] {
        func key(_ row: NetRow) -> (Double, String) {
            switch sort.column {
            case "status": return (Double(row.failed ? -1 : row.status), "")
            case "size", "h:content-length": return (Double(row.fromCache ? -1 : row.transferred), "")
            case "time": return (row.duration ?? .infinity, "")
            case "waterfall": return (row.span.start, "")
            case "number", "connection": return (Double(row.resource.id), "")
            case "priority": return (Double(["low", "medium", "high"].firstIndex(of: row.resource.priority) ?? -1), "")
            case "cookies": return (Double(NetCookie.request(row).count), "")
            case "setcookies": return (Double(NetCookie.response(row).cookies.count), "")
            case "name": return (0, row.name.lowercased())
            case "path": return (0, row.path)
            case "url": return (0, row.url)
            case "method": return (0, row.method)
            case "type": return (0, row.typeLabel)
            case "initiator": return (0, row.initiatorLabel.place)
            case "domain": return (0, row.host)
            case "protocol": return (0, row.resource.proto)
            case "scheme": return (0, row.scheme)
            case "remote": return (0, row.resource.remote)
            case "space": return (0, NetAddress.space(row.resource.remote))
            default:
                if sort.column.hasPrefix("h:") { return (0, row.responseHeaders.value(String(sort.column.dropFirst(2))) ?? "") }
                if sort.column.hasPrefix("q:") { return (0, row.requestHeaders.value(String(sort.column.dropFirst(2))) ?? "") }
                return (row.span.start, "")
            }
        }
        let keyed = rows.enumerated().map { ($0.offset, key($0.element), $0.element) }
        return keyed.sorted { a, b in
            if a.1 == b.1 { return a.0 < b.0 }
            let less = a.1.0 != b.1.0 ? a.1.0 < b.1.0 : a.1.1.localizedStandardCompare(b.1.1) == .orderedAscending
            return sort.ascending ? less : !less
        }.map(\.2)
    }
}

enum NetDetailTab: String, CaseIterable {
    case headers = "Headers", payload = "Payload", preview = "Preview", response = "Response", messages = "Messages", eventStream = "EventStream"
    case initiator = "Initiator", timing = "Timing", cookies = "Cookies"
}

enum NetDrawer: String {
    case conditions = "Network conditions", rules = "Request conditions"
}

nonisolated(unsafe) private var netPanelKey: UInt8 = 0

extension Browser {
    var netPanel: NetPanel {
        if let panel = objc_getAssociatedObject(self, &netPanelKey) as? NetPanel { return panel }
        let panel = NetPanel()
        objc_setAssociatedObject(self, &netPanelKey, panel, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return panel
    }
}

// MARK: - the pane

struct DevNetPane: View {
    let browser: Browser
    var tab: Tab
    var log: NetLog
    @Bindable var panel: NetPanel
    @Bindable var prefs = NetPrefs.shared
    let side: DevSide
    /// The pane's width, for how far a line may be dragged across.
    @State private var room: CGFloat = 800
    /// The list's height with the drawer under it, for how far up the
    /// drawer may come.
    @State private var lower: CGFloat = 300

    /// A split's key: its name and where the card is.
    private func key(_ name: String) -> String { name + (side == .bottom ? ".bottom" : ".beside") }

    /// Search's width: as dragged, else the card's own, within the pane.
    private var searchWidth: CGFloat {
        let wanted = panel.splits[key("search")] ?? (side == .bottom ? 300 : 240)
        return max(180, min(wanted, room * 0.6))
    }

    /// The list's width beside a request, leaving the request 280: the
    /// header names and their values side by side.
    private func listWidth(after search: CGFloat) -> CGFloat {
        let wanted = panel.splits[key("list")] ?? (side == .bottom ? 240 : 170)
        return max(120, min(wanted, room - search - 280))
    }

    /// The drawer's height, leaving the list 60 over it.
    private var drawerHeight: CGFloat {
        let wanted = panel.splits[key("drawer")] ?? (side == .bottom ? 190 : 240)
        return max(80, min(wanted, lower - 60))
    }

    var body: some View {
        let shown = panel.shown(log, page: tab.address)
        let horizon = log.live
        let scale = NetScale.of(log.rows, contentLoaded: log.contentLoaded, loaded: log.loaded, horizon: horizon)
        VStack(spacing: 0) {
            NetToolbar(browser: browser, log: log, panel: panel, prefs: prefs)
            rule
            if panel.settingsOpen {
                NetSettingsRow(prefs: prefs)
                rule
            }
            if panel.filterBar {
                NetFilterBar(panel: panel, log: log, wide: side == .bottom)
                rule
            }
            if log.unavailable {
                unavailable
            } else {
                if prefs.screenshots, !log.shots.isEmpty {
                    NetFilmstrip(log: log, panel: panel, scale: scale)
                    rule
                }
                if prefs.overview, !log.rows.isEmpty {
                    NetOverview(model: .init(rows: log.rows, scale: scale, horizon: horizon, contentLoaded: log.contentLoaded,
                                             loaded: log.loaded, range: panel.filter.range, shot: panel.shot)) { panel.filter.range = $0 }
                        .frame(height: 58)
                    rule
                }
                let search = searchWidth
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        if panel.searchOpen {
                            NetSearchSide(browser: browser, log: log, panel: panel)
                                .frame(width: search)
                            NetSplitter(axis: .horizontal, size: search, range: 180...max(180, room * 0.6),
                                        set: { panel.splits[key("search")] = $0 }, done: panel.keepSplits)
                                .benchSpot("net split search")
                        }
                        let row = picked(shown)
                        table(shown, scale: scale, horizon: horizon)
                            .frame(width: row != nil ? listWidth(after: panel.searchOpen ? search : 0) : nil)
                            .frame(maxWidth: row != nil ? nil : .infinity)
                        if let row {
                            NetSplitter(axis: .horizontal, size: listWidth(after: panel.searchOpen ? search : 0),
                                        range: 120...max(120, room - (panel.searchOpen ? search : 0) - 280),
                                        set: { panel.splits[key("list")] = $0 }, done: panel.keepSplits)
                                .benchSpot("net split list")
                            NetDetails(browser: browser, tab: tab, log: log, panel: panel, row: row, wide: side == .bottom)
                                .id(row.id)
                        }
                    }
                    .frame(maxHeight: .infinity)
                    .overlay(alignment: .topTrailing) {
                        if panel.manageColumns {
                            NetManageColumns(prefs: prefs) { panel.manageColumns = false }
                                .padding(8)
                        }
                    }
                    if let drawer = panel.drawer {
                        let height = drawerHeight
                        NetSplitter(axis: .vertical, size: height, range: 80...max(80, lower - 60), sign: -1,
                                    set: { panel.splits[key("drawer")] = $0 }, done: panel.keepSplits)
                            .benchSpot("net split drawer")
                        NetDrawerView(browser: browser, log: log, panel: panel, prefs: prefs, drawer: drawer)
                            .frame(height: height)
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { lower = $0 }
            }
            rule
            NetStatusBar(log: log, shown: shown, all: log.rows, prefs: prefs)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { [panel] in panel.laid = $0 }
        // Whatever still runs wide is cut at the card's end, never centered
        // with its start cut off.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { [panel] in panel.room = $0 }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { room = $0 }
        .clipped()
        .onChange(of: prefs.keepLog) { browser.netApplyConditions() }
        .onChange(of: prefs.noCache) { browser.netApplyConditions() }
        .onChange(of: prefs.throttle) { browser.netApplyConditions() }
        .onChange(of: prefs.rules) { browser.netApplyConditions() }
        .onChange(of: prefs.rulesOn) { browser.netApplyConditions() }
        .onChange(of: prefs.userAgent) { browser.netApplyConditions() }
        .onChange(of: prefs.saveData) { browser.netApplyConditions() }
    }

    private var rule: some View {
        Rectangle().fill(Palette.ink.opacity(0.06)).frame(height: 1)
    }

    private func picked(_ shown: [NetRow]) -> NetRow? {
        guard let id = panel.selected else { return nil }
        return log.rows.first { $0.id == id }
    }

    /// The bridge didn't come up in this inspector: WebKit's own Network.
    private var unavailable: some View {
        VStack(spacing: 8) {
            Text("This Mac’s WebKit inspector isn’t one Yab’s Network knows")
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
            Button("Open WebKit’s Network") { browser.pickDevPane(.webkit(.requests)) }
                .buttonStyle(.yab(.secondary, .small))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func table(_ shown: [NetRow], scale: NetScale, horizon: Double?) -> some View {
        let columns = panel.selected != nil ? ["name"] : prefs.columns
        let chain = panel.shift ? panel.hover.map { NetChain.of($0, in: log.rows) } : nil
        let up = chain?.up ?? [], down = chain?.down ?? []
        let numbers = Dictionary(uniqueKeysWithValues: log.rows.enumerated().map { ($0.element.id, $0.offset + 1) })
        var overridden: [Int: String] = [:]
        if !panel.overridden.isEmpty { for row in shown { if let kind = panel.overridden[row.url] { overridden[row.id] = kind } } }
        let items: [NetItem] = prefs.groupByFrame ? NetChain.grouped(shown, page: tab.address) : shown.map(NetItem.row)
        let empty: String
        if log.rows.isEmpty {
            empty = log.recording ? "Recording network activity…\nPerform a request or hit ⌘R to record the reload." : "No network activity recorded.\nRecord with ⌘E, then perform a request or reload."
        } else {
            empty = "No requests match the filter."
        }
        return NetTableView(
            model: .init(items: items, numbers: numbers, columns: columns, selected: panel.selected, up: up, down: down, found: panel.found(log), big: prefs.bigRows,
                         scale: scale, horizon: horizon, contentLoaded: log.contentLoaded, loaded: log.loaded, sort: panel.sort,
                         overridden: overridden, empty: empty,
                         pageSpace: NetAddress.space(log.rows.last { $0.resource.main }?.resource.remote ?? "")),
            select: { id in
                if id != panel.selected, id != nil, panel.selected == nil { panel.detail = .headers }
                panel.selected = id
            },
            open: { browser.netOpenInTab($0) },
            sortBy: { column in
                if let sort = panel.sort, sort.column == column {
                    panel.sort = sort.ascending ? NetSort(column: column, ascending: false) : nil
                } else {
                    panel.sort = NetSort(column: column, ascending: true)
                }
            },
            hover: { id, shift in
                // Only Shift draws the chain: the panel isn't drawn again for
                // every move of the pointer.
                let wanted = shift ? id : nil
                if panel.hover != wanted { panel.hover = wanted }
                if panel.shift != shift { panel.shift = shift }
            },
            resend: { browser.netResend($0) },
            rowMenu: { browser.netRowMenu($0, shown: shown) },
            headMenu: { browser.netHeadMenu() },
            reveal: { browser.netRevealInitiator($0) }
        )
        .overlay(alignment: .bottom) {
            if log.rows.isEmpty, log.recording {
                Button { browser.reload() } label: {
                    HStack(spacing: 4) {
                        Symbol("arrow.clockwise", size: 10)
                        Text("Reload page")
                    }
                }
                .buttonStyle(.yab(.secondary, .small))
                .focusable(false)
                .padding(.bottom, 32)
            }
        }
    }
}

/// Who asked for whom, for Shift over a row, and the rows under their
/// frames for Group by frame.
enum NetChain {
    static func of(_ id: Int, in rows: [NetRow]) -> (up: Set<Int>, down: Set<Int>) {
        guard let row = rows.first(where: { $0.id == id }) else { return ([], []) }
        let byResource = Dictionary(rows.filter { $0.hop == nil }.map { ($0.resource.id, $0.id) }, uniquingKeysWith: { a, _ in a })
        var up = Set<Int>()
        var current = row.resource
        var guardCount = 0
        while let parent = current.initiator.resource, let parentRow = byResource[parent], guardCount < 50 {
            up.insert(parentRow)
            guard let next = rows.first(where: { $0.id == parentRow })?.resource else { break }
            current = next
            guardCount += 1
        }
        var down = Set<Int>()
        var queue = [row.resource.id]
        while let next = queue.popLast(), down.count < 2000 {
            for child in rows where child.hop == nil && child.resource.initiator.resource == next && !down.contains(child.id) {
                down.insert(child.id)
                queue.append(child.resource.id)
            }
        }
        return (up, down)
    }

    static func grouped(_ rows: [NetRow], page: URL?) -> [NetItem] {
        var order: [String] = []
        var byFrame: [String: [NetRow]] = [:]
        var titles: [String: String] = [:]
        for row in rows {
            let frame = row.resource.frame
            if byFrame[frame] == nil { order.append(frame) }
            byFrame[frame, default: []].append(row)
            if row.resource.type == "document", row.hop == nil, titles[frame] == nil { titles[frame] = row.url }
        }
        var items: [NetItem] = []
        for (index, frame) in order.enumerated() {
            let title = index == 0 ? "top" : (titles[frame] ?? "frame \(frame)")
            items.append(.frame(title))
            items.append(contentsOf: byFrame[frame, default: []].map(NetItem.row))
        }
        return items
    }
}

// MARK: - the toolbar

/// A split's line, dragged as Chromium's: the hairline between two parts and
/// a few points either side of it to take hold of. Horizontal moves a line
/// standing up (Search's width, the list's), vertical one lying down (the
/// drawer's height, grown by dragging up: `sign` -1).
struct NetSplitter: View {
    let axis: Axis
    let size: CGFloat
    let range: ClosedRange<CGFloat>
    var sign: CGFloat = 1
    let set: (CGFloat) -> Void
    let done: () -> Void
    @State private var from: CGFloat?

    var body: some View {
        let across = axis == .horizontal
        ZStack {
            Color.clear
            Rectangle().fill(Palette.ink.opacity(0.06))
                .frame(width: across ? 1 : nil, height: across ? nil : 1)
        }
        .frame(width: across ? 6 : nil, height: across ? nil : 6)
        .frame(maxWidth: across ? nil : .infinity, maxHeight: across ? .infinity : nil)
        .contentShape(Rectangle())
        .pointerStyle(.frameResize(position: across ? .trailing : .top))
        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { drag in
                let start = from ?? size
                if from == nil { from = start }
                let moved = across ? drag.translation.width : drag.translation.height
                set(min(range.upperBound, max(range.lowerBound, (start + sign * moved).rounded())))
            }
            .onEnded { _ in
                from = nil
                done()
            })
        .accessibilityHidden(true)
    }
}

struct NetToolbar: View {
    let browser: Browser
    var log: NetLog
    @Bindable var panel: NetPanel
    @Bindable var prefs: NetPrefs

    var body: some View {
        HStack(spacing: 2) {
            // Beside the page the card is 460 to 500 points: what has no room
            // scrolls, the gear stays at the end.
            ThreadScrollView(.horizontal, showsIndicators: false) {
                tools
            }
            Spacer(minLength: 4)
            icon("gearshape", "Network settings", on: panel.settingsOpen) { panel.settingsOpen.toggle() }
        }
        .font(.system(size: 11.5))
        .focusable(false)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .frame(height: 30)
    }

    private var tools: some View {
        HStack(spacing: 2) {
            Button { log.recording.toggle() } label: {
                Circle()
                    .fill(log.recording ? DevLook.red : Color.clear)
                    .overlay(Circle().strokeBorder(log.recording ? Color.clear : Palette.muted, lineWidth: 1.5))
                    .frame(width: 10, height: 10)
                    // Recording, a ring of its red round it, as Chromium's.
                    .background(Circle().fill(DevLook.red.opacity(log.recording ? 0.14 : 0)).frame(width: 16, height: 16))
            }
            .buttonStyle(.yab(.quiet, .small, tint: Palette.ink, icon: .square))
            .keyTip(log.recording ? "Stop recording network log" : "Record network log", keys: "⌘E")
            icon("nosign", "Clear network log", keys: "⌘K") { browser.netClear() }
            divider
            Button { panel.filterBar.toggle() } label: {
                Symbol("funnel", size: 11)
                    .overlay(alignment: .topTrailing) {
                        if panel.filter.isActive { Circle().fill(Color(nsColor: NetInk.accent)).frame(width: 5, height: 5).offset(x: 3, y: -2) }
                    }
            }
            .buttonStyle(.yab(panel.filterBar ? .secondary : .quiet, .small, tint: Palette.ink, icon: .square))
            .keyTip("Filter")
            icon("magnifyingglass", "Search", keys: "⌘F", on: panel.searchOpen) {
                panel.searchOpen.toggle()
                panel.focusSearch = panel.searchOpen
            }
            divider
            check("Keep log", $prefs.keepLog, tip: "Don’t clear log on page reload / navigation")
            divider
            check("Disable cache", $prefs.noCache, tip: "Disable cache while DevTools is open")
            throttling
            icon("wifi", "More network conditions…", on: panel.drawer == .conditions) {
                panel.drawer = panel.drawer == .conditions ? nil : .conditions
            }
            divider
            icon("arrow.up.from.line", "Import HAR file…") { browser.netImportHAR() }
            Menu {
                Button("Export HAR (sanitized)…") { browser.netExportHAR(sanitized: true) }
                Button("Export HAR (with sensitive data)…") { browser.netExportHAR(sanitized: false) }
            } label: {
                HStack(spacing: 4) {
                    Symbol("arrow.down.to.line", size: 11)
                    Symbol("chevron.down", size: 8)
                }
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.yab(.quiet, .small, tint: Palette.ink))
            .fixedSize()
            .keyTip("Export HAR (sanitized)…")
        }
    }

    private var divider: some View {
        Rectangle().fill(Palette.ink.opacity(0.1)).frame(width: 1, height: 14).padding(.horizontal, 4)
    }

    private func icon(_ name: String, _ title: String, keys: String? = nil, on: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Symbol(name, size: 11) }
            .buttonStyle(.yab(on ? .secondary : .quiet, .small, tint: Palette.ink, icon: .square))
            .keyTip(title, keys: keys)
    }

    private func check(_ title: String, _ value: Binding<Bool>, tip: String) -> some View {
        Toggle(isOn: value) { Text(title).font(.system(size: 11.5)).fixedSize() }
            .toggleStyle(NetCheckboxStyle())
            .controlSize(.small)
            .padding(.horizontal, 4)
            .pointerTip(tip)
    }

    /// Chrome's throttling menu: none, its presets, Offline, your own.
    private var throttling: some View {
        let current = NetThrottle.named(prefs.throttle)
        return Menu {
            Section("Disabled") {
                Button { prefs.throttle = NetThrottle.none.id } label: { mark(NetThrottle.none.name, prefs.throttle == NetThrottle.none.id) }
            }
            Section("Presets") {
                ForEach(NetThrottle.presets + [NetThrottle.offline]) { preset in
                    Button { prefs.throttle = preset.id } label: { mark(preset.name, prefs.throttle == preset.id) }
                }
            }
            Section("Custom") {
                ForEach(prefs.profiles) { profile in
                    Button { prefs.throttle = profile.id } label: { mark(profile.name, prefs.throttle == profile.id) }
                }
                Button("Add…") { panel.drawer = .conditions; NetPrefs.shared.addProfile() }
            }
        } label: {
            HStack(spacing: 4) {
                if current != nil { Symbol("exclamationmark.triangle", size: 10).foregroundStyle(DevLook.amber) }
                Text(current?.name ?? NetThrottle.none.name).fixedSize()
                Symbol("chevron.down", size: 8)
            }
            .foregroundStyle(current != nil ? DevLook.amber : Palette.ink)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.yab(.quiet, .small, tint: current != nil ? DevLook.amber : Palette.ink))
        .fixedSize()
        .keyTip("Throttling")
    }

    @ViewBuilder private func mark(_ title: String, _ on: Bool) -> some View {
        if on { Label(title, systemImage: "checkmark") } else { Text(title) }
    }
}

/// The gear's row: Chrome's four settings, as checkboxes.
struct NetSettingsRow: View {
    @Bindable var prefs: NetPrefs

    var body: some View {
        HStack(spacing: 16) {
            box("Big request rows", $prefs.bigRows, "Show more information in request rows")
            box("Group by frame", $prefs.groupByFrame, "Group requests by top level request frame")
            box("Overview", $prefs.overview, "Show overview of network requests")
            box("Screenshots", $prefs.screenshots, "Capture screenshots when loading a page")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .frame(height: 26)
        .clipped()
        .background(Palette.ink.opacity(0.025))
    }

    private func box(_ title: String, _ value: Binding<Bool>, _ tip: String) -> some View {
        Toggle(isOn: value) { Text(title).font(.system(size: 11.5)).fixedSize() }
            .toggleStyle(NetCheckboxStyle())
            .controlSize(.small)
            .pointerTip(tip)
    }
}

// MARK: - the filter row

struct NetFilterBar: View {
    @Bindable var panel: NetPanel
    var log: NetLog
    let wide: Bool
    @FocusState private var typing: Bool

    var body: some View {
        // Each chip a place of its own, so a narrow card wraps them.
        NetFlowRow(spacing: 2) {
            field
            Toggle(isOn: $panel.filter.invert) { Text("Invert").font(.system(size: 11.5)).fixedSize() }
                .toggleStyle(NetCheckboxStyle())
                .controlSize(.small)
                .padding(.horizontal, 4)
                .pointerTip("Inverts the search filter")
            more
            Rectangle().fill(Palette.ink.opacity(0.1)).frame(width: 1, height: 14).padding(.horizontal, 4)
            chip(nil, "All", "")
            ForEach(NetCategory.allCases, id: \.self) { chip($0, $0.title, $0.tip + " · ⌘-click to select multiple types") }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private var field: some View {
        HStack(spacing: 4) {
            Symbol("magnifyingglass", size: 10).foregroundStyle(Palette.muted)
            TextField("Filter", text: $panel.filter.text)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .focused($typing)
                .onSubmit { complete() }
            if !panel.filter.text.isEmpty {
                Button { panel.filter.text = "" } label: { Symbol("xmark.circle.fill", size: 10).foregroundStyle(Palette.muted) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6)
        .frame(width: wide ? 260 : 180, height: ButtonSize.small.height)
        .background(Palette.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .pointerTip("e.g. /small[\\d]+/ url:a.com/b")
        .overlay(alignment: .topLeading) {
            let options = typing ? NetFilter.completions(panel.filter.text, rows: log.rows) : []
            if !options.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(options, id: \.self) { option in
                        Button { take(option) } label: {
                            Text(option).font(DevMono.font(11.5)).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.yab(.quiet, .small, tint: Palette.ink))
                    }
                }
                .padding(4)
                .frame(width: 240)
                .cardFrame()
                .offset(y: ButtonSize.small.height + 4)
                .zIndex(10)
            }
        }
        .zIndex(10)
    }

    private func complete() {
        if let first = NetFilter.completions(panel.filter.text, rows: log.rows).first { take(first) }
    }

    private func take(_ option: String) {
        var words = panel.filter.text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        let negated = words.last?.hasPrefix("-") == true
        if words.isEmpty { words = [""] }
        words[words.count - 1] = (negated ? "-" : "") + option
        panel.filter.text = words.joined(separator: " ") + (option.hasSuffix(":") ? "" : " ")
    }

    /// More filters: what to hide, what alone to show, with how many are on.
    private var more: some View {
        let on = [panel.filter.hideData, panel.filter.hideExtensions, panel.filter.onlyBlocked, panel.filter.onlyThirdParty].filter { $0 }.count
        return Menu {
            Toggle("Hide data URLs", isOn: $panel.filter.hideData)
            Toggle("Hide extension URLs", isOn: $panel.filter.hideExtensions)
            Divider()
            Toggle("Blocked response cookies", isOn: .constant(false)).disabled(true)
            Toggle("Blocked requests", isOn: $panel.filter.onlyBlocked)
            Toggle("3rd-party requests", isOn: $panel.filter.onlyThirdParty)
        } label: {
            HStack(spacing: 4) {
                Text(on > 0 ? "More filters · \(on)" : "More filters").fixedSize()
                Symbol("chevron.down", size: 8)
            }
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.yab(on > 0 ? .secondary : .quiet, .small, tint: Palette.ink))
        .fixedSize()
        .keyTip("Show only/hide requests")
    }

    private func chip(_ category: NetCategory?, _ title: String, _ tip: String) -> some View {
        let on = category.map { panel.filter.types.contains($0) } ?? panel.filter.types.isEmpty
        return Button {
            guard let category else { panel.filter.types = []; return }
            if NSEvent.modifierFlags.contains(.command) {
                if panel.filter.types.contains(category) { panel.filter.types.remove(category) } else { panel.filter.types.insert(category) }
            } else {
                panel.filter.types = [category]
            }
        } label: {
            Text(title).font(.system(size: 11.5, weight: .medium)).fixedSize()
        }
        .buttonStyle(.yab(on ? .secondary : .quiet, .small, tint: Palette.ink))
        .keyTip(tip)
    }
}

/// Views in a row, wrapping onto the next where the row has no room, as
/// Chrome's filter row wraps in a narrow DevTools.
struct NetFlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 800
        return lay(width, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, point) in lay(bounds.width, subviews).points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    /// Lines left to right, wrapping, each thing in the middle of its
    /// line's height: a checkbox beside the taller field and chips.
    private func lay(_ width: CGFloat, _ subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        var x: CGFloat = 0, y: CGFloat = 0, widest: CGFloat = 0
        var points: [CGPoint] = [], line: [(index: Int, height: CGFloat)] = []
        func close() {
            let tallest = line.map(\.height).max() ?? 0
            for item in line { points[item.index].y = y + ((tallest - item.height) / 2).rounded() }
            y += tallest
            line = []
        }
        for (index, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                close()
                y += 4
                x = 0
            }
            points.append(CGPoint(x: x, y: 0))
            line.append((index, size.height))
            x += size.width + spacing
            widest = max(widest, x - spacing)
        }
        close()
        return (CGSize(width: widest, height: y), points)
    }
}

// MARK: - status and film

struct NetStatusBar: View {
    var log: NetLog
    let shown: [NetRow]
    let all: [NetRow]
    @Bindable var prefs: NetPrefs

    var body: some View {
        let filtered = shown.count != all.count
        let origin = log.origin ?? 0
        let finish = all.filter { !$0.pending }.compactMap(\.span.end).max().map { ($0 - origin) * 1000 }
        func bytes(_ rows: [NetRow], _ f: (NetRow) -> Int) -> Int { rows.reduce(0) { $0 + ($1.failed ? 0 : f($1)) } }
        let sent = { (row: NetRow) in row.fromCache ? 0 : row.transferred }
        return HStack(spacing: 0) {
            part((filtered ? "\(shown.count.formatted()) / " : "") + "\(all.count.formatted()) requests", first: true)
            part((filtered ? NetFormat.size(bytes(shown, sent)) + " / " : "") + NetFormat.size(bytes(all, sent)) + " transferred")
            part((filtered ? NetFormat.size(bytes(shown, \.size)) + " / " : "") + NetFormat.size(bytes(all, \.size)) + " resources")
            if let finish, log.origin != nil, finish >= 0 { part("Finish: " + NetFormat.time(finish)) }
            if let at = log.contentLoaded { part("DOMContentLoaded: " + NetFormat.time((at - origin) * 1000), Color(nsColor: NetInk.contentLoaded)) }
            if let at = log.loaded { part("Load: " + NetFormat.time((at - origin) * 1000), Color(nsColor: NetInk.loaded)) }
            if let throttle = NetThrottle.named(prefs.throttle) { part(throttle.name, DevLook.amber) }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11).monospacedDigit())
        .foregroundStyle(Palette.muted)
        .lineLimit(1)
        .padding(.horizontal, 4)
        // Beside the page the sums run past the card: cut at its end, as
        // Chrome's are, never widening the pane.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .frame(height: 24)
        .clipped()
    }

    /// One sum, a line between it and the one before, none after the last.
    private func part(_ words: String, _ ink: Color? = nil, first: Bool = false) -> some View {
        HStack(spacing: 0) {
            if !first { Rectangle().fill(Palette.ink.opacity(0.08)).frame(width: 1, height: 12) }
            Text(words).foregroundStyle(ink ?? Palette.muted).fixedSize().padding(.horizontal, 6)
        }
    }
}

/// Screenshots: the page as it loaded, its moment under each; over one,
/// its moment on the overview, a click keeps the requests up to it.
struct NetFilmstrip: View {
    var log: NetLog
    @Bindable var panel: NetPanel
    let scale: NetScale

    var body: some View {
        ThreadScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(log.shots.enumerated()), id: \.offset) { _, shot in
                    Button {
                        panel.filter.range = scale.origin...shot.at
                    } label: {
                        VStack(spacing: 2) {
                            Image(nsImage: shot.image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 88, height: 54)
                                .overlay(RoundedRectangle(cornerRadius: Radius.small).strokeBorder(Palette.ink.opacity(0.1)))
                            Text(NetFormat.time((shot.at - scale.origin) * 1000))
                                .font(.system(size: 10).monospacedDigit())
                                .foregroundStyle(Palette.muted)
                        }
                    }
                    .buttonStyle(.plain)
                    .onHover { inside in panel.shot = inside ? shot.at : (panel.shot == shot.at ? nil : panel.shot) }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }
}

/// Manage Header Columns: the headers shown as columns, your own added.
struct NetManageColumns: View {
    @Bindable var prefs: NetPrefs
    let done: () -> Void
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Header columns").font(.system(size: 12, weight: .semibold))
            let headers = prefs.columns.filter { $0.hasPrefix("h:") || $0.hasPrefix("q:") }
            if headers.isEmpty {
                Text("No custom headers").font(.system(size: 11.5)).foregroundStyle(Palette.muted)
            }
            ForEach(headers, id: \.self) { id in
                HStack {
                    Text((id.hasPrefix("h:") ? "Response · " : "Request · ") + id.dropFirst(2)).font(.system(size: 11.5))
                    Spacer()
                    Button { prefs.columns.removeAll { $0 == id } } label: { Symbol("xmark", size: 11) }
                        .buttonStyle(.yab(.quiet, .small, icon: .square))
                }
            }
            HStack(spacing: 4) {
                TextField("Add custom header…", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11.5))
                    .onSubmit(add)
                Button("Add", action: add).buttonStyle(.yab(.secondary, .small)).disabled(name.isEmpty)
            }
            HStack {
                Spacer()
                Button("Done", action: done).buttonStyle(.yab(.primary, .small))
            }
        }
        .frame(width: 260)
        .cardFrame()
    }

    private func add() {
        let header = name.trimmingCharacters(in: .whitespaces)
        guard !header.isEmpty else { return }
        let id = "h:" + header
        if !prefs.columns.contains(id) { prefs.columns.insert(id, at: max(0, prefs.columns.count - 1)) }
        name = ""
    }
}

extension NetPrefs {
    /// Created while the row still exists: its action must not read the
    /// collection's Binding after removing that row.
    func profileRemovalAction(id: String) -> () -> Void {
        { [weak self] in self?.removeProfile(id: id) }
    }

    func removeProfile(id: String) {
        profiles.removeAll { $0.id == id }
        if throttle == id { throttle = NetThrottle.none.id }
    }

    /// Add… in the throttling menu: a profile of your own, to be named and
    /// set in Network conditions.
    func addProfile() {
        var n = profiles.count + 1
        while profiles.contains(where: { $0.name == "Custom \(n)" }) { n += 1 }
        profiles.append(NetThrottle(id: "custom-" + UUID().uuidString.prefix(8).lowercased(), name: "Custom \(n)", latency: 100, download: 10_000, upload: 5_000))
    }
}

// MARK: - menus

extension Browser {
    /// A request's menu, in Chrome's order; yab's two at its end where
    /// Chrome's Debug with AI is.
    func netRowMenu(_ row: NetRow, shown: [NetRow]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func item(_ title: String, enabled: Bool = true, _ act: @escaping () -> Void) -> NSMenuItem {
            let made = PageMenuItem(title, act: act)
            made.isEnabled = enabled
            return made
        }
        func sub(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let made = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let inner = NSMenu()
            inner.autoenablesItems = false
            items.forEach(inner.addItem)
            made.submenu = inner
            return made
        }
        let r = row.resource
        let sourceKinds: Set<String> = ["script", "stylesheet", "document"]
        menu.addItem(item("Open in Sources panel", enabled: sourceKinds.contains(r.type) && row.hop == nil) { self.netReveal(row) })
        menu.addItem(item("Open in new tab", enabled: row.scheme == "http" || row.scheme == "https") { self.netOpenInTab(row) })
        menu.addItem(.separator())
        menu.addItem(item("Clear browser cache") { self.netClearBrowser(cookies: false) })
        menu.addItem(item("Clear browser cookies") { self.netClearBrowser(cookies: true) })
        menu.addItem(.separator())
        let all = shown.count != (toolsFront?.netLog.rows.count ?? shown.count) ? "Copy all listed" : "Copy all"
        var copy: [NSMenuItem] = [
            item("Copy URL") { self.copyForAgent(row.url, "Copied URL") },
            item("Copy as cURL") { self.copyForAgent(NetCopy.curl(row), "Copied as cURL") },
            item("Copy as PowerShell") { self.copyForAgent(NetCopy.powerShell(row), "Copied as PowerShell") },
            item("Copy as fetch") { self.copyForAgent(NetCopy.fetch(row, node: false), "Copied as fetch") },
            item("Copy as fetch (Node.js)") { self.copyForAgent(NetCopy.fetch(row, node: true), "Copied as fetch (Node.js)") },
            item("Copy as preload element", enabled: NetCopy.preload(row) != nil) { if let text = NetCopy.preload(row) { self.copyForAgent(text, "Copied as preload element") } },
            .separator(),
            item("Copy request headers", enabled: !row.requestHeaders.isEmpty) { self.copyForAgent(NetCopy.headers(row.requestHeaders), "Copied request headers") },
            item("Copy response headers", enabled: !row.responseHeaders.isEmpty) { self.copyForAgent(NetCopy.headers(row.responseHeaders), "Copied response headers") },
        ]
        if row.finished, row.hop == nil, !row.failed {
            copy.append(item("Copy response") { self.netBody(row) { body in
                self.copyForAgent(body.base64 ? body.text : body.text, body.error == nil ? "Copied response" : "This request has no response data available")
            } })
        }
        if let stack = NetCopy.stack(row) { copy.append(item("Copy stack trace") { self.copyForAgent(stack, "Copied stack trace") }) }
        copy.append(.separator())
        copy.append(item(all + " URLs") { self.copyForAgent(shown.map(\.url).joined(separator: "\n"), "Copied URLs") })
        copy.append(item(all + " as cURL") { self.copyForAgent(shown.map(NetCopy.curl).joined(separator: " ;\n"), "Copied as cURL") })
        copy.append(item(all + " as PowerShell") { self.copyForAgent(shown.map(NetCopy.powerShell).joined(separator: ";\n"), "Copied as PowerShell") })
        copy.append(item(all + " as fetch") { self.copyForAgent(shown.map { NetCopy.fetch($0, node: false) }.joined(separator: " ;\n"), "Copied as fetch") })
        copy.append(item(all + " as fetch (Node.js)") { self.copyForAgent(shown.map { NetCopy.fetch($0, node: true) }.joined(separator: " ;\n"), "Copied as fetch (Node.js)") })
        copy.append(item(all + " as HAR (sanitized)") { self.netHAR(shown, sanitized: true) { self.copyForAgent($0, "Copied as HAR, cookies and tokens left out") } })
        copy.append(item(all + " as HAR (with sensitive data)") { self.netHAR(shown, sanitized: false) { self.copyForAgent($0, "Copied as HAR with cookies and tokens") } })
        menu.addItem(sub("Copy", copy))
        menu.addItem(.separator())
        let prefs = NetPrefs.shared
        let address = row.url.components(separatedBy: "?").first ?? row.url
        let domain = "*\(row.host)*"
        func toggle(_ pattern: String, _ condition: String, add: String, remove: String) -> NSMenuItem {
            if let rule = prefs.rules.first(where: { $0.pattern == pattern && ($0.condition == "block") == (condition == "block") }) {
                return item(remove + " " + pattern) { prefs.rules.removeAll { $0.id == rule.id } }
            }
            return item(add) { self.netAddRule(pattern, condition) }
        }
        menu.addItem(sub("Block requests", [
            toggle(address, "block", add: "Block request URL", remove: "Unblock"),
            toggle(domain, "block", add: "Block request domain", remove: "Unblock"),
        ]))
        menu.addItem(sub("Throttle requests", [
            toggle(address, NetThrottle.slow3G.id, add: "Throttle request URL", remove: "Stop throttling"),
            toggle(domain, NetThrottle.slow3G.id, add: "Throttle request domain", remove: "Stop throttling"),
        ]))
        let resendable: Set<String> = ["fetch", "xhr", "script", "stylesheet", "image", "font", "other"]
        let resend = item("Resend", enabled: resendable.contains(r.type) && row.hop == nil) { self.netResend(row) }
        resend.keyEquivalent = "r"
        resend.keyEquivalentModifierMask = []
        menu.addItem(resend)
        menu.addItem(item("Edit and resend as fetch", enabled: row.hop == nil && (row.scheme == "http" || row.scheme == "https")) { self.netEditResend(row) })
        menu.addItem(.separator())
        menu.addItem(sub("Sort by", (prefs.columns.filter { $0 != "waterfall" } + ["waterfall"]).compactMap(NetColumn.named).map { column in
            let made = item(column.title) { self.netPanel.sort = NetSort(column: column.id, ascending: true) }
            made.state = self.netPanel.sort?.column == column.id ? .on : .off
            return made
        }))
        let head = netHeadMenu()
        let headItems = head.items
        headItems.forEach(head.removeItem)
        menu.addItem(sub("Header options", headItems))
        menu.addItem(.separator())
        menu.addItem(item("Override headers", enabled: row.hop == nil && row.finished) { self.netPanel.selected = row.id; self.netPanel.detail = .headers; self.netEditingHeaders = true })
        menu.addItem(item("Override content", enabled: row.hop == nil && row.finished && !row.failed) { self.netOverrideContent(row) })
        menu.addItem(item("Show all overrides") { self.netShowOverrides() })
        menu.addItem(.separator())
        if r.type == "image" {
            menu.addItem(item("Save image", enabled: row.finished && !row.failed) { self.netSave(row) })
        } else {
            menu.addItem(item("Save as…", enabled: sourceKinds.contains(r.type) && row.finished && !row.failed) { self.netSave(row) })
        }
        menu.addItem(.separator())
        menu.addItem(sub("Ask in Chat", [
            item("Start a chat") { self.netAsk([row], question: "") },
            .separator(),
            item("Explain purpose") { self.netAsk([row], question: "What is the purpose of this request?") },
            item("Explain slowness") { self.netAsk([row], question: "Why is this request taking so long?") },
            item("Explain failures") { self.netAsk([row], question: "Why is the request failing?") },
            item("Assess security headers") { self.netAsk([row], question: "Are there any security headers present?") },
        ]))
        menu.addItem(item("Copy for Agent") { self.netCopyForAgent([row]) })
        return menu
    }

    /// The table head's menu: the columns, the headers as columns, the
    /// waterfall's order.
    func netHeadMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let prefs = NetPrefs.shared
        func toggle(_ column: NetColumn) -> NSMenuItem {
            let item = PageMenuItem(column.title) {
                if prefs.columns.contains(column.id) {
                    if column.id != "name" { prefs.columns.removeAll { $0 == column.id } }
                } else {
                    var columns = prefs.columns
                    let order = NetColumn.listed.map(\.id)
                    let at = columns.firstIndex { (order.firstIndex(of: $0) ?? 999) > (order.firstIndex(of: column.id) ?? 999) } ?? columns.count
                    columns.insert(column.id, at: at)
                    prefs.columns = columns
                }
            }
            item.state = prefs.columns.contains(column.id) ? .on : .off
            item.isEnabled = column.id != "name"
            return item
        }
        for column in NetColumn.listed where column.id != "name" { menu.addItem(toggle(column)) }
        menu.addItem(.separator())
        func headers(_ title: String, _ names: [String], prefix: String) -> NSMenuItem {
            let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let inner = NSMenu()
            for name in names { inner.addItem(toggle(NetColumn(id: prefix + name, title: name, width: 110))) }
            inner.addItem(.separator())
            inner.addItem(PageMenuItem("Manage Header Columns…") { self.netPanel.manageColumns = true })
            parent.submenu = inner
            return parent
        }
        menu.addItem(headers("Response headers", NetColumn.responseHeaders, prefix: "h:"))
        menu.addItem(headers("Request headers", NetColumn.requestHeaders, prefix: "q:"))
        let waterfall = NSMenuItem(title: "Waterfall", action: nil, keyEquivalent: "")
        let order = NSMenu()
        for (title, column) in [("Start time", "waterfall"), ("Response time", "waterfall"), ("End time", "waterfall"), ("Total duration", "time"), ("Latency", "time")] {
            let item = PageMenuItem(title) { self.netPanel.sort = NetSort(column: column, ascending: true) }
            item.state = netPanel.sort?.column == column && title == (column == "time" ? "Total duration" : "Start time") ? .on : .off
            order.addItem(item)
        }
        waterfall.submenu = order
        menu.addItem(waterfall)
        menu.addItem(.separator())
        menu.addItem(PageMenuItem("Reset columns") { prefs.columns = NetColumn.defaults })
        return menu
    }
}

// MARK: - what the panel does

extension Browser {
    var netEditingHeaders: Bool {
        get { netPanel.editingHeaders }
        set { netPanel.editingHeaders = newValue }
    }

    func netClear() {
        toolsFront?.netLog.clear()
        netPanel.selected = nil
        netPanel.filter.range = nil
    }

    func netOpenInTab(_ row: NetRow) {
        guard let url = URL(string: row.url), url.scheme == "http" || url.scheme == "https" else { return }
        _ = open(url, foreground: true, from: toolsFront)
    }

    func netReveal(_ row: NetRow) {
        pickDevPane(.webkit(.sources))
        netRun("__yabNet.reveal(id)", arguments: ["id": row.resource.bridge])
    }

    /// The initiator's link: the line that asked, in Sources; a redirect's
    /// or a preflight's, the row it came from.
    func netRevealInitiator(_ row: NetRow) {
        if let from = row.from { netPanel.selected = from; return }
        let initiator = row.resource.initiator
        let place = initiator.stack.first.map { DevPlace(url: $0.url, line: $0.line, column: $0.column) }
            ?? (initiator.url.isEmpty ? nil : DevPlace(url: initiator.url, line: max(1, initiator.line), column: max(1, initiator.column)))
        guard let place else { return }
        revealSource(place)
    }

    func netResend(_ row: NetRow) {
        netRun("__yabNet.resend(id)", arguments: ["id": row.resource.bridge]) { [weak self] done in
            if done as? Bool != true { self?.announce("Couldn’t resend this request", mark: "exclamationmark.triangle") }
        }
    }

    /// Edit and resend as fetch: the request as a fetch() at Console's
    /// prompt, to change and run.
    func netEditResend(_ row: NetRow) {
        pickDevPane(.console)
        consolePanel.prefill = NetCopy.fetch(row, node: false)
    }

    func netOverrideContent(_ row: NetRow) {
        pickDevPane(.webkit(.sources))
        netRun("__yabNet.overrideContent(id)", arguments: ["id": row.resource.bridge]) { [weak self] done in
            guard done as? Bool == true, let self else { return }
            netMarkOverride(row.url, "content")
        }
    }

    func netOverrideHeaders(_ row: NetRow, _ headers: [String: String]) {
        netRun("__yabNet.overrideHeaders(id, h)", arguments: ["id": row.resource.bridge, "h": headers]) { [weak self] done in
            guard let self else { return }
            if done as? Bool == true {
                netMarkOverride(row.url, "headers")
                announce("Header overrides apply from the next load", mark: "arrow.clockwise")
            } else {
                announce("Couldn’t override this request’s headers", mark: "exclamationmark.triangle")
            }
        }
    }

    private func netMarkOverride(_ url: String, _ kind: String) {
        let was = netPanel.overridden[url]
        netPanel.overridden[url] = was == nil || was == kind ? kind : "both"
    }

    func netShowOverrides() {
        pickDevPane(.webkit(.sources))
        netRun("__yabNet.showOverrides()")
    }

    func netAddRule(_ pattern: String, _ condition: String) {
        let prefs = NetPrefs.shared
        prefs.rules.insert(NetPrefs.Rule(on: true, pattern: pattern, condition: condition), at: 0)
        prefs.rulesOn = true
        netPanel.drawer = .rules
        announce(condition == "block" ? "Blocked from the next request" : "Throttled to \(NetThrottle.named(condition)?.name ?? "3G") from the next request", mark: "arrow.clockwise")
    }

    /// Clear browser cache or cookies, as Chromium's: the profile's, after a
    /// yes for cookies, which sign you out of every site.
    func netClearBrowser(cookies: Bool) {
        guard let tab = toolsFront else { return }
        guard let web = tab.webKitOnly("WebKit profile cache and cookies") else { return }
        let store = web.configuration.websiteDataStore
        Task { @MainActor in
            let yes = await Questions.shared.ask(Question(
                title: cookies ? "Are you sure you want to clear browser cookies?" : "Are you sure you want to clear browser cache?",
                detail: cookies ? "Every site in this profile signs you out." : "Pages load their files from the network again.",
                glyph: cookies ? "lock.open" : "trash", yes: cookies ? "Clear Cookies" : "Clear Cache", danger: cookies))
            guard yes else { return }
            let kinds: Set<String> = cookies ? [WKWebsiteDataTypeCookies] : [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache]
            await store.removeData(ofTypes: kinds, modifiedSince: .distantPast)
            self.announce(cookies ? "Cleared browser cookies" : "Cleared browser cache", mark: "checkmark")
        }
    }

    /// Save as… and Save image: the body, as a file.
    func netSave(_ row: NetRow) {
        netBody(row) { [weak self] body in
            guard let self, body.error == nil, let data = body.data else {
                self?.announce("This request has no response data available", mark: "exclamationmark.triangle")
                return
            }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = URL(string: row.url)?.lastPathComponent.nonEmpty ?? "response"
            panel.begin { answer in
                guard answer == .OK, let url = panel.url else { return }
                try? data.write(to: url)
            }
        }
    }

    /// HAR of `rows`, their bodies read first: Chrome's export has them.
    func netHAR(_ rows: [NetRow], sanitized: Bool, _ done: @escaping (String) -> Void) {
        guard let tab = toolsFront else { return }
        let log = tab.netLog
        netLoadBodies(rows.filter { $0.hop == nil && $0.finished && !$0.failed }, limit: 400) { bodies in
            let archive = NetHAR.archive(rows, bodies: bodies, page: tab.address, contentLoaded: log.contentLoaded, loaded: log.loaded, sanitized: sanitized)
            done(NetHAR.data(archive).flatMap { String(data: $0, encoding: .utf8) } ?? "{}")
        }
    }

    func netExportHAR(sanitized: Bool) {
        guard let tab = toolsFront else { return }
        let rows = netPanel.shown(tab.netLog, page: tab.address)
        netHAR(rows, sanitized: sanitized) { text in
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "har") ?? .json]
            panel.nameFieldStringValue = (tab.address?.host() ?? "network") + ".har"
            panel.begin { answer in
                guard answer == .OK, let url = panel.url else { return }
                try? text.data(using: .utf8)?.write(to: url)
            }
        }
    }

    func netImportHAR() {
        guard let tab = toolsFront else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "har") ?? .json, .json]
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] answer in
            guard answer == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
            guard let resources = NetHAR.resources(from: data) else {
                self?.announce("That file isn’t a HAR Yab can read", mark: "exclamationmark.triangle")
                return
            }
            tab.netLog.bring(resources)
        }
    }

    /// Bodies of rows not yet read, one after another, at most `limit`.
    func netLoadBodies(_ rows: [NetRow], limit: Int, _ done: @escaping ([Int: NetBody]) -> Void) {
        guard let log = toolsFront?.netLog else { done([:]); return }
        var bodies = log.bodies
        let wanted = Array(rows.filter { log.bodies[$0.resource.id] == nil }.prefix(limit))
        var index = 0
        func next() {
            guard index < wanted.count else { done(bodies); return }
            let row = wanted[index]
            index += 1
            netBody(row) { body in
                bodies[row.resource.id] = body
                next()
            }
        }
        next()
    }

    func netCopyForAgent(_ rows: [NetRow]) {
        guard let tab = toolsFront else { return }
        netLoadBodies(rows.filter { $0.hop == nil && $0.finished }, limit: rows.count) { [weak self] bodies in
            self?.copyForAgent(NetCopy.agent(rows, bodies: bodies, page: tab.address), "Copied for your agent")
        }
    }

    /// Ask in Chat about requests, with one of Chrome's questions.
    func netAsk(_ rows: [NetRow], question: String) {
        guard let tab = toolsFront else { return }
        netLoadBodies(rows.filter { $0.hop == nil && $0.finished }, limit: 10) { [weak self] bodies in
            self?.askInChat(about: tab, selection: NetCopy.agent(rows, bodies: bodies, page: tab.address), words: question)
        }
    }

    /// A failed request from yab's list of what went wrong, shown in
    /// Network: found by its address, its method and when it was sent.
    func netShow(_ request: DevLog.Request) {
        guard devOpen, let tab = toolsFront else { return }
        pickDevPane(.network)
        let rows = tab.netLog.rows
        let plain = { (s: String) in s.components(separatedBy: "#")[0] }
        let found = rows.last { row in
            guard plain(row.hop == nil ? (row.resource.redirects.first?.url ?? row.url) : row.url) == plain(request.url) || plain(row.url) == plain(request.url),
                  row.method == request.method else { return false }
            guard let sent = request.sent, let wall = row.resource.wall else { return true }
            return abs(wall * 1000 - sent) < 1000
        }
        if let found {
            netPanel.filter = NetFilter()
            netPanel.selected = found.id
        } else {
            announce("Reload to see it in Network", mark: "arrow.clockwise")
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty || self == "/" ? nil : self }
}
