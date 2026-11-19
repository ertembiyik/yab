import Combine
import Foundation

// Searches Gmail answers (docs/mail.md, Search by the server): when the Mac
// finds fewer than ten threads, when the search reaches past what the Mac
// keeps (before:, older_than:) or asks what it can't tell (size:, Bcc),
// and when you take Search All Mail. Asked once for each account and
// search, and again only when you ask for all mail or for more; what Gmail
// finds comes by its headers, is kept, and joins the list (MailDesk.read),
// a thread that came so marked Gmail. The column's search, its empty state
// and the agents' mail_search all read the answers here.
//
// The mail memory (MailMemory, P1.12), five years of mail's words on this
// Mac, is asked the same searches by their words, without the network: its
// threads join the column's list at once, marked as Gmail's are, and a
// thread only it keeps opens with its words when Gmail can't be reached.

@MainActor
@Observable final class MailServerSearch {
    static let shared = MailServerSearch()

    enum State: Equatable {
        case asking
        /// The threads Gmail found, newest first, all here now; `more`:
        /// it found more than came, asked again they do.
        case found([String], more: Bool)
        /// Said for a person: Gmail couldn't be asked.
        case failed(String)
    }

    /// Below this many threads found on the Mac, Gmail is asked too.
    nonisolated static let enough = 10

    /// By account and the search as Gmail reads it.
    private(set) var states: [String: State] = [:]
    @ObservationIgnored private var running: [String: Task<State, Never>] = [:]
    /// Whether the Mac's own answer to a search wasn't the whole one,
    /// decided once for each account and search, not each time the list
    /// is read (Search All Mail asks Gmail whatever it was).
    @ObservationIgnored private var decided: [String: (wanted: Bool, answered: Bool)] = [:]

    /// A thread of old mail the mail memory keeps, as its row says it.
    struct Recalled: Equatable {
        let thread: String
        let subject: String
        let sender: String
        let line: String
        let at: Date
    }

    /// What the mail memory found, by account and search, newest first.
    private(set) var recalled: [String: [Recalled]] = [:]
    @ObservationIgnored private var recalling: Set<String> = []

    private func key(_ account: String, _ query: MailQuery) -> String { account + "|" + query.gmail }

    func state(_ query: MailQuery, account: String) -> State? { states[key(account, query)] }

    /// The threads Gmail found for a search on one account, so far.
    func found(_ query: MailQuery, account: String) -> [String] {
        if case .found(let threads, _)? = states[key(account, query)] { return threads }
        return []
    }

    /// Any account's answer still coming.
    func asking(_ query: MailQuery, accounts: [String]) -> Bool {
        accounts.contains { states[key($0, query)] == .asking }
    }

    /// What went wrong asking, on any account.
    func trouble(_ query: MailQuery, accounts: [String]) -> String? {
        for account in accounts { if case .failed(let said)? = states[key(account, query)] { return said } }
        return nil
    }

    /// Whether the Mac's own answer isn't the whole one: too few found,
    /// something it can't tell, or a reach past the mail it keeps (since
    /// sixty days before its first sync, MailSync.bootstrap).
    nonisolated static func wanted(_ query: MailQuery, found: Int, answered: Bool, horizon: Date, now: Date = Date()) -> Bool {
        guard !query.isEmpty else { return false }
        return !answered || found < enough || query.reachesPast(horizon, now: now)
    }

    /// Where an account's mail reaches back to.
    nonisolated static func horizon(_ store: MailStore, now: Date = Date()) -> Date {
        store.value("since").flatMap(Double.init).map(Date.init(timeIntervalSince1970:)) ?? now.addingTimeInterval(-60 * 86_400)
    }

    /// Whether the Mac's answer on one account isn't the whole one (`wanted`),
    /// and whether it could tell at all, asked of the store once.
    private func short(_ query: MailQuery, engine: MailCenter.Engine) -> (wanted: Bool, answered: Bool) {
        let key = key(engine.account, query)
        if let known = decided[key] { return known }
        let here = engine.store.find(query, limit: 1)
        let wanted = MailServerSearch.wanted(query, found: here.total, answered: here.answered, horizon: MailServerSearch.horizon(engine.store))
        decided[key] = (wanted, here.answered)
        return (wanted, here.answered)
    }

