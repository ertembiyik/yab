import SwiftUI

/// The accounts kept for a site, hanging from the sign-in box the caret is
/// in, an offer where you are typing, not a question, so it stays at the
/// box rather than coming to the middle. The cards' language: their ground,
/// hairline and corners, a row lit as a wash inset from the edge, and the
/// site's own mark on each account, light or dark as the page is under the
/// box. A click puts
/// both into the form. It follows the box when the page scrolls, and goes
/// when the caret does.
struct AccountList: View {
    var browser: Browser
    let asked: Browser.Suggesting

    /// Rows shown before the list scrolls, the last cut through so it
    /// reads as one that does.
    private static let shown = 6.5
    /// One account row's height (FieldListRow): two lines and its padding.
    private static let rowHeight: CGFloat = 41

    var body: some View {
        let rows = asked.list
        VStack(alignment: .leading, spacing: 0) {
            // Every row, scrolling past a few; the footer rows (another
            // device's passkey, All Passwords) stay under them.
            let upper = rows.filter { !$0.footer }
            if Double(upper.count) > Self.shown {
                ScrollViewReader { reader in
                    ThreadScrollView(.vertical) { list(upper, in: rows) }
                        .scrollIndicators(.automatic)
                        .frame(height: Self.rowHeight * Self.shown)
                        .onChange(of: browser.lit) { _, lit in
                            guard let lit, rows.indices.contains(lit) else { return }
                            reader.scrollTo(rows[lit].id)
                        }
                }
            } else {
                list(upper, in: rows)
            }
            ForEach(Array(rows.enumerated()).filter { $0.element.footer }, id: \.element.id) { at, item in
                // A hairline over another device's passkey, setting the footer apart.
                if case .otherPasskey = item.kind, !upper.isEmpty { FieldListSeparator() }
                row(item, at: at)
            }
            // A page over plain http: one quiet line, not a red band.
            if asked.insecure {
                HStack(spacing: 6) {
                    Symbol("lock.open", size: 10).foregroundStyle(Palette.muted)
                    Text("Not encrypted: others on this network could see it.")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(2)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
        }
        // As wide as the box it hangs from, as every autofill list is.
        .dropFrame(width: max(200, asked.spot.width))
        .pageScheme(dark: asked.dark)
        // Just under the box, left edges lined up. The offset is from the
        // stage's top-left, which is also the web view's.
        .offset(x: asked.spot.minX, y: asked.spot.maxY + 6)
    }

    private func list(_ shown: [SuggestRow], in rows: [SuggestRow]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { order, item in
                // A hairline between sources; another Space's logins under
                // their one heading.
                if item.away != nil, order == 0 || shown[order - 1].away == nil {
                    FieldListHeading(title: "Other Spaces", rule: order > 0)
                } else if order > 0, shown[order - 1].group != item.group {
                    FieldListSeparator()
                }
                row(item, at: rows.firstIndex(of: item) ?? 0).id(item.id)
            }
        }
    }

    private func row(_ item: SuggestRow, at index: Int) -> some View {
        let keys: String? = item.kind == .all ? Keymap.shared.keys(.passwords)?.text : item.quick ? "⏎" : nil
        return FieldListRow(title: item.title, detail: item.detail, used: item.used, lit: browser.lit == index,
                            keys: keys, code: item.shown ?? "", still: !item.pickable,
                            point: { browser.pointChoice(index) }, pick: { if item.pickable { browser.chooseRow(item) } }) {
            picture(item)
        }
        // Another Space's: there to take, quieter until it is the lit one.
        .opacity(item.away != nil && browser.lit != index ? 0.6 : 1)
    }

    @ViewBuilder
    private func picture(_ item: SuggestRow) -> some View {
        switch item.kind {
        case .yab(let login):
            LoginSiteMark(host: login.host, badge: nil)
        case .managed(let login):
            LoginSiteMark(host: item.host.isEmpty ? (login.urls.first.flatMap { URL(string: $0)?.host() } ?? "") : item.host,
                     badge: login.provider)
        case .entry(let entry):
            LoginSiteMark(host: item.host, badge: entry.provider)
        case .locked(let id):
            ManagerMark(id: id)
        case .unlocking:
            FieldListSpinner()
        case .hybrid(let id, let busy):
            if busy { FieldListSpinner() } else { ManagerMark(id: id) }
        case .open(let id):
            if item.glyph != nil { FieldListWell(glyph: item.glyph ?? "") } else { ManagerMark(id: id) }
        case .generate(let id, _):
            if let id { ManagerMark(id: id) } else { FieldListWell(glyph: "key") }
        case .nothing, .all:
            FieldListWell(glyph: "key")
        case .email:
            FieldListWell(glyph: "envelope")
        case .passkey:
            // The site's own mark: the page's icon on a passkey.
            LoginSiteMark(host: item.host, badge: nil)
        case .otherPasskey:
            // The device icon.
            FieldListWell(glyph: item.glyph ?? "iphone")
        }
    }
}

/// A site's mark in a row, with the manager it came from cut into its
/// corner (KeepCard's notch): 20 pt, the badge 11.
struct LoginSiteMark: View {
    let host: String
    let badge: String?

