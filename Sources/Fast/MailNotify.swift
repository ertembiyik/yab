import AppKit
import SwiftUI
import UserNotifications

// Mail that needs you, said by the Mac when you aren't looking at mail
// (docs/mail.md, Notifications and the Dock badge). After a sync brings mail
// and it is sorted (MailSense), each thread that newly needs you says so
// once: who wrote, the subject, and what they want in a line. More than
// three at once are one notification. Its buttons do what E and H do, the
// same way (MailDesk), so ⌘Z takes them back; Reply opens the thread with
// the reply written ahead in it. Nothing is ever sent from a notification.
//
// Yab never asks macOS to let it show them. They are on where it may
// already (an agent asked once, AgentNotices); otherwise Settings › Mail
// says they are off and offers Allow…, which asks only when pressed. The
// Dock's badge counts what needs you, or what is unread; nothing else in
// Yab badges the Dock.

@MainActor
@Observable final class MailNotify {
    static let shared = MailNotify(center: MailNotify.system())

    /// What an account's new mail says: nothing, what needs you, or
    /// everything that comes into the inbox.
    enum Mode: String, CaseIterable {
        case off, needs, inbox
        var title: String { self == .off ? "Off" : self == .needs ? "Needs you" : "Everything in Inbox" }
    }

    /// The one number the mail pin, the column's door and the Dock show
    /// (Settings › Mail's Count): Needs you, its unread, every unread
    /// thread of the inbox, or none.
    enum Badge: String, CaseIterable {
        case needs
        case unreadNeeds = "unread-needs"
        case unread, off
        var title: String {
            switch self {
            case .needs: return "Needs you"
            case .unreadNeeds: return "Unread in Needs you"
            case .unread: return "All unread"
            case .off: return "Off"
            }
        }
    }

    /// What macOS lets Yab do, as it last said: asked and allowed, asked
    /// and refused, or never asked.
    enum Permission: String { case allowed, denied, unasked }

    /// A notification answered: the notification itself, or a button.
    enum Act: String {
        case open, done, remind, reply, copyCode

        init?(action: String) {
            if action == UNNotificationDefaultActionIdentifier { self = .open } else { self.init(rawValue: action) }
        }
    }

    /// A thread's new mail, as a notification says it.
    struct Note: Equatable, Sendable {
        var thread: String
        /// Its last mail from someone else: said once for each.
        var message: String
        var who: String
        var subject: String
        /// What they want, worked out on this Mac, or the mail's start.
        var line: String
        var at: Date
        var code: MailCodeRead? = nil
    }

    /// One notification as it went to the Mac: one thread's, or several's.
    struct Posted: Equatable, Sendable {
        var id: String
        var account: String
        var threads: [String]
        var title: String
        var subtitle: String
        var body: String
        var codeMessage: String? = nil
        var batch: Bool { id.hasSuffix("|batch") }
    }

    nonisolated static let category = "mail.thread"
    nonisolated static let batchCategory = "mail.batch"
    nonisolated static let codeCategory = "mail.code"
    /// A mail older than this is not news, however it came: a Mac that
    /// slept the night wakes to its badge, not to a heap of banners.
    nonisolated static let window: TimeInterval = 3600

    let center: MailNotifyCenter
    /// As macOS last said, read and never asked for (Allow… asks).
    private(set) var permission: Permission = .unasked
    private(set) var modes: [String: Mode] = [:]
    private(set) var badgeMode: Badge
    /// For the bench: mail in front, whatever the windows say.
    @ObservationIgnored var frontForced: Bool?
    /// The last ones posted, newest last, for the bench.
    @ObservationIgnored private(set) var posted: [Posted] = []
    /// Posted this run and still standing, by id: taken down once their
    /// mail is dealt with here.
    @ObservationIgnored private var standing: [String: (account: String, threads: [String])] = [:]
    @ObservationIgnored private var watching: NSObjectProtocol?
    /// Accounts being looked at now, and those to look at again after: two
    /// looks at once would say the same mail twice.
    @ObservationIgnored private var looking: Set<String> = []
    /// What the last look asked for meanwhile wanted held, and when its sync
    /// ended: the look after goes by it.
    @ObservationIgnored private var lookAgain: [String: (holding: Set<String>, synced: Date?)] = [:]

