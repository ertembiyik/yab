import AppKit
import YabCoreClient

/// Extensions' keyboard shortcuts (manifest "commands") in Chromium tabs, as
/// Chrome keeps and runs them (register 2343: 1Password's ⇧⌘X).
///
/// Chrome's CommandService keeps each command's key in the profile, from the
/// manifest's suggestion at install or as chrome://extensions/shortcuts set
/// it; YabCore reads it with the list (`extension.list`) and writes it as that
/// page does (`extension.command`).
///
/// A named command's key, ⌘ or not, is Chrome's own to run while the page
/// has the keyboard: the hidden BrowserView's ExtensionKeybindingRegistryViews
/// hears it and sends commands.onCommand with the tab, activeTab granted (main
/// did, job d0de3219ff914b4e). Yab leaves it to the page, so it never runs
/// twice. Chrome's registry leaves the button's command to a toolbar
/// CEF_CTT_NONE has none of, so that one is Yab's: it presses the button as a
/// click does (Chrome's RunAction: a popup, or action.onClicked, activeTab
/// granted). A named command's key with the page not holding the keyboard (in
/// Yab's field), and a ⌘T alias, run through CEF patch 0116
/// (`extension.command.run`); a helper without it can't.
///
/// Yab's own shortcuts keep theirs (a browser's shortcut is never an
/// extension's; Settings › Shortcuts frees one before giving it), and the
/// button's key runs before the page, as Chromium runs extension keys ahead of
/// the page (ChromeCommandDispatcherDelegate, kHighPriority).
enum ChromiumExtensionCommands {
    /// The commands that press the button, MV2's two included.
    static let actionCommands: Set<String> = ["_execute_action", "_execute_browser_action", "_execute_page_action"]

    // MARK: - Chrome's key strings

    /// Chrome's names for the keys a command may have, by Yab's (Hotkey.key
    /// as a press reads, KeyLayout.named).
    private static let names: [String: String] = [
        ",": "Comma", ".": "Period", "home": "Home", "end": "End", "pageup": "PageUp", "pagedown": "PageDown",
        "space": "Space", " ": "Space", "⌦": "Delete", "⇥": "Tab",
        "↑": "Up", "↓": "Down", "←": "Left", "→": "Right",
    ]
    private static let keys: [String: String] = [
        "Comma": ",", "Period": ".", "Home": "home", "End": "end", "PageUp": "pageup", "PageDown": "pagedown",
        "Space": "space", "Delete": "⌦", "Tab": "⇥", "Up": "↑", "Down": "↓", "Left": "←", "Right": "→",
    ]

    /// A key as Chromium stores it on a Mac (Command::AcceleratorToString):
    /// "Command+Shift+X", "Ctrl+Alt+Comma". Command is ⌘ and Ctrl is ⌃ here,
    /// unlike a manifest's suggestion. Nil for one a Mac can't press (Insert,
    /// a media key) or no modifier but Shift.
    static func hotkey(stored combo: String) -> Hotkey? {
        var flags: NSEvent.ModifierFlags = []
        var key: String?
        for part in combo.split(separator: "+", omittingEmptySubsequences: false).map(String.init) {
            switch part {
            case "Command": flags.insert(.command)
            case "Ctrl": flags.insert(.control)
            case "Alt": flags.insert(.option)
            case "Shift": flags.insert(.shift)
            default:
                guard key == nil else { return nil }
                if let named = keys[part] { key = named }
                else if part.count == 1, let c = part.unicodeScalars.first, ("A"..."Z").contains(c) || ("0"..."9").contains(c) {
                    key = part.lowercased()
                } else { return nil }
            }
        }
        guard let key, !flags.subtracting(.shift).isEmpty else { return nil }
        return Hotkey(key, flags)
    }

    /// The same key in the form chrome://extensions/shortcuts writes
    /// (cr_shortcut_util keystrokeToString): Command, Ctrl, Alt, Shift, key.
    /// Nil for a key Chrome doesn't give commands (F keys, marks but , and .).
    static func stored(_ hotkey: Hotkey) -> String? {
        let key: String
        if let named = names[hotkey.key] { key = named }
        else if hotkey.key.count == 1, let c = hotkey.key.unicodeScalars.first, ("a"..."z").contains(c) || ("0"..."9").contains(c) {
            key = hotkey.key.uppercased()
        } else { return nil }
        guard !hotkey.flags.subtracting(.shift).isEmpty else { return nil }
        var parts: [String] = []
        if hotkey.flags.contains(.command) { parts.append("Command") }
        if hotkey.flags.contains(.control) { parts.append("Ctrl") }
        if hotkey.flags.contains(.option) { parts.append("Alt") }
        if hotkey.flags.contains(.shift) { parts.append("Shift") }
        return (parts + [key]).joined(separator: "+")
    }

    // MARK: - whose

