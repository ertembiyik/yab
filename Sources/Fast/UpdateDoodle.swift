import AppKit
import Combine
import CoreText
import SwiftUI

// A newer Yab, written in by hand where the tabs are. The updater has
// already fetched and swapped it in by the time anything shows (Updater), so
// there is nothing to wait for and nothing to show while it downloads: an
// Update button comes, and a pen writes beside it in the Mac's accent,
// the way someone scribbles on your screen to point a thing
// out: "Yab 1.2 is here!" and a heart, "restart to update", an arrow to the
// button and a loop round it, and "not now" under it all. Arc's old "Arc is
// ready to update!" had a heart that beat; this one is drawn.
//
// With the tabs on top the button stands at the far end of the strip, where
// it always stood, and the note is written on the page just under it. With
// the tabs in the column, whose foot is the downloads, the extensions and
// the space's capsule, the button stands in the capsule's place for as long
// as there is something to say, and the note is written in the column's own
// room over the foot, the rows keeping clear of it (UpdateOrCapsule,
// UpdateSlot, UpdateRoom), never over someone else's site.
//
// It is one pen: written out in 2.2 s, the rare moment that takes its time
// (family-values-motion P10), then still. The line trembles, as a drawn
// animation's does, only while the pointer is on the button and for a
// moment after writing, so an update left waiting for days costs nothing
// while it waits. State is instant (P6): the button's words change at once
// and the ink says the rest.
//
//   fetching       nothing.
//   ready          the button, and the note written in.
//   pointed        the ink trembles faster.
//   Update         the ink taken back, quick, last stroke first; the button
//                  says "Restarting…"; the window goes.
//   back           the new Yab's first frame is that button; a beat, then
//                  "What's new ↗" and a new note: "you're on 1.2!" and a
//                  tick, "have a look", "got it".
//   not now        a zigzag through the note, then the ink taken back. With
//                  the tabs on top the Update button stays, quiet, and
//                  restarts when pressed; in the column nothing is left. The
//                  update comes with the next launch anyway.
//   offered        the same note, "download it here", for the disk image.
//   done           the ink taken back, the button gone.
//   on a call      no ink, and in the column no button: nobody restarts in
//                  a meeting.
//   reduce motion  the ink fades in and out whole and never trembles.

@MainActor
@Observable final class UpdateNews {
    static let shared = UpdateNews()

    enum Phase: Equatable {
        case none
        /// Swapped in; a restart makes it this Yab.
        case ready(version: String)
        case restarting(version: String)
        /// It couldn't be swapped in here; the disk image is offered.
        case offered(version: String, dmg: URL)
        /// This is the new one; `changelog` is where what's new is read.
        case updated(version: String, changelog: URL?)
    }

    private(set) var phase = Phase.none
    /// Put off with "not now": the ink is gone for this version. With the
    /// tabs on top the button stays, quiet; in the column nothing does.
    private(set) var tucked = false
    /// The zigzag through the note, drawn before the ink is taken back.
    private(set) var striking = false
    /// The ink being taken back before what it said goes: "not now", or
    /// done with.
    private(set) var wiping = false
    /// The pointer on the Update button: the ink trembles faster.
    var pointed = false
    /// The Update button at the far end of the strip, in the window's
    /// space, for the note written on the page under it.
    var stripButton: CGRect?
    /// The button's width in the column's foot, where the plus stands
    /// otherwise: the spaces' row lends it the difference (SpaceRowPlan).
    var sideButton: CGFloat = 0

    /// Back from a restart, and not yet on screen: the button's first frame
    /// is the one the last Yab left.
    @ObservationIgnored private var arriving = false
    @ObservationIgnored private var watch: AnyCancellable?

    private enum Key {
        static let pending = "update.pending"
        static let restarting = "update.restarting"
        static let shown = "update.shown"
        static let later = "update.later"
    }

    private init() {}

    /// At launch, after the updater has been started.
    func start() {
        let current = Updater.version
        // A Yab that was ready and is now this one: it is the update.
        if let pending = Store.settings.dictionary(forKey: Key.pending), pending["version"] as? String == current {
            Store.settings.set(["version": current, "changelog": pending["changelog"] as? String ?? "", "since": Date()], forKey: Key.shown)
            Store.settings.removeObject(forKey: Key.pending)
            Store.settings.removeObject(forKey: Key.later)
            arriving = Store.settings.bool(forKey: Key.restarting)
        }
        Store.settings.removeObject(forKey: Key.restarting)
        if let shown = Store.settings.dictionary(forKey: Key.shown), shown["version"] as? String == current,
           let since = shown["since"] as? Date, Date().timeIntervalSince(since) < 60 * 60 * 24 {
            phase = arriving ? .restarting(version: current) : .updated(version: current, changelog: Self.link(shown))
        } else {
            Store.settings.removeObject(forKey: Key.shown)
        }
        watch = Updater.shared.observed(\.stage).sink { [weak self] stage in
            DispatchQueue.main.async { self?.follow(stage) }
        }
    }

