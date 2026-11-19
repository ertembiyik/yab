import AppKit
import Combine
import SQLite3
import WebKit

// Dark pages: when Yab is dark, a site with no dark look of its own is
// darkened by Dark Reader's engine built into Yab (docs/dark-pages.md).
//
// Yab decides what a site gets before the request leaves (`decide`, from
// Tab.arm), and the page only carries the answer out (dark-pages.js). A site
// that is dark of its own is left to itself and costs nothing after the
// first visit; a site turned off gets no script at all and the window's
// appearance, so in a dark window its own dark theme.

/// Settings › Appearance, Dark pages.
enum DarkMode: String, CaseIterable {
    /// While the window is dark: Theme Dark, or System on a dark Mac.
    case withTheme
    case always
    case off

    static let key = "pages.dark"

    var title: String {
        switch self {
        case .withTheme: return "With the theme"
        case .always: return "Always"
        case .off: return "Off"
        }
    }

    static func read(in store: UserDefaults = Store.settings) -> DarkMode {
        store.string(forKey: key).flatMap(DarkMode.init) ?? .off
    }
}

/// The sheet behind Customize…: Dark Reader's brightness, contrast and sepia
/// (Warmth), the ground, and pictures dimmed a little.
struct DarkLook: Codable, Equatable {
    enum Ground: String, Codable, CaseIterable {
        case gray, space, black

        var title: String {
            switch self {
            case .gray: return "Gray"
            case .space: return "Space"
            case .black: return "Black"
            }
        }
    }

    var brightness = 100
    var contrast = 100
    var warmth = 0
    var ground: Ground = .gray
    var dimPictures = false

    static let key = "pages.darkLook"
    static let brightnessRange = 60...140
    static let contrastRange = 60...140
    static let warmthRange = 0...60

    /// The ground Gray is, and the words on every ground.
    static let gray = "1c1c1c"
    static let text = "e8e6e3"

    static func read(in store: UserDefaults = Store.settings) -> DarkLook {
        guard let data = store.data(forKey: key), let look = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return look.clamped
    }

    var clamped: DarkLook {
        var look = self
        look.brightness = min(Self.brightnessRange.upperBound, max(Self.brightnessRange.lowerBound, brightness))
        look.contrast = min(Self.contrastRange.upperBound, max(Self.contrastRange.lowerBound, contrast))
        look.warmth = min(Self.warmthRange.upperBound, max(Self.warmthRange.lowerBound, warmth))
        return look
    }

    /// The ground as six hex digits: Space is the space's color with its
    /// hue and a little of its saturation, as dark as Gray.
    func groundHex(space: NSColor?) -> String {
        switch ground {
        case .gray: return Self.gray
        case .black: return "000000"
        case .space:
            guard let color = space?.usingColorSpace(.sRGB) else { return Self.gray }
            var hue: CGFloat = 0, saturation: CGFloat = 0, bright: CGFloat = 0, alpha: CGFloat = 0
            color.getHue(&hue, saturation: &saturation, brightness: &bright, alpha: &alpha)
            return NSColor(hue: hue, saturation: min(0.42, saturation), brightness: 0.16, alpha: 1).hex
        }
    }

    /// Dark Reader's theme, as `DarkReader.enable` takes it. Scrollbars and
    /// controls are left to WebKit, which draws them dark from the page's
    /// color-scheme.
    func theme(ground: String) -> [String: Any] {
        ["mode": 1, "brightness": brightness, "contrast": contrast, "sepia": warmth, "grayscale": 0,
         "darkSchemeBackgroundColor": "#" + ground.lowercased(), "darkSchemeTextColor": "#" + Self.text,
         "scrollbarColor": "", "selectionColor": "auto", "styleSystemControls": false]
    }

    /// The style from the first frame until the engine has its own, as
    /// Dark Reader's darkreader--fallback.
    static func fallback(ground: String) -> String {
        """
        html { color-scheme: dark !important; }
        html, body, body > :not(iframe) { background-color: #\(ground.lowercased()) !important; border-color: #4c4c4c !important; color: #\(text) !important; }
        """
    }

    /// Photos a little darker, never inverted: zero specificity, so the
    /// engine's inverted marks and a site's own filters stay as they are.
    var dimCSS: String {
        dimPictures ? ":where(img, picture, image, video:not(:fullscreen)) { filter: brightness(0.82) contrast(1.04); }" : ""
    }
}

/// What a site gets, from Tab.arm's decision for its host.
enum DarkDecision: String {
    /// Nothing at all: pages can't be dark here, or this is no page for it.
    case none
    /// Turned off by the person (`dark.<host>` = off): no engine, the window's appearance.
    case off
    /// The engine whatever was learned. No longer decided (#336), kept for the page script.
    case on
    /// The site is dark of its own: it is left alone.
    case own
    /// The site was seen to be light: the engine at once.
    case engine
    /// Nothing known: a look at the ground once the styles are in.
    case check

    /// Whether the dark scripts go into the list.
    var scripted: Bool { self != .none && self != .off }
}

