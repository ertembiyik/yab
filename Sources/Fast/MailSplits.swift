import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Splits (docs/mail.md, Splits): the inbox divided by who writes and what
// the mail is. A split is a rule: the people and
// domains it gathers, words, a search in Gmail's own words (MailQuery), and
// kinds of mail as this Mac reads them (MailSense: a bill, an invite, a
// delivery). Five come with mail, each off until turned on: VIP, Team,
// Calendar, Receipts and Dev; the rest are yours, kept from a search, made
// in words with Claude, or Your lists as they were kept before. A split's
// mail is the inbox's: done, it leaves. Where it goes is the split's to say:
// also in Needs you and Other, only in the split, or out of the inbox as it
// comes (Skip the inbox), never from people you have written to or from
// your own domain. The column lists the inbox's lists and the splits in the
// order they were dragged to, empty splits hidden, and ⇥ follows it.

extension MailList {
    /// A split: its rules, kept as one line (MailRule), what it wears and
    /// says, and where its mail goes. A built-in one has its own id and is
    /// on only once turned on; one of yours is "q:" and the rules it was
    /// made with, its id however its rules change since.
    struct Split: Identifiable, Equatable, Codable {
        /// Where its mail goes.
        enum Mode: String, Codable, CaseIterable, Sendable {
            /// Here, and in Needs you or Other as well.
            case also
            /// Here alone: out of Needs you and Other.
            case only
            /// Out of the inbox as it comes: archived on arrival (MailSkip).
            case skip

            var title: String {
                switch self {
                case .also: return "Also in Needs you"
                case .only: return "Only here"
                case .skip: return "Skips the inbox"
                }
            }
        }

        var id: String
        var title: String
        var q: String
        /// A glyph's name for the column and its head.
        var icon: String?
        /// What it keeps, in words: Claude's when it made it.
        var why: String?
        /// "sender" or "day"; nil, one run newest first.
        var group: String?
        /// Pages kept with it (a Stripe dashboard with Receipts): a peek
        /// away, or all opened as tabs.
        var pages: [Page]?
        /// Turned on: a built-in split is off until it is; yours are on.
        var on = true
        var mode: Mode = .only
        /// Its new mail says so in a notification (MailNotify).
        var notify = false
        /// When Skip the inbox was turned on: mail that came before stays.
        var skipSince: Date?

        init(id: String? = nil, title: String, q: String, icon: String? = nil, why: String? = nil, group: String? = nil,
             pages: [Page]? = nil, on: Bool = true, mode: Mode = .only, notify: Bool = false) {
            self.id = id ?? "q:" + q
            self.title = title
            self.q = q
            self.icon = icon
            self.why = why
            self.group = group
            self.pages = pages
            self.on = on
            self.mode = mode
            self.notify = notify
        }

        var rules: [MailRule] { MailRule.parse(q) }
        /// One that comes with mail, not one of yours.
        var builtIn: Bool { !id.hasPrefix("q:") }
        /// Out of the column and Settings' list of splits: Ads and promos,
        /// reached from Other's head and its own row in Settings › Mail.
        var hidden: Bool { id == MailSplits.ads }
        /// Its new mail says so: as it says, and never once it skips the inbox.
        var notifies: Bool { notify && mode != .skip }

        enum CodingKeys: String, CodingKey { case id, title, q, icon, why, group, pages, on, mode, notify, skipSince }

        /// Kept by this Yab or a later one: what isn't said takes its default.
        init(from decoder: Decoder) throws {
            let kept = try decoder.container(keyedBy: CodingKeys.self)
            q = try kept.decodeIfPresent(String.self, forKey: .q) ?? ""
            id = try kept.decodeIfPresent(String.self, forKey: .id) ?? "q:" + q
            title = try kept.decodeIfPresent(String.self, forKey: .title) ?? q
            icon = try kept.decodeIfPresent(String.self, forKey: .icon)
            why = try kept.decodeIfPresent(String.self, forKey: .why)
            group = try kept.decodeIfPresent(String.self, forKey: .group)
            pages = try kept.decodeIfPresent([Page].self, forKey: .pages)
            on = try kept.decodeIfPresent(Bool.self, forKey: .on) ?? true
            mode = (try? kept.decodeIfPresent(Mode.self, forKey: .mode)) ?? .only
            notify = try kept.decodeIfPresent(Bool.self, forKey: .notify) ?? false
            skipSince = try kept.decodeIfPresent(Date.self, forKey: .skipSince)
        }
    }

