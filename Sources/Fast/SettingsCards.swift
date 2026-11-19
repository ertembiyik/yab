import AppKit
import SwiftUI

// Settings' cards and questions stand in a window of their own over the
// Settings window, not inside it: Connect's steps, an extension's long
// list of powers or the snippet editor are taller than Settings is at its
// usual 540, and drawn inside it they were cut off at its foot. The panel
// is a clear column the height of the screen over Settings, the card in it
// at Settings' middle, kept on the screen when taller; Settings under it is
// dimmed (SettingsVeil) and held still until the card goes.

@MainActor
final class SettingsCards {
    static let shared = SettingsCards()

    /// Where the card stands in the panel: Settings' middle, from the
    /// panel's, and how tall the panel is.
    @Observable final class Spot {
        var offset: CGFloat = 0
        var height: CGFloat = 0
    }

    let spot = Spot()
    private var panel: SettingsCardPanel?
    private weak var parent: NSWindow?
    private var watch: ObservationLoop?
    private var shown = false

    /// A card or a question of Settings' own is up.
    var up: Bool { Questions.shared.current?.place == .settings || closer != nil }

    /// Settings on screen, where a question of its own can be seen.
    var showing: Bool { parent?.isVisible == true }

    /// Takes down the card up, a click outside it or the veil's: never a
    /// question, which waits for its answer.
    var closer: (() -> Void)? {
        if SiteEditing.shared.draft != nil { return { SiteEditing.shared.close() } }
        if QuickActionEditing.shared.action != nil { return { QuickActionEditing.shared.close() } }
        if ShieldSourceEditing.shared.draft != nil { return { ShieldSourceEditing.shared.close() } }
        if LinkRouteEditing.shared.draft != nil { return { LinkRouteEditing.shared.close() } }
        if EngineSiteEditing.shared.draft != nil { return { EngineSiteEditing.shared.close() } }
        if RoutineEditing.shared.card != nil { return { RoutineEditing.shared.closeCard() } }
        if #available(macOS 15.4, *), BlockEditing.shared.draft != nil { return { BlockEditing.shared.close() } }
        if AwakeSiteEditing.shared.draft != nil { return { AwakeSiteEditing.shared.close() } }
        if PasswordManagers.Connections.shared.card != nil { return { PasswordManagers.Connections.shared.card = nil } }
        if SnippetEditing.shared.card != nil || SnippetEditing.shared.bring != nil { return { SnippetEditing.shared.close() } }
        return nil
    }

    /// Made with the Settings window, as its child.
    func attach(to window: NSWindow, browser: Browser) {
        parent = window
        let panel = SettingsCardPanel(
            contentRect: window.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.animationBehavior = .none
        let host = NSHostingView(rootView: SettingsCardStack(browser: browser, spot: spot))
        host.sizingOptions = []
        panel.contentView = host
        self.panel = panel
        watch = ObservationLoop { [weak self] in self?.update() }
    }

    /// The column over Settings: Settings' width, the screen's height.
    func place() {
        guard let panel, let parent else { return }
        let screen = (parent.screen ?? NSScreen.main)?.visibleFrame ?? parent.frame
        let frame = NSRect(x: parent.frame.minX, y: screen.minY, width: parent.frame.width, height: screen.height)
        if panel.frame != frame { panel.setFrame(frame, display: shown) }
        let offset = frame.midY - parent.frame.midY
        if spot.offset != offset { spot.offset = offset }
        if spot.height != frame.height { spot.height = frame.height }
    }

    /// Settings back on screen (opened again, out of the Dock): the card
    /// that is up shown over it again, since nothing about the card changed.
    func refresh() { update() }

    private func update() {
        guard let panel, let parent else { return }
        let up = up && parent.isVisible
        guard up != shown else { return }
        shown = up
        if up {
            place()
            parent.addChildWindow(panel, ordered: .above)
            panel.orderFront(nil)
            panel.makeKey()
        } else {
            parent.removeChildWindow(panel)
            panel.orderOut(nil)
            if NSApp.isActive { parent.makeKey() }
        }
    }

    /// Settings going away takes its card with it, and answers its
    /// question no. A card kept is shown again with Settings (refresh).
    func parentClosed() {
        guard let panel else { return }
        shown = false
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        Questions.shared.settingsClosed()
    }

    /// The panel or Settings itself: both answer Settings' questions.
    nonisolated static func owns(_ window: NSWindow?) -> Bool { window is SettingsFrame || window is SettingsCardPanel }
}

/// Takes the keyboard for its fields and Escape, without a title bar.
final class SettingsCardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// ⌘W closes Settings, as it does with no card up.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if Keymap.shared.matches(event, .closeTab), let parent {
            parent.performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Every card Settings asks with, in the panel at Settings' middle. A
/// click beside the card takes it down, as the dimming's did.
private struct SettingsCardStack: View {
    let browser: Browser
    var spot: SettingsCards.Spot
    @State private var tall: CGFloat = 0

    var body: some View {
        // The card's middle at Settings' middle, kept 12 inside the screen.
        let room = max(0, (spot.height - tall) / 2 - 12)
        let offset = min(max(spot.offset, -room), room)
        ZStack {
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture { SettingsCards.shared.closer?() }
            ZStack {
                SettingsQuestionLayer(room: spot.height - 48)
                SiteCardLayer()
                QuickActionCardLayer()
                LinkRouteCardLayer()
                EngineSiteCardLayer()
                ShieldSourceCardLayer()
                RoutineCardLayer(browser: browser)
                if #available(macOS 15.4, *) { BlockCardLayer() }
                AwakeSiteCardLayer()
                PasswordCardLayer()
                SnippetCardLayer()
            }
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { tall = $0 }
            .offset(y: offset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }
}

/// Over Settings while a card is up: dimmed for a card, clear for a
/// question, and taking every click either way.
struct SettingsVeil: View {
    private var questions = Questions.shared
    private var site = SiteEditing.shared
    private var quick = QuickActionEditing.shared
    private var shield = ShieldSourceEditing.shared
    private var link = LinkRouteEditing.shared
    private var engine = EngineSiteEditing.shared
    private var routine = RoutineEditing.shared
    private var awake = AwakeSiteEditing.shared
    private var passwords = PasswordManagers.Connections.shared
    private var snippets = SnippetEditing.shared

    var body: some View {
        let cards = SettingsCards.shared
        ZStack {
            if cards.closer != nil {
                Color.black.opacity(0.12)
                    .contentShape(Rectangle())
                    .onTapGesture { cards.closer?() }
                    .transition(.asymmetric(insertion: .opacity.animation(Motion.arrive), removal: .identity))
            } else if questions.current?.place == .settings {
                Color.clear.contentShape(Rectangle())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
