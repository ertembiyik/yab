import AppKit
import SwiftUI

// Cards and addresses at the moment you use them: the kept ones hanging from
// the box the caret is in, the way sign-in accounts do (Accounts.swift), and
// a new one offered a place in the keychain once the page shows it went
// through, the way a password is (Keep.swift): one card over the page, Save
// or Not now, and put off, a card on the tab until you come back to it.
//
// A form's new answers are never asked about: they are kept on their own
// (FormAnswers), and the morning look goes over them.
//
// Saving says nothing when it works: the card going away is the answer.

struct PayOffer: Equatable, Identifiable {
    let id = UUID()
    /// A card to keep, with its number. Its id is a kept card's when this
    /// is that card with a new date.
    var card: SavedCard?
    /// The date it had, when this is an update of a kept card.
    var was: String?
    var address: StreetAddress?
    /// Which of the two to keep, when there are both.
    var keepsCard = true
    var keepsAddress = true
    /// Where it was paid, and where that landed. The offer holds while the
    /// tab stays on one of them.
    var sites: Set<String>
    let at = Date()
    var parked = false
    /// The keychain wouldn't take it.
    var refused = false
    /// Folding into its mark, the moment before it goes: the card leaves
    /// toward the mark rather than the way it came.
    var folding = false
    /// Its mark is in the air on the way to the tab, and the tab doesn't
    /// show it until it lands.
    var flying = false

    /// What flies to the tab: the card's network, or "house".
    var mark: String { card?.brand ?? "house" }
    /// What flies when it is kept: the first thing ticked.
    var keptMark: String { card != nil && keepsCard ? mark : "house" }

    var both: Bool { card != nil && address != nil }
    var anything: Bool { (card != nil && keepsCard) || (address != nil && keepsAddress) }

    /// A form can report the same submission again after a SPA redraw or
    /// refocus. It doesn't undo Not Now or replace the existing question.
    func alreadyOffers(card: SavedCard?, address: StreetAddress?, site: String) -> Bool {
        guard !refused, sites.contains(site), card != nil || address != nil else { return false }
        if let card {
            guard let old = self.card, old.number == card.number,
                  old.month == card.month, old.year == card.year, old.name == card.name,
                  old.csc == card.csc else { return false }
        }
        if let address {
            guard self.address?.same(as: address) == true else { return false }
        }
        return true
    }
}

/// A number of yours for a phone box on its own: from your card in
/// Contacts, then the Wallet's addresses, one row a number.
struct KnownPhone: Equatable, Identifiable {
    /// As it is kept, "+1 (415) 555-0100".
    let number: String
    /// Where it is kept: "Contact card · mobile", "Sam R., 221 Mission St".
    let from: String
    var id: String { KnownPhone.key(number) }

    /// The last ten digits: "+1 415 555 0100" and "(415) 555-0100" are one.
    static func key(_ number: String) -> String { String(number.filter(\.isNumber).suffix(10)) }

    /// Every number known, read off the main thread, heard on it.
    static func all(_ done: @escaping @MainActor ([KnownPhone]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let card = MeCard.phones().map { KnownPhone(number: $0.number, from: ["Contact card", $0.label].filter { !$0.isEmpty }.joined(separator: " · ")) }
            let kept = Wallet.addresses().filter { !$0.phone.isEmpty }.map { KnownPhone(number: $0.phone, from: $0.title) }
            var seen = Set<String>()
            let phones = (card + kept).filter { $0.id.count >= 7 && seen.insert($0.id).inserted }
            DispatchQueue.main.async { MainActor.assumeIsolated { done(Array(phones.prefix(5))) } }
        }
    }
}

extension Browser {
    struct WalletChoices: Equatable {
        let tab: Tab.ID
        var spot: CGRect
        let group: WalletField.Group
        let cards: [SavedCard]
        let addresses: [StreetAddress]
        /// The page the list was made for: a pick fills only that one.
        let origin: String
        /// "Fill the form" on top, when the form holds enough (FormFill).
        var form: FormOffer? = nil
        /// The page dark under the box, so the list is too.
        var dark: Bool? = nil
        /// "Fill your profile first" under it: the profile is empty and an
        /// agent could get to know you (docs/forms.md).
        var knowMe = false
        /// Your numbers, for a phone box on its own.
        var phones: [KnownPhone] = []
        /// What the box asks (`WalletField.box`): a name box's rows say
        /// the name, an email box's the email, the street under it.
        var box = ""
        var count: Int { first + (group == .card ? cards.count : group == .phone ? phones.count : addresses.count) }
        /// All Cards or All Addresses as the last row; a phone's list is
        /// only its numbers.
        var all: Bool { group != .phone }
        /// The row a card or an address is on, past the form's rows.
        var first: Int { (form == nil ? 0 : 1) + (knowMe ? 1 : 0) }
    }

