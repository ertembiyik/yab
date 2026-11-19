import SwiftUI
import YabStore

/// Your own API keys, rows in Settings › AI › Models' Plans beside the
/// plans they stand in for, added from its Add Account list. Anthropic's
/// and OpenAI's are accounts of Claude's and ChatGPT's (PlanAccounts, after
/// the plans by default); OpenRouter's run TypeSafe Jev (OpenRouterKey).
/// As many of each as you like: tasks try them top to bottom, and one
/// turned away sits out a minute while the next takes over.
@MainActor
@Observable final class APIKeys {
    static let shared = APIKeys()

    enum Provider: String, CaseIterable, Identifiable {
        case anthropic, openai, openrouter
        var id: String { rawValue }

        var name: String {
            switch self {
            case .anthropic: "Anthropic"
            case .openai: "OpenAI"
            case .openrouter: "OpenRouter"
            }
        }
        /// The agent a key of this provider runs; nil for OpenRouter's.
        var cli: String? {
            switch self {
            case .anthropic: "claude"
            case .openai: "codex"
            case .openrouter: nil
            }
        }
        var mark: String { cli == nil ? "key" : cli == "codex" ? "brand.openai" : "brand.claude" }
        var placeholder: String { cli.map(AgentKey.placeholder) ?? "sk-or-v1-…" }
        var keysPage: URL { cli.map(AgentKey.keysPage) ?? URL(string: "https://openrouter.ai/settings/keys")! }
        var console: String { cli.map(AgentKey.console) ?? "OpenRouter" }
        /// What it runs, after the list's line: "for Claude".
        var runs: String { cli.map(AgentSetupModel.plan) ?? "Jev" }
        var blurb: String {
            switch self {
            case .anthropic, .openai: "\(runs) runs on it when your plans are out. Billed per use by \(name), kept in this Mac’s keychain."
            case .openrouter: "TypeSafe Jev reads the field on it. Billed per use by OpenRouter, kept in this Mac’s keychain."
            }
        }

        static func of(_ cli: String) -> Provider { cli == "codex" ? .openai : .anthropic }
    }

    /// The key page, in Models' place: whose key, and the account or
    /// OpenRouter key it replaces, if any.
    struct Page: Equatable {
        var provider: Provider
        var replacing: String?
    }

    var page: Page?
    /// OpenRouter's keys, by id, in the order Jev tries them.
    private(set) var openRouter: [String] = OpenRouterKey.ids
    var on = OpenRouterKey.on {
        didSet { Store.settings.set(on, forKey: OpenRouterKey.onKey) }
    }

    var anyOpenRouter: Bool { !openRouter.isEmpty }

    func open(_ provider: Provider, replacing: String? = nil) {
        page = Page(provider: provider, replacing: replacing)
    }

    /// The key in, after its provider took it. Nil when it is in; else why
    /// not, said under the field. An agent not connected yet is connected
    /// with it, the way Agents' Use an API Key does.
    func take(_ key: String, on page: Page, _ browser: Browser) async -> String? {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let cli = page.provider.cli else {
            if OpenRouterKey.has(key) { return PlanAccounts.keyHere }
            guard await OpenRouterKey.verify(key) else { return "OpenRouter didn’t take this key. Check it and paste it again." }
            let first = !anyOpenRouter
            if let id = page.replacing { OpenRouterKey.replace(id, with: key) } else { OpenRouterKey.add(key) }
            openRouter = OpenRouterKey.ids
            on = true
            // A first key picks Jev to read the field: that is what it is for.
            if first { FieldReader.chosen = .jev }
            return nil
        }
        let setup = AgentSetupModel.shared
        if page.replacing == nil, !setup.connected(cli) {
            setup.connect(cli, key: key, browser)
            return nil
        }
        if let id = page.replacing { return await PlanAccounts.shared.replaceKey(id, key) }
        return await PlanAccounts.shared.addKey(cli, key)
    }

    func removeOpenRouter(_ id: String) {
        OpenRouterKey.remove(id)
        openRouter = OpenRouterKey.ids
        if openRouter.isEmpty, FieldReader.chosen == .jev { FieldReader.chosen = .system }
    }

    func moveOpenRouter(_ id: String, by step: Int) {
        OpenRouterKey.move(id, by: step)
        openRouter = OpenRouterKey.ids
    }
}

/// An OpenRouter key's row in Plans: OpenRouter, its last four letters and
/// what it runs, whether Jev reads on it now, and the rest behind ···.
struct OpenRouterKeyRow: View {
    let id: String
    var browser: Browser
    private var keys = APIKeys.shared

    var body: some View {
        HStack(spacing: 12) {
            // OpenRouter's own app icon (Resources/AgentIcons), as the plans wear theirs.
            AgentMark(cli: "openrouter", side: 24) // design: PlanAccountRow.markSide
            VStack(alignment: .leading, spacing: 3) { // design: SettingsRow's own gap
                Text("OpenRouter")
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            SettingsMoreMenu("More options for OpenRouter key", entries: entries) {
                Symbol("ellipsis", size: 14)
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24) // design: PlanAccountRow.markSide
                    .contentShape(Rectangle())
            }
        }
    }

