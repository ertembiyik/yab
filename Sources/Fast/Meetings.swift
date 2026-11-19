import AppKit
import Combine
@preconcurrency import EventKit
import SwiftUI

// Your next meeting, from the Google accounts connected for mail (their
// calendars come in the same consent, read only), and from the Mac's own
// calendars (EventKit) where macOS already lets Yab read them: an iCloud or
// Exchange account added in System Settings.
//
// On a calendar you pinned, a
// countdown under its mark once the meeting is within the hour, and a
// minute before it starts, Join, which opens its link, or goes back to the
// tab already in it. ⌃⌘J does the same from anywhere. On the call itself,
// the last five minutes are counted on its tab, which gives one small
// shake at five and at two. A minute before, the corner's notice says it
// with Join (Toast.swift), in the window you are in; flung away, that
// occurrence stays quiet. With another app in front, it floats over the
// screen you are on instead (MeetingFloat).

@MainActor
@Observable final class Meetings {
    static let shared = Meetings()

    /// Today's and tomorrow's, soonest first, gone ones left out.
    private(set) var list: [Meeting] = [] { didSet { refreshReminder() } }
    private(set) var reminder: Meeting?
    /// The card came ten minutes early, for what is open with its people.
    private(set) var reminderEarly = false
    /// What is open with its people: what you promised, what they owe you.
    private(set) var reminderOpen: [MailCenter.MeetingOpen] = []
    private var reminders = MeetingReminders()
    /// The minute, for everything that counts down by it.
    private(set) var now = Date() { didSet { refreshReminder() } }

    /// Settings › Tabs: on unless turned off; it does nothing until the Mac
    /// lets yab read the calendars.
    var wanted: Bool = Store.settings.object(forKey: "meetings.show") as? Bool ?? true {
        didSet {
            Store.settings.set(wanted, forKey: "meetings.show")
            if wanted { start() } else { stop() }
        }
    }

    /// Made when first read, not with Meetings: the window's first body
    /// makes Meetings (CornerNotices), and an event store is 6-8 ms of the
    /// main thread before the window's first frame, for a calendar read
    /// only once the launch is over (YAB_LAUNCH_EVENTSTORE_LAZY=0 makes it
    /// with Meetings, as before).
    @ObservationIgnored private lazy var store = EKEventStore()
    @ObservationIgnored private var ticking: Timer?
    @ObservationIgnored private var watch: NSObjectProtocol?
    /// Meetings the bench made up, in place of the calendar's.
    private var made: [Meeting]?

    /// Where the calendars are read. EventKit answers over XPC: 10 to 40 ms
    /// for a day's events even with nothing to read and 40 for the first
    /// look at the permission (measured), more with a full calendar, and a
    /// sync lands as a burst of changes. None of it on the main thread,
    /// which only takes the finished list.
    private let queue = DispatchQueue(label: "dev.serafim.fast.meetings", qos: .utility)
    /// A read under way, and whether another was asked for meanwhile.
    private var reading = false
    private var again = false
    /// Bumped by stop, so a read still under way then lands nowhere.
    private var generation = 0

    /// The Mac's calendars' last read, and Google's.
    private var local: [Meeting] = []
    private var google: [Meeting] = []
    /// When Google's calendars were last read: every five minutes, not on
    /// every minute's turn.
    private var readGoogle: Date?

