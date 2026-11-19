import AppKit
import SwiftUI

/// Settings › Privacy › Filter lists, under the Ad blocker's card: each
/// list by its real name and what it blocks, its rule count, and your own
/// lists with their source and a ··· menu; Add List… checks a list before
/// it is added (row 1108's redesign, variants A and C).
struct ShieldSourceSettings: View {
    private var shield = Shield.shared
    /// The bench opens the card with an optional address, or closes it
    /// (false), for pictures (Bench "shield").
    static let benchAdding = Notification.Name("yab.shield.bench-adding")

    var body: some View {
        Section {
            ForEach(shield.availableSources, id: \.name) { source in
                row(source)
                    .settingsAnchor(source.name == shield.availableSources.first?.name ? "shield-lists" : "shield-list-" + source.name)
            }
            addRow
        } header: {
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text(SettingsWords.text("Filter lists"))
                Spacer()
                Button(SettingsWords.text(shield.refreshing ? "Updating…" : "Update Now")) { shield.refresh(now: true) }
                    .buttonStyle(.yab(.quiet, .small, tint: .accentColor))
                    .disabled(shield.refreshing)
            }
            .textCase(nil)
        } footer: {
            if shield.refreshFailed {
                SettingsNote("Some lists didn’t update. Their previous rules are still active.")
            }
        }
        .onAppear { shield.readFacts() }
        .onReceive(NotificationCenter.default.publisher(for: Self.benchAdding)) { note in
            if note.object as? Bool == false { ShieldSourceEditing.shared.close(); return }
            ShieldSourceEditing.shared.open(url: note.object as? String ?? "")
        }
    }

    // MARK: - a list

    private func row(_ source: ShieldLists.Source) -> some View {
        let facts = shield.facts[source.name]
        let custom = shield.customSources.first { $0.source.name == source.name }
        let name = ShieldListWords.name(source, title: facts?.title)
        return SettingsRow(verbatim: name, detail: ShieldListWords.detail(source)) {
            HStack(spacing: 12) {
                if let rules = facts?.rules, rules > 0 {
                    Text(verbatim: ShieldListWords.count(rules))
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                if let custom {
                    SettingsMoreMenu("More for \(name)", entries: { entries(custom, source: source) }) {
                        Symbol("ellipsis", size: 14)
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 22) // design: Names.dc.html's ··· plate
                            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
                            .contentShape(Rectangle())
                    }
                }
                Toggle(name, isOn: Binding(get: { !shield.disabledSources.contains(source.name) },
                                           set: { shield.setSource(source.name, enabled: $0) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
        }
    }

    private func entries(_ custom: ShieldSubscription, source: ShieldLists.Source) -> [SettingsMenuEntry] {
        [
            .item(SettingsWords.text("Update"), enabled: !shield.refreshing) { shield.refresh(now: true, only: source.name) },
            .item(SettingsWords.text("Copy Address")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(custom.url.absoluteString, forType: .string)
            },
            .destructive(SettingsWords.text("Remove")) { shield.removeSource(custom.id) },
        ]
    }

    private var addRow: some View {
        Button { ShieldSourceEditing.shared.open() } label: {
            HStack(spacing: 12) {
                Symbol("plus.tab", size: 10)
                    .frame(width: 22, height: 22) // design: Names.dc.html's plus circle
                    .background(Color.primary.opacity(0.07), in: Circle())
                Text(SettingsWords.text("Add List…"))
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(shield.customSources.count >= 16)
    }

}

/// Uses the same Settings panel and card frame as Air Traffic Control.
@MainActor
@Observable final class ShieldSourceEditing {
    static let shared = ShieldSourceEditing()

    struct Draft: Identifiable {
        let id = UUID()
        let url: String
    }

    private(set) var draft: Draft?

    func open(url: String = "") { draft = Draft(url: url) }
    func close() { draft = nil }
}

struct ShieldSourceCardLayer: View {
    private var editing = ShieldSourceEditing.shared

    var body: some View {
        ZStack {
            if let draft = editing.draft {
                ShieldSourceCard(url: draft.url) { editing.close() }
                    .frame(width: 440)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.97).combined(with: .opacity).animation(Motion.arrive),
                        removal: .identity
                    ))
                    .id(draft.id)
            }
        }
    }
}

private struct ShieldSourceCard: View {
    let done: () -> Void
    private var shield = Shield.shared
    @State private var url: String
    @State private var check = ShieldAddCheck.idle
    @State private var looking: Task<Void, Never>?
    @FocusState private var typing: Bool

    init(url: String, done: @escaping () -> Void) {
        _url = State(initialValue: url)
        self.done = done
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: CardFrame.wellGap) {
                well
                VStack(alignment: .leading, spacing: 2) {
                    Text(SettingsWords.text("Add List…"))
                        .font(CardFrame.title)
                        .foregroundStyle(Palette.ink)
                    Text(SettingsWords.text("List address"))
                        .font(CardFrame.detail)
                        .foregroundStyle(Palette.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 8) {
                TextField("", text: $url)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Palette.ink)
                    .labelsHidden()
                    .accessibilityLabel(SettingsWords.text("List address"))
                    .modifier(CardField(hint: "https://example.com/filters.txt", empty: url.isEmpty, typing: typing))
                    .autocorrectionDisabled()
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .overlay {
                        if case .bad = check {
                            RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                                .strokeBorder(ButtonCSS.danger, lineWidth: 1)
                        }
                    }
                    .focused($typing)
                    .onSubmit(add)
                switch check {
                case .idle:
                    EmptyView()
                case .checking:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(SettingsWords.text("Checking the list…")).font(.callout).foregroundStyle(.secondary)
                    }
                case .good(let title, let rules, let updated):
                    found(title, line: ShieldListWords.checked(rules: rules, updated: updated))
                case .bad(let words):
                    Text(SettingsWords.text(words))
                        .font(.callout)
                        .foregroundStyle(ButtonCSS.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 12)
            HStack(spacing: 6) {
                Spacer(minLength: 8)
                Button(action: done) {
                    HStack(spacing: 6) {
                        Text(SettingsWords.text("Cancel"))
                        KeyGlyphs(keys: "esc", size: CardFrame.words, tint: nil, rest: 0.6)
                    }
                }
                .buttonStyle(.yab(.secondary, CardFrame.button))
                .fixedSize()
                Button(action: add) {
                    HStack(spacing: 6) {
                        Text(SettingsWords.text("Add"))
                        KeyGlyphs(keys: "↩", size: CardFrame.words, tint: nil, rest: 0.6)
                    }
                }
                .buttonStyle(.yab(.primary, CardFrame.button))
                .fixedSize()
                .disabled(!check.addable)
                .allowsHitTesting(check.addable)
            }
            .padding(.top, CardFrame.buttonGap)
        }
        .cardFrame()
        .onExitCommand(perform: done)
        .onAppear {
            DispatchQueue.main.async { typing = true }
            look(url)
        }
        .onChange(of: url) { _, raw in look(raw) }
        .onDisappear { looking?.cancel() }
    }

    private var well: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        return shape.fill(Palette.ink.opacity(0.05))
            .overlay(shape.strokeBorder(Palette.ink.opacity(0.08), lineWidth: 0.5))
            .overlay { Symbol("plus", size: 16).foregroundStyle(Palette.ink) }
            .frame(width: CardFrame.well, height: CardFrame.well)
    }

    /// The list as it came back: its own title and how many rules.
    private func found(_ title: String, line: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        return HStack(spacing: 10) {
            Symbol("checkmark", size: 9, stroke: 3)
                .foregroundStyle(.white)
                .frame(width: 16, height: 16) // design: Adding.dc.html's check
                .background(Color(nsColor: .systemGreen), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: title).fontWeight(.medium)
                Text(verbatim: line).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(nsColor: .textBackgroundColor), in: shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
    }

    /// Fetched at once, a moment after the last key, as Add will.
    private func look(_ raw: String) {
        looking?.cancel()
        if let early = ShieldAddCheck.before(raw, taken: shield.availableSources.map(\.url)) {
            check = early
            return
        }
        check = .checking
        looking = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let address = ShieldSubscription(raw)?.url else { return }
            let data = await ShieldLists.Download(address, most: ShieldLists.most).data
            let verdict = await Task.detached(priority: .userInitiated) { ShieldAddCheck.after(data, url: address) }.value
            guard !Task.isCancelled else { return }
            check = verdict
        }
    }

    private func add() {
        guard check.addable, shield.addSource(url, facts: check.facts) else { return }
        done()
    }
}

/// What the field says of the address in it: nothing yet, being looked
/// at, a list that checks out, or why it can't be added, in words.
enum ShieldAddCheck: Equatable {
    case idle
    case checking
    case good(title: String, rules: Int, updated: Date?)
    case bad(String)

    var addable: Bool { if case .good = self { return true } else { return false } }

    var facts: ShieldLists.Facts? {
        guard case .good(let title, let rules, let updated) = self else { return nil }
        return .init(rules: rules, title: title, updated: updated)
    }

    static let notHTTPS = "Lists load over HTTPS only. Check the address starts with https://."
    static let notAddress = "That isn’t a web address. Paste the list’s https:// address."
    static let taken = "This list is already in your lists."
    static let unreachable = "Nothing came back from this address. Check it and try again."
    static let notList = "This page isn’t a filter list: it has no rules. Check the address ends in .txt."

    /// What can be said before fetching: nil when it is worth a fetch.
    static func before(_ raw: String, taken urls: [URL], loopback: Bool = ShieldSubscription.loopback) -> ShieldAddCheck? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .idle }
        guard let item = ShieldSubscription(trimmed, loopback: loopback) else {
            let url = URL(string: trimmed)
            return url?.scheme == nil || url?.host()?.isEmpty != false ? .bad(notAddress) : .bad(notHTTPS)
        }
        return urls.contains(item.url) ? .bad(taken) : nil
    }

    /// What came back: a list with rules, or why not.
    static func after(_ data: Data?, url: URL) -> ShieldAddCheck {
        guard let data else { return .bad(unreachable) }
        guard data.count >= 16, ShieldSubscription.accepts(data), let text = String(data: data, encoding: .utf8) else { return .bad(notList) }
        let facts = ShieldLists.facts(text)
        guard facts.rules > 0 else { return .bad(notList) }
        return .good(title: facts.title ?? url.host() ?? url.absoluteString, rules: facts.rules, updated: facts.updated)
    }
}

