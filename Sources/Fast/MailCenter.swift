import AppKit
import AuthenticationServices
import Foundation
import SwiftUI

// The mail accounts this Mac keeps and the rhythm they are synced to
// (docs/mail.md, Sync). Nothing here runs until Settings › Mail is on and an
// account is connected: no timer, no store, no request.
//
// Gmail's push needs a server of its own, so this asks (MailCadence):
// every 2 seconds while a box waits for a code, every 10 while the mail
// page is in front, 15 while yab is, 30 behind other apps when a
// notification would say what came and five when none would, and not at
// all while the Mac sleeps or saves power; at once when it wakes, the screen
// is unlocked or the network comes back. One timer, set for the next ask
// due, and an ask that finds nothing new changes nothing on screen. What you
// did goes out right after each sync, even one that fell short. When Gmail
// keeps saying slow down, the account rests: two minutes, then longer each
// time, up to fifteen.

@MainActor
@Observable final class MailCenter {
    static let shared = MailCenter()

    struct Engine {
        let account: String
        let store: MailStore
        /// Its server behind the seam (MailProvider): Gmail, or IMAP.
        let provider: any MailProvider
        let sync: any MailSyncing
        /// Its line to Gmail, kept open between asks (MailWire).
        var wire: MailWire? = nil
        /// Gmail's own client, for what only Gmail has: its calendar, the
        /// memory's years of mail, its search words.
        var gmail: MailGmail? { provider as? MailGmail }
        var kind: MailProviderKind { provider.kind }
    }

    /// The server an account lives on, as kept when it was added: Gmail
    /// unless said otherwise (every account before M3 is Gmail's).
    static func kind(of account: String) -> MailProviderKind {
        Store.settings.string(forKey: "mail.provider.\(account)").flatMap(MailProviderKind.init(rawValue:)) ?? .gmail
    }

    struct Status: Equatable {
        var synced: Date?
        var syncing = false
        /// What went wrong last, said for a person, or nil.
        var trouble: String?
        /// Google took Yab's access back: Sign In Again, not a wait.
        var signedOut = false
        /// Gmail said slow down: the trouble is a wait, nothing to do.
        var resting = false
    }

    /// How long a sent mail waits for ⌘Z: Settings › Mail's Undo send.
    static var undoSend: TimeInterval {
        let kept = Store.settings.double(forKey: "mail.undo")
        return [5, 10, 20].contains(kept) ? kept : 5
    }

    /// Settings › Mail › Agents' Mail you hand to Claude: D, and the mail
    /// tools a task is given. Off until the person turns it on (MailConsent).
    static var agentsAllowed: Bool { Store.settings.bool(forKey: MailConsent.agentsKey) }

    /// Threads that need you, over every account: the mail pin says it.
    private(set) var needYou = 0
    /// The one number the mail pin, the column's door and the Dock show,
    /// as Settings › Mail's Count says (MailNotify.Badge); 0 shows none.
    private(set) var counted = 0
    private(set) var accounts: [String] = []
    /// Accounts kept out of All Accounts (Settings › Mail's Show in All
    /// Accounts, off): their own inbox and count stay, the combined lists,
    /// counts, the pin and the Dock leave them out (MailAllAccounts).
    private(set) var apart: Set<String> = []
    private(set) var status: [String: Status] = [:]
    /// Moves every time a store changes, for whatever shows mail: a beat
    /// after the change (`note`), all the changes of one turn of the run
    /// loop together. Told inside a key, it drew everything that watches
    /// the center again before the key's own screen was drawn.
    private(set) var changed = 0 {
        didSet { recount() }
    }
    @ObservationIgnored private var noting = false

