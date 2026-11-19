import AppKit
import Combine
import os
import SwiftUI

// Mail as a space of its own (docs/mail.md, The mail space). The column says
// where you are: which account, which list, and Kept, what you chose to have
// at hand. The middle is one page, yab://mail: the list, and a thread in its
// place on ↩, esc back to the same row. It is not in your saved list of
// spaces and nowhere a tab can be sent, but it stands among them in the
// column's foot and the tray, in a place of your choosing (`mailPlace`),
// ⌃1 to ⌃9 counting it there, with an emoji and a look of its own. ⇧⌘I,
// its place in the foot, the envelope there with spaces off, or the mail
// pin go in and out; any yab://mail address, a new tab's row, the field's,
// lands here.

extension Space {
    static let mailID = UUID(uuidString: "00000000-0000-0000-0000-00000000A11E")!
    /// Signed in where the first space is: a link from a mail opens as you.
    /// Its emoji and look are yours to change, kept apart from the list.
    static var mail: Space {
        _ = MailSpaceLook.revision.count
        if let kept = MailSpaceLook.cached.withLock({ $0 }) { return kept }
        var space = Space(id: mailID, name: "Mail", icon: Store.settings.string(forKey: MailSpaceLook.iconKey) ?? "✉️", ownSignIns: false)
        space.paint = Store.settings.data(forKey: MailSpaceLook.paintKey).flatMap { try? JSONDecoder().decode(SpacePaint.self, from: $0) }
        MailSpaceLook.cached.withLock { $0 = space }
        return space
    }
}

/// Mail's place among the spaces and its look, kept apart from the saved
/// list it is never in.
enum MailSpaceLook {
    static let iconKey = "mail.space.icon"
    static let paintKey = "mail.space.paint"
    static let placeKey = "mail.space.place"

    /// How many of your spaces stand before Mail. Last until moved: ⌃1 to
    /// ⌃9 stay on the spaces they always were, and Mail takes the next.
    static var place: Int {
        get {
            _ = revision.count
            return Store.settings.object(forKey: placeKey) == nil ? Int.max : Store.settings.integer(forKey: placeKey)
        }
        set { Store.settings.set(max(0, newValue), forKey: placeKey) }
    }

    /// Space.mail as last read, read again after its emoji or look change.
    static let cached = OSAllocatedUnfairLock<Space?>(initialState: nil)

    /// Read with Mail's look and place, bumped by `changed`.
    @Observable fileprivate final class Revision: @unchecked Sendable {
        var count = 0
    }
    fileprivate static let revision = Revision()

    static func keep(_ paint: SpacePaint?) {
        if let paint, let data = try? JSONEncoder().encode(paint) { Store.settings.set(data, forKey: paintKey) }
        else { Store.settings.removeObject(forKey: paintKey) }
        changed()
    }

    static func setIcon(_ icon: String) {
        Store.settings.set(icon, forKey: iconKey)
        changed()
    }

    /// Every window draws Mail's place again: its emoji, its look, its place.
    static func changed() {
        cached.withLock { $0 = nil }
        DispatchQueue.main.async { revision.count += 1 }
    }

    /// What each window wore as Mail came on screen there: leaving with
    /// anything else means its look was changed in Mail, and is Mail's own
    /// now. Per window, as another window's switch changes the shared look.
    @MainActor static var worn: [ObjectIdentifier: SpacePaint] = [:]
}

extension Browser {
    var inMail: Bool { spaceID == Space.mailID }

    /// Finish a cancelled Mail navigation outside its space. Tab.go has
    /// already set the address, so a newly opened Mail tab is no longer blank.
    /// Background opens are removed too, without switching spaces. A pin is
    /// the deliberate door to Mail and stays where the user put it.
    func routeMailNavigation(_ url: URL, from source: Tab) {
        let foreground = source.id == activeID
        // Mail's pin loading its own page as its space comes back, in front
        // because it was the tab left in front there: no ask to go in (a
        // click on it is, Browser.select), or leaving mail would come
        // straight back. The tab beside it is put in front instead.
        if source.pin != nil, MailPage.isMail(source.pending ?? source.address) {
            if foreground, let other = tabs.first(where: { $0.id != source.id && $0.pin == nil }) ?? tabs.first(where: { $0.id != source.id }) {
                select(other)
            }
            return
        }
        if source.pin == nil,
           source.isBlank || MailPage.isMail(source.pending ?? source.address) {
            source.kept = false
            close(source)
            // Closing the only tab normally retains it under the field for
            // Escape. A cancelled Mail page must not be brought back that way.
            if underTab === source { settleUnder() }
        }
        if foreground { enterMail(url) }
    }

    /// Into the mail space, the column with it, and the mail page in front.
    func enterMail(_ url: URL? = nil) {
        guard windowPurpose == .normal, prefs.usesMail else { return }
        if !inMail { switchSpace(to: Space.mailID) }
        openInMail(url)
    }

    /// Back to the space you came from: ⇧⌘I goes back, where two fingers
    /// go on to the next one along (Browser.turnOrder).
    func leaveMail() {
        guard inMail else { return }
        let back = MailSpaceState.shared.back
        switchSpace(to: spaces.contains { $0.id == back } ? back : homeSpaceID)
    }

    /// However mail's space is gone into, ⇧⌘I, the door, the tray or two
    /// fingers (switchSpace): where you came from, kept to go back to, and
    /// the column out, since mail is a column and a page.
    func mailComing() {
        if spaceID != Space.mailID { MailSpaceState.shared.back = spaceID }
        MailSpaceState.shared.turnedSidebar = !prefs.sidebar
        if !prefs.sidebar { prefs.sidebar = true }
    }

    /// In: the lists read, the stores synced, the mail page up.
    func mailCame() {
        // Those reading the row told again, now that it is Mail's: in the
        // switch's transaction SwiftUI could draw Mail's column there and
        // then from the row's willSet, the space's tabs still in it, and
        // keep that, its tabs listed under Mail's and the space's mail pin
        // hiding the way back, until the next change (feedback #158's film,
        // job 0c226c8e; Preferences.told).
        withMutation(keyPath: \.tabs) {}
        MailList.shared.reload()
        MailLabels.shared.came()
        MailDesk.shared.browser = self
        MailDesk.shared.arrived()
        if mailPageTab == nil { openInMail(nil) }
        mailFollows()
    }

    /// Out, however: the page no longer in front, the column put back if
    /// mail took it out.
    func mailLeft() {
        // The same going out: the space's foot read Mail's row and showed
        // the envelope beside the space's own mail pin (mailCame).
        withMutation(keyPath: \.tabs) {}
        mailFollows()
        MailCenter.shared.pageInFront = false
        // No label's count is asked while the column is away.
        MailLabels.shared.gone()
        // Pin Mail asked for from mail's own space: the door goes here.
        if Store.settings.bool(forKey: "mail.pin.asked") {
            Store.settings.set(false, forKey: "mail.pin.asked")
            MailCenter.shared.putPin(in: self)
        }
        MailList.shared.choosing = false
        if MailSpaceState.shared.turnedSidebar {
            MailSpaceState.shared.turnedSidebar = false
            prefs.sidebar = false
        }
    }

    /// Leave Mail and remove its doors without disconnecting any account.
    func hideMail() {
        if inMail { leaveMail() }
        for tab in tabs where MailPage.isMail(tab.pending ?? tab.address) {
            tab.pin = nil
            tab.kept = false
            close(tab)
        }
        for (space, row) in parked {
            parked[space]?.tabs = row.tabs.filter { !MailPage.isMail($0.pending ?? $0.address) }
        }
        writeSession(now: true)
        // The door among the shared pins, put aside under a space of its own.
        writePins(now: true)
    }

    func toggleMail() { if inMail { leaveMail() } else { enterMail() } }

    /// The pages of mail's own space, its page and an agent's work aside:
    /// a link's peek kept (⌘O), a ⌘-click. The column lists them under
    /// its lists (MailTabRows), as any space's rows.
    var mailTabs: [Tab] {
        guard inMail else { return [] }
        let agents = Agents.shared
        return tabs.filter { $0.pin == nil && !MailPage.isMail($0.pending ?? $0.address) && !MailChat.isAgents($0) && !agents.sealed($0) }
    }

    /// Mail's page in front again, from one of the space's tabs: what a list,
    /// a label, Kept or the search is chosen with in the column.
    func showMailPage() {
        guard inMail, let mail = mailPageTab, activeID != mail.id else { return }
        select(mail)
    }

    /// Whether a page of mail's space is in front rather than mail's own,
    /// for which of the column's rows is lit (MailList.paging), and for how
    /// often mail asks Gmail (MailCenter.pageInFront).
    func mailFollows() {
        let paging = inMail && !MailPage.isMail(active?.pending ?? active?.address)
        if MailList.shared.paging != paging { MailList.shared.paging = paging }
        if inMail { MailCenter.shared.pageInFront = !paging }
    }

    /// The mail page, the one tab of the space that holds it.
    var mailPageTab: Tab? {
        guard inMail else { return nil }
        return active.flatMap { MailPage.isMail($0.address) ? $0 : nil } ?? tabs.first { MailPage.isMail($0.address) }
    }

    /// A yab://mail address in the mail space: the thread it names, on the
    /// mail page, or the page itself.
    func openInMail(_ url: URL?) {
        guard windowPurpose == .normal else { return }
        if let here = mailPageTab {
            if active?.id != here.id { select(here) }
            editing = false
            if let url, let (account, id) = MailSpaceState.thread(in: url) {
                MailDesk.shared.openThread(account: account, thread: id, split: MailSpaceState.split(in: url))
            } else if let url, let list = MailSpaceState.list(in: url) {
                MailDesk.shared.go(list)
            }
            return
        }
        let page = MailPage.url
        if let blank = active, blank.isBlank {
            blank.go(to: page)
            editing = false
        } else {
            open(page, foreground: true)
        }
        // First in the row, the space's tabs after it: ⌃⇥ starts from mail.
        if let at = tabs.firstIndex(where: { MailPage.isMail($0.pending ?? $0.address) }), at > 0 {
            var row = tabs
            row.insert(row.remove(at: at), at: 0)
            lay(row)
        }
        if let url, let (account, id) = MailSpaceState.thread(in: url) {
            MailDesk.shared.openThread(account: account, thread: id, split: MailSpaceState.split(in: url))
        } else if let url, let list = MailSpaceState.list(in: url) {
            MailDesk.shared.go(list)
        }
    }

