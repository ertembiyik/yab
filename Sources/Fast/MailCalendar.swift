import AppKit
import SwiftUI

// The calendar in mail (docs/mail.md, Calendar): a card over a thread whose
// mail invites you, what it clashes with in your calendar, your answer sent
// to the organizer as iMIP through the send path any mail takes (⌘Z takes
// it back while it waits), and the free slots ⇧⌘A puts in the words. Agents
// read invitations (mail_read says them, as data) and never answer them.

extension MailDesk {
    /// An invitation as its card shows it (MailInviteCard).
    struct Invite: Equatable {
        /// The mail that carries it.
        let message: String
        let invite: MailInvite
        /// The occurrence it is about: the next of a series.
        var at: DateInterval
        /// Your answer as it stands: given here, sent from elsewhere (a
        /// REPLY of yours kept with the mail), or what the invitation says
        /// of you.
        var answer: MailInvite.Answer?
        /// Yours from here is still in its undo window.
        var sending = false
        /// What you had said before it changed, when that no longer holds.
        var before: MailInvite.Answer?
        /// What changed since an earlier one of it: "Moved from Mon, Oct
        /// 5, 14:00", "Was at Room 4".
        var change: String?
        /// What it overlaps in your calendar; nil until known, or with no
        /// calendar to look in.
        var clashes: [BusyTime]?
        /// Someone else's request, not called off and not over: it can be
        /// answered.
        var answerable = false
    }

    /// The card A, M and N answer: the thread's newest that can be answered.
    var answerable: Invite? {
        screen == .thread ? invites.last { $0.answerable } : nil
    }

    /// The invitations of the open thread, read from its mail as the store
    /// has it: their cards at once, an invitation that came as a file
    /// fetched once (then the cards again), and what each clashes with
    /// asked of the calendar.
    func loadInvites(_ row: Row, all: [MailMessage], in engine: MailCenter.Engine) {
        let me = [engine.store.me] + engine.store.aliases
        var cards = MailInvites.cards(all, me: me, store: engine.store)
        // What was asked of the calendar holds while the occurrence does.
        for at in cards.indices {
            if let old = invites.first(where: { $0.message == cards[at].message && $0.at == cards[at].at }) { cards[at].clashes = old.clashes }
        }
        if cards != invites { invites = cards }
        let missing = all.filter { $0.calendar == nil && ($0.files ?? []).contains(where: MailInvites.isCalendar) }
            .filter { invitesAsked.insert($0.id).inserted }
        if !missing.isEmpty {
            Task { @MainActor in
                guard await MailInvites.fetch(missing, engine: engine), self.open?.id == row.id else { return }
                self.refreshInvites()
            }
        }
        // Asked once while the thread is open: a calendar that can't be read
        // isn't asked again at every change of the store.
        for card in cards where card.answerable && !card.invite.allDay && card.clashes == nil && card.at.end > Date()
            && invitesAsked.insert("clash:\(card.message)@\(card.at.start.timeIntervalSince1970)").inserted {
            Task { @MainActor in
                guard let busy = await Meetings.shared.busy(from: card.at.start, to: card.at.end), self.open?.id == row.id,
                      let at = self.invites.firstIndex(where: { $0.message == card.message && $0.at == card.at }) else { return }
                let clashes = MailInvites.clashes(card.at, invite: card.invite, in: busy)
                if self.invites[at].clashes != clashes { self.invites[at].clashes = clashes }
            }
        }
    }

    /// The open thread's cards again, as the store has them now.
    func refreshInvites() {
        guard screen == .thread, let open, let engine = MailCenter.shared.engines[open.account] else {
            if !invites.isEmpty { invites = [] }
            return
        }
        loadInvites(open, all: engine.store.messages(thread: open.thread), in: engine)
    }

