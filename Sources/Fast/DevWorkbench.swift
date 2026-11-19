import AppKit
import SwiftUI
import WebKit

struct DevDOMNode: Codable, Identifiable {
    var id: Int
    var type: Int
    var label: String
    var count: Int
    var children: [DevDOMNode]
    /// The name as Chromium writes it: an HTML element's tag in lower case,
    /// `::before` for a pseudo-element, the doctype's `html`.
    var name: String?
    /// The attributes in their order, as name and value.
    var attrs: [[String]]?
    /// A text's or a comment's words, a shadow root's mode, the document's address.
    var value: String?
    /// "grid" or "flex" for a box laid out so, as Chromium's badge says.
    var layout: String?
    /// A plain loop: `children.lazy.compactMap { $0.find(id) }.first` ran the
    /// search twice on every level down to the node (startIndex, then the
    /// subscript), 2^depth calls, minutes on X's 40-deep tree.
    func find(_ id: Int) -> DevDOMNode? {
        if self.id == id { return self }
        for child in children { if let found = child.find(id) { return found } }
        return nil
    }
    var tag: String { name ?? label }
    func attribute(_ key: String) -> String? { attrs?.first { $0.first == key }.flatMap { $0.count > 1 ? $0[1] : "" } }
}

struct DevProperty: Identifiable {
    var id: String { "\(index):\(name)" }
    var name: String
    var value: String
    var declaration = ""
    var disabled = false
    var inactive = false
    /// Its place in its rule, as WebKit counts the rule's declarations.
    var index = 0
    /// Another rule's declaration wins over it.
    var overridden = false
    /// In an inherited rule, a property that doesn't inherit: shown faint.
    var dim = false
    /// A shorthand's longhands, and whether they are shown under it.
    var longhands: [DevProperty] = []
    var expanded = false
}

/// A rule of Styles: the node's own (element.style, its rules, its
/// attributes' style) or an ancestor's, inherited.
struct DevStyle: Identifiable {
    var id: String
    var selector: String
    var source: String
    var text: String
    var styleID: [String: Any]
    var properties: [DevProperty]
    var origin = ""
    /// The rule's line in its sheet, from 1; 0 where it has none.
    var line = 0
    /// The ancestor this rule is inherited from, as Chromium names it ("body").
    var inheritedFrom = ""
    /// inline, attributes, rule or pseudo.
    var kind = "rule"
    var editable = false

    /// Where a rule stands, as Chromium writes it: `style.css:12`, `(index):1`
    /// for the page's own document.
    static func place(_ source: String, line: Int, page: URL?) -> String {
        guard let url = URL(string: source) else { return source }
        let same = page.map { $0.host == url.host && $0.path == url.path } ?? false
        let name = same || url.lastPathComponent.isEmpty || url.lastPathComponent == "/" ? "(index)" : url.lastPathComponent
        return line > 0 ? "\(name):\(line)" : name
    }
}

/// What gave a computed property its value: the winning declaration.
struct DevTrace {
    var value: String
    var selector: String
    var source: String
    var line: Int
    var origin: String
}

/// A box laid out as a grid or a flexbox somewhere on the page, for Layout.
struct DevLayoutBox: Identifiable {
    var id: Int
    var kind: String
    var label: String
}

/// An event listener on the node or an ancestor, the page's own: yab's
/// relays run in a world of their own and aren't the page's.
struct DevListener: Identifiable {
    var id: Int
    var type: String
    var owner: String
    var ownerID: Int
    var capture: Bool
    var passive: Bool
    var once: Bool
    var disabled: Bool
    var handler: String
    var url: String
    var line: Int
    var marks: [String] { (capture ? ["capture"] : []) + (passive ? ["passive"] : []) + (once ? ["once"] : []) }
}

/// A DOM breakpoint, set from a node's Break on.
struct DevDOMBreak: Identifiable {
    var id: String { "\(node):\(type)" }
    var node: Int
    var type: String
    var label: String
    var enabled = true
    static let kinds: [(type: String, title: String)] = [("subtree-modified", "Subtree modifications"), ("attribute-modified", "Attribute modifications"), ("node-removed", "Node removal")]
}

/// A property of the node, as Properties lists them: its value in words
/// and, for an object, the object to open.
struct DevNodeProperty: Identifiable {
    var id: String { name }
    var name: String
    var preview: String
    var type: String
    var own: Bool
    var object: ConsoleValue?
    /// Hidden until Show all: null, undefined and functions.
    var quiet: Bool { type == "function" || preview == "null" || type == "undefined" || name.allSatisfy { $0.isUppercase || $0 == "_" } }
    var color: Color {
        switch type {
        case "string": ConsoleInk.string
        case "number", "bigint", "boolean": ConsoleInk.number
        case "undefined": Palette.muted
        default: preview == "null" ? Palette.muted : Palette.ink
        }
    }
}

/// A node of the accessibility tree, for Show accessibility tree.
struct DevAXNode: Identifiable {
    var id: Int
    var role: String
    var name: String
    var children: [DevAXNode]
}

struct DevSource: Identifiable, Hashable {
    var id: String { target + ":" + script + ":" + url }
    var script: String
    var url: String
    var target: String
    var frame: String
    var kind: String
    var name: String { URL(string: url)?.lastPathComponent.nonempty ?? URL(string: url)?.host() ?? url }
}

/// The files' answers as they come, in the order WebKit named the files.
@MainActor final class DevSearchGather {
    var files: [DevSearchFile?]
    var left: Int
    init(_ count: Int) { files = Array(repeating: nil, count: count); left = count }
}

/// A file Sources' search found its words in, and the lines.
struct DevSearchFile: Identifiable {
    var id: String { url }
    let url: String
    let frame: String
    let lines: [DevSearchLine]
    var name: String { URL(string: url)?.lastPathComponent.nonempty ?? URL(string: url)?.host() ?? url }
    var path: String {
        guard let parsed = URL(string: url) else { return url }
        let folder = parsed.deletingLastPathComponent().path()
        return (parsed.host() ?? "") + (folder == "/" ? "" : folder)
    }
}

