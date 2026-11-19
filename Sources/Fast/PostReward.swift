import AppKit
import Combine
import CoreImage
import Foundation

// Post About Yab (Settings › Invite Friends, docs/invites.md): a post on X
// about Yab wins one of three icons, a surprise until it opens. Yab writes
// the post in English from what this Mac knows (where you came from and
// when, the plan your agent runs on, what it did for you), you change it or
// ask for another, and you post it yourself in an X tab. Yab takes the
// post's address when X shows it and sends only that to the site, which
// looks at the post through X's public oEmbed for a day (fast-web,
// lib/invite-posts.ts). Still up a day later: one of the icons you don't
// have yet. One post a week counts, three in all.
@MainActor
@Observable final class PostReward {
    static let shared = PostReward()

    /// What a post wins, one at a time, in no order the person sees.
    static let icons: [AppIconStyle] = [.chrome, .amber, .redEnamel]
    /// Where a post's own address is: x.com or twitter.com, /handle/status/digits.
    nonisolated static func isPost(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased(), ["x.com", "twitter.com", "www.x.com", "mobile.twitter.com"].contains(host) else { return false }
        return url.path().range(of: #"^/[A-Za-z0-9_]{1,15}/status/\d+/?$"#, options: .regularExpression) != nil
    }

    /// One post, as the site last said.
    struct Post: Codable, Equatable {
        var url: String
        /// live, gone or won
        var state: String
        var posted: Date
        var reward: String?
        /// When a live one opens, a day after it was sent.
        var opens: Date?
    }

    private(set) var posts: [Post]
    /// When the next post counts, while the last win is under a week old.
    private(set) var after: Date?
    /// Kept while Settings closes and opens again, as the invite message is.
    var draft: String { didSet { Store.settings.set(draft, forKey: "invite.post.draft") } }
    private(set) var writing = false
    /// An X tab is open with the draft, and Yab waits for the post's address.
    private(set) var waiting = false
    /// Waiting two minutes and more without seeing the post.
    private(set) var waitedLong = false
    @ObservationIgnored private var waitTimer: Timer?
    private(set) var sending = false
    private(set) var problem: String?
    /// The one that just opened, for its tile's reveal.
    var fresh: AppIconStyle?

    @ObservationIgnored private var step = 0
    @ObservationIgnored private var watch: AnyCancellable?
    @ObservationIgnored private var openers: [String]?

    private init() {
        posts = Self.decode(Store.settings.data(forKey: "invite.posts")) ?? []
        draft = Store.settings.string(forKey: "invite.post.draft") ?? ""
        after = Store.settings.object(forKey: "invite.postAfter") as? Date
        // Someone wearing one of these from before they were won: theirs to keep.
        if Store.settings.string(forKey: Self.keptKey) == nil,
           let worn = Store.settings.string(forKey: AppIconStyle.key),
           Self.icons.map(\.rawValue).contains(worn) {
            Store.settings.set(worn, forKey: Self.keptKey)
        }
    }

    private static let keptKey = "invite.post.kept"

    // MARK: what is won

    var won: [AppIconStyle] {
        var out: [AppIconStyle] = []
        for post in posts.reversed() {
            if let style = post.reward.flatMap(AppIconStyle.init(rawValue:)), Self.icons.contains(style), !out.contains(style) { out.append(style) }
        }
        return out
    }

    func owns(_ style: AppIconStyle) -> Bool {
        won.contains(style) || Store.settings.string(forKey: Self.keptKey) == style.rawValue
    }

    var live: Post? { posts.first { $0.state == "live" } }
    var allWon: Bool { Self.icons.allSatisfy(owns) }
    var count: Int { Self.icons.filter(owns).count }
    /// The latest post went before its day was up.
    var lastGone: Bool { posts.first?.state == "gone" }
    var canPost: Bool { live == nil && !allWon && (after.map { $0 <= Date() } ?? true) }

    /// What the surprise or a locked one takes, under its name in App Icon.
    var takes: String? {
        if allWon { return nil }
        if let opens = live?.opens { return "Opens \(Self.words(until: opens))." }
        return "One of three, for a post on X."
    }

    /// "in 15 h", "in 40 min", "soon".
    static func words(until date: Date, now: Date = Date()) -> String {
        let minutes = Int(date.timeIntervalSince(now) / 60)
        if minutes <= 1 { return "soon" }
        if minutes < 60 { return "in \(minutes) min" }
        return "in \(Int((Double(minutes) / 60).rounded())) h"
    }

    /// What the site said in status: the posts and when the next counts.
    func update(_ answer: [String: Any]) {
        guard let list = answer["posts"] as? [[String: Any]] else { return }
        let had = Set(won)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = { (value: Any?) -> Date? in (value as? String).flatMap { iso.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) } }
        posts = list.compactMap { item in
            guard let url = item["url"] as? String, let state = item["state"] as? String, let posted = date(item["posted"]) else { return nil }
            return Post(url: url, state: state, posted: posted, reward: item["reward"] as? String, opens: date(item["opens"]))
        }
        after = date(answer["postAfter"])
        Store.settings.set(try? Self.encoder.encode(posts), forKey: "invite.posts")
        Store.settings.set(after, forKey: "invite.postAfter")
        if let new = won.first(where: { !had.contains($0) }) { opened(new) }
    }

