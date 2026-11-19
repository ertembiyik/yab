import AppKit
import Combine
import ScreenCaptureKit
import SwiftUI

// Sharing a screen with a page, yab's way (docs/screen-share.md).
//
// WebKit answers getDisplayMedia only with the system's picker, windows and
// screens and nothing of a browser's own. So the page's getDisplayMedia is
// yab's: the page asks, a card over the tab offers its tabs, and, where
// macOS lets yab see them, other apps' windows and the screens. What is
// picked yab takes itself (ShareFeed) and hands the page a frame at a time,
// decoded into Yab's canvas and handed as a native track. Without the right to
// record the screen, windows and screens go to the system's picker as they
// always did, WebKit's own getDisplayMedia called as the card's answer.

enum ShareScript {
    static let name = "yabShare"
    static let asked = "yab-share-ask"
    /// Where yab reaches the page's side: MediaDevices.prototype[Symbol.for(mark)].
    static let mark = "yab.share"

    /// In the page's own world, before the site's first line, in every
    /// frame: it has to stand in for the page's getDisplayMedia. Nothing of
    /// yab's is in the page's world, so questions go to yab's side as
    /// events (`bridge`), and yab answers and sends frames by calling in
    /// (`call`).
    static let page = PageScript.load("share-page", vars: ["MARK": mark, "ASKED": asked])

    /// Yab decodes into its own canvas and hands its native capture track
    /// through srcObject. No worker track crosses JavaScript worlds.
    /// Only a native permission answer prepares a source.
    static let bridge = PageScript.load("share-bridge", vars: ["NAME": name, "ASKED": asked])

    static func transport(_ body: String) -> String {
        "var api = window[Symbol.for('yab.share.worker')]; if (!api) return false; return \(body);"
    }

    /// What yab runs in the page's world to hand it something: false when
    /// the page's side is gone, the frame navigated or the share ended.
    static func call(_ body: String) -> String {
        "var api = MediaDevices.prototype[Symbol.for('\(mark)')]; if (!api) return false; return \(body);"
    }
}

// MARK: - the picker

extension SharePicker: Equatable {
    nonisolated static func == (a: SharePicker, b: SharePicker) -> Bool { a === b }
}

/// What the box offers, and what is picked in it, one kind at a time as
/// Chrome offers them: Tab, Window and Entire Screen, three doors under the
/// field. The screens are always there: without Screen Recording each is
/// its name, its size and its wallpaper, and goes on to macOS's own picker
/// on the screens. Found by typing, picked with the arrows.
@MainActor
@Observable final class SharePicker {
    enum Kind: String, CaseIterable { case tabs, windows, screens }

    struct Item: Identifiable {
        let id: String
        /// Nil for what goes on to macOS's own picker.
        let source: Share.Source?
        let kind: Kind
        let title: String
        let icon: NSImage?
        let letter: String
        var picture: NSImage?
        /// A screen's size in pixels.
        var detail = ""
    }

    struct Section: Identifiable {
        let kind: Kind
        let items: [Item]
        var id: Kind { kind }
        var title: String {
            switch kind {
            case .tabs: return "Tabs"
            case .windows: return "Windows"
            case .screens: return "Screens"
            }
        }
    }

    /// Columns of a door's grid, for the arrows up and down: the screens
    /// are two to a row, as large as the box lets them be.
    static func columns(_ kind: Kind) -> Int { kind == .screens ? 2 : 4 }

    private(set) var tabs: [Item] = []
    /// The window's other tabs: found by typing, not shown until then.
    @ObservationIgnored private var otherTabs: [Item] = []
    private(set) var windows: [Item] = []
    private(set) var screens: [Item] = []
    var typed = "" { didSet { if !items(door).contains(where: { $0.id == chosenID }) { chosenID = nil } } }
    /// The door open: the kind shown and picked from.
    var door: Kind = .tabs
    /// What is picked behind each door, kept while another is open.
    private var picks: [Kind: String] = [:]
    var chosenID: String? {
        get { picks[door] }
        set { picks[door] = newValue }
    }
    /// macOS lets Yab see other apps' windows and the screens.
    let allowed = CGPreflightScreenCaptureAccess()
    /// Yab takes other apps' windows and the screens itself: Screen
    /// Recording allowed and ScreenCaptureKit answering. Turned on in
    /// System Settings while Yab runs, macOS can say yes to the first and
    /// still refuse the second (request 904); then they go on to macOS's
    /// picker, as without the permission, rather than an empty door.
    private(set) var sees: Bool
    let token: String
    /// The frame that asked; nil for an extension's chooseDesktopMedia,
    /// which a worker can ask with no frame at all (ExtensionCapture).
    let frame: PageFrame?
    let host: String
    let audio: Bool
    /// The largest picture the page asked for, if it named one.
    @ObservationIgnored var most: CGSize?
    /// What may be offered: an extension names its kinds (tab, window,
    /// screen); a page gets them all.
    @ObservationIgnored var kinds: Set<Kind> = [.tabs, .windows, .screens]
    /// Only a page's own getDisplayMedia can go on to macOS's picker.
    @ObservationIgnored var offersSystem = true
    /// The door the page named (displaySurface), over the one remembered.
    @ObservationIgnored var preferred: Kind?
    /// The page's own tab is offered (selfBrowserSurface), and first
    /// (preferCurrentTab).
    @ObservationIgnored var offersCaller = false
    @ObservationIgnored var callerFirst = false

    /// The way to macOS's own picker on the windows, where Yab can't see
    /// other apps' windows.
    static let system = Item(id: "system", source: nil, kind: .windows, title: "Another App's Window", icon: nil, letter: "")

    init(token: String, frame: PageFrame?, host: String, audio: Bool) {
        self.token = token
        self.frame = frame
        self.host = host
        self.audio = audio
        sees = allowed
    }

    /// The doors offered: an extension's kinds, and the screens only where
    /// they can be shown, by Yab or by macOS's picker.
    var doors: [Kind] {
        Kind.allCases.filter { kinds.contains($0) && ($0 != .screens || sees || offersSystem) }
    }

    /// What a page's getDisplayMedia said of what it wants offered.
    func take(_ body: [String: Any]) {
        switch body["surface"] as? String {
        case "browser": preferred = .tabs
        case "window": preferred = .windows
        case "monitor": preferred = .screens
        default: break
        }
        callerFirst = body["current"] as? Bool ?? false
        offersCaller = callerFirst || body["own"] as? String == "include"
        if body["screens"] as? String == "exclude" { kinds.remove(.screens) }
    }

    /// Whether the sound comes with this: a tab's, as Chromium shares it
    /// unless told not to. Never a window's, as Chromium on the Mac. A
    /// screen's stays off: Chromium leaves its "Also share system audio" off
    /// until it is pressed, and this box has no such switch. Asking for it
    /// also puts macOS's System Audio Recording question up, and the page's
    /// getDisplayMedia waits on that answer.
    func hears(_ source: Share.Source) -> Bool {
        if case .tab = source { return audio }
        return false
    }

    /// A door's items, narrowed to what is typed.
    func items(_ kind: Kind) -> [Item] {
        let words = typed.trimmingCharacters(in: .whitespaces).lowercased()
        func kept(_ items: [Item]) -> [Item] {
            words.isEmpty ? items : items.filter { $0.title.lowercased().contains(words) }
        }
        switch kind {
        case .tabs: return kept(words.isEmpty ? tabs : tabs + otherTabs)
        // Yab's own windows need no Screen Recording; the rest are macOS's to show.
        case .windows: return kept(windows) + (!sees && offersSystem ? [Self.system] : [])
        case .screens: return kept(screens)
        }
    }

    /// What shows: the open door's items.
    var sections: [Section] {
        [Section(kind: door, items: items(door))].filter { !$0.items.isEmpty }
    }

    var chosen: Item? {
        let all = items(door)
        return all.first { $0.id == chosenID } ?? all.first
    }

    /// The keys are on the doors' row (Tab, Window, Entire Screen) rather
    /// than the tiles under it.
    var onDoors = false

    /// An arrow: on the doors, left and right open the one beside and down
    /// goes to the tiles; on the tiles, left and right along the order, up
    /// and down a row, to the same column of the row above or below, and up
    /// from the first row to the doors.
    func move(_ step: Step) {
        if onDoors {
            switch step {
            case .left: turn(false)
            case .right: turn(true)
            case .down: onDoors = false
            case .up: break
            }
            return
        }
        let all = items(door), columns = Self.columns(door)
        guard let current = chosen, let index = all.firstIndex(where: { $0.id == current.id }) else {
            if step == .up, doors.count > 1 { onDoors = true }
            return
        }
        switch step {
        case .left: chosenID = all[max(0, index - 1)].id
        case .right: chosenID = all[min(all.count - 1, index + 1)].id
        case .up:
            guard index >= columns else { if doors.count > 1 { onDoors = true }; return }
            chosenID = all[index - columns].id
        case .down:
            guard index / columns < (all.count - 1) / columns else { return }
            chosenID = all[min(all.count - 1, index + columns)].id
        }
    }

    enum Step { case left, right, up, down }

    /// Tab and Shift-Tab: from the doors' row to the tiles and back.
    func switchRow() {
        guard doors.count > 1 else { return }
        onDoors.toggle()
    }

    /// The next door along, or the one before.
    func turn(_ forward: Bool) {
        let open = doors
        guard let index = open.firstIndex(of: door), !open.isEmpty else { return }
        door = open[(index + (forward ? 1 : open.count - 1)) % open.count]
    }

    /// The door a site was last shown from opens first, as a call that
    /// shares the screen every week finds it there; Tab the first time.
    private static let doorsKey = "share.doors"
    static func remember(_ door: Kind, for host: String) {
        var all = UserDefaults.standard.dictionary(forKey: doorsKey) as? [String: String] ?? [:]
        all[host] = door.rawValue
        UserDefaults.standard.set(all, forKey: doorsKey)
    }

