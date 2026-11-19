import AppKit
import PDFKit
import SwiftUI

// What Fill & Sign draws (docs/pdf-sign.md, the frames in
// docs/prototypes/pdf-sign-2026-10-20): the glass plate at a PDF's foot and
// the bar it opens into, the PDFView laid over the web view while the mode
// is on, with the boxes of the form lit and the words typed into them, the
// sheet a signature is made on, and the corner that offers the reply when
// the PDF came from a mail.

// MARK: - over the page

/// Everything Fill & Sign puts over a tab's page.
struct PDFLayer: View {
    var paper: PDFPaper
    let tab: Tab
    var corner: CGFloat = 0
    var flatTop = false

    var body: some View {
        ZStack {
            if let desk = paper.desk {
                PDFDeskHost(desk: desk, corner: corner, flatTop: flatTop)
                    .transition(.opacity)
            } else if paper.pdf, !paper.fillable {
                PDFFootWatch(paper: paper)
            }
            if paper.plateShown {
                // Under WebKit's own zoom buttons while the PDF is WebKit's,
                // which rise over the page's foot as the pointer moves.
                PDFSignBar(paper: paper, tab: tab)
                    .padding(.bottom, paper.desk == nil ? 4 : 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .transition(.opacity.combined(with: .offset(y: 8)))
            }
            if let desk = paper.desk {
                PDFSheetLayer(desk: desk)
            }
            if let signed = paper.signed, paper.mail != nil, paper.desk == nil {
                // Low as the plate, under WebKit's zoom buttons as they rise.
                PDFSignedCorner(paper: paper, tab: tab, name: signed.lastPathComponent)
                    .padding(.trailing, 16)
                    .padding(.bottom, 4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .transition(.opacity)
            }
        }
        .animation(Motion.morph, value: paper.plateShown)
        .animation(Motion.quick, value: paper.desk == nil)
    }
}

/// The browser a tab's page is in, for what its plate does.
@MainActor
private func browser(of tab: Tab) -> Browser? {
    BrowserWindows.shared.owner(of: tab.id)?.browser ?? Links.browser
}

/// The plate at the foot of a PDF, and the bar it opens into: Fill, Text,
/// Sign, and Done past a rule. On Capture's glass, as the mode bars are.
struct PDFSignBar: View {
    var paper: PDFPaper
    let tab: Tab

    var body: some View {
        HStack(spacing: 4) {
            if let desk = paper.desk {
                PDFDeskModes(desk: desk, paper: paper, tab: tab)
            } else {
                Button { browser(of: tab)?.fillSign(tab) } label: {
                    HStack(spacing: 6) {
                        Symbol("signature", size: 12.5)
                        Text("Fill & Sign")
                    }
                }
                .buttonStyle(.yab(.quiet, .regular))
                .disabled(paper.starting)
            }
        }
        .font(.system(size: 12.5))
        .padding(BarFrame.inset)
        .background { PDFBarGround() }
        .fixedSize()
        .animation(Motion.morph, value: paper.desk == nil)
    }
}

/// The bar's words while the mode is on.
struct PDFDeskModes: View {
    var desk: PDFDesk
    let paper: PDFPaper
    let tab: Tab

    var body: some View {
        ForEach(PDFDeskMode.allCases, id: \.self) { mode in
            let button = Button(mode.title) { desk.set(mode) }
                .buttonStyle(.yab(desk.mode == mode ? .primary : .quiet, .regular))
            if mode == .sign {
                button.contextMenu { signatures }
            } else {
                button
            }
        }
        Rectangle()
            .fill(Palette.hairline)
            .frame(width: 1, height: 16)
            .padding(.horizontal, 2)
        Button {
            if let browser = browser(of: tab) { paper.done(tab, browser: browser) }
        } label: {
            HStack(spacing: 6) {
                Text("Done")
                KeyGlyphs(keys: "⌘↩", size: 12.5, tint: nil, rest: 0.6)
                    .transaction { $0.animation = nil }
            }
        }
        .buttonStyle(.yab(.quiet, .regular))
    }

    /// Sign's menu: the signatures kept, and another made.
    @ViewBuilder
    private var signatures: some View {
        ForEach(desk.kept, id: \.id) { kept in
            Toggle(kept.id.replacingOccurrences(of: "Yab ", with: ""), isOn: Binding(get: { desk.signature?.id == kept.id }, set: { _ in
                desk.use(kept)
                desk.set(.sign)
            }))
        }
        if !desk.kept.isEmpty { Divider() }
        Button("New Signature\u{2026}") { desk.set(.sign); desk.openSheet() }
        Button("New Initials\u{2026}") { desk.set(.sign); desk.openSheet(initials: true) }
    }
}

/// The ground of the plate, the bar and Done's corner: Capture's glass, with
/// an edge and the card's lift, so it reads over white paper as the frames
/// draw it (glass alone is all but gone on a white page).
struct PDFBarGround: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.floating, style: .continuous)
        CaptureGlass(corner: Radius.floating)
            .cast(Shadow.card)
            .overlay(shape.strokeBorder(Color.black.opacity(scheme == .dark ? 0 : 0.1), lineWidth: 1))
    }
}

/// Where the pointer is over a PDF with no form: near the page's foot, the
/// plate comes. Drawn nowhere and never hit.
struct PDFFootWatch: NSViewRepresentable {
    let paper: PDFPaper

    func makeNSView(context: Context) -> FootWatchView {
        let view = FootWatchView()
        view.near = { [weak paper] near in if paper?.near != near { paper?.near = near } }
        return view
    }

    func updateNSView(_ view: FootWatchView, context: Context) {}

