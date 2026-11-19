import AppKit
import SwiftUI

extension Browser {
    /// No old secret is read. The place owns the draft and discards it when
    /// the selection, place or window closes, including during owner proof.
    func editPassword(_ entry: Vault.Entry) {
        guard let parent = fieldHost ?? BrowserWindows.shared.window(for: self) ?? NSApp.keyWindow else { return }
        let reason = "edit the password for \(entry.host)"
        proveOwner(reason) { [weak self, weak parent] in
            guard let self, let parent, parent.isVisible,
                  self.fieldShowing, self.query.place == .passwords,
                  self.placeItem?.id == "login." + entry.id else { return }
            let editor = PasswordEditController(entry: entry, prove: { [weak self] done in
                guard let self else { done(false); return }
                self.proveOwner(reason, otherwise: { done(false) }) { done(true) }
            }, write: { host, user, password in
                Vault.updateLogin(host: entry.host, user: entry.user, newHost: host, newUser: user, password: password)
            }, endEditing: { [weak self] in
                guard let self else { return }
                (self.fieldHost ?? BrowserWindows.shared.window(for: self))?.makeFirstResponder(nil)
            }, didSave: { [weak self] in
                guard let self, self.query.place == .passwords else { return }
                self.query.revealed = nil
                self.finishEdit(select: "login." + (self.query.edit?.passwordEditor?.model.host ?? entry.host)
                                + "\u{1}" + (self.query.edit?.passwordEditor?.model.userName ?? entry.user))
            })
            self.beginEdit(.login(editor))
        }
    }
}

/// What the card edits. Plain strings, so the real controls can be tested
/// without a browser, an authentication prompt or a Keychain.
@MainActor
@Observable final class PasswordEditModel {
    let entry: Vault.Entry
    var website: String
    var userName: String
    var password = ""
    var showing = false
    var error: String?
    var waiting = false
    var finished = false

    init(entry: Vault.Entry) {
        self.entry = entry
        website = entry.host
        userName = entry.user
    }

    /// The site as it will be kept, nil while the field holds no site.
    /// Untouched, it stays exactly as saved, whatever its case.
    var host: String? { website == entry.host ? entry.host : Vault.cleanHost(website) }

    /// Something differs from what is saved: a site, a name or a new password.
    var changed: Bool { host != entry.host || userName != entry.user || !password.isEmpty }

    var canSave: Bool { !finished && !waiting && host != nil && changed }
}

/// The place's edit session. Storage and proof callbacks are shared by the
/// real preview and synthetic tests; there is no separate window or modal loop.
@MainActor
final class PasswordEditController: NSObject {
    let model: PasswordEditModel
    private let prove: (@escaping (Bool) -> Void) -> Void
    private let write: (String, String, String?) -> Vault.LoginEdit
    private let endEditing: () -> Void
    private let didSave: () -> Void

    var waiting: Bool { model.waiting }
    var finished: Bool { model.finished }

    init(entry: Vault.Entry, prove: @escaping (@escaping (Bool) -> Void) -> Void,
         write: @escaping (String, String, String?) -> Vault.LoginEdit,
         endEditing: @escaping () -> Void = {}, didSave: @escaping () -> Void) {
        self.prove = prove
        self.write = write
        self.endEditing = endEditing
        self.didSave = didSave
        model = PasswordEditModel(entry: entry)
        super.init()
    }

    func save(_ sender: Any?) {
        guard model.canSave, let host = model.host else { return }
        endEditing()
        model.waiting = true
        model.error = nil
        let user = model.userName
        let password = model.password.isEmpty ? nil : model.password
        // Reuse the existing five-minute owner proof at Save too. A cancelled
        // editor cannot write if a delayed authentication answer arrives later.
        prove { [weak self] allowed in
            guard let self, !self.model.finished else { return }
            self.model.waiting = false
            guard allowed else { return }
            switch self.write(host, user, password) {
            case .saved:
                self.discard()
                self.didSave()
            case .taken:
                self.model.error = "That login is already saved."
            case .failed:
                self.model.error = "The keychain didn\u{2019}t take it. Try again."
            }
        }
    }

    func cancel(_ sender: Any?) { discard() }

    private func discard() {
        guard !model.finished else { return }
        endEditing()
        model.finished = true
        model.waiting = false
        model.password = ""
        model.showing = false
    }
}

/// The approved form inside the Passwords preview. Its actions live in the foot.
struct PasswordEditForm: View {
    @Bindable var model: PasswordEditModel
    let save: () -> Void
    let cancel: () -> Void
    @FocusState private var focus: Field?
    private enum Field { case website, user, password }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                SiteMark(host: model.entry.host, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Edit Login").font(.system(size: 13.5, weight: .semibold))
                    Text("Saved in Yab").font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
            }
            field("Website", focus: .website) {
                TextField("example.com", text: $model.website)
                    .accessibilityLabel("Website")
            }
            field("User name", focus: .user) {
                TextField("Optional", text: $model.userName)
                    .accessibilityLabel("User name")
            }
            field("Password", focus: .password) {
                HStack(spacing: 6) {
                    Group {
                        if model.showing {
                            TextField("Leave empty to keep it", text: $model.password)
                        } else {
                            SecureField("Leave empty to keep it", text: $model.password)
                        }
                    }
                    .accessibilityLabel("New password")
                    Button(model.showing ? "Hide" : "Show") { model.showing.toggle() }
                        .buttonStyle(.yab(.quiet, .small))
                        .focusable(false)
                }
            }
            if let error = model.error {
                Text(error).font(.system(size: 11.5)).foregroundStyle(Color.red)
            } else {
                Text("Changes only what is saved in Yab, not the site.")
                    .font(.system(size: 11.5)).foregroundStyle(Palette.muted)
            }
        }
        .textFieldStyle(.plain)
        .font(.system(size: 13))
        .onSubmit(save)
        .onExitCommand(perform: cancel)
        .onAppear { focus = .website }
    }

    private func field<Content: View>(_ title: String, focus at: Field, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11.5)).foregroundStyle(Palette.muted)
            content()
                .disabled(model.waiting || model.finished)
                .focused($focus, equals: at)
                .focusEffectDisabled()
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(Palette.wash, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .strokeBorder(focus == at ? Color.accentColor : Palette.hairline, lineWidth: 1)
                }
        }
    }
}