    private static func remembered(_ host: String) -> Kind? {
        (UserDefaults.standard.dictionary(forKey: doorsKey)?[host] as? String).flatMap(Kind.init(rawValue:))
    }

    /// The tabs ⌃Tab walks, the asking one left out, with the pictures the
    /// tabs' cards already have (TabGlance); the rest from macOS.
    func fill(_ browser: Browser, caller: Tab, offeringCaller: Bool = false) {
        let stills = TabGlance.of(browser).stills
        func offered(_ tabs: [Tab]) -> [Item] {
            tabs.filter { (offeringCaller || offersCaller || $0.id != caller.id) && !$0.isBlank && !$0.shy }.map { tab in
                Item(id: tab.id.uuidString, source: .tab(tab.id), kind: .tabs, title: tab.rowLabel, icon: tab.icon, letter: tab.monogram, picture: stills[tab.id])
            }
        }
        let recent = browser.recentTabs().tabs
        let first = callerFirst ? browser.tabs.filter { $0.id == caller.id } + recent.filter { $0.id != caller.id } : recent
        tabs = offered(first)
        otherTabs = offered(browser.tabs.filter { tab in !first.contains { $0.id == tab.id } })
        door = (callerFirst ? Kind.tabs : preferred).flatMap { doors.contains($0) ? $0 : nil }
            ?? Self.remembered(host).flatMap { doors.contains($0) ? $0 : nil } ?? doors.first ?? .tabs
        if !allowed, offersSystem { Task { await walls() } }
        Task { await others() }
    }

    /// What macOS tells anyone of a screen: its number, its name and its
    /// size in pixels.
    private static func described(_ screen: NSScreen) -> (id: CGDirectDisplayID, name: String, size: String) {
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        let scale = screen.backingScaleFactor
        return (id, screen.localizedName, "\(Int(screen.frame.width * scale)) × \(Int(screen.frame.height * scale))")
    }

    /// The screens without Screen Recording: each its name, its size and
    /// the wallpaper it shows, which needs no permission, so it can be told
    /// from the others. Picked, it goes on to macOS's picker on the screens.
    private func walls() async {
        let shown = NSScreen.screens
        screens = shown.map { screen in
            let about = Self.described(screen)
            return Item(id: "d\(about.id)", source: nil, kind: .screens, title: about.name, icon: nil, letter: "", detail: about.size)
        }
        for screen in shown {
            guard let url = NSWorkspace.shared.desktopImageURL(for: screen), let image = await Capture.wallpaper(at: url) else { continue }
            let id = "d\(Self.described(screen).id)"
            if let index = screens.firstIndex(where: { $0.id == id }) { screens[index].picture = NSImage(cgImage: image, size: .zero) }
        }
    }

    /// Yab's own windows a share may show: its browser windows. Panels and windows kept out of shares (the call's,
    /// the frame round a shown page) aren't windows to show.
    static func showable(_ number: CGWindowID) -> Bool {
        guard let window = NSApp.windows.first(where: { $0.windowNumber == Int(number) }) else { return false }
        return window.isVisible && !(window is NSPanel) && window.sharingType != .none
    }

    /// macOS's own surfaces, windows to ScreenCaptureKit and nothing to show.
    private static let systemParts: Set<String> = ["com.apple.controlcenter", "com.apple.notificationcenterui", "com.apple.dock", "com.apple.WindowManager"]

    private func others() async {
        // Yab's own windows come from the process's own content, which
        // needs no Screen Recording: without it they were never listed.
        let mine = (try? await SCShareableContent.currentProcess)?.windows.filter { window in
            window.windowLayer == 0 && window.frame.width >= 120 && window.frame.height >= 80 && Self.showable(window.windowID)
        } ?? []
        let content = sees && Share.refusing != "list" ? try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) : nil
        if sees, content == nil {
            sees = false
            if offersSystem { await walls() }
        }
        let me = getpid()
        let found = content?.windows.filter { window in
            guard window.windowLayer == 0, window.frame.width >= 120, window.frame.height >= 80,
                  let app = window.owningApplication, app.processID != me, !app.applicationName.isEmpty,
                  window.title?.isEmpty == false, !Self.systemParts.contains(app.bundleIdentifier)
            else { return false }
            return true
        } ?? []
        let shown = mine + found
        let own = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? ProcessInfo.processInfo.processName
        windows = shown.map { window in
            let app = window.owningApplication
            let ours = mine.contains { $0.windowID == window.windowID }
            let name = ours ? own : app?.applicationName ?? ""
            let words = ours ? NSApp.windows.first { $0.windowNumber == Int(window.windowID) }?.title ?? window.title : window.title
            let title = (words ?? "").isEmpty ? name : "\(name): \(words ?? "")"
            let icon = ours ? NSApp.applicationIconImage : app.flatMap { NSRunningApplication(processIdentifier: $0.processID)?.icon }
            return Item(id: "w\(window.windowID)", source: .window(window.windowID), kind: .windows, title: title, icon: icon, letter: String(name.prefix(1)))
        }
        for window in shown { takes["w\(window.windowID)"] = (SCContentFilter(desktopIndependentWindow: window), window.frame.size) }
        guard let content else {
            await picturesOfTheDoor(.windows)
            keepPicturesLive()
            return
        }
        screens = content.displays.enumerated().map { index, display in
            let about = NSScreen.screens.map(Self.described).first { $0.id == display.displayID }
            return Item(id: "d\(display.displayID)", source: .display(display.displayID), kind: .screens, title: about?.name ?? "Screen \(index + 1)",
                        icon: nil, letter: "", detail: about?.size ?? "\(display.width) × \(display.height)")
        }
        for display in content.displays { takes["d\(display.displayID)"] = (SCContentFilter(display: display, excludingWindows: []), display.frame.size) }
        await picturesOfTheDoor(.windows)
        await picturesOfTheDoor(.screens)
        keepPicturesLive()
    }

    /// What each window and screen is taken with, by its tile's id.
    @ObservationIgnored private var takes: [String: (filter: SCContentFilter, size: CGSize)] = [:]

    private func picturesOfTheDoor(_ kind: Kind) async {
        for item in (kind == .windows ? windows : screens) {
            guard let take = takes[item.id], let picture = await Self.picture(take.filter, take.size) else { continue }
            if kind == .windows, let index = windows.firstIndex(where: { $0.id == item.id }) { windows[index].picture = picture }
            if kind == .screens, let index = screens.firstIndex(where: { $0.id == item.id }) { screens[index].picture = picture }
        }
    }

    /// The open door's pictures stay live while the box is up, as Chromium's
    /// picker keeps its own, a look a second. The box's end drops the picker
    /// and this with it.
    private func keepPicturesLive() {
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                if self.door != .tabs { await self.picturesOfTheDoor(self.door) }
            }
        }
    }

    private static func picture(_ filter: SCContentFilter, _ size: CGSize) async -> NSImage? {
        let config = SCStreamConfiguration()
        let width: CGFloat = 480
        config.width = Int(width)
        config.height = max(2, Int(width * size.height / max(1, size.width)))
        config.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}

/// The box a page's getDisplayMedia is answered in: ⌘T's box, its glass,
/// its curve and its foot, in the middle of the page. Under the field,
/// Chrome's three doors, Tab, Window and Entire Screen, each a picture of
/// where it goes; under them the open door's tiles. The field finds a tab
/// or a window by its name, the arrows move through the tiles, Tab and
/// ⌘1 to ⌘3 turn the doors, Return shows what is picked and Escape says no.
/// The share box's keys, from the window whatever has them there: a
/// Chromium page or the call's window can hold the first responder, and
/// the box's field then heard no arrow. Arrows move the pick (and onto the
/// doors' row), Tab and Shift-Tab change rows, Return shares, Escape
/// cancels; letters go to the field, which finds as you type.
@MainActor
final class ShareKeys {
    private var monitor: Any?

    func start(_ picker: SharePicker, yes: @escaping () -> Void, no: @escaping () -> Void, focus: @escaping () -> Void) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak picker] event in
            guard let picker else { return event }
            let flags = event.modifierFlags.intersection([.command, .control, .option])
            guard flags.isEmpty else { return event }
            let editing = (event.window?.firstResponder as? NSTextView)?.isFieldEditor == true
            switch event.keyCode {
            case 123:
                if editing, !picker.typed.isEmpty { return event }
                picker.move(.left)
            case 124:
                if editing, !picker.typed.isEmpty { return event }
                picker.move(.right)
            case 126: picker.move(.up)
            case 125: picker.move(.down)
            case 48: picker.switchRow()
            case 36, 76: yes()
            case 53: no()
            case 51:
                if editing { return event }
                if !picker.typed.isEmpty { picker.typed.removeLast() }
            default:
                if editing { return event }
                guard let text = event.characters, !text.isEmpty,
                      text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }) else { return event }
                picker.typed += text
                picker.onDoors = false
                focus()
            }
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

struct ShareBox: View {
    let browser: Browser
    let tab: Tab
    @Bindable var picker: SharePicker
    @FocusState private var typing: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var solid

