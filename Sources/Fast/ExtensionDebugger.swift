import AppKit
import SwiftUI
import WebKit

// chrome.debugger, the part the AI extensions speak.
//
// In Chrome `debugger.attach({tabId}, "1.3")` hands an extension the Chrome
// DevTools Protocol for a tab, and Claude and ChatGPT drive pages with it:
// they read the page with Runtime.evaluate, press and type with Input.*, and
// look with Page.captureScreenshot. WebKit has no such protocol for an
// extension, so this is a translator per attached tab, in the app: each
// command the extensions were seen to send (docs/evidence/
// debugger-cdp-calls-2026-10-13.md) is done the way Yab's own agent does it,
// and answered in Chrome's shapes, measured from Chrome on the same packages
// (evals/extensions/debugger.py compares them).
//
// - Runtime.evaluate and callFunctionOn run in the page's own world, where
//   Chrome runs them, as an indirect eval inside WebKit's callAsyncJavaScript;
//   a page whose policy forbids eval gets WebKit's own evaluateJavaScript
//   instead (no await there). Objects not returned by value are kept for the
//   extension by id in that world, as Chromium's remote objects are.
// - Input.* are real events handed to the tab's view, the way Yab's agent
//   presses and types (AgentPage.click, AgentPage.send, AgentPage.insert),
//   so the page sees trusted ones; a tab behind others, whose view has no
//   window, is told in script, as the agent's keys are.
// - Page.captureScreenshot is WKWebView.takeSnapshot, drawn at exactly the
//   pixels Chrome would give (Claude checks).
// - Events: Runtime's console and errors, and Network's requests as the page's
//   resource timing lists them, from a small script put in the page while an
//   extension has those domains on; Page's navigations from the view's URL and
//   loading; a dialog the page opens.
// - Anything else is answered with CDP's own "wasn't found", never silence.
//
// Consent: an attached tab shows "<Extension> is controlling this tab" with
// Stop at the page's foot (ExtensionDebuggerDock); Stop detaches with
// `canceled_by_user`, as Chromium's bar's Cancel does. Private tabs and Yab's
// own pages refuse attach. Nothing runs on a page no extension attached to.

@available(macOS 15.4, *)
@MainActor
@Observable final class ExtensionDebugger {
    static let shared = ExtensionDebugger()

    /// The native port a worker's shim opens for events.
    nonisolated static let portName = ExtensionShims.application + ".debugger"
    /// The world events and the windowless input fallback run in.
    static let world = WKContentWorld.world(name: "yab-debugger")
    /// The page script's message handler, in the page's own world.
    static let handlerName = "yabDebugger"

    struct Holder: Hashable {
        let extensionID: String
        let name: String
    }

    /// Who controls each tab, for the dock at its foot.
    private(set) var holders: [UUID: [Holder]] = [:]

    @ObservationIgnored private var sessions: [String: Session] = [:]
    @ObservationIgnored private var ports: [String: WKWebExtension.MessagePort] = [:]
    @ObservationIgnored private var nextContext = 1
    /// Why the last Page.handleJavaScriptDialog found nothing to answer,
    /// for the bench (evals/extensions/debugger.py).
    @ObservationIgnored var missed = ""

    /// One extension attached to one tab.
    final class Session {
        let extensionID: String
        let name: String
        /// Chrome's tab id, as WebKit gives it to the extension.
        let tabID: Int
        weak var tab: Tab?
        /// Chrome's target and main frame id, one for the tab's life.
        let targetID: String
        var loaderID = Session.hex()
        var runtime = false
        var page = false
        var network = false
        var lifecycle = false
        var context = 1
        var watches: [NSKeyValueObservation] = []
        var handler: Relay?
        var requests = 0
        /// Which mouse buttons are down, by CDP's name, for a windowless
        /// tab's pressed and released pair.
        var pressed: [String: CGPoint] = [:]

        init(extensionID: String, name: String, tabID: Int, tab: Tab) {
            self.extensionID = extensionID
            self.name = name
            self.tabID = tabID
            self.tab = tab
            targetID = tab.id.uuidString.replacingOccurrences(of: "-", with: "")
        }

        var key: String { ExtensionDebugger.key(extensionID, tabID) }
        var source: [String: Any] { ["tabId": tabID] }

        static func hex() -> String {
            UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }
    }

    /// A CDP error, as chrome.debugger's lastError carries it: its JSON.
    struct Failure: LocalizedError {
        let text: String
        init(_ text: String) { self.text = text }
        init(code: Int, _ message: String) {
            let body: [String: Any] = ["code": code, "message": message]
            let data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
            text = String(decoding: data, as: UTF8.self)
        }
        var errorDescription: String? { text }
    }

    nonisolated static func key(_ extensionID: String, _ tabID: Int) -> String { "\(extensionID):\(tabID)" }

    // MARK: - the shim's calls

    func run(_ api: String, _ args: [Any], context: WKWebExtensionContext, owner: Extensions) async throws -> Any? {
        let spec = args.first as? [String: Any] ?? [:]
        // By its sign-in too: the same extension in two sign-ins is two
        // debuggers, each over its own tabs (ExtensionSignIns).
        let id = ExtensionExternal.key(context.uniqueIdentifier, in: owner.signIn)
        let tabID = (spec["tabId"] as? NSNumber)?.intValue ?? -1
        if DebuggerCallLog.on, api != "debugger.send" {
            DebuggerCallLog.write(["kind": api, "ext": id, "name": context.webExtension.displayName ?? "", "tabId": tabID])
        }
        switch api {
        case "debugger.attach":
            return try attach(spec, extensionID: id, name: context.webExtension.displayName ?? "An extension", owner: owner)
        case "debugger.detach":
            guard let session = sessions[Self.key(id, tabID)] else { throw Failure("Debugger is not attached to the tab with id: \(tabID).") }
            end(session, reason: nil)
            return nil
        case "debugger.send":
            guard let session = sessions[Self.key(id, tabID)], session.tab != nil else {
                throw Failure("Debugger is not attached to the tab with id: \(tabID).")
            }
            let method = spec["method"] as? String ?? ""
            let params = spec["params"] as? [String: Any] ?? [:]
            guard DebuggerCallLog.on else { return try await send(session, method, params) }
            let start = Date()
            do {
                let answer = try await send(session, method, params)
                DebuggerCallLog.write(["kind": "call", "ext": session.extensionID, "method": method, "params": DebuggerCallLog.clip(params, 400),
                               "ok": true, "result": DebuggerCallLog.clip(answer, 700), "ms": Int(Date().timeIntervalSince(start) * 1000)])
                return answer
            } catch {
                DebuggerCallLog.write(["kind": "call", "ext": session.extensionID, "method": method, "params": DebuggerCallLog.clip(params, 400),
                               "ok": false, "error": error.localizedDescription, "ms": Int(Date().timeIntervalSince(start) * 1000)])
                throw error
            }
        case "debugger.attached":
            // Every tab some extension holds, by this extension's tab ids
            // where it is the one, for getTargets.
            return sessions.values.filter { $0.extensionID == id && $0.tab != nil }.map { ["tabId": $0.tabID, "targetId": $0.targetID] }
        default:
            throw ExtensionShims.Unsupported(what: "\(api) isn't available in Yab")
        }
    }

    private func attach(_ spec: [String: Any], extensionID: String, name: String, owner: Extensions) throws -> Any? {
        let tabID = (spec["tabId"] as? NSNumber)?.intValue ?? -1
        let version = spec["version"] as? String ?? "1.3"
        // Chrome takes 1.0 to 1.3.
        let parts = version.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 2, parts[0] == 1, (0...3).contains(parts[1]) else {
            throw Failure("Requested protocol version is not supported: \(version).")
        }
        guard let tab = find(spec, owner: owner) else { throw Failure("No tab with given id \(tabID).") }
        if sessions.values.contains(where: { $0.tab === tab }) {
            throw Failure("Another debugger is already attached to the tab with id: \(tabID).")
        }
        if tab.shy { throw Failure("Cannot attach to this target.") }
        if let scheme = tab.address?.scheme?.lowercased(), !["http", "https", "about", "data", "blob", "file"].contains(scheme) {
            throw Failure("Cannot access a chrome:// URL")
        }
        guard tab.webKitOnly("Legacy extension debugger") != nil else { throw Failure("The WebKit extension debugger is not available on this engine yet.") }
        let session = Session(extensionID: extensionID, name: name, tabID: tabID, tab: tab)
        sessions[session.key] = session
        watch(session)
        show()
        return ["targetId": session.targetID]
    }

