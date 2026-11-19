import AppKit
import SwiftUI

// Writing in a place, where the pages used to: your profile, a card, an
// address, a login's one-time code, a bookmark's name and address, a folder. Nothing opens for it. The chosen row's
// Information becomes fields where its values stood (EditLines), one keys
// grammar for all of them:
//
//   ⌘E  edit the chosen row        ⌘N  a new card
//   ↩   save                       esc cancel, the row as it was
//   ⇥   the next field             ⇧⇥  the one before
//
// A value that can't be kept says why under its own field, and the fields
// stay. What was written goes where the page wrote it (Profile, Wallet,
// OneTime), and a profile key you wrote is yours: nothing an agent or your
// card finds later goes over it (Profile.merge).
//
// And bringing more in, with a list already there: ⌘K's Bring In More…
// puts the place's ways in (the browsers on this Mac, Safari's export, a
// CSV, your card in Contacts) where its list was, until one is taken or
// Escape. Safari's export is waited for there, step by step, as the pages
// had it (SafariImport.Desk).

/// A row being written.
struct PlaceEdit: Equatable {
    enum Kind: Equatable {
        case profile
        /// A saved Yab login, edited in the preview with owner proof at Save.
        case login(PasswordEditController)
        /// A card, or a new one.
        case card(String?)
        case address(String?)
        /// The setup key of a login's one-time codes.
        case code(host: String, user: String)
        /// A bookmark's name and address, or a folder's name.
        case bookmark(Bookmark.ID)
        /// A new folder, in this one or at the top.
        case folder(in: Bookmark.ID?)
        /// A snippet's name and words, or a new one (Snippets.swift).
        case snippet(String?)
    }

    struct Line: Equatable {
        let key: String
        let label: String
        var value: String
        /// What the empty field says: what goes in it.
        var hint = ""
        /// Words in lines, ⌥↩ starting another: a snippet's.
        var lines = false
        /// Set in a fixed width: a setup key's.
        var mono = false
        /// What Yab found for it, pale where the hint stands until Tab
        /// takes it: the key from the QR code on the page.
        var ghost = ""
    }

    var passwordEditor: PasswordEditController? {
        if case .login(let editor) = kind { return editor }
        return nil
    }

    var kind: Kind
    /// Said at the field's end, and on the new row: "New Card".
    var title: String
    var lines: [Line]
    /// The field with the caret.
    var focus = 0
    /// The field that can't be kept as it is, and why.
    var wrong: Int?
    var why = ""
    /// The tab whose box for the first code Save fills: a one-time code
    /// added on the page that set it up.
    var fillTab: Tab.ID?

    /// Written where its value stands among the preview's lines, the rest
    /// of them kept: a login's one-time code.
    var inPlace: Bool {
        if case .code = kind { return true }
        return false
    }

    var new: Bool {
        switch kind {
        case .card(nil), .address(nil), .folder, .snippet(nil): return true
        default: return false
        }
    }

