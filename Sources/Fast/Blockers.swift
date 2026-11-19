import AppKit
import SwiftUI
import WebKit

// One ad blocker at a time (docs/ad-blocker-source.md).
//
// Shield blocks out of the box. An ad blocker extension, added from the
// store, a file, Bring In or the welcome, comes in turned off, and Yab asks
// once which one should block. The answer is Shield.chosen. The extension
// picked is turned on and the others off; Shield keeps blocking until the
// extension's first compiled rule file is held (ExtensionRules), and only
// then steps aside (Shield.source). Its rules failing, or the extension
// going away, gives the pages back to Shield, whose compiled lists never
// went anywhere.
//
// "Off on this site" is one state, Shield.paused, whoever blocks: with an
// extension blocking, Yab gives it a session allowAllRequests rule for the
// site, ids from a range kept for Yab, written again each time it loads
// (session rules die with it). The other way, a site the extension allows
// all requests on, from its own popup, is read from its rules each time it
// recompiles and marked off here too.

@available(macOS 15.4, *)
@MainActor
enum Blockers {
    /// Ad blockers by their Chrome Web Store id.
    static let known: [String: String] = [
        "ddkjiahejlhfcafbddmgiahcphecmpfh": "uBlock Origin Lite",
        "gighmmpiobklfepjocnamgkkbiglidom": "AdBlock",
        "bgnkhhnnamicmpeenaelnjfhikgbkllg": "AdGuard",
        "cfhdojbkjhnklbpkdaibdccddilifddb": "Adblock Plus",
        "mlomiejdfkolichcflejclcbmpeaniij": "Ghostery",
        // Manifest V2, can't run on WebKit: Bring In only (its sites).
        classic: "uBlock Origin",
    ]
    static let classic = "cjpalhdlnbpafiamejdnhcphjbkeiagm"

    /// Lightest first, for when several arrive together (Bring In, two
    /// installs in a row, a launch finding several on): the one offered
    /// on the card, whatever order they finished installing in. uBlock
    /// Origin Lite compiles in a second and rests at 0.2% of a core with
    /// 20 tabs; AdBlock compiles for 13-17 s (extension-ad-blockers.md).
    /// Blockers Yab doesn't know come after these, in the order given.
    nonisolated static let lightest = [
        "ddkjiahejlhfcafbddmgiahcphecmpfh", // uBlock Origin Lite
        "bgnkhhnnamicmpeenaelnjfhikgbkllg", // AdGuard
        "mlomiejdfkolichcflejclcbmpeaniij", // Ghostery
        "cfhdojbkjhnklbpkdaibdccddilifddb", // Adblock Plus
        "gighmmpiobklfepjocnamgkkbiglidom", // AdBlock
    ]

    /// The one of these to offer: the lightest Yab knows, else the first.
    /// YAB_BLOCKER_ORDER=added offers the last one added, as before.
    nonisolated static func preferred(_ ids: [String]) -> String? {
        if ProcessInfo.processInfo.environment["YAB_BLOCKER_ORDER"] == "added" { return ids.last }
        return ids.min { rank($0) < rank($1) }
    }

    nonisolated private static func rank(_ id: String) -> Int {
        lightest.firstIndex(of: id) ?? lightest.count
    }

    /// Session rule ids Yab keeps for itself in a blocker's rules.
    nonisolated static let firstRule = 1_987_000_000
    nonisolated static let rules = 1_000_000

    /// An ad blocker: one Yab knows by its store id, or one that blocks
    /// with declarativeNetRequest rule sets of over 10,000 rules.
    nonisolated static func isBlocker(_ id: String, folder: URL) -> Bool {
        if known[id] != nil { return true }
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return isBlocker(manifest: manifest, folder: folder)
    }

    nonisolated static func isBlocker(manifest: [String: Any], folder: URL) -> Bool {
        let permissions = (manifest["permissions"] as? [String] ?? []) + (manifest["optional_permissions"] as? [String] ?? [])
        guard permissions.contains(where: { $0.hasPrefix("declarativeNetRequest") }),
              let sets = (manifest["declarative_net_request"] as? [String: Any])?["rule_resources"] as? [[String: Any]]
        else { return false }
        var count = 0
        for set in sets where set["enabled"] as? Bool != false {
            guard let path = set["path"] as? String,
                  let data = try? Data(contentsOf: folder.appendingPathComponent(path), options: .mappedIfSafe)
            else { continue }
            count += occurrences(of: Data("\"action\"".utf8), in: data, upTo: 10_001 - count)
            if count > 10_000 { return true }
        }
        return false
    }

