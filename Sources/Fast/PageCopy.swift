import AppKit
import SwiftUI

// The whole page, for whoever it is going to: ⌘A on a page offers three
// ways to take it, and nothing is decided for you.
//
// ⌘A is already what people press before handing a page to an agent, so
// that is where the offer is made: a pill in the corner every notice comes
// to, Copy ⌘C as always, Markdown M for a chat, File for agent F, a file an
// agent reads by its path, which is what is copied. ⌘C still just copies, so the everyday ⌘A ⌘C has
// nothing in its way; M and F are the pill's only while it is up, and go
// back to the page with it. A click, a scroll, another key, or another tab
// puts it away.
//
// The part picked becomes the notice (papers/family-values-motion P1, P4):
// the others fold into it and its words turn over in place, "Markdown"
// into "Markdown copied · 1,240 words", instead of a second surface coming
// up where the first one was.

@MainActor
@Observable final class PageCopy {
    enum Pick: Equatable { case copy, markdown, file }
    enum Stage: Equatable { case offering, done(Pick) }

    private(set) var stage: Stage?
    /// What was taken, kept until the next offer rather than cleared with
    /// the stage: the pill leaves as the one part it had become, instead of
    /// opening back into three on its way out.
    private(set) var picked: Pick?
    /// The selection's words when offered, the page's in Markdown once taken.
    private(set) var words = 0
    /// Private tabs keep nothing on disk, so they are offered no file.
    private(set) var canSave = true
    /// A video with a transcript: what it says is the page, not the page
    /// around it, so Markdown and the file are its transcript.
    private(set) var transcript = false
    /// What was picked while it is still being gathered: a transcript
    /// takes its panel a moment. Nothing else is taken meanwhile.
    private(set) var reading: Pick?
    /// Over this, the file is the better way, and the pill says so with a dot.
    static let long = 8000

    @ObservationIgnored private(set) var tab: UUID?
    @ObservationIgnored private(set) var saved: URL?
    @ObservationIgnored private weak var web: NSView?
    @ObservationIgnored private var hush: DispatchWorkItem?
    @ObservationIgnored private var watch: Any?
    @ObservationIgnored private var hovering = false
    /// Counts offers and dismissals, so an offer still on its way out is
    /// dropped once put away or offered again.
    @ObservationIgnored private var turn = 0

    var offering: Bool { stage == .offering }

    /// The clipboard: a test run's own, so trying this from the bench never
    /// takes what the person at the Mac had copied.
    static var board: NSPasteboard {
        Store.testing ? NSPasteboard(name: NSPasteboard.Name("dev.serafim.fast.test.copy")) : .general
    }

    func offer(tab: UUID, web: NSView, words: Int, canSave: Bool, transcript: Bool) {
        NoticeFeedback.offer.play()
        self.tab = tab
        self.web = web
        saved = nil
        let set = {
            self.words = words
            self.canSave = canSave
            self.transcript = transcript
            self.picked = nil
        }
        if stage != nil {
            // Still up, as the part it became: it opens back into three
            // where it is.
            let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            withAnimation(still ? Motion.quick : Motion.reshape) {
                set()
                stage = .offering
            }
        } else {
            // Put away as the part it last became. The three parts put back
            // first, unanimated, and only then does it come out, whole: in
            // one pass, the coming out took the opening with it, and it
            // arrived folded, unfolding on the way.
            var quiet = Transaction()
            quiet.disablesAnimations = true
            withTransaction(quiet, set)
            turn += 1
            let mine = turn
            DispatchQueue.main.async { [weak self] in
                guard let self, self.turn == mine, self.stage == nil else { return }
                self.stage = .offering
            }
        }
        watchPointer()
        // Left alone, it doesn't hang over the page for good.
        later(8)
    }

    func begin(_ pick: Pick) {
        reading = pick
        hush?.cancel()
    }

    func did(_ pick: Pick, words: Int? = nil, saved: URL? = nil) {
        reading = nil
        guard stage != nil else { return }
        NoticeFeedback.success.play()
        self.saved = saved
        // In a transaction of its own, so the row the pill hangs in moves
        // with it: animated from inside, the pill's width changed at once
        // around parts still folding, and the one on the left was cut off.
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        withAnimation(still ? Motion.quick : Motion.reshape) {
            if let words { self.words = words }
            picked = pick
            stage = .done(pick)
        }
        unwatch()
        later(pick == .file ? 3.6 : 1.8)
    }

    func dismiss() {
        reading = nil
        turn += 1
        hush?.cancel()
        unwatch()
        if stage != nil { stage = nil }
    }

    /// The pointer resting on it keeps it up, to read the words or reach Show.
    func hold(_ on: Bool) {
        hovering = on
        if on { hush?.cancel() } else if stage != nil { later(stage == .done(.file) ? 2 : 1.2) }
    }

