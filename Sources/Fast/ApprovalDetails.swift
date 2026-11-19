import AppKit
import Combine
import ImageIO
import MailCore
import PDFKit
import QuickLookThumbnailing
import SyncKit
import UniformTypeIdentifiers

// What an approval is about, whole, for the person's other devices
// (docs/approvals.md, "Details"; the records: AssistantApprovalDetails.swift).
//
// When this Mac asks another device for a yes, beside the request goes its
// detail: the mails as they will go, every address and every word; the
// files, with a picture of their first pages; a payment as the pay sheet
// has it, its cards (never a number) and its addresses; a post's or a
// message's words. A payment's detail is written again whenever the sheet's
// model changes (the total, the delivery, a card added here).
//
// A yes from there may pick a card and an address (AssistantApprovals.
// answerFromSync puts them into the page). What came of it goes back as a
// result: paying, then paid with the site's order or declined; done or
// failed once the agent's send ran. The request and its records stay until
// that has been said, then go together.

typealias ApprovalDetail = AssistantApprovalRecords.Detail

/// The detail of a question, made from what this Mac has: pure, so every
/// kind can be checked without a sheet or a page.
@MainActor
enum ApprovalDetailBuilder {
    /// A page's picture: small enough that its sealed record stays under
    /// the server's 96 KB a record (base64 of the JPEG, then of the box).
    nonisolated static let jpegLimit = 50_000
    /// The detail's own room, a little under the record's.
    static let room = 58_000
    static let mailPages = 3, uploadPages = 6

    /// A file whose pages are pictured, as `assistantpreview` records.
    struct Pictured: Equatable, Sendable {
        let file: String
        let url: URL
        let kind: String
        let pages: Int
    }

    struct Built {
        var detail: ApprovalDetail
        var pictured: [Pictured] = []
    }

    static func verb(_ words: String) -> String { String(words.prefix(60)) }

    // MARK: a payment

    /// A payment as the pay sheet has it (PaySheetModel): its cards by
    /// brand and last four, its addresses by their line.
    static func pay(id: String, _ model: PaySheetModel) -> ApprovalDetail {
        let cards = Array(model.cards.prefix(12)), places = Array(model.places.prefix(12))
        let pay = ApprovalDetail.Pay(
            site: model.site, item: model.item, amount: model.amount, delivery: model.delivery,
            cards: cards.map { .init(id: $0.id, brand: $0.brand, last4: $0.last4, name: $0.name) },
            places: places.map { .init(id: $0.id, line: $0.line, who: $0.who) },
            card: cards.contains { $0.id == model.card } ? model.card : nil,
            place: places.contains { $0.id == model.place } ? model.place : nil,
            takesCard: model.takesCard, takesPlace: model.takesPlace)
        return .init(id: id, verb: verb(model.amount.isEmpty ? "Pay" : "Pay \(model.amount)"), pay: pay)
    }

    // MARK: files

    nonisolated static func kind(_ type: UTType?) -> String {
        guard let type else { return "file" }
        if type.conforms(to: .pdf) { return "pdf" }
        if type.conforms(to: .image) { return "image" }
        return "file"
    }

    /// A file as it is named and measured, and how many of its pages will
    /// be pictured: a PDF's first `most`, an image, another file's look.
    static func file(_ url: URL, id: String, most: Int, name: String? = nil, bytes: Int? = nil) -> (ApprovalDetail.File, Pictured?) {
        let sort = Self.kind(UTType(filenameExtension: url.pathExtension))
        let size = bytes ?? (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        var file = ApprovalDetail.File(id: id, name: name ?? url.lastPathComponent, bytes: size, kind: sort)
        guard FileManager.default.isReadableFile(atPath: url.path) else { return (file, nil) }
        switch sort {
        case "pdf":
            if let document = PDFDocument(url: url), document.pageCount > 0 {
                file.pages = document.pageCount
                if let bounds = document.page(at: 0)?.bounds(for: .mediaBox) {
                    file.width = Int(bounds.width.rounded()); file.height = Int(bounds.height.rounded())
                }
                file.previews = min(document.pageCount, most)
            }
        case "image":
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let facts = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                file.width = facts[kCGImagePropertyPixelWidth] as? Int
                file.height = facts[kCGImagePropertyPixelHeight] as? Int
                file.previews = 1
            }
        default:
            file.previews = 1
        }
        return (file, file.previews > 0 ? Pictured(file: id, url: url, kind: sort, pages: file.previews) : nil)
    }

