import AppKit
import Combine
import SwiftUI

// design: file, sheets of mail drawn in miniature, at their own sizes

// A list in mail with nothing in it, and mail with no account yet
// (docs/mail.md, Empty lists). One thing for every list: a sheet of mail.
// The place a mail will land is a dashed outline, handled mail lies in a
// pile, and a list tells itself apart by how its sheets lie and one small
// grey mark on a corner. All grey, no color, no drawing but the sheets.
// Under them a fact, and one line on what to do or where to go. The sheets
// settle once, one by one, the mark last; seen again this session, they are
// simply there.

/// What mail remembers about its empty lists for the session: which have
/// come in already, and whether Needs you was just emptied by hand.
@MainActor
final class MailEmptyMemory {
    static let shared = MailEmptyMemory()
    private(set) var seen: Set<String> = []
    /// Needs you went from mail to none while you were in it.
    private(set) var cleared = false
    private var had = 0
    private var bag: AnyCancellable?

    /// Watches the list for Needs you emptying; the list view starts it.
    func start() {
        guard bag == nil else { return }
        bag = MailDesk.shared.observed(\.rows).sink { [weak self] rows in
            MainActor.assumeIsolated { self?.saw(rows.count) }
        }
    }

    private func saw(_ count: Int) {
        let desk = MailDesk.shared
        guard MailList.shared.split == "needs", desk.query.isEmpty, desk.who == nil else { had = 0; return }
        if count == 0, had > 0 {
            if !cleared { WrappedLedger.shared.add(.mailZero) }
            cleared = true
        }
        if count > 0 { cleared = false }
        had = count
    }

    /// Whether this kind comes in now, or is simply there (seen before, or
    /// mail held still: MailDesk.still).
    func arrives(_ kind: String) -> Bool { seen.insert(kind).inserted && !MailDesk.still }
}

/// One sheet of mail: its three grey lines, on paper or as the dashed place
/// one will land.
struct MailSheet: View {
    enum Look { case paper, faint, dashed }
    var look: Look = .paper
    var lines: [CGFloat] = [0.52, 0.78, 0.40]
    /// Two letters before the lines: whose mail it is.
    var initials: String?

    static let size = CGSize(width: 150, height: 62)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.surface, style: .continuous)
        ZStack(alignment: .topLeading) {
            switch look {
            case .dashed:
                shape.strokeBorder(Palette.hairline, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            case .paper, .faint:
                shape.fill(Palette.ground)
                    .overlay(shape.strokeBorder(Palette.hairline, lineWidth: 1))
                    .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
            }
            HStack(alignment: .top, spacing: 8) {
                if let initials {
                    Text(initials)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Palette.wash))
                }
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, width in
                        Capsule()
                            .fill(look == .paper ? Palette.hairline : Palette.wash)
                            .frame(width: (MailSheet.size.width - 28 - (initials == nil ? 0 : 30)) * width, height: 6)
                    }
                }
            }
            .padding(.horizontal, 12) // design: the sheet's lines sit its own inset in
            .padding(.top, 12)
        }
        .frame(width: MailSheet.size.width, height: MailSheet.size.height)
    }
}

/// The small grey mark on a sheet's corner that says which list it is.
struct MailSheetMark: View {
    let symbol: String?
    var number: Int?

    var body: some View {
        Group {
            if let number {
                Text("\(number)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Palette.ground)
                    .padding(.horizontal, 6)
                    .frame(minWidth: 22, minHeight: 22)
                    .background(Capsule().fill(Palette.ink))
            } else if let symbol {
                Symbol(symbol, size: 11, weight: .semibold)
                    .foregroundStyle(Palette.ink)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Palette.ground))
                    .overlay(Circle().strokeBorder(Palette.hairline, lineWidth: 1))
            }
        }
        .offset(x: 7, y: -7)
    }
}

/// A rounded bookmark over a sheet's top edge, for Kept.
private struct MailRibbon: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r: CGFloat = 4, w = rect.width, h = rect.height
        path.move(to: CGPoint(x: 0, y: r))
        path.addArc(center: CGPoint(x: r, y: r), radius: r, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.addLine(to: CGPoint(x: w - r, y: 0))
        path.addArc(center: CGPoint(x: w - r, y: r), radius: r, startAngle: .degrees(270), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: w, y: h - 2))
        path.addQuadCurve(to: CGPoint(x: w - 2.4, y: h - 0.8), control: CGPoint(x: w, y: h))
        path.addLine(to: CGPoint(x: w / 2 + 1.2, y: h - 3.4))
        path.addQuadCurve(to: CGPoint(x: w / 2 - 1.2, y: h - 3.4), control: CGPoint(x: w / 2, y: h - 4.2))
        path.addLine(to: CGPoint(x: 2.4, y: h - 0.8))
        path.addQuadCurve(to: CGPoint(x: 0, y: h - 2), control: CGPoint(x: 0, y: h))
        path.closeSubpath()
        return path
    }
}