/// What a site was found to be, and when: checked again after 14 days, or
/// sooner when its CSS grows a dark theme (`sign`).
struct DarkLearned: Equatable {
    var value: DarkDecision
    var at: Date
    /// The site's own CSS had prefers-color-scheme: dark rules when it was learned.
    var sign: Bool

    static let fresh: TimeInterval = 14 * 24 * 3600

    var plist: [String: Any] { ["v": value.rawValue, "at": at.timeIntervalSince1970, "sign": sign] }

    init(value: DarkDecision, at: Date, sign: Bool = false) {
        self.value = value
        self.at = at
        self.sign = sign
    }

    init?(_ plist: Any?) {
        guard let plist = plist as? [String: Any], let raw = plist["v"] as? String,
              let value = DarkDecision(rawValue: raw), value == .engine || value == .own,
              let at = plist["at"] as? Double else { return nil }
        self.init(value: value, at: Date(timeIntervalSince1970: at), sign: plist["sign"] as? Bool ?? false)
    }
}

/// How a tab's page is now, for Site Controls' row and the View menu.
enum DarkShown: Equatable {
    case none, engine, own, off, extensionDoes
}

@MainActor
enum DarkPages {
    /// The scripts' own world: the page sees neither the engine nor the bridge.
    static let world = WKContentWorld.world(name: "yab-dark")
    /// The same world through the page seam, for either engine.
    static let pageWorld = PageWorld.named("yab-dark")
    /// Dark Reader the extension, by its Web Store id.
    nonisolated static let extensionID = "eimadpbcbfnmbkopoojfekhnkhdbieeh"
    static let changed = Notification.Name("yab.dark-pages.changed")
    /// The Dark Reader release the engine and the lists came from.
    static let version: String = {
        guard let folder = DarkLists.folder(), let text = try? String(contentsOf: folder.appendingPathComponent("VERSION"), encoding: .utf8) else { return "?" }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }()

    static func choiceKey(_ host: String) -> String { "dark." + host }
    static func learnedKey(_ host: String) -> String { "darkLearned." + host }

    // MARK: the decision

    /// The first that answers wins: the mode and the window, a page that is
    /// not for it, the person's word, Dark Reader's list of dark sites, what
    /// was learned, and otherwise a look.
    nonisolated static func decide(mode: DarkMode, windowDark: Bool, eligible: Bool, choice: String?,
                                   darkSite: Bool, learned: DarkLearned?, now: Date = Date()) -> DarkDecision {
        switch mode {
        // Off is a mode, not a word over a site: a site turned on from ⌘E
        // while the window is dark is dark with it off.
        case .off where choice != "yes" || !windowDark: return .none
        case .withTheme where !windowDark: return .none
        default: break
        }
        guard eligible else { return .none }
        if choice == "off" { return .off }
        // "on" (kept from before #336) is no word over a site's own dark
        // theme: a site that has one uses it, as with no word at all.
        if darkSite { return .own }
        // A site learned to be light gets the engine at once. One learned
        // to be dark is still looked at each time: a host can have a dark
        // home and a light page under it, and a look costs one style read,
        // where trusting it left that page white (evals/dark-first-paint,
        // the bare page on a host whose other pages were dark).
        if let learned, learned.value == .engine, now.timeIntervalSince(learned.at) < DarkLearned.fresh, now >= learned.at {
            return .engine
        }
        return .check
    }

    /// A frame takes its tab's top site's decision: dark with the page round
    /// it, each frame looking at its own ground, so a dark player stays as
    /// it is and a white payment form is darkened.
    nonisolated static func frame(top: DarkDecision, darkSite: Bool) -> DarkDecision {
        switch top {
        case .engine, .on, .check: return darkSite ? .own : .check
        case .own: return .own
        case .none, .off: return .off
        }
    }

    /// Whether a learned decision should be looked at again: the engine
    /// found the site's own CSS speaking of a dark scheme it hadn't when
    /// it was learned.
    nonisolated static func relearns(_ learned: DarkLearned?, sign: Bool) -> Bool {
        guard let learned, learned.value == .engine else { return false }
        return sign && !learned.sign
    }

    /// The appearance a page is drawn in, nil for the window's. The engine
    /// is all a site's word turns off: a site kept off gets the window's
    /// prefers-color-scheme, so in a dark window its own dark theme (#336).
    /// A site darkened in a light window (Always) is drawn dark, so a site
    /// with a dark theme of its own uses it.
    nonisolated static func appearance(_ decision: DarkDecision, windowDark: Bool) -> NSAppearance.Name? {
        switch decision {
        case .on, .engine, .check, .own: return windowDark ? nil : .darkAqua
        case .off, .none: return nil
        }
    }

    /// Pages can be dark here: the window is dark, or the mode is Always. With
    /// the mode Off a dark window still has the site's own switch (⌘E, ⌥⇧D).
    static func active(windowDark: Bool, mode: DarkMode = DarkMode.read()) -> Bool {
        mode == .always || windowDark
    }

