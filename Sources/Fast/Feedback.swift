import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// Send Feedback, asked where you are: a card on the window it was asked
// from, the browser's, or Settings', that sends straight to the site
// (fast-web's /api/feedback) with the version and macOS filled in. Nothing
// opens in a tab and nothing leaves for Mail. What was written and not sent
// is still there the next time the card opens, files and all. Sent, the
// card goes at once: its going is the answer. Not sent, it stays and says
// why.
//
// It comes as yab's own questions come (Question.swift), not as the
// system's sheet sliding down from the title bar: in the middle of the page
// over the dimming, in from a touch smaller on arrive's curve, gone at once.
// It has a window of its own, clear, over the one it was asked from and
// moving with it, so the words typed, the paste, the drop and the file
// picker are its own and never the page's.
//
// Files go along as square tiles under the words, the way Mail and Codex
// show what is attached: a picture shows itself, anything else wears its
// extension. They come from the clip in the field's corner, dropped on the
// sheet, or pasted with ⌘V, a screenshot straight from the clipboard. The
// site takes a few megabytes in one go, so a big picture is sent as a JPEG
// no wider than a Retina screen, which a screenshot always fits in. What
// moves is never drawn again (FeedbackMedia.swift): a GIF goes as it is,
// or as an MP4 film when it is too big, and a video too big is exported
// smaller.

@MainActor
enum FeedbackSheet {
    private static var sheet: FeedbackFrame?
    private static var paster: Any?
    private static var watchers: [Any] = []
    private static let stage = FeedbackStage()

    struct Draft {
        var kind = FeedbackKind.bug
        var message = ""
        /// The address the last report went with, already in the field
        /// (feedback #164).
        var email = FeedbackSheet.rememberedEmail
        var files: [FeedbackFile] = []
        var includeDiagnostics = true
    }

