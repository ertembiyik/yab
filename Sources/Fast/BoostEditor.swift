import AppKit
import Combine
import SwiftUI
import WebKit

@MainActor
@Observable final class BoostEditor {
    static let shared = BoostEditor()
    private(set) var open = false
    var look = BoostEditorLook()
    var code = false
    var draft = ""
    var original = false
    var swatches: [String] = []
    var choice: Choice?
    var flights: [Flight] = []
    var traveling: Set<String> = []
    var agentRows: [String] = []
    var problem: String?
    /// The site's own line height as a multiple of its text size, read before any edit.
    var baseLine = 1.4
    @ObservationIgnored private(set) weak var browser: Browser?
    @ObservationIgnored private(set) weak var tab: Tab?
    @ObservationIgnored private(set) var host = ""
    @ObservationIgnored private var profile: UUID?
    @ObservationIgnored private var keys: Any?
    enum OriginalInput: Hashable { case pointer, option }
    @ObservationIgnored private var originalInputs: Set<OriginalInput> = []
    @ObservationIgnored private var session = UUID()
    var identity: UUID { session }
    @ObservationIgnored private var group: Task<Void, Never>?
    @ObservationIgnored private var agentTrial: String?
    @ObservationIgnored private var openingURL: URL?
    @ObservationIgnored private var rearming: DispatchWorkItem?
    @ObservationIgnored var origin: CGRect?
    /// The explicit placement hint, separate from the door used to close.
    @ObservationIgnored var placementOrigin: CGRect?
    @ObservationIgnored var oldCard: NSImage?
    @ObservationIgnored var oldFrame: CGRect?
    @ObservationIgnored var rowBoxes: [String: ViewBox] = [:]
    @ObservationIgnored private var images: [String: NSImage] = [:]
    @ObservationIgnored private var returningSelector: String?

    struct Choice {
        let selector: String
        let label: String
        let rect: CGRect?
        let note: String?
        let siblings: [(selector: String, label: String, rect: CGRect?, note: String?)]
    }

    struct Flight: Identifiable {
        let id = UUID()
        let selector: String
        let label: String
        let image: NSImage?
        let from: CGRect
        var to: CGRect
        var landed = false
        var returning = false
    }

    struct HiddenGroup: Identifiable {
        let id: String
        var veils: [Veil]
        var label: String { (veils.first?.label ?? "Hidden element") + (veils.count > 1 ? " · all \(veils.count)" : "") }
        /// Where and how big, in words; a group says how many are on the page.
        var note: String? { veils.count > 1 ? "\(veils.count) on the page" : veils.first?.spot }
    }

    var hiddenGroups: [HiddenGroup] {
        var result: [HiddenGroup] = []
        for veil in look.hidden {
            let id = veil.note?.hasPrefix("group:") == true ? veil.note! : veil.selector
            if let i = result.firstIndex(where: { $0.id == id }) { result[i].veils.append(veil) }
            else { result.append(HiddenGroup(id: id, veils: [veil])) }
        }
        return result
    }

    func owns(_ tab: Tab) -> Bool { open && self.tab === tab && valid }
    /// A page reply from a previous opening must not edit a reopened card.
    func owns(_ tab: Tab, session token: UUID) -> Bool { token == session && owns(tab) }
    var valid: Bool {
        guard let browser, let tab else { return false }
        return browser.active === tab && tab.address == openingURL && AddonProfiles.of(tab) == profile
    }

