import AppKit
import Combine
import os
import SwiftUI

/// Password managers connected to Yab (docs/password-managers.md). Two sources, each on its
/// own: Yab's passwords on a switch (`passwords.yab`), and the managers you
/// connect (`passwords.managers`). Both kept on this Mac only: extensions
/// differ from Mac to Mac, and an unlock password stays on the Mac it was
/// typed on (ManagerUnlock).
enum PasswordManagers {
    static let onePassword = "aeblfdkhhhdcdjpifhhbdiojplfjncoa"
    static let onePasswordBeta = "khgocmkkpikpnmmkgmdnfckapcdkgfaf"
    static let bitwarden = "nngceckbapebfimnlniiiahkandclblb"
    static let nordPass = "eiaeiblijfjekdanodkjadfinkhbfgcd"
    static let protonPass = "ghmbeldphafepmbegfdlkpapadhbakde"
    static let dashlane = "fdjamakpfbbddfjaooikfcpapjohcfmg"
    static let lastPass = "hdokiejnpimakedhajhdlcegeplioahd"
    static let apple = "pejdijmoenmkgeppbflobdenhhabjlaj"

    struct Provider: Identifiable, Equatable {
        /// Its extension's Chrome Web Store id.
        let id: String
        let name: String
        /// Its Mac app: bundle ids, and names for an app found by its folder.
        let bundles: [String]
        let apps: [String]
        /// The extension's own page that unlocks it.
        let unlockPage: String?
        /// Its app has to let Yab in (1Password's Settings › Browser).
        var allows = false
        /// Tags its content script puts its menu and field words in, on the
        /// page itself rather than in a frame of its own (NordPass's
        /// `nordpass-autofill-portal`): what sign_in reads there.
        var pageTags: [String] = []
    }

    /// In the order the sheet lists them. Keeper stays an extension only
    /// until its unlock page has been seen.
    static let providers: [Provider] = [
        Provider(id: onePassword, name: "1Password", bundles: ["com.1password.1password"], apps: ["1Password.app"],
                 unlockPage: "popup/index.html", allows: true),
        Provider(id: bitwarden, name: "Bitwarden", bundles: ["com.bitwarden.desktop"], apps: ["Bitwarden.app"],
                 unlockPage: "popup/index.html"),
        Provider(id: protonPass, name: "Proton Pass", bundles: ["me.proton.pass.electron"], apps: ["Proton Pass.app"],
                 unlockPage: "popup.html"),
        Provider(id: dashlane, name: "Dashlane", bundles: [], apps: ["Dashlane.app"], unlockPage: "index.html"),
        // Its own tab for signing in, which its worker opens; it has no popup.html.
        Provider(id: lastPass, name: "LastPass", bundles: ["com.lastpass.LastPass"], apps: ["LastPass.app"],
                 unlockPage: "login.html"),
        Provider(id: nordPass, name: "NordPass", bundles: ["com.nordsec.nordpass"],
                 apps: ["NordPass.app", "NordPass® Password Manager & Digital Vault.app"], unlockPage: "app.html",
                 pageTags: ["nordpass-"]),
        // Read by Yab through Keeper Commander, or filled by Enpass's own
        // extension (ManagerVault.swift).
        Provider(id: ManagerVault.keeper, name: "Keeper", bundles: ["com.keepersecurity.passwordmanager"],
                 apps: ["Keeper Password Manager.app"], unlockPage: nil),
        Provider(id: ManagerVault.enpass, name: "Enpass", bundles: ["in.sinew.Enpass-Desktop"], apps: ["Enpass.app"], unlockPage: nil),
        Provider(id: apple, name: "Apple Passwords", bundles: ["com.apple.Passwords"], apps: ["Passwords.app"], unlockPage: nil),
    ]

    /// A test run's stand-in extensions, by their local id, as a manager.
    static let testAliases = OSAllocatedUnfairLock<[String: String]>(initialState: [:])

    static func provider(_ id: String) -> Provider? {
        providers.first { $0.id == canonical(id) }
    }

