import AppKit
import SwiftUI
import SyncKit

// On an agent's page, while it works there, a dark dock at the page's foot
// says it in words: the face, what it is doing right now, and the one thing
// you can do about it, Take over, ⌘.; at its end, for a task yab runs, its
// chat in the column. Take over (or any click or key of yours in the page)
// and the dock turns light: "You're driving", Hand back, ⌘↩. The agent
// waits in between (AgentFeed, AgentBench).
//
// Its shape follows the buttons' (Buttons.swift): 36 high, the one
// regular-size button inside it 4 in, so the dock's corners are the button's
// 8 and 4 more. It comes up from the page's foot and goes back the same way
// (family-values-motion P3), and its words cross over when the step changes
// (P2) while it keeps its place.
//
// On the tab Connect or Add Account opens a sign-in in, the same light
// plate a handoff uses says whose sign-in it is, that Yab closes the tab
// when you're done, and Cancel (esc). It floats: the page keeps its room.
//
// And on the page, the agent itself: its face on a small white disc, gliding
// to where it is about to click and pressing there the way a button is
// pressed on iOS, down and back on springs, a ring from the spot, so
// what it does happens under something you can see. No arrow: yours is the
// only pointer on the screen.

struct AgentDock: View {
    var tab: Tab
    /// The page owns this finite proposal, including a live Peek holder.
    var availableWidth: CGFloat?
    private var selection: SelectionCommands
    private var agents = Agents.shared
    /// Which chat the column shows: what it asks stands there, not here.
    private var columnChat = ColumnChat.shared
    private var feed = AgentFeed.shared
    private var hints = Hints.shared
    /// A payment's sheet, which stays after its question until the site said.
    private var payments = Payments.shared
    @Environment(\.accessibilityReduceMotion) private var still
    @State private var copiedAnswer = false
    @State private var answerHasField = false

    /// Finished while you were here: the dock says so for a few seconds,
    /// then goes back into the page's foot.
    @State private var finishedRead: String?
    /// Counts an attached agent's last step here going stale, to redraw.
    @State private var lingered = 0
    /// The measured content changes at once; this one plate follows every state.
    @State private var plateSize = CGSize.zero
    @State private var plateCorner: CGFloat = Radius.control + 4
    @State private var plateLight: CGFloat = 0
    /// The plate has been round this answer once. Until then it is still
    /// growing from the working capsule, and the answer (laid out at its own
    /// size from the start) and the row over the plate's corner wait: shown
    /// at once, the answer's words, its Insert and the face sat on one
    /// another inside the capsule. Later reshapes (Show All, a follow-up
    /// typed) keep it shown.
    @State private var answerFitted = false
    @State private var answerTurn = 0
    @State private var reshapes = 0

    /// The air between the plate and the page's foot: nothing is drawn in
    /// it, so a click there is the page's (AgentDockHost).
    static let footGap: CGFloat = 14

    init(tab: Tab, selection: SelectionCommands? = nil, availableWidth: CGFloat? = nil) {
        self.tab = tab
        self.availableWidth = availableWidth
        self.selection = selection ?? BrowserWindows.shared.owner(of: tab.id)?.browser.selectionCommands ?? SelectionCommands()
    }

    private var commanding: Bool { selection.activeTab === tab && selection.showsDock }
    private var commandExpanded: Bool { commanding && SelectionDockContent.expanded(selection) }

    private var session: Agents.Session? { agents.session(tab.askedBy ?? feed.stopped[tab.id]) }
    private var stoppedHere: Bool { session.map { feed.stopped[tab.id] == $0.id } ?? false }
    private var terminalKey: String { "\(session?.id ?? ""):\(stoppedHere ? "stopped-here" : session?.state.rawValue ?? "")" }
    private var finished: Bool {
        (stoppedHere || session?.state == .stopped || session?.state == .done || session?.state == .failed)
            && finishedRead != terminalKey
    }
    /// The sign-in Connect or Add Account opened here, while it waits for
    /// you. Agents says when one lands in a tab, so `agents` redraws this.
    private var signIn: (cli: String, privately: Bool)? { agents.connectSignIn(on: tab) }
    private var asking: Bool {
        if payments.flow(tab) != nil { return !AgentDock.askedInColumn(tab) }
        // A send asked of a tab that isn't the agent's stands in the
        // window's corner instead (Agents.inCorner).
        return tab.handoff != nil && tab.askedBy != nil && !AgentDock.askedInColumn(tab) && !Agents.inCorner(tab)
            && !Agents.choosingInCorner(tab)
    }