    /// Files given to a page (upload).
    static func upload(id: String, _ urls: [URL]) -> Built {
        var pictured: [Pictured] = []
        let files = urls.prefix(20).enumerated().map { index, url -> ApprovalDetail.File in
            let (made, pic) = Self.file(url, id: "f\(index)", most: uploadPages)
            if let pic { pictured.append(pic) }
            return made
        }
        let words = urls.count == 1 ? "Upload \(urls[0].lastPathComponent)" : "Upload \(urls.count) Files"
        return Built(detail: .init(id: id, verb: verb(words), files: files), pictured: pictured)
    }

    // MARK: mail

    static func person(_ person: MailPerson) -> ApprovalDetail.Person {
        .init(name: person.name.isEmpty ? person.address : person.name, address: person.address)
    }

    /// Mails as they will go: from the account sending, to whom, the
    /// subject, the whole words, the files with their first pages.
    static func mails(id: String, _ outs: [MailAgent.Outgoing]) -> Built {
        var pictured: [Pictured] = []
        var count = 0
        let mails = outs.prefix(20).enumerated().map { index, out -> ApprovalDetail.Mail in
            let draft = out.draft
            let from = draft.from.isEmpty ? out.engine.account : draft.from
            var files: [ApprovalDetail.File] = []
            for (number, attached) in draft.files.enumerated() where count < 20 {
                count += 1
                let fid = "m\(index)f\(number)"
                if !attached.original, let url = MailAttach.place(attached, draft: draft.id, store: out.engine.store) {
                    let (made, pic) = Self.file(url, id: fid, most: mailPages, name: attached.name, bytes: attached.size)
                    if let pic { pictured.append(pic) }
                    files.append(made)
                } else {
                    // Another mail's file, fetched from Gmail as it goes:
                    // named and measured, not pictured.
                    files.append(.init(id: fid, name: attached.name, bytes: attached.size, kind: Self.kind(attached.type)))
                }
            }
            return .init(id: draft.id, from: .init(name: from, address: from), to: draft.to.map(Self.person), cc: draft.cc.map(Self.person),
                         bcc: draft.bcc.isEmpty ? nil : draft.bcc.map(Self.person), subject: draft.subject, body: draft.body, files: files)
        }
        let one = mails.count == 1 ? mails[0] : nil
        let to = one.flatMap { $0.to.count == 1 && $0.cc.isEmpty && ($0.bcc ?? []).isEmpty ? $0.to[0] : nil }
        let words = mails.count == 1 ? "Send" : "Send All \(mails.count)"
        return Built(detail: fitted(.init(id: id, verb: words, mails: mails, person: to)), pictured: pictured)
    }

    /// Mail a change is for, as its list shows it: who, when, the subject
    /// and its first lines.
    static func changed(id: String, verb words: String, threads keys: [String]) -> ApprovalDetail {
        var mails: [ApprovalDetail.Mail] = []
        for key in keys.prefix(20) {
            let thread = key.split(separator: "|").last.map(String.init) ?? key
            guard let engine = MailAgent.engine(holding: key, in: MailCenter.shared.engines.values)?.engine,
                  let found = engine.store.thread(thread) else { continue }
            mails.append(.init(id: found.id, from: found.people.first.map(Self.person), to: [], subject: found.subject,
                               body: found.snippet, date: found.last.timeIntervalSince1970))
        }
        return .init(id: id, verb: verb(words), mails: mails.isEmpty ? nil : mails)
    }

