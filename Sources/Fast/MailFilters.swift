import AppKit
import Combine
import SwiftUI

// A split's rules as filters (docs/mail.md, Splits):
// under its name a pill for each kind of rule it has. From, the people and
// sites whose mail it gathers; To, whom you wrote to; Kind, what this Mac
// reads the mail as; Mentions, its words; Search, a Gmail search. A click
// opens the pill over the list: what it holds, ticked, and more from your
// mail under it, each with what it would bring now, counted off the main
// thread. + Add Filter offers the kinds, and For now what ⇧U, ⇧S and ⇧R
// narrow the list to, kept nowhere: that one stands in the row too, grey,
// with a dot, until esc. Adding from a mail is ⌘K's (Add to Split…, New
// Split from This Mail…); a new split starts in the library
// (MailSplitLibrary).

/// A kind of rule, a pill of its own.
enum MailFilter: String, CaseIterable, Identifiable {
    case from, to, kind, words, search

    var id: String { rawValue }

    /// The rules it holds (MailRule.kinds).
    var kinds: Set<String> {
        switch self {
        case .from: return ["with", "from", "team"]
        case .to: return ["to"]
        case .kind: return ["kind"]
        case .words: return ["words"]
        case .search: return ["search"]
        }
    }

    static func of(_ rule: MailRule) -> MailFilter? { allCases.first { $0.kinds.contains(rule.kind) } }

    var title: String {
        switch self {
        case .from: return "From"
        case .to: return "To"
        case .kind: return "Kind"
        case .words: return "Mentions"
        case .search: return "Search"
        }
    }

    /// As + Add Filter offers it, and what it holds.
    var offered: (title: String, detail: String) {
        switch self {
        case .from: return ("From", "people and sites")
        case .to: return ("To", "your mail to them")
        case .kind: return ("Kind of mail", "bills, invitations\u{2026}")
        case .words: return ("Mentions", "words in the mail")
        case .search: return ("Gmail search", "has:, older_than:\u{2026}")
        }
    }

    var symbol: String {
        switch self {
        case .from: return "person"
        case .to: return "paperplane"
        case .kind: return "tag"
        case .words: return "magnifyingglass"
        case .search: return "envelope"
        }
    }

    /// How its values join, as the sort reads them (MailSplitSort.place):
    /// people and kinds any of, words and searches all of.
    var joins: String { self == .words || self == .search ? "all of" : "any of" }

    /// From and To are one group: a thread from either is in.
    var people: Bool { self == .from || self == .to }

    /// What its field asks before anything is in it.
    var asks: String {
        switch self {
        case .from: return "Search people and sites"
        case .to: return "Search people"
        case .kind: return "Search kinds"
        case .words: return "Add a word"
        case .search: return "Add a Gmail search"
        }
    }

    /// The symbol a kind of mail wears.
    static func symbol(ofKind raw: String) -> String {
        switch raw {
        case "person": return "person"
        case "code": return "key"
        case "invoice": return "creditcard"
        case "meeting": return "calendar"
        case "shipping": return "bag"
        case "list": return "doc.text"
        case "promotion": return "tag"
        default: return "envelope"
        }
    }
}

extension MailRule {
    /// As a pill and its rows say it: a person by their name, a site, a
    /// kind's name, the words.
    @MainActor var named: String {
        switch kind {
        case "with", "from", "to":
            guard value.contains("@") else { return value }
            let name = MailDesk.shared.name(of: value)
            return name.isEmpty ? value : name
        case "team": return "Your team"
        case "kind": return MailSplits.kindName(value)
        default: return value
        }
    }

    /// A person's address, under their name where it isn't the name.
    @MainActor var address: String {
        ["with", "from", "to"].contains(kind) && value.contains("@") && named != value ? value : ""
    }
}

// MARK: - counts

/// What rules would gather now, counted off the main thread: one pass of
/// the splits' sort over all of them a store, as a split's own count is
/// made (MailSplitCache), never a wait on a key.
@MainActor
@Observable final class MailFilterCounts {
    static let shared = MailFilterCounts()

    struct Count: Equatable, Sendable {
        /// Threads it gathers.
        var all = 0
        /// Of them, those the split doesn't gather now.
        var added = 0
    }

    /// By the account, the split's line now and the line asked.
    @ObservationIgnored private(set) var known: [String: Count] = [:]
    /// Bumped as counts come in.
    private(set) var version = 0
    @ObservationIgnored private var asking: Set<String> = []
    private(set) var epoch = 0
    @ObservationIgnored private var watching: Set<AnyCancellable> = []

    private init() {
        // Published values arrive before the store/account is replaced.
        // Invalidate on the next turn, when a new request can see it.
        MailCenter.shared.observed(\.changed).dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.forget() }
        }.store(in: &watching)
        MailList.shared.observed(\.account).removeDuplicates().dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.forget() }
        }.store(in: &watching)
    }

    private static func key(_ line: String, base: String, account: String) -> String {
        account + "\u{1F}" + base + "\u{1F}" + line
    }

    func count(_ line: String, base: String, account: String) -> Count? { _ = version; return known[Self.key(line, base: base, account: account)] }

    /// Lines to count beside the split's own (`base`): those known or on
    /// their way left out.
    func ask(_ lines: [String], base: String, account: String) {
        var wanted: [String] = []
        for line in lines where !line.isEmpty && !wanted.contains(line) {
            let key = Self.key(line, base: base, account: account)
            if known[key] == nil, !asking.contains(key) { wanted.append(line) }
        }
        guard !wanted.isEmpty else { return }
        let keys = wanted.map { Self.key($0, base: base, account: account) }
        asking.formUnion(keys)
        let rules = Self.rules([base] + wanted)
        let stores = MailCenter.shared.showing(account).map(\.store)
        let now = MailClock.now
        let generation = epoch
        Task.detached(priority: .userInitiated) {
            let counted = MailFilterCounts.counted(rules, in: stores, now: now)
            await MainActor.run {
                let shared = MailFilterCounts.shared
                guard shared.epoch == generation else { return }
                for (key, count) in zip(keys, counted) { shared.known[key] = count }
                shared.asking.subtract(keys)
                shared.version += 1
                if let browser = MailDesk.shared.browser, browser.query.place == .mail,
                   browser.query.stock.mail?.mode == .splitRule {
                    browser.query.stock.version += 1
                    browser.replaceTyped(browser.typed)
                }
            }
        }
    }

    /// Everything counted goes: a menu opens again on mail since moved.
    func forget() {
        epoch += 1
        known = [:]
        asking = []
        version += 1
        if let browser = MailDesk.shared.browser, browser.query.place == .mail,
           browser.query.stock.mail?.mode == .splitRule {
            browser.query.stock.version += 1
            browser.replaceTyped(browser.typed)
        }
    }

    /// Lines as the sort reads them, the first the split's own.
    static func rules(_ lines: [String]) -> [MailSplitSort.Rule] {
        lines.enumerated().map { n, line in MailSplitSort.Rule(MailList.Split(id: "count\(n)", title: "", q: line, mode: .also)) }
    }

    /// Each rule after the first, counted: the threads it gathers, and of
    /// them those the first doesn't. A store a pass, 63 rules at a time,
    /// each store asked once for answers rules share.
    nonisolated static func counted(_ rules: [MailSplitSort.Rule], in stores: [MailStore], now: Date) -> [Count] {
        guard let base = rules.first else { return [] }
        let asked = Array(rules.dropFirst())
        var out = Array(repeating: Count(), count: asked.count)
        let snapshots = stores.map { (store: $0, facts: $0.facts(now: now), me: $0.me) }
        var at = 0
        while at < asked.count {
            let chunk = Array(asked[at..<min(at + 63, asked.count)])
            let sort = MailSplitSort(rules: [base] + chunk)
            for snapshot in snapshots {
                let store = snapshot.store
                var answered: [String: MailSplitSort.Answer] = [:]
                let answers = MailSplitSort.Answers(each: sort.rules.map { rule in
                    guard rule.answered else { return MailSplitSort.Answer() }
                    if let known = answered[rule.key] { return known }
                    let one = MailSplitSort.answer(rule, in: store, among: nil, now: now)
                    answered[rule.key] = one
                    return one
                })
                let placed = sort.place(snapshot.facts, me: snapshot.me, answers: answers, now: now)
                for bits in placed.members where bits > 1 {
                    let held = bits & 1 != 0
                    for n in chunk.indices where bits & (1 << UInt64(n + 1)) != 0 {
                        out[at + n].all += 1
                        if !held { out[at + n].added += 1 }
                    }
                }
            }
            at += chunk.count
        }
        return out
    }
}

