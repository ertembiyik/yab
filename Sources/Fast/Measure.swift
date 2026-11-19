import AppKit
import WebKit

// Measure: rulers on a local page, as Figma has them (⌥⌘U, or the ruler in
// the address band, Developer Mode only). The rulers lie over the page's top
// and left edges and the page keeps its width, so what is measured is the
// layout at the width it really has.
//
// What shows comes when asked and goes the same way (docs/measure.md):
// under the pointer a box shows its outline and its name and size, and
// nothing more; a click picks it, and its numbers stand on the page, each
// in the band it measures: padding inside, margin outside, the gaps of a
// flex or a grid, and a red bar on an edge its letters come closer than 4
// to, 0 too. ⌥ measures: from the picked box to the one under the pointer,
// or, over the picked box itself, every space inside it (its lines, for
// text). ⌥S keeps a measurement, N writes a note for the agent, X shows
// every box at once. Guides are pulled out of a ruler, snap to the edges
// and middles of what is under them, the trackpad ticking as one catches,
// and go back into it to be dropped. The corner where the rulers meet opens
// a menu: columns, an 8-point grid, pixels or rems, Clear Guides.
//
// Words stay off the page: they are in Measure's dock at its foot
// (MeasureDock.swift), the agent's dock's shape and glass, which says what
// is picked, how many troubles the page has, and grows into a sheet of the
// picked box's numbers, rules, motion, kept measurements and notes on
// Space.
//
// All of it on the page is drawn in yab's own world (Web.world), inside a
// closed shadow root in the top layer: it scrolls with the page with no lag,
// lies over any z-index, and the page's scripts never see into it. Numbers
// are the page's CSS pixels; what yab draws is kept at the same size on
// screen at any zoom. Nothing is put into a page until Measure is turned on,
// and it is all taken out again when it is turned off.
//
// Guides are kept by yab, per page (host, port and path), not in the page:
// they are there again after a reload or a hot update.
//
// Inspired by ibelick's Mesurer (MIT), github.com/ibelick/mesurer: its ⌥S,
// its motion scrubbing. The drawing and the dock are yab's.

final class MeasureRelay: NSObject, PageScriptReceiving {
    static let name = "yabMeasure"
    weak var tab: Tab?

    func receive(_ message: PageScriptMessage) {
        guard message.frame.isMain, let body = message.body as? [String: Any],
              let kind = body["k"] as? String else { return }
        MainActor.assumeIsolated {
            guard let tab else { return }
            switch kind {
            case "guides":
                Measure.keep(guides: body["guides"] as? [String] ?? [], for: tab.address)
            case "off":
                tab.measure(false)
            case "menu":
                Measure.menu(for: tab, at: CGPoint(x: body["x"] as? Double ?? 0, y: body["y"] as? Double ?? 0))
            case "copy":
                guard let text = body["text"] as? String else { return }
                tab.onMeasureCopy?(tab, text)
                tab.measureModel.copied()
            case "elements":
                guard let path = body["path"] as? String else { return }
                tab.onMeasureElements?(tab, path)
            case "dock":
                guard let json = body["dock"] as? String, let data = json.data(using: .utf8),
                      let info = try? JSONDecoder().decode(MeasureInfo.self, from: data) else { return }
                tab.measureModel.heard(info)
            case "time":
                tab.measureModel.times = (body["t"] as? [Double]) ?? []
            case "details":
                tab.measureModel.toggleDetails()
            case "note":
                tab.measureModel.noting = true
            case "snap":
                // A guide caught an edge or a middle, a padding pulled by
                // hand reached its next step: felt, as the Mac's own guides
                // are, once for each.
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            default:
                break
            }
        }
    }
}

