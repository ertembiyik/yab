import SwiftUI
import AppKit
import Combine

// ⌃Tab's walk as a row on the page itself, an experiment (Settings ›
// Experimental, off until turned on); off, the walk is the card in
// Switcher.swift as it was.
//
// Read frame by frame off a reference film at 60 fps, four openings and
// four closings, fitted rather than eyeballed: no card; the tabs last
// looked at in one row in the middle of the window; the row comes in at
// 0.95 of its size and grows to it as it fades in, easing out. The page
// under the row blurs with it, all at once rather than spreading: all of
// it a little (1.3 pt), a band about the row a lot (9.3), and in that
// band it lightens, or on a dark page darkens, which is the plate without
// an edge that seems to stand round the row. The tab the walk is on
// stands on a plate of its own that slides to the next in 0.06 s; its
// title turns at once. The film's row fades out in 0.07 s; this one is
// gone the moment ⌃ is let go of, blur and all: any
// fade read as lag.
//
// Nothing of it waits on the main thread once it moves: coming in, the
// row's fade and growth, the blur's radius and the veil are Core
// Animation's own animations, run by the render server, so a page being
// drawn or a picture of one arriving cannot stall them. The row is built
// during the beat before it shows, from the first Tab, and the layers live
// as long as the window, hidden between walks, so showing it is only
// starting those animations. Going, it is hidden and flushed to the render
// server before the tab landed on is switched to (Switcher.ending).

enum SwitcherStrip {
    static let key = "switcher.strip"
    static var on: Bool { Store.settings.bool(forKey: key) }
    /// The film's tiles, 166 by 108 points, 24 apart.
    static let tile = CGSize(width: 166, height: 108)
    static let gap: CGFloat = 24
    /// How far the plate under the tab the walk is on stands out round it.
    static let rim: CGFloat = 8
    /// Between a tile's picture and its title, and the title's line.
    static let titleGap: CGFloat = 10
    static let titleHeight: CGFloat = 16
    /// The row's own size, rim included, before it is fitted to the window:
    /// worked out, not measured, so the pointer's tile is known exactly.
    static func size(of count: Int) -> CGSize {
        CGSize(width: CGFloat(count) * tile.width + CGFloat(max(0, count - 1)) * gap + rim * 2,
               height: tile.height + titleGap + titleHeight + rim * 2)
    }
    /// The size it comes in at and goes back to.
    static let small: CGFloat = 0.95
    /// Shorter than the card's 0.15 s: a tap still lands before it, and a
    /// second Tab inside it shows the row at once (Switcher.step).
    static let beat: TimeInterval = 0.12
    /// The film's openings fit an ease-out quad over 0.18 s as well as a
    /// cubic over 0.23 (rms 0.023 both): the quicker of the two.
    static let arriving: CFTimeInterval = 0.18
    static let arriveCurve = CAMediaTimingFunction(controlPoints: 0.5, 1, 0.89, 1)
    static let slide = Animation.timingCurve(0.33, 1, 0.68, 1, duration: 0.06)
}

/// The row and the page under it, in place of SwitcherPanel's card.
struct SwitcherStripPanel: View {
    let browser: Browser
    var switcher: Switcher
    @Environment(\.accessibilityReduceMotion) private var still
    @Environment(\.accessibilityReduceTransparency) private var solid

    var body: some View {
        // What the stage keys its work off, so every change of the walk
        // reaches it (a representable's update follows its own fields).
        StripStage(browser: browser, switcher: switcher, still: still, solid: solid,
                   showing: switcher.showing, at: switcher.at, ids: switcher.order.map(\.id), pictures: switcher.pictures.count)
            .ignoresSafeArea()
            .allowsHitTesting(switcher.showing)
    }
}

private struct StripStage: NSViewRepresentable {
    let browser: Browser
    let switcher: Switcher
    let still: Bool
    let solid: Bool
    let showing: Bool
    let at: Int
    let ids: [Tab.ID]
    let pictures: Int

    func makeNSView(context: Context) -> StripStageView { StripStageView(browser: browser, switcher: switcher) }

    func updateNSView(_ view: StripStageView, context: Context) {
        view.sync(still: still, solid: solid)
    }
}

