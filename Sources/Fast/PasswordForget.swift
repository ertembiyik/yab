import AppKit
import Combine

/// Keep the chosen login, or the next surviving row after it, when the
/// list is read again. At the end, walk back to the nearest survivor.
struct PasswordListSelection {
    let ids: [String]
    let spot: Int
    let picks: Set<String>

    func restored(in remaining: [String]) -> (spot: Int, picks: Set<String>) {
        let available = Set(remaining)
        let fallback = min(max(0, spot), max(0, remaining.count - 1))
        guard ids.indices.contains(spot) else { return (fallback, picks.intersection(available)) }
        let chosen = ids[spot...].first(where: { available.contains($0) })
            ?? ids[..<spot].reversed().first(where: { available.contains($0) })
        return (chosen.flatMap { remaining.firstIndex(of: $0) } ?? fallback, picks.intersection(available))
    }
}

/// Only the classifications already shown in the list, never passwords.
/// Kept in memory while a confirmation is up so warning filters have rows
/// before the fresh background analysis answers.
struct PasswordListWarnings {
    var groups: [String: String] = [:]
    var shared: [String: Int] = [:]
    var weak: Set<String> = []
    var leaked: [String: Int] = [:]

    init(groups: [String: String] = [:], shared: [String: Int] = [:],
         weak: Set<String> = [], leaked: [String: Int] = [:]) {
        self.groups = groups
        self.shared = shared
        self.weak = weak
        self.leaked = leaked
    }

    init(stock: PlaceStock) {
        self.init(groups: stock.groups, shared: stock.shared, weak: stock.weak, leaked: stock.leaked)
    }

    /// The same membership used by the real Weak, Reused and Leaked rows.
    func contains(_ id: String, filter: Int) -> Bool {
        switch filter {
        case 3: return leaked[id] != nil
        case 4: return (shared[id] ?? 0) > 0
        case 5: return weak.contains(id)
        default: return true
        }
    }

    /// Deleting the other login in a reused pair makes its survivor unique.
    /// Do not carry that old count, or a deleted login's warning, forward.
    func retained(in ids: Set<String>) -> PasswordListWarnings {
        let groups = self.groups.filter { ids.contains($0.key) }
        var counts: [String: Int] = [:]
        for group in groups.values { counts[group, default: 0] += 1 }
        let shared = groups.compactMapValues { group -> Int? in
            let others = (counts[group] ?? 1) - 1
            return others > 0 ? others : nil
        }
        return PasswordListWarnings(groups: groups, shared: shared,
                                    weak: weak.intersection(ids), leaked: leaked.filter { ids.contains($0.key) })
    }

    func apply(to stock: inout PlaceStock) {
        stock.groups = groups
        stock.shared = shared
        stock.weak = weak
        stock.leaked = leaked
        // The memo otherwise sees counts only: equal-sized warnings can
        // name different logins, and must make different filtered rows.
        stock.version += 1
    }
}

extension Browser {
    /// A result changes membership while the person may have moved the
    /// selection. Follow the rows chosen now, not an earlier async cursor.
    func replacePasswordWarnings(_ warnings: PasswordListWarnings) {
        guard query.place == .passwords else { return }
        let selection = PasswordListSelection(ids: placeItems.map(\.id), spot: query.spot, picks: query.picks)
        var stock = query.stock
        warnings.retained(in: Set(stock.logins.map(\.id))).apply(to: &stock)
        query.stock = stock
        let restored = selection.restored(in: placeItems.map(\.id))
        query.spot = restored.spot
        query.picks = restored.picks
    }

