import SwiftUI

// An agent's hand in mail (docs/mail.md, Motion): when an agent's mail_act
// takes a row out of the list in front, a soft ring comes to the row's end,
// presses, and only then does the row go, as E takes it. It is a picture of
// what the agent did, not a pointer: the agent works through mail_act as
// ever, and nothing here waits for it. Only with mail on screen and the list
// in front; held still (Reduce Motion, Animations off), rows go as before.

/// Where the hand is and what it is about to do.
@MainActor
@Observable final class MailHand {
    static let shared = MailHand()

    /// Its middle in the list's content (MailMorph.list); nil before it came.
    private(set) var at: CGPoint?
    private(set) var pressed = false
    private(set) var shown = false
    /// Threads an agent acted on, by row id, and when: rows going within a
    /// few seconds of it are the agent's.
    @ObservationIgnored private var touched: [String: Date] = [:]
    /// The rows' going, held for the press.
    @ObservationIgnored private var pending: (() -> Void)?
    @ObservationIgnored private var turn = 0

    /// How long after mail_act a row going is taken for the agent's.
    static let window: TimeInterval = 4
    /// From where it is to the row, then the press.
    static let travel: Double = 0.40
    static let press: Double = 0.10
    /// Seen after its last press, for the next act to find it still there.
    static let linger: Double = 0.5

    /// mail_act on a thread: its row, should it go, is the agent's.
    func touch(_ id: String, now: Date = Date()) {
        touched = touched.filter { now.timeIntervalSince($0.value) < MailHand.window }
        touched[id] = now
    }

    /// Whether these rows going are the agent's doing.
    func leads(_ ids: [String], now: Date = Date()) -> Bool {
        !ids.isEmpty && ids.allSatisfy { touched[$0].map { now.timeIntervalSince($0) < MailHand.window } ?? false }
    }

    /// To `point`, a press, then `then` (the rows going); a press still to
    /// come does what it held at once first.
    func press(at point: CGPoint, then: @escaping () -> Void) {
        flush()
        turn += 1
        let now = turn
        pending = then
        let pace = MailMorph.pace
        if !shown || at == nil {
            // In from under the row, where the field's pill stands below the list.
            var quiet = Transaction()
            quiet.disablesAnimations = true
            withTransaction(quiet) { at = CGPoint(x: point.x, y: point.y + 56) }
            withAnimation(.easeOut(duration: 0.15 * pace)) { shown = true }
        }
        DispatchQueue.main.async { [self] in
            guard turn == now else { return }
            withAnimation(.smooth(duration: MailHand.travel * pace)) { at = point }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + MailHand.travel * pace) { [self] in
            guard turn == now else { return }
            withAnimation(.easeOut(duration: MailHand.press * 0.8 * pace)) { pressed = true }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (MailHand.travel + MailHand.press) * pace) { [self] in
            guard turn == now else { return }
            withAnimation(MailMorph.spring(MailMorph.quick)) { pressed = false }
            flush()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (MailHand.travel + MailHand.press + MailHand.linger) * pace) { [self] in
            guard turn == now else { return }
            withAnimation(.easeIn(duration: 0.2 * pace)) { shown = false }
        }
    }

    /// What a press held, done now: a key, another load or a screen change
    /// never waits for the hand.
    func flush() {
        guard let held = pending else { return }
        pending = nil
        held()
    }

    /// Gone at once: the list left, or mail held still.
    func away() {
        flush()
        turn += 1
        if shown || pressed {
            var quiet = Transaction()
            quiet.disablesAnimations = true
            withTransaction(quiet) {
                shown = false
                pressed = false
            }
        }
    }
}

/// The hand over the list's rows, in their own coordinates.
struct MailHandView: View {
    private var hand = MailHand.shared

    var body: some View {
        if let at = hand.at {
            Circle()
                .fill(.ultraThinMaterial)
                .overlay(Circle().fill(Palette.ink.opacity(0.08)))
                .overlay(Circle().strokeBorder(Palette.ink.opacity(0.14), lineWidth: 1))
                .frame(width: 28, height: 28)
                .scaleEffect(hand.pressed ? 0.86 : 1)
                .position(at)
                .opacity(hand.shown ? 1 : 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