    /// Send Feedback's key (⌥⇧I) in a window of Yab's whose keys no
    /// browser window's monitor hears (ContentView.take): Settings, a
    /// small window, the floating video, the card itself. A key with ⌘
    /// reaches the Help menu's item anyway; ⌥⇧I alone went to Settings'
    /// search as a letter (feedback #385).
    private static var keys: Any?
    static func listen() {
        guard keys == nil else { return }
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard !Keymap.shared.recording, Keymap.shared.matches(event, .sendFeedback) else { return event }
            if let window = event.window, let browser = BrowserWindows.shared.browser(for: window),
               BrowserWindows.shared.window(for: browser) === window, LinkWindow.owning(window) == nil, !Floater.owns(window) {
                return event
            }
            Links.writeFeedback()
            return nil
        }
    }

    /// On `window` when one is named (Settings' own Send Feedback), else on
    /// the window in front.
    static func show(on window: NSWindow? = nil) {
        if let sheet {
            sheet.makeKeyAndOrderFront(nil)
            return
        }
        guard let parent = window ?? NSApp.keyWindow?.sheetParent ?? NSApp.keyWindow ?? Links.window else { return }
        let window = FeedbackFrame(contentRect: parent.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        let layer = NSHostingView(rootView: FeedbackLayer(stage: stage))
        // The window follows its parent's frame; SwiftUI leaves its size alone.
        layer.sizingOptions = []
        window.contentView = layer
        stage.up = false
        stage.page = page(in: parent)
        sheet = window
        parent.addChildWindow(window, ordered: .above)
        window.makeKeyAndOrderFront(nil)
        watchPaste()
        let center = NotificationCenter.default
        for name in [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification] {
            watchers.append(center.addObserver(forName: name, object: parent, queue: .main) { _ in
                MainActor.assumeIsolated { follow(parent) }
            })
        }
        watchers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: parent, queue: .main) { _ in
            MainActor.assumeIsolated { close() }
        })
        DispatchQueue.main.async { stage.up = true }
    }

    /// The address the last report sent went with, kept on this Mac alone
    /// (`SyncShapes.syncs` leaves it out), so the next one has it filled
    /// in. A report sent with the field emptied forgets it.
    nonisolated static let emailKey = "feedback.email"
    nonisolated static var rememberedEmail: String { Store.settings.string(forKey: emailKey) ?? "" }

    static func remember(email: String) {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        if address.isEmpty {
            Store.settings.removeObject(forKey: emailKey)
        } else {
            Store.settings.set(address, forKey: emailKey)
        }
    }

    /// Put away without sending, ./bench ui feedback off.
    static func dismiss() { close() }

    /// The bench's hand: words written on the card and ⌘↩ pressed, and
    /// the address in its field when one is given ("" empties it).
    static func send(writing message: String, email: String? = nil) {
        FeedbackModel.shared.draft.message = message
        if let email { FeedbackModel.shared.draft.email = email }
        stage.sendRequests += 1
    }

    /// Gone at once, as a question is once answered: nothing is left to
    /// watch leave.
    fileprivate static func close() {
        guard let sheet else { return }
        self.sheet = nil
        watchers.forEach(NotificationCenter.default.removeObserver)
        watchers = []
        if let paster { NSEvent.removeMonitor(paster) }
        paster = nil
        stage.up = false
        let parent = sheet.parent
        parent?.removeChildWindow(sheet)
        sheet.orderOut(nil)
        parent?.makeKey()
    }

    /// Over the window it was asked from, as that window grows or shrinks.
    private static func follow(_ parent: NSWindow) {
        guard let sheet else { return }
        sheet.setFrame(parent.frame, display: true)
        stage.page = page(in: parent)
    }

    /// The page in front, from the window's top left: the largest page on
    /// show, the one of a split that has the room. None in Settings, or
    /// on a window with no page open, where the card stands in the middle
    /// of the window, undimmed.
    private static func page(in window: NSWindow) -> CGRect? {
        guard let content = window.contentView else { return nil }
        var pages: [NSView] = []
        func look(_ view: NSView) {
            if view is PageView || view is ChromiumPage { pages.append(view); return }
            view.subviews.forEach(look)
        }
        look(content)
        let rects = pages.filter { !$0.isHiddenOrHasHiddenAncestor && $0.window === window }
            .map { $0.convert($0.bounds, to: nil) }
        guard let rect = rects.max(by: { $0.width * $0.height < $1.width * $1.height }), rect.width > 0 else { return nil }
        return CGRect(x: rect.minX, y: window.frame.height - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Files added from anywhere, the clip, a drop, a paste, the bench.
    /// What fits goes on the card at once; a moving picture or a video too
    /// big for what is left joins it when it has been made smaller.
    static func attach(_ urls: [URL]) {
        let model = FeedbackModel.shared
        var left = max(FeedbackFile.room - model.weight, 0)
        var now: [FeedbackFile] = []
        var unread: [String] = []
        defer { model.unread(unread) }
        for url in urls {
            guard let file = FeedbackFile(url: url, room: left) else {
                unread.append(url.lastPathComponent)
                continue
            }
            guard file.data == nil, FeedbackFile.fits(url) else {
                now.append(file)
                left = max(left - file.size, 0)
                continue
            }
            let room = left
            Task {
                let made = await Task.detached(priority: .userInitiated) { await FeedbackFile.fitting(url, room: room) }.value
                if let made { model.add([made]) }
            }
        }
        model.add(now)
    }

    /// Chosen by hand, in a sheet on the card's window.
    fileprivate static func choose() {
        guard let sheet else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Attach"
        panel.beginSheetModal(for: sheet) { answer in
            guard answer == .OK else { return }
            MainActor.assumeIsolated { attach(panel.urls) }
        }
    }

    /// ⌘V with files or a picture on the clipboard attaches them; with
    /// words on it, it is the field's paste as ever.
    private static func watchPaste() {
        paster = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.window === sheet, Keymap.shared.matches(event, .feedbackSend) {
                stage.sendRequests += 1
                return nil
            }
            guard event.window === sheet,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  Hotkey(event)?.key == "v" else { return event }
            let board = NSPasteboard.general
            if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
                attach(urls)
                return nil
            }
            if picture(from: board, named: "Pasted image", drawing: board.string(forType: .string) == nil) { return nil }
            return event
        }
    }

    /// A picture that is bytes, not a file, put on the card: a GIF as it
    /// is, every frame (NSImage would keep the first), anything else as
    /// `FeedbackFile(picture:)` draws it, when `drawing`.
    private static func picture(from board: NSPasteboard, named name: String, drawing: Bool = true) -> Bool {
        if let gif = board.data(forType: NSPasteboard.PasteboardType(UTType.gif.identifier)),
           let file = keep(gif, as: name + ".gif") {
            attach([file])
            return true
        }
        guard drawing, let image = NSImage(pasteboard: board), let file = FeedbackFile(picture: image, named: name) else { return false }
        FeedbackModel.shared.add([file])
        return true
    }

    /// Bytes written to a folder of their own, for a file the card reads.
    private static func keep(_ data: Data, as name: String) -> URL? {
        guard let folder = newFolder() else { return nil }
        let file = folder.appendingPathComponent(name)
        return (try? data.write(to: file)) != nil ? file : nil
    }

    private static func newFolder() -> URL? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-feedback-\(UUID().uuidString)")
        return (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil ? folder : nil
    }

    // MARK: Drops (#251)

    /// What a drag can bring the card: files from Finder, files promised
    /// by Photos, Mail or a browser's picture, or a picture's bytes alone.
    /// SwiftUI hands the delegate only drags with one of these.
    static let dropTypes: [UTType] = [.fileURL, .image, .movie]
        + NSFilePromiseReceiver.readableDraggedTypes.compactMap { UTType($0) }

    /// Read from the drag's own pasteboard before anything lights up: a
    /// folder, or a card already holding all it can, lights nothing,
    /// because dropping there would attach nothing.
    static func takes(_ board: NSPasteboard) -> Bool {
        guard FeedbackModel.shared.draft.files.count < FeedbackFile.most else { return false }
        return !dropFiles(board).isEmpty || !promises(board).isEmpty || board.availableType(from: pictureTypes) != nil
    }

    /// A picture's bytes, as an app that has no file for it drags them.
    private static let pictureTypes = [UTType.png, .tiff, .jpeg, .gif, .heic, .webP].map { NSPasteboard.PasteboardType($0.identifier) }

    /// The drop itself: what `takes` saw, attached. A promised file joins
    /// the card when its app has written it, a moment later.
    @discardableResult
    static func take(_ board: NSPasteboard) -> Bool {
        let files = dropFiles(board)
        if !files.isEmpty {
            attach(files)
            return true
        }
        let promised = promises(board)
        if !promised.isEmpty, let folder = newFolder() {
            for promise in promised {
                promise.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: promiseQueue) { url, error in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            if error == nil { attach([url]) } else { FeedbackModel.shared.unread([url.lastPathComponent]) }
                        }
                    }
                }
            }
            return true
        }
        return board.availableType(from: pictureTypes) != nil && picture(from: board, named: "Dropped image")
    }

    private static let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    /// Files on a drag, folders left out: a card attaches files only.
    private static func dropFiles(_ board: NSPasteboard) -> [URL] {
        let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true }
    }

    /// Files an app will write when they are dropped. A link a browser
    /// drags promises a .webloc too: that is a link, not a file to attach.
    private static func promises(_ board: NSPasteboard) -> [NSFilePromiseReceiver] {
        let all = board.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver] ?? []
        return all.filter { promise in
            let types = promise.fileTypes.compactMap { UTType($0) }
            return types.isEmpty || !types.allSatisfy { $0.conforms(to: .internetLocation) || $0.conforms(to: .internetShortcut) }
        }
    }

    /// The site's answer: nil when it took it, or what to say.
    fileprivate static func send(_ draft: Draft) async -> String? {
        guard let site = Updater.site else { return "This build has nowhere to send it." }
        var snapshots: [String] = []
        if draft.includeDiagnostics {
            let stalls = await Task.detached(priority: .utility) { Watchdog.recent() ?? "" }.value
            let pages = await FeedbackDiagnostics.pages()
            snapshots = FeedbackDiagnostics.shared.snapshots(stallLog: stalls, page: pages.front, behind: pages.behind)
        }
        // A site older than this build turns down an event it doesn't know
        // yet, and the words with it: they go again without the newer
        // events, then without diagnostics at all.
        let tries: [String?] = snapshots + [nil]
        for (index, diagnostics) in tries.enumerated() {
            guard let (body, response) = try? await URLSession.shared.data(for: request(draft, site: site, diagnostics: diagnostics)) else {
                return "Couldn't reach Yab's site. Check the connection and try again."
            }
            let status = (response as? HTTPURLResponse)?.statusCode
            if index < tries.count - 1, status == 400, Self.refusesDiagnostics(body) { continue }
            switch status {
            case 200: return nil
            case 413: return "The files are more than the site takes at once. Leave one out and try again."
            default: return "The site didn't take it. Try again in a moment."
            }
        }
        return "The site didn't take it. Try again in a moment."
    }

    /// The site's no to the diagnostics alone: {"error": "invalid diagnostics"}.
    static func refusesDiagnostics(_ body: Data) -> Bool {
        (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["error"] as? String == "invalid diagnostics"
    }

    static func request(_ draft: Draft, site: URL, diagnostics: String?) -> URLRequest {
        var request = URLRequest(url: site.appendingPathComponent("api/feedback"))
        request.httpMethod = "POST"
        var fields: [String: String] = [
            "kind": draft.kind.rawValue,
            "message": draft.message,
            "email": draft.email.trimmingCharacters(in: .whitespaces),
            "version": Updater.version,
            "build": String(Updater.build),
            "os": Updater.system,
        ]
        if draft.includeDiagnostics {
            fields["diagnostics"] = diagnostics
        }
        // ACP stderr is not accepted by the site's typed event schema.
        // Carry its recent, redacted tail as a diagnostic attachment under
        // the existing toggle and upload limits, alongside the person's files.
        let signInLog = draft.includeDiagnostics ? GeminiSignInLog.shared.recent : nil
        let log = signInLog.flatMap { data in
            draft.files.count < FeedbackFile.most && draft.files.reduce(0, { $0 + $1.size }) + data.count <= FeedbackFile.room ? data : nil
        }
        if draft.files.isEmpty && log == nil {
            request.timeoutInterval = 15
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: fields)
        } else {
            // Words and files in one form, as a browser posts one.
            request.timeoutInterval = 60
            let boundary = "yab-\(UUID().uuidString)"
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            var body = Data()
            func line(_ text: String) { body.append(Data((text + "\r\n").utf8)) }
            for (key, value) in fields.sorted(by: { $0.key < $1.key }) {
                line("--\(boundary)")
                line("Content-Disposition: form-data; name=\"\(key)\"")
                line("")
                line(value)
            }
            for file in draft.files {
                guard let data = file.data else { continue }
                let name = file.name.replacingOccurrences(of: "\"", with: "'")
                line("--\(boundary)")
                line("Content-Disposition: form-data; name=\"file\"; filename=\"\(name)\"")
                line("Content-Type: \(file.mime)")
                line("")
                body.append(data)
                line("")
            }
            if let log {
                line("--\(boundary)")
                line("Content-Disposition: form-data; name=\"file\"; filename=\"gemini-signin-diagnostics.txt\"")
                line("Content-Type: text/plain")
                line("")
                body.append(log)
                line("")
            }
            line("--\(boundary)--")
            request.httpBody = body
        }
        return request
    }
}