    final class FootWatchView: NSView {
        var near: (Bool) -> Void = { _ in }
        /// How far up from the foot the pointer brings the plate.
        static let reach: CGFloat = 96
        private var area: NSTrackingArea?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area) }
            let made = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
            addTrackingArea(made)
            area = made
        }

        override func mouseMoved(with event: NSEvent) {
            let p = convert(event.locationInWindow, from: nil)
            near(p.y < Self.reach)
        }

        override func mouseExited(with event: NSEvent) { near(false) }
    }
}

/// Done's corner for a PDF from a mail: the file, and the reply with it.
struct PDFSignedCorner: View {
    var paper: PDFPaper
    let tab: Tab
    let name: String

    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: 6) {
                Symbol("doc", size: 12.5)
                    .foregroundStyle(Palette.muted)
                Text(name)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
            }
            .padding(.leading, 10)
            .padding(.trailing, 6) // design: the words' room before the button, with the row's 4, as ModeFoot has it
            Button("Reply with Signed PDF") {
                if let browser = browser(of: tab) { paper.reply(browser) }
            }
            .buttonStyle(.yab(.primary, .regular))
        }
        .font(.system(size: 12.5))
        .padding(BarFrame.inset)
        .background { PDFBarGround() }
        .fixedSize()
    }
}

// MARK: - the sheet a signature is made on

/// The page dimmed under the sheet, while it is up.
struct PDFSheetLayer: View {
    var desk: PDFDesk

    var body: some View {
        if desk.sheet {
            ZStack(alignment: .top) {
                Color.black.opacity(0.13)
                    .contentShape(Rectangle())
                    .onTapGesture { desk.sheet = false }
                PDFSignatureSheet(desk: desk)
                    .padding(.top, 32)
            }
            .transition(.opacity)
        }
    }
}

/// "Your Signature": a finger on the trackpad, the mouse in the box, or a
/// name typed in a hand's font, as Preview makes one.
struct PDFSignatureSheet: View {
    var desk: PDFDesk
    @Bindable var pad: SignatureSheetModel

    init(desk: PDFDesk) {
        self.desk = desk
        pad = desk.pad
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(pad.initials ? "Your Initials" : "Your Signature")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(Palette.ink)
            GlassTrack(title: "Sign with", options: [("Trackpad", SignatureWay.trackpad), ("Mouse", .mouse), ("Type", .type)], selection: $pad.way)
                .frame(width: 240)
            board
                .frame(height: 150)
            HStack(spacing: 8) {
                Text("Kept in your Keychain")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.muted)
                Spacer(minLength: 8)
                Button("Clear") { pad.clear() }
                    .buttonStyle(.yab(.secondary, .regular))
                    .disabled(pad.empty)
                Button("Cancel") { desk.sheet = false }
                    .buttonStyle(.yab(.secondary, .regular))
                Button { desk.finishSheet() } label: {
                    HStack(spacing: 6) {
                        Text("Done")
                        KeyGlyphs(keys: "↩", size: 12.5, tint: nil, rest: 0.6)
                            .transaction { $0.animation = nil }
                    }
                }
                .buttonStyle(.yab(.primary, .regular))
                .disabled(pad.empty)
            }
        }
        .frame(width: 416)
        .cardFrame()
    }

    /// The white box: paper in light and dark alike.
    @ViewBuilder
    private var board: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        ZStack {
            shape.fill(Color.white)
            shape.strokeBorder(Color.black.opacity(0.12), lineWidth: 1)
            if pad.way == .type {
                VStack(spacing: 12) {
                    TextField("Your name", text: $pad.name)
                        .textFieldStyle(.plain)
                        .font(.custom(pad.hand, size: 32))
                        .foregroundStyle(Color(nsColor: SignatureInk.color))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                    HStack(spacing: 6) {
                        ForEach(SignatureInk.hands, id: \.self) { font in
                            Button { pad.hand = font } label: {
                                Text(pad.name.isEmpty ? "Signature" : pad.name)
                                    .font(.custom(font, size: 13))
                                    .lineLimit(1)
                            }
                            .buttonStyle(.yab(pad.hand == font ? .secondary : .quiet, .small))
                        }
                    }
                }
                .environment(\.colorScheme, .light)
            } else {
                Rectangle()
                    .fill(Color.black.opacity(0.18))
                    .frame(height: 1)
                    .padding(.horizontal, 32)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 40) // design: the line a name stands on, where Preview's pad draws it, over the hint
                    .allowsHitTesting(false)
                SignaturePad(pad: pad)
                Text(pad.way == .trackpad ? "Sign with one finger on the trackpad. Press any key when done." : "Sign with the mouse in the box.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.black.opacity(0.45))
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 12)
                    .allowsHitTesting(false)
            }
        }
        .clipShape(shape)
    }
}

/// The white box a signature is drawn in: with the mouse, or with a finger
/// on the trackpad while the pointer stands still, until a key is pressed.
struct SignaturePad: NSViewRepresentable {
    @Bindable var pad: SignatureSheetModel

    func makeNSView(context: Context) -> PadView {
        let view = PadView()
        view.pad = pad
        return view
    }

    func updateNSView(_ view: PadView, context: Context) {
        view.pad = pad
        view.way = pad.way
        if view.ink != pad.ink {
            view.ink = pad.ink
            view.needsDisplay = true
        }
    }

    final class PadView: NSView {
        weak var pad: SignatureSheetModel?
        var ink = PenInk()
        var way = SignatureWay.trackpad {
            didSet { if way != oldValue { release() } }
        }
        /// The pointer held still while a finger draws.
        private(set) var capturing = false

        override init(frame: NSRect) {
            super.init(frame: frame)
            allowedTouchTypes = [.indirect]
            wantsRestingTouches = false
        }

        required init?(coder: NSCoder) { nil }

        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { release() }
        }