    /// A row of Kept, in the middle: its thread, its draft, or its send set
    /// for later, back to being written.
    func openKept(_ item: MailList.Kept) {
        if let here = mailPageTab, active?.id != here.id { select(here) }
        let desk = MailDesk.shared
        switch item.kind {
        case .thread: desk.openThread(account: item.account, thread: item.thread)
        case .draft:
            if item.thread.isEmpty { desk.openDraft(account: item.account, id: item.draft) }
            else { desk.openThread(account: item.account, thread: item.thread, reply: true, forward: item.draft.hasPrefix("forward:")) }
        case .scheduled: desk.reopen(item.seq, account: item.account)
        }
    }
}

/// Where the mail space was entered from, and whether it put the tabs in
/// the column to do it.
@MainActor
final class MailSpaceState {
    static let shared = MailSpaceState()
    var back = Space.firstID
    var turnedSidebar = false

    /// yab://mail/<split>/<account>/<id>, or a new tab's row's
    /// yab://mail#thread=<account>|<id>; an agent's link that left the
    /// account out, yab://mail#thread=<id>, in the account that has it.
    static func thread(in url: URL) -> (String, String)? {
        if let fragment = url.fragment(percentEncoded: false), fragment.hasPrefix("thread=") {
            let parts = fragment.dropFirst(7).split(separator: "|", maxSplits: 1).map(String.init)
            if parts.count == 1, let id = parts.first,
               let engine = MailCenter.shared.engines.values.first(where: { $0.store.thread(id) != nil }) {
                return (engine.account, id)
            }
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        }
        let parts = url.pathComponents.filter { $0 != "/" }
        return parts.count >= 3 ? (parts[1], parts[2]) : nil
    }

    static func split(in url: URL) -> String? {
        let parts = url.pathComponents.filter { $0 != "/" }
        return parts.count >= 3 ? parts[0] : nil
    }

    /// yab://mail#list=<id>: a list to have in front, the new tab's
    /// "archived today" line's (MailSplits.skipped).
    static func list(in url: URL) -> String? {
        guard let fragment = url.fragment(percentEncoded: false), fragment.hasPrefix("list=") else { return nil }
        let id = String(fragment.dropFirst(5))
        return id.isEmpty ? nil : id
    }
}

/// One rule of a split: whom (with, from or to a person or a whole domain),
/// which words, what kind of mail it is as this Mac reads it (MailSense),
/// the account's own domain, or a search in Gmail's words (MailQuery). A
/// split's rules are one line, "from:stripe.com from:apple.com words:receipt
/// kind:invoice", and a line of plain words (as lists were first kept) is
/// one rule of words.
struct MailRule: Equatable, Hashable {
    let kind: String
    let value: String

    static let kinds = ["with", "from", "to", "words", "kind", "team", "search"]

    /// What a search keeps of its words in one token: spaces and the rest
    /// written out, so a line splits at its spaces alone.
    private static let plain = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~:@/"))

    static func parse(_ q: String) -> [MailRule] {
        var out: [MailRule] = [], loose: [String] = []
        for token in q.split(separator: " ").map(String.init) {
            if let colon = token.firstIndex(of: ":"), kinds.contains(String(token[..<colon])) {
                let kind = String(token[..<colon]), value = String(token[token.index(after: colon)...])
                guard !value.isEmpty else { continue }
                switch kind {
                case "words": loose.append(value.replacingOccurrences(of: "_", with: " "))
                case "search": out.append(MailRule(kind: kind, value: value.removingPercentEncoding ?? value))
                default: out.append(MailRule(kind: kind, value: value))
                }
            } else {
                loose.append(token)
            }
        }
        if !loose.isEmpty { out.append(MailRule(kind: "words", value: loose.joined(separator: " "))) }
        return out
    }

    static func line(_ rules: [MailRule]) -> String {
        rules.map { rule in
            switch rule.kind {
            case "words": return "words:" + rule.value.replacingOccurrences(of: " ", with: "_")
            case "search": return "search:" + (rule.value.addingPercentEncoding(withAllowedCharacters: plain) ?? rule.value)
            default: return rule.kind + ":" + rule.value
            }
        }.joined(separator: " ")
    }

    /// As its chip says it: "from stripe.com", "words receipt", "kind Bills",
    /// "from your own domain".
    var said: (kind: String, value: String) {
        switch kind {
        case "kind": return ("kind", MailSplits.kindName(value))
        case "team": return ("from", "your own domain")
        default: return (kind, value)
        }
    }
}

/// The column's state: which account, which list, how many each holds,
/// the splits and their order (MailSplits), and Kept. Read from the stores
/// on the main thread again whenever one changes.
@MainActor
@Observable final class MailList {
    static let shared = MailList()

    /// What stays at hand until it is done: a thread kept with P, a draft
    /// you wrote words in, a send set for later. Never a reply Claude wrote
    /// that you haven't touched, never an agent's work (that shows on its
    /// row).
    struct Kept: Identifiable, Equatable {
        enum Kind { case thread, draft, scheduled }
        let kind: Kind
        let account: String
        var thread = ""
        var draft = ""
        var seq: Int64 = 0
        let title: String
        /// Said at its end: "Draft", "Tue 9:00".
        let said: String
        var id: String { "\(kind)|\(account)|\(thread)|\(draft)|\(seq)" }
    }

    struct Page: Codable, Equatable, Hashable {
        let url: String
        let title: String
    }

    /// What Claude said matters now in a list, and when, and over how many
    /// threads: said again when the list changes or half an hour has gone.
    private(set) var summaries: [String: (text: String, at: Date, count: Int)] = [:]

    /// Icons a list may wear, for Claude to pick from.
    static let icons = ["doc.text", "creditcard", "airplane", "bag", "calendar", "person", "person.2", "suitcase", "building.2",
                        "house", "book", "star", "bolt", "sparkles", "globe", "paperplane", "music.note", "video", "bookmark", "magnifyingglass"]

    /// The inbox's own lists, among which the splits stand (MailSplits.base).
    static let base: [(id: String, name: String, symbol: String)] = [
        ("needs", "Needs you", "envelope"), ("waiting", "Waiting", "clock.circle"), ("promised", "Promised", "checkmark.circle"),
        ("other", "Other", "tray.and.arrow.down"), ("later", "Later", "clock"),
        ("older", "Archive", "archivebox"),
    ]

    /// A list's name as the page's head says it.
    static func name(_ split: String) -> String {
        if split == "kept" { return "Kept" }
        if split == MailSplits.skipped { return "Archived Today" }
        if split == "draft" { return shared.draft.map { $0.title.isEmpty ? "New Split" : $0.title } ?? "New Split" }
        if let made = shared.splits.first(where: { $0.id == split }) { return made.title }
        if split.hasPrefix("q:") { return String(split.dropFirst(2)) }
        if let view = MailGo.views[split] { return view }
        if let label = MailViews.label(split) { return label }
        return base.first { $0.id == split }?.name ?? "Mail"
    }

    var split = "needs" {
        didSet {
            guard split != oldValue else { return }
            // The counts are the same whichever list is in front: only the
            // list changes, read once (MailDesk.listChosen), not twice.
            if gone(split) { split = "needs" }
            // The column is laid again only for the one in front: an empty
            // split or Archive stands in it while it is (a split just made
            // from a label's senders was open and in no row).
            layColumn()
            MailDesk.shared.listChosen()
        }
    }
    /// "all", or one account's address.
    var account = Store.settings.string(forKey: "mail.column.account") ?? "all" {
        didSet {
            guard account != oldValue else { return }
            Store.settings.set(account, forKey: "mail.column.account")
            reload()
            MailLabels.shared.reload()
            MailDesk.shared.listChosen()
        }
    }
    private(set) var counts: [String: Int] = [:]
    /// One of mail's space's tabs in front rather than the mail page
    /// (Browser.mailFollows): no list is chosen, the plate is on its row.
    var paging = false
    /// Needs you, per account, for the chooser's menu.
    private(set) var needs: [String: Int] = [:]
    private(set) var kept: [Kept] = []
    /// Every split, the built-in ones among them, on or off (MailSplits).
    private(set) var splits: [Split] = MailSplits.load(Store.settings) {
        didSet { sort = MailSplitSort(splits, order: order) }
    }
    /// The column's order: the inbox's lists and every split, as dragged.
    private(set) var order: [String] = [] {
        didSet { sort = MailSplitSort(splits, order: order) }
    }
    /// The column's rows, in their order, empty splits hidden as asked.
    private(set) var column: [Entry] = []
    /// Settings › Mail's Hide empty splits: on until turned off.
    var hideEmpty = Store.settings.object(forKey: MailSplits.hideKey) as? Bool ?? true {
        didSet {
            Store.settings.set(hideEmpty, forKey: MailSplits.hideKey)
            layColumn()
        }
    }
    /// The splits on, as they sort threads (MailSplitSort), for the lists,
    /// Skip the inbox and the notifications alike.
    @ObservationIgnored private(set) var sort = MailSplitSort.none
    /// How the inbox's own lists sort (Settings › Mail, MailSplit.Policy):
    /// what needs you, and how far back Needs you and Other look.
    var policy = MailSplit.Policy.current {
        didSet {
            guard policy != oldValue else { return }
            MailSplit.Policy.current = policy
            policy.keep(Store.settings)
            sort = MailSplitSort(splits, order: order, policy: policy)
            // The lists, the column's counts, the pin and the Dock again.
            MailCenter.shared.touch()
        }
    }
    /// The column's row being dragged (MailColumnDrop).
    @ObservationIgnored var dragging: String?
    /// What Skip the inbox archived today on the accounts shown, by split:
    /// a split's head says so.
    private(set) var skippedToday: [String: Int] = [:]
    /// The thread the page shows, "account|id", told to whoever keeps it
    /// (`showing`: MailSearch's Recently opened). Not published, nor
    /// `view`: nothing the column draws reads them, and each letter opened
    /// drew the column and the page again for them, inside the key.
    @ObservationIgnored var shown: String? {
        didSet { if shown != oldValue { showing.send(shown) } }
    }
    let showing = PassthroughSubject<String?, Never>()
    /// A search is over the list: none of the column's lists is on screen.
    var searched = false
    /// The account panel is up under the chooser.
    var choosing = false
    /// What the page shows, "list", "thread", "ready" (a thread with a
    /// reply ready), "compose" or "draft", for the bench.
    @ObservationIgnored var view = "list"
    /// Threads handed to an agent (Do It), "account|thread" to its
    /// session, while it works.
    private(set) var working: [String: String] = [:]
    /// Threads whose ready reply an agent wrote, having done what they asked.
    private(set) var did = Set(Store.settings.stringArray(forKey: "mail.did") ?? [])
    /// A list that just took something: it answers with a pulse.
    private(set) var pulsed: (id: String, n: Int) = ("", 0)
    /// Rows whose ready reply an agent just wrote or changed, "account|thread"
    /// to how many times: each time, the row lights once.
    private(set) var flashed: [String: Int] = [:]
    /// What sorting did, said once over Needs you (MailInboxHead): from the
    /// first time it is drawn until a day has gone or you act on mail.
    private(set) var sorted: Sorted?
    struct Sorted: Equatable {
        let needs: Int
        let older: Int
        let ads: Int
    }
    /// When the card was first drawn, or "done".
    static let sortedKey = "mail.sorted-card"
    /// The day's line over Needs you (docs/mail.md, Only what matters): what is
    /// dated in it and what you promised, soonest first, three at most;
    /// none on a quiet day.
    private(set) var today: [Dated] = []
    struct Dated: Equatable {
        let account: String
        let thread: String
        /// "Ledgerly · $1,240 for August hosting", "you promised Mark · Q3 numbers".
        let words: String
        let due: Date
    }

