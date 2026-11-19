import SwiftUI
import AppKit

/// Chrome's Elements in yab's card: the tree as Chromium writes it (the
/// doctype, closing tags, a short text on its tag's line, tag, attribute
/// and value in their own colors), the path under it, and the sidebar with
/// Styles, Computed, Layout, Event Listeners, DOM Breakpoints, Properties
/// and Accessibility. What the panels say comes from WebKit's own inspector
/// models (DevWorkbenchBridge): the rules in cascade order with what each
/// overrides, the inherited ones, the attributes' style.
struct DevElementsPane: View {
    let browser: Browser
    @Bindable var model: DevWorkbench
    @State private var editingHTML: String?
    @State private var editingAttributes: Int?
    @State private var attributesText = ""
    @FocusState private var finding: Bool

    var body: some View {
        GeometryReader { size in
            Group {
                if size.size.width >= 620 {
                    HSplitView { dom.frame(minWidth: 200); DevElementsSide(browser: browser, model: model).frame(minWidth: 280, idealWidth: 340) }
                } else {
                    VSplitView { dom.frame(minHeight: 90, idealHeight: size.size.height * 0.45); DevElementsSide(browser: browser, model: model).frame(minHeight: 100) }
                }
            }
            .sheet(isPresented: Binding(get: { editingHTML != nil }, set: { if !$0 { editingHTML = nil } })) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Edit as HTML").font(.system(size: 13, weight: .semibold))
                    ThreadTextEditor(text: Binding(get: { editingHTML ?? "" }, set: { editingHTML = $0 })).font(DevMono.font(12))
                    HStack(spacing: 8) {
                        Spacer()
                        Button("Cancel") { editingHTML = nil }.buttonStyle(.yab(.quiet, .regular))
                        Button("Apply") { applyHTML() }.buttonStyle(.yab(.primary, .regular)).keyboardShortcut(.defaultAction)
                    }
                }.padding(16).frame(width: 640, height: 400)
            }
        }
        .onAppear { browser.elementsShown() }
        .onChange(of: model.domRevision) { browser.elementsRefresh() }
        // Selected by the card's own handler (DevAudit), once.
        .onChange(of: model.pickSerial) { editingAttributes = nil }
        .onChange(of: model.elementsFind) { if !model.elementsFind { browser.elementsFindClosed() } }
    }

    // MARK: the tree

    private var dom: some View {
        VStack(spacing: 0) {
            if model.axTreeShown { axTree } else { domTree }
            Divider()
            crumbs
            // Under the path, as Chromium's: the path above shows where each
            // step led.
            if model.elementsFind, !model.axTreeShown { findBar }
        }
        .environment(\.openURL, OpenURLAction { url in follow(url); return .handled })
    }

    /// Show accessibility tree: roles and names in place of the DOM, as Chromium's.
    private var axTree: some View {
        ThreadScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(DevAXLine.lines(model.axRoot)) { line in
                    HStack(spacing: 6) {
                        Text(line.node.role).foregroundStyle(Palette.ink)
                        if !line.node.name.isEmpty { Text("\"\(line.node.name)\"").foregroundStyle(ConsoleInk.string).lineLimit(1) }
                    }
                    .font(DevMono.font(11))
                    .padding(.leading, CGFloat(line.depth) * 14 + 30) // design: tree indentation, 14 a level after the gutter and the arrow
                    .frame(maxWidth: .infinity, minHeight: 16, alignment: .leading)
                    .background(model.selectedNode == line.node.id ? Color.accentColor.opacity(0.12) : .clear)
                    .contentShape(Rectangle())
                    .onTapGesture { select(line.node.id) }
                }
            }
            .padding(.vertical, 4)
        }
        .onAppear { browser.elementsAXTree() }
    }

    /// As Chromium's: a deep tree scrolls sideways, each line's words keeping
    /// room to wrap in; a node brought into view comes in from the side too.
    /// The lines are the model's, made once a change of the tree or of what
    /// is open (DevTree.swift), drawn by an AppKit table (DevTreeTable.swift).
    private var domTree: some View {
        DevTreeTable(model: model, editing: editingAttributes, editText: attributesText,
                     select: { select($0, close: $1) },
                     toggle: { toggle($0, deep: $1) },
                     doubleClick: { doubleClick($0) },
                     menu: { nodeMenu($0) },
                     follow: { follow($0) },
                     commit: { id, text in attributesText = text; applyAttributes(id) },
                     cancel: { editingAttributes = nil },
                     hover: { hover($0) })
            .onChange(of: model.editRequest) { if let node = model.node(model.editNode) { editAttributes(node) } }
            .onChange(of: model.htmlRequest) { editHTML(model.editNode) }
    }

    /// The node under the pointer drawn on the page, once a node: not
    /// hidden and drawn again on the way from one row to the next.
    private func hover(_ id: Int) {
        guard id != model.hoverSent else { return }
        browser.elementsHighlight(id)
    }

    /// Chrome's, as drawn (layout A): a capsule field with its clear
    /// button, the count, up and down, close. Found as typed, 150 ms
    /// after the last key (400 for a single one); while an answer is
    /// awaited the count before it stands dimmed.
    private var findBar: some View {
        HStack(spacing: 4) {
            HStack(spacing: 6) {
                Symbol("magnifyingglass", size: 12).foregroundStyle(Palette.muted)
                TextField("Find by string, selector, or XPath", text: $model.elementsQuery)
                    .textFieldStyle(.plain).font(.system(size: 13))
                    .focused($finding)
                    .onAppear { focusFind() }
                    .onSubmit {
                        let back = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
                        let words = model.elementsQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                        if words != model.elementsSearched || model.elementsWaiting { browser.elementsSearch(model.elementsQuery) } else { browser.elementsStep(back ? -1 : 1) }
                        finding = true
                    }
                    .onExitCommand { model.elementsFind = false }
                if !model.elementsQuery.isEmpty {
                    Button { model.elementsQuery = ""; finding = true } label: {
                        Symbol("xmark.circle.fill", size: 14).foregroundStyle(Palette.muted)
                    }
                    .buttonStyle(.plain).keyTip("Clear")
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, 4) // design: as drawn, the clear button sits close to the capsule end
            .frame(height: ButtonSize.regular.height)
            .background(Palette.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(finding ? 0.75 : 0), lineWidth: 1.5)
            }
            count
            Button { browser.elementsStep(-1) } label: { Symbol("chevron.up", size: 12) }
                .buttonStyle(.yab(.quiet, .regular, icon: .square)).disabled(!stepping).keyTip("Previous", keys: "⇧↩")
            Button { browser.elementsStep(1) } label: { Symbol("chevron.down", size: 12) }
                .buttonStyle(.yab(.quiet, .regular, icon: .square)).disabled(!stepping).keyTip("Next", keys: "↩")
            Button { model.elementsFind = false } label: { Symbol("xmark", size: 12) }
                .buttonStyle(.yab(.quiet, .regular, icon: .square)).keyTip("Close", keys: "esc")
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
        .overlay(alignment: .top) { Divider() }
        .task(id: model.elementsQuery) {
            let words = model.elementsQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            if words != model.elementsSearched, !words.isEmpty { model.elementsWaiting = true }
            try? await Task.sleep(for: .milliseconds(words.count == 1 ? 400 : 150))
            guard !Task.isCancelled else { return }
            browser.elementsSearch(model.elementsQuery)
        }
        // The page changed under the words: looked for again, staying on
        // the node shown while it is still found.
        .task(id: model.domRevision) {
            guard !model.elementsSearched.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            browser.elementsSearch(model.elementsQuery, keep: true)
        }
        .onChange(of: model.elementsFocus) { focusFind() }
    }

    private var stepping: Bool { model.elementsCount > 0 && !model.elementsWaiting && !model.elementsSearched.isEmpty }

    /// "2 of 6", "No matches", "1 of 10,000+"; nothing for no words; the
    /// count before dimmed while the next is awaited.
    private var count: some View {
        let total = model.elementsCount
        let shown = total > 9_999 ? "10,000+" : total.formatted()
        let words: String = model.elementsQuery.isEmpty || model.elementsSearched.isEmpty ? ""
            : total == 0 ? "No matches"
            : model.elementsMatch < 0 ? "\(shown) found"
            : "\((model.elementsMatch + 1).formatted()) of \(shown)"
        return Text(words)
            .font(.system(size: 12.5)).monospacedDigit()
            .foregroundStyle(total == 0 ? Palette.ink.opacity(0.8) : Palette.muted)
            .opacity(model.elementsWaiting ? 0.45 : 1)
            .frame(minWidth: 66, alignment: .trailing)
            .padding(.horizontal, 6)
            .lineLimit(1)
    }

    /// The field takes the keyboard with its words selected, as ⌘F again
    /// does in Chrome.
    private func focusFind() {
        finding = true
        DispatchQueue.main.async {
            finding = true
            NSApp.sendAction(#selector(NSResponder.selectAll(_:)), to: nil, from: nil)
        }
    }

    private var crumbs: some View {
        ScrollViewReader { reader in
            ThreadScrollView(.horizontal) {
                HStack(spacing: 2) {
                    ForEach(path, id: \.id) { node in
                        Button { select(node.id) } label: {
                            Text(DevTreeLine.crumb(node)).font(DevMono.font(11)).foregroundStyle(ConsoleInk.tag)
                        }
                        .buttonStyle(.yab(node.id == model.selectedNode ? .secondary : .quiet, .small))
                        .id(node.id)
                    }
                }
                .padding(.horizontal, 6)
            }
            .scrollIndicators(.never)
            .frame(height: 30)
            .onChange(of: model.selectedNode) { reader.scrollTo(model.selectedNode, anchor: .trailing) }
        }
    }

    /// A node's menu, Chrome's: on its line's right click and its ⋯.
    private func nodeMenu(_ node: DevDOMNode) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let element = node.type == 1
        func item(_ title: String, enabled: Bool = true, on: Bool = false, _ act: @escaping () -> Void) -> NSMenuItem {
            let made = PageMenuItem(title, act: act)
            made.isEnabled = enabled
            made.state = on ? .on : .off
            return made
        }
        func sub(_ title: String, enabled: Bool = true, _ items: [NSMenuItem]) -> NSMenuItem {
            let made = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let inner = NSMenu()
            inner.autoenablesItems = false
            items.forEach(inner.addItem)
            made.submenu = inner
            made.isEnabled = enabled
            return made
        }
        menu.addItem(item("Edit Attributes", enabled: element) { editAttributes(node) })
        menu.addItem(item("Edit as HTML") { editHTML(node.id) })
        menu.addItem(item("Duplicate Element", enabled: element) { browser.workCall("elements.action", ["id": node.id, "action": "duplicate"]) { _ in browser.elementsRefresh() } })
        menu.addItem(item("Delete Element") { browser.workCall("DOM.markUndoableState"); browser.workCall("DOM.removeNode", ["nodeId": node.id]) { _ in browser.elementsRefresh(reload: true) } })
        menu.addItem(.separator())
        menu.addItem(sub("Copy", [
            item("Copy outerHTML") { browser.workCall("elements.html", ["id": node.id]) { value in browser.copyForAgent((value as? [String: Any])?["outerHTML"] as? String ?? "", "Copied HTML") } },
            item("Copy Selector") { browser.workCall("elements.action", ["id": node.id, "action": "selector"]) { browser.copyForAgent($0 as? String ?? "", "Copied selector") } },
            item("Copy for Agent") { browser.workCall("elements.html", ["id": node.id]) { value in browser.copyForAgent((value as? [String: Any])?["outerHTML"] as? String ?? "", "Copied element for agent") } },
        ]))
        menu.addItem(item("Ask in Chat") { select(node.id); browser.askAboutDev() })
        menu.addItem(.separator())
        menu.addItem(item("Hide Element", enabled: element) { browser.workCall("elements.action", ["id": node.id, "action": "hide"]) { _ in browser.elementsRefresh(); browser.elementsSelect(node.id) } })
        menu.addItem(sub("Force State", enabled: element, DevElementsSide.states.map { state in item(":" + state) { select(node.id); browser.elementsForce(state) } }))
        menu.addItem(sub("Break on", enabled: element, DevDOMBreak.kinds.map { kind in
            let on = model.domBreaks.contains { $0.node == node.id && $0.type == kind.type }
            return item(kind.title, on: on) { browser.elementsBreak(node.id, kind.type, on: !on) }
        }))
        menu.addItem(.separator())
        menu.addItem(item("Expand Recursively") { browser.elementsExpand(node.id, deep: true) })
        menu.addItem(item("Collapse Children") { browser.elementsCollapse(node.id, deep: true, keep: true) })
        menu.addItem(item("Scroll into View", enabled: element) { browser.workCall("elements.action", ["id": node.id, "action": "scroll"]) })
        menu.addItem(item("Focus", enabled: element) { browser.workCall("DOM.focus", ["nodeId": node.id]) })
        menu.addItem(.separator())
        menu.addItem(item("Undo") { browser.workCall("DOM.undo") { _ in browser.elementsRefresh(reload: true) } })
        menu.addItem(item("Redo") { browser.workCall("DOM.redo") { _ in browser.elementsRefresh(reload: true) } })
        return menu
    }

    /// From the index, not a walk of the whole tree on every redraw.
    private var path: [DevDOMNode] {
        let index = model.treeIndex
        // The document and the text a node holds aren't steps of the path, as in Chromium.
        return index.path(to: model.selectedNode).compactMap { index.nodes[$0] }.filter { $0.type == 1 }
    }
    private func select(_ id: Int, close: Bool = false) { guard id != 0 else { return }; editingAttributes = nil; browser.elementsSelect(id, close: close) }
    private func toggle(_ node: DevDOMNode, deep: Bool = false) {
        if model.expanded.contains(node.id) { browser.elementsCollapse(node.id, deep: deep) } else { browser.elementsExpand(node.id, deep: deep) }
    }
    private func editHTML(_ id: Int) {
        guard id != 0 else { return }
        select(id)
        browser.workCall("elements.html", ["id": id]) { editingHTML = ($0 as? [String: Any])?["outerHTML"] as? String }
    }
    /// As in Chromium, a closed node opens; on any other line the
    /// attributes are edited (Edit Attributes in its menu too).
    private func doubleClick(_ line: DevTreeLine) {
        guard line.kind != .close else { return }
        if line.arrow, !model.expanded.contains(line.node.id) { toggle(line.node) } else { editAttributes(line.node) }
    }
    private func editAttributes(_ node: DevDOMNode) {
        guard node.type == 1 else { return }
        select(node.id)
        attributesText = (node.attrs ?? []).map { $0.count > 1 ? "\($0[0])=\"\($0[1])\"" : $0.first ?? "" }.joined(separator: " ")
        editingAttributes = node.id
    }
    private func applyAttributes(_ id: Int) {
        let text = attributesText
        editingAttributes = nil
        browser.workCall("elements.attributes", ["id": id, "text": text]) { _ in browser.elementsRefresh(); browser.elementsSelect(id) }
    }
    private func applyHTML() {
        guard let html = editingHTML else { return }
        browser.workCall("elements.editHTML", ["id": model.selectedNode, "html": html]) { _ in editingHTML = nil; browser.elementsRefresh(reload: true) }
    }
    /// A link in the tree: a script or a sheet the page loaded opens in
    /// Sources, anything else in a tab of its own.
    private func follow(_ url: URL) {
        if let file = model.sources.first(where: { $0.url == url.absoluteString }) {
            browser.pickDevPane(.sources); browser.sourceOpen(file)
        } else {
            _ = browser.open(url, foreground: true, from: browser.toolsFront)
        }
    }
}

