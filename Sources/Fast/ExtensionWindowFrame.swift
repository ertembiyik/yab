import AppKit
import Combine
import SwiftUI

// The window an extension opens for a page of its own, chrome.windows.create
// with type "popup" (Bitwarden's passkey prompt, its pop-outs), on either
// engine: one frame, written once. ExtensionPopout (WebKit) and
// ChromiumExtensionWindow (Chromium) give it the page's view and who it is
// for, and keep what their engine needs to hear; everything the window is
// and where it stands is here.
//
// The design: it
// stands just under the extension's pinned button, the button lit while it
// is up, which is all that ties it to the button: no tail, it is a window,
// not a popover, as Chrome's and Safari's are. The frame is Liquid Glass tinted with the space's color, as the
// ⌘L field and the Small Window wear it; the page lies in it as a card,
// under the header the extension's side panel has (ChromiumSidePanelColumn):
// its icon and name, the site it is acting for, and the cross.
//
// A window of its own, all the same: it moves, it is resized, ⌘W closes it,
// and the extension keeps it by its id and closes it itself. Escape is the
// page's. With no pin to stand under (not pinned, the band away in full
// screen) it stands where the extension asked, else by the browser
// window's top right, as Chrome's popup window does.

@MainActor
final class ExtensionWindowFrame: NSObject, NSWindowDelegate {
    /// Open ones, oldest first.
    private(set) static var open: [ExtensionWindowFrame] = []

    /// Who the window is for, as its header says it.
    struct Owner {
        /// The extension's id, as its pin knows it: WebKit's unique
        /// identifier, Chrome's 32 letters.
        let id: String
        let name: String
        /// Its icon; nil draws the header without one.
        let button: Extensions.Button?
    }

    /// What the header draws.
    @MainActor
    final class Model {
        let owner: Owner
        let close: () -> Void
        init(owner: Owner, close: @escaping () -> Void) {
            self.owner = owner
            self.close = close
        }
    }

    /// The pins lit by an open window, by extension id (PlatePin).
    @MainActor
    @Observable final class Hung {
        static let shared = Hung()
        private(set) var ids: Set<String> = []
        fileprivate func update() {
            let now = Set(ExtensionWindowFrame.open.map(\.owner.id))
            if now != ids { ids = now }
        }
    }

    // MARK: - measures (design: the header, ChromiumSidePanelColumn's)

    /// Round the header and the page.
    static let inset: CGFloat = 4
    /// The frame's corner, a panel's.
    static let corner: CGFloat = Radius.floating
    /// The page's, concentric with the frame's, the inset in.
    static let pageCorner: CGFloat = Radius.floating - inset // design: concentric with the frame's corner, the inset in
    /// Under its pin, and in from the browser window's edges: the
    /// page's own inset, so it lines up with the column and the page.
    static let margin: CGFloat = Backdrop.inset
    static var header: CGFloat { SideBar.row }
    /// The frame round a page as wide as the extension asked and the
    /// header over it, as tall as it asked: Chrome's height is its window's
    /// whole, title bar and all, the header standing in for that.
    static func glass(for asked: NSSize) -> NSSize {
        NSSize(width: asked.width + 2 * inset, height: asked.height)
    }

    let window: Panel
    let owner: Owner
    let model: Model
    /// The engine's page, in its card.
    let page: NSView
    private let slot = PageSlot()
    private weak var browser: Browser?
    private var closed = false
    /// The space's light or dark (Look), followed.
    private var looked: AnyCancellable?
    /// The pin it stands under, on the screen, when it does.
    private(set) var underPin: NSRect?

    /// Closed, by any way: once.
    var onClose: (() -> Void)?
    /// Became or stopped being the key window.
    var onKey: ((Bool) -> Void)?

    static func owning(_ window: NSWindow?) -> ExtensionWindowFrame? {
        guard let window else { return nil }
        return open.first { $0.window === window }
    }