    /// What the tab asks stands in the chat's column, which is out with
    /// its chat: not twice, and nothing else at the page's foot meanwhile,
    /// where Take Over and the step would say it isn't waiting on you.
    static func askedInColumn(_ tab: Tab) -> Bool {
        let agents = Agents.shared
        let pay = { (tab: Tab) in Payments.shared.flow(tab)?.session }
        guard tab.handoff != nil || pay(tab) != nil, let shown = agents.columnChat, let browser = agents.browser else { return false }
        // The column holds one question: its chat's first.
        let first = browser.tabs.first {
            ($0.handoff != nil || pay($0) != nil) && agents.root(of: pay($0) ?? $0.askedBy) == shown
        }
        return first?.id == tab.id
    }
    /// What the foot's offer looks at again for: the address while an
    /// offer is up (it goes once the page moves on), the site otherwise
    /// (the corner says the key on a site with actions). Read through the
    /// whole address, every link ran this dock's body (round 12).
    private var noticeKey: String {
        guard Narrow.addressFlags, hints.offered[tab.id] == nil else { return tab.address?.absoluteString ?? "" }
        return tab.siteHost ?? ""
    }
    /// The glass the agent works on: light over a dark page, dark
    /// otherwise (HUD.surface(over:)).
    private var working: HUD.Surface { HUD.surface(over: tab.isBlank ? nil : tab.under) }
    private var answering: Bool { signIn == nil && !asking && session?.state.live != true && tab.answer != nil }
    private var suggesting: Bool {
        signIn == nil && !asking && !answering && hints.offered[tab.id] != nil && hints.actions(on: tab).first != nil
    }

    /// Shown while its agent works here, while it asks for a handoff on the
    /// same plate, and for a moment after it finishes in front of you.
    private var shown: Bool {
        if commanding { return true }
        if signIn != nil { return true }
        if AgentDock.askedInColumn(tab) { return false }
        // Its question stands in the window's corner as the card: asked in
        // one place, nothing at the foot running under it.
        if Agents.inCorner(tab) || Agents.choosingInCorner(tab) || Agents.sendingInCorner(tab) { return false }
        if asking || answering || suggesting { return true }
        guard let session else { return false }
        if stoppedHere { return finished }
        // A script has nothing to hand over and never finishes: only while
        // it is doing things.
        if session.script { return session.busy }
        // An agent attached through `yab mcp`: only while it does things
        // here, and at once gone when you hand the tab back.
        if session.state == .attached {
            _ = lingered
            return feed.driving.contains(tab.id) || feed.atWorkHere(tab)
        }
        return session.state.live || finished
    }