    // MARK: - the list under a box

    /// The caret came into a box a card or an address goes in, or left it.
    /// The list shows while the box is empty; typing puts it away.
    func walletField(_ tab: Tab, _ field: WalletField?) {
        // An extension that took cards or addresses Chrome's way (a
        // password manager's) has those boxes: its menu alone, never Yab's
        // list beside it (docs/password-manager-fields.md).
        if let field, PasswordManagers.walletOwner(cards: field.group == .card) != nil {
            if walletList?.tab == tab.id { walletList = nil }
            return
        }
        if let field, offersAutofill(tab), walletBoxEmpty != field.empty { walletBoxEmpty = field.empty }
        if let field, field.group == .phone { return phoneField(tab, field) }
        // Escape said no on this page: none of its boxes asks again.
        if let field, field.group == .form || field.group == .address, tab.wallet.declined(on: tab.address) {
            if walletList?.tab == tab.id { walletList = nil }
            return
        }
        // A form's box, or an address's: the form's row is worked out first,
        // and the addresses, if any, join it (FormFill.offerForm).
        if let field, field.group != .card, offersAutofill(tab), !tab.shy {
            walletLowering?.cancel()
            // Typed in, as anywhere: the box is yours now, and the row
            // goes until the caret comes to an empty one.
            guard field.empty else {
                if walletList?.tab == tab.id { walletList = nil }
                return
            }
            // The same form a moment later, the box scrolled or another box
            // of it: the list only moves. The caret speaks on every frame of
            // a scroll, and working the form out again each time read every
            // box and the keychain per frame.
            if var list = walletList, list.tab == tab.id, list.group == .address, field.group == .address,
               Date().timeIntervalSince(tab.wallet.form.planned) < 5 {
                if list.spot != field.spot || list.box != field.box { list.spot = field.spot; list.box = field.box; walletList = list }
                return
            }
            // The same box of a form a moment later, scrolled: its pale
            // value is in the page already. Another box reads the form
            // again, which a step swapped in by the page needs.
            if field.group == .form {
                let key = "\(field.box)|\(field.spot.minX.rounded())|\(field.spot.width.rounded())"
                if tab.wallet.form.box == key, Date().timeIntervalSince(tab.wallet.form.planned) < 5 { return }
                tab.wallet.form.box = key
            }
            let addresses = field.group == .address && prefs.fillsCards ? Array(Wallet.addresses().prefix(5)) : []
            if FormFill.on {
                offerForm(tab, field, addresses: addresses)
                return
            }
            guard field.group == .address else {
                if walletList?.tab == tab.id { walletList = nil }
                return
            }
        }
        guard let field, field.empty else {
            guard walletList?.tab == tab.id else { return }
            if field != nil {
                walletList = nil
                return
            }
            walletLowering?.cancel()
            // A beat later, as with the accounts: a click on a row takes
            // the caret out of the page first.
            let work = DispatchWorkItem { [weak self] in
                guard let self, walletList?.tab == tab.id else { return }
                walletList = nil
            }
            walletLowering = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
            return
        }
        walletLowering?.cancel()
        guard prefs.fillsCards, offersAutofill(tab), !tab.shy || field.group == .address else { return }
        // No card goes into a page that came over plain http.
        if field.group == .card, !field.secure { return }
        let cards = field.group == .card ? Array(Wallet.cards().filter { !$0.expired }.prefix(5)) : []
        let addresses = field.group == .address ? Array(Wallet.addresses().prefix(5)) : []
        guard !cards.isEmpty || !addresses.isEmpty else {
            walletList = nil
            return
        }
        var list = WalletChoices(tab: tab.id, spot: field.spot, group: field.group, cards: cards, addresses: addresses,
                                 origin: Tab.originOf(tab.address), dark: field.dark)
        list.box = field.box
        if walletList != list { walletList = list }
    }

