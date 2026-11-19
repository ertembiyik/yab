import SwiftUI

/// General's engine row: the default with its mark, and at the foot of its
/// list the way to the sites' table. Watching only the rules, so General
/// isn't drawn for them.
struct EngineGeneralRows: View {
    private var engine = EngineRulesModel.shared
    var model: SettingsModel

    var body: some View {
        if EngineRules.available {
            SettingsRow("Default engine") {
                DropMenu("Default engine",
                         options: EngineDefault.offered.map { DropOption(title: $0.title, value: $0, picture: $0.mark) },
                         selection: Binding(get: { engine.standard }, set: { EngineRules.choose($0) }),
                         inset: TableCell.inset, small: NSSize(width: 14, height: 14), trailing: true,
                         link: DropLink(title: SettingsPage.engine.title) { model.go(.engine) })
                    .frame(width: TableCell.column, alignment: .trailing)
            }
            .settingsAnchor("engine-default")
        }
    }
}

private extension EngineDefault {
    /// The engine's own mark, Auto's a drawn one in the words' ink.
    var mark: NSImage? {
        switch self {
        case .auto: Glyphs.image("yab.fork", side: 16)
        case .webKit, .webKitFirst: Self.logo("webkit")
        case .chromium: Self.logo("chromium")
        }
    }

    static func logo(_ name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Sites"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: 16, height: 16)
        return image
    }
}

/// General › Engines for Sites, as round 2 drew the table in Air Traffic
/// Control's language (the site bare, its engine in a MenuCell, Remove on a
/// right click): the owner's sites, if any, then the built-in rules in a
/// muted group, each with its reason, each overridable. Its search and
/// Add Site… stand in the toolbar (EngineToolbar).
struct EnginePage: View {
    private var model = EngineRulesModel.shared
    var search: EngineSearch

    private func shown(_ text: String) -> Bool {
        let needle = search.words.trimmingCharacters(in: .whitespacesAndNewlines)
        return needle.isEmpty || ShortcutsPage.says(text, needle)
    }

    var body: some View {
        let own = model.own.filter { shown($0.host) }
        let builtIn = EngineBuiltInRule.all.filter { shown(([$0.name, $0.reason] + $0.domains).joined(separator: " ")) }
        if !own.isEmpty {
            Section {
                ForEach(own) { rule in
                    EngineOwnRow(rule: rule)
                        .settingsAnchor("engine-rule:" + rule.host)
                }
            }
        }
        if !builtIn.isEmpty {
            Section {
                ForEach(builtIn) { rule in
                    EngineBuiltInRow(rule: rule, kind: model.builtIn[rule.id] ?? rule.engine)
                }
            }
        }
        if own.isEmpty, builtIn.isEmpty {
            Section {
                Text("No sites found").foregroundStyle(.secondary)
            }
        }
    }
}

/// What the page's search holds, for the table and the toolbar's field.
@MainActor
@Observable final class EngineSearch {
    var words = ""
}

/// The page's glass in the toolbar, beside back and forward: Shortcuts'
/// search, and Add Site… as a toolbar button of the same kind as Shortcuts'
/// Filters.
@MainActor
final class EngineToolbar: NSObject {
    static let searchID = NSToolbarItem.Identifier("SearchSettingsEngineSearch")
    static let addID = NSToolbarItem.Identifier("SearchSettingsEngineAdd")
    static var identifiers: [NSToolbarItem.Identifier] { [searchID, addID] }

    let search: ToolbarSearch
    private weak var toolbar: NSToolbar?
    private var following: ObservationLoop?

    init(search words: EngineSearch, window: NSWindow) {
        search = ToolbarSearch(id: Self.searchID, label: "Search sites", prompt: "Search sites", window: window,
                               words: { words.words }, typed: { words.words = $0 })
        super.init()
        following = ObservationLoop { [weak self] in
            _ = words.words
            self?.search.sync()
        }
    }

    func attach(to toolbar: NSToolbar, visible: Bool) {
        self.toolbar = toolbar
        search.attach(to: toolbar)
        toolbar.keep(Self.identifiers, shown: visible)
        if !visible { search.detach() }
    }

    func item(for id: NSToolbarItem.Identifier) -> NSToolbarItem? {
        if id == Self.searchID { return search.item() }
        guard id == Self.addID else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = "Add Site…"
        item.title = "Add Site…"
        item.target = self
        item.action = #selector(add(_:))
        item.isBordered = true
        item.visibilityPriority = .high
        return item
    }

    @objc private func add(_ sender: Any?) { EngineSiteEditing.shared.open() }

    /// How the toolbar stands, for a probe.
    var state: [String: Any] {
        ["searching": search.searching, "focused": search.field?.currentEditor() != nil,
         "noFocusRing": search.field?.focusRingType == NSFocusRingType.none,
         "adding": EngineSiteEditing.shared.draft != nil,
         "items": toolbar?.items.map(\.itemIdentifier.rawValue) ?? []]
    }

    /// AppKit's own button for Add Site…, for a probe to press.
    func addButton(in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSButton, button.title == "Add Site…" || button.accessibilityLabel() == "Add Site…" { return button }
        return view.subviews.lazy.compactMap { self.addButton(in: $0) }.first
    }
}

private let engineChoices: [(title: String, value: PageEngineKind)] = [
    (title: "Chromium", value: .chromium), (title: "WebKit", value: .webKit),
]

