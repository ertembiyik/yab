import Combine
import Foundation
import SyncKit

/// Extensions and plugins another Mac has and this one doesn't yet, put in
/// one after another, never two at once: WebKit fails extension workers
/// started together (docs/sync.md, "Extensions and plugins"). Each waits in
/// its list's row in words. One that couldn't be fetched is tried again a
/// minute on, then five, fifteen and every hour after, and the moment the
/// network comes back; one that can't come in (files that aren't the other
/// Mac's, a package that won't open) says so and waits until what it would
/// put in changes, or the next launch; a Store release with code waits for
/// a catalog that lists it, and is tried when the next one comes.
@MainActor
@Observable final class SyncInstalls {
    static let shared = SyncInstalls()

    enum State: Equatable {
        case downloading, failed, refused, newer

        var words: String {
            switch self {
            case .downloading: return "Downloading…"
            case .failed: return "Couldn't download, trying again"
            case .refused: return "Couldn't install"
            case .newer: return "Needs a newer Yab"
            }
        }
    }

    struct Waiting: Identifiable, Equatable {
        let collection: String
        let item: String
        var name: String
        var sites: [String]
        var rung: String?
        var state: State = .downloading
        var tries = 0
        var next = Date.distantPast
        /// What of its record putting it in depends on (SyncAddons.signature),
        /// as last tried: a record changed in anything else isn't tried again.
        var tried: String?
        /// Waits for its parts, or for the Store's catalog.
        var parts = false
        var catalog = false
        /// "extension/<id>" or "plugin/<id>".
        var id: String { collection + "/" + item }
    }

    private(set) var waiting: [String: Waiting] = [:]
    /// The one being put in now.
    @ObservationIgnored private var current: String?
    @ObservationIgnored private var network: MailNetwork?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var bag = Set<AnyCancellable>()
    @ObservationIgnored private var generation = 0
    private let record: (SyncKit.Record.Key) -> SyncKit.Record?
    private let putIn: ((Waiting) async throws -> Void)?

