import AppKit
import WebKit

/// What someone set for an extension's commands besides their keys, kept
/// per extension (`extensions.commands.<id>`), as its keys are kept
/// (`extensions.keys.<id>`): an alias that runs the command from ⌘T, and
/// whether it is off, out of ⌘T and its key not heard. Shown in Settings ›
/// Shortcuts, a group for each extension, Raycast's way.
enum ExtensionCommands {
    /// The same browser/macOS ownership gate as key dispatch. A saved
    /// binding can be hidden temporarily by a later App Shortcut.
    @MainActor static func routes(_ key: Hotkey) -> Bool {
        key.commands && Keymap.shared.action(for: key) == nil && !Keymap.shared.hasCommand(key) && !Shortcut.kept(key, from: nil)
    }

    static func key(_ id: String) -> String { "extensions.commands.\(id)" }

    struct Kept: Equatable {
        var alias = ""
        var off = false
    }

    static func kept(_ id: String, _ command: String, in settings: UserDefaults = Store.settings) -> Kept {
        let entry = (settings.dictionary(forKey: key(id)) ?? [:])[command] as? [String: Any] ?? [:]
        return Kept(alias: entry["alias"] as? String ?? "", off: entry["off"] as? Bool ?? false)
    }

    static func off(_ id: String, _ command: String) -> Bool { kept(id, command).off }

    static func set(_ kept: Kept, _ id: String, _ command: String, in settings: UserDefaults = Store.settings) {
        var all = settings.dictionary(forKey: key(id)) ?? [:]
        all[command] = kept == Kept() ? nil : ["alias": kept.alias, "off": kept.off]
        if all.isEmpty { settings.removeObject(forKey: key(id)) } else { settings.set(all, forKey: key(id)) }
    }

    /// Every alias kept, by word: the extension and the command it runs.
    static func aliases(in settings: UserDefaults = Store.settings, ids: [String]) -> [String: (id: String, command: String)] {
        var out: [String: (id: String, command: String)] = [:]
        for id in ids {
            for (command, entry) in settings.dictionary(forKey: key(id)) ?? [:] {
                guard let entry = entry as? [String: Any], let alias = entry["alias"] as? String, !alias.isEmpty,
                      entry["off"] as? Bool != true else { continue }
                out[alias] = (id, command)
            }
        }
        return out
    }

    /// An alias as it is kept: lowercased, without spaces round it.
    static func clean(_ word: String) -> String { word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    /// Why a word can't be this command's alias, or nil: letters, digits
    /// and -, and no one else's word in the field.
    @MainActor
    static func aliasProblem(_ word: String, for id: String, _ command: String, ids: [String]) -> String? {
        let word = clean(word)
        guard !word.isEmpty else { return nil }
        guard word.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return "Only letters, digits and -" }
        if let other = aliases(ids: ids)[word], other.id != id || other.command != command {
            return "Already \(Extensions.here.installed.first { $0.id == other.id }?.name ?? "another extension")"
        }
        if let scope = Scopes.all.first(where: { $0.aliases.contains(word) || $0.name.lowercased() == word || $0.host == word }) {
            return "Already \(scope.name)"
        }
        if let action = QuickActions.shared.actions.first(where: { $0.enabled && $0.alias == word }) { return "Already \(action.name)" }
        if let place = FieldPlace.allCases.first(where: { $0.names.contains(word) }) { return "Already \(place.title)" }
        if let command = Command.allCases.first(where: { $0.title.lowercased() == word }) { return "Already \(command.title)" }
        return nil
    }

    /// The extension a word is the alias of, for the other tables' own
    /// checks (Scopes, QuickActions).
    @MainActor
    static func aliasOwner(_ word: String) -> String? {
        let word = clean(word)
        guard !word.isEmpty, #available(macOS 15.4, *) else { return nil }
        let extensions = Extensions.here
        guard let found = aliases(ids: extensions.installed.map(\.id))[word] else { return nil }
        return extensions.installed.first { $0.id == found.id }?.name
    }
}

@available(macOS 15.4, *)
extension Extensions {
    /// One of an extension's commands, as Settings › Shortcuts and ⌘T
    /// list it.
    struct CommandEntry: Identifiable, Equatable {
        let extensionID: String
        let command: String
        /// "Open NordPass" for its button's, else the extension's words.
        let title: String
        let keys: Hotkey?
        let kept: ExtensionCommands.Kept
        /// Its key is Chrome's (ChromiumExtensionCommands): the extension
        /// runs in Chromium, and Settings writes the key there.
        var chromium = false
        var id: String { extensionID + "/" + command }
        var press: Bool { ExtensionTip.pressCommands.contains(command) || ChromiumExtensionCommands.actionCommands.contains(command) }