    private func opened(_ style: AppIconStyle) {
        fresh = style
        if let browser = BrowserWindows.shared.activeBrowser {
            browser.announce("\(style.title) is yours", mark: "brand.blobplus")
        }
    }

    // MARK: the draft

    /// A post, written: by the agent you connected when there is one, else
    /// from the same facts in a few plain shapes. Another asks for a new angle.
    func write(another: Bool = false) async {
        guard !writing else { return }
        if another { step += 1 }
        writing = true
        problem = nil
        defer { writing = false }
        guard let link = await Invites.shared.link(best: false) else {
            problem = "Couldn't reach yetanotherbrowser.com. Check the connection and try again."
            return
        }
        if openers == nil { openers = await Self.fetchOpeners() }
        let facts = PostFacts.now()
        guard let installation = await Invites.installation else {
            problem = "Couldn't reach yetanotherbrowser.com. Check the connection and try again."
            return
        }
        let angle = PostFacts.angle(seed: installation, step: step, facts: facts)
        let written = await PostWriter.write(facts: facts, angle: angle, link: link.absoluteString, avoid: openers ?? [])
        draft = written ?? PostFacts.template(facts, angle: angle, link: link.absoluteString)
    }

    private static func fetchOpeners() async -> [String] {
        guard let installation = await Invites.installation else { return [] }
        return (await Invites.ask("api/invites/openers", ["install": installation])?["openers"] as? [String]) ?? []
    }

    // MARK: posting

    /// The draft in an X tab, where you post it; its address is taken when X shows the post.
    func post() {
        guard let browser = BrowserWindows.shared.activeBrowser ?? Links.browser,
              var parts = URLComponents(string: "https://x.com/intent/post") else { return }
        parts.queryItems = [URLQueryItem(name: "text", value: draft)]
        guard let url = parts.url else { return }
        let tab = browser.open(url, foreground: true)
        if let window = BrowserWindows.shared.window(for: browser) {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        waiting = true
        waitedLong = false
        problem = nil
        fresh = nil
        waitTimer?.invalidate()
        waitTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { if self?.waiting == true { self?.waitedLong = true } }
        }
        watch = tab.changes(\.address)
            .compactMap { $0 }
            .first(where: Self.isPost)
            .sink { [weak self] address in
                guard let self else { return }
                Task { await self.send(address.absoluteString) }
            }
    }

