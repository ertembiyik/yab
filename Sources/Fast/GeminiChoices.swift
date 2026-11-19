import Foundation

/// Antigravity 1.4.7 shares one OS keyring login across its profiles.
/// Keep one account until Google exposes independent token profiles.
struct GeminiChoice: Identifiable, Equatable {
    enum Source: Equatable { case mac, space(UUID), another }
    let source: Source
    var email: String?
    var name = ""
    var photo: URL?
    var plan: String?
    var place: String?
    var id: String {
        switch source {
        case .mac: return "mac"
        case .space: return email?.lowercased() ?? ""
        case .another: return "another"
        }
    }
    static let another = GeminiChoice(source: .another)
}

@MainActor
@Observable final class GeminiChoices {
    static let shared = GeminiChoices()
    private(set) var rows: [GeminiChoice] = [.another]
    var chosen: String?
    var showing = false
    /// Shared Settings route for Models, initial Connect and Switch Account.
    func inSettings(_ page: SettingsPage) -> Bool { showing && page.top == .ai }

    @ObservationIgnored var switching = false
    private(set) var looking = false
    var pick: GeminiChoice { rows.first { $0.id == chosen } ?? rows.first ?? .another }

    func look(_ browser: Browser, switching: Bool, refreshIdentity: Bool = true) async {
        looking = true
        defer { looking = false }
        let account = GeminiAccount.shared
        if refreshIdentity {
            await account.look()
            await account.identify()
        }
        let google = await MailFound.shared.discover(browser)
        let local = account.signedIn == true ? account.identity : nil
        rows = Self.rows(local: local, google: google, excluding: switching ? [account.identity?.email].compactMap { $0 } : []).map { choice in
            var choice = choice
            if case .space(let id) = choice.source, browser.prefs.usesSpaces,
               browser.spaces.contains(where: \.ownSignIns) {
                choice.place = browser.spaces.first { $0.id == id }?.marked()
            }
            return choice
        }
        if !rows.contains(where: { $0.id == chosen }) { chosen = rows.first?.id }
    }

    nonisolated static func rows(local: GeminiIdentity?, google: [MailFound.Account], excluding: [String]) -> [GeminiChoice] {
        var seen = Set(excluding.map { $0.lowercased() })
        var rows: [GeminiChoice] = []
        if let local, seen.insert(local.email.lowercased()).inserted {
            rows.append(GeminiChoice(source: .mac, email: local.email, plan: local.plan))
        }
        for account in google where seen.insert(account.email.lowercased()).inserted {
            rows.append(GeminiChoice(source: .space(account.space), email: account.email,
                                     name: account.name, photo: account.photo))
        }
        return rows + [.another]
    }
}

/// Public identity printed by the CLI itself, never inferred from a choice.
struct GeminiIdentity: Codable, Equatable {
    var email: String
    var plan: String?

    nonisolated static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: #"\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\x1B\[[0-?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
    }

    nonisolated static func read(_ text: String) -> GeminiIdentity? {
        let plain = plain(text)
        // Only the signed-in CLI header. OAuth URLs and echoed login hints
        // must never become proof of which Google account answered.
        guard let header = plain.range(of: #"Antigravity CLI \d+\.\d+\.\d+"#, options: .regularExpression) else { return nil }
        let tail = String(plain[header.upperBound...])
        let lines = tail.components(separatedBy: .newlines).prefix(4)
        guard let email = lines.compactMap({ line -> String? in
            guard let range = line.range(of: #"[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, options: .regularExpression) else { return nil }
            return String(line[range])
        }).first else { return nil }
        var plan: String?
        if let range = tail.range(of: #"\((?:Antigravity|Google AI)[^()\r\n]{1,80}\)"#, options: .regularExpression) {
            plan = String(tail[range].dropFirst().dropLast())
        }
        return GeminiIdentity(email: email, plan: plan)
    }
}

enum GeminiQuota {
    /// The Gemini group only. Claude/GPT quotas in /usage aren't Yab plans.
    nonisolated static func read(_ output: String) -> PlanQuota? {
        guard let root = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
              root["status"] as? String == "SUCCESS",
              let command = root["command"] as? [String: Any], command["name"] as? String == "usage",
              let data = command["data"] as? [String: Any], let groups = data["groups"] as? [[String: Any]] else { return nil }
        var windows: [String: PlanWindow] = [:]
        for group in groups where (group["name"] as? String)?.lowercased().hasPrefix("gemini") == true {
            for bucket in group["buckets"] as? [[String: Any]] ?? [] {
                guard let remaining = bucket["remaining_fraction"] as? Double, remaining.isFinite,
                      (0...1).contains(remaining), let id = bucket["id"] as? String else { continue }
                let reset = (bucket["reset_time"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
                windows[id] = PlanWindow(used: 1 - remaining, resets: reset)
            }
        }
        guard let fullest = windows.max(by: { $0.value.used < $1.value.used }) else { return nil }
        return PlanQuota(out: fullest.value.used >= 1 ? fullest.value.resets : nil, used: fullest.value.used,
                         resets: fullest.value.resets, window: fullest.key, windows: windows)
    }
}