    /// Within the record's room: the longest words cut first, an ellipsis
    /// where they were.
    static func fitted(_ detail: ApprovalDetail) -> ApprovalDetail {
        var detail = detail
        func size() -> Int { (try? detail.fields()["body"]?.string?.utf8.count) ?? .max }
        var rounds = 0
        while size() > room, rounds < 40 {
            rounds += 1
            if let text = detail.text, text.count > 200, (detail.mails ?? []).allSatisfy({ $0.body.count <= text.count }) {
                detail.text = String(text.prefix(text.count * 3 / 4)) + "…"
                continue
            }
            guard var mails = detail.mails, let longest = mails.indices.max(by: { mails[$0].body.count < mails[$1].body.count }),
                  mails[longest].body.count > 200 else { break }
            let body = mails[longest].body
            mails[longest].body = String(body.prefix(body.count * 3 / 4)) + "…"
            detail.mails = mails
        }
        return detail
    }

    // MARK: by the question

    /// The detail a permit's question carries.
    static func build(id: String, permit: AgentPermit, tab: Tab?) -> Built {
        let yes = verb(permit.answers.first?.title ?? "")
        switch permit.kind {
        case .press(let label, _):
            if permit.isPayment, let tab, let flow = Payments.shared.flow(tab) { return Built(detail: pay(id: id, flow.model)) }
            // A post or a message pressed on a page: its words.
            return Built(detail: fitted(.init(id: id, verb: verb(label), text: permit.draft.isEmpty ? nil : permit.draft)))
        case .upload(let files, _):
            return upload(id: id, files)
        case .sendMessage(let to):
            return Built(detail: fitted(.init(id: id, verb: "Send", text: permit.draft, person: .init(name: to))))
        case .sendMail, .sendMails:
            guard let outs = ApprovalDetails.shared.outgoing[permit.key], !outs.isEmpty else { return Built(detail: .init(id: id, verb: yes)) }
            return mails(id: id, outs)
        case .mailChange(_, let act):
            let threads = ApprovalDetails.shared.changing[ApprovalDetails.changeKey(session: permit.session, permit: permit)] ?? []
            return Built(detail: changed(id: id, verb: Bench.changeWords(act).yes, threads: threads))
        case .mailRead:
            // What it looks for first, then the terms it reads under, a line
            // each: the yes is for every search in the chat.
            let words = ApprovalDetails.shared.searching[ApprovalDetails.changeKey(session: permit.session, permit: permit)] ?? permit.detail
            return Built(detail: fitted(.init(id: id, verb: "Allow in This Chat", text: words.isEmpty ? nil : words)))
        case .signIn:
            // Its accounts are the request's choices; the yes is one word.
            return Built(detail: .init(id: id, verb: "Sign In"))
        default:
            return Built(detail: .init(id: id, verb: yes.isEmpty ? nil : yes))
        }
    }

    // MARK: pictures