    private func later(_ seconds: TimeInterval) {
        hush?.cancel()
        guard !hovering else { return }
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        hush = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// A click or a scroll on the page is the selection being put down, and
    /// the offer with it. The pill's own clicks land outside the page.
    private func watchPointer() {
        unwatch()
        watch = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { [weak self] event in
            guard let self, let web = self.web, event.window === web.window,
                  let hit = web.window?.contentView?.hitTest(event.locationInWindow),
                  hit.isDescendant(of: web)
            else { return event }
            if event.type == .scrollWheel, event.scrollingDeltaY == 0, event.scrollingDeltaX == 0 { return event }
            self.dismiss()
            return event
        }
    }

    private func unwatch() {
        if let watch { NSEvent.removeMonitor(watch) }
        watch = nil
    }

    // MARK: - files

    /// Where pages for agents are written: the caches, so the Mac may clear
    /// them, and a path without spaces, so it pastes into a terminal as is.
    nonisolated static var folder: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        var name = Bundle.main.bundleIdentifier ?? "yab"
        if let world = Store.world { name += "-" + slug(world) }
        return caches.appendingPathComponent(name, isDirectory: true).appendingPathComponent("pages", isDirectory: true)
    }

    /// The same page copied again is the same file, written over: an agent
    /// told about it once finds the newer one where the old one was.
    nonisolated static func file(for url: URL) -> URL {
        var parts = [url.host() ?? "page"]
        parts += url.path().split(separator: "/").map(String.init)
        var name = slug(parts.joined(separator: "-"))
        if name.count > 80 { name = String(name.prefix(80)).trimmingCharacters(in: CharacterSet(charactersIn: "-")) }
        if let query = url.query(), !query.isEmpty {
            // A hash that is the same from one launch to the next, which
            // Swift's own isn't: two videos, two files, and each one kept.
            var hash: UInt32 = 2166136261
            for byte in query.utf8 { hash = (hash ^ UInt32(byte)) &* 16777619 }
            name += "-" + String(hash, radix: 36)
        }
        return folder.appendingPathComponent((name.isEmpty ? "page" : name) + ".md")
    }

