import AppKit
import Quartz
import SwiftUI
import UniformTypeIdentifiers
import WebKit

// A mail's files in its thread (docs/mail.md, Files): a row of chips under
// its words, each the Finder's mark for its kind, its name and its size. A
// click chooses one, a second opens it in its app, a drag puts it in the
// Finder (a file promise, fetched as it lands when it isn't here yet).
// Chosen, Space looks at it with Quick Look, ↩ opens it, ⌘S saves it to
// Downloads, ← and → choose the next (MailDesk). The pictures a mail's words
// draw by Content-ID come from the same files, through a scheme of Yab's own
// (MailCid).

/// A message's files under its words, a chip each.
struct MailFileChips: View {
    let message: MailDesk.Message
    var desk: MailDesk

    var body: some View {
        MailChipFlow(spacing: 6) {
            ForEach(message.files, id: \.part) { file in
                MailFileChip(file: file, message: message, desk: desk)
            }
        }
    }
}

/// One file: its mark, its name cut in the middle (its kind stays), its
/// size. Chosen, a ring; being fetched, paler; one Gmail wouldn't give
/// says so where its size was, the chip as wide as before.
private struct MailFileChip: View {
    let file: MailFile
    let message: MailDesk.Message
    var desk: MailDesk
    @State private var hovering = false

    var body: some View {
        let chip = MailDesk.Chip(message: message.id, part: file.part)
        let chosen = desk.chip == chip
        let failed = desk.failed.contains(chip)
        let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        HStack(spacing: 8) {
            Image(nsImage: MailFiles.icon(file))
                .resizable()
                .frame(width: 16, height: 16)
            Text(file.name)
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 240, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            ZStack(alignment: .leading) {
                Text(file.said).hidden()
                Text("Failed").hidden()
                Text(failed ? "Failed" : file.said).foregroundStyle(failed ? Color(nsColor: .systemRed) : Palette.muted)
            }
            .font(.system(size: 11.5).monospacedDigit())
            // "668 bytes", an invitation's invite.ics, on one line as "340 KB" is.
            .lineLimit(1)
            .fixedSize()
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(shape.fill(Palette.wash))
        .overlay(shape.fill(Palette.ink.opacity(hovering || chosen ? 0.04 : 0)))
        .overlay(shape.strokeBorder(Palette.ink.opacity(chosen ? 0.22 : 0), lineWidth: 1))
        .opacity(desk.getting.contains(chip) ? 0.55 : 1)
        .overlay {
            MailFileHandle(chip: chip, account: message.account, file: file, hovering: $hovering) {
                desk.choose(chip)
            } open: {
                desk.choose(chip)
                desk.openFile()
            }
        }
        .pointerTip(file.name + " · " + file.said)
    }
}

/// Chips a line at a time, onto the next when a line is full, each as wide
/// as it is.
struct MailChipFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += line + spacing; line = 0 }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: min(size.width, bounds.width), height: size.height))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

// MARK: - the pointer on a chip

/// What the pointer does on a chip, in AppKit: a click, two, and a drag
/// out of the window with the file promised to wherever it lands.
private struct MailFileHandle: NSViewRepresentable {
    let chip: MailDesk.Chip
    let account: String
    let file: MailFile
    @Binding var hovering: Bool
    let choose: () -> Void
    let open: () -> Void

    func makeNSView(context: Context) -> MailFileHandleView {
        let view = MailFileHandleView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: MailFileHandleView, context: Context) {
        view.chip = chip
        view.account = account
        view.file = file
        view.choose = choose
        view.open = open
        view.hover = { on in if hovering != on { hovering = on } }
        if MailFileHandleView.live.count > 200 { MailFileHandleView.live = MailFileHandleView.live.filter { $0.value.view != nil } }
        MailFileHandleView.live[chip] = WeakHandle(view: view)
    }
}

struct WeakHandle {
    weak var view: MailFileHandleView?
}

