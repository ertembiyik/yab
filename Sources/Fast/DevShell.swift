import AppKit
import SwiftUI

// What every panel of Yab's own shares, as Chromium's DevTools has it around
// its panels: the drawer under them (Escape), the command menu (⇧⌘P) and
// Open file (⌘P), Settings (F1, the gear), and the keys that work while
// the keyboard is in the card.

// MARK: - the drawer

/// The drawer's tools, Chrome's, in More tools' order.
enum DevTool: String, CaseIterable, Identifiable, Hashable {
    case console = "Console"
    case comments = "Comments"
    case protocolMonitor = "Protocol monitor"
    case rendering = "Rendering", sensors = "Sensors", animations = "Animations", coverage = "Coverage"
    case changes = "Changes", cssOverview = "CSS overview", issues = "Issues", search = "Search"
    case networkConditions = "Network conditions", requestConditions = "Request conditions", quickSource = "Quick source"
    case developerResources = "Developer resources", memoryInspector = "Memory inspector", media = "Media"
    case performanceMonitor = "Performance monitor", layers = "Layers", autofill = "Autofill", webAudio = "WebAudio", webAuthn = "WebAuthn"

    var id: String { rawValue }
}

/// The drawer: open or not, the tools opened in it, the one shown, its height.
@MainActor @Observable final class DevDrawerState {
    var open = false
    var tool: DevTool = .console
    var tools: [DevTool] = [.console]
    var height: CGFloat = (Store.settings.object(forKey: "dev.drawerHeight") as? Double).map { CGFloat($0) } ?? 220

    func show(_ tool: DevTool) {
        if !tools.contains(tool) { tools.append(tool) }
        self.tool = tool
        open = true
    }

    func close(_ tool: DevTool) {
        guard tool != .console else { open = false; return }
        tools.removeAll { $0 == tool }
        if self.tool == tool { self.tool = tools.last ?? .console }
    }
}

nonisolated(unsafe) private var drawerKey: UInt8 = 0
nonisolated(unsafe) private var commandKey: UInt8 = 0

extension Browser {
    var toolDrawer: DevDrawerState {
        if let state = objc_getAssociatedObject(self, &drawerKey) as? DevDrawerState { return state }
        let state = DevDrawerState()
        objc_setAssociatedObject(self, &drawerKey, state, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return state
    }

    /// Escape: the drawer in or out; Console in it under any other panel.
    func toggleToolDrawer() {
        let drawer = toolDrawer
        if drawer.open { drawer.open = false; return }
        if devPane == .console, drawer.tool == .console, drawer.tools.count > 1 { drawer.tool = drawer.tools.first { $0 != .console } ?? .console }
        drawer.open = true
        fitToolDrawer()
    }

    private func fitToolDrawer() {
        guard devSide == .bottom else { return }
        let size = DevSize.shared
        let current = DevLook.height(in: size.room, wanted: size.height)
        size.height = max(current, toolDrawer.height + 260)
    }

    func showTool(_ tool: DevTool) {
        if !devOpen { openDevTools(devPane) }
        toolDrawer.show(tool)
        fitToolDrawer()
        if tool == .protocolMonitor, let tab = toolsFront, !tab.devModel(ProtocolLog.self).recording { protocolRecord(true) }
    }

    var devCommand: DevCommandState {
        if let state = objc_getAssociatedObject(self, &commandKey) as? DevCommandState { return state }
        let state = DevCommandState()
        objc_setAssociatedObject(self, &commandKey, state, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return state
    }
}

struct DevDrawerView: View {
    let browser: Browser
    var tab: Tab
    var drawer: DevDrawerState
    @State private var from: CGFloat?

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Palette.ink.opacity(0.08)).frame(height: 1)
                .overlay {
                    Color.clear.frame(height: 6).contentShape(Rectangle())
                        .pointerStyle(.frameResize(position: .top))
                        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { drag in
                                let start = from ?? drawer.height
                                if from == nil { from = start }
                                drawer.height = min(800, max(90, (start - drag.translation.height).rounded()))
                            }
                            .onEnded { _ in
                                from = nil
                                Store.settings.set(Double(drawer.height), forKey: "dev.drawerHeight")
                            })
                }
            HStack(spacing: 1) {
                ScrollViewReader { reader in
                ThreadScrollView(.horizontal) {
                HStack(spacing: 1) {
                ForEach(drawer.tools) { tool in
                    Button { drawer.tool = tool } label: {
                        HStack(spacing: 4) {
                            Text(tool.rawValue).font(.system(size: 11.5, weight: .medium)).fixedSize()
                            if tool != .console, drawer.tool == tool {
                                Button { drawer.close(tool) } label: { Symbol("xmark", size: 7) }.buttonStyle(.plain)
                            }
                        }
                    }
                    .buttonStyle(.yab(drawer.tool == tool ? .secondary : .quiet, .small))
                    .id(tool.id)
                }
                Menu {
                    ForEach(DevTool.allCases) { tool in
                        Button(tool.rawValue) { browser.showTool(tool) }
                    }
                } label: { Symbol("ellipsis", size: 10) }
                    .menuStyle(.button)
                    .menuIndicator(.hidden)
                    .buttonStyle(.yab(.quiet, .small))
                    .fixedSize()
                    .keyTip("More tools")
                }
                }
                .scrollIndicators(.never)
                .onAppear { reader.scrollTo(drawer.tool.id, anchor: .center) }
                .onChange(of: drawer.tool) { reader.scrollTo(drawer.tool.id, anchor: .center) }
                }
                Spacer(minLength: 0)
                Button { drawer.open = false } label: { Symbol("xmark", size: 9) }
                    .buttonStyle(.yab(.quiet, .small))
                    .keyTip("Close drawer", keys: "esc")
            }
            .focusable(false)
            .padding(.horizontal, 6)
            .frame(height: 28)
            Rectangle().fill(Palette.ink.opacity(0.06)).frame(height: 1)
            DevKeyHost {
                switch drawer.tool {
                case .console:
                    DevConsolePane(browser: browser, tab: tab, log: tab.devModel(ConsoleLog.self), panel: browser.consolePanel, compact: true)
                case .issues:
                    DevIssues(browser: browser, tab: tab, log: tab.devLog, filter: .all, wide: false)
                case .networkConditions, .requestConditions:
                    NetDrawerView(browser: browser, log: tab.netLog, panel: browser.netPanel, prefs: NetPrefs.shared, drawer: drawer.tool == .networkConditions ? .conditions : .rules, pick: { browser.showTool($0 == .conditions ? .networkConditions : .requestConditions) }, close: { drawer.open = false })
                case .quickSource:
                    DevSourcesPane(browser: browser, model: tab.devModel(DevWorkbench.self))
                case .comments:
                    DevCommentsPane(browser: browser, model: tab.devModel(DevWorkbench.self))
                case .protocolMonitor:
                    ProtocolMonitor(browser: browser, log: tab.devModel(ProtocolLog.self))
                default:
                    DevExtraTool(browser: browser, model: tab.devModel(DevWorkbench.self), tool: drawer.tool)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: drawer.height)
    }
}