    /// The calendar's permission, asked once and kept until Yab comes to
    /// front again or asks for access: each ask is a synchronous trip to
    /// the calendar daemon when no event store is open yet (lazy since the
    /// night launch work), 19 ms on adhd on every ⌘T, whose empty list
    /// asks it (Noticing). YAB_CAL_STATUS_CACHE=0 asks every time.
    nonisolated(unsafe) private static var knownStatus: EKAuthorizationStatus?
    private static let caches = ProcessInfo.processInfo.environment["YAB_CAL_STATUS_CACHE"] != "0"
    nonisolated(unsafe) private static var forgetting: NSObjectProtocol?
    static var status: EKAuthorizationStatus {
        guard caches else { return EKEventStore.authorizationStatus(for: .event) }
        if let knownStatus { return knownStatus }
        let now = EKEventStore.authorizationStatus(for: .event)
        knownStatus = now
        if forgetting == nil {
            forgetting = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                                object: nil, queue: .main) { _ in Meetings.forgetStatus() }
        }
        return now
    }
    /// Asked again next time: access was just asked for, or may have
    /// changed in System Settings while Yab was away.
    nonisolated static func forgetStatus() { knownStatus = nil }
    nonisolated static func requestAccess(_ store: EKEventStore) async throws -> Bool {
        defer { forgetStatus() }
        return try await store.requestFullAccessToEvents()
    }
    var allowed: Bool { made != nil || Meetings.status == .fullAccess || online }
    /// A Google account that gave its calendar, or an Outlook one.
    private var online: Bool { !MeetingsGoogle.accounts.isEmpty || !OutlookCalendars.shared.accounts.isEmpty }
    /// Wanted, and nothing to read meetings from: no Google account gave
    /// its calendar, no Outlook one is connected, and the Mac's calendars aren't let in. A pinned
    /// calendar says so on its card, with Connect; never asked by itself.
    var unconnected: Bool { wanted && !allowed }
    var undecided: Bool { made == nil && Meetings.status == .notDetermined && !online }

    private init() {
        if !Startup.flag("EVENTSTORE_LAZY") { _ = store }
    }

    private func refreshReminder() {
        let mail = MailCenter.shared, at = now
        let picked = reminders.pick(in: wanted ? list : [], at: at) { !mail.open(with: $0.people, now: at).isEmpty }
        if reminder != picked?.meeting { reminder = picked?.meeting }
        if reminderEarly != (picked?.early ?? false) { reminderEarly = picked?.early ?? false }
        let open = picked.map { mail.open(with: $0.meeting.people, now: at) } ?? []
        if open != reminderOpen { reminderOpen = open }
    }

    func dismissReminder() {
        if let reminder { reminders.dismiss(reminder, early: reminderEarly) }
        refreshReminder()
    }

    /// Mail changed: what is open with the card's people may have too.
    func mailChanged() { if reminder != nil || !list.isEmpty { refreshReminder() } }

    /// At launch, and whenever it is let in: reads, then keeps up. The
    /// permission is first looked at on the queue: at launch that look is
    /// the slow one.
    func start() {
        guard wanted else { return }
        guard made == nil else { return begin() }
        // A Google or Outlook account connected: no need to wait on the Mac's answer.
        if online { readGoogle = nil; return begin() }
        // The last one gone: its meetings with it, whatever the Mac says.
        if !google.isEmpty { google = []; readGoogle = nil; merge() }
        let generation = self.generation
        queue.async { [weak self] in
            let status = EKEventStore.authorizationStatus(for: .event)
            DispatchQueue.main.async {
                guard let self, self.generation == generation, status == .fullAccess else { return }
                self.begin()
            }
        }
    }

    private func begin() {
        guard wanted, allowed else {
            // The last account gone, and the Mac's calendars never let in.
            local = []; google = []; list = []
            return
        }
        if watch == nil, Meetings.status == .fullAccess {
            watch = NotificationCenter.default.addObserver(
                forName: .EKEventStoreChanged, object: store, queue: .main
            ) { [weak self] _ in
                // A burst of these is one read, a moment after the first.
                MainActor.assumeIsolated { self?.read(after: 0.3) }
            }
        }
        read()
        tick()
    }

    private func stop() {
        generation += 1
        reading = false
        again = false
        ticking?.invalidate()
        ticking = nil
        if let watch { NotificationCenter.default.removeObserver(watch) }
        watch = nil
        list = []
        local = []
        google = []
        readGoogle = nil
    }

    /// The Mac's question, once: true if yab may read the calendars now.
    func ask() async -> Bool {
        guard Meetings.status == .notDetermined else { return allowed }
        let yes = (try? await Meetings.requestAccess(store)) ?? false
        if yes {
            start()
            // Read before answering: Join, asked the moment the Mac says
            // yes, looks at the list right after.
            let store = self.store
            let found = await withCheckedContinuation { done in
                queue.async { done.resume(returning: Meetings.fetch(store)) }
            }
            if made == nil { local = found; merge() }
            now = Date()
        }
        return yes
    }

    /// A timer for the turn of each minute, not a poll: the countdown moves
    /// then, and only then.
    private func tick() {
        ticking?.invalidate()
        let date = Date()
        let next = Calendar.current.nextDate(after: date, matching: DateComponents(second: 0), matchingPolicy: .nextTime) ?? date.addingTimeInterval(60)
        ticking = Timer.scheduledTimer(withTimeInterval: next.timeIntervalSince(date) + 0.05, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.now = Date()
                // Past midnight, tomorrow's meetings are today's: read again.
                if !Calendar.current.isDate(self.now, inSameDayAs: date) {
                    self.readGoogle = nil
                    self.read()
                } else if let last = self.readGoogle, self.now.timeIntervalSince(last) >= 5 * 60 {
                    self.readFromGoogle()
                }
                self.tick()
            }
        }
    }

    /// Today's and tomorrow's, read on the queue. One read at a time; one
    /// asked for meanwhile runs after it.
    private func read(after delay: TimeInterval = 0) {
        if let made { list = made.filter { $0.end > Date() }.sorted { $0.start < $1.start }; return }
        guard allowed else { return }
        if readGoogle == nil { readFromGoogle() }
        guard Meetings.status == .fullAccess else { return }
        guard !reading else { again = true; return }
        reading = true
        let generation = self.generation
        queue.asyncAfter(deadline: .now() + delay) { [weak self, store] in
            let found = Meetings.fetch(store)
            DispatchQueue.main.async {
                guard let self, self.generation == generation else { return }
                self.reading = false
                if self.made == nil { self.local = found; self.merge() }
                self.now = Date()
                if self.again {
                    self.again = false
                    self.read(after: 0.3)
                }
            }
        }
    }

    /// Google's calendars, every connected account's at once, and
    /// Outlook's; an account that can't be read keeps what it had.
    private func readFromGoogle() {
        let accounts = MeetingsGoogle.accounts
        let outlook = OutlookCalendars.shared
        guard !accounts.isEmpty || !outlook.accounts.isEmpty else {
            if !google.isEmpty { google = []; merge() }
            return
        }
        readGoogle = Date()
        let generation = self.generation
        Task {
            var found: [Meeting] = []
            for account in accounts {
                // The mail's own line and token, or one of its own while the mail is off.
                let gmail = MailCenter.shared.engines[account]?.gmail ?? MailClient.configured.map { client in
                    let auth = MailAuth(account: account, client: client)
                    return MailGmail(token: { try await auth.token() })
                }
                var read: [Meeting]?
                if let gmail { read = await MeetingsGoogle.read(account, gmail: gmail) }
                found += read ?? google.filter { $0.id.hasSuffix("|" + account) }
            }
            for account in outlook.accounts {
                found += await outlook.read(account) ?? google.filter { $0.id.hasSuffix("|outlook:" + account) }
            }
            guard self.generation == generation, made == nil else { return }
            google = found
            merge()
            now = Date()
        }
    }

    /// The lists as one, soonest first: a meeting both the Mac and Google
    /// have (the same account added in System Settings), or two connected
    /// accounts are both invited to, once.
    private func merge() {
        var seen = Set<String>()
        let all = (google + local).filter { $0.end > Date() && seen.insert("\($0.title)|\($0.start.timeIntervalSince1970)").inserted }
            .sorted { $0.start < $1.start }
        if all != list { list = all }
    }

    // MARK: - busy, any day

    /// The last stretch read, kept a minute: J and K through invitations,
    /// or the slots asked again, don't ask Google again.
    private var busyKept: (from: Date, to: Date, at: Date, list: [BusyTime])?

    /// What is taken from one moment to another (docs/mail.md, Calendar):
    /// each connected Google account's calendars (MeetingsGoogle.busy),
    /// read with the calendar.events.readonly it gave, and the Mac's calendars where
    /// macOS already lets Yab read them; never asked for. A test world
    /// reads only its fake's. Nil when no calendar could be read.
    func busy(from: Date, to: Date) async -> [BusyTime]? {
        if let made {
            return made.map { BusyTime(title: $0.title, start: $0.start, end: $0.end) }.filter { $0.start < to && $0.end > from }
        }
        if let kept = busyKept, kept.from <= from, kept.to >= to, Date().timeIntervalSince(kept.at) < 60 {
            return kept.list.filter { $0.start < to && $0.end > from }
        }
        let accounts = MeetingsGoogle.accounts.compactMap { account in MailCenter.shared.engines[account]?.gmail.map { (account, $0) } }
        let mac = !Store.testing && Meetings.status == .fullAccess
        let outlook = OutlookCalendars.shared
        guard !accounts.isEmpty || !outlook.accounts.isEmpty || mac else { return nil }
        var found: [BusyTime] = []
        var read = false
        for (account, gmail) in accounts {
            guard let got = await MeetingsGoogle.busy(account, gmail: gmail, from: from, to: to) else { continue }
            found += got
            read = true
        }
        for account in outlook.accounts {
            guard let got = await outlook.busy(account, from: from, to: to) else { continue }
            found += got
            read = true
        }
        if mac {
            let store = self.store
            found += await withCheckedContinuation { done in queue.async { done.resume(returning: Meetings.busy(store, from: from, to: to)) } }
            read = true
        }
        guard read else { return nil }
        found.sort { $0.start < $1.start }
        busyKept = (from, to, Date(), found)
        return found
    }

    /// The Mac's calendars between two moments: not canceled, not
    /// declined, not shown as free. Slow: on the queue only.
    nonisolated static func busy(_ store: EKEventStore, from: Date, to: Date) -> [BusyTime] {
        store.events(matching: store.predicateForEvents(withStart: from, end: to, calendars: nil)).compactMap { event in
            guard event.status != .canceled, event.availability != .free else { return nil }
            let me = event.attendees?.first { $0.isCurrentUser }
            if me?.participantStatus == .declined { return nil }
            return BusyTime(title: event.title ?? "", start: event.startDate, end: event.endDate, uid: event.calendarItemExternalIdentifier ?? "",
                        maybe: me.map { $0.participantStatus != .accepted } ?? false)
        }
    }

    /// Today's and tomorrow's, soonest first, gone ones left out. Slow: on the queue only.
    nonisolated static func fetch(_ store: EKEventStore) -> [Meeting] {
        let from = Date().addingTimeInterval(-4 * 3600), to = Date().addingTimeInterval(26 * 3600)
        let events = store.events(matching: store.predicateForEvents(withStart: from, end: to, calendars: nil))
        return events.compactMap(Meetings.meeting).filter { $0.end > Date() }.sorted { $0.start < $1.start }
    }

    /// Not a day's worth of holiday, not cancelled, not one you said no to.
    nonisolated static func meeting(_ event: EKEvent) -> Meeting? {
        guard !event.isAllDay, event.status != .canceled else { return nil }
        if event.attendees?.contains(where: { $0.isCurrentUser && $0.participantStatus == .declined }) == true { return nil }
        let link = [event.url?.absoluteString, event.location, event.notes].lazy.compactMap { CallLink.find(in: $0) }.first
        let people = (event.attendees ?? []).filter { !$0.isCurrentUser }.compactMap { attendee -> String? in
            let url = attendee.url.absoluteString
            return url.lowercased().hasPrefix("mailto:") ? String(url.dropFirst(7)).lowercased() : nil
        }
        return Meeting(id: event.calendarItemIdentifier + "@\(event.startDate.timeIntervalSince1970)",
                       title: event.title ?? "", start: event.startDate, end: event.endDate, link: link, people: people)
    }

    // MARK: - what the pin and the keys say

    /// The one to count down to, or to join: starting within the hour, or
    /// started up to ten minutes ago and not over.
    func next(at now: Date? = nil) -> Meeting? { Meetings.next(in: list, at: now ?? self.now) }

    static func next(in list: [Meeting], at now: Date) -> Meeting? {
        list.first { $0.end > now && $0.start > now.addingTimeInterval(-10 * 60) && $0.start < now.addingTimeInterval(3600) }
    }

    /// What a pinned calendar says under its mark.
    enum Badge: Equatable {
        case minutes(Int)
        case join
    }

    func badge(at now: Date? = nil, inCall: (String) -> Bool = { _ in false }) -> Badge? {
        Meetings.badge(in: list, at: now ?? self.now, inCall: inCall)
    }

    /// Nothing more than an hour off; from a minute before to ten after,
    /// Join, if there is anything to join and you aren't already in it.
    static func badge(in list: [Meeting], at now: Date, inCall: (String) -> Bool = { _ in false }) -> Badge? {
        guard let meeting = next(in: list, at: now) else { return nil }
        let wait = meeting.start.timeIntervalSince(now)
        if wait <= 60 {
            guard let key = CallLink.key(meeting.link), !inCall(key) else { return nil }
            return .join
        }
        return .minutes(Int((wait / 60).rounded(.up)))
    }

    /// Whole minutes left of the meeting a call is, the last five only.
    func minutesLeft(for key: String?, at now: Date? = nil) -> Int? {
        Meetings.minutesLeft(in: list, for: key, at: now ?? self.now)
    }

    static func minutesLeft(in list: [Meeting], for key: String?, at now: Date) -> Int? {
        guard let key, let meeting = list.first(where: {
            $0.start <= now.addingTimeInterval(15 * 60) && $0.end > now && CallLink.key($0.link) == key
        }) else { return nil }
        let left = Int((meeting.end.timeIntervalSince(now) / 60).rounded(.up))
        return (1...5).contains(left) ? left : nil
    }

    /// A pinned tab that is a calendar, the kind a meeting is kept in.
    static func isCalendar(_ url: URL?) -> Bool {
        guard let host = url?.host()?.lowercased() else { return false }
        let path = url?.path.lowercased() ?? ""
        if benchCalendars.contains(host) { return true }
        switch host {
        case "calendar.google.com", "calendar.notion.so", "app.cal.com", "app.reclaim.ai", "fantastical.app",
             "calendar.proton.me", "calendar.amie.so", "calendar.vimcal.com", "web.morgen.so":
            return true
        case "outlook.office.com", "outlook.office365.com", "outlook.live.com":
            return path.hasPrefix("/calendar")
        default:
            // Zoho's, in each of its regions: calendar.zoho.com, .eu, .in, .com.au.
            return host.hasPrefix("calendar.zoho.")
        }
    }

    // MARK: - bench

    /// Hosts the bench counts as calendars: a test world's local page, where
    /// a real calendar would only be its sign-in.
    static var benchCalendars: Set<String> = []

    /// Meetings of the bench's making, instead of the calendar's.
    /// For the bench: the minute told again, as the clock tells it.
    func benchTick() { now = Date() }

    func pretend(_ meetings: [Meeting]?) {
        busyKept = nil
        made = meetings
        if meetings != nil { list = []; start() } else { read() }
        now = Date()
    }
}

