import SwiftUI
import WebKit

// JSON shown as a tree (docs/json-viewer.md).
//
// A main document that came as JSON is read and drawn by json-view.js, in
// the page's own WebContent process, in yab's world: a tree that folds, a
// text set out with line numbers, or the document as it was sent. All yab's
// main thread hears is one message saying what the page is (JSONRelay), for
// the { } door in the band over the page, the words beside it when
// something is off, and the commands in ⌘K and the View menu.
//
// Agents never see the tree: the body WebKit made stays in the document,
// hidden, so `text`, `snapshot`, `yab text` and ⌘J read the JSON as sent.

/// How a link that answers with JSON shows: Settings › Developers › JSON,
/// and the door's card, which are the same value.
enum JSONShow: String, CaseIterable {
    case tree, text, sent

    static let key = "json.view"
    /// As stored, for a page being armed in any window.
    static var current: JSONShow { JSONShow(rawValue: Store.settings.string(forKey: key) ?? "") ?? .tree }

    var title: String {
        switch self {
        case .tree: "Tree"
        case .text: "Text"
        case .sent: "As Sent"
        }
    }

    var detail: String {
        switch self {
        case .tree: "Display JSON as a collapsible, searchable tree."
        case .text: "Display formatted JSON with indentation and line numbers."
        case .sent: "Display the original JSON response."
        }
    }
}

/// What the viewer said of the document in front.
struct JSONPage: Equatable {
    struct Failure: Equatable {
        let line: Int
        let column: Int
        let message: String
    }

    var shown: JSONShow
    /// The document's length in characters, which is its size in bytes for
    /// JSON's ASCII and near enough for the rest.
    var size: Int
    /// Past 25 MB: opened as text first.
    var big: Bool
    /// Sent as text/plain, and read as JSON all the same.
    var plain: Bool
    var ndjson: Bool
    /// The security prefix cut off its front, `)]}'`.
    var skipped: String?
    var failure: Failure?

    init?(_ body: [String: Any]) {
        guard let shown = (body["shown"] as? String).flatMap(JSONShow.init) else { return nil }
        self.shown = shown
        size = (body["size"] as? NSNumber)?.intValue ?? 0
        big = body["big"] as? Bool ?? false
        plain = body["plain"] as? Bool ?? false
        ndjson = body["ndjson"] as? Bool ?? false
        skipped = body["skipped"] as? String
        failure = (body["error"] as? [String: Any]).map {
            Failure(line: ($0["line"] as? NSNumber)?.intValue ?? 0, column: ($0["col"] as? NSNumber)?.intValue ?? 0,
                    message: $0["message"] as? String ?? "")
        }
    }

