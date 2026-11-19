import AppKit
import CoreGraphics
import SwiftUI

/// A card beside a helper's window, vertically only. Core Graphics exposes
/// window bounds and owner PID without Screen Recording; no titles, pixels,
/// Accessibility access or authentication codes are read here.
@MainActor
final class QuestionAnchor {
    var processIdentifier: Int32?
    private(set) var panel: QuestionAnchorPanel?
    private weak var parent: NSWindow?
    private weak var questions: Questions?
    private var host: NSHostingView<QuestionAnchorCard>?
    private var timer: Timer?
    private var lastAnchor: CGRect?
    private var side: QuestionAnchorLayout.Side?
    private let layout = QuestionAnchorRoom()
    private var started = Date()
    private var activated = false
    private let readWindows: () -> [[String: Any]]?

    init(processIdentifier: Int32?, readWindows: @escaping () -> [[String: Any]]? = {
        CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    }) {
        self.processIdentifier = processIdentifier
        self.readWindows = readWindows
    }

    func owns(_ window: NSWindow?) -> Bool { window != nil && window === panel }

    func show(_ question: Question, questions: Questions) {
        dismiss()
        self.questions = questions
        parent = question.window.flatMap { NSApp.window(withWindowNumber: $0) }
        let panel = QuestionAnchorPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                        backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.level = .floating
        panel.animationBehavior = .none
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.appearance = parent?.appearance
        let host = NSHostingView(rootView: QuestionAnchorCard(question: question, questions: questions, room: layout))
        self.panel = panel
        self.host = host
        panel.contentView = WindowHosting.measured(host)
        started = Date()
        activated = false
        refresh()
        let timer = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func dismiss() {
        timer?.invalidate()
        timer = nil
        guard let panel else { return }
        let returnFocus = panel.isKeyWindow
        questions?.shownIn.remove(panel.windowNumber)
        panel.orderOut(nil)
        panel.contentView = nil
        panel.close()
        self.panel = nil
        host = nil
        lastAnchor = nil
        side = nil
        if returnFocus, NSApp.isActive, parent?.isVisible == true { parent?.makeKey() }
    }

    private func refresh() {
        guard let panel, let host else { return }
        guard !NSApp.isHidden else {
            panel.orderOut(nil)
            questions?.shownIn.remove(panel.windowNumber)
            return
        }
        let screens = NSScreen.screens
        let desktopTop = screens.first?.frame.maxY ?? 0
        if let pid = processIdentifier,
           let info = readWindows(),
           let frame = QuestionAnchorLayout.helperFrame(in: info, processIdentifier: pid, desktopTop: desktopTop) {
            lastAnchor = frame
        }
        let fallback = parent?.frame ?? NSScreen.main?.visibleFrame ?? .zero
        let reference = lastAnchor ?? fallback
        guard let screen = screens.max(by: {
            QuestionAnchorLayout.area($0.frame.intersection(reference)) < QuestionAnchorLayout.area($1.frame.intersection(reference))
        }) else { return }
        let visible = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        // Give the helper a moment to order its window. If metadata is
        // unavailable, keep the code field usable at the screen's foot.
        guard lastAnchor != nil || Date().timeIntervalSince(started) >= 1 else { return }
        let anchor = lastAnchor ?? CGRect(x: reference.midX, y: visible.minY - QuestionAnchorLayout.gap, width: 0, height: 0)
        let available = QuestionAnchorLayout.availableHeight(anchor: anchor, screen: visible)
        let room = max(1, available)
        if layout.height != room { layout.height = room }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let card = CGSize(width: size.width - 24, height: size.height - 24)
        guard card.width > 0, card.height > 0,
              let placement = QuestionAnchorLayout.place(size: card, anchor: anchor, screen: visible, preferred: side)
        else {
            // Never put an oversized card over the code while its content
            // relayouts (for example, when a wrong-code message appears).
            panel.orderOut(nil)
            questions?.shownIn.remove(panel.windowNumber)
            return
        }
        side = placement.side
        let frame = placement.frame.insetBy(dx: -12, dy: -12)
        if panel.frame != frame { panel.setFrame(frame, display: panel.isVisible) }
        if !panel.isVisible {
            panel.prepareFirstResponder()
            panel.orderFront(nil)
            // The helper is the active app while its code is up, so a key
            // panel alone gets no keys: bring Yab forward once, and the code
            // field takes typing without a click.
            if !activated {
                activated = true
                if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
            }
            panel.makeKey()
            questions?.shownIn.insert(panel.windowNumber)
        }
    }
}

final class QuestionAnchorPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// The card's field is the view AppKit makes first responder as the
    /// panel first goes on screen (`-[NSWindow _setUpFirstResponder]`, from
    /// ordering it in), its `initialFirstResponder`; SwiftUI's half is the
    /// strip's `defaultFocus` (ApplePasswordsPairing.CodeStrip). Left to
    /// them, both took the first item of the key loop, which with keyboard
    /// navigation on is the Not Now button, so the code typed went nowhere
    /// until a click on the strip (R2564). A panel keeps its first
    /// responder each time it becomes key again, as when Yab comes back to
    /// the front.
    func prepareFirstResponder() {
        guard initialFirstResponder == nil, let content = contentView else { return }
        initialFirstResponder = Self.field(in: content)
    }

