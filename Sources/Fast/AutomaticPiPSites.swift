import SwiftUI

/// Explicit local-profile exceptions to the global automatic-video switch.
/// An absent host inherits it; allowing a site again removes its exception.
/// Calls and manually requested PiP do not consult this list.
@MainActor
@Observable final class AutomaticPiPSites {
    static let shared = AutomaticPiPSites()
    nonisolated static let key = "float.deniedSites"

    private(set) var denied: Set<String>
    private let store: UserDefaults

    init(store: UserDefaults = Store.settings) {
        self.store = store
        denied = Set((store.stringArray(forKey: Self.key) ?? []).compactMap {
            Self.site(URL(string: "https://" + $0))
        })
    }

    /// Exact site identity, matching Site Controls' www alias without
    /// inheriting exceptions from a parent domain. Reparse the serialized
    /// URL so Foundation returns an IDN's ASCII host, as Address does.
    nonisolated static func site(_ url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              var host = URL(string: url.absoluteString)?.host()?.lowercased(), !host.isEmpty else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host.isEmpty ? nil : host
    }

    /// This is only the site exception. The existing caller still owns the
    /// master switch, known-player, fullscreen, minimize and call policy.
    func allows(_ url: URL?) -> Bool {
        guard let site = Self.site(url) else { return true }
        return !denied.contains(site)
    }

    func setAllowed(_ allowed: Bool, for url: URL?) {
        guard let site = Self.site(url) else { return }
        var next = denied
        if allowed { next.remove(site) } else { next.insert(site) }
        guard next != denied else { return }
        denied = next
        if next.isEmpty { store.removeObject(forKey: Self.key) }
        else { store.set(next.sorted(), forKey: Self.key) }
    }
}
