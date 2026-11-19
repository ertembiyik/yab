import AppKit
import SwiftUI

// Themes & Settings, the card Aa opens beside reading mode's book, as
// Apple Books has it (the Oct 21 prototype, reader.html, picked as drawn):
// the text smaller and larger, a wider page, light or dark, the six themes
// each drawn in its own face and colors, and Customize, which slides the
// card over to the face and the spacing. There is no preview: the article
// beside it is the preview, and changes as you go.
//
// The card is laid over the window, as a held door's list is (DoorList),
// and takes presses only on itself: a press anywhere else, the article
// too, puts it away, and goes on to where it was pressed. Escape puts the
// light's menu away, then the card. ⌘+ and ⌘− change the size with or
// without it (Browser.zoom).

/// Aa, beside the book while a page is read: the card's door. Lit, ink
/// under ground, while its card is out, as the prototype draws it.
struct ThemesDoor: View {
    let browser: Browser
    var tab: Tab
    private var card = ReaderCard.shared
    @Environment(\.tone) private var tone
    @Environment(\.doorSize) private var size
    @State private var hovering = false
    @State private var box = ViewBox()

    var body: some View {
        let open = card.isOpen && card.tabID == tab.id
        Button { card.toggle(browser: browser, tab: tab, from: box.view) } label: {
            Text("Aa")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(open ? Palette.ground : hovering ? Palette.ink.opacity(0.88) : Palette.muted(on: tone))
                .frame(width: size.side, height: size.side)
                .contentShape(RoundedRectangle(cornerRadius: size.corner, style: .continuous))
        }
        .buttonStyle(Door.Give())
        .focusable(false)
        .background(
            RoundedRectangle(cornerRadius: size.corner, style: .continuous)
                .fill(open ? Palette.ink : hovering ? Palette.hover(on: tone) : .clear)
        )
        .onHover { hovering = $0 }
        .keyTip("Themes & Settings")
        .accessibilityLabel("Themes & Settings")
        .benchSpot("reader themes")
        .background(CardAnchor(box: box))
        .onAppear { card.doors[tab.id] = box }
        .onDisappear { card.left(tab.id, door: box) }
    }
}