    nonisolated static func occurrences(of needle: Data, in data: Data, upTo most: Int) -> Int {
        var count = 0
        var from = data.startIndex
        while count < most, let found = data.range(of: needle, in: from..<data.endIndex) {
            count += 1
            from = found.upperBound
        }
        return count
    }

    static var extensions: Extensions { Extensions.shared }

    static func isBlocker(_ id: String) -> Bool {
        isBlocker(id, folder: Extensions.folder(for: id))
    }

    /// Its short name: AdBlock's full one is a sentence.
    static func name(_ id: String) -> String {
        if let known = known[id] { return known }
        if let short = extensions.contexts[id]?.webExtension.displayShortName, !short.isEmpty { return short }
        return extensions.installed.first { $0.id == id }?.name ?? id
    }

    /// Every ad blocker installed, in the order added.
    static var installed: [Installed] {
        extensions.installed.filter { isBlocker($0.id) }
    }

    // MARK: - launch

    static func start() {
        let shield = Shield.shared
        shield.handsOver = { id, persistent in
            // Not while its compiled file is gone mid-recompile: new pages
            // get no list of its then (ExtensionRules.give), so Shield's.
            guard ExtensionRules.ready(id), let context = Extensions.shared.contexts[id] else { return false }
            return persistent || context.hasAccessToPrivateData
        }
        shield.dropExtension = { controller, id, off in ExtensionRules.drop(controller, id, off: off) }
        ExtensionRules.landed = { id in landed(id) }
        ExtensionRules.lookupFailed = { id, _ in
            Shield.shared.fellBack(id, failed: true)
        }
        // Before this: a blocker already on was blocking beside Shield. It
        // goes on blocking, alone now; another one on beside it is asked
        // about the next time ⌘E opens.
        if !Store.settings.bool(forKey: "shield.sourceKnown") {
            Store.settings.set(true, forKey: "shield.sourceKnown")
            let on = installed.filter(\.enabled).map(\.id)
            if shield.chosen == nil, let first = preferred(on) {
                shield.choose(first)
                if on.count > 1 {
                    owed = on.filter { $0 != first }
                    Store.settings.set(owed, forKey: "shield.owed")
                }
            }
        }
        // The chosen one no longer here, or turned off: Built-in.
        if let chosen = shield.chosen, !extensions.installed.contains(where: { $0.id == chosen && $0.enabled }) {
            shield.choose(nil)
        }
        if let chosen = shield.chosen, ExtensionRules.holds(chosen) { landed(chosen) }
    }

    // MARK: - arriving

    /// Ad blockers added and not yet answered for, kept across launches:
    /// the card comes back once, the next time ⌘E opens.
    private(set) static var owed: [String] = Store.settings.stringArray(forKey: "shield.owed") ?? []
    private static var askedAgain = Store.settings.bool(forKey: "shield.askedAgain")
    private static var asking = false

    /// What Bring In brought for each, said in the card's footer.
    static var broughtWith: [String: (sites: Int, hiding: Int)] = [:]

    /// A blocker on its way in: whether it comes in turned off until the
    /// card is answered. Every one is, but the one already chosen.
    static func arrivesOff(_ id: String, folder: URL) -> Bool {
        guard isBlocker(id, folder: folder) else { return false }
        if Shield.shared.chosen == id { return false }
        if !owed.contains(id) { owed.append(id) }
        Store.settings.set(owed, forKey: "shield.owed")
        return true
    }

    /// Added, turned off: the card, once the welcome is over. A test run
    /// told to answer every question answers it here too: yes picks it.
    static func arrived(_ id: String) {
        if let ahead = answeredAhead(id) {
            answered(ahead, new: [id])
            return
        }
        if Store.testing, let answer = extensions.answerForTests {
            answered(answer ? .pick(id) : .builtIn, new: [id])
            return
        }
        // The card already up for another one: asked again with both, so
        // what it offers doesn't depend on which finished installing first.
        if asking, let card, ProcessInfo.processInfo.environment["YAB_BLOCKER_ORDER"] != "added" {
            superseded = true
            Questions.shared.withdraw(card)
            return
        }
        Task { await ask() }
    }

