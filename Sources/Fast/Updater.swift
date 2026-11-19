import AppKit
import Combine
import ServiceManagement
import YabUpdate

// Knowing when there is a newer one, and having it ready.
//
// No framework: one small JSON file next to the download, read every hour
// while the app is up and whenever asked. For a newer build, the ZIP is
// fetched quietly and checked beside this bundle. Once the app and its
// engine exit, the sealed helper puts it in place for the next launch.
// Chrome's way, without Chrome's machinery. A plain release relaunches on
// its own only once nobody is at the Mac (idle, locked or asleep) and
// nothing would be lost, as Arc does; a page you are reading is not
// interrupted by a browser that wants to be newer. A critical one restarts
// sooner, once nobody is using Yab (Away).
//
// What the updater leaves alone, on purpose: everything in
// ~/Library/Application Support/Yab, the defaults under
// the app's own bundle id, and the keychain. The session, the pins, the
// history, the passwords, none of it is read, moved or rewritten here. Only
// the bundle changes hands, and it keeps its bundle id and its signing
// identity, so the keychain items the old build made open for the new one.
// The updater deletes only what it made: its own scratch folder and the
// `.old` bundle it set aside.
//
// build.sh writes the file (build/appcast.json) at the same time as the DMG
// and the ZIP; publish.sh puts all three where `feed` points.
//
// The site can spread a release over hours (release.sh --rollout=HOURS):
// each Mac takes it at its own moment in that time, set by a number it
// rolled once and keeps (Rollout). A release marked critical (release.sh
// --critical) goes to every Mac at the first check, so to every copy that is
// up within the hour, and when it can't be put in place is tried again
// within the hour. Once it is in place Yab restarts for it by itself when
// nobody has used it for a while (Away): a fix for a build that keeps you
// from pressing Update, as 0.0.17's second build did by taking every click
// in the window, needs no press. Why the last one couldn't be put in place
// is said once, with the next check (Failure). The site counts each copy
// once a day all the same (Count). A Mac on Stable that updated less than a
// day ago waits out that day before the next build is offered (Settle); a
// Mac on Nightly takes every build on its turn.
//
// While the app is closed, a small agent in the bundle does the same
// (Sources/YabUpdater): launchd starts it at login and every four hours, and
// it puts a newer build in place, so a Yab nobody opened for a month opens
// as the current one, and a build that can't get as far as its own check
// still gets the next. The app enrolls it with SMAppService (Agent below).

@MainActor
@Observable final class Updater {
    static let shared = Updater()

    // The feed, the rules and the swap live in YabUpdate (Update.swift), so
    // the agent that updates a closed Yab (YabUpdater) runs the same code.
    // The names stay here so the app and its tests read as before.
    typealias Release = Update.Release
    typealias Rollout = Update.Rollout
    typealias Settle = Update.Settle
    typealias Failure = Update.Failure
    typealias Count = Update.Count

    nonisolated static var feed: URL? { Update.feed }
    nonisolated static var site: URL? { Update.site }
    nonisolated static var system: String { Update.system }
    static var enabled: Bool { Update.enabled }
    private static var overridden: Bool { Update.overridden }
    nonisolated static var version: String { Update.version }
    nonisolated static var build: Int { Update.build }
    nonisolated static let checkedKey = Update.checkedKey
    nonisolated static let nightlyKey = Update.nightlyKey
    nonisolated static let soonerKey = Update.soonerKey
    nonisolated static let interval = Update.interval
    nonisolated static let retry = Update.retry

    nonisolated static func due(now: Date, in defaults: UserDefaults) -> Bool {
        Update.due(now: now, in: defaults)
    }

    nonisolated static func checkURL(feed: URL, build: Int, system: String, failure: String?, again: Bool = false, nightly: Bool = false, arch: String? = nil) -> URL {
        Update.checkURL(feed: feed, build: build, system: system, failure: failure, again: again, nightly: nightly, arch: arch)
    }

    nonisolated static func parse(_ data: Data, allowingHTTP: Bool, architecture: String? = nil) -> Release? {
        Update.parse(data, allowingHTTP: allowingHTTP, architecture: architecture)
    }

