import SwiftUI

// Settings › Developers: what a developer reaches for, in one place.
// Developer Mode for the servers on this Mac (whether a local page offers
// it, the servers chosen for, where the tools dock, what the rulers count
// in); the yab command on the PATH; and Yab's skill and MCP tools in Claude
// Code and Codex, a piece at a time, with the config any other MCP client
// takes. AI's Connect still puts all of it in at once; this is where each
// piece is seen and put right, without a plan signed in, for the person who
// uses Yab from a terminal and never connects an agent.
//
// Quiet when all is well: a piece in place shows where it is and nothing
// else. Words come only with something to do, and one button that does it.

struct DevelopersPage: View {
    var browser: Browser
    @Bindable var prefs: Preferences
    private var setup = AgentSetupModel.shared
    private var inspectorKey = Keymap.shared.slot(.inspector)
    private var measureKey = Keymap.shared.slot(.measure)
    @State private var pieces = AgentSetup.pieces()
    @State private var servers = DevSites.servers
    @State private var working: String?
    @State private var rems = Measure.rems

    var body: some View {
        PageHero(page: .developers)
        Section("Developer Mode") {
            SettingsRow("Offer on local pages", detail: "Offer Developer Mode for localhost, .test and 127.0.0.1 sites.") {
                Toggle(SettingsWords.text("Offer on local pages"), isOn: $prefs.offerDevMode)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .settingsAnchor("dev-offer")
            SettingsRow("Developer Tools open", detail: inspectorKey.keys.map { "Default dock position for Developer Tools (\($0.settingsHint))." } ?? "Default dock position for Developer Tools.") {
                GlassTrack(title: "Developer Tools open", options: [("Bottom", DevSide.bottom), ("Right", DevSide.right), ("Left", DevSide.left)],
                           selection: $prefs.devSide)
                    .frame(width: 200)
            }
            .settingsAnchor("dev-side")
            SettingsRow("Measure in", detail: measureKey.keys.map { "Ruler units for Measure (\($0.settingsHint))." } ?? "Ruler units for Measure.") {
                GlassTrack(title: "Measure in", options: [("Pixels", false), ("Rems", true)], selection: $rems)
                    .frame(width: 160)
            }
            .settingsAnchor("dev-measure")
            if servers.isEmpty {
                SettingsNote("Servers with Developer Mode enabled.")
            }
        }
        if !servers.isEmpty {
            Section(SettingsWords.text("Servers")) {
                ForEach(servers, id: \.name) { server in
                    SettingsRow(server.name) {
                        Toggle(server.name, isOn: Binding(get: { server.on }, set: { Browser.setDevMode(server: server.name, $0) }))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                    .contentShape(Rectangle())
                    .contextMenu {
                        Button(SettingsWords.text("Forget")) { Browser.forgetDevMode(server: server.name) }
                    }
                }
                SettingsNote("Right-click a server to reset its Developer Mode preference.")
            }
            .settingsAnchor("dev-servers")
        }
        // JSON comes from any site, not only this Mac's servers: a group of
        // its own (JSONView.swift).
        Section("JSON") {
            SettingsRow("Show JSON as", detail: prefs.jsonView.detail) {
                GlassTrack(title: "Show JSON as", options: JSONShow.allCases.map { (title: $0.title, value: $0) }, selection: $prefs.jsonView)
                    .frame(width: 240)
            }
            .settingsAnchor("dev-json")
            if let name = JSONView.yieldsTo {
                SettingsNote("\(name) shows these pages. Turn it off in Extensions to use Yab\u{2019}s.")
            }
        }
        Section("Command Line") {
            command
                .settingsAnchor("dev-command")
            SettingsNote("In Terminal, \(AgentSetup.command) \u{201C}…\u{201D} hands Yab a task, and \(AgentSetup.command) guide says what else it does.")
        }
        Section("Agent Tools") {
            // The same setting as the switch at the top of AI › Agents, so the
            // same name, and it says the rest of what it stops.
            SettingsRow("Let agents use Yab", detail: prefs.bench
                        ? "Claude Code and others drive Yab through \(AgentSetup.command) and MCP. Off also stops Yab\u{2019}s own tasks and routines."
                        : "Off. Claude Code and others can\u{2019}t drive Yab, and Yab\u{2019}s own tasks and routines are stopped.") {
                Toggle(SettingsWords.text("Let agents use Yab"), isOn: $prefs.bench)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .settingsAnchor("dev-agents-allowed")
            agent("claude", pieces.claude)
                .settingsAnchor("dev-claude")
            agent("codex", pieces.codex)
                .settingsAnchor("dev-codex")
            SettingsRow("Other MCP clients", detail: "Paste this configuration into your MCP client's settings.") {
                Button("Copy Config") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(AgentSetup.mcpConfig, forType: .string)
                    SettingsWindow.shared.toaster.pop("MCP config copied", mark: "doc.on.doc", feedback: .success)
                }
                .settingsButton()
            }
            .settingsAnchor("dev-mcp")
            SettingsNote(AgentSetup.mayInstall
                         ? "Yab\u{2019}s skill and its MCP tools, nothing else; right-click to remove them. Signing in to a plan is on AI › Agents."
                         : AgentSetup.notInstalled)
        }
        .task { await look() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await look() }
        }
        // `yab setup` or `yab remove` in a terminal, while this is open.
        .onReceive(DistributedNotificationCenter.default().publisher(for: Cli.setUp, object: Bundle.main.bundleIdentifier as NSString?)) { _ in
            Task { await look() }
        }
        .onReceive(NotificationCenter.default.publisher(for: DevSites.changed)) { _ in
            servers = DevSites.servers
        }
        .onChange(of: rems) { _, on in
            Measure.rems = on
            // The rulers up now count in it at once.
            for tab in BrowserWindows.shared.browsers.flatMap(\.everyTab) where tab.measuring { tab.pushMeasure() }
        }
    }

    // MARK: the command

    @ViewBuilder private var command: some View {
        let title = "The \(AgentSetup.command) command"
        let path = tilde(AgentSetup.shim)
        let folder = tilde(AgentSetup.shim.deletingLastPathComponent())
        switch pieces.command {
        case .missing:
            SettingsRow(title, detail: "Use Yab from Terminal and agent tools.") {
                if AgentSetup.mayInstall {
                    Button("Install") { run("command") { AgentSetup.installCommand() ?? AgentSetup.addPathLine($0) } }
                        .settingsButton(.primary)
                        .disabled(working != nil)
                }
            }
        case .foreign:
            Placed(title: title, path: path, note: "Someone else\u{2019}s file is there; Yab leaves it be.") { EmptyView() }
        case .otherCopy:
            Placed(title: title, path: path, note: "Runs another copy of Yab.") {
                Button("Use This Copy") { run("command") { AgentSetup.installCommand() ?? AgentSetup.addPathLine($0) } }
                    .settingsButton(.primary)
                    .disabled(working != nil || !AgentSetup.mayInstall)
            }
            .contextMenu { remove("command") }
        case .ours:
            if offPath {
                Placed(title: title, path: path, note: "\(folder) isn\u{2019}t on your PATH yet.") {
                    Button("Add to PATH") { run("path") { AgentSetup.addPathLine($0) } }
                        .settingsButton(.primary)
                        .disabled(working != nil)
                }
                .contextMenu { remove("command") }
            } else {
                Placed(title: title, path: path) { EmptyView() }
                    .contextMenu { remove("command") }
            }
        }
    }

    /// A login shell that wouldn't find the command, and no line of ours
    /// that puts it there for the next one.
    private var offPath: Bool {
        guard let found = setup.found, !found.late else { return false }
        return !AgentSetup.onPath(found.env["PATH"]) && !pieces.pathLine
    }

    // MARK: an agent

    @ViewBuilder private func agent(_ cli: String, _ state: AgentSetup.Pieces.Agent) -> some View {
        // The tool's own name: this page is about its skill and tools.
        let name = AgentSetupModel.tool(cli)
        let path = tilde(cli == "codex" ? AgentSetup.codexConfig : AgentSetup.claudeSkill.deletingLastPathComponent())
        let add = { run(cli) { found in
            if cli == "codex" { return found.codex == nil ? "Codex isn\u{2019}t installed." : AgentSetup.addCodex() }
            guard let binary = found.claude else { return "Claude Code isn't installed." }
            let localSetup = LocalAgentSetupPermit.userSetupClaude(binary: binary)
            defer { localSetup.revoke() }
            return await AgentSetup.addClaude(found, localSetup: localSetup)
        } }
        switch state {
        case .ours:
            Placed(title: name, path: path) { EmptyView() }
                .contextMenu { remove(cli) }
        case .stale:
            Placed(title: name, path: path, note: "Added by an older Yab.") {
                Button("Update") { add() }.settingsButton(.primary).disabled(working != nil)
            }
            .contextMenu { remove(cli) }
        case .otherCopy:
            Placed(title: name, path: path, note: "Set up for another copy of Yab.") {
                Button("Use This Copy") { add() }.settingsButton(.primary).disabled(working != nil || !AgentSetup.mayInstall)
            }
            .contextMenu { remove(cli) }
        case .missing:
            if setup.ready, !setup.installed(cli) {
                SettingsRow(name, detail: "Not on this Mac.") { EmptyView() }
            } else {
                SettingsRow(name, detail: "Yab's skill and tools are not installed.") {
                    if AgentSetup.mayInstall {
                        Button(SettingsWords.text("Add")) { add() }.settingsButton(.primary).disabled(working != nil || !setup.ready)
                    }
                }
            }
        }
    }

    /// Where a piece is, from the home it was put in: `~/.local/bin/yab`.
    private func tilde(_ url: URL) -> String {
        let home = AgentSetup.home.path
        return url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path
    }

    // MARK: doing

    /// Takes back only what Yab put there, marked as its own.
    @ViewBuilder private func remove(_ piece: String) -> some View {
        Button("Show in Finder") {
            let url: URL = switch piece {
            case "claude": AgentSetup.claudeSkill.deletingLastPathComponent()
            case "codex": AgentSetup.codexConfig
            default: AgentSetup.shim
            }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        Button(SettingsWords.text("Remove")) {
            run(piece) { found in
                await AgentSetup.remove(found, only: [piece])
                return nil
            }
        }
    }

    /// One piece put in, put right or taken out, then everything read again;
    /// what went wrong said in the corner.
    private func run(_ piece: String, _ work: @escaping @MainActor (Shell.Found) async -> String?) {
        working = piece
        Task {
            let found = await Shell.find()
            let trouble = await work(found)
            working = nil
            await look()
            if let trouble { SettingsWindow.shared.toaster.pop(trouble, mark: "exclamationmark.triangle") }
        }
    }

    private func look() async {
        pieces = await AgentSetup.readPieces()
        servers = DevSites.servers
        rems = Measure.rems
        if setup.found == nil { await setup.look() } else { setup.reread() }
    }
}

/// A piece in place: its name, where it is, and, when it wants something
/// done, what, in a word of warning over the button that does it.
private struct Placed<Trailing: View>: View {
    let title: String
    let path: String
    var note = ""
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) { // design: SettingsRow's own gap under a title
                Text(title)
                Text(path)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                if !note.isEmpty {
                    Text(note)
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
        .contentShape(Rectangle())
    }
}
