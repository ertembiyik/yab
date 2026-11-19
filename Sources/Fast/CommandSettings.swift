import SwiftUI
import UniformTypeIdentifiers

struct CommandSettingsPage: View {
    static let benchEdit = Notification.Name("commands.bench-edit")
    var commands: SelectionCommands
    private var askKey = Keymap.shared.slot(.agentAsk)
    @State private var editing: SelectionCommand?
    @State private var imported = ""
    @State private var editingAdvanced = false

    var body: some View {
        PageHero(page: .commands)
        Section {
            ForEach(Array(commands.commands.enumerated()), id: \.element.id) { index, command in
                CommandRow(commands: commands, index: index, command: command) { editing = command }
                    .settingsAnchor("command-" + command.id)
            }
            Button("New Command") {
                editing = SelectionCommand(id: UUID().uuidString, name: "", prompt: "{selection}", executor: "agent", custom: true)
            }
            .settingsButton(.primary)
            Button("Bring in from Raycast…") {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.json]
                panel.canChooseDirectories = false
                panel.begin { response in
                    guard response == .OK, let url = panel.url else { return }
                    do {
                        let count = try commands.importRaycast(url)
                        imported = count == 0 ? "No supported commands found" : "Imported \(count) commands"
                    } catch {
                        imported = "Could not read that file"
                    }
                }
            }
            .settingsButton()
            if !imported.isEmpty { Text(imported).foregroundStyle(.secondary) }
        } header: {
            Text("Commands for selected text")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                SettingsText("Select text on a page and press \(askKey.keys?.settingsHint ?? "the assigned shortcut") for its commands", size: 11)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Commands can show a result or replace selected text directly.")
            }
        }
        .sheet(item: $editing) { command in
            CommandEditor(command: command, occupied: commands.commands.filter { $0.id != command.id }, expanded: editingAdvanced, save: { updated in
                if let index = commands.commands.firstIndex(where: { $0.id == updated.id }) {
                    commands.commands[index] = updated
                } else {
                    commands.commands.append(updated)
                }
                commands.save()
                editing = nil
            }, delete: {
                commands.commands.removeAll { $0.id == command.id && $0.custom }
                commands.save()
                editing = nil
            }, cancel: { editing = nil })
        }
        .onReceive(NotificationCenter.default.publisher(for: Self.benchEdit)) { note in
            guard Store.testing, let id = note.userInfo?["id"] as? String else { return }
            editingAdvanced = note.userInfo?["advanced"] as? Bool ?? false
            editing = commands.commands.first { $0.id == id }
        }
    }
}

private struct CommandEditor: View {
    @State private var draft: SelectionCommand
    @State private var advanced = false
    let occupied: [SelectionCommand]
    let save: (SelectionCommand) -> Void
    let delete: () -> Void
    let cancel: () -> Void

    init(command: SelectionCommand, occupied: [SelectionCommand], expanded: Bool = false, save: @escaping (SelectionCommand) -> Void,
         delete: @escaping () -> Void, cancel: @escaping () -> Void) {
        _draft = State(initialValue: command)
        _advanced = State(initialValue: expanded)
        self.occupied = occupied
        self.save = save
        self.delete = delete
        self.cancel = cancel
    }