    /// The post's address, typed or pasted when Yab didn't see it.
    func send(_ address: String) async {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: address), Self.isPost(url) else {
            problem = "That isn't a link to a post on X."
            return
        }
        sending = true
        defer { sending = false }
        guard let installation = await Invites.installation else {
            problem = "Couldn't reach yetanotherbrowser.com. Check the connection and try again."
            return
        }
        let answer = await Invites.ask("api/invites/post", ["install": installation, "url": address], accepting: [200, 422])
        guard let answer else {
            problem = "Couldn't reach yetanotherbrowser.com. Check the connection and try again."
            return
        }
        if let error = answer["error"] as? String {
            problem = error
            return
        }
        problem = nil
        stopWaiting()
        draft = ""
        await Invites.shared.refresh()
    }

    func stopWaiting() {
        waiting = false
        waitedLong = false
        waitTimer?.invalidate()
        watch = nil
    }

    // MARK: the surprise's picture

    nonisolated(unsafe) private static var surprise: [Bool: NSImage] = [:]

    /// Two of the three, gray and out of focus, turned apart, a question mark over them.
    nonisolated static func surprisePicture(dark: Bool) -> NSImage? {
        if let kept = surprise[dark] { return kept }
        guard let back = AppIconStyle.amber.image(dark: dark), let front = AppIconStyle.redEnamel.image(dark: dark) else { return nil }
        let side: CGFloat = 512
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            for (picture, turn, shift) in [(back, -9.0, -26.0), (front, 8.0, 26.0)] {
                guard let soft = blurred(picture, side: side) else { continue }
                NSGraphicsContext.saveGraphicsState()
                let transform = NSAffineTransform()
                transform.translateX(by: side / 2 + shift, yBy: side / 2)
                transform.rotate(byDegrees: turn)
                transform.translateX(by: -side / 2, yBy: -side / 2)
                transform.concat()
                soft.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.55)
                NSGraphicsContext.restoreGraphicsState()
            }
            let mark = NSAttributedString(string: "?", attributes: [
                .font: NSFont.systemFont(ofSize: side * 0.36, weight: .bold).rounded(),
                .foregroundColor: dark ? NSColor.white : NSColor(white: 0.12, alpha: 1),
            ])
            let size = mark.size()
            mark.draw(at: NSPoint(x: (side - size.width) / 2, y: (side - size.height) / 2))
            return true
        }
        surprise[dark] = image
        return image
    }

    nonisolated private static func blurred(_ image: NSImage, side: CGFloat) -> NSImage? {
        var rect = NSRect(x: 0, y: 0, width: side, height: side)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        let input = CIImage(cgImage: cg)
        let gray = input.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        let soft = gray.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: side * 0.018]).cropped(to: input.extent)
        let context = CIContext()
        guard let out = context.createCGImage(soft, from: input.extent) else { return nil }
        return NSImage(cgImage: out, size: NSSize(width: side, height: side))
    }

    // MARK: plumbing

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static func decode(_ data: Data?) -> [Post]? {
        guard let data else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode([Post].self, from: data)
    }
}

private extension NSFont {
    func rounded() -> NSFont {
        guard let descriptor = fontDescriptor.withDesign(.rounded) else { return self }
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}

/// What a post can say about this Mac, all of it the person's own.
struct PostFacts: Equatable {
    /// The browser first brought in from, as Bring In named it.
    var from: String?
    /// Since when: Bring In's day, else the first day Wrapped counted.
    var since: Date?
    var broughtIn: Bool
    /// "Claude Code" or "Codex", and the plan's name: "Max", "Pro", "Plus".
    var agent: String?
    var plan: String?
    var tasks: Int
    var hours: Int
    var asks: Int
    var mailZero: Int
    var ads: Int

