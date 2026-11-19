import AppKit
import SwiftUI

// The bench's and the agents' words for mail beyond Gmail
// (docs/mail-providers.md, M3): mail_probe, and on a --test run an IMAP
// account on a fake server on this Mac (evals/mail/fake_imap.py).

/// Add a Mail Account's sheet filled and pressed by the bench on a --test
/// run, through the sheet's own state and buttons: what a person types and
/// presses, without a pointer. Nothing reaches it outside a test world.
@MainActor @Observable final class MailSheetDrive {
    static let shared = MailSheetDrive()

    struct Poke: Equatable {
        let id = UUID()
        var address: String?
        var password: String?
        var name: String?
        var press: String?
    }

    /// The address a sheet is opened with, from Settings › Mail.
    var open: String?
    @ObservationIgnored var provider: String?
    var poke: Poke?
    /// What the open sheet shows, as it last said (never the password).
    @ObservationIgnored var seen: [String: Any] = [:]
}

/// Which address Add a Mail Account's sheet opens on, as an item: the
/// sheet is made with it, never with the one before (a `.sheet(isPresented:)`
/// read a start set with it as it was a moment earlier, so iCloud… opened
/// on an empty address).
struct MailSheetStart: Identifiable {
    let id = UUID()
    let address: String
    var provider: String? = nil
}

/// Settings › Mail's sheet opened by the bench (MailSheetDrive.open).
struct MailSheetOpened: ViewModifier {
    @Binding var asked: MailSheetStart?

    func body(content: Content) -> some View {
        content.onChange(of: MailSheetDrive.shared.open, initial: true) { _, start in
            guard Store.testing, let start else { return }
            asked = MailSheetStart(address: start, provider: MailSheetDrive.shared.provider)
            DispatchQueue.main.async { MailSheetDrive.shared.open = nil }
        }
    }
}

extension Bench {
    static let otherMailVerbs: [String: AgentHandler] = [
        "agent-mail-probe": { $0.handleAgentMailProbe($1) },
        "agent-mail-imap": { $0.handleAgentMailIMAP($1) },
        "agent-mail-sheet": { $0.handleAgentMailSheet($1) },
        "agent-mail-setup": { bench, c in MailSetup.shared.handle(c.request, session: c.session, browser: c.browser, answer: c.answer) },
        "agent-mail-add": { $0.handleAgentMailAdd($1) },
    ]