/// A sheet as it lies in a pile: where, how turned, how it looks.
private struct Laid: Identifiable {
    let id: Int
    var look: MailSheet.Look = .paper
    var x: CGFloat = 0
    var y: CGFloat = 0
    var turn: Double = 0
    var mark: String?
    var number: Int?
    var ribbon = false
    var initials: String?
    var lines: [CGFloat] = [0.52, 0.78, 0.40]
}

/// Sheets laid as a list's pile, settling one by one when they arrive.
private struct MailPile: View {
    let sheets: [Laid]
    let arrives: Bool
    /// Needs you just emptied by hand: the last row condensing into the place.
    var fromRow = false
    @State private var settled = false

    var body: some View {
        let width = (sheets.map(\.x).max() ?? 0) - (sheets.map(\.x).min() ?? 0) + MailSheet.size.width
        ZStack {
            ForEach(sheets) { laid in
                MailSheet(look: laid.look, lines: laid.lines, initials: laid.initials)
                    .overlay(alignment: .topTrailing) {
                        if laid.ribbon {
                            MailRibbon().fill(Palette.ink).frame(width: 14, height: 20).offset(x: -14, y: -4)
                                .opacity(settled ? 1 : 0).offset(y: settled ? 0 : -8)
                        } else if laid.mark != nil || laid.number != nil {
                            MailSheetMark(symbol: laid.mark, number: laid.number)
                                .scaleEffect(settled ? 1 : 0.5).opacity(settled ? 1 : 0)
                        }
                    }
                    .rotationEffect(.degrees(laid.turn))
                    .offset(x: laid.x - ((sheets.map(\.x).max() ?? 0) + (sheets.map(\.x).min() ?? 0)) / 2, y: laid.y)
                    .opacity(settled || laid.look == .dashed && !arrives ? 1 : 0)
                    .offset(y: settled || laid.look == .dashed ? 0 : -14)
                    .scaleEffect(x: fromRow && !settled ? 3.2 : 1, y: fromRow && !settled ? 0.65 : 1)
                    .offset(y: fromRow && !settled ? -110 : 0)
                    .animation(MailDesk.still ? nil : .timingCurve(0.3, 0.9, 0.3, 1, duration: fromRow ? 0.42 : 0.26).delay(Double(laid.id) * 0.06),
                               value: settled)
            }
        }
        .frame(width: width, height: 92)
        .onAppear {
            if arrives { DispatchQueue.main.async { settled = true } } else { settled = true }
        }
    }
}

/// What an empty list in mail shows, picked from where the page is.
struct MailEmptyState: View {
    var desk: MailDesk
    var list: MailList
    var center: MailCenter
    /// Gmail's answers to searches, which a search with nothing here waits on.
    private var server = MailServerSearch.shared

    private struct Said {
        let kind: String
        var sheets: [Laid]
        let title: String
        var line = ""
        var key: String?
        var shortcut: Shortcut.Action?
        var keyWords = ""
        var keyAction: (() -> Void)?
        var fromRow = false
    }