    /// One manager under one id: 1Password's beta is 1Password, iCloud
    /// Passwords' second origin is Apple Passwords.
    static func canonical(_ id: String) -> String {
        if Store.testing, let alias = testAliases.withLock({ $0[id] }) { return alias }
        if id == onePasswordBeta { return onePassword }
        if Extensions.iCloudPasswords.contains(id) { return apple }
        return id
    }

    static func name(_ id: String) -> String {
        provider(id)?.name ?? "Password manager"
    }

    /// Its name as unlock_manager takes it: "bitwarden", "proton-pass".
    static func slug(_ id: String) -> String {
        name(id).lowercased().replacingOccurrences(of: " ", with: "-")
    }

    /// The manager's own way to stay open or unlock quickly, offered first
    /// on its Connect card (docs/evidence/manager-unlock-policy-2026-10-13.md);
    /// "I'll unlock it" for one without.
    static func ownUnlock(_ id: String) -> (title: String, detail: String) {
        let after = "Agents stop and ask you when it's locked."
        switch canonical(id) {
        case onePassword:
            return ("Unlock with the 1Password app", "Touch ID in the 1Password app unlocks its extension in Yab too. " + after)
        case bitwarden:
            return ("Bitwarden's PIN or Touch ID", "Turn on in Bitwarden's settings, under unlock options. " + after)
        case protonPass:
            return ("Proton Pass PIN", "Turn on in Proton Pass's settings, under security. " + after)
        case nordPass:
            return ("NordPass stays unlocked", "Set NordPass's autolock to a longer time, or keep its extension unlocked. " + after)
        default:
            return ("I'll unlock it", "You unlock \(name(id)) yourself. " + after)
        }
    }

    /// Whether Yab offers to keep its unlock password and type it into the
    /// manager's own unlock page: only where that page was seen and typed
    /// into end to end, Bitwarden (its synthetic vault, password_unlock.py)
    /// and NordPass (signed in by hand). Not 1Password, whose app holds its
    /// lock (Touch ID), nor Apple Passwords; not Proton Pass, Dashlane or
    /// LastPass, whose unlock pages were never tried signed in
    /// (docs/password-manager-fields.md).
    static func yabMayUnlock(_ id: String) -> Bool {
        [bitwarden, nordPass].contains(canonical(id))
    }

    /// Apple Passwords can be connected only once Apple lets Yab's helper run.
    @MainActor static func selectable(_ id: String) -> Bool {
        canonical(id) != apple || ApplePasswords.mayRun
    }

    /// The icon its extension ships: the installed one's, or the copy Yab
    /// carries for one not in Yab yet. Never drawn by Yab.
    @MainActor static func icon(_ id: String) -> NSImage? {
        if let installed = installed(id), let image = ManagerExtensions.shared.icon(installed.id, side: 28) {
            return image
        }
        let id = canonical(id)
        if let kept = carried[id] { return kept }
        let image = Bundle.main.url(forResource: id, withExtension: "png", subdirectory: "PasswordManagerIcons")
            .flatMap(NSImage.init(contentsOf:))
        carried[id] = image
        return image
    }

    /// The icons Yab carries, read from disk once: a card's rows asked for
    /// all seven in the frame it came up in.
    @MainActor private static var carried: [String: NSImage?] = [:]

    // MARK: - on this Mac

    /// Lit by lookAround, off the main thread.
    static let appFound = "App on this Mac"

    /// What Connect still has to set up: its extension, and 1Password's yes
    /// in its app. 1Password's app is optional, its extension works alone.
    @MainActor static func leftToSetUp(_ id: String) -> Bool {
        guard let item = installed(id) else { return true }
        guard provider(id)?.allows == true, Connections.shared.here[canonical(id)] == appFound else { return false }
        return !Extensions.here.onePasswordAnswered.contains(item.id)
    }

    /// One unlock choice and nothing to set up: Connect has nothing to ask.
    @MainActor static func connectsAtOnce(_ id: String) -> Bool {
        !yabMayUnlock(id) && !leftToSetUp(id) && Connections.shared.connection(id) == nil
    }

