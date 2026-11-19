import SwiftUI

// Sites whose tabs are never put to sleep, Chrome's "Always keep these
// sites active" (Settings › Performance there, Settings › Tabs here).
//
// A tab put down comes back loaded again, which costs most pages a second
// and a chat app the most: WhatsApp Web shows its "Loading your chats" for
// several seconds, Slack and Discord fetch every channel again, a player
// forgets its queue. Those are the tabs people keep open all day and come
// back to after hours (feedback #15, #21, #78), so they come in the list
// from the start, and anyone can add a site or take one off.
//
// A site here is kept awake as a pin is (Sleep.swift): never by the four
// hours, never for memory running short or a page grown heavy, and only
// when memory runs out, after every other tab, does one go.

@MainActor
@Observable final class AwakeSites {
    static let shared = AwakeSites()

    nonisolated static let key = "tabs.awake"

    /// The sites a new install keeps awake: messengers, mail and music,
    /// the pages whose loading again is a wait and a lost place.
    nonisolated static let defaults = [
        "web.whatsapp.com", "web.telegram.org", "app.slack.com", "discord.com", "messenger.com",
        "teams.microsoft.com", "teams.cloud.microsoft", "mail.google.com", "open.spotify.com", "music.youtube.com", "music.apple.com",
    ]

    /// The list as kept: the defaults until it is changed.
    private(set) var sites: [String]

    private init() {
        sites = Store.settings.stringArray(forKey: Self.key) ?? Self.defaults
    }

    /// Whether a page at this address is one of them: the site itself or
    /// any page under it, as "discord.com" takes "ptb.discord.com".
    func keeps(_ url: URL?) -> Bool {
        guard let host = url?.host()?.lowercased() else { return false }
        return Self.match(host, in: sites)
    }

    nonisolated static func match(_ host: String, in sites: [String]) -> Bool {
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return sites.contains { bare == $0 || bare.hasSuffix("." + $0) }
    }

    /// The site to keep for an address or a typed name, as a row shows it:
    /// "web.whatsapp.com", without "www.". Nil for what is no site.
    nonisolated static func site(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        let url = URL(string: trimmed.contains("://") ? trimmed : "https://" + trimmed)
        guard var host = url?.host(), host.contains("."), !host.contains(" ") else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    func add(_ site: String) {
        guard !sites.contains(site) else { return }
        save(sites + [site])
    }

    func remove(_ site: String) {
        save(sites.filter { $0 != site })
    }

    /// The tab's own site, for its menu: kept, or let go again. A site
    /// kept because a wider one is (a subdomain of a site in the list)
    /// is let go by taking that one off.
    func toggle(_ url: URL?) {
        guard let host = url?.host()?.lowercased(), let site = Self.site(from: host) else { return }
        if keeps(url) {
            save(sites.filter { !(site == $0 || site.hasSuffix("." + $0)) })
        } else {
            add(site)
        }
    }

    /// The list as it was (an agent's site.keep_awake undone).
    func restore(_ list: [String]) { save(list) }

    private func save(_ list: [String]) {
        sites = list
        Store.settings.set(list, forKey: Self.key)
    }
}

/// Settings › Tabs, under Close tabs: the sites put to sleep last, in the table look of an extension's Allowed sites, the site's
/// mark and name, a minus on hover and Remove on a right click, Add Site… in the heading.
struct AwakeSiteSettings: View {
    private var awake = AwakeSites.shared
    private var editing = AwakeSiteEditing.shared