    @ObservationIgnored private var bag: AnyCancellable?

    private init() {
        order = MailSplits.order(Store.settings.stringArray(forKey: MailSplits.orderKey), splits: splits)
        // Observers don't run in an initializer.
        sort = MailSplitSort(splits, order: order)
        bag = MailCenter.shared.observed(\.changed).dropFirst()
            .debounce(for: .milliseconds(120), scheduler: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.reload() } }
    }

    func reload() {
        let center = MailCenter.shared
        if account != "all", center.engines[account] == nil { account = "all" }
        // A split taken away, or turned off, while in front: Needs you.
        if gone(split) { split = "needs" }
        // The counts are the inbox's and the splits', in one pass: a list
        // beyond it isn't read for them, and no rows are built for them.
        let inbox = split == "kept" || split == MailSplits.skipped || MailGo.isView(split) || split == "draft"
        var counts = MailDesk.read(split: inbox ? "needs" : split, query: "", account: account, limit: 0).counts
        var needs: [String: Int] = [:]
        for engine in center.engines.values { needs[engine.account] = MailDesk.needYou(in: engine.store) }
        self.needs = needs
        kept = makeKept()
        counts["kept"] = kept.count
        self.counts = counts
        layColumn()
        var skipped: [String: Int] = [:]
        if splits.contains(where: { $0.on && $0.mode == .skip }) {
            for engine in center.showing(account) {
                for one in engine.store.skipped(since: MailSkip.today()) { skipped[one.split, default: 0] += 1 }
            }
        }
        if skipped != skippedToday { skippedToday = skipped }
        let card = sortedCard(counts)
        if card != sorted { sorted = card }
        let dated = MailList.dated(MailCenter.shared.showing(account), now: MailClock.now)
        // Its Got It hides it until something new is dated in it.
        let seen = Set(Store.settings.stringArray(forKey: Self.todaySeenKey) ?? [])
        let shown = dated.contains { !seen.contains(Self.seenKey($0)) } ? dated : []
        if shown != today { today = shown }
        offerUp()
        // An agent that finished is off its row.
        let live = Set(Agents.shared.sessions.filter(\.state.live).map(\.id))
        let still = working.filter { live.contains($0.value) }
        if still.count != working.count { working = still }
    }

    /// The card's numbers while it stands: once mail is in, until a day has
    /// gone since it was first drawn or something was done (`doneSorting`).
    private func sortedCard(_ counts: [String: Int]) -> Sorted? {
        let kept = Store.settings.string(forKey: Self.sortedKey)
        guard kept != "done", MailCenter.shared.connected else { return nil }
        let needs = counts["needs"] ?? 0, older = counts[MailSplit.older.rawValue] ?? 0, ads = counts[MailSplits.ads] ?? 0
        guard needs + older + ads > 0 else { return nil }
        let now = Date().timeIntervalSince1970
        guard let first = kept.flatMap(Double.init) else {
            Store.settings.set(String(now), forKey: Self.sortedKey)
            return Sorted(needs: needs, older: older, ads: ads)
        }
        guard now - first < 86_400 else {
            Store.settings.set("done", forKey: Self.sortedKey)
            return nil
        }
        return Sorted(needs: needs, older: older, ads: ads)
    }

    /// The day's line: Needs you's threads naming a date within the week
    /// (a bill past due among them) and what you promised by then, soonest
    /// first, three at most, a thread once.
    static func dated(_ engines: [MailCenter.Engine], now: Date) -> [Dated] {
        let horizon = now.addingTimeInterval(7 * 86_400)
        var out: [Dated] = []
        for engine in engines {
            let store = engine.store
            for (thread, sensed) in MailSplit.threads(.needs, in: store, now: now, limit: 300) {
                guard let sensed, let due = sensed.due, due < horizon else { continue }
                let who = thread.people.first.map { $0.said.components(separatedBy: " ").first ?? $0.said } ?? ""
                // The model's few words when it read it; the rules' are the
                // mail's first line, and the subject says it better.
                let what = sensed.byModel && !sensed.gist.isEmpty ? sensed.gist : MailCenter.bare(thread.subject)
                out.append(Dated(account: engine.account, thread: thread.id, words: who.isEmpty ? what : who + " · " + what, due: due))
            }
            for promise in MailPromise.open(in: store, now: now) {
                guard let due = promise.due, due < horizon, !out.contains(where: { $0.thread == promise.thread }),
                      let thread = store.thread(promise.thread) else { continue }
                let who = promise.person.components(separatedBy: " ").first.flatMap { $0.isEmpty ? nil : $0 } ?? promise.address
                out.append(Dated(account: engine.account, thread: thread.id, words: "you promised \(who) · " + MailCenter.bare(thread.subject),
                                 due: due))
            }
        }
        return Array(out.sorted { $0.due < $1.due }.prefix(3))
    }

    /// Offers from what you did (MailOffers), the first of each list over
    /// it: worked out off the main thread at most every five minutes, and
    /// again at once after one is taken or turned down.
    private(set) var offers: [MailOffer] = []
    @ObservationIgnored private var offered = Date.distantPast

    private func offerUp(force: Bool = false) {
        guard force || Date().timeIntervalSince(offered) > 300 else { return }
        offered = Date()
        let jobs = MailCenter.shared.showing(account).map { ($0.account, $0.store) }
        let splits = self.splits, now = MailClock.now
        // Asked of macOS here: the app mail links open in, unless it is Yab.
        let app = jobs.isEmpty ? nil : MailOffers.mailApp(current: MailDefault.isDefault ? nil : MailDefault.current)
        Task.detached(priority: .utility) { [weak self] in
            let made = (app.map { [$0] } ?? []) + jobs.flatMap { MailOffers.offers(account: $0.0, store: $0.1, splits: splits, now: now) }
            await MainActor.run { [weak self] in
                guard let self, made != self.offers else { return }
                self.offers = made
            }
        }
    }

    /// The offer over a list, if it has one.
    func offer(over split: String) -> MailOffer? { offers.first { $0.home == split } }

    /// Worked out again now, not in five minutes (the bench).
    func refreshOffers() { offerUp(force: true) }

    /// One turned down, and why: gone, and kept so.
    func decline(_ offer: MailOffer, why: MailOffer.No) {
        MailOffers.decline(offer, why: why)
        offers.removeAll { $0.id == offer.id }
        offerUp(force: true)
    }

    /// One taken: gone, never offered again.
    func took(_ offer: MailOffer) {
        MailOffers.took(offer)
        offers.removeAll { $0.id == offer.id }
        offerUp(force: true)
    }

    /// A split of yours made from an offer, in the column at its end, the
    /// list in front left as it is: its id.
    @discardableResult
    func keepSplit(title: String, q: String, icon: String?, mode: Split.Mode) -> String {
        var made = Split(title: title, q: q, icon: icon, mode: mode)
        made.on = true
        if !splits.contains(where: { $0.id == made.id }) {
            splits.append(made)
            keepSplits()
        }
        pulse(made.id)
        reload()
        MailDesk.shared.load()
        return made.id
    }

    /// The line's words: "First: Ledgerly · $1,240 for August hosting.
    /// Then Anna · Asks for a review slot by Thursday, and you promised
    /// Mark · Q3 numbers."
    static func todayLine(_ dated: [Dated]) -> String {
        guard let first = dated.first else { return "" }
        // Each said as a clause: its own stop or question mark goes.
        let clause = { (words: String) in words.trimmingCharacters(in: CharacterSet(charactersIn: ".!?\u{2026} ")) }
        let rest = dated.dropFirst().map { clause($0.words) }
        let head = (rest.isEmpty ? "Today: " : "First: ") + clause(first.words) + "."
        guard !rest.isEmpty else { return head }
        return head + " Then " + rest.joined(separator: ", and ") + "."
    }

    /// The day's line's Got It: gone until something new is dated in it.
    func doneToday() {
        guard !today.isEmpty else { return }
        Store.settings.set(today.map(Self.seenKey), forKey: Self.todaySeenKey)
        today = []
    }
    static let todaySeenKey = "mail.today-seen"
    private static func seenKey(_ one: Dated) -> String {
        "\(one.account)|\(one.thread)|\(Int(one.due.timeIntervalSince1970))"
    }

    /// Something was done with mail, a thread opened, or its Got It
    /// pressed: the card has said its piece.
    func doneSorting() {
        guard sorted != nil else { return }
        Store.settings.set("done", forKey: Self.sortedKey)
        sorted = nil
    }

    /// The column's rows again, from the order and the counts as they are.
    private func layColumn() {
        let made = MailSplits.column(order: order, splits: splits, counts: counts, hideEmpty: hideEmpty, front: split)
        if made != column { column = made }
    }

    /// The lists ⇥ and ⇧⇥ go through: the column's, in its order.
    var tabbed: [String] { column.map(\.id) + (kept.isEmpty ? [] : ["kept"]) }

    /// A split that is on, by its id; nil for an inbox's list or another.
    func split(_ id: String) -> Split? { splits.first { $0.id == id && $0.on } }

    /// A split taken away, or turned off: not a list to show.
    private func gone(_ id: String) -> Bool {
        !MailSplits.base.contains(id) && (id.hasPrefix("q:") || MailSplits.builtIns.contains { $0.id == id }) && split(id) == nil
    }

    /// Every split in the column's order, on or off: Settings › Mail's.
    var ordered: [Split] { order.compactMap { id in splits.first { $0.id == id } } }

    /// Yours: the splits kept from a search, made in words, or once your lists.
    var yours: [Split] { ordered.filter { !$0.builtIn } }

    private func makeKept() -> [Kept] {
        let center = MailCenter.shared
        var out: [Kept] = []
        let now = Date()
        for engine in center.showing(account).sorted(by: { $0.account < $1.account }) {
            let store = engine.store
            let ops = store.allOps()
            let sending = Set(ops.filter { $0.kind == .send }.map(\.thread))
            for key in Store.settings.stringArray(forKey: "mail.kept") ?? [] {
                let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
                guard parts.count == 2, parts[0] == engine.account, let thread = store.thread(parts[1]) else { continue }
                out.append(Kept(kind: .thread, account: engine.account, thread: thread.id, title: thread.subject.isEmpty ? "(no subject)" : thread.subject, said: ""))
            }
            for draft in store.drafts() where !sending.contains(draft.id)
                && !(draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.subject.isEmpty && draft.files.allSatisfy(\.original)) {
                // A reply's or a forward's own subject ("Re: …", "Fwd: …", or one you changed).
                let subject = draft.thread.isEmpty || !draft.subject.isEmpty ? draft.subject : store.thread(draft.thread)?.subject ?? ""
                out.append(Kept(kind: .draft, account: engine.account, thread: draft.thread, draft: draft.id,
                                title: subject.isEmpty ? "New mail" : draft.thread.isEmpty || !draft.forwarded.isEmpty || subject.lowercased().hasPrefix("re:") ? subject : "Re: " + subject,
                                said: "Draft"))
            }
            for op in ops where op.kind == .send && op.notBefore.timeIntervalSince(now) > 30 {
                guard let draft = store.draft(op.thread) else { continue }
                out.append(Kept(kind: .scheduled, account: engine.account, seq: op.seq,
                                title: draft.subject.isEmpty ? "New mail" : draft.subject, said: MailLater.said(op.notBefore, now: now)))
            }
        }
        return out
    }

    /// Kept, in a line on its bubble: "2 drafts · 1 sending · 1 kept".
    var keptSaid: String {
        let drafts = kept.filter { $0.kind == .draft }.count
        let sending = kept.filter { $0.kind == .scheduled }.count
        let threads = kept.filter { $0.kind == .thread }.count
        var bits: [String] = []
        if drafts > 0 { bits.append("\(drafts) \(drafts > 1 ? "drafts" : "draft")") }
        if sending > 0 { bits.append("\(sending) sending") }
        if threads > 0 { bits.append("\(threads) kept") }
        return bits.joined(separator: " · ")
    }

    /// In Kept by hand.
    func isKept(account: String, thread: String) -> Bool {
        (Store.settings.stringArray(forKey: "mail.kept") ?? []).contains(account + "|" + thread)
    }

    /// P on a thread: into Kept, or out of it. Says which.
    func toggleKept(account: String, thread: String) -> Bool {
        let key = account + "|" + thread
        var list = Store.settings.stringArray(forKey: "mail.kept") ?? []
        let now = !list.contains(key)
        if now { list.append(key) } else { list.removeAll { $0 == key } }
        Store.settings.set(list, forKey: "mail.kept")
        kept = makeKept()
        counts["kept"] = kept.count
        return now
    }

    /// Do It: the thread is the agent's until it is done; its row says so.
    func agentTook(account: String, thread: String, session: String) {
        working[account + "|" + thread] = session
    }

    /// Do It's reply, left for the thread: the reply ready under it says
    /// Claude wrote it.
    func agentDid(account: String, thread: String) {
        let key = account + "|" + thread
        working[key] = nil
        flash(key)
        guard !did.contains(key) else { return }
        did.insert(key)
        Store.settings.set(Array(did.suffix(200)), forKey: "mail.did")
    }

    /// An agent wrote or changed the reply under a thread: its row lights once.
    func flash(_ key: String) {
        flashed[key, default: 0] += 1
    }

    /// What the agent is doing on a thread, in a few words, while it works.
    func work(_ account: String, _ thread: String) -> String? {
        guard let id = working[account + "|" + thread],
              let session = Agents.shared.sessions.first(where: { $0.id == id }), session.state.live else { return nil }
        let now = session.progress ?? (session.now.isEmpty ? "working" : AgentDock.say(session.now, name: session.name))
        return AgentModels.agentName(session.cli) + " · " + now
    }

    /// A thread done, snoozed or archived leaves Kept.
    func settled(account: String, thread: String) {
        settled([(account, thread)])
    }

    /// Threads done, snoozed or archived together leave Kept in one go;
    /// none of them kept, nothing changes (an act's key reads no drafts).
    func settled(_ threads: [(account: String, thread: String)]) {
        let keys = Set(threads.map { $0.account + "|" + $0.thread })
        var list = Store.settings.stringArray(forKey: "mail.kept") ?? []
        guard list.contains(where: keys.contains) else { return }
        list.removeAll { keys.contains($0) }
        Store.settings.set(list, forKey: "mail.kept")
        kept = makeKept()
        counts["kept"] = kept.count
    }

    /// A list, Later, Waiting or Kept, took something: it pulses once.
    func pulse(_ id: String) {
        pulsed = (id, pulsed.n + 1)
    }

    /// ⌘0 every account, ⌘1 to ⌘9 each, as the chooser numbers them.
    func choose(number: Int) {
        let accounts = MailCenter.shared.accounts
        if number == 0 { account = "all" } else if accounts.indices.contains(number - 1) { account = accounts[number - 1] }
        if choosing { choosing = false }
    }

    /// A search kept as a split, in the column at its end, chosen: one of
    /// yours, its mail only here, as a split's is unless it says otherwise.
    func saveList(title: String, q: String, icon: String? = nil, why: String? = nil) {
        let q = q.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        let id = "q:" + q
        if !splits.contains(where: { $0.id == id }) {
            splits.append(Split(id: id, title: title.isEmpty ? q : title, q: q, icon: icon, why: why))
            keepSplits()
        }
        split = id
        pulse(id)
        reload()
    }

    /// A split added from Settings (Sorting's split of a kind's own),
    /// none in front changed: in the column at its end.
    func addSplit(_ one: Split) {
        guard !splits.contains(where: { $0.id == one.id }) else { return }
        splits.append(one)
        keepSplits()
        reload()
        MailDesk.shared.load()
    }

    /// A split changed where it stands: a rule taken off or added, its
    /// grouping, its pages, where its mail goes. On screen, it stays on
    /// screen; its id is the same whatever its rules are now.
    func change(_ id: String, _ edit: (inout Split) -> Void) {
        guard let at = splits.firstIndex(where: { $0.id == id }) else { return }
        var one = splits[at]
        edit(&one)
        // One of yours keeps a rule at least; a built-in VIP may have nobody.
        guard one.builtIn || !one.q.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        guard one != splits[at] else { return }
        splits[at] = one
        keepSplits()
        reload()
        MailDesk.shared.load()
    }

    /// Where a split's mail goes, from Settings › Mail: "off" turns a
    /// built-in one off; Skip the inbox from now on, its mail before that
    /// left where it is.
    func setMode(_ mode: String, for id: String) {
        change(id) { one in
            guard let mode = Split.Mode(rawValue: mode) else {
                if one.builtIn { one.on = false }
                return
            }
            if mode == .skip, one.mode != .skip || !one.on { one.skipSince = MailClock.now }
            one.on = true
            one.mode = mode
        }
    }

    /// A built-in split on or off (Settings › Mail, ⌘K's Add to VIP).
    func turn(_ id: String, on: Bool) {
        change(id) { $0.on = on }
    }

    /// The column's order with one moved to where another stands (a drag),
    /// kept at once.
    func move(_ id: String, to target: String) {
        let moved = MailSplits.moved(order, id, to: target)
        guard moved != order else { return }
        order = moved
        Store.settings.set(order, forKey: MailSplits.orderKey)
        layColumn()
    }

    /// Senders into VIP, or, all of them in it already, out of it (⌘K's
    /// Add to VIP): VIP turned on with them. What VIP was, for ⌘Z.
    @discardableResult
    func vip(_ senders: [String]) -> (before: Split?, added: Bool) {
        let before = splits.first { $0.id == "vip" }
        let wanted = Set(senders.map { $0.lowercased() }.filter { !$0.isEmpty })
        guard var made = before, !wanted.isEmpty else { return (before, false) }
        let have = Set(made.rules.filter { $0.kind == "from" || $0.kind == "with" }.map { $0.value.lowercased() })
        let adding = !wanted.isSubset(of: have) || !made.on
        var rules = made.rules
        if adding {
            rules += wanted.subtracting(have).sorted().map { MailRule(kind: "from", value: $0) }
            made.on = true
        } else {
            rules.removeAll { ($0.kind == "from" || $0.kind == "with") && wanted.contains($0.value.lowercased()) }
        }
        made.q = MailRule.line(rules)
        if let at = splits.firstIndex(where: { $0.id == "vip" }) {
            splits[at] = made
            keepSplits()
            reload()
        }
        return (before, adding)
    }

    /// Rules into a split, turned on with them (⌘K's Add to Split): what
    /// it was, for ⌘Z; nil when it had them already.
    @discardableResult
    func add(_ rules: [MailRule], to id: String) -> Split? {
        guard let at = splits.firstIndex(where: { $0.id == id }) else { return nil }
        let before = splits[at]
        let new = rules.filter { !before.rules.contains($0) }
        guard !new.isEmpty else { return nil }
        var made = before
        made.q = MailRule.line(made.rules + new)
        made.on = true
        splits[at] = made
        keepSplits()
        reload()
        return before
    }

    /// A split put back as it was (⌘Z of Add to VIP and Add to Split).
    func restore(_ one: Split) {
        guard let at = splits.firstIndex(where: { $0.id == one.id }) else { return }
        splits[at] = one
        keepSplits()
        reload()
    }

    // MARK: - a split being made

    /// A split being made, on screen as a list is, in the middle: its name
    /// in the head, its rules as chips, the threads they gather under them.
    /// Kept only on Keep Split; Discard, or esc, and it was never there.
    private(set) var draft: Split?
    /// Claude is making the draft of its words.
    private(set) var making = false
    /// A new Describe request also focuses a draft that was already open.
    private(set) var draftTitleFocus = 0
    @ObservationIgnored private var beforeDraft = "needs"

    func focusDraftTitle() {
        guard split == "draft", draft != nil else { return }
        draftTitleFocus += 1
    }

    /// + New Split, in the column or ⌘K.
    func startDraft() {
        if draft == nil {
            beforeDraft = split == "draft" ? "needs" : split
            draft = Split(id: "draft", title: "", q: "")
        }
        split = "draft"
        MailDesk.shared.load()
    }

    func editDraft(_ edit: (inout Split) -> Void) {
        guard var made = draft else { return }
        edit(&made)
        draft = made
        MailDesk.shared.load()
    }

    /// Discard, or esc: back to the list you were on.
    func discardDraft() {
        guard draft != nil else { return }
        draft = nil
        making = false
        split = beforeDraft
        MailDesk.shared.load()
    }

    /// Keep Split, or ⌘↩: one of your splits now, where the draft stood.
    func keepDraft() {
        guard var made = draft, !made.rules.isEmpty else { return }
        if made.title.trimmingCharacters(in: .whitespaces).isEmpty { made.title = MailList.said(made.rules) }
        made.id = "q:" + made.q
        draft = nil
        making = false
        if !splits.contains(where: { $0.id == made.id }) {
            splits.append(made)
            keepSplits()
        }
        split = made.id
        pulse(made.id)
        reload()
    }

    /// Claude makes the draft of the words in its name: a name, what it
    /// keeps, an icon and its rules.
    func makeDraft() {
        guard let words = draft?.title.trimmingCharacters(in: .whitespaces), !words.isEmpty, !making else { return }
        making = true
        let senders = MailDesk.shared.topContacts(60).map { ($0.name, $0.address, $0.threads) }
        MailDrafts.list(words, senders: senders) { [weak self] made in
            guard let self, self.making else { return }
            self.making = false
            guard let made else {
                // No Claude, or nothing from it: the words are the split.
                self.editDraft { $0.q = MailRule.line([MailRule(kind: "words", value: words)]) }
                return
            }
            self.editDraft {
                $0.title = made.title
                $0.icon = made.icon
                $0.why = made.why
                $0.q = made.q
                if $0.group == nil { $0.group = "sender" }
            }
        }
    }

    /// A name for rules no one named: "stripe.com and apple.com".
    static func said(_ rules: [MailRule]) -> String {
        rules.prefix(2).map(\.said.value).joined(separator: " and ")
    }

    /// Claude's line on what matters in a split now: asked again when what
    /// it holds changed in number or half an hour has gone; one Claude said
    /// nothing of waits as long (`force`: asked now, the bench's).
    func summarize(_ id: String, force: Bool = false) {
        guard let made = splits.first(where: { $0.id == id }), !asking.contains(id) else { return }
        let count = counts[id] ?? 0
        guard count > 0 else { return }
        if !force, let was = summaries[id], was.count == count, Date().timeIntervalSince(was.at) < 1800 { return }
        if !force, let was = tried[id], was.count == count, Date().timeIntervalSince(was.at) < 1800 { return }
        tried[id] = (count, Date())
        let threads = MailDesk.splitThreads(id, account: account)
        guard !threads.isEmpty else { return }
        asking.insert(id)
        MailDrafts.summary(of: made.title, threads: threads) { [weak self] line in
            self?.asking.remove(id)
            guard let line else { return }
            self?.summaries[id] = (line, Date(), count)
        }
    }
    @ObservationIgnored private var asking: Set<String> = []
    @ObservationIgnored private var tried: [String: (count: Int, at: Date)] = [:]

    /// One of your splits taken away; a built-in one is turned off instead.
    func dropList(_ id: String) {
        guard let one = splits.first(where: { $0.id == id }) else { return }
        if one.builtIn {
            turn(id, on: false)
        } else {
            splits.removeAll { $0.id == id }
            keepSplits()
        }
        if split == id { split = "needs" } else { reload() }
    }

    private func keepSplits() {
        MailSplits.save(splits, Store.settings)
        let made = MailSplits.order(order, splits: splits)
        if made != order {
            order = made
            Store.settings.set(order, forKey: MailSplits.orderKey)
        }
    }
}

