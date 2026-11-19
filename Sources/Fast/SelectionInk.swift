import SwiftUI

/// A rewrite's result in the text's own place, "ink in place" (variant A
/// of artifact FYR34RrQ5Ez7ubZvAeGVjy): no card and no quote of the
/// original. The words come in where the selected ones were, in the page's
/// font, size, line spacing and color, on a soft accent wash, a caret at
/// their end while they come; the original is under them, shown again
/// while ⌥ is held. One bar under the end of the last line says what is
/// happening and holds Stop, or Copy and Replace. Replace leaves the
/// page's own words where these were and fades the wash off them.
struct SelectionInk: View {
    var commands: SelectionCommands
    /// The selection it is drawn over; nil when there is nothing to draw.
    /// Always in the layer, so the words and the bar each go their own way.
    let snap: SelectionSnapshot?
    let room: CGSize
    let tab: Tab
    /// The end of the result's last line, and the foot of the result,
    /// from the selection's corner.
    @State private var end: CGPoint?
    @State private var barSize: CGSize = .zero
    /// The bar has been put in its place once: from then on it moves
    /// there on a spring, rather than flying in from the corner.
    @State private var placed = false
    @Environment(\.accessibilityReduceMotion) private var still

    /// Whether the result can be drawn over the text: the page's font is
    /// here, the selection's place is known and on screen.
    static func fits(_ snap: SelectionSnapshot, room: CGSize) -> Bool {
        snap.canShowInPlace && snap.rect.minX >= 0 && snap.rect.minY >= 0 && snap.rect.minY < room.height
            && snap.rect.minX + max(80, snap.rect.width) <= room.width - 12
    }

    /// The result's lines as wide as the page's: to the right edge of the
    /// block the text sits in (a field's, a paragraph's), not just the
    /// selection's own width, and never past the window.
    static func inkWidth(_ snap: SelectionSnapshot, room: CGSize) -> CGFloat {
        let reach = snap.box.map { $0.maxX - snap.rect.minX } ?? snap.rect.width
        return max(80, min(max(snap.rect.width, reach), room.width - snap.rect.minX - 12))
    }

    /// The bar's corner: its trailing edge just past the end of the last
    /// line, under the result and the original both, so it covers neither;
    /// above the selection when there is no room under it.
    /// `left`: the field's own edge, for words in a field, which the bar
    /// stays inside when there is room.
    static func barOrigin(end: CGPoint, foot: CGFloat, top: CGFloat, bar: CGSize, room: CGSize, left: CGFloat = 12) -> CGPoint {
        let x = min(max(max(12, left), end.x + 16 - bar.width), max(12, room.width - bar.width - 12))
        let below = foot + 8
        if below + bar.height + 12 <= room.height { return CGPoint(x: x, y: below) }
        let above = top - 8 - bar.height
        if above >= 12 { return CGPoint(x: x, y: above) }
        return CGPoint(x: x, y: max(12, room.height - bar.height - 12))
    }

    /// The motion's: chip to bar and the bar following the text, about a
    /// third of a second, overshooting by a couple of points at most.
    static let spring = Animation.spring(duration: 0.32, bounce: 0.12)

    private var written: Bool {
        !commands.output.isEmpty && (commands.stage == .running || commands.stage == .preview)
    }

    private static func font(_ snap: SelectionSnapshot) -> Font {
        let size = CGFloat(max(snap.fontSize, 8))
        return snap.systemFont ? .system(size: size) : .custom(snap.fontFamily, size: size)
    }

