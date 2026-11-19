import Combine
import Foundation

/// The model's app-level choice. Hardware availability remains FormModel's.
@MainActor
@Observable final class AppleModelControl {
    static let shared = AppleModelControl()
    private(set) var enabled: Bool
    @ObservationIgnored private var changes: AnyCancellable?

    init() {
        enabled = AppleModelAccess.enabled
        changes = NotificationCenter.default.publisher(for: AppleModelAccess.changed)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.enabled = AppleModelAccess.enabled }
            }
    }

    func setEnabled(_ value: Bool) {
        _ = AppleWritingTools.shared
        AppleModelAccess.enabled = value
        enabled = value
    }

    /// The same native menu builder used by the other plan rows.
    func menuEntries() -> [SettingsMenuEntry] {
        if enabled {
            return [.destructive("Disable in Yab") { self.setEnabled(false) }]
        }
        return [.item("Enable in Yab") { self.setEnabled(true) }]
    }
}
