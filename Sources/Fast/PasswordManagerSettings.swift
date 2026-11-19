import AppKit
import SwiftUI

// Settings › Passwords' Password managers (docs/password-managers.md): Yab's
// own passwords on a switch, then the connected managers, the managers on
// this Mac with Connect on their row, and Connect Password Manager for the
// rest, a page of its own. Every question is a card over Settings
// (PasswordCardLayer), as Search's and Spaces' are: Connect with the unlock
// choice, an unlock password, Disconnect.

/// Settings › Passwords' own pages, by `SettingsModel.opened`.
enum PasswordManagersPlace {
    /// Connect a Password Manager: the managers not on this Mac.
    static let connect = "connect-manager"
    /// One manager's Connect: its steps, who unlocks it, Connect.
    static func connect(_ id: String) -> String { connect + ":" + PasswordManagers.canonical(id) }
    /// The manager a Connect page is for.
    static func manager(_ opened: String?) -> String? {
        guard let opened, opened.hasPrefix(connect + ":") else { return nil }
        return String(opened.dropFirst(connect.count + 1))
    }
    /// Either Connect page is open.
    static func connecting(_ opened: String?) -> Bool { opened?.hasPrefix(connect) == true }
}

/// The section at the top of Settings › Passwords.
struct PasswordManagersSection: View {
    @Bindable var prefs: Preferences
    var model: SettingsModel
    let browser: Browser
    private var extensions = Extensions.here
    private var managers = ManagerExtensions.shared
    private var connections = PasswordManagers.Connections.shared

    private var note: String {
        if !prefs.usesYabPasswords && connections.list.isEmpty { return "Yab doesn't fill or save passwords. Agents ask you to sign in." }
        if connections.list.isEmpty { return "Connect the password manager you already use, and agents can sign in with it too." }
        return "Agents sign in with these. On a site, pick the sign-in from their own menu as you do now."
    }

    /// On this Mac and not connected yet: Connect on their row.
    private var here: [String] {
        PasswordManagers.providers.map(\.id).filter {
            connections.connection($0) == nil && PasswordManagers.found($0) != nil
        }
    }

    var body: some View {
        Section {
            HStack(spacing: 10) {
                PenTileView(page: .passwords, side: 28).frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 3) { // design: SettingsRow's own 3 between a title and its line
                    Text(SettingsWords.text("Use Yab's passwords"))
                    Text("Yab fills and saves your sign-ins from this Mac's keychain.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Toggle(SettingsWords.text("Use Yab's passwords"), isOn: $prefs.usesYabPasswords)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .settingsAnchor("use-yab-passwords")
        } header: {
            Text("Password managers")
        }
        Section {
            ForEach(connections.list, id: \.provider) { connection in
                ManagerRow(id: connection.provider, model: model, browser: browser)
            }
            ForEach(here, id: \.self) { id in
                HereRow(id: id)
            }
            AddManagerRow(title: here.isEmpty ? "Connect Password Manager" : "Other Password Manager…") {
                model.open(.passwords, item: PasswordManagersPlace.connect)
            }
        } footer: {
            SettingsNote(note)
        }
        .onAppear { connections.look(); connections.lookAround(); managers.refresh() }
    }
}

/// "+ Connect Password Manager", as Extensions' "+ Add Extension".
private struct AddManagerRow: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Symbol("plus", size: 11, weight: .semibold)
                    .frame(width: 20)
                Text(title)
            }
            .foregroundStyle(hovering ? Palette.ink : Palette.muted)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: ButtonSize.regular.pressed))
        .onHover { hovering = $0 }
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsAnchor("connect-password-manager")
    }
}

/// A manager on this Mac, not connected: where it was found, and Connect.
private struct HereRow: View {
    let id: String
    private var extensions = Extensions.here
    private var managers = ManagerExtensions.shared
    private var connections = PasswordManagers.Connections.shared