struct DevSearchLine: Identifiable {
    var id: Int { number }
    /// From 0, as WebKit counts; shown from 1.
    let number: Int
    let text: String

    /// A minified file's line is one long one: the part round the first
    /// match, as Chromium cuts it.
    static func around(_ line: String, query: String, matchCase: Bool, regex: Bool) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > 160 else { return trimmed }
        let options: NSRegularExpression.Options = matchCase ? [] : [.caseInsensitive]
        let pattern = regex ? query : NSRegularExpression.escapedPattern(for: query)
        guard let found = (try? NSRegularExpression(pattern: pattern, options: options))?.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              let range = Range(found.range, in: trimmed) else { return String(trimmed.prefix(160)) + "…" }
        let start = trimmed.index(range.lowerBound, offsetBy: -60, limitedBy: trimmed.startIndex) ?? trimmed.startIndex
        let end = trimmed.index(range.upperBound, offsetBy: 100, limitedBy: trimmed.endIndex) ?? trimmed.endIndex
        return (start == trimmed.startIndex ? "" : "…") + trimmed[start..<end] + (end == trimmed.endIndex ? "" : "…")
    }
}

struct DevScope: Identifiable {
    var id: String { objectID }
    var name: String
    var objectID: String
}

struct DevCallFrame: Identifiable {
    var id: String
    var name: String
    var script: String
    var line: Int
    var column = 0
    var target: String
    var scopes: [DevScope]
    /// The file a source map names and the line in it, where the script
    /// has one: what Sources shows for the frame.
    var mappedURL = ""
    var mappedLine = 0
}

/// A file pretty printed by WebKit's formatter, and for each of its lines
/// where that line starts in the file as the page has it (line, column):
/// a breakpoint set on a line shown goes on the page's place, and a place
/// in the page's file (a paused frame, a breakpoint) is shown on its line.
struct DevPretty: Equatable {
    var text: String
    var back: [[Int]]

    /// The page's place for a line shown.
    func original(_ line: Int) -> (line: Int, column: Int) {
        guard back.indices.contains(line), back[line].count == 2 else { return (line, 0) }
        return (back[line][0], back[line][1])
    }

    /// The line shown for a place in the page's file: the last one starting
    /// at or before it.
    func shown(_ line: Int, column: Int = 0) -> Int {
        var low = 0, high = back.count - 1, found = 0
        while low <= high {
            let mid = (low + high) / 2
            let at = original(mid)
            if at.line < line || (at.line == line && at.column <= column) { found = mid; low = mid + 1 } else { high = mid - 1 }
        }
        return found
    }
}

struct DevBreakpoint: Identifiable {
    var id: String
    var url: String
    var line: Int
    /// Where on the line, for a line of a minified file set pretty printed.
    var column = 0
    var target: String
    var condition: String
    var enabled = true
}

struct DevTraceEvent: Identifiable {
    var id: Int
    var name: String
    var start: Double
    var end: Double
    var depth: Int
    var data: String
    var selfDuration = 0.0
    var duration: Double { max(0, (end - start) * 1000) }
    var color: Color {
        if name.contains("Layout") || name.contains("Style") { return .purple }
        if name.contains("Paint") || name.contains("Composite") { return .green }
        if name.contains("Script") || name.contains("Function") || name.contains("Event") { return .orange }
        return .blue
    }
}

struct DevHeapClass: Identifiable {
    var id: String { name }
    var name: String
    var count: Int
    var size: Int
    var retained: Int = 0
}

