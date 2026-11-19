import AppKit
import SwiftUI

// Settings › Agents before an agent is connected, and just after: not a form
// but a way in, in the middle of the pane, as Spaces and Extensions are.
// Four providers in a fixed order, with
// one explicit choice. From the press on, the
// agent's mark wears a ring round its square and the button says in its
// own place what is under way; a failure is said under it until the next
// press. Connected, a tick for a moment, and then how to ask for it, shown
// once (AgentsTry).

struct AgentsIntro: View {
    var browser: Browser
    private var setup = AgentSetupModel.shared
    private var geminiChoices = GeminiChoices.shared
    /// The mark is one thing through the steps: it moves, the words fade.
    @Namespace private var markSpace
    /// Use an API Key's field; kept after a key is turned down, to fix.
    @State private var key = ""
    /// Connect's field for the code Google shows after Allow, and whether
    /// the last paste wasn't a whole code.
    @State private var googleCode = ""
    @State private var badPaste = false
    private var gemini = GeminiAccount.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ArrivalFrame {
            Group {
                if geminiChoices.showing { GeminiArrival(browser: browser) }
                else { switch setup.flow {
                case .asking(let clis): AgentsTry(clis: clis, browser: browser, marks: markSpace)
                case .knowing: KnowStep(browser: browser, marks: markSpace)
                default: way
                } }
            }
            .animation(Motion.glide, value: setup.flow)
        }
        .task { await setup.look() }
        // Back in Yab, as Settings › Agents and Models look: a CLI installed
        // in Terminal meanwhile ("Not set up" until Yab was reopened, #2038).
        // Not while Connect runs: its own steps look for what they need.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard setup.flow == nil else { return }
            Task { await setup.look() }
        }
    }

    private var way: some View {
        let said = Self.words(flow: setup.flow, page: setup.page, ready: setup.ready, byHand: setup.installByHand, slow: setup.slow,
                              anyInstalled: anyInstalled, chosen: chosen, toInstall: toInstall, trouble: setup.trouble,
                              keyFor: setup.flow == nil ? setup.keyFor : setup.keying, keyBlank: blank,
                              geminiTasksGoTo: chosen == ["gemini"] ? ModelDefaults.geminiTasksGoTo : nil,
                              geminiIdentity: GeminiAccount.shared.identity, geminiChoice: GeminiAccount.shared.choice,
                              geminiPageOpen: gemini.pageOpen || gemini.waiting != .signingIn)
        return VStack(spacing: 0) {
            marks(ring: said.ring, tick: said.tick)
            Text(geminiSigningIn && gemini.submittingCode ? "Connecting Gemini"
                 : geminiSigningIn && gemini.codeError != nil ? "That code didn't work" : said.title)
                .font(.system(size: 17, weight: .medium))
                .padding(.top, 16)
                .id(said.title)
                .transition(.opacity)
            Text(geminiSigningIn && gemini.submittingCode ? "Got the code from Google. Checking it on this Mac…"
                 : geminiSigningIn ? gemini.codeError ?? said.detail : said.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 340)
                .frame(minHeight: 30)
                .padding(.top, 6)
            if setup.flow == nil, let cli = setup.keyFor {
                keyEntry(cli)
                    .padding(.top, 16)
            } else if setup.flow == nil {
                gains
                    .padding(.top, 16)
                picker
                    .padding(.top, 16)
            }
            if case .installing(let cli) = setup.flow, setup.installByHand {
                CommandSlot(text: AgentSetupModel.install(cli))
                    .frame(width: 340)
                    .padding(.top, 16)
            }
            if geminiSigningIn && (gemini.awaitingCode || gemini.codeError != nil) {
                geminiCodeEntry.padding(.top, 16)
            }
            // One button through every step, re-worded where it stands.
            if let button = said.button, !geminiSigningIn {
                Button(button) { said.shows ? setup.showSignIn() : go() }
                    .settingsButton(.primary)
                    .disabled(!said.enabled)
                    .padding(.top, 20)
            }
            if geminiSigningIn {
                HStack(spacing: 8) {
                    if !gemini.submittingCode {
                        Button("Show Sign-In") { gemini.showSignIn() }.settingsButton()
                    }
                    Button { setup.cancel() } label: {
                        HStack(spacing: 6) {
                            Text("Cancel")
                            KeyGlyphs(keys: "esc", size: 12.5, tint: nil, rest: 0.6)
                                .transaction { $0.animation = nil }
                        }
                    }
                    .settingsButton(.quiet)
                    .keyboardShortcut(.cancelAction)
                }.padding(.top, 16)
            }
            if said.cancel && !geminiSigningIn {
                Button("Cancel") { setup.cancel() }
                    .settingsButton(.quiet)
                    .padding(.top, 8)
            }
            if case .signingIn("gemini") = setup.flow, let email = GeminiAccount.shared.choice?.email {
                Text("If Google asks which account, choose " + email + ".")
                    .font(.caption).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 340).padding(.top, 12)
            }
            if setup.flow == nil {
                if let trouble = setup.trouble {
                    TroubleLine(words: trouble.words)
                        .frame(maxWidth: 360)
                        .padding(.top, 12)
                } else {
                    Text(setup.keyFor.map(AgentKey.hint) ?? footnote)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 360)
                        .padding(.top, 12)
                }
                // No plan: a key of your own, billed per use. Pressed
                // again, back to the plans.
                // Cursor takes no key: the button stays, for Claude's or ChatGPT's.
                Button(setup.keyFor == nil ? "Use an API Key" : "Use a Plan Instead") {
                    setup.clearFailure()
                    let keyed = (chosen + [toInstall]).first(where: AgentSetupModel.skilled) ?? "claude"
                    setup.keyFor = setup.keyFor == nil ? keyed : nil
                }
                .settingsButton(.quiet)
                .padding(.top, 8)
                .opacity(setup.ready ? 1 : 0)
                .disabled(!setup.ready)
                .accessibilityHidden(!setup.ready)
                .animation(reduceMotion ? nil : Motion.quick, value: setup.ready)
            }
        }
        .animation(Motion.settle, value: setup.flow)
        .animation(Motion.settle, value: setup.trouble)
        .onChange(of: gemini.awaitingCode) { _, waiting in if waiting { googleCode = ""; badPaste = false } }
        .onChange(of: setup.flow) { _, _ in googleCode = ""; badPaste = false }
        .onChange(of: googleCode) { _, _ in badPaste = false }
    }

    private var geminiSigningIn: Bool { setup.flow == .signingIn("gemini") }

    /// Google's hosted callback shows a code to paste. Yab relays it from
    /// the sign-in tab when it can; this field takes it by hand, shown
    /// while the CLI waits and after it turns a code down.
    private var geminiCodeEntry: some View {
        let waiting = gemini.awaitingCode
        let pasted = !googleCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let wrong = badPaste || gemini.codeError != nil
        return VStack(spacing: 8) {
            HStack(spacing: 8) {
                TextField("Paste the code from Google", text: $googleCode)
                    .font(.system(size: 12, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .accessibilityIdentifier("gemini-code")
                    .disabled(!waiting)
                    .onSubmit { sendGoogleCode() }
                    .overlay(RoundedRectangle(cornerRadius: Radius.small)
                        .strokeBorder(wrong ? Color.red : pasted ? Color.accentColor : Color.clear))
                Button { sendGoogleCode() } label: {
                    HStack(spacing: 6) {
                        Text("Connect")
                        KeyGlyphs(keys: "↩", size: 12.5, tint: nil, rest: 0.6)
                            .transaction { $0.animation = nil }
                    }
                }
                .settingsButton(.primary)
                .keyboardShortcut(.defaultAction)
                .disabled(!waiting || !pasted)
            }
            // After a turned-down code the card's own line says why.
            if gemini.codeError == nil {
                Text(badPaste ? "That isn't a whole code. Copy it from Google's page; it starts with 4/."
                     : pasted ? "Pasted. Connect sends it to Gemini."
                     : "After Allow, Google shows a code. Yab picks it up by itself; if it doesn't, paste it here.")
                    .font(.caption)
                    .foregroundStyle(badPaste ? Color.red : Color.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: 340)
    }

    private func sendGoogleCode() {
        guard gemini.awaitingCode else { return }
        if gemini.submitCode(googleCode) { googleCode = "" } else { badPaste = true }
    }

    // MARK: - what shows

    private var anyInstalled: Bool { AgentSetupModel.clis.contains { setup.installed($0) } }

    /// The ticked agents that are here; with none here, the one to install.
    private var chosen: [String] {
        AgentSetupModel.clis.filter { setup.picks.contains($0) }
    }

    private var toInstall: String {
        AgentSetupModel.clis.first { setup.picks.contains($0) } ?? "claude"
    }

    private var shown: [String] {
        switch setup.flow {
        case .installing(let cli), .signingIn(let cli): return [cli]
        case .preparing(let clis), .finishing(let clis), .landed(let clis), .asking(let clis): return clis
        case .knowing, nil:
            return chosen.isEmpty ? AgentSetupModel.clis : chosen
        }
    }

    private func marks(ring: Bool, tick: Bool) -> some View {
        let clis = shown
        return HStack(spacing: -12) {
            ForEach(clis, id: \.self) { cli in
                if cli == "gemini", shown.count == 1, setup.flow != nil {
                    GeminiAccountMark(email: GeminiAccount.shared.choice?.email ?? GeminiAccount.shared.identity?.email,
                                      photo: GeminiAccount.shared.choice?.photo, side: 56, connecting: ring)
                } else { AgentMark(cli: cli, side: clis.count > 1 ? 48 : 56) }
            }
        }
        .overlay { if ring && clis != ["gemini"] { SquareRing(side: 56) } }
        .matchedGeometryEffect(id: "mark", in: markSpace)
        .overlay(alignment: .bottomTrailing) {
            if tick {
                DoneTick(side: 22)
                    .offset(x: 6, y: 6)
                    .transition(.scale(scale: 0.2).combined(with: .opacity))
            }
        }
        .animation(Motion.glide, value: tick)
        .accessibilityHidden(true)
    }

    /// What the way in says and offers in one state, apart from the view
    /// so each state can be held to the table in docs/agents.md.
    struct Words: Equatable {
        var title: String
        var detail: String
        /// The one button's words, nil when there is none.
        var button: String?
        var enabled = false
        /// The button brings the sign-in back rather than starting anything.
        var shows = false
        /// Cancel, quiet, under the button.
        var cancel = false
        /// The ring round the mark.
        var ring = false
        /// The tick on it.
        var tick = false
    }

    static func words(flow: AgentSetupModel.Flow?, page: Agents.SignInPage? = nil, ready: Bool = true, byHand: Bool = false,
                      slow: Bool = false, anyInstalled: Bool = true, chosen: [String] = ["claude"], toInstall: String = "claude",
                      trouble: AgentSetupModel.Trouble? = nil, keyFor: String? = nil, keyBlank: Bool = true,
                      geminiTasksGoTo: String? = nil, geminiIdentity: GeminiIdentity? = nil,
                      geminiChoice: GeminiChoice? = nil, geminiPageOpen: Bool = true) -> Words {
        switch flow {
        case .preparing(let clis) where keyFor != nil:
            return Words(title: "Connecting \(names(clis))", detail: "Checking the key with \(AgentKey.provider(clis.first ?? "claude"))…",
                         button: "Connecting…", cancel: true, ring: true)
        case .finishing(let clis) where keyFor != nil:
            return Words(title: "Connecting \(names(clis))", detail: "Key taken. Adding Yab's skill and tools…", button: "Connecting…", ring: true)
        case .installing(let cli) where keyFor != nil && !byHand:
            return Words(title: "Setting up \(AgentSetupModel.name(cli))",
                         detail: slow ? "Still downloading. A slow connection can take a few minutes."
                             : "A minute or so, from \(AgentKey.provider(cli)). Then Yab checks your key.",
                         button: "Setting Up…", cancel: true, ring: true)
        case nil where keyFor != nil:
            let cli = keyFor ?? "claude"
            return Words(title: "Let your agent use Yab",
                         detail: "No \(AgentSetupModel.plan(cli)) plan? Connect with an API key of your own.",
                         button: trouble.map { Set($0.clis) == [cli] } == true ? "Try Again" : "Connect \(AgentSetupModel.name(cli))",
                         enabled: ready && !keyBlank)
        case .preparing(let clis):
            return Words(title: "Connecting \(names(clis))", detail: "Checking \(clis.count > 1 ? "them" : "it") on this Mac…",
                         button: "Connecting…", cancel: true, ring: true)
        case .installing(let cli):
            let name = AgentSetupModel.name(cli)
            if byHand {
                return Words(title: "Set up \(name) in Terminal",
                             detail: "Yab couldn't install \(AgentSetupModel.tool(cli)), the tool it runs for \(name), from here. Paste the command into the Terminal that just opened; Yab notices when it's there.",
                             button: "Waiting for Terminal…", cancel: true, ring: true)
            }
            return Words(title: "Setting up \(name)",
                         detail: slow ? "Still downloading. A slow connection can take a few minutes."
                             : "A minute or so, from \((AgentPlan.of(cli) ?? .claude).maker). Then you sign in, and that's all.",
                         button: "Setting Up…", cancel: true, ring: true)
        case .signingIn("gemini") where !geminiPageOpen:
            return Words(title: "Allow Gemini in Google", detail: "Opening Google's sign-in…",
                         button: "Show Sign-In", enabled: true, shows: true, cancel: true, ring: true)
        case .signingIn("gemini"):
            let detail = geminiChoice?.email.map { "A tab in \(geminiChoice?.place ?? "Yab") is asking. You're signed in there as \($0), so it's one Allow." }
                ?? "A private Yab tab is asking. Sign in to the Google account you want, then Allow."
            return Words(title: "Allow Gemini in Google", detail: detail,
                         button: "Show Sign-In", enabled: true, shows: true, cancel: true, ring: true)
        case .signingIn(let cli):
            let plan = AgentSetupModel.plan(cli)
            switch page {
            case .yab:
                return Words(title: "Sign in to \(plan)",
                             detail: "The sign-in is in a Yab tab. Yab closes it and carries on once you say yes there.",
                             button: "Show Sign-In", enabled: true, shows: true, cancel: true, ring: true)
            case .browser(let name):
                let place = name ?? "your browser"
                return Words(title: "Sign in to \(plan) in \(place)",
                             detail: "\(AgentSetupModel.name(cli)) opened its sign-in in \(place). Say yes there, then come back; Yab carries on by itself.",
                             button: "Open Sign-In Again", enabled: true, shows: true, cancel: true, ring: true)
            case .opening, nil:
                return Words(title: "Sign in to \(plan)", detail: "Opening the sign-in…", button: "Opening Sign-In…", cancel: true, ring: true)
            }
        case .finishing(let clis):
            // Cursor gets no skill: only its sign-in is checked.
            let detail = clis.contains(where: AgentSetupModel.skilled) ? "Signed in. Adding Yab's skill and tools…" : "Signed in. Checking your plan…"
            return Words(title: "Connecting \(names(clis))", detail: detail, button: "Connecting…", ring: true)
        case .landed(let clis), .asking(let clis):
            let detail = clis == ["gemini"] ? [geminiIdentity?.email, geminiIdentity?.plan].compactMap { $0 }.joined(separator: " · ") : " "
            return Words(title: "\(names(clis)) \(clis.count > 1 ? "are" : "is") connected", detail: detail, tick: true)
        case .knowing, nil:
            let detail = !ready ? "Checking this Mac…"
                : chosen == ["gemini"] ? geminiTasksGoTo.map { "Answers and chats on your Google plan. Gemini can\u{2019}t use Yab\u{2019}s tools yet, so tasks in your tabs run on \(AgentSetupModel.name($0))." }
                    ?? (GeminiSupport.toolsProven ? "Chats and tasks in your tabs on your Google plan."
                        : "Answers and chats on your Google plan. Browser tasks aren't available with Gemini yet.")
                : "Choose Claude, ChatGPT, Cursor or Gemini. Use the plan you already have."
            let button: String
            if !ready { button = "Connect" }
            else if chosen.isEmpty { button = "Choose a Provider" }
            else if chosen == ["gemini"] { button = trouble.map { Set($0.clis) == ["gemini"] } == true ? "Try Again" : "Continue" }
            else if !anyInstalled { button = "Connect \(AgentSetupModel.name(toInstall))" }
            else if let trouble, !chosen.isEmpty, Set(trouble.clis) == Set(chosen) { button = "Try Again" }
            else { button = "Connect \(names(chosen))".trimmingCharacters(in: .whitespaces) }
            return Words(title: "Choose your AI provider", detail: detail, button: button,
                         enabled: ready && !chosen.isEmpty)
        }
    }

    /// What connecting gives, in three lines: every AI thing in Yab runs on
    /// your own Claude Code or Codex, so none of it is there before.
    static let gains: [(icon: String, text: String)] = [
        (SettingsPage.commands.icon, "Improve, translate, explain selected text"),
        (SettingsPage.agents.icon, "Tasks you ask for in the address bar"),
        (SettingsPage.agentRoutines.icon, "Routines, and a memory of you on this Mac"),
    ]

    private var gains: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(chosen.isEmpty || chosen == ["gemini"] ? [
                (icon: SettingsPage.commands.icon, text: "Improve, translate, explain selected text"),
                (icon: SettingsPage.ai.icon, text: "Ask about pages and chat on your own plan"),
            ] : Self.gains, id: \.text) { gain in
                HStack(spacing: 8) {
                    Symbol(gain.icon, size: 12)
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text(gain.text)
                }
            }
        }
        .multilineTextAlignment(.leading)
        .fixedSize()
    }

    private var footnote: String {
        // Nothing to promise until Yab knows what is on this Mac; the line
        // keeps its height.
        guard setup.ready else { return " " }
        guard !chosen.isEmpty else { return "Connect one provider on your own plan." }
        guard anyInstalled else { return "Yab sets it up, then signs you in to your plan in a tab." }
        let out = chosen.filter { setup.signedIn[$0] != true }.map(AgentSetupModel.plan)
        return out.isEmpty
            // Signed in already: someone who has the tool itself, and wants to
            // know whose settings Yab changes.
            ? footnoteSkilled
            : "Signs in with your \(AgentSetupModel.list(out)) plan in a tab. Yab does the rest."
    }

    /// Signed in already: whose settings Yab changes. Cursor gets no
    /// skill, so it is left out; with only Cursor, nothing changes outside.
    private var footnoteSkilled: String {
        let tools = chosen.filter(AgentSetupModel.skilled).map(AgentSetupModel.tool)
        guard !tools.isEmpty else { return "Yab uses your \(Self.names(chosen)) plan. Disconnect stops that." }
        return "Adds Yab's skill and tools to \(AgentSetupModel.list(tools)). Disconnect takes back only that."
    }

    private func go() {
        if let cli = setup.keyFor { return setup.connect(cli, key: key, browser) }
        guard let cli = chosen.first else { return }
        if cli == "gemini" { setup.chooseGemini(browser); return }
        if setup.installed(cli) { setup.connect([cli], browser) } else { setup.install(cli, browser) }
    }

    private var blank: Bool { key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Use an API Key: whose key, and the key. The one button connects
    /// with it; the hint under it says who bills it.
    private func keyEntry(_ cli: String) -> some View {
        VStack(spacing: 10) {
            GlassTrack(title: "Agent",
                       options: AgentSetupModel.clis.filter(AgentSetupModel.skilled).map { (AgentSetupModel.plan($0), $0) },
                       room: 12, selection: Binding(get: { cli }, set: { setup.keyFor = $0; setup.clearFailure() }))
            .fixedSize()
            SecureField("API Key", text: $key, prompt: Text(AgentKey.placeholder(cli)))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .onSubmit { if !blank { go() } }
                .onChange(of: key) { _, _ in setup.clearFailure() }
            Button("Get a Key from \(AgentKey.provider(cli))") {
                browser.tuning = false
                browser.open(AgentKey.keysPage(cli), foreground: true)
            }
            .settingsButton(.quiet)
        }
        .frame(width: 340)
    }

    static func names(_ clis: [String]) -> String { AgentSetupModel.names(clis) }

    // MARK: - the choice

    /// All four providers are offered, with one explicit choice. An installed
    /// CLI never preselects another provider or hides one that needs setup.
    private var picker: some View {
        VStack(spacing: 0) {
            ForEach(Array(AgentSetupModel.clis.enumerated()), id: \.element) { index, cli in
                Button { setup.selectProvider(cli) } label: {
                    HStack(spacing: 12) {
                        AgentMark(cli: cli, side: 28)
                        providerWords(cli)
                        Symbol(setup.picks.contains(cli) ? "largecircle.fill.circle" : "circle", size: 16)
                            .foregroundStyle(setup.picks.contains(cli) ? Color.accentColor : Color.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Choose " + AgentSetupModel.name(cli))
                .accessibilityValue([providerStatus(cli), setup.picks.contains(cli) ? "Selected" : "Not selected"].compactMap { $0 }.joined(separator: ", "))
                .overlay(alignment: .top) { if index > 0 { Divider().padding(.horizontal, 12) } }
            }
        }
        .multilineTextAlignment(.leading)
        .frame(width: 340)
        .background(Palette.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: Radius.surface, style: .continuous))
    }

    private func providerStatus(_ cli: String) -> String? {
        guard setup.ready else { return nil }
        guard setup.installed(cli) else { return "Not set up" }
        return setup.signedIn[cli].map { $0 ? "Signed in" : "Signed out" }
    }

    private func providerWords(_ cli: String) -> some View {
        let status = providerStatus(cli)
        return ZStack(alignment: .leading) {
            Text(AgentSetupModel.name(cli))
                .offset(y: status == nil ? 0 : -8)
            if let status {
                Text(status)
                    .font(.callout)
                    .foregroundStyle(setup.signedIn[cli] == true ? Color.accentColor : Color.secondary)
                    .offset(y: 9)
                    .transition(.opacity.combined(with: .offset(y: 4)))
            }
        }
        .frame(height: 32)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(reduceMotion ? nil : Motion.settle, value: status)
    }

}

// MARK: - how to ask

/// Shown once, right after Connect: an agent asked for yab in its own
/// words, played out in a terminal or in its app, the line to copy, and
/// Continue. The moment the agent really opens a tab, it says so.
struct AgentsTry: View {
    let clis: [String]
    var browser: Browser
    let marks: Namespace.ID
    private var setup = AgentSetupModel.shared
    @State private var cli = ""
    @State private var inApp = false
    @State private var round = 0

    private var current: String { clis.contains(cli) ? cli : clis.first ?? "claude" }
    private var line: String { "use \(AgentSetupModel.mention(current)) to \(AgentDemo.ask)" }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: -12) {
                ForEach(clis, id: \.self) { AgentMark(cli: $0, side: clis.count > 1 ? 48 : 56) }
            }
            .matchedGeometryEffect(id: "mark", in: marks)
            .overlay(alignment: .bottomTrailing) { DoneTick(side: 22).offset(x: 6, y: 6) }
            .accessibilityHidden(true)
            Text(setup.tried.map { "\(AgentSetupModel.name($0)) is browsing" } ?? "Now ask \(AgentSetupModel.name(current))")
                .font(.system(size: 17, weight: .medium))
                .padding(.top, 16)
                .id(setup.tried ?? "ask")
                .transition(.opacity)
            Text(setup.tried != nil
                 ? "That was its tab, beside yours. Its face on the tab shows what it's doing; click the page and it waits for you."
                 : "Name Yab's skill, then say what you need. It works in tabs of its own, signed in as you.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 10) {
                if setup.tried == nil {
                    HStack(spacing: 8) {
                        if clis.count > 1 {
                            GlassTrack(title: "Agent", options: clis.map { (AgentSetupModel.name($0), $0) }, room: 12,
                                       selection: Binding(get: { current }, set: { cli = $0 }))
                                .fixedSize()
                        }
                        GlassTrack(title: "Where", options: [("Terminal", false), ("\(AgentSetupModel.name(current)) app", true)], room: 12,
                                   selection: $inApp)
                            .fixedSize()
                        Spacer()
                        Button("Replay") { round += 1 }
                            .buttonStyle(.yab(.quiet, .small))
                    }
                    AgentDemo(cli: current, inApp: inApp)
                        .id("\(current)-\(inApp)-\(round)")
                }
                // The line to copy, until the agent has used it: then its tab.
                if let tried = setup.tried {
                    HStack(spacing: 10) {
                        Symbol("agent.face", size: 12).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("A tab of its own, beside yours")
                            Text("Opened by \(AgentSetupModel.name(tried)) \(setup.lastUse[tried].map { AgentSetupModel.ago($0) } ?? "just now")")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(12)
                    .background(Palette.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    .transition(.opacity)
                } else {
                    CommandSlot(text: line, mention: AgentSetupModel.mention(current))
                }
            }
            .multilineTextAlignment(.leading)
            .frame(width: 520)
            .padding(.top, 20)
            Button(setup.tried != nil ? "Done" : "Continue") { setup.finish(browser.prefs) }
                .settingsButton(.primary)
                .padding(.top, 20)
        }
        .animation(Motion.settle, value: setup.tried)
    }
}

// MARK: - getting to know you

/// After How to Ask, while yab knows nothing about you: its own agent
/// offers to look you up once, and says in three lines what it is for.
/// Return starts it, Escape leaves it for later (the Memory row and the
/// new tab still offer it).
struct KnowStep: View {
    var browser: Browser
    let marks: Namespace.ID
    private var setup = AgentSetupModel.shared

    private let points: [(icon: String, tint: NSColor, title: String, detail: String)] = [
        ("doc", .systemGreen, "Fills forms for you", "Name, job, links, address."),
        ("magnifyingglass", .systemBlue, "Writes replies like you", "Ready when you open \u{2318}T."),
        ("key", .systemOrange, "Asks you less", "It knows your accounts and people."),
    ]

    var body: some View {
        VStack(spacing: 0) {
            PenTileView(page: .agents).frame(width: 56, height: 56)
                .matchedGeometryEffect(id: "mark", in: marks)
                .accessibilityHidden(true)
            Text("Let your agent get to know you")
                .font(.system(size: 17, weight: .medium))
                .padding(.top, 16)
                .transition(.opacity)
            Text(Self.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(points, id: \.title) { point in
                    HStack(alignment: .top, spacing: 12) {
                        PenTileView(symbol: point.icon, tint: point.tint).frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(point.title).font(.system(size: 13, weight: .semibold))
                            Text(point.detail)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, 4)
                    }
                }
            }
            .multilineTextAlignment(.leading)
            .frame(width: 380, alignment: .leading)
            .padding(.top, 20)
            HStack(spacing: 8) {
                Button { setup.flow = nil } label: {
                    HStack(spacing: 6) {
                        Text("Not Now")
                        KeyGlyphs(keys: "esc", size: 12.5, tint: nil, rest: 0.6)
                            .transaction { $0.animation = nil }
                    }
                }
                .settingsButton()
                .keyboardShortcut(.cancelAction)
                Button { setup.getToKnow() } label: {
                    HStack(spacing: 6) {
                        Text("Get to Know Me")
                        KeyGlyphs(keys: "↩", size: 12.5, tint: nil, rest: 0.6)
                            .transaction { $0.animation = nil }
                    }
                }
                .settingsButton(.primary)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 20)
            HStack(spacing: 6) {
                ClosingLock(side: 15)
                Text(Self.foot)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: 380)
            .padding(.top, 12)
        }
    }

    /// What pressing it starts, said before the press: that is the consent.
    static let detail = "It reads the sites you're signed in to, once, out of sight."
    static let foot = "About ten minutes, in a shut folder at the end of your tabs. Nothing is sent or bought."
}

/// The lock under Get to Know Me: open when the step comes up, its shackle
/// drops shut a moment later, once. With reduced motion, shut from the start.
private struct ClosingLock: View {
    let side: CGFloat
    @State private var shut = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Its strokes cut one shape, filled once in the words' gray: two
        // translucent strokes drawn one on another would darken where the
        // shackle meets the body.
        Rectangle()
            .fill(.tertiary)
            .mask {
                ZStack {
                    LockShackle()
                        .stroke(style: StrokeStyle(lineWidth: side / 24 * 2.4, lineCap: .round, lineJoin: .round))
                        .offset(y: shut ? 0 : -side * 0.16)
                    LockBody()
                        .stroke(style: StrokeStyle(lineWidth: side / 24 * 2.4, lineJoin: .round))
                        .scaleEffect(shut ? 1 : 0.94, anchor: .bottom)
                }
            }
            .frame(width: side, height: side)
            .accessibilityHidden(true)
            .task {
                if reduceMotion { shut = true; return }
                try? await Task.sleep(for: .seconds(0.7))
                withAnimation(.spring(response: 0.32, dampingFraction: 0.55)) { shut = true }
            }
    }
}

/// Central's lock, in its 24-point square, drawn to any size.
private struct LockShackle: Shape {
    func path(in rect: CGRect) -> Path {
        let k = rect.width / 24
        var path = Path()
        path.move(to: CGPoint(x: 8 * k, y: 10 * k))
        path.addLine(to: CGPoint(x: 8 * k, y: 7.5 * k))
        path.addArc(center: CGPoint(x: 12 * k, y: 7.5 * k), radius: 4 * k, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: 16 * k, y: 10 * k))
        return path
    }
}