    @MainActor static func now() -> PostFacts {
        let settings = Store.settings
        let from = settings.string(forKey: Bringing.fromKey)
        let ledger = WrappedLedger.shared
        let since = (settings.object(forKey: Bringing.atKey) as? Date) ?? ledger.started
        let start = ledger.started ?? Date.distantPast
        var agent: String?
        var plan: String?
        for cli in ["claude", "codex"] where AgentSetup.connected(cli) {
            agent = cli == "claude" ? "Claude Code" : "Codex"
            plan = PlanAccounts.shared.usual[cli]?.plan?.capitalized
            break
        }
        return PostFacts(
            from: from.map(Self.shortName), since: since, broughtIn: from != nil, agent: agent, plan: plan,
            tasks: Int(ledger.sum(.agentTasks, since: start)), hours: Int(ledger.sum(.agentMinutes, since: start) / 60),
            asks: Int(ledger.sum(.asks, since: start)), mailZero: Int(ledger.sum(.mailZero, since: start)),
            ads: Int(ledger.sum(.ads, since: start)))
    }

    /// "Google Chrome" → "Chrome", the way people say it.
    static func shortName(_ name: String) -> String {
        let plain = name.replacingOccurrences(of: "Google ", with: "")
        return plain.components(separatedBy: " (").first ?? plain
    }

    /// "3 weeks ago", "a few days ago", as a person writes it.
    static func ago(_ date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let days = Int(now.timeIntervalSince(date) / 86_400)
        if days < 2 { return nil }
        if days < 7 { return "a few days ago" }
        if days < 14 { return "a week ago" }
        if days < 60 { return "\(days / 7) weeks ago" }
        return "\(days / 30) months ago"
    }

    enum Angle: String, CaseIterable {
        case switched, plan, number, beforeAfter, tip, admit, short, moment
    }

    /// The angle for this person: the first from their strongest fact,
    /// ties broken by their invite ID, so people alike start differently;
    /// each Another the next one round.
    static func angle(seed: String, step: Int, facts: PostFacts) -> Angle {
        var order = Angle.allCases
        let hash = seed.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff }
        order = Array(order[(hash % order.count)...] + order[..<(hash % order.count)])
        if facts.broughtIn, let at = order.firstIndex(of: .switched) { order.swapAt(0, at) }
        else if facts.tasks >= 10, let at = order.firstIndex(of: .number) { order.swapAt(0, at) }
        else if facts.agent != nil, let at = order.firstIndex(of: .plan) { order.swapAt(0, at) }
        return order[step % order.count]
    }