    var body: some View {
        HStack(spacing: 10) {
            ManagerIcon(id: id, side: 28)
            VStack(alignment: .leading, spacing: 3) { // design: SettingsRow's own 3 between a title and its line
                Text(PasswordManagers.name(id))
                Text(managers.adding == id ? "Adding its extension…" : PasswordManagers.found(id) ?? "")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if managers.adding == id {
                ProgressView().controlSize(.small)
            } else {
                Button(SettingsWords.text("Connect")) { connections.openConnect(id) }.settingsButton()
            }
        }
        .settingsAnchor("password-manager-here-\(id)")
    }
}

/// A connected manager: its extension's icon, its name, its state in
/// words, at most one button, and ⋯.
private struct ManagerRow: View {
    let id: String
    var model: SettingsModel
    let browser: Browser
    private var extensions = Extensions.here
    private var managers = ManagerExtensions.shared
    private var connections = PasswordManagers.Connections.shared
    @State private var waiting = false

    var body: some View {
        let row = connections.row(id)
        let name = PasswordManagers.name(id)
        HStack(spacing: 10) {
            ManagerIcon(id: id, side: 28)
            VStack(alignment: .leading, spacing: 3) { // design: SettingsRow's own 3 between a title and its line
                Text(name)
                if row.trouble {
                    TroubleLine(words: row.words)
                } else {
                    Text(row.words).font(.callout).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if managers.adding == id || waiting {
                ProgressView().controlSize(.small)
            } else if let action = row.action {
                Button(action) { act(row) }.settingsButton()
            }
            SettingsMoreMenu("Manage \(name)", entries: entries) {
                Symbol("ellipsis", size: 12, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .fixedSize()
        }
        .background {
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .fill(Color.accentColor.opacity(connections.flash == id ? 0.18 : 0))
                .padding(-4)
                .animation(.easeOut(duration: 1.4), value: connections.flash == id)
        }
        .onChange(of: extensions.onePasswordAnswered) { _, _ in waiting = false }
        .settingsAnchor("password-manager-\(id)")
    }

    private func act(_ row: PasswordManagers.Row) {
        switch row {
        case .noExtension: managers.add(id)
        case .off: if let item = PasswordManagers.installed(id) { managers.setEnabled(item.id, true) }
        case .notAllowed:
            waiting = true
            Extensions.openOnePassword()
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { waiting = false }
        case .wrongPassword, .passwordMissing: connections.card = .password(id)
        case .yabUnlocks, .youUnlock: break
        }
    }

    private func entries() -> [SettingsMenuEntry] {
        let name = PasswordManagers.name(id)
        let mode = connections.connection(id)?.mode ?? .you
        var entries: [SettingsMenuEntry] = [.header("Unlock Password")]
        if mode == .yab {
            entries.append(.item("Change Unlock Password…") { connections.card = .password(id) })
            entries.append(.item("Forget Unlock Password") { connections.forgetPassword(id) })
        } else if PasswordManagers.yabMayUnlock(id) {
            entries.append(.item("Save Unlock Password…") { connections.card = .password(id) })
        }
        entries += [.separator, .item("Open \(name)") { PasswordManagers.open(id, in: browser) }]
        if id == PasswordManagers.apple, browser.passwordImportRoute.available(for: id) {
            entries.append(.item(Command.importYabPasswords.title) { browser.passwordImportRoute.run() })
        }
        // Apple Passwords through Yab's helper doesn't use its extension:
        // its page would only show a switch Yab turned off.
        let native = PasswordManagers.canonical(id) == PasswordManagers.apple && PasswordManagers.appleNative
        if let item = PasswordManagers.installed(id), !native {
            entries.append(.item("Extension Settings") { model.open(extension: item.id) })
        }
        entries.append(.destructive("Disconnect…") { connections.card = .disconnect(id) })
        return entries
    }
}

/// A manager's own icon in the 28-point square Settings' rows use.
struct ManagerIcon: View {
    let id: String
    let side: CGFloat
    private var extensions = Extensions.here
    private var managers = ManagerExtensions.shared

    var body: some View {
        Group {
            if let image = PasswordManagers.icon(id) {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Palette.ink.opacity(0.05)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.25, style: .continuous)) // design: an icon tile's corner, a quarter of its side
        .accessibilityHidden(true)
    }
}

// MARK: - the cards

/// The password managers' cards, over the whole of Settings as Search's
/// and Spaces' are: drawn in the frame they are asked for, no sheet to
/// slide in first (that took 0.32 s, and finding the managers in the
/// sheet's body 1.5 s more).
struct PasswordCardLayer: View {
    private var connections = PasswordManagers.Connections.shared

    var body: some View {
        ZStack {
            if let card = connections.card {
                Group {
                    switch card {
                    case .password(let id): UnlockPasswordCard(id: id)
                    case .disconnect(let id): DisconnectManagerCard(id: id)
                    }
                }
                .frame(width: 440)
                .onAppear { connections.cardShown() }
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.97).combined(with: .opacity).animation(Motion.arrive),
                    removal: .identity
                ))
                .id(card)
            }
        }
    }
}

/// A card's head: the well (a manager's icon, or a mark), what it asks,
/// and the line under it.
private struct CardHead: View {
    let title: String
    let detail: String
    var manager: String?
    var symbol = "plus"