    /// The window is dark: the app's theme is, or the space in front wears
    /// Dark (Look, kept where `Preferences.lookMode` keeps it). Dark wins, so
    /// a Light theme with a Dark space has dark sites, and a Dark theme with
    /// a Light space keeps them.
    static var windowDark: Bool {
        windowDark(lookMode: prefs?.lookMode ?? Store.settings.string(forKey: "backdrop.mode") ?? "")
    }

    static func windowDark(lookMode: String) -> Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            || lookMode == LookMode.dark.rawValue
    }

    /// A background tab belongs to its own space, not the last window or
    /// space that wrote backdrop.mode (#1606).
    static func windowDark(for tab: Tab) -> Bool {
        guard let browser = tab.delegate as? Browser else { return windowDark }
        let mode: String
        if let parked = browser.parked.first(where: { $0.value.tabs.contains { $0 === tab } }),
           let space = browser.spaces.first(where: { $0.id == parked.key }) {
            mode = space.paint?.mode ?? browser.prefs.lookMode
        } else {
            mode = browser.prefs.lookMode
        }
        return windowDark(lookMode: mode)
    }

    /// Every tab decides in its own window and space. One global dark bit
    /// cannot tell whether a second space's appearance changed.
    static func appearanceChanged() {
        refresh()
    }

    /// Dark Reader the extension is on: Yab's own stays off, so a page is
    /// never darkened twice.
    static var extensionOn: Bool {
        guard #available(macOS 15.4, *) else { return false }
        return Extensions.shared.installed.contains { $0.id == extensionID && $0.enabled }
    }

    /// Dark Reader on for this tab's engine: WebKit's extensions, or the
    /// extensions of the tab's own Chromium profile (ChromiumPage+Dark).
    @MainActor static func extensionOn(for tab: Tab) -> Bool {
        if let chromium = tab.builtPage as? ChromiumPage { return chromium.darkReaderOn }
        return extensionOn
    }

    /// Not a page for it: an agent's tab, a hidden Yab, Yab's own pages,
    /// anything but a website.
    static func eligible(_ tab: Tab, url: URL?) -> Bool {
        guard !tab.bench, !Headless.on, !extensionOn(for: tab) else { return false }
        guard let scheme = (url ?? tab.address)?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    static func choice(_ host: String?, in store: UserDefaults = Store.settings) -> String? {
        guard let host, !host.isEmpty else { return nil }
        return store.string(forKey: choiceKey(host))
    }

    static func learned(_ host: String?, in store: UserDefaults = Store.settings) -> DarkLearned? {
        guard let host, !host.isEmpty else { return nil }
        return DarkLearned(store.object(forKey: learnedKey(host)))
    }

    static func decision(for tab: Tab, url: URL?, host: String?) -> DarkDecision {
        let mode = DarkMode.read()
        let dark = windowDark(for: tab)
        guard active(windowDark: dark, mode: mode) else { return .none }
        let host = host ?? PageScripts.host(of: url ?? tab.address)
        return decide(mode: mode, windowDark: dark, eligible: eligible(tab, url: url), choice: choice(host),
                      darkSite: DarkLists.shared.isDark(url ?? tab.address), learned: learned(host))
    }

    /// What the page found, kept for the site: never from a private tab.
    static func learn(_ host: String, _ value: DarkDecision, sign: Bool, shy: Bool, now: Date = Date()) {
        guard !shy, !host.isEmpty, value == .engine || value == .own else { return }
        Store.settings.set(DarkLearned(value: value, at: now, sign: sign).plist, forKey: learnedKey(host))
    }

    static func forget(_ host: String) {
        Store.settings.removeObject(forKey: learnedKey(host))
    }

    /// The sites turned off, for the sheet's Turned off.
    static func keptLight(in store: UserDefaults = Store.settings) -> [String] {
        store.dictionaryRepresentation().compactMap { key, value in
            guard key.hasPrefix("dark."), value as? String == "off" else { return nil }
            return String(key.dropFirst(5))
        }.sorted()
    }

    /// The person's word for a site, from ⌥⇧D, Site Controls, ⌘T or the
    /// View menu: Yab's dark off, or back. Back drops the word, so a site
    /// with a dark theme of its own uses it and the rest get the engine.
    /// With the mode Off the word is "yes" for a site turned on, and dropped
    /// when it is turned off again, so Off stays Off for every other site.
    static func toggle(_ host: String, darkNow: Bool, mode: DarkMode = DarkMode.read()) {
        let key = choiceKey(host)
        switch (darkNow, mode) {
        case (true, .off): Store.settings.removeObject(forKey: key)
        case (true, _): Store.settings.set("off", forKey: key)
        case (false, .off): Store.settings.set("yes", forKey: key)
        case (false, _): Store.settings.removeObject(forKey: key)
        }
        NotificationCenter.default.post(name: changed, object: host)
    }

    static func keepLight(_ host: String, _ light: Bool) {
        if light { Store.settings.set("off", forKey: choiceKey(host)) } else { Store.settings.removeObject(forKey: choiceKey(host)) }
        NotificationCenter.default.post(name: changed, object: host)
    }

    // MARK: the look

    /// The ground's color for this window: the space's, when that is chosen.
    static func groundHex(_ look: DarkLook = DarkLook.read()) -> String {
        var space: NSColor?
        if look.ground == .space, let prefs { space = SpacePaint(prefs).color(dark: true) }
        return look.groundHex(space: space)
    }

    /// The window in front's preferences, for its space's color.
    static var prefs: Preferences? {
        (BrowserWindows.shared.browser(for: NSApp.keyWindow) ?? BrowserWindows.shared.browsers.first)?.prefs
    }

    static func groundColor(_ look: DarkLook = DarkLook.read()) -> NSColor {
        NSColor(hex: groundHex(look)) ?? NSColor(white: 0.11, alpha: 1)
    }

    static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: the scripts

    /// The engine, as a function in the yab-dark world that only a page
    /// needing it calls: every frame gets it, but parses it lazily, and an
    /// own or kept-light site never runs it.
    static let engine = WKUserScript(source: "window.__yabDarkEngine = function () {\n" + PageScript.load("darkreader") + "\n};",
                                     injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world)
    /// The engine's stylesheet proxy, in the page's own world (darkreader-proxy.js).
    static let proxy = WKUserScript(source: PageScript.load("darkreader-proxy"), injectionTime: .atDocumentStart,
                                    forMainFrameOnly: false, in: .page)
    static let ownSites = json(DarkLists.ownDarkSites.split(whereSeparator: \.isNewline).map(String.init))

    /// The start script, one object for each look: its fallback and theme
    /// are in its text, so the first frame is already the right dark.
    static func startScript(_ look: DarkLook, ground: String) -> WKUserScript {
        let theme = json(look.theme(ground: ground))
        let fallback = json(DarkLook.fallback(ground: ground))
        let dim = json(look.dimCSS)
        // A test run's A/B of the engine at the document's start or once it
        // is parsed (evals/dark-pages); always at the start otherwise.
        let deferred = Store.testing && Store.settings.bool(forKey: "pages.dark.defer") ? "true" : "false"
        return PageScripts.made("dark", theme + fallback + dim + deferred) {
            WKUserScript(source: PageScript.load("dark-pages", vars: ["THEME": theme, "FALLBACK": fallback, "DIM": dim, "DEFER": deferred, "OWN_SITES": ownSites]),
                         injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world)
        }
    }

    /// The three, for a decision that has them: the same objects for every
    /// site, so a tab going between sites sends nothing new (PageScripts.fit).
    static func scripts(for decision: DarkDecision) -> [WKUserScript] {
        guard decision.scripted, !LinkGap.cut("dark") else { return [] }
        return [proxy, engine, startScript(DarkLook.read(), ground: groundHex())]
    }

    /// What a frame is told when it asks: off the main thread, since the
    /// first one waits for the fixes to be read.
    nonisolated static func answer(top: DarkDecision, url: URL?, isMain: Bool) -> [String: Any] {
        let decision = isMain ? top : frame(top: top, darkSite: DarkLists.shared.isDark(url))
        var out: [String: Any] = ["decision": decision.rawValue]
        if decision == .engine || decision == .on || decision == .check, let url {
            out["fixes"] = DarkLists.shared.fixes(for: url).json
        }
        return out
    }

    /// Every open tab once a setting changed: the mode, the look, the
    /// window's appearance, a site's word.
    static func refresh(host: String? = nil) {
        for tab in Tab.every where host == nil || PageScripts.host(of: tab.address) == host {
            tab.darkRefresh()
        }
    }

    /// The sheet's controls, to every darkened page, a frame at most apart.
    static func lookChanged() {
        pendingLook?.cancel()
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                let look = DarkLook.read(), ground = groundHex(look)
                let call = "window.__yabDark && window.__yabDark.look(\(json(look.theme(ground: ground))), \(json(DarkLook.fallback(ground: ground))), \(json(look.dimCSS)))"
                for tab in Tab.every { tab.darkEvaluate(call) }
                NotificationCenter.default.post(name: changed, object: nil)
            }
        }
        pendingLook = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60, execute: work)
    }
    private static var pendingLook: DispatchWorkItem?

    /// Watches the window's appearance and the extensions, which change
    /// what every tab gets.
    static func start() {
        guard watching == nil else { return }
        watching = NSApp.observe(\.effectiveAppearance, options: [.new]) { _, _ in
            MainActor.assumeIsolated { DarkPages.appearanceChanged() }
        }
        if active(windowDark: windowDark) { DarkLists.shared.warm() }
        // Dark Reader the extension turned on or off: Yab's own stands
        // aside, or comes back.
        if #available(macOS 15.4, *) {
            extensionWatch = Extensions.shared.observed(\.installed)
                .map { list in list.contains { $0.id == DarkPages.extensionID && $0.enabled } }
                .removeDuplicates()
                .dropFirst()
                .sink { _ in DispatchQueue.main.async { MainActor.assumeIsolated { DarkPages.refresh() } } }
        }
    }
    private static var watching: NSKeyValueObservation?
    private static var extensionWatch: AnyCancellable?

    // MARK: Switch to Yab's

    /// Dark Reader the extension's sites and theme brought over, and the
    /// extension turned off. Its storage is read where WebKit keeps it; what
    /// can't be read leaves Yab's own as it is.
    @discardableResult
    static func takeOverFromExtension() -> Int {
        var moved = 0
        if let kept = DarkReaderStorage.read() {
            for host in kept.lightSites { Store.settings.set("off", forKey: choiceKey(host)); moved += 1 }
            if let look = kept.look {
                if let prefs { prefs.darkLook = look } else if let data = try? JSONEncoder().encode(look) { Store.settings.set(data, forKey: DarkLook.key) }
            }
        }
        if #available(macOS 15.4, *) { Extensions.shared.setEnabled(extensionID, false) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { refresh() }
        return moved
    }
}

