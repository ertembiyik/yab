import SwiftUI

/// Settings' row for passwords from elsewhere, as WalletBringer is for
/// cards: brought in right there from every browser that has some, or
/// from one, the count said under the row as they are kept. Safari's
/// export goes to Passwords' own screen, which waits for the file; a CSV
/// file is chosen and read in place.
struct PasswordBringer: View {
    var browser: Browser
    let anchor: String
    /// Worn where the rows around it wear theirs (Passwords), not on Bring
    /// in, whose rows go without.
    var icon = false

    private enum Stage: Equatable {
        case counting
        case idle
        case bringing(String)
        case keeping(String, Int, Int)
        case said(String)
    }
    @State private var stage: Stage = .counting
    @State private var logins: [(source: Chromium.Source, count: Int)] = []

    var body: some View {
        Group {
            if icon {
                FeatureRow("Bring passwords in", icon: "tray.and.arrow.down", tint: .systemGray, detail: detail) { button }
            } else {
                SettingsRow("Bring passwords in", detail: detail) { button }
            }
        }
        .settingsAnchor(anchor)
        .task { count() }
    }

    @ViewBuilder
    private var button: some View {
        switch stage {
        case .bringing, .keeping:
            ProgressView().controlSize(.small)
        default:
            Menu("Bring In") {
                if logins.count > 1 {
                    Button("All Browsers") { bring(logins.map(\.source)) }
                    Divider()
                }
                ForEach(logins, id: \.source.id) { login in
                    Button(login.source.name) { bring([login.source]) }
                }
                if !logins.isEmpty { Divider() }
                Button("Safari…") {
                    browser.tuning = false
                    browser.openPlace(.passwords)
                    browser.bringMore()
                    browser.waitForSafari("safari")
                }
                // Firefox wraps its passwords with a key of its own: not
                // read from its profile, only from its own export.
                Button("Zen or Firefox…") { browser.importPasswords(message: FirefoxBringer.passwordsHow) }
                Button("CSV File…") { browser.importPasswords() }
            }
            .settingsButton()
            .fixedSize()
        }
    }

    private var detail: String {
        switch stage {
        case .counting: return "From Chrome, Arc, Safari or a CSV file."
        case .bringing(let name): return "Opening \(name)’s passwords…"
        case .keeping(let name, let done, let all): return "Keeping \(done.formatted()) of \(all.formatted()) from \(name)…"
        case .said(let text): return text
        case .idle:
            guard !logins.isEmpty else { return "From Chrome, Arc, Safari or a CSV file." }
            return "Choose a browser to import from. Existing items are kept."
        }
    }

    static func passwords(_ count: Int) -> String {
        "\(count.formatted()) password\(count == 1 ? "" : "s")"
    }

    /// Discover browser names without inspecting their credential stores.
    private func count() {
        DispatchQueue.global(qos: .userInitiated).async {
            let found = Chromium.installed().map { (source: $0, count: 0) }
            DispatchQueue.main.async {
                logins = found
                if stage == .counting { stage = .idle }
            }
        }
    }

    /// Each browser's in turn, its key asked once; one that says no doesn't
    /// stop the rest, and is named at the end.
    private func bring(_ sources: [Chromium.Source]) {
        guard let first = sources.first else { return }
        stage = .bringing(first.name)
        DispatchQueue.global(qos: .userInitiated).async {
            var kept = 0
            var refused: [String] = []
            for discovered in sources {
                let source = discovered.authorizingImport()
                DispatchQueue.main.async { stage = .bringing(source.name) }
                guard let found = try? Chromium.read(source) else { refused.append(source.name); continue }
                var said = Date.distantPast
                kept += Vault.take(found) { done, all in
                    guard Date().timeIntervalSince(said) > 0.1 || done == all else { return }
                    said = Date()
                    DispatchQueue.main.async { stage = .keeping(source.name, done, all) }
                }
            }
            DispatchQueue.main.async {
                let brought = kept == 0 ? "Nothing new: they are all here already." : "Brought in \(Self.passwords(kept))."
                let trouble = refused.isEmpty ? "" : " \(refused.joined(separator: " and ")) didn’t hand over \(refused.count == 1 ? "its" : "their") key: try again and choose Always Allow."
                stage = .said(brought + trouble)
            }
        }
    }
}
