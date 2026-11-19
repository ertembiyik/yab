import AppKit
import QuartzCore
import SwiftUI
import Testing
import WebKit
@testable import Fast

/// Preference and mounted native-view coverage. The tune is controlled model
/// state; this suite does not claim real audio playback or provider coverage.
@MainActor
@Suite(.serialized)
struct PlayerVisibilityTests {
    private func isolatedSettings(_ check: () async throws -> Void) async throws {
        try #require(Thread.isMainThread)
        try #require(Store.testing && Store.world != nil, "Never change a production settings store")
        try #require(Store.settings !== UserDefaults.standard, "The test must own its defaults suite")
        let saved = Store.settings.object(forKey: "player.shown")
        defer {
            if let saved { Store.settings.set(saved, forKey: "player.shown") }
            else { Store.settings.removeObject(forKey: "player.shown") }
        }
        _ = NSApplication.shared
        try await check()
    }

    private struct RoomProbe: View {
        var prefs: Preferences
        var room: PlayerRoom
        let measured: (CGFloat) -> Void

        var body: some View {
            BandRoom(room: room, visible: prefs.showsPlayer)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measured($0) }
        }
    }

    @MainActor
    private final class Fixture {
        let browser: Browser
        let source: Fast.Tab
        let notes: Fast.Tab
        let window: NSWindow
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let slot: NSHostingView<BandSlot>
        let room: NSHostingView<RoomProbe>
        private(set) var roomHeight: CGFloat?

        init() {
            let browser = Browser(windowID: UUID())
            self.browser = browser
            source = Fast.Tab(shy: true, configuration: Web.configuration(shy: true, extensions: false))
            notes = Fast.Tab(shy: true, configuration: Web.configuration(shy: true, extensions: false))
            slot = NSHostingView(rootView: BandSlot(player: browser.player, prefs: browser.prefs,
                                                  room: browser.player.room, column: 270))
            room = NSHostingView(rootView: RoomProbe(prefs: browser.prefs, room: browser.player.room, measured: { _ in }))
            window = NSWindow(contentRect: root.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = root
            browser.dozing?.invalidate()
            browser.stuck.timer?.invalidate()
            browser.stuck.agentTimer?.invalidate()
            browser.stuck.frontTimer?.invalidate()
            browser.pressure?.cancel()
            for (tab, title) in [(source, "Owned source"), (notes, "Notes")] {
                tab.restore(url: URL(string: "about:blank#player-visibility-" + title.replacingOccurrences(of: " ", with: "-"))!, title: title)
                browser.prepare(tab)
            }
            browser.lay([source, notes])
            browser.activeID = notes.id
            source.tune = Tune(title: "Owned source", duration: 240, elapsed: 20,
                               stamp: CACurrentMediaTime(), playing: true)
            browser.player.heard(source)
            browser.player.restage(immediate: true)
            slot.frame = NSRect(x: 0, y: 80, width: 300, height: Band.reach + 10)
            room.frame = NSRect(x: 320, y: 0, width: 270, height: 70)
            room.rootView = RoomProbe(prefs: browser.prefs, room: browser.player.room,
                                      measured: { [weak self] height in self?.roomHeight = height })
            root.addSubview(slot)
            root.addSubview(room)
        }

        var bands: [BandView] {
            func find(_ view: NSView) -> [BandView] {
                (view as? BandView).map { [$0] } ?? view.subviews.flatMap(find)
            }
            return find(slot)
        }

        func settle(_ ready: () -> Bool) async throws {
            let reached = try await Loaded.until(3, every: .milliseconds(25)) {
                self.window.layoutIfNeeded()
                self.root.layoutSubtreeIfNeeded()
                CATransaction.flush()
                return ready()
            }
            try #require(reached, "The mounted native player hierarchy must reach the requested state")
        }

        func close() {
            bands.forEach { $0.bench("close") }
            slot.removeFromSuperview()
            room.removeFromSuperview()
            window.contentView = nil
            window.close()
            browser.dozing?.invalidate()
            browser.stuck.timer?.invalidate()
            browser.stuck.agentTimer?.invalidate()
            browser.stuck.frontTimer?.invalidate()
            browser.pressure?.cancel()
            browser.tabs.forEach { $0.close() }
            if let id = browser.windowID {
                try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
            }
        }
    }

    @Test func visibilityDefaultsOnAndTheRealSettingPersistsBothChoices() async throws {
        try await isolatedSettings {
            Store.settings.removeObject(forKey: "player.shown")
            let prefs = Preferences()
            #expect(prefs.showsPlayer)
            let setting = try #require(NativeSetting.all.first { $0.id == "player" })
            try setting.write(prefs, .bool(false))
            #expect(!prefs.showsPlayer)
            #expect(setting.read(prefs) == .bool(false))
            #expect(setting.saved == .bool(false))
            #expect(!Preferences().showsPlayer)
            #expect(throws: (any Error).self) { try setting.write(prefs, .string("false")) }
            #expect(!Preferences().showsPlayer)
            try setting.write(prefs, .bool(true))
            #expect(prefs.showsPlayer && Preferences().showsPlayer)
            #expect(setting.saved == .bool(true))
            #expect(SettingsItem.all.contains { $0.id == "player" })
        }
    }

    @Test func hidingRemovesTheMountedSlotAndRoomWithoutChangingThePlayer() async throws {
        try await isolatedSettings {
            Store.settings.removeObject(forKey: "player.shown")
            let fixture = Fixture()
            defer { fixture.close() }
            try #require(!fixture.source.store.isPersistent)
            try await fixture.settle {
                fixture.bands.count == 1 && fixture.bands.first?.window === fixture.window
                    && abs((fixture.roomHeight ?? -1) - Band.room) < 0.5
            }
            // Retain the old view so removal cannot pass by deallocation alone.
            let original = try #require(fixture.bands.first)
            let face = try #require(fixture.browser.player.face)
            let tune = try #require(fixture.source.tune)
            let active = fixture.browser.activeID
            try #require(fixture.browser.player.tab === fixture.source)
            try #require(tune.playing && fixture.browser.player.room.up)

            fixture.browser.prefs.showsPlayer = false
            try await fixture.settle {
                fixture.bands.isEmpty && original.window == nil && fixture.roomHeight == 0
            }
            #expect(fixture.room.window === fixture.window, "BandRoom stays mounted and reports zero height")
            #expect(fixture.browser.player.room.up, "The room is hidden by the preference, not by clearing playback state")
            #expect(fixture.browser.player.face == face)
            #expect(fixture.browser.player.tab === fixture.source)
            #expect(fixture.source.tune == tune)
            #expect(fixture.browser.activeID == active)

            fixture.browser.prefs.showsPlayer = true
            try await fixture.settle {
                fixture.bands.count == 1 && fixture.bands.first?.window === fixture.window
                    && abs((fixture.roomHeight ?? -1) - Band.room) < 0.5
            }
            #expect(fixture.browser.player.face == face)
            #expect(fixture.browser.player.tab === fixture.source)
            #expect(fixture.source.tune == tune)
            #expect(fixture.source.tune?.playing == true)
            #expect(fixture.browser.activeID == active)
        }
    }
}
