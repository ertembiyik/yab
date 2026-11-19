import SwiftUI
import AppKit

// design: file, the field drawn in miniature at its own sizes (Omnibox.swift's points), over the space's look, for the menu's pictures

/// Full or Compact: a menu as Window's is, whose answers are pictures of
/// the field over the space's own look, the chosen one small beside its
/// name in the row.
struct FieldMenu: View {
    @Bindable var prefs: Preferences
    @Environment(\.colorScheme) private var scheme
    @State private var pictures = Pictures()

    var body: some View {
        PictureMenu(title: "Field", options: [("Full", false, picture(false)), ("Compact", true, picture(true))],
                    small: NSSize(width: 30, height: 19),
                    notes: [false: "A big box with sections and actions",
                            true: "A small card with the top results"],
                    selection: $prefs.compactField)
    }

    /// Drawn once for what it shows, as Window's pictures are: half the
    /// size it is drawn at, so its lines stay sharp.
    private func picture(_ compact: Bool) -> NSImage {
        let paint = SpacePaint(prefs)
        let key = ["\(compact)", scheme == .dark ? "dark" : "light", paint.swatch, paint.color, "\(paint.grain)"].joined(separator: " ")
        if let kept = pictures.kept[key] { return kept }
        let renderer = ImageRenderer(content: FieldPicture(prefs: prefs, compact: compact).environment(\.colorScheme, scheme))
        renderer.scale = 2
        let image = renderer.nsImage ?? NSImage()
        image.size = NSSize(width: 66, height: 42)
        if pictures.kept.count > 24 { pictures.kept.removeAll() }
        pictures.kept[key] = image
        return image
    }

    private final class Pictures {
        var kept: [String: NSImage] = [:]
    }
}

/// The field as ⌘T shows it in a window 1200 points wide, drawn small:
/// Full is the box, 750 by 475, its rows in parts under headings and its
/// foot's pills over them; Compact the card, 540 wide and as tall as its
/// five rows. Both stand where Omnibox puts the field, its top 122 down,
/// so the field's line is at one height in the two.
struct FieldPicture: View {
    @Bindable var prefs: Preferences
    let compact: Bool
    @Environment(\.colorScheme) private var scheme

    /// Window's picture's size (WindowPicture), its window 1200 points wide.
    static let size = CGSize(width: 132, height: 84)
    private static let room = CGSize(width: 1200, height: 1200 * 84 / 132)

    var body: some View {
        let paint = SpacePaint(prefs)
        let dark = scheme == .dark
        let scale = Self.size.width / Self.room.width
        ZStack(alignment: .topLeading) {
            // Its deep tone halfway to the dark window's, so a gray look
            // stays a gray and doesn't go to black.
            FieldWallpaper(light: Color(nsColor: paint.color(dark: false)),
                           deep: Color(nsColor: paint.color(dark: false).blended(withFraction: 0.5, of: paint.color(dark: true)) ?? paint.color(dark: true)))
            Group {
                if compact { card(paint: paint, dark: dark) } else { box(dark: dark) }
            }
            .frame(width: Self.room.width, height: Self.room.height, alignment: .topLeading)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .overlay { FieldPictureGrain(amount: max(paint.grain, 0.25)) }
        .drawingGroup()
        // Window's picture's corner and edge (WindowPicture).
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
    }

    // MARK: the two

    /// Full: the box, 750 by 475 at the field's place, corner 26.
    private func box(dark: Bool) -> some View {
        let ink = dark ? Color.white : Color.black
        return ZStack(alignment: .topLeading) {
            FieldPictureGlass(dark: dark, corner: 26)
            bar(x: 50, y: 29, width: 170, height: 24, ink.opacity(0.7))
            // Its rows in two parts under their headings, going out under the foot.
            ZStack(alignment: .topLeading) {
                let rows = Self.boxRows
                ForEach(rows.indices, id: \.self) { index in
                    let row = rows[index]
                    if row.heading {
                        bar(x: 16, y: row.y + 7, width: row.width, height: 14, ink.opacity(0.3))
                    } else {
                        if index == 1 {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(ink.opacity(0.08))
                                .frame(width: 734, height: 38)
                                .offset(x: 8, y: row.y)
                        }
                        tile(y: row.y + 19, ink)
                        bar(x: 50, y: row.y + 19, width: row.width, height: 16, ink.opacity(0.42))
                    }
                }
            }
            .frame(width: 750, height: 475, alignment: .topLeading)
            .mask(LinearGradient(stops: [.init(color: .black, location: 372 / 475), .init(color: .clear, location: 425 / 475)],
                                 startPoint: .top, endPoint: .bottom))
            foot(ink)
        }
        .frame(width: 750, height: 475, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .shadow(color: .black.opacity(dark ? 0.45 : 0.18), radius: 22, y: 10)
        .offset(x: 225, y: 122)
    }

    /// Compact: the card, 540 wide, its field 52 and five rows of 40 inside 6, corner 18.
    private func card(paint: SpacePaint, dark: Bool) -> some View {
        let ink = dark ? Color.white : Color.black
        let height: CGFloat = 52 + 5 * 40 + 12
        return ZStack(alignment: .topLeading) {
            FieldPictureGlass(dark: dark, corner: 18)
            bar(x: 50, y: 26, width: 170, height: 24, ink.opacity(0.7))
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: paint.color(dark: dark)).opacity(0.6))
                .frame(width: 528, height: 40)
                .offset(x: 6, y: 58)
            ForEach(Array([210, 160, 240, 130, 190].enumerated()), id: \.offset) { index, width in
                let y = 58 + CGFloat(index) * 40 + 20
                tile(y: y, ink)
                bar(x: 50, y: y, width: CGFloat(width), height: 16, ink.opacity(index == 0 ? 0.75 : 0.42))
            }
        }
        .frame(width: 540, height: height, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(dark ? 0.45 : 0.18), radius: 22, y: 10)
        .offset(x: 330, y: 122)
    }

