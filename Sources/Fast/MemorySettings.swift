import AppKit
import SwiftUI
import Combine

// Settings › Agents › Memory: what agents have learned about you, as the
// notes it is kept in (Memory.swift), a page further in as Routines is.
//
// The switch that lets agents remember is the page's own, in the toolbar,
// the way Spaces and Agents keep theirs. The notes are one table, grouped
// by what they are about, each row its title and when it last changed in
// words; a row opens the note's own page, as a space's row opens its page,
// with the note to read and correct, kept as it is typed. Show in Finder
// and Forget… are on that page and on a right click. With nothing kept
// yet, the page is a way in, as Spaces is while off: what it is, and Get
// to Know Me once an agent is connected.

/// What a note is about, by the folder it is in. The briefs lead their
/// kind: USER.md is You, MEMORY.md how agents work for you.
enum MemoryKind: String, CaseIterable {
    case you, agent, people, companies, sites, projects, concepts, days

    init?(path: String) {
        switch path {
        case "USER.md": self = .you
        case "MEMORY.md": self = .agent
        default:
            guard let slash = path.firstIndex(of: "/") else { return nil }
            switch path[..<slash] {
            case "users": self = .you
            case "agent": self = .agent
            case "people": self = .people
            case "companies": self = .companies
            case "sites": self = .sites
            case "projects": self = .projects
            case "concepts": self = .concepts
            case "episodic": self = .days
            default: return nil
            }
        }
    }

    var title: String {
        switch self {
        case .you: return "You"
        case .agent: return "How agents work for you"
        case .people: return "People"
        case .companies: return "Companies"
        case .sites: return "Sites"
        case .projects: return "Projects"
        case .concepts: return "Concepts"
        case .days: return "Days"
        }
    }

    var glyph: String {
        switch self {
        case .you: return "person"
        case .agent: return "agent.face"
        case .people: return "person.text.rectangle"
        case .companies: return "building.2"
        case .sites: return "globe"
        case .projects: return "folder"
        case .concepts: return "book"
        case .days: return "calendar"
        }
    }
}

/// One note as the page lists it.
struct MemoryNote: Identifiable, Equatable {
    /// Its path inside the memory folder, as `Memory.files()` lists it.
    let path: String
    let title: String
    let changed: Date
    var id: String { path }
    var kind: MemoryKind? { MemoryKind(path: path) }
    /// A day's note: its day, "2026-10-20".
    var day: String { ((path as NSString).lastPathComponent as NSString).deletingPathExtension }
}

/// The notes on disk, read for the page, and what the page does to them.
@MainActor
@Observable final class MemoryShelf {
    static let shared = MemoryShelf()

    /// Every note that says something, the seeds and the taxonomy left out.
    private(set) var notes: [MemoryNote] = []
    private(set) var keepsAddresses = false
    private(set) var keepsSyncReview = false
    var hasRetainedContext: Bool { !notes.isEmpty || KnowReport.exists || !Profile.load().isEmpty || keepsAddresses || keepsSyncReview }
    @ObservationIgnored private var contextChanges: AnyCancellable?

    private init() {
        reload()
        contextChanges = NotificationCenter.default.publisher(for: ContextPrivacy.changed).receive(on: RunLoop.main).sink { [weak self] _ in self?.reload() }
    }

    func reload() {
        keepsSyncReview = !ContextPrivacy.shared.syncReview.isEmpty
        var found: [MemoryNote] = []
        for path in Memory.files() where MemoryKind(path: path) != nil {
            let url = Memory.folder.appendingPathComponent(path)
            guard let body = try? String(contentsOf: url, encoding: .utf8), Memory.meaningful(body) else { continue }
            let changed = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            found.append(MemoryNote(path: path, title: Self.title(path: path, body: body), changed: changed))
        }
        if found != notes { notes = found }
        let epoch = ContextPrivacy.shared.epoch
        DispatchQueue.global(qos: .utility).async {
            let kept = Wallet.hasAddresses
            DispatchQueue.main.async {
                guard ContextPrivacy.shared.current(epoch) else { return }
                if self.keepsAddresses != kept { self.keepsAddresses = kept }
            }
        }
    }