    /// A row of the column: one of the inbox's lists, or a split.
    struct Entry: Identifiable, Equatable {
        let id: String
        let title: String
        let symbol: String
        /// How many it holds, as the inbox's lists say it.
        let count: Int
        /// What is new in a split, in words rather than a number to learn.
        let note: String
    }
}

enum MailSplits {
    /// The inbox's own lists, which the splits stand among in the column.
    /// Promised and Archive ("older") only while they hold something.
    static let base = ["needs", "waiting", "promised", "other", "later", "older"]

    /// Where Dev's mail comes from: code, issues and builds.
    static let dev = ["github.com", "gitlab.com", "bitbucket.org", "linear.app", "circleci.com", "buildkite.com", "travis-ci.com",
                      "vercel.com", "netlify.com", "sentry.io"]

    /// Ads and promos: Gmail's Promotions and Social kept out of every list
    /// on this Mac alone (Only here, out of the column), Gmail's inbox left
    /// as it is; on until Settings › Mail says otherwise.
    static let ads = "ads"
    static let adsSearch = "category:promotions OR category:social"

    /// The splits that come with mail, each off until turned on (Ads and
    /// promos on), each from what this Mac knows of a mail already
    /// (MailSense, Gmail's categories), no model of its own.
    static let builtIns: [MailList.Split] = [
        MailList.Split(id: "vip", title: "VIP", q: "", icon: "star", on: false, mode: .only, notify: true),
        MailList.Split(id: "team", title: "Team", q: "team:domain", icon: "person.2", on: false, mode: .only, notify: true),
        MailList.Split(id: "calendar", title: "Calendar", q: "kind:meeting", icon: "calendar", on: false, mode: .only),
        MailList.Split(id: "receipts", title: "Receipts", q: "kind:invoice", icon: "creditcard", on: false, mode: .only),
        MailList.Split(id: "dev", title: "Dev", q: MailRule.line(dev.map { MailRule(kind: "from", value: $0) }),
                       icon: "chevron.left.forwardslash.chevron.right", on: false, mode: .only),
        MailList.Split(id: ads, title: "Ads and promos", q: MailRule.line([MailRule(kind: "search", value: adsSearch)]),
                       icon: "megaphone", on: true, mode: .only),
    ]

    /// Settings: the splits, the column's order, empty splits hidden; and
    /// Your lists as they were kept before splits.
    static let key = "mail.splits"
    static let orderKey = "mail.order"
    static let hideKey = "mail.splits.hide"
    static let listsKey = "mail.lists"

    /// The list Skip the inbox's mail of the day is found in (the new tab's
    /// line, ⌘K's Go To).
    static let skipped = "skipped"

    // MARK: - kept

    /// The splits as kept, the built-in ones among them; the first time,
    /// Your lists (mail.lists) made splits of, kept as splits from then on,
    /// and the built-in ones off. A built-in split this Yab has that the
    /// ones kept don't joins them, off.
    static func load(_ defaults: UserDefaults) -> [MailList.Split] {
        var splits: [MailList.Split]
        if let data = defaults.data(forKey: key), let kept = try? JSONDecoder().decode([MailList.Split].self, from: data) {
            splits = kept
        } else {
            splits = migrated(defaults.data(forKey: listsKey)) + builtIns
            save(splits, defaults)
        }
        for one in builtIns where !splits.contains(where: { $0.id == one.id }) { splits.append(one) }
        return splits
    }

    static func save(_ splits: [MailList.Split], _ defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(splits) { defaults.set(data, forKey: key) }
    }

    /// Your lists as splits, nothing of them lost: the same names, rules,
    /// icons, words, grouping and pages; their mail in Needs you as well,
    /// as a list's was, and quiet. Kept as they were too (mail.lists), for
    /// an older Yab.
    static func migrated(_ lists: Data?) -> [MailList.Split] {
        struct List: Decodable {
            var title: String
            var q: String
            var icon: String?
            var why: String?
            var group: String?
            var pages: [MailList.Page]?
        }
        guard let lists, let old = try? JSONDecoder().decode([List].self, from: lists) else { return [] }
        var seen = Set<String>()
        return old.compactMap { list in
            let q = list.q.trimmingCharacters(in: .whitespaces)
            guard !q.isEmpty, seen.insert(q).inserted else { return nil }
            return MailList.Split(title: list.title.isEmpty ? q : list.title, q: q, icon: list.icon, why: list.why, group: list.group,
                                  pages: list.pages, on: true, mode: .also, notify: false)
        }
    }

    // MARK: - the column's order