/// The column in the mail space: the account and the search at its head,
/// the inbox's lists and the splits in the order they were dragged to, the
/// space's tabs and the labels, and at its foot Kept, one bubble. The lists
/// scroll as one, on up under the head and the lights to the window's top
/// and down under the foot, dimmed and blurred there as the tabs' rows are
/// (ColumnEnds). Its keys are the page's foot pill's (MailFootPill), never
/// the column's.
struct MailColumn: View {
    let browser: Browser
    /// How far below the window's top it stands: its lists go on up under
    /// the lights to there.
    var rise: CGFloat = 0
    /// A newer Yab's note over the foot: the lists go on under it too.
    var note: CGFloat = 0
    var list = MailList.shared
    var center = MailCenter.shared
    @Environment(\.tone) private var tone
    @MailStill private var still
    /// The lists, and the column under the foot too: while the lists fit,
    /// the room under them is the window's to be dragged by.
    @State private var listsHeight: CGFloat = 0
    @State private var height: CGFloat = 0
    /// How far the lists have gone under each end. Read by the fade and the
    /// blur alone, so a scroll draws nothing else again.
    @State private var ends = ColumnEnds()
    /// The account chooser's, this column's own (FloatAnchor).
    @State private var anchor = FloatAnchorBox()

    /// The account and the search over the lists, and the air under them.
    static var head: CGFloat { MailAccountChooser.height + SideBar.gap + SideBar.row + 8 }
    /// Where the first list stands at rest, under the head.
    static let start: CGFloat = head + SideBar.gap
    /// Kept and the capsule over the column's bottom (SideFoot): the column
    /// runs on under them, out of the room its callers leave for them.
    static let foot: CGFloat = SideBar.footHeight

