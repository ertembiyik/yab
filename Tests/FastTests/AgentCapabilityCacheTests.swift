import Foundation
import Combine
import SyncKit
import Testing
@testable import Fast

@MainActor
@Suite(.serialized)
struct AgentCapabilityCacheTests {
    private func state() -> AgentCapabilityCache.State {
        .init(folder: false, boost: false, messages: false, mail: false,
              mailbox: false, mailAgents: false, recall: false, asking: "ask", knowing: false)
    }

    @Test func eachLiveInputInvalidatesImmediatelyAndSessionsStaySeparate() {
        let cache = AgentCapabilityCache()
        let initial = state()
        _ = cache.answer(session: "one", state: initial)
        _ = cache.answer(session: "one", state: initial)
        #expect(cache.builds == 1)
        let switches: [WritableKeyPath<AgentCapabilityCache.State, Bool>] = [
            \.folder, \.boost, \.messages, \.mail, \.mailbox, \.mailAgents, \.recall, \.knowing]
        for key in switches {
            var changed = initial; changed[keyPath: key] = true
            let before = cache.builds
            _ = cache.answer(session: "one", state: changed)
            #expect(cache.builds == before + 1)
            _ = cache.answer(session: "one", state: initial)
        }
        var changed = initial; changed.asking = "auto"
        #expect(cache.answer(session: "one", state: changed)["asking"] as? String == "auto")
        #expect(cache.answer(session: "two", state: initial)["asking"] as? String == "ask")
        #expect(cache.answer(session: "one", state: changed)["asking"] as? String == "auto")
    }

    @Test func grantRevocationAndMetadataChangesCannotReuseAnAnswer() {
        let cache = AgentCapabilityCache()
        var input = state()
        let grant = AssistantGrant(id: "fixture", name: "Fixture", client: "test", made: Date())
        input.assistant = .init(grant: grant, space: "Home", spaces: ["Home"], connected: false,
                                approvalDevices: [], tasks: false, started: [])
        _ = cache.answer(session: "one", state: input)
        input.assistant?.grant.paused = true
        var answer = cache.answer(session: "one", state: input)["assistant"] as? [String: Any]
        #expect(answer?["paused"] as? Bool == true)
        input.assistant?.approvalDevices = ["Phone"]
        input.assistant?.spaces = ["Work"]
        input.assistant?.started = ["new-task"]
        input.assistant?.tasks = true
        answer = cache.answer(session: "one", state: input)["assistant"] as? [String: Any]
        #expect(answer?["approvalDevices"] as? [String] == ["Phone"])
        #expect(answer?["spaces"] as? [String] == ["Work"])
        #expect(answer?["started"] as? [String] == ["new-task"])
        #expect(answer?["tasks"] as? Bool == true)
        input.assistant = nil
        #expect(cache.answer(session: "one", state: input)["assistant"] is NSNull)
    }

    @Test func largeSessionIndexAndCachedRepliesStayUnderFiveMilliseconds() throws {
        let agents = Agents()
        for n in 0..<20_000 {
            agents.register(.init(id: "large-\(n)", cli: "external", name: "Fixture", prompt: "", state: .done))
        }
        let cache = AgentCapabilityCache(), input = state()
        let start = ContinuousClock.now
        for _ in 0..<50 {
            #expect(agents.session("large-19999")?.id == "large-19999")
            _ = cache.answer(session: "large-19999", state: input)
        }
        let elapsed = start.duration(to: .now)
        #expect(elapsed < .milliseconds(5))
        #expect(cache.builds == 1)
    }

