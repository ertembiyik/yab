import AppKit
import Foundation
import Observation

/// One immutable outgoing operation, with as many callers as asked for it.
/// A tab is only a page; neither it nor the caller owns a pending send.
@MainActor @Observable
final class MailSendAsk {
    let id = UUID().uuidString.lowercased()
    let permit: AgentPermit
    let outs: [MailAgent.Outgoing]
    let hold: TimeInterval?
    @ObservationIgnored var callers: Set<String>
    @ObservationIgnored var calls: [String: Set<String>] = [:]
    var phase: AskPhase = .ready
    @ObservationIgnored var result: [String: Any]?
    @ObservationIgnored var task: Task<[String: Any], Never>?
    @ObservationIgnored var results: [[String: Any]?]
    @ObservationIgnored var kept: [String?]
    let connected: [Bool]

    init(_ outs: [MailAgent.Outgoing], permit: AgentPermit, hold: TimeInterval?) {
        self.outs = outs; self.permit = permit; self.hold = hold
        callers = [permit.session]
        results = Array(repeating: nil, count: outs.count)
        kept = outs.map { out in out.engine.store.draft(out.draft.id).map { draft in
            var current = out; current.draft = draft; return current.key
        } }
        connected = outs.map { MailCenter.shared.engines[$0.engine.account]?.store === $0.engine.store }
    }

    var waiting: [String: Any] {
        ["asking": true, "mailAsk": id, "question": permit.question,
         "error": "sending waits for the person's yes; asking them now"]
    }
}

extension Agents {
    func mailRequest(_ id: String) -> MailSendAsk? { mailRequests.first { $0.id == id } }

    private func mailSource(_ out: MailAgent.Outgoing) -> String {
        out.engine.account + "|" + (MailDesk.place(of: out.draft.id, thread: out.draft.thread) ?? out.draft.id)
    }

    func queueMail(_ outs: [MailAgent.Outgoing], session: String, hold: TimeInterval?, call: String? = nil) async -> [String: Any] {
        guard !outs.isEmpty else { return ["error": "no mails to send"] }
        let permit: AgentPermit
        if outs.count == 1, let out = outs.first {
            permit = AgentPermit(kind: .sendMail(to: out.to, mail: out.key), session: session,
                                 detail: out.detail, draft: out.draft.body)
        } else {
            permit = AgentPermit(kind: .sendMails(count: outs.count, mail: MailAgent.batchKey(outs)), session: session,
                                 detail: "To " + outs.map(\.to).joined(separator: "; "), draft: MailAgent.batchDraft(outs))
        }
        if Headless.nobody || self.session(session)?.unattended == true {
            return ["error": Bench.declinedWords(permit.kind)]
        }
        pruneMailReceipts()
        if let receipt = mailReceipts.values.first(where: { $0.permit.key == permit.key && $0.callers.contains(session) }) {
            if let task = receipt.task { return consumeMail(receipt, session: session, result: await task.value) }
            if let result = receipt.result { return consumeMail(receipt, session: session, result: result) }
            return receipt.waiting
        }
        if let same = mailRequests.first(where: { $0.permit.key == permit.key }) {
            same.callers.insert(session)
            if let call { same.calls[session, default: []].insert(call) }
            if let task = same.task { return consumeMail(same, session: session, result: await task.value) }
            if let result = same.result { return consumeMail(same, session: session, result: result) }
            return same.waiting
        }
        if let held = mailReceipts.values.first(where: { $0.permit.key == permit.key && $0.result != nil && mailClaimActive($0) }),
           let result = held.result {
            // The approved mail may still be in its Undo / Send Later window.
            // Another exec shares that send, rather than scheduling it twice.
            return result
        }
        let sources = Set(outs.map(mailSource))
        guard sources.count == outs.count else { return ["error": "the same draft appears more than once in this send"] }
        // Two different decisions cannot own the same draft simultaneously.
        // An identical operation joined above; changed mail needs a fresh yes.
        let claimed = mailRequests + mailReceipts.values.filter { mailClaimActive($0) }
        guard !claimed.contains(where: { !sources.isDisjoint(with: $0.outs.map(mailSource)) }) else {
            return ["error": "a send for this draft is already waiting in Yab; answer or dismiss that card before asking for changed mail"]
        }
        let request = MailSendAsk(outs, permit: permit, hold: hold)
        if let call { request.calls[session, default: []].insert(call) }
        ApprovalDetails.shared.outgoing[permit.key] = outs
        mailReceipts[request.id] = request
        mailRequests.append(request)
        if let caller = self.session(session), caller.state == .running { caller.state = .waiting }
        if self === Agents.shared {
            AgentNotices.shared.mailAsked(request.id, permit)
            if let asker = asker(permit) { AssistantApprovals.shared.opened(mail: request.id, permit, by: asker) }
        }
        return request.waiting
    }

