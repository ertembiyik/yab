import AppKit
import WebKit

// Bench.agentCommand's verbs (AgentBench). Mail: the agent's mail tools and
// the bench's words for mail's own state.

extension Bench {
    static let mailVerbs: [String: AgentHandler] = [
        "agent-mail-triage": { $0.handleAgentMailTriage($1) },
        "agent-mail-search": { $0.handleAgentMailTriage($1) },
        "agent-mail-read": { $0.handleAgentMailTriage($1) },
        "agent-mail-draft": { $0.handleAgentMailTriage($1) },
        "agent-mail-act": { $0.handleAgentMailTriage($1) },
        "agent-mail-recall": { $0.handleAgentMailTriage($1) },
        "agent-mail-file": { $0.handleAgentMailTriage($1) },
        "agent-mail-labels": { $0.handleAgentMailTriage($1) },
        "agent-mail-send": { $0.handleAgentMailTriage($1) },
        "agent-mail-snippets": { $0.handleAgentMailTriage($1) },
        "agent-mail-list": { $0.handleAgentMailTriage($1) },
        "agent-mail-accounts": { $0.handleAgentMailAccounts($1) },
        "agent-mail-code": { $0.handleAgentMailCode($1) },
        "agent-mail-code-state": { $0.handleMailCodeState($1) },
        "agent-mail-account": { $0.handleAgentMailAccount($1) },
        "agent-mail-settings": { $0.handleAgentMailSettings($1) },
        "agent-mail-memory": { $0.handleAgentMailMemory($1) },
        "agent-mail-reads": { $0.handleAgentMailReads($1) },
        "agent-mail-sendas": { $0.handleAgentMailSendas($1) },
        "agent-mail-sync": { $0.handleAgentMailSync($1) },
        "agent-mail-hold": { $0.handleAgentMailHold($1) },
        "agent-mail-state": { $0.handleAgentMailState($1) },
        "agent-mail-notify": { $0.handleAgentMailNotify($1) },
        "agent-mail-notify-act": { $0.handleAgentMailNotifyAct($1) },
        "agent-mail-time-shift": { $0.handleAgentMailTimeShift($1) },
        "agent-mail-body": { $0.handleAgentMailBody($1) },
        "agent-mail-writer-fake": { $0.handleAgentMailWriterFake($1) },
        "agent-mail-fake": { $0.handleAgentMailFake($1) },
    ]

