import AppKit
import Combine
import Testing
@testable import Fast

@MainActor
struct SideRowHoverTests {
    @Test func closeKeepsTheRowHoveredAfterItsExit() {
        var hover = SideRow.Hover()
        #expect(!hover.inside)
        hover.row = true
        #expect(hover.inside)
        hover.close = true
        hover.row = false
        #expect(hover.inside)
        // Repeated row exits must not clear the control's own hover.
        hover.row = false
        #expect(hover.inside)
        hover.close = false
        #expect(!hover.inside)
    }

    @Test func enteringTheCloseControlDirectlyHoversTheRow() {
        var hover = SideRow.Hover()
        hover.close = true
        #expect(hover.inside)
        #expect(!hover.row)
        hover.close = false
        #expect(!hover.inside)
    }

    @Test func returningToTheTitleKeepsTheRowHovered() {
        var hover = SideRow.Hover()
        hover.close = true
        hover.row = true
        hover.close = false
        #expect(hover.inside)
        hover.row = false
        #expect(!hover.inside)
    }

    @Test(arguments: [false, true])
    func leavingBothTargetsClearsHover(closeFirst: Bool) {
        var hover = SideRow.Hover()
        hover.row = true
        hover.close = true
        if closeFirst { hover.close = false } else { hover.row = false }
        #expect(hover.inside)
        if closeFirst { hover.row = false } else { hover.close = false }
        #expect(!hover.inside)
    }

    @Test(arguments: [false, true])
    func titleClearanceStaysTheSameOverTheCloseControl(wearsFace: Bool) throws {
        let tab = Tab(bench: true)
        // A local face fixture, independent of live agent sessions.
        if wearsFace { tab.unread = AgentFeed.Unread(session: "sidebar-close-hover-fixture") }
        try #require(tab.wearsFace == wearsFace)
        var hover = SideRow.Hover()
        hover.row = true
        let clear = TabEnd.clear(tab, hovering: hover.inside, slotted: true,
                                 speaker: false, unkeeps: true, pitch: TabEnd.beside)
        #expect(clear == 21 + (wearsFace ? TabEnd.beside : 0))
        hover.close = true
        hover.row = false
        #expect(TabEnd.clear(tab, hovering: hover.inside, slotted: true,
                             speaker: false, unkeeps: true, pitch: TabEnd.beside) == clear)
        hover.row = true
        hover.close = false
        #expect(TabEnd.clear(tab, hovering: hover.inside, slotted: true,
                             speaker: false, unkeeps: true, pitch: TabEnd.beside) == clear)
    }

    /// Rows scrolled out of a long column each say the pointer left them.
    /// For a row the pointer isn't on that says nothing to the glance: no
    /// change published, the hovered tab and its card kept.
    @Test func aRowScrolledAwayLeavesTheHoveredOneAlone() {
        _ = NSApplication.shared
        let id = UUID(), browser = Browser(windowID: id)
        let tabs = (0..<6).map { index in
            let tab = Tab(bench: true)
            tab.restore(url: URL(string: "https://row-\(index).test/")!, title: "Row \(index)")
            browser.prepare(tab)
            return tab
        }
        browser.lay(tabs)
        let glance = browser.glance
        glance.pointerLocation = { nil }
        defer {
            glance.drop()
            glance.pointerLocation = nil
            browser.dozing?.invalidate()
            browser.stuck.timer?.invalidate()
            browser.pressure?.cancel()
            tabs.forEach { $0.close() }
            try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
            Store.settings.removeObject(forKey: "window.\(id.uuidString).space")
        }
        let hovered = tabs[2]
        glance.pretend(hovered.id, true)
        #expect(glance.pointed == hovered.id)
        #expect(glance.shown == hovered.id)

        var published = 0
        let watch = ObservedWrites({ _ = (glance.shown, glance.pointed, glance.shownFolder, glance.agent) }, told: { published += 1 })
        defer { watch.cancel() }
        for tab in tabs where tab.id != hovered.id {
            #expect(!glance.concerns(tab.id))
            glance.hover(tab.id, false)
        }
        // A tab no longer in the window at all, as a recycled row's may be.
        glance.hover(UUID(), false)
        #expect(published == 0)
        #expect(glance.pointed == hovered.id)
        #expect(glance.shown == hovered.id)

        // The hovered row's own leave still lets go of it.
        #expect(glance.concerns(hovered.id))
        glance.hover(hovered.id, false)
        #expect(glance.pointed == nil)
        #expect(!glance.concerns(hovered.id))
    }
}