    /// The welcome's Bring answered before they came: Yab's blocker
    /// ("builtin"), or the one of them to use. Kept across launches, as the
    /// extensions may land after a relaunch, until each has come.
    private static let aheadKey = "shield.ahead", aheadForKey = "shield.aheadFor"

    static func decideAhead(builtIn: Bool, among ids: [String]) {
        guard !ids.isEmpty else { return }
        Store.settings.set(builtIn ? "builtin" : preferred(ids) ?? ids[0], forKey: aheadKey)
        Store.settings.set(ids, forKey: aheadForKey)
    }

    /// The answer given ahead for this one, used up as it comes: Built-in,
    /// it picked, or another's picked and it stays off.
    static func answeredAhead(_ id: String) -> Answer? {
        guard var waiting = Store.settings.stringArray(forKey: aheadForKey), waiting.contains(id),
              let ahead = Store.settings.string(forKey: aheadKey) else { return nil }
        waiting.removeAll { $0 == id }
        if waiting.isEmpty {
            Store.settings.removeObject(forKey: aheadKey)
            Store.settings.removeObject(forKey: aheadForKey)
        } else {
            Store.settings.set(waiting, forKey: aheadForKey)
        }
        return ahead == "builtin" ? .builtIn : ahead == id ? .pick(id) : .keep
    }

    enum Answer: Equatable {
        case builtIn
        case pick(String)
        case keep
        /// The bench pressing Return: the card's selected tile.
        case selected
    }

    /// The question: Built-in, the one blocking now, the ones just added.
    static func ask() async {
        guard !asking, !owed.isEmpty else { return }
        asking = true
        defer { asking = false }
        // In the welcome, it waits until the welcome is over.
        while BrowserWindows.shared.browsers.contains(where: \.welcoming) {
            try? await Task.sleep(for: .seconds(1))
        }
        while true {
            let new = owed.filter { id in extensions.installed.contains { $0.id == id } }
            guard let latest = preferred(new) else {
                owed = []
                Store.settings.set(owed, forKey: "shield.owed")
                return
            }
            let current = Shield.shared.chosen.flatMap { id in new.contains(id) ? nil : id }
            let choice = BlockerChoice(latest: latest, current: current)
            let question = Question(
                title: "Which ad blocker should Yab use?",
                detail: "One blocks at a time.",
                yes: "Use \(name(latest))", no: "Keep \(current.map(name) ?? "Built-in")", place: .plain,
                accessory: AnyView(BlockerOptions(choice: choice)),
                bare: true,
                keys: { choice.key($0) }
            )
            card = question.id
            offered = latest
            superseded = false
            let yes = await extensions.ask(question)
            card = nil
            offered = nil
            // Another blocker arrived while it was up: asked again with it.
            if superseded, forced == nil { continue }
            // The card answers with its buttons; a row's Keep answers through
            // `choice`, the bench through `forced`.
            // "Keep" (esc, the left tile) keeps what blocks now, Built-in or the
            // extension already chosen.
            let answer: Answer = forced.map { $0 == .selected ? .pick(latest) : $0 }
                ?? (yes && !choice.kept ? .pick(latest) : current == nil ? .builtIn : .keep)
            forced = nil
            answered(answer, new: new)
            return
        }
    }

    private static var forced: Answer?
    private static var card: UUID?
    /// The extension the card offers (its selected tile), for the bench.
    private static var offered: String?
    private static var superseded = false

    /// The bench's answer, a test run only: the card's, if it is up, or
    /// straight away: an id picks it, "builtin" and "keep" as the card.
    static func benchAnswer(_ pick: String) {
        let answer: Answer = pick == "builtin" ? .builtIn : pick == "keep" ? .keep : pick == "selected" ? .selected : .pick(pick)
        if asking, let card {
            forced = answer
            Questions.shared.withdraw(card)
        } else if answer == .selected {
            if let id = preferred(owed) { answered(.pick(id), new: owed) }
        } else {
            answered(answer, new: owed)
        }
    }

    static var report: [String: Any] {
        ["owed": owed, "asking": asking, "offered": offered ?? "", "blockers": installed.map(\.id),
         "helpers": Array(helpers.keys).sorted(), "last_run": lastRun]
    }

