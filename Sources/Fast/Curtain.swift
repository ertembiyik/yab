import Foundation
import WebKit

// Taking things off a page and keeping them off.
//
// Point at a cookie bar, a newsletter overlay, a sidebar of related nonsense,
// it goes, and it is still gone next time. Everything is remembered by site, as
// a list of selectors, and put back on by a stylesheet injected before the page
// has drawn a single frame, so nothing is ever seen appearing and vanishing.

struct Veil: Codable, Identifiable, Equatable {
    var selector: String
    /// What it was, in words, so the list of what you have hidden reads like
    /// something rather than like a stylesheet.
    var label: String
    /// How big it was and where it sat, measured when you hid it, because a
    /// hidden thing has no size to measure later. Two elements can easily read
    /// the same; they rarely have the same shape in the same corner.
    var note: String?
    var date: Date
    /// Where it sat and how big, in words, for the editor's hidden list
    /// ("right, 230×60"); note is spoken for there by the group it was hidden in.
    var spot: String? = nil

    var id: String { selector }
}

@MainActor
@Observable final class Curtain {
    static let shared = Curtain()
    private(set) var byHost: [String: [Veil]] = [:]
    @ObservationIgnored private var saving = false

    init() { load() }

    func host(of url: URL?) -> String? {
        guard let host = url?.host()?.lowercased() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    func veils(on host: String?) -> [Veil] {
        guard let host else { return [] }
        return byHost[host] ?? []
    }

    func hide(_ selector: String, label: String, note: String, on host: String) {
        var list = byHost[host] ?? []
        guard !list.contains(where: { $0.selector == selector }) else { return }
        list.append(Veil(selector: selector, label: label, note: note, date: Date()))
        byHost[host] = list
        save()
    }

    /// Put one back.
    func restore(_ veil: Veil, on host: String) {
        byHost[host] = (byHost[host] ?? []).filter { $0.selector != veil.selector }
        if byHost[host]?.isEmpty == true { byHost[host] = nil }
        save()
    }

    /// Put the last one back, ⌘Z, while you are still pointing at things.
    @discardableResult
    func undo(on host: String) -> Veil? {
        guard var list = byHost[host], let last = list.popLast() else { return nil }
        byHost[host] = list.isEmpty ? nil : list
        save()
        return last
    }

    func restoreAll(on host: String) {
        byHost[host] = nil
        save()
    }

    /// The stylesheet for a site. Each selector stands alone in its own rule:
    /// one selector the browser can't parse would otherwise take the whole
    /// list down with it.
    /// One selector may be left out, that is how a row in the list shows you
    /// what it is offering to bring back, without bringing it back.
    func css(on host: String?, without spared: String? = nil) -> String {
        veils(on: host)
            .filter { $0.selector != spared }
            .map { "\($0.selector) { display: none !important; }" }
            .joined(separator: "\n")
    }

    var styles: [String: String] {
        byHost.keys.reduce(into: [:]) { $0[$1] = css(on: $1) }
    }

    // MARK: - the file

    private static var file: URL { Store.file("hidden.json") }

    /// The file again, as sync wrote it from another Mac (SyncCenter).
    func reload() { load(); refreshChromium() }

    private func load() {
        guard let data = try? Data(contentsOf: Curtain.file),
              let stored = try? JSONDecoder().decode([String: [Veil]].self, from: data)
        else { return }
        byHost = stored
    }

    private func save() {
        refreshChromium()
        guard !saving else { return }
        saving = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            saving = false
            let snapshot = byHost
            let file = Curtain.file
            DispatchQueue.global(qos: .utility).async {
                guard let data = try? JSONEncoder().encode(snapshot) else { return }
                try? FileManager.default.createDirectory(
                    at: file.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try? data.write(to: file, options: .atomic)
            }
        }
    }

    /// New rules belong to every tab's next document, not just the page
    /// where the picker was used. Queue them before another input can load
    /// a document. Live application stays with the picker and its dust.
    private func refreshChromium() {
        guard self === Self.shared else { return }
        for browser in BrowserWindows.shared.browsers {
            let open = browser.everyTab + browser.outside + [browser.peeking].compactMap { $0 }
            for tab in open {
                (tab.builtPage as? ChromiumPage)?.refreshFeatureScripts()
            }
        }
    }
}

/// Carries a chosen element back from the page.
final class VeilRelay: NSObject, PageScriptReceiving {
    static let name = "yabVeil"