/// What is being written, kept between openings of the sheet.
@MainActor
@Observable final class FeedbackModel {
    static let shared = FeedbackModel()
    var draft = FeedbackSheet.Draft()
    /// Files given to the card that could not be read, said under the
    /// field until the next file comes on.
    private(set) var unreadNote: String?

    func add(_ files: [FeedbackFile]) {
        let room = FeedbackFile.most - draft.files.count
        guard room > 0, !files.isEmpty else { return }
        unreadNote = nil
        withAnimation(Motion.arrive) { draft.files += files.prefix(room) }
    }

    func unread(_ names: [String]) {
        guard let first = names.first else { return }
        unreadNote = names.count == 1 ? "Couldn't read \(first)." : "Couldn't read \(first) and \(names.count - 1) more."
    }

    func remove(_ file: FeedbackFile) {
        withAnimation(Motion.depart) { draft.files.removeAll { $0.id == file.id } }
    }

    /// Everything that goes, in bytes.
    var weight: Int { draft.files.reduce(0) { $0 + $1.size } }

    /// Why it can't be sent as it stands, if it can't.
    var tooMuch: String? {
        if let big = draft.files.first(where: { $0.data == nil }) {
            return "\(big.name) is \(FeedbackFile.bytes(big.size)), files can be \(FeedbackFile.bytes(FeedbackFile.room)) together. Remove it to send."
        }
        if weight > FeedbackFile.room {
            return "That's \(FeedbackFile.bytes(weight)), files can be \(FeedbackFile.bytes(FeedbackFile.room)) together. Leave one out to send."
        }
        return nil
    }
}

