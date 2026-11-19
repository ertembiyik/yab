import AppKit
import SwiftUI
import WebKit

/// Page defaults; author styles can still choose their own type and size.
struct PageFonts: Codable, Equatable {
    var size: Int = 16
    var minimum: Int = 0
    var standard: String = ""
    var serif: String = ""
    var sans: String = ""
    var fixed: String = ""

    static func read(in store: UserDefaults = Store.settings) -> PageFonts {
        guard let data = store.data(forKey: "pages.fonts"),
              let fonts = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return fonts
    }

    static func family(_ value: String, fallback: String) -> String {
        guard !value.isEmpty else { return "" }
        // CSS strings, not selectors or executable script.
        let safe = value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        // Keep the chosen text face first, with system emoji before the generic fallback.
        return "\"\(safe)\", \"\(emojiFamily)\", \(fallback)"
    }

    /// Apple Color Emoji under a name of Yab's own that covers only real
    /// emoji. Named directly, it also has ©, ®, ™, arrows, ‼ and the digits,
    /// so a chosen face without them drew them as color pictures; outside
    /// this range they fall to the generic face as text.
    static let emojiFamily = "Yab Emoji"

    /// Characters drawn as emoji by default (Emoji_Presentation), the joiner,
    /// keycap, presentation selector and tag pieces of sequences, and the
    /// pictograph blocks, whose few text-default faces Apple draws as emoji.
    static let emojiRange = [
        "U+200D", "U+20E3", "U+231A-231B", "U+23E9-23EC", "U+23F0", "U+23F3", "U+25FD-25FE",
        "U+2614-2615", "U+2648-2653", "U+267F", "U+2693", "U+26A1", "U+26AA-26AB", "U+26BD-26BE",
        "U+26C4-26C5", "U+26CE", "U+26D4", "U+26EA", "U+26F2-26F3", "U+26F5", "U+26FA", "U+26FD",
        "U+2705", "U+270A-270B", "U+2728", "U+274C", "U+274E", "U+2753-2755", "U+2757",
        "U+2795-2797", "U+27B0", "U+27BF", "U+2B1B-2B1C", "U+2B50", "U+2B55", "U+FE0F",
        "U+1F004", "U+1F0CF", "U+1F18E", "U+1F191-1F19A", "U+1F1E6-1F1FF", "U+1F201", "U+1F21A",
        "U+1F22F", "U+1F232-1F236", "U+1F238-1F23A", "U+1F250-1F251", "U+1F300-1F64F",
        "U+1F680-1F6FF", "U+1F7E0-1F7FF", "U+1F900-1F9FF", "U+1FA70-1FAFF", "U+E0020-E007F",
    ].joined(separator: ", ")

    /// local() needs no download, so the face is ready for the first paint.
    static let emojiFace = "@font-face { font-family: \"\(emojiFamily)\"; src: local(\"Apple Color Emoji\"), local(\"AppleColorEmoji\"); unicode-range: \(emojiRange); }"

    var css: String {
        var rules: [String] = []
        if size != 16 { rules.append(":where(html) { font-size: \(min(72, max(9, size)))px; }") }
        let body = standard.isEmpty ? serif : standard
        if !body.isEmpty { rules.append(":where(html, body) { font-family: \(Self.family(body, fallback: "serif")); }") }
        if !sans.isEmpty { rules.append(":where(input, button, select, textarea) { font-family: \(Self.family(sans, fallback: "sans-serif")); }") }
        if !fixed.isEmpty { rules.append(":where(pre, code, kbd, samp) { font-family: \(Self.family(fixed, fallback: "monospace")); }") }
        // A custom family anywhere makes rules here, so the sheet brings the
        // emoji face; the generic families come from the engines (PageFamilies).
        if [standard, serif, sans, fixed].contains(where: { !$0.isEmpty }) { rules.insert(Self.emojiFace, at: 0) }
        return rules.joined(separator: "\n")
    }
}

enum PageAppearance {
    static let changed = Notification.Name("yab.page-appearance.changed")
    static let siteZoomChanged = Notification.Name("yab.site-zoom.changed")
    static let marker = "/* yab page appearance */"

