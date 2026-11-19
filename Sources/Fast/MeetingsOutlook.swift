import AppKit
import Foundation
import MailCore

// Meetings from Outlook and Microsoft 365 (docs/meetings-on-tabs.md,
// Outlook): an account connected for its calendar alone, read only
// (Calendars.Read), from Settings › Mail beside the Google accounts. Its
// sign-in is Microsoft's page in a tab, its answer caught on a port of
// this Mac as Google's is (MailSignIn, PKCE), the refresh token kept in
// the keychain and nowhere else. Every calendar it has is read through
// Microsoft Graph's calendarView, today's and tomorrow's, into the same
// list as Google's (Meetings); Teams links are calls already (Calls.key).
//
// Off until Yab has a Microsoft app: OutlookClient.shippedID, or
// YAB_MICROSOFT_CLIENT_ID for a build of one's own. Without one nothing
// here shows.

/// Yab's app at Microsoft: a public client (no secret), signing in to any
/// work, school or personal account.
struct OutlookClient: OAuthDoor {
    let id: String

    /// The Application (client) ID of Yab's app registration in Microsoft
    /// Entra, once it exists (docs/meetings-on-tabs.md, Outlook). Empty:
    /// Outlook stays off.
    static let shippedID = ""

    static var configured: OutlookClient? {
        let id = ProcessInfo.processInfo.environment["YAB_MICROSOFT_CLIENT_ID"] ?? shippedID
        return id.isEmpty ? nil : OutlookClient(id: id)
    }

    /// The calendars, read only, the address they belong to, and a refresh
    /// token to read them by.
    static let scopes = "offline_access openid email User.Read Calendars.Read"
    static let authority = "https://login.microsoftonline.com/common/oauth2/v2.0/"

    var loopback: String { "localhost" }
    var presenter: OAuthPresenter { .tab }

    func consent(redirect: String, challenge: String, state: String, hint: String?) -> URL {
        var parts = URLComponents(string: Self.authority + "authorize")!
        parts.queryItems = [
            URLQueryItem(name: "client_id", value: id),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "response_mode", value: "query"),
            URLQueryItem(name: "scope", value: Self.scopes),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "prompt", value: "select_account"),
        ] + (hint.map { [URLQueryItem(name: "login_hint", value: $0)] } ?? [])
        return parts.url!
    }

    func tokens(_ form: [String: String], session: URLSession) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: Self.authority + "token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var all = form
        all["client_id"] = id
        all["scope"] = Self.scopes
        request.httpBody = all.map { "\($0.key)=\(Self.escape($0.value))" }.joined(separator: "&").data(using: .utf8)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if status == 400 || status == 401, json["error"] as? String == "invalid_grant" { throw MailTrouble.signedOut }
        guard status == 200 else { throw MailTrouble.status(status) }
        return json
    }

    static func escape(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }
}

/// The Outlook accounts connected for their calendars, their sign-in, and
/// how they are read.
@MainActor
@Observable final class OutlookCalendars {
    static let shared = OutlookCalendars()

    private(set) var accounts: [String] = Store.settings.stringArray(forKey: "outlook.accounts") ?? []
    private(set) var connecting = false
    /// Microsoft stopped letting Yab in: said on its row, with Sign In Again.
    private(set) var signedOut: Set<String> = []

    @ObservationIgnored private var signIn: MailSignIn?
    @ObservationIgnored private var signInTab: Tab.ID?
    /// Access tokens, each until a minute before it runs out.
    @ObservationIgnored private var access: [String: (token: String, until: Date)] = [:]

    /// Its refresh token's keychain item, beside the mail's.
    static func item(_ account: String) -> String { "outlook:" + account.lowercased() }

    var available: Bool { OutlookClient.configured != nil }

    // MARK: - connecting

    /// Microsoft's page in a tab; the account comes in when it answers.
    /// Only ever from a press: never asked by itself.
    func connect(in browser: Browser, hint: String? = nil) {
        guard let client = OutlookClient.configured else { return }
        cancel(in: browser)
        let signIn = MailSignIn(client: client)
        self.signIn = signIn
        connecting = true
        do {
            let page = try signIn.start(hint: hint) { [weak self, weak browser] result in
                guard let self, self.signIn === signIn else { return }
                switch result {
                case .success(let grant): self.welcome(grant, browser: browser)
                case .failure: self.finish(browser, connected: nil)
                }
            }
            signInTab = browser.open(page, foreground: true).id
        } catch {
            finish(browser, connected: nil)
        }
    }

    func cancel(in browser: Browser?) {
        guard connecting else { return }
        signIn?.cancel()
        signIn = nil
        connecting = false
        closeTab(browser)
    }