    /// The tab the extension means: where it says the tab stands in the
    /// row, checked against the address it read, as everything the shim
    /// does by tab is (tabs.move, tabs.discard).
    private func find(_ spec: [String: Any], owner: Extensions) -> Tab? {
        let index = (spec["index"] as? NSNumber)?.intValue ?? -1
        let url = spec["url"] as? String ?? ""
        let visible = owner.visibleTabs
        func same(_ tab: Tab) -> Bool {
            let address = tab.address?.absoluteString ?? ""
            return url.isEmpty || address == url || address.isEmpty || url == "about:blank"
        }
        if visible.indices.contains(index), same(visible[index]) { return visible[index] }
        guard !url.isEmpty else { return nil }
        // Only its own sign-in's pages.
        let all = BrowserWindows.shared.browsers.flatMap(\.tabs).filter(owner.seen)
        return all.first { $0.address?.absoluteString == url }
    }

    /// Stop on the dock: every extension on the tab let go, each told.
    func stop(_ tab: Tab) {
        for session in sessions.values where session.tab === tab { end(session, reason: "canceled_by_user") }
    }

    /// The tab closed.
    func closed(_ tab: Tab) {
        for session in sessions.values where session.tab === tab || session.tab == nil { end(session, reason: "target_closed") }
    }

    private func end(_ session: Session, reason: String?) {
        sessions[session.key] = nil
        session.watches.forEach { $0.invalidate() }
        session.watches = []
        if session.handler != nil, let web = session.tab?.webKitOnly("Legacy WebKit debugger cleanup", build: false) {
            web.configuration.userContentController.removeScriptMessageHandler(forName: Self.handlerName, contentWorld: .page)
            web.evaluateJavaScript("window.__yabDebuggerOff && window.__yabDebuggerOff()", in: nil, in: .page)
        }
        session.handler = nil
        if let reason { post(session.extensionID, ["d": [session.source, reason]]) }
        show()
    }

    private func show() {
        var out: [UUID: [Holder]] = [:]
        for session in sessions.values {
            guard let tab = session.tab else { continue }
            out[tab.id, default: []].append(Holder(extensionID: ExtensionExternal.parts(session.extensionID).id, name: session.name))
        }
        if out != holders { holders = out }
    }

    // MARK: - the port events go over