// MARK: - the protocol monitor

struct ProtocolMonitor: View {
    let browser: Browser
    var log: ProtocolLog
    @State private var filter = ""
    @State private var command = ""
    @State private var picked: Int?

    var body: some View {
        let shown = filter.isEmpty ? log.messages : log.messages.filter { $0.method.localizedCaseInsensitiveContains(filter) || $0.request.localizedCaseInsensitiveContains(filter) }
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                Button { browser.protocolRecord(!log.recording) } label: {
                    Circle().fill(log.recording ? DevLook.red : Color.clear)
                        .overlay(Circle().strokeBorder(log.recording ? Color.clear : Palette.muted, lineWidth: 1.5))
                        .frame(width: 10, height: 10)
                }
                .buttonStyle(.yab(.quiet, .small))
                .keyTip(log.recording ? "Stop recording" : "Record")
                Button { log.clear() } label: { Symbol("nosign", size: 11) }
                    .buttonStyle(.yab(.quiet, .small))
                    .keyTip("Clear all")
                HStack(spacing: 4) {
                    Symbol("line.3.horizontal.decrease", size: 10).foregroundStyle(Palette.muted)
                    TextField("Filter", text: $filter).textFieldStyle(.plain).font(DevMono.font(11.5))
                }
                .padding(.horizontal, 6)
                .frame(width: 220, height: ButtonSize.small.height)
                .background(Palette.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                Button { save(shown) } label: { Symbol("square.and.arrow.down", size: 11) }
                    .buttonStyle(.yab(.quiet, .small))
                    .keyTip("Save")
                Spacer(minLength: 0)
                Text("WebKit’s protocol, both ways").foregroundStyle(Palette.muted)
            }
            .font(.system(size: 11.5))
            .padding(.horizontal, 6)
            .frame(height: 28)
            Rectangle().fill(Palette.ink.opacity(0.06)).frame(height: 1)
            ThreadScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 0) {
                        head("Method", 240)
                        head("Request · Response", nil)
                        head("Elapsed", 70)
                        head("Type", 64)
                        head("Target", 90)
                    }
                    ForEach(shown) { message in
                        HStack(spacing: 0) {
                            cell(message.method, 240, mono: true)
                            cell(message.error.isEmpty ? message.request + (message.response.isEmpty ? "" : "  →  " + message.response) : message.error, nil, mono: true, ink: message.error.isEmpty ? Palette.muted : DevLook.errorInk)
                            cell(message.elapsed.map { String(format: "%.0f ms", $0) } ?? "", 70)
                            cell(message.kind == "send" ? "↑ send" : "↓ event", 64)
                            cell(message.target.isEmpty ? "page" : message.target, 90)
                        }
                        .background(picked == message.id ? Color.accentColor.opacity(0.15) : .clear)
                        .contentShape(Rectangle())
                        .onTapGesture { picked = message.id }
                    }
                }
            }
            .defaultScrollAnchor(.bottom)
            Rectangle().fill(Palette.ink.opacity(0.06)).frame(height: 1)
            HStack(spacing: 6) {
                TextField("Send a raw command: DOM.getDocument or {\"method\":\"DOM.getDocument\",\"params\":{\"depth\":2}}", text: $command)
                    .textFieldStyle(.plain)
                    .font(DevMono.font(11.5))
                    .onSubmit(send)
                Button("Send", action: send).buttonStyle(.yab(.secondary, .small)).keyTip("Send command", keys: "⌘↩")
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
        }
        .onAppear { if !log.recording { browser.protocolRecord(true) } }
    }

    private func head(_ title: String, _ width: CGFloat?) -> some View {
        Text(title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Palette.muted)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(width: width, alignment: .leading)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            .frame(height: 22)
            .background(Palette.ink.opacity(0.03))
    }

    private func cell(_ text: String, _ width: CGFloat?, mono: Bool = false, ink: Color = Palette.ink) -> some View {
        Text(text).font(mono ? DevMono.font(11) : .system(size: 11)).foregroundStyle(ink)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 6)
            .frame(width: width, alignment: .leading)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            .frame(height: 20)
    }

    private func send() {
        let text = command.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        var method = text
        var params: [String: Any] = [:]
        if text.hasPrefix("{"), let data = text.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            method = json["method"] as? String ?? json["command"] as? String ?? ""
            params = json["params"] as? [String: Any] ?? json["parameters"] as? [String: Any] ?? [:]
        }
        browser.wire("wire.raw", ["method": method, "params": params])
    }

    private func save(_ messages: [ProtocolLog.Message]) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "protocol-monitor.json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let rows = messages.map { ["method": $0.method, "type": $0.kind, "request": $0.request, "response": $0.response, "error": $0.error, "elapsed": $0.elapsed ?? 0] as [String: Any] }
            if let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted]) { try? data.write(to: url) }
        }
    }
}

