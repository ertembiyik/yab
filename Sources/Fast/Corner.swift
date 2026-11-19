import SwiftUI
import WebKit

// What a mark says at its top corner: how many wait for you on that site, a
// meeting's time on a pinned calendar, the last minutes of a call. A few
// words on a plate, set into the mark the way the call's dot is at the
// bottom corner: a capsule a gap wider than the plate is cut out of the mark
// itself, so what shows round the plate is whatever the tab is drawn on, in
// any theme and on any space's color, never a ring of some other color.
//
// The count comes from the site: its own badge, when it calls the Badging
// API (`navigator.setAppBadge`), or a number in its title, "(3) Slack",
// "Inbox (12) - … - Gmail". Only on pins and kept tabs, the places you live
// in, and by default only on sites where a number means someone is waiting:
// mail, chat, notifications. YouTube's "(340)" is not a message.

/// The words at a mark's top corner.
struct Corner: Equatable {
    enum Kind: Equatable {
        /// A count, a meeting's minutes: the space's ink.
        case ink
        /// Join: the call's green.
        case go
    }

    var words: String
    var kind: Kind = .ink

    static func count(_ n: Int) -> Corner? {
        guard n > 0 else { return nil }
        return Corner(words: n > 99 ? "99+" : "\(n)")
    }
}

extension EnvironmentValues {
    /// A pinned calendar's meeting, said at its mark's corner (PinMeeting):
    /// handed down by the one pin that hears the minute, so no other mark
    /// has to.
    @Entry var meetingCorner: Corner? = nil
}

/// The plate: the words on a capsule, the number rolling when it changes.
struct CornerPlate: View {
    let corner: Corner
    @Environment(\.tone) private var tone

    static let height: CGFloat = 10
    /// The gap round the plate, cut out of the mark: the call's dot's.
    static let gap: CGFloat = CaptureDot.gap
    static let font = NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .semibold) // design: a 10-point plate on a 16-point mark, a Dock badge's scale

    /// One character is a circle; more, the words and three points a side.
    static func size(_ words: String) -> CGSize {
        guard words.count > 1 else { return CGSize(width: height, height: height) }
        let width = RollingTextView.width(words, font: font) + 6
        return CGSize(width: max(height, width.rounded(.up)), height: height)
    }

    var body: some View {
        let size = Self.size(corner.words)
        Capsule(style: .continuous)
            .fill(fill)
            .frame(width: size.width, height: size.height)
            .overlay {
                RollingText(text: corner.words, font: Self.font, color: ink)
                    // The layer's line box is the font's, taller than the
                    // digits' ink; up by what the descender adds below.
                    .offset(y: -0.5)
            }
            .allowsHitTesting(false)
    }

    private var fill: Color {
        switch corner.kind {
        case .ink: return Palette.strong(on: tone)
        case .go: return Color(nsColor: .systemGreen)
        }
    }

    private var ink: Color {
        switch corner.kind {
        case .ink: return tone?.color ?? Palette.ground
        case .go: return Meetings.joinInk
        }
    }
}

/// The two corners of a mark: the words at the top, the call's dot at the
/// bottom (drawn by TabMark), each set into a hole cut out of the mark. The
/// cut is a mask, and only while something is there: a mask is a layer drawn
/// apart, and with it on every mark each row of the column cost an offscreen
/// pass whenever the column moved.
struct MarkCorners: ViewModifier {
    var tab: Tab
    private var choices = CountSites.shared
    /// How far inside the mark's corner the call's dot centers.
    let dotInset: CGFloat
    /// Room right of the mark inside whatever it is drawn in: a wider plate
    /// moves in so it doesn't pass that edge (a pin on top is 30 points).
    let room: CGFloat
    /// How far above the mark's corner the words sit: a pin's letter is
    /// drawn from the top of its square down, and a plate centered on the
    /// corner would take the top of a 1 or a 7.
    var lift: CGFloat = 0
    @Environment(\.meetingCorner) private var meeting

    /// A 12-point letter's top sits about 3.5 points down its 16-point
    /// square, a 1's flag a little higher; the plate's hole ends 6.5 points
    /// under its center, so 4.5 up leaves it clear by a point and more.
    static let letterLift: CGFloat = 4.5

