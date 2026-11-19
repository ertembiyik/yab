import AppKit
import SwiftUI

// Keeping a password a page has just signed in with.
//
// One card, and it belongs to the tab the password was typed in, not to the
// window: in the middle of that tab's page, over a light dimming, the way Arc
// asks, and where the eye is right after signing in, which the foot of the
// page never was. Save puts it away at once, and that is the whole answer;
// if the keychain refuses, the card comes back saying so. Put off, Not now,
// a click beside it, going to another tab, it folds away and the site's mark
// on its corner flies up to wait on the tab as a key; a click on the key
// brings it back the same way. It lasts as long as the tab stays
// on the site. Leaving takes the key.
//
// papers/family-values-motion: one surface, its contents replaced (P1);
// crossfades that overlap, never an empty frame (P2); the way back is the way
// there (P3); the pending thing goes where you will look for it (ex-39, and
// ex-01's mark turning into a key); state at once, geometry animated (P6).
// The flight is the one flourish, and it is on a path walked once a site.

struct PasswordOffer: Equatable, Identifiable {
    let id = UUID()
    var login: Login
    /// The same account is already kept, with a different password.
    let changed: Bool
    /// Where the password went and where the sign-in landed, as registrable
    /// domains. The offer holds while the tab stays on one of them.
    var sites: Set<String>
    let at = Date()
    var stage: Stage = .asking
    /// Put off: a key on the tab rather than a pill over the page.
    var parked = false
    /// Folding into its mark, the moment before it is parked, so the pill
    /// leaves toward the mark rather than down the way it came.
    var folding = false
    /// The mark is in the air between the pill and the tab, and neither
    /// shows it until it lands.
    var flying = false
    /// Brought back down from its key: it opens out of the mark rather than
    /// rising from the edge.
    var fromKey = false
    /// Bumped on every change, so a timer only takes down the pill it was
    /// set for, not one that has been answered differently since.
    var beat = 0
    /// The manager it goes into instead of Yab's keychain (Apple Passwords,
    /// ApplePasswords.swift): its icon in the well, its name in the words.
    var into: String? = nil

    enum Stage: Equatable { case asking, naming, never, refused }
}

/// The mark in the air, from the pill to its tab or back.
struct KeyFlight: Equatable, Identifiable {
    let id = UUID()
    let from: CGRect
    let to: CGRect
    let icon: NSImage?
    let letter: String
    /// Toward the tab, the mark turns into the key on the way; back, the key
    /// turns into the mark.
    let parking: Bool
    /// A card or an address going to wait on its tab (WalletKeep): the
    /// network's mark, or "house", all the way, no key.
    var pay: String? = nil

    static let time: TimeInterval = 0.35
}

/// Watched by the flight alone, so a mark taking off doesn't redraw the
/// window around it.
@MainActor
@Observable final class KeySky {
    var flight: KeyFlight?

    /// Where each tab's mark and each tab's pill mark last were, in the
    /// window's SwiftUI space. Written as they are laid out, read only when
    /// something takes off, nothing redraws because they moved.
    @ObservationIgnored var marks: [Tab.ID: CGRect] = [:]
    /// Which mark said so last: a mark going takes back only its own word.
    @ObservationIgnored var markers: [Tab.ID: UUID] = [:]
    @ObservationIgnored var pills: [Tab.ID: CGRect] = [:]
    /// Where the window's own top-left is in that space: not the same in
    /// every window, which can lay its root out under the title bar's
    /// safe area (TearGround).
    @ObservationIgnored var ground: CGPoint = .zero
    /// An AppKit view laid over the whole window there, to take that space
    /// to the screen and back exactly (TearGround).
    @ObservationIgnored weak var groundView: NSView?
    /// And each tab's whole shape, in the same space, for a page's question
    /// to hang from, a card to come out of, a middle press to close: read
    /// through `place`. A row in the column says where it is in that space
    /// (`lay`). A tab across the top says where it is in its own run
    /// (`lay(_:_:in:by:)`), and that is taken to the window as it is read,
    /// through an AppKit view laid under the run (StripAnchor). The run is
    /// an AppKit scroll view: what SwiftUI called its tabs' global frames
    /// was counted once, as they were laid out, and never again as the
    /// strip came down from past the window's top or the run scrolled. At
    /// launch every tab across the top was said to be a strip's height
    /// above where it was drawn, and the pointer on it was taken to be off it.
    @ObservationIgnored private var laid: [Tab.ID: CGRect] = [:]
    /// What each pill across the top said, a tab's pills in strips going
    /// and coming both, each until it goes (`current`).
    @ObservationIgnored private var strip: [Tab.ID: [StripSpot]] = [:]