    func value(_ key: String) -> String {
        lines.first { $0.key == key }?.value.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

/// Where Bring In More… has got with Safari's export.
enum SafariStep: Equatable {
    case waiting
    case done(line: String, file: String, folder: String)
    case failed(String)
}

/// Something bringing in couldn't do, said where the list was, with the way
/// to try again.
struct PlaceTrouble {
    let title: String
    let detail: String
    var retry: FieldAction?
}

extension Browser {
    /// The profile's keys as the fields show them, with what goes in each.
    static let profileLines: [(key: String, label: String, hint: String)] = [
        ("name", "Name", "Your full name"), ("headline", "Headline", "The line under your name"),
        ("company", "Company", "Where you work"), ("role", "Title", "Founder, Designer"),
        ("location", "Location", "City, Country"), ("linkedin", "LinkedIn", "linkedin.com/in/you"),
        ("x", "X", "@handle"), ("github", "GitHub", "Your user name"), ("website", "Website", "yoursite.com"),
        ("telegram", "Telegram", "@handle"), ("instagram", "Instagram", "@handle"),
        ("bio", "Bio", "A sentence about you"), ("about", "About", "A paragraph, for a box that wants more"),
        ("working", "Working on", "What you are building now"), ("languages", "Languages", "English, Swedish"),
        ("timezone", "Time zone", "Europe/Stockholm"), ("pronouns", "Pronouns", "Only as you want them in forms"),
    ]

    /// Where a profile key came from, as its line says it.
    static func profileSource(_ raw: String) -> String {
        switch raw.lowercased() {
        case "": return ""
        case "you": return "By you"
        case "contact card": return "Contact card"
        case "linkedin": return "LinkedIn"
        case "github": return "GitHub"
        case "x", "twitter": return "X"
        default: return raw.prefix(1).uppercased() + raw.dropFirst()
        }
    }

    /// Getting to know you, while it is under way.
    var knowingSession: Agents.Session? {
        Agents.shared.sessions.first { $0.knowing && $0.state.live }
    }

    // MARK: editing

    /// ⌘E on a row, ⌘N for a new card, Add a Code…: the preview's lines
    /// become fields.
    func beginEdit(_ kind: PlaceEdit.Kind) {
        query.acting = nil
        query.revealed = nil
        var edit: PlaceEdit
        switch kind {
        case .login:
            edit = PlaceEdit(kind: kind, title: "Edit Login", lines: [])
        case .profile:
            let profile = query.stock.profile
            edit = PlaceEdit(kind: kind, title: "Your Profile",
                             lines: Browser.profileLines.map { PlaceEdit.Line(key: $0.key, label: $0.label, value: profile[$0.key], hint: $0.hint) })
        case .card(let id):
            let card = id.flatMap { id in query.stock.cards.first { $0.id == id } }
            edit = PlaceEdit(kind: kind, title: card?.title ?? "New Card", lines: [
                PlaceEdit.Line(key: "number", label: "Number", value: "", hint: card.map { "Empty keeps •••• \($0.last4)" } ?? "As on the card’s front"),
                PlaceEdit.Line(key: "name", label: "Name on card", value: card?.name ?? "", hint: "As on the card"),
                PlaceEdit.Line(key: "expires", label: "Expires", value: card?.expiry ?? "", hint: "MM/YY"),
                PlaceEdit.Line(key: "csc", label: "Security code", value: "",
                               hint: card?.keepsCode == true ? "Empty keeps the one kept" : "Only if you want it kept"),
                PlaceEdit.Line(key: "nickname", label: "Nickname", value: card?.nickname ?? "", hint: "Work card"),
            ])
            if card != nil { edit.focus = 1 }
        case .address(let id):
            let address = id.flatMap { id in query.stock.addresses.first { $0.id == id } } ?? StreetAddress(id: "")
            edit = PlaceEdit(kind: kind, title: id == nil ? "New Address" : address.title, lines: [
                PlaceEdit.Line(key: "name", label: "Name", value: address.name, hint: "Who it goes to"),
                PlaceEdit.Line(key: "organization", label: "Company", value: address.organization),
                PlaceEdit.Line(key: "street", label: "Street", value: address.street.replacingOccurrences(of: "\n", with: ", "), hint: "1 Market St, Suite 300"),
                PlaceEdit.Line(key: "city", label: "City", value: address.city),
                PlaceEdit.Line(key: "region", label: "State", value: address.region),
                PlaceEdit.Line(key: "postal", label: "ZIP", value: address.postal),
                PlaceEdit.Line(key: "country", label: "Country", value: address.country, hint: "United States"),
                PlaceEdit.Line(key: "phone", label: "Phone", value: address.phone),
                PlaceEdit.Line(key: "email", label: "Email", value: address.email),
            ])
        case .code(let host, _):
            edit = PlaceEdit(kind: kind, title: "One-Time Code",
                             lines: [PlaceEdit.Line(key: "setup", label: "One-time code", value: "", hint: "The key, or an otpauth:// link", mono: true)])
        case .bookmark(let id):
            let (title, lines) = bookmarkLines(id)
            edit = PlaceEdit(kind: kind, title: title, lines: lines)
        case .folder:
            edit = PlaceEdit(kind: kind, title: "New Folder", lines: [PlaceEdit.Line(key: "title", label: "Name", value: "", hint: "The folder’s name")])
        case .snippet(let id):
            let snippet = id.flatMap { MailSnippets.shared.snippet($0) }
            edit = PlaceEdit(kind: kind, title: snippet.map { ";" + $0.name } ?? "New Snippet", lines: [
                PlaceEdit.Line(key: "name", label: "Name", value: snippet?.name ?? "", hint: "What follows ;"),
                PlaceEdit.Line(key: "words", label: "Words", value: snippet?.body ?? "",
                               hint: "{date} and {clipboard} fill themselves in; ⌥↩ for a new line", lines: true),
            ])
        }
        if edit.new {
            // The new row stands first in the list, chosen.
            if query.placeFilter != 0, query.place == .autofill { query.placeFilter = 0 }
            query.spot = 0
        }
        query.edit = edit
        if case .code(let host, let user) = kind { readCodePage(host: host, user: user) }
    }

    /// Esc: the row as it was, the keyboard back in the field.
    func cancelEdit() {
        guard let edit = query.edit else { return }
        query.edit = nil
        if edit.new { query.spot = 0 }
        query.focusRequest += 1
    }

    /// ↩ while editing: kept, or the field that can't be kept says why.
    func saveEdit() {
        guard var edit = query.edit else { return }
        func wrong(_ key: String, _ why: String) {
            edit.wrong = edit.lines.firstIndex { $0.key == key }
            edit.focus = edit.wrong ?? edit.focus
            edit.why = why
            query.edit = edit
        }
        switch edit.kind {
        case .login(let editor):
            editor.save(nil)
        case .profile:
            var profile = Profile.load()
            var given: [String: String] = [:]
            for line in edit.lines { given[line.key] = line.value }
            profile.merge(given, source: "you", force: true)
            guard Profile.save(profile, origin: .manual(Set(Profile.keys))) else { return wrong("name", "This Mac’s disk didn’t take it. Try again.") }
            finishEdit(select: "profile")
        case .card(let id):
            let digits = edit.value("number").filter(\.isNumber)
            guard let (month, year) = Browser.expiry(edit.value("expires")) else {
                let said = edit.value("expires")
                return wrong("expires", said.isEmpty ? "Write when it runs out, as on the card: 09/28."
                                                     : "Write the month and the year as the card has them: 09/28.")
            }
            let number = digits.isEmpty ? id.flatMap(Wallet.number(of:)) ?? "" : digits
            guard Wallet.luhn(number) else {
                return wrong("number", number.isEmpty ? "Write the card’s number, as on its front."
                                                      : "That number doesn’t add up. Look at the digits again.")
            }
            let code = edit.value("csc").filter(\.isNumber)
            guard code.isEmpty || (3...4).contains(code.count) else {
                return wrong("csc", "A security code is 3 digits on the back, or 4 on the front of an Amex.")
            }
            let kept = id.flatMap { id in query.stock.cards.first { $0.id == id } }
            var card = SavedCard(id: id ?? UUID().uuidString, number: number, last4: String(number.suffix(4)),
                                 brand: Wallet.brand(of: number), name: edit.value("name"), month: month, year: year,
                                 used: kept?.used, saved: nil, nickname: edit.value("nickname"),
                                 source: kept?.source ?? "", usedOn: kept?.usedOn ?? "")
            // What isn't written here stays as it was: its code, where it is billed.
            card.csc = code.isEmpty ? id.flatMap(Wallet.securityCode(of:)) ?? "" : code
            card.billing = kept?.billing ?? ""
            guard Wallet.save(card) else { return wrong("number", "The keychain didn’t take it. Try again.") }
            finishEdit(select: "card." + card.id)
        case .address(let id):
            var address = StreetAddress(id: id ?? UUID().uuidString)
            address.name = edit.value("name")
            address.organization = edit.value("organization")
            address.street = edit.value("street")
            address.city = edit.value("city")
            address.region = edit.value("region")
            address.postal = edit.value("postal")
            address.country = edit.value("country")
            address.phone = edit.value("phone")
            address.email = edit.value("email")
            guard !address.line1.isEmpty || !address.name.isEmpty else {
                return wrong("street", "Write a street, or at least who it goes to.")
            }
            let kept = id.flatMap { id in query.stock.addresses.first { $0.id == id } }
            address.used = kept?.used
            address.usedOn = kept?.usedOn
            address.source = kept?.source
            address.found = kept?.found
            guard Wallet.save(address, origin: .manual(Set(Wallet.contextKeys))) else { return wrong("street", "The keychain didn’t take it. Try again.") }
            finishEdit(select: "address." + address.id)
        case .code(let host, let user):
            let text = edit.value("setup")
            guard let setup = OneTime.parse(text), OneTime.save(text, host: host, user: user) else {
                // Six digits from the authenticator are the commonest slip.
                let digits = text.filter { !$0.isWhitespace }
                let code = (6...8).contains(digits.count) && digits.allSatisfy(\.isNumber)
                return wrong("setup", (code ? "That’s a code, not the key." : "That isn’t a setup key.")
                    + " Paste the key or the otpauth:// link the site shows by its QR code.")
            }
            // Just added: its code is shown at once, for the site to check.
            Browser.placeProven = Browser.placeProven ?? Date()
            finishEdit(select: "login." + host + "\u{1}" + user)
            if let tab = edit.fillTab {
                // The page asks for the first code: it goes in, the box away.
                close()
                fillCodePage(OneTime.code(setup).code, tab: tab, host: host)
            }
        case .bookmark, .folder:
            saveBookmark(edit, wrong: wrong)
        case .snippet(let id):
            let name = edit.value("name")
            let words = edit.lines.first { $0.key == "words" }?.value ?? ""
            if name.isEmpty { return wrong("name", "A snippet needs a name: it is what you type after ;.") }
            if let other = MailSnippets.shared.named(name), other.id != id { return wrong("name", "Another snippet is called that.") }
            if words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return wrong("words", "Write the words it puts in.") }
            let kept: MailSnippet
            if let id, var snippet = MailSnippets.shared.snippet(id) {
                snippet.name = name
                snippet.body = words
                MailSnippets.shared.change(snippet)
                kept = snippet
            } else {
                kept = MailSnippets.shared.add(name: name, body: words, mailOnly: false)
            }
            finishEdit(select: "snippet." + kept.id)
        }
    }

    /// Kept: the place read again, the row that was written chosen.
    func finishEdit(select id: String) {
        query.edit = nil
        restock()
        if let index = placeItems.firstIndex(where: { $0.id == id }) { query.spot = index }
        query.focusRequest += 1
    }

    /// What ↩ and the foot do while a row is written.
    var editActions: [FieldAction] {
        [FieldAction(id: "save", title: query.edit?.fillTab == nil ? "Save" : "Save and Fill", symbol: "checkmark") { self.saveEdit() },
         FieldAction(id: "cancel", title: "Cancel", keys: "esc", symbol: "yab.x") { self.cancelEdit() }]
    }

    /// "09/28", "9/2028", "0928": a month and a whole year.
    static func expiry(_ text: String) -> (Int, Int)? {
        let parts = text.split(whereSeparator: { !$0.isNumber }).map(String.init)
        var month: Int?, year: Int?
        if parts.count >= 2 {
            month = Int(parts[0])
            year = Int(parts[1])
        } else if let only = parts.first, only.count == 4 || only.count == 6 {
            month = Int(only.prefix(2))
            year = Int(only.dropFirst(2))
        }
        guard let month, let year, (1...12).contains(month) else { return nil }
        let whole = Wallet.fullYear(year)
        return whole >= 2000 ? (month, whole) : nil
    }

    /// The place read again as it is kept now, its filter and words kept.
    func restock() {
        guard let place = query.place else { return }
        let filter = query.placeFilter
        let site = query.stock.site
        switch place {
        case .passwords:
            query.stock.logins = Vault.entries()
            query.stock.codes = Set(OneTime.ids())
            weighPasswords()
        case .autofill:
            query.stock.cards = Wallet.cards()
            query.stock.addresses = Wallet.addresses()
            query.stock.profile = Profile.load()
            query.stock.answered = FormAnswers.load().said.count
        case .history:
            askHistory()
        default: break
        }
        query.placeFilter = filter
        query.stock.site = site
        query.stock.version += 1
    }

    // MARK: you

    /// The profile read again, and nothing else: an agent is writing it.
    func reloadProfile() {
        guard query.place == .autofill else { return }
        query.stock.profile = Profile.load()
        query.stock.version += 1
    }

    /// The profile's row, first in Autofill.
    func profileItem() -> PlaceItem {
        let profile = query.stock.profile
        let known = Profile.keys.filter { !profile[$0].isEmpty }.count
        let work = profile.role.isEmpty ? profile.headline : [profile.role, profile.company].filter { !$0.isEmpty }.joined(separator: ", ")
        let source = profile.isEmpty ? "Nothing about you yet" : [work, "\(known) of \(Profile.keys.count) known"].filter { !$0.isEmpty }.joined(separator: " · ")
        return PlaceItem(id: "profile", section: "You", title: profile.name.isEmpty ? "You" : profile.name, source: source,
                         tile: .symbol("person.text.rectangle"), search: Profile.keys.map { profile[$0] }.joined(separator: " ") + " you profile",
                         what: .profile)
    }

    /// What can be done with the profile: filled into the form under the
    /// box, or its line copied, and everything the page had.
    func profileActions() -> [FieldAction] {
        let profile = query.stock.profile
        var out: [FieldAction] = []
        if let (_, tab) = formTab(), tab.wallet.form.plan != nil {
            out.append(FieldAction(id: "fill", title: "Fill the Form", symbol: "yab.doc.check") {
                self.close()
                self.handBack(to: tab)
                self.fillForm(tab)
            })
        }
        let line = [("Bio", profile.bio), ("Headline", profile.headline), ("Name", profile.name)].first { !$0.1.isEmpty }
        if let line {
            out.append(FieldAction(id: "copy", title: "Copy \(line.0)", keys: Keymap.shared.text(.fieldCopy), symbol: "doc.on.doc", group: 1) {
                self.copyPlain(line.1, transient: true)
            })
        }
        let edit = FieldAction(id: "edit", title: profile.isEmpty ? "Write It Myself" : "Edit Profile", keys: Keymap.shared.text(.fieldEdit), symbol: profile.isEmpty ? "yab.pen" : "pencil", group: 2) {
            self.beginEdit(.profile)
        }
        let know = FieldAction(id: "know", title: "Get to Know Me", symbol: "yab.person.spark", group: 2) {
            self.close()
            self.getToKnowMe()
        }
        let knowing = knowingSession
        // Nothing known, or only your card's name and city: getting to know
        // you is what ↩ does, where an agent can.
        if profile.thin, knowing == nil, FormFill.agentsHere {
            out.insert(know, at: out.isEmpty ? 0 : 1)
            out.append(edit)
        } else {
            out.append(edit)
            if knowing == nil, FormFill.agentsHere { out.append(know) }
        }
        if let knowing {
            out.append(FieldAction(id: "stop", title: "Stop Getting to Know Me", symbol: "stop", group: 2) {
                _ = Agents.shared.stop(knowing.id)
            })
        }
        out.append(FieldAction(id: "mecard", title: "Fill From My Contact Card", symbol: "person.crop.circle", group: 2) {
            MeCard.fillProfile(ask: true) { filled in
                DispatchQueue.main.async {
                    self.restock()
                    if filled == 0 { self.toaster.pop("Nothing new on your contact card", mark: "person.crop.circle") }
                }
            }
        })
        let answered = query.stock.answered
        if answered > 0 {
            out.append(FieldAction(id: "answers", title: "Forget Saved Answers…", symbol: "trash", group: 3) {
                self.close()
                Task { @MainActor in
                    let yes = await Questions.shared.ask(Question(
                        title: "Forget \(answered) saved answer\(answered == 1 ? "" : "s")?",
                        detail: "What you wrote into forms before, kept so the next form asking the same gets it. Your profile stays.",
                        glyph: "trash", yes: "Forget", danger: true
                    ))
                    if yes { FormAnswers.forget() }
                }
            })
        }
        if !profile.isEmpty {
            out.append(FieldAction(id: "delete", title: "Forget Profile…", keys: Keymap.shared.text(.fieldDelete), symbol: "trash", group: 3) {
                self.close()
                Task { @MainActor in
                    let yes = await Questions.shared.ask(Question(
                        title: "Forget your profile?",
                        detail: "Your name, work and links, as forms get them. Memory, cards and addresses stay.",
                        glyph: "trash", yes: "Forget", danger: true
                    ))
                    if yes { Profile.forget() }
                }
            })
        }
        out.append(contentsOf: walletKit())
        return out
    }

    /// Autofill's own, on every row: a new card or address, more brought in.
    func walletKit() -> [FieldAction] {
        [FieldAction(id: "new", title: "New Card", keys: Keymap.shared.text(.fieldNew), symbol: "yab.card.plus", group: 4) { self.beginEdit(.card(nil)) },
         FieldAction(id: "newaddress", title: "New Address", symbol: "yab.home.plus", group: 4) { self.beginEdit(.address(nil)) },
         FieldAction(id: "more", title: "Bring In More…", symbol: "tray.and.arrow.down", group: 4) { self.bringMore() }]
    }

    // MARK: bringing more in

    /// Bring In More…: the place's ways in, where its list was.
    func bringMore() {
        guard let place = query.place else { return }
        query.acting = nil
        query.edit = nil
        query.stock.more = true
        query.spot = 0
        countSources(place)
    }

    /// Back to the list from bringing in, whatever step it was at.
    func leaveMore() -> Bool {
        let stock = query.stock
        guard stock.more || stock.safari != nil || stock.trouble != nil else { return false }
        if stock.safari == .waiting { SafariImport.Desk.shared.answer("safariCancel") { _, _ in } }
        query.stock.more = false
        query.stock.safari = nil
        query.stock.trouble = nil
        query.spot = 0
        return true
    }

    /// Every way in for the place: the browsers counted, Safari, and a CSV
    /// or your card in Contacts.
    func placeSources(_ place: FieldPlace) -> [PlaceSource] {
        var sources = query.stock.sources ?? []
        if let icon = SafariImport.icon {
            sources.append(PlaceSource(name: "Safari", icon: icon, take: FieldAction(id: "safari", title: "Bring In from Safari…", symbol: "yab.globe.dl") {
                self.waitForSafari("safari")
            }))
        }
        if place == .passwords {
            sources.append(PlaceSource(name: "CSV File", symbol: "doc.text", take: FieldAction(id: "csv", title: "Import a CSV File…", symbol: "yab.doc.dl") {
                self.close()
                self.importPasswords()
            }))
        } else if place == .bookmarks {
            sources.append(PlaceSource(name: "Bookmarks File", symbol: "doc.text", take: FieldAction(id: "file", title: "Import a Bookmarks File…", symbol: "doc.text") {
                self.close()
                self.importBookmarksFile()
            }))
        } else {
            sources.append(PlaceSource(name: "Contacts", symbol: "person.crop.circle", take: FieldAction(id: "me", title: "Use Your Card in Contacts", symbol: "person.crop.circle") {
                MeCard.addresses { found in
                    DispatchQueue.global(qos: .userInitiated).async {
                        let kept = Wallet.take(cards: [], addresses: found)
                        DispatchQueue.main.async {
                            guard self.query.place == .autofill else { return }
                            if found.isEmpty || kept.addresses == 0 {
                                self.query.stock.trouble = PlaceTrouble(
                                    title: found.isEmpty ? "Your contact card has no address" : "Your addresses are here already",
                                    detail: found.isEmpty ? "Add one to your card in Contacts, the one marked as you, and bring it in again." : "Every address on your card in Contacts is kept already.")
                            } else {
                                _ = self.leaveMore()
                            }
                            self.restock()
                        }
                    }
                }
            }))
        }
        return sources
    }

    /// Safari's export: Safari opened on it and Downloads watched, or a file
    /// chosen; then everything in it brought in, the file offered to the Trash.
    func waitForSafari(_ verb: String) {
        let place = query.place
        if verb == "safari" { query.stock.safari = .waiting }
        SafariImport.Desk.shared.answer(verb) { [weak self] reply, _ in
            MainActor.assumeIsolated {
                guard let self, self.query.place == place, let answer = reply as? [String: Any] else { return }
                if answer["cancelled"] as? Bool == true {
                    if verb == "safariFile", self.query.stock.safari == .waiting { return }
                    return
                }
                if let error = answer["error"] as? String {
                    self.query.stock.safari = .failed(error)
                    return
                }
                self.query.stock.safari = .done(line: answer["line"] as? String ?? "Nothing new", file: answer["file"] as? String ?? "The export",
                                                folder: answer["folder"] as? String ?? "Downloads")
                self.restock()
            }
        }
    }

    /// What the place says while bringing in: where Safari's export is, a
    /// trouble, the count so far, or the ways in to choose from.
    var bringingEmpty: PlaceEmpty? {
        guard let place = query.place, [.passwords, .autofill, .bookmarks].contains(place) else { return nil }
        let stock = query.stock
        if let trouble = stock.trouble {
            return PlaceEmpty(place: place, searching: false, title: trouble.title, detail: trouble.detail,
                              actions: [trouble.retry, FieldAction(id: "back", title: "Back to the List", symbol: "arrow.uturn.backward") { _ = self.leaveMore() }].compactMap { $0 })
        }
        switch stock.safari {
        case .waiting:
            return PlaceEmpty(place: place, searching: false, title: "Waiting for Safari’s export",
                              detail: "Safari is open. Choose File › Export Browsing Data, keep \(place == .bookmarks ? "Bookmarks" : "Passwords and Credit Cards") ticked, and save it in Downloads. Yab brings it in the moment it lands.",
                              footnote: place == .bookmarks ? nil : "Safari keeps its passwords where no other app can read them: its own export is the one way in.",
                              actions: [FieldAction(id: "file", title: "Choose File…", symbol: "yab.folder.search") { self.waitForSafari("safariFile") },
                                        FieldAction(id: "back", title: "Cancel", symbol: "yab.x") { _ = self.leaveMore() }])
        case .done(let line, let file, let folder):
            return PlaceEmpty(place: place, searching: false, title: "Brought in \(line.prefix(1).lowercased() + line.dropFirst())",
                              detail: place == .bookmarks ? "\(file) in \(folder) isn’t encrypted: if it holds passwords too, anyone who opens it reads them."
                                                          : "\(file) in \(folder) isn’t encrypted: anyone who opens it reads every password in it.",
                              actions: [FieldAction(id: "trash", title: "Move It to the Trash", symbol: "trash") {
                                  SafariImport.Desk.shared.answer("safariTrash") { _, _ in }
                                  _ = self.leaveMore()
                              }, FieldAction(id: "back", title: "Keep It", symbol: "yab.check") { _ = self.leaveMore() }])
        case .failed(let why):
            return PlaceEmpty(place: place, searching: false, title: why,
                              detail: "Safari’s export is a ZIP it saves with File › Export Browsing Data.",
                              actions: [FieldAction(id: "file", title: "Choose File…", symbol: "yab.folder.search") { self.waitForSafari("safariFile") },
                                        FieldAction(id: "retry", title: "Open Safari Again", symbol: "safari") { self.waitForSafari("safari") }])
        case nil:
            break
        }
        if let name = stock.bringing {
            let detail = stock.keeping.map { "Keeping \($0.0.formatted()) of \($0.1.formatted())." } ?? (place == .bookmarks ? "Folders come as they are." : "macOS may ask for \(name)’s key once.")
            return PlaceEmpty(place: place, searching: false, title: "Bringing them in from \(name)", detail: detail, busy: true)
        }
        guard stock.more else { return nil }
        var sources = placeSources(place)
        // Cards in more than one browser: all of them, first and chosen.
        if place == .autofill, let wallets = stock.wallets, wallets.count > 1 {
            let all = wallets.map(\.source)
            sources.insert(PlaceSource(name: "All Browsers", symbol: "square.stack", detail: "",
                                       take: FieldAction(id: "bringall", title: "Bring In from All Browsers", symbol: "tray.and.arrow.down") {
                                           self.bringWallets(all)
                                       }), at: 0)
        }
        let chosen = sources[min(query.spot, sources.count - 1)]
        // ⌘K has every way in, not only the chosen one's, and the way back.
        let rest = sources.map(\.take).filter { $0.id != chosen.take.id || $0.title != chosen.take.title }
            .map { FieldAction(id: $0.id + "." + $0.title, title: $0.title, symbol: $0.symbol, group: 3, run: $0.run) }
        let back = FieldAction(id: "back", title: "Back to the List", symbol: "arrow.uturn.backward", group: 4) { _ = self.leaveMore() }
        return PlaceEmpty(place: place, searching: false,
                          title: place == .passwords ? "Bring in more passwords" : place == .bookmarks ? "Bring in more bookmarks" : "Bring in more cards and addresses",
                          detail: place == .passwords ? "Logins already here are left as they are, and new ones join them."
                                : place == .bookmarks ? "Folders come as they are. Brought from the same browser again, they are merged, not doubled."
                                : "Cards and addresses already here are left as they are.",
                          footnote: chosen.take.id == "bringall" ? "macOS asks once for each browser’s key. Nothing changes in them."
                              : chosen.icon == nil || chosen.name == "Safari" ? nil
                              : place == .bookmarks ? "Nothing changes in \(chosen.name)." : "macOS asks once for \(chosen.name)’s key. Nothing changes in \(chosen.name).",
                          sources: sources, actions: [chosen.take] + rest + [back])
    }

    /// Cards and addresses from a browser on this Mac, and what went wrong
    /// if it did.
    func bringWallet(_ source: Chromium.Source) { bringWallets([source]) }

    /// Cards and addresses from each browser in turn, each asked for its
    /// key once. One that says no or won't open doesn't stop the rest: the
    /// first of those is said at the end, with a way to try them again.
    func bringWallets(_ sources: [Chromium.Source]) {
        guard let first = sources.first else { return }
        query.stock.bringing = first.name
        DispatchQueue.global(qos: .userInitiated).async {
            var failed: [(Chromium.Source, Error)] = []
            for (index, discovered) in sources.enumerated() {
                let source = discovered.authorizingImport()
                if index > 0 {
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.query.place == .autofill, self.query.stock.bringing != nil else { return }
                        self.query.stock.bringing = source.name
                    }
                }
                do {
                    let kept = try Chromium.wallet(source)
                    _ = Wallet.take(cards: kept.cards, addresses: kept.addresses)
                } catch {
                    failed.append((source, error))
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.query.place == .autofill else { return }
                self.query.stock.bringing = nil
                if let (source, error) = failed.first {
                    let again = failed.map(\.0)
                    let retry = FieldAction(id: "retry", title: "Try Again", symbol: "yab.reload") { self.query.stock.trouble = nil; self.bringWallets(again) }
                    let rest = failed.count > 1 ? " \(failed.dropFirst().map(\.0.name).joined(separator: " and ")) too." : ""
                    if case Chromium.Trouble.noPassphrase = error {
                        self.query.stock.trouble = PlaceTrouble(title: "\(source.name) didn’t hand over its key",
                                                                detail: "macOS asked for your password to open \(source.name)’s cards and it was turned down. Try again and choose Always Allow.\(rest)",
                                                                retry: retry)
                    } else {
                        self.query.stock.trouble = PlaceTrouble(title: "Couldn’t read \(source.name)’s cards",
                                                                detail: "Quit \(source.name) and try again: it may be holding its files.\(rest)",
                                                                retry: retry)
                    }
                } else {
                    _ = self.leaveMore()
                }
                self.restock()
            }
        }
    }

    /// Autofill with nothing kept, and cards or addresses in the other
    /// browsers: one row that brings them all in, under Cards, or under
    /// Addresses when that is all there is or all the filter shows.
    func bringItem(_ filter: Int) -> PlaceItem? {
        let stock = query.stock
        guard stock.cards.isEmpty, stock.addresses.isEmpty, let wallets = stock.wallets, !wallets.isEmpty else { return nil }
        let cards = wallets.reduce(0) { $0 + $1.cards }, addresses = wallets.reduce(0) { $0 + $1.addresses }
        // Discovery knows browser names, not whether they have cards or addresses.
        guard cards + addresses > 0 else { return nil }
        if filter == 2 && cards == 0 || filter == 3 && addresses == 0 { return nil }
        let names = wallets.map(\.source.name)
        return PlaceItem(id: "bring", section: filter == 3 || cards == 0 ? "Addresses" : "Cards",
                         title: bringTitle(names), source: Self.walletCount(cards, addresses),
                         tile: .symbol("tray.and.arrow.down"),
                         search: (names + ["bring in import cards addresses"]).joined(separator: " "), what: .bring)
    }

    /// "Bring In from Chrome", "from Chrome and Arc", "from 3 Browsers".
    func bringTitle(_ names: [String]) -> String {
        switch names.count {
        case 1: return "Bring In from \(names[0])"
        case 2: return "Bring In from \(names[0]) and \(names[1])"
        default: return "Bring In from \(names.count) Browsers"
        }
    }

    /// "3 cards · 2 addresses", each said only when there is one.
    static func walletCount(_ cards: Int, _ addresses: Int) -> String {
        [cards > 0 ? "\(cards) card\(cards == 1 ? "" : "s")" : "",
         addresses > 0 ? "\(addresses) address\(addresses == 1 ? "" : "es")" : ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The row's: every browser at once first, what ↩ does; then each way
    /// in on its own, Safari's export and your contact card among them.
    func bringActions() -> [FieldAction] {
        let wallets = query.stock.wallets ?? []
        var out = [FieldAction(id: "bringall", title: "Bring In", symbol: "tray.and.arrow.down") {
            self.bringWallets(wallets.map(\.source))
        }]
        let each = placeSources(.autofill).map(\.take)
        out += (wallets.count > 1 ? each : Array(each.dropFirst(wallets.isEmpty ? 0 : 1))).map { take in
            FieldAction(id: take.id + "." + take.title, title: take.title, symbol: take.symbol, group: 3, run: take.run)
        }
        return out + walletKit()
    }

    // MARK: one-time codes

    /// A login's code box: the key added or taken away.
    func codeActions(_ entry: Vault.Entry) -> [FieldAction] {
        guard query.stock.codes.contains(entry.id) else {
            return [FieldAction(id: "addcode", title: "Add One-Time Code…", symbol: "yab.clock.plus", group: 2) {
                self.beginEdit(.code(host: entry.host, user: entry.user))
            }]
        }
        return [FieldAction(id: "dropcode", title: "Remove One-Time Code…", symbol: "clock.badge.xmark", group: 3) {
            self.close()
            Task { @MainActor in
                let yes = await Questions.shared.ask(Question(
                    title: "Remove the one-time code for \(entry.host)?",
                    detail: "Turn two-step sign-in off on \(Browser.site(entry.host)) first, or keep the key somewhere else: without it you can’t sign in.",
                    glyph: "clock", yes: "Remove", danger: true
                ))
                guard yes else { return }
                self.proveOwner("remove the code for \(entry.host)") { OneTime.forget(host: entry.host, user: entry.user) }
            }
        }]
    }

    /// Whether the box the caret was in asks for a one-time code.
    static func asksCode(_ box: Tab.CaretBox) -> Bool {
        guard !box.password else { return false }
        if box.code { return true }
        let label = box.label.lowercased()
        return ["code", "otp", "2fa", "two-factor", "two factor", "verification", "authenticat", "token"].contains { label.contains($0) }
    }
}

/// A field of a row being written, where its value stood: bare text on a
/// plate a shade off the ground, the caret's ringed in the accent, a wrong
/// one in the warning's color. ↩ saves, esc cancels, ⇥ and ⇧⇥ step.
struct EditLine: NSViewRepresentable {
    let browser: Browser
    var query: Query
    let index: Int

    func makeCoordinator() -> Coordinator { Coordinator(browser: browser, query: query, index: index) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = context.coordinator
        if let edit = query.edit, edit.lines.indices.contains(index), edit.lines[index].lines {
            field.cell?.isScrollable = false
            field.cell?.wraps = true
            field.usesSingleLineMode = false
            field.maximumNumberOfLines = 0
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.index = index
        guard let edit = query.edit, edit.lines.indices.contains(index) else { return }
        let line = edit.lines[index]
        if field.stringValue != line.value { field.stringValue = line.value }
        let font = line.mono ? NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular) : NSFont.systemFont(ofSize: 13)
        if field.font != font { field.font = font }
        let hint = line.ghost.isEmpty ? line.hint : line.ghost
        if field.placeholderString != hint {
            // Faint, so an empty field never reads as one filled in; what
            // Yab found, pale in the accent, as a page's box shows it.
            field.placeholderAttributedString = NSAttributedString(string: hint, attributes: line.ghost.isEmpty ? [
                .foregroundColor: NSColor(Palette.faint), .font: NSFont.systemFont(ofSize: 13),
            ] : [
                .foregroundColor: NSColor.controlAccentColor.withAlphaComponent(0.6), .font: font,
            ])
        }
        field.textColor = NSColor(Palette.ink)
        if edit.focus == index, field.currentEditor() == nil {
            DispatchQueue.main.async {
                guard query.edit?.focus == index, field.currentEditor() == nil else { return }
                field.window?.makeFirstResponder(field)
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let browser: Browser
        let query: Query
        var index: Int

        init(browser: Browser, query: Query, index: Int) {
            self.browser = browser
            self.query = query
            self.index = index
        }

        @MainActor
        func controlTextDidBeginEditing(_ note: Notification) {
            if query.edit?.focus != index { query.edit?.focus = index }
        }

        @MainActor
        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField, var edit = query.edit, edit.lines.indices.contains(index) else { return }
            edit.lines[index].value = field.stringValue
            edit.focus = index
            if edit.wrong == index {
                edit.wrong = nil
                edit.why = ""
            }
            query.edit = edit
        }

        @MainActor
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard let count = query.edit?.lines.count else { return false }
            switch selector {
            case #selector(NSResponder.insertNewline(_:)): browser.saveEdit()
            case #selector(NSResponder.cancelOperation(_:)): browser.cancelEdit()
            case #selector(NSResponder.insertTab(_:)):
                // ⇧⇥ comes as a plain tab from some keyboards' events.
                let back = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
                if !back, let line = query.edit?.lines[safe: index], line.value.isEmpty, !line.ghost.isEmpty {
                    // What Yab found, taken, as if typed: the caret after it.
                    textView.insertText(line.ghost, replacementRange: textView.selectedRange())
                    return true
                }
                query.edit?.focus = (index + (back ? count - 1 : 1)) % count
            case #selector(NSResponder.insertBacktab(_:)): query.edit?.focus = (index - 1 + count) % count
            default: return false
            }
            return true
        }
    }
}

/// The row being written, in the preview: the card drawn from what is typed
/// so far, then its fields under what they are, and why one can't be kept.
struct EditForm: View {
    let browser: Browser
    var query: Query
    let edit: PlaceEdit

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // What is written is said at the field's end; a card is drawn.
            if case .card = edit.kind { card }
            VStack(spacing: 0) {
                ForEach(Array(edit.lines.enumerated()), id: \.offset) { index, line in
                    HStack(spacing: 12) {
                        Text(line.label)
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.muted)
                            .lineLimit(1)
                            .frame(width: 96, alignment: .leading)
                        EditLine(browser: browser, query: query, index: index)
                            .frame(height: line.lines ? 76 : 20)
                            .padding(.horizontal, 8)
                            .frame(height: line.lines ? 84 : 28)
                            .background(RoundedRectangle(cornerRadius: Radius.small, style: .continuous).fill(Omnibox.tileFill))
                            .overlay {
                                RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                                    .strokeBorder(edit.wrong == index ? Color(nsColor: .systemOrange) : Color.accentColor,
                                                  lineWidth: edit.wrong == index ? 1.5 : 2)
                                    .opacity(edit.wrong == index || edit.focus == index ? 1 : 0)
                            }
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 38)
                    .id("edit.\(index)")
                    if edit.wrong == index, !edit.why.isEmpty {
                        // Under its field, from where the field starts.
                        HStack(spacing: 12) {
                            Color.clear.frame(width: 96, height: 1)
                            Text(edit.why)
                                .font(.system(size: 12))
                                .foregroundStyle(Color(nsColor: .systemOrange))
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 6)
                    }
                }
            }
        }
    }

