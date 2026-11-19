import SwiftUI
import AppKit
import Combine
import SQLite3

// MARK: - bringing things over

/// Discovery lists browsers only. Files, counts and keychain items are read
/// only after Bring In is pressed, for that operation and that browser.
@MainActor
@Observable final class Bringing {
    /// What one browser holds, counted, not yet taken.
    struct Counts: Equatable {
        var passwords: Int?
        var cards: Int?
        var addresses: Int?
        var memory: Int?
        var chats: Int?
        var bookmarks: Int?
        /// The pages in its history.
        var places: Int?
        var cookies: Int?
        /// The sites it is signed in to: each site with a live sign-in cookie, once.
        var signIns: Int?
        /// Its spaces or profiles, each with its pins. Nil until read;
        /// empty when the browser has nothing pinned or open.
        var tabPlaces: [TabImport.Place]?
        /// Onboarding transfers ordinary tabs as well as pins.
        var withOpen = false
        /// Why the tabs couldn't be read, in words, and the cause when it
        /// is known, for the corner's notice.
        var tabsTrouble: String?
        var tabsCause: TabImport.Trouble?
        /// The extensions on there that aren't here yet.
        var extensions: [Chromium.Extension]?
        /// Its pins' own icons, by host, from its Favicons file.
        var pinIcons: [String: NSImage] = [:]

        /// The places with something to bring.
        var holding: [TabImport.Place] { (tabPlaces ?? []).filter { $0.holds(withOpen: withOpen) } }
        /// Every tab that stays there, the pins and the tabs kept in its
        /// folders: all of them come.
        var pinned: Int { holding.reduce(0) { $0 + $1.pinned.count + $1.kept.count } }
        var open: Int { withOpen ? holding.reduce(0) { $0 + $1.open.count } : 0 }
        /// Its folders, each name once.
        var folders: Int { Set(holding.flatMap { $0.kept.compactMap(\.folder) }).count }
        /// The colors its places wear, each with its place's name.
        var colors: [(name: String, color: NSColor)] {
            holding.compactMap { place in place.color.flatMap { NSColor(hex: $0) }.map { (name: place.name, color: $0) } }
        }
    }

    enum State: Equatable {
        case idle
        case bringing
        case done(String)
        case failed(String)
    }

    /// What came of asking macOS for the other browser's key.
    enum Answer: Equatable {
        /// Given, or not needed: the welcome goes on and the rest comes in behind it.
        case allowed
        /// Said beside the button: "The keychain is locked", "Couldn’t read Dia’s tabs".
        case failed(String)
    }

    private(set) var sources: [Chromium.Source] = []
    var chosen: Chromium.Source? {
        didSet {
            guard chosen != oldValue else { return }
            taken = []
            state = .idle
            count(chosen)
        }
    }
    /// The browsers brought in from already, by id.
    private(set) var brought: Set<String> = []
    private(set) var counts: [String: Counts] = [:]
    /// Several places, spaces off: each comes as a space of its own (Keep
    /// its spaces), or all of them together into the one row.
    var asSpaces = false
    private(set) var state: State = .idle
    /// macOS is asking for the key, after Bring was pressed.
    private(set) var asking = false
    /// What's already been brought from the chosen browser, so a second
    /// press brings only what's left.
    @ObservationIgnored private var taken: Set<String> = []

    var current: Counts { chosen.flatMap { counts[$0.id] } ?? Counts() }
    var busy: Bool { state == .bringing }
    /// Everything came, the last of it in behind the welcome.
    var allIn: Bool { if case .done = state { return true } else { return false } }

    /// The browsers on this Mac, their icons, and which one links go to.
    /// Finding them checks container metadata and asks macOS for icons, so it is
    /// done once, off the main thread; the chapter then reads what was found
    /// rather than asking again every time it is drawn.
    private(set) var loaded = false
    private(set) var icons: [String: NSImage] = [:]
    /// When each was last browsed in, read with the rest.
    private(set) var used: [String: Date] = [:]
    private(set) var defaultID: String?
    @ObservationIgnored private var loading = false
    /// A failure said once the welcome has handed the window over.
    @ObservationIgnored private var later: AnyCancellable?

    /// How long the tabs, sign-ins and the rest wait after the key is
    /// given: until your pins have poured into the window-to-be, so the
    /// main thread is free for the peak.
    static let afterPour: Double = 1.2

