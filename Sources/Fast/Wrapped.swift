import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Yab Wrapped over the browser window: the window behind goes dark, the
// arcade rises into the middle of it, a layer of the window rather than a
// window of its own (WrappedLayer, among App's panels, as LookCard is), so
// it moves with the browser and adds nothing to the Dock or Mission
// Control. Esc or a click on the dark closes it. Keys while it is up: → or
// Space next, ← back, held mouse pauses, S share, W wear the icon, R play
// again.
//
// It is asked for by ⌘T only once a moment is due: its row at the top of
// the empty field's Now (`due`), and "Yab Wrapped" by name then too: the
// first 100 days, then each December the year. Never on its own, and not
// at will in between (2026-10-14).

@MainActor
@Observable final class Wrapped {
    static let shared = Wrapped()
    static let finishedKey = "wrapped.finished"
    static let playedKey = "wrapped.played"

    static var finished: Bool { Store.settings.bool(forKey: finishedKey) }

    /// What is up, and over which browser.
    private(set) var model: WrappedModel?
    @ObservationIgnored private(set) weak var browser: Browser?
    /// The moment ⌘T offers, until it is played.
    private(set) var due: WrappedMoment?
    @ObservationIgnored private var checked: Date?
    /// Esc, wherever the keyboard is in the window: the window's own keys
    /// take it before the arcade could (as LookCard's).
    @ObservationIgnored private var keys: Any?

    /// The bench's world, stood in for what this Mac counted.
    @ObservationIgnored var stand: (counts: WrappedCounts, first: Date, period: String?)?

    func show(in browser: Browser?) {
        guard let browser else { return }
        if let stand { return open(counts: stand.counts, first: stand.first, period: stand.period, in: browser) }
        WrappedTally.gather { counts, first in
            self.open(counts: counts, first: first, in: browser)
        }
    }

    /// Up on counts given, for the bench's worlds too.
    func open(counts: WrappedCounts, first: Date?, period given: String? = nil, in browser: Browser) {
        let initials = Store.settings.string(forKey: "wrapped.initials") ?? WrappedTally.initials(NSFullUserName())
        let period = given ?? WrappedTally.period(first: first)
        let story = WrappedStory.make(counts, initials: initials, period: period)
        model = WrappedModel(story: story, waiting: WrappedStory.levelsFor(counts).filter { $0.minutes >= WrappedStory.floorMinutes }.count,
                             period: period, initials: initials)
        self.browser = browser
        listen()
        if browser.fieldShowing { browser.close() }
        BrowserWindows.shared.window(for: browser)?.makeKeyAndOrderFront(nil)
        // Played: the moment's row goes.
        if story != nil, let due {
            var played = Set(Store.settings.stringArray(forKey: Self.playedKey) ?? [])
            played.insert(due.id)
            Store.settings.set(Array(played).sorted(), forKey: Self.playedKey)
            self.due = nil
            // A window with no tab keeps the field up under the arcade: its
            // list again, without the row just played.
            browser.typed = browser.typed
        }
    }

    /// The bench's: a moment due now, without waiting for one.
    func pretend(_ moment: WrappedMoment?) {
        due = moment
        checked = Date()
    }

    func close() {
        WrappedSound.shared.stop()
        model?.closeShare()
        model = nil
        browser = nil
        if let keys { NSEvent.removeMonitor(keys) }
        keys = nil
    }

    /// Esc by its key or by what it types, as a posted one may say only that.
    static func isEscape(_ event: NSEvent) -> Bool {
        event.keyCode == 53 || event.charactersIgnoringModifiers == "\u{1b}"
    }

