import AppKit
import SwiftUI

// Settings › AI › Assistants › Enter a Code: a page further in, as What
// Syncs is, not a sheet. The code an assistant showed, typed or pasted into
// two groups of four, then, on the same page, what it may do and the yes.

/// The pages further in, as `SettingsModel.opened`.
enum AssistantPlace {
    static let code = "code"
    static let add = "assistant-add"
}

/// What the code page starts from, set just before it opens: a code that
/// came in (an assistant's OAuth page, the connection task) with the nonce
/// it has to carry, or the bot whose message the page offers to copy.
@MainActor
enum AssistantCodeHandoff {
    static var code: String?
    static var nonce: String?
    static var client: String?
    static var revision = 0
}

struct AssistantCodePage: View {
    var browser: Browser
    var model: SettingsModel
    @State private var code = ""
    @State private var nonce: String?
    @State private var client: String?
    @State private var link: AssistantHost.Link?
    @State private var busy = false
    @State private var trouble: String?
    @State private var name = ""
    @State private var space: UUID?
    @State private var mode: AgentAsking = .auto
    @State private var mail = false
    @State private var messages = false
    @State private var cards = false
    @State private var guarded = true
    @State private var connected: AssistantGrant?
    @State private var checking = 0
    @State private var expired = false
    @State private var wasFirst = false

    var body: some View {
        Group {
            if let connected { success(connected) }
            else if let link { ThreadForm { consent(link) }.formStyle(.grouped) }
            else { entry }
        }
        .task {
            wasFirst = Assistants.shared.grants.isEmpty
            nonce = AssistantCodeHandoff.nonce
            client = AssistantCodeHandoff.client
            let given = AssistantCodeHandoff.code
            AssistantCodeHandoff.code = nil
            AssistantCodeHandoff.nonce = nil
            AssistantCodeHandoff.client = nil
            if let given {
                code = CodeGroupsField.clean(given)
                look()
            }
        }
    }

    // MARK: the code

    private var entry: some View {
        GeometryReader { bounds in
            let compact = bounds.size.height < 540
            VStack(spacing: compact ? 12 : 20) {
                AssistantBotIcon(client: client ?? "", side: compact ? 48 : 66)
                Text("Enter a Code").font(.system(size: 17, weight: .medium))
                Text("Enter the eight-character code shown by your assistant.")
                    .foregroundStyle(.secondary).font(.callout)
                CodeGroupsField(code: Binding(get: { code }, set: {
                    code = $0
                    AssistantConnect.shared.editCode($0)
                    checking += 1
                    busy = false
                    trouble = nil
                    expired = false
                }), invalid: trouble != nil, onPaste: look, onSubmit: look)
                    .accessibilityIdentifier("assistant-code")
                if let trouble {
                    Text(trouble).font(.callout).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if expired {
                    HStack(spacing: 8) {
                        if Agents.installed, let bot = AssistantBot.allCases.first(where: { $0.client == client }) {
                            Button("Get a New Code") {
                                finish()
                                model.open(.assistants, item: AssistantPlace.add)
                                AssistantConnect.shared.connect(bot)
                            }.settingsButton(.primary)
                        }
                        Button("Copy Message", action: copyMessage).settingsButton()
                    }
                } else {
                    Button(action: look) {
                        HStack(spacing: 6) {
                            Text(busy ? "Checking…" : trouble == nil ? "Continue" : "Try Again")
                            KeyGlyphs(keys: "↩", size: 12.5, tint: nil).opacity(0.6)
                        }.frame(maxWidth: .infinity)
                    }
                    .keyboardShortcut(.defaultAction)
                    .settingsButton(.primary)
                    .disabled(busy || code.count != CodeGroupsField.length)
                }
                if !expired { Button("Copy Message", action: copyMessage).settingsButton(.quiet) }
            }
            .frame(maxWidth: 360)
            .padding(compact ? 16 : 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: compact ? .top : .center)
            .multilineTextAlignment(.center)
        }
    }

    private func copyMessage() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(AssistantsPage.message(client: client ?? "your-assistant", nonce: nil), forType: .string)
    }

    private func look() {
        guard !busy, code.count == CodeGroupsField.length else { return }
        busy = true
        trouble = nil
        expired = false
        checking += 1
        let mine = checking
        let requested = code
        Task {
            do {
                let found = try await AssistantHost.shared.lookup(requested)
                guard mine == checking, code == requested else { return }
                if !found.matches(client: nonce == nil ? nil : client, nonce: nonce) {
                    trouble = "This code isn't from the connection just started. Check it with your assistant."
                    busy = false
                    return
                }
                name = Assistants.name(client: identity(found))
                space = browser.spaces.first { $0.id == Spaces.current }?.id ?? browser.spaces.first?.id
                withAnimation(Motion.settle) { link = found }
            } catch {
                guard mine == checking, code == requested else { return }
                if case AssistantHost.Failure.status(410) = error {
                    expired = true
                    trouble = "This code has expired. \(Assistants.name(client: client ?? "your assistant")) needs to show a new one."
                } else if case AssistantHost.Failure.status(404) = error {
                    trouble = "No assistant is waiting with this code. Check the letters with \(Assistants.name(client: client ?? "your assistant"))."
                } else { trouble = error.localizedDescription }
            }
            busy = false
        }
    }