    private static func link(_ shown: [String: Any]?) -> URL? {
        (shown?["changelog"] as? String).flatMap(URL.init(string:)).flatMap { $0.scheme == nil ? nil : $0 }
    }

    private func follow(_ stage: Updater.Stage) {
        switch stage {
        case .ready(let release):
            Store.settings.set(["version": release.version, "changelog": release.changelog?.absoluteString ?? ""], forKey: Key.pending)
            if case .restarting = phase { return }
            tucked = Store.settings.string(forKey: Key.later) == release.version
            phase = .ready(version: release.version)
        case .offered(let release):
            tucked = Store.settings.string(forKey: Key.later) == release.version
            phase = .offered(version: release.version, dmg: release.dmg)
        case .none, .fetching:
            switch phase {
            case .updated, .none, .restarting: return
            default: phase = .none
            }
        }
    }

    /// The button is on screen for the first time since the restart: a beat
    /// as the button that was left, then its words turn and the new note is
    /// written. Timed from here rather than from launch, which is over
    /// before the window is up.
    func shown() {
        guard arriving, case .restarting(let version) = phase else { return }
        arriving = false
        let link = Self.link(Store.settings.dictionary(forKey: Key.shown))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.phase = .updated(version: version, changelog: link)
        }
    }

    // MARK: what a hand does

    func press(in browser: Browser) {
        switch phase {
        case .ready(let version):
            phase = .restarting(version: version)
            Store.settings.set(true, forKey: Key.restarting)
            // Long enough for the ink to have been taken back, then the
            // window goes.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { Updater.shared.relaunch() }
        case .offered(_, let dmg):
            browser.open(dmg, foreground: true)
        case .updated(_, let link):
            if let link {
                if Halloween.isDay() { Halloween.dressedUp() }
                browser.open(link, foreground: true)
            }
            done()
        default:
            break
        }
    }

    /// "not now" under the note, or "got it" once it is the new one.
    func notNow() {
        switch phase {
        case .updated:
            done()
        case .ready(let version), .offered(let version, _):
            guard !tucked, !striking else { return }
            Store.settings.set(version, forKey: Key.later)
            striking = true
            DispatchQueue.main.asyncAfter(deadline: .now() + UpdateInk.striking + 0.18) { [weak self] in
                self?.wiping = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + UpdateInk.striking + 0.18 + UpdateInk.wiping + 0.02) { [weak self] in
                guard let self else { return }
                striking = false
                wiping = false
                tucked = true
            }
        default:
            break
        }
    }

    func done() {
        Store.settings.removeObject(forKey: Key.shown)
        wiping = true
        DispatchQueue.main.asyncAfter(deadline: .now() + UpdateInk.wiping + 0.02) { [weak self] in
            guard let self else { return }
            wiping = false
            phase = .none
            tucked = false
        }
    }

    /// ./bench ui update: any phase, to look at; "back" is the new Yab's
    /// first frame after a restart, "plain" the new one with no changelog
    /// to open, "notnow" the note put off, "point" and "unpoint" the pointer
    /// on the button and off it.
    func bench(_ name: String) {
        let link = URL(string: "https://example.com/changelog")
        switch name {
        case "ready":
            tucked = false
            phase = .ready(version: "1.2")
        case "restarting": phase = .restarting(version: "1.2")
        case "offered":
            tucked = false
            phase = .offered(version: "1.2", dmg: URL(string: "https://example.com/yab.dmg")!)
        case "updated": phase = .updated(version: "1.2", changelog: link)
        case "plain": phase = .updated(version: "1.2", changelog: nil)
        case "none":
            phase = .none
            tucked = false
        case "notnow": notNow()
        case "point": pointed = true
        case "unpoint": pointed = false
        case "back":
            Store.settings.set(["version": "1.2", "changelog": link!.absoluteString, "since": Date()], forKey: Key.shown)
            phase = .none
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.arriving = true
                self.phase = .restarting(version: "1.2")
            }
        default: break
        }
    }
}

// MARK: - the button

/// Where the update is said: at the far end of the strip, or over the
/// column's foot.
enum UpdatePlace { case strip, side }

/// Update, Restarting…, What's new ↗: one button, only its words changing.
struct UpdateButton: View {
    var browser: Browser
    let place: UpdatePlace
    var news: UpdateNews = .shared
    var share: Share = .shared

