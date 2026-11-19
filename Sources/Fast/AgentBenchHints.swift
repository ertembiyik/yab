import AppKit
import WebKit

// Bench.agentCommand's verbs (AgentBench). Hints: history, what the person
// does on sites, and landings.

extension Bench {
    static let hintsVerbs: [String: AgentHandler] = [
        "agent-history": { $0.handleAgentHistory($1) },
        "agent-devices": { $0.handleAgentDevices($1) },
        "agent-calendar": { $0.handleAgentCalendar($1) },
        "agent-calendar-add": { $0.handleAgentCalendarAdd($1) },
        "agent-calendar-free": { $0.handleAgentCalendarFree($1) },
        "agent-hint": { $0.handleAgentHint($1) },
        "agent-hints": { $0.handleAgentHints($1) },
        "hints-copy": { $0.handleHintsCopy($1) },
        "hints-visits": { $0.handleHintsVisits($1) },
        "hints-habits": { $0.handleHintsHabits($1) },
        "hints-promises": { $0.handlePromises($1) },
        "agent-landing": { $0.handleAgentLanding($1) },
    ]

    func handleAgentHistory(_ c: AgentCall) {
        let request = c.request
        let answer = c.answer
        let agents = c.agents
        let session = c.session
        // Off the main thread: other browsers' files are copied and read.
        let words = request["query"] as? String
        let site = request["site"] as? String
        let device = request["device"] as? String
        let days = request["days"] as? Int
        let epoch = ContextPrivacy.shared.epoch
        let admission = agents.session(session)?.admission
        let allowed = { ContextPrivacy.shared.current(epoch) && (admission?.valid ?? true) }
        guard allowed() else { answer(["error": "This context was cleared."]); return }
        ConsentAudit.record("history.read")
        agents.touch(session, "history")
        // What they did then, as the day's threads: a time named, or asked for.
        let when = request["when"] as? String
        if when?.isEmpty == false || request["threads"] as? Bool == true {
            Task { @MainActor in
                guard allowed() else { answer(["error": "This context was cleared."]); return }
                let text = await AgentHistory.threads(when: when, query: words, days: days ?? 30)
                guard allowed() else { answer(["error": "This task's permission expired."]); return }
                answer(["text": text])
            }
            return
        }
        // The iPhone's and other Macs' places come through sync, named.
        AgentDevices.named {
            guard allowed() else { answer(["error": "This context was cleared."]); return }
            let source = AgentDevices.source()
            DispatchQueue.global(qos: .userInitiated).async {
                guard allowed() else { DispatchQueue.main.async { answer(["error": "This context was cleared."]) }; return }
                let elsewhere = AgentDevices.visits(source)
                let text = (words?.isEmpty == false || site?.isEmpty == false || device?.isEmpty == false)
                    ? AgentHistory.pages(matching: words, host: site, device: device, days: days ?? 365, elsewhere: elsewhere)
                    : AgentHistory.sites(days: days ?? AgentHistory.window, elsewhere: elsewhere)
                DispatchQueue.main.async {
                    // Words: the threads they match lead, the pages after.
                    guard words?.isEmpty == false, site?.isEmpty != false, device?.isEmpty != false else { return answer(["text": text]) }
                    Task { @MainActor in
                        guard allowed() else { answer(["error": "This task's permission expired."]); return }
                        let threads = await AgentHistory.threads(when: nil, query: words, days: days ?? 30)
                        guard allowed() else { answer(["error": "This task's permission expired."]); return }
                        answer(["text": threads.hasSuffix("Nothing for that.") ? text : threads + "\n# Pages that match\n\n" + text])
                    }
                }
            }
        }
    }

    func handleAgentDevices(_ c: AgentCall) {
        let answer = c.answer
        c.agents.touch(c.session, "devices")
        AgentDevices.named {
            let source = AgentDevices.source()
            let seen = Dictionary(SyncCenter.shared.devices.compactMap { d in d.lastSeen.map { (d.id, $0) } }, uniquingKeysWith: { a, _ in a })
            DispatchQueue.global(qos: .userInitiated).async {
                let text = AgentDevices.describe(source, seen: seen)
                DispatchQueue.main.async { answer(["text": text]) }
            }
        }
    }

    func handleAgentCalendar(_ c: AgentCall) {
        let request = c.request
        let answer = c.answer
        c.agents.touch(c.session, "calendar")
        let calendar = Calendar.current
        let first = (request["from"] as? String).flatMap(AgentCalendar.day) ?? calendar.startOfDay(for: Date())
        let days = min(max(request["days"] as? Int ?? 1, 1), 31)
        let last = calendar.date(byAdding: .day, value: days, to: first) ?? first.addingTimeInterval(Double(days) * 86_400)
        Task { @MainActor in
            let busy = await Meetings.shared.busy(from: first, to: last)
            answer(["text": AgentCalendar.describe(busy, from: first, days: days, meetings: Meetings.shared.list)])
        }
    }

