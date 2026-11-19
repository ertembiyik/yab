import AppKit
import SwiftUI

// Console's prompt, as Chromium's: one line that grows as it is written,
// Return runs it, ⇧Return goes to a new line, ↑ and ↓ go back through what
// was run, Tab and → take the completion shown, names completed from the
// page's own objects and from history; under it what it would answer, when
// what is typed only reads.

/// The views that keep the keyboard in the Developer Tools card: Escape
/// there opens the drawer, ⌘K clears, ⇧⌘P runs a command.
protocol DevKeyTarget: AnyObject {}

final class PromptTextView: NSTextView, DevKeyTarget {
    /// Its typing undone in the prompt and gone with it, never left in the
    /// window's undo after the prompt is freed (crash #64, AddressEditor).
    private let edits = UndoManager()
    override var undoManager: UndoManager? { edits }
    @objc func undo(_ sender: Any?) { edits.undo() }
    @objc func redo(_ sender: Any?) { edits.redo() }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): return edits.canUndo
        case #selector(redo(_:)): return edits.canRedo
        default: return super.validateUserInterfaceItem(item)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let browser = BrowserWindows.shared.browser(for: window), DevKeys.take(event, browser: browser) { return true }
        return super.performKeyEquivalent(with: event)
    }
    /// Return, ⇧Return, Tab, ↑, ↓, Escape and → as the prompt takes them:
    /// true when taken.
    var take: ((PromptKey) -> Bool)?
    var changed: ((String) -> Void)?
    var attached: ((PromptTextView) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { attached?(self) }
    }

    enum PromptKey { case enter, newline, tab, up, down, escape, right }

    override func doCommand(by selector: Selector) {
        let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
        let key: PromptKey? = {
            switch selector {
            case #selector(insertNewline(_:)): return shift ? .newline : .enter
            case #selector(insertNewlineIgnoringFieldEditor(_:)): return .newline
            case #selector(insertTab(_:)): return .tab
            case #selector(moveUp(_:)): return .up
            case #selector(moveDown(_:)): return .down
            case #selector(cancelOperation(_:)): return .escape
            case #selector(moveRight(_:)): return selectedRange().location == string.utf16.count ? .right : nil
            default: return nil
            }
        }()
        if let key, take?(key) == true { return }
        if key == .newline { insertText("\n", replacementRange: selectedRange()); return }
        super.doCommand(by: selector)
    }

    override func didChangeText() {
        super.didChangeText()
        changed?(string)
    }

    /// The caret on the first line, or the last.
    var onFirstLine: Bool { !string.prefix(selectedRange().location).contains("\n") }
    var onLastLine: Bool { !string.dropFirst(min(string.count, selectedRange().location)).contains("\n") }
}

