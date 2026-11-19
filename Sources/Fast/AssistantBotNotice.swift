import AppKit
import SwiftUI

extension Notification.Name {
    static let assistantBotConnect = Notification.Name("yab.assistantBotConnect")
}

/// An invitation in the browser's upper corner, once per supported bot site.
/// It is native UI, so page text and scripts cannot press Connect for a user.
struct AssistantBotNotice: View {
    let browser: Browser
    let tab: Tab?
    let top: CGFloat
    private var assistants = Assistants.shared
    private var setup = AgentSetupModel.shared
    @State private var dismissedSite: String?

    private var bot: String? {
        guard let url = tab?.address else { return nil }
        return AssistantBot.at(url)?.rawValue
    }

    private var visible: String? {
        guard let bot, setup.signedIn.values.contains(true), dismissedSite != bot,
              Store.settings.bool(forKey: "assistant.banner.dismissed.\(bot)") == false,
              !assistants.grants.contains(where: { $0.client.lowercased() == (bot == "Grok Bot" ? "grok-bot" : bot.lowercased()) })
        else { return nil }
        return bot
    }

    var body: some View {
        Group {
            if let bot = visible {
                HStack(spacing: 10) {
                    Text("\(bot) can browse in Yab")
                        .font(.callout.weight(.medium))
                    Button("Not Now") {
                        Store.settings.set(true, forKey: "assistant.banner.dismissed.\(bot)")
                        dismissedSite = bot
                    }
                    .buttonStyle(.yab(.secondary, .small))
                    Button("Connect") {
                        Store.settings.set(true, forKey: "assistant.banner.dismissed.\(bot)")
                        dismissedSite = bot
                        AssistantConnectIntent.bot = bot
                        browser.openSettings(.assistants)
                        NotificationCenter.default.post(name: .assistantBotConnect, object: bot)
                    }
                    .buttonStyle(.yab(.primary, .small))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .shadow(radius: 12, y: 4)
                .padding(.top, top)
                .padding(.trailing, 18)
                .accessibilityIdentifier("assistant.bot.notice")
            }
        }
        // Whether a plan is signed in is read only on a bot's own page, and
        // from files: the notice shows by itself, nobody asked, so it never
        // starts the login shell (Cortex).
        .task(id: bot) { if bot != nil { await setup.look(whereTasksRun: false) } }
    }
}