    /// The Chromium list a tab runs, for a Chromium tab.
    @MainActor static func native(for tab: Tab?) -> ChromiumExtensions? {
        tab.flatMap { ChromiumColumn.shared.native(for: $0) }
    }

    /// The Chromium list whose keys Settings › Shortcuts shows for a sign-in's
    /// extensions: the front window's tab's, when that is a Chromium tab of
    /// this sign-in; else this sign-in's regular profile, as listed.
    @available(macOS 15.4, *)
    @MainActor static func native(for extensions: Extensions) -> ChromiumExtensions? {
        let front = BrowserWindows.shared.activeBrowser?.active
        if let front, !ChromiumColumn.isPrivate(front), let native = native(for: front),
           native.joined?.signIn == extensions.signIn { return native }
        return ChromiumExtensions.profiles.values
            .filter { !$0.privateMode && $0.joined.map { $0.signIn == extensions.signIn } == true }
            .sorted { $0.profile < $1.profile }.first
    }

    /// The enabled extension's row in `native`, with its commands, when it
    /// runs there.
    @MainActor static func row(_ id: String, in native: ChromiumExtensions?) -> ChromiumExtensions.Item? {
        native?.items.first { $0.id == id && $0.enabled && !$0.commands.isEmpty }
    }

    /// This helper runs named commands (patch 0116); without it, only the
    /// button's command is Yab's to run.
    @MainActor static var runsNamed: Bool { ChromiumProcess.shared.runsExtensionCommands }

    // MARK: - pressed

    /// A key pressed with a Chromium tab in front: the command Chrome gave it,
    /// run, and the key spent. Yab's own shortcuts and macOS's keep theirs;
    /// one turned off in Settings › Shortcuts isn't heard.
    @MainActor static func take(_ event: NSEvent, in browser: Browser) -> Bool {
        guard event.type == .keyDown, let tab = browser.active, tab.engineKind == .chromium,
              let native = native(for: tab) else { return false }
        let pressed = Hotkey.readings(event)
        guard pressed.contains(where: \.commands), Keymap.shared.action(for: event) == nil,
              !pressed.contains(where: { Shortcut.kept($0, from: nil) }) else { return false }
        let page = tab.builtPage as? ChromiumPage
        let typing = page.map { holdsKeyboard($0, in: event.window) } ?? false
        guard let (id, command) = owner(of: pressed, in: ChromiumColumn.shared.items(native, for: tab), pageHasKeys: typing) else { return false }
        // Held down, the one press it was: a popup isn't opened and closed
        // again for every repeat.
        if event.isARepeat { return true }
        if #available(macOS 15.4, *) { Extensions.lastTaken = id + "/" + command }
        run(id, command: command, in: tab)
        return true
    }

    /// The page has the keyboard: its key reaches Chrome's own registry.
    @MainActor static func holdsKeyboard(_ page: ChromiumPage, in window: NSWindow?) -> Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder === page || responder.isDescendant(of: page)
    }

    /// The extension and command a press is, among `items`: a key Chrome gave
    /// a command, Yab's to route, and that command on. A named command's is
    /// Chrome's own while the page has the keyboard (`pageHasKeys`).
    @MainActor static func owner(of pressed: [Hotkey], in items: [ChromiumExtensions.Item],
                                 pageHasKeys: Bool) -> (id: String, command: String)? {
        for item in items where item.enabled {
            for command in item.commands {
                guard let key = command.hotkey, pressed.contains(key), ExtensionCommands.routes(key),
                      !ExtensionCommands.off(item.id, command.name) else { continue }
                if !command.action {
                    // Chrome's registry hears it through the page; without
                    // the page, only a helper with 0116 can run it.
                    guard !pageHasKeys, !command.global, runsNamed else { return nil }
                }
                return (item.id, command.name)
            }
        }
        return nil
    }

    /// Runs one of an extension's commands for a Chromium tab: from its key,
    /// or from ⌘T. The button's presses its button, popup and all.
    @MainActor static func run(_ id: String, command: String, in tab: Tab) {
        if actionCommands.contains(command) {
            ChromiumColumn.shared.press(id, tab: tab)
            return
        }
        guard let page = tab.builtPage as? ChromiumPage else { return }
        Task { @MainActor in _ = await page.runExtensionCommand(id, command: command) }
    }

    /// Settings › Shortcuts' key for a command Chrome keeps: Chrome's, written
    /// as chrome://extensions/shortcuts writes it, then the list read again.
    @available(macOS 15.4, *)
    @MainActor static func setKey(_ hotkey: Hotkey?, extension id: String, command: String,
                                  in native: ChromiumExtensions, for extensions: Extensions) {
        Task { @MainActor [weak extensions] in
            do { try await native.setCommandKey(id, command: command, to: hotkey) }
            catch { native.failure = "\(command): \(error.localizedDescription)" }
            extensions?.actionsChanged += 1
        }
    }
}