/// The row's own view: the blur and veil under it, and the row in a box
/// Core Animation fades and grows.
final class StripStageView: NSView {
    private let browser: Browser
    private let switcher: Switcher
    private let blur = StripBackdropView()
    private let box = NSView()
    private let host = SwitcherRowHost(rootView: StripRow.empty)
    /// The fitted row's scale, below 1 in a window too narrow for it.
    private var fit: CGFloat = 1
    private var up = false
    private var still = false
    private var dark = false
    /// The row as it was last shown, kept while it goes: the walk forgets
    /// its tabs the moment ⌃ is let go of.
    private var held: [Tab] = []
    private var homes: [Tab.ID: Space] = [:]
    private var at = 0
    private var watching: AnyCancellable?
    private var picturing: DispatchWorkItem?

    init(browser: Browser, switcher: Switcher) {
        self.browser = browser
        self.switcher = switcher
        super.init(frame: .zero)
        wantsLayer = true
        host.sizingOptions = []
        updateTrackingAreas()
        box.wantsLayer = true
        box.isHidden = true
        box.addSubview(host)
        addSubview(blur)
        addSubview(box)
        // ⌃ let go of: gone and on its way to the screen before the tab
        // landed on is switched to, the slow part, rather than with it.
        switcher.ending = { [weak self] in
            guard let self, self.up else { return }
            self.leave()
            CATransaction.flush()
        }
        // A picture of each page soon after it comes to the front, while it
        // is on screen and quick to take (Switcher.remember).
        watching = browser.changes(\.activeID).sink { [weak self] id in
            guard let self else { return }
            self.picturing?.cancel()
            let take = DispatchWorkItem { [weak self] in
                guard let self, let id, self.browser.activeID == id, let tab = self.browser.active else { return }
                self.switcher.remember(tab)
            }
            self.picturing = take
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: take)
        }
    }

    required init?(coder: NSCoder) { nil }

    /// The row takes the pointer, worked out here from its geometry; the
    /// rest of the window is the page's. The SwiftUI inside only draws
    /// (SwitcherRowHost): the hover and the click are this view's.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard up, let superview else { return nil }
        return shown.contains(convert(point, from: superview)) ? self : nil
    }

    /// Where the row stands on screen, fitted, in this view's points.
    private var shown: CGRect {
        let size = SwitcherStrip.size(of: held.count)
        let width = size.width * fit, height = size.height * fit
        return CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
    }

    /// The tile under `point` (this view's points), title included.
    private func tile(at point: NSPoint) -> Int? {
        let row = shown
        guard up, row.contains(point), fit > 0 else { return nil }
        // From the row's top left corner, unfitted, inside its rim.
        let x = (point.x - row.minX) / fit - SwitcherStrip.rim
        let y = (row.maxY - point.y) / fit - SwitcherStrip.rim
        let step = SwitcherStrip.tile.width + SwitcherStrip.gap
        guard x >= 0, y >= 0, y <= SwitcherStrip.tile.height + SwitcherStrip.titleGap + SwitcherStrip.titleHeight else { return nil }
        let index = Int(x / step)
        guard held.indices.contains(index), x - CGFloat(index) * step <= SwitcherStrip.tile.width else { return nil }
        return switcher.visibleIndices.lowerBound + index
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    /// The pointer over a tile picks it once it has moved (Switcher.point).
    override func mouseMoved(with event: NSEvent) {
        guard up, let index = tile(at: convert(event.locationInWindow, from: nil)) else { return }
        switcher.point(at: index)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}

    /// A click on a tile lands there.
    override func mouseUp(with event: NSEvent) {
        guard up, let index = tile(at: convert(event.locationInWindow, from: nil)) else { return }
        browser.landSwitch(on: switcher.order[index])
    }

    override func layout() {
        super.layout()
        blur.frame = bounds
        box.frame = bounds
        place()
    }

    /// The host at the row's own size in the middle; the fitting is the
    /// row's scale effect about that middle. An NSHostingView with no
    /// sizing options has no constraints, so its fitting size was zero: the
    /// row drew past an empty frame and nothing under it took the pointer.
    private func place() {
        let size = SwitcherStrip.size(of: held.count)
        host.frame = CGRect(x: ((bounds.width - size.width) / 2).rounded(), y: ((bounds.height - size.height) / 2).rounded(),
                            width: size.width, height: size.height)
    }

    func sync(still: Bool, solid: Bool) {
        self.still = still
        blur.solid = solid
        // From the first Tab: the row is built during the beat, hidden, so
        // that showing it starts animations and nothing else.
        if switcher.open, !switcher.order.isEmpty {
            if !up && !switcher.showing { dark = browser.active?.under == .dark }
            held = switcher.visibleIndices.map { switcher.order[$0] }
            homes = switcher.homes
            at = switcher.at - switcher.visibleIndices.lowerBound
            // One row: the up and down arrows go round it.
            switcher.across = Switcher.columns
            render()
        }
        if switcher.showing != up {
            if switcher.showing { arrive() } else { leave() }
        }
    }

    private func render() {
        let width = SwitcherStrip.size(of: held.count).width
        // A window too narrow for the row shrinks it rather than cut it.
        fit = bounds.width > 0 ? min(1, (bounds.width - 48) / max(width, 1)) : 1
        host.rootView = StripRow(row: held, homes: homes, at: at, pictures: switcher.pictures, dark: dark, still: still, fit: fit)
        place()
    }

    /// Scaling about the middle of the window: a view's layer turns about
    /// its corner, so the scale is moved there and back.
    private func scaled(_ scale: CGFloat) -> CATransform3D {
        let middle = CGPoint(x: bounds.midX, y: bounds.midY)
        return CATransform3DConcat(CATransform3DConcat(CATransform3DMakeTranslation(-middle.x, -middle.y, 0),
                                                       CATransform3DMakeScale(scale, scale, 1)),
                                   CATransform3DMakeTranslation(middle.x, middle.y, 0))
    }

    private func arrive() {
        up = true
        blur.show(true, dark: dark, still: still)
        guard let layer = box.layer else { return }
        // Back from wherever a going it interrupts had got to.
        let from = box.isHidden ? 0 : (layer.presentation()?.opacity ?? 0)
        layer.removeAllAnimations()
        layer.isHidden = false
        box.isHidden = false
        let duration = still ? 0.12 : SwitcherStrip.arriving
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = 1
        fade.duration = duration
        fade.timingFunction = SwitcherStrip.arriveCurve
        layer.add(fade, forKey: "fade")
        if !still {
            let grow = CABasicAnimation(keyPath: "transform")
            grow.fromValue = NSValue(caTransform3D: scaled(SwitcherStrip.small))
            grow.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            grow.duration = duration
            grow.timingFunction = SwitcherStrip.arriveCurve
            layer.add(grow, forKey: "grow")
        }
    }

    /// Gone in the frame ⌃ is let go of, with the blur and the veil: the
    /// page landed on is what to look at. The film's 0.07 s fade read as
    /// lag (owner, 2026-11-05).
    private func leave() {
        up = false
        blur.show(false, dark: dark, still: still)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        box.layer?.removeAllAnimations()
        // The layer itself, in this transaction: the view's hiding reaches
        // its layer only on AppKit's next pass, a frame later.
        box.layer?.isHidden = true
        box.isHidden = true
        CATransaction.commit()
    }
}