    /// Where the sheet found it: its extension in Yab, its app, or its
    /// extension in another browser's profile. Nil when it isn't here.
    /// Only reads: the app and the other browsers were looked for off the
    /// main thread (Connections.lookAround); walking other browsers'
    /// folders here, in a body, took 1.8 s to open the sheet on a Mac with
    /// five of them.
    @MainActor static func found(_ id: String) -> String? {
        guard let provider = provider(id), provider.id != apple else { return nil }
        if installed(provider.id) != nil { return "Extension in Yab" }
        return Connections.shared.here[provider.id]
    }

    /// Each manager's app on this Mac, else its extension in another
    /// browser, in found()'s words. LaunchServices and other browsers'
    /// folders: never on the main thread.
    nonisolated static func lookAround(in sources: [Chromium.Source]) -> [String: String] {
        var out: [String: String] = [:]
        var rest: [String] = []
        for provider in providers where provider.id != apple {
            if appHere(provider) { out[provider.id] = appFound } else { rest.append(provider.id) }
        }
        for (id, browser) in inBrowsers(rest, in: sources) { out[id] = "In \(browser)" }
        return out
    }

    /// The first of these browsers holding each extension in a profile:
    /// the discovered profile directories (without reading Local State) and the
    /// folder itself, each asked for Extensions/<id> only. No walk of the
    /// browser's folders and no sorting by use, which cost thousands of
    /// file checks a call.
    nonisolated static func inBrowsers(_ ids: [String], in sources: [Chromium.Source]) -> [String: String] {
        var out: [String: String] = [:]
        let files = FileManager.default
        for source in sources {
            let left = ids.filter { out[$0] == nil }
            guard !left.isEmpty else { break }
            guard files.fileExists(atPath: source.root.path) else { continue }
            let listed = TabImport.profileOrder(in: source)
            let folders = [source.root] + (listed.isEmpty ? ["Default"] : listed).map { source.root.appendingPathComponent($0) }
            for id in left where folders.contains(where: { files.fileExists(atPath: $0.appendingPathComponent("Extensions/\(id)").path) }) {
                out[id] = source.name
            }
        }
        return out
    }