        /// The existing Shortcuts filter also finds the alias shown in its row.
        func matches(_ filter: String) -> Bool {
            let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return needle.isEmpty || ShortcutsPage.says(title, needle) || ShortcutsPage.says(kept.alias, needle)
                || keys?.text.lowercased() == needle
        }
    }

    /// Each extension that's on and has commands, in install order, with
    /// them: from WebKit when it is loaded, from Chrome when it runs in
    /// Chromium (its keys Chrome's), from its manifest while it sleeps or
    /// waits its turn.
    func commandGroups() -> [(item: Installed, short: String, commands: [CommandEntry])] {
        _ = revision
        let native = ChromiumExtensionCommands.native(for: self)
        return installed.filter(\.enabled).compactMap { item in
            let short = buttons.first { $0.id == item.id }?.label
                ?? ExtensionTip.label(action: "", name: item.name, displayName: nil, shortName: tipFacts[item.id]?.shortName ?? "")
            let listed: [(id: String, title: String, keys: Hotkey?)]
            var chromium = false
            if contexts[item.id] == nil, let row = ChromiumExtensionCommands.row(item.id, in: native) {
                // Chrome lists the button's first, then the rest by name.
                chromium = true
                listed = (row.commands.filter(\.action) + row.commands.filter { !$0.action }).map { command -> (id: String, title: String, keys: Hotkey?) in
                    (command.name, command.action ? "" : command.description, command.hotkey)
                }
            } else if let context = contexts[item.id] {
                let all = context.commands.map { command -> (id: String, title: String, keys: Hotkey?) in
                    (command.id, command.title, command.activationKey.map { Hotkey($0, command.modifierFlags) })
                }
                listed = all.filter { ExtensionTip.pressCommands.contains($0.id) } + all.filter { !ExtensionTip.pressCommands.contains($0.id) }
            } else if let facts = tipFacts[item.id] {
                listed = facts.commands.map { command in (command.id, command.title, facts.keys.first { $0.command == command.id }?.hotkey) }
            } else {
                listed = []
            }
            let commands = listed.map { id, title, keys in
                let press = ExtensionTip.pressCommands.contains(id) || ChromiumExtensionCommands.actionCommands.contains(id)
                return CommandEntry(extensionID: item.id, command: id,
                                    title: press ? "Open \(short)" : (title.isEmpty ? id : title),
                                    keys: keys, kept: ExtensionCommands.kept(item.id, id), chromium: chromium)
            }
            return commands.isEmpty ? nil : (item, short, commands)
        }
    }

    func routedKey(_ command: WKWebExtension.Command) -> Hotkey? {
        _ = revision
        guard !ExtensionCommands.off(command.webExtensionContext?.uniqueIdentifier ?? "", command.id),
              let key = command.activationKey.map({ Hotkey($0, command.modifierFlags) }),
              ExtensionCommands.routes(key) else { return nil }
        return key
    }

    /// A key for a command, loaded or asleep: kept as Settings keeps any
    /// (`extensions.keys.<id>`), on the loaded command at once, and in what
    /// an asleep one answers to.
    func setKey(_ hotkey: Hotkey?, extension id: String, command: String) {
        // One that runs in Chromium: Chrome keeps its keys, as
        // chrome://extensions/shortcuts sets them.
        if contexts[id] == nil, let native = ChromiumExtensionCommands.native(for: self),
           ChromiumExtensionCommands.row(id, in: native)?.commands.contains(where: { $0.name == command }) == true {
            ChromiumExtensionCommands.setKey(hotkey, extension: id, command: command, in: native, for: self)
            return
        }
        if let wk = contexts[id]?.commands.first(where: { $0.id == command }) {
            setKey(hotkey?.key, hotkey?.flags ?? [], for: wk)
        } else {
            var all = Store.settings.dictionary(forKey: "extensions.keys.\(id)") ?? [:]
            all[command] = ["key": hotkey?.key ?? "", "flags": Int(hotkey?.flags.rawValue ?? 0)]
            Store.settings.set(all, forKey: "extensions.keys.\(id)")
            revision &+= 1
        }
        refreshTipFacts(id)
        actionsChanged += 1
    }

    func setCommand(_ kept: ExtensionCommands.Kept, extension id: String, command: String) {
        ExtensionCommands.set(kept, id, command)
        revision &+= 1
        actionsChanged += 1
    }

    /// Runs one, from its key or ⌘T: its button pressed, or its command performed,
    /// woken for it first if it sleeps.
    func run(_ id: String, command: String) {
        guard !ExtensionCommands.off(id, command) else { return }
        if ExtensionTip.pressCommands.contains(command) { return press(id) }
        let perform = { [weak self] in
            guard !ExtensionCommands.off(id, command),
                  let context = self?.contexts[id], let wk = context.commands.first(where: { $0.id == command }) else { return }
            if let tab = self?.activeAdapter { context.userGesturePerformed(in: tab) }
            context.performCommand(wk)
        }
        if contexts[id] != nil { perform() } else { wake(id) { perform() } }
    }
}