    /// The card's answer: the one picked turned on, every other blocker off.
    static func answered(_ answer: Answer, new: [String]) {
        owed.removeAll { new.contains($0) }
        Store.settings.set(owed, forKey: "shield.owed")
        switch answer {
        case .keep:
            for id in new where id != Shield.shared.chosen { extensions.setEnabled(id, false) }
        case .builtIn:
            use(nil)
        case .pick(let id):
            use(id)
        case .selected:
            break
        }
    }

    /// ⌘E opened: the card once more for a blocker never answered for.
    static func askAgainIfOwed() {
        guard !owed.isEmpty, !askedAgain, !asking else { return }
        askedAgain = true
        Store.settings.set(true, forKey: "shield.askedAgain")
        Task { await ask() }
    }

    // MARK: - choosing

    private static var switching = false
    private static var chosenAt: Date?

    /// Blocking with this extension, or Built-in for nil: the one picked
    /// turned on, the other blockers turned off (not removed).
    static func use(_ id: String?) {
        switching = true
        defer { switching = false }
        Shield.shared.choose(id)
        for item in installed where item.id != id && item.enabled {
            extensions.setEnabled(item.id, false)
        }
        guard let id else { return }
        chosenAt = Date()
        if extensions.installed.contains(where: { $0.id == id && !$0.enabled }) {
            extensions.setEnabled(id, true)
        } else if ExtensionRules.holds(id) {
            landed(id)
        }
        watchForFailure(id)
    }

