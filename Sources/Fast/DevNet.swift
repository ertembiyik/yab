import AppKit
import Foundation

// Network, as Chromium's DevTools has it (docs/developer-mode.md, "Network").
//
// What the page asks the network for is heard where WebKit hears it: in its
// inspector's backend, below the page's own scripts, and handed to the
// inspector's page as its protocol's Network events. That page is docked in
// the card already (DevTools.swift), and keeps every request as a
// WI.Resource: redirects, timings, sizes, the headers really sent, the
// initiator with its stack, WebSocket frames. A script of yab's in it
// (DevNet.script) passes what changed to yab every quarter of a second, and
// NetLog keeps it for the tab, as rows the way Chromium lists them: each hop of
// a redirect a row of its own. The panel draws them (DevNetPane.swift);
// bodies, overrides, blocking and throttling go back the same way.
//
// WebKit's own Network is the same data in Safari's look; it stays where its
// inspector puts it, and nothing of yab's points there.

/// One resource as WebKit's inspector keeps it, the bridge's record of it.
/// Times are seconds on the inspector's clock, which every resource and the
/// page's own moments share; wall times are seconds since 1970.
struct NetResource: Equatable {
    struct Timing: Equatable {
        var start, redirectStart, redirectEnd, fetchStart, dnsStart, dnsEnd, connectStart, connectEnd, secureStart, requestStart, responseStart, responseEnd: Double?
    }
    struct Hop: Equatable {
        var url: String
        var method: String
        var status: Int
        var statusText: String
        var requestHeaders: [NetHeader]
        var responseHeaders: [NetHeader]
        /// When its redirect came back.
        var at: Double?
    }
    struct Frame: Equatable {
        /// Sent by the page (↑), or received (↓).
        var outgoing: Bool
        var opcode: Int
        var data: String?
        var length: Int
        /// Seconds since 1970.
        var wall: Double
    }
    struct Event: Equatable {
        var id: String
        var type: String
        var data: String
        var wall: Double
    }
    struct Initiator: Equatable {
        enum Kind: String { case parser, script, other, redirect, preflight }
        var kind: Kind = .other
        /// The resource whose code or markup asked for it, when WebKit knows.
        var resource: Int?
        var url: String = ""
        var line: Int = 0
        var column: Int = 0
        /// Function, address, line, column; the page's frames first.
        var stack: [NetFrameLine] = []
    }

    var id: Int
    /// The bridge's own number for it, in the inspector it came from; 0 for
    /// one brought in from a HAR file.
    var bridge = 0
    /// Which connection of the inspector heard it (NetLog.session).
    var session = 0
    var target = ""
    var frame = ""
    var loader = ""
    /// The main resource of the page's top frame.
    var main = false
    var url = ""
    var method = "GET"
    var type = "other"
    var mime = ""
    var status = 0
    var statusText = ""
    var source = "unknown"
    var proto = ""
    var priority = ""
    var remote = ""
    var connection = ""
    var size = 0
    var transferred = 0
    var requestHeaderBytes = 0
    var requestBodyBytes = 0
    var responseHeaderBytes = 0
    var responseBodyBytes = 0
    var timing = Timing()
    var sent: Double?
    var wall: Double?
    var responded: Double?
    var ended: Double?
    var finished = false
    var failed = false
    var canceled = false
    var failure = ""
    var referrerPolicy = ""
    var initiator = Initiator()
    var requestHeaders: [NetHeader] = []
    var responseHeaders: [NetHeader] = []
    var postData: String?
    var postType: String?
    var redirects: [Hop] = []
    var security: [String: String] = [:]
    var frames: [Frame] = []
    var events: [Event] = []
    var socketOpen = false
    /// Brought in from a HAR file, not heard from this page.
    var imported = false
    /// Slowed or blocked by a rule of Request conditions, by its condition.
    var throttledBy: String?
    var blockedBy: String?
}

struct NetHeader: Equatable, Hashable {
    let name: String
    let value: String
}

struct NetFrameLine: Equatable {
    let function: String
    let url: String
    let line: Int
    let column: Int
}

