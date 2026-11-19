import SwiftUI

// Reading mode's look on the Mac: the one copy of the prefs (ReaderStyle),
// Settings › Appearance › Reading mode and View › Reading Appearance. The
// themes themselves are ReaderThemes.swift, shared with the iPhone; the
// card is ReaderCard.swift.

extension ReaderColors {
    var ground: Color { Color(nsColor: NSColor(hex: background) ?? .white) }
    var ink: Color { Color(nsColor: NSColor(hex: text) ?? .black) }
}

/// The one copy every view and the page read; each change is kept and sent
/// to every page being read.
@MainActor
@Observable final class ReaderStyle {
    static let shared = ReaderStyle()

    var prefs: ReaderPrefs {
        didSet {
            guard prefs != oldValue else { return }
            prefs.save(to: Store.settings)
            Tab.refreshReaderThemes()
        }
    }

    private init() { prefs = ReaderPrefs.load(from: Store.settings) }
}

extension ReaderPrefs {
    @MainActor static var saved: ReaderPrefs { ReaderStyle.shared.prefs }
}

/// Reading mode in Settings › Appearance, under the pages' own size and
/// fonts (feedback #272): the theme, the light, and colors of your own for
/// the theme, which is where Custom's went. The card over a page being
/// read has the rest.
struct ReaderAppearanceSettings: View {
    private var style = ReaderStyle.shared

    var body: some View {
        let prefs = style.prefs
        Group {
            SettingsRow("Reading mode", detail: "Default reading theme. Use Aa beside the book to change it on a page.") {
                DropMenu("Reading mode", options: ReaderThemeSpec.ordered.map { DropOption(title: $0.name, value: $0.id) },
                         selection: Binding(get: { style.prefs.theme }, set: { style.prefs.theme = $0 }))
                    .fixedSize()
            }
            .settingsAnchor("reader-theme")
            SettingsRow("Reading appearance") {
                DropMenu("Reading appearance", options: ReaderMode.allCases.map { DropOption(title: $0.title, value: $0) },
                         selection: Binding(get: { style.prefs.mode }, set: { style.prefs.mode = $0 }))
                    .fixedSize()
            }
            SettingsRow("Custom colors", detail: "Customize colors for \(prefs.spec.name).") {
                Toggle("Custom colors", isOn: Binding(
                    get: { style.prefs.look.colors != nil },
                    set: { on in
                        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                        let own = style.prefs.colors(style.prefs.theme, dark: style.prefs.isDark(system: dark))
                        style.prefs.change { $0.colors = on ? own : nil }
                    }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .settingsAnchor("reader-colors")
            if let colors = prefs.look.colors {
                SettingsRow("Reading background") {
                    ColorPicker("Reading background", selection: color(colors.background) { hex in
                        let text = style.prefs.look.colors?.text ?? colors.text
                        style.prefs.change { $0.colors = ReaderColors(hex, text) }
                    }, supportsOpacity: false)
                        .labelsHidden()
                }
                SettingsRow("Reading text", detail: "Adjusted for readable contrast.") {
                    ColorPicker("Reading text", selection: color(colors.text) { hex in
                        let background = style.prefs.look.colors?.background ?? colors.background
                        style.prefs.change { $0.colors = ReaderColors(background, hex) }
                    }, supportsOpacity: false)
                        .labelsHidden()
                }
            }
        }
    }

    private func color(_ hex: String, _ set: @escaping (String) -> Void) -> Binding<Color> {
        Binding(get: { Color(nsColor: NSColor(hex: hex) ?? .white) }, set: { set(NSColor($0).hex) })
    }
}

/// View › Reading Appearance: the six themes and the light, checked, for a
/// page being read wherever Aa isn't in sight; the card itself, and the
/// colors of your own in Settings.
struct ReaderAppearanceMenu: View {
    let browser: Browser
    private var style = ReaderStyle.shared

    var body: some View {
        Menu("Reading Appearance") {
            Picker("Theme", selection: Binding(get: { style.prefs.theme }, set: { style.prefs.theme = $0 })) {
                ForEach(ReaderThemeSpec.ordered, id: \.id) { spec in
                    Text(style.prefs.edited(spec.id) ? spec.name + " (Edited)" : spec.name).tag(spec.id)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            Picker("Appearance", selection: Binding(get: { style.prefs.mode }, set: { style.prefs.mode = $0 })) {
                ForEach(ReaderMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            Button("Themes & Settings\u{2026}") { ReaderCard.shared.open(browser: browser) }
                .disabled(browser.active?.reader != true)
            Button("Custom Colors\u{2026}") {
                SettingsModel.ask(row: "reader-colors")
                SettingsWindow.shared.show(.reading, for: browser)
            }
        }
    }
}
