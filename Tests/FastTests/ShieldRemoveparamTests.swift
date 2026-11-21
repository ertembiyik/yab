import Foundation
import Testing
@testable import Fast

// A tab's top document loads without the parameters that only say where a
// link came from: Yab's own names (Filters.tracking, the same ones a copy
// drops) and the lists' $removeparam rules. The rules are the lists' own
// lines (uBlock filters – Privacy, AdGuard URL Tracking, 2026-11-18).

@Suite struct ShieldRemoveparamTests {
    static let privacy = """
    $removeparam=gbraid
    $removeparam=srsltid
    $removeparam=/^__hs/
    ||reddit.com^$doc,removeparam=ref_source
    ||reddit.com^$doc,removeparam=/deep_link=/
    ||facebook.com^$removeparam=mibextid
    ||googletagmanager.com/gtag/js?id=$removeparam=gtm
    $removeparam=cid,domain=example.org|~shop.example.org
    ||adthrive.com^$removeparam,from=~mediaite.com
    """

    static let remover = Filters.Remover(Filters.convert([privacy]).removals)

    private func clean(_ address: String, _ remover: Filters.Remover = remover) -> String? {
        remover.clean(URL(string: address)!)?.absoluteString
    }

    @Test func trackersGoThePageStays() {
        #expect(clean("https://httpbin.org/get?id=7&utm_source=x&fbclid=y") == "https://httpbin.org/get?id=7")
        #expect(clean("https://example.com/a?UTM_Medium=mail&gclid=1&msclkid=2") == "https://example.com/a")
        #expect(clean("https://github.com/o/r/blob/main/f.swift?ref=dev&utm_campaign=x") == "https://github.com/o/r/blob/main/f.swift?ref=dev")
        #expect(clean("https://example.com/search?q=a&source=hp&feature=x&si=1") == "https://example.com/search?q=a&source=hp&feature=x")
    }

    @Test func fragmentAndEncodingAsWritten() {
        #expect(clean("https://shop.example.com/a%2Fb?value=a%2Bb&utm_source=x&q=%E2%9C%93#Part%202") == "https://shop.example.com/a%2Fb?value=a%2Bb&q=%E2%9C%93#Part%202")
        #expect(clean("https://example.com/?utm%5Fsource=x&gclid=1#top") == "https://example.com/#top")
        #expect(clean("https://example.com/a?next=https%3A%2F%2Fb.example%2F%3Futm_source%3Dx&fbclid=1") == "https://example.com/a?next=https%3A%2F%2Fb.example%2F%3Futm_source%3Dx")
    }

    @Test func nothingToStripIsNil() {
        #expect(clean("https://example.com/") == nil)
        #expect(clean("https://example.com/?") == nil)
        #expect(clean("https://example.com/a?id=7&page=2#utm_source=x") == nil)
        #expect(clean("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42") == nil)
    }

    @Test func theListsRulesWhereTheyApply() {
        #expect(clean("https://www.google.com/search?q=a&srsltid=AfmBOo") == "https://www.google.com/search?q=a")
        #expect(clean("https://example.com/?gbraid=0AAAA&__hstc=1&__hssc=2&__hsfp=3&p=1") == "https://example.com/?p=1")
        #expect(clean("https://www.reddit.com/r/swift/?ref_source=share&deep_link=1&sort=new") == "https://www.reddit.com/r/swift/?sort=new")
        // Only on the site its pattern names.
        #expect(clean("https://example.com/?ref_source=share") == nil)
        #expect(clean("https://m.facebook.com/story.php?id=1&mibextid=Zx") == "https://m.facebook.com/story.php?id=1")
        // $domain: the document's own site, less the ones it spares.
        #expect(clean("https://news.example.org/?cid=5&p=1") == "https://news.example.org/?p=1")
        #expect(clean("https://shop.example.org/?cid=5") == nil)
        #expect(clean("https://example.net/?cid=5") == nil)
        // Every parameter, narrowed to one site.
        #expect(clean("https://ads.adthrive.com/x?a=1&b=2#c") == "https://ads.adthrive.com/x#c")
    }

