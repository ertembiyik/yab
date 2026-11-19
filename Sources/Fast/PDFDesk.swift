import AppKit
import PDFKit
import WebKit
import YabCoreClient

// Fill and sign a PDF in its tab (docs/pdf-sign.md).
//
// Until Fill & Sign is pressed the PDF is WebKit's: its find, print, links
// and speed are left alone, and all Yab adds is the glass plate at the
// page's foot (PDFPaper). Pressed, the PDF's own bytes go into a PDFView
// laid over the web view (PDFDeskView.swift), and the mode lives here: the
// boxes of its form and what goes in each, the lines of text and the
// signatures put down, every step of it undone by ⌘Z, and Done, which
// writes a new file to Downloads with all of it pressed into the pages.

/// What the mode does now, as the bar's three words say.
enum PDFDeskMode: String, CaseIterable {
    case fill, text, sign

    var title: String {
        switch self {
        case .fill: "Fill"
        case .text: "Text"
        case .sign: "Sign"
        }
    }
}

@MainActor
@Observable final class PDFDesk {
    /// A step the mode took, and how to take it back and again.
    struct Step {
        let name: String
        let undo: () -> Void
        let redo: () -> Void
    }

    let document: PDFDocument
    /// The address the PDF came from, and the name it had there.
    let source: URL?
    let sourceName: String?

    private(set) var mode: PDFDeskMode = .fill
    @ObservationIgnored private(set) var boxes: [PDFBox]
    /// The box being filled, by its place in `boxes`.
    private(set) var current: Int?
    /// What the box being filled holds as it is typed.
    var draft = "" { didSet { if draft != oldValue { scheduleWorkingSave() } } }
    /// A line of text being typed, and its words so far.
    private(set) var writing: PDFAnnotation?
    var note = "" { didSet { if note != oldValue { scheduleWorkingSave() } } }
    /// A signature or a line of text picked: ⌫ takes it away, its corners resize it.
    private(set) var selected: PDFAnnotation?
    /// The sheet a signature is made on, and what is on it.
    var sheet = false
    let pad = SignatureSheetModel()
    /// Where the view shows an annotation: points under it and over it.
    @ObservationIgnored var room: ((PDFAnnotation) -> [CGFloat])?
    /// A place on a page brought into sight above the bar (for ./bench,
    /// whose pointer is no person's).
    @ObservationIgnored var bring: ((Int, CGRect) -> Void)?
    /// The same native page/zoom operation used by the persistence probe.
    @ObservationIgnored var position: ((Int, CGFloat, CGFloat, CGFloat) -> Void)?
    @ObservationIgnored var shownViewport: (() -> [String: Any])?
    /// The signature Sign puts down.
    private(set) var signature: Signature?
    /// Where a signature follows the pointer, in a PDF with no box for one.
    var ghost: (page: Int, point: CGPoint)?
    /// The page last written or signed on, for the signed file to open at.
    @ObservationIgnored private(set) var lastPage = 0
    /// Every change to what is drawn, for the view over the page.
    private(set) var version = 0

    @ObservationIgnored private(set) var steps: [Step] = []
    @ObservationIgnored private(set) var undone: [Step] = []
    /// Something was filled, typed or signed: esc asks before throwing it away.
    var changed: Bool { restoredChanges || !steps.isEmpty || writingChanged || draftChanged }

    let profile: Profile
    let address: StreetAddress?
    let today: Date
    let shelf: SignatureShelf
    /// The scroll the web view was at as the mode began, as a share of the
    /// document's height, for the PDFView to start at.
    @ObservationIgnored var startedAt: CGFloat?

    init(document: PDFDocument, source: URL?, name: String? = nil, profile: Profile = Profile.load(),
         address: StreetAddress? = nil, today: Date = Date(), shelf: SignatureShelf = SignatureKeychain.shared) {
        self.document = document
        self.source = source
        sourceName = name
        self.profile = profile
        self.address = address
        self.today = today
        self.shelf = shelf
        boxes = PDFFill.boxes(document)
        // PDFKit washes an empty signature box blue of its own: the mode
        // draws its own wash, and Done leaves no box to wash.
        for box in boxes where box.kind == .signature { box.annotation.shouldDisplay = false }
        signature = shelf.all().first { !$0.initials }
        // A PDF with nothing to fill starts where a line of text goes in.
        if boxes.contains(where: { $0.kind != .signature }) {
            mode = .fill
            current = firstEmpty
            draft = current.map { boxes[$0].value } ?? ""
        } else {
            mode = .text
        }
    }

    private func changedNow() {
        version &+= 1
        scheduleWorkingSave()
    }

    // MARK: - the editable working copy

    @ObservationIgnored private var working: PDFWorkingCopy?
    @ObservationIgnored private var pendingSave: DispatchWorkItem?
    @ObservationIgnored private var workingState: PDFWorkingState?
    @ObservationIgnored private var contentNeedsSave = true
    @ObservationIgnored private var restoredChanges = false
    @ObservationIgnored private var discardWorking = false
    @ObservationIgnored private var workingActive = true
    @ObservationIgnored var mailOrigin: PDFMailOrigin? { didSet { scheduleWorkingSave() } }
    @ObservationIgnored private var quitWatch: NSObjectProtocol?
    @ObservationIgnored private(set) var viewport: PDFWorkingState.Viewport?
    @ObservationIgnored private(set) var restored = false
    @ObservationIgnored private(set) var saveError: String?
    @ObservationIgnored private(set) var snapshots = 0