    private static func fetch(failure: String?, again: Bool) async -> (reached: Bool, release: Release?) {
        await Update.fetch(failure: failure, again: again)
    }

    /// How far along the newer build is, when there is one.
    enum Stage: Equatable {
        /// None known, or this is the latest.
        case none
        /// The ZIP is on its way, or being looked over.
        case fetching(Release)
        /// Verified beside the running app; installed after its processes exit.
        case ready(Release)
        /// Can't be swapped in on this Mac at all (Failure.lasting: the
        /// folder Yab is in takes no rename, a copy with no signature to
        /// check the new one against), so the disk image is offered instead,
        /// the same as the first time.
        case offered(Release)
    }

    /// Where a build that was being fetched leaves the stage. In place, it
    /// is ready. One that couldn't be put in place sends this Mac to the
    /// disk image only when no update can ever go in here; any other
    /// failure (the download cut off, the Mac asleep halfway, a file in the
    /// way) was this attempt's, and the stage goes back to none, so Check
    /// Now and the hourly check try again in place. Every failure used to
    /// offer the disk image, and Update then downloaded a 280 MB DMG into the
    /// browser until Yab was quit (Alpha chat, 0.46.25).
    nonisolated static func landing(_ release: Release, failure: String?) -> Stage {
        guard let failure else { return .ready(release) }
        return Failure.lasting.contains(failure) ? .offered(release) : .none
    }

    private(set) var stage: Stage = .none
    /// True while the file is being fetched.
    private(set) var checking = false
    /// When the file was last read, for the line in Settings.
    private(set) var lastChecked: Date?
    /// The newer build whose last try to go in place failed for a reason
    /// that may pass (`landing`): Settings names it, with Check Now, rather
    /// than calling this one up to date.
    private(set) var missed: Release?
    /// Where a line goes when there is one to say, handed over at launch.
    @ObservationIgnored private var say: ((String) -> Void)?

