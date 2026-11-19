import AppKit
import Combine
import SwiftUI

// Engines (General in Settings; round 2 of the engine artifact, picked 2026-10-29):
// which engine draws a site. Three layers, the first that speaks wins:
//
//   1. the owner's own rule for the exact host (Opens in, ⌘K's Always Open
//      in, Settings' table), stored as `site.engine.<host>` as before;
//   2. a built-in rule Yab ships (protected video and Apple Pay to WebKit,
//      the Chrome Web Store to Chromium), which the table can override;
//   3. the default engine. Auto is Chromium, always: WebKit only through the
//      built-in rules above (protected video, Apple Pay), never because memory
//      is tight (the owner, 2026-11-02). WebKit First is WebKit, except that a
//      tab opening or waking while memory is tight gets Chromium. Neither ever
//      moves a live tab: a move reloads the page, and a page's memory, media
//      and scripts don't carry.
//
// A build with Yab's own Chromium and no choice made is on Auto, an upgrade
// from a WebKit-only version included (PageEngineSelection.requested). A build
// without it, Intel included, keeps WebKit and shows no Engine page or actions.

/// A rule Yab ships: a family of hosts, the engine they need, and why.
struct EngineBuiltInRule: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    /// Matched as ChromiumDRM matches: the domain itself or below it.
    let domains: [String]
    let engine: PageEngineKind
    let reason: String

    /// The host its mark is fetched for.
    var host: String { domains[0] }

    static let protectedVideo = "Protected video"

    /// Our own CEF has no Widevine and no Apple Pay: those go to WebKit.
    static let all: [EngineBuiltInRule] = [
        .init(id: "netflix", name: "Netflix", domains: ["netflix.com"], engine: .webKit, reason: protectedVideo),
        .init(id: "disneyplus", name: "Disney+", domains: ["disneyplus.com"], engine: .webKit, reason: protectedVideo),
        .init(id: "primevideo", name: "Prime Video", domains: ["primevideo.com"], engine: .webKit, reason: protectedVideo),
        .init(id: "appletv", name: "Apple TV", domains: ["tv.apple.com"], engine: .webKit, reason: protectedVideo),
        .init(id: "max", name: "Max", domains: ["max.com", "hbomax.com", "hbo.com"], engine: .webKit, reason: protectedVideo),
        .init(id: "spotify", name: "Spotify", domains: ["spotify.com"], engine: .webKit, reason: protectedVideo),
        .init(id: "applemusic", name: "Apple Music", domains: ["music.apple.com"], engine: .webKit, reason: protectedVideo),
        .init(id: "hulu", name: "Hulu", domains: ["hulu.com"], engine: .webKit, reason: protectedVideo),
        .init(id: "peacock", name: "Peacock", domains: ["peacocktv.com"], engine: .webKit, reason: protectedVideo),
        .init(id: "paramountplus", name: "Paramount+", domains: ["paramountplus.com"], engine: .webKit, reason: protectedVideo),
        .init(id: "crunchyroll", name: "Crunchyroll", domains: ["crunchyroll.com"], engine: .webKit, reason: protectedVideo),
        .init(id: "applepay", name: "Apple Pay checkouts",
              domains: ["store.apple.com", "checkout.stripe.com", "buy.stripe.com", "pay.shopify.com", "shop.app", "checkout.square.site"],
              engine: .webKit, reason: "Apple Pay"),
        .init(id: "chromewebstore", name: "Chrome Web Store", domains: ["chromewebstore.google.com", "chrome.google.com"],
              engine: .chromium, reason: "Extensions"),
    ]

    static func matching(host: String) -> EngineBuiltInRule? {
        all.first { rule in rule.domains.contains { ChromiumDRM.matches(host: host, domain: $0) } }
    }
}

/// The default engine, as the Settings menu names it.
enum EngineDefault: String, CaseIterable, Sendable {
    case auto, webKit, webKitFirst, chromium