    func body(content: Content) -> some View {
        // Only a tab on a call hears the minute, as EndingSoon did: every
        // other mark is left alone when it turns.
        if tab.onCall {
            content.modifier(CallCorners(tab: tab, count: count, dotInset: dotInset, room: room, lift: lift))
        } else if tab.pin != nil || tab.kept, MailPage.isMail(tab.address) {
            content.modifier(MailCorners(tab: tab, dot: dot, dotInset: dotInset, room: room, lift: lift))
        } else {
            content.modifier(Cuts(corner: meeting ?? count, dot: dot, dotInset: dotInset, room: room, lift: lift))
        }
    }

    /// The call's dot, or a chat's ring or its blue dot (ChatCorner).
    private var dot: Bool { tab.camera != .none || tab.microphone != .none || tab.chatBusy != nil || tab.chatDone != nil }

    private var count: Corner? { tab.countCorner }
}

extension Tab {
    /// The count its mark shows: a pin's or a kept tab's, on a site whose
    /// count is on.
    var countCorner: Corner? { showsOwnCount ? unadornedCountCorner : nil }

    /// Also used to remove the title's duplicate number, and by rows with
    /// no icon at all (LooseCount), where there is nothing to double-badge.
    var unadornedCountCorner: Corner? {
        guard countsTitle, let count else { return nil }
        return .count(count)
    }

    /// Once this row uses unread counts, a stale title number cannot return
    /// merely because the API cleared its badge or favicon ownership hid it.
    var countsTitle: Bool { (pin != nil || kept) && Counts.shows(address) }
}

/// A row with no mark, letters rather than icons: the count stands on its
/// own where the mark would be, before the title.
struct LooseCount: View {
    var tab: Tab
    private var choices = CountSites.shared

    var body: some View {
        if let corner = tab.unadornedCountCorner { CornerPlate(corner: corner) }
    }
}

/// A call's tab: its last five minutes at the top corner, "5m", over the
/// microphone's dot, when the calendar knows when it ends. One small shake
/// as they come and at two, as the words at its end had.
private struct CallCorners: ViewModifier {
    var tab: Tab
    var meetings = Meetings.shared
    let count: Corner?
    let dotInset: CGFloat
    let room: CGFloat
    let lift: CGFloat

    func body(content: Content) -> some View {
        let key = CallLink.key(tab.callStarted ?? tab.address)
        let left = meetings.wanted ? meetings.minutesLeft(for: key) : nil
        content.modifier(Cuts(corner: left.map { Corner(words: "\($0)m") } ?? count,
                              dot: tab.camera != .none || tab.microphone != .none,
                              dotInset: dotInset, room: room, lift: lift, nudge: left.map { $0 <= 2 ? 2 : 5 }))
    }
}

/// The mail pin: the number Settings › Mail's Count says (MailCenter.counted),
/// at its mark's corner as a site's count is. Only this mark hears mail's count.
private struct MailCorners: ViewModifier {
    var tab: Tab
    var center = MailCenter.shared
    let dot: Bool
    let dotInset: CGFloat
    let room: CGFloat
    let lift: CGFloat

    func body(content: Content) -> some View {
        content.modifier(Cuts(corner: tab.appBadgeCount.flatMap(Corner.count) ??
                              (center.connected && tab.showsOwnCount && tab.appBadgeCount == nil ? .count(center.counted) : nil),
                              dot: dot, dotInset: dotInset, room: room, lift: lift))
    }
}

/// The holes and what sits in them.
struct Cuts: ViewModifier {
    let corner: Corner?
    let dot: Bool
    let dotInset: CGFloat
    let room: CGFloat
    var lift: CGFloat = 0
    /// A shake of the plate each time this changes (Nudge).
    var nudge: Int?