    var groups: [(kind: MemoryKind, notes: [MemoryNote])] { Self.group(notes) }

    func note(_ path: String) -> MemoryNote? { notes.first { $0.path == path } }

    /// A listed note's file, and never anything outside the folder.
    func url(_ path: String) -> URL? {
        guard !path.contains(".."), MemoryKind(path: path) != nil else { return nil }
        let url = Memory.folder.appendingPathComponent(path)
        let root = Memory.folder.resolvingSymlinksInPath().standardizedFileURL.path
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolved.hasPrefix(root + "/"),
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        return url
    }

    func read(_ path: String) -> String {
        url(path).flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }

    /// The note as corrected by hand: nil when kept, else why not, in the
    /// limits `Memory.write` keeps an agent to.
    func save(_ path: String, text: String, epoch: String? = nil) -> String? {
        guard epoch.map({ ContextPrivacy.shared.current($0) }) ?? true else { return "This context was cleared. Reopen the note." }
        guard let url = url(path) else { return "This note is gone." }
        guard text.utf8.count <= Memory.fileLimit else { return "Too long to keep: a note holds \(Memory.fileLimit / 1024) KB at most." }
        let others = Memory.files().filter { $0 != path }
            .reduce(0) { $0 + ((try? Data(contentsOf: Memory.folder.appendingPathComponent($1)).count) ?? 0) }
        guard others + text.utf8.count <= Memory.totalLimit else { return "Memory is full: forget a note or two first." }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return error.localizedDescription
        }
        reload()
        return nil
    }

    /// One note gone. A brief is put back to its seed rather than deleted,
    /// since every task reads it.
    func forget(_ path: String) {
        guard let url = url(path) else { return }
        switch path {
        case "USER.md": try? Seeds.user.write(to: url, atomically: true, encoding: .utf8)
        case "MEMORY.md": try? Seeds.operating.write(to: url, atomically: true, encoding: .utf8)
        default: try? FileManager.default.removeItem(at: url)
        }
        reload()
    }

    func forgetEverything() {
        Memory.forgetEverything()
        reload()
    }

    func showInFinder(_ path: String? = nil) {
        if let path, let url = url(path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            try? FileManager.default.createDirectory(at: Memory.folder, withIntermediateDirectories: true)
            NSWorkspace.shared.activateFileViewerSelecting([Memory.folder])
        }
    }

    // MARK: - words

    /// The note's name: the briefs by what they are, a day by its date,
    /// a subject page by the name in its frontmatter or its first heading,
    /// else by its file's name.
    nonisolated static func title(path: String, body: String) -> String {
        switch path {
        case "USER.md": return "About you"
        case "MEMORY.md": return "How to work for you"
        default: break
        }
        let file = (path as NSString).lastPathComponent
        let slug = (file as NSString).deletingPathExtension
        if path.hasPrefix("episodic/"), let day = dayFormat.date(from: slug) {
            return dayTitle(day)
        }
        let lines = body.components(separatedBy: "\n")
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            for line in lines[1..<end] {
                let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2, ["name", "title"].contains(parts[0].lowercased()) {
                    let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    if !value.isEmpty { return value }
                }
            }
        }
        if let heading = lines.first(where: { $0.hasPrefix("# ") }) {
            let text = heading.dropFirst(2).trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { return text }
        }
        // A site's page is its host as it is; anything else, its words.
        if path.hasPrefix("sites/") { return slug }
        return slug.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// In the order the page lists them: the kinds in theirs, each brief
    /// ahead of its kind's pages, the days newest first, the rest by name.
    nonisolated static func group(_ notes: [MemoryNote]) -> [(kind: MemoryKind, notes: [MemoryNote])] {
        MemoryKind.allCases.compactMap { kind in
            let mine = notes.filter { $0.kind == kind }
            guard !mine.isEmpty else { return nil }
            let sorted = mine.sorted { a, b in
                let (x, y) = (a.path.contains("/"), b.path.contains("/"))
                if x != y { return !x }
                if kind == .days { return a.path > b.path }
                return a.title.localizedStandardCompare(b.title) == .orderedAscending
            }
            return (kind, sorted)
        }
    }

    /// When a note last changed, in a word or two: "Today", "Yesterday",
    /// "3 days ago", "Sep 20", "Sep 20, 2025".
    nonisolated static func when(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ...0: return "Today"
        case 1: return "Yesterday"
        case 2...6: return "\(days) days ago"
        default:
            let format = DateFormatter()
            format.locale = Locale(identifier: "en_US_POSIX")
            format.calendar = calendar
            format.timeZone = calendar.timeZone
            format.dateFormat = calendar.component(.year, from: date) == calendar.component(.year, from: now) ? "MMM d" : "MMM d, yyyy"
            return format.string(from: date)
        }
    }

    /// The same as a line: "Changed today", "Changed 3 days ago",
    /// "Changed on Sep 20".
    nonisolated static func changed(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let words = when(date, now: now, calendar: calendar)
        if words == "Today" || words == "Yesterday" || words.hasSuffix(" ago") { return "Changed " + words.lowercased() }
        return "Changed on " + words
    }

    nonisolated private static let dayFormat: DateFormatter = {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd"
        return format
    }()

    /// "Thursday, September 24".
    nonisolated static func dayTitle(_ day: Date) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "EEEE, MMMM d"
        return format.string(from: day)
    }
}

