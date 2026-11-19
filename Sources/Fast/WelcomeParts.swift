import SwiftUI
import AppKit
import QuartzCore

// design: file, the welcome's drawing of Yab's own parts at their own sizes (the tab row, the column, the page, the box, the dock, the chat, the window-to-be) and of sample sites' pages

// Yab's own parts, as the welcome lays them out: each at the app's own
// size, with the app's own metrics (TabBar, Side, Omnibox, AgentDock,
// ChatColumn, LinkPeek), so the words are readable and exactly Yab. What a
// part holds that can come, go or move on its own (a tab, a pin, a row of
// the box) is a part of its own inside it, with its own key. The sample
// sites' pages are drawn here too, as the sites would draw them.
//
// Everything here is drawn once per board and then only moved: the faces
// and folders are Core Animation layers that change only when their pose
// does, the waiting ring is the one loop and turns only while it is shown,
// and the only SwiftUI motion is the box row's MorphText and the dock's
// words crossing.
//
// This file is the only one in the welcome that draws at its own sizes; it
// says so in its first lines.

// MARK: - marks

/// A sample site's stand-in: a FeatureTile square with a Central glyph,
/// never a brand's favicon.
enum WelcomeSite: String, CaseIterable {
    case mail, calendar, code, tracker, docs, video, music, photo, chat, book, news, globe

    var icon: String {
        switch self {
        case .mail: return "envelope.fill"
        case .calendar: return "calendar"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .tracker: return "square.2.layers.3d"
        case .docs: return "doc.text"
        case .video: return "play.fill"
        case .music: return "music.note"
        case .photo: return "photo"
        case .chat: return "bubble"
        case .book: return "book"
        case .news: return "doc.text.fill"
        case .globe: return "globe"
        }
    }

    var tint: NSColor {
        switch self {
        case .mail: return .systemBlue
        case .calendar, .video: return .systemRed
        case .code: return WelcomeHue.hex(0x1F2328)
        case .tracker: return .systemIndigo
        case .docs: return .systemOrange
        case .music: return .systemPink
        case .photo: return .systemTeal
        case .chat: return .systemGreen
        case .book: return .systemBrown
        case .news: return .systemCyan
        case .globe: return .systemGray
        }
    }
}

/// What a tab or a pin wears: a sample site's mark, or a real page's
/// picture (a pin brought in from another browser).
enum WelcomeMark {
    case site(WelcomeSite)
    case picture(NSImage)
}

/// An app's own icon on the stage.
enum WelcomeIcon {
    /// An agent's app icon (AgentIcons), or its tile when the app isn't here.
    case agent(String)
    /// A picture already found: a browser's icon, from Bringing.
    case picture(NSImage?)
    /// Data survives after the app is removed: its first letter on the icon grid.
    case letter(String)
    /// An app of this Mac by bundle id, in the Mac's look: Mail, Messages, Slack.
    case app(String)
    /// A password manager's own icon by its provider id, set on the app
    /// grid's 0.8 square, its ring following its own shape (WelcomeVault).
    case manager(String)
}

// MARK: - the row's and the column's things

/// One thing in the row of tabs or down the column: the prototype's items.
/// A keyed one is a part of its own inside the row, so it comes, goes and
/// moves by itself.
struct WelcomeTab {
    enum Kind: Equatable {
        case pin, tab
        /// A tab squeezed to its icon.
        case compact
        case folder
        /// An open folder's capsule, holding the folder's pill and its tabs.
        case nest
        case gap
        case plus
        /// The window's three lights, inside the window-to-be.
        case lights
        /// The column's New tab row.
        case newTab
        /// The column's line under what is kept.
        case hairline
    }

    var kind: Kind
    var key: String?
    var mark: WelcomeMark?
    var title = ""
    /// A tab's width: 186 giving way to 150 or 136. A gap's.
    var width: CGFloat = 150
    /// The live tab: a ground chip with its ring.
    var on = false
    /// An agent's face at the tab's end.
    var face: FacePose?
    var open = false
    /// A shut folder's count, at 10.5 faint.
    var count = 0
    /// An agent's folder: the folder wears its eyes.
    var task = false
    var unread = false
    /// A folder's child in the column: 12 in.
    var indent = false
    var items: [WelcomeTab] = []
    var enter: StagePart.Enter?
    var delay: Double?

    static func pin(_ mark: WelcomeSite, key: String? = nil, on: Bool = false, enter: StagePart.Enter? = nil, delay: Double? = nil) -> WelcomeTab {
        WelcomeTab(kind: .pin, key: key, mark: .site(mark), on: on, enter: enter, delay: delay)
    }

    static func pin(_ mark: WelcomeMark, key: String? = nil, enter: StagePart.Enter? = nil, delay: Double? = nil) -> WelcomeTab {
        WelcomeTab(kind: .pin, key: key, mark: mark, enter: enter, delay: delay)
    }

    static func tab(_ title: String, _ mark: WelcomeSite?, width: CGFloat = 150, key: String? = nil, on: Bool = false, face: FacePose? = nil,
                    indent: Bool = false, enter: StagePart.Enter? = nil, delay: Double? = nil) -> WelcomeTab {
        WelcomeTab(kind: .tab, key: key, mark: mark.map { .site($0) }, title: title, width: width, on: on, face: face, indent: indent, enter: enter, delay: delay)
    }

    static func icon(_ mark: WelcomeSite, key: String? = nil, on: Bool = false) -> WelcomeTab {
        WelcomeTab(kind: .compact, key: key, mark: .site(mark), width: 30, on: on)
    }

    static func folder(_ name: String, open: Bool = false, count: Int = 0, task: Bool = false, key: String? = nil,
                       enter: StagePart.Enter? = nil, delay: Double? = nil) -> WelcomeTab {
        WelcomeTab(kind: .folder, key: key, title: name, open: open, count: count, task: task, enter: enter, delay: delay)
    }

    static func nest(key: String? = nil, _ items: [WelcomeTab], enter: StagePart.Enter? = nil, delay: Double? = nil) -> WelcomeTab {
        WelcomeTab(kind: .nest, key: key, items: items, enter: enter, delay: delay)
    }

    static func gap(_ width: CGFloat) -> WelcomeTab { WelcomeTab(kind: .gap, width: width) }
    static func plus(key: String? = nil) -> WelcomeTab { WelcomeTab(kind: .plus, key: key, width: 30) }
    static let lights = WelcomeTab(kind: .lights, width: 75)
    static func newTab(key: String? = nil) -> WelcomeTab { WelcomeTab(kind: .newTab, key: key, title: "New tab") }
    static let hairline = WelcomeTab(kind: .hairline)
}

// MARK: - the box's rows

/// A row of the ⌘T box under its field.
struct WelcomeBoxRow {
    enum Mark {
        case site(WelcomeSite)
        /// A Central glyph in the gray well.
        case well(String)
        /// A feature's tile.
        case tile(String, NSColor)
        /// An agent's own icon, 22.
        case agent(String)
    }

    /// What kind of row, at its end, as the box says it; the chosen row
    /// keeps its keys.
    enum End {
        case none
        case words(String)
        /// Keys on their plates: "⌘ J".
        case keys(String)
    }

    var key: String
    var mark: Mark
    var title: String
    var detail: String?
    var end: End = .none
    var chosen = false
    var enter: StagePart.Enter?
    var delay: Double?

    init(key: String, mark: Mark, title: String, detail: String? = nil, end: End = .none, chosen: Bool = false,
         enter: StagePart.Enter? = nil, delay: Double? = nil) {
        self.key = key
        self.mark = mark
        self.title = title
        self.detail = detail
        self.end = end
        self.chosen = chosen
        self.enter = enter
        self.delay = delay
    }
}

/// The box's foot: one glass pill at its bottom right, what Return does
/// to the chosen row and Actions with its keys, as FieldFoot has it.
struct WelcomeBoxFoot {
    var primary: String
    /// Actions ⌘K after it: the row has more than what Return does.
    var actions = true
}

// MARK: - pages

/// The sample sites' pages, drawn as the sites would draw them.
enum WelcomePage: Equatable {
    /// linear.app: Design · Y-214, "Peek keeps its scroll". Its link, "Read
    /// the Peek spec", is a part of its own keyed "link", for the Peek to
    /// grow out of and for the press.
    case tracker
    /// docs.google.com: "Peek spec".
    case spec
    /// github.com: #482 Sidebar width, the review asking for changes, the checks.
    case pullRequest(narrow: Bool)
    /// A New Tab: the field "Enter a web address".
    case newTab
    /// docs.google.com: "Launch notes", shared in Slack.
    case launchNotes
}

/// How a page stands off the stage.
enum WelcomePageEdge {
    /// A hairline ring and a card's shadow.
    case card
    /// The Split View pane in front: the accent, 1.5 inside its edge, as
    /// the approved prototype rings it.
    case front
    /// Peek's panel: a hairline ring and a lifted shadow.
    case peek
}

// MARK: - the agent's column

enum WelcomeChatBody {
    case working(String)
    case answer([WelcomeAnswer])
}

struct WelcomeAnswer {
    var mark: WelcomeSite
    var title: String
    var state: String
}

// MARK: - the window-to-be

/// How the window-to-be wears the look chosen.
struct WelcomeWindowLook {
    var sidebar: Bool
    var backdrop: Backdrop
    /// A color's, as the window wears it in this look.
    var color: NSColor
    var grain: Double
    var transparency: Double
    /// Spaces that came with colors, and the one on screen.
    var spaces: [NSColor] = []
    var space = 0
    /// The colors after the main one, as worn, and how far they have
    /// turned (Shift with tabs); the drawings over them and how strong.
    var colors: [NSColor] = []
    var step = 0
    var drawings = ""
    var strength = LookDrawings.standard

    /// How strongly the window-to-be wears its color. The window has the
    /// desktop under it, its see-through color tinting what shows; here
    /// there is only the stage's pale gray, and a color nearly see-through
    /// read as no color at all (a report, 2026-10-22: A color picked, a gray
    /// window). So at least about half of it, the slider still going all
    /// the way.
    static func opacity(_ transparency: Double) -> Double {
        0.45 + 0.55 * BackdropTransparency.opacity(transparency)
    }

    /// What the window's tint is drawn from, to draw it again only when it changes.
    var tint: String {
        ([color.hex] + colors.map(\.hex) + ["\(step)", drawings, "\(strength)", "\(transparency)"]).joined(separator: " ")
    }

    init(sidebar: Bool, backdrop: Backdrop, color: NSColor, grain: Double, transparency: Double = 0, spaces: [NSColor] = [], space: Int = 0) {
        self.sidebar = sidebar
        self.backdrop = backdrop
        self.color = color
        self.grain = grain
        self.transparency = transparency
        self.spaces = spaces
        self.space = space
    }
}

/// What is yours in the window-to-be: what came, or nothing but a New Tab.
struct WelcomeYoursThings {
    var pins: [WelcomeMark] = []
    var folders: [(name: String, count: Int)] = []

    init(pins: [WelcomeMark] = [], folders: [(name: String, count: Int)] = []) {
        self.pins = pins
        self.folders = folders
    }
}

enum WelcomeWindowPage: Equatable {
    case newTab
    /// Chapter 6's shared doc; `landed` once the link has become the tab.
    case launchNotes(landed: Bool)
}

// MARK: - ink

/// The colors a row or a column is drawn in: the stage's own, on the
/// plate; or a backdrop's, where the words and the folders are the color
/// itself, deepened on a light one and paled on a dark one, and the veil
/// and the live chip lie over it (the prototype's inkVars).
struct WelcomeInk {
    /// The live tab's words.
    var ink: NSColor
    /// A folder's name, and its outline.
    var strong: NSColor
    var muted: NSColor
    var faint: NSColor
    /// A folder's back, and its front.
    var back: NSColor
    var body: NSColor
    /// A pin's ground, an open folder's capsule.
    var veil: NSColor
    /// The live tab's ground, and its ring.
    var chip: NSColor
    var ring: NSColor
    /// Which it is, for a drawing's version.
    var id: String

    static let stage = WelcomeInk(
        ink: Palette.NS.ink,
        strong: WelcomeHue.pair(0x3A3A3E, 0xDADADE),
        muted: Palette.NS.muted,
        faint: Palette.NS.faint,
        back: WelcomeHue.pair(0xCBCBD0, 0x3A3A3E),
        body: WelcomeHue.pair(0xFAFAFB, 0x5A5A60),
        veil: WelcomeHue.pair(WelcomeHue.hex(0x171717, 0.05), WelcomeHue.hex(0xEDEDED, 0.06)),
        chip: WelcomeHue.pair(.white, NSColor(white: 1, alpha: 0.11)),
        ring: WelcomeHue.pair(NSColor(white: 0, alpha: 0.07), NSColor(white: 1, alpha: 0.08)),
        id: "stage"
    )

    /// On a backdrop of this color.
    static func on(_ backdrop: NSColor) -> WelcomeInk {
        let color = backdrop.usingColorSpace(.sRGB) ?? backdrop
        let r = color.redComponent, g = color.greenComponent, b = color.blueComponent
        func mix(_ to: CGFloat, _ t: CGFloat) -> NSColor {
            NSColor(srgbRed: r + (to - r) * t, green: g + (to - g) * t, blue: b + (to - b) * t, alpha: 1)
        }
        if 0.2126 * r + 0.7152 * g + 0.0722 * b > 0.45 {
            return WelcomeInk(ink: NSColor(white: 0.09, alpha: 1), strong: mix(0, 0.72), muted: mix(0, 0.45), faint: mix(0, 0.28),
                              back: mix(0, 0.16), body: mix(1, 0.8), veil: NSColor(white: 0, alpha: 0.05),
                              chip: NSColor(white: 1, alpha: 0.9), ring: stage.ring, id: color.hex)
        }
        return WelcomeInk(ink: NSColor(white: 0.93, alpha: 1), strong: mix(1, 0.8), muted: mix(1, 0.5), faint: mix(1, 0.3),
                          back: mix(1, 0.2), body: mix(1, 0.45), veil: NSColor(white: 1, alpha: 0.07),
                          chip: NSColor(white: 1, alpha: 0.14), ring: stage.ring, id: color.hex)
    }
}

