import Observation

/// Counts Observation's change notices for what `read` reads, calling `told` on each.
@MainActor
final class ObservedWrites {
    private(set) var count = 0
    private let read: () -> Void
    private let told: () -> Void
    private var live = true

    init(_ read: @escaping () -> Void, told: @escaping () -> Void = {}) {
        self.read = read
        self.told = told
        arm()
    }

    func cancel() { live = false }

    private func arm() {
        guard live else { return }
        withObservationTracking(read) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.live else { return }
                self.count += 1
                self.told()
                self.arm()
            }
        }
    }
}
