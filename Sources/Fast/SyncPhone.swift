import AppKit
import SwiftUI
import SyncKit

// Send to iPhone, from this Mac (docs/sync.md, "Pages for the iPhone"): a
// tab's menu and Site Controls' ⋯ offer "Send to <iPhone>" for each iPhone
// that says in its own commandcap record that it takes pages (OpenOnPhone);
// the page goes as a `send` of kind `open` addressed to it, which the
// iPhone takes once. From iPhone, the other way, is SyncPhoneFront.

/// Bumped as capability records come in; their journal isn't observed.
@MainActor
@Observable
private final class CapabilitiesHeard {
    static let shared = CapabilitiesHeard()
    var count = 0
}

extension SyncCenter {
    /// The iPhones of the account that take pages from this Mac, by name.
    var phones: [SyncClient.Listed] {
        _ = CapabilitiesHeard.shared.count
        guard let journal else { return [] }
        return devices.filter { device in
            device.id != thisDevice && !device.revoked && device.isMobile
                && OpenOnPhone.supports(journal.record(.init(collection: OpenOnMac.capability, id: device.id)), device: device.id)
        }.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    /// The other devices of the account that show an assistant's question
    /// and answer it, as they say in their own commandcap record.
    var assistantAnswerers: [SyncClient.Listed] {
        _ = CapabilitiesHeard.shared.count
        guard on, let journal else { return [] }
        return devices.filter { device in
            device.id != thisDevice && !device.revoked
                && AssistantApprovalRecords.answers(journal.record(.init(collection: OpenOnMac.capability, id: device.id)), device: device.id)
        }
    }

    /// The page goes to that iPhone: written now, up as soon as the line
    /// is. Nil, and nothing written, for a page that can't go (a private
    /// one, Yab's own, an address only this Mac reaches) or an iPhone that
    /// doesn't take pages.
    @discardableResult
    func send(_ url: URL, title: String, space: UUID?, to phone: String) -> String? {
        guard let journal, OpenOnPhone.supports(journal.record(.init(collection: OpenOnMac.capability, id: phone)), device: phone),
              let page = ContinuePage.page(url: url, title: title, space: space?.uuidString),
              let fields = try? OpenOnMac.fields(device: phone, sender: Self.deviceID, url: page.url, at: Date(),
                                                 space: page.space, title: page.title) else { return nil }
        let id = UUID().uuidString.lowercased()
        do { try journal.change(.init(collection: SyncChats.send, id: id), fields) } catch { return nil }
        client?.kick()
        return id
    }

    /// Capability records that came in: an iPhone this Mac doesn't list yet
    /// has the device list read again, so its name is there to send to.
    func heardCapabilities(_ records: [SyncKit.Record]) {
        refreshAssistantAnswererNames()
        let known = Set(devices.map(\.id))
        if records.contains(where: { $0.id != Self.deviceID && !known.contains($0.id) }) { refreshDevicesSoon() }
        CapabilitiesHeard.shared.count += 1
    }

    /// The device list read again, at most every ten seconds.
    func refreshDevicesSoon() {
        guard Date().timeIntervalSince(phonesAskedForDevices) > 10 else { return }
        phonesAskedForDevices = Date()
        refreshDevices()
    }
}

@MainActor
enum SyncPhones {
    /// An iPhone (or an iPad) by the model the server lists.
    nonisolated static func isPhone(_ model: String) -> Bool { model.hasPrefix("iPhone") || model.hasPrefix("iPad") }
    /// An Android phone or tablet, which lists itself as "Android <maker> <model>".
    nonisolated static func isAndroid(_ model: String) -> Bool { model.hasPrefix("Android") }

    /// A tab's page as it would go to an iPhone, or nil for one that can't:
    /// an agent's or Yab's own, Mail's, an address only this Mac
    /// reaches (ContinuePage).
    static func page(_ tab: Tab, in browser: Browser) -> ContinuePage.Page? {
        guard !tab.shy, !tab.isBlank, !browser.inMail, !Agents.shared.sealed(tab) else { return nil }
        return ContinuePage.page(url: tab.address, title: tab.title,
                                 space: browser.prefs.usesSpaces ? browser.spaceID.uuidString : nil)
    }

    /// Send to iPhone, from a menu: written, and said in the corner (nothing
    /// else on this Mac's screen answers it).
    static func send(_ tab: Tab, in browser: Browser, to phone: SyncClient.Listed) {
        guard let page = page(tab, in: browser) else { return }
        let sync = SyncCenter.shared
        if sync.send(page.url, title: page.title, space: page.space.flatMap(UUID.init(uuidString:)), to: phone.id) != nil {
            browser.toaster.pop("Sent to \(phone.name)", mark: "iphone", feedback: .success)
        } else {
            browser.toaster.pop("Couldn’t send to \(phone.name)", mark: "exclamationmark.triangle")
        }
    }
}

/// "Send to <iPhone>" for each iPhone that takes pages, in a tab's menu and
/// Site Controls' ⋯; nothing at all without one.
struct PhoneSend: View {
    var browser: Browser
    let tab: Tab
    private var sync = SyncCenter.shared

    var body: some View {
        let phones = sync.on ? sync.phones : []
        if !phones.isEmpty, SyncPhones.page(tab, in: browser) != nil {
            ForEach(phones, id: \.id) { phone in
                Button("Send to \(phone.name)", mark: "yab.iphone.right") { SyncPhones.send(tab, in: browser, to: phone) }
            }
        }
    }
}
