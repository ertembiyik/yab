import Foundation
import Combine

/// Cursor is a connected AI plan. Its CLI owns authentication and billing.
@MainActor
enum CursorRunner {
    nonisolated static let connectionKey = "agents.cursor.connected"
    nonisolated static var connected: Bool { Store.settings.bool(forKey: connectionKey) }
    static var available: Bool { connected && Shell.cached?.cursor != nil }
    static let model = AgentModel(cli: "cursor", model: "auto", name: "Auto", about: "Your Cursor plan's default model.", efforts: [])
    static var chatClis: [String] { AgentSetupModel.clis }
    static var models: [AgentModel] {
        [model] + parseModels(AgentSetupModel.shared.cursorModels).filter { $0.model != "auto" }
    }
    /// Where Cursor shows its plan's usage; it doesn't tell its CLI.
    static let usage = URL(string: "https://cursor.com/dashboard?tab=usage")!
    private static var refreshed = Date.distantPast

    static func refresh(binary: String, env: [String: String], permit: ProviderLaunchPermit) async {
        guard permit.valid else { return }
        guard Date().timeIntervalSince(refreshed) > 300 else { return }
        refreshed = Date()
        let result = await Shell.timed(binary, ["models"], env: environment(env), permit: permit)
        guard permit.valid, result.code == 0, !parseModels(result.output).isEmpty else { return }
        AgentSetupModel.shared.keepCursorModels(result.output)
    }

    static func parseModels(_ text: String) -> [AgentModel] {
        let plain = text.replacingOccurrences(of: #"\x1B\[[0-9;?]*[A-Za-z]"#, with: "", options: .regularExpression)
        var seen: Set<String> = []
        return plain.components(separatedBy: .newlines).compactMap { line in
            let parts = line.components(separatedBy: " - ")
            guard parts.count >= 2 else { return nil }
            let id = parts[0].trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty, id.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:/-]*$"#, options: .regularExpression) != nil,
                  seen.insert(id).inserted else { return nil }
            let title = parts.dropFirst().joined(separator: " - ").replacingOccurrences(of: #" \((?:current|default)(?:, (?:current|default))*\)$"#, with: "", options: .regularExpression)
            // No line of its own: the list's head already says the plan.
            return AgentModel(cli: "cursor", model: id, name: title, about: "", efforts: [])
        }
    }

    typealias Identity = (signedIn: Bool, email: String?, plan: String?)
    private static var identities: [String: Identity] = [:]

    /// Passive reads reuse only the official CLI's verified public status.
    /// Guessed keychain names and old config metadata cannot prove a login.
    static func identity(env: [String: String]) -> Identity {
        identities[identityKey(env)] ?? (false, nil, nil)
    }

    private static func identityKey(_ env: [String: String]) -> String {
        URL(fileURLWithPath: env["HOME"] ?? AgentSetup.home.path).standardizedFileURL.path
    }

    static func identify(binary: String, env: [String: String], permit: ProviderLaunchPermit? = nil) async -> Identity {
        guard let permit = permit ?? ProviderConsent.shared.permit("cursor") ?? ProviderConsent.shared.connectionPermit("cursor"), permit.valid else { return (false, nil, nil) }
        let key = identityKey(env)
        let result = await Shell.timed(binary, ["status", "--format", "json"], env: environment(env), permit: permit)
        guard permit.valid else { return (false, nil, nil) }
        guard result.code == 0,
              let status = try? JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any],
              status["isAuthenticated"] as? Bool == true else {
            identities[key] = (false, nil, nil)
            return (false, nil, nil)
        }
        let who: Identity = (true, (status["userInfo"] as? [String: Any])?["email"] as? String, nil)
        identities[key] = who
        await refresh(binary: binary, env: env, permit: permit)
        guard permit.valid else { return (false, nil, nil) }
        return who
    }

    static func environment(_ base: [String: String]) -> [String: String] {
        let providerKeys = ["CLAUDE", "ANTHROPIC_", "CODEX_", "OPENAI_", "CURSOR_"]
        return base.filter { key, _ in !providerKeys.contains(where: key.hasPrefix) }
    }

    /// Only a Yab-owned chat workspace. Cursor's normal `mcp enable`
    /// command can then approve this exact server, without Run Everything
    /// or any tool allowlist changes. Existing edited config is refused.
    /// What a task's Cursor may do by itself, by its `.cursor/cli.json`:
    /// a text run nothing, a browser task only Yab's tools (its own shell,
    /// files and web denied, as Claude Code's and Codex's are until Mac
    /// access is given), a task with Mac access what Cursor's sandbox lets it.
    nonisolated static func policy(textOnly: Bool, full: Bool) -> [String: Any] {
        let natives = ["Shell(*)", "Read(**)", "Write(**)", "WebFetch(*)"]
        if textOnly { return ["permissions": ["allow": [String](), "deny": natives + ["Mcp(*:*)"]]] }
        if full { return ["permissions": ["allow": ["Mcp(\(Mcp.name):*)"], "deny": [String]()]] }
        return ["permissions": ["allow": ["Mcp(\(Mcp.name):*)"], "deny": natives]]
    }

