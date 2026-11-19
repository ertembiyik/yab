import SwiftUI
import WebKit
import UniformTypeIdentifiers

// Adding an extension is an arrival, not a form, the way
// connecting an account or naming websites should feel. One column in the middle of the
// pane; one mark that stays through every step, wearing where the extension
// comes from at its corner, a ring while yab works and a tick when it has
// landed; and one button that carries the whole flow and only re-words
// itself. The steps are routes, so the window's back button walks them, and
// once something lands they drop out of it and the window goes to what was
// added.
//
// It is a rare moment, so it may move: the words morph, a ticked icon flies
// into the button. What is ticked, picked or chosen changes at once.

/// Settings › Extensions, the pane: the list and each extension's page are
/// rows of the form; adding, and the page itself while nothing is
/// installed, takes the whole pane.
struct ExtensionsPane<Rows: View>: View {
    var browser: Browser
    var model: SettingsModel
    @ViewBuilder let rows: () -> Rows

    var body: some View {
        if #available(macOS 15.4, *) {
            Chooser(browser: browser, model: model, extensions: PageEngineFactory.chromiumEnabled ? Extensions.of(browser) : ExtensionsPage.listed(browser, model), adding: .shared, rows: rows)
        } else {
            rows()
        }
    }

    @available(macOS 15.4, *)
    private struct Chooser: View {
        var browser: Browser
        var model: SettingsModel
        var extensions: Extensions
        @Bindable var adding: ExtensionAdding
        let rows: () -> Rows

        var body: some View {
            Group {
                if let step = ExtensionAdd.step(model.opened) {
                    ExtensionAdd(step: step, browser: browser, model: model, extensions: extensions, adding: adding)
                } else if model.opened == nil, (!PageEngineFactory.chromiumEnabled && extensions.installed.isEmpty && !SignIns.split(browser)) || adding.busy {
                    // Nothing yet: the page is the way in. And while the first
                    // ones are going in, it stays that way until they land.
                    // With spaces signed in apart, the list stays, with which
                    // sign-in's it is over it.
                    ExtensionAdd(step: .arrival, browser: browser, model: model, extensions: extensions, adding: adding)
                } else {
                    rows()
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard let file = urls.first, file.isFileURL,
                      file.pathExtension.lowercased() == "crx" else { return false }
                adding.choose(folder: file, model: model)
                return true
            }
            // Added to the sign-in the list is of (ExtensionSignIns).
            .task(id: ObjectIdentifier(extensions)) {
                adding.target = extensions
                adding.chromium = PageEngineFactory.chromiumEnabled ? ChromiumExtensions.of(browser) : nil
                adding.chromium?.joinList(signIn: extensions.signIn)
            }
        }
    }
}

/// Where adding is: which way in, what the other browsers have, what is
/// ticked, the extension waiting on a yes, and what the button is doing.
@available(macOS 15.4, *)
@MainActor
@Observable final class ExtensionAdding {
    static let shared = ExtensionAdding()

    enum Way: Hashable { case browser(String), store, folder }
    enum Phase: Equatable { case idle, working(String), landed }

    /// The way picked in the menu; until then, the best one there is.
    var chosen: Way?
    private(set) var sources: [Chromium.Source] = []
    /// What each browser has that isn't here yet, by the browser's name.
    private(set) var fresh: [String: [Chromium.Extension]] = [:]
    private(set) var icons: [String: NSImage] = [:]
    private(set) var counted = false
    var picked: Set<String> = []
    /// The ticked ones in the order they were ticked: the button's stack.
    var order: [String] = []
    private(set) var candidate: Extensions.Candidate?
    /// What it may ask for later that was ticked, by key: given now. None
    /// is to begin with; the rest it is asked about when it asks.
    var given: Set<String> = []
    var link = ""
    private(set) var phase = Phase.idle
    var error: String?
    private(set) var landedNames: [String] = []
    private(set) var landedIcon: NSImage?

    var busy: Bool { phase != .idle }
    var way: Way { chosen ?? suggested }

    /// A browser with something to bring, the one links open in first;
    /// else the store.
    var suggested: Way {
        if let source = sources.first(where: { !(fresh[$0.name] ?? []).isEmpty }) { return .browser(source.name) }
        return .store
    }

    var linkIsGood: Bool { Crx.id(in: link) != nil }

    /// The sign-in what is added goes to: the one Settings lists.
    @ObservationIgnored var target: Extensions = .shared
    @ObservationIgnored var chromium: ChromiumExtensions?
    private var extensions: Extensions { target }