    /// A phone box on its own, a sign-in by text (Partiful's): your numbers
    /// hang from it while it is empty, as the accounts do from a name box.
    private func phoneField(_ tab: Tab, _ field: WalletField) {
        walletLowering?.cancel()
        guard field.empty, prefs.fillsCards, offersAutofill(tab) else {
            if walletList?.tab == tab.id { walletList = nil }
            return
        }
        // The same box scrolled: only the list moves.
        if var list = walletList, list.tab == tab.id, list.group == .phone {
            if list.spot != field.spot { list.spot = field.spot; walletList = list }
            return
        }
        // Heard back a moment later: only while the caret is still where it was.
        let origin = Tab.originOf(tab.address), beat = tab.wallet.beat
        KnownPhone.all { [weak self, weak tab] phones in
            guard let self, let tab, tab.wallet.beat == beat, self.offersAutofill(tab), Tab.originOf(tab.address) == origin else { return }
            guard !phones.isEmpty else {
                if self.walletList?.tab == tab.id { self.walletList = nil }
                return
            }
            var list = WalletChoices(tab: tab.id, spot: field.spot, group: .phone, cards: [], addresses: [],
                                     origin: origin, dark: field.dark)
            list.phones = phones
            if self.walletList != list { self.walletList = list }
        }
    }

    /// A row of the list, picked. A card waits for Touch ID; an address goes
    /// straight in.
    func chooseWallet(_ index: Int) {
        walletLowering?.cancel()
        guard let list = walletList, let tab = autofillTab(list.tab) else { return }
        if list.form != nil, index == 0 { return fillForm() }
        if list.knowMe, index == (list.form == nil ? 0 : 1) { return getToKnowMe() }
        let index = index - list.first
        walletList = nil
        guard Tab.originOf(tab.address) == list.origin else { return }
        let site = Browser.site(tab.address?.host() ?? "")
        switch list.group {
        case .card:
            guard list.cards.indices.contains(index) else { return }
            let card = list.cards[index]
            // Other sites' frames that would get it are named in the question.
            let also = tab.walletHosts(.card)
            Wallet.prove("fill \(card.title) on \(site)" + (also.isEmpty ? "" : " (its form is \(also.joined(separator: ", ")))")) { [weak self] proven in
                guard let self else { return }
                switch proven {
                case .yes: break
                case .no: return
                case .cannot:
                    announce("Couldn’t ask for \(Vault.proof), nothing filled", mark: "creditcard")
                    return
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    let number = Wallet.number(of: card.id)
                    let code = Wallet.securityCode(of: card.id) ?? ""
                    // For a billing ZIP beside the card: its billing address.
                    let home = Wallet.billing(of: card, among: Wallet.addresses())
                    DispatchQueue.main.async { [weak self, weak tab] in
                        guard let self, let tab, let number else { return }
                        let data: [String: Any] = ["number": number, "name": card.name, "month": card.month, "year": card.year, "csc": code,
                                                   "postal": home?.postal ?? "", "country": home?.country ?? "", "billing": home?.filling ?? [:]]
                        // Frames of a site that is neither the shop nor a payment
                        // company get nothing; their empty boxes say nothing why.
                        let passed = tab.walletPassed(.card)
                        tab.walletFill(data, what: .card, origin: list.origin) { [weak self] filled in
                            if filled > 0 {
                                DispatchQueue.global(qos: .utility).async { Wallet.touch(card: card.id, on: site) }
                            }
                            if let host = passed.first {
                                self?.toaster.pop("Not filled in \(host)’s fields: type the card there", mark: "exclamationmark.triangle")
                            } else if filled == 0 {
                                self?.toaster.pop("The card fields are gone", mark: "exclamationmark.triangle")
                            }
                        }
                    }
                }
            }
        case .address:
            guard list.addresses.indices.contains(index) else { return }
            let address = list.addresses[index]
            tab.walletFill(address.filling, what: .address, origin: list.origin) { filled in
                guard filled > 0 else { return }
                DispatchQueue.global(qos: .utility).async { Wallet.touch(address: address.id, on: site) }
            }
        case .phone:
            guard list.phones.indices.contains(index) else { return }
            tab.walletFill(["phone": list.phones[index].number], what: .phone, origin: list.origin) { _ in }
        case .form:
            break
        }
    }