    static func prepareTools(in room: URL, command: String, args: [String], textOnly: Bool = false, full: Bool = false) throws {
        let folder = room.appendingPathComponent(".cursor")
        let file = folder.appendingPathComponent("mcp.json")
        guard folder.resolvingSymlinksInPath().deletingLastPathComponent().path == room.resolvingSymlinksInPath().path else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSLocalizedDescriptionKey: "This chat's Cursor config points outside its workspace. It was left unchanged."])
        }
        let config: [String: Any] = ["mcpServers": textOnly ? [:] : [Mcp.name: ["command": command, "args": args, "env": [String: String]()]]]
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encode = { (config: [String: Any]) in
            try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        }
        /// `yabs`: what Yab itself may have written there before (a task
        /// given Mac access moves from one policy to the next); anything
        /// else is someone's edit, left alone, and the task doesn't start.
        func keep(_ config: [String: Any], at file: URL, yabs: [[String: Any]] = []) throws {
            guard file.resolvingSymlinksInPath().deletingLastPathComponent().path == folder.resolvingSymlinksInPath().path else {
                throw CocoaError(.fileWriteNoPermission)
            }
            let data = try encode(config)
            if FileManager.default.fileExists(atPath: file.path) {
                let there = try Data(contentsOf: file)
                if there == data { return }
                guard try yabs.contains(where: { try encode($0) == there }) else {
                    throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "This task's Cursor configuration was edited. Start a new task; the edited file was left unchanged."])
                }
            }
            try data.write(to: file, options: .atomic)
        }
        try keep(config, at: file)
        try keep(policy(textOnly: textOnly, full: full), at: folder.appendingPathComponent("cli.json"),
                 yabs: textOnly ? [] : [policy(textOnly: false, full: !full)])
    }

    /// One answer with no tools, for Yab's own helpers (PlanText): ACP in
    /// ask mode, as a text command runs, in a room of the helper's own with
    /// every tool denied. "" when it fails or takes past `limit`.
    static func once(binary: String, message: String, model: String? = nil, environment base: [String: String],
                     room: URL, limit: Double = 120, permit: ProviderLaunchPermit? = nil) async -> String {
        guard let permit, permit.valid else { return "" }
        do { try prepareTools(in: room, command: "", args: [], textOnly: true) } catch { return "" }
        var env = environment(base)
        env["CURSOR_CONFIG_DIR"] = room.appendingPathComponent(".cursor-user").path
        final class Heard { var answer = ""; var over = false; var buffer = Data() }
        let heard = Heard()
        let process = Process(), input = Pipe(), out = Pipe()
        var args = ["--sandbox", "enabled"]
        if let model, !model.isEmpty { args += ["--model", model] }
        Agents.throughShell(process, binary, args + ["--mode", "ask", "acp"])
        process.environment = env
        process.currentDirectoryURL = room
        process.standardInput = input
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let writer = input.fileHandleForWriting
        let server = CursorServer { try? writer.write(contentsOf: $0) }
        return await withCheckedContinuation { (done: CheckedContinuation<String, Never>) in
            let finish = { (words: String) in
                guard !heard.over else { return }
                heard.over = true
                out.fileHandleForReading.readabilityHandler = nil
                if process.isRunning { Shell.end(process, grace: 2) }
                done.resume(returning: words)
            }
            out.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard !heard.over else { return }
                        if data.isEmpty { finish(""); return }
                        heard.buffer.append(data)
                        while let newline = heard.buffer.firstIndex(of: 0x0A) {
                            let line = Data(heard.buffer[..<newline])
                            heard.buffer.removeSubrange(...newline)
                            guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
                            for event in server.heard(message) {
                                switch event {
                                case .delta(_, let words, let thinking): if !thinking { heard.answer += words }
                                case .permission(let id, _, _, _): server.reply(id, option: nil)
                                case .ended: finish(heard.answer)
                                case .failed: finish("")
                                default: break
                                }
                            }
                        }
                    }
                }
            }
            do { guard try permit.start(process) else { finish(""); return } } catch { finish(""); return }
            server.open(thread: nil, cwd: room.path, mcp: [], textOnly: true)
            server.say(message)
            DispatchQueue.main.asyncAfter(deadline: .now() + limit) {
                MainActor.assumeIsolated { finish("") }
            }
        }
    }

    static func unavailable(textOnly: Bool, unattended: Bool, fork: Bool) -> String? {
        if fork { return "Cursor can't carry this chat into a new one. Start a new chat on your Cursor plan." }
        return nil
    }
}