    /// A store changed: `changed` moves once the screen in front is drawn.
    private func note() {
        guard !noting else { return }
        noting = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            noting = false
            changed += 1
            // A sign-in link may have come for the page in front.
            MailLinks.look()
        }
    }
    /// A sign-in waiting for Google's answer.
    private(set) var connecting = false
    /// Google said no, or its window was closed: mail's front door says so
    /// (MailFrontDoor) and offers it again.
    private(set) var connectFailed = false
    /// An account just connected from Settings › Mail, until its way in
    /// has said once where mail is (MailArrival).
    private(set) var landed: String?
    /// The mail pin, a door to mail's space: put when the first account
    /// comes in, and on until you take it away (unpin it, or
    /// Settings › Mail); back from there, or the field's Pin Mail.
    private(set) var pinWanted = Store.settings.object(forKey: "mail.pin") as? Bool ?? true

    @ObservationIgnored private(set) var engines: [String: Engine] = [:] { didSet { relink() } }
    /// The next beat: set for when the soonest ask is due, not a tick.
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var last: [String: Date] = [:]
    /// Accounts asking Gmail now, and those asked again meanwhile, which
    /// ask once more as soon as the first is done.
    @ObservationIgnored private var running: Set<String> = []
    /// Each account's sync running now, stopped when the account goes.
    @ObservationIgnored private var syncing: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var again: Set<String> = []
    /// When each account last heard from Gmail, told or not (Status.synced
    /// is told at most once a minute while nothing changes).
    @ObservationIgnored private(set) var heard: [String: Date] = [:]
    /// Asks made at once, by why, for the bench: wake, unlock, network.
    @ObservationIgnored private(set) var checks: [String: Int] = [:]
    @ObservationIgnored private var network: MailNetwork?
    @ObservationIgnored private var unlock: MailUnlock?
    /// Accounts Gmail told to slow down: not asked again before then, and
    /// how long the last rest was.
    @ObservationIgnored private var rest: [String: (until: Date, length: TimeInterval)] = [:]
    @ObservationIgnored private var quickUntil = Date.distantPast
    /// The mail page is in front (MailPage): asked every 10 seconds.
    @ObservationIgnored var pageInFront = false {
        didSet { if pageInFront != oldValue { schedule() } }
    }
    @ObservationIgnored private var signIn: MailSignIn?
    /// The Mac's sign-in sheet Google's consent page is in (#456).
    @ObservationIgnored private var signInSheet: GoogleSignInSheet?
    @ObservationIgnored private var signInTab: Tab.ID?
    /// The space the sign-in's tab was opened in, when that meant leaving
    /// the one on screen: gone back to once Google has answered.
    @ObservationIgnored private var signInLeft: UUID?
    /// Whether the sign-in's peek is over the mail page.
    @ObservationIgnored private var signInOver = false
    @ObservationIgnored private var signInFromSettings = false
    @ObservationIgnored private var asleep = false
    @ObservationIgnored private var on = false { didSet { relink() } }

    private init() {
        accounts = Store.settings.stringArray(forKey: "mail.accounts") ?? []
        apart = MailAllAccounts.apart(accounts, in: Store.settings)
        MailConsent.migrate()
        // Gmail's answers an older Yab left in the app's shared cache, once.
        DispatchQueue.global(qos: .utility).async { MailWire.sweepCache() }
        // Tokens an older Yab kept in the login keychain: into this Mac's.
        DispatchQueue.global(qos: .utility).async { MailKeychain.moveToThisDevice() }
        // A token a Disconnect couldn't take back at Google (offline): again.
        if !(Store.settings.stringArray(forKey: MailRevoke.key) ?? []).isEmpty { Task { await MailRevoke.retry() } }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.asleep = true
                self?.schedule()
            }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.asleep = false
                self?.now("wake")
            }
        }
        // Someone is back at the Mac.
        unlock = MailUnlock { MailCenter.shared.now("unlock") }
        // Yab in front or behind, Low Power on or off: another rhythm.
        let local = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification, .NSProcessInfoPowerStateDidChange] {
            local.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.schedule() }
            }
        }
    }

    // MARK: - on and off

    /// Settings › Mail's switch, and the start of the app.
    func turn(_ wanted: Bool) {
        on = wanted && MailExperiment.enabled()
        guard on, !accounts.isEmpty else {
            timer?.invalidate()
            timer = nil
            network?.stop()
            network = nil
            recount()
            return
        }
        // Each store opened off the main thread: an update's migration of a
        // mailbox of 50,000 took the main thread a second or two at launch.
        for account in accounts where engines[account] == nil && Self.runs(account) { open(account) }
        MailNotify.shared.start()
        if network == nil {
            network = MailNetwork { Task { @MainActor in MailCenter.shared.now("network") } }
        }
        tick()
    }

    /// Stores being opened, off the main thread (`open`): mail shows each
    /// account once its store is ready, the front door not offered meanwhile.
    private(set) var opening: Set<String> = []

    /// An account's engine, its store opened (and brought up to date by its
    /// migrations) off the main thread, the engine made on it after.
    private func open(_ account: String) {
        guard opening.insert(account).inserted else { return }
        let file = MailStore.file(for: account)
        Task.detached(priority: .userInitiated) {
            let store = MailStore(file: file)
            await MainActor.run {
                let center = MailCenter.shared
                center.opening.remove(account)
                // Disconnected, or made by Connect, meanwhile.
                guard center.on, center.accounts.contains(account), center.engines[account] == nil else { return }
                center.make(account, store: store)
                center.note()
                center.tick()
            }
        }
    }

    /// IMAP accounts share Mail's experimental opt-in.
    static func runs(_ account: String) -> Bool {
        kind(of: account) != .imap || MailServerSetup.kept(account, in: Store.settings)?.provider == "gmail" || MailExperiment.otherAccounts()
    }

    private func make(_ account: String, gmail: MailGmail? = nil, store kept: MailStore? = nil) {
        if Self.kind(of: account) == .imap { return makeIMAP(account, store: kept) }
        guard var gmail = gmail ?? MailClient.configured.map({ client in
            let auth = MailAuth(account: account, client: client)
            return MailGmail(token: { try await auth.token() }, pace: MailPace(burst: MailPace.burst))
        }) else { return }
        // A line of its own, unless it came with one (a test's).
        let wire = gmail.session === MailGmail.uncached ? MailWire() : nil
        if let wire { gmail.session = wire.session }
        let store = kept ?? MailStore(file: MailStore.file(for: account))
        MailNotify.begin(store)
        // Files of drafts the store let go of while Yab was away.
        MailAttach.sweep(store)
        let sync = MailSync(store: store, gmail: gmail) { Task { @MainActor in MailCenter.shared.touch() } }
        engines[account] = Engine(account: account, store: store, provider: gmail, sync: sync, wire: wire)
        MailRecall.shared.attach(engines[account]!)
        // Its files, beside its store; its syncs fetch the newest ahead.
        MailFiles.attach(store, provider: gmail)
    }

    /// An IMAP account's engine (docs/mail-providers.md, M3): its servers
    /// as kept, its password from the keychain when a line opens, IDLE's
    /// news a sync at once.
    private func makeIMAP(_ account: String, store kept: MailStore?) {
        guard Self.runs(account), let setup = MailServerSetup.kept(account, in: Store.settings) else { return }
        let store = kept ?? MailStore(file: MailStore.file(for: account))
        MailNotify.begin(store)
        MailAttach.sweep(store)
        let imap = MailIMAPAccount(setup: setup, store: store, password: {
            guard let password = MailSecret.password(for: account) else { throw MailTrouble.signedOut }
            return password
        }, told: { Task { @MainActor in MailCenter.shared.pushed(account) } })
        engines[account] = Engine(account: account, store: store, provider: imap, sync: imap)
        MailFiles.attach(store, provider: imap)
    }

    /// The server told of new mail (IMAP IDLE): that account asked now.
    func pushed(_ account: String) {
        checks["idle", default: 0] += 1
        touch()
        guard on, !asleep, let engine = engines[account] else { return }
        run(engine)
    }

    /// What an account's server is called where trouble is said.
    func serverName(_ account: String) -> String {
        guard Self.kind(of: account) == .imap else { return "Gmail" }
        let setup = MailServerSetup.kept(account, in: Store.settings)
        return MailKnownProviders.by(id: setup?.provider ?? "")?.name ?? setup?.imapHost ?? "The mail server"
    }

    /// An IMAP account in: its servers kept, its password in the keychain,
    /// its engine made and its first sync started.
    func addIMAP(_ setup: MailServerSetup, password: String) {
        let account = setup.address.lowercased()
        Store.settings.set(MailProviderKind.imap.rawValue, forKey: "mail.provider.\(account)")
        // Its calendar isn't Google's.
        Store.settings.set(false, forKey: MeetingsGoogle.key(account))
        setup.saved(in: Store.settings)
        MailSecret.save(password: password, for: account)
        // The first one lands as Gmail's does; another just joins the list.
        let first = accounts.isEmpty
        add(account)
        if first { landed = account }
    }

    /// Sync every 2 seconds for a while: a box is waiting for a code.
    func quick(for seconds: TimeInterval) {
        guard on, !engines.isEmpty else { return }
        quickUntil = max(quickUntil, Date().addingTimeInterval(seconds))
        tick()
    }

    /// An account's rhythm now (MailCadence): seconds between asks, or nil.
    func cadence(for account: String) -> TimeInterval? {
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        return MailCadence.every(MailCadence.State(
            quick: Date() < quickUntil, asleep: asleep, lowPower: lowPower, lowBattery: Thrift.on && !lowPower,
            // The page on screen, even behind another app's window: someone
            // is looking at the list.
            mailInFront: pageInFront, active: NSApp?.isActive == true, notifying: MailNotify.shared.wants(account)))
    }

    /// From an account's last ask to its next: its rhythm, or 2 seconds
    /// while a first sync cut short still has mail to bring, as soon as its
    /// rest is over rather than five minutes off.
    private func due(_ engine: Engine) -> TimeInterval? {
        guard let every = cadence(for: engine.account) else { return nil }
        return engine.store.value("history") == nil ? min(every, 2) : every
    }

    /// Notifications turned on or off, or allowed: another rhythm.
    func cadenceChanged() { schedule() }

    /// Held while Yab runs, so `yab mail flush` leaves what is due to it.
    private let waker = MailLock(MailLater.lockFile)

    /// Snoozed threads whose time came, or that someone wrote in, back; and
    /// mail of yours nobody answered by its reminder (MailFollowups).
    private func wake(_ engine: Engine) {
        if waker.take() {
            let due = MailOps.wakeDue(engine.store)
            let reminded = MailFollowups.check(engine.store)
            if !due.isEmpty || !reminded.isEmpty { note() }
            if !due.isEmpty || !reminded.fired.isEmpty { Task { try? await MailOps.flush(engine.store, provider: engine.provider) } }
            // Nobody answered by its reminder: said, "Mila hasn’t answered".
            if !reminded.fired.isEmpty { Task { await MailNotify.shared.reminded(engine, threads: reminded.fired) } }
        }
        MailLater.keepAgent(MailLater.waiting([engine.store]) || engines.values.contains { MailLater.waiting([$0.store]) })
    }

    /// What is due woken now, not at the next beat (the bench's time
    /// moved on).
    func wakeNow() {
        for engine in engines.values { wake(engine) }
    }

    /// The beat: snoozed threads whose time came go back, mail nobody
    /// answered by its reminder comes back, and every account whose ask is
    /// due asks; then the timer is set for the next one due.
    private func tick() {
        timer = nil
        guard on else { return }
        for engine in engines.values { wake(engine) }
        let now = Date()
        if !asleep {
            for engine in engines.values where !running.contains(engine.account) {
                guard let every = due(engine), now >= rest[engine.account]?.until ?? .distantPast,
                      now.timeIntervalSince(last[engine.account] ?? .distantPast) >= every - 0.05 else { continue }
                run(engine)
            }
        }
        schedule()
    }

    /// One timer, for when the soonest account is due, a snoozed thread
    /// comes back or a reminder comes due, so a Mac at rest wakes for mail
    /// only then. It used to tick every 2 seconds whatever was due.
    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard on, !asleep, !engines.isEmpty else { return }
        let now = Date()
        let asks = engines.values.filter { !running.contains($0.account) }.map { engine in
            (last: last[engine.account] ?? .distantPast, every: due(engine), rest: rest[engine.account]?.until)
        }
        // Only what is still ahead: one gone by that couldn't wake yet (the
        // wake lock held by `yab mail flush`, a thread not here yet) waits
        // for the next ask rather than spinning the timer.
        let snoozed = engines.values.compactMap { engine in
            (engine.store.snoozes().compactMap(\.until) + engine.store.followups().filter { $0.fired == nil }.map(\.until)).filter { $0 > now }.min()
        }.min()
        guard let at = MailCadence.next(asks: asks, snoozed: snoozed, now: now) else { return }
        let wait = at.timeIntervalSince(now)
        let timer = Timer(timeInterval: max(wait, 0.05), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // Room to fall in with the Mac's other wakes: a tenth of the wait.
        timer.tolerance = min(5, max(0.1, wait / 10))
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Every account asked at once, whatever the beat says: the Mac woke,
    /// the screen was unlocked, the network came back. Not in Low Power,
    /// and not one asked a moment ago: these often come together. `pressed`:
    /// someone reloaded Mail, Low Power or not.
    func now(_ why: String, pressed: Bool = false) {
        checks[why, default: 0] += 1
        // The network back: a token a Disconnect couldn't take back, again.
        if why == "network", !(Store.settings.stringArray(forKey: MailRevoke.key) ?? []).isEmpty { Task { await MailRevoke.retry() } }
        guard on, !asleep else { return }
        let at = Date()
        for engine in engines.values where (pressed || cadence(for: engine.account) != nil) && at >= rest[engine.account]?.until ?? .distantPast
            && (pressed || at.timeIntervalSince(last[engine.account] ?? .distantPast) > 2) {
            run(engine)
        }
        schedule()
    }

    /// One sync, then whatever you did goes out, even when the sync fell
    /// short: a thread archived here shouldn't wait on a list from Gmail.
    /// Off the main thread, back once with what came of it. Asked again
    /// while it runs, it runs once more right after.
    func run(_ engine: Engine) {
        let account = engine.account
        guard running.insert(account).inserted else {
            again.insert(account)
            return
        }
        last[account] = Date()
        // Said only while the first sync reads (MailEmpty).
        if status[account]?.synced == nil, status[account]?.syncing != true { status[account, default: Status()].syncing = true }
        let store = engine.store, sync = engine.sync, provider = engine.provider
        syncing[account] = Task.detached(priority: .utility) { [weak self] in
            var failed: Error?
            var news = false
            do { news = try await sync.sync() } catch { failed = error }
            if failed as? MailTrouble != .signedOut {
                // What was waiting to go out changes lists when it goes, or gives up.
                if store.pendingOps > 0 { news = true }
                do { try await MailOps.flush(store, provider: provider) } catch { failed = failed ?? error }
            }
            let came = news, trouble = failed
            await MainActor.run { self?.ran(engine, news: came, failed: trouble) }
        }
    }

    /// A sync done: its trouble said, and only when something came, the
    /// lists, the sorting and what notifications say.
    private func ran(_ engine: Engine, news: Bool, failed: Error?) {
        let account = engine.account
        running.remove(account)
        // Disconnected meanwhile: nothing more of it.
        guard engines[account]?.store === engine.store else {
            again.remove(account)
            return schedule()
        }
        syncing[account] = nil
        var trouble: String?
        var out = false
        switch failed {
        case nil:
            rest[account] = nil
        case MailTrouble.signedOut?:
            trouble = engine.kind == .imap ? "\(serverName(account)) stopped accepting the password" : "Google stopped letting Yab in"
            out = true
        case MailTrouble.offline?:
            trouble = nil
        case MailTrouble.limited?:
            let length = min(900, max(120, (rest[account]?.length ?? 60) * 2))
            rest[account] = (Date().addingTimeInterval(length), length)
            trouble = "Gmail asked Yab to slow down. Mail catches up in a few minutes."
        case let error?:
            if let server = error as? MailServerTrouble {
                // An IMAP server's own trouble, in its words for a person.
                trouble = "\(serverName(account)): \(server.words.prefix(1).lowercased() + server.words.dropFirst()). Yab asks again in a minute."
                MailGmail.log.error("sync failed: \(server.hint, privacy: .public) \(server.said, privacy: .public)")
            } else {
                trouble = "\(serverName(account)) didn’t answer. Yab asks again in a minute."
                MailGmail.log.error("sync failed: \(MailGmail.said(error), privacy: .public)")
            }
        }
        let was = status[account]
        let synced = trouble == nil ? Date() : was?.synced
        if trouble == nil { heard[account] = synced }
        let now = Status(synced: synced, syncing: false, trouble: trouble, signedOut: out, resting: rest[account] != nil && trouble != nil)
        // Everything that shows mail watches this: an ask that found
        // nothing new and changed nothing else tells its time at most once
        // a minute.
        let same = was.map { $0.trouble == now.trouble && $0.signedOut == now.signedOut && $0.resting == now.resting && !$0.syncing } ?? false
        let recent = was?.synced.map { told in (now.synced ?? told).timeIntervalSince(told) < 60 } ?? false
        if news || !same || !recent { status[account] = now }
        if news {
            wake(engine)
            note()
            skip(engine)
            sense(engine)
        }
        readsDue(engine)
        if again.remove(account) != nil { run(engine) }
        schedule()
    }

    // MARK: - read statuses

    /// When each account last asked the site about all its mail's read
    /// statuses (MailReads), each thread asked about on its own, and the
    /// accounts asking now.
    @ObservationIgnored private var readsAsked: [String: Date] = [:]
    @ObservationIgnored private var threadsAsked: [String: Date] = [:]
    @ObservationIgnored private var readsAsking: Set<String> = []
    /// A mail sent (⌘↩): from when it has gone, its undo window over, the
    /// next sync asks, not five minutes on.
    @ObservationIgnored private var readsSoon: [String: Date] = [:]

    /// After a sync: every five minutes while Yab is active, or mail is in
    /// front, the site asked about the mail of the last 30 days, and after
    /// a mail of yours went. The syncs are the beat, so a Mac at rest wakes
    /// for nothing more.
    private func readsDue(_ engine: Engine) {
        let account = engine.account, now = Date()
        let sent = readsSoon[account].map { now >= $0 } ?? false
        guard NSApp?.isActive == true || pageInFront, !readsAsking.contains(account),
              sent || now.timeIntervalSince(readsAsked[account] ?? .distantPast) >= MailReads.every else { return }
        readsSoon[account] = nil
        readsAsked[account] = now
        Task { await askReads(account) }
    }

    /// The site asked now about an account's mail: one thread's (one with
    /// mail of yours opened, `thread`), or all of the last 30 days'. Off
    /// the main thread; what came drawn. One ask an account at a time (a
    /// thread opened meanwhile asked once it is done), and a thread asked a
    /// moment ago (J and K over it) not again. Whether anything new came.
    @discardableResult
    func askReads(_ account: String, thread: String? = nil) async -> Bool {
        guard let engine = engines[account] else { return false }
        guard !readsAsking.contains(account) else {
            // A thread opened while its account's mail is asked about: its
            // own ask once that one is done, which may have begun before the
            // mail was opened.
            if let thread { readsAfter[account, default: []].insert(thread) }
            return false
        }
        if let thread {
            let id = account + "|" + thread, now = Date()
            guard now.timeIntervalSince(threadsAsked[id] ?? .distantPast) > 20 else { return false }
            if threadsAsked.count > 64 { threadsAsked = threadsAsked.filter { now.timeIntervalSince($0.value) <= 20 } }
            threadsAsked[id] = now
        }
        readsAsking.insert(account)
        let store = engine.store
        let news = await Task.detached(priority: .utility) { await MailReads.ask(store, thread: thread) }.value
        readsAsking.remove(account)
        if news, engines[account]?.store === store { note() }
        if let next = readsAfter[account]?.popFirst() {
            if readsAfter[account]?.isEmpty == true { readsAfter[account] = nil }
            Task { await askReads(account, thread: next) }
        }
        return news
    }

    /// Threads opened while their account's reads were being asked about.
    @ObservationIgnored private var readsAfter: [String: Set<String>] = [:]

    /// Accounts whose new mail is being sorted now, and those to sort again after.
    @ObservationIgnored private(set) var sensing: Set<String> = []
    @ObservationIgnored private var senseAgain: Set<String> = []

    /// Accounts whose new mail Skip the inbox looks at now, and those to
    /// look at again after.
    @ObservationIgnored private var skipping: Set<String> = []
    @ObservationIgnored private var skipAgain: Set<String> = []

    /// Mail that came into a split that skips the inbox, archived as soon
    /// as the sync that brought it is done (MailSkip), not behind the
    /// sorting of what came before: notifications say only what the rules
    /// read after this. Asked again while it runs, it runs once more after.
    private func skip(_ engine: Engine) {
        let sort = MailList.shared.sort
        guard sort.rules.contains(where: { $0.mode == .skip }) else { return }
        guard skipping.insert(engine.account).inserted else {
            skipAgain.insert(engine.account)
            return
        }
        let store = engine.store
        Task.detached(priority: .utility) { [weak self] in
            let skipped = MailSkip.run(store, sort: sort)
            await MainActor.run {
                guard let self else { return }
                if let skipped {
                    MailDesk.shared.skipped(account: engine.account, skipped)
                    // Gmail hears it now; the lists and the new tab follow.
                    self.acted(engine.account, after: 0)
                }
                self.skipping.remove(engine.account)
                if self.skipAgain.remove(engine.account) != nil { self.skip(engine) }
            }
        }
    }

    /// What new mail wants, worked out on this Mac after each sync that
    /// brought some; the list and the new tab's rows follow as each thread
    /// is read, and then what notifications say. Asked again while it
    /// runs, it runs once more after.
    private func sense(_ engine: Engine) {
        guard sensing.insert(engine.account).inserted else {
            senseAgain.insert(engine.account)
            return
        }
        let store = engine.store, accounts = accounts.count, synced = Date()
        Task.detached(priority: .utility) { [weak self] in
            // What the rules can tell is said as soon as they have read it;
            // a stranger's mail the Mac's model may yet call a sales pitch
            // waits for its reading, a few seconds at most: what it hasn't
            // read by then goes with the rules' reading and the mail's start.
            let early = Task.detached(priority: .utility) {
                try await Task.sleep(nanoseconds: 4_000_000_000)
                await MailNotify.shared.look(engine, accounts: accounts, synced: synced)
            }
            await MailSense.run(store, model: MailSense.ready && MailSense.wanted, ruled: { holding in
                await MailNotify.shared.look(engine, accounts: accounts, holding: holding, synced: synced)
            }, read: { _, holding in
                await MailNotify.shared.look(engine, accounts: accounts, holding: holding, synced: synced)
            }) {
                Task { @MainActor in self?.note() }
            }
            // What you promised in your own mail (MailPromise), rules alone.
            if MailPromise.run(store) { Task { @MainActor in self?.note() } }
            // Kinds labeled in Gmail (Sorting), what was read as them since.
            if MailKindLabels.run(store, kinds: MailKinds.labeled) != nil {
                Task { @MainActor in self?.acted(engine.account, after: 0) }
            }
            // Once a day, the people you write with in memory (MailPeople).
            MailPeople.run(store, open: { address in
                let found = MailCenter.open(in: store, account: engine.account, with: [address])
                return (found.promised + found.owed).map { $0.words + " · " + $0.when }
            })
            early.cancel()
            await MailNotify.shared.look(engine, accounts: accounts, synced: synced)
            await MainActor.run {
                guard let self else { return }
                self.sensing.remove(engine.account)
                // Mail placed: a routine on a split's mail takes what came (docs/mail.md, Routines on a split's mail).
                Routines.shared.mailCame()
                Hints.shared.compose()
                // A person's new mail waiting on the user: a short look at it.
                if BackgroundConsent.canStartMailReply(), Store.settings.bool(forKey: "bench") {
                    Agents.shared.glance(at: MailCenter.noticed(in: store, account: engine.account, now: Date()))
                }
                MailDrafts.run(engine)
                if self.senseAgain.remove(engine.account) != nil { self.sense(engine) }
            }
        }
    }

    /// An op done here now and sent after the next sync or in a moment.
    @discardableResult
    func act(_ kind: MailOp.Kind, thread: String, account: String, label: String = "", after: TimeInterval = 0) -> Int64? {
        guard let engine = engines[account] else { return nil }
        let seq = MailOps.act(kind, thread: thread, label: label, after: after, in: engine.store)
        note()
        // A mail going out with a read status: the site asked once it went (readsDue).
        if kind == .send { readsSoon[account] = Date().addingTimeInterval(after + 2) }
        DispatchQueue.main.asyncAfter(deadline: .now() + after + 0.5) { [weak self] in
            guard let self, let engine = engines[account] else { return }
            Task {
                try? await MailOps.flush(engine.store, provider: engine.provider)
                if (try? await engine.sync.countLabels(now: Date())) == true { MailLabels.shared.reload() }
            }
            _ = self
        }
        return seq
    }

    func undo(_ seq: Int64, account: String) -> Bool {
        guard let engine = engines[account], MailOps.undo(seq, in: engine.store) else { return false }
        note()
        return true
    }

    /// A kind turned on for Label in Gmail (Sorting): its last month's
    /// threads labeled now in every account, not at the next sync.
    func labelKinds() {
        let kinds = MailKinds.labeled
        for engine in engines.values {
            let store = engine.store, account = engine.account
            Task.detached(priority: .utility) { [weak self] in
                guard MailKindLabels.run(store, kinds: kinds) != nil else { return }
                await MainActor.run { self?.acted(account, after: 0) }
            }
        }
    }

    /// An act done in an account's store (MailOps, an act on one thread or
    /// many): what shows mail draws again, and Gmail hears it once its undo
    /// window is over.
    func acted(_ account: String, after: TimeInterval) {
        note()
        DispatchQueue.main.asyncAfter(deadline: .now() + after + 0.5) { [weak self] in
            guard let engine = self?.engines[account] else { return }
            Task {
                try? await MailOps.flush(engine.store, provider: engine.provider)
                // A label it changed counts otherwise now: asked again if shown.
                if (try? await engine.sync.countLabels(now: Date())) == true { MailLabels.shared.reload() }
            }
        }
    }

    // MARK: - codes

    /// Mail that came in the last few minutes, from every account, as the
    /// codes read it.
    func recent(minutes: Double) -> [Mailed] {
        let since = Date().addingTimeInterval(-minutes * 60)
        return engines.values.flatMap { engine in
            engine.store.inbound(since: since).map {
                Mailed(from: $0.from.name, address: $0.from.address, subject: $0.subject, text: $0.text ?? $0.snippet, at: $0.date,
                       thread: $0.thread, account: engine.account, html: $0.html, unread: $0.labels.contains("UNREAD"),
                       junk: $0.labels.contains("SPAM") || $0.labels.contains("TRASH"),
                       message: $0.id, read: engine.store.code(message: $0.id))
            }
        }
    }

    /// Read through MailLink, so a view that asks follows it: the stores
    /// open off the main thread, after the column's first frame, and the
    /// foot left Mail out of its spaces until the next switch (2026-10-16).
    var connected: Bool { MailLink.shared.connected }

    private func relink() {
        let now = on && !engines.isEmpty
        if MailLink.shared.connected != now { MailLink.shared.connected = now }
    }

    /// Something changed in a store from outside the sync: the page redraws.
    func touch() { note() }

    // MARK: - All Accounts

    /// Whether an account's mail is in All Accounts: every one is, but
    /// those turned off, and all of them when every one is.
    func inAll(_ account: String) -> Bool { MailAllAccounts.shows(account, in: "all", accounts: accounts, apart: apart) }

    /// The accounts All Accounts gathers.
    var together: [String] { MailAllAccounts.together(accounts, apart: apart) }

    /// The engines a column on `chosen` shows: that account's, or, on
    /// "all", those in All Accounts.
    func showing(_ chosen: String) -> [Engine] {
        engines.values.filter { MailAllAccounts.shows($0.account, in: chosen, accounts: accounts, apart: apart) }
    }

    /// The engines a search on `chosen` looks in: every account's on "all",
    /// those kept out of All Accounts too.
    func searching(_ chosen: String) -> [Engine] {
        engines.values.filter { chosen == "all" || $0.account == chosen }
    }

    /// Show in All Accounts turned on or off for an account; the last one
    /// in stays in.
    func setInAll(_ account: String, _ on: Bool) {
        guard accounts.contains(account), on || MailAllAccounts.canLeave(account, accounts: accounts, apart: apart) else { return }
        var now = apart
        if on { now.remove(account) } else { now.insert(account) }
        guard now != apart else { return }
        apart = now
        MailAllAccounts.keep(account, on: on, in: Store.settings)
        // The combined lists, their counts, the labels, the pin and the Dock again.
        MailList.shared.reload()
        MailLabels.shared.reload()
        MailDesk.shared.load()
        note()
    }

    @ObservationIgnored private var counting = false

    /// How many need you, and the Dock's badge, counted a beat after the
    /// stores change; notifications whose mail was dealt with go.
    func recount() {
        let span = MainBudget.begin("mail.recount"); defer { span?.end() }
        guard !counting else { return }
        counting = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            counting = false
            var count = 0, unreadNeeds = 0
            if connected {
                // An account kept out of All Accounts counts in its own inbox only.
                let needing = MailAllAccounts.needing(engines.values.map { ($0.account, $0.store) }, accounts: accounts, apart: apart)
                count = needing.all
                unreadNeeds = needing.unread
            }
            if count != needYou { needYou = count }
            let notify = MailNotify.shared
            let unread = connected && notify.badgeMode == .unread ? showing("all").reduce(0) { $0 + $1.store.unreadThreads() } : 0
            let shown = MailNotify.number(notify.badgeMode, needs: count, unreadNeeds: unreadNeeds, unread: unread)
            if shown != counted { counted = shown }
            notify.badge(needs: count, unreadNeeds: unreadNeeds, unread: unread)
            notify.tidy()
            // What is open with a meeting's people, on its card.
            Meetings.shared.mailChanged()
        }
    }

    /// The mail pin, put once, when the first account comes in, unless
    /// it was taken away before.
    func pinOnce(in browser: Browser?) {
        guard let browser, !Store.settings.bool(forKey: "mail.pinned") else { return }
        Store.settings.set(true, forKey: "mail.pinned")
        if pinWanted { putPin(in: browser) }
    }

    /// Pin Mail: the door among the pins of the space on screen, if none
    /// is anywhere there already. In mail's own space it goes to the space
    /// you go back to (Browser.mailLeft).
    func putPin(in browser: Browser) {
        guard browser.prefs.usesMail else { return }
        setPin(true)
        guard !browser.inMail, !Self.hasPin(browser) else { return }
        browser.pin(browser.open(MailPage.url, foreground: false))
    }

    /// Unpin Mail: every door taken away, in every space, and it stays away.
    func takePin(in browser: Browser) {
        setPin(false)
        for tab in browser.tabs where tab.pin != nil && MailPage.isMail(tab.pending ?? tab.address) { browser.unpinMail(tab) }
        for (space, row) in browser.parked {
            let kept = row.tabs.filter { !($0.pin != nil && MailPage.isMail($0.pending ?? $0.address)) }
            if kept.count != row.tabs.count { browser.parked[space]?.tabs = kept }
        }
        // Gone from the shared pins too, in every window (SharedPins.swift).
        browser.writePins(now: true)
    }

    /// The door unpinned by hand: gone, and not put back.
    func pinTaken() { setPin(false) }

    static func hasPin(_ browser: Browser) -> Bool {
        browser.tabs.contains { $0.pin != nil && MailPage.isMail($0.pending ?? $0.address) }
    }

    private func setPin(_ on: Bool) {
        Store.settings.set(on, forKey: "mail.pin")
        if pinWanted != on { pinWanted = on }
    }

    /// What Skip the inbox archived since the day began, every account's:
    /// how many, and the splits that did it, for the new tab's line.
    func archivedToday(now: Date = MailClock.now) -> (count: Int, splits: [String]) {
        guard connected, MailList.shared.splits.contains(where: { $0.on && $0.mode == .skip }) else { return (0, []) }
        return Self.archivedToday(in: showing("all").map(\.store), since: MailSkip.today(now))
    }

    /// Called while the address field composes its first rows. The Skip
    /// summary must not queue behind a synchronizing account's writer.
    static func archivedToday(in stores: [MailStore], since: Date) -> (count: Int, splits: [String]) {
        var count = 0, splits: [String] = []
        for store in stores {
            for one in store.off.skipped(since: since) {
                count += 1
                if !splits.contains(one.split) { splits.append(one.split) }
            }
        }
        return (count, splits)
    }

    /// Whether the thread a row opens is dealt with by you since: your word
    /// is the last, or you read it. A row of no thread here is not.
    func settled(_ url: URL?) -> Bool {
        guard let (account, id) = Hints.mailThread(url),
              let store = engines.values.first(where: { $0.account == account })?.store else { return false }
        return Self.settled(id, in: store)
    }

    /// Agent-found rows are filtered synchronously by Hints.compose too.
    static func settled(_ id: String, in store: MailStore) -> Bool {
        guard let thread = store.off.thread(id) else { return false }
        return thread.lastIsMine || !thread.unread
    }

    /// Threads the look read and found waiting on no one: their rows stay
    /// away until a new mail comes in them (Noticing.setAside).
    func quiet(_ threads: [String]) {
        for one in threads {
            let parts = one.split(separator: "|", maxSplits: 1).map(String.init)
            let id = parts.last ?? one
            let stores = engines.values.filter { parts.count < 2 || $0.account == parts[0] }.map(\.store)
            guard let last = stores.lazy.compactMap({ $0.thread(id)?.last }).first else { continue }
            Noticing.shared.setAside("mail." + id, last: last)
        }
    }

    /// Threads worth a row on the new tab (Noticing.mail).
    func noticed(now: Date = MailClock.now) -> [Noticing.MailNotice] {
        guard connected else { return [] }
        return showing("all").flatMap { MailCenter.noticed(in: $0.store, account: $0.account, now: now) }
    }

    /// One account's: Waiting by the same rule as its list, so a thread
    /// you are done waiting on has no "hasn't answered" row either.
    static func noticed(in store: MailStore, account: String, now: Date) -> [Noticing.MailNotice] {
        // The address field composes these rows before its first draw.
        // Read through the WAL reader so mail sync cannot hold that input
        // event behind its writer queue.
        let store = store.off
        var out: [Noticing.MailNotice] = []
        var seen = Set<String>()
        for thread in store.threads(label: "INBOX", limit: 150) + store.threads(label: "SENT", limit: 60)
        where seen.insert(thread.id).inserted {
            let sensed = store.sensed(thread.id)
            // Archive is quiet: older than the window, it asks for no row.
            guard let split = MailSplit.of(thread, sensed: sensed, now: now), split != .other, split != .older else { continue }
            let person = thread.people.first
            let who = person.map { $0.said.components(separatedBy: " ").first ?? $0.said } ?? "Someone"
            let host = person.flatMap { $0.address.split(separator: "@").last.map(String.init) } ?? ""
            var notice = Noticing.MailNotice(account: account, thread: thread.id, who: who, host: host, subject: thread.subject,
                                             gist: sensed?.gist ?? "", last: thread.last, due: sensed?.due, why: .waitingOnYou,
                                             address: person?.address.lowercased() ?? "")
            let age = now.timeIntervalSince(thread.last)
            // You wrote in it: an answer to you, not a stranger's first word.
            let conversation = thread.labels.contains("SENT")
            if split == .waiting || thread.followup?.fired != nil {
                // Brought back by its reminder: as long as it was asked for.
                guard age > 3 * 86_400 || thread.followup?.fired != nil else { continue }
                notice.why = .noAnswer
            } else if sensed?.kind == .invoice, let due = sensed?.due, due < now {
                notice.why = .pastDue
            } else if let due = sensed?.due, due > now.addingTimeInterval(-86_400), due < now.addingTimeInterval(36 * 3600) {
                notice.why = .due
            } else if sensed?.needs == true, thread.unread, sensed?.byModel == true || !(MailSense.ready && MailSense.wanted),
                      age > (conversation ? 0 : 4 * 3600) {
                // Read and left is seen: a robot's "Action needed" asks for
                // a tap or a call, not a reply. Said once the Mac's model has
                // read it with the thread (MailSense), at once in a
                // conversation of yours, after four hours from someone new.
                notice.why = .waitingOnYou
                notice.conversation = conversation
            } else {
                continue
            }
            out.append(notice)
        }
        // What you promised them is a row of its own (Promises), not mail's.
        return out
    }

    // MARK: - what is open with people

    /// A line of the meeting card (MeetingReminder): what is open with a
    /// meeting's people, a click to its thread.
    struct MeetingOpen: Equatable {
        let account: String
        let thread: String
        /// "You owe: Q3 numbers", "Mark owes: Term sheet redline".
        let words: String
        /// "by Fri", "asked 4d ago".
        let when: String
    }

    /// What is open with these people: what you promised them first, then
    /// what they owe you (Waiting), two at most.
    func open(with people: [String], now: Date = Date()) -> [MeetingOpen] {
        guard connected, !people.isEmpty else { return [] }
        let wanted = Set(people.map { $0.lowercased() })
        var promised: [MeetingOpen] = [], owed: [MeetingOpen] = []
        for engine in engines.values.sorted(by: { $0.account < $1.account }) {
            let found = MailCenter.open(in: engine.store, account: engine.account, with: wanted, now: now)
            promised += found.promised.filter { one in !promised.contains { $0.thread == one.thread } }
            owed += found.owed
        }
        return Array((promised + owed).prefix(2))
    }

    /// The same in one store, all of it: what you promised them, and what
    /// they owe you. Off the main thread too (MailPeople's pages).
    nonisolated static func open(in store: MailStore, account: String, with wanted: Set<String>,
                                 now: Date = Date()) -> (promised: [MeetingOpen], owed: [MeetingOpen]) {
        var promised: [MeetingOpen] = [], owed: [MeetingOpen] = []
        for promise in MailPromise.open(in: store, now: now) where wanted.contains(promise.address) {
            guard !promised.contains(where: { $0.thread == promise.thread }), let thread = store.thread(promise.thread) else { continue }
            promised.append(MeetingOpen(account: account, thread: thread.id, words: "You owe: " + bare(thread.subject),
                                        when: MailPromise.when(promise, now: now)))
        }
        for (thread, _) in MailSplit.threads(.waiting, in: store, now: now, limit: 200) {
            guard let them = thread.people.first(where: { wanted.contains($0.address.lowercased()) }) else { continue }
            let who = them.said.components(separatedBy: " ").first ?? them.said
            let days = max(1, Int(now.timeIntervalSince(thread.last) / 86_400))
            owed.append(MeetingOpen(account: account, thread: thread.id, words: "\(who) owes: " + bare(thread.subject),
                                    when: "asked \(days)d ago"))
        }
        return (promised, owed)
    }

    /// A subject without its "Re:" and "Fwd:".
    nonisolated static func bare(_ subject: String) -> String {
        var out = subject.trimmingCharacters(in: .whitespaces)
        while let range = out.range(of: #"^(re|fwd?|aw|wg)\s*:\s*"#, options: [.regularExpression, .caseInsensitive]) {
            out.removeSubrange(range)
        }
        return out.isEmpty ? "(no subject)" : out
    }

    // MARK: - connecting

    /// An OAuth attempt belongs to one initiator through profile verification.
    @ObservationIgnored private var connectAttempt: UUID?
    @ObservationIgnored private var connectReply: ((Result<String, Error>) -> Void)?

    static let newGmailConnectionNotice = "New Gmail accounts connect with an app password. Open Settings > Mail > Add Account and choose Google Account."

    /// Only a connected Gmail account's explicit reauthentication may proceed.
    /// A discovered address or login hint does not establish an existing account.
    func gmailConnectionProblem(expectedAccount: String?) -> String? {
        guard let expected = expectedAccount?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !expected.isEmpty,
              let account = accounts.first(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == expected }),
              Self.kind(of: account) == .gmail else { return Self.newGmailConnectionNotice }
        return nil
    }

    /// Google's consent page, the account coming in when it answers.
    /// Asked for by the person, it is the Mac's own sign-in sheet
    /// (ASWebAuthenticationSession, OAuthPresenter): Google refuses its
    /// sign-in in a page Yab draws, "This browser or app may not be secure"
    /// (#456), so it is never a tab or a peek of Yab's; `hint` still names
    /// the address, and `space` is kept for a door that takes a tab. Asked
    /// for by an agent (`outside`), it opens in another browser: an agent
    /// must not drive its own consent page.
    @discardableResult
    func connect(in browser: Browser, hint: String? = nil, space: UUID? = nil, fromSettings: Bool = false,
                 outside: Bool = false, expectedAccount: String? = nil, attempt: UUID = UUID(),
                 authorized: @escaping () -> Bool = { true },
                 completion: ((Result<String, Error>) -> Void)? = nil) -> Bool {
        if let problem = gmailConnectionProblem(expectedAccount: expectedAccount) {
            browser.announce(problem, mark: "exclamationmark.triangle")
            completion?(.failure(MailTrouble.offline(problem)))
            return false
        }
        guard let client = MailClient.configured else {
            browser.announce("This build has no Google client for Mail", mark: "exclamationmark.triangle")
            completion?(.failure(MailTrouble.unreadable))
            return false
        }
        if connecting { cancelConnect(in: browser) }
        let signIn = MailSignIn(client: client)
        self.signIn = signIn
        connectAttempt = attempt
        connectReply = completion
        signInFromSettings = fromSettings
        connecting = true
        connectFailed = false
        signInLeft = nil
        let presenter = OAuthPresenter.choose(for: client, outside: outside)
        if presenter == .tab, let space, space != browser.spaceID, browser.spaces.contains(where: { $0.id == space }),
           Spaces.store(for: space) !== Spaces.store(for: browser.spaceID) {
            signInLeft = browser.spaceID
            browser.switchSpace(to: space)
        }
        do {
            let page = try signIn.start(hint: hint) { [weak self, weak browser] result in
                guard let self, connectAttempt == attempt else { return }
                // Google has answered: its sheet goes, the account comes in here.
                closeSheet()
                guard authorized() else { cancelConnect(in: browser, attempt: attempt); return }
                switch result {
                case .success(let tokens):
                    welcome(tokens, client: client, browser: browser,
                            expectedAccount: expectedAccount?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                            attempt: attempt, authorized: authorized)
                case .failure(let error): finishConnect(attempt, result: .failure(error), browser: browser)
                }
            }
            signInShown = MailCenter.described(page, presenter: presenter)
            if presenter == .systemSheet {
                let window = BrowserWindows.shared.window(for: browser) ?? NSApp.keyWindow
                let sheet = GoogleSignInSheet(page: page, window: window) { [weak self, weak browser] in
                    // Closed by the person before Google answered: as Cancel.
                    guard let self, connectAttempt == attempt, !(self.signIn?.answered ?? false) else { return }
                    cancelConnect(in: browser, attempt: attempt)
                }
                signInSheet = sheet
                guard sheet.start() else { throw MailTrouble.offline("The Mac's sign-in sheet didn't open") }
                return true
            }
            if presenter == .tab {
                if let over = browser.inMail ? browser.mailPageTab : nil {
                    signInOver = true
                    browser.peek(page, from: over)
                } else {
                    signInTab = browser.open(page, foreground: true).id
                }
                return true
            }
            let workspace = NSWorkspace.shared
            let defaultApp = workspace.urlForApplication(toOpen: page)
            let defaultIsYab = defaultApp.flatMap { Bundle(url: $0)?.bundleIdentifier }?.hasPrefix("dev.serafim.fast") == true
            let external = defaultIsYab ? nil : defaultApp
            guard let application = external ?? workspace.urlForApplication(withBundleIdentifier: "com.apple.Safari") else {
                throw MailTrouble.offline("No external browser for Google sign-in")
            }
            workspace.open([page], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration()) { [weak self, weak browser] _, error in
                if let error { Task { @MainActor in self?.finishConnect(attempt, result: .failure(error), browser: browser) } }
            }
            // A window closed in the external browser has no callback here.
            // Expire its attempt instead of keeping a connection alive forever.
            Task { @MainActor [weak self, weak browser] in
                try? await Task.sleep(nanoseconds: 600_000_000_000)
                guard let self, connectAttempt == attempt else { return }
                finishConnect(attempt, result: .failure(MailTrouble.offline("Google sign-in expired")), browser: browser)
            }
            return true
        } catch {
            finishConnect(attempt, result: .failure(error), browser: browser)
            return false
        }
    }

    private func finishConnect(_ attempt: UUID, result: Result<String, Error>, browser: Browser?) {
        guard connectAttempt == attempt else { return }
        connectAttempt = nil
        signIn?.cancel()
        signIn = nil
        connecting = false
        let over = signInOver
        leaveSignIn(browser)
        let completion = connectReply
        connectReply = nil
        if case .failure = result {
            connectFailed = true
            signInFromSettings = false
            // Over the mail page, the card under the peek says so.
            if !over { browser?.announce("Gmail wasn’t connected", mark: "exclamationmark.triangle") }
        }
        completion?(result)
    }

    /// Cancel invalidates both a pending callback and a profile verification.
    func cancelConnect(in browser: Browser?, attempt: UUID? = nil) {
        guard connecting, attempt == nil || attempt == connectAttempt else { return }
        let completion = connectReply
        connectReply = nil
        connectAttempt = nil
        signIn?.cancel()
        signIn = nil
        connecting = false
        signInFromSettings = false
        leaveSignIn(browser, now: true)
        completion?(.failure(MailTrouble.offline("Google sign-in cancelled")))
    }

    /// What the last sign-in opened, for a --test run (agent-mail-settings):
    /// the presenter and Google's address, its client named only as there.
    @ObservationIgnored private(set) var signInShown: [String: String] = [:]

    static func described(_ page: URL, presenter: OAuthPresenter) -> [String: String] {
        let items = URLComponents(url: page, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value ?? "" }
        let redirect = URL(string: value("redirect_uri"))
        return ["presenter": presenter.rawValue, "host": page.host() ?? "", "path": page.path,
                "client_id": value("client_id").isEmpty ? "missing" : "present",
                "redirect": "\(redirect?.scheme ?? "")://\(redirect?.host() ?? "")\(redirect?.path ?? "")",
                "pkce": value("code_challenge_method")]
    }

    private func closeSheet() {
        signInSheet?.close()
        signInSheet = nil
    }

    /// Google's sheet, tab or peek put away, and the space left for it given back.
    private func leaveSignIn(_ browser: Browser?, now: Bool = false) {
        closeSheet()
        let over = signInOver
        let id = signInTab
        let back = signInLeft
        signInOver = false
        signInTab = nil
        signInLeft = nil
        guard let browser else { return }
        if over { DispatchQueue.main.asyncAfter(deadline: .now() + (now ? 0 : 0.6)) { browser.closePeek() } }
        let tab = id.flatMap { id in browser.tabs.first { $0.id == id } }
        guard tab != nil || back != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + (now ? 0 : 1.2)) {
            if let tab { browser.close(tab) }
            if let back, browser.spaceID != back { browser.switchSpace(to: back) }
        }
    }

    /// The way in has said where mail is: Settings › Mail is its page now.
    func landingSeen() {
        landed = nil
        // The landing asked about agents and mail (MailConsentList): whatever
        // was left off is the answer.
        if PlanText.any { MailConsent.answered() }
    }

    /// A test world's Settings › Mail in a state it can't reach without
    /// Google: asking, refused, just in, or an account Google let go of.
    func bench(_ state: String, account: String?) {
        guard Store.testing else { return }
        switch state {
        case "connecting": connecting = true; connectFailed = false
        case "failed": connecting = false; connectFailed = true
        case "landed": connecting = false; landed = account ?? accounts.first
        case "signedOut":
            guard let account = account ?? accounts.first else { return }
            status[account] = Status(synced: status[account]?.synced, trouble: "Google stopped letting Yab in", signedOut: true)
        default: connecting = false; connectFailed = false; landed = nil
        }
    }

    private func welcome(_ tokens: MailGrant, client: MailClient, browser: Browser?, expectedAccount: String?,
                         attempt: UUID, authorized: @escaping () -> Bool) {
        let access = tokens.access
        let probe = MailGmail(token: { access }, pace: MailPace())
        Task {
            do {
                let (address, _) = try await probe.profile()
                let account = address.lowercased()
                guard connectAttempt == attempt else { return }
                guard authorized() else { cancelConnect(in: browser, attempt: attempt); return }
                guard MailClient.accepts(tokens.scopes), expectedAccount == nil || expectedAccount?.lowercased() == account else {
                    finishConnect(attempt, result: .failure(MailTrouble.offline("Google granted a different account or incomplete mail access")), browser: browser)
                    return
                }
                guard MailKeychain.save(tokens.refresh, for: account) else {
                    finishConnect(attempt, result: .failure(MailTrouble.offline("The keychain refused Gmail’s sign-in")), browser: browser)
                    return
                }
                // Whether Google let the calendar through too: Meetings
                // reads it from now on.
                Store.settings.set(tokens.calendar, forKey: "mail.calendar.\(account)")
                // And its list of calendars: every one it shows, or the
                // primary alone (MeetingsGoogle.calendars).
                Store.settings.set(tokens.calendarList, forKey: MeetingsGoogle.listKey(account))
                // And whether it may make events there: never asked for yet (MailEvents).
                Store.settings.set(tokens.calendarWrite, forKey: MailEvents.writeKey(account))
                MeetingsGoogle.forget(account)
                let first = accounts.isEmpty
                // Signed in again: its row stops saying Google let it go
                // now, not at the end of its next sync.
                if let was = status[account], was.signedOut { status[account] = Status(synced: was.synced) }
                add(account)
                Meetings.shared.start()
                pinOnce(in: browser)
                // Back to Settings, where the first account's way in says
                // where mail is now and any other's row shows it connected.
                if signInFromSettings {
                    if first { landed = account }
                    if let window = SettingsWindow.shared.window, window.isVisible { window.makeKeyAndOrderFront(nil) }
                }
                signInFromSettings = false
                finishConnect(attempt, result: .success(account), browser: browser)
            } catch {
                finishConnect(attempt, result: .failure(error), browser: browser)
            }
        }
    }

    /// An account, kept and started. `gmail`: a test world's own.
    func add(_ account: String, gmail: MailGmail? = nil) {
        if !accounts.contains(account) {
            accounts.append(account)
            Store.settings.set(accounts, forKey: "mail.accounts")
        }
        // A sync of the engine it had stops, and its end is passed over (ran).
        syncing.removeValue(forKey: account)?.cancel()
        engines[account]?.wire?.close()
        // An IMAP account's lines, IDLE's with them, closed before new ones open.
        if let line = engines[account]?.provider as? MailIMAPAccount { Task { await line.close() } }
        // What the splits kept of the store it had goes with it: a new one may
        // take its place in memory.
        if let old = engines[account]?.store { MailSplitCache.shared.forget(old) }
        engines[account] = nil
        running.remove(account)
        again.remove(account)
        make(account, gmail: gmail)
        // Connected again: its send-as addresses and signatures asked anew at its next sync.
        engines[account]?.store.set("sendas.at", nil)
        // Its first sync, once: the beat starts it, or, where the beat
        // wouldn't (Low Power), this does. It used to run here as well as
        // in the beat, two first syncs at once reading the same mail.
        turn(on)
        if on, let engine = engines[account], !running.contains(account) { run(engine) }
    }

    /// Gone from here: its token taken back at Google, its store deleted,
    /// the files its mail and its drafts kept, its memory, and what
    /// Notification Center still says of it.
    func disconnect(_ account: String) {
        let imap = Self.kind(of: account) == .imap
        if imap {
            // Nothing to take back at a server: the password goes from the keychain.
            if let line = engines[account]?.provider as? MailIMAPAccount { Task { await line.close() } }
            MailSecret.forget(account)
            Store.settings.removeObject(forKey: MailServerSetup.key(account))
            Store.settings.removeObject(forKey: "mail.provider.\(account)")
            try? FileManager.default.removeItem(atPath: (engines[account]?.store.file ?? MailStore.file(for: account)).path + ".imap")
        } else {
            // Taken back at Google, now or, offline, at a later launch (MailRevoke).
            if let token = MailKeychain.token(for: account) { Task { await MailRevoke.revoke(token) } }
            MailKeychain.forget(account)
        }
        let file = engines[account]?.store.file ?? MailStore.file(for: account)
        // Its sync stops first: a first sync goes on for minutes.
        syncing.removeValue(forKey: account)?.cancel()
        engines[account]?.wire?.close()
        if let old = engines[account]?.store { MailSplitCache.shared.forget(old) }
        engines[account] = nil
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: file.path + suffix) }
        MailAttach.forget(store: file)
        MailRecall.shared.drop(account)
        // Its files, mail/<account>.noindex/, gone with its store.
        MailFiles.drop(account)
        Task { await MailNotify.shared.forget(account) }
        DispatchQueue.global(qos: .utility).async { MailWire.sweepCache(always: true) }
        accounts.removeAll { $0 == account }
        Store.settings.set(accounts, forKey: "mail.accounts")
        // Its face and space, as Settings › Mail found them.
        Store.settings.removeObject(forKey: "mail.photo.\(account)")
        Store.settings.removeObject(forKey: "mail.space.\(account)")
        Store.settings.removeObject(forKey: "mail.calendar.\(account)")
        Store.settings.removeObject(forKey: MeetingsGoogle.listKey(account))
        Store.settings.removeObject(forKey: MailEvents.writeKey(account))
        MeetingsGoogle.forget(account)
        Store.settings.removeObject(forKey: "mail.notify.\(account)")
        Store.settings.removeObject(forKey: MailAllAccounts.key(account))
        apart.remove(account)
        Meetings.shared.start()
        status[account] = nil
        note()
        if accounts.isEmpty { turn(on) }
    }
}