    func connect(_ port: WKWebExtension.MessagePort, from extensionID: String) {
        if let old = ports[extensionID], old !== port { old.disconnect() }
        ports[extensionID] = port
        port.messageHandler = { [weak self, weak port] message, _ in
            MainActor.assumeIsolated {
                guard let port, let body = message as? [String: Any] else { return }
                // The worker's shim asks every port whether it has arrived
                // (ExtensionNative); this one answers too.
                if (body["__yabNative"] as? String) == "here?" { port.sendMessage(["__yabNative": "here"]) { _ in } }
                if body["hello"] != nil { port.sendMessage(["ready": true]) { _ in } }
                _ = self
            }
        }
        port.disconnectHandler = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.ports[extensionID] === port else { return }
                self.ports[extensionID] = nil
            }
        }
    }

    private func post(_ extensionID: String, _ message: [String: Any]) {
        guard let port = ports[extensionID], !port.isDisconnected else { return }
        port.sendMessage(message) { _ in }
    }

    private func emit(_ session: Session, _ method: String, _ params: [String: Any]) {
        if DebuggerCallLog.on { DebuggerCallLog.write(["kind": "event", "ext": session.extensionID, "method": method, "params": DebuggerCallLog.clip(params, 300)]) }
        post(session.extensionID, ["e": [session.source, method, params]])
    }

    // MARK: - navigation and loading, from the view

    private func watch(_ session: Session) {
        guard let tab = session.tab else { return }
        guard let web = tab.webKitOnly("Legacy extension debugger") else { return }
        var lastURL = web.url
        session.watches.append(web.observe(\.isLoading, options: [.new]) { [weak self, weak session] web, _ in
            let loading = web.isLoading
            MainActor.assumeIsolated {
                guard let self, let session else { return }
                self.loading(session, loading)
            }
        })
        session.watches.append(web.observe(\.url, options: [.new]) { [weak self, weak session] web, _ in
            let url = web.url
            let loading = web.isLoading
            MainActor.assumeIsolated {
                guard let self, let session, url != lastURL else { return }
                let sameDocument = !loading && url?.absoluteString.components(separatedBy: "#").first == lastURL?.absoluteString.components(separatedBy: "#").first
                lastURL = url
                self.navigated(session, to: url, sameDocument: sameDocument || !loading)
            }
        })
    }

    private func frame(_ session: Session, _ url: URL?) -> [String: Any] {
        let address = url?.absoluteString ?? "about:blank"
        let origin = url.flatMap { u -> String? in
            guard let scheme = u.scheme, let host = u.host() else { return nil }
            return "\(scheme)://\(host)" + (u.port.map { ":\($0)" } ?? "")
        } ?? "://"
        return ["id": session.targetID, "loaderId": session.loaderID, "url": address, "domainAndRegistry": "",
                "securityOrigin": origin, "mimeType": "text/html", "secureContextType": url?.scheme == "https" ? "Secure" : "InsecureScheme",
                "crossOriginIsolatedContextType": "NotIsolated", "gatedAPIFeatures": [Any](), "adFrameStatus": ["adFrameType": "none"]]
    }

    private func loading(_ session: Session, _ loading: Bool) {
        guard session.page else { return }
        if loading {
            session.loaderID = Session.hex()
            emit(session, "Page.frameStartedLoading", ["frameId": session.targetID])
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        emit(session, "Page.domContentEventFired", ["timestamp": now])
        emit(session, "Page.loadEventFired", ["timestamp": now])
        emit(session, "Page.frameStoppedLoading", ["frameId": session.targetID])
        // A new document: the console and network watch go in again.
        if session.runtime || session.network { inject(session) }
    }

    private func navigated(_ session: Session, to url: URL?, sameDocument: Bool) {
        if sameDocument {
            if session.page {
                emit(session, "Page.navigatedWithinDocument", ["frameId": session.targetID, "url": url?.absoluteString ?? "", "navigationType": "historyApi"])
            }
            return
        }
        if session.runtime {
            emit(session, "Runtime.executionContextsCleared", [:])
            nextContext += 1
            session.context = nextContext
        }
        if session.page { emit(session, "Page.frameNavigated", ["frame": frame(session, url), "type": "Navigation"]) }
        if session.runtime { contextCreated(session, url) }
        if session.runtime || session.network { inject(session) }
    }

    private func contextCreated(_ session: Session, _ url: URL?) {
        let origin = (frame(session, url)["securityOrigin"] as? String) ?? ""
        emit(session, "Runtime.executionContextCreated", ["context": [
            "id": session.context, "origin": origin, "name": "", "uniqueId": "\(session.targetID).\(session.context)",
            "auxData": ["frameId": session.targetID, "isDefault": true, "type": "default"],
        ]])
    }

    // MARK: - commands

    private func send(_ session: Session, _ method: String, _ params: [String: Any]) async throws -> Any? {
        guard let tab = session.tab else { throw Failure("Debugger is not attached to the tab with id: \(session.tabID).") }
        guard let web = tab.webKitOnly("Legacy extension debugger") else { throw Failure("The WebKit extension debugger is not available on this engine yet.") }
        switch method {
        case "Runtime.enable":
            if !session.runtime {
                session.runtime = true
                contextCreated(session, web.url)
                inject(session)
            }
            return [String: Any]()
        case "Runtime.disable":
            session.runtime = false
            return [String: Any]()
        case "Page.enable": session.page = true; return [String: Any]()
        case "Page.disable": session.page = false; return [String: Any]()
        case "Page.setLifecycleEventsEnabled": session.lifecycle = params["enabled"] as? Bool ?? false; return [String: Any]()
        case "Network.enable":
            if !session.network {
                session.network = true
                inject(session)
            }
            return [String: Any]()
        case "Network.disable": session.network = false; return [String: Any]()
        // Chrome keeps a background tab's page thinking it has the focus.
        // A Yab tab behind others has no window to lose the focus to; the
        // page is told it has it when the input comes in script instead.
        case "Emulation.setFocusEmulationEnabled", "Runtime.runIfWaitingForDebugger":
            return [String: Any]()
        case "Page.bringToFront":
            Self.browser(of: tab)?.select(tab)
            return [String: Any]()
        case "Runtime.evaluate":
            return try await evaluate(session, tab, params)
        case "Runtime.callFunctionOn":
            return try await callFunction(session, tab, params)
        case "Runtime.releaseObject", "Runtime.releaseObjectGroup":
            let id = params["objectId"] as? String ?? ""
            try? await web.callAsyncJavaScript("const k = window[Symbol.for('yab.debugger.objects')]; if (k) { if (id) k.delete(id); else k.clear(); }",
                                                   arguments: ["id": method == "Runtime.releaseObject" ? id : ""], in: nil, contentWorld: .page)
            return [String: Any]()
        case "Page.navigate":
            guard let raw = params["url"] as? String, let url = URL(string: raw), url.scheme != nil else {
                throw Failure(code: -32000, "Cannot navigate to invalid URL")
            }
            session.loaderID = Session.hex()
            tab.go(to: url)
            return ["frameId": session.targetID, "loaderId": session.loaderID, "isDownload": false]
        case "Page.reload":
            tab.reload()
            return [String: Any]()
        case "Page.getLayoutMetrics":
            return try await layoutMetrics(tab)
        case "Page.captureScreenshot":
            return try await screenshot(tab, params)
        case "Page.handleJavaScriptDialog":
            return try answerDialog(tab, params)
        case "Input.dispatchMouseEvent":
            try await mouse(session, tab, params)
            return [String: Any]()
        case "Input.dispatchKeyEvent":
            await key(tab, params)
            return [String: Any]()
        case "Input.insertText":
            let before = await heard(web, "input")
            AgentPage.insert(tab.page, params["text"] as? String ?? "")
            await heard(web, "input", beyond: before)
            return [String: Any]()
        default:
            throw Failure(code: -32601, "'\(method)' wasn't found")
        }
    }

    // MARK: Runtime

    /// What the page's world needs to answer as Chromium's Runtime does: a
    /// value made into a RemoteObject, objects kept by id, an error made
    /// into exceptionDetails. Defined once per call: nothing stays in the
    /// page but the objects kept.
    static let remote = """
    const kept = window[Symbol.for('yab.debugger.objects')] || (window[Symbol.for('yab.debugger.objects')] = new Map());
    let next = kept.__next || 1;
    const keep = (v) => { const id = 'yab.' + context + '.' + (next++); kept.__next = next; kept.set(id, v); return id; };
    const subtypeOf = (v) => {
      if (Array.isArray(v)) return 'array';
      if (typeof Node !== 'undefined' && v instanceof Node) return 'node';
      if (v instanceof RegExp) return 'regexp';
      if (v instanceof Date) return 'date';
      if (v instanceof Map) return 'map';
      if (v instanceof Set) return 'set';
      if (v instanceof WeakMap) return 'weakmap';
      if (v instanceof WeakSet) return 'weakset';
      if (v instanceof Error) return 'error';
      if (v instanceof Promise) return 'promise';
      if (ArrayBuffer.isView(v)) return 'typedarray';
      if (v instanceof ArrayBuffer) return 'arraybuffer';
      return undefined;
    };
    const describe = (v, subtype, className) => {
      try {
        if (subtype === 'array') return className + '(' + v.length + ')';
        if (subtype === 'node') {
          if (v.nodeType === 1) { let d = v.localName; if (v.id) d += '#' + v.id; if (typeof v.className === 'string' && v.className.trim()) d += '.' + v.className.trim().split(/\\s+/).join('.'); return d; }
          return v.nodeName.toLowerCase();
        }
        if (subtype === 'regexp' || subtype === 'date') return String(v);
        if (subtype === 'map' || subtype === 'set') return className + '(' + v.size + ')';
        if (subtype === 'error') {
          // Chrome's "Name: message" and its frames; WebKit's stack lines
          // are "fn@url:line:col", eval's own frames have no address.
          const frames = String(v.stack || '').split('\\n').filter((l) => /:\\d+:\\d+$/.test(l))
            .map((l) => { const at = l.lastIndexOf('@'); return '    at ' + (at > 0 ? l.slice(0, at) + ' (' + l.slice(at + 1) + ')' : l.slice(at + 1)); });
          return [String(v)].concat(frames).join('\\n');
        }
      } catch (e) {}
      return className;
    };
    const remote = (v, byValue) => {
      const t = typeof v;
      if (v === undefined) return { type: 'undefined' };
      if (v === null) return { type: 'object', subtype: 'null', value: null };
      if (t === 'number') {
        if (Number.isFinite(v) && !Object.is(v, -0)) return { type: 'number', value: v, description: String(v) };
        const u = Object.is(v, -0) ? '-0' : String(v);
        return { type: 'number', unserializableValue: u, description: u };
      }
      if (t === 'string' || t === 'boolean') return { type: t, value: v };
      if (t === 'bigint') return { type: 'bigint', unserializableValue: v + 'n', description: v + 'n' };
      if (t === 'symbol') { if (byValue) throw { cdp: "Object couldn't be returned by value" }; return { type: 'symbol', description: String(v), objectId: keep(v) }; }
      if (t === 'function') {
        if (byValue) return { type: 'function', value: {} };
        return { type: 'function', className: 'Function', description: Function.prototype.toString.call(v), objectId: keep(v) };
      }
      if (byValue) {
        let value;
        try { value = JSON.parse(JSON.stringify(v)); } catch (e) { throw { cdp: 'Object reference chain is too long' }; }
        return { type: 'object', value: value === undefined ? {} : value };
      }
      const subtype = subtypeOf(v);
      let className = 'Object';
      try { className = (v.constructor && v.constructor.name) || Object.prototype.toString.call(v).slice(8, -1); } catch (e) {}
      const out = { type: 'object' };
      if (subtype) out.subtype = subtype;
      out.className = className;
      out.description = describe(v, subtype, className);
      out.objectId = keep(v);
      return out;
    };
    const failed = (error, text) => {
      const exception = (error && typeof error === 'object') ? remote(error, false) : remote(error, false);
      if (error instanceof SyntaxError && /^Return statements are only valid inside functions/.test(error.message)) {
        exception.description = 'SyntaxError: Illegal return statement';
      }
      const details = { exceptionId: 1, text: text || 'Uncaught', lineNumber: 0, columnNumber: 0, exception };
      if (error instanceof SyntaxError) details.scriptId = String(context);
      return details;
    };
    """

    /// Runtime.evaluate in the page's world, as an async function of
    /// `expression`, `byValue`, `wait` and `context`: its answer as JSON.
    static let evaluation = """
    \(ExtensionDebugger.remote)
    let value;
    try {
      try { value = (0, eval)(expression); }
      catch (error) {
        if (error instanceof EvalError) return JSON.stringify({ csp: true });
        // Chrome's REPL takes a top-level await; eval doesn't.
        if (!(error instanceof SyntaxError) || !/\\bawait\\b/.test(expression)) throw error;
        const inner = expression.trim().replace(/^\\{([\\s\\S]*)\\}$/, '$1');
        try { value = await (0, eval)('(async () => (' + inner + '\\n))()'); }
        catch (again) { if (again instanceof SyntaxError) value = await (0, eval)('(async () => {' + inner + '\\n})()'); else throw again; }
      }
      if (wait && value && typeof value.then === 'function') {
        try { value = await value; }
        catch (error) { const d = failed(error, 'Uncaught (in promise) ' + (error && error.stack ? String(error).split('\\n')[0] : String(error))); return JSON.stringify({ result: byValue ? { type: 'object', value: {} } : d.exception, exceptionDetails: d }); }
      }
      return JSON.stringify({ result: remote(value, byValue) });
    } catch (error) {
      if (error && error.cdp) return JSON.stringify({ cdp: error.cdp });
      const d = failed(error);
      // A script that doesn't compile: Chrome answers with the error
      // itself, by value or not; one that throws, by value, with {}.
      const compiled = !(error instanceof SyntaxError);
      return JSON.stringify({ result: byValue && compiled ? { type: 'object', value: {} } : d.exception, exceptionDetails: d });
    }
    """

    private func evaluate(_ session: Session, _ tab: Tab, _ params: [String: Any]) async throws -> Any? {
        guard let web = tab.webKitOnly("Legacy extension debugger") else { throw Failure("The WebKit extension debugger is not available on this engine yet.") }
        let expression = params["expression"] as? String ?? ""
        let byValue = params["returnByValue"] as? Bool ?? false
        let wait = params["awaitPromise"] as? Bool ?? false
        let body = Self.evaluation
        let raw: Any?
        do {
            raw = try await timed(params["timeout"]) {
                try await web.callAsyncJavaScript(body, arguments: ["expression": expression, "byValue": byValue, "wait": wait, "context": session.context],
                                                     in: nil, contentWorld: .page)
            }
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure(code: -32000, (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription)
        }
        let answer = try Self.read(raw)
        if answer["csp"] as? Bool == true { return try await evaluateBare(tab, expression) }
        return answer
    }

    /// A page whose policy refuses eval: WebKit's own evaluation, which the
    /// policy doesn't govern, with its completion value as Chromium gives it.
    /// It can't await, and an object comes back by value or as its kind.
    private func evaluateBare(_ tab: Tab, _ expression: String) async throws -> Any? {
        guard let web = tab.webKitOnly("Legacy extension debugger") else { throw Failure("The WebKit extension debugger is not available on this engine yet.") }
        do {
            let value: Any? = try await withCheckedThrowingContinuation { done in
                web.evaluateJavaScript(expression, in: nil, in: .page) { result in
                    switch result {
                    case .success(let value): done.resume(returning: value)
                    case .failure(let error): done.resume(throwing: error)
                    }
                }
            }
            return ["result": Self.remote(value)]
        } catch {
            let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
            if message.contains("unsupported type") { return ["result": ["type": "object", "className": "Object", "description": "Object"]] }
            let kind = message.split(separator: ":").first.map(String.init) ?? "Error"
            let exception: [String: Any] = ["type": "object", "subtype": "error", "className": kind, "description": message]
            return ["result": exception, "exceptionDetails": ["exceptionId": 1, "text": "Uncaught", "lineNumber": 0, "columnNumber": 0, "exception": exception]]
        }
    }

    nonisolated static func remote(_ value: Any?) -> [String: Any] {
        switch value {
        case nil, is NSNull: return ["type": "object", "subtype": "null", "value": NSNull()]
        case let n as NSNumber where CFGetTypeID(n) == CFBooleanGetTypeID(): return ["type": "boolean", "value": n.boolValue]
        case let n as NSNumber: return ["type": "number", "value": n, "description": n.stringValue]
        case let s as String: return ["type": "string", "value": s]
        default: return ["type": "object", "value": value ?? NSNull()]
        }
    }

    private func callFunction(_ session: Session, _ tab: Tab, _ params: [String: Any]) async throws -> Any? {
        guard let web = tab.webKitOnly("Legacy extension debugger") else { throw Failure("The WebKit extension debugger is not available on this engine yet.") }
        let declaration = params["functionDeclaration"] as? String ?? ""
        let body = """
        \(Self.remote)
        const take = (a) => {
          if (!a) return undefined;
          if ('objectId' in a) { if (!kept.has(a.objectId)) throw { cdp: 'Could not find object with given id' }; return kept.get(a.objectId); }
          if ('unserializableValue' in a) return (0, eval)(a.unserializableValue);
          return a.value;
        };
        try {
          let self = undefined;
          if (objectId) { if (!kept.has(objectId)) return JSON.stringify({ cdp: 'Could not find object with given id' }); self = kept.get(objectId); }
          const f = (0, eval)('(' + declaration + ')');
          let value = f.apply(self, (args || []).map(take));
          if (wait && value && typeof value.then === 'function') value = await value;
          return JSON.stringify({ result: remote(value, byValue) });
        } catch (error) {
          if (error instanceof EvalError) return JSON.stringify({ cdp: 'Refused by the page\\u2019s Content Security Policy' });
          if (error && error.cdp) return JSON.stringify({ cdp: error.cdp });
          const d = failed(error);
          return JSON.stringify({ result: d.exception, exceptionDetails: d });
        }
        """
        let raw = try await web.callAsyncJavaScript(body, arguments: [
            "declaration": declaration, "objectId": params["objectId"] as? String ?? "", "args": params["arguments"] as? [Any] ?? [],
            "byValue": params["returnByValue"] as? Bool ?? false, "wait": params["awaitPromise"] as? Bool ?? false, "context": session.context,
        ], in: nil, contentWorld: .page)
        return try Self.read(raw)
    }

    /// The page's answer, a JSON string, or the CDP error it carries.
    private static func read(_ raw: Any?) throws -> [String: Any] {
        guard let text = raw as? String, let data = text.data(using: .utf8),
              let answer = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(code: -32000, "Execution context was destroyed.")
        }
        if let message = answer["cdp"] as? String { throw Failure(code: -32000, message) }
        return answer
    }

    /// Chrome's `timeout`, in ms: the answer stops waiting then, with
    /// Chrome's "execution was terminated". WebKit can't stop the script.
    private func timed(_ limit: Any?, _ work: @escaping @MainActor () async throws -> Any?) async throws -> Any? {
        guard let ms = (limit as? NSNumber)?.doubleValue, ms > 0 else { return try await work() }
        let exception: [String: Any] = ["type": "object", "subtype": "error", "className": "Error", "description": "Error: execution was terminated"]
        let stopped: [String: Any] = ["result": exception, "exceptionDetails": ["exceptionId": 1, "text": "Uncaught", "lineNumber": 0, "columnNumber": 0, "exception": exception]]
        let late = String(decoding: try JSONSerialization.data(withJSONObject: stopped), as: UTF8.self)
        let outcome: Result<Any?, Error> = await first(within: ms / 1000, otherwise: .success(late)) {
            do { return .success(try await work()) } catch { return .failure(error) }
        }
        return try outcome.get()
    }

    /// Whichever comes first, the work's answer or `otherwise` after the
    /// time: a script in a page held by a dialog never answers, and a
    /// task group would wait for it all the same.
    private func first<T>(within seconds: Double, otherwise: T, _ work: @escaping @MainActor () async -> T) async -> T {
        await withCheckedContinuation { (done: CheckedContinuation<T, Never>) in
            var over = false
            let finish = { (value: T) in
                guard !over else { return }
                over = true
                done.resume(returning: value)
            }
            Task { @MainActor in finish(await work()) }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { finish(otherwise) }
        }
    }

    /// A script of Yab's own about the page, in this world, given up on
    /// after a second.
    private func look(_ web: WKWebView, _ body: String, _ arguments: [String: Any] = [:]) async -> Any? {
        await first(within: 1, otherwise: nil) {
            try? await web.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: Self.world)
        }
    }

    // MARK: Page

    private struct Viewport {
        var width = 0.0, height = 0.0, scrollX = 0.0, scrollY = 0.0, ratio = 2.0, contentWidth = 0.0, contentHeight = 0.0
    }

    private func viewport(_ tab: Tab) async throws -> Viewport {
        guard let web = tab.webKitOnly("Legacy extension debugger") else { throw Failure("The WebKit extension debugger is not available on this engine yet.") }
        let raw = await look(web, """
            const e = document.documentElement;
            return [innerWidth, innerHeight, scrollX, scrollY, devicePixelRatio,
                    Math.max(e ? e.scrollWidth : 0, innerWidth), Math.max(e ? e.scrollHeight : 0, innerHeight)];
            """)
        let n = (raw as? [NSNumber] ?? []).map(\.doubleValue)
        guard n.count == 7 else { throw Failure(code: -32000, "Not attached to an active page") }
        return Viewport(width: n[0], height: n[1], scrollX: n[2], scrollY: n[3], ratio: n[4], contentWidth: n[5], contentHeight: n[6])
    }

    private func layoutMetrics(_ tab: Tab) async throws -> Any? {
        let v = try await viewport(tab)
        let r = v.ratio
        func layout(_ s: Double) -> [String: Any] { ["clientWidth": Int(v.width * s), "clientHeight": Int(v.height * s), "pageX": Int(v.scrollX), "pageY": Int(v.scrollY)] }
        func visual(_ s: Double) -> [String: Any] {
            ["clientWidth": v.width * s, "clientHeight": v.height * s, "offsetX": 0, "offsetY": 0, "pageX": v.scrollX, "pageY": v.scrollY, "scale": 1, "zoom": 1]
        }
        func content(_ s: Double) -> [String: Any] { ["x": 0, "y": 0, "width": v.contentWidth * s, "height": v.contentHeight * s] }
        return ["layoutViewport": layout(r), "visualViewport": visual(r), "contentSize": content(r),
                "cssLayoutViewport": layout(1), "cssVisualViewport": visual(1), "cssContentSize": content(1)]
    }

    private func screenshot(_ tab: Tab, _ params: [String: Any]) async throws -> Any? {
        guard let web = tab.webKitOnly("Legacy extension debugger") else { throw Failure("The WebKit extension debugger is not available on this engine yet.") }
        let v = try await viewport(tab)
        let zoom = web.pageZoom * web.magnification
        // The part asked for, in the page's CSS pixels, and the pixels it
        // comes out at: Chrome's are the CSS size times the clip's scale
        // times the device's ratio.
        var rect = CGRect(x: 0, y: 0, width: v.width, height: v.height)
        var scale = 1.0
        if let clip = params["clip"] as? [String: Any] {
            let n = { (k: String) in (clip[k] as? NSNumber)?.doubleValue ?? 0 }
            rect = CGRect(x: n("x") - v.scrollX, y: n("y") - v.scrollY, width: n("width"), height: n("height"))
            scale = (clip["scale"] as? NSNumber)?.doubleValue ?? 1
        }
        guard rect.width >= 1, rect.height >= 1 else { throw Failure(code: -32000, "Unable to capture screenshot") }
        let wide = max(1, Int((rect.width * scale * v.ratio).rounded()))
        let high = max(1, Int((rect.height * scale * v.ratio).rounded()))
        let shot = WKSnapshotConfiguration()
        shot.afterScreenUpdates = true
        shot.rect = CGRect(x: rect.minX * zoom, y: rect.minY * zoom, width: rect.width * zoom, height: rect.height * zoom)
        let image: NSImage
        do { image = try await web.takeSnapshot(configuration: shot) } catch { throw Failure(code: -32000, "Unable to capture screenshot") }
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: wide, pixelsHigh: high, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep)
        else { throw Failure(code: -32000, "Unable to capture screenshot") }
        context.cgContext.interpolationQuality = .high
        context.cgContext.draw(cg, in: CGRect(x: 0, y: 0, width: wide, height: high))
        let format = params["format"] as? String ?? "png"
        let quality = ((params["quality"] as? NSNumber)?.doubleValue ?? 80) / 100
        let data = format == "jpeg" || format == "webp"
            ? rep.representation(using: .jpeg, properties: [.compressionFactor: min(1, max(0, quality))])
            : rep.representation(using: .png, properties: [:])
        guard let data else { throw Failure(code: -32000, "Unable to capture screenshot") }
        return ["data": data.base64EncodedString()]
    }

    // MARK: dialogs

    /// The browser of the window a tab is in, as WebKit's tab says it.
    static func browser(of tab: Tab) -> Browser? {
        Extensions.shared.window(of: tab)?.browser ?? Extensions.shared.browser
    }

    /// A tab's page asked alert, confirm or prompt: an extension with Page
    /// on hears it, as Chromium tells it. The card stays for the person; the
    /// extension may answer instead (Page.handleJavaScriptDialog).
    func dialogOpening(_ tab: Tab, kind: String, message: String, defaultPrompt: String) {
        for session in sessions.values where session.tab === tab && session.page {
            emit(session, "Page.javascriptDialogOpening", ["url": tab.address?.absoluteString ?? "", "frameId": session.targetID,
                                                          "message": message, "type": kind, "hasBrowserHandler": true, "defaultPrompt": defaultPrompt])
        }
    }

    private func answerDialog(_ tab: Tab, _ params: [String: Any]) throws -> Any? {
        guard let question = tab.asks.first(where: { $0.fromPage }), let browser = Self.browser(of: tab) else {
            missed = "asks \(tab.asks.map { "\($0.kind)" }), browser \(Self.browser(of: tab) != nil)"
            throw Failure(code: -32602, "No dialog is showing")
        }
        let accept = params["accept"] as? Bool ?? false
        let text = params["promptText"] as? String ?? question.text
        browser.answerPageDialog(tab, accept ? .yes(text) : .no)
        for session in sessions.values where session.tab === tab && session.page {
            emit(session, "Page.javascriptDialogClosed", ["result": accept, "userInput": accept ? text : "", "frameId": session.targetID])
        }
        return [String: Any]()
    }

    // MARK: Input

    private static func flags(_ modifiers: Int) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & 1 != 0 { flags.insert(.option) }
        if modifiers & 2 != 0 { flags.insert(.control) }
        if modifiers & 4 != 0 { flags.insert(.command) }
        if modifiers & 8 != 0 { flags.insert(.shift) }
        return flags
    }

    private func mouse(_ session: Session, _ tab: Tab, _ params: [String: Any]) async throws {
        let type = params["type"] as? String ?? ""
        let x = (params["x"] as? NSNumber)?.doubleValue ?? 0
        let y = (params["y"] as? NSNumber)?.doubleValue ?? 0
        let button = params["button"] as? String ?? "none"
        let clicks = (params["clickCount"] as? NSNumber)?.intValue ?? 1
        let buttons = (params["buttons"] as? NSNumber)?.intValue ?? 0
        let modifiers = (params["modifiers"] as? NSNumber)?.intValue ?? 0
        guard let web = tab.webKitOnly("Legacy extension debugger") else { throw Failure("The WebKit extension debugger is not available on this engine yet.") }
        guard let window = web.window else {
            try await scriptMouse(session, tab, type: type, x: x, y: y, button: button, clicks: clicks, params: params)
            return
        }
        let zoom = web.pageZoom * web.magnification
        let local = NSPoint(x: x * zoom, y: web.isFlipped ? y * zoom : web.bounds.height - y * zoom)
        let at = web.convert(local, to: nil)
        let flags = Self.flags(modifiers)
        PageView.agentActing = true
        defer { PageView.agentActing = false }
        func event(_ kind: NSEvent.EventType, clicks: Int, pressure: Float) -> NSEvent? {
            NSEvent.mouseEvent(with: kind, location: at, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: pressure)
        }
        switch type {
        case "mouseMoved":
            if buttons & 1 != 0, let drag = event(.leftMouseDragged, clicks: 1, pressure: 1) { web.mouseDragged(with: drag); return }
            guard let moved = event(.mouseMoved, clicks: 0, pressure: 0) else { return }
            let owners = web.trackingAreas.compactMap { $0.owner as? NSResponder }
            if let owner = owners.first(where: { $0 !== web }) ?? owners.first { owner.mouseMoved(with: moved) } else { web.mouseMoved(with: moved) }
        case "mousePressed":
            window.makeFirstResponder(web)
            let before = await heard(web, "pointerdown")
            switch button {
            case "right": if let e = event(.rightMouseDown, clicks: clicks, pressure: 1) { web.rightMouseDown(with: e) }
            case "middle": if let e = event(.otherMouseDown, clicks: clicks, pressure: 1) { web.otherMouseDown(with: e) }
            default: if let e = event(.leftMouseDown, clicks: clicks, pressure: 1) { web.mouseDown(with: e) }
            }
            await heard(web, "pointerdown", beyond: before)
        case "mouseReleased":
            let before = await heard(web, "pointerup")
            switch button {
            case "right": if let e = event(.rightMouseUp, clicks: clicks, pressure: 0) { web.rightMouseUp(with: e) }
            case "middle": if let e = event(.otherMouseUp, clicks: clicks, pressure: 0) { web.otherMouseUp(with: e) }
            default: if let e = event(.leftMouseUp, clicks: clicks, pressure: 0) { web.mouseUp(with: e) }
            }
            await heard(web, "pointerup", beyond: before)
        case "mouseWheel":
            let dx = (params["deltaX"] as? NSNumber)?.doubleValue ?? 0
            let dy = (params["deltaY"] as? NSNumber)?.doubleValue ?? 0
            let before = await scrolled(web, x: x, y: y)
            let screen = window.convertPoint(toScreen: at)
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                wheel1: Int32(-dy.rounded()), wheel2: Int32(-dx.rounded()), wheel3: 0) {
                cg.location = CGPoint(x: screen.x, y: top - screen.y)
                cg.flags = CGEventFlags(rawValue: UInt64(flags.rawValue))
                cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
                cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
                if let wheel = NSEvent(cgEvent: cg) { web.scrollWheel(with: wheel) }
            }
            // Chrome answers once the page has scrolled. A wheel WebKit
            // didn't take there (nothing under the point it reads) is told
            // in script instead, as for a tab behind others.
            try? await Task.sleep(for: .milliseconds(60))
            if dx != 0 || dy != 0, await scrolled(web, x: x, y: y) == before {
                try await scriptMouse(session, tab, type: type, x: x, y: y, button: button, clicks: clicks, params: params)
            }
        default:
            throw Failure(code: -32602, "Invalid parameters: type")
        }
    }

    /// How many events of a kind the page has had, counted in this world
    /// from the first time it is asked. A real event goes to the page's
    /// process apart from script, so a script sent after it can run first;
    /// Chrome answers an Input command once the page has had the event.
    @discardableResult
    private func heard(_ web: WKWebView, _ type: String, beyond: Int? = nil) async -> Int {
        let count = """
            const all = globalThis.__yabHeard || (globalThis.__yabHeard = {});
            if (!(type in all)) { all[type] = 0; addEventListener(type, () => all[type]++, true); }
            return all[type];
            """
        guard let beyond else {
            return (await look(web, count, ["type": type]) as? NSNumber)?.intValue ?? 0
        }
        guard web.window != nil else { return beyond }
        let limit = Date().addingTimeInterval(type == "input" ? 0.3 : 0.6)
        while Date() < limit {
            let now = (await look(web, count, ["type": type]) as? NSNumber)?.intValue ?? 0
            if now > beyond { return now }
            try? await Task.sleep(for: .milliseconds(15))
        }
        return beyond
    }

    /// How far the page and whatever scrolls under a point have scrolled.
    private func scrolled(_ web: WKWebView, x: Double, y: Double) async -> String {
        let raw = await look(web, """
            let s = document.elementFromPoint(x, y), out = [scrollX, scrollY];
            for (; s; s = s.parentElement) out.push(s.scrollLeft, s.scrollTop);
            return out.join(',');
            """, ["x": x, "y": y])
        return raw as? String ?? ""
    }

    /// A tab whose view has no window, behind others: the page is told in
    /// script what a mouse would have told it, at the element under the
    /// point, the way the agent's clicks reach such a tab.
    private func scriptMouse(_ session: Session, _ tab: Tab, type: String, x: Double, y: Double, button: String, clicks: Int, params: [String: Any]) async throws {
        guard let web = tab.webKitOnly("Legacy extension debugger") else { throw Failure("The WebKit extension debugger is not available on this engine yet.") }
        if type == "mousePressed" { session.pressed[button] = CGPoint(x: x, y: y) }
        if type == "mouseReleased" { session.pressed[button] = nil }
        _ = await look(web, """
            const el = document.elementFromPoint(x, y) || document.body;
            if (!el) return false;
            const b = button === 'right' ? 2 : button === 'middle' ? 1 : 0;
            const init = { bubbles: true, cancelable: true, composed: true, clientX: x, clientY: y, button: b, detail: clicks, view: window };
            if (type === 'mouseMoved') { el.dispatchEvent(new PointerEvent('pointermove', init)); el.dispatchEvent(new MouseEvent('mousemove', init)); }
            else if (type === 'mousePressed') { el.dispatchEvent(new PointerEvent('pointerdown', init)); el.dispatchEvent(new MouseEvent('mousedown', init)); if (el.focus) el.focus(); }
            else if (type === 'mouseReleased') {
              el.dispatchEvent(new PointerEvent('pointerup', init)); el.dispatchEvent(new MouseEvent('mouseup', init));
              if (b === 0) { el.dispatchEvent(new MouseEvent('click', init)); if (clicks === 2) el.dispatchEvent(new MouseEvent('dblclick', init)); }
              else if (b === 2) el.dispatchEvent(new MouseEvent('contextmenu', init));
            } else if (type === 'mouseWheel') {
              el.dispatchEvent(new WheelEvent('wheel', { ...init, deltaX: dx, deltaY: dy }));
              let s = el;
              while (s && s !== document.documentElement && !(s.scrollHeight > s.clientHeight && /(auto|scroll)/.test(getComputedStyle(s).overflowY))) s = s.parentElement;
              (s && s !== document.documentElement ? s : document.scrollingElement || document.documentElement).scrollBy(dx, dy);
            }
            return true;
            """, ["x": x, "y": y, "type": type, "button": button, "clicks": clicks,
                  "dx": (params["deltaX"] as? NSNumber)?.doubleValue ?? 0, "dy": (params["deltaY"] as? NSNumber)?.doubleValue ?? 0])
    }

    /// Mac key codes by DOM code, for the keys CDP names.
    private static let macKeys: [String: UInt16] = {
        var keys: [String: UInt16] = [
            "Enter": 36, "NumpadEnter": 76, "Tab": 48, "Space": 49, "Backspace": 51, "Escape": 53, "Delete": 117,
            "ArrowLeft": 123, "ArrowRight": 124, "ArrowDown": 125, "ArrowUp": 126, "Home": 115, "End": 119,
            "PageUp": 116, "PageDown": 121, "Minus": 27, "Equal": 24, "BracketLeft": 33, "BracketRight": 30,
            "Backslash": 42, "Semicolon": 41, "Quote": 39, "Comma": 43, "Period": 47, "Slash": 44, "Backquote": 50,
            "F1": 122, "F2": 120, "F3": 99, "F4": 118, "F5": 96, "F6": 97, "F7": 98, "F8": 100, "F9": 101, "F10": 109, "F11": 103, "F12": 111,
        ]
        let letters: [Character: UInt16] = ["A": 0, "S": 1, "D": 2, "F": 3, "H": 4, "G": 5, "Z": 6, "X": 7, "C": 8, "V": 9, "B": 11,
                                            "Q": 12, "W": 13, "E": 14, "R": 15, "Y": 16, "T": 17, "O": 31, "U": 32, "I": 34, "P": 35,
                                            "L": 37, "J": 38, "K": 40, "N": 45, "M": 46]
        for (letter, code) in letters { keys["Key\(letter)"] = code }
        let digits: [UInt16] = [29, 18, 19, 20, 21, 23, 22, 26, 28, 25]
        for (digit, code) in digits.enumerated() { keys["Digit\(digit)"] = code }
        return keys
    }()

    /// Function keys' characters, as AppKit gives them.
    private static let named: [String: String] = [
        "Enter": "\r", "Tab": "\t", "Backspace": "\u{7f}", "Escape": "\u{1b}", " ": " ",
        "ArrowLeft": String(UnicodeScalar(NSLeftArrowFunctionKey)!), "ArrowRight": String(UnicodeScalar(NSRightArrowFunctionKey)!),
        "ArrowUp": String(UnicodeScalar(NSUpArrowFunctionKey)!), "ArrowDown": String(UnicodeScalar(NSDownArrowFunctionKey)!),
        "Delete": String(UnicodeScalar(NSDeleteFunctionKey)!), "Home": String(UnicodeScalar(NSHomeFunctionKey)!),
        "End": String(UnicodeScalar(NSEndFunctionKey)!), "PageUp": String(UnicodeScalar(NSPageUpFunctionKey)!),
        "PageDown": String(UnicodeScalar(NSPageDownFunctionKey)!),
    ]

    /// A key down is the whole stroke, down and up, the way the agent's
    /// keys go (AgentPage.send: real events in a window, script without
    /// one); its key up has already been sent with it. `char` is words in.
    private func key(_ tab: Tab, _ params: [String: Any]) async {
        guard let web = tab.webKitOnly("Legacy extension debugger") else { return }
        let type = params["type"] as? String ?? ""
        let text = params["text"] as? String ?? ""
        if type == "char" {
            guard !text.isEmpty else { return }
            let before = await heard(web, "input")
            AgentPage.insert(tab.page, text)
            await heard(web, "input", beyond: before)
            return
        }
        guard type == "keyDown" || type == "rawKeyDown" else { return }
        let key = params["key"] as? String ?? ""
        let code = params["code"] as? String ?? ""
        let modifiers = (params["modifiers"] as? NSNumber)?.intValue ?? 0
        let keyCode = (params["windowsVirtualKeyCode"] as? NSNumber)?.intValue ?? 0
        let characters = Self.named[key] ?? (text.isEmpty ? key.lowercased() : text.lowercased())
        guard !characters.isEmpty else { return }
        // A chord Chrome carries out as editing commands (Claude's ⌘A is
        // selectAll): the same commands, sent the way the Edit menu sends
        // them, since a ⌘ key handed to the view goes to the menu first.
        let commands = (params["commands"] as? [String] ?? []).filter { !$0.isEmpty }
        if modifiers & (2 | 4) != 0, !commands.isEmpty {
            if let window = web.window {
                window.makeFirstResponder(web)
                PageView.agentActing = true
                defer { PageView.agentActing = false }
                for command in commands { NSApp.sendAction(Selector(command + ":"), to: web, from: web) }
            } else {
                // A tab behind others: the editing commands a page has.
                let named = ["selectAll": "selectAll", "deleteBackward": "delete", "deleteForward": "forwardDelete", "insertNewline": "insertParagraph"]
                let script = "for (const c of \(Self.json(commands.compactMap { named[$0] }))) document.execCommand(c)"
                web.evaluateJavaScript(script, in: nil, in: Self.world)
            }
            return
        }
        let mac = Self.macKeys[code] ?? characters.first.map { Bench.keyCode(for: $0) } ?? 49
        let typed = modifiers & (2 | 4) != 0 ? "" : (key == "Enter" ? "" : text)
        let stroke = AgentPage.Stroke(command: modifiers & 4 != 0, shift: modifiers & 8 != 0, option: modifiers & 1 != 0, control: modifiers & 2 != 0,
                                      code: mac, characters: characters, key: key, domCode: code, keyCode: keyCode, text: typed)
        let before = await heard(web, "keyup")
        AgentPage.send(tab.page, [stroke])
        await heard(web, "keyup", beyond: before)
    }

    private static func json(_ value: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: value)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    }

    // MARK: - the page script for Runtime's and Network's events

    final class Relay: NSObject, WKScriptMessageHandler {
        weak var owner: ExtensionDebugger?
        weak var tab: Tab?
        init(owner: ExtensionDebugger, tab: Tab) {
            self.owner = owner
            self.tab = tab
        }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            let body = message.body
            MainActor.assumeIsolated {
                guard let tab, let items = body as? [[String: Any]] else { return }
                owner?.heard(tab, items)
            }
        }
    }

    /// Wraps console, listens for errors and lists the page's requests,
    /// once per document, posting each in a batch a beat.
    static let pageScript = """
    (() => {
      if (window.__yabDebuggerOff) return;
      const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.yabDebugger;
      if (!handler) return;
      const post = handler.postMessage.bind(handler);
      let queue = [], timer = 0;
      const send = (item) => { queue.push(item); if (!timer) timer = setTimeout(() => { timer = 0; const q = queue; queue = []; try { post(q); } catch (e) {} }, 50); };
      const arg = (v) => {
        const t = typeof v;
        if (v === undefined) return { type: 'undefined' };
        if (v === null) return { type: 'object', subtype: 'null', value: null };
        if (t === 'number') return Number.isFinite(v) ? { type: 'number', value: v, description: String(v) } : { type: 'number', unserializableValue: String(v), description: String(v) };
        if (t === 'string' || t === 'boolean') return { type: t, value: v };
        if (t === 'function') return { type: 'function', className: 'Function', description: String(v).slice(0, 200) };
        if (t !== 'object') return { type: t, description: String(v) };
        let className = 'Object'; try { className = v.constructor && v.constructor.name || className; } catch (e) {}
        const out = { type: 'object', className, description: v instanceof Error ? String(v.stack || v) : className };
        if (Array.isArray(v)) { out.subtype = 'array'; out.description = 'Array(' + v.length + ')'; }
        else if (v instanceof Error) out.subtype = 'error';
        else if (typeof Node !== 'undefined' && v instanceof Node) { out.subtype = 'node'; out.description = v.nodeName.toLowerCase(); }
        try { out.value = JSON.parse(JSON.stringify(v)); } catch (e) {}
        return out;
      };
      // The caller's place: WebKit's stack has no header, so its third
      // line is whoever called console; eval's own code has no address,
      // which Chrome gives as an empty url.
      const where = () => { const line = String(new Error().stack || '').split('\\n')[2] || ''; const m = line.match(/@(.+):(\\d+):(\\d+)$/); return m ? { url: m[1], lineNumber: +m[2] - 1, columnNumber: +m[3] - 1 } : { url: '', lineNumber: 0, columnNumber: 0 }; };
      const original = {};
      const kinds = { log: 'log', info: 'info', warn: 'warning', error: 'error', debug: 'debug', dir: 'dir', table: 'table', trace: 'trace', assert: 'assert' };
      for (const name of Object.keys(kinds)) {
        const f = console[name];
        if (typeof f !== 'function') continue;
        original[name] = f;
        console[name] = function (...args) {
          if (name !== 'assert' || !args[0]) {
            const at = where();
            send({ t: 'console', type: kinds[name], args: (name === 'assert' ? args.slice(1) : args).map(arg), at, ts: Date.now() });
          }
          return f.apply(this, args);
        };
      }
      const onError = (event) => send({ t: 'exception', message: String(event.message || event.error), error: event.error ? arg(event.error) : null, url: event.filename || '', line: (event.lineno || 1) - 1, column: (event.colno || 1) - 1, ts: Date.now() });
      const onRejection = (event) => send({ t: 'exception', message: 'Uncaught (in promise) ' + String(event.reason && event.reason.stack ? String(event.reason).split('\\n')[0] : event.reason), error: arg(event.reason), url: '', line: 0, column: 0, ts: Date.now() });
      addEventListener('error', onError);
      addEventListener('unhandledrejection', onRejection);
      let observer = null;
      try {
        const nav = performance.getEntriesByType('navigation')[0];
        if (nav) send({ t: 'net', url: nav.name, kind: 'Document', status: nav.responseStatus || 200, start: nav.startTime });
        observer = new PerformanceObserver((list) => { for (const e of list.getEntries()) send({ t: 'net', url: e.name, kind: e.initiatorType, status: e.responseStatus, start: e.startTime }); });
        observer.observe({ type: 'resource', buffered: true });
      } catch (e) {}
      Object.defineProperty(window, '__yabDebuggerOff', { configurable: true, value: () => {
        for (const name of Object.keys(original)) console[name] = original[name];
        removeEventListener('error', onError);
        removeEventListener('unhandledrejection', onRejection);
        if (observer) observer.disconnect();
        delete window.__yabDebuggerOff;
      } });
    })();
    """

    private func inject(_ session: Session) {
        guard let tab = session.tab else { return }
        guard let web = tab.webKitOnly("Legacy extension debugger") else { return }
        if session.handler == nil {
            let relay = Relay(owner: self, tab: tab)
            web.configuration.userContentController.removeScriptMessageHandler(forName: Self.handlerName, contentWorld: .page)
            web.configuration.userContentController.add(relay, contentWorld: .page, name: Self.handlerName)
            session.handler = relay
        }
        web.evaluateJavaScript(Self.pageScript, in: nil, in: .page)
    }

    fileprivate func heard(_ tab: Tab, _ items: [[String: Any]]) {
        guard let session = sessions.values.first(where: { $0.tab === tab }) else { return }
        let wall = Date().timeIntervalSince1970
        for item in items {
            switch item["t"] as? String {
            case "console" where session.runtime:
                var params: [String: Any] = ["type": item["type"] ?? "log", "args": item["args"] ?? [Any](), "executionContextId": session.context,
                                             "timestamp": (item["ts"] as? NSNumber)?.doubleValue ?? wall * 1000]
                if let at = item["at"] as? [String: Any] {
                    params["stackTrace"] = ["callFrames": [["functionName": "", "scriptId": "0", "url": at["url"] ?? "",
                                                            "lineNumber": at["lineNumber"] ?? 0, "columnNumber": at["columnNumber"] ?? 0]]]
                }
                emit(session, "Runtime.consoleAPICalled", params)
            case "exception" where session.runtime:
                var exception = item["error"] as? [String: Any] ?? ["type": "object", "subtype": "error", "className": "Error"]
                if exception["description"] == nil { exception["description"] = item["message"] ?? "" }
                emit(session, "Runtime.exceptionThrown", ["timestamp": (item["ts"] as? NSNumber)?.doubleValue ?? wall * 1000, "exceptionDetails": [
                    "exceptionId": 1, "text": item["message"] ?? "Uncaught", "lineNumber": item["line"] ?? 0, "columnNumber": item["column"] ?? 0,
                    "url": item["url"] ?? "", "executionContextId": session.context, "exception": exception,
                ]])
            case "net" where session.network:
                session.requests += 1
                let id = "yab.\(session.requests)"
                let url = item["url"] as? String ?? ""
                let kind = Self.resourceType(item["kind"] as? String ?? "")
                let status = (item["status"] as? NSNumber)?.intValue ?? 0
                let now = ProcessInfo.processInfo.systemUptime
                emit(session, "Network.requestWillBeSent", ["requestId": id, "loaderId": session.loaderID, "documentURL": tab.address?.absoluteString ?? "",
                                                           "request": ["url": url, "method": "GET", "headers": [String: Any]()],
                                                           "timestamp": now, "wallTime": wall, "initiator": ["type": "other"], "type": kind, "frameId": session.targetID])
                // Resource timing gives no status for another site's file
                // that doesn't allow it (0): it loaded, as far as anyone
                // here can tell.
                emit(session, "Network.responseReceived", ["requestId": id, "loaderId": session.loaderID, "timestamp": now, "type": kind, "frameId": session.targetID,
                                                          "response": ["url": url, "status": status == 0 ? 200 : status, "statusText": "", "headers": [String: Any](), "mimeType": ""]])
                emit(session, "Network.loadingFinished", ["requestId": id, "timestamp": now, "encodedDataLength": 0])
            default:
                continue
            }
        }
    }

    private static func resourceType(_ initiator: String) -> String {
        switch initiator {
        case "Document": return "Document"
        case "script": return "Script"
        case "link", "css": return "Stylesheet"
        case "img", "image": return "Image"
        case "fetch": return "Fetch"
        case "xmlhttprequest": return "XHR"
        case "video", "audio": return "Media"
        default: return "Other"
        }
    }
}

