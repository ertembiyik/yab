import AppKit
import SwiftUI
import Testing
@testable import Fast

/// A tab's right-click menu holds still while its row redraws
/// (SteadyMenu.swift): open, with the row drawn again and again under it,
/// every line stays the line it was, so Edit Kept Page's submenu, open under
/// the pointer, isn't dropped and brought back (alpha report, Slumdog8).
@MainActor
@Suite(.serialized)
struct SteadyMenuTests {
    @Observable final class Ticker { var n = 0 }

    /// A row that redraws with each tick, as a busy page's row does.
    struct Row: View {
        var ticker: Ticker
        let browser: Browser
        let tab: Fast.Tab
        var body: some View {
            Text("Performance \(ticker.n)").frame(width: 200, height: 40).background(Color.gray)
                .steadyMenu { TabMenu(browser: browser, tab: tab, close: {}) }
        }
    }

    private func world(_ body: (Browser) throws -> Void) rethrows {
        let id = UUID(), browser = Browser(windowID: id)
        defer {
            browser.dozing?.invalidate()
            browser.stuck.timer?.invalidate()
            browser.pressure?.cancel()
            for tab in browser.tabs + browser.parkedTabs { tab.close() }
            try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
            Store.settings.removeObject(forKey: "window.\(id.uuidString).space")
        }
        try body(browser)
    }

    private static func spot(in view: NSView) -> SteadyMenuView? {
        if let spot = view as? SteadyMenuView { return spot }
        for sub in view.subviews { if let spot = spot(in: sub) { return spot } }
        return nil
    }

    private static func lines(_ menu: NSMenu) -> [String: ObjectIdentifier] {
        Dictionary(menu.items.filter { !$0.isSeparatorItem }.map { ($0.title, ObjectIdentifier($0)) }, uniquingKeysWith: { a, _ in a })
    }

    /// Build the same native tree as a right-click, without opening it or
    /// invoking a command. Both ordinary and pinned pairs have the same
    /// group-first menu; Option and search keep the same Separate item.
    @Test(arguments: [false, true])
    func pinPairLeadsASplitTabsActualMenu(pinned: Bool) throws {
        try world { browser in
            let left = Fast.Tab(), right = Fast.Tab()
            for tab in [left, right] { browser.prepare(tab) }
            left.restore(url: URL(string: "https://left.test/")!, title: "Left")
            right.restore(url: URL(string: "https://right.test/")!, title: "Right")
            if pinned { left.pin = "L"; right.pin = "R" }
            browser.lay([left, right])
            browser.activeID = left.id
            browser.splitBook.place = CGRect(x: 0, y: 0, width: 1400, height: 900)
            browser.pairs = [Pair(first: left.id, second: right.id)]

            let menu = NSHostingMenu(rootView: TabMenu(browser: browser, tab: left, close: {}))
            let list = ActionMenuList(menu: menu, falls: true)
            let pinTitle = pinned ? "Unpin Pair" : "Pin Pair"
            #expect(list.lines.first?.title == pinTitle)
            #expect(list.lines.filter { $0.title == "Separate All Tabs" }.count == 1)
            let separate = try #require(list.lines.first { $0.title == "Separate All Tabs" })
            let item = try #require(separate.menu.item(at: separate.index))
            #expect(item.isEnabled)
            #expect(item.image === MenuMark.image("yab.split.slash"))
            #expect(item.keyEquivalent.isEmpty)
            #expect(!list.lines.contains { $0.title == "Pin" || $0.title == "Unpin" })
            #expect(list.lines.contains { $0.title == "Move to" })
            #expect(!list.lines.contains { $0.title == "Open as Split" })
            list.modifiers(.option)
            #expect(list.lines.first?.title == pinTitle)
            list.query = "Separate"
            let found = try #require(list.lines.first { $0.title == "Separate All Tabs" })
            #expect(found.menu.item(at: found.index) === item)
        }
    }

    @Test func anUnsplitTabsActualMenuKeepsItsExistingFirstAction() throws {
        try world { browser in
            let tab = Fast.Tab()
            browser.prepare(tab)
            tab.restore(url: URL(string: "https://single.test/")!, title: "Single")
            browser.lay([tab])
            browser.activeID = tab.id
            let menu = NSHostingMenu(rootView: TabMenu(browser: browser, tab: tab, close: {}))
            let list = ActionMenuList(menu: menu, falls: true)
            #expect(list.lines.first?.title == "Pin")
            #expect(!list.lines.contains { $0.title == "Separate" })
            #expect(list.lines.contains { $0.title == "Open as Split" })
        }
    }

    @Test func aKeptTabsMenuKeepsItsLinesWhileItsRowRedraws() throws {
        guard let screen = TestScreen.screen else { return }
        try world { browser in
            let tab = Fast.Tab(), other = Fast.Tab()
            browser.prepare(tab)
            browser.prepare(other)
            tab.restore(url: URL(string: "https://home.test/overview")!, title: "Overview")
            other.restore(url: URL(string: "https://home.test/other")!, title: "Other")
            browser.lay([tab, other])
            browser.activeID = other.id
            browser.keepTabs([tab])
            tab.restore(url: URL(string: "https://home.test/performance")!, title: "Performance")
            #expect(tab.awayFromHome)

            let ticker = Ticker()
            let host = NSHostingView(rootView: Row(ticker: ticker, browser: browser, tab: tab))
            let window = NSWindow(contentRect: NSRect(x: screen.frame.minX + 100, y: screen.frame.minY + 100, width: 300, height: 120),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFrontRegardless()
            defer { window.orderOut(nil) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))

            let spot = try #require(Self.spot(in: host))
            // A press not asking for a menu goes through it to the row.
            #expect(spot.hitTest(NSPoint(x: spot.frame.midX, y: spot.frame.midY)) == nil)
            let at = spot.convert(NSPoint(x: spot.bounds.midX, y: spot.bounds.midY), to: nil)
            let press = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            let menu = try #require(spot.menu(for: press))
            #expect(menu.items.contains { $0.title == "Edit Kept Page" && $0.submenu != nil })

            var before: [String: ObjectIdentifier] = [:], after: [String: ObjectIdentifier] = [:]
            var submenuBefore: ObjectIdentifier?, submenuAfter: ObjectIdentifier?
            var step = 0
            let timer = Timer(timeInterval: 0.2, repeats: true) { timer in
                MainActor.assumeIsolated {
                    step += 1
                    if step == 1 {
                        before = Self.lines(menu)
                        submenuBefore = menu.items.first { $0.title == "Edit Kept Page" }?.submenu.map(ObjectIdentifier.init)
                    }
                    if step <= 4 { ticker.n += 1; return }
                    after = Self.lines(menu)
                    submenuAfter = menu.items.first { $0.title == "Edit Kept Page" }?.submenu.map(ObjectIdentifier.init)
                    timer.invalidate()
                    menu.cancelTracking()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            RunLoop.main.add(timer, forMode: .eventTracking)
            NSMenu.popUpContextMenu(menu, with: press, for: spot)
            timer.invalidate()

            #expect(ticker.n == 4)
            #expect(!before.isEmpty)
            let replaced = before.keys.filter { before[$0] != after[$0] }.sorted()
            #expect(replaced.isEmpty, "lines replaced while the row redrew: \(replaced)")
            #expect(submenuBefore != nil && submenuBefore == submenuAfter)
        }
    }
}
