import AppKit
import Combine
import SwiftUI
import SyncKit

// The card an agent's question stands in (docs/chat-asks.md, "The card"),
// the iPhone tray's anatomy at the Mac's sizes (picked 2026-10-22,
// claude.ai/artifact/AR1ksAvCJAozRoQo5rgoLh):
//
// - The head says who or what it is about: the person, the site, your
//   mail, your Mac, with the agent's face on the corner of its mark.
// - The body is the thing itself, from the same detail the iPhone reads
//   (ApprovalDetailBuilder): a mail as paper, several as rows that open in
//   place, a search as its search field, files, a message's bubble, the
//   accounts of a sign-in.
// - The foot is Not Now and the yes in the act's own words, with their
//   keys. Its buttons never move while the card is up: every face of a
//   button keeps the widest face's width, and the card grows upward from
//   them.

/// What a question shows, shaped once from its permit and its detail.
struct AskContent: Equatable {
    enum Mark: Equatable {
        case person(String)
        case site(String)
        case mail
        case messages
        case mac
        case folder(file: Bool)
        case skill
        case tabs
        case key
    }

    struct Row: Equatable, Identifiable {
        let id: String
        var who: String
        var subject: String
        var snippet: String
        var mail: ApprovalDetail.Mail?
    }

    enum Body: Equatable {
        case paper(ApprovalDetail.Mail)
        case rows([Row])
        case search(words: String, opens: Bool, scope: String)
        case bubble(String)
        case files([URL])
        case accounts([String])
        case press(String)
        case lines([String])
        case folder
    }

    var mark: Mark
    var name: String
    var sub: String
    var question: String?
    var body: Body
    /// A quiet line under the body: what a search reads under, how far a
    /// yes reaches.
    var terms: String?

    /// Whose question, in words: the plan and the chat's name.
    @MainActor static func who(_ permit: AgentPermit) -> String {
        let agents = Agents.shared
        guard let asker = agents.session(permit.session) else { return "" }
        let root = agents.session(agents.root(of: asker.id)) ?? asker
        let chat = root.title ?? root.name
        return [root.planName, chat == root.planName ? "" : chat].filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
    }

    @MainActor static func make(_ permit: AgentPermit, tab: Tab?) -> AskContent {
        let who = who(permit)
        let host = tab.map { ChatComposer.host($0) } ?? ""
        let site = host.isEmpty ? "This page" : host
        let plan = Agents.shared.session(Agents.shared.root(of: permit.session))?.planName ?? "The agent"
        func lines(_ more: String...) -> Body {
            let said = more.filter { !$0.isEmpty }
            return said.isEmpty ? .lines([permit.detail].filter { !$0.isEmpty }) : .lines(said)
        }
        switch permit.kind {
        case .sendMail:
            let outs = ApprovalDetails.shared.outgoing[permit.key] ?? []
            if let mail = ApprovalDetailBuilder.mails(id: permit.key, outs).detail.mails?.first {
                let to = mail.to.first.map { $0.name.isEmpty ? $0.address ?? "" : $0.name } ?? ""
                return AskContent(mark: .person(to), name: to, sub: who, question: nil, body: .paper(mail))
            }
            return AskContent(mark: .mail, name: "Your mail", sub: who, question: permit.question, body: lines(permit.draft))
        case .sendMails:
            let outs = ApprovalDetails.shared.outgoing[permit.key] ?? []
            let mails = ApprovalDetailBuilder.mails(id: permit.key, outs).detail.mails ?? []
            let rows = mails.map { mail in
                Row(id: mail.id, who: mail.to.first.map { $0.name.isEmpty ? $0.address ?? "" : $0.name } ?? "",
                    subject: mail.subject, snippet: snippet(mail.body), mail: mail)
            }
            return AskContent(mark: .mail, name: "Your mail", sub: who, question: permit.question,
                              body: rows.isEmpty ? lines(permit.draft) : .rows(rows))
        case .mailRead:
            let said = ApprovalDetails.shared.searching[ApprovalDetails.changeKey(session: permit.session, permit: permit)] ?? permit.detail
            let parts = said.components(separatedBy: "\n")
            let first = parts.first?.trimmingCharacters(in: .whitespaces) ?? ""
            let opens = first.hasPrefix("Opens")
            let words = quoted(first) ?? first
            let rest = parts.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            let scope = permit.forSession
                ? (opens ? "And any mail after it, while this \(plan) session runs." : "And any search after it, while this \(plan) session runs.")
                : (opens ? "And any mail after it, until this chat ends." : "And any search after it, until this chat ends.")
            return AskContent(mark: .mail, name: "Your mail", sub: who, question: "Let \(plan) \(opens ? "read" : "search") your mail?",
                              body: .search(words: words, opens: opens, scope: scope), terms: rest.isEmpty ? nil : rest)
        case .mailChange(_, let act):
            let threads = ApprovalDetails.shared.changing[ApprovalDetails.changeKey(session: permit.session, permit: permit)] ?? []
            let mails = ApprovalDetailBuilder.changed(id: permit.key, verb: Bench.changeWords(act).yes, threads: threads).mails ?? []
            let rows = mails.map { mail in
                Row(id: mail.id, who: mail.from?.name ?? "", subject: mail.subject, snippet: snippet(mail.body), mail: nil)
            }
            return AskContent(mark: .mail, name: "Your mail", sub: who, question: permit.question,
                              body: rows.isEmpty ? lines() : .rows(rows))
        case .mailSite(let host):
            return AskContent(mark: .site(host), name: host, sub: who, question: permit.question, body: lines())
        case .sendMessage(let to):
            return AskContent(mark: .person(to), name: to, sub: ["iMessage", who].filter { !$0.isEmpty }.joined(separator: " \u{00B7} "),
                              question: nil, body: .bubble(permit.draft))
        case .messages:
            return AskContent(mark: .messages, name: "Messages", sub: who, question: permit.question, body: lines())
        case .press(let label, _):
            return AskContent(mark: .site(host), name: site, sub: who, question: permit.question,
                              body: permit.draft.isEmpty ? .press(label) : .lines([permit.draft]), terms: permit.draft.isEmpty ? nil : permit.detail)
        case .upload(let files, _):
            return AskContent(mark: .site(host), name: site, sub: who, question: permit.question, body: .files(files))
        case .signIn(let host, let users):
            return AskContent(mark: .site(host), name: host, sub: ["Saved in Yab", who].filter { !$0.isEmpty }.joined(separator: " \u{00B7} "),
                              question: permit.question, body: .accounts(Array(users.prefix(3))))
        case .unlockManager(let provider):
            return AskContent(mark: .key, name: PasswordManagers.name(provider), sub: who, question: permit.question, body: lines())
        case .address(let host):
            return AskContent(mark: .site(host), name: host, sub: who, question: permit.question, body: lines())
        case .use:
            return AskContent(mark: .site(host), name: site, sub: who, question: permit.question, body: lines())
        case .computer:
            return AskContent(mark: .mac, name: "Your Mac", sub: who, question: permit.question, body: lines())
        case .folder(let ask):
            return AskContent(mark: .folder(file: ask.file), name: ask.question, sub: who, question: nil, body: .folder)
        case .native:
            return AskContent(mark: .tabs, name: "Yab", sub: who, question: permit.question, body: lines(permit.draft.isEmpty ? permit.detail : permit.draft))
        case .saveSkill(let name, _):
            return AskContent(mark: .skill, name: name, sub: who, question: permit.question, body: lines(String(permit.draft.prefix(400))))
        }
    }

