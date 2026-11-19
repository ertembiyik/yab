import AppKit
import SwiftUI

/// Settings › Mail (docs/mail.md) once an account is in; before that the
/// pane is the way in (MailArrival). As AI is: the accounts and the mail
/// pin here, and a row for each page further in, saying how it is set.
struct MailSettings: View {
    var browser: Browser
    @Bindable var prefs: Preferences
    var model: SettingsModel
    private var center = MailCenter.shared
    private var outlook = OutlookCalendars.shared
    private var list = MailList.shared
    private var notify = MailNotify.shared
    private var agents = AgentSetupModel.shared
    @AppStorage("mail.ahead", store: Store.settings) private var ahead = false
    @AppStorage("mail.pixels", store: Store.settings) private var pixels = true
    @AppStorage("mail.agents", store: Store.settings) private var agentsWork = false
    @AppStorage("mail.undo", store: Store.settings) private var undo = 5
    @AppStorage("mail.slots.start", store: Store.settings) private var start = 9 * 60
    @AppStorage("mail.slots.end", store: Store.settings) private var end = 18 * 60
    @AppStorage("mail.slots.length", store: Store.settings) private var length = 30

    /// Whether mail links from other apps come here (MailDefault), asked
    /// again each time the page shows.
    @State private var mailDefault = true