    /// No compiled file two minutes after it was picked: its rules didn't
    /// load. Shield blocks meanwhile, as it does anyway.
    private static func watchForFailure(_ id: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) {
            guard Shield.shared.chosen == id, Shield.shared.source == .builtIn, !ExtensionRules.holds(id),
                  extensions.contexts[id] != nil else { return }
            Shield.shared.fellBack(id, failed: true)
        }
    }

    /// Settings' Try Again: the extension started again, its rules
    /// compiled again.
    static func retry() {
        guard let id = Shield.shared.chosen else { return }
        switching = true
        defer { switching = false }
        Shield.shared.choose(id)
        extensions.setEnabled(id, false)
        extensions.setEnabled(id, true)
        watchForFailure(id)
    }

    /// Turned on or off by hand, in Extensions: a blocker turned on is
    /// picked, the chosen one turned off leaves Built-in.
    static func enabledByHand(_ id: String, _ on: Bool) {
        guard !switching, isBlocker(id) else { return }
        if on, Shield.shared.chosen != id {
            DispatchQueue.main.async { use(id) }
        } else if !on, Shield.shared.chosen == id {
            Shield.shared.choose(nil)
        }
    }

    /// Settings › Privacy's Ad blocker switch: off turns the extension
    /// blocking off too, on turns it back on.
    static func shieldSwitched(_ on: Bool) {
        guard let id = Shield.shared.chosen else { return }
        switching = true
        defer { switching = false }
        extensions.setEnabled(id, on)
    }

    // MARK: - its life

    /// Loaded: Yab's own pauses written again, session rules having gone
    /// with it.
    static func loaded(_ id: String) {
        guard Shield.shared.chosen == id else { return }
        writePauses(id)
        if ExtensionRules.holds(id) { landed(id) }
    }

    /// Unloaded, turned off or removed: Built-in, at once.
    static func unloaded(_ id: String) {
        helpers[id] = nil
        Shield.shared.fellBack(id, failed: false)
    }

    static func removed(_ id: String) {
        owed.removeAll { $0 == id }
        Store.settings.set(owed, forKey: "shield.owed")
        if Shield.shared.chosen == id { Shield.shared.choose(nil) }
        Store.settings.removeObject(forKey: "shield.compile.\(id)")
        Store.settings.removeObject(forKey: "shield.theirs.\(id)")
        Store.settings.removeObject(forKey: "shield.wrote.\(id)")
        Store.settings.removeObject(forKey: "shield.marked.\(id)")
    }

    /// Its newly compiled rules are held: the handover, and the sites
    /// waiting on it turned off for real.
    static func landed(_ id: String) {
        guard Shield.shared.chosen == id else { return }
        Shield.shared.landed(id)
        if let since = pauseAskedAt[id] {
            pauseAskedAt[id] = nil
            Shield.shared.timed(id, seconds: Date().timeIntervalSince(since))
        }
        let hosts = Array(Shield.shared.waiting.keys)
        for host in hosts { Shield.shared.wait(host, false) }
        if !hosts.isEmpty { reload(hosts) }
        readTheirPauses(id)
    }

    private static func reload(_ hosts: [String]) {
        for browser in BrowserWindows.shared.browsers {
            for tab in browser.tabs where hosts.contains(browser.curtain.host(of: tab.address) ?? "") {
                browser.reloadForChange(tab, .blocking)
            }
        }
    }

    // MARK: - off on a site

    private static var pauseAskedAt: [String: Date] = [:]

    /// Off or on for a site with an extension blocking: its rules change,
    /// and the tab reloads once they land. True when the extension was told
    /// and the page waits for it, false when Shield alone answers.
    @discardableResult
    static func paused(_ host: String, _ off: Bool) -> Bool {
        guard let id = Shield.shared.chosen, extensions.contexts[id] != nil else { return false }
        pauseAskedAt[id] = Date()
        writePauses(id)
        // Its list comes off the site's pages at once (Shield.fit), so the
        // page reloads now; the rule is what keeps it so in new tabs and
        // after a launch. `waiting` and the countdown are for an extension
        // whose list can't be taken off, none so far.
        return false
    }

    /// The seconds left before an off reaches this site's pages, nil when
    /// none is waiting; 0 past the time the last compile took.
    static func left(_ host: String, now: Date = Date()) -> Double? {
        guard let since = Shield.shared.waiting[host], let id = Shield.shared.chosen else { return nil }
        guard let took = Shield.shared.compileSeconds(id) else { return -1 }
        return max(0, took - now.timeIntervalSince(since))
    }

    nonisolated static func ruleID(_ host: String) -> Int {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in host.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return firstRule + Int(hash % UInt64(rules))
    }

    /// The allowAllRequests rule Yab gives a blocker for a site turned off.
    nonisolated static func pauseRule(_ host: String) -> [String: Any] {
        ["id": ruleID(host), "priority": 1_000_000,
         "action": ["type": "allowAllRequests"],
         "condition": ["requestDomains": [host], "resourceTypes": ["main_frame", "sub_frame"]]]
    }

    private static func writePauses(_ id: String) {
        let hosts = Shield.shared.paused.sorted()
        // Nothing to write, and nothing of Yab's there: its page isn't
        // even opened.
        let wrote = "shield.wrote.\(id)"
        if hosts.isEmpty, !Store.settings.bool(forKey: wrote) { return }
        Store.settings.set(!hosts.isEmpty, forKey: wrote)
        let add = hosts.map(pauseRule)
        guard let json = try? JSONSerialization.data(withJSONObject: add),
              let text = String(data: json, encoding: .utf8) else { return }
        let script = """
        const d = chrome.declarativeNetRequest;
        const want = \(text);
        const have = await d.getSessionRules();
        const mine = have.filter(r => r.id >= \(firstRule) && r.id < \(firstRule + rules));
        const wanted = new Set(want.map(r => r.id));
        const removeRuleIds = mine.filter(r => !wanted.has(r.id)).map(r => r.id);
        const held = new Set(mine.map(r => r.id));
        const addRules = want.filter(r => !held.has(r.id));
        if (removeRuleIds.length || addRules.length) await d.updateSessionRules({ removeRuleIds, addRules });
        return addRules.length + removeRuleIds.length;
        """
        Task { _ = await run(script, in: id) }
    }

    /// Sites the extension allows everything on by its own rules (its
    /// popup's pause, a trusted site), read each time it recompiles: new
    /// ones turned off in Yab, ones it dropped turned on again.
    private static var reading: Set<String> = []
    private static func readTheirPauses(_ id: String) {
        guard reading.insert(id).inserted else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            Task {
                defer { reading.remove(id) }
                let script = """
                const d = chrome.declarativeNetRequest;
                const all = [...(await d.getDynamicRules()), ...(await d.getSessionRules())];
                return JSON.stringify(all.filter(r => !(r.id >= \(firstRule) && r.id < \(firstRule + rules))));
                """
                guard let text = await run(script, in: id) as? String,
                      let data = text.data(using: .utf8),
                      let rules = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
                else { return }
                theirs(Set(rules.flatMap(allowedHosts)), from: id)
            }
        }
    }

    /// The sites an allowAllRequests rule (or an allow for whole pages)
    /// lets through: its requestDomains, or the host of a "||host^" filter.
    nonisolated static func allowedHosts(_ rule: [String: Any]) -> [String] {
        guard let action = rule["action"] as? [String: Any], let type = action["type"] as? String,
              type == "allowAllRequests" else { return [] }
        let condition = rule["condition"] as? [String: Any] ?? [:]
        if let domains = condition["requestDomains"] as? [String], !domains.isEmpty { return domains.map { $0.lowercased() } }
        if let domains = condition["initiatorDomains"] as? [String], !domains.isEmpty { return domains.map { $0.lowercased() } }
        if let filter = condition["urlFilter"] as? String, filter.hasPrefix("||") {
            let host = filter.dropFirst(2).prefix { $0 != "^" && $0 != "/" && $0 != "*" && $0 != "|" }
            if !host.isEmpty { return [String(host).lowercased()] }
        }
        return []
    }

    static func theirs(_ hosts: Set<String>, from id: String) {
        let key = "shield.theirs.\(id)"
        // The first read is what it ships with, not what a person did:
        // AdBlock allows all requests on hundreds of sites of its own.
        // Only changes after it are someone's pause or resume.
        guard let known = Store.settings.stringArray(forKey: key) else {
            Store.settings.set(hosts.sorted(), forKey: key)
            return
        }
        let before = Set(known)
        Store.settings.set(hosts.sorted(), forKey: key)
        let shield = Shield.shared
        let gone = before.subtracting(hosts), new = hosts.subtracting(before)
        // A person pauses one site at a time; rules arriving by the dozen
        // are the extension's own list (AdBlock adds hundreds in batches
        // for minutes after it starts).
        let markedKey = "shield.marked.\(id)"
        var marked = Set(Store.settings.stringArray(forKey: markedKey) ?? [])
        if new.count <= 3 {
            for host in new where !shield.isPaused(on: host) {
                shield.pause(host, true)
                marked.insert(host)
            }
        }
        for host in gone where marked.contains(host) {
            if shield.isPaused(on: host) { shield.pause(host, false) }
            marked.remove(host)
        }
        Store.settings.set(marked.sorted(), forKey: markedKey)
        if !gone.isEmpty || !new.isEmpty { shield.apply() }
    }

    // MARK: - a page of the extension's own

    /// A hidden page of each blocker's own, where chrome.declarativeNetRequest
    /// is its own, to change and read its rules. Let go a minute after.
    private static var helpers: [String: WKWebView] = [:]
    /// How the last call to each went, for the bench.
    private static var lastRun: [String: String] = [:]
    private static var lettingGo: [String: DispatchWorkItem] = [:]
    nonisolated static let helperFile = "yab-blocker.html"

    static func run(_ script: String, in id: String) async -> Any? {
        guard let context = extensions.contexts[id], let configuration = context.webViewConfiguration else { return nil }
        let page: WKWebView
        if let kept = helpers[id] {
            page = kept
        } else {
            let file = Extensions.folder(for: id).appendingPathComponent(helperFile)
            if !FileManager.default.fileExists(atPath: file.path) {
                try? Data("<!doctype html><meta charset=utf-8><title>Yab</title>".utf8).write(to: file)
            }
            guard let url = URL(string: helperFile, relativeTo: context.baseURL)?.absoluteURL else { return nil }
            page = WKWebView(frame: NSRect(x: 0, y: 0, width: 10, height: 10), configuration: configuration)
            page.load(URLRequest(url: url))
            helpers[id] = page
            for _ in 0..<500 {
                if !page.isLoading, (try? await page.evaluateJavaScript("typeof chrome === 'object' && !!chrome.declarativeNetRequest")) as? Bool == true { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        lettingGo[id]?.cancel()
        let later = DispatchWorkItem { helpers[id] = nil }
        lettingGo[id] = later
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: later)
        do {
            let value = try await page.callAsyncJavaScript(script, contentWorld: .page)
            lastRun[id] = "ok: " + String(String(describing: value ?? "nil").prefix(200))
            return value
        } catch {
            lastRun[id] = "error: " + String(describing: error)
            NSLog("yab: blocker %@ rules: %@", id, String(describing: error))
            return nil
        }
    }
}

// MARK: - the card

/// The card's two tiles: what blocks now on the left, the one just added
/// on the right, selected. Return takes the selected one, the arrows move
/// it, a press on a tile takes that one and closes the card.
@MainActor
@Observable final class BlockerChoice {
    let latest: String
    let current: String?
    /// The right tile, the new one, unless the arrows moved it.
    var newSelected = true
    /// The answer, once given by a tile or a key.
    @ObservationIgnored var kept = false

    init(latest: String, current: String?) {
        self.latest = latest
        self.current = current
    }

    /// Left and right move the selection; Return keeps the left one when
    /// it is selected.
    func key(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return false }
        switch event.keyCode {
        case 123: newSelected = false; return true
        case 124: newSelected = true; return true
        case 36, 76:
            guard !newSelected else { return false }
            take(new: false)
            return true
        default: return false
        }
    }

    func take(new: Bool) {
        kept = !new
        Questions.shared.answer(new)
    }
}