    var body: some View {
        let site = Browser.site(host)
        Mark(icon: Favicons.shared.cached(host) ?? Favicons.shared.cached(site),
             letter: site.first.map { String($0).uppercased() } ?? "•", size: 20)
            .notched(badge != nil, side: 11, radius: 2.5, offset: 4)
            .overlay(alignment: .bottomTrailing) {
                if let badge {
                    Mark(icon: PasswordManagers.icon(badge), letter: String(PasswordManagers.name(badge).prefix(1)), size: 11)
                        .offset(x: 4, y: 4)
                }
            }
    }
}

/// A manager's own icon, whole, 20 pt.
struct ManagerMark: View {
    let id: String

    var body: some View {
        Mark(icon: PasswordManagers.icon(id), letter: String(PasswordManagers.name(id).prefix(1)), size: 20)
    }
}

/// The well, spinning: something comes in here.
struct FieldListSpinner: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
        shape.fill(Palette.ink.opacity(0.05))
            .overlay(shape.strokeBorder(Palette.ink.opacity(0.08), lineWidth: 0.5))
            .overlay { ProgressView().controlSize(.mini).scaleEffect(0.8) }
            .frame(width: 20, height: 20)
    }
}

/// A heading over a part of a list, another Space's logins: quiet small
/// words, the hairline over them when rows come before.
struct FieldListHeading: View {
    let title: String
    var rule = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if rule { FieldListSeparator() }
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.top, 4)
                .padding(.bottom, 2)
        }
    }
}

/// The hairline between a list's sources.
struct FieldListSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Palette.ink.opacity(0.07))
            .frame(height: 1)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
    }
}

/// Yab's plate in the sign-in box: the key on a quiet well, a manager's
/// icon at its corner when the list is that manager's alone. A click
/// brings the list back.
struct FieldPlateView: View {
    var browser: Browser
    let plate: FieldPlate

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
        Button { browser.pressPlate(plate.tab) } label: {
            shape.fill(Palette.ink.opacity(0.05))
                .background(shape.fill(Palette.ground)) // design: the well's own plate inside the page's box, opaque over its text
                .overlay(shape.strokeBorder(Palette.ink.opacity(0.12), lineWidth: 0.5))
                .overlay { Symbol("key", size: 11).foregroundStyle(Palette.ink) }
                .frame(width: 20, height: 20)
                .notched(plate.badge != nil, side: 11, radius: 2.5, offset: 4)
                .overlay(alignment: .bottomTrailing) {
                    if let badge = plate.badge {
                        Mark(icon: PasswordManagers.icon(badge), letter: String(PasswordManagers.name(badge).prefix(1)), size: 11)
                            .offset(x: 4, y: 4)
                    }
                }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .pointerTip("Passwords")
        .pageScheme(dark: plate.dark)
        .offset(x: plate.frame.minX, y: plate.frame.minY)
    }
}

