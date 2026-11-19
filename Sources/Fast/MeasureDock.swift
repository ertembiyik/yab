import SwiftUI

// Measure's dock at the page's foot (Measure.swift): the agent's dock
// (AgentDock.swift) in every part, so the two read as one thing. The HUD
// plate, light over a dark page and dark otherwise (HUD.surface(over:)),
// 36 high, a regular button 4 in from its edge, its corner the
// button's 8 and those 4; the ruler where the agent has its face, 12 in;
// words of 12.5. It says what is picked, or how to pick, and holds the
// page's troubles as a word, Details and Copy for Agent.
//
// Space grows it up into a card, as the agent's answer grows (CardFrame):
// everything 12 in, the corner 8 and 12; the sheet holds the picked box's
// numbers, its rules (a value clicked is a field), what moves in it, the
// measurements kept and the notes. N turns the words into a field for a
// note. Copy for Agent says Copied where it stands, in its own width.
//
// The words cross over as the agent's do and the buttons keep their end;
// the plate comes up from the foot on Motion.arrive. With an agent's dock
// on the same page, Measure's stands above it (PageFoot).

struct MeasureDock: View {
    var tab: Tab
    var model: MeasureModel
    @Environment(\.accessibilityReduceMotion) private var still
    @FocusState private var noteFocus: Bool
    @State private var note = ""

    /// Its plate: light over a dark page, dark otherwise.
    private var hud: HUD.Surface { HUD.surface(over: tab.isBlank ? nil : tab.under) }

    /// A regular button's corner and its inset, as the agent's dock.
    static let corner = Radius.control + 4
    /// Room for the longest words a pick says, so a click on a short name
    /// doesn't move the dock.
    static let words: CGFloat = 260
    /// The sheet's width at the least.
    static let sheet: CGFloat = 616

    private var info: MeasureInfo { model.info }

    var body: some View {
        let open = model.details
        VStack(alignment: .leading, spacing: 0) {
            if open {
                MeasureSheet(tab: tab, model: model)
                    .padding(.bottom, CardFrame.inset)
                    .overlay(alignment: .bottom) { Rectangle().fill(HUD.rule(on: hud)).frame(height: 1) }
                    .padding(.bottom, CardFrame.inset)
                    .frame(minWidth: Self.sheet, alignment: .leading)
                    .transition(still ? .opacity : .opacity.combined(with: .offset(y: 6)))
            }
            row(open: open)
        }
        .padding(open ? CardFrame.inset : 0)
        .fixedSize()
        .background { HUD.plate(open ? Radius.card : Self.corner, surface: hud) }
        .environment(\.colorScheme, hud == .light ? .light : .dark)
        .environment(\.hudSurface, hud)
        .animation(still ? nil : Motion.quick, value: hud)
        .animation(still ? nil : Motion.reshape, value: open)
        .onChange(of: model.noting) { _, now in
            if now { note = ""; noteFocus = true } else { noteFocus = false }
        }
    }

    private func row(open: Bool) -> some View {
        HStack(spacing: 10) {
            Symbol("ruler", size: 11)
                .foregroundStyle(HUD.ink(on: hud))
                .frame(width: 15, height: 15)
                .padding(.leading, open ? 0 : 12)
            words
                .frame(minWidth: Self.words, alignment: .leading)
            Spacer(minLength: 0)
            buttons
                .padding(.trailing, open ? 0 : 4)
        }
        .frame(height: open ? ButtonSize.regular.height : 36)
    }

    // MARK: - the words

    @ViewBuilder private var words: some View {
        ZStack(alignment: .leading) {
            if model.noting, let sel = info.sel {
                TextField("What should change in \(sel.name)", text: $note)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(HUD.ink(on: hud))
                    .focused($noteFocus)
                    .onSubmit { addNote() }
                    .onExitCommand { model.noting = false; focusPage() }
                    .frame(width: 320)
                    .transition(still ? .opacity : said)
            } else {
                Group {
                    if let sel = info.sel {
                        HStack(spacing: 8) {
                            Text(sel.name).font(.system(size: 12.5, weight: .medium)).foregroundStyle(HUD.ink(on: hud))
                            Text(sel.size).font(.system(size: 12.5)).foregroundStyle(HUD.muted(on: hud)).monospacedDigit()
                        }
                    } else if let picture = info.compare {
                        HStack(spacing: 8) {
                            Text(picture.name).font(.system(size: 12.5, weight: .medium)).foregroundStyle(HUD.ink(on: hud))
                            Text(picture.dx == 0 && picture.dy == 0 ? "arrows move it" : "moved \(Self.number(picture.dx)), \(Self.number(picture.dy))")
                                .font(.system(size: 12.5)).foregroundStyle(HUD.muted(on: hud)).monospacedDigit()
                        }
                    } else {
                        HStack(spacing: 4) {
                            Text("Click a box, hold")
                            KeyGlyphs(keys: "⌥", size: 12.5, tint: nil).opacity(0.6)
                            Text("to measure")
                        }
                        .font(.system(size: 12.5))
                        .foregroundStyle(HUD.ink(on: hud))
                    }
                }
                .lineLimit(1)
                .id(wordsKey)
                .transition(still ? .opacity : said)
            }
        }
        .animation(still ? nil : Motion.morph, value: wordsKey)
    }