    var body: some View {
        HStack(alignment: .top, spacing: CardFrame.wellGap) {
            if let manager {
                ManagerIcon(id: manager, side: CardFrame.well)
            } else {
                let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                shape.fill(Palette.ink.opacity(0.05))
                    .overlay(shape.strokeBorder(Palette.ink.opacity(0.08), lineWidth: 0.5))
                    .overlay { Symbol(symbol, size: 16).foregroundStyle(Palette.ink) }
                    .frame(width: CardFrame.well, height: CardFrame.well)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(CardFrame.title).foregroundStyle(Palette.ink)
                Text(detail)
                    .font(CardFrame.detail)
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A card's answer with its key on a plate beside the words.
private struct CardButton: View {
    let title: String
    let keys: String
    var kind: ButtonKind = .secondary
    var tint: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                KeyGlyphs(keys: keys, size: CardFrame.words, tint: nil, rest: 0.6)
            }
        }
        .buttonStyle(.yab(kind, CardFrame.button, tint: tint))
        .fixedSize()
    }
}

/// The words of a failed add, short: the store's own refusal, or the
/// network's, which are long, as one line.
@MainActor private func addTrouble(_ id: String) -> String? {
    guard ManagerExtensions.shared.addFailed(id) else { return nil }
    return "Couldn't add its extension. Check the connection and try again."
}

/// Connect a Password Manager, for the managers not on this Mac: a page
/// under Passwords, a row each. Add brings a manager's extension in, and
/// then Connect asks how it unlocks; connected, it is back to Passwords.
struct ConnectManagersPage: View {
    var model: SettingsModel
    private var extensions = Extensions.here
    private var managers = ManagerExtensions.shared
    private var connections = PasswordManagers.Connections.shared
    /// Fixed as the page opens, so a row added here stays where it was.
    @State private var ids: [String] = PasswordManagers.providers.map(\.id).filter {
        PasswordManagers.Connections.shared.connection($0) == nil && PasswordManagers.found($0) == nil
    }

    var body: some View {
        PageHero(title: "Connect a Password Manager",
                 detail: "Allow agents to sign in and request permission to unlock this manager.") {
            PenTileView(page: .passwords)
        }
        Section {
            ForEach(ids.filter { connections.connection($0) == nil }, id: \.self) { id in row(id) }
        }
        .onChange(of: connections.list.map(\.provider)) { _, now in
            if ids.contains(where: now.contains) { connections.leaveConnect() }
        }
        // Added here, with nothing to ask: connected, not one more press.
        .onChange(of: managers.adding) { was, _ in
            if let was, PasswordManagers.connectsAtOnce(was) { connections.openConnect(was) }
        }
    }