    static func field(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable, !field.isHiddenOrHasHiddenAncestor { return field }
        for child in view.subviews {
            if let field = field(in: child) { return field }
        }
        return nil
    }
}

@MainActor
@Observable private final class QuestionAnchorRoom {
    var height: CGFloat = 1000
}

private struct QuestionAnchorCard: View {
    let question: Question
    let questions: Questions
    var room: QuestionAnchorRoom

    var body: some View {
        QuestionCard(questions: questions, question: question, room: room.height)
            .fixedSize()
            .padding(12) // The card's own shadow; not a second surface.
    }
}

/// AppKit coordinates, including displays above/below or left of the main
/// display. Pure geometry so edge cases do not need an Apple Account.
enum QuestionAnchorLayout {
    enum Side: Equatable { case above, below }
    struct Placement {
        let frame: CGRect
        let side: Side
    }
    static let gap: CGFloat = 16

    static func area(_ frame: CGRect) -> CGFloat {
        frame.isNull ? 0 : max(0, frame.width) * max(0, frame.height)
    }

    static func helperFrame(in windows: [[String: Any]], processIdentifier: Int32, desktopTop: CGFloat) -> CGRect? {
        guard processIdentifier > 0 else { return nil }
        // WindowServer lists front to back. Only this Yab-owned helper,
        // not another browser's pairing window or a private window title.
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processIdentifier,
                  ((window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.width >= 100, frame.height >= 60,
                  frame.origin.x.isFinite, frame.origin.y.isFinite,
                  frame.width.isFinite, frame.height.isFinite
            else { continue }
            return CGRect(x: frame.minX, y: desktopTop - frame.maxY, width: frame.width, height: frame.height)
        }
        return nil
    }

    static func availableHeight(anchor: CGRect, screen: CGRect) -> CGFloat {
        max(0, max(anchor.minY - screen.minY - gap, screen.maxY - anchor.maxY - gap))
    }

    static func place(size: CGSize, anchor: CGRect, screen: CGRect, preferred: Side? = nil) -> Placement? {
        guard size.width > 0, size.height > 0, size.width <= screen.width, size.height <= screen.height else { return nil }
        let x = min(max(anchor.midX - size.width / 2, screen.minX), screen.maxX - size.width)
        let order: [Side] = preferred == .above ? [.above, .below] : [.below, .above]
        for side in order {
            let y = side == .below ? anchor.minY - gap - size.height : anchor.maxY + gap
            let frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
            if screen.contains(frame), !frame.intersects(anchor) { return Placement(frame: frame, side: side) }
        }
        return nil
    }
}
