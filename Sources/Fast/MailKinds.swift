import SwiftUI

// Sorting (docs/mail.md, Splits): the kinds of mail this Mac reads
// (MailSense) in one table, each with how many threads came in the last
// month, where it goes, and whether Gmail gets it as a label. Where it goes
// is the splits' own rules gathered by kind, not a system beside them: a
// split of that kind alone takes it (Only here), or skips the inbox with
// it; without one, the inbox's lists place it, Needs you or Other as
// Settings says for that kind (MailSplit.Policy.kinds) or as it asks.

enum MailKinds {
    /// The kinds labeled in Gmail, by Label in Gmail's switches.
    static var labeled: Set<MailSensed.Kind> {
        Set((Store.settings.stringArray(forKey: MailKindLabels.key) ?? []).compactMap(MailSensed.Kind.init(rawValue:)))
    }

    /// A kind's mail goes to the lists as it asks when nothing says
    /// otherwise: a bill and an invitation may need you, the rest is Other.
    static func asks(_ kind: MailSensed.Kind) -> Bool { kind == .invoice || kind == .meeting }

    /// The splits that gather a kind and nothing else: Receipts for bills,
    /// Calendar for invitations, one made here for the rest. Hidden ones
    /// (Ads and promos) aren't among them.
    static func splits(of kind: MailSensed.Kind, in splits: [MailList.Split]) -> [MailList.Split] {
        splits.filter { split in
            let rules = split.rules
            return !split.hidden && !rules.isEmpty && rules.allSatisfy { $0.kind == "kind" }
                && rules.contains { $0.value.lowercased() == kind.rawValue }
        }
    }

    /// Where a kind goes, as its row's menu says it: "skip", "split:<id>"
    /// (the first split in the column's order that takes it), "needs",
    /// "other", or "auto" (as it asks, or Other for kinds that never ask).
    static func goes(_ kind: MailSensed.Kind, splits ordered: [MailList.Split], policy: MailSplit.Policy) -> String {
        if let taking = splits(of: kind, in: ordered).first(where: { $0.on && $0.mode != .also }) {
            return taking.mode == .skip ? "skip" : "split:" + taking.id
        }
        switch policy.place(kind) {
        case .needs?: return "needs"
        case .other?: return asks(kind) ? "other" : "auto"
        default: return "auto"
        }
    }

    /// Its menu: the lists, its splits (or one to make), Skip the inbox.
    static func choices(_ kind: MailSensed.Kind, splits ordered: [MailList.Split]) -> [(title: String, value: String)] {
        var out: [(String, String)] = asks(kind)
            ? [("Needs you if it asks", "auto"), ("Needs you", "needs"), ("Other", "other")]
            : [("Other", "auto"), ("Needs you", "needs")]
        let own = splits(of: kind, in: ordered)
        out += own.map { ($0.title, "split:" + $0.id) }
        if own.isEmpty { out.append(("New Split", "new")) }
        out.append(("Skip the inbox", "skip"))
        return out
    }

    /// A split of a kind's own, as New Split in its menu makes it: the
    /// kind's name, its mail only there.
    static func made(_ kind: MailSensed.Kind) -> MailList.Split {
        let q = MailRule.line([MailRule(kind: "kind", value: kind.rawValue)])
        return MailList.Split(title: MailKindLabels.name(kind), q: q, icon: icon(kind), mode: .only)
    }

    static func icon(_ kind: MailSensed.Kind) -> String {
        switch kind {
        case .invoice: return "creditcard"
        case .meeting: return "calendar"
        case .shipping: return "shippingbox"
        case .code: return "number"
        case .list: return "newspaper"
        case .promotion: return "megaphone"
        default: return "tray"
        }
    }