/// The row's SwiftUI, drawing only: the stage takes the pointer.
private final class SwitcherRowHost: NSHostingView<StripRow> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The tiles in one row and the plate under the one the walk is on.
private struct StripRow: View {
    let row: [Tab]
    let homes: [Tab.ID: Space]
    let at: Int
    let pictures: [Tab.ID: NSImage]
    let dark: Bool
    let still: Bool
    let fit: CGFloat

    static let empty = StripRow(row: [], homes: [:], at: 0, pictures: [:], dark: false, still: false, fit: 1)

    var body: some View {
        let tile = SwitcherStrip.tile, gap = SwitcherStrip.gap, rim = SwitcherStrip.rim
        ZStack(alignment: .topLeading) {
            if !row.isEmpty {
                StripPlate(dark: dark)
                    .frame(width: tile.width + rim * 2, height: tile.height + rim * 2)
                    .offset(x: CGFloat(at) * (tile.width + gap) - rim, y: -rim)
                    .animation(still ? nil : SwitcherStrip.slide, value: at)
            }
            HStack(alignment: .top, spacing: gap) {
                ForEach(Array(row.enumerated()), id: \.element.id) { index, tab in
                    StripTile(tab: tab, picture: pictures[tab.id], home: homes[tab.id]?.icon, picked: index == at, dark: dark)
                }
            }
        }
        // Room for the plate's rim above and before the first tile.
        .padding(rim)
        .fixedSize()
        .scaleEffect(fit)
        .environment(\.colorScheme, dark ? .dark : .light)
    }
}