// MARK: - Dark Reader's lists

/// One of Dark Reader's URL patterns: `github.com`, `*.abc.net.au`,
/// `github.*.*`, `docs.rs/crate`, `^exact.org$`. Its host matches with any
/// subdomain in front unless it starts with ^, `*` stands for one label, and
/// its path is a prefix unless it ends with $.
struct DarkPattern: Equatable {
    let raw: String
    let labels: [String]
    let path: String?
    let exactStart: Bool
    let exactEnd: Bool

    init?(_ text: String) {
        var t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        raw = t
        exactStart = t.hasPrefix("^")
        exactEnd = t.hasSuffix("$")
        if exactStart { t.removeFirst() }
        if exactEnd { t.removeLast() }
        if let scheme = t.range(of: "://") { t = String(t[scheme.upperBound...]) }
        if let query = t.firstIndex(of: "?") { t = String(t[..<query]) }
        while t.hasSuffix("/") { t.removeLast() }
        let host: Substring
        if let slash = t.firstIndex(of: "/") {
            host = t[..<slash]
            path = String(t[slash...])
        } else {
            host = Substring(t)
            path = nil
        }
        let parts = host.lowercased().split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, !parts.contains(where: \.isEmpty) else { return nil }
        labels = parts
    }

    /// The label a URL's host must have for this to match: the first one
    /// that isn't `*`, or nil for `*` alone.
    var indexLabel: String? { labels.first { $0 != "*" } }