    init(center: MailNotifyCenter) {
        self.center = center
        badgeMode = Badge(rawValue: Store.settings.string(forKey: "mail.badge") ?? "") ?? .needs
    }

    /// The Mac's notifications from the app itself; a record of them in a
    /// test world, or from a bare binary, which has none.
    static func system() -> MailNotifyCenter {
        Store.testing || !AgentNotices.possible ? Record() : MailNotifySystem()
    }

    /// Mail is on: the buttons known to the Mac, and what it allows read.
    func start() {
        guard watching == nil else { return }
        center.prepare()
        Task { await refresh() }
        // Back from System Settings, maybe with them turned on.
        watching = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    /// What macOS allows now, read without asking.
    func refresh() async {
        let now = await center.permission()
        guard now != permission else { return }
        permission = now
        MailCenter.shared.cadenceChanged()
    }

    // MARK: - settings

    /// An account's notifications: Needs you until changed.
    func mode(_ account: String) -> Mode {
        modes[account] ?? Mode(rawValue: Store.settings.string(forKey: "mail.notify.\(account)") ?? "") ?? .needs
    }

    func setMode(_ mode: Mode, for account: String) {
        let was = self.mode(account)
        Store.settings.set(mode.rawValue, forKey: "mail.notify.\(account)")
        modes[account] = mode
        // On again: new from now, not whatever came while it was off.
        if was == .off, mode != .off {
            MailCenter.shared.engines[account]?.store.set("notify-since", String(Date().timeIntervalSince1970))
        }
        MailCenter.shared.cadenceChanged()
    }

    func setBadge(_ mode: Badge) {
        Store.settings.set(mode.rawValue, forKey: "mail.badge")
        badgeMode = mode
        MailCenter.shared.recount()
    }

    /// Whether an account's new mail would say so now: asks for it come
    /// every 30 seconds behind other apps instead of every five minutes.
    func wants(_ account: String) -> Bool { permission == .allowed && mode(account) != .off }

    /// Settings › Mail's Allow…: macOS asks the person, the first time;
    /// after a no, System Settings, where only they can turn them on.
    func allow() async {
        permission = await center.permission()
        switch permission {
        case .unasked:
            await center.ask()
            permission = await center.permission()
        case .denied: center.openSettings()
        case .allowed: break
        }
        MailCenter.shared.cadenceChanged()
    }

    /// Mail is what you're looking at: its page in front in the key window
    /// of the app in front.
    var mailInFront: Bool {
        if let frontForced { return frontForced }
        guard let app = NSApp, app.isActive, let key = app.keyWindow else { return false }
        return BrowserWindows.shared.browser(for: key)?.inMail == true
    }

    // MARK: - after a sync

    /// After a sync brought mail and it was sorted: what is new and wants
    /// you says so, once, unless you're looking at mail or macOS doesn't
    /// let Yab say it; either way it counts as said, so nothing comes in a
    /// heap later. Then what you've dealt with since leaves Notification
    /// Center.
    func look(_ engine: MailCenter.Engine, accounts: Int = 1, now: Date? = nil, holding: Set<String> = [], synced: Date? = nil) async {
        let account = engine.account, store = engine.store
        let mode = mode(account)
        guard mode != .off else { return }
        guard looking.insert(account).inserted else {
            lookAgain[account] = (holding, synced)
            return
        }
        defer {
            looking.remove(account)
            if let again = lookAgain.removeValue(forKey: account) {
                Task { await look(engine, accounts: accounts, now: now, holding: again.holding, synced: again.synced) }
            }
        }
        let now = now ?? Date()
        await refresh()
        let quiet = permission != .allowed || mailInFront
        let sort = MailList.shared.sort
        let notes = await Task.detached(priority: .utility) {
            let fresh = MailNotify.fresh(in: store, mode: mode, since: MailNotify.since(store, now: now), now: now, sort: sort, holding: holding)
            store.noteNotified(fresh.map { ($0.thread, $0.message) })
            return fresh
        }.value
        if !quiet {
            for one in MailNotify.posts(notes, account: account, mode: mode, accounts: accounts) {
                await center.post(one)
                standing[one.id] = (account, one.threads)
                posted.append(one)
                if posted.count > 50 { posted.removeFirst() }
                // How long after the sync that brought it, for the bench.
                if let synced { lags.append(Date().timeIntervalSince(synced)) }
            }
        }
        tidy()
    }

    /// Seconds from the end of the sync that brought mail to its
    /// notification, the last ones, for the bench.
    @ObservationIgnored private(set) var lags: [TimeInterval] = []

    /// Mail of yours nobody answered by its reminder (MailFollowups), back
    /// in the inbox now: said in one line, "Mila hasn’t answered", its
    /// subject under it, with new mail's buttons, in the thread's own place
    /// in Notification Center. As the account's notifications are set and
    /// macOS allows, never while you're looking at mail.
    func reminded(_ engine: MailCenter.Engine, threads: [String]) async {
        let account = engine.account
        guard !threads.isEmpty, mode(account) != .off else { return }
        await refresh()
        guard permission == .allowed, !mailInFront else { return }
        for thread in threads {
            guard let found = engine.store.thread(thread) else { continue }
            let one = MailNotify.reminder(found, account: account)
            await center.post(one)
            standing[one.id] = (account, one.threads)
            posted.append(one)
            if posted.count > 50 { posted.removeFirst() }
        }
    }

    /// A reminder's notification: who hasn't answered, as the new tab says
    /// it, and the subject.
    nonisolated static func reminder(_ thread: MailThread, account: String) -> Posted {
        let who = thread.people.first.map { $0.said.components(separatedBy: " ").first ?? $0.said }
        return Posted(id: "mail|\(account)|\(thread.id)", account: account, threads: [thread.id],
                      title: who.map { "\($0) hasn’t answered" } ?? "Nobody has answered",
                      subtitle: thread.subject.isEmpty ? "(no subject)" : thread.subject, body: "")
    }

    /// Mail counts as new from when the account came in, or from when this
    /// came to it: what was there before never says anything, whatever its
    /// first sorting takes.
    nonisolated static func begin(_ store: MailStore, now: Date = Date()) {
        if store.value("notify-since") == nil { store.set("notify-since", String(now.timeIntervalSince1970)) }
    }

    /// From when mail counts as new for an account: when its notifications
    /// began (kept with its mail), and never more than an hour back.
    nonisolated static func since(_ store: MailStore, now: Date) -> Date {
        guard let began = store.value("notify-since").flatMap(Double.init).map(Date.init(timeIntervalSince1970:)) else {
            store.set("notify-since", String(now.timeIntervalSince1970))
            return now
        }
        return max(began, now.addingTimeInterval(-window))
    }

    /// The threads of a store a notification would say now, oldest first:
    /// in the mode's list, their last mail from someone else come since
    /// `since`, read by the rules (MailSense), and not said before. Never
    /// your own last word, never mail from a sender you blocked or in Trash
    /// or spam, never a thread muted (⇧M, or `muted` here), nor one whose
    /// reading waits for the Mac's model (`holding`: a stranger's mail the
    /// model may yet call a sales pitch, said once it has read it); in
    /// Needs you never a list's or a code's, which MailSplit leaves in
    /// Other. A mail the rules haven't read yet waits for its own sorting:
    /// a sync that came while another was sorted would show a code as
    /// needing you. With splits (`sort`): Needs you's is what no split took,
    /// with what a split that notifies holds; Everything in Inbox leaves
    /// out what a quiet split took. A split that skips the inbox never says
    /// anything: its mail left the inbox before this looked.
    nonisolated static func fresh(in store: MailStore, mode: Mode, since: Date, now: Date = Date(), muted: Set<String> = [],
                                  sort: MailSplitSort = .none, holding: Set<String> = []) -> [Note] {
        guard mode != .off else { return [] }
        let threads: [(MailThread, MailSensed?)]
        if mode == .needs, sort.rules.isEmpty {
            threads = MailSplit.threads(.needs, in: store, now: now)
        } else if mode == .needs {
            let came = store.facts(now: now).filter { !$0.snoozed && $0.inbox && $0.last > since }
            let placed = sort.place(came, me: store.me, answers: sort.answers(store, among: came.map(\.id), now: now), now: now)
            let ids = came.filter { fact in
                if let home = placed.home[fact.id] { return sort.rules[home].notify }
                let member = placed.member[fact.id] ?? 0
                if sort.rules.indices.contains(where: { member & (1 << UInt64($0)) != 0 && sort.rules[$0].notify }) { return true }
                return MailSplit.of(fact, now: now) == .needs
            }.map(\.id)
            let sensed = store.sensed(ids)
            threads = store.threads(ids: ids).map { ($0, sensed[$0.id]) }
        } else {
            let snoozed = Set(store.snoozes().map(\.thread))
            var inbox = store.threads(label: "INBOX", limit: 300).filter { !snoozed.contains($0.id) }
            if !sort.rules.isEmpty {
                let new = Set(inbox.filter { $0.last > since }.map(\.id))
                let came = store.facts(now: now).filter { new.contains($0.id) }
                let placed = sort.place(came, me: store.me, answers: sort.answers(store, among: Array(new), now: now), now: now)
                inbox = inbox.filter { thread in placed.home[thread.id].map { sort.rules[$0].notify } ?? true }
            }
            threads = inbox.map { ($0, store.sensed($0.id)) }
        }
        let me = store.me
        let said = store.notified()
        // Kept out (Block Sender): their mail is in Trash as it comes
        // (MailOps.keepBlocked), never said, though a thread others write
        // in stays in the inbox.
        let blocked = store.blocked().map(\.who)
        var out: [Note] = []
        for (thread, sensed) in threads where thread.last > since && !thread.lastIsMine && !thread.muted && !muted.contains(thread.id)
            && !holding.contains(thread.id) {
            guard let last = store.messages(thread: thread.id).last(where: { $0.from.address != me }), last.date > since,
                  last.labels.isDisjoint(with: ["TRASH", "SPAM"]), !MailBlock.blocks(blocked, last.from.address),
                  said[thread.id] != last.id, let sensed, sensed.message == last.id else { continue }
            let gist = sensed.gist
            out.append(Note(thread: thread.id, message: last.id, who: last.from.said,
                            subject: thread.subject.isEmpty ? "(no subject)" : thread.subject,
                            line: gist.isEmpty ? MailSense.preview(last) : gist, at: last.date,
                            code: sensed.kind == .code ? store.code(message: last.id) : nil))
        }
        return out.sorted { $0.at < $1.at }
    }

    /// What goes to the Mac: one notification each, or, past three, one
    /// for them all saying how many and from whom.
    nonisolated static func posts(_ notes: [Note], account: String, mode: Mode, accounts: Int) -> [Posted] {
        let codes = notes.filter { $0.code != nil }
        if !codes.isEmpty {
            let plain = notes.filter { $0.code == nil }
            return codes.map { note in
                let read = note.code!
                let line = read.purpose == .purchase
                    ? ["Card transaction", read.amount, read.merchant.map { "at " + $0 }].compactMap { $0 }.joined(separator: ", ")
                    : "Sign-in code"
                return Posted(id: "mail|\(account)|\(note.thread)", account: account, threads: [note.thread],
                              title: note.who + " · " + read.shown, subtitle: "", body: line, codeMessage: note.message)
            } + (plain.isEmpty ? [] : posts(plain, account: account, mode: mode, accounts: accounts))
        }
        guard notes.count > 3 else {
            return notes.map { note in
                Posted(id: "mail|\(account)|\(note.thread)", account: account, threads: [note.thread],
                       title: note.who, subtitle: note.subject, body: note.line)
            }
        }
        var names: [String] = []
        for note in notes.reversed() where !names.contains(note.who) { names.append(note.who) }
        let first = names.prefix(3).joined(separator: ", ")
        return [Posted(id: "mail|\(account)|batch", account: account, threads: notes.map(\.thread),
                       title: "\(notes.count) new in \(mode == .inbox ? "Inbox" : "Needs you")",
                       subtitle: accounts > 1 ? account : "",
                       body: names.count > 3 ? first + " and \(names.count - 3) more" : first)]
    }

    /// Notifications still standing whose mail you've dealt with here,
    /// read, done or put off: taken out of Notification Center.
    func tidy() {
        var gone: [String] = []
        for (id, stood) in standing {
            let store = MailCenter.shared.engines[stood.account]?.store
            let open = stood.threads.contains { thread in
                store?.thread(thread).map { $0.unread && $0.labels.contains("INBOX") } ?? false
            }
            if !open { gone.append(id) }
        }
        guard !gone.isEmpty else { return }
        for id in gone { standing[id] = nil }
        center.remove(gone)
    }

    /// Disconnect: whatever Notification Center still shows of the account
    /// goes, whichever launch of Yab posted it, the batch's too.
    func forget(_ account: String) async {
        standing = standing.filter { $0.value.account != account }
        modes[account] = nil
        let prefix = "mail|\(account)|"
        let gone = await center.delivered().filter { $0.hasPrefix(prefix) }
        if !gone.isEmpty { center.remove(gone) }
    }

    // MARK: - the badge

    /// The Dock's badge, from what MailCenter has just counted.
    func badge(needs: Int, unreadNeeds: Int = 0, unread: Int) {
        guard let app = NSApp else { return }
        let label = MailNotify.label(badgeMode, needs: needs, unreadNeeds: unreadNeeds, unread: unread)
        if app.dockTile.badgeLabel != label { app.dockTile.badgeLabel = label }
    }

    nonisolated static func number(_ mode: Badge, needs: Int, unreadNeeds: Int = 0, unread: Int) -> Int {
        switch mode {
        case .needs: return needs
        case .unreadNeeds: return unreadNeeds
        case .unread: return unread
        case .off: return 0
        }
    }

    nonisolated static func label(_ mode: Badge, needs: Int, unreadNeeds: Int = 0, unread: Int) -> String? {
        let count = number(mode, needs: needs, unreadNeeds: unreadNeeds, unread: unread)
        return count > 0 ? String(count) : nil
    }

    // MARK: - answers

    /// A notification answered. Open and Reply bring Yab and mail up on
    /// the thread, Reply with the reply written ahead in its composer;
    /// Mark Done and Remind Me Tomorrow go as E and H do, so ⌘Z in mail
    /// takes them back. Nothing sends.
    func answer(_ act: Act, account: String, threads: [String], message: String? = nil) async {
        // Clicked as Yab started: mail's accounts come up first, if it has them.
        for _ in 0..<40 where MailCenter.shared.engines[account] == nil && MailCenter.shared.accounts.contains(account) {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        let thread = threads.count == 1 ? threads.first : nil
        let desk = MailDesk.shared
        switch act {
        case .open, .reply:
            guard let browser = forward() else { return }
            guard let thread, let store = MailCenter.shared.engines[account]?.store else {
                // Several: mail, on the list they're in.
                browser.enterMail()
                if mode(account) == .needs, MailList.shared.split != "needs" { MailList.shared.split = "needs" }
                break
            }
            // In Needs you, or the split that took it, on that list, so J and
            // K walk its neighbors.
            var address = URLComponents(string: "yab://mail")!
            let sort = MailList.shared.sort
            let found = store.thread(thread)
            if let found, let home = sort.place(found, in: store).home {
                if MailList.shared.split != sort.rules[home].id { MailList.shared.split = sort.rules[home].id }
                address.fragment = "thread=" + account + "|" + thread
            } else if found.flatMap({ MailSplit.of($0, sensed: store.sensed(thread)) }) == .needs {
                address.path = "/needs/\(account)/\(thread)"
            } else {
                address.fragment = "thread=" + account + "|" + thread
            }
            browser.enterMail(address.url)
            if act == .reply { desk.reply() }
        case .copyCode:
            guard let thread, let message,
                  let item = MailCodeState.shared.item(account: account, thread: thread, message: message) else { return }
            MailCodeState.shared.copy(item)
        case .done:
            guard let thread else { return }
            desk.done(account: account, thread: thread)
        case .remind:
            guard let thread, let tomorrow = MailLater.snoozes(for: nil, meetings: []).first(where: { $0.label == "Tomorrow morning" }) else { return }
            desk.snooze(account: account, thread: thread, at: tomorrow.at, why: tomorrow.label + ", " + tomorrow.detail)
        }
        let id = thread.map { "mail|\(account)|\($0)" } ?? "mail|\(account)|batch"
        standing[id] = nil
        center.remove([id])
    }

    /// Yab in front, its browser's window with it, for what a click opens.
    /// A test world's stays where it is: the keyboard is the person's.
    private func forward() -> Browser? {
        let browser = Links.browser
        guard !Store.testing else { return browser }
        if Headless.hidden {
            Headless.show(.request)
            Links.showBrowser()
        }
        NSApp.activate(ignoringOtherApps: true)
        if let browser, let window = BrowserWindows.shared.window(for: browser) { window.makeKeyAndOrderFront(nil) }
        return browser
    }

    /// One comes while Yab is in front: a banner, unless it's mail you're
    /// looking at.
    func presenting() -> UNNotificationPresentationOptions {
        mailInFront ? [] : [.banner, .sound, .list]
    }

    // MARK: - the bench

    /// What a test world posted and was asked, and the Dock's badge.
    func benchState() -> [String: Any] {
        let record = center as? Record
        return ["permission": permission.rawValue, "asks": record?.asks ?? 0, "settingsOpened": record?.settingsOpened ?? 0,
                "modes": Dictionary(uniqueKeysWithValues: MailCenter.shared.accounts.map { ($0, mode($0).rawValue) }),
                "badgeMode": badgeMode.rawValue, "badge": NSApp?.dockTile.badgeLabel ?? "", "removed": record?.removed ?? [],
                "front": mailInFront, "lags": lags.suffix(20).map { ($0 * 1000).rounded() / 1000 }]
    }

    var benchPosted: [[String: Any]] {
        posted.map { ["id": $0.id, "account": $0.account, "threads": $0.threads, "title": $0.title, "subtitle": $0.subtitle,
                      "body": $0.body, "batch": $0.batch] }
    }

    /// A test world's macOS saying yes, no, or nothing yet.
    func benchPermission(_ state: Permission) async {
        (center as? Record)?.state = state
        await refresh()
    }

    func benchClear() {
        posted = []
        (center as? Record)?.clear()
    }
}

/// Where notifications go: the Mac's own, or, in a test world and in tests,
/// a record of them.
@MainActor
protocol MailNotifyCenter: AnyObject {
    /// What macOS allows, read without asking.
    func permission() async -> MailNotify.Permission
    /// macOS's question: from Allow…, or once by a chat's question that
    /// waits on it (AgentNotices.ask).
    func ask() async
    /// The buttons a mail's notification wears, told to the Mac.
    func prepare()
    func post(_ posted: MailNotify.Posted) async
    func remove(_ ids: [String])
    /// The ids of what Notification Center shows of Yab's now.
    func delivered() async -> [String]
    /// System Settings › Notifications, where only the person can turn
    /// them on again.
    func openSettings()
}

/// The Mac's Notification Center.
@MainActor
final class MailNotifySystem: MailNotifyCenter {
    private var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }

    func permission() async -> MailNotify.Permission {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .allowed
        case .denied: return .denied
        default: return .unasked
        }
    }

