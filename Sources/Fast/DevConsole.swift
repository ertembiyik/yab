import AppKit
import SwiftUI

// Console as Chromium's, on what WebKit's console says (DevConsoleBridge.swift):
// every message of the page, its workers and frames, with its values as the
// protocol gives them; what is typed run in the context picked, its answer
// a value that opens; groups, repeats, a table, a trace; the filter's words
// and levels, the sidebar, live expressions, Keep log. The words of a
// message are WebKit's ("undefined is not an object"), the look Chrome's.

/// A value as the protocol gives it: a RemoteObject, its preview, and the
/// objectId the wire asks about (properties, entries, a node).
struct ConsoleValue: Equatable, Hashable {
    var type: String
    var subtype: String?
    var className: String?
    var string: String?
    var number: Double?
    var bool: Bool?
    var description: String?
    var objectId: String?
    var size: Int?
    var preview: ConsolePreview?
    /// The target it lives in, a worker's, or "" for the page.
    var target: String

    init(type: String, subtype: String? = nil, description: String? = nil, target: String = "") {
        self.type = type
        self.subtype = subtype
        self.description = description
        self.target = target
    }

    init(json: [String: Any]) {
        type = json["ty"] as? String ?? "undefined"
        subtype = json["st"] as? String
        className = json["cn"] as? String
        description = json["d"] as? String
        objectId = json["id"] as? String
        size = (json["sz"] as? NSNumber)?.intValue
        target = json["tg"] as? String ?? ""
        switch json["v"] {
        case let text as String: string = text
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { bool = number.boolValue } else if number.doubleValue.isFinite { self.number = number.doubleValue }
        default: break
        }
        preview = (json["pv"] as? [String: Any]).map(ConsolePreview.init(json:))
    }

    var isObject: Bool { objectId != nil && type != "symbol" }
    var isNode: Bool { subtype == "node" }
    var isError: Bool { subtype == "error" }
}

/// What the protocol says of an object at a glance: some of its
/// properties, or a collection's first entries.
struct ConsolePreview: Equatable, Hashable {
    struct Property: Equatable, Hashable {
        var name: String
        var type: String
        var subtype: String?
        var value: String?
        /// Nested, at most one.
        var preview: [ConsolePreview]
        var isInternal: Bool
    }

    struct Entry: Equatable, Hashable {
        var key: [ConsolePreview]
        var value: [ConsolePreview]
    }

    var type: String
    var subtype: String?
    var description: String?
    var overflow: Bool
    var lossless: Bool
    var size: Int?
    var properties: [Property]
    var entries: [Entry]

    init(json: [String: Any]) {
        type = json["ty"] as? String ?? "object"
        subtype = json["st"] as? String
        description = json["d"] as? String
        overflow = json["of"] as? Bool ?? false
        lossless = json["ll"] as? Bool ?? false
        size = (json["sz"] as? NSNumber)?.intValue
        properties = (json["ps"] as? [[String: Any]] ?? []).map { p in
            Property(name: p["n"] as? String ?? "", type: p["ty"] as? String ?? "undefined", subtype: p["st"] as? String,
                     value: p["v"] as? String ?? (p["v"] as? NSNumber)?.stringValue,
                     preview: (p["pv"] as? [String: Any]).map { [ConsolePreview(json: $0)] } ?? [], isInternal: p["i"] as? Bool ?? false)
        }
        entries = (json["es"] as? [[String: Any]] ?? []).map { e in
            Entry(key: (e["k"] as? [String: Any]).map { [ConsolePreview(json: $0)] } ?? [],
                  value: (e["v"] as? [String: Any]).map { [ConsolePreview(json: $0)] } ?? [])
        }
    }
}

/// A frame of a stack, as WebKit's console gives it.
struct ConsoleFrame: Equatable, Hashable {
    var function: String
    var url: String
    var line: Int
    var column: Int
    /// The line between a stack and the one that scheduled it.
    var async: String?

    init(json: [String: Any]) {
        function = json["f"] as? String ?? ""
        url = json["u"] as? String ?? ""
        line = (json["l"] as? NSNumber)?.intValue ?? 0
        column = (json["c"] as? NSNumber)?.intValue ?? 0
        async = json["async"] as? String
    }

    var place: DevPlace? { url.isEmpty || line == 0 ? nil : DevPlace("\(url):\(line):\(column)") }

    /// A frame of Yab's own listener on a local page, or of the console's
    /// own evaluation: never the page's.
    var ours: Bool { url.hasPrefix("user-script") || url.contains("__WebInspector") }
}

/// A line of the console: something the page said, something typed, its
/// answer, or Navigated to….
struct ConsoleMessage: Identifiable, Equatable {
    enum Kind: Equatable { case page, command, result, navigated, xhr }

    let id: Int
    var kind: Kind
    var target: String
    /// javascript, console-api, network, security, css, xml, other…
    var source: String
    /// log, info, warning, error, debug.
    var level: String
    /// log, dir, dirxml, table, trace, startGroup, startGroupCollapsed,
    /// endGroup, assert, timing, profile, profileEnd, image, result.
    var type: String
    var text: String
    var url: String
    var line: Int
    var column: Int
    var count: Int
    var timestamp: Double
    var values: [ConsoleValue]
    var stack: [ConsoleFrame]
    var requestId: String
    /// The groups this message is in, outermost first.
    var groups: [Int] = []
    /// What a command's answer was saved as in WebKit ($1, $2…), -1 none.
    var saved = -1

    var isGroup: Bool { type == "startGroup" || type == "startGroupCollapsed" }

    /// Chrome's level: errors, warnings, info (log and info) or verbose.
    var chromeLevel: ConsoleLevel {
        switch level {
        case "error": return .error
        case "warning": return .warning
        case "debug": return .verbose
        default: return .info
        }
    }

    /// The first place of the page's own in its stack, else where WebKit
    /// says it was said.
    var place: DevPlace? {
        if let frame = stack.first(where: { !$0.ours && $0.place != nil }), let place = frame.place { return place }
        if !url.isEmpty, !url.hasPrefix("user-script"), line > 0 { return DevPlace("\(url):\(line):\(column)") }
        return nil
    }

    /// The whole message as words, for Copy and the filter.
    var words: String {
        if kind == .navigated { return "Navigated to " + url }
        if !values.isEmpty, source == "console-api" || kind == .result {
            return ConsoleFormat.plain(self)
        }
        return text
    }
}

enum ConsoleLevel: String, CaseIterable, Hashable {
    case verbose = "Verbose", info = "Info", warning = "Warnings", error = "Errors"
}

