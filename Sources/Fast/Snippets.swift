import AppKit
import CryptoKit
import SwiftUI
import YabStore

// Snippets outside a mail (docs/snippets.md): the same list as Mail's
// (MailSnippets), those that work everywhere.
//
//   ;name  in any box on a page: the snippets by that name hang under the
//          caret, drawn as autofill's lists are (DropFrame); ↩ or ⇥ puts
//          the lit one in over ";" and the name, esc leaves it as typed.
//          Never in a password box, a box for a code, or a code editor
//          (snippets.js), and never a snippet for Mail only.
//   ⌘;     every snippet, in the field's Snippets place (FieldPlaces).
//   a key  a snippet given one types it into the box the caret is in, a
//          mail's words included.
//
// And text pasted again and again: the same words pasted 50 times in a
// week bring a card over the page offering to keep them (SnippetOffers).
// Only a digest of what was pasted is kept, on this Mac.

enum SnippetSettings {
    static let semicolonKey = "snippets.semicolon"
    static let offerKey = "snippets.offer"

    /// ";" and a name in a page's boxes (Settings › Snippets).
    static var semicolon: Bool {
        get { Store.settings.object(forKey: semicolonKey) as? Bool ?? true }
        set { Store.settings.set(newValue, forKey: semicolonKey) }
    }

    /// The card offering to keep what is pasted often.
    static var offers: Bool {
        get { Store.settings.object(forKey: offerKey) as? Bool ?? true }
        set { Store.settings.set(newValue, forKey: offerKey) }
    }
}

extension MailSnippets {
    /// The snippet whose own key this is, if any.
    func withHotkey(_ event: NSEvent) -> MailSnippet? {
        all.first { !$0.hotkey.isEmpty && Hotkey(stored: $0.hotkey)?.heard(in: event) == true }
    }

    /// The snippet that has this key, besides `id`.
    func holding(_ key: Hotkey, besides id: String? = nil) -> MailSnippet? {
        all.first { $0.id != id && Hotkey(stored: $0.hotkey).map { Keymap.keysOverlap($0, key) } == true }
    }

    /// Who a key recorded for a snippet would be taken from, by the
    /// Shortcuts rules: one with no ⌘, ⌃ or ⌥ is refused, as is another
    /// snippet's or a Selection Command's; one the browser has is taken by
    /// pressing it again.
    func clash(_ key: Hotkey, for id: String?) -> Keymap.Clash? {
        if key.flags.intersection([.command, .option, .control]).isEmpty {
            return .refused("A snippet’s shortcut needs ⌘, ⌃ or ⌥ so typing still reaches the page.")
        }
        for browser in BrowserWindows.shared.browsers {
            if let command = browser.selectionCommands.commands.first(where: {
                $0.enabled && Hotkey(stored: $0.shortcut).map { Keymap.keysOverlap($0, key) } == true
            }) {
                return .refused("Already used by \(command.name) in Selection Commands.")
            }
        }
        return Keymap.shared.clash(key, for: nil, snippet: id ?? "")
    }

    /// A name no snippet has yet: this one, or with a number after it.
    func freeName(_ name: String) -> String {
        guard named(name) != nil else { return name }
        var n = 2
        // Joined, not spaced: a name is what follows ";", one word.
        while named("\(name)-\(n)") != nil { n += 1 }
        return "\(name)-\(n)"
    }
}

// MARK: - ";" in a page's box

@MainActor
@Observable final class PageSnippets {
    static let shared = PageSnippets()

    struct Call: Equatable {
        let tab: Tab.ID
        /// Where the caret's line is, in the page's points.
        var spot: CGRect
        var dark: Bool?
        let words: String
        /// Where ";" stands in the box's words: esc puts away its list alone.
        var at = 0
        let rows: [MailSnippet]
        var lit = 0
    }

    private(set) var call: Call?
    /// What the page said last, and why no list came of it: for the bench.
    @ObservationIgnored private(set) var heardLast = ""
    /// The ";" esc put away, by its tab and where it stands: no list for it
    /// again until it is gone.
    @ObservationIgnored private var dismissed: (tab: Tab.ID, at: Int)?