extension Browser {
    /// ⌃⌘J, Join from a pin: the meeting on now, or about to be, on its
    /// call; the tab it is already in, if it is.
    /// ⌃⌘O, and the card's Open Thread: the first of what is open with the
    /// meeting's people (or the line clicked), in mail. False with nothing
    /// open, so the key is the page's.
    @discardableResult
    func openMeetingThread(_ line: MailCenter.MeetingOpen? = nil) -> Bool {
        let meetings = Meetings.shared
        guard let open = line ?? meetings.reminderOpen.first,
              let url = URL(string: "yab://mail#thread=" + open.account + "|" + open.thread) else { return false }
        enterMail(url)
        if meetings.reminderEarly { meetings.dismissReminder() }
        return true
    }

    func joinNextMeeting() {
        let meetings = Meetings.shared
        guard meetings.allowed else {
            guard meetings.undecided else { return announce("Yab can’t see your calendar", mark: "calendar") }
            Task { @MainActor in
                if await meetings.ask() { self.joinNextMeeting() }
            }
            return
        }
        let now = Date()
        // Starting within a quarter of an hour, or on already.
        guard let meeting = meetings.list.first(where: {
            $0.end > now && $0.start < now.addingTimeInterval(15 * 60) && $0.link != nil
        }) else {
            return announce("No meeting soon", mark: "calendar")
        }
        joinMeeting(meeting)
    }

