import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A `.user.js` opened in this tab: the Keep card's look (BoostTrialView),
/// in the page's corner. The title is `@name`, the detail the permission
/// sentence, then where it came from. Review Code, Try on the site, Keep
/// ⌘↩; once tried, Undo replaces Try and it runs in this tab only.
struct UserscriptCard: View {
    let browser: Browser
    var tab: Tab
    private var scripts = Userscripts.shared
    @State private var keeping = false

    var body: some View {
        if let offer = scripts.offers[tab.id] {
            VStack(alignment: .leading, spacing: 0) {
                well(offer.script).padding(.bottom, 12)
                Text(offer.script.name)
                    .font(CardFrame.title)
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail(offer))
                    .font(CardFrame.detail)
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
                if let facts = offer.facts {
                    Text(facts)
                        .font(CardFrame.detail)
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                        .padding(.top, 4)
                }
                if let problem = offer.problem {
                    Text(problem)
                        .font(CardFrame.detail)
                        .foregroundStyle(ButtonCSS.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
                // Tampermonkey in Yab too: the file can go to it instead,
                // its own install page.
                if !offer.tried, scripts.tampermonkey(in: AddonProfiles.of(tab)) != nil {
                    Button("Install in Tampermonkey Instead") { scripts.useTampermonkey(tab) }
                        .buttonStyle(.plain)
                        .font(CardFrame.detail)
                        .foregroundStyle(Palette.muted)
                        .focusable(false)
                        .padding(.top, 4)
                }
                foot(offer).padding(.top, CardFrame.buttonGap)
            }
            .frame(width: BoostTrialView.width - CardFrame.inset * 2, alignment: .leading)
            .cardFrame()
            .padding(16)
        }
    }

    private func detail(_ offer: Userscripts.Offer) -> String {
        var words = offer.script.permission
        if offer.tried { words += " Only this tab until you keep it." }
        if let old = offer.replaces, old != offer.script.version { words += " Replaces \(old)." }
        return words
    }

    private func well(_ script: Userscript) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        let host = script.sites.first ?? tab.address?.host() ?? ""
        return shape.fill(Palette.ink.opacity(0.05))
            .overlay(shape.strokeBorder(Palette.ink.opacity(0.08), lineWidth: 0.5))
            .overlay {
                if let icon = script.icon.flatMap(URL.init(string:)), ["http", "https", "data"].contains(icon.scheme ?? "") {
                    AsyncImage(url: icon) { image in
                        image.resizable().interpolation(.high).aspectRatio(contentMode: .fit).frame(width: 22, height: 22)
                    } placeholder: {
                        Symbol("puzzlepiece.extension", size: 16).foregroundStyle(Palette.ink)
                    }
                } else {
                    Symbol("puzzlepiece.extension", size: 16).foregroundStyle(Palette.ink)
                }
            }
            .frame(width: CardFrame.well, height: CardFrame.well)
            .notched(!script.everywhere, side: 15, radius: 4, offset: 5)
            .overlay(alignment: .bottomTrailing) {
                if !script.everywhere {
                    Mark(icon: Favicons.shared.cached(host), letter: Browser.site(host).first.map { String($0).uppercased() } ?? "•", size: 15)
                        .offset(x: 5, y: 5)
                }
            }
            .onAppear { if !host.isEmpty { Favicons.shared.fetch(host: host) } }
    }

    private func foot(_ offer: Userscripts.Offer) -> some View {
        HStack(spacing: 6) {
            Button("Review Code") { UserscriptSheets.code(offer.script) }
                .buttonStyle(.yab(.quiet, CardFrame.button))
                .fixedSize()
            Spacer(minLength: 8)
            if offer.tried {
                press("Undo", .secondary, key: "esc") { scripts.dismiss(tab) }
                    .disabled(keeping)
            } else if let site = trySite(offer.script) {
                Button("Try on " + site) { Task { await scripts.tryOut(tab, browser: browser) } }
                    .buttonStyle(.yab(.secondary, CardFrame.button))
                    .fixedSize()
                    .disabled(!offer.ready || offer.problem != nil)
            }
            Button { keep() } label: {
                HStack(spacing: 6) {
                    Text(keeping ? "Keeping…" : "Keep")
                    KeyGlyphs(keys: "⌘↩", size: CardFrame.words, tint: nil, rest: 0.6)
                        .transaction { $0.animation = nil }
                }
            }
            .buttonStyle(.yab(.primary, CardFrame.button))
            .fixedSize()
            .disabled(!offer.ready || offer.problem != nil || keeping)
        }
    }