    static let width: CGFloat = 600
    /// As tall as ⌘T's box, its field and the body under it (owner,
    /// 0.46.10); the tiles scroll in what the field, doors and foot leave.
    static let height: CGFloat = Omnibox.fieldHeight + Omnibox.bodyHeight
    @State private var keys = ShareKeys()

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Omnibox.corner, style: .continuous) }
    private var yes: () -> Void { { SharePicker.remember(picker.door, for: picker.host); browser.answer(tab, .yes(nil)) } }
    private var no: () -> Void { { browser.answer(tab, .no) } }

    var body: some View {
        VStack(spacing: 0) {
            field
            Rectangle().fill(Omnibox.seam).frame(height: 1)
            if picker.doors.count > 1 { doors }
            list
            foot
        }
        .frame(width: Self.width, height: Self.height)
        .clipShape(shape)
        .background { ground }
        .overlay(shape.strokeBorder(scheme == .dark ? Color.white.opacity(0.1) : Color.black.opacity(0.08), lineWidth: 0.5)) // design: the field's box ring (Omnibox), not a card's hairline
        .onAppear {
            DispatchQueue.main.async { typing = true }
            keys.start(picker, yes: yes, no: no, focus: { typing = true })
        }
        .onDisappear { keys.stop() }
    }

    /// Who asks and what for, where ⌘T has its glass and its words: the
    /// site's mark and "Share with" the site, in ink, a heading until a
    /// key is typed, when the words narrow the open door's tiles. "Find a
    /// tab" there read as a search of the browser's tabs, not as this
    /// question. The screens are one or two, found by looking, not typing.
    private var field: some View {
        HStack(spacing: Omnibox.gap) {
            Group {
                if picker.typed.isEmpty {
                    Mark(icon: Favicons.shared.cached(picker.host) ?? Favicons.shared.cached(Browser.site(picker.host)),
                         letter: Browser.site(picker.host).first.map { String($0).uppercased() } ?? "•", size: Omnibox.tile - 2)
                } else {
                    Symbol("magnifyingglass", size: Omnibox.glass)
                        .foregroundStyle(Palette.muted)
                }
            }
            .frame(width: Omnibox.slot)
            TextField("", text: $picker.typed, prompt: Text("Share with \(picker.host)").foregroundStyle(Palette.ink))
                .textFieldStyle(.plain)
                .font(.system(size: 20))
                .foregroundStyle(Palette.ink)
                .focused($typing)
                .onSubmit(yes)
                .onExitCommand(perform: no)
                // Arrows, Tab, Return and Escape: ShareKeys, wherever the
                // window's keys are.
            if picker.typed.isEmpty, picker.door != .screens, !InputMethod.composing(focused: typing) {
                Text("Type to find")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.muted)
                    .fixedSize()
            }
        }
        .padding(.horizontal, Omnibox.gutter)
        .frame(height: Omnibox.fieldHeight)
    }

    /// Chrome's three kinds, in its words, each showing where it goes: the
    /// window's tabs fanned, a window, the screen itself.
    private var doors: some View {
        HStack(spacing: 8) {
            ForEach(Array(picker.doors.enumerated()), id: \.element) { index, kind in
                Button { picker.door = kind } label: {
                    ShareDoor(kind: kind, on: picker.door == kind, items: picker.items(kind), allowed: picker.sees)
                        // The keys on the doors' row: the open door ringed.
                        .overlay {
                            if picker.onDoors, picker.door == kind {
                                RoundedRectangle(cornerRadius: Radius.floating, style: .continuous)
                                    .strokeBorder(Color.accentColor, lineWidth: 2)
                            }
                        }
                }
                .buttonStyle(.plain)
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
        }
        .padding(.horizontal, Omnibox.gutter)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private static func columns(_ kind: SharePicker.Kind) -> [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: SharePicker.columns(kind))
    }

    private var list: some View {
        let kind = picker.door, items = picker.items(kind)
        return ThreadScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if items.isEmpty {
                    Text("Nothing here is called that.")
                        .font(.system(size: 13.5))
                        .foregroundStyle(Palette.muted)
                        .frame(maxWidth: .infinity, minHeight: 80)
                }
                LazyVGrid(columns: Self.columns(kind), spacing: 8) {
                    ForEach(items) { item in
                        let on = picker.chosen?.id == item.id
                        Group {
                            if item.id == SharePicker.system.id {
                                ShareElsewhere(on: on)
                            } else if kind == .screens {
                                ShareScreenTile(item: item, on: on)
                            } else {
                                ShareThumb(item: item, on: on)
                            }
                        }
                        // One click shares, as a click on ⌃Tab's grid goes.
                        .onTapGesture { picker.chosenID = item.id; yes() }
                    }
                }
                if !picker.allowed, kind != .tabs { ShareAllow(kind: kind) }
            }
            .padding(.horizontal, Omnibox.gutter)
            .padding(.vertical, 12)
        }
        .frame(maxHeight: .infinity)
    }

    /// What Return sends, named: a tab, a window, a screen; the way to
    /// macOS's picker says so.
    private var word: String {
        guard let item = picker.chosen else { return "Share" }
        if item.id == SharePicker.system.id { return "Open macOS Picker" }
        switch item.kind {
        case .tabs: return "Share Tab"
        case .windows: return "Share Window"
        case .screens: return "Share Screen"
        }
    }

    /// As the field's foot: one glass pill on the right, what Return does
    /// and Escape. Who asks is said once, at the head.
    private var foot: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                Button(action: yes) { FieldFoot.label(word, "↩") }
                    .buttonStyle(FootButton(strong: true))
                Button(action: no) { FieldFoot.label("Cancel", "esc") }
                    .buttonStyle(FootButton(strong: false))
            }
            .padding(2)
            .background { FieldGlass(shape: Capsule()) }
            .fixedSize()
        }
        .frame(height: FieldFoot.pill)
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .padding(.top, 4)
    }

    /// The field's own: Liquid Glass over a material where the Mac draws
    /// it, the ground with a short shadow close under it where it doesn't.
    @ViewBuilder
    private var ground: some View {
        if #available(macOS 26.0, *), !solid {
            shape.fill(.regularMaterial)
            Color.clear.glassEffect(.regular.tint(Palette.ground.opacity(Omnibox.glassTint)), in: shape)
        } else {
            shape
                .fill(scheme == .dark ? Omnibox.nearer : Palette.ground) // design: the field's box (Omnibox), not a card
                .shadow(color: .black.opacity(scheme == .dark ? 0.3 : 0.05), radius: 1.5, y: 2) // design: the field's box's own short shadow
        }
    }
}

/// One of the three doors: a picture of where it goes, its name in
/// Chrome's words and how many are behind it. The open one stands on a
/// plate lifted off the glass, as a picked row does in the column.
private struct ShareDoor: View {
    let kind: SharePicker.Kind
    let on: Bool
    let items: [SharePicker.Item]
    let allowed: Bool
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    private var name: String {
        switch kind {
        case .tabs: return "Tab"
        case .windows: return "Window"
        case .screens: return "Entire Screen"
        }
    }

    private var count: String {
        let real = items.filter { $0.id != SharePicker.system.id }.count
        switch kind {
        case .tabs: return real == 1 ? "1 tab" : "\(real) tabs"
        // Without Screen Recording only Yab's own are listed.
        case .windows: return allowed ? (real == 1 ? "1 window" : "\(real) windows") : "\(real) in Yab"
        case .screens: return real == 1 ? "1 screen" : "\(real) screens"
        }
    }

    var body: some View {
        let plate = RoundedRectangle(cornerRadius: Radius.floating, style: .continuous)
        VStack(alignment: .leading, spacing: 8) {
            art
                .frame(height: 62)
                .frame(maxWidth: .infinity)
                .background(Omnibox.tileFill)
                .clipShape(RoundedRectangle(cornerRadius: Radius.floating, style: .continuous))
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(name)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Spacer(minLength: 0)
                Text(count)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.muted)
                    .monospacedDigit()
            }
            .padding(.horizontal, 2)
        }
        .padding(6)
        .background {
            if on {
                plate.fill(scheme == .dark ? Palette.ink.opacity(0.12) : Palette.ground.opacity(0.85))
                    .cast(scheme == .dark ? Shadow.selectionDark : Shadow.selection)
                    .overlay(plate.strokeBorder(Palette.ink.opacity(0.08), lineWidth: 0.5)) // design: the lifted plate's rim on glass, as the column's picked row
            } else if hovering {
                plate.fill(Palette.ink.opacity(0.04))
            }
        }
        .contentShape(plate)
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var art: some View {
        switch kind {
        case .tabs:
            // The first tabs offered, fanned, the first on top.
            let shown = Array(items.prefix(3).reversed())
            ZStack {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                    let step = Double(index) - Double(shown.count - 1) / 2
                    card(item)
                        .frame(width: 78, height: 49)
                        .rotationEffect(.degrees(step * 5))
                        .offset(x: step * 26, y: 4 + abs(step) * 2)
                }
            }
        case .windows:
            // One window, its bar and lights, rising off the bottom edge.
            VStack(spacing: 0) {
                HStack(spacing: 3) { // design: a window's lights in miniature
                    ForEach([Color(nsColor: .systemRed), Color(nsColor: .systemYellow), Color(nsColor: .systemGreen)], id: \.self) { light in
                        Circle().fill(light).frame(width: 4, height: 4)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 4)
                .frame(height: 9)
                .background(Palette.ground)
                picture(items.first { $0.picture != nil } ?? items.first)
            }
            .frame(width: 100, height: 60)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: Radius.small, topTrailingRadius: Radius.small, style: .continuous))
            .cast(Shadow.thumb)
            .offset(y: 12)
        case .screens:
            if let screen = items.first, let shown = screen.picture {
                Image(nsImage: shown).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                    .overlay(alignment: .top) { if screen.source == nil { ShareScreenTile.menuBar(height: 5) } }
            } else {
                Symbol("display", size: 20).foregroundStyle(Palette.muted)
            }
        }
    }

    private func card(_ item: SharePicker.Item) -> some View {
        picture(item)
            .clipShape(RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.small, style: .continuous).strokeBorder(Palette.ink.opacity(0.12), lineWidth: 0.5)) // design: a picture's edge in miniature, as ShareThumb's
            .cast(Shadow.thumb)
    }

    @ViewBuilder
    private func picture(_ item: SharePicker.Item?) -> some View {
        if let item, let shown = item.picture {
            Image(nsImage: shown).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
                .clipped()
        } else {
            Palette.ground
                .overlay { if let item { Mark(icon: item.icon, letter: item.letter, size: 16) } }
        }
    }
}

/// A screen behind the Entire Screen door, as large as two to a row lets
/// it be, in its own shape: what is on it where Yab may see it, else its
/// wallpaper under a menu bar, so it is told from the others at a glance.
private struct ShareScreenTile: View {
    let item: SharePicker.Item
    let on: Bool
    @State private var hovering = false

