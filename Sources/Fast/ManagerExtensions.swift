import AppKit

/// Password managers' extensions, in one place whichever engine draws the
/// pages: the CEF profile's list while Chromium is the default, the same list
/// Settings › Extensions shows, WebKit's otherwise. Everything that asks what
/// is installed, where its pages are, or adds or turns on one asks here.
/// With Chromium the default, WebKit's list is a leftover at rest: a manager
/// in it runs on no page.
@MainActor
@Observable final class ManagerExtensions {
    static let shared = ManagerExtensions()

    /// The manager last asked to be added on Chromium, whose list has one
    /// `busy` for everything it does.
    private var addingID: String?
    @ObservationIgnored private var images: [Data: NSImage] = [:]

    /// The window in front's CEF profile's list; nil under WebKit.
    var native: ChromiumExtensions? {
        guard PageEngineFactory.chromiumEnabled,
              let browser = BrowserWindows.shared.activeBrowser ?? Extensions.shared.browser else { return nil }
        return ChromiumExtensions.of(browser)
    }

    var installed: [Installed] {
        guard let native else { return Extensions.here.installed }
        return native.items.map {
            Installed(id: $0.id, name: $0.name, version: $0.version, enabled: $0.enabled, fromStore: true, permissions: [])
        }
    }

    /// Where an installed extension's own pages are. On WebKit an extension
    /// at rest has no context yet, so no address.
    func base(_ id: String) -> URL? {
        guard native != nil else { return Extensions.here.contexts[id]?.baseURL }
        return ChromiumExtensions.validID(id) ? URL(string: "chrome-extension://\(id)/") : nil
    }

    /// Every extension's origin: frames of these are its menus, not the page's.
    var origins: [String] {
        guard native != nil else { return Extensions.shared.contexts.values.map(\.baseURL.absoluteString) }
        return installed.compactMap { base($0.id)?.absoluteString }
    }

    func icon(_ id: String, side: CGFloat) -> NSImage? {
        guard let native else { return Extensions.here.icon(for: id, side: side) }
        guard let data = native.items.first(where: { $0.id == id })?.iconData else { return nil }
        if let known = images[data] { return known }
        let image = NSImage(data: data)
        images[data] = image
        return image
    }

    /// Read the list again: Chromium's is kept in its profile, and nothing
    /// here hears it change behind Yab's back.
    func refresh() {
        guard let native else { return }
        Task { @MainActor in _ = try? await native.list() }
    }

    func setEnabled(_ id: String, _ on: Bool) {
        guard let native else { Extensions.here.setEnabled(id, on); return }
        native.perform { try await native.setEnabled(id, on) }
    }

    /// Adds a manager from the store. `confirm` false: the person has said
    /// yes already, on the welcome's card.
    func add(_ id: String, confirm: Bool = true) {
        guard !ApplePasswordExtensionRoute.intercept(id) else { return }
        guard let native else { Extensions.here.install(from: id, confirm: confirm); return }
        addingID = id
        if !confirm {
            native.perform { _ = try await native.installFromStore(id) }
        } else if #available(macOS 15.4, *), let browser = BrowserWindows.shared.activeBrowser {
            native.reviewInstall(id, browser: browser, place: .settings)
        }
    }

    /// The manager being added now.
    var adding: String? {
        guard let native else { return Extensions.here.busy }
        return native.busy ? addingID : nil
    }

    /// Its last add failed.
    func addFailed(_ id: String) -> Bool {
        guard let native else { return Extensions.here.installErrors[PasswordManagers.canonical(id)] != nil }
        return addingID == id && !native.busy && native.failure != nil
    }

    /// The extension's own button on this tab: its popup.
    func press(_ id: String, on tab: Tab?) {
        if let tab, tab.engineKind == .chromium {
            ChromiumColumn.shared.press(id, tab: tab)
        } else {
            Extensions.here.press(id)
        }
    }
}
