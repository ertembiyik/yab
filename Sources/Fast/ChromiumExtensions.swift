import Foundation
import Combine
import YabCoreClient
import WebKit

/// Native Chrome extensions belong to a CEF profile, never a WebKit controller.
/// The management document is temporary and never replaces the selected page.
@MainActor
@Observable final class ChromiumExtensions {
    private(set) static var profiles: [String: ChromiumExtensions] = [:]
    static func shared(profile: String, privateMode: Bool = false, store: WKWebsiteDataStore? = nil) -> ChromiumExtensions {
        let key = (privateMode ? "private:" : "regular:") + profile + ":" + scope(of: store)
        if let value = profiles[key] { return value }
        let value = ChromiumExtensions(profile: profile, privateMode: privateMode)
        value.associationStore = store
        profiles[key] = value
        return value
    }

    private static func scope(of store: WKWebsiteDataStore?) -> String {
        store.map { $0.isPersistent ? ($0.identifier?.uuidString ?? "default") : String(describing: ObjectIdentifier($0)) } ?? "unbound"
    }

    /// The list a regular page in `store` draws from, when a page there made
    /// one this launch: found by the store, so a tab whose page isn't built
    /// reads no profile record and starts nothing. `profile`, the one the
    /// tab's last page had, picks among several; with more than one and no
    /// way to tell, none.
    static func existing(in store: WKWebsiteDataStore, profile: String? = nil) -> ChromiumExtensions? {
        guard store.isPersistent else { return nil }
        let prefix = "regular:", suffix = ":" + scope(of: store)
        if let profile, let known = profiles[prefix + profile + suffix] { return known }
        let found = profiles.filter { $0.key.hasPrefix(prefix) && $0.key.hasSuffix(suffix) }
        return found.count == 1 ? found.first?.value : nil
    }

    #if DEBUG
    /// Chrome's list as `list` leaves it, for tests of what the column draws.
    func listedForTest(_ found: [Item]) {
        rows = found
        compose()
    }
    #endif

    static func retirePrivate(_ profile: String) {
        profiles = profiles.filter { !$0.key.hasPrefix("private:" + profile + ":") }
    }

    struct Item: Equatable, Identifiable {
        let id: String
        let name: String
        let version: String
        let state: String
        let optionsURL: URL?
        let about: String
        let iconData: Data?
        /// The folder Chrome loaded it from, and its runtime host permissions.
        var path: String? = nil
        /// How Chrome holds it: "FROM_STORE" (it updates it), "UNPACKED"...
        var location = ""
        var access: JSONValue? = nil
        var issue: String? = nil
        /// Chrome's "Allow in Incognito" for it, and whether it can change:
        /// Yab's one "Allow in private tabs" switch sets it for each.
        var incognito = false
        var incognitoChangeable = false
        /// Chrome's "Allow User Scripts" for it (Chrome 138+), and whether it
        /// asks for userScripts at all: without it Tampermonkey's and
        /// Violentmonkey's scripts never run. The one list keeps the choice.
        var userScripts = false
        var userScriptsChangeable = false
        /// Off since Chrome's updater put in a version that asks for more:
        /// on again only with a gesture, after Yab asked (ChromiumExtensionSync).
        var escalated = false
        /// The kinds of its pages Chrome has open (developerPrivate's views:
        /// TAB_CONTENTS, EXTENSION_SIDE_PANEL, OFFSCREEN_DOCUMENT, its worker;
        /// Chrome leaves popups out); nil from a helper that doesn't say.
        var views: [String]? = nil
        /// A page of its own is open: a tab (or its frame in a site), side
        /// panel or offscreen document, anything but its worker. Reloading it
        /// now would leave that page without its chrome.* (Chrome closes such
        /// tabs when it unloads one).
        var hasOpenPages: Bool {
            views?.contains { !["EXTENSION_SERVICE_WORKER_BACKGROUND", "EXTENSION_BACKGROUND_PAGE"].contains($0) } ?? false
        }
        var enabled: Bool { state == "ENABLED" }
        var storeRow: ChromiumStoreInstalls.Row { .init(id: id, version: version, location: location, path: path) }
        /// Its manifest's commands, each with the key Chrome gave it.
        var commands: [Command] = []

