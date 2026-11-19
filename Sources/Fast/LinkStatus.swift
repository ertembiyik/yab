import AppKit
import SwiftUI
import WebKit

/// The link under the pointer, said at the page's bottom left as Arc and
/// Safari say it; with keys held, what a click would do with it.
@MainActor
@Observable final class LinkStatus {
    static let shared = LinkStatus()

    struct Pointed: Equatable {
        let tab: Tab.ID
        let url: URL
        /// The link's own words, as WebKit read them (`linkLabel`), for a
        /// notice naming what a click opened out of sight.
        var label: String? = nil
    }

    private(set) var pointed: Pointed?
    /// The keys that change a click on a link, as held now.
    private(set) var keys: NSEvent.ModifierFlags = []
    @ObservationIgnored private var watch: Any?
    /// The pointer's own moves, every one the app is given: WebKit hears
    /// them from a tracking area of its own, not through the page view.
    @ObservationIgnored private var moves: Any?
    /// For the bench (pointer op=pictures): WebKit's words on what is under
    /// the pointer, and how many changed the link.
    @ObservationIgnored private(set) var told = 0
    @ObservationIgnored private(set) var changed = 0
    /// What WebKit last said is under the pointer, shown or not: the words
    /// of a link a click opens (`label(of:in:)`).
    @ObservationIgnored private var under: Pointed?
    @ObservationIgnored private var rule = Rule()

    /// When the pill speaks. WebKit says what is under the pointer as the
    /// pointer moves, and again as a scroll carries the page under a
    /// pointer at rest: on a feed every thumbnail's link going by put the
    /// pill up and took it down, and its glass over the scrolling page
    /// cost Yab's main thread some 7 s a minute of it (row 1051, 1181,
    /// evals/scroll-ram). So only the pointer's own moves show a link or
    /// change it; one a scroll brings shows nothing, and the pill a scroll
    /// takes off its link goes. Keys held change its words either way.
    struct Rule {
        private var moves = 0, seen = 0

        /// The pointer moved (the app's mouse moves and drags).
        mutating func moved() { moves += 1 }
        /// The page scrolled under it: what WebKit says next is the
        /// scroll's, unless the pointer moves first.
        mutating func scrolled() { seen = moves }

        /// What the pill shows, given what it shows and what WebKit says
        /// is under the pointer now.
        mutating func next<T: Equatable>(showing: T?, offered: T?) -> T? {
            let moved = moves != seen
            seen = moves
            if moved { return offered }
            return offered == showing ? showing : nil
        }
    }

    /// The pointer itself moved over a page.
    func pointerMoved() { rule.moved() }
    /// A page scrolled under the pointer.
    func scrolled() { rule.scrolled() }

    init() {
        // WebKit says the keys only as the pointer moves: held or let go
        // with the pointer still, the words change all the same.
        watch = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let held = Self.clicking(event.modifierFlags)
            AppKitMainThread.sync { if self?.keys != held { self?.keys = held } }
            return event
        }
        moves = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]) { [weak self] event in
            AppKitMainThread.sync { self?.pointerMoved() }
            return event
        }
    }

    deinit {
        if let watch { NSEvent.removeMonitor(watch) }
        if let moves { NSEvent.removeMonitor(moves) }
    }

    nonisolated static func clicking(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection([.command, .shift, .option, .control])
    }

    /// WebKit's word on what is under the pointer in a page: a link, or none.
    func pointed(at url: URL?, in tab: Tab.ID?, keys: NSEvent.ModifierFlags, label: String? = nil) {
        told += 1
        let now = url.flatMap { url in tab.map { Pointed(tab: $0, url: url, label: label) } }
        under = now
        let shown = rule.next(showing: pointed, offered: now)
        if pointed != shown { pointed = shown; changed += 1 }
        let held = Self.clicking(keys)
        if self.keys != held { self.keys = held }
    }

    /// The words of the link under the pointer in `tab`, when it goes to
    /// `url`: the link a middle click or a ⌘-click just opened.
    func label(of url: URL, in tab: Tab.ID?) -> String? {
        guard let under, under.url == url, tab == nil || under.tab == tab else { return nil }
        return under.label
    }

    /// The page it was said for is gone or went somewhere else.
    func forget(_ tab: Tab.ID) {
        if pointed?.tab == tab { pointed = nil }
        if under?.tab == tab { under = nil }
    }

    /// What a click with these keys does, by the link policy in
    /// Browser.webView(_:decidePolicyFor:decisionHandler:), or nil for a
    /// plain click, which just says where it goes.
    nonisolated static func act(_ keys: NSEvent.ModifierFlags, peekClick: PeekClick = .shift) -> String? {
        if keys == peekClick.flags { return "in a peek" }
        return switch keys {
        case [.command]: "in a new tab"
        case [.command, .shift]: "in a new tab and go to it"
        case [.option]: "in Split View"
        case [.shift]: nil
        default: nil
        }
    }

    /// Where a link goes, as one reads it: no scheme for the web's own.
    nonisolated static func place(_ url: URL) -> String {
        let whole = url.absoluteString
        for scheme in ["https://", "http://"] where whole.hasPrefix(scheme) {
            return IDN.shownAddress(String(whole.dropFirst(scheme.count)))
        }
        return whole
    }
}

/// The pill at a page's bottom left for the link under the pointer.
struct LinkStatusPill: View {
    var status = LinkStatus.shared
    let tab: Tab.ID

    var body: some View {
        if let pointed = status.pointed, pointed.tab == tab {
            words(pointed.url)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(HUD.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background {
                    // pillglass: the pill on a plain ground, for the eval of
                    // its cost over a scrolling page (evals/scroll-ram).
                    if LinkGap.cut("pillglass") { RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(Color.black) } else { HUD.plate(Radius.control) }
                }
                .environment(\.colorScheme, .dark)
                .frame(maxWidth: 560, alignment: .leading)
                .padding(8)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    private func words(_ url: URL) -> Text {
        guard let act = LinkStatus.act(status.keys, peekClick: PeekClick.read(in: Store.settings)) else { return Text(LinkStatus.place(url)) }
        return Text("Open ") + Text(LinkStatus.place(url)).fontWeight(.semibold) + Text(" \(act)")
    }
}
