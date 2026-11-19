import AppKit
import SwiftUI
import YabStore

// Agents in One Row (Settings › Agents): the tabs a routine's run or
// an agent from the terminal (Claude Code, Codex through `yab mcp`) opens
// for itself aren't drawn among yours. One row over the column's foot
// stands for them: the agent's name while one works ("3 agents" while
// several do), the tab itself with the hand when one needs you, and the
// tab on its plate while you are on one of theirs. Nothing there while
// none works. A click grows a panel out of it, as ⌘K's list grows out of
// its pill: their tabs themselves, what asks first, then what works, then
// the rest, with search at its foot. Your own tasks (⌘T, ⌘J, a chat) keep
// their folders.
// docs/agent-row.md.

@MainActor
enum AgentRow {
    // A new key: the old experimental one kept a false for everyone who
    // tried it and turned it back off, and the row is now on for all.
    static let key = "agents.row"

    /// Read where no preferences reach (Folders works out every window's
    /// rows): a defaults read, as cheap as a dictionary's.
    static var on: Bool { Store.settings.object(forKey: key) as? Bool ?? true }

    /// A tab the row stands for: one an agent opened for itself, for a
    /// routine's run or an agent from the terminal, and not since kept,
    /// pinned or put in a folder of yours. A tab of yours the agent was let
    /// into (TabReuse) stays yours, where it is.
    static func holds(_ tab: Tab) -> Bool {
        guard on, tab.bench, tab.pin == nil, !tab.kept, tab.nest == nil, let id = tab.agent else { return false }
        return rowed(Agents.shared.session(Agents.shared.root(of: id)))
    }

    /// Whose tabs go behind the row: a routine's run, an agent that came on
    /// its own, and a task Yab runs that nobody began in Yab: `yab "…"`
    /// from a terminal or a script (a voice agent checking Telegram, 2026-10-19),
    /// or one an outside agent handed over through MCP. Not Yab's own work
    /// out of sight (sealed, its shut folder), not a script.
    static func rowed(_ session: Agents.Session?) -> Bool {
        guard let session, !session.sealed, !session.script, session.parent == nil else { return false }
        return session.routine != nil || session.agent == .external || session.providerBackground || session.person != "app"
    }

    /// What the row says now; nil, no row.
    enum Shown: Equatable {
        /// You are on one of their tabs: the row is that tab.
        case front(Tab)
        /// One tab waits on you.
        case asks(Tab)
        /// Several do: how many, and the first, for its hand.
        case many(Int, Tab)
        /// At work, none asking: the one's name, or how many.
        case working(String)

        var id: String {
            switch self {
            case .front(let tab): return "front " + tab.id.uuidString
            case .asks(let tab): return "asks " + tab.id.uuidString
            case .many(let count, _): return "many \(count)"
            case .working(let words): return "working " + words
            }
        }

        static func == (a: Shown, b: Shown) -> Bool { a.id == b.id }
    }

    /// One agent behind the row, its tabs in the order they stand.
    struct Worker {
        let session: Agents.Session
        let tabs: [Tab]
        /// Working, not done and not resting after its last call.
        var busy: Bool { session.state.live && !session.resting }
        var name: String { session.title ?? session.name }
        var words: String {
            if session.resting { return "Resting" }
            if !session.state.live { return session.state == .failed ? "Couldn’t finish" : "Done" }
            if let progress = session.progress, !progress.isEmpty { return progress }
            return session.now.isEmpty ? "" : AgentDock.say(session.now, name: session.name)
        }
    }

    /// Every agent behind the row in this window: those with tabs held, and
    /// a routine's run at work that has opened none yet. The ones at work
    /// first, then by when they began.
    static func workers(in browser: Browser) -> [Worker] {
        guard on else { return [] }
        let agents = Agents.shared
        var order: [String] = []
        var tabs: [String: [Tab]] = [:]
        for tab in browser.tabs where holds(tab) {
            guard let root = agents.root(of: tab.agent) else { continue }
            if tabs[root] == nil { order.append(root) }
            tabs[root, default: []].append(tab)
        }
        for session in agents.sessions where rowed(session) && session.routine != nil && session.state.live && tabs[session.id] == nil {
            order.append(session.id)
            tabs[session.id] = []
        }
        let found = order.compactMap { id in agents.session(id).map { Worker(session: $0, tabs: tabs[id] ?? []) } }
        return found.filter(\.busy) + found.filter { !$0.busy }
    }

