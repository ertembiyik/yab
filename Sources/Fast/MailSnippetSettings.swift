import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings › Snippets (docs/snippets.md), a page of its own beside Mail:
/// whether ";" and a name work in a page's boxes, whether what is pasted
/// often is offered as a snippet, and the list.
struct SnippetsPage: View {
    @AppStorage(SnippetSettings.semicolonKey, store: Store.settings) private var semicolon = true
    @AppStorage(SnippetSettings.offerKey, store: Store.settings) private var offers = true

    var body: some View {
        PageHero(page: .snippets)
        Section {
            SettingsRow("Type ; and a name in any box", detail: "Show matching snippets as you type. Excludes password fields and code editors.") {
                Toggle(SettingsWords.text("Type ; and a name in any box"), isOn: $semicolon)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .settingsAnchor("snippets-semicolon")
            SettingsRow("Offer to keep what you paste often", detail: "Suggest a snippet after repeated pastes in a week. Stores only a content digest on this Mac.") {
                Toggle(SettingsWords.text("Offer to keep what you paste often"), isOn: $offers)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .settingsAnchor("snippets-offer")
        }
        MailSnippetList()
    }
}

/// The snippets, as Settings › Search lays out its sites: what each says on
/// the left, its key, and in the column its name, what ";" takes, typed
/// straight into its cell to rename it. A click on its words opens it to
/// change everything else; New Snippet… makes one; a right click deletes.
/// Most used first.
struct MailSnippetList: View {
    private var snippets = MailSnippets.shared
    private var snippetKey = Keymap.shared.slot(.snippets)
    private var editing: SnippetEditing { SnippetEditing.shared }

    var body: some View {
        Section {
            ForEach(snippets.ordered) { snippet in
                MailSnippetRow(snippet: snippet) { editing.open(snippet) }
                    .settingsAnchor("mail-snippet:" + snippet.id)
            }
            if snippets.all.isEmpty {
                SnippetSourceRows()
            }
        } header: {
            HStack(spacing: 8) {
                Text(SettingsWords.text("Snippets"))
                Spacer()
                SnippetBringMenu()
                Button("New Snippet…") { editing.open(nil) }
                    .settingsButton()
            }
            .textCase(nil)
            .settingsAnchor("snippets-list")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                SettingsText("Type ; and a snippet’s name in any box, or press \(snippetKey.keys?.settingsHint ?? "the assigned shortcut") for all of them.", size: 11)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Use {date} and {clipboard} in any field; {first_name}, {name} and {my_name} in mail. {{place}} creates an editable placeholder. Right-click to delete.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A snippet being changed, or a new one (nil).
struct MailSnippetEditing: Identifiable {
    let id = UUID()
    let snippet: MailSnippet?
    /// A new one's start, the bench's way to open it for a mail.
    var draft: MailSnippet?
}

/// The editor open over Settings' pane, or none. Not a sheet: AppKit's
/// sheet slid down for a quarter of a second and pictured the whole
/// Settings window for its dimming on every step (evals/snippets/editor.py,
/// 350 ms to see it, 620 ms cold), where this is up in the next frame.
@MainActor
@Observable final class SnippetEditing {
    static let shared = SnippetEditing()
    var card: MailSnippetEditing?
    /// The bench's click on Hotkey: its recorder starts listening.
    var listen = false

    func open(_ snippet: MailSnippet?, draft: MailSnippet? = nil) {
        card = MailSnippetEditing(snippet: snippet, draft: draft)
    }

    func close() {
        card = nil
        bring = nil
        reading = nil
        listen = false
    }

    /// The agent reading Superhuman's snippets, until they are on the card.
    var reading: Agents.Session?
    /// What it says it is doing now.
    var readingNow = ""

    /// Another app's snippets on the card, before they come in.
    var bring: SnippetBringing?
    /// The ones just brought in, lit in the list for a moment.
    var fresh: Set<String> = []

    func bring(_ source: SnippetSource, from place: String, found: [FoundSnippet]) {
        card = nil
        bring = SnippetBringing(source: source, from: place, found: MailSnippets.shared.planned(found))
    }

    func brought(_ ids: [String]) {
        bring = nil
        fresh = Set(ids)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            withAnimation(Motion.arrive) { self?.fresh = [] }
        }
    }
}

/// The editor over Settings' pane: the page dimmed under it, a click there or esc going back.
struct SnippetCardLayer: View {
    private var editing = SnippetEditing.shared

    var body: some View {
        ZStack {
            if let card = editing.card {
                MailSnippetEditor(snippet: card.snippet, draft: card.draft) { editing.close() }
                    .frame(maxWidth: 760, maxHeight: 500)
                    .padding(24)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.97).combined(with: .opacity).animation(Motion.arrive),
                        removal: .identity
                    ))
                    .id(card.id)
            } else if let bring = editing.bring {
                SnippetBringCard(bringing: bring)
                    .frame(maxWidth: 560, maxHeight: 460)
                    .padding(24)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.97).combined(with: .opacity).animation(Motion.arrive),
                        removal: .identity
                    ))
                    .id(bring.id)
            } else if editing.reading != nil {
                Color.black.opacity(0.12)
                    .contentShape(Rectangle())
                    .transition(.asymmetric(insertion: .opacity.animation(Motion.arrive), removal: .identity))
                SnippetReadingCard(now: editing.readingNow)
                    .frame(maxWidth: 460)
                    .padding(24)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.97).combined(with: .opacity).animation(Motion.arrive),
                        removal: .identity
                    ))
            }
        }
    }
}