    /// Where along the top a tab stands: the pins every space shares, ahead
    /// of the capsule, or the run of the space's own.
    enum StripRoom: Sendable {
        case ahead, run
        /// The SwiftUI space it is measured in (TabBar).
        var space: String { self == .ahead ? "ahead" : "run" }
    }

    /// One room of one strip, and the AppKit view laid under it: a pill
    /// is measured in the room it stands in, and taken to the window
    /// through that room's own view. A window's strip can be made again
    /// (its first tab, the tabs changing sides) and for a moment there are
    /// two, the one going and the one coming.
    @MainActor
    final class Anchor {
        let room: StripRoom
        weak var view: NSView?
        /// Made after every anchor with a smaller one: the strip coming.
        let serial: Int
        private static var made = 0
        init(_ room: StripRoom) {
            self.room = room
            Anchor.made += 1
            serial = Anchor.made
        }
    }

    struct StripSpot: Equatable {
        let anchor: Anchor
        let frame: CGRect
        /// The pill that said so: going, it takes back only its own word.
        let by: UUID

        static func == (a: StripSpot, b: StripSpot) -> Bool {
            a.anchor === b.anchor && a.frame == b.frame && a.by == b.by
        }
    }

    /// The tabs are along the top now, not down the side: which of a
    /// tab's two words on where it is holds (`place`). Told by Browser.
    @ObservationIgnored var across: () -> Bool = { false }

    /// A row in the column, in the window's SwiftUI space. It leaves the
    /// strip's word alone: the column sliding out as the tabs went to the
    /// top said where its rows were last, and every card hung from the
    /// column's old row, at the window's left edge under the strip.
    func lay(_ id: Tab.ID, _ frame: CGRect) {
        laid[id] = frame
        heard(id)
    }

    /// A tab across the top, in its room's own space.
    func lay(_ id: Tab.ID, _ frame: CGRect, in anchor: Anchor, by: UUID) {
        let spot = StripSpot(anchor: anchor, frame: frame, by: by)
        var spots = strip[id] ?? []
        if let at = spots.firstIndex(where: { $0.by == by }) {
            guard spots[at] != spot else { return }
            spots[at] = spot
        } else {
            spots.append(spot)
        }
        strip[id] = spots
        heard(id)
    }

    /// The pill `by` is gone from the top: its word goes, and only its.
    /// A strip made again fades out after the new one is laid, still
    /// saying where its tabs are as it goes; taking the tab's place with it
    /// left a second window's tabs nowhere.
    func unlay(_ id: Tab.ID, by: UUID) {
        guard var spots = strip[id], let at = spots.firstIndex(where: { $0.by == by }) else { return }
        spots.remove(at: at)
        strip[id] = spots.isEmpty ? nil : spots
        heard(id)
    }

    /// The word on a tab across the top that holds now: of the pills in
    /// this window, the newest strip's.
    private func current(_ id: Tab.ID) -> StripSpot? {
        guard let spots = strip[id], let window = groundView?.window else { return nil }
        return spots.filter { $0.anchor.view?.window === window }.max { $0.anchor.serial < $1.anchor.serial }
    }

    /// The tab's shape in the window's SwiftUI space, as it is now.
    func place(_ id: Tab.ID) -> CGRect? {
        // Along the top, the strip's word, and the column's only for a tab
        // that has no pill there (a mail column's). Down the side, the
        // column's, and the strip's for a tab it has no row for yet, as
        // the tabs come down from the top.
        if across() {
            if strip[id] != nil { return current(id).flatMap { live($0) } }
            return laid[id]
        }
        return laid[id] ?? current(id).flatMap { live($0) }
    }

    /// As much of a tab across the top as its run shows now: nil for one
    /// scrolled out of sight or not across the top.
    func seen(_ id: Tab.ID) -> CGRect? {
        current(id).flatMap { live($0, seen: true) }
    }

    /// The scroll view the run of tabs across the top is in, for the bench.
    var runScroll: NSScrollView? {
        runs.allObjects.lazy.compactMap(\.view)
            .first { $0.window != nil && $0.window === self.groundView?.window }?.enclosingScrollView
    }

    /// Every run's anchor this window's strips have made, while it lasts.
    private let runs = NSHashTable<Anchor>.weakObjects()

    /// A room's view is laid.
    func room(_ anchor: Anchor) {
        if anchor.room == .run, !runs.contains(anchor) { runs.add(anchor) }
    }