    /// Gmail's answer on one account: asked when it is wanted and wasn't
    /// before, or `force` (Search All Mail, or more of it), else the one
    /// kept; one search at a time for each account and search. `view`: a
    /// list beyond the inbox's (MailViews), wanted without the store's look,
    /// reading on through Gmail's pages past what is here.
    @discardableResult
    func answer(_ query: MailQuery, engine: MailCenter.Engine, force: Bool = false, view: Bool = false) async -> State? {
        // A server that can't search in Yab's words (IMAP, for now): the store answers alone.
        guard !query.isEmpty, engine.provider.can.contains(.search) else { return nil }
        let key = key(engine.account, query)
        if let going = running[key] { return await going.value }
        if !force, let known = states[key] { return known }
        if !force, !view, !short(query, engine: engine).wanted { return nil }
        states[key] = .asking
        let task = Task<State, Never> {
            do {
                let got = try await engine.sync.search(query, take: 25, pages: view ? MailViews.pages : 1)
                return .found(got.threads, more: got.more)
            } catch MailTrouble.limited {
                return .failed("Gmail asked Yab to slow down. Try again in a minute.")
            } catch MailTrouble.signedOut {
                return .failed("Google stopped letting Yab in.")
            } catch MailTrouble.offline {
                return .failed("Gmail couldn’t be reached.")
            } catch {
                return .failed("Gmail didn’t answer.")
            }
        }
        running[key] = task
        let state = await task.value
        running[key] = nil
        states[key] = state
        return state
    }

    /// The same, for every account the column shows, without waiting, the
    /// mail memory too: `done` once each has answered.
    func ask(_ query: MailQuery, account: String, force: Bool = false, done: @escaping () -> Void) {
        for engine in MailCenter.shared.searching(account) {
            Task {
                if await remember(query, engine: engine, force: force) { done() }
            }
            Task {
                let before = states[key(engine.account, query)]
                let state = await answer(query, engine: engine, force: force)
                if state != nil, state != before { done() }
            }
        }
    }

    // MARK: - the lists beyond the inbox

    /// A list beyond the inbox's (G then a key, a label's) asked of Gmail for
    /// what is older than this Mac keeps (MailViews.query), on every account
    /// the column shows: once for each account and list, and, `more`, again
    /// for the next of it where Gmail found more than came. `done` once an
    /// account's answer changed what the list holds.
    func ask(view: String, account: String, more: Bool = false, done: @escaping () -> Void) {
        for engine in MailCenter.shared.showing(account) {
            guard let query = MailViews.query(view, in: engine.store) else { continue }
            let key = key(engine.account, query)
            if more {
                guard case .found(_, more: true)? = states[key] else { continue }
            } else if states[key] != nil {
                continue
            }
            Task {
                let before = states[key]
                let state = await answer(query, engine: engine, force: more, view: true)
                if state != nil, state != before { done() }
            }
        }
    }

    /// Where a list beyond the inbox's stands with Gmail on the accounts
    /// shown: being asked, found more than came, or Gmail's trouble.
    func view(_ view: String, account: String) -> (asking: Bool, more: Bool, trouble: String?) {
        var out: (asking: Bool, more: Bool, trouble: String?) = (false, false, nil)
        for engine in MailCenter.shared.showing(account) {
            guard let query = MailViews.query(view, in: engine.store) else { continue }
            switch states[key(engine.account, query)] {
            case .asking?: out.asking = true
            case .found(_, let more)?: out.more = out.more || more
            case .failed(let said)?: out.trouble = said
            case nil: break
            }
        }
        return out
    }

    // MARK: - the mail memory

    func recalled(_ query: MailQuery, account: String) -> [Recalled] { recalled[key(account, query)] ?? [] }

    /// The mail memory asked a search by its words, once for each account
    /// and search, off the main thread: only where the Mac's own answer
    /// isn't the whole one and could be told (a label or a file the memory
    /// knows nothing of), and only while the memory is on. True when it
    /// found something.
    private func remember(_ query: MailQuery, engine: MailCenter.Engine, force: Bool) async -> Bool {
        let key = key(engine.account, query)
        guard recalled[key] == nil, !recalling.contains(key), !query.keywords.isEmpty,
              let memory = MailMemory.attached(to: engine.store) else { return false }
        let mac = short(query, engine: engine)
        guard mac.answered, force || mac.wanted else { return false }
        recalling.insert(key)
        let me = engine.store.me
        let found = await Task.detached(priority: .userInitiated) { MailServerSearch.recall(query, in: memory, me: me) }.value
        recalling.remove(key)
        recalled[key] = found
        return !found.isEmpty
    }

    /// The memory's pieces for a search's words (and its from:), each read
    /// as a message would be, only those that answer the whole search, a
    /// thread each, newest first.
    nonisolated static func recall(_ query: MailQuery, in memory: MailMemory, me: String, now: Date = Date()) -> [Recalled] {
        var out: [String: Recalled] = [:]
        for hit in memory.recall(query.keywords.joined(separator: " "), from: query.sender, limit: MailMemory.depth) {
            let from = MailPerson.one(hit.sender) ?? MailPerson(name: hit.sender, address: "")
            let message = MailMessage(id: hit.mail, thread: hit.thread, from: from, to: MailPerson.list(hit.recipients),
                                      subject: hit.subject, date: hit.at, replyTo: [], text: hit.text)
            guard query.matches(message, me: me, now: now), (out[hit.thread]?.at ?? .distantPast) < hit.at else { continue }
            out[hit.thread] = Recalled(thread: hit.thread, subject: hit.subject, sender: from.said, line: MailSense.line(hit.text), at: hit.at)
        }
        return out.values.sorted { $0.at > $1.at }
    }

}