/// One of the owner's rules: the site's mark, the site, its engine.
private struct EngineOwnRow: View {
    let rule: SiteEngineSettings.OwnRule

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                HostMark(host: rule.host)
                Text(rule.host)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            MenuCell(title: "Engine", options: engineChoices, selection: Binding(
                get: { rule.kind },
                set: { SiteEngineSettings.shared.setOwn($0, host: rule.host) }
            ), trailing: true)
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Remove") { SiteEngineSettings.shared.setOwn(nil, host: rule.host) }
        }
    }
}

/// A rule Yab ships, muted, with its reason in a few words.
private struct EngineBuiltInRow: View {
    let rule: EngineBuiltInRule
    let kind: PageEngineKind

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                HostMark(host: rule.host)
                    .opacity(0.55)
                Text(rule.name)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(rule.reason)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            MenuCell(title: "Engine", options: engineChoices, selection: Binding(
                get: { kind },
                set: { SiteEngineSettings.shared.set($0, for: rule) }
            ), trailing: true)
            .opacity(kind == rule.engine ? 0.7 : 1)
        }
        .contentShape(Rectangle())
    }
}

/// Add Site…'s card over Settings, as Air Traffic Control's is.
@MainActor
@Observable final class EngineSiteEditing {
    static let shared = EngineSiteEditing()

    struct Draft: Identifiable {
        let id = UUID()
        var site = ""
        var kind: PageEngineKind = .chromium
    }

    var draft: Draft?

    func open(site: String = "", kind: PageEngineKind = .chromium) { draft = Draft(site: site, kind: kind) }
    func close() { draft = nil }

    /// "figma.com", "https://www.figma.com/file/…": the exact host.
    static func host(from typed: String) -> String? {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        let url = URL(string: text.contains("://") ? text : "https://" + text)
        guard let host = SiteEngineSettings.host(url), host.contains(".") else { return nil }
        return host
    }
}

struct EngineSiteCardLayer: View {
    private var editing = EngineSiteEditing.shared

    var body: some View {
        ZStack {
            if let draft = editing.draft {
                EngineSiteCard(draft: draft) { editing.close() }
                    .frame(width: 440)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.97).combined(with: .opacity).animation(Motion.arrive),
                        removal: .identity
                    ))
                    .id(draft.id)
            }
        }
    }
}

private struct EngineSiteCard: View {
    let draft: EngineSiteEditing.Draft
    let done: () -> Void

    @State private var typed: String
    @State private var kind: PageEngineKind
    @FocusState private var typing: Bool

    init(draft: EngineSiteEditing.Draft, done: @escaping () -> Void) {
        self.draft = draft
        self.done = done
        _typed = State(initialValue: draft.site)
        _kind = State(initialValue: draft.kind)
    }

    private var host: String? { EngineSiteEditing.host(from: typed) }

    private var detail: String {
        guard !typed.trimmingCharacters(in: .whitespaces).isEmpty else {
            return "New tabs and tabs waking from sleep open it in the engine you pick."
        }
        guard let host else { return "Needs to be a site, like figma.com." }
        return "\(host) opens in \(SiteEngineWords.name(kind))."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: CardFrame.wellGap) {
                well
                VStack(alignment: .leading, spacing: 2) {
                    Text("Always open a site in one engine")
                        .font(CardFrame.title)
                        .foregroundStyle(Palette.ink)
                    Text(detail)
                        .font(CardFrame.detail)
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(spacing: 6) {
                TextField("", text: $typed)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Palette.ink)
                    .focused($typing)
                    .modifier(CardField(hint: "figma.com", empty: typed.isEmpty, typing: typing))
                    .onSubmit(save)
                HStack(spacing: 8) {
                    Text("Opens in")
                        .font(.system(size: 13.5))
                        .foregroundStyle(Palette.ink)
                    Spacer(minLength: 8)
                    MenuCell(title: "Opens in", options: engineChoices, selection: $kind, trailing: true)
                }
                .padding(.leading, 10)
                .frame(height: 32)
            }
            .padding(.top, 12)
            HStack(spacing: 6) {
                Spacer(minLength: 8)
                Button(action: done) {
                    HStack(spacing: 6) {
                        Text("Cancel")
                        KeyGlyphs(keys: "esc", size: CardFrame.words, tint: nil, rest: 0.6)
                    }
                }
                .buttonStyle(.yab(.secondary, CardFrame.button))
                .fixedSize()
                Button(action: save) {
                    HStack(spacing: 6) {
                        Text("Add")
                        KeyGlyphs(keys: "↩", size: CardFrame.words, tint: nil, rest: 0.6)
                    }
                }
                .buttonStyle(.yab(.primary, CardFrame.button))
                .fixedSize()
                .disabled(host == nil)
                .allowsHitTesting(host != nil)
            }
            .padding(.top, CardFrame.buttonGap)
        }
        .cardFrame()
        .onExitCommand(perform: done)
        .onAppear { DispatchQueue.main.async { typing = true } }
    }

    private func save() {
        guard let host else { return }
        SiteEngineSettings.shared.setOwn(kind, host: host)
        done()
    }

    private var well: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        return shape.fill(Palette.ink.opacity(0.05))
            .overlay(shape.strokeBorder(Palette.ink.opacity(0.08), lineWidth: 0.5))
            .overlay { Symbol("plus", size: 16).foregroundStyle(Palette.ink) }
            .frame(width: CardFrame.well, height: CardFrame.well)
    }
}
