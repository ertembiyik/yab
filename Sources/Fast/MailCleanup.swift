import AppKit
import Foundation

// Clearing mail out (docs/mail.md, Cleanup): ⌘U leaves a list, Block Sender
// keeps someone out, Get Me To Zero marks the inbox done, and the Bulk
// Actions log keeps what was done to many threads at once for seven days,
// to be taken back. What a list says about leaving it comes with its mail
// (List-Unsubscribe, List-Unsubscribe-Post, MailStore); a sender kept out
// is kept on this Mac, not as a Gmail filter, which would need another of
// Google's scopes.

// MARK: - the acts

extension MailDesk {
    /// Who wrote a thread, as Block Sender and ⌘U name them: the newest
    /// writer in it who isn't you; nobody in one only you wrote in.
    nonisolated static func writer(of thread: String, in store: MailStore) -> MailPerson? {
        let me = store.me
        return store.messages(thread: thread).last { $0.from.address != me && $0.from.address.contains("@") }?.from
    }

    func sender(of row: Row) -> MailPerson? {
        MailCenter.shared.engines[row.account].flatMap { MailDesk.writer(of: row.thread, in: $0.store) }
    }

    /// ⌘U: off the lists of the threads picked, or of the one in front
    /// (MailUnsubscribe): one POST where the list offers it, else a mail to
    /// its address through the send path, never an agent's, else its page
    /// in a peek, to finish there. The threads are done at once; ⌘Z brings
    /// them back, and leaving the list stands. One list, with more of its
    /// mail in the inbox: the field offers the rest, done or into Trash.
    func unsubscribe() {
        let all = targets
        let picked = all.filter { MailCenter.shared.engines[$0.account]?.store.thread($0.thread)?.bulk == true }
        guard !picked.isEmpty else {
            if !all.isEmpty { say("Not from a mailing list", mark: "rectangle.portrait.and.arrow.right") }
            return
        }
        let was = screen, kept = keptOf(picked)
        let acted = perform(picked, hold: MailDesk.hold) { MailOps.done($0, after: $1, in: $2) }
        MailList.shared.settled(picked.map { ($0.account, $0.thread) })
        settle(picked, away: true)
        remember(.unsubscribe, picked, acted, screen: was, kept: kept)
        // A list whose way is its page has nothing to clear yet: the page is in front.
        let row = picked.count == 1 ? picked.first : nil
        let way = row.flatMap { row in
            MailCenter.shared.engines[row.account].flatMap { MailUnsubscribe.of($0.store.messages(thread: row.thread), me: $0.store.me)?.way }
        }
        if let row, let sender = sender(of: row), way?.isPage != true {
            offerRest(account: row.account, of: sender, trash: false)
        }
        Task { await leave(picked) }
    }

    /// Off each list, one at a time, by its first way that works; then the
    /// corner says how it went. A list kept before the store had its header
    /// is asked of Gmail first.
    private func leave(_ picked: [Row]) async {
        var left: [(name: String, by: MailUnsubscribe.Way)] = []
        var failed: [String] = []
        var page: URL?
        var seen = Set<String>()
        for row in picked {
            guard let engine = MailCenter.shared.engines[row.account] else { continue }
            var messages = engine.store.messages(thread: row.thread)
            if messages.contains(where: { $0.listUnsubscribe && $0.unsubscribe == nil }) {
                try? await engine.sync.open(thread: row.thread)
                messages = engine.store.messages(thread: row.thread)
            }
            guard let found = MailUnsubscribe.all(messages, me: engine.store.me) else {
                failed.append(row.whoFull)
                continue
            }
            // The same list picked twice is left once.
            guard seen.insert(found.sender.address).inserted else { continue }
            var gone: MailUnsubscribe.Way?
            for way in found.ways {
                switch way {
                case .oneClick(let url): if await MailUnsubscribe.post(url) { gone = way }
                case .mail(let mail): if MailDesk.mailOut(mail, account: row.account) { gone = way }
                case .page(let url):
                    page = page ?? url
                    gone = way
                }
                if gone != nil { break }
            }
            guard let gone else {
                failed.append(found.sender.said)
                continue
            }
            engine.store.unsubscribed(found.sender.address, how: gone.name)
            if gone.isPage { continue }
            left.append((found.sender.said, gone))
        }
        if let page { follow(page) }
        if let name = failed.first, left.isEmpty, page == nil {
            say("Couldn’t unsubscribe from " + name, mark: "exclamationmark.triangle")
        } else if left.count == 1, let one = left.first {
            say("Unsubscribed from " + one.name + (one.by.name == "mail" ? " by mail" : ""), mark: "rectangle.portrait.and.arrow.right")
        } else if left.count > 1 {
            say("Unsubscribed from \(left.count) lists", mark: "rectangle.portrait.and.arrow.right")
        }
    }