/// What the page says the dock should show: the picked box, the page's
/// troubles, and the sheet's rows, rules, motion, kept measurements and
/// notes (the page's tellDock).
struct MeasureInfo: Decodable, Equatable {
    struct Picked: Decodable, Equatable {
        let name: String
        let size: String
    }
    /// A piece of a row's value, red when it is the trouble.
    struct Piece: Decodable, Equatable, Hashable {
        let t: String
        let bad: Bool
    }
    struct Row: Decodable, Equatable, Identifiable {
        let l: String
        let v: [Piece]
        /// The text's color, then its ground, for the Color row.
        let c: [String]?
        var id: String { l + v.map(\.t).joined() }
    }
    struct Decl: Decodable, Equatable, Identifiable {
        let p: String
        let v: String
        /// Beaten by another rule.
        let x: Bool
        /// Changed here by hand.
        let ch: Bool
        var id: String { p }
    }
    struct Rule: Decodable, Equatable, Identifiable {
        let sel: String
        let `where`: String
        let decls: [Decl]
        var id: String { sel + `where` }
    }
    struct Motion: Decodable, Equatable, Identifiable {
        let name: String
        let ms: Double
        let delay: Double
        let ease: String
        let bez: [Double]
        let props: [[String]]
        let total: Double
        let t: Double
        let running: Bool
        var id: String { name }
    }
    struct Trouble: Decodable, Equatable, Identifiable {
        let title: String
        let name: String
        let words: String
        var id: String { title + name + words }
    }
    struct Kept: Decodable, Equatable, Identifiable {
        let a: String
        let b: String
        let v: String
        var id: String { a + b + v }
    }
    struct Note: Decodable, Equatable, Identifiable {
        let n: Int
        let text: String
        let mine: Bool
        var id: Int { n }
    }
    struct Compare: Decodable, Equatable {
        let name: String
        let dx: Double
        let dy: Double
        let diff: Bool
    }

    var sel: Picked?
    var issues: Int
    var showIssues: Bool
    var rows: [Row]
    var rules: [Rule]
    var motion: [Motion]
    var list: [Trouble]
    var pins: [Kept]
    var notes: [Note]
    var compare: Compare?
    var xray: Bool

    static let idle = MeasureInfo(sel: nil, issues: 0, showIssues: false, rows: [], rules: [], motion: [], list: [], pins: [], notes: [], compare: nil, xray: false)
}

/// The dock's side of Measure, apart from the Tab so that what the page
/// says many times a second redraws the dock and nothing else.
@MainActor
@Observable final class MeasureModel {
    private(set) var info = MeasureInfo.idle
    /// The picked box's animations' times while they run.
    var times: [Double] = []
    /// The sheet out over the dock, kept for the next time (Measure.details).
    private(set) var details = Measure.details
    /// The dock's words a field for a note.
    var noting = false
    /// Copy for Agent saying Copied, for a moment.
    private(set) var copiedNow = false
    @ObservationIgnored private var copiedTask: Task<Void, Never>?

    func heard(_ new: MeasureInfo) {
        guard new != info else { return }
        info = new
        times = new.motion.map(\.t)
        if new.sel == nil { noting = false }
    }

    func toggleDetails() {
        details.toggle()
        Measure.details = details
    }

    func copied() {
        copiedTask?.cancel()
        copiedNow = true
        copiedTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled { self?.copiedNow = false }
        }
    }

    func reset() {
        info = .idle
        times = []
        noting = false
        copiedNow = false
    }
}

enum Measure {
    // MARK: - what is kept

    private static var store: UserDefaults { Store.settings }

    /// Columns laid over the page's content.
    static var columns: Bool {
        get { store.bool(forKey: "measure.columns") }
        set { store.set(newValue, forKey: "measure.columns") }
    }

    /// Lines every 8 pixels.
    static var grid: Bool {
        get { store.bool(forKey: "measure.grid") }
        set { store.set(newValue, forKey: "measure.grid") }
    }

    /// Numbers in rems, of the page's own root size, rather than pixels.
    static var rems: Bool {
        get { store.bool(forKey: "measure.rems") }
        set { store.set(newValue, forKey: "measure.rems") }
    }