        /// One of an extension's commands as Chromium keeps it: the key is
        /// Chrome's own record of it (CommandService), set from the
        /// manifest's suggestion at install or by chrome://extensions/shortcuts.
        struct Command: Equatable {
            let name: String
            /// The manifest's words for it; Chrome's generic ones for the button's.
            let description: String
            /// Chrome's stored form, "Command+Shift+X" ("Ctrl" is ⌃); "" for none.
            let shortcut: String
            /// Works with Yab in the background in Chrome; here, only in front.
            let global: Bool
            /// Presses the extension's button (_execute_action and MV2's two).
            let action: Bool

            var hotkey: Hotkey? { shortcut.isEmpty ? nil : ChromiumExtensionCommands.hotkey(stored: shortcut) }

            init?(_ value: JSONValue) {
                guard let name = value["name"].string, !name.isEmpty, name.utf8.count <= 256 else { return nil }
                self.name = name
                description = String((value["description"].string ?? "").prefix(200))
                shortcut = value["shortcut"].string ?? ""
                global = value["global"] == .bool(true)
                action = value["action"] == .bool(true) || ChromiumExtensionCommands.actionCommands.contains(name)
            }
        }
        /// In the one list and not in this profile (yet): on its way, or
        /// waiting to be turned on and asked about.
        var absent: Bool { state == Self.arriving || state == Self.waiting }
        /// On in the list, whichever state Chrome has it in.
        var on: Bool { enabled || state == Self.arriving || state == Self.webKitOn }
        /// Listed for management, never a runnable Chromium action.
        var webKitOnly: Bool { state == Self.webKitOn || state == Self.webKitOff }
        nonisolated static let webKitOn = "WEBKIT_ENABLED", webKitOff = "WEBKIT_DISABLED"
        nonisolated static let arriving = "ARRIVING", waiting = "WAITING"

        init(_ value: JSONValue) throws {
            guard let id = value["id"].string, ChromiumExtensions.validID(id),
                  let name = value["name"].string, let state = value["state"].string else {
                throw YabCoreError.protocolViolation("Malformed Chromium extension")
            }
            self.id = id; self.name = name; self.state = state
            version = value["version"].string ?? ""
            about = value["description"].string ?? ""
            let image = value["iconData"].string ?? ""
            iconData = image.hasPrefix("data:image/png;base64," ) && image.count < 200_000
                ? Data(base64Encoded: String(image.dropFirst("data:image/png;base64,".count))) : nil
            let options = value["optionsURL"].string.flatMap(URL.init(string:))
            optionsURL = options?.scheme == "chrome-extension" && options?.host == id ? options : nil
            path = value["path"].string
            location = value["location"].string ?? ""
            if case .object = value["access"] { access = value["access"] }
            incognito = value["incognito"] == .bool(true)
            incognitoChangeable = value["incognitoChangeable"] == .bool(true)
            escalated = value["escalated"] == .bool(true)
            if case .array(let rows) = value["commands"] { commands = rows.prefix(64).compactMap(Command.init) }
            userScripts = value["userScripts"] == .bool(true)
            userScriptsChangeable = value["userScriptsChangeable"] == .bool(true)
            if case .array(let kinds) = value["views"] { views = kinds.prefix(64).compactMap(\.string) }
        }

        /// An entry of the one list this profile doesn't hold.
        init(absent entry: Installed, icon: Data?) {
            id = entry.id; name = entry.name; version = entry.version
            state = ExtensionOneList.crosses(entry)
                ? (entry.enabled ? Self.arriving : Self.waiting)
                : (entry.enabled ? Self.webKitOn : Self.webKitOff)
            optionsURL = nil; about = ""; iconData = icon
        }
    }

