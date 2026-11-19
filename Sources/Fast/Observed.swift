import Combine
import Foundation
import Observation

// The window's state is kept in Observation-framework classes (@Observable:
// Preferences, Browser, Tab), so a view's body depends on the properties it
// reads and on nothing else; see docs/state-observation.md. What @Published
// gave besides that, a Combine publisher of each property (`$name`), and
// what AppKit code needs to follow a value, are here.

/// Each watched property's new values, sent in its willSet, before the
/// property holds the value, as @Published's `$name` sent them. A class
/// keeps one (`relay`), and a property that can be watched says so in its
/// willSet: `willSet { relay.send(\.name, newValue) }`.
@MainActor
final class ChangeRelay<Root: AnyObject> {
    private var subjects: [PartialKeyPath<Root>: Any] = [:]
    /// Any watched property about to change, the way objectWillChange told
    /// of every @Published one.
    let any = PassthroughSubject<Void, Never>()

    func send<Value>(_ path: KeyPath<Root, Value>, _ value: Value) {
        (subjects[path] as? PassthroughSubject<Value, Never>)?.send(value)
        any.send()
    }

    /// The value now, as the subscription starts, and every new one after:
    /// `$name` without the property wrapper.
    func publisher<Value>(_ path: KeyPath<Root, Value>, of root: Root) -> AnyPublisher<Value, Never> {
        let subject: PassthroughSubject<Value, Never>
        if let kept = subjects[path] as? PassthroughSubject<Value, Never> {
            subject = kept
        } else {
            subject = PassthroughSubject<Value, Never>()
            subjects[path] = subject
        }
        return Deferred { [weak root] in
            subject.prepend(root.map { [$0[keyPath: path]] } ?? [])
        }
        .eraseToAnyPublisher()
    }
}

/// A class whose properties can be watched with Combine.
@MainActor
protocol Relaying: AnyObject {
    var relay: ChangeRelay<Self> { get }
}

extension Relaying {
    /// What `$name` was: the value now and each new one, in willSet.
    func changes<Value>(_ path: KeyPath<Self, Value>) -> AnyPublisher<Value, Never> {
        relay.publisher(path, of: self)
    }
}

/// AppKit following Observation: `apply` runs now, reading whatever it
/// reads, and again on the next main run-loop turn after any of that
/// changes, until the loop is cancelled or let go. Several changes in one
/// turn run it once. For a view or a controller that draws from Browser,
/// Tab or Preferences without SwiftUI (the column, menus, Settings' window).
@MainActor
final class ObservationLoop {
    private var live = true
    private let apply: @MainActor () -> Void

    init(_ apply: @escaping @MainActor () -> Void) {
        self.apply = apply
        run()
    }

    func cancel() { live = false }

    private func run() {
        guard live else { return }
        withObservationTracking {
            apply()
        } onChange: { [weak self] in
            // Told once, in the first change's willSet, before the property
            // holds the new value: read everything a turn later.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.run() }
            }
        }
    }
}

extension Observable where Self: AnyObject {
    /// `$name` for any Observable: the value now, then each new one a turn later.
    @MainActor
    func observed<Value>(_ path: KeyPath<Self, Value>) -> AnyPublisher<Value, Never> {
        Deferred { [weak self] () -> AnyPublisher<Value, Never> in
            MainActor.assumeIsolated {
                guard let self else { return Empty().eraseToAnyPublisher() }
                let subject = CurrentValueSubject<Value, Never>(self[keyPath: path])
                var first = true
                let loop = ObservationLoop { [weak self, weak subject] in
                    guard let self else { return }
                    let value = self[keyPath: path]
                    if first { first = false } else { subject?.send(value) }
                }
                return subject.handleEvents(receiveCancel: { loop.cancel() }).eraseToAnyPublisher()
            }
        }
        .eraseToAnyPublisher()
    }
}


/// For a test run (YAB_BODY_AUDIT=1): a body SwiftUI ran inside a property's
/// setter, from Observation's willSet, reads the old value and can miss the
/// writes after it (Split.swift's transactions, 2026-10-17). Each such run's
/// own frames, as addresses in the app's image, by how many times, for the
/// bench's `bodyaudit` and `atos`.
@MainActor
enum BodyAudit {
    static let on = ProcessInfo.processInfo.environment["YAB_BODY_AUDIT"] == "1"
    static var seen: [String: Int] = [:]

    static func note(_ view: String) {
        guard on else { return }
        let symbols = Thread.callStackSymbols
        guard symbols.contains(where: { $0.contains("withMutation") }) else { return }
        var frames: [String] = []
        for address in Thread.callStackReturnAddresses.dropFirst() {
            var info = Dl_info()
            let pointer = UnsafeRawPointer(bitPattern: address.uintValue)
            guard let pointer, dladdr(pointer, &info) != 0, let base = info.dli_fbase,
                  let image = info.dli_fname, String(cString: image).hasSuffix("/yab") else { continue }
            frames.append(String(format: "0x%llx", UInt64(address.uintValue - UInt(bitPattern: base)) + 0x1_0000_0000))
            if frames.count == 16 { break }
        }
        seen[view + " " + frames.joined(separator: " "), default: 0] += 1
    }
}