    /// A restored mode keeps its editor drafts separate from committed PDF
    /// values. Neither saving nor reopening commits an Undo step.
    func keepWorking(in copy: PDFWorkingCopy, restoring state: PDFWorkingState?) {
        working = copy
        if let state {
            restoreWorking(state)
            restored = true
        }
        quitWatch = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushWorking(wait: true) }
        }
        scheduleWorkingSave()
    }

    deinit {
        pendingSave?.cancel()
        if let quitWatch { NotificationCenter.default.removeObserver(quitWatch) }
    }

    private func scheduleWorkingSave(content: Bool = true) {
        guard working != nil, !discardWorking else { return }
        contentNeedsSave = contentNeedsSave || content
        pendingSave?.cancel()
        // Keep the final pending edit alive if its tab is closed before the
        // debounce fires; the scheduled block releases it after the flush.
        let work = DispatchWorkItem { [self] in flushWorking() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    func movedViewport(_ value: PDFWorkingState.Viewport) {
        guard value != viewport, value.scale.isFinite, value.scale > 0,
              value.point.x.isFinite, value.point.y.isFinite,
              (0..<document.pageCount).contains(value.page) else { return }
        viewport = value
        scheduleWorkingSave(content: false)
    }

    func flushWorking(wait: Bool = false, active: Bool? = nil) {
        pendingSave?.cancel()
        pendingSave = nil
        guard let working, !discardWorking else { return }
        if contentNeedsSave || workingState == nil {
            workingState = captureWorking()
            snapshots += 1
            contentNeedsSave = false
        }
        guard var state = workingState else { return }
        if let active { workingActive = active }
        state.viewport = viewport
        state.active = workingActive && (changed || writing != nil)
        workingState = state
        working.save(state, wait: wait) { [weak self] error in
            if let error { NSLog("PDF working copy: %@", error) }
            DispatchQueue.main.async { self?.saveError = error }
        }
    }

    /// Only the confirmed Discard action removes the working copy. A tab
    /// releasing its view or navigating elsewhere saves it first.
    func discardWorkingCopy() {
        discardWorking = true
        pendingSave?.cancel()
        pendingSave = nil
        working?.discard()
    }

    private func captureWorking() -> PDFWorkingState {
        var marks: [PDFWorkingState.Mark] = []
        var positions: [ObjectIdentifier: Int] = [:]
        var writingIndex: Int?
        for index in 0..<document.pageCount {
            for (offset, annotation) in (document.page(at: index)?.annotations ?? []).enumerated() {
                positions[ObjectIdentifier(annotation)] = offset
                guard Self.ours(annotation) else { continue }
                if annotation === writing { writingIndex = marks.count }
                marks.append(PDFWorkingState.Mark(page: index, bounds: annotation.bounds,
                    text: annotation.contents ?? "", font: annotation.font?.fontName,
                    size: annotation.font?.pointSize ?? 12, signature: (annotation as? PDFSignatureStamp)?.png))
            }
        }
        let fields = boxes.map { box in
            PDFWorkingState.Field(page: box.page, annotation: positions[ObjectIdentifier(box.annotation)] ?? -1,
                name: box.name, value: box.annotation.widgetStringValue ?? "",
                button: Int(box.annotation.buttonWidgetState.rawValue))
        }
        return PDFWorkingState(fields: fields, marks: marks, mode: mode.rawValue, current: current, draft: draft,
            writing: writingIndex, note: note, lastPage: lastPage, changed: changed, viewport: viewport, mail: mailOrigin)
    }

    private func restoreWorking(_ state: PDFWorkingState) {
        for field in state.fields {
            guard let page = document.page(at: field.page), page.annotations.indices.contains(field.annotation) else { continue }
            let annotation = page.annotations[field.annotation]
            guard annotation.fieldName == field.name, let box = boxes.first(where: { $0.annotation === annotation }) else { continue }
            if box.kind == .check || box.kind == .radio {
                annotation.buttonWidgetState = PDFWidgetCellState(rawValue: field.button) ?? .offState
            } else { PDFFill.put(field.value, in: box) }
        }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations where Self.ours(annotation) { page.removeAnnotation(annotation) }
        }
        var made: [PDFAnnotation?] = []
        for mark in state.marks {
            guard let page = document.page(at: mark.page) else { made.append(nil); continue }
            let annotation: PDFAnnotation
            if let png = mark.signature {
                annotation = PDFSignatureStamp(Signature(id: mark.text, png: png, initials: false), bounds: mark.bounds)
            } else {
                annotation = PDFFill.textAnnotation(mark.text, at: mark.bounds.origin, size: mark.size)
                annotation.bounds = mark.bounds
                annotation.font = mark.font.flatMap { NSFont(name: $0, size: mark.size) } ?? .systemFont(ofSize: mark.size)
            }
            page.addAnnotation(annotation)
            made.append(annotation)
        }
        mode = PDFDeskMode(rawValue: state.mode) ?? .fill
        current = state.current.flatMap { boxes.indices.contains($0) ? $0 : nil }
        draft = state.draft
        writing = state.writing.flatMap { made.indices.contains($0) ? made[$0] : nil }
        writing?.shouldDisplay = false
        note = state.note
        lastPage = min(max(0, state.lastPage), max(0, document.pageCount - 1))
        viewport = state.viewport
        restoredChanges = state.changed
        mailOrigin = state.mail
    }

    // MARK: - modes

    func set(_ mode: PDFDeskMode) {
        guard mode != self.mode else {
            if mode == .sign, signature == nil { openSheet() }
            return
        }
        commitField()
        commitNote()
        self.mode = mode
        selected = nil
        ghost = nil
        if mode == .fill, current == nil { focus(firstEmpty) }
        if mode != .fill { current = nil }
        // The first Sign: the sheet a signature is made on.
        if mode == .sign, signature == nil { openSheet() }
        changedNow()
    }

    // MARK: - Fill

    /// The boxes Tab walks: the ones words or a choice go into.
    private var typed: [Int] { boxes.indices.filter { boxes[$0].kind == .text || boxes[$0].kind == .choice } }

    var firstEmpty: Int? { typed.first { boxes[$0].empty } ?? typed.first }

    var signatureBoxes: [Int] { boxes.indices.filter { boxes[$0].kind == .signature } }

    func hint(_ index: Int) -> String? {
        guard boxes.indices.contains(index) else { return nil }
        return PDFFill.hint(for: boxes[index], profile: profile, address: address, today: today)
    }

    /// The gray words the box being filled shows while nothing is typed.
    var ghostWords: String? {
        guard mode == .fill, let current, draft.isEmpty else { return nil }
        return hint(current)
    }

    private var draftChanged: Bool {
        guard let current else { return false }
        return draft != boxes[current].value
    }

    /// The keyboard in a box: what was typed in the one before is kept.
    func focus(_ index: Int?) {
        commitField()
        if let index, !boxes.indices.contains(index) { return }
        current = index
        draft = index.map { boxes[$0].value } ?? ""
        selected = nil
        changedNow()
    }

    /// What the box being filled holds, put in, as one step.
    func commitField() {
        guard let current, draftChanged else { return }
        let box = boxes[current]
        let before = box.value, after = draft
        apply(after, to: current)
        record("Fill \(box.label.isEmpty ? box.name : box.label)", undo: { [weak self] in self?.apply(before, to: current) },
               redo: { [weak self] in self?.apply(after, to: current) })
    }

    private func apply(_ value: String, to index: Int) {
        PDFFill.put(value, in: boxes[index])
        lastPage = boxes[index].page
        if current == index { draft = value }
        changedNow()
    }

    /// Return: the gray words taken, or what was typed kept, and on to the next box.
    func enter() {
        guard let current else { return }
        if draft.isEmpty, let hint = hint(current) { draft = hint }
        step(1)
    }

    /// Tab and ⇧Tab: the next box, or the one before; past the last, none.
    func step(_ by: Int) {
        let walk = typed
        guard let current, let at = walk.firstIndex(of: current) else { return focus(firstEmpty) }
        let next = at + by
        focus(walk.indices.contains(next) ? walk[next] : nil)
    }

    /// A tick, or a choice of a group of them, as one step.
    func toggle(_ index: Int) {
        guard boxes.indices.contains(index), boxes[index].kind == .check || boxes[index].kind == .radio else { return }
        commitField()
        let box = boxes[index]
        let before = boxes.filter { $0.name == box.name || $0.annotation === box.annotation }.map { ($0.annotation, $0.annotation.buttonWidgetState) }
        let on = box.kind == .radio ? true : box.annotation.buttonWidgetState != .onState
        let all = boxes
        PDFFill.tick(box, on: on, among: all)
        changedNow()
        record(on ? "Tick" : "Untick", undo: { [weak self] in
            for (widget, state) in before { widget.buttonWidgetState = state }
            self?.changedNow()
        }, redo: { [weak self] in
            PDFFill.tick(box, on: on, among: all)
            self?.changedNow()
        })
    }

    /// One of a list box's choices, as one step.
    func choose(_ index: Int, _ value: String) {
        guard boxes.indices.contains(index) else { return }
        focus(index)
        draft = value
        commitField()
    }

    // MARK: - Text

    private var writingChanged: Bool { writing != nil && !note.isEmpty }

    /// A line of text where the click was, the keyboard in it.
    @discardableResult
    func write(on pageIndex: Int, at point: CGPoint) -> PDFAnnotation? {
        guard let page = document.page(at: pageIndex) else { return nil }
        commitField()
        commitNote()
        let size = PDFFill.neighborSize(on: page, at: point)
        let made = PDFFill.textAnnotation("", at: point, size: size, width: 120)
        made.shouldDisplay = false
        page.addAnnotation(made)
        lastPage = pageIndex
        writing = made
        note = ""
        selected = nil
        changedNow()
        return made
    }

    /// A line of text already there, to type in again.
    func rewrite(_ annotation: PDFAnnotation) {
        commitField()
        commitNote()
        writing = annotation
        note = annotation.contents ?? ""
        annotation.shouldDisplay = false
        selected = nil
        changedNow()
    }

    /// The line being typed, put down as one step; with nothing typed, gone.
    func commitNote() {
        guard let writing, let page = writing.page else { self.writing = nil; return }
        self.writing = nil
        let before = writing.contents ?? ""
        let after = note
        writing.shouldDisplay = true
        if after.isEmpty {
            if before.isEmpty {
                page.removeAnnotation(writing)
            } else {
                // Emptied: taken away, as ⌫ would.
                remove(writing)
            }
            changedNow()
            return
        }
        guard after != before else { changedNow(); return }
        let font = writing.font ?? .systemFont(ofSize: 12)
        let grown = Self.fit(after, font: font, in: writing.bounds)
        let was = writing.bounds
        writing.contents = after
        writing.bounds = grown
        changedNow()
        if before.isEmpty {
            record("Add Text", undo: { [weak self] in page.removeAnnotation(writing); self?.unpick(writing) },
                   redo: { [weak self] in page.addAnnotation(writing); self?.changedNow() })
        } else {
            record("Edit Text", undo: { [weak self] in writing.contents = before; writing.bounds = was; self?.changedNow() },
                   redo: { [weak self] in writing.contents = after; writing.bounds = grown; self?.changedNow() })
        }
    }

    /// A line's box grown to hold its words, its left and middle kept.
    static func fit(_ text: String, font: NSFont, in bounds: CGRect) -> CGRect {
        let size = (text as NSString).size(withAttributes: [.font: font])
        let width = max(bounds.width, ceil(size.width) + 8)
        return CGRect(x: bounds.minX, y: bounds.minY, width: width, height: bounds.height)
    }

    // MARK: - Sign

    /// The sheet, empty, for a signature or for initials.
    func openSheet(initials: Bool = false) {
        pad.initials = initials
        pad.ink = PenInk()
        pad.name = initials ? SignatureSheetModel.initials(of: profile.name) : profile.name
        sheet = true
    }

    /// The sheet's Done: what is on it kept, and the one Sign puts down.
    func finishSheet() {
        guard sheet, let png = pad.png() else { return }
        adopt(png, initials: pad.initials)
    }

    /// A signature made on the sheet, kept and the one Sign puts down.
    func adopt(_ png: Data, initials: Bool = false) {
        guard let kept = shelf.keep(png, initials: initials) else {
            // The keychain said no: used for this file all the same.
            signature = Signature(id: initials ? "Yab Initials" : "Yab Signature", png: png, initials: initials)
            sheet = false
            changedNow()
            return
        }
        if !initials || signature == nil { signature = kept }
        sheet = false
        changedNow()
    }

    /// Another of the kept signatures, for Sign to put down.
    func use(_ kept: Signature) {
        signature = kept
        changedNow()
    }

    var kept: [Signature] { shelf.all() }

    /// The signature put down: fitted into a signature box, or as tall as a
    /// line where the click was.
    @discardableResult
    func sign(on pageIndex: Int, at point: CGPoint) -> PDFAnnotation? {
        guard let signature else { openSheet(); return nil }
        guard let page = document.page(at: pageIndex) else { return nil }
        commitField()
        commitNote()
        let box = signatureBoxes.map { boxes[$0] }.first { $0.page == pageIndex && $0.bounds.insetBy(dx: -4, dy: -4).contains(point) }
        let rect = box.map { signature.fitted(in: $0.bounds) } ?? signature.standing(at: point)
        let stamp = PDFSignatureStamp(signature, bounds: rect.integral)
        page.addAnnotation(stamp)
        lastPage = pageIndex
        selected = stamp
        ghost = nil
        changedNow()
        record("Sign", undo: { [weak self] in page.removeAnnotation(stamp); self?.unpick(stamp) },
               redo: { [weak self] in page.addAnnotation(stamp); self?.changedNow() })
        return stamp
    }

    // MARK: - what was put down

    /// Ours: signatures and lines of text the mode put on the pages.
    static func ours(_ annotation: PDFAnnotation) -> Bool {
        annotation is PDFSignatureStamp || (annotation.type == "FreeText" && annotation.value(forAnnotationKey: .textLabel) as? String == "Yab")
    }

    func pick(_ annotation: PDFAnnotation?) {
        commitField()
        if writing !== annotation { commitNote() }
        selected = annotation
        changedNow()
    }

    private func unpick(_ annotation: PDFAnnotation) {
        if selected === annotation { selected = nil }
        changedNow()
    }

    /// Moved or resized, as one step once the hand lets go.
    func moved(_ annotation: PDFAnnotation, from before: CGRect) {
        let after = annotation.bounds
        guard after != before else { return }
        changedNow()
        record(annotation is PDFSignatureStamp ? "Move Signature" : "Move Text", undo: { [weak self] in
            annotation.bounds = before
            self?.changedNow()
        }, redo: { [weak self] in
            annotation.bounds = after
            self?.changedNow()
        })
    }

    /// Live, while dragged: no step until it is let go (`moved`).
    func drag(_ annotation: PDFAnnotation, to rect: CGRect) {
        annotation.bounds = rect
        changedNow()
    }

    /// ⌫: the picked one taken away, as one step.
    func deleteSelected() {
        guard let selected else { return }
        remove(selected)
    }

    private func remove(_ annotation: PDFAnnotation) {
        guard let page = annotation.page else { return }
        page.removeAnnotation(annotation)
        unpick(annotation)
        record("Delete", undo: { [weak self] in page.addAnnotation(annotation); self?.changedNow() },
               redo: { [weak self] in page.removeAnnotation(annotation); self?.unpick(annotation) })
    }

    // MARK: - undo

    private func record(_ name: String, undo: @escaping () -> Void, redo: @escaping () -> Void) {
        steps.append(Step(name: name, undo: undo, redo: redo))
        undone = []
    }

    /// ⌘Z: the last step taken back. What is being typed goes first.
    func undo() {
        if let current, draftChanged {
            draft = boxes[current].value
            changedNow()
            return
        }
        if let writing {
            let kept = writing.contents ?? ""
            if note != kept {
                note = kept
                changedNow()
                return
            }
            commitNote()
        }
        guard let last = steps.popLast() else { return }
        last.undo()
        undone.append(last)
        if let current { draft = boxes[current].value }
        changedNow()
    }

    /// ⇧⌘Z: taken again.
    func redo() {
        guard let next = undone.popLast() else { return }
        next.redo()
        steps.append(next)
        if let current { draft = boxes[current].value }
        changedNow()
    }

    // MARK: - Done

    /// Everything typed put in, and the file made: the pages with it all
    /// pressed in.
    func finish() -> Data? {
        commitField()
        commitNote()
        current = nil
        selected = nil
        ghost = nil
        return PDFFill.flattened(document)
    }

    /// The mode as ./bench sees it.
    var report: [String: Any] {
        var out: [String: Any] = [
            "mode": mode.rawValue, "steps": steps.map(\.name), "undone": undone.count, "changed": changed,
            "sheet": sheet, "signature": signature?.id ?? "", "draft": draft, "note": note,
            "restored": restored, "workingSnapshots": snapshots, "workingError": saveError ?? "",
            "boxes": boxes.enumerated().map { index, box -> [String: Any] in
                ["name": box.name, "label": box.label, "kind": box.kind.rawValue, "page": box.page, "value": box.value,
                 "hint": hint(index) ?? "", "bounds": [box.bounds.minX, box.bounds.minY, box.bounds.width, box.bounds.height]]
            },
        ]
        out["shownViewport"] = shownViewport?()
        if let viewport {
            out["viewport"] = ["page": viewport.page, "x": viewport.point.x, "y": viewport.point.y, "scale": viewport.scale]
        }
        out["current"] = current.map { boxes[$0].name } ?? ""
        out["ghost"] = ghostWords ?? ""
        out["writing"] = writing != nil
        out["selected"] = selected.map { $0 is PDFSignatureStamp ? "signature" : "text" } ?? ""
        var placed: [[String: Any]] = []
        for index in 0..<document.pageCount {
            for annotation in document.page(at: index)?.annotations ?? [] where Self.ours(annotation) {
                placed.append(["page": index, "kind": annotation is PDFSignatureStamp ? "signature" : "text",
                               "text": annotation.contents ?? "",
                               "bounds": [annotation.bounds.minX, annotation.bounds.minY, annotation.bounds.width, annotation.bounds.height]])
            }
        }
        out["placed"] = placed
        // The current box's and the picked one's place on screen: above the
        // bar's room, below the air at the top.
        if let room {
            if let current { out["currentRoom"] = room(boxes[current].annotation) }
            if let selected { out["selectedRoom"] = room(selected) }
            if let first = signatureBoxes.first { out["signatureRoom"] = room(boxes[first].annotation) }
        }
        return out
    }
}