    private func row(_ id: String) -> some View {
        let selectable = PasswordManagers.selectable(id)
        let added = PasswordManagers.installed(id) != nil
        let trouble = addTrouble(id)
        let detail = !selectable ? "Needs Apple's approval for Yab"
            : managers.adding == id ? "Adding its extension…"
            : trouble ?? (added ? "Extension in Yab" : "Adds its extension to Yab")
        return HStack(spacing: 10) {
            ManagerIcon(id: id, side: 28)
            VStack(alignment: .leading, spacing: 3) { // design: SettingsRow's own 3 between a title and its line
                Text(PasswordManagers.name(id))
                if selectable, trouble != nil, managers.adding != id {
                    TroubleLine(words: detail)
                } else {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !selectable {
                EmptyView()
            } else if managers.adding == id {
                ProgressView().controlSize(.small)
            } else if added {
                Button(SettingsWords.text("Connect")) { connections.openConnect(id) }.settingsButton()
            } else {
                Button(trouble == nil ? "Add" : "Try Again") { managers.add(id) }.settingsButton()
            }
        }
        .opacity(selectable ? 1 : 0.45)
        .settingsAnchor("connect-manager-\(id)")
    }
}

/// An empty dot, or the ink's with a dot of the ground in it.
private struct Dot: View {
    let on: Bool

    var body: some View {
        Circle()
            .fill(on ? Palette.ink : Color.clear)
            .overlay { if on { Circle().fill(Palette.ground).frame(width: 7, height: 7) } } // design: the hole in a chosen dot, not a card
            .overlay { if !on { Circle().strokeBorder(Palette.ink.opacity(0.35), lineWidth: 1.5) } }
            .frame(width: 18, height: 18)
    }
}

private struct GreenTick: View {
    var body: some View {
        Circle().fill(Color(nsColor: .systemGreen))
            .overlay(Symbol("checkmark", size: 8, weight: .bold).foregroundStyle(.white))
            .frame(width: 18, height: 18)
    }
}

/// A step's mark: its number, a spinner while it runs, a tick once done.
private struct SetUpMark: View {
    let number: Int
    let done: Bool
    let busy: Bool

    var body: some View {
        Group {
            if done { GreenTick() }
            else if busy { ProgressView().controlSize(.small) }
            else {
                Text("\(number)").font(.system(size: 11)).foregroundStyle(Palette.muted)
                    .frame(width: 18, height: 18)
                    .overlay(Circle().strokeBorder(Palette.ink.opacity(0.35), lineWidth: 1.5))
            }
        }
        .frame(width: 28)
    }
}

/// A password box: the lock, the words hidden or shown, the eye.
private struct UnlockField: View {
    let placeholder: String
    @Binding var text: String
    var bad = false
    var submit: () -> Void = {}
    @State private var showing = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Symbol("lock", size: 13).foregroundStyle(Palette.muted)
            Group {
                if showing { TextField("", text: $text) } else { SecureField("", text: $text) }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 13.5))
            .foregroundStyle(Palette.ink)
            .focused($focused)
            .onSubmit(submit)
            .overlay(alignment: .leading) {
                if text.isEmpty, !InputMethod.composing(focused: focused) {
                    Text(placeholder).font(.system(size: 13.5)).foregroundStyle(Palette.muted).allowsHitTesting(false)
                }
            }
            Button { showing.toggle(); focused = true } label: {
                Symbol(showing ? "eye.slash" : "eye", size: 13).foregroundStyle(Palette.muted)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showing ? "Hide password" : "Show password")
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
            .fill(Palette.ink.opacity(focused ? 0.035 : 0.06)))
        .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
            .strokeBorder(bad ? ButtonCSS.danger : Palette.ink.opacity(focused ? 0.22 : 0), lineWidth: 1))
        .onAppear { DispatchQueue.main.async { focused = true } }
        // Emptied when Yab loses focus: nothing typed waits around.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in text = "" }
    }
}

/// One manager's Connect, a page under Passwords: what is left to set up
/// (its extension, and 1Password's yes in its app), then who unlocks it,
/// then Connect ↩. Back is Cancel.
struct ConnectManagerPage: View {
    let id: String
    private var extensions = Extensions.here
    private var managers = ManagerExtensions.shared
    private var connections = PasswordManagers.Connections.shared
    @State private var mode = PasswordManagers.Mode.you
    @State private var password = ""
    @State private var tried = false
    @State private var failed = false
    @State private var allowing = false