    private func welcome(_ grant: MailGrant, browser: Browser?) {
        Task {
            guard let address = await Self.address(token: grant.access),
                  MailKeychain.save(grant.refresh, for: Self.item(address)) else {
                finish(browser, connected: nil)
                return
            }
            access[address] = (grant.access, Date().addingTimeInterval(50 * 60))
            signedOut.remove(address)
            if !accounts.contains(address) {
                accounts.append(address)
                Store.settings.set(accounts, forKey: "outlook.accounts")
            }
            finish(browser, connected: address)
            Meetings.shared.start()
        }
    }

    private func finish(_ browser: Browser?, connected: String?) {
        signIn?.cancel()
        signIn = nil
        connecting = false
        closeTab(browser)
        if connected == nil { browser?.announce("Outlook wasn’t connected", mark: "exclamationmark.triangle") }
    }

    private func closeTab(_ browser: Browser?) {
        guard let browser, let id = signInTab else { return }
        signInTab = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if let tab = browser.tabs.first(where: { $0.id == id }) { browser.close(tab) }
        }
    }

    /// Gone from here: its token forgotten, its meetings with it.
    /// Microsoft keeps no revoke for a public client's token; it lapses
    /// unused in 90 days, and the person can take Yab out at
    /// myapps.microsoft.com or account.live.com.
    func disconnect(_ account: String) {
        MailKeychain.forget(Self.item(account))
        access[account] = nil
        signedOut.remove(account)
        accounts.removeAll { $0 == account }
        Store.settings.set(accounts, forKey: "outlook.accounts")
        Meetings.shared.start()
    }

    /// The signed-in address: its mail, or the name it signs in with.
    static func address(token: String) async -> String? {
        var request = URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/me?$select=mail,userPrincipalName")!, timeoutInterval: 20)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await MailGmail.uncached.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let address = (json["mail"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? json["userPrincipalName"] as? String
        return address?.lowercased()
    }

    // MARK: - reading

    /// An access token for the account: kept, or traded for its refresh
    /// token, which Microsoft hands back new each time and is kept again.
    func token(_ account: String) async -> String? {
        if let kept = access[account], kept.until > Date().addingTimeInterval(60) { return kept.token }
        guard let client = OutlookClient.configured, let refresh = MailKeychain.token(for: Self.item(account)) else { return nil }
        do {
            let got = try await client.tokens(["grant_type": "refresh_token", "refresh_token": refresh], session: MailGmail.uncached)
            guard let token = got["access_token"] as? String else { return nil }
            if let next = got["refresh_token"] as? String, next != refresh { MailKeychain.save(next, for: Self.item(account)) }
            access[account] = (token, Date().addingTimeInterval((got["expires_in"] as? Double) ?? 3600))
            signedOut.remove(account)
            return token
        } catch MailTrouble.signedOut {
            signedOut.insert(account)
            return nil
        } catch {
            return nil
        }
    }

    /// The account's calendars, its default first.
    private func calendars(_ account: String, token: String) async -> [(id: String, name: String, primary: Bool)]? {
        guard let json = await Self.get("https://graph.microsoft.com/v1.0/me/calendars?$select=id,name,isDefaultCalendar&$top=100",
                                         token: token) else { return nil }
        let all = (json["value"] as? [[String: Any]] ?? []).compactMap { item -> (id: String, name: String, primary: Bool)? in
            guard let id = item["id"] as? String else { return nil }
            return (id, item["name"] as? String ?? "", item["isDefaultCalendar"] as? Bool == true)
        }
        return all.filter(\.primary) + all.filter { !$0.primary }
    }

    /// Today's and tomorrow's meetings, soonest first, a meeting in two
    /// calendars once; nil when Microsoft wouldn't answer this time.
    func read(_ account: String) async -> [Meeting]? {
        guard let token = await token(account), let calendars = await calendars(account, token: token) else { return nil }
        let from = Date().addingTimeInterval(-4 * 3600), to = Date().addingTimeInterval(26 * 3600)
        var found: [Meeting] = []
        var seen = Set<String>()
        for calendar in calendars {
            guard let events = await Self.view(calendar.id, from: from, to: to, token: token) else {
                if calendar.primary { return nil } else { continue }
            }
            for event in events {
                guard var meeting = Self.meeting(event, account: account), meeting.end > Date() else { continue }
                let uid = (event["iCalUId"] as? String ?? meeting.id) + "@\(meeting.start.timeIntervalSince1970)"
                guard seen.insert(uid).inserted else { continue }
                if !calendar.primary, !calendar.name.isEmpty { meeting.calendar = calendar.name }
                found.append(meeting)
            }
        }
        return found.sorted { $0.start < $1.start }
    }

    /// What is taken in the account's calendars between two moments; nil
    /// when Microsoft wouldn't answer.
    func busy(_ account: String, from: Date, to: Date) async -> [BusyTime]? {
        guard let token = await token(account), let calendars = await calendars(account, token: token) else { return nil }
        var found: [BusyTime] = []
        var seen = Set<String>()
        for calendar in calendars {
            guard let events = await Self.view(calendar.id, from: from, to: to, token: token) else {
                if calendar.primary { return nil } else { continue }
            }
            for time in events.compactMap(Self.taken) where time.uid.isEmpty || seen.insert(time.uid + "@\(time.start.timeIntervalSince1970)").inserted {
                // Another calendar's whole days are its holidays and birthdays.
                if !calendar.primary, time.end.timeIntervalSince(time.start) >= 86_400 { continue }
                found.append(time)
            }
        }
        return found.sorted { $0.start < $1.start }
    }

    /// One calendar's calendarView, every page, times in UTC.
    private static func view(_ calendar: String, from: Date, to: Date, token: String) async -> [[String: Any]]? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let id = calendar.addingPercentEncoding(withAllowedCharacters: allowed) ?? calendar
        let fields = "id,iCalUId,subject,start,end,isAllDay,isCancelled,showAs,responseStatus,onlineMeeting,onlineMeetingUrl,location,attendees,bodyPreview"
        var next: String? = "https://graph.microsoft.com/v1.0/me/calendars/\(id)/calendarView?startDateTime=\(stamp.string(from: from))"
            + "&endDateTime=\(stamp.string(from: to))&$select=\(fields)&$orderby=start/dateTime&$top=100"
        var events: [[String: Any]] = []
        while let link = next, events.count < 1_000 {
            guard let json = await get(link, token: token) else { return nil }
            events += json["value"] as? [[String: Any]] ?? []
            next = json["@odata.nextLink"] as? String
        }
        return events
    }

    private static func get(_ link: String, token: String) async -> [String: Any]? {
        guard let url = URL(string: link) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("outlook.timezone=\"UTC\"", forHTTPHeaderField: "Prefer")
        guard let (data, response) = try? await MailGmail.uncached.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: - an event as Graph has it

    /// A meeting at a time of day, not cancelled, not declined.
    nonisolated static func meeting(_ event: [String: Any], account: String) -> Meeting? {
        guard event["isCancelled"] as? Bool != true, event["isAllDay"] as? Bool != true,
              (event["responseStatus"] as? [String: Any])?["response"] as? String != "declined",
              let id = event["id"] as? String, let start = time(event["start"]), let end = time(event["end"]) else { return nil }
        let link = [(event["onlineMeeting"] as? [String: Any])?["joinUrl"] as? String, event["onlineMeetingUrl"] as? String,
                    (event["location"] as? [String: Any])?["displayName"] as? String, event["bodyPreview"] as? String]
            .lazy.compactMap { CallLink.find(in: $0) }.first
        let people = (event["attendees"] as? [[String: Any]] ?? [])
            .compactMap { (($0["emailAddress"] as? [String: Any])?["address"] as? String)?.lowercased() }
            .filter { $0 != account.lowercased() }
        return Meeting(id: "o:\(id)@\(start.timeIntervalSince1970)|outlook:\(account)", title: event["subject"] as? String ?? "",
                       start: start, end: end, link: link, people: people)
    }

    /// A stretch taken: not cancelled, not declined, not shown as free.
    nonisolated static func taken(_ event: [String: Any]) -> BusyTime? {
        guard event["isCancelled"] as? Bool != true, event["showAs"] as? String != "free",
              let start = time(event["start"]), let end = time(event["end"]) else { return nil }
        let response = (event["responseStatus"] as? [String: Any])?["response"] as? String
        if response == "declined" { return nil }
        return BusyTime(title: event["subject"] as? String ?? "", start: start, end: end, uid: event["iCalUId"] as? String ?? "",
                        maybe: response == "tentativelyAccepted" || response == "notResponded")
    }

    /// `{"dateTime": "2026-10-15T17:00:00.0000000", "timeZone": "UTC"}`,
    /// as asked for with Prefer: outlook.timezone="UTC".
    nonisolated static func time(_ value: Any?) -> Date? {
        guard let text = (value as? [String: Any])?["dateTime"] as? String, text.count >= 19 else { return nil }
        return utc.date(from: String(text.prefix(19)))
    }

    nonisolated(unsafe) private static let utc: DateFormatter = {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: "UTC")
        format.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return format
    }()

    nonisolated(unsafe) private static let stamp: ISO8601DateFormatter = {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime]
        return format
    }()
}
