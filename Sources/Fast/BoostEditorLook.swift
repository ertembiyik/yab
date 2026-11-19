import AppKit
import Foundation
import WebKit

/// The hand-edited look belongs to one exact host in one sign-in profile.
/// It is separate from agent trials, whose Keep/Undo contract still applies.
struct BoostEditorLook: Codable, Equatable {
    var enabled = true
    var hue = 205.0
    var amount = 0.0
    var mode = ""
    var font = 0
    var size = 1.0
    var spacing = 1.0
    var photos = 1.0
    /// 0 as the site has it, 1 lowercase, 2 uppercase (the ⋯ menu's Text Case).
    var textCase = 0
    var css = ""
    var hidden: [Veil] = []

    init() {}

    /// A saved look from before Text Case has none: it reads as the site's own.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        hue = try c.decodeIfPresent(Double.self, forKey: .hue) ?? 205
        amount = try c.decodeIfPresent(Double.self, forKey: .amount) ?? 0
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? ""
        font = try c.decodeIfPresent(Int.self, forKey: .font) ?? 0
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? 1
        spacing = try c.decodeIfPresent(Double.self, forKey: .spacing) ?? 1
        photos = try c.decodeIfPresent(Double.self, forKey: .photos) ?? 1
        textCase = try c.decodeIfPresent(Int.self, forKey: .textCase) ?? 0
        css = try c.decodeIfPresent(String.self, forKey: .css) ?? ""
        hidden = try c.decodeIfPresent([Veil].self, forKey: .hidden) ?? []
        normalize()
    }

    /// Keep older or hand-edited saves inside the controls' supported range.
    mutating func normalize() {
        hue = hue.isFinite ? min(360, max(0, hue)) : 205
        amount = amount.isFinite ? min(1, max(0, amount)) : 0
        size = size.isFinite ? min(1.6, max(0.85, size)) : 1
        spacing = spacing.isFinite ? min(2.5, max(0.5, spacing)) : 1
        photos = photos.isFinite ? min(1.5, max(0, photos)) : 1
        font = min(7, max(0, font))
        textCase = min(2, max(0, textCase))
        if !["", "light", "dark"].contains(mode) { mode = "" }
    }

    var changed: Bool {
        amount != 0 || !mode.isEmpty || font != 0 || textCase != 0 || size != 1 || spacing != 1 || photos != 1 || !css.isEmpty || !hidden.isEmpty
    }

    static func host(_ url: URL?) -> String? {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        return host
    }

    /// Incomplete typing keeps the last working stylesheet, including braces
    /// in strings/comments and escaped quotes. The browser parses declarations.
    static func completeCSS(_ css: String) -> Bool {
        var stack: [Character] = [], quote: Character?, comment = false, escape = false
        let chars = Array(css)
        var i = 0
        while i < chars.count {
            let c = chars[i], next = i + 1 < chars.count ? chars[i + 1] : nil
            if comment {
                if c == "*", next == "/" { comment = false; i += 1 }
            } else if escape { escape = false
            } else if c == "\\" { escape = true
            } else if let held = quote {
                if c == held { quote = nil }
            } else if c == "/", next == "*" { comment = true; i += 1
            } else if c == "\"" || c == "'" { quote = c
            } else if c == "{" || c == "(" || c == "[" { stack.append(c)
            } else if c == "}" || c == ")" || c == "]" {
                let pair: Character = c == "}" ? "{" : c == ")" ? "(" : "["
                guard stack.popLast() == pair else { return false }
            }
            i += 1
        }
        return stack.isEmpty && quote == nil && !comment && !escape
    }

    var payload: [String: Any] {
        ["enabled": enabled, "hue": hue, "amount": amount, "mode": mode, "font": font,
         "textCase": textCase, "size": size, "spacing": spacing, "photos": photos, "css": css,
         "hidden": hidden.map { ["selector": $0.selector, "label": $0.label] }]
    }
}

@MainActor
@Observable final class BoostEditorLooks {
    static let shared = BoostEditorLooks()
    private(set) var looks: [String: [String: BoostEditorLook]] = [:]
    private let file: URL
    @ObservationIgnored private var saving: DispatchWorkItem?
    private(set) var problem: String?

    init(file: URL = Store.file("site-looks.json")) {
        self.file = file
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([String: [String: BoostEditorLook]].self, from: data) { looks = saved }
    }

    func look(host: String, profile: UUID?) -> BoostEditorLook {
        looks[AddonProfiles.key(profile)]?[host] ?? BoostEditorLook()
    }

    func set(_ look: BoostEditorLook, host: String, profile: UUID?) {
        var look = look
        look.normalize()
        let previous = self.look(host: host, profile: profile)
        let key = AddonProfiles.key(profile)
        if look.changed { looks[key, default: [:]][host] = look }
        else { looks[key]?[host] = nil }
        if self === Self.shared,
           previous.hidden != look.hidden || previous.enabled != look.enabled || previous.changed != look.changed {
            // A hidden rule must reach other tabs before their next load.
            // Continuous color/font edits keep the editor's existing
            // rearming cadence, rather than installing per slider pixel.
            for browser in BrowserWindows.shared.browsers {
                let open = browser.everyTab + browser.outside + [browser.peeking].compactMap { $0 }
                for tab in open where !tab.shy && AddonProfiles.of(tab) == profile {
                    (tab.builtPage as? ChromiumPage)?.refreshFeatureScripts()
                }
            }
        }
        saving?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.flush() } }
        saving = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func flush() {
        saving?.cancel(); saving = nil
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(looks).write(to: file, options: .atomic)
            problem = nil
        } catch { problem = "Could not save this site's look: \(error.localizedDescription)" }
    }

    func script(for tab: Tab, host: String?) -> WKUserScript? {
        guard !tab.shy, let host else { return nil }
        let saved = look(host: host, profile: AddonProfiles.of(tab))
        guard saved.changed, saved.enabled else { return nil }
        // The frozen script also checks location: a redirect must not wear
        // the previous site's colors, CSS or hidden selectors.
        let source = "if (\(PageScripts.documentHost) === \(BoostScript.json(PageScripts.scriptHost(host)))) {\n"
            + BoostEditorScript.source + "\nwindow.__yabEditor.apply(\(BoostScript.json(saved.payload)), 'direct');\n}"
        return PageScripts.made("site-look", source) { WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Web.world) }
    }

    /// CDP registrations survive Back/Forward, redirects and renderer-led
    /// navigation. Carry this sign-in's exact-host looks, and let each new
    /// document choose its own. A normalized Curtain key cannot enter here.
    func chromiumSource(for tab: Tab) -> String? {
        guard !tab.shy else { return nil }
        let saved = (looks[AddonProfiles.key(AddonProfiles.of(tab))] ?? [:])
            .filter { $0.value.changed && $0.value.enabled }
            .mapValues(\.payload)
        guard !saved.isEmpty else { return nil }
        let entries = saved.sorted { $0.key < $1.key }.map { [PageScripts.scriptHost($0.key), $0.value] as [Any] }
        return """
        (() => {
          const look = new Map(\(BoostScript.json(entries))).get(\(PageScripts.documentHost));
          if (!/^https?:$/.test(location.protocol) || !look) return;
          \(BoostEditorScript.source)
          window.__yabEditor.apply(look, 'direct');
        })();
        """
    }
}

enum BoostEditorScript {
    static let source = PageScript.load("boost-editor")
    static func apply(_ look: BoostEditorLook, motion: String, original: Bool = false) -> String {
        source + "\nwindow.__yabEditor.apply(\(BoostScript.json(look.payload)), \(BoostScript.json(motion)), \(original));"
    }
}
