import AppKit
import SwiftUI
import SyncKit
import Testing
@testable import Fast

/// Actual SwiftUI views, including their AppKit typing indicator and layout.
/// The same tests run against main and the candidate on a farm test screen.
@MainActor
@Suite(.serialized)
struct ChatStreamStabilityTests {
    static let paragraphs = "The documents are ready to review.\n\n"
        + "The first document explains how the browser keeps the current conversation in place while the answer is arriving.\n\n"
        + "The second document includes the detailed results and the remaining checks. Both links are available in the card below."
    static let table = "Here are the results.\n\n| Check | Result |\n|---|---|\n| Streaming | Stable |\n| Cards | In place |\n\n"
        + "```swift\nlet answer = \"Ready\"\nprint(answer)\n```\n\nThe report is ready for review."

    final class Measurements {
        var footer: CGFloat = 0
        var samples: [CGFloat] = []
    }

    @Test(.enabled("needs a farm test screen") { await TestScreen.available })
    func cardsStayAtTheirFinalPositionWhileKnownTextIsWrittenOut() async throws {
        for (name, text, grow) in [("paragraphs", Self.paragraphs, true), ("table-code", Self.table, true), ("plain", Self.paragraphs, false)] {
            for dark in [false, true] {
                let measured = Measurements()
                let content = VStack(alignment: .leading, spacing: 6) {
                    ChatWords(text: text, streaming: false, fresh: true, bubbles: true, grow: grow)
                    Text("RESULT CARD")
                        .font(.system(size: 13))
                        .padding(12)
                        .background(Color.blue.opacity(0.15))
                        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named("probe")).minY } action: { measured.footer = $0 }
                    Spacer(minLength: 0)
                }
                .padding(16)
                .frame(width: 380, height: 720, alignment: .topLeading)
                .coordinateSpace(name: "probe")
                .background(Palette.ground)
                .environment(\.colorScheme, dark ? .dark : .light)
                let host = Host(content)
                defer { host.close() }
                var previous = 0.0
                for at in [0.05, 0.15, 0.3, 0.6, 1.0, 1.6] {
                    try await Task.sleep(for: .seconds(at - previous))
                    previous = at
                    host.view.layoutSubtreeIfNeeded()
                    measured.samples.append(measured.footer)
                    try host.save("\(name)-\(dark ? "dark" : "light")-\(Int(at * 1000))")
                }
                let final = try #require(measured.samples.last)
                #expect(final > 40, "the footer was measured")
                #expect(measured.samples.allSatisfy { abs($0 - final) <= 1 }, "\(name) footer moved: \(measured.samples)")
                try saveJSON(["name": name, "dark": dark, "footer_y": measured.samples], "\(name)-\(dark)-geometry")
            }
        }
    }

    @Observable final class Conversation {
        var chat: Chat
        var live = true
        @ObservationIgnored var writing: [Bool] = []
        init(_ chat: Chat) { self.chat = chat }
    }
    struct Transcript: View {
        let browser: Browser
        var conversation: Conversation
        var body: some View {
            ChatTranscript(browser: browser, chat: conversation.chat, live: conversation.live, away: .constant(false), foot: 56)
                .frame(width: 380, height: 720)
                .background(Palette.ground)
                .onPreferenceChange(ChatWords.WritingOut.self) { conversation.writing.append($0) }
        }
    }

    @Test(.enabled("needs a farm test screen") { await TestScreen.available })
    func resultCardsWaitForTheFinalBubble() async throws {
        for (name, streamed, short) in [("lump", false, false), ("stream", true, false), ("short", false, true)] {
            for dark in [false, true] {
                let browser = Browser(windowID: UUID())
                let id = "card-reveal-" + UUID().uuidString
                Agents.shared.benchTask(id, state: .running)
                let session = try #require(Agents.shared.session(id))
                session.cli = "claude"
                defer {
                    session.state = .done
                    browser.everyTab.forEach { $0.close() }
                }
                session.items.put(ChatItem(id: "q", kind: .asked, text: "Check the documents", state: .done), at: Date())
                if streamed {
                    session.items.put(ChatItem(id: "answer", kind: .message, text: "The documents are ready to review.", state: .running), at: Date())
                }
                let conversation = Conversation(Agents.shared.chat(of: session))
                let host = Host(Transcript(browser: browser, conversation: conversation)
                    .environment(\.colorScheme, dark ? .dark : .light))
                defer { host.close() }
                // Let the send settle before delivering the result and final text together.
                try await Task.sleep(for: .milliseconds(400))
                let text = short ? "The documents are ready." : Self.paragraphs
                session.items.put(ChatItem(id: "answer", kind: .message, text: text, state: .done), at: Date())
                session.items.put(.card(ResultCard(kind: .routine, title: "RESULT READY", detail: "Documents checked", ref: "probe"), id: "result", at: Date()))
                session.state = .done
                conversation.chat = Agents.shared.chat(of: session)
                conversation.live = false
                let prefix = "reveal-\(name)-\(dark ? "dark" : "light")"
                let evidence = ChatRevealEvidence(folder: evidenceFolder)
                try await evidence.retaining {
                    var frames: [[UInt8]] = []
                    var writing: [Bool] = []
                    var capturedAt: [Double] = []
                    // The reveal starts later on a loaded Mac and its fade is
                    // 0.22 s: sampled often enough to see it, and until the
                    // frame has settled rather than to a fixed end.
                    var at = 0.03
                    let started = Date()
                    while true {
                        try await Task.sleep(for: .seconds(max(0, at - Date().timeIntervalSince(started))))
                        host.view.layoutSubtreeIfNeeded()
                        writing.append(conversation.writing.last ?? false)
                        capturedAt.append(Date().timeIntervalSince(started))
                        frames.append(try evidence.capture("\(prefix)-\(Int(at * 1000))",
                            width: Int(host.view.bounds.width), height: Int(host.view.bounds.height), started: started,
                            requested: at, writing: writing.last,
                            pixels: { try host.pixels() }, image: { try host.image() }))
                        let settled = writing.last == false && frames.count >= 5 && frames.suffix(5).allSatisfy { $0 == frames.last }
                        if (at >= 1.6 && settled) || at >= 8 { break }
                        at = at == 0.03 ? 0.10 : at + 0.06
                    }
                    let final = try #require(frames.last)
                    // A native rendering without the result isolates the result's
                    // pixels, avoiding assumptions about fonts, theme or coordinates.
                    session.items.removeAll { $0.kind == .card }
                    conversation.chat = Agents.shared.chat(of: session)
                    try await Task.sleep(for: .milliseconds(400))
                    host.view.layoutSubtreeIfNeeded()
                    let blank = try evidence.capture("\(prefix)-no-card",
                        width: Int(host.view.bounds.width), height: Int(host.view.bounds.height), started: started,
                        pixels: { try host.pixels() }, image: { try host.image() })
                    let observed = ChatRevealPixels(frames: frames, final: final, blank: blank, width: Int(host.view.bounds.width))
                    let mask = observed.mask, strayIcons = observed.strayIcons, visibility = observed.visibility
                    #expect(mask.count > 100, "the actual result card must be on screen: \(prefix)")
                    #expect(observed.noDetachedIcon, "no detached AppKit icon: \(prefix) \(strayIcons)")
                    #expect(observed.noFirstFlash, "no first-frame result flash: \(prefix) \(visibility)")
                    if !short {
                        #expect(writing.contains(true), "the native text reveal was observed")
                        for index in writing.indices where writing[index] {
                            #expect(observed.hidden(at: index), "the card waits for all paragraphs: \(prefix) \(visibility)")
                        }
                    }
                    if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                        #expect(observed.fadesIn, "the card fades in: \(prefix) \(visibility)")
                    }
                    #expect(observed.staysVisible, "the card stays visible after settling")
                    try saveJSON(["times": capturedAt, "writing": writing, "visibility": visibility, "result_pixels": mask.count, "stray_icon_pixels": strayIcons], prefix)
                }
            }
        }
    }

    @Test(.enabled("needs a farm test screen") { await TestScreen.available })
    func acknowledgingTheSentMessageKeepsTheSameTypingView() async throws {
        for history in [false, true] {
            let browser = Browser(windowID: UUID())
            let id = "stream-stability-" + UUID().uuidString
            Agents.shared.benchTask(id, state: .running)
            let session = try #require(Agents.shared.session(id))
            session.cli = "claude"
            session.title = "Streaming check"
            if history {
                let earlier = Date().addingTimeInterval(-120)
                session.items.put(ChatItem(id: "old-asked", kind: .asked, text: "Earlier question", state: .done), at: earlier)
                session.items.put(ChatItem(id: "old-answer", kind: .message, text: "Earlier answer.", state: .done), at: earlier)
            }
            session.saying = ["Please check the documents"]
            defer {
                session.saying = []
                session.state = .done
                browser.everyTab.forEach { $0.close() }
            }
            let conversation = Conversation(Agents.shared.chat(of: session))
            let host = Host(Transcript(browser: browser, conversation: conversation))
            defer { host.close() }
            try await Task.sleep(for: .milliseconds(150))
            let before = try #require(host.typing.first, "pending typing indicator is present")
            try host.save("history-\(history)-send-before-echo")
            session.saying = []
            session.items.put(ChatItem(id: "echo", kind: .asked, text: "Please check the documents", state: .done), at: Date())
            conversation.chat = Agents.shared.chat(of: session)
            try await Task.sleep(for: .milliseconds(150))
            let after = try #require(host.typing.first, "acknowledged typing indicator is present")
            #expect(before === after, "provider acknowledgement must preserve the visible typing view")
            try host.save("history-\(history)-send-after-echo")
            // Real partial-message updates, followed by a completed provider item.
            let pieces = ["I am checking ", "the documents ", "and keeping this answer in place.", " See [mail](yab://mail#inbox)."]
            for words in pieces {
                session.items.grow("answer.text", by: words, at: Date())
                conversation.chat = Agents.shared.chat(of: session)
                try await Task.sleep(for: .milliseconds(120))
            }
            try host.save("history-\(history)-send-streaming")
            let completed = pieces.joined() + "\n\n" + Self.paragraphs
            session.items.put(ChatItem(id: "answer.text", kind: .message, text: completed, state: .done), at: Date())
            session.state = .done
            conversation.chat = Agents.shared.chat(of: session)
            conversation.live = false
            try await Task.sleep(for: .milliseconds(2200))
            try host.save("history-\(history)-send-finished")
            #expect(conversation.writing.filter { $0 }.count == 1, "completing the answer must not replay WriteOut: \(conversation.writing)")
            #expect(conversation.writing.last == false, "the completed answer must settle")
        }
    }

    @Test(.enabled("needs a farm test screen") { await TestScreen.available })
    func partialChunksAreNotWrittenOutASecondTime() async throws {
        let browser = Browser(windowID: UUID())
        let id = "partial-no-replay-" + UUID().uuidString
        Agents.shared.benchTask(id, state: .running)
        let session = try #require(Agents.shared.session(id))
        session.cli = "claude"
        defer { session.state = .done; browser.everyTab.forEach { $0.close() } }
        session.items.put(ChatItem(id: "q", kind: .asked, text: "Read the documents", state: .done), at: Date())
        let conversation = Conversation(Agents.shared.chat(of: session))
        let rendered = RenderedWords()
        let host = Host(Transcript(browser: browser, conversation: conversation)
            .onPreferenceChange(ChatWords.Rendered.self) { rendered.words = $0 })
        defer { host.close() }
        try await Task.sleep(for: .milliseconds(150))
        #expect(!host.typing.isEmpty)
        let chunk = String(repeating: "one more word ", count: 10)
        for _ in 0..<8 {
            session.items.grow("answer.text", by: chunk, at: Date())
            conversation.chat = Agents.shared.chat(of: session)
            try await Task.sleep(for: .milliseconds(120))
            host.view.layoutSubtreeIfNeeded()
        }
        #expect(host.typing.isEmpty, "the real partial answer replaced the typing indicator")
        #expect(!conversation.writing.contains(true), "partial chunks must not enter a second WriteOut")
        try host.save("partial-no-replay-running")
        let expected = String(repeating: chunk, count: 8)
        #expect(session.items.last?.text == expected)
        let index = try #require(session.items.lastIndex(where: { $0.id == "answer.text" }))
        session.items[index].state = .done
        session.state = .done
        conversation.chat = Agents.shared.chat(of: session)
        conversation.live = false
        let deadline = Date().addingTimeInterval(3)
        while !rendered.words.contains(expected), Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
            host.view.layoutSubtreeIfNeeded()
        }
        #expect(rendered.words.contains(expected), "the completed native view shows every received word")
        #expect(!conversation.writing.contains(true), "completion does not replay the stream")
        try host.save("partial-no-replay-finished")
    }

    final class RenderedWords { var words: Set<String> = [] }

    @MainActor final class Host {
        let view: NSHostingView<AnyView>
        let window: NSWindow
        init<V: View>(_ content: V) {
            view = NSHostingView(rootView: AnyView(content))
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 720), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            if let screen = TestScreen.screen {
                window.setFrameOrigin(NSPoint(x: screen.visibleFrame.minX + 32, y: screen.visibleFrame.maxY - 752))
            }
            window.orderFrontRegardless()
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
        }
        var typing: [NSView] {
            func find(_ view: NSView) -> [NSView] {
                (String(describing: type(of: view)) == "DotsView" ? [view] : []) + view.subviews.flatMap(find)
            }
            return find(view)
        }
        func pixels() throws -> [UInt8] {
            let size = view.bounds.size
            var pixels = [UInt8](repeating: 0, count: Int(size.width * size.height) * 4)
            try pixels.withUnsafeMutableBytes { buffer in
                let context = try #require(CGContext(data: buffer.baseAddress, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                    bytesPerRow: Int(size.width) * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
                context.translateBy(x: 0, y: size.height)
                context.scaleBy(x: 1, y: -1)
                (view.layer?.presentation() ?? view.layer)?.render(in: context)
            }
            return pixels
        }
        func image() throws -> CGImage {
            let layer = try #require(view.layer)
            let scale: CGFloat = 2
            let size = view.bounds.size
            let context = try #require(CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.translateBy(x: 0, y: size.height * scale)
            context.scaleBy(x: scale, y: -scale)
            (layer.presentation() ?? layer).render(in: context)
            return try ChatRevealEvidence.snapshot(context)
        }
        func save(_ name: String) throws {
            guard let out = ProcessInfo.processInfo.environment["YAB_FARM_OUT"], view.layer != nil else { return }
            let image = try image()
            let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            let folder = URL(fileURLWithPath: out).appendingPathComponent(ProcessInfo.processInfo.environment["CHAT_STABILITY_PHASE"] ?? "candidate")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: folder.appendingPathComponent(name + ".png"))
        }
        func close() { window.close() }
    }

    private var evidenceFolder: URL? {
        ProcessInfo.processInfo.environment["YAB_FARM_OUT"].map {
            URL(fileURLWithPath: $0).appendingPathComponent(ProcessInfo.processInfo.environment["CHAT_STABILITY_PHASE"] ?? "candidate")
        }
    }

    private func saveJSON(_ value: [String: Any], _ name: String) throws {
        guard let out = ProcessInfo.processInfo.environment["YAB_FARM_OUT"] else { return }
        let folder = URL(fileURLWithPath: out).appendingPathComponent(ProcessInfo.processInfo.environment["CHAT_STABILITY_PHASE"] ?? "candidate")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent(name + ".json"))
    }
}