    @MainActor static func rememberZoom(_ value: Double?, host: String) {
        Store.settings.set(value, forKey: "zoom." + host)
        NotificationCenter.default.post(name: siteZoomChanged, object: host)
    }

    static func defaultZoom(in store: UserDefaults = Store.settings) -> Double {
        let value = store.object(forKey: "pages.zoom") as? Double ?? 1
        return value.isFinite ? min(3, max(0.4, value)) : 1
    }

    static func zoom(host: String?, privatePage: Bool, in store: UserDefaults = Store.settings) -> Double {
        if !privatePage, let host, let value = store.object(forKey: "zoom." + host) as? Double, value.isFinite {
            return min(3, max(0.4, value))
        }
        return defaultZoom(in: store)
    }

    /// Keyboard and site controls move by ten percentage points, not ten
    /// percent of the previous size. An exact custom size stays the origin.
    static func steppedZoom(_ current: Double, increasing: Bool) -> Double {
        min(3, max(0.4, current + (increasing ? 0.1 : -0.1)))
    }

    /// The page's sheet of defaults, put in once per document and left as it
    /// is: nothing watches the page or reads or sets its elements. The generic
    /// families are the engines' own settings (PageFamilies), so a page asking
    /// for sans-serif gets the chosen face from the engine itself (#1889: the
    /// script that named it on every added element cost 14% of Speedometer).
    static func script(_ fonts: PageFonts) -> String {
        let data = try! JSONEncoder().encode(fonts.css)
        let css = String(decoding: data, as: UTF8.self)
        return """
        \(marker)
        (() => {
          if (!/^https?:$/.test(location.protocol)) return;
          const css = \(css);
          const previous = globalThis.__yabPageDefaults;
          previous?.observer?.disconnect();
          previous?.rootObserver?.disconnect();
          // What an older copy of this script named on elements, put back.
          for (const [node, value] of previous?.changed || []) {
            if (node.isConnected) {
              if (value.font) node.style.setProperty('font-family', value.font, value.priority);
              else node.style.removeProperty('font-family');
            }
          }
          const state = {rootObserver:null};
          globalThis.__yabPageDefaults = state;
          const apply = () => {
            let style = document.getElementById('yab-page-defaults');
            if (!css) { style?.remove(); return; }
            if (!style) {
              style = document.createElement('style');
              style.id = 'yab-page-defaults';
              document.documentElement.prepend(style);
            }
            if (style.textContent !== css) style.textContent = css;
          };
          if (document.documentElement) { apply(); return; }
          if (!css) return;
          // At document start the engine may not have made <html> yet: the
          // sheet goes in the moment it exists, and the watch ends there.
          state.rootObserver = new MutationObserver(() => {
            if (!document.documentElement || globalThis.__yabPageDefaults !== state) return;
            state.rootObserver.disconnect();
            state.rootObserver = null;
            apply();
          });
          state.rootObserver.observe(document, {childList:true});
        })();
        """
    }

    @MainActor static func install(_ fonts: PageFonts, in controller: WKUserContentController) {
        let retained = controller.userScripts.filter { !$0.source.hasPrefix(marker) }
        controller.removeAllUserScripts()
        // WebKit keeps extension scripts when clearing application scripts.
        // Re-adding those survivors doubles them on every navigation, until
        // CreateWebPage exceeds the kernel's IPC message limits.
        let remaining = Set(controller.userScripts.map(ObjectIdentifier.init))
        for script in retained where !remaining.contains(ObjectIdentifier(script)) {
            controller.addUserScript(script)
        }
        // The one object a tab's next arming puts first (PageScripts), and
        // none when no face or size of one's own is chosen.
        if !fonts.css.isEmpty { controller.addUserScript(PageScripts.fonts(fonts)) }
    }
}

/// Pages' size, three Aa; and their fonts, set
/// once and seldom again, in a sheet behind Customize….
struct PageAppearanceSettings: View {
    @Bindable var prefs: Preferences
    /// For the row to Reading Mode's page.
    var model: SettingsModel? = nil
    @State private var fonts = false

