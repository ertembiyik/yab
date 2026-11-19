import AppKit
import Combine
import SwiftUI
import Testing
@testable import Fast

@MainActor
@Suite(.serialized)
struct PrivateFolderTests {
    private func world(_ body: (Browser, Nest, [Fast.Tab]) async throws -> Void) async rethrows {
        let browser = Browser(windowID: UUID(), purpose: .privateOnly)
        let folder = Nest(name: "Private folder", open: true)
        folder.fleeting = true
        let tabs = (0..<3).map { index in
            let tab = Fast.Tab(shy: true)
            tab.restore(url: URL(string: "https://private-folder.invalid/\(index)")!, title: "Private \(index)")
            if index < 2 { tab.nest = folder }
            browser.prepare(tab)
            return tab
        }
        browser.lay(tabs)
        browser.activeID = tabs.last?.id
        browser.folderBook.refresh()
        defer {
            browser.folderBook.browser = nil
            browser.dozing?.invalidate(); browser.stuck.timer?.invalidate(); browser.pressure?.cancel()
            tabs.forEach { $0.close() }
        }
        try await body(browser, folder, tabs)
    }

    private func nextTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @Test func privateFolderChangesReachTheColumnWithoutSharingItsContents() async throws {
        try await world { browser, folder, tabs in
            #expect(browser.folderBook !== Folders.shared)
            #expect(browser.folderBook.browser === browser)
            #expect(!Folders.shared.folders.contains { $0.id == folder.key })
            var publications = 0
            let watch = ObservedWrites({ _ = (browser.folderBook.folders, browser.folderBook.version) }, told: { publications += 1 })
            defer { watch.cancel() }
            browser.folderBook.toggle(folder.key)
            #expect(!folder.open)
            #expect(browser.folderBook.place(of: tabs[0])?.shown == false)
            #expect(publications > 0)
            publications = 0
            browser.folderBook.toggle(folder.key)
            await nextTurn()
            #expect(folder.open)
            #expect(browser.folderBook.place(of: tabs[0])?.shown == true)
            #expect(publications > 0)
            #expect(!Folders.shared.folders.contains { $0.id == folder.key })
            #expect(tabs.allSatisfy { $0.shy && !$0.store.isPersistent })
        }
    }

    @Test func fieldOffersThePrivateFoldersCurrentActionAboveHistoryAndWeb() async throws {
        try await world { browser, folder, _ in
            let spaces = browser.prefs.usesSpaces
            let more = browser.prefs.menuCommands
            let moreStored = Store.settings.object(forKey: MenuCommands.key)
            let commands = FieldUnder.shared.commands
            let commandsStored = Store.settings.object(forKey: "field.match.commands")
            defer {
                browser.prefs.usesSpaces = spaces
                browser.prefs.menuCommands = more
                Store.settings.set(moreStored, forKey: MenuCommands.key)
                FieldUnder.shared.commands = commands
                Store.settings.set(commandsStored, forKey: "field.match.commands")
            }
            // Keep the existing advanced-catalog gate; private context must
            // not silently turn on more commands for everyone.
            browser.prefs.menuCommands = false
            #expect(MenuCommands.targets(in: browser).allSatisfy { ![Command.openFolder, .closeFolder].contains($0.operation) })
            #expect(!Command.closeFolder.available(in: browser))
            browser.prefs.usesSpaces = true
            browser.prefs.menuCommands = true
            FieldUnder.shared.commands = true
            for opening in [false, true] {
                let title = "\(opening ? "Open" : "Close") Folder Private folder"
                let operation: Command = opening ? .openFolder : .closeFolder
                let other: Command = opening ? .closeFolder : .openFolder
                #expect(MenuCommands.hasTargets(operation, in: browser))
                #expect(!MenuCommands.hasTargets(other, in: browser))
                let target = try #require(MenuCommands.targets(operation, in: browser).first { $0.title == title })
                browser.history = History([Visit(url: "https://private-folder.invalid/history", key: title.lowercased(), title: title,
                                                 count: 100, last: Date())])
                browser.typed = title
                let offers = browser.offers
                #expect(offers.first?.key == title)
                #expect(offers.first?.kind == target.offer.kind)
                let merged = SearchSuggestions.merge([
                    Suggestion(key: title + " online", title: "", url: nil, kind: .suggested)
                ], into: offers, lead: browser.query.lead)
                #expect(merged.list.first?.kind == target.offer.kind)
                // Execution resolves the existing typed target for this window.
                target.run(browser)
                await nextTurn()
                #expect(folder.open == opening)
                #expect(!MenuCommands.targets(in: browser).contains { [.switchSpace, .moveToSpace, .moveToFolder, .newLiveFolder].contains($0.operation) })
            }
        }
    }

    @Test func privateColumnUsesThePrivateGroundAcrossSpaceLooks() throws {
        let browser = Browser(windowID: UUID(), purpose: .privateOnly)
        defer {
            browser.folderBook.browser = nil
            browser.dozing?.invalidate(); browser.stuck.timer?.invalidate(); browser.pressure?.cancel()
        }
        let prefs = browser.prefs
        let saved = (prefs.backdrop, prefs.swatch, prefs.lookMode, prefs.lookGlass)
        defer {
            prefs.backdrop = saved.0; prefs.swatch = saved.1
            prefs.lookMode = saved.2; prefs.lookGlass = saved.3
        }
        func luminance(_ rgb: [Double]) -> Double {
            zip(rgb, [0.2126, 0.7152, 0.0722]).reduce(0) { sum, pair in
                let (v, weight) = pair
                return sum + weight * (v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4))
            }
        }
        for mode in ["light", "dark"] {
            prefs.lookMode = mode
            for backdrop in [Backdrop.color, .site, .none] {
                prefs.backdrop = backdrop
                for swatch in [Swatch.paper, .plain, .peach, .graphite] {
                    prefs.swatch = swatch
                    prefs.lookGlass = true
                    let tone = try #require(ColumnRoot(browser: browser, prefs: prefs).swatch)
                    #expect(tone.page == Tone(ContentView.privateBackdrop).page)
                    #expect(tone.scheme == .dark && !tone.glass)
                    let paint = try #require(SpaceWash.grounded(in: browser))
                    #expect(paint.color == ContentView.privateBackdrop)
                    #expect(paint.transparency == 0 && !paint.glass && paint.drawings == nil)
                    let card = Column.paint(tone, prefs: prefs, privateWindow: true)
                    #expect(card.color == paint.color && card.transparency == 0 && !card.glass)
                    var env = EnvironmentValues()
                    env.colorScheme = tone.scheme
                    env.tone = tone
                    let background = [tone.page.redComponent, tone.page.greenComponent, tone.page.blueComponent].map(Double.init)
                    let ground = luminance(background)
                    for ink in [Palette.ink, Palette.muted(on: tone)] {
                        let resolved = try #require(NSColor(cgColor: ink.resolve(in: env).cgColor)?.usingColorSpace(.sRGB))
                        let channels = [resolved.redComponent, resolved.greenComponent, resolved.blueComponent].map(Double.init)
                        let alpha = Double(resolved.alphaComponent)
                        let text = luminance(zip(channels, background).map { pair in pair.0 * alpha + pair.1 * (1 - alpha) })
                        #expect((max(text, ground) + 0.05) / (min(text, ground) + 0.05) >= 4.5)
                    }
                }
            }
        }
    }
}