    let profile: String
    let privateMode: Bool
    private(set) var associationStore: WKWebsiteDataStore?
    /// What the Settings list and the column read: the one list's entries in
    /// its order, with Chrome's facts where this profile has them
    /// (ChromiumExtensionSync).
    private(set) var items: [Item] = []
    /// This profile's own list, as Chromium last said.
    private(set) var rows: [Item] = []
    var failure: String?
    var busy = false
    var importing = false
    /// The one list's join has run in this profile this launch.
    var adopting = false
    /// Which sign-in's list this profile follows, once it has joined.
    var joined: Joined?
    struct Joined { let signIn: UUID? }
    var converging = false
    var convergeAgain = false
    /// The list as the last pass matched it.
    var lastSignature: Data?
    /// What was chosen for each, as the last pass saw it.
    var lastChoices: [String: [String: Bool]]?
    var sweeping = false
    struct Queued { let id: String; let name: String; let beyond: Set<String>; let folder: URL }
    var questions: [Queued] = []
    var questioning = false
    @ObservationIgnored var following: AnyCancellable?
    @ObservationIgnored var sweeper: Task<Void, Never>?
    /// Packages that couldn't be fetched this launch, tried again next launch.
    var unfetched: Set<String> = []
    var loadFailures: [String: String] = [:]
    /// Questions up or queued, by extension.
    var asking: Set<String> = []
    /// Extensions whose grants and storage cross on the next pass.
    var crossing: Set<String> = []
    /// Store extensions tried this launch for the move to Chrome's own store
    /// install, and whether one is under way (ChromiumExtensionSync).
    var storeMoves: Set<String> = []
    var movingToStore = false
    /// "id@version" the list was ahead with when Chrome was asked to look,
    /// and Chrome was ahead with when WebKit's copy was asked to follow.
    var updateAsks: Set<String> = []
    var followed: Set<String> = []
    /// The column's pin order (ChromiumExtensionImport), cached off disk.
    /// Filled silently on first read; saveMigration bumps pinRevision, which readers read.
    @ObservationIgnored var pinCache: [String]?
    var pinRevision = 0
    /// The enabled set the other browsers' host files were last adopted for.
    var hostsAdoptedFor: Set<String> = []
    @ObservationIgnored private var tail: Task<JSONValue, Error>?

    init(profile: String, privateMode: Bool) {
        self.profile = profile; self.privateMode = privateMode
    }

    /// Nothing installed in this profile, as its files say: no folder in
    /// `Extensions`, nothing loaded unpacked (location 4) or by switch (8).
    static func noneInstalled(profile: String) -> Bool {
        let root = Store.file("Chromium").appendingPathComponent("space-" + profile)
        let packed = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Extensions").path)) ?? []
        guard packed.allSatisfy({ $0.hasPrefix(".") || $0 == "Temp" }) else { return false }
        for name in ["Secure Preferences", "Preferences"] {
            guard let data = try? Data(contentsOf: root.appendingPathComponent(name)) else { continue }
            guard let prefs = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            let settings = (prefs["extensions"] as? [String: Any])?["settings"] as? [String: Any] ?? [:]
            if settings.values.contains(where: { [4, 8].contains(($0 as? [String: Any])?["location"] as? Int) }) { return false }
        }
        return true
    }

    nonisolated static func validID(_ id: String) -> Bool {
        id.utf8.count == 32 && id.utf8.allSatisfy { (97...112).contains($0) }
    }

