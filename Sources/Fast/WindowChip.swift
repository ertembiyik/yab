import SwiftUI
import AppKit

/// "Window blocked", on the plate beside the site, from the moment a page
/// asks for a window it doesn't get until the page is left (WindowGate).
/// Pressed, the Mac's own menu under it: "Open <place>" for each place it was
/// going, in that site's icon, and "Always allow on <site>".
struct WindowChip: View {
    let browser: Browser
    var tab: Tab
    @State private var hovering = false
    @State private var box = ViewBox()

    static let words = "Window blocked"
    /// Its anchor's name, for the bench to find it by.
    static let anchorID = "yab.window-chip"
    static let height: CGFloat = 22
    static let size: CGFloat = 11.5
    static let pad: CGFloat = 8

    /// Its width, worked out from the words rather than measured, so the
    /// plate fades the site under it in the same pass it is laid out in.
    static var width: CGFloat {
        let font = NSFont.systemFont(ofSize: size * SidebarTypography.current / 14)
        return (words as NSString).size(withAttributes: [.font: font]).width.rounded(.up) + 2 * pad
    }

    /// How much of the site the column's plate fades under the chip, with
    /// `doors` standing before it and the sliders' room after it, shown or
    /// not: the chip stands where it will when they come (SidePlate).
    static func cover(after doors: Int) -> CGFloat {
        CGFloat(doors) * (SidePlate.door + 2) + width + 2 + SidePlate.door + SidePlate.air
    }

    var body: some View {
        if !tab.windows.blocked.isEmpty {
            Button { BlockedMenu.show(for: tab, in: browser, under: box.view) } label: {
                Text(Self.words)
                    .sidebarFont(size: Self.size)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, Self.pad)
                    .frame(height: Self.height)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                            .fill(Palette.ink.opacity(hovering ? 0.11 : 0.07))
                    )
                    .contentShape(RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
            }
            .buttonStyle(Door.Give())
            .focusable(false)
            .onHover { hovering = $0 }
            .accessibilityLabel("Window blocked, show options")
            .background(ChipAnchor(box: box))
            .transition(.opacity)
        }
    }
}

/// A plain view under the chip, for its menu to hang from.
private struct ChipAnchor: NSViewRepresentable {
    let box: ViewBox
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.identifier = NSUserInterfaceItemIdentifier(WindowChip.anchorID)
        box.view = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { box.view = view }
}

/// The chip's menu.
@MainActor
enum BlockedMenu {
    /// The menu while it is up, for the bench to read and let go.
    private(set) static weak var shown: NSMenu?

    /// In the searchable panel (ActionMenu.swift), hung under the chip.
    static func show(for tab: Tab, in browser: Browser, under view: NSView?) {
        guard let view else { return }
        let menu = make(for: tab, in: browser)
        shown = menu
        ActionMenu.show(menu, under: view) { shown = nil }
    }

    /// Its rows: each place the page was going, newest first, then the
    /// site's always. A window with nowhere to go yet is one row, for the
    /// rest of this visit.
    static func make(for tab: Tab, in browser: Browser) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        var blank = false
        for window in tab.windows.blocked {
            if let place = WindowGate.place(window.url) {
                let line = PageMenuItem("Open \(place)") { [weak browser, weak tab] in
                    guard let browser, let tab else { return }
                    browser.openBlocked(window, from: tab)
                }
                line.image = icon(place)
                MenuMark.show(line)
                menu.addItem(line)
            } else if !blank {
                blank = true
                let line = PageMenuItem("Allow on this visit") { [weak browser, weak tab] in
                    guard let browser, let tab else { return }
                    browser.openBlocked(window, from: tab)
                }
                MenuMark.put("macwindow", on: line)
                menu.addItem(line)
            }
        }
        if let site = tab.windows.blocked.first?.site {
            let always = PageMenuItem("Always allow on \(site)") { [weak browser, weak tab] in
                guard let browser, let tab else { return }
                browser.allowWindows(on: tab)
            }
            MenuMark.put("checkmark", on: always)
            menu.addItem(always)
        }
        return menu
    }

    /// The place's own icon, or its site's, at a menu's 16 points; the
    /// globe until one has been fetched.
    private static func icon(_ place: String) -> NSImage {
        let found = Favicons.shared.cached(place) ?? Favicons.shared.cached(Browser.site(place))
        guard let found else {
            Favicons.shared.fetch(host: place)
            return MenuMark.image("globe")
        }
        return NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            found.draw(in: rect)
            return true
        }
    }
}
