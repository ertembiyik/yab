import SwiftUI
import AppKit

// ⌃Tab, the way Arc and Dia have it: the tabs in the order you last looked at
// them, not the order they sit in the row. From every space, as in Arc: one
// of another space goes to that space (feedback #110); or from the space on
// screen alone, as in Dia (feedback #132), Settings › Tabs. Tapped, it goes back to the tab you
// were just on, which is almost always the one you want, two pages you are
// going back and forth between stay one keystroke apart however far apart
// they are in the row. Held, it lays out the pages as pictures, each ⌃Tab a
// step further back, and letting go of ⌃ goes to wherever it stopped.
//
// A tap never shows the grid: it waits a beat before appearing, and a ⌃ let
// go of before then just lands. A grid that flashed up on every quick switch
// would be the one thing on screen worth looking at, for a tenth of a second.
//
// Its numbers are Arc's, filmed frame by frame (evals/switcher/arc_grid.py):
// the five tabs last looked at in one row, 156 by 104 pictures, up after
// 0.15 s and gone the moment ⌃ is let go of, with no fade either way.

/// Where ⌃Tab's tabs come from: every space, as Arc has it, or the space on
/// screen, as Dia. Until it is picked, as the browser first brought in from
/// does it, so a move from Dia keeps its ⌃Tab.
enum SwitchReach: String, CaseIterable, Identifiable {
    case everySpace, thisSpace

    var id: String { rawValue }
    static let key = "switcher.reach"

    static var current: Self {
        Store.settings.string(forKey: key).flatMap(Self.init) ?? brought
    }

    /// Not picked: Dia's way for someone who came from Dia, Arc's for the
    /// rest. "bring.from" is `Bringing.fromKey`, the first browser brought from.
    static var brought: Self {
        Store.settings.string(forKey: "bring.from") == "Dia" ? .thisSpace : .everySpace
    }

    var title: String {
        switch self {
        case .everySpace: return "Every space"
        case .thisSpace: return "This space"
        }
    }
}

/// What the grid holds while ⌃ is down. Its own object, so walking it
/// redraws the grid and not the window.
@MainActor
@Observable final class Switcher {
    /// The tabs, most recently looked at first, the one you are on leads.
    /// Taken once when ⌃Tab is first pressed: looking at a tab moves it to the
    /// front, and a list that reshuffled under the walk would be no list.
    private(set) var order: [Tab] = []
    /// The space each tab of another space is in, by tab: going to one goes
    /// there first, and its tile wears that space's emoji.
    @ObservationIgnored private(set) var homes: [Tab.ID: Space] = [:]
    /// Where the walk has got to.
    var at = 0
    /// False for the beat before the grid appears, so a tap never shows it.
    private(set) var showing = false
    /// The last picture of each page. Kept between openings, so a page that
    /// can't be drawn right now still shows what it looked like last time.
    private(set) var pictures: [Tab.ID: NSImage] = [:]
    /// How many tiles go across, as the grid last laid itself out; the up and
    /// down arrows move by this much.
    @ObservationIgnored var across = Switcher.columns

    /// Five visible tiles; the keyboard walk includes every eligible tab.
    static let most = 5
    static let columns = 5

    /// A tab an agent opened for itself and still has: not kept, pinned or
    /// put in a folder of yours, so not one you were reading.
    static func agents(_ tab: Tab) -> Bool {
        tab.bench && tab.pin == nil && !tab.kept && tab.nest == nil
    }
    /// Two tabs side by side are one tab here, as in Arc (feedback #675):
    /// only the half that comes first in `ids` (the one you are on, else
    /// the one looked at last) stays, so ⌃Tab never walks from one half of
    /// the page on screen to the other. Landing on it brings the pair back.
    nonisolated static func onePerPair(_ ids: [Tab.ID], pairs: [Pair]) -> [Tab.ID] {
        guard !pairs.isEmpty else { return ids }
        var taken = Set<Tab.ID>()
        return ids.filter { id in
            guard let pair = pairs.first(where: { $0.contains(id) }) else { return true }
            return taken.insert(pair.first).inserted
        }
    }
    static let tile = CGSize(width: 156, height: 104)
    /// A beat long enough to hide a tap, short enough that a hold never
    /// waits: Arc's grid is up 0.15 s after Tab.
    static let beat: TimeInterval = 0.15