    var body: some View {
        ZStack(alignment: .top) {
            scroll
            VStack(alignment: .leading, spacing: SideBar.gap) {
                MailAccountChooser(list: list, accounts: center.accounts, open: Binding(get: { list.choosing }, set: { show($0) }))
                    // Out of the chooser, over the lists and past the column, as
                    // ⌘K's list comes out of the field's foot: wide enough for
                    // every address whole (MailAccountFloat).
                    .background(FloatAnchor(box: anchor))
                MailColumnSearch(desk: MailDesk.shared)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.bottom, -(Self.foot + note))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { columnWidth = $0 }
        .onChange(of: list.account) { _, _ in show(false) }
        .onDisappear {
            // Another column's list stays up: a space's picture of this one
            // goes when the slide lands.
            let float = MailAccountFloat.shared
            guard float.anchor?.window == nil || float.anchor === anchor.view else { return }
            list.choosing = false
            float.hide()
        }
        .onChange(of: list.choosing) { _, on in
            let float = MailAccountFloat.shared
            if on {
                // Under the chooser clicked (show); with none in a window, as
                // the bench's choose has it, this one. Every column hears the
                // change, and only that one puts the panel up.
                if float.anchor?.window == nil { float.anchor = anchor.view }
                guard float.anchor === anchor.view else { return }
                float.show(MailAccountPanel(list: list, accounts: center.accounts) { show(false) }, width: max(columnWidth - 20, 320))
            } else {
                float.hide()
            }
        }
    }

    /// The lists from the window's top to the column's bottom, under the
    /// lights, the head and the foot, reaching into the margins as the tabs'
    /// rows do, so a lit row's swell isn't cut at their edge.
    private var scroll: some View {
        // Where the search's foot is, and the foot's top, from the ends.
        let under = rise + Self.head - 8
        return ThreadScrollView(.vertical) {
            VStack(spacing: 0) {
                lists
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listsHeight = $0 }
                // The room under the lists, the foot's at least, so the last
                // comes out from under it: the window's to be dragged by, as
                // the column's empty room is anywhere.
                DragStrip()
                    .frame(height: max(Self.foot + note, height - rise - Self.start - listsHeight))
            }
            .padding(.top, rise + Self.start)
            .padding(.horizontal, SideBar.margin)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.never)
        .modifier(OwnScrollEdges())
        .ignoresSafeArea(.container, edges: .vertical)
        .modifier(ColumnScrolled(ends: ends))
        .mask { ColumnFade(ends: ends, top: under, foot: true, footRoom: Self.foot + note) }
        .overlay { ColumnBlur(ends: ends, top: under, foot: true, grain: tone == nil ? 0 : browser.prefs.grain, footRoom: Self.foot + note) }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .padding(.top, -rise)
        .padding(.horizontal, -SideBar.margin)
    }

