import Combine
import SwiftUI

/// Settings › Sync › Add a Device, using the same code field and page
/// frame as connecting an assistant. Leaving cancels the invitation.
struct SyncAddDevicePage: View {
    var model: SettingsModel
    private var adding = SyncDeviceAdding.shared
    private var sync = SyncCenter.shared

    var body: some View {
        GeometryReader { bounds in
            let compact = bounds.size.height < 540
            ArrivalFrame {
                VStack(spacing: compact ? 8 : 16) {
                    if let invite = adding.invite {
                        SyncDeviceInvitation(invite: invite, adding: adding, compact: compact)
                    } else {
                        Text("Turn on Sync to add another device.").foregroundStyle(.secondary)
                    }
                    // Under the digits the Cancel is the join's own.
                    if !adding.joining && !sync.joiningAccounts {
                        Button(adding.finished ? "Done" : "Cancel") { model.leave(SyncPlace.add, to: .sync) }
                            .settingsButton(.quiet)
                    }
                }
                .frame(maxWidth: 380)
                // No hero: the toolbar names the page as soon as it scrolls,
                // its top 24 points of padding the first to go under.
                .onChange(of: sync.joinedByCode) { _, _ in model.leave(SyncPlace.add, to: .sync) }
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY - 23 } action: { top in
                    SettingsWindow.shared.heroTitle(SettingsWords.text("Add a Device"), bottom: top)
                }
            }
        }
        .onAppear { adding.start() }
        .onDisappear { adding.stop() }
    }
}

private struct SyncDeviceInvitation: View {
    var invite: SyncInvite
    var adding: SyncDeviceAdding
    var sync = SyncCenter.shared
    let compact: Bool