/// Suggestions from the chosen account, rebuilt off the main thread when mail changes.
@MainActor
@Observable final class MailFilterContacts {
    static let shared = MailFilterContacts()
    private(set) var version = 0
    @ObservationIgnored private var account = ""
    @ObservationIgnored private var known: [MailDesk.Contact] = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var stale = true
    @ObservationIgnored private var watching: Set<AnyCancellable> = []

    private init() {
        MailCenter.shared.observed(\.changed).dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.invalidate() }
        }.store(in: &watching)
        MailList.shared.observed(\.account).removeDuplicates().dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.invalidate() }
        }.store(in: &watching)
    }

    var people: [MailDesk.Contact] {
        if stale || account != MailList.shared.account { read() }
        return known
    }

    private func invalidate() {
        generation += 1
        stale = true
        if account != MailList.shared.account { known = [] }
        // Syncs and archive keys need no suggestions while their menu is closed.
        if MailFilterMenu.shared.open == .filter(.from) || MailFilterMenu.shared.open == .filter(.to) { read() }
    }

    private func read() {
        stale = false
        generation += 1
        let generation = generation
        let account = MailList.shared.account
        if self.account != account { known = [] }
        self.account = account
        let stores = MailCenter.shared.showing(account).map(\.store.off)
        Task.detached(priority: .utility) {
            let found = MailDesk.contacts(in: stores)
            await MainActor.run {
                let contacts = MailFilterContacts.shared
                guard contacts.generation == generation, MailList.shared.account == account else { return }
                contacts.known = found
                contacts.version += 1
            }
        }
    }
}

// MARK: - the menu

/// A row of a pill's menu, + Add Filter's or For now's.
struct MailFilterRow: Identifiable {
    enum Mark {
        case rule(MailRule)
        case symbol(String)
    }

    enum Does {
        /// A value in or out of the split, the menu staying.
        case tick(MailRule)
        /// Words or a search, added from the field.
        case add(MailRule)
        /// + Add Filter: a kind's menu.
        case pick(MailFilter)
        /// For now: the list narrowed (⇧U, ⇧S, ⇧R); kept as a rule; all of it again.
        case only(MailDesk.Only)
        case keep(MailDesk.Only)
        case whole
    }

    /// What its end says, from the counts (MailFilterCounts): what a value
    /// in it brings under the other filters (or that they leave it out);
    /// what one more would add, or keep of the list; or keys.
    enum Tally {
        case none
        case brings(String, alone: String)
        case adds(String)
        case keeps(String)
        case gathers(String)
        case keys(Shortcut.Action)
        case words(String)
    }

    let id: String
    var section = ""
    let mark: Mark
    let title: String
    var detail = ""
    /// Ticked or not; nil: no box.
    var ticked: Bool?
    /// Can't be ticked off: a split of yours keeps a rule.
    var fixed = false
    var tally: Tally = .none
    let does: Does

    /// The lines its count is asked by.
    var lines: [String] {
        switch tally {
        case .brings(let line, let alone): return [line, alone]
        case .adds(let line), .keeps(let line), .gathers(let line): return [line]
        default: return []
        }
    }
}

/// The menu a pill opens, + Add Filter's, or For now's: one at a time,
/// over the list (MailFilterLayer). ↑ ↓ walk its rows and ↩ takes one
/// (MailDesk.take); esc, a click elsewhere or any other key puts it away.
@MainActor
@Observable final class MailFilterMenu {
    static let shared = MailFilterMenu()

    enum Open: Equatable {
        case filter(MailFilter)
        case picker
        case temp
    }

    private(set) var open: Open?
    /// A kind picked from + Add Filter with nothing in it yet, or whose
    /// last value went while its menu was open: its pill stands, empty,
    /// until the menu goes.
    private(set) var fresh: MailFilter?
    /// The words in its field.
    var typed = "" { didSet { if typed != oldValue { lit = 0 } } }
    /// The row the keys are on.
    var lit = 0
    /// A pill something was just added to (⌘K's Add to Split): it shines once.
    private(set) var shine: (filter: MailFilter?, n: Int) = (nil, 0)
    /// Asks the menu's field for the keyboard.
    private(set) var focus = 0

    @ObservationIgnored lazy var away = ClickAway { [weak self] in self?.close() }
    /// A menu to open once the split it is for is on screen (Build Your Own).
    @ObservationIgnored private var waiting: Open?
    @ObservationIgnored private var watching: AnyCancellable?
    @ObservationIgnored private var contactsWatching: AnyCancellable?
    private var contactsVersion = 0