    func ask() async { _ = try? await center.requestAuthorization(options: [.alert, .sound]) }

    /// Mail's buttons, set with the sites' (AgentNotices.prepareCategories):
    /// setting them replaces the app's set.
    func prepare() { AgentNotices.prepareCategories() }

    nonisolated static var categories: Set<UNNotificationCategory> {
        let done = UNNotificationAction(identifier: MailNotify.Act.done.rawValue, title: "Mark Done", options: [])
        let remind = UNNotificationAction(identifier: MailNotify.Act.remind.rawValue, title: "Remind Me Tomorrow", options: [])
        let copy = UNNotificationAction(identifier: MailNotify.Act.copyCode.rawValue, title: "Copy Code", options: [])
        let reply = UNNotificationAction(identifier: MailNotify.Act.reply.rawValue, title: "Reply", options: [.foreground])
        return [
            UNNotificationCategory(identifier: MailNotify.codeCategory, actions: [copy, done], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: MailNotify.category, actions: [done, remind, reply], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: MailNotify.batchCategory, actions: [], intentIdentifiers: [], options: []),
        ]
    }

    func post(_ posted: MailNotify.Posted) async {
        let content = UNMutableNotificationContent()
        content.title = posted.title
        content.subtitle = posted.subtitle
        content.body = posted.body
        content.sound = .default
        // One stack an account in Notification Center.
        content.threadIdentifier = "mail." + posted.account
        content.categoryIdentifier = posted.codeMessage != nil ? MailNotify.codeCategory : posted.batch ? MailNotify.batchCategory : MailNotify.category
        content.userInfo = ["mail": posted.account, "threads": posted.threads]
        if let message = posted.codeMessage { content.userInfo["codeMessage"] = message }
        // The same id for a thread's next mail: it takes the last one's place.
        try? await center.add(UNNotificationRequest(identifier: posted.id, content: content, trigger: nil))
    }