    /// What the page said: ";" and a name at the caret, or nothing now.
    func heard(_ body: [String: Any], in tab: Tab) {
        let owner = BrowserWindows.shared.owner(of: tab.id)?.browser
        heardLast = "on=\(body["on"] as? Bool ?? false) words=\(body["words"] as? String ?? "-") rect=\(body["rect"] != nil) "
            + "switch=\(SnippetSettings.semicolon) owner=\(owner != nil) shows=\(owner.map { Self.shows(tab, in: $0) } ?? false) "
            + "key=\(tab.builtPage?.window?.isKeyWindow ?? false)"
        guard body["on"] as? Bool == true, SnippetSettings.semicolon,
              let rect = body["rect"] as? [String: Double], let x = rect["x"], let y = rect["y"],
              let w = rect["w"], let h = rect["h"],
              let browser = BrowserWindows.shared.owner(of: tab.id)?.browser, Self.shows(tab, in: browser) else {
            if dismissed?.tab == tab.id { dismissed = nil }
            if call?.tab == tab.id { set(nil) }
            return
        }
        let words = body["words"] as? String ?? ""
        let at = body["at"] as? Int ?? 0
        if let dismissed, dismissed.tab == tab.id {
            guard dismissed.at != at else { return }
            self.dismissed = nil
        }
        let rows = Array(MailSnippets.shared.matching(words, pages: true).prefix(5))
        guard !rows.isEmpty else { return set(nil) }
        let zoom = tab.builtPage?.pageZoom ?? 1
        let spot = CGRect(x: x * zoom, y: y * zoom, width: w * zoom, height: h * zoom)
        let lit = call.flatMap { old in old.tab == tab.id ? rows.firstIndex { $0.id == old.rows[min(old.lit, old.rows.count - 1)].id } : nil } ?? 0
        set(Call(tab: tab.id, spot: spot, dark: body["dark"] as? Bool, words: words, at: at, rows: rows, lit: lit))
    }

    /// Whether a list may hang in this tab: the one in front of its window,
    /// a small window's page or a peek, awake. The page said the caret is
    /// there, so its window has the keys, whether or not it is the key
    /// window this moment (a probe behind another app's).
    static func shows(_ tab: Tab, in browser: Browser) -> Bool {
        guard !tab.gone, !tab.asleep, tab.builtPage != nil else { return false }
        if browser.peeking?.id == tab.id { return true }
        if browser.outside.contains(where: { $0.id == tab.id }) { return true }
        return tab.id == browser.activeID && browser.peeking == nil
    }

    /// ↑ or ↓: another lit, round from the last to the first.
    func move(_ by: Int) {
        guard var now = call, !now.rows.isEmpty else { return }
        now.lit = (now.lit + by + now.rows.count) % now.rows.count
        call = now
    }

    func point(_ index: Int) {
        guard var now = call, now.rows.indices.contains(index), now.lit != index else { return }
        now.lit = index
        call = now
    }

    /// ↩, ⇥ or a click: the lit one (or this one) in over ";" and the name.
    func take(_ index: Int? = nil) {
        guard let now = call, let browser = BrowserWindows.shared.owner(of: now.tab)?.browser,
              let tab = browser.tabs.first(where: { $0.id == now.tab }) ?? browser.outside.first(where: { $0.id == now.tab })
                ?? (browser.peeking?.id == now.tab ? browser.peeking : nil) else { return set(nil) }
        let row = now.rows[min(index ?? now.lit, now.rows.count - 1)]
        set(nil)
        put(row, into: tab, replacing: true)
    }

    /// esc: the list away, ";" and the name left as typed.
    func dismiss() {
        if let now = call { dismissed = (now.tab, now.at) }
        set(nil)
    }

    func drop(_ tab: Tab.ID) {
        if call?.tab == tab { set(nil) }
    }

    private func set(_ new: Call?) {
        if new != call { call = new }
    }