    /// The row's words for what it shows.
    static func words(_ shown: Shown) -> String {
        switch shown {
        case .front(let tab), .asks(let tab): return tab.label
        case .many(let count, _): return "\(count) need you"
        case .working(let words): return words
        }
    }

    static func shown(in browser: Browser) -> Shown? {
        guard on, !browser.inMail else { return nil }
        if let active = browser.active, holds(active) { return .front(active) }
        let held = browser.tabs.filter(holds)
        let asking = held.filter { $0.handoff != nil }
        if asking.count == 1, let tab = asking.first { return .asks(tab) }
        if let first = asking.first { return .many(asking.count, first) }
        let busy = workers(in: browser).filter(\.busy)
        switch busy.count {
        case 0: return nil
        case 1: return .working(busy[0].name)
        default: return .working("\(busy.count) agents")
        }
    }
}

/// The row over the column's foot (Side), as tall as a tab's, with the
/// ground a pin has at rest so it reads as a place and not one of your
/// tabs. Its face holds still: only the hand moves, when one asks.
struct AgentRowView: View {
    var browser: Browser
    private var agents = Agents.shared
    @State private var hovering = false
    private var panel = AgentRowPanel.Model.shared
    /// The panel is up over this window's row (one window's at a time).
    private var open: Bool { panel.up == ObjectIdentifier(browser) }
    private var openBinding: Binding<Bool> {
        Binding(get: { open }, set: { panel.up = $0 ? ObjectIdentifier(browser) : nil })
    }
    /// A click anywhere but on the panel or the row puts the panel away.
    @State private var away: ClickAway?
    @Environment(\.tone) private var tone
    @Environment(\.tabTitleSize) private var titleSize
    @Environment(\.accessibilityReduceMotion) private var still

    var body: some View {
        let shown = AgentRow.shown(in: browser)
        VStack(spacing: 0) {
            if let shown {
                Button { show() } label: { label(shown) }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .onHover { hovering = $0 }
                    .keyTip(tip(shown), side: .above)
                    .background { if let away { ClickZone(away: away) } }
                    .padding(.bottom, SideBar.gap)
                    .transition(.opacity)
                    .accessibilityLabel(tip(shown))
            }
        }
        .padding(.horizontal, SideBar.margin)
        .modifier(HoardHush(hoard: browser.hoard))
        // Grown up out of the row, over the list: it takes no room of its own.
        .overlay(alignment: .bottom) {
            if open, shown != nil {
                AgentRowPanel(browser: browser, open: openBinding, away: away)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, SideBar.margin)
                    .padding(.bottom, SideBar.row + SideBar.gap + 4)
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .bottom)))
            }
        }
        .animation(still ? nil : .easeOut(duration: 0.15), value: shown?.id)
        .animation(still ? nil : .easeOut(duration: 0.12), value: open)
        .onAppear { if away == nil { away = ClickAway { AgentRowPanel.Model.shared.up = nil } } }
        .onChange(of: open) { _, up in away?.watch(up) }
        .onDisappear { if open { panel.up = nil }; away?.watch(false) }
    }

    private func label(_ shown: AgentRow.Shown) -> some View {
        HStack(spacing: SideBar.markGap) {
            lead(shown)
                .frame(width: SideBar.mark, height: SideBar.mark)
            Text(words(shown))
                .font(.system(size: titleSize))
                .foregroundStyle(front(shown) || hovering || open ? Palette.strong(on: tone) : Palette.muted(on: tone))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            end(shown)
        }
        .padding(.leading, SideBar.inner)
        .padding(.trailing, SideBar.endInset) // design: a tab row's own ends, its face where a tab's cross is
        .frame(height: SideBar.row)
        .contentShape(RoundedRectangle(cornerRadius: SideBar.radius, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: SideBar.radius, style: .continuous)
                .fill(front(shown) || open ? Palette.wash(on: tone) : Palette.resting(on: tone, hovering: hovering))
        )
    }

    @ViewBuilder private func lead(_ shown: AgentRow.Shown) -> some View {
        switch shown {
        case .front(let tab), .asks(let tab):
            Mark(icon: tab.displayIcon, letter: tab.monogram, size: SideBar.mark)
        case .many(_, let tab):
            AgentFace(tab: tab, size: SideBar.mark, tint: Palette.strong(on: tone), tip: false)
        case .working:
            StillFace(pose: .watch, size: SideBar.mark, tint: Palette.muted(on: tone))
        }
    }

    @ViewBuilder private func end(_ shown: AgentRow.Shown) -> some View {
        switch shown {
        case .front(let tab):
            if tab.worker != nil || tab.handoff != nil {
                AgentFace(tab: tab, size: 15, tint: Palette.strong(on: tone), tip: false)
            }
        case .asks(let tab):
            AgentFace(tab: tab, size: 15, tint: Palette.strong(on: tone), tip: false)
        case .many, .working:
            EmptyView()
        }
    }

    private func front(_ shown: AgentRow.Shown) -> Bool {
        if case .front = shown { return true }
        return false
    }

    private func words(_ shown: AgentRow.Shown) -> String { AgentRow.words(shown) }

    private func tip(_ shown: AgentRow.Shown) -> String {
        switch shown {
        case .asks(let tab), .front(let tab):
            let name = agents.session(agents.root(of: tab.agent)).map { $0.title ?? $0.name } ?? ""
            if let ask = tab.handoff { return name.isEmpty ? ask : "\(name) needs you · \(ask)" }
            return name
        case .many(let count, _): return "\(count) agents need you"
        case .working: return "Agents at work"
        }
    }

    private func show() {
        if open { panel.up = nil; return }
        panel.reset()
        panel.up = ObjectIdentifier(browser)
    }
}

