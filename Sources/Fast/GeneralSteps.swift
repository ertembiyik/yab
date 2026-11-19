import AppKit
import SwiftUI

/// The top of Settings › General while Yab is new here: the two things done
/// once, open links in Yab and bring over another browser, side by side in
/// one group. Each goes the moment it is done, with no tick and no word of
/// success; with both done there is nothing here at all and General starts
/// with Yab itself.
struct GeneralSteps: View {
    /// Only handed to Bring In: nothing here is drawn from it, so its every
    /// change needn't draw the steps again.
    let browser: Browser
    /// The welcome's own: the browsers on this Mac, what each holds, and
    /// bringing one over with a press. Settings keeps it, so the row at
    /// the foot of General knows whether the step is up here.
    var bringing: Bringing
    var model: SettingsModel
    let isDefault: Bool
    let makeDefault: () -> Void
    /// The app links go to now, found when Settings opens, never here.
    private var links = DefaultBrowser.shared
    /// What macOS said when it was asked for the other browser's key.
    @State private var refused: String?

    var body: some View {
        Group {
            if !isDefault || Self.offersBring(bringing) {
                Section {
                    HStack(alignment: .top, spacing: 16) {
                        if !isDefault { defaultStep }
                        if !isDefault && Self.offersBring(bringing) { Divider() }
                        if Self.offersBring(bringing) { bringStep }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .onAppear { if !Bringing.everBrought { bringing.load() } }
    }

    /// Something to bring, and nothing brought yet: from here or from the
    /// welcome, ever.
    static func offersBring(_ bringing: Bringing) -> Bool {
        guard !Bringing.everBrought, bringing.loaded, bringing.chosen != nil else { return false }
        if case .done = bringing.state { return false }
        return true
    }

    // MARK: Links

    /// How many times the step has been drawn: a test draws it and checks
    /// that macOS was asked nothing meanwhile.
    static var drawnDefaultStep = 0

    private var defaultStep: some View {
        Self.drawnDefaultStep += 1
        let current = links.app
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                // Its place held while the icon is on its way.
                Group {
                    if let icon = current?.icon { Self.icon(icon) } else { Color.clear.frame(width: 20, height: 20) }
                }
                Symbol("arrow.right", size: 10, weight: .semibold).foregroundStyle(.tertiary)
                Self.icon(NSApplication.shared.applicationIconImage)
            }
            .accessibilityHidden(true)
            Text(SettingsWords.text("Open links in Yab"))
                .font(.system(size: 13, weight: .semibold))
            Text(current.map { SettingsWords.format("Links from Mail, Slack and other apps open here, not in %@.", [$0.name]) }
                 ?? SettingsWords.text("Links from Mail, Slack and other apps open here."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(SettingsWords.text("Make Default"), action: makeDefault)
                .settingsButton(.primary)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsAnchor("default-browser")
    }

    private static func icon(_ image: NSImage) -> some View {
        Image(nsImage: image)
            .resizable()
            .frame(width: 20, height: 20)
    }

    // MARK: Another browser

    private var bringStep: some View {
        let name = bringing.chosen?.name ?? SettingsWords.text("another browser")
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                ForEach(bringing.sources.prefix(3)) { source in
                    if let icon = bringing.icons[source.id] { Self.icon(icon) }
                }
            }
            .accessibilityHidden(true)
            Text(SettingsWords.format(bringing.busy ? "Bringing in from %@…" : "Bring in from %@", [name]))
                .font(.system(size: 13, weight: .semibold))
            Text(bringDetail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if bringing.busy || bringing.asking {
                    ProgressView().controlSize(.small)
                } else {
                    Button(SettingsWords.text(failed ? "Try Again" : "Bring In")) {
                        refused = nil
                        bringing.bring(into: browser) { answer in
                            if case .failed(let words) = answer { refused = words; return false }
                            return true
                        }
                    }
                    .settingsButton()
                    // Another browser, a file, extensions: the whole page.
                    Button(SettingsWords.text("Other Browsers…")) { model.go(.bringIn) }
                        .buttonStyle(.yab(.quiet))
                }
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var failed: Bool {
        if refused != nil { return true }
        if case .failed = bringing.state { return true }
        return false
    }

    /// What will come, counted ahead; what went wrong, when something did.
    private var bringDetail: String {
        if let refused { return refused }
        if case .failed(let words) = bringing.state { return words }
        if bringing.busy { return SettingsWords.text("Passwords, cards, tabs and sign-ins are coming over. It all stays on this Mac.") }
        let counts = bringing.current
        var parts: [String] = []
        if let passwords = counts.passwords, passwords > 0 { parts.append(SettingsWords.format("%@ passwords", [passwords.formatted()])) }
        if let cards = counts.cards, cards > 0 { parts.append(cards == 1 ? SettingsWords.text("1 card") : SettingsWords.format("%ld cards", [cards])) }
        if let bookmarks = counts.bookmarks, bookmarks > 0 { parts.append(SettingsWords.format("%@ bookmarks", [bookmarks.formatted()])) }
        let what = parts.isEmpty ? SettingsWords.text("Its tabs, passwords, bookmarks and sign-ins") : parts.joined(separator: SettingsWords.text(", ")) + SettingsWords.text(", its tabs and sign-ins")
        return what + SettingsWords.text(". It all stays on this Mac.")
    }
}