    /// What the menu offers. WebKit First stays out until its cost under memory
    /// pressure is understood (the 8 GB stand: 19% more memory than WebKit).
    static let offered: [EngineDefault] = [.auto, .webKit, .chromium]

    var title: String {
        switch self {
        case .auto: "Auto"
        case .webKit: "WebKit"
        case .webKitFirst: "WebKit First"
        case .chromium: "Chromium"
        }
    }

    /// The engine of a tab with no rule and memory to spare.
    var base: PageEngineKind {
        switch self {
        case .auto, .chromium: .chromium
        case .webKit, .webKitFirst: .webKit
        }
    }
}

/// What decided a tab's engine, for the hover card's foot.
struct EngineDecision: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        /// ⌘K's Open in: this tab only, until it closes.
        case tab
        case own
        case builtIn(String)
        /// The default engine, Auto or not.
        case standard
        /// Memory was tight when the tab opened: WebKit First chose Chromium.
        /// Auto never spares (the owner, 2026-11-02).
        case spared
    }
    let kind: PageEngineKind
    let source: Source

    var reason: String? {
        guard case .builtIn(let id) = source else { return nil }
        return EngineBuiltInRule.all.first { $0.id == id }?.reason ?? EngineBuiltInRule.protectedVideo
    }
}

enum EngineRules {
    static let defaultKey = "engine.default"
    static let builtInPrefix = "engine.builtin."
    static let ownPrefix = "site.engine."

    /// Whether this build has Yab's own Chromium (YAB_CEF=1), or a development
    /// world asking for it. Without it there is no Engine page and no actions.
    /// PageEngineFactory.chromiumAvailable, read off the main actor too.
    static var available: Bool {
        let requested = PageEngineSelection.requested(defaults: Store.settings.string(forKey: PageEngineSelection.key),
                                                      environment: ProcessInfo.processInfo.environment["YAB_ENGINE"],
                                                      permitted: Store.development || Store.testing,
                                                      bundledChromium: PageEngineSelection.bundledChromium)
        return PageEngineSelection.supportsChromium && (PageEngineSelection.bundledChromium || requested == .chromium)
    }

    /// macOS says memory is short (warning or critical), as Sleep reads it.
    /// A test world that names its engine keeps it, whatever a busy farm Mac's
    /// memory says, or its checks quietly run on the other engine.
    static var memoryTight: Bool {
        if Store.testing, Pressure.forced == nil, ProcessInfo.processInfo.environment["YAB_ENGINE"]?.isEmpty == false { return false }
        return (Pressure.level ?? 1) >= 2
    }

    /// The rule order, kept free of the store so it can be tested alone.
    /// `base` is the engine the tab would use with no rule: the window's.
    static func decide(held: PageEngineKind?, own: SiteEngineChoice, builtIn: (rule: String, kind: PageEngineKind)?,
                       base: PageEngineKind, auto: Bool, webKitFirst: Bool = false, tight: Bool) -> EngineDecision {
        if let held { return EngineDecision(kind: held, source: .tab) }
        switch own {
        case .chromium: return EngineDecision(kind: .chromium, source: .own)
        case .webKit: return EngineDecision(kind: .webKit, source: .own)
        case .recommended: break
        }
        if let builtIn { return EngineDecision(kind: builtIn.kind, source: .builtIn(builtIn.rule)) }
        if base == .webKit, webKitFirst, tight { return EngineDecision(kind: .chromium, source: .spared) }
        return EngineDecision(kind: base, source: .standard)
    }
}

/// The rules live in the same defaults as the old Opens in: own rules keep
/// their `site.engine.<host>` keys, so nothing needs migrating.
@MainActor
extension SiteEngineSettings {
    struct OwnRule: Identifiable, Equatable {
        let host: String
        let kind: PageEngineKind
        var id: String { host }
    }

