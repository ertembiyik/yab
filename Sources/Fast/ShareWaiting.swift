import SwiftUI

// A tab behind that asks for the screen no longer takes you to it: the ask
// waits on the tab, as every page's question from a tab behind does
// (Browser.ask), and its row says so in words, "wants your screen", where
// the bubble would be one more mark to learn. Going to the tab brings the
// box down over its page. Only Yab's own Share, pressed in the call's
// window, still brings its tab forward (RelayGuard.Hand.yab).

extension Tab {
    /// A share of the screen asked for while the tab was behind, waiting
    /// on it.
    var wantsScreen: Bool {
        guard let ask = asks.first else { return false }
        return ask.parked && ask.sharing
    }
}

/// The words on the row of a tab waiting to be shown a screen: muted, at
/// the row's end where "Presenting" would be, the title giving way to them.
struct ShareWaiting: View {
    var tab: Tab
    /// Room for them: a tab in the strip narrower than `fits` keeps the
    /// bubble on its mark instead.
    var shown = true
    @Environment(\.tone) private var tone

    /// The narrowest tab in the strip that has the words and still some of
    /// its title: a tab at its full width (Metrics.tabWidth), not one the
    /// row has squeezed.
    static let fits: CGFloat = 180

    var body: some View {
        if shown, tab.wantsScreen {
            Text("wants your screen")
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.muted(on: tone))
                .lineLimit(1)
                .fixedSize()
                .padding(.trailing, 16)
                .transition(.opacity)
        }
    }
}
