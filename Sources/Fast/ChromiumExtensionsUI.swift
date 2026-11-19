import AppKit
import SwiftUI
import WebKit

// The existing Settings rows and install question, backed by the CEF profile.
// Reading WebKit's manifest metadata here never loads a WebKit controller.
@MainActor
extension ChromiumExtensions {
    /// Source CEF asks through Chrome's own uninstall dialog delegate. Keep
    /// the existing native card as the prebuilt-CEF fallback, exactly once.
    func reviewRemoval(_ id: String, name: String, place: Question.Place) async throws -> Bool {
        let core = try await ChromiumProcess.shared.connection()
        let capabilities = try await core.request("extension.consent.capabilities")
        // In the one list and not in this profile, Chrome has nothing to ask.
        let held = rows.contains { $0.id == id }
        // A bool, or 1 from a helper that boxed the macro as a number. Read
        // as a no, Yab's card came first and Chrome's own asked again: twice
        // with one window, refused unseen with two (#2030).
        let native = capabilities["nativeConsent"] == .bool(true) || capabilities["nativeConsent"] == .number(1)
        if !native || !held {
            guard await Questions.shared.ask(Question(title: "Remove “\(name)”?",
                detail: "What it kept in Yab goes with it.", yes: "Remove", danger: true, place: place)) else { return false }
        }
        if !held, #available(macOS 15.4, *) {
            oneList?.remove(id)
            compose()
            return true
        }
        do { try await remove(id, userApproved: true); return true }
        catch {
            let words = String(describing: error).lowercased()
            if words.contains("cancelled") || words.contains("canceled") { return false }
            throw error
        }
    }
    static func of(_ browser: Browser) -> ChromiumExtensions {
        shared(profile: ChromiumPersistentProfiles.profile(for: browser), store: Spaces.store(for: browser.spaceID))
    }

    func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        failure = nil
        Task { @MainActor in
            defer { busy = false }
            do { try await operation() }
            catch is CancellationError { }
            catch {
                failure = error.localizedDescription
                _ = try? await list()
            }
        }
    }

    @available(macOS 15.4, *)
    func reviewInstall(_ id: String, browser: Browser, place: Question.Place? = nil) {
        guard !privateMode else {
            failure = "Extension management is unavailable in private profiles"
            return
        }
        guard !ApplePasswordExtensionRoute.intercept(id, browser: browser) else { return }
        perform {
            let folder = try await Self.storeFolder(id)
            let found = try await WKWebExtension(resourceBaseURL: folder)
            let wants = try await self.installLines(found, folder: folder)
            let name = found.displayName ?? id
            var question = Question(
                title: "Add “\(name)”?",
                detail: wants.first.map { "It will \(Extensions.lowered($0))." } ?? "It asks for no special access.",
                folded: Array(wants.dropFirst()),
                icon: found.icon(for: CGSize(width: 64, height: 64)), yes: "Add"
            )
            if let place { question.place = place }
            guard await Questions.shared.ask(question) else { return }
            try await self.put(folder, id: id)
            guard try await self.list().contains(where: { $0.id == id }) else {
                throw Crx.Refused.unpack
            }
            self.pinOnArrival(id)
            browser.announce("\(name) installed", mark: "puzzlepiece.extension", feedback: .success)
        }
    }

    /// The review page has already asked. Load only the preserved native
    /// package, then record the original folder and approval in the one list.
    @available(macOS 15.4, *)
    func add(_ candidate: Extensions.Candidate, into list: Extensions, giving: Set<String> = []) async throws {
        guard !ApplePasswordExtensionRoute.intercept(candidate.id, browser: list.browser) else { throw CancellationError() }
        guard !privateMode, let folder = candidate.chromiumFolder else { throw Crx.Refused.unpack }
        let manifest = try ChromiumExtensionPackages.manifest(in: folder)
        let root = Store.file("Chromium")
        let folders = ChromiumNativeHosts.folders()
        let id = candidate.id
        await Task.detached(priority: .userInitiated) {
            ChromiumNativeHosts.adopt(installed: [id], dataRoot: root, folders: folders)
        }.value
        if candidate.fromStore { try await put(folder, id: candidate.id) } else { try await load(folder: folder) }
        // Read without list()'s automatic adoption: source metadata must be
        // saved before a convergence pass can mistake a folder for a store ID.
        let result = try await request("extension.list")
        guard case .array(let values) = result,
              let row = try values.map(Item.init).first(where: { $0.id == candidate.id }), row.enabled else {
            throw Crx.Refused.unpack
        }
        // Keep a WebKit metadata copy for switching engines and for the
        // approval comparison; Chromium never executes its rewritten files.
        let target = Extensions.folder(for: candidate.id)
        let files = FileManager.default
        if files.fileExists(atPath: candidate.staged.path),
           !Extensions.installedElsewhere(candidate.id, than: list.signIn) || !files.fileExists(atPath: target.path) {
            if files.fileExists(atPath: target.path) { try files.removeItem(at: target) }
            try files.moveItem(at: candidate.staged, to: target)
        }
        list.takeNative(id: row.id, name: row.name, version: row.version, enabled: true,
                        fromStore: candidate.fromStore, source: candidate.source,
                        permissions: Array(ChromiumExtensionGrants.required(in: manifest)).sorted())
        let picks = candidate.extras.filter { giving.contains($0.key) }
        Extensions.setChoices(Dictionary(picks.map { ($0.key, true) }, uniquingKeysWith: { a, _ in a }), for: row.id)
        _ = try await self.list()
        await crossEach([row.id])
    }

    nonisolated static func importable(_ entries: [Installed], installed: Set<String>, pending: Set<String>) -> [Installed] {
        entries.filter { !installed.contains($0.id) || pending.contains($0.id) }
    }

    @available(macOS 15.4, *)
    func canImportWebKitList(_ browser: Browser) -> Bool {
        guard !privateMode, let previous = Extensions.unread(Extensions.signIn(of: browser.spaceID)) else { return false }
        return !Self.importable(previous, installed: Set(rows.map(\.id)), pending: pendingImport).isEmpty
    }

    @available(macOS 15.4, *)
    func importWebKitList(_ browser: Browser) {
        perform {
            guard let previous = Extensions.unread(Extensions.signIn(of: browser.spaceID)) else {
                if !FileManager.default.fileExists(atPath: Extensions.list(of: Extensions.signIn(of: browser.spaceID)).path) { return }
                throw ImportError.unreadableList
            }
            let installed = Set(try await self.list().map(\.id))
            let missing = Self.importable(previous, installed: installed, pending: self.pendingImport).filter {
                !ApplePasswordExtensionRoute.intercept($0.id, browser: browser)
            }
            guard !missing.isEmpty else { return }
            guard await Questions.shared.ask(Question(
                title: "Import extensions?", detail: "Add these extensions to this space’s sign-ins.",
                lines: missing.map(\.name), yes: "Import", place: .settings
            )) else { return }
            // Fetch original, verified packages, never WebKit's rewritten files.
            let results = try await self.importList(missing) { item in
                let folder = try await Self.storeFolder(item.id)
                let data = try Data(contentsOf: folder.appendingPathComponent("manifest.json"))
                guard let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Crx.Refused.unpack }
                let native = ChromiumExtensionGrants.required(in: manifest)
                let additional = native.subtracting(ChromiumExtensionGrants.normalized(item.permissions))
                if !additional.isEmpty {
                    guard await Questions.shared.ask(Question(
                        title: "\(item.name) wants more", detail: "This version asks for additional access.",
                        lines: try await self.installLines(WKWebExtension(resourceBaseURL: folder), folder: folder), yes: "Add", place: .settings
                    )) else { throw ImportError.declined }
                }
                self.oneList?.allowOnChromium(item.id, Array(native))
                let id = item.id, root = Store.file("Chromium")
                let folders = ChromiumNativeHosts.folders()
                await Task.detached(priority: .userInitiated) {
                    ChromiumNativeHosts.adopt(installed: [id], dataRoot: root, folders: folders)
                }.value
                try await self.put(folder, id: item.id)
                guard try await self.list().contains(where: { $0.id == item.id }) else {
                    throw Crx.Refused.unpack
                }
            }
            // One left asking is in Chromium now: its WebKit copy rests too.
            let arrived = Set(results.filter { $0.state == .imported || $0.state == .existing }.map(\.id))
            for id in arrived {
                self.unfetched.remove(id)
                self.loadFailures[id] = nil
            }
            self.compose()
            if var state = try? self.migration(), let asking = state.asking, !asking.isDisjoint(with: arrived) {
                state.asking = asking.subtracting(arrived)
                try? self.saveMigration(state)
            }
            let unfinished = results.filter { $0.state == .failed || $0.state == .blocked }
            self.failure = unfinished.isEmpty ? nil : unfinished.map {
                "\($0.name): \($0.detail ?? $0.state.rawValue)"
            }.joined(separator: "\n")
        }
    }

    /// Chrome's own warnings when its management page offers them, else
    /// the words WebKit Yab asks with plus Chrome-only grants.
    @available(macOS 15.4, *)
    func installLines(_ found: WKWebExtension, folder: URL) async throws -> [String] {
        if let native = try? await permissionWarnings(folder: folder) { return native }
        let data = try Data(contentsOf: folder.appendingPathComponent("manifest.json"))
        guard data.count <= 1_000_000, let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Crx.Refused.unpack
        }
        return ChromiumInstallWords.lines(manifest: manifest, yab: Extensions.describe(found, in: folder))
    }

    private static func storeFolder(_ id: String) async throws -> URL {
        let data = try await ChromiumExtensionPackages.fetch(id)
        let root = Store.file("ChromiumPackages")
        return try await Task.detached(priority: .userInitiated) {
            try ChromiumExtensionPackages.prepare(data, id: id, root: root)
        }.value
    }
}