/// The door's own view, for the card to hang from.
private struct CardAnchor: NSViewRepresentable {
    let box: ViewBox
    func makeNSView(context: Context) -> NSView {
        let view = Through()
        box.view = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { box.view = view }

    final class Through: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

@MainActor
@Observable final class ReaderCard {
    static let shared = ReaderCard()

    enum Page { case main, customize }

    private(set) var isOpen = false
    private(set) var tabID: Tab.ID?
    var page: Page = .main
    /// Customize's list of faces, open.
    var fonts = false
    /// The light's menu, under ◐.
    var menu = false
    /// In or on its way out: what the card's scale and fade follow.
    fileprivate(set) var shown = false
    /// Whether the Mac reads dark where the card hangs, for Match the Mac.
    fileprivate(set) var systemDark = false

    /// Each tab's Aa, while it is in sight.
    @ObservationIgnored var doors: [Tab.ID: ViewBox] = [:]

    /// The card's own width, inside its inset, as drawn: 330 across.
    static let width: CGFloat = 306
    /// Between the door and the card's top.
    static let gap: CGFloat = 6
    /// Room round the card for its shadow.
    static let margin: CGFloat = PullView.margin
    nonisolated static let space = "reader-card"

    @ObservationIgnored private weak var browser: Browser?
    @ObservationIgnored private weak var tab: Tab?
    @ObservationIgnored private weak var anchor: NSView?
    @ObservationIgnored private var host: Host?
    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private var watchers: [NSObjectProtocol] = []
    /// The card, in the host's points from its top left.
    @ObservationIgnored fileprivate var cardRect: CGRect = .zero

    func toggle(browser: Browser, tab: Tab, from view: NSView?) {
        if isOpen, tabID == tab.id { close() } else { present(browser, tab, from: view) }
    }

    /// From View › Reading Appearance, or the bench: from the tab's Aa, or
    /// with none in sight (the column down the side, no address bar) from
    /// the page's top right corner.
    func open(browser: Browser) {
        guard let tab = browser.active, tab.reader, !(isOpen && tabID == tab.id) else { return }
        present(browser, tab, from: doors[tab.id]?.view)
    }

    /// A tab's Aa gone, or its page no longer read: its card goes with it.
    func left(_ id: Tab.ID, door: ViewBox? = nil) {
        if let door, doors[id] === door { doors[id] = nil }
        if isOpen, tabID == id { close() }
    }

    private func present(_ browser: Browser, _ tab: Tab, from view: NSView?) {
        close(animated: false)
        guard tab.reader else { return }
        let door = view?.window != nil ? view : nil
        guard let window = door?.window ?? tab.builtPage?.window, let content = window.contentView else { return }
        self.browser = browser
        self.tab = tab
        anchor = door
        page = .main
        fonts = false
        menu = false
        shown = false
        systemDark = (door ?? content).effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let host = Host(rootView: ReaderCardView(card: self, style: .shared))
        host.card = self
        host.safeAreaRegions = []
        let top = content.superview ?? content
        top.addSubview(host, positioned: .above, relativeTo: top === content ? nil : content)
        self.host = host
        tabID = tab.id
        isOpen = true
        fit()
        watch(window)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.host === host else { return }
            withAnimation(Motion.glide) { self.shown = true }
        }
    }

    func close(animated: Bool = true) {
        guard let host else { return }
        unwatch()
        self.host = nil
        isOpen = false
        tabID = nil
        menu = false
        fonts = false
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            shown = false
            host.removeFromSuperview()
            return
        }
        withAnimation(Motion.depart) { shown = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { host.removeFromSuperview() }
    }

    func go(_ page: Page) {
        menu = false
        if page == .main { fonts = false }
        withAnimation(Motion.glide) { self.page = page }
    }

    /// Laid under its door, its right edge on the door's, its top a gap
    /// under it, as tall as the window leaves below.
    fileprivate func fit() {
        guard let host, let top = host.superview, let window = host.window else { return }
        let door: NSRect
        if let anchor, anchor.window === window {
            door = anchor.convert(anchor.bounds, to: nil)
        } else if let web = tab?.builtPage, web.window === window {
            let page = web.convert(web.bounds, to: nil)
            door = NSRect(x: page.maxX - 8, y: page.maxY - 2, width: 0, height: 0)
        } else {
            let room = top.convert(top.bounds, to: nil)
            door = NSRect(x: room.maxX - 8, y: room.maxY - 44, width: 0, height: 0)
        }
        let m = Self.margin
        let room = top.convert(top.bounds, to: nil)
        let width = Self.width + 2 * CardFrame.inset + 2 * m
        var x = door.maxX + m - width
        x = min(max(x, room.minX - m + 8), room.maxX + m - 8 - width)
        let ceiling = door.minY - Self.gap + m
        let rect = NSRect(x: x, y: room.minY, width: width, height: max(0, ceiling - room.minY))
        let frame = top.convert(rect, from: nil).integral
        if host.frame != frame { host.frame = frame }
    }

    /// The card, in the window's points from its top left, for the bench.
    var benchRect: CGRect? {
        guard let host, let content = host.window?.contentView else { return nil }
        let local = NSRect(x: cardRect.minX, y: host.isFlipped ? cardRect.minY : host.bounds.height - cardRect.maxY,
                           width: cardRect.width, height: cardRect.height)
        let frame = host.convert(local, to: nil)
        return CGRect(x: frame.minX, y: content.bounds.height - frame.maxY, width: frame.width, height: frame.height)
    }

    private func watch(_ window: NSWindow) {
        unwatch()
        let presses = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self, let host, event.window === host.window else { return event }
            if host.holds(event.locationInWindow) { return event }
            // The door again: its own press toggles.
            if let anchor, anchor.window === event.window, anchor.convert(anchor.bounds, to: nil).contains(event.locationInWindow) { return event }
            close()
            return event
        }
        let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let host, event.window === host.window, event.keyCode == 53,
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return event }
            if menu { menu = false } else { close() }
            return nil
        }
        monitors = [presses, keys].compactMap { $0 }
        watchers = [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification].map {
            NotificationCenter.default.addObserver(forName: $0, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.fit() }
            }
        }
    }

    private func unwatch() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        watchers.forEach { NotificationCenter.default.removeObserver($0) }
        watchers = []
    }

    /// Takes presses only on the card: the article beside it stays the
    /// article's, under the pointer and to the click that puts the card away.
    final class Host: NSHostingView<ReaderCardView> {
        weak var card: ReaderCard?
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        func holds(_ inWindow: NSPoint) -> Bool {
            guard let card else { return false }
            let local = convert(inWindow, from: nil)
            let y = isFlipped ? local.y : bounds.height - local.y
            return card.cardRect.contains(CGPoint(x: local.x, y: y))
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let superview, holds(superview.convert(point, to: nil)) else { return nil }
            return super.hitTest(point)
        }
    }
}

