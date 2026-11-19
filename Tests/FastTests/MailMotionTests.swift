import AppKit
import SwiftUI
import Testing
@testable import Fast

// Settings › Mail's Animations (docs/mail.md, Motion): mail holds still
// under the Mac's Reduce Motion or with the switch off, and moves only when
// both let it; the switch is on until turned off, and mail reads it at once.
// Between any list and a thread, only the list name morphs. The letter,
// rows, count and sender switch immediately; other actions keep their motion.
@Suite(.serialized) @MainActor
struct MailMotionTests {
    /// Exercise the actual cached-letter modifier in a hosting view: testing
    /// only MailDesk.motion missed the animation the child added back.
    @Test func cachedLetterContentsStayStillButSteppingAnimates() async throws {
        for move in [MailDesk.Move.cut, .open, .close, .step(1)] {
            let seen = try await renderedLetter(move, parent: Transaction(animation: nil))
            #expect(seen.animated == (move == .step(1)))
        }
    }

    @Test func cutBlocksAnimationsInstalledByChildren() async throws {
        for move in [MailDesk.Move.cut, .open, .close] {
            let seen = try await renderedLetter(move, parent: MailDesk.transaction(1, move), nested: true)
            #expect(seen.blocked)
            #expect(!seen.animated)
        }
    }

    private func renderedLetter(_ move: MailDesk.Move, parent: Transaction, nested: Bool = false) async throws -> (animated: Bool, blocked: Bool) {
        let probe = LetterMotionProbe()
        let host = NSHostingView(rootView: LetterMotionView(probe: probe, move: move, nested: nested).frame(width: 420, height: 80))
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 80)
        let window = NSWindow(contentRect: NSRect(x: -30000, y: 0, width: 420, height: 80), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        _ = host.fittingSize
        for _ in 0..<100 {
            if !probe.seen.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        _ = try #require(probe.seen.last)
        let before = probe.seen.count
        withTransaction(parent) { probe.place = .front }
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if probe.seen.count > before { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(probe.seen.count > before)
        return try #require(probe.seen.last)
    }

    @Test func stillUnderReduceMotionOrAnimationsOff() {
        #expect(!MailDesk.still(reduce: false, animations: true))
        #expect(MailDesk.still(reduce: true, animations: true))
        #expect(MailDesk.still(reduce: false, animations: false))
        #expect(MailDesk.still(reduce: true, animations: false))
    }

    @Test func animationsOnUntilTurnedOff() {
        let settings = Store.settings
        let kept = settings.object(forKey: "mail.motion")
        defer { settings.set(kept, forKey: "mail.motion") }
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        settings.removeObject(forKey: "mail.motion")
        #expect(MailDesk.animations)
        #expect(MailDesk.still == reduce)
        #expect(Preferences().mailAnimations)

        // The switch, as Settings › Mail turns it: mail is still from the next move.
        let prefs = Preferences()
        prefs.mailAnimations = false
        #expect(settings.object(forKey: "mail.motion") as? Bool == false)
        #expect(!MailDesk.animations)
        #expect(MailDesk.still)
        prefs.mailAnimations = true
        #expect(MailDesk.animations)
        #expect(MailDesk.still == reduce)
    }

    @Test func listTitleIsTheOnlyFlyingElement() {
        #expect(MailMorph.letter == ["crumb:name"])
        #expect(MailMorph.row("any-thread") == ["list:title"])
        #expect(MailDesk.opening(flies: true) == .open)
        #expect(MailDesk.opening(flies: false) == .cut)
        #expect(MailDesk.closing(flies: true, thread: true) == .close)
        #expect(MailDesk.closing(flies: false, thread: true) == .cut)
        #expect(MailDesk.closing(flies: false, thread: false) == .plain)

        let settings = Store.settings
        let kept = settings.object(forKey: "mail.motion")
        defer { settings.set(kept, forKey: "mail.motion") }
        settings.set(true, forKey: "mail.motion")
        for move in [MailDesk.Move.cut, .open, .close] {
            #expect(MailDesk.motion(1, move) == nil)
            #expect(MailDesk.transaction(1, move).disablesAnimations)
        }
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            for move in [MailDesk.Move.step(1), .list(1), .compose, .uncompose, .gone, .unsend] {
                #expect(MailDesk.motion(1, move) != nil)
                #expect(!MailDesk.transaction(1, move).disablesAnimations)
            }
        }
    }

}

@MainActor
@Observable private final class LetterMotionProbe {
    var place = MailDesk.Place.after
    @ObservationIgnored var seen: [(animated: Bool, blocked: Bool)] = []
}

private struct LetterMotionView: View {
    var probe: LetterMotionProbe
    let move: MailDesk.Move
    let nested: Bool

    var body: some View {
        LetterTransactionView(probe: probe, place: probe.place)
            .modifier(MailLetterPlace(place: probe.place, move: move, still: false, instant: false))
            .animation(nested ? .smooth : nil, value: probe.place)
    }
}

private struct LetterTransactionView: NSViewRepresentable {
    let probe: LetterMotionProbe
    let place: MailDesk.Place

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        probe.seen.append((context.transaction.animation != nil, context.transaction.disablesAnimations))
    }
}
