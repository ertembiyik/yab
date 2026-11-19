import AppKit
import SwiftUI
import WebKit

@MainActor final class DevFloating: NSObject, NSWindowDelegate {
    weak var browser: Browser?
    private(set) var window: NSWindow?
    private var opening: NSObjectProtocol?
    private weak var watchedPage: WKWebView?
    private weak var preparingWindow: NSWindow?
    private var windowObservation: NSKeyValueObservation?
    private var titleObservation: NSKeyValueObservation?
    private var keys: Any?
    private final class Owner { weak var browser: Browser?; init(_ browser: Browser) { self.browser = browser } }

    static func owner(of window: NSWindow?) -> Browser? {
        guard let window else { return nil }
        return (objc_getAssociatedObject(window, &detachedOwnerKey) as? Owner)?.browser
    }

    init(browser: Browser) { self.browser = browser; super.init() }

    /// WebKit must own its detached window. Moving an attached frontend to a
    /// second NSWindow makes WebKit reopen it when Inspect Element brings it
    /// forward. Adopt that one window before its first frame is displayed.
    func prepare(page: WKWebView? = nil) {
        if let page, page !== watchedPage {
            watchedPage = page
            windowObservation = page.observe(\.window, options: [.new]) { [weak self] page, _ in
                MainActor.assumeIsolated { self?.prepareWindow(page.window) }
            }
            prepareWindow(page.window)
        }
        guard opening == nil else { return }
        opening = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: nil) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let frame = note.object as? NSWindow,
                      let browser = self.browser, browser.devDetached,
                      let tab = browser.inspected, let inspector = Inspector.ofPage(tab.page),
                      let page = DevTools.page(inspector), page.window === frame else { return }
                self.adopt(frame, page: page, browser: browser)
            }
        }
    }

    /// window KVO runs when WebKit adds its frontend, before ordering the
    /// native window on screen. Key-window notification alone is too late:
    /// AppKit has already begun the stock window's opening animation.
    private func prepareWindow(_ frame: NSWindow?) {
        guard let frame, let browser, browser.devDetached,
              frame !== BrowserWindows.shared.window(for: browser),
              frame !== window, frame !== preparingWindow else { return }
        preparingWindow = frame
        frame.animationBehavior = .none
        frame.alphaValue = 0
        titleObservation = frame.observe(\.title, options: [.new]) { frame, _ in
            MainActor.assumeIsolated {
                if frame.title != "Developer Tools" { frame.title = "Developer Tools" }
            }
        }
        frame.title = "Developer Tools"
    }

    private func adopt(_ frame: NSWindow, page: WKWebView, browser: Browser) {
        guard window !== frame else { return }
        // Switching the inspected tab creates a new native inspector window.
        // Release the old host so its SwiftUI updates cannot reclaim the dock.
        if let keys { NSEvent.removeMonitor(keys); self.keys = nil }
        if let previous = window {
            previous.delegate = nil
            previous.orderOut(nil)
            previous.contentView = nil
            objc_setAssociatedObject(previous, &detachedOwnerKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        window = frame
        objc_setAssociatedObject(frame, &detachedOwnerKey, Owner(browser), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        frame.title = "Developer Tools"
        frame.styleMask.remove(.fullSizeContentView)
        frame.titlebarAppearsTransparent = false
        frame.isReleasedWhenClosed = false
        frame.opensOnActiveSpace()
        frame.contentMinSize = NSSize(width: 460, height: 320)
        frame.delegate = self
        browser.inspectorDock.addSubview(page)
        let content = WindowHosting.content(DevFloatingContent(browser: browser))
        frame.contentView = content
        if let kept = DevMemory.window, NSScreen.screens.contains(where: { $0.visibleFrame.intersection(kept).width >= 100 && $0.visibleFrame.intersection(kept).height >= 100 }) {
            frame.setFrame(kept, display: false)
        } else {
            frame.setContentSize(NSSize(width: 1000, height: 700))
            frame.center()
        }
        content.layoutSubtreeIfNeeded()
        frame.displayIfNeeded()
        frame.alphaValue = 1
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window, let browser = self.browser else { return event }
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            let key = Hotkey.readings(event).first?.key ?? ""
            if (flags == [.command] && key == "w") || Keymap.shared.action(for: event)?.action == .inspector {
                browser.closeDevTools()
                return nil
            }
            if NetKeys.take(event, browser: browser) || DevKeys.take(event, browser: browser) { return nil }
            if flags == [.command], key == "r" { browser.active?.page.reload(fromOrigin: false); return nil }
            if flags == [.command, .shift], key == "r" { browser.active?.page.reload(fromOrigin: true); return nil }
            return event
        }
    }

    func show() {
        guard let browser, browser.devDetached, browser.devOpen || browser.devComing else { return }
        prepare()
        window?.makeKeyAndOrderFront(nil)
    }

    func hide() {
        if let opening { NotificationCenter.default.removeObserver(opening); self.opening = nil }
        if let keys { NSEvent.removeMonitor(keys); self.keys = nil }
        keep()
        window?.delegate = nil
        window?.orderOut(nil)
        preparingWindow?.alphaValue = 1
        preparingWindow = nil
        windowObservation = nil
        titleObservation = nil
        watchedPage = nil
        window?.contentView = nil
        if let window { objc_setAssociatedObject(window, &detachedOwnerKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
        window = nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === window, let browser else { return true }
        // Tear down WebKit while its attachment window is still live. Our
        // common close hides the window, so AppKit must not close it again.
        browser.closeDevTools()
        return false
    }

    func windowWillClose(_ notification: Notification) {
        // A direct close() bypasses windowShouldClose. Ignore notifications
        // from windows discarded by a previous close or re-docking.
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        browser?.closeDevTools()
    }

    /// Kept as it is moved and sized, for the next time (DevMemory).
    func windowDidUpdate(_ notification: Notification) {
        // WebKit updates its native title when the inspected URL changes.
        if window?.title != "Developer Tools" { window?.title = "Developer Tools" }
    }
    func windowDidMove(_ notification: Notification) { keep() }
    func windowDidEndLiveResize(_ notification: Notification) { keep() }
    func windowDidResize(_ notification: Notification) { if window?.inLiveResize != true { keep() } }

    private func keep() {
        guard let window, window.isVisible else { return }
        DevMemory.window = window.frame
    }
}

nonisolated(unsafe) private var detachedOwnerKey: UInt8 = 0
nonisolated(unsafe) private var floatingKey: UInt8 = 0

extension Browser {
    var devFloating: DevFloating {
        if let value = objc_getAssociatedObject(self, &floatingKey) as? DevFloating { return value }
        let value = DevFloating(browser: self)
        objc_setAssociatedObject(self, &floatingKey, value, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return value
    }
    var devWindow: NSWindow? { devDetached ? devFloating.window : BrowserWindows.shared.window(for: self) }
}

private struct DevFloatingContent: View {
    var browser: Browser
    var body: some View {
        if let tab = browser.toolsFront {
            DevSheet(browser: browser, tab: tab, log: tab.devLog, pane: browser.devPane, panels: browser.devPanels,
                     filter: browser.issueFilter, side: .bottom, shown: true, corner: 0)
        } else { DevQuiet(words: "Select a page to inspect") }
    }
}