    /// The card as it will be, from what is typed so far.
    private var card: some View {
        let digits = edit.value("number").filter(\.isNumber)
        let kept: SavedCard? = {
            if case .card(let id?) = edit.kind { return query.stock.cards.first { $0.id == id } }
            return nil
        }()
        let shown = digits.isEmpty ? kept.map { "•••• •••• •••• \($0.last4)" } ?? "•••• •••• •••• ••••" : Browser.grouped(digits)
        let brand = digits.isEmpty ? kept?.brand ?? "Card" : Wallet.brand(of: digits)
        let expires = edit.value("expires")
        return VStack(alignment: .leading, spacing: 8) {
            Text(brand)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.muted)
            Text(shown)
                .font(.system(size: 15, design: .monospaced))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .fixedSize()
            HStack {
                Text(edit.value("nickname").isEmpty ? (edit.value("name").isEmpty ? " " : edit.value("name")) : edit.value("nickname"))
                Spacer(minLength: 0)
                Text(expires.isEmpty ? "MM/YY" : expires)
            }
            .font(.system(size: 12))
            .foregroundStyle(Palette.muted)
        }
        .padding(16)
        .frame(width: 260)
        .background(RoundedRectangle(cornerRadius: Radius.floating, style: .continuous).fill(Omnibox.tileFill))
    }
}