    // MARK: looking

    func refresh() async {
        let found = Chromium.installed()
        sources = found
        let all = await Task.detached(priority: .userInitiated) {
            Dictionary(uniqueKeysWithValues: found.map { ($0.name, Chromium.extensions(in: $0)) })
        }.value
        let here = Set(extensions.installed.map(\.id))
        let folders = Set(extensions.installed.compactMap(\.source))
        fresh = all.mapValues { list in list.filter { !here.contains($0.id) && !folders.contains($0.folder.path) } }
        for item in fresh.values.joined() where icons[item.id] == nil {
            if let file = item.iconFile, let image = NSImage(contentsOf: file) { icons[item.id] = image }
        }
        counted = true
    }

    /// A store link on the clipboard is what someone copied to add, the
    /// way a setup step looks for a pasted ID there.
    func offerClipboard() {
        guard !busy, let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              text.count < 400, text != link,
              text.contains("chromewebstore.google.com") || text.contains("chrome.google.com/webstore")
                || text.range(of: "^[a-p]{32}$", options: .regularExpression) != nil,
              let id = Crx.id(in: text), !extensions.installed.contains(where: { $0.id == id })
        else { return }
        link = text
        chosen = .store
        error = nil
    }

    // MARK: the button

    /// The arrival's press, for the way chosen.
    func go(_ model: SettingsModel, _ browser: Browser) {
        error = nil
        switch way {
        case .browser(let name):
            let list = fresh[name] ?? []
            order = list.filter(\.enabled).map(\.id)
            picked = Set(order)
            model.open(extension: ExtensionAdd.Step.pick.rawValue)
        case .store:
            guard linkIsGood else {
                Links.openFromSettings(Browser.webStore, in: browser)
                return
            }
            let text = link
            look(model, "Looking at it…") { try await self.extensions.prepare(link: text, chromium: self.chromium) }
        case .folder:
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = true
            panel.allowedContentTypes = [.folder, UTType(filenameExtension: "crx") ?? .data]
            panel.prompt = "Choose"
            panel.message = "Choose an extension's folder (with its manifest.json) or a .crx file."
            guard panel.runModal() == .OK, let folder = panel.url else { return }
            choose(folder: folder, model: model)
        }
    }