    var body: some View {
        let driving = feed.driving.contains(tab.id)
        let signing = signIn
        let light = commanding || signing != nil || asking || driving || answering || suggesting
        let answer = answering && !commanding ? tab.answer : nil
        let known = answer.flatMap { agents.session($0.session) }
        let sharedActions = !commanding && (suggesting || (answering && !answerHasField && answer.map {
            AgentAnswer.canShareActions(text: $0.text, draft: known?.draft, threaded: known?.thread != nil)
        } == true))
        let paying = asking && payments.flow(tab) != nil
        let expanded = commanding ? commandExpanded : answering
        let arriving = expanded && !answerFitted && !still
        let workingDock = !commanding && signing == nil && answer == nil && !asking && !suggesting && session != nil
        let plateWidth = workingDock ? min(plateSize.width, availableWidth ?? plateSize.width) : plateSize.width
        let corner = commanding ? (commandExpanded ? Radius.card : Radius.control + 4)
            : paying ? Radius.box : signing != nil || asking || answering ? Radius.card : Radius.control + 4
        ZStack(alignment: .bottomTrailing) {
            if shown {
                ZStack(alignment: .bottom) {
                    // You driving: the agent's glass gives way to the other
                    // one, the dark to light, or over a dark page the light
                    // to dark. Not one laid over the other, whose rim showed
                    // round it.
                    let glass = !commanding && driving && signing == nil && !asking && !answering && !suggesting
                    HUD.plate(plateCorner, surface: working)
                        .opacity(glass ? 1 - plateLight / 0.94 : 1)
                    if glass {
                        HUD.plate(plateCorner, surface: HUD.flipped(working))
                            .opacity(plateLight / 0.94)
                            .allowsHitTesting(false)
                    }
                    RoundedRectangle(cornerRadius: plateCorner, style: .continuous)
                        .fill(Palette.ground) // design: the light plate cross-fades over the one persistent HUD plate
                        .opacity(glass ? 0 : plateLight)
                        .overlay {
                            RoundedRectangle(cornerRadius: plateCorner, style: .continuous)
                                .strokeBorder(Palette.hairline.opacity(glass ? 0 : plateLight), lineWidth: 1) // design: animates the hairline with the one persistent HUD plate
                        }
                        .allowsHitTesting(false)
                    Group {
                        if commanding {
                            SelectionDockContent(commands: selection, tab: tab)
                                .opacity(arriving ? 0 : 1)
                                .animation(arriving ? nil : Motion.arrive, value: arriving)
                                .transition(.identity)
                        } else if let signing {
                            SignInPlate(cli: signing.cli, privately: signing.privately)
                                .transition(.identity)
                        } else if let answer {
                            AgentAnswer(tab: tab, session: answer.session, text: answer.text,
                                        draft: known?.state == .failed ? nil : known?.draft, threaded: known?.thread != nil,
                                        embedded: true, sharedActions: sharedActions,
                                        onFieldChange: { answerHasField = $0 })
                                // Shown once the plate is round it (`arriving`).
                                .opacity(arriving ? 0 : 1)
                                .animation(arriving ? nil : Motion.arrive, value: arriving)
                                .transition(.identity)
                        } else if asking, let flow = payments.flow(tab) {
                            PaySheet(flow: flow, tab: tab, embedded: true)
                                .frame(width: 380) // design: the sheet's width in the column, ChatLook.width less its insets
                                .transition(.identity)
                        } else if asking {
                            AgentPlaque(tab: tab, embedded: true)
                                .transition(.identity)
                        } else if suggesting {
                            PagePill(tab: tab, embedded: true, sharedActions: sharedActions)
                                .transition(.identity)
                        } else if let session {
                            dock(session: session, driving: driving, done: finished)
                                .transition(.identity)
                        }
                    }
                    .fixedSize()
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                        guard size.width > 0, size.height > 0, size != plateSize else { return }
                        if plateSize == .zero || still { plateSize = size; if expanded { answerFitted = true }; return }
                        reshapes += 1
                        let mine = reshapes
                        withAnimation(Motion.reshape, completionCriteria: .logicallyComplete) { plateSize = size } completion: {
                            if mine == reshapes, expanded { answerFitted = true }
                        }
                    }
                    // A tall answer grows upward from the dock. Keep its
                    // first line at the moving top edge so the new words
                    // are visible as soon as that edge starts moving.
                    .frame(width: plateWidth, height: plateSize.height,
                           alignment: expanded ? .topLeading : .bottomLeading)
                    .clipShape(RoundedRectangle(cornerRadius: plateCorner, style: .continuous))
                }
                .frame(width: plateWidth, height: plateSize.height)
                .benchSpot("agent dock plate")
                .overlay(alignment: .bottomLeading) {
                    // This is the same face through work, the handoff,
                    // and the return. Only its pose and ink change.
                    if commanding || (!answering && !suggesting && signing == nil && !paying) {
                        // Its ink follows the plate it is on: a hand on the dark
                        // plate stayed black when the plate hadn't turned light.
                        Group {
                            if commanding {
                                Face(pose: SelectionDockContent.pose(selection), size: 15, tint: Palette.ink)
                            } else {
                                AgentFace(tab: tab, size: 15,
                                          tint: plateLight < 0.5 ? HUD.ink(on: working) : driving && !asking ? HUD.ink(on: HUD.flipped(working)) : Palette.ink)
                            }
                        }
                            // Gone at once when the answer comes: fading,
                            // it sat over the answer's first letters.
                            .transition(.identity)
                            .padding(.leading, 12)
                            .padding(.bottom, !commanding && asking ? CardFrame.inset + (ButtonSize.small.height - 15) / 2 : (36 - 15) / 2)
                            .animation(still ? nil : Motion.reshape, value: asking)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if sharedActions {
                        sharedActionRow(answering: answering, action: hints.actions(on: tab).first,
                                        answer: answer?.text)
                            // Kept mounted, but unseen until the plate has
                            // grown round the answer it belongs to.
                            .opacity(answering && arriving ? 0 : 1)
                            .animation(arriving ? nil : Motion.arrive, value: arriving)
                            // The right edge stays put; a longer action grows left.
                            .padding(.trailing, 8)
                            .padding(.bottom, answering ? CardFrame.inset : (36 - ButtonSize.regular.height) / 2)
                    }
                }
                .transition(still ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        // The shared offer/answer plate keeps one screen-space right edge.
        // Its content and primary button can then grow left without drifting.
        .frame(width: sharedActions ? 496 : nil, alignment: .trailing)
        .animation(Motion.arrive, value: shown)
        // A viewport resize is a new boundary, not an animated overshoot.
        .transaction(value: availableWidth) { if workingDock { $0.animation = nil } }
        .animation(still ? nil : Motion.reshape, value: answering)
        .padding(.bottom, AgentDock.footGap)
        .onChange(of: shown) { _, now in if !now { plateSize = .zero } }
        .onChange(of: expanded) { _, now in
            answerFitted = false
            answerTurn += 1
            guard now else { return }
            // An answer the capsule's size has no reshape to wait for.
            let turn = answerTurn
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { if turn == answerTurn { answerFitted = true } }
        }
        .onChange(of: corner, initial: true) { _, corner in
            if plateSize == .zero || still { plateCorner = corner }
            else { withAnimation(Motion.reshape) { plateCorner = corner } }
        }
        .onChange(of: light, initial: true) { _, now in
            let opacity: CGFloat = now ? 0.94 : 0
            if plateSize == .zero || still { plateLight = opacity }
            else { withAnimation(Motion.morph) { plateLight = opacity } }
        }
        .onChange(of: tab.answer?.text) { _, _ in
            copiedAnswer = false
            answerHasField = false
        }
        .task(id: "\(noticeKey):\(asking):\(answering):\(tab.worker == nil):\(signIn == nil):\(hints.offered[tab.id] ?? "")") {
            guard tab.worker == nil, !asking, !answering, signIn == nil else { return }
            await PagePill.noticed(tab, hints)
        }
        .task(id: feed.last[tab.id]?.count) {
            guard feed.last[tab.id] != nil else { return }
            try? await Task.sleep(for: .seconds(AgentFeed.lingers))
            if !Task.isCancelled { lingered += 1 }
        }
        .task(id: terminalKey) {
            // Change the words and fade the controls in the same render as Stop.
            guard finished else { return }
            let key = terminalKey
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { withAnimation(Motion.depart) { finishedRead = key } }
        }
    }

    /// The same two controls stay mounted while an answer becomes a suggestion.
    /// Their labels and actions change with the plate; their frames follow it.
    private func sharedActionRow(answering: Bool, action: Skills.Action?, answer: String?) -> some View {
        let title = answering ? (copiedAnswer ? "Copied" : "Copy") : (action?.title ?? "")
        // Offered by a thing addressed to you (SiteItems): Skip asks in the
        // corner whether to stop suggesting there.
        let site = !answering && action?.pattern.hasPrefix("@") == true ? action?.skill : nil
        return HStack(spacing: 6) {
            if !answering {
                HStack(spacing: 6) {
                    Face(pose: .watch, size: 15, tint: Palette.ink)
                        .padding(.leading, 4) // design: the persistent row reserves the plate's remaining leading inset
                        .padding(.trailing, 2) // design: match the face-to-label gap of PagePill
                    Text("Suggested")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.muted)
                        .fixedSize()
                }
                .transition(.identity)
            }
            Button {
                if answering { tab.answer = nil }
                else {
                    hints.unoffer(tab.id)
                    if let site { SiteItems.shared.skip(site, from: BrowserWindows.shared.owner(of: tab.id)?.browser) }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(answering ? "Close" : "Skip")
                        .transaction { $0.animation = nil }
                    KeyGlyphs(keys: "esc", size: 12.5, tint: nil, rest: 0.6)
                }
            }
            .buttonStyle(.yab(.secondary, .regular))
            .focusable(false)
            .keyboardShortcut(.cancelAction)
            Button {
                if answering, let answer {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(answer, forType: .string)
                    copiedAnswer = true
                } else if let action {
                    Agents.shared.act(action, on: tab, item: SiteItems.shared.item(offeredOn: tab, for: action))
                }
            } label: {
                HStack(spacing: 6) {
                    // Copy as wide as the Copied it turns into.
                    ZStack {
                        if answering { Text("Copied").hidden() }
                        Text(title).lineLimit(1)
                    }
                    .transaction { $0.animation = nil }
                    ShortcutGlyphs(answering ? .answerCopy : .agentAsk,
                                   size: 12.5, tint: nil)
                        .opacity(0.6)
                        .transaction { $0.animation = nil }
                }
            }
            .buttonStyle(.yab(.primary, .regular, glass: true))
            .focusable(false)
            .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        }
        .fixedSize()
        .animation(still ? nil : Motion.reshape, value: answering)
    }

    private func dock(session: Agents.Session, driving: Bool, done: Bool) -> some View {
        let surface = driving ? HUD.flipped(working) : working
        let ink = HUD.ink(on: surface)
        let words = done ? AgentDock.finishedWords(session, stopped: stoppedHere)
            : driving ? "You're driving, \(session.name) waits"
            : elsewhere(session) ? "Working in another tab"
            : AgentDock.say(session.now, name: session.name)
        return AgentDockWidth(maximum: availableWidth) {
            HStack(spacing: 10) {
                Color.clear.frame(width: 15, height: 15)
                    .padding(.leading, 12)
                AgentDockWidth(minimum: 150) {
                    ZStack(alignment: .leading) {
                        Text(words)
                            .font(.system(size: 12.5))
                            .foregroundStyle(ink)
                            .lineLimit(1)
                            .id(words)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .offset(y: 6)),
                                removal: .opacity.combined(with: .offset(y: -6)).animation(.easeIn(duration: 0.1))
                            ))
                    }
                }
                if !done {
                    HStack(spacing: 6) {
                        if !session.script {
                            Button {
                                driving ? feed.handBack(tab) : feed.drive(tab)
                            } label: {
                                HStack(spacing: 7) { // design: preserve the existing Take Over label-to-shortcut gap
                                    // The label crosses over rather than being swapped.
                                    ZStack {
                                        Text(driving ? "Hand Back" : "Take Over")
                                            .id(driving)
                                            .transition(.asymmetric(
                                                insertion: .opacity.combined(with: .offset(y: 5)),
                                                removal: .opacity.combined(with: .offset(y: -5)).animation(.easeIn(duration: 0.1))
                                            ))
                                    }
                                    // The key that does it now, lit once as it changes.
                                    ShortcutGlyphs(driving ? .agentHandBack : .agentTakeWheel, size: 12.5, tint: nil)
                                        .keyframeAnimator(initialValue: 0.6, trigger: driving) { key, lit in
                                            key.opacity(lit).scaleEffect(1 + (lit - 0.6) * 0.375)
                                        } keyframes: { _ in
                                            LinearKeyframe(1, duration: 0.05)
                                            CubicKeyframe(0.6, duration: 0.21)
                                        }
                                }
                            }
                            .buttonStyle(.yab(.secondary, .regular, surface: surface))
                            .focusable(false)
                        }
                        Button { _ = agents.stop(on: tab) } label: { Symbol("stop.fill", size: 9) }
                            .buttonStyle(.yab(.secondary, .regular, surface: surface, icon: .square))
                            .focusable(false)
                            .accessibilityLabel("Stop Agent")
                            .benchSpot("agent dock stop")
                            .keyTip("Stop", shortcut: "Stop Agent", side: .above)
                        // Its chat, in full, beside the page (ChatColumn.swift): at
                        // the end, on the side the column comes out, with the mark
                        // ⌘J's answer opens it by. An agent from a terminal has
                        // its chat there, and none here.
                        if !session.script, !driving, agents.hasChat(session.id), let browser = agents.browser, !browser.chatOpen {
                            Button { browser.showChat(session.id) } label: { Symbol("square.arrow.out", size: 14) }
                                .buttonStyle(.yab(.secondary, .regular, surface: surface, icon: .square))
                                .focusable(false)
                                // Over it: under it, at the page's foot, the tip
                                // would hang past the window's edge.
                                .keyTip("Open in Chat", side: .above)
                                .transition(.opacity)
                        }
                    }
                    .padding(.trailing, 4)
                    // Narrow holders (a peek) squeeze the words, never the
                    // buttons: a cut "Take O…" left its slack after Stop.
                    .fixedSize()
                    .transition(.opacity)
                } else {
                    Color.clear.frame(width: 4)
                }
            }
            // The width follows the words on the words' own curve; the button
            // keeps its end.
            .animation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.3), value: words)
            .animation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.3), value: done)
            .animation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.3), value: driving)
            .frame(height: 36)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent-working-dock")
    }

    /// Its step is on another page than this one: "Reading the page" here
    /// would be about a page you can't see.
    private func elsewhere(_ session: Agents.Session) -> Bool {
        let verb = session.now.components(separatedBy: " · ").first?.lowercased() ?? ""
        // Its words may be the chat's ("Clicking “Mark as read”"): then the
        // step going on says which tool it is.
        let tool = session.items.last { $0.kind == .tool && $0.state == .running }?.name ?? ""
        let hands = ["snapshot", "read", "text", "shot", "screenshot", "click", "fill", "type", "select", "choose", "hover", "drag", "scroll",
                     "eval", "run", "submit", "dialog", "answered the page"]
        let paged = hands.contains(verb) || verb.hasPrefix("press") || hands.contains(tool) || tool == "press"
        guard paged else { return false }
        let latest = (agents.browser?.tabs ?? []).filter { $0.worker == session.id }.compactMap { feed.last[$0.id] }.max { $0.count < $1.count }
        return latest != nil && latest != feed.last[tab.id]
    }

    /// A sign-in tab's plate: whose sign-in, and what becomes of the tab.
    /// The provider's page asks about the tool ("Claude Code would like to
    /// connect", "continue to Codex"), so the plate says what that is.
    static func signInWords(_ cli: String, privately: Bool) -> (title: String, detail: String) {
        privately
            ? ("Sign in to your other \(AgentSetupModel.plan(cli)) account", "A private tab, so your usual account doesn't answer")
            : ("Sign in to connect \(AgentSetupModel.name(cli))", "Say yes to \(AgentSetupModel.tool(cli)), which Yab runs for you. Yab then closes this tab.")
    }

    static func finishedWords(_ session: Agents.Session, stopped: Bool = false) -> String {
        if stopped || session.state == .stopped { return "You stopped \(session.name)" }
        if session.state == .failed { return "\(session.name) couldn\u{2019}t finish" }
        return result(session)
    }

    /// What it found, in a line: its answer's first sentence, or "Done".
    static func result(_ session: Agents.Session) -> String {
        guard let line = firstLine(session.result) else { return "\(session.name) is done" }
        let short = line.count > 64 ? String(line.prefix(62)) + "…" : line
        return "Done · \(short)"
    }

    /// An answer's first line as words: Markdown's marks off it, so a
    /// heading reads "Shorts hidden", not "# Shorts hidden".
    static func firstLine(_ answer: String) -> String? {
        let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = text.split(whereSeparator: \.isNewline).first.map(String.init) else { return nil }
        let line = first.replacingOccurrences(of: #"^\s*(#{1,6}\s+|[-*+]\s+|>\s*)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "").replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespaces)
        return line.isEmpty ? nil : line
    }

    /// The agent's last step, in words a person would use: the chat's own
    /// (StepWords), wherever it is said.
    static func say(_ now: String, name: String) -> String {
        StepWords.say(now, name: name)
    }
}

