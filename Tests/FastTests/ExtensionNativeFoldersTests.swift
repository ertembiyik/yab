import Foundation
import Testing
@testable import Fast

/// Another browser's manifest for the same host may name other extensions
/// or a program since removed: a later folder that lets this one in wins.
struct ExtensionNativeFoldersTests {
    let name = "com.example.host"
    let id = "abcdefghijklmnopabcdefghijklmnop"

    private func folder(allowing ids: [String], path: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let manifest: [String: Any] = ["name": name, "path": path, "type": "stdio",
                                       "allowed_origins": ids.map { "chrome-extension://\($0)/" }]
        try JSONSerialization.data(withJSONObject: manifest).write(to: url.appendingPathComponent(name + ".json"))
        return url
    }

    @Test func aLaterFolderThatAllowsTheExtensionWins() throws {
        let other = try folder(allowing: ["zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"], path: "/bin/cat")
        let removed = try folder(allowing: [id], path: "/nowhere/host")
        let right = try folder(allowing: [id], path: "/bin/cat")
        defer { [other, removed, right].forEach { try? FileManager.default.removeItem(at: $0) } }
        #expect(try ExtensionNative.host(name, for: id, in: [other, removed, right]).path == "/bin/cat")
    }

    @Test func refusalSaysWhetherAnyFileForbadeIt() throws {
        let other = try folder(allowing: ["zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"], path: "/bin/cat")
        defer { try? FileManager.default.removeItem(at: other) }
        #expect { try ExtensionNative.host(name, for: id, in: [other]) } throws: { $0.localizedDescription.contains("forbidden") }
        #expect { try ExtensionNative.host(name, for: id, in: []) } throws: { $0.localizedDescription.contains("not found") }
    }
}