    /// The dock's sheet out (Space), as it was left.
    static var details: Bool {
        get { store.bool(forKey: "measure.details") }
        set { store.set(newValue, forKey: "measure.details") }
    }

    /// Pages whose guides are kept, the most; the oldest go first.
    static let keptPages = 200

    /// A page's own place: its server and path, not its query or fragment,
    /// so a hot update or a changed filter keeps the guides.
    static func key(_ url: URL?) -> String? {
        guard let url, Address.isLocal(url), let host = url.host()?.lowercased() else { return nil }
        let port = url.port.map { ":\($0)" } ?? ""
        let path = url.path().isEmpty ? "/" : url.path()
        return host + port + path
    }

    /// Each guide as "v:120" (a line down, 120 pixels from the left) or
    /// "h:48.5" (a line across).
    static func guides(for url: URL?) -> [String] {
        guard let key = key(url), let all = store.dictionary(forKey: "measure.guides"),
              let page = all[key] as? [String: Any] else { return [] }
        return (page["g"] as? [String] ?? []).filter(isGuide)
    }

    static func keep(guides: [String], for url: URL?) {
        guard let key = key(url) else { return }
        var all = store.dictionary(forKey: "measure.guides") ?? [:]
        let kept = Array(guides.filter(isGuide).prefix(100))
        if kept.isEmpty {
            all.removeValue(forKey: key)
        } else {
            all[key] = ["g": kept, "t": Date().timeIntervalSince1970]
        }
        if all.count > keptPages {
            let old = all.sorted { (($0.value as? [String: Any])?["t"] as? Double ?? 0) < (($1.value as? [String: Any])?["t"] as? Double ?? 0) }
            for (key, _) in old.prefix(all.count - keptPages) { all.removeValue(forKey: key) }
        }
        store.set(all, forKey: "measure.guides")
    }

    static func isGuide(_ text: String) -> Bool {
        let parts = text.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, parts[0] == "v" || parts[0] == "h", let at = Double(parts[1]) else { return false }
        return at.isFinite && abs(at) < 1_000_000
    }

    // MARK: - the page's side

    /// What the page is told: on or off, the zoom, the guides, the menu's
    /// choices, and a point whose element is to be picked (Inspect
    /// Element), in the page's CSS pixels.
    @MainActor static func state(for tab: Tab, pick: CGPoint? = nil) -> String {
        var state: [String: Any] = [
            "on": tab.measuring,
            "zoom": Double(tab.page.pageZoom),
            "guides": guides(for: tab.address),
            "columns": columns,
            "grid": grid,
            "rems": rems,
        ]
        if let pick { state["pick"] = ["x": Double(pick.x), "y": Double(pick.y)] }
        guard let data = try? JSONSerialization.data(withJSONObject: state),
              let json = String(data: data, encoding: .utf8) else { return "{\"on\":false}" }
        return json
    }

    // MARK: - the corner's menu

    @MainActor static func menu(for tab: Tab, at point: CGPoint) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let hand = MenuHand.shared
        hand.tab = tab
        func item(_ title: String, _ on: Bool, _ tag: Int) {
            let item = NSMenuItem(title: title, action: #selector(MenuHand.pick(_:)), keyEquivalent: "")
            item.target = hand
            item.tag = tag
            item.state = on ? .on : .off
            menu.addItem(item)
        }
        item("Columns", columns, 1)
        item("8-Point Grid", grid, 2)
        menu.addItem(.separator())
        item("Pixels", !rems, 3)
        item("Rems", rems, 4)
        menu.addItem(.separator())
        item("Clear Guides", false, 5)
        menu.items.last?.isEnabled = !guides(for: tab.address).isEmpty
        let page = tab.page
        let web = page
        let zoom = page.pageZoom
        let y = point.y * zoom
        menu.popUp(positioning: nil, at: NSPoint(x: point.x * zoom, y: web.isFlipped ? y : web.bounds.height - y), in: web)
    }