    /// The column's order: the inbox's lists and every split, as they were
    /// dragged; one not in it yet takes its place, a built-in split under
    /// Needs you and one of yours at the end.
    static func order(_ kept: [String]?, splits: [MailList.Split]) -> [String] {
        let known = Set(base + splits.map(\.id))
        var out: [String] = []
        for id in kept ?? [] where known.contains(id) && !out.contains(id) { out.append(id) }
        for id in base where !out.contains(id) {
            if id == "needs" {
                out.insert(id, at: 0)
            } else if id == "older", let later = out.firstIndex(of: "later") {
                // Archive under Later, where an older Yab's order has none.
                out.insert(id, at: later + 1)
            } else if id == MailPromise.list, let waiting = out.firstIndex(of: "waiting") {
                // Promised beside Waiting, its pair.
                out.insert(id, at: waiting + 1)
            } else {
                out.append(id)
            }
        }
        var under = (out.firstIndex(of: "needs") ?? -1) + 1
        // Out of the column (Ads and promos): in no order, sorted after the rest.
        for one in builtIns where !one.hidden && !out.contains(one.id) && splits.contains(where: { $0.id == one.id }) {
            out.insert(one.id, at: under)
            under += 1
        }
        for split in splits where !split.hidden && !out.contains(split.id) { out.append(split.id) }
        return out
    }

    /// The order with one moved to where another stands, as a drag over
    /// it moves it: before it going up, after it going down.
    static func moved(_ order: [String], _ id: String, to target: String) -> [String] {
        guard id != target, let from = order.firstIndex(of: id), let to = order.firstIndex(of: target) else { return order }
        var out = order
        out.remove(at: from)
        out.insert(id, at: to)
        return out
    }

    /// The column's rows in their order: the inbox's lists always, a split
    /// while it is on, an empty one only when empty ones show or it is the
    /// one in front. Counts as MailDesk.read gives them, "new:<id>" a
    /// split's unread.
    @MainActor
    static func column(order: [String], splits: [MailList.Split], counts: [String: Int], hideEmpty: Bool, front: String) -> [MailList.Entry] {
        order.compactMap { id in
            if let list = MailList.base.first(where: { $0.id == id }) {
                // Promised and Archive only while they hold something, or are in front.
                if id == MailSplit.older.rawValue || id == MailPromise.list, (counts[id] ?? 0) == 0, front != id { return nil }
                return MailList.Entry(id: id, title: list.name, symbol: list.symbol, count: counts[id] ?? 0, note: "")
            }
            guard let split = splits.first(where: { $0.id == id }), split.on, !split.hidden else { return nil }
            // How many threads it holds, as Needs you says its own: one
            // number down the column, what is left to go through.
            let count = counts[id] ?? 0
            guard count > 0 || !hideEmpty || front == id else { return nil }
            return MailList.Entry(id: id, title: split.title, symbol: split.icon ?? "magnifyingglass", count: count, note: "")
        }
    }

    // MARK: - in words

    /// A kind of mail as a split's rule says it (MailSense).
    static func kindName(_ raw: String) -> String {
        switch raw {
        case "person": return "People"
        case "code": return "Codes"
        case "invoice": return "Bills"
        case "meeting": return "Invites"
        case "shipping": return "Deliveries"
        case "list": return "Lists"
        case "promotion": return "Promotions"
        default: return raw.capitalized
        }
    }

    /// The kinds a split's rule may name, as MailSense reads mail.
    static let kinds = ["person", "code", "invoice", "meeting", "shipping", "list", "promotion"]

    /// What a split gathers, in a few words: "anna@fold.studio and 2 more",
    /// "Bills", "your own domain".
    static func gathers(_ split: MailList.Split) -> String {
        let said = split.rules.map(\.said.value)
        if said.isEmpty { return split.id == "vip" ? "Nobody yet: Add to VIP is among mail’s commands" : "Nothing yet" }
        return said.count > 2 ? said.prefix(2).joined(separator: ", ") + " and \(said.count - 2) more" : said.joined(separator: " and ")
    }

    /// An account's own domain, for Team and Skip the inbox's guard: none
    /// for the domains everyone writes from (gmail.com).
    static func domain(of me: String) -> String? {
        guard let domain = me.lowercased().split(separator: "@").last.map(String.init), domain.contains("."),
              !MailBlock.common.contains(domain) else { return nil }
        return domain
    }

    /// "12 newsletters archived today": a split named by a plural says its
    /// mail by it; another its name after "from".
    static func archivedLine(_ count: Int, names: [String]) -> String {
        guard names.count == 1, let name = names.first else { return "\(count.formatted()) archived today" }
        let word = name.lowercased()
        let plural = !word.contains(" ") && word.hasSuffix("s") && !word.hasSuffix("ss")
        if plural { return "\(count.formatted()) \(count == 1 ? String(word.dropLast()) : word) archived today" }
        return "\(count.formatted()) from \(name) archived today"
    }
}

