import AppKit
import SwiftUI

/// A list entry can come from an unopened space's session. Opening it
/// switches to that space first, so edits always use its real Nest and cookies.
struct LiveFolderSummary: Identifiable {
    let id: UUID
    let space: UUID
    var name: String
    let live: Live
    var count: Int

    @MainActor
    static func all(in browser: Browser) -> [LiveFolderSummary] {
        browser.spaces.flatMap { space -> [LiveFolderSummary] in
            var entries: [LiveFolderSummary] = []
            func add(_ id: UUID, _ name: String, _ live: Live, count: Int) {
                if let index = entries.firstIndex(where: { $0.id == id }) {
                    entries[index].count += count
                } else {
                    entries.append(LiveFolderSummary(id: id, space: space.id, name: name, live: live, count: count))
                }
            }
            if space.id == browser.spaceID || browser.parked[space.id] != nil {
                let tabs = space.id == browser.spaceID ? browser.tabs : browser.parked[space.id]?.tabs ?? []
                for tab in tabs where tab.kept {
                    if let nest = tab.nest, let live = nest.live { add(nest.id, nest.name, live, count: 1) }
                }
            } else {
                for entry in Session.read(space: space.id, window: browser.windowID).tabs {
                    if let folder = entry.folder, let id = UUID(uuidString: folder), let live = entry.folderLive {
                        add(id, entry.folderName ?? "Folder", live, count: 1)
                    }
                }
            }
            for nest in Folders.shared.empties(in: space.id) {
                if let live = nest.live { add(nest.id, nest.name, live, count: 0) }
            }
            return entries
        }
    }
}

/// The site a folder's tabs come from, for its mark: GitHub for a search
/// or a repository, nil for a routine's.
private func siteHost(_ live: Live) -> String? {
    if let git = LiveGitService.of(live.source) { return git.repository(live.host)?.host() }
    // An Enterprise server's own name, or github.com; the address's host
    // when the folder was made from one.
    if live.source.hasPrefix("github.") { return URL(string: LiveGitHub.base(live.host))?.host() ?? "github.com" }
    guard let source = LiveSource.of(live.source), !source.site.isEmpty else { return nil }
    return source.site
}

private func tabs(_ count: Int) -> String { count == 1 ? "1 tab" : "\(count) tabs" }

/// Settings › Live Folders: off, an introduction; on, your folders, then
/// what you could add, the sources your history goes to most first; a
/// folder further in, its own page.
struct LiveFoldersSettings: View {
    var browser: Browser
    var prefs: Preferences
    var model: SettingsModel
    private var live = LiveFolders.shared
    private var folders = Folders.shared
    @State private var entries: [LiveFolderSummary] = []
    /// Read from history once the page is on, never before.
    @State private var visits: [(url: String, count: Int)]?
    @State private var uses: [LiveSuggest.Use] = []
    /// Just added: washed for a moment, as a space just made is.
    @State private var made: UUID?
    @State private var pickingRepo = false

    private var opened: Nest? {
        guard let id = model.opened.flatMap(UUID.init(uuidString:)) else { return nil }
        return LiveFolders.nests(in: browser).first { $0.id == id }
    }