    /// What is known of where a tab is, for the bench: across the top in
    /// which room, and whether that room's view and the ground are in the
    /// same window; or in the column.
    func census(_ id: Tab.ID) -> [String: Any] {
        var out: [String: Any] = ["ground": groundView?.window?.windowNumber ?? 0, "column": laid[id] != nil, "pills": strip[id]?.count ?? 0]
        if let spot = current(id) {
            out["room"] = spot.anchor.room.space
            out["anchor"] = spot.anchor.view == nil ? -1 : spot.anchor.view?.window?.windowNumber ?? 0
        }
        return out
    }

    /// Every tab whose place is known.
    var places: [Tab.ID: CGRect] {
        var out: [Tab.ID: CGRect] = [:]
        for id in Set(laid.keys).union(strip.keys) { out[id] = place(id) }
        return out
    }

    /// The tab across the top standing at `point` (the window's SwiftUI
    /// space): by where each is drawn now.
    func stripTab(at point: CGPoint, among ids: [Tab.ID]) -> Tab.ID? {
        ids.first { id in
            guard let frame = seen(id), frame.width > 0 else { return false }
            return frame.contains(point)
        }
    }

    /// A point of the window's own, AppKit's from its bottom left, in the
    /// space the tabs' places are in.
    func spot(_ point: NSPoint, in window: NSWindow?) -> CGPoint? {
        guard let view = groundView, let window, view.window === window else { return nil }
        let at = view.convert(point, from: nil)
        return CGPoint(x: at.x + ground.x, y: at.y + ground.y)
    }

    /// `seen`: only as much of it as the run shows, not what has scrolled
    /// out past its ends, over the capsule or the plus.
    private func live(_ spot: StripSpot, seen: Bool = false) -> CGRect? {
        guard let anchor = spot.anchor.view, let view = groundView,
              let window = anchor.window, window === view.window else { return nil }
        let frame = seen ? spot.frame.intersection(anchor.visibleRect) : spot.frame
        guard !frame.isNull else { return nil }
        return KeySky.carry(frame, from: anchor, to: view, ground: ground)
    }

    /// `rect`, in `anchor`'s space, in the space `view` stands at `ground` in.
    static func carry(_ rect: CGRect, from anchor: NSView, to view: NSView, ground: CGPoint) -> CGRect {
        anchor.convert(rect, to: view).offsetBy(dx: ground.x, dy: ground.y)
    }

    /// A strip's room moved in the window, with its tabs: down from past
    /// the top, along as the run scrolls.
    func shifted() {
        guard let watched, strip[watched] != nil else { return }
        heard(watched)
    }

    /// The tab a question hangs from moved, arriving in the row or the
    /// column: the card goes with it rather than stay where the tab was as
    /// it was asked.
    private func heard(_ id: Tab.ID) {
        guard id == watched, let now = place(id), now != watchedAt else { return }
        watchedAt = now
        moved += 1
    }

    /// The tab with a question hanging from it, which the card watches.
    @ObservationIgnored var watched: Tab.ID? {
        didSet { if watched != oldValue { watchedAt = watched.flatMap(place) } }
    }
    @ObservationIgnored private var watchedAt: CGRect?
    /// Counts the watched tab's moves.
    private(set) var moved = 0
}

/// Laid under a room of the strip's tabs, exactly its size, so KeySky can
/// take a place in it to the window as AppKit has it now: past the
/// strip's slide and the run's scroll, which SwiftUI's global frames inside
/// the run were never told of.
struct StripAnchor: NSViewRepresentable {
    let sky: KeySky
    let anchor: KeySky.Anchor

    func makeNSView(context: Context) -> StripAnchorView {
        let view = StripAnchorView()
        view.sky = sky
        anchor.view = view
        sky.room(anchor)
        return view
    }

    func updateNSView(_ view: StripAnchorView, context: Context) {
        view.sky = sky
        if anchor.view !== view { anchor.view = view }
    }
}

final class StripAnchorView: NSView {
    weak var sky: KeySky?
    private var watching: [NSObjectProtocol] = []

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    deinit {
        for each in watching { NotificationCenter.default.removeObserver(each) }
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        sky?.shifted()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for each in watching { NotificationCenter.default.removeObserver(each) }
        watching = []
        guard window != nil else { return }
        // The run scrolling, and the strip it is in coming down or going
        // up: the run's scroll view moves, not this.
        var subjects: [(NSView, Notification.Name)] = []
        var view = superview
        while let each = view, each !== window?.contentView {
            if let scroll = each as? NSScrollView {
                scroll.contentView.postsBoundsChangedNotifications = true
                subjects.append((scroll.contentView, NSView.boundsDidChangeNotification))
            }
            each.postsFrameChangedNotifications = true
            subjects.append((each, NSView.frameDidChangeNotification))
            view = each.superview
        }
        watching = subjects.map { subject, name in
            NotificationCenter.default.addObserver(forName: name, object: subject, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sky?.shifted() }
            }
        }
        sky?.shifted()
    }
}