    /// The words crossing over, as the agent's dock's do.
    private var said: AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .offset(y: 6)),
                    removal: .opacity.combined(with: .offset(y: -6)).animation(.easeIn(duration: 0.1)))
    }

    private var wordsKey: String {
        if model.noting { return "note" }
        if let sel = info.sel { return sel.name + sel.size }
        if let picture = info.compare { return "picture \(picture.dx) \(picture.dy)" }
        return "idle"
    }

    static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    // MARK: - the buttons

    @ViewBuilder private var buttons: some View {
        HStack(spacing: 6) {
            if model.noting {
                Button { addNote() } label: {
                    HStack(spacing: 6) {
                        Text("Add")
                        KeyGlyphs(keys: "↩", size: 12.5, tint: nil).opacity(0.6)
                            .transaction { $0.animation = nil }
                    }
                }
                .buttonStyle(.yab(.primary, .regular, surface: hud))
                .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .transition(.opacity)
            } else {
                if let picture = info.compare {
                    Button { act(["compare": "diff"]) } label: {
                        HStack(spacing: 6) {
                            Text(picture.diff ? "Difference" : "Faded")
                                .transaction { $0.animation = nil }
                            KeyGlyphs(keys: "D", size: 12.5, tint: nil).opacity(0.6)
                        }
                    }
                    .buttonStyle(.yab(.secondary, .regular, surface: hud))
                    Button { act(["compare": "remove"]) } label: { Symbol("xmark", size: 11) }
                        .buttonStyle(.yab(.quiet, .regular, surface: hud, icon: .square))
                        .focusable(false)
                        .keyTip("Remove Picture", side: .above)
                }
                if info.issues > 0 {
                    Button { act(["issues": !info.showIssues]) } label: {
                        HStack(spacing: 6) {
                            Circle().fill(MeasureDock.yellow).frame(width: 6, height: 6)
                            Text(info.issues == 1 ? "1 issue" : "\(info.issues) issues")
                                .monospacedDigit()
                                .transaction { $0.animation = nil }
                        }
                    }
                    .buttonStyle(.yab(info.showIssues ? .secondary : .quiet, .regular, surface: hud))
                    .keyTip(info.showIssues ? "Hide on the Page" : "Show on the Page", side: .above)
                }
                Button { model.toggleDetails(); focusPage() } label: {
                    HStack(spacing: 6) {
                        Text("Details")
                        KeyGlyphs(keys: "space", size: 12.5, tint: nil).opacity(0.6)
                    }
                }
                .buttonStyle(.yab(.secondary, .regular, surface: hud))
                Button { act(["copy": true]) } label: {
                    HStack(spacing: 6) {
                        // Copy for Agent as wide as the Copied it turns into.
                        ZStack {
                            Text("Copy for Agent").hidden()
                            Text(model.copiedNow ? "Copied" : "Copy for Agent")
                        }
                        .transaction { $0.animation = nil }
                        KeyGlyphs(keys: "⌘C", size: 12.5, tint: nil).opacity(0.6)
                            .transaction { $0.animation = nil }
                    }
                }
                .buttonStyle(.yab(.secondary, .regular, surface: hud))
                .disabled(info.sel == nil)
            }
        }
        .fixedSize()
    }

    static let yellow = Color(nsColor: .systemYellow)

    private func act(_ asked: [String: Any]) {
        tab.measureAct(asked)
        focusPage()
    }

    private func addNote() {
        let words = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !words.isEmpty { tab.measureAct(["note": words]) }
        note = ""
        model.noting = false
        focusPage()
    }

    /// The keys back to the page, where Measure hears them.
    private func focusPage() {
        tab.page.window?.makeFirstResponder(tab.page)
    }
}

