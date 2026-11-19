import AppKit
import Combine
import SwiftUI

// Tabs you haven't looked at in a while, put away, the way Arc archives them.
//
// A tab left alone for twelve hours (or a day, a week, a month, or never,
// Settings → Tabs) is closed the next time you come back to the app: at
// launch, before the window's first frame, so nothing vanishes in front of
// you, when the Mac wakes, when you switch back to it. So the morning
// starts with yesterday's forty tabs down to the ones you kept, and a notice
// in the corner says as much, with Undo on it. ⌘⇧T does the same.
//
// What stays, whatever its age: the page on screen, pinned tabs, the tabs
// kept above the line (Kept.swift), and anything
// sleep keeps awake, sound, a call, a download, a video out in the little
// window, something typed and not sent. When tabs don't sleep, sleep's
// reasons are asked here directly.
//
// It only looks when you come back, never in the middle of reading: a tab
// disappearing from under you while you work is not tidying.

enum Tidy: Int, CaseIterable, Identifiable {
    case never = 0
    case halfDay = 12
    case day = 24
    case week = 168
    case month = 720

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .never: return "Never"
        case .halfDay: return "12 h"
        case .day: return "Day"
        case .week: return "Week"
        case .month: return "Month"
        }
    }

    var seconds: TimeInterval? { self == .never ? nil : TimeInterval(rawValue) * 3600 }
}

extension Browser {
    /// How long a tab has to go without being looked at: the setting, or
    /// `tidy.after` in seconds, for the bench and for trying it.
    var tidyAfter: TimeInterval? {
        let set = Store.settings.double(forKey: "tidy.after")
        return set > 0 ? set : prefs.tidyAfter.seconds
    }