    func joinMeeting(_ meeting: Meeting) {
        guard let link = meeting.link else { return }
        // Joined by any road, ⌃⌘J included: the card has said its piece.
        if Meetings.shared.reminder?.id == meeting.id { Meetings.shared.dismissReminder() }
        if !openCall(link) {
            let tab = open(link, foreground: true)
            if prefs.meetingFolders { meetingFolder(tab, for: meeting) }
        }
    }

    /// Whether a call with this key is on in some tab.
    func inCall(_ key: String) -> Bool {
        everyTab.contains { $0.onCall && (CallLink.key($0.address) == key || CallLink.key($0.callStarted) == key) }
    }

    /// Pinned a calendar: offered once, the next meeting on it.
    func offerMeetings(for tab: Tab) {
        let meetings = Meetings.shared
        guard meetings.wanted, meetings.undecided, Meetings.isCalendar(tab.address),
              !Store.settings.bool(forKey: "meetings.offered")
        else { return }
        Store.settings.set(true, forKey: "meetings.offered")
        Task { @MainActor in
            let yes = await Questions.shared.ask(Question(
                title: "Show your next meeting here?",
                detail: "A countdown on this pin, and Join when it starts. Yab reads your Mac’s calendars for it, and nothing leaves this Mac.",
                glyph: "calendar", yes: "Show", no: "Not Now"
            ))
            if yes { _ = await meetings.ask() } else { meetings.wanted = false }
        }
    }
}