/// The words a list is shown with: its real name, what it blocks, its count.
enum ShieldListWords {
    static let builtIn: [String: (name: String, detail: String)] = [
        "easylist": ("EasyList", "Ads on most sites"),
        "easyprivacy": ("EasyPrivacy", "Trackers and analytics"),
        "ublock-filters": ("uBlock filters", "Ads EasyList misses, anti-adblock walls"),
        "ublock-badware": ("Malware and scams", "Malicious and fraudulent sites"),
        "ublock-privacy": ("uBlock privacy", "More trackers"),
        "ublock-unbreak": ("Site fixes", "Fixes sites affected by blocking"),
        "ublock-quick-fixes": ("Quick fixes", "Same-day fixes from uBlock"),
        "peter-lowe": ("Peter Lowe’s list", "Ad and tracker servers"),
    ]

    /// A built-in list's name; your own by its "! Title:", else its host.
    static func name(_ source: ShieldLists.Source, title: String?) -> String {
        if let known = builtIn[source.name] { return SettingsWords.text(known.name) }
        return title ?? source.url.host() ?? source.url.absoluteString
    }

    static func detail(_ source: ShieldLists.Source) -> String {
        if let known = builtIn[source.name] { return SettingsWords.text(known.detail) }
        return SettingsWords.format("Your list · %@", [source.url.host() ?? source.url.absoluteString])
    }