/// Colors by their six hex digits, and pairs of them for a light and a
/// dark window, resolved wherever they are drawn.
private enum WelcomeHue {
    static func hex(_ value: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(value >> 16 & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
    }

    static func pair(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    static func pair(_ light: UInt32, _ dark: UInt32) -> NSColor { pair(hex(light), hex(dark)) }
}

/// The copy the sample pages share with the parts laid over them.
private enum WelcomeCopy {
    static let trackerBody = "When a link opens in Peek and you close it, the page under it should stay where you left it. Today it jumps back to the top."
    static let link = "Read the Peek spec"
}

// MARK: - the parts

@MainActor
enum WelcomeParts {
    // The drawing's own colors, where the app has none: the plate the row
    // and the column stand on, #ECECED and #2A2A2D.
    static let plate = WelcomeHue.pair(0xECECED, 0x2A2A2D)
    /// A folder's words and line: stronger than muted, softer than ink.
    static let strong = Color(nsColor: WelcomeInk.stage.strong)
    static let veil = Color(nsColor: WelcomeInk.stage.veil)
    static let chip = Color(nsColor: WelcomeInk.stage.chip)
    static let ring = Color(nsColor: WelcomeInk.stage.ring)
    static let ink82 = Palette.ink.opacity(0.82)
    /// The site's color under Launch notes: the docs' own blue, carried up.
    static let siteTint = WelcomeHue.pair(0xE3ECF8, 0x1F2937)

    // MARK: the row of tabs

    /// The row of tabs, as TabBar draws it: 40 tall, corner 14, the plate,
    /// Shadow.card; 5 in, things 2 apart. `plate: false` inside the
    /// window-to-be, where the row stands on the backdrop.
    static func row(_ key: String, _ frame: CGRect, _ items: [WelcomeTab], enter: StagePart.Enter? = nil, delay: Double? = nil,
                    exit: StagePart.Exit = .shrink, plate: Bool = true) -> StagePart {
        var part = StagePart(key, frame, plate: plate ? StagePlate(fill: Self.plate, corner: 14, shadow: Shadow.card) : nil,
                             enter: enter, delay: delay, exit: exit)
        part.children = lay(items, in: key, x: 5, height: frame.height, ink: .stage, unit: 1, end: frame.width)
        return part
    }

    /// A slice of your row on a wash well: Calendar's. 9 in on a 48 well,
    /// 5 on a 40 one.
    static func strip(_ key: String, _ frame: CGRect, _ items: [WelcomeTab], corner: CGFloat, enter: StagePart.Enter? = nil, delay: Double? = nil) -> StagePart {
        var part = StagePart(key, frame, plate: StagePlate(fill: Palette.NS.wash, corner: corner), enter: enter, delay: delay)
        let inset: CGFloat = frame.height > 40 ? 9 : 5
        part.children = lay(items, in: key, x: inset, height: frame.height, ink: .stage, unit: 1, end: frame.width)
        return part
    }

    /// The things of a row, left to right, 2 apart, each a part (a gap is
    /// room of its own, with the row's 2 on either side, as the prototype's
    /// flex row has it); an open folder's capsule holds its own. What runs
    /// past `end`, the row's own edge (its padding given up first, as the
    /// prototype's clipped row does), is cut: a tab that crosses it gives
    /// way to what is left, anything else past it isn't there.
    private static func lay(_ items: [WelcomeTab], in parent: String, x start: CGFloat, height: CGFloat, ink: WelcomeInk, unit: CGFloat,
                            end: CGFloat = .infinity) -> [StagePart] {
        var x = start
        var parts: [StagePart] = []
        let tall = 30 * unit
        for (index, item) in items.enumerated() where item.kind != .newTab && item.kind != .hairline {
            var width = self.width(of: item) * unit
            defer { x += width + 2 * unit }
            guard item.kind != .gap else { continue }
            if x + width > end {
                guard item.kind == .tab, end - x >= 80 * unit else { break }
                width = end - x
            }
            let frame = CGRect(x: x, y: (height - tall) / 2, width: width, height: tall)
            let key = item.key ?? "\(parent).\(index)"
            if item.kind == .nest {
                var nest = StagePart(key, frame, plate: StagePlate(fill: ink.veil, corner: Radius.control * unit), enter: item.enter, delay: item.delay)
                nest.children = lay(item.items, in: key, x: 0, height: tall, ink: ink, unit: unit)
                parts.append(nest)
            } else {
                parts.append(StagePart(key, frame, drawing: drawn(RowThing(item: item, ink: ink), frame.size, unit),
                                       enter: item.enter, delay: item.delay, version: version(of: item, ink, frame.size)))
            }
        }
        return parts
    }

    /// How wide a thing of the row is.
    static func width(of item: WelcomeTab) -> CGFloat {
        switch item.kind {
        case .pin, .compact, .plus: return 30
        case .tab, .gap: return item.width
        case .lights: return 75
        case .folder:
            let name = measure(item.title, NSFont.systemFont(ofSize: 12.5, weight: .medium))
            let count = item.open ? 0 : 6 + measure("\(item.count)", NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular))
            return ceil(8 + 15 + 6 + name + count + 9 + (item.unread ? 13 : 0))
        case .nest:
            let inner = item.items.filter { $0.kind != .newTab && $0.kind != .hairline }.map(width(of:))
            return inner.reduce(0, +) + CGFloat(max(inner.count - 1, 0)) * 2
        case .newTab, .hairline: return 0
        }
    }

    private static func measure(_ text: String, _ font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    // MARK: the column

    /// The sample column sits directly on the window's ground.
    static func column(_ key: String, _ frame: CGRect, pins: [WelcomeTab], rows: [WelcomeTab], lights: Bool = false,
                       enter: StagePart.Enter? = nil, delay: Double? = nil, exit: StagePart.Exit = .shrink, plate: Bool = false) -> StagePart {
        var part = StagePart(key, frame, plate: plate ? StagePlate(fill: Self.plate, corner: Radius.surface, shadow: Shadow.card) : nil,
                             enter: enter, delay: delay, exit: exit)
        part.children = sampleColumnParts(key, frame.size, pins: pins, rows: rows)
        return part
    }

    private static func sampleColumnParts(_ key: String, _ size: CGSize, pins: [WelcomeTab], rows: [WelcomeTab]) -> [StagePart] {
        var parts = [StagePart(key + ".head", CGRect(x: 0, y: 0, width: size.width, height: 85),
                               drawing: .view(AnyView(SampleColumnHead())), version: "head")]
        let square = (size.width - 16 - 24) / 4
        for (index, item) in pins.prefix(4).enumerated() {
            let frame = CGRect(x: 8 + CGFloat(index) * (square + 8), y: 93, width: square, height: 36)
            parts.append(StagePart(item.key ?? "\(key).pin\(index)", frame,
                                   drawing: .view(AnyView(SamplePin(mark: item.mark))), version: version(of: item, .stage, frame.size)))
        }
        parts.append(StagePart(key + ".space", CGRect(x: 8, y: 137, width: size.width - 16, height: 36),
                               drawing: .view(AnyView(HStack(spacing: 6) {
                                   Text("💼")
                                   Text("Work").font(.system(size: 12.5, weight: .semibold))
                                   Spacer(minLength: 0)
                               }.foregroundStyle(Palette.muted).padding(.horizontal, 10))), version: "work"))
        for (index, item) in rows.enumerated() {
            let frame = CGRect(x: 8, y: 177 + CGFloat(index) * 40, width: size.width - 16, height: 36)
            let view: AnyView
            if item.kind == .hairline {
                view = AnyView(Rectangle().fill(Palette.hairline).frame(height: 1).padding(.horizontal, 10))
            } else {
                view = AnyView(SampleColumnRow(item: item))
            }
            parts.append(StagePart(item.key ?? "\(key).row\(index)", frame, drawing: .view(view),
                                   enter: item.enter, delay: item.delay, version: version(of: item, .stage, frame.size)))
        }
        parts.append(StagePart(key + ".foot", CGRect(x: 8, y: size.height - 34, width: size.width - 16, height: 26),
                               drawing: .view(AnyView(SampleColumnFoot())), version: "foot"))
        return parts
    }

    /// The column's things in its own points, `unit` stage points to each
    /// of the app's.
    private static func columnParts(_ key: String, _ size: CGSize, pins: [WelcomeTab], rows: [WelcomeTab], lights: String?,
                                    dots: (count: Int, current: Int)?, ink: WelcomeInk, unit u: CGFloat) -> [StagePart] {
        var children: [StagePart] = []
        var y = 10 * u
        let inner = size.width - 20 * u
        if let lights {
            // The window's three at 20, 20, in the same frame the row
            // gives them, so they glide rather than stretch between the two.
            let frame = CGRect(x: 11 * u, y: 11 * u, width: 75 * u, height: 30 * u)
            children.append(StagePart(lights, frame, drawing: drawn(RowThing(item: .lights, ink: ink), frame.size, u),
                                      version: "lights \(frame.size)"))
            y += 32 * u
        }
        let square = (inner - 8 * u) / 3
        for (index, item) in pins.enumerated() {
            var pin = item
            pin.kind = .pin
            let frame = CGRect(x: 10 * u + CGFloat(index % 3) * (square + 4 * u), y: y + CGFloat(index / 3) * 38 * u, width: square, height: 34 * u)
            children.append(StagePart(item.key ?? "\(key).pin\(index)", frame, drawing: drawn(RowThing(item: pin, ink: ink), frame.size, u),
                                      enter: item.enter, delay: item.delay, version: version(of: pin, ink, frame.size)))
        }
        if !pins.isEmpty { y += (CGFloat((pins.count + 2) / 3) * 38 - 4 + 10) * u }
        for (index, item) in rows.enumerated() {
            if item.kind == .hairline {
                let frame = CGRect(x: 18 * u, y: y + 6 * u, width: inner - 16 * u, height: u)
                children.append(StagePart(item.key ?? "\(key).line\(index)", frame, drawing: .view(AnyView(Rectangle().fill(Color(nsColor: ink.ring)))),
                                          enter: item.enter, delay: item.delay, version: "line \(ink.id)"))
                y += 15 * u
                continue
            }
            let lead: CGFloat = item.indent ? 12 * u : 0
            let frame = CGRect(x: 10 * u + lead, y: y, width: inner - lead, height: 28 * u)
            children.append(StagePart(item.key ?? "\(key).row\(index)", frame, drawing: drawn(ColumnRow(item: item, ink: ink), frame.size, u),
                                      enter: item.enter, delay: item.delay, version: version(of: item, ink, frame.size)))
            y += 30 * u
        }
        if let dots, dots.count > 1 {
            let frame = CGRect(x: 0, y: size.height - 19 * u, width: size.width, height: 7 * u)
            children.append(StagePart(key + ".dots", frame, drawing: drawn(SpaceDots(count: dots.count, current: dots.current, ink: ink), frame.size, u),
                                      version: "dots \(dots.count) \(dots.current) \(ink.id) \(frame.size)"))
        }
        return children
    }

    /// A drawing at `unit` stage points to each of its own: laid out at its
    /// own size and scaled, so the window-to-be can be built in the real
    /// window's points on a stage that is scaled.
    private static func drawn<V: View>(_ view: V, _ size: CGSize, _ unit: CGFloat) -> StagePart.Drawing {
        guard unit != 1 else { return .view(AnyView(view)) }
        return .view(AnyView(view
            .frame(width: size.width / unit, height: size.height / unit)
            .scaleEffect(unit, anchor: .topLeading)
            .frame(width: size.width, height: size.height, alignment: .topLeading)))
    }

    /// What a thing of the row looks like, as one string: the same, and
    /// SwiftUI isn't asked to draw it again.
    private static func version(of item: WelcomeTab, _ ink: WelcomeInk, _ size: CGSize) -> String {
        let mark: String
        switch item.mark {
        case .site(let site): mark = site.rawValue
        case .picture(let image): mark = "\(ObjectIdentifier(image).hashValue)"
        case nil: mark = ""
        }
        let face = item.face.map { "\($0)" } ?? ""
        return "\(item.kind) \(mark) \(item.title) \(item.on) \(face) \(item.open) \(item.count) \(item.task) \(item.unread) \(ink.id) \(size)"
    }

    // MARK: pages

    /// A page: the ground at corner 10 with a 1 pt ring and a shadow, the
    /// site's content 28 down and 36 in. It keeps its place and reshapes
    /// under its content (a page going to half width).
    static func page(_ key: String, _ frame: CGRect, _ page: WelcomePage, edge: WelcomePageEdge = .card,
                     enter: StagePart.Enter? = nil, delay: Double? = nil, exit: StagePart.Exit = .shrink) -> StagePart {
        let plate: StagePlate
        switch edge {
        case .card: plate = StagePlate(fill: Palette.NS.ground, corner: Radius.surface, ring: Palette.NS.hairline, shadow: Shadow.card)
        case .front: plate = StagePlate(fill: Palette.NS.ground, corner: Radius.surface, ring: .controlAccentColor, ringWidth: 1.5, shadow: Shadow.card)
        case .peek: plate = StagePlate(fill: Palette.NS.ground, corner: Radius.surface, ring: Palette.NS.hairline, shadow: Shadow.lift)
        }
        var part = StagePart(key, frame, drawing: .view(AnyView(PageDrawing(page: page))), plate: plate,
                             enter: enter, delay: delay, exit: exit, resize: .pin, version: "\(page)")
        if page == .tracker {
            part.children = [StagePart("link", linkFrame(in: frame.width), drawing: .view(AnyView(PageLink())), version: "link")]
        }
        return part
    }

    /// Where "Read the Peek spec" sits on the tracker's page this wide: its
    /// own line under the paragraph, which wraps at the page's width less
    /// 36 each side, or at 640.
    static func linkFrame(in width: CGFloat) -> CGRect {
        let font = NSFont.systemFont(ofSize: 14)
        let measure = { (text: String, wide: CGFloat) -> CGFloat in
            (text as NSString).boundingRect(with: CGSize(width: wide, height: 4000), options: [.usesLineFragmentOrigin],
                                            attributes: [.font: font]).height
        }
        let one = measure("Peek", 1000)
        let lines = max(1, (measure(WelcomeCopy.trackerBody, max(1, min(width - 72, 640))) / max(one, 1)).rounded())
        let link = (WelcomeCopy.link as NSString).size(withAttributes: [.font: font]).width
        // 28 in, the crumb 16 and its 16, the heading 28 and its 12, the
        // chips 22 and their 18, the paragraph's lines and its 12.
        return CGRect(x: 36, y: 140 + lines * 22 + 12, width: ceil(link), height: 22)
    }

    // MARK: the box

    /// The ⌘T box as the Omnibox draws it: 750 wide, or over a narrower
    /// page as wide as it less 16 each side (Omnibox.width), corner 26,
    /// the material under glass tinted with the ground, the field 58 tall
    /// (glass 20, words 20), no line under it, rows 38 with 22 tiles, the
    /// chosen one on an ink veil of 0.08, the list 8 in, and the foot's
    /// pill under the rows ("KEY-foot"). `height`: the real box's own,
    /// one height whatever it holds, the rows at its top and the pill at
    /// its foot; without it, as tall as its rows. The field's words are
    /// typed through WelcomeTyping under the box's key.
    static func box(_ key: String = "box", at origin: CGPoint, width: CGFloat = Metrics.fieldWidth, height fixed: CGFloat? = nil,
                    query: String?, placeholder: String = "Search or enter address", keys: String? = nil, rows: [WelcomeBoxRow] = [],
                    foot: WelcomeBoxFoot? = nil, enter: StagePart.Enter? = nil, delay: Double? = nil,
                    exit: StagePart.Exit = .shrink) -> StagePart {
        let list = rows.isEmpty ? 0 : Omnibox.inset + CGFloat(rows.count) * Omnibox.rowHeight + (foot == nil ? Omnibox.inset : FieldFoot.room)
        let height = fixed ?? Omnibox.fieldHeight + list
        var part = StagePart(key, CGRect(x: origin.x, y: origin.y, width: width, height: height),
                             drawing: .view(AnyView(BoxDrawing(field: key, query: query, placeholder: placeholder, keys: keys))),
                             enter: enter, delay: delay, exit: exit, resize: .pin,
                             version: "\(query ?? "-") \(placeholder) \(keys ?? "")")
        part.children = rows.enumerated().map { index, row in
            StagePart(row.key, CGRect(x: Omnibox.inset, y: Omnibox.fieldHeight + Omnibox.inset + CGFloat(index) * Omnibox.rowHeight,
                                      width: width - 2 * Omnibox.inset, height: Omnibox.rowHeight),
                      drawing: .view(AnyView(BoxRowDrawing(row: row))), enter: row.enter, delay: row.delay, version: row.version)
        }
        if let foot, !rows.isEmpty {
            part.children.append(StagePart(key + "-foot", CGRect(x: 0, y: height - FieldFoot.room, width: width, height: FieldFoot.room),
                                           drawing: .view(AnyView(BoxFootDrawing(foot: foot))), enter: .fade,
                                           delay: (rows.compactMap(\.delay).max() ?? 0) + 0.03,
                                           version: "\(foot.primary) \(foot.actions)"))
        }
        return part
    }

    // MARK: the agent

    /// AgentDock's HUD at a page's foot, centered on it, 16 above its
    /// bottom: 36 tall, corner 12, dark in both looks; the face, the words,
    /// Take Over with ⌘ . on its plates. The part is wider and taller than
    /// the HUD, so its shadow and a long line of words have room.
    static func dock(_ key: String = "dock", under page: CGRect, words: String,
                     enter: StagePart.Enter? = nil, delay: Double? = nil, exit: StagePart.Exit = .sink) -> StagePart {
        let width = max(page.width, 480)
        return StagePart(key, CGRect(x: page.midX - width / 2, y: page.maxY - 16 - 36 - 12, width: width, height: 36 + 12 + 32),
                         drawing: .view(AnyView(DockDrawing(words: words))), enter: enter, delay: delay, exit: exit, version: words)
    }

    /// The agent's face on a white disc, 28 round, over what it reads; the
    /// part has room round it for the disc's shadow.
    static func disc(_ key: String = "disc", at center: CGPoint, enter: StagePart.Enter? = nil, delay: Double? = nil) -> StagePart {
        StagePart(key, CGRect(x: center.x - 26, y: center.y - 26, width: 52, height: 52),
                  drawing: .view(AnyView(DiscDrawing())), enter: enter, delay: delay, version: "disc")
    }

    /// The current chat: floating face and name, Messages bubbles and the
    /// composer's glass. Answers keep their own parts for the staged arrival.
    static func chat(_ key: String, _ frame: CGRect, task: String, body: WelcomeChatBody,
                     enter: StagePart.Enter? = nil, delay: Double? = nil, exit: StagePart.Exit = .shrink) -> StagePart {
        let part = StagePart(key, frame, drawing: .view(AnyView(ChatDrawing(task: task, content: body))),
                             plate: StagePlate(fill: Palette.NS.ground, corner: Radius.surface, ring: Palette.NS.hairline, shadow: Shadow.card),
                             enter: enter, delay: delay, exit: exit, resize: .pin, version: "\(task) \(body)")
        return part
    }

    /// Peek's three buttons, 12 right of its panel, 28 round, 8 apart, with
    /// LinkPeek's own ring and shadow: close, Open as Tab, Split View. Each a
    /// part ("KEY-close", "KEY-open", "KEY-split"), so Split View can be
    /// pressed; each has room round it for its shadow.
    static func peekButtons(_ key: String, at origin: CGPoint, enter: StagePart.Enter? = .fade, delay: Double? = 0.1) -> StagePart {
        var part = StagePart(key, CGRect(x: origin.x, y: origin.y, width: 28, height: 100), enter: enter, delay: delay)
        part.children = [("close", "xmark"), ("open", "arrow.up.left.and.arrow.down.right"), ("split", "rectangle.split.2x1")]
            .enumerated().map { index, button in
                StagePart(key + "-" + button.0, CGRect(x: -12, y: CGFloat(index) * 36 - 12, width: 52, height: 52),
                          drawing: .view(AnyView(PeekButtonDrawing(icon: button.1))), version: button.1)
            }
        return part
    }

    // MARK: marks

    /// An app's own icon at its size, its square 0.805 of the picture, with
    /// the waiting ring round the square and DoneTick at its corner, each a
    /// part of its own ("KEY-ring", "KEY-tick"). A click chooses it.
    static func mark(_ key: String, _ frame: CGRect, _ icon: WelcomeIcon, ring: Bool = false, tick: Bool = false, tickEnters: Bool = true,
                     dim: Bool = false, enter: StagePart.Enter? = nil, delay: Double? = nil, exit: StagePart.Exit = .shrink,
                     action: (() -> Void)? = nil) -> StagePart {
        var part = StagePart(key, frame, drawing: .view(AnyView(MarkDrawing(icon: icon, side: frame.width, dim: dim, action: action))),
                             enter: enter, delay: delay, exit: exit, takesClicks: action != nil)
        let square = frame.width * 0.805
        let inset = (frame.width - square) / 2
        if ring {
            let (rect, corner) = ringFrame(icon, side: frame.width)
            let diamond = ringDiamond(icon)
            part.children.append(StagePart(key + "-ring", rect, drawing: .layer({ WelcomeRingLayer(side: rect.width, corner: corner, diamond: diamond) }), enter: .ring))
        }
        if tick {
            // Its middle a little in from the square's corner, and a ring
            // of the stage's ground round it, 2 wide.
            let side = (square * 0.3).rounded()
            let x = frame.width - inset - side * 0.72
            part.children.append(StagePart(key + "-tick", CGRect(x: x - 2, y: x - 2, width: side + 4, height: side + 4),
                                           drawing: .view(AnyView(TickDrawing(side: side))),
                                           enter: tickEnters ? .tick : StagePart.Enter.none, version: "tick \(side)"))
        }
        return part
    }

    /// The chosen mark's ring, still, at the mark's `frame` on the stage:
    /// out of the icon to its place, back into it when another is chosen.
    static func pick(_ key: String, _ frame: CGRect, _ icon: WelcomeIcon, delay: Double? = nil) -> StagePart {
        let (rect, corner) = ringFrame(icon, side: frame.width)
        var part = StagePart(key, rect.offsetBy(dx: frame.minX, dy: frame.minY),
                             drawing: .layer({ WelcomeRingLayer(side: rect.width, corner: corner, still: true, diamond: ringDiamond(icon)) }),
                             enter: .pick, delay: delay, exit: .tuck)
        part.version = "pick \(corner)"
        return part
    }

    /// A ring's layer in its mark's points, its line 6 out from the icon's
    /// square and 2 wide, and its corner, 6 more than the icon's.
    /// A diamond icon's ring is a diamond (Proton Pass).
    static func ringDiamond(_ icon: WelcomeIcon) -> Bool {
        if case .manager(let id) = icon { return WelcomeVault.diamond(id) }
        return false
    }

    static func ringFrame(_ icon: WelcomeIcon, side: CGFloat) -> (CGRect, CGFloat) {
        // A diamond: 7 out from the icon's solid shape along each side, so
        // its half-diagonal is the shape's farthest reach |dx|+|dy| (measured,
        // WelcomeVault.reach) plus 7·√2, and what the round tips take back.
        if case .manager(let id) = icon, WelcomeVault.diamond(id) {
            let square = side * 0.8 / WelcomeVault.fill(id)
            let corner = square * 0.12
            let half = WelcomeVault.reach(id) * square + 7 * 2.0.squareRoot() + corner * (2.0.squareRoot() - 1)
            return (CGRect(x: side / 2 - half, y: side / 2 - half, width: 2 * half, height: 2 * half), corner)
        }
        // An agent's icon is drawn at 0.8 of the mark; an app's picture
        // holds its square at 0.8, as macOS's icon grid has it.
        let shape: (fill: CGFloat, corner: CGFloat)
        if case .agent(let cli) = icon { shape = AgentIcons.outline(cli) }
        else if case .manager(let id) = icon { shape = (1, WelcomeVault.corner(id)) }
        else { shape = (1, 0.226) }
        let square = side * 0.8 * shape.fill
        let inset = (side - square) / 2
        return (CGRect(x: inset - 7, y: inset - 7, width: square + 14, height: square + 14), square * shape.corner + 6)
    }

    // MARK: the terminal

    /// A Terminal window, drawn: #1D1D1D in both looks, corner 10, a 28
    /// strip with its three lights and its title, SF Mono 13 on 20. The line
    /// is typed through WelcomeTyping under the part's key.
    static func terminal(_ key: String, _ frame: CGRect, who: String, line: String,
                         enter: StagePart.Enter? = nil, delay: Double? = nil, exit: StagePart.Exit = .shrink) -> StagePart {
        StagePart(key, frame, drawing: .view(AnyView(TerminalDrawing(field: key, who: who, line: line))),
                  plate: StagePlate(fill: WelcomeHue.hex(0x1D1D1D), corner: Radius.surface, ring: NSColor(white: 0, alpha: 0.35),
                                    ringWidth: 0.5, shadow: Shadow.card),
                  enter: enter, delay: delay, exit: exit, version: "\(who) \(line)")
    }

    // MARK: the window-to-be

    /// Your parts docked on the window's backdrop, corner 18, a card's
    /// shadow: what is yours in the row (or the column), the page on the
    /// backdrop 8 in at corner 10, or to the edges. Keyed inside: "y-grain",
    /// "y-row" or "y-col" with "y-lights", "y-pin-N", "y-f-N", "y-launch"
    /// once a link has landed, "y-plus" (the row's), and "y-page". `pour`: the pins pour
    /// in from that many seconds, 30 ms apart, the folders 40 ms after them.
    /// At any rect: Finish builds it at the real window's, and `unit` (stage
    /// points to the window's; nil: 1, or flat, the corner's share of the
    /// window's 18) lays the row, the column and the page at the window's
    /// own metrics there. `samples`: with nothing yours, three sample
    /// tabs ("y-s-N"), the first open, so the row reads as tabs; `field`:
    /// ⌘T's field over the page ("y-box"), the compact card or the full
    /// box, as a window 1200 wide shows it.
    static func windowToBe(_ key: String, _ frame: CGRect, look: WelcomeWindowLook, yours: WelcomeYoursThings, page: WelcomeWindowPage,
                           empty: Bool = false, pour: Double? = nil, corner: CGFloat = Radius.window, flat: Bool = false,
                           samples: Bool = false, field compact: Bool? = nil,
                           enter: StagePart.Enter? = nil, delay: Double? = nil, exit: StagePart.Exit = .shrink, unit: CGFloat? = nil) -> StagePart {
        let u = unit ?? (flat ? corner / Radius.window : 1)
        let size = frame.size
        let landed = page == .launchNotes(landed: true)
        let launch = page != .newTab
        let paint = look.spaces.indices.contains(look.space) ? look.spaces[look.space] : look.color
        // Edge to edge wears the color too, in the row or the column round
        // the page; only the page's own margin and corner go.
        let painted = look.backdrop != .site
        let ground: NSColor = painted ? paint.withAlphaComponent(WelcomeWindowLook.opacity(look.transparency))
            : launch ? Self.siteTint : Self.plate
        let ink: WelcomeInk = painted ? .on(paint) : .stage
        let edge = look.backdrop == .none
        var part = StagePart(key, frame, plate: StagePlate(fill: ground, corner: corner, shadow: flat ? nil : Shadow.card),
                             enter: enter, delay: delay, exit: exit, resize: .pin)
        var children: [StagePart] = []
        if painted, look.spaces.isEmpty {
            // The colors after the main one and the drawings, over the
            // plate's color and under the grain, as the window has them.
            children.append(StagePart("y-tint", CGRect(origin: .zero, size: size), drawing: .view(AnyView(WelcomeTintDrawing(look: look, corner: corner))),
                                      enter: StagePart.Enter.none, exit: .none, version: "\(look.tint) \(corner)"))
            // How much of it is the part's own opacity, so a drag can set
            // it on "y-grain"'s layer at once; it comes with the window.
            children.append(StagePart("y-grain", CGRect(origin: .zero, size: size), drawing: .view(AnyView(GrainDrawing(amount: look.grain, corner: corner))),
                                      enter: StagePart.Enter.none, version: "\(look.grain) \(corner)"))
        }

        let pins: [WelcomeTab] = empty ? [] : yours.pins.enumerated().map { index, mark in
            .pin(mark, key: "y-pin-\(index)", enter: pour == nil ? nil : .pour, delay: pour.map { $0 + Double(index) * 0.03 })
        }
        let folders: [WelcomeTab] = empty ? [] : yours.folders.enumerated().map { index, folder in
            .folder(folder.name, count: folder.count, key: "y-f-\(index)", enter: pour == nil ? nil : .slideX,
                    delay: pour.map { $0 + Double(yours.pins.count) * 0.03 + 0.04 + Double(index) * 0.04 })
        }
        // A tab only once a link has landed: before that the window has
        // none in front, only the field (Browser.askNew).
        let live: WelcomeTab? = landed
            ? .tab("Launch notes", .docs, width: 136, key: "y-launch", on: true, enter: .fade)
            : nil
        // Nothing yours: sample tabs, so the row reads as where tabs go.
        let sampled: [WelcomeTab] = samples && !empty && yours.pins.isEmpty && yours.folders.isEmpty && live == nil
            ? Self.sampleTabs.enumerated().map { index, tab in
                .tab(tab.title, tab.site, width: 150, key: "y-s-\(index)", on: index == 0, enter: .fade, delay: Double(index) * 0.03)
            }
            : []
        var lights = WelcomeTab.lights
        lights.key = "y-lights"
        let shown: WelcomePage = landed ? .launchNotes : sampled.isEmpty ? .newTab : .tracker

        if look.sidebar {
            // What is kept, the line under it, then the live tab, where a
            // link that lands opens.
            // New tab under them as the column always has it, lit while
            // nothing is open and the field asks (Browser.newTabLit): an
            // empty column read as no column at all.
            var rows: [WelcomeTab] = folders
            if !rows.isEmpty { rows.append(.hairline) }
            var ask = WelcomeTab.newTab(key: "y-newtab")
            ask.on = live == nil && sampled.isEmpty
            rows.append(ask)
            if let live { rows.append(live) }
            rows += sampled
            var column = StagePart("y-col", CGRect(x: 0, y: 0, width: Metrics.side * u, height: size.height))
            column.children = columnParts("y-col", column.frame.size, pins: pins, rows: rows, lights: "y-lights",
                                          dots: look.spaces.isEmpty ? nil : (look.spaces.count, look.space), ink: ink, unit: u)
            children.append(column)
            let side = Metrics.side * u, inset = Backdrop.inset * u
            // Edge to edge, the page runs to the window's edges with a
            // hairline beside the column; on a backdrop, 8 in at corner 10.
            children.append(windowPage(shown, edge
                ? CGRect(x: side - u, y: 0, width: size.width - side + u, height: size.height)
                : CGRect(x: side, y: inset, width: size.width - side - inset, height: size.height - 2 * inset),
                edge: edge ? .leading : nil, corner: corner, unit: u))
        } else {
            var run: [WelcomeTab] = pins
            if !pins.isEmpty { run.append(.gap(6)) }
            run += folders
            if !folders.isEmpty, live != nil { run.append(.gap(4)) }
            if let live { run.append(live) }
            run += sampled
            var row = StagePart("y-row", CGRect(x: 0, y: 0, width: size.width, height: Metrics.row * u))
            row.children = windowRow(lights: lights, run: run, width: size.width, ink: ink, unit: u)
            children.append(row)
            let top = Metrics.row * u, inset = Backdrop.inset * u
            // Edge to edge, a hairline under the row and the page to the
            // edges; on a backdrop, 8 in at corner 10.
            children.append(windowPage(shown, edge
                ? CGRect(x: 0, y: top, width: size.width, height: size.height - top)
                : CGRect(x: inset, y: top, width: size.width - 2 * inset, height: size.height - top - inset),
                edge: edge ? .top : nil, corner: corner, unit: u))
        }
        if let compact, let page = children.last(where: { $0.key == "y-page" }) {
            children.append(fieldOver(page.frame, compact: compact, paint: paint, window: size.width))
        }
        part.children = children
        return part
    }

    /// The window-to-be's sample tabs: the tracker's page open, two more.
    static let sampleTabs: [(title: String, site: WelcomeSite)] = [
        ("Peek keeps its scroll", .tracker), ("Peek spec", .docs), ("#482 Sidebar width", .code),
    ]

    /// ⌘T's field over the window-to-be's page, laid as Omnibox lays it in
    /// a window 1200 wide and drawn at this window's share of that: the
    /// full box or the compact card, as wide as the page leaves it, its
    /// top where the Omnibox puts it, with room round it for its shadow.
    private static func fieldOver(_ page: CGRect, compact: Bool, paint: NSColor, window: CGFloat) -> StagePart {
        let s = min(1, window / 1200)
        let room = CGSize(width: page.width / s, height: page.height / s)
        let width = compact ? min(Omnibox.compactWidth, Omnibox.width(in: room.width)) : Omnibox.width(in: room.width)
        let height = compact ? WindowFieldDrawing.compactHeight : Omnibox.fieldHeight + Omnibox.bodyHeight
        let pad = WindowFieldDrawing.pad
        let top = Omnibox.top(in: room.height)
        let frame = CGRect(x: page.minX + (page.width - width * s) / 2 - pad * s, y: page.minY + (top - pad) * s,
                           width: (width + 2 * pad) * s, height: (height + 2 * pad) * s)
        return StagePart("y-box", frame, drawing: drawn(WindowFieldDrawing(compact: compact, paint: paint), frame.size, s),
                         enter: .fade, delay: 0.08, exit: .fastFade, resize: .pin, version: "box \(compact) \(paint.hex) \(frame.size)")
    }

    /// The window-to-be's row as TabBar lays it: the lights, your things in
    /// a run of their own, the plus after them. Past what fits, the live
    /// tab gives way to 96, then the run keeps its end in view and the
    /// first things go, the plus always there.
    private static func windowRow(lights: WelcomeTab, run: [WelcomeTab], width: CGFloat, ink: WelcomeInk, unit u: CGFloat) -> [StagePart] {
        let height = Metrics.row * u
        let start = (5 + self.width(of: lights) + 2) * u
        let end = width - (5 + self.width(of: .plus()) + 2) * u
        func span(_ items: [WelcomeTab]) -> CGFloat {
            items.isEmpty ? 0 : (items.map(self.width(of:)).reduce(0, +) + CGFloat(items.count - 1) * 2) * u
        }
        var items = run
        let room = end - start
        if span(items) > room, let last = items.indices.last, items[last].kind == .tab {
            items[last].width = max(96, items[last].width - (span(items) - room) / u)
        }
        while span(items) > room, items.count > 1 {
            items.removeFirst()
            while items.first?.kind == .gap { items.removeFirst() }
        }
        let x = span(run) > room ? end - span(items) : start
        var parts = lay([lights], in: "y-row", x: 5 * u, height: height, ink: ink, unit: u)
        parts += lay(items, in: "y-row.run", x: x, height: height, ink: ink, unit: u)
        parts += lay([.plus(key: "y-plus")], in: "y-row.end", x: x + span(items) + 2 * u, height: height, ink: ink, unit: u)
        return parts
    }

    /// The window-to-be's page, "y-page".
    private static func windowPage(_ page: WelcomePage, _ frame: CGRect, edge: Edge?, corner: CGFloat, unit u: CGFloat) -> StagePart {
        // No card under the field with nothing open: on a backdrop it stands
        // on the window's own ground, as it does in the window.
        let plate = edge == nil && page != .newTab
            ? StagePlate(fill: Palette.NS.ground, corner: Radius.surface * u, ring: NSColor(white: 0, alpha: 0.06), ringWidth: 0.5 * u)
            : nil
        var part = StagePart("y-page", frame, drawing: drawn(WindowPageDrawing(page: page, edge: edge, corner: corner / u), frame.size, u),
                             plate: plate, resize: .pin, version: "\(page) \(String(describing: edge)) \(corner) \(u) \(frame.size)")
        if page == .newTab {
            // The field a part of its own, a third of the way down and in
            // the middle of what is under the hairline, so it glides there
            // as the page changes size (Finish) rather than jumping ahead.
            let top: CGFloat = edge == .top ? u : 0, lead: CGFloat = edge == .leading ? u : 0
            let room = CGSize(width: frame.width - lead, height: frame.height - top)
            let width = min(420, room.width / u * 0.78) * u, height = 44 * u, pad = NewTabField.pad * u
            let field = CGRect(x: lead + (room.width - width) / 2 - pad, y: top + room.height * 0.34 - pad,
                               width: width + 2 * pad, height: height + 2 * pad)
            part.children = [StagePart("y-field", field, drawing: drawn(NewTabField(), field.size, u), version: "field \(field.size) \(u)")]
        }
        return part
    }

}

// MARK: - the row's drawings

/// A pin, a tab, a folder's pill, the plus, the lights: one thing of the row.
private struct RowThing: View {
    let item: WelcomeTab
    let ink: WelcomeInk

    var body: some View {
        switch item.kind {
        case .pin, .compact:
            WelcomeSiteMark(mark: item.mark)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background { ground }
        case .tab:
            HStack(spacing: 7) {
                if let mark = item.mark { WelcomeSiteMark(mark: mark) }
                Text(item.title).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
                if let face = item.face {
                    FaceGlyph(pose: face, side: 15, tint: ink.ink, alpha: face == .done ? 0.5 : item.on ? 0.75 : 0.45)
                }
            }
            .font(.system(size: 12.5))
            .foregroundStyle(Color(nsColor: item.on ? ink.ink : ink.muted))
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { ground }
        case .folder:
            HStack(spacing: 6) {
                WelcomeFolderGlyph(open: item.open, eyes: item.task, ink: ink)
                Text(item.title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Color(nsColor: ink.strong)).lineLimit(1).fixedSize()
                if item.unread { Circle().fill(Color.accentColor).frame(width: 7, height: 7) }
                if !item.open {
                    Text("\(item.count)").font(.system(size: 10.5)).monospacedDigit().foregroundStyle(Color(nsColor: ink.faint)).fixedSize()
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, 9)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        case .plus:
            Symbol("plus", size: 12 / Glyphs.scale).foregroundStyle(Color(nsColor: ink.muted)).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .lights:
            LightsDrawing().padding(.leading, 9).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        case .nest, .gap, .newTab, .hairline:
            Color.clear
        }
    }

    /// The live one on a chip with its half-point ring; a pin otherwise on
    /// the veil; the rest on nothing.
    @ViewBuilder private var ground: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        if item.on {
            shape.fill(Color(nsColor: ink.chip)).overlay(shape.strokeBorder(Color(nsColor: ink.ring), lineWidth: 0.5))
        } else if item.kind == .pin {
            shape.fill(Color(nsColor: ink.veil))
        }
    }
}

/// A row of the column: a tab, a folder, New tab.
private struct SampleColumnHead: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                // As the column lays its header out: the lights 20 in, the
                // sidebar door 27 past the green one, back, forward and
                // reload against the margin, at the header's own size.
                let doors = Door.Size(side: 30, glyph: 13, arrow: 14.5, mark: 16, reload: 18, stroke: 1.5, roundMark: true, gap: 4)
                let middle: CGFloat = 26
                LightsDrawing(side: 14, gap: 9).offset(x: Lights.first - 7, y: middle - 7)
                doors.symbol("sidebar.left")
                    .frame(width: doors.side, height: doors.side)
                    .offset(x: ColumnHead.green + ColumnHead.fromGreen - doors.side / 2, y: middle - doors.side / 2)
                HStack(spacing: doors.gap) {
                    doors.symbol("arrow.left").frame(width: doors.side, height: doors.side)
                    doors.symbol("arrow.right").frame(width: doors.side, height: doors.side).opacity(0.4)
                    doors.symbol("arrow.clockwise").frame(width: doors.side, height: doors.side)
                }
                .offset(x: geometry.size.width - SideBar.margin - doors.helm, y: middle - doors.side / 2)
                Text("github.com").font(.system(size: 12.5)).foregroundStyle(Palette.ink)
                    .padding(.horizontal, 10)
                    .frame(width: geometry.size.width - 16, height: 36, alignment: .leading)
                    .background(Palette.pin(on: nil, dark: scheme == .dark, hovering: false),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .offset(x: 8, y: 49)
            }
            .foregroundStyle(Palette.muted)
        }
    }
}