    func matches(host: String, path urlPath: String) -> Bool {
        if labels == ["*"] { return true }
        let parts = host.lowercased().split(separator: ".").map(String.init)
        guard exactStart ? parts.count == labels.count : parts.count >= labels.count else { return false }
        for (have, want) in zip(parts.suffix(labels.count), labels) where want != "*" && have != want { return false }
        let p = urlPath.isEmpty ? "/" : urlPath
        guard let path else { return !exactEnd || p == "/" }
        let wanted = path.lowercased(), given = p.lowercased()
        if exactEnd { return given == wanted || given == wanted + "/" }
        return given == wanted || given.hasPrefix(wanted.hasSuffix("/") ? wanted : wanted + "/") || given.hasPrefix(wanted)
    }
}

/// A site's fixes from dynamic-theme-fixes.config, as `DarkReader.enable`
/// takes them.
struct DarkFix: Equatable {
    var urls: [DarkPattern] = []
    var invert: [String] = []
    var css = ""
    var ignoreInlineStyle: [String] = []
    var ignoreImageAnalysis: [String] = []
    var ignoreCSSUrl: [String] = []

    var json: [String: Any] {
        ["invert": invert, "css": css, "ignoreInlineStyle": ignoreInlineStyle,
         "ignoreImageAnalysis": ignoreImageAnalysis, "ignoreCSSUrl": ignoreCSSUrl]
    }

    /// Dark Reader's getDynamicThemeFixesFor: the common `*` block, with the
    /// most specific site block that matches put after it.
    func merged(with site: DarkFix?) -> DarkFix {
        guard let site else { return self }
        var out = DarkFix(urls: site.urls)
        out.invert = invert + site.invert
        out.css = [css, site.css].filter { !$0.isEmpty }.joined(separator: "\n")
        out.ignoreInlineStyle = ignoreInlineStyle + site.ignoreInlineStyle
        out.ignoreImageAnalysis = ignoreImageAnalysis + site.ignoreImageAnalysis
        out.ignoreCSSUrl = ignoreCSSUrl + site.ignoreCSSUrl
        return out
    }

    /// These fixes with `more`'s put after them, keeping these URLs.
    func adding(_ more: DarkFix) -> DarkFix {
        var out = merged(with: more)
        out.urls = urls
        return out
    }

    static let commands = ["INVERT", "CSS", "IGNORE INLINE STYLE", "IGNORE IMAGE ANALYSIS", "IGNORE CSS URL"]

