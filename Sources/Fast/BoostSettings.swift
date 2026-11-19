import AppKit
import SwiftUI

// Settings › Boosts: the changes kept for sites, a boost's or a userscript's,
// in one list, On then Off, in the look of Spaces' list. A row opens that
// boost's own page; Select picks several to turn on, off or delete. Before
// there is one the page is an arrival pointing to the Store. Drawn from the
// picked mockup "A, the plan as written" (PLAN-library-bulk.md, section 5).

/// A boost's or a userscript's mark: the site's icon on a faint tile, a
/// globe for every site, `</>` for a userscript.
struct BoostMark: View {
    let item: BoostItem
    var side: CGFloat = 22

    /// A page's own mark, over 40 points, is the icon itself, filling its
    /// square; in a row it stands on a faint tile.
    private var large: Bool { side >= 40 }

    var body: some View {
        ZStack {
            if !large || item.markHost == nil {
                RoundedRectangle(cornerRadius: large ? Radius.floating : Radius.small, style: .continuous)
                    .fill(Palette.ink.opacity(0.06))
            }
            content
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var content: some View {
        if item.kind == .userscript {
            Symbol("yab.code", size: side * 0.55).foregroundStyle(.secondary)
        } else if let host = item.markHost.map(BoostItem.bare) {
            SiteIcon(host: host, side: large ? side : side * 0.72)
        } else {
            Symbol("globe", size: side * 0.55).foregroundStyle(.secondary)
        }
    }
}

/// A site's icon, or its first letter until there is one.
struct SiteIcon: View {
    let host: String
    var side: CGFloat = 16

    var body: some View {
        Group {
            if let icon = Favicons.shared.cached(host) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: side * 0.22, style: .continuous))
            } else {
                Text(Browser.site(host).first.map { String($0).uppercased() } ?? "\u{2022}")
                    .font(.system(size: side * 0.62, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: side, height: side)
            }
        }
        .onAppear { Favicons.shared.fetch(host: host) }
    }
}

/// What a press on a row's switch, or a button under Select, does to the
/// boosts and userscripts it names, in the sign-in the page is for.
@MainActor
enum BoostActions {
    static func turn(_ items: [BoostItem], on: Bool, in signIn: UUID?) async {
        for item in items where item.enabled != on {
            switch item.kind {
            case .boost: await Boosts.shared.setEnabled(item.key, on, in: signIn)
            case .userscript: Userscripts.shared.setEnabled(item.key, on, in: signIn)
            }
        }
    }

    static func delete(_ items: [BoostItem], in signIn: UUID?) async {
        for item in items {
            switch item.kind {
            case .boost: await Boosts.shared.delete(item.key, in: signIn)
            case .userscript: Userscripts.shared.delete(item.key, in: signIn)
            }
        }
    }

    /// Delete… asks once, with the names, in the middle of Settings.
    static func ask(_ items: [BoostItem]) async -> Bool {
        await Questions.shared.ask(Question(title: BoostDeletion.title(items), detail: BoostDeletion.detail(items),
                                            yes: "Delete", danger: true, place: .settings, bare: true))
    }
}

// MARK: - the page

struct BoostsSettings: View {
    var browser: Browser
    var prefs: Preferences
    var model: SettingsModel
    private var boosts = Boosts.shared
    private var scripts = Userscripts.shared

    var body: some View {
        if boosts.records.isEmpty, scripts.records.isEmpty {
            BoostsArrival(browser: browser)
        } else if let opened = model.opened {
            ThreadForm {
                if opened.hasPrefix("script:") {
                    UserscriptDetail(id: String(opened.dropFirst("script:".count)), browser: browser, model: model)
                } else {
                    BoostDetail(id: String(opened.dropFirst("boost:".count)), browser: browser, model: model)
                }
            }
            .formStyle(.grouped)
            .id(opened)
        } else {
            BoostsList(browser: browser, model: model)
        }
    }
}

/// Nothing kept yet: the way in, in the middle of the pane, as Spaces and
/// Extensions have before there is one.
struct BoostsArrival: View {
    var browser: Browser