    private var lists: some View {
        VStack(alignment: .leading, spacing: SideBar.gap) {
            // The inbox's lists and the splits, in the order they were
            // dragged to, each with how many threads it holds: one number
            // that means one thing down the column, what is left to go
            // through there (a thread done leaves its list); what is unread
            // is the row's dot. Labels say Gmail's unread counts, a label
            // being where mail stays once it is done.
            ForEach(list.column) { entry in
                MailColumnRow(symbol: entry.symbol, title: entry.title, count: entry.count,
                              chosen: list.split == entry.id && !list.searched && !list.paging, pulse: list.pulsed.id == entry.id ? list.pulsed.n : 0,
                              note: entry.note) {
                    // A list chosen: the search over it goes, and mail's
                    // page comes back over a tab of the space; the list
                    // already in front, out of the letter open in it.
                    browser.showMailPage()
                    if list.split == entry.id { MailDesk.shared.back() }
                    if list.searched { MailSearch.shared.clear() }
                    list.split = entry.id
                }
                .onDrag {
                    list.dragging = entry.id
                    return NSItemProvider(object: entry.id as NSString)
                }
                .onDrop(of: [.text], delegate: MailColumnDrop(id: entry.id, list: list))
                .contextMenu {
                    if let split = list.split(entry.id) {
                        Button(split.builtIn ? "Turn Off \(split.title)" : "Remove Split") { list.dropList(split.id) }
                    }
                }
            }
            // Kept: drafts, sends set for later and threads kept with P,
            // a list under the others while it holds anything.
            if !list.kept.isEmpty {
                MailColumnRow(symbol: "bookmark", title: "Kept", count: list.kept.count,
                              chosen: list.split == "kept" && !list.searched && !list.paging, pulse: list.pulsed.id == "kept" ? list.pulsed.n : 0) {
                    browser.showMailPage()
                    if list.split == "kept" { MailDesk.shared.back() }
                    if list.searched { MailSearch.shared.clear() }
                    list.split = "kept"
                }
                .keyTip(list.keptSaid)
                .transition(.opacity)
            }
            if let made = list.draft {
                MailColumnRow(symbol: made.icon ?? "sparkles", title: made.title.isEmpty ? "Untitled" : made.title, count: 0,
                              chosen: list.split == "draft" && !list.paging, pulse: 0, note: "draft") {
                    browser.showMailPage()
                    list.startDraft()
                }
            }
            MailColumnRow(symbol: "plus", title: "New Split", count: 0, chosen: false, pulse: 0, quiet: true) {
                browser.showMailPage()
                MailDesk.shared.field(.library)
            }
            // An account connected before Yab asked about agents and mail:
            // the question once, its answer in Settings › Mail › Agents.
            if consentAsks {
                MailColumnRow(symbol: "agent.face", title: "\(PlanText.writer) and your mail", count: 0, chosen: false, pulse: 0,
                              quiet: true, note: "Off", close: {
                    MailConsent.answered()
                }) {
                    browser.openSettings(row: "mail-agents")
                }
                .keyTip("Whether \(PlanText.writer) may read mail you hand it")
                .transition(.opacity)
            }
            // The space's tabs under the lists, so nothing above them moves
            // as they come, and the labels under them.
            MailTabRows(browser: browser, prefs: browser.prefs)
            MailLabelRows(labels: MailLabels.shared, chosen: list.searched || list.paging ? nil : MailViews.label(list.split))
                .equatable()
        }
        .animation(still ? nil : Motion.glide, value: list.kept.isEmpty)
        .animation(still ? nil : Motion.glide, value: list.column.map(\.id))
        .animation(still ? nil : Motion.glide, value: consentAsks)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// Answered, by a switch or Not Now (MailConsent.asked).
    @AppStorage(MailConsent.askedKey, store: Store.settings) private var consentAnswered = false

    /// The row asking about agents and mail is up (MailConsent.rowShows).
    private var consentAsks: Bool { !consentAnswered && center.connected && PlanText.any }

    @State private var columnWidth: CGFloat = 0

    private func show(_ on: Bool) {
        guard on != list.choosing else { return }
        if on { MailAccountFloat.shared.anchor = anchor.view }
        list.choosing = on
        // Put away: the keys are mail's again (MailDesk.key), not the search's.
        if !on { NSApp.keyWindow?.makeFirstResponder(nil) }
    }
}

/// Search, under the account: every account's mail on this Mac. Only a
/// door: / from anywhere in mail, or a click, raises the search over it
/// (MailSearch), large, its magnifier where this one's is. What the list is
/// searched by stays written here, the person's name or the words, as
/// words, with a cross to take it off; esc in the list does the same.
private struct MailColumnSearch: View {
    @Environment(\.tabTitleSize) private var titleSize
    var desk: MailDesk
    private var search = MailSearch.shared
    @Environment(\.tone) private var tone
    @State private var hovering = false

    /// Words or a person in it.
    private var holding: Bool { !desk.query.isEmpty || desk.who != nil }
    /// A key's plate at the field's end, and how far it reaches into the
    /// field's padding: the square a row of the column has under its cross
    /// (RowPlate), as far in from the end as from top and bottom.
    private var plate: CGFloat { RowPlate.column.side }
    private var pull: CGFloat { SideBar.endInset - RowPlate.column.inset }

    private var said: String { MailSearch.said(desk) }

    var body: some View {
        HStack(spacing: SideBar.markGap) {
            Symbol("magnifyingglass", size: SideBar.mark - 3)
                .foregroundStyle(holding ? Palette.ink : Palette.muted(on: tone))
                .frame(width: SideBar.mark, height: SideBar.mark)
            Text(said)
                .font(.system(size: titleSize))
                .foregroundStyle(holding ? Palette.ink : Palette.muted(on: tone))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            // At the end as the column's rows have their keys: on plates of
            // the words' size, the last as far in from the end as from top
            // and bottom; the cross in the same square once words are in.
            if holding {
                Button { search.clear() } label: {
                    Symbol("xmark", size: 8, weight: .semibold)
                        .foregroundStyle(Palette.muted(on: tone))
                        .frame(width: plate, height: plate)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyTip("Clear", keys: "esc")
                .padding(.trailing, -pull) // design: into the trailing padding, as KeyPlate pulls keys
            } else {
                ShortcutGlyphs(.mailSearch, size: titleSize, tint: nil).opacity(0.6)
                    .environment(\.keyPlate, KeyPlate(height: plate, pull: pull, corner: RowPlate.column.radius))
            }
        }
        .padding(.leading, SideBar.inner)
        .padding(.trailing, SideBar.endInset) // design: a tab row's own ends
        .frame(height: SideBar.row)
        .background {
            RoundedRectangle(cornerRadius: SideBar.radius, style: .continuous)
                .fill(hovering ? Palette.hover(on: tone) : Palette.wash(on: tone))
        }
        .contentShape(RoundedRectangle(cornerRadius: SideBar.radius, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture {
            desk.browser?.showMailPage()
            desk.searching = true
        }
        // The search stands on it and grows out of it (MailSearchLayer).
        .opacity(search.covering ? 0 : 1)
        // Where the search is to stand over it, in the window.
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { search.field = $0 }
        // And its colors, on the column's tone: the search starts in them.
        .onChange(of: hovering ? Palette.hover(on: tone) : Palette.wash(on: tone), initial: true) { _, ground in search.fieldGround = ground }
        .onChange(of: Palette.muted(on: tone), initial: true) { _, ink in search.fieldInk = ink }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(holding ? "Search, \(said)" : "Search")
    }
}

/// Where a chooser is on screen: the panel opens under it (MailAccountFloat).
/// Each chooser keeps its own: the column is drawn again elsewhere (a
/// space's picture while the spaces slide), and a shared one went to that
/// copy and was gone with it, so the panel opened nowhere until a relaunch.
final class FloatAnchorBox {
    weak var view: NSView?
}

struct FloatAnchor: NSViewRepresentable {
    let box: FloatAnchorBox

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        box.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { box.view = view }
}

/// The account panel in a window of its own over the window, as a tray is
/// (Tray): the column is a clipped view of its own, and the panel is wider
/// than it. It never takes the keyboard; MailAccountPanel's monitor has it.
@MainActor
final class MailAccountFloat {
    static let shared = MailAccountFloat()
    static let code = MailAccountFloat()
    weak var anchor: NSView?
    private var panel: NSPanel?
    /// Each show and hide, so a hide's end finds out whether it is still the last word.
    private var turn = 0

    /// The panel on screen over a window that is: what `choosing` only asks
    /// for (bench agent-mail-space's chooserUp).
    var up: Bool { panel.map { $0.isVisible && $0.parent?.isVisible == true } ?? false }

    func show(_ content: some View, width: CGFloat) {
        guard let anchor, let window = anchor.window else { return }
        // FieldGlass blurs its shadow by 24 pt and lowers it by 8 pt.
        // Give that blur room to fade before the window clips it.
        let inset: CGFloat = 64
        let host = NSHostingView(rootView: AnyView(content.frame(width: width).padding(inset)))
        host.sizingOptions = [.intrinsicContentSize]
        let size = host.fittingSize
        host.sizingOptions = []
        let panel = self.panel ?? NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.appearance = window.effectiveAppearance
        panel.contentView = host
        let at = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        // Keep the card under the chooser as the shadow's room changes, its
        // left edge on the chooser's; with the column on the window's right
        // it runs leftward from the chooser's right edge instead, and either
        // way it stays inside the window, 8 from its edges.
        let card = size.width - 2 * inset
        let frame = window.frame
        var left = at.minX
        if left + card > frame.maxX - 8 { left = max(frame.minX + 8, min(at.maxX, frame.maxX - 8) - card) }
        panel.setFrame(NSRect(x: left - inset, y: at.minY - 6 - size.height + inset, width: size.width, height: size.height), display: true)
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        self.panel = panel
        turn += 1
        // Mail held still (MailDesk.still): there at once, and gone so.
        if MailDesk.still {
            panel.alphaValue = 1
            panel.orderFront(nil)
            return
        }
        if !panel.isVisible { panel.alphaValue = 0 }
        panel.orderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        turn += 1
        let mine = turn
        if MailDesk.still { return gone(panel, mine) }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { self.gone(panel, mine) }
        })
        // Put away even when the fade never ends (a window not on screen).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.gone(panel, mine) }
    }

    private func gone(_ panel: NSPanel, _ mine: Int) {
        guard mine == turn, panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        panel.contentView = nil
    }
}

/// The account at the head of the mail column: all of them, or one. Its
/// choice comes up under it as ⌘K's list does in the field (MailAccountPanel).
private struct MailAccountChooser: View {
    @Environment(\.tabTitleSize) private var titleSize
    var list: MailList
    let accounts: [String]
    @Binding var open: Bool
    @Environment(\.tone) private var tone
    @MailStill private var still
    @State private var hovering = false