    /// Forget still dismisses the field before asking. Only the passwords
    /// list that owned the action comes back after its answer.
    func forgetPasswords(_ entries: [Vault.Entry], asking question: Question) {
        let returning = PasswordListReturn(self, picked: entries.count > 1
            ? Set(entries.map { "login." + $0.id }) : nil)
        close()
        returning?.watch()
        var question = question
        if let window = returning?.window { question.window = window.windowNumber }
        Task { @MainActor in
            // The window may close between the action and this task. Do
            // not enqueue a question after its close notification passed.
            guard returning?.canAsk != false else { return }
            let yes = await Questions.shared.ask(question)
            if yes {
                for entry in entries {
                    Vault.forget(host: entry.host, user: entry.user)
                    OneTime.forget(host: entry.host, user: entry.user)
                }
            }
            returning?.restore()
        }
    }
}

/// A confirmation's origin, held only until that confirmation finishes.
/// A field opened in between, another tab/Space or a closed window gives
/// up the return permanently, even if the user later comes back.
@MainActor
private final class PasswordListReturn {
    private weak var browser: Browser?
    private(set) weak var window: NSWindow?
    private let words: String
    private let filter: Int
    private let site: String?
    private let selection: PasswordListSelection
    private let warnings: PasswordListWarnings
    private var valid = true
    private var watches = Set<AnyCancellable>()

    init?(_ browser: Browser, picked: Set<String>?) {
        guard browser.query.place == .passwords, browser.query.form == nil,
              let window = BrowserWindows.shared.window(for: browser),
              window.isVisible, !window.isMiniaturized else { return nil }
        self.browser = browser
        self.window = window
        words = browser.typed
        filter = browser.query.placeFilter
        site = browser.query.stock.site
        warnings = PasswordListWarnings(stock: browser.query.stock)
        selection = PasswordListSelection(ids: browser.placeItems.map(\.id), spot: browser.query.spot,
                                          picks: picked ?? browser.query.picks)
    }

    /// Start after this action's own close, so it doesn't cancel itself.
    func watch() {
        guard let browser, let window else { valid = false; return }
        func cancel<T>(_ publisher: AnyPublisher<T, Never>) {
            publisher.sink { [weak self] _ in self?.valid = false }.store(in: &watches)
        }
        cancel(browser.query.observed(\.typed).removeDuplicates().dropFirst().eraseToAnyPublisher())
        cancel(browser.query.observed(\.place).removeDuplicates().dropFirst().eraseToAnyPublisher())
        cancel(browser.changes(\.editing).removeDuplicates().dropFirst().eraseToAnyPublisher())
        cancel(browser.changes(\.tuning).removeDuplicates().dropFirst().eraseToAnyPublisher())
        cancel(browser.changes(\.activeID).removeDuplicates().dropFirst().eraseToAnyPublisher())
        cancel(browser.changes(\.spaceID).removeDuplicates().dropFirst().eraseToAnyPublisher())
        if let tab = browser.active {
            cancel(tab.loadMoved.eraseToAnyPublisher())
            cancel(tab.changes(\.address).removeDuplicates().dropFirst().eraseToAnyPublisher())
        }
        cancel(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification, object: window)
            .eraseToAnyPublisher())
    }

    var canAsk: Bool {
        guard valid, let browser, let window else { return false }
        return window.isVisible && !window.isMiniaturized
            && BrowserWindows.shared.window(for: browser) === window
    }

    func restore() {
        watches.removeAll()
        guard valid, let browser, let window,
              window.isVisible, !window.isMiniaturized,
              BrowserWindows.shared.window(for: browser) === window,
              NSApp.keyWindow == nil || NSApp.keyWindow === window,
              !browser.tuning, !browser.editing, browser.query.place == nil,
              browser.typed.isEmpty, Questions.shared.current == nil else { return }
        // Read the list again, not the old stock: confirmed deletions must
        // disappear and a cancelled confirmation must retain its rows.
        browser.openPlace(.passwords, words: words)
        // openPlace starts a fresh asynchronous analysis. Until it answers,
        // retain known warning membership for the freshly read survivors.
        browser.replacePasswordWarnings(warnings)
        browser.query.placeFilter = filter
        browser.query.stock.site = site
        let restored = selection.restored(in: browser.placeItems.map(\.id))
        browser.query.spot = restored.spot
        browser.query.picks = restored.picks
    }
}
