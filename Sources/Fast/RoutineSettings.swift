import SwiftUI

private func routineNewTabPlace(_ key: Hotkey?, plates: Bool = false) -> String {
    key.map { "New Tab (\(plates ? $0.settingsHint : $0.text))" } ?? "New Tab"
}

// Settings › AI › Routines: the tasks that come back, in the table language
// of Commands, the one a routine is made like.
//
// A row is a routine's name and what its last run came to in words, when it
// runs in a cell with a menu, its model in another, and the rest under ···.
// New Routine… and a click on a name open the editor, Commands' own sheet:
// the prompt down the left with the tabs it works in over it, what runs it
// and when down the right. A command of Commands is made one from its ···
// (Run Regularly…), in a small card: the tab, and when. Under the list, a
// few routines worth having for the sites you use (RoutineIdea); with none
// set yet, the commands that can run on a page besides them.

struct AgentRoutinesPage: View {
    var browser: Browser
    private var newTabKey = Keymap.shared.slot(.newTab)
    private var routines = Routines.shared
    private var ideas = RoutineIdeas.shared
    @Bindable private var editing = RoutineEditing.shared

    var body: some View {
        PageHero(page: .agentRoutines)
            .onAppear { ideas.count() }
        Section {
            ForEach(routines.all) { routine in
                RoutineRow(routine: routine)
                    .settingsAnchor(routine.id == routines.all.first?.id ? "agents-routines-list" : "agents-routine-" + routine.id)
            }
            if routines.all.isEmpty {
                Text("No routines yet")
                    .foregroundStyle(.secondary)
            }
        } header: {
            HStack(spacing: 8) {
                Text("Yours")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("New Routine…") { editing.edit(nil) }
                    .settingsButton()
            }
            .textCase(nil)
            .settingsAnchor("agents-routines-add")
        } footer: {
            SettingsNote("Run scheduled tasks while Yab is open. Results appear in \(routineNewTabPlace(newTabKey.keys, plates: true)) and the task's chat. Terminal: \(AgentSetup.command) every \"weekdays 9:00\" \"check my mail\".")
        }
        .sheet(item: $editing.sheet) { sheet in
            RoutineEditor(browser: browser, sheet: sheet)
        }
        let offered = ideas.offered(routines.all)
        if !offered.isEmpty {
            Section {
                ForEach(offered) { idea in
                    RoutineIdeaRow(idea: idea)
                        .settingsAnchor("agents-routine-idea-" + idea.id)
                }
            } header: {
                Text(offered == [RoutineIdea.anyone] ? "Suggested" : "Suggested from your history")
                    .foregroundStyle(.secondary)
            }
        }
        let commands = browser.selectionCommands.commands.filter(\.runsOnPages)
        if routines.all.isEmpty, !commands.isEmpty {
            Section {
                ForEach(commands.prefix(3), id: \.id) { command in
                    SettingsRow(SelectionCommand.menuTitle(command.name), detail: "Monitor a webpage, feed, dashboard or thread.") {
                        Button("Run Regularly…") { RoutineEditing.shared.runRegularly(command) }
                            .settingsButton()
                    }
                }
            } header: {
                Text("From your commands")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - a row

/// One routine: the marks of its sites, its name and what its last run
/// came to, when it runs, and the rest under ···. Its model is the
/// editor's: a cell for it left the name too little room to say what the
/// last run found.
private struct RoutineRow: View {
    let routine: Routine
    private var agents = Agents.shared

    /// Wide enough for the times people pick: "Weekdays 9:00 AM",
    /// "Mondays and Thursdays 9:00 AM" were cut at a hotkey's 144.
    static let whenColumn: CGFloat = 220

    var body: some View {
        HStack(spacing: 12) {
            Button { edit() } label: {
                HStack(spacing: 8) {
                    RoutineMarks(routine: routine)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(routine.name)
                            .lineLimit(1)
                        Text(Routines.status(routine, live: live))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .allowsHitTesting(routine.quiet != true)
            .accessibilityHint(routine.quiet == true ? "" : "Edits \(routine.name)")
            if routine.quiet == true {
                // A watch runs every two hours until its day: nothing to pick.
                Text(Routines.short(routine.when))
                    .foregroundStyle(.secondary)
                    .modifier(TableCell(width: Self.whenColumn))
            } else {
                MenuCell(title: "Repeats", options: Routines.quickTimes(routine.when), selection: Binding(
                    get: { routine.when },
                    set: { when in change { $0.when = when } }
                ), width: Self.whenColumn)
            }
            more
        }
        .opacity(routine.off == true ? 0.45 : 1)
        .contentShape(Rectangle())
        .contextMenu { actions }
    }

    private var live: Bool { agents.session(routine.session)?.state.live == true }

    private func edit() { RoutineEditing.shared.edit(routine) }

    private func change(_ edit: (inout Routine) -> Void) {
        var changed = routine
        edit(&changed)
        Routines.shared.put(changed)
    }

    private var more: some View {
        Menu { actions } label: {
            Symbol("ellipsis", size: 14)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More options for \(routine.name)")
    }

    @ViewBuilder private var actions: some View {
        if routine.quiet != true {
            Button("Edit…") { edit() }
        }
        Button("Run Now") { Routines.shared.run(routine) }
            .disabled(live)
        if routine.chat != nil {
            Button("Open Chat") { Routines.shared.openChat(routine) }
        }
        if routine.quiet != true {
            Button(routine.off == true ? "Turn On" : "Turn Off") { Routines.shared.turn(routine.id, on: routine.off == true) }
            Divider()
            Button("Duplicate") { Routines.shared.duplicate(routine.id) }
        }
        Divider()
        Button("Delete", role: .destructive) { _ = Routines.shared.remove(routine.id) }
    }
}

/// The marks of the sites it works in, two at most, or its own clock.
private struct RoutineMarks: View {
    let routine: Routine

    var body: some View {
        let hosts = Routines.hosts(routine).prefix(2)
        HStack(spacing: 2) {
            if hosts.isEmpty {
                Symbol(SettingsPage.agentRoutines.icon, size: 11)
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
            }
            ForEach(Array(hosts), id: \.self) { HostMark(host: $0) }
        }
        .frame(width: 34, alignment: .leading)
    }
}

/// A routine offered: the site's mark, what it would find, and when.
private struct RoutineIdeaRow: View {
    let idea: RoutineIdea

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                if let site = idea.site {
                    HostMark(host: site)
                } else {
                    Symbol(SettingsPage.agentRoutines.icon, size: 11)
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(idea.title)
                    Text(Routines.say(idea.when))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Add") { RoutineIdeas.shared.take(idea) }
                .settingsButton()
            Button { RoutineIdeas.shared.decline(idea) } label: { Symbol("xmark", size: 11) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyTip("Don't suggest this")
                .accessibilityLabel("Don't suggest \(idea.title)")
        }
    }
}

// MARK: - suggestions

/// The routines worth offering, from how often each site was opened this
/// month, here and in this Mac's other browsers, counted off the main
/// thread as the page shows, ten minutes apart at most. The sites counted
/// are also the editor's Sites You Use.
@MainActor
@Observable final class RoutineIdeas {
    static let shared = RoutineIdeas()
    nonisolated static let declinedKey = "routines.ideas.declined"

    /// Visits to each host this month, once counted.
    private(set) var visits: [String: Int]?
    private(set) var declined: Set<String>
    @ObservationIgnored private var counted = Date.distantPast
    @ObservationIgnored private var counting = false

    private init() {
        declined = Set(Store.settings.stringArray(forKey: Self.declinedKey) ?? [])
    }

    /// None until the history is counted, so the one for anyone never
    /// shows for a moment before the ones for you.
    func offered(_ set: [Routine]) -> [RoutineIdea] {
        guard let visits else { return [] }
        return RoutineIdea.offered(visits: visits, set: set, declined: declined)
    }

    /// The sites opened most this month, for the tab picker.
    func sites(_ limit: Int) -> [String] {
        guard let visits else { return [] }
        var seen = Set<String>()
        return visits.sorted { $0.value > $1.value }.compactMap { host, _ in
            let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            guard !AgentHistory.noise(bare), seen.insert(bare).inserted else { return nil }
            return bare
        }.prefix(limit).map { $0 }
    }

    func count() {
        guard !counting, Date().timeIntervalSince(counted) > 600 else { return }
        counting = true
        Task.detached(priority: .utility) {
            var visits: [String: Int] = [:]
            for visit in AgentHistory.visits(days: 30) {
                if let host = visit.url.host()?.lowercased() { visits[host, default: 0] += 1 }
            }
            let found = visits
            await MainActor.run { RoutineIdeas.shared.land(found) }
        }
    }

    private func land(_ found: [String: Int]) {
        counting = false
        counted = Date()
        if found != visits { visits = found }
    }

    /// The bench's counts in place of the history's.
    func given(_ counts: [String: Int]) {
        counted = Date()
        visits = counts
    }

    func take(_ idea: RoutineIdea) {
        var made = Routine(id: Routines.newID(idea.id), when: idea.when, prompt: idea.task, last: nil, title: idea.title)
        if let site = idea.site { made.tabs = ["https://" + site] }
        Routines.shared.put(made)
    }

    func decline(_ idea: RoutineIdea) {
        declined.insert(idea.id)
        Store.settings.set(declined.sorted(), forKey: Self.declinedKey)
    }
}

// MARK: - the editor

/// What is being made or changed: the editor's sheet, or the small card a
/// command is made a routine in.
@MainActor
@Observable final class RoutineEditing {
    static let shared = RoutineEditing()

    struct Sheet: Identifiable {
        let id = UUID()
        let routine: Routine
        let isNew: Bool
    }

    struct Card: Identifiable {
        let id = UUID()
        let command: SelectionCommand
    }

    var sheet: Sheet? {
        didSet {
            if let old = oldValue, old.id != sheet?.id { Routines.shared.cancelDraft(old.routine.id) }
        }
    }
    private(set) var card: Card?

    /// Open in the editor, or a new one when nil; from anywhere: Settings is
    /// brought up on Routines first.
    func edit(_ routine: Routine?, fresh: Bool = false) {
        let blank = Routine(id: Routines.newID("new"), when: "weekdays 9:00", prompt: "", last: nil)
        sheet = Sheet(routine: routine ?? blank, isNew: routine == nil || fresh)
    }

    func runRegularly(_ command: SelectionCommand) { card = Card(command: command) }
    func closeCard() { card = nil }
}

/// The routine as Commands' editor has a command: its prompt down the left,
/// with the tabs it works in over it, and down the right its name, when it
/// runs, what runs it, what it may do and how it says what it found.
private struct RoutineEditor: View {
    let browser: Browser
    let isNew: Bool
    /// Its when as it was kept: unchanged, its runs keep their count.
    private let saved: String
    private var newTabKey = Keymap.shared.slot(.newTab)
    @State private var draft: Routine
    @State private var parts: RoutineWhen.Parts
    @State private var trying: String?
    private var agents = Agents.shared
    @Environment(\.dismiss) private var dismiss

    init(browser: Browser, sheet: RoutineEditing.Sheet) {
        self.browser = browser
        isNew = sheet.isNew
        _draft = State(initialValue: sheet.routine)
        _parts = State(initialValue: RoutineWhen.split(sheet.routine.when))
        saved = sheet.routine.when
    }

    private static let column: CGFloat = 260
    private static var face: CGFloat { column - 2 * ButtonSize.small.padding }

    /// Its words: the ones it was kept in while they say the same, "on the
    /// 1st 9:00" left as typed, else the menus' own.
    private var when: String {
        let made = RoutineWhen.join(parts)
        return Routines.schedule(made) == Routines.schedule(saved.lowercased()) ? saved : made
    }
    private var command: SelectionCommand? { draft.command.flatMap { id in browser.selectionCommands.commands.first { $0.id == id } } }
    private var ready: Bool {
        (!draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || command != nil) && Routines.schedule(when) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    caption("Tabs it works in")
                    RoutineTabs(browser: browser, tabs: Binding(get: { draft.tabs ?? [] }, set: { draft.tabs = $0.isEmpty ? nil : $0 }))
                        .padding(.bottom, 10)
                    caption(command == nil ? "Prompt" : "Also tell it")
                    ThreadTextEditor(text: $draft.prompt)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(Color.primary.opacity(0.04), in: RoutineEditor.box)
                        .overlay(RoutineEditor.box.strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
                        .frame(maxHeight: .infinity)
                        .accessibilityLabel("Prompt")
                    Text(command.map { "Runs \(SelectionCommand.menuTitle($0.name)) on each tab. Use {since}, {date} and {memory}" }
                         ?? "Use {since}, {date}, {tabs} and {memory}")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                VStack(alignment: .leading, spacing: 16) {
                    field("Name") {
                        TextField(Routine.name(from: draft.prompt).isEmpty ? "Morning check" : Routine.name(from: draft.prompt),
                                  text: Binding(get: { draft.title ?? "" }, set: { draft.title = $0.isEmpty ? nil : $0 }))
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                    }
                    field("Repeats") {
                        RoutineWhenFields(parts: $parts, next: nextWords, column: Self.column)
                    }
                    if !browser.selectionCommands.commands.filter(\.runsOnPages).isEmpty {
                        field("Command") {
                            ChoiceMenu(title: "Command", options: [("None, the Prompt", String?.none)]
                                       + browser.selectionCommands.commands.filter(\.runsOnPages).map { (SelectionCommand.menuTitle($0.name), Optional($0.id)) },
                                       selection: $draft.command, width: Self.face)
                        }
                    }
                    field("Model") {
                        ModelField(choice: modelChoice, automatic: ("Default", ModelDefaults.shared.name(.tasks)), follows: .tasks, width: Self.face)
                    }
                    field("Reasoning effort") {
                        if AgentPlan.isPlan(draft.cli) {
                            EffortField(choice: modelChoice, width: Self.face)
                        } else {
                            Text("As the Tasks default").foregroundStyle(.secondary)
                        }
                    }
                    field("May") {
                        ChoiceMenu(title: "May", options: [("Only Read", "read"), ("Ask Before Acting", "ask"), ("As Agents Settings Say", "agents")],
                                   selection: Binding(get: { draft.may ?? "read" }, set: { draft.may = $0 == "read" ? nil : $0 }), width: Self.face)
                    }
                    field("Tell me") {
                        ChoiceMenu(title: "Tell me", options: [("Quietly, in \(routineNewTabPlace(newTabKey.keys))", "quiet"), ("When It Finds Something", "found"), ("Every Time", "always")],
                                   selection: Binding(get: { draft.tell ?? "quiet" }, set: { draft.tell = $0 == "quiet" ? nil : $0 }), width: Self.face)
                    }
                    // What it finds as a folder it keeps, rather than an answer
                    // (LiveFolders, the `routine` source).
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle("Keep what it finds in a folder", isOn: Binding(get: { draft.folder == true }, set: { draft.folder = $0 ? true : nil }))
                            .toggleStyle(.checkbox)
                        Text("New ones come in, ones that no longer fit go")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 20)
                    }
                }
                .frame(width: Self.column, alignment: .topLeading)
            }
            HStack(spacing: 8) {
                if !isNew {
                    Button("Delete", role: .destructive) {
                        _ = Routines.shared.remove(draft.id)
                        dismiss()
                    }
                    .buttonStyle(.yab(.quiet, .regular, tint: ButtonCSS.danger))
                }
                Button("Try Now") { try_() }
                    .buttonStyle(.yab(.secondary, .regular))
                    .disabled(!ready || trialLive)
                Text(trialWords)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.yab(.secondary, .regular))
                Button("Save") { save() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.yab(.primary, .regular))
                    .disabled(!ready)
            }
        }
        .padding(24)
        .frame(width: 720, height: 640)
        .onDisappear { Routines.shared.cancelDraft(draft.id) }
    }

    private static let box = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)

    /// When it runs next as it stands: counted from its last run while its
    /// when is the one it had, from now once changed, as saving does.
    private var nextWords: String? {
        var routine = draft
        routine.when = when
        if isNew || when != saved { routine.last = Date() }
        return Routines.nextWords(routine)
    }

    private var trial: Agents.Session? { agents.session(trying) }
    private var trialLive: Bool { trial?.state.live == true }

    /// What the try came to, in the fewest words.
    private var trialWords: String {
        guard let trial else { return "Runs it once, now, and brings what it finds" }
        if trial.state.live { return "Trying…" }
        let line = trial.result.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.isEmpty ? "Done: see its chat" : line
    }

    private var modelChoice: Binding<ModelChoice> {
        Binding(get: { ModelChoice(cli: draft.cli, model: draft.model, effort: draft.effort) },
                set: { picked in
                    let own = AgentPlan.isPlan(picked.cli)
                    draft.cli = own ? picked.cli : nil
                    draft.model = own ? picked.model : nil
                    draft.effort = own ? picked.effort : nil
                })
    }

    private func made() -> Routine {
        var routine = draft
        routine.when = when
        routine.prompt = routine.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if let title = routine.title?.trimmingCharacters(in: .whitespacesAndNewlines) { routine.title = title.isEmpty ? nil : title }
        if routine.title == nil, let command { routine.title = SelectionCommand.menuTitle(command.name) }
        return routine
    }

    private func save() {
        guard ready else { return }
        let routine = made()
        if case .success = Routines.shared.put(routine) {
            if routine.folder == true { browser.prefs.usesLiveFolders = true }
            dismiss()
        }
    }

    /// Once, now, as it stands, saved or not: into a chat of its own, the
    /// routine's when it is one already.
    private func try_() {
        trying = Routines.shared.run(made(), trial: true)?.id
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            caption(title)
            content()
        }
    }
}

/// The tabs it works in: a chip each, and + Tab, whose menu has the tabs you
/// have open and the sites you go to most.
private struct RoutineTabs: View {
    let browser: Browser
    @Binding var tabs: [String]
    private var ideas = RoutineIdeas.shared
    @State private var place = DropAnchor.Place()