    func choose(folder: URL, model: SettingsModel) {
        guard !busy else { return }
        dropCandidate()
        error = nil
        chosen = .folder
        model.open(extension: ExtensionAdd.Step.arrival.rawValue)
        look(model, "Reading it…") {
            if folder.pathExtension.lowercased() == "crx",
               (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true {
                return try await self.extensions.prepare(package: folder, chromium: self.chromium)
            }
            return try await self.extensions.prepare(folder: folder, chromium: self.chromium)
        }
    }

    private func look(_ model: SettingsModel, _ words: String, _ fetch: @escaping () async throws -> Extensions.Candidate) {
        phase = .working(words)
        Task {
            do {
                let found = try await fetch()
                withAnimation(Motion.settle) { phase = .idle }
                given = []
                candidate = found
                model.open(extension: ExtensionAdd.Step.review.rawValue)
            } catch is CancellationError {
                withAnimation(Motion.settle) { phase = .idle }
            } catch {
                withAnimation(Motion.settle) {
                    phase = .idle
                    self.error = error.localizedDescription
                }
            }
        }
    }

    func tick(_ id: String, _ on: Bool, flight: Animation?) {
        // The tick is a state and lands at once; only the icon's trip into
        // the button takes time.
        if on { picked.insert(id) } else { picked.remove(id) }
        withAnimation(flight) {
            if on { order.append(id) } else { order.removeAll { $0 == id } }
        }
    }

    /// The ticked ones in, one after another.
    func bring(from name: String, _ model: SettingsModel) {
        let list = (fresh[name] ?? []).filter {
            picked.contains($0.id) && !ApplePasswordExtensionRoute.intercept($0.id, browser: extensions.browser)
        }
        guard !list.isEmpty, !busy else { return }
        error = nil
        withAnimation(Motion.settle) { phase = .working(list.count == 1 ? "Adding…" : "Adding 1 of \(list.count)…") }
        Task {
            let added: [String]
            if let chromium {
                added = await bringNative(list, from: name, into: chromium)
            } else {
                added = await extensions.bring(list, from: name) { index in
                    if index > 0 { self.phase = .working("Adding \(index + 1) of \(list.count)…") }
                }
            }
            // uBlock Origin's sites came, the extension itself never does.
            await land(added, model, keptOnly: list.contains(where: \.keptOnly))
        }
    }

    /// Import uses the same approved package path as a store/folder review,
    /// never the other browser's rewritten files or a WebKit runtime.
    private func bringNative(_ items: [Chromium.Extension], from name: String, into native: ChromiumExtensions) async -> [String] {
        var added: [String] = []
        for (index, item) in items.enumerated() {
            phase = .working(items.count == 1 ? "Adding…" : "Adding \(index + 1) of \(items.count)…")
            extensions.bringKept(item, from: name)
            if item.keptOnly { continue }
            do {
                let candidate: Extensions.Candidate
                if item.fromStore {
                    candidate = try await extensions.prepare(link: item.id, chromium: native)
                } else {
                    candidate = try await extensions.prepare(folder: item.folder, chromium: native)
                }
                defer { extensions.discard(candidate) }
                try await native.add(candidate, into: extensions)
                extensions.bringKeys(item, as: candidate.id)
                added.append(candidate.id)
            } catch {
                self.error = error.localizedDescription
            }
        }
        return added
    }

    /// The yes on the page.
    func add(_ model: SettingsModel) {
        guard let candidate, !busy else { return }
        error = nil
        withAnimation(Motion.settle) { phase = .working("Adding…") }
        Task {
            if let chromium, candidate.chromiumFolder != nil {
                do { try await chromium.add(candidate, into: extensions, giving: given) }
                catch {
                    phase = .idle
                    self.error = error.localizedDescription
                    return
                }
                extensions.discard(candidate)
            } else {
                _ = await extensions.add(candidate, giving: given)
            }
            self.candidate = nil
            await land(extensions.installed.contains { $0.id == candidate.id } ? [candidate.id] : [], model, icon: candidate.icon)
        }
    }

    /// The tick, held long enough to be seen, then what was added.
    func land(_ ids: [String], _ model: SettingsModel, keptOnly: Bool = false, icon: NSImage? = nil) async {
        guard !ids.isEmpty || keptOnly else {
            withAnimation(Motion.settle) {
                phase = .idle
                error = "It couldn't be added. Try again, or another way in."
            }
            return
        }
        if chromium != nil {
            model.leaveAdding(to: ids.count == 1 ? ids[0] : nil)
            extensions.arrivedQuietly(ids)
            reset()
            return
        }
        landedNames = ids.compactMap { id in extensions.installed.first { $0.id == id }?.name } + (keptOnly ? ["uBlock Origin's sites"] : [])
        landedIcon = ids.count == 1 ? icon ?? ExtensionIconShape.rounded(extensions.contexts[ids[0]]?.webExtension.icon(for: CGSize(width: 128, height: 128))) : nil
        withAnimation(Motion.settle) { phase = .landed }
        try? await Task.sleep(for: .seconds(0.9))
        model.leaveAdding(to: ids.count == 1 ? ids[0] : nil)
        // Nothing flies out of this window into the browser's row: the
        // puzzle hops once there and keeps a dot until its list is opened.
        extensions.arrivedQuietly(ids)
        reset()
    }

    /// Back from the extension waiting on a yes, or out of adding.
    func dropCandidate() {
        guard let candidate, !busy else { return }
        extensions.discard(candidate)
        self.candidate = nil
    }

    private func reset() {
        phase = .idle
        given = []
        picked = []
        order = []
        error = nil
        link = ""
        chosen = nil
        landedNames = []
        landedIcon = nil
        counted = false
    }
}

/// One step of adding, in the middle of the pane.
@available(macOS 15.4, *)
struct ExtensionAdd: View {
    enum Step: String { case arrival = "+add", pick = "+add/pick", review = "+add/review" }

    static func step(_ opened: String?) -> Step? { opened.flatMap(Step.init) }
    static var benchFlight: Animation { Flight.curve }

    let step: Step
    var browser: Browser
    var model: SettingsModel
    var extensions: Extensions
    @Bindable var adding: ExtensionAdding
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rowFrames: [String: CGRect] = [:]
    @State private var stackFrame: CGRect = .zero
    /// The pane's height, so a long list scrolls inside itself and the
    /// mark, the words and the button always fit around it.
    @State private var pane: CGFloat = 500

    private var working: Bool { if case .working = adding.phase { return true } else { return false } }
    private var landed: Bool { adding.phase == .landed }
    /// The browser whose extensions are being ticked.
    private var from: String? { if case .browser(let name) = adding.way { return name } else { return nil } }

