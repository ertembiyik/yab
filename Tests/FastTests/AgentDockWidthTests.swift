import AppKit
import SwiftUI
import Testing
import WebKit
@testable import Fast

@MainActor
@Suite(.serialized)
struct AgentDockWidthTests {
    init() throws {
        try #require(Store.testing && Store.world != nil && Store.settings !== UserDefaults.standard)
        _ = NSApplication.shared
    }

    private let command = "Running yt-dlp " + String(repeating: "--extractor-args player_client=web,mweb,tv --format video+audio ", count: 18)

    private func fixture(_ body: (Fast.Tab, Agents.Session) async throws -> Void) async throws {
        // No Browser, selected page, real store, provider, sign-in or clipboard.
        let previousMail = Store.settings.object(forKey: "mail")
        Store.settings.set(false, forKey: "mail")
        defer {
            if let previousMail { Store.settings.set(previousMail, forKey: "mail") }
            else { Store.settings.removeObject(forKey: "mail") }
        }
        // SwiftUI builds its accessibility tree in process only once an
        // assistive client is said to be there; swift test has none.
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let wasEnhanced = NSApp.accessibilityAttributeValue(enhanced) as? Bool ?? false
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(wasEnhanced, forAttribute: enhanced) }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let tab = Fast.Tab(bench: true, configuration: configuration)
        let agents = Agents.shared
        let session = agents.attach(name: "Dock width fixture " + UUID().uuidString)
        session.state = .running // Inert external session: never launch a provider.
        session.now = command
        tab.agent = session.id
        defer {
            tab.agent = nil
            tab.close()
            session.state = .attached
            agents.detach(session.id)
        }
        try await body(tab, session)
        #expect(session.process == nil && session.server == nil)
        #expect(tab.builtPage == nil && !tab.store.isPersistent)
    }

    private func window(width: CGFloat) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -8000, y: -8000, width: width, height: 180),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private func settle(_ window: NSWindow) async throws {
        // Final layout only: words use300ms; the measured plate can then
        // reshape for300ms (Motion.reshape).800ms allows both plus200ms
        // delivery margin. Intermediate motion remains prepared-app acceptance.
        for _ in 0..<40 {
            window.layoutIfNeeded()
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    // These are the mounted SwiftUI accessibility elements, not width arithmetic
    // or a duplicate test layout. KVC calls only advertised public AX properties.
    private func value(_ object: NSObject, _ key: String) -> Any? {
        object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil
    }

    private func elements(_ root: NSObject) -> [NSObject] {
        var seen = Set<ObjectIdentifier>(), found: [NSObject] = []
        func visit(_ object: NSObject) {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return }
            found.append(object)
            for child in value(object, "accessibilityChildren") as? [NSObject] ?? [] { visit(child) }
        }
        visit(root)
        return found
    }

    private func bounds(_ element: NSObject) -> NSRect {
        (value(element, "accessibilityFrame") as? NSValue)?.rectValue ?? .zero
    }

    /// The drawn plate on screen. Its accessibility group's frame is the
    /// union of its children (SwiftUI), 12 in and 4 short of the plate, so
    /// the plate is its benchSpot, carried to the screen by the Stop
    /// button, which is both a spot and an accessibility element.
    private func plate(stop: NSObject) throws -> NSRect {
        let spot = try #require(Bench.spots["agent dock plate"])
        let stopSpot = try #require(Bench.spots["agent dock stop"])
        let stopScreen = bounds(stop)
        // Spots are top-down, the screen bottom-up.
        let dx = stopScreen.minX - stopSpot.minX, top = stopScreen.minY + stopSpot.maxY
        return NSRect(x: spot.minX + dx, y: top - spot.maxY, width: spot.width, height: spot.height)
    }

    private func controls(in root: NSView, window: NSWindow, width: CGFloat) throws -> NSRect {
        let all = elements(root)
        let dock = try #require(all.first { value($0, "accessibilityIdentifier") as? String == "agent-working-dock" })
        let page = window.convertToScreen(NSRect(x: 0, y: 0, width: width, height: 180))
        let buttons = elements(dock).filter { value($0, "accessibilityRole") as? String == "AXButton" }
        func button(_ title: String) throws -> NSObject {
            try #require(buttons.first { button in
                ["accessibilityLabel", "accessibilityTitle"].contains { key in
                    (value(button, key) as? String)?.contains(title) == true
                }
            })
        }
        let frame = try plate(stop: try button("Stop"))
        #expect(frame.width > 0 && frame.height > 0)
        #expect(abs(frame.height - 36) <= 1)
        #expect(frame.minX >= page.minX - 1 && frame.maxX <= page.maxX + 1)
        #expect(frame.insetBy(dx: -1, dy: -1).contains(bounds(dock)))
        for title in ["Take Over", "Stop"] {
            let rect = bounds(try button(title))
            #expect(rect.width > 0 && rect.height > 0)
            #expect(frame.insetBy(dx: -1, dy: -1).contains(rect))
        }
        return frame
    }

    @Test func composedPageFootKeepsCommandsAndControlsInsideLivePageWidth() async throws {
        try await fixture { tab, session in
            let selection = SelectionCommands()
            let host = NSHostingView(rootView: GeometryReader { page in
                PageFoot(availableWidth: page.size.width, tab: tab, selection: selection)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }.transaction { $0.disablesAnimations = true })
            let window = window(width: 1000)
            window.contentView = host
            defer { window.contentView = nil; window.close() }
            for width in [CGFloat(1000), 360, 1000] {
                window.setContentSize(NSSize(width: width, height: 180))
                try await settle(window)
                _ = try controls(in: host, window: window, width: width)
                #expect(session.now == command)
            }
            session.now = "Reading"
            try await settle(window)
            let short = try controls(in: host, window: window, width: 1000)
            #expect(short.width < 700)
            session.now = command
            try await settle(window)
            let long = try controls(in: host, window: window, width: 1000)
            #expect(long.width > short.width)
        }
    }

    @Test func intrinsicPeekHostTracksHolderWithoutCatchingEmptyPageOrFoot() async throws {
        try await fixture { tab, session in
            let window = window(width: 1000)
            let holder = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 180))
            window.contentView = holder
            let host = AgentDockHost.mount(tab, in: holder)
            defer { host.removeFromSuperview(); window.contentView = nil; window.close() }
            for width in [CGFloat(1000), 360, 1000] {
                window.setContentSize(NSSize(width: width, height: 180))
                try await settle(window)
                _ = try controls(in: host, window: window, width: width)
                #expect(host.frame.width <= holder.bounds.width + 1)
                #expect(host.frame.height < 80)
            }
            session.now = "Reading"
            try await settle(window)
            let short = try controls(in: host, window: window, width: 1000)
            #expect(host.frame.width < holder.bounds.width - 100)
            #expect(abs(host.frame.width - short.width) <= 1)
            let blank = NSPoint(x: 4, y: holder.bounds.midY)
            let foot = NSPoint(x: holder.bounds.midX, y: 2)
            for point in [blank, foot] {
                let hit = holder.hitTest(point)
                #expect(hit !== host && hit?.isDescendant(of: host) != true)
            }
            let button = try #require(elements(host).first {
                value($0, "accessibilityRole") as? String == "AXButton"
                    && (value($0, "accessibilityLabel") as? String)?.contains("Stop") == true
            })
            let buttonInWindow = window.convertFromScreen(bounds(button))
            let hit = holder.hitTest(holder.convert(NSPoint(x: buttonInWindow.midX, y: buttonInWindow.midY), from: nil))
            #expect(hit === host || hit?.isDescendant(of: host) == true)
        }
    }
}