    /// A, M or N, or a card's button: your answer to the organizer, a mail
    /// carrying an iCalendar REPLY (MailInvite.reply), out after the undo
    /// window as any send, ⌘Z taking it back. An answer still waiting
    /// gives way to this one: the organizer hears only the last.
    func answer(_ answer: MailInvite.Answer, message wanted: String? = nil) {
        guard let row = open, row.real, let engine = MailCenter.shared.engines[row.account],
              let card = wanted.flatMap({ id in invites.first { $0.message == id } }) ?? answerable, card.answerable,
              let message = engine.store.message(card.message) else { return }
        // The same answer as stands: nothing more to say.
        if card.answer == answer, card.before == nil { return }
        let store = engine.store
        let (me, from) = MailInvites.answerer(card.invite, store: store)
        guard var draft = card.invite.replyMail(answer, from: me, answering: message) else { return }
        draft.from = from
        withdraw(card.invite, in: engine)
        draft.messageID = MailCompose.messageID(from: store.me)
        store.save(draft)
        store.keep(MailRSVP(draft: draft.id, uid: card.invite.uid, recurrence: card.invite.recurrence, sequence: card.invite.sequence,
                            answer: answer, message: card.message, ics: card.invite.reply(answer, from: me)))
        let seq = MailCenter.shared.act(.send, thread: draft.id, account: row.account, after: MailCenter.undoSend)
        say("Sending", mark: "paperplane", keys: ["⌘", "Z"], stay: MailCenter.undoSend, until: Date().addingTimeInterval(MailCenter.undoSend))
        if let seq {
            var undo = Undo(kind: .rsvp, seq: seq, account: row.account, row: row, split: split, screen: screen)
            undo.rsvp = draft.id
            remember(undo)
        }
        refreshInvites()
    }

    /// An answer to this event still in its undo window, taken back: its
    /// mail never goes, and ⌘Z no longer offers it.
    private func withdraw(_ invite: MailInvite, in engine: MailCenter.Engine) {
        let store = engine.store
        guard let waiting = store.rsvp(uid: invite.uid, recurrence: invite.recurrence), store.draft(waiting.draft) != nil,
              let op = store.allOps().first(where: { $0.kind == .send && $0.thread == waiting.draft }),
              MailCenter.shared.undo(op.seq, account: engine.account) else { return }
        store.dropDraft(waiting.draft)
        store.dropRSVP(draft: waiting.draft)
        forgetUndo { $0.kind == .rsvp && $0.rsvp == waiting.draft }
    }

    /// ⌘Z on an answer: back while it waits, its draft and record gone,
    /// the card asking again; "Already sent" after.
    func takeBackAnswer(_ last: Undo) -> Bool {
        guard let seq = last.seq, MailCenter.shared.undo(seq, account: last.account) else { return false }
        if let id = last.rsvp, let store = MailCenter.shared.engines[last.account]?.store {
            store.dropDraft(id)
            store.dropRSVP(draft: id)
        }
        refreshInvites()
        return true
    }

    // MARK: - free slots

    /// ⇧⌘A in a reply or a new mail: the field's rows become the free
    /// slots of the next five working days, the first of the next three
    /// days picked already; the caret's place kept for their words.
    func offerSlots() {
        guard draft != nil else { return }
        slotsRange = words?.selectedRange()
        field(.slots)
        MailSlots.read()
    }

    /// The slots picked, as words, where the caret was, as if typed
    /// (`insert`), apart from the words round them: a space after a word,
    /// a line before what follows. The keyboard back in the words once the
    /// field has given the page its own (Places.handBack).
    func insertSlots(_ text: String) {
        guard let now = draft, !text.isEmpty else { return }
        var text = text
        if let words, words.window != nil {
            let string = words.string as NSString
            if let range = slotsRange, NSMaxRange(range) <= string.length { words.setSelectedRange(range) }
            let range = words.selectedRange()
            let before = range.location > 0 ? string.substring(with: NSRange(location: range.location - 1, length: 1)) : "\n"
            let end = NSMaxRange(range)
            let after = end < string.length ? string.substring(with: NSRange(location: end, length: 1)) : "\n"
            text = (before == "\n" || before == " " ? "" : " ") + text + (after == "\n" ? "" : "\n")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak words] in
                guard let words, let window = words.window, window.firstResponder !== words else { return }
                window.makeFirstResponder(words)
            }
        } else if !now.body.isEmpty, !now.body.hasSuffix("\n") {
            text = "\n" + text
        }
        slotsRange = nil
        insert(text)
    }
}