private struct SamplePin: View {
    let mark: WelcomeMark?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        WelcomeSiteMark(mark: mark)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.pin(on: nil, dark: scheme == .dark, hovering: false),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct SampleColumnRow: View {
    let item: WelcomeTab

    var body: some View {
        HStack(spacing: 10) {
            if item.kind == .folder {
                WelcomeFolderGlyph(open: item.open, eyes: item.task, side: 18)
            } else if item.kind == .newTab {
                // As the column's New tab row draws its plus.
                Symbol("plus", size: 11, weight: .medium, side: 15.5).frame(width: 18)
            } else if let mark = item.mark {
                WelcomeSiteMark(mark: mark)
            }
            GeometryReader { geometry in
                Text(item.title).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
                    .clipped()
            }
                .mask {
                    GeometryReader { geometry in
                        HStack(spacing: 0) {
                            Rectangle()
                            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                                .frame(width: min(40, geometry.size.width))
                        }
                    }
                }
            if item.unread {
                Circle().fill(Color.accentColor).frame(width: 7, height: 7)
            } else if let face = item.face {
                FaceGlyph(pose: face, side: 14, tint: Palette.NS.ink, alpha: item.on ? 0.75 : 0.45)
            }
        }
        .font(.system(size: 14))
        .foregroundStyle(item.on ? Palette.ink : Palette.muted)
        .padding(.leading, item.indent ? 25 : 10)
        .padding(.trailing, 11)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if item.on { RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.wash) }
        }
    }
}

