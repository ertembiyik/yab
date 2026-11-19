import AppKit
import SwiftUI

// Apps' and files' names and icons as the Finder shows them, found off the
// main thread and kept for the run.
//
// Asking macOS for either reads the bundle's attributes from disk. On a Mac
// running macOS 27's beta each such read of a third-party app stalled about
// 5 s in getattrlist, and Settings › General asked for the default browser's
// name and icon in its body: 10 s of frozen window at every redraw, and
// General redraws two or three times as it opens. So nothing drawn asks
// macOS here. A body reads what is kept, and a lookup's answer, when it
// lands, draws the view again.

enum FinderLooks {
    struct Look {
        let name: String
        let icon: NSImage
    }

    @MainActor private static var kept: [String: Look] = [:]
    @MainActor private static var waiting: [String: [(Look) -> Void]] = [:]

    private static let lock = NSLock()
    nonisolated(unsafe) private static var asked = 0
    /// How many times macOS has been asked for a name and an icon this run;
    /// tests hold it still while a view is drawn.
    static var lookups: Int { lock.withLock { asked } }

    /// What was found for this path, if it has been looked up.
    @MainActor static func kept(_ path: String) -> Look? { kept[path] }

    /// The Finder's name for it once found, its file name until then (the
    /// same thing for nearly every app), and the lookup is started.
    @MainActor static func name(_ path: String) -> String {
        if let look = kept[path] { return look.name }
        find(path) { _ in }
        return fileName(path)
    }

    /// The name with no lookup: the file's, less ".app".
    static func fileName(_ path: String) -> String {
        (path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
    }

    /// Looks the path up once, off the main thread; every caller waiting on
    /// the same path hears the one answer.
    @MainActor static func find(_ path: String, _ done: @escaping (Look) -> Void) {
        if let look = kept[path] { done(look); return }
        if waiting[path] != nil { waiting[path]?.append(done); return }
        waiting[path] = [done]
        DispatchQueue.global(qos: .userInitiated).async {
            let look = lookUp(path)
            DispatchQueue.main.async {
                kept[path] = look
                for done in waiting.removeValue(forKey: path) ?? [] { done(look) }
            }
        }
    }

    @MainActor static func look(_ path: String) async -> Look {
        await withCheckedContinuation { answer in find(path) { answer.resume(returning: $0) } }
    }

    /// The slow part. The icon is drawn into pixels here as well: an
    /// NSImage from NSWorkspace loads its pictures only when first drawn,
    /// which would put the disk back on the main thread.
    private static func lookUp(_ path: String) -> Look {
        lock.withLock { asked += 1 }
        let name = FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
        let found = NSWorkspace.shared.icon(forFile: path)
        let side: CGFloat = 64
        var rect = NSRect(x: 0, y: 0, width: side * 2, height: side * 2)
        let icon = found.cgImage(forProposedRect: &rect, context: nil, hints: nil)
            .map { NSImage(cgImage: $0, size: NSSize(width: side, height: side)) } ?? found
        return Look(name: name, icon: icon)
    }
}

/// An app's or a file's icon, from FinderLooks: the space it takes is held
/// empty until the icon is found, so nothing moves when it arrives.
struct FinderIcon: View {
    let path: String
    @State private var found: (path: String, icon: NSImage)?

    var body: some View {
        let icon = FinderLooks.kept(path)?.icon ?? (found?.path == path ? found?.icon : nil)
        Group {
            if let icon {
                Image(nsImage: icon).resizable().interpolation(.high)
            } else {
                Color.clear
            }
        }
        .task(id: path) {
            guard FinderLooks.kept(path) == nil else { return }
            let look = await FinderLooks.look(path)
            found = (path, look.icon)
        }
    }
}

/// The app web links open in now, by name and icon, for Settings › General
/// while Yab isn't it. Looked up when Settings opens and when Yab comes to
/// the front again (the default may have been changed elsewhere), never
/// from a view's body.
@MainActor
@Observable final class DefaultBrowser {
    static let shared = DefaultBrowser()

    struct App: Equatable {
        let path: String
        let name: String
        let icon: NSImage?

        static func == (a: App, b: App) -> Bool {
            a.path == b.path && a.name == b.name && (a.icon == nil) == (b.icon == nil)
        }
    }

    /// Nil until looked up, and while Yab is the one.
    private(set) var app: App?
    @ObservationIgnored private var looking = false
    @ObservationIgnored private var again = false

    func refresh() {
        guard !looking else { again = true; return }
        looking = true
        DispatchQueue.global(qos: .userInitiated).async {
            let handler = URL(string: "https://example.com").flatMap(NSWorkspace.shared.urlForApplication(toOpen:))
            let mine = handler?.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
            DispatchQueue.main.async {
                guard let handler, !mine else { return self.settle(nil) }
                let path = handler.path
                if let look = FinderLooks.kept(path) {
                    return self.settle(App(path: path, name: look.name, icon: look.icon))
                }
                // Its file name at once, so the words don't change under
                // you; the Finder's name and the icon when they come.
                self.set(App(path: path, name: FinderLooks.fileName(path), icon: nil))
                FinderLooks.find(path) { look in
                    self.settle(self.app?.path == path ? App(path: path, name: look.name, icon: look.icon) : self.app)
                }
            }
        }
    }

    private func settle(_ app: App?) {
        set(app)
        looking = false
        if again {
            again = false
            refresh()
        }
    }

    /// Published only when it changed, or every Settings opening would draw
    /// General again.
    private func set(_ new: App?) {
        if new != app { app = new }
    }
}