/// State belongs to the inspected tab, including debugger and recordings.
@MainActor @Observable final class DevWorkbench: DevWireListener {
    static let channel = "workbench"
    var root: DevDOMNode? { didSet { linesCache = nil; indexCache = nil } }
    var expanded: Set<Int> = [] { didSet { linesCache = nil } }
    var selectedNode = 0
    /// The node's closing tag is the line selected, as Chromium selects it
    /// (a click on it, ↓ from its last child).
    var selectedClose = false
    /// The lines shown, made once a change of the tree or of what is open:
    /// a hover, an answer of the sidebar, a find redraw the pane without
    /// walking the tree again (DevTree.swift).
    var treeLines: DevTreeLines {
        if let linesCache { return linesCache }
        let start = CACurrentMediaTime()
        let made = MainBudget.chunk("elements.lines") { DevTreeLines(DevTreeLine.lines(root, open: expanded)) }
        linesMade += 1
        linesMs = (CACurrentMediaTime() - start) * 1000
        linesCache = made
        return made
    }
    var treeIndex: DevTreeIndex {
        if let indexCache { return indexCache }
        let made = MainBudget.chunk("elements.index") { DevTreeIndex(root) }
        indexCache = made
        return made
    }
    @ObservationIgnored private var linesCache: DevTreeLines?
    @ObservationIgnored private var indexCache: DevTreeIndex?
    func node(_ id: Int) -> DevDOMNode? { treeIndex.nodes[id] }
    /// The tree's own view, for where it is in the window: keys are the
    /// tree's after a press in it, as in Chromium, where the tree has the focus.
    @ObservationIgnored weak var treeView: NSView?
    /// The tree in its window, AppKit's points from the bottom left.
    var treeRect: CGRect? { treeView.flatMap { $0.window == nil ? nil : $0.convert($0.bounds, to: nil) } }
    /// Selected from the keyboard: shown with the least scroll, as
    /// Chrome's scrollIntoViewIfNeeded.
    @ObservationIgnored var keySelected = false
    var elementsKeyReveal = 0
    /// The node last drawn on the page from Elements (0: none).
    @ObservationIgnored var hoverSent = 0
    /// Enter and F2 on the tree: the node's attributes, or its HTML, edited.
    var editRequest = 0
    var htmlRequest = 0
    @ObservationIgnored var editNode = 0
    /// Each pick, the same node picked again included.
    var pickSerial = 0
    /// A pick no pane has shown yet: it can arrive before Elements is on screen.
    @ObservationIgnored var pickUnseen = false
    /// For the bench: the last tree's parse, the lines' making, a select.
    @ObservationIgnored var loadMs = 0.0
    @ObservationIgnored var linesMs = 0.0
    @ObservationIgnored var linesMade = 0
    @ObservationIgnored var selectMs = 0.0
    /// Elements' sidebar tab, kept while other panels are in front.
    var elementsTab = "Styles"
    /// The panes' filter words (Styles, Computed, Properties, Sources'
    /// files), kept as the panes are made anew: another panel, another tab.
    var paneFilters: [String: String] = [:]
    /// Elements' find bar, under the tree (⌘F with the card focused).
    var elementsFind = false
    /// What Elements' find looks for, as typed; how many nodes WebKit
    /// found for the words it last looked for, and which one is shown.
    var elementsQuery = ""
    var elementsSearched = ""
    var elementsCount = 0
    var elementsMatch = 0
    @ObservationIgnored var elementsSearchSerial = 0
    /// The node the find shows now (its row alone is lit), and whether an
    /// answer is awaited (the count before it stands dimmed meanwhile).
    var elementsMatchNode = 0
    var elementsWaiting = false
    /// ⌘F again with the bar up: the field takes the keyboard, its words
    /// selected.
    var elementsFocus = 0
    /// Said when the selected node should come into view in the tree.
    var elementsReveal = 0
    /// The tree as it stood when its inspector was put away with another
    /// tab in front, shown meanwhile: the new inspector numbers nodes anew,
    /// so what was open, selected and at the top is found again in its
    /// tree by place (DevReturn.swift).
    @ObservationIgnored var keptTree: DevDOMNode?
    /// The tree's row at the top as last scrolled ("o12"), not published:
    /// only read back when the tree is shown again.
    @ObservationIgnored var elementsTop: String?
    /// Said when the top row should be put back at the top.
    var elementsTopReveal = 0
    /// The domRevision the tree in hand was fetched at, and whether a
    /// fetch is out (another asked meanwhile is made once it is back).
    @ObservationIgnored var treeRevision = -1
    @ObservationIgnored var treeFetching = false
    @ObservationIgnored var treeAgain = false
    /// No plain tree fetch before this (CACurrentMediaTime), and whether one
    /// is waiting for it.
    @ObservationIgnored var treeNext: CFTimeInterval = 0
    @ObservationIgnored var treeLater = false
    @ObservationIgnored var treeAnswered: CFTimeInterval = 0
    /// Trees fetched, for the bench; how long the last one and the last
    /// inspector's coming up took (ms), and whether that tree was a return.
    @ObservationIgnored var treeFetches = 0
    @ObservationIgnored var treeMs = 0.0
    @ObservationIgnored var connectMs = 0.0
    @ObservationIgnored var restoreMs = 0.0
    var computedFrom: [String: DevTrace] = [:]
    /// Computed properties some rule sets, Computed's list without Show all.
    var computedSet: Set<String> = []
    var listenerRows: [DevListener] = []
    var domBreaks: [DevDOMBreak] = []
    var layoutBoxes: [DevLayoutBox] = []
    var overlays: Set<Int> = []
    var nodeProperties: [DevNodeProperty] = []
    var ax: [String: Any] = [:]
    var axTreeShown = false
    var axRoot: DevAXNode?
    /// States forced on the selected node (:hov), and classes turned off (.cls).
    var forced: Set<String> = []
    var offClasses: [String] = []
    var styles: [DevStyle] = []
    var computed: [DevProperty] = []
    var accessibility: [DevProperty] = []
    var listeners: [DevProperty] = []
    var properties: [DevProperty] = []
    var comments: [DevComment] = []
    var nodeObject: ConsoleValue?
    var domRevision = 0
    var navigationRevision = 0
    var layerRevision = 0
    var pickedNode = 0
    var picking = false
    /// A Styles name or value being edited where it stands: Escape is its
    /// own then (the edit put back), not the drawer's. Drawn by nothing.
    @ObservationIgnored var styleEditing = false
    /// What Styles offers for the words being typed, for the bench.
    @ObservationIgnored var styleCompletions: [String] = []
    var sources: [DevSource] = []
    var source: DevSource?
    /// Sources' search through every file the page loaded (⌘F out of the
    /// editor, ⌥⌘F from any panel): the words, and how many times each
    /// file has them, by address, its frame to ask for the lines.
    var sourcesFind = false
    var sourcesQuery = ""
    var sourcesFound: [String: Int] = [:]
    var sourcesSearched = ""
    var sourcesFocus = 0
    @ObservationIgnored var sourcesFoundFrames: [String: String] = [:]
    @ObservationIgnored var sourcesSerial = 0
    var sourcesCase = false
    var sourcesRegex = false
    var sourcesResults: [DevSearchFile] = []
    /// The search's last line: how many it found, or why it found none.
    var sourcesNote = ""
    var sourcesShut: Set<String> = []
    var sourcesPicked = ""
    @ObservationIgnored weak var sourceEditor: WKWebView?
    var sourceText = ""
    var originalSourceText = ""
    var openSources: [DevSource] = []
    @ObservationIgnored var sourceBuffers: [String: (text: String, original: String)] = [:]
    var styleEdits: [String: String] = [:]
    var workspace: URL?
    var changes: [DevProperty] = []
    var sourceLine = 0
    /// The column on `sourceLine` a paused frame is at: on a minified
    /// file's one long line, what says where it is once pretty printed.
    var sourceColumn = 0
    /// Files shown pretty printed ({ }), by address.
    var pretty: [String: DevPretty] = [:]
    var breakpoints: [DevBreakpoint] = []
    var frames: [DevCallFrame] = []
    var frameID = ""
    var scopeProperties: [DevProperty] = []
    var pauseReason = ""
    var watch: [DevProperty] = []
    var recording = false
    var trace: [DevTraceEvent] = []
    var metrics: [DevProperty] = []
    var memorySamples: [DevMemorySample] = []
    var storage: [DevProperty] = []
    var cookies: [[String: Any]] = []
    var applicationInfo: [String: Any] = [:]
    var applicationSection = "Local storage"
    let application = DevApplicationModel()
    var heap: [DevHeapClass] = []
    var heapSnapshots: [(name: String, classes: [DevHeapClass], total: Int, raw: String)] = []
    var audit: [DevProperty] = []
    var auditReport = ""
    @ObservationIgnored var auditPreviousDevice: DeviceMode?
    @ObservationIgnored var auditHasDeviceOverride = false
    var error = ""
    var busy = false
    @ObservationIgnored var traceRaw: [[String: Any]] = []
    let heapEngine = DevHeapEngine()
    @ObservationIgnored var heapRaw = ""
    @ObservationIgnored var installedIgnorePatterns: [String] = []
    init() {}