// MARK: - the command menu and Open file

/// A command of the menu: Chrome's category, words, keys, what it does.
struct DevCommand: Identifiable {
    var id: String { category + "·" + title }
    let category: String
    let title: String
    var keys = ""
    let run: () -> Void
}

/// An entry of Open file: a file the page loaded.
struct DevFile: Identifiable, Hashable {
    var id: String { url }
    let url: String
    let name: String
    let folder: String
}

@MainActor @Observable final class DevCommandState: NSObject, NSWindowDelegate {
    /// What is typed: ">" for commands, nothing for files; nil when shut.
    var query: String?
    var picked = 0
    /// Settings (F1), on which of its tabs.
    var settings: DevSettingsTab?
    @ObservationIgnored private(set) var settingsWindow: NSWindow?

    func presentSettings(for browser: Browser) {
        guard settings != nil else {
            if let window = settingsWindow {
                window.parent?.removeChildWindow(window)
                window.orderOut(nil)
            }
            return
        }
        query = nil
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 480),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Developer Tools Settings"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = WindowHosting.content(DevSettingsView(browser: browser, state: self))
            window.center()
            settingsWindow = window
        }
        guard let window = settingsWindow, !window.isVisible else { return }
        browser.devWindow?.addChildWindow(window, ordered: .above)
        window.makeKeyAndOrderFront(nil)
    }

    func closeSettings() {
        settings = nil
        settingsWindow?.close()
        settingsWindow?.contentView = nil
        settingsWindow = nil
    }

    func windowWillClose(_ notification: Notification) {
        settings = nil
        if let window = settingsWindow { window.parent?.removeChildWindow(window) }
    }
}

extension Browser {
    /// ⇧⌘P with ">", ⌘P with nothing typed.
    func openDevCommand(_ prefix: String) {
        if !devOpen { openDevTools(devPane) }
        devCommand.query = prefix
        devCommand.picked = 0
    }