/// The row's panel, grown up out of it as ⌘K's list is out of its pill: the
/// agents' tabs themselves, what asks first, then what works, then the rest
/// newest first, one line for a site's several done tabs. Search at its
/// foot takes the keys at once; ↑↓ walk, Return opens, Escape goes.
/// A right click on a line has Show Chat, Stop and Close.
struct AgentRowPanel: View {
    var browser: Browser
    @Binding var open: Bool
    @Bindable private var model = Model.shared
    private var agents = Agents.shared
    let away: ClickAway?
    @FocusState private var typing: Bool
    @State private var hovered: String?

    static let row: CGFloat = 46
    static let part: CGFloat = 26

    @MainActor
    @Observable final class Model {
        static let shared = Model()
        var query = ""
        var chosen = 0
        /// The window whose row it is up over, if any.
        var up: ObjectIdentifier?
        func reset() { query = ""; chosen = 0 }
    }

    var body: some View {
        let lines = AgentRow.lines(in: browser, query: model.query)
        VStack(alignment: .leading, spacing: 0) {
            ScrollViewReader { reader in
                ThreadScrollView(.vertical) { rows(lines).padding(.top, 4) }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(height: min(height(lines), Self.row * 7.5))
                    .onChange(of: model.chosen) { _, chosen in
                        if lines.indices.contains(chosen) { reader.scrollTo(lines[chosen].id) }
                    }
            }
            Rectangle()
                .fill(Omnibox.seam)
                .frame(height: 1)
                .padding(.top, 4)
            TextField("", text: $model.query, prompt: Text("Search agents\u{2019} tabs\u{2026}").foregroundStyle(Palette.muted))
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .foregroundStyle(Palette.ink)
                .focused($typing)
                .onChange(of: model.query) { _, _ in model.chosen = 0 }
                .onKeyPress(.downArrow) { model.chosen = min(max(0, lines.count - 1), model.chosen + 1); return .handled }
                .onKeyPress(.upArrow) { model.chosen = max(0, model.chosen - 1); return .handled }
                .onKeyPress(.escape) { open = false; return .handled }
                .onExitCommand { open = false }
                .onSubmit { pick(lines) }
                .frame(height: 20)
                .padding(.horizontal, 16)
                .frame(height: 48)
        }
        .frame(maxWidth: .infinity)
        .background { FieldGlass(shape: RoundedRectangle(cornerRadius: FieldActionsPanel.corner, style: .continuous), lifted: true) }
        .background { if let away { ClickZone(away: away) } }
        .onChange(of: lines.map(\.id)) { _, ids in
            model.chosen = min(model.chosen, max(0, ids.count - 1))
            if let hovered, !ids.contains(hovered) { self.hovered = nil }
        }
        .onAppear { DispatchQueue.main.async { typing = true } }
    }

