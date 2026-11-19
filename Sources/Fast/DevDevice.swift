import AppKit
import SwiftUI
import WebKit

// Device mode, Chrome's device toolbar: the page laid out at a phone's or a
// tablet's size, in the middle of its own room, over a gray ground, with a
// bar above it saying which device, its size, how near it is drawn, and a
// turn. The page is given the device's width to lay itself out in, and
// drawn smaller when the room is smaller, by WebKit's view scale: the page
// sees 393 points across however large it is drawn. A phone or an Android
// tells the site so in its user agent from the next load, as Chromium's does;
// Responsive keeps the page's own. Its edges pull, as Chromium's Responsive
// does, and pulled, any device becomes Responsive at the new size.

/// A device the page is shown as.
struct DeviceMode: Equatable {
    var name: String
    var width: CGFloat
    var height: CGFloat
    /// What the page is told it runs in; nil for yab's own.
    var userAgent: String?
    /// How near it is drawn; nil to fit the room.
    var zoom: CGFloat?
    /// The scale kept while a hand pulls an edge, so the edge stays under
    /// it; nil again once it lets go, and Fit fits again.
    var held: CGFloat?

    static let responsive = "Responsive"

    /// The bar over the page, and the air round it: room for a handle at
    /// each side and under it, Chrome's 20 points.
    static let bar: CGFloat = 40
    static let air: CGFloat = 20
    /// Chrome's bounds for a size, typed or pulled.
    static let smallest: CGFloat = 50
    static let largest: CGFloat = 9999

    /// What a room of `size` leaves the device: less the air at each side,
    /// the bar over it and the air under it.
    static func room(in size: CGSize) -> CGSize {
        CGSize(width: size.width - 2 * air, height: size.height - bar - air)
    }

    /// How large it is drawn in a room of `size`: as held, as asked, or as
    /// large as fits, never larger than itself.
    func scale(in size: CGSize) -> CGFloat {
        if let held { return held }
        if let zoom { return zoom }
        let room = Self.room(in: size)
        guard width > 0, height > 0, room.width > 0, room.height > 0 else { return 1 }
        return min(1, room.width / width, room.height / height)
    }

    /// Pulled by `handle` `moved` points from where the hand took it, in a
    /// room of `size`: Responsive at the new size, as a size typed makes it,
    /// at the scale it had when taken. Twice the hand across, since it
    /// stands in the middle of its room and grows both ways, so the edge
    /// stays under the hand; never past the room at that scale unless it
    /// already was (Chrome's DeviceModeView.onResizeUpdate).
    func pulled(_ handle: DeviceHandle, by moved: CGSize, in size: CGSize) -> DeviceMode {
        let scale = held ?? scale(in: size)
        let room = Self.room(in: size)
        var next = self
        next.name = Self.responsive
        next.userAgent = nil
        next.held = scale
        func pull(_ from: CGFloat, _ by: CGFloat, _ room: CGFloat) -> CGFloat {
            let most = min(Self.largest, max(from, (room / scale).rounded(.down)))
            return min(most, max(Self.smallest, (from + by / scale).rounded()))
        }
        if handle.across != 0 { next.width = pull(width, moved.width * handle.across, room.width) }
        if handle.down != 0 { next.height = pull(height, moved.height * handle.down, room.height) }
        return next
    }

    /// The bottom edge clicked twice: as tall as the room holds at the scale
    /// its width is drawn at (Chrome's "Double-click for full height").
    func fullHeight(in size: CGSize) -> DeviceMode {
        let room = Self.room(in: size)
        let scale = held ?? zoom ?? min(1, room.width / max(width, 1))
        var next = self
        next.name = Self.responsive
        next.userAgent = nil
        next.height = min(Self.largest, max(Self.smallest, (room.height / scale).rounded(.down)))
        return next
    }

    /// Where the page stands in a room of `size`, from its top left.
    func frame(in size: CGSize) -> CGRect {
        let scale = scale(in: size)
        let drawn = CGSize(width: (width * scale).rounded(), height: (height * scale).rounded())
        return CGRect(x: ((size.width - drawn.width) / 2).rounded(), y: Self.bar, width: drawn.width, height: drawn.height)
    }

