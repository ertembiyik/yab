import AppKit
import SwiftUI

// How a task ends at the foot of the page it worked on. Two kinds, as the
// action that started it says (Skills.Draft):
//
// A draft. The agent wrote it into the page's own field, a review into
// GitHub's Review changes, a reply into Gmail's composer, and stopped
// there: it is yours to read and change where it is. What stays is one line
// where the dock was: where the draft is, the agent's notes on it under ▴,
// Rewrite ⌘R, and the one dark button that sends it, ⌘↩.
//
// An answer. Something to read: a summary, a plan, what it found. A card
// with it drawn, headings, bullets and code, eight lines of it and the rest
// under Show All; under it the field to ask more, ⌘J to it, Copy ⌘C,
// and, when the page has a field of its own, Insert ⌘⇧V. Its dark button
// is Done ⌘↩, which puts it away, until words are typed to ask more: then
// the round arrow that sends them.
//
// A draft the agent couldn't put in the page comes as an answer whose one
// dark button is Insert.

enum AnswerKey: Hashable { case send, rewrite, insert, copy, ask, pick(Int) }

/// The card's keys. The window's key watcher asks here first, so while a
/// card offers ⌘R it is Rewrite rather than Reload, and while it doesn't,
/// every key is what it always is.
@MainActor
@Observable final class AnswerKeys {
    static let shared = AnswerKeys()

    /// What each tab's card answers to right now.
    @ObservationIgnored var offers: [UUID: Set<AnswerKey>] = [:]
    struct Press: Equatable {
        let tab: UUID
        let key: AnswerKey
        let at: Date
    }

    var pressed: Press?