/// A file going along with the feedback, read in when it was added.
struct FeedbackFile: Identifiable {
    /// As many as fit on one line of tiles.
    static let most = 5
    /// What the site takes in one go, with room left for the words.
    static let room = 4_000_000
    /// A picture bigger than this goes as a JPEG…
    private static let shrinkOver = 1_000_000
    /// …no longer on its long side than this.
    private static let longest: CGFloat = 2560

    let id = UUID()
    var name: String
    var type: UTType?
    /// Nil when it is too big to go.
    var data: Data?
    var size: Int
    var picture: NSImage?

    var mime: String { type?.preferredMIMEType ?? "application/octet-stream" }

    /// Four letters at most, for the tile.
    var ext: String {
        let tail = (name as NSString).pathExtension.uppercased()
        return tail.isEmpty ? "FILE" : String(tail.prefix(4))
    }

    /// A file as it is, a big still picture as a JPEG. A moving picture or a
    /// video goes as it is only within `room`, what is left of the site's;
    /// over it, it is read without its data, for `fitting` to make smaller.
    init?(url: URL, room: Int = Self.room) {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        guard values?.isDirectory != true else { return nil }
        name = url.lastPathComponent
        type = UTType(filenameExtension: url.pathExtension)
        size = values?.fileSize ?? 0
        let moves = type?.conforms(to: .image) == true && FeedbackMedia.moves(url)
        if type?.conforms(to: .image) == true, let image = NSImage(contentsOf: url) {
            picture = image
            // Drawn again, a moving picture would keep only its first frame.
            if !moves, size > Self.shrinkOver, let jpeg = Self.jpeg(image) {
                name = (name as NSString).deletingPathExtension + ".jpg"
                type = .jpeg
                data = jpeg
                size = jpeg.count
                return
            }
        }
        let limit = moves || type?.conforms(to: .movie) == true ? min(room, Self.room) : Self.room
        data = size > limit ? nil : try? Data(contentsOf: url)
        if data == nil, size <= limit { return nil }
    }

