import AppKit
import SwiftUI

// Settings › Agents › Skills: what agents know about sites before they get
// there (Skills.swift), a page further in as Routines is.
//
// One table in two groups, yours and the ones yab comes with, each row the
// site's mark, the skill's name, its sites, and how many ⌘J actions it
// brings. A row opens the skill's own page: what it says it is for, its
// sites, words, actions and reads, and the page itself, to read for a
// built-in one and to change for yours. A built-in one is changed by
// duplicating it into yours, which then wins by its name. New Skill… asks
// a name, or the site it is for, in the app's own card, and makes the
// folder from a template. The list is read again whenever the page shows,
// yab comes to the front, or the folder of yours changes.

/// The file work behind the page, apart from it so it can be tested with
/// folders of its own.
enum SkillFiles {
    /// A skill's name as its folder is called: lowercase letters, digits
    /// and dashes.
    static func slug(_ text: String) -> String {
        let folded = text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(folded).split(separator: "-").joined(separator: "-")
    }

    /// What New Skill… was answered with: a name, or a site, whose skill is
    /// then named for it ("github.com" is github, for github.com). Nil when
    /// nothing is left to name it by.
    static func named(_ typed: String) -> (name: String, site: String?)? {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for scheme in ["https://", "http://"] where text.hasPrefix(scheme) { text = String(text.dropFirst(scheme.count)) }
        let looksLikeSite = text.contains(".") && !text.contains(" ") && !text.hasPrefix(".") && !text.hasSuffix(".")
        if looksLikeSite {
            var site = text
            if site.hasSuffix("/") { site.removeLast() }
            if site.hasPrefix("www.") { site = String(site.dropFirst(4)) }
            let host = site.split(separator: "/").first.map(String.init) ?? site
            let labels = host.split(separator: ".")
            let name = slug(labels.count > 1 ? labels.dropLast().joined(separator: "-") : host)
            return name.isEmpty ? nil : (name, site)
        }
        let name = slug(text)
        return name.isEmpty ? nil : (name, nil)
    }

    /// A new skill's SKILL.md: the frontmatter an agent and the index read,
    /// and a page to fill in.
    static func template(name: String, site: String?) -> String {
        """
        ---
        name: \(name)
        description: What an agent should know about \(site ?? "this"), in a line.
        sites: \(site ?? "")
        keywords: \(name)
        ---

        # \(site ?? name.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " "))

        How the site works for an agent with Yab's tools: where things are, what to press, what to leave alone.
        """
    }

