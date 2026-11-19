import AppKit
import MailCore

// Purchases (docs/purchases.md): what you pay for and have coming, read from
// the mail kept on this Mac (MailPurchases reads each receipt, renewal
// notice and shipping mail), beside what only the browser knows: when you
// last opened the site you pay. Three lists in ⌘T's Purchases place
// (subscriptions with their monthly total, orders on the way, receipts),
// one row in Now the day before a subscription you haven't opened lately
// renews, and an agent's `purchases` tool. Nothing here pays or cancels:
// Do It hands the row to the agent, which stops at the merchant's last
// button for the person's yes (AgentPermit's commits).

@MainActor
@Observable final class Purchases {
    static let shared = Purchases()

    struct Item: Identifiable, Equatable {
        let purchase: MailPurchase
        let account: String
        /// The last visit to its site, here or in this Mac's other browsers.
        var opened: Date?

        var id: String { purchase.kind.rawValue + "." + account + "|" + purchase.message }

        /// Its mail, as mail opens it.
        var thread: URL? { URL(string: "yab://mail#thread=" + account + "|" + purchase.thread) }

        var site: URL? { purchase.host.flatMap { URL(string: "https://" + $0) } }

        /// "$15 a month", "$180 a year", "$2,499".
        var price: String? {
            guard let amount = purchase.amount, let currency = purchase.currency else { return nil }
            let said = MailPurchases.said(amount, currency)
            switch purchase.period {
            case .week?: return said + " a week"
            case .month?: return said + " a month"
            case .year?: return said + " a year"
            case nil: return said
            }
        }

        /// "Visa 4411".
        var card: String? {
            guard let last4 = purchase.card else { return nil }
            return [purchase.brand, last4].compactMap { $0 }.joined(separator: " ")
        }

        /// Days since its site was last opened; nil when it was never seen
        /// in the window History reads, or it has no site.
        func idle(now: Date) -> Int? {
            guard purchase.host != nil else { return nil }
            guard let opened else { return Purchases.window }
            return max(0, Int(now.timeIntervalSince(opened) / 86_400))
        }

        /// Paid for and not opened in a month.
        func unused(now: Date) -> Bool { (idle(now: now) ?? 0) >= Purchases.unusedDays }
    }

    private(set) var subscriptions: [Item] = []
    private(set) var orders: [Item] = []
    private(set) var receipts: [Item] = []
    /// Counts every change, for what is made from it (Places' memo).
    @ObservationIgnored private(set) var version = 0
    @ObservationIgnored private var read: Date?
    @ObservationIgnored private var reading = false
    /// What each mail read as, by `Purchases.key`: a mail's words don't
    /// change, so a refresh reads only mail it hasn't read before. Every
    /// candidate read again every ten minutes was the owner's whole 400
    /// days, 8,000 mails, and the run took longer than the ten minutes it
    /// waited, so one core never rested (2026-10-25).
    @ObservationIgnored private var known = Known()

    struct Known: Sendable, Codable {
        /// The rules that read them (MailPurchases.rules): other rules may
        /// read mail otherwise. Not the build: each update, and on a Nightly
        /// that is every few hours, threw all of this away, and a run cut
        /// short by a quit saved nothing, so the same mail was read for ever
        /// (2026-10-31: 56 to 120% of a core seven minutes after launch).
        var rules = MailPurchases.rules
        var found: [String: MailPurchase] = [:]
        var none: Set<String> = []
        var count: Int { found.count + none.count }
    }

    /// `known` kept between launches, so a launch reads only the mail that
    /// came since the last one: reading all of it again was minutes of a
    /// core at every launch on a large mailbox.
    nonisolated static var knownFile: URL { Store.file("purchases-read.json") }

    nonisolated static func loadKnown() -> Known {
        guard let data = try? Data(contentsOf: knownFile),
              let known = try? JSONDecoder().decode(Known.self, from: data), known.rules == MailPurchases.rules else { return Known() }
        return known
    }