// MARK: - the sheet

/// How a signature is made on the sheet.
enum SignatureWay: String, Hashable { case trackpad, mouse, type }

/// What is on the signature sheet: kept apart from the desk, so each point
/// drawn redraws the pad and not the pages.
@MainActor
@Observable final class SignatureSheetModel {
    var way = SignatureWay.trackpad
    var ink = PenInk()
    var name = ""
    var hand = SignatureInk.hands[0]
    @ObservationIgnored var initials = false

    var empty: Bool { way == .type ? name.trimmingCharacters(in: .whitespaces).isEmpty : ink.isEmpty }

    func png() -> Data? {
        way == .type ? Signature.picture(typing: name, hand: hand) : Signature.picture(of: ink)
    }

    func clear() {
        if way == .type { name = "" } else { ink = PenInk() }
    }

    static func initials(of name: String) -> String {
        let letters = name.split(separator: " ").compactMap { $0.first.map(String.init) }
        return letters.isEmpty ? "" : letters.joined(separator: ".") + "."
    }
}

// MARK: - the tab's PDF

/// Where a PDF in a tab came from in Mail: the thread its reply goes to.
struct PDFMailOrigin: Codable, Equatable {
    var account: String
    var thread: String
    var message: String
}

/// A tab's PDF, as Fill & Sign sees it: whether the page in front is one,
/// whether it has boxes to fill, the mode while it is on, and the file
/// Done made while the tab shows it.
@MainActor
@Observable final class PDFPaper {
    private(set) var pdf = false
    private(set) var fillable = false
    /// The pointer by the page's foot: the plate shows on a PDF with no boxes.
    var near = false
    private(set) var desk: PDFDesk?
    /// The file Done made, while the tab shows it.
    private(set) var signed: URL?
    /// Opened from a mail: Done's corner offers the reply.
    var mail: PDFMailOrigin? { didSet { desk?.mailOrigin = mail } }
    private(set) var starting = false
    /// The last main document's answer said PDF.
    @ObservationIgnored private var heardPDF = false
    @ObservationIgnored private var nativeAnalysis = ChromiumOriginalPDFAnalysisState()
    @ObservationIgnored private var generation = 0
    /// Timings, for ./bench.
    @ObservationIgnored private(set) var metrics: [String: Double] = [:]