    var body: some View {
        ArrivalPage(page: .boosts, title: "Boosts", blurb: SettingsPage.boosts.blurb ?? "") {
            HStack(spacing: 8) {
                Button("Open Store") {
                    SettingsWindow.shared.hide()
                    browser.openPlace(.store)
                }
                .settingsButton(.primary)
                Button("Build One with Claude") {
                    SettingsWindow.shared.hide()
                    browser.newBoost()
                }
                .settingsButton()
            }
            .padding(.top, 20)
        }
        .settingsAnchor("boosts")
    }
}

/// Which sign-in's boosts the page is, from the space picked or the
/// window's own.
@MainActor
func boostsSign(_ browser: Browser, _ model: SettingsModel) -> (space: UUID, signIn: UUID?) {
    let space = model.boostsSpace.flatMap { id in browser.spaces.contains { $0.id == id } ? id : nil } ?? browser.spaceID
    return (space, AddonProfiles.of(space: space))
}

/// The bench's hand on Boosts' list (a --test run only): Select turned on
/// or off, rows picked by name, Delete… asked.
enum BoostsBench {
    static let hand = Notification.Name("yab.settings.boostsHand")
}

private struct BoostsList: View {
    var browser: Browser
    var model: SettingsModel
    private var boosts = Boosts.shared
    private var scripts = Userscripts.shared
    private var catalog = StoreCatalog.shared

    @State private var selecting = false
    @State private var picks = BoostPicks()
    @State private var order = BoostsList.savedOrder()

    private static let orderKey = "boostsOrder"
    private static func savedOrder() -> [String] { Store.settings.stringArray(forKey: orderKey) ?? [] }

    private var sign: (space: UUID, signIn: UUID?) { boostsSign(browser, model) }

    private var items: [BoostItem] {
        let signIn = sign.signIn
        let mine = boosts.records(in: signIn)
        let own = scripts.records(in: signIn)
        return BoostOrder.sorted(
            BoostItem.list(boosts: mine, scripts: own,
                           sites: Dictionary(uniqueKeysWithValues: own.map { ($0.id, scripts.scripts[$0.id]?.sites ?? []) }),
                           loaded: Set(boosts.packages.keys),
                           asking: Set(mine.map(\.id).filter { catalog.pending($0) != nil }),
                           scriptsLoaded: Set(scripts.scripts.keys)),
            by: order)
    }

