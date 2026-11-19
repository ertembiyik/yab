import Foundation
import Observation
import Combine

/// What the menu bar says about the tab in front (Back, Forward, the
/// items a blank tab can't use, Share), kept apart from the tab itself and
/// brought up to date a moment after it changes.
///
/// The menu bar's commands (YabApp) read the tab in front directly, so
/// every navigation, its address and its Back going on and off, ran the
/// whole menu bar's body again and AppKit's main menu was rebuilt, right on
/// the way to the page's first frame (docs/evidence/clean-gap-2026-10-13.md).
/// Now the commands read this, which changes only when what the menu shows
/// does, `delay` after the tab settled. Back and Forward by key don't wait
/// for it: the window's key monitor reads the tab (ContentView).
///
/// Whether a picked tab can be kept and which site's buttons the View menu
/// offers came back into the menu bar read straight off the tabs, their
/// addresses with them: a link's new address ran the whole menu bar's
/// body again in the turn just after the link's start, the turn WebKit's
/// question about the response waits behind (round 11 of
/// docs/evidence/clean-gap-2026-10-13.md; 1-2 ms of that turn's 13-16 on
/// m4). They are read here too (Narrow.menuAddress).
@MainActor
@Observable
final class MenuFront {
    struct Front: Equatable {
        var blank = true
        var dev = false
        var back = false
        var forward = false
        /// The page's address, when it is one to share.
        var share: URL?
        /// Some tab picked can be kept (Tab › Keep Tab).
        var keepable = false
        /// The skill whose buttons Yab puts in this site's rows, if any
        /// (View › Show Buttons on …, SiteButtonsCommand).
        var siteSkill: String?
    }

    /// What the menu shows now.
    private(set) var now = Front()

    @ObservationIgnored private weak var browser: Browser?
    @ObservationIgnored private var due = false

    /// How long after the tab in front changes the menu follows.
    static let delay: TimeInterval = Narrow.menu ? 0.25 : 0

    /// Follows `browser`'s tab in front from now on (once).
    func follow(_ browser: Browser) {
        guard self.browser == nil else { return }
        self.browser = browser
        track()
    }

    private func track() {
        let front = withObservationTracking {
            Self.read(browser)
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.soon() }
        }
        if front != now { now = front }
    }

    private func soon() {
        guard !due else { return }
        due = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay) { [weak self] in
            self?.due = false
            self?.track()
        }
    }

    private static func read(_ browser: Browser?) -> Front {
        guard let browser else { return Front() }
        let keepable = browser.chosen.contains { $0.keepable }
        guard let tab = browser.active else { return Front(keepable: keepable) }
        let url = tab.address
        return Front(blank: url == nil, dev: tab.isDev, back: tab.canGoBack, forward: tab.canGoForward,
                     share: url.flatMap { Bookmark.keepable($0) ? $0 : nil }, keepable: keepable,
                     siteSkill: tab.shy ? nil : SiteItems.shared.skill(for: url))
    }
}

/// History › Recently Visited's places, a moment after the history changes:
/// every page that finished loading recorded a visit, and the menu bar's
/// whole body ran again for it, on the way to the page's frames.
@MainActor
@Observable final class RecentMenu {
    static let shared = RecentMenu(History.shared)
    private static var profiles: [ObjectIdentifier: RecentMenu] = [:]

    static func following(_ history: History) -> RecentMenu {
        if history === History.shared { return shared }
        let key = ObjectIdentifier(history)
        if let kept = profiles[key] { return kept }
        let made = RecentMenu(history)
        profiles[key] = made
        return made
    }

    private(set) var visited: [History.Trace] = []
    @ObservationIgnored private var watch: ObservationLoop?
    @ObservationIgnored private var due = false

    init(_ history: History) {
        visited = history.recent()
        watch = ObservationLoop { [weak self, weak history] in
            guard let self, let history else { return }
            history.followVisits()
            guard !self.due else { return }
            self.due = true
            DispatchQueue.main.asyncAfter(deadline: .now() + MenuFront.delay) { [weak self, weak history] in
                guard let self, let history else { return }
                self.due = false
                let now = history.recent()
                if now.map(\.id) != self.visited.map(\.id) || now.map(\.title) != self.visited.map(\.title) { self.visited = now }
            }
        }
    }
}