    var body: some View {
        Section {
            ForEach(awake.sites, id: \.self) { site in
                AwakeSiteRow(site: site)
            }
            if awake.sites.isEmpty {
                Text("No sites yet").foregroundStyle(.secondary)
            }
        } header: {
            HStack(spacing: 8) {
                Text("Always keep these sites awake")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Add Site…") { editing.open() }
                    .settingsButton()
            }
            .textCase(nil)
            .settingsAnchor("awake-sites")
        } footer: {
            SettingsNote(awake.sites.isEmpty
                ? "Inactive tabs unload when memory is low. Sites added here unload last."
                : "Inactive tabs unload when memory is low. These sites unload last.")
        }
    }
}

/// One kept site: its mark and name, and a minus on a plate at the end
/// (Raycast's way) that shows while the pointer is on the row. It keeps its place when hidden,
/// so the row never shifts (hover moves nothing).
private struct AwakeSiteRow: View {
    let site: String

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) { // design: the same gap as Search's site rows, which this table matches
            HostMark(host: site)
            Text(site).lineLimit(1)
            Spacer(minLength: 4)
            RemoveMinus(label: "Remove \(site)") { AwakeSites.shared.remove(site) }
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .settingsRowHover { hovering = $0 }
        .contextMenu { Button("Remove") { AwakeSites.shared.remove(site) } }
    }
}

/// Add Site…'s card, laid over the whole of the settings as an
/// extension's is (BlockEditing).
@MainActor
@Observable final class AwakeSiteEditing {
    static let shared = AwakeSiteEditing()

    struct Draft: Identifiable {
        let id = UUID()
    }

    private(set) var draft: Draft?

    func open() { draft = Draft() }
    func close() { draft = nil }
}

struct AwakeSiteCardLayer: View {
    private var editing = AwakeSiteEditing.shared

    var body: some View {
        ZStack {
            if let draft = editing.draft {
                AwakeSiteCard { editing.close() }
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

/// The site to keep awake, as the app's own cards ask: a plus in the well,
/// the question, the field washed in ink, the buttons at the foot. Add
/// waits until there is a site not on the list already.
private struct AwakeSiteCard: View {
    let done: () -> Void

    @State private var text = ""
    @FocusState private var typing: Bool

    private var site: String? { AwakeSites.site(from: text) }
    private var already: Bool { site.map { AwakeSites.shared.sites.contains($0) } ?? false }
    private var valid: Bool { site != nil && !already }

    private var line: String {
        let typed = text.trimmingCharacters(in: .whitespaces)
        if already { return "\(site ?? typed) is on the list already." }
        if !typed.isEmpty, site == nil { return "Type a site, like web.whatsapp.com." }
        return "Its tabs, and those of every page under it, stay loaded."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: CardFrame.wellGap) {
                let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                shape.fill(Palette.ink.opacity(0.05))
                    .overlay(shape.strokeBorder(Palette.ink.opacity(0.08), lineWidth: 0.5))
                    .overlay { Symbol("plus", size: 16).foregroundStyle(Palette.ink) }
                    .frame(width: CardFrame.well, height: CardFrame.well)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Always keep a site awake")
                        .font(CardFrame.title)
                        .foregroundStyle(Palette.ink)
                    Text(line)
                        .font(CardFrame.detail)
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .foregroundStyle(Palette.ink)
                .focused($typing)
                .modifier(CardField(hint: "web.whatsapp.com", empty: text.isEmpty, typing: typing))
                .onSubmit(save)
                .padding(.top, 12)
            HStack(spacing: 6) {
                Spacer(minLength: 8)
                // Escape works here as on every card, and says so as theirs do.
                Button(action: done) {
                    HStack(spacing: 6) {
                        Text("Cancel")
                        KeyGlyphs(keys: "esc", size: CardFrame.words, tint: nil, rest: 0.6)
                    }
                }
                .buttonStyle(.yab(.secondary, CardFrame.button))
                .fixedSize()
                Button(action: save) {
                    HStack(spacing: 6) {
                        Text("Add")
                        KeyGlyphs(keys: "↩", size: CardFrame.words, tint: nil, rest: 0.6)
                    }
                }
                .buttonStyle(.yab(.primary, CardFrame.button))
                .fixedSize()
                .disabled(!valid)
                .allowsHitTesting(valid)
            }
            .padding(.top, CardFrame.buttonGap)
        }
        .cardFrame()
        .onExitCommand(perform: done)
        .onAppear { DispatchQueue.main.async { typing = true } }
    }

    private func save() {
        guard valid, let site else { return }
        AwakeSites.shared.add(site)
        done()
    }
}