/// A pinned calendar with a meeting coming: the pin says so at its mark's
/// top corner, on the plate a count wears elsewhere (Corner.swift), "12m"
/// within the hour, the number rolling each minute; from a minute before
/// the meeting until you are in it, "Join" on the call's green, and the
/// whole pin is the button. The mark stays where every other pin's is.
struct PinMeeting: ViewModifier {
    let browser: Browser
    var tab: Tab
    let calls: Calls
    /// The pin's own corners, the shape its click takes while it joins.
    let radius: CGFloat

    /// Only a pinned calendar hears the minute and the calls: every other pin,
    /// and there may be dozens, is left alone when either changes.
    func body(content: Content) -> some View {
        if tab.pin != nil, Meetings.isCalendar(tab.address) {
            content.modifier(PinMeetingLive(browser: browser, tab: tab, calls: calls, radius: radius))
        } else {
            content
        }
    }
}

private struct PinMeetingLive: ViewModifier {
    let browser: Browser
    var tab: Tab
    var meetings = Meetings.shared
    var calls: Calls
    let radius: CGFloat

    private var badge: Meetings.Badge? {
        guard tab.pin != nil, Meetings.isCalendar(tab.address), meetings.wanted else { return nil }
        return meetings.badge(inCall: { browser.inCall($0) })
    }