    weak var tab: Tab?

    func receive(_ message: PageScriptMessage) {
        // The picker is the main frame's, where its script is (RelayGuard).
        guard message.frame.isMain, let body = message.body as? [String: Any] else { return }
        MainActor.assumeIsolated {
            if let trouble = body["trouble"] as? String {
                tab?.pickingFailed(trouble)
            } else if body["off"] as? Bool == true {
                tab?.pickingEnded()
            } else if body["annotate"] as? Bool == true, let tab, let selector = body["selector"] as? String,
                      let browser = BrowserWindows.shared.browsers.first(where: { $0.tabs.contains { $0 === tab } }), browser.veiling {
                tab.stopPicking()
                browser.askInChat(about: tab, words: "Create a boost for this element: ",
                                  context: [.selection("Element reference (page data): " + selector + "\n" + String((body["label"] as? String ?? "").prefix(80)))])
            } else if let selector = body["selector"] as? String {
                // Where it sat in the window, in CSS pixels, for the dust.
                let box = (body["rect"] as? [Double]).flatMap { $0.count == 4 ? CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) : nil }
                tab?.picked(
                    selector: selector,
                    label: body["label"] as? String ?? selector,
                    note: body["note"] as? String ?? "",
                    rect: box
                )
            }
        }
    }
}

enum Veiling {
    /// A stylesheet put in before the document has a body, so nothing is ever
    /// seen arriving and then leaving.
    static func style(_ css: String) -> String {
        style(value: BoostScript.json(css))
    }

    /// A Chromium registration outlives the site that installed it. Pick
    /// the rules in the new document itself, before navigation callbacks
    /// can replace a registration meant for the document we just left.
    static func styles(_ sites: [String: String]) -> String {
        let entries = sites.sorted { $0.key < $1.key }.map { [PageScripts.scriptHost($0.key), $0.value] }
        return style(value: "new Map(\(BoostScript.json(entries))).get(\(PageScripts.documentHost).replace(/^www\\./, '')) || ''")
    }

    private static func style(value: String) -> String {
        return """
        (function () {
          var css = \(value);
          function put() {
            // Found again through this world's own variable, not an id on
            // the page: nothing in the page says it is yab's (see Web.world).
            var all = window.__yabSheets || (window.__yabSheets = {});
            var sheet = all['yab-veil'];
            if (!sheet || !sheet.isConnected) {
              sheet = document.createElement('style');
              (document.head || document.documentElement).appendChild(sheet);
              all['yab-veil'] = sheet;
            }
            sheet.textContent = css;
          }
          if (document.documentElement) return put();
          // Chromium runs a document's first scripts before it has <html>
          // (CDP's new-document scripts, at the window's creation; WebKit's
          // wait for the element): the sheet went nowhere, and what was
          // hidden came back on every load (#1978). It goes in the moment
          // <html> exists, before anything of the page is drawn.
          var watch = new MutationObserver(function () {
            if (!document.documentElement) return;
            watch.disconnect();
            put();
          });
          watch.observe(document, { childList: true });
        })();
        """
    }