    struct Preset: Identifiable {
        let name: String
        let width: CGFloat
        let height: CGFloat
        let userAgent: String?
        var id: String { name }
    }

    static let iPhone = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Mobile/15E148 Safari/604.1"
    static let android = "Mozilla/5.0 (Linux; Android 15; Pixel 9) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36"

    /// Chrome's list, the ones people test on. An iPad tells sites it is a
    /// Mac, as an iPad's own browser does.
    static let presets: [Preset] = [
        Preset(name: "iPhone SE", width: 375, height: 667, userAgent: iPhone),
        Preset(name: "iPhone 16", width: 393, height: 852, userAgent: iPhone),
        Preset(name: "iPhone 16 Pro Max", width: 440, height: 956, userAgent: iPhone),
        Preset(name: "Pixel 9", width: 412, height: 923, userAgent: android),
        Preset(name: "Galaxy S24", width: 360, height: 780, userAgent: android),
        Preset(name: "iPad mini", width: 744, height: 1133, userAgent: nil),
        Preset(name: "iPad Air", width: 820, height: 1180, userAgent: nil),
        Preset(name: "iPad Pro 13″", width: 1032, height: 1376, userAgent: nil),
    ]
}

/// An edge of the device a hand can pull, Chrome's: the right one, the
/// bottom and the corner between, and the left ones, which show only under
/// the hand.
enum DeviceHandle: CaseIterable {
    case right, bottom, bottomRight, left, bottomLeft

    /// How the width follows the hand across: twice, the device standing in
    /// the middle of its room; against it on the left.
    var across: CGFloat {
        switch self {
        case .right, .bottomRight: 2
        case .left, .bottomLeft: -2
        case .bottom: 0
        }
    }

    /// How the height follows the hand down: once, the top staying put.
    var down: CGFloat { self == .right || self == .left ? 0 : 1 }

    /// Seen only under the hand, as Chromium's left ones.
    var shy: Bool { self == .left || self == .bottomLeft }

    /// Where it stands round a device drawn in `frame`, in its room's points.
    func rect(round frame: CGRect) -> CGRect {
        let air = DeviceMode.air
        switch self {
        case .right: return CGRect(x: frame.maxX, y: frame.minY, width: air, height: frame.height)
        case .left: return CGRect(x: frame.minX - air, y: frame.minY, width: air, height: frame.height)
        case .bottom: return CGRect(x: frame.minX, y: frame.maxY, width: frame.width, height: air)
        case .bottomRight: return CGRect(x: frame.maxX, y: frame.maxY, width: air, height: air)
        case .bottomLeft: return CGRect(x: frame.minX - air, y: frame.maxY, width: air, height: air)
        }
    }

    /// The Mac's own resize pointer for that edge.
    var cursor: NSCursor {
        switch self {
        case .right: .frameResize(position: .right, directions: .all)
        case .left: .frameResize(position: .left, directions: .all)
        case .bottom: .frameResize(position: .bottom, directions: .all)
        case .bottomRight: .frameResize(position: .bottomRight, directions: .all)
        case .bottomLeft: .frameResize(position: .bottomLeft, directions: .all)
        }
    }
}

extension Browser {
    /// The device button: the page as a device, or itself again.
    func toggleDevice() {
        guard let tab = active else { return }
        // On again as the device it was last, as Chromium's toolbar comes back.
        tab.setDevice(tab.device == nil ? DevMemory.device ?? DeviceMode(name: DeviceMode.responsive, width: 400, height: 800) : nil)
    }
}

extension Tab {
    /// Shown as `device`, or as itself with nil: its user agent from the
    /// next load, its size and scale at once (StageView.settle). A hand's
    /// choice is kept for the next time the tools come out (DevMemory);
    /// the card going away, or a recording replayed, isn't one.
    func setDevice(_ device: DeviceMode?, remember: Bool = true) {
        let was = self.device
        self.device = device
        if remember { DevMemory.remember(device) }
        if let chromium = builtPage as? ChromiumPage {
            // Its size and scale come with the stage's next layout, as WebKit's do.
            if device == nil { chromium.emulate(nil, scale: 1) }
            return
        }
        guard let web = webKitOnly("WebKit device emulation", build: false) else { return }
        if device?.userAgent != was?.userAgent { web.customUserAgent = device?.userAgent }
        if device == nil { DeviceStage.scale(web, 1) }
    }
}

