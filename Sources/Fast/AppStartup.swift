import AppKit

// What the app starts once a run, as the first window's Browser is made
// (its `windowID` is nil). Each stage is called from Browser.init at the
// spot it always ran, between the window's own setup, so everything still
// starts in the order it did.
//
// Each piece is timed (Startup.stage, `bench startup`). What the first
// window doesn't show waits until the launch is over (Startup.later): the
// update check, crash reports, the day's activity, the Store's marks, the
// diary's first seed, the calendar, mail unless the window opens on it, and
// the skills' refresh. See docs/lazy-launch.md for the whole inventory.

@MainActor
enum AppStartup {
    /// Links from other apps come to this window, and the small window's key.
    static func links(for browser: Browser) {
        Startup.stage("links") {
            Links.browser = browser
            LinkWindow.hotkey(browser.prefs.smallKey)
            ShowYab.hotkey()
            LinkWindow.watch()
        }
    }

    /// The shield, local network protection, extensions and the bench.
    static func services(for browser: Browser) {
        Startup.stage("store permissions") { Store.harden() }
        // Blocking and protection hold from the first page.
        Startup.stage("shield") {
            Shield.shared.enabled = browser.prefs.shielded
            Shield.shared.start()
        }
        Startup.stage("local network") { LocalNetwork.start() }
        // Dark pages follow the window's appearance and the extensions.
        Startup.stage("dark pages") { DarkPages.start() }
        if #available(macOS 15.4, *) {
            // WebKit's controller, made on first use, then what follows the
            // windows; the extensions themselves load once the window is up.
            Startup.stage("extension controller") { _ = Extensions.shared }
            Startup.stage("extensions") { Extensions.shared.start(for: browser) }
        }
        if browser.prefs.bench { Startup.stage("bench") { Bench.shared.start(for: browser) } }
        if Store.testing, ProcessInfo.processInfo.environment["YAB_TEST_CONTROL"] == "1" {
            Startup.stage("consent test UI") { ConsentTestControl.listener.startControl(for: browser) }
        }
    }

    /// Skills set up by an older yab say what this one says.
    static func skills() {
        Startup.later("skills") { DispatchQueue.global(qos: .utility).async { AgentSetup.refreshSkills() } }
    }

    /// Once a day, quietly: is there a newer one? And crash reports, hangs,
    /// the day's activity, and the Store's site marks, ready before the
    /// Store is opened.
    static func checks(for browser: Browser) {
        // The doodle by the Update button is in the first window.
        Startup.stage("update news") { UpdateNews.shared.start() }
        // The main thread's budget is watched from the launch on.
        Startup.stage("main budget") { MainBudget.start() }
        // A friend's link, read on the first launch, before Welcome says who sent it.
        Startup.stage("invite") { Invites.shared.start() }
        Startup.stage("stamp") { MemberStamp.shared.start() }
        Startup.later("update check") { [weak browser] in
            Updater.shared.checkIfDue { [weak browser] line in browser?.announce(line, mark: "arrow.down.circle") }
        }
        Startup.later("crash reports") { Crashes.sendAfterLaunch() }
        Startup.later("field hangs") { FieldHangs.start() }
        Startup.later("activity") { Activity.shared.start() }
        // The opt-in phishing list, fetched (or left alone) after the
        // launch settles, and asked again every hour after that so a copy
        // up for days keeps yesterday's bad sites.
        Startup.later("phishing list") {
            Task { await SafeBrowsing.refresh() }
            SafeBrowsing.startClock()
        }
        Startup.later("store icons") { StoreCatalog.shared.fetchIcons() }
    }

    /// Safari's export and Mail answer to this window.
    static func desks(for browser: Browser) {
        Startup.stage("desks") {
            SafariImport.Desk.shared.browser = browser
            MailDesk.shared.browser = browser
        }
        // Once ever, the first launch with a diary; the whole history is
        // read for it only then.
        Startup.later("diary") { [weak browser] in
            guard let browser else { return }
            Diary.shared.seed { browser.history.everything() }
            // Days from before threads, grouped once, on the diary's queue.
            Diary.shared.backfillThreads()
            // What only grew on disk (#685): the history's pictures past
            // their limit, the caches of sites no longer visited.
            Diary.shared.trimShots()
            SiteCaches.start()
        }
    }

    static func icons(for browser: Browser) {
        // An icon that arrives is put on every tab showing that site, not only
        // the one that happened to ask for it; not on one wearing the icon
        // its own page named (another Notion page's, a count): each
        // tab keeps its page's.
        Favicons.shared.arrived = { [weak browser] host, image in
            // On a link in an answer that asked for it.
            AnswerLinks.shared.arrived(host)
            guard let browser else { return }
            let all = BrowserWindows.shared.browsers.flatMap { $0.tabs + $0.parkedTabs }
            // Nor on one whose page wore an icon of its own when last seen
            // (Favicons.pageIcon): a slideshow's, not the Docs icon its
            // host keeps.
            for tab in all where tab.address.flatMap(Favicons.site) == host && !Favicons.shared.wearsOwn(tab) && !tab.awaitingDocumentMetadata {
                tab.icon = tab.address.flatMap(Favicons.shared.pageIcon) ?? image
            }
            // Readers use Favicons.shared.cached, which is observed.
        }
        // The sites the field knows from the start wear their own icons the
        // first time they are offered, not a letter: fetched once, quietly,
        // a little after launch, and only those not already on disk. Google's
        // G kept for its products before goes first, once (Favicons.tidy),
        // and off the tabs wearing it: a letter until their page names their
        // own, asked for at once where the page is open.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            let gone = Favicons.shared.tidy()
            if !gone.isEmpty {
                for tab in BrowserWindows.shared.browsers.flatMap({ $0.tabs + $0.parkedTabs })
                where gone.contains(tab.address?.host()?.lowercased() ?? "") {
                    tab.adoptIcon()
                    if tab.builtPage != nil, !tab.asleep { Favicons.shared.fetch(for: tab) }
                }
            }
            // Once: kept icons that draw nothing (ChatGPT's, feedback #368)
            // go, and their tabs show a letter until their page names one.
            Task {
                let blanked = await Favicons.shared.unblank()
                guard !blanked.isEmpty else { return }
                for tab in BrowserWindows.shared.browsers.flatMap({ $0.tabs + $0.parkedTabs })
                where blanked.contains(tab.address?.host()?.lowercased() ?? "") {
                    tab.adoptIcon()
                    if tab.builtPage != nil, !tab.asleep { Favicons.shared.fetch(for: tab) }
                }
            }
            for host in History.knownHosts { Favicons.shared.fetch(host: host) }
            // And once a day, the icons of sites long gone go from the disk.
            let tabs = BrowserWindows.shared.browsers.flatMap { $0.tabs + $0.parkedTabs }
            let keep = tabs.flatMap { [$0.address, $0.home].compactMap { $0 } }
                + Bookmarks.urls(Bookmarks.shared.roots)
            let visited = History.shared.lastVisits()
            Task { await Favicons.shared.prune(keep: keep, visited: visited) }
        }
    }

    /// The calendar, not while hidden for agents: it is for someone
    /// looking. Mail syncs only when it was turned on and has an account.
    /// Both once the launch is over: mail's reminders and notifications
    /// due meanwhile come then, a few seconds late. A window that opens on
    /// Mail, or goes there first, has it at once (`mailNow`).
    static func meetingsAndMail(for browser: Browser) {
        Startup.later("meetings") { if !Headless.hidden { Meetings.shared.start() } }
        Startup.later("mail") { [weak browser] in
            guard let browser else { return }
            mailNow(browser)
        }
    }

    private static var mailStarted = false

    /// Mail, now, if it is turned on and not started yet: the window shows
    /// it, or the launch is over.
    static func mailNow(_ browser: Browser? = Links.browser) {
        guard !mailStarted, let browser, browser.prefs.usesMail else { return }
        mailStarted = true
        Startup.stage("mail") { MailCenter.shared.turn(true) }
    }
}

@MainActor
private enum ConsentTestControl { static let listener = Bench() }