    /// Started once, at launch.
    func watchForTidy() {
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.tidy(); Chats.shared.archiveOld() } }
            .store(in: &tidyWatch)
        // A beat after waking, so the window is up to show the notice.
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .delay(for: .seconds(2), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.tidy(); Chats.shared.archiveOld() } }
            .store(in: &tidyWatch)
    }

    /// Every tab gone long enough unseen, put away in one batch. At launch
    /// it runs while the session is read, before anything is drawn: the
    /// window opens already tidy, and the notice follows once it is up.
    func tidy(atLaunch: Bool = false) {
        guard let wait = tidyAfter else { return }
        let now = Date()
        // With today's in every window, a tab looked at in another window
        // is no older here: closed here, it would close there too.
        let elsewhere = seenElsewhere()
        var old = tabs.filter { tab in
            let seen = elsewhere[KeptEverywhere.key(tab)].map { max($0, tab.touched) } ?? tab.touched
            return now.timeIntervalSince(seen) >= wait && tidyable(tab)
        }
        // A search's folder goes whole or not at all, one batch, as it came.
        let going = Set(old.map(\.id))
        let staying = Set(tabs.compactMap { tab in tab.nest.flatMap { $0.today && !going.contains(tab.id) ? ObjectIdentifier($0) : nil } })
        if !staying.isEmpty { old.removeAll { $0.nest.map { staying.contains(ObjectIdentifier($0)) } ?? false } }
        guard !old.isEmpty, let batch = putAway(old) else { return }
        WrappedLedger.shared.add(.tabsTidied, Double(old.count))
        tidied.append(batch)
        guard atLaunch else {
            tidier.show(old.count, batch: batch)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, tidied.contains(batch) else { return }
            tidier.show(old.count, batch: batch)
        }
    }

    /// Clear, on the line under the kept tabs: today's tabs put away now,
    /// whatever their age, but for what tidying up always leaves.
    func tidyNow() {
        guard dusting.isEmpty else { return }
        let going = tabs.filter(sweepable)
        let empty = folderBook.empties.filter { nest in
            guard nest.ordinaryToday else { return false }
            let root = nest.chain.first ?? nest
            return tabs(in: root).allSatisfy { tab in going.contains { $0 === tab } }
        }
        guard !going.isEmpty || !empty.isEmpty else { return }
        let land: ([Tab]) -> Void = { [weak self] left in
            guard let self else { return }
            let batch = putAway(left) ?? UUID()
            if !empty.isEmpty {
                clearedEmptyFolders[batch] = (spaceID, empty)
                for nest in empty { folderBook.removeEmpty(nest) }
            }
            tidied.append(batch)
            tidier.show(left.count, batch: batch)
        }
        if !dust(going, then: land) { land(going) }
    }

    /// Whether Clear would put anything away.
    var canTidyNow: Bool { dusting.isEmpty && (tabs.contains(where: sweepable) || folderBook.empties.contains { $0.ordinaryToday && tabs(in: $0.chain.first ?? $0).isEmpty }) }

    /// Today's rows on screen gone to dust as a wave, top to bottom, each
    /// giving up its room a beat after it sets off, so what stays rides up
    /// behind the dust (Dust.swift); all of them put away once the last has
    /// folded, when nothing moves for it: `land` is given those still open
    /// then. False when there is nothing of them on screen or no dust to be
    /// had now: then nothing has happened and they go as they always did.
    /// Clear's, and closing the others or those above or below (Browser).
    func dust(_ going: [Tab], then land: @escaping ([Tab]) -> Void) -> Bool {
        guard dusting.isEmpty, let column, column.shown else { return false }
        let floor = keptLine?.maxY ?? -.infinity
        let clip = rowsClip ?? column.bounds
        let ids = Set(going.map(\.id))
        let folders = folderBook
        let seen: (CGRect) -> Bool = { rect in
            let shown = rect.intersection(clip)
            return rect.minY >= floor - 1 && !shown.isNull && shown.height >= 8
        }
        // The rows drawn now, each once, from where the list has them
        // (DrawnRows): a tab tucked in a shut folder or scrolled out of the
        // list has no row, and goes with the batch as it always did.
        var rows: [(rect: CGRect, tabs: [Tab.ID], key: String?)] = []
        for tab in going {
            if let place = folders.place(of: tab), !place.shown { continue }
            guard let rect = drawnRows[DrawnRows.tab(tab.id)], seen(rect) else { continue }
            // A pair on one row, drawn on its first: one row, given up only
            // when both halves go. One half going alone leaves the row be,
            // and goes when the batch does.
            if let pair = pair(of: tab.id), pair.first == tab.id, drawnRows[DrawnRows.tab(pair.second)] == nil {
                guard ids.contains(pair.second) else { continue }
                rows.append((rect, [tab.id, pair.second], nil))
            } else {
                rows.append((rect, [tab.id], nil))
            }
        }
        // A folder whose tabs all go goes with them, its own row and the
        // "N more" under it in the wave too, rather than left standing
        // empty until the batch is put away.
        for folder in folders.folders where !folder.members.isEmpty && folder.members.allSatisfy(ids.contains) {
            for key in [DrawnRows.folder(folder.id), DrawnRows.more(folder.id)] {
                if let rect = drawnRows[key], seen(rect) { rows.append((rect, [], key)) }
            }
        }
        rows.sort { $0.rect.minY < $1.rect.minY }
        guard !rows.isEmpty else { return false }
        let step = rows.count > 1 ? min(Dust.waveStep, Dust.waveSpan / Double(rows.count - 1)) : 0
        let wave = rows.enumerated().map { k, row in
            DustRow(rect: row.rect.intersection(clip), start: Double(k) * step, fold: row.rect.height + SideBar.gap)
        }
        guard column.dust(wave) else { return false }
        // The half of a pair on one row going alone stays drawn: hiding it
        // would hide the row, the other half with it.
        let halves = Set(going.compactMap { tab in
            pair(of: tab.id).flatMap { pair in
                drawnRows[DrawnRows.tab(pair.second)] == nil && !(ids.contains(pair.first) && ids.contains(pair.second)) ? tab.id : nil
            }
        })
        dusting = ids.subtracting(halves)
        dustingRows = Set(rows.compactMap(\.key))
        for (k, row) in rows.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + wave[k].start + Dust.foldDelay) { [weak self] in
                guard let self else { return }
                let tabs = row.tabs.filter { self.dusting.contains($0) }
                let key = row.key.flatMap { self.dustingRows.contains($0) ? $0 : nil }
                guard !tabs.isEmpty || key != nil else { return }
                withAnimation(Dust.fold) {
                    if let key { _ = self.dustFoldedRows.insert(key) }
                    self.dustFolded.formUnion(tabs)
                }
            }
        }
        let end = (wave.last?.start ?? 0) + Dust.foldDelay + Dust.foldTime
        DispatchQueue.main.asyncAfter(deadline: .now() + end) { [weak self] in
            guard let self else { return }
            let left = tabs.filter { ids.contains($0.id) }
            dustLanding = true
            land(left)
            dusting = []
            dustFolded = []
            dustingRows = []
            dustFoldedRows = []
            DispatchQueue.main.async { self.dustLanding = false }
        }
        return true
    }

    /// Today's, and nothing keeping it: sound, a call, a download, a video
    /// out, something typed, a task's. Awake is no reason here, it may just
    /// have been looked at.
    private func sweepable(_ tab: Tab) -> Bool {
        if onScreen(tab.id) || tab.pin != nil || tab.kept || tab.bench || tab.isBlank || tasksHold(tab) { return false }
        return tab.asleep || awake(because: tab) == nil
    }

    /// A task's and not done with: one at work in it or its subagents still
    /// out, Yab's own out of sight, or what a finished one left that you
    /// haven't come to see. Its folder puts those away itself, once you
    /// have (Agents.putAway, AgentFeed).
    private func tasksHold(_ tab: Tab) -> Bool {
        if tab.unread != nil { return true }
        let agents = Agents.shared
        for id in [tab.worker, tab.agent, tab.answering, tab.began] {
            guard let id else { continue }
            if agents.sealed(id) { return true }
            guard let task = agents.session(agents.root(of: id)) else { continue }
            if task.state.live || agents.children(of: task.id).contains(where: { $0.state.live }) { return true }
        }
        return false
    }

    /// For the bench: every tab of yours but the one on screen, last seen
    /// this long ago.
    func ageForTidy(hours: Double) {
        let then = Date().addingTimeInterval(-hours * 3600)
        for tab in tabs where tab.id != activeID && !tab.bench { tab.touch(at: then) }
    }

    private func tidyable(_ tab: Tab) -> Bool {
        if onScreen(tab.id) || tab.pin != nil || tab.kept || tab.bench || tab.isBlank || tasksHold(tab) { return false }
        if tab.asleep { return true }
        // Awake this long while tabs sleep means something kept it awake,
        // and that something is the reason to leave it be.
        if prefs.sleepsTabs { return false }
        return awake(because: tab) == nil
    }
}