    var body: some View {
        Group {
            if !prefs.usesLiveFolders {
                LiveFoldersArrival(paused: entries.count) { prefs.usesLiveFolders = true }
            } else if let nest = opened {
                ThreadForm {
                    LiveFolderDetail(browser: browser, nest: nest, model: model) { added in
                        reload()
                        flash(added)
                    }
                }
                .formStyle(.grouped)
                .id(nest.id)
            } else {
                list
            }
        }
        .onAppear { reload() }
        .onReceive(browser.changes(\.tabs)) { _ in DispatchQueue.main.async { reload() } }
        .onReceive(browser.changes(\.spaceID)) { _ in DispatchQueue.main.async { reload() } }
        .onChange(of: folders.empties.map(\.id)) { _, _ in reload() }
        .onChange(of: live.states) { _, _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: Session.written)) { _ in reload() }
        .onChange(of: model.opened) { _, _ in reload() }
        .onChange(of: prefs.usesLiveFolders) { _, _ in reload() }
    }

    private func reload() {
        entries = LiveFolderSummary.all(in: browser)
        guard prefs.usesLiveFolders else { return }
        if visits == nil { visits = LiveSuggest.visits() }
        // Repositories this space already follows aren't offered again
        // inside GitHub's pull requests.
        let followed = Set(entries.filter { $0.space == browser.spaceID }.compactMap(\.live.followed))
        uses = LiveSuggest.uses(visits ?? [], followed: followed)
    }

    private func flash(_ id: UUID?) {
        made = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { if made == id { made = nil } }
    }

    // MARK: the list

    /// The sources not yet in a folder of this space, the ones history goes
    /// to most first.
    private var left: [LiveSource] {
        let have = Set(entries.filter { $0.space == browser.spaceID }.map(\.live.source))
        return LiveSource.all.filter { LiveSuggest.offered($0.id) && !have.contains($0.id) }
    }

    private func use(_ source: LiveSource) -> LiveSuggest.Use? { uses.first { $0.source == source.id } }

    private var list: some View {
        let used = left.filter { (use($0)?.visits ?? 0) >= LiveSuggest.enough }
            .sorted { (use($0)?.visits ?? 0) > (use($1)?.visits ?? 0) }
        let usedIDs = Set(used.map(\.id))
        let rest = left.filter { !usedIDs.contains($0.id) }
        // No folder yet: the first list of sites says what to do with it.
        let step = "Pick a site and click Add"
        let lands = "Its folder shows up in your sidebar and fills in while you\u{2019}re signed in to that site in this space."
        return ThreadForm {
            PageHero(page: .liveFolders)
                .settingsAnchor("live-folders")
            let spaces = browser.spaces.filter { space in entries.contains { $0.space == space.id } }
            ForEach(spaces) { space in
                let rows = entries.filter { $0.space == space.id }
                Section {
                    LiveFolderList(browser: browser, entries: rows, made: made, open: open)
                        // The form's inset round a cell traded for the
                        // list's own air, as the spaces' list does.
                        .padding(.vertical, SettingsList.air - 10) // design: the form's own inset round a cell, traded for the list's air
                        .disabled(space.id != browser.spaceID && !prefs.usesSpaces)
                } header: {
                    if spaces.count > 1 { Text(space.name) }
                }
            }
            if !used.isEmpty {
                Section {
                    ForEach(Array(used.enumerated()), id: \.element.id) { index, source in
                        LiveSourceRow(source: source, detail: usedDetail(source), primary: index == 0) { add(source) }
                    }
                } header: {
                    Text(entries.isEmpty ? step : "From your history")
                } footer: {
                    SettingsNote(entries.isEmpty ? "The sites you opened most in the last 30 days, on this Mac. " + lands
                                                 : "The sites you opened most in the last 30 days, on this Mac.")
                }
            }
            Section {
                ForEach(rest, id: \.id) { source in
                    LiveSourceRow(source: source, detail: Self.what(source.id), primary: false) { add(source) }
                }
                LiveRepoRow(browser: browser, picking: $pickingRepo, title: "A GitHub Repository…",
                            detail: "Follow all open pull requests in a repository.") { flash($0) }
                FeatureRow("Ask an Agent…", icon: SettingsPage.agentRoutines.icon, tint: .systemPink,
                           detail: "Describe a folder for a routine to keep updated.", open: askAgent) {
                    SettingsChevron()
                }
                .settingsAnchor("live-folders-add")
            } header: {
                Text(used.isEmpty && entries.isEmpty ? step : "More sources")
            } footer: {
                SettingsNote(used.isEmpty && entries.isEmpty ? lands
                                                             : "Each folder uses the sign-ins of its space and updates while that space is open.")
            }
            if !prefs.usesSpaces, entries.contains(where: { $0.space != browser.spaceID }) {
                Section {
                    FeatureRow(.spaces, detail: "Turn on Spaces to manage folders kept in your other spaces.", model: model)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func usedDetail(_ source: LiveSource) -> String {
        guard let use = use(source) else { return Self.what(source.id) }
        return ([use.visits == 1 ? "1 visit" : "\(use.visits) visits"] + use.groups.prefix(2)).joined(separator: " · ")
    }

    /// What each source brings, in a line.
    static func what(_ id: String) -> String {
        switch id {
        case "github.pulls": return "Reviews asked of you and your open pull requests"
        case "github.issues": return "Issues assigned to you or mentioning you"
        case "linear": return "Issues assigned to you"
        case "notion": return "Mentions and pages changed by others"
        case "drive": return "Shared with you and changed since you looked"
        case "figma": return "Comments and files changed by others"
        case "youtube": return "New videos from channels you follow"
        default: return ""
        }
    }

    private func add(_ source: LiveSource) {
        let nest = LiveFolders.shared.make(source.id, in: browser)
        if nest == nil { browser.announce("Open this space first, then try again", mark: "folder", on: SettingsWindow.shared.toaster) }
        reload()
        flash(nest?.id)
    }

    private func askAgent() {
        var routine = Routine(id: Routines.newID("folder"), when: "daily 9:00", prompt: "", last: nil, title: "Folder")
        routine.folder = true
        routine.space = browser.spaceID
        SettingsWindow.shared.showRoutine(routine, for: browser, fresh: true)
    }

    private func open(_ entry: LiveFolderSummary) {
        if browser.spaceID != entry.space { browser.switchSpace(to: entry.space) }
        model.open(.liveFolders, item: entry.id.uuidString)
    }
}

// MARK: - the folders

/// Your folders, a row each as the spaces' list has them: the site's mark
/// on its plate, the name, how many tabs, and only what needs doing.
private struct LiveFolderList: View {
    var browser: Browser
    let entries: [LiveFolderSummary]
    let made: UUID?
    let open: (LiveFolderSummary) -> Void
    private var live = LiveFolders.shared

    static let row = SettingsList.row

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                row(entry)
                    .overlay(alignment: .top) { if index > 0 { Divider().offset(y: -0.5) } }
            }
        }
    }

    private func row(_ entry: LiveFolderSummary) -> some View {
        let state = live.states[entry.id]
        return HStack(spacing: 8) {
            LiveSourceMark(live: entry.live, side: 22)
            Text(entry.name).lineLimit(1)
            Text(tabs(entry.count))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if live.reading.contains(entry.id) && state?.read == nil {
                Text(SettingsWords.text("Checking…")).font(.callout).foregroundStyle(.secondary)
            } else if state?.signedOut == true, let url = LiveSource.of(entry.live.source)?.signIn(entry.live) {
                Button("Sign In…") { browser.arrive(url) }
                    .buttonStyle(.yab(.secondary, .small))
            } else if state?.failures ?? 0 > 0 {
                Text("Couldn’t update").font(.callout).foregroundStyle(.secondary)
            }
            SettingsChevron()
        }
        .frame(height: Self.row)
        .contentShape(Rectangle())
        .onTapGesture { open(entry) }
        .background {
            // As SettingsAnchor washes a row the search picked out.
            RoundedRectangle(cornerRadius: 7, style: .continuous) // design: SettingsAnchor's wash, seven round inside the card's ten
                .fill(Color(nsColor: .unemphasizedSelectedContentBackgroundColor))
                .padding(.horizontal, -7) // design: SettingsAnchor's wash, out to the row's edges less three
                .opacity(made == entry.id ? 1 : 0)
                .animation(.easeOut(duration: made == entry.id ? 0.12 : 0.5), value: made == entry.id)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entry.name)
        .accessibilityHint("Opens \(entry.name)")
        .accessibilityAddTraits(.isButton)
    }
}