    private init() {
        // Another list: a menu waiting for it opens, one open for the last
        // goes; once the list is chosen, not while it is being chosen.
        contactsWatching = MailFilterContacts.shared.observed(\.version).dropFirst().sink { [weak self] version in
            DispatchQueue.main.async { self?.contactsVersion = version }
        }
        watching = MailList.shared.observed(\.split).removeDuplicates().dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.arrived() }
        }
    }

    /// Where each menu hangs from (MailFilterAnchors).
    static func anchor(_ open: Open) -> String {
        switch open {
        case .filter(let filter): return "filter:" + filter.rawValue
        case .picker: return "add"
        case .temp: return "temp"
        }
    }

    static func width(_ open: Open) -> CGFloat {
        if case .filter = open { return 360 }
        return 300
    }

    func toggle(_ what: Open) {
        if open == what { close() } else { show(what) }
    }

    func show(_ what: Open) {
        if case .filter(let filter) = what, fresh != filter { fresh = nil }
        if what == .picker || what == .temp { fresh = nil }
        open = what
        typed = ""
        lit = 0
        MailFilterCounts.shared.forget()
        away.watch(true)
        focus += 1
    }

    func close() {
        guard open != nil || fresh != nil else { return }
        open = nil
        fresh = nil
        typed = ""
        lit = 0
        away.watch(false)
    }

    func show(once arrived: Open) { waiting = arrived }

    /// The pills of another split on screen: a menu waiting for it opens;
    /// one open for the split before goes.
    func arrived() {
        if let waiting {
            self.waiting = nil
            show(waiting)
        } else {
            close()
        }
    }

    /// A kind from + Add Filter: its pill, empty until a value is ticked.
    func pick(_ filter: MailFilter) {
        let has = split?.rules.contains { filter.kinds.contains($0.kind) } ?? false
        show(.filter(filter))
        if !has { fresh = filter }
    }

    func shone(_ filter: MailFilter?) { shine = (filter, shine.n + 1) }

    /// The split on screen: the one being made, or one in the column.
    var split: MailList.Split? {
        let list = MailList.shared
        if list.split == "draft" { return list.draft }
        return list.split(list.split)
    }

    var drafting: Bool { MailList.shared.split == "draft" && MailList.shared.draft != nil }

    // MARK: keys

    func move(_ by: Int) {
        let count = rows().count
        guard count > 0 else { return }
        lit = (lit + by + count) % count
    }

    /// ↩: the row the keys are on.
    func take() {
        let rows = rows()
        guard rows.indices.contains(lit) else { return }
        take(rows[lit])
    }

    /// ⌫ in the empty field: the last value in it goes.
    func dropLast() {
        guard case .filter(let filter) = open, let split else { return }
        if filter == .words {
            dropWord(split.rules.filter { $0.kind == "words" }.flatMap { $0.value.split(separator: " ").map(String.init) }.last ?? "")
            return
        }
        guard let last = split.rules.last(where: { filter.kinds.contains($0.kind) }), !fixed(last, in: split) else { return }
        remove(last, from: filter)
    }

    // MARK: rows

    func rows() -> [MailFilterRow] {
        guard let open, let split else { return [] }
        switch open {
        case .filter(let filter): return rows(filter, split)
        case .picker: return pickerRows(split)
        case .temp: return tempRows(split)
        }
    }

    private func rows(_ filter: MailFilter, _ split: MailList.Split) -> [MailFilterRow] {
        let needle = typed.trimmingCharacters(in: .whitespaces).lowercased()
        let held = split.rules.filter { filter.kinds.contains($0.kind) }
        let line = { (rules: [MailRule]) in MailRule.line(rules) }
        // One more value: widening its group, narrowing the split, or all of a new one.
        let more = { (rule: MailRule) -> MailFilterRow.Tally in
            if split.rules.isEmpty { return .gathers(line([rule])) }
            return self.widens(filter, split) ? .adds(line(split.rules + [rule])) : .keeps(line(split.rules + [rule]))
        }
        switch filter {
        case .words, .search:
            guard !needle.isEmpty else { return [] }
            let words = typed.trimmingCharacters(in: .whitespaces)
            let rule = MailRule(kind: filter == .words ? "words" : "search", value: words)
            let title = (filter == .words ? "Mentions" : "Search") + " \u{201C}\(words)\u{201D}"
            return [MailFilterRow(id: "add", mark: .symbol(filter.symbol), title: title, tally: more(rule), does: .add(rule))]
        case .from, .to, .kind:
            // What it holds, under the other filters: the people group's
            // rest stands apart from a person's own count.
            let others = split.rules.filter { rule in
                guard let of = MailFilter.of(rule) else { return true }
                return filter.people ? !of.people : of != filter
            }
            let matches = { (rule: MailRule) in
                needle.isEmpty || rule.named.lowercased().split(separator: " ").contains { $0.hasPrefix(needle) }
                    || rule.named.lowercased().hasPrefix(needle) || rule.value.lowercased().hasPrefix(needle)
            }
            var out: [MailFilterRow] = []
            let inSplit = "In " + (split.title.isEmpty ? "this split" : split.title)
            for rule in held.filter(matches) {
                out.append(MailFilterRow(id: "on." + rule.kind + rule.value, section: inSplit, mark: .rule(rule), title: rule.named,
                                         detail: rule.address, ticked: true, fixed: fixed(rule, in: split),
                                         tally: .brings(line(others + [rule]), alone: line([rule])), does: .tick(rule)))
            }
            let taken = Set(split.rules.map { $0.value.lowercased() })
            var offered: [MailRule] = []
            if filter == .kind {
                offered = MailSplits.kinds.filter { !taken.contains($0) }.map { MailRule(kind: "kind", value: $0) }.filter(matches)
            } else {
                let contacts = MailFilterContacts.shared.people.filter { !taken.contains($0.address) }
                let sites = Set(held.filter { $0.kind == "from" && !$0.value.contains("@") }.map(\.value))
                let people = contacts.filter { contact in
                    (needle.isEmpty || contact.address.hasPrefix(needle) || contact.name.lowercased().hasPrefix(needle)
                        || contact.name.lowercased().split(separator: " ").contains { $0.hasPrefix(needle) })
                        && !sites.contains(where: { contact.address.hasSuffix("@" + $0) || contact.address.hasSuffix("." + $0) })
                }
                offered = people.prefix(needle.isEmpty ? 3 : 5).map { MailRule(kind: filter == .to ? "to" : "with", value: $0.address) }
                if filter == .from {
                    let common: Set<String> = ["gmail.com", "googlemail.com", "icloud.com", "me.com", "outlook.com", "hotmail.com",
                                               "yahoo.com", "proton.me", "protonmail.com", "hey.com", "live.com", "aol.com"]
                    let own = Set(MailCenter.shared.showing(MailList.shared.account)
                        .compactMap { $0.store.me.split(separator: "@").last.map(String.init) })
                    var domains: [String: Int] = [:]
                    for contact in contacts {
                        guard let domain = contact.address.split(separator: "@").last.map(String.init),
                              !common.contains(domain), !own.contains(domain), !taken.contains(domain),
                              needle.isEmpty || domain.hasPrefix(needle) else { continue }
                        domains[domain, default: 0] += contact.threads
                    }
                    let sorted = domains.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                    offered += sorted.prefix(needle.isEmpty ? 2 : 3).map { MailRule(kind: "from", value: $0.key) }
                }
                // An address or a site typed as it is.
                if !needle.contains(" "), needle.contains("."), !taken.contains(needle), !offered.contains(where: { $0.value == needle }),
                   filter == .from || needle.contains("@") {
                    offered.append(MailRule(kind: needle.contains("@") ? (filter == .to ? "to" : "with") : "from", value: needle))
                }
            }
            let section = filter == .kind ? (held.isEmpty ? "Kinds, as this Mac reads mail" : "More kinds")
                : needle.isEmpty ? "More from your mail" : "People and sites"
            for rule in offered {
                out.append(MailFilterRow(id: "off." + rule.kind + rule.value, section: section, mark: .rule(rule), title: rule.named,
                                         detail: rule.address, ticked: false, tally: more(rule), does: .tick(rule)))
            }
            return out
        }
    }

    private func pickerRows(_ split: MailList.Split) -> [MailFilterRow] {
        let needle = typed.trimmingCharacters(in: .whitespaces).lowercased()
        var out: [MailFilterRow] = []
        for filter in MailFilter.allCases {
            let offered = filter.offered
            guard needle.isEmpty || offered.title.lowercased().contains(needle) || filter.title.lowercased().hasPrefix(needle) else { continue }
            out.append(MailFilterRow(id: "pick." + filter.rawValue, mark: .symbol(filter.symbol), title: offered.title,
                                     detail: offered.detail, does: .pick(filter)))
        }
        // What the list is narrowed to, for now: not in a split being made.
        guard !drafting else { return out }
        let ways: [(MailDesk.Only, String, String)] = [(.unread, "Unread", "line.3.horizontal.decrease"), (.starred, "Starred", "star"),
                                                      (.unanswered, "No reply from you", "arrow.uturn.backward")]
        for (only, title, symbol) in ways where needle.isEmpty || title.lowercased().contains(needle) {
            out.append(MailFilterRow(id: "only." + only.rawValue, section: "For now, not kept", mark: .symbol(symbol), title: title,
                                     tally: .keys(only.action), does: .only(only)))
        }
        return out
    }

    private func tempRows(_ split: MailList.Split) -> [MailFilterRow] {
        guard let only = MailDesk.shared.only else { return [] }
        var out: [MailFilterRow] = []
        if only != .unanswered {
            out.append(MailFilterRow(id: "keep", mark: .symbol("plus"), title: "Keep in " + split.title, does: .keep(only)))
        }
        out.append(MailFilterRow(id: "whole", mark: .symbol("arrow.uturn.backward"), title: "Show All", tally: .words("esc"), does: .whole))
        return out
    }

    /// One more value of this kind gathers more: its group has one already.
    private func widens(_ filter: MailFilter, _ split: MailList.Split) -> Bool {
        switch filter {
        case .from, .to: return split.rules.contains { MailFilter.of($0)?.people == true }
        case .kind: return split.rules.contains { $0.kind == "kind" }
        case .words, .search: return false
        }
    }

    /// A split of yours keeps one rule at least; VIP and a draft may have none.
    func fixed(_ rule: MailRule, in split: MailList.Split) -> Bool {
        !split.builtIn && !drafting && split.rules.count == 1 && split.rules.first == rule
    }

    // MARK: doing

    func take(_ row: MailFilterRow) {
        guard let split else { return }
        switch row.does {
        case .tick(let rule):
            guard let filter = MailFilter.of(rule) else { return }
            if split.rules.contains(rule) {
                guard !fixed(rule, in: split) else { return }
                remove(rule, from: filter)
            } else {
                add(rule)
            }
            typed = ""
        case .add(let rule):
            add(rule)
            typed = ""
        case .pick(let filter):
            pick(filter)
        case .only(let only):
            close()
            MailDesk.shared.narrow(only)
        case .keep(let only):
            close()
            add(MailRule(kind: "search", value: only == .starred ? "is:starred" : "is:unread"))
            MailDesk.shared.narrow(nil)
        case .whole:
            close()
            MailDesk.shared.narrow(nil)
        }
    }

    /// A word of Mentions out.
    func dropWord(_ word: String) {
        guard !word.isEmpty, let split else { return }
        let held = split.rules.filter { $0.kind == "words" }
        let left = held.flatMap { $0.value.split(separator: " ").map(String.init) }.filter { $0 != word }
        guard !held.isEmpty else { return }
        if left.isEmpty, !split.builtIn, !drafting, split.rules.allSatisfy({ $0.kind == "words" }) { return }
        edit { one in
            var rules = one.rules.filter { $0.kind != "words" }
            if !left.isEmpty { rules.append(MailRule(kind: "words", value: left.joined(separator: " "))) }
            one.q = MailRule.line(rules)
        }
        if left.isEmpty, open == .filter(.words) { fresh = .words }
    }

    func remove(_ rule: MailRule, from filter: MailFilter) {
        guard let split, !fixed(rule, in: split) else { return }
        edit { $0.q = MailRule.line($0.rules.filter { $0 != rule }) }
        // Its pill stays while its menu is open, empty.
        if open == .filter(filter), !(self.split?.rules.contains { filter.kinds.contains($0.kind) } ?? false) { fresh = filter }
    }

    /// Every value of one kind out, from its menu's head.
    func removeAll(_ filter: MailFilter) {
        edit { $0.q = MailRule.line($0.rules.filter { !filter.kinds.contains($0.kind) }) }
        close()
    }

    /// Whether every value of one kind can go: the split keeps a rule, or
    /// may have none.
    func removable(_ filter: MailFilter, _ split: MailList.Split) -> Bool {
        split.builtIn || drafting || split.rules.contains { !filter.kinds.contains($0.kind) }
    }

    func add(_ rule: MailRule) {
        let name = rule.named
        edit { one in
            guard !one.rules.contains(rule) else { return }
            if rule.kind == "words" {
                let words = (one.rules.filter { $0.kind == "words" }.map(\.value) + [rule.value]).joined(separator: " ")
                one.q = MailRule.line(one.rules.filter { $0.kind != "words" } + [MailRule(kind: "words", value: words)])
            } else {
                one.q = MailRule.line(one.rules + [rule])
            }
            // A split being made with no name takes the first person's or site's.
            if MailList.shared.split == "draft", one.title.trimmingCharacters(in: .whitespaces).isEmpty, MailFilter.of(rule)?.people == true {
                one.title = name
                if one.group == nil { one.group = "sender" }
            }
        }
        if let filter = MailFilter.of(rule), fresh == filter { fresh = nil }
    }

    private func edit(_ change: (inout MailList.Split) -> Void) {
        let list = MailList.shared
        if drafting { list.editDraft(change) } else { MailDesk.shared.editSplit(list.split, change) }
    }
}