    /// The config's blocks, split by lines of `=`: their URLs, then each
    /// command and the lines under it.
    static func parse(_ text: String) -> [DarkFix] {
        var fixes: [DarkFix] = []
        var block: [Substring] = []
        func flush() {
            defer { block.removeAll(keepingCapacity: true) }
            var fix = DarkFix()
            var command: String?
            var lines: [Substring] = []
            func close() {
                guard let command else { return }
                let values = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                switch command {
                case "INVERT": fix.invert += values
                case "CSS": fix.css = lines.map(String.init).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                case "IGNORE INLINE STYLE": fix.ignoreInlineStyle += values
                case "IGNORE IMAGE ANALYSIS": fix.ignoreImageAnalysis += values
                case "IGNORE CSS URL": fix.ignoreCSSUrl += values
                default: break
                }
                lines.removeAll()
            }
            for line in block {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if commands.contains(trimmed) {
                    close()
                    command = trimmed
                } else if command == nil {
                    if let pattern = DarkPattern(trimmed) { fix.urls.append(pattern) }
                } else {
                    lines.append(line)
                }
            }
            close()
            if !fix.urls.isEmpty { fixes.append(fix) }
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = line.hasSuffix("\r") ? line.dropLast() : line
            if line.count >= 2, line.allSatisfy({ $0 == "=" }) { flush() } else { block.append(line) }
        }
        flush()
        return fixes
    }
}

/// An index of patterns by the label a host must have, so a URL is matched
/// against the few that could match it, not all three thousand.
struct DarkIndex<Item> {
    private(set) var everywhere: [Item] = []
    private(set) var byLabel: [String: [Item]] = [:]

    mutating func add(_ item: Item, _ pattern: DarkPattern) {
        if let label = pattern.indexLabel { byLabel[label, default: []].append(item) } else { everywhere.append(item) }
    }

    func candidates(_ host: String) -> [Item] {
        var out = everywhere
        var seen = Set<String>()
        for label in host.lowercased().split(separator: ".").map(String.init) where seen.insert(label).inserted {
            out += byLabel[label] ?? []
        }
        return out
    }
}

/// Dark Reader's site lists. The list of dark sites, 20 KB, is read the
/// first time a tab arms; the fixes, 800 KB, on a queue of their own as
/// pages can first be dark, and the first answer that needs them waits
/// there, never on the main thread.
final class DarkLists: @unchecked Sendable {
    static let shared = DarkLists()

    struct Fixes {
        var common = DarkFix()
        var index = DarkIndex<Int>()
        var all: [DarkFix] = []
        var own: [DarkFix] = []
        var ownIndex = DarkIndex<Int>()
    }

    private let lock = NSLock()
    private var fixesParsed: Fixes?
    private var darkParsed: DarkIndex<DarkPattern>?
    private var cache: [String: DarkFix] = [:]
    private let queue = DispatchQueue(label: "yab.dark-lists", qos: .userInitiated)