    var body: some View {
        // Nothing about updates on a screen others see.
        if share.sessions.isEmpty, let words = UpdateInk.button(news.phase) {
            Button { news.press(in: browser) } label: {
                // As tall as the doors and the space's capsule beside it,
                // in the strip and in the column's foot alike.
                Text(words).frame(height: Door.side)
            }
                .buttonStyle(.yab(.secondary, .small, cornerRadius: place == .side ? SideBar.radius : Radius.control)) // design: in the column's foot, the doors' row corner (FootPlus)
                .focusable(false)
                // Its words whole however many tabs there are: they give way.
                .fixedSize()
                .allowsHitTesting(pressable)
                .onHover { news.pointed = $0 && pressable }
                .keyTip(news.tucked ? "Restart to update" : "")
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                    if place == .strip { news.stripButton = frame }
                    if place == .side, news.sideButton != frame.width { news.sideButton = frame.width }
                }
                .onAppear { news.shown() }
                .onDisappear {
                    if place == .strip { news.stripButton = nil }
                    if place == .side { news.sideButton = 0 }
                    news.pointed = false
                }
        }
    }

    private var pressable: Bool {
        if case .restarting = news.phase { return false }
        return true
    }
}

/// With the tabs in the column: the button stands in the foot where the
/// space's capsule does, for as long as there is something to say, and the
/// capsule comes back once it is done with or put off. On a call, the
/// capsule.
struct UpdateOrCapsule<Capsule: View>: View {
    var browser: Browser
    var calls: Calls
    var news: UpdateNews = .shared
    var share: Share = .shared
    @ViewBuilder let capsule: () -> Capsule

    var body: some View {
        let says = UpdateSlot.says(news, calls: calls)
        ZStack {
            if says {
                UpdateButton(browser: browser, place: .side)
                    .anchorPreference(key: UpdateMarks.Key.self, value: .bounds) { UpdateMarks(button: $0) }
                    .transition(.opacity)
            } else {
                capsule().transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.16), value: says)
    }
}

/// The room over the foot the note is written in, which the rows keep
/// clear (UpdateRoom).
struct UpdateSlot: View {
    var calls: Calls
    var news: UpdateNews = .shared
    var share: Share = .shared

    var body: some View {
        Color.clear
            .frame(height: Self.height(news, calls: calls))
            .anchorPreference(key: UpdateMarks.Key.self, value: .bounds) { UpdateMarks(slot: $0) }
            .animation(Motion.room, value: Self.height(news, calls: calls))
    }

    /// Something to say in the column: not once it is put off, never on
    /// a call or while the screen or a tab is shared or recorded.
    static func says(_ news: UpdateNews, calls: Calls) -> Bool {
        if calls.any || news.tucked || !Share.shared.sessions.isEmpty { return false }
        if case .none = news.phase { return false }
        return true
    }

    static func height(_ news: UpdateNews, calls: Calls) -> CGFloat {
        says(news, calls: calls) ? UpdateInk.above : 0
    }
}

/// In the column's rows, the room the note takes over the foot, as
/// BandRoom keeps the band's.
struct UpdateRoom: View {
    var calls: Calls
    var news: UpdateNews = .shared
    var share: Share = .shared

    var body: some View {
        Color.clear.frame(height: UpdateSlot.height(news, calls: calls))
    }
}

/// Where the button in the foot and the room over it are, told up to the
/// column, which writes the note over both (UpdateNoteInColumn).
struct UpdateMarks {
    var slot: Anchor<CGRect>?
    var button: Anchor<CGRect>?

    struct Key: PreferenceKey {
        static var defaultValue: UpdateMarks { UpdateMarks() }
        static func reduce(value: inout UpdateMarks, nextValue: () -> UpdateMarks) {
            let next = nextValue()
            value.slot = next.slot ?? value.slot
            value.button = next.button ?? value.button
        }
    }
}

/// The note in the column: written in the room over the foot and pointing
/// down at the button in the capsule's place. Right over the foot when
/// nothing plays; over the band when it does.
struct UpdateNoteInColumn: View {
    let marks: UpdateMarks
    var prefs: Preferences
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { proxy in
            if let button = marks.button {
                let at = proxy[button]
                let top = min(at.minY - UpdateInk.above, marks.slot.map { proxy[$0].minY } ?? .infinity)
                UpdateInk.Note(button: at, origin: CGPoint(x: 14, y: top), place: .side,
                               space: SpacePaint(prefs).color(dark: scheme == .dark),
                               ground: SpacePaint(prefs).color(dark: scheme == .dark))
            }
        }
    }
}

/// With the tabs on top: the note written on the page under the Update
/// button at the far end of the strip, over everything, taking no clicks
/// but its "not now".
struct UpdateInkOver: View {
    var browser: Browser
    var prefs: Preferences
    var news: UpdateNews = .shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        // Not with the strip put away (⌘S): its button is out of sight.
        if !prefs.sidebar, !prefs.stripShut, !news.tucked, let button = news.stripButton, UpdateInk.button(news.phase) != nil {
            UnlessOnCall(calls: browser.calls) {
                GeometryReader { proxy in
                    let origin = proxy.frame(in: .global).origin
                    let local = button.offsetBy(dx: -origin.x, dy: -origin.y)
                    OnPage(tab: browser.active) {
                        UpdateInk.Note(button: local, origin: UpdateInk.under(local), place: .strip,
                                       space: SpacePaint(prefs).color(dark: scheme == .dark),
                                       ground: browser.active?.isBlank == false ? nil : SpacePaint(prefs).color(dark: scheme == .dark))
                    }
                }
            }
        }
    }
}