extension Browser {
    /// ⌘T's rows for the extensions' commands the words name: by alias,
    /// the start of one, or every word in its title.
    func extensionCommandRows(_ text: String) -> (rows: [Suggestion], exact: Suggestion?) {
        guard #available(macOS 15.4, *) else { return ([], nil) }
        let words = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !words.isEmpty else { return ([], nil) }
        var rows: [Suggestion] = []
        var exact: Suggestion?
        for group in Extensions.of(self).commandGroups() {
            for entry in group.commands where !entry.kept.off {
                let alias = entry.kept.alias
                let byAlias = !alias.isEmpty && alias.hasPrefix(words)
                let byName = words.count >= 2 && ShortcutsPage.says(entry.title, words)
                guard byAlias || byName else { continue }
                let row = Suggestion(key: entry.title, title: group.short, url: nil,
                                     kind: .page("ext:" + entry.extensionID + "\u{1F}" + entry.command))
                if alias == words { exact = row; rows.insert(row, at: 0) } else { rows.append(row) }
            }
        }
        return (Array(rows.prefix(4)), exact)
    }

    func takeExtensionCommandRow(_ what: String) {
        guard #available(macOS 15.4, *) else { return }
        let parts = what.dropFirst(4).split(separator: "\u{1F}", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        // A Chromium tab in front: the extension's Chromium copy runs it, for that tab.
        if let tab = active, tab.engineKind == .chromium, !ExtensionCommands.off(parts[0], parts[1]),
           ChromiumExtensionCommands.row(parts[0], in: ChromiumExtensionCommands.native(for: tab))?
               .commands.contains(where: { $0.name == parts[1] }) == true {
            ChromiumExtensionCommands.run(parts[0], command: parts[1], in: tab)
            return
        }
        Extensions.of(self).run(parts[0], command: parts[1])
    }

    /// The keys a command row says at its end, and its extension's icon.
    static func extensionCommand(_ what: String) -> (keys: String?, icon: NSImage?) {
        guard #available(macOS 15.4, *) else { return (nil, nil) }
        let parts = what.dropFirst(4).split(separator: "\u{1F}", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return (nil, nil) }
        let extensions = Extensions.here
        let entry = extensions.commandGroups().first { $0.item.id == parts[0] }?.commands.first { $0.command == parts[1] }
        return (entry?.keys?.text, extensions.buttons.first { $0.id == parts[0] }?.icon ?? extensions.icon(for: parts[0], side: 16))
    }
}

extension Browser {
    /// Only extensions already allowed to read this page, never an activeTab
    /// request made merely by opening the field. Sleeping extensions stay asleep.
    func pageExtensionRows(on tab: Tab) -> [FieldPageRows.Candidate] {
        guard #available(macOS 15.4, *), let url = tab.address else { return [] }
        let extensions = Extensions.of(tab: tab)
        return extensions.commandGroups().flatMap { group -> [FieldPageRows.Candidate] in
            guard !tab.shy || Store.settings.bool(forKey: "extensions.private") else { return [] }
            let reaches: Bool
            if let context = extensions.contexts[group.item.id] {
                reaches = context.hasAccess(to: url, in: extensions.adapter(for: tab))
            } else {
                let id = group.item.id
                let blocked = extensions.blocked(id).flatMap { Extensions.patterns(for: $0) }.contains { $0.matches(url) }
                switch extensions.access(id) {
                case .click: reaches = false
                case .sites:
                    reaches = !blocked && extensions.allowed(id).flatMap { Extensions.patterns(for: $0) }.contains { $0.matches(url) }
                case .asked:
                    let choices = Extensions.choices(id)
                    let patterns = group.item.permissions.compactMap { $0.hasPrefix("site:") ? String($0.dropFirst(5)) : nil }
                        + choices.compactMap { $0.value ? $0.key : nil }
                    let denied = choices.contains { !$0.value && (try? WKWebExtension.MatchPattern(string: $0.key))?.matches(url) == true }
                    reaches = !blocked && !denied && patterns.contains { (try? WKWebExtension.MatchPattern(string: $0))?.matches(url) == true }
                }
            }
            guard reaches else { return [] }
            return group.commands.filter { !$0.kept.off }.map { command in
                let id = "ext:" + command.extensionID + "\u{1F}" + command.command
                return .init(id: id, kind: command.press ? .extensionButtons : .extensionCommands,
                    row: Suggestion(key: command.title, title: command.press ? "Extension" : group.short, url: nil, kind: .page(id)))
            }
        }
    }
}