    /// A new skill's folder in `root`, with its SKILL.md. The folder that
    /// is there already is left as it is.
    @discardableResult
    static func create(name: String, site: String?, in root: URL) throws -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        let file = folder.appendingPathComponent("SKILL.md")
        if FileManager.default.fileExists(atPath: file.path) { return file }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try template(name: name, site: site).write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    /// A built-in skill's folder, everything in it, copied into `root`
    /// under its own folder's name. A copy there already is kept, not
    /// overwritten: it is yours.
    @discardableResult
    static func duplicate(_ skillFile: URL, into root: URL) throws -> URL {
        let from = skillFile.deletingLastPathComponent()
        let to = root.appendingPathComponent(from.lastPathComponent, isDirectory: true)
        let file = to.appendingPathComponent("SKILL.md")
        if FileManager.default.fileExists(atPath: file.path) { return file }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: from, to: to)
        return file
    }

    /// "3 actions", or nothing without any.
    static func actions(_ count: Int) -> String {
        count == 0 ? "" : count == 1 ? "1 action" : "\(count) actions"
    }

    /// The host a site is kept under for its icon: "docs.google.com" of
    /// "docs.google.com/spreadsheets".
    static func host(_ site: String) -> String {
        let host = site.split(separator: "/").first.map(String.init) ?? site
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// The skills on disk, read for the page, and what the page does to them.
@MainActor
@Observable final class SkillShelf {
    static let shared = SkillShelf()

    private(set) var skills: [Skills.Skill] = []
    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?

    private init() {}

    var yours: [Skills.Skill] { skills.filter(\.own) }
    var builtIn: [Skills.Skill] { skills.filter { !$0.own } }

    func reload() {
        Skills.reload()
        skills = Skills.all()
        watch()
    }

    func skill(_ name: String) -> Skills.Skill? { skills.first { $0.name == name } }

    /// A folder made or removed in yours, from a terminal, Finder or an
    /// agent, reads the list again.
    private func watch() {
        guard watcher == nil else { return }
        try? FileManager.default.createDirectory(at: Skills.mine, withIntermediateDirectories: true)
        let handle = open(Skills.mine.path, O_EVTONLY)
        guard handle >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: handle, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.reload()
                // The folder itself went: watched again once it is back.
                if source.data.contains(.delete) || source.data.contains(.rename) {
                    source.cancel()
                    self?.watcher = nil
                }
            }
        }
        source.setCancelHandler { close(handle) }
        source.resume()
        watcher = source
    }

    /// New Skill…'s answer made into a folder of yours; the name it is
    /// listed by, nil when the answer named nothing.
    func create(_ typed: String) -> String? {
        guard let (name, site) = SkillFiles.named(typed) else { return nil }
        // A site's built-in skill already has its actions and reads. Keep
        // those when making an editable copy instead of replacing them with
        // the empty New Skill template.
        if let builtIn = skills.first(where: { $0.name == name && !$0.own }) {
            return duplicate(builtIn) ? name : nil
        }
        guard (try? SkillFiles.create(name: name, site: site, in: Skills.mine)) != nil else { return nil }
        reload()
        return name
    }

    /// A built-in one copied into yours, to change: the copy wins by name.
    func duplicate(_ skill: Skills.Skill) -> Bool {
        guard (try? SkillFiles.duplicate(skill.path, into: Skills.mine)) != nil else { return false }
        reload()
        return true
    }

    func delete(_ skill: Skills.Skill) {
        guard skill.own, skill.path.path.hasPrefix(Skills.mine.path + "/") else { return }
        try? FileManager.default.removeItem(at: skill.path.deletingLastPathComponent())
        reload()
    }

    /// Yours as changed by hand: nil when kept, else why not.
    func save(_ skill: Skills.Skill, text: String) -> String? {
        guard skill.own else { return nil }
        guard let edited = Skills.parse(text, own: true, path: skill.path) else {
            return "Add YAML frontmatter between --- lines, including a name."
        }
        guard edited.name == skill.name else {
            return "Keep the name \(skill.name) to preserve this skill's identity."
        }
        do {
            try text.write(to: skill.path, atomically: true, encoding: .utf8)
        } catch {
            return error.localizedDescription
        }
        Skills.reload()
        skills = Skills.all()
        return nil
    }

    func showInFinder(_ skill: Skills.Skill? = nil) {
        if let skill {
            NSWorkspace.shared.activateFileViewerSelecting([skill.path])
        } else {
            try? FileManager.default.createDirectory(at: Skills.mine, withIntermediateDirectories: true)
            NSWorkspace.shared.activateFileViewerSelecting([Skills.mine])
        }
    }
}

/// New Skill… and Delete…, asked in the app's own card.
@MainActor
enum SkillAsk {
    static func new(_ model: SettingsModel) {
        let field = Question.Field("", prompt: "github.com, or a name")
        let question = Question(title: "New Skill", detail: "Enter a site or skill name, then add instructions.",
                                glyph: "script.ai", yes: "Create", field: field)
        Task { @MainActor in
            guard await Questions.shared.ask(question), let name = SkillShelf.shared.create(field.trimmed) else { return }
            model.open(.agentSkills, item: name)
        }
    }

    static func delete(_ skill: Skills.Skill, then: @escaping () -> Void = {}) {
        let shadowed = Skills.builtIn.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent(skill.path.deletingLastPathComponent().lastPathComponent).path) } ?? false
        let question = Question(
            title: "Delete the skill “\(skill.name)”?",
            detail: shadowed ? "Delete the custom skill folder and restore the built-in version." : "Delete the skill folder from this Mac.",
            glyph: "trash", yes: "Delete", danger: true, place: .settings)
        Task { @MainActor in
            guard await Questions.shared.ask(question) else { return }
            then()
            SkillShelf.shared.delete(skill)
        }
    }
}

// MARK: - the page

struct AgentSkillsPage: View {
    var model: SettingsModel
    private var shelf = SkillShelf.shared

    var body: some View {
        if let opened = model.opened {
            SkillPage(name: opened, model: model)
                .id(opened)
        } else {
            list
        }
    }