private struct LockBody: Shape {
    func path(in rect: CGRect) -> Path {
        let k = rect.width / 24
        return Path(roundedRect: CGRect(x: 5 * k, y: 10 * k, width: 14 * k, height: 10 * k), cornerRadius: 2.5 * k, style: .continuous) // design: the icon's own drawing, Central's 2.5 in its 24-point square
    }
}

/// A line to copy: the words in the terminal's type, the skill's name in
/// its agent's color, Copy at the end. Copy says "Copied" in its own place
/// for a moment, at the width it always has, so nothing moves and no toast
/// is needed. `fits` sizes the slot to its whole words, never cut, instead
/// of filling the row; `kind` is the button's, glass on the welcome.
struct CommandSlot: View {
    let text: String
    var mention: String?
    var fits = false
    var kind: ButtonKind = .secondary

    @State private var copied = false
    @State private var copies = 0

    var body: some View {
        HStack(spacing: 8) {
            words
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
                .textSelection(.enabled)
                .fixedSize(horizontal: fits, vertical: false)
                .frame(maxWidth: fits ? nil : .infinity, alignment: .leading)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copies += 1
                let copy = copies
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    if copies == copy { copied = false }
                }
            } label: {
                ZStack {
                    Text("Copied").hidden()
                    Text(copied ? "Copied" : "Copy")
                }
            }
            .buttonStyle(.yab(kind, .small))
        }
        .padding(.leading, 12)
        .padding(.trailing, 6) // design: the Copy button stands 6 from the end, as high as it is from top and bottom
        .padding(.vertical, 6)
        .background(Palette.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }

    private var words: Text {
        guard let mention, let range = text.range(of: mention) else { return Text(text) }
        return Text(text[..<range.lowerBound])
            + Text(mention).foregroundColor(AgentDemo.color(mention.hasPrefix("$") ? "codex" : "claude"))
            + Text(text[range.upperBound...])
    }
}