// MARK: - a sign-in's tab

/// The tab Connect or Add Account opened a sign-in in, the whole time it
/// waits: the agent's mark where the face would be, whose sign-in it is,
/// that Yab closes the tab once you've said yes, and the way out. Closing
/// the tab cancels too, and says so where Connect was pressed.
private struct SignInPlate: View {
    let cli: String
    let privately: Bool

    var body: some View {
        let words = AgentDock.signInWords(cli, privately: privately)
        HStack(spacing: 8) {
            AgentMark(cli: cli, side: 15)
            VStack(alignment: .leading, spacing: 2) {
                Text(words.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Palette.ink)
                Text(words.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
            }
            .lineLimit(1)
            .fixedSize()
            Spacer(minLength: 12)
            Button {
                let setup = AgentSetupModel.shared
                if privately { PlanAccounts.shared.cancelAdding() }
                else if setup.flow == .signingIn(cli) { setup.cancel() }
                else { Agents.shared.cancelConnect(cli, privately: false) }
            } label: {
                HStack(spacing: 6) {
                    Text("Cancel")
                    KeyGlyphs(keys: "esc", size: 11.5, tint: nil, rest: 0.6)
                        .transaction { $0.animation = nil }
                }
            }
            .buttonStyle(.yab(.secondary, .small))
            .focusable(false)
            .keyboardShortcut(.cancelAction)
        }
        .frame(minWidth: 300, alignment: .leading)
        .agentCardFrame(surface: false)
    }
}

// MARK: - the agent's pointer

/// Where the agent last clicked on a tab's page, in the page view's points
/// from its top left, and how many clicks there have been.
struct AgentPoint: Equatable {
    let at: CGPoint
    let count: Int
}

struct AgentPointer: View {
    var tab: Tab
    private var feed = AgentFeed.shared
    private var agents = Agents.shared
    @State private var pressed = false
    @State private var ring: CGFloat = 1
    @State private var ringing: Double = 0
    /// The click has landed and been seen: the mark steps off the page
    /// rather than sitting over the words it pressed until the agent rests.
    /// Its next click brings it back, from where it was.
    @State private var off = false
    @Environment(\.accessibilityReduceMotion) private var still

