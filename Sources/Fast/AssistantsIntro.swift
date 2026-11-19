import AppKit
import SwiftUI

// Settings › AI › Assistants before any assistant is connected: not a form
// but a way in, as Agents is (AgentsIntro). The bots' faces, what connecting
// gives, the pick, one button. From the press on, the picked face is the
// same thing growing into the middle with a ring round it, what is not in
// the next step goes first, the title and the button change in place, and a
// failure is said under the button until the next press.

/// The bots Yab knows how to connect by itself.
enum AssistantBot: String, CaseIterable, Identifiable {
    case dots = "dots", muse = "Muse", grok = "Grok Bot"
    var id: String { rawValue }
    var client: String { self == .grok ? "grok-bot" : rawValue.lowercased() }
    var url: String { switch self {
        case .dots: return "https://chatgpt.com/dots"
        case .muse: return "https://muse.ai"
        case .grok: return "https://grok.com/?product=grok-bot"
    } }
    var detail: String { switch self {
        case .dots: return "Your dots assistant in ChatGPT"
        case .muse: return "Your Muse assistant"
        case .grok: return "Your Grok Bot"
    } }
    /// Where its chat is, as the way in says it.
    var place: String { switch self {
        case .dots: return "In ChatGPT"
        case .muse: return "muse.ai"
        case .grok: return "x.ai"
    } }

    /// Recognize the bot's actual chat as well as its public introduction.
    static func at(_ url: URL) -> AssistantBot? {
        guard url.scheme == "https", let host = url.host()?.lowercased() else { return nil }
        if host == "chatgpt.com", url.path.hasPrefix("/dots") { return .dots }
        if host == "muse.ai" || host == "www.muse.ai" { return .muse }
        if host == "x.ai", url.path == "/bot" || url.path.hasPrefix("/bot/") { return .grok }
        if host == "grok.com" {
            if url.path == "/bot" || url.path.hasPrefix("/bot/") { return .grok }
            if url.path == "/", URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .contains(where: { $0.name == "product" && $0.value == "grok-bot" }) == true { return .grok }
        }
        return nil
    }
}

/// Connect, pressed: an agent task that asks the bot for a code in a tab of
/// its own and reads it back. Shared by the way in and the page's rows, so
/// leaving the page doesn't lose it.
@MainActor
@Observable final class AssistantConnect {
    static let shared = AssistantConnect()

    /// The bot being connected, while it is.
    private(set) var bot: AssistantBot?
    /// The task's tab is open: Show Tab brings it forward.
    private(set) var tabOpen = false
    private(set) var needsYou = false
    var code = ""
    private(set) var stopped: AssistantBot?
    var justConnected: String?
    @ObservationIgnored private var lastSession: String?
    /// Why the last try stopped, until the next press.
    var trouble: String?
    /// The bot whose connection stopped without a code: the way in offers
    /// its message to send by hand, until the next press or Back.
    var stalled: AssistantBot?
    /// A code the task brought back with the nonce it has to carry; the
    /// page takes it and opens Enter a Code with it.
    var found: Found?

    struct Found: Equatable {
        let code: String
        let nonce: String
        let bot: AssistantBot
    }

    @ObservationIgnored private var session: String?
    @ObservationIgnored private var run = 0

