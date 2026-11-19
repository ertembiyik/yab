import Combine
import SwiftUI
import WebKit

/// Looking for a word on the page. A bar in the top corner, the same white and
/// hairline as everything else that floats, and gone the moment it isn't wanted.
struct FindBar: View {
    @Bindable var finder: Finder
    let close: () -> Void

    static let width: CGFloat = 300
    /// The corner notice's anatomy (Notice, ToastButton): it stands in the
    /// page's corner as the notice does, on the notice's curve, its doors
    /// 3 in and concentric with it.
    static let corner: CGFloat = Notice.corner
    static let inset: CGFloat = ToastButton.inset
    static let button: CGFloat = corner - inset

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .leading) {
                if finder.needle.isEmpty, !InputMethod.composing(focused: focused) {
                    Text("Find on page")
                        .foregroundStyle(Palette.muted)
                }
                TextField("", text: $finder.needle)
                    .textFieldStyle(.plain)
                    .foregroundStyle(Palette.ink)
                    .focused($focused)
                    .onKeyPress(.return, phases: .down) { press in
                        // Words still being composed: Return commits them.
                        guard !InputMethod.composing(),
                              press.modifiers.isDisjoint(with: [.command, .option, .control]) else { return .ignored }
                        finder.step(forward: !press.modifiers.contains(.shift))
                        return .handled
                    }
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)

            if let count {
                Text(count)
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(finder.missed ? Color.red : Palette.muted)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 4)
            }

            Button { finder.step(forward: false) } label: { Symbol("chevron.up", size: 11) }
                .disabled(!finder.steppable)
                .focusable(false)
                .keyTip("Previous", shortcut: "Find Previous")
            Button { finder.step(forward: true) } label: { Symbol("chevron.down", size: 11) }
                .disabled(!finder.steppable)
                .focusable(false)
                .keyTip("Next", shortcut: "Find Next")
            Button(action: close) { Symbol("xmark", size: 11) }
                .focusable(false)
                .keyTip("Close", keys: "esc")
        }
        .buttonStyle(.yab(.quiet, .small, icon: .square, cornerRadius: Self.button))
        .frame(width: Self.width - 2 * Self.inset)
        .barFrame(inset: Self.inset, corner: Self.corner)
        .onAppear { take() }
        .onChange(of: finder.focus) { _, _ in take() }
    }

    /// "3/12", "0/0" in red when the page doesn't hold it, nothing before a
    /// letter is typed. WebKit too old to count says only when it missed.
    private var count: String? {
        guard finder.asked else { return nil }
        if finder.missed { return "0/0" }
        guard finder.total > 0 else { return nil }
        return "\(finder.index + 1)/\(finder.total)\(finder.capped ? "+" : "")"
    }

    /// Into the field, with what is there already picked, so a word typed
    /// replaces it and an Enter looks for it again.
    private func take() {
        focused = true
        DispatchQueue.main.async {
            // Only once the field has the keys: a Select All sent to the
            // page would pick the whole page.
            let window = NSApp.keyWindow ?? NSApp.orderedWindows.first
            (window?.firstResponder as? NSTextView)?.selectAll(nil)
        }
    }
}

/// What one tab is looking for on its page, and where it has got to. Every
/// tab keeps its own: the bar goes when you leave a tab and is there again,
/// with the same words, when you come back.
///
/// The page is searched by a script in yab's own world, which marks every
/// match with a highlight rather than a change to the page, counts them, and
/// keeps counting while the page changes. A PDF, whose words the script
/// can't reach, is searched by WebKit's own find, which counts and marks
/// there itself (WebFind); so is a page in WebKit without
/// highlights.
@MainActor
@Observable final class Finder {
    private(set) var shown = false
    var needle = "" {
        didSet { if needle != oldValue, shown { find(reveal: true) } }
    }
    /// The current match, from 0, and how many there are, up to a thousand.
    private(set) var index = -1
    private(set) var total = 0
    private(set) var capped = false
    /// Looked for, and not on the page.
    private(set) var missed = false
    /// Whether what is in the field has been looked for yet.
    private(set) var asked = false
    /// Bumped to put the keys in the field and pick what is there.
    private(set) var focus = 0

    @ObservationIgnored private weak var tab: Tab?
    private let selectionRequest = FindSelectionRequest()
    /// WebKit's own find, for this page: a PDF, or WebKit that can't mark
    /// matches. Asked again of every page that comes in.
    @ObservationIgnored private var native = false
    @ObservationIgnored private lazy var webFind = WebFind()
    @ObservationIgnored private var loads: AnyCancellable?
    @ObservationIgnored private var looking = false
    @ObservationIgnored private var waiting = false
    @ObservationIgnored private var revealWaiting = false
    /// Steps asked for while a look was under way, on and back netted.
    @ObservationIgnored private var steps = 0
    /// Pictures whose words were asked for while the bar is up.
    @ObservationIgnored private var asking = Set<String>()

    init(tab: Tab) {
        self.tab = tab
    }

    var steppable: Bool { native ? asked && !missed : total > 0 }