    /// A mail's line that says something: the one after a short greeting.
    static func snippet(_ body: String) -> String {
        let words = body.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return words.count > 1 && words[0].count < 24 ? words[1] : (words.first ?? "")
    }

    /// "Yab 0.32" out of "Looks for “Yab 0.32”".
    static func quoted(_ line: String) -> String? {
        guard let open = line.firstIndex(of: "\u{201C}"), let close = line.lastIndex(of: "\u{201D}"), open < close else { return nil }
        let words = line[line.index(after: open)..<close]
        return words.isEmpty ? nil : String(words)
    }
}

// MARK: - the mark

/// What a question is about, with the agent's face on its corner: a disc
/// that is the face itself, two upright eyes (AgentFace at rest), cut out
/// of the mark by a ring of the card.
struct AskMark: View {
    let mark: AskContent.Mark
    var size: CGFloat = 32
    var face = true

    /// A person's own color, the same for the same name every time (the
    /// iPhone tray's).
    static func tint(_ name: String) -> Color {
        let colors: [Color] = [
            Color(red: 0.48, green: 0.35, blue: 0.97), Color(red: 0.94, green: 0.42, blue: 0.0),
            Color(red: 0.0, green: 0.54, blue: 0.48), Color(red: 0.08, green: 0.4, blue: 0.75),
            Color(red: 0.85, green: 0.11, blue: 0.38), Color(red: 0.43, green: 0.3, blue: 0.25),
        ]
        let sum = name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return colors[abs(sum) % colors.count]
    }

    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "\u{00B7}" || $0 == "@" || $0 == "." }).prefix(2)
        return words.compactMap(\.first).map(String.init).joined().uppercased()
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            picture
                .frame(width: size, height: size)
            if face {
                AskFaceBadge()
                    .offset(x: 4, y: 4)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var picture: some View {
        switch mark {
        case .person(let name):
            Text(Self.initials(name))
                .font(.system(size: size >= 32 ? 12.5 : 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Self.tint(name), in: Circle())
        case .site(let host):
            SiteMark(host: host, size: size)
        case .mail:
            tile("envelope.fill", Color(red: 0.77, green: 0.13, blue: 0.12))
        case .messages:
            tile("message.fill", Color(red: 0.2, green: 0.78, blue: 0.35))
        case .mac:
            tile("laptopcomputer", Color(white: 0.36))
        case .folder(let file):
            tile(file ? "doc.fill" : "folder.fill", Color(red: 0.23, green: 0.56, blue: 0.9))
        case .skill:
            tile("doc.text", Color(white: 0.28))
        case .tabs:
            tile("square.on.square", Color(white: 0.28))
        case .key:
            tile("key.fill", Color(red: 0.1, green: 0.45, blue: 0.91))
        }
    }

    private func tile(_ symbol: String, _ ground: Color) -> some View {
        Symbol(symbol, size: size * 0.5)
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(ground, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }
}

/// The agent's face on a mark's corner: 17 pt, the disc itself the face.
struct AskFaceBadge: View {
    var body: some View {
        Canvas { context, canvas in
            let k = canvas.width / 16
            var eyes = Path()
            eyes.move(to: CGPoint(x: 6 * k, y: 6.4 * k)); eyes.addLine(to: CGPoint(x: 6 * k, y: 9 * k))
            eyes.move(to: CGPoint(x: 10 * k, y: 6.4 * k)); eyes.addLine(to: CGPoint(x: 10 * k, y: 9 * k))
            context.stroke(eyes, with: .color(Palette.ground), style: StrokeStyle(lineWidth: 1.9 * k, lineCap: .round))
        }
        .frame(width: 17, height: 17)
        .background(Palette.ink, in: Circle())
        // The cut: a ring of the card round the disc.
        .background(Circle().fill(Palette.ground).padding(-2)) // design: the badge's cut out of its mark, a ring of the card's ground, not a card
    }
}

// MARK: - the card

/// Where a question stands in its life, for the card's foot.
enum AskPhase: Equatable {
    case ready
    /// The yes was taken: the ring draws, then the -ing words while it runs.
    case going(since: Date)
    /// It didn't go: the reason in red over the buttons; the yes tries again.
    case failed(String)
    /// Answered elsewhere, or the chat stopped: what happened, in place of
    /// the buttons, for a moment before the card goes.
    case said(String, good: Bool)

    var acceptsAnswer: Bool {
        switch self { case .ready, .failed: return true; case .going, .said: return false }
    }
}

/// What a card's buttons do, given by whoever holds the question.
struct AskActions {
    var no: () -> Void
    var yes: (_ user: String?) -> Void
    var always: (() -> Void)?
    var never: (() -> Void)?
    var stop: (() -> Void)?
}

struct AgentAskCard: View {
    let content: AskContent
    let permit: AgentPermit
    var phase: AskPhase = .ready
    /// "1 of 2" while more wait under it.
    var count: String?
    var width: CGFloat = AgentAskCard.width
    var keysReach = true
    var actions: AskActions
    /// The stand's: a send keeps its mark and controls through the Undo
    /// capsule the same card folds into.
    var fold: Namespace.ID?
    /// The same card after Send. Its footer and mark stay mounted while
    /// the single surface closes around them (approved layout B).
    var toast: AskStand.Toast?
    /// Some hosts draw their own surface.
    var surface = true

    static let width: CGFloat = 360
    /// A --test run pressing a row (its index), Back or "N more", as a
    /// click would (agent-ask-stand act: open, back, all).
    static let pressed = PassthroughSubject<String, Never>()

    private var confirmation = Keymap.shared.slot(.confirmDanger)
    @State private var option = false
    @State private var watching: Any?
    /// The mail of several opened in place, and every row shown.
    @State private var opened: Int?
    @State private var all = false
    @State private var whole = false
    /// The send foot's folded faces, as wide as they are drawn (AskSendFoot).
    @State private var footWidths: [String: CGFloat] = [:]
    @Namespace private var travel
    @Environment(\.accessibilityReduceMotion) private var still

    private var rows: [AskContent.Row] {
        if case .rows(let rows) = content.body { return rows }
        return []
    }

    private var openRow: AskContent.Row? { opened.flatMap { rows.indices.contains($0) ? rows[$0] : nil } }

    private var mailFold: Bool {
        guard fold != nil else { return false }
        switch permit.kind {
        case .sendMail, .sendMails: return true
        default: return false
        }
    }

    private var compact: Bool {
        if case .going = phase { return true }
        return toast != nil
    }

    private var singleMail: Bool {
        if case .paper = content.body { return true }
        return false
    }

    var body: some View {
        Group {
            if mailFold { sendCard } else { ordinaryCard }
        }
        // opened, all and whole change inside withAnimation, not here: an
        // .animation on the card moves only its insides, and the corner
        // would set the card at its new height at once, its buttons
        // jumping by the difference before gliding back.
        .animation(still ? nil : AskMotion.height, value: phase)
        .onAppear {
            watching = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                option = event.modifierFlags.contains(.option)
                return event
            }
        }
        .onDisappear {
            if let watching { NSEvent.removeMonitor(watching) }
            watching = nil
        }
        .onReceive(Self.pressed) { press in
            switch press {
            case "back": step { opened = nil }
            case "all": step { all = true }
            default: if let index = Int(press), rows.indices.contains(index) { step { opened = index } }
            }
        }
    }

    private var ordinaryCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            top
            foot.padding(.top, 12)
        }
        .frame(width: width - 2 * CardFrame.inset, alignment: .leading)
        .agentCardFrame(surface: surface)
    }

    /// The folded mark (AskMark's 32 at 0.625) and the gap after it.
    private static let foldedMark: CGFloat = 32 * 0.625 + 10

    /// The expanded contents keep their layout as the outer frame closes.
    /// The footer is drawn once, pinned 12 pt from the bottom right.
    private var sendCard: some View {
        let cardWidth = AskSendFoot.foldedWidth(toast: toast, content: content, widths: footWidths) + 2 * CardFrame.inset + Self.foldedMark
        let corner = Radius.card
        return AskSendLayout(folded: compact ? 1 : 0, width: width, compactWidth: cardWidth) {
            VStack(alignment: .leading, spacing: 0) {
                top
                // The foot's room: a gap, the hairline, a gap and the controls.
                Color.clear.frame(height: AskSendLayout.foldedHeight + 1)
            }
            .frame(width: width - 2 * CardFrame.inset, alignment: .leading)
            .padding(CardFrame.inset)
            .opacity(compact ? 0 : 1)
            .animation(still ? nil : .easeOut(duration: 0.09), value: compact)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.hairline).frame(height: 1)
                .padding(.horizontal, CardFrame.inset)
                .padding(.bottom, AskSendLayout.foldedHeight)
                .opacity(compact ? 0 : 1)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottomTrailing) {
            Group {
                if case .said = phase {
                    foot
                } else {
                    AskSendFoot(permit: permit, content: content, phase: phase, toast: toast, keysReach: keysReach,
                                widths: $footWidths, no: actions.no, yes: { actions.yes(permit.answers.last?.user) })
                }
            }
            .padding(CardFrame.inset)
        }
        .overlay(alignment: .topLeading) {
            // This mark is never replaced by a second toast's avatar.
            AskMark(mark: content.mark, face: !compact)
                .scaleEffect(compact ? 0.625 : 1, anchor: .topLeading)
                .offset(x: CardFrame.inset, y: compact ? 16 : CardFrame.inset)
                .opacity(openRow == nil || compact ? 1 : 0)
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .background { if surface { HUD.plate(corner, surface: .page) } }
        .pointerTip(compact ? toast?.subject ?? "" : "")
        .animation(still ? nil : AskMotion.capsule, value: compact)
        .animation(still ? nil : AskMotion.capsule, value: toast)
    }

    private var top: some View {
        VStack(alignment: .leading, spacing: 0) {
            head
            VStack(alignment: .leading, spacing: 8) {
                if openRow == nil, let question = content.question {
                    MorphWords(question)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(swap)
                }
                bodyView
                    .id(openRow?.id ?? "root")
                    .transition(swap)
                if openRow == nil, let terms = content.terms {
                    Text(terms)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 10)
            if case .failed(let why) = phase {
                Text(why)
                    .font(.system(size: 12))
                    .foregroundStyle(ButtonCSS.danger)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
                    .transition(.opacity)
            }
        }
    }

    /// One body for another: the old one gone in 80 ms, the new one in
    /// after it, so the two are never read on top of each other.
    private var swap: AnyTransition {
        still ? .opacity : .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 6)).animation(.easeOut(duration: 0.16).delay(0.06)),
            removal: .opacity.animation(.easeOut(duration: 0.08)))
    }

    /// Opening a mail, going back and showing every row change the card's
    /// height: the corner moves its top with it, its buttons stay put.
    private func step(_ change: () -> Void) {
        withAnimation(still ? nil : AskMotion.step, change)
    }

    // MARK: the head

    private var head: some View {
        HStack(spacing: 10) {
            if openRow != nil {
                Button { step { opened = nil } } label: {
                    Symbol("chevron.left", size: 12, weight: .semibold)
                        .foregroundStyle(Palette.muted)
                        .frame(width: 16, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyTip("Back")
                .transition(.opacity.combined(with: .offset(x: -6)))
            }
            Group {
                if let row = openRow {
                    AskMark(mark: .person(row.who))
                        .matchedGeometryEffect(id: "mark." + row.id, in: travel)
                } else if mailFold {
                    Color.clear.frame(width: 32, height: 32)
                } else if let fold {
                    AskMark(mark: content.mark)
                        .matchedGeometryEffect(id: "mark." + permit.key, in: fold)
                } else {
                    AskMark(mark: content.mark)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Group {
                    if let row = openRow {
                        Text(row.who).matchedGeometryEffect(id: "name." + row.id, in: travel)
                    } else {
                        MorphWords(mailFold && singleMail ? "Send this mail?" : content.name)
                    }
                }
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                MorphWords(openRow.map { "\((opened ?? 0) + 1) of \(rows.count) \u{00B7} \($0.subject)" }
                           ?? (mailFold && singleMail ? [content.sub, content.name].filter { !$0.isEmpty }.joined(separator: " \u{00B7} ") : content.sub))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let count {
                Text(count)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Palette.muted)
                    .monospacedDigit()
            }
        }
    }

    // MARK: the body

    @ViewBuilder private var bodyView: some View {
        if let row = openRow, let mail = row.mail {
            AskPaper(mail: mail, whole: $whole.animation(still ? nil : AskMotion.height), flat: mailFold)
        } else {
            switch content.body {
            case .paper(let mail):
                AskPaper(mail: mail, whole: $whole.animation(still ? nil : AskMotion.height), flat: mailFold)
            case .rows(let rows):
                rowsView(rows)
            case .search(let words, let opens, let scope):
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Symbol(opens ? "envelope" : "magnifyingglass", size: 12.5, weight: .semibold)
                            .foregroundStyle(Palette.muted)
                        Text(words)
                            .font(.system(size: 13.5))
                            .foregroundStyle(Palette.ink)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Palette.ink.opacity(0.08), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    Text(scope)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .bubble(let text):
                HStack {
                    Spacer(minLength: 32)
                    Text(text)
                        .font(.system(size: 13.5))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.accentColor,
                                    in: UnevenRoundedRectangle(topLeadingRadius: Radius.floating, bottomLeadingRadius: Radius.floating,
                                                             bottomTrailingRadius: Radius.small, topTrailingRadius: Radius.floating,
                                                             style: .continuous))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            case .files(let urls):
                HStack(spacing: 8) {
                    ForEach(Array(urls.prefix(3).enumerated()), id: \.offset) { _, url in
                        VStack(spacing: 4) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                .resizable()
                                .frame(width: 40, height: 40)
                            Text(url.lastPathComponent)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(Palette.ink)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(ByteCountFormatter.string(fromByteCount: Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0), countStyle: .file))
                                .font(.system(size: 11))
                                .foregroundStyle(Palette.muted)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity)
                        .background(Palette.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    }
                }
                if urls.count > 3 {
                    Text("and \(urls.count - 3) more")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                }
            case .accounts(let users):
                VStack(spacing: 0) {
                    ForEach(Array(users.enumerated()), id: \.offset) { index, user in
                        Button { actions.yes(user) } label: {
                            HStack(spacing: 10) {
                                AskMark(mark: .person(user), size: 28, face: false)
                                Text(user)
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(Palette.ink)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                if index == 0, keysReach {
                                    KeyGlyphs(keys: "\u{23CE}", size: 12.5, tint: nil, rest: 0.6)
                                }
                            }
                            .padding(.horizontal, 10)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(AskRowPress())
                    }
                }
                .background(Palette.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            case .press(let label):
                VStack(alignment: .leading, spacing: 4) {
                    Text("\u{201C}\(label)\u{201D}")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Palette.ink)
                    if !permit.detail.isEmpty {
                        Text(permit.detail)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.muted)
                            .lineLimit(2)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            case .lines(let lines):
                if !lines.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 12.5))
                                .foregroundStyle(Palette.ink)
                                .lineLimit(whole ? nil : 8)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                }
            case .folder:
                if case .folder(let ask) = permit.kind {
                    FolderAskAbove(ask: ask)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// Several mails: three and "N more" beyond four; a row opens its mail
    /// in place, its mark and name travelling up into the head.
    private func rowsView(_ rows: [AskContent.Row]) -> some View {
        let shown = all || rows.count <= 4 ? rows : Array(rows.prefix(3))
        let more = rows.count - shown.count
        return capped(all && rows.count > 7) { VStack(spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, row in
                Button { if row.mail != nil { step { opened = index } } } label: {
                    HStack(spacing: 10) {
                        AskMark(mark: .person(row.who), size: 28, face: false)
                            .matchedGeometryEffect(id: "mark." + row.id, in: travel)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.who).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Palette.ink).lineLimit(1)
                                .matchedGeometryEffect(id: "name." + row.id, in: travel)
                            if !row.subject.isEmpty {
                                Text(row.subject).font(.system(size: 12.5)).foregroundStyle(Palette.ink).lineLimit(1)
                            }
                            if !row.snippet.isEmpty {
                                Text(row.snippet).font(.system(size: 11.5)).foregroundStyle(Palette.muted).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                        if row.mail != nil {
                            Symbol("chevron.right", size: 11, weight: .semibold)
                                .foregroundStyle(Palette.faint)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(minHeight: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(AskRowPress())
                .disabled(row.mail == nil)
            }
            if more > 0 {
                Button { step { all = true } } label: {
                    HStack(spacing: 10) {
                        Text("+\(more)")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Palette.muted)
                            .frame(width: 28, height: 28)
                            .background(Palette.ink.opacity(0.1), in: Circle())
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(more) more").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Color.accentColor)
                            Text(rows.dropFirst(shown.count).prefix(4).map(\.who).joined(separator: ", "))
                                .font(.system(size: 11.5)).foregroundStyle(Palette.muted).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(minHeight: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(AskRowPress())
            }
        } }
        .background {
            if !mailFold {
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(Palette.ink.opacity(0.06))
            }
        }
    }

    /// Every mail shown scrolls past seven rows, as a long mail does past
    /// 360 pt: the card stays within the corner's room, its buttons in it.
    @ViewBuilder private func capped<V: View>(_ on: Bool, @ViewBuilder _ list: () -> V) -> some View {
        if on {
            ThreadScrollView(.vertical) { list() }
                .frame(maxHeight: 360)
        } else {
            list()
        }
    }

    // MARK: the foot

    @ViewBuilder private var foot: some View {
        if case .said(let words, let good) = phase {
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Symbol("checkmark", size: 12, weight: .bold)
                Text(words).font(.system(size: 12.5, weight: .medium))
            }
            .foregroundStyle(good ? Palette.success : Palette.muted)
            .frame(height: ButtonSize.regular.height)
            .transition(.opacity)
        } else if case .accounts = content.body {
            HStack(spacing: 6) {
                Text("Click an account to sign in")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.muted)
                Spacer(minLength: 0)
                noButton
            }
        } else {
            HStack(spacing: 6) {
                if permit.ruleLabel != nil {
                    Button(option ? "Never Here" : "Always Here") { if option { actions.never?() } else { actions.always?() } }
                        .buttonStyle(.yab(.quiet, .regular))
                        .disabled(going)
                        .opacity(going ? 0.5 : 1)
                        .keyTip("\(permit.ruleLabel ?? "") from now on, without asking")
                }
                Spacer(minLength: 0)
                if permit.isFolder {
                    if permit.answers.isEmpty {
                        Button { actions.stop?() } label: { labeled("Stop", key: "esc") }
                            .buttonStyle(.yab(.secondary, .regular))
                    }
                } else {
                    noButton
                }
                ForEach(permit.answers, id: \.self) { yes in
                    if yes == permit.answers.last {
                        yesButton(yes)
                    } else {
                        Button { actions.yes(yes.user) } label: { Text(yes.title) }
                            .buttonStyle(.yab(.secondary, .regular))
                            .disabled(going)
                    }
                }
            }
        }
    }

    private var going: Bool { if case .going = phase { return true } else { return false } }

    /// Not Now, as wide in every state: dimmed, never shortened, while a
    /// yes runs; Never Here under ⌥ in the same width.
    private var noButton: some View {
        let never = permit.ruleLabel != nil && option && !going
        return Button { if never { actions.never?() } else { actions.no() } } label: {
            ZStack {
                labeled("Not Now", key: "esc").opacity(never ? 0 : 1)
                labeled("Never Here", key: "esc").opacity(never ? 1 : 0)
            }
        }
        .buttonStyle(.yab(.secondary, .regular))
        .disabled(going)
    }

    /// The yes: its words and keys, the ring drawing round as it is taken,
    /// the -ing words while it runs, its verb again after a failure. Every
    /// face is laid out under the others, so it never changes width.
    private func yesButton(_ yes: AgentPermit.Answer) -> some View {
        let keys = permit.weighty ? confirmation.keys?.text : "\u{23CE}"
        let goingWords = AgentPermit.going(yes.title)
        return Button { if !going { actions.yes(yes.user) } } label: {
            ZStack {
                labeled(yes.title, key: keys).opacity(going ? 0 : 1)
                HStack(spacing: 6) {
                    SendingArc()
                    Text(goingWords)
                }
                .opacity(0)
                if case .going(let since) = phase {
                    AskYesRing(since: since, words: goingWords)
                }
            }
        }
        .buttonStyle(.yab(.primary, .regular, glass: true))
        .allowsHitTesting(!going)
    }

    private func labeled(_ title: String, key: String?) -> some View {
        HStack(spacing: 6) {
            Text(title)
            if let key, keysReach {
                KeyGlyphs(keys: key, size: ButtonSize.regular.wordSize, tint: nil, rest: 0.6)
                    .transaction { $0.animation = nil }
            }
        }
    }
}

/// Explicitly interpolate the measured card's dimensions. Switching a
/// frame from its natural height to 52 would skip the height animation.
private struct AskSendLayout: Layout {
    /// The folded card: one row of controls inside the card's inset.
    static let foldedHeight = ButtonSize.regular.height + 2 * CardFrame.inset

    var folded: CGFloat
    let width: CGFloat
    var compactWidth: CGFloat
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(folded, compactWidth) }
        set { folded = newValue.first; compactWidth = newValue.second }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let full = subviews.first?.sizeThatFits(ProposedViewSize(width: width, height: nil)) ?? .zero
        return CGSize(width: width + (compactWidth - width) * folded,
                      height: full.height + (Self.foldedHeight - full.height) * folded)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: bounds.maxX, y: bounds.maxY), anchor: .bottomTrailing,
                              proposal: ProposedViewSize(width: width, height: nil))
    }
}

/// The same two controls travel across one another as the card folds:
/// Not Now / Send becomes status / Undo, without replacing either view.
private struct AskSendControlsLayout: Layout {
    var folded: CGFloat
    var finished: CGFloat
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(folded, finished) }
        set { folded = newValue.first; finished = newValue.second }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let no = subviews[0].sizeThatFits(.unspecified), yes = subviews[1].sizeThatFits(.unspecified)
        return CGSize(width: yes.width + (no.width + AskSendFoot.gap) * (1 - finished), height: ButtonSize.regular.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let no = subviews[0].sizeThatFits(.unspecified), yes = subviews[1].sizeThatFits(.unspecified)
        subviews[0].place(at: CGPoint(x: bounds.minX + (yes.width + AskSendFoot.gap) * folded, y: bounds.minY),
                          proposal: ProposedViewSize(no))
        subviews[1].place(at: CGPoint(x: bounds.minX + (no.width + AskSendFoot.gap) * (1 - finished) * (1 - folded), y: bounds.minY),
                          proposal: ProposedViewSize(yes))
    }
}

/// Approved B: the status sits directly on the card, with Undo on the
/// right. The original controls stay mounted through countdown and result:
/// Not Now becomes Undo, both a secondary yab button, and Send gives way to
/// the status, the one plain label.
private struct AskSendFoot: View {
    let permit: AgentPermit
    let content: AskContent
    let phase: AskPhase
    let toast: AskStand.Toast?
    let keysReach: Bool
    /// The folded faces' widths, drawn unseen beside the foot, so the card
    /// knows how far to close before it does (foldedWidth).
    @Binding var widths: [String: CGFloat]
    let no: () -> Void
    let yes: () -> Void
    private var confirmation = Keymap.shared.slot(.confirmDanger)
    @Environment(\.accessibilityReduceMotion) private var still

    /// Between the two controls, as in every card's foot.
    static let gap: CGFloat = 6

    private var started: Bool { if case .going = phase { return true }; return toast != nil }
    private var done: Bool { toast?.done != nil }
    private var sendKeys: String { permit.weighty ? confirmation.keys?.text ?? "\u{2318}\u{21A9}" : "\u{21A9}" }

    static func sending(_ content: AskContent) -> String {
        if case .rows(let rows) = content.body { return "Sending \(rows.count) mails" }
        return "Sending to \(content.name.split(separator: " ").first.map(String.init) ?? content.name)"
    }

    /// The status's words: Sending…, then Sent… or what came of it.
    static func status(_ toast: AskStand.Toast?, content: AskContent) -> String {
        let sending = toast?.title ?? sending(content)
        guard let result = toast?.done else { return sending }
        return result == "Sent" ? sending.replacingOccurrences(of: "Sending", with: "Sent") : result
    }

    private static let undoKey = "\u{1}undo"
    private static func key(_ words: String, done: Bool) -> String { (done ? "done\u{1}" : "going\u{1}") + words }

    /// The folded foot's width: Undo and the status while it can be taken
    /// back, the status alone after.
    static func foldedWidth(toast: AskStand.Toast?, content: AskContent, widths: [String: CGFloat]) -> CGFloat {
        let done = toast?.done != nil
        let status = widths[key(status(toast, content: content), done: done)] ?? 0
        return done ? status : (widths[undoKey] ?? 0) + gap + status
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let left = toast.map { Int(max(0, $0.until.timeIntervalSince(context.date)).rounded(.up)) }
            AskSendControlsLayout(folded: started ? 1 : 0, finished: done ? 1 : 0) {
                Button { if let toast { AskStand.shared.undo(toast.id) } else if !started { no() } } label: {
                    HStack(spacing: Self.gap) {
                        MorphWords(started ? "Undo" : "Not Now").fixedSize()
                        if keysReach { keys(started ? "\u{2318}Z" : "esc") }
                    }
                }
                .buttonStyle(.yab(.secondary, .regular))
                .disabled(done || (started && toast == nil))
                .opacity(done ? 0 : 1)
                .allowsHitTesting(!done)
                // One subview through the swap, so the layout keeps two.
                ZStack(alignment: .leading) {
                    if started {
                        status(Self.status(toast, content: content), left: left)
                            .transition(.opacity)
                    } else {
                        Button { yes() } label: {
                            HStack(spacing: Self.gap) {
                                Text(permit.answers.last?.title ?? "Send")
                                if keysReach { keys(sendKeys) }
                            }
                        }
                        .buttonStyle(.yab(.primary, .regular))
                        .transition(.opacity)
                    }
                }
            }
        }
        .fixedSize()
        .clipped()
        .background { measures.hidden() }
        .animation(still ? nil : AskMotion.controls, value: started)
        .animation(still ? nil : AskMotion.controls, value: toast?.done)
    }

    private func keys(_ keys: String) -> some View {
        KeyGlyphs(keys: keys, size: ButtonSize.regular.wordSize, tint: nil, rest: 0.6)
            .transaction { $0.animation = nil }
    }

    /// The flat status: its mark, its words, the seconds left. Sending in
    /// the Mac's accent, Sent in the success green, the rest muted; a cross
    /// only for what was neither sent nor taken back.
    private func status(_ words: String, left: Int?) -> some View {
        let result = toast?.done
        return HStack(spacing: Self.gap) {
            Group {
                switch result {
                case nil: AskSendSpinner()
                case .some("Sent"): AskSendTick()
                case .some("Not sent"): Symbol("yab.undo", size: 12, side: 12)
                case .some("Already sent"): Symbol("checkmark", size: 12, side: 12)
                default: Symbol("xmark", size: 12, side: 12)
                }
            }
            .frame(width: 12, height: 12)
            .transition(.opacity.combined(with: .scale(scale: 0.6)))
            MorphWords(words).lineLimit(1).fixedSize()
            if result == nil {
                Text(left.map { String($0) } ?? "")
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
                    .frame(width: Self.digits)
                    .animation(still ? nil : AskMotion.counter, value: left)
            }
        }
        .font(ButtonSize.regular.font)
        .foregroundStyle(result == nil ? Color.accentColor : result == "Sent" ? Palette.success : Palette.muted)
        .frame(height: ButtonSize.regular.height)
    }

    /// Room for two digits, so the countdown never moves the words.
    private static let digits: CGFloat = 18

    /// Every folded face, unseen, so the card's folded width is known
    /// before the fold and before each result.
    private var measures: some View {
        let sending = toast?.title ?? Self.sending(content)
        let results = [sending.replacingOccurrences(of: "Sending", with: "Sent"), "Not sent", "Already sent"]
        return ZStack {
            Button {} label: {
                HStack(spacing: Self.gap) {
                    Text("Undo")
                    if keysReach { keys("\u{2318}Z") }
                }
            }
            .buttonStyle(.yab(.secondary, .regular))
            .fixedSize()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { widths[Self.undoKey] = $0 }
            measured(sending, done: false)
            ForEach(results, id: \.self) { measured($0, done: true) }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func measured(_ words: String, done: Bool) -> some View {
        HStack(spacing: Self.gap) {
            Color.clear.frame(width: 12, height: 12)
            Text(words).lineLimit(1)
            if !done { Color.clear.frame(width: Self.digits) }
        }
        .font(ButtonSize.regular.font)
        .fixedSize()
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { widths[Self.key(words, done: done)] = $0 }
    }
}

/// The prototype's 12 pt, three-quarter ring, one turn in 0.8 s.
private struct AskSendSpinner: View {
    @State private var turning = false
    @Environment(\.accessibilityReduceMotion) private var still
    var body: some View {
        Circle().trim(from: 0, to: 0.75)
            .stroke(style: StrokeStyle(lineWidth: 1.8, lineCap: .butt))
            .padding(0.9) // design: half of the 1.8 pt stroke keeps the 12 pt spinner inside its bounds
            .rotationEffect(.degrees(turning ? 360 : 0))
            .onAppear {
                withAnimation(.linear(duration: still ? 2.4 : 0.8).repeatForever(autoreverses: false)) { turning = true }
            }
    }
}

private struct AskSendTick: View {
    @State private var drawn: CGFloat = 0
    @State private var started = false
    @State private var alive = false
    @State private var feedback: UUID?
    @Environment(\.accessibilityReduceMotion) private var still
    var body: some View {
        AskTickPath().trim(from: 0, to: drawn)
            .stroke(style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
            .onAppear(perform: begin)
            .onDisappear {
                alive = false
                drawn = 1
                if let feedback { NoticeFeedback.cancelSuccessPair(feedback) }
                feedback = nil
            }
    }

    private func begin() {
        guard !started else { return }
        started = true
        alive = true
        if still {
            drawn = 1
            feedback = NoticeFeedback.beginSuccessPair()
            DispatchQueue.main.asyncAfter(deadline: .now() + AskMotion.successLong) { finishFeedback() }
            return
        }
        // The elbow is 32.6% of the path's length. Each landing gives
        // its own beat; a busy frame cannot make an independent timer
        // fire before the corresponding stroke has finished.
        withAnimation(.linear(duration: AskMotion.successShort), completionCriteria: .logicallyComplete) {
            drawn = 0.326
        } completion: {
            guard alive else { return }
            feedback = NoticeFeedback.beginSuccessPair()
            withAnimation(.easeOut(duration: AskMotion.successLong), completionCriteria: .logicallyComplete) {
                drawn = 1
            } completion: { finishFeedback() }
        }
    }

    private func finishFeedback() {
        guard alive, let feedback else { return }
        NoticeFeedback.endSuccessPair(feedback)
        self.feedback = nil
    }
}

private struct AskTickPath: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.width * 0.2, y: rect.height * 0.52))
            p.addLine(to: CGPoint(x: rect.width * 0.42, y: rect.height * 0.75))
            p.addLine(to: CGPoint(x: rect.width * 0.85, y: rect.height * 0.25))
        }
    }
}