    var body: some View {
        // Raycast's: the prompt down the left, what it runs on and where
        // the result goes down the right, one field under another.
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    caption("Prompt")
                    ThreadTextEditor(text: $draft.prompt)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
                        .frame(maxHeight: .infinity)
                        .accessibilityLabel("Prompt")
                    Menu {
                        ForEach(["selection", "around", "page", "url", "title", "language", "memory"], id: \.self) { variable in
                            Button("{" + variable + "}") { draft.prompt += "{" + variable + "}" }
                        }
                    } label: {
                        Label("Insert variable", systemImage: "curlybraces")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()

                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        field("Name") {
                            TextField(SettingsWords.text("Name"), text: $draft.name)
                                .textFieldStyle(.roundedBorder)
                                .labelsHidden()
                                .disabled(!draft.custom)
                        }
                        field("Model") {
                            ModelField(choice: modelChoice,
                                       automatic: ("Default", ModelDefaults.shared.name(.commands)),
                                       offersMac: true, width: Self.face)
                        }
                        field("Output") {
                            ChoiceMenu(title: "Output", options: [
                                ("Replace selection", "replace"), ("Show result", "preview"),
                            ], selection: Binding(
                                get: { draft.outputBehavior.rawValue },
                                set: { draft.outputBehavior = SelectionCommand.OutputBehavior(rawValue: $0) ?? .preview }
                            ), width: Self.face)
                            Text(draft.outputBehavior == .replace ? "Replaces the text as soon as it’s ready." : "Shows the result before changing the text.")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                        field("Shortcut") {
                            ShortcutRecorder(
                                current: Hotkey(stored: draft.shortcut),
                                clash: { key in
                                    if occupied.contains(where: { $0.enabled && Hotkey(stored: $0.shortcut) == key }) {
                                        return .refused("Already used by another command.")
                                    }
                                    if let clash = Keymap.shared.clash(key, for: nil) {
                                        if case .taken(let reason, _) = clash { return .refused(reason) }
                                        return clash
                                    }
                                    return nil
                                },
                                save: { draft.shortcut = $0?.stored ?? "" },
                                column: 168
                            )
                        }
                        DisclosureGroup("Advanced", isExpanded: $advanced) {
                            VStack(alignment: .leading, spacing: 16) {
                                if AgentPlan.isPlan(draft.executor) {
                                    field("Reasoning") { EffortField(choice: modelChoice, width: Self.face - 20) }
                                }
                                field("Show command when selecting") {
                                    ChoiceMenu(title: "Show command when selecting", options: [
                                        ("Text anywhere", "any"), ("Text in input fields", "fields"),
                                        ("Text on web pages", "pages"), ("Code", "code"),
                                    ], selection: Binding(
                                        get: { draft.codeOnly ? "code" : draft.fieldsOnly ? "fields" : draft.pagesOnly ? "pages" : "any" },
                                        set: { value in
                                            draft.fieldsOnly = value == "fields"
                                            draft.pagesOnly = value == "pages"
                                            draft.codeOnly = value == "code"
                                        }
                                    ), width: Self.face - 20)
                                    Text(availabilityDescription)
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(.secondary)
                                }
                                field("Sites") {
                                    TextField("All sites", text: $draft.site)
                                        .textFieldStyle(.roundedBorder)
                                        .labelsHidden()
                                }
                            }
                            .frame(width: Self.column - 20, alignment: .leading)
                            .padding(.top, 12)
                        }
                        .font(.system(size: 12))
                        .tint(Palette.muted)
                    }
                }
                .padding(.trailing, 2)
                .frame(width: Self.column, alignment: .topLeading)
            }
            HStack {
                if draft.custom {
                    Button(SettingsWords.text("Delete"), role: .destructive, action: delete)
                        .buttonStyle(.yab(.quiet, .regular, tint: ButtonCSS.danger))
                }
                Spacer()
                Button(SettingsWords.text("Cancel"), action: cancel)
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.yab(.secondary, .regular))
                Button("Save command") {
                    draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    draft.prompt = draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !draft.name.isEmpty, !draft.prompt.isEmpty else { return }
                    // Old placements stay readable until an edit is saved.
                    let behavior = draft.outputBehavior
                    draft.outputBehavior = behavior
                    save(draft)
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.yab(.primary, .regular))
                .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 720, height: 560)
    }

    private var availabilityDescription: String {
        if draft.codeOnly { return "Appears only when selected text is recognized as code." }
        if draft.fieldsOnly { return "Appears only in fields you can type in, such as message drafts." }
        if draft.pagesOnly { return "Appears only for page text, such as articles and posts." }
        return "Appears in the selection menu for text in fields and on pages."
    }

    /// The right side's width, and a choice's face across it (less a small
    /// button's padding each side).
    private static let column: CGFloat = 260
    private static var face: CGFloat { column - 2 * ButtonSize.small.padding }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            caption(title)
            content()
        }
    }

    /// The command's runner as a model: this Mac's, the Commands default
    /// ("agent"), or one of its own on Claude Code or Codex.
    private var modelChoice: Binding<ModelChoice> {
        Binding(get: {
            switch draft.executor {
            case "mac": ModelChoice(cli: "mac")
            case let cli where AgentPlan.isPlan(cli): ModelChoice(cli: cli, model: draft.model, effort: draft.effort)
            default: ModelChoice()
            }
        }, set: { choice in
            draft.executor = choice.cli ?? "agent"
            let own = AgentPlan.isPlan(choice.cli)
            draft.model = own ? choice.model : nil
            draft.effort = own ? choice.effort : nil
        })
    }
}

