import Combine
import Foundation

extension Agents {
    /// Stop Yab's task, or release only this page from an attached client.
    @discardableResult
    func stop(on tab: Tab) -> Bool {
        guard let session = session(tab.worker), session.state.live else { return false }
        let feed = AgentFeed.shared
        feed.stopped(tab, by: session.id)
        if session.agent != .external { return stop(session.id) }

        session.stoppedTabs.insert(tab.id)
        tab.allowed.remove(session.id)
        tab.refused.insert(session.id)
        tab.declined.remove(session.id)
        if tab.approved?.session == session.id { tab.approved = nil }
        if tab.permit?.session == session.id { tab.permit = nil }
        if tab.sending?.permit.session == session.id { tab.sending = nil }
        tab.handoff = nil
        tab.handoffDetail = nil
        tab.choices = []
        tab.asker = nil
        Bench.shared.rest(tab)
        if tab.guest == session.id { tab.guest = nil }
        if tab.agent == session.id { tab.agent = nil }
        return true
    }

    func stoppedOnTab(_ tab: Tab, session id: String?) -> String? {
        guard session(id ?? Agents.script)?.stoppedTabs.contains(tab.id) == true else { return nil }
        return "The person stopped you on this tab."
    }
}