// MARK: - the page

struct AgentMemoryPage: View {
    var browser: Browser
    var prefs: Preferences
    var model: SettingsModel
    private var shelf = MemoryShelf.shared
    private var setup = AgentSetupModel.shared
    private var days = DaysModel.shared

    var body: some View {
        if let opened = model.opened {
            // Its own state for each note's page, never the last one's.
            MemoryNotePage(path: opened, model: model, browser: browser)
                .id(opened)
        } else {
            list
                .onAppear {
                    days.editing = nil
                    days.load(shelf.notes.filter { $0.kind == .days }.map(\.day))
                }
                .onChange(of: shelf.notes) { _, notes in days.load(notes.filter { $0.kind == .days }.map(\.day)) }
        }
    }

    @ViewBuilder
    private var list: some View {
        PageHero(page: .agentMemory)
            .settingsAnchor("agents-remember")
            .onAppear { shelf.reload() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in shelf.reload() }
            // While Get to Know Me writes, its notes come in as they land.
            .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
                if setup.knowingNow != nil { shelf.reload() }
            }
        MemoryKnowingSection(browser: browser)
        AsideBringer()
        let groups = shelf.groups
        ForEach(Array(groups.enumerated()), id: \.element.kind) { index, group in
            Section {
                ForEach(group.notes) { note in
                    MemoryNoteRow(note: note, detail: group.kind == .days ? days.summary(note) : nil) { model.open(.agentMemory, item: note.path) }
                        .settingsAnchor(index == 0 && note.id == group.notes.first?.id ? "memory-notes" : "memory-" + note.path)
                }
            } header: {
                Text(group.kind.title).foregroundStyle(.secondary)
            } footer: {
                if index == 0, !prefs.agentsRemember {
                    SettingsNote("When memory is off, agents cannot read or update these notes.")
                }
            }
        }
        Section {
            // The page shows the profile, the Wallet and the run's report too:
            // there with any of them, not only with notes.
            if shelf.hasRetainedContext {
                SettingsRow("Notes About You", detail: "Review and edit your saved profile notes.") {
                    Button(SettingsWords.text("Open")) { KnowPage.show(in: browser) }
                        .settingsButton()
                }
                .settingsAnchor("memory-notes-page")
            }
            MemoryGetToKnowRow(prefs: prefs)
            SettingsRow("Your notes", detail: "Markdown notes stored on this Mac. Open or edit them in any app.") {
                Button("Show in Finder") { shelf.showInFinder() }
                    .settingsButton()
            }
            .settingsAnchor("memory-finder")
            SettingsRow("Forget everything", detail: "Review and remove collected notes, photos and profile details. Later edits are protected.") {
                Button("Forget…") { MemoryAsk.forgetEverything() }
                    .buttonStyle(.yab(.secondary, .regular, tint: ButtonCSS.danger))
            }
            .settingsAnchor("memory-forget")
        } footer: {
            SettingsNote("Right-click a note to show it in Finder or forget it.")
        }
    }
}

