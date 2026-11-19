import Combine
import Foundation
import WebKit

// chrome.readingList, as a folder of your bookmarks: "Reading List", at the
// top of them, made the first time an extension adds to it, each entry a
// bookmark there. Whether an entry has been read, and when it was added and
// last changed, are kept beside it by its address, since a bookmark has no
// such thing; an entry taken out of the folder by hand is gone from the
// list, as it is from Chrome's when removed there.
//
// onEntryAdded, onEntryUpdated and onEntryRemoved: a context of an
// extension with the permission that listens opens a port (the shim does,
// at its first listener, never before), and every change to the list, an
// extension's or one made by hand in Bookmarks, is told over each such
// port, the entry as it is after (as it was, for a removal). Bookmarks are
// watched only while a port is open.

@available(macOS 15.4, *)
@MainActor
enum ExtensionReadingList {
    static let folderName = "Reading List"
    private static let stateKey = "extensions.readingList"
    nonisolated static let portName = ExtensionShims.application + ".readinglist"

    private static var ports: [String: [WKWebExtension.MessagePort]] = [:]
    private static var watch: AnyCancellable?
    private static var last: [[String: Any]] = []

    static func connect(_ port: WKWebExtension.MessagePort, from id: String) {
        ports[id] = (ports[id] ?? []).filter { !$0.isDisconnected } + [port]
        port.disconnectHandler = { [weak port] _ in
            MainActor.assumeIsolated {
                ports[id] = (ports[id] ?? []).filter { $0 !== port && !$0.isDisconnected }
                if ports[id]?.isEmpty == true { ports[id] = nil }
                if ports.isEmpty { watch = nil }
            }
        }
        guard watch == nil else { return }
        last = entries()
        watch = Bookmarks.shared.observed(\.roots).dropFirst().sink { _ in
            // @Published tells before it sets: read once it has.
            DispatchQueue.main.async { changed() }
        }
    }

    /// What changed since last told, to every listening context.
    static func changed() {
        guard !ports.isEmpty else { return }
        let now = entries()
        let events = diff(last, now)
        last = now
        guard !events.isEmpty else { return }
        for port in ports.values.joined() where !port.isDisconnected { port.sendMessage(["e": events]) { _ in } }
    }

    /// Chrome's events between two lists of entries, by address: removals,
    /// then additions and changes in the list's order.
    nonisolated static func diff(_ before: [[String: Any]], _ after: [[String: Any]]) -> [[Any]] {
        func url(_ entry: [String: Any]) -> String { entry["url"] as? String ?? "" }
        let was = Dictionary(before.map { (url($0), $0) }, uniquingKeysWith: { first, _ in first })
        let now = Set(after.map(url))
        var events: [[Any]] = before.filter { !now.contains(url($0)) }.map { ["onEntryRemoved", $0] }
        for entry in after {
            guard let old = was[url(entry)] else {
                events.append(["onEntryAdded", entry])
                continue
            }
            if !NSDictionary(dictionary: old).isEqual(to: entry) { events.append(["onEntryUpdated", entry]) }
        }
        return events
    }

    private static var folder: Bookmark? {
        Bookmarks.shared.roots.first { $0.isFolder && $0.title == folderName }
    }

    private static var state: [String: [String: Any]] {
        get { Store.settings.dictionary(forKey: stateKey) as? [String: [String: Any]] ?? [:] }
        set { Store.settings.set(newValue, forKey: stateKey) }
    }

    private static func entries() -> [[String: Any]] {
        let kept = state
        return (folder?.children ?? []).compactMap { node in
            guard let url = node.url else { return nil }
            let mine = kept[url] ?? [:]
            let added = (mine["creationTime"] as? Double) ?? (node.added?.timeIntervalSince1970 ?? 0) * 1000
            return ["url": url, "title": node.title, "hasBeenRead": mine["hasBeenRead"] as? Bool ?? false,
                    "creationTime": added, "lastUpdateTime": (mine["lastUpdateTime"] as? Double) ?? added]
        }
    }

    static func run(_ api: String, _ args: [Any]) throws -> Any? {
        let spec = args.first as? [String: Any] ?? [:]
        let url = spec["url"] as? String
        let now = Date().timeIntervalSince1970 * 1000
        switch api {
        case "readingList.query":
            return entries().filter { entry in
                if let url, entry["url"] as? String != url { return false }
                if let title = spec["title"] as? String, entry["title"] as? String != title { return false }
                if let read = spec["hasBeenRead"] as? Bool, entry["hasBeenRead"] as? Bool != read { return false }
                return true
            }
        case "readingList.addEntry":
            guard let url, let address = URL(string: url), ["http", "https"].contains(address.scheme ?? "") else {
                throw ExtensionShims.Unsupported(what: "URL is not valid.")
            }
            if entries().contains(where: { $0["url"] as? String == url }) { throw ExtensionShims.Unsupported(what: "Duplicate URL.") }
            let home = folder ?? Bookmarks.shared.insert(Bookmark(title: folderName, url: nil, children: []), into: nil)
            _ = Bookmarks.shared.insert(Bookmark.site(spec["title"] as? String ?? "", address), into: home.id)
            var kept = state
            kept[url] = ["hasBeenRead": spec["hasBeenRead"] as? Bool ?? false, "creationTime": now, "lastUpdateTime": now]
            state = kept
            changed()
            return nil
        case "readingList.updateEntry":
            guard let url, let node = folder?.children?.first(where: { $0.url == url }) else { throw ExtensionShims.Unsupported(what: "URL not found.") }
            if let title = spec["title"] as? String { Bookmarks.shared.update(node.id, title: title, url: nil) }
            var kept = state
            var mine = kept[url] ?? ["creationTime": now]
            if let read = spec["hasBeenRead"] as? Bool { mine["hasBeenRead"] = read }
            mine["lastUpdateTime"] = now
            kept[url] = mine
            state = kept
            changed()
            return nil
        case "readingList.removeEntry":
            guard let url, let node = folder?.children?.first(where: { $0.url == url }) else { throw ExtensionShims.Unsupported(what: "URL not found.") }
            Bookmarks.shared.remove(node.id)
            var kept = state
            kept[url] = nil
            state = kept
            changed()
            return nil
        default:
            throw ExtensionShims.Unsupported(what: "\(api) isn't available in Yab")
        }
    }
}
