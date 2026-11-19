import AppKit
import SwiftUI

/// Links in an answer as Dia shows them: the site's icon before the words,
/// and on hover a tip with the page's title, when it has been here, and
/// its site. The icon has its room from the start, a letter until the
/// site's own arrives, and the tip is a panel of its own: nothing in the
/// line moves.
@MainActor
@Observable final class AnswerLinks {
    static let shared = AnswerLinks()

    /// Bumped when an icon a link asked for arrives: the words with links
    /// draw again, wearing it.
    private(set) var arrivals = 0
    @ObservationIgnored private var asked: Set<String> = []
    @ObservationIgnored private var drawn: [String: NSImage] = [:]
    /// The words with links on screen, in a test run (bench answer-links).
    let live = NSHashTable<LinkSpots>.weakObjects()

    /// A site's icon arrived (AppStartup's Favicons.arrived).
    func arrived(_ host: String) {
        if asked.remove(host) != nil { arrivals += 1 }
    }

    /// The host a link's icon is the icon of: only pages on the web have one.
    nonisolated static func host(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return url.host()?.lowercased()
    }

    /// The icon as a piece of the line: a hair under the words' middle,
    /// kept to the words after it by a space no line breaks at.
    func icon(_ host: String, size: CGFloat) -> Text {
        let side = (size - 1).rounded()
        let image = picture(host, side: side)
        // Its middle on the lowercase letters' middle.
        let lift = size * 0.33 - side / 2
        return Text(Image(nsImage: image)).baselineOffset(lift) + Text("\u{202F}")
    }

    private func picture(_ host: String, side: CGFloat) -> NSImage {
        let dark = Favicons.dark
        let icon = SiteMark.icon(host)
        let key = "\(host)|\(side)|\(dark)|\(icon == nil)"
        if let known = drawn[key] { return known }
        if icon == nil {
            asked.insert(host)
            Favicons.shared.fetch(host: host)
        }
        let letter = String(host.replacingOccurrences(of: "www.", with: "").prefix(1)).uppercased()
        // A black mark on the dark gets a light tile, as SiteMark gives it.
        let tile = icon.map { dark && SiteMark.dark($0, host) } ?? false
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let corner = side * 0.25
            let shape = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)
            if let icon {
                if tile {
                    NSColor.white.withAlphaComponent(0.92).setFill()
                    shape.fill()
                    icon.draw(in: rect.insetBy(dx: 1.5, dy: 1.5))
                } else {
                    shape.addClip()
                    icon.draw(in: rect)
                }
            } else {
                // A letter on a quiet tile until the site's icon is known.
                (dark ? NSColor.white : NSColor.black).withAlphaComponent(0.08).setFill()
                shape.fill()
                let words = NSAttributedString(string: letter, attributes: [
                    .font: NSFont.systemFont(ofSize: side * 0.68, weight: .semibold),
                    .foregroundColor: (dark ? NSColor.white : NSColor.black).withAlphaComponent(0.5),
                ])
                let bounds = words.size()
                words.draw(at: NSPoint(x: (side - bounds.width) / 2, y: (side - bounds.height) / 2))
            }
            return true
        }
        if drawn.count > 200 { drawn.removeAll() }
        drawn[key] = image
        return image
    }

    /// What the tip says: the page's title and its site, or the address
    /// whole when the page hasn't been here.
    static func tip(_ url: URL) -> String {
        guard let host = url.host() else { return url.absoluteString }
        if let title = History.current.title(of: url) {
            let site = IDN.shownAddress(host.hasPrefix("www.") ? String(host.dropFirst(4)) : host)
            return title + "\n" + site
        }
        return Address.whole(url)
    }
}

/// A run of a link's words, for the hover to find where it was drawn.
struct LinkSpot: TextAttribute {
    let url: URL
}

/// Where each link's words were drawn, read as they are drawn: hover
/// looks here, no layout of its own. Its own tip's owner too.
@MainActor
final class LinkSpots {
    var spots: [(rect: CGRect, url: URL)] = []
    /// The link the pointer is on.
    private(set) var on: URL?
    /// Where the words are on screen: a test run's only (bench answer-links).
    weak var view: NSView?

    /// The pointer at `point` in the words, or gone from them.
    func hover(_ point: CGPoint?) {
        let now = point.flatMap { point in spots.first { $0.rect.insetBy(dx: -1, dy: -2).contains(point) }?.url }
        guard now != on else { return }
        if on != nil { KeyTip.shared.leave(self) }
        on = now
        if let now { KeyTip.shared.hover(self, title: AnswerLinks.tip(now), shortcut: nil, side: .pointer) }
    }

    /// The links' rects on screen, from the top left of the first one.
    func onScreen() -> [[String: Any]] {
        guard let view, let window = view.window else { return [] }
        let top = NSScreen.screens.first?.frame.height ?? 0
        return spots.map { spot in
            var rect = spot.rect
            if !view.isFlipped { rect.origin.y = view.bounds.height - rect.maxY }
            let screen = window.convertToScreen(view.convert(rect, to: nil))
            return ["url": spot.url.absoluteString, "rect": [screen.minX, top - screen.maxY, screen.width, screen.height]]
        }
    }
}

/// Notes where the links fell, drawing nothing: it lays out a copy of
/// the words over them. Selectable words (`textSelection`) are drawn
/// with no renderer at all, so the words seen can't be the ones measured.
private struct LinkSpotter: TextRenderer {
    let found: LinkSpots

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        var spots: [(rect: CGRect, url: URL)] = []
        for line in layout {
            for run in line {
                if let spot = run[LinkSpot.self] { spots.append((rect: run.typographicBounds.rect, url: spot.url)) }
            }
        }
        let drawn = spots
        MainActor.assumeIsolated { found.spots = drawn }
    }
}

/// Rich words (`RichMemo.text`) with a tip over each link: its title
/// and site. An unseen copy of the words, laid out the same, says where
/// the links are; it takes no clicks and no selection.
struct LinkedText: View {
    let text: Text
    @State private var found = LinkSpots()
    private static let testing = Store.testing

    var body: some View {
        text
            .overlay(alignment: .topLeading) {
                // Its own height: held to the words' frame, a rounding short,
                // it would drop its last line, and that line's links.
                text.textRenderer(LinkSpotter(found: found))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.disabled)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .onContinuousHover { phase in
                if case .active(let at) = phase { found.hover(at) } else { found.hover(nil) }
            }
            .background { if LinkedText.testing { SpotAnchor(found: found) } }
            .onAppear { if LinkedText.testing { AnswerLinks.shared.live.add(found) } }
            .onDisappear { found.hover(nil) }
    }
}

/// The words' place on screen for a test run's bench, taking no clicks.
private struct SpotAnchor: NSViewRepresentable {
    let found: LinkSpots
    func makeNSView(context: Context) -> NSView {
        let view = Transparent()
        found.view = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { found.view = view }

    private final class Transparent: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

extension AnswerLinks {
    /// Whether words have a link in them, for the tips: none, no renderer.
    nonisolated static func linked(_ words: String) -> Bool {
        words.contains("](") || words.contains("<http")
    }
}