// MARK: - getting to know you

/// What Get to Know Me does, said beside every button that starts it: the
/// press is the yes, so it says what it reads, that it works out of sight,
/// and what it never does.
@MainActor
enum MemoryKnowing {
    static let does = "Read signed-in sites in the background and save profile notes. No messages or purchases."
    static let paused = "Agents are paused. Turn them on in AI › Agents."

    /// Its step, in words: "Opening linkedin.com".
    static func step(_ session: Agents.Session) -> String {
        AgentDock.say(session.now, name: session.name)
    }

    /// "Getting to know you: opening linkedin.com", the step's first
    /// letter lowered; "Claude is working" keeps its name.
    static func line(_ session: Agents.Session) -> String {
        let step = step(session)
        return "Getting to know you: " + (step.hasPrefix(session.name) ? step : step.prefix(1).lowercased() + step.dropFirst())
    }

    /// Its chat, in the column of the browser's window, brought forward
    /// over Settings as Passwords and Downloads are.
    static func showChat(_ session: Agents.Session, in browser: Browser) {
        browser.tuning = false
        NSApp.activate()
        BrowserWindows.shared.window(for: browser)?.makeKeyAndOrderFront(nil)
        browser.showChat(session.id)
    }
}

/// Get to Know at work, from wherever it was started: its step in words,
/// its chat and Stop. Its own view, watching the agents, so only it is
/// drawn again as the step changes.
private struct MemoryKnowingSection: View {
    var browser: Browser
    private var agents = Agents.shared
    private var setup = AgentSetupModel.shared

    var body: some View {
        if let session = setup.knowingNow {
            Section {
                SettingsRow("Getting to know you", detail: MemoryKnowing.step(session)) {
                    HStack(spacing: 8) {
                        if agents.hasChat(session.id) {
                            Button("Show Chat") { MemoryKnowing.showChat(session, in: browser) }
                                .settingsButton()
                        }
                        // Whoever started it: the welcome, the new tab, a form or here.
                        Button("Stop") { setup.stopKnowing() }
                            .settingsButton()
                    }
                }
                .settingsAnchor("memory-knowing")
            }
        }
    }
}

/// Get to Know Me, offered while nothing runs: what it does beside it, and
/// with agents paused, why it can't start.
private struct MemoryGetToKnowRow: View {
    var prefs: Preferences
    private var agents = Agents.shared
    private var setup = AgentSetupModel.shared

    var body: some View {
        if prefs.agentsRemember, setup.anyConnected, setup.knowingNow == nil {
            SettingsRow("Get to Know Me", detail: prefs.bench ? MemoryKnowing.does : MemoryKnowing.paused) {
                Button("Get to Know Me") { setup.getToKnow() }
                    .settingsButton()
                    .disabled(!prefs.bench)
            }
            .settingsAnchor("memory-get-to-know")
        }
    }
}

