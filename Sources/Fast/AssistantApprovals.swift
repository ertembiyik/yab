import AppKit
import SyncKit

// An assistant's question is shown by Yab on this Mac and, when Sync is on,
// on the person's other devices. The assistant relay never receives a way to
// answer it. A call returns needs_user at once and approval_status follows it.
//
// A local agent's (Claude Code through `yab mcp`, a task of Yab's) goes the
// same way when Settings › Agents › Ask on my other devices is on: only the
// yes or no that one press needs, never what needs this Mac itself.
@MainActor
@Observable final class AssistantApprovals {
    static let shared = AssistantApprovals()
    static let lifetime: TimeInterval = 15 * 60
    static let taskLifetime: TimeInterval = 24 * 60 * 60

    static func lifetime(for session: String) -> TimeInterval {
        Agents.shared.session(session).map { $0.cli != "external" } == true ? taskLifetime : lifetime
    }

    enum Kind: String { case yes, hands }

    /// Who asks: an assistant in the cloud, or an agent on this Mac.
    struct Asker: Equatable {
        let id: String
        let name: String
        let local: Bool
    }
    enum State: String { case open, approved, denied, expired, done, skipped }

    enum Place: Equatable {
        case tab(UUID), chat(String), mail(String)
        var wire: String {
            switch self { case .tab(let id): id.uuidString.lowercased(); case .chat(let id): "chat:" + id; case .mail(let id): id }
        }
    }

    struct Record {
        let id: String
        let assistant: String
        let session: String
        let place: Place
        var tab: UUID? { if case .tab(let id) = place { return id }; return nil }
        var seen = false
        let kind: Kind
        let title: String
        let lines: [String]
        let expires: Date
        var state: State = .open
        let key: String?
        var local = false
        /// A sign-in's accounts, for the answer to pick one.
        var choices: [String]? = nil
    }

    private(set) var records: [String: Record] = [:]
    @ObservationIgnored private var waiters: [String: [(Record) -> Void]] = [:]
    /// Local questions waiting for Sync to come up, in a Yab woken for
    /// agents that hasn't started it yet.
    @ObservationIgnored private var unpublished: Set<String> = []
    private init() {}

    /// A local agent's question that may go to the other devices: a plain
    /// yes or no, answerable anywhere. Mac access, folders, native effects,
    /// and a password manager's unlock need this Mac. A sign-in goes only
    /// to a device that picks the account and proves the yes (version 2).
    static func travels(_ kind: AgentPermit.Kind) -> Bool {
        switch kind {
        case .press, .upload, .use, .messages, .sendMessage, .sendMail, .sendMails, .address, .saveSkill, .signIn, .mailRead, .mailChange, .mailSite: return true
        case .computer, .folder, .native, .unlockManager: return false
        }
    }

    static func lines(_ tab: Tab, _ permit: AgentPermit) -> [String] {
        var lines: [String] = []
        if let host = tab.address?.host() { lines.append(host) }
        if !permit.detail.isEmpty { lines.append(permit.detail) }
        if !permit.amount.isEmpty { lines.append("Amount: \(permit.amount)") }
        if !permit.draft.isEmpty { lines.append(String(permit.draft.prefix(600))) }
        return lines
    }

    func opened(_ tab: Tab, _ permit: AgentPermit, by asker: Asker) {
        // One question a tab: an older one there is over.
        for old in records.values where old.tab == tab.id && old.state == .open && old.kind == .yes { finish(old.id, .skipped) }
        var record = Record(id: UUID().uuidString.lowercased(), assistant: asker.id, session: permit.session,
                            place: .tab(tab.id), kind: .yes, title: "\(asker.name): \(permit.question)",
                            lines: Self.lines(tab, permit), expires: Date().addingTimeInterval(Self.lifetime(for: permit.session)),
                            key: permit.key, local: asker.local)
        if case .signIn(_, let users) = permit.kind { record.choices = Array(users.prefix(3)) }
        keep(record)
        publish(record)
        if let browser = Agents.shared.browser { seen(in: browser) }
    }

    static func mailLines(_ permit: AgentPermit) -> [String] {
        [permit.detail, String(permit.draft.prefix(600))].filter { !$0.isEmpty }
    }

    func opened(mail id: String, _ permit: AgentPermit, by asker: Asker) {
        let record = Record(id: UUID().uuidString.lowercased(), assistant: asker.id, session: permit.session,
                            place: .mail(id), kind: .yes, title: "\(asker.name): \(permit.question)",
                            lines: Self.mailLines(permit), expires: Date().addingTimeInterval(Self.lifetime(for: permit.session)),
                            key: permit.key, local: asker.local)
        keep(record)
        publish(record)
    }