/// A live expression, pinned over the messages and run four times a second.
struct ConsoleLive: Identifiable, Equatable {
    let id: Int
    var expression: String
    var value: ConsoleValue?
}

/// A context Console can run in: the page, a frame, an extension's world,
/// a worker.
struct ConsoleContext: Identifiable, Equatable, Hashable {
    let id: Int
    var name: String
    var type: String
    var frame: String
    var main: Bool
    var url: String
    var on: Bool

    var title: String {
        if type == "worker" { return name }
        if main, type == "normal" { return "top" }
        if type == "user" || type == "internal" { return name.isEmpty ? "Extension" : name }
        return frame
    }
}

/// What Yab keeps of Console's settings, Chrome's, across pages and launches.
@Observable final class ConsolePrefs {
    static let shared = ConsolePrefs()

    var networkMessages: Bool { didSet { save("console.network", networkMessages) } }
    var logXHR: Bool { didSet { save("console.xhr", logXHR) } }
    var keepLog: Bool { didSet { save("console.keepLog", keepLog) } }
    var eager: Bool { didSet { save("console.eager", eager) } }
    var selectedContextOnly: Bool { didSet { save("console.selectedOnly", selectedContextOnly) } }
    var historyCompletion: Bool { didSet { save("console.historyCompletion", historyCompletion) } }
    var groupSimilar: Bool { didSet { save("console.groupSimilar", groupSimilar) } }
    var userActivation: Bool { didSet { save("console.userActivation", userActivation) } }
    var corsErrors: Bool { didSet { save("console.cors", corsErrors) } }
    var timestamps: Bool { didSet { save("console.timestamps", timestamps) } }
    var expandTraces: Bool { didSet { save("console.expandTraces", expandTraces) } }
    var levels: Set<ConsoleLevel> { didSet { Store.settings.set(levels.map(\.rawValue), forKey: "console.levels") } }
    var sidebar: Bool { didSet { save("console.sidebar", sidebar) } }
    var history: [String] { didSet { Store.settings.set(Array(history.suffix(300)), forKey: "console.history") } }

    private init() {
        let s = Store.settings
        networkMessages = s.object(forKey: "console.network") as? Bool ?? true
        logXHR = s.bool(forKey: "console.xhr")
        keepLog = s.bool(forKey: "console.keepLog")
        eager = s.object(forKey: "console.eager") as? Bool ?? true
        selectedContextOnly = s.bool(forKey: "console.selectedOnly")
        historyCompletion = s.object(forKey: "console.historyCompletion") as? Bool ?? true
        groupSimilar = s.object(forKey: "console.groupSimilar") as? Bool ?? true
        userActivation = s.object(forKey: "console.userActivation") as? Bool ?? true
        corsErrors = s.object(forKey: "console.cors") as? Bool ?? true
        timestamps = s.bool(forKey: "console.timestamps")
        expandTraces = s.object(forKey: "console.expandTraces") as? Bool ?? true
        levels = Set((s.stringArray(forKey: "console.levels") ?? ["Info", "Warnings", "Errors"]).compactMap(ConsoleLevel.init(rawValue:)))
        sidebar = s.bool(forKey: "console.sidebar")
        history = s.stringArray(forKey: "console.history") ?? []
    }

    private func save(_ key: String, _ value: Bool) { Store.settings.set(value, forKey: key) }

    /// Chrome's words on the levels menu.
    var levelsTitle: String {
        if levels == [.info, .warning, .error] { return "Default levels" }
        if levels.count == ConsoleLevel.allCases.count { return "All levels" }
        if levels.isEmpty { return "Hide all" }
        if levels.count == 1, let one = levels.first { return one.rawValue + " only" }
        return "Custom levels"
    }
}

// MARK: - the tab's console

@MainActor @Observable final class ConsoleLog: DevWireListener {
    static let channel = "console"

    private(set) var messages: [ConsoleMessage] = [] {
        didSet { counts.update(messages) }
    }
    /// The DevTools head counts occurrences, including collapsed repeats.
    /// Observe these totals separately so ordinary log batches leave it alone.
    @Observable final class Counts {
        private(set) var errors = 0
        private(set) var warnings = 0
        /// Chrome's DevTools count their own (ChromiumDevTools.swift).
        func set(errors: Int, warnings: Int) {
            if self.errors != errors { self.errors = errors }
            if self.warnings != warnings { self.warnings = warnings }
        }
        func update(_ messages: [ConsoleMessage]) {
            let errorTotal = messages.lazy.filter { $0.level == "error" }.reduce(0) { $0 + $1.count }
            let warningTotal = messages.lazy.filter { $0.level == "warning" }.reduce(0) { $0 + $1.count }
            if errors != errorTotal { errors = errorTotal }
            if warnings != warningTotal { warnings = warningTotal }
        }
    }
    let counts = Counts()
    /// Groups shut, by the id of the message that opens them.
    var shut: Set<Int> = []
    /// Messages whose stack is shown.
    var opened: Set<Int> = []
    var live: [ConsoleLive] = []
    var contexts: [ConsoleContext] = []
    /// Bumped when the contexts may have changed, for the menu to ask again.
    private(set) var contextsChanged = 0
    /// What the bridge was unable to do, said once.
    var unavailable = false
    @ObservationIgnored private var next = 1
    @ObservationIgnored private var openGroups: [String: [Int]] = [:]
    @ObservationIgnored private var lastPage: [String: Int] = [:]
    @ObservationIgnored private var nextLive = 1

    init() {}

    @ObservationIgnored private var batchIssued = 0
    @ObservationIgnored private var batchNext = 0
    @ObservationIgnored private var batchGeneration = 0
    @ObservationIgnored private var pendingBatches: [Int: [Item]] = [:]

    func hear(_ json: String) {
        let ticket = batchIssued, generation = batchGeneration
        batchIssued += 1
        Task.detached(priority: .utility) { [weak self] in
            let items = json.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
            let parsed = items.map(ConsoleLog.parse)
            await self?.received(parsed, ticket: ticket, generation: generation)
        }
    }

    private func received(_ items: [Item], ticket: Int, generation: Int) {
        guard generation == batchGeneration else { return }
        pendingBatches[ticket] = items
        while let next = pendingBatches.removeValue(forKey: batchNext) {
            batchNext += 1
            apply(next)
        }
    }

    private func discardPending() {
        batchGeneration += 1
        batchIssued = 0
        batchNext = 0
        pendingBatches = [:]
    }

