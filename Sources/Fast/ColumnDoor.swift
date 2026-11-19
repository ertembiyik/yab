import AppKit
import SwiftUI

// The column's own door, Arc's sidebar mark (feedback #250, #287): right
// after the lights, a door like back, forward and reload, doing what ⌘S
// does. The same mark in the card the column comes out over the page as,
// where it puts the column back, as Arc's does. With the column on the
// right it stands at the outer edge, the mark's pane on that side.
//
// The row it stands in folds as the column narrows, as Arc's does: reload
// and this door go into "⋯" beside back and forward. Where it folds is
// worked out from the doors' own sizes (ColumnHead.fit), never written
// down as a width. Reading mode has no door in this row.

/// The column header's row: where its doors stand, and which of them fit.
@MainActor
enum ColumnHead {
    /// How much of the row's doors fit beside the lights.
    enum Fit: Equatable {
        /// Back, forward, reload and the column's door.
        case full
        /// Back, forward and "⋯", which holds reload and the column's door.
        case fold
    }

    /// Arc's distance from the green light's center to its sidebar door's
    /// (measured 2026-10-21: 26.8).
    static let fromGreen: CGFloat = 27
    /// The green light's center, from the column's edge: the lights start
    /// Lights.first in (SideBar's header) and run Lights.run, the last
    /// one's center a radius from its end.
    static let green: CGFloat = Lights.first + Lights.run - 2 * Lights.lead
    /// The door's leading edge, from the column's edge: 78 at 30 a door,
    /// 79 at Compact's 28.
    static func doorX(_ size: Door.Size = .header) -> CGFloat {
        green + fromGreen - size.side / 2
    }

    /// The narrowest column with everything in the row: the lights, the
    /// door, a gap, back, forward and reload, and the margin. With the
    /// column on the right the lights are over the page (HeadBand) and the
    /// door at the far end: the margin, the three, a gap, the door, the
    /// margin. 218 and 148, Compact 211 and 140.
    static func full(right: Bool, size: Door.Size = .header, margin: CGFloat = SideBar.margin, showSidebarButton: Bool = true) -> CGFloat {
        if !showSidebarButton { return margin + (right ? 0 : Metrics.sideLights) + size.helm + margin }
        return right ? margin + size.helm + size.gap + size.side + margin
              : doorX(size) + size.side + size.gap + size.helm + margin
    }

    /// The doors' size in the row at this width: the header's, or, in a
    /// column too narrow for even its folded row, Arc's own at its
    /// narrowest: 26 a door and 28 from one door's center to the next
    /// (Arc's 164 pt sidebar, 2026-10-24: back, forward and "⋯" centered
    /// 88, 116 and 144 from the window's edge), which fits the lights,
    /// back, forward and "⋯" at 164.
    static func doors(width: CGFloat, right: Bool, margin: CGFloat = SideBar.margin) -> Door.Size {
        let header = Door.Size.header
        if right || width >= margin + Metrics.sideLights + header.helm + margin { return header }
        return .tight
    }

    /// What the row holds at this width. On the right, everything fits at
    /// the column's narrowest.
    static func fit(width: CGFloat, right: Bool, size: Door.Size = .header, margin: CGFloat = SideBar.margin, showSidebarButton: Bool = true) -> Fit {
        if width >= full(right: right, size: size, margin: margin, showSidebarButton: showSidebarButton) { return .full }
        return .fold
    }
}

/// The sidebar mark: puts the column away, as ⌘S does; in the card,
/// brings it back.
struct ColumnDoor: View {
    var browser: Browser
    var prefs: Preferences

    /// Its tip waits as long as a Mac's own, longer than the doors pressed
    /// all day: it is found once and then left to ⌘S.
    static let tipWait: TimeInterval = 0.7

    /// The mark, its pane on the column's side.
    static func mark(_ flank: Flank) -> String { flank == .right ? "sidebar.right" : "sidebar.left" }

    var body: some View {
        let shut = prefs.sideShut
        let title = browser.columnTitle
        Door(icon: Self.mark(browser.flank), help: title, shortcut: title, tipWait: Self.tipWait) {
            browser.toggleColumn()
        }
        .accessibilityLabel(title)
        .accessibilityAddTraits(shut ? .isSelected : [])
        .benchSpot("column door")
    }
}

/// "⋯" in reload's place, a narrow column's: reload or stop and the
/// column's door, in the Mac's own menu under it. A cross while it is
/// open, as Arc's.
struct HelmMore: View {
    let browser: Browser
    /// The page the doors are for, and whether they are a half's own.
    let tab: Tab?
    var own = false

    @State private var open = false
    @State private var box = ViewBox()

    /// The menu while it is up, for the bench to read and let go.
    static weak var shown: NSMenu?

    var body: some View {
        Door(icon: open ? "xmark" : "ellipsis", on: open, instant: true) { show() }
            .background(MoreAnchor(box: box))
            .accessibilityLabel("More")
            .benchSpot("column more")
    }

    private func show() {
        guard let view = box.view else { return }
        open = true
        let menu = Self.make(browser, tab: tab, own: own)
        // The searchable panel (ActionMenu.swift), hung under the door.
        Self.shown = menu
        ActionMenu.show(menu, under: view) {
            Self.shown = nil
            open = false
        }
    }

    static func make(_ browser: Browser, tab: Tab?, own: Bool) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func line(_ title: String, _ mark: String, keys action: Shortcut.Action, enabled: Bool = true, act: @escaping () -> Void) {
            let item = PageMenuItem(title, act: act)
            MenuMark.put(mark, on: item)
            if let hotkey = Keymap.shared.keys(action) { item.shortcut(hotkey) }
            item.isEnabled = enabled
            menu.addItem(item)
        }
        let mine = own ? tab : nil
        if let tab, tab.loadingShown {
            line("Stop", "xmark", keys: .stopLoading) { browser.stop(tab) }
        } else {
            line("Reload", "arrow.clockwise", keys: .reload, enabled: tab.map { !$0.isBlank } ?? false) {
                browser.reload(mine)
            }
        }
        line(browser.columnTitle, ColumnDoor.mark(browser.flank), keys: .column) { browser.toggleColumn() }
        return menu
    }
}

/// A plain view under "⋯", for its menu to hang from.
private struct MoreAnchor: NSViewRepresentable {
    let box: ViewBox
    func makeNSView(context: Context) -> NSView { let view = NSView(); box.view = view; return view }
    func updateNSView(_ view: NSView, context: Context) { box.view = view }
}