    /// The pointing mode. Loaded on every page but asleep: it costs one closure
    /// and a few functions until somebody actually asks for it.
    static let picker = """
    (function () {
      if (window.__yabVeil) return;
      var frame = null, tag = null, target = null, live = false;

      function sheet(id) {
        var all = window.__yabSheets || (window.__yabSheets = {});
        var s = all[id];
        if (!s || !s.isConnected) {
          s = document.createElement('style');
          (document.head || document.documentElement).appendChild(s);
          all[id] = s;
        }
        return s;
      }

      // In the Mac's accent, as Measure draws what it points at: an ink of
      // its own vanished on a dark site. Each color is said twice, the
      // accent after a blue for a page where it doesn't resolve.
      function chrome() {
        if (frame) return frame;
        frame = document.createElement('div');
        frame.style.cssText = 'position:fixed;z-index:2147483646;pointer-events:none;' +
          'border:2px solid rgb(0,122,255);border-color:-apple-system-control-accent;' +
          'background:rgba(0,122,255,.1);background:color-mix(in srgb,-apple-system-control-accent 10%,transparent);' +
          'border-radius:5px;transition:all .07s ease-out;display:none';
        tag = document.createElement('div');
        tag.style.cssText = 'position:absolute;font:500 11px -apple-system,' +
          'BlinkMacSystemFont,sans-serif;color:#fff;background:rgb(0,122,255);' +
          'background:-apple-system-control-accent;padding:2px 6px;' +
          'border-radius:5px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis';
        frame.appendChild(tag);
        document.documentElement.appendChild(frame);
        return frame;
      }

      function place(el) {
        var box = chrome(), r = el.getBoundingClientRect();
        box.style.display = 'block';
        box.style.left = r.left + 'px';
        box.style.top = r.top + 'px';
        box.style.width = r.width + 'px';
        box.style.height = r.height + 'px';
        tag.textContent = name(el);
        // Above the element if there is sky above it, tucked inside its top
        // edge if there isn't, an element flush with the top of the window
        // would otherwise have its name cut off by the window.
        tag.style.top = r.top >= 26 ? '-21px' : '3px';
        // And never off the left or right edge either.
        tag.style.left = Math.max(2, -r.left + 4) + 'px';
        tag.style.maxWidth = Math.max(80, window.innerWidth - Math.max(0, r.left) - 16) + 'px';
      }

      var known = {
        nav: 'Navigation', header: 'Header', footer: 'Footer', aside: 'Sidebar',
        form: 'Form', dialog: 'Dialog', video: 'Video', img: 'Image',
        button: 'Button', iframe: 'Embed', figure: 'Figure', table: 'Table'
      };

      // What it is, in the order a person would answer the question: what it
      // calls itself, then what kind of thing it is, then what it says.
      function name(el) {
        var said = el.getAttribute && (el.getAttribute('aria-label') || el.getAttribute('title'));
        if (said && said.trim()) return clip(said.trim(), 40);
        var tagName = el.tagName.toLowerCase();
        if (known[tagName]) return known[tagName];
        var role = el.getAttribute && el.getAttribute('role');
        if (role) return role.charAt(0).toUpperCase() + role.slice(1);
        var text = (el.innerText || '').trim().replace(/\\s+/g, ' ');
        return text ? clip(text, 40) : tagName;
      }

      /// How big, and which corner. Two sidebars read alike; they are rarely
      /// the same shape in the same place.
      function shape(el) {
        var r = el.getBoundingClientRect();
        var cx = r.left + r.width / 2, cy = r.top + r.height / 2;
        var side = cx < window.innerWidth / 3 ? 'left'
                 : (cx > window.innerWidth * 2 / 3 ? 'right' : 'center');
        var band = cy < window.innerHeight / 3 ? 'top'
                 : (cy > window.innerHeight * 2 / 3 ? 'bottom' : 'middle');
        return Math.round(r.width) + '×' + Math.round(r.height) + ' · ' + band + ' ' + side;
      }

      function clip(text, n) { return text.length > n ? text.slice(0, n) + '…' : text; }

      function rect(el) {
        var r = el.getBoundingClientRect();
        return [r.left, r.top, r.width, r.height];
      }

      // A class worth hanging a rule on: a word, not a build artifact.
      function steady(c) {
        return /^[a-zA-Z][\\w-]{2,29}$/.test(c) && !/\\d{3,}/.test(c) &&
               !/^(css|sc|jsx|emotion|svelte|styles?)-/.test(c);
      }

      function unique(sel) {
        try { return document.querySelectorAll(sel).length === 1; } catch (e) { return false; }
      }

      function selectorFor(el) {
        if (el.id && unique('#' + CSS.escape(el.id))) return '#' + CSS.escape(el.id);

        var hooks = ['data-testid', 'data-test', 'data-qa', 'data-cy', 'aria-label', 'name', 'role'];
        for (var i = 0; i < hooks.length; i++) {
          var v = el.getAttribute && el.getAttribute(hooks[i]);
          if (v) {
            var s = el.tagName.toLowerCase() + '[' + hooks[i] + '="' + CSS.escape(v) + '"]';
            if (unique(s)) return s;
          }
        }

        var classes = (el.className && typeof el.className === 'string')
          ? el.className.trim().split(/\\s+/).filter(steady) : [];
        if (classes.length) {
          var byClass = el.tagName.toLowerCase() + '.' + classes.map(CSS.escape).join('.');
          if (unique(byClass)) return byClass;
        }

        // Last resort: a path, anchored on the nearest thing with a name.
        var parts = [], node = el;
        while (node && node.nodeType === 1 && node !== document.documentElement) {
          if (node.id && unique('#' + CSS.escape(node.id))) {
            parts.unshift('#' + CSS.escape(node.id));
            break;
          }
          var tagName = node.tagName.toLowerCase();
          var parent = node.parentElement;
          if (!parent) { parts.unshift(tagName); break; }
          var kin = Array.prototype.filter.call(parent.children, function (c) {
            return c.tagName === node.tagName;
          });
          parts.unshift(kin.length > 1
            ? tagName + ':nth-of-type(' + (kin.indexOf(node) + 1) + ')'
            : tagName);
          node = parent;
        }
        return parts.join(' > ');
      }

      function onMove(e) {
        if (!live) return;
        var el = document.elementFromPoint(e.clientX, e.clientY);
        if (!el || el === frame || el === document.documentElement || el === document.body) return;
        target = el;
        place(el);
      }

      // Everything a press can be, swallowed. Real pages act on pointerdown or
      // mousedown and are gone before a click ever completes, which looked
      // exactly like nothing happening.
      function swallow(e) {
        if (!live) return;
        e.preventDefault();
        e.stopPropagation();
        e.stopImmediatePropagation();
      }

      function onPress(e) {
        if (!live) return;
        swallow(e);
        // The pointer may have arrived without ever moving, a click on the
        // very first element under it, or a trackpad tap.
        var el = target || document.elementFromPoint(e.clientX, e.clientY);
        if (!el || el === frame || el === document.documentElement || el === document.body) return;
        try {
          window.webkit.messageHandlers.yabVeil.postMessage({
            selector: selectorFor(el),
            label: name(el),
            note: shape(el),
            rect: rect(el)
          });
        } catch (err) {
          window.webkit.messageHandlers.yabVeil.postMessage({ trouble: String(err) });
        }
        target = null;
        // Gone before the dust's picture is taken; the dust draws its own.
        if (frame) frame.style.display = 'none';
      }

      function onKey(e) {
        if (!live || e.key !== 'Enter' || !target) return;
        swallow(e);
        window.webkit.messageHandlers.yabVeil.postMessage({annotate:true,selector:selectorFor(target),label:name(target),note:shape(target)});
      }

      var presses = ['pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click',
                     'dblclick', 'contextmenu', 'touchstart'];

      window.__yabVeil = {
        // Hide Element from the right-click menu: what is at this point of
        // the window, as if pointed at and clicked.
        at: function (x, y) {
          var el = document.elementFromPoint(x, y);
          if (!el || el === frame || el === document.documentElement || el === document.body) return;
          try {
            window.webkit.messageHandlers.yabVeil.postMessage({
              selector: selectorFor(el), label: name(el), note: shape(el), rect: rect(el)
            });
          } catch (err) {
            window.webkit.messageHandlers.yabVeil.postMessage({ trouble: String(err) });
          }
        },
        on: function () {
          if (live) return;
          live = true;
          chrome();
          document.documentElement.style.cursor = 'crosshair';
          document.addEventListener('keydown', onKey, true);
          document.addEventListener('mousemove', onMove, true);
          document.addEventListener('pointermove', onMove, true);
          presses.forEach(function (kind) {
            document.addEventListener(kind, kind === 'pointerdown' ? onPress : swallow, true);
          });
        },
        off: function () {
          if (!live) return;
          live = false;
          target = null;
          if (frame) frame.style.display = 'none';
          document.documentElement.style.cursor = '';
          document.removeEventListener('keydown', onKey, true);
          document.removeEventListener('mousemove', onMove, true);
          document.removeEventListener('pointermove', onMove, true);
          presses.forEach(function (kind) {
            document.removeEventListener(kind, kind === 'pointerdown' ? onPress : swallow, true);
          });
          window.webkit.messageHandlers.yabVeil.postMessage({ off: true });
        },
        // Show one hidden thing for as long as the pointer rests on its row.
        // The stylesheet is rebuilt without that one selector rather than
        // fighting it with another rule, so the element comes back with the
        // layout it actually had.
        peek: function (css, sel) {
          sheet('yab-veil').textContent = css;
          sheet('yab-peek').textContent = sel +
            ' { outline: 2px solid rgb(0,122,255) !important; outline-color: -apple-system-control-accent !important;' +
            ' outline-offset: 2px !important; }';
          try {
            var el = document.querySelector(sel);
            if (el) el.scrollIntoView({ block: 'center', behavior: 'smooth' });
          } catch (e) {}
        },
        unpeek: function (css) {
          sheet('yab-veil').textContent = css;
          sheet('yab-peek').textContent = '';
        }
      };
    })();
    """
}