/// Where each row of the column is drawn while the list has it: a tab's
/// (a pair's on its first), a folder's own, a folder's "N more". What
/// Clear's dust is taken from. Unlike `KeySky.tabs`, which keeps a tab's
/// last place for a card to hang from, a row gone from the list takes its
/// place back: a tab tucked in a shut folder, or scrolled out, has none,
/// so the dust is never taken from a row drawn there since.
@MainActor
final class DrawnRows {
    private var frames: [String: (rect: CGRect, by: UUID)] = [:]

    subscript(key: String) -> CGRect? { frames[key]?.rect }

    func put(_ key: String, _ rect: CGRect, by: UUID) { frames[key] = (rect, by) }

    /// Only its own word: the same row drawn anew may have spoken since.
    func take(_ key: String, by: UUID) {
        if frames[key]?.by == by { frames[key] = nil }
    }

    nonisolated static func tab(_ id: Tab.ID) -> String { "tab:" + id.uuidString }
    nonisolated static func folder(_ id: String) -> String { "folder:" + id }
    nonisolated static func more(_ id: String) -> String { "more:" + id }
}

/// A row of the column telling `DrawnRows` where it is, while it is.
struct DrawnRow: ViewModifier {
    let key: String
    let rows: DrawnRows
    @State private var by = UUID()

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { [rows, key, by] in rows.put(key, $0, by: by) }
            .onDisappear { [rows, key, by] in rows.take(key, by: by) }
    }
}

/// Whether "Cleared" is up, and over how many. An object of its own for
/// the reason Toaster is one.
@MainActor
@Observable final class Tidier {
    private(set) var shown = false
    private(set) var count = 0
    /// Every batch the notice is about, so Undo takes all it counted.
    @ObservationIgnored private(set) var batches: [UUID] = []

    @ObservationIgnored private var hush: DispatchWorkItem?

    func show(_ count: Int, batch: UUID) {
        NoticeFeedback.success.play()
        if shown {
            self.count += count
            batches.append(batch)
        } else {
            self.count = count
            batches = [batch]
            shown = true
        }
        later(6)
    }

    func hide() {
        hush?.cancel()
        shown = false
    }

    /// The pointer over it holds it up; leaving gives it a little longer.
    func hold(_ on: Bool) {
        guard shown else { return }
        if on { hush?.cancel() } else { later(2) }
    }

    private func later(_ seconds: Double) {
        hush?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.shown = false }
        hush = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}