/// One tab: the page as it was left, its icon on a plate in the corner,
/// its title under it, dark ink when the walk is on it.
private struct StripTile: View {
    var tab: Tab
    let picture: NSImage?
    /// Another space's emoji, for a tab of that space.
    let home: String?
    let picked: Bool
    let dark: Bool

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 13, style: .continuous) // design: the film's tile corner, measured (13 on a 166 tile)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SwitcherStrip.titleGap) {
            page
                .frame(width: SwitcherStrip.tile.width, height: SwitcherStrip.tile.height)
                .clipShape(shape)
                .overlay(alignment: .bottomLeading) { chip.padding(8) }
                .overlay(shape.strokeBorder(Palette.ink.opacity(0.1), lineWidth: 0.5))
                .castShadow(shape, color: .black.opacity(Double(dark ? Shadow.fieldNearDark.opacity : Shadow.rest.opacity)),
                            radius: Shadow.rest.radius, y: Shadow.rest.y)
            HStack(spacing: 6) {
                Text(tab.label)
                    .font(.system(size: 13))
                    .foregroundStyle(picked ? Palette.ink : Palette.faint)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let home {
                    Spacer(minLength: 0)
                    SpaceMark(icon: home, size: 11).fixedSize()
                }
            }
            // Level with the icon's plate above it.
            .padding(.horizontal, 8)
            .frame(width: SwitcherStrip.tile.width, height: SwitcherStrip.titleHeight, alignment: .leading)
        }
    }

    /// The page from the top, the way it was left; a page with no picture
    /// yet is the ground, its icon in the corner saying whose it is.
    @ViewBuilder
    private var page: some View {
        if let picture {
            Image(nsImage: picture)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: SwitcherStrip.tile.width, height: SwitcherStrip.tile.height, alignment: .top)
        } else {
            Palette.ground
        }
    }

    /// Light on any page, as the film's: the icon reads the same on all.
    private var chip: some View {
        let plate = RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
        return Mark(icon: tab.icon, letter: tab.monogram, size: 20, dim: tab.asleep)
            .frame(width: 30, height: 30) // design: the film's icon plate, 30 pt
            .background(plate.fill(Color(white: 0.97).opacity(0.94)))
            .overlay(plate.strokeBorder(Color.black.opacity(0.1), lineWidth: 0.5))
            .environment(\.colorScheme, .light)
    }
}

/// What the tab the walk is on stands on: gray glass with a light rim,
/// lighter on a dark page.
private struct StripPlate: View {
    let dark: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 21, style: .continuous) // design: concentric with the tile's 13, standing 8 out
        shape
            .fill(dark ? Color.white.opacity(0.2) : Color(white: 0.45).opacity(0.34))
            .overlay(shape.strokeBorder(Color.white.opacity(dark ? 0.2 : 0.42), lineWidth: 1))
    }
}

/// The page under the row: blurred a little all over and a lot in a band
/// about the row, lightened or darkened in that band, all of it coming and
/// going with the row. Three of Core Animation's backdrops stacked
/// (EdgeBlurView.backdrop), each a gaussian blur masked to where the
/// blur reaches its level; stacked, they add in quadrature to the film's
/// curve: 1.3 + 8 * exp(-(d / 185)^4) points at d from the row's middle,
/// 1.3 at the window's edges, 9.3 behind the row. The two strong ones
/// cover only their band, not the window: a backdrop blurs all it covers,
/// masked or not. The radius grows and falls by the render server's own
/// animation of the filter, and the layers are hidden between walks.
final class StripBackdropView: NSView {
    private static let levels: [CGFloat] = [1.3, 4.2, 9.3]
    private static let blurKey = "filters.blur.inputRadius"
    private struct Blur {
        let layer: CALayer
        let mask: CAGradientLayer?
        let radius: CGFloat
        let below: CGFloat
        let level: CGFloat
        /// How far from the row's middle it reaches, nil for the whole window.
        let reach: CGFloat?
    }
    private var blurs: [Blur] = []
    /// The veil, white or black, in the band (its mask), fading out at the
    /// window's sides (the box's mask).
    private let box = CALayer()
    private let sides = CAGradientLayer()
    private let veil = CALayer()
    private let band = CAGradientLayer()
    /// Reduce Transparency: no blur, the veil as a solid ground instead.
    var solid = false
    private var up = false