    static func folder() -> URL? {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let app = Bundle.main.bundleURL.pathExtension == "app"
        let places = [Bundle.main.resourceURL?.appendingPathComponent("DarkReader"), app ? nil : repo.appendingPathComponent("Resources/DarkReader")]
        return places.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("dark-sites.config").path) }
    }

    static func read(_ name: String) -> String? {
        guard let folder = folder(), let text = try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8) else {
            NSLog("yab: dark pages: Dark Reader's %@ is missing", name)
            return nil
        }
        return text
    }

    /// `own`: Yab's own fixes (yab-fixes.config, the same format), kept
    /// apart so a Dark Reader update never drops them. They add to Dark
    /// Reader's: its `*` block to the common one, and every site block that
    /// matches to the one Dark Reader's lists pick (`fixes(for:)`).
    static func parseFixes(_ text: String, own: String = "") -> Fixes {
        var out = Fixes()
        for (i, fix) in DarkFix.parse(text).enumerated() {
            if i == 0, fix.urls.first?.raw == "*" { out.common = fix; continue }
            out.all.append(fix)
            for pattern in fix.urls { out.index.add(out.all.count - 1, pattern) }
        }
        for fix in DarkFix.parse(own) {
            if fix.urls.first?.raw == "*" {
                out.common = out.common.adding(fix)
                continue
            }
            out.own.append(fix)
            for pattern in fix.urls { out.ownIndex.add(out.own.count - 1, pattern) }
        }
        return out
    }

    /// Sites with a dark theme of their own that Yab always leaves alone,
    /// kept apart so an update never drops them. ChatGPT sets its theme by
    /// script after the load, so the look came too early (#743); its
    /// sandboxed answers (oaiusercontent.com) and its old chat.openai.com
    /// origin get the same rule, even without the vendored list.
    static let ownDarkSites = "chatgpt.com\nchat.openai.com\noaiusercontent.com"
    private static let ownDarkIndex = parseDark(ownDarkSites)

    static func parseDark(_ text: String) -> DarkIndex<DarkPattern> {
        var out = DarkIndex<DarkPattern>()
        for line in text.split(whereSeparator: \.isNewline) {
            if let pattern = DarkPattern(String(line)) { out.add(pattern, pattern) }
        }
        return out
    }

    /// Starts reading the fixes in the background.
    func warm() { queue.async { [self] in _ = fixesNow() } }

    /// For tests: lists given rather than read.
    func use(fixes: String, dark: String, own: String = "") {
        let parsedFixes = Self.parseFixes(fixes, own: own), parsedDark = Self.parseDark(dark)
        lock.lock(); fixesParsed = parsedFixes; darkParsed = parsedDark; cache = [:]; lock.unlock()
    }

    private func fixesNow() -> Fixes {
        lock.lock()
        if let fixesParsed { lock.unlock(); return fixesParsed }
        lock.unlock()
        let own = Self.folder().flatMap { try? String(contentsOf: $0.appendingPathComponent("yab-fixes.config"), encoding: .utf8) } ?? ""
        let fresh = Self.read("dynamic-theme-fixes.config").map { Self.parseFixes($0, own: own) } ?? Fixes()
        lock.lock()
        if fixesParsed == nil { fixesParsed = fresh }
        let out = fixesParsed!
        lock.unlock()
        return out
    }

    private func darkNow() -> DarkIndex<DarkPattern> {
        lock.lock()
        if let darkParsed { lock.unlock(); return darkParsed }
        lock.unlock()
        let fresh = Self.read("dark-sites.config").map(Self.parseDark) ?? DarkIndex()
        lock.lock()
        if darkParsed == nil { darkParsed = fresh }
        let out = darkParsed!
        lock.unlock()
        return out
    }

    func isDark(_ url: URL?) -> Bool {
        guard let url, let host = url.host() else { return false }
        return isDark(host: host, path: url.path())
    }

    func isDark(host: String, path: String = "/") -> Bool {
        Self.ownDarkIndex.candidates(host).contains { $0.matches(host: host, path: path) }
            || darkNow().candidates(host).contains { $0.matches(host: host, path: path) }
    }

    /// The fixes for a page: the common block with its site's, the site
    /// block whose first pattern is longest winning, as in Dark Reader.
    /// Off the main thread: the first call waits for the parse.
    func fixes(for url: URL) -> DarkFix {
        let host = url.host()?.lowercased() ?? ""
        let path = url.path()
        let key = host + path
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        lock.unlock()
        let lists = fixesNow()
        let site = lists.index.candidates(host)
            .map { lists.all[$0] }
            .filter { fix in fix.urls.contains { $0.matches(host: host, path: path) } }
            .max { ($0.urls.first?.raw.count ?? 0) < ($1.urls.first?.raw.count ?? 0) }
        var out = lists.common.merged(with: site)
        for i in Set(lists.ownIndex.candidates(host)).sorted()
        where lists.own[i].urls.contains(where: { $0.matches(host: host, path: path) }) {
            out = out.adding(lists.own[i])
        }
        lock.lock()
        if cache.count > 256 { cache = [:] }
        cache[key] = out
        lock.unlock()
        return out
    }

    /// How many site blocks there are, for the bench.
    var counts: (fixes: Int, dark: Int) {
        let fixes = fixesNow(), dark = darkNow()
        return (fixes.all.count, dark.byLabel.values.reduce(dark.everywhere.count) { $0 + $1.count })
    }
}


// MARK: - the bridge

/// Stylesheets and images the engine can't read itself, fetched here: http
/// and https only, never with cookies, 2 MB and 10 seconds at most, and a
/// local address only for a page that is itself on the local network
/// (docs/local-network.md). Registered in the yab-dark world alone, so a
/// page's own script can't reach it.
enum DarkFetch {
    static let limit = 2 << 20
    static let timeout: TimeInterval = 10

    enum Refusal: Error, Equatable { case scheme, local, size, status, kind }

    /// Whether `url` may be fetched for a page at `page`.
    nonisolated static func allowed(_ url: URL, from page: URL?) -> Refusal? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", let host = url.host() else { return .scheme }
        if LocalNetwork.space(of: host) != .public {
            guard let pageHost = page?.host(), LocalNetwork.space(of: pageHost) != .public else { return .local }
        }
        return nil
    }

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.urlCache = URLCache(memoryCapacity: 16 << 20, diskCapacity: 0)
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.httpAdditionalHeaders = ["User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Safari/605.1.15"]
        return URLSession(configuration: configuration)
    }()

    @MainActor static func fetch(_ body: [String: Any], page: URL?, reply: @escaping @MainActor (Any?, String?) -> Void) {
        guard let text = body["url"] as? String, let url = URL(string: text) else { return reply(nil, "No address") }
        if let refused = allowed(url, from: page) { return reply(nil, "Refused: \(refused)") }
        let type = body["type"] as? String ?? "text"
        let mime = body["mime"] as? String ?? ""
        var request = URLRequest(url: url, timeoutInterval: timeout)
        if let origin = body["origin"] as? String, !origin.isEmpty, origin != "null" { request.setValue(origin + "/", forHTTPHeaderField: "Referer") }
        let task = session.dataTask(with: request) { data, response, error in
            let http = response as? HTTPURLResponse
            var value: String?, why: String?
            if let error { why = error.localizedDescription }
            else if let http, !(200..<300).contains(http.statusCode) { why = "Status \(http.statusCode)" }
            else if let data, data.count <= limit {
                let kind = (http?.value(forHTTPHeaderField: "Content-Type") ?? "").split(separator: ";").first
                    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
                if mime == "text/css", !kind.isEmpty, !kind.hasPrefix("text/") {
                    why = "Not CSS: \(kind)"
                } else if type == "data-url" {
                    value = "data:\(kind.isEmpty ? "application/octet-stream" : kind);base64," + data.base64EncodedString()
                } else {
                    value = String(decoding: data, as: UTF8.self)
                }
            } else { why = "Too large" }
            let answer = value, refusal = why
            DispatchQueue.main.async {
                MainActor.assumeIsolated { reply(answer, answer == nil ? (refusal ?? "Failed") : nil) }
            }
        }
        task.resume()
    }
}

