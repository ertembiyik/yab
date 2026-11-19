import AppKit
import Combine
import Foundation
import YabCoreClient

// A CEF profile kept in step with its sign-in's one list (ExtensionOneList).
//
// `converge` compares the list with what Chrome holds and does what differs. It
// runs when the first page opens in a profile and again after any change to the
// list, from either engine. Nothing here decides what is installed: the list
// does, and an extension that asks Chromium for more than was approved stays in
// the list and is asked about, in Yab's own question, once.
//
// Grants and storage take a page of the extension's own, so they cross when an
// extension arrives or turns on, and otherwise only when a file moved.

@MainActor
extension ChromiumExtensions {
    @available(macOS 15.4, *)
    var oneList: Extensions? { joined.map { Extensions.instance($0.signIn) } }

    /// The list's entries in its order, Chrome's rows for those it has, then
    /// whatever Chrome has that the list hasn't taken in yet.
    @available(macOS 15.4, *)
    func composed(_ rows: [Item], list: [Installed]) -> [Item] {
        let held = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var out: [Item] = []
        for entry in list {
            var row = held[entry.id] ?? Item(absent: entry, icon: Self.shippedIcon(entry.id))
            row.issue = loadFailures[entry.id]
            if entry.source != nil && !ChromiumExtensions.validID(entry.id) {
                row.issue = "Remove this older install, then load its folder again to enable it in Chromium."
            }
            out.append(row)
        }
        let listed = Set(list.map(\.id))
        return out + rows.filter { !listed.contains($0.id) }
    }

    @available(macOS 15.4, *)
    private static func shippedIcon(_ id: String) -> Data? {
        let folder = Extensions.folder(for: id)
        guard let manifest = try? ChromiumExtensionPackages.manifest(in: folder), let file = Chromium.icon(manifest, in: folder) else { return nil }
        return try? Data(contentsOf: file)
    }