/// One command in the AI Commands table: its name, what runs
/// it, its hotkey, and the rest under ···. Both cells are changed where
/// they are; a click on the name opens the editor. Off is said by the row
/// going pale, and switched under ···.
private struct CommandRow: View {
    var commands: SelectionCommands
    let index: Int
    let command: SelectionCommand
    let edit: () -> Void
    /// Wide enough for "Claude Sonnet" with its mark and ⌃⌄.
    static let modelColumn: CGFloat = 164

    var body: some View {
        HStack(spacing: 12) {
            Button(action: edit) {
                Text(SelectionCommand.menuTitle(command.name))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Edits \(command.name)")
            Group {
                if isLocal {
                    Text("No model")
                        .foregroundStyle(.secondary)
                        .modifier(TableCell(width: Self.modelColumn))
                } else {
                    ModelField(choice: choice,
                               automatic: ("Default", ModelDefaults.shared.name(.commands)),
                               offersMac: true, width: Self.modelColumn, cell: cellTitle)
                }
            }
            ShortcutRecorder(
                current: Hotkey(stored: command.shortcut),
                clash: { key in
                    if commands.commands.contains(where: { $0.id != command.id && $0.enabled && Hotkey(stored: $0.shortcut) == key }) {
                        return .refused("Already used by another command.")
                    }
                    if let clash = Keymap.shared.clash(key, for: nil) {
                        if case .taken(let reason, _) = clash { return .refused(reason) }
                        return clash
                    }
                    return nil
                },
                save: { key in change { $0.shortcut = key?.stored ?? "" } }
            )
            more
        }
        .opacity(command.enabled ? 1 : 0.45)
        .contextMenu { actions }
    }

    private var isLocal: Bool {
        command.executor == "local" || ["quote", "calendar", "map", "call", "convert"].contains(command.id)
    }

    /// "On this Mac", "Default", "Claude Opus": the effort is the editor's.
    private var cellTitle: String {
        switch command.executor {
        case "mac": return "Apple Intelligence"
        case let cli where AgentPlan.isPlan(cli):
            return AgentModels.find(command.executor, command.model)?.name ?? AgentModels.agentName(command.executor)
        default: return "Default"
        }
    }

    /// What runs it, as the model field reads and writes it.
    private var choice: Binding<ModelChoice> {
        Binding(get: {
            switch command.executor {
            case "mac": ModelChoice(cli: "mac")
            case let cli where AgentPlan.isPlan(cli): ModelChoice(cli: cli, model: command.model, effort: command.effort)
            default: ModelChoice()
            }
        }, set: { picked in
            change {
                $0.executor = picked.cli ?? "agent"
                let own = AgentPlan.isPlan(picked.cli)
                $0.model = own ? picked.model : nil
                $0.effort = own ? picked.effort : nil
            }
        })
    }

    private func change(_ edit: (inout SelectionCommand) -> Void) {
        guard let i = commands.commands.firstIndex(where: { $0.id == command.id }) else { return }
        edit(&commands.commands[i])
        commands.save()
    }

    private var more: some View {
        Menu { actions } label: {
            Symbol("ellipsis", size: 14)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More options for \(command.name)")
    }

    @ViewBuilder private var actions: some View {
        Button("Edit…", action: edit)
        // One that means something on a page with nothing selected can
        // run there on its own, as a routine (RoutineSettings).
        if command.runsOnPages {
            Button("Run Regularly…") { RoutineEditing.shared.runRegularly(command) }
        }
        Button(command.enabled ? "Turn Off" : "Turn On") { change { $0.enabled.toggle() } }
        Divider()
        Button("Move Up") {
            commands.commands.swapAt(index, index - 1)
            commands.save()
        }
        .disabled(index == 0)
        Button("Move Down") {
            commands.commands.swapAt(index, index + 1)
            commands.save()
        }
        .disabled(index + 1 >= commands.commands.count)
        Button("Duplicate") {
            var copy = command
            copy.id = UUID().uuidString
            copy.name += " copy"
            copy.custom = true
            copy.shortcut = ""
            commands.commands.insert(copy, at: index + 1)
            commands.save()
        }
        Divider()
        if command.custom {
            Button(SettingsWords.text("Delete"), role: .destructive) {
                commands.commands.removeAll { $0.id == command.id }
                commands.save()
            }
        } else {
            Button(SettingsWords.text("Reset")) {
                if let original = SelectionCommand.builtIn.first(where: { $0.id == command.id }) {
                    commands.commands[index] = original
                    commands.save()
                }
            }
        }
    }
}
