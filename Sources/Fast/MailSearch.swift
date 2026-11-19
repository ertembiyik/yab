import AppKit
import Combine
import SwiftUI

/// Mail's search, as ⌘K's list is drawn: the column's field is only a
/// door, and / or a click on it raises this over it, a field of its own,
/// large, its magnifier where the column's was, and under it what the
/// words find. Empty, the searches you went through lately, the threads
/// you opened lately and the people you wrote to last; with words, the search itself first, then people,
/// then the best threads, drawn as the list draws them, the words lit.
/// The list under it stays as it was until a row is taken: the words into
/// the list, a person's mail, a thread opened.
@MainActor
@Observable final class MailSearch {
    static let shared = MailSearch()

    /// A search gone through: words, a person, or a person and words.
    struct Recent: Codable, Equatable, Hashable {
        var words: String
        var rel: String?
        var name: String?
        var address: String?

        var who: MailDesk.Filter? { address.map { MailDesk.Filter(rel: rel ?? "with", name: name ?? "", address: $0) } }
        /// The line a list of it would keep, to leave out what is a list already.
        var q: String { who.map { MailDesk.line($0, words: words) } ?? words.trimmingCharacters(in: .whitespaces) }
    }

    /// A row under the field.
    enum Hit: Identifiable, Equatable {
        /// The words, or a person's mail with them: how many threads answer.
        case words(String, count: Int)
        /// The same asked of Gmail, the whole mailbox: ⇥ from anywhere in
        /// the search (MailServerSearch).
        case all(String)
        case recent(Recent)
        case person(MailDesk.Contact)
        case thread(MailDesk.Row)
        /// A thread opened lately, before a word is typed.
        case opened(MailDesk.Row)

        var id: String {
            switch self {
            case .words(let words, _): return "words:" + words
            case .all(let words): return "all:" + words
            case .recent(let recent): return "recent:" + recent.q + (recent.rel ?? "")
            case .person(let contact): return "person:" + contact.address
            case .thread(let row): return "thread:" + row.id
            case .opened(let row): return "opened:" + row.id
            }
        }

        /// The heading it goes under.
        var section: String? {
            switch self {
            case .words, .all: return nil
            case .recent: return "Recent"
            case .person: return "People"
            case .thread: return "Threads"
            case .opened: return "Recently opened"
            }
        }

        static func == (a: Hit, b: Hit) -> Bool { a.id == b.id }
    }

    /// The words in the field, while it is up.
    var typed = "" {
        didSet {
            guard typed != oldValue else { return }
            personLit = false
            lit = 0
            refresh()
        }
    }
    private(set) var hits: [Hit] = []
    /// The row ↩ takes: the first, until the arrows or the pointer move it.
    var lit = 0
    /// ⌫ once in the empty field: the person is chosen, ⌫ again takes them off.
    var personLit = false
    /// The column's field in the window, for the search to stand over.
    var field: CGRect = .zero
    /// The field's ground and its words' gray, on the column's tone: the
    /// search starts in them, then takes its own as it grows.
    @ObservationIgnored var fieldGround = Palette.wash
    @ObservationIgnored var fieldInk = Palette.muted
    /// The search is on screen, growing, up or going back into the field:
    /// the field itself is not drawn under it.
    var covering = false
    /// Times it grew out of the field, for the bench: never while mail
    /// holds still (MailDesk.still), when it fades in at its place.
    @ObservationIgnored var grew = 0
    private(set) var recents: [Recent] = []
    /// Threads opened lately, "account|thread", newest first.
    @ObservationIgnored private(set) var opened: [String] = []

    private static let kept = "mail.search.recent"
    private static let keptOpened = "mail.search.opened"
    private static let most = 5
    @ObservationIgnored private var bag: Set<AnyCancellable> = []
    @ObservationIgnored private lazy var away = ClickAway { [weak self] in self?.close() }
    var desk: MailDesk { MailDesk.shared }