/// Whether mail is connected, as Observation follows it: MailCenter is an
/// ObservableObject whose `on` and `engines` nothing watches, and
/// Browser.turnOrder, the foot's row and its Mail door read it in bodies.
@MainActor
@Observable
final class MailLink {
    static let shared = MailLink()
    fileprivate(set) var connected = false
}

extension MailCenter.Engine {
    /// A Gmail account's engine, as tests and test worlds make one.
    init(account: String, store: MailStore, gmail: MailGmail, sync: MailSync, wire: MailWire? = nil) {
        self.init(account: account, store: store, provider: gmail, sync: sync, wire: wire)
    }
}

/// Show in All Accounts (docs/mail.md, All Accounts): each account on until
/// turned off, as Spark lets an account stay out of its unified inbox. One
/// kept apart is left out of All Accounts' lists and their counts, the
/// labels it shows, the mail pin, the Dock and the new tab's rows, and
/// keeps its own inbox and count; a search still looks in it. With one
/// account left in, All Accounts is that account's.
enum MailAllAccounts {
    /// Kept per account, on this Mac (not synced, as `mail.notify.` isn't).
    static func key(_ account: String) -> String { "mail.all.\(account)" }

    /// The accounts kept apart, as kept.
    static func apart(_ accounts: [String], in settings: UserDefaults) -> Set<String> {
        Set(accounts.filter { settings.object(forKey: key($0)) as? Bool == false })
    }