        override func draw(_ dirtyRect: NSRect) {
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            ink.draw(in: context)
        }

        // The mouse.
        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            if way == .trackpad {
                if !capturing { capture() }
                return
            }
            ink.begin(convert(event.locationInWindow, from: nil), at: event.timestamp)
            redraw()
        }

        override func mouseDragged(with event: NSEvent) {
            guard way == .mouse else { return }
            ink.add(convert(event.locationInWindow, from: nil), at: event.timestamp)
            redraw()
        }

        // A finger on the trackpad, while the pointer is held.
        private func capture() {
            capturing = true
            NSCursor.hide()
            CGAssociateMouseAndMouseCursorPosition(0)
        }

        func release() {
            guard capturing else { return }
            capturing = false
            CGAssociateMouseAndMouseCursorPosition(1)
            NSCursor.unhide()
        }

        /// Any key ends the drawing, as Preview has it.
        override func keyDown(with event: NSEvent) {
            if capturing { release(); return }
            super.keyDown(with: event)
        }

        private func at(_ touch: NSTouch) -> CGPoint {
            let p = touch.normalizedPosition
            return CGPoint(x: p.x * bounds.width, y: p.y * bounds.height)
        }

        override func touchesBegan(with event: NSEvent) {
            guard way == .trackpad else { return }
            if !capturing { capture() }
            let touches = event.touches(matching: .touching, in: self)
            guard touches.count == 1, let one = touches.first else { return }
            ink.begin(at(one), at: event.timestamp)
            redraw()
        }

        override func touchesMoved(with event: NSEvent) {
            guard way == .trackpad, capturing else { return }
            let touches = event.touches(matching: .touching, in: self)
            guard touches.count == 1, let one = touches.first else { return }
            ink.add(at(one), at: event.timestamp)
            redraw()
        }

        private func redraw() {
            needsDisplay = true
            pad?.ink = ink
        }
    }
}

// MARK: - the PDF while the mode is on

struct PDFDeskHost: NSViewRepresentable {
    let desk: PDFDesk
    var corner: CGFloat = 0
    var flatTop = false

    func makeNSView(context: Context) -> PDFDeskView { PDFDeskView(desk: desk) }

    func updateNSView(_ view: PDFDeskView, context: Context) {
        view.round(corner, flatTop: flatTop)
    }
}

/// The colors on the paper: the pen's blue light over a box, brighter over
/// the one being filled with a line under it, and the gray of the words
/// Return takes. The paper is white in light and dark alike.
enum PDFDeskInk {
    static let box = NSColor(srgbRed: 64 / 255.0, green: 120 / 255.0, blue: 240 / 255.0, alpha: 0.09)
    static let current = NSColor(srgbRed: 64 / 255.0, green: 120 / 255.0, blue: 240 / 255.0, alpha: 0.16)
    static let line = NSColor(srgbRed: 0x3A / 255.0, green: 0x6D / 255.0, blue: 0xF0 / 255.0, alpha: 1)
    static let ghost = NSColor(srgbRed: 0x9A / 255.0, green: 0xA3 / 255.0, blue: 0xB5 / 255.0, alpha: 1)
    /// Around the PDF's pages: WebKit's own gray for a PDF, so nothing
    /// moves as the mode comes over it.
    static let ground = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.16, alpha: 1) : NSColor(srgbRed: 0xE0 / 255.0, green: 0xE0 / 255.0, blue: 0xE3 / 255.0, alpha: 1)
    }
}

/// The PDFView over the web view, and what is drawn over its pages.
@MainActor
final class PDFDeskView: NSView, PDFPageOverlayViewProvider, NSTextFieldDelegate {
    let desk: PDFDesk
    let pdf = DeskPDFView()
    private var overlays: [ObjectIdentifier: DeskOverlay] = [:]
    private var watch: ObservationLoop?
    private var scaled: NSObjectProtocol?
    private var viewportWatches: [NSObjectProtocol] = []
    private var viewportReady = false
    private var viewportEpoch = 0
    private var placed = false
    /// The words being typed: into a box, or a line of text.
    private let editor = DeskEditor()
    private var editing: (page: PDFPage, rect: CGRect, note: Bool)?
    /// The ↩ beside the gray words.
    private var returnKey: NSHostingView<AnyView>?
    private var returnSize: CGFloat = 0

