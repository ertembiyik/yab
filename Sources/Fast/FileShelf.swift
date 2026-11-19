import AppKit
import MailCore
import UniformTypeIdentifiers

// Files (docs/files.md): everything that came to this Mac through Yab or
// left it, in the one list ⇧⌘J opens. Downloads are Loot's; this keeps the
// rest: the files mail carried both ways, read from each account's store,
// and the files you gave a site, kept here as they went. It also keeps the
// words inside them (a PDF's text, a document's), so a search finds the
// lease by "security deposit", and agents read them (files_search,
// files_read). Nothing is copied: a mail's file is where MailFiles keeps
// it, fetched the first time it is wanted, and a download stays where it
// landed.

/// A file of mail's or one you sent a site, as Files lists it.
struct ShelfFile: Identifiable, Equatable {
    enum Origin: Equatable {
        /// A mail's file: who wrote it, to whom, in which thread. `sent`
        /// when the mail was yours.
        case mail(account: String, message: String, thread: String, from: MailPerson, to: [MailPerson], subject: String, sent: Bool)
        /// A file you gave a site, by its host.
        case upload(host: String)
    }

    let id: String
    let name: String
    let date: Date
    let size: Int
    let origin: Origin
    /// Mail's own record of it, to fetch it by.
    let file: MailFile?
    /// Where it is on this Mac, when it is: a mail's file once fetched, an
    /// upload while it is still where it was.
    var path: String?

    var sent: Bool {
        switch origin {
        case .mail(_, _, _, _, _, _, let sent): return sent
        case .upload: return true
        }
    }

    /// "Ivan Petrov", "Sent to Anna Lee", "Sent to united.com".
    var said: String {
        switch origin {
        case .mail(_, _, _, let from, let to, _, let sent):
            if sent { return "Sent to " + (to.first.map(ShelfFile.person) ?? "yourself") }
            return ShelfFile.person(from)
        case .upload(let host): return "Sent to " + host
        }
    }

    /// The mail's subject, for a mail's file.
    var subject: String? {
        guard case .mail(_, _, _, _, _, let subject, _) = origin else { return nil }
        return subject.isEmpty ? nil : subject
    }

    /// The mail thread it came in, as mail opens it.
    var thread: URL? {
        guard case .mail(let account, _, let thread, _, _, _, _) = origin else { return nil }
        return URL(string: "yab://mail#thread=" + account + "|" + thread)
    }

    static func person(_ person: MailPerson) -> String {
        let name = person.name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? person.address : name
    }
}

@MainActor
@Observable final class FileShelf {
    static let shared = FileShelf()

    /// Mail's files, newest first, as last read from the stores.
    private(set) var mail: [ShelfFile] = []
    /// What you gave sites, newest first.
    private(set) var uploads: [Upload] = []
    /// Counts every change, for what is made from it (Places' memo).
    @ObservationIgnored private(set) var version = 0

    struct Upload: Codable, Equatable {
        var path: String
        var name: String
        var host: String
        var date: Date
    }

    /// How far back mail's files are listed, and how many.
    static let days: Double = 365
    static let most = 600
    /// The uploads remembered.
    static let uploadsKept = 200

    private let file: URL
    @ObservationIgnored private var read: Date?
    /// Mail's files a test world hands over (bench `seed-shelf`); nil reads
    /// the stores.
    @ObservationIgnored var testingMail: [ShelfFile]?

    init(file: URL = Store.file("files-sent.json"), words: URL = Store.file("file-words.json")) {
        self.file = file
        self.words = Words(file: words)
        if let data = try? Data(contentsOf: file), let kept = try? JSONDecoder().decode([Upload].self, from: data) { uploads = kept }
    }

    // MARK: - mail's files