// MARK: - a thread's invitations

enum MailInvites {
    /// Who answers an invitation: the address of yours it names (yours or
    /// an alias's), with that address's name, and the address the mail
    /// goes from: the same when the account sends as it (MailSendAs), else
    /// "" for the default. No signature goes with it.
    static func answerer(_ invite: MailInvite, store: MailStore) -> (me: MailPerson, from: String) {
        let address = (invite.attendee([store.me] + store.aliases)?.person.address ?? store.me).lowercased()
        let senders = store.sendAs()
        let sender = senders.first { $0.address == address }
        let name = [sender?.name, senders.first(where: \.primary)?.name, store.value("name")].compactMap { $0 }.first { !$0.isEmpty } ?? ""
        return (MailPerson(name: name, address: address), sender == nil ? "" : address)
    }

    /// A thread's cards, oldest first: one for each event, on its newest
    /// mail that asks or calls it off (an answer, yours or anyone's, has
    /// none), none for one you organize.
    static func cards(_ messages: [MailMessage], me: [String], store: MailStore?, now: Date = Date(), zone: TimeZone = .current) -> [MailDesk.Invite] {
        var newest: [String: (message: MailMessage, invite: MailInvite)] = [:]
        for message in messages {
            guard let text = message.calendar, let invite = MailInvite.parse(text), ["REQUEST", "CANCEL"].contains(invite.method),
                  !invite.organizes(me) else { continue }
            let key = invite.uid + "|" + invite.recurrence
            if let kept = newest[key], (kept.invite.sequence, kept.message.date) > (invite.sequence, message.date) { continue }
            newest[key] = (message, invite)
        }
        return newest.values.sorted { $0.message.date < $1.message.date }
            .map { card($0.invite, message: $0.message.id, me: me, store: store, now: now, zone: zone) }
    }

    static func card(_ invite: MailInvite, message: String, me: [String], store: MailStore?, now: Date = Date(),
                     zone: TimeZone = .current) -> MailDesk.Invite {
        let next = invite.next(after: now)
        var card = MailDesk.Invite(message: message, invite: invite, at: DateInterval(start: next.start, end: max(next.start, next.end)))
        // Over and done with: nothing left to answer.
        card.answerable = invite.asks && !invite.organizes(me) && card.at.end > now
        let mine = Set(me.map { $0.lowercased() })
        let kept = store?.invites(uid: invite.uid) ?? []
        // Your answers to it: given here, and REPLYs of yours kept with the
        // mail (sent from here or from your phone); the newest holds.
        var answers: [(answer: MailInvite.Answer, sequence: Int, at: Date, sending: Bool)] = []
        if let store, let rsvp = store.rsvp(uid: invite.uid, recurrence: invite.recurrence) {
            answers.append((rsvp.answer, rsvp.sequence, rsvp.at, store.draft(rsvp.draft) != nil))
        }
        for one in kept where mine.contains(one.from.lowercased()) {
            guard let reply = MailInvite.parse(one.ics), reply.method == "REPLY", reply.recurrence == invite.recurrence,
                  let answer = reply.attendee(me).flatMap({ MailInvite.Answer(status: $0.status) }) else { continue }
            answers.append((answer, reply.sequence, one.at, false))
        }
        // An answer to the newer version wins, then the later one.
        if let last = answers.max(by: { ($0.sequence, $0.at) < ($1.sequence, $1.at) }) {
            if last.sequence >= invite.sequence {
                card.answer = last.answer
                card.sending = last.sending
            } else {
                card.before = last.answer
            }
        }
        // Or what the invitation says of you, answered in a calendar.
        if card.answer == nil { card.answer = invite.attendee(me).flatMap { MailInvite.Answer(status: $0.status) } }
        if card.answer == card.before { card.before = nil }
        // What changed since the one before it, when that one came too.
        let earlier = kept.compactMap { MailInvite.parse($0.ics) }
            .filter { $0.method == "REQUEST" && $0.recurrence == invite.recurrence && $0.sequence < invite.sequence }
            .max { $0.sequence < $1.sequence }
        if let earlier, invite.method == "REQUEST" {
            if earlier.start != invite.start || earlier.end != invite.end {
                card.change = "Moved from " + earlier.when(zone: zone, now: now)
            } else if earlier.placeSaid != invite.placeSaid, !earlier.placeSaid.isEmpty {
                card.change = "Was at " + earlier.placeSaid
            }
        }
        return card
    }