    var body: some View {
        Group {
            if sync.joiningAccounts {
                ProgressView().controlSize(.small)
                Text("Joining…").foregroundStyle(.secondary)
            } else if adding.joining, let check = sync.joiningCheck {
                // A code of another Mac typed here, sync on on both.
                if sync.joinAgreed {
                    Text("Waiting for Your Other Mac").font(.headline)
                    Text("Choose Let In there.").foregroundStyle(.secondary)
                } else {
                    Text("Join Your Other Mac’s Sync?").font(.headline)
                    Text("Join only if it shows these digits. What’s on this Mac stays and syncs with it.")
                        .foregroundStyle(.secondary)
                }
                Text(SyncPage.spaced(check))
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                if adding.slow {
                    Text("Nothing yet. Check the code on your other Mac.").font(.callout).foregroundStyle(.orange)
                }
                HStack(spacing: 8) {
                    Button("Cancel") { adding.cancelJoin() }.settingsButton()
                    if !sync.joinAgreed {
                        Button("Join") { sync.agreeToJoin() }.settingsButton(.primary)
                    }
                }
            } else if adding.finished {
                Symbol("checkmark.circle", size: 32).foregroundStyle(.green)
                Text("Device Added").font(.headline)
                Text("It has everything in a moment.").foregroundStyle(.secondary)
            } else if adding.busy || invite.phase == .lettingIn {
                ProgressView().controlSize(.small)
                Text("Letting it in…").foregroundStyle(.secondary)
            } else {
                switch invite.phase {
                case .waiting:
                    entry
                case .arrived(let check):
                    Text("Let In This Device?").font(.headline)
                    Text("Let it in only if these are the digits on its screen.")
                        .foregroundStyle(.secondary)
                    Text(SyncPage.spaced(check))
                        .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    HStack(spacing: 8) {
                        Button("Not This One") { adding.start() }.settingsButton()
                        Button("Let In") { adding.confirm() }.settingsButton(.primary)
                    }
                case .expired, .failed:
                    Text(invite.words ?? "That device couldn’t be let in.")
                        .foregroundStyle(.secondary)
                    Button("Get a New Code") { adding.start() }.settingsButton(.primary)
                case .letIn, .lettingIn:
                    EmptyView()
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var entry: some View {
        VStack(spacing: compact ? 8 : 16) {
            if let apart = sync.keptApart {
                SeparateRow(name: apart.name, keep: false)
                Divider()
            }
            InviteCode(invite: invite, side: compact ? 112 : 132)
                .multilineTextAlignment(.leading)
            Divider()
            Text("Or enter the other device’s code").font(.headline)
            Text("An iPhone shows one under Join Your Mac. A Mac shows one here.")
                .font(.callout).foregroundStyle(.secondary)
            CodeGroupsField(code: Binding(get: { adding.code }, set: { adding.edit($0) }),
                            onSubmit: { adding.approve() })
                .accessibilityIdentifier("sync-device-code")
            if let trouble = adding.trouble {
                Text(trouble).font(.callout).foregroundStyle(.orange)
            }
            Button("Continue") { adding.approve() }
                .settingsButton(.primary)
                .disabled(adding.code.count != CodeGroupsField.length)
        }
    }
}

/// Owns the active page's invitation and ignores callbacks after leaving
/// or starting a new code. Typing a code never approves it by itself.
@MainActor
@Observable final class SyncDeviceAdding {
    static let shared = SyncDeviceAdding()
    private(set) var invite: SyncInvite?
    private(set) var code = ""
    private(set) var busy = false
    private(set) var trouble: String?
    private(set) var finished = false
    /// The code typed is another syncing Mac's: this Mac waits under it.
    private(set) var joining = false
    /// Half a minute and no Let In: a slow person, or a mistyped code.
    private(set) var slow = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var joinTrouble: AnyCancellable?
    @ObservationIgnored private var watch: AnyCancellable?
    private let makeInvite: @MainActor () -> SyncInvite?
    private let approveCode: @MainActor (String, @escaping (Bool) -> Void) -> Void
    private let letIn: @MainActor (SyncInvite) -> Void
    private let joinCode: @MainActor (String) -> Void
    private let stopJoin: @MainActor () -> Void
    private let joinWords: AnyPublisher<String?, Never>

    init(makeInvite: @escaping @MainActor () -> SyncInvite? = { SyncCenter.shared.invite() },
         approveCode: @escaping @MainActor (String, @escaping (Bool) -> Void) -> Void = { SyncCenter.shared.approve(code: $0, $1) },
         letIn: @escaping @MainActor (SyncInvite) -> Void = { SyncCenter.shared.letIn($0) {} },
         joinCode: @escaping @MainActor (String) -> Void = { SyncCenter.shared.askToJoin(invite: $0) },
         stopJoin: @escaping @MainActor () -> Void = { SyncCenter.shared.stopAsking() },
         joinWords: AnyPublisher<String?, Never>? = nil) {
        self.makeInvite = makeInvite
        self.approveCode = approveCode
        self.letIn = letIn
        self.joinCode = joinCode
        self.stopJoin = stopJoin
        self.joinWords = joinWords ?? SyncCenter.shared.observed(\.joinTrouble).eraseToAnyPublisher()
    }

    func start() {
        stop()
        code = ""
        trouble = nil
        finished = false
        newInvite()
    }

    func stop() {
        generation += 1
        watch = nil
        invite?.stop()
        invite = nil
        busy = false
        if joining { stopJoin() }
        joining = false
        slow = false
        joinTrouble = nil
    }

    func edit(_ text: String) {
        guard !busy else { return }
        let cleaned = CodeGroupsField.clean(text)
        // The field hands its text back unchanged when it comes back after
        // a try: that is no edit, and the trouble under it stays.
        guard cleaned != code else { return }
        code = cleaned
        trouble = nil
    }

    func approve() {
        guard !busy, !finished, code.count == CodeGroupsField.length,
              invite?.phase == .waiting else { return }
        // The code this very page shows, typed back into it: it goes on the
        // other device (register 1628).
        if let invite, Self.same(code, invite.code) {
            trouble = "That’s this Mac’s code. Enter it on the device you’re adding, or enter the code that device shows here."
            return
        }
        busy = true
        trouble = nil
        let mine = generation
        // Only one pairing path can be in flight on this page.
        invite?.stop()
        approveCode(code) { [weak self] ok in
            guard let self, self.generation == mine else { return }
            self.busy = false
            if ok { self.finished = true } else { self.join() }
        }
    }

    /// Typed code nobody waits under: another syncing Mac's own Add a Device
    /// code, which invites instead, or a slip. The server can't tell them
    /// apart, so this Mac waits under it and shows the digits (register 1738).
    private func join() {
        let mine = generation
        joining = true
        joinCode(code)
        joinTrouble = joinWords.compactMap { $0 }.sink { [weak self] words in
            guard let self, self.joining else { return }
            self.joining = false
            self.slow = false
            self.joinTrouble = nil
            self.trouble = words
            self.newInvite()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.patience) { [weak self] in
            guard let self, self.generation == mine, self.joining else { return }
            self.slow = true
        }
    }

    static let patience: TimeInterval = 30

    /// Cancel under the digits: back to the code, this Mac as it was.
    func cancelJoin() {
        guard joining else { return }
        stopJoin()
        joining = false
        slow = false
        joinTrouble = nil
        code = ""
        newInvite()
    }

    static func same(_ typed: String, _ shown: String) -> Bool {
        CodeGroupsField.clean(typed) == CodeGroupsField.clean(shown)
    }

    private func newInvite() {
        watch = nil
        invite = makeInvite()
        watch = invite?.observed(\.phase).sink { [weak self] phase in
            if phase == .letIn { self?.finished = true }
        }
        invite?.start { _ in }
    }

    func confirm() {
        guard !busy, !finished, let invite, case .arrived = invite.phase else { return }
        letIn(invite)
    }
}