    /// Where Try goes, in a word: this page when it is one of the script's.
    private func trySite(_ script: Userscript) -> String? {
        if let url = tab.address, script.matches(url) { return "This Page" }
        guard let page = Userscripts.firstPage(script), let host = page.host() else { return nil }
        return UserscriptSheets.siteWord(host)
    }

    private func press(_ title: String, _ kind: ButtonKind, key: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            HStack(spacing: 6) {
                Text(title)
                KeyGlyphs(keys: key, size: CardFrame.words, tint: nil, rest: 0.6)
                    .transaction { $0.animation = nil }
            }
        }
        .buttonStyle(.yab(kind, CardFrame.button))
        .fixedSize()
    }

    private func keep() {
        keeping = true
        Task { await scripts.keep(tab); keeping = false }
    }
}

/// Site Controls' rows for the userscripts kept for this site, in the
/// Boosts block beside boosts: on or off in a word with the version, its
/// menu at the end; a version that asks for more says so with Update and
/// each new right in a line; the page's menu commands under it.
struct UserscriptSiteRows: View {
    let browser: Browser
    var tab: Tab
    private var scripts = Userscripts.shared
    @State private var deleting: Userscripts.Record?

    private typealias Setting = SiteControlsView.Setting

    var body: some View {
        if let url = tab.address {
            let mine = scripts.on(url, in: AddonProfiles.of(tab))
            VStack(spacing: 1) {
                ForEach(mine) { record in
                    SiteControlsView.SettingRow(row: row(record))
                    if let pending = record.pending {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(pending.rights, id: \.self) { right in
                                Text("+ " + right).sidebarFont(size: 11.5).foregroundStyle(Palette.ink)
                            }
                            Text("\(record.version) keeps running until you update.").sidebarFont(size: 11.5).foregroundStyle(Palette.muted)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 44) // design: under the row's title, past its 6 inset, 28 mark and 10 gap (SettingRow)
                        .padding(.trailing, 6) // design: the row's own trailing inset (SettingRow)
                        .padding(.bottom, 4)
                    }
                    if record.enabled {
                        ForEach(scripts.commands[tab.id]?[record.id] ?? []) { command in
                            SiteControlsView.SettingRow(row: Setting(symbol: "command", title: command.caption, said: "") {
                                ExtensionPanel.shared.close()
                                scripts.run(command.id, of: record.id, in: tab)
                            })
                        }
                    }
                }
                if let offer = moveOffer {
                    SiteControlsView.SettingRow(row: Setting(symbol: "arrow.right.square", title: offer, said: "Tampermonkey keeps any it must") {
                        ExtensionPanel.shared.close()
                        Store.settings.set(true, forKey: "userscripts.moveOffered")
                        UserscriptSheets.move()
                    })
                }
            }
            .alert("Delete userscript?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("Cancel", role: .cancel) { deleting = nil }
                Button("Delete", role: .destructive) { if let record = deleting { scripts.delete(record.id, in: AddonProfiles.of(tab)) }; deleting = nil }
            } message: { Text(deleting?.name ?? "") }
        }
    }

    /// Offered once, while Tampermonkey runs scripts on this page.
    private var moveOffer: String? {
        guard scripts.tampermonkey != nil, !Store.settings.bool(forKey: "userscripts.moveOffered"),
              let host = tab.address?.host(), Extensions.shared.contexts[scripts.tampermonkey!.id] != nil,
              !host.isEmpty else { return nil }
        return "Move Scripts from Tampermonkey…"
    }

    private func row(_ record: Userscripts.Record) -> Setting {
        let broken = scripts.scripts[record.id] == nil
        if let pending = record.pending, !broken {
            return Setting(symbol: "puzzlepiece.extension", title: record.name, said: "\(pending.version) asks for more",
                           on: record.enabled, act: { scripts.setEnabled(record.id, !record.enabled, in: AddonProfiles.of(tab)) },
                           end: AnyView(HStack(spacing: 6) {
                               Button("Update") { Task { await scripts.applyPending(record.id, in: AddonProfiles.of(tab)) } }
                                   .buttonStyle(.yab(.primary, .small))
                                   .fixedSize()
                                   .focusable(false)
                               menu(record)
                           }))
        }
        let stopped = !(scripts.errors[record.id] ?? []).isEmpty && (scripts.errors[record.id]?.count ?? 0) >= 3
        let said = broken ? "Could not load" : stopped ? "Stopped working on \(tab.address?.host().map(Browser.site) ?? "this site")"
            : (record.enabled ? "On" : "Off") + " · Userscript " + record.version
        return Setting(symbol: "puzzlepiece.extension", title: record.name, said: said, on: record.enabled && !broken, live: broken || stopped,
                       act: { scripts.setEnabled(record.id, !record.enabled, in: AddonProfiles.of(tab)) }, end: AnyView(menu(record)))
    }

    private func menu(_ record: Userscripts.Record) -> some View {
        Menu {
            Button("History…") { ExtensionPanel.shared.close(); UserscriptSheets.history(record.id) }
            Button("Review Code…") { ExtensionPanel.shared.close(); if let script = scripts.scripts[record.id] { UserscriptSheets.code(script, pending: record.pending == nil ? nil : record.id) } }
            if !(scripts.errors[record.id] ?? []).isEmpty {
                Button("Fix…") {
                    ExtensionPanel.shared.close()
                    let errors = (scripts.errors[record.id] ?? []).suffix(5).joined(separator: "\n")
                    browser.askInChat(about: tab, words: "The userscript \"\(record.name)\" (\(scripts.folder(record.id).path)/script.user.js) stopped working here. Its errors:\n\(errors)\nEdit a copy, try it in a tab of your own, and hand it to Keep as a boost trial. ")
                }
            }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([scripts.folder(record.id)]) }
            Divider()
            Button("Delete…", role: .destructive) { deleting = record }
        } label: {
            Symbol("ellipsis", size: 10, weight: .medium)
                .foregroundStyle(Palette.muted)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .focusable(false)
    }
}