    var body: some View {
        FlowRow(spacing: 6) {
            ForEach(tabs, id: \.self) { address in
                HStack(spacing: 6) {
                    HostMark(host: URL(string: address)?.host() ?? address)
                    Text(URL(string: address).map(Address.pretty) ?? address)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button { tabs.removeAll { $0 == address } } label: { Symbol("xmark", size: 9) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Remove \(address)")
                }
                .font(.system(size: 12.5))
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(Palette.ink.opacity(0.055), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            }
            // Settings' own list (DropPopup): your open tabs, a line, then
            // the sites you use, each with its site's mark.
            Button(action: pickTab) {
                HStack(spacing: 4) {
                    Symbol("plus", size: 10)
                    Text("Tab")
                }
            }
            .buttonStyle(.yab(.secondary, .small))
            .background(DropAnchor(place: place, title: "Add a tab", press: pickTab, hover: { _ in }))
            .fixedSize()
            .accessibilityLabel("Add a tab")
        }
        .onAppear { ideas.count() }
    }

    /// Your tabs with a web page in them, each address once.
    private var openTabs: [(title: String, address: String)] {
        var seen = Set<String>()
        return browser.tabs.compactMap { tab in
            guard let url = tab.address, url.scheme?.hasPrefix("http") == true, seen.insert(url.absoluteString).inserted,
                  !tabs.contains(url.absoluteString) else { return nil }
            return (tab.label, url.absoluteString)
        }.prefix(12).map { $0 }
    }

    private func pickTab() {
        guard let view = place.view, view.window != nil, !DropPopup.closed(from: view) else { return }
        let open = openTabs
        let sites = ideas.sites(8).filter { site in !tabs.contains { URL(string: $0)?.host()?.hasSuffix(site) == true } }
        let addresses = open.map(\.address) + sites.map { "https://" + $0 }
        guard !addresses.isEmpty else { return }
        let lines = open.map { DropList.Line(title: $0.title, picture: Self.mark(URL(string: $0.address)?.host())) }
            + sites.map { DropList.Line(title: $0, picture: Self.mark($0)) }
        let list = DropList(options: lines, chosen: 0,
                            divideBefore: open.isEmpty || sites.isEmpty ? nil : open.count, inset: DropFace.inset)
        DropPopup.show(list, under: view) { index in
            if let index, addresses.indices.contains(index) { add(addresses[index]) }
        }
    }

    /// A site's mark at 16 points, as the list's pictures are drawn.
    private static func mark(_ host: String?) -> NSImage? {
        guard let host, let icon = Favicons.shared.cached(host) else { return Glyphs.image("globe", size: 12) }
        return NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
    }

    private func add(_ address: String) {
        guard !tabs.contains(address) else { return }
        tabs.append(address)
    }
}

/// Chips that wrap onto another line when the line is full.
private struct FlowRow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { y += line + spacing; x = 0; line = 0 }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { y += line + spacing; x = bounds.minX; line = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

/// What a kind of repeat needs, under its menu: the days of the week, a day
/// of the month or which weekday of it, a date, a gap; then the times of
/// day, as many as it runs at, + for another; and when it runs next.
private struct RoutineWhenFields: View {
    @Binding var parts: RoutineWhen.Parts
    let next: String?
    let column: CGFloat

    /// A menu's face across the column, and two side by side.
    private var whole: CGFloat { column - 2 * ButtonSize.small.padding }
    private var half: CGFloat { (column - 8) / 2 - 2 * ButtonSize.small.padding }
    private static let time: CGFloat = 72

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ChoiceMenu(title: "Repeats", options: RoutineWhen.choices(parts.repeats), selection: $parts.repeats, width: whole)
            kind
            if RoutineWhen.timed(parts.repeats) { times }
            // When it runs next, and what a short month does with its day.
            let words = [next, note].compactMap { $0 }.joined(separator: ", ")
            if !words.isEmpty { line(words) }
        }
    }

    @ViewBuilder private var kind: some View {
        switch parts.repeats {
        case RoutineWhen.onDays:
            RoutineDays(days: $parts.days)
        case RoutineWhen.everyWeeks:
            ChoiceMenu(title: "Every", options: RoutineWhen.gaps("Weeks", most: 12, current: parts.gap), selection: $parts.gap, width: whole)
            RoutineDays(days: Binding(get: { parts.days.isEmpty ? [parts.weekday] : parts.days }, set: { parts.days = $0 }))
        case RoutineWhen.everyDays:
            ChoiceMenu(title: "Every", options: RoutineWhen.gaps("Days", most: 30, current: parts.gap), selection: $parts.gap, width: whole)
        case RoutineWhen.monthly:
            HStack(spacing: 8) {
                ChoiceMenu(title: "On", options: RoutineWhen.whiches, selection: $parts.which, width: half)
                if parts.which == 0 {
                    ChoiceMenu(title: "Day", options: RoutineWhen.monthDays, selection: $parts.monthDay, width: half)
                } else {
                    ChoiceMenu(title: "Weekday", options: RoutineWhen.weekdays, selection: $parts.weekday, width: half)
                }
            }
        case RoutineWhen.yearly:
            HStack(spacing: 8) {
                ChoiceMenu(title: "Month", options: RoutineWhen.months, selection: Binding(get: { parts.month }, set: { month in
                    parts.month = month
                    parts.yearDay = min(parts.yearDay, RoutineWhen.longest(month))
                }), width: half)
                ChoiceMenu(title: "Day", options: (1...RoutineWhen.longest(parts.month)).map { ("\($0)", $0) }, selection: $parts.yearDay, width: half)
            }
        default:
            EmptyView()
        }
    }

    /// Its times, each a menu whose last choice takes it away while there
    /// are others, and + for one more, an hour after the last.
    private var times: some View {
        FlowRow(spacing: 8) {
            ForEach(Array(parts.minutes.enumerated()), id: \.offset) { index, minute in
                ChoiceMenu(title: "At", options: RoutineWhen.times(minute) + (parts.minutes.count > 1 ? [("Remove", -1)] : []),
                           selection: Binding(get: { minute }, set: { picked in
                               if picked < 0 { parts.minutes.remove(at: index) } else { parts.minutes[index] = picked }
                               parts.minutes = Array(Set(parts.minutes)).sorted()
                           }), width: Self.time)
            }
            if parts.minutes.count < 6 {
                Button { add() } label: { Symbol("plus", size: 10) }
                    .buttonStyle(.yab(.secondary, .small))
                    .fixedSize()
                    .keyTip("Another time of day")
                    .accessibilityLabel("Add a time of day")
            }
        }
    }

    private func add() {
        let last = parts.minutes.last ?? 8 * 60
        let free = stride(from: last + 60, through: 23 * 60 + 30, by: 30).first { !parts.minutes.contains($0) }
            ?? stride(from: 5 * 60, through: 23 * 60, by: 30).first { !parts.minutes.contains($0) }
        guard let free else { return }
        parts.minutes = (parts.minutes + [free]).sorted()
    }

    /// What a short month or year does with a day it hasn't.
    private var note: String? {
        if parts.repeats == RoutineWhen.monthly, parts.which == 0, parts.monthDay > 28 { return "the last day in shorter months" }
        if parts.repeats == RoutineWhen.yearly, parts.month == 2, parts.yearDay == 29 { return "Feb 28 in other years" }
        if parts.repeats == RoutineWhen.everyDays || parts.repeats == RoutineWhen.everyWeeks { return "counted from its last run" }
        return nil
    }

    private func line(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
    }
}

/// The days of the week a routine runs on, from Monday.
private struct RoutineDays: View {
    @Binding var days: Set<Int>

