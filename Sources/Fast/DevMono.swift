import AppKit
import Combine
import SwiftUI

/// The face DevTools sets code in. As in Chromium, whose DevTools has no font
/// setting of its own and sets code in CSS `monospace`, which is the
/// browser's Fixed-width font (Settings > Appearance > Customize fonts):
/// Yab's Fixed-width font (Appearance > Fonts > Customize…) is DevTools'
/// too. Left at Default, DevTools keeps SF Mono.
@MainActor @Observable final class DevMono {
    static let shared = DevMono()
    /// The family chosen and installed here, empty for SF Mono. DevSheet
    /// lays its panes out again when it changes.
    private(set) var family: String
    /// The same, for fonts made outside a view's body (table cells).
    nonisolated(unsafe) private static var resolved = installed(PageFonts.read().fixed)
    @ObservationIgnored private var watch: AnyCancellable?

    private init() {
        family = Self.resolved
        watch = NotificationCenter.default.publisher(for: PageAppearance.changed)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let next = Self.installed(PageFonts.read().fixed)
                    guard next != self.family else { return }
                    Self.resolved = next
                    self.family = next
                    DevTools.setMono(next)
                }
            }
    }

    /// The family when it is installed on this Mac, else empty.
    nonisolated static func installed(_ family: String) -> String {
        guard !family.isEmpty, NSFontManager.shared.availableMembers(ofFontFamily: family)?.isEmpty == false else { return "" }
        return family
    }

    nonisolated static var current: String { resolved }

    nonisolated static func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let family = resolved
        guard !family.isEmpty else { return .system(size: size, weight: weight, design: .monospaced) }
        return .custom(family, fixedSize: size).weight(weight)
    }

    nonisolated static func nsFont(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let system = NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        let family = resolved
        guard !family.isEmpty else { return system }
        let descriptor = NSFontDescriptor(fontAttributes: [.family: family])
            .addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: weight]])
        return NSFont(descriptor: descriptor, size: size) ?? system
    }
}
