import AppKit
import SwiftUI
import Testing
@testable import Fast

@Suite(.serialized) @MainActor
struct SidebarTypographyTests {
    @Test func detachedPopoverTextTracksSidebarSizeWithoutReopening() async throws {
        let state = SidebarSizeProbe()
        let host = NSHostingView(rootView: PopoverFontProbe(state: state))
        host.frame = NSRect(x: 0, y: 0, width: 260, height: 64)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        defer { window.orderOut(nil) }

        func fields(in view: NSView) -> [NSTextField] {
            if let field = view as? NSTextField { return [field] }
            return view.subviews.flatMap { fields(in: $0) }
        }

        var original: [NSTextField] = []
        for (size, scale) in [(SidebarRowSize.medium, 1.0), (.large, 16.0 / 14), (.small, 13.0 / 14), (.medium, 1.0)] {
            state.size = size
            for _ in 0..<100 {
                host.layoutSubtreeIfNeeded()
                let actual = fields(in: host).compactMap { $0.font?.pointSize }.sorted()
                if actual.count == 2, abs(actual[0] - 11 * scale) < 0.01,
                   abs(actual[1] - 12.5 * scale) < 0.01 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let editors = fields(in: host)
            let actual = editors.compactMap { $0.font?.pointSize }.sorted()
            #expect(actual.count == 2)
            if actual.count == 2 {
                #expect(abs(actual[0] - 11 * scale) < 0.01)
                #expect(abs(actual[1] - 12.5 * scale) < 0.01)
            }
            if !original.isEmpty { #expect(editors.elementsEqual(original, by: { $0 === $1 })) }
            original = editors
        }
    }

    @Test func sidebarPreferenceUpdatesExistingNativeEditor() async throws {
        let nest = Nest(name: "A/B test math and New Folder")
        let state = SidebarSizeProbe()
        let host = NSHostingView(rootView: SidebarEditorProbe(nest: nest, state: state))
        host.frame = NSRect(x: 0, y: 0, width: 260, height: 64)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        defer { window.orderOut(nil) }

        func field(in view: NSView) -> NSTextField? {
            if let text = view as? NSTextField { return text }
            return view.subviews.lazy.compactMap { field(in: $0) }.first
        }

        var original: NSTextField?
        let sizes: [(SidebarRowSize, CGFloat)] = [(.medium, 14), (.large, 16), (.small, 13), (.medium, 14)]
        for (size, points) in sizes {
            state.size = size
            for _ in 0..<100 {
                host.layoutSubtreeIfNeeded()
                if field(in: host)?.font?.pointSize == points { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let editor = try #require(field(in: host))
            #expect(editor.font?.pointSize == points)
            #expect(editor.stringValue == nest.name)
            #expect(editor.intrinsicContentSize.height <= 28)
            if let original { #expect(editor === original) }
            original = editor
        }

        // Outside the sidebar the same shared native field stays compact.
        let strip = NSHostingView(rootView: NestNameField(nest: nest).frame(width: 260, height: 28))
        strip.layoutSubtreeIfNeeded()
        #expect(try #require(field(in: strip)).font?.pointSize == 12.5)
    }
}

private struct PopoverFontProbe: View {
    var state: SidebarSizeProbe

    var body: some View {
        VStack {
            TextField("", text: .constant("Recent here"))
                .sidebarFont(size: 12.5)
            TextField("", text: .constant("Yesterday"))
                .sidebarFont(size: 11)
        }
        .textFieldStyle(.plain)
        .environment(\.sidebarRowSize, state.size)
    }
}

@MainActor @Observable private final class SidebarSizeProbe {
    var size: SidebarRowSize = .medium
}

private struct SidebarEditorProbe: View {
    let nest: Nest
    var state: SidebarSizeProbe

    var body: some View {
        VStack(spacing: 4) {
            NestNameField(nest: nest).frame(height: 28)
            Quiet(icon: "plus", title: "New tab") {}
        }
        .modifier(SidebarTypography())
        .environment(\.sidebarRowSize, state.size)
    }
}