final class MailFileHandleView: NSView, NSDraggingSource {
    var chip: MailDesk.Chip?
    var account = ""
    var file: MailFile?
    var choose: (() -> Void)?
    var open: (() -> Void)?
    var hover: ((Bool) -> Void)?
    private var down: NSEvent?
    private var tracking: NSTrackingArea?
    /// The file promised by the drag under way.
    private var promised: MailFilePromise?

    /// Each chip's view, for where a file saved flies from (MailDesk.saveFile).
    @MainActor static var live: [MailDesk.Chip: WeakHandle] = [:]

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hover?(true) }
    override func mouseExited(with event: NSEvent) { hover?(false) }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            down = nil
            open?()
        } else {
            down = event
            choose?()
        }
    }

    override func mouseUp(with event: NSEvent) { down = nil }

    override func mouseDragged(with event: NSEvent) {
        guard let down, let file, let chip else { return }
        let from = down.locationInWindow, now = event.locationInWindow
        guard hypot(now.x - from.x, now.y - from.y) > 3 else { return }
        self.down = nil
        let promise = MailFilePromise(account: account, message: chip.message, file: file)
        let provider = NSFilePromiseProvider(fileType: file.type.identifier, delegate: promise)
        // The provider holds its delegate weakly: kept until it is written.
        MailFilePromise.held.insert(promise)
        promised = promise
        let item = NSDraggingItem(pasteboardWriter: provider)
        let icon = NSWorkspace.shared.icon(for: file.type)
        let at = convert(down.locationInWindow, from: nil)
        item.setDraggingFrame(CGRect(x: at.x - 16, y: at.y - 16, width: 32, height: 32), contents: icon)
        beginDraggingSession(with: [item], event: down, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }

    /// Dropped nowhere: nothing will be written, the promise let go.
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if operation.isEmpty, let promised { MailFilePromise.held.remove(promised) }
        promised = nil
    }

    /// The middle of the chip, in its window.
    var center: CGPoint { convert(CGPoint(x: bounds.midX, y: bounds.midY), to: nil) }
}

/// A file dragged out of a thread, written where it lands: the copy kept
/// here, or fetched from Gmail first.
final class MailFilePromise: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {
    let account: String
    let message: String
    let file: MailFile
    /// Promises given and not yet kept.
    @MainActor static var held: Set<MailFilePromise> = []
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    init(account: String, message: String, file: MailFile) {
        self.account = account
        self.message = message
        self.file = file
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        MailFiles.safe(file.name)
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        let account = account, message = message, file = file
        Task { @MainActor in
            defer { MailFilePromise.held.remove(self) }
            guard let engine = MailCenter.shared.engines[account], let files = MailFiles.of(engine.store, engine.provider) else {
                return completionHandler(CocoaError(.fileWriteUnknown))
            }
            completionHandler(await MailFilePromise.write(file, of: message, from: files, to: url))
        }
    }

    /// The file, kept or fetched, copied where it was dropped; what went
    /// wrong, or nil.
    static func write(_ file: MailFile, of message: String, from files: MailFiles, to url: URL) async -> Error? {
        do {
            let kept = try await files.file(file, message: message)
            try FileManager.default.copyItem(at: kept, to: url)
            return nil
        } catch {
            return error
        }
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { queue }
}

// MARK: - Quick Look

/// Quick Look on a mail's file (Space on a chip): the panel macOS draws,
/// its one item the file kept here. The panel takes as its controller the
/// first in the keyboard's line that will have it: a still view under the
/// thread (MailLookAnchor) steps into that place while it is up.
@MainActor
final class MailLook: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = MailLook()
    /// What it was last asked to show; nil once put away.
    private(set) var item: URL?
    weak var anchor: MailLookAnchor?

    /// The panel is on screen.
    var visible: Bool { QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible }

    func show(_ url: URL) {
        item = url
        let panel = QLPreviewPanel.shared()!
        if panel.isVisible, panel.dataSource === self {
            panel.reloadData()
            return
        }
        if let anchor, let window = anchor.window { window.makeFirstResponder(anchor) }
        // A Yab in front makes it the key window, as the Finder's is; one
        // behind (a test world on its own screen) only shows it.
        if NSApp.isActive { panel.makeKeyAndOrderFront(nil) } else { panel.orderFront(nil) }
    }

    func close() {
        item = nil
        if QLPreviewPanel.sharedPreviewPanelExists() {
            let panel = QLPreviewPanel.shared()!
            // End Quick Look's presentation, including an opening panel whose
            // item is already selected but which is not yet visible.
            panel.close()
        }
    }

    /// The panel let go of its controller: put away. A draft's chip looked
    /// at, the keyboard back in its words, never left on the anchor, where
    /// a letter typed would be one of mail's keys.
    func ended() {
        item = nil
        MailDesk.shared.wordsAgain()
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { item == nil ? 0 : 1 }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated { item.map { $0 as NSURL } }
    }
}

/// Under a thread, still and unseen: Quick Look's controller while it is up.
final class MailLookAnchor: NSView {
    override var acceptsFirstResponder: Bool { true }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = MailLook.shared
            panel.delegate = MailLook.shared
            panel.reloadData()
        }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
            MailLook.shared.ended()
        }
    }
}

/// The thread's anchor for Quick Look.
struct MailLookSpot: NSViewRepresentable {
    func makeNSView(context: Context) -> MailLookAnchor {
        let view = MailLookAnchor()
        MailLook.shared.anchor = view
        return view
    }

    func updateNSView(_ view: MailLookAnchor, context: Context) {
        MailLook.shared.anchor = view
    }
}

// MARK: - pictures by Content-ID

/// A mail's pictures by Content-ID for its web view (MailBody):
/// yab-mail-cid:<account>/<message>/<id> (MailHTML.pictures), the file kept
/// on this Mac, fetched from Gmail first when it isn't (MailFiles.picture).
final class MailCid: NSObject, WKURLSchemeHandler {
    /// A picture's bytes and kind by whose mail it is and its Content-ID.
    typealias Find = @MainActor (_ account: String, _ message: String, _ cid: String) async -> (data: Data, mime: String)?
    private let find: Find
    /// Tasks the web view still wants: one it stopped is answered no more.
    private var live: Set<ObjectIdentifier> = []
    /// Pictures served, for the bench.
    @MainActor static var served = 0

    init(find: @escaping Find = MailCid.kept) {
        self.find = find
    }

    /// From the account's files on this Mac, or Gmail.
    @MainActor static func kept(account: String, message: String, cid: String) async -> (data: Data, mime: String)? {
        guard let engine = MailCenter.shared.engines[account], let files = MailFiles.of(engine.store, engine.provider),
              let found = try? await files.picture(message: message, cid: cid), let data = try? Data(contentsOf: found.url) else { return nil }
        return (data, found.mime)
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let key = ObjectIdentifier(task)
        // Only pictures of the mail the view shows: an address in this
        // scheme written into a mail's own HTML names no other mail's files.
        guard let url = task.request.url, let wanted = MailHTML.picture(url),
              (webView as? MailBodyView)?.message == wanted.message else {
            return task.didFailWithError(URLError(.badURL))
        }
        live.insert(key)
        let find = find
        Task { @MainActor in
            let got = await find(wanted.account, wanted.message, wanted.cid)
            guard live.remove(key) != nil else { return }
            guard let got else { return task.didFailWithError(URLError(.fileDoesNotExist)) }
            task.didReceive(URLResponse(url: url, mimeType: got.mime, expectedContentLength: got.data.count, textEncodingName: nil))
            task.didReceive(got.data)
            task.didFinish()
            MailCid.served += 1
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        live.remove(ObjectIdentifier(task))
    }
}
