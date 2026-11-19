import AppKit
import SwiftUI

/// Settings › Mail › Add Account › Other Account… (docs/mail-providers.md,
/// M3), in the way in's own look (MailArrival): Mail's mark wearing where
/// the mail comes from, one address, then what it takes in one surface. The
/// servers are found without anyone (MailFinding: known providers,
/// autoconfig, MX, a guess); the password goes from Yab's own secure field
/// into the keychain, never through a model; Connect tries both servers with
/// it (MailProbe) before the account is kept. Where the provider's
/// app-password page is signed in in Yab, Set It Up hands it all to an agent (MailSetup).
struct MailOtherAccountSheet: View {
    var browser: Browser
    /// The address it starts with: an account's own, for Fix; "@icloud.com"
    /// from the Add Account menu, the caret before the @.
    var start = ""
    /// Explicit Google selection also covers Workspace addresses.
    var provider: String? = nil
    @Environment(\.dismiss) private var dismiss
    private var agent = MailSetup.shared
    @MailStill private var still
    @State private var address = ""
    @State private var name = NSFullUserName()
    @State private var password = ""
    @State private var found: MailFinding.Found?
    @State private var setup: MailServerSetup?
    @State private var known: MailKnownProvider?
    @State private var busy = false
    @State private var trouble: String?
    /// What the refusal was (MailServerTrouble's words), for where it shows.
    @State private var hint = ""
    @State private var servers = false
    @State private var opened = false
    @State private var signedIn = false
    /// Paste an app password myself: the steps by hand, though the agent could.
    @State private var byHand = false
    @State private var ticked = false
    @FocusState private var focus: Focus?

    enum Focus { case address, password }

    static let face: CGFloat = 340

