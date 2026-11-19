import SwiftUI

struct DevComment: Identifiable {
    let id = UUID()
    let url: String
    let node: Int
    let selector: String
    let html: String
    var text: String
}

struct DevCommentsPane: View {
    let browser: Browser
    var model: DevWorkbench
    @State private var text = ""
    @State private var adding = false
    var body: some View {
        VStack(spacing: 0) {
            DevPanelBar {
                Button("Pick element") { browser.inspectElement() }
                Text("Comments (\(model.comments.count))").foregroundStyle(Palette.muted)
                Spacer(minLength: 0)
                Button("Copy for Agent") { browser.copyForAgent(report, "Comments copied") }.disabled(model.comments.isEmpty)
                Button("Ask in Chat") { if let tab = browser.toolsFront { browser.askInChat(about: tab, words: report) } }.disabled(model.comments.isEmpty)
                Button("Clear") { model.comments = [] }
            }
            Divider()
            HStack(spacing: 8) {
                TextField("Comment on the selected element", text: $text).textFieldStyle(.plain).onSubmit { add() }
                Button("Add comment") { add() }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.selectedNode == 0 || adding)
            }.font(.system(size: 12)).padding(8)
            Divider()
            ThreadScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if model.comments.isEmpty { Text("Pick an element in Elements, then describe the change for your agent.").foregroundStyle(Palette.muted) }
                    ForEach(model.comments) { comment in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Button(comment.selector) { browser.pickDevPane(.elements); browser.elementsSelect(comment.node) }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
                                Spacer(minLength: 0)
                                Button { model.comments.removeAll { $0.id == comment.id } } label: { Symbol("xmark", size: 10) }.buttonStyle(.yab(.quiet, .small)).keyTip("Delete comment")
                            }
                            Text(comment.text).textSelection(.enabled)
                            Text(comment.url).foregroundStyle(Palette.muted).lineLimit(1)
                            Divider()
                        }
                    }
                }.font(.system(size: 12)).padding(8)
            }
        }
    }
    private func add() {
        let note = text.trimmingCharacters(in: .whitespacesAndNewlines), node = model.selectedNode
        guard !note.isEmpty, node != 0, !adding else { return }
        adding = true
        browser.addDevComment(note) { added in if added { text = "" }; adding = false }
    }
    private var report: String {
        model.comments.enumerated().map { index, comment in "\(index + 1). \(comment.text)\nPage: \(comment.url)\nSelector: \(comment.selector)\n```html\n\(comment.html)\n```" }.joined(separator: "\n\n")
    }
}

@MainActor extension Browser {
    func addDevComment(_ note: String, done: @escaping (Bool) -> Void = { _ in }) {
        guard let model = workbench, model.selectedNode != 0, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { done(false); return }
        let node = model.selectedNode, url = toolsFront?.address?.absoluteString ?? ""
        workCall("elements.action", ["id": node, "action": "selector"]) { selector in
            guard let selector = selector as? String else { done(false); return }
            self.workCall("elements.html", ["id": node]) { result in
                guard let html = (result as? [String: Any])?["outerHTML"] as? String, self.toolsFront?.address?.absoluteString == url else { done(false); return }
                model.comments.append(DevComment(url: url, node: node, selector: selector, html: String(html.prefix(4_000)), text: note))
                done(true)
            }
        }
    }
}
