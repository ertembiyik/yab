import AppKit
import Combine
import Testing
@testable import Fast

@MainActor @Suite(.serialized)
struct PinPreviewReadyTests {
    private typealias Reply = @MainActor ([PinItem]) -> Void

    private func world(_ body: (Browser, TabGlance, Tab, Tab) -> Void) {
        let id = UUID(), browser = Browser(windowID: id)
        let tabs = ["one", "two"].map { name in
            let tab = Tab()
            tab.restore(url: URL(string: "https://\(name).test/")!, title: name)
            tab.pin = name
            browser.prepare(tab)
            return tab
        }
        browser.lay(tabs)
        let glance = browser.glance
        defer {
            glance.drop()
            glance.pinLoader = PinList.items
            browser.dozing?.invalidate()
            browser.stuck.timer?.invalidate()
            browser.pressure?.cancel()
            for tab in browser.tabs { tab.close() }
            try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
            Store.settings.removeObject(forKey: "window.\(id.uuidString).space")
        }
        body(browser, glance, tabs[0], tabs[1])
    }

    private func rows(_ prefix: String, count: Int = 6) -> [PinItem] {
        (0..<count).map { PinItem(id: "\(prefix)\($0)", title: "\(prefix) \($0)", detail: "1 min", open: {}) }
    }

    @Test func publishesOnlyAfterRowsAreReady() {
        world { _, glance, pin, _ in
            var reply: Reply?
            glance.pinLoader = { _, _, _, done in reply = done }
            var visibleCounts: [Int] = []
            let observation = ObservedWrites({ _ = glance.shownFolder }, told: { visibleCounts.append(glance.pinItems.count) })
            glance.pretendFolder(TabGlance.pinKey(pin.id), true)
            #expect(glance.shownFolder == nil && !glance.searching && !glance.taking)
            reply?(rows("loaded"))
            #expect(glance.shownFolder == TabGlance.pinKey(pin.id) && glance.searching)
            #expect(visibleCounts == [6])
            withExtendedLifetime(observation) {}
        }
    }

    @Test func aCompletedEmptyResultCanBeShown() {
        world { _, glance, pin, _ in
            var reply: Reply?
            glance.pinLoader = { _, _, _, done in reply = done }
            glance.pretendFolder(TabGlance.pinKey(pin.id), true)
            #expect(glance.shownFolder == nil)
            reply?([])
            #expect(glance.shownFolder == TabGlance.pinKey(pin.id) && glance.pinItems.isEmpty)
        }
    }

    @Test func dismissAndReopenRejectsTheFirstReply() {
        world { _, glance, pin, _ in
            var replies: [Reply] = []
            glance.pinLoader = { _, _, _, done in replies.append(done) }
            glance.pretendFolder(TabGlance.pinKey(pin.id), true)
            glance.drop()
            replies[0](rows("dismissed"))
            #expect(glance.shownFolder == nil)
            glance.pretendFolder(TabGlance.pinKey(pin.id), true)
            replies[0](rows("old"))
            #expect(glance.shownFolder == nil)
            replies[1](rows("new"))
            #expect(glance.pinItems.first?.id == "new0")
        }
    }

    @Test func movingToAnotherPinRejectsTheOldReply() {
        world { _, glance, first, second in
            var replies: [Reply] = []
            glance.pinLoader = { _, _, _, done in replies.append(done) }
            glance.pretendFolder(TabGlance.pinKey(first.id), true)
            glance.pretendFolder(TabGlance.pinKey(second.id), true)
            replies[0](rows("old"))
            #expect(glance.shownFolder == nil)
            replies[1](rows("new"))
            #expect(glance.shownFolder == TabGlance.pinKey(second.id))
            #expect(glance.pinItems.first?.id == "new0")
        }
    }

    @Test func leavingBeforeTheReplyDoesNotOpenACard() {
        world { _, glance, pin, _ in
            var reply: Reply?
            glance.pinLoader = { _, _, _, done in reply = done }
            let key = TabGlance.pinKey(pin.id)
            glance.pretendFolder(key, true)
            glance.hoverFolder(key, false)
            reply?(rows("late"))
            #expect(glance.shownFolder == nil && !glance.taking)
        }
    }

    @Test func repeatedSearchWordsStillRejectAnOlderReply() {
        world { _, glance, pin, _ in
            var replies: [Reply] = []
            glance.pinLoader = { _, _, _, done in replies.append(done) }
            glance.pretendFolder(TabGlance.pinKey(pin.id), true)
            replies[0](rows("all"))
            glance.search("a")
            glance.search("b")
            glance.search("a")
            replies[3](rows("latest", count: 2))
            replies[1](rows("obsolete"))
            replies[2](rows("wrong-query"))
            #expect(glance.pinItems.map(\.id) == ["latest0", "latest1"])
        }
    }

    @Test func heightIsKnownForEmptyFullAndScrollableLists() {
        #expect(PinPreview.height(0) == PinPreview.height(1))
        #expect(PinPreview.height(6) - PinPreview.height(1) == 5 * FieldActionsPanel.row)
        #expect(PinPreview.height(12) == PinPreview.height(TabGlance.previewRows))
    }
}
