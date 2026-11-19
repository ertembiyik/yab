import AppKit
import SwiftUI

// Settings › AI › Assistants (docs/assistants.md):
// the address an assistant is given, Enter Code for the code it shows, each
// assistant linked with what it may do and what it asked for.

@MainActor
enum AssistantConnectIntent {
    static var bot: String?
    static var code: String?
    static var selection: AssistantBot? = .dots
}

struct AssistantsPage: View {
    var browser: Browser
    var model: SettingsModel
    private var assistants = Assistants.shared
    private var host = AssistantHost.shared
    private var sync = SyncCenter.shared
    private var connect = AssistantConnect.shared
    @State private var codeGeneration = 0

    var body: some View {
        Group {
            switch model.opened {
            case AssistantPlace.code:
                AssistantCodePage(browser: browser, model: model).id("\(codeGeneration)-\(AssistantCodeHandoff.revision)")
            case AssistantPlace.add:
                intro(adding: !assistants.grants.isEmpty)
            case let opened? where opened.hasPrefix(AssistantPlace.detail):
                ThreadForm { AssistantDetailPage(id: String(opened.dropFirst(AssistantPlace.detail.count)), browser: browser, model: model) }.formStyle(.grouped)
            default:
                // Nothing connected yet: a way in, not a form.
                if assistants.grants.isEmpty && assistants.requests.isEmpty {
                    intro(adding: false)
                } else {
                    ThreadForm { home }.formStyle(.grouped)
                }
            }
        }
        // A code the connection brought back opens Enter a Code with it.
        .onChange(of: connect.found) { _, found in
            guard let found else { return }
            connect.found = nil
            openCode(found.code, nonce: found.nonce, client: found.bot.client)
        }
        .onReceive(NotificationCenter.default.publisher(for: .assistantBotConnect)) { note in
            guard let name = note.object as? String, let bot = AssistantBot(rawValue: name) else { return }
            AssistantConnectIntent.bot = nil
            openAdd(bot)
            connect.connect(bot)
        }
        .onReceive(NotificationCenter.default.publisher(for: .assistantAuthorizationCode)) { note in
            guard let code = note.object as? String else { return }
            AssistantConnectIntent.code = nil
            guard connect.code.isEmpty else { return }
            connect.clear()
            openCode(code)
        }
        .onDisappear { if model.page != .assistants { connect.justConnected = nil } }
        .onAppear {
            if let found = connect.found {
                connect.found = nil
                openCode(found.code, nonce: found.nonce, client: found.bot.client)
            } else if let code = AssistantConnectIntent.code {
                AssistantConnectIntent.code = nil
                guard connect.code.isEmpty else { return }
                connect.clear()
                openCode(code)
            } else if let name = AssistantConnectIntent.bot, let bot = AssistantBot(rawValue: name) {
                AssistantConnectIntent.bot = nil
                openAdd(bot)
                connect.connect(bot)
            }
        }
    }

    /// Enter a Code, a page further in: empty, with a code that came in, or
    /// with a bot's own message to copy.
    private func openCode(_ code: String? = nil, nonce: String? = nil, client: String? = nil) {
        codeGeneration += 1
        AssistantCodeHandoff.code = code
        AssistantCodeHandoff.nonce = nonce
        AssistantCodeHandoff.client = client
        model.open(.assistants, item: AssistantPlace.code)
        SettingsWindow.shared.window?.makeKeyAndOrderFront(nil)
    }

    private func openAdd(_ bot: AssistantBot?) {
        AssistantConnectIntent.selection = bot
        model.open(.assistants, item: AssistantPlace.add)
    }

    private func intro(adding: Bool) -> some View {
        AssistantsIntro(browser: browser, initial: model.opened == AssistantPlace.add ? AssistantConnectIntent.selection : .dots, adding: adding,
                        back: { connect.clear(); model.leave(AssistantPlace.add, to: .assistants) },
                        enterCode: { code, client in openCode(code, client: client) })
    }

