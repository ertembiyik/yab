import SwiftUI

/// Settings' row for Zen and Firefox: their bookmarks and history brought
/// in right there, from a copy of each profile's places.sqlite, what came
/// said under the row. Passwords are their own export, a CSV, so the row
/// says where it is and Bring passwords in takes the file.
struct FirefoxBringer: View {
    var browser: Browser
    let anchor: String

    private enum Stage: Equatable {
        case counting
        case idle
        case bringing(String)
        case said(String)
    }
    @State private var stage: Stage = .counting
    @State private var sources: [Firefox.Source] = []

    /// Where Zen and Firefox keep their export, for the row and the panel
    /// that picks the file.
    static let passwordsHow = "The CSV from Zen or Firefox: about:logins, then ⋯ › Export Passwords…"

    var body: some View {
        SettingsRow(title, detail: detail) { button }
            .settingsAnchor(anchor)
            .task { find() }
    }

    private var title: String {
        sources.count == 1 ? "Bring in from \(sources[0].name)" : "Bring in from Zen or Firefox"
    }

    @ViewBuilder
    private var button: some View {
        switch stage {
        case .bringing:
            ProgressView().controlSize(.small)
        default:
            Menu("Bring In") {
                if sources.count > 1 {
                    Button("All Browsers") { bring(sources) }
                    Divider()
                }
                ForEach(sources) { source in
                    Button(source.name) { bring([source]) }
                }
            }
            .settingsButton()
            .fixedSize()
            .disabled(sources.isEmpty)
        }
    }

    private var passwords: String {
        "For passwords, export them in about:logins (⋯ › Export Passwords…) and choose Zen or Firefox under Bring passwords in."
    }

    private var detail: String {
        switch stage {
        case .counting, .idle:
            return "Bookmarks and history. " + passwords
        case .bringing(let name):
            return "Reading \(name)’s bookmarks and history…"
        case .said(let text):
            return text
        }
    }

    private func find() {
        DispatchQueue.global(qos: .userInitiated).async {
            let found = Firefox.installed()
            DispatchQueue.main.async {
                sources = found
                if stage == .counting { stage = .idle }
            }
        }
    }

    /// Each browser's bookmarks and then its history, in turn, then one line
    /// for all of it.
    private func bring(_ picked: [Firefox.Source]) {
        var queue = picked
        var marks = 0
        var places = 0
        func next() {
            guard !queue.isEmpty else {
                let names = picked.map(\.name).joined(separator: " and ")
                stage = .said(Self.line(bookmarks: marks, places: places, from: names))
                return
            }
            let source = queue.removeFirst()
            stage = .bringing(source.name)
            browser.takeBookmarks(from: source, quiet: true) { added in
                marks += added
                browser.takePlaces(from: source) { count in
                    places += count
                    next()
                }
            }
        }
        next()
    }

    /// "Brought in 120 bookmarks and 8,300 places from Zen."
    static func line(bookmarks: Int, places: Int, from name: String) -> String {
        let parts = [(bookmarks, "bookmark"), (places, "place")]
            .filter { $0.0 > 0 }
            .map { "\($0.0.formatted()) \($0.1)\($0.0 == 1 ? "" : "s")" }
        guard !parts.isEmpty else { return "Nothing new from \(name): it is all here already." }
        return "Brought in \(parts.joined(separator: " and ")) from \(name)."
    }
}