/// Settings › Extensions, "Boosts and userscripts": everything kept, with
/// the sites each runs on, in the one Settings table look; Review Code,
/// History and Delete on a right click; Add Userscript… for a `.user.js`
/// of one's own (or one dropped on the list), then the way to move
/// Tampermonkey's scripts as the last row. Only while something is kept or
/// Tampermonkey is in.
struct UserscriptsSection: View {
    private var profile = ExtensionsHere.shared
    /// The window whose page in front gets the card; else the one in front.
    var browser: Browser?
    private var scripts = Userscripts.shared
    private var boosts = Boosts.shared
    @State private var hovering = false
    @State private var adding = false

    private var signIn: UUID? { AddonProfiles.of(browser) }

    var body: some View {
        let localScripts = scripts.records(in: signIn)
        let localBoosts = boosts.records(in: signIn)
        if !localScripts.isEmpty || !localBoosts.isEmpty || scripts.tampermonkey != nil {
            Section {
                ForEach(localScripts) { record in
                    row(symbol: "puzzlepiece.extension", name: record.name,
                        line: place(scripts.scripts[record.id]) + " · Userscript " + record.version + (record.moved.map { " · from " + $0 } ?? ""),
                        on: Binding(get: { record.enabled }, set: { scripts.setEnabled(record.id, $0, in: signIn) }),
                        update: record.pending == nil ? nil : { Task { await scripts.applyPending(record.id, in: signIn) } },
                        updateLine: record.pending.map { "\($0.version) asks for more: " + $0.rights.joined(separator: ", ").lowercased() })
                    .userscriptDrop(add)
                    .contextMenu {
                        Button("Review Code…") { if let script = scripts.scripts[record.id] { UserscriptSheets.code(script) } }
                        Button("History…") { UserscriptSheets.history(record.id) }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([scripts.folder(record.id)]) }
                        Divider()
                        Button("Delete", role: .destructive) { scripts.delete(record.id, in: signIn) }
                    }
                }
                ForEach(localBoosts) { record in
                    row(symbol: record.rung == .look ? "colorpalette" : "puzzlepiece.extension", name: record.name,
                        line: (record.sites == ["<all_urls>"] ? "Every site" : record.sites.first.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? "") + " · Boost",
                        on: Binding(get: { record.enabled }, set: { on in Task { await boosts.setEnabled(record.id, on, in: signIn) } }), update: nil, updateLine: nil)
                    .userscriptDrop(add)
                    .contextMenu {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([boosts.library.folder(record.id)]) }
                        Divider()
                        Button("Delete", role: .destructive) { Task { await boosts.delete(record.id, in: signIn) } }
                    }
                }
                Button { if let file = Userscripts.choose() { add(file) } } label: {
                    HStack(spacing: 8) {
                        Symbol("yab.puzzle.plus", size: 11, weight: .semibold).frame(width: 20)
                        Text("Add Userscript…")
                    }
                    .foregroundStyle(adding ? Palette.ink : Palette.muted)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle(scale: ButtonSize.regular.pressed))
                .onHover { adding = $0 }
                .frame(maxWidth: .infinity, alignment: .leading)
                .userscriptDrop(add)
                Button { UserscriptSheets.move() } label: {
                    HStack(spacing: 8) {
                        Symbol("arrow.right.square", size: 11, weight: .semibold).frame(width: 20)
                        Text("Move from Tampermonkey…")
                    }
                    .foregroundStyle(hovering ? Palette.ink : Palette.muted)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle(scale: ButtonSize.regular.pressed))
                .onHover { hovering = $0 }
                .frame(maxWidth: .infinity, alignment: .leading)
                .userscriptDrop(add)
            } header: {
                Text("Boosts and userscripts")
            }
        }
    }

    /// The card goes over the page in front: Settings steps aside for it.
    private func add(_ file: URL) {
        guard let browser = browser ?? Links.browser else { return }
        SettingsWindow.shared.hide()
        Userscripts.shared.add(file, browser: browser)
    }

    private func place(_ script: Userscript?) -> String {
        guard let script else { return "Could not load" }
        if script.everywhere { return "Every site" }
        let sites = script.sites
        return sites.count > 1 ? sites[0] + " and \(sites.count - 1) more" : sites.first ?? "Every site"
    }

    private func row(symbol: String, name: String, line: String, on: Binding<Bool>, update: (() -> Void)?, updateLine: String?) -> some View {
        HStack(spacing: 8) {
            Symbol(symbol, size: 12).foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 3) { // design: a Settings row's title and its line, as SettingsRow sets them
                Text(name).lineLimit(1)
                Text(line).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                if let updateLine {
                    Text(updateLine).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let update {
                Button("Update", action: update).settingsButton(.primary)
            }
            Toggle("Enabled", isOn: on)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
    }
}

/// The sheets a userscript opens over the window in front: its code, its
/// history, the move from Tampermonkey.
@MainActor
enum UserscriptSheets {
    private static var open: [NSWindow] = []

    static func present<Content: View>(_ content: Content, width: CGFloat, height: CGFloat) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = WindowHosting.content(content.environment(\.closeSheet, CloseSheet { close(window) }))
        open.append(window)
        if let parent = NSApp.keyWindow ?? NSApp.mainWindow, parent.attachedSheet == nil {
            parent.beginSheet(window)
        } else {
            window.opensOnActiveSpace()
            window.center(); window.makeKeyAndOrderFront(nil)
        }
    }

    static func close(_ window: NSWindow) {
        if let parent = window.sheetParent { parent.endSheet(window) } else { window.close() }
        open.removeAll { $0 === window }
    }

    static func code(_ script: Userscript, pending: String? = nil) {
        present(UserscriptCodeView(script: script, pendingFor: pending), width: 680, height: 540)
    }
    static func history(_ id: String) {
        present(UserscriptHistoryView(id: id), width: 520, height: 360)
    }
    static func move() {
        present(UserscriptMoveView(), width: 520, height: 460)
    }

    /// A site in a word, as Try names it: YouTube, GitHub, Wikipedia.
    static func siteWord(_ host: String) -> String {
        let known = ["youtube.com": "YouTube", "github.com": "GitHub", "greasyfork.org": "Greasy Fork", "ycombinator.com": "Hacker News",
                     "wikipedia.org": "Wikipedia", "reddit.com": "Reddit", "x.com": "X", "twitter.com": "X", "linkedin.com": "LinkedIn"]
        return known[Browser.site(host)] ?? Browser.siteName(host)
    }
}