    nonisolated static func appHere(_ provider: Provider) -> Bool {
        if provider.bundles.contains(where: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }) { return true }
        let places = ["/Applications", NSHomeDirectory() + "/Applications", "/System/Applications"]
        return places.contains { place in provider.apps.contains { FileManager.default.fileExists(atPath: place + "/" + $0) } }
    }

    /// The Chromium browsers to look in: the apps on this Mac (a probe's
    /// stand-ins in a test world), the default browser first.
    nonisolated static var browsersHere: [Chromium.Source] {
        let standing = Store.testing ? Chromium.standIns.withLock({ $0 }) : []
        if !standing.isEmpty { return standing }
        let links = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)
            .flatMap { Bundle(url: $0)?.bundleIdentifier }
        let here = Chromium.known.filter { $0.app != nil }
        return here.filter { $0.bundle == links } + here.filter { $0.bundle != links }
    }

    // MARK: - a connected manager's row

    enum Mode: String, Codable { case yab, you }

    struct Connection: Codable, Equatable {
        var provider: String
        var since: Date
        /// Who unlocks it when an agent finds it locked.
        var mode: Mode = .you
    }

    /// A row's state (the design's table 5): fine, or the one thing to do.
    enum Row: Equatable {
        case yabUnlocks, youUnlock, noExtension, off, notAllowed, wrongPassword, passwordMissing

        var words: String {
            switch self {
            case .yabUnlocks: return "Connected · Yab unlocks it"
            case .youUnlock: return "Connected · You unlock it"
            case .noExtension: return "Its extension isn't in Yab"
            case .off: return "Its extension is off"
            case .notAllowed: return "1Password hasn't allowed Yab yet. In 1Password: Settings › Browser › Add Browser."
            case .wrongPassword: return "The saved unlock password didn't work"
            case .passwordMissing: return "Its unlock password is missing on this Mac"
            }
        }

        /// The row's one button, nil when nothing needs doing.
        var action: String? {
            switch self {
            case .yabUnlocks, .youUnlock: return nil
            case .noExtension: return "Add Extension"
            case .off: return "Turn On"
            case .notAllowed: return "Open 1Password"
            case .wrongPassword: return "Change…"
            case .passwordMissing: return "Save Again…"
            }
        }

        var trouble: Bool { action != nil }
    }

    static func row(installed: Bool, enabled: Bool, refused: Bool, mode: Mode,
                    hasPassword: Bool, lastFailed: Bool) -> Row {
        if !installed { return .noExtension }
        if !enabled { return .off }
        if refused { return .notAllowed }
        guard mode == .yab else { return .youUnlock }
        if !hasPassword { return .passwordMissing }
        if lastFailed { return .wrongPassword }
        return .yabUnlocks
    }

    /// Whose menus an agent tries after Yab's own login: connected managers
    /// whose extension is in Yab and on, in the order connected.
    static func agentOrder(_ connections: [Connection], on: Set<String>) -> [String] {
        connections.map(\.provider).filter { on.contains($0) && $0 != apple }
    }

    /// The managers whose extension is in Yab and on.
    @MainActor static var extensionsOn: Set<String> {
        Set(ManagerExtensions.shared.installed.filter(\.enabled).map { canonical($0.id) })
    }

    /// Password managers by their store ids beyond the ones Connect lists:
    /// RoboForm and KeePassXC-Browser (docs/password-manager-fields.md).
    static let roboForm = "pnlccmojcmeohlpggmfnbbiapkmbliob"
    static let keePassXC = "oboonakemofpalcgghocfoadofidjkkk"
    static let strongbox = "mnilpkfepdibngheginihjpknnopchbn"
    static let knownElsewhere: Set<String> = [roboForm, keePassXC, strongbox]

    /// Whether an extension is a password manager: one Yab knows by its
    /// id, or one that asked Chrome's way to do the saving itself
    /// (chrome.privacy passwordSavingEnabled false).
    @MainActor static func isManager(_ item: Installed) -> Bool {
        let id = canonical(item.id)
        if providers.contains(where: { $0.id == id }) || knownElsewhere.contains(id) { return true }
        return Extensions.settings(for: item.id)["privacy.services.passwordSavingEnabled"] as? Bool == false
    }

    /// The password manager extension that has the page's sign-in boxes:
    /// the first one on in Yab, connected or not. While one is, its icon
    /// and menu are the only thing on a sign-in box, and it saves: Yab
    /// draws no list, plate or strong password there and asks to save
    /// nothing (docs/password-manager-fields.md). Nil: Yab's own.
    @MainActor static var fieldOwner: Installed? {
        // Apple Passwords connected is Yab's own list (ApplePasswords.swift):
        // the iCloud Passwords extension, on beside it, doesn't take the box.
        let native = appleNative
        return ManagerExtensions.shared.installed.first { $0.enabled && isManager($0) && !(native && canonical($0.id) == apple) }
    }

    /// The manager extension that has this tab's sign-in boxes: fieldOwner,
    /// where extensions run. On a private tab they don't unless Settings ›
    /// Extensions › Allow in private tabs lets them (Web.configuration), so
    /// there none has the box and Yab's own list is the one, as Chromium's own
    /// passwords fill in Incognito. Stepping aside there for an extension
    /// that wasn't on the page left nothing at all to fill (#1303).
    @MainActor static func fieldOwner(on tab: Tab) -> Installed? {
        extensionsRun(on: tab) ? fieldOwner : nil
    }

    /// Whether extensions reach this tab's pages.
    @MainActor static func extensionsRun(on tab: Tab) -> Bool {
        !tab.shy || Store.settings.bool(forKey: "extensions.private")
    }

    /// Apple Passwords connected, in a Yab that may run its helper: Yab
    /// lists, fills and keeps its logins itself, no extension needed.
    @MainActor static var appleNative: Bool {
        ApplePasswords.mayRun && Connections.shared.connection(apple) != nil
    }

    /// Apple Passwords connected: the iCloud Passwords extension turned off,
    /// so its menu doesn't come up under Yab's list on every sign-in box.
    @MainActor static func quietAppleExtension() {
        for item in ManagerExtensions.shared.installed where item.enabled && Extensions.iCloudPasswords.contains(item.id) {
            ManagerExtensions.shared.setEnabled(item.id, false)
        }
    }

    /// The extension that took a card's or an address's boxes the way
    /// Chrome hears it (chrome.privacy autofillCreditCardEnabled or
    /// autofillAddressEnabled set false): Yab's cards or addresses stay
    /// out of those boxes then.
    @MainActor static func walletOwner(cards: Bool) -> Installed? {
        let key = cards ? "privacy.services.autofillCreditCardEnabled" : "privacy.services.autofillAddressEnabled"
        return ManagerExtensions.shared.installed.first { $0.enabled && Extensions.settings(for: $0.id)[key] as? Bool == false }
    }

    /// The installed extension of a manager, by any of its ids.
    @MainActor static func installed(_ id: String) -> Installed? {
        ManagerExtensions.shared.installed.first { canonical($0.id) == canonical(id) }
    }

    /// While a manager's extension is on, connected or not, it saves new
    /// sign-ins and Yab doesn't ask: a connected one first, by its id.
    @MainActor static var savingManager: String? {
        let on = extensionsOn
        let native = appleNative
        return Connections.shared.list.map(\.provider).first { $0 == apple ? native : on.contains($0) }
            ?? fieldOwner.map { canonical($0.id) }
    }

    /// Who fills and saves: Yab, while its switch is on, offers what it
    /// keeps where it keeps something; a connected manager whose extension
    /// is on saves new sign-ins, and Yab doesn't ask then.
    struct Source: Equatable {
        var yab: Bool
        var saver: String?
        /// Apple Passwords connected and read by Yab itself (appleNative):
        /// the saver, but the question is Yab's own card, not an extension's.
        var asksForApple = false
        /// Yab offers to save a sign-in.
        var yabSaves: Bool { yab && saver == nil }
        /// Yab puts a recent login in by itself, with no manager beside it.
        var yabFillsAlone: Bool { yab && saver == nil }

        /// Settings › Passwords › Offer to save passwords, as Chromium draws
        /// its own (credentials_enable_service): the person's switch while
        /// Yab is the one asking, into its keychain or into Apple Passwords,
        /// and held, off, only while a manager's extension asks on its own,
        /// as Chromium holds a pref an extension controls. Apple Passwords
        /// connected used to hold it off too, though Yab's card still asked
        /// (register 2497).
        func offerSwitch(saves: Bool) -> (on: Bool, enabled: Bool) {
            let ours = saver == nil || asksForApple
            return (ours && saves, ours)
        }
    }

    /// Opens the manager: its app, else its extension's own page in a tab.
    @MainActor static func open(_ id: String, in browser: Browser?) {
        if let provider = provider(id), let app = provider.bundles.lazy.compactMap({
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
        }).first {
            NSWorkspace.shared.openApplication(at: app, configuration: .init(), completionHandler: nil)
            return
        }
        openPage(id, in: browser)
    }

    /// Its extension's own page in a tab, in front of Settings: where a
    /// person signs in to it or unlocks it. A manager signed out shows its
    /// sign-in or its introduction there. False when there is no such page.
    @MainActor @discardableResult static func openPage(_ id: String, in browser: Browser?) -> Bool {
        guard let browser, let item = installed(id), let page = provider(id)?.unlockPage,
              let base = ManagerExtensions.shared.base(item.id) else { return false }
        browser.open(base.appendingPathComponent(page), foreground: true)
        // Settings stays open, behind the page.
        BrowserWindows.shared.window(for: browser)?.makeKeyAndOrderFront(nil)
        return true
    }
}