    /// Whether a file too big as it is can be made smaller: a moving picture
    /// or a video.
    static func fits(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .movie) || type.conforms(to: .image) && FeedbackMedia.moves(url)
    }

    /// The file read as `init(url:room:)` reads it, and when it doesn't fit
    /// `room`, made to: a moving picture as an MP4 film, a video exported
    /// smaller. Still without data when it can't be. Slow, off the main
    /// thread.
    static func fitting(_ url: URL, room: Int = Self.room) async -> FeedbackFile? {
        guard var file = FeedbackFile(url: url, room: room) else { return nil }
        guard file.data == nil else { return file }
        let film: Data?
        if file.type?.conforms(to: .movie) == true {
            film = await FeedbackMedia.smaller(video: url, room: min(room, Self.room))
        } else if let source = CGImageSourceCreateWithURL(url as CFURL, nil), FeedbackMedia.moves(source) {
            film = await FeedbackMedia.film(source, room: min(room, Self.room))
        } else {
            film = nil
        }
        guard let film else { return file }
        file.name = (file.name as NSString).deletingPathExtension + ".mp4"
        file.type = .mpeg4Movie
        file.data = film
        file.size = film.count
        return file
    }

    /// A picture that was never a file, pasted from the clipboard.
    init?(picture image: NSImage, named: String) {
        guard let rep = image.representations.first.flatMap({ $0 as? NSBitmapImageRep }) ?? Self.bitmap(image, scale: 1),
              var data = rep.representation(using: .png, properties: [:]) else { return nil }
        var ext = "png"
        if data.count > Self.shrinkOver, let jpeg = Self.jpeg(image) {
            data = jpeg
            ext = "jpg"
        }
        name = "\(named).\(ext)"
        type = ext == "png" ? .png : .jpeg
        self.data = data
        size = data.count
        picture = image
    }

    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    private static func jpeg(_ image: NSImage) -> Data? {
        let points = max(image.size.width, image.size.height)
        guard points > 0 else { return nil }
        let pixels = image.representations.map { CGFloat(max($0.pixelsWide, $0.pixelsHigh)) }.max() ?? points
        let side = min(max(pixels, points), longest)
        return bitmap(image, scale: side / points)?.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }

    /// The picture drawn at `scale` pixels to its points.
    private static func bitmap(_ image: NSImage, scale: CGFloat) -> NSBitmapImageRep? {
        let width = Int((image.size.width * scale).rounded()), height = Int((image.size.height * scale).rounded())
        guard width > 0, height > 0, let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
}