    /// The page went: a new document, or an app's next step at a new
    /// address. Its lists go with it, and the form read off it, so nothing
    /// of the last step hangs over the next one.
    func walletPageLeft(_ tab: Tab) {
        tab.wallet.beat += 1
        tab.wallet.form.plan = nil
        tab.wallet.form.planned = .distantPast
        if walletList?.tab == tab.id { walletLowering?.cancel(); walletList = nil }
        if codeList?.tab == tab.id { codeList = nil }
        if codeWatch.tab == tab.id { codeWatch.stop() }
    }

    /// An address without its #section.
    static func unhashed(_ url: URL?) -> String? {
        guard let url else { return nil }
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        parts?.fragment = nil
        return parts?.string ?? url.absoluteString
    }

    /// Escape, or the tab gone. On a form's or an address's box it is a no
    /// for the page: its next box doesn't ask again, and ⌥↩ still fills.
    func dropWallet() {
        if let list = walletList, list.group == .form || list.group == .address, let tab = autofillTab(list.tab) {
            tab.wallet.declined = WalletWatch.page(tab.address)
        }
        walletList = nil
    }

    /// ↑ and ↓, round the ends; All Cards or All Addresses is the last row.
    func moveWallet(_ by: Int) {
        guard let list = walletList else { return }
        let count = list.count + (list.all ? 1 : 0)
        walletLit = walletShown.map { ($0 + by + count) % count } ?? (by > 0 ? 0 : count - 1)
        walletChosen = true
    }

    /// The pointer on a row lights it, as the arrows do.
    func pointWallet(_ at: Int) {
        walletLit = at
        walletChosen = true
    }

    /// The row lit now: the first while the box is empty, one the arrows or
    /// the pointer came to at any time. With words typed into the box and
    /// no row chosen, none is, and Return sends the form as it would.
    var walletShown: Int? { walletChosen || walletBoxEmpty ? walletLit : nil }

    /// Return on a lit row; false when none is lit, so the key is the page's.
    func chooseWalletLit() -> Bool {
        guard let walletLit = walletShown, let list = walletList else { return false }
        let count = list.count
        if walletLit == count, list.all {
            openAll(.autofill)
            return true
        }
        guard walletLit < count else { return false }
        chooseWallet(walletLit)
        return true
    }

    // MARK: - keeping a new one

    /// A card, an address or both went through. Whatever is already kept
    /// is marked used and not asked about; a kept card with a new date is
    /// asked about as an update.
    func paid(_ tab: Tab, card seen: SeenCard?, address: StreetAddress?, host: String) {
        guard prefs.savesCards, !tab.shy else { return }
        let site = Browser.site(host)
        DispatchQueue.global(qos: .userInitiated).async {
            var card: SavedCard?
            var was: String?
            if let seen, seen.keepable {
                let fresh = SavedCard(id: UUID().uuidString, number: seen.number, last4: String(seen.number.suffix(4)),
                                 brand: Wallet.brand(of: seen.number), name: seen.name, month: seen.month, year: seen.year,
                                 used: Date(), saved: nil, usedOn: site, csc: seen.csc)
                if let same = Wallet.card(numbered: seen.number) {
                    if same.month == seen.month, same.year == seen.year {
                        Wallet.touch(card: same.id, on: site)
                        // Its code, as it was just typed, for the next time.
                        if !seen.csc.isEmpty, Wallet.securityCode(of: same.id) != seen.csc {
                            Wallet.update(card: same.id) { $0.csc = seen.csc }
                        }
                    } else {
                        card = fresh
                        card?.id = same.id
                        if seen.name.isEmpty { card?.name = same.name }
                        if seen.csc.isEmpty { card?.csc = Wallet.securityCode(of: same.id) ?? "" }
                        card?.billing = same.billing
                        card?.nickname = same.nickname
                        card?.source = same.source
                        was = same.expiry
                    }
                } else {
                    card = fresh
                }
            }
            var kept: StreetAddress?
            if var address {
                if let same = Wallet.addresses().first(where: { $0.same(as: address) }) {
                    Wallet.touch(address: same.id, on: site)
                } else {
                    address.used = Date()
                    address.usedOn = site
                    kept = address
                }
            }
            DispatchQueue.main.async { [weak self, weak tab] in
                guard let self, let tab, card != nil || kept != nil else { return }
                if tab.payOffer?.alreadyOffers(card: card, address: kept, site: site) == true { return }
                var sites: Set<String> = [Browser.site(host)]
                if let here = tab.address?.host() { sites.insert(Browser.site(here)) }
                var offer = PayOffer(card: card, was: was, address: kept, sites: sites)
                // An address from the step before and a card from this one
                // are one question.
                if let old = tab.payOffer, !old.refused {
                    if offer.card == nil { offer.card = old.card; offer.was = old.was }
                    if offer.address == nil { offer.address = old.address }
                    offer.sites.formUnion(old.sites)
                }
                offer.parked = tab.id != activeID
                withAnimation(Motion.reshape) { tab.payOffer = offer }
            }
        }
    }