// MARK: - the connections

extension PasswordManagers {
    @MainActor @Observable final class Connections {
        static let shared: Connections = {
            let connections = Connections()
            // Not in init: Extensions.shared may be what is building this.
            DispatchQueue.main.async { connections.watch() }
            return connections
        }()
        static let key = "passwords.managers"
        static let lastKey = "passwords.lastUnlock"

        private(set) var list: [Connection]
        /// Managers whose last unlock by Yab left the password box there.
        private(set) var failed: Set<String>
        /// Managers whose unlock password Yab can find now.
        private(set) var kept: Set<String> = []
        /// The row that just changed, lit for a moment.
        var flash: String?
        /// The card over Settings: an unlock password, or Disconnect's
        /// question. Connect is a page under Passwords, the managers not
        /// on this Mac another (PasswordManagersPlace).
        enum Card: Hashable {
            case password(String), disconnect(String)
        }
        var card: Card? {
            didSet {
                guard card != oldValue else { return }
                askedAt = card == nil ? nil : Date()
                shownMs = nil
            }
        }
        /// When the card was asked for, and how long after that it first
        /// appeared, for the bench (password_connect_timing.py).
        @ObservationIgnored private var askedAt: Date?
        @ObservationIgnored private(set) var shownMs: Int?
        func cardShown() {
            if shownMs == nil, let askedAt { shownMs = Int(Date().timeIntervalSince(askedAt) * 1000) }
        }
        /// The manager a card opens on, set before `connecting`: the corner
        /// card's Connect, the bench.
        @ObservationIgnored var opensOn: String?
        /// Kept for the bench; Connect's card shows what is left to set up.
        @ObservationIgnored var opensSetUp = false
        /// A Connect page is open: one manager's, or the list of the others.
        var connecting: Bool {
            get { PasswordManagersPlace.connecting(SettingsWindow.shared.model?.opened) }
            set {
                if newValue { openConnect(opensOn) } else { leaveConnect() }
                opensOn = nil
            }
        }

