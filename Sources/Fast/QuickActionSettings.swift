import SwiftUI

/// Settings › Search, in the same table language as site aliases and hotkeys.
struct QuickActionSettings: View {
    private var actions = QuickActions.shared
    private var editing = QuickActionEditing.shared
    @State private var enableError: String?
    @State private var hovered: String?

    var body: some View {
        Section {
            ForEach(actions.actions) { action in
                row(action)
            }
            FieldAddLine("Add Action") {
                editing.open(QuickAction(id: UUID().uuidString, name: "", url: "https://", alias: "", custom: true))
            }
        } header: {
            Text("Quick Actions")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                // A hotkey that couldn't be taken, said where the table is,
                // as the recorder says a clash, not in an alert of the Mac's.
                if let enableError {
                    Text(enableError)
                        .font(.callout)
                        .foregroundStyle(Color.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .animation(Motion.quick, value: enableError)
        }

        if !actions.suggestions.isEmpty {
            Section {
                ForEach(actions.suggestions) { suggestion in
                    SettingsRow(suggestion.name, detail: suggestion.detail) {
                        Button(suggestion.replacing == nil ? "Add" : "Use") { actions.accept(suggestion) }
                            .settingsButton()
                        Button { actions.dismiss(suggestion) } label: { Symbol("xmark", size: 11) }
                            .buttonStyle(.plain)
                            .keyTip("Don't suggest this")
                            .accessibilityLabel("Don't suggest \(suggestion.name)")
                    }
                }
            } header: { Text("Suggested from your history") }
        }
    }

    private func row(_ action: QuickAction) -> some View {
        // Its alias and hotkey stand in the row always, in columns, as
        // Raycast's table; the menu only under the pointer, and hover moves
        // nothing.
        let over = hovered == action.id
        return FieldLine(action.name, off: !action.enabled, mark: {
            Mark(icon: Favicons.shared.cached(action.host), letter: String(action.name.prefix(1)), size: FieldLineColumn.mark)
        }, status: {
            QuickActionAlias(action: action)
        }, end: {
            HStack(spacing: FieldLineColumn.gap) {
                ShortcutRecorder(
                    current: Hotkey(stored: action.shortcut),
                    clash: { key in
                        return actions.shortcutProblem(key, excluding: action.id).map { .refused($0) }
                    },
                    save: { key in
                        guard var updated = actions.action(action.id) else { return }
                        updated.shortcut = key?.stored ?? ""
                        enableError = actions.put(updated)
                    },
                    column: 118
                )
                SettingsMoreMenu("More options for \(action.name)", entries: {
                    // The switch at the row's end turns it off.
                    [.item("Edit…") { editing.open(action) }]
                        + (action.custom ? [.destructive("Remove") { actions.remove(action.id) }] : [])
                }) {
                    Symbol("ellipsis", size: 14)
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .opacity(over ? 1 : 0)
                .allowsHitTesting(over)
                FieldSwitch(action.name, isOn: Binding(
                    get: { actions.action(action.id)?.enabled ?? false },
                    set: { enableError = actions.setEnabled(action.id, $0) }
                ))
            }
        })
        .contentShape(Rectangle())
        .settingsRowHover { hovered = $0 ? action.id : (hovered == action.id ? nil : hovered) }
        .settingsAnchor("quick-action:" + action.id)
    }
}

/// A quick action's alias, typed in place as a site's is (SiteRow): bare
/// words at rest, an outline under the pointer, a real field only while it
/// is wanted, and a card under it saying why a word was refused.
private struct QuickActionAlias: View {
    let action: QuickAction

    @State private var word = ""
    @State private var hovering = false
    @State private var refused: (word: String, why: String)?
    @State private var glow: Glow?
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if hovering || focused || refused != nil || ShortcutRecorder.eager {
                field
            } else {
                Text(word.isEmpty ? "Alias" : word)
                    .foregroundStyle(word.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Alias for \(action.name)")
                    .accessibilityValue(word)
            }
        }
        .modifier(TableCell(width: FieldLineColumn.status, hovering: hovering, active: focused))
        .onHover { hovering = $0 }
        // Watched here, not on the field, which may go in the same pass.
        .onChange(of: focused) { was, now in if was, !now { commit() } }
        .onAppear { word = action.alias }
        .onChange(of: action.alias) { _, alias in if !focused { word = alias } }
        .popover(isPresented: Binding(get: { refused != nil }, set: { if !$0 { refused = nil } }), arrowEdge: .bottom) {
            KeySheet(glow: glow) {
                Text(refused?.word ?? "")
                    .font(.system(size: 15, weight: .medium))
                    .frame(height: 24)
                Text(refused?.why ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(ButtonCSS.danger)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(height: 28, alignment: .top)
            }
        }
    }

    private var field: some View {
        TextField(text: $word, prompt: Text("")) { EmptyView() }
            .textFieldStyle(.plain)
            .labelsHidden()
            .multilineTextAlignment(.leading)
            .focused($focused)
            .accessibilityLabel("Alias for \(action.name)")
            .overlay(alignment: .leading) {
                if word.isEmpty, !InputMethod.composing(focused: focused) {
                    Text("Alias")
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                }
            }
            .onSubmit { commit() }
    }

    /// What was typed, kept if it can be an alias; if not, the old one comes
    /// back and the card says why, as SiteRow's does.
    private func commit() {
        let actions = QuickActions.shared
        let old = actions.action(action.id)?.alias ?? action.alias
        let clean = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard clean != old, var updated = actions.action(action.id) else {
            word = old
            return
        }
        updated.alias = clean
        if let problem = actions.put(updated) {
            word = old
            refused = (clean, problem)
            light($glow, .bad, reduceMotion: reduceMotion)
            return
        }
        word = clean
    }
}

@MainActor
@Observable final class QuickActionEditing {
    static let shared = QuickActionEditing()
    var action: QuickAction?

    func open(_ action: QuickAction) { self.action = action }
    func close() { action = nil }
}

struct QuickActionCardLayer: View {
    private var editing = QuickActionEditing.shared

    var body: some View {
        ZStack {
            if let action = editing.action {
                QuickActionCard(action: action) { editing.close() }
                    .frame(width: 440)
                    .transition(.asymmetric(insertion: .scale(scale: 0.97).combined(with: .opacity).animation(Motion.arrive), removal: .identity))
                    .id(action.id)
            }
        }
    }
}

private struct QuickActionCard: View {
    @State private var draft: QuickAction
    @State private var error = ""
    @FocusState private var focus: Field?
    let done: () -> Void

    private enum Field { case name, url, alias }

    init(action: QuickAction, done: @escaping () -> Void) {
        _draft = State(initialValue: action)
        self.done = done
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: CardFrame.wellGap) {
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .fill(Palette.ink.opacity(0.05))
                    .overlay {
                        if draft.name.isEmpty {
                            Symbol("arrow.up.right", size: 16).foregroundStyle(Palette.ink)
                        } else {
                            Mark(icon: Favicons.shared.cached(draft.host), letter: String(draft.name.prefix(1)), size: 20)
                        }
                    }
                    .frame(width: CardFrame.well, height: CardFrame.well)
                VStack(alignment: .leading, spacing: 2) {
                    Text(draft.name.isEmpty ? "Add a Quick Action" : "Edit Quick Action")
                        .font(CardFrame.title)
                        .foregroundStyle(Palette.ink)
                    Text("Create an alias for a website.")
                        .font(CardFrame.detail)
                        .foregroundStyle(Palette.muted)
                }
            }
            VStack(spacing: 8) {
                formRow("Name") {
                    field("Name", hint: "New document", text: $draft.name, as: .name)
                }
                formRow("Address") {
                    field("Address", hint: "https://example.com/new", text: $draft.url, as: .url)
                }
                formRow("Alias") {
                    field("Alias", hint: "doc", text: $draft.alias, as: .alias)
                }
                formRow("Hotkey") {
                    ShortcutRecorder(
                        current: Hotkey(stored: draft.shortcut),
                        clash: { key in
                            return QuickActions.shared.shortcutProblem(key, excluding: draft.id).map { .refused($0) }
                        },
                        save: { draft.shortcut = $0?.stored ?? "" },
                        card: true
                    )
                }
            }
            .padding(.top, 16)
            if !error.isEmpty {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(ButtonCSS.danger)
                    .padding(.top, 8)
            }
            HStack(spacing: 6) {
                if !draft.name.isEmpty {
                    Button(draft.custom ? "Remove" : "Turn Off", role: .destructive) {
                        QuickActions.shared.remove(draft.id)
                        done()
                    }
                    .buttonStyle(.yab(.quiet, CardFrame.button, tint: ButtonCSS.danger))
                }
                Spacer(minLength: 8)
                Button(action: done) {
                    HStack(spacing: 6) {
                        Text(SettingsWords.text("Cancel"))
                        KeyGlyphs(keys: "esc", size: CardFrame.words, tint: nil, rest: 0.6)
                    }
                }
                .buttonStyle(.yab(.secondary, CardFrame.button))
                .fixedSize()
                Button(action: save) {
                    HStack(spacing: 6) {
                        Text(SettingsWords.text("Save"))
                        KeyGlyphs(keys: "↩", size: CardFrame.words, tint: nil, rest: 0.6)
                    }
                }
                .buttonStyle(.yab(.primary, CardFrame.button))
                .fixedSize()
            }
            .padding(.top, CardFrame.buttonGap)
        }
        .cardFrame()
        .onExitCommand(perform: done)
        .onAppear { if draft.name.isEmpty { DispatchQueue.main.async { focus = .name } } }
    }

    private func field(_ label: String, hint: String, text: Binding<String>, as which: Field) -> some View {
        TextField("", text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 13.5))
            .foregroundStyle(Palette.ink)
            .focused($focus, equals: which)
            .modifier(CardField(hint: hint, empty: text.wrappedValue.isEmpty, typing: focus == which))
            .onSubmit(save)
            .accessibilityLabel(label)
    }

    private func formRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.muted)
                .frame(width: 64, alignment: .leading)
            content()
                .frame(maxWidth: .infinity)
        }
    }

    private func save() {
        if let problem = QuickActions.shared.put(draft) { error = problem; return }
        done()
    }
}