    var body: some View {
        let said = self.said
        let memory = MailEmptyMemory.shared
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            MailPile(sheets: said.sheets, arrives: memory.arrives(said.kind), fromRow: said.fromRow)
                .padding(.bottom, 20)
            Text(said.title)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(Palette.ink)
            if !said.line.isEmpty {
                Text(said.line)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 330)
                    .padding(.top, 4)
            }
            if said.key != nil || said.shortcut != nil {
                let hint = HStack(spacing: 6) {
                    if let shortcut = said.shortcut {
                        ShortcutGlyphs(shortcut, size: 11.5, tint: nil)
                    } else if let key = said.key {
                        KeyGlyphs(keys: key, size: 11.5)
                    }
                    Text(said.keyWords)
                }
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.muted)
                // A key to learn is said; one that goes somewhere is also a click.
                Group {
                    if let action = said.keyAction {
                        Button(action: action) { hint }.buttonStyle(.plain)
                    } else {
                        hint
                    }
                }
                .padding(.top, 12)
            }
            Spacer(minLength: 24)
            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .id(said.kind)
        .transition(.opacity)
    }

    private var said: Said {
        let words = desk.query.trimmingCharacters(in: .whitespaces)
        if desk.who != nil || !words.isEmpty {
            let asked = desk.who?.title ?? "\u{201C}" + words + "\u{201D}"
            let reading = center.status.values.contains { $0.syncing && $0.synced == nil }
            if reading {
                return Said(kind: "search.reading", sheets: [Laid(id: 0, look: .faint, y: 3, turn: -3), Laid(id: 1, look: .faint, turn: 2), Laid(id: 2, y: -4, mark: "magnifyingglass")],
                            title: "Nothing for \(asked) yet", line: "Older mail is still coming in. What it finds shows up here as it does.")
            }
            // Nothing here: Gmail is asked for it (MailServerSearch), and
            // what it finds comes into the list; ↩ asks again.
            let accounts = list.account == "all" ? center.accounts : [list.account]
            if let search = desk.searchAsked {
                if server.asking(search, accounts: accounts) {
                    return Said(kind: "search.asking", sheets: [Laid(id: 0, look: .faint, y: 3, turn: -3), Laid(id: 1, y: -2, mark: "magnifyingglass")],
                                title: "Looking in all your mail", line: "Nothing for \(asked) on this Mac. Gmail is searching the rest.")
                }
                if let trouble = server.trouble(search, accounts: accounts) {
                    return Said(kind: "search.failed", sheets: [Laid(id: 0, look: .dashed, mark: "magnifyingglass")],
                                title: "Nothing for \(asked) on this Mac", line: trouble,
                                key: "↩", keyWords: "Search All Mail", keyAction: { MailDesk.shared.searchAll() })
                }
                if accounts.contains(where: { server.state(search, account: $0) != nil }) {
                    return Said(kind: "search.none", sheets: [Laid(id: 0, look: .dashed, mark: "magnifyingglass")],
                                title: "Nothing for \(asked)", line: "Not on this Mac, and not in Gmail either.")
                }
            }
            return Said(kind: "search.mac", sheets: [Laid(id: 0, look: .dashed, mark: "magnifyingglass")],
                        title: "Nothing for \(asked)", line: "Nothing on this Mac has it.",
                        key: "↩", keyWords: "Search All Mail", keyAction: { MailDesk.shared.searchAll() })
        }
        // Narrowed to nothing (⇧U, ⇧S, ⇧R): the way back to all of it.
        if let only = desk.only {
            let name = MailList.name(list.split)
            let title: String
            switch only {
            case .unread: title = "Nothing unread in \(name)"
            case .starred: title = "Nothing starred in \(name)"
            case .unanswered: title = "You wrote in everything in \(name)"
            }
            return Said(kind: "only." + only.rawValue, sheets: [Laid(id: 0, look: .dashed, mark: "line.3.horizontal.decrease")],
                        title: title, key: "esc", keyWords: "Show All", keyAction: { MailDesk.shared.narrow(nil) })
        }
        // A list beyond the inbox's with nothing of it here: Gmail is asked
        // for what is older (MailViews), or couldn't be.
        if MailGo.isView(list.split) {
            let name = MailList.name(list.split)
            let gmail = server.view(list.split, account: list.account)
            if gmail.asking {
                return Said(kind: "view.asking", sheets: [Laid(id: 0, look: .faint, y: 3, turn: -3), Laid(id: 1, y: -2, mark: "magnifyingglass")],
                            title: "Looking in Gmail", line: "Nothing in \(name) on this Mac. Gmail is looking for older mail.")
            }
            if let trouble = gmail.trouble {
                return Said(kind: "view.failed", sheets: [Laid(id: 0, look: .dashed, mark: "magnifyingglass")],
                            title: "Nothing in \(name) on this Mac", line: trouble)
            }
        }
        if let label = MailViews.label(list.split) {
            return Said(kind: "label", sheets: [Laid(id: 0, look: .faint, y: 4, turn: -3), Laid(id: 1, y: -2, mark: "tag")],
                        title: "Nothing labeled \u{201C}\(label)\u{201D}", line: "Mail under this label shows here, from this Mac and from Gmail.",
                        shortcut: .mailLabel, keyWords: "Label")
        }
        switch list.split {
        case "starred":
            return Said(kind: "starred", sheets: [Laid(id: 0, look: .faint, y: 4, turn: -3), Laid(id: 1, y: -2, mark: "star")],
                        title: "Nothing starred", line: "A thread you star stays here, wherever it is.",
                        shortcut: .mailStar, keyWords: "Star")
        case "sent":
            return Said(kind: "sent", sheets: [Laid(id: 0, look: .dashed, mark: "paperplane")],
                        title: "Nothing sent yet", line: "Mail you send, from here or from Gmail, shows here.")
        case "done":
            return Said(kind: "done", sheets: [Laid(id: 0, look: .faint, y: 3, turn: -2), Laid(id: 1, look: .paper, y: -2, mark: "checkmark")],
                        title: "Nothing done yet", line: "A thread you mark done leaves the inbox and waits here.",
                        shortcut: .mailDone, keyWords: "Mark Done")
        case "muted":
            return Said(kind: "muted", sheets: [Laid(id: 0, look: .dashed, mark: "speaker.slash")],
                        title: "Nothing muted", line: "A muted thread stays out of the inbox, and so does every reply in it.",
                        shortcut: .mailMute, keyWords: "Mute")
        case "spam":
            return Said(kind: "spam", sheets: [Laid(id: 0, look: .dashed, mark: "exclamationmark.shield")],
                        title: "No spam here", line: "What you mark as spam on this Mac waits here.")
        case "trash":
            return Said(kind: "trash", sheets: [Laid(id: 0, look: .dashed, mark: "trash")],
                        title: "Trash is empty", line: "What you move to the Trash waits here until Gmail lets it go.")
        case "all":
            return Said(kind: "all", sheets: [Laid(id: 0, look: .dashed)], title: "No mail here yet")
        case "waiting":
            return Said(kind: "waiting", sheets: [Laid(id: 0, look: .dashed, x: 16, y: 10, turn: 3), Laid(id: 1, x: -14, y: -4, turn: -4, mark: "arrow.up.right")],
                        title: "Nobody owes you a reply", line: "Mail you send that asks something waits here until they answer.")
        case "other":
            return Said(kind: "other", sheets: (0..<5).map { Laid(id: $0, look: $0 < 4 ? .faint : .paper, y: CGFloat(-$0) * 3) },
                        title: "Nothing else", line: "Lists, receipts and notifications land here, out of the way.")
        case "later":
            return Said(kind: "later", sheets: [Laid(id: 0, look: .faint, y: 4, turn: -3), Laid(id: 1, y: -2, mark: "clock")],
                        title: "Nothing set for later", line: "A thread comes back when you say. A send set for later waits here too.",
                        shortcut: .mailRemind, keyWords: "Remind Me")
        case "kept":
            return Said(kind: "kept", sheets: [Laid(id: 0, ribbon: true)],
                        title: "Nothing kept", line: "A thread kept stays at hand. A draft you write stays here until it’s sent.",
                        shortcut: .mailKeep, keyWords: "Keep")
        default:
            break
        }
        if list.split == MailSplits.skipped {
            return Said(kind: "skipped", sheets: [Laid(id: 0, look: .faint, y: 4, turn: -3), Laid(id: 1, y: -2, mark: "archivebox")],
                        title: "Nothing archived today", line: "Mail a split skips the inbox for is archived as it comes, and waits here for the day.")
        }
        if let split = list.split(list.split) {
            let name = split.title
            let person = MailDesk.person(in: list.split) != nil
            // VIP of nobody yet: Add to VIP is among mail's commands, its key
            // drawn as keys are, never in the words.
            let nobody = split.id == "vip" && split.rules.isEmpty
            let line = split.mode == .skip ? "Its new mail is archived as it comes, unless it’s from someone you’ve written to."
                : nobody ? "Add someone with Add to VIP among mail’s commands, and their mail lands here."
                : "Mail in your inbox that its rules gather shows here as it comes."
            return Said(kind: "list", sheets: [Laid(id: 0, look: .dashed, x: 8, y: 14, turn: 2), Laid(id: 1, look: .dashed, x: 4, y: 7, turn: -1),
                                              Laid(id: 2, initials: person ? MailDesk.initials(name.split(separator: " ").dropFirst().joined(separator: " ")) : nil,
                                                   lines: person ? [0.62, 0.9] : [0.52, 0.78, 0.40])],
                        title: "Nothing in \(name) yet", line: line, shortcut: nobody ? .mailCommands : nil, keyWords: nobody ? "Commands" : "",
                        keyAction: nobody ? { MailDesk.shared.field(.commands) } : nil)
        }
        // Needs you.
        // Every Account's key only where All Accounts gathers the other one.
        let together = center.together
        if list.account != "all", together.count > 1,
           let other = list.needs.filter({ $0.key != list.account && $0.value > 0 && together.contains($0.key) }).max(by: { $0.value < $1.value }) {
            return Said(kind: "needs.account", sheets: [Laid(id: 0, look: .dashed, x: 0), Laid(id: 1, x: 180, y: 4, turn: -2), Laid(id: 2, x: 180, y: 2, turn: 1.5),
                                                       Laid(id: 3, x: 180, number: other.value)],
                        title: "Nothing needs you here", line: "\(other.key) has \(other.value).",
                        shortcut: .mailAccountAll, keyWords: "Every Account", keyAction: { MailList.shared.choose(number: 0) })
        }
        if MailEmptyMemory.shared.cleared {
            let owed = MailDesk.read(split: "waiting", query: "", account: list.account).rows.prefix(2)
                .map { $0.who.components(separatedBy: ",").first?.components(separatedBy: " ").first ?? $0.who }
            let names = owed.count == 2 ? owed[0] + " and " + owed[1] : owed.first ?? ""
            // ⇥ says Waiting only where it is the column's next list.
            let tabbed = list.tabbed
            let next = tabbed.firstIndex(of: "needs").map { tabbed[($0 + 1) % tabbed.count] }
            return Said(kind: "needs.cleared", sheets: [Laid(id: 0, look: .dashed)], title: "Nothing needs you",
                        line: names.isEmpty ? "" : "\(names) owe\(owed.count == 1 ? "s" : "") you \(owed.count == 1 ? "a reply" : "replies").",
                        key: names.isEmpty || next != "waiting" ? nil : "⇥", keyWords: "Waiting", keyAction: { MailList.shared.split = "waiting" },
                        fromRow: true)
        }
        return Said(kind: "needs", sheets: [Laid(id: 0, look: .dashed)],
                    title: "Nothing needs you", line: "When someone asks you something, it lands here first.")
    }
}