/// Two tiles under the words, and the one line under them.
@available(macOS 15.4, *)
struct BlockerOptions: View {
    var choice: BlockerChoice
    private var extensions = Extensions.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                if let current = choice.current {
                    BlockerTile(icon: extensions.icon(for: current, side: 28), title: Blockers.name(current),
                                line: Self.theirs(current), selected: !choice.newSelected) { choice.take(new: false) }
                } else {
                    BlockerTile(icon: nil, title: "Built-in", line: "Off on a site at once. Settings in Yab.",
                                selected: !choice.newSelected) { choice.take(new: false) }
                }
                BlockerTile(icon: extensions.icon(for: choice.latest, side: 28), title: Blockers.name(choice.latest),
                            line: Self.theirs(choice.latest), selected: choice.newSelected) { choice.take(new: true) }
            }
            // As tall as the taller of the two, no taller.
            .fixedSize(horizontal: false, vertical: true)
            Text(footer)
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 10)
    }

    private var footer: String {
        if let brought = Blockers.broughtWith[choice.latest], brought.sites + brought.hiding > 0 {
            return "Its \(BlockerWords.brought(brought.sites, brought.hiding)) come over either way. YouTube's ads stay with Yab."
        }
        return "YouTube's ads stay with Yab either way."
    }

    /// "Off on a site in about 15 s. Its own settings."
    static func theirs(_ id: String) -> String {
        "Off on a site in \(delay(id)). Its own settings."
    }

    /// "about 15 s" from its last compile, "a few seconds" before one.
    static func delay(_ id: String) -> String {
        guard let seconds = Shield.shared.compileSeconds(id) else { return "a few seconds" }
        return "about \(max(1, Int(seconds.rounded()))) s"
    }
}

