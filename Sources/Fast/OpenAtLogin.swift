import AppKit
import ServiceManagement
import SwiftUI

// Settings › General, Open at Login: Yab opens as the person logs in, its
// window put away (Headless, "at login"), so what an iPhone sends, a chat,
// a task, Open on Mac, finds it running. A login item of the app itself
// (SMAppService.mainApp), off until it is turned on here, and a Mac's own:
// it isn't a setting that syncs. The Mac says it has it on in its
// `commandcap` record (OpensAtLogin), and the iPhone says so then.
//
// Opened at login, Yab runs as a woken Yab does (docs/headless.md): no
// window, no Dock tile, nothing in front changes, sync on, and it never
// quits on its own. The Dock, Spotlight or a link shows it as usual.

@MainActor
@Observable final class OpenAtLogin {
    static let shared = OpenAtLogin()

    /// macOS opens Yab at login.
    private(set) var on = false
    /// Turned on, and waiting for the person to allow it in System
    /// Settings › General › Login Items.
    private(set) var waiting = false
    /// Why the last change didn't take, in words.
    private(set) var trouble: String?

    /// What macOS said last, so the switch is drawn as it was while macOS
    /// is asked again. This Mac's own: no synced prefix (SyncShapes).
    private static let onKey = "loginItem.on", waitingKey = "loginItem.waiting"
    @ObservationIgnored private var reading = false

    private init() {
        on = Store.settings.bool(forKey: Self.onKey)
        waiting = Store.settings.bool(forKey: Self.waitingKey)
        read()
    }

    /// What macOS says now: the person can change it in System Settings.
    /// Asked off the main thread: the status is a round trip to macOS's
    /// login items service, a third of a second of Settings' first frame
    /// when asked on it (row 1039).
    func read() {
        guard !reading else { return }
        reading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let status = SMAppService.mainApp.status
            DispatchQueue.main.async {
                self.reading = false
                self.take(status)
            }
        }
    }

    private func take(_ status: SMAppService.Status) {
        let enabled = status == .enabled, approval = status == .requiresApproval
        if on != enabled { on = enabled }
        if waiting != approval { waiting = approval }
        Store.settings.set(enabled, forKey: Self.onKey)
        Store.settings.set(approval, forKey: Self.waitingKey)
    }

    func set(_ wanted: Bool) {
        trouble = nil
        do {
            if wanted { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            trouble = wanted ? "macOS didn't add Yab to your login items." : "macOS didn't take Yab out of your login items."
        }
        // Pressed: what macOS says now, before sync tells the iPhone.
        take(SMAppService.mainApp.status)
        // An iPhone says it only for a Mac that has it on.
        SyncCenter.shared.capabilityChanged()
    }

    func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }

    // MARK: Opened at login

    /// Right after launch: true when macOS opened Yab as a login item and
    /// Open at Login is on. Its window is then put away as it comes, it
    /// keeps running, and sync starts as it always does.
    /// `YAB_LOGIN_START=1` stands in for a login in a test world.
    static func began() -> Bool {
        let standIn = Store.testing && ProcessInfo.processInfo.environment["YAB_LOGIN_START"] == "1"
        guard standIn || (launchedAsLoginItem() && SMAppService.mainApp.status == .enabled) else { return false }
        Headless.atLogin = true
        Headless.serving = true
        Headless.launch()
        return true
    }

    /// What the row under Open at Login says: only trouble, or what macOS
    /// waits for; the title says the rest.
    var detail: String {
        if let trouble { return trouble }
        if waiting { return "Allow Yab in System Settings › General › Login Items." }
        return ""
    }

    /// The Apple event the launch came with says macOS opened it at login.
    /// Read while the launch's own event is the current one, as
    /// applicationDidFinishLaunching runs.
    nonisolated static func launchedAsLoginItem() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == AEEventID(kAEOpenApplication) else { return false }
        return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }
}

/// Settings › General's row: the switch, and while macOS waits for the
/// person's yes, the way to where it is given.
struct OpenAtLoginRow: View {
    var login = OpenAtLogin.shared

    var body: some View {
        SettingsRow("Open at Login", detail: login.detail) {
            if login.waiting {
                Button("Login Items…") { login.openLoginItems() }.settingsButton()
            }
            Toggle("Open at Login", isOn: Binding(get: { login.on || login.waiting }, set: { login.set($0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        // Changed in System Settings meanwhile: read again when shown.
        .onAppear { login.read() }
    }
}