    @ObservationIgnored private var reveal: DispatchWorkItem?
    /// Where the pointer was when the walk began, and whether it has moved
    /// since: as in Arc and ⌘Tab, a tile the pointer is moved onto is the
    /// one picked, but a pointer resting where the grid happened to open
    /// picks nothing.
    @ObservationIgnored private var pointerAtOpen = NSPoint.zero
    @ObservationIgnored private var pointerMoved = false

    /// True from the first ⌃Tab until ⌃ is let go of.
    @ObservationIgnored private(set) var open = false
    var picked: Tab? { order.indices.contains(at) ? order[at] : nil }

    var visibleIndices: Range<Int> {
        let start = min((max(0, at) / Self.most) * Self.most, order.count)
        return start..<min(start + Self.most, order.count)
    }

    private func pictureVisibleTabs(refresh: Bool = false) {
        let visible = Set(visibleIndices.map { order[$0].id })
        pictures = pictures.filter { visible.contains($0.key) }
        for index in visibleIndices {
            let tab = order[index]
            guard refresh || pictures[tab.id] == nil else { continue }
            tab.glance(width: (SwitcherStrip.on ? SwitcherStrip.tile.width : Self.tile.width) * 2) { [weak self] image in
                guard let self, let image, self.open,
                      self.visibleIndices.contains(where: { self.order[$0].id == tab.id }) else { return }
                self.pictures[tab.id] = image
            }
        }
    }

    fileprivate func begin(_ tabs: [Tab], at start: Int, homes: [Tab.ID: Space] = [:]) {
        open = true
        self.homes = homes
        pointerAtOpen = NSEvent.mouseLocation
        pointerMoved = false
        order = tabs
        at = start
        let wanted = Set(tabs.map(\.id))
        pictures = pictures.filter { wanted.contains($0.key) }
        pictureVisibleTabs(refresh: true)
        let reveal = DispatchWorkItem { [weak self] in
            guard let self, self.open else { return }
            self.showing = true
        }
        self.reveal = reveal
        DispatchQueue.main.asyncAfter(deadline: .now() + (SwitcherStrip.on ? SwitcherStrip.beat : Self.beat), execute: reveal)
    }

    /// The pointer over a tile: it is the one picked once the pointer has
    /// moved, and letting go of ⌃ lands there, no click needed.
    func point(at index: Int) {
        guard open, order.indices.contains(index) else { return }
        if !pointerMoved {
            let now = NSEvent.mouseLocation
            guard hypot(now.x - pointerAtOpen.x, now.y - pointerAtOpen.y) > 2 else { return }
            pointerMoved = true
        }
        if at != index { at = index }
    }

    fileprivate func step(_ by: Int) {
        guard order.count > 1 else { return }
        at = ((at + by) % order.count + order.count) % order.count
        pictureVisibleTabs()
        // A second press is a walk, so show the experimental row immediately.
        if SwitcherStrip.on, open, !showing, let reveal {
            reveal.cancel()
            self.reveal = nil
            showing = true
        }
    }

    fileprivate func drop(_ tab: Tab) {
        guard let index = order.firstIndex(where: { $0.id == tab.id }) else { return }
        order.remove(at: index)
        homes[tab.id] = nil
        pictures[tab.id] = nil
        if at > index || at == order.count { at = max(0, at - 1) }
        pictureVisibleTabs()
    }