    /// Kept at once as far as the card goes; if the keychain refuses, the
    /// card comes back saying so.
    func keepPay(_ tab: Tab) {
        guard let offer = tab.payOffer, offer.anything else { return }
        // Saving is rare, so it may have the one flourish: the mark flies
        // to the tab, the path a password's key takes, and sits there a
        // beat. Nothing is said: the flight was the answer.
        let mark = offer.keptMark
        if flyPay(tab, mark: mark, parking: false) {
            tab.payOffer?.folding = true
            tab.payOffer?.flying = true
            DispatchQueue.main.async { [weak tab] in
                guard let tab, tab.payOffer?.id == offer.id else { return }
                withAnimation(Motion.depart) { tab.payOffer = nil }
            }
        } else {
            withAnimation(Motion.depart) { tab.payOffer = nil }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            var ok = true
            if offer.keepsCard, let card = offer.card { ok = Wallet.save(card) && ok }
            if offer.keepsAddress, let address = offer.address { ok = Wallet.save(address) && ok }
            DispatchQueue.main.async { [weak self, weak tab] in
                guard let self, let tab, !ok, tab.payOffer == nil else { return }
                var back = offer
                back.refused = true
                back.parked = tab.id != activeID
                withAnimation(Motion.reshape) { tab.payOffer = back }
            }
        }
    }

    func tickPay(_ tab: Tab, card: Bool? = nil, address: Bool? = nil) {
        guard var offer = tab.payOffer else { return }
        if let card { offer.keepsCard = card }
        if let address { offer.keepsAddress = address }
        tab.payOffer = offer
    }

    /// Not now: onto the tab, a card where its mark was, until it is
    /// clicked or the tab leaves the site.
    func parkPay(_ tab: Tab) {
        guard var offer = tab.payOffer, !offer.parked else { return }
        guard !offer.refused else { return dismissPay(tab) }
        // Down into its mark, and the mark onto the tab, as a password's.
        let flies = flyPay(tab, mark: offer.mark, parking: true)
        tab.payOffer?.folding = flies
        offer.folding = flies
        offer.flying = flies
        offer.parked = true
        DispatchQueue.main.async { [weak tab] in
            guard let tab, tab.payOffer?.id == offer.id else { return }
            withAnimation(Motion.depart) { tab.payOffer = offer }
        }
    }

    /// The card's mark from the well to the tab. Parking, it lands as the
    /// offer waiting there; kept, it stays on the tab a beat, then the
    /// site's mark comes back. False when it can't fly (reduced motion,
    /// no place for it), and the card just goes.
    private func flyPay(_ tab: Tab, mark: String, parking: Bool) -> Bool {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let from = keySky.pills[tab.id], let to = keySky.marks[tab.id], to.width > 0 else { return false }
        let flight = KeyFlight(from: from, to: to, icon: nil, letter: "", parking: parking, pay: mark)
        keySky.flight = flight
        DispatchQueue.main.asyncAfter(deadline: .now() + KeyFlight.time) { [weak self, weak tab] in
            guard let self, keySky.flight?.id == flight.id else { return }
            var landing = Transaction()
            landing.disablesAnimations = true
            withTransaction(landing) {
                self.keySky.flight = nil
                if parking {
                    tab?.payOffer?.flying = false
                } else {
                    tab?.payLanded = mark
                }
            }
            guard !parking else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak tab] in
                guard tab?.payLanded == mark else { return }
                withAnimation(Motion.quick) { tab?.payLanded = nil }
            }
        }
        return true
    }

    func unparkPay(_ tab: Tab) {
        guard var offer = tab.payOffer, offer.parked else { return }
        if activeID != tab.id { select(tab) }
        offer.parked = false
        offer.folding = false
        offer.flying = false
        withAnimation(Motion.arrive) { tab.payOffer = offer }
    }

    func dismissPay(_ tab: Tab) {
        withAnimation(Motion.depart) { tab.payOffer = nil }
    }

    /// Gone to another tab: a question still open waits on the tab left.
    func payLeft(_ tab: Tab) {
        guard tab.payOffer?.parked == false else { return }
        parkPay(tab)
    }

    /// The tab went somewhere else. Anywhere but where it paid, or where
    /// that landed, and the offer goes; a moment after it is made, a new
    /// place is taken as more of the payment landing.
    func payMoved(_ tab: Tab, to url: URL) {
        tab.walletSettle(navigated: true)
        if fileWaiting(for: tab) { cancelFileAnswer() }
        tab.wallet.form.guided = nil
        // Answers sent: kept once the new page is there.
        if let at = tab.wallet.answered?.at {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak tab] in
                guard let tab, tab.wallet.answered?.at == at else { return }
                tab.answersSettle()
            }
        }
        guard let offer = tab.payOffer, let host = url.host() else { return }
        let site = Browser.site(host)
        guard !offer.sites.contains(site) else { return }
        if Date().timeIntervalSince(offer.at) < 4 {
            tab.payOffer?.sites.insert(site)
            return
        }
        withAnimation(offer.parked ? Motion.quick : Motion.depart) { tab.payOffer = nil }
    }
}