    static func count(_ number: Int, locale: Locale = .current) -> String {
        number.formatted(.number.locale(locale))
    }

    /// The Ad blocker row's line: "208,887 rules from 9 lists · updated 12 min ago".
    static func summary(rules: Int, lists: Int, fetched: Date?, now: Date = Date(), locale: Locale = .current) -> String? {
        guard rules > 0 else { return nil }
        var line = "\(count(rules, locale: locale)) \(rules == 1 ? "rule" : "rules") from \(lists) \(lists == 1 ? "list" : "lists")"
        if let fetched { line += " · " + ago(fetched, now: now) }
        return line
    }

    static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "updated just now" }
        if seconds < 3600 { return "updated \(Int(seconds / 60)) min ago" }
        if seconds < 86_400 {
            let hours = Int(seconds / 3600)
            return hours == 1 ? "updated 1 hour ago" : "updated \(hours) hours ago"
        }
        let days = Int(seconds / 86_400)
        return days == 1 ? "updated 1 day ago" : "updated \(days) days ago"
    }

    /// The check's line: "38,069 rules · updated today", the day being the
    /// one the list's own header gives.
    static func checked(rules: Int, updated: Date?, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        var line = "\(count(rules, locale: locale)) \(rules == 1 ? "rule" : "rules")"
        if let updated {
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: updated), to: calendar.startOfDay(for: now)).day ?? 0
            line += " · " + (days <= 0 ? "updated today" : days == 1 ? "updated yesterday" : "updated \(days) days ago")
        }
        return line
    }
}