    /// Every type WebKit takes for a PDF (its MIMETypeRegistry's PDF
    /// types), not only application/pdf: a PDF a server sent as text/pdf,
    /// opened behind, was laid out at no width and shown as a strip of
    /// thumbnails until reloaded (register 1304, evals/pdf/blank.py's
    /// 14-text-pdf).
    static let types: Set<String> = ["application/pdf", "application/x-pdf", "text/pdf", "text/x-pdf",
                                     "application/acrobat", "applications/vnd.pdf", "application/vnd.pdf"]

    /// The main document's answer: a PDF or not, known before it commits.
    func heard(_ response: URLResponse) -> Bool {
        heardPDF = response.mimeType.map { Self.types.contains($0.lowercased()) } ?? false
            || (response.mimeType == nil && response.url?.pathExtension.lowercased() == "pdf")
        return heardPDF
    }

    /// A new document in the tab: what it is, and the mode gone with the old.
    func committed(_ url: URL?) {
        nativeAnalysis = ChromiumOriginalPDFAnalysisState()
        generation &+= 1
        starting = false
        desk?.flushWorking()
        pdf = heardPDF || (url?.isFileURL == true && url?.pathExtension.lowercased() == "pdf")
        fillable = false
        near = false
        if desk != nil { desk = nil }
        if let signed, url?.path != signed.path { self.signed = nil; mail = nil }
    }

