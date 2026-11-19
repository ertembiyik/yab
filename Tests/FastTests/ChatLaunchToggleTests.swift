import AppKit
import SwiftUI
import Testing
@testable import Fast

/// Start with an unmeasured room, as after relaunch. Check the native
/// frames, not just chatOpen or a separately constructed layout value.
@MainActor
@Suite(.serialized)
struct ChatLaunchToggleTests {
    private struct Page: NSViewRepresentable {
        let view: NSView
        func makeNSView(context: Context) -> NSView { view }
        func updateNSView(_ view: NSView, context: Context) {}
        func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
            proposal.replacingUnspecifiedDimensions()
        }
    }

    private struct Room: View {
        var browser: Browser
        let page: NSView
        var body: some View {
            ChatRoom(open: browser.chatOpen, rim: .init(card: true), width: 380, leading: browser.chatLeads) {
                Page(view: page)
                if browser.chatOpen || browser.chatMoving {
                    ChatColumnHost(browser: browser, shown: browser.chatOpen, corner: 12, width: 380, leading: browser.chatLeads)
                }
            }
        }
    }

    @MainActor
    private final class Fixture {
        let browser = Browser(windowID: UUID())
        let page = NSView()
        let host: NSHostingView<Room>
        let window: NSWindow
        let oldSide: (Bool, Bool, Flank)

        init(flank: Flank) {
            _ = NSApplication.shared
            oldSide = (browser.prefs.sidebar, browser.prefs.sideShut, browser.prefs.sideFlank)
            browser.prefs.sidebar = true
            browser.prefs.sideShut = false
            browser.prefs.sideFlank = flank
            host = NSHostingView(rootView: Room(browser: browser, page: page))
            window = NSWindow(contentRect: .init(x: -8000, y: -8000, width: 1000, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            // Deliberately attach only after the first requests.
        }

        func layout() {
            if window.contentView !== host { window.contentView = host }
            window.layoutIfNeeded()
            host.layoutSubtreeIfNeeded()
        }

        func settle() async throws {
            for _ in 0..<300 {
                layout()
                if !browser.chatMoving { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            Issue.record("launch-time chat transition did not finish")
        }

        func check(open: Bool, frame: NSRect, sidebar: CGFloat) throws {
            layout()
            #expect(browser.chatOpen == open)
            #expect(!browser.chatMoving)
            #expect(window.frame == frame)
            #expect(browser.sideShown == sidebar)
            let rect = page.convert(page.bounds, to: host)
            let room = open ? ChatRoom.room(.init(card: true), width: 380) : 0
            #expect(abs(rect.width - (host.bounds.width - room)) < 0.5,
                    "native page must reserve exactly the current column's room")
            #expect(abs(rect.minX - (open && browser.chatLeads ? room : 0)) < 0.5)
            if open {
                let column = try #require(browser.chatColumnView)
                let columnRect = column.convert(column.bounds, to: host)
                #expect(rect.intersection(columnRect).width < 0.5, "chat must stand beside the page")
                #expect(column.shown)
            }
        }

        func close() {
            browser.dozing?.invalidate()
            browser.stuck.timer?.invalidate()
            browser.pressure?.cancel()
            browser.prefs.sidebar = oldSide.0
            browser.prefs.sideShut = oldSide.1
            browser.prefs.sideFlank = oldSide.2
            window.contentView = nil
            window.close()
            browser.letGo()
        }
    }

    @Test(arguments: [false, true])
    func connectedAgentKeepsTheColumnBeforeDiscoveryFinishes(ready: Bool) async throws {
        try #require(Store.testing)
        let fixture = Fixture(flank: .left)
        let browser = fixture.browser
        let oldAgent = Agents.shared.browser
        let oldReady = Agents.assumedInTests, oldConnected = Agents.connectedInTests
        let oldPlace = browser.prefs.askOpens
        let line = TaskLine()
        defer {
            line.close()
            Agents.shared.browser = oldAgent
            Agents.assumedInTests = oldReady
            Agents.connectedInTests = oldConnected
            browser.prefs.askOpens = oldPlace
            fixture.close()
        }
        Agents.shared.browser = browser
        Agents.assumedInTests = ready
        Agents.connectedInTests = true
        browser.prefs.askOpens = .chat
        let tab = Tab(bench: true)
        tab.restore(url: URL(string: "https://launch.example.test/")!, title: "Restored page")
        browser.lay([tab])
        browser.activeID = tab.id
        let frame = fixture.window.frame, sidebar = browser.sideShown
        // Five Command-J routes before the first layout or discovery.
        // Use the real close decision, including its pending movement.
        line.open(on: tab)
        for _ in 0..<4 {
            if browser.askClosesChat { browser.hideChat() }
            else { line.open(on: tab) }
        }
        #expect(line.tab == nil, "the saved column choice must not become an overlay while discovery is pending")
        #expect(browser.chatMovement.target == true)
        try await fixture.settle()
        try fixture.check(open: true, frame: frame, sidebar: sidebar)
        browser.hideChat()
        try await fixture.settle()
        try fixture.check(open: false, frame: frame, sidebar: sidebar)
    }

    @Test(arguments: [Flank.left, .right])
    func rapidTogglesBeforeFirstLayoutAndDuringArrival(_ flank: Flank) async throws {
        try #require(Store.testing)
        // Show Chat opens the column only with an agent or a chat to go back
        // to (AIUse.chats, since 4802102d1). Without this the test passed
        // only when an earlier suite had left a chat behind.
        let oldReady = Agents.assumedInTests
        Agents.assumedInTests = true
        let fixture = Fixture(flank: flank)
        defer {
            fixture.close()
            Agents.assumedInTests = oldReady
        }
        let browser = fixture.browser, frame = fixture.window.frame, sidebar = fixture.browser.sideShown
        // Five presses before the native column has ever been measured.
        for _ in 0..<5 { browser.toggleChat() }
        try await fixture.settle()
        try fixture.check(open: true, frame: frame, sidebar: sidebar)
        browser.toggleChat()
        try await fixture.settle()
        try fixture.check(open: false, frame: frame, sidebar: sidebar)

        // Reverse after the opening model write, then cancel that close
        // before its next frame. The original arrival has not landed yet.
        browser.toggleChat()
        for _ in 0..<300 {
            if browser.chatOpen { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(browser.chatOpen && browser.chatMoving)
        browser.toggleChat()
        browser.toggleChat()
        try await fixture.settle()
        try fixture.check(open: true, frame: frame, sidebar: sidebar)
        for _ in 0..<5 { browser.toggleChat() }
        try await fixture.settle()
        try fixture.check(open: false, frame: frame, sidebar: sidebar)
    }
}