enum FeedbackKind: String, CaseIterable, Identifiable {
    case bug, idea, love, other
    var id: String { rawValue }

    var title: String {
        switch self {
        case .bug: return "Something's broken"
        case .idea: return "An idea"
        case .love: return "I love it"
        case .other: return "Other"
        }
    }

    var prompt: String {
        switch self {
        case .bug: return "What happened, and what did you expect?"
        case .idea: return "What would make Yab better for you?"
        case .love: return "What do you like about it?"
        case .other: return "Tell us anything"
        }
    }
}

/// The card's window: clear, the size of the one it stands over, and able
/// to take the keys, which a window with no title bar can't by default.
final class FeedbackFrame: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
@Observable final class FeedbackStage {
    var up = false
    var sendRequests = 0
    /// The page in front, from the window's top left; nil for none.
    var page: CGRect?
}

/// The card where a question would stand: in the middle of the window, over
/// all of it dimmed on a browser's window (Question.swift), undimmed in
/// Settings or on a window with no page open.
private struct FeedbackLayer: View {
    var stage: FeedbackStage
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Color.clear.allowsHitTesting(false)
            if stage.up {
                if stage.page != nil {
                    // A borderless window of its own over the browser's,
                    // so it is cut to that window's corners by hand.
                    Color.black.opacity(Question.dim(scheme))
                        .clipShape(RoundedRectangle(cornerRadius: Radius.window, style: .continuous))
                        .contentShape(Rectangle())
                        .transition(Question.veil)
                }
                FeedbackForm(model: .shared, stage: stage)
                    .transition(Question.appear)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }
}

/// The card's drop (#251). A drop of file URLs alone lit the card for a
/// folder too, which then attached nothing, and passed over the files
/// Photos, Mail and browsers drag as promises. This one asks the drag's
/// pasteboard what it holds before lighting up, and the drop reads the
/// same pasteboard, so the card lights up only for what it attaches.
@MainActor
private struct FeedbackDrop: DropDelegate {
    @Binding var dropping: Bool

    private var board: NSPasteboard { NSPasteboard(name: .drag) }