/// WebKit's view scale with its layout mode computed from it: the page
/// laid out at the view's size over the scale, 393 points in a view drawn
/// at 161, and drawn at that scale. The scale alone only draws the page
/// smaller; it kept laying out at the view's own 161. Each name asked for
/// before use, as the inspector's are.
@MainActor
enum DeviceStage {
    private static let set = NSSelectorFromString("_setViewScale:")
    private static let get = NSSelectorFromString("_viewScale")
    private static let mode = NSSelectorFromString("_setLayoutMode:")
    /// _WKLayoutModeViewSize and _WKLayoutModeDynamicSizeComputedFromViewScale.
    private static let viewSize: UInt = 0, fromScale: UInt = 2

    static func scale(_ web: WKWebView, _ scale: CGFloat) {
        guard web.responds(to: set) else { return }
        if web.responds(to: mode) {
            typealias Mode = @convention(c) (AnyObject, Selector, UInt) -> Void
            unsafeBitCast(web.method(for: mode), to: Mode.self)(web, mode, scale == 1 ? viewSize : fromScale)
        }
        typealias Setter = @convention(c) (AnyObject, Selector, CGFloat) -> Void
        unsafeBitCast(web.method(for: set), to: Setter.self)(web, set, scale)
    }

    /// The page's view scale now; nil where WebKit has no such name.
    static func scale(of web: WKWebView) -> CGFloat? {
        guard web.responds(to: get) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> CGFloat
        return unsafeBitCast(web.method(for: get), to: Getter.self)(web, get)
    }
}

/// The gray the device stands on, under the page.
struct DeviceGround: View {
    var body: some View {
        Palette.ink.opacity(0.06)
            .background(Palette.ground)
            .allowsHitTesting(false)
    }
}

/// Over the page in device mode: which device, its size, how near, a turn.
struct DeviceBar: View {
    var tab: Tab
    let device: DeviceMode
    let room: CGSize

    var body: some View {
        HStack(spacing: 4) {
            Menu {
                Toggle(DeviceMode.responsive, isOn: pick(DeviceMode.responsive) {
                    DeviceMode(name: DeviceMode.responsive, width: device.width, height: device.height)
                })
                Divider()
                ForEach(DeviceMode.presets) { preset in
                    Toggle("\(preset.name)   \(Int(preset.width)) × \(Int(preset.height))", isOn: pick(preset.name) {
                        DeviceMode(name: preset.name, width: preset.width, height: preset.height, userAgent: preset.userAgent)
                    })
                }
            } label: {
                HStack(spacing: 4) {
                    Text(device.name).font(.system(size: 12, weight: .medium))
                    Symbol("chevron.down", size: 8)
                }
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.yab(.quiet, .small))
            .fixedSize()
            .focusable(false)
            .keyTip("Device")

            SizeField(value: device.width) { change(width: $0) }
                .keyTip("Width")
            Text("×").font(.system(size: 12)).foregroundStyle(Palette.muted)
            SizeField(value: device.height) { change(height: $0) }
                .keyTip("Height")

            Menu {
                Toggle("Fit", isOn: zoom(nil))
                Divider()
                ForEach([0.5, 0.75, 1, 1.25, 1.5], id: \.self) { value in
                    Toggle("\(Int(value * 100))%", isOn: zoom(CGFloat(value)))
                }
            } label: {
                HStack(spacing: 4) {
                    Text("\(Int((device.scale(in: room) * 100).rounded()))%").monospacedDigit().font(.system(size: 12, weight: .medium))
                    Symbol("chevron.down", size: 8)
                }
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.yab(.quiet, .small))
            .fixedSize()
            .focusable(false)
            .keyTip("Zoom")

            Button { turn() } label: { Symbol("arrow.rotate", size: 11) }
                .buttonStyle(.yab(.quiet, .small, icon: .square))
                .focusable(false)
                .keyTip("Rotate")
        }
        .frame(height: DeviceMode.bar)
        .frame(maxWidth: .infinity)
    }