extension View {
    /// A `.user.js` dropped here goes where Add Userscript… sends a chosen one.
    func userscriptDrop(_ take: @escaping @MainActor (URL) -> Void) -> some View {
        onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let file = url.flatMap({ Userscripts.dropped([$0]) }) else { return }
                Task { @MainActor in take(file) }
            }
            return true
        }
    }
}

struct CloseSheet { let close: () -> Void }
private struct CloseSheetKey: EnvironmentKey { static let defaultValue = CloseSheet {} }
extension EnvironmentValues {
    var closeSheet: CloseSheet {
        get { self[CloseSheetKey.self] }
        set { self[CloseSheetKey.self] = newValue }
    }
}

/// Review Code: the file as it will run, its pinned files, and for a
/// version waiting for Update, what changed.
private struct UserscriptCodeView: View {
    let script: Userscript
    let pendingFor: String?
    @Environment(\.closeSheet) private var close

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(script.name).font(.headline)
            Text(script.permission).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ThreadScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let id = pendingFor, let diff = diff(id) {
                        DisclosureGroup("Changes in the new version") {
                            Text(diff).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    DisclosureGroup("script.user.js", isExpanded: .constant(true)) {
                        Text(String(script.source.prefix(200_000))).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(script.requires + script.resources, id: \.url) { file in
                        DisclosureGroup(Userscript.describe(require: file.url) + " · sha256 " + file.sha256.prefix(12)) {
                            Text(String(file.text.prefix(100_000))).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            HStack { Spacer(); Button("Done") { close.close() }.keyboardShortcut(.cancelAction) }
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 400)
    }

    private func diff(_ id: String) -> String? {
        let pending = Userscripts.shared.folder(id).appendingPathComponent("pending/script.user.js")
        guard let new = try? String(contentsOf: pending, encoding: .utf8) else { return nil }
        let before = script.source.components(separatedBy: .newlines), after = new.components(separatedBy: .newlines)
        return after.difference(from: before).map { change in
            switch change {
            case .remove(let offset, let line, _): return "− \(offset + 1): " + line
            case .insert(let offset, let line, _): return "+ \(offset + 1): " + line
            }
        }.prefix(2000).joined(separator: "\n")
    }
}

/// The versions kept before, each with Restore.
private struct UserscriptHistoryView: View {
    let id: String
    @Environment(\.closeSheet) private var close
    @State private var restoring = false

    var body: some View {
        let kept = Userscripts.shared.record(id)
        VStack(alignment: .leading, spacing: 16) {
            Text(kept?.name ?? "").font(.headline)
            ThreadScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Version \(kept?.version ?? "")").font(.system(size: 12))
                        Spacer()
                        Text("Current").font(.caption)
                    }
                    Divider()
                    let past = Userscripts.shared.history(id)
                    if past.isEmpty { Text("No earlier versions.").font(.system(size: 12)).foregroundStyle(.secondary) }
                    ForEach(past, id: \.url) { entry in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Version \(entry.version)").font(.system(size: 12))
                                Text(entry.date).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Restore") {
                                restoring = true
                                Task { await Userscripts.shared.restore(id, from: entry.url); close.close() }
                            }.disabled(restoring)
                        }
                        Divider()
                    }
                }
            }
            HStack { Spacer(); Button("Done") { close.close() }.keyboardShortcut(.cancelAction) }
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 300)
    }
}