    /// One posted item, read off the main thread.
    enum Item: @unchecked Sendable {
        case message(ConsoleMessage)
        case preview(ConsoleValue)
        case repeated(Int, target: String = "")
        case cleared(String, String)
        case live(Int, ConsoleValue)
        case contexts
        case xhr(String, String, String, Int)
        case none
    }

    nonisolated static func parse(_ raw: [String: Any]) -> Item {
        switch raw["t"] as? String {
        case "m":
            let message = ConsoleMessage(id: 0, kind: .page, target: raw["tg"] as? String ?? "", source: raw["src"] as? String ?? "",
                                         level: raw["lv"] as? String ?? "log", type: raw["ty"] as? String ?? "log", text: raw["x"] as? String ?? "",
                                         url: raw["u"] as? String ?? "", line: (raw["l"] as? NSNumber)?.intValue ?? 0, column: (raw["c"] as? NSNumber)?.intValue ?? 0,
                                         count: max(1, (raw["n"] as? NSNumber)?.intValue ?? 1), timestamp: (raw["ts"] as? NSNumber)?.doubleValue ?? 0,
                                         values: (raw["p"] as? [[String: Any]] ?? []).map(ConsoleValue.init(json:)),
                                         stack: (raw["s"] as? [[String: Any]] ?? []).map(ConsoleFrame.init(json:)),
                                         requestId: raw["r"] as? String ?? "")
            return .message(message)
        case "preview": return .preview(ConsoleValue(json: raw["v"] as? [String: Any] ?? [:]))
        case "r": return .repeated((raw["n"] as? NSNumber)?.intValue ?? 1, target: raw["tg"] as? String ?? "")
        case "clear": return .cleared(raw["why"] as? String ?? "", raw["u"] as? String ?? "")
        case "live":
            return .live((raw["i"] as? NSNumber)?.intValue ?? 0, ConsoleValue(json: raw["v"] as? [String: Any] ?? [:]))
        case "ctx": return .contexts
        case "xhr": return .xhr(raw["k"] as? String ?? "XHR", raw["m"] as? String ?? "GET", raw["u"] as? String ?? "", (raw["st"] as? NSNumber)?.intValue ?? 0)
        default: return .none
        }
    }

    func apply(_ items: [Item]) {
        var out = messages
        for item in items {
            switch item {
            case .message(var message):
                // The end of a group closes it; the line itself is not shown.
                if message.type == "endGroup" {
                    if openGroups[message.target]?.isEmpty == false { openGroups[message.target]?.removeLast() }
                    continue
                }
                if !handedOver.isEmpty, handOver(message, into: &out) { continue }
                message = number(message)
                if message.type == "startGroupCollapsed" { shut.insert(message.id) }
                if message.type == "trace", ConsolePrefs.shared.expandTraces { opened.insert(message.id) }
                out.append(message)
                if message.isGroup { openGroups[message.target, default: []].append(message.id) }
                lastPage[message.target] = message.id
            case .preview(let value):
                for i in out.indices {
                    for j in out[i].values.indices where out[i].values[j].objectId == value.objectId && out[i].values[j].target == value.target {
                        out[i].values[j] = value
                    }
                }
            case .repeated(let count, let target):
                if let last = lastPage[target], let index = out.lastIndex(where: { $0.id == last }) { out[index].count = max(1, count) }
            case .cleared(let why, let url):
                // A new page, kept as Chromium keeps it: a line saying so.
                if why.contains("navigation") || why.contains("main-frame"), ConsolePrefs.shared.keepLog {
                    openGroups = [:]
                    lastPage = [:]
                    out.append(ConsoleMessage(id: take(), kind: .navigated, target: "", source: "other", level: "info", type: "log", text: "",
                                              url: url, line: 0, column: 0, count: 1, timestamp: Date().timeIntervalSince1970, values: [], stack: [], requestId: ""))
                } else {
                    out.removeAll()
                    handedOver = [:]
                    openGroups = [:]
                    shut = []
                    opened = []
                    lastPage = [:]
                }
            case .live(let index, let value):
                if live.indices.contains(index) { live[index].value = value }
            case .contexts:
                contextsChanged += 1
            case .xhr(let kind, let method, let url, let status):
                out.append(number(ConsoleMessage(id: 0, kind: .xhr, target: "", source: "network", level: "info", type: "log",
                                                 text: "\(kind) finished loading: \(method) \"\(url)\".",
                                                 url: url, line: 0, column: 0, count: 1, timestamp: Date().timeIntervalSince1970, values: [], stack: [], requestId: "\(status)")))
            case .none:
                break
            }
        }
        // Chrome keeps the newest lines when a page says a great deal.
        if out.count > 15_000 { out.removeFirst(out.count - 15_000) }
        messages = out
    }

    private func take() -> Int {
        defer { next += 1 }
        return next
    }

    private func number(_ message: ConsoleMessage) -> ConsoleMessage {
        var message = message
        message = ConsoleMessage(id: take(), kind: message.kind, target: message.target, source: message.source, level: message.level, type: message.type,
                                 text: message.text, url: message.url, line: message.line, column: message.column, count: message.count,
                                 timestamp: message.timestamp, values: message.values, stack: message.stack, requestId: message.requestId,
                                 groups: openGroups[message.target] ?? [], saved: message.saved)
        return message
    }

    /// The inspector came up anew: it hands over again everything the page
    /// said, so what was here goes (a kept log keeps its earlier pages).
    func connected() {
        discardPending()
        if ConsolePrefs.shared.keepLog, !messages.isEmpty {
            messages.append(ConsoleMessage(id: take(), kind: .navigated, target: "", source: "other", level: "info", type: "log", text: "",
                                           url: "", line: 0, column: 0, count: 1, timestamp: Date().timeIntervalSince1970, values: [], stack: [], requestId: ""))
        } else {
            messages = []
            shut = []
            opened = []
        }
        handedOver = [:]
        openGroups = [:]
        lastPage = [:]
        contextsChanged += 1
    }

    /// Back on the document its inspector was put away on: every line
    /// stays, what was typed and answered with them, as in Chromium. The new
    /// inspector hands over again what the page said; each of those found
    /// here takes its line's place (its objects live again) and isn't
    /// shown twice.
    func reconnected() {
        discardPending()
        handedOver = [:]
        for message in messages where message.kind == .page { handedOver[Self.mark(message), default: []].append(message.id) }
        openGroups = [:]
        lastPage = [:]
        contextsChanged += 1
    }