// MARK: - sorting

/// The splits that are on, in the column's order, as they sort threads of
/// the inbox: a value any thread can take (the sync's, a notification's
/// look), so the column, Skip the inbox and notifications sort alike.
struct MailSplitSort: Sendable, Equatable {
    struct Rule: Sendable, Equatable {
        let id: String
        let mode: MailList.Split.Mode
        let notify: Bool
        let since: Date?
        /// Addresses and domains whose mail it gathers: from:, and with:'s
        /// sender side.
        let from: [String]
        /// The account's own domain (Team).
        let team: Bool
        /// Whom mail went to: your own mail (to:), anyone's (with:).
        let to: [String]
        let with: [String]
        /// MailSense's kinds, by their names (MailSensed.Kind).
        let kinds: Set<String>
        /// Its words and searches, each asked of the store, Spam and Trash
        /// too: a thread of the inbox answers when its mail does.
        let asks: [MailQuery]
        /// Never a thread you wrote in, starred, or from your own domain,
        /// as Skip the inbox guards (Ads and promos).
        var guarded = false

        /// It gathers by people: from, to, with, or your own domain.
        var people: Bool { !from.isEmpty || team || !to.isEmpty || !with.isEmpty }
        /// It asks nothing at all, so it gathers nothing (a VIP of nobody).
        var empty: Bool { !people && kinds.isEmpty && asks.isEmpty }
        /// Meetings: what MailSense reads as one, and mail carrying an
        /// invitation this Mac read (MailInvite), sensed or not.
        var invites: Bool { kinds.contains(MailSensed.Kind.meeting.rawValue) }
        /// What the store answers for it: whom mail went to, its asks, and
        /// the threads with invitations.
        var answered: Bool { !to.isEmpty || !with.isEmpty || !asks.isEmpty || invites }
        /// What it asks of the store, as one key, for its answers kept.
        var key: String {
            (invites ? "\u{1E}" : "") + ([to.joined(separator: ","), with.joined(separator: ",")] + asks.map(\.text)).joined(separator: "\u{1F}")
        }
        /// An ask of labels or flags: its answers move with them too.
        var labeled: Bool { asks.contains(where: \.labeled) }

        /// A split's rule as the store and the facts answer it.
        init(_ split: MailList.Split) {
            var from: [String] = [], to: [String] = [], with: [String] = [], kinds = Set<String>(), asks: [MailQuery] = []
            var words: [String] = [], team = false
            for rule in split.rules {
                let value = rule.value.lowercased()
                switch rule.kind {
                case "from": from.append(value)
                case "to": to.append(value)
                case "with":
                    from.append(value)
                    with.append(value)
                case "team": team = true
                case "kind": kinds.insert(value)
                case "words": words.append(rule.value)
                case "search": if let ask = Rule.anywhere(MailQuery.parse(rule.value)) { asks.append(ask) }
                default: break
                }
            }
            if !words.isEmpty, let ask = Rule.anywhere(MailQuery.parse(words.joined(separator: " "))) { asks.append(ask) }
            self.init(id: split.id, mode: split.mode, notify: split.notifies, since: split.skipSince, from: from, team: team, to: to,
                      with: with, kinds: kinds, asks: asks)
            guarded = split.id == MailSplits.ads
        }

        init(id: String, mode: MailList.Split.Mode, notify: Bool = false, since: Date? = nil, from: [String] = [], team: Bool = false,
             to: [String] = [], with: [String] = [], kinds: Set<String> = [], asks: [MailQuery] = []) {
            self.id = id
            self.mode = mode
            self.notify = notify
            self.since = since
            self.from = from
            self.team = team
            self.to = to
            self.with = with
            self.kinds = kinds
            self.asks = asks
        }

        /// A search asked of everything kept, Spam and Trash too: what the
        /// inbox holds of it is the facts' to say, so its answer moves with
        /// the mail alone. Nil for one that asks nothing.
        static func anywhere(_ asked: MailQuery) -> MailQuery? {
            asked.root.map { MailQuery(root: .all([$0, .anywhere]), text: asked.text) }
        }
    }

    /// The splits on, in the column's order: no more than 64, a bit each.
    let rules: [Rule]
    /// How the inbox's own lists sort (MailSplit.Policy): another one
    /// places every thread again (MailSplitCache keeps a placing by sort).
    var policy = MailSplit.Policy.current

    static let none = MailSplitSort(rules: [])

    init(rules: [Rule], policy: MailSplit.Policy = .current) {
        self.rules = Array(rules.prefix(64))
        self.policy = policy
    }