    var body: some View {
        PageHero(page: .mail)
            .settingsAnchor("mail")
        if !prefs.usesMail {
            Section {
                SettingsNote("When off, Mail is hidden and stops syncing. Local mail is kept until you disconnect.")
            }
        }
        // The accounts stay in reach while it is off: disconnecting is always yours.
        Section {
            ForEach(center.accounts, id: \.self) { account in
                MailAccountRow(browser: browser, account: account)
            }
            ForEach(outlook.accounts, id: \.self) { account in
                OutlookAccountRow(browser: browser, account: account)
            }
            MailAddAccount(browser: browser)
                .disabled(!prefs.usesMail)
        } footer: {
            SettingsNote("Right-click an account to disconnect it.")
        }
        .settingsAnchor("mail-accounts")
        // Show in All Accounts, an account each, once there are several.
        if center.accounts.count > 1 {
            MailAllAccountsSettings()
        }
        Group {
            Section {
                SettingsRow("Mail pin", detail: "Show Mail and its count in pinned tabs.") {
                    Toggle(SettingsWords.text("Mail pin"), isOn: Binding(get: { center.pinWanted },
                                                     set: { $0 ? center.putPin(in: browser) : center.takePin(in: browser) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                .settingsAnchor("mail-pin")
                // Only while it isn't: once it is, there is nothing to do.
                if !mailDefault {
                    SettingsRow("Default mail app", detail: "Open mail links in Yab.") {
                        Button(SettingsWords.text("Make Default")) {
                            MailDefault.become { now in
                                mailDefault = now
                                if !now { browser.announce("macOS kept your old mail app", mark: "envelope", on: SettingsWindow.shared.toaster) }
                            }
                        }
                        .settingsButton()
                    }
                    .settingsAnchor("mail-default")
                }
            }
            Section {
                FeatureRow(.mailInbox, detail: inboxDetail, model: model)
                FeatureRow(.mailNotify, detail: notifyDetail, model: model)
                FeatureRow(.mailReading, detail: readingDetail, model: model)
                FeatureRow(.mailWriting, detail: writingDetail, model: model)
                FeatureRow(.mailCalendar, detail: calendarDetail, model: model)
            }
            Section {
                // Off with an agent connected: turned on right on its row.
                FeatureRow(.mailAgents, detail: agentsDetail, model: model) {
                    if !agentsWork && ai {
                        Button("Turn On") {
                            agentsWork = true
                            MailConsent.answered()
                        }
                        .settingsButton()
                    }
                }
                // Only once someone is: an empty list is no page.
                if !MailBlockedList.blocked(center).isEmpty {
                    FeatureRow(.mailBlocked, detail: blockedDetail, model: model)
                }
            }
        }
        .disabled(!prefs.usesMail)
        .task { await agents.look() }
        .onAppear { mailDefault = MailDefault.isDefault }
    }

    /// "Asks you something, the last month".
    private var inboxDetail: String {
        let needs = list.policy.asks ? "Asks you something" : "Everything from people"
        let back = switch list.policy.days ?? 0 {
        case 7: "the last week"
        case 30: "the last month"
        default: "every age"
        }
        return needs + ", " + back
    }

    private var notifyDetail: String {
        guard notify.permission == .allowed else { return "Off for Yab in macOS" }
        let on = center.accounts.filter { notify.mode($0) != .off }.count
        let said = on == 0 ? "No new mail notifications"
            : center.accounts.count == 1 ? "New mail: " + notify.mode(center.accounts[0]).title
            : "New mail from \(on) of \(center.accounts.count) accounts"
        return said + ", count: " + notify.badgeMode.title
    }

    private var readingDetail: String {
        let sorted = MailSense.ready ? "Sorted by Apple Intelligence" : "Sorted by rules"
        return sorted + (pixels ? ", tracking pixels blocked" : "")
    }

    private var writingDetail: String {
        let undoing = "Undo send for \([5, 10, 20].contains(undo) ? undo : 5)s"
        return ai && ahead ? "Replies written ahead, " + undoing.lowercased() : undoing
    }

    private var calendarDetail: String {
        let length = self.length < 60 ? "\(self.length) min" : self.length == 60 ? "1 hour" : "1.5 hours"
        return "Free slots \(Self.time(start)) to \(Self.time(end)), \(length)"
    }

    private var agentsDetail: String {
        agentsWork ? "Read and draft mail. Sending requires approval." : "Off"
    }

    private var blockedDetail: String {
        let count = MailBlockedList.blocked(center).count
        return count == 1 ? "1 sender" : "\(count) senders"
    }

    private var ai: Bool { agents.writes }

    /// "9:00", as the Calendar page says its times.
    static func time(_ minutes: Int) -> String { String(format: "%d:%02d", minutes / 60, minutes % 60) }

    /// The face found for an account when it was connected.
    static func photo(_ account: String) -> URL? {
        Store.settings.string(forKey: "mail.photo.\(account)").flatMap(URL.init(string:))
    }

    /// The space it was signed in in, for Sign In Again to go back to.
    static func space(_ account: String) -> UUID? {
        Store.settings.string(forKey: "mail.space.\(account)").flatMap(UUID.init(uuidString:))
    }

    /// Its face and space kept as they were found, before Connect.
    static func remember(_ found: MailFound.Account) {
        Store.settings.set(found.photo?.absoluteString, forKey: "mail.photo.\(found.email)")
        Store.settings.set(found.space.uuidString, forKey: "mail.space.\(found.email)")
    }
}

/// A page further in from Settings › Mail: its hero and its groups, off
/// with the rest while mail is.
struct MailSettingsPage: View {
    let page: SettingsPage
    @Bindable var prefs: Preferences
    var model: SettingsModel

    var body: some View {
        PageHero(page: page)
        Group {
            switch page {
            case .mailInbox:
                MailSortSettings()
                MailKindSettings()
                MailSplitSettings()
            case .mailNotify:
                MailNotifySettings()
                MailCountSettings()
            case .mailReading: MailReadingSettings(model: model, prefs: prefs)
            case .mailWriting: MailWritingSettings(model: model)
            case .mailCalendar: MailCalendarSettings()
            case .mailAgents: MailAgentSettings()
            case .mailBlocked: MailBlockedList()
            default: EmptyView()
            }
        }
        .disabled(!prefs.usesMail)
    }
}

/// Settings › Mail › Reading: how mail is sorted, summed up and shown.
private struct MailReadingSettings: View {
    var model: SettingsModel
    @Bindable var prefs: Preferences
    private var agents = AgentSetupModel.shared
    @AppStorage("mail.summaries", store: Store.settings) private var summaries = false
    @AppStorage("mail.sense", store: Store.settings) private var sense = true
    @AppStorage("mail.pixels", store: Store.settings) private var pixels = true
    @AppStorage("mail.pdf.yab", store: Store.settings) private var pdfs = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Section {
            SettingsRow("Sort and sum up on this Mac", detail: senseDetail) {
                Toggle(SettingsWords.text("Sort and sum up on this Mac"), isOn: $sense)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .settingsAnchor("mail-sense")
            SettingsRow("Split summaries", detail: summariesDetail) {
                if ai {
                    Toggle(SettingsWords.text("Split summaries"), isOn: $summaries)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                } else {
                    Button("Connect…") { model.go(.ai) }.settingsButton()
                }
            }
            .settingsAnchor("mail-summaries")
            SettingsRow("Block tracking pixels", detail: "Block images that report when you open mail.") {
                Toggle(SettingsWords.text("Block tracking pixels"), isOn: $pixels)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .settingsAnchor("mail-pixels")
            SettingsRow("Open PDFs from Mail in Yab", detail: "Press Return to open a PDF in a tab for filling and signing.") {
                Toggle(SettingsWords.text("Open PDFs from Mail in Yab"), isOn: $pdfs)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .settingsAnchor("mail-pdf-yab")
            SettingsRow("Animations", detail: motionDetail) {
                Toggle("Animations", isOn: $prefs.mailAnimations)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .settingsAnchor("mail-motion")
        }
        .task { await agents.look() }
    }

    private var ai: Bool { agents.writes }

    private var senseDetail: String {
        guard MailSense.ready else {
            return "Using rules. Enable Apple Intelligence in System Settings for local mail summaries."
        }
        return "Sort and summarize new mail with Apple Intelligence on this Mac."
    }

    /// What moves, and, where the Mac's Reduce Motion holds mail still
    /// anyway, that the switch can't change it.
    private var motionDetail: String {
        if reduceMotion { return "Disabled by this Mac's Reduce Motion setting." }
        return "Animate opening and sending mail."
    }

    private var summariesDetail: String {
        guard ai else { return "Needs Claude or ChatGPT." }
        return "Summarize splits with \(agents.writer) using your subscription. Sends names, subjects and opening lines."
    }
}

/// Settings › Mail › Writing: replies written ahead, Undo send, read
/// statuses and each address's signature.
private struct MailWritingSettings: View {
    var model: SettingsModel
    private var center = MailCenter.shared
    private var agents = AgentSetupModel.shared
    @AppStorage("mail.ahead", store: Store.settings) private var ahead = false
    @AppStorage("mail.undo", store: Store.settings) private var undo = 5
    @AppStorage("mail.signature.replies", store: Store.settings) private var signsReplies = true

    var body: some View {
        Section {
            SettingsRow("Write replies ahead", detail: aheadDetail) {
                if ai {
                    Toggle(SettingsWords.text("Write replies ahead"), isOn: $ahead)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                } else {
                    Button("Connect…") { model.go(.ai) }.settingsButton()
                }
            }
            .settingsAnchor("mail-ahead")
            .onChange(of: ahead) { MailConsent.answered() }
            SettingsRow("Undo send", detail: "Delay sending to allow time to undo.") {
                GlassTrack(title: "Undo send", options: [("5s", 5), ("10s", 10), ("20s", 20)], selection: Binding(
                    get: { [5, 10, 20].contains(undo) ? undo : 5 },
                    set: { undo = $0 }
                ))
                .frame(width: 160)
            }
            .settingsAnchor("mail-undo")
            MailReadsSettings()
        }
        .task { await agents.look() }
        // Once Gmail has said what the accounts send as (MailSendAs).
        if center.accounts.contains(where: { !(center.engines[$0]?.store.sendAs().isEmpty ?? true) }) {
            Section("Signatures") {
                SettingsRow("Signature in replies and forwards", detail: "New messages always include a signature. Choose whether replies and forwards do too.") {
                    Toggle(SettingsWords.text("Signature in replies and forwards"), isOn: $signsReplies)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                .settingsAnchor("mail-signature-replies")
                MailSignatures()
            }
        }
    }

    private var ai: Bool { agents.writes }

    private var aheadDetail: String {
        guard ai else { return "Needs Claude or ChatGPT." }
        return "Draft three replies with \(agents.writer) using your subscription and past writing. Mail access is read-only."
    }
}

/// Settings › Mail › Agents: whether the AI connected may read mail (the
/// person's consent, MailConsent, each use on its own switch, all off until
/// turned on), the mail they may search, and the people pages kept from it.
private struct MailAgentSettings: View {
    @AppStorage(MailConsent.agentsKey, store: Store.settings) private var agentsWork = false
    @AppStorage(MailConsent.aheadKey, store: Store.settings) private var ahead = false
    @AppStorage(MailConsent.othersKey, store: Store.settings) private var others = false
    @AppStorage(MailPeople.key, store: Store.settings) private var people = true
    private var agents = AgentSetupModel.shared

    var body: some View {
        Section {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) { // design: SettingsRow's own gap
                    Text("Mail you hand to \(agents.writer)")
                    VStack(alignment: .leading, spacing: 3) { // design: SettingsRow's own gap
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            // A size under the words: at theirs the plate stood taller than the line.
                            KeyGlyphs(keys: "D", size: 11, tint: nil, rest: 0.6)
                            Text("on a mail or")
                            KeyGlyphs(keys: "⌘J", size: 11, tint: nil, rest: 0.6)
                            Text("in Mail")
                        }
                        Text(handDetail)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Toggle("Mail you hand to \(agents.writer)", isOn: $agentsWork)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .settingsAnchor("mail-agents")
            SettingsRow("Replies written ahead", detail: MailConsent.aheadDetail(agents.writer)) {
                Toggle(SettingsWords.text("Replies written ahead"), isOn: $ahead)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .settingsAnchor("mail-ahead-consent")
            SettingsRow("Mail tools in other apps", detail: "Allow connected MCP clients to read and organize mail with the same approval rules as Yab agents.") {
                Toggle(SettingsWords.text("Mail tools in other apps"), isOn: $others)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .disabled(!agentsWork)
            .settingsAnchor("mail-agents-others")
            MailMemoryRow(agentsOn: agentsWork)
                .settingsAnchor("mail-memory")
            SettingsRow("People in memory", detail: "Update notes about frequent contacts daily. Stored on this Mac in memory/people.") {
                Toggle(SettingsWords.text("People in memory"), isOn: $people)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .settingsAnchor("mail-people")
        } footer: {
            SettingsNote(MailConsent.terms(agents.writer))
        }
        .onChange(of: agentsWork) { MailConsent.answered() }
        .onChange(of: ahead) { MailConsent.answered() }
        .task { await agents.look() }
    }

    /// What D does, said after its key.
    private var handDetail: String {
        "\(agents.writer) reads it on your plan. A task asks once before it searches your mail, and before it changes or sends anything."
    }
}

/// Show in All Accounts (MailAllAccounts), a switch an account: on until
/// turned off; the last one left in can't be.
private struct MailAllAccountsSettings: View {
    private var center = MailCenter.shared

    var body: some View {
        Section {
            ForEach(center.accounts, id: \.self) { account in
                SettingsRow(verbatim: account) {
                    Toggle(SettingsWords.text("Show in All Accounts"), isOn: Binding(get: { !center.apart.contains(account) },
                                                                 set: { center.setInAll(account, $0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(!center.apart.contains(account)
                                  && !MailAllAccounts.canLeave(account, accounts: center.accounts, apart: center.apart))
                }
                // The search finds the first; each row keeps an id of its own.
                .settingsAnchor(account == center.accounts.first ? "mail-all-accounts" : "mail-all-accounts-" + account)
            }
        } header: {
            Text(SettingsWords.text("Show in All Accounts"))
        } footer: {
            SettingsNote("Disabled accounts keep their inbox and remain searchable, but are excluded from All Accounts and combined counts.")
        }
    }
}

/// The one number the mail pin, mail's door and the Dock show.
private struct MailCountSettings: View {
    private var notify = MailNotify.shared

    var body: some View {
        Section {
            SettingsRow("Count", detail: "Choose the count shown on Mail and the Dock.") {
                DropMenu("Count", options: MailNotify.Badge.allCases.map { (title: $0.title, value: $0) },
                         selection: Binding(get: { notify.badgeMode }, set: { notify.setBadge($0) }))
                    .fixedSize()
            }
            .settingsAnchor("mail-badge")
        }
    }
}

/// Settings › Mail › Inbox: what needs you, how far back the lists look,
/// what becomes of ads and promos, and cold pitches. All of it on this
/// Mac: Gmail's inbox is left as it is unless ads are set to be archived
/// there too.
private struct MailSortSettings: View {
    private var list = MailList.shared
    @AppStorage(MailOffers.declinesKey, store: Store.settings) private var declines = false

    var body: some View {
        Section {
            SettingsRow("What needs you", detail: "Show requests, deadlines and unanswered threads. Other mail appears in Other.") {
                DropMenu("What needs you", options: [("Asks you something", true), ("Everything from people", false)],
                         selection: Binding(get: { list.policy.asks }, set: { list.policy.asks = $0 }))
                    .fixedSize()
            }
            .settingsAnchor("mail-needs")
            SettingsRow("How far back", detail: "Older mail appears in Archive without counts or alerts. Gmail's inbox is unchanged.") {
                DropMenu("How far back", options: [("The last week", 7), ("The last month", 30), ("Every age", 0)],
                         selection: Binding(get: { list.policy.days ?? 0 }, set: { list.policy.days = $0 > 0 ? $0 : nil }))
                    .fixedSize()
            }
            .settingsAnchor("mail-window")
            SettingsRow("Ads and promos", detail: "Gmail Promotions and Social. Excludes your domain, threads you replied to and starred mail.") {
                DropMenu("Ads and promos", options: [("Hide here", "only"), ("Keep in Other", "off"), ("Archive in Gmail too", "skip")],
                         selection: Binding(get: { adsMode }, set: { list.setMode($0, for: MailSplits.ads) }))
                    .fixedSize()
            }
            .settingsAnchor("mail-ads")
            SettingsRow("Cold pitches", detail: "Draft rejections for unsolicited sales mail. Press \u{2318}\u{21A9} on a No ready row to send.") {
                Toggle("No ready in the list", isOn: Binding(get: { declines }, set: { declines = $0; MailDesk.shared.load() }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .settingsAnchor("mail-pitches")
        } header: {
            Text(SettingsWords.text("What needs you"))
        }
    }

    /// Where Ads and promos' mail goes, as its row says it.
    private var adsMode: String {
        guard let ads = list.ordered.first(where: { $0.id == MailSplits.ads }), ads.on else { return "off" }
        return ads.mode == .skip ? "skip" : "only"
    }
}

/// Read statuses (MailReads), an account each, off until turned on (kept in
/// its store, as `yab mail flush` sends too): how they work, under the
/// first, and that the picture can send mail to spam.
private struct MailReadsSettings: View {
    private var center = MailCenter.shared

    static let detail = "Your mail ends with an invisible picture from Yab’s site, which notes when it loads. Addresses and words never leave this Mac.\n"
        + "Mail with such a picture lands in spam more often: if yours stops arriving, turn this off."

    var body: some View {
        ForEach(center.accounts, id: \.self) { account in
            if let store = center.engines[account]?.store {
                SettingsRow(center.accounts.count > 1 ? "Read statuses for " + account : "Read statuses",
                            detail: account == center.accounts.first ? MailReadsSettings.detail : "") {
                    Toggle(SettingsWords.text("Read statuses"), isOn: Binding(get: { MailReads.on(store) }, set: { on in
                        MailReads.set(on, in: store)
                        center.touch()
                    }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
                // The search finds the first; each row keeps an id of its own.
                .settingsAnchor(account == center.accounts.first ? "mail-reads" : "mail-reads-" + account)
            }
        }
    }
}

/// Each address's signature, as a mail from it carries it: Gmail's, or one
/// written here (kept in the account's store, `signatures`; Gmail's own
/// stays as it is). Edit… opens it to write in, with a mail's marks; Use
/// Gmail's there takes yours away.
private struct MailSignatures: View {
    private var center = MailCenter.shared
    @State private var editing: Editing?

    struct Editing: Identifiable {
        let account: String
        let address: String
        var id: String { account + "|" + address }
    }

    private struct Row: Identifiable {
        let account: String
        let sender: MailSendAs
        let html: String
        let own: Bool
        var id: String { account + "|" + sender.address }
    }

    var body: some View {
        let rows = center.accounts.flatMap { account -> [Row] in
            guard let store = center.engines[account]?.store else { return [] }
            return store.sendAs().map { sender in
                let own = store.ownSignature(for: sender.address)
                return Row(account: account, sender: sender, html: own ?? sender.signature, own: own != nil)
            }
        }
        ForEach(rows) { row in
            SettingsRow(rows.count == 1 ? "Signature" : row.sender.address, detail: detail(row)) {
                Button("Edit…") { editing = Editing(account: row.account, address: row.sender.address) }
                    .settingsButton()
            }
            .settingsAnchor("mail-signature:" + row.sender.address)
        }
        .sheet(item: $editing) { one in
            MailSignatureEditor(account: one.account, address: one.address)
        }
    }

    /// Its words on a line, and whose it is.
    private func detail(_ row: Row) -> String {
        let words = MailSignature(html: row.html).shown.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " · ")
        if words.isEmpty { return row.own ? "None, written here" : "None in Gmail" }
        return (row.own ? "Written here: " : "From Gmail: ") + words
    }
}

/// One address's signature to write in, with a mail's marks: bold, italic,
/// underline, lists, a link pasted over words (MailWords, its keys its
/// own here). Save keeps it in the account's store; Use Gmail's takes it away.
private struct MailSignatureEditor: View {
    let account: String
    let address: String
    @State private var words: (body: String, html: String) = ("", "")
    @State private var own = false
    @State private var focus = 0
    @Environment(\.dismiss) private var dismiss

    private var store: MailStore? { MailCenter.shared.engines[account]?.store }
    private static let box = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Signature").font(.system(size: 15, weight: .semibold))
                Text("Signature for " + address + ". Your Gmail signature is unchanged.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ThreadScrollView(.vertical) {
                MailWords(body: words.body, html: words.html, changed: { body, html in words = (body, html) },
                          focus: focus, toFirst: false, live: false)
                    .padding(8)
            }
            .frame(height: 160)
            .background(Color.primary.opacity(0.04), in: MailSignatureEditor.box)
            .overlay(MailSignatureEditor.box.strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
            HStack(spacing: 8) {
                if own {
                    Button("Use Gmail\u{2019}s") {
                        store?.setSignature(nil, for: address)
                        MailCenter.shared.touch()
                        dismiss()
                    }
                    .buttonStyle(.yab(.quiet, .regular))
                }
                Spacer()
                Button(SettingsWords.text("Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.yab(.secondary, .regular))
                Button(SettingsWords.text("Save")) {
                    // Kept as HTML either way: plain words made so.
                    let html = words.html.isEmpty ? MailRich.html(MailRich.trimmed(MailRich.plain(words.body))) : words.html
                    store?.setSignature(html, for: address)
                    MailCenter.shared.touch()
                    dismiss()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.yab(.primary, .regular))
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear {
            guard let store else { return }
            let mine = store.ownSignature(for: address)
            own = mine != nil
            words = ("", mine ?? store.signature(for: address))
            focus += 1
        }
    }
}

/// Free slots and the booking link (docs/mail.md, Calendar): the hours
/// ⇧⌘A finds free time in, how long a slot is, and a Calendly or Cal.com
/// page said after the slots.
private struct MailCalendarSettings: View {
    @AppStorage("mail.slots.start", store: Store.settings) private var start = 9 * 60
    @AppStorage("mail.slots.end", store: Store.settings) private var end = 18 * 60
    @AppStorage("mail.slots.length", store: Store.settings) private var length = 30
    @AppStorage("mail.booking", store: Store.settings) private var booking = ""
    private var slot = Keymap.shared.slot(.mailSlots)

    /// Every half hour of the day, as mail says its times.
    private static let times: [(title: String, value: Int)] = stride(from: 0, through: 24 * 60, by: 30).map { minutes in
        (String(format: "%d:%02d", minutes / 60, minutes % 60), minutes)
    }

    var body: some View {
        Section {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) { // design: SettingsRow's own gap
                    Text("Working hours")
                    SettingsText((slot.keys.map { $0.settingsHint + " " } ?? "") + "in a message inserts available calendar times during these working hours.")
                        .fixedSize(horizontal: false, vertical: true)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    DropMenu("From", options: Self.times.dropLast().map { (title: $0.title, value: $0.value) },
                             selection: Binding(get: { start }, set: { start = min($0, end - 30) }))
                        .fixedSize()
                    Text("to").foregroundStyle(.secondary)
                    DropMenu("To", options: Self.times.dropFirst().map { (title: $0.title, value: $0.value) },
                             selection: Binding(get: { end }, set: { end = max($0, start + 30) }))
                        .fixedSize()
                }
            }
            .settingsAnchor("mail-hours")
            SettingsRow("Slot length") {
                DropMenu("Slot length", options: MailSlots.lengths.map { minutes in
                    (title: minutes < 60 ? "\(minutes) min" : minutes == 60 ? "1 hour" : "1.5 hours", value: minutes)
                }, selection: $length)
                    .fixedSize()
            }
            .settingsAnchor("mail-slot-length")
            SettingsRow("Booking link", detail: "Add a scheduling link after your available times.") {
                TextField(SettingsWords.text("Booking link"), text: $booking, prompt: Text("https://cal.com/you"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .autocorrectionDisabled()
                    .frame(width: 220)
            }
            .settingsAnchor("mail-booking")
        }
    }
}

/// The senders kept out on this Mac (Block Sender, docs/mail.md Cleanup),
/// each account's: an address, or a domain and every one under it, since
/// when, Unblock on a right click, as the other tables of Settings take
/// theirs away. Only while there is one.
private struct MailBlockedList: View {
    private var center = MailCenter.shared

    /// "Oct 1", as mail says its days.
    static let day: DateFormatter = {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "MMM d"
        return format
    }()

    private struct Blocked: Identifiable {
        let account: String
        let who: String
        let at: Date
        var id: String { account + "|" + who }
    }

    /// Everyone blocked, in every account.
    static func blocked(_ center: MailCenter) -> [(account: String, who: String, at: Date)] {
        center.accounts.flatMap { account in
            (center.engines[account]?.store.blocked() ?? []).map { (account, $0.who, $0.at) }
        }
    }

    var body: some View {
        let blocked = Self.blocked(center).map { Blocked(account: $0.account, who: $0.who, at: $0.at) }
        if !blocked.isEmpty {
            Section {
                ForEach(blocked) { one in
                    HStack(spacing: 12) {
                        HStack(spacing: 8) {
                            HostMark(host: one.who.split(separator: "@").last.map(String.init) ?? one.who)
                            Text(one.who)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if center.accounts.count > 1 {
                                Text("in " + one.account)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text("since " + MailBlockedList.day.string(from: one.at))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                    .contextMenu {
                        Button("Unblock") {
                            center.engines[one.account]?.store.unblock(one.who)
                            center.touch()
                        }
                    }
                    .settingsAnchor("mail-blocked:" + one.who)
                }
            } footer: {
                SettingsNote("New mail from these senders goes to Trash on this Mac. Gmail filters are unchanged. Right-click to unblock.")
            }
        }
    }
}

/// An account across the table: its face, its address, and under them how
/// much of it is here, or what went wrong and the way out.
private struct MailAccountRow: View {
    var browser: Browser
    let account: String
    private var center = MailCenter.shared
    @State private var size: (threads: Int, bytes: Int64)?
    @State private var fixing = false
    private var imap: Bool { MailCenter.kind(of: account) == .imap }

    var body: some View {
        let status = center.status[account]
        HStack(spacing: 12) {
            MailFace(email: account, photo: MailSettings.photo(account), side: 28)
            VStack(alignment: .leading, spacing: 3) { // design: SettingsRow's own gap
                Text(account).lineLimit(1).truncationMode(.middle)
                Text(detail(status))
                    .font(.callout)
                    .foregroundStyle(status?.trouble != nil && status?.resting != true ? AnyShapeStyle(ButtonCSS.danger) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if imap, status?.signedOut == true || status?.trouble != nil && status?.resting != true {
                // The password the server stopped taking, or servers to look at again.
                Button("Fix…") { fixing = true }
                    .settingsButton()
            } else if imap {
                EmptyView()
            } else if status?.signedOut == true {
                Button("Sign In Again") {
                    Task {
                        guard await MailClient.warnFirst(place: .settings) else { return }
                        center.connect(in: browser, hint: account, space: MailSettings.space(account), fromSettings: true, expectedAccount: account)
                        Links.window?.makeKeyAndOrderFront(nil)
                    }
                }
                    .settingsButton()
                    .disabled(center.connecting)
            } else if MailClient.listsCalendars, !Store.settings.bool(forKey: MeetingsGoogle.listKey(account)) {
                // Connected before the calendar list was asked for: its
                // primary alone until Google is asked again, at a press.
                Button("Show All Calendars") {
                    Task {
                        guard await MailClient.warnFirst(place: .settings) else { return }
                        center.connect(in: browser, hint: account, space: MailSettings.space(account), fromSettings: true, expectedAccount: account)
                        Links.window?.makeKeyAndOrderFront(nil)
                    }
                }
                    .settingsButton()
                    .disabled(center.connecting)
            }
        }
        .contentShape(Rectangle())
        .settingsContextMenu {
            var entries: [SettingsMenuEntry] = []
            if center.accounts.count > 1 {
                // MailAllAccountsMenu's one row, for this account.
                let inAll = !center.apart.contains(account)
                entries.append(.toggle("Show in All Accounts", on: inAll,
                                       enabled: !inAll || MailAllAccounts.canLeave(account, accounts: center.accounts, apart: center.apart)) {
                    center.setInAll(account, !inAll)
                })
            }
            entries.append(.destructive("Disconnect \(account)…") { disconnect() })
            return entries
        }
        .task(id: center.status[account]?.synced) { await measure() }
        .sheet(isPresented: $fixing) {
            MailOtherAccountSheet(browser: browser, start: account,
                                  provider: MailServerSetup.kept(account, in: Store.settings)?.provider == "gmail" ? "gmail" : nil)
        }
    }

    /// "iCloud · app password", for an account that isn't Gmail.
    private var kindLine: String? {
        guard imap, let setup = MailServerSetup.kept(account, in: Store.settings) else { return nil }
        let known = MailKnownProviders.by(id: setup.provider)
        let name = known?.name ?? setup.imapHost
        return known?.appPassword == true ? name + " \u{00B7} app password" : name + " \u{00B7} IMAP"
    }

    private func detail(_ status: MailCenter.Status?) -> String {
        if let trouble = status?.trouble { return trouble }
        if status?.synced == nil { return "Reading your mail, newest first" }
        guard let size, size.threads > 0 else { return kindLine ?? "On this Mac" }
        let bytes = ByteCountFormatter.string(fromByteCount: size.bytes, countStyle: .file)
        let here = "\(size.threads.formatted()) \(size.threads == 1 ? "thread" : "threads"), \(bytes) on this Mac"
        return kindLine.map { $0 + ", " + here.prefix(1).lowercased() + here.dropFirst() } ?? here
    }

    /// Threads counted and the store's files weighed, the files mail
    /// carries kept with them, off the main thread.
    private func measure() async {
        guard let store = center.engines[account]?.store else { return }
        let file = store.file
        size = await Task.detached(priority: .utility) {
            let bytes = ["", "-wal"].reduce(Int64(0)) { sum, suffix in
                sum + ((try? FileManager.default.attributesOfItem(atPath: file.path + suffix)[.size] as? Int64) ?? 0)
            }
            return (store.threadCount(), bytes + (MailFiles.folder(for: store).map(MailFiles.weight(of:)) ?? 0))
        }.value
    }

    private func disconnect() {
        Task {
            let yes = await Questions.shared.ask(Question(
                title: "Disconnect \(account)?",
                detail: imap ? "Yab forgets its password and deletes this account’s mail from this Mac. The server keeps all of it."
                    : "Yab gives back its access at Google and deletes this account’s mail from this Mac. Gmail keeps all of it.",
                glyph: "envelope", yes: "Disconnect", danger: true, place: .settings))
            if yes { center.disconnect(account) }
        }
    }
}

/// An Outlook or Microsoft 365 account, connected for its calendar alone.
private struct OutlookAccountRow: View {
    var browser: Browser
    let account: String
    private var outlook = OutlookCalendars.shared

    var body: some View {
        let out = outlook.signedOut.contains(account)
        HStack(spacing: 12) {
            MailFace(email: account, photo: nil, side: 28)
            VStack(alignment: .leading, spacing: 3) { // design: SettingsRow's own gap
                Text(account).lineLimit(1).truncationMode(.middle)
                Text(out ? "Microsoft stopped letting Yab in" : "Outlook calendar, read only")
                    .font(.callout)
                    .foregroundStyle(out ? AnyShapeStyle(ButtonCSS.danger) : AnyShapeStyle(.secondary))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if out {
                Button("Sign In Again") {
                    outlook.connect(in: browser, hint: account)
                    Links.window?.makeKeyAndOrderFront(nil)
                }
                .settingsButton()
                .disabled(outlook.connecting)
            }
        }
        .contentShape(Rectangle())
        .settingsContextMenu { [.destructive("Disconnect \(account)…") { disconnect() }] }
    }

    private func disconnect() {
        Task {
            let yes = await Questions.shared.ask(Question(
                title: "Disconnect \(account)?",
                detail: "Yab forgets this account’s sign-in, and its meetings leave your tabs. Outlook keeps all of it.",
                glyph: "calendar", yes: "Disconnect", danger: true, place: .settings))
            if yes { outlook.disconnect(account) }
        }
    }
}

/// Where the next account comes from, under the last: the ones signed in
/// in Yab's spaces, or another, signed in to in a tab. While Google is
/// asked, the row says so and can be called off.
private struct MailAddAccount: View {
    var browser: Browser
    private var center = MailCenter.shared
    private var found = MailFound.shared
    private var outlook = OutlookCalendars.shared
    @State private var hovering = false
    /// Add a Mail Account's sheet, on the address it starts with: "@icloud.com" for iCloud….
    @State private var other: MailSheetStart?
    @AppStorage(MailExperiment.key, store: Store.settings) private var mailOn = false

    var body: some View {
        if center.connecting {
            SettingsRow("Waiting for Google", detail: "Allow Yab in the tab it opened.") {
                Button(SettingsWords.text("Cancel")) { center.cancelConnect(in: browser) }.settingsButton(.quiet)
            }
        } else if outlook.connecting {
            SettingsRow("Waiting for Microsoft", detail: "Allow Yab in the tab it opened.") {
                Button(SettingsWords.text("Cancel")) { outlook.cancel(in: browser) }.settingsButton(.quiet)
            }
        } else {
            Menu {
                ForEach(found.accounts) { account in
                    Button(account.email) { connect(account) }
                }
                if !found.accounts.isEmpty { Divider() }
                // Each way in wears where it goes.
                Button { connect(nil) } label: {
                    Label { Text(found.accounts.isEmpty ? "Google Account…" : "Another Google Account…") } icon: { MailMenuMark.image("google.com") }
                }
                // iCloud, Zoho, Yahoo and the rest by IMAP (Settings › Experimental).
                if mailOn {
                    Button { other = MailSheetStart(address: "@icloud.com") } label: {
                        Label { Text("iCloud…") } icon: { MailMenuMark.image("icloud.com") }
                    }
                    Button { other = MailSheetStart(address: "") } label: {
                        Label { Text("Zoho, Yahoo and Other Mail…") } icon: { Image(systemName: "at") }
                    }
                }
                // Its calendar alone, read only: Outlook's mail stays in Outlook.
                if outlook.available {
                    Divider()
                    Button {
                        outlook.connect(in: browser)
                        Links.window?.makeKeyAndOrderFront(nil)
                    } label: {
                        Label { Text("Outlook Calendar…") } icon: { MailMenuMark.image("outlook.com") }
                    }
                }
            } label: {
                // As wide as its words, as Add Extension is: muted until the
                // hand is on it.
                HStack(spacing: 8) {
                    Symbol("plus", size: 11, weight: .semibold)
                        .frame(width: 28)
                    Text("Add Account")
                }
                .foregroundStyle(hovering ? Palette.ink : Palette.muted)
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(PressStyle(scale: ButtonSize.regular.pressed))
            .menuIndicator(.hidden)
            .fixedSize()
            .onHover { hovering = $0 }
            .frame(maxWidth: .infinity, alignment: .leading)
            .task {
                MailMenuMark.fetch()
                await found.look(browser)
            }
            .sheet(item: $other) { MailOtherAccountSheet(browser: browser, start: $0.address, provider: $0.provider) }
            .modifier(MailSheetOpened(asked: $other))
        }
    }

    private func connect(_ account: MailFound.Account?) {
        if let account { MailSettings.remember(account) }
        other = MailSheetStart(address: account?.email ?? "@gmail.com", provider: "gmail")
    }
}

/// Settings › Autofill's One-time codes: where the codes offered under a
/// box that asks for one come from, beside the cards and forms they fill
/// with. Each is on by itself only where it needs nothing more from you:
/// mail once Mail is connected, texts where Messages can already be read.
/// Full Disk Access is never asked for on the way; Allow… opens the place
/// to give it only once texts were turned on.
struct OneTimeCodes: View {
    @Bindable var prefs: Preferences
    private var center = MailCenter.shared
    @AppStorage("mail.codes.archive", store: Store.settings) private var archive = false
    /// Whether Messages can be read now; nil until looked.
    @State private var readable: Bool?

    var body: some View {
        Section("One-time codes") {
            SettingsRow("From your mail", detail: center.connected
                        ? "Gmail, through Mail: a code that lands after you click the box shows in seconds."
                        : "Unread Gmail, read with the tab’s own sign-in the moment a site asks. On by itself once Mail is connected.") {
                Toggle("From your mail", isOn: $prefs.mailCodes)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .settingsAnchor("codes-mail")
            SettingsRow("From Messages", detail: textsDetail) {
                HStack(spacing: 12) {
                    if readable == false, prefs.textCodes {
                        Button("Allow…") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .settingsButton()
                    }
                    Toggle("From Messages", isOn: $prefs.textCodes)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            }
            .settingsAnchor("codes-texts")
            .task { await look() }
            // Back from System Settings with the access given.
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await look() }
            }
            if center.connected {
                SettingsRow("Archive code mails after use", detail: "Archive verification mail after filling its code.") {
                    Toggle(SettingsWords.text("Archive code mails after use"), isOn: $archive)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(!prefs.mailCodes)
                }
                .settingsAnchor("codes-archive")
            }
            SettingsNote("Verification codes appear below the field. Press Return to fill one. Codes stay on this Mac and are never filled automatically.")
        }
    }

    private var textsDetail: String {
        switch (readable, prefs.textCodes) {
        case (false, true): return "Yab can’t read Messages yet. Give it Full Disk Access, and texted codes show too."
        case (false, false): return "Texted codes, from Messages on this Mac. They need Full Disk Access, which Yab doesn’t have."
        default: return "Texted codes, read from Messages on this Mac while a box asks for one."
        }
    }

    /// Messages opened once, off the main thread, to know whether it can be.
    private func look() async {
        let can = await Task.detached(priority: .utility) { MailCodes.canReadTexts() }.value
        MailCodes.textsReadable = can
        readable = can
    }
}