    /// This profile follows `signIn`'s list from now on. The first time ever,
    /// the two lists become one (`ExtensionOneList.merged`).
    @available(macOS 15.4, *)
    func joinList(signIn: UUID?) {
        guard !privateMode, !adopting, !ExtensionOneList.off else { return }
        adopting = true
        joined = Joined(signIn: signIn)
        following = Extensions.listsChanged
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.compose()
                    self.oneList?.revision &+= 1
                    self.converge()
                }
            }
        sweeper = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                // A running WebKit copy can write too; at rest only Chromium does.
                let awake = self?.oneList?.contexts.isEmpty == false
                try? await Task.sleep(for: .seconds(awake ? 20 : 300))
                guard let self, ChromiumProcess.shared.connectedClient != nil else { continue }
                self.converge()
                await self.crossEach(nil)
            }
        }
        converge(force: true)
    }

    /// What Chrome is compared with: the list and where each may reach.
    @available(macOS 15.4, *)
    private func signature(_ list: Extensions) -> Data {
        let places = list.installed.map { [$0.id, list.access($0.id).rawValue] + list.allowed($0.id) + Extensions.choices($0.id).keys.sorted() }
        return (try? JSONEncoder().encode([try? JSONEncoder().encode(list.installed), try? JSONEncoder().encode(places)])) ?? Data()
    }

    /// Runs one pass, or one more after the pass under way. Without `force`,
    /// only if the list changed, and only while the helper is up: one missed
    /// then waits for the next pass, which compares everything. A pass that
    /// fails ends the run, as the next change or sweep starts it again: an
    /// install it couldn't take in would otherwise ask for one more forever.
    @available(macOS 15.4, *)
    func converge(force: Bool = false) {
        guard let list = oneList, list.loaded else { return }
        guard force || ChromiumProcess.shared.connectedClient != nil else { return }
        if !force, lastSignature == signature(list) { return }
        guard !converging else { convergeAgain = true; return }
        converging = true
        Task(priority: .utility) { @MainActor in
            defer { converging = false }
            repeat {
                convergeAgain = false
                lastSignature = signature(list)
                do { try await convergeOnce(list) }
                catch is CancellationError { return }
                catch {
                    NSLog("Chromium extensions: list not matched: %@", String(describing: error))
                    lastSignature = nil
                    return
                }
            } while convergeAgain
        }
    }

    @available(macOS 15.4, *)
    private func convergeOnce(_ list: Extensions) async throws {
        var native = try await self.list()
        var state = try migration()
        if state.joined == nil {
            list.joinList(ExtensionOneList.merged(webKit: list.installed, native: native.map(Self.row), pins: state.pins))
            ChromiumExtensionGrants.adoptAccess(native, into: list)
            state.joined = Set(native.map(\.id))
            try saveMigration(state)
            crossing.formUnion(list.installed.filter(\.enabled).map(\.id))
            NSLog("Chromium extensions: lists joined, %d in all", list.installed.count)
        }
        // Once a launch, and for each one whose choices changed since.
        let choices = Dictionary(list.installed.filter(\.enabled).map { ($0.id, Extensions.choices($0.id)) }, uniquingKeysWith: { first, _ in first })
        crossing.formUnion(choices.filter { lastChoices?[$0.key] != $0.value }.keys)
        lastChoices = choices
        let plan = ExtensionOneList.plan(list: list.installed, native: native.map(Self.row), known: state.joined ?? [])
        for id in plan.dropFromChromium {
            ChromiumConsent.approve("uninstall", id)
            defer { ChromiumConsent.withdrawApproval("uninstall", id) }
            do {
                _ = try await request("extension.remove", params: ["extension": .string(id), "userApproved": .bool(true)])
                ChromiumExtensionStorage.forget(id, profile: profile)
            } catch { NSLog("Chromium extensions: %@ not removed: %@", id, String(describing: error)) }
        }
        for row in plan.addToList {
            list.takeNative(id: row.id, name: row.name, version: row.version, enabled: row.enabled)
            if row.enabled { crossing.insert(row.id) }
        }
        for item in plan.bringToChromium { await bring(item, list) }
        await fillWebKitFolders(list)
        native = try await self.list()
        for row in native {
            guard let item = list.installed.first(where: { $0.id == row.id }) else { continue }
            await arm(row)
            guard row.state == "ENABLED" || row.state == "DISABLED" else { continue }
            let wanted = item.enabled && item.wants == nil
            if wanted, !row.enabled, row.escalated {
                await grewInUpdate(row, item, list)
                continue
            }
            if row.enabled != wanted {
                do {
                    try await applyEnabled(row.id, wanted)
                    if wanted { crossing.insert(row.id) }
                } catch { NSLog("Chromium extensions: %@ not switched: %@", row.id, String(describing: error)) }
            }
            if wanted {
                await pushAccess(row, list)
                await pushUserScripts(row, item, list)
            }
        }
        native = try await self.list()
        state = try migration()
        // Not every id Chrome holds now: one installed while this pass ran
        // isn't in the list yet, and the next pass must add it, not drop it.
        state.joined = ExtensionOneList.matched(native: native.map(\.id), list: list.installed, known: state.joined ?? [])
        try saveMigration(state)
        compose()
        if !crossing.isEmpty {
            let going = crossing
            crossing = []
            await crossEach(going)
        }
        askQueued(list)
        moveToStoreInstalls(native, list)
        askChromeToCheck(native, list)
        followChrome(native, list)
    }

    private static func row(_ item: Item) -> ExtensionOneList.Native {
        .init(id: item.id, name: item.name, version: item.version, enabled: item.enabled)
    }

    // MARK: to Chromium

    /// A kept package with the store's own file beside it, so Chrome can
    /// install it as the store's; else the store's current one.
    private static func packageFolder(_ id: String) async throws -> URL {
        let root = Store.file("ChromiumPackages")
        if let kept = ChromiumExtensionPackages.existing(id, root: root), ChromiumExtensionPackages.original(of: kept, id: id) != nil { return kept }
        let data = try await ChromiumExtensionPackages.fetch(id)
        return try await Task.detached(priority: .utility) {
            try ChromiumExtensionPackages.prepare(data, id: id, root: root)
        }.value
    }

    /// The grants of the manifest the person said yes to, as WebKit keeps it.
    @available(macOS 15.4, *)
    private static func approvedManifest(_ id: String) -> Set<String> {
        guard let manifest = try? ChromiumExtensionPackages.manifest(in: Extensions.folder(for: id)) else { return [] }
        return ChromiumExtensionGrants.required(in: manifest)
    }

    /// One the list has and Chrome hasn't. Already approved: loaded, in the
    /// state the list says. Wanting more than was approved: on, it is asked
    /// about; off, it waits to be turned on. Never left out of the list.
    @available(macOS 15.4, *)
    private func bring(_ item: Installed, _ list: Extensions) async {
        guard !ApplePasswordExtensionRoute.matches(item.id), item.wants == nil, !unfetched.contains(item.id), !asking.contains(item.id) else { return }
        do {
            let folder: URL
            if let source = item.source {
                folder = try ChromiumExtensionPackages.existingUnpacked(item.id)
                    ?? ChromiumExtensionPackages.prepareUnpacked(URL(fileURLWithPath: source), id: item.id)
            }
            else { folder = try await Self.packageFolder(item.id) }
            let manifest = try ChromiumExtensionPackages.manifest(in: folder)
            let beyond = ChromiumExtensionGrants.beyondApproval(required: ChromiumExtensionGrants.required(in: manifest),
                                                                saved: ChromiumExtensionGrants.normalized(item.permissions),
                                                                approvedManifest: Self.approvedManifest(item.id))
            guard beyond.isEmpty else {
                list.holdForChromium(item.id, asks: Array(beyond), turnOff: false)
                if item.enabled {
                    asking.insert(item.id)
                    questions.append(.init(id: item.id, name: item.name, beyond: beyond, folder: folder))
                }
                return
            }
            // Installed long ago in WebKit, new to Chromium: Chrome's
            // "install" to it is told as an update (ChromiumArrivalHook), so it
            // opens no welcome page. Only Yab's own folder starts its worker
            // with that hook, so a store one loads from it too; the move to
            // Chrome's store install follows on this pass, which Chrome itself
            // tells as an update (moveToStoreInstalls).
            _ = try ChromiumExtensionPackages.arm(folder, broughtIn: true)
            try await load(folder: folder)
            guard try await self.list().contains(where: { $0.id == item.id }) else { throw Crx.Refused.unpack }
            if item.enabled { crossing.insert(item.id) } else { try await applyEnabled(item.id, false) }
        } catch is CancellationError {
        } catch {
            unfetched.insert(item.id)
            loadFailures[item.id] = "Couldn’t run in Chromium: \(error.localizedDescription)"
            compose()
            NSLog("Chromium extensions: %@ didn't arrive: %@", item.id, String(describing: error))
        }
    }

    /// One question at a time, after the pass, so none holds the rest up.
    @available(macOS 15.4, *)
    private func askQueued(_ list: Extensions) {
        guard !questions.isEmpty, !questioning else { return }
        questioning = true
        Task { @MainActor in
            defer { questioning = false }
            while !questions.isEmpty {
                let next = questions.removeFirst()
                let manifest = try? ChromiumExtensionPackages.manifest(in: next.folder)
                let icon = manifest.flatMap { Chromium.icon($0, in: next.folder) }.flatMap { NSImage(contentsOf: $0) }
                let yes = await Questions.shared.ask(Question(
                    title: "\(next.name) wants more", detail: "This version asks for additional access.",
                    lines: ChromiumInstallWords.lines(next.beyond),
                    icon: ExtensionIconShape.rounded(icon), yes: "Turn On", no: "Not Now", place: .plain))
                asking.remove(next.id)
                if yes { list.allowOnChromium(next.id, Array(next.beyond)) }
                else { list.holdForChromium(next.id, asks: Array(next.beyond), turnOff: true) }
            }
        }
    }

    /// Chrome reads a worker's file when it registers it, so a package from
    /// before the hook takes it with one reload, once. A store install takes
    /// it in the folder Chrome installed, again after each update (a new
    /// folder); Chrome doesn't check a store install's files in this build
    /// (content verification is a Google Chrome build's). Off and on is no
    /// install: Chrome tells it nothing (no runtime.onInstalled), and the
    /// tabs it opens after are its own, as in Chromium.
    ///
    /// Never under a page of its own. Chrome doesn't reload an extension it
    /// has just installed, and closes the tabs of one it unloads; this reload
    /// came right after Chrome's runtime.onInstalled and left the tab opened
    /// there without its chrome.* (Toggl Track's onboarding, where it asks
    /// which sites may show its button: switching one on did nothing;
    /// register 2358). While Chrome lists a page of it, the hook waits for a
    /// later pass, at the latest the next launch; set icons it misses until
    /// then still arrive from the hook put in over CDP when Yab reads it.
    private func arm(_ row: Item) async {
        guard let path = row.path, !row.hasOpenPages else { return }
        let roots = [Store.file("ChromiumPackages").path,
                     Store.file("Chromium").appendingPathComponent("space-" + profile).appendingPathComponent("Extensions").path]
        guard ChromiumStoreInstalls.armable(path, roots: roots),
              (try? ChromiumExtensionPackages.arm(URL(fileURLWithPath: path))) == true, row.enabled else { return }
        do {
            try await applyEnabled(row.id, false)
            try await applyEnabled(row.id, true)
        } catch { NSLog("Chromium extensions: %@ not reloaded: %@", row.id, String(describing: error)) }
    }

    // MARK: store installs

    /// Store extensions Yab loaded unpacked before (ChromiumStoreInstalls)
    /// move to Chrome's own store install, one at a time, once a launch:
    /// the store's current CRX over the unpacked copy, same id, so all it
    /// kept stays. One whose current version asks for more than was
    /// approved is asked about first, as WebKit's update asks; until a yes,
    /// the version it has keeps running. A pass follows, which puts back
    /// what Chrome's install reset (on or off, site access).
    @available(macOS 15.4, *)
    private func moveToStoreInstalls(_ native: [Item], _ list: Extensions) {
        let due = ChromiumStoreInstalls.toMove(native.map(\.storeRow), list: list.installed, packages: Store.file("ChromiumPackages").path)
            .filter { !storeMoves.contains($0) && !asking.contains($0) && !ApplePasswordExtensionRoute.matches($0) }
        guard !due.isEmpty, !movingToStore else { return }
        storeMoves.formUnion(due)
        movingToStore = true
        Task(priority: .utility) { @MainActor in
            defer { movingToStore = false }
            guard await canInstallCrx() else { return }
            var moved = false
            for id in due {
                guard let row = rows.first(where: { $0.id == id }), row.location == ChromiumStoreInstalls.unpacked,
                      let item = list.installed.first(where: { $0.id == id }) else { continue }
                do {
                    let data = try await ChromiumExtensionPackages.fetch(id)
                    let root = Store.file("ChromiumPackages")
                    let folder = try await Task.detached(priority: .utility) {
                        try ChromiumExtensionPackages.prepare(data, id: id, root: root)
                    }.value
                    let manifest = try ChromiumExtensionPackages.manifest(in: folder)
                    let version = manifest["version"] as? String ?? ""
                    guard ChromiumStoreInstalls.installs(version, over: row.version),
                          let crx = ChromiumExtensionPackages.original(of: folder, id: id) else {
                        NSLog("Chromium extensions: %@ stays unpacked: the store has %@, Chrome %@", id, version, row.version)
                        continue
                    }
                    // As Chromium judges an update: against what the copy it runs
                    // has (approved when it came), and what the list approved.
                    let running = row.path.flatMap { try? ChromiumExtensionPackages.manifest(in: URL(fileURLWithPath: $0)) }
                        .map(ChromiumExtensionGrants.required(in:)) ?? []
                    let beyond = ChromiumExtensionGrants.beyondApproval(required: ChromiumExtensionGrants.required(in: manifest),
                                                                        saved: ChromiumExtensionGrants.normalized(item.permissions).union(running),
                                                                        approvedManifest: Self.approvedManifest(id).union(running))
                    if !beyond.isEmpty {
                        // "Not Now" to this version holds until the store has another.
                        let declined = "extensions.storeMoveDeclined." + id
                        guard Store.settings.string(forKey: declined) != version else { continue }
                        let icon = Chromium.icon(manifest, in: folder).flatMap { NSImage(contentsOf: $0) }
                        asking.insert(id)
                        let yes = await Questions.shared.ask(Question(
                            title: "\(item.name)’s update wants more",
                            detail: "Until you say yes, the version you have keeps running. Updated, it could also:",
                            lines: ChromiumInstallWords.lines(beyond),
                            icon: ExtensionIconShape.rounded(icon), yes: "Update", no: "Not Now", place: .plain))
                        asking.remove(id)
                        guard yes else { Store.settings.set(version, forKey: declined); continue }
                        list.allowOnChromium(id, Array(beyond))
                    }
                    // Over the unpacked copy of the same id, Chrome tells it
                    // "update" from that version, never "install"
                    // (ChromiumArrivalHook): nothing of its is a welcome page.
                    // Chrome holds back an update of an extension in use until
                    // it is idle (UpdateInstallGate), and Yab keeps its worker
                    // busy: off for the install, it goes in at once. Chrome
                    // keeps it off after (inherited disable reason); on again
                    // here, as the list has it.
                    if row.enabled { try await applyEnabled(id, false) }
                    let installed: String
                    do { installed = try await installCrx(crx, id: id) }
                    catch {
                        if row.enabled { try? await applyEnabled(id, true) }
                        throw error
                    }
                    // The hook goes into Chrome's folder while it is off, so the
                    // worker starts with it and no reload follows (arm).
                    let installs = Store.file("Chromium").appendingPathComponent("space-" + profile).appendingPathComponent("Extensions")
                    if let folder = ChromiumStoreInstalls.installedFolder(root: installs, id: id, version: version) {
                        _ = try? ChromiumExtensionPackages.arm(folder)
                    }
                    if row.enabled { try await applyEnabled(id, true) }
                    moved = true
                    NSLog("Chromium extensions: %@ is a store install now, %@ (was unpacked %@)", id, installed, row.version)
                } catch {
                    NSLog("Chromium extensions: %@ stays unpacked this launch: %@", id, String(describing: error))
                }
            }
            if moved {
                _ = try? await self.list()
                converge(force: true)
            }
        }
    }

    /// Chrome's updater put in a version that asks for more and turned it
    /// off until that is allowed, as Chromium does (where Chromium would show its
    /// "needs new permissions" card). What the list approved already turns
    /// it on again at once, with the gesture Chrome wants and its re-enable
    /// question answered yes; anything beyond is asked about once, after the
    /// pass, as the move's question is: "Turn On" allows it (the next pass
    /// turns it on), "Not Now" turns it off in the list too.
    @available(macOS 15.4, *)
    private func grewInUpdate(_ row: Item, _ item: Installed, _ list: Extensions) async {
        guard !asking.contains(row.id), let path = row.path,
              let manifest = try? ChromiumExtensionPackages.manifest(in: URL(fileURLWithPath: path)) else { return }
        let beyond = ChromiumExtensionGrants.beyondApproval(required: ChromiumExtensionGrants.required(in: manifest),
                                                            saved: ChromiumExtensionGrants.normalized(item.permissions),
                                                            approvedManifest: Self.approvedManifest(row.id))
        guard beyond.isEmpty else {
            asking.insert(row.id)
            questions.append(.init(id: row.id, name: item.name, beyond: beyond, folder: URL(fileURLWithPath: path)))
            return
        }
        ChromiumConsent.approve("reenable", row.id)
        defer { ChromiumConsent.withdrawApproval("reenable", row.id) }
        do {
            try await applyEnabled(row.id, true, approved: true)
            crossing.insert(row.id)
            NSLog("Chromium extensions: %@ on again after Chrome updated it to %@", row.id, row.version)
        } catch { NSLog("Chromium extensions: %@ not on again after its update: %@", row.id, String(describing: error)) }
    }

    /// Chrome's updater is ahead of the list: the WebKit copy takes the same
    /// version now, not at its next daily check, so the two engines (and the
    /// storage carried between them) never run two versions of one extension.
    @available(macOS 15.4, *)
    private func followChrome(_ native: [Item], _ list: Extensions) {
        let ahead = Set(ChromiumStoreInstalls.ahead(native.map(\.storeRow), list: list.installed)).subtracting(followed)
        guard !ahead.isEmpty else { return }
        followed.formUnion(ahead)
        for key in ahead {
            guard let id = key.split(separator: "@").first.map(String.init) else { continue }
            list.followChromium(id)
        }
    }

    /// The list is ahead of a store install: WebKit's daily check found a
    /// newer version. Chrome's updater looks now, once for that version,
    /// rather than at its next check up to five hours away.
    @available(macOS 15.4, *)
    private func askChromeToCheck(_ native: [Item], _ list: Extensions) {
        let behind = Set(ChromiumStoreInstalls.behind(native.map(\.storeRow), list: list.installed)).subtracting(updateAsks)
        guard !behind.isEmpty else { return }
        updateAsks.formUnion(behind)
        Task(priority: .utility) { @MainActor in
            do {
                try await checkForUpdates()
                // What it put in is read now: a moved version takes the hook
                // again in a pass (list() notices it).
                _ = try await self.list()
            } catch { NSLog("Chromium extensions: Chrome's update check failed: %@", String(describing: error)) }
        }
    }

    @available(macOS 15.4, *)
    private func pushAccess(_ row: Item, _ list: Extensions) async {
        guard let change = ChromiumExtensionGrants.accessChange(row, access: list.access(row.id), allowed: list.allowed(row.id)) else { return }
        do {
            _ = try await request("extension.access", params: [
                "extension": .string(row.id), "hostAccess": .string(change.hostAccess),
                "add": .array(change.add.map { .string($0) }), "remove": .array(change.remove.map { .string($0) })])
        } catch { NSLog("Chromium extensions: access of %@ not set: %@", row.id, String(describing: error)) }
    }

    /// "Allow user scripts" as the one list says; one turned on in Chrome
    /// before the list chose is taken in, so every profile follows it.
    @available(macOS 15.4, *)
    private func pushUserScripts(_ row: Item, _ item: Installed, _ list: Extensions) async {
        guard row.userScriptsChangeable else { return }
        if item.userScripts == nil, row.userScripts { list.setUserScripts(row.id, true); return }
        guard let on = Self.userScriptsChange(row, wanted: item.userScripts) else { return }
        do {
            _ = try await request("extension.userScripts", params: ["extension": .string(row.id), "enabled": .bool(on)])
        } catch { NSLog("Chromium extensions: user scripts of %@ not set: %@", row.id, String(describing: error)) }
    }

    @available(macOS 15.4, *)
    func reloadUnpacked(_ item: Installed) async throws {
        guard let source = item.source, ExtensionOneList.crosses(item) else { return }
        let folder = try ChromiumExtensionPackages.prepareUnpacked(URL(fileURLWithPath: source), id: item.id)
        try await load(folder: folder)
        guard try await self.list().contains(where: { $0.id == item.id }) else { throw Crx.Refused.unpack }
        if !item.enabled { try await applyEnabled(item.id, false) }
        unfetched.remove(item.id)
        loadFailures[item.id] = nil
        compose()
    }

    // MARK: to WebKit

    /// Files for the entries that came in on Chromium: WebKit runs them when
    /// it wakes, and the rest of Yab reads their manifests.
    @available(macOS 15.4, *)
    private func fillWebKitFolders(_ list: Extensions) async {
        for item in list.installed where ExtensionOneList.crosses(item) && !ApplePasswordExtensionRoute.matches(item.id) {
            guard !FileManager.default.fileExists(atPath: Extensions.folder(for: item.id).appendingPathComponent("manifest.json").path),
                  !unfetched.contains(item.id) else { continue }
            do {
                let folder: URL
                if let source = item.source {
                    folder = try ChromiumExtensionPackages.existingUnpacked(item.id)
                        ?? ChromiumExtensionPackages.prepareUnpacked(URL(fileURLWithPath: source), id: item.id)
                } else { folder = try await Self.packageFolder(item.id) }
                try await list.fillFolder(item.id, from: folder)
            }
            catch {
                unfetched.insert(item.id)
                NSLog("Chromium extensions: no WebKit copy of %@: %@", item.id, String(describing: error))
            }
        }
    }

    // MARK: grants and storage

    /// `ids`: these, whatever moved. Nil: every one that is on, if a file moved.
    @available(macOS 15.4, *)
    func crossEach(_ ids: Set<String>?) async {
        guard let list = oneList, let root = Extensions.storageRoot(of: list.signIn) else { return }
        // A pass with ids waits its turn; a look round the files can skip one.
        while sweeping {
            guard ids != nil else { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        sweeping = true
        defer { sweeping = false }
        let listed = Set(list.installed.filter(\.enabled).map(\.id))
        for row in rows where row.enabled && listed.contains(row.id) && (ids?.contains(row.id) ?? true) {
            let folder = root.appendingPathComponent(row.id)
            guard ids != nil || ChromiumExtensionStorage.moved(row.id, profile: profile, folder: folder) else { continue }
            var page: ChromiumExtensionPage?
            defer { page?.close() }
            do {
                let shown = try await ChromiumExtensionStorage.open(row.id, profile: profile, store: associationStore)
                page = shown
                var shadow = ChromiumExtensionStorage.shadow(row.id, profile: profile) // design: a record of what both engines held, not a view
                try await ChromiumExtensionStorage.cross(row.id, page: shown, folder: folder, profile: profile, shadow: &shadow)
                if ids != nil { try await ChromiumExtensionGrants.cross(row, page: shown, list: list, shadow: &shadow) }
                try ChromiumExtensionStorage.save(shadow, row.id, profile: profile)
                // A carry 0.46.0 owed is paid by crossing: the merge never
                // writes over what Chromium kept since, it takes it in.
                if var state = try? migration(), state.storageOwed?.contains(row.id) == true {
                    state.storageOwed?.remove(row.id)
                    try? saveMigration(state)
                }
            } catch {
                NSLog("Chromium extensions: %@ stayed behind: %@", row.id, String(describing: error))
            }
        }
    }

    /// WebKit is about to wake: what its extensions keep is brought up to
    /// date first, so they start where Chromium left off.
    @available(macOS 15.4, *)
    static func bringStorageHome(signIn: UUID?) async {
        guard ChromiumProcess.shared.connectedClient != nil else { return }
        for native in profiles.values where !native.privateMode && native.joined.map({ $0.signIn == signIn }) == true {
            await native.crossEach(nil)
        }
    }

    /// The bench's view of both engines' lists, in a test run. Each key does
    /// what the other engine's own control does, then the state is answered:
    /// "pass" runs one pass and waits for it, "sweep" crosses what moved.
    @available(macOS 15.4, *)
    func benchOneList(_ request: [String: Any], answer: @escaping ([String: Any]) -> Void) {
        guard Store.testing else { answer(["error": "one-list only works on a --test run"]); return }
        Task { @MainActor in
            do {
                if let id = request["pin"] as? String { try setPinned(id, request["on"] as? Bool ?? true) }
                if let id = request["enable"] as? String { try await setEnabled(id, request["on"] as? Bool ?? true) }
                if let id = request["remove"] as? String {
                    ChromiumConsent.approve("uninstall", id)
                    try await remove(id, userApproved: true)
                }
                if let id = request["move"] as? String, let other = request["to"] as? String { oneList?.movePinned(id, to: other) }
                // As the Settings page's "Allow user scripts" switch sets it.
                if let id = request["userScripts"] as? String { try await setUserScripts(id, request["on"] as? Bool ?? true) }
                if let id = request["access"] as? String, let word = request["value"] as? String, let value = Extensions.SiteAccess(rawValue: word) {
                    oneList?.setAccess(id, value)
                    for host in request["hosts"] as? [String] ?? [] { oneList?.allow(host, for: id) }
                }
                if request["pass"] as? Bool == true {
                    converge(force: true)
                    while converging { try await Task.sleep(for: .milliseconds(50)) }
                }
                if request["sweep"] as? Bool == true { await crossEach(request["force"] as? Bool == true ? Set(rows.map(\.id)) : nil) }
                var out: [String: Any] = ["joined": joined != nil, "converging": converging, "rests": Extensions.restsForChromium,
                                          "pins": pinnedIDs, "unfetched": unfetched.sorted(), "asking": asking.sorted(),
                                          "items": items.map { ["id": $0.id, "name": $0.name, "state": $0.state, "version": $0.version] },
                                          "rows": rows.map { row -> [String: Any] in
                                              var fields: [String: Any] = ["id": row.id, "name": row.name, "state": row.state,
                                                                           "userScripts": row.userScripts, "userScriptsChangeable": row.userScriptsChangeable]
                                              if let held = row.access {
                                                  fields["hostAccess"] = held["hostAccess"].string ?? ""
                                                  if case .array(let hosts) = held["hosts"] {
                                                      fields["hosts"] = hosts.filter { $0["granted"] == .bool(true) }.compactMap { $0["host"].string }
                                                  }
                                              }
                                              return fields
                                          }]
                if let list = oneList {
                    out["list"] = list.installed.map { item -> [String: Any] in
                        ["id": item.id, "name": item.name, "version": item.version, "enabled": item.enabled, "pinned": item.pinned ?? false,
                         "store": item.fromStore, "chromeAsks": item.chromeAsks ?? [], "permissions": item.permissions,
                         "running": list.contexts[item.id] != nil, "access": list.access(item.id).rawValue, "allowed": list.allowed(item.id),
                         "blocked": list.blocked(item.id), "choices": Extensions.choices(item.id), "userScripts": item.userScripts.map { $0 as Any } ?? NSNull(),
                         "folder": FileManager.default.fileExists(atPath: Extensions.folder(for: item.id).appendingPathComponent("manifest.json").path)]
                    }
                    if let id = request["storage"] as? String, let root = Extensions.storageRoot(of: list.signIn) {
                        let folder = root.appendingPathComponent(id)
                        out["webKitStorage"] = Dictionary((ChromiumExtensionStorage.rows(folder.appendingPathComponent("LocalStorage.db")) ?? []).map { ($0.key, $0.value) }, uniquingKeysWith: { _, last in last })
                    }
                }
                answer(out)
            } catch { answer(["error": String(describing: error)]) }
        }
    }

    /// The person granted `id` something on Chromium.
    @available(macOS 15.4, *)
    static func grantChanged(profile: String, id: String) {
        for native in profiles.values where native.profile == profile && !native.privateMode {
            Task { @MainActor in await native.crossEach([id]) }
        }
    }
}