/// Where a menu hangs from: the pills, + Add Filter, For now's pill.
struct MailFilterAnchors: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

// MARK: - the pills

/// A split's filters under its name: a pill for each kind of rule it
/// has, what the list is narrowed to for now, and + Add Filter.
struct MailFilterBar: View {
    let saved: MailList.Split
    let draft: Bool
    var desk: MailDesk
    @Bindable private var menu = MailFilterMenu.shared

    var body: some View {
        MailPills(spacing: 6) {
            ForEach(shown) { filter in
                MailFilterPill(filter: filter, rules: saved.rules.filter { filter.kinds.contains($0.kind) },
                               open: menu.open == .filter(filter), shine: menu.shine.filter == filter ? menu.shine.n : 0)
                    .anchorPreference(key: MailFilterAnchors.self, value: .bounds) { [MailFilterMenu.anchor(.filter(filter)): $0] }
            }
            if let only = desk.only, !draft {
                MailTempPill(only: only, open: menu.open == .temp)
                    .anchorPreference(key: MailFilterAnchors.self, value: .bounds) { [MailFilterMenu.anchor(.temp): $0] }
            }
            MailFilterAdd(open: menu.open == .picker, lit: draft && saved.rules.isEmpty)
                .anchorPreference(key: MailFilterAnchors.self, value: .bounds) { [MailFilterMenu.anchor(.picker): $0] }
        }
    }