    /// Refresh browser discovery only. No credential files or profile
    /// metadata are read, on any thread, before the import button.
    func load() {
        guard !loaded, !loading else { return }
        if let kept = BringCache.browsers { show(kept) }
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let found = Hangs.time("browsers.find") { Chromium.installed() }
            var icons: [String: NSImage] = [:]
            var used: [String: Date] = [:]
            for source in found {
                icons[source.id] = source.icon
                used[source.id] = source.lastUsed
            }
            let fallback = found.first(where: \.isDefault)?.id
            DispatchQueue.main.async {
                self.loading = false
                let fresh = BringCache.Found(sources: found, icons: icons, used: used, defaultID: fallback, at: .now)
                BringCache.keep(fresh)
                // The same browsers as shown already: nothing to draw again.
                if self.loaded, self.sources == found, self.used == used, self.defaultID == fallback { return }
                self.show(fresh)
            }
        }
    }

    private func show(_ found: BringCache.Found) {
        icons = found.icons
        used = found.used
        defaultID = found.defaultID
        sources = found.sources
        loaded = true
        if chosen == nil || !found.sources.contains(where: { $0 == chosen }) { chosen = found.sources.first }
        // Each one's counts, for the chapter that asks which: what
        // a browser holds is how the one in use is told apart.
        found.sources.forEach(count)
    }

    /// Browsers whose tabs shown are the kept ones: Bring reads them again.
    @ObservationIgnored private var keptTabs: Set<String> = []

    private func count(_ source: Chromium.Source?) {
        guard let source, counts[source.id] == nil else { return }
        // Discovery must not open or stat another browser's credential stores.
        // Counts remain unknown until the person presses Bring In.
        counts[source.id] = Counts(withOpen: true)
    }

    /// Its places read, and its pins' icons after them; `done` hears why
    /// they couldn't be, nil when they could.
    private func readTabs(_ source: Chromium.Source, ask: Bool = false, stamp: String? = nil, then done: @escaping (Error?) -> Void) {
        TabImport.load(source, ask: ask) { outcome in
            var counts = self.counts[source.id] ?? Counts(withOpen: true)
            switch outcome {
            case .success(let found):
                counts.tabPlaces = found
                counts.tabsTrouble = nil
                counts.tabsCause = nil
            case .failure(let error):
                counts.tabPlaces = []
                counts.tabsTrouble = Self.unreadable(source, error)
                counts.tabsCause = error as? TabImport.Trouble
            }
            self.keptTabs.remove(source.id)
            if counts != self.counts[source.id] { self.counts[source.id] = counts }
            switch outcome {
            case .success(let found):
                // Kept with its files' stamp only when it was read whole.
                BringCache.keep(source, counts: counts, stamps: stamp.map { [.tabs: $0] } ?? [:])
                self.readIcons(source, found)
                done(nil)
            case .failure(let error):
                BringCache.keep(source, counts: counts)
                done(error)
            }
        }
    }

    /// The pins' icons as the other browser kept them, for the pins pouring
    /// into the window-to-be: read off the main thread, a few dozen at most.
    private func readIcons(_ source: Chromium.Source, _ places: [TabImport.Place]) {
        let urls = places.flatMap { $0.pinned.map(\.url) }
        guard !urls.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            let found = Chromium.icons(in: source, for: urls, limit: 40)
            var icons: [String: NSImage] = [:]
            for (host, data) in found { icons[host] = NSImage(data: data) }
            DispatchQueue.main.async {
                guard !icons.isEmpty, var counts = self.counts[source.id] else { return }
                counts.pinIcons = icons
                self.counts[source.id] = counts
                BringCache.keep(source, counts: counts)
            }
        }
    }

    /// What is here already stays out: a store one by its id, an unpacked
    /// one by the folder it's loaded from.
    private static func fresh(_ found: [Chromium.Extension]) -> [Chromium.Extension] {
        guard #available(macOS 15.4, *) else { return [] }
        let here = Set(Extensions.shared.installed.map(\.id))
        let folders = Set(Extensions.shared.installed.compactMap(\.source))
        // One on in a profile past the first goes to that profile's space,
        // whatever the shared sign-in has (Extensions.bringIn(byProfile:)).
        return found.filter { (!here.contains($0.id) && !folders.contains($0.folder.path)) || $0.profiles.contains { $0 != "Default" } }
    }

    /// "Couldn’t read Dia’s tabs: its tab file is damaged", as
    /// TabImport.explain says it, its apostrophes the welcome's.
    static func unreadable(_ source: Chromium.Source, _ error: Error) -> String {
        TabImport.explain(error, from: source).replacingOccurrences(of: "'", with: "\u{2019}")
    }

    /// "Your default browser", "Used yesterday", "Brought in".
    func caption(_ source: Chromium.Source) -> String {
        if brought.contains(source.id) { return "Brought in" }
        if defaultID == source.id { return "Your default browser" }
        return "Available to import"
    }

    /// "Used today", "Used 3 days ago", "Used in March", "Used in 2025".
    static func used(_ date: Date?, now: Date = .now) -> String {
        guard let date else { return "Not used yet" }
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return "Used today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Used yesterday"
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days < 7 { return "Used \(days) days ago" }
        if days < 14 { return "Used a week ago" }
        if days < 31 { return "Used \(days / 7) weeks ago" }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US")
        format.dateFormat = days < 300 ? "MMMM" : "yyyy"
        return "Used in " + format.string(from: date)
    }

    // MARK: what comes into the window

    /// Every place as one, for the row on screen: the pins first, in order,
    /// then the tabs kept in folders, each page once.
    static func merge(_ places: [TabImport.Place]) -> TabImport.Place? {
        guard var one = places.first else { return nil }
        var seen = Set<String>()
        one.pinned = TabImport.once(places.flatMap(\.pinned), seen: &seen)
        one.kept = TabImport.once(places.flatMap(\.kept), seen: &seen)
        one.open = TabImport.once(places.flatMap(\.open), seen: &seen)
        one.splits = places.flatMap(\.splits)
        return one
    }

    /// How the places go, one bring each. Spaces on, or kept as spaces:
    /// all at once, each where it lands. Otherwise the places signed in as
    /// the browser's first profile come together into the row on screen,
    /// and a profile with sign-ins of its own comes as its own space, never
    /// into that row, where its pages would open signed in as the first.
    static func batches(_ places: [TabImport.Place], asSpaces: Bool, spaces: Bool) -> [(places: [TabImport.Place], asSpaces: Bool)] {
        guard !asSpaces, !spaces, places.count > 1 else { return [(places, asSpaces)] }
        var out: [(places: [TabImport.Place], asSpaces: Bool)] = []
        if let shared = merge(places.filter(\.shared)) { out.append(([shared], false)) }
        let apart = places.filter { !$0.shared }
        if !apart.isEmpty { out.append((apart, true)) }
        return out
    }

    /// What of a browser's comes into the row on screen: its pins, nine at
    /// most (Browser.pinLimit; the rest come as tabs that stay), each with
    /// its own icon, and its folders with how many tabs each holds. From
    /// the first of its places when they come as spaces; from those that
    /// come together into one list otherwise (`batches`).
    static func yours(_ counts: Counts, spaces: Bool) -> (pins: [WelcomeMark], folders: [(name: String, count: Int)]) {
        let holding = counts.holding
        guard let place = spaces ? holding.first : batches(holding, asSpaces: false, spaces: false).first?.places.first
        else { return ([], []) }
        let pins: [WelcomeMark] = place.pinned.prefix(Browser.pinLimit).map { entry in
            guard let host = entry.url.host()?.lowercased(), let icon = counts.pinIcons[host] else { return .site(.globe) }
            return .picture(icon)
        }
        var names: [String] = []
        var held: [String: Int] = [:]
        for entry in place.kept {
            guard let name = entry.folder else { continue }
            if held[name] == nil { names.append(name) }
            held[name, default: 0] += 1
        }
        return (pins, names.map { (name: $0, count: held[$0] ?? 0) })
    }

    // MARK: bringing it

    /// Bring from the chosen browser, pressed. Its tabs first, read again if
    /// they couldn't be; then macOS asks for its key, once, reading its
    /// passwords (or only the key, when it keeps none). `answer` hears
    /// whether that went through, on the main thread, and says whether to go
    /// on: false, and nothing comes (Start Fresh was pressed meanwhile). On,
    /// the rest comes in behind the welcome: thousands of passwords, pages
    /// and sign-ins are seconds, and nobody should sit and watch them.
    /// Something came over once, from the welcome or Settings › General:
    /// General stops offering it at the top.
    static let everKey = "bring.done"
    static var everBrought: Bool { Store.settings.bool(forKey: everKey) }
    /// The browser first brought in from, by name, and when: kept once, for
    /// a post about Yab written in the person's own facts.
    static let fromKey = "bring.from", atKey = "bring.at"

    func bring(into browser: Browser, answer: @escaping (Answer) -> Bool) {
        guard let chosen, !asking, !busy else { return }
        let source = chosen.authorizingImport()
        if counts[source.id] == nil { counts[source.id] = Counts() }
        asking = true
        // Dia is asked itself, now that Bring was pressed: its own file
        // stopped following what it shows (DiaScript).
        let asksDia = source.bundle == TabImport.dia
        // Tabs shown from what was kept are read again: what comes is what
        // is there now.
        guard current.tabPlaces == nil || current.tabsTrouble != nil || asksDia || keptTabs.contains(source.id) else {
            unlock(source, into: browser, answer: answer)
            return
        }
        readTabs(source, ask: asksDia) { error in
            if let error { TabImport.note(error) }
            guard self.chosen?.id == source.id && self.chosen?.root == source.root else { self.asking = false; return }
            self.unlock(source, into: browser, answer: answer)
        }
    }

    /// The key asked for, off the main thread: the passwords read with it,
    /// or the key alone when the sign-ins need it and there are no passwords.
    private func unlock(_ source: Chromium.Source, into browser: Browser, answer: @escaping (Answer) -> Bool) {
        DispatchQueue.global(qos: .userInitiated).async {
            let tally = BringTally.read(source, Set(BringPart.allCases).subtracting([.tabs]))
            let readsPasswords = (tally.passwords ?? 0) > 0
            let needsKey = readsPasswords || (tally.cookies ?? 0) > 0 || (tally.cards ?? 0) > 0
            var found: Result<Chromium.Found, Error>?
            var unlocked = true
            if readsPasswords {
                let outcome = Result { try Hangs.measure("passwords.read") { try Chromium.read(source) } }
                if case .failure(Chromium.Trouble.noPassphrase) = outcome { unlocked = false }
                found = outcome
            } else if needsKey {
                unlocked = Chromium.safeStorage(source) != nil
            }
            let passwords = found
            let given = unlocked
            DispatchQueue.main.async {
                self.asking = false
                guard self.chosen?.id == source.id && self.chosen?.root == source.root else { return }
                var counts = self.counts[source.id] ?? Counts(withOpen: true)
                tally.apply(to: &counts, aside: source.bundle == AsideImport.bundle, fresh: Self.fresh)
                self.counts[source.id] = counts
                guard given else {
                    _ = answer(.failed("The keychain is locked"))
                    return
                }
                guard answer(.allowed) else { return }
                self.run(source, into: browser, passwords: passwords)
            }
        }
    }

    /// Everything else, the key given: the passwords (read already) saved
    /// off the main thread at once; the tabs, extensions, bookmarks,
    /// history and sign-ins once the pour has landed. What came, or what
    /// didn't, is said when it is all in: in the welcome's corner by the
    /// welcome itself, else where the pages are. Nothing is lost on a
    /// failure: what came stays, and going back offers to try again.
    private func run(_ source: Chromium.Source, into browser: Browser, passwords found: Result<Chromium.Found, Error>?) {
        state = .bringing
        Hangs.phase("bring.start")
        var lines: [String] = []
        var troubles: [String] = []
        // Why the tabs didn't come, when that is known.
        var tabsCause: TabImport.Trouble?
        let group = DispatchGroup()
        let spaces = browser.prefs.usesSpaces

        // Passwords are a keychain call or two each: a thousand of them are
        // seconds, so the saving stays off the main thread, and only the
        // count comes back to it.
        if let found, !taken.contains("passwords") {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let kept = (try? found.get()).map { passwords in Hangs.measure("passwords.save") { Vault.take(passwords) } }
                DispatchQueue.main.async {
                    switch found {
                    case .success:
                        lines.append("\(kept ?? 0) passwords")
                        self.taken.insert("passwords")
                    case .failure:
                        troubles.append("No passwords readable in \(source.name)")
                    }
                    group.leave()
                }
            }
        }

        if !taken.contains("wallet") {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let found = Result { try Chromium.wallet(source, quiet: true) }
                let kept = (try? found.get()).map { Wallet.take(cards: $0.cards, addresses: $0.addresses) }
                DispatchQueue.main.async {
                    if let kept {
                        if kept.cards > 0 { lines.append("\(kept.cards) cards") }
                        if kept.addresses > 0 { lines.append("\(kept.addresses) addresses") }
                        self.taken.insert("wallet")
                    } else { troubles.append("Couldn't read \(source.name)'s cards and addresses") }
                    group.leave()
                }
            }
        }

        if source.bundle == AsideImport.bundle, !taken.contains("aside") {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let found = AsideImport.read()
                let notes = AsideImport.take(found.notes)
                DispatchQueue.main.async {
                    let added = AsideImport.keep(found.chats)
                    if notes.added > 0 { lines.append("\(notes.added) memory notes") }
                    if added > 0 { lines.append("\(added) archived chats") }
                    let skipped = notes.skipped + found.skipped
                    if skipped > 0 { troubles.append("\(skipped) Aside items couldn't be imported") }
                    else { self.taken.insert("aside") }
                    group.leave()
                }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.afterPour) {
            let counted = self.counts[source.id] ?? Counts()
            if !self.taken.contains("tabs") {
                let places = counted.holding
                // Extension pages with no web address in them can't come:
                // said, so they aren't lost without a word.
                let left = (counted.tabPlaces ?? []).reduce(0) { $0 + $1.left }
                if left > 0 { troubles.append(TabBringer.leftWords(left, from: source)) }
                if !places.isEmpty {
                    // Each space or profile into its space, or all of them
                    // together into the row on screen; sign-ins come in
                    // their own step below, each profile's into its space.
                    var took = (spaces: 0, pinned: 0, open: 0, marked: 0)
                    Hangs.measure("tabs.take") {
                        for batch in Self.batches(places, asSpaces: self.asSpaces, spaces: spaces) {
                            let one = browser.bring(batch.places, withOpen: counted.withOpen, asSpaces: batch.asSpaces, signIns: false, from: source)
                            took = (took.spaces + one.spaces, took.pinned + one.pinned, took.open + one.open, took.marked + one.marked)
                        }
                    }
                    if took.spaces > 0 { lines.append(took.spaces == 1 ? "1 space" : "\(took.spaces) spaces") }
                    lines.append(took.pinned == 1 ? "1 pin" : "\(took.pinned) pins")
                    if took.open > 0 { lines.append(took.open == 1 ? "1 tab" : "\(took.open) tabs") }
                    if took.marked > 0 { lines.append("\(took.marked) bookmarked") }
                    self.taken.insert("tabs")
                } else if let why = counted.tabsTrouble {
                    troubles.append(why)
                    tabsCause = counted.tabsCause
                } else {
                    self.taken.insert("tabs")
                }
            }
            // Arc keeps its boosts apart from its extensions (ArcBoosts):
            // each comes as a boost of yours, on or off as it was.
            if !self.taken.contains("boosts") {
                let brought = ArcBoosts.bringIn(from: source)
                if brought > 0 { lines.append(ArcBoosts.words(brought)) }
                self.taken.insert("boosts")
            }
            if !self.taken.contains("bookmarks") {
                group.enter()
                Hangs.phase("bookmarks")
                browser.takeBookmarks(from: source) { count in
                    lines.append("\(count) bookmarks")
                    self.taken.insert("bookmarks")
                    group.leave()
                }
            }
            if !self.taken.contains("history") {
                group.enter()
                Hangs.phase("history")
                browser.takePlaces(from: source) { count in
                    lines.append("\(count) places")
                    self.taken.insert("history")
                    group.leave()
                }
            }
            // Each profile past the first is a space of its own, those with
            // nothing to bring too.
            browser.profileSpaces(from: source)
            // Each is fetched again from the Web Store, which can take a
            // while for a dozen; they come in behind the welcome. Each
            // profile's into its space's sign-in, as Arc keeps them (#358),
            // once the spaces are there.
            if !self.taken.contains("extensions"), #available(macOS 15.4, *), let extensions = counted.extensions, !extensions.isEmpty {
                Extensions.bringIn(byProfile: extensions, from: source, spaces: browser.spaces)
                lines.append(extensions.count == 1 ? "1 extension on its way" : "\(extensions.count) extensions on their way")
                self.taken.insert("extensions")
            }
            // After the tabs, so a space made with sign-ins of its own is
            // there to take its profile's; the key is given already.
            if !self.taken.contains("cookies") {
                group.enter()
                Hangs.phase("cookies")
                browser.takeCookies(from: source) { count in
                    lines.append("\(count) sign-ins")
                    self.taken.insert("cookies")
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                Hangs.phase("bring.finish")
                let said = lines.joined(separator: " · ")
                let trouble = troubles.isEmpty ? nil : troubles.joined(separator: " · ")
                if let trouble {
                    self.state = .failed(said.isEmpty ? trouble : said + " · " + trouble)
                } else {
                    self.state = .done(said)
                    self.brought.insert(source.id)
                    Store.settings.set(true, forKey: Self.everKey)
                    if Store.settings.string(forKey: Self.fromKey) == nil {
                        Store.settings.set(source.name, forKey: Self.fromKey)
                        Store.settings.set(Date(), forKey: Self.atKey)
                    }
                }
                // All in: the welcome's corner says it while the welcome is
                // up (WelcomeYours); after it, it is said where the pages
                // are. What didn't come is said there once the welcome has
                // handed the window over.
                if trouble != nil {
                    self.say(Self.notice(source, tabs: troubles.count == 1 ? tabsCause : nil), mark: "exclamationmark.triangle", in: browser)
                } else if !said.isEmpty, !browser.welcoming {
                    browser.announce("Brought in from \(source.name)", mark: "tray.and.arrow.down", feedback: .success)
                }
                Hangs.note("brought: \(said.isEmpty ? "nothing" : said)\(trouble.map { " · " + $0 } ?? "")")
                // A while after, for what the import set off behind it:
                // icons arriving, history written out.
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { Hangs.phase("after") }
            }
        }
    }

    /// What the corner says when not everything came: why, when only the
    /// tabs didn't and the cause is known, "Dia's tab file is damaged".
    static func notice(_ source: Chromium.Source, tabs cause: TabImport.Trouble?) -> String {
        cause.map { $0.briefly(source.name) } ?? "Not all of \(source.name) came over"
    }

    /// A notice where the pages are: now, or once the welcome is gone.
    private func say(_ words: String, mark: String, in browser: Browser) {
        guard browser.welcoming else {
            browser.announce(words, mark: mark)
            return
        }
        later = browser.changes(\.welcoming).dropFirst().filter { !$0 }.first().sink { [weak self, weak browser] _ in
            browser?.announce(words, mark: mark)
            self?.later = nil
        }
    }
}