    /// Every command there is, Chrome's categories: the panels and tools,
    /// what each of Yab's panels can do, the settings to turn on or off.
    func devCommands() -> [DevCommand] {
        var out: [DevCommand] = []
        for tab in DevTab.allCases { out.append(DevCommand(category: "Panel", title: "Show " + tab.title) { [weak self] in self?.pickDevPane(tab.pane) }) }
        for tool in DevTool.allCases { out.append(DevCommand(category: "Drawer", title: "Show " + tool.rawValue) { [weak self] in self?.showTool(tool) }) }
        out.append(DevCommand(category: "Drawer", title: "Toggle drawer", keys: "esc") { [weak self] in self?.toggleToolDrawer() })
        out += consoleCommands()
        out += [
            DevCommand(category: "Network", title: "Clear network log", keys: "⌘K") { [weak self] in self?.netClear() },
            DevCommand(category: "Network", title: NetPrefs.shared.noCache ? "Enable cache" : "Disable cache") { NetPrefs.shared.noCache.toggle() },
            DevCommand(category: "Network", title: NetPrefs.shared.throttle == NetThrottle.offline.id ? "Go online" : "Go offline") {
                NetPrefs.shared.throttle = NetPrefs.shared.throttle == NetThrottle.offline.id ? NetThrottle.none.id : NetThrottle.offline.id
            },
        ]
        for preset in NetThrottle.presets {
            out.append(DevCommand(category: "Network", title: "Use " + preset.name + " throttling") { NetPrefs.shared.throttle = preset.id })
        }
        out += [
            DevCommand(category: "Mobile", title: "Toggle device toolbar", keys: "⇧⌘M") { [weak self] in self?.toggleDevice() },
            DevCommand(category: "Elements", title: "Select an element in the page to inspect it", keys: "⇧⌘C") { [weak self] in self?.inspectElement() },
            DevCommand(category: "Global", title: "Ask in Chat") { [weak self] in self?.askAboutDev() },
            DevCommand(category: "Global", title: "Give your agent access to DevTools") { [weak self] in
                guard let self else { return }
                SettingsWindow.shared.show(.developers, for: self)
            },
            DevCommand(category: "Appearance", title: "Dock to bottom") { [weak self] in self?.setDevSide(.bottom) },
            DevCommand(category: "Appearance", title: "Dock to right") { [weak self] in self?.setDevSide(.right) },
            DevCommand(category: "Appearance", title: "Dock to left") { [weak self] in self?.setDevSide(.left) },
            DevCommand(category: "Appearance", title: "Undock into separate window") { [weak self] in self?.detachDevTools() },
            DevCommand(category: "Settings", title: "Show Preferences", keys: "F1") { [weak self] in self?.devCommand.settings = .preferences },
            DevCommand(category: "Settings", title: "Show Shortcuts") { [weak self] in self?.devCommand.settings = .shortcuts },
            DevCommand(category: "Settings", title: "Show Throttling") { [weak self] in self?.devCommand.settings = .throttling },
            DevCommand(category: "Settings", title: "Show Devices") { [weak self] in self?.devCommand.settings = .devices },
            DevCommand(category: "Navigation", title: "Reload page", keys: "⌘R") { [weak self] in self?.active?.page.reload(fromOrigin: false) },
            DevCommand(category: "Navigation", title: "Hard reload page", keys: "⇧⌘R") { [weak self] in self?.active?.page.reload(fromOrigin: true) },
        ]
        for setting in DevOverride.allCases {
            out.append(DevCommand(category: "Rendering", title: setting.title) { [weak self] in self?.toggleDevOverride(setting) })
        }
        out.append(DevCommand(category: "Rendering", title: "Emulate CSS prefers-color-scheme: dark") { [weak self] in self?.setDevAppearance("Dark") })
        out.append(DevCommand(category: "Rendering", title: "Emulate CSS prefers-color-scheme: light") { [weak self] in self?.setDevAppearance("Light") })
        out.append(DevCommand(category: "Rendering", title: "Do not emulate CSS prefers-color-scheme") { [weak self] in self?.setDevAppearance(nil) })
        return out
    }

    /// The page's files, for Open file: what Network heard, scripts and
    /// stylesheets and documents first.
    func devFiles() -> [DevFile] {
        guard let tab = toolsFront else { return [] }
        var seen = Set<String>()
        var out: [DevFile] = []
        for row in tab.netLog.rows where !seen.contains(row.url) {
            guard ["document", "script", "stylesheet", "xhr", "fetch", "font", "image", "other"].contains(row.resource.type) else { continue }
            guard let url = URL(string: row.url), url.scheme == "http" || url.scheme == "https" || url.scheme == "file" else { continue }
            seen.insert(row.url)
            out.append(DevFile(url: row.url, name: url.lastPathComponent.isEmpty ? (url.host() ?? row.url) : url.lastPathComponent,
                               folder: (url.host() ?? "") + url.deletingLastPathComponent().path()))
        }
        for file in workbench?.sources ?? [] where !seen.contains(file.url) {
            guard let url = URL(string: file.url) else { continue }
            seen.insert(file.url)
            out.append(DevFile(url: file.url, name: file.name, folder: (url.host() ?? "") + url.deletingLastPathComponent().path()))
        }
        return out
    }
}

/// Chrome's fuzzy match: the letters in order, runs and word starts first.
enum DevFuzzy {
    static func score(_ query: String, _ text: String) -> Int? {
        guard !query.isEmpty else { return 0 }
        let q = Array(query.lowercased()), t = Array(text.lowercased())
        var i = 0, score = 0, last = -2
        for (j, c) in t.enumerated() where i < q.count && c == q[i] {
            score += j == last + 1 ? 3 : 1
            if j == 0 || t[j - 1] == " " || t[j - 1] == "." || t[j - 1] == "/" { score += 2 }
            last = j
            i += 1
        }
        return i == q.count ? score : nil
    }
}

struct DevCommandMenu: View {
    let browser: Browser
    var state: DevCommandState
    @FocusState private var focused: Bool
    var width: CGFloat = 560
    var listHeight: CGFloat = 320

    private struct Row: Identifiable {
        let id: String
        let category: String
        let title: String
        let keys: String
        let run: () -> Void
    }