    private init() {
        if let data = Store.settings.data(forKey: Self.kept), let saved = try? JSONDecoder().decode([Recent].self, from: data) {
            recents = saved
        }
        opened = Store.settings.stringArray(forKey: Self.keptOpened) ?? []
        // A thread opened anywhere in mail, kept for the empty search.
        MailList.shared.showing.removeDuplicates().sink { [weak self] shown in
            guard let shown else { return }
            // After the letter is drawn, not inside its key.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.saw(shown) } }
        }.store(in: &bag)
        MailDesk.shared.observed(\.searching).dropFirst().removeDuplicates().sink { [weak self] up in
            // After the change: @Published tells in its willSet.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.opened(up) } }
        }.store(in: &bag)
    }

    var clickZone: ClickAway { away }

    /// What the column's field says: the person, the words, or Search.
    static func said(_ desk: MailDesk) -> String {
        let words = desk.query.trimmingCharacters(in: .whitespaces)
        guard let who = desk.who else { return words.isEmpty ? "Search" : words }
        let name = who.name.isEmpty ? who.address : who.name
        return words.isEmpty ? name : name + " · " + words
    }

    private func opened(_ up: Bool) {
        away.watch(up)
        if up { prepare() } else { prepared = false }
    }

    /// Up again: the words the list is searched by, to go on from, and
    /// what they find, ready before the search is drawn (MailSearchLayer),
    /// so it grows to its whole height at once.
    @ObservationIgnored private var prepared = false
    func prepare() {
        guard desk.searching else { prepared = false; return }
        guard !prepared else { return }
        prepared = true
        typed = desk.query
        personLit = false
        lit = 0
        refresh(now: true)
    }

    /// The words the rows under the field answer: behind `typed` while the
    /// word index looks for the newest ones.
    private(set) var answered: String?
    /// Asks of the word index, the last one's answer the only one taken.
    @ObservationIgnored private var asked = 0

    /// What the field's words find, in the rows' order. Words are looked
    /// for off the main thread (MailDesk.find), so a letter typed is in the
    /// field at once and never waits for the index; the rows follow a few
    /// ms later, the last letter's only. `now`: at once, for the search
    /// coming up, which grows to its rows' height (MailSearchLayer).
    func refresh(now: Bool = false) {
        let words = typed.trimmingCharacters(in: .whitespaces)
        let account = MailList.shared.account
        let who = desk.who
        asked += 1
        let ask = asked
        guard who != nil || !words.isEmpty else {
            var out: [Hit] = []
            let lists = Set(MailList.shared.yours.map(\.q))
            out += recents.filter { !lists.contains($0.q) }.prefix(3).map { .recent($0) }
            let rows = opened.lazy.compactMap { key -> MailDesk.Row? in
                let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
                guard parts.count == 2, account == "all" || parts[0] == account else { return nil }
                return MailDesk.row(account: parts[0], thread: parts[1])
            }
            out += rows.prefix(4).map { .opened($0) }
            out += desk.recentContacts(3).map { .person($0) }
            return take(out, for: typed)
        }
        let query = MailDesk.search(words, who: who)
        let beside = MailDesk.beside(query, account: account)
        let people = who == nil ? desk.people(matching: words, limit: 3) : []
        let typed = typed
        func hits(_ found: (rows: [MailDesk.Row], total: Int)) -> [Hit] {
            [.words(words, count: found.total), .all(words)] + people.map { .person($0) } + found.rows.map { .thread($0) }
        }
        if now { return take(hits(MailDesk.find(query, in: beside, limit: 4)), for: typed) }
        Task.detached(priority: .userInitiated) { [weak self] in
            let found = MailDesk.find(query, in: beside, limit: 4)
            await MainActor.run { [weak self] in
                guard let self, self.asked == ask else { return }
                self.take(hits(found), for: typed)
            }
        }
    }

    private func take(_ out: [Hit], for words: String) {
        hits = out
        lit = min(lit, max(0, out.count - 1))
        answered = words
    }

    func move(_ by: Int) {
        guard !hits.isEmpty else { return }
        lit = max(0, min(hits.count - 1, lit + by))
    }