/// The sheet Space grows out of the dock: the picked box's numbers on the
/// left; on the right what moves in it, its rules, the page's troubles when
/// they are shown, the measurements kept and the notes.
private struct MeasureSheet: View {
    @Environment(\.hudSurface) private var hud
    var tab: Tab
    var model: MeasureModel
    @State private var height: CGFloat = 0

    private var info: MeasureInfo { model.info }

    var body: some View {
        ThreadScrollView(.vertical) {
            HStack(alignment: .top, spacing: 16) {
                if info.sel != nil {
                    facts
                        .frame(width: 260, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 12) {
                    if info.sel != nil, !info.motion.isEmpty { motion }
                    if info.sel != nil, !info.rules.isEmpty { rules }
                    if info.showIssues, !info.list.isEmpty { troubles }
                    if !info.pins.isEmpty { kept }
                    if !info.notes.isEmpty { notes }
                    if info.sel != nil {
                        Button("Open in Elements") { tab.measureAct(["elements": true]) }
                            .buttonStyle(.yab(.secondary, .small, surface: hud))
                    }
                    if info.sel == nil, info.pins.isEmpty, info.notes.isEmpty, !info.showIssues {
                        Text("Pick a box to see its numbers, its rules and what moves in it.")
                            .font(.system(size: 12))
                            .foregroundStyle(HUD.muted(on: hud))
                    }
                    keys
                }
                .frame(minWidth: 300, maxWidth: 340, alignment: .leading)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        }
        .scrollIndicators(.never)
        .frame(height: min(height, 360))
    }

    // MARK: the numbers

    private var facts: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 4) {
            ForEach(info.rows) { row in
                GridRow {
                    Text(row.l).foregroundStyle(HUD.muted(on: hud))
                        .frame(width: 56, alignment: .leading)
                    if let colors = row.c {
                        HStack(spacing: 4) {
                            ForEach(Array(colors.enumerated()), id: \.offset) { index, hex in
                                if index > 0 { Text("on").foregroundStyle(HUD.muted(on: hud)) }
                                RoundedRectangle(cornerRadius: Radius.small / 2, style: .continuous) // design: a 10 pt swatch, a tag's corner halved
                                    .fill(Color(measureHex: hex))
                                    .overlay(RoundedRectangle(cornerRadius: Radius.small / 2, style: .continuous).strokeBorder(HUD.rule(on: hud), lineWidth: 1)) // design: the swatch's own edge
                                    .frame(width: 10, height: 10)
                                Text(hex).foregroundStyle(HUD.ink(on: hud))
                            }
                        }
                    } else {
                        row.v.enumerated().reduce(Text("")) { line, piece in
                            line + Text(piece.offset == 0 ? "" : " ") + Text(piece.element.t)
                                .foregroundStyle(piece.element.bad ? MeasureSheet.red : HUD.ink(on: hud))
                                .fontWeight(piece.element.bad ? .semibold : .regular)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .font(.system(size: 12))
        .monospacedDigit()
    }

    static let red = Color(nsColor: .systemRed)

    // MARK: motion

    private var motion: some View {
        section("Motion") {
            ForEach(Array(info.motion.enumerated()), id: \.offset) { index, item in
                MeasureMotionRow(tab: tab, model: model, index: index, item: item)
            }
        }
    }

    // MARK: rules

    private var rules: some View {
        section("Rules") {
            ForEach(Array(info.rules.enumerated()), id: \.offset) { index, rule in
                MeasureRuleCard(tab: tab, index: index, rule: rule)
            }
        }
    }

    // MARK: the page's troubles

    private var troubles: some View {
        section("On This Page") {
            ForEach(Array(info.list.enumerated()), id: \.offset) { index, trouble in
                Button { tab.measureAct(["pickIssue": index]) } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(trouble.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(HUD.ink(on: hud))
                        Text("\(trouble.name) · \(trouble.words)").font(.system(size: 11.5)).foregroundStyle(HUD.muted(on: hud))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.yab(.quiet, .small, surface: hud))
                .onHover { on in tab.measureAct(["flash": on ? index as Any : NSNull() as Any]) }
            }
        }
    }

    // MARK: kept and notes

    private var kept: some View {
        section("Kept", clear: { tab.measureAct(["unpin": "all"]) }) {
            ForEach(Array(info.pins.enumerated()), id: \.offset) { index, pin in
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(pin.a) to \(pin.b)").foregroundStyle(HUD.muted(on: hud)).lineLimit(1)
                        Text(pin.v).foregroundStyle(HUD.ink(on: hud)).monospacedDigit()
                    }
                    Spacer(minLength: 0)
                    Button { tab.measureAct(["unpin": index]) } label: { Symbol("xmark", size: 10) }
                        .buttonStyle(.yab(.quiet, .small, surface: hud, icon: .square))
                        .focusable(false)
                        .keyTip("Remove", side: .above)
                }
                .font(.system(size: 12))
            }
        }
    }

    private var notes: some View {
        section("Notes") {
            ForEach(Array(info.notes.enumerated()), id: \.offset) { index, note in
                HStack(alignment: .top, spacing: 8) {
                    Text(String(note.n)).font(.system(size: 12, weight: .bold)).foregroundStyle(MeasureSheet.violet)
                    Text(note.text).font(.system(size: 12)).foregroundStyle(HUD.ink(on: hud))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { tab.measureAct(["unnote": index]) } label: { Symbol("xmark", size: 10) }
                        .buttonStyle(.yab(.quiet, .small, surface: hud, icon: .square))
                        .focusable(false)
                        .keyTip("Remove", side: .above)
                }
            }
        }
    }

    static let violet = Color(nsColor: NSColor(srgbRed: 0.6, green: 0.45, blue: 1, alpha: 1))

    // MARK: the keys, said once where they can be read

    private var keys: some View {
        HStack(spacing: 10) {
            hint("⌥", "measure")
            hint("⌥S", "keep")
            hint("N", "note")
            hint("X", "every box")
        }
        .font(.system(size: 11.5))
        .foregroundStyle(HUD.muted(on: hud))
    }

    private func hint(_ keys: String, _ words: String) -> some View {
        HStack(spacing: 4) {
            KeyGlyphs(keys: keys, size: 11.5, tint: nil)
            Text(words)
        }
    }

    private func section<Content: View>(_ title: String, clear: (() -> Void)? = nil, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(HUD.muted(on: hud).opacity(0.7))
                Spacer(minLength: 0)
                if let clear {
                    Button("Clear", action: clear)
                        .buttonStyle(.yab(.quiet, .small, surface: hud))
                }
            }
            content()
        }
    }
}

/// One of the picked box's rules: its selector and where it was written,
/// each declaration under it, struck through when another rule beats it,
/// and its value a field when clicked: Return keeps it, in the page's rule.
private struct MeasureRuleCard: View {
    @Environment(\.hudSurface) private var hud
    let tab: Tab
    let index: Int
    let rule: MeasureInfo.Rule
    @State private var editing: String?
    @State private var draft = ""
    @FocusState private var focus: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(rule.sel).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(HUD.ink(on: hud))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(rule.where).font(.system(size: 11, design: .monospaced)).foregroundStyle(HUD.muted(on: hud))
                    .lineLimit(1)
            }
            ForEach(rule.decls) { decl in
                HStack(spacing: 0) {
                    Text(decl.p + ": ").foregroundStyle(HUD.muted(on: hud))
                    if editing == decl.p {
                        TextField("", text: $draft)
                            .textFieldStyle(.plain)
                            .focused($focus)
                            .onSubmit { keep(decl.p) }
                            .onExitCommand { editing = nil }
                            .fixedSize()
                    } else {
                        Button { editing = decl.p; draft = decl.v; focus = true } label: {
                            Text(decl.v).foregroundStyle(decl.ch ? Color.accentColor : HUD.ink(on: hud))
                        }
                        .buttonStyle(.plain)
                        .pointerTip("Click to change")
                    }
                    Text(";").foregroundStyle(HUD.muted(on: hud))
                }
                .strikethrough(decl.x)
                .opacity(decl.x ? 0.5 : 1)
                .padding(.leading, 10)
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(HUD.rule(on: hud).opacity(0.4), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }

    private func keep(_ prop: String) {
        tab.measureAct(["edit": ["r": index, "p": prop, "v": draft]])
        editing = nil
    }
}

/// One animation of the picked box: its name and timing, its curve with a
/// dot where it is now, what it changes, scrubbed by hand or played again
/// slowed down; , and . step it a frame.
private struct MeasureMotionRow: View {
    @Environment(\.hudSurface) private var hud
    let tab: Tab
    var model: MeasureModel
    let index: Int
    let item: MeasureInfo.Motion
    @State private var speed = 1.0