/// The page's side, asking and telling, in the yab-dark world.
final class DarkRelay: NSObject, PageScriptReplying {
    static let name = "yabDark"
    weak var tab: Tab?

    func receive(_ message: PageScriptMessage, reply replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        MainActor.assumeIsolated {
            guard let body = message.body as? [String: Any], let kind = body["kind"] as? String, let tab else {
                return replyHandler(nil, "Not a request")
            }
            switch kind {
            case "ask":
                let url = (body["url"] as? String).flatMap(URL.init(string:)) ?? message.frame.url
                tab.darkAsked(message.frame, url: url, reply: replyHandler)
            case "fetch":
                // The page a fetch is for is the engine's word, never the body's.
                let page = message.frame.url ?? tab.address
                DarkFetch.fetch(body, page: page, reply: replyHandler)
            case "done":
                tab.darkDone(message.frame, body)
                replyHandler(true, nil)
            default:
                replyHandler(nil, "Unknown")
            }
        }
    }
}

/// What Dark Reader the extension kept: the sites it was turned off on, and
/// its theme, from the storage WebKit keeps for it: `SyncStorage.db` and
/// `LocalStorage.db` in its folder under ~/Library/WebKit/<app>/WebExtensions,
/// a table `extension_storage` of keys and JSON values.
enum DarkReaderStorage {
    struct Kept: Equatable {
        var lightSites: [String] = []
        var look: DarkLook?
    }

    static func folders() -> [URL] {
        guard let app = Bundle.main.bundleIdentifier else { return [] }
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/WebKit/\(app)/WebExtensions")
        let profiles = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
        return profiles.map { $0.appendingPathComponent(DarkPages.extensionID) }
    }

    static func read() -> Kept? {
        var values: [String: Any] = [:]
        for folder in folders() {
            for name in ["LocalStorage.db", "SyncStorage.db"] {
                let file = folder.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: file.path),
                      let db = SQLiteConnection(path: file.path, flags: SQLITE_OPEN_READONLY, busyTimeout: 500, name: "dark reader storage") else { continue }
                for row in db.query("SELECT key, value FROM extension_storage") {
                    guard let key = row.string(0), let text = row.string(1), let data = text.data(using: .utf8),
                          let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { continue }
                    values[key] = value
                }
            }
        }
        return values.isEmpty ? nil : parse(values)
    }

    /// Dark Reader's settings as its storage holds them (scheme 2): on
    /// everywhere but `disabledFor`, and `theme` once changed.
    nonisolated static func parse(_ values: [String: Any]) -> Kept {
        var kept = Kept()
        let byDefault = values["enabledByDefault"] as? Bool ?? true
        if byDefault {
            let listed = (values["disabledFor"] as? [String]) ?? (values["siteList"] as? [String]) ?? []
            kept.lightSites = Array(Set(listed.compactMap(host(of:)))).sorted()
        }
        if let theme = values["theme"] as? [String: Any] {
            var look = DarkLook()
            if let value = theme["brightness"] as? Int { look.brightness = value }
            if let value = theme["contrast"] as? Int { look.contrast = value }
            if let value = theme["sepia"] as? Int { look.warmth = value }
            if let ground = (theme["darkSchemeBackgroundColor"] as? String)?.lowercased() {
                look.ground = ground == "#000000" || ground == "#000" ? .black : .gray
            }
            kept.look = look.clamped
        }
        return kept
    }

    /// A site of Dark Reader's list as Yab keys it: `*.example.com/path` is
    /// example.com, lower case, without "www.".
    nonisolated static func host(of pattern: String) -> String? {
        var t = pattern.trimmingCharacters(in: .whitespaces).lowercased()
        if let scheme = t.range(of: "://") { t = String(t[scheme.upperBound...]) }
        t = String(t.prefix { $0 != "/" && $0 != "?" && $0 != ":" })
        while t.hasPrefix("*.") { t.removeFirst(2) }
        if t.hasPrefix("www.") { t.removeFirst(4) }
        guard !t.isEmpty, !t.contains("*"), t.contains(".") else { return nil }
        return t
    }
}
