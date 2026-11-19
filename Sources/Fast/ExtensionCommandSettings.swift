import SwiftUI

/// Settings › Shortcuts, after Yab's own: each extension's commands in a
/// group of its own, Raycast's way. Every row wears the extension's icon;
/// its button's command is "Open" and its short name, the rest say what the
/// manifest says. An alias runs the command from ⌘T, the key runs it
/// anywhere in Yab, asleep or not, and unchecked it is neither.
@available(macOS 15.4, *)
struct ExtensionCommandSections: View {
    let filter: String
    var visibleIDs: Set<String>? = nil
    /// The window's sign-in's extensions (ExtensionSignIns).
    private var here = ExtensionsHere.shared
    private var extensions: Extensions { here.current }

    var body: some View {
        let needle = filter.lowercased()
        let groups = extensions.commandGroups().compactMap { group -> (item: Installed, short: String, commands: [Extensions.CommandEntry])? in
            let commands = group.commands.filter {
                (visibleIDs?.contains("ext." + $0.id) ?? true)
                    && (needle.isEmpty || $0.matches(needle) || ShortcutsPage.says(group.item.name, needle))
            }
            return commands.isEmpty ? nil : (group.item, group.short, commands)
        }
        ForEach(Array(groups.enumerated()), id: \.element.item.id) { index, group in
            Section {
                ForEach(group.commands) { entry in
                    ExtensionCommandRow(entry: entry, icon: icon(group.item.id), extensions: extensions)
                        .settingsAnchor("key:ext." + entry.id)
                }
            } header: {
                Text(group.short)
            } footer: {
                if index == groups.count - 1 {
                    SettingsNote("Aliases run commands from ⌘T. Hotkeys work while Yab is active.")
                }
            }
        }
    }

    private func icon(_ id: String) -> NSImage? {
        extensions.buttons.first { $0.id == id }?.icon ?? extensions.icon(for: id, side: 16)
    }
}

@available(macOS 15.4, *)
struct ExtensionCommandRow: View {
    let entry: Extensions.CommandEntry
    let icon: NSImage?
    var extensions: Extensions

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Group {
                    if let icon {
                        Image(nsImage: icon).resizable().interpolation(.high)
                    } else {
                        Symbol("puzzlepiece.extension", size: 12).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 16, height: 16)
                Text(entry.title).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(entry.kept.off ? 0.45 : 1)
            ExtensionAliasCell(entry: entry, extensions: extensions)
            ShortcutRecorder(
                current: entry.keys,
                clash: { Self.clash($0, entry: entry, command: command) },
                save: { extensions.setKey($0, extension: entry.extensionID, command: entry.command) },
                column: 118
            )
            Toggle(entry.title, isOn: Binding(
                get: { !entry.kept.off },
                set: { on in
                    var kept = entry.kept
                    kept.off = !on
                    extensions.setCommand(kept, extension: entry.extensionID, command: entry.command)
                }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .frame(width: 20)
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Remove Hotkey") { extensions.setKey(nil, extension: entry.extensionID, command: entry.command) }
                .disabled(entry.keys == nil)
        }
    }

    /// Who has a key recorded for `entry`. Chrome keeps the keys of one that
    /// runs in Chromium, and gives a command only the keys
    /// chrome://extensions/shortcuts can record.
    static func clash(_ hotkey: Hotkey, entry: Extensions.CommandEntry, command: AnyObject?) -> Keymap.Clash? {
        if entry.chromium, ChromiumExtensionCommands.stored(hotkey) == nil {
            return .refused("Chrome doesn't give extension commands this key.")
        }
        return Keymap.shared.clash(hotkey, for: nil, command: command, extensionCommand: entry.chromium ? entry.id : nil)
    }

    /// WebKit's own, while it is loaded: a clash with itself isn't one.
    private var command: AnyObject? {
        extensions.contexts[entry.extensionID]?.commands.first { $0.id == entry.command }
    }
}

/// The alias, Settings › Search's cell: its word bare at rest, a field
/// under the pointer and while typed in, a card under it saying why a word
/// was refused.
@available(macOS 15.4, *)
private struct ExtensionAliasCell: View {
    let entry: Extensions.CommandEntry
    var extensions: Extensions
    @State private var word = ""
    @State private var hovering = false
    @State private var refused: (word: String, why: String)?
    @State private var glow: Glow?
    @FocusState private var typing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if hovering || typing || refused != nil {
                TextField(text: $word, prompt: Text("")) { EmptyView() }
                    .textFieldStyle(.plain)
                    .labelsHidden()
                    .focused($typing)
                    .overlay(alignment: .leading) {
                        if word.isEmpty, !InputMethod.composing(focused: typing) {
                            Text("Alias").foregroundStyle(.secondary).allowsHitTesting(false)
                        }
                    }
                    .onSubmit(commit)
            } else {
                Text(word.isEmpty ? "Alias" : word)
                    .foregroundStyle(word.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .modifier(TableCell(width: 96, hovering: hovering, active: typing))
        .onHover { hovering = $0 }
        .onChange(of: typing) { was, now in if was, !now { commit() } }
        .onAppear { word = entry.kept.alias }
        .onChange(of: entry.kept.alias) { _, now in if !typing { word = now } }
        .accessibilityLabel("Alias for \(entry.title)")
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

    private func commit() {
        let clean = ExtensionCommands.clean(word)
        guard clean != entry.kept.alias else {
            word = entry.kept.alias
            return
        }
        if let problem = ExtensionCommands.aliasProblem(clean, for: entry.extensionID, entry.command,
                                                         ids: extensions.installed.map(\.id)) {
            word = entry.kept.alias
            refused = (clean, problem)
            light($glow, .bad, reduceMotion: reduceMotion)
            return
        }
        var kept = entry.kept
        kept.alias = clean
        extensions.setCommand(kept, extension: entry.extensionID, command: entry.command)
        word = clean
    }
}
