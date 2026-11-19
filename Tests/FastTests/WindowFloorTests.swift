import AppKit
import SwiftUI
import Testing
@testable import Fast

/// A browser window's least size comes from Yab, on a turn of its own, not
/// from SwiftUI inside a layout pass: SwiftUI reshaping a full-screen
/// window's tile as the screen was unlocked made AppKit throw (crash #96).
@MainActor
@Suite(.serialized)
struct WindowFloorTests {
    final class Heard { var sizes: [CGSize] = [] }

    @Test func swiftUISeesOneLeastSizeWhateverTheContentAsks() {
        let heard = Heard()
        for least in [300.0, 900.0] {
            let host = NSHostingController(rootView: WindowFloorLayout(measured: { heard.sizes.append($0) }) {
                Color.clear.frame(minWidth: least, minHeight: 500)
            })
            #expect(host.sizeThatFits(in: .zero) == CGSize(width: Browser.narrowestWindow, height: Browser.leastHeight))
        }
        // What the content asks is heard, for Yab to give the window.
        #expect(heard.sizes.contains(CGSize(width: 300, height: 500)))
        #expect(heard.sizes.contains(CGSize(width: 900, height: 500)))
        // The root it replaces showed SwiftUI the pair's floor, so a pair
        // made in full screen had SwiftUI reshape the window's tile.
        let old = [Browser.narrowestWindow, 900].map { floor in
            NSHostingController(rootView: Color.clear.frame(minWidth: floor, minHeight: Browser.leastHeight)).sizeThatFits(in: .zero)
        }
        #expect(old[0] != old[1])
    }

    /// Crash #510: a layout pass off the main thread reached `measured`, and
    /// `assumeIsolated` trapped. The measurement now arrives on the main
    /// queue, whichever thread said it.
    @Test func aMeasurementFromAnotherThreadIsHeardOnTheMainThread() async {
        let size = CGSize(width: 321, height: 123)
        let heard = await withCheckedContinuation { (done: CheckedContinuation<(CGSize, Bool), Never>) in
            DispatchQueue.global().async {
                WindowFloorLayout.onMain { done.resume(returning: (size, Thread.isMainThread)) }
            }
        }
        #expect(heard.0 == size)
        #expect(heard.1)
        // A main-thread layout must finish before observable state changes.
        var ran = false
        WindowFloorLayout.onMain { ran = true }
        #expect(!ran)
        await withCheckedContinuation { done in
            DispatchQueue.main.async { done.resume() }
        }
        #expect(ran)
    }

    @Test func contentIsLaidAtTheWindowsSize() {
        let host = NSHostingController(rootView: WindowFloorLayout(measured: { _ in }) {
            Color.clear.frame(minWidth: 300, maxWidth: .infinity, minHeight: 200, maxHeight: .infinity)
        })
        #expect(host.sizeThatFits(in: CGSize(width: 1200, height: 800)) == CGSize(width: 1200, height: 800))
    }

    /// A window held at its size whatever is asked, as a tile is: each
    /// frame asked of it is taken and then put back, the first `holds`
    /// times, so a loop of asks ends where AppKit would have thrown.
    final class HeldWindow: NSWindow {
        var held: NSRect?
        var holds = 5
        var asked = 0

        override func setFrame(_ frameRect: NSRect, display flag: Bool) {
            super.setFrame(frameRect, display: flag)
            guard let held, frameRect.size != held.size else { return }
            asked += 1
            if asked <= holds { super.setFrame(held, display: flag) }
        }
    }

    @Observable final class Grows { var big = false }

    struct Rows: View {
        var grows: Grows
        let floor: Bool
        var body: some View {
            let rows = ScrollView { VStack { ForEach(0..<30) { Text("Row \($0)") } } }
                .frame(minWidth: grows.big ? 700 : 300, idealWidth: grows.big ? 900 : 400,
                       minHeight: grows.big ? 500 : 200, idealHeight: grows.big ? 700 : 300)
            if floor { AnyView(WindowFloorLayout(measured: { _ in }) { rows }) } else { AnyView(rows) }
        }
    }