    private func listen() {
        guard keys == nil else { return }
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.model != nil, Self.isEscape(event),
                      let browser = self.browser, event.window === BrowserWindows.shared.window(for: browser),
                      event.window?.attachedSheet == nil else { return event }
                self.close()
                return nil
            }
        }
    }

    /// Whether a moment is due, worked out again at most hourly, as ⌘T's
    /// empty field opens; the row shows from the next time.
    func refresh(now: Date = Date()) {
        if let checked, now.timeIntervalSince(checked) < 3_600 { return }
        checked = now
        WrappedTally.gather(now: now) { counts, first in
            let played = Set(Store.settings.stringArray(forKey: Self.playedKey) ?? [])
            let ready = WrappedStory.levelsFor(counts).filter { $0.minutes >= WrappedStory.floorMinutes }.count >= WrappedStory.fewest
            self.due = ready ? WrappedMoment.current(now: now, first: first).flatMap { played.contains($0.id) ? nil : $0 } : nil
        }
    }
}

/// When Yab asks: Yab's 100th day and the three after it, and the year from
/// December to the first week of January. The 100th day is let go when its days
/// touch the year's season or the two weeks before it (November 17 to
/// January 7): one Wrapped then, the year's.
struct WrappedMoment: Equatable {
    let id: String
    let title: String

    static func current(now: Date, first: Date?, calendar: Calendar = .current) -> WrappedMoment? {
        if let year = WrappedTally.year(now: now, calendar: calendar) {
            return WrappedMoment(id: "year-\(year)", title: "Your \(year)")
        }
        guard let first, let age = calendar.dateComponents([.day], from: first, to: now).day, (100...103).contains(age),
              let hundredth = calendar.date(byAdding: .day, value: 100, to: first),
              let last = calendar.date(byAdding: .day, value: 3, to: hundredth),
              !season(hundredth, calendar: calendar), !season(last, calendar: calendar) else { return nil }
        return WrappedMoment(id: "100-days", title: "Your first 100 days")
    }

    /// November 17 to January 7: the year's Wrapped and the weeks before it.
    static func season(_ date: Date, calendar: Calendar = .current) -> Bool {
        let c = calendar.dateComponents([.month, .day], from: date)
        guard let m = c.month, let d = c.day else { return false }
        return m == 12 || (m == 1 && d <= 7) || (m == 11 && d >= 17)
    }
}

/// The arcade over the window it belongs to.
struct WrappedLayer: View {
    var browser: Browser
    private var wrapped = Wrapped.shared

    static let size = CGSize(width: 360, height: 692)

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let model = wrapped.model, wrapped.browser === browser {
                    Color.black.opacity(0.55)
                        .background(.ultraThinMaterial)
                        .contentShape(Rectangle())
                        .onTapGesture { wrapped.close() }
                        .transition(.opacity)
                    let scale = min(1, (geo.size.height - 48) / Self.size.height)
                    WrappedStageView(model: model)
                        .frame(width: Self.size.width, height: Self.size.height)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.window, style: .continuous))
                        .shadow(color: .black.opacity(0.5), radius: 30, y: 16) // design: a machine standing over the window, not a card
                        .scaleEffect(scale)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .animation(wrapped.model != nil ? Motion.arrive : Motion.depart, value: wrapped.model != nil)
        }
        .allowsHitTesting(wrapped.model != nil && wrapped.browser === browser)
        .accessibilityHidden(wrapped.model == nil)
    }
}

/// The stage in SwiftUI, taking the keyboard as it arrives.
struct WrappedStageView: NSViewRepresentable {
    let model: WrappedModel

    func makeNSView(context: Context) -> WrappedStage {
        let stage = WrappedStage(model: model, tube: CGSize(width: 360, height: 640), strip: 52)
        DispatchQueue.main.async {
            model.host = stage.window
            stage.window?.makeFirstResponder(stage)
        }
        return stage
    }

    func updateNSView(_ stage: WrappedStage, context: Context) {}
}

/// What the story is at, kept by the window's stage.
@MainActor
@Observable final class WrappedModel {
    let story: WrappedStory?
    /// The levels there are so far, when too few for a story.
    let waiting: Int
    let period: String
    var initials: String
    private(set) var index = 0
    var iconWorn = AppIconStyle.saved == .arcade
    var muted = WrappedSound.muted {
        didSet { WrappedSound.muted = muted }
    }
    /// The sounds of the screen up, still to play.
    @ObservationIgnored private var cues: [(at: Double, sfx: WrappedSfx)] = []
    /// What the card says besides the character.
    var showHours = true
    var showDash = true
    @ObservationIgnored private var started = CACurrentMediaTime()
    @ObservationIgnored private var pausedAt: CFTimeInterval?
    let opened = CACurrentMediaTime()
    let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    @ObservationIgnored lazy var icon: CGImage? = AppIconStyle.arcade.image(dark: false)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    @ObservationIgnored private var share: NSWindow?
    /// The browser window the arcade is up in, for the card's sheet.
    @ObservationIgnored weak var host: NSWindow?