    /// What of your calendar an occurrence overlaps: not itself (its UID,
    /// or its title at its time, as a calendar keeps an invitation it
    /// was given), nothing of no length.
    static func clashes(_ at: DateInterval, invite: MailInvite, in busy: [BusyTime]) -> [BusyTime] {
        busy.filter { other in
            other.start < at.end && other.end > at.start && other.end > other.start && other.uid != invite.uid
                && !(other.title == invite.title && abs(other.start.timeIntervalSince(at.start)) < 60)
        }.sorted { $0.start < $1.start }
    }

    /// The clash in words: "Overlaps Standup, 14:00–14:15"; "Overlaps
    /// Standup and Design sync"; "Overlaps Standup and 2 more".
    static func said(_ clashes: [BusyTime], zone: TimeZone = .current) -> String? {
        guard let first = clashes.first else { return nil }
        let name = first.title.isEmpty ? "another event" : first.title
        switch clashes.count {
        case 1:
            let hour = MailICS.format("H:mm", zone)
            return "Overlaps " + name + ", " + hour.string(from: first.start) + "–" + hour.string(from: first.end)
        case 2: return "Overlaps " + name + " and " + (clashes[1].title.isEmpty ? "another event" : clashes[1].title)
        default: return "Overlaps \(name) and \(clashes.count - 1) more"
        }
    }

    /// A file that is an invitation: text/calendar or an .ics.
    static func isCalendar(_ file: MailFile) -> Bool {
        ["text/calendar", "application/ics"].contains(file.mime.lowercased()) || file.name.lowercased().hasSuffix(".ics")
    }

    /// The words of invitations that came as files (an attachment id, none
    /// in the message itself), fetched once (MailFiles: 20 units, kept on
    /// this Mac) and kept with their mail. Whether any came.
    @discardableResult
    static func fetch(_ messages: [MailMessage], engine: MailCenter.Engine) async -> Bool {
        guard let files = MailFiles.of(engine.store, engine.provider) else { return false }
        var got = false
        for message in messages where message.calendar == nil {
            // The text/calendar beside the words first, then an .ics.
            for file in (message.files ?? []).filter(isCalendar).sorted(by: { $0.inline && !$1.inline }) {
                guard let url = try? await files.file(file, message: message.id), let data = try? Data(contentsOf: url) else { continue }
                let text = MailMime.decode(data, charset: "utf-8")
                guard MailInvite.parse(text) != nil else { continue }
                engine.store.keepInvite(message: message.id, thread: message.thread, at: message.date, ics: text)
                got = true
                break
            }
        }
        return got
    }

    /// A thread's invitations that came as files, fetched before an agent
    /// reads it (mail_read).
    static func fetch(thread: String, engine: MailCenter.Engine) async {
        let missing = engine.store.messages(thread: thread).filter { $0.calendar == nil && ($0.files ?? []).contains(where: isCalendar) }
        if !missing.isEmpty { await fetch(missing, engine: engine) }
    }