    var body: some View {
        let query = state.query ?? ""
        let rows = rows(query)
        VStack(spacing: 0) {
            DevCommandField(text: Binding(get: { state.query ?? "" }, set: { if state.query != nil { state.query = $0; state.picked = 0 } }), placeholder: query.hasPrefix(">") ? "Run command" : "Open file", command: command)
                .padding(.horizontal, 12)
                .frame(height: 36)
            Rectangle().fill(Palette.ink.opacity(0.08)).frame(height: 1)
            ScrollViewReader { reader in
                ThreadScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(rows.prefix(80).enumerated()), id: \.element.id) { index, row in
                            HStack(spacing: 10) {
                                Text(row.category).font(.system(size: 11.5)).foregroundStyle(index == state.picked ? Color.white.opacity(0.8) : Palette.muted).frame(width: 96, alignment: .leading)
                                Text(row.title).font(.system(size: 12.5)).lineLimit(1)
                                Spacer(minLength: 4)
                                if !row.keys.isEmpty { Text(row.keys).font(.system(size: 11.5)).foregroundStyle(index == state.picked ? Color.white.opacity(0.8) : Palette.muted) }
                            }
                            .foregroundStyle(index == state.picked ? Color.white : Palette.ink)
                            .padding(.horizontal, 10)
                            .frame(height: 26)
                            .background(index == state.picked ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
                            .contentShape(Rectangle())
                            .onTapGesture { let run = row.run; state.query = nil; run() }
                            .id(index)
                        }
                        if rows.isEmpty {
                            Text("No results found").foregroundStyle(Palette.muted).frame(height: 30)
                        }
                    }
                    .padding(4)
                }
                .frame(maxHeight: listHeight)
                .onChange(of: state.picked) { reader.scrollTo(state.picked) }
            }
            Rectangle().fill(Palette.ink.opacity(0.08)).frame(height: 1)
            Text(query.hasPrefix(">") ? "Run command · ↩ to run · ⌫ to Open file" : "Open file · > commands · : line · ? help")
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .frame(height: 24)
        }
        .frame(width: width)
        .cardFrame()
        .onAppear { focused = true }
    }

    private func command(_ selector: Selector) -> Bool {
        let rows = rows(state.query ?? "")
        switch NSStringFromSelector(selector) {
        case "moveDown:": state.picked = min(max(0, rows.count - 1), state.picked + 1)
        case "moveUp:": state.picked = max(0, state.picked - 1)
        case "insertNewline:":
            if rows.indices.contains(state.picked) { let run = rows[state.picked].run; state.query = nil; run() }
        case "cancelOperation:": state.query = nil
        case "deleteBackward:":
            guard state.query == ">" else { return false }; state.query = ""
        default: return false
        }
        return true
    }
    private func rows(_ query: String) -> [Row] {
        if query.hasPrefix(">") {
            let words = query.dropFirst().trimmingCharacters(in: .whitespaces)
            return browser.devCommands()
                .compactMap { command in DevFuzzy.score(words, command.category + " " + command.title).map { (command, $0) } }
                .sorted { $0.1 > $1.1 }
                .map { command, _ in Row(id: command.id, category: command.category, title: command.title, keys: command.keys, run: command.run) }
        }
        if query.hasPrefix("?") {
            return [("", "Open file"), (">", "Run command"), (":", "Go to line"), ("@", "Go to symbol"), ("!", "Run snippet")].map { prefix, title in
                Row(id: prefix, category: prefix.isEmpty ? "…" : prefix, title: title, keys: "") { [weak state] in
                    DispatchQueue.main.async { state?.query = prefix }
                }
            }
        }
        if query.hasPrefix(":") {
            guard let model = browser.workbench, model.source != nil,
                  let line = Int(query.dropFirst().split(separator: ":").first ?? ""), line > 0,
                  line <= model.sourceText.components(separatedBy: "\n").count else { return [] }
            return [Row(id: "line", category: ":", title: "Go to line \(line)", keys: "") { model.sourceLine = line - 1; browser.pickDevPane(.sources) }]
        }
        if query.hasPrefix("@"), let model = browser.workbench {
            let words = String(query.dropFirst())
            return DevSourceSymbols.symbols(model.sourceText).filter { DevFuzzy.score(words, $0.name) != nil }.map { symbol in
                Row(id: symbol.name + String(symbol.line), category: "@", title: symbol.name, keys: String(symbol.line + 1)) { model.sourceLine = symbol.line; browser.pickDevPane(.sources) }
            }
        }
        if query.hasPrefix("!") {
            let words = String(query.dropFirst())
            return DevSourcePrefs.shared.snippets.filter { DevFuzzy.score(words, $0.name) != nil }.map { snippet in
                Row(id: snippet.id.uuidString, category: "Snippet", title: snippet.name, keys: "") { browser.consoleRun(snippet.text); browser.showTool(.console) }
            }
        }
        let words = query.trimmingCharacters(in: .whitespaces)
        return browser.devFiles()
            .compactMap { file in DevFuzzy.score(words, file.name).map { (file, $0) } ?? DevFuzzy.score(words, file.url).map { (file, $0 - 5) } }
            .sorted { $0.1 > $1.1 }
            .map { file, _ in
                Row(id: file.url, category: file.name, title: file.folder, keys: "") { [weak browser] in
                    if let place = DevPlace(file.url + ":1:1") { browser?.revealSource(place) }
                }
            }
    }
}

