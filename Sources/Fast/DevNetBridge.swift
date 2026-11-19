import AppKit
import WebKit

// The bridge between WebKit's inspector page and yab's Network
// (DevNet.swift). The inspector's page keeps the network as WI.Resource
// objects and says when each changes; DevNet.script listens to the classes
// themselves, so it hears every resource of every frame and worker, and
// passes the changed fields to yab through the inspector's message handler.
// What yab asks back (a body, a resend, an override, blocking, throttling,
// the cache off) goes through `__yabNet`, run in that page.
//
// Only this file knows WebKit's inspector classes by name. When they are not
// what the script expects it says so once (`x`), and the panel offers
// WebKit's own Network instead.

enum DevNet {
    static let script = PageScript.load("dev-net")
}

// MARK: - the browser's side

extension Browser {
    /// The inspector's page for the tab in front, if it is up.
    var netInspector: NSObject? {
        guard let tab = toolsFront, inspected === tab, inspectorLive else { return nil }
        return Inspector.ofPage(tab.page)
    }

    /// A line of `__yabNet` run in the inspector's page, its answer back.
    func netRun(_ js: String, arguments: [String: Any] = [:], _ done: ((Any?) -> Void)? = nil) {
        guard let inspector = netInspector, let web = DevTools.page(inspector) else { done?(nil); return }
        web.callAsyncJavaScript("if (!window.__yabNet) return null; return await (\(js));", arguments: arguments, in: nil, in: .page) { result in
            done?(try? result.get())
        }
    }

    /// A response's body, as WebKit has it; kept in the log once read.
    func netBody(_ row: NetRow, _ done: @escaping (NetBody) -> Void) {
        guard let tab = toolsFront else { done(NetBody(text: "", base64: false, error: "gone")); return }
        let log = tab.netLog
        if let kept = log.bodies[row.resource.id] { done(kept); return }
        // Brought in from a file, or heard by an inspector since gone.
        guard !row.resource.imported, row.resource.session == log.session else { done(NetBody(text: "", base64: false, error: "gone")); return }
        netRun("__yabNet.body(id)", arguments: ["id": row.resource.bridge]) { value in
            let raw = value as? [String: Any] ?? [:]
            let error = raw["e"] as? String
            let body = NetBody(text: raw["t"] as? String ?? "", base64: raw["b"] as? Bool ?? false,
                               error: (error?.isEmpty ?? true) ? (value == nil ? "gone" : nil) : error).readable(mime: row.resource.mime)
            if body.error == nil { log.keep(body, for: row.resource.id) }
            done(body)
        }
    }

    /// The conditions yab keeps, given to the inspector's page: as it
    /// comes up, and whenever they change.
    func netApplyConditions() {
        let prefs = NetPrefs.shared
        let rules: [[String: Any]] = prefs.rulesOn ? prefs.rules.map { rule in
            var out: [String: Any] = ["on": rule.on, "p": rule.pattern, "c": rule.condition == "block" ? "block" : "throttle", "name": NetThrottle.named(rule.condition)?.name ?? ""]
            if let preset = NetThrottle.named(rule.condition) { out["preset"] = preset.script }
            return out
        } : []
        let preset = prefs.throttle == NetThrottle.offline.id ? nil : NetThrottle.named(prefs.throttle)
        netRun("__yabNet.conditions(r, p, o)", arguments: ["r": rules, "p": preset?.script ?? NSNull(), "o": prefs.throttle == NetThrottle.offline.id])
        netRun("__yabNet.cache(c)", arguments: ["c": prefs.noCache])
        netRun("__yabNet.keep(k)", arguments: ["k": prefs.keepLog])
        netRun("__yabNet.userAgent(u)", arguments: ["u": prefs.userAgent ?? NSNull()])
        netRun("__yabNet.extraHeaders(h)", arguments: ["h": prefs.saveData.map { ["Save-Data": $0] } ?? [:]])
    }
}

/// What yab keeps of Network's settings across pages and launches: Keep
/// log, Disable cache, the throttling, the rules, the user agent.
@Observable final class NetPrefs {
    static let shared = NetPrefs()

    struct Rule: Codable, Equatable, Identifiable {
        var id = UUID()
        var on: Bool
        var pattern: String
        /// "block", or a throttling profile's id.
        var condition: String
    }