    /// The row over the page (SwitcherStrip) hides itself here, before the
    /// tab landed on is switched to, rather than when the view next updates.
    @ObservationIgnored var ending: (() -> Void)?
    /// The tabs `remember` has pictures of, oldest first.
    @ObservationIgnored private var remembered: [Tab.ID] = []

    /// The row over the page (SwitcherStrip): a picture of the page in
    /// front, taken while it is on screen, where it is quick, so the next
    /// walk has it from its first frame. A page behind others took longer
    /// than the walk's first half second to draw, and its tile stood blank.
    func remember(_ tab: Tab) {
        guard !open else { return }
        tab.glance(width: SwitcherStrip.tile.width * 2) { [weak self] image in
            guard let self, let image else { return }
            self.pictures[tab.id] = image
            self.remembered.removeAll { $0 == tab.id }
            self.remembered.append(tab.id)
            // The few a walk can show, and no more pictures than that.
            while self.remembered.count > Self.most * 2 {
                let gone = self.remembered.removeFirst()
                if !self.open || !self.order.contains(where: { $0.id == gone }) { self.pictures[gone] = nil }
            }
        }
    }

    fileprivate func end() {
        ending?()
        reveal?.cancel()
        reveal = nil
        open = false
        // Gone at once, as Arc's: the page you land on is what you look at.
        showing = false
        order = []
    }
}

extension Browser {
    /// The tabs ⌃Tab walks, and the space of each from another space. The
    /// share box offers these too.
    func recentTabs(limit: Int? = Switcher.most) -> (tabs: [Tab], homes: [Tab.ID: Space]) {
        // Today's tabs, and pins and kept tabs whose page is up. Asleep
        // they filled the grid with blank tiles ahead of pages you had
        // just been reading; awake they are pages you were just on, and
        // a window of pins and one tab had no ⌃Tab at all without them.
        // The one you are on leads even if something else was touched
        // later, a tab opened in the background, say.
        // The other spaces' too, each row left in memory, Mail's and the
        // shared pins' aside (a shared pin is in this row already).
        var homes: [Tab.ID: Space] = [:]
        var seen = Set(tabs.map(\.id))
        var pool = tabs
        if spacesShown, SwitchReach.current == .everySpace {
            for space in spaces where space.id != spaceID {
                for tab in parked[space.id]?.tabs ?? [] where seen.insert(tab.id).inserted && !Switcher.agents(tab) && tab.guest == nil {
                    pool.append(tab)
                    homes[tab.id] = space
                }
            }
        }
        // An agent's own tabs aren't yours to come back to, here as in
        // the other spaces, unless you kept one or are on it now.
        let sorted = pool
            .filter { $0.id == activeID || !Switcher.agents($0) }
            .filter { ($0.pin == nil && !$0.kept) || !$0.asleep }
            .sorted { ($0.id == activeID ? .distantFuture : $0.touched) > ($1.id == activeID ? .distantFuture : $1.touched) }
        // A pair is one tab, here and in the other spaces alike.
        let kept = Set(Switcher.onePerPair(sorted.map(\.id), pairs: pairs + parked.filter { $0.key != spaceID }.values.flatMap(\.pairs)))
        let eligible = sorted.filter { kept.contains($0.id) }
        let recent = limit.map { Array(eligible.prefix($0)) } ?? eligible
        return (recent, homes.filter { id, _ in recent.contains { $0.id == id } })
    }

    /// ⌃Tab or ⌃⇧Tab. The first press opens the walk one step along, back to
    /// the tab before this one, or round to the oldest, and every press after
    /// takes one more step while ⌃ stays down.
    func switchStep(_ direction: Int) {
        guard switcher.open else {
            let (recent, homes) = recentTabs(limit: nil)
            guard !recent.isEmpty else { return }
            // On a sleeping pin, the first step is the latest of the rest.
            // With the one you are on alone, held, the grid still comes up
            // with its one tile, so the key never seems dead.
            let leads = recent.first?.id == activeID
            let first = direction > 0 ? min(leads ? 1 : 0, recent.count - 1) : recent.count - 1
            switcher.begin(recent, at: first, homes: homes)
            return
        }
        switcher.step(direction)
    }