    init(story: WrappedStory?, waiting: Int, period: String, initials: String) {
        self.story = story
        self.waiting = waiting
        self.period = period
        self.initials = initials
        if let story { cues = WrappedSound.cues(story.screens[0], story: story) }
    }

    var screen: WrappedScreen? { story?.screens[index] }

    func go(_ to: Int) {
        guard let story else { return }
        index = max(0, min(story.screens.count - 1, to))
        started = CACurrentMediaTime()
        pausedAt = nil
        cues = WrappedSound.cues(story.screens[index], story: story)
        if story.screens[index] == .again || story.screens[index] == .icon {
            Store.settings.set(true, forKey: Wrapped.finishedKey)
        }
    }

    func next() { go(index + 1) }
    func back() { go(index - 1) }
    func again() { go(0) }

    func pause(_ on: Bool) {
        if on { pausedAt = pausedAt ?? CACurrentMediaTime() }
        else if let pausedAt { started += CACurrentMediaTime() - pausedAt; self.pausedAt = nil }
    }

    func wear() {
        guard Wrapped.finished else { return }
        AppIconStyle.arcade.choose()
        iconWorn = true
    }

    /// The grid for now, moving the story on when a screen's time is up.
    func draw(on grid: WrappedGrid, clock: Double) -> WrappedTubeUniforms {
        var u = WrappedTubeUniforms(time: Float(clock), rows: Float(grid.height))
        if reduceMotion { u.flicker = 0 }
        guard let story else {
            WrappedArcade.waiting(have: waiting, period: period, clock: clock, reduce: reduceMotion, on: grid)
            return u
        }
        let now = pausedAt ?? CACurrentMediaTime()
        let t = now - started
        let length = story.screens[index].seconds
        if length > 0, t >= length, pausedAt == nil, !reduceMotion, index < story.screens.count - 1 {
            next()
            return draw(on: grid, clock: clock)
        }
        // The screen's sounds as their moments pass.
        while let cue = cues.first, cue.at <= t {
            cues.removeFirst()
            WrappedSound.shared.play(cue.sfx)
        }
        var s = story
        s.initials = initials
        let frame = WrappedFrame(story: s, index: index, t: t, clock: clock, reduceMotion: reduceMotion, icon: icon, iconWorn: iconWorn)
        WrappedArcade.draw(frame, on: grid)
        u.roll = reduceMotion ? 0 : Float(max(0, 1 - t / 0.35))
        return u
    }

    // MARK: the card

    var card: WrappedArcade.Card? {
        guard var story else { return nil }
        story.initials = initials
        return WrappedArcade.Card(story: story, showHours: showHours, showDash: showDash, link: Invites.shared.friendLink.map(WrappedModel.bare),
                                  icon: Wrapped.finished ? icon : nil)
    }

    static func bare(_ url: URL) -> String {
        var s = url.absoluteString
        for p in ["https://", "http://", "www."] where s.hasPrefix(p) { s.removeFirst(p.count) }
        return s
    }

    /// The card as a picture, `scale` grid pixels a pixel: 8 makes it
    /// 3200 by 2000, twice 1600 by 1000.
    func picture(scale: Int = 8) -> CGImage? {
        guard let card, let grid = WrappedArcade.cardGrid(card) else { return nil }
        var u = WrappedTubeUniforms(time: 3.7, roll: 0, flicker: 0, curve: 0.08, rows: Float(grid.height))
        u.pad = 0
        return WrappedTube.shared.picture(grid, width: grid.width * scale, height: grid.height * scale, uniforms: u)
    }