private struct SampleColumnFoot: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 2) {
            ZStack {
                Circle().strokeBorder(lineWidth: HoardMark.line)
                HoardMark(pose: .arrow).stroke(style: StrokeStyle(lineWidth: HoardMark.line, lineCap: .round, lineJoin: .round))
            }
            .frame(width: HoardMark.side, height: HoardMark.side)
            .frame(width: 26, height: 26)
            Spacer(minLength: 0)
            // The space on screen in its colors, the others gray as the
            // foot draws them (GrayMark: saturation leaves a color emoji
            // half colored).
            ForEach(["🏠", "💼", "✈️"], id: \.self) { space in
                Group {
                    if space == "💼" {
                        Text(space).font(.system(size: 12))
                    } else {
                        Image(nsImage: GrayMark.image(space, size: 12, dark: scheme == .dark)).opacity(0.5)
                    }
                }
                .frame(width: 34, height: 26)
            }
            Spacer(minLength: 0)
            Symbol("plus", size: 11, weight: .medium).frame(width: Door.side, height: Door.side)
        }
        .foregroundStyle(Palette.muted)
    }
}

private struct ColumnRow: View {
    let item: WelcomeTab
    let ink: WelcomeInk

    var body: some View {
        HStack(spacing: 8) {
            switch item.kind {
            case .folder:
                WelcomeFolderGlyph(open: item.open, eyes: item.task, ink: ink)
                Text(item.title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Color(nsColor: ink.strong)).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !item.open {
                    Text("\(item.count)").font(.system(size: 10.5)).monospacedDigit().foregroundStyle(Color(nsColor: ink.faint))
                }
            case .newTab:
                Symbol("plus", size: 12 / Glyphs.scale).foregroundStyle(Color(nsColor: ink.muted)).padding(.horizontal, 2)
                Text(item.title).font(.system(size: 12.5)).foregroundStyle(Color(nsColor: item.on ? ink.ink : ink.muted)).frame(maxWidth: .infinity, alignment: .leading)
            default:
                if let mark = item.mark { WelcomeSiteMark(mark: mark) }
                Text(item.title).font(.system(size: 12.5)).foregroundStyle(Color(nsColor: item.on ? ink.ink : ink.muted)).lineLimit(1)
                    .truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
                if let face = item.face {
                    FaceGlyph(pose: face, side: 15, tint: ink.ink, alpha: face == .done ? 0.5 : item.on ? 0.75 : 0.45)
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if item.on {
                let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                shape.fill(Color(nsColor: ink.chip)).overlay(shape.strokeBorder(Color(nsColor: ink.ring), lineWidth: 0.5))
            }
        }
    }
}

/// Spaces that came, a dot each at the column's foot: the one on screen
/// in the strong ink.
private struct SpaceDots: View {
    let count: Int
    let current: Int
    let ink: WelcomeInk

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { index in
                Circle().fill(Color(nsColor: index == current ? ink.strong : ink.faint)).frame(width: 7, height: 7)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A site's mark, 16: the site's own favicon where the sample names a real
/// one (Resources/Sites, Google's from Resources/Google), the sample's tile
/// otherwise, or a real page's picture.
struct WelcomeSiteMark: View {
    let mark: WelcomeMark?
    var side: CGFloat = 16
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        switch mark {
        case .site(let site):
            if let favicon = Self.favicon(site, dark: scheme == .dark) {
                Image(nsImage: favicon).resizable().interpolation(.high).frame(width: side, height: side)
            } else {
                FeatureTile(icon: site.icon, tint: site.tint, side: side)
            }
        case .picture(let image): Image(nsImage: image).resizable().interpolation(.high).frame(width: side, height: side)
        case nil: Color.clear.frame(width: side, height: side)
        }
    }

    private static let sites: [String: NSImage] = {
        var out: [String: NSImage] = [:]
        for name in ["github.com", "github.com-dark", "linear.app", "docs.google.com"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Sites"),
               let image = NSImage(contentsOf: url) { out[name] = image }
        }
        return out
    }()

    /// Gmail, Google Calendar, GitHub, Linear and Google Docs: the sites the
    /// sample's mail, calendar, code, tracker and docs stand for.
    static func favicon(_ site: WelcomeSite, dark: Bool) -> NSImage? {
        switch site {
        case .mail: return GoogleMarks.gmail
        case .calendar: return GoogleMarks.calendar
        case .code: return sites[dark ? "github.com-dark" : "github.com"]
        case .tracker: return sites["linear.app"]
        case .docs: return sites["docs.google.com"]
        default: return nil
        }
    }
}

/// The window's three lights at their size, each with its faint rim.
private struct LightsDrawing: View {
    /// A light's size and the gap between two: the window's own, 14 and 9,
    /// their centers 23 apart, in the column's header.
    var side: CGFloat = 12
    var gap: CGFloat = 8

    var body: some View {
        HStack(spacing: gap) {
            ForEach([0xFF5F57, 0xFEBC2E, 0x28C840] as [UInt32], id: \.self) { value in
                Circle().fill(Color(nsColor: WelcomeHue.hex(value)))
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.16), lineWidth: 0.5))
                    .frame(width: side, height: side)
            }
        }
    }
}