    /// Loaded: WebKit says whether it is showing a PDF, and the PDF says
    /// whether it has a form.
    func finished(_ tab: Tab) {
        if let page = tab.builtPage as? ChromiumPage {
            page.restartOriginalPDFPresence()
            page.presentOriginalPDFPresence()
            return
        }
        guard let web = tab.webKitOnly("WebKit PDF data preservation", build: false) else { return }
        if web.webKitShowsPDF { pdf = true }
        guard pdf else { return }
        let expected = generation
        let source = tab.address
        let owner = tab.id
        PDFPaper.bytes(of: tab) { [weak self, weak tab] data in
            guard let self, let data else { return }
            Task.detached(priority: .utility) {
                let form = PDFDocument(data: data).map(PDFFill.fillable) ?? false
                let copy = PDFWorkingCopy(original: data, source: source, owner: owner)
                let state = copy.load()
                await MainActor.run {
                    guard self.generation == expected, let tab, tab.address == source else { return }
                    self.fillable = form
                    if state?.active == true, self.desk == nil, !self.starting { self.start(tab) }
                }
            }
        }
    }

    /// Unknown native metadata retires promotions, not the user's working copy.
    /// Chromium never enters committed(URL)'s WebKit file-extension heuristic.
    func nativePresenceUnavailable() {
        generation &+= 1
        starting = false
        heardPDF = false
        nativeAnalysis.unavailable()
        desk?.flushWorking()
        pdf = desk != nil
        fillable = false
        near = false
    }
    func nativePresenceReady(_ identity: OriginalPDFPresenceIdentity, tab: Tab,
                             page: ChromiumPage, visible: Bool) {
        guard tab.builtPage === page, page.originalPDFPresence.ready == identity else { return }
        if nativeAnalysis.source != identity {
            generation &+= 1
            starting = false
            fillable = false
        }
        pdf = true
        // Background subscription observes metadata only. The existing form
        // analysis starts when this original page is actually shown.
        switch nativeAnalysis.prepare(identity, visible: visible, hasDesk: desk != nil) {
        case .metadataOnly: return
        case .cached(let result):
            if let result { fillable = result }
            return
        case .read: break
        }
        let expected = generation, source = tab.address, owner = tab.id
        PDFPaper.bytes(of: tab) { [weak self, weak tab, weak page] data in
            guard let self, self.generation == expected, self.nativeAnalysis.source == identity else { return }
            guard let data else { self.nativeAnalysis.failed(identity); return }
            Task.detached(priority: .utility) {
                let form = PDFDocument(data: data).map(PDFFill.fillable) ?? false
                let copy = PDFWorkingCopy(original: data, source: source, owner: owner)
                let state = copy.load()
                await MainActor.run {
                    guard self.generation == expected, self.nativeAnalysis.source == identity,
                          let tab, let page, tab.builtPage === page,
                          page.originalPDFPresence.ready == identity else { return }
                    guard self.nativeAnalysis.complete(identity, form: form) else { return }
                    self.fillable = form
                    if state?.active == true, self.desk == nil, !self.starting { self.start(tab) }
                }
            }
        }
    }