        /// One manager's Connect page, or the list of the others for nil.
        func openConnect(_ id: String?) {
            card = nil
            if let id, PasswordManagers.connectsAtOnce(id) {
                connectAndSignIn(id, mode: .you)
                return
            }
            SettingsWindow.shared.model?.open(.passwords, item: id.map(PasswordManagersPlace.connect) ?? PasswordManagersPlace.connect)
        }

        /// Back on Passwords, the Connect pages gone from back and forward.
        func leaveConnect() {
            guard let model = SettingsWindow.shared.model, PasswordManagersPlace.connecting(model.opened) else { return }
            if let opened = model.opened, opened != PasswordManagersPlace.connect { model.leave(opened, to: .passwords) }
            model.leave(PasswordManagersPlace.connect, to: .passwords)
        }
        /// Managers on this Mac outside Yab, by id: "App on this Mac" or
        /// "In Arc" (lookAround). Read by found(), filled off the main thread.
        private(set) var here: [String: String] = [:]
        @ObservationIgnored private var looking = false
        @ObservationIgnored private var lookAgain = false
        @ObservationIgnored private var watching: [AnyCancellable] = []

        init() {
            let data = Store.settings.data(forKey: Self.key)
            list = (data.flatMap { try? JSONDecoder().decode([Connection].self, from: $0) } ?? [])
                .filter { PasswordManagers.provider($0.provider) != nil }
            let last = Store.settings.dictionary(forKey: Self.lastKey) as? [String: Bool] ?? [:]
            failed = Set(last.filter { !$0.value }.keys)
            look()
        }

        func connection(_ id: String) -> Connection? { list.first { $0.provider == canonical(id) } }

        /// Looks again when an extension comes or goes and when Yab comes
        /// back to the front (an app installed meanwhile), besides
        /// Settings › Passwords opening.
        private func watch() {
            lookAround()
            watching = [
                Extensions.listsChanged.map { Extensions.here.installed.map(\.id) }.removeDuplicates().dropFirst()
                    .sink { [weak self] _ in self?.lookAround() },
                NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
                    .sink { [weak self] _ in self?.lookAround() },
            ]
        }

        /// What is on this Mac outside Yab, looked for off the main thread;
        /// a call while one runs looks once more after it.
        func lookAround() {
            if looking { lookAgain = true; return }
            looking = true
            Task.detached(priority: .userInitiated) { [weak self] in
                let found = PasswordManagers.lookAround(in: PasswordManagers.browsersHere)
                await self?.landed(found)
            }
        }

        private func landed(_ found: [String: String]) {
            if found != here { here = found }
            looking = false
            if lookAgain { lookAgain = false; lookAround() }
        }