    @ViewBuilder
    private var list: some View {
        PageHero(page: .agentSkills)
            .settingsAnchor("skills")
            .onAppear { shelf.reload() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in shelf.reload() }
        Section {
            ForEach(shelf.yours, id: \.name) { skill in
                SkillRow(skill: skill) { model.open(.agentSkills, item: skill.name) }
                    .settingsAnchor(skill.name == shelf.yours.first?.name ? "skills-yours" : "skill-" + skill.name)
            }
            if shelf.yours.isEmpty {
                Text("No skills of your own yet")
                    .foregroundStyle(.secondary)
            }
        } header: {
            HStack(spacing: 8) {
                Text("Yours")
                Spacer()
                Button("New Skill…") { SkillAsk.new(model) }
                    .settingsButton()
            }
            .textCase(nil)
            .settingsAnchor("skills-new")
        } footer: {
            SettingsNote("Custom skills override built-in skills with the same name. Right-click to show in Finder.")
        }
        Section {
            ForEach(shelf.builtIn, id: \.name) { skill in
                SkillRow(skill: skill) { model.open(.agentSkills, item: skill.name) }
                    .settingsAnchor(skill.name == shelf.builtIn.first?.name ? "skills-built-in" : "skill-" + skill.name)
            }
        } header: {
            Text("Built In").foregroundStyle(.secondary)
        }
    }
}

/// The mark of the site a skill is for: its icon once there is one, its
/// first letter until then, as the other tables of sites show them.
struct SkillMark: View {
    let skill: Skills.Skill
    var size: CGFloat = 16
    @State private var icon: NSImage?
    @Environment(\.colorScheme) private var scheme

    private var host: String? { skill.sites.first.map(SkillFiles.host) }

    var body: some View {
        Mark(icon: icon, letter: skill.name.first.map { String($0).uppercased() } ?? "", size: size)
            .background {
                if let icon, scheme == .dark, ActionIcons.inky(icon) {
                    RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                        .fill(Color.white.opacity(0.9))
                }
            }
            .task {
                guard let host else { return }
                icon = Favicons.shared.cached(host)
                guard icon == nil else { return }
                Favicons.shared.fetch(host: host)
                // Once it has come: a slow front page took longer than one
                // look 1.5 s on, and the letter stayed.
                for _ in 0..<6 where icon == nil {
                    try? await Task.sleep(for: .seconds(1.5))
                    icon = Favicons.shared.cached(host)
                }
            }
    }
}