    var body: some View {
        VStack(spacing: 0) {
            MailMark(badge: ticked ? nil : badge, working: working, ticked: ticked)
            Text(title)
                .font(.system(size: 17, weight: .medium))
                .padding(.top, 16)
                .id(title)
                .transition(.opacity)
            if let lead {
                Text(lead)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: Self.face)
                    .padding(.top, 6)
                    .id(lead)
                    .transition(.opacity)
            }
            TextField(gmail ? "you@gmail.com" : "you@icloud.com", text: $address)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .labelsHidden()
                .autocorrectionDisabled()
                .focused($focus, equals: .address)
                .frame(width: Self.face)
                .padding(.top, 16)
                .disabled(working)
                .onSubmit { Task { await go() } }
                .onChange(of: address) { _, _ in
                    if provider == "gmail" {
                        chooseGoogle()
                    } else if (setup != nil || found != nil), setup?.address != address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                        clear()
                    }
                }
            middle
            if let said {
                Text(said)
                    .font(.callout)
                    .foregroundStyle(ButtonCSS.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: Self.face)
                    .padding(.top, 12)
                    .transition(.opacity)
            }
            if let setup, case .imap = found, run == nil {
                sends
                if !servers, !agentWay {
                    Button { withAnimation(still ? nil : Motion.settle) { servers = true } } label: {
                        Text("\(setup.imapHost) \u{00B7} \(setup.smtpHost)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .keyTip("Servers")
                    .padding(.top, 6)
                }
                if agentWay {
                    Button("Paste an App Password Myself") {
                        withAnimation(still ? nil : Motion.settle) { byHand = true }
                        focus = .password
                    }
                    .buttonStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 6)
                }
            }
            if let foot {
                Text(foot)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: Self.face)
                    .padding(.top, 12)
            }
            buttons.padding(.top, 20)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 20)
        .frame(width: 440)
        .animation(still ? nil : Motion.settle, value: shape)
        .onAppear {
            address = start
            if provider == "gmail" { chooseGoogle() }
            if start.hasPrefix("@") {
                focus = .address
                // The name before the @ is what's left to type.
                DispatchQueue.main.async { NSApp.sendAction(#selector(NSResponder.moveToBeginningOfLine(_:)), to: nil, from: nil) }
            } else if !start.isEmpty {
                if provider == "gmail" { focus = .password } else { Task { await find() } }
            } else {
                focus = .address
            }
        }
        .onChange(of: run?.done) { _, done in
            guard done == true else { return }
            land()
        }
        .onDisappear {
            agent.clear()
            if Store.testing { MailSheetDrive.shared.seen = [:] }
        }
        // A test world's bench fills and presses it as a person would (MailSheetDrive).
        .onChange(of: MailSheetDrive.shared.poke, initial: true) { _, poke in
            guard Store.testing, let poke else { return }
            take(poke)
        }
        .onChange(of: told) { _, _ in tell() }
        .onAppear { tell() }
    }

    // MARK: - a test world's bench

    /// What it shows, for the bench: changes of it are told.
    private var told: String { "\(shape)|\(busy)|\(ticked)|\(action)|\(ready)|\(address)|\(hint)|\(password.isEmpty)" }

    private func tell() {
        guard Store.testing else { return }
        MailSheetDrive.shared.seen = [
            "title": title, "lead": lead ?? "", "said": said ?? "", "hint": hint, "busy": busy, "ticked": ticked, "action": action,
            "ready": ready, "address": address, "typed": !password.isEmpty, "prompt": setup == nil ? "" : passwordPrompt(known.flatMap(MailSetupWay.of)),
            "imap": setup.map { "\($0.imapHost):\($0.imapPort)" } ?? "", "smtp": setup.map { "\($0.smtpHost):\($0.smtpPort)" } ?? "",
            "imapUser": setup?.imapUser ?? "", "provider": known?.id ?? "", "foundBy": setup?.foundBy ?? "",
        ]
    }

    private func take(_ poke: MailSheetDrive.Poke) {
        // Once: a sheet opened later never takes it again.
        DispatchQueue.main.async { if MailSheetDrive.shared.poke == poke { MailSheetDrive.shared.poke = nil } }
        if let typed = poke.address { address = typed }
        if let typed = poke.password { password = typed }
        if let typed = poke.name { name = typed }
        switch poke.press {
        case "continue", "connect": Task { await go() }
        case "cancel": cancel()
        default: break
        }
    }

    // MARK: - what shows

    /// The setup the agent is doing for this address, when it is.
    private var run: MailSetup.Run? {
        guard let run = agent.run, run.address == setup?.address.lowercased() else { return nil }
        return run
    }

    private var gmail: Bool { known?.id == "gmail" || provider == "gmail" }

    private var working: Bool { busy || (run != nil && run?.trouble == nil && run?.done == false) }

    /// Set It Up offered: the page signed in, the agent can, nothing failed.
    private var agentWay: Bool {
        guard case .imap = found, setup != nil, run == nil else { return false }
        return signedIn && !byHand && trouble == nil && MailSetup.available(known)
    }

    private var badge: MailMark.Badge? {
        switch found {
        case .gmail?: return .google
        case .microsoft?: return .site("outlook.com")
        case .imap(let setup, let provider)?:
            if provider?.id == "gmail" { return .google }
            return .site(provider?.domains.first ?? String(setup.address.split(separator: "@").last ?? ""))
        default: return nil
        }
    }

    private var title: String {
        if gmail { return "Gmail" }
        switch found {
        case .gmail?: return "Google Account"
        case .microsoft?: return "Outlook"
        case .imap(let setup, let provider)?:
            guard let provider else { return String(setup.address.split(separator: "@").last ?? "") }
            return provider.name.hasSuffix("Mail") || provider.name.hasSuffix("Bridge") ? provider.name : provider.name + " Mail"
        default: return "Add a Mail Account"
        }
    }

    private var lead: String? {
        if gmail { return "Gmail needs an app password for Yab." }
        switch found {
        case .gmail?: return "Gmail connects with Google\u{2019}s sign-in, in a tab."
        case .microsoft?: return "Outlook mail isn\u{2019}t in Yab yet. Its calendar is."
        default: break
        }
        guard let setup else { return nil }
        let provider = known
        if run != nil { return run?.done == true ? nil : "Your agent is doing it in a tab of its own." }
        if busy { return "Trying the password with \(provider?.name ?? setup.imapHost)." }
        if agentWay, let provider { return "You\u{2019}re signed in to \(MailSetupWay.pageName(provider)) in Yab." }
        if setup.foundBy == "guess" { return "Servers guessed from the address." }
        if let provider, provider.appPassword { return "\(provider.name) wants an app password for Yab." }
        return nil
    }

    private var said: String? { run?.trouble ?? trouble }

    private var foot: String? {
        if run != nil { return run?.done == true ? nil : "The new password goes from the page straight to the keychain." }
        switch found {
        case .imap?: return nil
        case .microsoft?: return "Meetings from Outlook show on your tabs. Mail comes with Yab\u{2019}s Microsoft sign-in."
        default: return "Your mail stays on this Mac, and Disconnect deletes it."
        }
    }

    /// What changes the sheet's height, for one animation.
    private var shape: String {
        "\(title)|\(lead ?? "")|\(servers)|\(byHand)|\(said ?? "")|\(run?.at ?? -1)|\(run?.asking ?? "")|\(agentWay)"
    }

    // MARK: - the middle

    @ViewBuilder
    private var middle: some View {
        switch found {
        case nil:
            picks.padding(.top, 12)
        case .gmail?:
            if let account = MailFound.shared.accounts.first(where: { $0.email == address.lowercased() }) {
                surface {
                    row(mark: { MailFace(email: account.email, photo: account.photo, side: 28) }) {
                        Text(account.email).lineLimit(1).truncationMode(.middle)
                        Text("Signed in in Yab: it\u{2019}s one Allow").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        case .some(.microsoft), .some(MailFinding.Found.none):
            EmptyView()
        case .imap?:
            if let run {
                surface { lines(run) }
            } else if agentWay, let known {
                surface {
                    row(mark: { pageMark(known) }) {
                        Text(MailSetupWay.pageName(known))
                        Text("Signed in in Yab as \(address.lowercased())").font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            } else if let setup {
                surface { steps(setup) }
            }
        }
    }

    /// Where the mail could be from, one press each: the address begun.
    private var picks: some View {
        HStack(spacing: 6) {
            ForEach(Self.picked, id: \.domain) { pick in
                Button {
                    address = "@" + pick.domain
                    focus = .address
                    DispatchQueue.main.async { NSApp.sendAction(#selector(NSResponder.moveToBeginningOfLine(_:)), to: nil, from: nil) }
                } label: {
                    HStack(spacing: 6) {
                        MailSiteMark(host: pick.domain, side: 18)
                        Text(pick.name).font(.system(size: 12.5))
                    }
                    .padding(.leading, 4) // design: the round mark sits concentric in the capsule
                    .padding(.trailing, 10)
                    .frame(height: 26)
                    .background(Capsule().fill(Palette.ink.opacity(0.05)))
                    .contentShape(Capsule())
                }
                .buttonStyle(PressStyle(scale: ButtonSize.regular.pressed))
            }
        }
    }

    static let picked: [(name: String, domain: String)] = [
        ("iCloud", "icloud.com"), ("Zoho", "zoho.com"), ("Yahoo", "yahoo.com"), ("Fastmail", "fastmail.com"),
    ]

    /// By hand: IMAP to turn on, the app password to make, where it goes,
    /// and the servers when they are open.
    @ViewBuilder
    private func steps(_ setup: MailServerSetup) -> some View {
        let way = known.flatMap(MailSetupWay.of)
        if hint == "imapDisabled", let known, let page = URL(string: known.imapSettingPage), !known.imapSettingPage.isEmpty {
            row(mark: { MailSiteMark(host: known.domains.first ?? "", side: 28) }) {
                Text("Turn on IMAP in \(known.name)")
                Text("Its mail settings").font(.callout).foregroundStyle(.secondary)
            } trailing: {
                Button(SettingsWords.text("Open")) { open(page) }.buttonStyle(.yab(.raised, .small))
            }
        }
        if let known, known.appPassword, let page = URL(string: known.appPasswordPage), !known.appPasswordPage.isEmpty {
            row(divided: hint == "imapDisabled", mark: { pageMark(known) }) {
                Text("Make one at \(MailSetupWay.pageName(known))")
                Text(gmail ? "Requires 2-Step Verification" : opened ? "Opened in a tab" : way?.path ?? "Name it Yab")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(2)
            } trailing: {
                Button(SettingsWords.text("Open")) { open(page); opened = true; focus = .password }.buttonStyle(.yab(.raised, .small))
            }
        }
        row(divided: known?.appPassword == true || hint == "imapDisabled", mark: { glyph("key") }) {
            SecureField(passwordPrompt(way), text: $password)
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .font(.system(size: 12.5, design: .monospaced))
                // A new app password, not a saved one: no Passwords… offer over the line that says why it was refused.
                .textContentType(nil)
                .focused($focus, equals: .password)
                .disabled(busy)
                .onSubmit { Task { await go() } }
                .overlay {
                    if ["authRejected", "appPasswordRequired"].contains(hint) {
                        RoundedRectangle(cornerRadius: Radius.small, style: .continuous).strokeBorder(ButtonCSS.danger, lineWidth: 1).allowsHitTesting(false)
                    }
                }
        }
        if servers {
            row(divided: true, mark: { glyph(text: "IN") }) { server(\.imapHost, \.imapPort, "imap.example.com") }
            row(divided: true, mark: { glyph(text: "OUT") }) { server(\.smtpHost, \.smtpPort, "smtp.example.com") }
        }
    }

    private func passwordPrompt(_ way: MailSetupWay?) -> String {
        if password.isEmpty, setup.map({ MailSecret.password(for: $0.address.lowercased()) != nil }) == true, run == nil, agent.run == nil,
           !MailCenter.shared.accounts.contains(address.lowercased()), known?.appPassword == true, way != nil, hint.isEmpty {
            return "Kept in the keychain"
        }
        if gmail { return "16-character app password" }
        return known?.appPassword == true ? way?.example ?? "App password" : "Password"
    }

    private func server(_ host: WritableKeyPath<MailServerSetup, String>, _ port: WritableKeyPath<MailServerSetup, Int>, _ prompt: String) -> some View {
        HStack(spacing: 6) {
            TextField(prompt, text: binding(host))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .font(.system(size: 12, design: .monospaced))
            TextField("993", value: binding(port), format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 54)
        }
    }

    /// The agent's steps as it goes, in words: each ticked once done; a
    /// tab it handed over, with the way to it.
    @ViewBuilder
    private func lines(_ run: MailSetup.Run) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(run.steps.enumerated()), id: \.offset) { index, step in
                HStack(spacing: 10) {
                    ZStack {
                        if index < run.at {
                            Symbol("checkmark", size: 10, weight: .bold).foregroundStyle(Color.green)
                        } else if index == run.at, run.trouble == nil {
                            if run.asking != nil {
                                Circle().fill(.tertiary).frame(width: 6, height: 6)
                            } else {
                                ProgressView().controlSize(.mini)
                            }
                        }
                    }
                    .frame(width: 16, height: 16)
                    Text(agent.words(step, run.provider))
                        .font(.system(size: 12.5))
                        .foregroundStyle(index <= run.at ? .primary : .tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
        .padding(.vertical, 4)
        if run.asking != nil {
            row(divided: true, mark: { pageMark(run.provider) }) {
                Text(run.askingWhat.isEmpty ? "\(MailSetupWay.pageName(run.provider)) asks for you" : run.askingWhat)
                Text("Your agent waits").font(.callout).foregroundStyle(.secondary)
            } trailing: {
                Button("Show the Tab") { agent.showAsking() }.buttonStyle(.yab(.raised, .small))
            }
        }
    }

    private var sends: some View {
        HStack(spacing: 4) {
            Text("Sends as").foregroundStyle(.secondary)
            TextField("Your name", text: $name)
                .textFieldStyle(.plain)
                .fixedSize()
                .disabled(working)
        }
        .font(.callout)
        .padding(.top, 12)
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            if helpable {
                Button { help() } label: {
                    HStack(spacing: 6) {
                        Symbol("agent.face", size: 13)
                        Text("Set It Up")
                    }
                }
                .buttonStyle(.yab(.quiet, .regular))
            }
            Spacer(minLength: 0)
            Button(SettingsWords.text("Cancel")) { cancel() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.yab(.secondary, .regular))
            Button { Task { await go() } } label: {
                HStack(spacing: 6) {
                    if agentWay { Symbol("agent.face", size: 13) }
                    Text(action)
                    KeyGlyphs(keys: "↩", size: 12.5, tint: nil, rest: 0.6)
                        .transaction { $0.animation = nil }
                }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.yab(.primary, .regular))
            .disabled(!ready)
        }
        .frame(maxWidth: .infinity)
    }

    /// Set It Up after a refusal: the agent takes it from there.
    private var helpable: Bool {
        guard trouble != nil || run?.trouble != nil, setup != nil, case .imap = found else { return false }
        return Agents.installed && MailCenter.agentsAllowed
    }

    private var action: String {
        switch found {
        case .gmail?: return "Continue with Google"
        case .microsoft?: return OutlookCalendars.shared.available ? "Add Outlook Calendar" : "Done"
        default:
            if setup == nil { return "Continue" }
            if run != nil { return run?.trouble == nil ? "Setting Up\u{2026}" : "Connect" }
            if agentWay { return "Set It Up" }
            return busy ? "Connecting\u{2026}" : "Connect"
        }
    }

    private var ready: Bool {
        if busy { return false }
        switch found {
        case .gmail?, .microsoft?: return true
        default:
            guard address.contains("@"), address.first != "@" else { return false }
            guard setup != nil else { return true }
            if let run { return run.trouble != nil && hasPassword }
            return agentWay || hasPassword
        }
    }

    private var hasPassword: Bool {
        !password.isEmpty || setup.map { MailSecret.password(for: $0.address.lowercased()) != nil } == true
    }

    // MARK: - pieces

    private func surface<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0, content: content)
            .multilineTextAlignment(.leading)
            .frame(width: Self.face)
            .background(Palette.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: Radius.surface, style: .continuous))
            .padding(.top, 16)
            .transition(.opacity)
    }

    private func row<Mark: View, Words: View>(divided: Bool = false, @ViewBuilder mark: () -> Mark, @ViewBuilder words: () -> Words) -> some View {
        row(divided: divided, mark: mark, words: words) { EmptyView() }
    }

    private func row<Mark: View, Words: View, Trailing: View>(divided: Bool = false, @ViewBuilder mark: () -> Mark, @ViewBuilder words: () -> Words,
                                                              @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            mark()
            VStack(alignment: .leading, spacing: 2) { words() }
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .overlay(alignment: .top) { if divided { Divider().padding(.horizontal, 12) } }
    }

    private func pageMark(_ provider: MailKnownProvider) -> some View {
        MailSiteMark(host: provider.id == "gmail" ? "google.com" : URL(string: provider.appPasswordPage)?.host ?? provider.domains.first ?? "", side: 28)
    }

    private func glyph(_ symbol: String = "", text: String? = nil) -> some View {
        Group {
            if let text {
                Text(text).font(.system(size: 10, weight: .semibold))
            } else {
                Symbol(symbol, size: 12)
            }
        }
        .foregroundStyle(.secondary)
        .frame(width: 28, height: 28)
        .background(Circle().fill(Palette.ink.opacity(0.07)))
    }

    private func binding<T>(_ path: WritableKeyPath<MailServerSetup, T>) -> Binding<T> {
        Binding(get: { setup![keyPath: path] }, set: { value in
            setup?[keyPath: path] = value
            // A port says its TLS: 993 and 465 from the first byte, the rest STARTTLS.
            let any = path as AnyKeyPath
            if any == (\MailServerSetup.imapPort as AnyKeyPath) { setup?.imapSecurity = setup?.imapPort == 993 ? .tls : .starttls }
            if any == (\MailServerSetup.smtpPort as AnyKeyPath) { setup?.smtpSecurity = setup?.smtpPort == 465 ? .tls : .starttls }
        })
    }

    // MARK: - doing

    private func clear() {
        if run != nil { agent.cancel() }
        found = nil
        setup = nil
        known = nil
        trouble = nil
        hint = ""
        servers = false
        opened = false
        signedIn = false
        byHand = false
    }

    private func cancel() {
        if run != nil { agent.cancel() }
        dismiss()
    }

    private func go() async {
        switch found {
        case .gmail?:
            dismiss()
            guard await MailClient.warnFirst(place: .settings) else { return }
            MailCenter.shared.connect(in: browser, hint: address.lowercased(), fromSettings: true)
            Links.window?.makeKeyAndOrderFront(nil)
        case .microsoft?:
            dismiss()
            if OutlookCalendars.shared.available {
                OutlookCalendars.shared.connect(in: browser, hint: address.lowercased())
                Links.window?.makeKeyAndOrderFront(nil)
            }
        default:
            if setup == nil { await find() } else if agentWay { setUp() } else { await connect() }
        }
    }

    /// Google was chosen explicitly, so the whole form stays available
    /// while a Gmail or Workspace address is typed.
    private func chooseGoogle() {
        guard let google = MailKnownProviders.by(id: "gmail") else { return }
        let one = google.setup(for: address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        known = google
        setup = one
        found = .imap(one, google)
        trouble = nil
        hint = ""
    }

    private func find() async {
        let wanted = address.trimmingCharacters(in: .whitespaces).lowercased()
        guard wanted.contains("@"), wanted.first != "@" else { return }
        busy = true
        trouble = nil
        let got: MailFinding.Found
        if let chosen = provider.flatMap(MailKnownProviders.by(id:)) {
            got = .imap(chosen.setup(for: wanted), chosen)
        } else {
            got = await MailFinding.find(wanted)
        }
        guard wanted == address.trimmingCharacters(in: .whitespaces).lowercased() else { busy = false; return }
        var signed = false
        if case .imap(_, let provider?) = got, MailSetup.available(provider) {
            signed = await MailSignedIn.check(provider, in: browser)
        }
        busy = false
        guard wanted == address.trimmingCharacters(in: .whitespaces).lowercased() else { return }
        withAnimation(still ? nil : Motion.settle) {
            found = got
            switch got {
            case .imap(let one, let provider):
                setup = one
                known = provider
                signedIn = signed
                servers = one.foundBy == "guess"
            case .none:
                trouble = "That doesn\u{2019}t look like a mail address."
            default:
                break
            }
        }
        if case .imap = got, !agentWay { focus = .password }
    }

    private var finalSetup: MailServerSetup? {
        guard var setup else { return nil }
        setup.name = name.trimmingCharacters(in: .whitespaces)
        return setup
    }

    /// The agent's way: it does the page, Yab keeps the password.
    private func setUp() {
        guard let setup = finalSetup, let known else { return }
        trouble = nil
        hint = ""
        if !agent.start(setup, provider: known, in: browser) {
            trouble = "Your agent couldn\u{2019}t start. Paste an app password yourself."
            byHand = true
        }
    }

    /// The password into the keychain, both servers tried with it, the
    /// account kept once both said yes.
    private func connect() async {
        guard var setup = finalSetup else { return }
        if run != nil { agent.cancel() }
        busy = true
        trouble = nil
        hint = ""
        defer { busy = false }
        let account = setup.address.lowercased()
        guard MailDesk.address(account) else { return }
        guard !MailCenter.shared.accounts.contains(account) || MailCenter.kind(of: account) == .imap else {
            trouble = "This account is already connected. Use Sign In Again in Mail settings."
            return
        }
        let pasted = MailSecret.cleaned(password, appPassword: known?.appPassword == true)
        let typed = !pasted.isEmpty
        guard let secret = typed ? pasted : MailSecret.password(for: account) else { return }
        let (result, tried) = await Self.tryBoth(setup, password: secret)
        setup = tried
        guard result.ok else {
            // Nothing kept of a password that didn't work.
            if !MailCenter.shared.accounts.contains(account) { MailSecret.forget(account) }
            let failed = (result.imap?.ok == false ? result.imap : result.smtp) ?? result.imap
            withAnimation(still ? nil : Motion.settle) {
                hint = failed?.hint ?? ""
                trouble = Self.words(failed, provider: known?.name)
                byHand = true
            }
            return
        }
        MailCenter.shared.addIMAP(setup, password: secret)
        if gmail { MailCenter.shared.pinOnce(in: browser) }
        password = ""
        land()
    }

    /// In: the mark closes with its tick, then the sheet goes; the first
    /// account's landing is behind it in Settings.
    private func land() {
        withAnimation(still ? nil : .snappy(duration: 0.24)) { ticked = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + (still ? 0 : 0.7)) { dismiss() }
    }

    /// Both servers tried with a password (MailProbe.connect): iCloud's
    /// IMAP by the name before @ or the whole address, a line closed at the
    /// sign-in tried again the other way. Answers the setup that worked.
    static func tryBoth(_ setup: MailServerSetup, password: String) async -> (MailProbe.Result, MailServerSetup) {
        await MailProbe.connect(setup, password: password)
    }

    /// A probe's failure for a person, in a line.
    static func words(_ server: MailProbe.Server?, provider: String?) -> String {
        guard let server else { return "Yab couldn\u{2019}t reach the servers." }
        let who = provider ?? server.host
        switch server.hint {
        case "appPasswordRequired" where provider == "Gmail": return "Gmail didn’t accept that app password. Make a new 16-character app password at Google Account."
        case "appPasswordRequired": return "\(who) wants an app password here, not the one you sign in with."
        case "authRejected": return "\(who) didn\u{2019}t take the password." + (server.said.isEmpty ? "" : " It said: \u{201C}\(server.said)\u{201D}")
        case "imapDisabled": return "IMAP is off in \(who)."
        case "dnsNotFound": return "There\u{2019}s no server called \(server.host)."
        case "tcpRefused", "timedOut": return "\(server.host) didn\u{2019}t answer on port \(server.port)."
        case "tlsFailed": return "\(server.host)\u{2019}s certificate isn\u{2019}t one Yab can trust."
        // The line gone before it said anything: said as that, never a bare
        // "refused", which read as the password refused (#441).
        case "closed": return "\(who) closed the connection before it took the password. Try again in a moment."
        case "offline": return "This Mac is offline."
        default: return server.said.isEmpty ? "\(who) didn\u{2019}t answer the sign-in." : "\(who) said: \u{201C}\(server.said)\u{201D}"
        }
    }

    /// Set It Up after a refusal. With the page signed in, the agent does
    /// it all (MailSetup); otherwise it takes it from here in a chat (docs/
    /// mail-providers.md, What the agent does): the password typed stays in
    /// the keychain for its mail_probe, the servers as found are kept for
    /// it, and the person presses Connect again when it is done.
    private func help() {
        if signedIn, MailSetup.available(known) {
            byHand = false
            setUp()
            return
        }
        guard let setup = finalSetup else { return }
        let account = setup.address.lowercased()
        guard MailDesk.address(account) else { return }
        guard !MailCenter.shared.accounts.contains(account) || MailCenter.kind(of: account) == .imap else {
            trouble = "This account is already connected. Use Sign In Again in Mail settings."
            return
        }
        let pasted = MailSecret.cleaned(password, appPassword: known?.appPassword == true)
        if !pasted.isEmpty { MailSecret.save(password: pasted, for: account) }
        setup.saved(in: Store.settings)
        _ = MailChat.start(Self.helpWords(account, provider: known, said: trouble ?? run?.trouble ?? ""), say: "Set up " + account, refs: [], in: browser, open: true)
        dismiss()
    }

    static func helpWords(_ account: String, provider: MailKnownProvider?, said: String) -> String {
        var words = "Help me set up the mail account \(account) in Yab. Connecting it said: \(said)\n\n"
        words += "Run mail_probe on \(account) to see which step fails; it tries the password I typed into Yab\u{2019}s own field. Never ask me for a password in the chat and never type one anywhere."
        if let provider, !provider.appPasswordPage.isEmpty {
            words += " If it wants an app password, open \(provider.appPasswordPage) in a tab of your own, wait for me to sign in, and show me where to make one for Yab; I paste it into Settings \u{203A} Mail \u{203A} Add Account myself."
        }
        if let provider, !provider.imapSettingPage.isEmpty {
            words += " If IMAP is off for the mailbox, find the switch at \(provider.imapSettingPage) and ask me before turning it on."
        } else {
            words += " If the servers are wrong, read the domain\u{2019}s mail help pages and try the ones they name with mail_probe."
        }
        words += " When mail_probe says both servers take the password, tell me to press Connect again. Say what is left in a line."
        return words
    }

    private func open(_ page: URL) {
        _ = browser.open(page, foreground: true)
        Links.window?.makeKeyAndOrderFront(nil)
    }
}