    func handleAgentCalendarFree(_ c: AgentCall) {
        let request = c.request
        let answer = c.answer
        c.agents.touch(c.session, "calendar")
        let now = MailClock.now
        let first = (request["from"] as? String).flatMap(AgentCalendar.day).map { max($0, now) } ?? now
        let days = min(max(request["days"] as? Int ?? MailSlots.reach, 1), 20)
        let minutes = request["minutes"] as? Int
        // Working days can stretch over weekends: three weeks' calendar read.
        let last = first.addingTimeInterval(Double(days * 2 + 7) * 86_400)
        Task { @MainActor in
            let busy = await Meetings.shared.busy(from: Calendar.current.startOfDay(for: first), to: last)
            answer(["text": AgentCalendar.free(busy, from: first, days: days, minutes: minutes)])
        }
    }

    func handleAgentCalendarAdd(_ c: AgentCall) {
        let request = c.request
        c.agents.touch(c.session, "calendar")
        let accounts = MeetingsGoogle.accounts.isEmpty ? MailCenter.shared.accounts : MeetingsGoogle.accounts
        switch AgentCalendar.page(request, accounts: accounts) {
        case .success(let url): c.answer(["url": url.absoluteString, "account": AgentCalendar.account(request, accounts: accounts) ?? ""])
        case .failure(let why): c.answer(["error": why.text])
        }
    }

    func handleAgentHint(_ c: AgentCall) {
        let request = c.request
        let browser = c.browser
        let answer = c.answer
        // A new tab's row taken, without a hand, a --test run only.
        guard Store.testing else { answer(["error": "agent-hint only works on a --test run"]); return }
        let rows = Hints.shared.rows
        // By a word of its title, or by its place.
        let named = (request["title"] as? String).flatMap { word in rows.firstIndex { $0.title.localizedCaseInsensitiveContains(word) } }
        let index = named ?? request["index"] as? Int ?? 0
        guard rows.indices.contains(index) else { answer(["error": "no row \(index), there are \(rows.count)"]); return }
        let hint = rows[index]
        // Or one of its menu's items: later, tomorrow, done, never; x, its ×.
        switch request["menu"] as? String {
        // yab's own rows: Not Today and Done are one, Don't Suggest This.
        case let action? where hint.local && ["later", "done", "today"].contains(action): Noticing.shared.hideToday(hint)
        case "later"?: Hints.shared.putOff(hint, until: Hints.laterToday(from: Hints.now))
        case "tomorrow"?: Hints.shared.putOff(hint, until: Hints.tomorrowMorning(from: Hints.now))
        case "done"?: Hints.shared.finish(hint)
        // scope "person": the sender's mail; otherwise the row's kind.
        case "never"?: Hints.shared.never(hint, person: request["scope"] as? String == "person")
        case "x"?: Hints.shared.dismiss(hint)
        case "join"?:
            guard let join = hint.join else { answer(["error": "no join on \(hint.title)"]); return }
            browser.take(Suggestion(key: join.host() ?? "", title: hint.title, url: join, kind: .address))
        default: Hints.shared.take(hint, in: browser)
        }
        answer(["ok": true, "took": hint.title])
    }

    func handleAgentHints(_ c: AgentCall) {
        let request = c.request
        let answer = c.answer
        // The new tab's rows as drawn and what is kept behind them,
        // with the clock moved on first if asked, a --test run only.
        guard Store.testing else { answer(["error": "agent-hints only works on a --test run"]); return }
        if let seconds = request["clock"] as? Double { Hints.offset += seconds }
        if request["reset"] as? Bool == true { Hints.offset = 0 }
        if request["forget"] as? Bool == true { Hints.shared.forget() }
        if let ids = request["drop"] as? [String] { Hints.shared.drop(ids) }
        Hints.shared.refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { answer(Hints.shared.state()) }
    }