    init() {
        super.init(frame: .zero)
        layer = CALayer()
        wantsLayer = true
        var below: CGFloat = 0
        for level in Self.levels {
            guard let backdrop = EdgeBlurView.backdrop(radius: 0) else { break }
            if let filter = Self.gaussian(radius: 0) { backdrop.filters = [filter] }
            let mask: CAGradientLayer? = below == 0 ? nil : CAGradientLayer()
            backdrop.mask = mask
            backdrop.isHidden = true
            layer?.addSublayer(backdrop)
            blurs.append(Blur(layer: backdrop, mask: mask, radius: (level * level - below * below).squareRoot(),
                              below: below, level: level, reach: below == 0 ? nil : Self.reach(above: below)))
            below = level
        }
        veil.mask = band
        box.addSublayer(veil)
        box.mask = sides
        box.opacity = 0
        box.isHidden = true
        layer?.addSublayer(box)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Its frame is set by the stage, which a layer-hosting view does not
    /// take as a reason to lay its layers out again.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    /// The blur's radius at `distance` points from the row's middle.
    static func radius(at distance: CGFloat) -> CGFloat { 1.3 + 8 * exp(-pow(distance / 185, 4)) }
    /// The veil's share at `distance`, 1 behind the row.
    static func share(at distance: CGFloat) -> CGFloat { exp(-pow(distance / 165, 4)) }
    /// Where the curve still stands above `level` by a hair, and a blur's
    /// width more for the edge it bleeds over.
    private static func reach(above level: CGFloat) -> CGFloat {
        let over = max(level - 1.3, 0.02)
        return 185 * pow(log(8 / over), 0.25) + 24
    }

    /// Core Animation's gaussian blur, as EdgeBlurView.backdrop makes it,
    /// named so its radius can be animated by key path.
    private static func gaussian(radius: CGFloat) -> NSObject? {
        guard let type = NSClassFromString("CAFilter") as? NSObject.Type,
              let blur = type.perform(NSSelectorFromString("filterWithType:"), with: "gaussianBlur")?.takeUnretainedValue() as? NSObject
        else { return nil }
        blur.setValue("blur", forKey: "name")
        blur.setValue(radius, forKey: "inputRadius")
        blur.setValue(true, forKey: "inputNormalizeEdges")
        return blur
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let middle = bounds.height / 2
        let steps = (0...48).map { CGFloat($0) / 48 }
        let locations = steps.map { NSNumber(value: Double($0)) }
        for blur in blurs {
            guard let reach = blur.reach, let mask = blur.mask else {
                blur.layer.frame = bounds
                continue
            }
            let low = max(0, middle - reach), high = min(bounds.height, middle + reach)
            blur.layer.frame = CGRect(x: 0, y: low, width: bounds.width, height: max(high - low, 1))
            mask.frame = blur.layer.bounds
            mask.startPoint = CGPoint(x: 0.5, y: 0)
            mask.endPoint = CGPoint(x: 0.5, y: 1)
            mask.locations = locations
            mask.colors = steps.map { at in
                let y = low + at * (high - low)
                let reach = (Self.radius(at: abs(y - middle)) - blur.below) / (blur.level - blur.below)
                return NSColor.black.withAlphaComponent(min(1, max(0, reach))).cgColor
            }
        }
        for part in [box, veil, band, sides] as [CALayer] { part.frame = bounds }
        band.startPoint = CGPoint(x: 0.5, y: 0)
        band.endPoint = CGPoint(x: 0.5, y: 1)
        band.locations = locations
        band.colors = steps.map { NSColor.black.withAlphaComponent(Self.share(at: abs($0 * bounds.height - middle))).cgColor }
        sides.startPoint = CGPoint(x: 0, y: 0.5)
        sides.endPoint = CGPoint(x: 1, y: 0.5)
        sides.locations = [0, 0.09, 0.91, 1]
        sides.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        CATransaction.commit()
    }

    /// In with the row on its curve; out at once, as the row goes.
    func show(_ up: Bool, dark: Bool, still: Bool) {
        guard up != self.up else { return }
        self.up = up
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard up else {
            for blur in blurs {
                blur.layer.removeAllAnimations()
                blur.layer.isHidden = true
            }
            box.removeAllAnimations()
            box.opacity = 0
            box.isHidden = true
            return
        }
        let duration = still ? 0.12 : SwitcherStrip.arriving
        let curve = SwitcherStrip.arriveCurve
        veil.backgroundColor = solid
            ? (dark ? NSColor(white: 0.11, alpha: 0.92) : NSColor(white: 1, alpha: 0.92)).cgColor
            : (dark ? NSColor(white: 0, alpha: 0.3) : NSColor(white: 1, alpha: 0.24)).cgColor
        for blur in blurs where !solid {
            // The value it ends at, then the render server's way there.
            if let filter = Self.gaussian(radius: blur.radius) { blur.layer.filters = [filter] }
            blur.layer.isHidden = false
            let grow = CABasicAnimation(keyPath: Self.blurKey)
            grow.fromValue = 0
            grow.toValue = blur.radius
            grow.duration = duration
            grow.timingFunction = curve
            blur.layer.add(grow, forKey: "radius")
        }
        box.isHidden = false
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = duration
        fade.timingFunction = curve
        box.opacity = 1
        box.add(fade, forKey: "fade")
    }
}