/// One note: its title, and when it changed across from it; its page on a
/// click, Show in Finder and Forget… on a right click. A day says its
/// threads under its title (`detail`).
private struct MemoryNoteRow: View {
    let note: MemoryNote
    var detail: String? = nil
    let open: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(note.title)
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // A day by the day it is; any other note by when it changed.
            Text(MemoryShelf.when(note.kind == .days ? Diary.day(named: note.day) ?? note.changed : note.changed))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            SettingsChevron()
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .contextMenu {
            Button("Show in Finder") { MemoryShelf.shared.showInFinder(note.path) }
            Divider()
            Button("Forget…") { MemoryAsk.forget(note) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens \(note.title)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Forget") { MemoryAsk.forget(note) }
    }
}

/// What can't be taken back, asked first in the app's own card.
@MainActor
enum MemoryAsk {
    static func forget(_ note: MemoryNote, then: @escaping () -> Void = {}) {
        let brief = !note.path.contains("/")
        let question = Question(
            title: "Forget “\(note.title)”?",
            detail: brief
                ? "Its lines are cleared, and agents start this note over."
                : "The note is deleted from this Mac, and agents won't know it anymore.",
            glyph: "trash", yes: "Forget", danger: true, place: .settings)
        Task { @MainActor in
            guard await Questions.shared.ask(question) else { return }
            then()
            MemoryShelf.shared.forget(note.path)
        }
    }

    static func forgetEverything() {
        Task { @MainActor in
            let review = MemoryClearReview()
            while true {
                var question = Question(title: "Forget what agents learned?",
                    detail: "Stops context collection before clearing. Protects later Profile and Wallet edits.",
                    glyph: "trash", yes: "Forget", danger: true, place: .settings)
                question.accessory = AnyView(MemoryClearReviewContent(review: review))
                question.enablement = review.enablement
                guard await Questions.shared.ask(question) else { return }
                guard review.perform() else { continue }
                let result = review.result ?? ContextPrivacy.ClearResult()
                _ = await Questions.shared.ask(Question(title: "Memory cleared",
                    detail: "\(result.removed) values removed, \(result.restored) earlier values restored, \(result.preserved) explicitly kept or later edited values protected. Notes, saved photos and the report are cleared. Sync removals are queued locally.",
                    glyph: "trash", yes: "Done", place: .settings))
                return
            }
        }
    }
}

// MARK: - one note

/// A note's own page: what it is, its text to read and correct, kept as
/// it is typed, and Show in Finder and Forget… under it.
private struct MemoryNotePage: View {
    let path: String
    @State private var contextEpoch = ContextPrivacy.shared.epoch
    @State private var firstNote: MemoryNote?
    var model: SettingsModel
    let browser: Browser?
    private var shelf = MemoryShelf.shared

    @State private var text: String
    @State private var trouble: String?
    @State private var pending: DispatchWorkItem?
    /// A day's page shows its timeline until Edit as Markdown (⌘E).
    private var days = DaysModel.shared

    init(path: String, model: SettingsModel, browser: Browser? = nil) {
        self.path = path
        self.model = model
        self.browser = browser
        _firstNote = State(initialValue: MemoryShelf.shared.note(path))
        _text = State(initialValue: MemoryShelf.shared.read(path))
    }

    var body: some View {
        // A note cleared in the editor stops being meaningful, but its page
        // must stay open so the person can keep typing or undo the clearing.
        if shelf.url(path) != nil, let note = shelf.note(path) ?? firstNote, note.kind == .days, days.editing != path {
            DayPage(note: note, text: shelf.read(path), browser: browser) { days.editing = path }
        } else if shelf.url(path) != nil, let note = shelf.note(path) ?? firstNote, let kind = note.kind {
            hero(note, kind)
            Section {
                ThreadTextEditor(text: $text)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 260)
                    .accessibilityLabel(note.title)
                    .onChange(of: text) { _, _ in keepSoon() }
                    .onDisappear(perform: keep)
                    .settingsAnchor("memory-note-text")
            } footer: {
                if let trouble {
                    Text(trouble)
                        .font(.callout)
                        .foregroundStyle(ButtonCSS.danger)
                } else {
                    SettingsNote("Markdown. Edits save automatically and apply to the next agent task.")
                }
            }
            Section {
                SettingsRow("Show in Finder", detail: path) {
                    Button("Show in Finder") { shelf.showInFinder(path) }
                        .settingsButton()
                }
                SettingsRow("Forget", detail: note.path.contains("/") ? "Delete this note from this Mac." : "Clear this note's contents.") {
                    Button("Forget…") {
                        keep()
                        MemoryAsk.forget(note) { model.leave(path, to: .agentMemory) }
                    }
                    .buttonStyle(.yab(.secondary, .regular, tint: ButtonCSS.danger))
                }
                .settingsAnchor("memory-note-forget")
            }
        } else {
            Section { SettingsNote("This note is gone.") }
        }
    }