/// A line of the accessibility tree.
struct DevAXLine: Identifiable {
    let node: DevAXNode
    let depth: Int
    var id: Int { node.id }
    static func lines(_ root: DevAXNode?) -> [DevAXLine] {
        var out: [DevAXLine] = []
        func walk(_ n: DevAXNode, _ depth: Int) { out.append(DevAXLine(node: n, depth: depth)); n.children.forEach { walk($0, depth + 1) } }
        if let root { walk(root, 0) }
        return out
    }
}

/// One line of the tree: an element's opening tag (or all of it, closed,
/// or with its short text), its closing tag under its children, a text, a
/// comment, the doctype.
struct DevTreeLine: Identifiable {
    enum Kind { case open, close, whole }
    let node: DevDOMNode
    let depth: Int
    let kind: Kind
    var arrow = false
    /// The node's own base URL, for href and src.
    var base: URL?
    var id: String { (kind == .close ? "c" : "o") + String(node.id) }

    /// Chrome's ForbiddenClosingTagElements: written without a closing tag.
    static let void: Set<String> = ["area", "base", "basefont", "br", "canvas", "col", "command", "embed", "frame", "hr", "img", "input", "keygen",
                                    "link", "menuitem", "meta", "param", "source", "track", "wbr"]
    /// Chrome's MappedCharToEntity: characters a reader can't see, written
    /// as their entities in texts and values.
    static let entities: [Character: String] = ["\u{A0}": "nbsp", "\u{AD}": "shy", "\u{2002}": "ensp", "\u{2003}": "emsp", "\u{2009}": "thinsp",
                                                "\u{200A}": "hairsp", "\u{200B}": "ZeroWidthSpace", "\u{200C}": "zwnj", "\u{200D}": "zwj",
                                                "\u{200E}": "lrm", "\u{200F}": "rlm", "\u{202A}": "#x202A", "\u{202B}": "#x202B", "\u{202C}": "#x202C",
                                                "\u{202D}": "#x202D", "\u{202E}": "#x202E", "\u{2060}": "NoBreak", "\u{FEFF}": "#xFEFF"]
    static func entitied(_ words: String) -> String {
        guard words.unicodeScalars.contains(where: { $0.value >= 0xA0 }), words.contains(where: { entities[$0] != nil }) else { return words }
        var out = ""
        for c in words { if let name = entities[c] { out += "&" + name + ";" } else { out.append(c) } }
        return out
    }
    /// Chrome keeps a text this long on its tag's line.
    static let inline = 80