    /// The pages' pictures, each a JPEG within `jpegLimit`. Off the main
    /// thread: PDFKit and ImageIO here, Quick Look for any other file.
    nonisolated static func pictures(of pictured: Pictured) -> [Data] {
        switch pictured.kind {
        case "pdf":
            guard let document = PDFDocument(url: pictured.url) else { return [] }
            return (0..<min(pictured.pages, document.pageCount)).compactMap { index in
                guard let page = document.page(at: index) else { return nil }
                let image = page.thumbnail(of: CGSize(width: 1000, height: 1000), for: .mediaBox)
                return image.cgImage(forProposedRect: nil, context: nil, hints: nil).flatMap { jpeg($0) }
            }
        case "image":
            guard let source = CGImageSourceCreateWithURL(pictured.url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1200] as CFDictionary) else { return [] }
            return jpeg(image).map { [$0] } ?? []
        default:
            let request = QLThumbnailGenerator.Request(fileAt: pictured.url, size: CGSize(width: 600, height: 800), scale: 2,
                                                       representationTypes: .thumbnail)
            let done = DispatchSemaphore(value: 0)
            let made = Made()
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { thumbnail, _ in
                made.image = thumbnail?.cgImage
                done.signal()
            }
            guard done.wait(timeout: .now() + 8) == .success, let image = made.image else { return [] }
            return jpeg(image).map { [$0] } ?? []
        }
    }

    private final class Made: @unchecked Sendable { var image: CGImage? }

    /// A JPEG of the picture within `limit`: plainer, then smaller, until it fits.
    nonisolated static func jpeg(_ image: CGImage, limit: Int = jpegLimit) -> Data? {
        var image = image
        for _ in 0..<6 {
            for quality in [0.7, 0.55, 0.4] {
                let out = NSMutableData()
                guard let sink = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
                CGImageDestinationAddImage(sink, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
                guard CGImageDestinationFinalize(sink) else { return nil }
                if out.length <= limit { return out as Data }
            }
            let width = image.width * 3 / 4, height = image.height * 3 / 4
            guard width > 40, height > 40,
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return nil }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let smaller = context.makeImage() else { return nil }
            image = smaller
        }
        return nil
    }

    // MARK: results

    /// What a pay sheet's phase says of a yes from another device; nil
    /// while it hasn't been pressed.
    static func result(id: String, phase: PaySheetModel.Phase, order: String) -> AssistantApprovalRecords.Result? {
        switch phase {
        case .ready, .armed, .checking: return nil
        case .paying: return .init(id: id, phase: .paying)
        case .paid: return .init(id: id, phase: .paid, order: order.isEmpty ? nil : String(order.prefix(80)))
        case .declined: return .init(id: id, phase: .declined, words: "Payment not completed")
        }
    }
}

/// The details this Mac has published and the results it owes, by request.
@MainActor
final class ApprovalDetails {
    static let shared = ApprovalDetails()

    /// The mails behind a send's question, by its permit's key
    /// (Agents.sendMail, sendMails), for its detail.
    var outgoing: [String: [MailAgent.Outgoing]] = [:]
    /// The threads a mail change names, by `changeKey`.
    var changing: [String: [String]] = [:]
    /// A mail search's card words by AgentPermit key and session: what it
    /// looks for, then on a line of its own the terms, when they are asked.
    var searching: [String: String] = [:]

    static func changeKey(session: String, permit: AgentPermit) -> String { session + "\u{1}" + permit.key }

    private struct Shown {
        var request: AssistantApprovalRecords.Request
        var detail: ApprovalDetail
        var watch: AnyCancellable?
    }
    private var shown: [String: Shown] = [:]

    /// A yes given on another device, waiting to say what came of it.
    private struct Owed {
        let tab: UUID?
        let session: String
        let key: String
        var settled = false
        /// The question is over here: its records go once this is said.
        var closing = false
        var watch: AnyCancellable?
    }
    private var owed: [String: Owed] = [:]
    /// Answers refused, "id@at": the same answer isn't taken again.
    private var refusals: Set<String> = []

    /// How long a said result stays for the device that answered to read.
    static let grace: TimeInterval = 30
    /// The longest a result is waited for: a payment's press and its page
    /// (PayFlow.watch) are over by then.
    static let longest: TimeInterval = 240

    private var sync: SyncCenter { SyncCenter.shared }

    // MARK: publishing