    /// The arrows, a row at a time up and down.
    func switchMove(_ key: UInt16) {
        switch key {
        case 123: switcher.step(-1)
        case 124: switcher.step(1)
        case 125: switcher.step(min(switcher.across, max(1, switcher.order.count - switcher.at - 1)))
        case 126: switcher.step(-min(switcher.across, max(1, switcher.at)))
        default: break
        }
    }

    /// ⌃ let go of, Return, or a click: go where the walk stopped.
    func landSwitch(on tab: Tab? = nil) {
        guard switcher.open else { return }
        let target = tab ?? switcher.picked
        let home = target.flatMap { switcher.homes[$0.id] }
        switcher.end()
        guard let target else { return }
        if tabs.contains(where: { $0.id == target.id }) { return select(target) }
        // Another space's: it comes back on this tab, and the space comes.
        guard let home, parked[home.id]?.tabs.contains(where: { $0.id == target.id }) == true else { return }
        parked[home.id]?.active = target.id
        switchSpace(to: home.id)
        if activeID != target.id, tabs.contains(where: { $0.id == target.id }) { select(target) }
    }

    /// Escape, or the app losing the keyboard with ⌃ still down: stay put.
    func cancelSwitch() {
        guard switcher.open else { return }
        switcher.end()
    }

    /// ⌃W with the grid up closes the tile it is on, and the walk carries on
    /// among what is left, the quickest way to thin out a pile of tabs.
    func closeSwitched() {
        guard let tab = switcher.picked else { return }
        let home = switcher.homes[tab.id]
        switcher.drop(tab)
        if let home { closeParked(tab, in: home.id) } else { close(tab) }
        if switcher.order.isEmpty { cancelSwitch() }
    }
}

/// The grid itself: a picture of each page, its icon and its title under it,
/// the one the walk is on lifted out of the rest.
struct SwitcherPanel: View {
    let browser: Browser
    var switcher: Switcher
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var solid
    /// Settings › Experimental: the tabs in a row on the page itself.
    @AppStorage(SwitcherStrip.key, store: Store.settings) private var strip = false

    var body: some View {
        if strip {
            SwitcherStripPanel(browser: browser, switcher: switcher)
        } else {
            card
        }
    }

    private var card: some View {
        GeometryReader { space in
            if switcher.showing {
                let across = columns(in: space.size.width)
                grid(across)
                    // In the middle of the window, as Arc's.
                    .position(x: space.size.width / 2, y: space.size.height / 2)
                    .onAppear { switcher.across = across }
                    .onChange(of: across) { _, now in switcher.across = now }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(switcher.showing)
    }

    /// As many across as fit, never more than five: one row, as Arc's.
    private func columns(in width: CGFloat) -> Int {
        let fits = Int((width - 48) / (Switcher.tile.width + Self.gap + Self.pad * 2))
        return max(1, min(Switcher.columns, fits, switcher.order.count))
    }

    private static let gap: CGFloat = 1
    private static let pad: CGFloat = 12

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Radius.floating + 4, style: .continuous)
    }