    /// The box's foot: Yab's round menu and Invite a Friend on the left,
    /// what Return does and Actions on the right, pills of 34 at 8 in.
    private func foot(_ ink: Color) -> some View {
        let y: CGFloat = 475 - 8 - 34
        let middle = y + 17
        let right: CGFloat = 750 - 8 - 262
        return ZStack(alignment: .topLeading) {
            pill(x: 8, y: y, width: 34, ink)
            bar(x: 18, y: middle, width: 14, height: 6, ink.opacity(0.65))
            pill(x: 50, y: y, width: 150, ink)
            key(x: 62, y: middle, ink)
            bar(x: 84, y: middle, width: 100, height: 14, ink.opacity(0.6))
            pill(x: right, y: y, width: 262, ink)
            bar(x: right + 14, y: middle, width: 62, height: 14, ink.opacity(0.7))
            key(x: right + 84, y: middle, ink)
            bar(x: right + 116, y: middle, width: 70, height: 14, ink.opacity(0.42))
            key(x: right + 194, y: middle, ink)
            key(x: right + 216, y: middle, ink)
        }
    }

    /// The box's rows from the field's foot down: a heading (12 point,
    /// 4 above and 6 below), two rows of 38, a heading 12 above, the rest.
    private static let boxRows: [(y: CGFloat, width: CGFloat, heading: Bool)] = {
        var out: [(CGFloat, CGFloat, Bool)] = []
        var y: CGFloat = 58
        func heading(_ width: CGFloat, top: CGFloat) { out.append((y + top, width, true)); y += top + 15 + 6 }
        func row(_ width: CGFloat) { out.append((y, width, false)); y += 38 }
        heading(36, top: 4)
        row(210); row(160)
        heading(84, top: 12)
        [240, 180, 270, 150, 220, 200].forEach { row(CGFloat($0)) }
        return out.map { (y: $0.0, width: $0.1, heading: $0.2) }
    }()

    // MARK: parts

    private func bar(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, _ color: Color) -> some View {
        Capsule().fill(color).frame(width: width, height: height).offset(x: x, y: y - height / 2)
    }

    /// A row's picture: the 22-point tile at the gutter, 16 in.
    private func tile(y: CGFloat, _ ink: Color) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(ink.opacity(0.2)).frame(width: 22, height: 22).offset(x: 16, y: y - 11)
    }

    private func pill(x: CGFloat, y: CGFloat, width: CGFloat, _ ink: Color) -> some View {
        Capsule().fill(ink.opacity(0.1))
            .overlay(Capsule().strokeBorder(ink.opacity(0.16), lineWidth: 1.5))
            .frame(width: width, height: 34).offset(x: x, y: y)
    }

    private func key(x: CGFloat, y: CGFloat, _ ink: Color) -> some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(ink.opacity(0.22)).frame(width: 18, height: 18).offset(x: x, y: y - 9)
    }
}

/// The card's glass over the wallpaper: dark on a dark window, light on a
/// light one, as the field is drawn as the page under it is.
private struct FieldPictureGlass: View {
    let dark: Bool
    let corner: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        shape.fill(dark ? Color(white: 0.1).opacity(0.55) : Color.white.opacity(0.62))
            .overlay(shape.strokeBorder((dark ? Color.white : Color.black).opacity(dark ? 0.14 : 0.08), lineWidth: 1.5))
    }
}

/// The space's look as a wallpaper: its color and its deep one, blurred
/// together, with a lighter light across them.
private struct FieldWallpaper: View {
    let light: Color
    let deep: Color

    var body: some View {
        GeometryReader { space in
            let w = space.size.width, h = space.size.height
            ZStack {
                light.opacity(0.55).background(deep)
                Ellipse().fill(light).frame(width: w * 0.95, height: h * 1.1).position(x: w * 0.3, y: h * 0.32)
                Ellipse().fill(Color.white.opacity(0.45)).frame(width: w * 0.7, height: h * 0.5).position(x: w * 0.42, y: h * 0.0)
                Ellipse().fill(deep).frame(width: w * 0.7, height: h * 0.8).position(x: w * 0.08, y: h * 1.0)
                Ellipse().fill(light.opacity(0.7)).frame(width: w * 1.05, height: h * 1.1).position(x: w * 0.95, y: h * 0.9)
            }
            .blur(radius: w * 0.09)
        }
    }
}

/// Fine grain over the wallpaper, as the look's own is.
private struct FieldPictureGrain: View {
    let amount: Double

    var body: some View {
        Canvas { context, size in
            var seed: UInt64 = 0x9E3779B97F4A7C15
            for _ in 0..<Int(size.width * size.height / 6) {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let x = CGFloat(seed >> 40 & 0xFFFF) / 65535 * size.width
                let y = CGFloat(seed >> 20 & 0xFFFF) / 65535 * size.height
                let white = seed & 1 == 0
                context.fill(Path(CGRect(x: x, y: y, width: 0.6, height: 0.6)),
                             with: .color((white ? Color.white : Color.black).opacity(0.18 * amount)))
            }
        }
        .allowsHitTesting(false)
    }
}