    private func rows(_ lines: [AgentRow.Line]) -> some View {
        VStack(spacing: 0) {
            if lines.isEmpty {
                Text(model.query.isEmpty ? "No agents\u{2019} tabs" : "No tabs")
                    .font(.system(size: 13.5))
                    .foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .frame(height: Self.row)
            }
            ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                if index == 0 || lines[index - 1].part != line.part {
                    Text(line.part.title)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .frame(height: Self.part, alignment: .bottom)
                        .padding(.bottom, 2)
                }
                row(line, index: index, lines: lines).id(line.id)
            }
        }
        .padding(.horizontal, 8)
    }

    private func row(_ line: AgentRow.Line, index: Int, lines: [AgentRow.Line]) -> some View {
        let plate = RowPlate.column
        // The tab's own square, centered on the row's height and inset from
        // its end as the row's corner is from the square's.
        let inset = Radius.surface - plate.radius
        return HStack(spacing: 12) {
            Group {
                if let tab = line.tab {
                    Mark(icon: tab.displayIcon, letter: tab.monogram, size: 16)
                } else {
                    StillFace(pose: .watch, size: 16, tint: Palette.ink)
                }
            }
            .frame(width: 16)
            // The title over its words: what it asks, what it does, how
            // long ago. A column's width has no room for both on one line.
            VStack(alignment: .leading, spacing: 1) {
                title(line)
                Text(subtitle(line))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            end(line)
        }
        .padding(.leading, 8)
        .padding(.trailing, line.tabs.isEmpty ? 8 : plate.side + inset + 4) // design: reserve the tab's close square at the right, centered; the leading edge holds only the site icon
        .frame(height: Self.row)
        .background {
            if index == model.chosen {
                RoundedRectangle(cornerRadius: Radius.surface, style: .continuous).fill(Omnibox.chosenFill)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            model.chosen = index
            pick(lines)
        }
        .steadyMenu(actions: true) { more(line) }
        .overlay(alignment: .trailing) {
            if !line.tabs.isEmpty {
                AgentRowCross(plate: plate, label: closeLabel(line)) { close(line) }
                    .padding(.trailing, inset)
                    .opacity(hovered == line.id ? 1 : 0)
                    .allowsHitTesting(hovered == line.id)
                    .accessibilityHidden(hovered != line.id)
            }
        }
        .onHover { on in
            if on { hovered = line.id; model.chosen = index }
            else if hovered == line.id { hovered = nil }
        }
    }

    private func title(_ line: AgentRow.Line) -> some View {
        Text(line.title)
            .font(.system(size: 13.5))
            .foregroundStyle(Palette.ink)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private func subtitle(_ line: AgentRow.Line) -> String {
        line.part == .earlier && line.count > 1 ? "\(line.count) tabs \u{00B7} \(line.words)" : line.words
    }

    /// The hand on what asks, the face on what works; nothing on the rest.
    @ViewBuilder private func end(_ line: AgentRow.Line) -> some View {
        switch line.part {
        case .asks:
            if let tab = line.tab { AgentFace(tab: tab, size: 15, tint: Palette.ink, tip: false) }
        case .working:
            StillFace(pose: .watch, size: 15, tint: Palette.muted)
        case .earlier:
            EmptyView()
        }
    }

    @ViewBuilder private func more(_ line: AgentRow.Line) -> some View {
        let id = line.session.id
        if agents.hasChat(id) {
            Button("Show Chat", mark: FieldAnswer.mark(line.session.cli)) { open = false; browser.showChat(id) }
        }
        if line.session.state.live, line.session.agent != .external {
            Button(Folders.stopping(line.session), mark: "stop") { _ = agents.stop(id) }
        }
        if !line.tabs.isEmpty {
            Button(closeLabel(line), mark: "yab.tabs.x") { close(line) }
        }
    }

    private func closeLabel(_ line: AgentRow.Line) -> String {
        line.tabs.count == 1 ? "Close Tab" : "Close \(line.tabs.count) Tabs"
    }

    private func close(_ line: AgentRow.Line) {
        for tab in line.tabs { browser.close(tab) }
    }

    private func pick(_ lines: [AgentRow.Line]) {
        guard lines.indices.contains(model.chosen) else { return }
        let line = lines[model.chosen]
        open = false
        AgentRow.open(line, in: browser)
    }

    private func height(_ lines: [AgentRow.Line]) -> CGFloat {
        guard !lines.isEmpty else { return Self.row + 4 }
        var total: CGFloat = 4
        for (index, line) in lines.enumerated() {
            if index == 0 || lines[index - 1].part != line.part { total += Self.part + 2 }
            total += Self.row
        }
        return total
    }
}

/// A tab's cross, on the same square, at a panel line's end.
private struct AgentRowCross: View {
    let plate: RowPlate
    let label: String
    let close: () -> Void
    @State private var pressed = false
    @State private var on = false
    @Environment(\.tone) private var tone
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: close) {
            MinusCross(open: 1)
                .stroke(style: StrokeStyle(lineWidth: plate.cross / 8, lineCap: .round))
                .frame(width: plate.cross, height: plate.cross)
                .foregroundStyle(on ? Palette.ink.opacity(0.75) : Palette.muted(on: tone))
                .frame(width: plate.side, height: plate.side)
                .background { if on { plate.square() } }
                .contentShape(RoundedRectangle(cornerRadius: plate.radius, style: .continuous))
                .scaleEffect(pressed && !reduceMotion ? 0.9 : 1)
                .animation(pressed ? Press.down : Press.up, value: pressed)
        }
        .buttonStyle(Held(pressed: $pressed))
        .focusable(false)
        .onHover { on = $0 }
        .keyTip(label)
        .accessibilityLabel(label)
    }
}