    func validateDrop(info: DropInfo) -> Bool { FeedbackSheet.takes(board) }

    func dropEntered(info: DropInfo) { dropping = validateDrop(info: info) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: dropping ? .copy : .forbidden)
    }

    func dropExited(info: DropInfo) { dropping = false }

    func performDrop(info: DropInfo) -> Bool {
        dropping = false
        return FeedbackSheet.take(board)
    }
}

private struct FeedbackForm: View {
    @Bindable var model: FeedbackModel
    var stage: FeedbackStage
    @State private var state = Sending.idle
    @State private var error: String?
    @State private var dropping = false
    @FocusState private var writing: Bool
    private let attachmentInset: CGFloat = 4

    enum Sending { case idle, sending }

    var body: some View {
        form
            .frame(width: 460)
            .onAppear { writing = true }
            .onChange(of: stage.sendRequests) { _, _ in send() }
            .onChange(of: model.draft.message) { _, _ in error = nil }
            .onDrop(of: FeedbackSheet.dropTypes, delegate: FeedbackDrop(dropping: $dropping))
            .overlay {
                if dropping {
                    dropHere
                        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                        .transition(.opacity.animation(Motion.quick))
                }
            }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Send feedback")
                    .font(.system(size: 15, weight: .semibold))
            }

            HStack(spacing: 6) {
                ForEach(FeedbackKind.allCases) { kind in
                    Button(kind.title) { model.draft.kind = kind }
                        .buttonStyle(.yab(model.draft.kind == kind ? .primary : .secondary, .small))
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .topLeading) {
                    ThreadTextEditor(text: $model.draft.message)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .focused($writing)
                        .padding(.horizontal, 5)
                        .padding(.top, 7)
                        .padding(.bottom, 30)
                    if model.draft.message.isEmpty, !InputMethod.composing(focused: writing) {
                        Text(model.draft.kind.prompt)
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.muted)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: 140)
                .background(field)
                .overlay(alignment: .bottomLeading) {
                    if model.draft.files.count < FeedbackFile.most {
                        Button { FeedbackSheet.choose() } label: {
                            HStack(spacing: 5) {
                                Symbol("paperclip", size: 10.5)
                                Text("Attach files")
                            }
                        }
                        .buttonStyle(.yab(.quiet, .small, cornerRadius: Radius.control - attachmentInset)) // design: Nested corner follows the field's radius less its inset.
                        .padding(attachmentInset)
                    }
                }
                if let note = error ?? model.unreadNote {
                    Text(note)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.red)
                }
            }

            if !model.draft.files.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(model.draft.files) { file in
                            FileTile(file: file) { model.remove(file) }
                                .transition(.scale(scale: 0.9).combined(with: .opacity))
                        }
                        if model.draft.files.count < FeedbackFile.most {
                            Button { FeedbackSheet.choose() } label: {
                                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                                    .strokeBorder(Palette.faint, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                                    .overlay { Symbol("plus", size: 11).foregroundStyle(Palette.muted) }
                                    .frame(width: FileTile.side, height: FileTile.side)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .keyTip("Attach files")
                        }
                    }
                    if let tooMuch = model.tooMuch {
                        Text(tooMuch)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            TextField("", text: $model.draft.email, prompt: Text("Email, if you'd like a reply").foregroundStyle(Palette.muted))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(field)

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Include diagnostics", isOn: $model.draft.includeDiagnostics)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                Text("No page content or browsing history.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Text(footnote)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                Spacer()
                Button("Cancel") { FeedbackSheet.close() }
                    .buttonStyle(.yab(.quiet, .regular))
                    .keyboardShortcut(.cancelAction)
                Button(state == .sending ? "Sending…" : "Send") { send() }
                    .buttonStyle(.yab(.primary, .regular))
                    .shortcut(.feedbackSend)
                    .disabled(model.tooMuch != nil)
                    .opacity(model.tooMuch != nil ? 0.4 : 1)
            }
        }
        .padding(20 - CardFrame.inset)
        .cardFrame()
    }

    /// The version and macOS, and what is attached.
    private var footnote: String {
        let files = model.draft.files
        let head = "Yab \(Updater.version) · macOS \(Updater.system)"
        guard !files.isEmpty else { return head }
        return head + " · " + (files.count == 1 ? "1 file" : "\(files.count) files") + " · " + FeedbackFile.bytes(model.weight)
    }

    /// The whole card, while a file is held over it.
    private var dropHere: some View {
        ZStack {
            Palette.ground.opacity(0.9)
            RoundedRectangle(cornerRadius: Radius.control + 2, style: .continuous)
                .strokeBorder(Palette.muted, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .padding(10)
            VStack(spacing: 6) {
                Symbol("paperclip", size: 15).foregroundStyle(Palette.ink)
                Text("Drop to attach")
                    .font(.system(size: 13, weight: .medium))
                Text("Up to \(FeedbackFile.most) files, \(FeedbackFile.bytes(FeedbackFile.room)) together")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.muted)
            }
        }
        .allowsHitTesting(false)
    }

    private var field: some View {
        RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
            .fill(Palette.ink.opacity(0.04))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .strokeBorder(Palette.hairline, lineWidth: 1)
            )
    }

    private func send() {
        guard state == .idle, model.tooMuch == nil else { return }
        guard !model.draft.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error = "Write something first"
            writing = true
            return
        }
        state = .sending
        let sending = model.draft
        Task {
            if let said = await FeedbackSheet.send(sending) {
                state = .idle
                error = said
                return
            }
            FeedbackSheet.remember(email: sending.email)
            model.draft = FeedbackSheet.Draft()
            FeedbackSheet.close()
        }
    }
}