    /// The screen's shape, from its size in pixels.
    private var ratio: CGFloat {
        let sides = item.detail.split(separator: "×").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard sides.count == 2, sides[1] > 0 else { return 16 / 10 }
        return sides[0] / sides[1]
    }

    static func menuBar(height: CGFloat) -> some View {
        Rectangle().fill(Color.white.opacity(0.3)).frame(height: height) // design: macOS's menu bar in miniature
    }

    private func screen(_ shape: RoundedRectangle) -> some View {
        Color.clear
            .aspectRatio(ratio, contentMode: .fit)
            .overlay {
                if let picture = item.picture {
                    Image(nsImage: picture).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                        .overlay(alignment: .top) { if item.source == nil { Self.menuBar(height: 9) } }
                } else {
                    Omnibox.tileFill.overlay { Symbol("display", size: 28).foregroundStyle(Palette.muted) }
                }
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(Palette.ink.opacity(0.08), lineWidth: 1))
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.floating, style: .continuous)
        let plate = RoundedRectangle(cornerRadius: Radius.floating, style: .continuous)
        VStack(alignment: .leading, spacing: 8) {
            // The screen's own shape across the tile, so the plate is the
            // same 6 round it on every side; a screen stood on end keeps
            // to 166 tall, in the middle.
            if ratio >= 1.5 {
                screen(shape).frame(maxWidth: .infinity)
            } else {
                Color.clear.frame(maxWidth: .infinity).frame(height: 166).overlay { screen(shape) }
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.title)
                    .font(.system(size: 12.5, weight: on ? .medium : .regular))
                    .foregroundStyle(on ? Palette.ink : Palette.muted)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(item.detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.muted)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .padding(.horizontal, 2)
        }
        .padding(6)
        .background {
            if on || hovering { plate.fill(Palette.ink.opacity(on ? 0.08 : 0.04)) }
        }
        .contentShape(plate)
        .onHover { hovering = $0 }
    }
}