// MARK: - the dock

/// "Claude is controlling this tab" with Stop, at the page's foot while an
/// extension holds the tab with chrome.debugger, the dark plate the agent's
/// dock and Measure's are. Stop lets go, as Chromium's bar's Cancel does.
@available(macOS 15.4, *)
struct ExtensionDebuggerDock: View {
    var tab: Tab
    private var debugger = ExtensionDebugger.shared

    var body: some View {
        if let holders = debugger.holders[tab.id], let first = holders.first {
            HStack(spacing: 10) {
                Group {
                    if let icon = Extensions.shared.icon(for: first.extensionID, side: 15) {
                        Image(nsImage: icon).resizable().interpolation(.high)
                    } else {
                        Symbol("puzzlepiece.extension", size: 11).foregroundStyle(HUD.ink)
                    }
                }
                .frame(width: 15, height: 15)
                .padding(.leading, 12)
                Text(holders.count == 1 ? "\(first.name) is controlling this tab" : "\(first.name) and \(holders.count - 1) more are controlling this tab")
                    .font(.system(size: 12.5))
                    .foregroundStyle(HUD.ink)
                    .lineLimit(1)
                Button("Stop") { ExtensionDebugger.shared.stop(tab) }
                    .buttonStyle(.yab(.secondary, .regular, surface: .dark))
                    .padding(.trailing, 4)
            }
            .frame(height: 36)
            .fixedSize()
            .background { HUD.plate(Radius.control + 4, surface: .dark) }
            .environment(\.colorScheme, .dark)
        }
    }
}