    private init() {
        // A normal quit installs too, after the engine has gone. The helper
        // waits for process exits; no bundle moves from this callback.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.installOnQuit() }
        }
    }

    /// At launch: once an hour, quietly. A test run, pointed at its own feed,
    /// checks every time.
    func checkIfDue(then say: @escaping (String) -> Void) {
        self.say = say
        Swap.sweep()
        guard Updater.enabled else { return }
        if case .none = stage, let waiting = Swap.prepared,
           waiting.release.build > Updater.build || (waiting.allowDowngrade && waiting.release.build != Updater.build) {
            stage = .ready(waiting.release)
            restartWhenAway()
        }
        Agent.enroll()
        // The day between updates counts from now if this build is new here.
        _ = Settle.since(build: Updater.build, in: Store.settings, now: Date())
        Away.start()
        // Asked every ten minutes whether the hour is up, for as long as the
        // app is up: on the hour itself, a tick a moment early would put the
        // check off to the next hour.
        if clock == nil {
            clock = Timer.scheduledTimer(withTimeInterval: 60 * 10, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkIfDue() }
            }
            clock?.tolerance = 60
        }
        checkIfDue()
    }

    @ObservationIgnored private var clock: Timer?

    private func checkIfDue() {
        guard Updater.overridden || Updater.due(now: Date(), in: Store.settings) else { return }
        check(asked: false) { _ in }
    }


    /// Now. `asked` is someone asking, Check Now, which never waits for this
    /// Mac's turn in a rollout or the Stable day, and asks the saved
    /// channel's feed like any check: a Stable copy is never offered a build
    /// still soaking on Nightly (register 1689). `done` gets the newer build the feed names,
    /// or nil when this is the latest or it isn't this Mac's turn; what
    /// becomes of it after that is said through the line handed to
    /// `checkIfDue`.
    func check(asked: Bool = true, then done: @escaping (Release?) -> Void) {
        guard Updater.enabled else {
            done(nil)
            return
        }
        guard !checking else { return }
        checking = true
        let defaults = Store.settings
        let failure = Failure.pending(in: defaults)
        let again = Count.again(in: defaults, now: Date())
        let channel = defaults.bool(forKey: Updater.nightlyKey)
        Task { [weak self] in
            let (reached, found) = await Updater.fetch(failure: failure, again: again)
            guard let self else { return }
            checking = false
            if reached, let failure { Failure.delivered(failure, in: defaults) }
            let now = Date()
            if reached { Count.counted(in: defaults, now: now) }
            lastChecked = now
            defaults.set(now, forKey: Updater.checkedKey)
            defaults.removeObject(forKey: Updater.soonerKey)
            // A response from the previous channel cannot install after a toggle.
            guard defaults.bool(forKey: Updater.nightlyKey) == channel else { done(nil); return }
            guard let found, found.isUpdate(from: Updater.version, build: Updater.build, asked: asked), found.runsHere else {
                // A build already swapped in stays ready whatever the feed
                // says now.
                if case .ready = stage {} else { stage = .none }
                missed = nil
                done(nil)
                return
            }
            // Not this Mac's turn yet, or, on Stable, this Mac took its last
            // update less than a day ago: nothing on screen says so, and the
            // file is read again when it is.
            let dice = Rollout.dice(in: defaults)
            let settled = Settle.since(build: Updater.build, in: defaults, now: now)
            // A build waiting for its restart is replaced without the Stable
            // day: that restart is asked for already, the newer build only
            // makes it the newest (register 1365).
            var waiting = false
            if case .ready = stage { waiting = true }
            let nightly = defaults.bool(forKey: Updater.nightlyKey) || waiting
            if let wait = Settle.wait(found, dice: dice, since: settled, now: now, asked: asked, nightly: nightly) {
                defaults.set(wait, forKey: Updater.soonerKey)
                done(nil)
                return
            }
            // On its way before anyone is told: the Yab menu's answer is a
            // modal alert that says it is downloading, and the download
            // waited behind it until OK was pressed.
            take(found)
            done(found)
        }
    }

    /// After Nightly is turned off, wait for an already-started swap before
    /// offering Stable. Its replacement must preserve the running .old bundle.
    func stableBehind() async -> Release? {
        guard Updater.enabled else { return nil }
        while checking || replacing != nil || fetching {
            guard !Store.settings.bool(forKey: Updater.nightlyKey), !Task.isCancelled else { return nil }
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return nil }
        }
        guard !Store.settings.bool(forKey: Updater.nightlyKey) else { return nil }
        let (_, found) = await Updater.fetch(failure: nil, again: true)
        guard !Store.settings.bool(forKey: Updater.nightlyKey) else { return nil }
        let build: Int
        if case .ready(let staged) = stage { build = staged.build } else { build = Updater.build }
        return found.flatMap { $0.isBehind(build: build) ? $0 : nil }
    }

    private var fetching: Bool {
        if case .fetching = stage { return true }
        return false
    }

    /// Only the existing Go back to Stable confirmation calls this. Routine
    /// checks and the background updater still refuse older builds.
    func installStable(_ release: Release) {
        guard !Store.settings.bool(forKey: Updater.nightlyKey), release.runsHere else { return }
        take(release, allowDowngrade: true)
    }

    /// Fetch it, check it, swap it in, unless one is already on its way.
    /// One already in place gives way to a newer one: a copy that waited
    /// through a newer release used to restart into the older build and at
    /// once offer the newer, one update per release it missed (register
    /// 1365). The newer one takes the place of the one in place, never of
    /// the bundle this process runs from (`.old`, Swap.replace), and the one
    /// in place stays ready, Restart and all, until it has.
    private func take(_ release: Release, allowDowngrade: Bool = false) {
        let staged: Int?
        switch stage {
        case .fetching: return
        case .ready(let inPlace):
            guard replacing == nil, release.replaces(inPlace)
                    || (allowDowngrade && release.build != inPlace.build && release.runsHere) else { return }
            replacing = release
            staged = inPlace.build
        case .none, .offered:
            stage = .fetching(release)
            missed = nil
            staged = nil
        }
        Task.detached(priority: .utility) {
            let failure: String?
            do {
                try await Swap.install(release, replacing: staged, allowDowngrade: allowDowngrade, deferUntilExit: true)
                failure = nil
            } catch {
                failure = Failure.reason(error)
            }
            await MainActor.run { [weak self] in self?.landed(release, failure: failure) }
        }
    }

    /// The newer build on its way to take the place of the one in place.
    @ObservationIgnored private var replacing: Release?

    private func landed(_ release: Release, failure: String?) {
        if replacing == release {
            replacing = nil
            // The one in place stays ready if this couldn't be put there;
            // why is said to the site all the same.
            guard let failure else {
                stage = .ready(release)
                restartWhenAway()
                return
            }
            Failure.keep(failure, in: Store.settings)
            return
        }
        guard case .fetching(let fetching) = stage, fetching == release else { return }
        // The Update button and the note written by it say so (UpdateDoodle).
        stage = Updater.landing(release, failure: failure)
        if stage == .none { missed = release }
        guard let failure else {
            // The Stable day starts when the helper actually installs it.
            restartWhenAway()
            return
        }
        let defaults = Store.settings
        Failure.keep(failure, in: defaults)
        if let sooner = Failure.retry(release, after: failure, now: Date()) {
            defaults.set(sooner, forKey: Updater.soonerKey)
        }
    }

    /// A minute's tick while a build waits in place, until it may restart
    /// for it (Away.restarts): a critical one once nobody is using Yab, any
    /// other once nobody is at the Mac, as Arc does. Then it restarts, as
    /// Update would.
    @ObservationIgnored private var awayClock: Timer?

    private func restartWhenAway(every tick: TimeInterval = 60) {
        guard awayClock == nil else { return }
        awayClock = Timer.scheduledTimer(withTimeInterval: tick, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, case .ready(let release) = self.stage, Away.restarts(for: release) else { return }
                self.awayClock?.invalidate()
                self.awayClock = nil
                self.relaunch(behind: !NSApp.isActive)
            }
        }
        awayClock?.tolerance = min(10, tick / 4)
    }

    /// A test run's update in place without a swap: the stage as a swapped
    /// build leaves it, so evals/updates/away.py can watch Yab restart for it
    /// with the tick it gives.
    func benchReady(critical: Bool, tick: TimeInterval) {
        guard Store.testing else { return }
        let here = URL(fileURLWithPath: "/dev/null")
        stage = .ready(Release(version: "9.9.9", build: Updater.build + 1, archive: here, dmg: here,
                               sha256: nil, notes: nil, minimumSystemVersion: nil, critical: critical))
        awayClock?.invalidate()
        awayClock = nil
        restartWhenAway(every: tick)
    }

    /// The sealed updater helper waits for this process to exit and asks
    /// LaunchServices to open its own app. Quit only after it has started.
    func relaunch(behind: Bool = false) {
        LaunchJournal.record("update.relaunch", target: Bundle.main.bundleURL)
        let build: Int?
        if case .ready = stage, let waiting = Swap.prepared { build = waiting.release.build }
        else { build = nil }
        do { try Relaunch.start(bundle: Bundle.main.bundleURL, behind: behind, installing: build) }
        catch { return }
        finishing = true
        Links.leaving = true
        NSApp.terminate(nil)
    }

    @ObservationIgnored private var finishing = false

    private func installOnQuit() {
        guard !finishing, let waiting = Swap.prepared,
              waiting.release.build > Updater.build || (waiting.allowDowngrade && waiting.release.build != Updater.build) else { return }
        do {
            try Relaunch.start(bundle: Bundle.main.bundleURL, installing: waiting.release.build, reopen: false)
            finishing = true
        } catch {
            Failure.keep(Failure.reason(error), in: Store.settings)
            NSLog("Yab: couldn't start the prepared update installer: %@", String(describing: error))
        }
    }


    /// The agent that updates Yab while it is closed (YabUpdater), from
    /// Contents/Library/LaunchAgents in this bundle. Enrolled at launch when
    /// it never was, which macOS says once with its own notice; once someone
    /// has turned it off in Login Items, it stays off: only `.notRegistered`
    /// is enrolled, never a copy waiting for approval. A build without the
    /// plist (a development build) answers `.notFound` and is left alone.
    enum Agent {
        static let plist = "YabUpdater.plist"

        /// Off the main thread: both calls go to the system and wait for it.
        static func enroll() {
            guard !Store.testing else { return }
            Task.detached(priority: .utility) {
                let agent = SMAppService.agent(plistName: plist)
                guard agent.status == .notRegistered else { return }
                try? agent.register()
            }
        }
    }

    /// When Yab may restart by itself for a build in place, and what would
    /// keep it from it.
    ///
    /// A critical build: once nobody is using Yab, behind another app for
    /// ten minutes or the Mac untouched for as long. Any other build (Arc's
    /// Automatic Updates, since its 1.42): once nobody is at the Mac, no
    /// input for half an hour, or the screen locked, the screen saver on or
    /// the display asleep for five minutes. Behind another app is not
    /// enough for it: someone at work in another app is still at the Mac.
    /// Off in Settings › General (Update automatically, `automaticKey`),
    /// only a critical build restarts by itself.
    ///
    /// Either way, nothing in Yab may go on that a restart would cut off or
    /// lose: a call, the screen or a tab shared, a download, a tab making
    /// sound, an agent at work, a question waiting for its answer,
    /// something typed and not sent, a private tab (it has no place in the
    /// session), a dialog or sheet open. The tabs come back after, as after
    /// ⌘Q. Held, it waits for the next time.
    @MainActor enum Away {
        nonisolated static let after: TimeInterval = 10 * 60
        /// No input for this long: nobody is at the Mac.
        nonisolated static let idle: TimeInterval = 30 * 60
        /// Locked, the screen saver on or the display asleep this long.
        nonisolated static let unattended: TimeInterval = 5 * 60
        nonisolated static let automaticKey = "update.automatic"

        /// Restarts for updates by itself; on unless turned off.
        static var automatic: Bool { Store.settings.object(forKey: automaticKey) as? Bool ?? true }

        /// Since when Yab has been behind another app; nil while in front.
        private static var behindSince: Date?
        /// What says nobody is at the screen, and since when one of them has.
        private static var locked = false, saver = false, asleep = false
        private static var unattendedSince: Date?
        /// A test run's input idle, in place of the real one.
        private static var benchIdle: TimeInterval?
        private static var watching: [NSObjectProtocol] = []

        static func start() {
            guard watching.isEmpty else { return }
            behindSince = NSApp.isActive ? nil : Date()
            let center = NotificationCenter.default
            let workspace = NSWorkspace.shared.notificationCenter
            let distributed = DistributedNotificationCenter.default()
            func on(_ center: NotificationCenter, _ name: Notification.Name, _ then: @escaping @MainActor () -> Void) -> NSObjectProtocol {
                center.addObserver(forName: name, object: nil, queue: .main) { _ in MainActor.assumeIsolated { then() } }
            }
            watching = [
                on(center, NSApplication.didResignActiveNotification) { behindSince = Date() },
                on(center, NSApplication.didBecomeActiveNotification) { behindSince = nil },
                on(distributed, .init("com.apple.screenIsLocked")) { locked = true; revise() },
                on(distributed, .init("com.apple.screenIsUnlocked")) { locked = false; revise() },
                on(distributed, .init("com.apple.screensaver.didstart")) { saver = true; revise() },
                on(distributed, .init("com.apple.screensaver.didstop")) { saver = false; revise() },
                on(workspace, NSWorkspace.screensDidSleepNotification) { asleep = true; revise() },
                on(workspace, NSWorkspace.screensDidWakeNotification) { asleep = false; revise() },
                // The Mac waking: the night it slept through doesn't count,
                // someone may be at the lock screen now. Five minutes again.
                on(workspace, NSWorkspace.didWakeNotification) { if unattendedSince != nil { unattendedSince = Date() } },
            ]
        }

        private static func revise() {
            if !(locked || saver || asleep) {
                unattendedSince = nil
            } else if unattendedSince == nil {
                unattendedSince = Date()
            }
        }

        /// A test run as if the Mac had no input for `idle` seconds, and was
        /// locked `lockedFor` seconds ago (nil: unlocked). Nothing else is
        /// faked: what holds a restart is read from the app as it is.
        static func bench(idle: TimeInterval?, lockedFor: TimeInterval?) {
            guard Store.testing else { return }
            benchIdle = idle
            locked = lockedFor != nil
            revise()
            if let lockedFor { unattendedSince = Date().addingTimeInterval(-lockedFor) }
        }

        private static var inputIdle: TimeInterval {
            // Any input at all, the keyboard's, the mouse's or the trackpad's.
            benchIdle ?? CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        }

        static func restarts(for release: Release) -> Bool {
            let now = Date()
            return restarts(critical: release.critical, automatic: automatic, idle: inputIdle,
                            behind: behindSince.map { now.timeIntervalSince($0) },
                            unattended: unattendedSince.map { now.timeIntervalSince($0) }, holding: holding)
        }

        /// Nobody using Yab, the critical rule: behind another app or the Mac
        /// untouched for ten minutes.
        nonisolated static func quiet(idle: TimeInterval, behind: TimeInterval?, busy: Bool) -> Bool {
            !busy && (idle >= after || (behind ?? 0) >= after)
        }

        /// Nobody at the Mac: no input for half an hour, or the screen
        /// locked, saving or asleep for five minutes.
        nonisolated static func absent(idle: TimeInterval, unattended: TimeInterval?) -> Bool {
            idle >= Away.idle || (unattended ?? -1) >= Away.unattended
        }

        /// Whether to restart for a build in place now.
        nonisolated static func restarts(critical: Bool, automatic: Bool, idle: TimeInterval, behind: TimeInterval?,
                                         unattended: TimeInterval?, holding: String?) -> Bool {
            guard holding == nil else { return false }
            if critical || automatic, absent(idle: idle, unattended: unattended) { return true }
            return critical && quiet(idle: idle, behind: behind, busy: false)
        }

        /// What goes on in Yab, as a restart sees it.
        struct Going {
            var call = false, sharing = false, download = false, sound = false, agent = false
            var question = false, unsent = false, privateTab = false, dialog = false
        }

        /// What a restart now would cut off, in a word; nil for nothing.
        nonisolated static func holding(_ going: Going) -> String? {
            if going.call { return "call" }
            if going.sharing { return "sharing" }
            if going.download { return "download" }
            if going.sound { return "sound" }
            if going.agent { return "agent" }
            if going.question { return "question" }
            if going.unsent { return "unsent" }
            if going.privateTab { return "private" }
            if going.dialog { return "dialog" }
            return nil
        }

        static var holding: String? {
            let browsers = BrowserWindows.shared.browsers
            var going = Going()
            going.call = browsers.contains(where: { $0.calls.any })
            going.sharing = !Share.shared.sessions.isEmpty
            going.download = browsers.contains(where: { !$0.hoard.going.isEmpty })
            going.sound = browsers.contains(where: { $0.everyTab.contains(where: \.noisy) })
            going.agent = !Links.agentsAtWork.isEmpty
            going.question = Questions.shared.current != nil
            // As the tab card's "Not sent" and Sleep's keeping a tab awake.
            going.unsent = browsers.contains(where: { $0.everyTab.contains(where: \.draft) })
            // A private tab has no place in the session: a restart loses it.
            going.privateTab = browsers.contains(where: { $0.everyTab.contains(where: \.shy) })
            // A save panel, a page's alert, a sheet halfway through.
            going.dialog = NSApp.modalWindow != nil || NSApp.windows.contains { $0.isVisible && $0.attachedSheet != nil }
            return holding(going)
        }
    }
}

/// The swap itself is in YabUpdate; the name stays for the app and its tests.
typealias Swap = YabUpdate.Swap
