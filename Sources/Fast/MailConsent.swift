import SwiftUI

// What the person agreed to about agents and their mail (docs/casa.md,
// Consent). Google's Limited Use lets mail go to the AI the person
// connected only with their consent, given in the app by their own hand,
// before anything is read, each use asked for apart: so every switch here
// is off until it is turned on, nothing turns one on for them, and an
// agent can't turn one on through Settings' native actions.
//
// Two uses, two switches: Mail you hand to Claude (`mail.agents`: D, ⌘J in
// Mail, a task's mail tools) and Replies written ahead (`mail.ahead`, with
// Split summaries, `mail.summaries`, the same kind of read). A third,
// `mail.agents.others`, gives the mail tools to other apps the person gave
// `yab mcp` (Cursor, Zed and the rest).
//
// Asked once: right after Connect, on the landing (MailLanding); for an
// account connected before this, by a row at the foot of mail's column that
// opens Settings › Mail › Agents (MailConsentRow).

@MainActor
enum MailConsent {
    nonisolated static let agentsKey = "mail.agents"
    nonisolated static let aheadKey = "mail.ahead"
    static let summariesKey = "mail.summaries"
    static let othersKey = "mail.agents.others"
    /// The person answered: turned a switch, or said Not Now.
    static let askedKey = "mail.consent.asked"
    /// The values kept before consent was asked were Yab's defaults, not the
    /// person's answer: dropped once.
    static let migratedKey = "mail.consent.v1"

    /// Settings › Mail › Agents' Mail tools in other apps.
    static var others: Bool { Store.settings.bool(forKey: othersKey) }

    static var asked: Bool { Store.settings.bool(forKey: askedKey) }

    static func answered() {
        BackgroundConsent.mailChanged()
        guard !asked else { return }
        Store.settings.set(true, forKey: askedKey)
    }

    /// Once, at launch: what an older Yab kept for these switches goes, so
    /// each is off until the person turns it on; a test world's own
    /// choices stay as it set them.
    static func migrate() {
        guard !Store.settings.bool(forKey: migratedKey) else { return }
        Store.settings.set(true, forKey: migratedKey)
        guard !Store.testing else { return }
        for key in [agentsKey, aheadKey, summariesKey] { Store.settings.removeObject(forKey: key) }
    }

    /// The row in mail's column: an account is in, an AI is connected to
    /// read with, and the person hasn't answered yet.
    static var rowShows: Bool { MailCenter.shared.connected && PlanText.any && !asked }
}

extension MailConsent {
    /// Whose terms a read goes under: the company behind the writer.
    static func company(_ writer: String) -> String {
        let name = writer.trimmingCharacters(in: .whitespacesAndNewlines)
        return AgentPlan.all.first { $0.name.caseInsensitiveCompare(name) == .orderedSame || $0.cli.caseInsensitiveCompare(name) == .orderedSame }?.maker
            ?? (name.isEmpty ? "your assistant" : name)
    }

    static func handDetail(_ writer: String) -> String {
        "Press D on a mail or ⌘J in Mail, and \(writer) reads it on your plan. A task asks once before it searches your mail, and before it changes or sends anything."
    }

    static func aheadDetail(_ writer: String) -> String {
        "\(writer) reads new mail that needs you and drafts three replies, on your plan. It can’t send or change anything."
    }

    static func terms(_ writer: String) -> String {
        "Mail goes to \(company(writer)) only when \(writer) reads it, under your account’s terms. Yab keeps no copy. Both are off until you turn them on."
    }
}

/// The two switches, on the landing after Connect, drawn as the way in's
/// list of accounts is: one surface, a row each.
struct MailConsentList: View {
    @AppStorage(MailConsent.agentsKey, store: Store.settings) private var hand = false
    @AppStorage(MailConsent.aheadKey, store: Store.settings) private var ahead = false
    private var agents = AgentSetupModel.shared

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Symbol("agent.face", size: 12)
                    Text("\(agents.writer) and your mail")
                }
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                row("Mail you hand to \(agents.writer)", MailConsent.handDetail(agents.writer), $hand, first: true)
                row("Replies written ahead", MailConsent.aheadDetail(agents.writer), $ahead, first: false)
            }
            .multilineTextAlignment(.leading)
            .frame(width: 340)
            .background(Palette.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: Radius.surface, style: .continuous))
            Text(MailConsent.terms(agents.writer))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360)
                .padding(.top, 8)
        }
        .onChange(of: hand) { MailConsent.answered() }
        .onChange(of: ahead) { MailConsent.answered() }
    }

    private func row(_ title: String, _ detail: String, _ on: Binding<Bool>, first: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(title, isOn: on)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .overlay(alignment: .top) { if !first { Divider().padding(.horizontal, 12) } }
    }
}