    /// The question's detail into Sync, with its pages' pictures after it.
    func publish(_ record: AssistantApprovals.Record, request: AssistantApprovalRecords.Request) {
        guard let found = Self.permit(of: record) else { return }
        let (permit, tab) = found
        let built = ApprovalDetailBuilder.build(id: record.id, permit: permit, tab: tab)
        shown[record.id] = Shown(request: request, detail: .init(id: ""), watch: shown[record.id]?.watch)
        guard permit.isPayment, let tab, let flow = Payments.shared.flow(tab) else {
            write(record.id, built)
            return
        }
        // A payment's: once the sheet has read the page (its delivery, its
        // boxes for a card), so a yes isn't given to a detail about to
        // change; then again whenever the sheet changes (the total read
        // again, a card added here).
        if flow.looked { write(record.id, built) }
        if shown[record.id]?.watch == nil {
            let id = record.id
            shown[id]?.watch = flow.observed(\.model).combineLatest(flow.observed(\.looked)).filter { $0.1 }
                .map { ApprovalDetailBuilder.pay(id: id, $0.0) }.removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] detail in MainActor.assumeIsolated { self?.write(id, .init(detail: detail)) } }
        }
    }

    static func permit(of record: AssistantApprovals.Record) -> (AgentPermit, Tab?)? {
        switch record.place {
        case .tab(let id):
            guard let tab = Agents.shared.browser?.everyTab.first(where: { $0.id == id }), let permit = tab.permit,
                  permit.key == record.key, permit.session == record.session else { return nil }
            return (permit, tab)
        case .mail(let id):
            guard let permit = Agents.shared.mailRequest(id)?.permit, permit.key == record.key,
                  permit.session == record.session else { return nil }
            return (permit, nil)
        case .chat(let id):
            guard let permit = Agents.shared.session(id)?.permit, permit.key == record.key else { return nil }
            return (permit, nil)
        }
    }

    private func write(_ id: String, _ built: ApprovalDetailBuilder.Built) {
        guard var now = shown[id], now.detail != built.detail, let journal = sync.journal, let client = sync.client else { return }
        do {
            try built.detail.validate(for: now.request)
            try journal.change(.init(collection: AssistantApprovalRecords.detailCollection, id: id), built.detail.fields())
        } catch {
            NSLog("assistant approval: couldn't publish its detail: %@", String(describing: error))
            return
        }
        now.detail = built.detail
        shown[id] = now
        client.kick()
        guard !built.pictured.isEmpty else { return }
        let pictured = built.pictured
        Task.detached(priority: .utility) {
            var made: [(String, Int, Data)] = []
            for one in pictured {
                for (page, jpeg) in ApprovalDetailBuilder.pictures(of: one).enumerated() { made.append((one.file, page, jpeg)) }
            }
            let pages = made
            await MainActor.run { ApprovalDetails.shared.picture(id, pages) }
        }
    }

    private func picture(_ id: String, _ pages: [(String, Int, Data)]) {
        guard shown[id] != nil, let journal = sync.journal, let client = sync.client else { return }
        for (file, page, jpeg) in pages {
            guard let preview = try? AssistantApprovalRecords.Preview(request: id, file: file, page: page, jpeg: jpeg),
                  let fields = try? preview.fields() else { continue }
            try? journal.change(.init(collection: AssistantApprovalRecords.previewCollection, id: preview.id), fields)
        }
        client.kick()
    }

    // MARK: results

    /// A yes from another device, about to go to the agent: what came of it
    /// goes back there. A payment: paying now, then what the site said. A
    /// send: once it ran. Anything else is done with the yes.
    func answered(_ id: String, tab: Tab?, permit: AgentPermit) {
        guard owed[id] == nil else { return }
        owed[id] = Owed(tab: tab?.id, session: permit.session, key: permit.key)
        if permit.isPayment, let tab, let flow = Payments.shared.flow(tab) {
            say(.init(id: id, phase: .paying))
            owed[id]?.watch = flow.observed(\.model).map { ($0.phase, $0.order) }.removeDuplicates { $0 == $1 }
                .receive(on: DispatchQueue.main)
                .sink { [weak self] phase, order in
                    MainActor.assumeIsolated {
                        guard let result = ApprovalDetailBuilder.result(id: id, phase: phase, order: order), result.phase != .paying else { return }
                        self?.say(result)
                    }
                }
        } else if !permit.sends {
            say(.init(id: id, phase: .done))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.longest) { [weak self] in
            guard let self, self.owed[id] != nil else { return }
            self.owed[id]?.settled = true
            self.release(id)
        }
    }

    /// The agent's send ran (Agents.sent): done, or what kept it.
    func ran(_ tab: Tab, _ permit: AgentPermit, trouble: String?) {
        guard let id = owed.first(where: { $0.value.tab == tab.id && $0.value.key == permit.key && $0.value.session == permit.session })?.key
        else { return }
        say(trouble == nil ? .init(id: id, phase: .done) : .init(id: id, phase: .failed, words: Self.failure(permit)))
    }

    func ran(_ permit: AgentPermit, trouble: String?) {
        guard let id = owed.first(where: { $0.value.tab == nil && $0.value.key == permit.key && $0.value.session == permit.session })?.key else { return }
        say(trouble == nil ? .init(id: id, phase: .done) : .init(id: id, phase: .failed, words: Self.failure(permit)))
    }

    static func failure(_ permit: AgentPermit) -> String {
        switch permit.kind {
        case .sendMail, .sendMails, .sendMessage: return "Not sent"
        case .upload: return "Not uploaded"
        default: return "Didn’t go through"
        }
    }

    /// A payment's sheet went: what the site said is said; nothing said,
    /// and the press went with no word back.
    func payEnded(tab: UUID) {
        for (id, now) in owed where now.tab == tab && !now.settled {
            say(.init(id: id, phase: .done))
        }
    }

    /// An answer this Mac won't take: the detail changed after it was read,
    /// or a card it picked never came. Said back once.
    func refuse(_ answer: AssistantApprovalRecords.Answer, words: String) {
        refuse(answer.id, at: answer.at, words: words)
    }

    func refuse(_ id: String, at: Double, words: String) {
        guard refusals.insert("\(id.lowercased())@\(at)").inserted, let journal = sync.journal, let client = sync.client else { return }
        let result = AssistantApprovalRecords.Result(id: id, phase: .failed, words: words)
        guard let fields = try? result.fields() else { return }
        try? journal.change(.init(collection: AssistantApprovalRecords.resultCollection, id: id), fields)
        client.kick()
    }

    func refused(_ id: String, at: Double) -> Bool { refusals.contains("\(id.lowercased())@\(at)") }

    private func say(_ result: AssistantApprovalRecords.Result) {
        guard let journal = sync.journal, let client = sync.client, let fields = try? result.fields() else { return }
        try? journal.change(.init(collection: AssistantApprovalRecords.resultCollection, id: result.id), fields)
        client.kick()
        if result.settled, owed[result.id] != nil {
            owed[result.id]?.settled = true
            release(result.id)
        }
    }

    /// The question is over here (SyncCenter.closeAssistantApproval): true
    /// while a yes from another device still owes what came of it; its
    /// records then go once that is said and read.
    func holds(_ id: String) -> Bool {
        guard owed[id] != nil else { return false }
        owed[id]?.closing = true
        release(id)
        return true
    }

    private func release(_ id: String) {
        guard let now = owed[id], now.settled, now.closing else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.grace) { [weak self] in
            guard self?.owed[id] != nil else { return }
            SyncCenter.shared.closeAssistantApproval(id, now: true)
        }
    }

    /// The question and its records gone.
    func forget(_ id: String) {
        if let record = AssistantApprovals.shared.records[id], let key = record.key {
            outgoing[key] = nil
            changing[record.session + "\u{1}" + key] = nil
            searching[record.session + "\u{1}" + key] = nil
        }
        shown[id]?.watch?.cancel()
        shown[id] = nil
        owed[id]?.watch?.cancel()
        owed[id] = nil
    }

    /// For the bench: what was published, by request.
    func published(_ id: String) -> ApprovalDetail? { shown[id]?.detail }
}