    static func lines(_ root: DevDOMNode?, open: Set<Int>) -> [DevTreeLine] {
        guard let root else { return [] }
        var out: [DevTreeLine] = []
        let base = root.value.flatMap(URL.init(string:))
        func walk(_ n: DevDOMNode, _ depth: Int) {
            switch n.type {
            case 3:
                // Whitespace between tags isn't shown, as in Chromium.
                guard !n.blank else { return }
                out.append(DevTreeLine(node: n, depth: depth, kind: .whole, base: base))
            case 1:
                let kids = n.children.filter { !$0.blank }
                let short = kids.count == 1 && kids[0].type == 3 && (kids[0].value ?? "").count <= inline && n.count <= 1
                if short || n.count == 0 {
                    out.append(DevTreeLine(node: n, depth: depth, kind: .whole, base: base))
                } else if open.contains(n.id), !kids.isEmpty {
                    out.append(DevTreeLine(node: n, depth: depth, kind: .open, arrow: true, base: base))
                    kids.forEach { walk($0, depth + 1) }
                    if !void.contains(n.tag) { out.append(DevTreeLine(node: n, depth: depth, kind: .close, base: base)) }
                } else {
                    out.append(DevTreeLine(node: n, depth: depth, kind: .whole, arrow: true, base: base))
                }
            case 9 where depth == 0:
                // The page's own document isn't a line; a frame's is.
                n.children.forEach { walk($0, depth) }
            default:
                if n.children.isEmpty || !open.contains(n.id) {
                    out.append(DevTreeLine(node: n, depth: depth, kind: .whole, arrow: !n.children.isEmpty, base: base))
                } else {
                    out.append(DevTreeLine(node: n, depth: depth, kind: .open, arrow: true, base: base))
                    n.children.forEach { walk($0, depth + 1) }
                }
            }
        }
        walk(root, 0)
        return out
    }