    var body: some View {
        let point = feed.pointer[tab.id]
        // An attached agent gone quiet (`resting`) is no longer at work here.
        let live = agents.session(tab.worker)?.working == true
        let shown = point != nil && live && !feed.driving.contains(tab.id) && tab.handoff == nil
        ZStack(alignment: .topLeading) {
            if let point, shown {
                ZStack {
                    // The click's ring: a thin, faint one that starts clear of
                    // the disc and is gone in a third of a second, never a
                    // border on it.
                    Circle()
                        .stroke(Palette.ink.opacity(0.3), lineWidth: 1)
                        .frame(width: 24, height: 24)
                        .scaleEffect(ring)
                        .opacity(ringing)
                    // The same tinted glass as the corner's tips and toasts,
                    // round at this size so the face stays clear over a page:
                    // light over a dark page, dark otherwise.
                    let surface = HUD.surface(over: tab.isBlank ? nil : tab.under)
                    AgentFace(tab: tab, size: 16, tint: HUD.ink(on: surface))
                        .frame(width: 24, height: 24)
                        .background { HUD.plate(12, surface: surface) }
                        .scaleEffect(pressed ? 0.8 : 1)
                }
                // Its middle is the spot it clicks.
                .offset(x: point.at.x - 12, y: point.at.y - 12)
                .animation(still ? nil : .timingCurve(0.4, 0, 0.2, 1, duration: 0.45), value: point.at)
                .opacity(off ? 0 : 1)
                .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .animation(Motion.quick, value: shown)
        .onChange(of: point?.count) { _, _ in press() }
    }

    /// Off the page once the click has been seen: about a second after it
    /// lands, unless another click came meanwhile.
    private func stepOff(after seconds: Double) {
        let count = feed.pointer[tab.id]?.count
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard feed.pointer[tab.id]?.count == count else { return }
            if still { off = true } else { withAnimation(.easeOut(duration: 0.25)) { off = true } }
        }
    }

    /// Down at once, back on a spring, and one ring from the spot.
    private func press() {
        var shown = Transaction()
        shown.disablesAnimations = true
        withTransaction(shown) { off = false }
        stepOff(after: still ? 1.0 : 1.15)
        guard !still else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.4))   // it has arrived
            withAnimation(.linear(duration: 0.06)) { pressed = true }
            try? await Task.sleep(for: .seconds(0.07))
            withAnimation(.spring(response: 0.28, dampingFraction: 0.55)) { pressed = false }
            var quiet = Transaction()
            quiet.disablesAnimations = true
            withTransaction(quiet) { ring = 1.2; ringing = 1 }
            withAnimation(.timingCurve(0.2, 0.9, 0.3, 1, duration: 0.34)) { ring = 2; ringing = 0 }
        }
    }
}

