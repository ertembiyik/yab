import Foundation
import AppKit

// What you have kept. Downloads work already; this is only the memory of them,
// so a file you fetched an hour ago is one click from the Finder rather than a
// hunt through a folder.

struct Keep: Codable, Identifiable, Equatable {
    var name: String
    var from: String
    var path: String
    var date: Date
    /// The page it was downloaded from, and what it was called, where the
    /// tab was known. Nil for downloads kept before this was written down.
    var page: URL?
    var pageTitle: String?
    /// The address the file came from, for extensions asking
    /// (chrome.downloads). Nil for downloads kept before this was written.
    var source: URL?
    /// Named by Tidy Downloads: what the site called it, and when it was
    /// renamed (DownloadNames). Undo puts `was` back.
    var was: String?
    var renamed: Date?
    /// Transient: a visual reveal only when an old-name snapshot was made.
    var revealing: Date? = nil

    private enum CodingKeys: String, CodingKey {
        case name, from, path, date, page, pageTitle, source, was, renamed
    }

    var id: String { path }

    var url: URL { URL(fileURLWithPath: path) }
    var stillThere: Bool { FileManager.default.fileExists(atPath: path) }
}

@MainActor
@Observable final class Loot {
    private(set) var kept: [Keep] = [] {
        didSet { version += 1 }
    }
    /// Counts every change to the list, for what is made from it.
    @ObservationIgnored private(set) var version = 0

    private let persists: Bool
    private let saving = DispatchQueue(label: "yab.downloads.save", qos: .utility)
    /// Where the list is kept: the store's, or a test's own file.
    private let file: URL

    init(persist: Bool = true, file: URL = Loot.file) {
        persists = persist
        self.file = file
        if persist { load() }
    }

    func add(_ keep: Keep) {
        // Start as soon as the completed file is known, before its badge rises.
        HoardPictures.shared.load(keep.url) { _ in }
        kept.removeAll { $0.path == keep.path }
        kept.insert(keep, at: 0)
        // Fifty is more than anybody scrolls back through.
        if kept.count > 50 { kept.removeLast(kept.count - 50) }
        save()
    }

    /// The file renamed on disk to `name` (a free one, beside it), its
    /// entry with it. Nil when it couldn't be moved.
    @discardableResult
    func rename(_ keep: Keep, to name: String, animate: Bool = false) -> Keep? {
        guard kept.contains(keep), name != keep.name, Self.validName(name) else { return nil }
        let folder = keep.url.deletingLastPathComponent()
        let to = Browser.free(name, in: folder)
        guard (try? FileManager.default.moveItem(at: keep.url, to: to)) != nil else { return nil }
        var moved = keep
        moved.name = to.lastPathComponent
        moved.path = to.path
        moved.was = keep.was ?? keep.name
        moved.renamed = Date()
        moved.revealing = animate ? moved.renamed : nil
        if let at = kept.firstIndex(where: { $0.path == keep.path }) { kept[at] = moved }
        ExtensionDownloads.moved(from: keep.path, to: moved.path)
        save()
        return moved
    }

    /// Tidy Downloads' name taken back: the site's name again.
    func undoRename(_ keep: Keep) {
        guard kept.contains(keep), let was = keep.was, Self.validName(was) else { return }
        let to = Browser.free(was, in: keep.url.deletingLastPathComponent())
        guard (try? FileManager.default.moveItem(at: keep.url, to: to)) != nil else { return }
        var back = keep
        back.name = to.lastPathComponent
        back.path = to.path
        back.was = nil
        back.renamed = nil
        back.revealing = nil
        if let at = kept.firstIndex(where: { $0.path == keep.path }) { kept[at] = back }
        ExtensionDownloads.moved(from: keep.path, to: back.path)
        save()
    }

    nonisolated static func validName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".."
            && name.rangeOfCharacter(from: .controlCharacters.union(CharacterSet(charactersIn: "/:\\"))) == nil
    }

    func forget(_ keep: Keep) {
        kept.removeAll { $0.id == keep.id }
        save()
    }

    /// Several taken off the list at once, handed back for ⌘Z (`putBack`).
    func forget(_ keeps: [Keep]) -> [Keep] {
        let ids = Set(keeps.map(\.id))
        let gone = kept.filter { ids.contains($0.id) }
        guard !gone.isEmpty else { return [] }
        kept.removeAll { ids.contains($0.id) }
        save()
        return gone
    }

    /// What `forget` took, back in the list by its date.
    func putBack(_ keeps: [Keep]) {
        let known = Set(kept.map(\.id))
        let back = keeps.filter { !known.contains($0.id) }
        guard !back.isEmpty else { return }
        kept = (kept + back).sorted { $0.date > $1.date }
        save()
    }

    /// Only the list is emptied. Files you asked for are yours, and deleting
    /// them is the Finder's business, not a browser's.
    func forgetAll() {
        kept = []
        save()
    }

    func reveal(_ keep: Keep) {
        NSWorkspace.shared.activateFileViewerSelecting([keep.url])
    }

    func open(_ keep: Keep) {
        NSWorkspace.shared.open(keep.url)
    }

    nonisolated static var file: URL { Store.file("downloads.json") }

    private func load() {
        guard let data = try? Data(contentsOf: file),
              let list = try? JSONDecoder().decode([Keep].self, from: data)
        else { return }
        kept = list
    }

    private func save() {
        guard persists else { return }
        let snapshot = kept
        let file = file
        saving.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? data.write(to: file, options: .atomic)
        }
    }
}

extension NSItemProvider {
    /// A file taken out of the window by a drag, a kept download or a row of
    /// the Files place, named as itself wherever it lands. Made from the
    /// file alone, the provider has no name to give: a page taking the file
    /// from it (WebKit receiving a drop) got "PDF document.pdf" or "PNG
    /// image.png", its kind's name, and an upload to Google Drive went up
    /// under that (feedback #122).
    static func file(_ url: URL) -> NSItemProvider {
        guard let provider = NSItemProvider(contentsOf: url) else { return NSItemProvider(object: url as NSURL) }
        provider.suggestedName = url.lastPathComponent
        return provider
    }
}