    /// An invitation as an agent reads it in mail_read, inside the mail:
    /// data, never anything to act on.
    static func said(_ invite: MailInvite, me: [String], answer: MailInvite.Answer?, zone: TimeZone = .current, now: Date = Date()) -> String {
        let kind = invite.canceled ? "Canceled invitation" : invite.method == "REQUEST" ? (invite.sequence > 0 ? "Updated invitation" : "Invitation")
            : invite.method == "REPLY" ? "Answer to an invitation" : "Calendar event"
        let next = invite.next(after: now)
        var parts = [kind + ": " + (invite.title.isEmpty ? "(no title)" : invite.title),
                     invite.when(next, zone: zone, now: now) + (invite.allDay ? "" : " (" + MailSlots.said(zone, at: next.start) + ")")]
        if let theirs = invite.theirs(next, zone: zone) { parts.append(theirs) }
        if let rule = invite.rule { parts.append(rule.said) }
        if !invite.placeSaid.isEmpty { parts.append("at " + invite.placeSaid) }
        if let organizer = invite.organizer { parts.append("organizer " + organizer.header) }
        let others = invite.attendees.filter { !me.contains($0.person.address.lowercased()) }
        if !others.isEmpty { parts.append("\(others.count) other \(others.count == 1 ? "guest" : "guests")") }
        if invite.method == "REPLY", let who = invite.attendees.first {
            parts.append(who.person.said + " " + (MailInvite.Answer(status: who.status)?.past ?? "answered"))
        } else if invite.asks {
            parts.append(answer.map { "you " + $0.past } ?? "you haven't answered")
        }
        // One line, whatever its words hold: data inside mail_read's fence
        // (MailAgent.fenced), never a line of its own.
        return MailICS.safe(parts.joined(separator: "; ").components(separatedBy: .newlines).joined(separator: " "))
    }
}

extension MailInvite.Answer {
    /// As a sentence says it was given: "accepted", "said maybe".
    var past: String {
        switch self {
        case .accepted: return "accepted"
        case .tentative: return "said maybe"
        case .declined: return "declined"
        }
    }
}

// MARK: - the card

/// An invitation over its thread: what, when in your zone and in theirs
/// when it differs, where and whose, how it repeats, what changed, what it
/// clashes with in your calendar; Accept, Maybe and Decline with their keys,
/// or, answered, your answer and the other two, quieter, to change it.
/// Called off, it says so and asks nothing.
struct MailInviteCard: View {
    let card: MailDesk.Invite
    var desk: MailDesk
    /// In the letter in front: one going out is only shown.
    var live = true

    private var invite: MailInvite { card.invite }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: CardFrame.wellGap) {
                MailDayTile(date: card.at.start, allDay: invite.allDay)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        // The invitation's words as data: verbatim, never Markdown or a link.
                        Text(verbatim: invite.title.isEmpty ? "Invitation" : invite.title)
                            .font(CardFrame.title)
                            .foregroundStyle(invite.canceled ? Palette.muted : Palette.ink)
                            .strikethrough(invite.canceled, color: Palette.muted)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        if let tag {
                            Text(tag).font(.system(size: 12)).foregroundStyle(Palette.muted).lineLimit(1)
                        }
                    }
                    ForEach(lines, id: \.self) { line in
                        Text(verbatim: line)
                            .font(CardFrame.detail)
                            .foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let clash = MailInvites.said(card.clashes ?? []) {
                        Text(verbatim: clash)
                            .font(CardFrame.detail)
                            .foregroundStyle(Color.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 1)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if card.answerable {
                buttons.padding(.top, CardFrame.buttonGap)
            }
        }
        .cardFrame()
        .accessibilityElement(children: .contain)
    }

    /// Beside the title: what kind of mail it is when not a plain ask.
    private var tag: String? {
        if invite.canceled { return "Canceled" }
        if invite.method == "REQUEST", invite.sequence > 0 || card.change != nil { return "Updated" }
        return nil
    }

    /// When (yours, then theirs), where and whose, how it repeats, what
    /// changed, and what you said before it did.
    private var lines: [String] {
        let at = (card.at.start, card.at.end)
        var out = [[invite.when(at), invite.theirs(at)].compactMap { $0 }.joined(separator: " · ")]
        let whose = invite.organizer.map { "Organized by " + ($0.name.isEmpty ? $0.address : $0.name) }
        let place = [invite.placeSaid, whose ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
        if !place.isEmpty { out.append(place) }
        if let rule = invite.rule { out.append(rule.said) }
        if let change = card.change { out.append(change) }
        if let before = card.before, card.answer == nil { out.append("You " + before.past + " before it changed") }
        return out
    }

    @ViewBuilder
    private var buttons: some View {
        HStack(spacing: 6) {
            if let answer = card.answer {
                // Your answer, said; the other two to change it.
                HStack(spacing: 6) {
                    Symbol(answer == .declined ? "xmark" : "checkmark", size: 11)
                    Text(answer.said)
                }
                .font(.system(size: CardFrame.words, weight: .medium))
                .foregroundStyle(Palette.ink)
                // Under the event's words, beside the day.
                .padding(.leading, CardFrame.well + CardFrame.wellGap)
                Spacer(minLength: 8)
                ForEach(MailInvite.Answer.allCases.filter { $0 != answer }, id: \.self) { other in
                    button(other, kind: .quiet)
                }
            } else {
                Spacer(minLength: 8)
                ForEach(MailInvite.Answer.allCases, id: \.self) { answer in
                    button(answer, kind: .secondary)
                }
            }
        }
    }

    private func button(_ answer: MailInvite.Answer, kind: ButtonKind) -> some View {
        Button { if live { desk.answer(answer, message: card.message) } } label: {
            HStack(spacing: 6) {
                Text(answer.button)
                ShortcutGlyphs(answer.action, size: CardFrame.words, tint: nil).opacity(0.6)
                    .transaction { $0.animation = nil }
            }
        }
        .buttonStyle(.yab(kind, CardFrame.button))
        .fixedSize()
        .accessibilityLabel(answer.button)
    }
}