    /// The splits on, as the column orders them.
    init(_ splits: [MailList.Split], order: [String], policy: MailSplit.Policy = .current) {
        let on = splits.filter(\.on)
        let ordered = order.compactMap { id in on.first { $0.id == id } } + on.filter { !order.contains($0.id) }
        self.init(rules: ordered.map(Rule.init), policy: policy)
    }

    func index(_ id: String) -> Int? { rules.firstIndex { $0.id == id } }

    /// Where threads stand among the splits: those whose rules each answers
    /// (a bit for each, in the column's order), and the one that takes it
    /// out of Needs you and Other, the first in order that does; by thread,
    /// and in the order of the facts placed (`members`, `homes`, -1 for
    /// none), for a pass over them that hashes no id.
    struct Placed: Sendable {
        var member: [String: UInt64] = [:]
        var home: [String: Int] = [:]
        var members: [UInt64] = []
        var homes: [Int8] = []
        var isEmpty: Bool { member.isEmpty }
    }

    /// What the store answers for a rule: the threads whose mail went to
    /// whom it gathers, those its asks find, and those carrying an
    /// invitation, for a rule of meetings; nil where it asks nothing.
    struct Answer: Sendable {
        var recipients: Set<String>?
        var asked: Set<String>?
        var invited: Set<String>?
    }

    /// The store's answers, a rule's at its place.
    struct Answers: Sendable {
        var each: [Answer] = []
    }

    /// The store's answers for one rule, for these threads or all it keeps.
    static func answer(_ rule: Rule, in store: MailStore, among ids: [String]?, now: Date) -> Answer {
        var out = Answer()
        if !rule.to.isEmpty || !rule.with.isEmpty {
            var found = Set<String>()
            if !rule.to.isEmpty { found.formUnion(store.threads(to: rule.to, mine: true, among: ids)) }
            if !rule.with.isEmpty { found.formUnion(store.threads(to: rule.with, mine: false, among: ids)) }
            out.recipients = found
        }
        for ask in rule.asks {
            // One the store can't answer finds nothing here.
            let found = store.threads(answering: ask, among: ids, now: now) ?? []
            out.asked = out.asked.map { $0.intersection(found) } ?? found
        }
        if rule.invites { out.invited = store.invited(among: ids) }
        return out
    }

    /// The store's answers for every rule.
    func answers(_ store: MailStore, among ids: [String]?, now: Date) -> Answers {
        Answers(each: rules.map { $0.answered ? MailSplitSort.answer($0, in: store, among: ids, now: now) : Answer() })
    }

    /// Where each of these threads stands: only threads of the inbox, not
    /// put off or muted, in Needs you or Other (Waiting keeps its own),
    /// by who wrote in them (`people`), what they are (`kind`) and what the
    /// store answered.
    func place(_ facts: [MailSplit.Facts], me: String, answers: Answers, now: Date) -> Placed {
        guard !rules.isEmpty, rules.contains(where: { !$0.empty }) else { return Placed() }
        // Who the splits gather by sender, an address or a domain, to their
        // bits; and each thread's senders as a whole, once worked out, to
        // the bits they make (most of an inbox is a few senders' mail).
        var who: [Substring: UInt64] = [:]
        let mine = MailSplits.domain(of: me)
        for (n, rule) in rules.enumerated() {
            let bit: UInt64 = 1 << UInt64(n)
            for value in rule.from { who[Substring(value), default: 0] |= bit }
            if rule.team, let mine { who[Substring(mine), default: 0] |= bit }
        }
        var bySenders: [String: UInt64] = [:]
        // Each rule's answers at hand, an empty set of invitations as none.
        let recipients = answers.each.map(\.recipients), asked = answers.each.map(\.asked)
        let invited = answers.each.map { $0.invited?.isEmpty == false ? $0.invited : nil }
        var placed = Placed()
        placed.members = Array(repeating: 0, count: facts.count)
        placed.homes = Array(repeating: -1, count: facts.count)
        for (index, fact) in facts.enumerated() where fact.inbox && !fact.snoozed && !fact.muted && !fact.gone {
            guard let base = MailSplit.of(fact, now: now, policy: policy), base != .waiting else { continue }
            var senders: UInt64 = 0
            if !who.isEmpty, !fact.people.isEmpty {
                if let known = bySenders[fact.people] {
                    senders = known
                } else {
                    for address in fact.people.split(separator: "|") {
                        senders |= who[address] ?? 0
                        guard let at = address.firstIndex(of: "@") else { continue }
                        // The domain and each under which it stands: mail.stripe.com, stripe.com.
                        var domain = address[address.index(after: at)...]
                        while !domain.isEmpty {
                            senders |= who[domain] ?? 0
                            guard let dot = domain.firstIndex(of: ".") else { break }
                            domain = domain[domain.index(after: dot)...]
                        }
                    }
                    bySenders[fact.people] = senders
                }
            }
            var member: UInt64 = 0
            var home: Int?
            let yours = fact.replied || fact.starred || mine.map { fact.people.contains("@" + $0 + "|") } == true
            for (n, rule) in rules.enumerated() where !rule.empty {
                let bit: UInt64 = 1 << UInt64(n)
                if rule.guarded, yours { continue }
                if rule.people, senders & bit == 0, recipients[n]?.contains(fact.id) != true { continue }
                if !rule.kinds.isEmpty, !(fact.kind.map { rule.kinds.contains($0.rawValue) } ?? false),
                   invited[n]?.contains(fact.id) != true { continue }
                if let asked = asked[n], !asked.contains(fact.id) { continue }
                member |= bit
                if home == nil, rule.mode != .also { home = n }
            }
            if member != 0 {
                placed.member[fact.id] = member
                placed.members[index] = member
            }
            if let home {
                placed.home[fact.id] = home
                placed.homes[index] = Int8(home)
            }
        }
        return placed
    }