    private func identity(_ link: AssistantHost.Link) -> String {
        nonce == nil ? link.presentationClient : (client ?? link.presentationClient)
    }

    // MARK: the yes

    @ViewBuilder private func consent(_ link: AssistantHost.Link) -> some View {
        AssistantSubHero(client: identity(link), title: "Let \(name) use Yab?",
                         detail: "Code \(String(code.prefix(4)))-\(String(code.suffix(4))) from \(name)" + (link.redirectHost.map { " · access goes to \($0)" } ?? " · allow only if it matches the code your assistant showed."))
        Section {
            SettingsRow("Tabs of its own, signed in as you") { EmptyView() }
            AssistantSpaceRow(spaces: browser.spaces, selection: $space)
            MenuRow("Asks you first", options: [(title: "Before sending, paying, deleting", value: AgentAsking.auto),
                                                (title: "Also before signing in", value: AgentAsking.ask)], selection: $mode)
            SettingsRow("Never sees history, passwords or files") { EmptyView() }
            SettingsRow("Away from banks and government sites", detail: "Payment apps too.") {
                Toggle("Away from banks and government sites", isOn: $guarded).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
        } header: { Text("\(name) Can").foregroundStyle(.secondary) }
        Section {
            SettingsRow("Mail", detail: "Search, read and draft mail. Sending requires approval.") {
                Toggle("Mail", isOn: $mail).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .disabled(!MailCenter.shared.connected)
            }
            SettingsRow("Codes from Messages") {
                Toggle("Codes from Messages", isOn: $messages).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            SettingsRow("Saved cards and addresses", detail: "Each use requires approval.") {
                Toggle("Saved cards and addresses", isOn: $cards).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
        } header: {
            Text("Also Allow").foregroundStyle(.secondary)
        } footer: {
            HStack(alignment: .top, spacing: 8) {
                if let trouble { TroubleLine(words: trouble) }
                Spacer(minLength: 0)
                Button("Don\u{2019}t Allow") { decide(link, allow: false) }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.yab(.secondary, .regular))
                    .disabled(busy)
                // Never Return: a link alone can open this page.
                Button("Allow") { decide(link, allow: true) }
                    .buttonStyle(.yab(.primary, .regular))
                    .disabled(busy)
            }
            .font(.callout)
        }
    }

    private func decide(_ link: AssistantHost.Link, allow: Bool) {
        busy = true
        trouble = nil
        var grant: AssistantGrant?
        if allow {
            var made = AssistantGrant(id: Assistants.newID(), name: name, client: identity(link), made: Date())
            made.selectSpace(space)
            made.mode = mode
            made.mail = mail
            made.messages = messages
            made.cards = cards
            if guarded { made.never = Assistants.guarded }
            grant = made
        }
        Task {
            do {
                try await AssistantHost.shared.decide(link, grant: grant)
                AssistantConnect.shared.clear()
                if let grant {
                    AssistantConnect.shared.justConnected = grant.id
                    if wasFirst { connected = grant }
                    else { finish() }
                } else { finish() }
            } catch {
                trouble = error.localizedDescription
            }
            busy = false
        }
    }
    private func finish() {
        model.leave(AssistantPlace.code, to: .assistants)
        model.leave(AssistantPlace.add, to: .assistants)
    }

    private func success(_ grant: AssistantGrant) -> some View {
        ArrivalFrame {
            VStack(spacing: 16) {
                AssistantBotIcon(client: grant.client, side: 66)
                    .overlay(alignment: .bottomTrailing) {
                        Symbol("checkmark.circle.fill", size: 20).foregroundStyle(Palette.success).offset(x: 4, y: 4)
                    }
                Text("\(grant.name) is connected").font(.system(size: 17, weight: .medium))
                Text("Ask it \(grant.client == "dots" ? "in ChatGPT " : "")to do something on the web. Its tabs open in \(grant.spaceName(in: browser.spaces)).")
                    .font(.callout).foregroundStyle(.secondary).frame(maxWidth: 360)
                HStack(spacing: 8) {
                    Button("Done") { finish() }.settingsButton(.primary)
                    if let bot = AssistantBot.allCases.first(where: { $0.client == grant.client }) {
                        Button("Open \(grant.name)") { Links.openFromSettings(URL(string: bot.url)!, in: browser) }.settingsButton()
                    }
                }
                HStack(spacing: 12) {
                    Text("Another assistant").foregroundStyle(.secondary)
                    Button("Add…") {
                        AssistantConnect.shared.clear()
                        AssistantConnectIntent.selection = nil
                        finish()
                        model.open(.assistants, item: AssistantPlace.add)
                    }.settingsButton()
                }.padding(.top, 12)
            }
        }
    }

}

/// The top of the code page: the assistant's face when Yab knows which
/// one it is, else the page's tile; its name and a line.
private struct AssistantSubHero: View {
    let client: String?
    let title: String
    let detail: String

    var body: some View {
        Section {} header: {
            VStack(spacing: 0) {
                Group {
                    if let client, !client.isEmpty {
                        AssistantBotIcon(client: client, side: 56)
                    } else {
                        PenTileView(page: .assistants).frame(width: 56, height: 56)
                    }
                }
                .padding(.bottom, 12)
                Text(title)
                    .font(.system(size: 22, weight: .bold))
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4) // design: PageHero's gap under the name
                    .padding(.horizontal, 24)
            }
            .foregroundStyle(.primary)
            .textCase(nil)
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
            .padding(.bottom, 16) // design: PageHero's air above the first group
            .accessibilityElement(children: .combine)
        }
    }
}

/// A code in two groups of four, each on a plate, as Sync shows its codes:
/// typed or pasted in any form ("k7qm 2xpa"), the mask giving way a letter
/// at a time and a ring round the group being typed into. Monospaced, so a
/// letter takes exactly its mask letter's room and nothing moves.
struct CodeGroupsField: View {
    @Binding var code: String
    var editable = true
    var autofocus = true
    var invalid = false
    var onPaste: () -> Void = {}
    var onSubmit: () -> Void = {}
    /// How many, and how many to a plate: Apple Passwords' code is six
    /// digits in two groups of three.
    var count = Self.length
    var per = 4
    /// Digits alone, as a code from Passwords is.
    var digits = false
    @FocusState private var focused: Bool
    @Namespace private var ringSpace