/// An agent filling a sign-in from a manager: its face, typing, and who
/// from where. Never the password.
struct AgentFillingList: View {
    var browser: Browser
    let tab: Tab
    let filling: AgentFilling

    var body: some View {
        FieldListRow(title: filling.title, detail: filling.detail, used: nil, lit: false, still: true, pick: {}) {
            AgentFace(tab: tab, size: 20, tip: false)
        }
        .dropFrame(width: max(200, filling.spot.width))
        .pageScheme(dark: filling.dark)
        .offset(x: filling.spot.minX, y: filling.spot.maxY + 6)
    }
}

/// The codes a site just sent, hanging from the box that asks for one the
/// way the accounts hang from a sign-in (MailCodes.swift): the code, who it
/// came from and how, and when. Return puts the lit one in.
struct CodeList: View {
    var browser: Browser
    let list: Browser.CodeChoices
    static let messages = NSWorkspace.shared.icon(forFile: "/System/Applications/Messages.app")

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(list.codes.enumerated()), id: \.element.id) { index, code in
                // Passwords' code that waits for Touch ID says what it is.
                FieldListRow(title: code.code.isEmpty ? "Verification Code" : MailCodes.spaced(code.code),
                             detail: detail(code), used: code.at,
                             lit: browser.codeLit == index, point: { browser.pointCode(index) }, pick: { browser.pickCode(code) }) {
                    picture(code)
                }
            }
            if let account = list.appleAccount {
                FieldListRow(title: "Open Apple Passwords", detail: account, used: nil,
                             lit: browser.codeLit == list.codes.count,
                             point: { browser.pointCode(list.codes.count) }, pick: { browser.openAppleCode() }) {
                    FieldListWell(glyph: "key")
                }
            }
            // Texted codes, while Messages can't be read: Messages is its
            // picture, what it opens to Yab (MailCodes.TextsRow).
            if list.texts {
                let at = list.count - 1
                FieldListRow(title: "Fill Codes from Texts", detail: "Full Disk Access, in System Settings", used: nil,
                             lit: browser.codeLit == at, point: { browser.pointCode(at) }, pick: { browser.allowTextCodes() }) {
                    Mark(icon: CodeList.messages, letter: "M", size: 20)
                }
            }
        }
        .dropFrame(width: max(260, min(360, list.spot.width)))
        .pageScheme(dark: list.dark)
        .offset(x: list.spot.minX, y: list.spot.maxY + 6)
    }

    private func detail(_ code: SentCode) -> String {
        switch code.source {
        case .mail: return "\(code.from), from mail"
        case .text: return "\(code.from), from a text"
        case .key: return code.from.isEmpty ? "Two-factor code" : "\(code.from), two-factor code"
        case .apple: return code.from.isEmpty ? "Apple Passwords" : "\(code.from), Apple Passwords"
        }
    }

    @ViewBuilder
    private func picture(_ code: SentCode) -> some View {
        if code.source == .apple {
            LoginSiteMark(host: list.site, badge: PasswordManagers.apple)
        } else if code.mine {
            let site = Browser.site(list.site)
            Mark(icon: Favicons.shared.cached(list.site) ?? Favicons.shared.cached(site),
                 letter: site.first.map { String($0).uppercased() } ?? "•", size: 20)
        } else {
            FieldListWell(glyph: code.source == .text ? "message.fill" : "envelope.fill")
        }
    }
}

