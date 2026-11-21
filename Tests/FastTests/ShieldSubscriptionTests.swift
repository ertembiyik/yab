import Foundation
import Testing
@testable import Fast

struct ShieldSubscriptionTests {
    @Test func validatedSubscriptionsPersistWithStableCacheNames() throws {
        let name = "shield-subscription-" + UUID().uuidString
        let store = try #require(UserDefaults(suiteName: name))
        defer { store.removePersistentDomain(forName: name) }
        #expect(ShieldSubscription.read(in: store).isEmpty)
        for raw in ["http://example.com/list.txt", "file:///tmp/list.txt", "https://user:secret@example.com/list", "https://example.com/list#fragment", "no url"] {
            #expect(ShieldSubscription(raw) == nil)
        }
        let item = try #require(ShieldSubscription(" https://example.com/list.txt "))
        ShieldSubscription.save([item, item], in: store)
        let restored = ShieldSubscription.read(in: store)
        #expect(restored == [item])
        #expect(restored[0].source.name == item.source.name)
        #expect(!item.source.name.contains("example.com") && !item.source.name.contains("/"))
        let all = Shield.selectedSources(disabling: [], custom: restored)
        #expect(all.last?.url == item.url)
        #expect(Shield.selectedSources(disabling: [item.source.name], custom: restored).map(\.name) == Shield.sources.map(\.name))
        #expect(!Shield.selectionMatches(nil, current: all.map(\.name)))
        ShieldSubscription.save([], in: store)
        #expect(ShieldSubscription.read(in: store).isEmpty)
    }

    @Test func errorPagesNeverReplaceCachedFilterText() {
        #expect(!ShieldSubscription.accepts(Data("<!DOCTYPE html>\n<html>Error</html>".utf8)))
        #expect(!ShieldSubscription.accepts(Data("{\"error\":\"unavailable\"}\n".utf8)))
        #expect(!ShieldSubscription.accepts(Data("a single line".utf8)))
        #expect(ShieldSubscription.accepts(Data("[Adblock Plus 2.0]\n||ads.example.com^\n".utf8)))
        #expect(ShieldSubscription.accepts(Data("0.0.0.0 ads.example.com\n".utf8)))
    }

    /// Row 1108: AdGuard's lists end their lines with CRLF.
    @Test func listsWithWindowsLineEndingsAreAccepted() {
        #expect(ShieldSubscription.accepts(Data("[Adblock Plus 2.0]\r\n! Title: AdGuard Annoyances filter\r\n##.cookie-notice\r\n".utf8)))
        #expect(ShieldSubscription.accepts(Data("! Checksum: x\r\n||ads.example.com^\r\n".utf8)))
        #expect(!ShieldSubscription.accepts(Data("<!DOCTYPE html>\r\n<html>Error</html>\r\n".utf8)))
        let rules = Filters.convert(["##.cookie-notice\r\n||ads.example.com^\r\n"])
        #expect(rules.generic.count == 1 && !rules.blocks.isEmpty)
    }
}

