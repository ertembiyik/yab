import SwiftUI

/// The existing Memory question owns this review. Opening it is passive;
/// only its final enabled action revokes collection and changes storage.
@MainActor
@Observable final class MemoryClearReview {
    enum LegacyChoice: String, CaseIterable { case keep, remove, restore }
    enum SyncChoice: String { case keep, use }
    let privacy: ContextPrivacy
    let sync: ContextSyncReplay
    let enablement = Question.Enablement()
    private(set) var plan: ContextPrivacy.ClearPlan
    private(set) var syncItems: [ContextSyncReplay.Item]
    var legacyChoices: [String: LegacyChoice] = [:] { didSet { validate() } }
    var syncChoices: [String: SyncChoice] = [:] { didSet { validate() } }
    private(set) var message = ""
    @ObservationIgnored private(set) var result: ContextPrivacy.ClearResult?

    init(privacy: ContextPrivacy = .shared, sync: ContextSyncReplay? = nil) {
        self.privacy = privacy
        self.sync = sync ?? SyncCenter.shared.contextSyncReplay()
        plan = privacy.preview(); syncItems = self.sync.items()
        validate()
    }

    private func validate() {
        enablement.allowed = plan.issues.isEmpty
            && plan.legacy.allSatisfy { item in legacyChoices[item.id].map { $0 != .restore || item.restore != nil } == true }
            && syncItems.allSatisfy { item in syncChoices[item.id].map { $0 != .use || item.canUse } == true }
    }

    private func refresh(_ text: String) {
        let before = Dictionary(uniqueKeysWithValues: plan.legacy.map { ($0.id, $0) })
        let revisions = plan.revisions
        let versions = Dictionary(uniqueKeysWithValues: syncItems.map { ($0.id, $0) })
        plan = privacy.preview(); syncItems = sync.items(); message = text
        legacyChoices = legacyChoices.filter { key, _ in
            guard let next = plan.legacy.first(where: { $0.id == key }), let old = before[key] else { return false }
            return next.value == old.value && next.restore == old.restore && revisions[key] == plan.revisions[key]
        }
        syncChoices = syncChoices.filter { key, _ in
            guard let next = syncItems.first(where: { $0.id == key }), let old = versions[key] else { return false }
            return next.sameReview(as: old)
        }
        validate()
    }

    /// False keeps the same review shell for changed/unresolved data. A
    /// successful result always comes from checked storage commits.
    func perform() -> Bool {
        guard enablement.allowed else { return false }
        var used = false
        for item in syncItems {
            let use = syncChoices[item.id] == .use
            guard sync.resolve(item, use: use) else {
                refresh("A Sync version changed or could not be saved. Review the current values again.")
                return false
            }
            used = used || use
        }
        if used {
            MemoryShelf.shared.reload()
            refresh("The selected Sync versions were applied. Review their current values before forgetting.")
            return false
        }
        let choices = legacyChoices.mapValues { choice -> ContextPrivacy.Choice in
            switch choice { case .keep: return .keep; case .remove: return .remove; case .restore: return .restore }
        }
        let cleared = privacy.clear(plan, choices: choices)
        guard cleared.complete else {
            refresh("Could not finish clearing: " + cleared.unresolved.joined(separator: "; ") + ". Review again; nothing is reported as fully cleared.")
            return false
        }
        result = cleared
        ConsentAudit.record("memory.clear.complete")
        MemoryShelf.shared.reload()
        Hints.shared.refresh()
        return true
    }

    var summary: [String] {
        let summary = plan.summary
        var lines = ["Remove notes, saved photos and the Notes About You report."]
        if summary.restoredFields > 0 { lines.append("Restore \(summary.restoredFields) earlier Profile or address values.") }
        if summary.removedFields > 0 { lines.append("Clear \(summary.removedFields) fields still owned by context collection.") }
        if summary.removedAddresses > 0 { lines.append("Remove \(summary.removedAddresses) context-created addresses that have no later kept fields or billing use.") }
        if summary.preservedFields > 0 { lines.append("Protect \(summary.preservedFields) later fields you explicitly kept or edited.") }
        lines.append("Passwords, card data, browsing history and your actions stay.")
        return lines
    }
}

struct MemoryClearReviewContent: View {
    var review: MemoryClearReview
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !review.message.isEmpty { words(review.message).foregroundStyle(ButtonCSS.danger) }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(review.summary, id: \.self) { words($0) }
            }
            ForEach(review.plan.issues, id: \.self) { words($0).foregroundStyle(ButtonCSS.danger) }
            if !review.plan.legacy.isEmpty {
                heading("Historical values")
                words("Their authorship is uncertain. Choose explicitly for each value; nothing is selected for you.")
                    .foregroundStyle(Palette.muted)
                ForEach(review.plan.legacy) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.label).font(.system(size: 12, weight: .medium))
                        words(item.value.value.isEmpty ? "Empty value" : item.value.value).textSelection(.enabled)
                        if let restore = item.restore { words("Earlier value: " + (restore.value.isEmpty ? "Empty value" : restore.value)).foregroundStyle(Palette.muted) }
                        Picker("What to keep", selection: Binding<MemoryClearReview.LegacyChoice?>(
                            get: { review.legacyChoices[item.id] }, set: { review.legacyChoices[item.id] = $0 })) {
                            Text("Choose…").tag(nil as MemoryClearReview.LegacyChoice?)
                            Text("Keep").tag(MemoryClearReview.LegacyChoice.keep as MemoryClearReview.LegacyChoice?)
                            Text("Remove").tag(MemoryClearReview.LegacyChoice.remove as MemoryClearReview.LegacyChoice?)
                            if item.restore != nil { Text("Restore earlier value").tag(MemoryClearReview.LegacyChoice.restore as MemoryClearReview.LegacyChoice?) }
                        }
                        .labelsHidden().pickerStyle(.menu).controlSize(.small)
                    }
                    .padding(.vertical, 4)
                }
            }
            if !review.syncItems.isEmpty {
                heading("Pending Sync versions")
                words("These versions arrived after a clear. Keep the local clear, or apply this exact version for review.")
                    .foregroundStyle(Palette.muted)
                ForEach(review.syncItems) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.label).font(.system(size: 12, weight: .medium))
                        Text(item.stamp.description).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted).textSelection(.enabled)
                        if !item.image.isEmpty { Text(item.image).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
                        words(item.text).textSelection(.enabled)
                        Picker("Sync decision", selection: Binding<MemoryClearReview.SyncChoice?>(
                            get: { review.syncChoices[item.id] }, set: { review.syncChoices[item.id] = $0 })) {
                            Text("Choose…").tag(nil as MemoryClearReview.SyncChoice?)
                            Text("Keep the local clear").tag(MemoryClearReview.SyncChoice.keep as MemoryClearReview.SyncChoice?)
                            if item.canUse { Text("Use this version").tag(MemoryClearReview.SyncChoice.use as MemoryClearReview.SyncChoice?) }
                        }
                        .labelsHidden().pickerStyle(.menu).controlSize(.small)
                    }
                    .padding(.vertical, 4)
                }
            }
            words("Sync removals are kept locally for delivery. An offline device may need review when it reconnects.")
                .foregroundStyle(Palette.muted)
        }
        .foregroundStyle(Palette.ink)
    }
    private func words(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
    }
    private func heading(_ text: String) -> some View {
        Text(text).font(.system(size: 12, weight: .semibold)).padding(.top, 4)
    }
}