    func handleAgentMailTriage(_ c: AgentCall) {
        let verb = c.verb
        let request = c.request
        let browser = c.browser
        let answer = c.answer
        let agents = c.agents
        let session = c.session
        // The mail kept on this Mac (docs/mail.md, Mail for agents).
        let center = MailCenter.shared
        guard center.connected else { answer(["error": "no mail account is connected in yab; use the gmail skill, or call handoff"]); return }
        // Mail you hand to Claude off: Yab's own chat asks for the person's
        // yes for this chat (mailAsks); another app's agent is refused.
        let own = session.flatMap { agents.session($0) }.map { $0.cli != "external" } ?? false
        guard MailCenter.agentsAllowed || own else { answer(["error": "the person turned off agents working on their mail in Settings › Mail"]); return }
        guard !agents.offMail(session) else { answer(["error": "this task has no mail: one started from the phone or getting to know the user doesn't read it"]); return }
        // The person's yes first, as often as the call weighs (mailAsks).
        if mailAsks(c) { return }
        if let session { agents.touch(session, "mail") }
        agents.session(session)?.mail = true
        switch verb {
        case "agent-mail-triage":
            answer(["text": MailAgent.triage(center)])
        case "agent-mail-search":
            // Gmail may be asked too (MailServerSearch): a moment, inside the call's time.
            Task {
                answer(["text": await MailAgent.search(center, request["query"] as? String ?? "", limit: Int(request["limit"] as? Double ?? 10))])
            }
        case "agent-mail-read":
            // A kept draft whole, and whether it went.
            if let draft = request["draft"] as? String, !draft.trimmingCharacters(in: .whitespaces).isEmpty {
                answer(MailAgent.draftWhole(center, draft)); return
            }
            let id = (request["thread"] as? String ?? "").split(separator: "|").last.map(String.init) ?? ""
            guard let engine = MailAgent.engine(holding: request["thread"] as? String ?? "", in: center.engines.values)?.engine else {
                // Older than the store keeps, found by mail_recall.
                Task { answer(await MailRecall.shared.read(request["thread"] as? String ?? "")) }
                return
            }
            Task {
                try? await engine.sync.open(thread: id)
                // Invitations that came as files, read first: mail_read says them.
                await MailInvites.fetch(thread: id, engine: engine)
                answer(["text": MailAgent.read(engine.store, thread: id)])
            }
        case "agent-mail-recall":
            guard MailRecall.wanted else { answer(["error": "the person turned off agents searching all their mail in Settings › Mail"]); return }
            let day = ISO8601DateFormatter()
            day.formatOptions = [.withFullDate]
            let date = { (key: String) -> Date? in
                (request[key] as? String).flatMap { ISO8601DateFormatter().date(from: $0) ?? day.date(from: String($0.prefix(10))) }
            }
            let from = (request["from"] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            Task {
                let text = await MailRecall.shared.answer(request["query"] as? String ?? "", from: from, after: date("after"),
                                                          before: date("before"), limit: Int(request["limit"] as? Double ?? 20))
                answer(["text": text])
            }
        case "agent-mail-act":
            // Off a list: its one click or its mail is the network's, a moment.
            if request["act"] as? String == "unsubscribe" {
                Task { answer(await MailAgent.unsubscribe(center, request)) }
                return
            }
            answer(MailAgent.act(center, request))
        case "agent-mail-list":
            answer(MailAgent.list(center, request))
        case "agent-mail-snippets":
            answer(["text": MailAgent.snippets(MailSnippets.shared.ordered)])
        case "agent-mail-labels":
            // The list read by anyone; changed only in a chat the person is
            // in, never by a subagent or a task nobody watches.
            if (request["act"] as? String ?? "list") != "list", let asker = agents.session(session),
               asker.parent != nil || asker.unattended {
                answer(["error": "the person's labels change only in a chat they are in: say what you would change in your answer"]); return
            }
            Task { answer(await MailAgent.labels(center, request)) }
        case "agent-mail-send" where request["undo"] as? Bool == true:
            // Taken back while it waits: nothing goes, so no card.
            answer(MailAgent.takeBack(center, request))
        case "agent-mail-send":
            // A mail the person asked to go (mail_send): only what is in
            // the mail page already, only for a chat they are in, and
            // after their yes on a card, in every mode. AgentPermit binds
            // a yes to every address and the words, so a changed word asks again.
            guard let session, let asker = agents.session(session) else { answer(["error": "no task to send for"]); return }
            if let why = Bench.sendRefusal(asker, what: "a mail") { answer(["error": why]); return }
            let call = Agents.mailCall(request)
            // Several at once (mails): one card listing each, one yes for all.
            if let many = request["mails"] as? [[String: Any]] {
                guard !many.isEmpty, many.count <= 20 else { answer(["error": "mails takes 1 to 20 mails"]); return }
                Task { @MainActor in
                    if let receipt = await agents.completedMailCall(call, session: session) { answer(receipt); return }
                    var outs: [MailAgent.Outgoing] = []
                    for (index, one) in many.enumerated() {
                        var later: Date?
                        if let said = one["at"] as? String, !said.trimmingCharacters(in: .whitespaces).isEmpty {
                            guard let at = MailAgent.when(said) else { answer(["error": "mail \(index + 1): at is when it goes, ahead of now"]); return }
                            later = at
                        }
                        let (made, why) = await MailAgent.outgoing(Array(center.engines.values), one)
                        guard var out = made else { answer(["error": "mail \(index + 1): " + why]); return }
                        out.at = later
                        outs.append(out)
                    }
                    answer(await agents.queueMail(outs, session: session, hold: nil, call: call))
                }
                return
            }
            var later: Date?
            if let said = request["at"] as? String, !said.trimmingCharacters(in: .whitespaces).isEmpty {
                guard let at = MailAgent.when(said) else {
                    answer(["error": "at is when it goes, ahead of now: 2026-10-20T09:00 (local), or words (\"tomorrow 9am\", \"monday\")"]); return
                }
                later = at
            }
            Task { @MainActor in
                if let receipt = await agents.completedMailCall(call, session: session) { answer(receipt); return }
                let (made, why) = await MailAgent.outgoing(Array(center.engines.values), request)
                guard var out = made else { answer(["error": why]); return }
                out.at = later
                answer(await agents.queueMail([out], session: session, hold: nil, call: call))
            }
        case "agent-mail-file":
            // A file of a thread kept here, its words (mail_file).
            let id = (request["thread"] as? String ?? "").split(separator: "|").last.map(String.init) ?? ""
            guard let engine = MailAgent.engine(holding: request["thread"] as? String ?? "", in: center.engines.values)?.engine else {
                answer(["error": "no thread \(id) on this Mac: mail_file reads the files of threads mail_read finds here"]); return
            }
            let index = (request["index"] as? Double).map { Int($0) } ?? request["index"] as? Int
            Task {
                try? await engine.sync.open(thread: id)
                answer(await MailAgent.file(engine, thread: id, name: request["name"] as? String, index: index))
            }
        default:
            // A reply's people (its Reply-To) are in the whole thread: read
            // first when the draft keeps them, as mail_send reads it.
            let key = request["thread"] as? String ?? ""
            if !key.isEmpty, request["draft"] == nil, let engine = MailAgent.engine(holding: key, in: center.engines.values)?.engine {
                Task { @MainActor in
                    try? await engine.sync.open(thread: key.split(separator: "|").last.map(String.init) ?? key)
                    self.drafted(MailAgent.draft(center, request), session: session, agents: agents, answer: answer)
                }
                return
            }
            drafted(MailAgent.draft(center, request), session: session, agents: agents, answer: answer)
        }
    }

    /// mail_accounts: listed while agents may work on mail, before any
    /// account is in too, so an agent can connect the first one.
    func handleAgentMailAccounts(_ c: AgentCall) {
        let request = c.request
        let answer = c.answer
        let agents = c.agents
        let session = c.session
        guard MailCenter.agentsAllowed else { answer(["error": "the person turned off agents working on their mail in Settings › Mail"]); return }
        guard !agents.offMail(session) else { answer(["error": "this task has no mail: one started from the phone or getting to know the user doesn't read it"]); return }
        if (request["act"] as? String ?? "list") == "add" {
            // Only in a chat the person is in: they choose and allow.
            guard let session, let asker = agents.session(session), asker.parent == nil, !asker.unattended else {
                answer(["error": "an account is added only in a chat the person is in: say what to connect in your answer"]); return
            }
            agents.touch(session, "mail · account")
        }
        Task { @MainActor in answer(await MailAgent.accounts(MailCenter.shared, request, session: session, browser: c.browser)) }
    }

    /// A draft's answer, its chat told where the reply is so it goes to it.
    private func drafted(_ got: [String: Any], session: String?, agents: Agents, answer: @escaping ([String: Any]) -> Void) {
        if let key = got["thread"] as? String, let session, let root = agents.session(agents.root(of: session)),
           !root.mailDrafts.contains(key) {
            root.mailDrafts.append(key)
        }
        answer(got)
    }

    func handleAgentMailCode(_ c: AgentCall) {
        let request = c.request
        let browser = c.browser
        let answer = c.answer
        let agents = c.agents
        let session = c.session
        func own(going: Bool = false, asking: Bool = false) -> Tab? { c.own(going: going, asking: asking) }
        // The code the tab's own site mailed, from Gmail's unread feed
        // with the tab's sign-in (MailCodes.swift). Only that site's:
        // a task on one site never reads another's codes, or the mail.
        guard browser.prefs.mailCodes else {
            answer(["error": "reading codes from Gmail is off; the person can turn it on in Settings › Autofill, or call handoff"])
            return
        }
        guard let tab = own(), let session else { return }
        guard let host = tab.address?.host() else {
            answer(["error": "the tab has no page yet"]); return
        }
        // Keep WebKit's existing absent-page refusal without materializing
        // a view. Connected Chromium mail does not need a WK cookie store.
        if tab.engineKind == .webKit, tab.builtPage?.webKit == nil {
            answer(["error": "the tab has no page yet"]); return
        }
        let minutes = min(request["minutes"] as? Double ?? 10, 30)
        agents.touch(session, "mail · code")
        mailedCodes(for: tab, minutes: minutes) { payload in
            let json = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            answer(["codes": payload, "text": payload.isEmpty
                ? "No code from \(Vault.registrable(host)) in Gmail in the last \(Int(minutes)) minutes."
                : json])
        }
    }

    /// The one-time codes the tab's own site mailed, shaped as mail_code
    /// returns them, so a snapshot can surface them the way autofill does
    /// without a separate call. Only that site's, only `mine`; `done([])`
    /// when there is no page or none fits. The caller gates the pref
    /// (prefs.mailCodes), as mail_code and the snapshot both do.
    func mailedCodes(for tab: Tab, minutes wanted: Double = 10, then done: @escaping ([[String: Any]]) -> Void) {
        guard let host = tab.address?.host() else { done([]); return }
        if tab.engineKind == .webKit, tab.builtPage?.webKit == nil { done([]); return }
        let center = MailCenter.shared
        let minutes = min(wanted, 30)
        let read: (@escaping ([Mailed]) -> Void) -> Void
        if center.connected {
            // Connected Mail already owns this source. It does not use the
            // tab's browser cookies and must work on either page engine.
            read = { fin in center.quick(for: 20); fin(center.recent(minutes: minutes)) }
        } else {
            // The tab's own cookie store, on either page engine.
            let store = tab.pageStore
            read = { fin in MailCodes.unread(store: store, done: fin) }
        }
        read { mail in
            let since = Date().addingTimeInterval(-minutes * 60)
            let codes = MailCodes.codes(in: mail.filter { $0.at > since }, for: host).filter(\.mine).filter { MailCodeState.shared.available($0) }
            done(codes.map { code in
                var out: [String: Any] = ["code": code.code, "from": code.from]
                if let read = code.read {
                    out["purpose"] = read.purpose.rawValue
                    if let amount = read.amount { out["amount"] = amount }
                    if let merchant = read.merchant { out["merchant"] = merchant }
                    if let card = read.card { out["card"] = card }
                    let expiry = read.expires ?? (code.at ?? Date()).addingTimeInterval(MailCodes.fresh)
                    out["expires"] = ISO8601DateFormatter().string(from: expiry)
                }
                return out
            })
        }
    }

    /// A test world can inspect and exercise the same actions as Mail's controls.
    func handleMailCodeState(_ c: AgentCall) {
        guard Store.testing else { c.answer(["error": "test world only"]); return }
        if let theme = c.request["theme"] as? String {
            NSApp.appearance = NSAppearance(named: theme == "dark" ? .darkAqua : .aqua)
        }
        let account = c.request["account"] as? String ?? "me@example.com"
        let thread = c.request["thread"] as? String ?? ""
        guard let item = MailCodeState.shared.item(account: account, thread: thread) else {
            c.answer(["error": "no parsed code"]); return
        }
        let codes = MailCodeState.shared
        switch c.request["act"] as? String {
        case "copy": codes.copy(item)
        case "forgetCopy": CodeClip.shared.tick(now: .distantFuture)
        case "selectWords", "clearSelection":
            if let web = MailBodyView.live.allObjects.first(where: { $0.message == item.message }) {
                web.window?.makeFirstResponder(web)
                let script = c.request["act"] as? String == "selectWords"
                    ? "var range = document.createRange(); range.selectNodeContents(document.querySelector('h2')); getSelection().removeAllRanges(); getSelection().addRange(range); true"
                    : "getSelection().removeAllRanges(); true"
                web.evaluateJavaScript(script, completionHandler: nil)
            }
        case "fill":
            if let tab = c.browser.codeBox(for: item) { c.browser.fillCode(item, into: tab) }
        default: break
        }
        let deadline = (c.request["wait"] as? Double ?? 0.2)
        DispatchQueue.main.asyncAfter(deadline: .now() + deadline) {
            let board = NSPasteboard.general
            c.answer(["state": codes.state(item).rawValue, "code": item.read.code, "shown": item.read.shown,
                      "purpose": item.read.purpose.rawValue, "message": item.message,
                      "destination": c.browser.codeBox(for: item)?.address?.host() ?? "",
                      "clipboardEmpty": board.string(forType: .string) == nil,
                      "clipboardMatchesCode": board.string(forType: .string) == item.read.code,
                      "concealed": board.types?.contains(.init("org.nspasteboard.ConcealedType")) == true])
        }
    }

    func handleAgentMailAccount(_ c: AgentCall) {
        let request = c.request
        let browser = c.browser
        let answer = c.answer
        // A test world's Gmail: an account whose Gmail is a fake one on
        // this Mac (evals/mail/fake_gmail.py), a --test run only; with
        // `remove`, that account disconnected, as Settings › Mail does.
        if Store.testing, request["remove"] as? Bool == true, let account = (request["account"] as? String)?.lowercased() {
            MailCenter.shared.disconnect(account)
            Store.settings.removeObject(forKey: "mail.fake." + account)
            answer(["ok": true, "accounts": MailCenter.shared.accounts])
            return
        }
        guard Store.testing, let base = (request["base"] as? String).flatMap(URL.init(string:)) else {
            answer(["error": "agent-mail-account only works on a --test run, with a base"]); return
        }
        let account = (request["account"] as? String ?? "me@example.com").lowercased()
        // Kept for `yab mail flush`, which reaches the same fake with yab closed.
        Store.settings.set(base.absoluteString, forKey: "mail.fake." + account)
        browser.prefs.usesMail = true
        // `pace`: Gmail's quota kept as a real account's is (MailPace), for
        // what is timed against it (the first screen after Connect).
        let pace = request["pace"] as? Bool == true ? MailPace(burst: MailPace.burst) : nil
        // `calendars`: its consent gave the calendar list too, so every
        // calendar the fake lists is read (MeetingsGoogle.calendars).
        Store.settings.set(request["calendars"] as? Bool == true, forKey: MeetingsGoogle.listKey(account))
        MeetingsGoogle.forget(account)
        MailCenter.shared.add(account, gmail: MailGmail(base: base, token: { "fake" }, tries: 2, wait: 0.1, pace: pace))
        MailCenter.shared.pinOnce(in: browser)
        Meetings.shared.start()
        answer(["ok": true, "account": account, "at": Date().timeIntervalSince1970])
    }

    func handleAgentMailSettings(_ c: AgentCall) {
        let request = c.request
        let browser = c.browser
        let answer = c.answer
        // Settings › Mail's way in on a --test run: the Google accounts
        // "found" in the spaces, and a state Google alone would bring.
        guard Store.testing else { answer(["error": "agent-mail-settings only works on a --test run"]); return }
        if let found = request["found"] as? [[String: String]] {
            MailFound.fake = found.map { one in
                MailFound.Account(email: one["email"] ?? "", name: one["name"] ?? "", photo: nil,
                                  space: browser.spaces.first { $0.name == one["space"] }?.id ?? Space.firstID)
            }
            Task { await MailFound.shared.look(browser) }
        }
        if let on = request["on"] as? Bool { browser.prefs.usesMail = on }
        // Google's real consent page in the Mac's sign-in sheet, for a test world connected
        // to a real account: its address can be answered from anywhere.
        if request["connect"] as? Bool == true {
            if let problem = MailCenter.shared.gmailConnectionProblem(expectedAccount: nil) { answer(["error": problem]); return }
            browser.prefs.usesMail = true
            guard MailCenter.shared.connect(in: browser) else { answer(["ok": false]); return }
        }
        if let state = request["state"] as? String { MailCenter.shared.bench(state, account: request["account"] as? String) }
        // The warning before Google's page, as Connect asks it.
        if request["warn"] as? Bool == true { Task { _ = await MailClient.warnFirst(place: .settings) } }
        answer(["ok": true, "found": MailFound.shared.accounts.map(\.email), "arriving": MailArrival.shows,
                "signIn": MailCenter.shared.signInShown])
    }

    func handleAgentMailMemory(_ c: AgentCall) {
        let request = c.request
        let answer = c.answer
        // The mail memory (MailRecall): how far each account's is, and
        // on a --test run a go by hand, on, off, pause, disconnect.
        MailRecall.shared.bench(request, answer)
    }

    func handleAgentMailReads(_ c: AgentCall) {
        let request = c.request
        let answer = c.answer
        // Read statuses in a test world (MailReads): turned on or off for
        // an account (`on`), Block tracking pixels as its switch turns it
        // (`pixels`), a key kept for mail of yours sent before, as a send
        // keeps it (`keep`: its Message-ID, thread, and how long `ago`,
        // for a list days have to pass for), the site asked now (`ask`, a
        // `thread`'s alone or all); then each account's keys, their
        // tokens, and what the site said of each, as the thread says it.
        guard Store.testing else { answer(["error": "agent-mail-reads only works on a --test run"]); return }
        let center = MailCenter.shared
        let accounts = (request["account"] as? String).map { [$0] } ?? center.accounts
        if let on = request["on"] as? Bool {
            for account in accounts { center.engines[account].map { MailReads.set(on, in: $0.store) } }
            center.touch()
        }
        if let pixels = request["pixels"] as? Bool { MailHTML.blocksPixels = pixels }
        var made: [String: Any] = [:]
        if let keep = request["keep"] as? [String: Any], let message = keep["message"] as? String,
           let store = accounts.first.flatMap({ center.engines[$0]?.store }) {
            let at = MailClock.now.addingTimeInterval(-((keep["ago"] as? Double) ?? 0))
            let key = store.readKey(message: message, at: at) { MailReads.encoded(MailReads.newKey()) } ?? ""
            store.readSent(message: message, thread: keep["thread"] as? String ?? "", at: at)
            made = ["key": key, "token": MailReads.token(for: key) ?? ""]
        }
        Task {
            var news = false
            if request["ask"] as? Bool == true {
                for account in accounts { news = await center.askReads(account, thread: request["thread"] as? String) || news }
            }
            var kept: [String: Any] = [:]
            for account in accounts {
                guard let store = center.engines[account]?.store else { continue }
                let keys = store.readKeys(since: .distantPast)
                let seen = MailReads.seen(keys.map(\.message), in: store)
                kept[account] = ["on": MailReads.on(store), "base": MailReads.base.absoluteString,
                                 "keys": keys.map { one -> [String: Any] in
                                     ["message": one.message, "key": one.key, "token": MailReads.token(for: one.key) ?? "",
                                      "thread": one.thread, "line": seen[one.message].map { MailReads.line($0) } ?? "",
                                      "opens": seen[one.message].map { $0.sure + $0.maybe } ?? 0]
                                 }]
            }
            answer(["accounts": kept, "news": news, "pixels": MailHTML.blocksPixels, "kept": made])
        }
    }

    func handleAgentMailSendas(_ c: AgentCall) {
        let answer = c.answer
        // Gmail's send-as addresses and signatures asked again now, as
        // Connect asks them (MailSync.keepSendAs); then what each account keeps.
        Task {
            for engine in MailCenter.shared.engines.values {
                engine.store.set("sendas.at", nil)
                await engine.sync.keepSendAs(now: Date())
            }
            MailCenter.shared.touch()
            var kept: [String: Any] = [:]
            for (account, engine) in MailCenter.shared.engines {
                kept[account] = ["sendAs": engine.store.sendAs().map { ["address": $0.address, "name": $0.name, "default": $0.isDefault,
                                                                         "signature": $0.signature] },
                                 "aliases": engine.store.aliases]
            }
            answer(["accounts": kept])
        }
    }

    func handleAgentMailSync(_ c: AgentCall) {
        let request = c.request
        let answer = c.answer
        // Every account synced now, as the page's own clock would;
        // `labels`, Gmail's list of labels read again with it, as its ten
        // minutes would.
        for engine in MailCenter.shared.engines.values {
            if request["labels"] as? Bool == true { engine.store.set("labels", nil) }
            MailCenter.shared.run(engine)
        }
        answer(["ok": true])
    }

    func handleAgentMailHold(_ c: AgentCall) {
        let request = c.request
        let answer = c.answer
        // Every account's writer held `seconds` (2 by default) off the main
        // thread, as a long sync write holds it, a --test run only:
        // answered once all are held, for timing what must not wait on it.
        guard Store.testing else { answer(["error": "agent-mail-hold only works on a --test run"]); return }
        let seconds = request["seconds"] as? Double ?? 2
        let stores = MailCenter.shared.engines.values.map(\.store)
        let held = DispatchGroup()
        for store in stores {
            held.enter()
            DispatchQueue.global(qos: .utility).async { store.holdWriter(seconds) { held.leave() } }
        }
        held.notify(queue: .main) { answer(["ok": true, "held": stores.count, "seconds": seconds]) }
    }

    func handleAgentMailState(_ c: AgentCall) {
        let browser = c.browser
        let answer = c.answer
        let center = MailCenter.shared
        answer(["accounts": center.accounts, "pending": center.engines.values.map(\.store.pendingOps).reduce(0, +),
                "synced": center.status.values.compactMap { $0.synced?.timeIntervalSince1970 }.max() ?? 0,
                "syncedBy": center.status.compactMapValues { $0.synced?.timeIntervalSince1970 },
                "trouble": center.status.values.compactMap(\.trouble).first ?? "",
                "notices": Noticing.mail(center.noticed(), now: Date()).map { $0.title + " · " + $0.detail },
                // The new tab's line for what Skip the inbox archived today, and where it goes.
                "archived": { () -> [String: Any] in
                    let archived = center.archivedToday()
                    guard archived.count > 0 else { return [:] }
                    let hint = Noticing.archived(archived.count, names: archived.splits.map { MailList.name($0) })
                    return ["title": hint.title, "detail": hint.detail, "url": hint.url?.absoluteString ?? "", "count": archived.count]
                }(),
                "needYou": center.needYou,
                "pinned": (browser.tabs + browser.parkedTabs).contains { MailPage.isMail($0.pending ?? $0.address) && $0.pin != nil },
                "snoozed": center.engines.values.flatMap { $0.store.snoozes().map(\.thread) },
                "scheduled": center.engines.values.flatMap { $0.store.allOps().filter { $0.kind == .send }.map(\.notBefore.timeIntervalSince1970) },
                // Notifications and the badge (MailNotify), the rhythm and the line to Gmail (MailCadence).
                "notified": MailNotify.shared.benchPosted, "badge": NSApp.dockTile.badgeLabel ?? "",
                "cadence": Dictionary(uniqueKeysWithValues: center.accounts.map { ($0, center.cadence(for: $0) ?? 0) }),
                "heard": center.heard.values.map(\.timeIntervalSince1970).max() ?? 0, "checks": center.checks,
                "sensing": Array(center.sensing),
                // Threads a notification was said for, or passed over on purpose (MailNotify.look).
                "noted": center.engines.values.flatMap { $0.store.notified().keys },
                "wire": ["opened": center.engines.values.compactMap(\.wire).map(\.opened).reduce(0, +),
                         "reused": center.engines.values.compactMap(\.wire).map(\.reused).reduce(0, +)],
                // Reminders if nobody answers (MailFollowups), and mail's clock.
                "followups": center.engines.values.flatMap { $0.store.followups() }.map { followup -> [String: Any] in
                    ["thread": followup.thread, "until": followup.until.timeIntervalSince1970, "sent": followup.sent.timeIntervalSince1970,
                     "fired": followup.fired?.timeIntervalSince1970 ?? 0, "message": followup.message]
                },
                "now": MailClock.now.timeIntervalSince1970])
    }

    func handleAgentMailNotify(_ c: AgentCall) {
        let request = c.request
        let answer = c.answer
        // Mail's notifications in a test world (MailNotify): what macOS
        // says, an account's mode, the badge's, mail in front as if it
        // were, Allow… pressed, a wake or an unlock as if it came; then
        // what was posted and asked.
        guard Store.testing else { answer(["error": "agent-mail-notify only works on a --test run"]); return }
        let notify = MailNotify.shared
        Task {
            if let state = (request["permission"] as? String).flatMap(MailNotify.Permission.init) { await notify.benchPermission(state) }
            if let mode = (request["mode"] as? String).flatMap(MailNotify.Mode.init) {
                for account in (request["account"] as? String).map({ [$0] }) ?? MailCenter.shared.accounts { notify.setMode(mode, for: account) }
            }
            if let badge = (request["badge"] as? String).flatMap(MailNotify.Badge.init) { notify.setBadge(badge) }
            if let front = request["front"] { notify.frontForced = front as? Bool }
            if request["allow"] as? Bool == true { await notify.allow() }
            if request["clear"] as? Bool == true { notify.benchClear() }
            if let event = request["event"] as? String { MailCenter.shared.now(event) }
            // The badge is counted a beat after a change.
            try? await Task.sleep(nanoseconds: 500_000_000)
            answer(notify.benchState().merging(["notified": notify.benchPosted, "checks": MailCenter.shared.checks]) { mine, _ in mine })
        }
    }

    func handleAgentMailNotifyAct(_ c: AgentCall) {
        let request = c.request
        let browser = c.browser
        let answer = c.answer
        // A notification answered as a click would: Open, Mark Done,
        // Remind Me Tomorrow or Reply, found by its id or its thread.
        guard Store.testing else { answer(["error": "agent-mail-notify-act only works on a --test run"]); return }
        let notify = MailNotify.shared
        let id = request["id"] as? String ?? "", thread = request["thread"] as? String ?? ""
        guard let posted = notify.posted.last(where: { $0.id == id || $0.threads == [thread] })
                ?? notify.posted.last(where: { !thread.isEmpty && $0.threads.contains(thread) }),
              let act = MailNotify.Act(rawValue: request["act"] as? String ?? "open") else {
            answer(["error": "no notification for that"]); return
        }
        Task {
            await notify.answer(act, account: posted.account, threads: posted.threads, message: posted.codeMessage)
            try? await Task.sleep(nanoseconds: UInt64(((request["wait"] as? Double) ?? 0.6) * 1_000_000_000))
            let desk = MailDesk.shared
            answer(["ok": true, "inMail": browser.inMail, "view": desk.screen == .list ? "list" : desk.screen == .thread ? "thread" : "compose",
                    "open": desk.open?.thread ?? "", "split": MailList.shared.split, "drafting": desk.draft != nil,
                    "draftBody": desk.draft?.body ?? "", "undo": desk.undoable, "removed": notify.benchState()["removed"] ?? []])
        }
    }

    func handleAgentMailTimeShift(_ c: AgentCall) {
        let request = c.request
        let answer = c.answer
        // A test world's mail clock moved on (`by` seconds, or `to` a
        // shift from the Mac's, 0 to go back), as days going by would
        // move it, and what that brings due woken now (MailClock).
        guard Store.testing else { answer(["error": "agent-mail-time-shift only works on a --test run"]); return }
        MailClock.move(by: request["by"] as? Double, to: request["to"] as? Double)
        MailCenter.shared.wakeNow()
        MailCenter.shared.touch()
        answer(["ok": true, "shift": MailClock.shift, "now": MailClock.now.timeIntervalSince1970])
    }

    func handleAgentMailBody(_ c: AgentCall) {
        let request = c.request
        let answer = c.answer
        // JavaScript in a mail's own web view (MailBody), by its message
        // id, or the last one on screen: what a picture drew, say. A test
        // world's only.
        guard Store.testing else { answer(["error": "agent-mail-body only works on a --test run"]); return }
        let id = request["message"] as? String ?? ""
        // The letter in front's: those made ahead are unseen beside it.
        let front = Set(MailDesk.shared.messages.map(\.id))
        let views = MailBodyView.live.allObjects.filter { id.isEmpty ? front.contains($0.message) : $0.message == id }
        guard let view = views.last else { answer(["error": "no mail body on screen" + (id.isEmpty ? "" : " for \(id)")]); return }
        view.evaluateJavaScript(request["js"] as? String ?? "document.images.length") { value, error in
            answer(["value": value ?? NSNull(), "error": error?.localizedDescription ?? "", "message": view.message,
                    "bodies": MailBodyView.live.allObjects.map(\.message)])
        }
    }

    func handleAgentMailWriterFake(_ c: AgentCall) {
        let request = c.request
        let answer = c.answer
        // A test world's Claude for replies written ahead: what it prints.
        guard Store.testing else { answer(["error": "agent-mail-writer-fake only works on a --test run"]); return }
        let printed = request["text"] as? String ?? ""
        MailDrafts.fake = { _ in printed }
        // Every account's, in order: a world with two (the search check's
        // second) had the run go to either, as a dictionary's first is.
        for engine in MailCenter.shared.engines.values.sorted(by: { $0.account < $1.account }) { MailDrafts.run(engine, force: true) }
        answer(["ok": true, "said": MailDrafts.said])
    }

    func handleAgentMailFake(_ c: AgentCall) {
        let request = c.request
        let answer = c.answer
        // A test world's mailbox: mail that the codes read in place of
        // Gmail's feed, a --test run only.
        guard Store.testing else { answer(["error": "agent-mail-fake only works on a --test run"]); return }
        let mail = (request["mail"] as? [[String: Any]] ?? []).map { row in
            Mailed(from: row["from"] as? String ?? "", address: row["address"] as? String ?? "",
                   subject: row["subject"] as? String ?? "", text: row["text"] as? String ?? "",
                   at: Date(timeIntervalSince1970: row["ts"] as? Double ?? Date().timeIntervalSince1970),
                   thread: row["thread"] as? String, account: row["account"] as? String,
                   html: row["html"] as? String, unread: row["unread"] as? Bool ?? true,
                   junk: row["junk"] as? Bool ?? false)
        }
        MailCodes.fakeMail.withLock { $0 = mail }
        // Mail came: a sign-in link in it is offered as one from the store would be.
        MailLinks.look()
        answer(["ok": true])
    }
}
