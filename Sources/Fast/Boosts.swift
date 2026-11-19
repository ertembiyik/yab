import AppKit
import WebKit

@MainActor
@Observable final class Boosts {
    static let shared = Boosts()
    struct Trial: Identifiable {
        let id: UUID
        let tabID: UUID
        let session: String
        let url: URL
        let package: BoostPackage
        let author: String
        let baseRevision: String?
        var report: [String: Any] = [:]
        var ready = false
        var problem: String?
        var at = Date()
        /// Brought to the person's tab by a quiet trial that passed: the
        /// card says where it was checked, if anywhere it can name.
        var fitted = false
        var checked: String?
        var signIn: UUID?
    }
    /// A passing quiet trial's page, before and after, for its chat.
    struct Pictures {
        let before: NSImage
        let after: NSImage
        let host: String
        let tries: Int
        /// The two as files, for Quick Look to open as a chat's pictures.
        var files: [URL] = []
    }
    private(set) var records: [BoostRecord] = []
    /// Whether the library's index was read: false when it is there and
    /// couldn't be (a later Yab's rung, a broken file), and `records` is
    /// empty for that, not for being empty (sync takes nothing away for it).
    @ObservationIgnored private(set) var loaded = false
    private(set) var trials: [UUID: Trial] = [:]
    private(set) var trouble: String?
    /// By chat (the task's root session): the last quiet trial that passed.
    private(set) var pictures: [String: Pictures] = [:]
    let library: BoostLibrary
    @ObservationIgnored private(set) var packages: [String: BoostPackage] = [:]
    @ObservationIgnored private var attempts: [String: Int] = [:]
    @ObservationIgnored private var busy: Set<UUID> = []
    @ObservationIgnored private var checked: Set<String> = []
    @ObservationIgnored private var repairing: [String: BoostRecord] = [:]
    /// Quiet trials' pages, by session, and the sessions with a try under way.
    @ObservationIgnored private var rooms: [String: Tab] = [:]
    @ObservationIgnored private var fitting: Set<String> = []
    let safeMode: Bool

    /// ⌥ held while Yab opened (docs/boosts.md, "Off for a start"), read
    /// as it launches: not when boosts are first needed, which may be any
    /// time later, an ⌥-click or ⌥⌘ then turning every boost off till quit.
    static var optionAtLaunch: Bool?

    init(root: URL = Store.file("boosts"), safeMode: Bool? = nil) {
        library = BoostLibrary(root: root)
        self.safeMode = safeMode ?? Boosts.optionAtLaunch ?? NSEvent.modifierFlags.contains(.option)
        reload()
        Task { BoostServices.shared.reconcile(); BoostContributions.reconcile() }
    }

    /// The index again, and one plugin's files: what a plugin from another
    /// Mac changes, without reading every other plugin again.
    private func reload(_ id: String) {
        do {
            records = try library.records()
            try migrateProfiles()
            loaded = true
            if let record = records.first(where: { $0.id == id }) {
                packages[id] = try BoostPackage.read(id: id, files: library.files(id), sites: record.sites)
            } else {
                packages[id] = nil
            }
        } catch { trouble = error.localizedDescription }
    }

    private func reload() {
        trouble = nil
        do {
            records = try library.records()
            try migrateProfiles()
            loaded = true
            var read: [String: BoostPackage] = [:]
            for record in records {
                do { read[record.id] = try BoostPackage.read(id: record.id, files: library.files(record.id), sites: record.sites) }
                catch { trouble = "\(record.name): \(error.localizedDescription)" }
            }
            packages = read
        } catch { trouble = error.localizedDescription }
    }

    private func migrateProfiles() throws {
        guard records.contains(where: { $0.profiles == nil }) else { return }
        var changed = records
        for at in changed.indices where changed[at].profiles == nil {
            let profiles = AddonProfiles(legacy: changed[at].enabled, signIns: AddonProfiles.existing)
            let state = BoostStorage.get(changed[at].id)
            for key in profiles.enabled.keys where key != AddonProfiles.key(nil) {
                if let signIn = UUID(uuidString: key), BoostStorage.get(changed[at].id, in: signIn).isEmpty {
                    try BoostStorage.set(changed[at].id, state, in: signIn)
                }
            }
            changed[at].profiles = profiles
        }
        try library.save(changed)
        records = changed
    }

    /// Copies for the list, with each switch saying what this profile runs.
    func records(in signIn: UUID?) -> [BoostRecord] {
        records.compactMap { record in
            guard record.profiles?.contains(signIn) ?? true else { return nil }
            var local = record
            local.enabled = record.enabled && (record.profiles?.isEnabled(in: signIn) ?? true)
            return local
        }
    }
    func isEnabled(_ id: String, in signIn: UUID?) -> Bool {
        !safeMode && records(in: signIn).contains { $0.id == id && $0.enabled }
    }

    func isEnabled(_ id: String) -> Bool { !safeMode && records.contains { $0.id == id && $0.enabled } }

    func mayCreate(session: String?) -> Bool {
        guard !safeMode, let owner = Agents.shared.session(session), owner.state.live,
              !owner.textOnly, owner.profile != "context_explorer", owner.boostOrigin == nil,
              Agents.shared.session(Agents.shared.root(of: session))?.boostOrigin == nil,
              Routines.shared.running(session) == nil else { return false }
        return true
    }

    // Retain the world independently of WKUserScript. Removing the last script
    // must not lose the handle to the runtime whose styles still need Undo.
    private static var worlds: [String: WKContentWorld] = [:]
    static func world(_ id: String) -> WKContentWorld {
        if let world = worlds[id] { return world }
        let world = WKContentWorld.world(name: "yab-boost-" + id)
        worlds[id] = world; return world
    }
    /// The same world through a tab's page, on either engine.
    nonisolated static func pageWorld(_ id: String) -> PageWorld { .named("yab-boost-" + id) }