    nonisolated static func slug(_ text: String) -> String {
        let lower = text.lowercased().replacingOccurrences(of: "www.", with: "")
        var out = ""
        var dash = false
        for scalar in lower.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar), scalar.isASCII {
                out.unicodeScalars.append(scalar)
                dash = false
            } else if !dash, !out.isEmpty {
                out.append("-")
                dash = true
            }
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// A week is long enough for any task that was handed one.
    nonisolated static func tidy() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let old = Date().addingTimeInterval(-7 * 24 * 3600)
        for file in files {
            let when = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let when, when < old { try? fm.removeItem(at: file) }
        }
    }

    // MARK: - the page's side

    /// Whether ⌘A selected the page itself, not a field in it, and how many
    /// words it took: none for a field, an editor, a frame, or a page with
    /// next to nothing on it. And whether it is a video with a transcript.
    static let probe = #"""
    (() => {
      const a = document.activeElement;
      if (a && a !== document.body && a !== document.documentElement &&
          (a.isContentEditable || /^(INPUT|TEXTAREA|SELECT|IFRAME|FRAME)$/.test(a.tagName))) return { words: 0 };
      const s = window.getSelection();
      if (!s || s.isCollapsed || !s.rangeCount) return { words: 0 };
      const video = /(^|\.)youtube\.com$/.test(location.hostname) && location.pathname === '/watch';
      const transcript = video && !!document.querySelector(
        'ytd-video-description-transcript-section-renderer button, ' +
        'ytd-engagement-panel-section-list-renderer[target-id*="transcript"]');
      return { words: (s.toString().match(/\S+/g) || []).length, transcript };
    })()
    """#

    /// A YouTube video's transcript, read from its own Transcript panel,
    /// opened for the moment if it wasn't open, and closed again. The panel
    /// because the captions' own address wants a token only the player can
    /// make, and YouTube's get_transcript refuses a request that isn't the
    /// panel's; what the panel shows it has already been given. Only the
    /// page is read, its title, channel and length from what it shows: this
    /// runs beside the page, where the player's functions can't be seen.
    /// The lines are gathered into paragraphs of about half a minute, each
    /// with the time it starts at, and a chapter's name as a heading.
    static let transcript = #"""
    const PANEL = 'ytd-engagement-panel-section-list-renderer[target-id*="transcript"]';
    const SEGMENT = 'transcript-segment-view-model, ytd-transcript-segment-renderer';
    const sleep = ms => new Promise(r => setTimeout(r, ms));
    // YouTube keeps more than one transcript panel, an older and a newer
    // kind, and only one of them is filled: the open one with lines, or
    // failing that any with lines.
    const open = p => p.getAttribute('visibility') === 'ENGAGEMENT_PANEL_VISIBILITY_EXPANDED';
    const filled = () => {
      const all = [...document.querySelectorAll(PANEL)].filter(p => p.querySelector(SEGMENT));
      return all.find(open) || all[0] || null;
    };
    const before = filled();
    const wasOpen = !!before && open(before);
    if (!wasOpen) {
      const button = document.querySelector('ytd-video-description-transcript-section-renderer button');
      if (!button) return null;
      button.click();
    }
    let root = null, last = -1, still = 0;
    for (let i = 0; i < 80; i++) {
      await sleep(100);
      root = filled();
      const n = root && open(root) ? root.querySelectorAll(SEGMENT).length : 0;
      if (n && n === last) { if (++still >= 3) break; } else still = 0;
      last = n;
    }
    if (!root) return null;

    const seconds = t => t.split(':').reduce((a, b) => a * 60 + (parseInt(b, 10) || 0), 0);
    const lines = [];
    const items = root.querySelectorAll('macro-markers-panel-item-view-model, ' + SEGMENT + ', ytd-transcript-section-header-renderer');
    const seen = new Set();
    for (const item of items) {
      const seg = item.matches(SEGMENT) ? item : item.querySelector(SEGMENT);
      if (seg) {
        if (seen.has(seg)) continue;
        seen.add(seg);
        const stamp = seg.querySelector('.ytwTranscriptSegmentViewModelTimestamp, .segment-timestamp');
        const body = seg.querySelector('span[role="text"], .segment-text, yt-formatted-string');
        const at = (stamp && stamp.textContent || '').trim();
        const text = (body && body.textContent || '').replace(/\s+/g, ' ').trim();
        if (text) lines.push({ at, t: seconds(at), text });
      } else if (!item.querySelector(SEGMENT)) {
        const name = (item.innerText || '').split('\n')[0].trim();
        if (name && !/^\d+(:\d\d)+$/.test(name)) lines.push({ chapter: name });
      }
    }
    if (!wasOpen) {
      const close = root.querySelector('#visibility-button button, button[aria-label="Close"]');
      if (close) close.click();
    }
    if (!lines.some(l => l.text)) return null;

    const out = [];
    let para = null;
    const flush = () => { if (para) out.push('[' + para.at + '] ' + para.words.join(' ')); para = null; };
    for (const l of lines) {
      if (l.chapter) { flush(); out.push('## ' + l.chapter); continue; }
      if (para && (l.t - para.t >= 30 || /[.!?]$/.test(para.words[para.words.length - 1]) && l.t - para.t >= 20)) flush();
      if (!para) para = { at: l.at, t: l.t, words: [] };
      para.words.push(l.text);
    }
    flush();

    const title = (document.querySelector('ytd-watch-metadata h1')?.innerText || document.title.replace(/ - YouTube$/, '')).trim();
    const channel = (document.querySelector('ytd-watch-metadata ytd-channel-name a')?.innerText || '').trim();
    // The player's clock, unless an ad is playing, when it is the ad's:
    // then the length the page declares, PT59M48S.
    const iso = (document.querySelector('meta[itemprop="duration"]')?.content || '').match(/PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?/);
    const declared = iso ? (() => {
      const h = +(iso[1] || 0), m = +(iso[2] || 0), sec = +(iso[3] || 0);
      const two = n => String(n).padStart(2, '0');
      return h ? h + ':' + two(m) + ':' + two(sec) : m + ':' + two(sec);
    })() : '';
    const ad = !!document.querySelector('.ad-showing');
    const length = ad ? declared : ((document.querySelector('.ytp-time-duration')?.textContent || '').trim() || declared);
    const id = new URLSearchParams(location.search).get('v');
    const url = id ? 'https://www.youtube.com/watch?v=' + id : location.href;
    const about = [channel, length, url].filter(Boolean).join(' · ');
    const markdown = '# ' + title + '\n\n' + about + '\n\n' + out.join('\n\n');
    return { title, url, markdown, words: (out.join(' ').match(/\S+/g) || []).length };
    """#

    /// The page as Markdown: the main part of it, where the page says which
    /// that is, or the whole body less what is arranged around it, nav,
    /// footers, sidebars, anything hidden. Headings, lists, code with its
    /// language, tables and links come through; the page is only read.
    static let markdown = #"""
    (() => {
      const SKIP = new Set(['SCRIPT','STYLE','NOSCRIPT','TEMPLATE','SVG','CANVAS','IFRAME','OBJECT','EMBED',
        'NAV','FOOTER','ASIDE','BUTTON','INPUT','SELECT','TEXTAREA','OPTION','DIALOG','MENU','VIDEO','AUDIO',
        'MAP','HEAD','LINK','META']);
      const ROLES = /^(navigation|banner|contentinfo|complementary|search|menu|menubar|toolbar|dialog|alertdialog|tooltip)$/;
      // What sites mark as not for print or not for the eye: edit links,
      // notices about the page, skip links, cookie bars.
      const CHROME = /(^|[\s_-])(noprint|no-print|print-hide|mw-editsection|ambox|navbox|metadata|sr-only|visually-hidden|screen-reader-text|skip-link|cookie|consent)([\s_-]|$)/i;
      const BLOCK = new Set(['P','DIV','SECTION','ARTICLE','MAIN','HEADER','FIGURE','FIGCAPTION','DETAILS',
        'SUMMARY','ADDRESS','DL','DT','DD','FORM','FIELDSET','CENTER','HGROUP']);
      const body = document.body;
      if (!body) return null;

      const total = (body.innerText || '').length || 1;
      let root = body, most = 0;
      for (const c of document.querySelectorAll('main, [role="main"], article')) {
        const n = (c.innerText || '').length;
        if (n > most) { most = n; root = c; }
      }
      if (most < total * 0.35) root = body;
      const whole = root === body;

      const codes = [];
      const hidden = el => {
        if (el.hidden || el.getAttribute('aria-hidden') === 'true') return true;
        if (el.checkVisibility) return !el.checkVisibility({ visibilityProperty: true });
        const cs = getComputedStyle(el);
        return cs.display === 'none' || cs.visibility === 'hidden';
      };
      const abs = u => {
        try { const x = new URL(u, location.href); return /^https?:$/.test(x.protocol) ? x.href : null; }
        catch (e) { return null; }
      };
      const squash = s => s.replace(/[ \t\r\n\f]+/g, ' ');
      const wrap = (s, m) => {
        const t = s.trim();
        if (!t) return s;
        return s.match(/^\s*/)[0] + m + t + m + s.match(/\s*$/)[0];
      };
      const lang = el => {
        for (const e of [el, el.querySelector('code')]) {
          if (!e) continue;
          const m = String(e.className || '').match(/(?:language|lang)-([\w+#-]+)/);
          if (m) return m[1];
        }
        return '';
      };
      const inline = el => { let s = ''; for (const c of el.childNodes) s += walk(c, 0); return s; };
      const cell = el => squash(inline(el)).trim().replace(/\|/g, '\\|');

      function table(el) {
        const rows = [...el.querySelectorAll('tr')].filter(r => r.closest('table') === el && !hidden(r));
        const grid = rows.map(r => [...r.children].filter(c => /^(TD|TH)$/.test(c.tagName)).map(cell));
        const w = Math.max(0, ...grid.map(r => r.length));
        if (!w) return '';
        const line = r => '| ' + Array.from({ length: w }, (_, i) => r[i] || '').join(' | ') + ' |';
        return '\n\n' + [line(grid[0]), '|' + ' --- |'.repeat(w), ...grid.slice(1).map(line)].join('\n') + '\n\n';
      }

      function list(el, depth) {
        const ordered = el.tagName === 'OL';
        let n = parseInt(el.getAttribute('start') || '1', 10) || 1;
        const pad = '  '.repeat(depth);
        let out = '';
        for (const li of el.children) {
          if (li.tagName !== 'LI' || hidden(li)) continue;
          let text = '', nested = '';
          for (const c of li.childNodes) {
            if (c.nodeType === 1 && (c.tagName === 'UL' || c.tagName === 'OL')) nested += list(c, depth + 1);
            else text += walk(c, depth + 1);
          }
          text = text.replace(/\n{2,}/g, '\n').trim().replace(/\n/g, '\n' + pad + '  ');
          if (!text && !nested) continue;
          out += pad + (ordered ? (n++) + '. ' : '- ') + text + '\n' + nested;
        }
        return depth ? out : '\n\n' + out + '\n';
      }

      function walk(node, depth) {
        if (node.nodeType === 3) return squash(node.nodeValue);
        if (node.nodeType !== 1) return '';
        const el = node, tag = el.tagName;
        if (SKIP.has(tag)) return '';
        if (tag === 'HEADER' && whole && !el.closest('article')) return '';
        const role = el.getAttribute('role');
        if (role && ROLES.test(role)) return '';
        const cls = typeof el.className === 'string' ? el.className : '';
        if (cls && CHROME.test(cls)) return '';
        if (hidden(el)) return '';
        switch (tag) {
          case 'BR': return '\n';
          case 'HR': return '\n\n---\n\n';
          case 'H1': case 'H2': case 'H3': case 'H4': case 'H5': case 'H6': {
            const t = squash(inline(el)).trim();
            return t ? '\n\n' + '#'.repeat(+tag[1]) + ' ' + t + '\n\n' : '';
          }
          case 'PRE': {
            const t = (el.innerText || el.textContent || '').replace(/\s+$/, '');
            if (!t.trim()) return '';
            codes.push('```' + lang(el) + '\n' + t + '\n```');
            return '\n\n\u0000' + (codes.length - 1) + '\u0000\n\n';
          }
          case 'CODE': case 'KBD': case 'SAMP': {
            const t = el.textContent || '';
            if (!t.trim()) return t;
            const f = t.includes('`') ? '``' : '`';
            return f + t.replace(/\s+/g, ' ') + f;
          }
          case 'STRONG': case 'B': return wrap(inline(el), '**');
          case 'EM': case 'I': return wrap(inline(el), '*');
          case 'S': case 'DEL': case 'STRIKE': return wrap(inline(el), '~~');
          case 'A': {
            const t = inline(el), text = squash(t).trim();
            const href = abs(el.getAttribute('href') || '');
            if (!href || !text || href.split('#')[0] === location.href.split('#')[0]) return t;
            if (text.startsWith('![')) return '[' + text + '](' + href + ')';
            return text === href ? '<' + href + '>' : '[' + text.replace(/[\[\]]/g, '') + '](' + href + ')';
          }
          case 'IMG': {
            const src = abs(el.currentSrc || el.getAttribute('src') || '');
            if (!src || (el.naturalWidth && el.naturalWidth < 48)) return '';
            return '![' + squash(el.getAttribute('alt') || '').trim().replace(/[\[\]]/g, '') + '](' + src + ')';
          }
          case 'UL': case 'OL': return list(el, depth);
          case 'TABLE': return table(el);
          case 'BLOCKQUOTE': {
            const t = inline(el).replace(/\n{3,}/g, '\n\n').trim();
            return t ? '\n\n' + t.split('\n').map(l => '> ' + l.trim()).join('\n') + '\n\n' : '';
          }
          case 'P': return '\n\n' + inline(el).trim() + '\n\n';
          case 'LI': return '\n- ' + inline(el).trim() + '\n';
          case 'TD': case 'TH': return ' ' + inline(el) + ' ';
        }
        if (el.shadowRoot) { let s = ''; for (const c of el.shadowRoot.childNodes) s += walk(c, depth); return s; }
        return BLOCK.has(tag) ? '\n' + inline(el) + '\n' : inline(el);
      }

      let text = walk(root, 0)
        .split('\n')
        .map(l => /^( {2})*(- |\d+\. )/.test(l) ? l.replace(/\s+$/, '') : l.trim())
        .join('\n')
        .replace(/\n{3,}/g, '\n\n')
        .trim()
        .replace(/\u0000(\d+)\u0000/g, (_, i) => codes[+i]);

      const h1 = root.querySelector('h1') || document.querySelector('h1');
      const title = ((h1 && h1.innerText) || document.title || location.host).replace(/\s+/g, ' ').trim();
      if (!text.startsWith('# ')) text = '# ' + title + '\n\n' + text;
      return { title, url: location.href, markdown: text, words: (text.match(/\S+/g) || []).length };
    })()
    """#
}

// MARK: - the browser's side

extension Browser {
    /// After ⌘A has done its selecting: the pill, if what it selected is the
    /// page itself.
    func offerPageCopy() {
        guard let tab = active, !tab.typing, !fieldShowing, let web = tab.builtPage else { return }
        web.run(PageCopy.probe, in: .client) { [weak self, weak tab] result in
            guard let self, let tab, self.activeID == tab.id,
                  let found = (try? result.get()) as? [String: Any],
                  let words = found["words"] as? Int, words >= 20
            else { return }
            let transcript = found["transcript"] as? Bool ?? false
            self.pageCopy.offer(tab: tab.id, web: web, words: words, canSave: !tab.shy, transcript: transcript)
        }
    }

    /// M: the page as Markdown, on the clipboard as plain text, for a chat
    /// or a terminal.
    func copyPageMarkdown() {
        guard pageCopy.offering, pageCopy.reading == nil else { return }
        pageCopy.begin(.markdown)
        readPage { [weak self] page in
            guard let self else { return }
            let board = PageCopy.board
            board.clearContents()
            board.setString(page.markdown, forType: .string)
            self.pageCopy.did(.markdown, words: page.words)
        }
    }

    /// F: the page written to a file, and the file on the clipboard, both
    /// ways: a terminal agent is pasted its path, a chat app the file itself.
    func savePageForAgent() {
        guard pageCopy.canSave, pageCopy.offering, pageCopy.reading == nil else { return }
        pageCopy.begin(.file)
        readPage { [weak self] page in
            guard let self else { return }
            let file = PageCopy.file(for: page.url)
            let stamp = ISO8601DateFormatter().string(from: Date())
            let head = "---\ntitle: \(Self.yaml(page.title))\nurl: \(page.url.absoluteString)\nsaved: \(stamp)\n---\n\n"
            let text = head + page.markdown + "\n"
            // A long page is a few hundred kilobytes: written away from the
            // main thread, so the pill doesn't wait on the disk to fold.
            DispatchQueue.global(qos: .userInitiated).async {
                let wrote: Bool
                do {
                    try FileManager.default.createDirectory(at: PageCopy.folder, withIntermediateDirectories: true)
                    try text.write(to: file, atomically: true, encoding: .utf8)
                    wrote = true
                } catch {
                    wrote = false
                }
                if wrote { PageCopy.tidy() }
                DispatchQueue.main.async {
                    guard wrote else {
                        self.pageCopy.dismiss()
                        self.toaster.pop("Couldn't save the page", mark: "exclamationmark.triangle")
                        return
                    }
                    let board = PageCopy.board
                    board.clearContents()
                    let item = NSPasteboardItem()
                    item.setString(file.absoluteString, forType: .fileURL)
                    item.setString(file.path, forType: .string)
                    board.writeObjects([item])
                    self.pageCopy.did(.file, words: page.words, saved: file)
                }
            }
        }
    }

    func revealSavedPage() {
        guard let file = pageCopy.saved else { return }
        NSWorkspace.shared.activateFileViewerSelecting([file])
        pageCopy.dismiss()
    }

    private struct ReadPage {
        let title: String
        let url: URL
        let markdown: String
        let words: Int
    }

    private func readPage(_ then: @escaping (ReadPage) -> Void) {
        guard let id = pageCopy.tab, let tab = tabs.first(where: { $0.id == id }), let web = tab.builtPage else {
            pageCopy.dismiss()
            return
        }
        let take: (Result<Any?, Error>) -> Void = { [weak self] result in
            guard let self else { return }
            guard let found = (try? result.get()) as? [String: Any],
                  let markdown = found["markdown"] as? String,
                  let url = (found["url"] as? String).flatMap(URL.init(string:)) ?? tab.address
            else {
                self.pageCopy.dismiss()
                return
            }
            then(ReadPage(
                title: found["title"] as? String ?? "",
                url: url,
                markdown: markdown,
                words: (found["words"] as? Int) ?? 0
            ))
        }
        if pageCopy.transcript {
            web.call(PageCopy.transcript, in: .client) { result in
                // No transcript after all: the page, as for any other.
                if case .success(let found) = result, found is [String: Any] {
                    take(result)
                } else {
                    web.run(PageCopy.markdown, in: .client) { take($0) }
                }
            }
        } else {
            web.run(PageCopy.markdown, in: .client) { take($0) }
        }
    }

    private static func yaml(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

// MARK: - the pill

/// Copy ⌘C · Markdown M · File for agent F, in the corner every notice comes to,
/// the notice's own size and ground: 28 high, a tab's corners, the hairline.
/// It comes out from under the page's top edge whole and goes back the way
/// it came, quicker. The part picked stays and says what happened; the
/// others fold into it.
struct CopyPill: View {
    let browser: Browser
    var copier: PageCopy
    /// The tab in front, so a pill for another one is never shown.
    let active: UUID?
    var top: CGFloat

    @Environment(\.accessibilityReduceMotion) private var still
    /// Its ground stays a moment after it is put away, for the way back,
    /// then leaves the tree, as the notice's does: glass kept up above
    /// the edge was composited under every scroll.
    @State private var lit = false

    private static let side: CGFloat = Notice.side
    private static var font: NSFont { Notice.font }
    private static let icon: CGFloat = 15

    private var up: Bool { copier.stage != nil && copier.tab == active }

    private var picked: PageCopy.Pick? { copier.picked }

    var body: some View {
        // Every part stays in the row; the ones not picked are folded to
        // nothing, so the pill's width follows them down frame by frame
        // instead of jumping when they leave the layout. They fade quicker
        // than they fold, gone before the others have closed over them.
        HStack(spacing: 0) {
            ForEach(parts, id: \.self) { part in
                let gone = picked != nil && picked != part
                if part != parts.first {
                    Rectangle()
                        .fill(HUD.rule)
                        .frame(width: 1, height: 12)
                        .animation(Motion.quick) { $0.opacity(picked == nil ? 1 : 0) }
                        .frame(width: picked == nil ? 1 : 0)
                }
                Part(
                    pick: part, picked: picked, words: copier.words, long: copier.words >= PageCopy.long,
                    transcript: copier.transcript, reading: copier.reading,
                    act: { act(part) }, show: { browser.revealSavedPage() }
                )
                .fixedSize()
                .animation(Motion.quick) { $0.opacity(gone ? 0 : 1) }
                .frame(width: gone ? 0 : nil, alignment: .leading)
                .clipped()
                .allowsHitTesting(!gone)
                .accessibilityHidden(gone)
            }
        }
        .frame(height: Self.side)
        .fixedSize()
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        // The corner's colors, the notice's own (Toast.swift).
        .background { if up || lit { HUD.plate(Radius.control) } }
        .noticeFling(.top, token: "\(active?.uuidString ?? "")|\(String(describing: copier.stage))|\(copier.words)") {
            if up { copier.dismiss() }
        }
        .onHover { copier.hold($0) }
        .offset(y: up || still ? 0 : -(top + Self.side + 12))
        .opacity(up || !still ? 1 : 0)
        .animation(up ? (still ? Motion.quick : Motion.arrive) : (still ? Motion.quick : Motion.depart), value: up)
        .allowsHitTesting(up)
        .accessibilityHidden(!up)
        .padding(.top, top)
        .padding([.leading, .trailing, .bottom], 12)
        .clipped()
        .padding([.leading, .trailing, .bottom], -12)
        .onChange(of: active) { _, _ in if copier.stage != nil { copier.dismiss() } }
        .onChange(of: up) { _, now in
            if now { lit = true; return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { if !up { lit = false } }
        }
    }

    /// What is offered: no file for a private tab.
    private var parts: [PageCopy.Pick] {
        copier.canSave ? [.copy, .markdown, .file] : [.copy, .markdown]
    }

    private func act(_ pick: PageCopy.Pick) {
        guard copier.offering else { return }
        switch pick {
        case .copy:
            if let page = browser.active?.builtPage {
                if let web = page.webKit { NSApp.sendAction(#selector(NSText.copy(_:)), to: web, from: nil) }
                else if case .success(let keys) = AgentPage.strokes("Meta+c") { page.sendAgentKeys(keys) }
            }
            copier.did(.copy)
        case .markdown: browser.copyPageMarkdown()
        case .file: browser.savePageForAgent()
        }
    }

    private struct Part: View {
        private var markdownKey = Keymap.shared.slot(.pageCopyMarkdown)
        private var fileKey = Keymap.shared.slot(.pageCopyFile)
        let pick: PageCopy.Pick
        let picked: PageCopy.Pick?
        let words: Int
        let long: Bool
        let transcript: Bool
        let reading: PageCopy.Pick?
        let act: () -> Void
        let show: () -> Void

        @State private var hovering = false
        @Environment(\.accessibilityReduceMotion) private var still

        private var done: Bool { picked == pick }

        /// What it offers, and what it says once taken. Each says plainly
        /// what is now on the clipboard: for an agent, the file's path.
        private var offer: String {
            switch pick {
            case .copy: return "Copy"
            case .markdown: return transcript ? "Transcript" : "Markdown"
            case .file: return "File for agent"
            }
        }

        private var taken: String {
            switch pick {
            case .copy: return "Copied"
            case .markdown: return transcript ? "Transcript copied" : "Markdown copied"
            case .file: return "File path copied"
            }
        }

        private var label: String { done ? taken : offer }

        /// What the two share from the start, "Markdown", "Cop", "File",
        /// which holds still while only the rest turns over, so the words
        /// read as extended rather than replaced (P5). A space it ends on
        /// goes with the rest, where a text keeps it.
        private var stem: String {
            var shared = String(zip(offer, taken).prefix { $0 == $1 }.map(\.0))
            while shared.hasSuffix(" ") { shared.removeLast() }
            return shared
        }
        private var offerRest: String { String(offer.dropFirst(stem.count)) }
        private var takenRest: String { String(taken.dropFirst(stem.count)) }

        private var key: String {
            switch pick {
            case .copy: return "⌘C"
            case .markdown: return markdownKey.keys?.text ?? ""
            case .file: return fileKey.keys?.text ?? ""
            }
        }

        private var symbol: String {
            switch pick {
            case .copy: return "doc.on.doc"
            case .markdown: return transcript ? "captions.bubble" : "markdown"
            case .file: return "doc.text"
            }
        }

        /// What follows the words: how much was taken, or, while a
        /// transcript's panel opens, that it is being read. A page is read
        /// in a few hundredths of a second, too quick to be worth a word.
        private var after: String? {
            if reading == pick, transcript { return " · reading" }
            guard done, pick == .markdown else { return nil }
            return " · " + words.formatted() + (words == 1 ? " word" : " words")
        }

        private static var font: NSFont { Notice.font }
        /// Its key as every key is drawn, on its plate (KeyGlyphs), at the
        /// size of the words beside it, its width laid out once
        /// off screen and kept, as the corner's keys are (KeyCaps).
        private static var keySize: CGFloat { Notice.font.pointSize }
        private static var keyWidths: [String: CGFloat] = [:]
        private static func keyWidth(_ key: String) -> CGFloat {
            let kept = "\(keySize)|\(key)"
            if let known = keyWidths[kept] { return known }
            let made = NSHostingView(rootView: KeyGlyphs(keys: key, size: keySize, tint: nil)).fittingSize.width.rounded(.up)
            keyWidths[kept] = made
            return made
        }

        /// Widths worked out from the words, as the notice's are: every
        /// piece stays in the row from the start and only its width and
        /// opacity change, so all of it moves as one while the row slides
        /// over. A piece put in or taken out appeared at once where it would
        /// end up, while the rest was still on its way there.
        private static func width(_ text: String, _ font: NSFont) -> CGFloat {
            (text as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
        }

        private var offered: Bool { picked == nil }
        private var stemWidth: CGFloat { Self.width(stem, Self.font) }
        private var restWidth: CGFloat { Self.width(done ? takenRest : offerRest, Self.font) }
        private var afterWidth: CGFloat { after.map { Self.width($0, Self.font) } ?? 0 }
        private var dotWidth: CGFloat { pick == .file && long && offered ? 9 : 0 }
        private var keyWidth: CGFloat { offered && !key.isEmpty ? Self.keyWidth(key) + 6 : 0 }

        var body: some View {
            let quickOut = Animation.easeIn(duration: 0.06)
            // A key is a state, not a thing that leaves: gone at once.
            let keyOut = Animation.linear(duration: 0.04)
            HStack(spacing: 5) {
                // Each fade scoped to the opacity alone: an animation laid
                // on a view by value times its move as well, and the mark and
                // the key ran ahead of the words they belong beside.
                ZStack {
                    Symbol(symbol, size: 15 * 0.72, weight: .medium)
                        .animation(.linear(duration: 0.04)) { $0.opacity(done ? 0 : 1) }
                    Symbol("checkmark", size: 15 * 0.72, weight: .medium)
                        .animation(.linear(duration: 0.04)) { $0.opacity(done ? 1 : 0) }
                }
                .foregroundStyle(HUD.muted)
                .frame(width: 15, height: 15)
                // The words, what follows them and the key on one baseline:
                // centered as boxes, the smaller key sat below the words.
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(stem)
                        .fixedSize()
                    // Keep a Text as the layout root: a ZStack reports its
                    // own baseline, which lifted this part above the stem
                    // and the word count. The offered letters still cross
                    // over the taken letters without changing that baseline.
                    Text(takenRest)
                        .fixedSize()
                        .animation(done ? Motion.morph.delay(0.06) : quickOut) {
                            $0.opacity(done ? 1 : 0).offset(y: done || still ? 0 : 4)
                        }
                        // Not clipped: the new words show whole as they fade
                        // in while the row makes room for them.
                        .frame(width: restWidth, alignment: .leading)
                        .overlay(alignment: .leading) {
                            Text(offerRest)
                                .fixedSize()
                                .animation(done ? quickOut : Motion.morph) {
                                    $0.opacity(done ? 0 : 1).offset(y: done && !still ? -4 : 0)
                                }
                        }
                    Text(after ?? "")
                        .foregroundStyle(HUD.muted)
                        .fixedSize()
                        // After the words have grown, as a qualifier is added.
                        .animation(still ? Motion.quick : Motion.morph.delay(0.08)) { $0.opacity(after == nil ? 0 : 1) }
                        .frame(width: afterWidth, alignment: .leading)
                    if pick == .file, long {
                        Circle().fill(Color.accentColor).frame(width: 4, height: 4)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 3 }
                            .padding(.leading, 5)
                            .animation(offered ? Motion.morph : keyOut) { $0.opacity(offered ? 1 : 0) }
                            .frame(width: dotWidth, alignment: .leading)
                            .clipped()
                            .keyTip("A long page: agents read a file better than a paste")
                    }
                    if !key.isEmpty {
                        // A key 6 after its words, as on every button.
                        KeyGlyphs(keys: key, size: Self.keySize, tint: HUD.muted)
                            .padding(.leading, 6)
                            .animation(offered ? Motion.morph : keyOut) { $0.opacity(offered ? 1 : 0) }
                            .frame(width: keyWidth, alignment: .leading)
                            .clipped()
                    }
                }
                .font(Font(Self.font))
                .foregroundStyle(HUD.ink)
                // Its width said outright, the pieces' added up, and the words
                // kept to its left: left to find its own, the row took its new
                // width at once inside a frame still on its way there, and
                // centered the words in it, over the mark beside them.
                .frame(width: stemWidth + restWidth + afterWidth + dotWidth + keyWidth, alignment: .leading)
            }
            .frame(width: 15 + 5 + stemWidth + restWidth + afterWidth + dotWidth + keyWidth, alignment: .leading)
            .padding(.leading, 8)
            .padding(.trailing, done && pick == .file ? 0 : 9)
            .frame(height: Notice.side - 6)
            .background(
                RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                    .fill(HUD.ink.opacity(hovering && offered ? 0.06 : 0))
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
            .onTapGesture { if offered { act() } }
            .padding(.horizontal, 3)
            .modifier(ShowButton(pick: pick, visible: done && pick == .file, show: show))
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(offered ? .isButton : [])
            .accessibilityLabel(offered && !key.isEmpty ? "\(label), \(key)" : label + (after ?? ""))
        }
    }

    /// Show, beside "File path copied": the file in the Finder. In the
    /// row from the start for the same reason as the words, folded to
    /// nothing until then.
    private struct ShowButton: ViewModifier {
        let pick: PageCopy.Pick
        let visible: Bool
        let show: () -> Void

        private static var width: CGFloat {
            ToastButton.width(("Show" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: Notice.font.pointSize, weight: .semibold)]).width.rounded(.up))
        }

        func body(content: Content) -> some View {
            HStack(spacing: 0) {
                content
                if pick == .file {
                    Button("Show", action: show)
                        .buttonStyle(ToastButton(font: .system(size: Notice.font.pointSize, weight: .semibold)))
                        .focusable(false)
                        .fixedSize()
                        .animation(visible ? Motion.morph.delay(0.1) : .easeIn(duration: 0.1)) { $0.opacity(visible ? 1 : 0) }
                        .frame(width: visible ? Self.width : 0, alignment: .leading)
                        .clipped()
                        .allowsHitTesting(visible)
                        .accessibilityHidden(!visible)
                }
            }
        }
    }
}