    /// ↩, or a click on a row.
    func take(_ index: Int? = nil) {
        let at = index ?? lit
        guard hits.indices.contains(at) else { return close() }
        switch hits[at] {
        case .words:
            // The words in the field, whether or not the rows under it
            // have caught up with the last letter.
            apply(words: typed, who: desk.who)
        case .all:
            desk.searchAll()
        case .recent(let recent):
            apply(words: recent.words, who: recent.who)
        case .person(let contact):
            apply(words: "", who: MailDesk.Filter(rel: "with", name: contact.name, address: contact.address))
        case .opened(let row):
            close()
            desk.show(desk.rows.first { $0.id == row.id } ?? row)
        case .thread(let row):
            // Opened at once; the search stays, so J and K walk it.
            apply(words: typed, who: desk.who)
            let listed = desk.rows.firstIndex { $0.id == row.id }
            if let listed { desk.sel = listed }
            desk.show(listed.map { desk.rows[$0] } ?? row)
        }
    }

    /// The person among the rows, for the bench: as ↩ on them.
    func takePerson(_ index: Int) {
        let people = hits.indices.filter { if case .person = hits[$0] { return true } else { return false } }
        guard people.indices.contains(index) else { return }
        take(people[index])
    }

    /// The words, the person or both, into the list; gone through, kept in
    /// Recent; the search put away.
    func apply(words: String, who: MailDesk.Filter?) {
        let words = words.trimmingCharacters(in: .whitespaces)
        desk.query = words
        if desk.who != who { desk.who = who }
        if desk.screen != .list { desk.back() }
        desk.searched()
        remember(Recent(words: words, rel: who?.rel, name: who?.name, address: who?.address))
        close()
    }

    /// esc, a click away: put away, what the column holds left as it is.
    func close() {
        guard desk.searching else { return }
        prepared = false
        desk.searching = false
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    /// Everything off: the list as it was before any search.
    func clear() {
        desk.query = ""
        desk.who = nil
        desk.searched()
    }

    /// ⌫ in the empty field over a person: chosen first, then gone.
    func backOverPerson() {
        if personLit {
            personLit = false
            desk.who = nil
            lit = 0
            refresh()
        } else {
            personLit = true
        }
    }

    /// ⌘⌫ on a recent search: gone from Recent.
    func forget() -> Bool {
        guard hits.indices.contains(lit), case .recent(let recent) = hits[lit] else { return false }
        recents.removeAll { $0 == recent }
        store()
        refresh()
        return true
    }

    /// A thread on screen: first among those opened lately.
    private func saw(_ shown: String) {
        let thread = shown.split(separator: "|", maxSplits: 1).last.map(String.init) ?? ""
        guard !thread.hasPrefix("draft:"), !thread.hasPrefix("send:") else { return }
        opened.removeAll { $0 == shown }
        opened.insert(shown, at: 0)
        opened = Array(opened.prefix(8))
        Store.settings.set(opened, forKey: Self.keptOpened)
    }

    /// The words searched by, lit where a word of the text starts with one,
    /// as mail's search matches them (MailStore.search, a word's start):
    /// "an" lights "Anna" and "and", not the middle of "variants". The
    /// words a search looks for (MailQuery.lit), not its operators or what
    /// it leaves out.
    nonisolated static func lit(_ text: String, words: String) -> AttributedString {
        var out = AttributedString(text)
        guard !words.isEmpty else { return out }
        for word in Set(MailQuery.parse(words).lit) where word.count >= 2 {
            var from = out.startIndex
            while from < out.endIndex, let found = out[from...].range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) {
                let before = found.lowerBound == out.startIndex ? nil : out.characters[out.characters.index(before: found.lowerBound)]
                if before.map({ !$0.isLetter && !$0.isNumber }) ?? true {
                    out[found].backgroundColor = Color(nsColor: .systemYellow).opacity(0.35)
                }
                from = found.upperBound
            }
        }
        return out
    }

    private func remember(_ recent: Recent) {
        guard !recent.words.isEmpty || recent.address != nil else { return }
        recents.removeAll { $0 == recent }
        recents.insert(recent, at: 0)
        recents = Array(recents.prefix(Self.most))
        store()
    }

    private func store() {
        if let data = try? JSONEncoder().encode(recents) { Store.settings.set(data, forKey: Self.kept) }
    }
}