// MARK: - settings

enum DevSettingsTab: String, CaseIterable, Identifiable {
    case preferences = "Preferences", workspace = "Workspace", ignoreList = "Ignore list", throttling = "Throttling", devices = "Devices", shortcuts = "Shortcuts"
    var id: String { rawValue }
}

struct DevSettingsView: View {
    let browser: Browser
    var state: DevCommandState
    @Bindable var console = ConsolePrefs.shared
    @Bindable var net = NetPrefs.shared

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Settings").font(.system(size: 15, weight: .semibold)).padding(.horizontal, 10).padding(.bottom, 8)
                ForEach(DevSettingsTab.allCases) { tab in
                    Button { state.settings = tab } label: {
                        Text(tab.rawValue).font(.system(size: 12.5)).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.yab(state.settings == tab ? .secondary : .quiet, .small))
                }
                Spacer(minLength: 0)
                Button("WebKit Inspector Settings…") { state.settings = nil; browser.pickDevPane(.webkit(.settings)) }
                    .buttonStyle(.yab(.quiet, .small))
            }
            .padding(12)
            .frame(width: 200)
            .background(Palette.ink.opacity(0.03))
            ThreadScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch state.settings ?? .preferences {
                    case .preferences: preferences
                    case .workspace:
                        Text("Workspace").font(.system(size: 15, weight: .medium))
                        Text(browser.workbench?.workspace?.path ?? "No project folder connected").textSelection(.enabled)
                        Button("Connect project folder…") { browser.sourcesChooseWorkspace() }
                        Text("Save maps local page URLs to files inside this folder. Files outside it are never written.").foregroundStyle(Palette.muted)
                    case .ignoreList: DevIgnoreSettings(browser: browser)
                    case .throttling: throttling
                    case .devices: devices
                    case .shortcuts: shortcuts
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .overlay(alignment: .topTrailing) {
                Button { state.settings = nil } label: { Symbol("xmark", size: 10) }
                    .buttonStyle(.yab(.quiet, .small))
                    .keyTip("Close", keys: "esc")
                    .padding(8)
            }
        }
        .frame(width: 760, height: 480)
        .cardFrame()
        .onExitCommand { state.settings = nil }
    }

    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 13, weight: .semibold)).padding(.bottom, 2)
            content()
        }
    }

    private func box(_ title: String, _ value: Binding<Bool>) -> some View {
        Toggle(isOn: value) { Text(title).font(.system(size: 12)) }.toggleStyle(.checkbox).controlSize(.small)
    }

    @ViewBuilder private var preferences: some View {
        section("Appearance") {
            Picker("Panel layout", selection: Binding(get: { browser.prefs.devSide }, set: { browser.setDevSide($0) })) {
                Text("Bottom").tag(DevSide.bottom)
                Text("Right").tag(DevSide.right)
                Text("Left").tag(DevSide.left)
            }
            .pickerStyle(.segmented)
            .frame(width: 260)
            Text("Theme: as Yab’s").font(.system(size: 11.5)).foregroundStyle(Palette.muted)
        }
        section("Console") {
            box("Network messages", $console.networkMessages)
            box("Selected context only", $console.selectedContextOnly)
            box("Timestamps", $console.timestamps)
            box("Autocomplete from history", $console.historyCompletion)
            box("Group similar messages", $console.groupSimilar)
            box("CORS errors in console", $console.corsErrors)
            box("Eager evaluation", $console.eager)
            box("Treat code evaluation as user action", $console.userActivation)
            box("Automatically expand console.trace() messages", $console.expandTraces)
            box("Keep log on navigation", $console.keepLog)
            box("Log XMLHttpRequests", $console.logXHR)
        }
        section("Network") {
            box("Disable cache while DevTools is open", $net.noCache)
            box("Keep log", $net.keepLog)
            box("Big request rows", $net.bigRows)
            box("Group network log by frame", $net.groupByFrame)
            box("Show overview", $net.overview)
            box("Capture screenshots", $net.screenshots)
        }
    }

    @ViewBuilder private var throttling: some View {
        section("Network throttling profiles") {
            ForEach(NetThrottle.presets + net.profiles) { profile in
                HStack {
                    Text(profile.name).frame(width: 160, alignment: .leading)
                    Text("\(Int(profile.download)) kbit/s down · \(Int(profile.upload)) kbit/s up · \(Int(profile.latency)) ms").foregroundStyle(Palette.muted)
                }
                .font(.system(size: 12))
            }
            Button("Add profile…") { NetPrefs.shared.addProfile(); state.settings = nil; browser.pickDevPane(.network) }
                .buttonStyle(.yab(.secondary, .small))
        }
        section("CPU throttling presets") {
            Text("WebKit doesn’t slow a page’s processor down, by its protocol or otherwise: there are none to calibrate.")
                .font(.system(size: 12)).foregroundStyle(Palette.muted)
        }
    }

    @ViewBuilder private var devices: some View {
        section("Emulated Devices") {
            ForEach(DeviceMode.presets, id: \.name) { preset in
                HStack {
                    Text(preset.name).frame(width: 180, alignment: .leading)
                    Text("\(Int(preset.width)) × \(Int(preset.height))").foregroundStyle(Palette.muted)
                }
                .font(.system(size: 12))
            }
        }
    }

    @ViewBuilder private var shortcuts: some View {
        section("Shortcuts") {
            ForEach(DevShortcut.all, id: \.0) { title, keys in
                HStack {
                    Text(title).frame(width: 280, alignment: .leading)
                    Text(keys).foregroundStyle(Palette.muted)
                }
                .font(.system(size: 12))
            }
        }
    }
}

