import SwiftUI
import YabStore

struct ExperimentalPage: View {
    @Bindable var prefs: Preferences
    var model: SettingsModel
    private var keys = APIKeys.shared
    @AppStorage(SwitcherStrip.key, store: Store.settings) private var switcherStrip = false

    var body: some View {
        PageHero(page: .experimental)
        Section {
            SettingsRow("Mail", detail: "Experimental support for Gmail, iCloud, Zoho, Yahoo, Fastmail and other IMAP accounts. Turning off hides Mail and stops syncing; local mail and accounts are kept.") {
                Toggle(SettingsWords.text("Mail"), isOn: $prefs.usesMail)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .settingsAnchor("experimental-mail")
            SettingsRow("More Commands in the Field", detail: "Find the rest of the menu actions in ⌘T and Actions: more folder, Space, window, project and developer commands.") {
                Toggle("More Commands in the Field", isOn: $prefs.menuCommands)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .settingsAnchor("experimental-menu-commands")
            SettingsRow("Recent Tabs Over the Page", detail: "⌃Tab shows your recent tabs in a row on the page, which blurs around them, instead of in a card.") {
                Toggle("Recent Tabs Over the Page", isOn: $switcherStrip)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .settingsAnchor("experimental-switcher-strip")
            SettingsRow("Actions in the Field", detail: "Suggest actions for requests typed in ⌘T, such as scheduling a meeting.") {
                Toggle("Actions in the Field", isOn: $prefs.fieldRequests)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .settingsAnchor("experimental-requests")
            if prefs.fieldRequests {
                // The key and the model live in AI › Models, as every other
                // model and key does.
                SettingsRow("Reading the Field", detail: who) {
                    Button("Change in Models") {
                        if let item = SettingsItem.all.first(where: { $0.id == "agents-model-field" }) { model.take(.item(item)) } else { model.go(.models) }
                    }
                    .settingsButton()
                }
            }
        }
    }

    private var who: String {
        if FieldReader.chosen == .jev, keys.anyOpenRouter, keys.on { return "TypeSafe Jev using your OpenRouter API key." }
        return FormModel.ready ? "Uses this Mac's model, or TypeSafe Jev with your OpenRouter API key." : "Basic requests only without a model. Connect TypeSafe Jev with your OpenRouter API key for more."
    }
}