    func settled(mail id: String, _ permit: AgentPermit, yes: Bool) {
        for record in records.values where record.place == .mail(id) && record.state == .open && record.key == permit.key {
            finish(record.id, yes ? .approved : .denied)
        }
    }

    static func lines(_ root: Agents.Session) -> [String] {
        [root.title ?? root.name, root.askedOnce].filter { !$0.isEmpty }
    }

    func opened(chat root: Agents.Session, _ permit: AgentPermit, by asker: Asker) {
        for old in records.values where old.place == .chat(root.id) && old.state == .open { finish(old.id, .skipped) }
        let record = Record(id: UUID().uuidString.lowercased(), assistant: asker.id, session: permit.session,
                            place: .chat(root.id), kind: .yes, title: "\(asker.name): \(permit.question)",
                            lines: Self.lines(root), expires: Date().addingTimeInterval(Self.lifetime(for: permit.session)),
                            key: permit.key, local: asker.local)
        keep(record)
        publish(record)
        if let browser = Agents.shared.browser { seen(in: browser) }
    }

    func settled(chat: String, _ permit: AgentPermit, yes: Bool) {
        for record in records.values where record.place == .chat(chat) && record.state == .open
            && record.session == permit.session && record.key == permit.key { finish(record.id, yes ? .approved : .denied) }
    }

    func seen(_ place: Place, key: String? = nil) {
        for var record in records.values where record.place == place && record.state == .open && !record.seen
            && (key == nil || record.key == key) {
            record.seen = true
            records[record.id] = record
            SyncCenter.shared.seeAssistantApproval(record.id)
        }
    }

    /// A chat's fallback card can stand on a tab when macOS notifications
    /// are unavailable. It still opens the chat question, not a tab record.
    func seen(on tab: Tab) {
        if let permit = tab.permit, permit.place == .chat {
            seen(.chat(Agents.shared.root(of: permit.session) ?? permit.session), key: permit.key)
        } else { seen(.tab(tab.id)) }
    }

    /// Only a card actually in front of the person counts as opened.
    func seen(in browser: Browser) {
        guard NSApp.isActive, BrowserWindows.shared.browser(for: NSApp.keyWindow) === browser else { return }
        if let shown = AskStand.shared.presented[ObjectIdentifier(browser)], shown.actionable,
           case .mail(let id) = shown.held { seen(.mail(id), key: shown.key) }
        if let id = browser.chatID, browser.chatOpen, !browser.chatHistory {
            seen(.chat(id))
            for tab in browser.tabs where tab.permit.map({ Agents.shared.root(of: $0.session) == id }) == true { seen(on: tab) }
        }
        if let tab = browser.active, tab.permit != nil { seen(on: tab) }
    }

    /// Up into Sync now, or, a local one, once Sync is up.
    private func publish(_ record: Record) {
        let sync = SyncCenter.shared
        if let choices = record.choices {
            // A sign-in: to a device that picks the account. An assistant's
            // with one account still goes as a plain yes to an older one.
            if sync.on, sync.state == .live, !sync.assistantChoosers.isEmpty { sync.publishAssistantApproval(record, choices: choices); return }
            if !record.local, choices.count == 1, sync.on { sync.publishAssistantApproval(record); return }
            unpublished.insert(record.id)
            if !sync.on { sync.launchIfNeeded() }
            return
        }
        guard record.local else { sync.publishAssistantApproval(record); return }
        // You at the Mac: it is said here, and goes to the iPhone quiet,
        // in its tray when Yab is opened there but not ringing. It rings
        // once you are away (presence), and is quiet again when you're back.
        let quiet = !AskPresence.shared.away && (!Store.testing || AskPresence.shared.testAway != nil)
        if quiet {
            atMac.insert(record.id)
            AskPresence.shared.watch(true)
        }
        guard sync.on, sync.state == .live else {
            unpublished.insert(record.id)
            sync.launchIfNeeded()
            return
        }
        // Nobody else to answer it, or the devices not read yet: it stays
        // on this Mac until one is there.
        guard !sync.assistantAnswerers.isEmpty else { unpublished.insert(record.id); return }
        sync.publishAssistantApproval(record, quiet: quiet)
    }

    /// Local questions sent quiet while you were at the Mac, to ring
    /// once you are away.
    @ObservationIgnored private var atMac: Set<String> = []
    var holdsAtMac: Bool { !atMac.isEmpty }
    /// Local questions sent to the other devices because you were away.
    @ObservationIgnored private var sentAway: Set<String> = []