struct ConsolePromptView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let take: (PromptTextView.PromptKey, PromptTextView) -> Bool

    /// The prompt last made, for a click on the messages to give it the keyboard.
    nonisolated(unsafe) static weak var latest: PromptTextView?

    @MainActor private static let prompts = NSHashTable<PromptTextView>.weakObjects()

    @MainActor static func focusLatest(in window: NSWindow?) {
        guard let window else { return }
        let view = latest?.window === window ? latest : prompts.allObjects.first { $0.window === window }
        if let view { window.makeFirstResponder(view) }
    }

    /// The prompt's own scroller, which hands the wheel to the list it
    /// stands in while all its lines are in sight: over the prompt the
    /// messages scroll as over any line of them.
    final class PromptScrollView: NSScrollView {
        override func scrollWheel(with event: NSEvent) {
            let lines = documentView?.frame.height ?? 0
            if lines <= contentView.bounds.height + 0.5, let list = superview?.enclosingScrollView {
                list.scrollWheel(with: event)
            } else {
                super.scrollWheel(with: event)
            }
        }
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = PromptScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.borderType = .noBorder
        let view = PromptTextView()
        AppleWritingTools.shared.apply(to: view)
        view.isRichText = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.font = DevMono.nsFont(11.5, weight: .regular)
        view.textColor = .labelColor
        view.insertionPointColor = .controlAccentColor
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.textContainerInset = NSSize(width: 0, height: 2)
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.minSize = NSSize(width: 0, height: 19)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 19)
        view.autoresizingMask = [.width]
        view.setAccessibilityLabel("Console prompt")
        scroll.documentView = view
        Self.latest = view
        Self.prompts.add(view)
        view.attached = { view in view.window?.makeFirstResponder(view) }
        context.coordinator.view = view
        view.changed = { [weak coordinator = context.coordinator] text in coordinator?.changed(text) }
        view.take = { [weak coordinator = context.coordinator] key in coordinator?.take(key) ?? false }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? PromptTextView else { return }
        if view.string != text {
            view.string = text
            view.setSelectedRange(NSRange(location: text.utf16.count, length: 0))
            context.coordinator.measure()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        let size = CGSize(width: max(0, proposal.width ?? 400), height: height)
        nsView.documentView?.setFrameSize(size)
        (nsView.documentView as? NSTextView)?.textContainer?.containerSize = NSSize(width: size.width, height: CGFloat.greatestFiniteMagnitude)
        return size
    }

    @MainActor final class Coordinator {
        var parent: ConsolePromptView
        weak var view: PromptTextView?

        init(parent: ConsolePromptView) { self.parent = parent }

        func changed(_ text: String) {
            if parent.text != text { parent.text = text }
            measure()
        }

        func take(_ key: PromptTextView.PromptKey) -> Bool {
            guard let view else { return false }
            return parent.take(key, view)
        }

        /// As tall as its lines, up to ten.
        func measure() {
            guard let view, let layout = view.layoutManager, let container = view.textContainer else { return }
            layout.ensureLayout(for: container)
            let lines = max(1, min(10, Int((layout.usedRect(for: container).height / 15).rounded(.up))))
            let height = CGFloat(lines) * 15 + 4
            if abs(parent.height - height) > 0.5 { DispatchQueue.main.async { self.parent.height = height } }
        }
    }
}