    nonisolated(unsafe) private static let linkPattern = try! NSRegularExpression(pattern: #"https?://\S+|\b[a-z0-9.-]+\.(com|app|dev|io)(/\S*)?"#)

    /// Characters as X counts them: any link is 23.
    static func xLength(_ text: String) -> Int {
        let whole = NSRange(text.startIndex..., in: text)
        var length = text.count
        for match in linkPattern.matches(in: text, range: whole) {
            guard let range = Range(match.range, in: text) else { continue }
            length += 23 - text[range].count
        }
        return length
    }

    /// Whether a written post can go: the link in it, English letters,
    /// short enough for X, no long dashes.
    static func fits(_ text: String, link: String) -> Bool {
        text.contains(link) && xLength(text) <= 280 && text.range(of: #"[^\P{L}\p{Latin}]"#, options: .regularExpression) == nil
            && !text.contains("\u{2014}") && text.count > 40
    }

    /// The post in one of a few plain shapes, from the same facts, when no agent writes it.
    static func template(_ f: PostFacts, angle: Angle, link: String) -> String {
        let plan = f.agent.map { "my \($0) plan" }
        let did = f.tasks > 0 ? "\(f.tasks) tasks done in tabs while I did other stuff" : f.asks > 0 ? "\(f.asks) answers right over the page" : nil
        let when = ago(f.since)
        var line: String
        switch angle {
        case .switched where f.broughtIn:
            line = "Moved from \(f.from ?? "Arc") to Yab\(when.map { " " + $0 } ?? ""). Same spaces, sidebar and ⌘T"
            line += plan.map { ", but it runs on \($0) and actually does the work" } ?? ", plus AI that's actually good"
            line += did.map { ": \($0)." } ?? "."
            line += "\n\nBest Arc alternative I've tried. Free, Mac: \(link)"
        case .plan where plan != nil:
            line = "Finally a use for \(plan!) outside the terminal. Yab hands it browser chores"
            line += did.map { ": \($0)." } ?? " and it just does them."
            line += " Feels like Arc, works like an assistant.\n\n\(link)"
        case .number where did != nil:
            line = "\(String(did!.prefix(1)).uppercased() + String(did!.dropFirst())), and I didn't open a single extra app. Yab is the Arc alternative where the AI actually does things.\n\n\(link)"
        case .short:
            line = "The browser Arc should have been. Plugs into your Claude Code or Codex plan and does the work.\n\n\(link)"
        case .admit:
            line = "Didn't expect to switch browsers this year. Yab runs my AI in background tabs and I just check what it did.\n\n\(link)"
        default:
            line = "Best Arc alternative I've found, and the AI is actually good: hook up your Claude Code or Codex plan and it does the work in tabs while you keep going.\n\nFree, Mac: \(link)"
        }
        return line
    }
}

/// The agent you connected writes the post, once, with no tools.
enum PostWriter {
    static let system = """
    Write one post for X, in English, in the first person, as the person whose facts these are. \
    Say that Yab is the best Arc alternative and that its AI runs on their own plan and does real work for them. \
    Use only the facts given and never invent a number, a feature or a time. \
    End with the link exactly as given. At most 280 characters, the link counting 23. \
    No hashtags, no emoji unless one fits naturally, no long dashes, no quotes around the post, \
    no "game changer", no "I'm not paid". Reply with the post and nothing else.
    """

    static func prompt(_ f: PostFacts, angle: PostFacts.Angle, link: String, avoid: [String]) -> String {
        var facts: [String] = []
        if let from = f.from { facts.append("They moved to Yab from \(from)" + (PostFacts.ago(f.since).map { ", \($0)" } ?? "") + ".") }
        else if let when = PostFacts.ago(f.since) { facts.append("They started using Yab \(when).") }
        if let agent = f.agent { facts.append("Yab runs on their \(agent) plan" + (f.plan.map { " (\($0))" } ?? "") + ".") }
        else { facts.append("They haven't connected an agent; say anyone can hook up their Claude Code or Codex plan.") }
        if f.tasks > 0 { facts.append("Yab's agent did \(f.tasks) tasks for them in tabs" + (f.hours > 0 ? ", about \(f.hours) hours of their time." : ".")) }
        if f.asks > 0 { facts.append("They asked Yab \(f.asks) questions answered over the page.") }
        if f.mailZero > 0 { facts.append("Inbox zero on \(f.mailZero) days in Yab Mail.") }
        if f.ads > 0 { facts.append("\(f.ads) ads blocked.") }
        let angles: [PostFacts.Angle: String] = [
            .switched: "the switch: where they came from and when", .plan: "their AI plan finally doing work in the browser",
            .number: "one striking number", .beforeAfter: "before and after, two short lines", .tip: "a tip to people still on Arc",
            .admit: "a candid admission", .short: "one short line", .moment: "one moment when it did something for them, from the facts",
        ]
        return "Facts:\n- " + facts.joined(separator: "\n- ")
            + "\n\nAngle: \(angles[angle] ?? "")."
            + "\nLink: \(link)"
            + (avoid.isEmpty ? "" : "\nDon't start like any of these: " + avoid.prefix(60).joined(separator: " | "))
    }

    /// Nil when no agent is connected, it failed, or what it wrote doesn't fit.
    @MainActor static func write(facts: PostFacts, angle: PostFacts.Angle, link: String, avoid: [String]) async -> String? {
        if Store.testing { return nil }
        let text = prompt(facts, angle: angle, link: link, avoid: avoid)
        let written = await PlanText.write(text, system: system, room: "agent/post", limit: 120).text
        let clean = written.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”"))
            .replacingOccurrences(of: " \u{2014} ", with: ", ")
        return PostFacts.fits(clean, link: link) ? clean : nil
    }
}
