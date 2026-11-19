import SwiftUI

/// The band above the page while the column is on the right, in a window
/// (`Browser.headBand`): the lights at the left, where the hand goes for
/// them, and the site's name in the middle, as a title bar has it. It is
/// not there until the pointer rests in the seam above the page; then the
/// page moves down to make room for it, as under a title bar, and back up
/// once the pointer has left it (`Browser.moveHead`, Brim). The column
/// keeps the whole height beside it, its doors at its own top. The rest of
/// the band is the window's to be dragged by, and a double-click fills the
/// screen.
///
/// Nothing is drawn under it: it is the backdrop's own top. In full screen
/// there is none: the lights are macOS's, from the top.
struct HeadBand: View {
    var browser: Browser

    var body: some View {
        ZStack {
            DragStrip()

            if let tab = browser.active {
                Title(tab: tab)
                    // Clear of the lights on either side, by the same
                    // amount, so it stays on the band's middle.
                    .padding(.horizontal, Metrics.lights + 24)
                    .allowsHitTesting(false)
            }

            HStack(spacing: 0) {
                Lights()
                    .frame(width: Lights.run)
                    .padding(.leading, Lights.first - Lights.lead)
                    .opacity(browser.stillLights ? 0 : 1)
                Spacer(minLength: 0)
            }
        }
        .frame(height: Metrics.row)
        .frame(maxWidth: .infinity, alignment: .top)
        .ignoresSafeArea()
    }

    /// The site, as the plate names it; the page's own name off the web.
    private struct Title: View {
        var tab: Tab
        @Environment(\.tone) private var tone

        var body: some View {
            let facts = SiteFacts(tab: tab)
            Text(facts.isSite ? facts.site : tab.label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.muted(on: tone))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