/// A broom with two sparks, in three pieces so they can move apart: the broom
/// turns about the foot of its handle, each spark grows from its own middle.
struct Broom: View {
    var sweep: Double
    var big: CGFloat
    var small: CGFloat

    var body: some View {
        ZStack {
            piece(Broom.stick)
                .rotationEffect(.degrees(sweep), anchor: UnitPoint(x: 20 / 24, y: 3 / 24))
            piece(Broom.bigSpark)
                .scaleEffect(big, anchor: UnitPoint(x: 10.5 / 24, y: 4.5 / 24))
            piece(Broom.smallSpark)
                .scaleEffect(small, anchor: UnitPoint(x: 5.5 / 24, y: 8.5 / 24))
        }
    }

    private func piece(_ image: NSImage?) -> some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().renderingMode(.template)
            }
        }
    }

    private static func art(_ path: String) -> NSImage? {
        let svg = #"<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none">"# + path + "</svg>"
        let image = NSImage(data: Data(svg.utf8))
        image?.isTemplate = true
        return image
    }

    static let stick = art(##"<path fill-rule="evenodd" clip-rule="evenodd" d="M20.494 2.13071C20.9742 2.40354 21.1423 3.01398 20.8695 3.49417L16.211 11.6934L16.4739 11.7891C17.9946 12.3426 19.2107 13.8511 18.9577 15.6529C18.6218 18.046 17.5997 19.7732 15.7132 21.6998C15.4261 21.9931 14.9889 22.0811 14.6106 21.9218L5.11191 17.9218C4.77265 17.7789 4.53931 17.4612 4.5045 17.0947C4.46968 16.7283 4.63902 16.3723 4.94531 16.1681C6.4026 15.1966 7.56778 14.2453 8.44308 12.8684C9.49955 11.2064 11.5974 10.0142 13.724 10.7882L14.3049 10.9996L19.1306 2.50618C19.4034 2.02599 20.0138 1.85788 20.494 2.13071ZM13.0399 12.6676C12.0565 12.3096 10.8499 12.8102 10.1309 13.9413C9.39348 15.1014 8.5024 15.9955 7.52875 16.7694L9.23671 17.4887C9.29412 17.5129 9.35952 17.5089 9.4136 17.478L11.5447 16.2597C11.7041 16.1686 11.8917 16.3224 11.8337 16.4966L11.2826 18.1499C11.2495 18.249 11.2984 18.3569 11.3947 18.3974L14.7482 19.8097C16.1067 18.3158 16.7421 17.0491 16.9771 15.3749C17.0719 14.7001 16.6192 13.9703 15.7899 13.6685L13.0399 12.6676Z" fill="#000"/>"##)
    static let bigSpark = art(##"<path d="M9.71906 3.56014C9.6845 3.62926 9.62846 3.6853 9.55934 3.71986L8.63803 4.18051C8.3748 4.31213 8.3748 4.68778 8.63803 4.81939L9.55934 5.28005C9.62846 5.31461 9.6845 5.37065 9.71906 5.43977L10.1797 6.36108C10.3113 6.62431 10.687 6.62431 10.8186 6.36108L11.2792 5.43977C11.3138 5.37065 11.3699 5.31461 11.439 5.28005L12.3603 4.81939C12.6235 4.68778 12.6235 4.31213 12.3603 4.18051L11.439 3.71986C11.3699 3.6853 11.3138 3.62926 11.2792 3.56014L10.8186 2.63883C10.687 2.3756 10.3113 2.3756 10.1797 2.63883L9.71906 3.56014Z" fill="#000"/>"##)
    static let smallSpark = art(##"<path d="M4.40702 7.18422C4.35864 7.28098 4.28018 7.35944 4.18342 7.40782L2.89358 8.05274C2.52506 8.237 2.52506 8.7629 2.89358 8.94717L4.18342 9.59208C4.28018 9.64047 4.35864 9.71893 4.40702 9.81569L5.05194 11.1055C5.2362 11.4741 5.7621 11.4741 5.94637 11.1055L6.59128 9.81569C6.63967 9.71893 6.71813 9.64047 6.81489 9.59208L8.10473 8.94717C8.47325 8.7629 8.47325 8.237 8.10473 8.05274L6.81489 7.40782C6.71813 7.35944 6.63967 7.28098 6.59128 7.18422L5.94637 5.89438C5.7621 5.52586 5.2362 5.52586 5.05194 5.89438L4.40702 7.18422Z" fill="#000"/>"##)
}