    @MainActor private final class MenuHand: NSObject {
        static let shared = MenuHand()
        weak var tab: Tab?

        @objc func pick(_ item: NSMenuItem) {
            guard let tab else { return }
            switch item.tag {
            case 1: Measure.columns.toggle()
            case 2: Measure.grid.toggle()
            case 3: Measure.rems = false
            case 4: Measure.rems = true
            case 5: Measure.keep(guides: [], for: tab.address)
            default: return
            }
            tab.pushMeasure()
        }
    }
}

// MARK: - the tab's side

extension Tab {
    /// On or off here, and the page told; `pick`, the right-click's point,
    /// has what is under it picked, on or already on.
    func measure(_ on: Bool, pick: CGPoint? = nil) {
        let on = on && isDev
        guard on != measuring || (on && pick != nil) else { return }
        // WebKit's picker makes way (Inspector.swift).
        if on, webPicking, let inspector = Inspector.ofPage(page) { Inspector.send(inspector, "toggleElementSelection") }
        measuring = on
        if !on { measureModel.reset() }
        pushMeasure(pick: pick)
    }

    /// The page told what it should show now: after a change, a new
    /// document, a zoom.
    func pushMeasure(pick: CGPoint? = nil) {
        let js = Measure.script + "(\(Measure.state(for: self, pick: pick)));"
        page.runInYab(js)
    }

    /// A new document: drawn again on it, or put away if the tab has gone
    /// to a page that isn't local.
    func measureAgain() {
        guard measuring else { return }
        measureModel.reset()
        if isDev { pushMeasure() } else { measuring = false }
    }

    /// What the dock asks of the page: copy, a note, a rule's value, a
    /// trouble picked, an animation scrubbed (the page's act).
    func measureAct(_ asked: [String: Any]) {
        guard measuring, let data = try? JSONSerialization.data(withJSONObject: asked),
              let json = String(data: data, encoding: .utf8) else { return }
        page.runInYab("window.__yabMeasure && window.__yabMeasure.act(\(json))")
    }
}

extension Browser {
    /// ⌥⌘U and the ruler in the band.
    func toggleMeasure() {
        guard let tab = devFront else { return }
        tab.measure(!tab.measuring)
    }
}

// MARK: - the script