    /// The words in the band, left of the door: only when something is off,
    /// or the page isn't what the setting would show.
    var sizeWords: String {
        ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

/// The main document's answer, kept for the door's card: its status, its
/// headers and how long it took to come.
struct PageResponse: Equatable {
    struct Header: Equatable {
        let name: String
        let value: String
    }

    let url: URL
    let status: Int
    let headers: [Header]
    let milliseconds: Int?

    /// "404 Not Found", as the band says it.
    var statusLine: String {
        let words = Self.reasons[status] ?? HTTPURLResponse.localizedString(forStatusCode: status).capitalized
        return "\(status) \(words)"
    }

    /// The reason phrases servers send, as RFC 9110 writes them: Foundation's
    /// own say "no error" for 200.
    static let reasons: [Int: String] = [
        200: "OK", 201: "Created", 202: "Accepted", 204: "No Content", 206: "Partial Content",
        301: "Moved Permanently", 302: "Found", 304: "Not Modified", 307: "Temporary Redirect", 308: "Permanent Redirect",
        400: "Bad Request", 401: "Unauthorized", 402: "Payment Required", 403: "Forbidden", 404: "Not Found",
        405: "Method Not Allowed", 406: "Not Acceptable", 408: "Request Timeout", 409: "Conflict", 410: "Gone",
        412: "Precondition Failed", 413: "Content Too Large", 415: "Unsupported Media Type",
        422: "Unprocessable Content", 429: "Too Many Requests", 500: "Internal Server Error", 501: "Not Implemented",
        502: "Bad Gateway", 503: "Service Unavailable", 504: "Gateway Timeout",
    ]

    var failed: Bool { status >= 400 }

    init(url: URL, status: Int, headers: [Header], milliseconds: Int?) {
        self.url = url
        self.status = status
        self.headers = headers
        self.milliseconds = milliseconds
    }

    /// The headers in the order a person reads them: what it is, how big,
    /// how long it keeps, then the rest by name.
    init?(_ response: URLResponse, since started: CFTimeInterval?) {
        guard let http = response as? HTTPURLResponse, let url = http.url else { return nil }
        let first = ["content-type", "content-length", "cache-control", "etag"]
        let all = http.allHeaderFields.map { Header(name: String(describing: $0.key).lowercased(), value: String(describing: $0.value)) }
        let sorted = all.sorted { a, b in
            let ia = first.firstIndex(of: a.name) ?? first.count, ib = first.firstIndex(of: b.name) ?? first.count
            return ia != ib ? ia < ib : a.name < b.name
        }
        self.init(url: url, status: http.statusCode, headers: sorted,
                  milliseconds: started.map { Int(((CACurrentMediaTime() - $0) * 1000).rounded()) })
    }
}

/// The viewer's word to yab, in yab's world, from the main frame only.
final class JSONRelay: NSObject, PageScriptReceiving {
    static let name = "yabJSON"
    weak var tab: Tab?

    func receive(_ message: PageScriptMessage) {
        guard message.frame.isMain, let body = message.body as? [String: Any],
              let kind = body["kind"] as? String else { return }
        MainActor.assumeIsolated {
            guard let tab else { return }
            switch kind {
            case "state":
                tab.json = JSONPage(body)
            case "copy":
                guard let text = body["text"] as? String else { return }
                JSONView.copy(text)
            case "open":
                guard let link = (body["url"] as? String).flatMap(URL.init(string:)), ["http", "https"].contains(link.scheme ?? ""),
                      let browser = BrowserWindows.shared.owner(of: tab.id)?.browser else { return }
                _ = browser.open(link, foreground: false, from: tab)
            default:
                break
            }
        }
    }
}

@MainActor
enum JSONView {
    /// The JSON extensions people install for what this does. One of them
    /// on, Yab steps aside: two viewers on one page fight over its body.
    static let extensions: [String: String] = [
        "bcjindcccaagfpapjjmafapmmgkkhgoa": "JSON Formatter",
        "gbmdgpbipfallnflgajpaliibnhdgobh": "JSON Viewer",
        "eifflpmocdbdmepbjaopkkhbfmdgijcc": "JSON Viewer Pro",
        "chklaanhfefbnpoihckbnefhakgolnmc": "JSONVue",
        "hdmbdioamgdkppmocchpkjhbpfmpjiei": "JSON Lite",
    ]

    /// The JSON extension that shows these pages instead of Yab, by name.
    static var yieldsTo: String? {
        guard #available(macOS 15.4, *) else { return nil }
        return Extensions.shared.installed.first { $0.enabled && extensions[$0.id] != nil }.map { extensions[$0.id] ?? $0.name }
    }

    /// Only the selected engine's profile can replace its JSON viewer.
    static func yieldsTo(for tab: Tab) -> String? {
        if tab.engineKind == .chromium {
            guard let page = tab.builtPage as? ChromiumPage else { return nil }
            return yieldsTo(chromium: page.extensions.items, privateMode: page.privateMode)
        }
        return yieldsTo
    }

    static func yieldsTo(chromium items: [ChromiumExtensions.Item], privateMode: Bool) -> String? {
        guard !privateMode else { return nil }
        return items.first { $0.enabled && extensions[$0.id] != nil }.map { extensions[$0.id] ?? $0.name }
    }

    /// The colors of DevTools › Network › Preview, light and dark, for the
    /// page's style sheet.
    static var colors: String {
        func hex(_ value: Int) -> String { String(format: "#%06x", value) }
        let pairs = NetHighlight.json.map { "\"\($0.name)\":[\"\(hex($0.light))\",\"\(hex($0.dark))\"]" }
        return "{" + pairs.joined(separator: ",") + "}"
    }

    /// On the clipboard: a test run's own one, never the person's.
    static func copy(_ text: String) {
        let board = PageCopy.board
        board.clearContents()
        board.setString(text, forType: .string)
        copies += 1
        copied = text
    }

    /// For the bench: what was copied and saved last, and how often.
    static var copies = 0
    static var copied: String?
    static var saved: URL?

    /// A file name for the document: the address's last part, `.json` on it.
    static func fileName(for url: URL?) -> String {
        let last = url?.lastPathComponent ?? ""
        let stem = last.isEmpty || last == "/" ? (url?.host() ?? "response") : last
        let safe = stem.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let lower = safe.lowercased()
        return lower.hasSuffix(".json") || lower.hasSuffix(".ndjson") || lower.hasSuffix(".jsonl") ? safe : safe + ".json"
    }

    /// The document's own bytes, as they came: the main resource of the
    /// page's web archive, which WebKit keeps as received. Its text, when
    /// there is no archive.
    static func bytes(of tab: Tab, _ done: @escaping (Data?) -> Void) {
        guard let page = tab.builtPage else { return done(nil) }
        let web = page.webKit
        if let url = page.url, url.isFileURL, let data = try? Data(contentsOf: url) { return done(data) }
        command(tab, ["do": "raw"]) { answer in
            guard let text = answer as? String else { return done(nil) }
            guard let web else { return done(Data(text.utf8)) }
            web.createWebArchiveData { result in
                MainActor.assumeIsolated {
                    // The archive's own bytes only when they are this text
                    // (a BOM or CRLF kept); WebKit may archive a text
                    // document as the HTML it made of it.
                    if case .success(let archive) = result,
                       let plist = try? PropertyListSerialization.propertyList(from: archive, format: nil) as? [String: Any],
                       let main = plist["WebMainResource"] as? [String: Any], let data = main["WebResourceData"] as? Data,
                       let decoded = String(data: data, encoding: .utf8),
                       decoded.replacingOccurrences(of: "\r\n", with: "\n").trimmingPrefix("\u{FEFF}") == text.replacingOccurrences(of: "\r\n", with: "\n") {
                        return done(data)
                    }
                    done(Data(text.utf8))
                }
            }
        }
    }

    /// A word to the viewer on `tab`'s page, and what it answers.
    static func command(_ tab: Tab, _ command: [String: Any], then: ((Any?) -> Void)? = nil) {
        guard let page = tab.builtPage else { then?(nil); return }
        page.call("return window.__yabJSON ? window.__yabJSON.command(c) : null",
                  arguments: ["c": command], in: .yab) { result in
            then?(try? result.get())
        }
    }
}

// MARK: - the browser's commands

extension Browser {
    /// The page in front, when it is a JSON document the viewer has.
    var jsonFront: Tab? {
        guard let tab = active, tab.json != nil else { return nil }
        return tab
    }

    /// Tree or Text, from the door's card, ⌘K or the View menu: the setting
    /// too, as the card and Settings are one value. With As Sent chosen
    /// there, only this page.
    func showJSON(_ show: JSONShow, in given: Tab? = nil) {
        guard let tab = given ?? jsonFront else { return }
        if prefs.jsonView != .sent || show == .sent { prefs.jsonView = show }
        JSONView.command(tab, ["do": "mode", "to": show.rawValue])
    }

    /// Text if it is a tree now, a tree otherwise.
    func toggleJSON() {
        guard let tab = jsonFront, let page = tab.json else { return }
        showJSON(page.shown == .tree ? .text : .tree, in: tab)
    }

    func copyJSON() {
        guard let tab = jsonFront else { return }
        JSONView.command(tab, ["do": "copy"]) { text in
            guard let text = text as? String else { return }
            JSONView.copy(text)
        }
    }

    func expandJSON() {
        guard let tab = jsonFront else { return }
        JSONView.command(tab, ["do": "expand"])
    }

    /// The band's "Not valid JSON · line 7": to the line.
    func revealJSONError() {
        guard let tab = jsonFront else { return }
        JSONView.command(tab, ["do": "reveal"])
    }

    /// ⌘S on a JSON page: the answer byte for byte in Downloads, named from
    /// the address (`next.js.json`), into the downloads as a capture is.
    func saveJSON() {
        guard let tab = jsonFront else { return }
        let name = JSONView.fileName(for: tab.address)
        let from = tab.address?.host() ?? ""
        let title = tab.title
        let page = tab.address
        let folder = downloadFolder(for: tab)
        JSONView.bytes(of: tab) { [weak self] data in
            guard let self, let data else { return }
            let target = Browser.free(name, in: folder)
            do {
                try data.write(to: target)
            } catch {
                return self.announce("Couldn\u{2019}t save \(name)", mark: "exclamationmark.triangle")
            }
            self.loot.add(Keep(name: target.lastPathComponent, from: from, path: target.path, date: Date(), page: page, pageTitle: title))
            self.hoard.lifting()
            self.hoard.touched(target.lastPathComponent)
            JSONView.saved = target
            // Said in words only where no downloads button stands to take it.
            if !self.bandDoors { self.announce("Saved to Downloads as \(target.lastPathComponent)", mark: "arrow.down.circle") }
        }
    }
}

// MARK: - the door and its card

/// The { } door in the band over a JSON page, beside Capture, and what the
/// band says left of it when something is off: as Developer Mode's doors
/// say "1 error" (DevBandDoors).
struct JSONBandDoor: View {
    var browser: Browser
    var tab: Tab
    private var card = JSONCardState.shared
    @Environment(\.tone) private var tone

    /// A word in the band: said, red, or a button.
    struct Word: Equatable {
        enum Kind { case quiet, red, error, tree }
        let text: String
        let kind: Kind
    }

    /// The words, in order: the status of an answer that failed, then why
    /// there is no tree, or that it was sent as text. None when all is well.
    static func words(_ page: JSONPage, _ response: PageResponse?) -> [Word] {
        var out: [Word] = []
        if let response, response.failed { out.append(Word(text: response.statusLine, kind: .red)) }
        guard page.shown != .sent else { return out }
        if let failure = page.failure {
            out.append(Word(text: "Not valid JSON \u{00B7} line \(failure.line.formatted())", kind: .error))
        } else if page.big, page.shown == .text {
            out.append(Word(text: "\(page.sizeWords), opened as text", kind: .quiet))
            out.append(Word(text: "Show as Tree", kind: .tree))
        } else if page.shown == .text {
            out.append(Word(text: "Text", kind: .quiet))
        }
        if page.plain { out.append(Word(text: "Sent as text", kind: .quiet)) }
        return out
    }

    var body: some View {
        if let page = tab.json {
            HStack(spacing: Door.Size.band.gap) {
                ForEach(Self.words(page, tab.jsonResponse), id: \.text) { word($0) }
                Door(icon: "curlybraces", on: page.shown == .tree || card.open == tab.id, help: "JSON") {
                    browser.focus(tab)
                    card.open = card.open == tab.id ? nil : tab.id
                }
                .popover(isPresented: Binding(get: { card.open == tab.id }, set: { if !$0, card.open == tab.id { card.open = nil } }),
                         arrowEdge: .bottom) {
                    JSONCard(browser: browser, tab: tab, prefs: browser.prefs, done: { card.open = nil })
                }
            }
        }
    }

    @ViewBuilder private func word(_ word: Word) -> some View {
        switch word.kind {
        case .error:
            Button { browser.focus(tab); browser.revealJSONError() } label: {
                Text(word.text).foregroundStyle(DevLook.red)
            }
            .buttonStyle(.yab(.quiet, .small))
            .focusable(false)
            .keyTip("Show the Line")
        case .tree:
            Button(word.text) { browser.focus(tab); browser.showJSON(.tree, in: tab) }
                .buttonStyle(.yab(.quiet, .small, tint: .accentColor))
                .focusable(false)
        case .quiet, .red:
            Text(word.text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(word.kind == .red ? DevLook.red : Palette.muted(on: tone))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 8)
        }
    }
}

/// Which tab's card is out, one at a time, for the door and the bench.
@MainActor
@Observable final class JSONCardState {
    static let shared = JSONCardState()
    var open: Tab.ID?
}

/// The door's card: Tree or Text, the JSON copied or saved, every box
/// opened, and the server's answer.
struct JSONCard: View {
    var browser: Browser
    var tab: Tab
    var prefs: Preferences
    let done: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GlassTrack(title: "Show JSON as", options: options, button: .regular, selection: Binding(
                get: { tab.json?.shown ?? prefs.jsonView },
                set: { browser.showJSON($0, in: tab) }
            ))
            .frame(maxWidth: .infinity)
            // Picked by the pointer: no focus ring round the chosen half.
            .focusEffectDisabled()
            VStack(spacing: 0) {
                row(copied ? "Copied" : "Copy JSON", keys: nil) {
                    browser.copyJSON()
                    copied = true
                }
                row("Save JSON\u{2026}", keys: "\u{2318}S") {
                    done()
                    browser.saveJSON()
                }
                if tab.json?.shown == .tree, tab.json?.ndjson == false {
                    row("Expand All", keys: "\u{2325}\u{2192}") { browser.expandJSON() }
                }
            }
            if let response = tab.jsonResponse {
                Divider().overlay(Palette.hairline)
                HStack {
                    Text("Response").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text(summary(response)).font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
                .padding(.horizontal, 8)
                .padding(.top, 4)
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 2) {
                    GridRow {
                        Text("status").font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.muted)
                        Text(response.statusLine).font(.system(size: 11, design: .monospaced))
                    }
                    ForEach(Array(response.headers.prefix(24).enumerated()), id: \.offset) { _, header in
                        GridRow {
                            Text(header.name)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Palette.muted)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(width: 118, alignment: .leading) // design: the names' column, as drawn
                            Text(header.value)
                                .font(.system(size: 11, design: .monospaced))
                                .lineLimit(3)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
            }
        }
        .padding(8)
        .frame(width: 280)
        .background(Palette.ground)
    }

    private var options: [(title: String, value: JSONShow)] {
        var all: [(title: String, value: JSONShow)] = [("Tree", .tree), ("Text", .text)]
        if prefs.jsonView == .sent || tab.json?.shown == .sent { all.append(("As Sent", .sent)) }
        return all
    }

    private func summary(_ response: PageResponse) -> String {
        let size = tab.json.map { ByteCountFormatter.string(fromByteCount: Int64($0.size), countStyle: .file) } ?? ""
        guard let ms = response.milliseconds else { return size }
        return size.isEmpty ? "\(ms) ms" : "\(size) \u{00B7} \(ms) ms"
    }

    private func row(_ title: String, keys: String?, act: @escaping () -> Void) -> some View {
        Button(action: act) {
            HStack {
                Text(title)
                Spacer(minLength: 8)
                if let keys { KeyGlyphs(keys: keys, size: 12, tint: nil, rest: 0.6) }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.yab(.quiet, .regular))
        .focusable(false)
    }
}

// MARK: - the bench

extension Browser {
    /// What the bench sees of JSON in front (Bench "probe").
    func jsonProbe() -> [String: Any] {
        var out: [String: Any] = ["pref": prefs.jsonView.rawValue, "copies": JSONView.copies,
                                  "copied": String((JSONView.copied ?? "").prefix(20000)), "saved": JSONView.saved?.path ?? "",
                                  "yields": active.flatMap { JSONView.yieldsTo(for: $0) } ?? "", "bar": barShown]
        guard let tab = active else { return out }
        out["card"] = JSONCardState.shared.open == tab.id
        if let page = tab.json {
            out["page"] = ["shown": page.shown.rawValue, "size": page.size, "big": page.big, "plain": page.plain,
                           "ndjson": page.ndjson, "skipped": page.skipped ?? "", "errorLine": page.failure?.line ?? 0] as [String: Any]
            out["words"] = JSONBandDoor.words(page, tab.jsonResponse).map(\.text)
        }
        if let response = tab.jsonResponse {
            out["status"] = response.statusLine
            out["headers"] = response.headers.map { "\($0.name): \($0.value)" }
        }
        return out
    }

    /// The door's card and commands, as a hand would use them (Bench "ui").
    func jsonBench(_ asked: [String: Any]) {
        if let pref = (asked["pref"] as? String).flatMap(JSONShow.init) { prefs.jsonView = pref }
        if let show = (asked["show"] as? String).flatMap(JSONShow.init) { showJSON(show) }
        if let on = asked["card"] as? Bool { JSONCardState.shared.open = on ? active?.id : nil }
        if asked["toggle"] as? Bool == true { toggleJSON() }
        if asked["copy"] as? Bool == true { copyJSON() }
        if asked["save"] as? Bool == true { saveJSON() }
        if asked["expand"] as? Bool == true { expandJSON() }
        if asked["reveal"] as? Bool == true { revealJSONError() }
    }
}