    func list(connectedTo core: YabCoreClient? = nil) async throws -> [Item] {
        let result = try await request("extension.list", connectedTo: core)
        guard case .array(let rows) = result else { throw YabCoreError.protocolViolation("Expected an extension list") }
        var found = try rows.map(Item.init)
        // Before native-host adoption or convergence can wake Apple's helper.
        // Disabled rows cause no write on subsequent refreshes.
        let changed = try await Self.quietAppleExtensions(found) { id in
            _ = try await self.request("extension.setEnabled", params: ["extension": .string(id), "enabled": .bool(false)], connectedTo: core)
            self.markOffInWebKitList(id)
        }
        // "Allow in private tabs", as Chromium's own per-extension switch: what
        // a private tab made as this profile's private side runs. Chrome
        // reloads an enabled extension once to apply it.
        let privateTabs = ChromiumPrivateProfiles.extensionsAllowed
        let crossing = Self.incognitoChanges(found, allowed: privateTabs)
        for id in crossing {
            _ = try await request("extension.incognito", params: ["extension": .string(id), "enabled": .bool(privateTabs)], connectedTo: core)
        }
        if changed || !crossing.isEmpty {
            let refreshed = try await request("extension.list", connectedTo: core)
            guard case .array(let rows) = refreshed else { throw YabCoreError.protocolViolation("Expected an extension list") }
            found = try rows.map(Item.init)
        }
        // developerPrivate names a folder only for unpacked ones; a store
        // install's is Chrome's own, in the profile (the hook and the
        // update's grants are read there).
        let installs = Store.file("Chromium").appendingPathComponent("space-" + profile).appendingPathComponent("Extensions")
        for index in found.indices where found[index].path == nil && found[index].location == ChromiumStoreInstalls.fromStore {
            found[index].path = ChromiumStoreInstalls.installedFolder(root: installs, id: found[index].id, version: found[index].version)?.path
        }
        let before = self.rows
        self.rows = found
        compose()
        adoptNativeHosts()
        // Chrome's updater put in a new version: its worker takes the hook
        // again on a pass (ChromiumExtensionSync.arm).
        if #available(macOS 15.4, *), joined != nil, !ChromiumStoreInstalls.moved(from: before.map(\.storeRow), to: found.map(\.storeRow)).isEmpty {
            converge(force: true)
        }
        // Installed here, from the store's page or Yab's own question: the
        // list takes it in. One that came while a pass ran takes one more
        // pass after it: that pass read Chrome's list before it came.
        if #available(macOS 15.4, *), let list = oneList, list.loaded,
           ExtensionOneList.wantsPass(native: found.map(\.id), list: list.installed,
                                      known: converging ? ((try? migration())?.joined ?? []) : nil) {
            converge(force: true)
        }
        return found
    }

    /// The extensions whose "Allow in Incognito" differs from Yab's switch
    /// and can change. Apple's quieted ones are left alone.
    nonisolated static func incognitoChanges(_ rows: [Item], allowed: Bool) -> [String] {
        rows.filter { $0.incognitoChangeable && $0.incognito != allowed && !ApplePasswordExtensionRoute.matches($0.id) }.map(\.id)
    }

    /// The switch turned: every regular profile listed this launch takes it
    /// on its next read, now.
    static func privateTabsChanged() {
        // Every window's preferences hear one change: once for them all.
        guard !privateTabsQueued else { return }
        privateTabsQueued = true
        Task { @MainActor in
            privateTabsQueued = false
            for list in profiles.values where !list.privateMode { _ = try? await list.list() }
        }
    }
    private static var privateTabsQueued = false

    /// A successful switch is reflected by the next native list read. An
    /// already-disabled extension never writes again, and a failure can retry.
    static func quietAppleExtensions(_ rows: [Item], disable: (String) async throws -> Void) async rethrows -> Bool {
        var changed = false
        for row in rows where row.enabled && ApplePasswordExtensionRoute.matches(row.id) {
            try await disable(row.id)
            changed = true
        }
        return changed
    }

    /// `items` again, from Chrome's rows and the one list.
    func compose() {
        var next = rows
        if #available(macOS 15.4, *), let list = oneList {
            next = composed(rows, list: list.installed)
        }
        guard items != next else { return }
        items = next
    }

    /// Chrome computes its own install warnings before the package is loaded.
    func permissionWarnings(folder: URL) async throws -> [String] {
        guard folder.isFileURL else { throw Crx.Refused.unpack }
        let data = try Data(contentsOf: folder.appendingPathComponent("manifest.json"))
        guard data.count <= 1_000_000, let manifest = String(data: data, encoding: .utf8) else { throw Crx.Refused.unpack }
        let result = try await request("extension.review", params: ["manifest": .string(manifest)])
        guard case .array(let rows) = result, rows.allSatisfy({ $0.string != nil }) else {
            throw YabCoreError.protocolViolation("Expected Chrome permission warnings")
        }
        return rows.compactMap(\.string)
    }

    /// The caller has already chosen the folder or approved an import.
    func load(folder: URL) async throws {
        guard folder.isFileURL else { throw YabCoreError.remote("Choose a local extension folder") }
        let id = try ChromiumExtensionPackages.unpackedID(folder)
        guard !ApplePasswordExtensionRoute.intercept(id) else { throw CancellationError() }
        _ = try await request("extension.load", params: ["path": .string(folder.path)])
    }

    func setEnabled(_ id: String, _ enabled: Bool) async throws {
        if enabled, ApplePasswordExtensionRoute.intercept(id) { return }
        // Written in the one list first: the other engine follows it, and one
        // this profile doesn't hold yet comes here (or asks) from there.
        if #available(macOS 15.4, *), let list = oneList, list.installed.contains(where: { $0.id == id }) {
            list.setEnabled(id, enabled)
            guard rows.contains(where: { $0.id == id }) else { compose(); return }
            try await applyEnabled(id, enabled)
            return
        }
        try await applyEnabled(id, enabled)
        if !enabled { markOffInWebKitList(id) }
    }

    /// "Allow user scripts" on its Settings page: written in the one list,
    /// which every profile of the sign-in and the next launch follow
    /// (convergeOnce), then Chrome's own switch in this profile.
    func setUserScripts(_ id: String, _ on: Bool) async throws {
        if #available(macOS 15.4, *), let list = oneList, list.installed.contains(where: { $0.id == id }) {
            list.setUserScripts(id, on)
        }
        guard rows.contains(where: { $0.id == id && $0.userScriptsChangeable }) else { compose(); return }
        _ = try await request("extension.userScripts", params: ["extension": .string(id), "enabled": .bool(on)])
        _ = try await list()
    }

    /// What Chrome's "Allow User Scripts" should be for a row, from the one
    /// list: nil when nothing needs writing. A choice the list hasn't made
    /// yet is Chrome's (off unless turned on there), taken in by the pass.
    nonisolated static func userScriptsChange(_ row: Item, wanted: Bool?) -> Bool? {
        guard row.userScriptsChangeable, let wanted, wanted != row.userScripts else { return nil }
        return wanted
    }

    /// Chrome's own switch, with the list untouched: what a pass does to
    /// match the list, and a reload's off and on.
    func applyEnabled(_ id: String, _ enabled: Bool, approved: Bool = false) async throws {
        var params: [String: JSONValue] = ["extension": .string(id), "enabled": .bool(enabled)]
        // Chrome turns one on whose update asked for more only with a gesture
        // (management.setEnabled); YabCore gives one for an approved request.
        if approved, enabled { params["userApproved"] = .bool(true) }
        _ = try await request("extension.setEnabled", params: params)
        // An explicit disable/re-enable is also the user's way to retry a
        // VPN after cancelling its shared proxy challenge.
        ProxyAuthentication.shared.reset(scope: "chromium:" + profile)
        _ = try await list()
    }

    /// Forward only the native Settings confirmation, never a page request.
    func remove(_ id: String, userApproved: Bool) async throws {
        _ = try await request("extension.remove", params: ["extension": .string(id), "userApproved": .bool(userApproved)])
        if #available(macOS 15.4, *), let list = oneList, list.installed.contains(where: { $0.id == id }) { list.remove(id) }
        else { markOffInWebKitList(id) }
        _ = try await list()
    }

    /// The same extension in the WebKit list of this profile's sign-in.
    private func markOffInWebKitList(_ id: String) {
        guard !privateMode, let store = associationStore ?? ChromiumSiteData.stores.first(where: {
            $0.isPersistent && ChromiumPersistentProfiles.profile(store: $0, placement: Space.firstID) == profile
        }) else { return }
        Extensions.offInChromium(id, signIn: Extensions.signIn(of: store))
    }

    /// A command's key, as chrome://extensions/shortcuts sets it: Chrome takes
    /// it from any other extension that had it; nil clears it.
    func setCommandKey(_ id: String, command: String, to hotkey: Hotkey?) async throws {
        let keybinding: String
        if let hotkey {
            guard let stored = ChromiumExtensionCommands.stored(hotkey) else { throw YabCoreError.remote("Chrome can't give a command this key") }
            keybinding = stored
        } else { keybinding = "" }
        _ = try await request("extension.command", params: ["extension": .string(id), "command": .string(command), "keybinding": .string(keybinding)])
        _ = try await list()
    }

    func registerNativeHost(manifestAt source: URL) async throws -> ChromiumNativeMessaging.Registration {
        let installed = Set(try await list().map(\.id))
        return try ChromiumNativeMessaging.register(manifestAt: source, dataRoot: Store.file("Chromium"), installed: installed)
    }

    /// Call after the install review has approved the package.
    func install(_ crx: Data, id: String) async throws -> Item {
        guard !ApplePasswordExtensionRoute.intercept(id) else { throw CancellationError() }
        guard !privateMode else { throw YabCoreError.remote("Extension management is unavailable in private profiles") }
        let root = Store.file("ChromiumPackages")
        let folder = try await Task.detached(priority: .userInitiated) {
            try ChromiumExtensionPackages.prepare(crx, id: id, root: root)
        }.value
        // Workers may connect to a desktop host as soon as Chromium loads them.
        // Place its approved host before loading, rather than racing list().
        let nativeRoot = Store.file("Chromium")
        let nativeFolders = ChromiumNativeHosts.folders()
        await Task.detached(priority: .userInitiated) {
            ChromiumNativeHosts.adopt(installed: [id], dataRoot: nativeRoot, folders: nativeFolders)
        }.value
        try await put(folder, id: id)
        guard let installed = try await list().first(where: { $0.id == id }) else {
            throw YabCoreError.remote("Chromium did not install the verified store ID")
        }
        return installed
    }

    /// A store package, after Yab's own question said yes: the CRX the store
    /// signed, through Chrome's installer, so Chrome updates it from the
    /// store from now on (ChromiumStoreInstalls). Over an unpacked copy of the
    /// same id, an update of it in place. A package Chrome can't take as the
    /// store's (a test world's own keys, a helper without 0022) is loaded
    /// unpacked, as before.
    func put(_ folder: URL, id: String) async throws {
        if let crx = ChromiumExtensionPackages.original(of: folder, id: id), await canInstallCrx() {
            do {
                try await installCrx(crx, id: id)
                return
            } catch Unaccepted.refused(let reason) {
                NSLog("Chromium extensions: %@ not taken as a store install (%@), loaded unpacked", id, reason)
            } catch YabCoreError.remote(let reason) {
                // The helper didn't start Chrome's installer at all.
                NSLog("Chromium extensions: %@ not offered as a store install (%@), loaded unpacked", id, reason)
            }
        }
        try await load(folder: folder)
    }

    enum Unaccepted: Error, LocalizedError {
        /// Chrome's installer refused the package itself.
        case refused(String)
        /// Cancelled: the profile or its management page went away.
        case cancelled(String)
        var errorDescription: String? {
            switch self { case .refused(let reason), .cancelled(let reason): return reason }
        }
    }

    /// Whether this helper has Chrome's verified CRX installer (0022).
    func canInstallCrx() async -> Bool {
        if Store.testing, ProcessInfo.processInfo.environment["YAB_CRX_INSTALL"] == "0" { return false }
        guard let core = try? await ChromiumProcess.shared.connection() else { return false }
        return ChromiumStoreInstalls.advertised(await core.nativeHooks["verifiedCrxInstall"])
    }

    /// Chrome's installer asks its own question (0021); Yab already asked, so
    /// it is answered yes once, for this id, and only for this install.
    @discardableResult
    func installCrx(_ file: URL, id: String) async throws -> String {
        guard !ApplePasswordExtensionRoute.matches(id) else { throw CancellationError() }
        ChromiumConsent.approve("install", id)
        defer { ChromiumConsent.withdrawApproval("install", id) }
        let result = try await request("extension.installCrx", params: ["path": .string(file.path), "extension": .string(id)])
        let error = result["error"].string ?? ""
        switch result["status"].string {
        case "installed"?:
            guard result["extensionId"].string == id, let version = result["version"].string, !version.isEmpty else {
                throw YabCoreError.protocolViolation("Chrome's installer named another extension")
            }
            return version
        case "cancelled"?: throw Unaccepted.cancelled(error.isEmpty ? "Cancelled" : error)
        default: throw Unaccepted.refused(error.isEmpty ? "Refused" : error)
        }
    }

    /// Chrome's updater, now rather than at its next check: every store
    /// install, installed at once when newer.
    func checkForUpdates() async throws {
        _ = try await request("extension.checkUpdates")
    }

    func installFromStore(_ id: String) async throws -> Item {
        guard !ApplePasswordExtensionRoute.intercept(id) else { throw CancellationError() }
        let data = try await ChromiumExtensionPackages.fetch(id)
        return try await install(data, id: id)
    }

    func request(_ method: String, params: [String: JSONValue] = [:], connectedTo expected: YabCoreClient? = nil) async throws -> JSONValue {
        guard !privateMode else { throw YabCoreError.remote("Extension management is unavailable in private profiles") }
        guard ["extension.list", "extension.review", "extension.load", "extension.setEnabled", "extension.access", "extension.incognito", "extension.userScripts", "extension.command", "extension.remove",
               "extension.installCrx", "extension.checkUpdates"].contains(method) else {
            throw YabCoreError.remote("Unknown extension operation")
        }
        if method == "extension.review" {
            guard let manifest = params["manifest"]?.string, manifest.utf8.count <= 1_000_000,
                  let data = manifest.data(using: .utf8),
                  (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
                throw YabCoreError.remote("A valid extension manifest is required")
            }
        }
        if method == "extension.setEnabled" || method == "extension.incognito" || method == "extension.userScripts" {
            guard let id = params["extension"]?.string, Self.validID(id), case .bool? = params["enabled"] else {
                throw YabCoreError.remote("A Chrome extension ID and enabled value are required")
            }
        }
        if method == "extension.installCrx" {
            guard let id = params["extension"]?.string, Self.validID(id),
                  let path = params["path"]?.string, path.hasPrefix("/"), path.hasSuffix(".crx") else {
                throw YabCoreError.remote("A kept store package and its extension ID are required")
            }
        }
        if method == "extension.command" {
            guard let id = params["extension"]?.string, Self.validID(id), let command = params["command"]?.string, !command.isEmpty,
                  let keybinding = params["keybinding"]?.string, keybinding.isEmpty || ChromiumExtensionCommands.hotkey(stored: keybinding) != nil else {
                throw YabCoreError.remote("A Chrome extension ID, command and key are required")
            }
        }
        if method == "extension.remove" {
            guard let id = params["extension"]?.string, Self.validID(id) else {
                throw YabCoreError.remote("A Chrome extension ID is required")
            }
            guard params["userApproved"] == .bool(true) else {
                throw YabCoreError.remote("Confirm removal in Yab first")
            }
        }
        let previous = tail
        let store = associationStore
        let task = Task { @MainActor [profile, store, privateMode] () throws -> JSONValue in
            _ = try? await previous?.value
            try Task.checkCancellation()
            guard let store else { throw ChromiumPersistentProfiles.Refused.unverifiedAssociation }
            try ChromiumPrivateProfiles.authorize(profile, store: store, privateMode: privateMode)
            let core: YabCoreClient
            if let expected {
                guard ChromiumProcess.shared.isCurrent(expected) else { throw YabCoreError.disconnected }
                core = expected
            } else { core = try await ChromiumProcess.shared.connection() }
            try await core.openProfile(profile, privateMode: privateMode)
            let created = try await core.request("extension.open", params: ["profile": .string(profile)])
            guard let tab = created["tab"].string else { throw YabCoreError.protocolViolation("Missing management tab") }
            do {
                _ = try await core.waitForDocument(tab: tab, profile: profile, url: "chrome://extensions/")
                var arguments = params; arguments["tab"] = .string(tab)
                // Chrome's installer and updater fetch, unpack and ask: longer than a read.
                let slow = method == "extension.installCrx" || method == "extension.checkUpdates"
                let result = try await core.request(method, params: arguments, timeout: slow ? 150 : 20)
                if method == "extension.remove", let extensionID = params["extension"]?.string {
                    // A native confirmation is outstanding, not a hung
                    // uninstallation. Its card times out after two minutes.
                    let deadline = Date().addingTimeInterval(result["nativeConsent"] == .bool(true) ? 130 : 15)
                    while true {
                        let status = try await core.request("extension.removalState", params: ["tab": .string(tab), "extension": .string(extensionID)])
                        if let error = status["error"].string { throw YabCoreError.remote(error) }
                        let list = try await core.request("extension.list", params: ["tab": .string(tab)])
                        guard case .array(let rows) = list else { throw YabCoreError.protocolViolation("Expected an extension list") }
                        if !rows.contains(where: { $0["id"].string == extensionID }) { break }
                        guard Date() < deadline else { throw YabCoreError.remote("Chrome did not finish removing the extension") }
                        try Task.checkCancellation()
                        try await Task.sleep(nanoseconds: 100_000_000)
                    }
                }
                try await core.closeTab(tab)
                return result
            } catch {
                try? await core.closeTab(tab)
                throw error
            }
        }
        tail = task
        return try await task.value
    }
}
