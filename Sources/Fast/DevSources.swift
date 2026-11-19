import AppKit
import SwiftUI
import WebKit

final class DevEditorWebView: WKWebView, DevKeyTarget {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let browser = BrowserWindows.shared.browser(for: window), DevKeys.take(event, browser: browser) { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// CodeMirror is bundled in the app. The editor sends only the user's edits
/// and gutter clicks back to the native controller.
struct DevSourceEditor: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    let browser: Browser
    @Bindable var model: DevWorkbench
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> DevEditorWebView {
        let config = WKWebViewConfiguration()
        config.processPool = Web.pool
        config.userContentController.add(context.coordinator, name: "editor")
        let web = DevEditorWebView(frame: .zero, configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        web.setAccessibilityLabel("Source editor")
        context.coordinator.web = web
        model.sourceEditor = web
        if let url = Bundle.main.url(forResource: "editor", withExtension: "html", subdirectory: "DevTools") {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return web
    }
    func updateNSView(_ web: DevEditorWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update()
    }
    static func dismantleNSView(_ web: DevEditorWebView, coordinator: Coordinator) { web.configuration.userContentController.removeScriptMessageHandler(forName: "editor") }
    @MainActor final class Coordinator: NSObject, WKScriptMessageHandler {
        var parent: DevSourceEditor
        weak var web: WKWebView?
        var ready = false
        var stamp = ""
        var editedFile = ""
        var editedText = ""
        init(_ parent: DevSourceEditor) { self.parent = parent }
        func update() {
            guard ready, let web, let file = parent.model.source else { return }
            let model = parent.model
            // Pretty printed: its own text, and the page's places shown on
            // its lines.
            let pretty = model.pretty[file.url]
            let text = pretty?.text ?? model.sourceText
            let line = pretty?.shown(model.sourceLine, column: model.sourceColumn) ?? model.sourceLine
            let points = model.breakpoints.filter { $0.url == file.url }.map { pretty?.shown($0.line, column: $0.column) ?? $0.line }
            let dark = parent.colorScheme == .dark
            let id = pretty == nil ? file.id : file.id + ":pretty"
            let stamp = String(dark) + ":" + id + ":" + String(text.hashValue) + ":" + String(line) + ":" + points.description
            guard stamp != self.stamp else { return }; self.stamp = stamp
            let ext = URL(string: file.url)?.pathExtension ?? "js"
            let language = ext == "css" ? "css" : ext == "html" || file.kind.lowercased() == "document" ? "html" : ext == "ts" || ext == "tsx" ? "ts" : "js"
            web.callAsyncJavaScript("window.loadSource(d)", arguments: ["d": ["id": id, "text": text, "line": line, "language": language, "breakpoints": points, "dark": dark, "echo": pretty == nil && editedFile == file.id && editedText == model.sourceText]], in: nil, in: .page) { _ in }
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let data = message.body as? [String: Any] else { return }
            switch data["kind"] as? String {
            case "ready": ready = true; update()
            case "breakpoint": if let line = data["line"] as? Int { parent.browser.sourcesBreakpoint(shown: line) }
            case "changed":
                // Pretty printed is only to read, as Chromium's: its id is
                // another, and what is typed there is not the file's.
                guard data["id"] as? String == parent.model.source?.id, let text = data["text"] as? String else { return }
                editedFile = parent.model.source?.id ?? ""; editedText = text; parent.model.sourceText = text
            case "save":
                guard let file = parent.model.source, parent.model.pretty[file.url] == nil, let text = data["text"] as? String else { return }
                parent.model.sourceText = text; parent.browser.sourcesSave()
            default: break
            }
        }
    }
}

struct DevSourcesPane: View {
    let browser: Browser
    @Bindable var model: DevWorkbench
    private var filter: String { model.paneFilters["sources"] ?? "" }
    private var filterText: Binding<String> { Binding(get: { model.paneFilters["sources"] ?? "" }, set: { model.paneFilters["sources"] = $0 }) }
    @State private var watchExpression = ""
    @State private var snippet = ""
    @State private var snippetName = "Untitled snippet"
    @State private var snippetID: UUID?
    private var sourcePrefs = DevSourcePrefs.shared
    @State private var snippets = false
    @State private var exceptionMode = "none"
    @State private var navOpen = true
    @State private var debugOpen = true
    @State private var breakLine = "1"
    @State private var breakCondition = ""
    @State private var logpoint = ""
    @State private var breaksActive = true
    @State private var eventName = "click"
    @State private var eventBreak = false
    @State private var urlPattern = ""
    var body: some View {
        GeometryReader { size in
            VStack(spacing: 0) {
                DevPanelBar {
                    Button { navOpen.toggle() } label: { Symbol("sidebar.left", size: 11) }.keyTip("Toggle navigator")
                    Button { debugOpen.toggle() } label: { Symbol("sidebar.right", size: 11) }.keyTip("Toggle debugger")
                    Button { browser.sourcesRefresh() } label: { Symbol("arrow.clockwise", size: 11) }
                    if let source = model.source {
                        Text(source.name + (model.sourceText == model.originalSourceText ? "" : " *")).lineLimit(1)
                        // { }, as Chromium's: the file pretty printed, or as it was.
                        Button { browser.sourcesPretty() } label: { Text("{ }").font(DevMono.font(11.5, weight: .semibold)) }
                            .buttonStyle(.yab(model.pretty[source.url] != nil ? .secondary : .quiet, .small))
                            .keyTip(model.pretty[source.url] != nil ? "Show as the page has it" : "Pretty print")
                            .benchSpot("sources pretty")
                    }
                    Spacer(minLength: 4)
                    Button("Save") { browser.sourcesSaveEditor() }.disabled(model.source == nil || model.workspace == nil)
                    Button("Workspace…") { browser.sourcesChooseWorkspace() }
                }
                Divider()
                if !model.openSources.isEmpty, !snippets {
                    ThreadScrollView(.horizontal) {
                        HStack(spacing: 0) {
                            ForEach(model.openSources) { file in
                                Button(file.name + (file.url == model.source?.url && model.sourceText != model.originalSourceText ? " *" : "")) { browser.sourceOpen(file) }
                                    .buttonStyle(.yab(file.url == model.source?.url ? .secondary : .quiet, .small))
                                    .keyTip(file.url)
                            }
                        }.padding(.horizontal, 4)
                    }.frame(height: 28)
                    Divider()
                }
                HSplitView {
                    if navOpen, size.size.width >= 650 { navigator.frame(minWidth: 150, idealWidth: 190, maxWidth: 300) }
                    VStack(spacing: 0) {
                        if !model.frames.isEmpty {
                            HStack { Text("Paused: " + model.pauseReason); Spacer(); Button("Resume") { debug("resume") } }.font(.system(size: 11.5)).padding(8).background(Color.orange.opacity(0.15))
                        }
                        if snippets {
                            HStack {
                                TextField("Snippet name", text: $snippetName).textFieldStyle(.plain)
                                Button("Save snippet") { saveSnippet() }
                                Button("New") { snippetID = nil; snippetName = "Untitled snippet"; snippet = "" }
                            }.font(.system(size: 11.5)).padding(8)
                            ThreadTextEditor(text: $snippet).font(DevMono.font(12))
                            Button("Run snippet") { browser.consoleRun(snippet); browser.showTool(.console) }.padding(8)
                        } else if model.source != nil {
                            DevSourceEditor(browser: browser, model: model).frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                        } else {
                            DevQuiet(words: "Open a file with ⌘P, or select a page resource")
                        }
                        if size.size.width < 650 {
                            Menu("Open file") { ForEach(model.sources) { file in Button(file.name) { browser.sourceOpen(file) } } }.padding(8)
                        }
                    }.frame(minWidth: 160)
                    if debugOpen, size.size.width >= 650 { debugger.frame(minWidth: 190, idealWidth: 240, maxWidth: 360) }
                }
                if debugOpen, size.size.width < 650 {
                    Divider()
                    debugger.frame(height: min(230, size.size.height * 0.45))
                }
                // Search through every file, as Chromium's Search under the
                // editor: a line picked opens its file above.
                if model.sourcesFind {
                    Divider()
                    DevSourcesSearch(browser: browser, model: model).frame(height: max(140, min(340, size.size.height * 0.5)))
                }
            }
        }
        .onAppear { browser.sourcesRefresh() }
        .onChange(of: model.frames.map { $0.id + ":" + String($0.line) }.joined(separator: ",")) { if let frame = model.frames.first { browser.sourcesFrame(frame); refreshWatch() } }
    }

    private var navigator: some View {
        VStack(spacing: 0) {
            HStack { Button("Page") { snippets = false }; Button("Snippets") { snippets = true } }.font(.system(size: 11.5)).padding(8)
            TextField("Filter files", text: filterText).textFieldStyle(.plain).padding(8)
            Divider()
            if snippets {
                ThreadScrollView {
                    ForEach(sourcePrefs.snippets) { item in
                        HStack {
                            Button(item.name) { snippetID = item.id; snippetName = item.name; snippet = item.text }
                            Spacer()
                            Button { sourcePrefs.snippets.removeAll { $0.id == item.id } } label: { Symbol("xmark", size: 8) }
                        }.padding(8).font(.system(size: 11.5))
                    }
                }
            } else {
            ThreadScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.sources.filter { filter.isEmpty || $0.url.localizedCaseInsensitiveContains(filter) }) { file in
                        let found = model.sourcesFind ? model.sourcesFound[file.url] : nil
                        Button { snippets = false; if found != nil { browser.sourceOpenFound(file) } else { browser.sourceOpen(file) } } label: {
                            HStack(spacing: 4) {
                                Symbol(file.kind.lowercased() == "document" ? "doc" : "curlybraces", size: 10)
                                Text(file.name).lineLimit(1); Spacer(minLength: 0)
                                if let found { Text(String(found)).foregroundStyle(Palette.muted).monospacedDigit() }
                            }.padding(.horizontal, 8).padding(.vertical, 4).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .background(model.source?.id == file.id ? Color.accentColor.opacity(0.12) : found != nil ? Color(nsColor: NetInk.found) : .clear)
                            .keyTip(file.url)
                    }
                }
            }
            }
            Divider()
            Text(model.workspace?.lastPathComponent ?? "No workspace connected").font(.system(size: 10)).foregroundStyle(Palette.muted).padding(8)
        }.font(.system(size: 11.5))
    }

