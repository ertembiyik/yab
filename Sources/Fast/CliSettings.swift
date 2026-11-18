import Foundation

// `yab settings`: Yab's own settings, spaces and tabs from a terminal, for a
// script or an agent's shell that has no MCP connection. Each verb is the
// native_* MCP tool of the same name called once (Mcp.once), so its checks,
// its refusals and the person's yes are the tool's.
//
//     yab settings show theme
//     yab settings actions engine
//     yab settings apply site.set_engine '{"site":"github.com","value":"webKit"}'
//     yab settings undo

enum CliSettings {
    static let verbs: Set<String> = ["show", "actions", "apply", "undo", "operation"]

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct Call: Equatable {
        var tool: String
        var input: [String: AnyHashable]
        var json: Bool
    }

    /// The tool and its input, from the words after `settings`. `newID`
    /// names an apply that gave no --request-id.
    static func parse(_ args: [String], newID: () -> String = { UUID().uuidString }) throws -> Call {
        var plain: [String] = []
        var json = false
        var target: [String: AnyHashable]?
        var expected: String?, requestID: String?, seconds: Double?
        var cancel = false
        var i = 0
        func value(_ flag: String) throws -> String {
            i += 1
            guard i < args.count else { throw Failure(message: "\(flag) needs a value.") }
            return args[i]
        }
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--json": json = true
            case "--socket": i += 1
            case "--target":
                let parts = try value(arg).split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { throw Failure(message: "--target is KIND:ID, as settings show names it (space:ID, tab:ID).") }
                target = ["kind": parts[0], "id": parts[1]]
            case "--expect": expected = try value(arg)
            case "--request-id": requestID = try value(arg)
            case "--seconds":
                guard let s = Double(try value(arg)), (0...10).contains(s) else { throw Failure(message: "--seconds must be 0 to 10.") }
                seconds = s
            case "--cancel": cancel = true
            default:
                guard !arg.hasPrefix("-") || arg == "-" else { throw Failure(message: "Unknown option: \(arg).") }
                plain.append(arg)
            }
            i += 1
        }
        let verb = plain.first?.lowercased() ?? "show"
        let rest = Array(plain.dropFirst())
        let query = rest.joined(separator: " ")
        switch verb {
        case "show":
            var input: [String: AnyHashable] = [:]
            if !query.isEmpty { input["query"] = query }
            if let target { input["target"] = target }
            return Call(tool: "native_context", input: input, json: json)
        case "actions":
            return Call(tool: "native_actions", input: query.isEmpty ? [:] : ["query": query], json: json)
        case "apply":
            guard let action = rest.first, rest.count <= 2 else { throw Failure(message: "usage: \(AgentSetup.command) settings apply ACTION ['{\"key\":value}']") }
            let arguments: [String: AnyHashable]
            if rest.count == 2 {
                guard let object = (try? JSONSerialization.jsonObject(with: Data(rest[1].utf8))) as? [String: Any] else {
                    throw Failure(message: "Arguments must be one JSON object, as settings actions lists them.")
                }
                arguments = hashable(object)
            } else {
                arguments = [:]
            }
            var input: [String: AnyHashable] = ["action": action, "arguments": arguments,
                                                "target": target ?? ["kind": "application", "id": "app"],
                                                "requestId": requestID ?? newID()]
            if let expected { input["expectedVersion"] = expected }
            return Call(tool: "native_apply", input: input, json: json)
        case "undo":
            guard rest.count <= 1 else { throw Failure(message: "usage: \(AgentSetup.command) settings undo [CHANGE_ID]") }
            return Call(tool: "native_undo", input: rest.first.map { ["changeId": $0] } ?? [:], json: json)
        case "operation":
            guard rest.count == 1 else { throw Failure(message: "usage: \(AgentSetup.command) settings operation OPERATION_ID [--seconds N] [--cancel]") }
            var input: [String: AnyHashable] = ["operationId": rest[0]]
            if let seconds { input["seconds"] = seconds }
            if cancel { input["cancel"] = true }
            return Call(tool: "native_operation", input: input, json: json)
        default:
            throw Failure(message: "No settings verb \(verb). There are: \(verbs.sorted().joined(separator: ", ")).")
        }
    }

    private static func hashable(_ object: [String: Any]) -> [String: AnyHashable] {
        object.compactMapValues { value -> AnyHashable? in
            switch value {
            case let nested as [String: Any]: return hashable(nested)
            case let list as [Any]: return list.compactMap { ($0 as? [String: Any]).map(hashable) ?? ($0 as? AnyHashable) }
            default: return value as? AnyHashable
            }
        }
    }

    static func run(_ args: [String]) -> Never {
        if args.contains("-h") || args.contains("--help") { print(usage); exit(0) }
        let call: Call
        do {
            call = try parse(args)
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n" + usage + "\n").utf8))
            exit(2)
        }
        let result = Mcp.once(call.tool, call.input, args: args)
        let failed = result["isError"] as? Bool == true
        let text: String
        if call.json, let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), let encoded = String(data: data, encoding: .utf8) {
            text = encoded
        } else {
            let words = CliExec.words(result)
            let elsewhere = call.tool == "native_undo" && failed && words.contains("not_found")
            text = words + (elsewhere ? "\nUndo reaches only this session's changes: apply and undo in one exec script, or apply the change's before value." : "")
        }
        try? (call.json || !failed ? FileHandle.standardOutput : FileHandle.standardError).write(contentsOf: Data((text + "\n").utf8))
        exit(CliExec.status(result))
    }

    static var usage: String {
        let c = AgentSetup.command
        return """
        usage: \(c) settings [show] [WORDS] [--target KIND:ID] [--json]   current settings, spaces and tabs
               \(c) settings actions [WORDS] [--json]                    what can be changed, with argument schemas
               \(c) settings apply ACTION ['{"key":value}'] [--target KIND:ID] [--expect VERSION] [--request-id ID] [--json]
               \(c) settings undo [CHANGE_ID] [--json]
               \(c) settings operation OPERATION_ID [--seconds N] [--cancel] [--json]
        The target defaults to the app (application:app). Reuse --request-id when retrying an apply.
        Undo reaches changes made in the same session, such as one exec script or an agent's shell.
        exit: 0 done · 1 refused or failed · 2 usage · 3 needs you in Yab
        """
    }
}