/// A yes being taken: a ring drawn round in 0.6 s (the iPhone tray's
/// approvalRing), then the -ing words with their arc while it runs.
private struct AskYesRing: View {
    let since: Date
    let words: String
    @State private var drawn: CGFloat = 0
    @State private var running = false
    @Environment(\.accessibilityReduceMotion) private var still

    var body: some View {
        ZStack {
            if running {
                HStack(spacing: 6) {
                    SendingArc()
                    Text(words)
                }
                .transition(.opacity)
            } else {
                Circle()
                    .trim(from: 0, to: drawn)
                    .stroke(style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 14, height: 14)
            }
        }
        .onAppear {
            let left = max(0, 0.6 - Date().timeIntervalSince(since))
            guard left > 0 else { running = true; return }
            withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: left)) { drawn = 1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + left) {
                withAnimation(still ? nil : Motion.quick) { running = true }
            }
        }
    }
}

/// One mail as paper: To, Cc, Subject, its first lines and Show All; Show
/// All grows its words in place, up from the buttons.
struct AskPaper: View {
    let mail: ApprovalDetail.Mail
    @Binding var whole: Bool
    /// The approved single surface: subject, message and recipients have
    /// no second well or inset inside the approval card.
    var flat = false

    private func named(_ people: [ApprovalDetail.Person]) -> String {
        people.map { person in
            guard let address = person.address, !address.isEmpty, address != person.name else { return person.name }
            return person.name.isEmpty ? address : "\(person.name) <\(address)>"
        }.joined(separator: ", ")
    }