    @Test func startedTasksInvalidateOnAdmissionReassignmentAndCLIChange() {
        let agents = Agents()
        for n in 0..<2_000 {
            let session = Agents.Session(id: "started-\(n)", cli: "codex", name: "Fixture", prompt: "", state: .done)
            session.assistant = "one"
            agents.register(session)
        }
        #expect(agents.assistantStarted("one").count == 10)
        let newest = agents.session("started-1999")!
        #expect(agents.assistantStarted("one").first == newest.id)
        newest.assistant = "two"
        #expect(!agents.assistantStarted("one").contains(newest.id))
        #expect(agents.assistantStarted("two") == [newest.id])
        newest.cli = "external"
        #expect(agents.assistantStarted("two").isEmpty)
        newest.cli = "codex"
        #expect(agents.assistantStarted("two") == [newest.id])
        let start = ContinuousClock.now
        for _ in 0..<50 { _ = agents.assistantStarted("one") }
        #expect(start.duration(to: .now) < .milliseconds(5))
    }

    @Test func admissionInvalidatesAPrePublicationSnapshot() {
        let agents = Agents()
        let first = Agents.Session(id: "first", cli: "codex", name: "Fixture", prompt: "", state: .done)
        first.assistant = "one"
        agents.register(first)
        _ = agents.assistantStarted("one")
        var notifications = 0
        let observation = ObservedWrites({ _ = agents.sessions }, told: {
            notifications += 1
            _ = agents.assistantStarted("one")
        })
        let next = Agents.Session(id: "next", cli: "codex", name: "Fixture", prompt: "", state: .done)
        next.assistant = "one"
        agents.register(next)
        withExtendedLifetime(observation) {}
        #expect(notifications == 1)
        #expect(agents.assistantStarted("one").contains(next.id))
    }

    @Test func theRealHandlerObservesPreferenceAndSessionChanges() {
        let browser = Browser(windowID: UUID()), bench = Bench()
        let session = Agents.shared.scripted()
        let previousKnowing = session.knowing
        let previousMessages = browser.prefs.agentsMessages
        let previousAsking = browser.prefs.agentsAsking
        defer {
            session.knowing = previousKnowing
            browser.prefs.agentsMessages = previousMessages
            browser.prefs.agentsAsking = previousAsking
            browser.letGo()
        }
        func read() -> [String: Any] {
            var answer: [String: Any] = [:]
            bench.handleAgentCaps(.init(bench: bench, verb: "agent-caps", request: ["session": session.id],
                                        browser: browser, answer: { answer = $0 }))
            return answer
        }
        session.knowing = false
        browser.prefs.agentsMessages = false
        browser.prefs.agentsAsking = .ask
        #expect(read()["knowing"] as? Bool == false)
        session.knowing = true
        browser.prefs.agentsMessages = true
        browser.prefs.agentsAsking = .auto
        let answer = read()
        #expect(answer["knowing"] as? Bool == true)
        #expect(answer["messages"] as? Bool == true)
        #expect(answer["asking"] as? String == "auto")
        let history = (0..<20_000).map {
            Agents.Session(id: "handler-history-\($0)", cli: "external", name: "Fixture", prompt: "", state: .done)
        }
        Agents.shared.withSessionFixture(history + [session]) {
            // Time the real handler, with its caller last in a large profile,
            // rather than timing only a hand-built cached dictionary.
            for _ in 0..<50 {
                let start = ContinuousClock.now
                _ = read()
                #expect(start.duration(to: .now) < .milliseconds(5))
            }
        }
    }

    @Test func blockedJournalWorkDoesNotBlockMainAndOldResultsCannotReturn() async throws {
        let names = AssistantAnswererNames()
        let gate = DispatchSemaphore(value: 0)
        names.refresh { gate.wait(); return ["Revoked phone"] }
        defer { gate.signal() }
        // A read never joins the blocked worker, even on its first call.
        let start = ContinuousClock.now
        for _ in 0..<50 { #expect(names.names.isEmpty) }
        #expect(start.duration(to: .now) < .milliseconds(5))
        names.refresh { ["Current phone"] }
        for _ in 0..<100 where names.names.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(names.names == ["Current phone"])
        gate.signal()
        try await Task.sleep(for: .milliseconds(50))
        #expect(names.names == ["Current phone"])
    }
}