    /// A list's unsubscribe mail, through the send path as one you wrote
    /// goes: from the account, out at the next flush, never by an agent.
    static func mailOut(_ mail: MailUnsubscribe.Mailto, account: String) -> Bool {
        guard let engine = MailCenter.shared.engines[account] else { return false }
        var draft = MailDraft(id: "unsubscribe:" + UUID().uuidString, to: mail.to.map { MailPerson(name: "", address: $0) },
                              subject: mail.subject, body: mail.body)
        draft.messageID = MailCompose.messageID(from: engine.store.me)
        engine.store.save(draft)
        return MailCenter.shared.act(.send, thread: draft.id, account: account) != nil
    }

    /// Block Sender (⌘K): whoever wrote the threads picked, or the one in
    /// front, kept out (their address, or with `domain` everyone at their
    /// domain), their new mail into Trash as it comes, and these threads
    /// into Trash now. ⌘Z takes it all back, the block too. One sender,
    /// with more of their mail in the inbox: the field offers the rest.
    func block(domain: Bool = false) {
        let picked = targets
        guard !picked.isEmpty else { return }
        let was = screen, kept = keptOf(picked)
        let senders = Set(picked.compactMap { row in sender(of: row).flatMap { entry($0, account: row.account, domain: domain) } })
        guard !senders.isEmpty else { return }
        let acted = perform(picked, hold: MailDesk.hold) { threads, hold, store in
            let who = threads.compactMap { MailDesk.writer(of: $0, in: store).flatMap { entry($0, me: store.me, domain: domain) } }
            return MailOps.block(Array(Set(who)).sorted(), threads: threads, after: hold, in: store)
        }
        MailList.shared.settled(picked.map { ($0.account, $0.thread) })
        say(senders.count == 1 ? "Blocked " + senders.first! : "Blocked \(senders.count) senders", mark: "xmark.shield", keys: ["⌘", "Z"])
        settle(picked, away: true)
        remember(.block, picked, acted, screen: was, kept: kept)
        if picked.count == 1, let row = picked.first, let sender = sender(of: row), !domain {
            offerRest(account: row.account, of: sender, trash: true)
        }
    }

    /// The spam notice's Also Block: the sender of a thread marked as spam
    /// kept out from now on, the thread left in spam.
    func blockSender(of row: Row) {
        guard let store = MailCenter.shared.engines[row.account]?.store, let sender = sender(of: row),
              let who = entry(sender, me: store.me, domain: false) else { return }
        let acted = MailOps.block([who], threads: [], in: store)
        guard !acted.isEmpty else { return say("Blocked " + who, mark: "xmark.shield") }
        say("Blocked " + who, mark: "xmark.shield", keys: ["⌘", "Z"])
        remember(Undo(kind: .block, account: row.account, row: nil, split: split, screen: screen, acted: [row.account: acted]))
    }

    /// What Block Sender keeps for a sender: their address, or their domain
    /// when it isn't everyone's or yours; never your own address.
    private func entry(_ sender: MailPerson, account: String, domain: Bool) -> String? {
        entry(sender, me: MailCenter.shared.engines[account]?.store.me ?? "", domain: domain)
    }