// MARK: - the face and the folder

/// The agent's face at a tab's end, on a step, on the dock: a circle and
/// two eyes, reading down and to the right, or at rest; done, the eyes
/// swing into a tick, the face's own done pose. A layer, still until its
/// pose changes. Welcome uses the app's Face, including its reading and
/// waiting scripts and its Reduce Motion behavior.
private struct FaceGlyph: View {
    let pose: FacePose
    let side: CGFloat
    let tint: NSColor
    var alpha: CGFloat = 1

    var body: some View {
        Face(pose: pose, size: side, tint: Color(nsColor: tint))
            .opacity(alpha)
            .frame(width: side, height: side)
    }
}

/// FolderGrid's folder at 15, shut or open, its back and front in the
/// ink's shades; an agent's folder wears its eyes on its front. It opens as
/// the app's folders do (a turn, then the front let down), on the render
/// server, when a board opens it; at rest it is still.
struct WelcomeFolderGlyph: NSViewRepresentable {
    var open: Bool
    var eyes = false
    var side: CGFloat = 15
    var ink: WelcomeInk = .stage

    func makeNSView(context: Context) -> WelcomeFolderView { WelcomeFolderView() }

    func updateNSView(_ view: WelcomeFolderView, context: Context) {
        view.show(open: open, eyes: eyes, side: side, line: ink.strong, back: ink.back, body: ink.body,
                  still: context.environment.accessibilityReduceMotion)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WelcomeFolderView, context: Context) -> CGSize? {
        CGSize(width: side, height: side)
    }
}

final class WelcomeFolderView: NSView {
    private let canvas = CALayer()
    private let backFill = CAShapeLayer()
    private let frontFill = CAShapeLayer()
    private let outline = CAShapeLayer()
    private let seam = CAShapeLayer()
    private let front = CALayer()
    private let eyes = CAShapeLayer()
    private var side: CGFloat = 0
    private var open = false
    private var eyesOn = false
    private var line = NSColor.black
    private var back = NSColor.gray
    private var body = NSColor.white
    /// The last move: where it started, when, how long, which way.
    private var fold = (from: FolderPose.shut, start: CFTimeInterval(0), duration: CFTimeInterval(0), opening: false)

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = CALayer()
        wantsLayer = true
        canvas.isGeometryFlipped = true
        layer?.addSublayer(canvas)
        for shape in [backFill, frontFill, outline, seam, eyes] {
            shape.fillColor = nil
            shape.lineJoin = .round
            shape.lineCap = .round
        }
        for layer in [backFill, frontFill, outline, seam, front] { canvas.addSublayer(layer) }
        front.addSublayer(eyes)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        rescale()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    func show(open: Bool, eyes on: Bool, side: CGFloat, line: NSColor, back: NSColor, body: NSColor, still: Bool) {
        self.line = line
        self.back = back
        self.body = body
        if side != self.side {
            // First drawn (or at another size): as it is, with no motion.
            self.side = side
            self.open = open
            eyesOn = on
            fold = (open ? .open : .shut, 0, 0, open)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            lay()
            set(open ? .open : .shut)
            eyes.opacity = on ? 1 : 0
            CATransaction.commit()
            paint()
            return
        }
        paint()
        if open != self.open {
            self.open = open
            unfold(open, still: still)
        }
        if on != eyesOn {
            eyesOn = on
            let from = eyes.presentation()?.opacity ?? eyes.opacity
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            eyes.opacity = on ? 1 : 0
            CATransaction.commit()
            if !still {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = from
                fade.toValue = on ? 1 : 0
                fade.duration = 0.2
                eyes.add(fade, forKey: "fade")
            }
        }
    }

    private var k: CGFloat { side / 24 }
    private var box: CGRect { CGRect(x: 0, y: 0, width: side, height: side) }

    private func lay() {
        canvas.frame = box
        for layer in [backFill, frontFill, outline, seam, eyes] { layer.frame = box }
        front.bounds = box
        front.anchorPoint = CGPoint(x: 0.5, y: FolderGrid.foot / 24)
        front.position = CGPoint(x: side * 0.5, y: side * FolderGrid.foot / 24)
        outline.lineWidth = 2 * k
        eyes.lineWidth = 2 * k
        eyes.path = Eyes(gaze: .zero, open: 1, tick: 0).path(in: box).cgPath
        rescale()
    }

    private func rescale() {
        let scale = window?.backingScaleFactor ?? 2
        for shape in [backFill, frontFill, outline, seam, eyes] { shape.contentsScale = scale }
    }

    /// The folder as it is at `pose`, with no motion.
    private func set(_ pose: FolderPose) {
        outline.path = FolderOpen(pose: pose).path(in: box).cgPath
        let (back, front) = FolderOpen.fills(pose: pose, in: box)
        backFill.path = back.cgPath
        frontFill.path = front.cgPath
        seam.path = FolderOpen.seam(pose: pose, in: box).cgPath
        seam.lineWidth = seamWidth(pose)
        self.front.transform = frontTransform(pose)
    }

    private func seamWidth(_ pose: FolderPose) -> CGFloat {
        (FolderGrid.seam + (2 - FolderGrid.seam) * pose.flap) * k
    }

    private func paint() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            outline.strokeColor = line.cgColor
            seam.strokeColor = line.cgColor
            eyes.strokeColor = line.cgColor
            backFill.fillColor = back.cgColor
            frontFill.fillColor = body.cgColor
        }
        CATransaction.commit()
    }

    /// The eyes carried on the front as it turns and lets down, as FaceView
    /// carries a task folder's: the front's own shape where they sit.
    private func frontTransform(_ pose: FolderPose) -> CATransform3D {
        let lift = FolderGrid.eyes - 11
        func seen(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            FolderGrid.project(CGPoint(x: x, y: y + lift), front: true, pose: pose)
        }
        let step: CGFloat = 0.5
        let middle = seen(12, 11), across = seen(12 + step, 11), down = seen(12, 11 + step)
        let a = (across.x - middle.x) / step, b = (across.y - middle.y) / step
        let c = (down.x - middle.x) / step, d = (down.y - middle.y) / step
        let anchor = CGPoint(x: 12, y: FolderGrid.foot)
        let moved = CGPoint(x: middle.x + a * (anchor.x - 12) + c * (anchor.y - 11),
                            y: middle.y + b * (anchor.x - 12) + d * (anchor.y - 11))
        return CATransform3DMakeAffineTransform(CGAffineTransform(a: a, b: b, c: c, d: d, tx: (moved.x - anchor.x) * k, ty: (moved.y - anchor.y) * k))
    }

    /// Open or shut from wherever the last move got to, sampled a frame at
    /// a time as FaceView does it: the turn, then the front let down.
    private func unfold(_ open: Bool, still: Bool) {
        let now = CACurrentMediaTime()
        let from = fold.duration > 0
            ? FaceView.fold(from: fold.from, opening: fold.opening, progress: min(1, (now - fold.start) / fold.duration))
            : (fold.opening ? FolderPose.open : .shut)
        let duration: CFTimeInterval = still ? 0 : open ? 0.3 : 0.24
        fold = (from, now, duration, open)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        set(open ? .open : .shut)
        CATransaction.commit()
        guard duration > 0 else { return }
        let steps = max(2, Int((duration * 120).rounded(.up)))
        let poses = (0...steps).map { FaceView.fold(from: from, opening: open, progress: Double($0) / Double(steps)) }
        let times = (0...steps).map { NSNumber(value: Double($0) / Double(steps)) }
        func frames(_ keyPath: String, _ values: [Any], discrete: Bool = true) -> CAKeyframeAnimation {
            let animation = CAKeyframeAnimation(keyPath: keyPath)
            animation.values = values
            animation.keyTimes = times
            animation.duration = duration
            if discrete { animation.calculationMode = .discrete }
            return animation
        }
        let fills = poses.map { FolderOpen.fills(pose: $0, in: box) }
        outline.add(frames("path", poses.map { FolderOpen(pose: $0).path(in: box).cgPath }), forKey: "fold")
        backFill.add(frames("path", fills.map { $0.back.cgPath }), forKey: "fold")
        frontFill.add(frames("path", fills.map { $0.front.cgPath }), forKey: "fold")
        seam.add(frames("path", poses.map { FolderOpen.seam(pose: $0, in: box).cgPath }), forKey: "fold")
        seam.add(frames("lineWidth", poses.map { seamWidth($0) }), forKey: "fold width")
        front.add(frames("transform", poses.map { NSValue(caTransform3D: frontTransform($0)) }, discrete: false), forKey: "fold")
    }
}

// MARK: - pages

/// Text on a line of a fixed height, as the pages' CSS sets it: the room
/// over the letters' own line split above and below each line.
private struct CSSLine: View {
    let text: Text
    let size: CGFloat
    let line: CGFloat
    var weight: NSFont.Weight = .regular

    var body: some View {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        let extra = max(0, line - (font.ascender - font.descender + font.leading))
        text.lineSpacing(extra).padding(.vertical, extra / 2)
    }
}

/// A sample site's page, drawn as the site draws it: 28 down and 36 in
/// (the narrow pull request 24 and 20); a New Tab's field a third down.
private struct PageDrawing: View {
    let page: WelcomePage