/// Where Yab can't see other apps' windows: a tile among the windows that
/// hands the choosing to macOS's picker, on the windows.
private struct ShareElsewhere: View {
    let on: Bool
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.floating, style: .continuous)
        VStack(alignment: .leading, spacing: 8) {
            Color.clear
                .aspectRatio(16 / 10, contentMode: .fit)
                .overlay {
                    VStack(spacing: 4) {
                        Symbol("macwindow.on.rectangle", size: 18)
                        Text("In macOS's picker")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(Palette.muted)
                }
                .overlay(shape.strokeBorder(Palette.ink.opacity(0.16), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))) // design: a place, not a picture: what opens elsewhere
            Text(SharePicker.system.title)
                .font(.system(size: 11.5, weight: on ? .medium : .regular))
                .foregroundStyle(on ? Palette.ink : Palette.muted)
                .lineLimit(1)
                .frame(height: 14)
                .padding(.horizontal, 2)
        }
        .padding(6)
        .background {
            if on || hovering {
                RoundedRectangle(cornerRadius: Radius.floating, style: .continuous) // design: the picture's 8 plus the 6 round it, as the doors' and screens' plates
                    .fill(Palette.ink.opacity(on ? 0.08 : 0.04))
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// One line under a door that is poorer without Screen Recording, and
/// the way to allow it.
private struct ShareAllow: View {
    let kind: SharePicker.Kind

    var body: some View {
        Button { Share.allowRecording() } label: {
            HStack(spacing: 6) {
                Symbol("info.circle", size: 12)
                    .foregroundStyle(Palette.muted)
                Text("Allow Screen Recording").fontWeight(.medium).foregroundColor(Palette.ink)
                    + Text(kind == .screens ? " to see what's on them" : " to list other apps' windows here").foregroundColor(Palette.muted)
            }
            .font(.system(size: 12))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
    }
}

/// A tile as ⌃Tab's grid has them: a plate under the one the keys are
/// on, a fainter one under the pointer, the same size either way.
private struct ShareThumb: View {
    let item: SharePicker.Item
    let on: Bool
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.floating, style: .continuous)
        VStack(alignment: .leading, spacing: 8) {
            Color.clear
                .aspectRatio(16 / 10, contentMode: .fit)
                .overlay {
                    if let picture = item.picture {
                        Image(nsImage: picture).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                    } else {
                        Omnibox.tileFill
                            .overlay { if item.icon != nil || !item.letter.isEmpty { Mark(icon: item.icon, letter: item.letter, size: 24) } }
                    }
                }
                .clipShape(shape)
                .overlay(shape.strokeBorder(Palette.ink.opacity(0.08), lineWidth: 1))
            HStack(spacing: 6) {
                if item.icon != nil || !item.letter.isEmpty { Mark(icon: item.icon, letter: item.letter, size: 12) }
                Text(item.title)
                    .font(.system(size: 11.5, weight: on ? .medium : .regular))
                    .foregroundStyle(on ? Palette.ink : Palette.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 2)
        }
        .padding(6)
        .background {
            if on || hovering {
                RoundedRectangle(cornerRadius: Radius.floating, style: .continuous) // design: the picture's 8 plus the 6 round it, as the doors' and screens' plates
                    .fill(Palette.ink.opacity(on ? 0.08 : 0.04))
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

// MARK: - sharing

/// What yab is showing pages now, and how: its own feeds, and the system
/// picker's shares, known only to say so on the tab and stop them.
@MainActor
@Observable final class Share {
    static let shared = Share()

    /// Bumped as shares come and go or stand still, for the rows and the chip.
    private(set) var revision = 0

    /// The purple macOS gives a screen being recorded, in the menu bar: the
    /// frame round a shown page, the chip and the tag.
    static let tint = Color(nsColor: .systemPurple)

    enum Source: Equatable {
        case tab(Tab.ID)
        case window(CGWindowID)
        case display(CGDirectDisplayID)
    }

    final class Session {
        let id: String
        weak var caller: Tab?
        weak var browser: Browser?
        let frame: PageFrame
        /// Nil for the system picker's, which WebKit takes itself.
        let source: Source?
        /// The page request, kept until decoded pixels provide its track.
        let token: String?
        weak var shown: Tab?
        var feed: ShareFeed?
        /// The page's largest size (SharePicker.most).
        var most: CGSize?
        var watch: Timer?
        /// Another tab coming to the front: heard before it is drawn.
        var switching: AnyCancellable?
        /// How many looks in a row the tab has been on screen.
        var steady = 0
        var rect = CGRect.zero
        var window = 0
        /// Frames handed to the page and not yet taken.
        var sending = 0
        var dropping = false
        /// Frames handed to the page, and dropped for it, since the start.
        var sent = 0
        var dropped = 0
        /// The frame and the pill round a shown tab's page.
        var outline: ShareOutline?
        /// Whether its words are out (ShareChip.swift).
        var fold: ShareFold?
        /// A tab's picture stands still: the tab is off screen.
        var paused = false
        /// The extension recording, when one asked (ExtensionCapture):
        /// the pill names it rather than its page.
        var recorder: String?
        /// Chromium takes the picture itself (ShareNative): no feed, the
        /// page's track is the engine's.
        var native = false
        /// The engine has said it is showing, so its saying otherwise ends this.
        var nativeLive = false
        /// The sound comes with it.
        var hearing = false

        /// The page that takes the frames when it isn't a tab's: an
        /// extension's offscreen document (ExtensionCapture).
        weak var page: (any PageScriptTarget)?
        /// Where the frames go: the asking tab's page, or `page`.
        @MainActor var consumer: (any PageScriptTarget)? { page ?? caller?.builtPage }

        init(id: String, caller: Tab?, browser: Browser?, frame: PageFrame, source: Source?, token: String? = nil, page: (any PageScriptTarget)? = nil) {
            self.id = id
            self.caller = caller
            self.page = page
            self.browser = browser
            self.frame = frame
            self.source = source
            self.token = token
        }
    }

    @ObservationIgnored private(set) var sessions: [String: Session] = [:]
    /// The words of a share from the system's picker, with no session of its own.
    let systemFold = ShareFold()
    /// The system picker asked for from the card: 1 for a screen, 2 for a
    /// window, by web view, for WebKit's question that follows.
    @ObservationIgnored var prompts: [ObjectIdentifier: Int] = [:]
    /// WebKit's questions before its own picker, counted for tests.
    @ObservationIgnored var systemAsked = 0
    /// The way to macOS's picker, step by step, for tests (bench share state).
    @ObservationIgnored var trail: [String] = []
    func note(_ step: String) {
        trail.append(step)
        if trail.count > 40 { trail.removeFirst(trail.count - 40) }
    }

    /// Open System Settings where Screen Recording is, asking first if
    /// macOS never has.
    static func allowRecording() {
        if !CGRequestScreenCaptureAccess(),
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func add(_ session: Session) {
        session.fold = ShareFold()
        sessions[session.id] = session
        if session.source != nil, let web = session.caller?.builtPage, web.window == nil { keepDrawing(web) }
        mark()
    }

    /// A call's page out of sight while it shares what Yab takes itself:
    /// its canvas needs a seen page to give the call frames (Bench.keepSharing).
    func keepDrawing(_ web: any PageHandle) {
        guard sessions.values.contains(where: { $0.source != nil && $0.caller?.builtPage === web }) else { return }
        web.webKitKeepSharing()
    }

    /// The share is over: yab stops taking the picture, and the page hears
    /// its track end when yab, not the page, ended it.
    func end(_ id: String, tellPage: Bool) {
        guard let session = sessions.removeValue(forKey: id) else { return }
        // A tab's sound for an extension: its tap let go too.
        ExtensionTabAudio.stop(id)
        session.watch?.invalidate()
        session.switching = nil
        session.outline?.close()
        session.outline = nil
        session.feed?.stop()
        session.feed = nil
        if session.source != nil, let web = session.caller?.builtPage,
           !sessions.values.contains(where: { $0.source != nil && $0.caller?.builtPage === web }) {
            web.webKitDoneSharing(of: session.caller)
        }
        if session.native {
            mark()
            guard tellPage, let page = session.caller?.builtPage as? ChromiumPage else { return }
            // The engine ends every track of it, and the page hears them
            // end as it would from Chrome's own Stop.
            if page.stopsNativeCapture { page.stopNativeCapture(kind: "screen") }
            else { page.call(ShareScript.call("api.feed(id, 'end')"), arguments: ["id": id], in: .page, frame: session.frame) { _ in } }
            return
        }
        if session.source != nil, let web = session.consumer {
            web.call(ShareScript.transport("api.end(id)"), arguments: ["id": id], in: .yab, frame: session.frame) { _ in }
        }
        if tellPage, let web = session.consumer {
            if let token = session.token {
                web.call(ShareScript.call("api.end(id, t)"), arguments: ["id": id, "t": token], in: .page, frame: session.frame) { _ in }
            } else {
                web.call(ShareScript.call("api.feed(id, 'end')"), arguments: ["id": id], in: .page, frame: session.frame) { _ in }
            }
        }
        mark()
    }

    /// Everything a tab is sharing, stopped: its dot's menu, its word's.
    func stop(caller tab: Tab) {
        for session in sessions.values where session.caller === tab { end(session.id, tellPage: true) }
    }

    func sharing(_ tab: Tab) -> Bool { sessions.values.contains { $0.caller === tab } }

    /// The tabs last told they share or are shown, to be told when they
    /// no longer are.
    @ObservationIgnored private var flagged: [Weak] = []
    private struct Weak { weak var tab: Tab? }

    /// The words on the tabs: Sharing on the page shown to, Others see on
    /// the tab shown.
    private func mark() {
        let callers = sessions.values.compactMap(\.caller), shown = sessions.values.compactMap(\.shown)
        var seen = Set<ObjectIdentifier>()
        for tab in flagged.compactMap(\.tab) + callers + shown where seen.insert(ObjectIdentifier(tab)).inserted {
            let sharing = callers.contains { $0 === tab }, looked = shown.contains { $0 === tab }
            if tab.sharing != sharing { tab.sharing = sharing }
            if tab.seen != looked { tab.seen = looked }
        }
        flagged = (callers + shown).map { Weak(tab: $0) }
        revision += 1
    }

    /// What a call is called on a tab: the service's name for the ones
    /// Yab knows, its site otherwise.
    static func callName(of tab: Tab?) -> String { callName(at: tab?.address) }

    static func callName(at address: URL?) -> String {
        guard let host = address?.host()?.lowercased() else { return "the call" }
        if host == "meet.google.com" { return "Meet" }
        if host == "zoom.us" || host.hasSuffix(".zoom.us") { return "Zoom" }
        if host.hasPrefix("teams.") { return "Teams" }
        if host == "app.slack.com" { return "Slack" }
        if host.hasSuffix(".webex.com") { return "Webex" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// The share showing a tab, if one is.
    func showing(_ tab: Tab) -> Session? { sessions.values.first { $0.shown === tab } }

    /// A tab share this tab could take over from: Share Instead, as Arc
    /// has it, on another of the window's tabs while one is shown.
    func switchable(to tab: Tab) -> Session? {
        guard !tab.isBlank, !tab.shy, !tab.sharing, !tab.seen else { return nil }
        return sessions.values.first { session in
            guard case .tab = session.source, let browser = session.browser, session.caller !== tab else { return false }
            // Chromium's capture moves only to another Chromium tab.
            if session.native, !(tab.builtPage is ChromiumPage) { return false }
            return browser.tabs.contains { $0 === tab }
        }
    }

    /// The share goes on with this tab in it: brought to the front where
    /// the last one was, so the picture taken is the same part of the
    /// window; the page's track and the call carry on as they were.
    func switchShown(_ session: Session, to tab: Tab) {
        if session.native, let caller = session.caller?.builtPage as? ChromiumPage, let page = tab.builtPage as? ChromiumPage {
            caller.switchDisplaySource(to: page, audio: session.hearing)
        }
        session.shown = tab
        session.browser?.select(tab)
        mark()
    }

    private func pause(_ session: Session, _ paused: Bool) {
        guard session.paused != paused else { return }
        session.paused = paused
        revision += 1
    }

    /// The frame round `ring`, the page shown when it is on screen, and the
    /// tag over the page in front when the window has nowhere else to say it.
    private func dress(_ session: Session, ring web: (any PageHandle)?) {
        guard let browser = session.browser else { return }
        let status = browser.shareSpot == .tag ? status(in: browser, over: browser.active) : nil
        guard let page = web ?? (status == nil ? nil : browser.active?.builtPage), let window = page.window else {
            session.outline?.hide()
            return
        }
        if session.outline == nil {
            session.outline = ShareOutline(fold: session.fold ?? systemFold) { [weak session] in session?.browser }
        }
        let corner = browser.pageSquare ? 0 : Backdrop.corner
        let look = web == nil ? nil : ShareOutline.Ring(recorded: session.recorder != nil, top: browser.barShown ? 0 : corner, bottom: corner)
        session.outline?.show(over: page, in: window, ring: look, tag: status)
    }

    // MARK: feeding the page

    func start(_ session: Session, _ filter: SCContentFilter, rect: CGRect?, points: CGSize, scale: CGFloat, cursor: Bool) {
        session.fold?.announce()
        let feed = ShareFeed()
        if (session.consumer as? any PageHandle)?.engine == .chromium { feed.encoding = .jpeg }
        feed.most = session.most
        let id = session.id
        feed.onFormat = { [weak self, weak session] format in
            guard let self, let session else { return }
            self.send(session, "api.feed(id, 'format', b, c, w, h)",
                      ["id": id, "b": format.description.base64EncodedString(), "c": format.codec, "w": format.width, "h": format.height], always: true)
        }
        feed.onChunk = { [weak self, weak session] chunk in
            guard let self, let session else { return }
            // A page behind (a busy tab, a slow Mac) gets the next whole
            // frame, not a queue of pieces it would decode late.
            if session.sending > 6 { session.dropping = true }
            if session.dropping {
                guard chunk.key, session.sending <= 2 else {
                    session.dropped += 1
                    if chunk.key { session.feed?.key() }
                    return
                }
                session.dropping = false
            }
            session.sent += 1
            self.send(session, "api.feed(id, 'chunk', b, k, t)", ["id": id, "b": chunk.data.base64EncodedString(), "k": chunk.key, "t": chunk.time])
        }
        feed.onEnd = { [weak self] _ in self?.end(id, tellPage: true) }
        session.feed = feed
        if case .tab = session.source {
            // Preparing the decoder is asynchronous. Revalidate the source,
            // then observe selection before SCK can deliver any frame.
            // Starting closed would lose the only frame of a static page.
            guard let shown = session.shown, let browser = session.browser,
                  browser.onScreen(shown.id), let web = shown.builtPage,
                  let window = web.window, window.windowNumber == session.window,
                  window.isVisible, !window.isMiniaturized else {
                return end(id, tellPage: true)
            }
            follow(session)
        } else {
            // A window or a screen has no frame of Yab's, only the tag.
            session.watch = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self, weak session] _ in
                MainActor.assumeIsolated {
                    guard let self, let session else { return }
                    self.dress(session, ring: nil)
                }
            }
        }
        if let refused = Self.refusedStart(session) { return failed(session, refused) }
        feed.start(filter, rect: rect, points: points, scale: scale, cursor: cursor) { [weak self] error in
            if let error { self?.failed(session, error) }
        }
    }

    /// ScreenCaptureKit wouldn't start. The page's side takes it as frames
    /// that never came (share-page.js `fail`): a window or a screen its
    /// page still waits for goes on to macOS's picker ("fallback"), a tab
    /// or an extension's share ends with the page told. Ending it here, as
    /// before, told Meet no ("Can't share your screen") with the system's
    /// picker a step away (request 904).
    private func failed(_ session: Session, _ error: Error) {
        let id = session.id
        guard sessions[id] === session, let web = session.consumer else { return end(id, tellPage: true) }
        session.feed?.stop()
        session.feed = nil
        web.call(ShareScript.call("api.fail(id, m)"), arguments: ["id": id, "m": error.localizedDescription],
                 in: .page, frame: session.frame) { [weak self] result in
            if (try? result.get()) as? Bool != true { self?.end(id, tellPage: true) }
        }
    }

    /// Test runs only (`YAB_SHARE_REFUSE`): ScreenCaptureKit acting as it
    /// does for a Yab given Screen Recording and not reopened, "list"
    /// finding no other app's window or screen, "start" refusing to take
    /// them, so evals/share-guard/refused.py can check where that goes.
    static let refusing: String? = Store.testing ? ProcessInfo.processInfo.environment["YAB_SHARE_REFUSE"] : nil

    private static func refusedStart(_ session: Session) -> Error? {
        guard refusing == "start", let source = session.source else { return nil }
        if case .tab = source { return nil }
        return NSError(domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain", code: -3801,
                       userInfo: [NSLocalizedDescriptionKey: "The user declined TCCs for application, window, display capture"])
    }

    private func send(_ session: Session, _ body: String, _ arguments: [String: Any], always: Bool = false) {
        guard let web = session.consumer else { return end(session.id, tellPage: false) }
        session.sending += 1
        let id = session.id
        web.call(ShareScript.call(body), arguments: arguments, in: .page, frame: session.frame) { [weak self, weak session] result in
            session?.sending -= 1
            // The page's side is gone: it navigated, or closed its frame.
            if (try? result.get()) as? Bool != true { self?.end(id, tellPage: false) }
        }
    }

    /// A tab's picture follows the tab: it goes out only while the tab is
    /// on screen, and is taken again where the tab now is when the window
    /// or the column around it changes. It stops the moment another tab is
    /// picked, before that tab is drawn where this one was: a look every
    /// quarter second let a few frames of the next tab through. It starts
    /// again once the tab has been back on screen for two looks, after
    /// the frames of whatever was there before it.
    func follow(_ session: Session) {
        // The next tab, not the one in front now: a publisher hands its
        // value on at once, and that shut the picture for its first frames.
        session.switching = session.browser?.changes(\.activeID).dropFirst().sink { [weak session] _ in
            session?.feed?.open = false
            session?.steady = 0
            session?.outline?.hide()
        }
        session.watch = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self, weak session] _ in
            MainActor.assumeIsolated {
                guard let self, let session else { return }
                guard session.consumer != nil else { return self.end(session.id, tellPage: false) }
                guard let tab = session.shown, let browser = session.browser, browser.everyTab.contains(where: { $0 === tab }) else {
                    return self.end(session.id, tellPage: true)
                }
                guard let web = tab.builtPage, let window = web.window, window.isVisible, !window.isMiniaturized,
                      session.native || window.windowNumber == session.window, browser.onScreen(tab.id)
                else {
                    session.feed?.open = false
                    session.steady = 0
                    self.pause(session, true)
                    self.dress(session, ring: nil)
                    return
                }
                session.steady += 1
                if session.steady >= 2 { session.feed?.open = true }
                self.pause(session, false)
                self.dress(session, ring: web)
                let rect = Self.place(of: web, in: window)
                if rect != session.rect {
                    session.rect = rect
                    session.feed?.move(rect, scale: window.backingScaleFactor)
                }
            }
        }
    }

    /// A view's place in its window, in points from the window's top left,
    /// as ScreenCaptureKit takes a part of a window.
    static func place(of view: NSView, in window: NSWindow) -> CGRect {
        let r = view.convert(view.bounds, to: nil)
        return CGRect(x: r.minX, y: window.frame.height - r.maxY, width: r.width, height: r.height).integral
    }

    /// Whether the tab is playing a video now, read in a world of Yab's
    /// (the page can't answer for it). A page that doesn't say within half
    /// a second counts as still.
    static func playsVideo(_ web: any PageScriptTarget, _ done: @escaping (Bool) -> Void) {
        var said = false
        func say(_ value: Bool) {
            guard !said else { return }
            said = true
            done(value)
        }
        let js = "return Array.prototype.some.call(document.querySelectorAll('video'), "
            + "function (v) { return !v.paused && !v.ended && v.readyState > 2 && v.videoWidth > 0; })"
        web.call(js, arguments: [:], in: .client) { result in
            // YAB_SHARE_TAB_HINT=none: every tab unhinted, as before
            // request 1030, for evals/share-guard/quality.py's A/B.
            DispatchQueue.main.async { say((try? result.get()) as? Bool == true || ProcessInfo.processInfo.environment["YAB_SHARE_TAB_HINT"] == "none") }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { say(false) }
    }
}

// MARK: - the browser's side

extension Browser {
    /// A question from a page's getDisplayMedia (ShareScript.page).
    func shareAsked(_ tab: Tab, _ body: [String: Any], _ frame: PageFrame) {
        switch body["kind"] as? String {
        case "ask":
            guard let token = body["token"] as? String else { return }
            // An extension's own page with a stream id it was given
            // (chromeMediaSourceId): what it names was picked or allowed
            // already, so no box and no click (ExtensionCapture).
            if let stream = body["stream"] as? String {
                guard let grant = ExtensionCapture.redeem(stream, from: frame) else {
                    return shareAnswer(tab, frame, token, ["choice": "cancel"])
                }
                let wide = body["width"] as? Double ?? 0, tall = body["height"] as? Double ?? 0
                let most = wide > 0 || tall > 0 ? CGSize(width: wide, height: tall) : nil
                return shareOwn(tab, frame: frame, token: token, most: most, label: grant.label, source: grant.source,
                                recorder: grant.extensionName)
            }
            // The page's own frames only, just after your click or key in its
            // tab or in a window it draws (RelayGuard, shareHand).
            guard let (hand, pressed) = shareHand(frame, on: tab) else { return shareAnswer(tab, frame, token, ["choice": "cancel"]) }
            let host = frame.origin.host.isEmpty ? (tab.address?.host() ?? "This page") : frame.origin.host
            let picker = SharePicker(token: token, frame: frame, host: host, audio: body["audio"] as? Bool ?? false)
            let wide = body["width"] as? Double ?? 0, tall = body["height"] as? Double ?? 0
            if wide > 0 || tall > 0 { picker.most = CGSize(width: wide, height: tall) }
            picker.take(body)
            picker.fill(self, caller: tab)
            // Asked from where you aren't, the call's Share out in its
            // window: the card comes where you can see it, over its tab.
            // A tab behind that its page asked from keeps it (ShareWaiting).
            // Pressed in a window the page draws, the box comes over that
            // window, where you are; the share is still the page's.
            if pressed == nil, !onScreen(tab.id), hand == .yab || floatingCall === tab { select(tab) }
            ask(PageAsk(kind: .share(picker), host: host), on: pressed ?? tab) { [weak self, weak tab] reply, _ in
                guard let self, let tab else { return }
                guard case .yes(let said) = reply else { return self.shareAnswer(tab, frame, token, ["choice": "cancel"]) }
                guard let item = picker.chosen else { return self.shareAnswer(tab, frame, token, ["choice": "cancel"]) }
                guard said != "system", let source = item.source else { return self.shareSystem(tab, picker) }
                self.shareOwn(tab, picker, item, source)
            }
        case "sound":
            // An extension's own tab asking for a tab's sound by a stream
            // id it was given (ExtensionTabAudio).
            guard let token = body["token"] as? String else { return }
            guard let stream = body["stream"] as? String, let grant = ExtensionCapture.redeem(stream, from: frame, for: "sound"),
                  let web = tab.builtPage else { return shareAnswer(tab, frame, token, ["choice": "cancel"]) }
            ExtensionTabAudio.start(grant, consumer: web, caller: tab, frame: frame, token: token) { [weak self, weak tab] reply in
                guard let self, let tab else { return }
                self.shareAnswer(tab, frame, token, reply)
            }
        case "tap":
            // What a captured tab's frame heard (tab-audio.js).
            ExtensionTabAudio.heard(tab, body)
        case "stop":
            if let id = body["id"] as? String { Share.shared.end(id, tellPage: false) }
        case "key":
            guard let id = body["id"] as? String, RelayGuard.ownFrame(frame, of: tab),
                  let session = Share.shared.sessions[id], session.caller === tab else { return }
            session.feed?.key()
        case "fallback":
            Share.shared.note("fallback asked")
            guard let id = body["id"] as? String, let token = body["token"] as? String, RelayGuard.ownFrame(frame, of: tab),
                  let session = Share.shared.sessions[id], session.caller === tab, session.source != nil,
                  session.token == token else { return Share.shared.note("fallback refused") }
            if case .tab = session.source {
                return Share.shared.end(id, tellPage: true)
            }
            // Re-enter from WebKit so its picker still has a user gesture,
            // even when the decoder reported its failure asynchronously.
            Share.shared.end(id, tellPage: false)
            if case .window = session.source {
                shareSystem(tab, frame: session.frame, token: token, prompt: 2)
            } else {
                shareSystem(tab, frame: session.frame, token: token)
            }
        case "started":
            guard let id = body["id"] as? String, RelayGuard.ownFrame(frame, of: tab) else { return }
            Share.shared.add(Share.Session(id: id, caller: tab, browser: self, frame: frame, source: nil))
        case "native":
            guard let id = body["id"] as? String, RelayGuard.ownFrame(frame, of: tab),
                  let session = Share.shared.sessions[id], session.native, session.caller === tab else { return }
            nativeStarted(session, stay: body["stay"] as? Bool ?? false)
        default:
            break
        }
    }

    /// Whose click stands behind a page's ask for the screen: one in its own
    /// tab, or one in a window the page opened and draws (RelayGuard.drawn),
    /// then that window's tab. Slack's huddle window is an about:blank
    /// popup its opener fills: Share Screen is pressed there, and the
    /// getDisplayMedia that follows is the opener's. Chrome asks no click
    /// for getDisplayMedia; Yab asks one, and finds it where it was made.
    /// A Document Picture-in-Picture window's click counts as its page's,
    /// as Chromium hands its activation to the opener; the box stays on the tab.
    func shareHand(_ frame: PageFrame, on tab: Tab) -> (RelayGuard.Hand, Tab?)? {
        guard RelayGuard.ownFrame(frame, of: tab) else { return nil }
        if let hand = RelayGuard.take(tab.builtPage) { return (hand, nil) }
        for window in everyTab + outside where window !== tab && RelayGuard.drawn(window, by: tab) {
            if let hand = RelayGuard.take(window.builtPage) { return (hand, window) }
        }
        let pip: [AnyObject?] = [tab.documentPiP.chromiumPage, tab.documentPiP.web]
        for page in pip { if let hand = RelayGuard.take(page) { return (hand, nil) } }
        return nil
    }

    /// An extension's chooseDesktopMedia (ExtensionCapture): the same box
    /// over `tab`, offering only the kinds it asked for and the tab itself
    /// too, under the extension's name; no way to macOS's picker, which
    /// hands nothing back that could be named. `done` with the source
    /// picked and its words, or nil.
    func pickShare(for name: String, kinds: Set<SharePicker.Kind>, on tab: Tab, done: @escaping (Share.Source?, String) -> Void) {
        let picker = SharePicker(token: UUID().uuidString, frame: nil, host: name, audio: false)
        picker.kinds = kinds
        picker.offersSystem = false
        picker.fill(self, caller: tab, offeringCaller: true)
        if !onScreen(tab.id) { select(tab) }
        ask(PageAsk(kind: .share(picker), host: name), on: tab) { reply, _ in
            guard case .yes = reply, let item = picker.chosen, let source = item.source else { return done(nil, "") }
            done(source, item.title)
        }
    }

    private func shareAnswer(_ tab: Tab, _ frame: PageFrame, _ token: String, _ reply: [String: Any], ready: ((Bool) -> Void)? = nil) {
        shareAnswer(tab.builtPage, frame, token, reply, ready: ready)
    }

    func shareRefused(_ tab: Tab, _ frame: PageFrame, _ token: String) { shareAnswer(tab, frame, token, ["choice": "cancel"]) }

    func shareAccepted(_ tab: Tab, _ frame: PageFrame, _ token: String, _ reply: [String: Any], ready: @escaping (Bool) -> Void) {
        shareAnswer(tab, frame, token, reply, ready: ready)
    }

    private func shareAnswer(_ page: (any PageScriptTarget)?, _ frame: PageFrame, _ token: String, _ reply: [String: Any], ready: ((Bool) -> Void)? = nil) {
        guard let web = page else { ready?(false); return }
        func answer() {
            web.call(ShareScript.call("api.answer(t, r)"), arguments: ["t": token, "r": reply], in: .page, frame: frame) { result in
                ready?((try? result.get()) as? Bool == true)
            }
        }
        if reply["choice"] as? String == "own", let id = reply["id"] as? String {
            func cancelled() {
                web.call(ShareScript.transport("api.end(id)"), arguments: ["id": id], in: .yab, frame: frame) { _ in }
                web.call(ShareScript.call("api.end(id, t)"), arguments: ["id": id, "t": token], in: .page, frame: frame) { _ in }
                ready?(false)
            }
            guard let session = Share.shared.sessions[id], session.consumer === web else { return cancelled() }
            web.call(ShareScript.transport("api.prepare(id, images)"),
                     arguments: ["id": id, "images": (web as? any PageHandle)?.engine == .chromium], in: .yab, frame: frame) { _ in
                guard Share.shared.sessions[id] === session, session.consumer === web else { return cancelled() }
                answer()
            }
        } else if reply["choice"] as? String == "sound", let id = reply["id"] as? String {
            // A tab's sound (ExtensionTabAudio): Yab's side may make its
            // track only once Yab has said so, never on a page's word.
            web.call(ShareScript.transport("api.prepareSound(id)"), arguments: ["id": id], in: .yab, frame: frame) { _ in
                answer()
            }
        } else { answer() }
    }

    /// An extension's offscreen document asking (ExtensionCapture.Relay):
    /// only for a stream id it was given; anything else is told no, as
    /// a page with nobody to click can't be shown a box.
    func shareAsked(page web: any PageScriptTarget, _ body: [String: Any], _ frame: PageFrame) {
        switch body["kind"] as? String {
        case "ask":
            guard let token = body["token"] as? String else { return }
            guard let stream = body["stream"] as? String, let grant = ExtensionCapture.redeem(stream, from: frame) else {
                return shareAnswer(web, frame, token, ["choice": "cancel"])
            }
            let wide = body["width"] as? Double ?? 0, tall = body["height"] as? Double ?? 0
            shareOwn(nil, page: web, frame: frame, token: token, most: wide > 0 || tall > 0 ? CGSize(width: wide, height: tall) : nil,
                     label: grant.label, source: grant.source, recorder: grant.extensionName)
        case "sound":
            guard let token = body["token"] as? String else { return }
            guard let stream = body["stream"] as? String, let grant = ExtensionCapture.redeem(stream, from: frame, for: "sound") else {
                return shareAnswer(web, frame, token, ["choice": "cancel"])
            }
            ExtensionTabAudio.start(grant, consumer: web, frame: frame, token: token) { [weak self, weak web] reply in
                self?.shareAnswer(web, frame, token, reply)
            }
        case "stop":
            if let id = body["id"] as? String, Share.shared.sessions[id]?.consumer === web { Share.shared.end(id, tellPage: false) }
        case "key":
            if let id = body["id"] as? String, let session = Share.shared.sessions[id], session.consumer === web { session.feed?.key() }
        default:
            break
        }
    }

    /// The system's picker, for a window or a screen Yab can't see: on
    /// the windows from the Window door, on the screens otherwise, with its
    /// own switch between them.
    private func shareSystem(_ tab: Tab, _ picker: SharePicker) {
        guard let frame = picker.frame else { return }
        shareSystem(tab, frame: frame, token: picker.token, prompt: picker.chosen?.kind == .windows ? 2 : 1)
    }

    /// `prompt`: WebKit's own numbering, 1 the screens, 2 the windows.
    private func shareSystem(_ tab: Tab, frame: PageFrame, token: String, prompt: Int = 1) {
        guard let web = tab.builtPage else { return }
        if web is ChromiumPage { return sharePicked(tab, frame: frame, token: token, most: nil, windows: prompt == 2) }
        // Sharing a tab brought its source forward. WebKit's own picker
        // needs the caller back in an active, focused document instead.
        if floating == tab.id { land(home: true) }
        select(tab)
        NSApp.activate()
        let key = ObjectIdentifier(web)
        let until = Date().addingTimeInterval(2)
        func handoff() {
            guard tab.builtPage === web else { return }
            guard activeID == tab.id, Date() < until else {
                Share.shared.note(activeID == tab.id ? "system: no focus in 2 s" : "system: another tab in front")
                return shareAnswer(tab, frame, token, ["choice": "cancel"])
            }
            func again() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { handoff() }
            }
            // select changes state before SwiftUI moves the web view. A
            // floated caller must also have landed in this browser's stage.
            guard let stage = web.superview as? StageView, stage.shows == tab.id,
                  let window = BrowserWindows.shared.window(for: self), web.window === window,
                  window.isVisible, !window.isMiniaturized, !tab.floating else { return again() }
            if !window.isKeyWindow { window.makeKey() }
            window.makeFirstResponder(web)
            Share.shared.prompts[key] = prompt
            // Native focus reaches the Web process asynchronously. Keep
            // the request pending until it arrives, then call WebKit in
            // this same native invocation so its user gesture is fresh.
            web.call(ShareScript.call("document.hasFocus() ? api.system(t) : 'unfocused'"),
                                    arguments: ["t": token], in: .page, frame: frame) { result in
                let value = try? result.get()
                Share.shared.note("system: page said \(value.map { "\($0)" } ?? "nothing")")
                if value as? Bool != true { Share.shared.prompts.removeValue(forKey: key) }
                if value as? String == "unfocused" { again() }
            }
        }
        DispatchQueue.main.async { handoff() }
    }

    /// A window or a screen ScreenCaptureKit won't find for Yab: a page's
    /// own ask goes on to macOS's picker on the same kind, where it may
    /// still be shown; an extension's, which can't, is told no.
    private func shareElsewhere(_ tab: Tab?, page: (any PageScriptTarget)?, recorder: String?, frame: PageFrame, token: String, prompt: Int) {
        guard let tab, page == nil, recorder == nil else {
            return shareAnswer(page ?? tab?.builtPage, frame, token, ["choice": "cancel"])
        }
        shareSystem(tab, frame: frame, token: token, prompt: prompt)
    }

    private func shareOwn(_ tab: Tab, _ picker: SharePicker, _ item: SharePicker.Item, _ source: Share.Source) {
        guard let frame = picker.frame else { return }
        shareNative(tab, picker, source) { [weak self] taken in
            guard !taken else { return }
            self?.shareOwn(tab, frame: frame, token: picker.token, most: picker.most, label: item.title, source: source)
        }
    }

    /// `recorder`: the extension recording, named on the shown tab's pill
    /// instead of the page that asked.
    func shareOwn(_ tab: Tab?, page: (any PageScriptTarget)? = nil, frame: PageFrame, token: String, most: CGSize?, label: String,
                  source: Share.Source, recorder: String? = nil) {
        let id = UUID().uuidString
        let session = Share.Session(id: id, caller: tab, browser: self, frame: frame, source: source, token: token, page: page)
        let consumer = page ?? tab?.builtPage
        session.most = most
        session.recorder = recorder
        switch source {
        case .tab(let shownID):
            guard let shown = everyTab.first(where: { $0.id == shownID }) else {
                return shareAnswer(consumer, frame, token, ["choice": "cancel"])
            }
            session.shown = shown
            // Brought in front: a tab out of sight
            // isn't drawn, and so can't be shown. Another space's comes with
            // its space, as ⌃Tab lands there.
            if !tabs.contains(where: { $0 === shown }), let space = spaceHolding(shown) { switchSpace(to: space) }
            select(shown)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self else { return }
                guard let web = shown.builtPage, let window = web.window else {
                    return self.shareAnswer(consumer, frame, token, ["choice": "cancel"])
                }
                let rect = Share.place(of: web, in: window)
                let scale = window.backingScaleFactor
                let pixels = ShareFeed.pixels(rect.size, scale: scale, most: most)
                session.rect = rect
                session.window = window.windowNumber
                Share.shared.add(session)
                // A tab playing a video keeps its frames coming; any other
                // keeps its size, as a shared tab's track should (request 1030: unhinted, a text tab reached the far
                // end at a third of its size). WebKit reads the hint once,
                // when the page adds the track, so it is decided here.
                Share.playsVideo(web) { motion in
                    guard Share.shared.sessions[id] === session else { return }
                    self.shareAnswer(consumer, frame, token,
                                     ["choice": "own", "id": id, "surface": "browser", "label": label, "width": pixels.width, "height": pixels.height,
                                      "motion": motion]) { ready in
                        guard ready else { return Share.shared.end(id, tellPage: false) }
                        guard Share.shared.sessions[id] === session else { return }
                        SCShareableContent.getCurrentProcessShareableContent { content, _ in
                            DispatchQueue.main.async {
                                guard Share.shared.sessions[id] === session else { return }
                                guard let own = content?.windows.first(where: { Int($0.windowID) == window.windowNumber }) else {
                                    return Share.shared.end(id, tellPage: true)
                                }
                                // The pointer too: what you point at on the page is what the call is to look at.
                                Share.shared.start(session, SCContentFilter(desktopIndependentWindow: own), rect: rect, points: rect.size, scale: scale, cursor: true)
                            }
                        }
                    }
                }
            }
        case .window(let number):
            // Yab's own window from its own content: other apps' need
            // Screen Recording, Yab's don't.
            let find: (@escaping (SCShareableContent?, Error?) -> Void) -> Void = SharePicker.showable(number)
                ? { SCShareableContent.getCurrentProcessShareableContent(completionHandler: $0) }
                : { SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false, completionHandler: $0) }
            find { [weak self] content, _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard let window = content?.windows.first(where: { $0.windowID == number }),
                          Share.refusing != "list" || SharePicker.showable(number) else {
                        return self.shareElsewhere(tab, page: page, recorder: recorder, frame: frame, token: token, prompt: 2)
                    }
                    let scale = NSScreen.screens.first { $0.frame.intersects(window.frame) }?.backingScaleFactor ?? 2
                    let pixels = ShareFeed.pixels(window.frame.size, scale: scale, most: most)
                    Share.shared.add(session)
                    self.shareAnswer(consumer, frame, token,
                                     ["choice": "own", "id": id, "surface": "window", "label": label, "width": pixels.width, "height": pixels.height]) { ready in
                        guard ready else { return Share.shared.end(id, tellPage: false) }
                        guard Share.shared.sessions[id] === session else { return }
                        Share.shared.start(session, SCContentFilter(desktopIndependentWindow: window), rect: nil, points: window.frame.size, scale: scale, cursor: true)
                    }
                }
            }
        case .display(let number):
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard let display = content?.displays.first(where: { $0.displayID == number }), Share.refusing != "list" else {
                        return self.shareElsewhere(tab, page: page, recorder: recorder, frame: frame, token: token, prompt: 1)
                    }
                    // yab's windows kept out of shares (a call's, floating)
                    // stay out of this one too.
                    let hidden = Set(NSApp.windows.filter { $0.sharingType == .none && $0.windowNumber > 0 }.map { CGWindowID($0.windowNumber) })
                    let out = content?.windows.filter { hidden.contains($0.windowID) } ?? []
                    let scale = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == number }?.backingScaleFactor ?? 2
                    let size = CGSize(width: display.width, height: display.height)
                    let pixels = ShareFeed.pixels(size, scale: scale, most: most)
                    Share.shared.add(session)
                    self.shareAnswer(consumer, frame, token,
                                     ["choice": "own", "id": id, "surface": "monitor", "label": label, "width": pixels.width, "height": pixels.height]) { ready in
                        guard ready else { return Share.shared.end(id, tellPage: false) }
                        guard Share.shared.sessions[id] === session else { return }
                        Share.shared.start(session, SCContentFilter(display: display, excludingWindows: out), rect: nil, points: size, scale: scale, cursor: true)
                    }
                }
            }
        }
    }
}