extension AgentRow {
    /// One line of the row's panel: a tab, or for a site's several done
    /// tabs the newest of them, the others counted.
    struct Line: Identifiable {
        enum Part: Int {
            case asks, working, earlier
            var title: String {
                switch self {
                case .asks: return "Needs You"
                case .working: return "At Work"
                case .earlier: return "Earlier"
                }
            }
        }
        let part: Part
        let session: Agents.Session
        /// The tab it opens; nil for a routine's run that has opened none.
        let tab: Tab?
        /// Every tab it stands for, for Close.
        let tabs: [Tab]
        /// What asks, what the agent does, or how long ago.
        let words: String
        let title: String
        let id: String
        var count: Int { max(1, tabs.count) }

        @MainActor
        init(part: Part, session: Agents.Session, tab: Tab?, tabs: [Tab], words: String) {
            self.part = part
            self.session = session
            self.tab = tab
            self.tabs = tabs
            self.words = words
            title = tab?.label ?? (session.title ?? session.name)
            id = tab.map { $0.id.uuidString } ?? session.id
        }
    }

    /// The panel's lines, narrowed to what `query` finds in a tab's title
    /// or site: what asks, then what works, then the rest newest first.
    static func lines(in browser: Browser, query: String = "") -> [Line] {
        let words = query.trimmingCharacters(in: .whitespaces).lowercased()
        func found(_ tab: Tab) -> Bool {
            words.isEmpty || tab.label.lowercased().contains(words) || (tab.address?.host()?.lowercased().contains(words) ?? false)
        }
        var asks: [Line] = [], working: [Line] = [], earlier: [Line] = []
        var sites: [String: Int] = [:]
        for worker in workers(in: browser) {
            if worker.tabs.isEmpty {
                let name = worker.name
                if worker.busy, words.isEmpty || name.lowercased().contains(words) {
                    working.append(Line(part: .working, session: worker.session, tab: nil, tabs: [], words: worker.words))
                }
                continue
            }
            for tab in worker.tabs where found(tab) {
                if let ask = tab.handoff {
                    asks.append(Line(part: .asks, session: worker.session, tab: tab, tabs: [tab], words: ask))
                } else if worker.busy {
                    working.append(Line(part: .working, session: worker.session, tab: tab, tabs: [tab], words: worker.words.isEmpty ? "Working" : worker.words))
                } else {
                    // A site's several done tabs are one line: the newest.
                    let site = tab.address?.host() ?? tab.id.uuidString
                    if let at = sites[site] {
                        let line = earlier[at]
                        let newest = tab.touched > (line.tab?.touched ?? .distantPast) ? tab : line.tab
                        earlier[at] = Line(part: .earlier, session: newest === tab ? worker.session : line.session,
                                           tab: newest, tabs: line.tabs + [tab], words: ago(newest?.touched ?? tab.touched))
                    } else {
                        sites[site] = earlier.count
                        earlier.append(Line(part: .earlier, session: worker.session, tab: tab, tabs: [tab], words: ago(tab.touched)))
                    }
                }
            }
        }
        earlier.sort { ($0.tab?.touched ?? .distantPast) > ($1.tab?.touched ?? .distantPast) }
        return asks + working + earlier
    }

    /// Picked: its tab in front, or a tab-less run's chat.
    static func open(_ line: Line, in browser: Browser) {
        if let tab = line.tab { browser.select(tab) }
        else if Agents.shared.hasChat(line.session.id) { browser.showChat(line.session.id) }
    }

    /// How long ago, as short as a tab's line has room for: "now", "4m ago", "2h ago", "3d ago".
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m ago"
        case ..<86_400: return "\(Int(seconds / 3600))h ago"
        default: return "\(Int(seconds / 86_400))d ago"
        }
    }
}
