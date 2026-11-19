import AppKit
import MailCore
import SwiftUI
import WebKit

// Add a Mail Account's agent way (docs/mail-providers.md, "The agent sets it
// up"): when the provider's app-password page is signed in in one of Yab's
// spaces, Set It Up hands the whole thing to an agent. It opens the page in
// a tab of its own, makes a password named Yab, and Yab takes that password
// off the page into the keychain itself: the agent never reads, types or
// repeats it (its answers show it as ••••, its screenshots are off while it
// works). Then, where the provider wants it, the agent turns IMAP on, and
// Yab tries both servers and adds the account. The person only does what
// the site wants from a person: their own password, when it asks again.

/// What a provider's way takes: the page that makes app passwords, signed
/// in to when these cookies are there, and the shape of what it makes.
struct MailSetupWay {
    /// Where the person would look on that page, in its own words.
    let path: String
    let cookieHosts: [String]
    let cookies: Set<String>
    /// The whole text of an element showing a new password (anchored).
    let shape: String
    /// Shown in the empty password field.
    let example: String

    static func of(_ provider: MailKnownProvider) -> MailSetupWay? {
        switch provider.id {
        case "icloud":
            return MailSetupWay(path: "Sign-In and Security › App-Specific Passwords", cookieHosts: ["apple.com"], cookies: ["myacinfo"],
                                shape: "^[a-z]{4}-[a-z]{4}-[a-z]{4}-[a-z]{4}$", example: "xxxx-xxxx-xxxx-xxxx")
        case "yahoo":
            return MailSetupWay(path: "Account Security › Generate app password", cookieHosts: ["yahoo.com"], cookies: ["T"],
                                shape: "^[a-z]{4} ?[a-z]{4} ?[a-z]{4} ?[a-z]{4}$", example: "xxxx xxxx xxxx xxxx")
        case "yandex":
            return MailSetupWay(path: "Security › App passwords", cookieHosts: ["yandex.ru", "yandex.com", "ya.ru"], cookies: ["Session_id"],
                                shape: "^[a-z]{16}$", example: "16 letters")
        default:
            guard provider.id == "zoho" || provider.id.hasPrefix("zoho-"), let host = URL(string: provider.appPasswordPage)?.host else { return nil }
            // accounts.zoho.eu's sign-in is zoho.eu's.
            return MailSetupWay(path: "Security › App Passwords", cookieHosts: [String(host.dropFirst("accounts.".count))], cookies: ["_iamadt", "_iambdt"],
                                shape: "^(?=[A-Za-z0-9 ]*[0-9])(?=[A-Za-z0-9 ]*[A-Za-z])[A-Za-z0-9]{4} ?[A-Za-z0-9]{4} ?[A-Za-z0-9]{4}$",
                                example: "12 letters and digits")
        }
    }

    /// The page's own name, as its header says it.
    static func pageName(_ provider: MailKnownProvider) -> String {
        switch provider.id {
        case "gmail": return "Google Account"
        case "icloud": return "Apple Account"
        case "yahoo": return "Yahoo Account"
        case "aol": return "AOL Account"
        case "yandex": return "Yandex ID"
        case "fastmail": return "Fastmail"
        default: return provider.id.hasPrefix("zoho") ? "Zoho Accounts" : provider.name
        }
    }

    /// The same shape anywhere in a text, for hiding it from an agent.
    var loose: NSRegularExpression? {
        let inner = shape.dropFirst().dropLast()
        return try? NSRegularExpression(pattern: "(?<![A-Za-z0-9-])" + inner + "(?![A-Za-z0-9-])")
    }

    func fits(_ text: String) -> Bool { text.range(of: shape, options: .regularExpression) != nil }
}

/// Whether a provider's app-password page is signed in in Yab: one of its
/// sign-in cookies, live, in some space's store. Only cookies, never a page.
enum MailSignedIn {
    /// A test world's providers signed in, in place of cookies.
    static var fake: Set<String>?