    /// Page lines kept over a return, by what makes one the same line, to
    /// their ids here.
    @ObservationIgnored private var handedOver: [String: [Int]] = [:]
    private static func mark(_ m: ConsoleMessage) -> String {
        "\(m.timestamp)|\(m.level)|\(m.type)|\(m.target)|\(m.url):\(m.line):\(m.column)|\(m.text)"
    }

    /// A line handed over again, put on its kept line: true when it was one.
    private func handOver(_ message: ConsoleMessage, into out: inout [ConsoleMessage]) -> Bool {
        let mark = Self.mark(message)
        guard var ids = handedOver[mark], !ids.isEmpty else { return false }
        let id = ids.removeFirst()
        handedOver[mark] = ids.isEmpty ? nil : ids
        // Ids only grow along the list: found by halving.
        var low = 0, high = out.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if out[mid].id == id {
                out[mid].values = message.values
                out[mid].count = message.count
                lastPage[message.target] = id
                if out[mid].isGroup { openGroups[message.target, default: []].append(id) }
                return true
            }
            if out[mid].id < id { low = mid + 1 } else { high = mid - 1 }
        }
        return false
    }

    /// What was typed, and its answer.
    func command(_ text: String) -> Int {
        let id = take()
        messages.append(ConsoleMessage(id: id, kind: .command, target: "", source: "console-api", level: "log", type: "log", text: text,
                                       url: "", line: 0, column: 0, count: 1, timestamp: Date().timeIntervalSince1970, values: [], stack: [], requestId: ""))
        return id
    }

    func answer(_ value: ConsoleValue, thrown: Bool, saved: Int) {
        var message = ConsoleMessage(id: take(), kind: .result, target: value.target, source: "console-api", level: thrown ? "error" : "log", type: "result",
                                     text: thrown ? "Uncaught " + (value.description ?? "") : "", url: "", line: 0, column: 0, count: 1,
                                     timestamp: Date().timeIntervalSince1970, values: [value], stack: [], requestId: "")
        message.saved = saved
        messages.append(message)
    }

    func clearHere() {
        discardPending()
        handedOver = [:]
        messages = []
        shut = []
        opened = []
        openGroups = [:]
        lastPage = [:]
    }

    func addLive(_ expression: String = "") {
        live.append(ConsoleLive(id: nextLive, expression: expression))
        nextLive += 1
    }

    func dropLive(_ id: Int) { live.removeAll { $0.id == id } }
}

// MARK: - filtering

/// Chrome's console filter: words, -words, /regex/, url:, -url:, source:,
/// context:.
struct ConsoleFilter: Equatable {
    var text = ""

    private struct Term {
        var key: String?
        var value: String
        var negative: Bool
        var regex: NSRegularExpression?
    }

    private var terms: [Term] {
        text.split(separator: " ").map(String.init).compactMap { raw in
            var word = raw
            let negative = word.hasPrefix("-") && word.count > 1
            if negative { word.removeFirst() }
            if word.hasPrefix("/"), word.hasSuffix("/"), word.count > 2 {
                return Term(key: nil, value: word, negative: negative, regex: try? NSRegularExpression(pattern: String(word.dropFirst().dropLast()), options: [.caseInsensitive]))
            }
            for key in ["url", "source", "context"] where word.hasPrefix(key + ":") {
                return Term(key: key, value: String(word.dropFirst(key.count + 1)), negative: negative, regex: nil)
            }
            return Term(key: nil, value: word, negative: negative, regex: nil)
        }
    }

    var isActive: Bool { !text.trimmingCharacters(in: .whitespaces).isEmpty }

    func admits(_ message: ConsoleMessage, context: (ConsoleMessage) -> String) -> Bool {
        let words = message.words
        for term in terms {
            var hit: Bool
            switch term.key {
            case "url": hit = message.url.localizedCaseInsensitiveContains(term.value) || (message.place?.url.localizedCaseInsensitiveContains(term.value) ?? false)
            case "source": hit = message.source.localizedCaseInsensitiveContains(term.value)
            case "context": hit = context(message).localizedCaseInsensitiveContains(term.value)
            default:
                if let regex = term.regex {
                    hit = regex.firstMatch(in: words, range: NSRange(words.startIndex..., in: words)) != nil
                } else {
                    hit = words.localizedCaseInsensitiveContains(term.value) || message.url.localizedCaseInsensitiveContains(term.value)
                }
            }
            if hit == term.negative { return false }
        }
        return true
    }
}

/// The sidebar's groups: Chrome's six, each by where it was said.
enum ConsoleGroup: String, CaseIterable, Hashable {
    case all = "messages", user = "user messages", errors = "errors", warnings = "warnings", info = "info", verbose = "verbose"

    func holds(_ message: ConsoleMessage) -> Bool {
        switch self {
        case .all: return true
        case .user: return message.source == "console-api" && message.kind == .page
        case .errors: return message.chromeLevel == .error
        case .warnings: return message.chromeLevel == .warning
        case .info: return message.chromeLevel == .info
        case .verbose: return message.chromeLevel == .verbose
        }
    }
}

/// What the console's panel shows of a tab's log.
@MainActor @Observable final class ConsolePanel {
    var filter = ConsoleFilter()
    var group: ConsoleGroup = .all
    /// One source's messages within the group, from the sidebar.
    var groupSource: String?
    var settingsOpen = false
    /// The copy picker, open from the toolbar's chevron, and the way its
    /// card shows: the one under the pointer.
    var copying = false
    var copyLit: ConsoleCopyWay = .brief
    var hidden = 0
    var context: Int = 0
    var focusPrompt = false
    /// The prompt shows completions: Escape is theirs, not the drawer's.
    @ObservationIgnored var completing = false
    /// Words to put at the prompt, to change and run: Edit and resend.
    var prefill: String?
    /// Hidden by "Hide messages from": these sources' files.
    var hiddenFiles: Set<String> = []
    /// What is at the prompt and not run yet, kept as it is typed (not
    /// published: the prompt draws it), for the prompt made anew and for
    /// the tab left (DevReturn).
    @ObservationIgnored var draft = ""
    /// Said when `draft` was put back from elsewhere: another tab's.
    private(set) var draftLoaded = 0

    func loadDraft(_ words: String) {
        guard draft != words else { return }
        draft = words
        draftLoaded += 1
    }