// MARK: - answering

extension Browser {
    private var still: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// A sign-in went through. Asked over the page if this is the tab you
    /// are on; a tab signed in behind your back gets the key straight away.
    func offer(_ login: Login, changed: Bool, on tab: Tab, into manager: String? = nil) {
        if let old = tab.offer, old.login == login, old.changed == changed { return }
        var sites: Set<String> = [Browser.site(login.host)]
        if let here = tab.address?.host() { sites.insert(Browser.site(here)) }
        var offer = PasswordOffer(login: login, changed: changed, sites: sites)
        offer.into = manager
        offer.parked = tab.id != activeID
        withAnimation(Motion.reshape) { tab.offer = offer }
    }

    /// Saved at once, as far as the pill goes: the keychain can take a
    /// quarter of a second to write, and the answer is not held up for it.
    /// If it refuses, the pill comes back saying so.
    func keepOffer(_ tab: Tab) {
        guard let offer = tab.offer else { return }
        let login = offer.login
        // The card going is the answer, and nothing else says it: a sign-in
        // is done with, and the page is waiting.
        withAnimation(Motion.depart) { tab.offer = nil }
        // A re-submission must read after this write, including a slow
        // keychain or manager reply, rather than ask again while Save waits.
        PasswordSaveDecision.beginSave(login)
        // Into the manager it was offered for, through its own API.
        if let manager = offer.into, let adapter = ManagerVault.adapter(manager) {
            Task { @MainActor [weak self, weak tab] in
                defer { PasswordSaveDecision.endSave(login) }
                var kept = true
                do {
                    try await adapter.save(host: login.host, user: login.user, password: login.password)
                    if manager == PasswordManagers.apple {
                        PasswordSaveDecision.remember(host: login.host, user: login.user, password: login.password)
                    }
                } catch {
                    kept = false
                    ApplePasswords.log.error("\(manager, privacy: .public) didn't save: \(String(describing: error), privacy: .public)")
                }
                ManagerVaults.forget()
                guard !kept, let self, let tab, tab.offer == nil else { return }
                var back = offer
                back.stage = .refused
                back.parked = tab.id != self.activeID
                withAnimation(Motion.reshape) { tab.offer = back }
            }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let kept = Vault.save(host: login.host, user: login.user, password: login.password, used: Date(), clear: login.clear, space: login.space)
            DispatchQueue.main.async { [weak self, weak tab] in
                PasswordSaveDecision.endSave(login)
                if kept {
                    self?.savedPasswordChanged()
                    return
                }
                // Refused: the question comes back, saying so, with the way
                // to try again.
                guard let self, !kept, let tab, tab.offer == nil else { return }
                var back = offer
                back.stage = .refused
                back.parked = tab.id != activeID
                back.folding = false
                back.flying = false
                back.fromKey = false
                withAnimation(Motion.reshape) { tab.offer = back }
            }
        }
    }

    /// Kept under a name typed into the pill.
    func keepOffer(_ tab: Tab, as user: String) {
        change(tab, nil) { $0.login.user = user.trimmingCharacters(in: .whitespacesAndNewlines) }
        keepOffer(tab)
        handBack(tab)
    }

    /// Never for this site. No asking whether you are sure: the pill says
    /// what it did, with the way back in it, for as long as it stays.
    func neverOffer(_ tab: Tab) {
        guard let host = tab.offer?.login.host else { return }
        Vault.never(host)
        change(tab) { $0.stage = .never }
        lower(tab, after: 3.5)
    }

    func undoNever(_ tab: Tab) {
        guard let host = tab.offer?.login.host else { return }
        Vault.never.remove(host)
        change(tab) { $0.stage = .asking }
    }

    func nameOffer(_ tab: Tab) { change(tab) { $0.stage = .naming } }
    func unnameOffer(_ tab: Tab) {
        change(tab) { $0.stage = .asking }
        handBack(tab)
    }

    /// The name box is gone with the answer: the keyboard goes back to the
    /// page, not to a field that no longer exists.
    private func handBack(_ tab: Tab) {
        DispatchQueue.main.async { [weak tab] in
            guard let web = tab?.builtPage, let window = web.window else { return }
            window.makeFirstResponder(web)
        }
    }

    func dismissOffer(_ tab: Tab) {
        withAnimation(Motion.depart) { tab.offer = nil }
    }