    /// A tab told again what its boosts are, on either engine.
    func arm(_ tab: Tab) {
        if let chromium = tab.builtPage as? ChromiumPage { chromium.refreshFeatureScripts() }
        else if let web = tab.webKitOnly("WebKit boost runtime", build: false) { attach(to: web.configuration.userContentController, tab: tab) }
    }

    /// A Chromium tab's boosts, for every document: a link's navigation asks
    /// nobody first, so each script keeps to its sites itself (BoostScript).
    func chromiumScripts(for tab: Tab) -> (scripts: [PageScriptRegistration], relays: [String]) {
        guard !safeMode, !tab.shy, !tab.isDev else { return ([], []) }
        let trial = trials[tab.id]
        let local = records(in: AddonProfiles.of(tab))
        var scripts: [PageScriptRegistration] = []
        func add(_ package: BoostPackage) {
            let made = script(for: package)
            scripts.append(PageScriptRegistration(source: made.source, world: Self.pageWorld(package.id),
                                                  atEnd: made.injectionTime == .atDocumentEnd, mainOnly: made.isForMainFrameOnly))
        }
        for record in local where record.enabled && record.id != trial?.package.id {
            if let package = packages[record.id] { add(package) }
        }
        if let trial { add(trial.package) }
        let relays = local.filter(\.enabled).compactMap { packages[$0.id] }.filter { !$0.plugin.permissions.isEmpty }.map(\.id)
        return (scripts, relays)
    }
    private var tabs: [Tab] {
        var seen: Set<UUID> = []
        return (BrowserWindows.shared.browsers + [Agents.shared.browser].compactMap { $0 })
            .flatMap { $0.tabs + $0.parkedTabs }.filter { seen.insert($0.id).inserted }
    }
    func on(_ url: URL?, in signIn: UUID? = nil) -> [BoostRecord] {
        guard let url else { return [] }
        return records(in: signIn).filter { packages[$0.id]?.matches(url) ?? $0.sites.contains(where: { $0 == "<all_urls>" || $0 == url.host }) }
    }
    func files(_ id: String, session: String?) throws -> [String: String] {
        if let trial = trials.values.filter({ $0.package.id == id && $0.session == session }).max(by: { $0.at < $1.at }) { return trial.package.files }
        return try library.files(id)
    }

    /// Called every time a tab is armed, including waking tabs, and when
    /// boosts change. A tab that already has these boosts is sent nothing.
    func attach(to controller: WKUserContentController, tab: Tab) {
        let span = MainBudget.begin("pagescripts.boosts"); defer { span?.end() }
        var wanted: [WKUserScript] = []
        var approved: [BoostPackage] = []
        if !safeMode, !tab.shy, !tab.isDev {
            let trial = trials[tab.id]
            let local = records(in: AddonProfiles.of(tab))
            approved = local.filter(\.enabled).compactMap { packages[$0.id] }
            for record in local where record.enabled && record.id != trial?.package.id {
                guard let package = packages[record.id] else { continue }
                wanted.append(script(for: package))
            }
            if let trial { wanted.append(script(for: trial.package)) }
        }
        BoostAPI.shared.attach(controller, packages: approved)
        let scripts = controller.userScripts.map { $0 }
        // Told apart by which objects they are, not by reading every
        // script's source on every navigation: every boost script is made
        // here (script(for:)).
        let have = scripts.filter { everMade.contains(ObjectIdentifier($0)) }
        guard have.map(ObjectIdentifier.init) != wanted.map(ObjectIdentifier.init) else { return }
        if !have.isEmpty {
            let others = scripts.filter { !everMade.contains(ObjectIdentifier($0)) }
            controller.removeAllUserScripts()
            // WebKit keeps extensions' scripts through that: added again,
            // they would run twice (PageAppearance.install).
            let kept = Set(controller.userScripts.map(ObjectIdentifier.init))
            for script in others where !kept.contains(ObjectIdentifier(script)) { controller.addUserScript(script) }
        }
        wanted.forEach(controller.addUserScript)
    }

