import AppKit
import Combine
import Testing
import WebKit
@testable import Fast

struct SelectionDirectTests {
    @MainActor private func fixture(_ html: String = "<textarea id=t>Original draft</textarea>", direct: Bool = true) async throws -> (Fast.Tab, SelectionCommands) {
        let tab = Fast.Tab(bench: true)
        tab.page.navigate(html: html, base: URL(string: "https://example.test/"))
        for _ in 0..<200 {
            if (try? await tab.page.fixtureExpression("document.getElementById('t') != null")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        _ = try await tab.page.fixtureExpression("const t=document.getElementById('t');t.focus();t.select();true")
        let commands = SelectionCommands()
        var snapshot: SelectionSnapshot?
        commands.peek(on: tab) { snapshot = $0 }
        for _ in 0..<200 where snapshot == nil { try await Task.sleep(for: .milliseconds(10)) }
        let snap = try #require(snapshot)
        var command = SelectionCommand(id: "direct-test", name: "Feedback style", prompt: "Rewrite", executor: "agent", custom: true)
        command.outputBehavior = direct ? .replace : .preview
        commands.show(command, on: tab, snapshot: snap, stage: .running, output: "")
        return (tab, commands)
    }

    @MainActor private func settled(_ commands: SelectionCommands) async throws {
        for _ in 0..<200 where commands.applying { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!commands.applying)
    }

    @Test @MainActor func directGenerationReplacesWithoutPublishingAPreview() async throws {
        let (tab, commands) = try await fixture()
        defer { commands.close(); tab.close() }
        var previewSeen = false
        let observer = ObservedWrites({ _ = commands.showsDockResult }, told: { if commands.showsDockResult { previewSeen = true } })
        defer { observer.cancel() }
        #expect(commands.showsDock)
        #expect(!commands.showsDockResult)
        commands.receive("Rewritten draft")
        try await settled(commands)
        #expect(commands.receipt == .replaced)
        #expect(!previewSeen)
        #expect(!commands.showsDockResult)
        #expect(try await tab.page.fixtureExpression("document.getElementById('t').value") as? String == "Rewritten draft")
        commands.undoReplacement()
        try await settled(commands)
        #expect(commands.receipt == .restored)
        #expect(try await tab.page.fixtureExpression("document.getElementById('t').value") as? String == "Original draft")
    }

    @Test @MainActor func showResultLeavesDraftUntouchedUntilReplace() async throws {
        let (tab, commands) = try await fixture(direct: false)
        defer { commands.close(); tab.close() }
        commands.receive("Previewed draft")
        #expect(commands.showsDockResult)
        #expect(commands.receipt == nil)
        #expect(try await tab.page.fixtureExpression("document.getElementById('t').value") as? String == "Original draft")
        commands.apply()
        try await settled(commands)
        #expect(commands.receipt == .replaced)
        #expect(try await tab.page.fixtureExpression("document.getElementById('t').value") as? String == "Previewed draft")
    }

    @Test @MainActor func cancelledCommandDiscardsPartialAndLateResults() async throws {
        let (tab, commands) = try await fixture()
        defer { commands.close(); tab.close() }
        commands.output = "A partial result"
        commands.cancelCommand()
        commands.receive("Late result")
        #expect(commands.receipt == .cancelled)
        #expect(commands.output.isEmpty)
        #expect(!commands.showsDockResult)
        #expect(try await tab.page.fixtureExpression("document.getElementById('t').value") as? String == "Original draft")
    }

    @Test @MainActor func undoRefusesLaterTypingInAnotherField() async throws {
        let (tab, commands) = try await fixture("<textarea id=t>Original draft</textarea><input id=other>")
        defer { commands.close(); tab.close() }
        commands.receive("Rewritten draft")
        try await settled(commands)
        _ = try await tab.page.fixtureExpression("const e=document.getElementById('other');e.focus();document.execCommand('insertText',false,'new typing');true")
        commands.undoReplacement()
        try await settled(commands)
        #expect(commands.stage == .failed)
        #expect(try await tab.page.fixtureExpression("document.getElementById('other').value") as? String == "new typing")
        #expect(try await tab.page.fixtureExpression("document.getElementById('t').value") as? String == "Rewritten draft")
    }

    @Test @MainActor func changedSelectionAndReadonlyFieldAreNotOverwritten() async throws {
        let (tab, commands) = try await fixture()
        defer { commands.close(); tab.close() }
        _ = try await tab.page.fixtureExpression("document.getElementById('t').value='User changed draft'")
        commands.receive("Late rewrite")
        try await settled(commands)
        #expect(commands.stage == .failed)
        #expect(try await tab.page.fixtureExpression("document.getElementById('t').value") as? String == "User changed draft")
        let web = await AgentKeysTests.page("<textarea id=t>Original draft</textarea>")
        _ = try await web.evaluateJavaScript("const e=document.getElementById('t');e.focus();e.select();true")
        _ = try await web.evaluateJavaScript(SelectionCommands.readScript, in: nil, contentWorld: .defaultClient)
        _ = try await web.evaluateJavaScript("document.getElementById('t').readOnly=true")
        #expect(try await web.evaluateJavaScript("window.__yabApplySelection('wrong')", in: nil, contentWorld: .defaultClient) as? String == "failed")
    }

    @Test @MainActor func aNewSelectionCannotTakeAnOlderCommandsResult() async throws {
        let (tab, commands) = try await fixture()
        defer { commands.close(); tab.close() }
        // A second selection has the same words but a different identity.
        _ = try await tab.page.fixtureExpression(SelectionCommands.readScript, world: .client)
        commands.receive("Wrong selection")
        try await settled(commands)
        #expect(commands.stage == .failed)
        #expect(try await tab.page.fixtureExpression("document.getElementById('t').value") as? String == "Original draft")
    }

    @Test @MainActor func richTextUndoPreservesMarkup() async throws {
        let web = await AgentKeysTests.page("<div id=t contenteditable=true><b>Hello</b> old world</div>")
        _ = try await web.evaluateJavaScript("const e=document.getElementById('t');e.focus();const r=document.createRange();r.setStart(e.lastChild,1);r.setEnd(e.lastChild,4);const s=getSelection();s.removeAllRanges();s.addRange(r);true")
        _ = try await web.evaluateJavaScript(SelectionCommands.readScript, in: nil, contentWorld: .defaultClient)
        #expect(try await web.evaluateJavaScript("window.__yabApplySelection('new')", in: nil, contentWorld: .defaultClient) as? String == "ok")
        #expect(try await web.evaluateJavaScript("window.__yabUndoSelection()", in: nil, contentWorld: .defaultClient) as? String == "ok")
        #expect(try await web.evaluateJavaScript("document.getElementById('t').innerHTML") as? String == "<b>Hello</b> old world")
    }

    @Test @MainActor func directReadOnlyAndUnchangedResultsDoNotApply() async throws {
        let (tab, commands) = try await fixture("<textarea id=t readonly>Original draft</textarea>")
        defer { commands.close(); tab.close() }
        commands.receive("A rewrite")
        #expect(commands.stage == .failed)
        #expect(try await tab.page.fixtureExpression("document.getElementById('t').value") as? String == "Original draft")
        let (sameTab, same) = try await fixture()
        defer { same.close(); sameTab.close() }
        same.receive("Original draft")
        #expect(same.noChange)
        #expect(same.receipt == nil)
        #expect(try await sameTab.page.fixtureExpression("document.getElementById('t').value") as? String == "Original draft")
    }

    @Test @MainActor func undoAfterUserTypedTextRestoresOnlyTheReplacement() async throws {
        let web = await AgentKeysTests.page("<textarea id=t></textarea>")
        _ = try await web.evaluateJavaScript("const e=document.getElementById('t');e.focus();document.execCommand('insertText',false,'Hello old world');e.setSelectionRange(6,9);true")
        _ = try await web.evaluateJavaScript(SelectionCommands.readScript, in: nil, contentWorld: .defaultClient)
        #expect(try await web.evaluateJavaScript("window.__yabApplySelection('new')", in: nil, contentWorld: .defaultClient) as? String == "ok")
        #expect(try await web.evaluateJavaScript("window.__yabUndoSelection()", in: nil, contentWorld: .defaultClient) as? String == "ok")
        #expect(try await web.evaluateJavaScript("document.getElementById('t').value") as? String == "Hello old world")
    }

    @Test @MainActor func outputChoiceRoundTripsWithExistingSavedFields() throws {
        var command = SelectionCommand(id: "existing", name: "Feedback", prompt: "{memory}", executor: "claude", custom: true,
                                       applyImmediately: true, result: "inPlace", model: "haiku")
        #expect(command.outputBehavior == .replace)
        command.outputBehavior = .preview
        let decoded = try JSONDecoder().decode(SelectionCommand.self, from: JSONEncoder().encode(command))
        #expect(decoded.outputBehavior == .preview)
        #expect(decoded.result == "auto")
        #expect(decoded.prompt == "{memory}")
        #expect(decoded.model == "haiku")
        for placement in ["draft", "foot", "copy", "beside"] {
            var legacy = command
            legacy.applyImmediately = true
            legacy.result = placement
            #expect(legacy.outputBehavior == .preview)
        }
    }

    @Test @MainActor func transformationsHaveASmallTextOnlyBrief() {
        let session = Agents.Session(id: "selection-brief-test", cli: "claude", name: "Selection command", prompt: "Rewrite", state: .starting)
        session.textOnly = true
        session.selectionTransform = true
        let brief = Agents.shared.brief(for: session)
        #expect(brief == Agents.selectionInstructions)
        #expect(brief.contains("no tools"))
        #expect(brief.count < Agents.instructions(textOnly: true, full: false, remembering: false).count)
    }
}