    var body: some View {
        let all = items
        let on = all.filter(\.enabled)
        let off = all.filter { !$0.enabled }
        let places = SignIns.split(browser) ? SignIns.places(browser) : []
        let place = places.first { $0.holds(sign.space) }
        let lead = place.map { "Boosts for \($0.names)\u{2019}s sign-ins" }
        ThreadForm {
            PageHero(page: .boosts)
                .settingsAnchor("boosts")
            if !places.isEmpty {
                Section {
                    SettingsRow("Sign-ins", detail: "Spaces with separate sign-ins have separate boosts.") {
                        DropMenu("Sign-ins",
                                 options: places.compactMap { place in place.spaces.first.map { (title: place.names, value: $0.id) } },
                                 selection: Binding(get: { place?.spaces.first?.id ?? browser.spaceID },
                                                    set: { model.boostsSpace = $0 }))
                            .frame(maxWidth: SignIns.pickerWidth)
                            .layoutPriority(1)
                    }
                    .settingsAnchor("boosts-sign-ins")
                }
            }
            if all.isEmpty {
                Section { SettingsNote("Nothing is kept in these sign-ins yet.") }
            }
            if !on.isEmpty {
                Section {
                    BoostGroup(items: on, all: all, order: $order, selecting: selecting, picks: $picks,
                               signIn: sign.signIn, model: model, save: save)
                        .padding(.vertical, SettingsList.air - 10) // design: the form's own inset round a cell, traded for the list's air
                        .settingsAnchor("boost-list")
                } header: {
                    header(lead ?? "On", button: true)
                } footer: {
                    if off.isEmpty { foot(all) }
                }
            }
            if !off.isEmpty {
                Section {
                    BoostGroup(items: off, all: all, order: $order, selecting: selecting, picks: $picks,
                               signIn: sign.signIn, model: model, save: save)
                        .padding(.vertical, SettingsList.air - 10) // design: the form's own inset round a cell, traded for the list's air
                } header: {
                    if on.isEmpty { header(lead ?? "Off", button: true) }
                    else if lead == nil { header("Off", button: false) }
                } footer: {
                    foot(all)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: all.map(\.id)) { _, _ in picks.keep(all) }
        .onReceive(NotificationCenter.default.publisher(for: BoostsBench.hand)) { note in
            guard Store.testing, let hand = note.userInfo as? [String: Any] else { return }
            if let name = hand["space"] as? String, let space = browser.spaces.first(where: { $0.name == name }) { model.boostsSpace = space.id }
            if let on = hand["select"] as? Bool { selecting = on; picks.clear() }
            for name in hand["pick"] as? [String] ?? [] {
                if let item = all.first(where: { $0.name == name }) { picks.toggle(item.id) }
            }
            if hand["ask"] as? Bool == true { delete(all) }
        }
    }

    private func save(_ next: [String]) {
        order = next
        Store.settings.set(next, forKey: Self.orderKey)
    }

    /// A group's name, and Select / Done at its end.
    private func header(_ title: String, button: Bool) -> some View {
        HStack(spacing: 8) {
            Text(title)
            Spacer(minLength: 0)
            if button {
                Button(selecting ? "Done" : "Select") {
                    selecting.toggle()
                    picks.clear()
                }
                .buttonStyle(.yab(.quiet, .small))
                .fixedSize()
            }
        }
        .textCase(nil)
    }

    /// Under the last card while selecting: how many, and what to do.
    @ViewBuilder
    private func foot(_ all: [BoostItem]) -> some View {
        if selecting {
            HStack(spacing: 8) {
                Text(picks.words)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("Turn On") { act(all, on: true) }
                    .settingsButton()
                    .disabled(!picks.canTurnOn(all))
                Button("Turn Off") { act(all, on: false) }
                    .settingsButton()
                    .disabled(!picks.canTurnOff(all))
                Button("Delete\u{2026}") { delete(all) }
                    .buttonStyle(.yab(.secondary, .regular, tint: ButtonCSS.danger))
                    .disabled(!picks.canDelete(all))
            }
            .padding(.top, 4)
            .textCase(nil)
        }
    }

    private func act(_ all: [BoostItem], on: Bool) {
        let picked = picks.picked(all)
        let signIn = sign.signIn
        Task { await BoostActions.turn(picked, on: on, in: signIn) }
    }

    private func delete(_ all: [BoostItem]) {
        let picked = picks.picked(all)
        let signIn = sign.signIn
        Task {
            guard await BoostActions.ask(picked) else { return }
            await BoostActions.delete(picked, in: signIn)
            picks.clear()
            selecting = false
        }
    }
}

/// One card of rows: a grip, or a box while selecting, the mark, the name,
/// where it works, the switch and the way in. A row in the hand moves over
/// the others, as Spaces' do.
private struct BoostGroup: View {
    let items: [BoostItem]
    let all: [BoostItem]
    @Binding var order: [String]
    let selecting: Bool
    @Binding var picks: BoostPicks
    let signIn: UUID?
    let model: SettingsModel
    let save: ([String]) -> Void

    @State private var lifted: String?
    @State private var lift: CGFloat = 0

    private var pitch: CGFloat { SettingsList.row }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                BoostRow(item: item, selecting: selecting, picked: picks.contains(item.id),
                         lifted: lifted == item.id, rule: index > 0 && lifted != item.id,
                         grip: items.count > 1 ? reorder(item) : nil,
                         turn: { on in Task { await BoostActions.turn([item], on: on, in: signIn) } },
                         pick: { picks.toggle(item.id) },
                         open: { model.open(boost: item.id) })
                    .offset(y: shift(index))
                    .zIndex(lifted == item.id ? 1 : 0)
                    .animation(lifted == nil || lifted == item.id ? nil : Motion.settle, value: shift(index))
            }
        }
    }

    private func landing(_ from: Int) -> Int {
        min(items.count - 1, max(0, from + Int((lift / pitch).rounded())))
    }

    private func shift(_ index: Int) -> CGFloat {
        guard let lifted, let from = items.firstIndex(where: { $0.id == lifted }) else { return 0 }
        if index == from { return lift }
        let to = landing(from)
        if from < to, index > from, index <= to { return -pitch }
        if from > to, index < from, index >= to { return pitch }
        return 0
    }

    private func reorder(_ item: BoostItem) -> AnyGesture<Void> {
        AnyGesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { drag in
                if lifted != item.id { NSCursor.closedHand.push() }
                lifted = item.id
                lift = drag.translation.height
            }
            .onEnded { _ in
                NSCursor.pop()
                guard lifted == item.id, let from = items.firstIndex(where: { $0.id == item.id }) else { return }
                let to = landing(from)
                var still = Transaction()
                still.disablesAnimations = true
                withTransaction(still) {
                    // The whole list's order, so the other group keeps its own.
                    let known = BoostOrder.sorted(all, by: order).map(\.id)
                    save(BoostOrder.moved(known, group: items.map(\.id), id: item.id, to: to))
                    lifted = nil
                    lift = 0
                }
            }
            .map { _ in () })
    }
}