    /// Not now: down into the site's mark, and the mark up onto the tab.
    func parkOffer(_ tab: Tab) {
        guard let offer = tab.offer, !offer.parked else { return }
        // Already answered: there is nothing left to wait for.
        guard offer.stage == .asking || offer.stage == .naming else {
            tab.offer = nil
            return
        }
        let sky = keySky
        var flies = false
        if !still, tabs.contains(where: { $0 === tab }),
           let from = sky.pills[tab.id], let to = sky.marks[tab.id], to.width > 0 {
            flies = true
            fly(KeyFlight(from: from, to: to, icon: mark(for: offer, on: tab), letter: letter(for: offer), parking: true), for: tab)
        }
        // First the way it will leave, then leaving: the pill takes its
        // exit from the last time it was drawn.
        tab.offer?.folding = true
        DispatchQueue.main.async { [weak self, weak tab] in
            guard let self, let tab, tab.offer?.id == offer.id else { return }
            change(tab, Motion.depart) {
                $0.stage = .asking
                $0.parked = true
                $0.flying = flies
                $0.fromKey = false
            }
        }
    }

    /// The key on a tab, clicked: back down the way it went.
    func unparkOffer(_ tab: Tab) {
        // The card on the tab is a card or an address to keep (WalletKeep).
        guard let offer = tab.offer, offer.parked else { return unparkPay(tab) }
        if activeID != tab.id { select(tab) }
        let sky = keySky
        var flies = false
        if !still, let from = sky.marks[tab.id], let to = sky.pills[tab.id], from.width > 0 {
            flies = true
            fly(KeyFlight(from: from, to: to, icon: mark(for: offer, on: tab), letter: letter(for: offer), parking: false), for: tab)
        }
        // The pill opens round the mark as it arrives, not after.
        let opening = flies ? Motion.arrive.delay(KeyFlight.time - 0.14) : Motion.arrive
        change(tab, opening) {
            $0.parked = false
            $0.folding = false
            $0.flying = flies
            $0.fromKey = true
        }
    }

    /// Gone to another tab. A question still open waits on the tab left.
    func offerLeft(_ tab: Tab) {
        guard tab.offer?.parked == false else { return }
        parkOffer(tab)
    }

    /// The tab went somewhere. Anywhere but the site signed in to, or where
    /// that sign-in landed, and the offer goes, no longer where it was
    /// about. For a moment after it is made, a new place is taken as more of
    /// the sign-in landing: one redirect after another.
    func offerMoved(_ tab: Tab, to url: URL) {
        guard let offer = tab.offer, let host = url.host() else { return }
        let site = Browser.site(host)
        guard !offer.sites.contains(site) else { return }
        if Date().timeIntervalSince(offer.at) < 4 {
            tab.offer?.sites.insert(site)
            return
        }
        withAnimation(offer.parked ? Motion.quick : Motion.depart) { tab.offer = nil }
    }

    /// The site's own mark: where the password went, not necessarily the
    /// page the tab is on now.
    func mark(for offer: PasswordOffer, on tab: Tab) -> NSImage? {
        guard prefs.glyph == .icons else { return nil }
        if let icon = Favicons.shared.cached(offer.login.host) { return icon }
        let here = tab.address?.host().map(Browser.site)
        return here == Browser.site(offer.login.host) ? tab.icon : nil
    }

    func letter(for offer: PasswordOffer) -> String {
        Self.site(offer.login.host).first.map { String($0).uppercased() } ?? "•"
    }

    /// The registrable part of a host, and an address like 192.168.1.1 left
    /// whole, which has no such part.
    static func site(_ host: String) -> String {
        host.allSatisfy { $0.isNumber || $0 == "." || $0 == ":" } ? host : Vault.registrable(host)
    }

    private func change(_ tab: Tab, _ motion: Animation? = Motion.reshape, _ edit: (inout PasswordOffer) -> Void) {
        guard var offer = tab.offer else { return }
        edit(&offer)
        offer.beat += 1
        withAnimation(motion) { tab.offer = offer }
    }

    /// Takes the pill down after a while, if nothing has happened to it since.
    private func lower(_ tab: Tab, after delay: TimeInterval) {
        guard let offer = tab.offer else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak tab] in
            guard let tab, tab.offer?.id == offer.id, tab.offer?.beat == offer.beat else { return }
            withAnimation(Motion.depart) { tab.offer = nil }
        }
    }

    private func fly(_ flight: KeyFlight, for tab: Tab) {
        keySky.flight = flight
        DispatchQueue.main.asyncAfter(deadline: .now() + KeyFlight.time) { [weak self, weak tab] in
            guard let self, keySky.flight?.id == flight.id else { return }
            // Landed exactly over the mark it becomes: the swap is instant,
            // or the old mark shows through for a moment between the two.
            var landing = Transaction()
            landing.disablesAnimations = true
            withTransaction(landing) {
                self.keySky.flight = nil
                if let tab, tab.offer?.flying == true { tab.offer?.flying = false }
            }
        }
    }
}