    private var now: Double { index < model.times.count ? model.times[index] : item.t }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(item.name).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(HUD.ink(on: hud))
                Spacer(minLength: 0)
                Text(item.delay > 0 ? "\(Int(item.ms)) ms after \(Int(item.delay))" : "\(Int(item.ms)) ms")
                    .font(.system(size: 12)).foregroundStyle(HUD.muted(on: hud)).monospacedDigit()
            }
            HStack(alignment: .top, spacing: 8) {
                MeasureCurve(bez: item.bez, at: progress)
                    .frame(width: 64, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.ease).foregroundStyle(HUD.ink(on: hud)).lineLimit(1)
                    ForEach(Array(item.props.enumerated()), id: \.offset) { _, prop in
                        Text(prop.count == 3 ? "\(prop[0]) \(prop[1]) → \(prop[2])" : prop.joined(separator: " "))
                            .foregroundStyle(HUD.muted(on: hud))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .font(.system(size: 11, design: .monospaced))
            }
            Slider(value: Binding(get: { now }, set: { tab.measureAct(["motion": ["n": index, "t": $0]]) }), in: 0...max(1, item.total))
                .controlSize(.small)
            HStack(spacing: 4) {
                Button("Replay") { tab.measureAct(["motion": ["n": index, "play": true]]) }
                    .buttonStyle(.yab(.secondary, .small, surface: hud))
                ForEach([1.0, 0.25, 0.1], id: \.self) { rate in
                    Button(rate == 1 ? "1×" : rate == 0.25 ? "¼×" : "⅒×") {
                        speed = rate
                        tab.measureAct(["motion": ["speed": rate]])
                    }
                    .buttonStyle(.yab(speed == rate ? .secondary : .quiet, .small, surface: hud))
                }
                Spacer(minLength: 0)
                Text("frame \(Int((min(now, item.total) / (1000 / 60)).rounded())) of \(Int((item.total / (1000 / 60)).rounded()))")
                    .font(.system(size: 11)).foregroundStyle(HUD.muted(on: hud)).monospacedDigit()
            }
        }
    }

    private var progress: Double {
        guard item.ms > 0 else { return 1 }
        return min(1, max(0, (now - item.delay) / item.ms))
    }
}