    private func entries() -> [SettingsMenuEntry] {
        var entries: [SettingsMenuEntry] = [
            .item("Manage in OpenRouter") {
                browser.tuning = false
                browser.open(APIKeys.Provider.openrouter.keysPage, foreground: true)
            },
            .item("Replace Key…") { keys.open(.openrouter, replacing: id) },
        ]
        if keys.openRouter.first != id {
            entries.append(.item("Move Up") { keys.moveOpenRouter(id, by: -1) })
        }
        if keys.openRouter.last != id {
            entries.append(.item("Move Down") { keys.moveOpenRouter(id, by: 1) })
        }
        entries.append(.destructive("Remove Key") { keys.removeOpenRouter(id) })
        return entries
    }

    private var detail: String {
        // Who first, as on the plans' rows: "API key …ae9c".
        var parts = ["API key " + (OpenRouterKey.key(id).map(AgentKey.tail) ?? "…")]
        if let until = OpenRouterKey.out(id) {
            parts.append("Turned away, back " + PlanAccounts.when(until))
        } else if !keys.on || FieldReader.chosen != .jev {
            parts.append("Jev is off in Reading the Field")
        } else if let running = OpenRouterKey.read(), OpenRouterKey.key(id) == running {
            parts.append(keys.openRouter.count > 1 ? "Runs TypeSafe Jev · In use" : "Runs TypeSafe Jev")
        }
        return parts.joined(separator: " · ")
    }
}

/// Add an API key, a page in Models' place (Settings' way in, as Agents'
/// Connect and Mail's Other Account are): Models' tile wearing the
/// provider's mark, one field, and one button that checks the key with the
/// provider and keeps it. Taken, it is back to Models, where its row says
/// so; turned down, why, under the field, the key kept there to fix.
struct APIKeyPage: View {
    var browser: Browser
    let page: APIKeys.Page
    private var keys = APIKeys.shared
    @State private var key = ""
    @State private var checking = false
    @State private var trouble: String?

    private var provider: APIKeys.Provider { page.provider }
    private var blank: Bool { key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var title: String {
        if checking { return "Checking the key with \(provider.name)…" }
        return page.replacing == nil ? "Add an \(provider.name) Key" : "Replace \(provider.name) Key"
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ArrivalFrame {
                VStack(spacing: 0) {
                    mark
                    Text(title)
                        .font(.system(size: 17, weight: .medium))
                        .padding(.top, 16)
                        .id(title)
                        .transition(.opacity)
                    Text(provider.blurb)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 340)
                        .padding(.top, 6)
                    SecureField("API Key", text: $key, prompt: Text(provider.placeholder))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        // The way in centers its words; a key reads from the left.
                        .multilineTextAlignment(.leading)
                        .frame(width: 340)
                        .disabled(checking)
                        .onSubmit { go() }
                        .onChange(of: key) { _, _ in trouble = nil }
                        .padding(.top, 16)
                    if let trouble {
                        TroubleLine(words: trouble)
                            .frame(maxWidth: 360)
                            .padding(.top, 12)
                    }
                    if checking {
                        Button("Cancel") { checking = false }
                            .settingsButton(.quiet)
                            .padding(.top, 20)
                    } else {
                        Button(page.replacing == nil ? "Add Key" : "Replace Key") { go() }
                            .settingsButton(.primary)
                            .disabled(blank)
                            .padding(.top, 20)
                        Button("Get a Key from \(provider.name)") {
                            browser.tuning = false
                            browser.open(provider.keysPage, foreground: true)
                        }
                        .settingsButton(.quiet)
                        .padding(.top, 8)
                    }
                }
                .animation(Motion.settle, value: checking)
                .animation(Motion.settle, value: trouble)
            }
            Button {
                keys.page = nil
            } label: {
                HStack(spacing: 4) {
                    Symbol("chevron.left", size: 11, weight: .semibold)
                    Text("Models")
                }
            }
            .settingsButton(.quiet)
            .keyboardShortcut(.cancelAction)
            .padding(12)
        }
    }

    /// Models' tile, the provider's mark in its corner, a seam going round
    /// while the provider is asked.
    private var mark: some View {
        let size: CGFloat = 56
        let corner = (size * 0.42).rounded()
        return FeatureTile(icon: SettingsPage.models.icon, tint: SettingsPage.models.tint ?? .systemRed, side: size)
            .overlay { Seam(size: size, corner: size * 0.26, working: checking, ticked: false) }
            .notched(true, side: corner, radius: corner / 2, offset: corner * 0.28, gap: 2.5)
            .overlay(alignment: .bottomTrailing) {
                Symbol(provider.mark, size: corner * 0.56)
                    .foregroundStyle(Palette.ink)
                    .frame(width: corner, height: corner)
                    .background(Circle().fill(Palette.ink.opacity(0.08)))
                    .offset(x: corner * 0.28, y: corner * 0.28)
            }
            .accessibilityHidden(true)
    }

    private func go() {
        guard !blank, !checking else { return }
        checking = true
        trouble = nil
        let asked = key
        Task {
            let said = await keys.take(asked, on: page, browser)
            // Cancel pressed meanwhile: nothing said, the page stays.
            guard checking else { return }
            checking = false
            if let said { trouble = said } else { keys.page = nil }
        }
    }
}
