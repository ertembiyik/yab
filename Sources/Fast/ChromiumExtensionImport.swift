import Foundation

/// A resumable metadata migration, separate from WebKit's package/storage trees.
/// Existing native installations belong to the user and are never overwritten.
@MainActor
enum ChromiumExtensionImport {
    static func pins(_ saved: [String], remembering item: Installed, order: [Installed]) -> [String] {
        var pins = Set(saved)
        if item.pinned == true { pins.insert(item.id) } else { pins.remove(item.id) }
        var seen = Set<String>()
        let migrated = order.map(\.id).filter { pins.contains($0) && seen.insert($0).inserted }
        return saved.filter { pins.contains($0) && !migrated.contains($0) && seen.insert($0).inserted } + migrated
    }

    struct Result: Equatable {
        enum State: String { case imported, existing, blocked, failed }
        let id: String
        let name: String
        let state: State
        let detail: String?
    }

    static func run(
        _ entries: [Installed], installed: Set<String>, pending: Set<String>,
        journal: (Set<String>) throws -> Void,
        install: (Installed) async throws -> Void,
        enable: (String, Bool) async throws -> Void,
        remember: (Installed) throws -> Void
    ) async throws -> [Result] {
        var pending = pending
        var known = installed
        var seen = Set<String>()
        var results: [Result] = []
        for item in entries where seen.insert(item.id).inserted {
            try Task.checkCancellation()
            if ApplePasswordExtensionRoute.intercept(item.id) {
                pending.remove(item.id)
                try journal(pending)
                results.append(Result(id: item.id, name: item.name, state: .blocked,
                                      detail: "Yab has Apple Passwords built in."))
                continue
            }
            if known.contains(item.id), !pending.contains(item.id) {
                results.append(Result(id: item.id, name: item.name, state: .existing, detail: nil))
                continue
            }
            guard item.fromStore, ChromiumExtensions.validID(item.id) else {
                results.append(Result(id: item.id, name: item.name, state: .blocked,
                                      detail: "Choose the original local folder and approve its native permissions before importing it."))
                continue
            }
            do {
                // Persist before native loading: a disable or metadata-write failure
                // must remain repairable after relaunch without reinstalling code.
                pending.insert(item.id)
                try journal(pending)
                if !known.contains(item.id) {
                    try await install(item)
                    known.insert(item.id)
                }
                try Task.checkCancellation()
                try await enable(item.id, item.enabled)
                try remember(item)
                var completed = pending
                completed.remove(item.id)
                try journal(completed)
                pending = completed
                results.append(Result(id: item.id, name: item.name, state: .imported, detail: nil))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                results.append(Result(id: item.id, name: item.name, state: .failed,
                                      detail: error.localizedDescription))
            }
        }
        return results
    }
}

@MainActor
extension ChromiumExtensions {
    struct Migration: Codable {
        var pending: Set<String> = []
        var pins: [String] = []
        /// Password managers pinned on arrival once (ChromiumColumn).
        var arrived: Set<String>?
        /// Store extensions the WebKit list's adoption has settled: here, or
        /// asking for more than was approved and left to Settings' Import.
        var adopted: Set<String>?
        /// Adopted, with what they kept under WebKit not yet across: tried
        /// again each launch while the Chromium side is still empty. Since
        /// the one list, each pass's storage crossing settles them.
        var storageOwed: Set<String>?
        /// Of `adopted`, those that asked for more and were left to
        /// Settings' Import: not in Chromium, so WebKit's copy still runs.
        var asking: Set<String>?
        /// Set once this profile has joined the one list: what it held when
        /// it last matched (ExtensionOneList.plan). Before that, `pins` is the
        /// profile's own pin order; after, the list keeps pins.
        var joined: Set<String>?
    }
    private var migrationFile: URL { Store.file("ChromiumImports").appendingPathComponent(profile + ".json") }