    private nonisolated func entry(_ sender: MailPerson, me: String, domain: Bool) -> String? {
        guard sender.address.lowercased() != me.lowercased() else { return nil }
        return domain ? MailBlock.domain(of: sender.address, me: me) : MailBlock.entry(sender.address)
    }

    /// The rest of a sender's mail in the inbox, offered in the field to
    /// clear: done, or into Trash (first, for a sender blocked). Nothing
    /// when there is none.
    func offerRest(account: String, of sender: MailPerson, trash: Bool) {
        guard let browser, let store = MailCenter.shared.engines[account]?.store, !store.inboxThreads(from: sender.address).isEmpty else { return }
        var context = MailFieldContext(mode: .sender, account: account, view: screen == .thread ? "thread" : "list", tab: browser.mailPageTab?.id)
        context.sender = sender.address
        context.senderName = sender.said
        context.trashFirst = trash
        browser.openMailField(context)
    }

    /// Everything from a sender in the inbox, done or into Trash, in one
    /// act ⌘Z takes back, and in the Bulk Actions log for seven days.
    func sweep(account: String, sender: String, name: String, trash: Bool) {
        guard let store = MailCenter.shared.engines[account]?.store else { return }
        let threads = store.inboxThreads(from: sender)
        guard !threads.isEmpty else { return }
        let said = "Everything from " + name + (trash ? ", moved to Trash" : ", done")
        let log = MailOps.log(trash ? .trash : .done, said: said, threads: threads, in: store)
        let acted = trash ? MailOps.trash(threads, after: MailDesk.hold, in: store) : MailOps.archive(threads, after: MailDesk.hold, in: store)
        MailCenter.shared.acted(account, after: MailDesk.hold)
        bulkDone(trash ? "moved to Trash" : "done", account: account, threads: threads, acted: acted, kind: .sweep, log: log)
    }

    /// Get Me To Zero: every thread in the inbox older than `age`, of the
    /// account the column shows or all of them, out of the inbox in one
    /// act, the unread and the starred left when asked (MailZero.Leave).
    /// The store's work goes off the main thread (30,000 threads take a
    /// few hundred ms); the list follows once it is done. One ⌘Z takes it
    /// back; the Bulk Actions log keeps it seven days.
    func zero(_ age: MailZero.Age) {
        let leave = MailZero.Leave.chosen, was = screen, hold = MailDesk.hold, now = Date()
        let stores = MailCenter.shared.showing(MailList.shared.account)
            .map { (account: $0.account, store: $0.store) }
        Task { @MainActor in
            let done = await Task.detached(priority: .userInitiated) {
                stores.compactMap { one -> (account: String, threads: [String], acted: MailOps.Acted, log: Int64)? in
                    let threads = MailZero.threads(age, leave: leave, in: one.store, now: now)
                    guard !threads.isEmpty else { return nil }
                    let log = MailOps.log(.zero, said: "Get Me To Zero, " + age.said, threads: threads, in: one.store, now: now)
                    return (one.account, threads, MailOps.archive(threads, inbox: true, after: hold, in: one.store), log)
                }
            }.value
            var acted: [String: MailOps.Acted] = [:], logs: [String: Int64] = [:], all: [(account: String, thread: String)] = []
            for one in done {
                acted[one.account] = one.acted
                logs[one.account] = one.log
                MailCenter.shared.acted(one.account, after: hold)
                all += one.threads.map { (one.account, $0) }
            }
            guard !all.isEmpty else { return self.say("Nothing in the inbox " + age.said, mark: "broom") }
            let ids = Set(all.map { $0.account + "|" + $0.thread })
            let shown = self.rows.filter { $0.real && ids.contains($0.id) }
            MailList.shared.settled(all)
            self.say(MailDesk.said("Done", "done", all.count), mark: "broom", keys: ["⌘", "Z"])
            self.settle(shown, away: true)
            self.remember(.zero, shown, acted, screen: was, kept: self.keptOf(shown), bulks: logs)
            MailGoing.shared.watch("Marking done in Gmail", acted: acted, after: hold)
            if shown.isEmpty { self.load() }
        }
    }