/// A one-time code as it is now, in groups of three, and how long it has
/// left in words ("18s"), turning over by itself. A click copies it.
struct LiveCode: View {
    var host = ""
    var user = ""
    /// A key not kept yet: the one being written.
    var given: OneTime.Setup?
    @State private var setup: OneTime.Setup?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let setup = given ?? setup {
                let now = OneTime.code(setup, at: context.date)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(LiveCode.spaced(now.code))
                        .font(.system(size: 15, design: .monospaced))
                        .foregroundStyle(Palette.ink)
                    Text("\(now.left)s")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(Palette.muted)
                        .frame(minWidth: 22, alignment: .trailing)
                }
            } else {
                Text("••• •••")
                    .font(.system(size: 12.5, design: .monospaced))
                    .kerning(2)
                    .foregroundStyle(Palette.muted)
            }
        }
        .task(id: host + user) { if given == nil { setup = OneTime.setup(host: host, user: user) } }
    }

    static func spaced(_ code: String) -> String {
        code.count == 6 ? code.prefix(3) + " " + code.suffix(3) : code
    }
}

/// A login's one-time code being added, in its own line of the preview's
/// Information: the field where "Add a Code…" stood, the key Yab read from
/// the page pale in it with Tab to take it, and the code it makes under it
/// as soon as it is a key, before anything is kept.
struct CodeEditLine: View {
    let browser: Browser
    var query: Query