    /// The plate stands at the page's foot: on a PDF with a form always,
    /// on any other while the pointer is near it, and as the mode's bar.
    var plateShown: Bool { pdf && (fillable || near || desk != nil) }

    // MARK: the bytes

    private static let nameSelector = NSSelectorFromString("_suggestedFilenameForDisplayedPDF")

    /// WebKit's main resource is the displayed response, including its PDF
    /// plugin data. _dataForDisplayedPDF is an iOS getter, absent on macOS.
    /// Bind this asynchronous read to the navigation, including same-URL reloads.
    static func displayedBytes(_ web: PageView, _ done: @escaping @MainActor (Data?) -> Void) {
        let selector = NSSelectorFromString("_getMainResourceDataWithCompletionHandler:")
        guard web.webKitShowsPDF, !web.isLoading, web.responds(to: selector) else { done(nil); return }
        let navigation = web.navigationEvents.documentNavigation
        let url = web.url
        typealias Reply = @convention(block) (NSData?, NSError?) -> Void
        typealias Read = @convention(c) (AnyObject, Selector, Reply) -> Void
        let reply: Reply = { [weak web] data, error in
            MainActor.assumeIsolated {
                guard let web, error == nil, !web.isLoading, web.webKitShowsPDF,
                      web.url == url, web.navigationEvents.documentNavigation == navigation,
                      let data, data.length > 0 else { done(nil); return }
                done(data as Data)
            }
        }
        unsafeBitCast(web.method(for: selector), to: Read.self)(web, selector, reply)
    }

