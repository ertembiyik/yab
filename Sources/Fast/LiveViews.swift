import SwiftUI

// What a live folder draws (Live.swift, LiveFolders.swift): a word at the
// end of each tab it holds, a word on its own row when it can't read or more
// wait than come out, and its menu.

/// At the end of a live folder's tab: what it needs, the first that
/// applies. Nothing when nothing does: the quiet row is the all clear.
struct LiveWordsView: View {
    var tab: Tab
    /// The same occupied end slot the title leaves clear, now outside
    /// the status text too; no room is taken when there are no words.
    var clearance: CGFloat = 0
    @Environment(\.tone) private var tone

    static func hasWords(_ tab: Tab) -> Bool { tab.live?.said != nil || tab.live?.words != nil }

    var body: some View {
        if let said = tab.live?.said {
            // A routine's folder's own words: loud in ink, the rest faint.
            Text(said.text)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(said.loud && !said.gone ? Palette.ink : Palette.faint(on: tone))
                .lineLimit(1)
                .fixedSize()
                .accessibilityLabel(said.text)
                .padding(.trailing, clearance)
        } else if let words = tab.live?.words {
            Text(words.text)
                .font(.system(size: 11))
                .foregroundStyle(words.needsYou ? Palette.ink : Palette.faint(on: tone))
                .lineLimit(1)
                .fixedSize()
                .accessibilityLabel(words.text)
                .padding(.trailing, clearance)
        }
    }
}

/// Beside a live folder's name: "Sign in" when its site answered with its
/// sign-in page, a click away; "5 need you" when more wait than come out
/// from under it shut; else nothing.
struct LiveNestWords: View {
    var browser: Browser
    var nest: Nest
    private var live = LiveFolders.shared
    /// Live Folders off: the folder says so, its tabs kept as they were.
    private var prefs: Preferences
    @Environment(\.tone) private var tone

    init(browser: Browser, nest: Nest) {
        self.browser = browser
        self.nest = nest
        self.prefs = browser.prefs
    }

    var body: some View {
        if let source = nest.live {
            if !prefs.usesLiveFolders {
                Text("Paused")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.faint(on: tone))
                    .lineLimit(1)
                    .fixedSize()
            } else if live.checking(nest) {
                // Its routine is looking: said on its own row, nowhere else.
                Text("Checking")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.faint(on: tone))
                    .lineLimit(1)
                    .fixedSize()
            } else if !nest.open, source.source == "routine", case let waiting = LiveFolders.waiting(nest, in: browser), waiting > 0 {
                // Words, no count: a folder never says how many tabs.
                Text("New")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .fixedSize()
            } else if live.states[nest.id]?.signedOut == true {
                Button {
                    if let url = LiveSource.of(source.source)?.signIn(source) { browser.arrive(url) }
                } label: {
                    Text("Sign in")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.ink)
                        .fixedSize()
                }
                .buttonStyle(.plain)
                .keyTip("Sign in to \(LiveSource.of(source.source)?.service ?? source.host)")
            } else if !nest.open, case let waiting = LiveFolders.waiting(nest, in: browser), waiting > 3 {
                Text("\(waiting) need you")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }
}

/// A live folder's own lines in its menu: which of the source's lists it
/// shows, which repositories or workspaces, reading now, the site, and
/// stopping.
struct LiveNestMenu: View {
    var browser: Browser
    var nest: Nest

    var body: some View {
        if let live = nest.live, let source = LiveSource.of(live.source) {
            if !browser.prefs.usesLiveFolders {
                Button("Turn On Live Folders…", mark: "yab.folder.bolt") { SettingsWindow.shared.showLiveFolder(nest, for: browser) }
            } else {
                Button("Update Now", mark: "yab.folder.refresh") { LiveFolders.shared.read(nest, in: browser) }
                if let page = source.page(live) {
                    Button("Open \(page.host()?.replacingOccurrences(of: "www.", with: "") ?? source.name)", mark: "yab.arrowout") { browser.arrive(page) }
                }
                if !source.lists.isEmpty {
                    Menu("Show", mark: "yab.eye") {
                        ForEach(source.lists, id: \.id) { list in
                            Toggle(list.title, isOn: Binding(
                                get: { live.shown.contains(list.id) },
                                set: { on in
                                    var changed = live
                                    changed.show = on ? source.lists.map(\.id).filter { live.shown.contains($0) || $0 == list.id }
                                                      : live.shown.filter { $0 != list.id }
                                    guard !changed.show.isEmpty else { return }
                                    nest.live = changed
                                    LiveFolders.shared.changed(nest, in: browser)
                                }
                            ))
                        }
                    }
                }
                let groups = source.id == "github.pulls" || source.id == "github.issues" || source.id == "linear"
                    ? Set(browser.tabs.filter { $0.nest === nest }.compactMap { Self.group($0.address, source: source.id) }).union(live.hidden).sorted() : []
                if !groups.isEmpty {
                    Menu(source.id == "linear" ? "Workspaces" : "Repositories", mark: "yab.list") {
                        ForEach(groups, id: \.self) { group in
                            Toggle(group, isOn: Binding(
                                get: { !live.hidden.contains(group) },
                                set: { on in
                                    var changed = live
                                    if on { changed.hidden.removeAll { $0 == group } } else { changed.hidden.append(group) }
                                    nest.live = changed
                                    LiveFolders.shared.changed(nest, in: browser)
                                }
                            ))
                        }
                    }
                }
                if live.source == "routine", let routine = Routines.shared.all.first(where: { $0.id == live.host }) {
                    Button("Edit Routine…", mark: "yab.clock.pen") { SettingsWindow.shared.showRoutine(routine, for: browser) }
                }
                Button("Live Folder Settings…", mark: "gearshape") { SettingsWindow.shared.showLiveFolder(nest, for: browser) }
            }
        }
    }

    /// The folder stays, a plain one, its tabs in it: among what is done
    /// with the folder and its tabs, at the menu's foot.
    static func stop(_ nest: Nest, in browser: Browser) {
        if nest.live?.source == "routine", let id = nest.live?.host { Routines.shared.stopKeeping(id) }
        LiveFolders.shared.stop(nest, in: browser)
    }

    /// "owner/name" from a pull request's address; a Linear workspace's
    /// word from an issue's.
    static func group(_ url: URL?, source: String = "github.pulls") -> String? {
        guard let parts = url?.path.split(separator: "/"), parts.count >= 2 else { return nil }
        return source == "linear" ? String(parts[0]) : "\(parts[0])/\(parts[1])"
    }
}