    func body(content: Content) -> some View {
        let plate = corner.map { CornerPlate.size($0.words) }
        // The plate's center is the mark's top corner, as the dot's is the
        // bottom one; a plate that would pass the room it has moves in.
        let shift = plate.map { max(0, $0.width / 2 - room) } ?? 0
        return Group {
            if dot || plate != nil {
                content.mask {
                    Rectangle()
                        .overlay(alignment: .bottomTrailing) {
                            if dot {
                                Circle()
                                    .frame(width: CaptureDot.hole, height: CaptureDot.hole)
                                    .offset(x: CaptureDot.hole / 2 - dotInset, y: CaptureDot.hole / 2 - dotInset)
                                    .blendMode(.destinationOut)
                            }
                        }
                        .overlay(alignment: .topTrailing) {
                            if let plate {
                                let hole = CGSize(width: plate.width + 2 * CornerPlate.gap, height: plate.height + 2 * CornerPlate.gap)
                                Capsule(style: .continuous)
                                    .frame(width: hole.width, height: hole.height)
                                    .offset(x: hole.width / 2 - shift, y: -hole.height / 2 - lift)
                                    .blendMode(.destinationOut)
                            }
                        }
                        .compositingGroup()
                }
            } else {
                content
            }
        }
        .overlay(alignment: .topTrailing) {
            if let corner, let plate {
                Group {
                    if let nudge {
                        CornerPlate(corner: corner).modifier(Nudge(at: nudge))
                    } else {
                        CornerPlate(corner: corner)
                    }
                }
                    .offset(x: plate.width / 2 - shift, y: -plate.height / 2 - lift)
                    .accessibilityLabel(corner.words)
            }
        }
    }
}

// MARK: - the count

enum Counts {
    /// Where a number in the title, or the site's badge, is someone waiting.
    static let sites: Set<String> = [
        "mail.google.com", "outlook.office.com", "outlook.office365.com", "outlook.live.com",
        "app.slack.com", "discord.com", "web.telegram.org", "web.whatsapp.com",
        "x.com", "twitter.com", "linkedin.com", "facebook.com", "messenger.com",
        "chat.google.com", "teams.microsoft.com", "teams.live.com",
        "github.com", "linear.app", "notion.so", "app.notion.com",
    ]