    /// Smaller, as it comes, larger: the zoom each Aa sets and its size.
    static let steps: [(zoom: Double, size: CGFloat)] = [(0.9, 11), (1, 13), (1.25, 17)]

    var body: some View {
        Section {
            SettingsRow("Page size", detail: "Default zoom for sites without a saved zoom level.") {
                GlassTrack(title: "Page size", options: options,
                           sizes: Dictionary(uniqueKeysWithValues: Self.steps.map { ($0.zoom, $0.size) }),
                           names: Dictionary(uniqueKeysWithValues: options.map { ($0.value, Self.percent($0.value)) }),
                           selection: $prefs.pageZoom)
                    .frame(width: 44 * CGFloat(options.count) + 6)
            }
            .settingsAnchor("page-zoom")
            SettingsRow("Fonts", detail: "Default fonts for pages without specified fonts.") {
                Button("Customize\u{2026}") { fonts = true }.settingsButton()
            }
            .settingsAnchor("page-fonts")
            .sheet(isPresented: $fonts) { PageFontsSheet(prefs: prefs) { fonts = false } }
            DarkPagesSettings(prefs: prefs)
            // Reading mode has a page of its own: one row to it.
            if let model { ReadingModeRow(model: model) }
        }
    }

    /// The three, and a zoom set some other way where it falls among them,
    /// in its own words, so the track never shows a size that isn't set.
    private var options: [(title: String, value: Double)] {
        var zooms = Self.steps.map(\.zoom)
        if !zooms.contains(prefs.pageZoom) { zooms = (zooms + [prefs.pageZoom]).sorted() }
        return zooms.map { zoom in (Self.steps.contains { $0.zoom == zoom } ? "Aa" : Self.percent(zoom), zoom) }
    }

    static func percent(_ zoom: Double) -> String { "\(Int((zoom * 100).rounded()))%" }
}

/// The type pages are set in when they don't choose their own: its size,
/// the four families and the least size any text may be.
private struct PageFontsSheet: View {
    @Bindable var prefs: Preferences
    let close: () -> Void
    private let families = NSFontManager.shared.availableFontFamilies.sorted { $0.localizedStandardCompare($1) == .orderedAscending }

    var body: some View {
        VStack(spacing: 0) {
            ThreadForm {
                Section {
                    MenuRow("Font size", options: [9, 12, 14, 16, 18, 20, 24, 28, 32, 36, 48, 72].map { ("\($0) px", $0) }, selection: $prefs.pageFonts.size)
                    font("Standard font", selection: $prefs.pageFonts.standard)
                    font("Serif font", selection: $prefs.pageFonts.serif)
                    font("Sans-serif font", selection: $prefs.pageFonts.sans)
                    font("Fixed-width font", selection: $prefs.pageFonts.fixed)
                    MenuRow("Minimum font size", options: [("None", 0)] + [9, 10, 11, 12, 14, 16, 18, 20, 24].map { ("\($0) px", $0) }, selection: $prefs.pageFonts.minimum)
                    SettingsNote("For pages and text fields. Sites can set their own fonts and sizes; the minimum size applies to all text.")
                } header: {
                    Text("Fonts").font(.headline).foregroundStyle(.primary)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            HStack(spacing: 8) {
                Button("Restore Defaults") { prefs.pageFonts = PageFonts() }
                    .settingsButton()
                    .disabled(prefs.pageFonts == PageFonts())
                Spacer()
                Button(action: close) {
                    HStack(spacing: 6) {
                        Text("Done")
                        KeyGlyphs(keys: "↩", size: 12.5, tint: nil, rest: 0.6)
                            .transaction { $0.animation = nil }
                    }
                }
                .settingsButton(.primary)
                .keyboardShortcut(.defaultAction)
            }
            .padding(EdgeInsets(top: 0, leading: 20, bottom: 20, trailing: 20))
        }
        .frame(width: 460, height: 432)
    }

    private func font(_ title: String, selection: Binding<String>) -> some View {
        MenuRow(title, options: [("Default", "")] + families.map { ($0, $0) }, selection: selection)
    }
}