// MARK: - round the shown page

/// The frame round a shown tab's page, marking the tab being shared,
/// and the tag when the window has nowhere else to say so (ShareChip.swift):
/// in windows of their own over the page, children of the browser's, so the
/// picture Yab takes of the browser's window never has them in it. Two: the
/// frame the page's size and deaf to the pointer, so every click is the
/// page's; the tag only its own size. Kept out of every share and never key.
@MainActor
final class ShareOutline {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    /// The frame's color and the corners of the page it goes round.
    struct Ring: Equatable {
        var recorded = false
        var top: CGFloat
        var bottom: CGFloat
    }

    private let ring: Panel
    private let ringHost: NSHostingView<ShareRing>
    private let pill: Panel
    private let fold: ShareFold
    private let words = ShareTagWords()
    private let pillHost: NSHostingView<ShareTag>
    private weak var web: NSView?
    private var watching: [NSObjectProtocol] = []
    private var wantsRing = false
    private var wantsTag = false

    init(fold: ShareFold, browser: @escaping () -> Browser?) {
        self.fold = fold
        func panel() -> Panel {
            let panel = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.sharingType = Store.recording ? .readOnly : .none
            panel.isReleasedWhenClosed = false
            panel.animationBehavior = .none
            return panel
        }
        ring = panel()
        ring.ignoresMouseEvents = true
        ringHost = NSHostingView(rootView: ShareRing(look: Ring(top: 0, bottom: 0)))
        ringHost.sizingOptions = []
        ring.contentView = ringHost
        pill = panel()
        pillHost = NSHostingView(rootView: ShareTag(words: words, fold: fold, browser: browser))
        pillHost.sizingOptions = []
        pill.contentView = WindowHosting.measured(pillHost)
        fold.opening = { [weak self] in self?.place(open: true) }
        fold.closed = { [weak self] in self?.place() }
    }