/// The existing corner offer, observed without constructing a WK controller.
struct ChromiumStoreOffer: View {
    let browser: Browser
    var tab: Tab
    var native: ChromiumExtensions

    private var wanted: String? {
        guard !tab.shy, ChromiumStoreBridge.accepts(tab.address),
              let id = Crx.id(in: tab.address?.absoluteString ?? ""), tab.storePlaced != id,
              !native.items.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .task(id: wanted) {
                guard let id = wanted, !StoreOffer.offered.contains(id) else { return }
                let space = browser.spaceID
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled, wanted == id, browser.spaceID == space,
                      StoreOffer.offered.insert(id).inserted else { return }
                browser.toaster.pop("Install in Yab", mark: "puzzlepiece.extension", undo: {
                    // A toast can outlive its page or space. Keep the offer's
                    // exact package and profile rather than a later address.
                    guard !tab.gone, !tab.shy, tab.delegate as? Browser === browser,
                          tab.engineKind == .chromium, browser.spaceID == space,
                          ChromiumStoreBridge.accepts(tab.address),
                          Crx.id(in: tab.address?.absoluteString ?? "") == id,
                          let page = tab.builtPage as? ChromiumPage, page.extensions === native else { return }
                    if #available(macOS 15.4, *) { native.reviewInstall(id, browser: browser) }
                }, act: "Add")
            }
    }
}