    /// A snippet's words into the box the caret is in on the page, over
    /// ";" and its name when `replacing`: {date} and {clipboard} filled.
    func put(_ snippet: MailSnippet, into tab: Tab, replacing: Bool, after delay: TimeInterval = 0) {
        guard let web = tab.builtPage else { return }
        let text = MailSnippets.fillPage(snippet.body, date: Date())
        MailSnippets.shared.used(snippet.id)
        let go = {
            web.window?.makeFirstResponder(web)
            web.call("return window.__yabSnippetPut ? window.__yabSnippetPut(text, replace) : document.execCommand('insertText', false, text)",
                                    arguments: ["text": text, "replace": replacing], in: .yab, frame: nil) { _ in }
        }
        if delay > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: go) } else { go() }
    }

    /// The list's keys, from the page it hangs in: ↑ ↓ ↩ ⇥ esc.
    func key(_ event: NSEvent, browser: Browser) -> Bool {
        guard let now = call, !browser.fieldShowing,
              event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
              let tab = browser.active, tab.id == now.tab || browser.peeking?.id == now.tab,
              let web = (browser.peeking?.id == now.tab ? browser.peeking : tab)?.builtPage, event.window === web.window else { return false }
        switch event.keyCode {
        case 125: move(1)
        case 126: move(-1)
        case 36, 76, 48: take()
        case 53: dismiss()
        default: return false
        }
        return true
    }

    /// A snippet's own key: its words into the box the caret is in, a page's
    /// or a mail's. Nothing when the caret isn't in one.
    func hotkey(_ event: NSEvent, browser: Browser) -> Bool {
        guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty == false,
              let snippet = MailSnippets.shared.withHotkey(event) else { return false }
        if event.window?.firstResponder is MailWordsView {
            MailDesk.shared.insert(snippet)
            return true
        }
        guard !snippet.mailOnly, !browser.fieldShowing, let tab = browser.peeking ?? browser.active, tab.typing,
              tab.caretBox?.password != true, tab.caretBox?.code != true,
              let web = tab.builtPage, (event.window?.firstResponder as? NSView)?.isDescendant(of: web) == true else { return false }
        put(snippet, into: tab, replacing: false)
        return true
    }
}

/// The snippets by the name typed after ";", under the caret in a page's
/// box: the name, what was typed of it bolder, its first words under it.
struct PageSnippetList: View {
    var snippets: PageSnippets
    let call: PageSnippets.Call

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(call.rows.enumerated()), id: \.element.id) { index, snippet in
                FieldListRow(title: snippet.name, detail: snippet.gist, used: nil, lit: call.lit == index,
                             keys: index == call.lit ? "⏎" : nil,
                             point: { snippets.point(index) }, pick: { snippets.take(index) }) {
                    FieldListWell(glyph: "doc")
                }
            }
        }
        .dropFrame(width: max(260, min(360, call.spot.width)))
        .pageScheme(dark: call.dark)
        .offset(x: call.spot.minX, y: call.spot.maxY + 6)
    }
}

// MARK: - pasted again and again

/// Text pasted into a page's boxes, counted by its digest: the same words
/// three times in seven days bring a card offering to keep them as a
/// snippet. Never counted: what a password manager copied, anything in a
/// private tab, pastes into password and code boxes (snippets.js), words
/// under 12 letters, a one-time code. Not Now (or a click beside the card)
/// keeps those words from being offered again for 30 days.
@MainActor
@Observable final class SnippetOffers {
    static let shared = SnippetOffers()

    struct Offer: Equatable, Identifiable {
        let id = UUID()
        let tab: Tab.ID
        let text: String
        let digest: String
        let name: String
        let count: Int
    }

    struct Log: Codable, Equatable {
        /// When each digest was pasted, within the last week.
        var pastes: [String: [Date]] = [:]
        /// Each digest put off, and when.
        var quiet: [String: Date] = [:]
    }

    static let times = 50
    static let within: TimeInterval = 7 * 86_400
    static let quietFor: TimeInterval = 30 * 86_400
    static let shortest = 12

    private(set) var offer: Offer?
    /// The name as written over in the card, for a ↩ from the page.
    @ObservationIgnored var written: String?
    @ObservationIgnored var log: Log
    let file: URL?