struct ReaderCardView: View {
    var card: ReaderCard
    var style: ReaderStyle
    @Environment(\.accessibilityReduceMotion) private var still
    /// The window's light or dark, read outside the card's own: Match the
    /// Mac follows it while the card is out, not only as it opened.
    @Environment(\.colorScheme) private var window
    @State private var scrolled: CGFloat = 0

    private var prefs: ReaderPrefs { style.prefs }

    var body: some View {
        let dark = prefs.isDark(system: card.systemDark)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                // The card's glass and inset, the pages sliding inside its
                // curve and nowhere past it.
                face
                    .frame(width: ReaderCard.width)
                    .padding(CardFrame.inset)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                    .barFrame(inset: 0, corner: Radius.card)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(ReaderCard.space)) } action: { card.cardRect = $0 }
            }
            Spacer(minLength: 0)
        }
        .padding(ReaderCard.margin)
        .scaleEffect(card.shown || still ? 1 : 0.92, anchor: .topTrailing)
        .opacity(card.shown ? 1 : 0)
        .coordinateSpace(name: ReaderCard.space)
        .environment(\.colorScheme, dark ? .dark : .light)
        .onChange(of: window) { _, scheme in card.systemDark = scheme == .dark }
    }

    // MARK: the two pages

    private var face: some View {
        ZStack(alignment: .top) {
            if card.page == .main {
                main.transition(.offset(x: -26).combined(with: .opacity))
            } else {
                customize.transition(.offset(x: 26).combined(with: .opacity))
            }
        }
    }

    private var main: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Themes & Settings")
                    .font(.system(size: 13.5, weight: .semibold))
                Spacer(minLength: 0)
                Button { card.close() } label: { Symbol("xmark", size: 11, weight: .semibold) }
                    .buttonStyle(.yab(.secondary, .regular, icon: .round))
                    .focusable(false)
                    .keyTip("Close")
                    .accessibilityLabel("Close")
            }
            .frame(height: 30)
            pills
            tiles
            Button { card.go(.customize) } label: {
                HStack(spacing: 8) {
                    Symbol("slider.horizontal.2", size: 13)
                    Text("Customize")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.yab(.secondary, .large, capsule: true))
        }
        .foregroundStyle(Palette.ink)
        .contentShape(Rectangle())
        .onTapGesture { card.menu = false }
        .overlay(alignment: .topTrailing) {
            if card.menu {
                modes
                    .offset(y: 84)
                    .transition(.scale(scale: 0.95, anchor: .topTrailing).combined(with: .opacity))
            }
        }
        .animation(Motion.quick, value: card.menu)
    }

    private var pills: some View {
        let look = prefs.look
        return HStack(spacing: 8) {
            pill {
                Button { style.prefs.step(-1) } label: { Text("A").font(.system(size: 12.5, weight: .medium)) }
                    .buttonStyle(PillPress())
                    .disabled(look.size <= 0)
                    .accessibilityLabel("Smaller Text")
                Button { style.prefs.step(1) } label: { Text("A").font(.system(size: 20, weight: .medium)) }
                    .buttonStyle(PillPress())
                    .disabled(look.size >= ReaderLook.sizes.count - 1)
                    .accessibilityLabel("Larger Text")
            }
            pill {
                Button { card.menu = false; style.prefs.wide.toggle() } label: { Symbol("text.alignleft", size: 14) }
                    .buttonStyle(PillPress(on: prefs.wide))
                    .accessibilityLabel("Wide Page")
                    .accessibilityAddTraits(prefs.wide ? .isSelected : [])
                Button { card.menu.toggle() } label: { Symbol("circle.lefthalf.filled", size: 14) }
                    .buttonStyle(PillPress(on: card.menu))
                    .accessibilityLabel("Appearance")
            }
        }
    }

    private func pill<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 0) { content() }
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(Palette.ink.opacity(0.08))
            .overlay(Rectangle().fill(Palette.ink.opacity(0.18)).frame(width: 1, height: 20))
            .clipShape(Capsule())
    }

    /// Match the Mac, Light, Dark: the list under ◐, checked.
    private var modes: some View {
        VStack(spacing: 0) {
            ForEach(ReaderMode.allCases, id: \.self) { mode in
                Button {
                    style.prefs.mode = mode
                    card.menu = false
                } label: {
                    HStack(spacing: 8) {
                        Symbol("checkmark", size: 11, weight: .semibold)
                            .opacity(prefs.mode == mode ? 1 : 0)
                            .frame(width: 14)
                        Text(mode.title).font(.system(size: 13))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 30)
                    .contentShape(Rectangle())
                }
                .buttonStyle(RowPress())
                .accessibilityAddTraits(prefs.mode == mode ? .isSelected : [])
            }
        }
        .dropFrame(width: 150)
    }

    private var tiles: some View {
        let dark = prefs.isDark(system: card.systemDark)
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(ReaderThemeSpec.ordered, id: \.id) { spec in
                tile(spec, colors: prefs.colors(spec.id, dark: dark))
            }
        }
    }

    private func tile(_ spec: ReaderThemeSpec, colors: ReaderColors) -> some View {
        ReaderThemeTile(spec: spec, colors: colors, picked: prefs.theme == spec.id, edited: prefs.edited(spec.id)) {
            card.menu = false
            style.prefs.theme = spec.id
        }
    }

    // MARK: Customize

    private var customize: some View {
        let spec = prefs.spec
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button { card.go(.main) } label: { Symbol("chevron.left", size: 11, weight: .semibold) }
                    .buttonStyle(.yab(.secondary, .regular, icon: .round))
                    .focusable(false)
                    .accessibilityLabel("Back")
                (Text("Customize ") + Text(spec.name).fontWeight(.regular).foregroundColor(Palette.ink.opacity(0.6)))
                    .font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button("Reset") { style.prefs.reset() }
                    .buttonStyle(.yab(.secondary, .regular, capsule: true))
                    .disabled(!prefs.edited(prefs.theme))
            }
            .frame(height: 30)
            ThreadScrollView(.vertical) {
                knobs
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { scrolled = $0 }
            }
            .scrollIndicators(.never)
            .frame(height: min(max(scrolled, 1), 470))
        }
        .foregroundStyle(Palette.ink)
    }

    private var knobs: some View {
        let look = prefs.look
        let spec = prefs.spec
        return VStack(alignment: .leading, spacing: 10) {
            section("Text")
            group {
                HStack(spacing: 10) {
                    Text("Aa").font(look.font.font(size: 13, weight: .semibold)).frame(width: 20).opacity(0.85)
                    Text("Font")
                    Spacer(minLength: 0)
                    Button { withAnimation(Motion.glide) { card.fonts.toggle() } } label: {
                        HStack(spacing: 6) {
                            Text(look.font == spec.look.font ? "\(spec.name)\u{2019}s" : look.font.title)
                            Symbol("chevron.right", size: 9, weight: .semibold)
                                .rotationEffect(.degrees(card.fonts ? 90 : 0))
                        }
                        .opacity(0.75)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Font")
                }
                .row()
                if card.fonts {
                    fontRow("\(spec.name)\u{2019}s font", face: spec.look.font, picked: look.font == spec.look.font) { $0.font = spec.look.font }
                    ForEach(ReaderFont.allCases, id: \.self) { face in
                        fontRow(face.title, hint: face.hint, face: face, picked: look.font == face && face != spec.look.font) { $0.font = face }
                    }
                }
                line
                HStack(spacing: 10) {
                    Text("B").font(.system(size: 13, weight: .bold)).frame(width: 20).opacity(0.85)
                    Text("Bold Text")
                    Spacer(minLength: 0)
                    toggle("Bold Text", look.bold) { on in style.prefs.change { $0.bold = on } }
                }
                .row()
            }
            section("Spacing")
            group {
                slider("Line spacing", value: look.line, range: ReaderLook.lines, step: 0.05,
                       text: String(format: "%.2f", look.line), changed: abs(look.line - spec.look.line) > 0.001,
                       set: { v in style.prefs.change { $0.line = (v * 20).rounded() / 20 } }, restore: { style.prefs.restore(\.line) })
                line
                slider("Character spacing", value: Double(look.letter), range: ReaderLook.letters, step: 1,
                       text: "\(look.letter)%", changed: look.letter != spec.look.letter,
                       set: { v in style.prefs.change { $0.letter = Int(v.rounded()) } }, restore: { style.prefs.restore(\.letter) })
                line
                slider("Word spacing", value: Double(look.word), range: ReaderLook.words, step: 2,
                       text: "\(look.word)%", changed: look.word != spec.look.word,
                       set: { v in style.prefs.change { $0.word = Int(v.rounded()) } }, restore: { style.prefs.restore(\.word) })
                line
                slider("Margins", value: Double(look.margins), range: ReaderLook.marginRange, step: 2,
                       text: (look.margins > 0 ? "+" : "") + "\(look.margins)%", changed: look.margins != spec.look.margins,
                       set: { v in style.prefs.change { $0.margins = Int(v.rounded()) } }, restore: { style.prefs.restore(\.margins) })
                line
                HStack(spacing: 10) {
                    Text("Justify Text")
                    Spacer(minLength: 0)
                    toggle("Justify Text", look.justify) { on in style.prefs.change { $0.justify = on } }
                }
                .row()
            }
        }
        .font(.system(size: 13))
    }

    private func section(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12.5, weight: .semibold))
            .opacity(0.8)
            .padding(.horizontal, 2)
    }

    private func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(Palette.ink.opacity(0.07), in: RoundedRectangle(cornerRadius: Radius.floating, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: Radius.floating, style: .continuous))
    }

    private var line: some View {
        Rectangle().fill(Palette.ink.opacity(0.1)).frame(height: 1)
    }

    private func toggle(_ title: String, _ on: Bool, _ set: @escaping (Bool) -> Void) -> some View {
        Toggle(title, isOn: Binding(get: { on }, set: set))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(Color(nsColor: .systemGreen))
    }

    private func fontRow(_ title: String, hint: String? = nil, face: ReaderFont, picked: Bool,
                         _ pick: @escaping (inout ReaderLook) -> Void) -> some View {
        VStack(spacing: 0) {
            line
            Button { style.prefs.change(pick) } label: {
                HStack(spacing: 10) {
                    Color.clear.frame(width: 20, height: 1)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(title).font(face.font(size: 15))
                        if let hint { Text(hint).font(.system(size: 11.5)).opacity(0.55) }
                    }
                    Spacer(minLength: 0)
                    Symbol("checkmark", size: 11, weight: .semibold).opacity(picked ? 1 : 0)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 38)
                .contentShape(Rectangle())
            }
            .buttonStyle(RowPress(corner: 0))
            .accessibilityAddTraits(picked ? .isSelected : [])
        }
    }

    private func slider(_ title: String, value: Double, range: ClosedRange<Double>, step: Double, text: String, changed: Bool,
                        set: @escaping (Double) -> Void, restore: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer(minLength: 0)
                Text(text).monospacedDigit().opacity(changed ? 1 : 0.6)
            }
            .font(.system(size: 12.5))
            // Stepped in `set`, with no ticks under the track, as drawn.
            Slider(value: Binding(get: { value }, set: { set(($0 / step).rounded() * step) }), in: range)
                .controlSize(.small)
                .tint(Palette.ink)
                .labelsHidden()
                .accessibilityLabel(title)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        // Twice on the row, its slider among it: back to the theme's own.
        .simultaneousGesture(TapGesture(count: 2).onEnded { restore() })
    }
}