// MARK: - the card

/// The question, in the middle of the page over a light dimming, the way Arc
/// asks it: the key in a quiet well with the site's own mark at its corner,
/// the question and one line under it, and the answer on the right, Never
/// on this site kept apart on the left, in plain words. A click on
/// the dimming is Not now: the page is live behind it, and a sign-in that
/// wanted answering first would be one that got in the way.
struct KeepCard: View {
    var browser: Browser
    var tab: Tab
    let offer: PasswordOffer

    static let width: CGFloat = 400
    private static let side = CardFrame.well

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            well.padding(.bottom, 12)
            Text(title)
                .font(CardFrame.title)
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .id(title)
                .transition(.opacity.animation(Motion.morph))
            if !detail.isEmpty {
                Text(detail)
                    .font(CardFrame.detail)
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
                    .id(detail)
                    .transition(.opacity.animation(Motion.morph))
            }
            foot.padding(.top, CardFrame.buttonGap)
        }
        .frame(width: Self.width - CardFrame.inset * 2, alignment: .leading)
        .cardFrame(glass: true)
    }

    // MARK: the well

    @ViewBuilder
    private var well: some View {
        if let manager = offer.into, offer.stage != .refused, let icon = PasswordManagers.icon(manager) {
            // Going into a password manager: its own icon where the key is,
            // the site's mark at its corner as ever.
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: Self.side, height: Self.side)
                .notched(true, side: 15, radius: 4, offset: 5)
                .overlay(alignment: .bottomTrailing) { badge.offset(x: 5, y: 5) }
        } else {
            keyWell
        }
    }

    private var keyWell: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        return shape.fill(Palette.ink.opacity(0.05))
            .overlay(shape.strokeBorder(Palette.ink.opacity(0.08), lineWidth: 0.5))
            // Refused: the key grayed, and nobody's mark at its corner.
            .overlay { Symbol("key", size: 16).foregroundStyle(offer.stage == .refused ? Palette.muted : Palette.ink) }
            .frame(width: Self.side, height: Self.side)
            // The site's mark in a hole cut out of the well, not on a plate
            // of the card's color (Design.swift's `notched`).
            .notched(offer.stage != .refused, side: 15, radius: 4, offset: 5)
            .overlay(alignment: .bottomTrailing) { badge.offset(x: 5, y: 5) }
    }

    /// The site's mark, the one that flies to the tab and becomes the key.
    @ViewBuilder
    private var badge: some View {
        if offer.stage != .refused {
            Mark(icon: browser.mark(for: offer, on: tab), letter: browser.letter(for: offer), size: 15)
                .opacity(offer.flying ? 0 : 1)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { [id = tab.id, sky = browser.keySky] in
                    sky.pills[id] = $0
                }
                .transition(.opacity)
        }
    }

    // MARK: the words

    private var site: String { IDN.shown(Browser.site(offer.login.host)) }

    private var title: String {
        switch offer.stage {
        case .asking, .naming: return offer.changed ? "Update password for \(site)?" : "Save password for \(site)?"
        case .never: return "Won’t ask again on \(site)"
        case .refused: return offer.into.map { "\(PasswordManagers.name($0)) didn’t save it" } ?? "The keychain didn’t save it"
        }
    }

    private var detail: String {
        switch offer.stage {
        case .asking, .naming:
            let user = offer.login.user
            if offer.changed { return user.isEmpty ? "The one saved for this account is different." : "The one saved for \(user) is different." }
            if let manager = offer.into {
                return manager == PasswordManagers.apple ? "In Apple Passwords, on your iPhone too." : "In \(PasswordManagers.name(manager))."
            }
            return "That way, it’s filled in next time."
        case .never: return "You can change this in Settings › Passwords."
        case .refused where offer.into != nil: return "Try again, or save it in \(PasswordManagers.name(offer.into ?? ""))."
        case .refused: return "macOS refused to write the password. Try again, or save it later in Settings › Passwords."
        }
    }

    // MARK: the answers

    private var foot: some View {
        HStack(spacing: 6) {
            if offer.stage == .asking || offer.stage == .naming, !offer.changed {
                Button("Never on This Site") { browser.neverOffer(tab) }
                    .buttonStyle(.yab(.quiet, CardFrame.button))
            }
            Spacer(minLength: 8)
            switch offer.stage {
            case .asking, .naming:
                press("Not Now", .secondary, key: "esc") { browser.parkOffer(tab) }
                press(offer.changed ? "Update" : "Save", .primary, key: "⏎") { browser.keepOffer(tab) }
            case .never:
                press("Undo", .secondary) { browser.undoNever(tab) }
            case .refused:
                press("Close", .quiet, key: "esc") { browser.dismissOffer(tab) }
                press("Try Again", .primary, key: "⏎") { browser.keepOffer(tab) }
            }
        }
    }

    private func press(_ title: String, _ kind: ButtonKind, key: String? = nil, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            HStack(spacing: 6) {
                Text(title)
                if let key, shows(key) {
                    KeyGlyphs(keys: key, size: CardFrame.words, tint: nil, rest: 0.6)
                        .transaction { $0.animation = nil }
                }
            }
        }
        .buttonStyle(.yab(kind, CardFrame.button))
        .fixedSize()
        .transition(.opacity.animation(Motion.morph))
    }

    /// Whether Return and Escape reach the card right now: not while the
    /// caret is in something on the page that takes typing, nor while the
    /// address field, find or a panel has the keys, read from the same
    /// things that decide it in `ContentView.take`.
    private func shows(_ key: String) -> Bool {
        return !tab.typing && !browser.fieldShowing && !browser.finding && browser.editingTab == nil
            && !browser.welcoming
    }
}