    static func keep(_ account: String, on: Bool, in settings: UserDefaults) {
        if on { settings.removeObject(forKey: key(account)) } else { settings.set(false, forKey: key(account)) }
    }

    /// The accounts All Accounts gathers, in their order: all of them when
    /// every one is kept apart, so it is never empty.
    static func together(_ accounts: [String], apart: Set<String>) -> [String] {
        let left = accounts.filter { !apart.contains($0) }
        return left.isEmpty ? accounts : left
    }

    /// Whether a column on `chosen` ("all" or an address) shows an account's mail.
    static func shows(_ account: String, in chosen: String, accounts: [String], apart: Set<String>) -> Bool {
        chosen == "all" ? together(accounts, apart: apart).contains(account) : chosen == account
    }

    /// Whether it may be turned off: another account stays in.
    static func canLeave(_ account: String, accounts: [String], apart: Set<String>) -> Bool {
        accounts.contains { $0 != account && !apart.contains($0) }
    }

    /// What needs you over All Accounts, and how much of it is unread:
    /// the mail pin's and the Dock's number (MailNotify.Badge).
    @MainActor
    static func needing(_ stores: [(account: String, store: MailStore)], accounts: [String], apart: Set<String>,
                        now: Date = MailClock.now) -> (all: Int, unread: Int) {
        let together = Set(together(accounts, apart: apart))
        return stores.filter { together.contains($0.account) }.reduce((all: 0, unread: 0)) { sum, one in
            let needing = MailDesk.needing(in: one.store, now: now)
            return (sum.all + needing.all, sum.unread + needing.unread)
        }
    }