    init(id: String) {
        self.id = id
        _mode = State(initialValue: PasswordManagers.Connections.shared.connection(id)?.mode ?? .you)
    }

    private var name: String { PasswordManagers.name(id) }
    private var yab: Bool { mode == .yab }
    private var valid: Bool { !yab || !password.trimmingCharacters(in: .whitespaces).isEmpty }
    private var added: Bool { PasswordManagers.installed(id) != nil }
    /// 1Password's app, only where it is on this Mac.
    private var allows: Bool {
        PasswordManagers.provider(id)?.allows == true && connections.here[PasswordManagers.canonical(id)] == PasswordManagers.appFound
    }
    private var allowed: Bool {
        guard let item = PasswordManagers.installed(id) else { return false }
        return extensions.onePasswordAnswered.contains(item.id)
    }
    /// Steps shown only while one of them is left: a manager already
    /// working connects with the choice alone.
    private var setUp: Bool { PasswordManagers.leftToSetUp(id) || managers.adding == id }

    var body: some View {
        PageHero(title: "Connect \(name)", detail: "Choose how to unlock \(name).") {
            ManagerIcon(id: id, side: 56)
        }
        if setUp {
            Section { steps } header: { Text("Set up") }
        }
        Section {
            // The manager's own way first, where it has one; Yab's
            // second, and never picked for you.
            let own = PasswordManagers.ownUnlock(id)
            choice(on: !yab, title: own.title, detail: own.detail) {
                mode = .you
                password = ""
            } more: { EmptyView() }
            if PasswordManagers.yabMayUnlock(id) || yab {
                choice(on: yab, title: "Yab unlocks it",
                       detail: "Store the unlock password on this Mac. Agents can use it; manual use requires Touch ID once per session.") {
                    if mode != .yab { mode = .yab; password = ""; tried = false }
                } more: {
                    if yab {
                        UnlockField(placeholder: "\(name) unlock password", text: $password, bad: failed || (tried && !valid)) {
                            if valid { connect() } else { tried = true }
                        }
                        .onChange(of: password) { _, _ in failed = false }
                        if failed {
                            Text("Yab couldn't save it on this Mac. Try again.")
                                .font(.system(size: 11.5)).foregroundStyle(ButtonCSS.danger)
                        } else if tried && !valid {
                            Text("Enter the password you unlock \(name) with.")
                                .font(.system(size: 11.5)).foregroundStyle(ButtonCSS.danger)
                        }
                    }
                }
            }
        } header: {
            Text("Who unlocks it")
        } footer: {
            HStack(spacing: 8) {
                Spacer(minLength: 8)
                Button(SettingsWords.text("Cancel")) { password = ""; connections.leaveConnect() }
                    .buttonStyle(.yab(.secondary, .regular))
                Button(SettingsWords.text("Connect")) { if valid { connect() } else { tried = true } }
                    .buttonStyle(.yab(.primary, .regular))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 8)
        }
        .animation(Motion.settle, value: setUp)
        // The extension added on this page, and nothing left to ask.
        .onChange(of: setUp) { _, now in
            if !now, PasswordManagers.connectsAtOnce(id) { connections.openConnect(id) }
        }
    }