    var body: some View {
        if let edit = query.edit, let line = edit.lines.first {
            let wrong = edit.wrong == 0
            let setup = wrong ? nil : OneTime.parse(line.value)
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text(line.label)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                        .frame(width: 96, alignment: .leading)
                    HStack(spacing: 6) {
                        EditLine(browser: browser, query: query, index: 0)
                            .frame(height: 20)
                        if line.value.isEmpty, !line.ghost.isEmpty {
                            KeyGlyphs(keys: "⇥", size: 12.5, tint: .accentColor, rest: 0.8)
                                .transaction { $0.animation = nil }
                        }
                    }
                    .padding(.leading, 8)
                    .padding(.trailing, line.value.isEmpty && !line.ghost.isEmpty ? 4 : 8) // design: the ⇥ plate sits 4 from the end, as a page's pale value has it
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: Radius.small, style: .continuous).fill(Omnibox.tileFill))
                    .overlay {
                        RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                            .strokeBorder(wrong ? Color(nsColor: .systemOrange) : Color.accentColor, lineWidth: wrong ? 1.5 : 2)
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: 38)
                if wrong, !edit.why.isEmpty {
                    // Under the field, from where it starts.
                    Text(edit.why)
                        .font(.system(size: 12))
                        .foregroundStyle(Color(nsColor: .systemOrange))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 8 + 96 + 12) // design: from where the field starts, past its label
                        .padding(.trailing, 8)
                        .padding(.bottom, 8)
                }
                if let setup {
                    Rectangle().fill(Omnibox.seam).frame(height: 0.5).padding(.horizontal, 8)
                    HStack(spacing: 12) {
                        Text("Code now")
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.muted)
                        Spacer(minLength: 0)
                        LiveCode(given: setup)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 34)
                }
            }
            .id("edit.0")
        }
    }
}

/// The profile's row's words while getting to know you is under way: where
/// it has got, in the dock's words, and the profile read again once done.
struct ProfileSource: View {
    let browser: Browser
    let fallback: String
    var agents = Agents.shared

    var body: some View {
        let session = browser.knowingSession
        Text(session.map { MemoryKnowing.line($0) } ?? fallback)
        // What it finds is written as it goes: the row and the preview
        // follow, and once more when it is done.
        .onChange(of: session?.now) { _, _ in browser.reloadProfile() }
        .onChange(of: session == nil) { _, _ in browser.reloadProfile() }
    }
}