/// "Move 6 scripts from Tampermonkey?": one checkbox row per script, how
/// it will run at its end; those that need what only Tampermonkey gives
/// unchecked, saying why. A backup from Chrome dropped here, or chosen.
struct UserscriptMoveView: View {
    @Environment(\.closeSheet) private var close
    @State private var items: [UserscriptMove.Item] = []
    @State private var chosen: Set<String> = []
    @State private var from = "Tampermonkey"
    @State private var reading = true
    @State private var moving = false
    @State private var said: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Text(items.isEmpty && !reading ? "Drop a Tampermonkey or Violentmonkey backup here (Utilities › Export in Tampermonkey), or choose one."
                 : "Each keeps its stored values. Moved scripts stop running in Tampermonkey.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ThreadScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(items) { item in
                        Toggle(isOn: Binding(get: { chosen.contains(item.id) }, set: { if $0 { chosen.insert(item.id) } else { chosen.remove(item.id) } })) {
                            HStack {
                                Text(item.script.name).lineLimit(1)
                                Spacer(minLength: 8)
                                Text(item.stays ?? item.how).font(.callout).foregroundStyle(.tertiary).lineLimit(1)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .disabled(item.stays != nil)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(Color.primary.opacity(0.04)))
            if let said { Text(said).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            HStack(spacing: 8) {
                Button("Choose Backup…") { choose() }.settingsButton(.quiet)
                Spacer()
                Button("Not Now") { close.close() }.keyboardShortcut(.cancelAction).settingsButton()
                Button { move() } label: {
                    HStack(spacing: 6) {
                        Text(moving ? "Moving…" : chosen.count == 1 ? "Move 1 Script" : "Move \(chosen.count) Scripts")
                        KeyGlyphs(keys: "⌘↩", size: 12.5, tint: nil, rest: 0.6).transaction { $0.animation = nil }
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .settingsButton(.primary)
                .disabled(chosen.isEmpty || moving)
            }
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 380)
        .task { await read() }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in load(url) }
            }
            return true
        }
    }

    private var title: String {
        if reading { return "Reading Tampermonkey…" }
        if items.isEmpty { return "Move scripts from Tampermonkey" }
        return items.count == 1 ? "Move 1 script from \(from)?" : "Move \(items.count) scripts from \(from)?"
    }

    private func read() async {
        if #available(macOS 15.4, *) {
            items = (try? await UserscriptMove.fromTampermonkey()) ?? []
        }
        chosen = Set(items.filter { $0.stays == nil }.map(\.id))
        reading = false
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip, .javaScript]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url)
    }

    private func load(_ url: URL) {
        do {
            items = try UserscriptMove.fromBackup(url)
            from = items.isEmpty ? from : "the backup"
            chosen = Set(items.filter { $0.stays == nil }.map(\.id))
            said = items.isEmpty ? "No userscripts in that file." : nil
        } catch { said = error.localizedDescription }
    }

    private func move() {
        moving = true
        let picked = items.filter { chosen.contains($0.id) }
        Task {
            let done = await UserscriptMove.move(picked, from: from == "the backup" ? "a backup" : from)
            moving = false
            if done.failed.isEmpty { close.close() }
            else { said = "Moved \(done.moved). " + done.failed.joined(separator: " ") }
        }
    }
}