    static let length = 8

    /// Letters and digits only, upper case, at most eight.
    static func clean(_ text: String, count: Int = length, digits: Bool = false) -> String {
        String(text.uppercased().filter { $0.isASCII && (digits ? $0.isNumber : $0.isLetter || $0.isNumber) }.prefix(count))
    }

    static func isCompletePaste(previous: String, proposed: String) -> Bool {
        let next = clean(proposed)
        return next.count == length && (next.count - clean(previous).count > 1 || proposed.count > length)
    }

    var body: some View {
        HStack(spacing: 10) {
            ForEach(0..<max(1, count / per), id: \.self) { group in
                if group > 0 { Text("\u{2013}").foregroundStyle(.tertiary) }
                plate(group)
            }
        }
        .font(.system(size: 22, weight: .semibold, design: .monospaced))
        .background {
            if editable {
                // The keys go to a field no one sees; the plates draw it.
                TextField("", text: Binding(get: { code }, set: { raw in
                    let old = code
                    code = Self.clean(raw, count: count, digits: digits)
                    if count == Self.length, Self.isCompletePaste(previous: old, proposed: raw) { onPaste() }
                }))
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit(onSubmit)
                    .opacity(0.01)
                    .accessibilityLabel("Code")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .animation(Motion.settle, value: code)
        .animation(Motion.settle, value: focused)
        .onAppear { if editable && autofocus { focused = true } }
        .onChange(of: autofocus) { _, on in if editable && on { focused = true } }
        .accessibilityElement(children: editable ? .contain : .ignore)
        .accessibilityLabel(editable ? "" : code)
    }

    private func plate(_ group: Int) -> some View {
        let typed = Array(code)
        let groups = max(1, count / per)
        let active = editable && focused && typed.count < count && min(typed.count / per, groups - 1) == group
        return HStack(spacing: 0) {
            ForEach(0..<per, id: \.self) { i in
                let at = group * per + i
                ZStack {
                    Text("\u{B7}")
                        .foregroundStyle(.tertiary)
                        .opacity(at < typed.count ? 0 : 1)
                    if at < typed.count {
                        Text(String(typed[at]))
                            .id("\(at)\(typed[at])")
                            .transition(.offset(y: -10).combined(with: .opacity))
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Palette.wash, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .overlay {
            if invalid {
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .strokeBorder(Color.orange, lineWidth: 2)
            } else if active {
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .matchedGeometryEffect(id: "ring", in: ringSpace)
            }
        }
    }
}