    /// The owner's rules, by host.
    var ownRules: [OwnRule] {
        store.dictionaryRepresentation().compactMap { key, value in
            guard key.hasPrefix(EngineRules.ownPrefix), let raw = value as? String,
                  let choice = SiteEngineChoice(rawValue: raw), choice != .recommended else { return nil }
            return OwnRule(host: String(key.dropFirst(EngineRules.ownPrefix.count)), kind: choice == .chromium ? .chromium : .webKit)
        }
        .sorted { $0.host < $1.host }
    }

    func setOwn(_ kind: PageEngineKind?, host: String) {
        let key = EngineRules.ownPrefix + host
        if let kind { store.set(kind == .chromium ? SiteEngineChoice.chromium.rawValue : SiteEngineChoice.webKit.rawValue, forKey: key) }
        else { store.removeObject(forKey: key) }
    }

    /// A built-in rule's engine, the owner's override first.
    func engine(of rule: EngineBuiltInRule) -> PageEngineKind {
        store.string(forKey: EngineRules.builtInPrefix + rule.id).flatMap(PageEngineKind.init(rawValue:)) ?? rule.engine
    }

    /// Picking a built-in rule's own engine again removes the override.
    func set(_ kind: PageEngineKind, for rule: EngineBuiltInRule) {
        let key = EngineRules.builtInPrefix + rule.id
        if kind == rule.engine { store.removeObject(forKey: key) } else { store.set(kind.rawValue, forKey: key) }
    }

    /// The built-in rule for this page, with its engine now.
    func builtIn(for url: URL?) -> (rule: String, kind: PageEngineKind)? {
        guard let host = Self.host(url) else { return nil }
        if let rule = EngineBuiltInRule.matching(host: host) { return (rule.id, engine(of: rule)) }
        // An isolated acceptance world's stand-in for a protected service.
        if ChromiumDRM.requiresWebKit(url) { return ("protected", .webKit) }
        return nil
    }

    /// Auto unless Chromium or WebKit First was picked by name. WebKit is the
    /// window's own engine (YabPageEngine), not a value kept here.
    var auto: Bool {
        let picked = store.string(forKey: EngineRules.defaultKey)
        return picked != EngineDefault.chromium.rawValue && picked != EngineDefault.webKitFirst.rawValue
    }

    var webKitFirst: Bool { store.string(forKey: EngineRules.defaultKey) == EngineDefault.webKitFirst.rawValue }

    /// Chromium picked by name as the default engine, not Auto: no page is
    /// moved to WebKit on a guess, only by a rule.
    var chromiumByName: Bool { store.string(forKey: EngineRules.defaultKey) == EngineDefault.chromium.rawValue }

    func decide(_ base: PageEngineKind, at url: URL?, held: PageEngineKind? = nil,
                tight: Bool = EngineRules.memoryTight) -> EngineDecision {
        if ChromePages.needsChromium(url) { return EngineDecision(kind: .chromium, source: .own) }
        if EngineRules.onlyWebKit(url) { return EngineDecision(kind: .webKit, source: .own) }
        return EngineRules.decide(held: held, own: choice(for: url), builtIn: builtIn(for: url),
                                  base: base, auto: auto, webKitFirst: webKitFirst, tight: tight)
    }
}

@MainActor
extension EngineRules {
    /// What the Default engine menu shows.
    static var standard: EngineDefault {
        let sites = SiteEngineSettings.shared
        guard (PageEngineFactory.requestedEngine ?? .webKit) == .chromium else { return sites.webKitFirst ? .webKitFirst : .webKit }
        return sites.auto ? .auto : .chromium
    }

    /// Auto and Chromium both make Chromium the window's engine; WebKit and
    /// WebKit First make it WebKit. Written at once: new tabs and tabs with no
    /// page take it now, and no working page is touched (EngineSwitchGlobal).
    static func choose(_ value: EngineDefault) {
        do {
            try EngineSwitchGlobal.choose(value.base)
            // WebKit is only the engine set above; the key tells the others.
            Store.settings.set((value == .chromium || value == .webKitFirst ? value : .auto).rawValue, forKey: defaultKey)
        } catch {
            NSLog("Default engine: %@", String(describing: error))
            BrowserWindows.shared.browsers.first?.announce("Chromium isn\u{2019}t in this build", mark: "exclamationmark.triangle",
                                                           on: SettingsWindow.shared.toaster)
        }
        EngineRulesModel.shared.reload()
    }