    var body: some View {
        GeometryReader { proxy in
            ThreadScrollView {
                VStack(spacing: 0) {
                    mark
                    Text(title)
                        .font(.system(size: 18, weight: .medium))
                        .padding(.top, 16)
                        .id(title)
                        .transition(.opacity)
                    if !explanation.isEmpty {
                        Text(explanation)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 340)
                            .padding(.top, 6)
                    }
                    if !working, !landed {
                        slot.padding(.top, 16).transition(.opacity)
                    }
                    button.padding(.top, 18)
                    if step == .review, !working, !landed {
                        Button("Cancel") {
                            adding.dropCandidate()
                            model.travel(-1)
                        }
                        .buttonStyle(.yab(.quiet, .regular))
                        .padding(.top, 6)
                    }
                    if let footnote {
                        Text(footnote)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 360)
                            .padding(.top, 14)
                            .transition(.opacity)
                    }
                    if let error = adding.error, !working {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(ButtonCSS.danger)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 340)
                            .padding(.top, 12)
                            .transition(.opacity)
                    }
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
            .onAppear { pane = proxy.size.height }
            .onChange(of: proxy.size.height) { _, height in pane = height }
        }
        .coordinateSpace(name: Flight.space)
        .onPreferenceChange(Flight.Rows.self) { rowFrames = $0 }
        .onPreferenceChange(Flight.Stack.self) { stackFrame = $0 }
        .font(.system(size: 13))
        .task(id: step) {
            if step == .arrival {
                adding.dropCandidate()
                adding.offerClipboard()
                if !adding.counted { await adding.refresh() }
            }
            // A step come back to by Forward, with what it showed gone.
            if step == .review, adding.candidate == nil, !adding.busy { model.travel(-1) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if step == .arrival { adding.offerClipboard() }
        }
    }

    // MARK: the mark

    private var mark: some View {
        AddMark(
            icon: landed ? adding.landedIcon : step == .review ? adding.candidate?.icon : nil,
            badge: step == .review || landed ? nil : badge,
            ticked: landed,
            working: working
        )
    }

    private var badge: AddMark.Badge {
        switch adding.way {
        case .browser(let name): return .image(name, adding.sources.first { $0.name == name }?.icon)
        case .store: return .symbol("bag")
        case .folder: return .symbol("folder")
        }
    }

    // MARK: the words

    private var title: String {
        if landed {
            let names = adding.landedNames
            return names.count == 1 ? "\(names[0]) is added" : "\(names.count) extensions are added"
        }
        switch step {
        case .arrival:
            if working { return "Looking at it" }
            return extensions.installed.isEmpty ? "Add your first extension" : "Add extensions"
        case .pick: return working ? "Adding them" : "Which ones?"
        case .review: return adding.candidate?.name ?? "An extension"
        }
    }

    private var explanation: String {
        if landed {
            let place = Keymap.shared.keys(.extensions).map { "in \($0.text)" } ?? "under the puzzle piece"
            return adding.landedNames.count == 1 ? "Its button is \(place)." : "Their buttons are \(place)."
        }
        switch step {
        case .arrival:
            if working { return "Checking what it asks to do before anything is added." }
            switch adding.way {
            case .browser(let name):
                let count = adding.fresh[name]?.count ?? 0
                return count == 1 ? "\(name) has one that isn't in Yab yet." : "\(name) has \(count) that aren't in Yab yet."
            case .store:
                return adding.linkIsGood ? "There's a link to one on the clipboard." : "In the store, press Add to Yab on an extension's page. Or paste its link here."
            case .folder:
                return "An unpacked extension: your own, or one exported from another browser."
            }
        case .pick:
            if working { return "Ones from the store come from the store again, so the copy you get is the one it signed." }
            return "From \(from ?? "the other browser"). The ones switched on there are ticked."
        case .review:
            guard let candidate = adding.candidate else { return "" }
            let origin = candidate.fromStore ? "Chrome Web Store" : "From “\(candidate.packageName ?? candidate.source?.lastPathComponent ?? "a folder")”"
            let meta = [candidate.version.isEmpty ? nil : candidate.version, origin].compactMap { $0 }.joined(separator: " · ")
            return candidate.about.isEmpty ? meta : "\(candidate.about)\n\(meta)"
        }
    }