    /// Whether WebKit's own find is looking, for a probe.
    var webKitFinds: Bool { native }

    func open() {
        focus += 1
        guard !shown else { return }
        shown = true
        // A new page under the same bar is looked through again once it
        // has come in.
        loads = tab?.changes(\.loading).removeDuplicates().dropFirst().filter { !$0 }.sink { [weak self] _ in
            MainActor.assumeIsolated {
                // A new page has its pictures read again, if they aren't kept,
                // and is asked again whether it is a PDF.
                self?.asking = []
                self?.native = false
                self?.find(reveal: false)
            }
        }
        // Words picked on the page are what you are looking for; if none
        // are, the words looked for last time here, picked, to go again.
        let before = needle
        selectionRequest.request(send: { [weak self] reply in
            self?.run("selection", then: reply)
        }, receive: { [weak self] answer in
            guard let self, self.shown, self.needle == before else { return }
            let picked = (answer?["selection"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            if !picked.isEmpty, picked.count <= 100, !picked.contains(where: \.isNewline), picked != self.needle {
                self.needle = picked
                self.focus += 1
            } else if !self.needle.isEmpty {
                self.find(reveal: true)
            }
        })
    }

    /// The marks go and the current match is left picked, to copy. The
    /// words stay, for the next time.
    func close() {
        guard shown else { return }
        selectionRequest.cancel()
        shown = false
        loads = nil
        waiting = false
        revealWaiting = false
        steps = 0
        if native, let web = tab?.webKitOnly("WebKit find runtime", build: false) { webFind.hide(in: web) }
        if native, let page = tab?.builtPage as? ChromiumPage { page.stopNativeFind() }
        native = false
        run("close")
        asking = []
        index = -1
        total = 0
        capped = false
        missed = false
        asked = false
    }

    func step(forward: Bool) {
        guard shown, !needle.isEmpty else { return }
        if native { return nativeFind(forward: forward) }
        // A look still under way would land over the step: it is taken
        // once the look has answered.
        if looking { steps += forward ? 1 : -1; return }
        guard total > 0 else { return }
        run("step", forward: forward) { [weak self] in self?.take($0) }
    }

    /// Counted again where the page stands, the current match kept and
    /// nothing scrolled: coming back to the tab, a page loaded under the bar.
    func recount() {
        // WebKit's find keeps its own count, and asked again it would move on.
        guard shown, !native else { return }
        find(reveal: false)
    }

    /// What the script says when the page changed under the bar.
    func heard(_ body: [String: Any]) {
        guard shown else { return }
        take(body)
    }

    /// The tab put behind: the page stops being watched until it is back.
    func pause() {
        guard shown else { return }
        run("pause")
    }

    /// One look at a time. Letters typed while the page is still being read
    /// wait, and only the last of them is looked for: a queue of every
    /// letter would keep the page busy long after the typing stopped.
    private func find(reveal: Bool) {
        if native || tab?.webKitOnly("WebKit find runtime", build: false)?.webKitShowsPDF == true {
            native = true
            return nativeFind(forward: true)
        }
        guard !looking else {
            waiting = true
            revealWaiting = revealWaiting || reveal
            return
        }
        looking = true
        let asking = needle
        run(reveal ? "find" : "recount") { [weak self] answer in
            guard let self else { return }
            self.looking = false
            if self.waiting {
                let reveal = self.revealWaiting
                self.waiting = false
                self.revealWaiting = false
                return self.find(reveal: reveal)
            }
            guard self.needle == asking else { return }
            self.take(answer)
            let steps = self.steps
            self.steps = 0
            for _ in 0..<abs(steps) { self.step(forward: steps > 0) }
        }
    }

    private func take(_ answer: [String: Any]?) {
        guard shown, let answer, answer["stale"] == nil else { return }
        if answer["fallback"] as? Bool == true || answer["pdf"] as? Bool == true {
            native = true
            return nativeFind(forward: true)
        }
        let blank = needle.allSatisfy(\.isWhitespace)
        if let want = answer["want"] as? [String], !want.isEmpty { read(want) }
        index = (answer["index"] as? NSNumber)?.intValue ?? -1
        total = (answer["total"] as? NSNumber)?.intValue ?? 0
        capped = answer["capped"] as? Bool ?? false
        missed = !blank && total == 0
        asked = !blank
    }

    /// The words in the page's pictures, read and handed to the script a
    /// few at a time, which counts them with the rest and marks them. A
    /// picture with none, or that couldn't be had, is handed over empty, so
    /// it isn't asked for again.
    private func read(_ sources: [String]) {
        guard let tab else { return }
        let fresh = sources.filter { asking.insert($0).inserted }
        guard !fresh.isEmpty else { return }
        let reader = PictureReader.shared
        Task { [weak self, weak tab] in
            for batch in stride(from: 0, to: fresh.count, by: 6).map({ Array(fresh[$0..<min($0 + 6, fresh.count)]) }) {
                var found: [String: Any] = [:]
                await withTaskGroup(of: (String, PictureWords?).self) { group in
                    for src in batch {
                        group.addTask { @MainActor in
                            guard let tab, let url = URL(string: src) else { return (src, nil) }
                            let words = await reader.marks(url, from: tab) { [weak self] finer in
                                // Vision's accurate reading, when it read something else.
                                guard let self, self.shown, self.asking.contains(src) else { return }
                                self.run("pictures", pictures: [src: finer.script]) { [weak self] in self?.take($0) }
                            }
                            return (src, words)
                        }
                    }
                    for await (src, words) in group { found[src] = words?.script ?? [] }
                }
                guard let self, self.shown else { return }
                self.run("pictures", pictures: found) { [weak self] in self?.take($0) }
            }
        }
    }

    private func nativeFind(forward: Bool) {
        if let page = tab?.builtPage as? ChromiumPage {
            guard !needle.allSatisfy(\.isWhitespace) else {
                page.stopNativeFind()
                index = -1
                total = 0
                capped = false
                missed = false
                asked = false
                return
            }
            let asking = needle
            page.nativeFind(needle, forward: forward) { [weak self] answer in
                guard let self, self.shown, self.native, self.needle == asking, let answer else { return }
                self.total = answer.total
                self.index = answer.index
                self.capped = answer.capped
                self.missed = !asking.allSatisfy(\.isWhitespace) && answer.total == 0
                self.asked = !asking.allSatisfy(\.isWhitespace)
            }
            return
        }
        guard let web = tab?.webKitOnly("WebKit find runtime", build: false) else { return }
        guard !needle.allSatisfy(\.isWhitespace) else {
            webFind.hide(in: web)
            index = -1
            total = 0
            capped = false
            missed = false
            asked = false
            return
        }
        // Counted and marked, the current one shown.
        let asking = needle
        if webFind.find(needle, forward: forward, in: web, answer: { [weak self] total, index, capped in
            guard let self, self.shown, self.native, self.needle == asking else { return }
            self.total = total
            self.capped = capped
            self.index = total == 0 ? -1 : min(max(index, 0), total - 1)
            self.missed = total == 0
            self.asked = true
        }) { return }
        let configuration = WKFindConfiguration()
        configuration.backwards = !forward
        configuration.caseSensitive = false
        configuration.wraps = true
        web.find(needle, configuration: configuration) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, self.shown, self.needle == asking else { return }
                self.missed = !result.matchFound
                self.asked = true
            }
        }
    }