/// One row of a list dropping from a box (AccountList, WalletList): what it
/// is, a line under it, and when it was last used, so the likely one reads.
struct FieldListRow<Picture: View>: View {
    let title: String
    let detail: String
    let used: Date?
    let lit: Bool
    /// The line under it says something to mind, a card running out.
    var warn = false
    /// The key that takes it from anywhere in the form, "⌥↩", where the
    /// others say when they were used.
    var keys: String? = nil
    /// Said after the title and never cut, an address's "Apt 1210"; a
    /// title with one is cut at its end, so a house number stays.
    var unit = ""
    /// Said first in the line under the title, as it is, monospaced: a
    /// password made here, so what goes in is seen.
    var code = ""
    /// Says something, takes nothing: no wash under the pointer.
    var still = false
    /// The pointer came onto the row: it becomes the lit one, so only one
    /// row is ever lit and Return takes what it shows.
    var point: (() -> Void)? = nil
    let pick: () -> Void
    @ViewBuilder let picture: () -> Picture
    @State private var hovering = false
    /// Where the pointer was as the row came up: a list that rises under a
    /// pointer standing still hasn't been pointed at, as a menu hasn't.
    @State private var stood = NSEvent.mouseLocation

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        Button(action: pick) {
            HStack(spacing: 8) {
                picture()
                // Two lines tall with one line of words too, so All Cards
                // stands as tall as the cards over it.
                ZStack(alignment: .leading) {
                    VStack(spacing: 1) {
                        Text(" ").font(.system(size: 12.5))
                        Text(" ").font(.system(size: 11))
                    }
                    .hidden()
                    lines
                }
                Spacer(minLength: 8)
                if let keys {
                    KeyGlyphs(keys: keys, size: 11, tint: nil, rest: 0.6)
                        .transaction { $0.animation = nil }
                } else if let used {
                    // The muted gray of the line under the name: the faint
                    // one was all but gone on a light page, and on a lit row.
                    Text(Self.ago(used))
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            // The field's chosen row, ink over the ground: the gray a sidebar
            // row lights with is lost on a white list.
            .background(shape.fill(!still && (lit || (point == nil && hovering)) ? Omnibox.chosenFill : .clear))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { on in
            hovering = on
            if on, !still, NSEvent.mouseLocation != stood { point?() }
        }
    }

    private var lines: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(title)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    // A name or an address cut in the middle keeps its
                    // ends; words ("Fill with 1Password") lose their tail,
                    // never their middle.
                    .truncationMode(unit.isEmpty && !title.contains(" ") ? .middle : .tail)
                if !unit.isEmpty {
                    Text(unit)
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .font(.system(size: 12.5))
            if !detail.isEmpty || !code.isEmpty {
                (Text(code).font(.system(size: 11, design: .monospaced)) + Text(detail).font(.system(size: 11)))
                    .foregroundStyle(warn ? Color(nsColor: .systemOrange) : Palette.muted)
                    .lineLimit(1)
            }
        }
    }
}

extension FieldListRow {
    /// "now", "12 min", "3 wk": when it was used, in words short enough to
    /// leave the row's width to what tells the rows apart.
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        let day = 86_400.0
        switch seconds {
        case ..<90: return "now"
        case ..<3600: return "\(Int((seconds / 60).rounded())) min"
        case ..<day: return "\(Int((seconds / 3600).rounded())) h"
        case ..<(7 * day): return "\(Int((seconds / day).rounded())) d"
        case ..<(30 * day): return "\(Int((seconds / (7 * day)).rounded())) wk"
        case ..<(365 * day): return "\(max(1, Int((seconds / (30 * day)).rounded()))) mo"
        default: return "\(Int((seconds / (365 * day)).rounded())) yr"
        }
    }
}

/// A row's glyph in a quiet well, for what isn't one kept thing: All
/// Passwords, All Cards, Fill the form.
struct FieldListWell: View {
    let glyph: String

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
        shape.fill(Palette.ink.opacity(0.05))
            .overlay(shape.strokeBorder(Palette.ink.opacity(0.08), lineWidth: 0.5))
            .overlay { Symbol(glyph, size: 10).foregroundStyle(Palette.ink) }
            .frame(width: 20, height: 20)
    }
}