    func hear(_ json: String) {
        guard let items = Self.parse(json) as? [[String: Any]] else { return }
        for item in items {
            switch item["kind"] as? String {
            case "navigation":
                error = ""; navigationRevision += 1
                picking = false; pickUnseen = false
                root = nil; keptTree = nil; selectedNode = 0; selectedClose = false; hoverSent = 0; expanded = []; styles = []; computed = []; accessibility = []; listeners = []; properties = []; nodeObject = nil
                computedFrom = [:]; listenerRows = []; domBreaks = []; layoutBoxes = []; overlays = []; nodeProperties = []; ax = [:]; axRoot = nil; forced = []; offClasses = []
                sourceBuffers = sourceBuffers.filter { $0.value.text != $0.value.original }; openSources = []
                source = nil; sourceText = ""; originalSourceText = ""; sources = []; frames = []; frameID = ""; scopeProperties = []; pretty = [:]
                domRevision += 1
            case "domChanged": domRevision += 1
            case "layers": layerRevision += 1
            case "picking": picking = item["on"] as? Bool ?? false
            case "picked": pickedNode = item["id"] as? Int ?? 0; pickUnseen = true; pickSerial += 1
            case "paused":
                pauseReason = item["reason"] as? String ?? "Paused"
                frames = (item["frames"] as? [[String: Any]] ?? []).map { frame in
                    let location = frame["location"] as? [String: Any] ?? [:]
                    let scopes = (frame["scopeChain"] as? [[String: Any]] ?? []).map { scope -> DevScope in
                        let object = scope["object"] as? [String: Any] ?? [:]
                        return DevScope(name: scope["name"] as? String ?? scope["type"] as? String ?? "Scope", objectID: object["objectId"] as? String ?? "")
                    }
                    let mapped = frame["mapped"] as? [String: Any] ?? [:]
                    return DevCallFrame(id: frame["callFrameId"] as? String ?? "", name: frame["functionName"] as? String ?? "(anonymous)",
                                        script: location["scriptId"] as? String ?? "", line: location["lineNumber"] as? Int ?? 0,
                                        column: location["columnNumber"] as? Int ?? 0, target: frame["target"] as? String ?? "", scopes: scopes,
                                        mappedURL: mapped["url"] as? String ?? "", mappedLine: mapped["line"] as? Int ?? 0)
                }
                frameID = frames.first?.id ?? ""
            case "resumed": frames = []; frameID = ""; scopeProperties = []; pauseReason = ""
            case "trace": appendTrace(item["records"] as? [[String: Any]] ?? [])
            case "memory": if let sample = item["sample"] as? [String: Any], let row = DevMemorySample(sample) { memorySamples.append(row) }
            default: break
            }
        }
    }