/// The search over the window, where the column's field is: laid over the
/// window rather than in the column, which is a clipped view of its own
/// (ColumnHost) and narrower than it. It comes out of the field itself:
/// raised, it starts as the field's own rect and grows into its place,
/// the magnifier held still, the field's words giving way to the large
/// field's, the rows uncovered as it grows; put away, it goes back into
/// the field the same way, quicker. Only its frame and corner move. Mail
/// held still (Reduce Motion, Animations off): it fades in and out at
/// its place, nothing growing.
struct MailSearchLayer: View {
    var browser: Browser
    private var desk = MailDesk.shared
    @Bindable private var search = MailSearch.shared
    @MailStill private var still
    /// On screen, growing or going.
    @State private var mounted = false

    var body: some View {
        let up = browser.inMail && desk.searching && desk.browser === browser && search.field != .zero
        GeometryReader { room in
            if mounted {
                let origin = room.frame(in: .global).origin
                MailSearchFloat(desk: desk, search: search, up: up, still: still,
                                field: search.field.offsetBy(dx: -origin.x, dy: -origin.y), room: room.size) {
                    // Back in the field: gone, unless raised again meanwhile.
                    guard !desk.searching else { return }
                    mounted = false
                    search.covering = false
                }
                .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .onChange(of: up, initial: true) { _, up in turn(up) }
    }

    private func turn(_ up: Bool) {
        if up {
            search.prepare()
            search.covering = true
            // Held still by Reduce Motion: a fade at its place; with
            // Animations off, there in the frame of its key.
            if still, !MailDesk.instant { withAnimation(.easeOut(duration: 0.14)) { mounted = true } } else { mounted = true }
        } else if mounted, still {
            if MailDesk.instant { mounted = false } else { withAnimation(.easeOut(duration: 0.1)) { mounted = false } }
            search.covering = false
        }
    }
}

/// The search itself: the field, a line, the rows.
struct MailSearchFloat: View {
    var desk: MailDesk
    @Bindable var search: MailSearch
    /// Wanted up; it grows once its rows are measured, and goes back into
    /// the field when this turns, then says so.
    let up: Bool
    let still: Bool
    /// The column's field and the room it stands in, in the layer's space.
    let field: CGRect
    let room: CGSize
    let gone: () -> Void
    /// Grown to its place; else standing as the column's field.
    @State private var grown = false
    /// Grown and done growing: the field's own words take over from the
    /// label that grew out of the column's.
    @State private var settled = false
    @FocusState private var focus: Bool
    @State private var pointed: Int?
    /// The rows' whole height, laid out at the full width.
    @State private var height: CGFloat = 0

    static let width: CGFloat = 560
    /// Between the column's field and the search's edge: the floating
    /// corner less the control's.
    static let gap: CGFloat = Radius.floating - Radius.control
    static let head: CGFloat = 52
    static let row: CGFloat = 36
    /// Where every row's words and marks start, the headings' too: wide
    /// enough to hang unread's dot in it.
    static let edge: CGFloat = 16
    static let twoLines: CGFloat = 44
    /// Out of the field quick and settling hard, as a tray grows out of
    /// the button that raised it; back into it quicker still.
    static let opening = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.17)
    static let closing = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.11)

    /// Its left edge grown: from the field's left edge rightward; with the
    /// column on the window's right, too little room there, so from the
    /// field's right edge leftward.
    static func left(field: CGRect, room: CGSize) -> CGFloat {
        let x = field.minX - gap
        let wide = max(field.width, width)
        return x + wide > room.width - Omnibox.margin ? max(Omnibox.margin, field.maxX + gap - wide) : x
    }