    var body: some View {
        if page == .newTab {
            // Its field is a part of its own ("y-field").
            Color.clear
        } else {
            let narrow = page == .pullRequest(narrow: true)
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.vertical, narrow ? 24 : 28)
                .padding(.horizontal, narrow ? 20 : 36)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .foregroundStyle(Palette.ink)
        }
    }

    @ViewBuilder private var content: some View {
        switch page {
        case .tracker:
            crumb(.tracker, ["Design", "Y-214"])
            heading(Text("Peek keeps its scroll"))
            chips(["In Progress", "High", "Design"])
            paragraph(WelcomeCopy.trackerBody)
            // The link is a part of its own on this line ("link"); Activity
            // 20 under it.
            Color.clear.frame(height: 22).padding(.bottom, 20)
            Text("Activity").font(.system(size: 13, weight: .semibold)).padding(.bottom, 6)
            activity("Moved to In Progress \u{00B7} 2h ago")
            activity("Linked #482 Sidebar width \u{00B7} yesterday")
        case .spec:
            crumb(.docs, ["docs.google.com"])
            heading(Text("Peek spec"))
            paragraph("A link opens over the page you\u{2019}re on. Esc puts it away, and it can stay as a tab.")
            paragraph("Beside the page, it becomes Split View: two tabs, one window, each with its own history.")
        case .pullRequest:
            crumb(.code, ["yab", "Pull requests"])
            heading(Text("Sidebar width \(Text("#482").foregroundStyle(Palette.muted).fontWeight(.regular))"))
            chips(["Open", "4 files", "2 reviewers"])
            review
            HStack(spacing: 8) {
                Symbol("checkmark.circle", size: 13 / Glyphs.scale).foregroundStyle(Palette.muted)
                Text("Checks").font(.system(size: 13, weight: .medium))
                Text("3 of 3 passed").font(.system(size: 13)).foregroundStyle(Palette.muted)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 38, maxHeight: 38, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
            .padding(.top, 10)
        case .launchNotes:
            crumb(.docs, ["docs.google.com"])
            heading(Text("Launch notes"))
            activity("Shared in Slack today").padding(.top, -6).padding(.bottom, 14)
            paragraph("What ships this week, and who has each part.")
            VStack(alignment: .leading, spacing: 0) {
                ForEach(["Sidebar width, merged once the two changes are in", "Tab sleep, approved, goes out with the next build",
                         "Paste in the field, waiting on CI"], id: \.self) { line in
                    HStack(spacing: 0) {
                        Circle().fill(WelcomeParts.ink82).frame(width: 5, height: 5).frame(width: 18, alignment: .leading).padding(.leading, 1.5)
                        Text(line).font(.system(size: 14)).foregroundStyle(WelcomeParts.ink82).lineLimit(1)
                    }
                    .frame(height: 24)
                }
            }
        case .newTab:
            EmptyView()
        }
    }

    /// Where the page is: the site's mark, and its place, 12 muted.
    private func crumb(_ mark: WelcomeSite, _ words: [String]) -> some View {
        HStack(spacing: 7) {
            WelcomeSiteMark(mark: .site(mark))
            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                if index > 0 { Text("\u{00B7}").foregroundStyle(Palette.faint) }
                Text(word)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(Palette.muted)
        .lineLimit(1)
        .frame(height: 16)
        .padding(.bottom, 16)
    }

    /// 22 medium on 28, as a display face sets it.
    private func heading(_ words: Text) -> some View {
        CSSLine(text: words.font(.system(size: 22, weight: .medium)).tracking(-0.22), size: 22, line: 28, weight: .medium)
            .padding(.bottom, 12)
    }

    /// 11.5 on 14, 4 and 7 in, on the wash at corner 5.
    private func chips(_ words: [String]) -> some View {
        HStack(spacing: 6) {
            ForEach(words, id: \.self) { word in
                Text(word).font(.system(size: 11.5)).foregroundStyle(WelcomeParts.ink82)
                    .frame(height: 14)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Palette.wash, in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
            }
        }
        .padding(.bottom, 18)
    }

    /// 14 on 22 at ink 0.82, never wider than 640.
    private func paragraph(_ words: String) -> some View {
        CSSLine(text: Text(words).font(.system(size: 14)), size: 14, line: 22)
            .foregroundStyle(WelcomeParts.ink82)
            .frame(maxWidth: 640, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 12)
    }

    private func activity(_ words: String) -> some View {
        Text(words).font(.system(size: 13)).foregroundStyle(Palette.muted).lineLimit(1).frame(height: 24)
    }

    /// The review asking for changes: its head, then a comment each, on
    /// hairlines at corner 8.
    private var review: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Symbol("exclamationmark.triangle", size: 13 / Glyphs.scale).foregroundStyle(Palette.muted)
                Text("Changes requested").font(.system(size: 13, weight: .medium))
                Text("2 comments").font(.system(size: 13)).foregroundStyle(Palette.muted)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 37, maxHeight: 37, alignment: .leading)
            Rectangle().fill(Palette.hairline).frame(height: 1)
            comment("Sidebar.swift, line 476", "Keep the narrowest width at 189 points, as the column has it now.")
            Rectangle().fill(Palette.hairline).frame(height: 1)
            comment("Sidebar.swift, line 483", "Past 64 points of pull, let the sidebar shut instead of springing back.")
        }
        .padding(1)
        .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
    }

    private func comment(_ place: String, _ words: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            CSSLine(text: Text(place).font(.system(size: 12)), size: 12, line: 19).foregroundStyle(Palette.muted)
            CSSLine(text: Text(words).font(.system(size: 13)), size: 13, line: 19).foregroundStyle(WelcomeParts.ink82)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A New Tab's floating field: 44 tall, corner 14, the glass 15 and its
/// words 15 muted, with room round it for its shadow.
private struct NewTabField: View {
    static let pad: CGFloat = 12

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.floating, style: .continuous)
        HStack(spacing: 10) {
            Symbol("magnifyingglass", size: 15 / Glyphs.scale).foregroundStyle(Palette.muted)
            Text("Enter a web address").font(.system(size: 15)).foregroundStyle(Palette.muted).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(shape.fill(Palette.ground))
        .overlay(shape.strokeBorder(Palette.hairline, lineWidth: 1))
        .castShadow(shape, color: .black.opacity(0.06), radius: 7, y: 4)
        .padding(Self.pad)
    }
}

/// The window-to-be's page: on a backdrop, the page alone (its plate is
/// its ground); edge to edge, the ground to the window's corners with a
/// hairline under the row, or beside the column.
private struct WindowPageDrawing: View {
    let page: WelcomePage
    let edge: Edge?
    let corner: CGFloat

    var body: some View {
        switch edge {
        case .top?:
            VStack(spacing: 0) {
                Rectangle().fill(Palette.hairline).frame(height: 1)
                PageDrawing(page: page)
            }
            .background(UnevenRoundedRectangle(bottomLeadingRadius: corner, bottomTrailingRadius: corner, style: .continuous).fill(Palette.ground))
        case .some:
            HStack(spacing: 0) {
                Rectangle().fill(Palette.hairline).frame(width: 1)
                PageDrawing(page: page)
            }
            .background(UnevenRoundedRectangle(bottomTrailingRadius: corner, topTrailingRadius: corner, style: .continuous).fill(Palette.ground))
        case nil:
            PageDrawing(page: page)
        }
    }
}

/// "Read the Peek spec", underlined in the faint, as the tracker's page has it.
private struct PageLink: View {
    var body: some View {
        Text(WelcomeCopy.link).font(.system(size: 14)).foregroundStyle(WelcomeParts.ink82)
            .underline(true, color: Palette.faint)
            .fixedSize()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

// MARK: - the box

/// The field's words as typed so far, or the board's.
struct WelcomeTypedLine: View {
    let field: String
    let text: String
    private var typing = WelcomeTyping.shared

    var body: some View {
        Text(typing.typed[field] ?? text)
    }
}

/// The box's glass and its field, as the Omnibox draws them; the rows are
/// parts of their own.
private struct BoxDrawing: View {
    let field: String
    let query: String?
    let placeholder: String
    let keys: String?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.box, style: .continuous)
        let dim = scheme == .dark
        let ground = dim ? Omnibox.nearer : Palette.ground
        VStack(spacing: 0) {
            HStack(spacing: Omnibox.gap) {
                Symbol("magnifyingglass", size: Omnibox.glass).foregroundStyle(Palette.muted).frame(width: Omnibox.slot)
                HStack(spacing: 1) {
                    if let query {
                        WelcomeTypedLine(field: field, text: query).foregroundStyle(Palette.ink)
                        Capsule().fill(Palette.ink).frame(width: 2, height: 24)
                    } else {
                        Text(placeholder).foregroundStyle(Palette.muted)
                    }
                }
                .font(.system(size: 20))
                .lineLimit(1)
                Spacer(minLength: 0)
                if let keys { KeyGlyphs(keys: keys.replacingOccurrences(of: " ", with: ""), size: 13) }
            }
            .padding(.horizontal, Omnibox.gutter)
            .frame(height: Omnibox.fieldHeight)
            Spacer(minLength: 0)
        }
        .background {
            if #available(macOS 26.0, *), PullView.glassy {
                // Liquid Glass over a material, tinted with the ground, as
                // the box has it: the glass gives its rim and its shadow.
                shape.fill(.regularMaterial)
                Color.clear.glassEffect(.regular.tint(ground.opacity(Omnibox.glassTint)), in: shape)
            } else {
                // Without glass: the ground and two short shadows close under it.
                let tint = dim ? Color.black.opacity(0.3) : Color.black.opacity(0.05)
                shape.fill(ground)
                    .castShadow(shape, color: tint, radius: 1.5, y: 2)
                    .castShadow(shape, color: tint, radius: 0.5, y: 1)
            }
        }
        .overlay(shape.strokeBorder(dim ? Color.white.opacity(0.1) : Color.black.opacity(0.08), lineWidth: 0.5))
    }
}

private extension WelcomeBoxRow {
    /// What the row looks like, as one string.
    var version: String {
        let mark: String
        switch self.mark {
        case .site(let site): mark = "site \(site.rawValue)"
        case .well(let icon): mark = "well \(icon)"
        case .tile(let icon, let tint): mark = "tile \(icon) \(tint)"
        case .agent(let cli): mark = "agent \(cli)"
        }
        return "\(key) \(mark) \(title) \(detail ?? "") \(end) \(chosen)"
    }
}

/// A row of the box as the Omnibox's: its mark in the 22 slot under the
/// field's glass, its words 13.5, what it is muted, and its end, the
/// chosen one on the ink's veil.
private struct BoxRowDrawing: View {
    let row: WelcomeBoxRow

    var body: some View {
        HStack(spacing: Omnibox.gap) {
            Self.mark(row.mark)
                .frame(width: Omnibox.slot, height: Omnibox.slot)
            Text(row.title)
                .font(.system(size: 13.5))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
            if let detail = row.detail {
                Text(detail).font(.system(size: 13.5)).foregroundStyle(Palette.muted).lineLimit(1)
            }
            Spacer(minLength: 0)
            end
        }
        .padding(.horizontal, Omnibox.gutter - Omnibox.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(row.chosen ? Omnibox.chosenFill : Color.clear, in: RoundedRectangle(cornerRadius: Radius.surface, style: .continuous))
    }

    @ViewBuilder static func mark(_ mark: WelcomeBoxRow.Mark) -> some View {
        switch mark {
        case .site(let site): WelcomeSiteMark(mark: .site(site))
        case .well(let icon): FieldMark(symbol: icon)
        case .tile(let icon, let tint): FeatureTile(icon: icon, tint: tint, side: Omnibox.tile)
        case .agent(let cli): AgentMark(cli: cli, side: Omnibox.tile)
        }
    }

    @ViewBuilder private var end: some View {
        switch row.end {
        case .none: EmptyView()
        case .words(let words): Text(words).font(.system(size: 13.5)).foregroundStyle(Palette.muted).lineLimit(1)
        case .keys(let keys):
            KeyGlyphs(keys: keys.replacingOccurrences(of: " ", with: ""), size: 13.5)
        }
    }
}

/// The box's foot: FieldFoot's pill, its buttons' own look, said and
/// never pressed.
private struct BoxFootDrawing: View {
    let foot: WelcomeBoxFoot

    var body: some View {
        HStack(spacing: 0) {
            Button {} label: { FieldFoot.label(foot.primary, "\u{21A9}") }
                .buttonStyle(FootButton(strong: true))
            let keys = Keymap.shared.text(.fieldActions)
            if foot.actions, !keys.isEmpty {
                Button {} label: { FieldFoot.label("Actions", keys) }
                    .buttonStyle(FootButton(strong: false))
            }
        }
        .padding(2)
        .background { FieldGlass(shape: Capsule()) }
        .fixedSize()
        .allowsHitTesting(false)
        .frame(height: FieldFoot.pill)
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }
}

/// ⌘T's field over the window-to-be's page, as the Omnibox draws it at its
/// own sizes: the full box, 475 tall with its rows from the top and the
/// foot's pills at its bottom, or the compact card, the field 52 and five
/// rows of 40 inside 6, its chosen row the space's color deepened. Liquid
/// Glass over a material where the Mac draws it, tinted with the ground,
/// the card's soft shadow round it; `pad` of room round it for that.
struct WindowFieldDrawing: View {
    let compact: Bool
    /// The window's color, which the compact card's chosen row is made of.
    let paint: NSColor
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var solid

    static let pad: CGFloat = 48
    static let compactHeight = Omnibox.compactFieldHeight + CGFloat(Omnibox.compactRows) * Omnibox.compactRowHeight + 2 * Omnibox.compactInset