    @MainActor static func check(_ provider: MailKnownProvider, in browser: Browser) async -> Bool {
        if let fake { return fake.contains(provider.id) }
        guard let way = MailSetupWay.of(provider) else { return false }
        let spaces = browser.prefs.usesSpaces ? browser.spaces.map(\.id) : [browser.homeSpaceID]
        var seen = Set<ObjectIdentifier>()
        for id in [browser.spaceID] + spaces {
            let store = Spaces.store(for: id)
            guard seen.insert(ObjectIdentifier(store)).inserted else { continue }
            let cookies = await store.httpCookieStore.allCookies()
            if cookies.contains(where: { live($0, way) }) { return true }
        }
        return false
    }

    nonisolated static func live(_ cookie: HTTPCookie, _ way: MailSetupWay) -> Bool {
        guard way.cookies.contains(cookie.name), !cookie.value.isEmpty else { return false }
        if let ends = cookie.expiresDate, ends < Date() { return false }
        let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
        return way.cookieHosts.contains { domain == $0 || domain.hasSuffix("." + $0) }
    }
}

/// The one setup an agent is doing, for the sheet to show and the agent's
/// mail_setup to move along.
@MainActor
@Observable final class MailSetup {
    static let shared = MailSetup()

    enum Step: String, CaseIterable {
        case open, make, keep, imap, test
    }

    struct Run: Equatable {
        let address: String
        let provider: MailKnownProvider
        var setup: MailServerSetup
        let session: String
        let steps: [Step]
        /// The step under way; steps.count once the account is in.
        var at = 0
        /// A tab of the agent's handed to the person, and what for.
        var asking: String?
        var askingWhat = ""
        /// Why it stopped short, in a line.
        var trouble: String?
        var done: Bool { at >= steps.count }
    }

    private(set) var run: Run?
    /// What Yab took off the page, for hiding it from the agent. Never shown.
    @ObservationIgnored private var taken: String?
    @ObservationIgnored private var watch: Timer?

    nonisolated static let hidden = "•••• (kept by Yab)"

    /// Whether this way is open to an address: its provider has the way,
    /// an agent can run, and the page is signed in.
    static func available(_ provider: MailKnownProvider?) -> Bool {
        guard let provider, provider.appPassword, !provider.appPasswordPage.isEmpty, MailSetupWay.of(provider) != nil else { return false }
        return (anyAgent ?? Agents.installed) && MailCenter.agentsAllowed
    }

    /// A test world's answer to whether an agent can run, for the sheet's
    /// pictures.
    static var anyAgent: Bool?

    func steps(for provider: MailKnownProvider) -> [Step] {
        provider.imapSettingPage.isEmpty ? [.open, .make, .keep, .test] : [.open, .make, .keep, .imap, .test]
    }

    func words(_ step: Step, _ provider: MailKnownProvider) -> String {
        switch step {
        case .open: return "Opening \(MailSetupWay.pageName(provider))"
        case .make: return "Making an app password named \u{201C}Yab\u{201D}"
        case .keep: return "Keeping it in the keychain"
        case .imap: return "Turning on IMAP in \(provider.name)"
        case .test: return "Trying \(provider.name)\u{2019}s servers"
        }
    }

    // MARK: - from the sheet