// MARK: - marks

/// An agent's mark: its app's icon from Yab's bundle, else its app's own
/// icon when its app is on this Mac, else a tile of its color.
struct AgentMark: View {
    let cli: String
    let side: CGFloat

    @State private var icon: NSImage?
    @Environment(\.colorScheme) private var scheme

    init(cli: String, side: CGFloat) {
        self.cli = cli
        self.side = side
        _icon = State(initialValue: AgentIcons.bundled(cli) ?? AgentIcons.known[AgentIcons.key(cli, dark: false)] ?? nil)
    }

    var body: some View {
        mark.task(id: "\(cli) \(scheme)") {
            icon = await AgentIcons.icon(cli, dark: scheme == .dark)
        }
    }

    @ViewBuilder
    private var mark: some View {
        if let icon {
            // Already cut to its own square (AgentIcons.square).
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: side, height: side)
        } else {
            let tile = (AgentPlan.of(cli) ?? .claude).tile
            FeatureTile(icon: tile.icon, tint: tile.tint, side: side)
        }
    }
}

/// The agents' app icons, looked up once and off the main thread. Asked
/// for in a view's body, LaunchServices and the icon took the main thread
/// for up to ten seconds on a Mac that had the app's disk image registered
/// too: the welcome froze as Connect came in.
@MainActor
enum AgentIcons {
    /// Looked up already: an icon, or nil for no app.
    static var known: [String: NSImage?] = [:]