    private var action: String {
        if landed {
            let names = adding.landedNames
            return names.count == 1 ? "\(names[0]) added" : "\(names.count) extensions added"
        }
        if case .working(let words) = adding.phase { return words }
        switch step {
        case .arrival:
            switch adding.way {
            case .browser(let name): return "Choose from \(name)"
            case .store: return adding.linkIsGood ? "View Extension" : "Open Chrome Web Store"
            case .folder: return "Choose a Folder or .crx…"
            }
        case .pick:
            let list = from.flatMap { adding.fresh[$0] } ?? []
            let sites = list.contains { $0.keptOnly && adding.picked.contains($0.id) }
            let count = adding.picked.count - (sites ? 1 : 0)
            let words = count == 0 ? (sites ? "" : "Choose Extensions") : count == 1 ? "Bring 1 Extension" : "Bring \(count) Extensions"
            guard sites else { return words }
            return count == 0 ? "Bring uBlock's Sites" : words + " and uBlock's Sites"
        case .review:
            return "Add \(adding.candidate?.name ?? "it")"
        }
    }

    private var footnote: String? {
        guard !working, !landed else { return nil }
        switch step {
        case .arrival:
            switch adding.way {
            case .browser(let name): return "The extensions come over; what they kept, sign-ins, settings, stays in \(name), so you sign in to them again."
            case .store: return "Each one shows here what it may do before it is added."
            case .folder: return "Choose a folder or a .crx file. Reload brings in changes to a folder."
            }
        case .pick: return nil
        case .review: return "On its page you can keep it off some sites, or make it wait until you press it."
        }
    }

    // MARK: the slot