    /// Away from the Mac: what waits goes to the iPhone. Back: what went
    /// there for that comes off it, its card still answerable there.
    func presence(away: Bool) {
        if away {
            let waiting = atMac
            atMac = []
            for id in waiting {
                guard let record = records[id], record.state == .open else { continue }
                sentAway.insert(id)
                // Waiting for Sync: it goes, ringing, when Sync is up.
                if unpublished.contains(id) { continue }
                // Opened here already: it stays quiet there.
                if record.seen { continue }
                if !SyncCenter.shared.ringAssistantApproval(id) { publish(record) }
            }
        } else {
            for id in sentAway {
                guard var record = records[id], record.state == .open, !record.seen else { continue }
                record.seen = true
                records[id] = record
                SyncCenter.shared.seeAssistantApproval(id)
            }
            sentAway = []
        }
    }

    /// Sync came up: the local questions that waited for it.
    func publishWaiting() {
        let waiting = unpublished
        unpublished = []
        for id in waiting { if let record = records[id], record.state == .open { publish(record) } }
    }

    /// A tab gone, or a task over: its questions with it.
    func closed(tab: UUID) {
        for record in records.values where record.tab == tab && record.state == .open { finish(record.id, .skipped) }
    }

    func left(session: String) {
        for record in records.values where record.session == session && record.state == .open {
            // An app-owned mail operation remains answerable after its caller ends.
            if case .mail = record.place { continue }
            finish(record.id, .skipped)
        }
    }

    func handed(_ tab: Tab, session: String, reason: String, grant: AssistantGrant) {
        if records.values.contains(where: { $0.tab == tab.id && $0.state == .open && $0.kind == .hands }) { return }
        let record = Record(id: UUID().uuidString.lowercased(), assistant: grant.id, session: session,
                            place: .tab(tab.id), kind: .hands, title: "\(grant.name): \(reason)",
                            lines: [tab.address?.host() ?? ""].filter { !$0.isEmpty },
                            expires: Date().addingTimeInterval(Self.lifetime(for: session)), key: nil)
        keep(record)
    }

    private func keep(_ record: Record) {
        records[record.id] = record
        let id = record.id
        DispatchQueue.main.asyncAfter(deadline: .now() + record.expires.timeIntervalSinceNow + 1) { [weak self] in
            MainActor.assumeIsolated { self?.lapse(id) }
        }
    }

    func settled(_ tab: Tab, _ permit: AgentPermit, yes: Bool) {
        guard let record = records.values.first(where: {
            $0.tab == tab.id && $0.state == .open && $0.kind == .yes && $0.key == permit.key
        }) else { return }
        finish(record.id, yes ? .approved : .denied)
    }

    func handedBack(_ tab: Tab, skipped: Bool) {
        for record in records.values where record.tab == tab.id && record.state == .open && record.kind == .hands {
            finish(record.id, skipped ? .skipped : .done)
        }
    }

    private func finish(_ id: String, _ state: State) {
        guard var record = records[id], record.state == .open else { return }
        record.state = state
        records[id] = record
        unpublished.remove(id)
        if atMac.remove(id) != nil, atMac.isEmpty { AskPresence.shared.watch(false) }
        sentAway.remove(id)
        if record.kind == .yes { SyncCenter.shared.closeAssistantApproval(id) }
        for wake in waiters.removeValue(forKey: id) ?? [] { wake(record) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 600) { [weak self] in
            MainActor.assumeIsolated { _ = self?.records.removeValue(forKey: id) }
        }
    }

    private func lapse(_ id: String) {
        guard let record = records[id], record.state == .open else { return }
        // A local agent's card stays on this Mac: only the other devices'
        // copy of the question goes.
        if !record.local, let tab = Agents.shared.browser?.everyTab.first(where: { $0.id == record.tab }),
           record.kind == .yes, tab.permit?.key == record.key, tab.permit?.session == record.session {
            tab.permit = nil
            Agents.shared.handBack(tab)
        }
        finish(id, .expired)
    }

    func current(tab: UUID?, session: String) -> Record? {
        records.values.filter { $0.state == .open && $0.session == session && (tab == nil || $0.tab == tab) }
            .max { $0.expires < $1.expires }
    }