    /// All Accounts' count from each account's.
    static func total(_ counts: [String: Int], accounts: [String], apart: Set<String>) -> Int {
        together(accounts, apart: apart).reduce(0) { $0 + (counts[$1] ?? 0) }
    }
}

/// Google's consent page in the Mac's own sign-in sheet
/// (ASWebAuthenticationSession), drawn by Safari or the default browser, so
/// Google sees the browser it allows and not a web view of Yab's (#456).
/// The answer goes to MailSignIn's loopback port, which no sheet can catch:
/// the callback scheme is one Google never sends to, and the sheet is put
/// away by MailCenter once the port has heard Google. Shared with that
/// browser's cookies, so an account already signed in there is asked only
/// for the yes.
@MainActor
final class GoogleSignInSheet: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let callbackScheme = "dev.serafim.fast.oauth"

    private let page: URL
    private weak var window: NSWindow?
    private var session: ASWebAuthenticationSession?
    private var closed: (() -> Void)?

    /// `closed`: the person put the sheet away before Google answered.
    init(page: URL, window: NSWindow?, closed: @escaping () -> Void) {
        self.page = page
        self.window = window
        self.closed = closed
    }

    func start() -> Bool {
        let session = ASWebAuthenticationSession(url: page, callback: .customScheme(Self.callbackScheme)) { [weak self] _, _ in
            Task { @MainActor in
                let closed = self?.closed
                self?.closed = nil
                self?.session = nil
                closed?()
            }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        self.session = session
        return session.start()
    }

    func close() {
        closed = nil
        session?.cancel()
        session = nil
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { window ?? NSApp.keyWindow ?? NSApp.windows.first ?? NSWindow() }
    }
}