    /// The PDF the tab shows, as it came: WebKit's own copy, or the same
    /// address read again with the tab's cookies.
    static func bytes(of tab: Tab, _ done: @escaping (Data?) -> Void) {
        if let page = tab.builtPage as? ChromiumPage {
            Task { @MainActor [weak page, weak tab] in
                guard let page, let tab, tab.builtPage === page else { done(nil); return }
                do {
                    let data = try await page.originalPDFBytes()
                    done(tab.builtPage === page ? data : nil)
                } catch { done(nil) }
            }
            return
        }
        guard let store = tab.webKitStore("Authenticated WebKit PDF source") else { return done(nil) }
        guard let web = tab.webKitOnly("WebKit PDF data preservation", build: false) else { done(nil); return }
        let source = tab.address
        displayedBytes(web) { data in
            guard tab.builtPage === web, tab.address == source else { done(nil); return }
            if let data { done(data); return }
            fetchWebKitBytes(of: tab, store: store, done)
        }
    }

    private static func fetchWebKitBytes(of tab: Tab, store: WKWebsiteDataStore, _ done: @escaping (Data?) -> Void) {
        guard let url = tab.address ?? tab.webKitOnly("WebKit PDF data preservation", build: false)?.url else { return done(nil) }
        if url.isFileURL {
            DispatchQueue.global(qos: .userInitiated).async {
                let data = try? Data(contentsOf: url)
                DispatchQueue.main.async { done(data) }
            }
            return
        }
        store.httpCookieStore.getAllCookies { cookies in
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage?.setCookies(cookies, for: url, mainDocumentURL: url)
            URLSession(configuration: config).dataTask(with: url) { data, _, _ in
                DispatchQueue.main.async { done(data) }
            }.resume()
        }
    }

    static func suggestedName(of tab: Tab) -> String? {
        guard let web = tab.webKitOnly("WebKit PDF data preservation", build: false), web.responds(to: nameSelector) else { return nil }
        return web.perform(nameSelector)?.takeUnretainedValue() as? String
    }

    // MARK: the mode

    /// Fill & Sign: the PDF's bytes into the mode's own view, at the place
    /// the web view was scrolled to.
    func start(_ tab: Tab, shelf: SignatureShelf? = nil, then: ((PDFDesk?) -> Void)? = nil) {
        guard pdf, desk == nil, !starting else { then?(desk); return }
        starting = true
        let t0 = CACurrentMediaTime()
        let name = PDFPaper.suggestedName(of: tab)
        let source = tab.address
        let expected = generation
        let owner = tab.id
        PDFPaper.bytes(of: tab) { [weak self, weak tab] data in
            guard let self, self.generation == expected else { then?(nil); return }
            self.metrics["bytes_ms"] = (CACurrentMediaTime() - t0) * 1000
            guard let data else { self.starting = false; then?(nil); return }
            Task.detached(priority: .utility) {
                let copy = PDFWorkingCopy(original: data, source: source, owner: owner)
                let state = copy.load()
                await MainActor.run {
                    guard self.generation == expected, let tab, tab.address == source else { then?(nil); return }
                    guard let document = PDFDocument(data: data) else { self.starting = false; then?(nil); return }
                    let address = Wallet.preferredAddress()
                    let desk = PDFDesk(document: document, source: source, name: name, address: address,
                        shelf: shelf ?? (Store.testing && Store.settings.bool(forKey: "pdf.memory") ? PDFPaper.memory : SignatureKeychain.shared))
                    desk.mailOrigin = self.mail
                    desk.keepWorking(in: copy, restoring: state)
                    self.mail = desk.mailOrigin
                    let begin = { [weak self] (share: CGFloat?) in
                        guard let self, self.generation == expected, tab.address == source else {
                            desk.flushWorking(); then?(nil); return
                        }
                        desk.startedAt = share
                        self.desk = desk
                        self.starting = false
                        self.metrics["start_ms"] = (CACurrentMediaTime() - t0) * 1000
                        then?(desk)
                    }
                    guard !desk.restored, let web = tab.webKitOnly("WebKit PDF data preservation", build: false) else { return begin(nil) }
                    web.evaluateJavaScript("[window.scrollY, document.documentElement.scrollHeight, window.innerHeight]") { result, _ in
                        MainActor.assumeIsolated {
                            guard let numbers = result as? [NSNumber], numbers.count == 3,
                                  numbers[1].doubleValue > numbers[2].doubleValue + 1 else { return begin(nil) }
                            begin(CGFloat(numbers[0].doubleValue / max(1, numbers[1].doubleValue - numbers[2].doubleValue)))
                        }
                    }
                }
            }
        }
    }