    var body: some View {
        // Grown, its head stands on the field's middle and its edge the
        // gap out from the field's: the magnifier and the words stay where
        // the column's were, only larger.
        let y = field.midY - Self.head / 2
        let x = Self.left(field: field, room: room)
        let full = CGRect(x: x, y: y, width: max(field.width, min(Self.width, room.width - x - Omnibox.margin)), height: max(height, Self.head))
        let rect = grown ? full : field
        let shape = RoundedRectangle(cornerRadius: grown ? Radius.floating : Radius.control, style: .continuous)
        content
            .frame(width: full.width, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measured in
                height = measured
                // Grown from the field only once its height is known (grown
                // first, the height came a pass late and jumped), and on the
                // next turn of the loop: a change made while geometry is
                // told is drawn without its animation.
                if up, !grown { DispatchQueue.main.async { if up { grow() } } }
            }
            // Standing as the field, the magnifier where the field's is.
            .offset(x: grown ? 0 : -Self.gap, y: grown ? 0 : (field.height - Self.head) / 2)
            .frame(width: rect.width, height: rect.height, alignment: .topLeading)
            .clipShape(shape)
            .background {
                ZStack {
                    // The field's own ground, giving way to the glass at once.
                    shape.fill(search.fieldGround)
                        .animation(still ? nil : .easeOut(duration: 0.04)) { $0.opacity(grown ? 0 : 1) }
                    FieldGlass(shape: shape, lifted: true)
                        .animation(still ? nil : .easeOut(duration: 0.04)) { $0.opacity(grown ? 1 : 0) }
                }
            }
            .background(ClickZone(away: search.clickZone))
            .offset(x: rect.minX, y: rect.minY)
            .onAppear {
                if still { grown = true; settled = true }
                DispatchQueue.main.async { focus = true }
            }
            .onChange(of: up) { _, up in
                if up { grow(); return }
                settled = false
                guard !still else { return }
                withAnimation(Self.closing) { grown = false } completion: { gone() }
            }
    }