    /// The line's words as SwiftUI takes them (the tests read them so).
    func text(picked: Bool, lit: String? = nil) -> AttributedString {
        let drawn = NSMutableAttributedString(attributedString: attributed(picked: picked, lit: lit))
        drawn.enumerateAttribute(Self.linkKey, in: NSRange(location: 0, length: drawn.length)) { value, range, _ in
            if let url = value as? URL { drawn.addAttribute(.link, value: url, range: range) }
        }
        return (try? AttributedString(drawn, including: \.appKit)) ?? AttributedString(drawn.string)
    }

    /// An attribute's value that opens: its address, under a key of Yab's
    /// own, so AppKit's drawing keeps Chrome's color instead of its link blue.
    static let linkKey = NSAttributedString.Key("yab.devTreeLink")

    /// Whether the line has a value that opens.
    var hasLink: Bool { node.type == 1 && kind != .close && (node.attrs ?? []).contains { $0.count > 1 && ($0[0] == "href" || $0[0] == "src") } }

    /// The line as Chromium writes it, in its colors (DevTreeTable draws it).
    func attributed(picked: Bool, lit: String? = nil) -> NSAttributedString {
        let s = NSMutableAttributedString()
        let font = DevTreeMetrics.font
        func add(_ words: String, _ color: NSColor, italic: Bool = false, link: URL? = nil, ground: NSColor? = nil) {
            var attributes: [NSAttributedString.Key: Any] = [.font: italic ? DevTreeMetrics.italic : font, .foregroundColor: color]
            if let link { attributes[Self.linkKey] = link; attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if let ground { attributes[.backgroundColor] = ground }
            s.append(NSAttributedString(string: words, attributes: attributes))
        }
        let ink = Palette.NS.ink, muted = Palette.NS.muted, plate = Palette.NS.ink.withAlphaComponent(0.08)
        switch node.type {
        case 1:
            if kind == .close { add("</\(node.tag)>", ConsoleInk.NS.tag); break }
            add("<\(node.tag)", ConsoleInk.NS.tag)
            for pair in node.attrs ?? [] {
                add(" ", ConsoleInk.NS.tag)
                add(pair[0], ConsoleInk.NS.attribute)
                guard pair.count > 1 else { continue }
                add("=\"", ConsoleInk.NS.tag)
                let linked = ["href", "src"].contains(pair[0]) ? URL(string: pair[1], relativeTo: base)?.absoluteURL : nil
                add(Self.entitied(pair[1]), ConsoleInk.NS.attributeValue, link: linked.flatMap { ["http", "https", "file"].contains($0.scheme ?? "") ? $0 : nil })
                add("\"", ConsoleInk.NS.tag)
            }
            add(">", ConsoleInk.NS.tag)
            if let layout = node.layout {
                add(" ", ink)
                add(" \(layout) ", muted, ground: plate)
            }
            if kind == .whole {
                if let short = shortText {
                    add(Self.entitied(short), ink)
                } else if arrow {
                    add(" ⋯ ", muted, ground: plate)
                }
                if !Self.void.contains(node.tag) { add("</\(node.tag)>", ConsoleInk.NS.tag) }
            }
        case 3: add("\"\(Self.entitied(node.value ?? ""))\"", ink)
        case 8: add("<!--\(node.value ?? "")-->", ConsoleInk.NS.comment)
        case 10: add("<!DOCTYPE \(node.tag)>", muted)
        case 11: add("#shadow-root" + (node.value.map { " (\($0))" } ?? ""), muted)
        default: add(node.tag, muted)
        }
        // The row the find shows now, as Chromium's: the words lit where
        // they are (a tag's name, an attribute, a text); found by a
        // selector or an XPath instead, its tag's name softly.
        if let lit {
            let plain = DevTreeLine.plain(lit)
            let whole = s.string as NSString
            var from = 0
            var any = false
            while !plain.isEmpty, from < whole.length {
                let range = whole.range(of: plain, options: .caseInsensitive, range: NSRange(location: from, length: whole.length - from))
                guard range.location != NSNotFound, range.length > 0 else { break }
                s.addAttributes([.backgroundColor: DevTreeLine.mark, .foregroundColor: DevTreeLine.markInk], range: range)
                from = range.location + range.length
                any = true
            }
            if !any, node.type == 1 {
                let range = whole.range(of: node.tag)
                if range.location != NSNotFound { s.addAttribute(.backgroundColor, value: DevTreeLine.softMark, range: range) }
            }
        }
        if picked { add("  == $0", muted, italic: true) }
        return s
    }

    /// A text short enough to stay on its tag's line, as Chromium keeps it.
    var shortText: String? {
        let kids = node.children.filter { !$0.blank }
        guard kids.count == 1, kids[0].type == 3, (kids[0].value ?? "").count <= Self.inline, node.count <= 1 else { return nil }
        return kids[0].value ?? ""
    }

    /// The line's width without laying it out, when every character is
    /// ASCII (the font's glyphs are all as wide): most lines, counted. Nil
    /// for a line to measure as drawn (another script, an entity).
    func plainWidth(picked: Bool) -> CGFloat? {
        var count = 0, extra: CGFloat = 0
        func take(_ words: String) -> Bool {
            let bytes = words.utf8
            guard bytes.allSatisfy({ $0 < 0x80 }) else { return false }
            count += bytes.count
            return true
        }
        switch node.type {
        case 1:
            guard take(node.tag) else { return nil }
            if kind == .close { count += 3; break }
            count += 2
            for pair in node.attrs ?? [] {
                guard take(pair[0]) else { return nil }
                count += 1
                if pair.count > 1 { guard take(pair[1]) else { return nil }; count += 3 }
            }
            if let layout = node.layout { guard take(layout) else { return nil }; count += 3 }
            if kind == .whole {
                if let short = shortText { guard take(short) else { return nil } } else if arrow { extra += DevTreeMetrics.dots }
                if !Self.void.contains(node.tag) { count += node.tag.utf8.count + 3 }
            }
        case 3: guard take(node.value ?? "") else { return nil }; count += 2
        case 8: guard take(node.value ?? "") else { return nil }; count += 7
        case 10: guard take(node.tag) else { return nil }; count += 11
        case 11: count += 12; if let mode = node.value { guard take(mode) else { return nil }; count += 3 }
        default: guard take(node.tag) else { return nil }
        }
        if picked { extra += DevTreeMetrics.picked }
        return CGFloat(count) * DevTreeMetrics.advance + extra
    }

    /// The words as they appear in a row: `<div` and `div>` are a tag's
    /// name, `"x"` a value.
    static func plain(_ query: String) -> String {
        var words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if words.hasPrefix("<") { words.removeFirst() }
        if words.hasSuffix(">") { words.removeLast() }
        if words.count >= 2, words.hasPrefix("\""), words.hasSuffix("\"") { words = String(words.dropFirst().dropLast()) }
        return words
    }

    /// Chrome's search yellow, and its softer one for a tag found by a
    /// selector or an XPath.
    static let mark = NetInk.pair(0xFFE45C, 0xFFCC00, alphas: (1, 0.30))
    static let markInk = NetInk.pair(0x171717, 0xFFE17A)
    static let softMark = NetInk.pair(0xFFD600, 0xFFCC00, alphas: (0.25, 0.14))

    /// A step of the path under the tree: `p`, `div#main.wide`.
    static func crumb(_ node: DevDOMNode) -> String {
        var words = node.tag
        if let id = node.attribute("id"), !id.isEmpty { words += "#" + id }
        if let first = node.attribute("class")?.split(separator: " ").first { words += "." + first }
        return words
    }
}

/// What Elements' panes ask of the page, through WebKit's own inspector
/// models in the bridge (`elements.*`).
extension Browser {
    /// What the sidebar's tab needs that selecting a node didn't bring.
    func elementsSideLoad() {
        guard let model = workbench, model.selectedNode != 0 else { return }
        let id = model.selectedNode
        switch model.elementsTab {
        case "Properties":
            workCall("elements.nodeProperties", ["id": id]) { [weak model] value in
                guard model?.selectedNode == id else { return }
                model?.nodeProperties = (value as? [[String: Any]] ?? []).map { row in
                    DevNodeProperty(name: row["name"] as? String ?? "", preview: row["preview"] as? String ?? "", type: row["type"] as? String ?? "",
                                    own: row["own"] as? Bool ?? false,
                                    object: (row["objectId"] as? String).map { ConsoleValue(json: ["ty": "object", "st": row["subtype"] ?? "", "d": row["preview"] ?? "", "id": $0]) })
                }
            }
        case "Layout":
            workCall("elements.layouts") { [weak model] value in
                model?.layoutBoxes = (value as? [[String: Any]] ?? []).map { DevLayoutBox(id: $0["id"] as? Int ?? 0, kind: $0["kind"] as? String ?? "", label: $0["label"] as? String ?? "") }
            }
        case "Event Listeners", "Accessibility":
            workCall("elements.select", ["id": id]) { [weak model] in if model?.selectedNode == id { model?.loadStyles($0) } }
        default: break
        }
        if model.axTreeShown { elementsAXTree() }
    }
    func elementsAXTree() {
        workCall("elements.axTree") { [weak self] value in
            func node(_ row: [String: Any]) -> DevAXNode {
                DevAXNode(id: row["id"] as? Int ?? 0, role: row["role"] as? String ?? "", name: row["name"] as? String ?? "",
                          children: (row["children"] as? [[String: Any]] ?? []).map(node))
            }
            self?.workbench?.axRoot = (value as? [String: Any]).map(node)
        }
    }
    /// :hov, a state on or off on the selected node.
    func elementsForce(_ state: String) {
        guard let model = workbench else { return }
        if model.forced.contains(state) { model.forced.remove(state) } else { model.forced.insert(state) }
        let id = model.selectedNode
        workCall("CSS.forcePseudoState", ["nodeId": id, "forcedPseudoClasses": Array(model.forced)]) { [weak self] _ in self?.elementsSelect(id) }
    }
    /// .cls: a class added, or one of the node's turned off and back on.
    func elementsClass(_ name: String, on: Bool) {
        guard let model = workbench, !name.isEmpty else { return }
        let id = model.selectedNode
        if on { model.offClasses.removeAll { $0 == name } } else if !model.offClasses.contains(name) { model.offClasses.append(name) }
        workCall("elements.class", ["id": id, "name": name, "on": on]) { [weak self] _ in self?.elementsRefresh(); self?.elementsSelect(id) }
    }
    /// +: a rule for the node in the page's inspector sheet, as Chromium's.
    func elementsAddRule() {
        guard let id = workbench?.selectedNode, id != 0 else { return }
        workCall("elements.addRule", ["id": id]) { [weak self] _ in self?.elementsSelect(id) }
    }
    func elementsProperty(_ style: DevStyle, _ property: DevProperty, enabled: Bool) {
        elementsEdit(["key": style.id, "index": property.index, "enabled": enabled])
    }
    func elementsProperty(_ style: DevStyle, _ property: DevProperty, name: String?, value: String?) {
        var change: [String: Any] = ["key": style.id, "index": property.index]
        if let name { change["name"] = name }
        if let value { change["value"] = value }
        elementsEdit(change)
    }
    func elementsAddProperty(_ style: DevStyle, name: String, value: String) {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        elementsEdit(["key": style.id, "add": true, "name": name, "value": value])
    }
    /// A declaration changed through WebKit's model, which writes the
    /// rule's text; the sheet's new text is kept for Save CSS.
    private func elementsEdit(_ change: [String: Any]) {
        guard let model = workbench else { return }
        let id = model.selectedNode
        workCall("elements.prop", change) { [weak self, weak model] value in
            if let sheet = value as? [String: Any], let url = sheet["url"] as? String, let text = sheet["text"] as? String, !url.isEmpty {
                model?.styleEdits[url] = text
                model?.changes.removeAll { $0.name == url }
                model?.changes.append(DevProperty(name: url, value: text))
            }
            self?.elementsSelect(id)
        }
    }
    /// A rule's or a listener's place, opened in Sources at its line.
    func elementsOpenSource(_ url: String, line: Int) {
        guard let model = workbench else { return }
        func open() -> Bool {
            guard let file = model.sources.first(where: { $0.url == url }) else { return false }
            pickDevPane(.sources); sourceOpen(file, line: max(0, line - 1)); return true
        }
        if open() { return }
        workCall("sources.files") { [weak self, weak model] value in
            model?.sources = (value as? [[String: Any]] ?? []).map { DevSource(script: $0["id"] as? String ?? "", url: $0["url"] as? String ?? "",
                                                                                target: $0["target"] as? String ?? "", frame: $0["frame"] as? String ?? "", kind: $0["type"] as? String ?? "script") }.sorted { $0.url < $1.url }
            if !open(), let address = URL(string: url) { _ = self?.open(address, foreground: true, from: self?.toolsFront) }
        }
    }
    func elementsOverlay(_ box: DevLayoutBox, on: Bool) {
        guard let model = workbench else { return }
        if on { model.overlays.insert(box.id) } else { model.overlays.remove(box.id) }
        showOverlay(box, on: on)
    }
    func elementsOverlaysRedraw() {
        guard let model = workbench else { return }
        for box in model.layoutBoxes where model.overlays.contains(box.id) { showOverlay(box, on: true) }
    }
    private func showOverlay(_ box: DevLayoutBox, on: Bool) {
        let defaults = Store.settings
        if box.kind == "grid" {
            guard on else { workCall("DOM.hideGridOverlay", ["nodeId": box.id]); return }
            let labels = defaults.string(forKey: "devGridLabels") ?? "numbers"
            workCall("DOM.showGridOverlay", ["nodeId": box.id, "gridOverlayConfig": [
                "gridColor": ["r": 147, "g": 51, "b": 234, "a": 0.9], "showLineNumbers": labels == "numbers", "showLineNames": labels == "names",
                "showTrackSizes": defaults.bool(forKey: "devGridTracks"), "showAreaNames": defaults.bool(forKey: "devGridAreas"),
                "showExtendedGridLines": defaults.bool(forKey: "devGridExtend")] as [String: Any]])
        } else {
            guard on else { workCall("DOM.hideFlexOverlay", ["nodeId": box.id]); return }
            workCall("DOM.showFlexOverlay", ["nodeId": box.id, "flexOverlayConfig": ["flexColor": ["r": 147, "g": 51, "b": 234, "a": 0.9], "showOrderNumbers": true] as [String: Any]])
        }
    }
    func elementsListener(_ row: DevListener, enabled: Bool) {
        let id = workbench?.selectedNode ?? 0
        workCall("DOM.setEventListenerDisabled", ["eventListenerId": row.id, "disabled": !enabled]) { [weak self] _ in self?.elementsSelect(id) }
    }
    /// Break on: a DOM breakpoint on a node set or taken away.
    func elementsBreak(_ node: Int, _ type: String, on: Bool) {
        guard let model = workbench else { return }
        workCall(on ? "DOMDebugger.setDOMBreakpoint" : "DOMDebugger.removeDOMBreakpoint", ["nodeId": node, "type": type])
        model.domBreaks.removeAll { $0.node == node && $0.type == type }
        if on, let found = model.node(node) { model.domBreaks.append(DevDOMBreak(node: node, type: type, label: DevTreeLine.crumb(found))) }
    }
    func elementsBreakEnable(_ mark: DevDOMBreak, on: Bool) {
        guard let model = workbench, let at = model.domBreaks.firstIndex(where: { $0.id == mark.id }) else { return }
        workCall(on ? "DOMDebugger.setDOMBreakpoint" : "DOMDebugger.removeDOMBreakpoint", ["nodeId": mark.node, "type": mark.type])
        model.domBreaks[at].enabled = on
    }
}