    /// How many sizes SwiftUI asks of a window held at 500 by 380, its root
    /// a scroll view (crash #112's window), while its content's size
    /// changes in an animation.
    func asks(floor: Bool, _ host: (Rows) -> NSView) async -> Int {
        let grows = Grows()
        let window = HeldWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 380),
                                styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.held = window.frame
        window.contentView = host(Rows(grows: grows, floor: floor))
        if let screen = TestScreen.screen {
            window.setFrameOrigin(NSPoint(x: screen.visibleFrame.minX + 20, y: screen.visibleFrame.minY + 20))
            window.held = window.frame
            window.orderFront(nil)
        }
        try? await Task.sleep(for: .milliseconds(300))
        withAnimation(.linear(duration: 0.2)) { grows.big = true }
        try? await Task.sleep(for: .milliseconds(600))
        window.close()
        return window.asked
    }

    @Test func swiftUILeavesAHeldWindowsSizeAlone() async {
        // NSHostingView's own sizing options: after each layout of the
        // window it puts the window back inside the content's least size,
        // the window goes back, and it asks again, pass after pass.
        #expect(await asks(floor: false) { NSHostingView(rootView: $0) } > 5)
        // Under the browser's root it still asks a window held under 640
        // by 420 for that size.
        #expect(await asks(floor: true) { NSHostingView(rootView: $0) } > 0)
        // The browser window's host asks nothing, whatever its content.
        #expect(await asks(floor: false) { WindowFloorLayout.host($0) } == 0)
        #expect(await asks(floor: true) { WindowFloorLayout.host($0) } == 0)
    }

    @Test func leastWindowTakesTheLargestAsk() {
        #expect(Browser.leastWindow(floor: 640, content: .zero) == CGSize(width: 640, height: 420))
        #expect(Browser.leastWindow(floor: 800, content: CGSize(width: 700, height: 300)) == CGSize(width: 800, height: 420))
        #expect(Browser.leastWindow(floor: 640, content: CGSize(width: 900.2, height: 512.5)) == CGSize(width: 901, height: 513))
    }

    enum Root: CaseIterable {
        case scene, normal, blank, privateWindow
    }

    /// These use the production root paths, including WindowSetup for the
    /// scene which never calls WindowFloorLayout.host. The growing scroll
    /// view is deliberately larger than the frame restored after fullscreen.
    @Test(arguments: Root.allCases)
    func animatedContentCannotResizeAFullscreenTransition(root: Root) async throws {
        let screen = try #require(TestScreen.screen)
        let grows = Grows()
        let rows = Rows(grows: grows, floor: true)
        let content = AnyView(rows.background(WindowSetup { _ in }))
        let host: NSHostingView<AnyView>
        if root == .scene {
            host = NSHostingView(rootView: content)
        } else {
            // Normal, Blank and Private all use BrowserWindows.open's host.
            host = WindowFloorLayout.host(content)
        }
        let window = HeldWindow(contentRect: NSRect(x: screen.visibleFrame.minX + 20,
                                                    y: screen.visibleFrame.minY + 20,
                                                    width: 760, height: 540),
                                styleMask: [.titled, .resizable, .fullSizeContentView],
                                backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(200))
        #expect(host.sizingOptions.isEmpty)
        let least = NSSize(width: Browser.narrowestWindow, height: Browser.leastHeight)
        window.contentMinSize = least
        let ordinary = window.frame
        // Native fullscreen's entry and exit change the frame while SwiftUI
        // content is animating. Hold each target just as the OS transition
        // does, without moving the test runner to a different Space.
        for (frame, big) in [(screen.frame, true), (ordinary, false)] {
            window.held = nil
            window.setFrame(frame, display: true)
            // A normal titled test window may be constrained to the screen's
            // visible frame. Freeze the rectangle AppKit actually accepted.
            let accepted = window.frame
            window.held = accepted
            window.asked = 0
            withAnimation(.linear(duration: 0.2)) { grows.big = big }
            try await Task.sleep(for: .milliseconds(400))
            window.layoutIfNeeded()
            #expect(window.asked == 0)
            #expect(window.frame == accepted)
            #expect(window.contentMinSize == least)
        }
    }

    @Test func browserHostHasNoSizingAuthorityEvenWithoutAnimation() {
        #expect(WindowFloorLayout.host(Color.clear).sizingOptions.isEmpty)
    }

    final class FullscreenWindow: NSWindow {
        var entries = 0
        override func toggleFullScreen(_ sender: Any?) { entries += 1 }
    }

    @Test func savedFullscreenStillRestoresOnceAfterHostingSetup() async throws {
        let screen = try #require(TestScreen.screen)
        let suite = "WindowFloorTests.\(UUID().uuidString)"
        let settings = try #require(UserDefaults(suiteName: suite))
        defer { settings.removePersistentDomain(forName: suite) }
        let id = UUID()
        let key = "window.\(id.uuidString).fullscreen"
        settings.set(true, forKey: key)
        let window = FullscreenWindow(contentRect: NSRect(x: screen.visibleFrame.minX + 20,
                                                         y: screen.visibleFrame.minY + 20,
                                                         width: 760, height: 540),
                                      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: Color.clear.background(WindowSetup { _ in }))
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        let state = WindowFullscreen(window, id: id, settings: settings)
        try await Task.sleep(for: .milliseconds(200))
        #expect(host.sizingOptions.isEmpty)
        #expect(window.entries == 1)
        #expect(settings.bool(forKey: key))
        state.prepareToQuit()
        #expect(settings.bool(forKey: key))
    }
}
