import AppKit
import Combine
import LocalAuthentication
import LocalAuthenticationEmbeddedUI
import SwiftUI

// A payment an agent waits on, from the question to what the site said.
//
// The agent never pays: it presses the site's own button once you have put
// a finger on the sensor (or typed the Mac's password), in a sheet that
// stands in the chat field's place (PaySheet). The sheet outlives the
// question: after the yes it shows the site being pressed, then Paid or
// what the site said no to, and a card picked there is put into the page,
// with the same Touch ID, before the press. Nothing here is Apple Pay: the
// site's checkout takes the card, as it would from you.

@MainActor
@Observable final class Payments {
    static let shared = Payments()

    /// The sheet of each tab that has one.
    private(set) var flows: [UUID: PayFlow] = [:]

    func flow(_ tab: Tab) -> PayFlow? { flows[tab.id] }

    /// The agent asks to pay: a sheet for it, or the one already up takes
    /// the new question (the amount rolls to what the page says now).
    func begin(_ tab: Tab, _ permit: AgentPermit) {
        if let flow = flows[tab.id], flow.session == permit.session {
            flow.asked(permit)
            return
        }
        flows[tab.id]?.stop()
        // A checkout's frames that drew their card's boxes after loading look
        // now, while the sheet is up: no frame watches its page for them.
        tab.walletLook()
        flows[tab.id] = PayFlow(tab: tab, permit: permit)
    }

    /// The question was answered somewhere else than the sheet: on another
    /// device, or by the task ending.
    func answered(_ tab: Tab, _ permit: AgentPermit, yes: Bool) {
        guard let flow = flows[tab.id], !flow.answering else { return }
        if yes { flow.paidElsewhere() } else { end(tab) }
    }

    func end(_ tab: Tab) { end(tab.id) }

    func end(_ id: UUID) {
        guard let flow = flows[id] else { return }
        flow.stop()
        // A yes from another device waits on what came of it.
        ApprovalDetails.shared.payEnded(tab: id)
        withAnimation(Motion.depart) { flows[id] = nil }
    }

    /// A task over: a sheet still asking goes with it. One the site has
    /// answered stays, Paid until it goes by itself, declined with Pay to
    /// try again (Yab presses the button then) or Esc to leave.
    func left(session: String) {
        for (id, flow) in flows where flow.session == session && [.ready, .armed, .checking].contains(flow.model.phase) { end(id) }
    }
}

extension AgentPermit {
    /// A press that pays: the pay sheet's, never the plaque's.
    var isPayment: Bool {
        if case .press = kind { return pays }
        return false
    }
}

@MainActor
@Observable final class PayFlow: Identifiable {
    var model: PaySheetModel
    /// The form's boxes, kept here so a list and back doesn't lose them.
    var form = Form()
    /// The page has been read once (delivery, card and address boxes).
    private(set) var looked = false

    @ObservationIgnored weak var tab: Tab?
    let session: String
    /// The press asked for, to make it again after a decline.
    @ObservationIgnored private(set) var ref: String
    @ObservationIgnored private(set) var label: String
    /// True while the sheet itself answers the question, so that answer
    /// isn't taken for one given elsewhere.
    @ObservationIgnored private(set) var answering = false

    let touch = PayTouch()
    /// A test run keeps the sheet on Paid for its picture (bench `agent-pay`).
    static var holdPaid = false
    @ObservationIgnored private var watching: Task<Void, Never>?
    @ObservationIgnored private var listening: AnyCancellable?

    struct Form: Equatable {
        var name = "", street = "", apt = "", city = "", zip = ""
        var number = "", expires = "", code = "", holder = ""
    }