    @discardableResult
    func start(_ setup: MailServerSetup, provider: MailKnownProvider, in browser: Browser) -> Bool {
        stop()
        let address = setup.address.lowercased()
        setup.saved(in: Store.settings)
        guard let session = MailChat.start(Self.words(address, provider: provider), say: "Set up " + address, refs: [], in: browser, open: false)
        else { return false }
        run = Run(address: address, provider: provider, setup: setup, session: session.id, steps: steps(for: provider))
        taken = nil
        watch = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated { MailSetup.shared.look() }
        }
        return true
    }

    /// The same way for an agent's own chat (mail_accounts add): the run is
    /// the asking session's, no sheet or second task behind it. False while
    /// another session's setup is going.
    func adopt(_ setup: MailServerSetup, provider: MailKnownProvider, session: String) -> Bool {
        if let run, !run.done, run.trouble == nil, run.session != session, Agents.shared.session(run.session)?.state.live == true { return false }
        stop()
        setup.saved(in: Store.settings)
        run = Run(address: setup.address.lowercased(), provider: provider, setup: setup, session: session, steps: steps(for: provider))
        taken = nil
        watch = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated { MailSetup.shared.look() }
        }
        return true
    }

    /// A test world's setup at a step, for the sheet's pictures: no agent
    /// behind it.
    func pretend(_ address: String, provider: MailKnownProvider, at: Int, asking: String?, trouble: String?) {
        stop()
        let address = address.lowercased()
        run = Run(address: address, provider: provider, setup: provider.setup(for: address), session: "pretend", steps: steps(for: provider),
                  at: at, asking: asking == nil ? nil : "pretend", askingWhat: asking ?? "", trouble: trouble)
    }

    /// Cancel: the agent stops; what it did stays (the password in the
    /// keychain, IMAP on).
    func cancel() {
        if let run, !run.done { _ = Agents.shared.stop(run.session) }
        stop()
    }

    /// The sheet is gone: nothing more to show.
    func clear() {
        if run?.done == true || run?.trouble != nil { stop() }
    }

    private func stop() {
        watch?.invalidate()
        watch = nil
        run = nil
        taken = nil
    }

    /// The person's tab, brought in front.
    func showAsking() {
        guard let id = run?.asking, let browser = Agents.shared.browser, let tab = browser.tabs.first(where: { $0.id.uuidString == id }) else { return }
        browser.select(tab)
        Links.window?.makeKeyAndOrderFront(nil)
    }

    /// Twice a second while it runs: whether the agent is still at it, and
    /// whether it handed a tab over.
    private func look() {
        guard var now = run, !now.done, now.trouble == nil else { return }
        let session = Agents.shared.session(now.session)
        if session?.state.live != true {
            now.trouble = "Your agent stopped before \(now.address) was in."
            now.asking = nil
            run = now
            return
        }
        let asking = Agents.shared.browser?.tabs.first { $0.agent == now.session && $0.handoff != nil }
        if now.asking != asking?.id.uuidString || now.askingWhat != (asking?.handoff ?? "") {
            now.asking = asking?.id.uuidString
            now.askingWhat = asking?.handoff ?? ""
            run = now
        }
    }

    // MARK: - from the agent (mail_setup)

    func handle(_ request: [String: Any], session: String?, browser: Browser, answer: @escaping ([String: Any]) -> Void) {
        guard var now = run, now.session == session else {
            answer(["error": "mail_setup is only for the setup Settings › Mail started for this task"]); return
        }
        let what = request["what"] as? String ?? ""
        switch what {
        case "step":
            guard let step = Step(rawValue: request["step"] as? String ?? ""), let index = now.steps.firstIndex(of: step) else {
                answer(["error": "step is one of " + now.steps.map(\.rawValue).joined(separator: ", ")]); return
            }
            now.at = max(now.at, index)
            run = now
            answer(["ok": true, "text": "Shown: " + words(step, now.provider) + "."])
        case "keep_password":
            let id = request["id"] as? String ?? ""
            guard let tab = browser.tabs.first(where: { $0.id.uuidString == id || Bench.short($0) == id }), tab.agent == session else {
                answer(["error": "give the tab of yours that shows the new password"]); return
            }
            take(from: tab, answer: answer)
        case "finish":
            Task { answer(await finish()) }
        case "stuck":
            let why = (request["why"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            now.trouble = why.isEmpty ? "Your agent couldn\u{2019}t finish." : String(why.prefix(160))
            now.asking = nil
            run = now
            answer(["ok": true, "text": "Said in Settings › Mail. Stop here and say what happened in a line."])
        default:
            answer(["error": "do is step, keep_password, finish or stuck"])
        }
    }

    /// The new password, read off the agent's tab in Yab's own world and
    /// put in the keychain; the agent hears only that it was kept.
    private func take(from tab: Tab, answer: @escaping ([String: Any]) -> Void) {
        guard let now = run, let way = MailSetupWay.of(now.provider) else { answer(["error": "no setup going"]); return }
        tab.page.runInYab(Self.finder(way.shape)) { [weak self] value in
            guard let self, var now = self.run else { return }
            let found = Set((value as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter(way.fits))
            guard found.count == 1, let shown = found.first else {
                answer(["error": found.isEmpty
                    ? "No new password shows on this page yet. Make it (Create, Generate), then call keep_password while it shows."
                    : "More than one password shows on this page. Close the others, then call keep_password again."])
                return
            }
            let password = shown.replacingOccurrences(of: " ", with: "")
            guard MailSecret.save(password: password, for: now.address) else { answer(["error": "the keychain didn't take it"]); return }
            self.taken = shown
            if let keep = now.steps.firstIndex(of: .keep) { now.at = max(now.at, keep + 1) }
            self.run = now
            answer(["ok": true, "text": "Kept in the keychain. It reads as \(Self.hidden) to you: never copy, type or repeat it. Close its dialog, then go on."])
        }
    }

    /// Both servers tried with what the keychain holds; the account added
    /// once both said yes.
    func finish() async -> [String: Any] {
        guard var now = run else { return ["error": "no setup going"] }
        guard let password = MailSecret.password(for: now.address) else {
            return ["error": "No password is kept for \(now.address) yet: keep_password first."]
        }
        if let test = now.steps.firstIndex(of: .test) { now.at = max(now.at, test) }
        run = now
        let (result, setup) = await MailOtherAccountSheet.tryBoth(now.setup, password: password)
        guard var after = run, after.session == now.session else { return ["error": "the setup was cancelled"] }
        guard result.ok else {
            let failed = (result.imap?.ok == false ? result.imap : result.smtp) ?? result.imap
            let said = MailOtherAccountSheet.words(failed, provider: now.provider.name)
            return ["error": said + (failed?.hint.isEmpty == false ? " (hint: \(failed!.hint))" : "") + " mail_probe says more; fix what you can and finish again."]
        }
        after.setup = setup
        if MailCenter.shared.accounts.contains(after.address) == false {
            MailCenter.shared.addIMAP(setup, password: password)
        }
        after.at = after.steps.count
        after.asking = nil
        run = after
        watch?.invalidate()
        watch = nil
        return ["ok": true, "text": "\(after.address) is in Yab's mail. Close your tabs and say so in a line."]
    }

    // MARK: - what the agent reads

    /// Every answer to the setup's own agent, with the password hidden from
    /// it: the one Yab took, and anything shaped like one, while it runs.
    /// Its screenshots are off, as a picture can't be hidden from.
    func guarded(_ verb: String, session: String?, _ answer: @escaping ([String: Any]) -> Void) -> ([String: Any]) -> Void {
        guard let now = run, let session, now.session == session, let way = MailSetupWay.of(now.provider) else { return answer }
        if verb == "shot" {
            return { _ in answer(["error": "Screenshots are off while Yab sets up mail. Read the page with snapshot."]) }
        }
        let taken = self.taken
        let loose = way.loose
        return { got in answer(Self.hide(got, taken: taken, loose: loose) as? [String: Any] ?? got) }
    }

    nonisolated static func hide(_ value: Any, taken: String?, loose: NSRegularExpression?) -> Any {
        switch value {
        case let text as String:
            var out = text
            if let taken, !taken.isEmpty {
                out = out.replacingOccurrences(of: taken, with: hidden)
                out = out.replacingOccurrences(of: taken.replacingOccurrences(of: " ", with: ""), with: hidden)
            }
            if let loose {
                out = loose.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: hidden)
            }
            return out
        case let list as [Any]:
            return list.map { hide($0, taken: taken, loose: loose) }
        case let dict as [String: Any]:
            return dict.mapValues { hide($0, taken: taken, loose: loose) }
        default:
            return value
        }
    }

    /// Every visible element (and field) whose whole text is one password
    /// of the shape, shadow roots included.
    nonisolated static func finder(_ shape: String) -> String {
        let pattern = shape.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        return """
        (() => {
          const shape = new RegExp('\(pattern)');
          const out = [];
          const seen = el => { const r = el.getBoundingClientRect(); const s = getComputedStyle(el);
            return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.display !== 'none' && Number(s.opacity) > 0.05; };
          const walk = root => {
            for (const el of root.querySelectorAll('*')) {
              if (el.shadowRoot) walk(el.shadowRoot);
              if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') {
                const v = (el.value || '').trim();
                if (shape.test(v) && seen(el)) out.push(v);
                continue;
              }
              if (el.childElementCount > 6) continue;
              const t = (el.innerText || el.textContent || '').trim();
              if (t.length <= 40 && shape.test(t) && seen(el)) out.push(t);
            }
          };
          walk(document);
          return out;
        })()
        """
    }

    // MARK: - the agent's words

    /// `asked`: the person asked for it in the chat (mail_accounts add),
    /// rather than pressing Set It Up with the page signed in.
    nonisolated static func words(_ address: String, provider: MailKnownProvider, asked: Bool = false) -> String {
        let page = MailSetupWay.pageName(provider)
        let imap = !provider.imapSettingPage.isEmpty
        var words = "Set up the mail account \(address) in Yab (\(provider.name)). "
        words += asked ? "The user asked for it in this chat: that is their yes to making an app password named Yab at \(page)"
            : "I pressed Set It Up in Settings \u{203A} Mail: that is my yes to making an app password named Yab at \(page)"
        words += imap ? ", and to turning on IMAP access in \(provider.name)\u{2019}s settings. " : ". "
        words += asked ? "If \(page) isn\u{2019}t signed in in Yab, its page asks for a sign-in: hand it over as step 2 says.\n\n" : "I\u{2019}m signed in to \(page) in Yab.\n\n"
        words += "1. Open \(provider.appPasswordPage) in a tab of your own, then call mail_setup with do: step, step: open.\n"
        words += "2. Make a new app password named Yab. Call mail_setup with do: step, step: make just before you press Create or Generate. "
        words += "If the site asks for my password again or wants a sign-in, call handoff on that tab with a short reason (Type your \(page) password): never type a password and never sign in yourself.\n"
        words += "3. While the page shows the new password, call mail_setup with do: keep_password and that tab. Yab takes it off the page into the keychain; it reads as \(hidden) to you. Never copy, type or repeat it. Then close its dialog.\n"
        if imap {
            words += "4. Call mail_setup with do: step, step: imap, open \(provider.imapSettingPage) and turn IMAP access on for the mailbox.\n"
        }
        words += "\(imap ? 5 : 4). Call mail_setup with do: finish. Yab tries both servers with the kept password and adds the account. If it says what failed, mail_probe says more: fix what you can and finish again.\n\n"
        words += "If you can\u{2019}t go on, call mail_setup with do: stuck and why, in a line. Screenshots are off for this task: read pages with snapshot. Close your tabs when you\u{2019}re done and say what happened in a line."
        return words
    }
}

/// A site's own icon on a round plate, its letter until the icon has come:
/// the provider on Mail's mark, the page a step goes to.
struct MailSiteMark: View {
    let host: String
    let side: CGFloat
    @State private var icon: NSImage?

    var body: some View {
        ZStack {
            Circle().fill(Color.white)
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: side * 0.62, height: side * 0.62)
            } else {
                Text(host.first.map { String($0).uppercased() } ?? "@")
                    .font(.system(size: (side * 0.42).rounded(), weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.55))
            }
        }
        .frame(width: side, height: side)
        .overlay(Circle().strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5))
        .onAppear { look() }
        .onChange(of: host) { _, _ in look() }
        .accessibilityHidden(true)
    }

    private func look() {
        icon = Favicons.shared.cached(host)
        guard icon == nil else { return }
        Favicons.shared.fetch(host: host)
        // In a moment, once it has come.
        let wanted = host
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if host == wanted { icon = Favicons.shared.cached(host) } }
    }
}

/// Add Account's menu marks: a site's icon at a menu's own 16 points, a
/// letter's circle until it has come.
enum MailMenuMark {
    static let hosts = ["google.com", "icloud.com", "outlook.com"]

    @MainActor static func fetch() { hosts.forEach { Favicons.shared.fetch(host: $0) } }

    @MainActor static func image(_ host: String) -> Image {
        guard let icon = Favicons.shared.cached(host) else { return Image(systemName: "globe") }
        let side = NSSize(width: 16, height: 16)
        let small = NSImage(size: side, flipped: false) { rect in
            icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        return Image(nsImage: small)
    }
}