extension Array where Element == NetHeader {
    /// The first value of a header, its name in any case.
    func value(_ name: String) -> String? {
        first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// A row of the table: a resource, or one hop of its redirects, as Chromium
/// lists each request it made on the way to where it ended.
struct NetRow: Identifiable, Equatable {
    let id: Int
    let resource: NetResource
    /// The redirect this row is, or nil for where the resource ended.
    let hop: Int?
    /// The row this one came from: the hop before it, for a redirect's end.
    let from: Int?

    static func ids(_ resource: Int, hop: Int?) -> Int { resource << 5 | (hop.map { Swift.min($0, 30) } ?? 31) }

    var url: String { hop.map { resource.redirects[$0].url } ?? resource.url }
    var method: String { hop.map { resource.redirects[$0].method } ?? resource.method }
    var status: Int { hop.map { resource.redirects[$0].status } ?? resource.status }
    var statusText: String { hop.map { resource.redirects[$0].statusText } ?? resource.statusText }
    var requestHeaders: [NetHeader] { hop.map { resource.redirects[$0].requestHeaders } ?? resource.requestHeaders }
    var responseHeaders: [NetHeader] { hop.map { resource.redirects[$0].responseHeaders } ?? resource.responseHeaders }
    var isRedirect: Bool { hop != nil }
    var finished: Bool { hop != nil || resource.finished }
    var failed: Bool { hop == nil && (resource.failed || resource.blockedBy != nil) }
    var pending: Bool { hop == nil && !resource.finished && !resource.failed && resource.blockedBy == nil }
    /// A socket or a stream open: Chrome's "Pending" with its own status.
    var streaming: Bool { pending && (resource.type == "websocket" || resource.type == "eventsource") && resource.status > 0 }
    var fromCache: Bool { hop == nil && (resource.source == "memory-cache" || resource.source == "disk-cache") }
    /// Red in the table: failed, blocked, or answered 400 or worse.
    var bad: Bool { failed || (status >= 400 && hop == nil) }

    var host: String { URL(string: url)?.host(percentEncoded: false) ?? "" }
    var hostAndPort: String {
        guard let parts = URLComponents(string: url), let host = parts.host else { return "" }
        return parts.port.map { "\(host):\($0)" } ?? host
    }
    var scheme: String { URLComponents(string: url)?.scheme ?? "" }
    var path: String {
        guard let parts = URLComponents(string: url) else { return url }
        return (parts.percentEncodedPath.isEmpty ? "/" : parts.percentEncodedPath) + (parts.percentEncodedQuery.map { "?" + $0 } ?? "")
    }

    /// Chrome's name for it: the file and query, or the host for a page.
    var name: String {
        if url.hasPrefix("data:") { return String(url.prefix(48)) }
        guard let parts = URLComponents(string: url) else { return url }
        let last = parts.percentEncodedPath.split(separator: "/").last.map(String.init) ?? ""
        if last.isEmpty { return (parts.host ?? url) + (parts.percentEncodedQuery.map { "?" + $0 } ?? "") }
        return last + (parts.percentEncodedQuery.map { "?" + $0 } ?? "")
    }

    /// Chrome's Type column.
    var typeLabel: String {
        if isRedirect { return "Redirect" }
        switch resource.type {
        case "image":
            let sub = resource.mime.split(separator: "/").last.map(String.init) ?? ""
            return sub.isEmpty ? "image" : sub
        case "stylesheet": return "stylesheet"
        default: return resource.type
        }
    }

    /// Chrome's filter chips: Fetch/XHR, Doc, CSS, JS and the rest.
    var category: NetCategory {
        if isRedirect { return .other }
        switch resource.type {
        case "fetch", "xhr", "eventsource": return .fetch
        case "document": return .doc
        case "stylesheet": return .css
        case "script": return .js
        case "font": return .font
        case "image": return resource.mime.hasPrefix("video/") || resource.mime.hasPrefix("audio/") ? .media : .img
        case "websocket": return .socket
        default:
            if resource.mime.hasPrefix("video/") || resource.mime.hasPrefix("audio/") { return .media }
            if resource.mime == "application/wasm" { return .wasm }
            if resource.mime == "application/manifest+json" { return .manifest }
            return .other
        }
    }

    /// Chrome's Status column.
    var statusLabel: String {
        if hop == nil, let rule = resource.blockedBy { return rule == "content" ? "(blocked:other)" : "(blocked:devtools)" }
        if hop == nil, resource.canceled { return "(canceled)" }
        if hop == nil, resource.failed {
            let words = resource.failure.lowercased()
            return words.contains("access-control") || words.contains("access control") || words.contains("cors") ? "CORS error" : "(failed)"
        }
        if streaming { return String(status) }
        if pending { return "(pending)" }
        return status > 0 ? String(status) : "(unknown)"
    }

    /// The words under the status in big rows, and its tip.
    var statusWords: String {
        if hop == nil, resource.failed || resource.blockedBy != nil { return resource.failure }
        return statusText
    }

    var fromCacheLabel: String? {
        guard hop == nil else { return nil }
        switch resource.source {
        case "memory-cache": return "(memory cache)"
        case "disk-cache": return "(disk cache)"
        case "service-worker": return "(ServiceWorker)"
        case "inspector-override": return "(override)"
        default: return nil
        }
    }

    /// Chrome's Size: what came over the wire, or where it came from.
    var transferred: Int {
        if hop != nil { return 0 }
        return resource.transferred
    }

    var size: Int { hop == nil ? resource.size : 0 }

    /// The Initiator column: a place, and in big rows its kind.
    var initiatorLabel: (place: String, kind: String) {
        if from != nil { return (Self.shortName(previousURL ?? ""), "Redirect") }
        let initiator = resource.initiator
        switch initiator.kind {
        case .other: return ("Other", "")
        case .preflight: return ("Preflight", "")
        case .redirect: return (Self.shortName(initiator.url), "Redirect")
        case .parser, .script:
            let file = initiator.url.isEmpty ? "" : Self.shortName(initiator.url)
            let place = initiator.line > 0 ? "\(file):\(initiator.line)" : file
            return (place.isEmpty ? "Other" : place, initiator.kind == .parser ? "Parser" : "Script")
        }
    }

    private var previousURL: String? {
        guard let hop else { return resource.redirects.last?.url }
        return hop > 0 ? resource.redirects[hop - 1].url : nil
    }

    /// A file's name as Chromium writes an initiator: the page itself is
    /// "(index)", anything else its last part.
    static func shortName(_ url: String) -> String {
        guard let parts = URLComponents(string: url) else { return url }
        let last = parts.path.split(separator: "/").last.map(String.init) ?? ""
        return last.isEmpty ? "(index)" : last
    }
}

enum NetCategory: String, CaseIterable, Hashable {
    case fetch, doc, css, js, font, img, media, manifest, socket, wasm, other

    var title: String {
        switch self {
        case .fetch: return "Fetch/XHR"
        case .doc: return "Doc"
        case .css: return "CSS"
        case .js: return "JS"
        case .font: return "Font"
        case .img: return "Img"
        case .media: return "Media"
        case .manifest: return "Manifest"
        case .socket: return "Socket"
        case .wasm: return "Wasm"
        case .other: return "Other"
        }
    }

    /// Chrome's tip on each chip.
    var tip: String {
        switch self {
        case .fetch: return "Fetch and XHR"
        case .doc: return "Document"
        case .css: return "CSS"
        case .js: return "JavaScript"
        case .font: return "Font"
        case .img: return "Image"
        case .media: return "Media"
        case .manifest: return "Manifest"
        case .socket: return "WebSocket"
        case .wasm: return "WebAssembly"
        case .other: return "Other"
        }
    }
}

// MARK: - timing

/// A request's time in Chrome's phases, in milliseconds. WebKit measures
/// when it was queued, fetched, looked up, connected, secured, asked and
/// answered; Request sent is what lies between the connection being ready
/// and the request starting, as WebKit has no moment for its end.
struct NetPhases: Equatable {
    var queueing = 0.0
    var stalled = 0.0
    var dns = 0.0
    /// The connection without its TLS, so the phases lie end to end.
    var connecting = 0.0
    var ssl = 0.0
    var sending = 0.0
    var waiting = 0.0
    var download = 0.0

    var total: Double { queueing + stalled + dns + connecting + ssl + sending + waiting + download }
    /// Chrome's latency: everything before the first byte came back.
    var latency: Double { total - download }
    /// Chrome's Initial connection, TLS included.
    var initialConnection: Double { connecting + ssl }

    enum Phase: String, CaseIterable {
        case queueing = "Queueing", stalled = "Stalled", dns = "DNS lookup", connecting = "Initial connection", ssl = "SSL"
        case sending = "Request sent", waiting = "Waiting for server response", download = "Content download"
    }

    func value(_ phase: Phase) -> Double {
        switch phase {
        case .queueing: return queueing
        case .stalled: return stalled
        case .dns: return dns
        case .connecting: return connecting
        case .ssl: return ssl
        case .sending: return sending
        case .waiting: return waiting
        case .download: return download
        }
    }

    /// From WebKit's timing for the resource; nil where it measured none
    /// (from the memory cache, or loaded before its inspector was up).
    init?(_ t: NetResource.Timing, ended: Double?) {
        guard let start = t.start else { return nil }
        let fetch = t.fetchStart ?? start
        queueing = max(0, fetch - start) * 1000
        let next = [t.dnsStart, t.connectStart, t.requestStart].compactMap { $0 }.first ?? fetch
        stalled = max(0, next - fetch) * 1000
        if let a = t.dnsStart, let b = t.dnsEnd { dns = max(0, b - a) * 1000 }
        if let a = t.connectStart, let b = t.connectEnd {
            if let s = t.secureStart, s >= a, s <= b {
                connecting = (s - a) * 1000
                ssl = (b - s) * 1000
            } else {
                connecting = max(0, b - a) * 1000
            }
        }
        if let request = t.requestStart {
            let ready = t.connectEnd ?? t.dnsEnd ?? next
            sending = max(0, request - max(ready, next)) * 1000
        }
        if let a = t.requestStart, let b = t.responseStart { waiting = max(0, b - a) * 1000 }
        if let a = t.responseStart, let b = t.responseEnd ?? ended { download = max(0, b - a) * 1000 }
    }

    init(queueing: Double = 0, stalled: Double = 0, dns: Double = 0, connecting: Double = 0, ssl: Double = 0, sending: Double = 0, waiting: Double = 0, download: Double = 0) {
        self.queueing = queueing
        self.stalled = stalled
        self.dns = dns
        self.connecting = connecting
        self.ssl = ssl
        self.sending = sending
        self.waiting = waiting
        self.download = download
    }
}

extension NetRow {
    /// When it began and ended on the inspector's clock; the end nil while
    /// it is still coming.
    var span: (start: Double, end: Double?) {
        let r = resource
        let begin = r.timing.start ?? r.sent ?? r.responded ?? r.ended ?? 0
        if let hop {
            let start = hop == 0 ? begin : (r.redirects[hop - 1].at ?? begin)
            return (start, r.redirects[hop].at ?? start)
        }
        let start = r.redirects.last?.at ?? begin
        if r.failed || r.blockedBy != nil { return (start, r.ended ?? start) }
        guard r.finished else { return (start, nil) }
        return (start, r.timing.responseEnd ?? r.ended ?? r.responded ?? start)
    }

    /// Chrome's phases for the row; a redirect's hop is one wait.
    var phases: NetPhases? {
        if hop != nil {
            let s = span
            return NetPhases(waiting: max(0, ((s.end ?? s.start) - s.start) * 1000))
        }
        if resource.failed || resource.blockedBy != nil { return nil }
        return NetPhases(resource.timing, ended: resource.ended)
    }

    /// The Time column, in milliseconds; nil while it is coming.
    var duration: Double? {
        let s = span
        guard let end = s.end else { return nil }
        return max(0, end - s.start) * 1000
    }
}

// MARK: - the log

/// The tab's requests as the card heard them, kept as Chromium keeps its
/// Network log: from the moment the card's inspector came up, cleared by a
/// new page unless Keep log is on, cleared by hand, paused by Record.
@Observable final class NetLog {
    /// Every resource in the order it was first heard; its rows in Chrome's
    /// order, each redirect's hops before where it ended.
    private(set) var rows: [NetRow] = []
    /// Moves each time the rows are built again, for what is drawn from them.
    @ObservationIgnored private(set) var generation = 0
    /// Moments of the page in front, on the same clock as the rows.
    private(set) var contentLoaded: Double?
    private(set) var loaded: Double?
    /// Pictures of the page as it loaded, for Screenshots.
    private(set) var shots: [(at: Double, image: NSImage)] = []
    /// The bridge couldn't be set up in this inspector: WebKit changed.
    var unavailable = false
    /// Record: off, nothing new is taken in.
    var recording = true

    @ObservationIgnored private var resources: [Int: NetResource] = [:]
    @ObservationIgnored private var order: [Int] = []
    /// Resources a new page let go of: what still comes for them is late.
    @ObservationIgnored private var gone = Set<Int>()
    /// When the page in front began, on the inspector's clock: a request
    /// first heard after it but sent before it was the page gone's.
    @ObservationIgnored private var pageStart: Double?
    @ObservationIgnored private var importedNext = 0
    /// Bodies asked for, kept while the log keeps their rows.
    @ObservationIgnored private(set) var bodies: [Int: NetBody] = [:]
    /// What the page's hook heard from each EventSource, by address.
    @ObservationIgnored private var streams: [String: [NetResource.Event]] = [:]
    /// The newest batch's version: rows are built again only when it moved.
    @ObservationIgnored private var changed = false
    @ObservationIgnored private var publishing: DispatchWorkItem?
    /// Each new connection of the inspector starts this again.
    @ObservationIgnored private(set) var session = 0

    /// Keep log is the browser's, not the tab's (Browser.netKeepLog).
    @ObservationIgnored var keepLog: () -> Bool = { false }

    var isEmpty: Bool { rows.isEmpty }

    func resource(_ id: Int) -> NetResource? { resources[id] }

    /// The rows' common zero: the earliest start, as Chromium's waterfall has it.
    var origin: Double? {
        rows.lazy.map(\.span.start).filter { $0 > 0 }.min()
    }

    /// Now on the inspector's clock, from a resource that has both clocks:
    /// how far a request still coming has got.
    var horizon: Double? {
        guard let id = order.last(where: { resources[$0]?.wall != nil && resources[$0]?.sent != nil }),
              let r = resources[id], let wall = r.wall, let sent = r.sent else { return nil }
        return sent + (Date().timeIntervalSince1970 - wall)
    }

    /// `horizon` while a request is still coming, else nil, and in steps of
    /// a quarter of a second, the log's own beat. Drawn from as it was, now
    /// to the instant on every drawing of the pane, it changed the scale
    /// each time: a hover, a pick or the card going away redrew each bar of
    /// the overview and loaded every row of the table again (200 to 400 ms
    /// of the main thread over 400 requests, evals/devmode/network_card.py).
    var live: Double? {
        guard rows.contains(where: \.pending), let horizon else { return nil }
        return (horizon * 4).rounded(.up) / 4
    }

    /// Called when a new page starts in the top frame, for Screenshots.
    @ObservationIgnored var navigated: (() -> Void)?

    /// The inspector has just come up for this tab: what it hands over now is
    /// what the page holds, and the log starts again unless Keep log is on.
    func connected() {
        session += 1
        handedOver = [:]
        returnedLoader = nil
        if !keepLog() { clear() }
    }

    /// Back on the document its inspector was put away on (DevReturn): the
    /// rows stay with their timings, headers and bodies, as in Chromium. The
    /// new inspector hands over again what the page loaded, from its
    /// resource tree, without timings: each of those found here is not a
    /// row of its own but gives its row the new inspector's number, for
    /// its body.
    func reconnected() {
        session += 1
        handedOver = [:]
        returnedLoader = order.lazy.compactMap { self.resources[$0] }.last(where: \.main)?.loader
        for id in order {
            guard let resource = resources[id], !resource.imported else { continue }
            handedOver[resource.method + " " + resource.url, default: []].append(id)
        }
    }

    /// Rows kept over a return, by method and address, not yet found again.
    @ObservationIgnored private var handedOver: [String: [Int]] = [:]
    /// The top frame's loader on the page kept over a return.
    @ObservationIgnored private var returnedLoader: String?

    /// The log's own number for a resource the bridge numbered: the
    /// bridge counts from one again in each new inspector.
    func key(_ bridge: Int) -> Int { session * 1_000_000_000 + bridge }

    func clear() {
        gone.formUnion(order)
        resources = [:]
        order = []
        bodies = [:]
        streams = [:]
        contentLoaded = nil
        loaded = nil
        shots = []
        publish(now: true)
    }

    /// A batch from the bridge, as its script wrote it. Parsed away from the
    /// main thread: a page making a thousand requests a second hands over a
    /// few hundred kilobytes at a time.
    nonisolated func hear(_ json: String) {
        Task.detached(priority: .utility) { [weak self] in
            guard let batch = NetBatch.parse(json) else { return }
            await MainActor.run { self?.apply(batch) }
        }
    }

    func apply(_ batch: NetBatch) {
        if batch.unavailable { unavailable = true; return }
        // The bridge reads the moments as it sends, so in a batch that also
        // says a new page came they are the new page's: said after the clearing.
        func moments() {
            guard let page = batch.page else { return }
            if let at = page.contentLoaded { contentLoaded = at }
            if let at = page.loaded { loaded = at }
        }
        guard recording else { moments(); publish(); return }
        // The page kept over a return, said again by the new inspector as it
        // reads the frame: not a new page.
        let navigation = batch.navigation.flatMap { $0.loader == returnedLoader ? nil : $0 }
        // A new page in the top frame: what came before it goes, unless the
        // log is kept; the page's own new requests stay (its loader's).
        if let navigation, !keepLog() {
            let main = batch.resources.first { $0.fields["mn"] as? Bool == true && $0.fields["ld"] as? String == navigation.loader }
            pageStart = (main?.fields["ts"] as? NSNumber)?.doubleValue
            for id in order where resources[id]?.loader != navigation.loader && resources[id]?.imported != true {
                resources[id] = nil
                bodies[id] = nil
                gone.insert(id)
            }
            order.removeAll { resources[$0] == nil }
            contentLoaded = nil
            loaded = nil
            shots = []
        }
        moments()
        if navigation != nil { navigated?(); handedOver = [:]; returnedLoader = nil }
        for update in batch.resources {
            let id = key(update.id)
            guard !gone.contains(id) else { continue }
            if resources[id] == nil, !handedOver.isEmpty, ((update.fields["ts"] as? NSNumber)?.doubleValue ?? 0) == 0,
               let url = update.fields["u"] as? String {
                let mark = (update.fields["m"] as? String ?? "GET") + " " + url
                if var kept = handedOver[mark], !kept.isEmpty {
                    let was = kept.removeFirst()
                    handedOver[mark] = kept.isEmpty ? nil : kept
                    resources[was]?.bridge = update.id
                    resources[was]?.session = session
                    gone.insert(id)
                    continue
                }
            }
            if resources[id] == nil, !keepLog(), let start = pageStart, let sent = (update.fields["ts"] as? NSNumber)?.doubleValue,
               sent > 0, sent < start - 0.001, update.fields["mn"] as? Bool != true {
                gone.insert(id)
                continue
            }
            var resource = resources[id] ?? NetResource(id: id)
            resource.bridge = update.id
            resource.session = session
            update.apply(to: &resource)
            if update.fields["in"] != nil, let from = resource.initiator.resource { resource.initiator.resource = key(from) }
            if let events = streams[resource.url], resource.type == "eventsource" { resource.events = events }
            if resources[id] == nil { order.append(id) }
            resources[id] = resource
        }
        for (bridge, frames) in batch.frames {
            let id = key(bridge)
            guard var resource = resources[id] else { continue }
            resource.frames.append(contentsOf: frames)
            if resource.frames.count > Self.keptFrames { resource.frames.removeFirst(resource.frames.count - Self.keptFrames) }
            resources[id] = resource
        }
        changed = true
        publish()
    }

    /// What the page's hook heard from its EventSources (DevRelay.page):
    /// kept by address and given to the stream's row.
    func heard(stream url: String, events: [NetResource.Event]) {
        guard recording, !events.isEmpty else { return }
        var kept = streams[url] ?? []
        kept.append(contentsOf: events)
        if kept.count > Self.keptFrames { kept.removeFirst(kept.count - Self.keptFrames) }
        streams[url] = kept
        if let id = order.last(where: { resources[$0]?.url == url && resources[$0]?.type == "eventsource" }) {
            resources[id]?.events = kept
            changed = true
            publish()
        }
    }

    /// HAR brought in: its requests after what is here, as Chromium adds them.
    func bring(_ imported: [NetResource]) {
        for var resource in imported {
            // Below zero: never one the bridge numbered.
            importedNext -= 1
            resource.id = importedNext
            order.append(resource.id)
            resources[resource.id] = resource
        }
        changed = true
        publish(now: true)
    }

    func took(_ image: NSImage, at moment: Double) {
        shots.append((moment, image))
        if shots.count > 24 { shots.removeFirst(shots.count - 24) }
    }

    func keep(_ body: NetBody, for id: Int) { bodies[id] = body }

    /// The rows built now, not on the next quarter second.
    func flush() { publish(now: true) }

    /// Frames and events kept for a socket or a stream at most.
    static let keptFrames = 5000

    /// Rows drawn at most four times a second, however fast they come.
    private func publish(now: Bool = false) {
        if now {
            publishing?.cancel()
            publishing = nil
            rows = build()
            changed = false
            return
        }
        guard publishing == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            publishing = nil
            if changed {
                changed = false
                rows = build()
            }
        }
        publishing = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func build() -> [NetRow] {
        generation += 1
        var out: [NetRow] = []
        out.reserveCapacity(order.count)
        for id in order {
            guard let resource = resources[id] else { continue }
            var previous: Int?
            for hop in resource.redirects.indices {
                let row = NetRow(id: NetRow.ids(id, hop: hop), resource: resource, hop: hop, from: previous)
                out.append(row)
                previous = row.id
            }
            out.append(NetRow(id: NetRow.ids(id, hop: nil), resource: resource, hop: nil, from: previous))
        }
        return out
    }
}

/// A response's body as WebKit handed it: words, or bytes in base64.
struct NetBody: Equatable {
    var text: String
    var base64: Bool
    var error: String?

    var data: Data? {
        base64 ? Data(base64Encoded: text) : text.data(using: .utf8)
    }

    /// Bytes WebKit handed over in base64, for a type it doesn't take as
    /// text (application/vnd.api, application/octet-stream, none at all),
    /// that read as text all the same: as words, as Chromium reads a JSON
    /// reply whatever its type says. Pictures and fonts stay bytes.
    func readable(mime: String) -> NetBody {
        let mime = mime.lowercased()
        guard base64, error == nil, !mime.hasPrefix("image/"), !mime.hasPrefix("font/"), !mime.hasPrefix("audio/"), !mime.hasPrefix("video/"),
              text.utf8.count < 12_000_000, let data, let words = String(data: data, encoding: .utf8) else { return self }
        let texty = mime.hasPrefix("text/") || mime.contains("json") || mime.contains("javascript") || mime.contains("xml")
        guard texty || NetJSON.reply(words) != nil else { return self }
        return NetBody(text: words, base64: false, error: nil)
    }
}

// MARK: - a batch

/// What the bridge passes in one go: the resources that changed, each with
/// only what changed in it, the frames sockets sent and got, a new page.
struct NetBatch {
    struct Update {
        let id: Int
        let fields: [String: Any]

        func apply(to r: inout NetResource) {
            let f = fields
            func string(_ key: String) -> String? { f[key] as? String }
            func int(_ key: String) -> Int? { (f[key] as? NSNumber)?.intValue }
            func double(_ key: String) -> Double? {
                guard let n = f[key] as? NSNumber else { return nil }
                let v = n.doubleValue
                return v.isFinite && v > 0 ? v : nil
            }
            if let v = string("tg") { r.target = v }
            if let v = string("fr") { r.frame = v }
            if let v = string("ld") { r.loader = v }
            if let v = f["mn"] as? Bool { r.main = v }
            if let v = string("u") { r.url = v }
            if let v = string("m") { r.method = v }
            if let v = string("y") { r.type = v }
            if let v = string("mt") { r.mime = v }
            if let v = int("st") { r.status = v }
            if let v = string("sx") { r.statusText = v }
            if let v = string("rs") { r.source = v }
            if let v = string("pr") { r.proto = v }
            if let v = string("pi") { r.priority = v }
            if let v = string("ra") { r.remote = v }
            if let v = string("ci") { r.connection = v }
            if let v = int("sz") { r.size = v }
            if let v = int("tt") { r.transferred = v }
            if let v = int("qh") { r.requestHeaderBytes = v }
            if let v = int("qb") { r.requestBodyBytes = v }
            if let v = int("ph") { r.responseHeaderBytes = v }
            if let v = int("pb") { r.responseBodyBytes = v }
            if f["ts"] != nil { r.sent = double("ts") }
            if f["wt"] != nil { r.wall = double("wt") }
            if f["rr"] != nil { r.responded = double("rr") }
            if f["en"] != nil { r.ended = double("en") }
            if let v = f["dn"] as? Bool { r.finished = v }
            if let v = f["fl"] as? Bool { r.failed = v }
            if let v = f["cn"] as? Bool { r.canceled = v }
            if let v = string("why") { r.failure = v }
            if let v = string("rp") { r.referrerPolicy = v }
            if let v = f["so"] as? Bool { r.socketOpen = v }
            if let v = string("thr") { r.throttledBy = v.isEmpty ? nil : v }
            if let v = string("blk") { r.blockedBy = v.isEmpty ? nil : v }
            if let t = f["tm"] as? [String: Any] {
                func d(_ k: String) -> Double? {
                    guard let n = t[k] as? NSNumber else { return nil }
                    let v = n.doubleValue
                    return v.isFinite && v > 0 ? v : nil
                }
                r.timing = NetResource.Timing(start: d("s"), redirectStart: d("rs"), redirectEnd: d("re"), fetchStart: d("f"),
                                              dnsStart: d("ds"), dnsEnd: d("de"), connectStart: d("cs"), connectEnd: d("ce"),
                                              secureStart: d("ss"), requestStart: d("qs"), responseStart: d("ps"), responseEnd: d("pe"))
            }
            if let h = f["qhd"] { r.requestHeaders = NetBatch.headers(h) }
            if let h = f["phd"] { r.responseHeaders = NetBatch.headers(h) }
            if f["pd"] != nil { r.postData = string("pd") }
            if let v = string("pdt") { r.postType = v }
            if let s = f["sec"] as? [String: Any] { r.security = s.compactMapValues { $0 as? String } }
            if let i = f["in"] as? [String: Any] {
                var initiator = NetResource.Initiator()
                initiator.kind = (i["k"] as? String).flatMap(NetResource.Initiator.Kind.init) ?? .other
                initiator.resource = (i["r"] as? NSNumber)?.intValue
                initiator.url = i["u"] as? String ?? ""
                initiator.line = (i["l"] as? NSNumber)?.intValue ?? 0
                initiator.column = (i["c"] as? NSNumber)?.intValue ?? 0
                initiator.stack = (i["s"] as? [[Any]] ?? []).map {
                    NetFrameLine(function: $0.first as? String ?? "", url: $0.count > 1 ? $0[1] as? String ?? "" : "",
                                 line: $0.count > 2 ? ($0[2] as? NSNumber)?.intValue ?? 0 : 0,
                                 column: $0.count > 3 ? ($0[3] as? NSNumber)?.intValue ?? 0 : 0)
                }
                r.initiator = initiator
            }
            if let hops = f["rd"] as? [[String: Any]] {
                r.redirects = hops.map {
                    NetResource.Hop(url: $0["u"] as? String ?? "", method: $0["m"] as? String ?? "GET",
                                    status: ($0["st"] as? NSNumber)?.intValue ?? 0, statusText: $0["sx"] as? String ?? "",
                                    requestHeaders: NetBatch.headers($0["qhd"] ?? [[String]]()), responseHeaders: NetBatch.headers($0["phd"] ?? [[String]]()),
                                    at: ($0["at"] as? NSNumber).map(\.doubleValue))
                }
            }
        }
    }

    struct Page {
        var contentLoaded: Double?
        var loaded: Double?
    }

    struct Navigation {
        let loader: String
    }

    var resources: [Update] = []
    var frames: [Int: [NetResource.Frame]] = [:]
    var page: Page?
    var navigation: Navigation?
    var unavailable = false

    static func headers(_ raw: Any) -> [NetHeader] {
        if let pairs = raw as? [[String]] { return pairs.compactMap { $0.count == 2 ? NetHeader(name: $0[0], value: $0[1]) : nil } }
        if let map = raw as? [String: Any] {
            return map.keys.sorted { $0.lowercased() < $1.lowercased() }.compactMap { key in
                (map[key] as? String).map { NetHeader(name: key, value: $0) }
            }
        }
        return []
    }

    static func parse(_ json: String) -> NetBatch? {
        guard let data = json.data(using: .utf8),
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var batch = NetBatch()
        batch.unavailable = body["x"] as? Bool ?? false
        for raw in body["r"] as? [[String: Any]] ?? [] {
            guard let id = (raw["i"] as? NSNumber)?.intValue else { continue }
            batch.resources.append(Update(id: id, fields: raw))
        }
        for raw in body["w"] as? [[Any]] ?? [] {
            guard raw.count >= 6, let id = (raw[0] as? NSNumber)?.intValue else { continue }
            let frame = NetResource.Frame(outgoing: raw[1] as? Bool ?? false, opcode: (raw[2] as? NSNumber)?.intValue ?? 1,
                                          data: raw[3] as? String, length: (raw[4] as? NSNumber)?.intValue ?? 0,
                                          wall: (raw[5] as? NSNumber)?.doubleValue ?? 0)
            batch.frames[id, default: []].append(frame)
        }
        if let page = body["pg"] as? [String: Any] {
            func d(_ k: String) -> Double? { (page[k] as? NSNumber).map(\.doubleValue).flatMap { $0.isFinite && $0 > 0 ? $0 : nil } }
            batch.page = Page(contentLoaded: d("dcl"), loaded: d("load"))
        }
        if let loader = body["nav"] as? String { batch.navigation = Navigation(loader: loader) }
        return batch
    }
}

// MARK: - the tab's log

nonisolated(unsafe) private var netLogKey: UInt8 = 0

extension Tab {
    /// What the card's Network heard for this tab's page.
    var netLog: NetLog {
        if let log = objc_getAssociatedObject(self, &netLogKey) as? NetLog { return log }
        let log = NetLog()
        objc_setAssociatedObject(self, &netLogKey, log, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return log
    }
}

// MARK: - sizes and times as Chromium writes them

enum NetFormat {
    /// 0 B, 812 B, 1.2 kB, 43.7 kB, 1.6 MB: decimal, as Chromium's table.
    static func size(_ bytes: Int) -> String {
        let b = Double(bytes)
        if bytes < 1000 { return "\(bytes) B" }
        if bytes < 1_000_000 { return String(format: b < 10_000 ? "%.1f kB" : "%.0f kB", b / 1000) }
        return String(format: "%.1f MB", b / 1_000_000)
    }

    /// 0.42 ms, 12 ms, 1.23 s.
    static func time(_ ms: Double) -> String {
        if ms < 1 { return String(format: "%.2f ms", ms) }
        if ms < 1000 { return "\(Int(ms.rounded())) ms" }
        if ms < 60_000 { return String(format: "%.2f s", ms / 1000) }
        return String(format: "%.1f min", ms / 60_000)
    }
}

extension DevPlace {
    init(url: String, line: Int, column: Int) {
        self.url = url
        self.line = line
        self.column = column
    }
}