private extension View {
    /// A row of Customize's groups: the room at its sides, at least the
    /// prototype's 40 tall.
    func row() -> some View {
        padding(.horizontal, 12).frame(minHeight: 40)
    }
}

/// Half of a pill: the whole half lit under the pointer and pressed, its
/// pill clipping it to the round; lit too while it is on.
private struct PillPress: ButtonStyle {
    var on = false
    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration, on: on)
    }

    private struct Face: View {
        let configuration: Configuration
        let on: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(Palette.ink)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .background(Palette.ink.opacity(configuration.isPressed ? 0.16 : on ? 0.2 : hovering ? 0.08 : 0))
                .opacity(enabled ? 1 : 0.3)
                .onHover { hovering = $0 && enabled }
                .animation(Motion.quick, value: hovering)
        }
    }
}

/// A row in a list on the card: lit under the pointer, a little more
/// pressed.
private struct RowPress: ButtonStyle {
    var corner: CGFloat = Radius.control
    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration, corner: corner)
    }

    private struct Face: View {
        let configuration: Configuration
        let corner: CGFloat
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(Palette.ink.opacity(configuration.isPressed ? 0.12 : hovering ? 0.08 : 0),
                            in: RoundedRectangle(cornerRadius: corner, style: .continuous))
                .onHover { hovering = $0 }
        }
    }
}