/// A cubic-bezier's curve, with a dot at `at` of the way along in time.
private struct MeasureCurve: View {
    @Environment(\.hudSurface) private var hud
    let bez: [Double]
    let at: Double

    var body: some View {
        Canvas { context, size in
            let p = bez.count == 4 ? bez : [0, 0, 1, 1]
            func point(_ t: Double) -> CGPoint {
                let x = 3 * (1 - t) * (1 - t) * t * p[0] + 3 * (1 - t) * t * t * p[2] + t * t * t
                let y = 3 * (1 - t) * (1 - t) * t * p[1] + 3 * (1 - t) * t * t * p[3] + t * t * t
                return CGPoint(x: x * size.width, y: size.height - y * size.height)
            }
            var line = Path()
            line.move(to: point(0))
            for step in 1...32 { line.addLine(to: point(Double(step) / 32)) }
            context.stroke(line, with: .color(HUD.ink(on: hud)), lineWidth: 1.5)
            // The dot at the time asked: t whose x is that far along.
            var lo = 0.0, hi = 1.0
            for _ in 0..<24 {
                let mid = (lo + hi) / 2
                if Double(point(mid).x / size.width) < at { lo = mid } else { hi = mid }
            }
            let dot = point((lo + hi) / 2)
            context.fill(Path(ellipseIn: CGRect(x: dot.x - 3, y: dot.y - 3, width: 6, height: 6)), with: .color(.accentColor))
        }
        .padding(4)
        .background(HUD.rule(on: hud).opacity(0.4), in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
    }
}

extension Color {
    /// A page's color as Measure writes it, #rrggbb or #rrggbbaa.
    init(measureHex hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        let value = UInt64(text, radix: 16) ?? 0
        if text.count == 8 {
            self.init(.sRGB, red: Double((value >> 24) & 0xFF) / 255, green: Double((value >> 16) & 0xFF) / 255,
                      blue: Double((value >> 8) & 0xFF) / 255, opacity: Double(value & 0xFF) / 255)
        } else {
            self.init(.sRGB, red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                      blue: Double(value & 0xFF) / 255, opacity: 1)
        }
    }
}