    /// Promises in Now (Promises), a --test run only. `forget` starts over;
    /// `add` hands over promises as mail would have them ({quote, person,
    /// address, theirs, kind, said: hours ago, thread}, the day read from
    /// the quote as mail's is); `read` runs a sentence through the rules;
    /// `act` does a row's action ({id, what: done|not|later|nudge|open});
    /// `field` opens the plain field as a person would, the two rows that
    /// stand counted as seen today. The answer: every promise, its window,
    /// its words, whether it may stand, and the field's rows.
    func handlePromises(_ c: AgentCall) {
        let request = c.request
        let answer = c.answer
        guard Store.testing else { answer(["error": "promises only works on a --test run"]); return }
        let promises = Promises.shared
        if let seconds = request["clock"] as? Double { Hints.offset += seconds }
        if request["forget"] as? Bool == true { promises.forget() }
        if let on = request["on"] as? Bool { Noticing.shared.promisesOn = on }
        let now = Hints.now
        // A site's notification, as SiteNotices hands one over.
        if let note = request["notify"] as? [String: String], let origin = (note["origin"]).flatMap(URL.init(string:)) {
            promises.heard(origin: origin, title: note["title"] ?? "", body: note["body"] ?? "")
        }
        if let sentences = request["read"] as? [String] {
            answer(["read": sentences.map { sentence -> [String: Any] in
                let mine = MailPromise.reading(sentence), theirs = MailPromise.theirReading(sentence)
                let due = MailPromise.when(in: sentence, at: now)
                return ["sentence": sentence, "mine": mine != nil, "theirs": theirs != nil, "kind": mine?.kind.rawValue ?? "",
                        "judgment": mine?.judgment ?? false, "due": due.map { ISO8601DateFormatter().string(from: $0.date) } ?? "",
                        "soft": due?.soft ?? false, "timed": due?.timed ?? false]
            }])
            return
        }
        for item in request["add"] as? [[String: Any]] ?? [] {
            let quote = item["quote"] as? String ?? ""
            let at = now.addingTimeInterval(-(item["said"] as? Double ?? 24) * 3600)
            let due = MailPromise.when(in: quote, at: at)
            let theirs = item["theirs"] as? Bool ?? false
            let read = theirs ? MailPromise.theirReading(quote) : MailPromise.reading(quote)
            guard let read else { continue }
            let promise = MailPromised(message: UUID().uuidString, thread: item["thread"] as? String ?? UUID().uuidString, quote: quote,
                                       person: item["person"] as? String ?? "", address: item["address"] as? String ?? "",
                                       kind: read.kind, due: due?.date, at: at, state: read.judgment ? .judgment : .open, theirs: theirs,
                                       soft: due?.soft ?? false, timed: due?.timed ?? false)
            promises.testing.append(.init(promise: promise, account: "test@yab.test", heard: item["heard"] as? Bool ?? false))
        }
        Hints.shared.compose()
        if let act = request["act"] as? [String: Any], let id = act["id"] as? String,
           let hint = Hints.shared.row(id) ?? promises.upcoming(now: now).first(where: { $0.id == id }) {
            switch act["what"] as? String {
            case "done"?: promises.done(hint)
            case "not"?: promises.notAPromise(hint)
            case "later"?: promises.putOff(id, until: Hints.tomorrowMorning(from: now)); Hints.shared.compose()
            case "nudge"?: promises.nudged(id); Hints.shared.compose()
            case "open"?: promises.acted(id)
            default: break
            }
        }
        var out = promises.state(now: now)
        if request["field"] as? Bool == true {
            let browser = c.browser
            Hints.shared.compose()
            let queue = browser.nowHints()
            let standing = browser.nowStanding(queue, room: 2, now: now)
            out["field"] = standing.map { ["id": $0.id, "title": $0.title, "status": HintList.status($0, now: now)] }
            out["more"] = queue.count - standing.count
            out["queue"] = queue.map(\.id)
            // Rows handed to the agent (Do It), their tasks and which answers were opened.
            out["handed"] = Hints.shared.handed
            out["answered"] = Hints.shared.answeredBy
        }
        answer(out)
    }

    func handleHintsCopy(_ c: AgentCall) {
        let request = c.request
        let answer = c.answer
        // A link copied as though in another app, for the row under
        // the field, a --test run only.
        guard Store.testing else { answer(["error": "hints-copy only works on a --test run"]); return }
        guard let url = (request["url"] as? String).flatMap(URL.init(string:)), Clips.isLink(url.absoluteString) else {
            answer(["error": "hints-copy wants an http(s) address"])
            return
        }
        Clips.shared.pretend(url, app: request["app"] as? String ?? "Slack")
        answer(Hints.shared.state())
    }

    func handleHintsVisits(_ c: AgentCall) {
        let request = c.request
        let answer = c.answer
        // Visits for habits, from a JSON file of {url, at (ISO 8601),
        // title}, in place of the history, a --test run only; "none"
        // gives the history back.
        guard Store.testing else { answer(["error": "hints-visits only works on a --test run"]); return }
        if request["path"] as? String == "none" {
            Noticing.shared.visits = nil
        } else {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let path = request["path"] as? String, let data = FileManager.default.contents(atPath: path),
                  let visits = try? decoder.decode([Habits.Visit].self, from: data) else {
                answer(["error": "hints-visits wants a JSON file of [{url, at, title}]"])
                return
            }
            Noticing.shared.visits = visits
        }
        Noticing.shared.countHabits(now: Hints.now)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { answer(Noticing.shared.state()) }
    }

    func handleHintsHabits(_ c: AgentCall) {
        let request = c.request
        let answer = c.answer
        // The habits found for today and why: the window, the days, and
        // whether it is their time now. "count" counts them again first.
        if request["count"] as? Bool == true {
            Noticing.shared.countHabits(now: Hints.now)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { answer(Noticing.shared.state()) }
        } else {
            answer(Noticing.shared.state())
        }
    }

    func handleAgentLanding(_ c: AgentCall) {
        let request = c.request
        let browser = c.browser
        let answer = c.answer
        // Where the last row's page landed, a --test run only.
        guard Store.testing else { answer(["error": "agent-landing only works on a --test run"]); return }
        guard let tab = find(request, in: browser) ?? browser.active, let landed = Landing.last[tab.id] else { answer(["error": "no landing"]); return }
        answer(["quote": landed.quote, "found": landed.found])
    }
}