    var body: some View {
        HStack(spacing: 4) {
            ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { day in
                let on = days.contains(day)
                Button(String(Calendar.current.veryShortWeekdaySymbols[day - 1])) {
                    if on, days.count > 1 { days.remove(day) } else { days.insert(day) }
                }
                .buttonStyle(.yab(on ? .primary : .secondary, .small))
                .accessibilityLabel(Calendar.current.weekdaySymbols[day - 1])
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

/// A when as the editor's menus hold it, and back: how often, the times of
/// day, and what the kind of repeat needs besides: the days picked one by
/// one, a day of the month or a weekday of it, a date, a gap.
enum RoutineWhen {
    static let onDays = "days"
    static let monthly = "monthly"
    static let yearly = "yearly"
    static let everyDays = "every days"
    static let everyWeeks = "every weeks"
    static let often = ["daily", "weekdays", "weekends", onDays, monthly, yearly, everyDays, everyWeeks, "hourly", "every 2h", "every 4h", "on open"]
    /// The kinds that need more than a time: the editor's, not a cell's.
    static let detailed: Set<String> = [onDays, monthly, yearly, everyDays, everyWeeks]

    struct Parts: Equatable {
        var repeats: String
        /// The minutes of the day it runs at, earliest first.
        var minutes: [Int]
        /// Weekly and every few weeks: its days.
        var days: Set<Int>
        /// Monthly: 0 by the day of the month, else which of a weekday
        /// (1 to 5, -1 the last).
        var which = 0
        /// Monthly by the day: 1 to 31, 0 the last.
        var monthDay = 1
        /// Monthly by a weekday: 1 Sunday … 7 Saturday.
        var weekday = 2
        /// Yearly: its month and day.
        var month = 1
        var yearDay = 1
        /// Every few days or weeks: how many.
        var gap = 2

        var minute: Int { minutes.first ?? 9 * 60 }
    }

    /// Its parts, with today's date and weekday for what it doesn't say.
    static func split(_ when: String, now: Date = Date()) -> Parts {
        let calendar = Routines.localCalendar
        let today = calendar.dateComponents([.month, .day, .weekday], from: now)
        var parts = Parts(repeats: "weekdays", minutes: [9 * 60], days: [2, 3, 4, 5, 6])
        parts.monthDay = today.day ?? 1
        parts.month = today.month ?? 1
        parts.yearDay = today.day ?? 1
        parts.weekday = today.weekday ?? 2
        let when = when.lowercased()
        switch Routines.schedule(when) {
        case .days(let days, let at):
            parts.minutes = at
            switch days {
            case .week(let set):
                if set.count == 7 { parts.repeats = "daily" }
                else if set == [2, 3, 4, 5, 6] { parts.repeats = "weekdays" }
                else if set == [1, 7] { parts.repeats = "weekends"; parts.days = set }
                else { parts.repeats = onDays; parts.days = set }
            case .cycle(let n):
                parts.repeats = everyDays
                parts.gap = n
            case .weeks(let n, let set):
                parts.repeats = everyWeeks
                parts.gap = n
                parts.days = set
            case .month(let d):
                parts.repeats = monthly
                parts.which = 0
                parts.monthDay = d
            case .nth(let n, let day):
                parts.repeats = monthly
                parts.which = n
                parts.weekday = day
            case .year(let m, let d):
                parts.repeats = yearly
                parts.month = m
                parts.yearDay = d
            }
        case .every, .opens, .mail:
            parts.repeats = when
        case nil:
            break
        }
        return parts
    }

    /// The words it is kept in.
    static func join(_ parts: Parts) -> String {
        if Routines.schedule(parts.repeats) != nil { return parts.repeats }
        let at = parts.minutes.isEmpty ? [9 * 60] : Array(Set(parts.minutes)).sorted()
        let days: Routines.Days
        switch parts.repeats {
        case "daily": days = .week(Set(1...7))
        case "weekends": days = .week([1, 7])
        case onDays: days = .week(parts.days.isEmpty ? [2, 3, 4, 5, 6] : parts.days)
        case everyDays: days = .cycle(max(2, parts.gap))
        case everyWeeks: days = .weeks(max(2, parts.gap), parts.days.isEmpty ? [parts.weekday] : parts.days)
        case monthly: days = parts.which == 0 ? .month(parts.monthDay) : .nth(parts.which, weekday: parts.weekday)
        case yearly: days = .year(month: parts.month, day: min(parts.yearDay, longest(parts.month)))
        default: days = .week([2, 3, 4, 5, 6])
        }
        return Routines.words(.days(days, at: at))
    }

    static func join(_ repeats: String, _ minute: Int, _ days: Set<Int>) -> String {
        join(Parts(repeats: repeats, minutes: [minute], days: days))
    }

    /// The most days a month has, Feb 29 counted.
    static func longest(_ month: Int) -> Int { [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][max(0, min(11, month - 1))] }

    /// A time of day matters to the days, not to a gap between runs.
    static func timed(_ repeats: String) -> Bool { Routines.schedule(repeats) == nil }

    static func choices(_ current: String) -> [(title: String, value: String)] {
        let keys = often.contains(current) ? often : often + [current]
        return keys.map { key in
            switch key {
            case "daily": return ("Every Day", key)
            case "weekdays": return ("Weekdays", key)
            case "weekends": return ("Weekends", key)
            case onDays: return ("Weekly…", key)
            case monthly: return ("Monthly…", key)
            case yearly: return ("Yearly…", key)
            case everyDays: return ("Every Few Days…", key)
            case everyWeeks: return ("Every Few Weeks…", key)
            case "hourly": return ("Every Hour", key)
            case "on open": return ("When Yab Opens", key)
            default: return (Routines.say(key).capitalized, key)
            }
        }
    }

    static func times(_ current: Int) -> [(title: String, value: Int)] {
        var minutes = Array(stride(from: 5 * 60, through: 23 * 60, by: 30))
        if !minutes.contains(current) { minutes = (minutes + [current]).sorted() }
        return minutes.map { (Routines.clock($0), $0) }
    }

    /// Monthly's first menu: by the day, or which of a weekday.
    static let whiches: [(title: String, value: Int)] = [("On Day", 0), ("First", 1), ("Second", 2), ("Third", 3), ("Fourth", 4), ("Last", -1)]

    /// The days of a month, and its last.
    static let monthDays: [(title: String, value: Int)] = (1...31).map { (Routines.nth($0), $0) } + [("Last Day", 0)]

    /// The weekdays from Monday.
    static var weekdays: [(title: String, value: Int)] {
        [2, 3, 4, 5, 6, 7, 1].map { (Calendar.current.weekdaySymbols[$0 - 1], $0) }
    }

    static var months: [(title: String, value: Int)] {
        (1...12).map { (Calendar.current.monthSymbols[$0 - 1], $0) }
    }

    static func gaps(_ unit: String, most: Int, current: Int) -> [(title: String, value: Int)] {
        var counts = Array(2...most)
        if !counts.contains(current) { counts = (counts + [current]).sorted() }
        return counts.map { ("Every \($0) " + unit, $0) }
    }
}

// MARK: - a command, run regularly

struct RoutineCardLayer: View {
    @Bindable private var editing = RoutineEditing.shared
    let browser: Browser

    var body: some View {
        ZStack {
            if let card = editing.card {
                RoutineCommandCard(browser: browser, command: card.command) { editing.closeCard() }
                    .frame(width: 440)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.97).combined(with: .opacity).animation(Motion.arrive),
                        removal: .identity
                    ))
                    .id(card.id)
            }
        }
    }
}

/// Run Regularly…'s card: the command's name, the tab it runs on, and when,
/// said back in words under the title as they change.
private struct RoutineCommandCard: View {
    let browser: Browser
    let command: SelectionCommand
    let done: () -> Void
    private var newTabKey = Keymap.shared.slot(.newTab)