    static let height: CGFloat = 32

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: SideBar.markGap) {
                MailAccountMark(letter: MailAccountMark.letter(list.account, accounts: accounts), size: 18,
                                photo: MailAccountMark.photo(list.account, accounts: accounts))
                Text(MailAccountMark.name(list.account, accounts: accounts))
                    .font(.system(size: titleSize))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .id(list.account)
                    .transition(.opacity)
                Spacer(minLength: 4)
                Symbol("chevron.up.chevron.down", size: 9, weight: .semibold)
                    .foregroundStyle(Palette.muted(on: tone))
            }
            .padding(.leading, SideBar.inner)
            .padding(.trailing, SideBar.endInset) // design: a tab row's own ends
            .frame(height: Self.height)
            .background {
                RoundedRectangle(cornerRadius: SideBar.radius, style: .continuous)
                    .fill(open || hovering ? Palette.hover(on: tone) : .clear)
            }
            .contentShape(RoundedRectangle(cornerRadius: SideBar.radius, style: .continuous))
        }
        .buttonStyle(PressStyle(scale: ButtonSize.regular.pressed))
        .onHover { hovering = $0 }
        .contextMenu { MailAllAccountsMenu(account: list.account) }
        .animation(still ? nil : .linear(duration: 0.16), value: list.account)
        .accessibilityLabel("Account, \(MailAccountMark.name(list.account, accounts: accounts))")
    }
}

/// Show in All Accounts in an account's own menu (a right click on the
/// chooser, or on its row in Settings › Mail): the account's, or on All
/// Accounts each one's. Nothing with one account; the last one left in
/// can't be turned off.
struct MailAllAccountsMenu: View {
    let account: String
    private var center = MailCenter.shared

    var body: some View {
        if center.accounts.count > 1 {
            if account == "all" {
                Section("Show in All Accounts") {
                    ForEach(center.accounts, id: \.self) { one in toggle(one, title: one) }
                }
            } else {
                toggle(account, title: "Show in All Accounts")
            }
        }
    }

    private func toggle(_ one: String, title: String) -> some View {
        Toggle(title, isOn: Binding(get: { !center.apart.contains(one) }, set: { center.setInAll(one, $0) }))
            .disabled(!center.apart.contains(one) && !MailAllAccounts.canLeave(one, accounts: center.accounts, apart: center.apart))
    }
}

/// An account's Google photo on its round plate, with its letter while the
/// photo loads or if it is unavailable; ∗ for all of them.
struct MailAccountMark: View {
    let letter: String
    let size: CGFloat
    var photo: URL? = nil

    var body: some View {
        ZStack {
            Circle().fill(Palette.ink.opacity(0.72))
            Text(letter)
                .font(.system(size: size * 0.55, weight: .semibold))
                .foregroundStyle(Palette.ground)
            if let photo {
                AsyncImage(url: photo) { image in
                    image.resizable().interpolation(.high)
                } placeholder: {
                    Color.clear
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    /// All Accounts with one account left in it (the rest kept out,
    /// MailAllAccounts) is that account's, and says so.
    static func name(_ account: String, accounts: [String]) -> String {
        let together = MailAllAccounts.together(accounts, apart: MailCenter.shared.apart)
        return account == "all" ? (together.count > 1 ? "All Accounts" : together.first ?? "Add an account") : account
    }

    static func letter(_ account: String, accounts: [String]) -> String {
        let together = MailAllAccounts.together(accounts, apart: MailCenter.shared.apart)
        return accounts.isEmpty ? "+" : account == "all" && together.count > 1 ? "∗" : String(name(account, accounts: accounts).prefix(1)).uppercased()
    }

    static func photo(_ account: String, accounts: [String]) -> URL? {
        let together = MailAllAccounts.together(accounts, apart: MailCenter.shared.apart)
        let shown = account == "all" ? (together.count == 1 ? together.first : nil) : account
        return shown.flatMap(MailSettings.photo)
    }
}

extension MailAccountMark {
    /// An account's mark as the chooser draws it, "all" for every one:
    /// on its row in the field (⌘T, mail's ⌘K).
    @MainActor
    init(account: String, size: CGFloat) {
        let accounts = MailCenter.shared.accounts
        self.init(letter: Self.letter(account, accounts: accounts), size: size, photo: Self.photo(account, accounts: accounts))
    }
}

extension MailPage {
    /// Where the mail tab is, as its row in the field says it beside
    /// "Mail" (Tab.place): the account the column is on, as the chooser
    /// names it. Nothing before one is connected.
    @MainActor
    static var place: String {
        let accounts = MailCenter.shared.accounts
        return accounts.isEmpty ? "" : MailAccountMark.name(MailList.shared.account, accounts: accounts)
    }
}

/// The accounts, as ⌘K's list is drawn in the field (FieldActionsPanel): on
/// glass, wider than the chooser so every address is whole, a head saying
/// what it chooses, a row each with its mark, its words, how many need you,
/// its key (⌘0 all, ⌘1 to ⌘9 each, here or anywhere in mail) and a check
/// on the one on screen. The arrows walk it, an account shortcut or Return takes a row,
/// Escape puts it away, and so does a click anywhere else. Past five
/// accounts a search of its own at its foot, which typing narrows.
private struct MailAccountPanel: View {
    var list: MailList
    private var center = MailCenter.shared
    let accounts: [String]
    let close: () -> Void
    @State private var lit = 0
    @State private var words = ""
    @State private var pointed: Int?
    @State private var keys: Any?
    @State private var clicks: Any?

    private struct Choice {
        let title: String
        let letter: String?
        let photo: URL?
        let symbol: String?
        let number: Int?
        let count: Int
        let on: Bool
        let pick: () -> Void
    }

    private var choices: [Choice] {
        var out: [Choice] = []
        // All Accounts counts only the accounts in it; with one left in,
        // it is that account's row.
        let together = MailAllAccounts.together(accounts, apart: center.apart)
        if together.count > 1 {
            out.append(Choice(title: "All Accounts", letter: "∗", photo: nil, symbol: nil, number: 0,
                              count: MailAllAccounts.total(list.needs, accounts: accounts, apart: center.apart),
                              on: list.account == "all") { list.account = "all" })
        }
        for (n, account) in accounts.enumerated() {
            out.append(Choice(title: account, letter: String(account.prefix(1)).uppercased(), photo: MailSettings.photo(account),
                              symbol: nil, number: n < 9 ? n + 1 : nil,
                              count: list.needs[account] ?? 0,
                              on: list.account == account || (together == [account] && list.account == "all")) { list.account = account })
        }
        out.append(Choice(title: "Add Account…", letter: nil, photo: nil, symbol: "plus", number: nil, count: 0, on: false) {
            MailDesk.shared.browser?.openSettings(.mail)
        })
        let needle = words.trimmingCharacters(in: .whitespaces).lowercased()
        return needle.isEmpty ? out : out.filter { $0.title.lowercased().contains(needle) }
    }

    private var searchable: Bool { accounts.count > 5 }

    var body: some View {
        let choices = self.choices
        VStack(alignment: .leading, spacing: 0) {
            Text("Account")
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 4)
            VStack(spacing: 0) {
                if choices.isEmpty {
                    Text("No account")
                        .font(.system(size: 13.5))
                        .foregroundStyle(Palette.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .frame(height: FieldActionsPanel.row)
                }
                ForEach(Array(choices.enumerated()), id: \.offset) { index, choice in
                    // A line before what is not an account.
                    if choice.letter == nil, index > 0 {
                        Rectangle().fill(Omnibox.seam).frame(height: 1).padding(.vertical, 4).padding(.horizontal, 8)
                    }
                    row(choice, index: index)
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 4)
            if searchable {
                Rectangle()
                    .fill(Omnibox.seam)
                    .frame(height: 1)
                MailAccountSearch(words: $words)
                    .frame(height: 20)
                    .padding(.horizontal, 16)
                    .frame(height: 44)
            }
        }
        .background { FieldGlass(shape: RoundedRectangle(cornerRadius: Radius.floating, style: .continuous), lifted: true) }
        .onAppear {
            lit = choices.firstIndex(where: \.on) ?? 0
            listen()
        }
        .onDisappear { stop() }
        .onChange(of: words) { _, _ in lit = 0 }
        .transaction { $0.animation = nil }
    }

    private func row(_ choice: Choice, index: Int) -> some View {
        HStack(spacing: 10) {
            Group {
                if let letter = choice.letter {
                    MailAccountMark(letter: letter, size: 18, photo: choice.photo)
                } else if let symbol = choice.symbol {
                    Symbol(symbol, size: 12).foregroundStyle(Palette.ink)
                }
            }
            .frame(width: 18)
            Text(choice.title)
                .font(.system(size: 13.5))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            Spacer(minLength: 8)
            if choice.count > 0 {
                Text("\(choice.count)")
                    .font(.system(size: 12.5).monospacedDigit())
                    .foregroundStyle(Palette.muted)
                    .fixedSize()
            }
            if let number = choice.number {
                let action: Shortcut.Action? = number == 0 ? .mailAccountAll : Shortcut.numbered("mailAccount", number)
                if let action { ShortcutGlyphs(action, size: 11.5, tint: nil).opacity(0.6) }
            }
            // The account on screen now.
            Group {
                if choice.on {
                    Symbol("checkmark", size: 11, weight: .semibold)
                        .foregroundStyle(Palette.ink)
                }
            }
            .frame(width: 14)
        }
        .padding(.horizontal, 8)
        .frame(height: FieldActionsPanel.row)
        .background {
            if index == lit {
                RoundedRectangle(cornerRadius: Radius.surface, style: .continuous).fill(Omnibox.chosenFill)
            }
        }
        .contentShape(Rectangle())
        .onHover { on in
            if on {
                lit = index
                pointed = index
            } else if pointed == index {
                pointed = nil
            }
        }
    }

    private func take(_ index: Int) {
        let choices = self.choices
        guard choices.indices.contains(index) else { return }
        close()
        choices[index].pick()
    }

    /// The arrows, Return and Escape, and the pointer, while it is up; the
    /// rest of the keys are the search's.
    private func listen() {
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let browser = MailDesk.shared.browser,
                  let owner = BrowserWindows.shared.window(for: browser),
                  event.window === owner || event.window?.parent === owner else { return event }
            let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
            let accountKeys: [Shortcut.Action] = [
                .mailAccountAll, .mailAccount1, .mailAccount2, .mailAccount3, .mailAccount4,
                .mailAccount5, .mailAccount6, .mailAccount7, .mailAccount8, .mailAccount9,
            ]
            if !flags.intersection([.command, .control, .option]).isEmpty,
               let number = accountKeys.firstIndex(where: { Keymap.shared.matches(event, $0) }) {
                close()
                MailList.shared.choose(number: number)
                return nil
            }
            guard flags.isEmpty else { return event }
            let count = max(1, choices.count)
            switch event.keyCode {
            case 125: lit = (lit + 1) % count
            case 126: lit = (lit - 1 + count) % count
            case 36, 76: take(lit)
            case 53: close()
            default: return event
            }
            return nil
        }
        clicks = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            if let pointed {
                take(pointed)
                return nil
            }
            // In the search: the search's. Anywhere else: the panel goes.
            if let field = event.window?.firstResponder as? NSTextView, field.isFieldEditor,
               let view = event.window?.contentView?.hitTest(event.locationInWindow), view === field || view.isDescendant(of: field) {
                return event
            }
            close()
            return event
        }
    }

    private func stop() {
        if let keys { NSEvent.removeMonitor(keys) }
        if let clicks { NSEvent.removeMonitor(clicks) }
        keys = nil
        clicks = nil
    }
}

/// The account panel's search, as ⌘K's list has its own (ActionSearch): a
/// plain field, the keyboard's while the panel is up.
struct MailAccountSearch: NSViewRepresentable {
    @Binding var words: String
    var placeholder = "Search accounts\u{2026}"

    func makeCoordinator() -> Coordinator { Coordinator(words: $words) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSSearchField()
        field.isAutomaticTextCompletionEnabled = false
        if let cell = field.cell as? NSSearchFieldCell {
            cell.searchButtonCell = nil
            cell.cancelButtonCell = nil
        }
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13.5)
        field.textColor = NSColor(Palette.ink)
        field.placeholderString = placeholder
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = context.coordinator
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != words { field.stringValue = words }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        let words: Binding<String>
        init(words: Binding<String>) { self.words = words }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            words.wrappedValue = field.stringValue
        }
    }
}

/// A row of the mail column: its mark, its words, how many at its end,
/// rolling to a new number; a pulse when something just went into it. The
/// chosen one has its own plate, there at once: nothing slides between rows.
private struct MailColumnRow: View {
    @Environment(\.tabTitleSize) private var titleSize
    let symbol: String
    let title: String
    let count: Int
    let chosen: Bool
    let pulse: Int
    var quiet = false
    /// Said at its end instead of a count: "2 new".
    var note = ""
    /// A cross in the note's place under the pointer, that puts the row away.
    var close: (() -> Void)? = nil
    let choose: () -> Void
    @Environment(\.tone) private var tone
    @MailStill private var still
    @State private var hovering = false
    @State private var lit = false