    nonisolated static func saveKnown(_ known: Known) {
        guard let data = try? JSONEncoder().encode(known) else { return }
        try? data.write(to: knownFile, options: .atomic)
    }
    @ObservationIgnored private var loaded = false

    /// A mail as it was read: its id and account, how much of it was there
    /// (the snippet first, its words when they arrive, and gone again when
    /// old bodies are let go), and whether it went to the bin or spam since.
    nonisolated static func key(_ head: MailPurchaseHead, account: String) -> String {
        let gone = !head.labels.isDisjoint(with: ["SENT", "SPAM", "TRASH", "DRAFT"])
        return account + "|" + head.id + "|" + (head.body ? "1" : "0") + (head.html ? "1" : "0") + "|" + String(head.snippet) + (gone ? "|gone" : "")
    }

    /// How far back mail is read for purchases.
    static let days: Double = 400
    /// How far back History is asked when each site was last opened.
    nonisolated static let window = 365
    /// Not opened in this many days: unused.
    nonisolated static let unusedDays = 30
    /// The receipts listed.
    static let receiptsKept = 400
    /// Mails taken from the store at a time: a pass never holds more bodies.
    nonisolated static let batch = 20
    /// Unread mail between saves, so a quit loses a minute's reading at most.
    nonisolated static let saveEvery = 200
    /// After each batch it rests this many times what the batch took, so a
    /// first reading of 400 days takes a quarter of a core at the very most.
    nonisolated static let restShare = 3.0

    /// Purchases a test world hands over (bench `purchases` seed), with
    /// the last visit of each site; nil reads the mail.
    @ObservationIgnored var testing: [(purchase: MailPurchase, account: String, opened: Date?)]?

    // MARK: - reading

    /// Read the mail again, at most every ten minutes unless asked.
    func refresh(force: Bool = false, now: Date = Date()) {
        if let testing {
            apply(testing.map { Item(purchase: $0.purchase, account: $0.account, opened: $0.opened) }, now: now)
            return
        }
        if reading || (!force && read.map { now.timeIntervalSince($0) < 600 } == true) { return }
        guard MailCenter.shared.connected else {
            if !subscriptions.isEmpty || !orders.isEmpty || !receipts.isEmpty { apply([], now: now) }
            return
        }
        read = now
        reading = true
        let engines = MailCenter.shared.engines.values.map { ($0.account, $0.store) }
        let since = now.addingTimeInterval(-Purchases.days * 86_400)
        let before = known
        let load = !loaded
        loaded = true
        let began = Date()
        DispatchQueue.global(qos: .background).async {
            let before = load ? Purchases.loadKnown() : before
            /// The visits of each site, then the lists.
            func show(_ items: [Item], kept: Known, done: Bool) {
                var all = items
                let hosts = Array(Set(all.compactMap(\.purchase.host)))
                let visits = AgentHistory.lastVisits(to: hosts, days: Purchases.window)
                for index in all.indices { all[index].opened = all[index].purchase.host.flatMap { visits[$0] } }
                DispatchQueue.main.async {
                    self.known = kept
                    if done {
                        self.reading = false
                        // Ten minutes from when this one ended, not began: a
                        // long run is never followed by the next at once.
                        self.read = now.addingTimeInterval(Date().timeIntervalSince(began))
                    }
                    self.apply(all, now: now)
                }
            }
            let (items, kept, fresh) = Purchases.pass(engines, since: since, now: now, before: before) { items, kept in
                Purchases.saveKnown(kept)
                show(items, kept: kept, done: false)
            }
            if fresh > 0 || kept.count != before.count { Purchases.saveKnown(kept) }
            show(items, kept: kept, done: true)
        }
    }