    /// A kind sent somewhere from its row. To a list: the splits that
    /// took it show it beside the lists instead (Also in Needs you), kept
    /// in the column. To a split: that one takes it. Skip the inbox: its
    /// split (made if there is none) skips the inbox from now on.
    @MainActor
    static func send(_ kind: MailSensed.Kind, to value: String, list: MailList) {
        var policy = list.policy
        let own = splits(of: kind, in: list.ordered)
        switch value {
        case "auto", "needs", "other":
            policy.kinds[kind.rawValue] = value == "auto" || (value == "other" && !asks(kind)) ? nil : value
            for split in own where split.on && split.mode != .also { list.setMode(MailList.Split.Mode.also.rawValue, for: split.id) }
        case "new":
            policy.kinds[kind.rawValue] = nil
            list.addSplit(made(kind))
        case "skip":
            policy.kinds[kind.rawValue] = nil
            let target = own.first(where: \.on) ?? own.first ?? made(kind)
            if own.isEmpty { list.addSplit(target) }
            list.setMode(MailList.Split.Mode.skip.rawValue, for: target.id)
        default:
            guard value.hasPrefix("split:") else { return }
            let id = String(value.dropFirst(6))
            policy.kinds[kind.rawValue] = nil
            // The one chosen takes it; another of its own that did steps aside.
            for split in own where split.id != id && split.on && split.mode != .also {
                list.setMode(MailList.Split.Mode.also.rawValue, for: split.id)
            }
            list.setMode(MailList.Split.Mode.only.rawValue, for: id)
        }
        if policy != list.policy { list.policy = policy }
    }

    /// Label in Gmail turned on or off for a kind: on, its month's
    /// threads labeled now; off, no more labeled, none taken off.
    @MainActor
    static func label(_ kind: MailSensed.Kind, _ on: Bool) {
        var kinds = labeled
        if on { kinds.insert(kind) } else { kinds.remove(kind) }
        Store.settings.set(MailKindLabels.kinds.filter(kinds.contains).map(\.rawValue), forKey: MailKindLabels.key)
        if on { MailCenter.shared.labelKinds() }
    }
}

/// Settings › Mail › Inbox's Sorting: a row a kind, in the tables'
/// language (TableCell, MenuCell, no headings): its name and the month's
/// number, where it goes, and its label in Gmail.
struct MailKindSettings: View {
    private var list = MailList.shared
    private var center = MailCenter.shared
    @State private var counts: [MailSensed.Kind: Int] = [:]
    @State private var labeled = MailKinds.labeled

    var body: some View {
        Section {
            ForEach(MailKindLabels.kinds, id: \.self) { kind in
                row(kind)
                    .settingsAnchor("mail-kind:" + kind.rawValue)
            }
        } header: {
            Text("Sorting")
                .settingsAnchor("mail-sorting")
        } footer: {
            SettingsNote("Mail categories and last month's counts. Splits move categories out of Needs you and Other. Label in Gmail adds matching yab/ labels. Turning it off keeps existing labels.")
        }
        .task(id: center.accounts) { await count() }
    }

    private func row(_ kind: MailSensed.Kind) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Text(MailKindLabels.name(kind))
                    .lineLimit(1)
                if let count = counts[kind] {
                    Text(count.formatted())
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            MenuCell(title: "Goes to", options: MailKinds.choices(kind, splits: list.ordered), selection: Binding(
                get: { MailKinds.goes(kind, splits: list.ordered, policy: list.policy) },
                set: { MailKinds.send(kind, to: $0, list: list) }
            ))
            Toggle("Label in Gmail", isOn: Binding(get: { labeled.contains(kind) }, set: { on in
                if on { labeled.insert(kind) } else { labeled.remove(kind) }
                MailKinds.label(kind, on)
            }))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .modifier(TableCell(width: TableCell.column))
        }
        .contentShape(Rectangle())
    }

    /// The month's threads of each kind, every account's, read off the
    /// main thread.
    private func count() async {
        let stores = center.engines.values.map(\.store)
        let found = await Task.detached(priority: .utility) {
            stores.reduce(into: [MailSensed.Kind: Int]()) { out, store in
                for (kind, n) in MailKindLabels.counts(store) { out[kind, default: 0] += n }
            }
        }.value
        counts = found
    }
}