    func take(_ event: NSEvent, in browser: Browser) -> Bool {
        guard let tab = browser.active, let offered = offers[tab.id], !offered.isEmpty else { return false }
        let bindings: [(Shortcut.Action, AnswerKey)] = [
            (.answerSend, .send), (.answerRewrite, .rewrite), (.answerInsert, .insert),
            (.answerCopy, .copy), (.answerAsk, .ask), (.answerPick1, .pick(1)),
            (.answerPick2, .pick(2)), (.answerPick3, .pick(3)),
        ]
        let which = bindings.first { Keymap.shared.matches(event, $0.0) }?.1
        guard let which, offered.contains(which) else { return false }
        // ⌘C over words picked in the field copies those words.
        if which == .copy, let editor = event.window?.firstResponder as? NSTextView, editor.selectedRange().length > 0 { return false }
        // And words picked in the page: asked of the page, which answers in
        // a moment, and the answer is copied only if nothing is picked there.
        if which == .copy, let web = tab.webKitOnly("WebKit selected-text helper", build: false), let responder = event.window?.firstResponder as? NSView,
           responder.isDescendant(of: web) {
            let id = tab.id
            PageView.readSelected(in: web) { [weak self, weak web] picked in
                MainActor.assumeIsolated {
                    if !picked.isEmpty, let web {
                        NSApp.sendAction(#selector(NSText.copy(_:)), to: web, from: nil)
                    } else {
                        self?.pressed = Press(tab: id, key: .copy, at: Date())
                    }
                }
            }
            return true
        }
        // Chromium's page: the same, through its own frames.
        if which == .copy, let page = tab.builtPage as? ChromiumPage, let responder = event.window?.firstResponder as? NSView,
           responder.isDescendant(of: page) {
            let id = tab.id
            Task { @MainActor [weak self, weak page] in
                let picked = await page?.agentSelectedWords() ?? ""
                if !picked.isEmpty, let page {
                    NSApp.sendAction(#selector(NSText.copy(_:)), to: page, from: nil)
                } else {
                    self?.pressed = Press(tab: id, key: .copy, at: Date())
                }
            }
            return true
        }
        pressed = Press(tab: tab.id, key: which, at: Date())
        return true
    }

    /// Whether a press was for this tab, and just now.
    func fresh(_ press: Press?, _ tab: Tab) -> AnswerKey? {
        guard let press, press.tab == tab.id, Date().timeIntervalSince(press.at) < 1 else { return nil }
        return press.key
    }
}

/// A task's answer, split: a draft it couldn't put in the page, between
/// <draft> and </draft>, and the rest.
private struct Said {
    let draft: String?
    let rest: String

    init(_ text: String) {
        if let open = text.range(of: "<draft>"), let close = text.range(of: "</draft>", range: open.upperBound..<text.endIndex) {
            draft = text[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            rest = (text[..<open.lowerBound] + text[close.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            draft = nil
            rest = text
        }
    }
}

struct AgentAnswer: View {
    var tab: Tab
    let session: String
    let text: String
    let draft: Skills.Draft?
    /// It can be asked more: the CLI gave its conversation an id.
    let threaded: Bool
    var embedded = false
    var sharedActions = false
    var onFieldChange: ((Bool) -> Void)? = nil

    var body: some View {
        let said = Said(text)
        if let draft, said.draft == nil {
            DraftLine(tab: tab, session: session, draft: draft, notes: said.rest, embedded: embedded)
        } else {
            AnswerCard(tab: tab, session: session, text: said.draft ?? said.rest, why: said.draft == nil ? nil : said.rest,
                       threaded: threaded, embedded: embedded, sharedActions: sharedActions,
                       onFieldChange: onFieldChange)
        }
    }

    static func canShareActions(text: String, draft: Skills.Draft?, threaded: Bool) -> Bool {
        draft == nil && Said(text).draft == nil && !threaded
    }

    /// What `rich` made of the last few texts: a card is drawn again at
    /// every key typed in its field, and Markdown isn't parsed again for it.
    private static var shaped = RichTextCache(costLimit: 1024 * 1024, countLimit: 128)

    /// Markdown's inline marks (bold, code, links), the lines kept; a
    /// heading is a bold line, a list's dash a bullet.
    static func rich(_ text: String) -> AttributedString {
        shaped.value(text) { shape(text) }
    }

    private static func shape(_ text: String) -> AttributedString {
        var fenced = false
        let lines = text.components(separatedBy: "\n").compactMap { line -> String? in
            let bare = line.trimmingCharacters(in: .whitespaces)
            // A fenced block: its lines as code, each kept a line (read
            // inline, the fence would be one span with its breaks gone).
            if bare.hasPrefix("```") { fenced.toggle(); return nil }
            if fenced {
                guard !line.isEmpty else { return "" }
                return line.contains("`") ? "`` " + line + " ``" : "`" + line + "`"
            }
            // A table: its rule gone, its cells set apart.
            if bare.hasPrefix("|"), bare.hasSuffix("|"), bare.count > 1 {
                let cells = bare.dropFirst().dropLast().split(separator: "|", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                if cells.allSatisfy({ !$0.isEmpty && $0.allSatisfy { "-:".contains($0) } }) { return nil }
                return cells.joined(separator: "   ")
            }
            if let hashes = bare.range(of: #"^#{1,6}\s+"#, options: .regularExpression) { return "**" + bare[hashes.upperBound...] + "**" }
            if let dash = line.range(of: #"^(\s*)[-*]\s+"#, options: .regularExpression) {
                let indent = line[..<dash.lowerBound] + String(line[dash].prefix { $0 == " " })
                return indent + "• " + line[dash.upperBound...]
            }
            return line
        }
        let shaped = lines.joined(separator: "\n")
        return (try? AttributedString(markdown: shaped, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    /// A button's words and the key that presses it.
    /// `holding`: words it may change to, whose width it keeps all along.
    static func label(_ words: String, _ action: Shortcut.Action, holding: String? = nil) -> some View {
        AnswerShortcutLabel(words: words, slot: Keymap.shared.slot(action), holding: holding)
    }

    /// The × that puts it away; Escape too.
    static func away(_ tab: Tab) -> some View {
        Button { tab.answer = nil } label: {
            Symbol("xmark", size: 9, weight: .semibold)
                .foregroundStyle(Palette.muted)
                .frame(width: ButtonSize.small.height, height: ButtonSize.small.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .keyTip("Put away", keys: "esc")
    }
}

private struct AnswerShortcutLabel: View {
    let words: String
    var slot: KeySlot
    var tint: Color? = nil
    var holding: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let holding {
                ZStack {
                    Text(holding).hidden()
                    Text(words)
                }
            } else if !words.isEmpty { Text(words) }
            if let keys = slot.keys?.text {
                KeyGlyphs(keys: keys, size: 11.5, tint: tint, rest: 0.6)
            }
        }
    }
}

// MARK: - a draft in the page

private struct DraftLine: View {
    var tab: Tab
    let session: String
    let draft: Skills.Draft
    let notes: String
    let embedded: Bool
    private var keys = AnswerKeys.shared
    @State private var open = false
    @State private var rewriting = false
    @State private var words = ""
    /// The line's own width, which the field keeps.
    @State private var width: CGFloat = 0
    @FocusState private var typing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if open, !notes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Notes for you, not in the draft")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                    Text(AgentAnswer.rich(notes))
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.ink)
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: 460, alignment: .leading)
                .padding(.bottom, CardFrame.inset)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if rewriting, words.isEmpty {
                picks
                    .padding(.bottom, CardFrame.inset)
                    .transition(.opacity)
            }
            // The field takes the line's place and its width: the line
            // stays laid out under it, unseen, so nothing moves.
            ZStack(alignment: .bottomLeading) {
                line
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                    // Gone at once, so the field fades in over nothing rather
                    // than through the buttons going.
                    .opacity(rewriting ? 0 : 1)
                    .animation(nil, value: rewriting)
                    .allowsHitTesting(!rewriting)
                if rewriting {
                    HStack(alignment: .bottom, spacing: 8) {
                        Composer(prompt: "What should change in the \(noun)?", text: $words, focus: $typing,
                                 send: { rewrite(words) }, cancel: { rewriting = false; words = "" })
                        SendArrow(lit: !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) { rewrite(words) }
                    }
                    .frame(width: width > 0 ? width : nil)
                    .onAppear { typing = true }
                    .transition(.opacity)
                }
            }
        }
        // As wide as its line: where the draft is and both buttons, whole.
        .frame(minWidth: 300, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .agentCardFrame(surface: !embedded)
        .animation(Motion.arrive, value: open)
        .animation(Motion.arrive, value: rewriting)
        .onAppear { offer() }
        .onChange(of: rewriting) { _, _ in offer() }
        .onChange(of: words.isEmpty) { _, _ in offer() }
        .onDisappear { keys.offers[tab.id] = nil }
        .onChange(of: keys.pressed, initial: true) { _, press in
            switch keys.fresh(press, tab) {
            case .send: send()
            case .rewrite: rewriting = true
            case .pick(let n) where DraftLine.picks.indices.contains(n - 1): rewrite(DraftLine.picks[n - 1].asked)
            default: break
            }
        }
    }

    private var line: some View {
        HStack(spacing: 8) {
            Symbol("checkmark", size: 11, weight: .semibold)
                .foregroundStyle(Palette.muted)
                .frame(width: 15)
            Text(draft.line)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .fixedSize()
            if !notes.isEmpty {
                Button { open.toggle() } label: {
                    HStack(spacing: 4) {
                        Text(count)
                        Symbol("chevron.up", size: 10, weight: .semibold)
                            .rotationEffect(.degrees(open ? 180 : 0))
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .fixedSize()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyTip(open ? "Hide the notes" : "What the agent noticed")
            }
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                Button { rewriting = true } label: { AgentAnswer.label("Rewrite", .answerRewrite) }
                    .buttonStyle(.yab(.secondary, .small))
                Button { send() } label: { AgentAnswer.label(draft.verb, .answerSend) }
                    .buttonStyle(.yab(.primary, .small, glass: true))
                AgentAnswer.away(tab)
            }
            .fixedSize()
        }
        .frame(height: ButtonSize.small.height)
    }

    /// "3 notes", when the notes are a list.
    private var count: String {
        let items = notes.components(separatedBy: "\n").filter { $0.range(of: #"^\s*([-*•]|\d+\.)\s"#, options: .regularExpression) != nil }.count
        return items == 0 ? "Notes" : items == 1 ? "1 note" : "\(items) notes"
    }

    /// The changes asked for most, one press each.
    static let picks: [(title: String, asked: String)] = [
        ("Shorter", "Make it shorter"), ("Warmer", "Make it warmer"), ("More direct", "Make it more direct"),
    ]

    private var picks: some View {
        HStack(spacing: 6) {
            ForEach(Array(DraftLine.picks.enumerated()), id: \.offset) { index, pick in
                Button { rewrite(pick.asked) } label: {
                    AgentAnswer.label(pick.title, Shortcut.numbered("answerPick", index + 1) ?? .answerPick1)
                }
                .buttonStyle(.yab(.secondary, .small))
            }
        }
    }

    /// What the draft is, from its line: "Review drafted" is a review.
    private var noun: String {
        (draft.line.split(separator: " ").first.map(String.init) ?? "draft").lowercased()
    }

    private func offer() {
        keys.offers[tab.id] = !rewriting ? [.send, .rewrite] : words.isEmpty ? [.pick(1), .pick(2), .pick(3)] : []
    }

    private func send() {
        Agents.shared.sendDraft(tab, session: session)
    }

    private func rewrite(_ asked: String) {
        let said = asked.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty else { return }
        Agents.shared.rewriteDraft(tab, session: session, said)
    }
}

// MARK: - an answer to read

private struct AnswerCard: View {
    var tab: Tab
    let session: String
    let text: String
    /// For a draft that couldn't go in the page: why, in a line.
    let why: String?
    let threaded: Bool
    let embedded: Bool
    let sharedActions: Bool
    let onFieldChange: ((Bool) -> Void)?
    private var keys = AnswerKeys.shared
    @State private var more = ""
    @State private var whole = false
    @State private var copiedAll = false
    /// The page has a field the answer could go in.
    @State private var field = false
    @FocusState private var typing: Bool

    private var loose: Bool { why != nil }
    /// What is drawn: a runaway answer is cut at twelve thousand letters so
    /// laying it out never holds the window. Copy still takes all of it.
    private var shown: String {
        text.utf8.count > 12_000 ? String(text.prefix(12_000)) + "\n\n…" : text
    }
    private var long: Bool { text.count > 560 || text.components(separatedBy: "\n").count > 8 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if loose, more.isEmpty {
                Text(AgentAnswer.rich(why.map { $0.isEmpty ? "A draft it couldn't put in the page" : $0 } ?? ""))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(2)
                    .padding(.bottom, 4)
            }
            if !more.isEmpty {
                // Asking about it: the answer folds to a line, so the field
                // stays by what it asks about.
                Text(AgentAnswer.rich(text.components(separatedBy: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""))
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
            } else if whole {
                ThreadScrollView { words.frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 260)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                words
                    .lineLimit(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if long {
                    Button("Show All") { whole = true }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                        .padding(.top, 4)
                }
            }
            // A page it saved or a download it made: the file itself, a
            // card under the words, never the steps to make it.
            let made = ChatItem.files(in: Agents.shared.session(session)?.items ?? [])
            if more.isEmpty, !made.isEmpty {
                ChatFileCards(paths: made)
                    .padding(.top, 8)
            }
            // What it put on the clipboard: Copy Again is the card's Copy.
            if more.isEmpty, let copied {
                ChatCopiedLine(what: copied.what, clip: copied.clip, button: false)
                    .padding(.top, 8)
            }
            Rectangle()
                .fill(Palette.hairline)
                .frame(height: 1)
                .padding(.vertical, CardFrame.inset)
            HStack(alignment: .bottom, spacing: 6) {
                if sharedActions {
                    Spacer(minLength: 0)
                    Color.clear.frame(width: 1, height: ButtonSize.regular.height)
                } else if threaded {
                    Composer(prompt: loose ? "What should change in the draft?" : "Ask a follow-up", text: $more, focus: $typing,
                             send: follow, cancel: { tab.answer = nil })
                        // The key to it right after its words, as if part
                        // of them: the placeholder laid out unseen, ⌘J past it.
                        .overlay(alignment: .leading) {
                            if !typing, more.isEmpty {
                                HStack(spacing: 6) {
                                    Text(loose ? "What should change in the draft?" : "Ask a follow-up")
                                        .font(.system(size: 12.5))
                                        .hidden()
                                    AnswerShortcutLabel(words: "", slot: Keymap.shared.slot(.answerAsk), tint: Palette.faint)
                                }
                                .allowsHitTesting(false)
                            }
                        }
                } else {
                    Spacer(minLength: 0)
                }
                if !sharedActions {
                    if loose {
                        copy
                        Button { insert() } label: { AgentAnswer.label("Insert", .answerSend) }
                            .buttonStyle(.yab(.primary, .small, glass: true))
                    } else {
                        if field {
                            Button { insert() } label: { AgentAnswer.label("Insert", .answerInsert) }
                                .buttonStyle(.yab(.secondary, .small))
                        }
                        copy
                    }
                    if threaded {
                        if !loose, more.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Button { tab.answer = nil } label: { AgentAnswer.label("Done", .answerSend) }
                                .buttonStyle(.yab(.primary, .small, glass: true))
                                .transition(.opacity.combined(with: .scale(scale: 0.6, anchor: .trailing)))
                        } else {
                            SendArrow(lit: !more.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, action: follow)
                                .transition(.opacity.combined(with: .scale(scale: 0.6)))
                        }
                    } else if !loose {
                        Button { tab.answer = nil } label: { AgentAnswer.label("Done", .answerSend) }
                            .buttonStyle(.yab(.primary, .small, glass: true))
                    } else {
                        AgentAnswer.away(tab)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 496, alignment: .leading)
        .agentCardFrame(surface: !embedded)
        // Escape puts it away, wherever the keys are: there is no ×
        // beside the field.
        .background {
            Button("") { tab.answer = nil }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .allowsHitTesting(false)
        }
        .animation(Motion.arrive, value: whole)
        .animation(Motion.arrive, value: more.isEmpty)
        .onAppear {
            // The field doesn't take the keys on its own: a text field that
            // becomes first responder brings macOS's input indicator with it,
            // a window ordered in and out, and with the card coming in that
            // held the window up to seconds on a busy Mac. A click, or ⌘J,
            // the key that asked in the first place.
            AgentPage.run(tab, AgentPage.field, ["text": NSNull()]) { result in
                if case .success(let value) = result { field = value as? Bool == true }
                offer()
            }
            offer()
        }
        .onChange(of: typing) { _, _ in offer() }
        .onChange(of: asking) { _, _ in offer() }
        .onChange(of: field) { _, now in offer(); onFieldChange?(now) }
        .onDisappear { keys.offers[tab.id] = nil }
        .onChange(of: keys.pressed, initial: true) { _, press in
            switch keys.fresh(press, tab) {
            case .copy: copyAll()
            case .ask: typing = true
            case .send where finishing: tab.answer = nil
            case .insert, .send: insert()
            default: break
            }
        }
    }

    private var words: some View {
        Text(AgentAnswer.rich(shown))
            .font(.system(size: 12.5))
            .foregroundStyle(Palette.ink)
            .lineSpacing(2)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var copy: some View {
        if let clip = copied?.clip, AgentClips.shared.clip(clip) != nil {
            ChatCopyAgain(clip: clip)
        } else {
            Button { copyAll() } label: { AgentAnswer.label(copiedAll ? "Copied" : "Copy", .answerCopy, holding: "Copied") }
                .buttonStyle(.yab(.secondary, .small))
        }
    }

    /// What the answer's turn put on the clipboard (copy), if it did.
    private var copied: (what: String, clip: String?)? {
        ChatItem.copied(in: Array(ChatItem.lastTurn(Agents.shared.session(session)?.items ?? [])))
    }

    /// Words typed to ask more: the arrow sends them, and Done waits.
    private var asking: Bool { !more.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// Its dark button is Done.
    private var finishing: Bool { !loose && !asking && !sharedActions }

    private func offer() {
        var keys: Set<AnswerKey> = []
        // ⌘C is the page's while the page has the keys, unless the turn
        // copied something: then it copies that again, words picked in the
        // page still the page's (AnswerKeys.take).
        if typing || copied?.clip != nil { keys.insert(.copy) }
        if !typing, threaded { keys.insert(.ask) }
        if loose { keys.insert(.send); keys.insert(.insert) } else if field { keys.insert(.insert) }
        if finishing { keys.insert(.send) }
        self.keys.offers[tab.id] = keys
    }

    private func copyAll() {
        // A turn that copied something: ⌘C copies that again.
        if let clip = copied?.clip, AgentClips.shared.pressAgain(clip) { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedAll = true
    }

    private func follow() {
        let said = more.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty else { return }
        if loose { Agents.shared.rewriteDraft(tab, session: session, said) } else { Agents.shared.follow(tab, session: session, said) }
    }

    /// Into the field the page is typing in, or its first one: the page
    /// takes it as typed, and the card goes.
    private func insert() {
        AgentPage.run(tab, AgentPage.field, ["text": text]) { result in
            if case .success(let value) = result, value as? Bool == true {
                tab.page.window?.makeFirstResponder(tab.page)
                tab.answer = nil
            } else {
                Agents.shared.browser?.toaster.pop("Click a field first", mark: "character.cursor.ibeam")
            }
        }
    }
}

// MARK: - what the card asks of the task

extension Agents {
    /// A follow-up in the same task, in the same tab.
    func follow(_ tab: Tab, session: String, _ said: String) {
        guard let known = self.session(session) else { return }
        let next = run(prompt: said, cli: known.cli, access: known.full ? nil : "browser", resume: session)
        if !tab.bench {
            tab.allowed.insert(next.id)
            tab.guest = next.id
        }
        tab.answer = nil
    }

    /// Send pressed on a draft: the agent presses the page's own button,
    /// and that press needs no second yes.
    func sendDraft(_ tab: Tab, session: String) {
        guard let known = self.session(session), let draft = known.draft else { return }
        known.sending = true
        known.sendOnce = Date()
        follow(tab, session: session, """
        The user read your draft as it stands in the page now (they may have changed it) and pressed \
        \(draft.verb). Send it now with the page's own button, exactly as it is in the field: don't change a \
        word, and leave any choice beside it as it is. Then answer with the one word Sent, or, if it didn't \
        go, one line on why.
        """)
    }

    /// Rewrite, with what to change: the same field, a new draft.
    func rewriteDraft(_ tab: Tab, session: String, _ said: String) {
        guard self.session(session) != nil else { return }
        follow(tab, session: session, """
        Rewrite the draft you left in the page: \(said). Replace what is in the field with the new draft; \
        don't send it. Finish as before: short notes for the user, a dash each, not the draft.
        """)
    }
}

extension AgentPage {
    /// Whether the page has a field to put words in: the one being typed
    /// in, or else its first one of a size in view. With `text`, puts it
    /// there as typing would.
    static let field = """
    const ok = e => e && e.isConnected && !e.disabled && !e.readOnly && e.getClientRects().length > 0 &&
      (e.tagName === 'TEXTAREA' || e.isContentEditable || (e.tagName === 'INPUT' && /^(text|search|email|url|)$/.test(e.type)));
    let el = document.activeElement;
    if (!ok(el)) {
      el = [...document.querySelectorAll('textarea,[contenteditable=""],[contenteditable="true"],[role=textbox]')]
        .find(e => ok(e) && e.getBoundingClientRect().height >= 28) || null;
    }
    if (!el) return false;
    if (text == null) return true;
    el.focus();
    el.scrollIntoView({ block: 'center' });
    if (!document.execCommand('insertText', false, text)) {
      if ('value' in el) { el.value += text; el.dispatchEvent(new Event('input', { bubbles: true })); }
      else { el.textContent += text; }
    }
    return true;
    """
}

// MARK: - the field

/// The card's own field. It has no box: the card is the box, and the
/// words stand where the card's line stood, the whole width theirs. What
/// they are for is in the placeholder. Return sends; it grows upward to
/// four lines.
private struct Composer: View {
    let prompt: String
    @Binding var text: String
    var focus: FocusState<Bool>.Binding
    let send: () -> Void
    let cancel: () -> Void

    var body: some View {
        TextField(prompt, text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .foregroundStyle(Palette.ink)
            .lineLimit(1...4)
            .focused(focus)
            .onSubmit(send)
            .onExitCommand(perform: cancel)
            .font(.system(size: 12.5))
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, minHeight: ButtonSize.small.height, alignment: .leading)
    }
}

/// A round arrow, lit once there is something to send.
private struct SendArrow: View {
    let lit: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Symbol("arrow.up", size: 11, weight: .bold)
                .foregroundStyle(lit ? Palette.ground : Palette.muted)
                .frame(width: ButtonSize.small.height, height: ButtonSize.small.height)
                .background(Circle().fill(lit ? Palette.ink : Palette.wash))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!lit)
        .keyTip("Send", keys: "↩")
        .animation(.easeOut(duration: 0.12), value: lit)
    }
}