// MARK: - the key on the tab

/// A tab's mark, or, while a password waits on the tab, a key in its place.
/// A click on the key brings the question back.
struct TabMark<Content: View>: View {
    var tab: Tab
    let sky: KeySky
    let size: CGFloat
    let tint: Color
    let unpark: () -> Void
    /// How far inside the mark's corner the call's dot centers. Nothing
    /// where the mark has room under it; a pair's chip has 4 points, and
    /// the dot's cut would reach past the chip's edge.
    var dotInset: CGFloat = 0
    /// Room right of the mark inside what it is drawn in, for the words at
    /// its top corner (MarkCorners): a pin on top has 7 points.
    var room: CGFloat = .infinity
    /// A pin's bare letter rather than a picture: its words at the corner
    /// sit higher, clear of the letter's top.
    var lettered = false
    /// On a row that says a share waiting on it in words (ShareWaiting):
    /// the mark stays the site's for that one.
    var worded = false
    @ViewBuilder let mark: () -> Content
    /// This mark, as KeySky knows it: going, it takes back only its own
    /// word. Changing sides (⇧⌘S), or a tab's end changing what it shows,
    /// builds the new mark before the old one goes, and the old one's going
    /// would otherwise erase where the new one is.
    @State private var me = UUID()
    /// In a cell of the AppKit column: where it stands is the page's to say.
    @Environment(\.columnHosted) private var hosted