    var body: some View {
        Button(action: choose) {
            HStack(spacing: SideBar.markGap) {
                Symbol(symbol, size: SideBar.mark - 3)
                    .foregroundStyle(chosen ? Palette.ink : Palette.muted(on: tone))
                    .frame(width: SideBar.mark, height: SideBar.mark)
                Text(title)
                    .font(.system(size: titleSize))
                    .foregroundStyle(chosen ? Palette.ink : quiet ? Palette.muted(on: tone) : Palette.strong(on: tone).opacity(0.88))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let close, hovering {
                    Button(action: close) {
                        Symbol("xmark", size: 9, weight: .semibold)
                            .foregroundStyle(Palette.muted(on: tone))
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .keyTip("Not Now")
                } else if !note.isEmpty {
                    Text(note)
                        .font(.system(size: titleSize - 0.5))
                        .foregroundStyle(Palette.muted(on: tone))
                        .lineLimit(1)
                } else if count > 0 {
                    Text("\(count)")
                        .font(.system(size: titleSize - 0.5).monospacedDigit())
                        .foregroundStyle(Palette.muted(on: tone))
                        .lineLimit(1)
                        .contentTransition(.numericText(value: Double(count)))
                }
            }
            .padding(.leading, SideBar.inner)
            .padding(.trailing, SideBar.endInset) // design: a tab row's own ends
            .frame(height: SideBar.row)
            .background {
                RoundedRectangle(cornerRadius: SideBar.radius, style: .continuous)
                    .fill(chosen || lit ? Palette.wash(on: tone) : hovering ? Palette.hover(on: tone) : .clear)
            }
            .scaleEffect(lit ? 1.02 : 1, anchor: .leading)
            .contentShape(RoundedRectangle(cornerRadius: SideBar.radius, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(nil, value: chosen)
        .onHover { hovering = $0 }
        .animation(still ? nil : .easeOut(duration: 0.22), value: count)
        .onChange(of: pulse) { _, _ in
            guard !still else { return }
            withAnimation(.easeOut(duration: 0.12)) { lit = true }
            withAnimation(.easeIn(duration: 0.24).delay(0.14)) { lit = false }
        }
    }
}

/// The pages of mail's space, under the lists (Browser.mailTabs): a link's
/// peek kept with ⌘O, a ⌘-click. Each a row as any space's has it, its
/// mark, its name, its cross and its menu, Move to Space among them; the one
/// in front on its own plate, as a list's row has it. Nothing while there
/// are none.
private struct MailTabRows: View {
    var browser: Browser
    var prefs: Preferences
    private var folders = Folders.shared
    @Environment(\.tone) private var tone

    var body: some View {
        let rows = browser.mailTabs
        let tasks = MailTaskRows.folders(in: browser, folders)
        if !rows.isEmpty || !tasks.isEmpty {
            VStack(alignment: .leading, spacing: SideBar.gap) {
                Text("Tabs")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.muted(on: tone))
                    .padding(.horizontal, 10)
                    .padding(.top, 16)
                    .padding(.bottom, 2)
                ForEach(tasks) { folder in
                    MailTaskRows(browser: browser, prefs: prefs, folders: folders, folder: folder)
                }
                ForEach(rows) { tab in
                    MailTabRow(browser: browser, prefs: prefs, tab: tab)
                }
            }
        }
    }
}

/// A tab of mail's space, the plate under it while it is the one in front.
private struct MailTabRow: View {
    let browser: Browser
    var prefs: Preferences
    let tab: Tab

    var body: some View {
        SideRow(browser: browser, prefs: prefs, tab: tab, live: tab.id == browser.activeID)
    }
}

/// A task begun from mail (D, ⌘J, a routine by a mail) under Tabs, as its
/// folder is in any space's column (FolderRow): the face while it works,
/// the hand while it waits on you, the tick for what you haven't seen; a
/// click opens or shuts it. Its tabs under it come up over the email as a
/// peek, live (Browser.peekLive); ⌘-click, as the tab, Back to Mail over it.
private struct MailTaskRows: View {
    var browser: Browser
    var prefs: Preferences
    var folders: Folders
    let folder: Folders.Folder

    var body: some View {
        let open = folders.isOpen(folder.id)
        VStack(alignment: .leading, spacing: SideBar.gap) {
            FolderRow(browser: browser, folder: folder, open: open)
            // Asking, its tab is out from under it, shut or not.
            ForEach(MailTaskRows.tabs(of: folder, in: browser).filter { open || folder.asking.contains($0.id) }) { tab in
                MailTabRow(browser: browser, prefs: prefs, tab: tab)
                    .padding(.leading, Folders.indent)
                    .transition(.opacity.combined(with: .offset(y: -6)))
            }
        }
    }

    /// Its tabs in mail's space, mail's own page aside (the page a task was
    /// begun from goes into its folder elsewhere).
    static func tabs(of folder: Folders.Folder, in browser: Browser) -> [Tab] {
        folder.members.compactMap { id in browser.tabs.first { $0.id == id } }
            .filter { !MailPage.isMail($0.pending ?? $0.address) }
    }

    /// The tasks' folders of mail's space: every task there was begun from
    /// mail. Yab's own work out of sight never shows.
    static func folders(in browser: Browser, _ folders: Folders) -> [Folders.Folder] {
        guard browser.inMail else { return [] }
        return folders.folders.filter { $0.nest == nil && !$0.sealed && !tabs(of: $0, in: browser).isEmpty }
    }
}

/// New Mail, at the far end of the lights' row where reload stands in the
/// other spaces: a rounded square on glass, a pen
/// in a square. C does the same.
struct MailNewButton: View {
    private var shortcut = Keymap.shared.slot(.mailNew)
    static let side = ButtonSize.regular.height

    var body: some View {
        Button { MailDesk.shared.compose() } label: { Symbol("square.and.pencil", size: 12) }
            .buttonStyle(.yab(.glass, .regular, icon: .square))
            // The new mail grows out of it (MailMorph).
            .background(MailPlace(kind: .newMail))
            // Never the window's first key view, as the doors it stands for.
            .focusable(false)
            .keyTip("New Mail", keys: shortcut.keys?.text ?? "")
            .accessibilityLabel("New Mail")
    }
}

/// The envelope at the column's foot: into mail and out, how many threads
/// need you beside it.
struct MailDoor: View {
    var browser: Browser
    var center = MailCenter.shared
    private var shortcut = Keymap.shared.slot(.mail)
    @Environment(\.tone) private var tone
    @State private var hovering = false

    var body: some View {
        Button { browser.toggleMail() } label: {
            HStack(spacing: 4) {
                Symbol(browser.inMail ? "chevron.left" : "envelope", size: 13)
                if !browser.inMail, center.counted > 0 {
                    Text(center.counted > 99 ? "99+" : "\(center.counted)")
                        .font(.system(size: SidebarTypography.current, weight: .medium).monospacedDigit())
                }
            }
            .foregroundStyle(Palette.ink.opacity(0.75))
            .padding(.horizontal, 8)
            .frame(minWidth: Door.side, minHeight: Door.side)
            // The column foot's doors' corner, a row's (FootPlus).
            .background {
                RoundedRectangle(cornerRadius: SideBar.radius, style: .continuous)
                    .fill(browser.inMail ? Palette.wash(on: tone) : hovering ? Palette.hover(on: tone) : .clear)
            }
            .contentShape(RoundedRectangle(cornerRadius: SideBar.radius, style: .continuous))
        }
        .buttonStyle(PressStyle(scale: ButtonSize.regular.pressed))
        .onHover { hovering = $0 }
        .keyTip(browser.inMail ? "Back to your tabs" : "Mail", keys: shortcut.keys?.text ?? "")
        .accessibilityLabel(browser.inMail ? "Back to your tabs" : "Mail, \(center.needYou) need you")
    }
}