    /// The messages shown: levels, the filter, the sidebar, the settings,
    /// groups shut.
    func shown(_ log: ConsoleLog) -> [ConsoleMessage] {
        let prefs = ConsolePrefs.shared
        var hidden = 0
        var out: [ConsoleMessage] = []
        let contextName = { [contexts = log.contexts] (m: ConsoleMessage) -> String in
            m.target.isEmpty ? (contexts.first(where: \.main)?.title ?? "top") : (contexts.first(where: { $0.type == "worker" })?.title ?? m.target)
        }
        let selected = log.contexts.first(where: \.on)
        for message in log.messages {
            guard message.kind == .page || message.kind == .xhr else { out.append(message); continue }
            var keep = prefs.levels.contains(message.chromeLevel)
            if keep, !prefs.networkMessages, message.source == "network" { keep = false }
            if keep, !prefs.corsErrors, message.text.contains("Access-Control-Allow-Origin") || message.text.contains("CORS") { keep = false }
            if keep, prefs.selectedContextOnly, let selected {
                keep = selected.type == "worker" ? !message.target.isEmpty : message.target.isEmpty
            }
            if keep, group != .all || groupSource != nil {
                keep = group.holds(message) && (groupSource == nil || ConsolePanel.file(message) == groupSource)
            }
            if keep, !hiddenFiles.isEmpty, hiddenFiles.contains(ConsolePanel.file(message)) { keep = false }
            if keep, filter.isActive { keep = filter.admits(message, context: contextName) }
            if !keep { hidden += 1; continue }
            if message.groups.contains(where: log.shut.contains) { continue }
            if !prefs.groupSimilar, message.count > 1 {
                var one = message
                one.count = 1
                out.append(contentsOf: repeatElement(one, count: min(message.count, 100)).enumerated().map { index, m in
                    var copy = m
                    copy = ConsoleMessage(id: -(m.id * 1000 + index + 1), kind: m.kind, target: m.target, source: m.source, level: m.level, type: m.type, text: m.text,
                                          url: m.url, line: m.line, column: m.column, count: 1, timestamp: m.timestamp, values: m.values, stack: m.stack,
                                          requestId: m.requestId, groups: m.groups, saved: m.saved)
                    return copy
                })
                continue
            }
            out.append(message)
        }
        if self.hidden != hidden { DispatchQueue.main.async { self.hidden = hidden } }
        return out
    }

    /// The file a message was said in, for the sidebar and Hide messages from.
    static func file(_ message: ConsoleMessage) -> String {
        let url = message.place?.url ?? message.url
        guard !url.isEmpty else { return "<other>" }
        return URL(string: url)?.lastPathComponent.nilIfEmpty ?? url
    }
}

nonisolated(unsafe) private var consolePanelKey: UInt8 = 0