    /// One thread as it stands now, its store asked for it alone: after an
    /// act, whether its row still stands in the list.
    func place(_ thread: MailThread, in store: MailStore, now: Date = MailClock.now) -> (member: UInt64, home: Int?) {
        guard !rules.isEmpty else { return (0, nil) }
        let snoozed = store.snoozes().contains { $0.thread == thread.id }
        let sensed = store.sensed(thread.id)
        let facts = MailSplit.Facts(id: thread.id, last: thread.last, inbox: thread.labels.contains("INBOX"), bulk: thread.bulk,
                                    category: !thread.labels.isDisjoint(with: MailSplit.categories),
                                    gone: !thread.labels.isDisjoint(with: ["TRASH", "SPAM"]) && !thread.labels.contains("INBOX"),
                                    lastIsMine: thread.lastIsMine, doneWaiting: thread.doneWaiting, kind: sensed?.kind,
                                    snoozed: snoozed, muted: thread.muted, unread: thread.unread, starred: thread.labels.contains("STARRED"),
                                    replied: thread.labels.contains("SENT"), fired: thread.followup?.fired != nil, people: store.people(of: thread.id),
                                    sensed: sensed != nil, needs: sensed?.needs ?? false, due: sensed?.due != nil)
        let placed = place([facts], me: store.me, answers: answers(store, among: [thread.id], now: now), now: now)
        return (placed.member[thread.id] ?? 0, placed.home[thread.id])
    }

    /// Whether a thread placed so stands in a split's own list: the split
    /// that takes it, or one that shows it beside Needs you.
    func shows(_ index: Int, member: UInt64, home: Int?) -> Bool {
        rules.indices.contains(index) && (rules[index].mode == .also ? member & (1 << UInt64(index)) != 0 : home == index)
    }
}

/// What each store's threads are placed as, kept while its facts are the
/// same reading and the splits the same; each rule's answers kept while the
/// mail is as it was (whom mail went to while no mail came or went, words
/// and searches while no mail came or was given its words, an ask of labels
/// while the facts are the same). One gone stale is asked again off the main
/// thread, the one before standing until it is in: a moment behind the
/// mail, never a key's wait. One never asked is asked at once, so a split
/// made is whole when it shows.
@MainActor
final class MailSplitCache {
    static let shared = MailSplitCache()

    private struct Kept {
        let stamp: Int
        let sort: MailSplitSort
        let placed: MailSplitSort.Placed
    }
    /// A rule's answers in a store, and how far the mail was when asked.
    private struct Answered {
        var at: String
        var answer: MailSplitSort.Answer
    }
    private var kept: [ObjectIdentifier: Kept] = [:]
    private var answered: [ObjectIdentifier: [String: Answered]] = [:]
    /// Answers being asked again, by store and rule.
    private var asking: Set<String> = []