private struct BoostRow: View {
    let item: BoostItem
    let selecting: Bool
    let picked: Bool
    let lifted: Bool
    let rule: Bool
    let grip: AnyGesture<Void>?
    let turn: (Bool) -> Void
    let pick: () -> Void
    let open: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            lead
            BoostMark(item: item)
            Text(item.name).lineLimit(1)
            Text(item.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let warning = item.warning {
                HStack(spacing: 4) {
                    Symbol("exclamationmark.triangle.fill", size: 11).foregroundStyle(Color(nsColor: .systemOrange))
                    Text(warning).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Toggle("Enabled", isOn: Binding(get: { item.enabled }, set: turn))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(item.trouble == .broken)
            SettingsChevron()
        }
        .opacity(item.enabled ? 1 : 0.55)
        .frame(height: SettingsList.row)
        .contentShape(Rectangle())
        .onTapGesture(perform: selecting ? pick : open)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous) // design: SettingsAnchor's wash, seven round inside the card's ten
                .fill(Color(nsColor: .unemphasizedSelectedContentBackgroundColor))
                .padding(.horizontal, -7) // design: SettingsAnchor's wash, out to the row's edges less three
                .opacity(picked ? 1 : 0)
        }
        .background {
            if lifted {
                let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                shape.fill(Color(nsColor: .controlBackgroundColor)) // design: a row lifted in the hand, as the tray's is, not a card
                    .castShadow(shape, color: .black.opacity(0.14), radius: 8, y: 3)
                    .padding(.horizontal, -6)
            }
        }
        .overlay(alignment: .top) {
            if rule { Divider().padding(.leading, 22).offset(y: -0.5) } // design: the grip's 14 and the row's gap of 8
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.name)
        .accessibilityHint(selecting ? "Selects \(item.name)" : "Opens \(item.name)")
        .accessibilityAddTraits(.isButton)
    }

    /// The grip that moves it, or the box that picks it.
    @ViewBuilder
    private var lead: some View {
        if selecting {
            Toggle("Select \(item.name)", isOn: Binding(get: { picked }, set: { _ in pick() }))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .frame(width: 14, height: SettingsList.row)
        } else {
            let dots = Symbol("circle.grid.2x3", size: 11)
                .foregroundStyle(.tertiary)
                .frame(width: 14, height: SettingsList.row)
                .contentShape(Rectangle())
            if let grip {
                dots
                    .onHover { inside in if inside { NSCursor.openHand.push() } else { NSCursor.pop() } }
                    .highPriorityGesture(grip)
                    .keyTip("Drag to change its place")
            } else {
                dots.hidden()
            }
        }
    }
}

// MARK: - one boost

/// When a version was kept, as the history says it: "Today, 9:41 AM",
/// "Oct 24, 6:12 PM".
enum BoostWords {
    static func when(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US")
        clock.calendar = calendar
        clock.timeZone = calendar.timeZone
        clock.dateFormat = "h:mm a"
        let time = clock.string(from: date)
        if calendar.isDate(date, inSameDayAs: now) { return "Today, " + time }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday, " + time
        }
        clock.dateFormat = "MMM d, h:mm a"
        return clock.string(from: date)
    }

    static func day(_ date: Date, calendar: Calendar = .current) -> String {
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US")
        clock.calendar = calendar
        clock.timeZone = calendar.timeZone
        clock.dateFormat = "MMM d"
        return clock.string(from: date)
    }

    /// The person's own words from a chat prompt, without what the chat
    /// told the agent ahead of them (attached files, pointed tabs, quotes).
    /// Boosts saved before 0.33 kept that context in their request.
    static func request(_ prompt: String) -> String {
        let said = [
            #"The user attached files on this Mac: .*?when the task needs it\. "#,
            #"The user points you at their tab .*?\(\S*\), ".*?"\. "#,
            #"Its words, read just now \(the page's.*?only for what they don't\. "#,
            #"This message is about th(?:at tab|ose tabs) \([^)]*\): .*?say plainly what stops you\. "#,
            #"They selected this on the page: «.*?»\. "#,
            #"The user points you at the email ".*?"[^.]*?\(thread [^)]*\)\. Read it with mail_read\. "#,
        ]
        var words = prompt
        for pattern in said {
            words = words.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        words = words.trimmingCharacters(in: .whitespacesAndNewlines)
        return words.isEmpty ? prompt : words
    }

    /// "Look · Made by Claude · Oct 22".
    static func made(kind: String, by author: String, on date: Date, calendar: Calendar = .current) -> String {
        [kind, author == "You" ? "Made by you" : "Made by \(author)", day(date, calendar: calendar)].joined(separator: " \u{00B7} ")
    }
}

