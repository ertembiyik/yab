import AppKit
import WebKit

// The wire between WebKit's inspector page and Yab's own panels. Network
// has a bridge of its own (DevNetBridge.swift); every other panel goes
// through this one. The inspector's page keeps WebKit's models (WI.*) and
// the connection to the page's backend, so Yab asks it for anything:
//
// - `call`: one of the protocol's commands, "CSS.getMatchedStylesForNode",
//   sent as WebKit's frontend sends it, or one of a panel module's own
//   functions, "console.eval", that reads WebKit's models;
// - channels: a module posts what changed on a channel ("console"), in one
//   batch a beat, and Yab's model for the tab hears it (DevWireListener);
// - the protocol monitor: every message between WebKit's frontend and its
//   backend, while the drawer's Protocol monitor is open.
//
// The beat is Network's (netTick): WebKit lets the timers of its hidden
// inspector page wait up to a minute, so the batches go out on Yab's clock.
//
// Only this file and each panel's bridge know WebKit's inspector classes by
// name. A module that finds them not as it expects says so on its channel,
// and its panel offers WebKit's own instead.

enum DevWire {
    /// What each panel puts in the inspector's page, after the wire itself.
    static var scripts: [String] { [core, DevConsoleBridge.script, DevWorkbenchBridge.script, DevApplicationBridge.script] }

    /// The models that hear a channel for a tab, made as the inspector
    /// connects so nothing said before a panel was opened is lost.
    static let listeners: [DevWireListener.Type] = [ConsoleLog.self, ProtocolLog.self, DevWorkbench.self]

    static let core = PageScript.load("dev-wire")
}

/// A model of a tab that hears one of the wire's channels.
@MainActor protocol DevWireListener: AnyObject {
    static var channel: String { get }
    init()
    /// A batch as the module posted it: a JSON array.
    func hear(_ json: String)
    /// WebKit's inspector came up anew for the tab: what it held is gone,
    /// or kept (Keep log).
    func connected()
    /// WebKit's inspector came up anew for the same document it was put
    /// away on as another tab came in front: what is here stays, as in
    /// Chrome, and only what the new inspector numbers anew is found again.
    func reconnected()
}

extension DevWireListener {
    func connected() {}
    func reconnected() { connected() }
}

nonisolated(unsafe) private var modelsKey: UInt8 = 0

extension Tab {
    /// The wire's models for this tab's page, by channel.
    private var wireModels: [String: AnyObject] {
        get { objc_getAssociatedObject(self, &modelsKey) as? [String: AnyObject] ?? [:] }
        set { objc_setAssociatedObject(self, &modelsKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    /// The tab's model of a kind, made the first time it is asked for.
    func devModel<T: DevWireListener>(_ kind: T.Type) -> T {
        if let model = wireModels[kind.channel] as? T { return model }
        let model = T()
        wireModels[kind.channel] = model
        return model
    }

    /// A batch on a channel, for the model that hears it.
    func wireHeard(_ channel: String, _ json: String) {
        for kind in DevWire.listeners where kind.channel == channel {
            (wireModels[channel] as? DevWireListener ?? make(kind)).hear(json)
        }
    }

    private func make(_ kind: DevWireListener.Type) -> DevWireListener {
        let model = kind.init()
        wireModels[kind.channel] = model
        return model
    }

    /// Every model told the inspector came up anew; `again`: on the
    /// document it was put away on (DevReturn).
    func wireConnected(again: Bool = false) {
        for kind in DevWire.listeners {
            let model = wireModels[kind.channel] as? DevWireListener ?? make(kind)
            if again { model.reconnected() } else { model.connected() }
        }
    }
}

// MARK: - the browser's side

extension Browser {
    /// The inspector's page for the tab in front, once it can be spoken to.
    var wirePage: WKWebView? {
        guard let tab = toolsFront, inspected === tab, inspectorLive, let inspector = Inspector.ofPage(tab.page) else { return nil }
        return DevTools.page(inspector)
    }

    /// A call on the wire, its answer back as JSON-able values; nil when
    /// the inspector isn't up or the call failed (`failed` says why).
    func wire(_ method: String, _ params: [String: Any] = [:], failed: ((String) -> Void)? = nil, _ done: ((Any?) -> Void)? = nil) {
        if applicationNative(method, params, failed: failed, done: done) { return }
        guard let web = wirePage else { failed?("The inspector isn’t connected"); done?(nil); return }
        web.callAsyncJavaScript("if (!window.__yabWire) throw new Error('no wire'); return await window.__yabWire.call(m, p);",
                                arguments: ["m": method, "p": params], in: nil, in: .page) { result in
            switch result {
            case .success(let value): done?(method == "application.frame" ? self.applicationFrameInfo(value) : value)
            case .failure(let error):
                failed?((error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription)
                done?(nil)
            }
        }
    }

    /// The wire's beat, folded into Network's (netTick): JavaScript to run
    /// in the inspector's page on each beat.
    static let wireTick = "(window.__yabWire ? window.__yabWire.tick() : 0)"
}

// MARK: - the protocol monitor

/// Every message between WebKit's inspector and the page's backend, while
/// the drawer's Protocol monitor records: Chrome's monitor, on WebKit's
/// protocol.
@MainActor @Observable final class ProtocolLog: DevWireListener {
    static let channel = "protocol"

    struct Message: Identifiable, Equatable {
        let id: Int
        /// send, response, event.
        var kind: String
        var method: String
        var request: String
        var response: String
        var error: String
        var sent: Double
        var elapsed: Double?
        var target: String
    }

    private(set) var messages: [Message] = []
    var recording = false
    @ObservationIgnored private var next = 1
    @ObservationIgnored private var pending: [Int: Int] = [:]

    init() {}

    func hear(_ json: String) {
        guard recording, let data = json.data(using: .utf8), let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        var out = messages
        for item in items {
            let kind = item["k"] as? String ?? ""
            let id = (item["id"] as? NSNumber)?.intValue ?? 0
            let at = (item["t"] as? NSNumber)?.doubleValue ?? 0
            let text = item["p"] as? String ?? ""
            if kind == "response", let index = pending.removeValue(forKey: id), index < out.count {
                out[index].response = text
                out[index].error = item["e"] as? String ?? ""
                out[index].elapsed = at - out[index].sent
                continue
            }
            let message = Message(id: next, kind: kind == "send" ? "send" : "event", method: item["m"] as? String ?? "",
                                  request: kind == "send" ? text : "", response: kind == "event" ? text : "", error: "",
                                  sent: at, elapsed: nil, target: item["g"] as? String ?? "")
            next += 1
            if kind == "send", id > 0 { pending[id] = out.count }
            out.append(message)
        }
        if out.count > 4000 {
            let cut = out.count - 4000
            out.removeFirst(cut)
            pending = pending.compactMapValues { $0 >= cut ? $0 - cut : nil }
        }
        messages = out
    }

    func clear() {
        messages = []
        pending = [:]
    }
}

extension Browser {
    /// The protocol monitor on or off in the inspector's page.
    func protocolRecord(_ on: Bool) {
        guard let tab = toolsFront else { return }
        tab.devModel(ProtocolLog.self).recording = on
        wire("wire.monitorSet", ["on": on])
    }
}