    @Test func exceptionsSpare() {
        let spared = Filters.Remover(Filters.convert([Self.privacy + """

        @@||news.example.com^$removeparam
        @@||docs.example.com^$removeparam=utm_source
        """]).removals)
        #expect(clean("https://news.example.com/a?utm_source=x&gbraid=1", spared) == nil)
        #expect(clean("https://docs.example.com/a?utm_source=x&utm_medium=y&gbraid=1", spared) == "https://docs.example.com/a?utm_source=x")
        #expect(clean("https://example.com/a?utm_source=x", spared) == "https://example.com/a")
    }

    @Test func onlyRulesForATopDocument() {
        // Other kinds of load only; every parameter of every page; entities.
        #expect(Filters.removalRule("||example.com^$xhr,removeparam=a") == nil)
        #expect(Filters.removalRule("||example.com^$script,image,removeparam=a") == nil)
        #expect(Filters.removalRule("||example.com^$doc,xhr,removeparam=a") != nil)
        #expect(Filters.removalRule("||example.com^$~xhr,removeparam=a") != nil)
        #expect(Filters.removalRule("$removeparam") == nil)
        #expect(Filters.removalRule("*$removeparam") == nil)
        #expect(Filters.removalRule("||example.com^$removeparam") != nil)
        #expect(Filters.removalRule("@@||example.com^$removeparam") != nil)
        #expect(Filters.removalRule("$removeparam=a,domain=example.*") == nil)
        #expect(Filters.removalRule("$removeparam=a,domain=a.com,to=b.com") == nil)
        #expect(Filters.removalRule("$removeparam=/[/") == nil)
        #expect(Filters.removalRule("||example.com^$removeparam=a,redirect=noop.js") == nil)
        #expect(Filters.removalRule("||example.com^$urlskip=?u") == nil)
        // A scheme alone keeps its scheme, and narrows nothing for "every parameter".
        #expect(Filters.removalRule("|http://$removeparam") == nil)
        let http = Filters.Remover(Filters.convert(["|http://$removeparam=ref"]).removals)
        #expect(clean("http://example.com/a?ref=x&b=1", http) == "http://example.com/a?b=1")
        #expect(clean("https://example.com/a?ref=x&b=1", http) == nil)
    }

    @Test func neverABlockAndBadfilterTakesItBack() {
        let rules = Filters.convert([Self.privacy])
        #expect(rules.removals.count == 9)
        #expect(rules.blocks.isEmpty && rules.exceptions.isEmpty)
        let line = "$removeparam=gbraid"
        #expect(Filters.convert([line, line + ",badfilter"]).removals.isEmpty)
    }

    @Test func aCopyDropsYabsOwnNames() {
        // The copy and the open share the one list.
        let url = URL(string: "https://example.com/a?id=4&utm_source=x&si=1&gbraid=2")!
        #expect(Diary.shareable(url).absoluteString == "https://example.com/a?id=4&gbraid=2")
        #expect(Filters.Remover([]).clean(url)?.absoluteString == "https://example.com/a?id=4&gbraid=2")
    }

    @MainActor @Test func onlyWhereShieldBlocks() throws {
        try #require(Store.testing)
        let shield = Shield.shared
        let enabled = shield.enabled, remover = shield.remover, skipper = shield.skipper
        let host = "httpbin.org", paused = shield.isPaused(on: host)
        defer { shield.enabled = enabled; shield.remover = remover; shield.skipper = skipper; shield.pause(host, paused) }
        let url = try #require(URL(string: "https://httpbin.org/get?id=7&utm_source=x&gbraid=1"))
        shield.remover = Self.remover
        shield.skipper = nil
        shield.enabled = true
        shield.pause(host, false)
        #expect(shield.redirect(url, persistent: nil, cleaning: true)?.absoluteString == "https://httpbin.org/get?id=7")
        // Back, forward and reload keep their entry.
        #expect(shield.redirect(url, persistent: nil, cleaning: false) == nil)
        // Before the lists' removals are read: Yab's own names.
        shield.remover = nil
        #expect(shield.redirect(url, persistent: nil, cleaning: true)?.absoluteString == "https://httpbin.org/get?id=7&gbraid=1")
        shield.pause(host, true)
        #expect(shield.redirect(url, persistent: nil, cleaning: true) == nil)
        shield.pause(host, false)
        shield.enabled = false
        #expect(shield.redirect(url, persistent: nil, cleaning: true) == nil)
    }
}
