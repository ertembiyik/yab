import AppKit
import SwiftUI
import WebKit

enum ApplicationSection: String, CaseIterable {
    case manifest = "Manifest", workers = "Service workers", storage = "Storage", webmcp = "WebMCP"
    case local = "Local storage", session = "Session storage", indexedDB = "IndexedDB", cookies = "Cookies", cache = "Cache storage"
    case backForward = "Back/forward cache", backgroundFetch = "Background fetch", backgroundSync = "Background sync"
    case notifications = "Notifications", payment = "Payment handler", periodicSync = "Periodic background sync", push = "Push messaging", reporting = "Reporting API", speculative = "Speculative loads"
    case frames = "Frames", shared = "Shared storage", privateTokens = "Private state tokens", interestGroups = "Interest groups"
    var symbol: String {
        switch self {
        case .manifest, .reporting, .webmcp: return "doc.text"
        case .workers: return "gearshape"
        case .storage, .shared, .privateTokens, .backForward: return "application.database"
        case .local, .session: return "application.table"
        case .indexedDB: return "application.database"
        case .cache: return "application.database"
        case .cookies: return "cookie"
        case .frames: return "application.frame"
        case .backgroundFetch: return "application.transfer"
        case .backgroundSync: return "arrow.rotate"
        case .periodicSync: return "clock"
        case .notifications: return "bell"
        case .push: return "application.cloud"
        case .payment: return "creditcard"
        case .interestGroups: return "person.2"
        case .speculative: return "eyeglasses"
        }
    }
    var isTable: Bool { [.local, .session, .cookies, .indexedDB, .cache].contains(self) }
    /// Chrome's StorageCategoryView for the category row itself: headline
    /// (or the empty one when no origin is listed) and what the page is for.
    var category: (title: String, empty: String, text: String)? {
        switch self {
        case .local: return ("Local storage", "No local storage detected", "On this page you can view, add, edit, and delete local storage key-value pairs")
        case .session: return ("Session storage", "No session storage detected", "On this page you can view, add, edit, and delete session storage key-value pairs")
        case .indexedDB: return ("IndexedDB", "No IndexedDB detected", "On this page you can view and delete IndexedDB key-value pairs and databases")
        case .cookies: return ("Cookies", "No cookies set", "On this page you can view, add, edit, and delete cookies")
        case .cache: return ("Cache storage", "No cache storage detected", "On this page you can view and delete cache data")
        default: return nil
        }
    }
}

struct ApplicationSelection: Hashable {
    var section: ApplicationSection = .manifest
    /// The category row (Local storage, Cookies…) rather than one origin
    /// under it, so the two never share a selection, as in Chromium.
    var category = false
    var origin = ""
    var frame = ""
    var database = ""
    var store = ""
    var index = ""
    var cache = ""
    var resource = ""
    var id: String { [section.rawValue, category ? "category" : "", origin, frame, database, store, index, cache, resource].joined(separator: "\u{1f}") }
    var params: [String: Any] { var p: [String: Any] = [:]; if !origin.isEmpty { p["origin"] = origin }; if !frame.isEmpty { p["frame"] = frame }; return p }
    var title: String { !resource.isEmpty ? URL(string: resource)?.lastPathComponent ?? resource : !index.isEmpty ? index : !store.isEmpty ? store : !database.isEmpty ? database : !cache.isEmpty ? cache : section.rawValue }
}

struct ApplicationTreeItem: Identifiable {
    var id: String
    var title: String
    var selection: ApplicationSelection?
    var symbol: String
    var children: [ApplicationTreeItem] = []
}

struct ApplicationGridRow: Identifiable {
    var id: String
    var cells: [String]
    var data: [String: Any] = [:]
}