    /// What is typed, and what the field offers for it.
    private static let typed = "peek"
    private static let rows: [WelcomeBoxRow] = [
        WelcomeBoxRow(key: "r0", mark: .site(.docs), title: "Peek spec", end: .words("Switch to Tab"), chosen: true),
        WelcomeBoxRow(key: "r1", mark: .site(.tracker), title: "Peek keeps its scroll", end: .words("Switch to Tab")),
        WelcomeBoxRow(key: "r2", mark: .well("magnifyingglass"), title: "peek", end: .words("Search Google")),
        WelcomeBoxRow(key: "r3", mark: .well("magnifyingglass"), title: "peek spec template"),
        WelcomeBoxRow(key: "r4", mark: .site(.code), title: "#482 Sidebar width", detail: "github.com"),
        WelcomeBoxRow(key: "r5", mark: .site(.mail), title: "Peek review notes", detail: "Mail"),
        WelcomeBoxRow(key: "r6", mark: .well("magnifyingglass"), title: "peek in safari"),
    ]

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: compact ? Omnibox.compactCorner : Radius.box, style: .continuous)
        let dim = scheme == .dark
        let ground = dim ? Omnibox.nearer : Palette.ground
        Group {
            if compact { card } else { box }
        }
        .frame(width: nil, height: compact ? Self.compactHeight : Omnibox.fieldHeight + Omnibox.bodyHeight)
        .clipShape(shape)
        .background {
            FieldShadow(shape: shape, dark: dim)
            if #available(macOS 26.0, *), !solid {
                if compact {
                    shape.fill(.ultraThinMaterial)
                    Color.clear.glassEffect(.regular.tint(ground.opacity(dim ? Omnibox.compactGlassTintDark : Omnibox.compactGlassTint)), in: shape)
                } else {
                    shape.fill(.regularMaterial)
                    Color.clear.glassEffect(.regular.tint(ground.opacity(Omnibox.glassTint)), in: shape)
                }
            } else {
                shape.fill(ground)
                    .castShadow(shape, color: dim ? .black.opacity(0.3) : .black.opacity(0.05), radius: 1.5, y: 2)
            }
        }
        .overlay(shape.strokeBorder(dim ? Color.white.opacity(0.12) : Color.black.opacity(0.13), lineWidth: 0.5))
        .padding(Self.pad)
    }

    /// The field's line: the glass, the words typed and the caret.
    private func line(height: CGFloat) -> some View {
        HStack(spacing: Omnibox.gap) {
            Symbol("magnifyingglass", size: Omnibox.glass).foregroundStyle(Palette.muted).frame(width: Omnibox.slot)
            HStack(spacing: 1) {
                Text(Self.typed).foregroundStyle(Palette.ink)
                Capsule().fill(Color.accentColor).frame(width: 2, height: 22)
            }
            .font(.system(size: 20))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Omnibox.gutter)
        .frame(height: height)
    }

    private var box: some View {
        VStack(spacing: 0) {
            line(height: Omnibox.fieldHeight)
            VStack(spacing: 0) {
                ForEach(Self.rows, id: \.key) { row in
                    BoxRowDrawing(row: row).frame(height: Omnibox.rowHeight)
                }
            }
            .padding(.horizontal, Omnibox.inset)
            .padding(.top, Omnibox.inset)
            Spacer(minLength: 0)
            foot
        }
    }

    /// The box's foot: the About menu and Invite a Friend at the left, what
    /// Return does and Actions at the right, each on its glass (FieldFoot).
    private var foot: some View {
        HStack(spacing: 8) {
            Button {} label: { Symbol("menu.bars", size: 12) }
                .buttonStyle(FootButton(strong: false, round: true))
                .padding(2)
                .background { FieldGlass(shape: Circle()) }
                .fixedSize()
            Button {} label: {
                HStack(spacing: 6) {
                    Symbol("brand.blobplus", size: 13)
                    Text("Invite a Friend")
                }
            }
            .buttonStyle(FootButton(strong: true))
            .padding(2)
            .background { FieldGlass(shape: Capsule()) }
            .fixedSize()
            Spacer(minLength: 0)
            BoxFootDrawing(foot: WelcomeBoxFoot(primary: "Switch to Tab")).fixedSize()
                .padding(.horizontal, -8)
                .padding(.bottom, -8)
        }
        .allowsHitTesting(false)
        .frame(height: FieldFoot.pill)
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }

    private var card: some View {
        VStack(spacing: 0) {
            line(height: Omnibox.compactFieldHeight)
            VStack(spacing: 0) {
                ForEach(Array(Self.rows.prefix(Omnibox.compactRows)), id: \.key) { row in
                    CompactRow(row: row, tone: tone).frame(height: Omnibox.compactRowHeight)
                }
            }
            .padding(.horizontal, Omnibox.compactInset)
            .padding(.bottom, Omnibox.compactInset)
        }
    }

    /// The window's color made deep enough for white words, gray for a
    /// gray one, as Omnibox.spaceTone makes the space's.
    private var tone: Color {
        let color = paint.usingColorSpace(.deviceRGB) ?? .gray
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        let gray = saturation < 0.06
        let chroma = gray ? 0 : max(saturation, 0.55)
        var depth: CGFloat = gray ? 0.40 : (scheme == .dark ? 0.58 : 0.62)
        while depth > 0.2, Omnibox.quietContrast(NSColor(hue: hue, saturation: chroma, brightness: depth, alpha: 1)) < 4.5 { depth -= 0.02 }
        return Color(nsColor: NSColor(hue: hue, saturation: chroma, brightness: depth, alpha: 1))
    }

    /// A row of the compact card: no headings; the chosen one on the deep
    /// color with white words and what Return does at its end.
    private struct CompactRow: View {
        let row: WelcomeBoxRow
        let tone: Color
        @Environment(\.colorScheme) private var scheme

        var body: some View {
            HStack(spacing: Omnibox.gap) {
                BoxRowDrawing.mark(row.mark).frame(width: Omnibox.slot, height: Omnibox.slot)
                Text(row.title).font(.system(size: 13.5)).foregroundStyle(row.chosen ? Color.white : Palette.ink).lineLimit(1)
                if let detail = row.detail {
                    Text(detail).font(.system(size: 13.5)).foregroundStyle(row.chosen ? Color.white.opacity(0.8) : Palette.muted).lineLimit(1)
                }
                Spacer(minLength: 0)
                if row.chosen {
                    HStack(spacing: 8) {
                        Text("Switch to Tab").font(.system(size: 13.5)).foregroundStyle(Color.white.opacity(0.8))
                        KeyGlyphs(keys: "\u{21A9}", size: 13.5)
                    }
                } else if case .words(let words) = row.end {
                    Text(words).font(.system(size: 13.5)).foregroundStyle(Palette.muted).lineLimit(1)
                }
            }
            .padding(.horizontal, Omnibox.gutter - Omnibox.compactInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                if row.chosen {
                    RoundedRectangle(cornerRadius: Omnibox.compactCorner - Omnibox.compactInset, style: .continuous)
                        .fill(tone)
                        .cast(Shadow.fieldRow)
                }
            }
            .environment(\.colorScheme, row.chosen ? .dark : scheme)
        }
    }
}

// MARK: - Peek, the dock, the disc

/// One of Peek's buttons: the ground, round, LinkPeek's ring and shadow.
private struct PeekButtonDrawing: View {
    let icon: String

    var body: some View {
        Symbol(icon, size: 13 / Glyphs.scale)
            .foregroundStyle(Palette.ink)
            .frame(width: 28, height: 28)
            .background(Circle().fill(Palette.ground))
            .overlay(Circle().strokeBorder(Palette.ink.opacity(0.06), lineWidth: 1))
            .castShadow(Circle(), color: .black.opacity(0.16), radius: 8, y: 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The agent's HUD: its face reading, what it is doing (the words cross
/// over, 6 up and out and 6 up and in), Take Over with ⌘ . on the glass.
private struct DockDrawing: View {
    let words: String
    @Environment(\.accessibilityReduceMotion) private var still
    private var takeOverKey = Keymap.shared.slot(.agentTakeWheel)

    private static let ink = NSColor(white: 0.93, alpha: 1)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        HStack(spacing: 8) {
            FaceGlyph(pose: .read, side: 15, tint: Self.ink)
            ZStack(alignment: .leading) {
                Text(words)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color(nsColor: Self.ink))
                    .lineLimit(1)
                    .fixedSize()
                    .id(words)
                    .transition(still ? .opacity : .asymmetric(insertion: .opacity.combined(with: .offset(y: 6)),
                                                               removal: .opacity.combined(with: .offset(y: -6)).animation(.easeIn(duration: 0.1))))
            }
            .frame(minWidth: 150, alignment: .leading)
            Button {} label: {
                HStack(spacing: 6) {
                    Text("Take Over")
                    if let key = takeOverKey.keys {
                        KeyGlyphs(keys: key.text, size: 11.5, tint: nil, rest: 0.6)
                    }
                }
            }
            .buttonStyle(.yab(.glass, .small, surface: .dark))
            .allowsHitTesting(false)
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: 36)
        .background {
            shape.fill(Color(nsColor: WelcomeHue.hex(0x1C1C1E, 0.94)))
                .overlay(shape.strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
        }
        .castShadow(shape, color: .black.opacity(0.24), radius: 13, y: 10)
        .animation(still ? nil : Motion.reshape, value: words)
        .environment(\.colorScheme, .dark)
        .fixedSize()
        .padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// The agent's face, 20, on a white disc 28 round.
private struct DiscDrawing: View {
    var body: some View {
        ZStack {
            Circle().fill(Color.white)
                .overlay(Circle().strokeBorder(Color.black.opacity(0.06), lineWidth: 0.5))
                .castShadow(Circle(), color: .black.opacity(0.22), radius: 4, y: 2)
            FaceGlyph(pose: .read, side: 20, tint: WelcomeHue.hex(0x171717))
        }
        .frame(width: 28, height: 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - the chat

/// The real chat's shared glass, metrics and bubble shape, on the sample
/// run. Only its current status is in the head; tool steps aren't messages.
private struct ChatDrawing: View {
    let task: String
    let content: WelcomeChatBody
    @Environment(\.accessibilityReduceTransparency) private var solid

    private var live: Bool {
        if case .working = content { return true }
        return false
    }

    private var status: String {
        if case .working(let words) = content { return words }
        return "Claude"
    }

    var body: some View {
        VStack(spacing: 0) {
            head
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 0) {
                            Spacer(minLength: 48)
                            CSSLine(text: Text(task).font(.system(size: 13.5)), size: 13.5, line: 19)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(MessageBubble(mine: true).fill(Color.accentColor))
                                .padding(.bottom, MessageBubble.tailDrop)
                        }
                        if case .answer(let rows) = content {
                            WelcomeChatAnswer(rows: rows)
                        } else {
                            ChatTyping()
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.top, ChatHead.contentGap)
                    .padding(.horizontal, ChatLook.turnsInset)
                }
                .scrollIndicators(.hidden)
                .onChange(of: live, initial: true) { _, _ in
                    scroll.scrollTo("end", anchor: .bottom)
                }
            }
            composer
        }
        .foregroundStyle(Palette.ink)
        .allowsHitTesting(false)
    }

    private var head: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                HStack {
                    Button {} label: { Symbol("clock", size: 15) }
                        .buttonStyle(.yab(.glass, ChatHead.button, icon: .round))
                    Spacer(minLength: 0)
                    Button {} label: { Symbol("ellipsis", size: 15) }
                        .buttonStyle(.yab(.glass, ChatHead.button, icon: .round))
                }
                .padding(.horizontal, 12)
                .padding(.top, ChatHead.top + (ChatHead.face - ChatHead.button.height) / 2)
                VStack(spacing: 0) {
                    FaceGlyph(pose: live ? .read : .watch, side: 28, tint: Palette.NS.ink)
                        .frame(width: ChatHead.face, height: ChatHead.face)
                        .background { ChatHead.glass(Circle(), plain: solid) }
                        .frame(height: ChatHead.face - ChatHead.overlap, alignment: .top)
                        .zIndex(1)
                    VStack(spacing: 1) {
                        HStack(spacing: 4) {
                            Text("Pull requests").font(.system(size: ChatZoomStage.headType, weight: .semibold))
                            Symbol("chevron.right", size: 9, weight: .semibold).foregroundStyle(Palette.muted)
                        }
                        HStack(spacing: 3) {
                            if !live { AgentMark(cli: "claude", side: 12) }
                            Text(status).lineLimit(1).truncationMode(.tail)
                        }
                        .font(.system(size: 12)).foregroundStyle(Palette.muted)
                        .frame(maxWidth: .infinity)
                    }
                    .lineLimit(1)
                    .padding(.horizontal, 16)
                    .frame(width: WelcomeChatMetrics.nameWidth(in: geometry.size.width), height: ChatHead.name)
                    .background { ChatHead.glass(Capsule(), plain: solid) }
                }
                .padding(.top, ChatHead.top)
            }
        }
        .frame(height: ChatHead.height)
    }

    private var composer: some View {
        HStack(spacing: 6) {
            Button {} label: { Symbol("plus", size: 12) }
                .buttonStyle(.yab(.quiet, .small, icon: .round))
            Text(live ? "Tell it more while it works\u{2026}" : "Ask a follow-up\u{2026}")
                .font(.system(size: 13.5)).foregroundStyle(Palette.muted)
                .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            if live {
                Button {} label: { Symbol("stop.fill", size: 9) }
                    .buttonStyle(.yab(.primary, .small, tint: .accentColor, icon: .round))
            } else {
                Button {} label: {
                    // As the chat's own Done: its keys on KeyGlyphs.
                    HStack(spacing: 6) {
                        Text("Done")
                        if let key = Keymap.shared.slot(.chatDone).keys {
                            KeyGlyphs(keys: key.text, size: 11.5, tint: nil, rest: 0.6)
                        }
                    }
                }
                    .buttonStyle(.yab(.primary, .small, tint: .accentColor, capsule: true))
            }
        }
        .padding(8)
        .frame(minHeight: 40)
        .background { FieldGlass(shape: RoundedRectangle(cornerRadius: Radius.card, style: .continuous)) }
        .padding(.horizontal, ChatLook.fieldInset)
        .padding(.bottom, 10)
    }
}

/// The same title measurement as ChatName, independent of the live line.
@MainActor
enum WelcomeChatMetrics {
    static func nameWidth(in width: CGFloat, title: String = "Pull requests") -> CGFloat {
        let text = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13.5, weight: .semibold)]).width
        let most = min(260, width - 2 * (12 + ChatHead.button.height + 8))
        return min(most, max(160, ceil(text) + 9 + 4 + 32))
    }
}

private struct WelcomeChatAnswer: View {
    let rows: [WelcomeAnswer]
    @Environment(\.accessibilityReduceMotion) private var still
    @State private var grown = false
    @State private var dotsOut = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CSSLine(text: Text("Two need you. #482 has two changes asked, and #476 failed CI. #479 is approved and ready.")
                .font(.system(size: 13.5)), size: 13.5, line: 19)
                .opacity(grown || still ? 1 : 0)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background { ChatGrowth(grown: grown || still, dotsOut: dotsOut || still, tail: true) }
                .padding(.bottom, MessageBubble.tailDrop)
                .padding(.trailing, 40)
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, answer in
                    ResultRow(lit: index == 0, open: { _ in }) {
                        HStack(spacing: 10) {
                            WelcomeSiteMark(mark: .site(answer.mark))
                            Text(answer.title).font(.system(size: 13.5))
                                .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            Text(answer.state).font(.system(size: 11.5))
                                .foregroundStyle(answer.state == "CI failed" ? Color.red : Palette.muted)
                                .fixedSize()
                        }
                    }
                }
            }
            .restingCardFrame(inset: CardFrame.rows)
            .frame(maxWidth: ChatResultCard.most)
        }
        .task {
            guard !still else { return }
            withAnimation(Motion.reshape) { grown = true }
            withAnimation(.easeOut(duration: 0.1)) { dotsOut = true }
        }
    }
}

// MARK: - marks

/// An app's icon at a size, its square 0.805 of the picture.
private struct MarkDrawing: View {
    let icon: WelcomeIcon
    let side: CGFloat
    let dim: Bool
    let action: (() -> Void)?

    var body: some View {
        picture
            .frame(width: side, height: side)
            .opacity(dim ? 0.5 : 1)
            .contentShape(Rectangle())
            .onTapGesture { action?() }
    }

    @ViewBuilder private var picture: some View {
        switch icon {
        case .agent(let cli): AgentMark(cli: cli, side: side * 0.8)
        case .picture(let image):
            if let image { Image(nsImage: image).resizable().interpolation(.high) } else { Color.clear }
        case .letter(let name):
            let square = side * 0.8
            ZStack {
                WelcomeIconPlate(corner: square * 0.226).fill(Palette.wash)
                Text(String(name.prefix(1)))
                    .font(.system(size: side * 34 / 96, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.muted)
            }
            .frame(width: square, height: square)
        case .app(let id): WelcomeAppIcon(bundle: id)
        case .manager(let id):
            // The picture drawn so what is solid in it fills the square:
            // most fill it whole, 1Password's circle 0.86 of it.
            let square = side * 0.8
            let drawn = square / WelcomeVault.fill(id)
            if let image = PasswordManagers.icon(id) {
                Image(nsImage: image).resizable().interpolation(.high).frame(width: drawn, height: drawn)
            }
        }
    }
}

/// Shares the ring's exact continuous curve so the fallback has the same gap.
private struct WelcomeIconPlate: Shape {
    let corner: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(WelcomeRingLayer.outline(rect, corner: corner))
    }
}

