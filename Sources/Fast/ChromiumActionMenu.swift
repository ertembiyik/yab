import AppKit
import SwiftUI
import YabCoreClient

/// The extension's own rows of its button's right-click menu on a Chromium
/// tab: chrome.contextMenus items of context "action" (or MV2's
/// "browser_action" / "page_action", or "all"), as Chromium lists them under
/// the extension's name in its toolbar button's menu
/// (ExtensionContextMenuModel::AppendExtensionItems). Chrome keeps them in
/// its MenuManager; YabCore reads them for the page (`extension.actionMenu`,
/// CEF patch 0124) and runs one (`extension.actionMenu.run`): Chrome's
/// MenuManager::ExecuteCommand, so contextMenus.onClicked comes with the tab,
/// activeTab granted, a checkbox or radio flipped as in Chromium.
///
/// A menu is drawn the moment it is asked for, so the rows are read ahead:
/// when the pointer comes onto the button, and again after each run.
@MainActor
@Observable final class ChromiumActionMenu {
    static let shared = ChromiumActionMenu()

    struct Row: Equatable, Identifiable {
        enum Kind: String { case normal, checkbox, radio, separator }
        var id: String
        var title: String
        var kind: Kind
        var checked = false
        var enabled = true
        var rows: [Row] = []

        /// Chrome's rows, at most 4 levels and 64 rows a level deep; nothing
        /// that isn't one.
        nonisolated static func parse(_ value: JSONValue, depth: Int = 0) -> [Row] {
            guard depth < 4, case .array(let list) = value else { return [] }
            return list.prefix(64).compactMap { item in
                guard let kind = item["type"].string.flatMap(Kind.init(rawValue:)) else { return nil }
                if kind == .separator { return Row(id: "-", title: "", kind: .separator) }
                guard let id = item["id"].string, !id.isEmpty, id.utf8.count <= 1024,
                      let title = item["title"].string else { return nil }
                return Row(id: id, title: String(title.prefix(300)), kind: kind, checked: item["checked"] == .bool(true),
                           enabled: item["enabled"] != .bool(false), rows: parse(item["items"], depth: depth + 1))
            }
        }
    }

    /// By page (its YabCore tab) and extension.
    private(set) var rows: [String: [Row]] = [:]
    @ObservationIgnored private var reading: Set<String> = []

    private static func key(_ page: ChromiumPage, _ id: String) -> String? {
        page.remoteID.map { $0 + "|" + id }
    }

    func rows(_ id: String, tab: Tab) -> [Row] {
        guard let page = tab.builtPage as? ChromiumPage, let key = Self.key(page, id) else { return [] }
        return rows[key] ?? []
    }

    /// Read the rows for the button on this tab, ahead of its menu.
    func refresh(_ id: String, tab: Tab) {
        guard ChromiumProcess.shared.extensionSurfaces.actionMenu, ChromiumSidePanel.validExtensionID(id),
              let page = tab.builtPage as? ChromiumPage, let key = Self.key(page, id), !reading.contains(key) else { return }
        reading.insert(key)
        Task { @MainActor [weak self] in
            let reply = await page.extensionSurface("extension.actionMenu", ["extension": .string(id)])
            guard let self else { return }
            self.reading.remove(key)
            let next = reply.map { Row.parse($0["items"]) } ?? []
            if self.rows[key] != next { self.rows[key] = next }
        }
    }

    /// One row chosen: Chrome runs it for this tab.
    func run(_ id: String, row: Row, tab: Tab) async -> Bool {
        guard let page = tab.builtPage as? ChromiumPage else { return false }
        let reply = await page.extensionSurface("extension.actionMenu.run", ["extension": .string(id), "item": .string(row.id)])
        refresh(id, tab: tab)
        return reply?["ran"] == .bool(true)
    }
}

/// The rows in a SwiftUI menu, Chrome's way: a checkbox or radio row with
/// its mark, a parent row as a submenu, a separator as a divider.
struct ChromiumActionMenuRows: View {
    let id: String
    let tab: Tab
    let rows: [ChromiumActionMenu.Row]

    var body: some View {
        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
            switch row.kind {
            case .separator:
                Divider()
            case _ where !row.rows.isEmpty:
                Menu(row.title) { ChromiumActionMenuRows(id: id, tab: tab, rows: row.rows) }
                    .disabled(!row.enabled)
            case .checkbox, .radio:
                Toggle(row.title, isOn: Binding(get: { row.checked }, set: { _ in choose(row) }))
                    .disabled(!row.enabled)
            case .normal:
                SwiftUI.Button(row.title) { choose(row) }
                    .disabled(!row.enabled)
            }
        }
    }

    private func choose(_ row: ChromiumActionMenu.Row) {
        Task { @MainActor in _ = await ChromiumActionMenu.shared.run(id, row: row, tab: tab) }
    }
}