    private func pick(_ name: String, _ make: @escaping () -> DeviceMode) -> Binding<Bool> {
        Binding(get: { device.name == name }, set: { on in
            guard on else { return }
            var next = make()
            next.zoom = device.zoom
            tab.setDevice(next)
        })
    }

    private func zoom(_ value: CGFloat?) -> Binding<Bool> {
        Binding(get: { device.zoom == value }, set: { on in
            guard on else { return }
            var next = device
            next.zoom = value
            tab.setDevice(next)
        })
    }

    /// A size typed: the device becomes Responsive at it, as in Chromium.
    private func change(width: CGFloat? = nil, height: CGFloat? = nil) {
        var next = device
        next.name = DeviceMode.responsive
        next.userAgent = nil
        if let width { next.width = min(max(width, DeviceMode.smallest), DeviceMode.largest) }
        if let height { next.height = min(max(height, DeviceMode.smallest), DeviceMode.largest) }
        tab.setDevice(next)
    }

    private func turn() {
        var next = device
        next.width = device.height
        next.height = device.width
        tab.setDevice(next)
    }
}

/// The handles round a device, on its gray ground, clear of the page.
struct DeviceHandles: View {
    var tab: Tab
    let device: DeviceMode
    let room: CGSize

    var body: some View {
        let frame = device.frame(in: room)
        // Placed by `position`, which lays each out there, the hand's AppKit
        // view with it.
        ZStack(alignment: .topLeading) {
            ForEach(DeviceHandle.allCases, id: \.self) { handle in
                let rect = handle.rect(round: frame)
                DeviceGrip(tab: tab, handle: handle, device: device, room: room)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }
        }
        .frame(width: room.width, height: room.height, alignment: .topLeading)
    }
}

/// One handle: Chrome's grip, two bars along the edge or two across the
/// corner, a plate under the hand, the Mac's resize pointer. ⇧ held pulls
/// it a tenth as far as the hand, for the exact point, as in Chromium.
private struct DeviceGrip: View {
    var tab: Tab
    let handle: DeviceHandle
    let device: DeviceMode
    let room: CGSize
    @State private var hovered = false
    @State private var holding = false