    func show(over web: NSView, in window: NSWindow, ring look: Ring?, tag status: ShareStatus?) {
        if let look, ringHost.rootView.look != look { ringHost.rootView = ShareRing(look: look) }
        words.say(status)
        let ringing = wantsRing
        wantsRing = look != nil
        wantsTag = status != nil
        if self.web !== web { watch(web, in: window) }
        place(open: fold.open)
        for (panel, wanted) in [(ring, wantsRing), (pill, wantsTag)] {
            guard wanted else {
                if panel === ring { fadeRing() } else { drop(panel) }
                continue
            }
            if panel.parent !== window {
                panel.parent?.removeChildWindow(panel)
                window.addChildWindow(panel, ordered: .above)
            }
            if !panel.isVisible { panel.orderFront(nil) }
        }
        if wantsRing, !ringing { lightRing() }
    }

    func hide() {
        words.say(nil)
        wantsRing = false
        wantsTag = false
        fadeRing()
        drop(pill)
    }

    private func drop(_ panel: Panel) {
        guard panel.isVisible || panel.parent != nil else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    /// `Motion.quick`, on the panel: the frame comes and goes, it never snaps.
    private func lightRing() {
        ring.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ring.animator().alphaValue = 1
        }
    }

    private func fadeRing() {
        guard ring.isVisible, ring.alphaValue > 0 else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ring.animator().alphaValue = 0
        }, completionHandler: { [self] in
            MainActor.assumeIsolated {
                if !wantsRing { drop(ring) }
            }
        })
    }

    /// What is up now, in screen points (bench share state).
    var report: [String: Any] {
        func rect(_ panel: Panel) -> Any { panel.isVisible ? [panel.frame.minX, panel.frame.minY, panel.frame.width, panel.frame.height] : NSNull() }
        return ["ring": wantsRing ? rect(ring) : NSNull(), "tag": rect(pill), "tagOpen": fold.open, "tagWords": words.status?.words ?? ""]
    }

    func close() {
        // Kept by its own timers until the frame has gone.
        wantsRing = false
        fadeRing()
        drop(pill)
        watching.forEach(NotificationCenter.default.removeObserver)
        watching = []
    }

    /// Over the page, following it at once as the window is sized or the
    /// column comes and goes, not only at the share's quarter-second look.
    private func watch(_ web: NSView, in window: NSWindow) {
        watching.forEach(NotificationCenter.default.removeObserver)
        self.web = web
        web.postsFrameChangedNotifications = true
        let center = NotificationCenter.default
        watching = [
            center.addObserver(forName: NSView.frameDidChangeNotification, object: web, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.place() }
            },
            center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.place() }
            },
        ]
    }

    private func place(open: Bool = false) {
        guard let web, let window = web.window else { return }
        let page = window.convertToScreen(web.convert(web.bounds, to: nil))
        if wantsRing, ring.frame != page { ring.setFrame(page, display: true) }
        guard wantsTag, let status = words.status else { return }
        // The shape grows and gathers inside: a panel sized frame by frame
        // falls behind what it holds. Small again at rest, the page has
        // the room back.
        let size = open ? words.open : status.paused ? words.standing : ShareTag.reach
        let spot = CGRect(x: (page.midX - size.width / 2).rounded(), y: page.maxY - size.height, width: size.width, height: size.height)
        if pill.frame != spot { pill.setFrame(spot, display: true) }
    }
}