    private func run(_ op: String, forward: Bool = true, pictures: [String: Any] = [:], then: (([String: Any]?) -> Void)? = nil) {
        guard let page = tab?.builtPage else { then?(nil); return }
        page.call(Self.script, arguments: ["op": op, "needle": needle, "forward": forward, "pictures": pictures], in: .yab) { result in
            then?((try? result.get()) as? [String: Any])
        }
    }

    /// Kept on the page's window between calls, in yab's world, so the page
    /// never sees it. Text is folded the way the needle is, case and accents
    /// and runs of white space set aside, and a match never runs from one
    /// block into the next.
    static let script = """
    // A JSON page shown as a tree or text has most of its rows out of the
    // document: its viewer looks in the data itself, opens the boxes on the
    // way to what it found and counts the same way (json-view.js).
    if (op !== 'selection' && window.__yabJSON && window.__yabJSON.finds()) return window.__yabJSON.find(op, needle, forward);
    // A PDF is drawn by WebKit's own viewer, with none of its words in the
    // document: WebKit's find looks in it (WebFind).
    if (op !== 'selection' && (document.contentType === 'application/pdf' ||
        (typeof yabFindChanged === 'function' && document.querySelector('embed[type="application/pdf"]')))) return { pdf: true };
    const S = window.__yabFind || (window.__yabFind = {
      index: null, building: null, dirty: false, epoch: 0, asked: 0, cost: 0,
      hits: [], ends: [], at: -1, last: null, needle: '', capped: false, shown: [0, 0],
      observer: null, timer: 0, sheet: null, told: '', folded: new Map(),
      pics: new Map(), host: null, layer: null, drawn: false
    });
    if (op === 'selection') return { selection: String(window.getSelection() || '') };
    // The words in pictures, read by Yab (PictureReader): each picture's
    // lines, each a list of words with their boxes in it, from 0 to 1.
    for (const src in (pictures || {})) S.pics.set(src, pictures[src]);
    if (op === 'pictures') S.dirty = true;
    const ok = !!(window.CSS && CSS.highlights && window.Highlight && window.StaticRange);
    const ALL = 'yab-find', NOW = 'yab-find-current';
    // Counted up to CAP; marked only SPAN of them at a time, around the current
    // one, so a page with a hundred thousand hits paints what is near.
    const CAP = 100000, SPAN = 1000;
    const INLINE = new Set(['A','ABBR','B','BDI','BDO','BIG','CITE','CODE','DATA','DEL','DFN','EM','FONT','I','INS','KBD','LABEL','MARK','NOBR','Q','S','SAMP','SMALL','SPAN','STRIKE','STRONG','SUB','SUP','TIME','TT','U','VAR']);
    const SKIP = new Set(['SCRIPT','STYLE','NOSCRIPT','TEMPLATE','TEXTAREA','INPUT','SELECT','OPTION','HEAD','TITLE','IFRAME','OBJECT','CANVAS','VIDEO','AUDIO']);
    const WIDE = /[^\\x00-\\x7f]/, SPACES = /[\\t\\n\\r\\f]/g;

    // One character folded to one: case and accents set aside, white space a
    // space. Every string keeps its length, so a place in the folded text is
    // the same place in the page's.
    function fold(c) {
      if (c === '\\u00a0' || c === '\\t' || c === '\\n' || c === '\\r' || c === '\\f') return ' ';
      let f = S.folded.get(c);
      if (f === undefined) {
        f = c.normalize('NFD').replace(/[\\u0300-\\u036f]/g, '').toLowerCase();
        if (f.length !== 1) { f = c.toLowerCase(); if (f.length !== 1) f = c; }
        S.folded.set(c, f);
      }
      return f;
    }
    function flat(d) {
      if (!WIDE.test(d)) return d.toLowerCase().replace(SPACES, ' ');
      let out = '';
      for (let k = 0; k < d.length; k++) out += fold(d[k]);
      return out;
    }
    function pattern(words) {
      const f = flat(words).replace(/ +/g, ' ');
      if (!f.trim()) return null;
      if (!f.includes(' ')) return { plain: f };
      return { re: new RegExp(f.replace(/[.*+?^${}()|[\\]\\\\]/g, '\\\\$&').replace(/ /g, ' +'), 'g') };
    }
    function sheet(root) {
      if (!S.sheet) {
        S.sheet = new CSSStyleSheet();
        S.sheet.replaceSync('::highlight(' + ALL + '){background-color:rgb(255 225 70);color:rgb(0 0 0)}::highlight(' + NOW + '){background-color:rgb(255 150 40);color:rgb(0 0 0)}');
      }
      try { if (!root.adoptedStyleSheets.includes(S.sheet)) root.adoptedStyleSheets = [...root.adoptedStyleSheets, S.sheet]; } catch (e) {}
    }
    // A turn of the page's own work between slices: input, painting, its
    // scripts. Not a timer, which WebKit slows to a second in a tab not seen.
    function breathe() {
      return new Promise(done => { const c = new MessageChannel(); c.port1.onmessage = () => done(); c.port2.postMessage(0); });
    }

    // The page's visible text, folded, in one string, with where each text node
    // starts in it. Built once and kept while the bar is up; a change to the
    // page marks it stale. Walked in slices of a few milliseconds.
    async function build(epoch) {
      if (S.observer) S.observer.disconnect();
      const parts = [], starts = [], nodes = [], rows = [], orders = [], labels = [], seen = new Map(), owners = new Map();
      let length = 0, block = null, count = 0;
      const began = performance.now();
      let slice = began;
      const edge = () => { if (length && parts[parts.length - 1] !== '\\0') { parts.push('\\0'); length++; } };
      const visible = el => {
        let v = seen.get(el);
        if (v === undefined) {
          v = el.checkVisibility ? el.checkVisibility({ visibilityProperty: true }) : el.getClientRects().length > 0;
          seen.set(el, v);
        }
        return v;
      };
      const row = el => {
        const chain = [];
        let found = null;
        while (el) {
          if (owners.has(el)) { found = owners.get(el); break; }
          chain.push(el);
          if (el.matches('[role="row"], tr')) { found = el; break; }
          el = el.parentElement || el.getRootNode().host;
        }
        for (const node of chain) owners.set(node, found);
        return found;
      };
      const filter = { acceptNode: n => {
        if (n.nodeType === 1 && SKIP.has(n.tagName.toUpperCase())) return NodeFilter.FILTER_REJECT;
        // Closed details can retain layout boxes. Only their first summary
        // belongs in the index, even when a range still reports a rectangle.
        const parent = n.parentElement;
        if (parent && parent.tagName === 'DETAILS' && !parent.open &&
            !(n.nodeType === 1 && n.matches('summary:first-of-type'))) return NodeFilter.FILTER_REJECT;
        return NodeFilter.FILTER_ACCEPT;
      } };
      const walker = root => {
        observe(root);
        return document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, filter);
      };
      const stack = document.body ? [walker(document.body)] : [];
      while (stack.length) {
        const n = stack[stack.length - 1].nextNode();
        if (!n) { stack.pop(); edge(); block = null; continue; }
        if ((++count & 255) === 0 && performance.now() - slice > 6) {
          await breathe();
          if (epoch !== S.epoch) return null;
          slice = performance.now();
        }
        if (n.nodeType === 1) {
          if (n.tagName === 'BR') edge();
          // Drive's mounted rows can carry a name only in their labels.
          // Keep those in the same sliced walk, with a box for the match.
          const owner = row(n);
          if (owner && (n.hasAttribute('aria-label') || n.hasAttribute('title')) && visible(n)) {
            for (const name of new Set([n.getAttribute('aria-label'), n.getAttribute('title')])) {
              if (!name || !name.trim()) continue;
              labels.push({ label: n, text: name, owner, order: count });
            }
          }
          // A picture's lines, each a block of its own.
          if (n.tagName === 'IMG') {
            const lines = S.pics.get(n.currentSrc);
            if (lines && lines.length && visible(n)) {
              for (const line of lines) {
                const text = line.map(w => w.t).join(' ');
                edge();
                starts.push(length); nodes.push({ pic: n, line }); rows.push(owner); orders.push(count);
                parts.push(flat(text)); length += text.length;
                edge();
              }
              block = null;
            }
            continue;
          }
          if (n.shadowRoot) { edge(); block = null; sheet(n.shadowRoot); stack.push(walker(n.shadowRoot)); }
          continue;
        }
        const el = n.parentElement || n.parentNode.host, d = n.data;
        if (!el || !d) continue;
        if (!visible(el)) {
          if (getComputedStyle(el).visibility !== 'visible') continue;
          const r = document.createRange(); r.selectNodeContents(n);
          if (!r.getClientRects().length) continue;
        }
        let b = el;
        while (b && INLINE.has(b.tagName)) b = b.parentElement;
        if (b !== block) { edge(); block = b; }
        starts.push(length); nodes.push(n); rows.push(row(el)); orders.push(count);
        const f = flat(d);
        parts.push(f); length += f.length;
      }
      // Attribute words stay separate so they cannot split an inline phrase.
      // Their walk order puts the matches back among the page's text later.
      const labelStart = length;
      for (const label of labels) {
        if ((++count & 255) === 0 && performance.now() - slice > 6) {
          await breathe();
          if (epoch !== S.epoch) return null;
          slice = performance.now();
        }
        edge();
        starts.push(length); nodes.push(label); rows.push(label.owner); orders.push(label.order);
        parts.push(flat(label.text)); length += label.text.length;
        edge();
      }
      S.cost = performance.now() - began;
      return { hay: parts.join(''), starts, nodes, rows, orders, labelStart };
    }
    function ready() {
      if (S.index && !S.dirty) return S.index;
      if (!S.building) {
        const epoch = S.epoch;
        S.dirty = false;
        S.building = build(epoch).then(index => {
          if (epoch === S.epoch) { S.index = index; S.building = null; }
          return index;
        });
      }
      return S.building;
    }

    function locate(pos) {
      const st = S.index.starts;
      let lo = 0, hi = st.length - 1;
      while (lo < hi) { const m = (lo + hi + 1) >> 1; if (st[m] <= pos) lo = m; else hi = m - 1; }
      return [S.index.nodes[lo], pos - st[lo], S.index.rows[lo], S.index.orders[lo]];
    }
    function bounds(i) {
      const [a, x] = locate(S.hits[i]), [z, y] = locate(S.ends[i] - 1);
      return { startContainer: a, startOffset: Math.min(x, a.length), endContainer: z, endOffset: Math.min(y + 1, z.length) };
    }
    function range(i) {
      const b = bounds(i), r = document.createRange();
      r.setStart(b.startContainer, b.startOffset);
      r.setEnd(b.endContainer, b.endOffset);
      return r;
    }
    function keep() {
      if (S.at < 0) return;
      const [node, offset] = locate(S.hits[S.at]);
      S.last = { node, offset };
    }
    // Where the last current match was, in the text as it stands now.
    function anchor() {
      if (!S.last) return -1;
      const i = S.index.nodes.findIndex(n => n === S.last.node ||
        (n.label && n.label === S.last.node.label && n.text === S.last.node.text));
      return i < 0 ? -1 : S.index.starts[i] + S.last.offset;
    }
    function scan(p) {
      const hay = S.index.hay, hits = [], ends = [];
      if (p.plain) {
        const n = p.plain.length;
        for (let i = hay.indexOf(p.plain); i >= 0 && hits.length < CAP; i = hay.indexOf(p.plain, i + n)) { hits.push(i); ends.push(i + n); }
      } else {
        let m;
        while (hits.length < CAP && (m = p.re.exec(hay))) { hits.push(m.index); ends.push(m.index + m[0].length); }
      }
      if (!hits.length || hits[hits.length - 1] < S.index.labelStart) {
        S.hits = hits; S.ends = ends; S.capped = hits.length >= CAP;
        return;
      }
      // A name repeated in the text, title and aria-label is one row match.
      // Ordinary text keeps all of its occurrences and its range highlights.
      const textRows = new Set(), labelRows = new Set(), text = [], labels = [];
      for (const hit of hits) {
        const [node, , owner] = locate(hit);
        if (!node.label && owner) textRows.add(owner);
      }
      for (let i = 0; i < hits.length; i++) {
        const [node, , owner, order] = locate(hits[i]);
        if (node.label) {
          if (textRows.has(owner) || labelRows.has(owner)) continue;
          labelRows.add(owner);
        }
        (node.label ? labels : text).push({ hit: hits[i], end: ends[i], order });
      }
      S.hits = []; S.ends = []; S.capped = hits.length >= CAP;
      let t = 0, l = 0;
      while (t < text.length || l < labels.length) {
        const match = l < labels.length && (t >= text.length || labels[l].order < text[t].order) ? labels[l++] : text[t++];
        S.hits.push(match.hit); S.ends.push(match.end);
      }
    }
    function pick(from) {
      const hits = S.hits, n = hits.length;
      if (!n) return -1;
      let lo = 0, hi = n;
      if (from >= 0) {
        const [, , , order] = locate(from);
        while (lo < hi) {
          const m = (lo + hi) >> 1, [, , , at] = locate(hits[m]);
          if (at < order || (at === order && hits[m] < from)) lo = m + 1; else hi = m;
        }
      } else {
        // The first not above the screen. Matches come in the page's order,
        // which is near enough its order down the screen to halve.
        while (lo < hi) {
          const m = (lo + hi) >> 1;
          let bottom = 1;
          try { const b = pic(m) ? picBox(m) : range(m).getBoundingClientRect(); bottom = b.top + b.height; } catch (e) {}
          if (bottom <= 0) lo = m + 1; else hi = m;
        }
      }
      return lo < n ? lo : 0;
    }
    // Pictures and row labels use the same boxes: highlights can only mark
    // text nodes, not words in a picture or an attribute.
    function pic(i) { const [a] = locate(S.hits[i]); return a && (a.pic || a.label) ? a : null; }
    function picBox(i) {
      const [a, x] = locate(S.hits[i]), [, y] = locate(S.ends[i] - 1);
      if (a.label) return a.label.getBoundingClientRect();
      const r = a.pic.getBoundingClientRect();
      let left = Infinity, top = Infinity, right = -Infinity, bottom = -Infinity, at = 0;
      for (const w of a.line) {
        const from = Math.max(x, at), to = Math.min(y + 1, at + w.t.length);
        if (to > from) {
          const a0 = (from - at) / w.t.length, a1 = (to - at) / w.t.length;
          left = Math.min(left, w.x + w.w * a0); right = Math.max(right, w.x + w.w * a1);
          top = Math.min(top, w.y); bottom = Math.max(bottom, w.y + w.h);
        }
        at += w.t.length + 1;
      }
      if (left === Infinity) return null;
      return { left: r.left + left * r.width - 1, top: r.top + top * r.height - 1, width: (right - left) * r.width + 2, height: (bottom - top) * r.height + 2 };
    }
    function layer() {
      if (!S.host || !S.host.isConnected) {
        S.host = document.createElement('yab-find-pictures');
        S.host.style.cssText = 'all:initial;position:fixed;inset:0;pointer-events:none;z-index:2147483647';
        S.layer = S.host.attachShadow({ mode: 'closed' });
        document.documentElement.appendChild(S.host);
      }
      return S.layer;
    }
    function drawPics() {
      const [from, to] = S.shown, boxes = [];
      for (let i = from; i < to && boxes.length < 300; i++) {
        if (!pic(i)) continue;
        const b = picBox(i);
        if (b && b.top < innerHeight && b.top + b.height > 0) boxes.push([b, i === S.at]);
      }
      if (!boxes.length && !S.host) return;
      layer().innerHTML = boxes.map(([b, now]) => '<div style="position:absolute;left:' + b.left + 'px;top:' + b.top + 'px;width:' + b.width + 'px;height:' + b.height + 'px;border-radius:2px;background:' + (now ? 'rgb(255 150 40 / .6)' : 'rgb(255 225 70 / .5)') + '"></div>').join('');
    }
    function follow() {
      if (S.drawn) return;
      S.drawn = () => { if (!S.frame) S.frame = requestAnimationFrame(() => { S.frame = 0; drawPics(); }); };
      addEventListener('scroll', S.drawn, true);
      addEventListener('resize', S.drawn);
    }
    function unfollow() {
      if (S.drawn) { removeEventListener('scroll', S.drawn, true); removeEventListener('resize', S.drawn); S.drawn = false; }
      if (S.host) { S.host.remove(); S.host = null; S.layer = null; }
    }
    // Pictures on the page whose words haven't been read: those big enough
    // to hold some, nearest the screen first, a few dozen at most.
    function wanted() {
      const out = [];
      for (const img of document.images) {
        const src = img.currentSrc;
        if (!src || S.pics.has(src) || !/^(https?|data|blob):/i.test(src)) continue;
        const r = img.getBoundingClientRect();
        if (r.width < 60 || r.height < 20 || (img.naturalWidth && img.naturalWidth < 80)) continue;
        if (img.checkVisibility && !img.checkVisibility({ visibilityProperty: true })) continue;
        out.push([Math.abs(r.top + r.height / 2 - innerHeight / 2), src]);
      }
      out.sort((a, b) => a[0] - b[0]);
      return [...new Set(out.map(o => o[1]))].slice(0, 30);
    }
    // WebKit (Safari 26's, before its fix of August 2026) repaints nothing
    // when CSS.highlights.set() or .delete() swaps or drops a highlight: the
    // marks of every earlier word stay on the screen, past a word that
    // isn't on the page. Only a highlight's own changes repaint, made or
    // cleared: the old one is cleared first, which paints out where it was,
    // and a new Highlight paints its ranges as it is made.
    function put(name, h) {
      const old = CSS.highlights.get(name);
      if (old && old !== h) old.clear();
      CSS.highlights.delete(name);
      if (h) CSS.highlights.set(name, h);
    }
    function paint() {
      const n = S.hits.length;
      if (!n) { put(ALL); S.shown = [0, 0]; drawPics(); return; }
      const from = Math.max(0, Math.min(S.at - SPAN / 2, n - SPAN)), to = Math.min(n, from + SPAN), all = [];
      for (let i = from; i < to; i++) { if (!pic(i)) { try { all.push(new StaticRange(bounds(i))); } catch (e) {} } }
      put(ALL, new Highlight(...all));
      S.shown = [from, to];
      drawPics();
    }
    function reveal(r) {
      const inside = b => b.top >= 60 && b.bottom <= innerHeight - 16 && b.left >= 0 && b.right <= innerWidth;
      if (inside(r.getBoundingClientRect())) return;
      const el = r.startContainer.parentElement || r.startContainer.getRootNode().host;
      if (el) el.scrollIntoView({ block: 'nearest', inline: 'nearest', behavior: 'instant' });
      const b = r.getBoundingClientRect();
      window.scrollBy({ top: b.top + b.height / 2 - innerHeight / 2, behavior: 'instant' });
    }
    function mark(scroll) {
      const n = S.hits.length;
      if (S.at < 0 || !n) { put(NOW); return; }
      const [from, to] = S.shown;
      if ((from > 0 && S.at < from + 50) || (to < n && S.at >= to - 50)) paint();
      const p = pic(S.at);
      if (p) {
        put(NOW);
        if (scroll) {
          if (p.label) p.label.scrollIntoView({ block: 'nearest', inline: 'nearest', behavior: 'instant' });
          const b = picBox(S.at);
          if (b && (b.top < 60 || b.top + b.height > innerHeight - 16)) window.scrollBy({ top: b.top + b.height / 2 - innerHeight / 2, behavior: 'instant' });
        }
        drawPics();
        return;
      }
      let r;
      try { r = range(S.at); } catch (e) { return; }
      const h = new Highlight(r);
      h.priority = 1;
      put(NOW, h);
      if (scroll) reveal(r);
      if (S.host) drawPics();
    }
    function state() { return { index: S.at, total: S.hits.length, capped: S.capped }; }
    async function search(words, scroll) {
      const epoch = S.epoch, asked = ++S.asked;
      S.needle = words;
      const p = pattern(words);
      if (!p) {
        S.hits = []; S.ends = []; S.at = -1; S.capped = false;
        paint(); mark(false);
        return state();
      }
      await ready();
      if (epoch !== S.epoch || asked !== S.asked || !S.index) return { stale: true };
      const from = anchor();
      scan(p);
      S.at = pick(from);
      keep();
      sheet(document);
      paint();
      mark(scroll);
      if (S.host || S.index.nodes.some(n => n.pic || n.label)) follow();
      S.told = JSON.stringify(state());
      return Object.assign(state(), { want: wanted() });
    }
    function stop() {
      clearTimeout(S.timer); S.timer = 0;
      if (S.observer) { S.observer.disconnect(); S.observer = null; }
    }
    function observe(root) {
      if (S.observer) S.observer.observe(root, { subtree: true, childList: true, characterData: true,
        attributes: true, attributeFilter: ['hidden', 'open'] });
    }
    // The page changing under the bar marks the text stale and, after a wait
    // that grows with what reading it costs, counts again. A page that changes
    // all the time is read at most every twenty times its cost.
    function watch() {
      if (S.observer || !document.body) return;
      S.observer = new MutationObserver(records => {
        if (!records.some(r => r.type === 'attributes' || r.type === 'characterData' || r.addedNodes.length || r.removedNodes.length)) return;
        S.dirty = true;
        if (S.timer) return;
        S.timer = setTimeout(async () => {
          S.timer = 0;
          if (!S.needle || document.hidden) return;
          const told = S.told;
          await search(S.needle, false);
          if (S.told !== told) { try { if (typeof yabFindChanged === 'function') yabFindChanged(JSON.stringify(state())); else webkit.messageHandlers.\(FindRelay.name).postMessage(state()); } catch (e) {} }
        }, Math.max(300, Math.min(5000, S.cost * 20)));
      });
      observe(document.body);
    }

    if (op === 'close') {
      stop();
      S.epoch++;
      let picked = null;
      if (ok && S.index && S.at >= 0) { try { picked = range(S.at); } catch (e) {} }
      if (ok) { put(ALL); put(NOW); }
      unfollow();
      if (picked && !picked.collapsed) { const sel = window.getSelection(); sel.removeAllRanges(); sel.addRange(picked); }
      Object.assign(S, { index: null, building: null, dirty: false, hits: [], ends: [], at: -1, last: null, needle: '', told: '', shown: [0, 0] });
      return {};
    }
    // The tab put behind: it stops watching, and whatever changed meanwhile is
    // read again when it comes back.
    if (op === 'pause') { stop(); if (S.index) S.dirty = true; return {}; }
    if (!ok) return { fallback: true };
    if (op === 'step') {
      const n = S.hits.length;
      if (n && S.index) {
        S.at = ((S.at < 0 ? 0 : S.at + (forward ? 1 : -1)) + n) % n;
        keep();
        mark(true);
        S.told = JSON.stringify(state());
      }
      return state();
    }
    // Words typed in the bar: what was picked on the page, by hand or by
    // the bar's last close, is let go, as the marks are now what is found.
    // Left, it stays lit over a word that isn't on the page. Not in a field
    // being written in, whose caret it would take.
    if (op === 'find') {
      const sel = window.getSelection();
      const at = sel && sel.rangeCount && !sel.isCollapsed ? sel.anchorNode : null;
      const el = at && (at.nodeType === 1 ? at : at.parentElement), writing = 'input, textarea, [contenteditable]:not([contenteditable="false"])';
      const active = document.activeElement;
      if (el && !el.closest(writing) && !(active && active.matches && active.matches(writing))) sel.removeAllRanges();
    }
    watch();
    const answer = await search(needle, op === 'find');
    return answer;
    """
}

