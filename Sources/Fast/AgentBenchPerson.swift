import Combine
import AppKit
import UserNotifications
import WebKit

// Bench.agentCommand's verbs (AgentBench). The person: handing a tab over,
// questions at a tab's foot, sign-ins and autofill.

extension Bench {
    static let personVerbs: [String: AgentHandler] = [
        "agent-cleanup-preview": { _, c in c.answer(AgentTabCleanup.bench(c.request, in: c.browser)) },
        "handoff": { $0.handleHandoff($1) },
        "handoff-wait": { $0.handleHandoffWait($1) },
        "agent-ask": { $0.handleAgentAsk($1) },
        "agent-reply": { $0.handleAgentReply($1) },
        "agent-sign-in": { $0.handleAgentSignIn($1) },
        "agent-unlock-manager": { $0.handleAgentUnlockManager($1) },
        "agent-autofill": { $0.handleAgentAutofill($1) },
        "agent-answer": { $0.handleAgentAnswer($1) },
        "agent-chat-ask": { $0.handleAgentChatAsk($1) },
        "agent-ask-stand": { $0.handleAskStand($1) },
        "agent-notice-click": { $0.handleAgentNoticeClick($1) },
        "agent-vault": { $0.handleAgentVault($1) },
        "agent-foot": { $0.handleAgentFoot($1) },
        "agent-foot-preview": { $0.handleAgentFootPreview($1) },
        "agent-person": { $0.handleAgentPerson($1) },
        "agent-handback": { $0.handleAgentHandback($1) },
    ]

    func handleHandoff(_ c: AgentCall) {
        let verb = c.verb
        let request = c.request
        let answer = c.answer
        let agents = c.agents
        let session = c.session
        func own(going: Bool = false, asking: Bool = false) -> Tab? { c.own(going: going, asking: asking) }
        // yab's own quiet work (the morning's look) has nobody watching:
        // it asks no one anything, and what needs a person it skips.
        if let alone = agents.session(session), alone.unattended || Headless.nobody {
            if alone.quiet { Hints.shared.refusedQuiet(verb) }
            answer(["error": alone.quiet ? "this is a quiet task nobody is watching: don't ask the user, skip what needs them"
                : "nobody is at Yab to do this for this task: don't ask the user, skip what needs them, and say in your answer what did"])
            return
        }
        if agents.session(session)?.parent != nil {
            answer(["error": "a subagent can't ask the user; report it to the parent"])
            return
        }
        guard let tab = own(asking: true) else { return }
        // Asked here before, as something it could do without, and
        // answered since: it hears that answer rather than asking again.
        if tab.handoff == nil, let said = Agents.answered.removeValue(forKey: tab.id) {
            answer(["ok": true, "answered": said])
            return
        }
        // A sign-in handed over while the page offers a way in this
        // space is signed in to: once, it's told to take that way first.
        let reason = (request["reason"] as? String ?? "").lowercased()
        if ["sign in", "log in", "login", "signin"].contains(where: reason.contains), let ways = Agents.ways[tab.id],
           Agents.waysTold.insert(tab.id).inserted {
            answer(["error": "not yet: \(ways). Call handoff again only if that doesn't get you in."])
            return
        }
        // Asked on a sign-in page: leaving it for the site is the answer.
        Agents.signInPage[tab.id] = tab.address.flatMap { SignIns.loginPage($0) ? $0 : nil }
        Agents.taken.remove(tab.id)
        agents.handoff(tab, reason: request["reason"] as? String ?? "Needs you", detail: request["detail"] as? String,
                       optional: request["optional"] as? Bool == true)
        answer(["ok": true])
    }