/// Done: the system's green, a white tick, a ring of the stage's ground.
private struct TickDrawing: View {
    let side: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(Palette.stage)
            Circle().fill(Color(nsColor: .systemGreen)).frame(width: side, height: side)
            Symbol("checkmark", size: (side * 0.62).rounded() / Glyphs.scale).foregroundStyle(.white)
        }
        .frame(width: side + 4, height: side + 4)
    }
}

/// An app of this Mac's icon, looked up and drawn off the main thread in
/// the window's look, light or dark.
struct WelcomeAppIcon: View {
    let bundle: String
    @Environment(\.colorScheme) private var scheme
    @State private var icon: NSImage?

    var body: some View {
        let dark = scheme == .dark
        Group {
            if let shown = icon ?? WelcomeAppIcons.known["\(bundle) \(dark)"] ?? nil {
                Image(nsImage: shown).resizable().interpolation(.high)
            } else {
                Color.clear
            }
        }
        .task(id: "\(bundle) \(dark)") { icon = await WelcomeAppIcons.icon(bundle, dark: dark) }
    }
}

/// Apps' icons, looked up once for each look, off the main thread, and
/// drawn in that look, so Mail, Messages and Slack are the Mac's own.
@MainActor
enum WelcomeAppIcons {
    static var known: [String: NSImage?] = [:]

    static func icon(_ bundle: String, dark: Bool) async -> NSImage? {
        let key = "\(bundle) \(dark)"
        if let found = known[key] { return found }
        let made = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return nil }
            return WelcomeAppIcons.bake(NSWorkspace.shared.icon(forFile: url.path), dark: dark)
        }.value
        known[key] = .some(made)
        return made
    }

    /// The icon drawn once at 128 (256 pixels), in a light or a dark look.
    nonisolated static func bake(_ icon: NSImage, dark: Bool) -> NSImage {
        let pixels = 256
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return icon }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let look = NSAppearance(named: dark ? .darkAqua : .aqua)
        let draw = {
            icon.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .sourceOver, fraction: 1)
        }
        if let look { look.performAsCurrentDrawingAppearance(draw) } else { draw() }
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: 128, height: 128))
        image.addRepresentation(rep)
        return image
    }
}

/// The ring round a mark, 6 out from its icon on the icon's own curve
/// (macOS's continuous corner), 2 wide, in the accent. Still, it says
/// which mark is chosen. Waiting, it is an arc a quarter round, turning
/// once in 1.1 s on the render server over a faint track of the same
/// ring. Its two arcs (the second where it wraps past the start) have
/// round caps, the track square ones, so the tick's close runs the arcs
/// out alone. It turns only while it is on the stage, and not at all with
/// Reduce Motion.
final class WelcomeRingLayer: CALayer {
    private let track = CAShapeLayer()
    private let arc = CAShapeLayer()
    private let wrap = CAShapeLayer()
    private var corner: CGFloat = 0
    private var still = false
    /// A rounded square turned 45°, its tips on the layer's edges.
    private var diamond = false
    private var laid = CGRect.null

    @MainActor init(side: CGFloat, corner: CGFloat, still: Bool = false, diamond: Bool = false) {
        super.init()
        self.corner = corner
        self.still = still
        self.diamond = diamond
        frame = CGRect(x: 0, y: 0, width: side, height: side)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        for shape in [track, arc, wrap] {
            shape.fillColor = nil
            shape.lineWidth = 2
            shape.lineJoin = .round
            shape.contentsScale = scale
            addSublayer(shape)
        }
        track.lineCap = .butt
        arc.lineCap = .round
        wrap.lineCap = .round
        paint(NSApp.effectiveAppearance)
        setNeedsLayout()
    }

    override init(layer: Any) {
        super.init(layer: layer)
        if let other = layer as? WelcomeRingLayer {
            corner = other.corner
            still = other.still
            diamond = other.diamond
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    @MainActor func paint(_ appearance: NSAppearance) {
        var accent = CGColor(gray: 0, alpha: 1)
        appearance.performAsCurrentDrawingAppearance { accent = NSColor.controlAccentColor.cgColor }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.strokeColor = still ? nil : accent.copy(alpha: 0.18)
        arc.strokeColor = accent
        wrap.strokeColor = accent
        CATransaction.commit()
    }

    override func layoutSublayers() {
        super.layoutSublayers()
        guard bounds != laid, bounds.width > 4 else { return }
        laid = bounds
        // Round from the top left, rightward: clockwise on screen, as the
        // prototype's ring turns, whichever way this layer's points run.
        let path = diamond ? Self.diamond(bounds.insetBy(dx: 1, dy: 1), corner: corner) : Self.outline(bounds.insetBy(dx: 1, dy: 1), corner: corner)
        var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: bounds.height)
        let shape: CGPath = contentsAreFlipped() ? path : (path.copy(using: &flip) ?? path)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [track, arc, wrap] {
            layer.frame = bounds
            layer.path = shape
        }
        arc.strokeStart = 0
        arc.strokeEnd = still ? 1 : 0.24
        wrap.strokeStart = 0
        wrap.strokeEnd = 0
        CATransaction.commit()
        turn()
    }

    /// One turn in 1.1 s, for as long as it is shown: the arc runs from the
    /// start to the end, and where it passes the end the wrap carries it on
    /// from the start.
    private func turn() {
        guard !still, arc.animation(forKey: "turn") == nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let length = 1.1
        func frames(_ keyPath: String, _ values: [Double], _ times: [Double]) -> CAKeyframeAnimation {
            let animation = CAKeyframeAnimation(keyPath: keyPath)
            animation.values = values
            animation.keyTimes = times.map { NSNumber(value: $0) }
            animation.duration = length
            return animation
        }
        let run = CAAnimationGroup()
        run.animations = [frames("strokeStart", [0, 1], [0, 1]), frames("strokeEnd", [0.24, 1, 1], [0, 0.76, 1])]
        run.duration = length
        run.repeatCount = .infinity
        arc.add(run, forKey: "turn")
        let carry = CAAnimationGroup()
        carry.animations = [frames("strokeEnd", [0, 0, 0.24], [0, 0.76, 1]), frames("opacity", [0, 0, 1, 1], [0, 0.76, 0.7601, 1])]
        carry.duration = length
        carry.repeatCount = .infinity
        wrap.add(carry, forKey: "turn")
    }

    /// A square with macOS's continuous corners, as app icons are cut: each
    /// corner three curves from 1.53 radii along its sides, so a ring 6 out
    /// with the corner 6 more stays 6 from the icon all the way round
    /// (5.9 to 6.0; a circular corner came 1.2 nearer at the corners). From
    /// the top edge's left end, rightward.
    /// A square of rounded corners turned 45° about the middle of `rect`,
    /// its tips at the middles of `rect`'s sides.
    nonisolated static func diamond(_ rect: CGRect, corner: CGFloat) -> CGPath {
        let side = min(rect.width, rect.height) / 2.0.squareRoot()
        let square = outline(CGRect(x: -side / 2, y: -side / 2, width: side, height: side), corner: corner)
        var turn = CGAffineTransform(translationX: rect.midX, y: rect.midY).rotated(by: .pi / 4)
        return square.copy(using: &turn) ?? square
    }

    nonisolated static func outline(_ rect: CGRect, corner: CGFloat) -> CGPath {
        // A round icon's (1Password's): a circle. The continuous corner
        // stops short of one, at a third of the side.
        if corner >= min(rect.width, rect.height) / 2 - 2 { return CGPath(ellipseIn: rect, transform: nil) }
        let r = min(corner, rect.width / 2 / 1.52866483, rect.height / 2 / 1.52866483)
        // One corner's points, measured from it inward along the edge it
        // leaves (a) and the edge it comes to (b).
        let points: [(a: CGFloat, b: CGFloat)] = [(1.52866483, 0), (1.08849296, 0), (0.86840694, 0), (0.63149399, 0.07491100),
                                                  (0.37282392, 0.16905037), (0.16905037, 0.37282392), (0.07491100, 0.63149399),
                                                  (0, 0.86840694), (0, 1.08849296), (0, 1.52866483)]
        let corners: [(CGFloat, CGFloat) -> CGPoint] = [
            { CGPoint(x: rect.maxX - $0 * r, y: rect.minY + $1 * r) },
            { CGPoint(x: rect.maxX - $1 * r, y: rect.maxY - $0 * r) },
            { CGPoint(x: rect.minX + $0 * r, y: rect.maxY - $1 * r) },
            { CGPoint(x: rect.minX + $1 * r, y: rect.minY + $0 * r) },
        ]
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX + points[0].a * r, y: rect.minY))
        for at in corners {
            let p = points.map { at($0.a, $0.b) }
            path.addLine(to: p[0])
            for k in stride(from: 1, to: 10, by: 3) { path.addCurve(to: p[k + 2], control1: p[k], control2: p[k + 1]) }
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - the terminal

/// A Terminal window's strip and its two lines, the second typed, with a
/// block caret.
private struct TerminalDrawing: View {
    let field: String
    let who: String
    let line: String

    private static let muted = Color(nsColor: WelcomeHue.hex(0x8C8C8C))
    private static let ink = Color(nsColor: WelcomeHue.hex(0xEDEDED))

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { _ in Circle().fill(Color(nsColor: WelcomeHue.hex(0x4A4A4C))).frame(width: 10, height: 10) }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                Text(who).font(.system(size: 11)).foregroundStyle(Self.muted)
            }
            .frame(height: 28)
            VStack(alignment: .leading, spacing: 0) {
                Text("~ % " + who).foregroundStyle(Self.muted).frame(height: 20)
                HStack(spacing: 1) {
                    WelcomeTypedLine(field: field, text: line)
                    Rectangle().fill(Self.ink).frame(width: 8, height: 15)
                }
                .frame(height: 20)
            }
            .font(.system(size: 13, design: .monospaced))
            .foregroundStyle(Self.ink)
            .lineLimit(1)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - the grain

/// The backdrop's grain over the window-to-be, as BackdropFill lays it:
/// Grain's tile, clipped to the window's corner. How much of it shows is
/// the "y-grain" part's own opacity, Grain.opacity(amount), which the Color
/// editor's grain track sets on that layer directly while it is dragged.
/// The window-to-be's colors after the main one, corner to corner, turned
/// as Shift with tabs turns them, and the drawings over them: the window's
/// own coating (BackdropCoatingView) in small. The main color is the
/// plate's; a drag recolors this at once through `shown`.
private struct WelcomeTintDrawing: NSViewRepresentable {
    let look: WelcomeWindowLook
    let corner: CGFloat

    func makeNSView(context: Context) -> WelcomeTintView { WelcomeTintView() }

    func updateNSView(_ view: WelcomeTintView, context: Context) {
        view.show(look, corner: corner)
    }
}

final class WelcomeTintView: NSView {
    /// The one on the stage, for a drag to recolor without a board.
    static weak var shown: WelcomeTintView?
    private let gradient = CAGradientLayer()
    private let drawings = CALayer()
    private var step = 0
    private var corner: CGFloat = 0
    /// The drawings' set and ink worn now, drawn again only when they change.
    private var drawn: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerCurve = .continuous
        let ends = BackdropCoatingView.ends(0)
        gradient.startPoint = ends.start
        gradient.endPoint = ends.end
        gradient.isHidden = true
        drawings.isHidden = true
        layer?.addSublayer(gradient)
        layer?.addSublayer(drawings)
    }

    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        drawings.frame = bounds
        CATransaction.commit()
    }

    func show(_ look: WelcomeWindowLook, corner: CGFloat? = nil) {
        Self.shown = self
        if let corner { self.corner = corner }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.cornerRadius = self.corner
        let alpha = WelcomeWindowLook.opacity(look.transparency)
        gradient.isHidden = look.colors.isEmpty
        gradient.colors = ([look.color] + look.colors).map { $0.withAlphaComponent(alpha).cgColor }
        if let set = LookDrawings.Set(rawValue: look.drawings) {
            let white = LookDrawings.light(on: look.color)
            let key = "\(set.rawValue)-\(white)"
            if drawn != key {
                drawings.backgroundColor = NSColor(patternImage: LookDrawings.tile(set, white: white)).cgColor
                drawn = key
            }
            drawings.opacity = Float(LookDrawings.opacity(look.strength, dark: white))
            drawings.isHidden = false
        } else {
            drawings.isHidden = true
        }
        CATransaction.commit()
        turn(to: look.step)
    }

    /// A quarter turn a step, as the window's coating turns.
    private func turn(to step: Int) {
        guard step != self.step else { return }
        let from = BackdropCoatingView.ends(self.step), to = BackdropCoatingView.ends(step)
        self.step = step
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.startPoint = to.start
        gradient.endPoint = to.end
        CATransaction.commit()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, !gradient.isHidden else { return }
        for (key, a, b) in [("startPoint", from.start, to.start), ("endPoint", from.end, to.end)] {
            let move = CABasicAnimation(keyPath: key)
            move.fromValue = NSValue(point: a)
            move.toValue = NSValue(point: b)
            move.duration = 0.56
            move.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            gradient.add(move, forKey: "look-turn-" + key)
        }
    }
}

private struct GrainDrawing: NSViewRepresentable {
    let amount: Double
    let corner: CGFloat

    func makeNSView(context: Context) -> WelcomeGrainView { WelcomeGrainView() }

    func updateNSView(_ view: WelcomeGrainView, context: Context) {
        view.show(amount: amount, corner: corner)
    }
}

final class WelcomeGrainView: NSView {
    private var amount: Double = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.masksToBounds = true
        layer?.cornerCurve = .continuous
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { needsDisplay = true }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        thicken()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.patternPhase = .zero
        NSColor(patternImage: Grain.tile).setFill()
        dirtyRect.fill(using: .sourceOver)
    }

    func show(amount: Double, corner: CGFloat) {
        self.amount = amount
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.cornerRadius = corner
        CATransaction.commit()
        thicken()
    }

    /// The part it is drawn in, as thick as the amount.
    private func thicken() {
        var view = superview
        while let found = view, !(found is WelcomePartView) { view = found.superview }
        guard let part = view?.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        part.opacity = Float(Grain.opacity(amount))
        CATransaction.commit()
    }
}
