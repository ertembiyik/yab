import AppKit
import SwiftUI

// The Store in the field (docs/store.md): rows for the site behind the field
// first, Yab's picks, plugins and the rest, then two ways to make what is
// missing. A row shows its preview; Return tries it in a tab of its own, and
// only Keep on that tab's card adds it.

extension Browser {
    func storeItems() -> [PlaceItem] {
        let catalog = StoreCatalog.shared
        catalog.fetchIcons()
        let words = typed.lowercased().split(separator: " ").map(String.init)
        let host = active?.address?.host()
        let kept = Set(Boosts.shared.records(in: AddonProfiles.of(self)).filter(\.enabled).map(\.id))
        func row(_ item: StoreCatalog.Item, _ section: String) -> PlaceItem {
            let checked = catalog.checked(item)
            let shared = item.revision.map { "shared-" + $0.prefix(16) }
            let on = kept.contains(item.id) || shared.map(kept.contains) == true || catalog.keptPackage(item.id).map(kept.contains) == true
            return PlaceItem(id: "boost." + item.id, section: section, title: item.name,
                             source: item.host, tile: .site(item.sites.first ?? item.host),
                             search: item.intent + " " + item.sites.joined(separator: " "),
                             tag: on ? "on" : checked == "Needs Fix" ? "needs fix" : nil, alarm: !on && checked == "Needs Fix",
                             what: .boost(item.id))
        }
        var out: [PlaceItem] = []
        // Arc's own boosts, first, while some aren't here (ArcBoosts).
        let arc = ArcBoosts.waitingSoon()
        if ArcBoosts.available, words.isEmpty || words.allSatisfy({ "arc boosts import bring".contains($0) }) {
            let sites = Array(Set(arc.compactMap { $0.sites.first.map { $0 == "<all_urls>" ? "every site" : Browser.site($0) } })).sorted()
            out.append(PlaceItem(id: "store.arc", section: "From Arc", title: "Bring Boosts from Arc",
                                 source: arc.isEmpty ? "Arc" : (arc.count == 1 ? "1 boost" : "\(arc.count) boosts") + " · " + sites.prefix(3).joined(separator: ", "),
                                 tile: .symbol("wand.and.stars"), what: .storeMake("arc")))
        }
        if words.isEmpty {
            let here = catalog.on(host)
            let hereIDs = Set(here.map(\.id))
            if let host, !here.isEmpty { out += here.map { row($0, "For " + StoreCatalog.bare(host)) } }
            let picks = catalog.items.filter { $0.picks == true && !hereIDs.contains($0.id) }
            out += picks.map { row($0, "Yab Picks") }
            let shown = hereIDs.union(picks.map(\.id))
            out += catalog.items.filter { $0.plugin && !shown.contains($0.id) }.map { row($0, "Plugins") }
            out += catalog.items.filter { !$0.plugin && !shown.contains($0.id) }
                .sorted { ($0.kept ?? 0, $1.name) > ($1.kept ?? 0, $0.name) }
                .map { row($0, "More Boosts") }
        } else {
            out += catalog.items.filter { item in
                let text = [item.name, item.host, item.intent, item.sites.joined(separator: " "), item.rung].joined(separator: " ").lowercased()
                return words.allSatisfy { text.contains($0) }
            }.sorted { ($0.kept ?? 0) > ($1.kept ?? 0) }.map { row($0, "Store") }
        }
        let asked = typed.trimmingCharacters(in: .whitespaces)
        out.append(PlaceItem(id: "store.build", section: "Make Your Own", title: "Build It with \(chatName)",
                             source: asked.isEmpty ? "Describe a change" : "“\(asked)”", tile: .symbol("agent.face"), what: .storeMake("build")))
        out.append(PlaceItem(id: "store.ask", section: "Make Your Own", title: "Ask for It",
                             source: asked.isEmpty ? "Others can vote for it" : "“\(asked)”", tile: .symbol("plus"), what: .storeMake("ask")))
        return out
    }

    func storeActions(_ id: String) -> [FieldAction] {
        let catalog = StoreCatalog.shared
        guard let item = catalog.item(id) else { return [] }
        var out = [FieldAction(id: "try", title: "Try on My Page", symbol: "eye") {
            self.close()
            catalog.tryOn(item, in: self)
        }]
        out.append(FieldAction(id: "remix", title: "Remix with \(chatName)", symbol: "sparkles", featured: true, group: 1) {
            self.close()
            catalog.remix(item, in: self)
        })
        out.append(FieldAction(id: "check", title: "Check with \(chatName)", symbol: "yab.shield.check", group: 1) {
            self.close()
            catalog.check(item, in: self)
        })
        if let page = catalog.page(item) {
            out.append(FieldAction(id: "page", title: "Open on the Web", symbol: "yab.globe.right", group: 2, image: NSApp.applicationIconImage) {
                self.close()
                self.open(page, foreground: true)
            })
            out.append(FieldAction(id: "copylink", title: "Copy Link", keys: Keymap.shared.text(.fieldSecond), symbol: "link", group: 2) {
                self.copyPlain(page.absoluteString)
            })
        }
        out.append(FieldAction(id: "change", title: "Ask for a Change…", symbol: "plus", group: 3) {
            self.close()
            self.askStore("Change \(item.name): ", host: item.sites.first)
        })
        out.append(FieldAction(id: "file", title: "Try a Boost File…", symbol: "doc", group: 3) {
            self.close()
            Task {
                do { try await BoostShare.choose(in: self) }
                catch { self.announce(error.localizedDescription, mark: "exclamationmark.triangle") }
            }
        })
        return out
    }