    /// Read mail's files again from every account, at most once a minute
    /// unless asked (`now`). Off the main thread: a store answers by
    /// blocking.
    func refresh(force: Bool = false) {
        if let testingMail {
            mail = testingMail
            version += 1
            learn(testingMail.compactMap(\.path))
            return
        }
        if !force, let read, Date().timeIntervalSince(read) < 60 { return }
        read = Date()
        guard MailCenter.shared.connected else {
            if !mail.isEmpty { mail = []; version += 1 }
            return
        }
        let engines = MailCenter.shared.engines.values.map { ($0.account, $0.store, $0.provider) }
        let since = Date().addingTimeInterval(-FileShelf.days * 86_400)
        DispatchQueue.global(qos: .userInitiated).async {
            var out: [ShelfFile] = []
            for (account, store, provider) in engines {
                let files = MailFiles.of(store, provider)
                for row in store.shelf(since: since, limit: FileShelf.most) {
                    out.append(ShelfFile(id: "mail.\(account)|\(row.message)|\(row.file.part)", name: row.file.name, date: row.at, size: row.file.size,
                                         origin: .mail(account: account, message: row.message, thread: row.thread, from: row.from, to: row.to, subject: row.subject, sent: row.sent),
                                         file: row.file, path: files?.kept(row.file, message: row.message)?.path))
                }
            }
            out.sort { $0.date > $1.date }
            let list = Array(out.prefix(FileShelf.most))
            DispatchQueue.main.async {
                self.mail = list
                self.version += 1
                self.learn(list.compactMap(\.path))
            }
        }
    }

    /// A mail's file on this Mac, fetched from its server first when it
    /// isn't here yet.
    func fetch(_ shelf: ShelfFile) async -> URL? {
        if let path = shelf.path, FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        guard case .mail(let account, let message, _, _, _, _, _) = shelf.origin, let file = shelf.file,
              let engine = MailCenter.shared.engines.values.first(where: { $0.account == account }),
              let files = MailFiles.of(engine.store, engine.provider),
              let url = try? await files.file(file, message: message) else { return nil }
        if let at = mail.firstIndex(where: { $0.id == shelf.id }) {
            mail[at].path = url.path
            version += 1
        }
        learn([url.path])
        return url
    }

    // MARK: - what you gave sites

    /// Files given to a site's file field, by you or an agent.
    func gave(_ urls: [URL], to host: String) {
        guard !host.isEmpty else { return }
        let now = Date()
        for url in urls where url.isFileURL {
            uploads.removeAll { $0.path == url.path && $0.host == host }
            uploads.insert(Upload(path: url.path, name: url.lastPathComponent, host: host, date: now), at: 0)
        }
        if uploads.count > FileShelf.uploadsKept { uploads.removeLast(uploads.count - FileShelf.uploadsKept) }
        version += 1
        save()
        learn(urls.map(\.path))
    }

    /// The uploads as rows of the list: those whose file is still there.
    var sentFiles: [ShelfFile] {
        uploads.compactMap { one in
            guard FileManager.default.fileExists(atPath: one.path) else { return nil }
            let size = (try? FileManager.default.attributesOfItem(atPath: one.path)[.size] as? Int) ?? 0
            return ShelfFile(id: "sent.\(one.host)|\(one.path)", name: one.name, date: one.date, size: size,
                             origin: .upload(host: one.host), file: nil, path: one.path)
        }
    }

    /// What was given this site before, newest first (a page's file
    /// field: Sent to … Before).
    func given(to host: String) -> [Upload] {
        let site = Vault.registrable(host)
        return uploads.filter { Vault.registrable($0.host) == site && FileManager.default.fileExists(atPath: $0.path) }
    }

    func forget(_ shelf: ShelfFile) {
        guard case .upload(let host) = shelf.origin, let path = shelf.path else { return }
        uploads.removeAll { $0.path == path && $0.host == host }
        version += 1
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(uploads) else { return }
        try? data.write(to: file, options: .atomic)
    }

    // MARK: - the words inside

    private let words: Words

    /// Read the words of these files, the ones not read since they last
    /// changed, in the background.
    func learn(_ paths: [String]) {
        words.learn(paths) { [weak self] in
            guard let self else { return }
            self.version += 1
        }
    }

    /// The words of a file read already, or nil.
    func text(_ path: String) -> String? { words.text(path) }

