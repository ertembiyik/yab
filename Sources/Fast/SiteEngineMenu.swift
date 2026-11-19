import SwiftUI

/// "Opens in" for Site Controls (mockup B, picked 2026-10-27): the choice lives
/// in the foot's "..." menu, and the panel gets a row in "This site" only
/// while the page's engine differs from what the window would use.
@MainActor
extension Tab {
    /// Whether the panel offers the choice at all: the build runs Chromium
    /// pages and this is an HTTP(S) page.
    var offersSiteEngine: Bool {
        engineFactory.kinds.contains(.chromium) && SiteEngineSettings.host(address) != nil
    }

    /// What Auto means here: a built-in rule's engine (protected video,
    /// Apple Pay, the Chrome Web Store), otherwise the window's own engine.
    var recommendedSiteEngine: PageEngineKind {
        engineFactory.sites.builtIn(for: address)?.kind ?? (chromiumDRMEnabled ? .chromium : .webKit)
    }

    /// The engine the page is in, or the one a sleeping tab will wake into.
    var effectiveSiteEngine: PageEngineKind {
        builtPage?.engine ?? engineFactory.resolved(engineKind, at: address)
    }

    /// The engine the persisted choice asks for.
    var chosenSiteEngine: PageEngineKind {
        switch siteEngineChoice {
        case .recommended: recommendedSiteEngine
        case .chromium: .chromium
        case .webKit: .webKit
        }
    }

    private func wanted(_ choice: SiteEngineChoice) -> PageEngineKind {
        switch choice {
        case .recommended: recommendedSiteEngine
        case .chromium: .chromium
        case .webKit: .webKit
        }
    }

    /// Picks the engine for this host and reloads the page in it, in this tab.
    /// `then` runs when the choice has landed (or was refused).
    func chooseSiteEngine(_ choice: SiteEngineChoice, then: @escaping () -> Void = {}) {
        // Recommended again on a tab Yab moved (protected video) is not a no-op:
        // it goes back to the window's engine and tries it afresh.
        guard offersSiteEngine, choice != siteEngineChoice || effectiveSiteEngine != chosenSiteEngine else { return then() }
        Task { @MainActor [weak self] in
            do { try await self?.setSiteEngineChoice(choice) }
            catch { self?.engineSwitchFailed(error, to: self?.wanted(choice) ?? .webKit) }
            then()
        }
    }
}

enum SiteEngineWords {
    static func name(_ kind: PageEngineKind) -> String { kind == .chromium ? "Chromium" : "WebKit" }
}

/// The three choices, the persisted one checked.
struct OpensInChoices: View {
    var tab: Tab
    var done: () -> Void = {}

    var body: some View {
        let current = tab.siteEngineChoice
        choice("Auto (\(SiteEngineWords.name(tab.recommendedSiteEngine)))", .recommended, current)
        Divider()
        choice("Chromium", .chromium, current)
        choice("WebKit", .webKit, current)
    }

    private func choice(_ title: String, _ value: SiteEngineChoice, _ current: SiteEngineChoice) -> some View {
        Toggle(title, isOn: Binding(get: { current == value }, set: { _ in
            tab.chooseSiteEngine(value, then: done)
        }))
    }
}

/// "Opens in ›" in the foot menu.
struct OpensInMenu: View {
    var tab: Tab
    var done: () -> Void = {}

    var body: some View {
        Menu("Opens in", mark: "square.2.layers.3d") { OpensInChoices(tab: tab, done: done) }
    }
}

/// What the panel's "Opens in" row says, when it has anything to say.
struct SiteEngineRowFacts: Equatable {
    let kind: PageEngineKind
    let said: String
    /// A choice made here (a cross goes back to Auto), not a move Yab made.
    let chosen: Bool
    var title: String { "Opens in \(SiteEngineWords.name(kind))" }
}

@MainActor
extension Tab {
    var siteEngineRowFacts: SiteEngineRowFacts? {
        guard offersSiteEngine else { return nil }
        if siteEngineChoice != .recommended {
            guard chosenSiteEngine != recommendedSiteEngine else { return nil }
            return SiteEngineRowFacts(kind: chosenSiteEngine, said: "Chosen for \(IDN.shown(SiteFacts(tab: self).site))", chosen: true)
        }
        guard effectiveSiteEngine != recommendedSiteEngine else { return nil }
        // Only a move Yab made says why: a built-in rule, or this site's
        // player refusing Chromium. Any other difference (⌘K's Open in, a
        // window a WebKit page opened) is no protected video (#1605).
        let reason = engineDecision.reason
            ?? (effectiveSiteEngine == .webKit && protectsVideo(at: address) ? EngineBuiltInRule.protectedVideo : nil)
        guard let reason else { return nil }
        return SiteEngineRowFacts(kind: effectiveSiteEngine, said: reason == EngineBuiltInRule.protectedVideo ? "For its protected video" : reason,
                                  chosen: false)
    }
}

extension SiteControlsView {
    /// The row in "This site": the exception, or the move Yab made.
    func opensInRow(done: @escaping () -> Void) -> Setting? {
        guard let facts = tab.siteEngineRowFacts else { return nil }
        if facts.chosen {
            return Setting(symbol: "square.2.layers.3d", title: facts.title, said: facts.said, on: true,
                           end: AnyView(Small(symbol: "xmark") { [tab] in
                               tab.chooseSiteEngine(.recommended, then: done)
                           }.keyTip("Back to Auto")))
        }
        return Setting(symbol: "square.2.layers.3d", title: facts.title, said: facts.said,
                       end: AnyView(Symbol("chevron.up.chevron.down", size: 10, weight: .medium)
                           .foregroundStyle(Palette.muted)
                           .frame(width: 24, height: 24)),
                       menu: AnyView(OpensInChoices(tab: tab, done: done)))
    }
}