    func storeMakeActions(_ kind: String) -> [FieldAction] {
        let words = typed.trimmingCharacters(in: .whitespaces)
        if kind == "arc" {
            return [FieldAction(id: "arc", title: "Bring from Arc", symbol: "wand.and.stars") {
                self.close()
                ArcBoosts.offer(in: self)
            }]
        }
        if kind == "build" {
            return [FieldAction(id: "build", title: "Build It with \(chatName)", symbol: "agent.face") {
                self.close()
                StoreCatalog.shared.build(words, in: self)
            }]
        }
        return [FieldAction(id: "ask", title: "Ask for It", symbol: "plus") {
            self.close()
            self.askStore(words, host: self.active?.address?.host())
        }]
    }

    /// A request for the Store's board: sent as is when there are words,
    /// otherwise the board opens with the site filled in.
    func askStore(_ words: String, host: String?) {
        let site = host.map(Browser.site) ?? ""
        if words.count >= 4, !words.hasSuffix(": ") {
            Task {
                let sent = await StoreCatalog.shared.ask(words, host: host)
                announce(sent ? "Asked for “\(words)”. You’ll hear when it’s in the Store." : "Couldn’t reach the Store. Try again later.",
                         mark: sent ? "storefront" : "exclamationmark.triangle")
            }
            return
        }
        guard var parts = URLComponents(string: (Updater.site?.absoluteString ?? "https://yetanotherbrowser.com/") + "store/requests") else { return }
        parts.queryItems = [URLQueryItem(name: "title", value: words), URLQueryItem(name: "host", value: site)]
        if let url = parts.url { open(url, foreground: true) }
    }
}

/// A Store row's preview: the page as the boost leaves it, when the Store
/// has its picture, then the name, the intent and what it can do.
struct StoreHead: View {
    let id: String
    let item: PlaceItem
    let meter: Hoard.Meter
    private var catalog = StoreCatalog.shared

    var body: some View {
        if let listing = catalog.item(id) {
            VStack(alignment: .leading, spacing: 12) {
                if let picture = catalog.picture(listing) {
                    Image(nsImage: picture)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity)
                        .frame(height: 170, alignment: .top)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Palette.ink.opacity(0.08), lineWidth: 0.5))
                }
                HStack(spacing: 12) {
                    PlaceTileView(tile: item.tile, meter: meter)
                        .scaleEffect(1.6)
                        .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(listing.name)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Palette.ink)
                            .lineLimit(2)
                        // Code says its rung; the rights below say what it may do.
                        Text(listing.plugin ? listing.host + " · " + listing.rung : listing.host)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Palette.muted)
                            .lineLimit(1)
                    }
                }
                Text(listing.intent)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                // What it can do, in the Keep card's words, whole.
                Text(listing.rights)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @MainActor static func facts(_ id: String) -> [Fact] {
        let catalog = StoreCatalog.shared
        guard let listing = catalog.item(id) else { return [] }
        var out: [Fact] = []
        if let checked = catalog.checked(listing) { out.append(Fact("Checked", checked)) }
        if let kept = catalog.kept(listing) { out.append(Fact("Kept by", kept)) }
        out.append(Fact("Made by", listing.by + (listing.commit.map { " · " + $0 } ?? "")))
        if let reviewed = listing.reviewed { out.append(Fact("Reviewed", [reviewed.by, reviewed.date, reviewed.commit].joined(separator: " · "))) }
        if let latest = listing.versions?.first, let note = latest.note {
            out.append(Fact("Latest", [latest.date, note].compactMap { $0 }.joined(separator: " · ")))
        }
        return out
    }
}

/// The preview of the Store's own last rows.
struct StoreMakeHead: View {
    let kind: String
    let item: PlaceItem
    let meter: Hoard.Meter
    /// Whose plan builds it: the chat's (Browser.chatName).
    let name: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                PlaceTileView(tile: item.tile, meter: meter)
                    .scaleEffect(1.6)
                    .frame(width: 40, height: 40)
                Text(item.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.ink)
            }
            Text(kind == "arc"
                 ? "The boosts you made in Arc, each for its site, on or off as they were there. Yab lists them before bringing them."
                 : kind != "build" ? "Adds a request to the Store’s board, with your vote. When someone makes it, Yab tells you."
                 : Agents.ready ? "\(name) writes the boost, checks it on your page and brings the Keep card. Nothing changes until you keep it."
                 : "Needs Claude or ChatGPT connected on your own plan. It writes the boost, checks it on your page and brings the Keep card.")
                .font(.system(size: 13))
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
