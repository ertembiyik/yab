import AppKit
import Combine
import Foundation

// Live folders at work: when each is read, reading it, and what its answer
// does to the row. The rules the answer is held to are Live.swift's; the
// plan and the words are docs/live-folders.md.
//
// Read only in rows that are up: a space parked out of sight is read when
// it comes back. Never with no window (yab used from the terminal), with
// the Mac in Low Power Mode, or twice at once.

@MainActor
@Observable final class LiveFolders {
    static let shared = LiveFolders()

    /// How a folder's reading went, by its nest's id. Not saved: a launch
    /// reads again.
    struct State: Equatable {
        var read: Date?
        var signedOut = false
        /// Answers that didn't parse since the last good one.
        var failures = 0
    }

    private(set) var states: [UUID: State] = [:]
    /// Routines running now that keep a folder, by id: "Checking" on their
    /// folder's row, wherever that folder is.
    private(set) var checking: Set<String> = []
    /// What a routine's run handed its folder while the folder's space was
    /// out of sight, by routine: put in when that space is back.
    @ObservationIgnored private var pending: [String: [LiveItem]] = [:]
    /// What each routine's folder held when last seen, for a run told what
    /// it holds while its space is out of sight.
    @ObservationIgnored private var lastHeld: [String: [(url: String, title: String, said: String)]] = [:]
    /// Things hidden from a folder (Hide from Folder, or taken out of it),
    /// by nest, until what they say changes.
    @ObservationIgnored private var hidden: [UUID: [String: LiveWords?]] = LiveFolders.readKept().hidden
    /// What a new-for-you folder has shown, by nest: never brought twice.
    @ObservationIgnored private var shown: [UUID: Set<String>] = LiveFolders.readKept().shown
    private(set) var reading: Set<UUID> = []
    /// A read begun before an off/on must never apply after it.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var soon: DispatchWorkItem?
    @ObservationIgnored private var watches: [AnyCancellable] = []

    private init() {}

    func availabilityChanged() {
        generation += 1
        nudge(after: 0.2)
    }

    // MARK: when