@MainActor @Observable final class DevApplicationModel: NSObject, WKScriptMessageHandler {
    var selection = ApplicationSelection()
    var selectionRevision = 0
    var origins: [[String: Any]] = []
    var frames: [[String: Any]] = []
    var expanded: Set<String> = ["application", "storage", "background", "frames", "section:Local storage", "section:Session storage", "section:Cookies", "section:IndexedDB", "section:Cache storage"]
    var schemas: [String: [[String: Any]]] = [:]
    var document: [String: Any] = [:]
    var rows: [ApplicationGridRow] = []
    var selectedRow = ""
    var filter = ""
    var preview = ""
    var previewDocument: [String: Any] = [:]
    var error = ""
    var busy = false
    var offset = 0
    var hasNext = false
    var startKey = ""
    var clearTypes: Set<String> = ["local", "session", "indexedDB", "cache", "workers", "cookies"]
    var events: [[String: Any]] = []
    var recordingEvents = false {
        didSet {
            notificationTimer?.invalidate(); notificationTimer = nil
            if recordingEvents {
                seenNotifications = Set(SiteNotices.shown.map(\.id))
                notificationTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
                    guard let self else { timer.invalidate(); return }
                    Task { @MainActor in self.captureNotifications() }
                }
            }
        }
    }
    var updateOnReload = false
    var backForwardStatus = ""
    @ObservationIgnored weak var web: WKWebView?
    @ObservationIgnored private var notificationTimer: Timer?
    @ObservationIgnored private var seenNotifications: Set<UInt64> = []
    private func captureNotifications() {
        guard recordingEvents else { return }
        for note in SiteNotices.shown where !seenNotifications.contains(note.id) {
            seenNotifications.insert(note.id)
            guard origins.contains(where: { $0["origin"] as? String == SiteNotices.webKitOrigin(note.origin) }) else { continue }
            events.append(["kind": "Notification", "id": String(note.id), "origin": SiteNotices.webKitOrigin(note.origin), "title": note.title, "body": note.body, "tag": note.tag, "worker": note.worker, "time": Date().timeIntervalSince1970 * 1000])
        }
        if events.count > 2000 { events.removeFirst(events.count - 2000) }
    }
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var boundOrigin = ""
    @ObservationIgnored private var returningFromCacheTest = false
    @ObservationIgnored private var cacheTestURL = ""
    var schemaKey: String { selection.origin + "\u{1f}" + selection.database }
    var originInfo: [String: Any] { origins.first { $0["origin"] as? String == selection.origin } ?? origins.first ?? [:] }
    var visibleRows: [ApplicationGridRow] { filter.isEmpty ? rows : rows.filter { $0.cells.contains { $0.localizedCaseInsensitiveContains(filter) } } }
    var row: ApplicationGridRow? { rows.first { $0.id == selectedRow } }

    func select(_ selection: ApplicationSelection) {
        generation += 1; self.selection = selection; document = [:]; rows = []; selectedRow = ""; preview = ""; previewDocument = [:]; error = ""; busy = false; offset = 0; startKey = ""; hasNext = false; selectionRevision += 1
    }
    func acceptSnapshot(_ snapshot: [String: Any]) {
        let newOrigins = snapshot["origins"] as? [[String: Any]] ?? []
        frames = snapshot["frames"] as? [[String: Any]] ?? []; origins = newOrigins
        let topOrigin = newOrigins.first?["origin"] as? String ?? ""
        if boundOrigin != topOrigin {
            boundOrigin = topOrigin; schemas = [:]
            var next = selection; next.origin = next.category ? "" : topOrigin; next.frame = ""; next.database = ""; next.store = ""; next.index = ""; next.cache = ""; next.resource = ""
            select(next)
        } else if !selection.origin.isEmpty && !newOrigins.contains(where: { $0["origin"] as? String == selection.origin }) {
            var next = selection; next.origin = topOrigin; next.frame = ""; next.database = ""; next.store = ""; next.index = ""; next.cache = ""; next.resource = ""; select(next)
        }
    }
    func call(_ browser: Browser, _ method: String, _ extra: [String: Any] = [:], done: @escaping (Any?) -> Void) {
        let token = generation, selected = selection
        var p = method.hasPrefix("application.") ? selected.params : [:]; p.merge(extra) { _, new in new }
        busy = true; error = ""
        var finished = false
        browser.wire(method, p, failed: { [weak self] error in
            guard !finished else { return }; finished = true
            guard let self, self.generation == token, self.selection == selected else { return }
            self.busy = false; self.error = error
        }) { [weak self] value in
            guard !finished else { return }; finished = true
            guard let self, self.generation == token, self.selection == selected else { return }
            self.busy = false; done((value as? String).flatMap(DevWorkbench.parse) ?? value)
        }
    }
    func install(_ web: WKWebView) {
        guard self.web !== web else { return }
        // Another pane's model (DevTools reopened) or a shared controller may already hold the
        // name, and WebKit throws on a second add (crash #36), so the newest pane takes it over.
        self.web?.configuration.userContentController.removeScriptMessageHandler(forName: "yabApplication", contentWorld: Web.world)
        self.web = web
        web.configuration.userContentController.removeScriptMessageHandler(forName: "yabApplication", contentWorld: Web.world)
        web.configuration.userContentController.add(self, contentWorld: Web.world, name: "yabApplication")
        web.configuration.userContentController.addUserScript(WKUserScript(source: Self.lifecycle, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: Web.world))
        web.callAsyncJavaScript(Self.lifecycle, arguments: [:], in: nil, in: Web.world, completionHandler: nil)
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let event = message.body as? [String: Any], message.name == "yabApplication" else { return }
        if event["kind"] as? String == "pageshow", message.frameInfo.isMainFrame {
            if returningFromCacheTest, event["url"] as? String == cacheTestURL {
                returningFromCacheTest = false
                backForwardStatus = event["persisted"] as? Bool == true ? "Restored from back/forward cache" : "Not restored from back/forward cache"
            }
            if updateOnReload { web?.evaluateJavaScript("navigator.serviceWorker?.getRegistrations().then(rs=>Promise.all(rs.map(r=>r.update())))", completionHandler: nil) }
        }
        if recordingEvents { events.append(event); if events.count > 2000 { events.removeFirst(events.count - 2000) } }
    }
    /// A real history round trip; pageshow.persisted is the result, not a heuristic.
    func testBackForward() {
        guard let web, web.url?.scheme == "http" || web.url?.scheme == "https" else { error = "Open a web page before testing back/forward cache"; return }
        returningFromCacheTest = true; cacheTestURL = web.url?.absoluteString ?? ""; backForwardStatus = "Navigating away and back…"
        let target = web.url
        web.load(URLRequest(url: URL(string: "about:blank")!))
        Task { @MainActor [weak self, weak web] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, self.returningFromCacheTest else { return }
            if web?.url != target, web?.canGoBack == true { web?.goBack() }
            try? await Task.sleep(for: .seconds(6))
            if self.returningFromCacheTest { self.returningFromCacheTest = false; self.backForwardStatus = "No pageshow result received. Retry after the page finishes loading." }
        }
    }
    static func cookie(_ cookie: [String: Any], belongsTo origin: String) -> Bool {
        guard let host = URL(string: origin)?.host?.lowercased(), let domain = cookie["domain"] as? String else { return false }
        let normalized = domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        return host == normalized || domain.hasPrefix(".") && host.hasSuffix("." + normalized)
    }
    static func json(_ value: Any?) -> String {
        guard let value, let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]), let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }
    static func text(_ value: Any?) -> String {
        guard let value else { return "" }
        if let string = value as? String { return string }
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]), let text = String(data: data, encoding: .utf8) { return text }
        return String(describing: value)
    }
    static let lifecycle = #"""
    (()=>{if(window.__yabApplicationLifecycle)return;window.__yabApplicationLifecycle=true;
      const post=(kind,data={})=>{try{window.webkit.messageHandlers.yabApplication.postMessage({kind,url:location.href,origin:location.origin,time:Date.now(),...data})}catch(e){}};
      addEventListener('pageshow',e=>post('pageshow',{persisted:e.persisted}));
      addEventListener('pagehide',e=>post('pagehide',{persisted:e.persisted}));
      addEventListener('securitypolicyviolation',e=>post('CSP violation',{directive:e.violatedDirective,blockedURL:e.blockedURI,source:e.sourceFile,line:e.lineNumber}));
      navigator.serviceWorker?.addEventListener('message',e=>post('Service worker message',{data:JSON.stringify(e.data).slice(0,4000)}));
      navigator.serviceWorker?.addEventListener('controllerchange',()=>post('Service worker controller changed',{source:navigator.serviceWorker.controller?.scriptURL||''}));
      if(typeof ReportingObserver!=='undefined'){new ReportingObserver(rs=>rs.forEach(r=>post('Report',{type:r.type,body:r.body?.toJSON?.()||{},reportURL:r.url})),{buffered:true}).observe()}
    })();
    """#
}