// MARK: - the keys

/// Take Over ⌘. and Hand Back ⌘↩ in the Tabs menu, each only there to press
/// when it can be, so the rest of the time the keys are the page's.
struct AgentCommands: View {
    var browser: Browser
    private var feed = AgentFeed.shared
    private var agents = Agents.shared

    var body: some View {
        let tab = browser.active
        let session = agents.session(tab?.worker)
        let driving = tab.map { feed.driving.contains($0.id) } ?? false
        PageActionCommand(browser: browser)
        Button("Take Over from Agent") { if let tab { feed.drive(tab) } }
            .shortcut(.agentTakeWheel)
            .disabled(tab == nil || session?.state.live != true || session?.script == true || driving || tab?.handoff != nil)
        Button("Hand Back to Agent") { if let tab { feed.handBack(tab) } }
            .shortcut(.agentHandBack)
            .disabled(!driving)
        Button("Stop Agent") { if let tab { _ = agents.stop(on: tab) } }
            .shortcut(.agentStop)
            .disabled(session?.state.live != true)
    }
}

/// Ask the real row for its natural size first, then offer only the page's
/// remaining width. A short dock hugs its words; a long command can truncate.
private struct AgentDockWidth: Layout {
    var maximum: CGFloat? = nil
    var minimum: CGFloat = 0

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let row = subviews.first else { return .zero }
        let natural = row.sizeThatFits(.unspecified)
        let ideal = max(minimum, natural.width)
        let width = min(ideal, max(0, maximum ?? proposal.width ?? ideal))
        let fitted = row.sizeThatFits(ProposedViewSize(width: width, height: natural.height))
        return CGSize(width: width, height: fitted.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

/// Peek keeps only the drawn dock as a native hit target. Its holder's width
/// is an input to the intrinsic content, never a full-width transparent host.
final class AgentDockHost: NSHostingView<AgentDock> {
    private var watches: [NSObjectProtocol] = []

    /// The foot gap under the plate is in the host's frame but empty: a
    /// click there goes to the page under it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let gap = AgentDock.footGap
        if isFlipped ? local.y > bounds.height - gap : local.y < gap { return nil }
        return super.hitTest(point)
    }

    static func mount(_ tab: Tab, in holder: NSView) -> AgentDockHost {
        let dock = AgentDockHost(rootView: AgentDock(tab: tab, availableWidth: holder.bounds.width))
        dock.sizingOptions = [.intrinsicContentSize]
        dock.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(dock)
        NSLayoutConstraint.activate([
            dock.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
            dock.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
        ])
        return dock
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        watches.forEach(NotificationCenter.default.removeObserver)
        watches.removeAll()
        guard let holder = superview else { return }
        holder.postsFrameChangedNotifications = true
        holder.postsBoundsChangedNotifications = true
        for name in [NSView.frameDidChangeNotification, NSView.boundsDidChangeNotification] {
            watches.append(NotificationCenter.default.addObserver(forName: name, object: holder, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.fitHolder() }
            })
        }
        fitHolder()
    }

    private func fitHolder() {
        guard let holder = superview, rootView.availableWidth != holder.bounds.width else { return }
        var content = rootView
        content.availableWidth = holder.bounds.width
        rootView = content
        invalidateIntrinsicContentSize()
    }

    deinit { watches.forEach(NotificationCenter.default.removeObserver) }
}
