import SwiftUI

/// Settings › Small Window, the way Arc has a page for Little Arc: what it
/// is for at the top, as every feature's page has it, and the ways into it.
struct SmallWindowPage: View {
    @Bindable var prefs: Preferences
    private var newKey = Keymap.shared.slot(.newSmallWindow)
    private var keepKey = Keymap.shared.slot(.peekTab)
    private var closeKey = Keymap.shared.slot(.closeTab)
    private var heard = LinkWindow.globalKey

    var body: some View {
        PageHero(page: .smallWindow)
        Section {
            SettingsSwitch("Give links from other apps a small window", isOn: $prefs.smallLinks)
                .settingsAnchor("small-links")
            SettingsSwitch("Open a small window with \(newKey.keys?.settingsHint ?? "a shortcut") in any app", isOn: $prefs.smallKey)
                .settingsAnchor("small-key")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if prefs.smallKey && heard.state == .taken {
                    SettingsNote("Another app uses \(newKey.keys?.settingsHint ?? "this shortcut"). Close that app or choose another hotkey in Shortcuts.")
                }
                SettingsNote("\(keepKey.keys.map { $0.settingsHint + " or " } ?? "")Open moves the page to your tabs. \(closeKey.keys.map { $0.settingsHint + " closes" } ?? "Close closes") this window.")
            }
        }
    }
}