/// The note is written on the page, so its ink is the one for the page's
/// own light or dark, not the window's; Yab's own blank page is the window's.
private struct OnPage<Content: View>: View {
    let tab: Tab?
    @ViewBuilder let content: () -> Content

    var body: some View {
        if let tab {
            Shade(tab: tab, content: content)
        } else {
            content()
        }
    }

    private struct Shade: View {
        var tab: Tab
        let content: () -> Content
        @Environment(\.colorScheme) private var scheme

        var body: some View {
            content().environment(\.colorScheme, tab.isBlank ? scheme : tab.shade ?? .light)
        }
    }
}

// MARK: - the ink

enum UpdateInk {
    struct Words: Equatable {
        let first: String
        let mark: Mark
        let second: String
        /// "not now", "got it": the one part of the note that takes a click.
        let aside: String?
    }

    enum Mark { case heart, tick, pumpkin }

    /// Only on October 31 the note wears its costume: a pumpkin for
    /// the heart and the tick, pumpkin ink, and What's new is where to
    /// dress Yab up, said until Yab is dressed (Halloween.swift).
    static func words(_ phase: UpdateNews.Phase, halloween: Bool = Halloween.isDay(), dressed: Bool = Halloween.dressed) -> Words? {
        switch phase {
        case .ready(let version):
            return Words(first: "Yab \(version) is here!", mark: halloween ? .pumpkin : .heart, second: "restart to update", aside: "not now")
        case .offered(let version, _):
            return Words(first: "Yab \(version) is here!", mark: halloween ? .pumpkin : .heart, second: "download it here", aside: "not now")
        case .updated(let version, let link):
            return Words(first: "you're on \(version)!", mark: halloween ? .pumpkin : .tick,
                         second: link == nil ? "all fresh" : halloween && !dressed ? "dress it up" : "have a look", aside: link == nil ? nil : "got it")
        default:
            return nil
        }
    }

    static func button(_ phase: UpdateNews.Phase) -> String? {
        switch phase {
        case .none: return nil
        case .ready: return "Update"
        case .offered: return "Download"
        case .restarting: return "Restarting…"
        case .updated(_, let link): return link == nil ? "Got it" : "What's new ↗"
        }
    }

    /// Written out: the rare moment's length (family-values-motion P10).
    static let writing: Double = 2.2
    /// Taken back: quick, last stroke first.
    static let wiping: Double = 0.24
    /// The zigzag through the note.
    static let striking: Double = 0.24

    /// One line of the note to the next.
    static let pitch: CGFloat = 25
    /// In the column, the note's top over the button's: three lines, the
    /// first two at the pitch, "not now" smaller, and the air the arrow
    /// comes down through.
    static let above: CGFloat = pitch * 2 + 20 + 16
    /// In the column, the second line starts a little in, as a hand's
    /// next line does, and its arrow has less far to go.
    static let indent: CGFloat = 18

    /// With the tabs on top, where the note starts on the page: under the
    /// button, far enough left that the arrow from its second line runs a
    /// little way before it turns up to the loop, and never off the page.
    static func under(_ button: CGRect) -> CGPoint {
        let words = Words(first: "Yab 1.20 is here!", mark: .heart, second: "restart to update", aside: nil)
        let turn = button.midX - loop(button).width / 2 * 0.35
        let top = width(words.first, first) + 28
        let next = width(words.second, second)
        let x = min(turn - 40 - top, turn - 46 - next)
        return CGPoint(x: max(16, x), y: button.maxY + 22)
    }

    // MARK: the pen's hand