    func connect(_ bot: AssistantBot) {
        guard self.bot == nil else { return }
        guard Agents.installed else {
            trouble = "Connect Claude or ChatGPT in Settings › AI › Models first."
            return
        }
        let nonce = Assistants.newID()
        trouble = nil
        stalled = nil
        tabOpen = false
        let entrance = bot == .grok ? "Open Bots in the sidebar and select the person's existing bot. Use its /bot/ chat, not the ordinary Grok chat or the marketing site. If sign-in is needed, use Yab's handoff and wait for the person before continuing. " : ""
        let prompt = "Open \(bot.url) in a tab of your own. \(entrance)Find the chat with \(bot.rawValue) in the person's signed-in Yab and send this message exactly: \(AssistantsPage.message(client: bot.client, nonce: nonce)) The person pressed Connect for this, which is their yes to sending exactly that message: send it without asking. Read its reply and return the eight-character Yab connection code in XXXX-XXXX form. If the site needs sign-in, call handoff and wait for the person. If this site has no web chat, say that plainly; do not guess a code."
        guard let task = Agents.shared.task(prompt, context: [], on: nil, said: "Connect \(bot.rawValue) to Yab",
                                            name: "Connect \(bot.rawValue)") else {
            trouble = "Couldn\u{2019}t start the connection. Enter its code below."
            return
        }
        let mine = begin(bot, session: task.id)
        Task { @MainActor in
            for _ in 0..<300 {
                try? await Task.sleep(for: .seconds(1))
                guard mine == run else { return }
                if !tabOpen, Self.tab(of: task.id) != nil { tabOpen = true }
                needsYou = task.state == .waiting || task.state == .signingIn || task.permission != nil
                let words = task.result.replacingOccurrences(of: nonce, with: "")
                if let match = words.range(of: "\\b[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}\\b", options: .regularExpression) {
                    if receive(String(words[match]), nonce: nonce, bot: bot, attempt: mine),
                       let browser = Self.tab(of: task.id)?.0 ?? BrowserWindows.shared.browsers.first {
                        browser.openSettings(.assistants)
                    }
                    return
                }
                if !task.state.live { break }
            }
            guard mine == run else { return }
            end()
            stalled = bot
            trouble = "\(bot.rawValue) didn\u{2019}t send a code."
        }
    }

    /// A generation owns its result. Cancellation invalidates it before stopping
    /// the process, so an already queued reply cannot replace manual input.
    @discardableResult
    func begin(_ bot: AssistantBot, session: String? = nil) -> Int {
        run += 1
        self.bot = bot
        self.session = session
        if let session { lastSession = session }
        found = nil
        stalled = nil
        stopped = nil
        trouble = nil
        tabOpen = false
        needsYou = false
        code = ""
        return run
    }

    @discardableResult
    func receive(_ code: String, nonce: String, bot: AssistantBot, attempt: Int) -> Bool {
        guard attempt == run, self.bot == bot else { return false }
        end()
        found = Found(code: code, nonce: nonce, bot: bot)
        return true
    }

    func editCode(_ text: String) {
        let clean = CodeGroupsField.clean(text)
        guard clean != code else { return }
        if let bot {
            cancel()
            stopped = bot
        }
        code = clean
        found = nil
        stalled = nil
        trouble = nil
    }

    func clear() {
        cancel()
        code = ""
        stopped = nil
        stalled = nil
        trouble = nil
        found = nil
    }

    /// Cancel: the task stops and the way in is as it was.
    func cancel() {
        let stopping = session
        end()
        found = nil
        if let stopping { _ = Agents.shared.stop(stopping) }
    }

    /// Show Tab: the task's tab in front, in its space and window.
    func showTab() {
        guard let session = session ?? lastSession, let (browser, tab) = Self.tab(of: session) else { return }
        if !browser.tabs.contains(where: { $0.id == tab.id }), let space = browser.spaceHolding(tab.id) {
            browser.switchSpace(to: space)
        }
        browser.select(tab)
        (BrowserWindows.shared.window(for: browser) ?? Links.window)?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Isolated native previews use the production states without starting an
    /// agent or sending a message to somebody's signed-in account.
    func preview(_ state: String, bot: AssistantBot) {
        guard Store.testing else { return }
        clear()
        switch state {
        case "connecting", "waiting":
            _ = begin(bot)
            tabOpen = true
            needsYou = state == "waiting"
        case "stalled": stalled = bot
        case "stopped":
            _ = begin(bot)
            editCode("K7Q")
        default: break
        }
    }

    private func end() {
        run += 1
        bot = nil
        session = nil
        tabOpen = false
        needsYou = false
    }

    private static func tab(of session: String) -> (Browser, Tab)? {
        for browser in BrowserWindows.shared.browsers {
            if let tab = browser.everyTab.first(where: { $0.agent == session }) { return (browser, tab) }
        }
        return nil
    }
}

/// The same path for first connection and Add… from an existing list. The
/// code field lives outside the changing header, preserving focus and input.
struct AssistantsIntro: View {
    var browser: Browser
    var initial: AssistantBot? = .dots
    var adding = false
    var back: () -> Void = {}
    var enterCode: (String, String?) -> Void
    private var connect = AssistantConnect.shared
    private var assistants = Assistants.shared
    private var setup = AgentSetupModel.shared
    @State private var pick: AssistantBot? = .dots
    @State private var face: AssistantBot?
    @State private var revealed = false
    @State private var ring = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var faces