// MARK: - the list

/// The cards or addresses kept, hanging from the box the caret is in, drawn
/// as the sign-in accounts are.
struct WalletList: View {
    var browser: Browser
    let list: Browser.WalletChoices

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let offer = list.form {
                FormFillRow(offer: offer, lit: browser.walletShown == 0, point: { browser.pointWallet(0) }) { browser.chooseWallet(0) }
            }
            if list.knowMe {
                let at = list.form == nil ? 0 : 1
                KnowMeRow(lit: browser.walletShown == at, point: { browser.pointWallet(at) }) { browser.chooseWallet(at) }
            }
            switch list.group {
            case .card:
                ForEach(Array(list.cards.enumerated()), id: \.element.id) { index, card in
                    // A date that is close is said in words, in the warning's color.
                    FieldListRow(title: card.nickname.isEmpty ? card.shortTitle : "\(card.nickname), \(card.last4)",
                                 detail: card.soon ?? [card.name, "expires \(card.expiry)"].filter { !$0.isEmpty }.joined(separator: " · "),
                                 used: card.used, lit: browser.walletShown == index + list.first, warn: card.soon != nil,
                                 point: { browser.pointWallet(index + list.first) },
                                 pick: { browser.chooseWallet(index + list.first) }) {
                        PayMark(kind: card.brand, height: 16)
                            .frame(width: 26, height: 20)
                    }
                }
            case .address:
                // The street first, its apartment never cut; a name only
                // when the addresses are more than one person's.
                let people = Set(list.addresses.map(\.name).filter { !$0.isEmpty }).count > 1
                // In a name or an email box, that is what the row says,
                // the street under it: the box shows what goes in it.
                ForEach(Array(list.addresses.enumerated()), id: \.element.id) { index, address in
                    let own = address.listOwn(list.box)
                    let street = address.listStreet.isEmpty ? address.title : address.listStreet
                    FieldListRow(title: own ?? street,
                                 detail: own != nil
                                    ? [[address.listStreet, address.listUnit].filter { !$0.isEmpty }.joined(separator: " "), address.listPlace].filter { !$0.isEmpty }.joined(separator: " · ")
                                    : [address.listPlace, people ? address.shortName : ""].filter { !$0.isEmpty }.joined(separator: " · "),
                                 used: address.used, lit: browser.walletShown == index + list.first, unit: own != nil ? "" : address.listUnit,
                                 point: { browser.pointWallet(index + list.first) },
                                 pick: { browser.chooseWallet(index + list.first) }) {
                        FieldListWell(glyph: address.mark)
                    }
                }
            case .phone:
                ForEach(Array(list.phones.enumerated()), id: \.element.id) { index, phone in
                    FieldListRow(title: phone.number, detail: phone.from, used: nil,
                                 lit: browser.walletShown == index + list.first,
                                 point: { browser.pointWallet(index + list.first) },
                                 pick: { browser.chooseWallet(index + list.first) }) {
                        FieldListWell(glyph: "phone")
                    }
                }
            case .form:
                EmptyView()
            }
            // Everything kept, in the box's Cards and Addresses, a pick
            // filling this box.
            if list.all {
                FieldListRow(title: list.group == .card ? "All Cards" : "All Addresses", detail: "", used: nil,
                             lit: browser.walletShown == list.count, point: { browser.pointWallet(list.count) },
                             pick: { browser.openAll(.autofill) }) {
                    // In the cards' own column, which is as wide as a card's mark,
                    // so its words start where theirs do.
                    FieldListWell(glyph: list.group == .card ? "creditcard" : "book.pin")
                        .frame(width: list.group == .card ? 26 : 20)
                }
            }
        }
        .dropFrame(width: max(280, min(360, list.spot.width)))
        .pageScheme(dark: list.dark)
        .offset(x: list.spot.minX, y: list.spot.maxY + 6)
    }

}