    /// Made, not shown yet: `show` puts it under its pin. `asked`: the size the
    /// extension asked for, the page's width and the window's height.
    init(page: NSView, owner: Owner, browser: Browser?, asked: NSSize) {
        self.page = page
        self.owner = owner
        self.browser = browser
        var close: () -> Void = {}
        model = Model(owner: owner, close: { close() })
        let size = Self.glass(for: asked)
        window = Panel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .resizable],
                       backing: .buffered, defer: false)
        super.init()
        close = { [weak self] in self?.close() }
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        // Over a browser window in full screen, as the prompt it is.
        window.collectionBehavior = [.fullScreenAuxiliary]
        // The frame draws itself, round corners and all; the shadow is the
        // system's, round what they draw.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.animationBehavior = .none
        window.title = owner.name
        window.delegate = self
        WindowDrag.keep(window)
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        content.wantsLayer = true
        // Everything in the frame's own round corners, from the first frame:
        // the window's shadow is cast by what it draws, and a square of the
        // material before the glass came cast a square one.
        content.layer?.cornerRadius = Self.corner
        content.layer?.cornerCurve = .continuous
        content.layer?.masksToBounds = true
        let room = NSHostingView(rootView: ExtensionWindowRoom(
            model: model, prefs: browser?.prefs))
        room.safeAreaRegions = []
        room.sizingOptions = []
        room.frame = content.bounds
        room.autoresizingMask = [.width, .height]
        content.addSubview(room)
        page.frame = slot.bounds
        page.autoresizingMask = [.width, .height]
        slot.addSubview(page)
        content.addSubview(slot)
        window.contentView = content
        setMinimum()
        layoutSlot()
        // Light or dark as the space's look has it, the Mac's when it says
        // neither, as the browser window wears it: the glass and the
        // material take it from the window.
        if let prefs = browser?.prefs {
            window.appearance = LookMode(rawValue: prefs.lookMode)?.appearance
            looked = prefs.changes(\.lookMode).receive(on: DispatchQueue.main).sink { [weak self] mode in
                self?.window.appearance = LookMode(rawValue: mode)?.appearance
            }
        }
    }

    /// Under its pin, or where `fallback` puts it, and brought up.
    /// `fallback`: the frame's rect, given the window's.
    func show(focused: Bool, fallback: (NSRect) -> NSRect) {
        Self.open.append(self)
        Self.listen()
        // Its pin lit first: in the column's plate the pins come in with it,
        // and only then is there a pin to stand under. They come in at
        // once, not faded in: a pin still fading is see-through when the
        // window looks for it a turn later, and it stood at the top right
        // instead (frames probe, column open, WebKit).
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { Hung.shared.update() }
        let parent = browser.flatMap { BrowserWindows.shared.window(for: $0) }
        // Where it stands with no pin, at once: the extension reads its
        // frame back before it is up.
        place(fallback(NSRect(origin: .zero, size: window.frame.size)), under: nil)
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.closed else { return }
            // No pin: it stays where it was put, or where the extension has
            // moved it since.
            if let parent {
                parent.contentView?.layoutSubtreeIfNeeded()
                if let pin = Self.pin(self.owner.id, in: parent) {
                    self.place(Self.under(pin, in: parent.frame, size: self.window.frame.size), under: (pin, parent))
                }
            }
            let pin = self.underPin != nil
            if focused {
                NSApp.activate()
                self.window.makeKeyAndOrderFront(nil)
            } else {
                self.window.orderFront(nil)
            }
            self.window.invalidateShadow()
            if Store.testing {
                let frame = self.window.frame
                let pins = AnchorView.census(self.owner.id) + ChromiumPopupAnchor.View.census(self.owner.id)
                FileHandle.standardError.write(Data("YAB_EXTENSION_FRAME open window=\(self.window.windowNumber) pin=\(pin) frame=\([frame.minX, frame.minY, frame.width, frame.height]) parent=\(parent?.windowNumber ?? -1) id=\(self.owner.id) pins=\(pins)\n".utf8))
            }
        }
    }

    /// Where one with no pin stands, given its frame: where the extension
    /// asked, its page's corner there, else by the top right of the window
    /// it came from, as Chrome puts one whose place the extension left out.
    static func standing(_ glass: NSRect, asked: CGPoint?, over parent: NSWindow?) -> NSRect {
        let from = parent?.frame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = asked.map { NSPoint(x: $0.x - inset, y: $0.y) }
            ?? NSPoint(x: from.maxX - 15 + inset - glass.width, y: from.maxY - 90 - glass.height)
        return NSRect(origin: origin, size: glass.size)
    }

    /// Where the extension sees it: the page's width, the frame's height
    /// (Chrome's window, as `glass(for:)` makes it from what was asked).
    var extensionFrame: NSRect {
        get {
            let frame = window.frame
            return NSRect(x: frame.minX + Self.inset, y: frame.minY, width: frame.width - 2 * Self.inset, height: frame.height)
        }
        set {
            guard newValue.width.isFinite, newValue.height.isFinite, newValue.minX.isFinite, newValue.minY.isFinite else { return }
            let glass = NSRect(x: newValue.minX - Self.inset, y: newValue.minY,
                               width: newValue.width + 2 * Self.inset, height: newValue.height)
            window.setFrame(glass.integral, display: true)
        }
    }

    /// Its top the inset under the pin, its leading edge on the pin's
    /// (the column's first pin is the column's inset in), kept the inset in
    /// from the browser window's trailing edge (the band's pins, at its end,
    /// put it flush with the page's edge).
    static func under(_ pin: NSRect, in bounds: NSRect, size: NSSize) -> NSRect {
        let lowest = bounds.minX + margin, highest = bounds.maxX - margin - size.width
        let x = highest >= lowest ? min(max(pin.minX, lowest), highest) : bounds.midX - size.width / 2
        return NSRect(x: x, y: pin.minY - margin - size.height, width: size.width, height: size.height)
    }

    /// Put at `rect`, kept on the screen; `under`: the browser window whose
    /// pin it stands under, if any.
    private func place(_ rect: NSRect, under: (pin: NSRect, parent: NSWindow)?) {
        var rect = rect
        let parent = under?.parent
        let screen = NSScreen.screens.first { $0.frame.intersects(rect) } ?? parent?.screen ?? NSScreen.main
        if let room = screen?.visibleFrame {
            rect.size.width = min(rect.width, room.width)
            if rect.minY < room.minY, parent != nil {
                // Too tall to stand whole under its pin: it gives up height,
                // not its place.
                rect.size.height = rect.maxY - room.minY
                rect.origin.y = room.minY
            }
            rect.size.height = min(rect.height, room.height)
            rect.origin.x = min(max(rect.minX, room.minX), room.maxX - rect.width)
            rect.origin.y = min(max(rect.minY, room.minY), room.maxY - rect.height)
        }
        underPin = under?.pin
        window.setFrame(rect.integral, display: false)
        layoutSlot()
    }

    /// The smallest a person may make it: the extension's 240 × 200, as
    /// before.
    private func setMinimum() {
        window.minSize = NSSize(width: 240 + 2 * Self.inset, height: 200)
    }

    /// The page's card: the inset round it, under the header.
    private func layoutSlot() {
        guard let content = window.contentView else { return }
        let bounds = content.bounds
        slot.frame = NSRect(x: Self.inset, y: Self.inset, width: max(bounds.width - 2 * Self.inset, 1),
                            height: max(bounds.height - Self.header - 2 * Self.inset, 1))
    }

    /// The pin's rect on the screen, where one shows: the plate's in the
    /// column, the band's with the column put away.
    static func pin(_ id: String, in window: NSWindow) -> NSRect? {
        let views: [NSView] = AnchorView.showing(id, in: window) + ChromiumPopupAnchor.View.showing(id, in: window)
        let rects = views.map { window.convertToScreen($0.convert($0.bounds, to: nil)) }
        // The topmost: the band's and the plate's are never both shown.
        return rects.max { $0.maxY < $1.maxY }
    }

    /// Whether a view shows in its window: on it, not hidden, not see-through,
    /// inside its content.
    static func shows(_ view: NSView) -> Bool {
        guard let window = view.window, let content = window.contentView, !view.isHiddenOrHasHiddenAncestor,
              view.bounds.width > 0, view.bounds.height > 0 else { return false }
        var node: NSView? = view
        while let at = node {
            if at.alphaValue <= 0.01 { return false }
            node = at.superview
        }
        return !view.convert(view.bounds, to: content).intersection(content.bounds).isEmpty
    }

    func focus() {
        NSApp.activate()
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    /// Closed: by ⌘W, its cross, the page or the extension.
    func close() { window.performClose(nil) }

    // MARK: - its window

    func windowWillClose(_ notification: Notification) {
        guard !closed else { return }
        closed = true
        looked = nil
        Self.open.removeAll { $0 === self }
        Hung.shared.update()
        window.delegate = nil
        onClose?()
        onClose = nil
    }

    func windowDidResize(_ notification: Notification) {
        layoutSlot()
        window.invalidateShadow()
    }

    func windowDidBecomeKey(_ notification: Notification) { onKey?(true) }
    func windowDidResignKey(_ notification: Notification) { onKey?(false) }

    /// ⌘W closes it, here and not in the browser: the menu's close is the
    /// browser's tab's.
    private static var keys: Any?
    private static func listen() {
        guard keys == nil else { return }
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let made = owning(event.window), Keymap.shared.action(for: event)?.action == .closeTab else { return event }
            made.close()
            return nil
        }
    }

    /// A window with no title bar that takes the keyboard, and closes as a
    /// titled one does when asked to (performClose), its delegate asked.
    final class Panel: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
        override func performClose(_ sender: Any?) {
            if let delegate, delegate.windowShouldClose?(self) == false { return }
            close()
        }
    }

    /// The page's card: its corner, concentric with the frame's.
    private final class PageSlot: NSView {
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.cornerRadius = ExtensionWindowFrame.pageCorner
            layer?.cornerCurve = .continuous
            layer?.masksToBounds = true
            // White behind the page until it paints, as Chrome's popup window.
            layer?.backgroundColor = NSColor.white.cgColor
        }
        required init?(coder: NSCoder) { fatalError("not from a nib") }
    }

}