    private func grid(_ across: Int) -> some View {
        let rows = stride(from: switcher.visibleIndices.lowerBound, to: switcher.visibleIndices.upperBound, by: across).map {
            Array(switcher.order.indices[$0..<min($0 + across, switcher.visibleIndices.upperBound)])
        }
        return VStack(alignment: .leading, spacing: Self.gap) {
            ForEach(rows, id: \.first) { row in
                HStack(spacing: Self.gap) {
                    ForEach(row, id: \.self) { index in
                        let tab = switcher.order[index]
                        Tile(
                            tab: tab,
                            home: switcher.homes[tab.id]?.icon,
                            picture: switcher.pictures[tab.id],
                            picked: index == switcher.at,
                            glassy: glassy,
                            point: { switcher.point(at: index) }
                        )
                        .onTapGesture { browser.landSwitch(on: tab) }
                    }
                }
            }
        }
        .padding(15) // design: Arc's card padding, measured (arc_grid.py)
        .background {
            if #available(macOS 26.0, *), glassy {
                // Liquid Glass, as the field's box has it: the page you are
                // leaving shows through, blurred, tinted with the ground so
                // the titles read over any page. Drawn by the window server;
                // its rim and shadow are the glass's own.
                Color.clear.glassEffect(.regular.tint(Palette.ground.opacity(scheme == .dark ? 0.7 : 0.6)), in: shape)
            } else {
                shape
                    .fill(Palette.ground) // design: the grid's solid card as it was, moved under the glass check
                    .shadow(color: .black.opacity(0.18), radius: 30, y: 10) // design: the grid's solid card as it was, moved under the glass check
            }
        }
        .overlay {
            if !glassy {
                shape.strokeBorder(Palette.hairline, lineWidth: 1).allowsHitTesting(false) // design: the grid's solid card as it was, moved under the glass check
            }
        }
        .fixedSize()
    }

    /// Glass on a Mac that draws it, with transparency left on.
    private var glassy: Bool {
        guard #available(macOS 26.0, *) else { return false }
        return !solid
    }

    private struct Tile: View {
        var tab: Tab
        /// Another space's emoji, for a tab of that space.
        let home: String?
        let picture: NSImage?
        let picked: Bool
        let glassy: Bool
        let point: () -> Void
        @State private var hovering = false

        private var frame: RoundedRectangle {
            RoundedRectangle(cornerRadius: Radius.small + 1, style: .continuous)
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 13) { // design: Arc's picture-to-title gap, measured (arc_grid.py)
                page
                    .frame(width: Switcher.tile.width, height: Switcher.tile.height)
                    .clipShape(frame)
                    .overlay(frame.strokeBorder(Palette.ink.opacity(0.08), lineWidth: 1))
                HStack(spacing: 8) {
                    Mark(icon: tab.icon, letter: tab.monogram, size: 16)
                    Text(tab.label)
                        .font(.system(size: 12, weight: picked ? .medium : .regular))
                        // On glass the gray of the ground's titles went pale
                        // over a bright page; the ink, faded, stays readable.
                        .foregroundStyle(picked ? Palette.ink : glassy ? Palette.ink.opacity(0.62) : Palette.muted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let home {
                        Spacer(minLength: 0)
                        SpaceMark(icon: home, size: 11).fixedSize()
                    }
                }
                .frame(width: Switcher.tile.width, alignment: .leading)
                .padding(.leading, 1)
            }
            .padding(SwitcherPanel.pad)
            .background {
                // Hovered before the pointer has moved, a tile is only marked
                // (Switcher.point): a grid that opened under a resting cursor
                // would otherwise take its first step from wherever the mouse
                // was.
                if picked || hovering {
                    RoundedRectangle(cornerRadius: Radius.control + 2, style: .continuous)
                        .fill(Palette.ink.opacity(glassy ? (picked ? 0.08 : 0.04) : (picked ? 0.1 : 0.05)))
                }
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onContinuousHover { phase in
                if case .active = phase { point() }
            }
        }

        /// The page from the top, the way it was left. Until there is a
        /// picture, the site's icon on a plain ground rather than a blank.
        @ViewBuilder
        private var page: some View {
            if let picture {
                Image(nsImage: picture)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: Switcher.tile.width, height: Switcher.tile.height, alignment: .top)
            } else {
                ZStack {
                    Palette.ink.opacity(0.04)
                    Mark(icon: tab.icon, letter: tab.monogram, size: 22, dim: tab.asleep)
                }
            }
        }
    }
}