    init(desk: PDFDesk) {
        self.desk = desk
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        pdf.desk = desk
        desk.room = { [weak self] in self?.room(of: $0) ?? [] }
        desk.bring = { [weak self] index, rect in
            guard let self, let page = self.desk.document.page(at: index) else { return }
            self.show(rect, on: page)
        }
        desk.shownViewport = { [weak self] in
            guard let self, let destination = self.pdf.currentDestination, let page = destination.page as PDFPage? else { return [:] }
            return ["page": self.desk.document.index(for: page), "x": destination.point.x,
                    "y": destination.point.y, "scale": self.pdf.scaleFactor]
        }
        desk.position = { [weak self] page, x, y, scale in
            self?.restoreViewport(PDFWorkingState.Viewport(page: page, point: CGPoint(x: x, y: y), scale: scale))
            self?.rememberViewport()
        }
        pdf.autoScales = true
        pdf.displayMode = .singlePageContinuous
        pdf.displayDirection = .vertical
        pdf.displaysPageBreaks = true
        pdf.pageShadowsEnabled = true
        pdf.backgroundColor = PDFDeskInk.ground
        pdf.pageOverlayViewProvider = self
        pdf.document = desk.document
        pdf.frame = bounds
        pdf.autoresizingMask = [.width, .height]
        addSubview(pdf)
        editor.delegate = self
        editor.isBordered = false
        editor.drawsBackground = false
        editor.focusRingType = .none
        editor.textColor = PDFFill.ink
        editor.cell?.isScrollable = true
        editor.cell?.wraps = false
        var first = true
        watch = ObservationLoop { [weak self, desk] in
            // What the overlays draw from, besides what refresh reads.
            _ = (desk.mode, desk.current, desk.draft, desk.writing, desk.note, desk.selected,
                 desk.sheet, desk.signature, desk.ghost, desk.version)
            if first { first = false } else { self?.refresh() }
        }
        scaled = NotificationCenter.default.addObserver(forName: .PDFViewScaleChanged, object: pdf, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(); self?.rememberViewport() }
        }
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let scaled { NotificationCenter.default.removeObserver(scaled) }
        for observer in viewportWatches { NotificationCenter.default.removeObserver(observer) }
    }

    func round(_ corner: CGFloat, flatTop: Bool) {
        layer?.cornerRadius = corner
        layer?.cornerCurve = .continuous
        layer?.maskedCorners = flatTop ? [.layerMinXMinYCorner, .layerMaxXMinYCorner] : [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !placed else { return }
        placed = true
        DispatchQueue.main.async { [weak self] in self?.settle() }
    }

    /// Where the web view was, then the box being filled in sight, and the
    /// keyboard in it.
    private func settle() {
        layoutSubtreeIfNeeded()
        makeRoom()
        observeViewport()
        if let scroll = pdf.documentView?.enclosingScrollView { ThreadScroller.put(on: scroll) }
        if let saved = desk.viewport {
            let annotation = desk.writing ?? desk.current.map { desk.boxes[$0].annotation }
            revealed = annotation.map(ObjectIdentifier.init)
            restoreViewport(saved)
            window?.makeFirstResponder(pdf)
            refresh()
            // PDFKit computes continuous-page geometry on its next layout.
            // Do not let first-field reveal replace the saved position.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.layoutSubtreeIfNeeded()
                self?.restoreViewport(saved)
                self?.viewportReady = true
                self?.rememberViewport()
            }
            return
        }
        if let share = desk.startedAt, let document = pdf.documentView, let scroll = pdf.documentView?.enclosingScrollView {
            let room = max(0, document.bounds.height - scroll.contentView.bounds.height)
            let y = document.isFlipped ? share * room : room - share * room
            scroll.contentView.scroll(to: CGPoint(x: scroll.contentView.bounds.minX, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        showForm(fresh: true)
        viewportReady = true
        rememberViewport()
        window?.makeFirstResponder(pdf)
        refresh()
        // Again once PDFKit has laid the pages out at their scale: the
        // first pass can land before it has.
        for delay in [0.15, 0.6] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.layoutSubtreeIfNeeded()
                self?.showForm(fresh: false)
            }
        }
    }

    private func observeViewport() {
        guard viewportWatches.isEmpty else { return }
        let center = NotificationCenter.default
        if let clip = pdf.documentView?.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            viewportWatches.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.rememberViewport() }
            })
        }
        viewportWatches.append(center.addObserver(forName: .PDFViewPageChanged, object: pdf, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rememberViewport() }
        })
    }

    private func rememberViewport() {
        guard viewportReady, let destination = pdf.currentDestination, let page = destination.page as PDFPage? else { return }
        let index = desk.document.index(for: page)
        guard index != NSNotFound else { return }
        desk.movedViewport(PDFWorkingState.Viewport(page: index, point: destination.point, scale: pdf.scaleFactor))
    }

    private func restoreViewport(_ saved: PDFWorkingState.Viewport) {
        guard desk.document.page(at: saved.page) != nil, saved.scale.isFinite, saved.scale > 0,
              saved.point.x.isFinite, saved.point.y.isFinite else { return }
        viewportEpoch &+= 1
        let epoch = viewportEpoch
        let wasReady = viewportReady
        viewportReady = false
        pdf.autoScales = false
        pdf.scaleFactor = min(pdf.maxScaleFactor, max(pdf.minScaleFactor, saved.scale))
        pdf.layoutDocumentView()
        correctViewport(saved)
        viewportReady = wasReady
        // Scaling updates PDFKit's page geometry on the next native layout.
        // Move the clip directly: go(to:) adds its own asynchronous scroll
        // near a page gap and is not the inverse of currentDestination.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.viewportEpoch == epoch else { return }
            let ready = self.viewportReady
            self.viewportReady = false
            self.layoutSubtreeIfNeeded()
            self.correctViewport(saved)
            self.viewportReady = ready
            self.rememberViewport()
        }
    }

    private func correctViewport(_ saved: PDFWorkingState.Viewport) {
        guard let page = desk.document.page(at: saved.page),
              let destination = pdf.currentDestination, let shownPage = destination.page as PDFPage?,
              let document = pdf.documentView, let scroll = document.enclosingScrollView else { return }
        let wanted = document.convert(pdf.convert(saved.point, from: page), from: pdf)
        let shown = document.convert(pdf.convert(destination.point, from: shownPage), from: pdf)
        guard wanted.x.isFinite, wanted.y.isFinite, shown.x.isFinite, shown.y.isFinite else { return }
        let clip = scroll.contentView
        let origin = CGPoint(x: clip.bounds.minX + wanted.x - shown.x,
                             y: clip.bounds.minY + wanted.y - shown.y)
        // PDFKit's clip constraint reapplies the scroll view's content inset
        // to these already converted document coordinates. scroll(to:) takes
        // the physical origin directly, keeping the saved point unchanged.
        clip.scroll(to: origin)
        scroll.reflectScrolledClipView(clip)
    }

    /// The box being filled in sight, and the rest of the form on its page
    /// under it where it fits: none of it under the bar.
    private func showForm(fresh: Bool) {
        guard let current = desk.current else { return }
        let box = desk.boxes[current]
        guard let page = desk.document.page(at: box.page) else { return }
        let rest = desk.boxes.filter { $0.page == box.page && $0.bounds.maxY <= box.bounds.maxY }.reduce(box.bounds) { $0.union($1.bounds) }
        let fits = pdf.convert(rest, from: page).height + 30 <= pdf.bounds.height - Self.foot - Self.air
        show(fits ? rest : box.bounds, on: page, fresh: fresh)
    }

    /// The bar's room at the foot (its 16 from the edge, its height, a gap),
    /// and the air left over what is shown at the top: nothing the mode
    /// points at stands under the bar or against the top edge.
    static let foot: CGFloat = 16 + ButtonSize.regular.height + 2 * BarFrame.inset + 16
    static let air: CGFloat = 32

    /// Where an annotation stands on screen: points from the view's foot to
    /// its bottom, and from its top to the view's top (for ./bench).
    func room(of annotation: PDFAnnotation) -> [CGFloat] {
        guard let page = annotation.page else { return [] }
        var shown = pdf.convert(annotation.bounds, from: page)
        if pdf.isFlipped { shown.origin.y = pdf.bounds.height - shown.maxY }
        return [shown.minY, pdf.bounds.height - shown.maxY]
    }

    /// The pages' end can rise above the bar.
    private func makeRoom() {
        guard let scroll = pdf.documentView?.enclosingScrollView else { return }
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: Self.foot, right: 0)
    }

    /// `rect` of `page` in sight, with the line over it (a box's label),
    /// between the air at the top and the bar's room. Already there, nothing
    /// moves; else, or `fresh` as the mode starts, its top stands a third of
    /// the way down, with what comes before it in sight above.
    private func show(_ rect: CGRect, on page: PDFPage, fresh: Bool = false) {
        guard let document = pdf.documentView, let scroll = document.enclosingScrollView else { return }
        let wanted = CGRect(x: rect.minX, y: rect.minY - 6, width: rect.width, height: rect.height + 30)
        var shown = pdf.convert(wanted, from: page)
        if pdf.isFlipped { shown.origin.y = pdf.bounds.height - shown.maxY }
        let low = Self.foot, high = pdf.bounds.height - Self.air
        guard high - low > 40 else { return }
        if !fresh, shown.minY >= low, shown.maxY <= high { return }
        // How far the content goes up on screen (AppKit's y runs up): as
        // little as brings it in, or as the mode starts, its top a third of
        // the way down, its foot never under the bar.
        let rise: CGFloat
        if fresh {
            var top = high - (high - low) / 3
            if top - shown.height < low { top = min(high, low + shown.height) }
            rise = top - shown.maxY
        } else if shown.height > high - low || shown.maxY > high {
            rise = high - shown.maxY
        } else {
            rise = low - shown.minY
        }
        guard abs(rise) > 0.5 else { return }
        slide(rise, document: document, scroll: scroll)
        untrimTop(keeping: wanted, on: page)
    }

    /// The pages `rise` of the view's points up on screen (down when it is
    /// less than nought), as far as their ends and the bar's room let them.
    /// PDFKit zooms by magnifying its scroll view, so the clip counts in the
    /// document's points: a rise is divided by the magnification. Its clip's
    /// own constraint adds the content inset again to an origin already in
    /// those points (72 points low on screen at every move, 2026-10-27), so
    /// the range is kept here and the origin set as is, as
    /// `correctViewport` does.
    private func slide(_ rise: CGFloat, document: NSView, scroll: NSScrollView) {
        let clip = scroll.contentView
        let units = rise / max(scroll.magnification, 0.01)
        // Up on screen is further down the document.
        var y = clip.bounds.minY + (document.isFlipped ? units : -units)
        let inset = clip.contentInsets
        let least = document.isFlipped ? -inset.top : -inset.bottom
        let most = document.bounds.height - clip.bounds.height + (document.isFlipped ? inset.bottom : inset.top)
        y = min(max(y, least), max(least, most))
        clip.scroll(to: CGPoint(x: clip.bounds.minX, y: y))
        scroll.reflectScrolledClipView(clip)
    }

    /// No line of the page cut by the view's top edge: it goes out of sight,
    /// or comes all the way in, whichever keeps `wanted` between the air
    /// and the bar.
    private func untrimTop(keeping wanted: CGRect, on page: PDFPage) {
        guard let document = pdf.documentView, let scroll = document.enclosingScrollView else { return }
        let edge = CGPoint(x: pdf.bounds.midX, y: pdf.isFlipped ? 0 : pdf.bounds.height)
        guard let atTop = pdf.page(for: edge, nearest: true) else { return }
        let top = pdf.convert(edge, to: atTop)
        let width = atTop.bounds(for: pdf.displayBox).width
        // A strip 2 points high found no line where the edge cut one off
        // its middle (2026-10-27): look wider, keep the line it crosses.
        let near = atTop.selection(for: CGRect(x: 0, y: top.y - 16, width: width, height: 32))?.selectionsByLine() ?? []
        guard let line = near.lazy.map({ $0.bounds(for: atTop) }).first(where: { $0.height > 0 && $0.minY < top.y && $0.maxY > top.y })
        else { return }
        let scale = zoom(atTop, pdf)
        func ys(_ r: CGRect, _ p: PDFPage) -> CGRect {
            var shown = pdf.convert(r, from: p)
            if pdf.isFlipped { shown.origin.y = pdf.bounds.height - shown.maxY }
            return shown
        }
        let shown = ys(wanted, page)
        // Out of sight: up by what still shows under the edge. All in:
        // down by what is over it, and some air.
        let up = (top.y - line.minY) * scale + 2
        let down = (line.maxY - top.y) * scale + Self.air / 2
        let rise: CGFloat
        if shown.maxY + up <= pdf.bounds.height - 8 { rise = up }
        else if shown.minY - down >= Self.foot { rise = -down }
        else { return }
        slide(rise, document: document, scroll: scroll)
    }

    // MARK: overlays

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> NSView? {
        let overlay = DeskOverlay(host: self, page: page)
        overlays[ObjectIdentifier(page)] = overlay
        // A page come into sight may be the one being typed on.
        DispatchQueue.main.async { [weak self] in
            self?.placeEditor()
            self?.placeReturn()
        }
        return overlay
    }

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: NSView, for page: PDFPage) {
        if let editing, editing.page === page { finishTyping() }
        overlays[ObjectIdentifier(page)] = nil
    }

    /// The paper as the mode has it now.
    func refresh() {
        for page in pdf.visiblePages { pdf.annotationsChanged(on: page) }
        for overlay in overlays.values {
            overlay.needsDisplay = true
            overlay.window?.invalidateCursorRects(for: overlay)
        }
        reveal()
        placeEditor()
        placeReturn()
    }

    /// A line being typed or a signature just put down, in sight once: put
    /// there by a click it already is; by an agent or the bench, maybe not.
    private var revealed: ObjectIdentifier?
    private func reveal() {
        // Sign with nothing picked: the signature box it waits for.
        let waiting = desk.mode == .sign ? desk.signatureBoxes.first.map { desk.boxes[$0].annotation } : nil
        let wanted = desk.writing ?? desk.selected ?? desk.current.map { desk.boxes[$0].annotation } ?? waiting
        guard let wanted, ObjectIdentifier(wanted) != revealed, let page = wanted.page else { return }
        revealed = ObjectIdentifier(wanted)
        show(wanted.bounds, on: page)
    }

    /// A rect of a page in an overlay's points.
    func rect(_ r: CGRect, page: PDFPage, in overlay: NSView) -> CGRect {
        overlay.convert(pdf.convert(r, from: page), from: pdf)
    }

    func point(_ p: CGPoint, in overlay: NSView, page: PDFPage) -> CGPoint {
        pdf.convert(overlay.convert(p, to: pdf), to: page)
    }

    /// The page's points to the overlay's.
    func zoom(_ page: PDFPage, _ overlay: NSView) -> CGFloat {
        let one = rect(CGRect(x: 0, y: 0, width: 100, height: 100), page: page, in: overlay)
        return one.height / 100
    }

    // MARK: the words being typed

    private func placeEditor() {
        let want: (page: PDFPage, rect: CGRect, note: Bool, text: String, font: NSFont)? = {
            if let note = desk.writing, let page = note.page {
                return (page, note.bounds, true, desk.note, note.font ?? .systemFont(ofSize: 12))
            }
            if desk.mode == .fill, let current = desk.current {
                let box = desk.boxes[current]
                guard box.kind == .text, let page = desk.document.page(at: box.page) else { return nil }
                let size = box.annotation.font?.pointSize ?? PDFFill.fontSize(for: box.bounds.height)
                return (page, box.bounds, false, desk.draft, box.annotation.font ?? .systemFont(ofSize: size))
            }
            return nil
        }()
        guard let want, let overlay = overlays[ObjectIdentifier(want.page)] else { return finishTyping() }
        let scale = zoom(want.page, overlay)
        var frame = rect(want.rect, page: want.page, in: overlay)
        let font = NSFont(descriptor: want.font.fontDescriptor, size: max(6, (want.font.pointSize > 0 ? want.font.pointSize : 12) * scale)) ?? want.font
        let line = ceil(font.ascender - font.descender + font.leading) + 2
        if frame.height > line { frame = CGRect(x: frame.minX, y: frame.midY - line / 2, width: frame.width, height: line) }
        frame = frame.insetBy(dx: 2 * scale, dy: 0)
        if want.note { frame.size.width = max(frame.width, (want.text as NSString).size(withAttributes: [.font: font]).width + 24) }
        if editor.superview !== overlay { overlay.addSubview(editor) }
        if editor.font != font { editor.font = font }
        editor.frame = frame.integral
        if editor.stringValue != want.text { editor.stringValue = want.text }
        let fresh = editing.map { $0.page !== want.page || $0.rect != want.rect || $0.note != want.note } ?? true
        if fresh, let previous = editing, !previous.note { showBoxes() }
        // Hidden while it is typed in, or its words would be drawn twice.
        if !want.note, let current = desk.current { desk.boxes[current].annotation.shouldDisplay = false }
        editing = (want.page, want.rect, want.note)
        if fresh || window?.firstResponder !== editor.currentEditor() {
            window?.makeFirstResponder(editor)
            editor.currentEditor()?.selectedRange = NSRange(location: (editor.stringValue as NSString).length, length: 0)
        }
    }

    private func showBoxes() {
        for box in desk.boxes where !box.annotation.shouldDisplay && box.kind != .signature { box.annotation.shouldDisplay = true }
    }

    private func finishTyping() {
        guard editing != nil else { return }
        editing = nil
        showBoxes()
        let had = window?.firstResponder === editor.currentEditor()
        editor.removeFromSuperview()
        if had { window?.makeFirstResponder(pdf) }
    }

    func controlTextDidChange(_ note: Notification) {
        if desk.writing != nil {
            desk.note = editor.stringValue
        } else if desk.current != nil {
            desk.draft = editor.stringValue
        }
    }

    /// The ↩ after the gray words, on its plate, as the key Return is.
    private func placeReturn() {
        guard let words = desk.ghostWords, let current = desk.current else {
            returnKey?.isHidden = true
            return
        }
        let box = desk.boxes[current]
        guard let page = desk.document.page(at: box.page), let overlay = overlays[ObjectIdentifier(page)] else {
            returnKey?.isHidden = true
            return
        }
        let scale = zoom(page, overlay)
        let font = ghostFont(box, scale: scale)
        let size = max(10, min(15, (font.pointSize * 0.85).rounded()))
        let made: NSHostingView<AnyView> = {
            if let returnKey, returnSize == size { return returnKey }
            returnKey?.removeFromSuperview()
            let view = NSHostingView(rootView: AnyView(
                KeyGlyphs(keys: "↩", size: size, tint: nil)
                    .environment(\.colorScheme, .light)
                    .transaction { $0.animation = nil }
            ))
            returnSize = size
            returnKey = view
            return view
        }()
        if made.superview !== overlay { overlay.addSubview(made) }
        let fit = made.fittingSize
        let frame = rect(box.bounds, page: page, in: overlay)
        let width = (words as NSString).size(withAttributes: [.font: font]).width
        let x = frame.minX + 2 * scale + width + 8
        made.frame = CGRect(x: x, y: (frame.midY - fit.height / 2).rounded(), width: fit.width, height: fit.height).integral
        made.isHidden = x + fit.width > frame.maxX + 40
    }

    func ghostFont(_ box: PDFBox, scale: CGFloat) -> NSFont {
        let size = (box.annotation.font?.pointSize).flatMap { $0 > 0 ? $0 : nil } ?? PDFFill.fontSize(for: box.bounds.height)
        let base = box.annotation.font ?? NSFont(name: "Helvetica", size: size) ?? .systemFont(ofSize: size)
        return NSFont(descriptor: base.fontDescriptor, size: size * scale) ?? base
    }

    // MARK: drawing over a page

    func draw(_ overlay: DeskOverlay) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let page = overlay.page
        let index = desk.document.index(for: page)
        let scale = zoom(page, overlay)
        for (at, box) in desk.boxes.enumerated() where box.page == index {
            let frame = rect(box.bounds, page: page, in: overlay)
            let lit: Bool = {
                switch desk.mode {
                case .fill: return desk.current == at
                // A signature box lit while it waits for one.
                case .sign: return box.kind == .signature
                    && !page.annotations.contains { $0 is PDFSignatureStamp && $0.bounds.intersects(box.bounds) }
                case .text: return false
                }
            }()
            context.setFillColor((lit ? PDFDeskInk.current : PDFDeskInk.box).cgColor)
            context.fill(frame)
            if lit {
                context.setFillColor(PDFDeskInk.line.cgColor)
                context.fill(CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: 2))
            }
        }
        // The gray words Return takes.
        if let words = desk.ghostWords, let current = desk.current, desk.boxes[current].page == index {
            let box = desk.boxes[current]
            let frame = rect(box.bounds, page: page, in: overlay)
            let font = ghostFont(box, scale: scale)
            let text = NSAttributedString(string: words, attributes: [.font: font, .foregroundColor: PDFDeskInk.ghost])
            let height = text.size().height
            text.draw(at: CGPoint(x: frame.minX + 2 * scale + 2, y: frame.midY - height / 2))
        }
        // A signature following the pointer, where there is no box for it.
        if let ghost = desk.ghost, ghost.page == index, let signature = desk.signature, let image = signature.image {
            let r = rect(signature.standing(at: ghost.point), page: page, in: overlay)
            context.saveGState()
            context.setAlpha(0.55)
            context.draw(image, in: r)
            context.restoreGState()
        }
        // The one picked: a blue frame, a handle at two corners.
        if let picked = desk.selected, picked.page === page {
            let r = rect(picked.bounds, page: page, in: overlay).insetBy(dx: -4, dy: -4)
            context.setStrokeColor(PDFDeskInk.line.cgColor)
            context.setLineWidth(1)
            context.stroke(r.insetBy(dx: 0.5, dy: 0.5))
            for corner in [CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.minY)] {
                let knob = CGRect(x: corner.x - 3.5, y: corner.y - 3.5, width: 7, height: 7)
                context.setFillColor(NSColor.white.cgColor)
                context.fillEllipse(in: knob)
                context.strokeEllipse(in: knob.insetBy(dx: 0.5, dy: 0.5))
            }
        }
    }

    // MARK: the pointer over a page

    func hits(_ overlay: DeskOverlay, _ p: CGPoint) -> Bool {
        let page = overlay.page
        let at = point(p, in: overlay, page: page)
        if ours(at, on: page) != nil { return true }
        switch desk.mode {
        case .fill: return box(at, on: page) != nil
        case .text, .sign: return page.bounds(for: pdf.displayBox).contains(at)
        }
    }

    private func ours(_ at: CGPoint, on page: PDFPage) -> PDFAnnotation? {
        page.annotations.reversed().first { PDFDesk.ours($0) && $0.shouldDisplay && $0.bounds.insetBy(dx: -6, dy: -6).contains(at) }
    }

    private func box(_ at: CGPoint, on page: PDFPage) -> Int? {
        let index = desk.document.index(for: page)
        return desk.boxes.indices.first { desk.boxes[$0].page == index && desk.boxes[$0].bounds.contains(at) }
    }

    private enum Grip { case move, topLeft, bottomRight }
    private var drag: (annotation: PDFAnnotation, from: CGRect, start: CGPoint, grip: Grip)?

    func down(_ overlay: DeskOverlay, _ event: NSEvent) {
        let page = overlay.page
        let index = desk.document.index(for: page)
        let at = point(overlay.convert(event.locationInWindow, from: nil), in: overlay, page: page)
        if let hit = ours(at, on: page) {
            if event.clickCount == 2, !(hit is PDFSignatureStamp) { return desk.rewrite(hit) }
            desk.pick(hit)
            let r = hit.bounds.insetBy(dx: -4, dy: -4)
            let reach = 8 / max(0.1, zoom(page, overlay))
            let grip: Grip = hypot(at.x - r.maxX, at.y - r.minY) < reach ? .bottomRight
                : hypot(at.x - r.minX, at.y - r.maxY) < reach ? .topLeft : .move
            drag = (hit, hit.bounds, at, grip)
            return
        }
        if let hit = box(at, on: page) {
            let box = desk.boxes[hit]
            switch box.kind {
            case .check, .radio: desk.toggle(hit)
            case .choice: choose(hit, page: page, overlay: overlay)
            case .signature:
                desk.set(.sign)
                if desk.signature != nil { desk.sign(on: index, at: CGPoint(x: box.bounds.midX, y: box.bounds.midY)) }
            case .text:
                if desk.mode != .fill { desk.set(.fill) }
                desk.focus(hit)
            }
            return
        }
        switch desk.mode {
        case .fill: desk.focus(nil)
        case .text: desk.write(on: index, at: at)
        case .sign: desk.sign(on: index, at: at)
        }
    }

    func dragged(_ overlay: DeskOverlay, _ event: NSEvent) {
        guard let drag else { return }
        let at = point(overlay.convert(event.locationInWindow, from: nil), in: overlay, page: overlay.page)
        let dx = at.x - drag.start.x, dy = at.y - drag.start.y
        var r = drag.from
        let keepsShape = drag.annotation is PDFSignatureStamp
        switch drag.grip {
        case .move:
            r = r.offsetBy(dx: dx, dy: dy)
        case .bottomRight:
            let width = max(24, drag.from.width + dx)
            let height = keepsShape ? drag.from.height * width / drag.from.width : drag.from.height
            r = CGRect(x: drag.from.minX, y: drag.from.maxY - height, width: width, height: height)
        case .topLeft:
            let width = max(24, drag.from.width - dx)
            let height = keepsShape ? drag.from.height * width / drag.from.width : drag.from.height
            r = CGRect(x: drag.from.maxX - width, y: drag.from.minY, width: width, height: height)
        }
        desk.drag(drag.annotation, to: r)
    }

    func up(_ overlay: DeskOverlay, _ event: NSEvent) {
        guard let drag else { return }
        self.drag = nil
        desk.moved(drag.annotation, from: drag.from)
    }

    func moved(_ overlay: DeskOverlay, _ event: NSEvent) {
        guard desk.mode == .sign, desk.signatureBoxes.isEmpty, desk.signature != nil, !desk.sheet else {
            if desk.ghost != nil { desk.ghost = nil }
            return
        }
        // Over the bar the pointer is the bar's: no signature under it.
        let local = pdf.convert(event.locationInWindow, from: nil)
        if (pdf.isFlipped ? pdf.bounds.height - local.y : local.y) < Self.foot {
            if desk.ghost != nil { desk.ghost = nil }
            return
        }
        let page = overlay.page
        let at = point(overlay.convert(event.locationInWindow, from: nil), in: overlay, page: page)
        if ours(at, on: page) != nil { if desk.ghost != nil { desk.ghost = nil }; return }
        desk.ghost = (desk.document.index(for: page), at)
    }

    func left(_ overlay: DeskOverlay) {
        if let ghost = desk.ghost, ghost.page == desk.document.index(for: overlay.page) { desk.ghost = nil }
    }

    /// A list box: its choices in a menu under it.
    private func choose(_ index: Int, page: PDFPage, overlay: NSView) {
        let box = desk.boxes[index]
        let menu = NSMenu()
        for choice in box.annotation.choices ?? [] {
            let item = NSMenuItem(title: choice, action: #selector(DeskChoice.pick(_:)), keyEquivalent: "")
            let target = DeskChoice { [weak self] in self?.desk.choose(index, choice) }
            item.target = target
            item.representedObject = target
            item.state = box.value == choice ? .on : .off
            menu.addItem(item)
        }
        let frame = rect(box.bounds, page: page, in: overlay)
        menu.popUp(positioning: nil, at: CGPoint(x: frame.minX, y: frame.minY), in: overlay)
    }
}

