import Foundation
import SwiftUI

struct DevSnippet: Codable, Identifiable {
    var id = UUID()
    var name: String
    var text: String
}

@MainActor @Observable final class DevSourcePrefs {
    static let shared = DevSourcePrefs()
    var snippets: [DevSnippet] {
        didSet { if let data = try? JSONEncoder().encode(snippets) { Store.settings.set(data, forKey: "dev.snippets") } }
    }
    var ignorePatterns: String { didSet { Store.settings.set(ignorePatterns, forKey: "dev.ignorePatterns") } }
    init() {
        snippets = Store.settings.data(forKey: "dev.snippets").flatMap { try? JSONDecoder().decode([DevSnippet].self, from: $0) } ?? []
        ignorePatterns = Store.settings.string(forKey: "dev.ignorePatterns") ?? ""
    }
}

enum DevSourceSymbols {
    static func symbols(_ source: String) -> [(name: String, line: Int)] {
        guard let regex = try? NSRegularExpression(pattern: #"^\s*(?:export\s+(?:default\s+)?)?(?:async\s+)?(?:function|class)\s+([A-Za-z_$][\w$]*)|^\s*(?:export\s+)?(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*(?:async\s*)?(?:\([^)]*\)|[A-Za-z_$][\w$]*)\s*=>"#) else { return [] }
        return source.components(separatedBy: "\n").enumerated().flatMap { line, text -> [(name: String, line: Int)] in
            regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match -> (name: String, line: Int)? in
                for i in 1..<match.numberOfRanges {
                    if let range = Range(match.range(at: i), in: text) { return (name: String(text[range]), line: line) }
                }
                return nil
            }
        }
    }
}

struct DevIgnoreSettings: View {
    let browser: Browser
    @Bindable private var prefs = DevSourcePrefs.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ignore list").font(.system(size: 15, weight: .medium))
            Text("One regular expression per line. Matching scripts are skipped while stepping.").foregroundStyle(Palette.muted)
            ThreadTextEditor(text: $prefs.ignorePatterns).font(DevMono.font(12)).frame(minHeight: 140)
            Button("Apply to inspected page") {
                let next = prefs.ignorePatterns.components(separatedBy: .newlines).filter { !$0.isEmpty }
                guard next.allSatisfy({ (try? NSRegularExpression(pattern: $0)) != nil }) else { browser.workbench?.error = "Invalid ignore-list regular expression"; return }
                for pattern in browser.workbench?.installedIgnorePatterns ?? [] { browser.workCall("Debugger.setShouldBlackboxURL", ["url": pattern, "shouldBlackbox": false, "caseSensitive": true, "isRegex": true]) }
                for pattern in next { browser.workCall("Debugger.setShouldBlackboxURL", ["url": pattern, "shouldBlackbox": true, "caseSensitive": true, "isRegex": true]) }
                browser.workbench?.installedIgnorePatterns = next
            }
        }
    }
}