    /// The kinds it has, in one order; one being added, empty.
    private var shown: [MailFilter] {
        MailFilter.allCases.filter { filter in menu.fresh == filter || saved.rules.contains { filter.kinds.contains($0.kind) } }
    }
}

/// A kind of rule as a pill: its name, what it holds, a chevron.
private struct MailFilterPill: View {
    let filter: MailFilter
    let rules: [MailRule]
    let open: Bool
    let shine: Int
    @State private var hovering = false
    @State private var shone = false
    @MailStill private var still

    var body: some View {
        Button { MailFilterMenu.shared.toggle(.filter(filter)) } label: {
            HStack(spacing: 6) {
                Symbol(filter.symbol, size: 10)
                if said.isEmpty {
                    Text(filter.title)
                } else {
                    Text(filter.title + ":").foregroundStyle(Color.accentColor.opacity(0.86)) + Text(" " + said).fontWeight(.medium)
                }
                Symbol("chevron.down", size: 7).opacity(0.62)
            }
            .font(.system(size: 12.5))
            .lineLimit(1)
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(Capsule().fill(Color.accentColor.opacity(open || hovering ? 0.15 : 0.075)))
            .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.32), lineWidth: 0.5))
            // Something just came into it from a mail: a ring goes out once.
            .overlay {
                Capsule().strokeBorder(Color.accentColor.opacity(shone ? 0 : 0.45), lineWidth: shone ? 1 : 3)
                    .padding(shone ? -8 : 0)
                    .opacity(shine > 0 ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .background(ClickZone(away: MailFilterMenu.shared.away))
        .onChange(of: shine) { _, _ in
            guard !still else { return }
            shone = false
            withAnimation(.easeOut(duration: 0.9)) { shone = true }
        }
    }

    /// Its values, three at most and how many more: people by their names.
    private var said: String {
        if filter == .words { return rules.flatMap { $0.value.split(separator: " ").map(String.init) }.joined(separator: ", ") }
        let names = rules.map(\.named)
        return names.count <= 3 ? names.joined(separator: ", ") : names.prefix(3).joined(separator: ", ") + " +\(names.count - 3)"
    }
}

/// ⇧U, ⇧S or ⇧R on a split: grey, a dot on it, as a filter not kept.
private struct MailTempPill: View {
    let only: MailDesk.Only
    let open: Bool
    @State private var hovering = false