    /// A store's threads as the splits place them.
    func placed(_ store: MailStore, facts: [MailSplit.Facts], stamp: Int, content: Int, arrivals: Int, sort: MailSplitSort,
                now: Date = MailClock.now) -> MailSplitSort.Placed {
        guard !sort.rules.isEmpty else { return MailSplitSort.Placed() }
        let key = ObjectIdentifier(store)
        if let was = kept[key], was.stamp == stamp, was.sort == sort { return was.placed }
        var answers = MailSplitSort.Answers()
        var mine = answered[key] ?? [:]
        for rule in sort.rules {
            guard rule.answered else {
                answers.each.append(MailSplitSort.Answer())
                continue
            }
            // Whom mail went to moves with mail come or gone; words and
            // invitations with a body fetched too; an ask of labels with
            // the facts as well.
            let at = (rule.asks.isEmpty && !rule.invites ? "\(arrivals)" : "\(content)") + (rule.labeled ? ".\(stamp)" : "")
            let one: Answered
            if let was = mine[rule.key] {
                one = was
                if was.at != at { refresh(store, rule, at: at, now: now) }
            } else {
                one = Answered(at: at, answer: MailSplitSort.answer(rule, in: store, among: nil, now: now))
                mine[rule.key] = one
            }
            answers.each.append(one.answer)
        }
        answered[key] = mine
        let placed = sort.place(facts, me: store.me, answers: answers, now: now)
        kept[key] = Kept(stamp: stamp, sort: sort, placed: placed)
        return placed
    }

    /// A rule's answers asked again off the main thread; once in, the
    /// placing goes, and what shows mail reads again (MailCenter.touch).
    private func refresh(_ store: MailStore, _ rule: MailSplitSort.Rule, at: String, now: Date) {
        let key = ObjectIdentifier(store)
        let id = "\(UInt(bitPattern: key.hashValue))|" + rule.key
        guard asking.insert(id).inserted else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            let asked = MailSplitSort.answer(rule, in: store, among: nil, now: now)
            await MainActor.run {
                guard let self else { return }
                self.asking.remove(id)
                // Gone meanwhile (its account): nothing kept of it.
                guard MailCenter.shared.engines.values.contains(where: { $0.store === store }) else { return }
                self.answered[key, default: [:]][rule.key] = Answered(at: at, answer: asked)
                self.kept[key] = nil
                MailCenter.shared.touch()
            }
        }
    }

    /// A store let go (an account gone): nothing kept of it.
    func forget(_ store: MailStore) {
        kept[ObjectIdentifier(store)] = nil
        answered[ObjectIdentifier(store)] = nil
    }
}

// MARK: - skipping the inbox

/// Skip the inbox: mail that comes into a split that skips the inbox is
/// archived as it comes, through ops (MailOps.archive), and kept in
/// `skipped` against the mail it came with, so each arrival is archived
/// once whatever is done with it after, and said on the new tab ("12
/// newsletters archived today"). Never mail from people you have written
/// to or from your own domain, nor a thread you wrote in or starred.
enum MailSkip {
    /// What one look archived: its ops, for ⌘Z, and the threads.
    struct Skipped: Sendable {
        var acted: MailOps.Acted
        var threads: [String]
    }

    /// After a sync brought mail, before anything says it came: the
    /// arrivals in a split that skips the inbox, archived. An arrival is a
    /// thread's newest mail from someone else, come since the last look
    /// (an hour's room for mail Gmail dates late), never one looked at
    /// before. Kinds as the rules read the mail that came, where MailSense
    /// hasn't yet; it keeps them after.
    static func run(_ store: MailStore, sort: MailSplitSort, now: Date = MailClock.now) -> Skipped? {
        guard let since = sort.rules.filter({ $0.mode == .skip }).compactMap(\.since).min() else { return nil }
        let looked = store.value("skip-looked").flatMap(Double.init).map { Date(timeIntervalSince1970: $0 - 3600) } ?? since
        store.set("skip-looked", String(now.timeIntervalSince1970))
        let earliest = max(since, looked)
        let came = store.facts(now: now).filter { $0.inbox && !$0.snoozed && !$0.muted && !$0.gone && !$0.lastIsMine && $0.last > earliest }
        guard !came.isEmpty else { return nil }
        let me = store.me
        let handled = store.skippedMessages(came.map(\.id))
        let sensed = store.sensed(came.map(\.id))
        var candidates: [MailSplit.Facts] = []
        var arrived: [String: String] = [:]
        for var fact in came {
            guard let last = store.lastFromOthers(fact.id), handled[fact.id] != last else { continue }
            if sensed[fact.id]?.message != last, let thread = store.thread(fact.id),
               let read = MailSense.rules(thread, messages: store.messages(thread: fact.id), me: me, now: now) {
                fact.kind = read.kind
            }
            candidates.append(fact)
            arrived[fact.id] = last
        }
        guard !candidates.isEmpty else { return nil }
        let placed = sort.place(candidates, me: me, answers: sort.answers(store, among: candidates.map(\.id), now: now), now: now)
        let mine = MailSplits.domain(of: me)
        var out: [(thread: String, message: String, split: String)] = []
        for fact in candidates {
            // Its newest mail, the one that came, is from someone else (`lastIsMine` false): its time is the thread's.
            guard let home = placed.home[fact.id], sort.rules[home].mode == .skip, fact.last > sort.rules[home].since ?? .distantFuture,
                  let id = arrived[fact.id], let mail = store.message(id) else { continue }
            if keeps(fact, sender: mail.from.address, domain: mine, wroteTo: store.wroteTo) { continue }
            out.append((fact.id, id, sort.rules[home].id))
        }
        guard !out.isEmpty else { return nil }
        let threads = out.map(\.thread)
        let acted = MailOps.archive(threads, inbox: true, in: store)
        store.skip(out, at: now)
        return Skipped(acted: acted, threads: threads)
    }