    private var debugger: some View {
        VStack(spacing: 0) {
            DevPanelBar {
                Button { debug(model.frames.isEmpty ? "pause" : "resume") } label: { Symbol(model.frames.isEmpty ? "pause.fill" : "play.fill", size: 11) }.keyTip("Pause / Resume")
                Button { debug("stepOver") } label: { Symbol("arrow.turn.down.right", size: 11) }.disabled(model.frames.isEmpty).keyTip("Step over")
                Button { debug("stepInto") } label: { Symbol("arrow.down.to.line", size: 11) }.disabled(model.frames.isEmpty).keyTip("Step into")
                Button { debug("stepOut") } label: { Symbol("arrow.up.to.line", size: 11) }.disabled(model.frames.isEmpty).keyTip("Step out")
                Menu { ForEach(["none", "uncaught", "all"], id: \.self) { state in Button("Pause on exceptions: " + state) { exceptionMode = state; browser.workCall("Debugger.setPauseOnExceptions", ["state": state]) } } } label: { Symbol("exclamationmark.octagon", size: 11) }
            }
            Divider()
            ThreadScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    section("Watch") {
                        TextField("Add expression", text: $watchExpression).textFieldStyle(.plain).onSubmit {
                            guard !watchExpression.isEmpty else { return }; model.watch.append(DevProperty(name: watchExpression, value: "not paused")); watchExpression = ""; refreshWatch()
                        }.padding(8)
                        ForEach(model.watch) { row in
                            HStack { Text(row.name + ": " + row.value).font(DevMono.font(11)); Spacer(); Button { model.watch.removeAll { $0.id == row.id } } label: { Symbol("xmark", size: 8) } }.padding(.horizontal, 8)
                        }
                    }
                    section("Call Stack") {
                        if model.frames.isEmpty { Text("Not paused").foregroundStyle(Palette.muted).padding(8) }
                        ForEach(model.frames) { frame in
                            Button { browser.sourcesFrame(frame); refreshWatch() } label: {
                                HStack { Text(frame.name); Spacer(); Text(place(frame)).foregroundStyle(Palette.muted) }.padding(8)
                            }.buttonStyle(.plain).background(frame.id == model.frameID ? Color.accentColor.opacity(0.1) : .clear)
                        }
                    }
                    section("Scope") {
                        if let frame = model.frames.first(where: { $0.id == model.frameID }) {
                            ForEach(frame.scopes) { scope in
                                DisclosureGroup(scope.name) {
                                    DevScopeRows(browser: browser, scope: scope, target: frame.target)
                                        .id(scope.objectID + ":" + String(frame.line))
                                }.padding(.horizontal, 8)
                            }
                        }
                    }
                    section("Breakpoints") {
                        Toggle("Activate breakpoints", isOn: $breaksActive).padding(.horizontal, 8).onChange(of: breaksActive) { browser.workCall("Debugger.setBreakpointsActive", ["active": breaksActive]) }
                        VStack(spacing: 6) {
                            HStack { TextField("Line", text: $breakLine).frame(width: 45); TextField("Condition", text: $breakCondition) }
                            TextField("Logpoint expression (optional)", text: $logpoint)
                            Button("Add breakpoint / logpoint") { guard let line = Int(breakLine), line > 0 else { model.error = "Enter a positive line number"; return }; browser.sourcesBreakpoint(line - 1, condition: breakCondition, logpoint: logpoint) }.disabled(model.source == nil)
                        }.textFieldStyle(.plain).padding(8)
                        ForEach(model.breakpoints) { breakpoint in
                            HStack {
                                Symbol("circle.fill", size: 8).foregroundStyle(Color.accentColor)
                                Text((URL(string: breakpoint.url)?.lastPathComponent ?? breakpoint.url) + ":\(breakpoint.line + 1)").lineLimit(1)
                                Spacer(minLength: 0)
                                Button { browser.workCall("Debugger.removeBreakpoint", ["breakpointId": breakpoint.id, "__target": breakpoint.target]) { _ in model.breakpoints.removeAll { $0.id == breakpoint.id } } } label: { Symbol("xmark", size: 8) }
                            }.padding(.horizontal, 8).keyTip(breakpoint.condition)
                        }
                    }
                    section("Event listener breakpoint") {
                        HStack { TextField("Event name", text: $eventName).textFieldStyle(.plain); Toggle("Break", isOn: $eventBreak).labelsHidden() }.padding(8)
                            .onChange(of: eventBreak) { browser.workCall(eventBreak ? "DOMDebugger.setEventBreakpoint" : "DOMDebugger.removeEventBreakpoint", ["breakpointType": "listener", "eventName": eventName]) }
                    }
                    section("URL breakpoint") {
                        TextField("Request URL contains", text: $urlPattern).textFieldStyle(.plain).padding(8)
                        HStack { Button("Add") { browser.workCall("DOMDebugger.setURLBreakpoint", ["url": urlPattern, "isRegex": false]) }; Button("Remove") { browser.workCall("DOMDebugger.removeURLBreakpoint", ["url": urlPattern, "isRegex": false]) } }.padding(.horizontal, 8)
                    }
                }.font(.system(size: 11.5))
            }
        }
    }
    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(title).font(.system(size: 11.5, weight: .semibold)).padding(8).frame(maxWidth: .infinity, alignment: .leading).background(Palette.ink.opacity(0.04)); content() }
    }
    /// Where a frame is, as Chromium's call stack says it: the file and the
    /// line as Sources shows them, the source map's file, or the line
    /// pretty printed.
    private func place(_ frame: DevCallFrame) -> String {
        if !frame.mappedURL.isEmpty { return (URL(string: frame.mappedURL)?.lastPathComponent ?? "") + ":" + String(frame.mappedLine + 1) }
        guard let file = model.sources.first(where: { $0.script == frame.script && $0.target == frame.target }) else { return String(frame.line + 1) }
        let line = model.pretty[file.url]?.shown(frame.line, column: frame.column) ?? frame.line
        return file.name + ":" + String(line + 1)
    }

    private func debug(_ command: String) { browser.workCall("Debugger." + command, ["__target": model.frames.first?.target ?? ""]) }
    private func refreshWatch() {
        guard let frame = model.frames.first(where: { $0.id == model.frameID }) else { return }
        for watch in model.watch {
            browser.workCall("sources.evaluate", ["frame": frame.id, "expression": watch.name, "target": frame.target]) { value in
                let result = (value as? [String: Any])?["result"] as? [String: Any] ?? [:]
                if let i = model.watch.firstIndex(where: { $0.id == watch.id }) { model.watch[i].value = DevWorkbench.string(result) }
            }
        }
    }
    private func saveSnippet() {
        if let id = snippetID, let i = sourcePrefs.snippets.firstIndex(where: { $0.id == id }) {
            sourcePrefs.snippets[i].name = snippetName; sourcePrefs.snippets[i].text = snippet
        } else {
            let item = DevSnippet(name: snippetName, text: snippet)
            sourcePrefs.snippets.append(item); snippetID = item.id
        }
    }
}