// MARK: - sign-ins, counted

extension Chromium {
    /// Another browser's cookies, counted without the keychain, one copy of
    /// each profile's file read: how many are live, to bring (as
    /// `cookieCount` counts them), and the sites it is signed in to, those
    /// holding a live cookie only the site can read and only over a secure
    /// line, the kind a sign-in leaves, each site once whatever its
    /// subdomains.
    static func cookieTally(_ source: Source) -> (live: Int, sites: Int) {
        guard source.credentialAccess else { return (0, 0) }
        var live = 0
        var sites = Set<String>()
        for folder in source.profiles {
            let deep = folder.appendingPathComponent("Network/Cookies")
            let flat = folder.appendingPathComponent("Cookies")
            guard let file = [deep, flat].first(where: { FileManager.default.fileExists(atPath: $0.path) }),
                  let tally = cookieTally(in: file) else { continue }
            live += tally.live
            sites.formUnion(tally.sites)
        }
        return (live, sites.count)
    }

    /// One profile's Cookies file, read from a copy: its live cookies, and
    /// the sites of the sign-in kind, each as its last two names.
    private static func cookieTally(in file: URL) -> (live: Int, sites: Set<String>)? {
        guard let temp = try? copyWithLog(file) else { return nil }
        defer { removeWithLog(temp) }
        var db: OpaquePointer?
        guard sqlite3_open_v2(temp.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else { return nil }
        defer { sqlite3_close(db) }
        // Microseconds since 1601; has_expires = 0 is a session cookie,
        // live while the browser is.
        let now = Int64((Date().timeIntervalSince1970 + 11_644_473_600) * 1_000_000)
        let fresh = "(has_expires = 0 OR expires_utc > \(now))"
        func rows(_ sql: String, _ each: (OpaquePointer) -> Void) {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return }
            defer { sqlite3_finalize(statement) }
            while sqlite3_step(statement) == SQLITE_ROW { each(statement) }
        }
        var live = 0
        rows("SELECT COUNT(*) FROM cookies WHERE \(fresh)") { live = Int(sqlite3_column_int($0, 0)) }
        var sites = Set<String>()
        rows("SELECT DISTINCT host_key FROM cookies WHERE is_secure = 1 AND is_httponly = 1 AND \(fresh)") { statement in
            guard let text = sqlite3_column_text(statement, 0) else { return }
            let names = String(cString: text).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")).split(separator: ".")
            guard names.count >= 2 else { return }
            sites.insert(names.suffix(2).joined(separator: "."))
        }
        return (live, sites)
    }
}