    init(tab: Tab, permit: AgentPermit) {
        self.tab = tab
        session = permit.session
        (ref, label) = Self.press(permit)
        let site = Browser.site(tab.address?.host() ?? "")
        model = PaySheetModel(site: site, item: Self.item(permit, site: site), amount: permit.amount)
        model.cards = PayWallet.cards().filter { !$0.expired }.map(PaySheetModel.Card.init)
        model.places = PayWallet.addresses().map(PaySheetModel.Place.init)
        model.card = model.cards.first?.id
        model.place = PayWallet.preferredAddress()?.id ?? model.places.first?.id
        if Store.testing, let stub = PayTouch.stub { model.proof = stub.proof }
        else if !PayTouch.canTouch { model.proof = .password }
        look()
        // Back to the app: Touch ID listens again where it had to stop.
        listening = NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.listen() } }
    }

    private static func press(_ permit: AgentPermit) -> (ref: String, label: String) {
        if case .press(let label, let ref) = permit.kind { return (ref, label) }
        return ("", "")
    }

    /// What is bought, in a line: the page's own heading for its checkout,
    /// never the site's name twice.
    private static func item(_ permit: AgentPermit, site: String) -> String {
        let words = permit.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        return words.lowercased() == site.lowercased() ? "" : words
    }

    func stop() {
        watching?.cancel()
        watching = nil
        touch.stop()
        listening = nil
    }

    // MARK: - what the page has

    /// Reads off the page what the sheet says beside the permit: when it
    /// arrives, which card it shows, whether it has boxes to put another
    /// card or address into.
    private func look() {
        guard let tab else { return }
        AgentPage.run(tab, Self.lookScript) { [weak self] result in
            guard let self else { return }
            // Read or not, the sheet says what it can: its detail goes to
            // the other devices from now (ApprovalDetails).
            defer { self.looked = true }
            guard case .success(let value) = result, let out = value as? [String: Any] else { return }
            var model = self.model
            model.delivery = out["delivery"] as? String ?? ""
            model.takesCard = out["card"] as? Bool ?? false
            model.takesPlace = out["place"] as? Bool ?? false
            // The card the page shows, by its last four, if Yab keeps it;
            // else one Yab put into its boxes.
            let shown = out["last4"] as? String ?? ""
            let filled = Wallet.filled.map { String($0.suffix(4)) }
            if let card = model.cards.first(where: { !shown.isEmpty && $0.last4 == shown }) ?? model.cards.first(where: { filled.contains($0.last4) }) {
                model.card = card.id
            } else if !shown.isEmpty {
                // A card the site keeps and Yab doesn't: said as the site has it.
                model.cards.insert(.init(id: "page", brand: Self.brand(out["brand"] as? String ?? ""), last4: shown, name: "On \(model.site)"), at: 0)
                model.card = "page"
            }
            self.model = model
            self.listen()
        }
        listen()
    }

    private static func brand(_ said: String) -> String {
        switch said.lowercased() {
        case "visa": return "Visa"
        case "mastercard", "master card": return "Mastercard"
        case "amex", "american express": return "American Express"
        case "discover": return "Discover"
        default: return "Card"
        }
    }

    static let lookScript = """
    const text = (document.body && document.body.innerText) || '';
    const lines = text.split('\\n').map(s => s.replace(/\\s+/g, ' ').trim()).filter(Boolean);
    const delivery = lines.find(l => l.length < 80 && /^(arrives|arriving|delivery|estimated delivery|get it|ships|delivers)\\b/i.test(l)) || '';
    const card = !!document.querySelector('input[autocomplete~="cc-number" i],input[name*="cardnumber" i],input[name*="card_number" i],input[name*="card-number" i],input[id*="cardnumber" i],iframe[src*="js.stripe.com"],iframe[name^="__privateStripeFrame"],iframe[src*="braintreegateway.com"],iframe[src*="adyen.com"]');
    const place = !!document.querySelector('input[autocomplete~="address-line1" i],input[autocomplete~="street-address" i],input[name*="address1" i],input[name*="street" i],input[id*="address1" i]');
    const four = text.match(/(visa|mastercard|master card|amex|american express|discover)?[^\\n\\d]{0,12}(?:ending in|ends in|•{2,}|\\*{2,}|x{4})\\s*(\\d{4})\\b/i);
    return { delivery, card, place, last4: four ? four[2] : '', brand: four && four[1] ? four[1] : '' };
    """

    // MARK: - the person

    func open(_ pane: PaySheetModel.Pane) {
        model.open(pane)
        listen()
    }

    func back() {
        model.back()
        listen()
    }

    func pick(_ index: Int) {
        let before = model.place
        model.pick(index)
        if model.pane.isForm { form = Form() }
        if model.place != before, let place = model.place { fill(place: place) }
        listen()
    }

    /// A key from the field or the page, while the sheet is up.
    func key(_ key: PaySheetModel.Key) -> PaySheetModel.Effect {
        let effect = model.key(key)
        switch effect {
        case .cancel: cancel()
        case .arm: arm()
        case .needsKeys:
            Agents.shared.browser?.toaster.pop("\(model.words(.pay)) with", mark: "hand.raised", keys: Keymap.shared.keys(.confirmDanger)?.caps ?? [])
        case .needsFinger:
            Agents.shared.browser?.toaster.pop("Pay with Touch ID", mark: "hand.raised")
        case .save: save()
        case .none, .ignored: break
        }
        listen()
        return effect
    }

    func cancel() {
        guard model.cancellable, let tab else { return }
        if tab.permit?.isPayment == true, tab.permit?.session == session {
            answering = true
            Agents.shared.answer(tab, yes: false)
            answering = false
        }
        Payments.shared.end(tab)
    }

    // MARK: - the forms

    var canSave: Bool {
        switch model.pane {
        case .newPlace: return PaySheetModel.placeFilled(street: form.street, city: form.city, zip: form.zip)
        case .newCard: return PaySheetModel.cardFilled(number: form.number, expires: form.expires)
        default: return false
        }
    }

    /// Kept in Yab (Settings › Autofill), picked, and the sheet back to paying.
    func save() {
        guard canSave else { return }
        switch model.pane {
        case .newPlace:
            var address = StreetAddress(id: UUID().uuidString)
            address.name = form.name.trimmingCharacters(in: .whitespaces)
            address.street = [form.street, form.apt].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "\n")
            address.city = form.city.trimmingCharacters(in: .whitespaces)
            address.postal = form.zip.trimmingCharacters(in: .whitespaces)
            address.source = "Yab"
            PayWallet.save(address)
            withAnimation(Motion.reshape) { model.added(PaySheetModel.Place(address.tidied())) }
            fill(place: address.id)
        case .newCard:
            guard let (month, year) = PaySheetModel.expiry(form.expires) else { return }
            let digits = form.number.filter(\.isNumber)
            let card = SavedCard(id: UUID().uuidString, number: digits, last4: String(digits.suffix(4)), brand: Wallet.brand(of: digits),
                                 name: form.holder.trimmingCharacters(in: .whitespaces), month: month, year: year,
                                 csc: form.code.filter(\.isNumber))
            guard PayWallet.save(card) else { return }
            withAnimation(Motion.reshape) { model.added(PaySheetModel.Card(card)) }
        default:
            return
        }
        form = Form()
        listen()
    }

    // MARK: - Touch ID

    /// Touch ID listens once Pay was pressed, while the sheet shows what is
    /// paid for, and stops while a list or a form is open, so a finger
    /// there pays nothing.
    func listen() {
        guard model.listening, !touch.stubbed else { touch.stop(); return }
        guard NSApp.isActive else { return }
        touch.listen(reason: "pay \(model.amount) on \(model.site)") { [weak self] answer in
            self?.heard(answer)
        }
    }

    /// A click on the foot's button. Pay arms the check; Use Password
    /// opens the password's dialog; Touch ID itself waits for the finger.
    func press() {
        switch model.face {
        case .pay, .password: arm()
        case .touch, .checking, .paying, .paid: break
        }
    }

    /// Pay pressed (a click or ⌘↩): Touch ID listens from now, or, where
    /// there's no finger to give, the password's dialog. Nothing is paid
    /// by the press itself.
    func arm() {
        guard model.pane == .main else { return }
        if model.proof == .touchID {
            guard model.armable else { return }
            withAnimation(Motion.arrive) { model.arm() }
            listen()
            return
        }
        guard model.armable || model.phase == .armed else { return }
        withAnimation(Motion.arrive) { model.asking() }
        if touch.stubbed, let stub = PayTouch.stub {
            DispatchQueue.main.asyncAfter(deadline: .now() + stub.delay) { [weak self] in self?.heard(stub.answer) }
            return
        }
        touch.password(reason: "pay \(model.amount) on \(model.site)") { [weak self] answer in self?.heard(answer) }
    }

    /// A finger on the sensor in a test world: the stand-in's answer, heard
    /// only while the check is armed (bench `agent-pay touch`).
    func finger() {
        guard model.listening, touch.stubbed, let stub = PayTouch.stub else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + stub.delay) { [weak self] in
            guard let self, self.model.listening else { return }
            self.heard(stub.answer)
        }
    }

    private func heard(_ answer: PaySheetModel.Answer) {
        let wasLocked = model.locked
        let yes = withAnimation(Motion.arrive) { model.answered(answer) }
        if yes, !wasLocked {
            pay()
        } else if answer == .miss || answer == .locked {
            listen()
        }
    }

    // MARK: - paying

    /// The yes: the card picked here into the page, the page's own words
    /// read again so the press matches what the sheet showed, then the
    /// press, by the agent the first time and by Yab on a retry.
    private func pay() {
        guard let tab else { return }
        put(card: model.cardPicked ? model.card : nil, in: tab) { [weak self] in
            guard let self else { return }
            self.reread { [weak self] _ in
                guard let self, let tab = self.tab else { return }
                if let permit = tab.permit, permit.isPayment, permit.session == self.session {
                    self.answering = true
                    Agents.shared.answer(tab, yes: true)
                    self.answering = false
                    self.watch(pressed: false)
                } else {
                    // The question is over (declined before): Yab presses
                    // the same button, with this yes.
                    if !self.model.amount.isEmpty { AgentRules.shared.spend(self.model.amount) }
                    self.pressAgain(tab)
                    self.watch(pressed: true)
                }
            }
        }
    }

    /// How long a card or an address just kept on another device is waited
    /// for, until Sync has put it into Wallet here.
    static let addedWait: TimeInterval = 10

    /// A yes from another device that picked a card or an address there
    /// (docs/approvals.md, "Details"): each picked here as a click in Pay
    /// With or Ship To picks it, the address put into the page, then the
    /// card, and the page's total read again, all before the yes goes to
    /// the agent's press. One just kept on that device (`added`) is waited
    /// for until Sync has taken it into Wallet. False: it never came, or
    /// the sheet can't take it; then nothing is pressed.
    func takePicks(card: String?, place: String?, added: Set<String>, then done: @escaping (Bool) -> Void) {
        let until = Date().addingTimeInterval(Self.addedWait)
        func arrive() {
            guard tab != nil else { done(false); return }
            var waiting = false
            if let card, !model.cards.contains(where: { $0.id == card }) {
                if added.contains(card), let kept = PayWallet.cards().first(where: { $0.id == card && !$0.expired }) {
                    withAnimation(Motion.reshape) { model.added(PaySheetModel.Card(kept)) }
                } else { waiting = true }
            }
            if let place, !model.places.contains(where: { $0.id == place }) {
                if added.contains(place), let kept = PayWallet.addresses().first(where: { $0.id == place }) {
                    withAnimation(Motion.reshape) { model.added(PaySheetModel.Place(kept)) }
                } else { waiting = true }
            }
            if waiting {
                guard Date() < until else { done(false); return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { arrive() }
                return
            }
            picked()
        }
        func picked() {
            guard let tab else { done(false); return }
            if let card, model.card != card || !model.cardPicked {
                // The one the sheet showed already is put in too: the
                // phone said this card.
                if model.card == card { model.cardPicked = true }
                else if !model.choose(card: card) { done(false); return }
            }
            let before = model.place
            if let place, model.place != place || !model.placePicked {
                if model.place == place { model.placePicked = true }
                else if !model.choose(place: place) { done(false); return }
            }
            let fresh = place.map { $0 != before || added.contains($0) } ?? false
            let go = { [weak self] in
                guard let self else { done(false); return }
                self.put(card: card != nil && self.model.cardPicked ? self.model.card : nil, in: tab) { [weak self] in
                    guard let self else { done(false); return }
                    self.reread { _ in done(true) }
                }
            }
            if fresh, let place { fill(place: place, then: go) } else { go() }
        }
        arrive()
    }

    /// Yes on another device: the sheet shows the site being pressed.
    func paidElsewhere() {
        touch.stop()
        guard withAnimation(Motion.arrive, { model.answered(.yes) }) else { return }
        watch(pressed: false)
    }

    /// The agent asked again (after a decline, or with a new total).
    func asked(_ permit: AgentPermit) {
        (ref, label) = Self.press(permit)
        watching?.cancel()
        withAnimation(Motion.reshape) {
            model.asked(amount: permit.amount, item: Self.item(permit, site: model.site))
        }
        listen()
    }

    private func put(card id: String?, in tab: Tab, then: @escaping () -> Void) {
        // A card goes only into a page that came over https, as the agent's own fill.
        guard let id, id != "page", tab.address?.scheme == "https" || Tab.local(tab.address),
              let card = PayWallet.cards().first(where: { $0.id == id }) else { then(); return }
        let origin = Tab.originOf(tab.address), site = model.site
        DispatchQueue.global(qos: .userInitiated).async {
            let number = PayWallet.number(of: card.id)
            let code = PayWallet.securityCode(of: card.id) ?? ""
            let home = Wallet.billing(of: card, among: PayWallet.addresses())
            DispatchQueue.main.async { [weak tab] in
                guard let tab, let number else { then(); return }
                let data: [String: Any] = ["number": number, "name": card.name, "month": card.month, "year": card.year, "csc": code,
                                           "postal": home?.postal ?? "", "country": home?.country ?? "", "billing": home?.filling ?? [:]]
                tab.walletFill(data, what: .card, origin: origin) { filled in
                    if filled > 0 { DispatchQueue.global(qos: .utility).async { PayWallet.touch(card: card.id, on: site) } }
                    then()
                }
            }
        }
    }

    /// An address picked here goes into the page at once; the site may
    /// charge another shipping for it, so its total is read again after.
    private func fill(place id: String, then: (() -> Void)? = nil) {
        guard let tab, model.takesPlace, let address = PayWallet.addresses().first(where: { $0.id == id }) else { then?(); return }
        let origin = Tab.originOf(tab.address), site = model.site
        tab.walletFill(address.filling, what: .address, origin: origin) { [weak self] filled in
            then?()
            guard filled > 0 else { return }
            DispatchQueue.global(qos: .utility).async { PayWallet.touch(address: id, on: site) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                self?.reread { _ in }
                self?.redeliver()
            }
        }
    }

    /// When it arrives, read again once another address is in.
    private func redeliver() {
        guard let tab else { return }
        AgentPage.run(tab, Self.lookScript) { [weak self] result in
            guard let self, case .success(let value) = result, let out = value as? [String: Any],
                  let said = out["delivery"] as? String, said != self.model.delivery else { return }
            withAnimation(Motion.arrive) { self.model.delivery = said }
        }
    }

    /// What the asked button would do now, read off the page and kept as
    /// what the yes is for, its total rolled into the sheet.
    private func reread(_ done: @escaping (Bool) -> Void) {
        guard let tab, !ref.isEmpty else { done(false); return }
        let (frame, _) = AgentPage.locate(tab, ref)
        AgentPage.run(tab, Self.rereadScript, frame: frame) { [weak self] result in
            guard let self, case .success(let value) = result, let amount = value as? String, !amount.isEmpty else { done(false); return }
            if amount != self.model.amount {
                withAnimation(Motion.reshape) { self.model.amount = amount }
                if var permit = self.tab?.permit, permit.isPayment { permit.amount = amount; self.tab?.permit = permit }
            }
            done(true)
        }
    }

    static let rereadScript = """
    const S = globalThis.__yab;
    if (!S || !S.asked || !S.asked.isConnected) return '';
    \(AgentPage.commits)
    S.askedAbout = about(S.asked);
    return S.askedAbout.amount || '';
    """

    /// The button the agent was let press, pressed by Yab: a retry after the
    /// site said no.
    private func pressAgain(_ tab: Tab) {
        let (frame, _) = AgentPage.locate(tab, ref)
        AgentPage.run(tab, """
        const S = globalThis.__yab;
        const el = S && (S.refs.get(ref) || S.asked);
        if (!el || !el.isConnected) return false;
        el.scrollIntoView({ block: 'center', behavior: 'instant' });
        el.click();
        return true;
        """, ["ref": ref], frame: frame) { _ in }
    }

    // MARK: - what the site said

    /// Until the site says paid or no: first the agent's press (its yes is
    /// good for two minutes), then the page, for 45 seconds after. Nothing
    /// said, and the sheet goes quietly; the agent's answer says the rest.
    private func watch(pressed: Bool) {
        watching?.cancel()
        guard let tab else { return }
        let start = tab.address
        watching = Task { [weak self] in
            var before: [String: Any]?
            var pressedAt: Date? = pressed ? Date() : nil
            let asked = Date()
            while !Task.isCancelled {
                guard let self, let tab = self.tab else { return }
                let said = await Self.read(tab)
                if before == nil { before = said }
                if pressedAt == nil {
                    // The agent's press goes through: its yes is spent.
                    if tab.approved == nil || tab.approved?.ref != self.ref { pressedAt = Date() }
                    else if Date().timeIntervalSince(asked) > 130 || Agents.shared.session(self.session)?.state.live != true {
                        Payments.shared.end(tab); return
                    }
                } else if let pressedAt {
                    let moved = tab.address != start && Self.confirms(tab.address)
                    let bad = said["bad"] as? String ?? "", ok = said["ok"] as? String ?? ""
                    if !bad.isEmpty, bad != before?["bad"] as? String {
                        self.ended(paid: false, order: "")
                        return
                    }
                    if moved || (!ok.isEmpty && ok != before?["ok"] as? String) {
                        self.ended(paid: true, order: said["order"] as? String ?? "")
                        return
                    }
                    if Date().timeIntervalSince(pressedAt) > 45 { Payments.shared.end(tab); return }
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    /// A thank-you page's address.
    static func confirms(_ url: URL?) -> Bool {
        guard let path = url?.absoluteString.lowercased() else { return false }
        return path.range(of: #"(thank|confirmation|order-?(complete|placed|received|success)|checkout/(success|complete|done)|receipt|/success)"#, options: .regularExpression) != nil
    }

    private static func read(_ tab: Tab) async -> [String: Any] {
        await withCheckedContinuation { done in
            AgentPage.run(tab, outcomeScript) { result in
                if case .success(let value) = result, let out = value as? [String: Any] { done.resume(returning: out) }
                else { done.resume(returning: [:]) }
            }
        }
    }

    static let outcomeScript = """
    const t = ((document.body && document.body.innerText) || '').slice(0, 200000);
    const bad = t.match(/(card (was|has been|is) declined|payment (was )?declined|transaction (was )?declined|declined by (your|the) (bank|issuer|card issuer)|payment (failed|was unsuccessful|could not be (processed|completed))|(couldn.t|could not|unable to) process (your|the) (payment|card)|insufficient funds|card (number )?is (invalid|incorrect)|security code is (incorrect|invalid)|card has expired)/i);
    const ok = t.match(/(thank you for your (order|purchase|payment)|thanks for your (order|purchase)|order (has been )?(placed|confirmed|received)|your order is (confirmed|placed|on its way)|payment (successful|received|complete|confirmed)|purchase (complete|confirmed|successful))/i);
    const order = t.match(/order\\s*(?:number|no\\.?|#|id)\\s*[:#]?\\s*#?([A-Z0-9][A-Z0-9-]{3,24})/i);
    return { bad: bad ? bad[0] : '', ok: ok ? ok[0] : '', order: order ? order[1] : '' };
    """

    /// How long Paid stands, green with the order, before the sheet goes
    /// back into the field.
    static let paidFor: TimeInterval = 1.4

    /// The site said. Paid: the button turns green with its tick, the line
    /// the order, then the sheet goes. No: the button shakes and is Pay
    /// again, the card's row and the line red; another press, or another
    /// card, tries again.
    func ended(paid: Bool, order: String) {
        watching?.cancel()
        if paid {
            withAnimation(Motion.arrive) { model.paid(order: order) }
            let id = tab?.id
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.paidFor) {
                if let id, !(Store.testing && PayFlow.holdPaid) { Payments.shared.end(id) }
            }
        } else {
            withAnimation(Motion.arrive) { model.declined() }
        }
    }
}

// MARK: - Touch ID in the sheet

/// LocalAuthentication with its glyph inside the sheet (LAAuthenticationView):
/// no system dialog over it. One context a listen, stopped while a list or a
/// form is open, its answers sorted into the sheet's.
@MainActor
@Observable final class PayTouch {
    /// The glyph the sheet holds, the current context's.
    private(set) var glyph: LAAuthenticationView?
    @ObservationIgnored private var context: LAContext?

    /// A test world answers in Touch ID's place (bench `pay`): nobody's
    /// finger, and no sensor on the farm's Macs.
    struct Stub {
        var answer: PaySheetModel.Answer = .yes
        var delay: TimeInterval = 0.4
        var proof: PaySheetModel.Proof = .touchID
    }
    static var stub: Stub?
    var stubbed: Bool { Store.testing && Self.stub != nil }

    static var canTouch: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    func listen(reason: String, _ done: @escaping (PaySheetModel.Answer) -> Void) {
        guard context == nil else { return }
        let context = LAContext()
        context.localizedFallbackTitle = ""
        self.context = context
        glyph = LAAuthenticationView(context: context, controlSize: .small)
        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { ok, error in
            let code = (error as? LAError)?.code
            DispatchQueue.main.async { [weak self] in
                guard let self, self.context === context else { return }
                self.context = nil
                if ok { done(.yes); return }
                switch code {
                case .authenticationFailed: done(.miss)
                case .biometryLockout, .biometryNotAvailable, .biometryNotEnrolled, .userFallback: done(.locked)
                default: done(.quiet)
                }
            }
        }
    }

    /// The Mac's password, in its own dialog: the one way the sheet can't
    /// hold in itself.
    func password(reason: String, _ done: @escaping (PaySheetModel.Answer) -> Void) {
        stop()
        let context = LAContext()
        self.context = context
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.context === context else { return }
                self.context = nil
                done(ok ? .yes : .quiet)
            }
        }
    }

    func stop() {
        guard let context else { return }
        self.context = nil
        context.invalidate()
    }
}

/// The cards and addresses the sheet offers: Wallet's, or in a test world a
/// stand-in kept in memory (bench `agent-pay seed`), so a farm Mac's
/// keychain is never written for a picture. Beside a stand-in, what Sync
/// brought into the test world's own Wallet is offered too: a card another
/// device kept for a payment's yes (evals/approvals/local.py).
enum PayWallet {
    nonisolated(unsafe) static var standIn: (cards: [SavedCard], addresses: [StreetAddress])?
    private static var stood: Bool { Store.testing && standIn != nil }

    static func cards() -> [SavedCard] {
        guard stood, let standIn else { return Wallet.cards() }
        let ids = Set(standIn.cards.map(\.id))
        return standIn.cards.map { var card = $0; card.number = ""; card.csc = ""; return card }
            .sorted { ($0.used ?? .distantPast) > ($1.used ?? .distantPast) } + Wallet.cards().filter { !ids.contains($0.id) }
    }

    static func addresses() -> [StreetAddress] {
        guard stood, let standIn else { return Wallet.addresses() }
        let ids = Set(standIn.addresses.map(\.id))
        return standIn.addresses.sorted { ($0.used ?? .distantPast) > ($1.used ?? .distantPast) }
            + Wallet.addresses().filter { !ids.contains($0.id) }
    }

    static func preferredAddress() -> StreetAddress? {
        guard stood else { return Wallet.preferredAddress() }
        let all = addresses()
        return all.first { $0.used != nil } ?? all.first
    }

    static func number(of id: String) -> String? {
        guard stood else { return Wallet.number(of: id) }
        return standIn?.cards.first { $0.id == id }?.number ?? Wallet.number(of: id)
    }

    static func securityCode(of id: String) -> String? {
        guard stood else { return Wallet.securityCode(of: id) }
        guard let card = standIn?.cards.first(where: { $0.id == id }) else { return Wallet.securityCode(of: id) }
        return card.csc.isEmpty ? nil : card.csc
    }

    @discardableResult
    static func save(_ card: SavedCard) -> Bool {
        guard stood else { return Wallet.save(card) }
        guard Wallet.luhn(card.number.filter(\.isNumber)) else { return false }
        standIn?.cards.append(card)
        return true
    }

    @discardableResult
    static func save(_ address: StreetAddress) -> Bool {
        guard stood else { return Wallet.save(address) }
        standIn?.addresses.append(address.tidied())
        return true
    }

    static func touch(card id: String, on site: String) {
        guard !stood else { return }
        Wallet.touch(card: id, on: site)
    }

    static func touch(address id: String, on site: String) {
        guard !stood else { return }
        Wallet.touch(address: id, on: site)
    }
}