/// The frame in the space's color, as the Small Window wears it (LinkRoom),
/// never the site's or the extension's.
private struct ExtensionWindowRoom: View {
    let model: ExtensionWindowFrame.Model
    let prefs: Preferences?

    var body: some View {
        if let prefs { Painted(model: model, prefs: prefs) } else { ExtensionWindowFramed(model: model) { Swatch.gray.color(dark: $0, custom: .gray) } }
    }

    private struct Painted: View {
        let model: ExtensionWindowFrame.Model
        var prefs: Preferences

        var body: some View {
            let backdrop = prefs.backdrop, custom = prefs.backdropColor, paint = SpacePaint(prefs)
            ExtensionWindowFramed(model: model) { dark in
                backdrop == .none ? Swatch.gray.color(dark: dark, custom: custom) : paint.color(dark: dark)
            }
        }
    }
}

/// The frame: glass in its ground and the header; the page's card
/// is the window's own view laid over the room under the header.
private struct ExtensionWindowFramed: View {
    let model: ExtensionWindowFrame.Model
    let ground: (Bool) -> NSColor
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let swatch = ground(scheme == .dark)
        let tone = Tone(swatch, lifted: true, glass: LiquidGlass.wanted)
        let shape = RoundedRectangle(cornerRadius: ExtensionWindowFrame.corner, style: .continuous)
        VStack(spacing: 0) {
            ExtensionWindowHeader(model: model)
                .frame(height: ExtensionWindowFrame.header)
                // The header moves the window, all but the cross's end.
                .background(DragStrip(trailing: SideBar.row))
                .padding([.horizontal, .top], ExtensionWindowFrame.inset)
                .toned(tone)
            Color.clear
        }
        .background { ExtensionWindowGlass(shape: shape, ground: Color(nsColor: swatch)) }
        .modifier(SidebarTypography())
        .ignoresSafeArea()
    }
}