    /// Installed in this profile now, whatever the adoption's file says: an
    /// id adopted on paper but missing here (one that asked for more, from a
    /// file older than `asking`) keeps running on WebKit. The helper's list
    /// when one was read this run, and Chrome's own extension settings.
    static func inChromium(profile: String) -> Set<String> {
        var found = Set<String>()
        // Chrome's own rows: `items` also lists the one list's entries this
        // profile doesn't hold yet, whose WebKit copy must keep running.
        for (key, value) in profiles where key.hasPrefix("regular:" + profile + ":") && !value.rows.isEmpty {
            found.formUnion(value.rows.map(\.id))
        }
        let root = Store.file("Chromium").appendingPathComponent("space-" + profile)
        for name in ["Secure Preferences", "Preferences"] {
            guard let data = try? Data(contentsOf: root.appendingPathComponent(name)),
                  let prefs = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            found.formUnion(installed(inPreferences: prefs))
        }
        return found
    }

    /// The ids Chrome's settings list as installed, its own built-in ones
    /// (component, external component) left out.
    nonisolated static func installed(inPreferences prefs: [String: Any]) -> Set<String> {
        let settings = (prefs["extensions"] as? [String: Any])?["settings"] as? [String: Any] ?? [:]
        return Set(settings.compactMap { id, value in
            guard validID(id), let row = value as? [String: Any], let location = row["location"] as? Int,
                  ![5, 10].contains(location) else { return nil }
            return id
        })
    }
    func migration() throws -> Migration {
        guard !profile.isEmpty, profile.utf8.count <= 128,
              profile.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else {
            throw ImportError.invalidProfile
        }
        guard FileManager.default.fileExists(atPath: migrationFile.path) else { return Migration() }
        let data = try Data(contentsOf: migrationFile)
        guard data.count <= 1_000_000 else { throw ImportError.unreadableList }
        return try JSONDecoder().decode(Migration.self, from: data)
    }
    func saveMigration(_ state: Migration) throws {
        try FileManager.default.createDirectory(at: migrationFile.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(state).write(to: migrationFile, options: .atomic)
        let changed = pinCache != state.pins
        pinCache = state.pins
        if changed { pinRevision &+= 1 }
    }
    var pendingImport: Set<String> {
        (try? migration().pending) ?? []
    }
    /// Read once from disk; every write goes through saveMigration.
    var pinnedIDs: [String] {
        if #available(macOS 15.4, *), let list = oneList {
            return list.installed.filter { $0.pinned == true }.map(\.id)
        }
        _ = pinRevision
        if let pinCache { return pinCache }
        let read = (try? migration().pins) ?? []
        pinCache = read
        return read
    }

    func importList(_ entries: [Installed],
                    install: (Installed) async throws -> Void) async throws -> [ChromiumExtensionImport.Result] {
        guard !privateMode else { throw ImportError.privateProfile }
        guard !importing else { throw ImportError.inProgress }
        importing = true
        defer { importing = false }
        var state = try migration()
        let current = Set(try await list().map(\.id))
        let results = try await ChromiumExtensionImport.run(entries, installed: current, pending: state.pending,
            journal: { pending in
                var next = state
                next.pending = pending
                try self.saveMigration(next)
                state = next
            },
            install: install,
            enable: { try await self.setEnabled($0, $1) },
            remember: { item in
                var next = state
                next.pins = ChromiumExtensionImport.pins(state.pins, remembering: item, order: entries)
                try self.saveMigration(next)
                state = next
            })
        _ = try await list()
        return results
    }

    enum ImportError: LocalizedError {
        case privateProfile, invalidProfile, unreadableList, declined, inProgress
        var errorDescription: String? {
            switch self {
            case .privateProfile: return "Extension import is unavailable in private profiles"
            case .invalidProfile: return "Extension import requires a valid Chromium profile"
            case .inProgress: return "An extension import is already running in this profile"
            case .unreadableList: return "The saved Yab extension list could not be read"
            case .declined: return "Additional native permissions were not approved"
            }
        }
    }
}