/// One attached file: a square with the picture, or the file's extension on
/// a tag in its kind's color, and its name and size under it.
private struct FileTile: View {
    static let side: CGFloat = 64
    let file: FeedbackFile
    let remove: () -> Void
    @State private var over = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        VStack(spacing: 3) {
            ZStack {
                shape.fill(Palette.ink.opacity(0.04))
                if let picture = file.picture {
                    Image(nsImage: picture)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: Self.side, height: Self.side)
                } else {
                    Text(file.ext)
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.4)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .background(tint, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
            }
            .frame(width: Self.side, height: Self.side)
            .clipShape(shape)
            .overlay(shape.strokeBorder(file.data == nil ? Color.red : Palette.hairline, lineWidth: file.data == nil ? 1.5 : 1))
            .overlay(alignment: .topTrailing) {
                if over || file.data == nil {
                    Button(action: remove) {
                        Symbol("xmark", size: 6.5, weight: .bold)
                            .foregroundStyle(Palette.ground)
                            .frame(width: 16, height: 16)
                            .background(Circle().fill(Palette.ink))
                            .overlay(Circle().strokeBorder(Palette.ground, lineWidth: 2).padding(-2))
                    }
                    .buttonStyle(.plain)
                    .offset(x: 5, y: -5)
                    .keyTip("Remove")
                    .transition(.opacity.animation(Motion.quick))
                }
            }
            Text(file.name)
                .font(.system(size: 10.5))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: Self.side)
            Text(FeedbackFile.bytes(file.size))
                .font(.system(size: 10))
                .foregroundStyle(Palette.muted)
        }
        .onHover { over = $0 }
        .keyTip(file.name)
    }

    /// The tag's color, by what kind of file it is.
    private var tint: Color {
        guard let type = file.type else { return Palette.ink }
        if type.conforms(to: .pdf) { return Color(red: 0.64, green: 0.18, blue: 0.18) }
        if type.conforms(to: .audiovisualContent) { return Color(red: 0.33, green: 0.29, blue: 0.72) }
        if type.conforms(to: .archive) { return Color(red: 0.52, green: 0.31, blue: 0.04) }
        if type.conforms(to: .text) || type.conforms(to: .json) || type.conforms(to: .log) { return Color(red: 0.37, green: 0.37, blue: 0.35) }
        return Palette.ink
    }
}