enum DevShortcut {
    static let all: [(String, String)] = [
        ("Run command", "⇧⌘P"), ("Open file", "⌘P"), ("Toggle drawer", "esc"), ("Settings", "F1"),
        ("Next panel", "⌘]"), ("Previous panel", "⌘["), ("Select an element in the page to inspect it", "⇧⌘C"),
        ("Clear console", "⌘K  ⌃L"), ("Toggle device toolbar", "⇧⌘M"), ("Record network log", "⌘E"),
        ("Save source or stylesheet", "⌘S"), ("Pause / resume JavaScript", "F8"),
        ("Step over", "F10"), ("Step into", "F11"), ("Step out", "⇧F11"),
        ("Record Performance or Recorder", "⌘E"), ("Replay recording", "⌘↩"),
    ]
}

// MARK: - keys

/// The card's own keys while the keyboard is in one of its panels, as
/// Chrome's: asked before the app's, so ⌘K there clears instead of opening
/// Actions and ⌘P opens a file instead of printing.
enum DevKeys {
    @MainActor static func contains(_ responder: NSResponder?) -> Bool {
        if responder is DevKeyTarget { return true }
        if let editor = responder as? NSTextView, editor.isFieldEditor,
           let field = editor.delegate as? NSView, field !== editor, contains(field) { return true }
        var view = responder as? NSView
        while let current = view { if current is DevKeyTarget { return true }; view = current.superview }
        return false
    }
    @MainActor static func take(_ event: NSEvent, browser: Browser) -> Bool {
        guard event.type == .keyDown, browser.devOpen else { return false }
        if browser.devPicking, event.keyCode == 53 { browser.stopPickingElement(); return true }
        let responder = (event.window ?? NSApp.keyWindow)?.firstResponder
        guard contains(responder) || DevFloating.owner(of: event.window ?? NSApp.keyWindow) === browser else { return false }
        // ⌥⌘J and ⌥⌘I from inside the card put it away, as Chromium's do
        // from inside its DevTools (#1467). ⌥⌘J leaves the keys in
        // Console's prompt, and the window's key monitor hands keys typed
        // in the card to the card: pressed again, it went nowhere.
        if Keymap.shared.matches(event, .console) { browser.showConsole(); return true }
        if Keymap.shared.matches(event, .inspector) { browser.developerTools(); return true }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = Hotkey.readings(event).first?.key ?? event.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags == [.command, .shift], key == "c" { browser.inspectElement(); return true }
        if flags == [.command, .shift], key == "m" { browser.toggleDevice(); return true }
        if flags == [.command, .shift], key == "p" { browser.openDevCommand(">"); return true }
        if flags == [.command], key == "p" || key == "o" { browser.openDevCommand(""); return true }
        if flags.isEmpty, event.keyCode == 122 { browser.devCommand.settings = .preferences; return true }
        if flags == [.command], key == "]" || key == "[" {
            let tabs = DevTab.allCases
            let at = tabs.firstIndex { $0.pane == browser.devPane } ?? 0
            browser.pickDevPane(tabs[(at + (key == "]" ? 1 : tabs.count - 1)) % tabs.count].pane)
            return true
        }
        if flags == [.command], let number = Int(key), (1...9).contains(number), DevTab.allCases.indices.contains(number - 1) {
            browser.pickDevPane(DevTab.allCases[number - 1].pane); return true
        }
        if flags == [.command], key == "s", browser.devPane == .sources { browser.sourcesSaveEditor(); return true }
        if flags == [.command], key == "s", browser.devPane == .elements { browser.stylesSave(); return true }
        // ⌘F finds in the panel the keyboard is in, as Chromium's: Elements'
        // tree by words, selector or XPath, Network's requests, Sources'
        // files (in the open file's own editor its find, CodeMirror's);
        // ⌥⌘F looks through every file the page loaded from any panel.
        if flags == [.command], key == "f", browser.devPane == .elements {
            browser.workbench?.elementsFind = true
            browser.workbench?.elementsFocus += 1
            return true
        }
        if flags == [.command] || flags == [.command, .shift], key == "g", browser.devPane == .elements, browser.workbench?.elementsFind == true {
            browser.elementsStep(flags.contains(.shift) ? -1 : 1)
            return true
        }
        if flags == [.command], key == "f", browser.devPane == .network { browser.netSearch(); return true }
        if flags == [.command], key == "f", browser.devPane == .sources, !(responder is DevEditorWebView) { browser.sourcesFind(); return true }
        if flags == [.command, .option], key == "f" {
            if browser.devPane != .sources { browser.pickDevPane(.sources) }
            browser.sourcesFind()
            return true
        }
        // Elements' tree after a press in it (or a pick): Chrome's keys,
        // not while a field of the card is being typed in.
        if browser.devPane == .elements, responder is DevKeyTarget, !(responder is NSTextView),
           let model = browser.workbench, let press = DevKeyClaim.pressAt, model.treeRect?.contains(press) == true,
           browser.elementsKey(event) { return true }
        if flags == [.command], key == "e", browser.devPane == .performance { browser.performanceRecord(!(browser.workbench?.recording ?? false)); return true }
        if browser.devPane == .sources {
            let frame = browser.workbench?.frames.first { $0.id == browser.workbench?.frameID } ?? browser.workbench?.frames.first
            let target = frame?.target ?? ""
            let command: String? = switch event.keyCode {
            case 100 where flags.isEmpty: browser.workbench?.frames.isEmpty == false ? "resume" : "pause"
            case 109 where flags.isEmpty: "stepOver"
            case 103 where flags.isEmpty: "stepInto"
            case 103 where flags == [.shift]: "stepOut"
            default: nil
            }
            if let command { browser.workCall("Debugger." + command, ["__target": target]); return true }
        }
        if flags == [.command], key == "e", browser.devPane == .recorder, let tab = browser.toolsFront {
            if tab.recorder.recording { tab.recorder.stop() } else { tab.recorder.start(tab) }; return true
        }
        if flags == [.command], event.keyCode == 36, browser.devPane == .recorder, let tab = browser.toolsFront { tab.recorder.play(tab); return true }
        // Escape closes a find before it toggles the drawer, as Chromium's,
        // and leaves a Styles edit without toggling it.
        if flags.isEmpty, event.keyCode == 53 {
            if browser.workbench?.styleEditing == true, responder is NSTextView { return false }
            if browser.devPane == .elements, browser.workbench?.elementsFind == true { browser.workbench?.elementsFind = false; return true }
            if browser.devPane == .sources, browser.workbench?.sourcesFind == true { browser.workbench?.sourcesFind = false; return true }
            if browser.devPane == .network, browser.netPanel.searchOpen, !(responder is NetTable) { browser.netPanel.searchOpen = false; return true }
        }
        if responder is PromptTextView {
            if (flags == [.command] && key == "k") || (flags == [.control] && key == "l") { browser.consoleClear(); return true }
            if flags.isEmpty, event.keyCode == 53, !browser.consolePanel.completing {
                browser.toggleToolDrawer()
                return true
            }
        } else if flags.isEmpty, event.keyCode == 53 {
            browser.toggleToolDrawer()
            return true
        }
        return false
    }
}