    /// Connected: what asks for an answer first, then the assistants, then
    /// the ones still to add.
    @ViewBuilder private var home: some View {
        PageHero(page: .assistants)
        if !assistants.requests.isEmpty {
            Section {
                ForEach(assistants.requests, id: \.key) { request in
                    if let grant = assistants.grant(request.assistant) {
                        HStack(spacing: 12) {
                            AssistantBotIcon(client: grant.client, side: 28)
                            SettingsRow("\(grant.name) asks for \(Self.words(request))", detail: request.reason) {
                                HStack(spacing: 8) {
                                    Button("Don\u{2019}t Allow") { assistants.answer(request, yes: false) }
                                        .settingsButton()
                                    Button("Allow") { assistants.answer(request, yes: true) }
                                        .buttonStyle(.yab(.primary, .regular))
                                }
                            }
                        }
                    }
                }
            }
        }
        if !assistants.grants.isEmpty {
            Section {
                ForEach(assistants.grants.sorted { $0.made > $1.made }, id: \.id) { grant in
                    AssistantRow(grant: grant, browser: browser) {
                        model.open(.assistants, item: AssistantPlace.detail + grant.id)
                    }
                    .settingsAnchor("assistant-" + grant.id)
                    .listRowBackground(connect.justConnected == grant.id ? Color.accentColor.opacity(0.08) : Color.clear)
                }
            } footer: {
                SettingsNote(footer)
            }
        }
        Section {
            // Every bot, one already connected too: a second one, for another
            // space, is a connection of its own.
            ForEach(AssistantBot.allCases) { bot in
                let have = assistants.grants.filter { $0.client.lowercased() == bot.client }.count
                HStack(spacing: 12) {
                    AssistantBotIcon(client: bot.client, side: 28)
                    SettingsRow(bot.rawValue, detail: have == 0 ? bot.place : "\(bot.place) \u{00B7} \(have) connected") {
                        Button("Add…") { connect.clear(); openAdd(bot) }.settingsButton()
                    }
                }
            }
            SettingsRow("Another assistant", detail: "Connect ChatGPT, Claude.ai or another agent using its code.") {
                Button("Add…") { connect.clear(); openAdd(nil) }
                    .settingsButton()
            }
            .settingsAnchor("assistants-add")
            if PhoneBeta.waiting {
                SettingsRow("Approve on your iPhone", detail: "Connect Yab for iPhone through Sync to approve assistant requests remotely.") {
                    PhoneBetaCode(side: 72)
                }
                .settingsAnchor("assistants-iphone")
            }
        } header: {
            Text("Add an Assistant").foregroundStyle(.secondary)
        } footer: {
            if let trouble = connect.trouble { TroubleLine(words: trouble) }
        }
    }

    static func message(client: String, nonce: String?) -> String {
        "Connect Yab as my browser. On your own computer, run `npx -y yab-mcp@latest login --client \(client)\(nonce.map { " --nonce \($0)" } ?? "")`, and show me its eight-character code. Don't ask me for a Yab Sync key or token."
    }

    private var footer: String {
        switch host.state {
        case .online, .connecting, .off:
            let phone = sync.assistantAnswerers.contains { SyncPhones.isPhone($0.model) }
            return "They work in their own tabs, in one space or all spaces you allow. Sending, paying and deleting wait for your yes, here\(phone ? " or on your iPhone" : " or on another device in Sync")."
        case .offline(let why): return "Can\u{2019}t reach the server right now (\(why)). Assistants will find this Mac again once it\u{2019}s back."
        }
    }

    static func words(_ request: AssistantRequest) -> String {
        switch request.what {
        case "mail": return "your mail"
        case "messages": return "codes from Messages"
        case "cards": return "your saved cards and addresses"
        default: return request.site.map { "\($0)" } ?? "a site"
        }
    }
}

private extension AssistantRequest {
    var key: String { assistant + what + (site ?? "") }
}

/// One assistant: its face, its name, what it is doing and where, its
/// switch; the row opens its page.
private struct AssistantRow: View {
    let grant: AssistantGrant
    var browser: Browser
    let open: () -> Void
    private var agents = Agents.shared
    private var approvals = AssistantApprovals.shared

    private var space: String { grant.spaceName(in: browser.spaces) }

    var body: some View {
        let status = AssistantConnect.shared.justConnected == grant.id ? "Connected just now" : AssistantDetailPage.status(grant, agents: agents, approvals: approvals)
        HStack(spacing: 12) {
            AssistantBotIcon(client: grant.client, side: 28)
                .opacity(grant.paused ? 0.5 : 1)
            VStack(alignment: .leading, spacing: 3) { // design: SettingsRow's gap under a title
                Text(grant.name)
                Text("\(status) · \(space)")
                    .font(.callout)
                    .foregroundStyle(status == "Needs you" ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(grant.name, isOn: Binding(get: { !grant.paused }, set: { on in Assistants.shared.update(grant.id) { $0.paused = !on } }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            SettingsChevron()
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .accessibilityAction(named: "Open", open)
    }
}

/// The same scope choice when connecting and when editing an assistant.
struct AssistantSpaceRow: View {
    let spaces: [Space]
    @Binding var selection: UUID?

    var body: some View {
        MenuRow("Space", options: [(title: "All spaces", value: Optional<UUID>.none)]
                + spaces.map { (title: $0.name, value: Optional($0.id)) }, selection: $selection)
    }
}