    func remove(_ ids: [String]) { center.removeDeliveredNotifications(withIdentifiers: ids) }

    func delivered() async -> [String] { await center.deliveredNotifications().map(\.request.identifier) }

    func openSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }
}

extension MailNotify {
    /// What a test world posts instead of showing it: kept for the bench,
    /// never on screen. macOS's answer is whatever the bench says.
    @MainActor
    final class Record: MailNotifyCenter {
        var state: Permission = .allowed
        private(set) var posts: [Posted] = []
        private(set) var removed: [String] = []
        private(set) var asks = 0
        private(set) var settingsOpened = 0

        func permission() async -> Permission { state }
        func ask() async {
            asks += 1
            if state == .unasked { state = .allowed }
        }
        func prepare() {}
        func post(_ posted: Posted) async { posts.append(posted) }
        func remove(_ ids: [String]) { removed += ids }
        /// Shown by a Yab before this one, still in Notification Center.
        var earlier: [String] = []
        func delivered() async -> [String] { (earlier + posts.map(\.id)).filter { !removed.contains($0) } }
        func openSettings() { settingsOpened += 1 }
        func clear() {
            posts = []
            removed = []
        }
    }
}

/// Settings › Mail's Notifications: what says so when mail comes, for each
/// account (the Dock's count is with what needs you, MailSortSettings).
/// macOS is asked nothing until Allow… is pressed.
struct MailNotifySettings: View {
    private var notify = MailNotify.shared
    private var center = MailCenter.shared

    var body: some View {
        Section {
            if notify.permission != .allowed {
                SettingsRow("Notifications are off for Yab", detail: notify.permission == .denied
                            ? "Enable notifications in System Settings."
                            : "Press Allow to request notification access.") {
                    Button("Allow…") { Task { await notify.allow() } }
                        .settingsButton()
                }
                .settingsAnchor("mail-notify-allow")
            }
            ForEach(center.accounts, id: \.self) { account in
                SettingsRow(center.accounts.count > 1 ? account : "New mail") {
                    DropMenu("New mail", options: MailNotify.Mode.allCases.map { (title: $0.title, value: $0) },
                             selection: Binding(get: { notify.mode(account) }, set: { notify.setMode($0, for: account) }))
                        .fixedSize()
                }
                // The search finds the first; each row keeps an id of its own.
                .settingsAnchor(account == center.accounts.first ? "mail-notify" : "mail-notify-" + account)
            }
        } footer: {
            SettingsNote("Notifications offer Mark Done, Remind Me Tomorrow and Reply. Reply opens a draft without sending. No alerts while Mail is active.")
        }
    }
}