        /// Which unlock passwords are there, read without their values.
        func look() {
            let now = Set(list.filter { $0.mode == .yab && ManagerUnlock.has($0.provider) }.map(\.provider))
            if now != kept { kept = now }
        }

        /// Connected, or its mode changed. False when the unlock password
        /// couldn't be saved and read back; nothing changes then.
        @discardableResult
        func connect(_ id: String, mode: Mode, password: String? = nil, pair: Bool = true) -> Bool {
            let id = canonical(id)
            if mode == .yab, let password {
                guard ManagerUnlock.save(id, password) else { return false }
                clearLast(id)
            }
            if mode == .you { ManagerUnlock.forget(id); clearLast(id) }
            if let index = list.firstIndex(where: { $0.provider == id }) {
                list[index].mode = mode
            } else {
                list.append(Connection(provider: id, since: Date(), mode: mode))
            }
            save()
            look()
            lit(id)
            // Apple Passwords pairs with its helper: the code at once.
            if id == apple, pair, ApplePasswords.mayRun { Task { await ApplePasswordsPairing.pair() } }
            return true
        }

        /// Connected from Settings: back on Passwords, and a manager new to
        /// Yab opens its own page, since it has to be signed in to.
        @discardableResult
        func connectAndSignIn(_ id: String, mode: Mode, password: String? = nil) -> Bool {
            let first = connection(id) == nil
            guard connect(id, mode: mode, password: password) else { return false }
            leaveConnect()
            if first { PasswordManagers.openPage(id, in: BrowserWindows.shared.activeBrowser) }
            return true
        }

        func forgetPassword(_ id: String) {
            ManagerUnlock.forget(id)
            if let index = list.firstIndex(where: { $0.provider == id }) { list[index].mode = .you }
            clearLast(id)
            save()
            look()
        }

        func disconnect(_ id: String) {
            ManagerUnlock.forget(id)
            list.removeAll { $0.provider == id }
            clearLast(id)
            save()
            look()
        }

        /// How Yab's last unlock went: a box still there marks the row.
        func unlocked(_ id: String, ok: Bool) {
            var last = Store.settings.dictionary(forKey: Self.lastKey) as? [String: Bool] ?? [:]
            last[id] = ok
            Store.settings.set(last, forKey: Self.lastKey)
            if ok { failed.remove(id) } else { failed.insert(id) }
        }

        private func clearLast(_ id: String) {
            var last = Store.settings.dictionary(forKey: Self.lastKey) as? [String: Bool] ?? [:]
            last[id] = nil
            Store.settings.set(last, forKey: Self.lastKey)
            failed.remove(id)
        }

        func lit(_ id: String) {
            flash = id
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                if self?.flash == id { self?.flash = nil }
            }
        }

        /// A row's state from what Extensions knows now.
        func row(_ id: String) -> Row {
            // Apple Passwords goes through its helper, not an extension, and
            // its Touch ID is the person's own.
            if PasswordManagers.canonical(id) == PasswordManagers.apple, ApplePasswords.mayRun { return .youUnlock }
            let item = PasswordManagers.installed(id)
            let refused = item.map { Extensions.here.unconnected.contains($0.id) } ?? false
            return PasswordManagers.row(installed: item != nil, enabled: item?.enabled == true, refused: refused,
                                        mode: mode(id), hasPassword: kept.contains(id),
                                        lastFailed: failed.contains(id))
        }

        /// Who unlocks it: "Yab unlocks it" kept from before counts only for
        /// a manager Yab still may unlock (yabMayUnlock).
        func mode(_ id: String) -> Mode {
            connection(id)?.mode == .yab && PasswordManagers.yabMayUnlock(id) ? .yab : .you
        }

        /// For the agents' guide: "Bitwarden (Yab unlocks), 1Password (you unlock)".
        var described: String {
            list.map { "\(PasswordManagers.name($0.provider)) (\(mode($0.provider) == .yab ? "Yab unlocks" : "you unlock"))" }
                .joined(separator: ", ")
        }

        private func save() {
            if let data = try? JSONEncoder().encode(list) { Store.settings.set(data, forKey: Self.key) }
        }
    }
}