    /// One object for each boost's script as it stands, so a tab armed again
    /// with the same boosts compares equal and is sent nothing.
    /// The package each was made from: the same package is the same
    /// script, without writing its source out again on every navigation.
    @ObservationIgnored private var madeScripts: [String: (package: BoostPackage, script: WKUserScript)] = [:]
    /// Every boost script made this run, kept so no other object takes its
    /// identifier; old ones are still taken out of a tab armed again.
    @ObservationIgnored private var everMade: Set<ObjectIdentifier> = []
    @ObservationIgnored private var everMadeScripts: [WKUserScript] = []
    private func script(for package: BoostPackage) -> WKUserScript {
        if let made = madeScripts[package.id], made.package == package { return made.script }
        let source = BoostScript.source(package)
        if let made = madeScripts[package.id], made.script.source == source {
            madeScripts[package.id] = (package, made.script)
            return made.script
        }
        let script = WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Self.world(package.id))
        madeScripts[package.id] = (package, script)
        everMade.insert(ObjectIdentifier(script))
        everMadeScripts.append(script)
        return script
    }

    func stage(name: String, changes: [String: Any], sites: [String], tab: Tab, session: String) async throws -> [String: Any] {
        guard !safeMode else { throw BoostPackage.Invalid("Boosts are off for this launch because Option was held at startup.") }
        guard !busy.contains(tab.id) else { throw BoostPackage.Invalid("A boost is already being checked in this tab. Wait for its result.") }
        guard !tab.shy, !tab.isDev, tab.bench, tab.agent == session || (Store.testing && session == Agents.script),
              let owner = Agents.shared.session(session), owner.state.live || owner.script,
              Routines.shared.running(session) == nil, owner.boostOrigin == nil,
              Agents.shared.session(Agents.shared.root(of: session))?.boostOrigin == nil,
              !owner.textOnly, owner.profile != "context_explorer" else {
            throw BoostPackage.Invalid("Create a boost in a task-owned tab outside Developer Mode. Routines cannot create boosts.")
        }
        guard let url = tab.address, let host = url.host, sites == [host], ["http", "https"].contains(url.scheme ?? "") else {
            throw BoostPackage.Invalid("A trial may change only its tab's exact site. Use that host in sites and the manifest.")
        }
        guard !name.isEmpty, name == BoostPackage.slug(name), name.count <= 64 else { throw BoostPackage.Invalid("Use a short lowercase boost name.") }
        let web = tab.page
        let sensitivity = try await BoostJavaScript.evaluate(BoostScript.sensitive, on: web, world: Self.pageWorld(name))
        guard sensitivity as? Bool == false else {
            throw BoostPackage.Invalid("Boosts are unavailable on sign-in, payment and password pages (page check: \(String(describing: sensitivity))).")
        }
        let key = session + ":" + name
        guard attempts[key, default: 0] < 5 else { throw BoostPackage.Invalid("Five tries did not finish this boost. Explain what still fails and let the user choose what to do next.") }
        if let other = trials[tab.id], other.package.id != name || other.session != session {
            throw BoostPackage.Invalid("This tab has another pending boost. Keep or undo it first.")
        }
        var merged = try BoostPackage.merge(changes, into: (try? files(name, session: session)) ?? [:])
        // The repair brief is the user's original request, not text supplied by a site.
        let intent = repairing[session]?.intent ?? BoostWords.request(owner.asked.last ?? owner.prompt)
        if !intent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let text = merged["BOOST.md"],
           let end = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: min(4, text.count))..<text.endIndex) {
            merged["BOOST.md"] = String(text[..<end.upperBound]) + "\n\n" + intent
        }
        let savedScope = records.first(where: { $0.id == name })?.sites
        let scope = savedScope == ["<all_urls>"] ? savedScope! : sites
        if let savedScope, savedScope != scope { throw BoostPackage.Invalid("An agent cannot change a saved boost’s sites. Start a separate trial for this site.") }
        let package = try BoostPackage.read(id: name, files: merged, sites: scope)
        if let repair = repairing[session] {
            guard name == repair.id, package.rung == .look, package.sites == repair.sites,
                  records.first(where: { $0.id == name })?.revision == repair.revision else {
                throw BoostPackage.Invalid("An automatic repair may only replace the same saved stylesheet on the same sites.")
            }
        }
        busy.insert(tab.id); defer { busy.remove(tab.id) }
        attempts[key, default: 0] += 1
        let began = Date()
        let before = await picture(web)
        guard tab.builtPage === web, tab.address == url else { throw BoostPackage.Invalid("The page changed while the boost was being prepared. Try on the new page.") }
        var trial = Trial(id: UUID(), tabID: tab.id, session: session, url: url, package: package, author: owner.cli,
                          baseRevision: records.first { $0.id == name }?.revision)
        trial.signIn = AddonProfiles.of(tab)
        let folder = library.root.appendingPathComponent(".trial/" + trial.id.uuidString)
        try library.write(package.files, to: folder)
        if let old = trials[tab.id] { try? FileManager.default.removeItem(at: library.root.appendingPathComponent(".trial/" + old.id.uuidString)) }
        trials[tab.id] = trial
        arm(tab)
        do {
            let initial = try await BoostJavaScript.evaluate(BoostScript.source(package), on: web, world: Self.pageWorld(name))
            if let message = (initial as? [String: Any])?["error"] as? String { throw BoostPackage.Invalid(message) }
            try await Task.sleep(for: .milliseconds(120))
            guard tab.address == url, trials[tab.id]?.id == trial.id else { throw BoostPackage.Invalid("The page changed. Recheck the boost before keeping it.") }
            var report = (try await BoostJavaScript.evaluate(BoostScript.report, on: web, world: Self.pageWorld(name))) as? [String: Any] ?? [:]
            report["rung"] = package.rung.rawValue; report["permission"] = package.permission
            report["name"] = name; report["trial"] = trial.id.uuidString
            report["before"] = before; report["after"] = await picture(web)
            guard trials[tab.id]?.id == trial.id, tab.address == url else { throw BoostPackage.Invalid("The page changed during the check.") }
            trials[tab.id]?.report = report
            trials[tab.id]?.ready = report["loaded"] as? Bool == true && (report["errors"] as? [String] ?? []).isEmpty
                && !(report["checks"] as? [[String: Any]] ?? []).contains { $0["state"] as? String == "fail" }
            // Checks that all belong to other pages prove nothing here.
            if let checks = report["checks"] as? [[String: Any]], !checks.isEmpty,
               checks.allSatisfy({ $0["state"] as? String == "skipped" }) {
                trials[tab.id]?.ready = false
                trials[tab.id]?.problem = "None of this boost\u{2019}s checks are for this page. Try it on a page they cover."
            }
            // An agent's stylesheet that hits nothing is its commonest bug;
            // a Store boost or a file the person chose may hide what this
            // page doesn't have today (an ad the blocker took), and its
            // checks say whether it works: Keep stays theirs (#447).
            if package.rung == .look, !package.css.isEmpty, session != Agents.script,
               let matched = report["matched"] as? [String: Int], !matched.values.contains(where: { $0 > 0 }) {
                trials[tab.id]?.ready = false
                trials[tab.id]?.problem = "No elements matched this stylesheet. Try the page the boost is for."
            }
            if repairing[session] != nil,
               let checks = report["checks"] as? [[String: Any]], !checks.isEmpty,
               checks.contains(where: { $0["state"] as? String == "pass" }),
               !checks.contains(where: { $0["state"] as? String == "fail" }),
               trials[tab.id]?.ready == true {
                await keep(trial.id, on: tab)
                if trials[tab.id] == nil { repairing.removeValue(forKey: session); report["repaired"] = true }
            }
            BoostMetrics.note("trial", name, seconds: Date().timeIntervalSince(began), attempts: attempts[key])
            return report
        } catch {
            trials[tab.id]?.problem = error.localizedDescription
            throw error
        }
    }

    private func picture(_ web: any PageHandle) async -> String {
        guard let image = try? await web.snapshot(PageShot(width: 900)), let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff), let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.65]) else { return "" }
        return data.base64EncodedString()
    }

    // MARK: - the quiet trial

    func isRepairing(_ session: String?) -> Bool { session.map { repairing[$0] != nil } ?? false }
    /// The tab shows the Keep card of a boost this task (or one of its
    /// subagents) made: the card answers, so no word in the corner too.
    func carded(_ tab: Tab, by session: String) -> Bool {
        guard let trial = trials[tab.id] else { return false }
        return trial.session == session || Agents.shared.root(of: trial.session) == session
    }
    /// A quiet try's own page, which nobody sees.
    func isRoom(_ tab: Tab) -> Bool { rooms.values.contains { $0 === tab } }

    /// The same page as one a try was checked on, but for its #fragment.
    nonisolated static func same(_ url: URL, as places: [URL]) -> Bool {
        func bare(_ url: URL) -> String {
            var parts = URLComponents(url: url, resolvingAgainstBaseURL: false); parts?.fragment = nil
            return parts?.string ?? url.absoluteString
        }
        return places.map(bare).contains(bare(url))
    }

    /// An agent's try, in a page of Yab's own the person never sees
    /// (docs/boosts.md, "Quiet trial"): the page loaded afresh, signed in
    /// as they are, out of the tab row and kept seen off screen so its
    /// checks and pictures run as they would in front of someone. A try
    /// that fails shows nothing; one that passes goes on in the person's
    /// own tab of the site, with the Keep card. `pages` are more of the
    /// site to check it on, two at most.
    func fit(name: String, changes: [String: Any], sites: [String], from source: Tab, session: String, pages: [String] = []) async throws -> [String: Any] {
        guard !safeMode else { throw BoostPackage.Invalid("Boosts are off for this launch because Option was held at startup.") }
        guard fitting.insert(session).inserted else { throw BoostPackage.Invalid("A try of this task's is still being checked. Wait for its result.") }
        defer { fitting.remove(session) }
        let root = Agents.shared.root(of: session) ?? session
        guard !source.shy, !source.isDev,
              source.agent == session || source.id == Agents.shared.session(root)?.nativeOriginTab || (Store.testing && session == Agents.script),
              let url = source.address, let host = url.host, ["http", "https"].contains(url.scheme ?? "") else {
            throw BoostPackage.Invalid("Try a boost from a tab of this task's, or the person's tab the chat is about, outside private tabs and Developer Mode.")
        }
        var urls = [url]
        for page in pages {
            guard let other = URL(string: page), other.host == host, ["http", "https"].contains(other.scheme ?? "") else {
                throw BoostPackage.Invalid("Check pages of \(host) only, the boost's own site.")
            }
            if !urls.contains(other) { urls.append(other) }
        }
        urls = Array(urls.prefix(3))
        let key = session + ":" + name
        let earlier = rooms[session]
        let room = Tab(bench: true, configuration: Self.room(source.pageStore), factory: .webKitOnly)
        guard let roomWeb = room.webKitOnly("Boost preview") else { room.close(); throw BoostPackage.Invalid("The preview page is unavailable.") }
        room.agent = session
        Bench.shared.house(room)
        room.go(to: urls[0])
        var report: [String: Any]
        do {
            try await settle(room, on: urls[0])
            report = try await stage(name: name, changes: changes, sites: sites, tab: room, session: session)
        } catch {
            // The last try's files stay for the next to build on.
            if trials[room.id] != nil { if let earlier { shut(earlier) }; rooms[session] = room } else { shut(room) }
            if attempts[key, default: 0] >= 5, let last = rooms.removeValue(forKey: session) { shut(last) }
            throw error
        }
        if let earlier { shut(earlier) }
        rooms[session] = room
        var passed = trials[room.id].map { $0.ready && $0.problem == nil } ?? false
        var places = [urls[0]]
        var more: [[String: Any]] = []
        if passed {
            for page in urls.dropFirst() {
                room.go(to: page)
                try await settle(room, on: page)
                var said: [String: Any] = ["url": page.absoluteString]
                let sensitive = try? await BoostJavaScript.evaluate(BoostScript.sensitive, on: roomWeb, world: Self.world(name))
                if room.address?.host != host || sensitive as? Bool != false {
                    said["error"] = "Not checked: the page went to another site, or to a sign-in or payment page."
                } else {
                    let got = (try? await BoostJavaScript.evaluate(BoostScript.report, on: roomWeb, world: Self.world(name))) as? [String: Any] ?? [:]
                    for field in ["loaded", "checks", "errors", "matched"] { said[field] = got[field] }
                    if got["loaded"] as? Bool == true, (got["errors"] as? [String] ?? []).isEmpty,
                       !(got["checks"] as? [[String: Any]] ?? []).contains(where: { $0["state"] as? String == "fail" }) { places.append(page) }
                    else { said["failed"] = true }
                }
                more.append(said)
                if said["failed"] != nil || said["error"] != nil { passed = false }
            }
        }
        let tries = attempts[key, default: 0]
        report["tries"] = tries
        if !more.isEmpty { report["pages"] = more }
        guard passed, let fitted = trials[room.id] else {
            report["shown"] = false
            if tries >= 5 {
                if let last = rooms.removeValue(forKey: session) { shut(last) }
                report["note"] = "That was the fifth try. Nothing was shown to the person. Explain in chat what still fails and let them choose what to do next."
            } else {
                report["note"] = "Nothing was shown to the person: they see a boost only once every check passes. Fix what fails and call boost again (\(5 - tries) tries left)."
            }
            return report
        }
        let target = try await present(fitted, on: places, root: root)
        if let done = rooms.removeValue(forKey: session) { shut(done) }
        if let beforeData = (report["before"] as? String).flatMap({ Data(base64Encoded: $0) }),
           let afterData = (report["after"] as? String).flatMap({ Data(base64Encoded: $0) }),
           let before = NSImage(data: beforeData), let after = NSImage(data: afterData) {
            pictures[root] = Pictures(before: before, after: after, host: host, tries: tries,
                                      files: Self.pictureFiles(beforeData, afterData, host: host, chat: root))
        }
        report["shown"] = true
        report["tab"] = Bench.short(target)
        report["note"] = "Every check passed. The boost is on now in the person's own tab of \(host), with the Keep card: Keep and Undo are theirs alone. Answer in one or two sentences, what changed; don't repeat what the card says."
        return report
    }

    /// Before and after written out under the chat's own folder in the
    /// temporary directory, named for the site, each new pair over the last.
    private static func pictureFiles(_ before: Data, _ after: Data, host: String, chat: String) -> [URL] {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("yab-boost-pictures/" + chat.replacingOccurrences(of: "/", with: "-"), isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = host.isEmpty ? "page" : host
        let files = [folder.appendingPathComponent(name + " before.png"), folder.appendingPathComponent(name + " after.png")]
        guard (try? before.write(to: files[0])) != nil, (try? after.write(to: files[1])) != nil else { return [] }
        return files
    }

    /// The person's tab a passing try goes on in: the one the chat is
    /// about, else one in front, else the page opened for them. Only a tab
    /// on a page the try was checked on: Keep saves what was checked there,
    /// so a tab on another page of the site gets the checked one beside it.
    private func present(_ fitted: Trial, on places: [URL], root: String) async throws -> Tab {
        let theirs = tabs.filter { tab in
            AddonProfiles.of(tab) == fitted.signIn && !tab.bench && !tab.shy && !tab.isDev && !tab.asleep && tab.address.map { Self.same($0, as: places) } == true
        }
        let origin = Agents.shared.session(root)?.nativeOriginTab
        let fronts = (BrowserWindows.shared.browsers + [Agents.shared.browser].compactMap { $0 }).compactMap(\.active)
        var target = theirs.first { $0.id == origin } ?? theirs.first { tab in fronts.contains { $0 === tab } }
        if target == nil, let browser = ([Agents.shared.browser].compactMap { $0 } + BrowserWindows.shared.browsers).first(where: { AddonProfiles.of($0) == fitted.signIn }) {
            target = browser.open(fitted.url, foreground: true)
        }
        guard let target else { throw BoostPackage.Invalid("There is no window to show the boost in.") }
        let web = target.page
        let checked = Self.checked(places)
        if let other = trials[target.id], other.package.id != fitted.package.id || other.session != fitted.session {
            throw BoostPackage.Invalid("The person's tab has another boost on trial. Ask them to keep or undo it first; nothing else changed.")
        }
        var trial = Trial(id: UUID(), tabID: target.id, session: fitted.session, url: target.address ?? fitted.url, package: fitted.package,
                          author: fitted.author, baseRevision: fitted.baseRevision)
        trial.signIn = fitted.signIn
        trial.report = fitted.report; trial.ready = true; trial.fitted = true; trial.checked = checked
        try library.write(trial.package.files, to: library.root.appendingPathComponent(".trial/" + trial.id.uuidString))
        let world = Self.pageWorld(trial.package.id)
        if let old = trials[target.id] {
            try? FileManager.default.removeItem(at: library.root.appendingPathComponent(".trial/" + old.id.uuidString))
            _ = try? await BoostJavaScript.evaluate(BoostScript.remove, on: web, world: world)
        }
        trials[target.id] = trial
        arm(target)
        if !web.isLoading { _ = try? await BoostJavaScript.evaluate(BoostScript.source(trial.package), on: web, world: world) }
        BoostMetrics.note("shown", trial.package.id, attempts: attempts[fitted.session + ":" + trial.package.id])
        return target
    }

    /// A quiet trial's page: the person's sign-ins, never suspended for
    /// being out of sight, so timers and frames run for its checks. No
    /// extensions: it is no tab of any window's, and their scripts in it
    /// would ask WebKit for their tab, never suspended, for as long as the
    /// room lasts.
    private static func room(_ store: WKWebsiteDataStore) -> WKWebViewConfiguration {
        let configuration = Web.configuration(store: store, extensions: false)
        configuration.preferences.inactiveSchedulingPolicy = .none
        return configuration
    }

    /// Loaded, or the time is up, and a beat for the page's own scripts.
    private func settle(_ room: Tab, on url: URL) async throws {
        for _ in 0..<150 {
            try await Task.sleep(for: .milliseconds(100))
            if room.address?.host == url.host, !room.page.isLoading { break }
        }
        try await Task.sleep(for: .milliseconds(600))
    }

    private func shut(_ room: Tab) {
        closed(room)
        Bench.shared.rest(room)
        room.webKitOnly("WebKit boost runtime", build: false)?.removeFromSuperview()
        room.close()
    }

    /// Where a passing try was checked, as the card says it: "Checked on
    /// Home, search and a video." Nil for one page it can't name.
    nonisolated static func checked(_ pages: [URL]) -> String? {
        var names: [String] = []
        var others = 0
        for url in pages {
            let path = url.path.lowercased()
            let asked = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                .contains { ["q", "query", "search_query", "k", "s"].contains($0.name) }
            let name = path.contains("search") || path.contains("results") || asked ? "search"
                : path.contains("watch") || path.contains("video") ? "a video"
                : path.isEmpty || path == "/" ? "Home" : nil
            if let name { if !names.contains(name) { names.append(name) } } else { others += 1 }
        }
        if others > 0 {
            if names.isEmpty, others == 1 { return nil }
            names.append(names.isEmpty ? "\(others) pages" : others == 1 ? "one more page" : "\(others) more pages")
        }
        return names.isEmpty ? nil : "Checked on " + BoostPackage.list(names) + "."
    }

    /// Only native user controls call these methods. There is no Keep MCP verb.
    func keep(_ trialID: UUID, on tab: Tab, everywhere: Bool = false) async {
        guard let trial = trials[tab.id], trial.id == trialID, trial.ready else { return }
        // Moved since the trial (a single-page app's own navigation): say
        // so on the card instead of a Keep that does nothing.
        guard tab.address == trial.url else { moved(tab); return }
        guard records.first(where: { $0.id == trial.package.id })?.revision == trial.baseRevision else {
            trials[tab.id]?.problem = "This boost changed in another tab. Make a new trial from the saved version."
            return
        }
        if repairing[trial.session] != nil, !isEnabled(trial.package.id) { return }
        do {
            let package = everywhere && !trial.package.allSites ? try trial.package.applyingEverywhere() : trial.package
            if package.allSites {
                guard await Questions.shared.ask(Question(title: "Apply to every site?", detail: package.permission, lines: [package.name], yes: "Keep for Every Site", no: "Cancel", place: .plain)) else { return }
                guard trials[tab.id]?.id == trialID, tab.address == trial.url,
                      records.first(where: { $0.id == package.id })?.revision == trial.baseRevision else { throw BoostPackage.Invalid("The trial changed while permission was being asked.") }
            }
            var profiles = records.first { $0.id == package.id }?.profiles ?? AddonProfiles(signIn: AddonProfiles.of(tab), enabled: true)
            if let old = packages[package.id], package.widens(old) {
                profiles.enabled = profiles.enabled.mapValues { _ in false }
            }
            profiles.setEnabled(true, in: AddonProfiles.of(tab))
            let record = try library.keep(package, author: trial.author, session: trial.session, profiles: profiles)
            StoreCatalog.shared.kept(package.id, digest: record.digest)
            BoostMetrics.note("keep", trial.package.id, attempts: attempts[trial.session + ":" + trial.package.id])
            trials.removeValue(forKey: tab.id)
            attempts.removeValue(forKey: trial.session + ":" + trial.package.id)
            try? FileManager.default.removeItem(at: library.root.appendingPathComponent(".trial/" + trial.id.uuidString))
            reload()
            await refresh(trial.package.id, except: tab.id)
            arm(tab)
        } catch { trials[tab.id]?.problem = error.localizedDescription }
    }

    func undo(on tab: Tab) async {
        guard let trial = trials[tab.id] else { return }
        let web = tab.page
        trials.removeValue(forKey: tab.id)
        BoostMetrics.note("undo", trial.package.id)
        try? FileManager.default.removeItem(at: library.root.appendingPathComponent(".trial/" + trial.id.uuidString))
        _ = try? await BoostJavaScript.evaluate(BoostScript.remove, on: web, world: Self.pageWorld(trial.package.id))
        arm(tab)
        // Arbitrary page code may have changed DOM state. Reload restores the
        // site's own document, and reinstates the saved version if there is one.
        if trial.package.rung != .look { tab.reloadForChange(.plugin) }
        // The kept one with code (a newer version from another Mac) waits
        // for the page's next load, as any code from elsewhere does.
        else if let old = packages[trial.package.id], old.rung != .look { tab.reloadForChange(.plugin) }
        else if let old = packages[trial.package.id], isEnabled(old.id, in: AddonProfiles.of(tab)) {
            _ = try? await BoostJavaScript.evaluate(BoostScript.source(old), on: web, world: Self.pageWorld(old.id))
        }
    }

    func setEnabled(_ id: String, _ enabled: Bool, in signIn: UUID? = nil) async {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        var changed = records
        var profiles = changed[index].profiles ?? AddonProfiles(legacy: changed[index].enabled, signIns: AddonProfiles.existing)
        profiles.setEnabled(enabled, in: signIn)
        changed[index].profiles = profiles
        changed[index].enabled = profiles.enabled.values.contains(true)
        // Turned on here: the yes code from another Mac waited for.
        if enabled { changed[index].waits = nil }
        BoostMetrics.note(enabled ? "enabled" : "disabled", id)
        do { try library.save(changed); records = changed; await refresh(id, profile: AddonProfiles.key(signIn)) }
        catch { trouble = error.localizedDescription }
    }
    func delete(_ id: String, in signIn: UUID? = nil) async {
        if let index = records.firstIndex(where: { $0.id == id }), var profiles = records[index].profiles {
            guard profiles.contains(signIn) else { return }
            profiles.remove(signIn)
            Store.settings.removeObject(forKey: BoostStorage.key(BoostStorage.scopedID(id, in: signIn)))
            if !profiles.enabled.isEmpty {
                var changed = records; changed[index].profiles = profiles
                changed[index].enabled = profiles.enabled.values.contains(true)
                do { try library.save(changed); records = changed; await refresh(id, profile: AddonProfiles.key(signIn)) }
                catch { trouble = error.localizedDescription }
                return
            }
        }
        let sites = records.first { $0.id == id }?.sites ?? []
        do { try library.delete(id); reload(); await refresh(id, reloadPages: true, sites: sites, profile: AddonProfiles.key(signIn)); BoostContributions.forget(id) }
        catch { trouble = error.localizedDescription }
    }
    func forget(signIn: UUID) {
        let ids = records(in: signIn).map(\.id)
        Task { for id in ids { await delete(id, in: signIn) } }
    }
    enum Update { case applied, held }
    /// A kept boost brought to the Store's newer version. One that may do no
    /// more than the kept version replaces it, the old one staying in
    /// history; one that asks for more turns the kept one off, its files as
    /// they were, until the person keeps the new one (docs/store.md).
    func update(_ id: String, to fresh: BoostPackage) async throws -> Update {
        guard let record = records.first(where: { $0.id == id }), record.enabled, let kept = packages[id] else {
            throw BoostPackage.Invalid("Only a kept boost that is on takes updates.")
        }
        let package = try BoostPackage.read(id: id, files: fresh.files, sites: fresh.sites)
        if package.widens(kept) {
            if let index = records.firstIndex(where: { $0.id == id }) {
                var changed = records; changed[index].enabled = false
                try library.save(changed); records = changed; await refresh(id)
            }
            return .held
        }
        _ = try library.keep(package, author: record.author, session: record.session)
        reload(); await refresh(id)
        return .applied
    }
    func restore(_ revision: BoostRevision, record: BoostRecord) async {
        do {
            let package = try BoostPackage.read(id: record.id, files: revision.files, sites: revision.sites)
            _ = try library.keep(package, author: "You", session: record.session)
            reload(); await refresh(record.id, reloadPages: true)
        } catch { trouble = error.localizedDescription }
    }
    /// `reloadCode`: a plugin with code on, or changed, reloads the pages
    /// it runs on; one that came from another Mac waits for their next load.
    private func refresh(_ id: String, except: UUID? = nil, reloadPages: Bool = false, sites: [String]? = nil, reloadCode: Bool = true, profile: String? = nil) async {
        BoostServices.shared.reconcile()
        BoostContributions.reconcile()
        if !isEnabled(id) {
            _ = Routines.shared.remove("boost-live:" + id)
            let repairs = repairing.filter { $0.value.id == id }.map(\.key)
            for session in repairs { repairing.removeValue(forKey: session); _ = Agents.shared.stop(session) }
            for session in Agents.shared.sessions where session.boostOrigin == id && session.state.live { _ = Agents.shared.stop(session.id) }
            for tab in tabs where trials[tab.id].map({ repairs.contains($0.session) }) == true { await undo(on: tab) }
        }
        for tab in tabs where tab.id != except {
            if let profile, AddonProfiles.key(AddonProfiles.of(tab)) != profile { continue }
            guard let web = tab.builtPage else { continue }
            arm(tab)
            if tab.address?.host == id + ".boost", !isEnabled(id) { web.navigate(html: "<h1>This plugin is turned off.</h1>", base: nil) }
            guard !tab.shy, !tab.isDev, trials[tab.id]?.package.id != id else { continue }
            _ = try? await BoostJavaScript.evaluate(BoostScript.remove, on: web, world: Self.pageWorld(id))
            if reloadPages || (reloadCode && packages[id]?.rung != .look) {
                if let url = tab.address, (sites ?? records.first(where: { $0.id == id })?.sites ?? []).contains(where: { $0 == "<all_urls>" || $0 == url.host }) { tab.reloadForChange(.plugin) }
            } else if !safeMode, !tab.shy, let package = packages[id], package.rung == .look, let url = tab.address, package.matches(url),
                      isEnabled(id, in: AddonProfiles.of(tab)) {
                // Only a look goes on a page as it is: code from another
                // Mac waits for the page's next load.
                _ = try? await BoostJavaScript.evaluate(BoostScript.source(package), on: web, world: Self.pageWorld(id))
            }
        }
    }

    // MARK: - from another Mac

    /// A plugin kept without a trial or its card: one that came from another
    /// Mac (SyncInstalls, `synced`), its files checked against the digest
    /// the account names, or one a test run or an import keeps straight
    /// away (bench, Arc). From another Mac, a look comes on or off as it is
    /// there; code this Mac never said yes to comes in off and waits for
    /// the person to turn it on here (SyncAddons.arrival, docs/sync.md).
    @discardableResult
    func keepSynced(_ package: BoostPackage, author: String, enabled: Bool = true, runsOn: String? = nil, synced: Bool = false) throws -> BoostRecord {
        let arrival = synced ? SyncAddons.arrival(package, kept: packages[package.id], here: records.first { $0.id == package.id }, enabled: enabled)
            : SyncAddons.PluginArrival(enabled: enabled, waits: false)
        var profiles = records.first { $0.id == package.id }?.profiles ?? AddonProfiles(signIn: nil, enabled: arrival.enabled)
        if arrival.waits { profiles.enabled = profiles.enabled.mapValues { _ in false } }
        profiles.setEnabled(arrival.enabled, in: nil)
        let kept = try library.keep(package, author: author, session: "", enabled: profiles.enabled.values.contains(true), waits: arrival.waits, runsOn: runsOn, profiles: profiles)
        reload(package.id)
        Task { await refresh(package.id, reloadCode: false) }
        return kept
    }

    /// On or off, and the Mac that ticks it, as the account says: none
    /// when the one that did gave it up. One that waits for the person's
    /// yes here stays off whatever the account says.
    func applySynced(_ id: String, enabled: Bool, runsOn: String?) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        var changed = records
        if records[index].waits != true {
            var profiles = changed[index].profiles ?? AddonProfiles(signIn: nil, enabled: changed[index].enabled)
            profiles.setEnabled(enabled, in: nil)
            changed[index].profiles = profiles
            changed[index].enabled = profiles.enabled.values.contains(true)
        }
        changed[index].runsOn = runsOn
        guard changed != records else { return }
        let was = records[index]
        do { try library.save(changed); records = changed }
        catch { trouble = error.localizedDescription; return }
        if was.profiles != changed[index].profiles || was.enabled != changed[index].enabled {
            // Turned off elsewhere, its code leaves the pages here too.
            Task { await refresh(id, reloadCode: !enabled, profile: AddonProfiles.key(nil)) }
        } else if was.runsOn != changed[index].runsOn {
            BoostServices.shared.reconcile()
            BoostContributions.reconcile()
        }
    }

    /// Removed on another Mac: gone here too, as Delete takes it.
    func removeSynced(_ id: String) {
        if let index = records.firstIndex(where: { $0.id == id }), var profiles = records[index].profiles {
            profiles.remove(nil)
            if !profiles.enabled.isEmpty {
                var changed = records; changed[index].profiles = profiles
                changed[index].enabled = profiles.enabled.values.contains(true)
                do { try library.save(changed); records = changed }
                catch { trouble = error.localizedDescription; return }
                Task { await refresh(id, profile: AddonProfiles.key(nil)) }
                return
            }
        }
        let sites = records.first { $0.id == id }?.sites ?? []
        do { try library.delete(id) } catch { trouble = error.localizedDescription; return }
        reload(id)
        Task {
            await refresh(id, reloadPages: true, sites: sites)
            BoostContributions.forget(id)
        }
    }

    /// The tab's address changed with no load (pushState): the trial was
    /// checked on another page, so Keep waits for a new one.
    func moved(_ tab: Tab) {
        guard let trial = trials[tab.id], tab.address != trial.url, !busy.contains(tab.id) else { return }
        trials[tab.id]?.ready = false
        trials[tab.id]?.problem = "The page changed. Undo this trial and ask again on the new page."
    }

    func navigated(_ tab: Tab) {
        if let trial = trials[tab.id], tab.address != trial.url {
            trials[tab.id]?.ready = false
            trials[tab.id]?.problem = "The page changed. Undo this trial and ask again on the new page."
        }
        guard !safeMode, !tab.shy else { return }
        for record in on(tab.address, in: AddonProfiles.of(tab)) where record.enabled {
            guard let package = packages[record.id], !package.checks.isEmpty else { continue }
            let key = record.id + ":" + (tab.address?.host ?? "") + ":" + record.revision + ":" + String(ISO8601DateFormatter().string(from: Date()).prefix(10))
            guard !checked.contains(key), record.lastCheck.map({ Date().timeIntervalSince($0) > 86_400 }) ?? true else { continue }
            checked.insert(key)
            let url = tab.address
            Task { [weak self, weak tab] in
                try? await Task.sleep(for: .seconds(1))
                guard let self, let tab, tab.address == url, let web = tab.builtPage else { return }
                guard let report = try? await BoostJavaScript.evaluate(BoostScript.report, on: web, world: Self.pageWorld(record.id)) as? [String: Any],
                      let checks = report["checks"] as? [[String: Any]], checks.contains(where: { $0["state"] as? String != "skipped" }),
                      let index = self.records.firstIndex(where: { $0.id == record.id && $0.revision == record.revision }) else { return }
                let failed = checks.contains { $0["state"] as? String == "fail" }
                var changed = self.records
                changed[index].lastCheck = Date(); changed[index].failures = failed ? changed[index].failures + 1 : 0
                changed[index].lastProblem = failed ? "A page check failed" : nil
                do {
                    try self.library.save(changed); self.records = changed
                    if changed[index].failures >= 2 { self.mend(changed[index], at: url) }
                }
                catch { self.trouble = error.localizedDescription }
            }
        }
    }
    private func mend(_ record: BoostRecord, at url: URL?) {
        guard record.rung == .look, record.enabled, (record.repairs ?? 0) < 2,
              !repairing.values.contains(where: { $0.id == record.id }), let url, Agents.installed else { return }
        let prompt = """
        Repair the saved Look boost \(record.id) on \(url.absoluteString).
        Its original request is: \(record.intent)
        Read skill('boosts') and boost_read('\(record.id)'). Open your own tab on the URL.
        Change only the stylesheet and checks needed to restore the original request. Keep its sites.
        Call boost and inspect its checks. A passing CSS-only repair is saved by Yab.
        Never add JavaScript, new sites or a new feature. Stop after five tries.
        """
        let session = Agents.shared.run(prompt: prompt, cli: nil, access: "browser", quiet: true,
                                        name: "Fix \(record.name)", sealed: true, resume: nil)
        repairing[session.id] = record
    }

    func closed(_ tab: Tab) {
        guard let trial = trials.removeValue(forKey: tab.id) else { return }
        try? FileManager.default.removeItem(at: library.root.appendingPathComponent(".trial/" + trial.id.uuidString))
    }

    /// A kept plugin's wake (BoostServices), over: out of the tab row as it
    /// worked, its answer is one row where finished tasks are (Noticing,
    /// "wake."), and a word in the corner when nothing on screen says it.
    private func woke(_ session: Agents.Session) {
        guard session.boostOrigin != nil, session.quiet, session.parent == nil, session.state == .done,
              let line = Self.headline(session.result), let browser = Agents.shared.browser else { return }
        Hints.shared.compose()
        guard !(browser.chatOpen && browser.chatID == session.id), !browser.askingNew else { return }
        browser.toaster.pop("\(session.name): \(line)", mark: "puzzlepiece.extension", undo: { [weak browser] in
            if let browser { Noticing.shared.show(woken: session, in: browser) }
        }, act: "Show", feedback: .success)
    }

    /// An answer's first line, without its markdown, short enough for a row.
    nonisolated static func headline(_ answer: String) -> String? {
        guard let first = answer.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) else { return nil }
        let bare = first.replacingOccurrences(of: #"^#+\s*|\*\*|__|`"#, with: "", options: .regularExpression)
        return bare.count > 80 ? String(bare.prefix(79)) + "\u{2026}" : bare
    }

    func ended(_ session: Agents.Session) {
        if let room = rooms.removeValue(forKey: session.id) { shut(room) }
        woke(session)
        guard let repair = repairing.removeValue(forKey: session.id),
              let index = records.firstIndex(where: { $0.id == repair.id && $0.revision == repair.revision }) else { return }
        var changed = records
        changed[index].repairs = (changed[index].repairs ?? 0) + 1
        if changed[index].repairs! >= 2 {
            changed[index].enabled = false
            changed[index].lastProblem = "Two repairs failed. Turn it on after fixing it."
        }
        do { try library.save(changed); records = changed }
        catch { trouble = error.localizedDescription }
        Task { await refresh(repair.id) }
    }

}