    var body: some View {
        let lit = hovered || holding
        // Only what is drawn goes clear on the shy ones; the hand's view
        // over it keeps taking the pointer.
        ZStack {
            RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                .fill(Palette.ink.opacity(lit ? 0.08 : handle == .bottomRight ? 0.04 : 0))
            grip
        }
        .opacity(handle.shy && !lit ? 0 : 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .overlay {
            GripArea(
                cursor: handle.cursor,
                take: {
                    var taken = device
                    taken.held = device.scale(in: room)
                    return taken
                },
                pull: { from, moved in tab.setDevice(from.pulled(handle, by: moved, in: room)) },
                done: {
                    // Let go: Fit fits again.
                    guard var now = tab.device, now.held != nil else { return }
                    now.held = nil
                    tab.setDevice(now)
                },
                doubled: {
                    // The bottom one twice: as tall as the room holds.
                    if handle == .bottom { tab.setDevice(device.fullHeight(in: room)) }
                },
                hover: { hovered = $0 },
                holding: { holding = $0 })
        }
        .pointerTip(handle == .bottom ? "Double-click for full height" : "")
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var grip: some View {
        let ink = Palette.ink.opacity(0.3)
        switch handle {
        case .right, .left:
            HStack(spacing: 2) {
                Capsule().fill(ink).frame(width: 2, height: 26)
                Capsule().fill(ink).frame(width: 2, height: 26)
            }
        case .bottom:
            VStack(spacing: 2) {
                Capsule().fill(ink).frame(width: 26, height: 2)
                Capsule().fill(ink).frame(width: 26, height: 2)
            }
        case .bottomRight, .bottomLeft:
            Path { path in
                path.move(to: CGPoint(x: 1, y: 11))
                path.addLine(to: CGPoint(x: 11, y: 1))
                path.move(to: CGPoint(x: 6, y: 11))
                path.addLine(to: CGPoint(x: 11, y: 6))
            }
            .stroke(ink, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: 12, height: 12)
            .scaleEffect(x: handle == .bottomLeft ? -1 : 1)
            .padding(4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: handle == .bottomLeft ? .bottomLeading : .bottomTrailing)
        }
    }
}

/// Where the hand takes a handle: a real view, as the splits' edge is
/// (EdgeHandle). A SwiftUI drag over the stage lost the mouse after a move
/// or two (evals/devmode/device_check.py), and its taps, run a beat later,
/// had no click of their own to count; here every press, move and let-go is
/// the mouse's own event, a double click read off its press.
struct GripArea: NSViewRepresentable {
    let cursor: NSCursor
    /// The device as the hand takes it, its scale held.
    let take: () -> DeviceMode
    /// Pulled from it this far, in the window's points, down and right.
    let pull: (DeviceMode, CGSize) -> Void
    let done: () -> Void
    let doubled: () -> Void
    let hover: (Bool) -> Void
    let holding: (Bool) -> Void

    func makeNSView(context: Context) -> Area { Area() }

    func updateNSView(_ view: Area, context: Context) {
        view.cursor = cursor
        view.take = take
        view.pull = pull
        view.done = done
        view.doubled = doubled
        view.hover = hover
        view.holding = holding
    }

    final class Area: NSView {
        var cursor = NSCursor.arrow
        var take: () -> DeviceMode = { DeviceMode(name: DeviceMode.responsive, width: 400, height: 800) }
        var pull: (DeviceMode, CGSize) -> Void = { _, _ in }
        var done: () -> Void = {}
        var doubled: () -> Void = {}
        var hover: (Bool) -> Void = { _ in }
        var holding: (Bool) -> Void = { _ in }

        /// Where the press was, in the window, and the device then.
        private var start: NSPoint?
        private var taken: DeviceMode?
        /// Where the hand was when ⇧ went down.
        private var slow: NSPoint?

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            addTrackingArea(NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                owner: self))
        }

        override func cursorUpdate(with event: NSEvent) {
            CursorUpdateGuard.run(self) { cursor.set() }
        }
        override func mouseEntered(with event: NSEvent) { hover(true) }
        override func mouseExited(with event: NSEvent) { if start == nil { hover(false) } }

        override func mouseDown(with event: NSEvent) {
            cursor.set()
            // A double click's own drag moves nothing: it was measured from
            // the press before.
            if event.clickCount >= 2 {
                start = nil
                doubled()
                return
            }
            // Where the event says, in the window, not where the pointer is
            // on the screen: a drag the bench posts has no pointer behind it.
            start = event.locationInWindow
            taken = take()
            slow = nil
            holding(true)
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start, let taken else { return }
            cursor.set()
            let at = event.locationInWindow
            let shift = event.modifierFlags.contains(.shift)
            if shift != (slow != nil) { slow = shift ? at : nil }
            // The window's y runs up; the device's down.
            var moved = CGSize(width: at.x - start.x, height: start.y - at.y)
            if let slow {
                moved = CGSize(width: (at.x - slow.x) / 10 + slow.x - start.x,
                               height: (slow.y - at.y) / 10 + start.y - slow.y)
            }
            pull(taken, moved)
        }

        override func mouseUp(with event: NSEvent) {
            guard start != nil else { return }
            start = nil
            taken = nil
            slow = nil
            holding(false)
            done()
            if !bounds.contains(convert(event.locationInWindow, from: nil)) { hover(false) }
        }
    }
}

/// A number of points, typed in and taken on Return or leaving the field.
private struct SizeField: View {
    let value: CGFloat
    let set: (CGFloat) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            .multilineTextAlignment(.center)
            .frame(width: 44, height: 22)
            .background(Palette.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
            .focused($focused)
            .onAppear { text = String(Int(value)) }
            .onChange(of: value) { _, now in if !focused { text = String(Int(now)) } }
            .onSubmit(take)
            .onChange(of: focused) { _, now in if !now { take() } }
    }

    private func take() {
        guard let number = Double(text.trimmingCharacters(in: .whitespaces)), number > 0 else {
            text = String(Int(value))
            return
        }
        if CGFloat(number) != value { set(CGFloat(number)) }
    }
}