    /// Add a Mail Account as a person does it, on a --test run
    /// (evals/mail/providers.py): Settings › Mail opened and its sheet with
    /// it (`open`, the address it starts with, as the menu's iCloud… gives
    /// "@icloud.com"), then filled and pressed (`address`, `password`,
    /// `name`, `press`: "continue", "connect", "cancel"), each through the
    /// sheet's own fields and buttons (MailSheetDrive). `standins` maps a
    /// provider's hosts to fakes on this Mac (MailStandIn); `keychain` says
    /// whether an account's password is in the keychain, never what it is.
    func handleAgentMailAdd(_ c: AgentCall) {
        let request = c.request
        let browser = c.browser
        let answer = c.answer
        guard Store.testing else { answer(["error": "agent-mail-add only works on a --test run"]); return }
        if let hosts = request["standins"] as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: hosts.compactMapValues { ($0 as? NSNumber)?.intValue }) {
            Store.settings.set(String(decoding: data, as: UTF8.self), forKey: MailStandIn.key)
        }
        let drive = MailSheetDrive.shared
        if let start = request["open"] as? String {
            browser.prefs.usesMail = true
            SettingsModel.ask(.mail)
            SettingsWindow.shared.show(for: browser)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                drive.provider = request["provider"] as? String
                drive.open = start
            }
        }
        if request["address"] != nil || request["password"] != nil || request["name"] != nil || request["press"] != nil {
            drive.poke = MailSheetDrive.Poke(address: request["address"] as? String, password: request["password"] as? String,
                                             name: request["name"] as? String, press: request["press"] as? String)
        }
        var kept: [String: Any] = [:]
        if let account = (request["keychain"] as? String)?.lowercased() {
            kept = ["keychain": MailKeychain.token(for: account) != nil, "password": MailSecret.password(for: account) != nil,
                    "fake": Store.settings.string(forKey: "mail.fake.imap." + account) != nil]
        }
        let wait = (request["wait"] as? Double) ?? 0.6
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
            let settings = SettingsWindow.shared.window
            var reply: [String: Any] = ["ok": true, "sheet": drive.seen, "open": settings?.attachedSheet != nil,
                                        "window": settings?.attachedSheet?.windowNumber ?? 0, "settings": settings?.windowNumber ?? 0,
                                        "otherAccounts": MailExperiment.otherAccounts(),
                                        "accounts": MailCenter.shared.accounts, "landed": MailCenter.shared.landed ?? ""]
            reply.merge(kept) { a, _ in a }
            answer(reply)
        }
    }

    /// Add a Mail Account's sheet, held open in a panel of its own on a
    /// --test run, for its pictures (winshot with its window): an address
    /// it starts with, as Fix… opens it; `close` puts it away.
    @MainActor static var sheetPanel: NSPanel?

    func handleAgentMailSheet(_ c: AgentCall) {
        let request = c.request
        let answer = c.answer
        guard Store.testing else { answer(["error": "agent-mail-sheet only works on a --test run"]); return }
        Bench.sheetPanel?.close()
        Bench.sheetPanel = nil
        if request["close"] as? Bool == true { answer(["ok": true]); return }
        // Providers whose pages count as signed in, for the agent's way.
        if let signed = request["signed"] as? [String] {
            MailSignedIn.fake = Set(signed)
            MailSetup.anyAgent = true
        }
        if request["run"] == nil { MailSetup.shared.cancel() }
        // The agent's way at a step: {"at": 1, "asking": "Type your Apple Account password"}.
        if let pretend = request["run"] as? [String: Any], let address = request["address"] as? String,
           let provider = MailKnownProviders.by(domain: String(address.lowercased().split(separator: "@").last ?? "")) {
            MailSetup.shared.pretend(address, provider: provider, at: (pretend["at"] as? NSNumber)?.intValue ?? 0,
                                     asking: pretend["asking"] as? String, trouble: pretend["trouble"] as? String)
        }
        let view = MailOtherAccountSheet(browser: c.browser, start: request["address"] as? String ?? "")
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 360), styleMask: [.titled, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        // A sheet's own ground, as Settings gives it.
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        panel.contentView = WindowHosting.measured(host)
        panel.orderFrontRegardless()
        // Its height once found: the fields under the address.
        DispatchQueue.main.asyncAfter(deadline: .now() + ((request["wait"] as? Double) ?? 1.5)) {
            panel.setContentSize(host.fittingSize)
            answer(["ok": true, "window": panel.windowNumber, "height": host.fittingSize.height])
        }
        Bench.sheetPanel = panel
    }

    /// mail_probe: an address's servers tried step by step with what the
    /// keychain holds for it. Never a password in or out.
    func handleAgentMailProbe(_ c: AgentCall) {
        let request = c.request
        let answer = c.answer
        guard MailExperiment.otherAccounts() else {
            answer(["error": "Mail is off: Settings › Experimental › Mail turns it on"]); return
        }
        let address = (request["address"] as? String ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        guard address.contains("@") else { answer(["error": "give the mail address to probe"]); return }
        let step = ["find", "imap", "smtp", "all"].contains(request["step"] as? String ?? "") ? request["step"] as! String : "all"
        Task {
            let kept = MailServerSetup.kept(address, in: Store.settings)
            let result = await MailProbe.run(address, step: step, setup: kept, password: MailSecret.password(for: address))
            let json = result.json
            let data = (try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])) ?? Data()
            answer(["text": String(decoding: data, as: UTF8.self), "probe": json, "ok": result.ok])
        }
    }

    /// A test world's IMAP account on a fake server: its ports, its fake
    /// password kept in the world's settings, never the keychain; with
    /// `remove`, disconnected as Settings › Mail does.
    func handleAgentMailIMAP(_ c: AgentCall) {
        let request = c.request
        let browser = c.browser
        let answer = c.answer
        guard Store.testing else { answer(["error": "agent-mail-imap only works on a --test run"]); return }
        let account = (request["account"] as? String ?? "me@example.com").lowercased()
        if request["remove"] as? Bool == true {
            MailCenter.shared.disconnect(account)
            Store.settings.removeObject(forKey: "mail.fake.imap." + account)
            answer(["ok": true, "accounts": MailCenter.shared.accounts])
            return
        }
        guard let imap = (request["imap_port"] as? NSNumber)?.intValue, let smtp = (request["smtp_port"] as? NSNumber)?.intValue else {
            answer(["error": "give imap_port and smtp_port"]); return
        }
        Store.settings.set("1", forKey: "mail.fake.imap." + account)
        browser.prefs.usesMail = true
        let setup = MailServerSetup(address: account, name: request["name"] as? String ?? "", imapHost: "127.0.0.1", imapPort: imap,
                                    imapSecurity: .none, smtpHost: "127.0.0.1", smtpPort: smtp, smtpSecurity: .none,
                                    provider: request["provider"] as? String ?? "", foundBy: "test",
                                    savesSent: request["saves_sent"] as? Bool == true)
        MailCenter.shared.addIMAP(setup, password: request["password"] as? String ?? "app-password")
        MailCenter.shared.pinOnce(in: browser)
        answer(["ok": true, "account": account, "kind": MailCenter.kind(of: account).rawValue, "at": Date().timeIntervalSince1970])
    }
}