private struct DevScopeRows: View {
    let browser: Browser
    let scope: DevScope
    let target: String
    var body: some View { ConsoleTree(browser: browser, value: ConsoleValue(json: ["ty": "object", "id": scope.objectID, "tg": target]), depth: 0).padding(8) }
}

extension Browser {
    func sourcesChooseWorkspace() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.message = "Connect the project folder served by this page. Save writes only inside this folder."
        guard let window = devWindow else { return }
        panel.beginSheetModal(for: window) { result in if result == .OK { self.workbench?.workspace = panel.url?.resolvingSymlinksInPath() } }
    }
    func sourcesSaveEditor() {
        guard let model = workbench, let web = model.sourceEditor, let source = model.source, model.pretty[source.url] == nil else { sourcesSave(); return }
        web.callAsyncJavaScript("return window.sourceText()", arguments: [:], in: nil, in: .page) { result in
            guard model.source?.id == source.id else { return }
            if case .success(let text as String) = result { model.sourceText = text; self.sourcesSave() }
            else { model.error = "The source editor could not provide its current text" }
        }
    }
    func sourcesSave() {
        guard let model = workbench, let file = model.source, let root = model.workspace, let url = URL(string: file.url) else { workbench?.error = "Connect a workspace folder before saving"; return }
        guard Address.isLocal(url) || url.isFileURL else { model.error = "Workspace writes are limited to a local development page"; return }
        let relative = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let target = root.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL
        guard !relative.isEmpty, target.path.hasPrefix(root.standardizedFileURL.path + "/"), FileManager.default.fileExists(atPath: target.path) else { model.error = "No matching file inside the workspace: " + relative; return }
        do {
            try model.sourceText.write(to: target, atomically: true, encoding: .utf8)
            model.changes.removeAll { $0.name == file.url }
            model.changes.append(DevProperty(name: file.url, value: model.sourceText))
            model.originalSourceText = model.sourceText
            model.sourceBuffers[file.url] = (model.sourceText, model.sourceText)
            toaster.pop("Saved " + target.lastPathComponent, mark: "checkmark")
        } catch { model.error = error.localizedDescription }
    }
    func stylesSave() {
        guard let model = workbench, let root = model.workspace else { workbench?.error = "Connect a workspace in Settings before saving style edits"; return }
        do {
            for (address, text) in model.styleEdits {
                guard let url = URL(string: address), Address.isLocal(url) || url.isFileURL else { continue }
                let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let target = root.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
                guard !path.isEmpty, target.path.hasPrefix(root.standardizedFileURL.path + "/"), FileManager.default.fileExists(atPath: target.path) else { throw CocoaError(.fileNoSuchFile) }
                try text.write(to: target, atomically: true, encoding: .utf8)
            }
            model.styleEdits = [:]
            toaster.pop("Saved style edits", mark: "checkmark")
        } catch { model.error = error.localizedDescription }
    }
}