/// The frame, on the page's own curve: square along the top under the
/// address band, square all round at the screen's edge. One color for the
/// whole of a share: macOS's purple, red for a recording.
struct ShareRing: View {
    let look: ShareOutline.Ring

    var body: some View {
        UnevenRoundedRectangle(topLeadingRadius: look.top, bottomLeadingRadius: look.bottom,
                               bottomTrailingRadius: look.bottom, topTrailingRadius: look.top, style: .continuous)
            .strokeBorder(look.recorded ? Color.red : Share.tint, lineWidth: 2)
    }
}

// MARK: - on the tabs

/// Shown in Meet on the tab a call shows, saying where it goes. The call's
/// own row says nothing and other rows offer no Share Instead: the owner
/// found both noise on the rows (0.46.10); the call's controls and the band
/// stop or move a share. In the row's strongest ink, a touch heavier than
/// the name. With no band and no row's end to say it, the column's row has
/// Stop too. Paused says its picture stands still.
struct ShareWord: View {
    var tab: Tab
    let hovering: Bool
    private var share = Share.shared
    /// The row's backdrop: a site's color, a space's.
    @Environment(\.tone) private var tone

    /// An extension's recording says so on both tabs: Recording on its
    /// page, Recorded by it on the tab it records.
    private var words: String {
        let session = share.showing(tab)
        if session?.paused == true { return "Paused" }
        if let recorder = session?.recorder { return "Recorded by \(recorder)" }
        return "Shown in \(Share.callName(of: session?.caller))"
    }

    var body: some View {
        if tab.seen, !tab.sharing {
            let stops = share.stopsInRow(tab, hovering: hovering)
            HStack(spacing: 6) {
                // Beside Stop the first word is enough, the title keeps the row.
                Text(stops ? String(words.prefix { $0 != " " }) : words)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Palette.strong(on: tone))
                    .lineLimit(1)
                    .fixedSize()
                if stops {
                    Button("Stop") { share.stopAll(of: tab) }
                        .buttonStyle(.yab(.secondary, .small))
                        .fixedSize()
                }
            }
            .padding(.trailing, 16)
            .contextMenu {
                Button("Stop Sharing Screen", mark: "yab.screen") { share.stopAll(of: tab) }
            }
            .transition(.opacity)
        }
    }
}