/// One skill: the site's mark, its name, its sites, and its ⌘J actions
/// counted at the end; its page on a click.
private struct SkillRow: View {
    let skill: Skills.Skill
    let open: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 9) { // design: the same gap as Search's site rows, which this table matches
                SkillMark(skill: skill)
                Text(skill.name).lineLimit(1)
                Text(skill.sites.joined(separator: ", "))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            let actions = SkillFiles.actions(skill.actions.count)
            if !actions.isEmpty {
                Text(actions)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            SettingsChevron()
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .contextMenu {
            Button("Show in Finder") { SkillShelf.shared.showInFinder(skill) }
            if skill.own {
                Divider()
                Button("Delete…") { SkillAsk.delete(skill) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens \(skill.name)")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - one skill

/// A skill's own page: what it is for, where, the words that call for it,
/// its actions and reads, and the page itself; yours to change here.
private struct SkillPage: View {
    let name: String
    var model: SettingsModel
    private var shelf = SkillShelf.shared
    private var askKey = Keymap.shared.slot(.agentAsk)

    @State private var text: String
    @State private var trouble: String?
    @State private var pending: DispatchWorkItem?

    init(name: String, model: SettingsModel) {
        self.name = name
        self.model = model
        let skill = SkillShelf.shared.skill(name) ?? Skills.named(name)
        _text = State(initialValue: skill.map(Self.shown) ?? "")
    }

    /// Yours whole, frontmatter and all, to change; a built-in one's page
    /// alone, to read.
    private static func shown(_ skill: Skills.Skill) -> String {
        skill.own ? ((try? String(contentsOf: skill.path, encoding: .utf8)) ?? skill.body) : skill.body
    }

    var body: some View {
        if let skill = shelf.skill(name) {
            hero(skill)
            about(skill)
            if !skill.actions.isEmpty {
                Section {
                    ForEach(Array(skill.actions.enumerated()), id: \.offset) { _, action in
                        HStack(spacing: 12) {
                            Text(action.title)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(action.draft.map { "Drafts, then \($0.verb)" } ?? action.pattern)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .pointerTip(action.prompt)
                    }
                } header: {
                    Text("Actions").foregroundStyle(.secondary)
                } footer: {
                    SettingsNote("Actions available on this site's pages with \(askKey.keys?.settingsHint ?? "the assigned shortcut").")
                }
            }
            if !skill.reads.isEmpty {
                Section {
                    ForEach(Array(skill.reads.enumerated()), id: \.offset) { _, read in
                        HStack(spacing: 12) {
                            Text(read.method + " " + read.pattern)
                                .font(.system(size: 12, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(read.note)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                } header: {
                    Text("Reads").foregroundStyle(.secondary)
                } footer: {
                    SettingsNote("URLs agents can read without opening a tab.")
                }
            }
            page(skill)
            doing(skill)
        } else {
            Section { SettingsNote("This skill is gone.") }
        }
    }

    private func hero(_ skill: Skills.Skill) -> some View {
        Section {} header: {
            VStack(spacing: 0) {
                SkillMark(skill: skill, size: 56)
                    .padding(.bottom, 12)
                Text(skill.name)
                    .font(.system(size: 22, weight: .bold))
                    .lineLimit(1)
                if !skill.description.isEmpty {
                    Text(skill.description)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 5) // design: PageHero's gap under the name
                        .padding(.horizontal, 24)
                }
            }
            .foregroundStyle(.primary)
            .textCase(nil)
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
            .padding(.bottom, 18) // design: PageHero's air above the first group
            .accessibilityElement(children: .combine)
        }
    }

    private func about(_ skill: Skills.Skill) -> some View {
        Section {
            SettingsRow("Sites", detail: skill.sites.isEmpty ? "Any site. Loaded when matching keywords appear." : skill.sites.joined(separator: ", ")) {
                EmptyView()
            }
            if !skill.keywords.isEmpty {
                SettingsRow("Words", detail: skill.keywords.joined(separator: ", ")) {
                    EmptyView()
                }
            }
            SettingsRow("Kind", detail: skill.own ? "Custom skill in your skills folder." : "Built-in skill.") {
                Text(skill.own ? "Yours" : "Built In").foregroundStyle(.secondary)
            }
        }
    }

    private func page(_ skill: Skills.Skill) -> some View {
        Section {
            if skill.own {
                ThreadTextEditor(text: $text)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 260)
                    .accessibilityLabel("SKILL.md")
                    .onChange(of: text) { _, _ in keepSoon(skill) }
                    .onDisappear { keep(skill) }
                    .settingsAnchor("skill-text")
            } else {
                ThreadScrollView {
                    Text(text)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 260)
            }
        } header: {
            Text("Page").foregroundStyle(.secondary)
        } footer: {
            if let trouble {
                Text(trouble)
                    .font(.callout)
                    .foregroundStyle(ButtonCSS.danger)
            } else {
                SettingsNote(skill.own
                    ? "Markdown, as SKILL.md. What you change is kept as you type, and agents read it from their next task."
                    : "Duplicate it to change it: the copy is yours, and wins over this one.")
            }
        }
    }

    @ViewBuilder
    private func doing(_ skill: Skills.Skill) -> some View {
        Section {
            if !skill.own {
                SettingsRow("Duplicate to Edit", detail: "Create an editable copy that overrides the built-in skill.") {
                    Button("Duplicate") {
                        guard shelf.duplicate(skill), let copy = shelf.skill(skill.name) else { return }
                        text = Self.shown(copy)
                    }
                    .settingsButton()
                }
                .settingsAnchor("skill-duplicate")
            }
            SettingsRow("Show in Finder", detail: skill.own ? skill.path.deletingLastPathComponent().lastPathComponent + "/SKILL.md" : "Inside Yab") {
                Button("Show in Finder") { shelf.showInFinder(skill) }
                    .settingsButton()
            }
            if skill.own {
                SettingsRow("Delete", detail: "Delete the skill folder from this Mac.") {
                    Button("Delete…") {
                        keep(skill)
                        SkillAsk.delete(skill) { model.leave(name, to: .agentSkills) }
                    }
                    .buttonStyle(.yab(.secondary, .regular, tint: ButtonCSS.danger))
                }
                .settingsAnchor("skill-delete")
            }
        }
    }

    private func keepSoon(_ skill: Skills.Skill) {
        pending?.cancel()
        let work = DispatchWorkItem { keep(skill) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func keep(_ skill: Skills.Skill) {
        pending?.cancel()
        pending = nil
        guard skill.own, text != Self.shown(skill) else { return }
        trouble = shelf.save(skill, text: text)
    }
}