    /// Up anew on another document: the node numbers are the new
    /// inspector's, so nothing stays selected or open by the old ones.
    func connected() { root = nil; keptTree = nil; treeFetching = false; selectedNode = 0; selectedClose = false; hoverSent = 0; expanded = []; elementsTop = nil; frames = []; domRevision += 1; navigationRevision += 1; error = "" }
    /// Up again on the same document: the tree stays shown until the new
    /// inspector's is in, then found again on its numbers.
    func reconnected() {
        if keptTree == nil { keptTree = root }
        treeFetching = false; frames = []; domRevision += 1; navigationRevision += 1; error = ""
    }
    static func parse(_ text: String) -> Any? { text.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) } }
    static func string(_ value: Any?) -> String {
        guard let value else { return "" }
        if let s = value as? String { return s }
        if let d = value as? [String: Any], let type = d["type"] as? String,
           ["object", "function", "undefined", "number", "string", "boolean", "symbol", "bigint"].contains(type) {
            return d["description"] as? String ?? d["value"].map { string($0) } ?? type
        }
        return json(value, pretty: false)
    }
    static func json(_ value: Any?, pretty: Bool = true) -> String {
        guard let value else { return "" }
        var options: JSONSerialization.WritingOptions = [.fragmentsAllowed, .sortedKeys]
        if pretty { options.insert(.prettyPrinted) }
        if let data = try? JSONSerialization.data(withJSONObject: value, options: options), let text = String(data: data, encoding: .utf8) { return text }
        return String(describing: value)
    }
    static func props(_ rows: [[String: Any]]) -> [DevProperty] {
        rows.map { DevProperty(name: $0["name"] as? String ?? "", value: string($0["value"])) }
    }
    /// True when it found a kept tree again (restore).
    @discardableResult func loadTree(_ value: Any?) -> Bool {
        let start = CACurrentMediaTime()
        guard let node = MainBudget.chunk("elements.parse", { DevDOMNode(json: value) }) else { return false }
        loadMs = (CACurrentMediaTime() - start) * 1000
        if let kept = keptTree { keptTree = nil; restore(from: kept, into: node); return true }
        if let root, root.id != node.id { expanded = []; selectedNode = 0; styles = []; computed = [] }
        root = node
        if expanded.isEmpty { expanded.insert(node.id); expanded.formUnion(node.children.filter { $0.type == 1 }.map(\.id)) }
        return false
    }
    func revealNode(_ id: Int) {
        let ids = treeIndex.path(to: id).dropLast()
        if !ids.isEmpty, !expanded.isSuperset(of: ids) { expanded.formUnion(ids) }
    }
    /// What `elements.select` says of the selected node: its rules in
    /// cascade order, the computed values and what set them, its
    /// accessibility and its listeners.
    func loadStyles(_ value: Any?) {
        guard let data = value as? [String: Any] else { return }
        let open = Set(styles.flatMap { style in style.properties.filter(\.expanded).map { style.id + ":" + $0.name } })
        func property(_ row: [String: Any], _ style: String) -> DevProperty {
            var p = DevProperty(name: row["name"] as? String ?? "", value: row["value"] as? String ?? "", declaration: row["text"] as? String ?? "",
                                disabled: row["enabled"] as? Bool == false, inactive: row["valid"] as? Bool == false, index: row["index"] as? Int ?? 0,
                                overridden: row["overridden"] as? Bool ?? false, dim: row["dim"] as? Bool ?? false)
            p.longhands = (row["longhands"] as? [[String: Any]] ?? []).enumerated().map { i, long in
                DevProperty(name: long["name"] as? String ?? "", value: long["value"] as? String ?? "", index: i, overridden: long["overridden"] as? Bool ?? false, dim: p.dim)
            }
            p.expanded = open.contains(style + ":" + p.name)
            return p
        }
        styles = (data["styles"] as? [[String: Any]] ?? []).map { row in
            let key = row["key"] as? String ?? UUID().uuidString
            return DevStyle(id: key, selector: row["selector"] as? String ?? "", source: row["source"] as? String ?? "",
                            text: row["text"] as? String ?? "", styleID: row["styleId"] as? [String: Any] ?? [:],
                            properties: (row["properties"] as? [[String: Any]] ?? []).map { property($0, key) },
                            origin: row["origin"] as? String ?? "", line: row["line"] as? Int ?? 0,
                            inheritedFrom: row["inheritedFrom"] as? String ?? "", kind: row["kind"] as? String ?? "rule",
                            editable: row["editable"] as? Bool ?? false)
        }
        computed = Self.props(data["computed"] as? [[String: Any]] ?? []).sorted { $0.name < $1.name }
        computedSet = Set((data["computed"] as? [[String: Any]] ?? []).filter { $0["implicit"] as? Bool == false }.compactMap { $0["name"] as? String })
        computedFrom = (data["from"] as? [String: [String: Any]] ?? [:]).mapValues {
            DevTrace(value: $0["value"] as? String ?? "", selector: $0["selector"] as? String ?? "", source: $0["source"] as? String ?? "",
                     line: $0["line"] as? Int ?? 0, origin: $0["origin"] as? String ?? "")
        }
        ax = data["accessibility"] as? [String: Any] ?? [:]
        accessibility = ax.keys.sorted().map { DevProperty(name: $0, value: Self.string(ax[$0])) }
        listenerRows = (data["listeners"] as? [[String: Any]] ?? []).map { row in
            DevListener(id: row["id"] as? Int ?? 0, type: row["type"] as? String ?? "event", owner: row["owner"] as? String ?? "",
                        ownerID: row["ownerId"] as? Int ?? 0, capture: row["useCapture"] as? Bool ?? false, passive: row["passive"] as? Bool ?? false,
                        once: row["once"] as? Bool ?? false, disabled: row["disabled"] as? Bool ?? false, handler: row["handler"] as? String ?? "",
                        url: row["url"] as? String ?? "", line: row["line"] as? Int ?? 0)
        }
        listeners = listenerRows.map { DevProperty(name: $0.type, value: ([$0.owner, $0.handler] + $0.marks).filter { !$0.isEmpty }.joined(separator: " · ")) }
    }
    func toggleLonghands(_ style: String, _ index: Int) {
        guard let s = styles.firstIndex(where: { $0.id == style }), let p = styles[s].properties.firstIndex(where: { $0.index == index }) else { return }
        styles[s].properties[p].expanded.toggle()
    }
    func appendTrace(_ records: [[String: Any]]) {
        traceRaw += records
        func add(_ r: [String: Any], _ depth: Int) {
            let start = r["startTime"] as? Double ?? 0
            let end = r["endTime"] as? Double ?? start
            let children = r["children"] as? [[String: Any]] ?? []
            let spans: [(Double, Double)] = children.compactMap { child in
                let a = max(start, child["startTime"] as? Double ?? start)
                let b = min(end, child["endTime"] as? Double ?? a)
                return b > a ? (a, b) : nil
            }.sorted { $0.0 < $1.0 }
            var covered = 0.0, lastEnd = start
            for span in spans { covered += max(0, span.1 - max(lastEnd, span.0)); lastEnd = max(lastEnd, span.1) }
            trace.append(DevTraceEvent(id: trace.count, name: r["type"] as? String ?? "Event", start: start, end: end,
                                       depth: depth, data: Self.string(r["data"]), selfDuration: max(0, end - start - covered) * 1000))
            for child in children { add(child, depth + 1) }
        }
        for r in records { add(r, 0) }
    }
}

private extension String { var nonempty: String? { isEmpty ? nil : self } }