    /// Yab's own pages: their addresses are answered by handlers on WebKit's
    /// configuration, and Chromium would show a failed load.
    nonisolated static func onlyWebKit(_ url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        return scheme == "yab" || scheme == "yab-artifact"
    }

    /// Which pages the default engine applies to: web pages and a tab with
    /// none yet. Another scheme's page keeps the engine that owns it.
    nonisolated static func followsDefault(_ url: URL?) -> Bool {
        guard let url else { return true }
        return ["http", "https", "about", "data", "file"].contains(url.scheme?.lowercased() ?? "")
    }

    /// A tab coming back from the session: saved engines record the default
    /// of their day, so the default now decides, or a choice never reaches
    /// the tabs of a profile that has only ever been WebKit. Rules decide
    /// on top of it when the page opens.
    nonisolated static func restored(saved: PageEngineKind, url: URL?, standard: PageEngineKind?) -> PageEngineKind {
        guard let standard, followsDefault(url) else { return saved }
        return standard
    }
}

/// The page's view of the rules, refreshed when the defaults change.
@MainActor
@Observable final class EngineRulesModel {
    static let shared = EngineRulesModel()

    private(set) var own: [SiteEngineSettings.OwnRule] = []
    private(set) var standard: EngineDefault = .webKit
    private(set) var builtIn: [String: PageEngineKind] = [:]
    @ObservationIgnored private var watch: NSObjectProtocol?

    private init() {
        reload()
        watch = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: nil) { _ in
            // Never queue: .main: a writer on another thread would wait for the main thread.
            DispatchQueue.main.async { MainActor.assumeIsolated { EngineRulesModel.shared.reload() } }
        }
    }

    func reload() {
        let sites = SiteEngineSettings.shared
        let own = sites.ownRules
        if own != self.own { self.own = own }
        let standard = EngineRules.standard
        if standard != self.standard { self.standard = standard }
        let builtIn = Dictionary(uniqueKeysWithValues: EngineBuiltInRule.all.map { ($0.id, sites.engine(of: $0)) })
        if builtIn != self.builtIn { self.builtIn = builtIn }
    }
}

// MARK: - tabs

@MainActor
extension PageEngineFactory {
    /// The engine a tab opens or wakes into: the one time the default looks
    /// at memory. A tab it moved remembers that, so it wakes into the
    /// default's own engine again once memory is back.
    func opening(_ tab: Tab) -> PageEngineKind {
        if let pending = tab.enginePendingDefault { tab.followDefaultEngine(pending) }
        let base: PageEngineKind = tab.engineMemoryMoved ? tab.engineDefaultBase : tab.engineKind
        let decision = sites.decide(base, at: tab.address, held: tab.engineHeld)
        tab.engineMemoryMoved = decision.source == .spared
        return resolved(decision.kind)
    }

    /// What `opening` will say for a tab with no page yet, deciding nothing:
    /// the way to a page depends on the engine it will be built on, and
    /// memory can send it to the other one.
    func upcoming(_ tab: Tab, at url: URL?) -> PageEngineKind {
        let base = tab.enginePendingDefault ?? (tab.engineMemoryMoved ? tab.engineDefaultBase : tab.engineKind)
        return resolved(sites.decide(base, at: url, held: tab.engineHeld).kind)
    }
}

@MainActor
extension Tab {
    /// The default's own engine for this tab, memory aside.
    var engineDefaultBase: PageEngineKind { chromiumDRMEnabled ? .chromium : .webKit }

    /// The decision behind the tab's engine now.
    var engineDecision: EngineDecision {
        engineFactory.sites.decide(engineDefaultBase, at: address, held: engineHeld, tight: engineMemoryMoved)
    }