    func body(content: Content) -> some View {
        let badge = self.badge
        let title = meetings.next()?.title ?? "the meeting"
        let corner: Corner? = {
            switch badge {
            case .minutes(let n)?: return Corner(words: "\(n)m")
            case .join?: return Corner(words: "Join", kind: .go)
            case nil: return nil
            }
        }()
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            // Down to the mark, which alone draws it (MarkCorners).
            .environment(\.meetingCorner, corner)
            .accessibilityValue(badge.map { badge -> String in
                if case .minutes(let n) = badge { return "\(title) in \(n) minutes" }
                return "Join \(title)"
            } ?? "")
            .overlay {
                if badge == .join {
                    Button { browser.joinNextMeeting() } label: { Color.clear.contentShape(shape) }
                        .buttonStyle(.plain)
                        .keyTip("Join \(title)")
                        .accessibilityLabel("Join \(title)")
                }
            }
    }
}

extension Meetings {
    /// Join's words on the system green: dark, since white on that green
    /// falls short of 4.5:1.
    static let joinInk = Color(red: 0.04, green: 0.18, blue: 0.09)
}

/// Words in Core Animation text layers: the letters around the number stand
/// still, and when the number changes only it rolls, down as it counts
/// down, in one transition the render server runs. Done as SwiftUI's
/// numeric content transition, every frame of the roll redrew the text on
/// the main thread with a blur and laid the window out again, about 130 ms
/// a change; here it is a few.
struct RollingText: NSViewRepresentable {
    let text: String
    let font: NSFont
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var still

    func makeNSView(context: Context) -> RollingTextView { RollingTextView() }