    /// Caveat, the hand the note is written in (Resources/Caveat.ttf, SIL
    /// OFL, THIRD_PARTY_NOTICES.md), from its one variable face; Bradley
    /// Hand, the Mac's own, in a build without it.
    private static let face: CTFontDescriptor? = {
        guard let url = Bundle.main.url(forResource: "Caveat", withExtension: "ttf"),
              let faces = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor]
        else { return nil }
        return faces.first
    }()

    /// Also the hand on the notebook's card in Get to Know's chat (KnowCard).
    static func hand(_ size: CGFloat, weight: Double) -> CTFont {
        guard let face else { return CTFontCreateWithName("BradleyHandITCTT-Bold" as CFString, size, nil) }
        // The weight axis, 'wght', 400 to 700.
        let axis = NSNumber(value: 0x7767_6874 as UInt32)
        let described = CTFontDescriptorCreateCopyWithAttributes(face, [kCTFontVariationAttribute as String: [axis: NSNumber(value: weight)]] as CFDictionary)
        return CTFontCreateWithFontDescriptor(described, size, nil)
    }

    static let first = hand(21, weight: 700)
    static let second = hand(19, weight: 500)
    static let aside = hand(17, weight: 600)

    static func width(_ text: String, _ font: CTFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: unsafeBitCast(font, to: NSFont.self)]).width)
    }

    /// The Mac's accent, or Halloween's orange on October 31.
    static var pen: Color { Halloween.isDay() ? Color(red: 0.82, green: 0.34, blue: 0.05) : .accentColor }

    /// The pen over a space's color: that color's own hue, deep over a light
    /// ground and pale over a dark one, so the note reads on every space
    /// instead of the accent sinking into a ground of its own color. Over
    /// the page (tabs on top) the page's light or dark says which; a space
    /// with no color of its own keeps the accent.
    static func pen(space: NSColor?, ground: NSColor?, dark: Bool) -> Color {
        if Halloween.isDay() { return pen }
        guard let space = space?.usingColorSpace(.sRGB) else { return pen }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        space.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        guard s > 0.12 else { return pen }
        let light: Bool
        if let ground = ground?.usingColorSpace(.sRGB) {
            light = luminance(ground) > 0.35
        } else {
            light = !dark
        }
        return light
            ? Color(hue: h, saturation: min(1, max(s, 0.65)), brightness: 0.36)
            : Color(hue: h, saturation: 0.3, brightness: 0.97)
    }

    private static func luminance(_ color: NSColor) -> CGFloat {
        func lin(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(color.redComponent) + 0.7152 * lin(color.greenComponent) + 0.0722 * lin(color.blueComponent)
    }

    /// Close round the button, and a little to its left: in the column's
    /// foot it stands where the capsule does, 10 from the page, and the
    /// loop closes clear of the page's edge.
    static func loop(_ button: CGRect) -> CGRect {
        button.insetBy(dx: -6, dy: -5).offsetBy(dx: -2, dy: 0)
    }

    // MARK: the sheet

    /// Where every line and stroke of a note lies, worked out once from
    /// the words, where the note starts and where the button is.
    struct Sheet {
        let first: CGRect
        let second: CGRect
        let aside: CGRect?
        let mark: [CGPoint]
        let arrow: [[CGPoint]]
        let loop: [CGPoint]
        let strike: [CGPoint]
        let bounds: CGRect

        init(words: Words, origin: CGPoint, button: CGRect, place: UpdatePlace = .strip) {
            let indent = place == .side ? UpdateInk.indent : 0
            first = CGRect(x: origin.x, y: origin.y, width: UpdateInk.width(words.first, UpdateInk.first), height: 26)
            second = CGRect(x: origin.x + indent, y: origin.y + UpdateInk.pitch, width: UpdateInk.width(words.second, UpdateInk.second), height: 24)
            // In the column, under the second line where it starts, so the
            // three read as one note.
            aside = words.aside.map {
                CGRect(x: origin.x + indent, y: origin.y + UpdateInk.pitch * 2 - (place == .side ? 3 : 0),
                       width: UpdateInk.width($0, UpdateInk.aside), height: 20)
            }

            // After the first line: a heart, drawn in one go and a little
            // past where it began, or a tick.
            let hx = first.maxX + 15, hy = first.midY + 1
            var mark: [CGPoint] = []
            switch words.mark {
            case .heart:
                var t = 0.2
                while t <= .pi * 2 + 0.45 {
                    let x = 16 * pow(sin(t), 3)
                    let y = 13 * cos(t) - 5 * cos(2 * t) - 2 * cos(3 * t) - cos(4 * t)
                    mark.append(CGPoint(x: hx + 0.58 * x, y: hy - 0.58 * y))
                    t += 0.14
                }
            case .tick:
                mark = [CGPoint(x: hx - 7, y: hy), CGPoint(x: hx - 3, y: hy + 4), CGPoint(x: hx, y: hy + 7),
                        CGPoint(x: hx + 5, y: hy - 1), CGPoint(x: hx + 11, y: hy - 9)]
            case .pumpkin:
                // Round from the stem's foot, squat, with the dips between
                // its lobes, then the two grooves down its middle and back
                // up, then the stem.
                var t = -Double.pi / 2
                while t <= Double.pi * 1.5 {
                    let lobes = 1 - 0.1 * abs(sin(3 * (t + .pi / 2)))
                    mark.append(CGPoint(x: hx + 14 * cos(t) * lobes, y: hy + 1 + 10.5 * sin(t) * lobes))
                    t += 0.12
                }
                let top = CGPoint(x: hx, y: hy - 9.5), foot = CGPoint(x: hx, y: hy + 11.5)
                for (side, end) in [(-1.0, foot), (1.0, top)] {
                    let start = end == foot ? top : foot
                    for step in 1...8 {
                        let u = Double(step) / 8, bow = 4 * u * (1 - u)
                        mark.append(CGPoint(x: hx + side * 6.5 * bow, y: start.y + (end.y - start.y) * u))
                    }
                }
                mark += [CGPoint(x: hx + 0.5, y: hy - 12.5), CGPoint(x: hx + 2.5, y: hy - 15), CGPoint(x: hx + 5.5, y: hy - 15.5)]
            }
            self.mark = mark

            // The loop round the button: begun at its upper left, once
            // round and on past the start a little, just outside it, as a
            // hand's does. The overrun lies along the top, never out at the
            // column's edge.
            let ring = place == .side ? button.insetBy(dx: -6, dy: -4) : UpdateInk.loop(button)
            let rx = ring.width / 2, ry = ring.height / 2
            let begin = -130.0, sweep = 388.0
            var loop: [CGPoint] = []
            for degrees in stride(from: begin, through: begin + sweep, by: 5.0) {
                let t = degrees * .pi / 180, done = (degrees - begin) / sweep
                let over = max(0, (done - 0.9) / 0.1)
                if place == .side {
                    // A wide button in the foot: round its own shape, a
                    // squircle just outside it, so the loop neither cuts
                    // its corners nor runs off past its end.
                    let c = cos(t), s = sin(t), k = 1 + 0.02 * sin(t * 2.3 + 0.6) + over * 0.04
                    loop.append(CGPoint(x: ring.midX + rx * k * (c < 0 ? -1 : 1) * pow(abs(c), 0.55),
                                        y: ring.midY + ry * k * (s < 0 ? -1 : 1) * pow(abs(s), 0.55) - over * 1.5))
                } else {
                    let k = 1 + 0.025 * sin(t * 2.3 + 0.6) + over * 0.05 + done * 0.015
                    loop.append(CGPoint(x: ring.midX + rx * cos(t) * k, y: ring.midY + ry * sin(t) * k - over * 1.5))
                }
            }
            self.loop = loop

            // From the end of the second line, along and then up or down
            // to the loop's edge, with its head.
            let start: CGPoint, end: CGPoint, bend: CGPoint
            if place == .side {
                // Down to the loop's top, a little way along from where the
                // line ends, and short of the line.
                start = CGPoint(x: second.maxX + 5, y: second.midY)
                let x = min(max(start.x + 22, button.minX + button.width * 0.35), button.maxX - 16)
                end = CGPoint(x: x, y: ring.minY - 4)
                bend = end.x - start.x > 30 ? CGPoint(x: end.x - 4, y: start.y - 1) : CGPoint(x: start.x + 16, y: start.y + 2)
            } else {
                start = CGPoint(x: second.maxX + 6, y: second.midY + 2)
                let up = button.midY < start.y
                end = CGPoint(x: button.midX - rx * 0.35, y: up ? button.midY + ry + 5 : button.midY - ry - 5)
                bend = CGPoint(x: end.x + 4, y: start.y)
            }
            var shaft: [CGPoint] = []
            for step in 0...24 {
                let t = CGFloat(step) / 24, u = 1 - t
                shaft.append(CGPoint(x: u * u * start.x + 2 * u * t * bend.x + t * t * end.x,
                                     y: u * u * start.y + 2 * u * t * bend.y + t * t * end.y))
            }
            let before = shaft[21]
            let angle = atan2(end.y - before.y, end.x - before.x)
            func barb(_ turn: CGFloat) -> [CGPoint] {
                [end, CGPoint(x: end.x - 9 * cos(angle + turn), y: end.y - 9 * sin(angle + turn))]
            }
            arrow = [shaft, barb(0.5), barb(-0.5)]

            // Through the first two lines, for "not now".
            let left = min(first.minX, second.minX) - 2, right = max(first.maxX, second.maxX) + 14
            let high = first.minY + 6, low = second.maxY - 4
            strike = (0...7).map { i in
                CGPoint(x: left + (right - left) * CGFloat(i) / 7, y: i % 2 == 1 ? low : high)
            }

            var all = first.union(second).union(ring)
            if let aside { all = all.union(aside) }
            for point in mark + shaft { all = all.union(CGRect(origin: point, size: .zero)) }
            bounds = all.insetBy(dx: -16, dy: -16)
        }
    }

    // MARK: the note

    /// The note and its strokes, written in, trembling, struck through and
    /// taken back, as UpdateNews says.
    struct Note: View {
        let button: CGRect
        let origin: CGPoint
        let place: UpdatePlace
        /// The space's color the note is written over.
        var space: NSColor? = nil
        /// What the ink lies on, when that is the space's own color: the
        /// column, or the strip's blank page. Absent over a site's page.
        var ground: NSColor? = nil
        var news: UpdateNews = .shared
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.colorScheme) private var scheme
        /// What is on the paper, kept while it is taken back.
        @State private var drawn: Words?
        @State private var written: CGFloat = 0
        @State private var struck: CGFloat = 0
        /// A moment of trembling once it has been written.
        @State private var settling = false
        @State private var asideLit = false
        /// Written out, so "not now" takes a click.
        @State private var done = false
        @State private var halloween = Halloween.isDay()

        private var words: Words? { UpdateInk.words(news.phase, halloween: halloween) }
        private var on: Bool { words != nil && !news.tucked && !news.wiping }

        var body: some View {
            ZStack(alignment: .topLeading) {
                if let drawn {
                    let sheet = Sheet(words: drawn, origin: origin, button: button, place: place)
                    let trembling = !reduceMotion && (news.pointed || settling)
                    TimelineView(Tremble(on: trembling, every: news.pointed ? 0.07 : 0.13)) { context in
                        Ink(sheet: sheet, words: drawn, written: written, struck: struck,
                            seed: trembling ? Int(context.date.timeIntervalSinceReferenceDate / (news.pointed ? 0.07 : 0.13)) : 0,
                            amount: news.pointed ? 1.9 : 1.05, pen: UpdateInk.pen(space: space, ground: ground, dark: scheme == .dark), asideLit: asideLit, whole: reduceMotion,
                            halo: place == .side ? (scheme == .dark ? Color.black.opacity(0.55) : Color.white.opacity(0.85)) : nil)
                    }
                    .frame(width: sheet.bounds.width, height: sheet.bounds.height)
                    .offset(x: sheet.bounds.minX, y: sheet.bounds.minY)
                    .allowsHitTesting(false)
                    .accessibilityElement()
                    .accessibilityLabel("\(drawn.first) \(drawn.second)")
                    if let rect = sheet.aside, let aside = drawn.aside, done, struck == 0 {
                        Button { news.notNow() } label: {
                            Color.clear
                                .frame(width: rect.width + 8, height: rect.height + 4)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .focusable(false)
                        .onHover { asideLit = $0 }
                        .pointerStyle(.link)
                        .offset(x: rect.minX - 4, y: rect.minY - 2)
                        .accessibilityLabel(aside)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onAppear {
                halloween = Halloween.isDay()
                if on { write() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
                halloween = Halloween.isDay()
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
                halloween = Halloween.isDay()
            }
            .onChange(of: on) { _, now in now ? write() : wipe() }
            .onChange(of: words) { _, now in
                guard on, now != drawn else { return }
                write()
            }
            .onChange(of: news.striking) { _, now in
                guard now else { return }
                withAnimation(.linear(duration: UpdateInk.striking)) { struck = 1 }
            }
        }

        private func write() {
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) {
                drawn = words
                written = 0
                struck = 0
                done = false
            }
            DispatchQueue.main.async {
                withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .linear(duration: UpdateInk.writing)) { written = 1 }
            }
            let time = reduceMotion ? 0.2 : UpdateInk.writing
            DispatchQueue.main.asyncAfter(deadline: .now() + time) { if on { done = true } }
            guard !reduceMotion else { return }
            settling = true
            DispatchQueue.main.asyncAfter(deadline: .now() + time + 2.4) { settling = false }
        }

        private func wipe() {
            asideLit = false
            done = false
            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .easeIn(duration: UpdateInk.wiping)) {
                written = 0
                struck = 0
            }
        }
    }

    /// The trembling's clock: a tick every so often while it trembles, one
    /// frame and no more while it doesn't.
    private struct Tremble: TimelineSchedule {
        let on: Bool
        let every: TimeInterval

        func entries(from start: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
            var next = start
            var over = false
            return AnyIterator {
                guard !over else { return nil }
                defer {
                    if on { next = next.addingTimeInterval(every) } else { over = true }
                }
                return next
            }
        }
    }

    /// Everything on the paper at one moment of the pen: `written` runs
    /// from 0 to 1 through the lines and strokes in the order a hand makes
    /// them, `struck` draws the zigzag.
    private struct Ink: View, Animatable {
        let sheet: Sheet
        let words: Words
        var written: CGFloat
        var struck: CGFloat
        let seed: Int
        let amount: CGFloat
        let pen: Color
        let asideLit: Bool
        /// Reduce motion: all of it, faded in and out by `written`.
        let whole: Bool
        /// In the column, a soft edge of the ground's own light under the
        /// ink, so it reads over the space's color and drawings.
        let halo: Color?

        var animatableData: AnimatablePair<CGFloat, CGFloat> {
            get { AnimatablePair(written, struck) }
            set {
                written = newValue.first
                struck = newValue.second
            }
        }

        var body: some View {
            Canvas { context, _ in
                context.translateBy(x: -sheet.bounds.minX, y: -sheet.bounds.minY)
                if whole { context.opacity = written }
                if let halo {
                    context.addFilter(.shadow(color: halo, radius: 1.5)) // design: a halo of the ground under hand-drawn ink, not a card shadow
                    context.addFilter(.shadow(color: halo, radius: 3)) // design: the halo's wider second ring
                }
                let at = whole ? 1 : written
                let style = StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round)
                func stroke(_ lines: [[CGPoint]], _ share: CGFloat, salt: Int) {
                    guard share > 0 else { return }
                    let path = shaky(lines, salt: salt).trimmedPath(from: 0, to: share)
                    context.stroke(path, with: .color(pen), style: style)
                }
                write(words.first, UpdateInk.first, in: sheet.first, share: Self.part(at, 0, 0.22), salt: 1, color: pen, &context)
                stroke([sheet.mark], Self.part(at, 0.23, 0.36), salt: 2)
                write(words.second, UpdateInk.second, in: sheet.second, share: Self.part(at, 0.345, 0.535), salt: 3, color: pen, &context)
                stroke(sheet.arrow, Self.part(at, 0.527, 0.70), salt: 4)
                stroke([sheet.loop], Self.part(at, 0.68, 0.918), salt: 5)
                if let aside = words.aside, let rect = sheet.aside {
                    write(aside, UpdateInk.aside, in: rect, share: Self.part(at, 0.864, 1), salt: 6,
                          color: pen.opacity(asideLit ? 1 : 0.8), &context)
                }
                if struck > 0 {
                    context.stroke(shaky([sheet.strike], salt: 7).trimmedPath(from: 0, to: struck), with: .color(pen), style: style)
                }
            }
        }

        /// A line of words wiped in from the left as the pen crosses it.
        private func write(_ text: String, _ font: CTFont, in rect: CGRect, share: CGFloat, salt: Int, color: Color, _ context: inout GraphicsContext) {
            guard share > 0 else { return }
            var line = context
            line.clip(to: Path(CGRect(x: rect.minX - 4, y: rect.minY - 8, width: (rect.width + 12) * share, height: rect.height + 16)))
            let nudge = CGPoint(x: wobble(salt, 0) * 0.5, y: wobble(salt, 1) * 0.5)
            line.draw(Text(text).font(Font(font)).foregroundColor(color),
                      at: CGPoint(x: rect.minX + nudge.x, y: rect.minY + nudge.y), anchor: .topLeading)
        }

        /// The strokes as the hand left them this moment: every point a
        /// little off, differently at each tick while it trembles.
        private func shaky(_ lines: [[CGPoint]], salt: Int) -> Path {
            var path = Path()
            for (n, line) in lines.enumerated() {
                for (i, point) in line.enumerated() {
                    let key = salt * 1000 + n * 100 + i
                    let moved = CGPoint(x: point.x + wobble(key, 0) * amount / 2, y: point.y + wobble(key, 1) * amount / 2)
                    if i == 0 { path.move(to: moved) } else { path.addLine(to: moved) }
                }
            }
            return path
        }

        /// -1 to 1, the same for the same key, seed and axis.
        private func wobble(_ key: Int, _ axis: Int) -> CGFloat {
            var hash = UInt64(bitPattern: Int64(key &* 73_856_093 ^ seed &* 19_349_663 ^ axis &* 83_492_791))
            hash ^= hash >> 33
            hash = hash &* 0xff51_afd7_ed55_8ccd
            hash ^= hash >> 33
            return CGFloat(hash % 2001) / 1000 - 1
        }

        /// How far along one stroke is, eased as a pen slows into its end.
        static func part(_ at: CGFloat, _ from: CGFloat, _ to: CGFloat) -> CGFloat {
            let t = min(1, max(0, (at - from) / (to - from)))
            return 1 - pow(1 - t, 2)
        }
    }
}