    /// The engine in words: "WebKit", "WebKit · Protected video", "Chromium",
    /// for probes; the hover card no longer shows it. Nil in a build without
    /// Chromium, where every page is WebKit.
    var engineFoot: String? {
        guard engineFactory.kinds.contains(.chromium), SiteEngineSettings.host(address) != nil else { return nil }
        let kind = effectiveSiteEngine
        let name = SiteEngineWords.name(kind)
        let decision = engineDecision
        guard decision.kind == kind, let reason = decision.reason else { return name }
        return "\(name) · \(reason)"
    }

    /// A spare's page was built before the tab opened: it stands in for
    /// the new tab only when the rules (memory now included) pick its engine.
    func spareFits(_ url: URL?) -> Bool {
        guard let built = builtPage?.engine, engineFactory.kinds.contains(.chromium) else { return true }
        // The default now, not the one the spare was built under.
        let base: PageEngineKind = engineFactory.followsGlobalSelection
            ? PageEngineFactory.requestedEngine ?? .webKit : chromiumDRMEnabled ? .chromium : .webKit
        let decision = engineFactory.sites.decide(base, at: url)
        guard engineFactory.resolved(decision.kind) == built else { return false }
        chromiumDRMEnabled = base == .chromium
        // A spare's engine can be memory's choice now though it wasn't then.
        engineMemoryMoved = decision.source == .spared
        return true
    }

    /// Whether a new tab for `url` opens on another engine than this page's.
    func leavesEngine(for url: URL) -> Bool {
        guard let built = builtPage?.engine, engineFactory.kinds.contains(.chromium) else { return false }
        let base: PageEngineKind = chromiumDRMEnabled ? .chromium : .webKit
        return engineFactory.resolved(engineFactory.sites.decide(base, at: url).kind) != built
    }

    /// ⌘K's Open in: this tab only, no rule written. It holds until the tab
    /// closes, through navigations and sleep.
    func openHere(in kind: PageEngineKind) {
        guard offersSiteEngine, let target = address else { return }
        guard effectiveSiteEngine != kind else { engineHeld = kind; return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await EngineSwitchTransaction.execute([
                    .init(tab: self, engine: kind, request: URLRequest(url: target),
                          installing: { [weak self] in self?.engineHeld = kind })
                ])
            } catch { engineSwitchFailed(error, to: kind) }
        }
    }

    /// ⌘K's Always Open in: writes the site's row, then moves this tab.
    func alwaysOpen(in kind: PageEngineKind) {
        chooseSiteEngine(kind == .chromium ? .chromium : .webKit)
    }
}

@MainActor
extension Tab {
    /// ⌘K's engine rows for this tab: the other engine, and whether
    /// Always Open in has anything to write.
    var engineActionPlan: (other: PageEngineKind, always: Bool)? {
        guard offersSiteEngine else { return nil }
        let other: PageEngineKind = effectiveSiteEngine == .chromium ? .webKit : .chromium
        return (other, siteEngineChoice != (other == .chromium ? .chromium : .webKit))
    }

    var engineActionTitles: [String] {
        guard let plan = engineActionPlan else { return [] }
        let name = SiteEngineWords.name(plan.other)
        return ["Open in \(name)"] + (plan.always ? ["Always Open in \(name)"] : [])
    }
}

extension Browser {
    /// ⌘K's two rows on a tab: the first changes this tab, the second
    /// writes the site's row in General › Engines for Sites.
    func engineActions(for tab: Tab) -> [FieldAction] {
        guard let plan = tab.engineActionPlan else { return [] }
        let titles = tab.engineActionTitles
        var out = [FieldAction(id: "engine-here", title: titles[0], symbol: "square.2.layers.3d") { [weak self] in
            self?.editing = false
            tab.openHere(in: plan.other)
        }]
        if plan.always {
            out.append(FieldAction(id: "engine-always", title: titles[1], symbol: "square.2.layers.3d") { [weak self] in
                self?.editing = false
                tab.alwaysOpen(in: plan.other)
            })
        }
        return out
    }
}