/// WebKit's own find, through its private calls: every
/// match marked, the current one lit and counted. It is what reaches a PDF,
/// whose words live in WebKit's viewer and not in the page's document.
/// Without those calls, WKWebView's public find, which only selects.
@MainActor
final class WebFind: NSObject {
    private static let findCall = NSSelectorFromString("_findString:options:maxCount:")
    private static let hideCall = NSSelectorFromString("_hideFindUI")
    private static let delegateCall = NSSelectorFromString("_setFindDelegate:")
    static let available = [findCall, hideCall, delegateCall].allSatisfy { WKWebView.instancesRespond(to: $0) }
    static let most: UInt = 1000

    // _WKFindOptions
    private static let caseInsensitive: UInt = 1 << 0
    private static let backwards: UInt = 1 << 3
    private static let wrapAround: UInt = 1 << 4
    private static let showOverlay: UInt = 1 << 5
    private static let showFindIndicator: UInt = 1 << 6
    private static let showHighlight: UInt = 1 << 7
    private static let determineMatchIndex: UInt = 1 << 9

    private var asked = ""
    private var answer: ((Int, Int, Bool) -> Void)?

    /// Looks for the words, the next match from the current one, and says
    /// how many there are and which is current. False when WebKit hasn't the
    /// calls, for the public find to be used instead.
    func find(_ words: String, forward: Bool, in web: WKWebView, answer: @escaping (_ total: Int, _ index: Int, _ capped: Bool) -> Void) -> Bool {
        guard Self.available else { return false }
        _ = web.perform(Self.delegateCall, with: self)
        asked = words
        self.answer = answer
        // The overlay is what shows every match in a PDF, the page dimmed
        // around them.
        var options = Self.caseInsensitive | Self.wrapAround | Self.showOverlay | Self.showFindIndicator | Self.showHighlight | Self.determineMatchIndex
        if !forward { options |= Self.backwards }
        typealias Find = @convention(c) (AnyObject, Selector, NSString, UInt, UInt) -> Void
        unsafeBitCast(web.method(for: Self.findCall), to: Find.self)(web, Self.findCall, words as NSString, options, Self.most)
        return true
    }