extension Browser {
    /// The console's own commands, for the menu.
    func consoleCommands() -> [DevCommand] {
        let prefs = ConsolePrefs.shared
        return [
            DevCommand(category: "Console", title: "Clear console", keys: "⌘K") { [weak self] in self?.consoleClear() },
            DevCommand(category: "Console", title: "Clear console history") { prefs.history = [] },
            DevCommand(category: "Console", title: "Create live expression") { [weak self] in
                guard let self, let tab = self.toolsFront else { return }
                self.pickDevPane(.console)
                tab.devModel(ConsoleLog.self).addLive()
                self.consoleLive()
            },
            DevCommand(category: "Console", title: prefs.sidebar ? "Hide console sidebar" : "Show console sidebar") { prefs.sidebar.toggle() },
            DevCommand(category: "Console", title: prefs.timestamps ? "Hide timestamps" : "Show timestamps") { prefs.timestamps.toggle() },
            DevCommand(category: "Console", title: prefs.keepLog ? "Do not keep log on navigation" : "Keep log on navigation") { prefs.keepLog.toggle() },
            DevCommand(category: "Console", title: prefs.networkMessages ? "Hide network messages" : "Show network messages") { prefs.networkMessages.toggle() },
            DevCommand(category: "Console", title: prefs.eager ? "Do not eagerly evaluate" : "Eagerly evaluate text in the prompt") { prefs.eager.toggle() },
        ]
    }
}

// MARK: - in the card

/// The drawer under the panels, when it is open.
struct DevDrawerHost: View {
    let browser: Browser
    var tab: Tab
    var drawer: DevDrawerState

    var body: some View {
        if drawer.open {
            DevDrawerView(browser: browser, tab: tab, drawer: drawer)
        }
    }
}

/// The command menu and Settings, over the card's panels.
struct DevOverlays: View {
    let browser: Browser
    var state: DevCommandState

    var body: some View {
        GeometryReader { room in
            if state.query != nil {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { state.query = nil }
                DevCommandMenu(browser: browser, state: state, width: min(560, max(200, room.size.width - 32)),
                               listHeight: max(48, min(320, room.size.height - 80)))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: state.query != nil ? .infinity : 0, alignment: .top)
        .allowsHitTesting(state.query != nil)
        .onChange(of: state.settings, initial: true) { state.presentSettings(for: browser) }
        .onDisappear { state.closeSettings() }
    }
}