    static func key(_ cli: String, dark: Bool) -> String { cli }

    /// The plans' own apps: ChatGPT's (its app has the bundle id Codex
    /// had, and an older ChatGPT app its own), and Claude's.
    static func icon(_ cli: String, dark: Bool = false) async -> NSImage? {
        if let shipped = bundled(cli) { return shipped }
        let key = key(cli, dark: dark)
        if let found = known[key] { return found }
        let ids = (AgentPlan.of(cli) ?? .claude).apps
        let found = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            guard let url = ids.lazy.compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }).first else { return nil }
            return AgentIcons.square(NSWorkspace.shared.icon(forFile: url.path))
        }.value
        known[key] = .some(found)
        return found
    }

    /// The plan's app icon shipped in Yab (Resources/AgentIcons), already
    /// cut to its square, so every plan wears its real mark whether or not
    /// its app is on this Mac. Small, so read on the main thread once.
    static func bundled(_ cli: String) -> NSImage? {
        if let found = shipped[cli] { return found }
        let image = Bundle.main.url(forResource: cli, withExtension: "png", subdirectory: "AgentIcons").flatMap(NSImage.init(contentsOf:))
        shipped[cli] = .some(image)
        return image
    }

    private static var shipped: [String: NSImage?] = [:]

    /// A shipped icon's own shape, measured from its picture's alpha: how
    /// much of the picture its square fills, and its continuous corner as
    /// a share of the square. ChatGPT's is rounder than the others'.
    nonisolated static func outline(_ cli: String) -> (fill: CGFloat, corner: CGFloat) {
        switch cli {
        case "claude": return (1, 0.228)
        case "codex": return (1, 0.266)
        case "cursor", "gemini": return (0.988, 0.222)
        default: return (1, 0.226)
        }
    }

    /// The icon cut to its own square, measured rather than assumed: most
    /// apps' squares fill about 0.8 of the picture, but Cursor's fills
    /// nearly all of it and stood a quarter bigger than the others (#273).
    /// What is solid enough counts, so the drop shadow under it doesn't.
    nonisolated static func square(_ icon: NSImage, side: Int = 256) -> NSImage {
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return icon }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage(), let bounds = opaque(context, side: side) else { return icon }
        // Square round its middle, so a mark never stretches.
        let edge = max(bounds.width, bounds.height)
        let square = CGRect(x: bounds.midX - edge / 2, y: bounds.midY - edge / 2, width: edge, height: edge).integral
            .intersection(CGRect(x: 0, y: 0, width: side, height: side))
        guard let cut = image.cropping(to: square) else { return icon }
        return NSImage(cgImage: cut, size: NSSize(width: square.width, height: square.height))
    }

    /// The box of pixels at least `floor` opaque, in image coordinates
    /// (top left origin, as `CGImage.cropping` takes them).
    nonisolated static func opaque(_ context: CGContext, side: Int, floor: UInt8 = 160) -> CGRect? {
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let row = context.bytesPerRow
        var (minX, minY, maxX, maxY) = (side, side, -1, -1)
        for y in 0..<side {
            for x in 0..<side where data[y * row + x * 4 + 3] >= floor {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}

/// Waiting: an arc running round the mark's square, a little outside it.
struct SquareRing: View {
    let side: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Outside the tile for every agent: drawn inside Gemini's white
        // tile it read as a black edge with a white sliver beside it. A
        // badge's notch cuts the ring where the badge sits.
        let size = side + 12
        let shape = RoundedRectangle(cornerRadius: side * 0.26 + 6, style: .continuous)
        let ink = Palette.ink
        TimelineView(.animation(paused: reduceMotion)) { time in
            let turn = reduceMotion ? 0 : time.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.1) / 1.1
            ZStack {
                shape.stroke(ink.opacity(0.1), lineWidth: 2)
                shape.trim(from: turn, to: min(1, turn + 0.24))
                    .stroke(ink, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                if turn + 0.24 > 1 {
                    shape.trim(from: 0, to: turn + 0.24 - 1)
                        .stroke(ink, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                }
            }
        }
        .frame(width: size, height: size)
    }
}

/// A try that stopped, said where it was pressed: the warning mark and the
/// words, until the next press. No toast while this is on screen.
struct TroubleLine: View {
    let words: String

    var body: some View {
        HStack(spacing: 6) {
            Symbol("exclamationmark.triangle", size: 12)
            Text(words)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}

/// Done: the system's green, a tick, a ring of the window's ground.
struct DoneTick: View {
    let side: CGFloat

    var body: some View {
        Circle()
            .fill(Color(nsColor: .systemGreen))
            .overlay(Symbol("checkmark", size: side * 0.4, weight: .bold).foregroundStyle(.white))
            .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
            .frame(width: side, height: side)
    }
}

// MARK: - the demo

/// The agent asked for yab, played out: the words typed, then what it does,
/// a line at a time, in its terminal or in its app. With reduced motion,
/// all of it at once.
struct AgentDemo: View {
    let cli: String
    let inApp: Bool
    @State private var typed = 0
    @State private var lines = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let ask = "open my GitHub notifications and tell me what needs me"
    private static let answer = "Three need you: a review on yab#412, a question in #408, and a failed check on main."

    static func color(_ cli: String) -> Color {
        cli == "codex" ? Color(nsColor: .systemPurple) : Color(nsColor: .systemOrange)
    }

    private var mention: String { AgentSetupModel.mention(cli) }
    private var said: String { "use \(mention) to \(Self.ask)" }

    /// What it does after the words, a line each.
    private var steps: [(mark: String, text: String, dim: Bool)] {
        if inApp {
            return [("spark", "Using \(AgentSetup.skill)", true),
                    ("globe", "open github.com/notifications, in Yab", true),
                    ("", Self.answer, false)]
        }
        return cli == "codex"
            ? [("•", "Using skill \(AgentSetup.skill)", false),
               ("•", "Called \(AgentSetup.server).open({\"url\":\"github.com/notifications\"})", false),
               ("  └", "Opened in Yab, a tab of its own", true),
               ("•", Self.answer, false)]
            : [("⏺", "Skill(\(AgentSetup.skill))", false),
               ("⏺", "\(AgentSetup.server) - open (MCP)(url: \"github.com/notifications\")", false),
               ("  ⎿", "Opened in Yab, a tab of its own", true),
               ("⏺", Self.answer, false)]
    }

    var body: some View {
        Group {
            if inApp { app } else { terminal }
        }
        .frame(height: 200)
        .task { await play() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(AgentSetupModel.name(cli)) asked: \(said)")
    }

    private func play() async {
        if reduceMotion { typed = said.count; lines = steps.count; return }
        try? await Task.sleep(for: .seconds(0.4))
        for count in 0...said.count {
            typed = count
            try? await Task.sleep(for: .milliseconds(28))
        }
        for count in 1...steps.count {
            try? await Task.sleep(for: .seconds(count == steps.count ? 1.0 : 0.55))
            withAnimation(Motion.quick) { lines = count }
        }
    }

    /// The typed part of the words, the skill's name in its color.
    private var typing: Text {
        let shown = String(said.prefix(typed))
        guard let range = shown.range(of: "use ") else { return Text(shown) }
        let rest = shown[range.upperBound...]
        let name = String(rest.prefix(mention.count))
        return Text("use ") + Text(name).foregroundColor(Self.color(cli)) + Text(rest.dropFirst(name.count))
    }

    // A terminal is dark in either look.
    private var terminal: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                ForEach([Color(nsColor: .systemRed), Color(nsColor: .systemYellow), Color(nsColor: .systemGreen)], id: \.self) {
                    Circle().fill($0).frame(width: 10, height: 10)
                }
                Spacer()
                Text(cli == "codex" ? "codex" : "claude").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                Spacer()
                Color.clear.frame(width: 42, height: 1)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(.white.opacity(0.06))
            VStack(alignment: .leading, spacing: 4) {
                (Text(cli == "codex" ? ">_ " : "✻ ").foregroundColor(Self.color(cli))
                    + Text(cli == "codex" ? "Codex" : "Claude Code").foregroundColor(.white)
                    + Text("  ~/work").foregroundColor(.white.opacity(0.45)))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .overlay(RoundedRectangle(cornerRadius: Radius.small, style: .continuous).strokeBorder(.white.opacity(0.18)))
                    .padding(.bottom, 4)
                (Text(cli == "codex" ? "› " : "> ").foregroundColor(.white.opacity(0.45)) + typing.foregroundColor(.white)
                    + Text(typed < said.count ? "▌" : "").foregroundColor(.white.opacity(0.8)))
                ForEach(Array(steps.prefix(lines).enumerated()), id: \.offset) { _, step in
                    (Text(step.mark + " ").foregroundColor(step.dim ? .white.opacity(0.45) : Color(nsColor: .systemGreen))
                        + Text(step.text).foregroundColor(step.dim ? .white.opacity(0.45) : .white))
                        .transition(.opacity)
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 11.5, design: .monospaced))
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Palette.inkGround, in: RoundedRectangle(cornerRadius: Radius.surface, style: .continuous))
        .environment(\.colorScheme, .dark)
    }

    private var app: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Spacer(minLength: 60)
                typing
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Palette.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: Radius.floating, style: .continuous))
            }
            ForEach(Array(steps.prefix(lines).enumerated()), id: \.offset) { _, step in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if !step.mark.isEmpty { Symbol(step.mark, size: 10).foregroundStyle(.secondary) }
                    Text(step.text)
                        .font(step.dim ? .callout : .system(size: 13))
                        .foregroundStyle(step.dim ? .secondary : .primary)
                }
                .transition(.opacity)
            }
            Spacer(minLength: 0)
            HStack {
                Text("Reply to \(AgentSetupModel.name(cli))…").foregroundStyle(.tertiary)
                Spacer()
                Symbol("arrow.up", size: 10, weight: .bold)
                    .foregroundStyle(Palette.ground)
                    .frame(width: 20, height: 20)
                    .background(Palette.ink, in: Circle())
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .overlay(RoundedRectangle(cornerRadius: Radius.floating, style: .continuous).strokeBorder(.quaternary))
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.ink.opacity(0.03), in: RoundedRectangle(cornerRadius: Radius.surface, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.surface, style: .continuous).strokeBorder(.quaternary))
    }
}
