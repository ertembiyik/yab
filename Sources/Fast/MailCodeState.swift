import AppKit
import Combine

extension MailCodes {
    enum State: String { case fresh, copied, expired, used }
}

/// The same message identity in Mail, notifications, agents and the field's list.
struct MailCodeItem: Identifiable, Equatable {
    let account: String
    let message: String
    let thread: String
    let address: String
    let at: Date
    let read: MailCodeRead
    var id: String { "mail:\(account):\(message)" }
    var expires: Date { read.expires ?? at.addingTimeInterval(MailCodes.fresh) }

    var sent: SentCode {
        SentCode(id: id, code: read.code, from: address, at: at, source: .mail, mine: true,
                 thread: thread, account: account, message: message, read: read)
    }
}

@MainActor
@Observable final class MailCodeState {
    static let shared = MailCodeState()
    private(set) var revision = 0
    @ObservationIgnored private(set) var timer: Timer?
    @ObservationIgnored private var uses = Set<String>()
    @ObservationIgnored private var copiedID: String?
    @ObservationIgnored private var copiedCount: Int?
    @ObservationIgnored private var cachedRevision = -1
    @ObservationIgnored private var items: [String: MailCodeItem] = [:]
    @ObservationIgnored private var absent = Set<String>()
    @ObservationIgnored private(set) var copyTimes: [String: Date] = [:]

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            // Crash #1010 faults in executor lookup, before the tick runs.
            // Foundation calls this timer on the main run loop.
            AppKitMainThread.sync { self?.revision &+= 1 }
        }
    }

    func item(account: String, thread: String, message: String? = nil) -> MailCodeItem? {
        if cachedRevision != MailCenter.shared.changed {
            cachedRevision = MailCenter.shared.changed
            items.removeAll(); absent.removeAll()
        }
        let key = account + "|" + thread + "|" + (message ?? "")
        if let item = items[key] { return item }
        if absent.contains(key) { return nil }
        guard let store = MailCenter.shared.engines[account]?.store else { return nil }
        let id = message ?? store.codeMessage(thread: thread)
        if let id, let read = store.code(message: id), let mail = store.message(id) {
            let item = MailCodeItem(account: account, message: id, thread: mail.thread, address: mail.from.address, at: mail.date, read: read)
            items[key] = item
            return item
        }
        // Already sorted ordinary mail never needs its HTML parsed on the UI thread.
        if let sensed = store.sensed(thread), sensed.kind != .code { absent.insert(key); return nil }
        // A header-only sync or an old archived thread may not have reached Sense.
        let mail = message.flatMap { store.message($0) } ?? store.messages(thread: thread).last
        guard let mail, MailSense.kind(mail, bulk: false) == .code,
              let read = MailCodeWords.read(subject: mail.subject, text: mail.text ?? mail.snippet,
                                            html: mail.html, received: mail.date) else { absent.insert(key); return nil }
        store.keepCode(read, message: mail)
        let item = MailCodeItem(account: account, message: mail.id, thread: thread, address: mail.from.address, at: mail.date, read: read)
        items[key] = item
        return item
    }

    func state(_ item: MailCodeItem, now: Date = Date()) -> MailCodes.State {
        let store = MailCenter.shared.engines[item.account]?.store
        if uses.contains(item.id) || store?.codeUse(message: item.message) != nil { return .used }
        if item.at > now.addingTimeInterval(30) || now >= item.expires || store?.codeReplaced(message: item.message, now: now) == true { return .expired }
        if copiedID == item.id, copiedCount == NSPasteboard.general.changeCount { return .copied }
        return .fresh
    }

    func available(_ code: SentCode) -> Bool {
        if code.made { return true }
        guard !uses.contains(code.id) else { return false }
        guard let account = code.account, let thread = code.thread,
              let item = item(account: account, thread: thread, message: code.message) else { return true }
        return code.code == item.read.code && [.fresh, .copied].contains(state(item))
    }

    func copy(_ item: MailCodeItem) {
        CodeClip.shared.put(item.read, id: item.id, expires: item.expires, sent: item.sent)
    }

    func copied(_ id: String, count: Int) {
        let since = Date()
        copyTimes[id] = since
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self, self.copyTimes[id] == since else { return }
            self.copyTimes[id] = nil
            self.revision &+= 1
        }
        copiedID = id; copiedCount = count; revision &+= 1
    }

    func used(_ code: SentCode, site: String) {
        guard !code.made else { return }
        guard uses.insert(code.id).inserted else { return }
        if let account = code.account, let message = code.message {
            MailCenter.shared.engines[account]?.store.useCode(message: message, site: site)
        }
        revision &+= 1
        if MailCodes.archivesUsed, let account = code.account, let thread = code.thread {
            MailCenter.shared.act(.archive, thread: thread, account: account)
        }
    }
}

@MainActor
extension CodeClip {
    static let shared = CodeClip(onCopy: { MailCodeState.shared.copied($0, count: $1) },
                                 onUse: { MailCodeState.shared.used($0, site: $1) },
                                 canKeep: { MailCodeState.shared.available($0) })
}