    /// Started with the app: a look every half minute at which folders are
    /// due, and at once when the app comes back or the Mac wakes.
    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            MainActor.assumeIsolated { LiveFolders.shared.tick() }
        }
        timer?.tolerance = 5
        let center = NotificationCenter.default
        watches = [
            center.publisher(for: NSApplication.didBecomeActiveNotification).sink { _ in LiveFolders.shared.nudge(after: 2) },
            NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification).sink { _ in LiveFolders.shared.nudge(after: 10) },
        ]
        nudge(after: 10)
    }

    /// Every folder due, now, and the counts of pins whose site says one.
    func tick(force: Bool = false) {
        let span = MainBudget.begin("live.tick"); defer { span?.end() }
        guard !Headless.hidden, !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
        settle()
        for browser in BrowserWindows.shared.browsers {
            if browser.prefs.usesLiveFolders {
                // Routines keep their own schedule. Activation and the master
                // switch refresh site sources, never start an agent run.
                for nest in Self.nests(in: browser) where nest.live?.source != "routine" && (force || due(nest, in: browser)) {
                    read(nest, in: browser)
                }
            }
        }
        readCounts(force: force)
    }

    @ObservationIgnored private var countsRead = Date.distantPast

    /// A Gmail or Notion pin's count from the site, every minute while yab
    /// is in front, and when it comes back or the Mac wakes: what it shows
    /// asleep, when no page says it. Each is one small request; at five
    /// minutes the count moved only when its card was opened (#314).
    private func readCounts(force: Bool) {
        guard NSApp.isActive || force, Date().timeIntervalSince(countsRead) > (force ? 10 : 55) else { return }
        countsRead = Date()
        for browser in BrowserWindows.shared.browsers {
            let store = Spaces.store(for: browser.spaceID)
            for tab in browser.tabs where (tab.pin != nil || tab.kept) && Counts.shows(tab.address) {
                guard let host = tab.address?.host()?.lowercased() else { continue }
                if host == "mail.google.com" {
                    let account = LiveGmail.account(tab.address)
                    Task { @MainActor [weak tab] in
                        if let read = await LiveGmail.read(account: account, store: store) { tab?.sourced(read.count) }
                    }
                } else if host == "app.notion.com" || host.hasSuffix("notion.so") {
                    Task { @MainActor [weak tab] in
                        if let n = await LiveNotion.unreadCount(store: store) { tab?.sourced(n) }
                    }
                }
            }
        }
    }

    /// Read everything a little later: the app back, the Mac awake, or
    /// something just done on GitHub in a tab.
    func nudge(after seconds: TimeInterval) {
        soon?.cancel()
        let work = DispatchWorkItem { LiveFolders.shared.tick(force: true) }
        soon = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Every minute while it is open or its site is in front, its own
    /// while yab is (five minutes, thirty for a heavy page), fifteen or its
    /// own while yab isn't.
    private func due(_ nest: Nest, in browser: Browser) -> Bool {
        guard let live = nest.live, let source = LiveSource.of(live.source), live.source != "routine" else { return false }
        guard let read = states[nest.id]?.read else { return true }
        let host = browser.active?.address?.host()?.lowercased() ?? ""
        let front = !source.site.isEmpty && (host == source.site || host.hasSuffix("." + source.site) || host == live.host)
        let every: TimeInterval = !NSApp.isActive ? max(15 * 60, source.every) : (nest.open || front) ? max(60, source.every / 5) : source.every
        return Date().timeIntervalSince(read) >= every
    }

    // MARK: reading

    func read(_ nest: Nest, in browser: Browser) {
        guard browser.prefs.usesLiveFolders else { return }
        // A routine's folder is read by running the routine.
        if nest.live?.source == "routine" {
            if let routine = Routines.shared.all.first(where: { $0.id == nest.live?.host }) { Routines.shared.runNow(routine) }
            return
        }
        guard let live = nest.live, let source = LiveSource.of(live.source), !reading.contains(nest.id) else { return }
        reading.insert(nest.id)
        let generation = self.generation
        let space = browser.spaceID
        let store = Spaces.store(for: browser.spaceID)
        Task { @MainActor [weak browser] in
            defer { self.reading.remove(nest.id) }
            let result = await LiveSource.read(live, store: store)
            guard generation == self.generation, browser?.prefs.usesLiveFolders == true,
                  browser?.spaceID == space, nest.live == live else { return }
            var state = self.states[nest.id] ?? State()
            state.read = Date()
            switch result {
            case .signedOut:
                state.signedOut = true
                self.states[nest.id] = state
            case .failed:
                // The tabs stay as they were; read again at its next turn.
                state.failures += 1
                self.states[nest.id] = state
            case .items(let items):
                let first = self.states[nest.id]?.read == nil && self.shown[nest.id] == nil
                self.states[nest.id] = State(read: Date(), signedOut: false, failures: 0)
                guard let browser, nest.live != nil else { return }
                self.apply(items, to: nest, source: source, first: first, in: browser)
            }
        }
    }

    // MARK: the answer, in the row

    /// What the source listed, made so: new ones at the folder's top,
    /// asleep; done ones gone (to do) or opened a day ago (new for you),
    /// unless you're on them; words changed.
    @discardableResult
    func apply(_ items: [LiveItem], to nest: Nest, source: LiveSource? = nil, first: Bool = false,
               adoptingTaskTabs: Set<UUID> = [], in browser: Browser) -> LiveDiff {
        let span = MainBudget.begin("live.apply"); defer { span?.end() }
        let kind = source?.kind ?? .toDo
        let newsLists = source?.newsLists ?? []
        // What a source said of each thing, for any tab showing it (TabGist).
        if nest.live?.source != "routine" { LiveSeen.note(items, news: newsLists) }
        let members = browser.tabs.filter { $0.nest === nest }
        // A routine's folder knows any page; the sources, their own things.
        let keyOf: (URL?) -> String? = nest.live?.source == "routine" ? LiveFolder.page : LiveText.key
        let held = members.map { tab in
            let came = tab.live?.came
            let opened = came.flatMap { came in tab.touched.timeIntervalSince(came) > 2 ? tab.touched : nil }
            return LiveFolder.Held(id: tab.id, key: tab.live?.key ?? keyOf(tab.address), brought: tab.broughtByFolder,
                                   words: tab.live?.words, busy: busy(tab, in: browser), came: came, opened: opened, said: tab.live?.said,
                                   news: tab.live?.news == true)
        }
        var today: [String: UUID] = [:]
        var elsewhere = Set<String>()
        let routine = nest.live?.source == "routine"
        for tab in browser.tabs where tab.nest !== nest {
            // An agent's own tab, the run's looking, is no place a thing
            // already is: it closes when the run ends.
            if routine, tab.bench || tab.agent != nil {
                // Repeat may keep a completed chat's originals. Put only
                // those explicitly eligible pages in the reconciliation's
                // candidates; duplicate keys and pages kept elsewhere are
                // still decided by the ordinary diff before ownership moves.
                if adoptingTaskTabs.contains(tab.id), tab.pin == nil, !tab.kept, tab.nest == nil, !tab.shy,
                   let key = keyOf(tab.address) { today[key] = tab.id }
                continue
            }
            guard let key = keyOf(tab.address) else { continue }
            if tab.pin == nil, !tab.kept, tab.nest == nil, !tab.bench, !tab.shy { today[key] = tab.id } else { elsewhere.insert(key) }
        }
        let hiddenHere = hidden[nest.id] ?? [:]
        // Hidden until what it says changes.
        let stillHidden = Set(items.compactMap { item in hiddenHere[item.key].map { $0 == item.words ? item.key : nil } ?? nil })
        if stillHidden.count != hiddenHere.count {
            hidden[nest.id] = hiddenHere.filter { stillHidden.contains($0.key) }
            saveHidden()
        }
        let diff: LiveDiff
        if kind == .toDo && newsLists.isEmpty {
            diff = LiveFolder.diff(items, held: held, today: today, elsewhere: elsewhere, hidden: stillHidden)
        } else {
            // Once shown, never again: what it brought, and on the first
            // reading everything it left out as not fresh. In a to-do
            // folder, only what its new-for-you lists brought.
            let before = shown[nest.id] ?? []
            diff = kind == .news
                ? LiveFolder.news(items, held: held, shown: before, hidden: stillHidden, first: first)
                : LiveFolder.mixed(items, news: newsLists, held: held, today: today, elsewhere: elsewhere, hidden: stillHidden,
                                   shown: before, first: first)
            let now = LiveFolder.shown(items, kind: kind, news: newsLists, added: diff.add, before: before, first: first)
            if now != before {
                shown[nest.id] = now.count > 600 ? Set(now.shuffled().prefix(500)).union(now.subtracting(before)) : now
                saveHidden()
            }
        }
        guard diff != LiveDiff() else { return diff }
        browser.quietly {
            for (id, words) in diff.words {
                guard let tab = members.first(where: { $0.id == id }), var mark = tab.live else { continue }
                mark.words = words
                tab.live = mark
            }
            for (id, said) in diff.said {
                guard let tab = members.first(where: { $0.id == id }) else { continue }
                // A tab of yours in it is given words too, never taken away.
                var mark = tab.live ?? LiveMark(key: keyOf(tab.address) ?? "", words: nil, seen: nil, folder: nest.id, yours: true)
                mark.said = said
                tab.live = mark
            }
            var fresh: [Tab] = []
            for item in diff.add {
                let tab: Tab
                if let id = diff.adopt[item.key], let open = browser.tabs.first(where: { $0.id == id }) {
                    tab = open
                    if adoptingTaskTabs.contains(tab.id) { Folders.shared.keep(tab) }
                } else {
                    tab = browser.asleepTab(item.url, title: item.title)
                }
                tab.kept = true
                tab.nest = nest
                tab.live = LiveMark(key: item.key, words: item.words, seen: nil, folder: nest.id, came: Date(), said: item.said,
                                    news: newsLists.contains(item.list ?? "") ? true : nil)
                fresh.append(tab)
            }
            if !fresh.isEmpty {
                // At the folder's top: where its first tab stands, or the
                // kept's end for a folder with none yet.
                let ids = Set(fresh.map(\.id))
                let rest = browser.tabs.filter { !ids.contains($0.id) }
                let pins = rest.filter { $0.pin != nil }
                var kept = rest.filter(\.kept)
                let at = kept.firstIndex { $0.nest === nest } ?? kept.count
                kept.insert(contentsOf: fresh, at: at)
                browser.lay(pins + kept + rest.filter { $0.pin == nil && !$0.kept })
            }
        }
        let going = members.filter { diff.remove.contains($0.id) }
        remove(going, from: nest, in: browser)
        Folders.shared.refresh()
        browser.writeSession()
        return diff
    }

    /// Gone from the folder, closed as today's tabs close. One awake with
    /// something typed in it stays, and goes at the next reading after.
    private func remove(_ going: [Tab], from nest: Nest, in browser: Browser) {
        guard !going.isEmpty else { return }
        let asleep = going.filter(\.asleep)
        let awake = going.filter { !$0.asleep }
        let done = { (tabs: [Tab]) in
            guard !tabs.isEmpty else { return }
            for tab in tabs { tab.live = nil }
            browser.discard(tabs)
            if !browser.tabs.contains(where: { $0.nest === nest }) {
                Folders.shared.keepEmpty(nest, space: browser.spaceID)
            }
        }
        done(asleep)
        for tab in awake {
            tab.unsaved { typed in
                MainActor.assumeIsolated { if !typed { done([tab]) } }
            }
        }
    }

    /// On screen, making sound, or on a call: left where it is for now.
    private func busy(_ tab: Tab, in browser: Browser) -> Bool {
        browser.onScreen(tab.id) || tab.noisy || tab.onCall
    }

    // MARK: what you do

    /// Hide from Folder: out, and kept out until what it says changes.
    func hide(_ tab: Tab, in browser: Browser) {
        guard let nest = tab.nest, let mark = tab.live else { return }
        hidden[nest.id, default: [:]][mark.key] = mark.words
        saveHidden()
        remove([tab], from: nest, in: browser)
        Folders.shared.refresh()
    }

    /// A tab it brought, taken out of it by hand (dragged out, Don't Keep):
    /// yours now, and its folder leaves that thing out until what it says
    /// changes, rather than taking it back at the next reading.
    func takenOut(_ tab: Tab) {
        guard let mark = tab.live else { return }
        tab.live = nil
        guard let folder = mark.folder else { return }
        hidden[folder, default: [:]][mark.key] = mark.words
        saveHidden()
    }

    /// Stop Updating: its tabs stay, a plain folder of yours.
    func stop(_ nest: Nest, in browser: Browser) {
        nest.live = nil
        for tab in browser.tabs where tab.nest === nest { tab.live = nil }
        states[nest.id] = nil
        Folders.shared.emptyChanged(nest)
        Folders.shared.refresh()
        browser.writeSession(now: true)
    }

    /// A tick or a repository changed in its menu: read again at once.
    func changed(_ nest: Nest, in browser: Browser) {
        Folders.shared.emptyChanged(nest)
        browser.writeSession(now: true)
        states[nest.id]?.read = nil
        read(nest, in: browser)
    }

    // MARK: making one

    /// New Live Folder › a source: an empty one at the kept's end, read at
    /// once; with one of it there already, that one, read. `host`: the
    /// site's (an Enterprise GitHub), a Google account's number for Drive,
    /// the feed's address for a feed.
    @discardableResult
    func make(_ source: String = "github.pulls", in browser: Browser, host: String? = nil, name: String? = nil) -> Nest? {
        guard let kind = LiveSource.of(source) else { return nil }
        // Only explicit creation opts in; navigation must not create one.
        let selectedHost: String
        if let git = LiveGitService.of(source) {
            guard let raw = host, let page = git.repository(raw) else { return nil }
            selectedHost = page.absoluteString
        } else {
            selectedHost = host ?? (source.hasPrefix("github.") ? "github.com" : source == "drive" ? "0" : kind.site)
        }
        browser.prefs.usesLiveFolders = true
        if let there = Self.nests(in: browser).first(where: { $0.live?.source == source && $0.live?.host == selectedHost }) {
            read(there, in: browser)
            return there
        }
        // The window's own folders: a second window has its own (#353,
        // where Add did nothing there but say to open the space).
        guard browser.folderBook.browser === browser,
              let nest = browser.folderBook.makeEmpty(named: name ?? kind.name,
                                                  live: Live(source: source, host: selectedHost, show: kind.shownAtFirst)) else { return nil }
        if source == "github.pulls" { Store.settings.set(false, forKey: Self.removedKey(browser.spaceID)) }
        read(nest, in: browser)
        return nest
    }

    /// A repository followed: its open pull requests, yours or not, active
    /// in the last week (Live.days), as a search folder of its own named for the repository. Its owner and
    /// name come typed, from history, or out of a github.com address.
    @discardableResult
    func followRepo(_ typed: String, in browser: Browser, issuesIn destination: Nest? = nil) -> Nest? {
        guard let full = Self.repo(typed), browser.folderBook.browser === browser else { return nil }
        if let destination {
            guard Self.nests(in: browser).contains(where: { $0 === destination }),
                  var live = destination.live, live.source == "github.issues" else { return nil }
            var repositories = live.issueRepositories
            if !repositories.contains(where: { $0.lowercased() == full.lowercased() }) { repositories.append(full) }
            live.query = repositories.map { "repo:\($0)" }.joined(separator: " ")
            live.hidden.removeAll { $0.lowercased() == full.lowercased() }
            destination.live = live
            browser.prefs.usesLiveFolders = true
            changed(destination, in: browser)
            return destination
        }
        browser.prefs.usesLiveFolders = true
        let query = "is:pr is:open repo:\(full)"
        if let there = Self.nests(in: browser).first(where: { $0.live?.source == "github.search" && $0.live?.query == query }) {
            read(there, in: browser)
            return there
        }
        guard let nest = browser.folderBook.makeEmpty(named: String(full.split(separator: "/").last ?? "Repository"),
                                                  live: Live(source: "github.search", host: "github.com", show: [], query: query)) else { return nil }
        read(nest, in: browser)
        return nest
    }

    /// "owner/name" out of what was typed: the two words, or a github.com
    /// address of the repository or of anything in it.
    nonisolated static func repo(_ typed: String) -> String? {
        var words = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://", "http://", "www.", "github.com/"] where words.lowercased().hasPrefix(prefix) {
            words = String(words.dropFirst(prefix.count))
        }
        let parts = words.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let owner = parts[0], name = parts[1].replacingOccurrences(of: ".git", with: "")
        guard !owner.isEmpty, !name.isEmpty,
              owner.unicodeScalars.allSatisfy(allowed.contains), name.unicodeScalars.allSatisfy(allowed.contains),
              !LiveSuggest.notRepos.contains(owner.lowercased()) else { return nil }
        return owner + "/" + name
    }

    /// Keep This Search as a Folder: a GitHub search the tab shows, read
    /// again and again, named for its words.
    func keepSearch(_ tab: Tab, in browser: Browser) {
        guard let url = tab.address, let found = LiveIssues.search(in: url), let host = LiveGitHub.host(of: url),
              browser.folderBook.browser === browser else { return }
        browser.prefs.usesLiveFolders = true
        let words = found.query.replacingOccurrences(of: #"\bis:(open|pr|issue)\b"#, with: "", options: .regularExpression)
            .split(separator: " ").joined(separator: " ")
        let query = found.pulls && !found.query.contains("is:pr") ? "is:pr " + found.query : found.query
        guard let nest = browser.folderBook.makeEmpty(named: words.isEmpty ? "Search" : String(words.prefix(40)),
                                                  live: Live(source: "github.search", host: host, show: [], query: query)) else { return }
        read(nest, in: browser)
    }

    /// Follow in a Folder: the page's own feed, found in it, as a folder
    /// named for the site.
    func follow(_ tab: Tab, in browser: Browser) {
        tab.feed { [weak browser] feed, site in
            guard let browser else { return }
            guard let feed else { return browser.announce("This page has no feed to follow", mark: "info.circle") }
            self.make("feed", in: browser, host: feed.absoluteString, name: site)
        }
    }

    /// Whether this space's folder was removed: then it isn't made again
    /// by itself (Remove Folder), only by hand.
    static func removedKey(_ space: UUID) -> String { "live.github.removed." + space.uuidString }

    /// A tab went from making a pull request to the pull request: the first
    /// time in a space, its folder is made, and that tab moves into it.
    func noticeMove(_ tab: Tab, from old: URL?, to url: URL, in browser: Browser) {
        guard browser.prefs.usesLiveFolders, !tab.bench, !tab.shy, LiveFolder.key(url) != nil, let old,
              old.host() == url.host(), old.path.contains("/compare/") || old.path.contains("/pull/new"),
              !Store.settings.bool(forKey: Self.removedKey(browser.spaceID)),
              let host = LiveGitHub.host(of: url),
              !Self.nests(in: browser).contains(where: { $0.live?.source == "github.pulls" }) else { return }
        guard let nest = make("github.pulls", in: browser, host: host) else { return }
        if tab.keepable {
            browser.keepTabs([tab], in: nest)
            tab.live = LiveMark(key: LiveFolder.key(url) ?? url.absoluteString, words: nil, seen: nil, folder: nest.id, yours: true, moved: true)
        }
        browser.announce("Your pull requests, kept up to date here", mark: "folder")
    }

    /// Remove Folder on a live one: not made again by itself in this space.
    func removed(_ nest: Nest, in browser: Browser) {
        if nest.live?.source == "github.pulls" { Store.settings.set(true, forKey: Self.removedKey(browser.spaceID)) }
        states[nest.id] = nil
    }

    // MARK: a routine's folder

    /// The folder a routine keeps. One, in the space it was made in
    /// (`Routine.space`): only found while that space is in the window;
    /// made there, named for the routine, at the kept's end, when `make`,
    /// it has none yet, and that space (or, the first time, any) is up.
    func folder(of routine: Routine, in browser: Browser, make: Bool = false) -> Nest? {
        if let there = Self.nests(in: browser).first(where: { $0.live?.source == "routine" && $0.live?.host == routine.id }) { return there }
        guard make, browser.prefs.usesLiveFolders, Folders.shared.browser === browser, routine.space == nil || routine.space == browser.spaceID else { return nil }
        let nest = Folders.shared.makeEmpty(named: routine.name, live: Live(source: "routine", host: routine.id, show: []))
        if nest != nil { Routines.shared.placed(routine.id, in: browser.spaceID) }
        return nest
    }

    /// What a routine's run says belongs in its folder, made so: new ones
    /// at its top, asleep, words changed, what it no longer lists gone. Its
    /// space out of sight: kept until that space is back (settleRoutines),
    /// and what would change said from what it held when last seen.
    @discardableResult
    func keep(_ routine: Routine, _ items: [LiveItem], adoptingTaskTabs: Set<UUID> = [], in browser: Browser) -> LiveDiff? {
        guard browser.prefs.usesLiveFolders else {
            pending[routine.id] = items
            return nil
        }
        guard let nest = folder(of: routine, in: browser, make: true) else {
            guard routine.space != nil else { return nil }
            pending[routine.id] = items
            let before = Set((lastHeld[routine.id] ?? []).compactMap { LiveFolder.page(URL(string: $0.url)) })
            lastHeld[routine.id] = items.map { ($0.url.absoluteString, $0.title, $0.said.map { $0.gone ? "gone: " + $0.text : $0.text } ?? "") }
            return LiveDiff(add: items.filter { !before.contains($0.key) && $0.said?.gone != true })
        }
        pending[routine.id] = nil
        if nest.name != routine.name, nest.name == Routine.name(from: routine.prompt) { nest.name = routine.name }
        states[nest.id] = State(read: Date())
        let diff = apply(items, to: nest, adoptingTaskTabs: adoptingTaskTabs, in: browser)
        _ = held(by: routine, in: browser)
        return diff
    }

    /// A window's routine folders, each time it is looked at: what a run
    /// handed one while its space was away put in now, and one whose
    /// routine is gone a plain folder of yours again.
    func settle() {
        for browser in BrowserWindows.shared.browsers { settleRoutines(in: browser) }
        LiveSeen.prune()
    }

    private func settleRoutines(in browser: Browser) {
        guard browser.prefs.usesLiveFolders else { return }
        for nest in Self.nests(in: browser) where nest.live?.source == "routine" {
            guard let id = nest.live?.host else { continue }
            guard let routine = Routines.shared.all.first(where: { $0.id == id }) else {
                stop(nest, in: browser)
                continue
            }
            if let items = pending.removeValue(forKey: id) { apply(items, to: nest, in: browser) }
            _ = held(by: routine, in: browser)
        }
    }

    /// What a routine's folder holds, for its next run: each tab's address,
    /// title and words; as last seen when its space is out of sight.
    func held(by routine: Routine, in browser: Browser) -> [(url: String, title: String, said: String)] {
        guard let nest = folder(of: routine, in: browser) else { return lastHeld[routine.id] ?? [] }
        let now: [(url: String, title: String, said: String)] = browser.tabs.filter { $0.nest === nest }.compactMap { tab in
            guard let url = tab.address?.absoluteString else { return nil }
            return (url, tab.label, tab.live?.said.map { $0.gone ? "gone: " + $0.text : $0.text } ?? "")
        }
        lastHeld[routine.id] = now
        return now
    }

    /// A routine's run began or ended: its folder says "Checking" meanwhile.
    /// Its first run makes the folder at once: it comes, says Checking, and
    /// fills.
    func checking(_ routine: Routine, _ on: Bool, in browser: Browser) {
        guard browser.prefs.usesLiveFolders || !on else { return }
        if on {
            _ = folder(of: routine, in: browser, make: true)
            checking.insert(routine.id)
        } else {
            checking.remove(routine.id)
        }
    }

    /// Whether a folder's routine is looking now.
    func checking(_ nest: Nest) -> Bool {
        nest.live?.source == "routine" && nest.live.map { checking.contains($0.host) } == true
    }

    // MARK: kept

    private static var hiddenFile: URL { Store.file("live-folders.json") }

    /// What is kept across launches: hidden things by folder, with the
    /// words they had, and what new-for-you folders have shown.
    private struct Kept: Codable {
        var hidden: [String: [String: String]] = [:]
        var shown: [String: [String]] = [:]
    }

    private static func readKept() -> (hidden: [UUID: [String: LiveWords?]], shown: [UUID: Set<String>]) {
        guard let data = try? Data(contentsOf: hiddenFile) else { return ([:], [:]) }
        // The first file held only what was hidden.
        let kept = (try? JSONDecoder().decode(Kept.self, from: data))
            ?? (try? JSONDecoder().decode([String: [String: String]].self, from: data)).map { Kept(hidden: $0) } ?? Kept()
        var hidden: [UUID: [String: LiveWords?]] = [:]
        for (nest, keys) in kept.hidden {
            guard let id = UUID(uuidString: nest) else { continue }
            hidden[id] = keys.mapValues { LiveWords(rawValue: $0) }
        }
        var shown: [UUID: Set<String>] = [:]
        for (nest, keys) in kept.shown { if let id = UUID(uuidString: nest) { shown[id] = Set(keys) } }
        return (hidden, shown)
    }

    private func saveHidden() {
        var kept = Kept()
        for (nest, keys) in hidden where !keys.isEmpty { kept.hidden[nest.uuidString] = keys.mapValues { $0?.rawValue ?? "" } }
        for (nest, keys) in shown where !keys.isEmpty { kept.shown[nest.uuidString] = keys.sorted() }
        guard let data = try? JSONEncoder().encode(kept) else { return }
        try? data.write(to: Self.hiddenFile, options: .atomic)
    }

    // MARK: for Folders

    /// A window's live folders: those its tabs hold, and the empty ones
    /// its folders keep (a second window has folders of its own).
    static func nests(in browser: Browser) -> [Nest] {
        var seen: [Nest] = []
        for tab in browser.tabs where tab.kept {
            if let nest = tab.nest, nest.live != nil, !seen.contains(where: { $0 === nest }) { seen.append(nest) }
        }
        if browser.folderBook.browser === browser { seen += browser.folderBook.empties.filter { $0.live != nil } }
        return seen
    }

    /// "Updated 2m ago", for a live folder's preview, by its folder's key.
    static func updated(_ key: String) -> String? {
        guard Nest.isKey(key), let id = UUID(uuidString: String(key.dropFirst(5))),
              let read = shared.states[id]?.read else { return nil }
        if shared.states[id]?.signedOut == true { return "Signed out" }
        let minutes = Int(Date().timeIntervalSince(read) / 60)
        switch minutes {
        case ..<1: return "Updated just now"
        case ..<60: return "Updated \(minutes)m ago"
        default: return "Updated \(minutes / 60)h ago"
        }
    }

    /// What a live folder's preview says at its foot: nothing while the
    /// folder is fresh, only a read under way, one gone late (twice its
    /// turn, ten minutes at least), or a sign-out.
    enum Foot: Equatable {
        case reading(String)
        case late(minutes: Int)
        case signedOut(String, URL?)
    }

    /// A --test run's folder state, as `bench live pretend` sets it.
    func pretend(_ nest: Nest, age minutes: Double, signedOut: Bool, reading: Bool) {
        guard Store.testing else { return }
        states[nest.id] = State(read: Date().addingTimeInterval(-minutes * 60), signedOut: signedOut, failures: 0)
        if reading { self.reading.insert(nest.id) } else { self.reading.remove(nest.id) }
    }

    static func foot(_ nest: Nest, now: Date = Date()) -> Foot? {
        guard let live = nest.live, let source = LiveSource.of(live.source), live.source != "routine" else { return nil }
        if shared.reading.contains(nest.id) { return .reading(source.service) }
        guard let state = shared.states[nest.id], let read = state.read else { return nil }
        if state.signedOut { return .signedOut(source.service, source.page(live)) }
        let minutes = Int(now.timeIntervalSince(read) / 60)
        return minutes >= max(10, Int(source.every * 2 / 60)) ? .late(minutes: minutes) : nil
    }

    /// A shut live folder's tabs that need you, out from under it: three at
    /// most, the rest said on its row.
    static func callingOut(_ nest: Nest, in browser: Browser) -> Set<Tab.ID> {
        callingOut(nest, among: browser.tabs)
    }

    /// The same among a row of tabs, a space's not on screen too.
    static func callingOut(_ nest: Nest, among tabs: [Tab]) -> Set<Tab.ID> {
        // A routine's folder says "1 new" on its own row instead.
        guard nest.live != nil, nest.live?.source != "routine" else { return [] }
        return Set(tabs.lazy.filter { $0.nest === nest && $0.live?.callsOut == true }.prefix(3).map(\.id))
    }

    /// How many of a folder's tabs need you and wait unseen.
    static func waiting(_ nest: Nest, in browser: Browser) -> Int {
        browser.tabs.reduce(0) { $0 + ($1.nest === nest && $1.live?.callsOut == true ? 1 : 0) }
    }
}