extension Browser {
    var workbench: DevWorkbench? { toolsFront?.devModel(DevWorkbench.self) }
    func workCall(_ method: String, _ params: [String: Any] = [:], done: @escaping (Any?) -> Void = { _ in }) {
        guard let model = workbench else { return }
        if !["performance.metrics", "elements.tree", "application.info", "tools.performanceMonitor", "tools.media"].contains(method) { model.error = "" }
        let navigation = model.navigationRevision
        var finished = false
        wire(method, params, failed: { [weak model] error in
            guard !finished else { return }; finished = true
            if model?.navigationRevision == navigation { model?.error = error; model?.busy = false }; done(nil)
        }) { [weak model] value in
            guard !finished else { return }; finished = true
            // When the answer came, its parse included: what a tree costs.
            if method == "elements.tree" { model?.treeAnswered = CACurrentMediaTime() }
            let decoded = (value as? String).flatMap(DevWorkbench.parse) ?? value
            done(decoded)
        }
    }
    func elementsRefresh(expand: Int? = nil, reload: Bool = false) {
        // Its inspector still coming up: asked for once it is (inspectorReady).
        guard let model = workbench, !(inspected === toolsFront && !inspectorLive) else { return }
        var params: [String: Any] = ["reload": reload]
        // A kept tree: the new inspector's with every path to what was open,
        // selected and at the top loaded, to be found again.
        if let kept = model.keptTree { params["open"] = model.keptPaths(kept) } else if let expand { params["expand"] = expand }
        // The same plain fetch asked again while one is out (the pane shown,
        // the DOM changed, the inspector up): one more once it is back.
        let plain = expand == nil && !reload
        if plain {
            if model.treeFetching { model.treeAgain = true; return }
            // A page that never stops changing (X's timeline): the tree again
            // no sooner than four times what the last one cost the main
            // thread, so that refreshing it never takes more than a fifth.
            let wait = model.treeNext - CACurrentMediaTime()
            if wait > 0 {
                if !model.treeLater {
                    model.treeLater = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self, weak model] in
                        model?.treeLater = false
                        self?.elementsRefresh()
                    }
                }
                return
            }
            model.treeFetching = true
        }
        model.treeFetches += 1
        let asked = CACurrentMediaTime(), returning = model.keptTree != nil
        workCall("elements.tree", params) { [weak self, weak model] value in
            guard let self, let model else { return }
            if plain { model.treeFetching = false }
            guard model === self.workbench else { return }
            model.treeMs = (CACurrentMediaTime() - asked) * 1000
            if returning { model.restoreMs = model.treeMs }
            if value != nil { model.treeRevision = model.domRevision }
            let start = min(model.treeAnswered, CACurrentMediaTime())
            if model.loadTree(value) { self.elementsReturned() } else { self.elementsStart() }
            _ = model.treeLines
            model.treeNext = CACurrentMediaTime() + 4 * (CACurrentMediaTime() - start)
            // The pane drawn anew is the bigger part: counted once it is done,
            // the next pass of the run loop.
            DispatchQueue.main.async { [weak model] in model?.treeNext = CACurrentMediaTime() + 4 * (CACurrentMediaTime() - start) }
            if plain, model.treeAgain { model.treeAgain = false; self.elementsRefresh() }
        }
    }

    /// As Chromium opens Elements, and after each navigation: html and body
    /// open, body selected and in view, unless a node is selected already
    /// (Inspect Element's).
    func elementsStart() {
        guard let model = workbench, model.selectedNode == 0, let root = model.root else { return }
        let html = root.children.first { $0.type == 1 && $0.tag == "html" }
        guard let html, let body = html.children.first(where: { $0.type == 1 && $0.tag == "body" }) else { return }
        model.expanded.formUnion([root.id, html.id, body.id])
        elementsSelect(body.id)
        model.elementsReveal += 1
        if body.children.isEmpty, body.count > 0 { elementsRefresh(expand: body.id) }
    }
    /// Elements' find, as Chromium's, as the words are typed: WebKit's own
    /// finder (tag names, attributes, text, a CSS selector, an XPath, in
    /// every frame of the page), the first node found shown at once.
    /// `keep`: looked for again as the page changed, staying on the node
    /// shown when it is still found.
    func elementsSearch(_ query: String, keep: Bool = false) {
        guard let model = workbench else { return }
        model.elementsSearchSerial += 1
        let serial = model.elementsSearchSerial
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else {
            model.elementsSearched = ""; model.elementsCount = 0; model.elementsMatch = 0
            model.elementsMatchNode = 0; model.elementsWaiting = false
            workCall("elements.searchEnd")
            return
        }
        if !keep { model.elementsWaiting = true }
        var params: [String: Any] = ["query": words]
        if keep, model.elementsMatchNode != 0 { params["keep"] = model.elementsMatchNode }
        workCall("elements.search", params) { [weak self, weak model] value in
            guard let self, let model, model.elementsSearchSerial == serial else { return }
            let data = value as? [String: Any]
            model.elementsWaiting = false
            model.elementsSearched = words
            model.elementsCount = data?["count"] as? Int ?? 0
            if keep {
                // Still found: the same node, at its new place. Gone: the
                // count stands without a current one, nothing moves.
                let at = data?["at"] as? Int ?? -1
                model.elementsMatch = at
                if at < 0 { model.elementsMatchNode = 0 }
                return
            }
            model.elementsMatch = 0
            model.elementsMatchNode = 0
            if model.elementsCount > 0 { self.elementsShowMatch(0) }
        }
    }

    /// The next found node or the one before (Return, Shift-Return, ⌘G,
    /// Shift-⌘G, the arrows), round.
    func elementsStep(_ by: Int) {
        guard let model = workbench, model.elementsCount > 0, !model.elementsWaiting else { return }
        let from = model.elementsMatch < 0 ? (by > 0 ? -1 : 0) : model.elementsMatch
        elementsShowMatch((from + by + model.elementsCount) % model.elementsCount)
    }

    /// A found node by its place among them: fetched from WebKit, the
    /// path to it opened in the tree (a frame's #document too), selected,
    /// in view, and shown on the page as when its row is pointed at.
    func elementsShowMatch(_ index: Int) {
        guard let model = workbench else { return }
        model.elementsMatch = index
        let serial = model.elementsSearchSerial
        workCall("elements.searchResult", ["index": index]) { [weak self, weak model] value in
            guard let self, let model, model.elementsSearchSerial == serial, model.elementsMatch == index,
                  let data = value as? [String: Any], let id = data["id"] as? Int, id != 0 else { return }
            let path = data["path"] as? [Int] ?? []
            let show = { [weak self, weak model] in
                guard let model else { return }
                model.expanded.formUnion(path)
                model.elementsMatchNode = id
                self?.elementsSelect(id)
                model.elementsReveal += 1
                self?.elementsHighlight(id)
            }
            if model.node(id) != nil { show(); return }
            self.workCall("elements.tree") { [weak model] tree in model?.loadTree(tree); show() }
        }
    }

    /// Esc or the bar's ×: the bar away, its marks with it, the node found
    /// stays selected and the words are kept for the next ⌘F.
    func elementsFindClosed() {
        guard let model = workbench else { return }
        model.elementsSearchSerial += 1
        model.elementsSearched = ""; model.elementsCount = 0; model.elementsMatch = 0
        model.elementsMatchNode = 0; model.elementsWaiting = false
        workCall("elements.searchEnd")
        elementsHighlight(0)
    }

    func elementsSelect(_ id: Int, close: Bool = false) {
        guard let model = workbench else { return }
        let start = CACurrentMediaTime()
        defer { model.selectMs = (CACurrentMediaTime() - start) * 1000 }
        if model.selectedClose != close { model.selectedClose = close }
        model.selectedNode = id
        if model.keptTree == nil, model.node(id) != nil { model.revealNode(id) }
        else {
            // The picker's node arrives with its path already in WebKit's
            // tree: the tree as known has it. The whole page (one call a
            // node, seconds on a big one) only when it doesn't.
            let found = { [weak model] (value: Any?) -> Bool in
                guard let model else { return true }
                model.loadTree(value)
                guard model.node(id) != nil else { return false }
                model.selectedNode = id; model.revealNode(id); model.elementsReveal += 1
                return true
            }
            workCall("elements.tree") { [weak self] value in
                if !found(value) { self?.workCall("elements.tree", ["deep": true]) { _ = found($0) } }
            }
        }
        workCall("elements.select", ["id": id]) { [weak model] in model?.loadStyles($0) }
    }
    func sourceOpen(_ file: DevSource, line: Int = 0) {
        guard let model = workbench else { return }
        if let previous = model.source { model.sourceBuffers[previous.url] = (model.sourceText, model.originalSourceText) }
        model.source = file; model.sourceLine = line; model.sourceColumn = 0
        if !model.openSources.contains(where: { $0.url == file.url }) { model.openSources.append(file) }
        if let buffer = model.sourceBuffers[file.url] { model.sourceText = buffer.text; model.originalSourceText = buffer.original; return }
        workCall("sources.content", ["id": file.script, "url": file.url, "target": file.target, "frame": file.frame]) { [weak model] value in
            guard model?.source?.url == file.url else { return }
            let text = (value as? [String: Any])?["scriptSource"] as? String ?? ""
            model?.sourceText = text; model?.originalSourceText = text
            model?.sourceBuffers[file.url] = (text, text)
        }
    }
    /// ⌘F in Sources, ⌥⌘F anywhere in the card: the search over every
    /// file, its field taking the keyboard.
    func sourcesFind() {
        guard let model = workbench else { return }
        model.sourcesFind = true
        model.sourcesFocus += 1
    }

    /// Every file the page loaded looked through, as Chromium's Search: each
    /// one that has the words lit in the list, with how many times.
    /// Every file the page loaded looked through, as Chromium's Search
    /// (⌥⌘F): the case and a regular expression as asked, each file with
    /// its matching lines, numbered.
    func sourcesSearch(_ query: String) {
        guard let model = workbench else { return }
        model.sourcesSerial += 1
        let serial = model.sourcesSerial
        let matchCase = model.sourcesCase, regex = model.sourcesRegex
        guard !query.isEmpty else {
            model.sourcesFound = [:]; model.sourcesSearched = ""; model.sourcesResults = []; model.sourcesNote = ""
            return
        }
        if regex, (try? NSRegularExpression(pattern: query)) == nil {
            model.sourcesResults = []; model.sourcesFound = [:]; model.sourcesSearched = ""
            model.sourcesNote = "Invalid regular expression"
            return
        }
        model.sourcesNote = "Searching…"
        let ask: [String: Any] = ["caseSensitive": matchCase, "isRegex": regex]
        workCall("Page.searchInResources", ask.merging(["text": query]) { $1 }) { [weak self, weak model] value in
            guard let self, let model, model.sourcesSerial == serial else { return }
            var order: [(url: String, frame: String)] = []
            for hit in (value as? [String: Any])?["result"] as? [[String: Any]] ?? [] {
                guard let url = hit["url"] as? String, !order.contains(where: { $0.url == url }) else { continue }
                order.append((url, hit["frameId"] as? String ?? ""))
            }
            order = Array(order.prefix(200))
            let gather = DevSearchGather(order.count)
            @MainActor func finish() {
                let found = gather.files.compactMap { $0 }.filter { !$0.lines.isEmpty }
                model.sourcesResults = found
                model.sourcesFound = Dictionary(found.map { ($0.url, $0.lines.count) }) { a, _ in a }
                model.sourcesFoundFrames = Dictionary(found.map { ($0.url, $0.frame) }) { a, _ in a }
                model.sourcesSearched = query
                let lines = found.reduce(0) { $0 + $1.lines.count }
                model.sourcesNote = lines == 0 ? "No matches found."
                    : "Search finished. Found \(lines.formatted()) matching line\(lines == 1 ? "" : "s") in \(found.count) file\(found.count == 1 ? "" : "s")."
            }
            if order.isEmpty { finish(); return }
            for (index, file) in order.enumerated() {
                self.workCall("Page.searchInResource", ask.merging(["frameId": file.frame, "url": file.url, "query": query]) { $1 }) { [weak model] value in
                    guard let model, model.sourcesSerial == serial else { return }
                    let rows = (value as? [String: Any])?["result"] as? [[String: Any]] ?? []
                    let lines = rows.prefix(100).map { row in
                        DevSearchLine(number: ((row["lineNumber"] as? NSNumber)?.intValue ?? 0),
                                      text: DevSearchLine.around(row["lineContent"] as? String ?? "", query: query, matchCase: matchCase, regex: regex))
                    }
                    gather.files[index] = DevSearchFile(url: file.url, frame: file.frame, lines: Array(lines))
                    gather.left -= 1
                    if gather.left == 0 { finish() }
                }
            }
        }
    }

    /// A line the search found: its file opened on it.
    func sourceOpenFound(_ url: String, line: Int) {
        guard let model = workbench else { return }
        let file = model.sources.first { $0.url == url }
            ?? DevSource(script: "", url: url, target: "", frame: model.sourcesFoundFrames[url] ?? "", kind: url.hasSuffix(".css") ? "stylesheet" : "script")
        model.sourcesPicked = "\(url)#\(line)"
        if model.source?.url == url { model.sourceLine = line } else { sourceOpen(file, line: line) }
    }

    /// A file the list at the side lit: opened on its first line found.
    func sourceOpenFound(_ file: DevSource) {
        let first = workbench?.sourcesResults.first { $0.url == file.url }?.lines.first?.number ?? 0
        sourceOpenFound(file.url, line: first)
    }

    func sourcesRefresh() {
        workCall("sources.files") { [weak self] value in
            self?.workbench?.sources = (value as? [[String: Any]] ?? []).map { DevSource(script: $0["id"] as? String ?? "", url: $0["url"] as? String ?? "",
                                                                                    target: $0["target"] as? String ?? "", frame: $0["frame"] as? String ?? "", kind: $0["type"] as? String ?? "script") }.sorted { $0.url < $1.url }
        }
    }
    /// { } on the file open: shown pretty printed, as WebKit's formatter
    /// writes it, or as the page has it again.
    func sourcesPretty() {
        guard let model = workbench, let file = model.source else { return }
        if model.pretty[file.url] != nil { model.pretty[file.url] = nil; return }
        let ext = URL(string: file.url)?.pathExtension.lowercased() ?? "js"
        workCall("sources.pretty", ["text": model.originalSourceText, "language": ext == "css" ? "css" : "js"]) { [weak model] value in
            guard let model, let answer = value as? [String: Any], let text = answer["text"] as? String else { return }
            model.pretty[file.url] = DevPretty(text: text, back: answer["back"] as? [[Int]] ?? [])
        }
    }

    /// A breakpoint on a line shown: pretty printed, the page's place for it.
    func sourcesBreakpoint(shown line: Int) {
        guard let model = workbench, let file = model.source, let pretty = model.pretty[file.url] else { sourcesBreakpoint(line); return }
        let at = pretty.original(line)
        sourcesBreakpoint(at.line, column: at.column)
    }

    func sourcesBreakpoint(_ line: Int, column: Int = 0, condition: String = "", logpoint: String = "") {
        guard let model = workbench, let file = model.source else { return }
        if let existing = model.breakpoints.first(where: { $0.url == file.url && $0.line == line && $0.column == column }) {
            workCall("Debugger.removeBreakpoint", ["breakpointId": existing.id, "__target": existing.target]) { [weak model] _ in model?.breakpoints.removeAll { $0.id == existing.id } }
            return
        }
        workCall("sources.breakpoint", ["url": file.url, "line": line, "column": column, "condition": condition, "logpoint": logpoint, "target": file.target]) { [weak model] value in
            guard let id = (value as? [String: Any])?["breakpointId"] as? String else { return }
            model?.breakpoints.append(DevBreakpoint(id: id, url: file.url, line: line, column: column, target: file.target, condition: condition))
        }
    }
    func sourcesFrame(_ frame: DevCallFrame) {
        guard let model = workbench else { return }
        model.frameID = frame.id
        if !frame.mappedURL.isEmpty, let file = model.sources.first(where: { $0.url == frame.mappedURL }) { sourceOpen(file, line: frame.mappedLine) }
        else if let file = model.sources.first(where: { $0.script == frame.script && $0.target == frame.target }) { sourceOpen(file, line: frame.line); model.sourceColumn = frame.column }
        if let scope = frame.scopes.first {
            workCall("sources.scope", ["objectId": scope.objectID, "target": frame.target]) { [weak model] value in
                model?.scopeProperties = DevWorkbench.props((value as? [String: Any])?["properties"] as? [[String: Any]] ?? [])
            }
        }
    }
    func devExport(_ text: String, filename: String) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = filename
        guard let window = devWindow else { return }
        panel.beginSheetModal(for: window) { result in
            guard result == .OK, let url = panel.url else { return }
            do { try text.write(to: url, atomically: true, encoding: .utf8) } catch { self.workbench?.error = error.localizedDescription }
        }
    }
}

struct DevDataRows: View {
    let rows: [DevProperty]
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 8) {
                    Text(row.name).foregroundStyle(ConsoleInk.property).lineLimit(1).truncationMode(.middle).frame(width: 140, alignment: .leading).pointerTip(row.name)
                    Text(row.value).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                }
                .font(DevMono.font(11.5))
                .padding(.vertical, 4).padding(.horizontal, 8)
                .textSelection(.enabled)
                Divider()
            }
        }
    }
}

struct DevPanelBar<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        GeometryReader { geometry in
            ThreadScrollView(.horizontal) {
                HStack(spacing: 8) { content }
                    .frame(minWidth: max(0, geometry.size.width - 16), minHeight: 30)
                    .padding(.horizontal, 8)
            }.scrollIndicators(.never)
        }
        .font(.system(size: 11.5)).frame(height: 30)
        .buttonStyle(.yab(.quiet, .small))
        .background(Palette.ink.opacity(0.025))
    }
}