extension Measure {
    /// The arithmetic, apart from the page, so it can be tested alone
    /// (MeasureTests): distances between two boxes, snapping, numbers
    /// written out.
    static let math = #"""
    var MeasureMath = (function () {
      function inside(a, b) {
        return b.x <= a.x + 0.5 && b.y <= a.y + 0.5 && b.x + b.w >= a.x + a.w - 0.5 && b.y + b.h >= a.y + a.h - 0.5;
      }
      // The lines between two boxes, each with its length; `dash` for a
      // line that only carries an edge over to where the length is read.
      function distances(a, b) {
        var out = [];
        // Every length, nothing too: an edge touching another is a 0
        // worth seeing, drawn as a mark on the edge (Measure's zeroMark).
        function push(x1, y1, x2, y2, dash) {
          var v = Math.abs(x2 - x1) + Math.abs(y2 - y1);
          out.push({ x1: x1, y1: y1, x2: x2, y2: y2, v: v, dash: !!dash });
        }
        var aIn = inside(a, b), bIn = inside(b, a);
        if (aIn || bIn) {
          var i = aIn ? a : b, o = aIn ? b : a;
          var cx = i.x + i.w / 2, cy = i.y + i.h / 2;
          push(cx, o.y, cx, i.y);
          push(cx, i.y + i.h, cx, o.y + o.h);
          push(o.x, cy, i.x, cy);
          push(i.x + i.w, cy, o.x + o.w, cy);
          return out;
        }
        var vy = null, hx = null;
        if (b.y >= a.y + a.h) vy = [a.y + a.h, b.y]; else if (a.y >= b.y + b.h) vy = [b.y + b.h, a.y];
        if (b.x >= a.x + a.w) hx = [a.x + a.w, b.x]; else if (a.x >= b.x + b.w) hx = [b.x + b.w, a.x];
        if (vy) {
          var ox = Math.max(a.x, b.x), ex = Math.min(a.x + a.w, b.x + b.w);
          var x = ox < ex ? (ox + ex) / 2 : a.x + a.w / 2;
          push(x, vy[0], x, vy[1]);
          if (ox >= ex) {
            var far = b.y >= a.y + a.h ? vy[1] : vy[0];
            var edge = b.x > x ? b.x : b.x + b.w;
            push(x, far, edge, far, true);
          }
        }
        if (hx) {
          var oy = Math.max(a.y, b.y), ey = Math.min(a.y + a.h, b.y + b.h);
          var y = oy < ey ? (oy + ey) / 2 : a.y + a.h / 2;
          push(hx[0], y, hx[1], y);
          if (oy >= ey) {
            var side = b.x >= a.x + a.w ? hx[1] : hx[0];
            var edgeY = b.y > y ? b.y : b.y + b.h;
            push(side, y, side, edgeY, true);
          }
        }
        if (!vy && !hx) {
          // Overlapping, neither inside the other: edge to edge.
          var my = a.y + a.h / 2, mx = a.x + a.w / 2;
          push(a.x, my, b.x, my);
          push(a.x + a.w, my, b.x + b.w, my);
          push(mx, a.y, mx, b.y);
          push(mx, a.y + a.h, mx, b.y + b.h);
        }
        return out;
      }
      // The nearest of `marks` ({at, name}) within `reach`, or the value itself.
      function snap(v, marks, reach) {
        var best = null;
        for (var i = 0; i < marks.length; i++) {
          var d = Math.abs(marks[i].at - v);
          if (d <= reach && (!best || d < best.d)) best = { d: d, at: marks[i].at, name: marks[i].name };
        }
        return best ? { at: best.at, name: best.name } : { at: v, name: null };
      }
      // A length as the page's CSS pixels, to a tenth, or in rems.
      function fmt(px, rem) {
        if (rem) {
          var r = Math.round(px / rem * 1000) / 1000;
          return String(r) + 'rem';
        }
        var p = Math.round(px * 10) / 10;
        return String(Object.is(p, -0) ? 0 : p);
      }
      // A computed color as #rrggbb, #rrggbbaa when it isn't opaque.
      function hex(css) {
        var m = /rgba?\(\s*([\d.]+)[ ,]+([\d.]+)[ ,]+([\d.]+)(?:\s*[,/]\s*([\d.]+%?))?\s*\)/.exec(css || '');
        if (!m) return css || '';
        var h = '#' + [m[1], m[2], m[3]].map(function (n) { return Math.round(+n).toString(16).padStart(2, '0'); }).join('');
        if (m[4] !== undefined) {
          var a = m[4].slice(-1) === '%' ? parseFloat(m[4]) / 100 : +m[4];
          if (a < 1) h += Math.round(a * 255).toString(16).padStart(2, '0');
        }
        return h;
      }
      // Four sides as CSS writes them: one, two, three or four numbers.
      function sides(t, r, b, l, rem) {
        var f = function (v) { return fmt(v, rem); };
        if (t === r && r === b && b === l) return f(t);
        if (t === b && r === l) return f(t) + ' ' + f(r);
        if (r === l) return f(t) + ' ' + f(r) + ' ' + f(b);
        return f(t) + ' ' + f(r) + ' ' + f(b) + ' ' + f(l);
      }
      return { inside: inside, distances: distances, snap: snap, fmt: fmt, hex: hex, sides: sides };
    })();
    """#

    /// A function of the state (`Measure.state`): draws Measure on the page,
    /// changes what it shows, or takes it all out.
    static let script = "(function (init) {\n" + math + body + "\n})"

    private static let body = PageScript.load("measure")
}
