import SwiftUI

// Settings › AI › While You Browse: the small things Yab does for you as you
// go, each a switch with what it does under its name, Arc Max's page as a
// page of ours (docs/tidy-names.md). Every rename it switches is drawn the
// same way, the old name going to dust as the new one comes in behind it
// (Rename.swift).

struct WhileYouBrowsePage: View {
    @Bindable var prefs: Preferences

    var body: some View {
        PageHero(page: .whileYouBrowse)
        Section {
            row("Tidy tabs", "Requires Apple Intelligence or a connected model (Claude or Codex).", $prefs.tidyTabs)
                .settingsAnchor("tidy-tabs")
            row("Tidy tab titles", "Shorten titles of kept tabs.", $prefs.tidyTitles)
                .settingsAnchor("tidy-titles")
            row("Folder names", "Name folders based on their tabs.", $prefs.folderNames)
                .settingsAnchor("folder-names")
            row("Tidy downloads", "Rename downloads based on their content.", $prefs.tidyDownloads)
                .settingsAnchor("tidy-downloads")
            keyed("Instant links", before: "", keys: "⇧↩", after: "opens the top search result.", $prefs.instantLinks)
                .settingsAnchor("ai-instant-links")
            keyed("Link previews", before: "Hold", keys: "⇧", after: "while hovering over a link to preview it.", $prefs.linkPreviews)
                .settingsAnchor("ai-link-previews")
        } footer: {
            if !FormModel.ready {
                SettingsNote("Requires Apple Intelligence on this Mac.")
                if PlanText.any { SettingsNote("Without Apple Intelligence, \(PlanText.writer) handles link previews and download names.") }
            }
        }
    }

    private func row(_ title: String, _ detail: String, _ on: Binding<Bool>) -> some View {
        SettingsRow(title, detail: detail) { toggle(title, on) }
    }

    /// A row whose line names a key: the key on its plate, as Mail's ⌘J.
    private func keyed(_ title: String, before: String, keys: String, after: String, _ on: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) { // design: SettingsRow's own gap
                Text(title)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if !before.isEmpty { Text(before) }
                    // A size under the words: at theirs the plate stood taller than the line.
                    KeyGlyphs(keys: keys, size: 11, tint: nil, rest: 0.6)
                    Text(after)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            toggle(title, on)
        }
    }

    private func toggle(_ title: String, _ on: Binding<Bool>) -> some View {
        Toggle(title, isOn: on)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
    }

    /// The AI page's line for this one: how many are on, or Off.
    @MainActor
    static func summary(_ prefs: Preferences) -> String {
        let all = [prefs.tidyTabs, prefs.tidyTitles, prefs.folderNames, prefs.tidyDownloads, prefs.instantLinks, prefs.linkPreviews]
        let on = all.filter { $0 }.count
        if on == 0 { return "Off" }
        return on == all.count ? "All on" : "\(on) of \(all.count) on"
    }
}