    /// Its kind's glyph on Memory's tile, its title, what it is and when
    /// it changed, as a space's page opens with its own.
    private func hero(_ note: MemoryNote, _ kind: MemoryKind) -> some View {
        Section {} header: {
            VStack(spacing: 0) {
                PenTileView(symbol: kind.glyph, tint: PenArt.color(.agentMemory), side: 56).frame(width: 56, height: 56)
                    .padding(.bottom, 12)
                Text(note.title)
                    .font(.system(size: 22, weight: .bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text(kind.title + " · " + MemoryShelf.changed(note.changed))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.top, 5) // design: PageHero's gap under the name
            }
            .foregroundStyle(.primary)
            .textCase(nil)
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
            .padding(.bottom, 18) // design: PageHero's air above the first group
            .accessibilityElement(children: .combine)
        }
    }

    /// Kept a moment after the last key, not on every one.
    private func keepSoon() {
        let epoch = ContextPrivacy.shared.epoch
        pending?.cancel()
        let work = DispatchWorkItem { if ContextPrivacy.shared.current(epoch) { keep() } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func keep() {
        pending?.cancel()
        pending = nil
        guard shelf.url(path) != nil, text != shelf.read(path) else { return }
        trouble = shelf.save(path, text: text, epoch: contextEpoch)
    }
}

// MARK: - nothing yet

/// Nothing kept yet: not a form but a way in, in the middle of the pane,
/// as Spaces is while off. What it is, and Get to Know Me once an agent
/// is connected and may remember.
struct MemoryArrival: View {
    var browser: Browser
    var prefs: Preferences
    private var setup = AgentSetupModel.shared
    private var shelf = MemoryShelf.shared
    /// Get to Know started anywhere shows here, and its step moves on.
    private var agents = Agents.shared

    var body: some View {
        ArrivalPage(page: .agentMemory, title: "Memory", blurb: words) {
            if setup.knowingNow != nil || !prefs.agentsRemember || setup.anyConnected {
                action
                    .padding(.top, 20)
            }
            Text(line)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360)
                .padding(.top, 12)
        }
        .onAppear { shelf.reload() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in shelf.reload() }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            if setup.knowingNow != nil { shelf.reload() }
        }
    }

    private var words: String {
        if let session = setup.knowingNow { return MemoryKnowing.line(session) }
        return "What agents learn about you as they work: who you are, the people and sites in your days, how you like things done. Nothing yet."
    }

    private var line: String {
        if setup.knowingNow != nil { return "Out of sight, about ten minutes. Nothing is sent or bought." }
        if !prefs.agentsRemember { return "Agents don't remember anything while the switch above is off." }
        if !setup.anyConnected { return "Connect Claude or ChatGPT in AI, and it starts here." }
        if !prefs.bench { return MemoryKnowing.paused }
        return "Your agent reads the sites you're signed in to, out of sight, and keeps what it learns here, on this Mac. Nothing is sent or bought."
    }

    @ViewBuilder
    private var action: some View {
        if let session = setup.knowingNow {
            HStack(spacing: 8) {
                if agents.hasChat(session.id) {
                    Button("Show Chat") { MemoryKnowing.showChat(session, in: browser) }
                        .settingsButton()
                }
                Button("Stop") { setup.stopKnowing() }
                    .settingsButton()
            }
        } else if !prefs.agentsRemember {
            Button("Turn On Memory") { prefs.agentsRemember = true }
                .settingsButton(.primary)
        } else if setup.anyConnected {
            Button("Get to Know Me") { setup.getToKnow() }
                .settingsButton(.primary)
                .disabled(!prefs.bench)
        }
    }
}