    private var long: Bool { mail.body.count > 320 || mail.body.split(whereSeparator: \.isNewline).count > 6 }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if flat {
                Text(mail.subject)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(whole ? nil : 2)
                    .padding(.bottom, 4)
            } else {
                recipients
                header("Subject", mail.subject)
                Rectangle()
                    .fill(Palette.hairline)
                    .frame(height: 1)
                    .padding(.vertical, 6)
            }
            Group {
                if whole {
                    ThreadScrollView(.vertical) {
                        Text(mail.body)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 360)
                } else {
                    Text(mail.body)
                        .lineLimit(6)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(flat ? Palette.muted : Palette.ink)
            .textSelection(.enabled)
            if flat { recipients.padding(.top, 8) }
            if !mail.files.isEmpty {
                Text(mail.files.map(\.name).joined(separator: ", "))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                    .padding(.top, 4)
            }
            if long {
                HStack {
                    Spacer(minLength: 0)
                    Button(whole ? "Show Less" : "Show All") { whole.toggle() }
                        .buttonStyle(.yab(.secondary, .small, capsule: true))
                    Spacer(minLength: 0)
                }
                .padding(.top, 8)
            }
        }
        .padding(.horizontal, flat ? 0 : 12)
        .padding(.vertical, flat ? 0 : 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if !flat { RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(Palette.ink.opacity(0.06)) }
        }
    }