    init(file: URL? = Store.file("snippet-pastes.json")) {
        self.file = file
        log = file.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(Log.self, from: $0) } ?? Log()
    }

    nonisolated static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(normal(text).utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Words as they are compared: spaces at the ends and runs of them inside.
    nonisolated static func normal(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
    }

    /// Whether these words may be counted at all.
    nonisolated static func counts(_ text: String) -> Bool {
        let words = normal(text)
        guard words.count >= shortest, words.count <= 4000 else { return false }
        // A code, a key or a password: one long run with no space in it,
        // or digits alone.
        if words.allSatisfy({ $0.isNumber || $0 == " " || $0 == "-" }) { return false }
        if MailCodeWords.code(in: words) != nil, words.count < 40 { return false }
        if !words.contains(where: \.isWhitespace), words.count < 60, !words.contains("."), !words.contains("/") {
            let kinds = [words.contains(where: \.isLowercase), words.contains(where: \.isUppercase), words.contains(where: \.isNumber),
                         words.contains(where: { !$0.isLetter && !$0.isNumber })].filter { $0 }.count
            if kinds >= 3 { return false }
        }
        return true
    }

    /// Words pasted in a page's box.
    func pasted(_ text: String, in tab: Tab, now: Date = Date()) {
        guard SnippetSettings.offers, !tab.shy, Self.counts(text),
              !Clips.concealed((NSPasteboard.general.types ?? []).map(\.rawValue)) else { return }
        guard let count = count(text, now: now) else { return }
        let words = Self.normal(text)
        // Kept already: nothing to offer.
        guard !MailSnippets.shared.all.contains(where: { Self.normal($0.body) == words }) else { return }
        written = nil
        offer = Offer(tab: tab.id, text: words, digest: Self.digest(words), name: MailSnippets.shared.freeName(Self.name(for: words)), count: count)
    }

    /// The paste counted: how many times within the week, when that is
    /// enough to ask and the words aren't put off; nil otherwise.
    func count(_ text: String, now: Date = Date()) -> Int? {
        let key = Self.digest(text)
        log.pastes = log.pastes.compactMapValues { dates in
            let kept = dates.filter { now.timeIntervalSince($0) < Self.within }
            return kept.isEmpty ? nil : kept
        }
        log.quiet = log.quiet.filter { now.timeIntervalSince($0.value) < Self.quietFor }
        log.pastes[key, default: []].append(now)
        write()
        let times = log.pastes[key]?.count ?? 0
        guard times >= Self.times, log.quiet[key] == nil else { return nil }
        return times
    }

    /// Save: kept as a snippet for everywhere under the name the card has
    /// now (written over in it, or the one it came with), its count forgotten.
    func keep(as written: String? = nil) {
        guard let offer else { return }
        let name = Self.command(written ?? self.written ?? offer.name)
        self.written = nil
        MailSnippets.shared.add(name: MailSnippets.shared.freeName(name.isEmpty ? offer.name : name), body: offer.text, mailOnly: false)
        log.pastes[offer.digest] = nil
        write()
        self.offer = nil
    }

    /// Not Now, esc or a click beside the card: not again for 30 days.
    func notNow(now: Date = Date()) {
        guard let offer else { return }
        log.quiet[offer.digest] = now
        log.pastes[offer.digest] = nil
        write()
        self.offer = nil
    }

    func drop(_ tab: Tab.ID) {
        if offer?.tab == tab { offer = nil }
    }

    /// What can follow ";" in a box: letters, digits, "_" and "-", as the
    /// page's script reads a name (snippets.js).
    nonisolated static func command(_ typed: String) -> String {
        String(typed.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }.prefix(40))
    }

    /// A name ready for the words: the site they name (linkedin for a
    /// LinkedIn address), else their first word or two.
    nonisolated static func name(for text: String) -> String {
        if let url = URL(string: text.trimmingCharacters(in: .whitespaces)), let host = url.host(), url.scheme?.hasPrefix("http") == true {
            let parts = host.lowercased().split(separator: ".").filter { $0 != "www" && $0 != "m" }
            if parts.count >= 2 { return String(parts[parts.count - 2]) }
        }
        if text.contains("@"), !text.contains(where: \.isWhitespace) { return "email" }
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).prefix(2)
        let name = words.joined(separator: "-")
        return name.isEmpty ? "snippet" : String(name.prefix(24))
    }

    private func write() {
        guard let file, let data = try? JSONEncoder().encode(log) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    /// The card's keys, from the page: ↩ saves, esc is Not Now.
    func key(_ event: NSEvent, browser: Browser) -> Bool {
        guard let offer, let tab = browser.active, tab.id == offer.tab, !browser.fieldShowing,
              tab.offer == nil, tab.payOffer == nil, !tab.asks.contains(where: { !$0.parked }),
              event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
              [36, 76, 53].contains(event.keyCode),
              let web = tab.builtPage, (event.window?.firstResponder as? NSView)?.isDescendant(of: web) == true else { return false }
        event.keyCode == 53 ? notNow() : keep()
        return true
    }
}

/// "Save as a snippet?" over the page, drawn as the password's card is
/// (KeepCard): the words in a quiet well, how often they were pasted and
/// the name to type next time, Not Now and Save.
struct SnippetOfferCard: View {
    var offers: SnippetOffers
    let offer: SnippetOffers.Offer
    /// The command, ready and written over at will: what follows ";".
    @State private var name: String
    @FocusState private var naming: Bool