/// A folder's mark: its site's icon on a plate, a routine's tile.
private struct LiveSourceMark: View {
    let live: Live
    let side: CGFloat

    var body: some View {
        if let host = siteHost(live) {
            SiteMark(host: host, size: side * 0.64)
                .frame(width: side, height: side)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
                .onAppear { if SiteMark.icon(host) == nil { Favicons.shared.fetch(host: host) } }
        } else {
            PenTileView(page: .agentRoutines, side: side).frame(width: side, height: side)
        }
    }
}

/// A site on the pen tiles' paper: the sources' rows and a folder's page.
private struct SiteTile: View {
    let host: String
    let side: CGFloat
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: side * 0.25, style: .continuous) // design: a pen tile's corner (PenArt.draw)
        SiteMark(host: host, size: side * 0.5)
            .frame(width: side, height: side)
            .background(Color(nsColor: PenArt.paper(dark: scheme == .dark)), in: shape)
            .overlay(shape.strokeBorder(Color(nsColor: PenArt.rim(dark: scheme == .dark)), lineWidth: max(0.5, side / 56)))
            .onAppear { if SiteMark.icon(host) == nil { Favicons.shared.fetch(host: host) } }
            .accessibilityHidden(true)
    }
}

// MARK: - the sources

/// One source to add, as Bring In lists the browsers: its site, what it
/// brings, and Add, the one used most in black.
private struct LiveSourceRow: View {
    let source: LiveSource
    let detail: String
    let primary: Bool
    let add: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            SiteTile(host: source.site, side: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.title)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(SettingsWords.text("Add"), action: add)
                .settingsButton(primary ? .primary : .secondary)
                .accessibilityLabel("Add \(source.title)")
        }
    }
}