    init(record: ((SyncKit.Record.Key) -> SyncKit.Record?)? = nil,
         putIn: ((Waiting) async throws -> Void)? = nil) {
        self.record = record ?? { SyncCenter.shared.journal?.record($0) }
        self.putIn = putIn
        // A catalog came: Store releases waiting on one are tried.
        StoreCatalog.shared.observed(\.version).dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { MainActor.assumeIsolated { self?.again { $0.catalog } } } }
            .store(in: &bag)
    }

    /// Made by a later Yab: waits for this one to be updated.
    struct Newer: Error {}
    /// Its parts are still on their way: waits for them, not the clock.
    struct Coming: Error {}
    /// A Store release with code the catalog here doesn't vouch for yet.
    struct Catalog: LocalizedError {
        let errorDescription: String?
        init(_ words: String) { errorDescription = words }
    }
    /// Can't come in as it is: waits for its record to change.
    struct Refused: LocalizedError {
        let errorDescription: String?
        init(_ words: String) { errorDescription = words }
    }
    /// Couldn't be fetched now: tried again.
    struct Unreached: LocalizedError {
        let errorDescription: String?
        init(_ words: String) { errorDescription = words }
    }

    /// Whether trying again later may help: the network, the stores'
    /// servers, a stand-in not there yet. Anything else is the package.
    nonisolated static func passing(_ error: Error) -> Bool {
        if error is URLError || error is Unreached || error is BoostShare.Busy { return true }
        if case Crx.Refused.download(let code)? = error as? Crx.Refused { return code >= 500 || code == 429 || code == 408 }
        return false
    }

    // MARK: Where packages come from

    /// A Web Store package by extension id, and a Store release by its
    /// revision. A test run never fetches from the network here: it reads
    /// `<id>.crx` and `<revision>.boost` from the folder YAB_SYNC_STANDINS
    /// names, or a test sets these to its own.
    static var crx: (String) async throws -> Data = { id in
        if Store.testing { return try standIn(id + ".crx") }
        return try await Crx.fetch(id)
    }

    static var boost: (String) async throws -> Data = { revision in
        if Store.testing { return try standIn(revision + ".boost") }
        return try await BoostShare.download(revision)
    }

    nonisolated static func standIn(_ name: String, in folder: String? = ProcessInfo.processInfo.environment["YAB_SYNC_STANDINS"]) throws -> Data {
        guard let folder, !name.contains("/"), !name.hasPrefix("."),
              let data = try? Data(contentsOf: URL(fileURLWithPath: folder).appendingPathComponent(name)) else {
            throw Unreached("A test run fetches nothing from the network; no stand-in for \(name)")
        }
        return data
    }

    // MARK: Waiting

    /// What sync says this Mac should have of a collection and hasn't:
    /// each waits its turn; what is no longer wanted stops waiting. One
    /// whose record changed in what putting it in depends on is tried now,
    /// and so is one waiting on parts when `parts` came.
    func want(_ collection: String, _ missing: [SyncKit.Record], parts: Bool = false) {
        let keys = Set(missing.map { collection + "/" + $0.id })
        for (key, item) in waiting where item.collection == collection && !keys.contains(key) { waiting[key] = nil }
        for record in missing {
            let key = collection + "/" + record.id
            var item = waiting[key] ?? Waiting(collection: collection, item: record.id, name: record.id, sites: [])
            item.name = record["name"]?.string ?? item.name
            item.sites = record["sites"]?.array?.compactMap(\.string) ?? item.sites
            item.rung = record["rung"]?.string
            if let tried = item.tried, tried != SyncAddons.signature(record) {
                item.next = .distantPast
                item.tries = 0
                item.state = .downloading
            } else if parts, item.parts {
                item.next = .distantPast
            }
            if waiting[key] != item { waiting[key] = item }
        }
        pump()
    }

    /// Sync off here, or this Mac out of it: nothing waits any more.
    func clear() {
        generation += 1
        waiting = [:]
        timer?.invalidate(); timer = nil
        network?.stop(); network = nil
    }

    /// Those waiting for a plugin, by site, for Site Controls.
    func plugins(on host: String?) -> [Waiting] {
        guard let host else { return [] }
        return waiting.values.filter { $0.collection == SyncAddons.plugin && ($0.sites.contains(host) || $0.sites.contains("<all_urls>")) }
            .sorted { $0.name < $1.name }
    }

    var extensions: [Waiting] {
        waiting.values.filter { $0.collection == SyncAddons.ext }.sorted { $0.name < $1.name }
    }

    nonisolated static func backoff(_ tries: Int) -> TimeInterval {
        [60, 300, 900][safe: tries - 1] ?? 3600
    }

    /// Those `which` picks, tried now.
    private func again(_ which: (Waiting) -> Bool) {
        for (key, item) in waiting where which(item) {
            waiting[key]?.next = .distantPast
            if item.state != .failed { waiting[key]?.state = .downloading }
        }
        pump()
    }

    /// The next one due, when none is being put in.
    private func pump() {
        defer { arm() }
        guard current == nil,
              let key = waiting.values.filter({ Date() >= $0.next }).map(\.id).sorted().first,
              let item = waiting[key] else { return }
        current = key
        let generation = generation
        Task {
            defer {
                current = nil
                pump()
            }
            let recordKey = SyncKit.Record.Key(collection: item.collection, id: item.item)
            let signature = record(recordKey).map(SyncAddons.signature)
            // A package or account may change during a download. Finishing
            // the old attempt must not discard the newer waiting request.
            @MainActor func stillCurrent() -> Bool {
                guard self.generation == generation, waiting[key] != nil else { return false }
                guard record(recordKey).map(SyncAddons.signature) == signature else {
                    waiting[key]?.next = .distantPast
                    waiting[key]?.tries = 0
                    waiting[key]?.state = .downloading
                    waiting[key]?.parts = false
                    waiting[key]?.catalog = false
                    return false
                }
                return true
            }
            waiting[key]?.tried = signature
            waiting[key]?.parts = false
            waiting[key]?.catalog = false
            do {
                if let putIn { try await putIn(item) }
                else { try await install(item) }
                guard stillCurrent() else { return }
                waiting[key] = nil
            } catch is Coming {
                guard stillCurrent() else { return }
                waiting[key]?.parts = true
                waiting[key]?.next = .distantFuture
            } catch is Newer {
                guard stillCurrent() else { return }
                waiting[key]?.state = .newer
                waiting[key]?.next = .distantFuture
            } catch let held as Catalog {
                guard stillCurrent() else { return }
                waiting[key]?.catalog = true
                waiting[key]?.state = .refused
                let tries = (waiting[key]?.tries ?? 0) + 1
                waiting[key]?.tries = tries
                waiting[key]?.next = Date().addingTimeInterval(Self.backoff(tries))
                NSLog("sync: %@ waits for the Store: %@", key, held.errorDescription ?? "")
            } catch {
                guard stillCurrent() else { return }
                guard var now = waiting[key] else { return }
                if Self.passing(error) {
                    now.tries += 1
                    now.state = .failed
                    now.next = Date().addingTimeInterval(Self.backoff(now.tries))
                } else {
                    now.state = .refused
                    now.next = .distantFuture
                }
                waiting[key] = now
                NSLog("sync: couldn't put %@ in: %@", key, error.localizedDescription)
            }
        }
    }

    /// The clock and the network, while something waits on them.
    private func arm() {
        let failed = waiting.values.contains { $0.state == .failed || $0.catalog }
        if failed, timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pump() }
            }
        } else if !failed {
            timer?.invalidate(); timer = nil
        }
        if failed, network == nil {
            network = MailNetwork { [weak self] in DispatchQueue.main.async { MainActor.assumeIsolated { self?.again { $0.state == .failed || $0.catalog } } } }
        } else if !failed {
            network?.stop(); network = nil
        }
    }

    // MARK: Putting in

    /// The record as the account has it now, while it is still wanted here
    /// (SyncMirror.wanted: the switch on, not removed here meanwhile).
    private func account(_ key: SyncKit.Record.Key, journal expected: Journal? = nil) -> (Journal, SyncKit.Record)? {
        guard let journal = SyncCenter.shared.journal, let mirror = SyncCenter.shared.mirror,
              expected == nil || journal === expected,
              mirror.wanted(key, in: journal), let record = journal.record(key) else { return nil }
        return (journal, record)
    }

    private func install(_ item: Waiting) async throws {
        let key = SyncKit.Record.Key(collection: item.collection, id: item.item)
        guard let (journal, record) = account(key) else { return }
        guard record.schema <= SyncAddons.schema else { throw Newer() }
        if item.collection == SyncAddons.ext {
            let data = try await Self.crx(item.item)
            guard let (_, now) = account(key, journal: journal) else { return }
            // Asked again right before it goes in, after unpacking: removed
            // meanwhile, it doesn't.
            let wanted = { [weak self] in self?.account(key, journal: journal) != nil }
            if try await Extensions.shared.adoptSynced(item.item, crx: data, enabled: now["enabled"]?.bool ?? true,
                                                       pinned: now["pinned"]?.bool ?? false,
                                                       allowed: now["permissions"]?.array?.compactMap(\.string) ?? [], wanted: wanted) {
                SyncCenter.shared.mirror?.installed(key)
            }
            return
        }
        guard let digest = record["digest"]?.string, let rung = BoostPackage.Rung(rawValue: record["rung"]?.string ?? "") else { throw Newer() }
        let package: BoostPackage
        var release: (store: String, revision: String)?
        if let store = record["store"]?.string, let revision = record["revision"]?.string {
            var code = try storeCheck(store, revision: revision, rung: rung)
            let data = try await Self.boost(revision)
            // The catalog may have moved while it came.
            code = try storeCheck(store, revision: revision, rung: rung)
            let id = record.id, reviewed = code ? revision : nil
            let read = await Task.detached(priority: .utility) { () -> Result<BoostPackage, Error> in
                guard let envelope = try? JSONDecoder().decode(BoostShare.Envelope.self, from: data) else { return .failure(Refused("The Store's package can't be read")) }
                guard envelope.payload.format <= 1 else { return .failure(Newer()) }
                do { return .success(try BoostShare.read(data, id: id, reviewed: reviewed)) }
                catch {
                    // Read by the Yab that kept it, and not by this one: a later one's.
                    if (try? BoostPackage.read(id: id, files: envelope.payload.files, sites: envelope.payload.sites)) == nil { return .failure(Newer()) }
                    return .failure(Refused(error.localizedDescription))
                }
            }.value
            package = try read.get()
            release = (store, revision)
        } else {
            let id = record.id
            let assembly = await Task.detached(priority: .utility) {
                SyncAddons.assemble(record) { journal.record(.init(collection: SyncAddons.part, id: $0)) }
            }.value
            switch assembly {
            case .waiting: throw Coming()
            case .broken: throw Refused("Its parts don't make the files the other Mac kept")
            case .newer: throw Newer()
            case .ready(let files, let sites):
                guard let read = await Task.detached(priority: .utility, operation: { try? BoostPackage.read(id: id, files: files, sites: sites) }).value
                else { throw Newer() }
                package = read
            }
        }
        let same = await Task.detached(priority: .utility) {
            (try? BoostShare.digest(.init(format: 1, id: package.id, sites: package.sites, files: package.files))) == digest
        }.value
        guard same else { throw Refused("These aren't the files the other Mac kept") }
        // Nothing awaited from here to the keep: wanted now is wanted then.
        guard let (_, now) = account(key, journal: journal), now["digest"]?.string == digest else { return }
        if let release { _ = try storeCheck(release.store, revision: release.revision, rung: rung) }
        try Boosts.shared.keepSynced(package, author: now["author"]?.string ?? "You", enabled: now["enabled"]?.bool ?? true,
                                     runsOn: now["runsOn"]?.string, synced: true)
        if let release { StoreCatalog.shared.noteSynced(record.id, catalog: release.store, revision: release.revision) }
        SyncCenter.shared.mirror?.installed(key)
    }

    /// Whether a Store release comes in as code: the catalog here asked for
    /// again when it is old, and the release waiting until one lists it.
    private func storeCheck(_ store: String, revision: String, rung: BoostPackage.Rung) throws -> Bool {
        let catalog = StoreCatalog.shared
        switch SyncAddons.storeCheck(rung: rung, revision: revision, listing: catalog.item(store), origin: catalog.origin,
                                     listed: catalog.items, fresh: catalog.fresh) {
        case .look: return false
        case .code: return true
        case .catalog(let why):
            if !catalog.fresh { catalog.refresh(force: true) }
            throw Catalog(why)
        }
    }
}