    static func site(_ url: URL?) -> String? {
        guard var host = url?.host()?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    /// Whether this site's count is shown: by default where it means someone
    /// waits, or as its pin's menu says.
    @MainActor
    static func shows(_ url: URL?) -> Bool {
        guard let site = site(url) else { return false }
        let choices = CountSites.shared
        if choices.off.contains(site) { return false }
        return sites.contains(site) || choices.on.contains(site)
    }

    /// Show Count, Hide Count, from a pin's or a kept tab's menu.
    @MainActor
    static func toggle(_ url: URL?) {
        guard let site = site(url) else { return }
        let choices = CountSites.shared
        if shows(url) {
            choices.on.remove(site)
            if sites.contains(site) { choices.off.insert(site) }
        } else {
            choices.off.remove(site)
            if !sites.contains(site) { choices.on.insert(site) }
        }
    }

    /// The title without its count, once the count is on the mark:
    /// "(3) Home / X" is "Home / X", "Inbox (12) - … - Gmail" is
    /// "Inbox - … - Gmail".
    static func untitled(_ title: String) -> String {
        var text = title.trimmingCharacters(in: .whitespaces)
        for pattern in [#"^\(\d[\d,  ]*\+?\)\s*"#, #"\s*\(\d[\d,  ]*\+?\)$"#] {
            if let match = text.range(of: pattern, options: .regularExpression) { text.removeSubrange(match) }
        }
        if let match = text.range(of: #"^[^()\-|–·]{1,40}?(\s\(\d[\d,  ]*\+?\))\s*[-|–·]"#, options: .regularExpression),
           let inner = text[match].range(of: #"\s\(\d[\d,  ]*\+?\)"#, options: .regularExpression) {
            text.removeSubrange(inner)
        }
        return text.isEmpty ? title : text
    }

    /// The number a title carries: at its start, "(3) Home / X"; after the
    /// first words, "Inbox (12) - … - Gmail"; or at its end, "Telegram (3)".
    /// Thousands may have a comma or a space. Nil when there is none.
    static func fromTitle(_ title: String) -> Int? {
        let text = title.trimmingCharacters(in: .whitespaces)
        let patterns = [
            #"^\((\d[\d,  ]*)\+?\)"#,
            #"^[^()\-|–·]{1,40}?\((\d[\d,  ]*)\+?\)\s*[-|–·]"#,
            #"\((\d[\d,  ]*)\+?\)$"#,
        ]
        for pattern in patterns {
            guard let match = text.range(of: pattern, options: .regularExpression) else { continue }
            let digits = text[match].filter(\.isNumber)
            if let n = Int(digits) { return n }
        }
        return nil
    }
}

/// The sites whose count you turned on or off, against the default. Every
/// mark with a count hears it, which costs nothing: it changes only from a
/// menu.
@MainActor
@Observable final class CountSites {
    static let shared = CountSites()
    private let store = Store.settings

    var on: Set<String> { didSet { store.set(Array(on).sorted(), forKey: "counts.on") } }
    var off: Set<String> { didSet { store.set(Array(off).sorted(), forKey: "counts.off") } }

    private init() {
        on = Set(store.stringArray(forKey: "counts.on") ?? [])
        off = Set(store.stringArray(forKey: "counts.off") ?? [])
    }
}

/// Evidence belongs to one document, not a host or favicon cache entry.
/// A new icon invalidates it even when the count has not changed yet.
struct CountIconProof {
    private var previous: (count: Int?, icon: String)?
    private var iconChangedSinceCount = false
    private var followsCount = false
    private(set) var unchanged = false

    var icon: String? { previous?.icon }

    mutating func observe(count: Int?, icon: String) {
        if let previous {
            if previous.icon != icon {
                unchanged = false
                iconChangedSinceCount = true
            }
            if let before = previous.count, let count, before != count {
                // Compare the whole interval between count transitions, not
                // just the last snapshot: a page may update its icon first
                // and its title in a separate mutation delivery.
                if iconChangedSinceCount {
                    // This document has demonstrated a count-dependent
                    // icon. Later title-only changes cannot establish that
                    // its existing pixels stopped carrying that number.
                    followsCount = true
                }
                unchanged = !iconChangedSinceCount && !followsCount
                iconChangedSinceCount = false
            }
        }
        previous = (count, icon)
    }
}

// MARK: - the site's own badge

/// `navigator.setAppBadge` and `clearAppBadge`, heard: the page's world
/// wraps them and hands the number over to yab's.
final class BadgeRelay: NSObject, PageScriptReceiving {
    static let name = "yabBadge"
    weak var tab: Tab?

    func receive(_ message: PageScriptMessage) {
        guard message.frame.isMain else { return }
        let n = (message.body as? NSNumber)?.intValue
        MainActor.assumeIsolated { tab?.badged(n.map { max(0, min($0, 99_999)) }) }
    }

    /// In the page's own world: the API a web app already calls, kept
    /// working as it was, telling yab the number too. Nothing else.
    static let page = """
    (function () {
      if (window.top !== window || !window.navigator) return;
      var nav = window.navigator;
      var set = nav.setAppBadge, clear = nav.clearAppBadge;
      function tell(n) { try { window.dispatchEvent(new CustomEvent('yab:badge', { detail: n })); } catch (e) {} }
      function call(f, args) { try { if (f) return f.apply(nav, args); } catch (e) {} return Promise.resolve(); }
      Object.defineProperty(nav, 'setAppBadge', { configurable: true, writable: true, value: function (n) {
        tell(n === undefined ? 1 : Number(n) || 0);
        return call(set, arguments);
      } });
      Object.defineProperty(nav, 'clearAppBadge', { configurable: true, writable: true, value: function () {
        tell(0);
        return call(clear, arguments);
      } });
    })();
    """

    /// In yab's world: the number, handed on.
    static let bridge = """
    (function () {
      var handler = window.webkit && webkit.messageHandlers && webkit.messageHandlers.\(name);
      if (!handler || window.__yabBadgeBridged) return;
      window.__yabBadgeBridged = true;
      window.addEventListener('yab:badge', function (e) {
        var n = Number(e.detail);
        if (isFinite(n)) handler.postMessage(Math.round(n));
      });
    })();
    """
}