    /// Accent at about an eighth, a sixth on a dark page, as the wash of a
    /// selection is lighter than the selection.
    private static func wash(_ snap: SelectionSnapshot) -> Color {
        Color.accentColor.opacity(snap.dark == true ? 0.16 : 0.12)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let snap {
                ink(snap)
                    .offset(x: snap.rect.minX, y: snap.rect.minY)
                    .transition(.opacity.animation(.easeOut(duration: 0.18)))
            }
            if let snap, !commands.replacing {
                // While the words come the bar keeps its place across and
                // goes down with the last line; done, it stands under that
                // line's end, and under the original too, which ⌥ shows.
                let foot = written ? snap.rect.minY + (end?.y ?? snap.rect.height) : snap.rect.maxY
                let tip = commands.stage == .preview && written
                    ? CGPoint(x: snap.rect.minX + (end?.x ?? snap.rect.width), y: max(foot, snap.rect.maxY))
                    : CGPoint(x: snap.rect.maxX, y: foot)
                let origin = Self.barOrigin(end: tip, foot: tip.y, top: snap.rect.minY, bar: barSize, room: room,
                                            left: snap.editable ? snap.box?.minX ?? 12 : 12)
                bar(snap)
                    .fixedSize()
                    .background(GeometryReader { size in
                        Color.clear.preference(key: InkBarSize.self, value: size.size)
                    })
                    .onPreferenceChange(InkBarSize.self) { size in
                        if placed { barSize = size; return }
                        withTransaction(Transaction(animation: nil)) { barSize = size }
                        DispatchQueue.main.async { placed = true }
                    }
                    .opacity(barSize == .zero ? 0 : 1)
                    .position(x: origin.x + barSize.width / 2, y: origin.y + barSize.height / 2)
                    .animation(placed && !still ? Self.spring : nil, value: origin)
                    .transition(still ? .opacity : .asymmetric(
                        insertion: .scale(scale: 0.96, anchor: .top).combined(with: .opacity).animation(Self.spring),
                        // Going, in the opposite order: the words first, then the bar.
                        removal: .scale(scale: 0.96, anchor: .top).combined(with: .opacity).animation(Self.spring.delay(0.08))))
            }
        }
        .frame(width: room.width, height: room.height, alignment: .topLeading)
        .animation(still ? .easeOut(duration: 0.15) : Self.spring, value: commands.replacing)
        .animation(still ? .easeOut(duration: 0.15) : Self.spring, value: snap == nil)
        .pageScheme(dark: snap?.dark)
        .onChange(of: snap == nil) { _, gone in
            if gone { placed = false; end = nil }
        }
    }

    // MARK: The words

    @ViewBuilder
    private func ink(_ snap: SelectionSnapshot) -> some View {
        let width = Self.inkWidth(snap, room: room)
        let wash = Self.wash(snap)
        ZStack(alignment: .topLeading) {
            if written {
                // The original under them, hidden while the result shows,
                // and its selection to the end of each of its lines.
                snap.ground
                    .frame(width: max(snap.rect.width, width) + 8, height: snap.rect.height + 4)
                    .offset(x: -4, y: -2)
                words(snap, width: width, wash: wash)
            } else if commands.stage == .running {
                // Nothing in yet: the selected words washed, as they will be.
                Rectangle().fill(wash)
                    .frame(width: snap.rect.width, height: snap.rect.height)
            }
        }
        .opacity(commands.showOriginal ? 0 : 1)
        .allowsHitTesting(false)
    }

    private func words(_ snap: SelectionSnapshot, width: CGFloat, wash: Color) -> some View {
        Text(commands.output)
            .font(Self.font(snap))
            .lineSpacing(snap.extraLineSpacing)
            .foregroundStyle(snap.foreground)
            .frame(width: width, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .backgroundPreferenceValue(Text.LayoutKey.self) { layouts in
                GeometryReader { geo in
                    let lines = Self.lines(layouts, in: geo)
                    ZStack(alignment: .topLeading) {
                        // The block on the page's ground, so its words below
                        // don't show between these lines.
                        snap.ground.padding(-2)
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            Rectangle().fill(wash)
                                .frame(width: line.width + 2, height: line.height)
                                .offset(x: line.minX - 1, y: line.minY)
                                .opacity(commands.replacing ? 0 : 1)
                                .animation(.easeOut(duration: 0.25), value: commands.replacing)
                        }
                    }
                }
            }
            .overlayPreferenceValue(Text.LayoutKey.self) { layouts in
                GeometryReader { geo in
                    let last = Self.lines(layouts, in: geo).last
                    ZStack(alignment: .topLeading) {
                        Color.clear.preference(key: InkEnd.self,
                                               value: CGPoint(x: last?.maxX ?? geo.size.width, y: max(last?.maxY ?? 0, geo.size.height)))
                        if let last, commands.stage == .running {
                            InkCaret(height: last.height)
                                .offset(x: last.maxX + 1, y: last.minY)
                        }
                    }
                }
            }
            .onPreferenceChange(InkEnd.self) { end = $0 }
    }

    /// Each line's typographic box, in the text's own frame.
    private static func lines(_ layouts: [Text.LayoutKey.AnchoredLayout], in geo: GeometryProxy) -> [CGRect] {
        guard let first = layouts.first else { return [] }
        let at = geo[first.origin]
        return first.layout.map { $0.typographicBounds.rect.offsetBy(dx: at.x, dy: at.y) }
    }

    // MARK: The bar

    private func bar(_ snap: SelectionSnapshot) -> some View {
        HStack(spacing: 6) {
            Symbol("spark", size: 13)
                .foregroundStyle(Color.accentColor)
            status
                .pointerTip(source)
            Spacer(minLength: commands.stage == .running ? 0 : 6)
            actions(snap)
        }
        .font(.system(size: 12.5))
        .barFrame()
        .animation(still ? nil : Self.spring, value: commands.stage)
    }

    @ViewBuilder
    private var status: some View {
        switch commands.stage {
        case .running:
            Shimmer(text: runningVerb, size: 12.5)
        case .failed:
            Text(commands.error)
                .foregroundStyle(ButtonCSS.danger)
                .lineLimit(1)
                .frame(maxWidth: max(120, min(360, room.width - 260)), alignment: .leading)
        default:
            HStack(spacing: 6) {
                Text(doneVerb).foregroundStyle(Palette.muted)
                // Held, the original shows in place: the key and its word
                // light up, nothing moves.
                if room.width > 420 {
                    KeyGlyphs(keys: "⌥", size: 12.5, tint: commands.showOriginal ? Palette.ink : Palette.faint)
                    Text("original").foregroundStyle(commands.showOriginal ? Palette.ink : Palette.faint)
                }
            }
            .lineLimit(1)
        }
    }

    @ViewBuilder
    private func actions(_ snap: SelectionSnapshot) -> some View {
        switch commands.stage {
        case .running:
            Button { commands.close() } label: {
                HStack(spacing: 6) { Text("Stop"); KeyGlyphs(keys: "esc", size: 12.5, tint: nil) }
            }
            .buttonStyle(.yab(.quiet, .regular))
        case .failed:
            if !commands.output.isEmpty {
                Button("Copy") { commands.copy() }
                    .buttonStyle(.yab(.primary, .regular))
            } else if commands.command?.executor == "mac" && !commands.noChange {
                Button("Ask " + commands.retryName) { commands.retryWithAgent() }
                    .buttonStyle(.yab(.primary, .regular))
            }
            Button("Close") { commands.close() }
                .buttonStyle(.yab(.secondary, .regular))
        default:
            if room.width > 640, let command = commands.command {
                Button { commands.run(command) } label: {
                    HStack(spacing: 6) { Text("Again"); ShortcutGlyphs(.selectionRetry, size: 12.5, tint: nil) }
                }
                .buttonStyle(.yab(.quiet, .regular))
            }
            if commands.canReplace(snap) {
                Button { commands.copy() } label: {
                    HStack(spacing: 6) { Text("Copy"); if room.width > 480 { ShortcutGlyphs(.selectionCopy, size: 12.5, tint: nil) } }
                }
                .buttonStyle(.yab(.quiet, .regular))
                Button { commands.apply() } label: {
                    HStack(spacing: 6) { Text("Replace"); KeyGlyphs(keys: "↩", size: 12.5, tint: nil) }
                }
                .buttonStyle(.yab(.primary, .regular))
            } else {
                // Words on a page that can't be written to: Return copies them.
                Button { commands.apply() } label: {
                    HStack(spacing: 6) { Text("Copy"); KeyGlyphs(keys: "↩", size: 12.5, tint: nil) }
                }
                .buttonStyle(.yab(.primary, .regular))
            }
        }
    }

    /// Where it runs, for the bar's tip: this Mac or the agent's name.
    private var source: String {
        guard let command = commands.command else { return "" }
        switch commands.runner(command) {
        case nil: return "Connect an agent"
        case "mac": return "On this Mac"
        case let cli? where AgentPlan.isPlan(cli): return commands.agentTitle(command) + (tab.shy ? " · leaves this Mac" : "")
        default: return ""
        }
    }

    private var runningVerb: String {
        switch commands.command?.id {
        case "improve": return "Improving…"
        case "fix": return "Fixing…"
        case "shorter": return "Shortening…"
        case "longer": return "Expanding…"
        case "formal": return "Making more formal…"
        case "friendly": return "Making friendlier…"
        case "translate": return "Translating…"
        default: return "Writing…"
        }
    }

    private var doneVerb: String {
        switch commands.command?.id {
        case "improve": return "Improved"
        case "fix": return "Fixed"
        case "shorter": return "Shortened"
        case "longer": return "Expanded"
        case "formal": return "Made more formal"
        case "friendly": return "Made friendlier"
        case "translate": return "Translated"
        default: return commands.command.map { SelectionCommand.menuTitle($0.name) } ?? "Ready"
        }
    }
}

/// The caret at the end of words still coming: the accent, blinking once
/// a second, still when motion is reduced.
private struct InkCaret: View {
    let height: CGFloat
    @Environment(\.accessibilityReduceMotion) private var still

    var body: some View {
        if still {
            Rectangle().fill(Color.accentColor).frame(width: 2, height: height)
        } else {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                Rectangle().fill(Color.accentColor).frame(width: 2, height: height)
                    .opacity(Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0 ? 1 : 0)
            }
        }
    }
}

private struct InkEnd: PreferenceKey {
    static let defaultValue: CGPoint? = nil
    static func reduce(value: inout CGPoint?, nextValue: () -> CGPoint?) { value = nextValue() ?? value }
}

private struct InkBarSize: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}