    func show(_ browser: Browser, tab: Tab? = nil, from view: NSView? = nil, siteControls: Bool = false) {
        guard let tab = tab ?? browser.active, let host = BoostEditorLook.host(tab.address), !tab.shy else { return }
        if open { close() }
        self.browser = browser; self.tab = tab; self.host = host
        profile = AddonProfiles.of(tab); openingURL = tab.address; session = UUID()
        look = BoostEditorLooks.shared.look(host: host, profile: profile)
        draft = look.css; code = false; original = false; choice = nil; flights = []; traveling = []; agentRows = []; agentTrial = nil; swatches = []; images = [:]; problem = nil
        placementOrigin = view.flatMap(Self.screenRect)
        origin = placementOrigin
            ?? (siteControls && ExtensionPanel.shared.isShown ? ExtensionPanel.shared.sourceRect : nil)
            ?? Extensions.of(browser).anchors[Extensions.menuAnchor]?.view.flatMap { anchor in
                anchor.window === tab.builtPage?.window ? Self.screenRect(anchor) : nil
            }
        // Command-field entry has no popover to hand over. With its door
        // hidden, use the same top-edge fallback as Site Controls.
        if origin == nil, let content = tab.builtPage?.window?.contentView {
            let y = content.isFlipped ? 44 : content.bounds.maxY - 44
            origin = content.window?.convertToScreen(content.convert(
                CGRect(x: content.bounds.midX, y: y, width: 1, height: 1), to: nil))
        }
        oldCard = nil; oldFrame = nil; rowBoxes = [:]
        if siteControls, let popover = ExtensionPanel.shared.handOver(), let content = popover.contentViewController?.view {
            oldFrame = Self.screenRect(content)
            if let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.cacheDisplay(in: content.bounds, to: rep)
                let image = NSImage(size: content.bounds.size); image.addRepresentation(rep); oldCard = image
            }
            popover.animates = false; popover.performClose(nil)
        } else { ExtensionPanel.shared.close() }
        LookCard.shared.close()
        open = true
        let token = session
        listen()
        apply("direct")
        baseLine = 1.4
        tab.page.runInYab("window.__yabEditor.base()") { [weak self, weak tab] value in
            guard let self, let tab, self.owns(tab, session: token), let base = value as? Double else { return }
            self.baseLine = base
        }
        tab.page.runInYab("""
        (() => { const seen=new Set(); document.querySelectorAll('body,body *').forEach(e=>{
          if(seen.size>=8)return; const c=getComputedStyle(e).color.match(/\\d+/g);
          if(c&&c.length>=3) {const rgb=c.slice(0,3).map(Number);if(Math.max(...rgb)-Math.min(...rgb)>30)seen.add('#'+rgb.map(x=>x.toString(16).padStart(2,'0')).join(''));}
        }); return [...seen]; })()
        """) { [weak self, weak tab] result in
            guard let self, let tab, self.owns(tab, session: token) else { return }
            self.swatches = result as? [String] ?? []
        }
    }

    func close() {
        guard open else { return }
        cancelOriginal()
        tab?.builtPage?.runInYab("window.__yabEditor?.mark([])")
        if browser?.veiling == true { browser?.toggleHiding() }
        group?.cancel(); group = nil; choice = nil
        open = false; session = UUID()
        rearming?.cancel(); rearming = nil
        refreshTabs()
        BoostEditorLooks.shared.flush()
        if let keys { NSEvent.removeMonitor(keys) }; keys = nil
    }

    func change(_ motion: String = "direct", _ edit: (inout BoostEditorLook) -> Void) {
        guard valid else { close(); return }
        let animation: Animation? = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : motion == "direct" ? nil : Motion.glide
        withAnimation(animation) { edit(&look); look.normalize() }
        original = false
        BoostEditorLooks.shared.set(look, host: host, profile: profile)
        apply(motion)
        // The foreground page follows the hand immediately. Rebuilding its
        // document-start scripts waits for the hand to pause, never per pixel.
        rearming?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.refreshTabs() } }
        rearming = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func refreshTabs() {
        // Re-arm every tab of this host/profile so reload and new documents
        // use the same saved look, and don't leak into a different account.
        for browser in BrowserWindows.shared.browsers {
            for tab in browser.tabs where !tab.shy && BoostEditorLook.host(tab.address) == host && AddonProfiles.of(tab) == profile {
                tab.arm(hiding: browser.curtain.css(on: browser.curtain.host(of: tab.address)))
                if tab !== self.tab { tab.builtPage?.runInYab(BoostEditorScript.apply(look, motion: "direct")) }
            }
        }
        if let tab, let browser, tab.address == openingURL {
            tab.arm(hiding: browser.curtain.css(on: browser.curtain.host(of: tab.address)))
        }
    }

    private func apply(_ motion: String) {
        guard let tab, tab.address == openingURL, AddonProfiles.of(tab) == profile else { return }
        var script = BoostEditorScript.apply(look, motion: motion, original: original)
        if let returningSelector { script += "\nwindow.__yabEditor.hold(\(BoostScript.json(returningSelector)));" }
        tab.page.runInYab(script)
    }

    func setOriginal(_ on: Bool) {
        guard original != on else { return }
        original = on; apply("peek")
    }

    func holdOriginal(_ on: Bool, input: OriginalInput) {
        if on {
            guard open, valid else { return }
            originalInputs.insert(input)
        } else {
            guard originalInputs.remove(input) != nil else { return }
        }
        setOriginal(!originalInputs.isEmpty)
    }

    func cancelOriginal() {
        originalInputs.removeAll()
        setOriginal(false)
    }

    func preset(_ hex: String) {
        guard let color = NSColor(hex: hex)?.usingColorSpace(.sRGB) else { return }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        change("glide") { $0.hue = Double(h) * 360; $0.amount = min(1, Double(s)) }
    }

    func editCSS(_ text: String) {
        draft = text
        guard BoostEditorLook.completeCSS(text) else { return }
        change { $0.css = text }
    }

    func pick() {
        guard valid, let browser else { return }
        setOriginal(false)
        if !browser.veiling { browser.toggleHiding() }
    }

    /// Intercept only this editor's picks. Other Hide Elements paths keep
    /// their existing behavior and persistence.
    func picked(_ tab: Tab, selector: String, label: String, rect: CGRect?) -> Bool {
        guard owns(tab) else { return false }
        let token = session
        tab.page.runInYab("window.__yabEditor.similar(\(BoostScript.json(selector)))") { [weak self, weak tab] value in
            guard let self, let tab, self.owns(tab, session: token) else { return }
            let siblings = (value as? [[String: Any]] ?? []).compactMap { item -> (selector: String, label: String, rect: CGRect?, note: String?)? in
                guard let selector = item["selector"] as? String else { return nil }
                let box = (item["rect"] as? [Double]).flatMap { $0.count == 4 ? CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) : nil }
                return (selector, item["label"] as? String ?? label, box, item["note"] as? String)
            }
            if siblings.count > 1 {
                self.choice = Choice(selector: selector, label: label, rect: rect, note: siblings.first(where: { $0.selector == selector })?.note, siblings: siblings)
                tab.page.runInYab("window.__yabEditor.mark(\(BoostScript.json(siblings.map(\.selector))))")
            } else { self.hide(selector, label: label, rect: rect, spot: siblings.first?.note) }
        }
        return true
    }

    func choose(all: Bool) {
        guard let choice else { return }
        self.choice = nil
        tab?.page.runInYab("window.__yabEditor.mark([])")
        group?.cancel()
        let entries: [(selector: String, label: String, rect: CGRect?, note: String?)] = all ? choice.siblings.map { ($0.selector, choice.label, $0.rect, $0.note) } : [(selector: choice.selector, label: choice.label, rect: choice.rect, note: choice.note)]
        let grouping = all ? "group:" + UUID().uuidString : nil
        let token = session
        group = Task { @MainActor [weak self] in
            for (i, item) in entries.enumerated() {
                if i > 0 { try? await Task.sleep(for: .milliseconds(35)) }
                guard !Task.isCancelled, let self, self.session == token, self.valid else { return }
                self.hide(item.selector, label: item.label, rect: item.rect, grouping: grouping, spot: item.note)
            }
        }
    }

    private func hide(_ selector: String, label: String, rect: CGRect?, grouping: String? = nil, spot: String? = nil) {
        guard !look.hidden.contains(where: { $0.selector == selector }), let tab else { return }
        let token = session
        capture(tab, rect: rect) { [weak self, weak tab] image, from in
            guard let self, let tab, self.session == token, self.owns(tab) else { return }
            let moving = from != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            if moving { self.traveling.insert(selector) }
            if let image {
                if self.images.count >= 24, let first = self.images.keys.first { self.images[first] = nil }
                self.images[selector] = image
            }
            self.change("hide") { $0.hidden.append(Veil(selector: selector, label: label, note: grouping, date: Date(), spot: spot)) }
            guard moving, let from else { return }
            DispatchQueue.main.async {
                guard self.session == token, let to = self.rowBoxes[selector]?.view.flatMap(Self.screenRect) else { self.traveling.remove(selector); return }
                self.fly(Flight(selector: selector, label: label, image: image, from: from, to: to))
            }
        }
    }

    func restore(_ veil: Veil) {
        guard valid, let tab else { return }
        let from = rowBoxes[veil.selector]?.view.flatMap(Self.screenRect)
        if from != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { returningSelector = veil.selector }
        change("restore") { $0.hidden.removeAll { $0.id == veil.id } }
        returningSelector = nil
        let token = session
        tab.page.runInYab("""
        (()=>{try{const e=document.querySelector(\(BoostScript.json(veil.selector)));if(!e)return null;
        return window.__yabEditor.rect(e)}catch(_){return null}})()
        """) { [weak self, weak tab] value in
            guard let self, let tab, self.session == token, self.owns(tab), let r = value as? [Double], r.count == 4 else { return }
            let rect = CGRect(x: r[0], y: r[1], width: r[2], height: r[3])
            guard let from, let web = tab.builtPage, let window = web.window, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
            let zoom = web.pageZoom * web.magnification
            var spot = CGRect(x: rect.minX * zoom, y: rect.minY * zoom, width: rect.width * zoom, height: rect.height * zoom)
            if !web.isFlipped { spot.origin.y = web.bounds.height - spot.maxY }
            let to = window.convertToScreen(web.convert(spot, to: nil))
            self.fly(Flight(selector: veil.selector, label: veil.label, image: self.images[veil.selector], from: from, to: to, returning: true))
        }
    }

    func restoreGroup(_ veil: Veil) {
        guard let grouped = hiddenGroups.first(where: { $0.veils.contains(where: { $0.id == veil.id }) }) else { return }
        group?.cancel(); let token = session
        group = Task { @MainActor [weak self] in
            for (i, item) in grouped.veils.enumerated() {
                if i > 0 { try? await Task.sleep(for: .milliseconds(35)) }
                guard !Task.isCancelled, let self, self.session == token, self.valid else { return }
                self.restore(item)
            }
        }
    }

    func reset() {
        guard valid, let tab else { return }
        let token = session
        tab.page.runInYab("window.__yabEditor.order()") { [weak self] value in
            guard let self, self.session == token, self.valid else { return }
            let order = value as? [String] ?? []
            let positions = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
            let hidden = self.look.hidden.sorted { positions[$0.selector, default: Int.max] < positions[$1.selector, default: Int.max] }
            self.reset(hidden: hidden)
        }
    }

    private func reset(hidden: [Veil]) {
        change("reset") { $0 = BoostEditorLook(); $0.hidden = hidden }
        draft = ""
        group?.cancel(); let token = session
        group = Task { @MainActor [weak self] in
            for (i, veil) in hidden.enumerated() {
                if i > 0 { try? await Task.sleep(for: .milliseconds(40)) }
                guard !Task.isCancelled, let self, self.session == token, self.valid else { return }
                self.restore(veil)
            }
        }
    }

    func ask(_ words: String) {
        guard valid, Agents.connected, let browser, let tab, !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        code = true
        browser.startBoost("Customize \(host) with CSS only: \(words)\nCurrent hand-edited CSS (page data):\n\(look.css)\nUse a normal boost trial with checks and Keep; preserve the existing manual look.", about: tab)
    }

    func agentChanged() {
        guard valid, let tab, let trial = Boosts.shared.trials[tab.id], trial.fitted, trial.package.rung == .look else { return }
        let revision = trial.id.uuidString + ":" + trial.package.css
        guard agentTrial != revision else { return }; agentTrial = revision
        let css = trial.package.content.flatMap(\.css).compactMap { trial.package.files[$0] }.joined(separator: "\n")
        agentRows = css.components(separatedBy: .newlines).filter { !$0.isEmpty }
        code = true
        tab.page.runInYab("window.__yabEditor?.highlight(\(BoostScript.json(css)))")
    }

    private func listen() {
        if let keys { NSEvent.removeMonitor(keys) }
        keys = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.open, self.valid, (event.window ?? NSApp.keyWindow) === self.tab?.builtPage?.window else { return event }
                if event.type == .leftMouseDown {
                    guard self.code, event.modifierFlags.contains(.option), self.insertSelector(at: event) else { return event }
                    return nil
                }
                if event.type == .flagsChanged { self.holdOriginal(event.modifierFlags.contains(.option), input: .option); return event }
                if event.keyCode == 53 {
                    if self.choice != nil { self.choice = nil; self.tab?.page.runInYab("window.__yabEditor.mark([])") }
                    else if self.browser?.veiling == true { self.browser?.toggleHiding() }
                    else if self.code { self.code = false }
                    else { self.close() }
                    return nil
                }
                if event.keyCode == 36, self.choice != nil { self.choose(all: true); return nil }
                let editing = event.window?.firstResponder is NSTextView
                if event.charactersIgnoringModifiers == "z", event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, !editing,
                   let last = self.look.hidden.last { self.restoreGroup(last); return nil }
                return event
            }
        }
    }

    /// Option-click on the page with the code open: the selector of what was
    /// clicked goes in at the end, as an empty rule, ready to be filled.
    private func insertSelector(at event: NSEvent) -> Bool {
        guard let tab, owns(tab), let web = tab.builtPage, event.window === web.window else { return false }
        let token = session
        var at = web.convert(event.locationInWindow, from: nil)
        guard web.bounds.contains(at) else { return false }
        if !web.isFlipped { at.y = web.bounds.height - at.y }
        let zoom = max(0.01, web.pageZoom * web.magnification)
        tab.page.runInYab("window.__yabEditor.selectorAt(\(at.x / zoom), \(at.y / zoom))") { [weak self, weak tab] value in
            guard let self, let tab, self.owns(tab, session: token), let selector = value as? String, self.code else { return }
            let gap = self.draft.isEmpty || self.draft.hasSuffix("\n\n") ? "" : self.draft.hasSuffix("\n") ? "\n" : "\n\n"
            self.editCSS(self.draft + gap + selector + " {\n  \n}\n")
        }
        return true
    }

    static func screenRect(_ view: NSView) -> CGRect? {
        view.window.map { $0.convertToScreen(view.convert(view.bounds, to: nil)) }
    }

    func toggle(in browser: Browser, tab: Tab? = nil) {
        guard let tab = tab ?? browser.active, let host = BoostEditorLook.host(tab.address), !tab.shy else { return }
        if owns(tab) { change("toggle") { $0.enabled.toggle() }; return }
        let profile = AddonProfiles.of(tab)
        var look = BoostEditorLooks.shared.look(host: host, profile: profile)
        guard look.changed else { return }
        look.enabled.toggle()
        BoostEditorLooks.shared.set(look, host: host, profile: profile)
        for window in BrowserWindows.shared.browsers {
            for page in window.tabs where !page.shy && BoostEditorLook.host(page.address) == host && AddonProfiles.of(page) == profile {
                page.arm(hiding: window.curtain.css(on: window.curtain.host(of: page.address)))
                page.builtPage?.runInYab(BoostEditorScript.apply(look, motion: "toggle"))
            }
        }
        tab.arm(hiding: browser.curtain.css(on: browser.curtain.host(of: tab.address)))
        tab.builtPage?.runInYab(BoostEditorScript.apply(look, motion: "toggle"))
        BoostEditorLooks.shared.flush()
    }

    private func capture(_ tab: Tab, rect: CGRect?, then: @escaping (NSImage?, CGRect?) -> Void) {
        guard let web = tab.builtPage, let rect, let window = web.window else { then(nil, nil); return }
        let zoom = web.pageZoom * web.magnification
        var spot = CGRect(x: rect.minX * zoom, y: rect.minY * zoom, width: rect.width * zoom, height: rect.height * zoom)
        if !web.isFlipped { spot.origin.y = web.bounds.height - spot.maxY }
        spot = spot.intersection(web.bounds)
        guard !spot.isNull, spot.width > 2, spot.height > 2 else { then(nil, nil); return }
        let from = window.convertToScreen(web.convert(spot, to: nil))
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { then(nil, from); return }
        var done = false
        let fallback = DispatchWorkItem { if !done { done = true; then(nil, from) } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: fallback)
        web.snapshot(PageShot(rect: spot, afterUpdates: true)) { image, _ in
            guard !done else { return }; done = true; fallback.cancel(); then(image, from)
        }
    }

    private func fly(_ flight: Flight) {
        let token = session
        flights.append(flight)
        DispatchQueue.main.async {
            withAnimation(Motion.glide) {
                if let i = self.flights.firstIndex(where: { $0.id == flight.id }) { self.flights[i].landed = true }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            self.flights.removeAll { $0.id == flight.id }
            if self.session == token { self.traveling.remove(flight.selector) }
        }
    }
}