/// A menu line's act, kept by the line.
final class DeskChoice: NSObject {
    let act: () -> Void
    init(_ act: @escaping () -> Void) { self.act = act }
    @objc func pick(_ sender: Any?) { act() }
}

/// The PDFView of the mode: the PDF's own interaction is the overlays'
/// while the mode is on.
final class DeskPDFView: PDFView {
    weak var desk: PDFDesk?
}

/// What is drawn over one page, and what the pointer does there.
@MainActor
final class DeskOverlay: NSView {
    weak var host: PDFDeskView?
    let page: PDFPage
    private var area: NSTrackingArea?

    init(host: PDFDeskView, page: PDFPage) {
        self.host = host
        self.page = page
        super.init(frame: .zero)
        // Paper is white in dark too: the caret and the keys drawn on it are light's.
        appearance = NSAppearance(named: .aqua)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) { host?.draw(self) }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let host else { return nil }
        let local = convert(point, from: superview)
        if let hit = super.hitTest(point), hit !== self { return hit }
        return host.hits(self, local) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) { host?.down(self, event) }
    override func mouseDragged(with event: NSEvent) { host?.dragged(self, event) }
    override func mouseUp(with event: NSEvent) { host?.up(self, event) }
    override func mouseMoved(with event: NSEvent) { host?.moved(self, event) }
    override func mouseExited(with event: NSEvent) { host?.left(self) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let made = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(made)
        area = made
    }

    override func resetCursorRects() {
        if host?.desk.mode == .text { addCursorRect(bounds, cursor: .iBeam) }
    }
}

/// The box typed in: no ground and no ring, the pen's blue.
final class DeskEditor: NSTextField {}