    @ViewBuilder
    private var slot: some View {
        switch step {
        case .arrival:
            VStack(spacing: 8) {
                picker
                if adding.way == .store {
                    TextField("Link", text: $adding.link, prompt: Text("Paste a link, or its id"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .multilineTextAlignment(.leading)
                        .onSubmit { if adding.linkIsGood { adding.go(model, browser) } }
                        .onChange(of: adding.link) { _, _ in adding.error = nil }
                }
            }
            .frame(maxWidth: 300)
        case .pick:
            checklist.frame(maxWidth: 340)
        case .review:
            VStack(spacing: 8) {
                wants
                if let extras = adding.candidate?.extras, !extras.isEmpty { later(extras) }
            }
            .frame(maxWidth: 320)
        }
    }

    /// Where from: every browser here with what it has to bring, the
    /// store, a folder. The best is picked already.
    private var picker: some View {
        Menu {
            ForEach(adding.sources) { source in
                let count = adding.fresh[source.name]?.count ?? 0
                Button {
                    adding.chosen = .browser(source.name)
                    adding.error = nil
                } label: {
                    Label {
                        Text(count == 0 ? "\(source.name): nothing new" : "\(source.name): \(count)")
                    } icon: {
                        if let icon = source.icon { Image(nsImage: Self.menuIcon(icon)) }
                    }
                }
                .disabled(count == 0)
            }
            if !adding.sources.isEmpty { Divider() }
            Button { adding.chosen = .store; adding.error = nil } label: {
                Label { Text("Chrome Web Store") } icon: { Symbol("bag", size: 14) }
            }
            Button { adding.chosen = .folder; adding.error = nil } label: {
                Label { Text("A Folder on This Mac") } icon: { Symbol("folder", size: 14) }
            }
        } label: {
            HStack(spacing: 8) {
                switch adding.way {
                case .browser(let name):
                    if let icon = adding.sources.first(where: { $0.name == name })?.icon {
                        Image(nsImage: icon).resizable().interpolation(.high).frame(width: 18, height: 18)
                    }
                    Text("From \(name)").foregroundStyle(.primary)
                    Text("\(adding.fresh[name]?.count ?? 0) extensions").foregroundStyle(.tertiary)
                case .store:
                    Symbol("bag", size: 12).frame(width: 18)
                    Text("Chrome Web Store").foregroundStyle(.primary)
                case .folder:
                    Symbol("folder", size: 12).frame(width: 18)
                    Text("A folder on this Mac").foregroundStyle(.primary)
                }
                Spacer(minLength: 4)
                Symbol("chevron.up.chevron.down", size: 10, weight: .semibold)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .frame(height: ButtonSize.large.height)
            .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(Color.primary.opacity(0.05)))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        // Pressed as every button is: down and back on springs.
        .buttonStyle(PressStyle(scale: ButtonSize.large.pressed))
        .menuIndicator(.hidden)
        .accessibilityLabel("From")
        .benchSpot("extension-add-source")
    }

    private var checklist: some View {
        let list = from.flatMap { adding.fresh[$0] } ?? []
        // Everything else in the column takes about 280 points.
        let room = max(pane - 280, 120)
        return ThreadScrollView {
          VStack(spacing: 0) {
            ForEach(Array(list.enumerated()), id: \.element.id) { index, item in
                if index > 0 { Divider().padding(.leading, 10) }
                Toggle(isOn: Binding(
                    get: { adding.picked.contains(item.id) },
                    set: { adding.tick(item.id, $0, flight: reduceMotion ? .easeOut(duration: 0.12) : Flight.curve) }
                )) {
                    HStack(spacing: 10) {
                        chip(item.id, side: 20)
                            .background {
                                GeometryReader { geometry in
                                    Color.clear.preference(key: Flight.Rows.self, value: [item.id: geometry.frame(in: .named(Flight.space))])
                                }
                            }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.name).lineLimit(1)
                            // A blocker's sites and hiding rules come with it.
                            if let line = Self.keptLine(item, from: from ?? "the other browser") {
                                Text(line).font(.system(size: 11.5)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 8)
                        if item.keptOnly {
                            Text("can't run in Yab").font(.callout).foregroundStyle(.tertiary)
                        } else if !item.enabled {
                            Text("off in \(from ?? "")").font(.callout).foregroundStyle(.tertiary)
                        } else if !item.fromStore {
                            Text("unpacked").font(.callout).foregroundStyle(.tertiary)
                        }
                    }
                    .multilineTextAlignment(.leading)
                }
                .toggleStyle(.checkbox)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
          }
          .padding(.vertical, 4)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: min(room, CGFloat(list.count) * 33 + CGFloat(list.filter { Self.keptLine($0, from: "") != nil }.count) * 30 + 8))
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }

    /// The line under a blocker's row in the pick step.
    static func keptLine(_ item: Chromium.Extension, from browserName: String) -> String? {
        guard let kept = item.kept, !kept.isEmpty else { return nil }
        guard item.keptOnly else { return kept.line }
        let rules = kept.blocking == 0 ? "" : kept.blocking == 1 ? " Its 1 blocking rule stays in \(browserName)." : " Its \(kept.blocking) blocking rules stay in \(browserName)."
        return "Its \(BlockerWords.brought(kept.sites.count, kept.hiding.count)) go to Yab's built-in blocker, which uses the same lists.\(rules)"
    }

    /// What it may do, in words, before the yes.
    private var wants: some View {
        let candidate = adding.candidate
        let lines = (candidate?.wants ?? []) + (candidate.map { $0.shortcuts == 0 ? [] : [$0.shortcuts == 1 ? "Has a shortcut, which you can change" : "Has \($0.shortcuts) shortcuts, which you can change"] } ?? [])
        return VStack(alignment: .leading, spacing: 7) {
            if lines.isEmpty {
                Text("It asks for nothing beyond its own pages.").foregroundStyle(.secondary)
            }
            ForEach(lines, id: \.self) { line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle().fill(Color.primary.opacity(0.35)).frame(width: 4, height: 4).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
                    Text(line).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    /// What it would also like, a box each, unticked: the manifest's
    /// optional permissions and sites. Ticked, it is given now; left, the
    /// extension is asked about it when it asks, as in Chromium. A tick is a
    /// state and lands at once.
    private func later(_ extras: [Extensions.Extra]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("It would also like to")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            ForEach(extras, id: \.key) { extra in
                Toggle(isOn: Binding(
                    get: { adding.given.contains(extra.key) },
                    set: { on in if on { adding.given.insert(extra.key) } else { adding.given.remove(extra.key) } }
                )) {
                    Text(extra.words).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(.checkbox)
            }
        }
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Radius.surface, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    // MARK: the button

    private var button: some View {
        Button(action: press) {
            HStack(spacing: 7) {
                if step == .pick, !working, !landed {
                    stack
                }
                if working {
                    Turning(size: 13).transition(.scale(scale: 0.6).combined(with: .opacity))
                }
                MorphText(action)
            }
            .animation(.easeOut(duration: 0.2), value: working)
        }
        .buttonStyle(.yab(.primary, .large))
        .disabled(step == .pick && adding.picked.isEmpty && !working && !landed)
        // Not disabled while it works: a button that fades mid-press reads
        // as a press that didn't take.
        .allowsHitTesting(!working && !landed)
    }

    /// The ticked ones' icons at the front of the button, the first three,
    /// each arriving from its row.
    private var stack: some View {
        let shown = Array(adding.order.prefix(Flight.shown))
        return HStack(spacing: -Flight.overlap) {
            ForEach(Array(shown.enumerated()), id: \.element) { index, id in
                chip(id, side: Flight.chip)
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Palette.ink, lineWidth: 1.5))
                    .transition(flight(for: id, at: index))
            }
        }
        .background {
            GeometryReader { geometry in
                Color.clear.preference(key: Flight.Stack.self, value: geometry.frame(in: .named(Flight.space)))
            }
        }
    }

    private func flight(for id: String, at index: Int) -> AnyTransition {
        guard !reduceMotion, let row = rowFrames[id], stackFrame != .zero else { return .opacity }
        let x = stackFrame.minX + CGFloat(index) * (Flight.chip - Flight.overlap)
        let offset = CGSize(width: row.minX - x, height: row.minY - (stackFrame.midY - Flight.chip / 2))
        return .asymmetric(
            insertion: .modifier(active: Flight.Travel(offset: offset, scale: row.width / Flight.chip), identity: Flight.Travel(offset: .zero, scale: 1)),
            removal: .scale(scale: 0.4).combined(with: .opacity)
        )
    }

    private func chip(_ id: String, side: CGFloat) -> some View {
        Group {
            if let icon = adding.icons[id] {
                Image(nsImage: icon).resizable().interpolation(.high)
            } else {
                Symbol("puzzlepiece.extension", size: side * 0.6)
                    .foregroundStyle(.secondary)
                    .frame(width: side, height: side)
                    .background(Color.primary.opacity(0.06))
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.25, style: .continuous))
    }

    private func press() {
        switch step {
        case .arrival: adding.go(model, browser)
        case .pick: if let from { adding.bring(from: from, model) }
        case .review: adding.add(model)
        }
    }

    private static func menuIcon(_ icon: NSImage) -> NSImage {
        let small = icon.copy() as? NSImage ?? icon
        small.size = NSSize(width: 16, height: 16)
        return small
    }
}

/// The plumbing and numbers of an icon flying from its row into the button.
private enum Flight {
    struct Rows: PreferenceKey {
        static let defaultValue: [String: CGRect] = [:]
        static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
            value.merge(nextValue()) { $1 }
        }
    }

    struct Stack: PreferenceKey {
        static let defaultValue: CGRect = .zero
        static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
            let next = nextValue()
            if next != .zero { value = next }
        }
    }

    struct Travel: ViewModifier {
        let offset: CGSize
        let scale: CGFloat

        func body(content: Content) -> some View {
            content.scaleEffect(scale, anchor: .topLeading).offset(offset)
        }
    }

    static let space = "adding"
    static let chip: CGFloat = 18
    static let overlap: CGFloat = 5
    static let shown = 3
    /// The arrival curve: the trip is most of the pane's height.
    static let curve: Animation = .timingCurve(0.32, 0.72, 0, 1, duration: 0.42)
}

/// The mark that stays through adding: the puzzle piece on a quiet well, or
/// the extension's own icon once it is known, where it comes from at the
/// corner, a ring while yab works and a tick once it is in.
@available(macOS 15.4, *)
private struct AddMark: View {
    enum Badge: Equatable {
        case image(String, NSImage?)
        case symbol(String)

        static func == (a: Badge, b: Badge) -> Bool {
            switch (a, b) {
            case (.image(let x, _), .image(let y, _)): return x == y
            case (.symbol(let x), .symbol(let y)): return x == y
            default: return false
            }
        }

        var key: String {
            switch self {
            case .image(let name, _): return "image-" + name
            case .symbol(let name): return "symbol-" + name
            }
        }
    }

    let icon: NSImage?
    let badge: Badge?
    let ticked: Bool
    let working: Bool
    private let size: CGFloat = 56

    var body: some View {
        let corner = (size * 0.42).rounded()
        let plate = RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
        Group {
            if let icon {
                Image(nsImage: icon).resizable().interpolation(.high)
                    .frame(width: size, height: size)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            } else {
                plate.fill(Color.primary.opacity(0.045))
                    .overlay { Symbol("puzzlepiece.extension", size: size * 0.4).foregroundStyle(.primary) }
                    .overlay { plate.strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5) }
                    .frame(width: size, height: size)
            }
        }
        .overlay {
            // The icon's own shape, a few points out: a run along its edge
            // while yab works, closing round it in green as it lands.
            Seam(size: size, corner: size * 0.225, working: working, ticked: ticked)
        }
        // The badge sits in a hole cut out of the mark and its seam, rather
        // than on a plate of the window's color.
        .notched(ticked || badge != nil, side: corner, radius: ticked ? corner / 2 : corner * 0.25,
                 offset: corner * 0.28, gap: 2.5)
        .overlay(alignment: .bottomTrailing) {
            Group {
                if ticked {
                    Symbol("checkmark", size: corner * 0.5, weight: .bold)
                        .foregroundStyle(.white)
                        .frame(width: corner, height: corner)
                        .background(Circle().fill(Color.green))
                        .transition(.scale(scale: 0.2).combined(with: .opacity))
                } else if let badge {
                    Group {
                        switch badge {
                        case .image(_, let image):
                            if let image { Image(nsImage: image).resizable().interpolation(.high) } else { Symbol("globe", size: corner * 0.5) }
                        case .symbol(let name):
                            Symbol(name, size: corner * 0.45)
                                .frame(width: corner, height: corner)
                                .background(RoundedRectangle(cornerRadius: corner * 0.25, style: .continuous).fill(Color.primary.opacity(0.08)))
                        }
                    }
                    .frame(width: corner, height: corner)
                    .clipShape(RoundedRectangle(cornerRadius: corner * 0.25, style: .continuous))
                    .id(badge.key)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .offset(x: corner * 0.28, y: corner * 0.28)
        }
        .animation(.snappy(duration: 0.24, extraBounce: 0), value: badge?.key)
        .animation(.snappy(duration: 0.24, extraBounce: 0), value: ticked)
        .animation(.snappy(duration: 0.24, extraBounce: 0), value: icon == nil)
        .accessibilityHidden(true)
    }
}

/// The mark's edge, drawn a few points outside it and parallel to it, the
/// same squircle, its corners the icon's plus the gap, so the two read as
/// one shape. While yab works a short run travels round it over a faint
/// track, the way a ring turns round a round thing; when it lands the run
/// spreads to close the whole edge in green, and then lets go.
struct Seam: View {
    let size: CGFloat
    let corner: CGFloat
    let working: Bool
    let ticked: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// How much of the edge the green has closed, and how much of it is left.
    @State private var closed: CGFloat = 0
    @State private var fading = false

    private let gap: CGFloat = 5
    private let line: CGFloat = 2
    private let run: CGFloat = 0.22
    private let lap: Double = 1.15

    var body: some View {
        let outer = RoundedRectangle(cornerRadius: corner + gap, style: .continuous)
        ZStack {
            if working {
                outer.stroke(Color.primary.opacity(0.07), lineWidth: line)
                    .transition(.opacity)
                if reduceMotion {
                    outer.stroke(Color.primary.opacity(0.25), lineWidth: line)
                } else {
                    TimelineView(.animation) { context in
                        let phase = CGFloat(context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: lap) / lap)
                        ZStack {
                            outer.trim(from: phase, to: min(phase + run, 1))
                                .stroke(Color.primary.opacity(0.55), style: StrokeStyle(lineWidth: line, lineCap: .round))
                            if phase + run > 1 {
                                outer.trim(from: 0, to: phase + run - 1)
                                    .stroke(Color.primary.opacity(0.55), style: StrokeStyle(lineWidth: line, lineCap: .round))
                            }
                        }
                    }
                    .transition(.opacity)
                }
            }
            if ticked {
                outer.trim(from: 0.5 - closed / 2, to: 0.5 + closed / 2)
                    .stroke(Color.green.opacity(fading ? 0 : 0.8), style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: size + gap * 2, height: size + gap * 2)
        .allowsHitTesting(false)
        .onChange(of: ticked) { _, ticked in
            guard ticked else {
                closed = 0
                fading = false
                return
            }
            // Closing from the bottom, where the tick sits, round both ways.
            closed = reduceMotion ? 1 : 0
            fading = false
            withAnimation(reduceMotion ? nil : .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.32)) { closed = 1 }
            withAnimation(.easeOut(duration: 0.45).delay(reduceMotion ? 0.2 : 0.36)) { fading = true }
        }
    }
}

/// An almost-closed ring, turning, in whatever color it is given, the
/// button's own ink inside the button, gray round the mark.
private struct Turning: View {
    var size: CGFloat
    var line: CGFloat = 1.6
    @State private var angle: Double = 0

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.78)
            .stroke(style: StrokeStyle(lineWidth: line, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(angle))
            .onAppear {
                withAnimation(.linear(duration: 0.85).repeatForever(autoreverses: false)) { angle = 360 }
            }
    }
}
