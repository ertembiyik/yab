import SwiftUI

// Settings › Reading Mode: a page of its own, as reading mode is a feature
// in its own right, with what the card Aa opens over a page being read
// (ReaderCard) has: the six themes, the light, the size, a wide page and
// Customize, and colors of your own. The same values (ReaderStyle), so a
// change here is on every page being read at once, and the card's edits
// are here.

/// A theme's tile, in its own face and colors, ringed when it is the one
/// in use and dotted when it has edits: the card's and this page's.
struct ReaderThemeTile: View {
    let spec: ReaderThemeSpec
    let colors: ReaderColors
    let picked: Bool
    let edited: Bool
    let pick: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.floating, style: .continuous)
        Button(action: pick) {
            VStack(spacing: 1) {
                Text("Aa").font(spec.look.font.font(size: 22, weight: spec.fontWeight))
                Text(spec.name).font(spec.look.font.font(size: 12, weight: spec.fontWeight)).opacity(0.9)
            }
            .foregroundStyle(colors.ink)
            .frame(maxWidth: .infinity)
            .frame(height: 72)
            .background(colors.ground, in: shape)
            .overlay(shape.strokeBorder(Color.gray.opacity(0.2), lineWidth: 1))
            .overlay(alignment: .topTrailing) {
                Circle().fill(colors.ink.opacity(0.8))
                    .frame(width: 6, height: 6)
                    .padding(8)
                    .opacity(edited ? 1 : 0)
                    .scaleEffect(edited ? 1 : 0.4)
            }
            .overlay { if picked { shape.inset(by: -1.25).stroke(Palette.ink, lineWidth: 2.5) } }
            .contentShape(shape)
        }
        .buttonStyle(PressStyle(scale: 0.95))
        .animation(Motion.settle, value: edited)
        .accessibilityLabel(edited ? "\(spec.name), edited" : spec.name)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }
}

struct ReadingModePage: View {
    private var style = ReaderStyle.shared
    @Environment(\.colorScheme) private var scheme

    /// The theme the pointer is over among the tiles, tried on in the head.
    @State private var trying: ReaderThemeID?

    private var prefs: ReaderPrefs { style.prefs }