    func wait(_ id: String, seconds: Double, _ done: @escaping (Record?) -> Void) {
        guard let record = records[id] else { done(nil); return }
        guard record.state == .open, seconds > 0 else { done(record); return }
        var answered = false
        let once: (Record) -> Void = { got in
            guard !answered else { return }
            answered = true
            done(got)
        }
        waiters[id, default: []].append(once)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let now = self.records[id] else { once(record); return }
                once(now)
            }
        }
    }

    /// A payment's card and address picked on the answering device, the
    /// detail's or ones it just kept (docs/approvals.md, "Details").
    struct Picks: Equatable {
        var card: String?
        var place: String?
        var added: [String] = []
        /// When the answer was given, so one refused isn't tried again.
        var at: Double = 0

        init(card: String? = nil, place: String? = nil, added: [String] = [], at: Double = 0) {
            self.card = card; self.place = place; self.added = added; self.at = at
        }

        init(_ answer: AssistantApprovalRecords.Answer) {
            self.init(card: answer.card, place: answer.place, added: answer.added ?? [], at: answer.at)
        }

        var any: Bool { card != nil || place != nil }
    }

    /// Picks being put into a page, by request: its answer isn't taken twice.
    @ObservationIgnored private var applying: Set<String> = []

    /// Only a reply opened from the sealed Sync journal by an enrolled device
    /// reaches here. The pending permit is checked again before its one yes.
    /// A sign-in's yes names the account; proven on that device, the fill
    /// here doesn't ask for Touch ID again. A payment's yes may name a card
    /// and an address: put into the page before the press, as a click in the
    /// pay sheet's lists would.
    func answerFromSync(_ request: AssistantApprovalRecords.Request, yes: Bool, choice: String? = nil, proved: Bool = false,
                        picks: Picks = Picks()) {
        guard !applying.contains(request.id), !ApprovalDetails.shared.refused(request.id, at: picks.at) else { return }
        guard let record = records[request.id], record.state == .open, record.kind == .yes,
              record.assistant == request.assistant, record.session == request.session,
              record.place.wire.lowercased() == request.tab.lowercased(), record.key == request.permit,
              record.title == request.title, record.lines == request.lines,
              request.choices == nil || request.choices == record.choices else { return }
        if record.local, Agents.shared.browser?.prefs.agentsAskElsewhere == false { return }
        if case .mail(let id) = record.place {
            guard let pending = Agents.shared.mailRequest(id), pending.permit.session == record.session,
                  pending.permit.key == record.key, Self.mailLines(pending.permit) == request.lines else { return }
            if yes { ApprovalDetails.shared.answered(request.id, tab: nil, permit: pending.permit) }
            Agents.shared.answerMail(id, yes: yes)
            return
        }
        if case .chat(let id) = record.place {
            guard let root = Agents.shared.session(id), let permit = root.permit,
                  permit.session == record.session, permit.key == record.key else { return }
            if yes { ApprovalDetails.shared.answered(request.id, tab: nil, permit: permit) }
            // Its card here says so a moment before it goes (AskStand).
            AskStand.shared.said(permit, tab: nil, words: yes ? "Allowed on iPhone" : "Not now on iPhone", good: yes)
            Agents.shared.answer(chat: id, yes: yes, key: permit.key)
            return
        }
        guard let tab = Agents.shared.browser?.everyTab.first(where: { $0.id == record.tab }),
              let permit = tab.permit, permit.session == record.session, permit.key == record.key,
              Self.lines(tab, permit) == request.lines else { return }
        // Settings › Agents turned off since it was asked: only this Mac answers.
        if record.local, Agents.shared.browser?.prefs.agentsAskElsewhere == false { return }
        if yes, picks.any, permit.isPayment, let flow = Payments.shared.flow(tab) {
            let id = request.id
            applying.insert(id)
            flow.takePicks(card: picks.card, place: picks.place, added: Set(picks.added)) { [weak self, weak tab] ok in
                guard let self else { return }
                self.applying.remove(id)
                guard let tab, let now = self.records[id], now.state == .open, let live = tab.permit,
                      live.session == permit.session, live.key == permit.key else { return }
                guard ok else {
                    // The card never reached this Mac: nothing is paid,
                    // and the question stays here.
                    ApprovalDetails.shared.refuse(id, at: picks.at, words: "That card isn’t on your Mac yet. Try again.")
                    return
                }
                ApprovalDetails.shared.answered(id, tab: tab, permit: live)
                Agents.shared.answer(tab, yes: true)
            }
            return
        }
        // Its card here says so a moment before it goes; a send's says
        // Sending itself.
        if !(yes && permit.sends) {
            AskStand.shared.said(permit, tab: tab, words: yes ? "Allowed on iPhone" : "Not now on iPhone", good: yes)
        }
        guard case .signIn(let site, _) = permit.kind, yes else {
            if yes { ApprovalDetails.shared.answered(request.id, tab: tab, permit: permit) }
            Agents.shared.answer(tab, yes: yes)
            return
        }
        // Sent as a plain yes (one account, an older device): that account.
        guard let user = choice ?? (record.choices?.count == 1 ? record.choices?.first : nil),
              record.choices?.contains(user) == true else { return }
        if proved { Vault.provenElsewhere = (site, Date()) }
        ApprovalDetails.shared.answered(request.id, tab: tab, permit: permit)
        Agents.shared.answer(tab, yes: true, as: user)
    }
}