    func openShare() {
        guard story != nil, share == nil, let host = host else { return }
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        sheet.contentView = WindowHosting.content(WrappedShareSheet(model: self) { [weak self, weak host, weak sheet] in
            guard let sheet else { return }
            host?.endSheet(sheet)
            self?.share = nil
        })
        share = sheet
        host.beginSheet(sheet)
    }

    func closeShare() {
        if let share, let parent = share.sheetParent { parent.endSheet(share) }
        share = nil
    }

    /// "I'm The Delegator in Yab Wrapped: 212 tasks handed off. About 37 hours back." and the link.
    var postText: String {
        let link = Invites.shared.friendLink?.absoluteString ?? "https://yetanotherbrowser.com"
        guard let story else { return link }
        let me = story.character
        let name = me.type.name.capitalized
        var text = "I'm \(name) in Yab Wrapped: \(me.line.lowercased())."
        if showHours, story.minutes >= 60 { text += " About \(story.minutes / 60) hours back." }
        return text + " " + link
    }
}

/// The window's content: the tube and the strip, taking keys and clicks.
@MainActor
final class WrappedStage: NSView {
    private let model: WrappedModel
    private let tube: WrappedTubeView
    private var downAt: CFTimeInterval = 0

    init(model: WrappedModel, tube size: CGSize, strip: CGFloat) {
        self.model = model
        tube = WrappedTubeView(width: WrappedArcade.width, height: WrappedArcade.height)
        super.init(frame: NSRect(x: 0, y: 0, width: size.width, height: size.height + strip))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        tube.frame = NSRect(x: 0, y: strip, width: size.width, height: size.height)
        tube.autoresizingMask = [.width, .height]
        tube.draw = { [weak model] grid, clock in model?.draw(on: grid, clock: clock) ?? WrappedTubeUniforms() }
        addSubview(tube)
        let bar = NSHostingView(rootView: WrappedStrip(model: model))
        bar.frame = NSRect(x: 0, y: 0, width: size.width, height: strip)
        bar.autoresizingMask = [.width]
        addSubview(bar)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func keyDown(with event: NSEvent) {
        if Wrapped.isEscape(event) { return Wrapped.shared.close() }
        switch event.keyCode {
        case 124, 49, 36: model.next()      // →, Space, Return
        case 123: model.back()              // ←
        case 53: Wrapped.shared.close()     // Esc
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "s": model.openShare()
            case "w": if model.screen == .icon || model.screen == .again { model.wear() }
            case "r": model.again()
            case "m": model.muted.toggle()
            default: super.keyDown(with: event)
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard tube.frame.contains(point) else { return super.mouseDown(with: event) }
        downAt = CACurrentMediaTime()
        model.pause(true)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard downAt > 0 else { return }
        model.pause(false)
        defer { downAt = 0 }
        guard CACurrentMediaTime() - downAt < 0.28, tube.frame.contains(point) else { return }
        (point.x - tube.frame.minX) / tube.frame.width < 0.3 ? model.back() : model.next()
    }
}

/// Under the tube: what can be done now, said with its key.
struct WrappedStrip: View {
    @Bindable var model: WrappedModel

    var body: some View {
        HStack(spacing: 8) {
            if model.story != nil {
                Button("Back") { model.back() }
                    .buttonStyle(.yab(.secondary, .regular, surface: .dark))
                    .disabled(model.index == 0)
                // Sound on or off, M too; kept.
                Button { model.muted.toggle() } label: {
                    Symbol(model.muted ? "speaker.slash" : "speaker.wave.2", size: 13)
                }
                .buttonStyle(.yab(.secondary, .regular, surface: .dark))
                .accessibilityLabel(model.muted ? "Turn Sound On" : "Turn Sound Off")
                .keyTip(model.muted ? "Turn Sound On" : "Turn Sound Off", keys: "M")
                Spacer(minLength: 0)
                if model.screen == .icon || model.screen == .again, !model.iconWorn {
                    Button("Wear Arcade") { model.wear() }
                        .buttonStyle(.yab(.secondary, .regular, surface: .dark))
                }
                Button("Share…") { model.openShare() }
                    .buttonStyle(.yab(.primary, .regular, surface: .dark))
            } else {
                Spacer(minLength: 0)
                Button("Close") { Wrapped.shared.close() }
                    .buttonStyle(.yab(.secondary, .regular, surface: .dark))
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}

/// The card to post: a live picture, three letters, which rows go on it,
/// and where it goes.
struct WrappedShareSheet: View {
    @Bindable var model: WrappedModel
    var done: () -> Void
    @State private var picture: CGImage?
    @State private var said: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Share Your Score").font(.system(size: 17, weight: .semibold))
            Group {
                if let picture {
                    Image(decorative: picture, scale: 1).resizable().interpolation(.high).aspectRatio(16 / 10, contentMode: .fit)
                } else {
                    Rectangle().fill(.black).aspectRatio(16 / 10, contentMode: .fit)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Initials").font(.callout).foregroundStyle(.secondary)
                    TextField("", text: Binding(get: { model.initials }, set: { new in
                        let letters = String(new.uppercased().filter { $0.isASCII && $0.isLetter }.prefix(3))
                        model.initials = letters
                        if letters.count == 3 { Store.settings.set(letters, forKey: "wrapped.initials") }
                    }))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .frame(width: 70)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("On the card").font(.callout).foregroundStyle(.secondary)
                    Toggle("Hours back", isOn: $model.showHours)
                    if model.story?.character.dash != nil {
                        Toggle("Second type", isOn: $model.showDash)
                    }
                }
                Spacer(minLength: 0)
            }
            Text(said ?? "Counts only, made on this Mac. No sites, mail or names are on it.")
                .font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Done") { done() }
                    .buttonStyle(.yab(.secondary, .regular))
                    .keyboardShortcut(.cancelAction)
                Spacer(minLength: 0)
                Button("Save…") { save() }.buttonStyle(.yab(.secondary, .regular))
                Button("Copy Image") { copy(); said = "Image copied." }.buttonStyle(.yab(.secondary, .regular))
                Button("Post on X") { post() }.buttonStyle(.yab(.primary, .regular))
            }
        }
        .padding(20)
        .frame(width: 680)
        .onAppear(perform: redraw)
        .onChange(of: model.initials) { redraw() }
        .onChange(of: model.showHours) { redraw() }
        .onChange(of: model.showDash) { redraw() }
    }

    private func redraw() { picture = model.picture(scale: 4) }

    private func png() -> Data? {
        guard let image = model.picture(scale: 8) else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = NSSize(width: image.width / 2, height: image.height / 2)
        return rep.representation(using: .png, properties: [:])
    }

    private func copy() {
        guard let data = png() else { return }
        let board = NSPasteboard.general
        board.clearContents()
        board.setData(data, forType: .png)
    }

    private func save() {
        guard let data = png() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Yab Wrapped.png"
        panel.allowedContentTypes = [.png]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url)
    }

    /// X's post page can't take a picture from a link: the picture goes
    /// on the clipboard first, to paste there.
    private func post() {
        copy()
        said = "Image copied. Paste it into the post."
        var parts = URLComponents(string: "https://x.com/intent/post")!
        parts.queryItems = [URLQueryItem(name: "text", value: model.postText)]
        if let url = parts.url { NSWorkspace.shared.open(url) }
    }
}

/// Every screen of a world's Wrapped as pictures, for the bench: what the
/// tube shows a moment after each screen opens, and the card to post.
@MainActor
enum WrappedShots {
    /// One screen as a film: its frames at 30 a second through the tube,
    /// into `dir`, and when CHARACTER SELECT's cursor stepped and landed,
    /// for a sound track to keep time with.
    static func film(counts: WrappedCounts, first: Date, period given: String? = nil, screen: String,
                     seconds: Double = 8.5, to dir: URL) -> [String: Any] {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let period = given ?? WrappedTally.period(first: first)
        guard let story = WrappedStory.make(counts, initials: "SER", period: period),
              let index = story.screens.firstIndex(where: { name($0) == screen || name($0).hasSuffix(screen) }),
              let grid = WrappedGrid(width: WrappedArcade.width, height: WrappedArcade.height) else { return ["error": "no such screen"] }
        let frames = Int(seconds * 30)
        for i in 0..<frames {
            let t = Double(i) / 30
            WrappedArcade.draw(WrappedFrame(story: story, index: index, t: t, clock: t), on: grid)
            let u = WrappedTubeUniforms(time: Float(t), roll: Float(max(0, 1 - t / 0.35)), flicker: 1, rows: Float(grid.height))
            guard let image = WrappedTube.shared.picture(grid, width: 450, height: 800, uniforms: u),
                  let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { continue }
            try? data.write(to: dir.appendingPathComponent(String(format: "%04d.png", i)))
        }
        var answer: [String: Any] = ["frames": frames, "screen": name(story.screens[index])]
        if story.screens[index] == .character {
            let select = WrappedArcade.select(story)
            answer["ticks"] = select.ticks
            answer["land"] = select.land
            answer["bars"] = story.character.bars.count
            answer["dash"] = story.character.dash != nil
            answer["type"] = story.character.type.name
        }
        return answer
    }