extension Tab {
    /// Brought by a live folder (or a routine's), rather than kept there by
    /// you: the folder's to take away.
    var broughtByFolder: Bool { live.map { $0.yours != true } ?? false }

    /// In its folder by the folder's doing, brought or moved in by it (the
    /// pull request you just made), rather than by your hand: a row with
    /// its status, never a tab you chose to keep, so once opened and left
    /// it sleeps as today's tabs do (Browser.awake(because:)). Only a tab
    /// you moved in by hand, or took out, keeps the kept rules. The mark
    /// travels with the row in sync, so it holds on every Mac.
    var placedByFolder: Bool { broughtByFolder || live?.moved == true }

    /// The page's own feed, RSS or Atom, as it names it in its head, and
    /// what the site calls itself.
    func feed(_ done: @escaping @MainActor (URL?, String?) -> Void) {
        let js = """
        (function () {
          var l = document.querySelector('link[rel="alternate"][type*="rss"], link[rel="alternate"][type*="atom"]');
          var s = document.querySelector('meta[property="og:site_name"]');
          return l ? [l.href, s ? s.content : location.hostname.replace(/^www\\./, '')] : null;
        })()
        """
        guard let built = builtPage else { return done(nil, nil) }
        built.runInYab(js) { value in
            let pair = value as? [String]
            MainActor.assumeIsolated { done(pair?.first.flatMap(URL.init(string:)), pair?.last) }
        }
    }
}

extension Browser {
    /// A tab for a page, asleep: a row, no page, no process, until opened.
    func asleepTab(_ url: URL, title: String) -> Tab {
        let tab = Tab(configuration: Web.configuration(store: Spaces.store(for: spaceID)))
        prepare(tab)
        tab.restore(url: url, title: title)
        return tab
    }
}