/// Follow a repository: the row, and the popover that takes it, the ones
/// opened most from history and any typed.
private struct LiveRepoRow: View {
    var browser: Browser
    @Binding var picking: Bool
    let title: String
    let detail: String
    let added: (UUID?) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            SiteTile(host: "github.com", side: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Add…") { picking = true }
                .settingsButton()
                .popover(isPresented: $picking, arrowEdge: .bottom) {
                    RepoPicker(browser: browser) { nest in
                        picking = false
                        added(nest?.id)
                    }
                }
        }
        .settingsAnchor("live-folders-repo")
    }
}

/// The repositories to follow: a field for owner/name or an address, and
/// under it the ones this Mac opened most.
private struct RepoPicker: View {
    var browser: Browser
    var issuesIn: Nest? = nil
    let done: (Nest?) -> Void
    @State private var typed = ""
    @State private var lit = 0
    @State private var known: [(name: String, visits: Int)] = []
    @FocusState private var focused: Bool

    /// What Return takes: a repository typed that history doesn't have
    /// first, then the history's, as far as the words narrow it.
    private var rows: [(name: String, visits: Int?)] {
        let words = typed.trimmingCharacters(in: .whitespaces).lowercased()
        let following = Set(LiveFolders.nests(in: browser).compactMap { $0.live?.query })
        let found = known.filter { row in
            if let issuesIn { return issuesIn.live?.issueRepositories.contains(where: { $0.lowercased() == row.name.lowercased() }) != true }
            return !following.contains("is:pr is:open repo:\(row.name)")
        }
            .filter { words.isEmpty || $0.name.lowercased().contains(words) }
            .prefix(6).map { (name: $0.name, visits: Optional($0.visits)) }
        if let full = LiveFolders.repo(typed), !found.contains(where: { $0.name.lowercased() == full.lowercased() }) {
            return [(full, nil)] + found
        }
        return Array(found)
    }

    var body: some View {
        let rows = rows
        VStack(alignment: .leading, spacing: 4) {
            TextField("owner/repo or a github.com link", text: $typed)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { if rows.indices.contains(lit) { take(rows[lit].name) } }
                .onChange(of: typed) { _, _ in lit = 0 }
                .onKeyPress(.downArrow) { lit = min(lit + 1, max(rows.count - 1, 0)); return .handled }
                .onKeyPress(.upArrow) { lit = max(lit - 1, 0); return .handled }
            if !known.isEmpty, typed.isEmpty {
                Text("From your history")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.top, 4)
            }
            ForEach(Array(rows.enumerated()), id: \.element.name) { index, row in
                Button { take(row.name) } label: {
                    HStack(spacing: 8) {
                        SiteMark(host: "github.com", size: 14)
                        Text(row.name).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(row.visits.map { $0 == 1 ? "1 visit" : "\($0) visits" } ?? "Follow")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 6)
                    .frame(height: 28)
                    .background(index == lit ? Palette.wash : .clear, in: RoundedRectangle(cornerRadius: Radius.small + 1, style: .continuous)) // design: a list row's wash inside the popover's 6
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { if $0 { lit = index } }
            }
        }
        .padding(8)
        .frame(width: 320)
        .onAppear {
            known = LiveSuggest.repos()
            focused = true
        }
    }

    private func take(_ name: String) {
        done(LiveFolders.shared.followRepo(name, in: browser, issuesIn: issuesIn))
    }
}

// MARK: - off

/// The same centered introduction as Spaces and Sync. Nothing is read,
/// history neither, before the person turns it on.
private struct LiveFoldersArrival: View {
    /// Folders already kept, waiting with their tabs.
    let paused: Int
    let start: () -> Void

    private static let shown: [(host: String, name: String)] = [
        ("github.com", "GitHub"), ("linear.app", "Linear"), ("notion.so", "Notion"),
        ("figma.com", "Figma"), ("drive.google.com", "Drive"), ("youtube.com", "YouTube"),
    ]