    /// The marks gone; the current match stays picked.
    func hide(in web: WKWebView) {
        answer = nil
        asked = ""
        guard Self.available else { return }
        _ = web.perform(Self.hideCall)
    }

    // _WKFindDelegate

    @objc(_webView:didFindMatches:forString:withMatchIndex:)
    func didFind(_ web: WKWebView, matches: UInt, string: String, index: Int) {
        guard string == asked else { return }
        // More than asked for comes as UInt32.max (kWKMoreThanMaximumMatchCount).
        let capped = matches > Self.most
        answer?(capped ? Int(Self.most) : Int(matches), index, capped)
    }

    @objc(_webView:didFailToFindString:)
    func didFail(_ web: WKWebView, string: String) {
        guard string == asked else { return }
        answer?(0, -1, false)
    }

    @objc(_webView:didCountMatches:forString:)
    func didCount(_ web: WKWebView, matches: UInt, string: String) {}
}

extension WKWebView {
    /// WebKit's viewer showing a PDF as the page.
    var webKitShowsPDF: Bool {
        let call = NSSelectorFromString("_isDisplayingPDF")
        guard responds(to: call) else { return false }
        typealias Get = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(method(for: call), to: Get.self)(self, call)
    }
}

final class FindRelay: NSObject, PageScriptReceiving {
    static let name = "yabFind"

    weak var tab: Tab?

    func receive(_ message: PageScriptMessage) {
        // ⌘F looks in the main frame, and only it answers (RelayGuard).
        guard message.frame.isMain, let body = message.body as? [String: Any] else { return }
        MainActor.assumeIsolated { tab?.finder.heard(body) }
    }
}