    func updateNSView(_ view: RollingTextView, context: Context) {
        view.update(text, font: font, color: color.resolve(in: context.environment).cgColor, still: still)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: RollingTextView, context: Context) -> CGSize? {
        RollingTextView.size(text, font: font)
    }
}

final class RollingTextView: NSView {
    private let before = CATextLayer()
    private let number = CATextLayer()
    private let after = CATextLayer()
    /// Clips the number while it rolls: a plain rectangle, no mask.
    private let slot = CALayer()
    private var shown: String?
    private var font: NSFont?

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = CALayer()
        wantsLayer = true
        slot.masksToBounds = true
        layer?.addSublayer(before)
        layer?.addSublayer(slot)
        slot.addSublayer(number)
        layer?.addSublayer(after)
        for text in [before, number, after] {
            text.alignmentMode = .left
            text.truncationMode = .none
            text.isWrapped = false
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for text in [before, number, after] { text.contentsScale = scale }
    }

    /// "in 12m" → ("in ", "12", "m"); words with no number are all "before".
    static func parts(_ text: String) -> (String, String, String) {
        guard let range = text.range(of: #"\d+"#, options: .regularExpression) else { return (text, "", "") }
        return (String(text[..<range.lowerBound]), String(text[range]), String(text[range.upperBound...]))
    }

    static func width(_ text: String, font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    static func size(_ text: String, font: NSFont) -> CGSize {
        CGSize(width: width(text, font: font).rounded(.up), height: (font.ascender - font.descender).rounded(.up))
    }

    func update(_ text: String, font: NSFont, color: CGColor, still: Bool) {
        let old = shown.map(Self.parts)
        let new = Self.parts(text)
        // Only a number changing between the same words rolls; anything
        // else lands at once.
        let rolls = !still && window != nil && old != nil && old!.1 != new.1 && old!.0 == new.0 && old!.2 == new.2 && !new.1.isEmpty
        let down = rolls && (Int(new.1) ?? 0) < (Int(old!.1) ?? 0)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let scale = window?.backingScaleFactor ?? 2
        let height = (font.ascender - font.descender).rounded(.up)
        let wBefore = Self.width(new.0, font: font), wNumber = Self.width(new.1, font: font), wAfter = Self.width(new.2, font: font)
        for (layer, words) in [(before, new.0), (number, new.1), (after, new.2)] {
            if self.font != font { layer.font = font; layer.fontSize = font.pointSize }
            layer.foregroundColor = color
            layer.contentsScale = scale
            layer.string = words
        }
        self.font = font
        before.frame = CGRect(x: 0, y: 0, width: wBefore.rounded(.up), height: height)
        slot.frame = CGRect(x: wBefore, y: 0, width: wNumber.rounded(.up) + 1, height: height)
        number.frame = slot.bounds
        after.frame = CGRect(x: wBefore + wNumber, y: 0, width: wAfter.rounded(.up) + 1, height: height)
        CATransaction.commit()
        if rolls {
            let roll = CATransition()
            roll.type = .push
            // Counting down, the next number comes from above, as on a
            // clock's wheel turning toward you.
            roll.subtype = down ? .fromTop : .fromBottom
            roll.duration = 0.22
            roll.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            number.add(roll, forKey: "roll")
        }
        shown = text
    }
}

/// A small shake as it appears and each time `at` changes: side to side,
/// less each time, in under half a second. Not with Reduce Motion.
struct Nudge: ViewModifier {
    let at: Int
    @State private var shakes = 0
    @Environment(\.accessibilityReduceMotion) private var still

    func body(content: Content) -> some View {
        content
            .keyframeAnimator(initialValue: CGFloat(0), trigger: shakes) { view, x in
                view.offset(x: x)
            } keyframes: { _ in
                KeyframeTrack {
                    SpringKeyframe(-2, duration: 0.07)
                    SpringKeyframe(2, duration: 0.09)
                    SpringKeyframe(-1.5, duration: 0.09)
                    SpringKeyframe(1, duration: 0.08)
                    SpringKeyframe(0, duration: 0.1)
                }
            }
            .onAppear { if !still { shakes += 1 } }
            .onChange(of: at) { _, _ in if !still { shakes += 1 } }
    }
}
