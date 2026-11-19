import SwiftUI

// A pin and a kept tab remember where they were pinned or kept, as Arc's
// pinned tabs and Favorites remember their pinned URL. Gone on from there,
// the kept tab's row says so the way Arc's does, a slash between its mark
// and the page's title (or the name you gave it, kept), and a click on the
// square round the mark takes it back. Its menu has Back to and Replace …
// Address with Current (Arc's "Back to Pinned URL" and "Replace Pinned URL
// with Current"), and ⌘W or the
// minus put it down back home, as Arc's Close and Keep Pinned does: "Pinned
// Tabs and Favorites always revert back to the original link".
//
// The address is the tab's `home`, set the moment it becomes a pin or a
// kept tab and forgotten when it is neither. It is written in the session
// and synced (`home`, `homeTitle`); a session or a record written before
// there was one takes the address the tab is at.

extension Tab {
    /// A pin or a kept tab without a home takes the address it is at; one
    /// that is neither has none.
    func settleHome() {
        if pin != nil || kept {
            guard home == nil, let here = pending ?? address else { return }
            home = here
            homeTitle = title.isEmpty ? nil : title
        } else if home != nil {
            home = nil
            homeTitle = nil
        }
    }

    /// The home a session or another device wrote for it. None written (a
    /// file or a record from before there was one, or an older copy's),
    /// it keeps the one it has, or the address it is at.
    func takeHome(_ entry: Session.Entry) {
        guard pin != nil || kept, let written = entry.home.flatMap(URL.init(string:)) else { return }
        if home != written { home = written }
        homeTitle = entry.homeTitle
    }

    /// Gone on from its home: the row shows the slash, Back to is offered.
    /// Never the mail pin, a door to mail's own space, not a page.
    var awayFromHome: Bool {
        guard pin != nil || kept, let home, let here = pending ?? address, !MailPage.isMail(home) else { return false }
        return !Tab.sameHome(home, here)
    }

    /// One address as another for a home: http or https, with or without
    /// "www.", a path's last slash or not. The query and the fragment
    /// count, a mail opened in Gmail's being one (#inbox/…), but an empty
    /// fragment doesn't.
    nonisolated static func sameHome(_ a: URL, _ b: URL) -> Bool {
        homeKey(a) == homeKey(b)
    }