    static let width: CGFloat = 400

    init(offers: SnippetOffers, offer: SnippetOffers.Offer) {
        self.offers = offers
        self.offer = offer
        _name = State(initialValue: offer.name)
    }

    /// Why the name can't be kept as written: another snippet has it.
    private var taken: Bool { MailSnippets.shared.named(SnippetOffers.command(name)) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: CardFrame.wellGap) {
                let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                shape.fill(Palette.ink.opacity(0.05))
                    .overlay(shape.strokeBorder(Palette.ink.opacity(0.08), lineWidth: 0.5))
                    .overlay { Symbol("doc", size: 16).foregroundStyle(Palette.ink) }
                    .frame(width: CardFrame.well, height: CardFrame.well)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Save as a snippet?")
                        .font(CardFrame.title)
                        .foregroundStyle(Palette.ink)
                    Text("You pasted this \(offer.count) times this week.")
                        .font(CardFrame.detail)
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text(offer.text)
                .font(.system(size: CardFrame.words))
                .foregroundStyle(Palette.ink)
                .lineLimit(3)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Palette.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .padding(.top, 12)
            command.padding(.top, 8)
            HStack(spacing: 6) {
                Spacer(minLength: 8)
                press("Not Now", .secondary, key: "esc") { offers.notNow() }
                press("Save", .primary, key: "⏎", save)
                    .disabled(taken || SnippetOffers.command(name).isEmpty)
            }
            .padding(.top, CardFrame.buttonGap)
        }
        .frame(width: Self.width - CardFrame.inset * 2, alignment: .leading)
        .cardFrame(glass: true)
    }

    /// "Type ;name next time": the name a field to write over, ↩ in it
    /// saving and esc putting the card away, as the buttons do.
    private var command: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        return HStack(spacing: 8) {
            Text("Type")
                .font(CardFrame.detail)
                .foregroundStyle(Palette.muted)
            HStack(spacing: 0) {
                Text(";")
                    .foregroundStyle(Palette.muted)
                TextField("", text: $name, prompt: Text("name"))
                    .textFieldStyle(.plain)
                    .focused($naming)
                    .onSubmit(save)
                    .onExitCommand { offers.notNow() }
                    .onChange(of: name) { _, now in
                        let clean = SnippetOffers.command(now)
                        if clean != now { name = clean }
                        offers.written = clean
                    }
                    .accessibilityLabel("Snippet name")
            }
            .font(.system(size: 13))
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 8)
            .frame(width: 180, height: 28)
            .background(Palette.ink.opacity(0.04), in: shape)
            .overlay(shape.strokeBorder(naming ? Color.accentColor : Palette.ink.opacity(0.1), lineWidth: naming ? 2 : 1))
            Text(taken ? "Another snippet is called that" : "next time")
                .font(CardFrame.detail)
                .foregroundStyle(taken ? Color(nsColor: .systemOrange) : Palette.muted)
                .lineLimit(1)
        }
    }

    private func save() {
        guard !taken, !SnippetOffers.command(name).isEmpty else { return }
        offers.keep(as: name)
    }

    private func press(_ title: String, _ kind: ButtonKind, key: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            HStack(spacing: 6) {
                Text(title)
                KeyGlyphs(keys: key, size: CardFrame.words, tint: nil, rest: 0.6)
            }
        }
        .buttonStyle(.yab(kind, CardFrame.button))
        .fixedSize()
    }
}

/// The card's place over the page: the page dimmed behind it, a click there
/// is Not Now (AskLayer).
struct SnippetOfferLayer: View {
    var offers = SnippetOffers.shared
    let tab: Tab.ID
    let page: CGRect

    var body: some View {
        if let offer = offers.offer, offer.tab == tab {
            Color.black.opacity(0.12)
                .frame(width: page.width, height: page.height)
                .clipShape(RoundedRectangle(cornerRadius: Backdrop.corner, style: .continuous))
                .contentShape(Rectangle())
                .onTapGesture { offers.notNow() }
                .offset(x: page.minX, y: page.minY)
                .transition(.opacity)
            SnippetOfferCard(offers: offers, offer: offer)
                .position(x: page.midX, y: page.midY)
                .transition(.scale(scale: 0.96).combined(with: .opacity))
                .id(offer.id)
        }
    }
}