    /// Every bot, one already connected too: a second one for another space
    /// is a connection of its own.
    private var available: [AssistantBot] { AssistantBot.allCases }
    private var hasAgent: Bool {
        if Store.testing, let set = Store.settings.object(forKey: "assistants.probe.agent") as? Bool { return set }
        return Agents.installed
    }
    private var reduced: Bool { reduceMotion || (Store.testing && Store.settings.bool(forKey: "assistants.probe.reduceMotion")) }
    private var named: String { (connect.bot ?? connect.stalled ?? pick)?.rawValue ?? "your assistant" }

    var body: some View {
        Group {
            if adding { addingForm } else { firstRun }
        }
        .transaction { transaction in
            if reduced {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
        .onAppear { pick = connect.bot ?? connect.stalled ?? initial }
        .task(id: connect.bot) { await transition(to: connect.bot) }
    }

    private var firstRun: some View {
        GeometryReader { bounds in
            let compact = bounds.size.height < 540
            ThreadScrollView {
                VStack(spacing: compact ? 8 : 16) {
                    if let bot = face ?? connect.stalled {
                        progress(bot, compact: compact)
                    } else {
                        selection(compact: compact)
                    }
                    // Keep this immediately after the controls. It is never a
                    // bottom-pinned footer or inside the scrolling list.
                    codeEntry(compact: compact)
                    if !hasAgent, pick != nil, face == nil, connect.stalled == nil {
                        help(compact: compact)
                    }
                }
                .frame(maxWidth: 412)
                .padding(.horizontal, compact ? 16 : 24)
                .padding(.vertical, compact ? 10 : 24)
                .frame(maxWidth: .infinity, minHeight: bounds.size.height)
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    // MARK: - Add… from the list

    /// The bot was chosen in the list, so this page is a Settings page about
    /// that one: its head, the ways to connect it, the code.
    private var addingForm: some View {
        ThreadForm {
            if let bot = face ?? connect.stalled {
                Section {} header: {
                    progress(bot, compact: true)
                        .font(.system(size: 13))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.primary)
                        .textCase(nil)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 8)
                }
            } else {
                addingHead
                addingConnect
            }
            addingCode
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var addingHead: some View {
        if let bot = pick {
            let have = assistants.grants.filter { $0.client.lowercased() == bot.client }
            PageHero(title: have.isEmpty ? bot.rawValue : "Another \(bot.rawValue)",
                     detail: have.isEmpty
                        ? "They open tabs on this Mac, signed in as you. Sending, paying and deleting wait for your yes."
                        : "Your first \(bot.rawValue) stays connected, in \(have[0].spaceName(in: browser.spaces)). This one gets its own spaces and permissions.") {
                AssistantBotIcon(client: bot.client, side: 56)
            }
        } else {
            PageHero(title: "Another Assistant", detail: "Connect ChatGPT, Claude.ai or another agent using its code.") {
                Symbol("plus", size: 24).frame(width: 56, height: 56).background(Palette.wash, in: Circle())
            }
        }
    }

    @ViewBuilder private var addingConnect: some View {
        if let bot = pick {
            Section {
                if let stopped = connect.stopped {
                    SettingsRow("Stopped Asking \(stopped.rawValue)", detail: "Its code won\u{2019}t replace yours.") {
                        Button("Keep Asking") { start(stopped) }.settingsButton()
                    }
                } else if hasAgent {
                    SettingsRow("Connect \(bot.rawValue)", detail: "Opens \(bot.rawValue) in a tab and brings its code back.") {
                        Button("Connect") { start(bot) }.settingsButton(.primary)
                    }
                } else {
                    SettingsRow("Let Yab Fetch It", detail: "Needs Claude or ChatGPT to open \(bot.rawValue) for you.") {
                        Button("Set Up") { browser.openSettings(.models) }.settingsButton()
                    }
                }
                SettingsRow("No Code Yet?", detail: "Paste this message into \(bot.rawValue)\u{2019}s chat.") {
                    Button("Copy Message") { copyMessage(bot) }.settingsButton()
                }
            } header: {
                Text("Connect").foregroundStyle(.secondary)
            } footer: {
                if let trouble = connect.trouble { TroubleLine(words: trouble) }
            }
        } else {
            let address = AssistantHost.origin.appending(path: "mcp").absoluteString
            Section {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) { // design: SettingsRow's gap under a title
                        Text("Add Yab as a Connector")
                        Text(address)
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                    Button("Copy Address") { copy(address) }.settingsButton()
                }
                SettingsRow("Agent with a Terminal", detail: "Hermes, OpenClaw and the like. Paste the message into its chat.") {
                    Button("Copy Message") { copyMessage(nil) }.settingsButton()
                }
            } header: {
                Text("Connect").foregroundStyle(.secondary)
            } footer: {
                SettingsNote("In ChatGPT, Claude.ai or any app with connectors. Its sign-in page brings the code here by itself.")
            }
        }
    }

    private var addingCode: some View {
        Section {
            SettingsRow("Enter Its Code", detail: connect.bot != nil ? "Already have it? Type it, and Yab stops."
                        : pick.map { "The code \($0.rawValue) showed." } ?? "The code the app or agent showed.") {
                CodeGroupsField(code: Binding(get: { connect.code }, set: { connect.editCode($0) }),
                                autofocus: !hasAgent || connect.stopped != nil || pick == nil, onPaste: submit, onSubmit: submit)
                    .accessibilityIdentifier("assistant-code")
            }
            if !connect.code.isEmpty {
                HStack {
                    Spacer(minLength: 0)
                    Button(action: submit) {
                        HStack(spacing: 6) { Text("Continue"); KeyGlyphs(keys: "\u{21A9}", size: 12.5, tint: nil).opacity(0.6) }
                    }
                    .settingsButton(.primary)
                    .disabled(connect.code.count != CodeGroupsField.length)
                    .keyboardShortcut(.defaultAction)
                }
            }
        } header: {
            Text("Code").foregroundStyle(.secondary)
        }
    }

    @MainActor private func transition(to bot: AssistantBot?) async {
        if reduced {
            withAnimation(.easeInOut(duration: 0.12)) { face = bot; revealed = bot != nil; ring = bot != nil }
            return
        }
        if let bot {
            revealed = false
            ring = false
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            withAnimation(Motion.glide) { face = bot }
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled else { return }
            withAnimation(Motion.quick) { ring = true }
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled else { return }
            withAnimation(Motion.quick) { revealed = true }
        } else {
            ring = false
            withAnimation(Motion.glide) { face = nil; revealed = false }
        }
    }

    private func selection(compact: Bool) -> some View {
        VStack(spacing: compact ? 8 : 16) {
            VStack(spacing: 6) {
                Text("Let your assistants use Yab")
                    .font(.system(size: 17, weight: .medium))
                if pick != nil || !compact {
                    Text("They open tabs on this Mac, signed in as you. Sending, paying and deleting wait for your yes.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .opacity(connect.bot == nil ? 1 : 0)
            HStack(spacing: 8) {
                ForEach(available) { bot in tile(bot, compact: compact) }
                tile(nil, compact: compact)
            }
            if let stopped = connect.stopped {
                HStack(spacing: 8) {
                    Symbol("stop", size: 12).foregroundStyle(.secondary)
                    Text("Stopped asking \(stopped.rawValue). Its code won’t replace yours.")
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    Button("Keep Asking") { start(stopped) }.settingsButton()
                }
                .padding(10)
                .background(Palette.ground, in: RoundedRectangle(cornerRadius: Radius.surface))
            } else if let pick, hasAgent {
                VStack(spacing: 6) {
                    Button { start(pick) } label: { Text("Connect \(pick.rawValue)").frame(minWidth: 156) }
                        .settingsButton(.primary)
                    Text("Opens \(pick.rawValue) in a tab and brings its code back.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .opacity(connect.bot == nil ? 1 : 0)
            } else if pick == nil {
                connector(compact: compact)
            }
            if let trouble = connect.trouble { TroubleLine(words: trouble) }
        }
        .animation(reduced ? .easeOut(duration: 0.12) : Motion.quick, value: connect.bot)
        .transition(.opacity.combined(with: .offset(y: 6)))
    }

    private func tile(_ bot: AssistantBot?, compact: Bool) -> some View {
        Button {
            pick = bot
            connect.clear()
        } label: {
            VStack(spacing: compact ? 4 : 6) {
                Group {
                    if let bot {
                        AssistantBotIcon(client: bot.client, side: 36)
                            .matchedGeometryEffect(id: bot.client, in: faces, properties: reduced ? [] : .frame)
                    } else {
                        Symbol("plus", size: 16).frame(width: 36, height: 36)
                            .background(Palette.wash, in: Circle())
                    }
                }
                Text(bot?.rawValue ?? "Another").font(.system(size: 12)).opacity(connect.bot == nil ? 1 : 0)
                Text(bot.map { $0 == .dots ? "ChatGPT" : $0.place } ?? "any app")
                    .font(.system(size: 11)).foregroundStyle(.secondary).opacity(connect.bot == nil ? 1 : 0)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, compact ? 8 : 12)
            .background(Palette.ground.opacity(connect.bot == nil ? 1 : 0), in: RoundedRectangle(cornerRadius: Radius.surface))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.surface)
                    .strokeBorder(pick == bot ? Color.accentColor : Palette.ink.opacity(0.08), lineWidth: pick == bot ? 2 : 0.5)
                    .opacity(connect.bot == nil ? 1 : 0)
            }
            .opacity(connect.bot == nil || connect.bot == bot ? 1 : 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(pick == bot ? .isSelected : [])
    }

    private func progress(_ bot: AssistantBot, compact: Bool) -> some View {
        let stalled = connect.stalled != nil
        let needsYou = connect.needsYou && !stalled
        let side: CGFloat = compact ? 48 : 66
        return VStack(spacing: compact ? 10 : 16) {
            AssistantBotIcon(client: bot.client, side: side)
                .matchedGeometryEffect(id: bot.client, in: faces, properties: reduced ? [] : .frame)
                .opacity(stalled ? 0.45 : 1)
                .overlay {
                    if needsYou {
                        Circle().strokeBorder(Color.orange, lineWidth: 2).padding(-6)
                        Symbol("exclamationmark.circle.fill", size: 17)
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                            .offset(x: 7, y: 7)
                    } else if ring && !stalled { RoundRing(side: side) }
                }
                .padding(6)
            VStack(spacing: 6) {
                Text(stalled ? "\(bot.rawValue) didn’t send a code" : needsYou ? "Sign in to \(bot == .dots ? "ChatGPT" : bot.rawValue)" : "Connecting \(bot.rawValue)")
                    .font(.system(size: 17, weight: .medium))
                Text(stalled ? "Its tab is still open if you want to see why."
                     : needsYou ? "\(bot.rawValue)’s tab needs you. Yab goes on once you’re in."
                     : "Asking \(bot.rawValue) for a code in a tab of its own.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .opacity(ring || stalled || reduced ? 1 : 0)
            .offset(y: ring || stalled || reduced ? 0 : 8)
            if !stalled {
                steps(bot, compact: compact)
                    .opacity(revealed ? 1 : 0)
            }
            HStack(spacing: 8) {
                if stalled { Button("Try Again") { start(bot) }.settingsButton(.primary) }
                Button("Show Tab") { connect.showTab() }
                    .settingsButton(needsYou ? .primary : .secondary)
                    .disabled(!connect.tabOpen && !stalled)
                if !stalled { Button("Cancel") { connect.clear() }.settingsButton() }
            }
            .opacity(revealed || stalled || reduced ? 1 : 0)
            if stalled {
                Button("Send It a Message Yourself") { copyMessage(bot) }.settingsButton(.quiet)
            }
        }
    }

    private func steps(_ bot: AssistantBot, compact: Bool) -> some View {
        let host = URL(string: bot.url)?.host() ?? bot.url
        return Group {
            if compact {
                Text(connect.needsYou ? "Waiting for you to sign in" : connect.tabOpen ? "Opened \(host), waiting for its reply" : "Opening \(host)")
                    .foregroundStyle(connect.needsYou ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Label(connect.tabOpen ? "Opened \(host)" : "Opening \(host)", systemImage: connect.tabOpen ? "checkmark" : "circle.fill")
                        .foregroundStyle(.secondary)
                    Label(connect.needsYou ? "Waiting for you to sign in" : "Waiting for \(bot.rawValue)’s reply", systemImage: "circle.fill")
                        .foregroundStyle(connect.needsYou ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.primary))
                    Label("You say yes", systemImage: "circle.fill").foregroundStyle(.tertiary)
                }
            }
        }
        .font(.system(size: 12))
    }

    private func codeEntry(compact: Bool) -> some View {
        VStack(spacing: compact ? 8 : 12) {
            HStack(spacing: 10) {
                Rectangle().fill(Palette.ink.opacity(0.1)).frame(height: 0.5)
                Text(connect.bot != nil ? "already have it? Type it, and Yab stops" : "or enter the code \(pick?.rawValue ?? "it") showed")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize()
                Rectangle().fill(Palette.ink.opacity(0.1)).frame(height: 0.5)
            }
            CodeGroupsField(code: Binding(get: { connect.code }, set: { connect.editCode($0) }),
                            autofocus: !hasAgent || connect.stopped != nil, onPaste: submit, onSubmit: submit)
                .accessibilityIdentifier("assistant-code")
            if !connect.code.isEmpty || (!hasAgent && pick != nil) {
                Button(action: submit) {
                    HStack(spacing: 6) { Text("Continue"); KeyGlyphs(keys: "↩", size: 12.5, tint: nil).opacity(0.6) }
                }
                .settingsButton(.primary)
                .disabled(connect.code.count != CodeGroupsField.length)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func connector(compact: Bool) -> some View {
        VStack(spacing: compact ? 6 : 12) {
            Text("Add Yab as a connector").fontWeight(.medium)
            Text("In ChatGPT, Claude.ai or any app with connectors. Its sign-in page brings the code here by itself.")
                .font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text(AssistantHost.origin.appending(path: "mcp").absoluteString)
                    .font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                Button("Copy Address") { copy(AssistantHost.origin.appending(path: "mcp").absoluteString) }.settingsButton()
            }
            .padding(10).background(Palette.ground, in: RoundedRectangle(cornerRadius: Radius.surface))
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Agent with a terminal?")
                    if !compact { Text("Hermes, OpenClaw and the like: send it a message instead.").font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
                Button("Copy Message") { copyMessage(nil) }.settingsButton()
            }
            .multilineTextAlignment(.leading)
        }
    }

    private func help(compact: Bool) -> some View {
        VStack(spacing: compact ? 6 : 10) {
            helpRow("Let Yab fetch it", detail: "Needs Claude or ChatGPT to open \(named) for you.", button: "Set Up") { browser.openSettings(.models) }
            helpRow("No code yet?", detail: "Paste this message into \(named)’s chat.", button: "Copy Message") { copyMessage(pick) }
        }
        .padding(10).background(Palette.ground, in: RoundedRectangle(cornerRadius: Radius.surface))
    }

    private func helpRow(_ title: String, detail: String, button: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            Button(button, action: action).settingsButton()
        }
    }

    private func start(_ bot: AssistantBot) { pick = bot; connect.clear(); connect.connect(bot) }
    private func submit() {
        guard connect.code.count == CodeGroupsField.length else { return }
        enterCode(connect.code, pick?.client)
    }
    private func copyMessage(_ bot: AssistantBot?) { copy(AssistantsPage.message(client: bot?.client ?? "your-assistant", nonce: nil)) }
    private func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
}

/// Waiting, round a round face: SquareRing's arc on a circle, a little
/// outside it. Its track is drawn in first, then the arc grows to a quarter
/// and only then runs.
struct RoundRing: View {
    let side: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn: CGFloat = 0

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { time in
            let turn = reduceMotion ? 0 : time.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.1) / 1.1
            let arc = 0.24 * drawn
            ZStack {
                Circle().trim(from: 0, to: drawn)
                    .stroke(Palette.ink.opacity(0.1), lineWidth: 2)
                Circle().trim(from: turn, to: min(1, turn + arc))
                    .stroke(Palette.ink, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                if turn + arc > 1 {
                    Circle().trim(from: 0, to: turn + arc - 1)
                        .stroke(Palette.ink, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                }
            }
            .rotationEffect(.degrees(-90))
        }
        .frame(width: side + 12, height: side + 12)
        .onAppear { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { drawn = 1 } }
    }
}