    nonisolated static func homeKey(_ url: URL) -> String {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), let host = parts.host?.lowercased() else {
            return url.absoluteString
        }
        let scheme = parts.scheme?.lowercased() == "http" ? "https" : (parts.scheme?.lowercased() ?? "")
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        var path = parts.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        var key = scheme + "://" + bare + (parts.port.map { ":\($0)" } ?? "") + path
        if let query = parts.percentEncodedQuery, !query.isEmpty { key += "?" + query }
        if let fragment = parts.percentEncodedFragment, !fragment.isEmpty { key += "#" + fragment }
        return key
    }

    /// The home as words: its page's title when known, its address else,
    /// cut short for a menu line or a tip.
    var homeName: String {
        let whole = homeTitle.flatMap { $0.isEmpty ? nil : $0 } ?? home.map(Tab.homeHost) ?? ""
        return Tab.short(whole)
    }

    /// A home's site, until its page has told its title: the host less
    /// "www.", or the address for one with none.
    nonisolated static func homeHost(_ url: URL) -> String {
        guard let host = url.host(), !host.isEmpty else { return url.absoluteString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// What Edit… takes as a home, read as the address field reads what is
    /// typed (Address.url): a scheme put in front of a bare host, a local
    /// one's http, never a search's words. Only a web page is a home, as
    /// only one is written down (Browser.sessionEntry).
    nonisolated static func homeAddress(from typed: String) -> URL? {
        guard let url = Address.url(from: typed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host()?.isEmpty == false else { return nil }
        return url
    }

    /// The page's title, once it has one at home, for a home whose title
    /// isn't known yet (one typed into Edit…).
    func learnHomeTitle() {
        guard home != nil, homeTitle == nil, !title.isEmpty, pin != nil || kept, !awayFromHome else { return }
        homeTitle = title
    }

    nonisolated static func short(_ text: String, most: Int = 32) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > most else { return trimmed }
        return String(trimmed.prefix(most - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The row's words away from home: a name you gave it, which stays
    /// whatever page it goes on to, as a renamed tab does in Arc (feedback
    /// #105); else the page it is on, not its short name, as Arc's row
    /// shows the page after the slash.
    var awayLabel: String {
        if let name { return name }
        if !title.isEmpty { return title }
        if let here = pending ?? address { return Address.pretty(here) }
        return label
    }
}

extension Browser {
    /// Back to Pinned URL: the tab at its home, and in front.
    func goHome(_ tab: Tab) {
        guard tab.pin != nil || tab.kept else { return }
        // Returning home ends this tab's link preview, even if its own
        // page is already home underneath it. Other tabs keep their peeks.
        dropPeek(of: tab)
        guard tab.awayFromHome else { return }
        glance.drop()
        tab.sendHome()
        if tab.id != activeID { select(tab) }
        writeSession(now: true)
    }

    /// Edit…: the tab's own field (TabAddressField), with its home in it,
    /// picked, to be typed or pasted over; Return keeps it (commitTabEdit),
    /// Escape or a click elsewhere leaves the home as it was.
    func beginHomeEdit(_ tab: Tab) {
        guard tab.pin != nil || tab.kept, let home = tab.home ?? tab.pending ?? tab.address else { return }
        glance.drop()
        if editingPin != nil { endPinEdit() }
        beginTabEdit(tab, home: home.absoluteString)
    }

    /// Return in Edit…'s field. Nothing typed leaves the home as it was;
    /// words that are no address are refused, the field shaking and
    /// staying. A new home goes without a title until its page has told
    /// it (the site's name in the menu till then); a tab at its home goes
    /// to the new one.
    @discardableResult
    func setHome(_ tab: Tab, typed: String) -> Bool {
        guard tab.pin != nil || tab.kept else { return false }
        guard let url = Tab.homeAddress(from: typed) else { return false }
        let here = tab.pending ?? tab.address
        let atHome = !tab.awayFromHome
        if tab.home != url {
            tab.home = url
            tab.homeTitle = here.map { Tab.sameHome($0, url) } == true && !tab.title.isEmpty ? tab.title : nil
        }
        if atHome, here.map({ !Tab.sameHome($0, url) }) ?? true { tab.sendHome() }
        writeSession(now: true)
        return true
    }

    /// Replace Pinned URL with Current: the page it is on becomes its home.
    func makeHome(_ tab: Tab) {
        guard tab.pin != nil || tab.kept, let here = tab.pending ?? tab.address else { return }
        tab.home = here
        tab.homeTitle = tab.title.isEmpty ? nil : tab.title
        writeSession(now: true)
    }
}

/// A pin's or a kept tab's menu line for its home, when it has gone on
/// from it: back there, first in the menu.
struct HomeItems: View {
    let browser: Browser
    var tab: Tab

    var body: some View {
        if tab.awayFromHome {
            Button("Back to \(tab.homeName)", mark: "yab.tab.undo") { browser.goHome(tab) }
        }
    }
}

/// Arc's "Edit Pinned Page": this page as its home (when it is on another),
/// or Edit… to type one, for every pin and kept tab.
struct HomeEditItems: View {
    let browser: Browser
    var tab: Tab

    var body: some View {
        if tab.pin != nil || tab.kept {
            Menu(tab.pin != nil ? "Edit Pinned Page" : "Edit Kept Page", mark: "yab.page.pen") {
                Button(tab.pin != nil ? "Replace Pinned Address with Current" : "Replace Kept Address with Current", mark: "yab.home.plus") { browser.makeHome(tab) }
                    .disabled(!tab.awayFromHome)
                Button("Edit…", mark: "pencil") {
                    browser.beginHomeEdit(tab)
                }
            }
        }
    }
}

/// The slash between a kept tab's mark and the page it has gone on to, as
/// Arc draws it, in the row's fainter ink. Only words: the way back is the
/// mark's square (HomeMark), which the slash goes from while the pointer
/// is on it, as Arc's does (feedback #213).
struct HomeSlash: View {
    let tab: Tab
    let size: CGFloat
    let tint: Color

    private var hover = HomeHover.shared

    var body: some View {
        Text("/")
            .font(.system(size: size))
            .foregroundStyle(tint)
            .opacity(hover.tab == tab.id ? 0 : 1)
    }
}

/// Which kept tab's way home the pointer is on, for its slash to go.
@MainActor
@Observable final class HomeHover {
    static let shared = HomeHover()
    var tab: UUID?
}

/// A kept tab away from home: its mark is the way back, as Arc's pinned
/// tab's favicon is, in a square the tab's height at its left end. The
/// pointer on it brings the square up and the tip naming where it goes, a
/// press on it goes home (measured on Arc, evals/kept-home, feedback
/// #213). Put on the whole row or tab, so the square is within it and
/// nothing moves for it.
struct HomeMark: ViewModifier {
    let browser: Browser
    var tab: Tab
    let away: Bool
    /// A tab's across the top, or a row's in the column.
    let plate: RowPlate

    @State private var hovering = false

    func body(content: Content) -> some View {
        // The same content either way, so the row keeps its state when
        // the tab goes home or away.
        content
            .background(alignment: .leading) {
                if away && hovering { plate.edge() }
            }
            .overlay(alignment: .leading) {
                if away {
                    Color.clear
                        .frame(width: plate.ground, height: plate.ground)
                        .contentShape(Rectangle())
                        .onTapGesture { browser.goHome(tab) }
                        .onHover { hover($0) }
                        .keyTip("Back to \(tab.homeName)")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityLabel("Back to \(tab.homeName)")
                        .onDisappear { hover(false) }
                }
            }
    }

    private func hover(_ on: Bool) {
        guard on != hovering else { return }
        hovering = on
        if on { HomeHover.shared.tab = tab.id } else if HomeHover.shared.tab == tab.id { HomeHover.shared.tab = nil }
    }
}

/// Edit… on a pin in the column: its row of the grid becomes a field, the
/// pin's mark and the tab's own field (TabAddressField), the home in it,
/// picked. The open row's gray on a ground of the column's color, so the
/// pins under it don't show through. It shakes at words that are no
/// address.
struct PinHomeField: View {
    var browser: Browser
    var tab: Tab
    /// The grid's cell height: the row it covers, exactly.
    let height: CGFloat

    @Environment(\.tabTitleSize) private var titleSize
    @Environment(\.tone) private var tone
    @State private var shake: CGFloat = 0

    var body: some View {
        HStack(spacing: 8) {
            Mark(icon: tab.displayIcon, letter: tab.monogram, size: 15)
            TabAddressField(browser: browser, tab: tab.id)
                .frame(height: titleSize + 4)
        }
        .padding(.leading, SideBar.inner)
        .padding(.trailing, 10) // design: as a row being named, room for the caret
        .frame(height: height)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: SideBar.corner(height), style: .continuous)
                .fill(Palette.wash(on: tone))
        }
        .background {
            GroundFill(shape: RoundedRectangle(cornerRadius: SideBar.corner(height), style: .continuous), browser: browser)
        }
        .modifier(Shake(travel: shake))
        .onChange(of: browser.refusals) { _, _ in
            shake = 0
            withAnimation(.easeOut(duration: 0.5)) { shake = 1 }
        }
    }
}
