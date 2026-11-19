import Combine
import Foundation
import Testing
@testable import Fast

@MainActor
struct AutomaticPiPSitesTests {
    private func isolated(_ body: (UserDefaults) throws -> Void) throws {
        let name = "dev.serafim.fast.test.automatic-pip-" + UUID().uuidString
        let store = try #require(UserDefaults(suiteName: name))
        defer { store.removePersistentDomain(forName: name) }
        try body(store)
    }

    @Test func defaultInheritsAndRestoringOnRemovesTheException() throws {
        try isolated { store in
            let sites = AutomaticPiPSites(store: store)
            let url = URL(string: "https://youtube.com/watch?v=example")!
            #expect(sites.allows(url))
            #expect(store.object(forKey: AutomaticPiPSites.key) == nil)
            sites.setAllowed(false, for: url)
            #expect(!sites.allows(url))
            #expect(store.stringArray(forKey: AutomaticPiPSites.key) == ["youtube.com"])
            #expect(!AutomaticPiPSites(store: store).allows(url), "A fresh preference owner must retain the exception")
            sites.setAllowed(true, for: URL(string: "http://WWW.YouTube.com.:8080/other#fragment"))
            #expect(sites.allows(url))
            #expect(store.object(forKey: AutomaticPiPSites.key) == nil, "On restores inheritance, not a redundant override")
            #expect(AutomaticPiPSites(store: store).allows(url))
        }
    }

    @Test func siteKeysShareAliasesButNeverInheritParentDomainExceptions() throws {
        try isolated { store in
            let sites = AutomaticPiPSites(store: store)
            sites.setAllowed(false, for: URL(string: "https://WWW.YouTube.com.:443/watch?v=one"))
            for address in ["https://youtube.com/", "http://youtube.com:8080/two?x=1#part", "https://www.youtube.com/embed/one"] {
                #expect(!sites.allows(URL(string: address)))
            }
            for address in ["https://music.youtube.com/", "https://m.youtube.com/", "https://notyoutube.com/", "https://youtube.com.evil.invalid/"] {
                #expect(sites.allows(URL(string: address)))
            }
            #expect(AutomaticPiPSites.site(URL(string: "https://münchen.de/")) == "xn--mnchen-3ya.de")
            sites.setAllowed(false, for: URL(string: "https://münchen.de/"))
            #expect(!sites.allows(URL(string: "https://xn--mnchen-3ya.de/rathaus")))
        }
    }

    @Test func unicodeExceptionsRoundTripThroughTheirASCIIKey() throws {
        try isolated { store in
            let unicode = URL(string: "https://www.münchen.de./rathaus")!
            let ascii = URL(string: "https://xn--mnchen-3ya.de/")!
            let sites = AutomaticPiPSites(store: store)
            sites.setAllowed(false, for: unicode)
            #expect(store.stringArray(forKey: AutomaticPiPSites.key) == ["xn--mnchen-3ya.de"])
            #expect(!AutomaticPiPSites(store: store).allows(unicode))
            #expect(!sites.allows(ascii))
            sites.setAllowed(true, for: ascii)
            #expect(sites.allows(unicode))
            #expect(store.object(forKey: AutomaticPiPSites.key) == nil)
            sites.setAllowed(false, for: ascii)
            #expect(!sites.allows(unicode))
            store.set(["www.münchen.de."], forKey: AutomaticPiPSites.key)
            let restored = AutomaticPiPSites(store: store)
            #expect(restored.denied == ["xn--mnchen-3ya.de"])
            #expect(!restored.allows(ascii))
        }
    }

    @Test func nonWebAddressesCannotRecordAnException() throws {
        try isolated { store in
            let sites = AutomaticPiPSites(store: store)
            let addresses: [URL?] = [nil, URL(string: "about:blank"), URL(string: "file:///tmp/example"),
                                     URL(string: "data:text/plain,hi"), URL(string: "ftp://youtube.com/video"),
                                     URL(string: "https:///"), URL(string: "https://./")]
            for url in addresses {
                #expect(AutomaticPiPSites.site(url) == nil)
                sites.setAllowed(false, for: url)
                #expect(sites.allows(url))
            }
            #expect(sites.denied.isEmpty)
            #expect(store.object(forKey: AutomaticPiPSites.key) == nil)
        }
    }

    @Test func theActualSiteRowObeysTheMasterAndRestoresTheSavedChoice() throws {
        try isolated { store in
            let sites = AutomaticPiPSites(store: store)
            let url = URL(string: "https://www.youtube.com/watch")!
            let initial = try #require(SiteControlsView.automaticPiPRow(url: url, globally: true, sites: sites))
            #expect(initial.on && initial.said == "On for youtube.com" && initial.act != nil)
            initial.act?()
            #expect(!sites.allows(url))
            let off = try #require(SiteControlsView.automaticPiPRow(url: url, globally: true, sites: sites))
            #expect(!off.on && off.said == "Off for youtube.com")
            let masterOff = try #require(SiteControlsView.automaticPiPRow(url: url, globally: false, sites: sites))
            #expect(!masterOff.on && masterOff.dim && masterOff.act == nil)
            #expect(masterOff.said == "Off in Settings › Tabs")
            masterOff.act?()
            #expect(!sites.allows(url), "The disabled row must retain the saved site choice")
            off.act?()
            #expect(sites.allows(url))
            #expect(store.object(forKey: AutomaticPiPSites.key) == nil)
            let inheritedOff = try #require(SiteControlsView.automaticPiPRow(url: url, globally: false, sites: sites))
            #expect(!inheritedOff.on && inheritedOff.act == nil)
            #expect(SiteControlsView.automaticPiPRow(url: URL(string: "about:blank"), globally: true, sites: sites) == nil)
        }
    }

    @Test func aSharedOwnerPublishesForOtherAlreadyOpenControls() throws {
        try isolated { store in
            let sites = AutomaticPiPSites(store: store)
            let url = URL(string: "https://youtube.com/")!
            var received: [Set<String>] = [sites.denied]
            let observation = ObservedWrites { _ = sites.denied }
            defer { observation.cancel() }
            sites.setAllowed(false, for: url)
            received.append(sites.denied)
            let other = try #require(SiteControlsView.automaticPiPRow(url: url, globally: true, sites: sites))
            #expect(!other.on)
            other.act?()
            received.append(sites.denied)
            #expect(observation.count == 2)
            #expect(received == [[], ["youtube.com"], []])
            #expect(sites.allows(url))
        }
    }
}
