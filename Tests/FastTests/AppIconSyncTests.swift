import Foundation
import Combine
import Testing
import SyncKit
@testable import Fast

struct AppIconSyncTests {
    @MainActor @Test func receivingAwardsAndColorsRefreshesAnOpenPicker() {
        var changes = 0
        let watch = ObservedWrites({ _ = Invites.shared.revision }, told: { changes += 1 })
        AppIconStyle.sharedSettingsChanged(["look"])
        #expect(changes == 0)
        AppIconStyle.sharedSettingsChanged([AppIconCatalog.bracelet.grantKey])
        #expect(changes == 1)
        AppIconStyle.sharedSettingsChanged(["invite.charm.left", "invite.charm.right"])
        #expect(changes == 2)
        withExtendedLifetime(watch) {}
    }

    @Test func productionCatalogAndCharmPaletteMatchBothPlatforms() {
        let mac = Set(AppIconStyle.allCases.filter { $0 != .standard && $0 != .surprise }.map(\.rawValue))
        #expect(mac == Set(AppIconCatalog.allCases.map(\.rawValue)))
        #expect(CharmDraw.colors == AppIconCatalog.charmColors)
    }

    @Test func existingAwardsBecomeIndependentTrueGrants() throws {
        let posts = try JSONSerialization.data(withJSONObject: [
            ["url": "https://x.com/test/status/1", "state": "won", "posted": "2026-10-20T12:00:00Z", "reward": "02-liquid-mercury"],
            ["url": "https://x.com/test/status/2", "state": "live", "posted": "2026-10-21T12:00:00Z"],
        ])
        let defaults: [String: Any] = [
            "invite.joined": 7,
            "invite.posts": posts,
            "invite.post.kept": AppIconCatalog.amber.rawValue,
            "wrapped.finished": true,
            "gift.firstEdition.receipt": String(repeating: "a", count: 64),
            "halloween.worn": [AppIconCatalog.ghost.rawValue, AppIconCatalog.pumpkin.rawValue, "unknown"],
            AppIconCatalog.redEnamel.grantKey: true,
        ]
        let expected: Set<AppIconCatalog> = [.waxSeal, .bracelet, .ticket, .chrome, .amber, .redEnamel, .arcade, .firstEdition, .ghost, .pumpkin]
        #expect(AppIconGrants.owned(defaults) == expected)
        let settings = SyncShapes.settings(defaults)
        #expect(Set(settings.keys.filter { $0.hasPrefix(AppIconCatalog.grantPrefix) }) == Set(expected.map(\.grantKey)))
        for icon in expected { #expect(settings[icon.grantKey]?["value"] == .bool(true)) }
        #expect(settings["invite.posts"] == nil)
        #expect(settings["invite.joined"] == nil)
        #expect(settings["halloween.worn"] == nil)
    }

    @Test func friendThresholdsAndReceivedLinkKeepTheirExistingMeaning() throws {
        #expect(AppIconGrants.owned(["invite.joined": 0]).isEmpty)
        #expect(AppIconGrants.owned(["invite.joined": 1]) == [.waxSeal])
        #expect(AppIconGrants.owned(["invite.joined": 3]) == [.waxSeal, .bracelet])
        #expect(AppIconGrants.owned(["invite.joined": 10]) == [.waxSeal, .bracelet, .ticket, .yearbook])
        let received = try JSONSerialization.data(withJSONObject: ["from": "Alex", "best": false])
        #expect(AppIconGrants.owned(["invite.received": received]) == [.waxSeal])
        #expect(AppIconGrants.owned(["invite.received": Data("{}".utf8)]).isEmpty)
    }

    @Test func bestFriendCharmNeedsAJoinedBestFriendOrReceivedBestLink() throws {
        let joined = try JSONSerialization.data(withJSONObject: ["name": "Alex", "color": "mint", "joined": true])
        let waiting = try JSONSerialization.data(withJSONObject: ["name": "Alex", "joined": false])
        let received = try JSONSerialization.data(withJSONObject: ["from": "Alex", "best": true])
        #expect(AppIconGrants.owned(["invite.best": joined]) == [.charm])
        #expect(AppIconGrants.owned(["invite.best": waiting]).isEmpty)
        #expect(AppIconGrants.owned(["invite.received": received]) == [.waxSeal, .charm])
        #expect(AppIconGrants.ownsLocalCharm(["invite.best": joined]))
        #expect(AppIconGrants.ownsLocalCharm(["invite.received": received]))
        #expect(!AppIconGrants.ownsLocalCharm(["invite.best": waiting]))
        #expect(!AppIconGrants.ownsLocalCharm([AppIconCatalog.charm.grantKey: true]))
        for invalid in ["{}", "{\"joined\":true}", "{\"name\":\"Alex\",\"joined\":\"true\"}"] {
            #expect(AppIconGrants.owned(["invite.best": Data(invalid.utf8)]).isEmpty)
        }
        #expect(SyncShapes.syncs(AppIconCatalog.charm.grantKey))
        #expect(SyncShapes.syncs("invite.charm.left"))
        #expect(SyncShapes.syncs("invite.charm.right"))
        #expect(!SyncShapes.syncs("invite.charm.apart"))
    }

    @Test func beingInSeasonOrSelectingAnIconDoesNotPermanentlyAwardIt() {
        let defaults: [String: Any] = [
            "halloween.now": Date(timeIntervalSince1970: 1_792_000_000),
            "appearance.appIcon": AppIconCatalog.pumpkin.rawValue,
            "halloween.worn": [AppIconCatalog.chrome.rawValue],
            "gift.firstEdition.receipt": "short",
            "invite.post.kept": AppIconCatalog.yearbook.rawValue,
            AppIconCatalog.witch.grantKey: false,
            AppIconCatalog.grantPrefix + "unknown": true,
        ]
        #expect(AppIconGrants.owned(defaults).isEmpty)
        #expect(SyncShapes.settings(defaults)[AppIconCatalog.witch.grantKey] == nil)
        #expect(!SyncShapes.syncs(AppIconCatalog.grantPrefix + "unknown"))
        #expect(!SyncShapes.syncs(AppIconCatalog.grantPrefix + "unknown-dynamic"))
        #expect(!SyncShapes.syncs(AppIconCatalog.grantPrefix + ""))
    }

    @Test func grantsFromOtherDevicesSurviveReconciliationWithoutTheirLocalSources() throws {
        SyncShapes.register()
        let mac = try Journal(path: nil, device: "mac")
        let phone = try Journal(path: nil, device: "phone")
        try SyncShapes.reconcileSettings(mac, ["invite.joined": 3], addons: true)
        try phone.reconcile(SyncShapes.setting, [AppIconCatalog.ghost.grantKey: ["value": .bool(true)]])
        _ = try mac.receive(phone.pending().map { ($0.record, 1) })
        _ = try phone.receive(mac.pending().map { ($0.record, 1) })

        // Neither this Mac nor another freshly joined Mac has the remote
        // device's source data. An explicit false is also no revocation.
        try SyncShapes.reconcileSettings(mac, [AppIconCatalog.ghost.grantKey: false], addons: true)
        let other = try Journal(path: nil, device: "other-mac")
        _ = try other.receive(mac.all(SyncShapes.setting).map { ($0, 2) })
        try SyncShapes.reconcileSettings(other, [:], addons: true)
        let expected: Set<String> = Set([AppIconCatalog.waxSeal, .bracelet, .ghost].map(\.grantKey))
        #expect(Set(mac.living(SyncShapes.setting).map(\.id)) == expected)
        #expect(Set(other.living(SyncShapes.setting).map(\.id)) == expected)
        #expect(other.all(SyncShapes.setting).allSatisfy { $0["value"] == .bool(true) && $0.alive() })
    }

    @Test func anotherMacCannotOverwriteOrRemoveTheBestFriendsPalette() throws {
        SyncShapes.register()
        let original = try Journal(path: nil, device: "relationship-mac")
        let other = try Journal(path: nil, device: "other-mac")
        let best = try JSONSerialization.data(withJSONObject: ["name": "Alex", "joined": true])
        try SyncShapes.reconcileSettings(original, [
            "invite.best": best,
            "invite.charm.left": "lilac",
            "invite.charm.right": "rose",
        ], addons: true)
        _ = try other.receive(original.pending().map { ($0.record, 1) })
        let defaults: [String: Any] = [AppIconCatalog.charm.grantKey: true, "invite.charm.left": "mint"]
        #expect(SyncShapes.settings(defaults)["invite.charm.left"] == nil)
        #expect(SyncShapes.settings(defaults)["invite.charm.right"] == nil)
        try SyncShapes.reconcileSettings(other, defaults, addons: true)
        for (key, color) in ["invite.charm.left": "lilac", "invite.charm.right": "rose"] {
            let record = other.record(.init(collection: SyncShapes.setting, id: key))
            #expect(record?.alive() == true)
            #expect(record?["value"] == .string(color))
        }
        #expect(other.pending().isEmpty, "receiving a charm does not publish this Mac's stale palette")
    }
}