    var body: some View {
        Button { MailFilterMenu.shared.toggle(.temp) } label: {
            HStack(spacing: 6) {
                Symbol("line.3.horizontal.decrease", size: 10)
                Text(only.name).fontWeight(.medium)
                Symbol("chevron.down", size: 7).opacity(0.62)
            }
            .font(.system(size: 12.5))
            .lineLimit(1)
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(Capsule().fill(open || hovering ? Palette.faint.opacity(0.6) : Palette.wash))
            .overlay(alignment: .topTrailing) {
                Circle().fill(Color(nsColor: .systemOrange))
                    .frame(width: 7, height: 7)
                    .overlay(Circle().strokeBorder(Palette.ground, lineWidth: 1.5))
                    .offset(x: 1, y: -1)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .background(ClickZone(away: MailFilterMenu.shared.away))
        .pointerTip("For now, not kept")
    }
}

/// + Add Filter, at the end of the pills; lit in a split with none yet.
private struct MailFilterAdd: View {
    let open: Bool
    let lit: Bool
    @State private var hovering = false

    var body: some View {
        Button { MailFilterMenu.shared.toggle(.picker) } label: {
            HStack(spacing: 4) {
                Symbol("plus", size: 9, weight: .semibold)
                Text("Add Filter")
            }
            .font(.system(size: 12.5))
            .foregroundStyle(open || lit || hovering ? Palette.ink : Palette.muted)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(Capsule().fill(open || lit || hovering ? Palette.wash : Color.clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .background(ClickZone(away: MailFilterMenu.shared.away))
    }
}

/// Pills in lines, as many on a line as fit. `stretch`: the last, a field,
/// takes what its line leaves.
struct MailPills: Layout {
    var spacing: CGFloat = 6
    var stretch = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for (index, view) in subviews.enumerated() {
            let size = measure(view, last: index == subviews.count - 1)
            if x > 0, x + size.width > width { x = 0; y += line + spacing; line = 0 }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: stretch ? (proposal.width ?? widest) : min(widest, width), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        // Into lines first, each on the middle of its line.
        var lines: [[(index: Int, size: CGSize)]] = [[]]
        var x: CGFloat = 0
        for (index, view) in subviews.enumerated() {
            let size = measure(view, last: index == subviews.count - 1)
            if x > 0, x + size.width > bounds.width { lines.append([]); x = 0 }
            lines[lines.count - 1].append((index, size))
            x += size.width + spacing
        }
        var y = bounds.minY
        for line in lines {
            let height = line.map(\.size.height).max() ?? 0
            var x = bounds.minX
            for (n, one) in line.enumerated() {
                var size = one.size
                if stretch, n == line.count - 1, one.index == subviews.count - 1 { size.width = max(size.width, bounds.maxX - x) }
                subviews[one.index].place(at: CGPoint(x: x, y: y + (height - size.height) / 2),
                                          proposal: ProposedViewSize(width: size.width, height: size.height))
                x += size.width + spacing
            }
            y += height + spacing
        }
    }

    private func measure(_ view: LayoutSubview, last: Bool) -> CGSize {
        stretch && last ? view.sizeThatFits(ProposedViewSize(width: 80, height: nil)) : view.sizeThatFits(.unspecified)
    }
}

// MARK: - the menus

/// The menu that is open, under what it hangs from, held inside the list.
struct MailFilterLayer: View {
    let anchors: [String: Anchor<CGRect>]
    var desk: MailDesk
    var list: MailList
    @Bindable private var menu = MailFilterMenu.shared
    @MailStill private var still
    @State private var menuHeight: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            if let open = menu.open, let anchor = anchors[MailFilterMenu.anchor(open)], let split = menu.split {
                let rect = proxy[anchor]
                let width = min(MailFilterMenu.width(open), max(0, proxy.size.width - 32))
                let x = max(16, min(rect.minX - 6, proxy.size.width - width - 16))
                let below = proxy.size.height - rect.maxY - 22
                let above = rect.minY - 22
                let room = max(0, max(below, above))
                let y = below >= menuHeight ? rect.maxY + 6 : max(16, rect.minY - menuHeight - 6)
                MailFilterPopover(open: open, split: split, account: list.account, room: room, desk: desk)
                    .frame(width: width)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { menuHeight = $0 }
                    .offset(x: x, y: y)
                    .transition(still ? .identity : .opacity.combined(with: .scale(scale: 0.97, anchor: .topLeading)))
            }
        }
        .animation(still ? nil : .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.14), value: menu.open)
    }
}

/// A pill's menu: how its values join, the field with them in it, what it
/// holds ticked and more from your mail, each counted. + Add Filter's: the
/// kinds, and For now. For now's: what it is, Keep and Show All.
private struct MailFilterPopover: View {
    let open: MailFilterMenu.Open
    let split: MailList.Split
    let account: String
    /// The height it has under its pill, down to the list's foot.
    let room: CGFloat
    var desk: MailDesk
    @Bindable private var menu = MailFilterMenu.shared
    private var counts = MailFilterCounts.shared
    @FocusState private var focus: Bool
    /// What each row's end says, kept while new counts are on their way.
    @State private var ends: [String: (words: String, faint: Bool)] = [:]
    /// What stands over the rows, as tall as it is drawn.
    @State private var top: CGFloat = 80

    var body: some View {
        let rows = menu.rows()
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                switch open {
                case .filter(let filter):
                    head(filter)
                    field(filter)
                    if rows.isEmpty, let note = note(filter) {
                        Text(note).font(.system(size: 12)).foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                    }
                case .picker:
                    search
                case .temp:
                    tempNote
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { top = $0 }
            // Its rows, scrolled when they are more than the room under the pill.
            ScrollViewReader { reader in
                ThreadScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            if !row.section.isEmpty, index == 0 || rows[index - 1].section != row.section {
                                Text(row.section).font(.system(size: 12)).foregroundStyle(Palette.muted)
                                    .lineLimit(1)
                                    .padding(.horizontal, 8)
                                    .padding(.top, 8)
                                    .padding(.bottom, 4)
                            }
                            rowView(row, index).id(row.id)
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: max(0, room - top - 12))
                .onChange(of: menu.lit) { _, lit in
                    if rows.indices.contains(lit) { reader.scrollTo(rows[lit].id) }
                }
            }
        }
        .padding(6)
        .background { FieldGlass(shape: RoundedRectangle(cornerRadius: Radius.floating, style: .continuous), lifted: true) }
        .background(ClickZone(away: menu.away))
        .task(id: wanted(rows) + "\u{1F}\(counts.epoch)") { ask(rows) }
        .onChange(of: counts.version) { _, _ in tell(menu.rows()) }
        .onChange(of: counts.epoch) { _, _ in ends = [:] }
        .onAppear {
            tell(rows)
            DispatchQueue.main.async { focus = true }
        }
        .onChange(of: menu.focus) { _, _ in focus = true }
    }

    // MARK: parts

    private func head(_ filter: MailFilter) -> some View {
        HStack(spacing: 6) {
            Text(filter.title) + Text(" " + filter.joins).foregroundStyle(Palette.ink).fontWeight(.medium)
            Spacer(minLength: 8)
            if menu.removable(filter, split), split.rules.contains(where: { filter.kinds.contains($0.kind) }) {
                Button { menu.removeAll(filter) } label: { Text("Remove") }
                    .buttonStyle(.yab(.quiet, .small))
                    .fixedSize()
            }
        }
        .font(.system(size: 12.5))
        .foregroundStyle(Palette.muted)
        .padding(.horizontal, 8)
        .frame(height: 30)
    }

    /// The values in it as tokens, a cross each, and the words to find more.
    private func field(_ filter: MailFilter) -> some View {
        let tokens = self.tokens(filter)
        return MailPills(spacing: 4, stretch: true) {
            ForEach(tokens.prefix(3), id: \.id) { token in
                HStack(spacing: 4) {
                    if let rule = token.rule { MailFilterMark(mark: .rule(rule), size: 16) }
                    Text(token.title).lineLimit(1)
                    if !token.fixed {
                        Button(action: token.drop) { Symbol("xmark", size: 7, weight: .semibold).foregroundStyle(Palette.muted) }
                            .buttonStyle(.plain)
                            .frame(width: 12, height: 12)
                    }
                }
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 4)
                .frame(height: 22)
                .background(RoundedRectangle(cornerRadius: Radius.small, style: .continuous).fill(Palette.wash))
            }
            if tokens.count > 3 {
                Text("+\(tokens.count - 3)").font(.system(size: 12.5)).foregroundStyle(Palette.muted)
                    .padding(.horizontal, 4)
                    .frame(height: 22)
            }
            TextField(tokens.isEmpty ? filter.asks : "", text: $menu.typed)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focus)
                .padding(.horizontal, 4)
                .frame(height: 22)
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(Palette.ground.opacity(0.8)))
        .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
            .strokeBorder(focus ? Color.accentColor.opacity(0.55) : Palette.ink.opacity(0.1), lineWidth: 1))
        .padding(.horizontal, 4)
        .padding(.bottom, 4)
    }

    private var search: some View {
        TextField("Filter by\u{2026}", text: $menu.typed)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .focused($focus)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(Palette.ground.opacity(0.8)))
            .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .strokeBorder(focus ? Color.accentColor.opacity(0.55) : Palette.ink.opacity(0.1), lineWidth: 1))
            .padding(.horizontal, 4)
            .padding(.bottom, 4)
    }

    private var tempNote: some View {
        let only = desk.only ?? .unread
        let what = only == .unanswered ? "Only threads without your reply" : "Only " + only.name.lowercased()
        return VStack(alignment: .leading, spacing: 0) {
            (Text(what + ", for now. ").foregroundStyle(Palette.ink).fontWeight(.semibold)
                + Text(split.title + " itself stays as it is."))
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            Rectangle().fill(Omnibox.seam).frame(height: 1).padding(.vertical, 4)
        }
    }

    private func rowView(_ row: MailFilterRow, _ index: Int) -> some View {
        let end = ends[row.id]
        return HStack(spacing: 10) {
            if let ticked = row.ticked { MailTick(on: ticked).opacity(row.fixed ? 0.4 : 1) }
            MailFilterMark(mark: row.mark, size: row.ticked == nil ? 20 : 18)
            Text(row.title).font(.system(size: 13)).foregroundStyle(Palette.ink).lineLimit(1).layoutPriority(1)
            if !row.detail.isEmpty {
                Text(row.detail).font(.system(size: 12)).foregroundStyle(Palette.muted).lineLimit(1)
            }
            Spacer(minLength: 8)
            switch row.tally {
            case .keys(let action):
                ShortcutGlyphs(action, size: 11.5, tint: nil).opacity(0.6)
                    .environment(\.keyPlate, KeyPlate(height: 20, pull: 2))
            case .words(let keys):
                KeyGlyphs(keys: keys, size: 11.5, tint: nil, rest: 0.6)
                    .environment(\.keyPlate, KeyPlate(height: 20, pull: 2))
            default:
                if let end, !end.words.isEmpty {
                    Text(end.words).font(.system(size: 12.5)).monospacedDigit()
                        .foregroundStyle(end.faint ? Palette.faint : Palette.muted)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
        }
        .foregroundStyle(Palette.muted)
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(index == menu.lit ? Omnibox.chosenFill : Color.clear))
        .contentShape(Rectangle())
        .onHover { if $0 { menu.lit = index } }
        .onTapGesture { menu.take(row) }
        .pointerTip(row.fixed ? "A split keeps one rule at least" : "")
    }

    // MARK: what it says

    private struct Token {
        let id: String
        let title: String
        var rule: MailRule?
        var fixed = false
        let drop: () -> Void
    }

    private func tokens(_ filter: MailFilter) -> [Token] {
        let held = split.rules.filter { filter.kinds.contains($0.kind) }
        if filter == .words {
            let words = held.flatMap { $0.value.split(separator: " ").map(String.init) }
            let alone = words.count == 1 && held.first.map { menu.fixed($0, in: split) } == true
            return words.enumerated().map { index, word in Token(id: "\(index):\(word)", title: word, fixed: alone) { menu.dropWord(word) } }
        }
        return held.map { rule in
            Token(id: rule.kind + rule.value, title: rule.named, rule: filter == .search ? nil : rule, fixed: menu.fixed(rule, in: split)) {
                menu.remove(rule, from: filter)
            }
        }
    }

    private func note(_ filter: MailFilter) -> String? {
        switch filter {
        case .words: return "Threads with all of these words, in the subject or the mail."
        case .search: return "As you would search Gmail: has:attachment, older_than:1y, subject:invoice."
        default: return menu.typed.isEmpty ? nil : "Nothing in your mail starts so. A site or an address typed whole is offered as it is."
        }
    }

    // MARK: counts

    private func wanted(_ rows: [MailFilterRow]) -> String {
        account + "\u{1F}" + split.q + "\u{1F}" + rows.flatMap(\.lines).joined(separator: "\u{1E}")
    }

    private func ask(_ rows: [MailFilterRow]) {
        var lines = rows.flatMap(\.lines)
        if rows.contains(where: { if case .keeps = $0.tally { return true } else { return false } }) { lines.append(split.q) }
        counts.ask(lines, base: split.q, account: account)
        tell(rows)
    }

    /// Each row's end from the counts in; one still counting keeps what it said.
    private func tell(_ rows: [MailFilterRow]) {
        let threads = { (n: Int) in n == 1 ? "1 thread" : "\(n.formatted()) threads" }
        let count = { (line: String) in counts.count(line, base: split.q, account: account) }
        var said = ends
        for row in rows {
            switch row.tally {
            case .brings(let line, let alone):
                guard let one = count(line) else { continue }
                if one.all > 0 { said[row.id] = (threads(one.all), false); continue }
                guard let raw = count(alone) else { continue }
                said[row.id] = (raw.all > 0 ? "left out" : "no mail now", true)
            case .adds(let line):
                guard let one = count(line) else { continue }
                said[row.id] = (one.added > 0 ? "+" + threads(one.added) : "", false)
            case .keeps(let line):
                guard let one = count(line), let all = count(split.q) else { continue }
                said[row.id] = ("keeps \(one.all.formatted()) of \(all.all.formatted())", one.all == 0)
            case .gathers(let line):
                guard let one = count(line) else { continue }
                said[row.id] = (one.all > 0 ? threads(one.all) : "no mail now", one.all == 0)
            default:
                continue
            }
        }
        if said.count != ends.count || said.contains(where: { ends[$0.key]?.words != $0.value.words }) { ends = said }
    }
}