    var body: some View {
        let keyed = tab.offer.map { $0.parked && !$0.flying } ?? false
        // A card or an address waiting to be kept, or just kept: its mark
        // in the site's place, the network's own.
        let paying = !keyed && tab.offer == nil && (tab.payOffer.map { $0.parked && !$0.flying } ?? false)
        let landed = !keyed && !paying && tab.payLanded != nil
        // A page's question waiting here: a bubble, the way the key waits. A
        // click on the tab is all it takes to bring it down.
        let asking = tab.asks.first?.parked == true && !(worded && tab.wantsScreen)
        // An agent waiting on you here: its face at the tab's end turns into
        // the hand, so the mark stays the site's.
        let handing = tab.handoff != nil && tab.worker == nil
        ZStack {
            if handing {
                Symbol("hand", size: size * 0.62)
                    .foregroundStyle(tint)
                    .frame(width: size, height: size)
                    .keyTip(tab.handoff ?? "")
                    .transition(.opacity)
            } else if asking {
                Symbol("bubble", size: size * 0.62)
                    .foregroundStyle(tint)
                    .frame(width: size, height: size)
                    .keyTip(tab.asks.first.map { "\($0.host) is waiting for an answer" } ?? "")
                    .transition(.opacity)
            } else if keyed {
                Symbol("key", size: size * 0.62)
                    .foregroundStyle(tint)
                    .frame(width: size, height: size)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: unpark)
                    .keyTip(tab.offer.map { "Save the password for \($0.login.host)" } ?? "")
                    .transition(.opacity)
            } else if paying || landed {
                PayMark(kind: tab.payLanded ?? tab.payOffer?.mark ?? "house", height: size * 0.66, tint: tint)
                    .frame(width: size, height: size)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: unpark)
                    .keyTip(tab.payOffer?.card != nil ? "Save the card" : tab.payOffer?.address != nil ? "Save the address" : "Save the answers")
                    .transition(.opacity)
            } else if let state = tab.instantState {
                InstantLinksMark(searching: state == .searching, icon: tab.displayIcon, tint: tint)
                    .frame(width: size, height: size)
            } else {
                mark().transition(.opacity)
            }
        }
        .animation(Motion.quick, value: keyed)
        .animation(Motion.quick, value: paying)
        .animation(Motion.quick, value: landed)
        .animation(Motion.quick, value: asking)
        .animation(Motion.quick, value: handing)
        // The camera or the microphone in use: a dot on the mark's corner
        // and a menu behind it. The dot is set into the mark, not laid on it:
        // a circle a gap wider than the dot is cut out of the mark itself, so
        // what shows round the dot is whatever the tab is drawn on, in any
        // theme, rather than a ring of some other color. The cut, the dot and
        // the dot's click all have their center on the mark's corner, each
        // placed by its own size, so the three can't drift apart. The cut is
        // a mask, and only while the dot is there: a mask is a layer drawn
        // apart, and with it on every mark each row of the column cost an
        // offscreen pass whenever the column moved. The top corner holds
        // the words, a count or a meeting's time, cut the same way in the
        // same mask (Corner.swift).
        .modifier(MarkCorners(tab: tab, dotInset: dotInset, room: room, lift: lettered ? MarkCorners.letterLift : 0))
        .overlay(alignment: .bottomTrailing) {
            CaptureDot(tab: tab)
                .offset(x: CaptureDot.reach / 2 - dotInset, y: CaptureDot.reach / 2 - dotInset)
        }
        // An AI chat at work, or its answer not opened yet, in the dot's
        // place and its cut (ChatBusy).
        .overlay(alignment: .bottomTrailing) {
            ChatCorner(tab: tab)
                .offset(x: CaptureDot.size / 2 - dotInset, y: CaptureDot.size / 2 - dotInset)
                .allowsHitTesting(false)
        }
        // A page peeked from it, waiting over it or for it (LinkPeek).
        .overlay(alignment: .topTrailing) {
            if tab.peekMarked {
                let side = (size * 0.75).rounded()
                PeekMark(page: tab.peek, since: tab.peekSince)
                    .frame(width: side, height: side)
                    .offset(x: size * 0.32, y: -size * 0.32)
                    .transition(.identity)
                    .allowsHitTesting(false)
            }
        }
        .globalFrame(!hosted) { [id = tab.id] in
            // Only at its own size: a row on its way out shrinks as it goes,
            // and would otherwise have the last word over the mark that
            // replaced it (a pair's chip, the other side's row).
            guard abs($0.width - size) < 0.5, !hosted else { return }
            sky.marks[id] = $0
            sky.markers[id] = me
        }
        .onDisappear { [id = tab.id] in
            guard sky.markers[id] == me else { return }
            sky.marks[id] = nil
            sky.markers[id] = nil
        }
    }
}

// MARK: - the flight

/// Over the whole window, since the mark crosses from the page to the strip
/// or the column.
struct KeyFlightLayer: View {
    var sky: KeySky

    var body: some View {
        GeometryReader { proxy in
            if let flight = sky.flight {
                KeyFlier(flight: flight, origin: proxy.frame(in: .global).origin)
                    .id(flight.id)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct KeyFlier: View {
    let flight: KeyFlight
    let origin: CGPoint
    @State private var there = false
    @State private var keyed: Bool

    init(flight: KeyFlight, origin: CGPoint) {
        self.flight = flight
        self.origin = origin
        _keyed = State(initialValue: !flight.parking)
    }

    var body: some View {
        let from = flight.from, to = flight.to
        let at = there ? to : from
        let side = max(from.width, 1)
        ZStack {
            if let pay = flight.pay {
                PayMark(kind: pay, height: side * 0.66)
            } else {
                Mark(icon: flight.icon, letter: flight.letter, size: side)
                    .opacity(keyed ? 0 : 1)
                Symbol("key", size: side * 0.62)
                    .foregroundStyle(Palette.ink)
                    .opacity(keyed ? 1 : 0)
            }
        }
        .frame(width: side, height: side)
        .scaleEffect(at.width / side)
        .position(x: at.midX - origin.x, y: at.midY - origin.y)
        .onAppear {
            withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: KeyFlight.time)) { there = true }
            // Changes what it is on the way, not at either end.
            withAnimation(Motion.quick.delay(KeyFlight.time * (flight.parking ? 0.45 : 0.25))) {
                keyed = flight.parking
            }
        }
    }
}
