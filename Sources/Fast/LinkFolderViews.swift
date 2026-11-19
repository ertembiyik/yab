import SwiftUI

// A ⌘-click folder's row as Dia draws its auto group (filmed frame by frame,
// docs/evidence/folder-motion-2026-10-16, section 1): the page's favicon for
// its mark, a gray bar where the name goes while the model is asked, a faint
// light passing over the bar, and once the name comes, a band of color
// crossing it once, left to right, while a blue wash leaves the mark.

/// Dia's numbers.
enum LinkFolderLook {
    /// The band crosses the name at about 200 points a second.
    static let bandSpeed: CGFloat = 200
    static let bandWidth: CGFloat = 56
    /// The bar's light: one pass of 0.55 s, again every second.
    static let passTime: Double = 0.55
    static let passEvery: Double = 1.0
    /// How long the shimmer is drawn at most after the name lands.
    static let shimmerTime: Double = 1.2
    /// The band, trailing to leading, as read off Dia's frames on its mint
    /// sidebar: blue, white, gold, pink-magenta.
    static let band: [Color] = [
        Color(red: 0x8D / 255, green: 0xB8 / 255, blue: 0xE5 / 255), // design: Dia's shimmer band, measured
        .white,
        Color(red: 0xE7 / 255, green: 0xC5 / 255, blue: 0x91 / 255), // design: Dia's shimmer band, measured
        Color(red: 0xE0 / 255, green: 0xA6 / 255, blue: 0xE9 / 255), // design: Dia's shimmer band, measured
    ]
}

/// The gray bar where a ⌘-click folder's name will be, a faint light
/// passing over it, as Dia's skeleton.
struct LinkFolderPlaceholder: View {
    @Environment(\.tone) private var tone
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSince(start).truncatingRemainder(dividingBy: LinkFolderLook.passEvery)
            let x = CGFloat(min(1, t / LinkFolderLook.passTime))
            Capsule(style: .continuous)
                .fill(Palette.hover(on: tone))
                .overlay {
                    GeometryReader { g in
                        LinearGradient(colors: [.clear, .white.opacity(0.35), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: 40)
                            .offset(x: -40 + (g.size.width + 40) * x)
                            .opacity(t < LinkFolderLook.passTime ? 1 : 0)
                    }
                    .clipShape(Capsule(style: .continuous))
                }
        }
        .frame(width: 92, height: 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("Naming folder")
    }
}

/// The band crossing a name once, from when it landed.
struct LinkFolderShimmer: ViewModifier {
    let landed: Date?
    /// Crossed: the overlay and its clock gone, nothing drawn a frame after.
    @State private var over = false

    func body(content: Content) -> some View {
        Group {
            if let landed, !over, Date().timeIntervalSince(landed) < LinkFolderLook.shimmerTime {
                shimmering(content, landed)
            } else {
                content
            }
        }
        .task(id: landed) {
            guard let landed else { return }
            over = false
            try? await Task.sleep(for: .seconds(max(0, LinkFolderLook.shimmerTime - Date().timeIntervalSince(landed))))
            over = true
        }
    }

    private func shimmering(_ content: Content, _ landed: Date) -> some View {
        content.overlay {
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSince(landed)
                LinearGradient(colors: [.clear] + LinkFolderLook.band + [.clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: LinkFolderLook.bandWidth)
                    .offset(x: -LinkFolderLook.bandWidth + LinkFolderLook.bandSpeed * CGFloat(t))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .mask(content)
            .allowsHitTesting(false)
        }
    }
}

/// A ⌘-click folder's mark: the site's icon of the page it grew from, or
/// the emoji its name came with, a blue wash leaving it as the name lands.
struct LinkFolderMark: View {
    var tab: Tab
    /// The emoji it wears in place of the site's icon, for pages of more
    /// than one site.
    var mark: NSImage? = nil
    let landed: Date?
    let size: CGFloat
    let tint: Color
    @State private var over = false

    var body: some View {
        ZStack {
            if let image = mark ?? tab.displayIcon {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            } else {
                Face(pose: .seen, size: SideBar.folder, tint: tint, folder: true, unfolded: true, weight: SideBar.folderWeight)
            }
            if let landed, !over, Date().timeIntervalSince(landed) < LinkFolderLook.shimmerTime {
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSince(landed)
                    RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                        .fill(LinkFolderLook.band[0])
                        .opacity(max(0, 0.7 * (1 - t / 0.6)))
                }
                .allowsHitTesting(false)
            }
        }
        .frame(width: size, height: size)
        .task(id: landed) {
            guard let landed else { return }
            over = false
            try? await Task.sleep(for: .seconds(max(0, LinkFolderLook.shimmerTime - Date().timeIntervalSince(landed))))
            over = true
        }
    }
}