/// Under About Yab, as in any Mac app that updates itself: the way to a
/// newer Yab that needs nothing in the window, which a broken build may not
/// let you press (0.0.17's second build took every click in it). The same
/// steps as ⌘K's Check for Updates and Restart to Update.
struct UpdateMenu: View {
    private var updater = Updater.shared
    let browser: () -> Browser

    init(browser: @escaping () -> Browser) { self.browser = browser }

    var body: some View {
        if Updater.enabled {
            switch updater.stage {
            case .none:
                Button(updater.checking ? "Checking for Updates…" : "Check for Updates…") {
                    // The menu closes on the press, so the answer comes as
                    // the Mac's own dialog, as Sparkle's does: a corner
                    // notice behind other windows went unseen.
                    updater.check { found in UpdateMenu.answer(found) }
                }
                .disabled(updater.checking)
            case .fetching:
                Button("Downloading Update…") {}
                    .disabled(true)
            case .ready:
                Button("Restart to Update") { updater.relaunch() }
            case .offered(let next):
                Button("Download Yab \(next.version)…") { _ = browser().open(next.dmg, foreground: true) }
            }
        }
    }

    @MainActor
    static func answer(_ found: Updater.Release?) {
        let alert = NSAlert()
        if let found {
            alert.messageText = "Yab \(found.version) is available"
            alert.informativeText = "It’s downloading now. Restart to Update appears in the Yab menu when it’s ready."
        } else {
            alert.messageText = "You’re up to date"
            alert.informativeText = "Yab \(Updater.version) is the newest version available."
        }
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