/// The top of a boost's or a userscript's page: its mark, its name, what
/// it does and where it came from. The toolbar says the name too, as the
/// page is a level in.
private struct BoostHead: View {
    let item: BoostItem
    let about: String
    let meta: String

    var body: some View {
        Section {} header: {
            VStack(spacing: 6) {
                BoostMark(item: item, side: 64)
                    .padding(.bottom, 4)
                Text(item.name)
                    .font(.system(size: 20, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { bottom in
                        SettingsWindow.shared.heroTitle(item.name, bottom: bottom)
                    }
                if !about.isEmpty {
                    Text(about)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 440)
                }
                Text(meta)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .foregroundStyle(.primary)
            .textCase(nil)
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
            .padding(.bottom, 12)
            .accessibilityElement(children: .combine)
        }
    }
}

/// The sites a boost works on, a row each.
private struct BoostSites: View {
    let hosts: [String]

    var body: some View {
        Section {
            if hosts.isEmpty {
                row(mark: AnyView(Symbol("globe", size: 12).foregroundStyle(.secondary)), name: "Every site")
            }
            ForEach(hosts, id: \.self) { host in
                row(mark: AnyView(SiteIcon(host: BoostItem.bare(host), side: 16)), name: BoostItem.bare(host))
            }
        } header: {
            Text("Sites")
        }
    }

    private func row(mark: AnyView, name: String) -> some View {
        HStack(spacing: 8) {
            mark
                .frame(width: 22, height: 22)
                .background(Palette.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
            Text(name).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct BoostDetail: View {
    let id: String
    var browser: Browser
    var model: SettingsModel
    private var boosts = Boosts.shared
    private var catalog = StoreCatalog.shared
    @State private var comparing: BoostRevision?
    @State private var restoring = false

    var body: some View {
        let signIn = boostsSign(browser, model).signIn
        if let record = boosts.records(in: signIn).first(where: { $0.id == id }) {
            page(record, signIn: signIn)
        } else {
            Section { SettingsNote("This boost has been deleted.") }
        }
    }

    @ViewBuilder
    private func page(_ record: BoostRecord, signIn: UUID?) -> some View {
        let item = BoostItem.list(boosts: [record], scripts: [], sites: [:], loaded: Set(boosts.packages.keys),
                                  asking: catalog.pending(id) == nil ? [] : [id], scriptsLoaded: [])[0]
        let history = boosts.library.history(id)
        BoostHead(item: item, about: BoostWords.request(record.intent),
                  meta: BoostWords.made(kind: record.rung.rawValue, by: record.author, on: history.last?.date ?? record.updated))
        if let word = item.trouble {
            Section {
                switch word {
                case .stopped:
                    SettingsRow("Stopped working", detail: "Its page checks failed. Ask Claude to fix it.") {
                        Button("Fix\u{2026}") { ask("Fix boost \(id) from its original request. Its page checks failed. Read boost_read and try a repair.") }
                            .settingsButton(.primary)
                    }
                case .asksMore:
                    SettingsRow("New version asks for more", detail: "It stays as it was until you review the newer one.") {
                        Button("Review") {
                            SettingsWindow.shared.hide()
                            catalog.review(id, in: browser)
                        }
                        .settingsButton(.primary)
                    }
                case .broken:
                    SettingsNote("Could not load. Restore a version from History.")
                }
            }
        }
        Section {
            SettingsSwitch("On", isOn: Binding(get: { record.enabled },
                                               set: { on in Task { await boosts.setEnabled(id, on, in: signIn) } }))
        }
        BoostSites(hosts: item.hosts)
        Section {
            ForEach(history) { revision in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) { // design: a Settings row's title and its line, as SettingsRow sets them
                        Text(BoostWords.request(revision.intent)).lineLimit(1).truncationMode(.tail)
                            .pointerTip(BoostWords.request(revision.intent))
                        Text(BoostWords.when(revision.date)).font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if revision.id == record.revision {
                        Text("Current").font(.callout).foregroundStyle(.secondary)
                    }
                    Button("Compare") { comparing = revision }
                        .settingsButton()
                        .fixedSize()
                    if revision.id != record.revision {
                        Button("Restore") {
                            restoring = true
                            Task { await boosts.restore(revision, record: record); restoring = false }
                        }
                        .settingsButton()
                        .fixedSize()
                        .disabled(restoring)
                    }
                }
            }
        } header: {
            Text("History")
        }
        .sheet(item: $comparing) { revision in BoostDiffView(record: record, revision: revision) }
        Section {
            SettingsRow("Change", detail: "Say what to change and Claude does it.") {
                Button("Change\u{2026}") { ask("Change boost \(id): ") }
                    .settingsButton()
            }
        }
        Section {
            SettingsRow("Delete this boost") {
                Button("Delete\u{2026}") {
                    Task {
                        guard await BoostActions.ask([item]) else { return }
                        model.leave("boost:" + id, to: .boosts)
                        await BoostActions.delete([item], in: signIn)
                    }
                }
                .buttonStyle(.yab(.secondary, .regular, tint: ButtonCSS.danger))
            }
        }
    }

    private func ask(_ words: String) {
        SettingsWindow.shared.hide()
        browser.startBoost(words, about: nil)
    }
}

// MARK: - one userscript

struct UserscriptDetail: View {
    let id: String
    var browser: Browser
    var model: SettingsModel
    private var scripts = Userscripts.shared

    var body: some View {
        let signIn = boostsSign(browser, model).signIn
        if let record = scripts.records(in: signIn).first(where: { $0.id == id }) {
            page(record, signIn: signIn)
        } else {
            Section { SettingsNote("This userscript has been deleted.") }
        }
    }

    @ViewBuilder
    private func page(_ record: Userscripts.Record, signIn: UUID?) -> some View {
        let script = scripts.scripts[id]
        let item = BoostItem.list(boosts: [], scripts: [record], sites: [id: script?.sites ?? []], loaded: [],
                                  asking: [], scriptsLoaded: script == nil ? [] : [id])[0]
        let from = record.source.flatMap { URL(string: $0)?.host() }.map(BoostItem.bare)
        BoostHead(item: item, about: script?.header["description"]?.first ?? "",
                  meta: ["Userscript", "Version " + record.version, from.map { "from " + $0 }].compactMap { $0 }.joined(separator: " \u{00B7} "))
        if let pending = record.pending {
            Section {
                SettingsRow("Version \(pending.version) asks for more",
                            detail: pending.rights.joined(separator: ", ").lowercased()) {
                    Button("Update") { Task { await scripts.applyPending(id, in: signIn) } }
                        .settingsButton(.primary)
                }
            }
        }
        Section {
            SettingsSwitch("On", isOn: Binding(get: { record.enabled }, set: { scripts.setEnabled(id, $0, in: signIn) }))
        }
        BoostSites(hosts: script?.everywhere == true ? [] : script?.sites ?? [])
        Section {
            SettingsRow("Review Code", detail: "Read what it runs before it does.") {
                Button("Review Code\u{2026}") { if let script { UserscriptSheets.code(script) } }
                    .settingsButton()
                    .disabled(script == nil)
            }
            SettingsRow("History", detail: "Versions kept before this one.") {
                Button("History\u{2026}") { UserscriptSheets.history(id) }
                    .settingsButton()
            }
        }
        Section {
            SettingsRow("Delete this userscript") {
                Button("Delete\u{2026}") {
                    Task {
                        guard await BoostActions.ask([item]) else { return }
                        model.leave("script:" + id, to: .boosts)
                        await BoostActions.delete([item], in: signIn)
                    }
                }
                .buttonStyle(.yab(.secondary, .regular, tint: ButtonCSS.danger))
            }
        }
    }
}