/// A value's mark: a person's letters, a site's icon, a kind's symbol.
struct MailFilterMark: View {
    let mark: MailFilterRow.Mark
    let size: CGFloat

    var body: some View {
        switch mark {
        case .symbol(let name):
            tile(name)
        case .rule(let rule):
            if ["with", "from", "to"].contains(rule.kind), rule.value.contains("@") {
                MailAvatar(initials: MailDesk.initials(rule.named), size: size)
            } else if rule.kind == "from" {
                SiteMark(host: rule.value, size: size)
            } else {
                tile(rule.kind == "team" ? "person.2" : rule.kind == "kind" ? MailFilter.symbol(ofKind: rule.value) : "magnifyingglass")
            }
        }
    }

    private func tile(_ name: String) -> some View {
        Symbol(name, size: (size * 0.5).rounded())
            .foregroundStyle(Palette.ink)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: Radius.small, style: .continuous).fill(Palette.ink.opacity(0.07)))
    }
}

/// A row's box, ticked in the accent.
private struct MailTick: View {
    let on: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                .fill(on ? Color.accentColor : Color.clear)
            if on {
                Symbol("checkmark", size: 8, weight: .bold).foregroundStyle(Color.white)
            } else {
                RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                    .strokeBorder(Palette.ink.opacity(0.28), lineWidth: 1)
            }
        }
        .frame(width: 14, height: 14)
    }
}

// MARK: - New Split

/// New Split, in mail's field as Passwords and History are (MailField's
/// library rows, MailLibraryPreview beside them): Build Your Own, which
/// starts one empty with + Add Filter open; Describe to Claude, which
/// starts it with its name to say; and the splits mail has ready, each
/// with what of your mail it would gather now.
@MainActor
@Observable final class MailSplitLibrary {
    static let shared = MailSplitLibrary()

    struct Card: Identifiable {
        let id: String
        let title: String
        let icon: String
        let says: String
        let q: String
        /// A built-in split, turned on; else one of yours, made.
        var builtIn = true
    }

    struct Preview: Sendable {
        struct Row: Sendable {
            let who: String
            let address: String
            let subject: String
        }
        var count = 0
        var rows: [Row] = []
    }

    static let cards: [Card] = [
        Card(id: "receipts", title: "Receipts", icon: "creditcard", says: "Bills and receipts.", q: "kind:invoice"),
        Card(id: "dev", title: "Dev", icon: "chevron.left.forwardslash.chevron.right", says: "Code, issues and deploys.",
             q: MailRule.line(MailSplits.dev.map { MailRule(kind: "from", value: $0) })),
        Card(id: "q:kind:list", title: "Newsletters", icon: "doc.text", says: "Letters you subscribed to.", q: "kind:list", builtIn: false),
        Card(id: "team", title: "Team", icon: "person.2", says: "Everyone at your domain.", q: "team:domain"),
        Card(id: "calendar", title: "Calendar", icon: "calendar", says: "Invitations and meeting mail.", q: "kind:meeting"),
        Card(id: "vip", title: "VIP", icon: "star", says: "People you pick, always first.", q: ""),
    ]

    /// Settings' feature colors, shared by the library row and its preview.
    static func tint(_ id: String) -> NSColor {
        switch id {
        case "build": return .systemBlue
        case "describe": return .systemPurple
        case "receipts": return .systemGreen
        case "dev": return .systemIndigo
        case "q:kind:list": return .systemOrange
        case "team": return .systemTeal
        case "calendar": return .systemRed
        case "vip": return .systemYellow
        default: return .systemGray
        }
    }

    private(set) var previews: [String: Preview] = [:]
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var watching: Set<AnyCancellable> = []