/// The invitation's date on a small tear-off calendar, with two spare
/// sheets and a folded corner, ivory by day and graphite in a dark card.
struct MailDayTile: View {
    let date: Date
    let allDay: Bool
    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }

    var body: some View {
        let zone = allDay ? TimeZone(identifier: "UTC")! : .current
        let shape = RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
        ZStack {
            shape.fill(Color(white: dark ? 0.25 : 0.85))
                .frame(width: 35, height: 36)
                .rotationEffect(.degrees(-8))
                .offset(x: -1, y: 1)
            shape.fill(Color(white: dark ? 0.32 : 0.94))
                .frame(width: 35, height: 36)
                .rotationEffect(.degrees(5))
                .offset(x: 1, y: 1)
            VStack(spacing: 0) {
                Text(MailICS.format("MMM", zone).string(from: date).uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color(red: 0.96, green: dark ? 0.42 : 0.28, blue: dark ? 0.44 : 0.31))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(height: 13)
                Text(MailICS.format("d", zone).string(from: date))
                    .font(.system(size: 20, weight: .medium).monospacedDigit())
                    .foregroundStyle(Color(white: dark ? 0.93 : 0.13))
                    .frame(height: 23)
            }
            .frame(width: 35, height: 36)
            .background {
                shape.fill(LinearGradient(colors: [Color(white: dark ? 0.36 : 1), Color(white: dark ? 0.27 : 0.95)], startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            .overlay(shape.strokeBorder(dark ? Color.white.opacity(0.10) : Color.black.opacity(0.08), lineWidth: 0.5))
            .overlay {
                Canvas { context, size in
                    var perforation = Path()
                    perforation.move(to: CGPoint(x: 4, y: 13))
                    perforation.addLine(to: CGPoint(x: size.width - 4, y: 13))
                    context.stroke(perforation, with: .color(dark ? .white.opacity(0.13) : .black.opacity(0.12)), style: StrokeStyle(lineWidth: 0.5, lineCap: .round, dash: [1, 2]))

                    let corner = CGPoint(x: size.width, y: size.height)
                    var fold = Path()
                    fold.move(to: CGPoint(x: corner.x - 7, y: corner.y))
                    fold.addLine(to: CGPoint(x: corner.x - 7, y: corner.y - 7))
                    fold.addQuadCurve(to: CGPoint(x: corner.x, y: corner.y - 7), control: CGPoint(x: corner.x - 7, y: corner.y - 9))
                    fold.closeSubpath()
                    context.fill(fold, with: .linearGradient(Gradient(colors: [Color(white: dark ? 0.23 : 0.84), Color(white: dark ? 0.43 : 1)]), startPoint: CGPoint(x: corner.x - 7, y: corner.y - 7), endPoint: corner))
                }
                .clipShape(shape)
            }
            .shadow(color: .black.opacity(dark ? 0.35 : 0.14), radius: 1.5, y: 1) // design: shadow belongs to the illustrated paper, not a UI surface.
        }
        .frame(width: CardFrame.well, height: CardFrame.well)
        .accessibilityHidden(true)
    }
}