extension Browser {
    /// The console panel's own state: one for the window, over the tab in front.
    var consolePanel: ConsolePanel {
        if let panel = objc_getAssociatedObject(self, &consolePanelKey) as? ConsolePanel { return panel }
        let panel = ConsolePanel()
        objc_setAssociatedObject(self, &consolePanelKey, panel, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return panel
    }

    /// What was typed at the prompt, run as Chromium runs it: in the context
    /// picked, or on the frame the debugger is paused on.
    func consoleRun(_ expression: String) {
        guard let tab = toolsFront else { return }
        let log = tab.devModel(ConsoleLog.self)
        let prefs = ConsolePrefs.shared
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if prefs.history.last != expression { prefs.history.append(expression) }
        // clear() is the console's own, and the command line clears it.
        _ = log.command(expression)
        wire("console.eval", ["expr": expression, "ctx": consolePanel.context, "gesture": prefs.userActivation], failed: { [weak log] why in
            log?.answer(ConsoleValue(type: "string", description: why), thrown: true, saved: -1)
        }) { [weak log] value in
            guard let log, let raw = value as? [String: Any] else { return }
            let result = ConsoleValue(json: raw["v"] as? [String: Any] ?? [:])
            log.answer(result, thrown: raw["thrown"] as? Bool ?? false, saved: (raw["saved"] as? NSNumber)?.intValue ?? -1)
        }
    }

    /// The inspector came up: Console's settings, live expressions and the
    /// contexts handed to its page.
    func consoleConnected() {
        wire("console.prefs", ["xhr": ConsolePrefs.shared.logXHR])
        consoleLive()
        consoleContexts()
    }

    /// The contexts there are, asked again.
    func consoleContexts() {
        guard let tab = toolsFront else { return }
        let log = tab.devModel(ConsoleLog.self)
        wire("console.contexts") { [weak self, weak log] value in
            guard let log, let list = value as? [[String: Any]] else { return }
            log.contexts = list.compactMap { c in
                guard let id = (c["id"] as? NSNumber)?.intValue else { return nil }
                return ConsoleContext(id: id, name: c["name"] as? String ?? "", type: c["type"] as? String ?? "normal", frame: c["frame"] as? String ?? "",
                                      main: c["main"] as? Bool ?? false, url: c["url"] as? String ?? "", on: c["on"] as? Bool ?? false)
            }
            // WebKit may take the keyboard while its hidden inspector opens.
            // Once it answers, return it to Console without interrupting an
            // input the person has already started editing.
            if self?.devOpen == true, self?.devPane == .console, let browser = self, let window = browser.devWindow,
               !(window.firstResponder is NSText), !(window.firstResponder is NSTextField) {
                ConsolePromptView.focusLatest(in: window)
            }
        }
    }

    func consoleSetContext(_ context: ConsoleContext) {
        consolePanel.context = context.id
        wire("console.setContext", ["id": context.id]) { [weak self] _ in self?.consoleContexts() }
    }

    func consoleClear() {
        guard let tab = toolsFront else { return }
        let log = tab.devModel(ConsoleLog.self)
        log.clearHere()
        wire("console.clear")
        consolePanel.hiddenFiles = []
    }

    /// Live expressions handed to the inspector's page, which runs them.
    func consoleLive() {
        guard let tab = toolsFront else { return }
        wire("console.live", ["list": tab.devModel(ConsoleLog.self).live.map(\.expression)])
    }

    /// An element in a message, shown in Elements.
    func consoleReveal(_ value: ConsoleValue) {
        guard let id = value.objectId else { return }
        pickDevPane(.elements)
        wire("console.node", ["id": id, "tg": value.target, "show": true])
    }

    func consoleHighlight(_ value: ConsoleValue?) {
        wire("console.highlight", ["id": value?.objectId ?? "", "tg": value?.target ?? ""])
    }

    /// Show function definition: its script and line in Sources.
    func consoleFunction(_ value: ConsoleValue) {
        guard let id = value.objectId else { return }
        wire("console.where", ["id": id, "tg": value.target]) { [weak self] raw in
            guard let self, let raw = raw as? [String: Any], let url = raw["u"] as? String, !url.isEmpty else { return }
            let line = (raw["l"] as? NSNumber)?.intValue ?? 1
            if let place = DevPlace("\(url):\(line):\((raw["c"] as? NSNumber)?.intValue ?? 1)") { self.revealSource(place) }
        }
    }

    /// Store as global variable: temp1, temp2…, as Chromium names them.
    func consoleStore(_ value: ConsoleValue) {
        guard let id = value.objectId else { return }
        let log = toolsFront?.devModel(ConsoleLog.self)
        Browser.consoleTemps += 1
        let name = "temp\(Browser.consoleTemps)"
        wire("console.store", ["id": id, "tg": value.target, "name": name]) { [weak log] _ in
            _ = log?.command(name)
            log?.answer(value, thrown: false, saved: -1)
        }
    }

    static var consoleTemps = 0

    /// Copy object: as JSON, as Chromium copies it.
    func consoleCopyObject(_ value: ConsoleValue) {
        guard let id = value.objectId else {
            copyForAgent(ConsoleFormat.plainValue(value, top: true), "Copied")
            return
        }
        wire("console.json", ["id": id, "tg": value.target]) { [weak self] text in
            self?.copyForAgent(text as? String ?? "", "Copied object")
        }
    }

    /// Copy for Agent: the messages, their stacks and the page, as one
    /// piece of Markdown, through the list's own packer.
    func consoleCopyForAgent(_ messages: [ConsoleMessage]) {
        guard let tab = toolsFront else { return }
        copyIssues([], console: messages.map { ConsoleFormat.line($0) }, on: tab)
    }

    /// Copy messages: every line the console shows, one a message, no
    /// stacks. The toolbar button's own press and the picker's first row.
    func consoleCopy(_ messages: [ConsoleMessage]) {
        copyForAgent(ConsoleFormat.text(messages, detail: .brief), "Copied console")
    }

    /// Copy with details: every frame and every object's JSON, fetched
    /// from the page first so nothing has to be unfolded by hand.
    func consoleCopyDetails(_ messages: [ConsoleMessage]) {
        consoleObjectsJSON(messages) { [weak self] json in
            self?.copyForAgent(ConsoleFormat.text(messages, detail: .full, json: json), "Copied console with details")
        }
    }

    /// Save to file, copy path: the same full text in a file under the
    /// temporary folder, its path on the pasteboard, for a console too
    /// long for an agent's context but fine as a file it reads.
    func consoleSaveAndCopyPath(_ messages: [ConsoleMessage]) {
        let url = consoleFileURL()
        consoleObjectsJSON(messages) { [weak self] json in
            guard let self else { return }
            do { try ConsoleFormat.text(messages, detail: .full, json: json).write(to: url, atomically: true, encoding: .utf8) } catch {
                announce("Could not save the console: " + error.localizedDescription, mark: "exclamationmark.triangle")
                return
            }
            copyForAgent(url.path, "Saved, path copied")
        }
    }

    /// Where Save to file puts the console: the temporary folder, the
    /// page's host and the time in the name, as the chat's screenshots.
    func consoleFileURL(now: Date = Date()) -> URL {
        let host = toolsFront.map(ChatComposer.host) ?? "console"
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("yab-console-" + host + "-" + String(Int(now.timeIntervalSince1970)) + ".log")
    }

    /// The Markdown Copy for Agent puts on the pasteboard: the page under
    /// a heading, then the lines.
    func consoleMarkdown(_ messages: [ConsoleMessage]) -> String {
        DevCopy.pack([], console: messages.map { ConsoleFormat.line($0) }, page: toolsFront?.address, size: toolsFront?.builtPage?.bounds.size)
    }

    /// The objects the messages hold, each as the JSON the page gives for
    /// it: at most 40 objects, each cut at 20k characters; without an
    /// inspector, or past 3 s, what came by then (the previews stand in).
    func consoleObjectsJSON(_ messages: [ConsoleMessage], _ done: @escaping ([String: String]) -> Void) {
        var wanted: [(id: String, target: String)] = []
        for message in messages {
            for value in message.values where value.type == "object" && value.subtype != "null" {
                if let id = value.objectId, !wanted.contains(where: { $0.id == id }) { wanted.append((id, value.target)) }
            }
        }
        wanted = Array(wanted.prefix(40))
        guard !wanted.isEmpty else { done([:]); return }
        var json: [String: String] = [:]
        var left = wanted.count
        var finished = false
        func finish() {
            guard !finished else { return }
            finished = true
            done(json)
        }
        for want in wanted {
            // `done` is called with nil on a failure too: one count a call.
            wire("console.json", ["id": want.id, "tg": want.target]) { text in
                if let text = text as? String, !text.isEmpty { json[want.id] = String(text.prefix(20_000)) }
                left -= 1
                if left == 0 { finish() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: finish)
    }

    func consoleAsk(_ messages: [ConsoleMessage]) {
        guard let tab = toolsFront else { return }
        askInChat(about: tab, selection: ConsoleFormat.text(messages, detail: .lines))
    }

    /// The console's lines saved to a file, as Chromium's Save as….
    func consoleSave(_ messages: [ConsoleMessage]) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (toolsFront?.address?.host() ?? "console") + "-\(Int(Date().timeIntervalSince1970)).log"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? ConsoleFormat.text(messages, detail: .lines).write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// A network message's request, shown in Network.
    func consoleShowRequest(_ message: ConsoleMessage) {
        guard let tab = toolsFront else { return }
        let url = message.url
        if let row = tab.netLog.rows.last(where: { $0.url == url }) { netPanel.selected = row.id }
        pickDevPane(.network)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - words

/// How a message and its values read: Chrome's way of writing them.
enum ConsoleFormat {
    /// The message, its format string's %s %d %i %f %o %O %c applied: runs
    /// of words, each with its CSS from %c, and values between.
    enum Part: Equatable {
        case text(String, css: String)
        case value(ConsoleValue)
    }

    static func parts(_ message: ConsoleMessage) -> [Part] {
        var values = message.values
        if message.kind == .result { return message.level == "error" ? [.text(message.text, css: "")] : values.map(Part.value) }
        guard message.source == "console-api" || message.kind == .result, !values.isEmpty else { return [.text(message.text, css: "")] }
        if message.type == "assert" {
            var out: [Part] = [.text("Assertion failed: ", css: "")]
            if values.isEmpty { return out }
            out.append(contentsOf: substitute(&values))
            return out
        }
        return substitute(&values)
    }

    private static func substitute(_ values: inout [ConsoleValue]) -> [Part] {
        var out: [Part] = []
        guard let first = values.first else { return out }
        if first.type == "string", let format = first.string, format.contains("%") {
            values.removeFirst()
            var css = ""
            var run = ""
            let chars = Array(format)
            var i = 0
            func flush() { if !run.isEmpty { out.append(.text(run, css: css)); run = "" } }
            while i < chars.count {
                let c = chars[i]
                if c == "%", i + 1 < chars.count {
                    let spec = chars[i + 1]
                    switch spec {
                    case "s", "d", "i", "f", "o", "O", "c":
                        i += 2
                        if values.isEmpty { run.append("%"); run.append(spec); continue }
                        let value = values.removeFirst()
                        switch spec {
                        case "c":
                            flush()
                            css = value.string ?? ""
                        case "s":
                            run += value.type == "string" ? (value.string ?? "") : plainValue(value, top: false)
                        case "d", "i":
                            run += (value.number ?? Double(value.string ?? "")).map { ConsoleFormat.integer($0) } ?? "NaN"
                        case "f":
                            run += value.number.map { ConsoleFormat.number($0) } ?? "NaN"
                        default:
                            flush()
                            out.append(.value(value))
                        }
                        continue
                    case "%":
                        run.append("%")
                        i += 2
                        continue
                    default:
                        break
                    }
                }
                run.append(c)
                i += 1
            }
            flush()
            for value in values {
                out.append(.text(" ", css: ""))
                out.append(value.type == "string" ? .text(value.string ?? "", css: "") : .value(value))
            }
            return out
        }
        for (index, value) in values.enumerated() {
            if index > 0 { out.append(.text(" ", css: "")) }
            out.append(value.type == "string" ? .text(value.string ?? "", css: "") : .value(value))
        }
        values = []
        return out
    }

    /// %d and %i: the whole part, as JavaScript's parseInt would write it.
    static func integer(_ n: Double) -> String {
        guard n.isFinite else { return "NaN" }
        let whole = n.rounded(.towardZero)
        return abs(whole) < 9e15 ? String(Int64(whole)) : String(format: "%.0f", whole)
    }

    static func number(_ n: Double) -> String {
        if n == n.rounded(), abs(n) < 1e15 { return String(Int64(n)) }
        return String(n)
    }

    /// A value in words, as Chromium writes it inline.
    static func plainValue(_ value: ConsoleValue, top: Bool) -> String {
        switch value.type {
        case "string": return top ? (value.string ?? "") : "'" + (value.string ?? "") + "'"
        case "number": return value.number.map(number) ?? value.description ?? "NaN"
        case "boolean": return value.bool.map { $0 ? "true" : "false" } ?? value.description ?? ""
        case "undefined": return "undefined"
        case "symbol", "bigint": return value.description ?? ""
        case "function": return "ƒ " + functionHead(value)
        default:
            if value.subtype == "null" { return "null" }
            if let preview = value.preview { return previewText(preview, value: value) }
            return value.description ?? value.className ?? "Object"
        }
    }

    /// `name(a, b)` from a function's description.
    static func functionHead(_ value: ConsoleValue) -> String {
        let text = value.description ?? "function"
        if text.hasPrefix("class ") { return text }
        let head = text.prefix { $0 != "{" }.replacingOccurrences(of: "function ", with: "").trimmingCharacters(in: .whitespaces)
        return head.isEmpty ? "anonymous()" : String(head.prefix(120))
    }

    /// An object's one line: {a: 1, b: 'x'}, (3) [1, 2, 3], Map(2) {k => v}.
    static func previewText(_ preview: ConsolePreview, value: ConsoleValue?) -> String {
        let subtype = preview.subtype ?? value?.subtype
        func prop(_ p: ConsolePreview.Property) -> String {
            if let nested = p.preview.first {
                if p.type == "object", nested.subtype == "array" { return "Array(\(nested.size ?? 0))" }
                if p.type == "object" { return nested.subtype == nil ? "{…}" : (nested.description ?? "{…}") }
            }
            switch p.type {
            case "string": return "'" + (p.value ?? "") + "'"
            case "function": return "ƒ"
            case "object": return p.subtype == "null" ? "null" : (p.value ?? "{…}")
            default: return p.value ?? p.type
            }
        }
        let more = preview.overflow ? ", …" : ""
        switch subtype {
        case "array":
            let items = preview.properties.filter { !$0.isInternal }
            let named = items.allSatisfy { Int($0.name) != nil }
            let body = items.map { named ? prop($0) : $0.name + ": " + prop($0) }.joined(separator: ", ")
            return "(\(preview.size ?? items.count)) [" + body + more + "]"
        case "map", "weakmap":
            let body = preview.entries.map { (($0.key.first?.description) ?? "") + " => " + (($0.value.first?.description) ?? "") }.joined(separator: ", ")
            return (preview.description ?? "Map") + " {" + body + more + "}"
        case "set", "weakset":
            let body = preview.entries.map { $0.value.first?.description ?? "" }.joined(separator: ", ")
            return (preview.description ?? "Set") + " {" + body + more + "}"
        case "node":
            return nodeTag(value?.description ?? preview.description ?? "node")
        case "error", "regexp", "date":
            return value?.description ?? preview.description ?? ""
        default:
            break
        }
        if (value?.className ?? preview.description) == "Promise" {
            let state = preview.properties.first { $0.name == "status" }?.value ?? "pending"
            let result = preview.properties.first { $0.name == "result" }.map(prop)
            return "Promise {<\(state)>" + (result.map { ": " + $0 } ?? "") + "}"
        }
        let body = preview.properties.filter { !$0.isInternal }.map { $0.name + ": " + prop($0) }.joined(separator: ", ")
        let name = preview.description ?? value?.className ?? "Object"
        return (name == "Object" ? "" : name + " ") + "{" + body + more + "}"
    }

    /// WebKit's node description, `div.item.big#cart`, as a tag.
    static func nodeTag(_ description: String) -> String {
        if description.hasPrefix("<") || description.hasPrefix("#") { return description }
        var name = description
        var id = ""
        var classes: [String] = []
        if let hash = name.firstIndex(of: "#") {
            id = String(name[name.index(after: hash)...].prefix { $0 != "." })
            name.removeSubrange(hash..<(name[hash...].firstIndex(of: ".") ?? name.endIndex))
        }
        let parts = name.split(separator: ".").map(String.init)
        name = parts.first ?? description
        classes = Array(parts.dropFirst())
        if name.hasPrefix("#") || name == "#text" { return description }
        var tag = "<" + name
        if !id.isEmpty { tag += " id=\"\(id)\"" }
        if !classes.isEmpty { tag += " class=\"\(classes.joined(separator: " "))\"" }
        return tag + ">"
    }

    /// The message as plain words, its values written inline.
    static func plain(_ message: ConsoleMessage) -> String {
        parts(message).map { part in
            switch part {
            case .text(let text, _): return text
            case .value(let value): return plainValue(value, top: false)
            }
        }.joined()
    }

    /// How much of a message a copy carries. Chrome copies whatever is
    /// unfolded, so a wall of stacks comes along uninvited and a folded
    /// object stays `{…}`; here the amount is picked, never the folding.
    enum Detail {
        /// One line a message: [level] words ×n (file:line). What a hand
        /// pastes into a chat.
        case brief
        /// Brief plus the page's own frames under an error, a warning or
        /// a trace, at most 8. Copy for Agent and Save as….
        case lines
        /// Everything: every frame, the async seams between them, and
        /// each object's JSON (from the page) under its line, so nothing
        /// has to be unfolded first.
        case full
    }

    /// One line for Copy and Copy for Agent: [level] words (file:line), and
    /// the page's own frames under it.
    static func line(_ message: ConsoleMessage, detail: Detail = .lines, json: [String: String] = [:]) -> String {
        switch message.kind {
        case .command: return "> " + message.text
        case .result:
            var line = (message.level == "error" ? "" : "< ") + (message.level == "error" ? message.text : plainValue(message.values.first ?? ConsoleValue(type: "undefined"), top: false))
            if detail == .full { line += objects(message, json: json) }
            return line
        case .navigated: return "Navigated to " + message.url
        default: break
        }
        var line = "[\(message.level)] " + message.words
        if message.count > 1 { line += " ×\(message.count)" }
        if let place = message.place { line += "  (\(place.short))" }
        guard detail != .brief else { return line }
        let stacked = message.level == "error" || message.level == "warning" || message.type == "trace"
        if detail == .full {
            for frame in message.stack where !frame.ours {
                if let async = frame.async { line += "\n    — " + async + " —"; continue }
                guard stacked || !message.stack.isEmpty else { continue }
                line += "\n    at " + (frame.function.isEmpty ? "(anonymous)" : frame.function) + " (" + (frame.place?.short ?? frame.url) + ")"
            }
            line += objects(message, json: json)
            return line
        }
        if stacked {
            for frame in message.stack.filter({ !$0.ours && $0.async == nil }).prefix(8) {
                line += "\n    at " + (frame.function.isEmpty ? "(anonymous)" : frame.function) + " (" + (frame.place?.short ?? frame.url) + ")"
            }
        }
        return line
    }

    /// The objects a message holds, each as the JSON the page gave for its
    /// id (`json`), indented under the line; a preview where no JSON came.
    private static func objects(_ message: ConsoleMessage, json: [String: String]) -> String {
        var out = ""
        for value in message.values where value.objectId != nil && value.type == "object" && value.subtype != "null" {
            let text = json[value.objectId ?? ""] ?? plainValue(value, top: true)
            guard !text.isEmpty else { continue }
            out += "\n" + text.split(separator: "\n", omittingEmptySubsequences: false).map { "    " + $0 }.joined(separator: "\n")
        }
        return out
    }

    /// The messages as one text, a line (and its details) each.
    static func text(_ messages: [ConsoleMessage], detail: Detail, json: [String: String] = [:]) -> String {
        messages.map { line($0, detail: detail, json: json) }.joined(separator: "\n")
    }
}

/// The ways the console is copied, in the toolbar's picker and the
/// list's menu: what each puts on the pasteboard is shown beside the
/// row before it is pressed, as a model picker shows a model.
enum ConsoleCopyWay: String, CaseIterable, Identifiable {
    case brief, details, markdown, file, saveAs
    var id: String { rawValue }

    var title: String {
        switch self {
        case .brief: "Copy console"
        case .details: "Copy with details"
        case .markdown: "Copy as Markdown, with the page"
        case .file: "Save to file, copy path"
        case .saveAs: "Save as…"
        }
    }

    /// The rows under the line: the file ones.
    var saves: Bool { self == .file || self == .saveAs }

    /// What the card says over the piece, where the piece alone doesn't.
    var blurb: String? {
        switch self {
        case .file: "The full text goes to a file, only its path is copied. Hand the path to an agent, it reads the file itself."
        case .saveAs: "Pick where the file goes. The same lines as the Markdown, no heading."
        default: nil
        }
    }

    /// What the way puts on the pasteboard (or in the file), for the
    /// card: the text, and the lines it has.
    @MainActor func text(_ messages: [ConsoleMessage], json: [String: String], browser: Browser) -> String {
        switch self {
        case .brief: ConsoleFormat.text(messages, detail: .brief)
        case .details, .file: ConsoleFormat.text(messages, detail: .full, json: json)
        case .markdown: browser.consoleMarkdown(messages)
        case .saveAs: ConsoleFormat.text(messages, detail: .lines)
        }
    }

    @MainActor func run(_ messages: [ConsoleMessage], browser: Browser) {
        switch self {
        case .brief: browser.consoleCopy(messages)
        case .details: browser.consoleCopyDetails(messages)
        case .markdown: browser.consoleCopyForAgent(messages)
        case .file: browser.consoleSaveAndCopyPath(messages)
        case .saveAs: browser.consoleSave(messages)
        }
    }
}

/// Only literal expressions can run ahead of Return. Reading a property
/// may invoke a getter or Proxy, and even a familiar function can be
/// replaced by the page. WebKit has no throwOnSideEffect evaluation.
enum ConsoleEager {
    static func safe(_ expression: String) -> Bool {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count < 400, !trimmed.contains("\n") else { return false }
        var bare = trimmed.replacingOccurrences(of: #"'(?:[^'\\]|\\.)*'|"(?:[^"\\]|\\.)*""#, with: "0", options: .regularExpression)
        guard bare.range(of: #"\+\+|--|=>|(^|[^=!<>])=(?!=)"#, options: .regularExpression) == nil else { return false }
        bare = bare.replacingOccurrences(of: #"\b(?:true|false|null)\b|(?:0[xX][0-9a-fA-F]+|0[bB][01]+|0[oO][0-7]+|(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?)"#, with: "0", options: .regularExpression)
        // A slash can only divide a primitive or a parenthesized expression.
        // RegExp literals are objects whose coercion may call page code.
        guard bare.range(of: #"(^|[^0)\s])\s*/"#, options: .regularExpression) == nil else { return false }
        return bare.range(of: #"^[0\s()+*/%<>=!&|^~?:-]+$"#, options: .regularExpression) != nil
    }
}