/// One snippet: what it says, the files it brings, and its name in the
/// column, a cell to rename it in. A name another snippet has is refused
/// on a card under the cell, as an alias another site has is.
private struct MailSnippetRow: View {
    let snippet: MailSnippet
    let edit: () -> Void
    @State private var name = ""
    @State private var hovering = false
    @FocusState private var typing: Bool
    @State private var refused: String?
    @State private var glow: Glow?
    /// Lit for a moment when it has just been brought in.
    private var editing = SnippetEditing.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 12) {
            Button(action: edit) {
                HStack(spacing: 8) {
                    Text(snippet.gist.isEmpty ? "No words" : snippet.gist)
                        .foregroundStyle(snippet.gist.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                    if snippet.mailOnly {
                        Text([snippet.whereSaid, snippet.filesSaid].filter { !$0.isEmpty }.joined(separator: " · "))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Edits \(snippet.name)")
            ShortcutRecorder(
                current: Hotkey(stored: snippet.hotkey),
                clash: { MailSnippets.shared.clash($0, for: snippet.id) },
                save: { key in
                    var now = snippet
                    now.hotkey = key?.stored ?? ""
                    MailSnippets.shared.change(now)
                },
                column: 120
            )
            cell
        }
        .background(
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .fill(Color.accentColor.opacity(editing.fresh.contains(snippet.id) ? 0.12 : 0)) // design: the glow on a row just brought in
                .padding(.horizontal, -8)
        )
        .contentShape(Rectangle())
        .contextMenu {
            Button("Edit…", action: edit)
            Divider()
            Button(SettingsWords.text("Delete")) { SettingsWindow.shared.did("Snippet deleted", mark: "trash", MailSnippets.shared.removeUndoably(snippet.id)) }
        }
        .onAppear { name = snippet.name }
        .onChange(of: snippet.name) { _, now in name = now }
    }

    /// Its name: bare at rest, a field under the pointer and while typed in.
    private var cell: some View {
        Group {
            if hovering || typing || refused != nil {
                TextField(text: $name, prompt: Text("")) { EmptyView() }
                    .textFieldStyle(.plain)
                    .labelsHidden()
                    .focused($typing)
                    .onSubmit { commit() }
            } else {
                Text(name)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Name")
                    .accessibilityValue(name)
            }
        }
        .modifier(TableCell(width: TableCell.column, hovering: hovering, active: typing))
        .onHover { hovering = $0 }
        .onChange(of: typing) { was, now in if was, !now { commit() } }
        .popover(isPresented: Binding(get: { refused != nil }, set: { if !$0 { refused = nil } }), arrowEdge: .bottom) {
            KeySheet(glow: glow) {
                Text(name)
                    .font(.system(size: 15, weight: .medium))
                    .frame(height: 24)
                Text(refused ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(ButtonCSS.danger)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(height: 28, alignment: .top)
            }
        }
    }

    /// The name typed, kept unless it is empty or another snippet's; then
    /// the old one comes back and the card says why.
    private func commit() {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean != snippet.name else {
            name = snippet.name
            return
        }
        if let problem = MailSnippetEditor.problem(name: clean, for: snippet.id) {
            refused = problem
            name = snippet.name
            light($glow, .bad, reduceMotion: reduceMotion)
            return
        }
        var now = snippet
        now.name = clean
        MailSnippets.shared.change(now)
    }
}

/// A snippet opened, or a new one, as the ⌘; panel's concept draws it
/// (docs/snippets/concept.html), Raycast's Create Snippet, in a card's
/// frame: its words in a tall well down the left with the placeholders
/// under it, a click putting one in at the caret; its name after ;, its
/// key, where it works (and for a mail its subject, whom it is to and its
/// files) down the right; Cancel and Save at the foot, as every card's.
private struct MailSnippetEditor: View {
    @State private var draft: MailSnippet
    /// Files chosen to add, copied in on Save.
    @State private var adding: [URL] = []
    /// The words take the keyboard as it opens.
    @FocusState private var writing: Bool
    /// The bench starts the recorder as a click would (`listen`).
    private var editing = SnippetEditing.shared
    private let new: Bool
    let close: () -> Void

    init(snippet: MailSnippet?, draft start: MailSnippet? = nil, close: @escaping () -> Void) {
        _draft = State(initialValue: snippet ?? start ?? MailSnippet(name: "", body: ""))
        new = snippet == nil
        self.close = close
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: CardFrame.inset) {
                words
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                ThreadScrollView {
                    side
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .scrollIndicators(.never)
                .frame(minWidth: 240, maxWidth: Self.column)
            }
            .frame(maxHeight: .infinity)
            buttons
                .padding(.top, CardFrame.buttonGap)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .cardFrame()
        .onExitCommand(perform: close)
        .onAppear {
            writing = true
            Bench.snippetEditorShown()
        }
    }

    /// What ";" takes, or an example while there is no name.
    private var typed: String {
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "thanks" : name
    }

    private var words: some View {
        VStack(alignment: .leading, spacing: 6) {
            caption("Words")
            ZStack(alignment: .topLeading) {
                ThreadTextEditor(text: $draft.body)
                    .focused($writing)
                    .font(.system(size: 13.5))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .accessibilityLabel("Words")
                if draft.body.isEmpty, !InputMethod.composing(focused: writing) {
                    // The editor's own inset: its text starts 5 in and 8 down.
                    Text("What it writes for you…")
                        .font(.system(size: 13.5))
                        .foregroundStyle(Palette.faint)
                        .padding(.leading, 13) // design: the text view's own 8 + its line's 5, so the prompt sits where the caret does
                        .padding(.top, 8)
                        .allowsHitTesting(false)
                }
            }
            .background(Self.well, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .frame(maxHeight: .infinity)
            MailChipFlow(spacing: 6) {
                ForEach(Self.placeholders(mail: draft.mailOnly), id: \.0) { token, said in
                    Button(token) { put(token) }
                        .buttonStyle(.yab(.secondary, .small))
                        .keyTip(said)
                }
            }
        }
    }

    private var side: some View {
        VStack(alignment: .leading, spacing: CardFrame.inset) {
            field("Name") {
                HStack(spacing: 6) {
                    Text(";")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Palette.muted)
                    TextField("thanks", text: $draft.name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .accessibilityLabel("Name")
                }
                .modifier(Self.Face())
                Text("Type ;\(typed) in \(draft.mailOnly ? "a mail" : "any field") to drop it in.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            field("Hotkey") {
                ShortcutRecorder(
                    current: Hotkey(stored: draft.hotkey),
                    clash: { MailSnippets.shared.clash($0, for: new ? nil : draft.id) },
                    save: { draft.hotkey = $0?.stored ?? "" },
                    listen: editing.listen,
                    heard: { editing.listen = false },
                    card: true
                )
            }
            field("Works") {
                HStack(spacing: 0) {
                    choice("Everywhere", mail: false)
                    choice("In Mail only", mail: true)
                }
                .padding(2)
                .background(Self.well, in: Capsule())
            }
            if draft.mailOnly {
                field("For a mail") {
                    VStack(alignment: .leading, spacing: 6) {
                        line("Subject", $draft.subject)
                        line("To", $draft.to)
                        line("Cc", $draft.cc)
                        line("Bcc", $draft.bcc)
                        Text("Apply only when the message has no value set.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.muted)
                    }
                }
                field("Files") { files }
            }
        }
    }

    /// As every card's: its answers at the right, each with its keys.
    private var buttons: some View {
        HStack(spacing: 6) {
            if !new {
                Button(SettingsWords.text("Delete"), role: .destructive) {
                    MailSnippets.shared.remove(draft.id)
                    close()
                }
                .buttonStyle(.yab(.quiet, CardFrame.button, tint: ButtonCSS.danger))
                .fixedSize()
            }
            Spacer(minLength: 8)
            if let problem {
                Text(problem)
                    .font(.system(size: CardFrame.words))
                    .foregroundStyle(ButtonCSS.danger)
                    .lineLimit(1)
            }
            Button(action: close) {
                HStack(spacing: 6) {
                    Text(SettingsWords.text("Cancel"))
                    KeyGlyphs(keys: "esc", size: CardFrame.words, tint: nil, rest: 0.6)
                }
            }
            .keyboardShortcut(.cancelAction)
            .buttonStyle(.yab(.secondary, CardFrame.button))
            .fixedSize()
            Button(action: save) {
                HStack(spacing: 6) {
                    Text(SettingsWords.text("Save"))
                    KeyGlyphs(keys: "⌘↩", size: CardFrame.words, tint: nil, rest: 0.6).transaction { $0.animation = nil }
                }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .buttonStyle(.yab(.primary, CardFrame.button))
            .fixedSize()
            .disabled(problem != nil || draft.name.trimmingCharacters(in: .whitespaces).isEmpty
                      || draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    /// One half of Works: lit on a plate when it is the one.
    private func choice(_ label: String, mail: Bool) -> some View {
        let on = draft.mailOnly == mail
        return Button { draft.mailOnly = mail } label: {
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(on ? Palette.ink : Palette.muted)
                .frame(maxWidth: .infinity)
                .frame(height: 26)
                .background {
                    if on {
                        Capsule().fill(Palette.ground) // design: the lit half of a segmented capsule, not a card
                            .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 0.5)) // design: the lit half of a segmented capsule, not a card
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// What may go in the words, and what each fills in with.
    static func placeholders(mail: Bool) -> [(String, String)] {
        (mail ? [("{first_name}", "The first name of whom it is to"), ("{name}", "The full name of whom it is to"),
                 ("{my_name}", "Your name")] : [])
            + [("{date}", "Today’s date"), ("{clipboard}", "What is copied"),
               ("{{place}}", mail ? "A place to fill by hand: the mail can’t go until it is" : "A place to fill by hand, chosen as it goes in")]
    }

    /// A placeholder put in at the caret in the words, or at their end
    /// when the caret is somewhere else.
    private func put(_ token: String) {
        if let text = NSApp.keyWindow?.firstResponder as? NSTextView, !text.isFieldEditor {
            text.insertText(token, replacementRange: text.selectedRange())
        } else {
            draft.body += token
        }
    }

    /// The face every field here has, the recorder's: a quiet well.
    private static let well = Palette.ink.opacity(0.06)

    private struct Face: ViewModifier {
        func body(content: Content) -> some View {
            content
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(MailSnippetEditor.well, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        }
    }

    private static let column: CGFloat = 280

    /// Why the name can't be kept: none, or another snippet's.
    static func problem(name: String, for id: String) -> String? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty { return "A snippet needs a name" }
        if let other = MailSnippets.shared.named(clean), other.id != id { return "Another snippet is called that" }
        return nil
    }

    private var problem: String? {
        draft.name.trimmingCharacters(in: .whitespaces).isEmpty ? nil : Self.problem(name: draft.name, for: draft.id)
    }

    private func save() {
        guard problem == nil, !draft.name.trimmingCharacters(in: .whitespaces).isEmpty,
              !draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if new {
            let mail = draft.mailOnly
            MailSnippets.shared.add(name: draft.name, body: draft.body, to: mail ? draft.to : "", cc: mail ? draft.cc : "",
                                    bcc: mail ? draft.bcc : "", subject: mail ? draft.subject : "", files: mail ? adding : [],
                                    mailOnly: mail, hotkey: draft.hotkey)
        } else {
            MailSnippets.shared.change(draft, adding: draft.mailOnly ? adding : [])
        }
        close()
    }

    /// Its files: those it keeps, and those chosen to add, each with ×.
    private var files: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(draft.files, id: \.id) { file in
                fileRow(file.name, MailAttach.said(file.size)) { draft.files.removeAll { $0.id == file.id } }
            }
            ForEach(adding, id: \.self) { url in
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                fileRow(url.lastPathComponent, MailAttach.said(size)) { adding.removeAll { $0 == url } }
            }
            Button("Add Files…", action: pick)
                .buttonStyle(.yab(.secondary, .small))
        }
    }

    private func fileRow(_ name: String, _ size: String, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: MailFiles.icon(UTType(filenameExtension: (name as NSString).pathExtension) ?? .data))
                .resizable()
                .frame(width: 16, height: 16)
            Text(name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Text(size)
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(.secondary)
            Button(action: remove) { Symbol("xmark", size: 8) }
                .buttonStyle(.yab(.quiet, .small, icon: .square))
                .keyTip("Remove")
        }
        .font(.system(size: 12.5))
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.begin { answer in
            guard answer == .OK else { return }
            MainActor.assumeIsolated { adding += panel.urls.filter { !adding.contains($0) } }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Palette.muted)
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            caption(title)
            content()
        }
    }

    /// A mail's field: its name, then the words, "None" while empty.
    private func line(_ label: String, _ text: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .frame(width: 52, alignment: .leading)
            TextField(SettingsWords.text("None"), text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .accessibilityLabel(label)
        }
        .modifier(Self.Face())
    }
}