// MARK: - the card over the page

/// The question, drawn as the password's (KeepCard): a card in a quiet
/// well, the question and a line under it, or with both a card and an
/// address, a box for each; Not now and Save on the right.
struct PayCard: View {
    var browser: Browser
    var tab: Tab
    let offer: PayOffer

    static let width: CGFloat = 400

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            well.padding(.bottom, 12)
            Text(title)
                .font(CardFrame.title)
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            if !detail.isEmpty {
                Text(detail)
                    .font(CardFrame.detail)
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            if offer.both, !offer.refused { picks.padding(.top, 10) }
            foot.padding(.top, CardFrame.buttonGap)
        }
        .frame(width: Self.width - CardFrame.inset * 2, alignment: .leading)
        .cardFrame(glass: true)
    }

    private var well: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        return shape.fill(Palette.ink.opacity(0.05))
            .overlay(shape.strokeBorder(Palette.ink.opacity(0.08), lineWidth: 0.5))
            .overlay {
                PayMark(kind: offer.mark, height: 18, tint: offer.refused ? Palette.muted : Palette.ink)
                    .opacity(offer.flying ? 0 : 1)
                    // Where the mark takes off from, as the password card's.
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { [id = tab.id, sky = browser.keySky] in
                        sky.pills[id] = $0
                    }
            }
            .frame(width: CardFrame.well, height: CardFrame.well)
    }

    private var title: String {
        if offer.refused { return "The keychain didn’t save it" }
        if offer.both { return offer.was == nil ? "Save card and address?" : "Update card and save address?" }
        if let card = offer.card { return offer.was == nil ? "Save card for next time?" : "Update \(card.title)?" }
        return "Save address for next time?"
    }

    private var detail: String {
        if offer.refused { return "macOS refused to write it. Try again, or add it in Cards and Addresses." }
        if offer.both { return "" }
        if let card = offer.card {
            if let was = offer.was { return "It expires \(card.expiry) now, not \(was)." }
            return "\(card.title), expires \(card.expiry)." + (card.csc.isEmpty ? "" : " Its security code is kept with it.")
        }
        guard let address = offer.address else { return "" }
        return [address.title, address.place].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// With both, a box for each: the card, then the address.
    @ViewBuilder
    private var picks: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let card = offer.card {
                pick(offer.was == nil ? "\(card.title), \(card.expiry)" : "\(card.title), now \(card.expiry)",
                     on: offer.keepsCard) { browser.tickPay(tab, card: $0) }
            }
            if let address = offer.address {
                pick([address.line1, address.city].filter { !$0.isEmpty }.joined(separator: ", "),
                     on: offer.keepsAddress) { browser.tickPay(tab, address: $0) }
            }
        }
    }

    private func pick(_ words: String, on: Bool, _ set: @escaping (Bool) -> Void) -> some View {
        Toggle(isOn: Binding(get: { on }, set: set)) {
            Text(words)
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .toggleStyle(.checkbox)
        .controlSize(.small)
    }

    private var foot: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 8)
            if offer.refused {
                press("Close", .quiet, key: "esc") { browser.dismissPay(tab) }
                press("Try Again", .primary, key: "⏎") { browser.keepPay(tab) }
            } else {
                press("Not Now", .secondary, key: "esc") { browser.parkPay(tab) }
                press(offer.was != nil && !offer.both ? "Update" : "Save", .primary, key: "⏎") { browser.keepPay(tab) }
                    .disabled(!offer.anything)
            }
        }
    }

    private func press(_ title: String, _ kind: ButtonKind, key: String? = nil, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            HStack(spacing: 6) {
                Text(title)
                if let key, shows {
                    KeyGlyphs(keys: key, size: CardFrame.words, tint: nil, rest: 0.6)
                        .transaction { $0.animation = nil }
                }
            }
        }
        .buttonStyle(.yab(kind, CardFrame.button))
        .fixedSize()
    }

    /// Whether Return and Escape reach the card now (KeepCard's rule).
    private var shows: Bool {
        !tab.typing && !browser.fieldShowing && !browser.finding && browser.editingTab == nil
            && !browser.welcoming
    }
}