    /// Signatures for a test run kept in memory (`pdf.memory`).
    static let memory = SignatureMemory()

    /// Done: the file in Downloads, into the downloads button, and the tab
    /// on it. The PDF it came from is left as it was.
    @discardableResult
    func done(_ tab: Tab, browser: Browser) -> URL? {
        guard let desk else { return nil }
        guard let data = desk.finish() else {
            browser.announce("Couldn\u{2019}t save the PDF", mark: "exclamationmark.triangle")
            return nil
        }
        let name = PDFFill.signedName(for: desk.source, suggested: desk.sourceName)
        let target = Browser.free(name, in: browser.downloadFolder(for: tab))
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
        } catch {
            browser.announce("Couldn\u{2019}t save \(name)", mark: "exclamationmark.triangle")
            return nil
        }
        if let source = desk.source, !source.isFileURL { Browser.writeWhereFrom(target, [source]) }
        browser.loot.add(Keep(name: target.lastPathComponent, from: desk.source?.host() ?? "", path: target.path, date: Date(),
                              page: desk.source, pageTitle: tab.title))
        browser.hoard.lifting()
        browser.hoard.touched(target.lastPathComponent)
        desk.flushWorking(active: false)
        self.desk = nil
        signed = target
        // At the page last worked on, as the mode was left: WebKit opens a
        // PDF at #page=N.
        var shown = URLComponents(url: target, resolvingAgainstBaseURL: false)
        shown?.fragment = "page=\(desk.lastPage + 1)"
        tab.go(to: shown?.url ?? target)
        return target
    }

    /// esc: out of the mode, asked first when something would be lost.
    func leave(_ tab: Tab) {
        guard let desk else { return }
        guard desk.changed else { return discard() }
        Task { @MainActor in
            let yes = await Questions.shared.ask(Question(
                title: "Discard changes?",
                detail: "What you filled in, typed and signed here goes. The PDF stays as it was.",
                glyph: "trash", yes: "Discard", danger: true
            ))
            if yes, self.desk === desk { self.discard() }
        }
    }

    func close() {
        desk?.flushWorking()
        desk = nil
    }

    func discard() {
        desk?.discardWorkingCopy()
        desk = nil
    }

    /// Reply with Signed PDF: Mail's reply to the thread it came from, the
    /// file on it. Sending is the person's.
    func reply(_ browser: Browser) {
        guard let mail, let signed else { return }
        browser.showMail()
        MailDesk.shared.openThread(account: mail.account, thread: mail.thread, reply: true)
        MailDesk.shared.attach([signed])
        self.mail = nil
    }

    /// The bench's own way to say a PDF came from a mail.
    func cameFrom(_ origin: PDFMailOrigin?) { mail = origin }

    // MARK: keys

    /// The mode's keys while it is up: esc, ⌘↩, ⌘Z and ⇧⌘Z, Tab and ⇧Tab,
    /// Return and ⌫. Anything else goes on to what has the keyboard.
    func take(_ event: NSEvent, tab: Tab, browser: Browser) -> Bool {
        guard let desk, event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let code = event.keyCode
        let enter = code == 36 || code == 76
        if desk.sheet {
            if code == 53, flags.isEmpty { desk.sheet = false; return true }
            if enter, flags.isEmpty { desk.finishSheet(); return true }
            return false
        }
        if enter, flags == .command { done(tab, browser: browser); return true }
        if code == 6, flags == .command { desk.undo(); return true }
        if code == 6, flags == [.command, .shift] { desk.redo(); return true }
        if code == 53, flags.isEmpty {
            if desk.writing != nil { desk.commitNote(); return true }
            if desk.current != nil, desk.mode == .fill { desk.focus(nil); return true }
            if desk.selected != nil { desk.pick(nil); return true }
            leave(tab)
            return true
        }
        if desk.writing != nil {
            if enter, flags.isEmpty { desk.commitNote(); return true }
            return false
        }
        if desk.mode == .fill, desk.current != nil {
            if code == 48 { desk.step(flags.contains(.shift) ? -1 : 1); return true }
            if enter, flags.isEmpty { desk.enter(); return true }
            return false
        }
        if desk.mode == .fill, code == 48 { desk.focus(desk.firstEmpty); return true }
        if code == 51 || code == 117, flags.isEmpty, desk.selected != nil { desk.deleteSelected(); return true }
        return false
    }
}

extension Browser {
    /// Fill & Sign, from the plate, the address's menu or ⌘T.
    func fillSign(_ tab: Tab? = nil) {
        guard let tab = tab ?? active, tab.paper.pdf else { return }
        focus(tab)
        tab.paper.start(tab)
    }
}
