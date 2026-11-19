import Combine
import Foundation
import Testing
@testable import Fast

/// Feedback #46: YouTube full screen and back, and the column of tabs came
/// back empty until clicked. The column is drawn in a host of its own that
/// hears only the browser, and lays itself out from `sideShown`, which reads
/// the page in front's `immersed`: the browser has to say when that changes.
struct ColumnImmersedTests {
    @MainActor @Test func thePageInFrontTakingTheScreenAndGivingItBackIsTold() {
        let window = UUID(), browser = Browser(windowID: window)
        let tabs = (0..<2).map { index in
            let tab = Tab()
            tab.restore(url: URL(string: "https://immersed.test/\(index)")!, title: "Tab \(index)")
            browser.prepare(tab)
            return tab
        }
        browser.lay(tabs)
        defer {
            browser.dozing?.invalidate()
            browser.stuck.timer?.invalidate()
            browser.pressure?.cancel()
            for tab in browser.tabs { tab.close() }
            try? FileManager.default.removeItem(at: Store.file("session-window-\(window.uuidString).json"))
        }
        browser.activeID = tabs[1].id
        var told = 0
        let hearing = ObservedWrites({ _ = browser.frontImmersed }, told: { told += 1 })
        defer { hearing.cancel() }

        tabs[1].immersed = true
        #expect(told == 1)
        tabs[1].immersed = false
        #expect(told == 2)
        // The same again is nothing new.
        tabs[1].immersed = false
        #expect(told == 2)
        // A tab behind isn't the column's business.
        tabs[0].immersed = true
        #expect(told == 2)
    }
}