/// Sources' search through every file the page loaded, as Chromium's: the
/// field with Aa and .*, the files with their matching lines numbered and
/// lit, a line picked opening its file on it, the count at the foot.
struct DevSourcesSearch: View {
    let browser: Browser
    @Bindable var model: DevWorkbench
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                HStack(spacing: 6) {
                    Symbol("magnifyingglass", size: 12).foregroundStyle(Palette.muted)
                    TextField("Search all sources", text: $model.sourcesQuery)
                        .textFieldStyle(.plain).font(.system(size: 13))
                        .focused($focused)
                        .onAppear { focus() }
                        .onSubmit { browser.sourcesSearch(model.sourcesQuery); focused = true }
                        .onExitCommand { model.sourcesFind = false }
                    if !model.sourcesQuery.isEmpty {
                        Button { model.sourcesQuery = ""; focused = true } label: { Symbol("xmark.circle.fill", size: 14).foregroundStyle(Palette.muted) }
                            .buttonStyle(.plain).keyTip("Clear")
                    }
                }
                .padding(.leading, 8)
                .padding(.trailing, 4) // design: as drawn, the clear button sits close to the capsule end
                .frame(height: ButtonSize.regular.height)
                .background(Palette.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(focused ? 0.75 : 0), lineWidth: 1.5)
                }
                toggle("Aa", "Match case", $model.sourcesCase)
                toggle(".*", "Use regular expression", $model.sourcesRegex)
                Button { model.sourcesFind = false } label: { Symbol("xmark", size: 12) }
                    .buttonStyle(.yab(.quiet, .regular, icon: .square)).keyTip("Close", keys: "esc")
            }
            .padding(6)
            Divider()
            ThreadScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.sourcesResults) { file in
                        fileRow(file)
                        if !model.sourcesShut.contains(file.url) {
                            ForEach(file.lines) { line in lineRow(file, line) }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            Divider()
            Text(model.sourcesNote)
                .font(.system(size: 12)).foregroundStyle(Palette.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .frame(height: 30)
        }
        .task(id: "\(model.sourcesQuery)|\(model.sourcesCase)|\(model.sourcesRegex)") {
            try? await Task.sleep(for: .milliseconds(model.sourcesQuery.count == 1 ? 400 : 150))
            guard !Task.isCancelled else { return }
            browser.sourcesSearch(model.sourcesQuery)
        }
        .onChange(of: model.sourcesFocus) { focus() }
    }

    private func fileRow(_ file: DevSearchFile) -> some View {
        let open = !model.sourcesShut.contains(file.url)
        return Button {
            if open { model.sourcesShut.insert(file.url) } else { model.sourcesShut.remove(file.url) }
        } label: {
            HStack(spacing: 6) {
                Symbol("chevron.right", size: 8).foregroundStyle(Palette.muted).rotationEffect(.degrees(open ? 90 : 0))
                Text(file.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                Text(file.path).font(.system(size: 12.5)).foregroundStyle(Palette.muted).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                Text(file.lines.count.formatted()).font(.system(size: 11.5)).foregroundStyle(Palette.muted).monospacedDigit()
                    .padding(.horizontal, 6)
                    .background(Palette.ink.opacity(0.06), in: Capsule())
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func lineRow(_ file: DevSearchFile, _ line: DevSearchLine) -> some View {
        Button { browser.sourceOpenFound(file.url, line: line.number) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(String(line.number + 1)).foregroundStyle(Palette.muted).frame(minWidth: 24, alignment: .trailing)
                Text(lit(line.text)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(DevMono.font(12))
            .padding(.leading, 24)
            .padding(.trailing, 8) // design: lines step in under their file's name, as Chromium's
            .frame(height: 18)
            .background(model.sourcesPicked == "\(file.url)#\(line.number)" ? Color.accentColor.opacity(0.12) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggle(_ title: String, _ tip: String, _ value: Binding<Bool>) -> some View {
        Button { value.wrappedValue.toggle() } label: { Text(title).font(DevMono.font(12, weight: .semibold)) }
            .buttonStyle(.yab(value.wrappedValue ? .secondary : .quiet, .regular, icon: .square))
            .keyTip(tip)
    }

    private func focus() {
        focused = true
        DispatchQueue.main.async {
            focused = true
            NSApp.sendAction(#selector(NSResponder.selectAll(_:)), to: nil, from: nil)
        }
    }

    /// Each match in the line, lit as Chromium's.
    private func lit(_ text: String) -> AttributedString {
        var out = AttributedString(text)
        let query = model.sourcesSearched
        guard !query.isEmpty else { return out }
        let options: NSRegularExpression.Options = model.sourcesCase ? [] : [.caseInsensitive]
        let pattern = model.sourcesRegex ? query : NSRegularExpression.escapedPattern(for: query)
        guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else { return out }
        for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).prefix(20) {
            guard let range = Range(match.range, in: text), !range.isEmpty,
                  let from = AttributedString.Index(range.lowerBound, within: out),
                  let to = AttributedString.Index(range.upperBound, within: out) else { continue }
            out[from..<to].backgroundColor = Color(nsColor: DevTreeLine.mark)
            out[from..<to].foregroundColor = Color(nsColor: DevTreeLine.markInk)
        }
        return out
    }
}