struct ConsolePrompt: View {
    let browser: Browser
    var log: ConsoleLog
    var panel: ConsolePanel
    var prefs: ConsolePrefs
    /// How tall the list it stands at the end of is on screen.
    let viewport: CGFloat
    /// Scrolls the list down to it, for typing while it is out of sight.
    let reveal: () -> Void
    /// Where it stands in the list as shown (ConsoleMessages.space).
    @State private var place = Place(below: true, seen: true)
    @State private var text = ""
    @State private var height: CGFloat = 19
    @State private var completions: [String] = []
    @State private var typed = ""
    @State private var picked = 0
    @State private var eager = ""
    @State private var eagerValue: ConsoleValue?
    /// Where ↑ has gone back to in the history; nil at the line being written.
    @State private var back: Int?
    @State private var draft = ""
    @State private var asked = 0
    /// The words were put back, not typed: no completions asked for them.
    @State private var restored = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 6) {
                Text("›").font(DevMono.font(13, weight: .bold)).foregroundStyle(Color.accentColor).padding(.top, -1)
                ConsolePromptView(text: $text, height: $height) { key, view in take(key, view) }
                    .frame(height: height)
                    .frame(minWidth: 0, maxWidth: .infinity)
            }
            if !eager.isEmpty {
                Text(eager)
                    .font(DevMono.font(11.5))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, 16)
            }
        }
        .padding(.horizontal, DevLook.padding)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Only what changes the drawing: the side with room for the
        // completions and whether it is in sight, not every scrolled point.
        .onGeometryChange(for: Place.self) { proxy in
            let frame = proxy.frame(in: .named(ConsoleMessages.space))
            let under = viewport - frame.maxY
            return Place(below: under >= Self.listMost || under > frame.minY, seen: frame.minY >= 0 && frame.maxY <= viewport + 0.5)
        } action: { place = $0 }
        // Chrome's: under the line while there is room, as with the prompt
        // under the toolbar, over it at the bottom of a full panel.
        .overlay(alignment: place.below ? .bottomLeading : .topLeading) {
            if !completions.isEmpty {
                let height = CGFloat(min(completions.count, 8)) * 18 + 8
                completionList
                    .offset(x: 26, y: place.below ? height : -height)
            }
        }
        .onAppear {
            // Made anew (the card back with its tab, Console picked again):
            // what was typed and not run is still there, as in Chromium.
            if text.isEmpty, !panel.draft.isEmpty { restored = true; text = panel.draft }
            DispatchQueue.main.async { ConsolePromptView.focusLatest(in: browser.devWindow) }
        }
        .onChange(of: text) {
            panel.draft = text
            if restored { restored = false; return }
            if !place.seen, !text.isEmpty { reveal() }
            refresh()
        }
        // Another tab's words put back while the prompt stayed.
        .onChange(of: panel.draftLoaded) {
            guard text != panel.draft else { return }
            back = nil
            completions = []
            eager = ""
            restored = true
            text = panel.draft
        }
        .onChange(of: completions) { panel.completing = !completions.isEmpty }
        .onChange(of: panel.prefill, initial: true) {
            guard let words = panel.prefill else { return }
            text = words
            panel.prefill = nil
            ConsolePromptView.focusLatest(in: browser.devWindow)
        }
        .onChange(of: panel.focusPrompt, initial: true) {
            if panel.focusPrompt { ConsolePromptView.focusLatest(in: browser.devWindow); panel.focusPrompt = false }
        }
    }

    struct Place: Equatable {
        var below: Bool
        var seen: Bool
    }

    /// The completion list at its tallest: eight rows and its inset.
    static let listMost: CGFloat = 8 * 18 + 8

    private var completionList: some View {
        ScrollViewReader { reader in
            ThreadScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(completions.enumerated()), id: \.offset) { index, name in
                        HStack(spacing: 0) {
                            Text(typed).fontWeight(.semibold)
                            Text(String(name.dropFirst(typed.count)))
                        }
                        .font(DevMono.font(11.5))
                        .foregroundStyle(index == picked ? Color.white : Palette.ink)
                        .padding(.horizontal, 8)
                        .frame(height: 18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(index == picked ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
                        .id(index)
                        .onTapGesture { picked = index; accept() }
                    }
                }
                .padding(4)
            }
            .frame(width: 260, height: CGFloat(min(completions.count, 8)) * 18 + 8)
            .onChange(of: picked) { reader.scrollTo(picked) }
        }
        .cardFrame()
    }

    private func take(_ key: PromptTextView.PromptKey, _ view: PromptTextView) -> Bool {
        switch key {
        case .enter:
            if !completions.isEmpty, picked < completions.count, completions[picked] != typed { accept(); return true }
            let line = text
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
            completions = []
            eager = ""
            back = nil
            text = ""
            browser.consoleRun(line)
            return true
        case .newline:
            return false
        case .tab, .right:
            guard !completions.isEmpty else { return key == .tab }
            accept()
            return true
        case .up:
            if !completions.isEmpty { picked = (picked + completions.count - 1) % completions.count; return true }
            guard view.onFirstLine, !prefs.history.isEmpty else { return false }
            if back == nil { draft = text; back = prefs.history.count }
            back = max(0, (back ?? 0) - 1)
            set(prefs.history[back ?? 0])
            return true
        case .down:
            if !completions.isEmpty { picked = (picked + 1) % completions.count; return true }
            guard view.onLastLine, let at = back else { return false }
            if at + 1 >= prefs.history.count { back = nil; set(draft) } else { back = at + 1; set(prefs.history[at + 1]) }
            return true
        case .escape:
            if !completions.isEmpty { completions = []; return true }
            return false
        }
    }

    private func set(_ line: String) {
        text = line
        completions = []
    }

    private func accept() {
        guard picked < completions.count else { return }
        let name = completions[picked]
        let rest = String(name.dropFirst(typed.count))
        // A name that isn't an identifier goes in brackets: obj['a-b'].
        if name.range(of: #"^[A-Za-z_$][\w$]*$"#, options: .regularExpression) == nil, text.hasSuffix("." + typed) {
            text = String(text.dropLast(typed.count + 1)) + "[" + quoted(name) + "]"
        } else {
            text += rest
        }
        completions = []
    }

    private func quoted(_ name: String) -> String {
        (try? String(data: JSONSerialization.data(withJSONObject: [name]), encoding: .utf8)).map { String($0.dropFirst().dropLast()) } ?? "'\(name)'"
    }

    /// What the line would complete to, and what it would answer.
    private func refresh() {
        asked += 1
        let ask = asked
        let line = text
        // The completion: names after the last dot of what is being written.
        let tail = line.range(of: #"([A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*|\[[^\]]*\]|\(\))*)\.([\w$]*)$|([A-Za-z_$][\w$]*)$"#, options: .regularExpression)
        if let tail, !line.isEmpty {
            let piece = String(line[tail])
            let dot = piece.lastIndex(of: ".")
            let base = dot.map { String(piece[..<$0]) } ?? ""
            let prefix = dot.map { String(piece[piece.index(after: $0)...]) } ?? piece
            if base.isEmpty || base.range(of: #"^[A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)*$"#, options: .regularExpression) != nil {
                browser.wire("console.complete", ["base": base, "prefix": prefix, "ctx": panel.context]) { raw in
                    guard ask == asked else { return }
                    var names = (raw as? [String] ?? [])
                    if base.isEmpty {
                        names += ["$", "$$", "$x", "$0", "$_", "clear", "copy", "dir", "dirxml", "inspect", "keys", "values", "getEventListeners",
                                  "monitorEvents", "unmonitorEvents", "queryInstances", "queryHolders", "screenshot", "table", "profile", "profileEnd",
                                  "await", "function", "const", "let", "var", "typeof", "instanceof", "new", "this", "true", "false", "null", "undefined"]
                        if prefs.historyCompletion { names += prefs.history.filter { $0.hasPrefix(prefix) && $0 != prefix } }
                    }
                    let unique = Array(Set(names))
                    let starts = unique.filter { $0.hasPrefix(prefix) && $0 != prefix }.sorted { ConsolePrompt.rank($0) < ConsolePrompt.rank($1) || (ConsolePrompt.rank($0) == ConsolePrompt.rank($1) && $0 < $1) }
                    let loose = unique.filter { !$0.hasPrefix(prefix) && $0.lowercased().hasPrefix(prefix.lowercased()) }.sorted()
                    typed = prefix
                    completions = prefix.isEmpty && base.isEmpty ? [] : Array((starts + loose).prefix(60))
                    picked = 0
                }
            } else {
                completions = []
            }
        } else {
            completions = []
        }
        // What it would answer: only what reads.
        guard prefs.eager, !line.isEmpty, ConsoleEager.safe(line) else { eager = ""; eagerValue = nil; return }
        browser.wire("console.eager", ["expr": line, "ctx": panel.context]) { raw in
            guard ask == asked else { return }
            if let raw = raw as? [String: Any] {
                let value = ConsoleValue(json: raw)
                eagerValue = value
                eager = ConsoleFormat.plainValue(value, top: false)
            } else {
                eager = ""
                eagerValue = nil
            }
        }
    }

    /// Own names before Object.prototype's, _private and $ helpers last.
    static func rank(_ name: String) -> Int {
        if name.hasPrefix("__") { return 3 }
        if ["constructor", "hasOwnProperty", "isPrototypeOf", "propertyIsEnumerable", "toLocaleString", "toString", "valueOf"].contains(name) { return 2 }
        if name.hasPrefix("_") || name.hasPrefix("$") { return 1 }
        return 0
    }
}