    var keepLog: Bool { didSet { save("net.keepLog", keepLog) } }
    var noCache: Bool { didSet { save("net.noCache", noCache) } }
    var throttle: String { didSet { save("net.throttle", throttle) } }
    var rulesOn: Bool { didSet { save("net.rulesOn", rulesOn) } }
    var rules: [Rule] { didSet { if let data = try? JSONEncoder().encode(rules) { save("net.rules", data) } } }
    var profiles: [NetThrottle] { didSet { if let data = try? JSONEncoder().encode(profiles) { save("net.profiles", data) } } }
    /// nil for the browser's own.
    var userAgent: String? { didSet { settings.set(userAgent, forKey: "net.userAgent") } }
    /// "on" or "off" sent as Save-Data, nil for the browser's default.
    var saveData: String? { didSet { settings.set(saveData, forKey: "net.saveData") } }
    var bigRows: Bool { didSet { save("net.bigRows", bigRows) } }
    var groupByFrame: Bool { didSet { save("net.groupByFrame", groupByFrame) } }
    var overview: Bool { didSet { save("net.overview", overview) } }
    var screenshots: Bool { didSet { save("net.screenshots", screenshots) } }
    var columns: [String] { didSet { save("net.columns", columns) } }

    private let settings: UserDefaults

    private convenience init() { self.init(settings: Store.settings) }

    init(settings: UserDefaults) {
        self.settings = settings
        let s = settings
        keepLog = s.bool(forKey: "net.keepLog")
        noCache = s.bool(forKey: "net.noCache")
        throttle = s.string(forKey: "net.throttle") ?? NetThrottle.none.id
        rulesOn = s.object(forKey: "net.rulesOn") as? Bool ?? true
        rules = (s.data(forKey: "net.rules")).flatMap { try? JSONDecoder().decode([Rule].self, from: $0) } ?? []
        profiles = (s.data(forKey: "net.profiles")).flatMap { try? JSONDecoder().decode([NetThrottle].self, from: $0) } ?? []
        userAgent = s.string(forKey: "net.userAgent")
        saveData = s.string(forKey: "net.saveData")
        bigRows = s.bool(forKey: "net.bigRows")
        groupByFrame = s.bool(forKey: "net.groupByFrame")
        overview = s.object(forKey: "net.overview") as? Bool ?? true
        screenshots = s.bool(forKey: "net.screenshots")
        columns = s.stringArray(forKey: "net.columns") ?? NetColumn.defaults
    }

    private func save(_ key: String, _ value: Any) { settings.set(value, forKey: key) }

    /// Something holds the network back or changes it: ⚠ on the tab, as
    /// Chrome's Network tab warns.
    var warns: Bool {
        throttle != NetThrottle.none.id || (rulesOn && rules.contains(where: \.on))
    }
}

/// A throttling profile: Chrome's presets, Offline, and your own.
struct NetThrottle: Codable, Equatable, Identifiable, Hashable {
    var id: String
    var name: String
    /// Added to every request, in milliseconds.
    var latency: Double
    /// kbit/s; 0 for no limit.
    var download: Double
    var upload: Double

    static let none = NetThrottle(id: "none", name: "No throttling", latency: 0, download: 0, upload: 0)
    // Chrome's own numbers (NetworkManager.ts): Lighthouse's, applied as
    // DevTools applies them, latency times its factor, speeds times .9 or .8.
    static let fast4G = NetThrottle(id: "fast4g", name: "Fast 4G", latency: 165, download: 8100, upload: 1350)
    static let slow4G = NetThrottle(id: "slow4g", name: "Slow 4G", latency: 562.5, download: 1440, upload: 675)
    static let slow3G = NetThrottle(id: "3g", name: "3G", latency: 2000, download: 400, upload: 400)
    static let offline = NetThrottle(id: "offline", name: "Offline", latency: 0, download: 0, upload: 0)
    static let presets = [fast4G, slow4G, slow3G]

    static func named(_ id: String) -> NetThrottle? {
        if id == none.id { return nil }
        return (presets + [offline] + NetPrefs.shared.profiles).first { $0.id == id }
    }

    /// As the bridge takes it.
    var script: [String: Any] {
        ["latency": latency, "down": download > 0 ? download : 1e9, "up": upload > 0 ? upload : 1e9, "name": name]
    }
}

// MARK: - the beat

nonisolated(unsafe) private var tickingKey: UInt8 = 0