    func handleHandoffWait(_ c: AgentCall) {
        let request = c.request
        let browser = c.browser
        let answer = c.answer
        let agents = c.agents
        let session = c.session
        let limit = Date().addingTimeInterval(request["seconds"] as? Double ?? 20)
        if let mail = request["mailAsk"] as? String {
            func heard() {
                let status = agents.mailStatus(mail, session: session)
                if status["state"] as? String != "waiting" || Date() >= limit { answer(status); return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { heard() }
            }
            heard()
            return
        }
        // A question for the whole chat (Agents.askChat): waiting while the
        // chat still asks it, answered once it doesn't.
        if let chat = request["chat"] as? String {
            func heard() {
                guard let root = agents.session(chat) else { answer(["state": "done"]); return }
                if let owner = agents.session(session ?? chat), owner.id != Agents.script, !owner.state.live {
                    answer(["state": "stopped"]); return
                }
                if root.permit == nil { answer(["state": "done", "answer": ""]); return }
                if Date() > limit { answer(["state": "waiting", "question": root.permit?.question ?? ""]); return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { heard() }
            }
            heard()
            return
        }
        guard let tab = find(request, in: browser) else { answer(["state": "done"]); return }
        // Whoever is waiting: the asking session, or the tab's, a guest's
        // in a tab of yours included.
        let waiting = session ?? tab.askedBy
        func check() {
            if let owner = agents.session(waiting), owner.id != Agents.script, !owner.state.live { answer(["state": "stopped"]); return }
            // Kept or pinned with the question open: not an answer.
            if Agents.taken.remove(tab.id) != nil {
                Agents.answered[tab.id] = nil
                answer(["state": "taken"])
                return
            }
            if tab.handoff == nil {
                Agents.answered[tab.id] = nil
                answer(["state": "done", "answer": tab.chosen ?? ""])
                return
            }
            if Agents.signedIn(tab) {
                agents.handBack(tab)
                answer(["state": "done", "answer": ""])
                return
            }
            if Date() > limit { answer(["state": "waiting", "question": tab.handoff ?? ""]); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { check() }
        }
        check()
    }

    func handleAgentAsk(_ c: AgentCall) {
        let verb = c.verb
        let request = c.request
        let browser = c.browser
        let answer = c.answer
        let agents = c.agents
        let session = c.session
        // A question with things to pick from, at the foot of a tab:
        // the one named, or the agent's own latest, or the one in front.
        // yab's own quiet work (the morning's look) has nobody watching:
        // it asks no one anything, and what needs a person it skips.
        if let alone = agents.session(session), alone.unattended || (Headless.nobody && !["tty", "caller"].contains(alone.person) && alone.cli != "external") {
            if alone.quiet { Hints.shared.refusedQuiet(verb) }
            answer(["error": alone.quiet ? "this is a quiet task nobody is watching: don't ask the user, skip what needs them"
                : "nobody is at Yab to do this for this task: don't ask the user, skip what needs them, and say in your answer what did"])
            return
        }
        if agents.session(session)?.parent != nil {
            answer(["error": "a subagent can't ask the user; report it to the parent"])
            return
        }
        // A caller that isn't a person, a script or another agent: the
        // question is the answer, and the reply comes as a resume. The
        // same while yab is hidden, for a task nobody said was followed
        // at a terminal (the `task` tool's, a routine's): its card would
        // be on no screen.
        // Only the agent's own `ask`: a check yab puts up itself (a send
        // to a site, which card) is a yes only Yab takes.
        let pick = request["pick"] as? Bool == true
        if pick, let asker = agents.session(session), asker.person == "caller" || (Headless.woken && asker.person == "app" && asker.cli != "external") {
            let options = request["options"] as? [String] ?? []
            asker.question = (request["question"] as? String ?? "Which one?") + (options.isEmpty ? "" : " (" + options.joined(separator: " / ") + ")")
            answer(["end_turn": "Nobody is at Yab to answer: whoever started this task reads your answer. End your turn now with this question and its options as your whole answer; the reply comes as the next message."])
            return
        }
        // Hidden for an agent of its own: nobody sees Yab's cards.
        if pick, Headless.woken || Headless.nobody, agents.session(session)?.cli == "external" {
            answer(["end_turn": "Yab is running hidden, and nobody sees its cards. Ask your user in your own chat, then carry on."])
            return
        }
        let named = (request["id"] as? String).flatMap { $0.isEmpty ? nil : find(request, in: browser) }
        guard let session, let tab = named ?? agents.askTab(for: session, in: browser) else { answer(["error": "no tab to ask in"]); return }
        if tab.permit != nil || (tab.handoff != nil && tab.askedBy != session) {
            answer(["error": "something else is being asked in that tab; try again in a moment"])
            return
        }
        // Asking lets it into no tab of yours: its card at the page's foot,
        // not its face (Tab.asker).
        if tab.worker != session { tab.asker = session }
        let options = (request["options"] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        // Known as a question before it is put up: a terminal following
        // the task is told the moment it is, and told it is a pick.
        agents.session(session)?.asking = tab.id
        agents.handoff(tab, reason: request["question"] as? String ?? "Which one?", detail: request["detail"] as? String, choices: options)
        agents.showAsk(tab, session: session, in: browser)
        answer(["ok": true, "id": Bench.short(tab)])
    }

    func handleAgentReply(_ c: AgentCall) {
        let request = c.request
        let browser = c.browser
        let answer = c.answer
        let agents = c.agents
        let session = c.session
        // An answer typed where the task was started (`yab "…"` in a
        // terminal): to its question only. What needs hands or a yes,
        // a sign-in, a captcha, Pay, is done in Yab, never from here,
        // or an agent could say yes to itself.
        guard let found = agents.session(session) else { answer(["error": "no session \(session ?? "")"]); return }
        guard let id = found.asking, let tab = browser.everyTab.first(where: { $0.id == id }), tab.handoff != nil, tab.askedBy == found.id || tab.guest == found.id || tab.agent == found.id else {
            let waits = agents.tabs(of: found).contains { $0.handoff != nil } || browser.everyTab.contains { $0.permit?.session == found.id }
            answer(["error": waits ? "this one is done in Yab, not here" : "nothing is asked here now"])
            return
        }
        guard tab.permit == nil else { answer(["error": "this one is done in Yab, not here"]); return }
        let said = (request["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty else { answer(["error": "an answer needs words"]); return }
        found.asking = nil
        agents.choose(tab, said)
        answer(["ok": true])
    }

    func handleAgentSignIn(_ c: AgentCall) {
        let verb = c.verb
        let request = c.request
        let browser = c.browser
        let answer = c.answer
        let agents = c.agents
        let session = c.session
        func own(going: Bool = false, asking: Bool = false) -> Tab? { c.own(going: going, asking: asking) }
        // yab's own quiet work (the morning's look) has nobody watching:
        // it asks no one anything, and what needs a person it skips.
        if let alone = agents.session(session), alone.unattended || Headless.nobody {
            if alone.quiet { Hints.shared.refusedQuiet(verb) }
            answer(["error": alone.quiet ? "this is a quiet task nobody is watching: don't ask the user, skip what needs them"
                : "nobody is at Yab to do this for this task: don't ask the user, skip what needs them, and say in your answer what did"])
            return
        }
        guard let tab = own(), let session else { return }
        guard let host = tab.address?.host else { answer(["error": "no site in that tab"]); return }
        // Yab's own login first, whichever managers are connected; then
        // each connected manager's own menu on the page, in order.
        let saved = browser.prefs.usesYabPasswords ? AgentFiles.users(for: host) : []
        guard !saved.isEmpty else {
            // A manager Yab reads itself first (ManagerVaults), then the
            // managers' own menus on the page.
            Bench.vaultSignIn(c, tab: tab, host: host, session: session) {
                Bench.menuSignIn(c, tab: tab, host: host, session: session) {
                    Bench.managerMenus(tab, host: host, browser: browser, house: { self.house($0) }) { answer($0) }
                }
            }
            return
        }
        let key = "signin:" + Vault.registrable(host)
        // Which account, when the task says: the one of that name. When
        // there are several and it doesn't, the agent is told which
        // there are rather than handed the last one used: signing in to
        // the wrong account does things as the wrong person.
        let names = Array(Set(saved.map(\.user))).sorted()
        if let wanted = (request["user"] as? String)?.trimmingCharacters(in: .whitespaces).lowercased(), !wanted.isEmpty {
            guard let user = names.first(where: { $0.lowercased() == wanted }) ?? names.first(where: { $0.lowercased().contains(wanted) }) else {
                answer(["error": "Yab has no saved password for \(wanted) on \(host); it has: \(names.joined(separator: ", ")). Ask the user, or call handoff"])
                return
            }
            if AgentFiles.shared.signIns[session + key]?.user != user { AgentFiles.shared.signIns[session + key] = nil }
            if browser.prefs.asking(session) != .ask { AgentFiles.shared.signIns[session + key] = (user, Date()) }
            tab.chosen = user
        } else if names.count > 1, AgentFiles.shared.signIns[session + key] == nil, browser.prefs.asking(session) == .auto {
            answer(["error": "Yab has \(names.count) accounts saved for \(Vault.registrable(host)): \(names.joined(separator: ", ")). Call sign_in again with user set to the one this task is for; if the task doesn't say, ask the user"])
            return
        }
        // Bypass never asks: the last account used there, as before,
        // and the agent told which others there are.
        let others = names.count > 1 && browser.prefs.asking(session) == .bypass && request["user"] == nil
            ? " Yab also keeps \(names.filter { $0 != (AgentFiles.shared.signIns[session + key]?.user ?? saved[0].user) }.joined(separator: ", ")) here: call sign_in with user to use that instead."
            : ""
        let kept = AgentFiles.shared.signIns[session + key].flatMap { Date().timeIntervalSince($0.at) < 600 ? $0 : nil }
        if kept == nil, let yes = tab.approved, yes.session == session, yes.ref == key {
            tab.approved = nil
            AgentFiles.shared.signIns[session + key] = (tab.chosen ?? saved[0].user, Date())
        } else if kept == nil, browser.prefs.asking(session) != .ask {
            // Only Ask asks before a sign-in: the last name used there.
            AgentFiles.shared.signIns[session + key] = (saved[0].user, Date())
        }
        guard let user = AgentFiles.shared.signIns[session + key].flatMap({ Date().timeIntervalSince($0.at) < 600 ? $0.user : nil }) else {
            if tab.declined.remove(session) != nil {
                answer(["error": "the person said not now to signing in: call handoff if they should do it themselves, or stop"])
                return
            }
            let users = Array(Set(saved.map(\.user))).sorted()
            var permit = AgentPermit(kind: .signIn(host: Vault.registrable(host), users: users), session: session, detail: users.count == 1 ? "as \(users[0])" : "")
            permit.draft = ""
            agents.ask(tab, permit)
            answer(["error": "signing in waits for the person's yes; asking them now", "asking": true])
            return
        }
        agents.touch(session, "sign in · \(host)")
        AgentFeed.shared.did(tab, .type)
        let entry = saved.first { $0.user == user } ?? saved[0]
        AgentPage.run(tab, AgentFiles.submit, ["phase": "focus"]) { _ in
            // Read now, handed straight to the page, never to the agent.
            let secret = Vault.password(host: entry.host, user: entry.user) ?? ""
            guard !secret.isEmpty else {
                answer(["error": "the keychain didn't hand over the saved password for \(entry.host): call handoff so the person signs in"])
                return
            }
            tab.fill(user: entry.user, password: secret, agent: true) { filled in
                if filled == .refused { answer(["error": "the person didn't confirm with \(Vault.proof): call handoff, or stop"]); return }
                if filled == .unasked { answer(["error": "the Mac couldn't ask for \(Vault.proof), so nothing was filled: call handoff so the person signs in"]); return }
                guard filled == .filled else { answer(["error": "couldn't fill the sign-in on this page: call handoff"]); return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    AgentPage.run(tab, AgentFiles.submit, ["phase": "submit"]) { result in
                        let out = (try? result.get()) as? [String: Any] ?? [:]
                        let step = out["password"] as? Bool == true ? "the password" : "the name"
                        answer(["ok": true, "said": "Filled \(step) for \(entry.user) and sent it.\(others) Take a snapshot: if a password page follows, call sign_in again; a code or captcha is a handoff."])
                    }
                }
            }
        }
    }

    func handleAgentAutofill(_ c: AgentCall) {
        let request = c.request
        let browser = c.browser
        let answer = c.answer
        let agents = c.agents
        let session = c.session
        func own(going: Bool = false, asking: Bool = false) -> Tab? { c.own(going: going, asking: asking) }
        // A card or an address yab keeps, put into the page by yab:
        // the agent hears what went in, never a card's number (Wallet).
        guard let tab = own(), let session else { return }
        if request["what"] as? String == "form" {
            agentFillForm(tab, session: session, browser: browser, answer)
            return
        }
        guard browser.prefs.fillsCards else {
            answer(["error": "filling cards and addresses is off (Settings › Passwords): call handoff so the person fills it in"])
            return
        }
        let site = Browser.site(tab.address?.host() ?? "")
        let origin = Tab.originOf(tab.address)
        let what = request["what"] as? String ?? "card"
        if what != "card" {
            guard let address = Wallet.preferredAddress() else {
                answer(["error": "Yab keeps no address: ask the user for it, or call handoff"])
                return
            }
            // An address is the person's to give to a site: asked at the
            // tab's foot, by yab itself, unless they said never to be
            // asked (Bypass). A client that skips the tool's question
            // still meets this one.
            if browser.prefs.asking(request["session"] as? String) != .bypass {
                let key = "address:" + site
                let yes = tab.approved.flatMap { $0.session == session && $0.ref == key && Date().timeIntervalSince($0.at) < 120 ? $0 : nil }
                guard yes != nil else {
                    if tab.declined.remove(session) != nil {
                        answer(["error": "the person said not now to filling their address here: don't type it in another way; say so in your answer"])
                        return
                    }
                    agents.ask(tab, AgentPermit(kind: .address(host: site), session: session,
                                                detail: [address.title, address.place].filter { !$0.isEmpty }.joined(separator: ", ")))
                    answer(["error": "filling the address waits for the person's yes; asking them now", "asking": true])
                    return
                }
                tab.approved = nil
            }
            agents.touch(session, "autofill · \(site)")
            AgentFeed.shared.did(tab, .type)
            tab.walletLook()
            tab.walletFill(address.filling, what: .address, origin: origin) { filled in
                guard filled > 0 else {
                    answer(["error": "no address boxes here that Yab could fill: type it in, or call handoff"])
                    return
                }
                DispatchQueue.global(qos: .utility).async { Wallet.touch(address: address.id, on: site) }
                answer(["ok": true, "said": "Filled \(filled) boxes with the address \(address.title). Check them in the snapshot before going on."])
            }
            return
        }
        guard tab.address?.scheme == "https" || Tab.local(tab.address) else {
            answer(["error": "this page didn't come over https: no card goes into it. Stop, and say so."])
            return
        }
        let cards = Wallet.cards().filter { !$0.expired }
        guard !cards.isEmpty else {
            answer(["error": "Yab keeps no card: call handoff so the person pays"])
            return
        }
        let named = (request["card"] as? String ?? "").filter(\.isNumber)
        let listed = cards.map { "\($0.title) (\($0.expiry))" }.joined(separator: ", ")
        let chosen: SavedCard
        if !named.isEmpty {
            guard let card = cards.first(where: { $0.last4 == String(named.suffix(4)) }) else {
                answer(["error": "no card ending in \(named.suffix(4)); Yab keeps \(listed)"])
                return
            }
            chosen = card
        } else if cards.count == 1 || browser.prefs.asking(request["session"] as? String) == .bypass {
            // Bypass never puts a question to the person: the card used
            // last, as a sign-in takes the account used last.
            chosen = cards[0]
        } else {
            // The person picks, from the cards themselves (the tool puts
            // the question); the agent hears only which.
            answer(["choose": cards.map { $0.nickname.isEmpty ? $0.title : "\($0.nickname), \($0.title)" },
                    "site": site, "error": "Yab keeps several cards: \(listed)"])
            return
        }
        agents.touch(session, "autofill · \(site)")
        // Frames that drew their card's boxes after loading look now, while
        // the person confirms: no frame watches its page for them.
        tab.walletLook()
        let also = tab.walletHosts(.card)
        Wallet.prove("let an agent fill \(chosen.title) on \(site)" + (also.isEmpty ? "" : " (its form is \(also.joined(separator: ", ")))")) { proven in
            switch proven {
            case .yes: break
            case .no: answer(["error": "the person didn't confirm with \(Vault.proof): call handoff, or stop"]); return
            case .cannot: answer(["error": "the Mac couldn't ask for \(Vault.proof), so nothing was filled: call handoff"]); return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let number = Wallet.number(of: chosen.id)
                let code = Wallet.securityCode(of: chosen.id) ?? ""
                let home = Wallet.billing(of: chosen, among: Wallet.addresses())
                DispatchQueue.main.async {
                    guard let number else { answer(["error": "the keychain didn't hand over the card: call handoff"]); return }
                    AgentFeed.shared.did(tab, .type)
                    let data: [String: Any] = ["number": number, "name": chosen.name, "month": chosen.month, "year": chosen.year, "csc": code,
                                               "postal": home?.postal ?? "", "country": home?.country ?? ""]
                    let passed = tab.walletPassed(.card)
                    // Boxes left empty on purpose, said, or the agent reads them as a fill that broke.
                    let empty = passed.isEmpty ? "" : " Card boxes in a frame of \(passed.joined(separator: ", ")), which is neither this shop nor a payment company, got nothing: call handoff so the person types them there."
                    tab.walletFill(data, what: .card, origin: origin) { filled in
                        guard filled > 0 else {
                            answer(["error": passed.isEmpty ? "no card boxes here that Yab could fill: call handoff so the person pays" : "nothing filled." + empty])
                            return
                        }
                        DispatchQueue.global(qos: .utility).async { Wallet.touch(card: chosen.id, on: site) }
                        let others = cards.count > 1 ? " Yab also keeps \(cards.filter { $0.id != chosen.id }.map(\.title).joined(separator: ", ")); card picks one." : ""
                        answer(["ok": true, "said": "Filled \(chosen.title) (\(filled) boxes).\(empty)\(others)" + (code.isEmpty ? " Its security code isn't kept: if the page asks for it, call handoff so the person types it." : "")])
                    }
                }
            }
        }
    }

    func handleAgentAnswer(_ c: AgentCall) {
        let request = c.request
        let browser = c.browser
        let answer = c.answer
        let agents = c.agents
        // Allow or Not now on a permit's card, without a hand, a --test run only.
        guard Store.testing else { answer(["error": "agent-answer only works on a --test run"]); return }
        if let mail = request["mailAsk"] as? String {
            guard agents.mailRequest(mail) != nil else { answer(["error": "nothing asked there"]); return }
            agents.answerMail(mail, yes: request["yes"] as? Bool ?? true)
            answer(["ok": true])
            return
        }
        // A chat's own question (Agents.askChat), as its notification's buttons answer it.
        if let chat = request["chat"] as? String {
            guard agents.session(chat)?.permit != nil else { answer(["error": "nothing asked there"]); return }
            agents.answer(chat: chat, yes: request["yes"] as? Bool ?? true)
            answer(["ok": true])
            return
        }
        guard let tab = find(request, in: browser) else { answer(missing(request)); return }
        if let choice = request["choice"] as? String, !tab.choices.isEmpty || tab.handoff != nil {
            agents.choose(tab, choice)
            answer(["ok": true])
            return
        }
        guard tab.permit != nil else { answer(["error": "nothing asked there"]); return }
        agents.answer(tab, yes: request["yes"] as? Bool ?? true, as: request["user"] as? String)
        answer(["ok": true])
    }

    /// The page's bottom right (AskStand), a --test run only
    /// (evals/mail/ask_stand.py): what stands there, the one in front's
    /// card as it reads, the Undo toasts and a card's last words; with
    /// `act`, its buttons: yes, no, undo, or elsewhere (answered on another
    /// device, as AssistantApprovals.answerFromSync answers).
    func handleAskStand(_ c: AgentCall) {
        guard Store.testing else { c.answer(["error": "agent-ask-stand only works on a --test run"]); return }
        let agents = c.agents, browser = c.browser, stand = AskStand.shared
        let held = agents.corneredAll(in: browser)
        func front() -> (AgentPermit, Tab?, String?)? {
            switch held.first {
            case .chat(let id): return agents.session(id)?.permit.map { ($0, nil, id) }
            case .mail(let id): return agents.mailRequest(id).map { ($0.permit, nil, nil) }
            case .tab(let id):
                guard let tab = browser.everyTab.first(where: { $0.id == id }), let permit = tab.permit ?? tab.sending?.permit else { return nil }
                return (permit, tab, nil)
            case nil: return nil
            }
        }
        if let act = c.request["act"] as? String {
            switch act {
            case "undo":
                c.answer(["ok": stand.undoLast()])
            case "open", "back", "all":
                AgentAskCard.pressed.send(act == "open" ? String(c.request["index"] as? Int ?? 0) : act)
                c.answer(["ok": true])
            case "yes", "no", "elsewhere":
                guard let (permit, tab, chat) = front() else { c.answer(["error": "nothing stands there"]); return }
                let yes = act != "no"
                if act == "elsewhere" { stand.said(permit, tab: tab, words: "Allowed on iPhone", good: true) }
                if let shown = stand.presented[ObjectIdentifier(browser)], !shown.actionable || shown.key != permit.key {
                    c.answer(["error": "the answered card is still leaving"]); return
                }
                if case .mail(let id) = held.first { agents.answerMail(id, yes: yes) }
                else if let chat { agents.answer(chat: chat, yes: yes, key: permit.key) }
                else if let tab { agents.answer(tab, yes: yes) }
                c.answer(["ok": true])
            default:
                c.answer(["error": "act is yes, no, undo, elsewhere, open, back or all"])
            }
            return
        }
        var said: [String: Any] = ["count": held.count,
            "order": held.compactMap { agents.cornerPermit($0, in: browser)?.key }]
        let surface = stand.presented[ObjectIdentifier(browser)]
        said["transitioning"] = held.first != nil && (surface.map { !$0.actionable || $0.held != held.first } ?? true)
        said["visiblePermits"] = Array(stand.questionCards[ObjectIdentifier(browser), default: [:]].values).sorted()
        if let frame = stand.frames[ObjectIdentifier(browser)] {
            said["cardFrame"] = ["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height,
                                  "right": frame.maxX, "bottom": frame.maxY]
        }
        if case .tab(let id) = held.first, let tab = browser.everyTab.first(where: { $0.id == id }), tab.permit == nil, tab.sending == nil, !tab.choices.isEmpty {
            said["front"] = ["choices": tab.choices, "question": tab.handoff ?? ""]
        }
        if let (permit, tab, _) = front() {
            let content = stand.content(permit, tab: tab)
            said["front"] = ["permit": permit.key, "name": content.name, "sub": content.sub, "question": content.question ?? "",
                             "verb": permit.answers.last?.title ?? "", "weighty": permit.weighty,
                             "sending": tab?.sending != nil, "failure": tab?.sending?.failure ?? ""]
        }
        said["toasts"] = stand.toasts.map { ["id": $0.id, "title": $0.title, "subject": $0.subject, "done": $0.done ?? "",
                                              "left": max(0, $0.until.timeIntervalSinceNow)] as [String: Any] }
        said["ghosts"] = stand.ghosts.map { ["id": $0.id, "words": $0.words] }
        said["drawn"] = (stand.drawn[ObjectIdentifier(browser)] ?? 0) > 0
        c.answer(said)
    }

    /// A click on the body of the Mac's notification of an agent's question,
    /// as UNUserNotificationCenter hands it to Yab (AgentNotices.respond):
    /// `chat` for a chat's question, `tab` (its id's start) for one asked
    /// on a tab. `away` hides Yab first, as when it is behind other apps.
    /// Answers where Yab is after it: in front, its window, the column and
    /// the corner. A --test run only (evals/mail/notice_click.py).
    func handleAgentNoticeClick(_ c: AgentCall) {
        guard Store.testing else { c.answer(["error": "agent-notice-click only works on a --test run"]); return }
        let agents = c.agents
        var info: [String: String] = [:]
        if let mail = c.request["mailAsk"] as? String {
            guard agents.mailRequest(mail) != nil else { c.answer(["error": "mail request asks nothing"]); return }
            info = ["mailAsk": mail]
        } else if let chat = c.request["chat"] as? String, !chat.isEmpty {
            guard let permit = agents.session(chat)?.permit else { c.answer(["error": "chat \(chat) asks nothing"]); return }
            info = ["permit": permit.key, "chat": chat]
        } else if let prefix = (c.request["tab"] as? String)?.lowercased(), !prefix.isEmpty {
            let every = BrowserWindows.shared.browsers.flatMap(\.everyTab) + c.browser.everyTab
            guard let tab = every.first(where: { $0.id.uuidString.lowercased().hasPrefix(prefix) }) else {
                c.answer(["error": "no tab \(prefix)"]); return
            }
            info = ["tab": tab.id.uuidString]
        } else {
            c.answer(["error": "chat or tab"]); return
        }
        let away = c.request["away"] as? Bool == true
        if away { NSApp.hide(nil) }
        let answer = c.answer
        DispatchQueue.main.asyncAfter(deadline: .now() + (away ? 0.8 : 0)) {
            let hidden = NSApp.isHidden, wasActive = NSApp.isActive
            Task { @MainActor in
                await AgentNotices.shared.respond(UNNotificationDefaultActionIdentifier, info)
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                let key = NSApp.keyWindow
                let front = BrowserWindows.shared.browsers.first { BrowserWindows.shared.window(for: $0) === key }
                let browser = front ?? c.browser
                let held = agents.corneredAll(in: browser)
                let permit = held.first.flatMap { agents.cornerPermit($0, in: browser)?.key }
                answer(["hiddenBefore": hidden, "activeBefore": wasActive, "active": NSApp.isActive, "hidden": NSApp.isHidden,
                        "key": key != nil, "visible": key?.isVisible == true, "miniaturized": key?.isMiniaturized == true,
                        "space": browser.space.name, "front": browser.active.map(Bench.short) ?? "",
                        "column": browser.chatOpen, "columnChat": browser.chatOpen ? (browser.chatID ?? "") : "",
                        "corner": held.count, "cornerPermit": permit ?? "",
                        "drawn": (AskStand.shared.drawn[ObjectIdentifier(browser)] ?? 0) > 0])
            }
        }
    }

    /// A chat's question, the notifications it posted, and what every tab
    /// wears of an agent, a --test run only (evals/mail/chat_asks.py). With
    /// no `chat`, the latest chat of Yab's.
    func handleAgentChatAsk(_ c: AgentCall) {
        guard Store.testing else { c.answer(["error": "agent-chat-ask only works on a --test run"]); return }
        let agents = c.agents
        let chat = (c.request["chat"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? agents.sessions.last { $0.parent == nil && !$0.quiet && !$0.script }?.id ?? ""
        let root = agents.session(chat)
        let tabs: [[String: Any]] = c.browser.everyTab.map { tab in
            ["id": Bench.short(tab), "url": tab.address?.absoluteString ?? "", "front": c.browser.active === tab,
             "agent": tab.agent ?? "", "guest": tab.guest ?? "", "asker": tab.asker ?? "", "permit": tab.permit?.key ?? "",
             "handoff": tab.handoff ?? "", "unread": tab.unread != nil, "answer": tab.answer != nil]
        }
        c.answer(["chat": chat, "state": root?.state.rawValue ?? "", "permit": root?.permit?.key ?? "",
                  "column": c.browser.chatOpen && c.browser.chatShown == chat,
                  "question": root?.permit?.question ?? "", "reading": root?.mailReading ?? false,
                  "notices": AgentNotices.shared.asked.filter { $0.info["chat"] == chat }.map { ["category": $0.category, "body": $0.body] },
                  "cleared": AgentNotices.shared.cleared.filter { $0 == "agent.permit." + chat }.count,
                  "mailAsks": agents.mailRequests.map { ["id": $0.id, "permit": $0.permit.key] },
                  "tabs": tabs])
    }

    func handleAgentVault(_ c: AgentCall) {
        let request = c.request
        let answer = c.answer
        // A saved password in a test world's own keychain items, for a
        // sign-in to be tried, a --test run only.
        guard Store.testing else { answer(["error": "agent-vault only works on a --test run"]); return }
        // Made again by this build, which a keychain item from another
        // build won't answer.
        Vault.forget(host: request["host"] as? String ?? "", user: request["user"] as? String ?? "")
        let saved = Vault.save(host: request["host"] as? String ?? "", user: request["user"] as? String ?? "", password: request["password"] as? String ?? "")
        answer(saved ? ["ok": true] : ["error": "not saved"])
    }

    func handleAgentFoot(_ c: AgentCall) {
        let request = c.request
        let browser = c.browser
        let answer = c.answer
        // What stands at a tab's page foot for agents, a --test run only.
        guard Store.testing else { answer(["error": "agent-foot only works on a --test run"]); return }
        guard let tab = find(request, in: browser) else { answer(missing(request)); return }
        var out: [String: Any] = ["handoff": tab.handoff ?? "", "detail": tab.handoffDetail ?? "", "choices": tab.choices,
                                  "answer": tab.answer?.text ?? "", "permit": tab.permit?.question ?? "", "draft": tab.permit?.draft ?? ""]
        if #available(macOS 26.0, *) { out["room"] = tab.builtPage?.webKit?.obscuredContentInsets.bottom ?? 0 }
        answer(out)
    }

    func handleAgentFootPreview(_ c: AgentCall) {
        let request = c.request
        let browser = c.browser
        let answer = c.answer
        let agents = c.agents
        // Isolated animation review of the result/offer states, a --test run only.
        guard Store.testing else { answer(["error": "agent-foot-preview only works on a --test run"]); return }
        guard let tab = find(request, in: browser) else { answer(missing(request)); return }
        switch request["state"] as? String {
        case "working":
            // No provider is launched: the real dock and controls, in an isolated world.
            let session = agents.attach(name: "Claude")
            let kind = request["kind"] as? String ?? "local"
            if kind == "local" { session.cli = "claude"; session.state = .running }
            let id = kind == "script" ? agents.scripted().id : session.id
            tab.agent = id
            tab.answer = nil
            agents.touch(id, "read")
            AgentFeed.shared.did(tab, .read)
            answer(["session": id, "id": tab.id.uuidString])
            return
        case "drive": AgentFeed.shared.drive(tab)
        case "point": AgentFeed.shared.pointed(tab.page, at: CGPoint(x: 160, y: 120))
        case "stop-key":
            guard let window = tab.page.window else { answer(["error": "no page window"]); return }
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(tab.page)
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [.shift, .command],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                    characters: ">", charactersIgnoringModifiers: ".", isARepeat: false, keyCode: 47) {
                    NSApp.postEvent(event, atStart: false)
                }
            }
        case "inspect":
            let session = agents.session(request["inspectSession"] as? String)
            answer(["state": session?.state.rawValue ?? "", "worker": tab.worker ?? "",
                    "stoppedItem": session?.items.contains { $0.name == ChatItem.stopped } ?? false,
                    "driving": AgentFeed.shared.driving.contains(tab.id), "pointer": AgentFeed.shared.pointer[tab.id] != nil,
                    "tabPresent": browser.tabs.contains { $0 === tab }, "url": tab.address?.absoluteString ?? ""])
            return
        case "answer":
            tab.answer = ("foot-preview", request["text"] as? String ?? "The page is ready to review.")
        case "mail-permit":
            agents.ask(tab, AgentPermit(kind: .sendMail(to: request["to"] as? String ?? "person@example.com", mail: "foot-preview"),
                                       session: request["session"] as? String ?? "foot-preview", detail: request["detail"] as? String ?? "Preview only",
                                       draft: request["text"] as? String ?? "A draft to review."))
        case "permit":
            // The other cards, for a chat's field (`session` its chat).
            let session = request["session"] as? String ?? "foot-preview"
            let detail = request["detail"] as? String ?? ""
            let kind: AgentPermit.Kind
            switch request["kind"] as? String {
            case "upload": kind = .upload(files: [URL(fileURLWithPath: request["file"] as? String ?? "/tmp/Deck v4.pdf")], ref: "foot-preview")
            case "sign-in": kind = .signIn(host: request["host"] as? String ?? "example.com", users: request["users"] as? [String] ?? ["anna@example.com"])
            case "use": kind = .use
            default: kind = .press(label: request["label"] as? String ?? "Send", ref: "foot-preview")
            }
            agents.ask(tab, AgentPermit(kind: kind, session: session, detail: detail, draft: request["text"] as? String ?? ""))
        case "sending":
            // The yes, said as a click on it says it.
            guard tab.permit != nil else { answer(["error": "no card to say yes to"]); return }
            agents.answer(tab, yes: true)
        case "failed":
            let trouble = request["text"] as? String ?? "It didn't go."
            agents.sent(tab, trouble: trouble) {
                try? await Task.sleep(for: .seconds(1.5))
                return trouble
            }
        case "sent":
            agents.sent(tab, trouble: nil)
        case "clear":
            tab.answer = nil
            tab.permit = nil
            tab.handoff = nil
            tab.sending = nil
        default:
            answer(["error": "state must be answer, mail-permit, permit, sending, failed, sent or clear"])
            return
        }
        answer(["ok": true])
    }

    func handleAgentPerson(_ c: AgentCall) {
        let request = c.request
        let browser = c.browser
        let answer = c.answer
        let agents = c.agents
        // The person, played by an eval, a --test run only: what stands
        // at the foot of every tab for them, and their answer to one.
        guard Store.testing else { answer(["error": "agent-person only works on a --test run"]); return }
        if let tab = find(request, in: browser), request["id"] as? String != nil {
            if let yes = request["yes"] as? Bool, tab.permit != nil {
                agents.answer(tab, yes: yes)
            } else if let pick = request["choose"] as? String {
                // As a click on the choice does: said in the chat too.
                agents.choose(tab, pick)
            } else {
                answer(["error": "nothing to answer there"])
                return
            }
            answer(["ok": true])
            return
        }
        let waiting = browser.tabs.filter { $0.permit != nil || $0.handoff != nil }.map { tab -> [String: Any] in
            ["id": Bench.short(tab), "permit": tab.permit?.question ?? "", "handoff": tab.handoff ?? "",
             "detail": tab.permit?.detail ?? tab.handoffDetail ?? "", "choices": tab.choices, "url": tab.address?.absoluteString ?? ""]
        }
        answer(["waiting": waiting])
    }

    func handleAgentHandback(_ c: AgentCall) {
        let request = c.request
        let browser = c.browser
        let answer = c.answer
        let agents = c.agents
        // "Done" at the foot of the page, or Skip with skip, without a
        // hand, a --test run only.
        guard Store.testing else { answer(["error": "agent-handback only works on a --test run"]); return }
        guard let tab = find(request, in: browser) else { answer(missing(request)); return }
        if request["skip"] as? Bool == true { agents.skip(tab) } else { agents.handBack(tab) }
        answer(["ok": true])
    }
}

extension Bench {
    /// sign_in where Yab keeps nothing for the site: each connected manager
    /// whose extension is on, in order. The sign-in field, in the page or in
    /// one of its frames, takes a click, and within a second the manager
    /// shows there or not: its menu (a frame of its extension's origin, or
    /// its own elements on the page, as NordPass draws it), its locked
    /// state, or nothing. Nothing at all is checked on its own unlock page:
    /// a locked NordPass shows no menu and no icon, only a hint to the
    /// screen reader, and is still locked.
    static func managerMenus(_ tab: Tab, host: String, browser: Browser, house: @escaping @MainActor (Tab) -> Void,
                             _ answer: @escaping @MainActor ([String: Any]) -> Void) {
        let connections = PasswordManagers.Connections.shared
        let order = PasswordManagers.agentOrder(connections.list, on: PasswordManagers.extensionsOn)
        let none: [String: Any] = ["error": "No sign-in for \(host) in Yab or a connected password manager. Call handoff so the person signs in."]
        guard !order.isEmpty else { answer(none); return }
        Task { @MainActor in
            for id in order {
                guard let item = PasswordManagers.installed(id), let base = ManagerExtensions.shared.base(item.id) else { continue }
                var found = await menu(in: tab, origin: base, manager: id)
                // Rows that can't be read, or nothing at all: its own unlock
                // page says whether it is locked.
                switch found {
                case .menu(_, false), .none:
                    if await ManagerUnlock.peekLocked(id, in: browser, house: house) == true { found = .locked }
                default: break
                }
                switch found {
                case .menu(let field, let read):
                    let name = PasswordManagers.name(id), slug = PasswordManagers.slug(id)
                    let locked = connections.row(id) == .yabUnlocks
                        ? "If it asks to unlock, call unlock_manager(\"\(slug)\")." : "If it asks to unlock, call handoff to ask the person."
                    answer(["ok": true, "manager": id, "menu": true, "menuText": Store.testing ? lastMenuText : "",
                            "said": read
                                ? "\(name)'s menu is open under the \(field) field. Pick the account in it; Yab has no sign-in here."
                                : "\(name)'s menu is open under the \(field) field; take a screenshot to see it. Pick the account in it. \(locked)"])
                    return
                case .locked:
                    let name = PasswordManagers.name(id), slug = PasswordManagers.slug(id)
                    let yabUnlocks = connections.row(id) == .yabUnlocks
                    answer(["error": yabUnlocks
                        ? "\(name) is locked. Yab has its unlock password: call unlock_manager(\"\(slug)\")."
                        : "\(name) is locked, and you unlock it yourself here: call handoff to ask the person to unlock \(name).",
                            "manager": id, "locked": true, "menuText": Store.testing ? lastMenuText : ""])
                    return
                case .none:
                    continue
                }
            }
            // A test run hears which frames there were, to see a menu missed.
            var out = none
            if Store.testing { out["frames"] = (AgentPage.frames[ObjectIdentifier(tab.page)] ?? []).map(\.href); out["menuText"] = lastMenuText }
            answer(out)
        }
    }

    /// Its menu (and whether its rows could be read), locked, or nothing.
    enum ManagerMenu: Equatable { case menu(String, read: Bool), locked, none }

    /// What the last manager frame said, for a test run's eyes.
    static var lastMenuText = ""

    /// The sign-in field of a document or of its frames of the same site,
    /// marked for its manager's content scripts as the page in front
    /// (extension-shims.js: its menu opens in a tab out of sight), brought
    /// into view, and where it is in this document's viewport; `path` is the
    /// way down to its document, iframe by iframe.
    static let fieldScript = """
    const shown = e => { const r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0 && !e.disabled; };
    const look = (doc, path) => {
      const all = [...doc.querySelectorAll('input')].filter(shown);
      const pick = all.find(e => /username|email/.test(e.autocomplete || '') || e.type === 'email')
        || all.find(e => e.type === 'text' || e.type === '') || all.find(e => e.type === 'password');
      if (pick) return { pick, doc, path };
      const frames = [...doc.querySelectorAll('iframe')];
      for (let i = 0; i < frames.length; i++) {
        let d = null; try { d = frames[i].contentDocument; } catch (e) {}
        const found = d && look(d, path.concat(i));
        if (found) return found;
      }
      return null;
    };
    const found = look(document, []);
    if (!found) return null;
    document.documentElement.setAttribute('data-yab-agent-signing-in', '');
    found.doc.documentElement.setAttribute('data-yab-agent-signing-in', '');
    found.pick.scrollIntoView({ block: 'center' });
    let x = 0, y = 0, doc = document;
    for (const i of found.path) {
      const f = doc.querySelectorAll('iframe')[i], b = f.getBoundingClientRect();
      x += b.left + f.clientLeft; y += b.top + f.clientTop; doc = f.contentDocument;
    }
    const r = found.pick.getBoundingClientRect();
    return { x: x + r.left + Math.min(20, r.width / 2), y: y + r.top + r.height / 2, path: found.path,
             kind: found.pick.type === 'password' ? 'password' : 'email', href: location.href, w: innerWidth, h: innerHeight };
    """

    /// Where another site's frame sits in the page: its iframe, found by its
    /// address, else by its size, through the page's frames of its own site.
    static let frameOffsetScript = """
    const bare = s => String(s || '').split('#')[0];
    const all = [];
    const walk = (doc, x, y) => {
      for (const f of doc.querySelectorAll('iframe')) {
        const b = f.getBoundingClientRect(), fx = x + b.left + f.clientLeft, fy = y + b.top + f.clientTop;
        let d = null; try { d = f.contentDocument; } catch (e) {}
        if (d) walk(d, fx, fy); else all.push({ f, x: fx, y: fy });
      }
    };
    walk(document, 0, 0);
    const near = e => Math.abs(e.f.clientWidth - w) < 3 && Math.abs(e.f.clientHeight - h) < 3;
    const hit = all.find(e => bare(e.f.src) === bare(href) && near(e)) || all.find(e => bare(e.f.src) === bare(href)) || all.find(near);
    return hit ? { x: hit.x, y: hit.y } : null;
    """

    /// What a manager that draws on the page itself shows in the field's
    /// document: the words in its own elements (open shadow roots too), the
    /// screen reader's hints that name it, and whether any of it is big
    /// enough to be its menu.
    static let pageMenuScript = """
    let doc = document;
    for (const i of path) { const f = doc.querySelectorAll('iframe')[i]; doc = f && f.contentDocument; if (!doc) return null; }
    const words = root => {
      let out = '';
      const walker = doc.createTreeWalker(root, NodeFilter.SHOW_TEXT);
      for (let n = walker.nextNode(); n && out.length < 2000; n = walker.nextNode()) {
        const p = n.parentNode && n.parentNode.nodeName;
        if (p !== 'STYLE' && p !== 'SCRIPT') out += ' ' + n.nodeValue;
      }
      return out;
    };
    const mine = [];
    const walk = root => {
      for (const el of root.querySelectorAll('*')) {
        if (mine.length > 40) return;
        if (tags.some(p => el.localName.startsWith(p))) mine.push(el);
        if (el.shadowRoot) walk(el.shadowRoot);
      }
    };
    walk(doc);
    let text = '', big = false;
    for (const el of mine) {
      text += words(el) + (el.shadowRoot ? words(el.shadowRoot) : '');
      const inner = [el, ...el.querySelectorAll('*'), ...(el.shadowRoot ? el.shadowRoot.querySelectorAll('*') : [])].slice(0, 120);
      for (const e of inner) { const r = e.getBoundingClientRect(); if (r.width >= 120 && r.height >= 40) { big = true; break; } }
    }
    let hint = '';
    const field = doc.activeElement;
    if (field && field.getAttribute) {
      hint += ' ' + (field.getAttribute('aria-description') || '');
      for (const id of (field.getAttribute('aria-describedby') || '').split(/\\s+/)) { const d = id && doc.getElementById(id); if (d) hint += ' ' + d.textContent; }
    }
    for (const live of doc.querySelectorAll('[aria-live],[role=status],[role=alert]')) hint += ' ' + live.textContent;
    const clean = s => s.replace(/\\s+/g, ' ').trim();
    hint = clean(hint).toLowerCase().includes(name.toLowerCase()) ? clean(hint) : '';
    return { text: clean(text).slice(0, 600), hint: hint.slice(0, 300), big, count: mine.length };
    """

    /// The sign-in field clicked, as a person's click, and the page asked
    /// within a second what its manager shows: a frame of `origin`, or its
    /// own elements beside the field.
    static func menu(in tab: Tab, origin: URL, manager id: String) async -> ManagerMenu {
        lastMenuText = ""
        guard let field = await signInField(in: tab) else { return .none }
        _ = AgentPage.click(tab.page, x: field.x, y: field.y)
        let clicked = Store.testing ? "field \(Int(field.x)),\(Int(field.y)) in \(field.frame?.url?.absoluteString ?? "the page") \(field.path) | " : ""
        let prefix = origin.absoluteString
        let tags = PasswordManagers.provider(id)?.pageTags ?? []
        let name = PasswordManagers.name(id)
        var seen = false
        lastMenuText = clicked
        for _ in 0..<5 {
            try? await Task.sleep(for: .milliseconds(200))
            await withCheckedContinuation { done in AgentPage.discover(tab.page) { done.resume() } }
            let frames = (AgentPage.frames[ObjectIdentifier(tab.page)] ?? []).filter { $0.href.hasPrefix(prefix) }
            if !frames.isEmpty {
                seen = true
                // Its button and its list are frames of their own; the list draws
                // its rows a beat after it is there. All of them, read as text.
                var said = ""
                for _ in 0..<8 {
                    said = ""
                    for frame in frames {
                        for world in [PageWorld.named("yab-agent"), .page] {
                            if let text = try? await tab.page.call("""
                                const box = [...document.querySelectorAll('input[type=password]')].length > 0;
                                return (box ? 'password-box ' : '') + (document.body ? document.body.textContent.replace(/\\s+/g, ' ').slice(0, 600) : '');
                                """, arguments: [:], in: world, frame: frame.info) as? String {
                                said += " " + text
                                break
                            }
                        }
                    }
                    if !said.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }
                    try? await Task.sleep(for: .milliseconds(150))
                }
                if Store.testing { lastMenuText = clicked + frames.map(\.href).joined(separator: " ") + " | " + said }
                let lower = said.lowercased()
                if lower.contains("password-box") || ["unlock", "locked", "log in to"].contains(where: lower.contains) { return .locked }
                if !lower.trimmingCharacters(in: .whitespaces).isEmpty { return .menu(field.kind, read: true) }
            }
            // Drawn on the page itself, beside the field.
            guard !tags.isEmpty else { continue }
            let drawn = try? await tab.page.call(pageMenuScript, arguments: ["path": field.path, "tags": tags, "name": name],
                                                               in: .named("yab-agent"), frame: field.frame) as? [String: Any]
            guard let drawn else { continue }
            let text = drawn["text"] as? String ?? "", hint = drawn["hint"] as? String ?? ""
            if Store.testing { lastMenuText = clicked + "page \(drawn["count"] ?? 0) big \(drawn["big"] ?? false) | \(text) | \(hint)" }
            let lower = (text + " " + hint).lowercased()
            if lower.contains("locked") || lower.contains("unlock") { return .locked }
            if drawn["big"] as? Bool == true {
                seen = true
                if !text.isEmpty { return .menu(field.kind, read: true) }
            }
        }
        // There, but its rows not readable from here: a menu all the same,
        // and the agent looks at it to see which.
        return seen ? .menu(field.kind, read: false) : .none
    }

    /// Where the sign-in field is: in the page or a frame of its site, else
    /// in another site's frame, placed in the page by its iframe.
    struct SignInField { let x: Double; let y: Double; let kind: String; let path: [Int]; let frame: PageFrame? }

    static func signInField(in tab: Tab) async -> SignInField? {
        func read(_ value: Any?, frame: PageFrame?, dx: Double = 0, dy: Double = 0) -> SignInField? {
            guard let got = value as? [String: Any], let x = got["x"] as? Double, let y = got["y"] as? Double else { return nil }
            return SignInField(x: x + dx, y: y + dy, kind: got["kind"] as? String ?? "email",
                               path: (got["path"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue }, frame: frame)
        }
        if let here = read(try? await tab.page.call(fieldScript, arguments: [:], in: .named("yab-agent")), frame: nil) {
            return here
        }
        // Another site's frame: asked in each, the extensions' own left out.
        await withCheckedContinuation { done in AgentPage.discover(tab.page) { done.resume() } }
        let own = ManagerExtensions.shared.origins
        for frame in AgentPage.frames[ObjectIdentifier(tab.page)] ?? [] where !own.contains(where: frame.href.hasPrefix) {
            guard let inner = try? await tab.page.call(fieldScript, arguments: [:], in: .named("yab-agent"), frame: frame.info) as? [String: Any],
                  inner["x"] != nil else { continue }
            let at = try? await tab.page.call(frameOffsetScript, arguments: ["href": inner["href"] as? String ?? frame.href,
                                                                                            "w": inner["w"] as? Double ?? frame.w, "h": inner["h"] as? Double ?? frame.h],
                                                            in: .named("yab-agent")) as? [String: Any]
            guard let dx = at?["x"] as? Double, let dy = at?["y"] as? Double else { continue }
            return read(inner, frame: frame.info, dx: dx, dy: dy)
        }
        return nil
    }

    /// unlock_manager: the manager's kept unlock password typed by Yab into
    /// its own unlock page, in a background tab of the agent's. One try, the
    /// tab closed after; the password never reaches the agent.
    func handleAgentUnlockManager(_ c: AgentCall) {
        let answer = c.answer
        let session = c.session
        if let alone = c.agents.session(session), alone.unattended || Headless.nobody {
            answer(["error": "nobody is at Yab to do this for this task: skip what needs the password manager, and say so in your answer"])
            return
        }
        let connections = PasswordManagers.Connections.shared
        let wanted = (c.request["provider"] as? String ?? c.request["manager"] as? String ?? "").lowercased()
            .trimmingCharacters(in: .whitespaces)
        guard let id = connections.list.map(\.provider).first(where: {
            PasswordManagers.slug($0) == wanted || PasswordManagers.name($0).lowercased() == wanted || $0 == wanted
        }) else {
            let names = connections.list.map { PasswordManagers.slug($0.provider) }
            answer(["error": names.isEmpty ? "No password manager is connected to Yab: call handoff so the person signs in"
                : "Name one of the connected password managers: \(names.joined(separator: ", "))"])
            return
        }
        let name = PasswordManagers.name(id)
        let person: [String: Any] = ["error": "\(name) is unlocked by the person here: call handoff to ask them to unlock \(name), then call sign_in again"]
        guard connections.connection(id)?.mode == .yab, PasswordManagers.yabMayUnlock(id) else { answer(person); return }
        guard connections.row(id) != .wrongPassword else {
            answer(["error": "\(name)'s saved unlock password didn't work before: don't try again. Call handoff to ask the person to unlock \(name)."])
            return
        }
        // Never for a private tab: the page the agent signs in on.
        let page = self.find(c.request, in: c.browser)
        if let page, page.shy { answer(["error": "not in a private tab: call handoff"]); return }
        // Ask asks first, as a sign-in does; Touch ID after, when asked for.
        let key = "unlock:" + id
        if let page, let session, c.browser.prefs.asking(session) == .ask {
            if let yes = page.approved, yes.session == session, yes.ref == key {
                page.approved = nil
            } else if page.declined.remove(session) != nil {
                answer(["error": "the person said not now to unlocking \(name): call handoff or stop"]); return
            } else {
                c.agents.ask(page, AgentPermit(kind: .unlockManager(provider: id), session: session,
                                               detail: "Yab types your \(name) unlock password; the agent doesn't see it."))
                answer(["error": "unlocking waits for the person's yes; asking them now", "asking": true]); return
            }
        }
        Vault.proveToFill(on: name, agent: true) { proven in
            guard proven == .yes else { answer(["error": "the person said no to unlocking \(name): call handoff or stop"]); return }
            let secret: String
            switch ManagerUnlock.fetch(id) {
            case .found(let text): secret = text
            case .locked: answer(["error": "Your Mac is locked, so Yab can't read \(name)'s unlock password: call handoff"]); return
            case .missing: answer(["error": "\(name)'s unlock password is missing on this Mac: call handoff to ask the person to unlock \(name)"]); return
            }
            ManagerUnlock.run(id, secret: secret, in: c.browser, session: session, house: { self.house($0) }) { outcome in
                switch outcome {
                case .unlocked:
                    connections.unlocked(id, ok: true)
                    ManagerUnlock.nudge()
                    // 1Password's menu comes back only on a page loaded since.
                    if id == PasswordManagers.onePassword { page?.reload() }
                    answer(["ok": true, "unlocked": true, "said": "\(name) is unlocked. Call sign_in again."])
                case .notUnlocked:
                    connections.unlocked(id, ok: false)
                    answer(["error": "\(name) didn't unlock with the saved password. Don't try again: call handoff to ask the person to unlock \(name).",
                            "not_unlocked": true])
                case .noField:
                    answer(["error": "\(name)'s unlock page showed no password box, so it may be unlocked already: call sign_in again, else handoff"])
                case .notRunning:
                    answer(["error": "\(name)'s extension isn't on in Yab: call handoff"])
                }
            }
        }
    }
}