    private var recipients: some View {
        VStack(alignment: .leading, spacing: 2) {
            header("To", named(mail.to))
            if !mail.cc.isEmpty { header("Cc", named(mail.cc)) }
            if let bcc = mail.bcc, !bcc.isEmpty { header("Bcc", named(bcc)) }
        }
    }

    private func header(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(name)
                .font(.system(size: flat ? 11.5 : 12))
                .foregroundStyle(Palette.muted)
                .frame(width: flat ? nil : 52, alignment: .leading)
            Text(value)
                .font(.system(size: flat ? 11.5 : 12, weight: flat ? .regular : .medium))
                .foregroundStyle(flat ? Palette.muted : Palette.ink)
                .lineLimit(flat && whole ? nil : 1)
                .truncationMode(.middle)
        }
    }
}

/// A row in a card that is a button: lit under the press, as a list's.
struct AskRowPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Palette.ink.opacity(configuration.isPressed ? 0.08 : 0),
                        in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }
}

/// The question card's movements, the iPhone tray's springs.
enum AskMotion {
    static let sendDuration = 0.24
    static let successShort = 0.09
    static let successLong = sendDuration - successShort
    static let controls = Animation.timingCurve(0.2, 0.9, 0.25, 1, duration: sendDuration)
    static let capsule = controls
    static let counter = Animation.timingCurve(0.2, 0.9, 0.25, 1, duration: 0.25)
    /// In from nowhere it came from: approvalIn.
    static let arrive = Animation.spring(response: 0.34, dampingFraction: 0.88)
    /// Away, quicker than it came: approvalOut.
    static let leave = Animation.spring(response: 0.22, dampingFraction: 1)
    /// One body for another: approvalStep.
    static let step = Animation.spring(response: 0.32, dampingFraction: 0.88)
    /// The height with it: approvalHeight.
    static let height = Animation.spring(response: 0.3, dampingFraction: 0.88)
    /// The next card coming forward.
    static let forward = Animation.spring(response: 0.38, dampingFraction: 0.86)
    /// A card folding into the Undo toast: approvalFold.
    static let fold = Animation.spring(response: 0.46, dampingFraction: 0.92)
}