/// Mail with no account yet, and while the first one is connected and read:
/// one card in the middle of mail's own space, never a page of settings.
/// Google asks over the page (MailCenter.connect); the card says what it is
/// waiting for, what went wrong, and that mail is being read.
struct MailFrontDoor: View {
    var center: MailCenter
    private var mailKey = Keymap.shared.slot(.mail)
    @MailStill private var still
    let browser: Browser?

    var body: some View {
        let state = self.state
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            MailPile(sheets: state.sheets, arrives: MailEmptyMemory.shared.arrives("door." + state.id))
                .padding(.bottom, 20)
            Text(state.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.ink)
            Text(state.line)
                .font(.system(size: 13))
                .foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
                .padding(.top, 4)
            if let button = state.button {
                Button { connect() } label: {
                    HStack(spacing: 6) {
                        Text(button)
                        KeyGlyphs(keys: "↩", size: 11.5, tint: nil, rest: 0.6)
                    }
                }
                .buttonStyle(.yab(.primary))
                .keyboardShortcut(.defaultAction)
                .padding(.top, 16)
            }
            if !state.note.isEmpty {
                Text(state.note)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.faint)
                    .padding(.top, 12)
            }
            Spacer(minLength: 24)
            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(still ? nil : .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.3), value: state.id)
    }

    private struct State {
        let id: String
        let sheets: [Laid]
        let title: String
        let line: String
        var button: String?
        var note = ""
    }

    private var state: State {
        if center.connecting {
            return State(id: "waiting", sheets: [Laid(id: 0, look: .dashed, mark: "envelope")], title: "Waiting for Google.",
                         line: "Finish in the window over the page. If Google says the app isn’t verified, choose Advanced, then Go to Yab.")
        }
        if center.connectFailed {
            let back = mailKey.keys.map { "come back with \($0.text) any time." } ?? "come back to Mail any time."
            return State(id: "failed", sheets: [Laid(id: 0, look: .dashed, mark: "envelope")], title: "Google didn’t give Yab access.",
                         line: "Nothing was read. Try again, or \(back)", button: "Try Again")
        }
        if center.connected {
            return State(id: "reading", sheets: [Laid(id: 0, look: .faint, y: 4, turn: -2), Laid(id: 1, look: .faint, y: 2, turn: 1.5), Laid(id: 2)],
                         title: "Reading your mail.", line: "Newest first, so what needs you shows up here in a minute. Older mail keeps coming in behind it.")
        }
        return State(id: "door", sheets: [Laid(id: 0, look: .dashed, mark: "envelope")], title: "Mail, sorted.",
                     line: "Gmail, read on this Mac and sorted by what it wants from you.", button: "Connect Gmail",
                     note: "Kept on this Mac, synced while Yab is open")
    }

    private func connect() {
        guard let browser else { return }
        SettingsWindow.shared.show(.mail, for: browser)
    }
}