/// Every chrome.debugger call, answer and event, one JSON row each, to
/// debugger-calls.jsonl in Yab's folder, while
/// `defaults write <bundle id> extensions.debugger.record -bool YES` is set:
/// what an AI extension asks of a page, recorded in the profile it is
/// signed in to (docs/extension-apis-plan.md, A1). Off, it costs one read.
@MainActor
enum DebuggerCallLog {
    static var on: Bool { Store.settings.bool(forKey: "extensions.debugger.record") }
    private static let queue = DispatchQueue(label: "yab.debugger.log")
    static var file: URL { Store.folder.appendingPathComponent("debugger-calls.jsonl") }

    static func clip(_ value: Any?, _ limit: Int) -> String {
        guard let value, JSONSerialization.isValidJSONObject([value]),
              let data = try? JSONSerialization.data(withJSONObject: [value], options: [.sortedKeys]) else { return value.map { "\($0)" } ?? "null" }
        let text = String(decoding: data.dropFirst().dropLast(), as: UTF8.self)
        return text.count > limit ? String(text.prefix(limit)) + "…(\(text.count))" : text
    }

    static func write(_ row: [String: Any]) {
        var row = row
        row["t"] = Int(Date().timeIntervalSince1970 * 1000)
        guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return }
        let file = file
        queue.async {
            if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
            guard let handle = try? FileHandle(forWritingTo: file) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data + Data([10]))
        }
    }
}