    /// Superhuman's guard: what Skip the inbox leaves where it is, however
    /// the split's rule reads it. A thread you wrote in or starred, mail
    /// from your own domain or under it, from someone you have written to.
    static func keeps(_ fact: MailSplit.Facts, sender: String, domain mine: String?, wroteTo: (String) -> Bool) -> Bool {
        if fact.replied || fact.starred { return true }
        let sender = sender.lowercased()
        if let mine, sender.hasSuffix("@" + mine) || sender.hasSuffix("." + mine) { return true }
        return wroteTo(sender)
    }

    /// The start of the day mail's clock is in: "today" for the new tab's line.
    static func today(_ now: Date = MailClock.now) -> Date { Calendar.current.startOfDay(for: now) }
}

// MARK: - the column's drag

/// A row of the column dragged over another: the order follows it as it
/// goes, kept once it lands (MailList.move). Held still, the rows change
/// places at once.
struct MailColumnDrop: DropDelegate {
    let id: String
    let list: MailList

    func dropEntered(info: DropInfo) {
        guard let dragged = list.dragging, dragged != id else { return }
        withAnimation(MailDesk.still ? nil : MailMorph.spring(MailMorph.quick)) { list.move(dragged, to: id) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        list.dragging = nil
        return true
    }
}

// MARK: - Settings › Mail

/// Settings › Mail's splits: each in the column's order, what it gathers,
/// where its mail goes (off, for a built-in one) and whether it says so in
/// a notification, in the tables' language (MenuCell); Hide empty splits
/// under them. One of yours goes on a right click.
struct MailSplitSettings: View {
    private var list = MailList.shared

    var body: some View {
        Section {
            ForEach(list.ordered.filter { !$0.hidden }) { split in
                MailSplitRow(split: split, list: list)
                    .settingsAnchor("mail-split:" + split.id)
            }
            SettingsRow("Hide empty splits", detail: "Hide empty splits from the sidebar and Tab navigation.") {
                Toggle("Hide empty splits", isOn: Binding(get: { list.hideEmpty }, set: { list.hideEmpty = $0 }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .settingsAnchor("mail-splits-hide")
        } header: {
            Text("Splits")
                .settingsAnchor("mail-splits")
        } footer: {
            SettingsNote("Splits group mail by sender or category on this Mac. Drag to reorder; Tab follows that order. Skips the inbox archives new mail, excluding previous contacts and your domain. Right-click a custom split to remove it.")
        }
    }
}

/// One split: its mark, its name, what it gathers; where its mail goes,
/// and whether it notifies.
private struct MailSplitRow: View {
    let split: MailList.Split
    let list: MailList

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Symbol(split.icon ?? "magnifyingglass", size: 12)
                    .foregroundStyle(split.on ? Palette.ink : Palette.muted)
                    .frame(width: 16)
                Text(split.title)
                    .lineLimit(1)
                Text(MailSplits.gathers(split))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            MenuCell(title: "Its mail", options: modes, selection: Binding(
                get: { split.on ? split.mode.rawValue : "off" },
                set: { list.setMode($0, for: split.id) }
            ))
            MenuCell(title: "Notifications", options: [("Notifies", true), ("Quiet", false)], selection: Binding(
                get: { split.notifies },
                set: { on in list.change(split.id) { $0.notify = on } }
            ))
            .disabled(!split.on || split.mode == .skip)
            .opacity(!split.on || split.mode == .skip ? 0.5 : 1)
        }
        .contentShape(Rectangle())
        .contextMenu {
            if !split.builtIn { Button("Remove Split") { list.dropList(split.id) } }
        }
    }

    /// Off, for a built-in split; then where its mail goes.
    private var modes: [(title: String, value: String)] {
        (split.builtIn ? [("Off", "off")] : []) + MailList.Split.Mode.allCases.map { ($0.title, $0.rawValue) }
    }
}