    /// A completed tool call is found before rebuilding its outgoing draft:
    /// the approved operation may already have removed or renamed that draft.
    static func mailCall(_ request: [String: Any]) -> String? {
        let keys = ["mails", "draft", "thread", "body", "all", "forward", "at", "rsvp"]
        var input: [String: Any] = [:]
        for key in keys { if let value = request[key] { input[key] = value } }
        return (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) }
    }

    func completedMailCall(_ call: String?, session: String) async -> [String: Any]? {
        guard let call, let request = mailReceipts.values.first(where: { $0.calls[session]?.contains(call) == true }) else { return nil }
        if let task = request.task { return consumeMail(request, session: session, result: await task.value) }
        guard let result = request.result else { return nil }
        return consumeMail(request, session: session, result: result)
    }

    private func mailClaimActive(_ request: MailSendAsk) -> Bool {
        guard request.result != nil else { return false }
        return request.outs.contains { out in
            out.engine.store.allOps().contains { op in
                guard op.kind == .send, let draft = out.engine.store.draft(op.thread) else { return false }
                var held = out; held.draft = draft
                return mailSource(held) == mailSource(out)
            }
        }
    }

    private func pruneMailReceipts() {
        for request in Array(mailReceipts.values) where request.result != nil && request.callers.isEmpty
            && mailRequest(request.id) == nil && !mailClaimActive(request) {
            mailReceipts[request.id] = nil
        }
    }

    private func consumeMail(_ request: MailSendAsk, session: String, result: [String: Any]) -> [String: Any] {
        request.callers.remove(session)
        request.calls[session] = nil
        if request.callers.isEmpty, mailRequest(request.id) == nil, !mailClaimActive(request) { mailReceipts[request.id] = nil }
        return result
    }

    /// Used by the existing MCP patient wait. It reads this operation's own
    /// result instead of calling mail_send again against an already-sent draft.
    func mailStatus(_ id: String, session: String?) -> [String: Any] {
        guard let request = mailReceipts[id], let session, request.callers.contains(session) else {
            return ["state": "done", "result": ["error": "no mail approval for this caller"]]
        }
        if let result = request.result { return ["state": "done", "result": result] }
        return ["state": "waiting", "question": request.permit.question]
    }

    /// Ending a CLI detaches its receipt, not the app-owned pending action.
    func forgetMailCaller(_ session: String) {
        for request in Array(mailReceipts.values) {
            request.callers.remove(session)
            request.calls[session] = nil
            if request.callers.isEmpty, mailRequest(request.id) == nil, !mailClaimActive(request) { mailReceipts[request.id] = nil }
        }
    }

    func answerMail(_ id: String, yes: Bool) {
        guard let request = mailRequest(id), request.task == nil else { return }
        if !yes {
            request.result = ["error": Bench.declinedWords(request.permit.kind)]
            finishMail(request, yes: false)
            return
        }
        if self === Agents.shared { AssistantApprovals.shared.settled(mail: request.id, request.permit, yes: true) }
        request.result = nil
        request.phase = .going(since: Date())
        for caller in request.callers {
            if let session = session(caller), session.state == .waiting {
                session.state = session.process != nil ? .running : session.agent == .external ? .attached : .signingIn
            }
        }
        request.task = Task { @MainActor in
            let hold = request.hold ?? MailCenter.undoSend
            for index in request.outs.indices where request.results[index] == nil || request.results[index]?["error"] != nil {
                let out = request.outs[index]
                let current = out.engine.store.draft(out.draft.id).map { draft in
                    var current = out; current.draft = draft; return current.key
                }
                let accountPresent = !request.connected[index] || MailCenter.shared.engines[out.engine.account]?.store === out.engine.store
                let message = out.engine.store.sensed(out.draft.thread)?.message ?? ""
                let readyPresent = out.ready.map { ready in
                    [message, ""].contains { out.engine.store.ahead(out.draft.thread, message: $0).contains(ready) }
                } ?? true
                if !accountPresent {
                    request.results[index] = ["error": "the mail account was disconnected; nothing was sent"]
                } else if current != request.kept[index] || (current == nil && !readyPresent) {
                    request.results[index] = ["error": "the draft changed while its card waited; review the current draft and ask to send it again"]
                } else {
                    request.results[index] = await MailAgent.send(out, hold: hold)
                    // A failed send may have materialized its unchanged draft.
                    // An explicit press on the existing failure card can use it;
                    // successful members of a batch are never dispatched again.
                    if request.results[index]?["error"] != nil,
                       let saved = out.engine.store.draft(out.draft.id) {
                        var savedOut = out; savedOut.draft = saved
                        if savedOut.key == out.key { request.kept[index] = savedOut.key }
                    }
                }
            }
            let results = request.results.compactMap { $0 }
            let trouble = results.compactMap { $0["error"] as? String }.first
            let result: [String: Any]
            if results.count == 1 { result = results[0] }
            else {
                var many: [String: Any] = ["text": results.enumerated().map { "\($0.offset + 1). \($0.element["text"] ?? $0.element["error"] ?? "")" }.joined(separator: "\n"),
                                          "count": results.count, "sending": trouble == nil]
                if let trouble { many["error"] = trouble }
                result = many
            }
            request.result = result
            request.task = nil
            if let trouble {
                request.phase = .failed(trouble)
            } else {
                let drafts = results.compactMap { $0["sending"] as? Bool == true ? $0["draft"] as? String : nil }
                if drafts.count == results.count, !drafts.isEmpty, self === Agents.shared {
                    AskStand.shared.sending(request.permit, outs: request.outs, drafts: drafts, hold: hold)
                }
                finishMail(request, yes: true)
            }
            if self === Agents.shared { ApprovalDetails.shared.ran(request.permit, trouble: trouble) }
            return result
        }
    }

    private func finishMail(_ request: MailSendAsk, yes: Bool) {
        if self === Agents.shared {
            AgentNotices.shared.mailAnswered(request.id)
            AssistantApprovals.shared.settled(mail: request.id, request.permit, yes: yes)
        }
        mailRequests.removeAll { $0.id == request.id }
        if request.callers.isEmpty, !mailClaimActive(request) { mailReceipts[request.id] = nil }
    }
}