struct ChromiumExtensionsSettings: View {
    var browser: Browser
    var model: SettingsModel
    var extensions: ChromiumExtensions

    var body: some View {
        Group {
            if let id = model.opened, let item = extensions.items.first(where: { $0.id == id }) {
                Section {
                    VStack(spacing: 6) {
                        mark(item, side: 64).padding(.bottom, 4)
                        Text(item.name).font(.system(size: 20, weight: .semibold)).multilineTextAlignment(.center)
                        Text(item.about).foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(3)
                        Text("Version \(item.version)").font(.callout).foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    if let issue = item.issue { SettingsNote(issue) }
                    SettingsSwitch("On", isOn: enabled(item))
                    if item.absent, let asks = chromeAsks(item), !asks.isEmpty {
                        SettingsNote("This version needs additional permissions. Enabling it asks for approval.")
                    }
                    SettingsSwitch("Pinned in the extensions list", isOn: Binding(
                        get: { extensions.pinnedIDs.contains(item.id) },
                        set: { on in
                            do { try extensions.setPinned(item.id, on) } catch { extensions.failure = error.localizedDescription }
                        }))
                    // Chrome's "Allow User Scripts", for one that asks for
                    // userScripts: Tampermonkey's and Violentmonkey's scripts
                    // run only with it on.
                    if item.userScriptsChangeable {
                        SettingsSwitch("Allow user scripts", isOn: Binding(
                            get: { item.userScripts },
                            set: { on in extensions.perform { try await extensions.setUserScripts(item.id, on) } }))
                    }
                    if let url = item.optionsURL {
                        SettingsRow("Options") {
                            Button("Open") { browser.tuning = false; browser.open(url, foreground: true) }.settingsButton()
                        }
                    }
                    if #available(macOS 15.4, *), let list = extensions.oneList,
                       list.installed.first(where: { $0.id == id })?.source != nil {
                        SettingsRow("Reload", detail: "Load again from the folder.") {
                            Button("Reload") { list.reload(id) }.settingsButton()
                        }
                    }
                    SettingsRow("Remove", detail: "Remove the extension and its saved data from Yab.") {
                        Button("Remove…") {
                            extensions.perform {
                                guard try await extensions.reviewRemoval(id, name: item.name, place: .settings) else { return }
                                model.travel(-1)
                            }
                        }.settingsButton()
                    }
                }
                if #available(macOS 15.4, *), let list = extensions.oneList, let entry = list.installed.first(where: { $0.id == id }),
                   let reach = ChromiumExtensionGrants.reach(of: item) {
                    ExtensionWebsites(id: id, item: entry, extensions: list, everywhere: reach.everywhere, hosts: reach.hosts,
                                      clickable: reach.clickable, blocks: false)
                }
            } else {
                Section {
                    ForEach(extensions.items) { item in
                        HStack(spacing: 10) {
                            HStack(spacing: 8) {
                                mark(item, side: 20)
                                VStack(alignment: .leading, spacing: 3) { // design: shipped in 0.46.11, name over its issue
                                    Text(item.name).lineLimit(1)
                                    if let issue = item.issue { Text(issue).font(.callout).foregroundStyle(.secondary) }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture { model.open(extension: item.id) }
                            Toggle("Enabled", isOn: enabled(item)).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                            Button { model.open(extension: item.id) } label: {
                                Symbol("chevron.right", size: 10, weight: .semibold).foregroundStyle(.tertiary)
                            }.buttonStyle(.plain).accessibilityLabel("Details for \(item.name)")
                        }
                        .opacity(item.on ? 1 : 0.55)
                    }

                }
                // The row Settings search finds as "Allow in private tabs".
                ExtensionsPage.PrivateTabs(prefs: browser.prefs)
            }
            if let error = extensions.failure { Section { SettingsNote(error) } }
        }
        .disabled(extensions.busy)
        .task(id: extensions.profile) {
            if #available(macOS 15.4, *) { extensions.joinList(signIn: Extensions.signIn(of: browser.spaceID)) }
            do { _ = try await extensions.list() }
            catch { extensions.failure = error.localizedDescription }
        }
    }

    private func enabled(_ item: ChromiumExtensions.Item) -> Binding<Bool> {
        Binding(get: { item.on }, set: { on in extensions.perform { try await extensions.setEnabled(item.id, on) } })
    }

    private func chromeAsks(_ item: ChromiumExtensions.Item) -> [String]? {
        guard #available(macOS 15.4, *) else { return nil }
        return extensions.oneList?.installed.first { $0.id == item.id }?.chromeAsks
    }

    @ViewBuilder private func mark(_ item: ChromiumExtensions.Item, side: CGFloat) -> some View {
        if let data = item.iconData, let image = NSImage(data: data) {
            Image(nsImage: image).resizable().interpolation(.high).frame(width: side, height: side)
        } else {
            Symbol("puzzlepiece.extension", size: side * 0.65).foregroundStyle(.secondary).frame(width: side, height: side)
        }
    }
}