/// The header, the extension side panel's: the icon half a row in, the
/// name at a tab's title size, the quiet cross half a row in from the end.
private struct ExtensionWindowHeader: View {
    let model: ExtensionWindowFrame.Model
    @Environment(\.tabTitleSize) private var titleSize
    private static var cross: ButtonSize { SideBar.row >= ButtonSize.regular.height + 8 ? .regular : .small }

    var body: some View {
        let owner = model.owner
        HStack(spacing: SideBar.markGap) {
            if let button = owner.button {
                ExtensionIcon(button: button, size: SideBar.mark)
                    .frame(width: SideBar.mark, height: SideBar.mark)
            }
            // The extension's name alone, as the side panel's header (owner, 2026-11-08).
            Text(owner.name).font(.system(size: titleSize, weight: .medium)).foregroundStyle(Palette.ink)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button { model.close() } label: { Symbol("xmark", size: 13) }
                .buttonStyle(.yab(.quiet, Self.cross, tint: Palette.ink, icon: .square))
                .focusable(false)
                .keyTip("Close", shortcut: "Close Tab")
        }
        .padding(.leading, (SideBar.row - SideBar.mark) / 2) // design: the mark's middle half a row in
        .padding(.trailing, (SideBar.row - Self.cross.height) / 2) // design: the cross's middle half a row in
    }
}

/// Liquid Glass with a breath of the space's ground over a material, as
/// the ⌘L field and the capture bar have it; where the Mac draws no glass,
/// the ground itself with a hairline.
private struct ExtensionWindowGlass: View {
    let shape: RoundedRectangle
    let ground: Color

    var body: some View {
        if #available(macOS 26.0, *), LiquidGlass.wanted {
            ZStack {
                shape.fill(.regularMaterial)
                Color.clear.glassEffect(.regular.tint(ground.opacity(Omnibox.glassTint)), in: shape)
            }
        } else {
            shape
                .fill(ground)
                .overlay(shape.stroke(Palette.hairline, lineWidth: 1))
        }
    }
}