    /// One reading of every account's candidates: what `before` read is
    /// taken as it was, without touching its body; the rest (`fresh`, how
    /// many) read now, a few bodies at a time, resting between batches.
    /// `reached` hears what is known so far before the first batch and
    /// every `saveEvery` mails, so nothing read is lost to a quit and the
    /// lists don't wait for a long first reading. `kept` is what was read
    /// of the mail still there.
    nonisolated static func pass(_ engines: [(String, MailStore)], since: Date, now: Date, before: Known,
                                 rest: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
                                 reached: ([Item], Known) -> Void = { _, _ in }) -> (items: [Item], kept: Known, fresh: Int) {
        var kept = Known()
        var order: [(key: String, account: String)] = []
        var unread: [(store: MailStore, heads: [(key: String, id: String)])] = []
        for (account, store) in engines {
            var waiting: [(key: String, id: String)] = []
            for head in store.purchaseHeads(since: since) {
                let key = Purchases.key(head, account: account)
                order.append((key, account))
                if let found = before.found[key] {
                    kept.found[key] = found
                } else if before.none.contains(key) {
                    kept.none.insert(key)
                } else {
                    waiting.append((key, head.id))
                }
            }
            if !waiting.isEmpty { unread.append((store, waiting)) }
        }
        func items() -> [Item] {
            // Newest first in each account, as the store gave them.
            order.compactMap { one in kept.found[one.key].map { Item(purchase: $0, account: one.account) } }
        }
        if unread.isEmpty { return (items(), kept, 0) }
        reached(items(), kept)
        var fresh = 0
        var saved = 0
        for (store, heads) in unread {
            for start in stride(from: 0, to: heads.count, by: Purchases.batch) {
                let began = DispatchTime.now().uptimeNanoseconds
                let some = heads[start..<min(start + Purchases.batch, heads.count)]
                let keys = Dictionary(some.map { ($0.id, $0.key) }, uniquingKeysWith: { first, _ in first })
                // Each mail in a pool of its own: this thread's isn't drained
                // until the pass ends, and regexes leave plenty in it.
                autoreleasepool {
                    for message in store.messages(ids: some.map(\.id)) {
                        guard let key = keys[message.id] else { continue }
                        autoreleasepool {
                            if let purchase = MailPurchases.read(message, now: now) {
                                kept.found[key] = purchase
                            } else {
                                kept.none.insert(key)
                            }
                            fresh += 1
                        }
                    }
                }
                if fresh - saved >= Purchases.saveEvery {
                    saved = fresh
                    reached(items(), kept)
                }
                rest(Double(DispatchTime.now().uptimeNanoseconds - began) / 1e9 * Purchases.restShare)
            }
        }
        return (items(), kept, fresh)
    }

    private func apply(_ all: [Item], now: Date) {
        let byMessage = Dictionary(all.map { ($0.purchase.message + "|" + $0.purchase.kind.rawValue, $0) }, uniquingKeysWith: { first, _ in first })
        func item(_ purchase: MailPurchase) -> Item {
            let known = byMessage[purchase.message + "|" + purchase.kind.rawValue] ?? all.first { $0.purchase.message == purchase.message }
            return Item(purchase: purchase, account: known?.account ?? "", opened: known?.opened)
        }
        let purchases = all.map(\.purchase)
        subscriptions = MailPurchases.subscriptions(purchases, now: now).map(item).sorted {
            ($0.purchase.canceled ? 1 : 0, -(MailPurchases.monthly($0.purchase) ?? 0)) < ($1.purchase.canceled ? 1 : 0, -(MailPurchases.monthly($1.purchase) ?? 0))
        }
        orders = MailPurchases.onTheWay(purchases, now: now).map(item).sorted { ($0.purchase.arrives ?? .distantFuture) < ($1.purchase.arrives ?? .distantFuture) }
        receipts = Array(all.filter { ($0.purchase.amount != nil && $0.purchase.kind != .order) || $0.purchase.kind == .receipt }
            .sorted { $0.purchase.date > $1.purchase.date }.prefix(Purchases.receiptsKept))
        version += 1
    }