/// Exercises real asynchronous WK compilation, including a choice changed
/// before the previous compile returns. No downloads or user profile.
// The global Shield fixture is only safe in the gate's unique test world.
// A plain SwiftPM run reports this native fixture skipped instead of touching
// the shared default test profile. The release/native gate actually runs it.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["YAB_CHECK_WORLD"] != nil))
struct ShieldSourceLifecycleTests {
    @MainActor @Test func compiledSelectionFollowsLatestChoiceAndKeepsBaseRules() async throws {
        try #require(Store.testing && Store.world?.hasPrefix("appkit-gate-") == true)
        let shield = Shield.shared
        let folder = Store.folder.appendingPathComponent("Shield/lists", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("easyprivacy.txt")
        let prior = try? Data(contentsOf: file)
        let fixture = "||subscription-fixture.invalid^\n"
        try Data(fixture.utf8).write(to: file)
        defer {
            if let prior { try? prior.write(to: file) } else { try? FileManager.default.removeItem(at: file) }
        }
        func settled() async throws {
            let limit = Date().addingTimeInterval(30)
            while shield.report["building"] as? Bool == true, Date() < limit {
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(shield.report["building"] as? Bool == false)
            #expect(shield.report["trouble"] as? String == "")
        }
        // A rapid series goes through the real setter and coalescing builder.
        for source in Shield.sources { shield.setSource(source.name, enabled: source.name == "easyprivacy") }
        shield.setSource("easyprivacy", enabled: false)
        shield.setSource("easyprivacy", enabled: true)
        try await settled()
        #expect(shield.report["selection"] as? [String] == ["easyprivacy"])
        #expect(shield.report["rules_made"] as? Int == Filters.convert([Shield.base, fixture]).count)
        #expect(!shield.lists.isEmpty)
        shield.setSource("easyprivacy", enabled: false)
        try await settled()
        #expect(shield.report["selection"] as? [String] == [])
        #expect(shield.report["rules_made"] as? Int == Filters.convert([Shield.base]).count)
        #expect(!shield.lists.isEmpty)
        shield.refresh(now: true)
        let limit = Date().addingTimeInterval(5)
        while shield.refreshing, Date() < limit { try await Task.sleep(for: .milliseconds(25)) }
        #expect(!shield.refreshing && !shield.refreshFailed)
    }
}

/// Settings › Privacy › Filter lists: names, counts, titles and the check
/// an address gets before Add (row 1108's redesign, A and C).
struct ShieldListWordsTests {
    private let us = Locale(identifier: "en_US")

    @Test func factsCountRulesAndReadTheHeader() {
        let adguard = """
        [Adblock Plus 2.0]\r
        ! Title: AdGuard Annoyances filter\r
        ! TimeUpdated: 2026-10-24T10:21:11.000Z\r
        ! Homepage: https://github.com/AdguardTeam\r
        \r
        ##.cookie-notice\r
        ||ads.example.com^\r
        example.com#@#.banner\r
        """
        let facts = ShieldLists.facts(adguard)
        #expect(facts.rules == 3)
        #expect(facts.title == "AdGuard Annoyances filter")
        #expect(facts.updated == ISO8601DateFormatter().date(from: "2026-10-24T10:21:11Z"))

        let easylist = "[Adblock Plus 2.0]\n! Version: 202610241002\n! Title: EasyList\n! Last modified: 24 Oct 2026 10:02 UTC\n||a.example^\n##.ad\n"
        let easy = ShieldLists.facts(easylist)
        #expect(easy.rules == 2 && easy.title == "EasyList")
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        #expect(easy.updated == utc.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 10, minute: 2)))

        // A hosts file: its # comments are no rules, its ## hiding is.
        let hosts = ShieldLists.facts("# Peter Lowe's list\n# Last updated: 2026-10-20\n127.0.0.1 ads.example\n127.0.0.1 track.example\n##.ad\n")
        #expect(hosts.rules == 3 && hosts.title == nil && hosts.updated != nil)
        #expect(ShieldLists.facts("! only a header\n! Title: Empty\n").rules == 0)
        #expect(ShieldLists.facts("||x.example^\n").title == nil)
    }

    @Test func builtInListsHaveRealNamesAndWhatTheyBlock() {
        let names = Dictionary(uniqueKeysWithValues: Shield.sources.map { ($0.name, ShieldListWords.name($0, title: "ignored")) })
        #expect(names == [
            "easylist": "EasyList", "easyprivacy": "EasyPrivacy", "ublock-filters": "uBlock filters",
            "ublock-badware": "Malware and scams", "ublock-privacy": "uBlock privacy", "ublock-unbreak": "Site fixes",
            "ublock-quick-fixes": "Quick fixes", "peter-lowe": "Peter Lowe’s list",
            "adguard-url-tracking": "AdGuard URL tracking",
        ])
        for source in Shield.sources {
            let detail = ShieldListWords.detail(source)
            #expect(!detail.isEmpty && !detail.contains("\u{2014}") && !detail.hasPrefix("Your list"))
        }
        #expect(ShieldListWords.detail(Shield.sources[0]) == "Ads on most sites")
        #expect(ShieldListWords.detail(Shield.sources[1]) == "Trackers and analytics")
    }

    @Test func customListsGoByTheirTitleElseTheirHost() throws {
        let item = try #require(ShieldSubscription("https://filters.adtidy.org/extension/ublock/filters/14_optimized.txt"))
        #expect(ShieldListWords.name(item.source, title: "AdGuard Annoyances") == "AdGuard Annoyances")
        #expect(ShieldListWords.name(item.source, title: nil) == "filters.adtidy.org")
        #expect(ShieldListWords.detail(item.source) == "Your list · filters.adtidy.org")
    }

