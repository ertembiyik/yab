import Foundation
import SwiftUI

/// User limits are independent of author metadata. All AI entry points share
/// the same counter, so a service cannot evade a limit by starting a task.
@MainActor
@Observable final class BoostAI {
    static let shared = BoostAI()
    private(set) var change = 0
    private func key(_ id: String) -> String { "boosts.ai." + id + "." + String(ISO8601DateFormatter().string(from: Date()).prefix(10)) }
    func used(_ id: String) -> Int { Store.settings.integer(forKey: key(id)) }
    func limit(_ package: BoostPackage) -> Int {
        let value = Store.settings.object(forKey: "boosts.limit." + package.id) as? Int
        return min(package.plugin.dailyLimit, max(0, value ?? package.plugin.dailyLimit))
    }
    func setLimit(_ count: Int, for package: BoostPackage) {
        Store.settings.set(min(package.plugin.dailyLimit, max(0, count)), forKey: "boosts.limit." + package.id); change += 1
    }
    func charge(_ package: BoostPackage) throws {
        guard used(package.id) < limit(package) else { throw BoostPackage.Invalid("This plugin reached its daily AI limit of \(limit(package)). Change its limit in Settings > AI or wait until tomorrow.") }
        Store.settings.set(used(package.id) + 1, forKey: key(package.id)); change += 1
    }
    func planAllowed(_ id: String, revision: String) -> Bool { Store.settings.string(forKey: "boosts.plan." + id) == revision }
    func allowPlan(_ id: String, revision: String) { Store.settings.set(revision, forKey: "boosts.plan." + id); change += 1 }
    func revokePlan(_ id: String) { Store.settings.removeObject(forKey: "boosts.plan." + id); change += 1 }
}

struct BoostAISettings: View {
    private var boosts = Boosts.shared
    private var usage = BoostAI.shared
    var body: some View {
        let packages = boosts.records.compactMap { boosts.packages[$0.id] }.filter { $0.plugin.permissions.contains("yab:ask") || $0.plugin.permissions.contains("yab:task") || $0.files["commands.json"] != nil }
        if !packages.isEmpty {
            Section("Plugin AI") {
                ForEach(packages, id: \.id) { package in
                    VStack(alignment: .leading, spacing: 6) {
                        Stepper(value: Binding(get: { usage.limit(package) }, set: { usage.setLimit($0, for: package) }), in: 0...package.plugin.dailyLimit) {
                            Text(package.name + ": \(usage.used(package.id)) of \(usage.limit(package)) calls today")
                        }
                        if let revision = boosts.records.first(where: { $0.id == package.id })?.revision, usage.planAllowed(package.id, revision: revision) {
                            Button("Ask before using my plan again") { usage.revokePlan(package.id) }
                        }
                    }
                }
                Text("Includes background tasks. Set the limit to zero to pause AI for a plugin. Counts stay on this Mac.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// A deliberately bounded JSON Schema subset. Unsupported constructs fail
/// before starting a model call; invalid output never reaches plugin code.
enum BoostJSON {
    static func checkSchema(_ schema: [String: Any], depth: Int = 0) throws {
        guard depth <= 8, Set(schema.keys).isSubset(of: ["type", "properties", "required", "additionalProperties", "items", "enum", "description"]),
              let type = schema["type"] as? String, ["object", "array", "string", "boolean", "number", "integer", "null"].contains(type) else { throw BoostPackage.Invalid("Use a JSON schema with type, properties, required, items and enum; nesting is limited to eight levels.") }
        if let value = schema["properties"] {
            guard type == "object", let properties = value as? [String: [String: Any]], properties.count <= 50 else { throw BoostPackage.Invalid("Invalid schema properties.") }
            for child in properties.values { try checkSchema(child, depth: depth + 1) }
        }
        if let value = schema["required"] {
            guard let required = value as? [String], let properties = schema["properties"] as? [String: Any], Set(required).isSubset(of: Set(properties.keys)) else { throw BoostPackage.Invalid("Invalid required properties.") }
        }
        if let value = schema["additionalProperties"], !(value is Bool) { throw BoostPackage.Invalid("additionalProperties must be a boolean.") }
        if let value = schema["items"] {
            guard type == "array", let items = value as? [String: Any] else { throw BoostPackage.Invalid("Invalid array schema.") }
            try checkSchema(items, depth: depth + 1)
        }
        if let value = schema["enum"], !(value is [Any]) { throw BoostPackage.Invalid("enum must be an array.") }
    }
    static func answer(_ text: String, schema: [String: Any]?) throws -> Any {
        guard let schema else { return text }
        guard text.utf8.count <= 128_000, let value = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) else { throw BoostPackage.Invalid("The model did not return the requested JSON.") }
        try validate(value, schema: schema)
        return value
    }
    static func validate(_ value: Any, schema: [String: Any]) throws {
        let type = schema["type"] as? String ?? ""
        if type == "null" { guard value is NSNull else { throw BoostPackage.Invalid("Model output must be null.") }; return }
        try BoostPlugin.Tool(name: "result", description: "", parameters: ["value": type], acts: nil).validate(["value": value])
        if let choices = schema["enum"] as? [Any], !choices.contains(where: { BoostScript.json($0) == BoostScript.json(value) }) { throw BoostPackage.Invalid("Model output is outside the schema's enum.") }
        if let object = value as? [String: Any], type == "object" {
            let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
            let required = schema["required"] as? [String] ?? []
            guard required.allSatisfy({ object[$0] != nil }), schema["additionalProperties"] as? Bool != false || Set(object.keys).isSubset(of: Set(properties.keys)) else { throw BoostPackage.Invalid("Model output has missing or unknown properties.") }
            for (key, child) in properties { if let value = object[key] { try validate(value, schema: child) } }
        }
        if let array = value as? [Any], let items = schema["items"] as? [String: Any], type == "array" { for value in array { try validate(value, schema: items) } }
    }
}