    func item(_ id: String) -> Item? {
        subscriptions.first { $0.id == id } ?? orders.first { $0.id == id } ?? receipts.first { $0.id == id }
    }

    /// What the subscriptions still renewing cost a month, in the currency
    /// most of them are charged in; the others aren't added in.
    var monthly: (value: Double, currency: String, count: Int)? {
        let live = subscriptions.filter { !$0.purchase.canceled }
        let currencies = live.compactMap(\.purchase.currency)
        guard let currency = Dictionary(grouping: currencies, by: { $0 }).max(by: { $0.value.count < $1.value.count })?.key else { return nil }
        let value = live.filter { $0.purchase.currency == currency }.compactMap { MailPurchases.monthly($0.purchase) }.reduce(0, +)
        return (value, currency, live.count)
    }

    /// "$216 a month", or nil with nothing renewing.
    var monthlySaid: String? {
        guard let total = monthly, total.count > 0 else { return nil }
        return MailPurchases.said(total.value, total.currency) + " a month"
    }

    // MARK: - Now's row

    /// A subscription you haven't opened in a month, renewing within a
    /// day and a half: one row, the soonest, the day before. One a
    /// subscription asked not to again until its next year.
    func rows(now: Date) -> [Hint] {
        refresh(now: now)
        let quiet = notAgain
        let soon = subscriptions.filter { one in
            guard !one.purchase.canceled, let renews = one.purchase.renews, let host = one.purchase.host,
                  renews > now, renews.timeIntervalSince(now) < 36 * 3600, one.unused(now: now) else { return false }
            return quiet[host].map { now >= $0 } ?? true
        }.sorted { ($0.purchase.renews ?? now) < ($1.purchase.renews ?? now) }
        return soon.prefix(1).map { Purchases.hint($0, now: now) }
    }

    nonisolated static func hint(_ item: Item, now: Date) -> Hint {
        let p = item.purchase
        let host = p.host ?? ""
        let calendar = Calendar.current
        let next = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        let when = p.renews.map { calendar.isDate($0, inSameDayAs: now) ? "today" : calendar.isDate($0, inSameDayAs: next) ? "tomorrow" : "soon" } ?? "soon"
        let idle = item.idle(now: now).map { $0 >= Purchases.window ? "not opened this year" : "not opened in \($0) days" }
        let detail = [[p.title == p.merchant ? nil : p.title, item.price].compactMap { $0 }.joined(separator: ", "), idle ?? ""]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        return Hint(id: "renewal." + host + "." + String(Int((p.renews ?? now).timeIntervalSince1970 / 86_400)), icon: .site(host),
                    title: "\(p.merchant) renews \(when)", detail: detail, url: item.site, due: p.renews, cancel: true,
                    source: .noticed, kind: Noticing.Kind.renewal.rawValue, day: true)
    }

    /// Ask Again Next Year: the merchant's renewals keep quiet until a
    /// month before the next year's charge.
    func askNextYear(_ host: String, now: Date = Date()) {
        var quiet = notAgain
        quiet[host] = now.addingTimeInterval(330 * 86_400)
        Store.settings.set(quiet.mapValues(\.timeIntervalSince1970), forKey: "purchases.notAgain")
        version += 1
    }

    private var notAgain: [String: Date] {
        ((Store.settings.dictionary(forKey: "purchases.notAgain") as? [String: Double]) ?? [:]).mapValues { Date(timeIntervalSince1970: $0) }
    }

    // MARK: - an agent's

