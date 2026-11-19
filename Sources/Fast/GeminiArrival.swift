import SwiftUI

/// The approved account-choice screen, shared by Connect and Switch Account.
struct GeminiArrival: View {
    var browser: Browser
    private var choices = GeminiChoices.shared
    private var gemini = GeminiAccount.shared
    @State private var more = false

    var body: some View {
        VStack(spacing: 0) {
            GeminiAccountMark(email: choices.pick.email, photo: choices.pick.photo, another: choices.pick.source == .another, side: 56, connecting: choices.looking)
            Text("Which Google account?")
                .font(.system(size: 17, weight: .medium))
                .padding(.top, 16)
            Text("Gemini runs on that account's Google AI plan.")
                .font(.callout).foregroundStyle(.secondary)
                .padding(.top, 6)
            picker.padding(.top, 16)
            Button(choices.pick.email.map { "Connect " + $0 } ?? "Connect Google Account") {
                gemini.choice = choices.pick
                choices.showing = false
                if AgentSetupModel.shared.installed("gemini") { AgentSetupModel.shared.connect(["gemini"], browser) }
                else { AgentSetupModel.shared.install("gemini", browser) }
            }
            .settingsButton(.primary)
            .disabled(choices.looking)
            .padding(.top, 20)
            Button("Back") {
                choices.showing = false
                ProviderConsent.shared.endConnection("gemini")
            }
            .settingsButton(.quiet).padding(.top, 8)
            Text("Gemini keeps one Google account on this Mac. Switching signs out the current account in Antigravity too.")
                .font(.caption).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 340).padding(.top, 12)
        }
        .multilineTextAlignment(.center)
        .padding(28) // design: 340-point list plus two 28-point margins keeps the chooser at 396 points
        .task { await choices.look(browser, switching: choices.switching) }
        .onDisappear {
            if gemini.choice == nil, !AgentSetupModel.shared.busy { ProviderConsent.shared.endConnection("gemini") }
        }
    }

    private var picker: some View {
        let accounts = choices.rows.filter { $0.source != .another }
        let shown = more ? accounts : Array(accounts.prefix(4))
        let hidden = accounts.count - shown.count
        return VStack(spacing: 0) {
            ForEach(shown) { choice in
                row(choice)
                Divider().padding(.horizontal, 12)
            }
            if hidden > 0 {
                Button("\(hidden) more signed in") { more = true }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                Divider().padding(.horizontal, 12)
            }
            row(.another)
        }
        .frame(width: 340)
        .background(Palette.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: Radius.surface))
    }

    private func row(_ choice: GeminiChoice) -> some View {
        Button { choices.chosen = choice.id } label: {
            HStack(spacing: 12) {
                if let email = choice.email {
                    MailFace(email: email, photo: choice.photo, side: 28)
                        .overlay(alignment: .bottomTrailing) {
                            if choice.source == .mac {
                                Symbol("laptopcomputer", size: 9).background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                            }
                        }
                } else {
                    Symbol("plus", size: 12).frame(width: 28, height: 28)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(choice.email ?? "Another Google Account").lineLimit(1).truncationMode(.middle)
                    Text(detail(choice)).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Symbol("checkmark", size: 11, weight: .bold)
                    .opacity(choices.pick.id == choice.id ? 1 : 0).frame(width: 16)
            }
            .padding(.horizontal, 12).padding(.vertical, 10).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(choices.pick.id == choice.id ? .isSelected : [])
    }

    private func detail(_ choice: GeminiChoice) -> String {
        switch choice.source {
        case .mac: return ["On this Mac", choice.plan].compactMap { $0 }.joined(separator: " · ")
        case .another: return "You sign in to it in a private tab"
        case .space(let id):
            if browser.prefs.usesSpaces, browser.spaces.contains(where: \.ownSignIns),
               let space = browser.spaces.first(where: { $0.id == id }) { return "Signed in in " + space.marked() }
            return choice.name.isEmpty ? "Signed in in Yab" : choice.name
        }
    }
}

struct GeminiAccountMark: View {
    var email: String?
    var photo: URL?
    var another = false
    let side: CGFloat
    var connecting = false

    var body: some View {
        let corner = (side * 0.42).rounded()
        AgentMark(cli: "gemini", side: side)
            .overlay { if connecting { SquareRing(side: side) } }
            .notched(email != nil || another, side: corner, radius: corner / 2, offset: corner * 0.28, gap: side > 30 ? 2.5 : 1.5)
            .overlay(alignment: .bottomTrailing) {
                if let email {
                    MailFace(email: email, photo: photo, side: corner)
                        .offset(x: corner * 0.28, y: corner * 0.28)
                } else if another {
                    Text("G").font(.system(size: corner * 0.55, weight: .bold))
                        .frame(width: corner, height: corner)
                        .background(Circle().fill(Palette.ink.opacity(0.08)))
                        .offset(x: corner * 0.28, y: corner * 0.28)
                }
            }
    }
}