    private func grow() {
        guard !grown else { return }
        if still {
            grown = true
            settled = true
            return
        }
        search.grew += 1
        withAnimation(Self.opening) { grown = true } completion: { if grown { settled = true } }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            // As the column's field: the magnifier, 8, the words.
            HStack(spacing: 8) {
                Symbol("magnifyingglass", size: 14)
                    .foregroundStyle(grown ? Palette.muted : search.fieldInk)
                    .frame(width: 15, height: 15)
                if desk.who == nil { words } else { personWords }
                KeyGlyphs(keys: "esc", size: 12.5, tint: Palette.muted)
                    .animation(still ? nil : .easeOut(duration: 0.08).delay(grown ? 0.08 : 0)) { $0.opacity(grown ? 1 : 0) }
            }
            .padding(.horizontal, 16)
            .frame(height: Self.head)
            if !search.hits.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Rectangle().fill(Omnibox.seam).frame(height: 1)
                    rows
                }
                // Uncovered as it grows, coming up the last few points.
                .animation(still ? nil : grown ? .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.1).delay(0.02) : .easeOut(duration: 0.05)) {
                    $0.opacity(grown ? 1 : 0).offset(y: grown ? 0 : 6)
                }
            }
        }
    }

    /// The field's words with nobody picked. One label grows out of the
    /// column's field into this one, "Search" or the words searched by, and
    /// stays its placeholder: two crossing, the word dimmed halfway and
    /// changed its gray. Once grown, the field shows what is typed.
    private var words: some View {
        // Going back, what the column will say: the words taken, or none.
        let typed = up ? search.typed : desk.query
        return ZStack(alignment: .leading) {
            Group {
                if typed.isEmpty, !InputMethod.composing(focused: focus) {
                    HStack(spacing: 0) {
                        Text("Search")
                        Text(" people, words").opacity(grown ? 1 : 0)
                    }
                    .foregroundStyle(grown ? Palette.muted : search.fieldInk)
                } else {
                    Text(typed).foregroundStyle(Palette.ink)
                }
            }
            .font(.system(size: 15))
            .lineLimit(1)
            .scaleEffect(grown ? 1 : 12.5 / 15, anchor: .leading)
            .opacity(settled && !typed.isEmpty ? 0 : 1)
            .allowsHitTesting(false)
            TextField("", text: $search.typed)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundStyle(Palette.ink)
                .focused($focus)
                .opacity(settled ? 1 : 0)
        }
    }

    /// The field's words with a person picked: their name gives way to
    /// their tag and the field.
    private var personWords: some View {
        ZStack(alignment: .leading) {
            Text(MailSearch.said(desk))
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .scaleEffect(grown ? 1.2 : 1, anchor: .leading)
                .animation(still ? nil : .easeOut(duration: 0.08)) { $0.opacity(grown ? 0 : 1) }
            HStack(spacing: 10) {
                if let who = desk.who { person(who) }
                TextField("Search their mail", text: $search.typed)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.ink)
                    .focused($focus)
            }
            .animation(still ? nil : grown ? .easeOut(duration: 0.1).delay(0.03) : .easeOut(duration: 0.04)) { $0.opacity(grown ? 1 : 0) }
        }
    }

    /// The person the search is narrowed to, as a tag in the field; the
    /// word turns with a click, ⌫ chooses it, again takes it off.
    private func person(_ who: MailDesk.Filter) -> some View {
        HStack(spacing: 6) {
            MailAvatar(initials: MailDesk.initials(who.name.isEmpty ? who.address : who.name), size: 18)
            Button { desk.turnWho(); search.refresh() } label: {
                Text(who.rel).foregroundStyle(Palette.muted)
            }
            .buttonStyle(.plain)
            .keyTip("With, from or to")
            Text(who.name.isEmpty ? who.address : who.name).foregroundStyle(Palette.ink).lineLimit(1)
        }
        .font(.system(size: 13.5))
        .padding(.horizontal, 6)
        .frame(height: 26)
        .background {
            RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                .fill(search.personLit ? Color.accentColor.opacity(0.2) : Palette.wash)
        }
        .fixedSize()
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(search.hits.enumerated()), id: \.element.id) { index, hit in
                if let section = hit.section, index == 0 || search.hits[index - 1].section != section {
                    Text(section)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                        .padding(.horizontal, Self.edge)
                        .padding(.top, 8)
                        .padding(.bottom, 4)
                }
                row(hit, lit: index == search.lit)
                    .contentShape(Rectangle())
                    .onHover { on in
                        if on { search.lit = index; pointed = index } else if pointed == index { pointed = nil }
                    }
                    .onTapGesture { search.take(index) }
            }
        }
        .padding(6)
    }

    @ViewBuilder
    private func row(_ hit: MailSearch.Hit, lit: Bool) -> some View {
        switch hit {
        case .all:
            allMail(lit: lit)
        case .words(let words, let count):
            let said = count == 1 ? "1 thread" : "\(count) threads"
            let title: Text = desk.who.map { who in
                let name = (who.name.isEmpty ? who.address : who.name).components(separatedBy: " ").first ?? who.name
                return words.isEmpty ? Text("All mail \(who.rel) \(name)")
                    : Text("Search \u{201C}\(words)\u{201D} ") + Text("in mail \(who.rel) \(name)").foregroundStyle(Palette.muted)
            } ?? Text("Search \u{201C}\(words)\u{201D}")
            line(lead: AnyView(mark("magnifyingglass")), title: title, detail: nil, end: said, action: said, lit: lit)
        case .recent(let recent):
            let lead = recent.who.map { who in AnyView(MailAvatar(initials: MailDesk.initials(who.name.isEmpty ? who.address : who.name), size: 24)) }
                ?? AnyView(mark("clock.arrow.circlepath"))
            let title: Text = recent.who.map { who in
                Text(who.rel + " ").foregroundStyle(Palette.muted) + Text(who.name.isEmpty ? who.address : who.name)
                    + Text(recent.words.isEmpty ? "" : " · " + recent.words)
            } ?? Text(recent.words)
            line(lead: lead, title: title, detail: nil, end: nil, action: "Search", lit: lit, forget: true)
        case .person(let contact):
            line(lead: AnyView(MailAvatar(initials: contact.initials, size: 24)), title: Text(contact.said),
                 detail: contact.name.isEmpty ? nil : contact.address,
                 end: contact.threads == 1 ? "1 thread" : "\(contact.threads) threads", action: "Their Mail", lit: lit)
        case .thread(let row), .opened(let row):
            thread(row, lit: lit)
        }
    }

    /// A thread as the list draws it, on one line: who, the subject and its
    /// first words, the typed words lit in them, and when; no picture, as
    /// Superhuman's results have none: the words are what is looked for.
    /// Who starts on the rows' one edge, with the headings, the people's
    /// marks and the search's glass; unread's dot hangs in the margin left
    /// of it, as Mail's does, so a read thread leaves no hole.
    private func thread(_ row: MailDesk.Row, lit: Bool) -> some View {
        let words = search.typed
        return HStack(spacing: 12) {
            Text(MailSearch.lit(row.who.isEmpty ? "(nobody)" : row.who, words: words))
                .font(.system(size: 13.5, weight: row.unread ? .semibold : .regular))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .frame(width: 112, alignment: .leading)
            (Text(MailSearch.lit(row.subject, words: words)).foregroundStyle(Palette.ink)
                + Text(row.line.isEmpty ? "" : " · ").foregroundStyle(Palette.muted)
                + Text(MailSearch.lit(row.line, words: words)).foregroundStyle(Palette.muted))
                .font(.system(size: 13.5))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if lit {
                HStack(spacing: 6) {
                    Text("Open")
                    KeyGlyphs(keys: "↩", size: 12.5, tint: nil, rest: 0.6)
                }
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.muted)
                .fixedSize()
            } else {
                HStack(spacing: 6) {
                    if row.gmail { Text(MailCenter.shared.serverName(row.account)).foregroundStyle(Palette.faint) }
                    Text(row.when.isEmpty ? MailPane.said(row.at, waiting: false) : row.when).foregroundStyle(Palette.muted)
                }
                .font(.system(size: 12.5).monospacedDigit())
                .fixedSize()
            }
        }
        .padding(.horizontal, Self.edge)
        .frame(height: Self.row)
        .overlay(alignment: .leading) {
            if row.unread {
                Circle().fill(Color.accentColor).frame(width: 6, height: 6).frame(width: Self.edge)
            }
        }
        .background {
            if lit {
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(Omnibox.chosenFill)
            }
        }
    }

    private func mark(_ symbol: String) -> some View {
        Symbol(symbol, size: 13).foregroundStyle(Palette.muted)
    }

    /// The search asked of Gmail, the whole mailbox: its key, ⇥, said at
    /// its end whether it is lit or not, as it works from anywhere here.
    private func allMail(lit: Bool) -> some View {
        HStack(spacing: 12) {
            mark("envelope").frame(width: 24, height: 24)
            (Text("Search all mail") + Text(" in Gmail").foregroundStyle(Palette.muted))
                .font(.system(size: 13.5))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                if lit { Text("Search") }
                KeyGlyphs(keys: lit ? "↩" : "⇥", size: 12.5, tint: nil, rest: 0.6)
            }
            .font(.system(size: 12.5))
            .foregroundStyle(Palette.muted)
            .fixedSize()
        }
        .padding(.horizontal, Self.edge)
        .frame(height: Self.row)
        .background {
            if lit {
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(Omnibox.chosenFill)
            }
        }
    }

    /// One row: what it is, what it is in words and under them, and at its
    /// end what ↩ does there while it is lit, a count or nothing otherwise.
    private func line(lead: AnyView, title: Text, detail: String?, end: String?, action: String, lit: Bool, forget: Bool = false) -> some View {
        HStack(spacing: 12) {
            lead.frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                title
                    .font(.system(size: 13.5))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if lit {
                HStack(spacing: 12) {
                    if forget {
                        HStack(spacing: 6) {
                            Text("Forget")
                            KeyGlyphs(keys: "⌘⌫", size: 12.5, tint: nil, rest: 0.6)
                        }
                    }
                    HStack(spacing: 6) {
                        Text(action)
                        KeyGlyphs(keys: "↩", size: 12.5, tint: nil, rest: 0.6)
                    }
                }
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.muted)
                .fixedSize()
            } else if let end {
                Text(end)
                    .font(.system(size: 12.5).monospacedDigit())
                    .foregroundStyle(Palette.muted)
                    .fixedSize()
            }
        }
        .padding(.horizontal, Self.edge)
        .frame(height: detail == nil ? Self.row : Self.twoLines)
        .background {
            if lit {
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(Omnibox.chosenFill)
            }
        }
    }
}