    var body: some View {
        let dark = prefs.isDark(system: scheme == .dark)
        PageHero(page: .reading) {
            ReaderPreviewPage(prefs: prefs, theme: trying ?? prefs.theme, dark: dark)
        }
        Section {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(ReaderThemeSpec.ordered, id: \.id) { spec in
                    ReaderThemeTile(spec: spec, colors: prefs.colors(spec.id, dark: dark),
                                    picked: prefs.theme == spec.id, edited: prefs.edited(spec.id)) {
                        style.prefs.theme = spec.id
                    }
                    .onHover { inside in
                        if inside { trying = spec.id } else if trying == spec.id { trying = nil }
                    }
                }
            }
            .padding(.vertical, 4)
            .settingsAnchor("reader-theme")
            MenuRow("Appearance", options: ReaderMode.allCases.map { (title: $0.title, value: $0) },
                    selection: Binding(get: { style.prefs.mode }, set: { style.prefs.mode = $0 }))
                .settingsAnchor("reader-light")
            SettingsRow("Text size") {
                HStack(spacing: 8) {
                    Button { style.prefs.step(-1) } label: { Text("A").font(.system(size: 11, weight: .medium)) }
                        .buttonStyle(.yab(.secondary, .regular, icon: .round))
                        .disabled(prefs.look.size <= 0)
                        .keyTip("Smaller Text")
                        .accessibilityLabel("Smaller Text")
                    Text("\(prefs.look.points) pt")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 40)
                    Button { style.prefs.step(1) } label: { Text("A").font(.system(size: 15, weight: .medium)) }
                        .buttonStyle(.yab(.secondary, .regular, icon: .round))
                        .disabled(prefs.look.size >= ReaderLook.sizes.count - 1)
                        .keyTip("Larger Text")
                        .accessibilityLabel("Larger Text")
                }
            }
            .settingsAnchor("reader-size")
            SettingsSwitch("Wide page", isOn: Binding(get: { style.prefs.wide }, set: { style.prefs.wide = $0 }))
                .settingsAnchor("reader-wide")
        }
        customize
        colors
    }

    // MARK: Customize, the theme in use

    @ViewBuilder
    private var customize: some View {
        let spec = prefs.spec
        let look = prefs.look
        Section {
            MenuRow("Font", options: ReaderFont.allCases.map { face in
                (title: face == spec.look.font ? "\(face.title) (\(spec.name)\u{2019}s)" : face.title, value: face)
            }, selection: Binding(get: { style.prefs.look.font }, set: { face in style.prefs.change { $0.font = face } }))
                .settingsAnchor("reader-font")
            SettingsSwitch("Bold text", isOn: Binding(get: { style.prefs.look.bold }, set: { on in style.prefs.change { $0.bold = on } }))
            slider("Line spacing", value: look.line, range: ReaderLook.lines, step: 0.05, text: String(format: "%.2f", look.line)) { v in
                style.prefs.change { $0.line = (v * 20).rounded() / 20 }
            }
            slider("Character spacing", value: Double(look.letter), range: ReaderLook.letters, step: 1, text: "\(look.letter)%") { v in
                style.prefs.change { $0.letter = Int(v.rounded()) }
            }
            slider("Word spacing", value: Double(look.word), range: ReaderLook.words, step: 2, text: "\(look.word)%") { v in
                style.prefs.change { $0.word = Int(v.rounded()) }
            }
            slider("Margins", value: Double(look.margins), range: ReaderLook.marginRange, step: 2,
                   text: (look.margins > 0 ? "+" : "") + "\(look.margins)%") { v in
                style.prefs.change { $0.margins = Int(v.rounded()) }
            }
            SettingsSwitch("Justify text", isOn: Binding(get: { style.prefs.look.justify }, set: { on in style.prefs.change { $0.justify = on } }))
        } header: {
            HStack {
                Text("Customize \(spec.name)")
                Spacer(minLength: 0)
                Button(SettingsWords.text("Reset")) { style.prefs.reset() }
                    .settingsButton()
                    .disabled(!prefs.edited(prefs.theme))
            }
            .foregroundStyle(.secondary)
            .settingsAnchor("reader-customize")
        }
    }

    private func slider(_ title: String, value: Double, range: ClosedRange<Double>, step: Double, text: String,
                        set: @escaping (Double) -> Void) -> some View {
        SettingsRow(title) {
            HStack(spacing: 8) {
                Slider(value: Binding(get: { value }, set: { set(($0 / step).rounded() * step) }), in: range)
                    .controlSize(.small)
                    .labelsHidden()
                    .frame(width: 160)
                    .accessibilityLabel(title)
                Text(text)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
        }
    }

    // MARK: colors of your own

    @ViewBuilder
    private var colors: some View {
        Section {
            SettingsRow("Custom colors", detail: "Customize colors for \(prefs.spec.name).") {
                Toggle(SettingsWords.text("Custom colors"), isOn: Binding(
                    get: { style.prefs.look.colors != nil },
                    set: { on in
                        let own = style.prefs.colors(style.prefs.theme, dark: style.prefs.isDark(system: scheme == .dark))
                        style.prefs.change { $0.colors = on ? own : nil }
                    }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .settingsAnchor("reader-colors")
            if let colors = prefs.look.colors {
                SettingsRow("Background") {
                    ColorPicker("Background", selection: color(colors.background) { hex in
                        let text = style.prefs.look.colors?.text ?? colors.text
                        style.prefs.change { $0.colors = ReaderColors(hex, text) }
                    }, supportsOpacity: false)
                        .labelsHidden()
                }
                SettingsRow("Text", detail: "Adjusted for readable contrast.") {
                    ColorPicker("Text", selection: color(colors.text) { hex in
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

/// Reading mode on Websites: one row, the theme in use small and named
/// beside it, as App icon's row, opening Reading Mode's page.
struct ReadingModeRow: View {
    var model: SettingsModel
    private var style = ReaderStyle.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button { model.go(.reading) } label: {
            SettingsRow("Reading mode") {
                HStack(spacing: 6) {
                    ReaderThumb(prefs: style.prefs, dark: style.prefs.isDark(system: scheme == .dark))
                    Text(style.prefs.spec.name)
                        .foregroundStyle(.secondary)
                    SettingsChevron()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens Reading Mode")
        .settingsAnchor("reading-mode")
    }
}