    @ViewBuilder private var steps: some View {
        let adding = managers.adding == id
        let trouble = adding ? nil : addTrouble(id)
        step(mark: SetUpMark(number: 1, done: added, busy: adding),
             title: "Add the \(name) extension",
             detail: added ? "Added." : adding ? "Adding…" : trouble ?? "From the Chrome Web Store, into Yab.",
             trouble: trouble != nil) {
            if !added && !adding {
                Button(trouble == nil ? "Add" : "Try Again") { managers.add(id) }.settingsButton()
            }
        }
        if allows {
            step(mark: SetUpMark(number: 2, done: allowed, busy: allowing && !allowed),
                 title: "Allow Yab in 1Password",
                 detail: allowed ? "1Password allowed Yab." : allowing ? "Waiting for 1Password…"
                     : "In 1Password: Settings › Browser › Add Browser, then choose Yab.") {
                if !allowed && !allowing {
                    Button("Open 1Password") {
                        allowing = true
                        Extensions.openOnePassword()
                    }
                    .settingsButton()
                }
            }
        }
    }

    private func step<Trail: View>(mark: SetUpMark, title: String, detail: String, trouble: Bool = false,
                                   @ViewBuilder trail: () -> Trail) -> some View {
        HStack(spacing: 10) {
            mark
            VStack(alignment: .leading, spacing: 3) { // design: SettingsRow's own 3 between a title and its line
                Text(title)
                if trouble {
                    TroubleLine(words: detail)
                } else {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trail()
        }
    }

    private func choice<More: View>(on: Bool, title: String, detail: String, pick: @escaping () -> Void,
                                    @ViewBuilder more: () -> More) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) { // design: SettingsRow's own 3 between a title and its line
                    Text(title)
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Dot(on: on)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: pick)
            more()
        }
        .accessibilityAddTraits(.isButton)
    }

    /// Connected: back on Passwords, its row lit.
    private func connect() {
        guard connections.connectAndSignIn(id, mode: mode, password: yab ? password : nil) else {
            failed = true
            return
        }
        password = ""
    }
}

/// Save Unlock Password…, Change Unlock Password…, Change… and Save Again….
private struct UnlockPasswordCard: View {
    let id: String
    private var connections = PasswordManagers.Connections.shared
    @State private var password = ""
    @State private var failed = false

    var body: some View {
        let name = PasswordManagers.name(id)
        VStack(alignment: .leading, spacing: 0) {
            CardHead(title: "\(name) Unlock Password",
                     detail: "Store the unlock password on this Mac. Agents can use it; manual use requires Touch ID once per session.", manager: id)
            VStack(alignment: .leading, spacing: 6) {
                UnlockField(placeholder: "\(name) unlock password", text: $password, bad: failed) { save() }
                    .onChange(of: password) { _, _ in failed = false }
                if failed {
                    Text("Yab couldn't save it on this Mac. Try again.")
                        .font(.system(size: 11.5)).foregroundStyle(ButtonCSS.danger)
                }
            }
            .padding(.top, 12)
            HStack(spacing: 6) {
                Spacer(minLength: 8)
                CardButton(title: "Cancel", keys: "esc") { password = ""; connections.card = nil }
                CardButton(title: "Save", keys: "↩", kind: .primary, action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.top, CardFrame.buttonGap)
        }
        .cardFrame()
        .onExitCommand { password = ""; connections.card = nil }
    }

    private func save() {
        guard !password.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        guard connections.connect(id, mode: .yab, password: password) else { failed = true; return }
        password = ""
        connections.card = nil
    }
}

/// Disconnect…'s question.
private struct DisconnectManagerCard: View {
    let id: String
    private var connections = PasswordManagers.Connections.shared

    var body: some View {
        let name = PasswordManagers.name(id)
        VStack(alignment: .leading, spacing: 0) {
            CardHead(title: "Disconnect \(name)?",
                     detail: "Stop agent access to \(name) and delete its saved unlock password. Your \(name) account and extension are kept.",
                     manager: id)
            HStack(spacing: 6) {
                Spacer(minLength: 8)
                CardButton(title: "Cancel", keys: "esc") { connections.card = nil }
                CardButton(title: "Disconnect", keys: "↩", kind: .danger) {
                    connections.disconnect(id)
                    connections.card = nil
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, CardFrame.buttonGap)
        }
        .cardFrame()
        .onExitCommand { connections.card = nil }
    }
}