    @Test func countsAndTheAdBlockerLine() {
        #expect(ShieldListWords.count(68_412, locale: us) == "68,412")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(ShieldListWords.summary(rules: 208_887, lists: 9, fetched: now.addingTimeInterval(-12 * 60), now: now, locale: us)
                == "208,887 rules from 9 lists · updated 12 min ago")
        #expect(ShieldListWords.summary(rules: 1_200, lists: 1, fetched: nil, now: now, locale: us) == "1,200 rules from 1 list")
        #expect(ShieldListWords.summary(rules: 0, lists: 9, fetched: now, now: now) == nil)
        #expect(ShieldListWords.ago(now.addingTimeInterval(-20), now: now) == "updated just now")
        #expect(ShieldListWords.ago(now.addingTimeInterval(-3_700), now: now) == "updated 1 hour ago")
        #expect(ShieldListWords.ago(now.addingTimeInterval(-5 * 3_600), now: now) == "updated 5 hours ago")
        #expect(ShieldListWords.ago(now.addingTimeInterval(-3 * 86_400), now: now) == "updated 3 days ago")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        #expect(ShieldListWords.checked(rules: 38_069, updated: now.addingTimeInterval(-60), now: now, calendar: calendar, locale: us)
                == "38,069 rules · updated today")
        #expect(ShieldListWords.checked(rules: 38_069, updated: now.addingTimeInterval(-86_400), now: now, calendar: calendar, locale: us)
                == "38,069 rules · updated yesterday")
        #expect(ShieldListWords.checked(rules: 1, updated: nil, locale: us) == "1 rule")
    }

    @Test func addressesAreCheckedBeforeAnyFetch() throws {
        let taken = Shield.sources.map(\.url)
        #expect(ShieldAddCheck.before("  ", taken: taken) == .idle)
        #expect(ShieldAddCheck.before("example.com/list.txt", taken: taken) == .bad(ShieldAddCheck.notAddress))
        #expect(ShieldAddCheck.before("http://example.com/list.txt", taken: taken) == .bad(ShieldAddCheck.notHTTPS))
        #expect(ShieldAddCheck.before("https://easylist.to/easylist/easylist.txt", taken: taken) == .bad(ShieldAddCheck.taken))
        #expect(ShieldAddCheck.before("https://example.com/list.txt", taken: taken) == nil)
        // An eval's list on this Mac: a test run only.
        #expect(ShieldAddCheck.before("http://127.0.0.1:8123/list.txt", taken: taken, loopback: true) == nil)
        #expect(ShieldAddCheck.before("http://127.0.0.1:8123/list.txt", taken: taken, loopback: false) == .bad(ShieldAddCheck.notHTTPS))
        #expect(ShieldSubscription("http://127.0.0.1:8123/list.txt", loopback: false) == nil)
        #expect(ShieldSubscription("http://localhost:8123/list.txt", loopback: true) == nil)
    }

    @Test func whatCameBackDecidesWhetherAddIsPrimary() throws {
        let url = try #require(URL(string: "https://lists.example.org/mine.txt"))
        #expect(ShieldAddCheck.after(nil, url: url) == .bad(ShieldAddCheck.unreachable))
        #expect(ShieldAddCheck.after(Data("<!doctype html>\n<html><body>Not here</body></html>\n".utf8), url: url) == .bad(ShieldAddCheck.notList))
        #expect(ShieldAddCheck.after(Data("! Title: Nothing\n! Expires: 1 day\n".utf8), url: url) == .bad(ShieldAddCheck.notList))
        let good = ShieldAddCheck.after(Data("! Title: My List\n||ads.example^\n##.banner\n".utf8), url: url)
        #expect(good == .good(title: "My List", rules: 2, updated: nil))
        #expect(good.addable && good.facts == ShieldLists.Facts(rules: 2, title: "My List"))
        #expect(ShieldAddCheck.after(Data("||ads.example^\n##.banner\n".utf8), url: url) == .good(title: "lists.example.org", rules: 2, updated: nil))
        for state in [ShieldAddCheck.idle, .checking, .bad(ShieldAddCheck.notList)] {
            #expect(!state.addable && state.facts == nil)
        }
    }
}