    /// The `purchases` tool's answer.
    func describe(kind: String, query: String, now: Date = Date()) -> String {
        let terms = query.lowercased().split(separator: " ").map(String.init)
        func keeps(_ item: Item) -> Bool {
            let p = item.purchase
            let text = [p.merchant, p.title, p.host ?? "", p.order ?? ""].joined(separator: " ").lowercased()
            return terms.allSatisfy { text.contains($0) }
        }
        let day = DateFormatter()
        day.dateFormat = "MMM d, yyyy"
        day.locale = Locale(identifier: "en_US")
        switch kind {
        case "orders":
            let list = orders.filter(keeps)
            guard !list.isEmpty else { return "Nothing on the way." }
            return list.map { item in
                let p = item.purchase
                var line = "- \(p.title) from \(p.merchant): \(Purchases.status(p) ?? "ordered")"
                if let arrives = p.arrives { line += ", arriving " + day.string(from: arrives) }
                if let tracking = p.tracking { line += " · \(p.carrier ?? "tracking") \(tracking)" }
                if let url = Purchases.tracking(p) { line += " · \(url.absoluteString)" }
                return line + " · mail \(item.account)|\(p.thread)"
            }.joined(separator: "\n")
        case "receipts":
            let list = receipts.filter(keeps).prefix(40)
            guard !list.isEmpty else { return "No receipts found." }
            return list.map { item in
                let p = item.purchase
                return "- \(day.string(from: p.date)) \(p.merchant): \(p.title)" + (item.price.map { ", " + $0 } ?? "")
                    + (item.card.map { ", " + $0 } ?? "") + (p.order.map { ", order \($0)" } ?? "") + " · mail \(item.account)|\(p.thread)"
            }.joined(separator: "\n")
        default:
            let list = subscriptions.filter(keeps)
            guard !list.isEmpty else { return "No subscriptions found in the mail on this Mac." }
            var out = list.map { item in
                let p = item.purchase
                var line = "- \(p.merchant)" + (p.title == p.merchant ? "" : " (\(p.title))") + (item.price.map { ": " + $0 } ?? "")
                if let card = item.card { line += ", " + card }
                if p.canceled { line += ", canceled" + (p.ends.map { ", yours until " + day.string(from: $0) } ?? "") }
                else if let renews = p.renews { line += ", renews " + day.string(from: renews) }
                if let idle = item.idle(now: now) { line += idle >= Purchases.window ? ", site not opened this year" : ", site last opened \(idle) days ago" }
                if let site = p.host { line += " · \(site)" }
                return line + " · mail \(item.account)|\(p.thread)"
            }.joined(separator: "\n")
            if terms.isEmpty, let total = monthly {
                out = "\(total.count) subscriptions, \(MailPurchases.said(total.value, total.currency)) a month.\n" + out
            }
            return out
        }
    }

    // MARK: - words

    /// Whether a question in the field is about money spent or things
    /// coming: Ask is then told what Purchases knows.
    nonisolated static func asks(_ words: String) -> Bool {
        words.range(of: #"subscri|spend|paying|pay for|renew|my orders?\b|package|parcel|deliver|arriv|tracking|receipt|bought|purchase|подписк|трач|плач|заказ|посылк|доставк|abonnement|bestell"#,
                    options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// "Out for delivery", "Shipped", "Delivered".
    nonisolated static func status(_ p: MailPurchase) -> String? {
        switch p.shipping {
        case .ordered?: return "Ordered"
        case .shipped?: return "Shipped"
        case .outForDelivery?: return "Out for delivery"
        case .delivered?: return "Delivered"
        case nil: return nil
        }
    }

    /// The carrier's own page for a tracking number.
    nonisolated static func tracking(_ p: MailPurchase) -> URL? {
        guard let number = p.tracking?.replacingOccurrences(of: " ", with: ""),
              let safe = number.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
        switch (p.carrier ?? "").lowercased() {
        case "ups": return URL(string: "https://www.ups.com/track?tracknum=" + safe)
        case "usps": return URL(string: "https://tools.usps.com/go/TrackConfirmAction?tLabels=" + safe)
        case "fedex": return URL(string: "https://www.fedex.com/fedextrack/?trknbr=" + safe)
        case "dhl": return URL(string: "https://www.dhl.com/global-en/home/tracking.html?tracking-id=" + safe)
        default: return nil
        }
    }
}