    @State private var page: String
    @State private var repeats = "daily"
    @State private var minute = 8 * 60

    init(browser: Browser, command: SelectionCommand, done: @escaping () -> Void) {
        self.browser = browser
        self.command = command
        self.done = done
        let front = browser.active?.address.flatMap { $0.scheme?.hasPrefix("http") == true ? $0.absoluteString : nil }
        _page = State(initialValue: front ?? "")
    }

    private var name: String { SelectionCommand.menuTitle(command.name) }
    private var when: String { RoutineWhen.join(repeats, minute, [2, 3, 4, 5, 6]) }
    private var host: String { URL(string: page)?.host().map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? "" }

    /// The tabs you have open and the sites you go to, as the cell's menu.
    private var pages: [(title: String, value: String)] {
        var seen = Set<String>()
        var out: [(String, String)] = []
        if page.isEmpty { out.append(("Choose a Page", "")) }
        if !page.isEmpty { out.append((URL(string: page).map(Address.pretty) ?? page, page)); seen.insert(page) }
        for tab in browser.tabs {
            guard let url = tab.address, url.scheme?.hasPrefix("http") == true, seen.insert(url.absoluteString).inserted else { continue }
            out.append((tab.label, url.absoluteString))
        }
        for site in RoutineIdeas.shared.sites(6) where seen.insert("https://" + site).inserted {
            out.append((site, "https://" + site))
        }
        return Array(out.prefix(16))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: CardFrame.wellGap) {
                well
                VStack(alignment: .leading, spacing: 2) {
                    Text("Run \(name) regularly")
                        .font(CardFrame.title)
                        .foregroundStyle(Palette.ink)
                    SettingsText(page.isEmpty ? "Pick the page it runs on."
                         : "\(name) on \(host), \(Routines.say(when).lowercased()). What it says comes to its chat and \(routineNewTabPlace(newTabKey.keys, plates: true)).", size: 13)
                        .font(CardFrame.detail)
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(spacing: 2) {
                row("On") {
                    MenuCell(title: "On", options: pages, selection: $page)
                }
                row("Repeats") {
                    MenuCell(title: "Repeats", options: RoutineWhen.choices(repeats).filter { !RoutineWhen.detailed.contains($0.value) }, selection: $repeats)
                    MenuCell(title: "At", options: RoutineWhen.times(minute), selection: $minute)
                        .opacity(RoutineWhen.timed(repeats) ? 1 : 0)
                        .allowsHitTesting(RoutineWhen.timed(repeats))
                        .accessibilityHidden(!RoutineWhen.timed(repeats))
                }
            }
            .padding(.top, 12)
            HStack(spacing: 6) {
                Spacer(minLength: 8)
                Button(action: done) {
                    HStack(spacing: 6) {
                        Text("Cancel")
                        KeyGlyphs(keys: "esc", size: CardFrame.words, tint: nil, rest: 0.6)
                    }
                }
                .buttonStyle(.yab(.secondary, CardFrame.button))
                .fixedSize()
                Button(action: save) {
                    HStack(spacing: 6) {
                        Text("Add")
                        KeyGlyphs(keys: "↩", size: CardFrame.words, tint: nil, rest: 0.6)
                    }
                }
                .buttonStyle(.yab(.primary, CardFrame.button))
                .fixedSize()
                .disabled(page.isEmpty)
                .allowsHitTesting(!page.isEmpty)
            }
            .padding(.top, CardFrame.buttonGap)
        }
        .cardFrame()
        .onExitCommand(perform: done)
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 13.5))
                .foregroundStyle(Palette.ink)
            Spacer(minLength: 8)
            content()
        }
        .padding(.leading, 10)
        .frame(height: 32)
    }

    private func save() {
        guard !page.isEmpty else { return }
        var routine = Routine(id: Routines.newID(command.id), when: when, prompt: "", last: nil, title: name)
        routine.command = command.id
        routine.tabs = [page]
        if AgentPlan.isPlan(command.executor) {
            routine.cli = command.executor
            routine.model = command.model
            routine.effort = command.effort
        }
        Routines.shared.put(routine)
        done()
    }

    private var well: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        return shape.fill(Palette.ink.opacity(0.05))
            .overlay(shape.strokeBorder(Palette.ink.opacity(0.08), lineWidth: 0.5))
            .overlay { Symbol(SettingsPage.agentRoutines.icon, size: 16).foregroundStyle(Palette.ink) }
            .frame(width: CardFrame.well, height: CardFrame.well)
    }
}

extension SelectionCommand {
    /// Whether it means anything on a page with nothing selected, so can run
    /// on a schedule: not a rewrite of text you wrote, nor one of the Mac's.
    var runsOnPages: Bool {
        let rewrites: Set<String> = ["improve", "fix", "shorter", "longer", "formal", "friendly", "quote", "calendar", "map", "call", "convert"]
        return enabled && !rewrites.contains(id) && executor != "local" && !fieldsOnly && !codeOnly
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