// MARK: - the network's mark

/// A card's network as it is printed on the card and at every till: Visa's
/// word, Mastercard's two circles, Amex's box, on a small white card. Not
/// the card's own art, which only the network hands out. "house" is an
/// address's mark, and a network without a mark of its own is its name.
struct PayMark: View {
    let kind: String
    var height: CGFloat
    var tint: Color = Palette.ink
    /// Dark: a white card would be the brightest thing in the list, so
    /// Visa is its own word in white on its blue, as it prints on dark,
    /// and the other networks sit on a dark card of their own.
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let width = (height * 1.55).rounded()
        let shape = RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
        switch kind {
        case "house":
            Symbol("house", size: height * 0.7).foregroundStyle(tint)
        case "American Express":
            shape.fill(Color(red: 0.12, green: 0.45, blue: 0.80))
                .overlay { word("AMEX", size: height * 0.36, color: .white, italic: false) }
                .frame(width: width, height: height)
        case "Mastercard", "Maestro":
            chip(shape, width: width) {
                let side = height * 0.6
                HStack(spacing: -side * 0.36) {
                    Circle().fill(kind == "Maestro" ? Color(red: 0.0, green: 0.62, blue: 0.87) : Color(red: 0.92, green: 0.0, blue: 0.11))
                        .frame(width: side, height: side)
                    Circle().fill(Color(red: 0.97, green: 0.62, blue: 0.11).opacity(0.9))
                        .frame(width: side, height: side)
                }
            }
        case "Visa":
            if scheme == .dark {
                shape.fill(Color(red: 0.10, green: 0.12, blue: 0.44))
                    .overlay { word("VISA", size: height * 0.46, color: .white, italic: true) }
                    .frame(width: width, height: height)
            } else {
                chip(shape, width: width) { word("VISA", size: height * 0.46, color: Color(red: 0.10, green: 0.12, blue: 0.44), italic: true) }
            }
        // Too long a word to read this small: the part of each network's
        // mark that is known on its own.
        case "Discover":
            chip(shape, width: width) {
                Circle().fill(Color(red: 0.96, green: 0.51, blue: 0.13)).frame(width: height * 0.5, height: height * 0.5)
            }
        case "Diners Club":
            chip(shape, width: width) {
                Circle().strokeBorder(Color(red: 0.0, green: 0.36, blue: 0.67), lineWidth: max(1, height * 0.1))
                    .frame(width: height * 0.56, height: height * 0.56)
            }
        case "UnionPay":
            shape.fill(Color(red: 0.84, green: 0.13, blue: 0.19))
                .overlay { word("UP", size: height * 0.42, color: .white, italic: false) }
                .frame(width: width, height: height)
        case "JCB":
            chip(shape, width: width) { word("JCB", size: height * 0.42, color: Color(red: 0.0, green: 0.36, blue: 0.67), italic: false) }
        default:
            Symbol("creditcard.2", size: height * 0.7).foregroundStyle(tint)
        }
    }

    private func chip<Inner: View>(_ shape: RoundedRectangle, width: CGFloat, @ViewBuilder _ inner: () -> Inner) -> some View {
        let dark = scheme == .dark
        return shape.fill(dark ? Color(white: 0.23) : Color.white)
            .overlay(shape.strokeBorder(dark ? Color.white.opacity(0.14) : Color.black.opacity(0.14), lineWidth: 0.5))
            .overlay { inner() }
            .frame(width: width, height: height)
    }

    private func word(_ text: String, size: CGFloat, color: Color, italic: Bool) -> some View {
        Text(text)
            .font(.system(size: size, weight: .heavy))
            .italic(italic)
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .padding(.horizontal, 2)
    }
}