extension Browser {
    /// Network's beat while the card is out, four times a second and quicker
    /// while a held request is due: WebKit may let the timers of its hidden
    /// inspector page wait up to a minute, so the batches and the throttled
    /// requests go on Yab's clock (`__yabNet.tick`).
    func netBeat() {
        guard objc_getAssociatedObject(self, &tickingKey) as? Bool != true else { return }
        objc_setAssociatedObject(self, &tickingKey, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        netTick()
    }

    /// How many beats there were, for the bench.
    static var netTicks = 0

    private func netTick() {
        // Only the card going away ends the beat: an inspector between pages
        // or between tabs comes back, and its held requests wait for it. A
        // card on its way out is out already.
        guard devOpen || devMoving else {
            objc_setAssociatedObject(self, &tickingKey, false, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            return
        }
        guard let tab = toolsFront, inspected === tab, let inspector = Inspector.ofPage(tab.page), let web = DevTools.page(inspector) else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.netTick() }
            return
        }
        Browser.netTicks += 1
        web.evaluateJavaScript("(\(Browser.wireTick), window.__yabNet && window.__yabNet.tick ? window.__yabNet.tick() : -1)") { [weak self] value, _ in
            guard let self else { return }
            let next = (value as? NSNumber)?.doubleValue ?? -1
            let delay = next >= 0 ? max(0.01, min(0.25, next / 1000)) : 0.25
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.netTick() }
        }
    }
}

// MARK: - connecting, pictures, keys

extension Browser {
    /// WebKit's inspector has just come up for `tab`: its log starts again,
    /// unless Keep log is on, and its pictures follow its pages.
    func netConnected(_ tab: Tab, again: Bool = false) {
        netWire(tab)
        let log = tab.netLog
        log.unavailable = false
        // Back on the page it was put away on: its rows and the one picked stay.
        if again { log.reconnected(); return }
        log.connected()
        netPanel.selected = nil
        netPanel.overridden = [:]
    }

    /// The log told what Keep log is and where a new page's pictures go,
    /// whenever the card is over its tab.
    func netWire(_ tab: Tab) {
        let log = tab.netLog
        log.keepLog = { NetPrefs.shared.keepLog }
        log.navigated = { [weak self, weak tab] in
            guard let self, let tab else { return }
            netShoot(tab)
        }
    }

    /// Screenshots: the page pictured small as it loads, every tenth of a
    /// second at first and then less often, for its first few seconds,
    /// while the setting is on.
    func netShoot(_ tab: Tab) {
        guard NetPrefs.shared.screenshots else { return }
        let log = tab.netLog
        var taken = 0
        func shoot() {
            guard taken < 24, NetPrefs.shared.screenshots, inspected === tab else { return }
            taken += 1
            tab.page.snapshot(PageShot(width: 240)) { image, _ in
                if let image, let now = log.horizon { log.took(image, at: now) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + (taken < 12 ? 0.1 : 0.3)) { shoot() }
        }
        shoot()
    }
}

extension Browser {
    /// ⌘F in Network, as Chromium's: Search at the side, its field taking
    /// the keyboard, every request it finds the words in lit in the list.
    func netSearch() {
        netPanel.searchOpen = true
        netPanel.focusSearch = true
    }
}

/// Network's own keys while its table has the keyboard, as Chromium's:
/// ⌘K and ⌃L clear, ⌘E records, ⌘F searches, Escape closes what is open.
/// Asked before the app's own keys, so ⌘K here isn't Actions.
enum NetKeys {
    @MainActor static func take(_ event: NSEvent, browser: Browser) -> Bool {
        guard event.type == .keyDown, browser.devOpen, browser.devPane == .network,
              event.window?.firstResponder is NetTable else { return false }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = Hotkey.readings(event).first?.key ?? event.charactersIgnoringModifiers?.lowercased() ?? ""
        let panel = browser.netPanel
        if (flags == [.command] && key == "k") || (flags == [.control] && key == "l") {
            browser.netClear()
            return true
        }
        if flags == [.command], key == "e" {
            browser.toolsFront?.netLog.recording.toggle()
            return true
        }
        if flags == [.command], key == "f" {
            browser.netSearch()
            return true
        }
        if flags.isEmpty, event.keyCode == 53 {
            if panel.selected != nil { panel.selected = nil } else if panel.searchOpen { panel.searchOpen = false } else if panel.drawer != nil { panel.drawer = nil } else { return false }
            return true
        }
        return false
    }
}