/// A choice: its picture, its name, what differs. Selected, a ring inside
/// its edge; hovered, the same ring fainter, so nothing moves.
private struct BlockerTile: View {
    let icon: NSImage?
    let title: String
    let line: String
    let selected: Bool
    let act: () -> Void
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.surface, style: .continuous)
        Button(action: act) {
            VStack(alignment: .leading, spacing: 6) {
                Group {
                    if let icon {
                        Image(nsImage: icon).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    } else {
                        Symbol("checkmark.shield", size: 20).foregroundStyle(Palette.ink)
                    }
                }
                .frame(width: 28, height: 28)
                Text(title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Palette.ink).lineLimit(1)
                Text(line).font(.system(size: 12)).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(12)
            .background(shape.fill(selected ? Palette.ink.opacity(0.05) : .clear))
            .overlay(shape.strokeBorder(Palette.ink.opacity(0.08), lineWidth: 1).opacity(selected ? 0 : 1))
            .overlay(shape.strokeBorder(Palette.ink, lineWidth: 1.5).opacity(selected ? 1 : hovering ? 0.35 : 0))
            .contentShape(shape)
        }
        .buttonStyle(.plain) // design: a tile is a choice in the card, drawn whole here
        .focusable(false)
        .onHover { hovering = $0 }
    }
}

enum BlockerWords {
    /// "12 trusted sites and 8 hiding rules", the parts there are.
    static func brought(_ sites: Int, _ hiding: Int) -> String {
        var parts: [String] = []
        if sites > 0 { parts.append(sites == 1 ? "1 trusted site" : "\(sites) trusted sites") }
        if hiding > 0 { parts.append(hiding == 1 ? "1 hiding rule" : "\(hiding) hiding rules") }
        return parts.joined(separator: " and ")
    }
}