    static func write(counts: WrappedCounts, first: Date, period given: String? = nil, to dir: URL) -> [String: Any] {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var files: [String] = []
        func save(_ image: CGImage?, _ name: String) {
            guard let image, let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
            let url = dir.appendingPathComponent(name)
            try? data.write(to: url)
            files.append(url.path)
        }
        let period = given ?? WrappedTally.period(first: first)
        guard let grid = WrappedGrid(width: WrappedArcade.width, height: WrappedArcade.height) else { return ["error": "no grid"] }
        let u = WrappedTubeUniforms(time: 2, roll: 0, flicker: 0, rows: Float(grid.height))
        guard let story = WrappedStory.make(counts, initials: "SER", period: period) else {
            let have = WrappedStory.levelsFor(counts).filter { $0.minutes >= WrappedStory.floorMinutes }.count
            WrappedArcade.waiting(have: have, period: period, clock: 0, reduce: true, on: grid)
            save(WrappedTube.shared.picture(grid, width: 720, height: 1280, uniforms: u), "00-waiting.png")
            return ["files": files, "story": false]
        }
        let icon = AppIconStyle.arcade.image(dark: false)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        for (i, screen) in story.screens.enumerated() {
            let t: Double
            switch screen {
            case .level(_, _, true): t = 4.2
            case .level: t = 2.6
            case .bonus: t = 2.6
            case .score: t = 4.6
            case .rhythm: t = 3
            case .character: t = 7
            default: t = 1.4
            }
            WrappedArcade.draw(WrappedFrame(story: story, index: i, t: t, clock: 0, icon: icon), on: grid)
            save(WrappedTube.shared.picture(grid, width: 720, height: 1280, uniforms: u), String(format: "%02d-%@.png", i, name(screen)))
        }
        // The year's last screen, its countdown run out: the fireworks.
        if story.festive, let last = story.screens.indices.last {
            WrappedArcade.draw(WrappedFrame(story: story, index: last, t: 11.2, clock: 0, icon: icon), on: grid)
            save(WrappedTube.shared.picture(grid, width: 720, height: 1280, uniforms: u), "99-new-year.png")
        }
        let model = WrappedModel(story: story, waiting: story.levels.count, period: period, initials: "SER")
        save(model.picture(scale: 4), "card-1600x1000.png")
        return ["files": files, "story": true, "levels": story.levels.map(\.id), "bonuses": story.bonuses.map(\.id), "minutes": story.minutes]
    }

    private static func name(_ screen: WrappedScreen) -> String {
        switch screen {
        case .coin: return "coin"
        case .rhythm: return "rhythm"
        case .character: return "character"
        case let .level(level, _, boss): return (boss ? "boss-" : "level-") + level.id
        case let .bonus(level): return "bonus-" + level.id
        case .score: return "score"
        case .icon: return "icon"
        case .again: return "continue"
        }
    }
}