    private init() {
        MailCenter.shared.observed(\.changed).dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshIfOpen() }
        }.store(in: &watching)
        MailList.shared.observed(\.account).removeDuplicates().dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshIfOpen() }
        }.store(in: &watching)
    }

    private func refreshIfOpen() {
        generation += 1
        previews = [:]
        if let browser = MailDesk.shared.browser, browser.query.place == .mail,
           browser.query.stock.mail?.mode == .library { read() }
    }

    /// Whether a card's split is in the column already.
    func added(_ card: Card) -> Bool { MailList.shared.split(card.id) != nil }

    /// Add: on, or made, and in front.
    func add(_ card: Card) {
        let list = MailList.shared
        if card.builtIn {
            list.turn(card.id, on: true)
            list.split = card.id
            list.pulse(card.id)
        } else {
            list.saveList(title: card.title, q: card.q, icon: card.icon)
        }
    }

    func open(_ card: Card) { MailList.shared.split = card.id }

    /// Build Your Own: an empty split in front, + Add Filter open on it.
    func build() {
        let was = MailList.shared.split
        MailFilterMenu.shared.show(once: .picker)
        MailList.shared.startDraft()
        if was == "draft" { MailFilterMenu.shared.arrived() }
    }

    /// Describe to Claude: an empty split, its name to say what it keeps.
    func describe() {
        MailFilterMenu.shared.close()
        MailList.shared.startDraft()
        MailList.shared.focusDraftTitle()
    }

    /// What each card would gather, the newest of it, off the main thread.
    func read() {
        generation += 1
        let generation = generation
        previews = [:]
        let account = MailList.shared.account
        let stores = MailCenter.shared.showing(account).map(\.store)
        let rules = Self.cards.map { MailSplitSort.Rule(MailList.Split(id: $0.id, title: "", q: $0.q, mode: .also)) }
        let now = MailClock.now
        Task.detached(priority: .userInitiated) {
            let found = MailSplitLibrary.previews(rules, in: stores, now: now)
            await MainActor.run {
                let library = MailSplitLibrary.shared
                guard library.generation == generation, MailList.shared.account == account else { return }
                library.previews = found
                // The rows say what each holds: made again, the field kept.
                if let browser = MailDesk.shared.browser, browser.query.place == .mail, browser.query.stock.mail?.mode == .library {
                    browser.query.stock.version += 1
                    browser.replaceTyped(browser.typed)
                }
            }
        }
    }

    nonisolated static func previews(_ rules: [MailSplitSort.Rule], in stores: [MailStore], now: Date) -> [String: Preview] {
        let sort = MailSplitSort(rules: rules)
        var counts = Array(repeating: 0, count: rules.count)
        var hits: [[(at: Date, store: MailStore, id: String)]] = Array(repeating: [], count: rules.count)
        for store in stores {
            let facts = store.facts(now: now)
            let placed = sort.place(facts, me: store.me, answers: sort.answers(store, among: nil, now: now), now: now)
            guard placed.members.count == facts.count else { continue }
            for (index, fact) in facts.enumerated() where placed.members[index] != 0 {
                for n in rules.indices where placed.members[index] & (1 << UInt64(n)) != 0 {
                    counts[n] += 1
                    if hits[n].count < 5 || fact.last >= hits[n].last!.at {
                        hits[n].append((fact.last, store, fact.id))
                        hits[n].sort { $0.at == $1.at ? $0.id < $1.id : $0.at > $1.at }
                        if hits[n].count > 5 { hits[n].removeLast() }
                    }
                }
            }
        }
        var out: [String: Preview] = [:]
        for (n, rule) in rules.enumerated() {
            let rows = hits[n].compactMap { hit -> Preview.Row? in
                guard let thread = hit.store.thread(hit.id), let person = thread.people.first else { return nil }
                return Preview.Row(who: person.name.isEmpty ? person.address : person.name, address: person.address.lowercased(),
                                   subject: thread.subject.isEmpty ? "(no subject)" : thread.subject)
            }
            out[rule.id] = Preview(count: counts[n], rows: rows)
        }
        return out
    }
}

/// Beside New Split's rows, the chosen one, as a place's preview is: what
/// it is, its filters, and what of your inbox it would hold now.
struct MailLibraryPreview: View {
    /// The row chosen: "build", "describe", or a card's id.
    let chosen: String?
    private var library = MailSplitLibrary.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if chosen == "build" {
                head("plus", "Build your own", "Start empty, then + Add Filter: people, sites, kinds of mail or words.")
                lines([("Filters", "From, To, Kind, Mentions, Search"), ("Kept", "Keep Split \u{2318}\u{21A9}")])
            } else if chosen == "describe" {
                head("sparkles", "Describe to \(PlanText.writer)", "Say what it keeps; \(PlanText.writer) picks the filters from who writes you.")
                lines([("Say", "\u{201C}investor updates and term sheets\u{201D}")])
            } else if let card = MailSplitLibrary.cards.first(where: { $0.id == chosen }) {
                let preview = library.previews[card.id]
                head(card.icon, card.title, card.says)
                lines([("Filters", filters(card)), ("Now", preview.map { $0.count == 1 ? "1 thread" : "\($0.count.formatted()) threads" } ?? "")])
                if let rows = preview?.rows, !rows.isEmpty {
                    Text("In your inbox now")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                        .padding(.horizontal, 8)
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            HStack(spacing: 8) {
                                mark(row)
                                Text(row.who).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Palette.ink).lineLimit(1)
                                Text(row.subject).font(.system(size: 12.5)).foregroundStyle(Palette.muted).lineLimit(1)
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 30)
                        }
                    }
                } else if preview != nil {
                    Text(card.id == "vip" ? "Nobody yet: Add to VIP from a mail with \u{2318}K." : "Nothing like it in your inbox now.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.muted)
                        .padding(.horizontal, 8)
                }
            }
        }
        .padding(16)
    }

    private func head(_ symbol: String, _ title: String, _ says: String) -> some View {
        HStack(spacing: 12) {
            // The row's own mark, larger: drawn by pen where the field's row is.
            let tint = MailSplitLibrary.tint(chosen ?? "build")
            FeatureTile(icon: symbol, tint: tint, side: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.ink)
                Text(says).font(.system(size: 12.5)).foregroundStyle(Palette.muted).lineLimit(2)
            }
        }
    }

    /// Label and value a line, as a place's Information has them.
    private func lines(_ all: [(String, String)]) -> some View {
        let shown = all.filter { !$0.1.isEmpty }
        return VStack(spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.offset) { index, line in
                HStack(spacing: 12) {
                    Text(line.0).font(.system(size: 13)).foregroundStyle(Palette.muted).lineLimit(1).fixedSize()
                    Spacer(minLength: 0)
                    Text(line.1).font(.system(size: 13)).foregroundStyle(Palette.ink).lineLimit(1).truncationMode(.tail)
                }
                .padding(.horizontal, 8)
                .frame(height: 34)
                if index < shown.count - 1 {
                    Rectangle().fill(Omnibox.seam).frame(height: 0.5).padding(.horizontal, 8)
                }
            }
        }
    }

    /// Its rules as its pills would say them: "Kind is Bills".
    private func filters(_ card: MailSplitLibrary.Card) -> String {
        let rules = MailRule.parse(card.q)
        if rules.isEmpty { return "From the people you add" }
        return MailFilter.allCases.compactMap { filter -> String? in
            let held = rules.filter { filter.kinds.contains($0.kind) }
            guard !held.isEmpty else { return nil }
            let names = held.map(\.named)
            return filter.title + " " + (names.count <= 2 ? names.joined(separator: ", ") : names.prefix(2).joined(separator: ", ") + " +\(names.count - 2)")
        }.joined(separator: "; ")
    }

    @ViewBuilder private func mark(_ row: MailSplitLibrary.Preview.Row) -> some View {
        if let domain = MailBlock.domain(of: row.address, me: "") {
            SiteMark(host: domain, size: 16)
        } else {
            MailAvatar(initials: MailDesk.initials(row.who), size: 16)
        }
    }
}