    var body: some View {
        ArrivalPage(page: .liveFolders, title: "Live Folders",
                    blurb: paused > 0
                           ? (paused == 1 ? "Your folder is paused, with its tabs. Turn on to bring it up to date."
                                          : "Your \(paused) folders are paused, with all their tabs. Turn on to bring them up to date.")
                           : "Folders in your sidebar that keep up with your sites. New pull requests, issues and shared files come in, and finished ones leave.") {
            if paused == 0 {
                HStack(spacing: 6) {
                    ForEach(Self.shown, id: \.name) { site in
                        HStack(spacing: 6) {
                            SiteMark(host: site.host, size: 14)
                                .onAppear { if SiteMark.icon(site.host) == nil { Favicons.shared.fetch(host: site.host) } }
                            Text(site.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        }
                        .padding(.horizontal, 8)
                        .frame(height: Door.side)
                        .background(Palette.wash, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    }
                }
                .padding(.top, 16)
                .accessibilityHidden(true)
            }
            Button("Turn On Live Folders", action: start)
                .buttonStyle(.yab(.primary, .large))
                .padding(.top, 20)
                .settingsAnchor("live-folders-add")
            if paused == 0 {
                Text("Click Add beside a site. Suggestions use browsing history stored on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 360)
                    .padding(.top, 12)
            }
        }
        .settingsAnchor("live-folders")
    }
}

// MARK: - one folder

/// A folder's own page, as a space's: its mark and name on top with one
/// line of facts, what needs doing first, then what it shows, and at the
/// foot stopping.
private struct LiveFolderDetail: View {
    var browser: Browser
    @Bindable var nest: Nest
    var model: SettingsModel
    /// A repository followed from here: the list shows its new folder.
    let added: (UUID?) -> Void
    private var folders = LiveFolders.shared
    @State private var pickingRepo = false

    private var source: LiveSource? { nest.live.flatMap { LiveSource.of($0.source) } }
    private var count: Int { browser.tabs.filter { $0.nest === nest }.count }
    private var state: LiveFolders.State? { folders.states[nest.id] }
    private var groups: [String] {
        guard let live = nest.live, live.source == "github.pulls" || live.source == "github.issues" || live.source == "linear" else { return [] }
        return Set(browser.tabs.filter { $0.nest === nest }.compactMap { LiveNestMenu.group($0.address, source: live.source) })
            .union(live.hidden).union(live.issueRepositories).sorted()
    }

    var body: some View {
        if let live = nest.live, let source {
            hero(live, source)
            if state?.signedOut == true, let url = source.signIn(live) {
                Section {
                    SettingsRow("Signed out of \(source.service)",
                                detail: count == 0 ? "Sign in to \(source.service) in this space, and its items come in."
                                                   : "Your \(count == 1 ? "tab is" : "\(count) tabs are") kept. Updates come back once you sign in.") {
                        Button("Sign In…") { browser.arrive(url) }.settingsButton(.primary)
                    }
                }
            } else if state?.failures ?? 0 > 0 {
                Section {
                    SettingsRow("Couldn’t update", detail: "Existing tabs are kept. Updates retry automatically.") {
                        Button("Try Again") { folders.read(nest, in: browser) }.settingsButton()
                    }
                }
            }
            Section {
                SettingsRow("Name") {
                    TextField(SettingsWords.text("Name"), text: $nest.name)
                        .labelsHidden()
                        .frame(width: 180)
                        .onChange(of: nest.name) { _, _ in save() }
                }
            }
            if !source.lists.isEmpty {
                Section("Show") {
                    ForEach(source.lists, id: \.id) { list in
                        SettingsSwitch(list.title, isOn: Binding(
                            get: { nest.live?.show.contains(list.id) == true },
                            set: { on in
                                guard var value = nest.live else { return }
                                value.show = on ? source.lists.map(\.id).filter { value.show.contains($0) || $0 == list.id }
                                                : value.show.filter { $0 != list.id }
                                guard !value.show.isEmpty else { return }
                                nest.live = value
                                folders.changed(nest, in: browser)
                            }
                        ))
                        // The last one on stays on: a folder shows something.
                        .disabled(live.show == [list.id])
                    }
                }
            }
            if live.followed != nil {
                Section {
                    MenuRow("Pull Requests", options: [("Active Today", 1), ("Active This Week", 7), ("Active This Month", 30), ("All Open", 0)],
                            selection: Binding(
                                get: { nest.live?.days ?? 7 },
                                set: { days in
                                    guard var value = nest.live else { return }
                                    value.days = days
                                    nest.live = value
                                    folders.changed(nest, in: browser)
                                }
                            ))
                } footer: {
                    SettingsNote("Include pull requests updated within this period.")
                }
            }
            let github = live.source == "github.pulls" || live.source == "github.issues"
            if !groups.isEmpty || github {
                Section {
                    ForEach(groups, id: \.self) { group in
                        SettingsSwitch(group, isOn: Binding(
                            get: { nest.live?.hidden.contains(group) != true },
                            set: { on in
                                guard var value = nest.live else { return }
                                if on { value.hidden.removeAll { $0 == group } } else { value.hidden.append(group) }
                                nest.live = value
                                folders.changed(nest, in: browser)
                            }
                        ))
                    }
                    if github { addRepository }
                } header: {
                    Text(live.source == "linear" ? "Workspaces" : "Repositories")
                } footer: {
                    if github {
                        SettingsNote(live.source == "github.issues"
                            ? "Your issues appear across repositories. Add a repository to include its open issues in this folder."
                            : "Your pull requests appear across repositories. Add a repository to follow all its pull requests from the last week.")
                    }
                }
            }
            if live.source == "routine", let routine = Routines.shared.all.first(where: { $0.id == live.host }) {
                Section {
                    SettingsRow("Kept by a routine", detail: routine.name) {
                        Button("Edit Routine…") { SettingsWindow.shared.showRoutine(routine, for: browser) }.settingsButton()
                    }
                }
            }
            Section {
                SettingsRow("Update Now", detail: every(source)) {
                    Button("Update Now") { folders.read(nest, in: browser) }
                        .settingsButton()
                        .disabled(folders.reading.contains(nest.id) || folders.checking(nest))
                }
            }
            Section {
                SettingsRow("Stop Updating", detail: "Its \(count == 1 ? "tab stays" : "\(count) tabs stay") in the sidebar, as a plain folder.") {
                    // The red of what can't be undone, on the wash, as a
                    // space's Delete… is.
                    Button("Stop Updating…", action: stop)
                        .buttonStyle(.yab(.secondary, .regular, tint: ButtonCSS.danger))
                }
            }
        }
    }

    /// Its mark, its name, and its facts in a line, as a space's page has.
    private func hero(_ live: Live, _ source: LiveSource) -> some View {
        let site = live.source == "github.search" ? live.query.flatMap { $0.components(separatedBy: "repo:").last }.map { "github.com/" + $0 } : siteHost(live)
        let when = folders.reading.contains(nest.id) || folders.checking(nest) ? "updating" : LiveFolders.updated(nest.key)?.lowercased()
        let words = [tabs(count), site, when].compactMap { $0 }.joined(separator: " · ")
        return Section {} header: {
            VStack(spacing: 0) {
                Group {
                    if let host = siteHost(live) {
                        SiteTile(host: host, side: 56)
                    } else {
                        PenTileView(page: .agentRoutines, side: 56).frame(width: 56, height: 56)
                    }
                }
                .padding(.bottom, 12)
                Text(nest.name)
                    .font(.system(size: 22, weight: .bold))
                    .lineLimit(1)
                Text(words)
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

    /// The way to a repository of its own, under the last, as Add Space is.
    private var addRepository: some View {
        Button { pickingRepo = true } label: {
            HStack(spacing: 8) {
                Symbol("plus", size: 11)
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
                Text("Add Repository…")
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $pickingRepo, arrowEdge: .bottom) {
            RepoPicker(browser: browser, issuesIn: nest.live?.source == "github.issues" ? nest : nil) { made in
                pickingRepo = false
                guard let made else { return }
                if made === nest { return }
                model.leave(nest.id.uuidString, to: .liveFolders)
                added(made.id)
            }
        }
        .settingsAnchor("live-folders-repo")
    }

    private func every(_ source: LiveSource) -> String {
        if nest.live?.source == "routine" { return "When its routine runs." }
        let minutes = Int(source.every / 60)
        return "On its own every \(minutes) minutes while \(browser.space.name) is open."
    }

    private func save() {
        Folders.shared.emptyChanged(nest)
        browser.writeSession(now: true)
    }

    private func stop() {
        let question = Question(title: "Stop updating “\(nest.name)”?",
                                detail: "Its \(count == 1 ? "tab stays" : "\(count) tabs stay") in \(browser.space.name), as a plain folder.",
                                glyph: "folder", yes: "Stop Updating", place: .settings)
        Task { @MainActor in
            guard await Questions.shared.ask(question) else { return }
            if nest.live?.source == "routine", let id = nest.live?.host { Routines.shared.stopKeeping(id) }
            folders.stop(nest, in: browser)
            model.leave(nest.id.uuidString, to: .liveFolders)
        }
    }
}