    /// An act on many done, in the corner and in the list: what left it goes,
    /// ⌘Z can take it all back, the head says how far Gmail is.
    private func bulkDone(_ verb: String, account: String, threads: [String], acted: MailOps.Acted, kind: Undo.Kind, log: Int64) {
        let ids = Set(threads.map { account + "|" + $0 })
        let shown = rows.filter { $0.real && ids.contains($0.id) }
        let was = screen, kept = keptOf(shown)
        MailList.shared.settled(threads.map { (account, $0) })
        say(MailDesk.said(verb.prefix(1).uppercased() + verb.dropFirst(), verb, threads.count),
            mark: verb == "done" ? "checkmark" : "trash", keys: ["⌘", "Z"])
        settle(shown, away: true)
        remember(kind, shown, [account: acted], screen: was, kept: kept, bulks: [account: log])
        MailGoing.shared.watch(verb == "done" ? "Marking done in Gmail" : "Moving to Trash in Gmail", acted: [account: acted], after: MailDesk.hold)
        if shown.isEmpty { load() }
    }

    /// A Bulk Actions entry taken back (the field's Bulk Actions…), in each
    /// account it was made in: its mail back in the inbox, here at once and
    /// in Gmail after.
    func takeBack(bulks ids: [String: Int64]) {
        let stores = ids.compactMap { account, id in MailCenter.shared.engines[account].map { (account: account, store: $0.store, id: id) } }
        Task { @MainActor in
            // Off the main thread, as the act was done: a whole inbox's worth.
            let restored = await Task.detached(priority: .userInitiated) {
                stores.compactMap { one in MailOps.restore(one.id, in: one.store).map { (account: one.account, threads: $0) } }
            }.value
            var back: [String] = []
            for one in restored {
                MailCenter.shared.acted(one.account, after: 0)
                back += one.threads.map { one.account + "|" + $0 }
            }
            guard !back.isEmpty else { return self.say("Too late to take that back", mark: "clock.arrow.circlepath") }
            self.comeBack(Set(back))
            self.say(MailDesk.said("Back in the inbox", "back in the inbox", back.count), mark: "tray.and.arrow.down")
        }
    }
}

/// What the list's head says while an act on many is on its way to Gmail,
/// after its undo window: "Marking done in Gmail, 1,000 of 1,204". Gone
/// once Gmail has heard all of it, or the act was taken back. Only for an
/// act Gmail hears in more than one call; one call is over before it reads.
@MainActor
@Observable final class MailGoing {
    static let shared = MailGoing()
    private(set) var line: String?
    @ObservationIgnored private var watched: (verb: String, parts: [(account: String, part: MailOps.Part)])?
    @ObservationIgnored private var timer: Timer?

    func watch(_ verb: String, acted: [String: MailOps.Acted], after: TimeInterval) {
        let parts = acted.flatMap { account, act in act.entries.flatMap(\.parts).map { (account, $0) } }
        guard parts.count > 1 else { return stop() }
        stop()
        watched = (verb, parts)
        start = Date().addingTimeInterval(after)
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// When Gmail starts hearing it: the act's undo window over.
    @ObservationIgnored private var start = Date.distantFuture

    func stop() {
        timer?.invalidate()
        timer = nil
        watched = nil
        if line != nil { line = nil }
    }

    private func tick() {
        guard let watched, Date() >= start else { return }
        let total = watched.parts.reduce(0) { $0 + $1.part.threads.count }
        // One look at each account's journal.
        var waiting: [String: Set<Int64>] = [:]
        for account in Set(watched.parts.map(\.account)) {
            waiting[account] = MailCenter.shared.engines[account]?.store.pending(watched.parts.filter { $0.account == account }.map(\.part.seq)) ?? []
        }
        let heard = watched.parts.filter { waiting[$0.account]?.contains($0.part.seq) != true }.reduce(0) { $0 + $1.part.threads.count }
        guard heard < total else { return stop() }
        let now = "\(watched.verb), \(heard.formatted()) of \(total.formatted())"
        if line != now { line = now }
    }
}