// MARK: - the bench

extension Bench {
    /// The card, worked without a pointer, for evals/reader-themes/card.py:
    /// "open", "close", "page" (main, customize), "theme", "step" (±1),
    /// "wide", "menu", "mode", "fonts", "font", "bold", "justify", "set"
    /// with "knob" (line, letter, word, margins) and "value", "restore"
    /// with "knob", "reset", "defaults" (every theme as it comes); each
    /// answers the state after it.
    func readerCardCommand(_ request: [String: Any], browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        let card = ReaderCard.shared
        let style = ReaderStyle.shared
        let value = request["value"]
        switch request["action"] as? String ?? "state" {
        case "open": card.open(browser: browser)
        case "close": card.close()
        case "page": card.go(value as? String == "customize" ? .customize : .main)
        case "theme": if let id = (value as? String).flatMap(ReaderThemeID.init) { style.prefs.theme = id }
        case "step": style.prefs.step(value as? Int ?? 1)
        case "wide": style.prefs.wide = value as? Bool ?? !style.prefs.wide
        case "menu": card.menu = value as? Bool ?? !card.menu
        case "mode": if let mode = (value as? String).flatMap(ReaderMode.init) { style.prefs.mode = mode }
        case "fonts": card.fonts = value as? Bool ?? !card.fonts
        case "font": if let face = (value as? String).flatMap(ReaderFont.init) { style.prefs.change { $0.font = face } }
        case "bold": style.prefs.change { $0.bold = value as? Bool ?? !$0.bold }
        case "justify": style.prefs.change { $0.justify = value as? Bool ?? !$0.justify }
        case "set":
            let number = (value as? Double) ?? (value as? Int).map(Double.init) ?? 0
            switch request["knob"] as? String {
            case "line": style.prefs.change { $0.line = number }
            case "letter": style.prefs.change { $0.letter = Int(number) }
            case "word": style.prefs.change { $0.word = Int(number) }
            case "margins": style.prefs.change { $0.margins = Int(number) }
            case "size": style.prefs.change { $0.size = Int(number) }
            default: break
            }
        case "restore":
            switch request["knob"] as? String {
            case "line": style.prefs.restore(\.line)
            case "letter": style.prefs.restore(\.letter)
            case "word": style.prefs.restore(\.word)
            case "margins": style.prefs.restore(\.margins)
            default: break
            }
        case "reset": style.prefs.reset()
        case "defaults": style.prefs = ReaderPrefs()
        default: break
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (request["wait"] as? Double ?? 0.5)) {
            let prefs = style.prefs
            var out: [String: Any] = [
                "open": card.isOpen, "page": card.page == .main ? "main" : "customize", "menu": card.menu, "fonts": card.fonts,
                "theme": prefs.theme.rawValue, "mode": prefs.mode.rawValue, "wide": prefs.wide, "points": prefs.look.points,
                "font": prefs.look.font.rawValue, "edited": ReaderThemeID.allCases.filter(prefs.edited).map(\.rawValue),
            ]
            if let rect = card.benchRect { out["card"] = [rect.minX, rect.minY, rect.width, rect.height].map(Double.init) }
            answer(out)
        }
    }
}