    /// The words of a file, read now if they weren't (an agent's
    /// files_read).
    nonisolated static func read(_ url: URL) -> String? { Words.extract(url) }

    /// A line of a file's words around the first of `terms`, when all of
    /// them are in it: "…the security deposit of $3,200 is due…".
    func found(_ path: String, terms: [String]) -> String? {
        guard !terms.isEmpty, let text = words.lowered(path) else { return nil }
        guard terms.allSatisfy({ text.contains($0) }), let first = terms.first,
              let range = text.range(of: first), let original = words.text(path) else { return nil }
        return FileShelf.snippet(original, at: text.distance(from: text.startIndex, to: range.lowerBound), length: first.count)
    }

    /// A few words before what was found and more after, so a row cut at
    /// its end still shows it.
    nonisolated static func snippet(_ text: String, at offset: Int, length: Int, before: Int = 24, after: Int = 120) -> String {
        let chars = Array(text)
        guard offset < chars.count else { return "" }
        let start = max(0, offset - before), end = min(chars.count, offset + length + after)
        var words = String(chars[start..<end]).components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        // Cut mid-word at the start: begin at the next whole word.
        if start > 0, !chars[start - 1].isWhitespace, words.count > 1 { words.removeFirst() }
        var out = words.joined(separator: " ")
        if start > 0 { out = "…" + out }
        if end < chars.count { out += "…" }
        return out
    }

    /// The words of files on this Mac, kept between launches by each file's
    /// date, so a list of hundreds isn't read again at every opening.
    final class Words {
        struct Kept: Codable { var changed: Date; var text: String }
        /// How much of one file is kept and searched.
        static let cap = 60_000
        /// How many files' words are kept.
        static let most = 800

        private let file: URL
        private let queue = DispatchQueue(label: "yab.files.words", qos: .utility)
        private var kept: [String: Kept] = [:]
        private var low: [String: String] = [:]
        private var reading = false
        private var dirty = false

        init(file: URL) {
            self.file = file
            if let data = try? Data(contentsOf: file), let all = try? JSONDecoder().decode([String: Kept].self, from: data) {
                kept = all
                low = all.mapValues { $0.text.lowercased() }
            }
        }

        func text(_ path: String) -> String? { kept[path]?.text }
        func lowered(_ path: String) -> String? { low[path] }

        @MainActor
        func learn(_ paths: [String], done: @escaping @MainActor () -> Void) {
            let known = kept.mapValues(\.changed)
            let wanted = paths.filter { path in
                guard let date = Words.changed(path) else { return false }
                return known[path].map { $0 < date } ?? true
            }
            guard !wanted.isEmpty else { return }
            queue.async {
                var got: [String: Kept] = [:]
                for path in wanted {
                    guard let date = Words.changed(path) else { continue }
                    let words = Words.extract(URL(fileURLWithPath: path)) ?? ""
                    got[path] = Kept(changed: date, text: String(words.prefix(Words.cap)))
                }
                DispatchQueue.main.async {
                    for (path, one) in got {
                        self.kept[path] = one
                        self.low[path] = one.text.lowercased()
                    }
                    self.trim()
                    self.save()
                    done()
                }
            }
        }

        private func trim() {
            guard kept.count > Words.most else { return }
            for (path, _) in kept.sorted(by: { $0.value.changed < $1.value.changed }).prefix(kept.count - Words.most) {
                kept[path] = nil
                low[path] = nil
            }
        }

        private func save() {
            let all = kept
            let file = self.file
            queue.async {
                guard let data = try? JSONEncoder().encode(all) else { return }
                try? data.write(to: file, options: .atomic)
            }
        }

        static func changed(_ path: String) -> Date? {
            (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        }

        /// A file's words: a PDF's, a document's, a text file's; nil for
        /// pictures, archives and the rest. Files over 50 MB aren't read.
        static func extract(_ url: URL) -> String? {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
            guard size < 50 << 20 else { return nil }
            let type = UTType(filenameExtension: url.pathExtension) ?? .data
            return MailFiles.text(of: url, type: type)
        }
    }
}
