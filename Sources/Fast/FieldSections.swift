import Foundation

/// A part of the empty ⌘T's list, Settings › Search's Before You Type.
enum FieldSection: String, CaseIterable, Identifiable {
    case reading, now, favorites, recent, frequent, actions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .reading: return "Reading Mode"
        case .now: return "Now"
        case .favorites: return "Favorites"
        case .recent: return "Recent Tabs"
        case .frequent: return "Frequent"
        case .actions: return "Quick Actions"
        }
    }

    var symbol: String {
        switch self {
        case .reading: return "book"
        case .now: return "clock.circle"
        case .favorites: return "star"
        case .recent: return "browser.tabs"
        case .frequent: return "clock.arrow.circlepath"
        case .actions: return "bolt"
        }
    }
}

/// Which spaces' sites the empty field's Frequent lists, once there are
/// spaces at all (History.frequent).
enum FrequentReach: String, CaseIterable, Identifiable {
    case thisSpace, everySpace

    var id: String { rawValue }
    static let key = "field.frequentReach"

    static var current: Self {
        Store.settings.string(forKey: key).flatMap(Self.init) ?? .thisSpace
    }

    var title: String {
        switch self {
        case .thisSpace: return "This space"
        case .everySpace: return "Every space"
        }
    }
}

/// What an empty ⌘T lists and in what order. Split View's field and the
/// words typed are not its business.
@MainActor
@Observable final class FieldSections {
    static let shared = FieldSections()

    private enum Key {
        static let order = "field.sections", off = "field.sections.off"
    }

    private let defaults: UserDefaults

    private(set) var order: [FieldSection] {
        didSet { defaults.set(order.map(\.rawValue), forKey: Key.order) }
    }
    private(set) var off: Set<FieldSection> {
        didSet { defaults.set(off.map(\.rawValue).sorted(), forKey: Key.off) }
    }

    init(defaults: UserDefaults = Store.settings) {
        self.defaults = defaults
        let kept = (defaults.stringArray(forKey: Key.order) ?? []).compactMap(FieldSection.init)
        // A part a later version adds goes to the end of a list put in order.
        order = kept + FieldSection.allCases.filter { !kept.contains($0) }
        off = Set((defaults.stringArray(forKey: Key.off) ?? []).compactMap(FieldSection.init))
    }

    func isOn(_ section: FieldSection) -> Bool { !off.contains(section) }

    func set(_ section: FieldSection, on: Bool) {
        if on { off.remove(section) } else { off.insert(section) }
    }

    func move(_ section: FieldSection, before other: FieldSection?) {
        guard section != other, let from = order.firstIndex(of: section) else { return }
        var next = order
        next.remove(at: from)
        next.insert(section, at: other.flatMap { next.firstIndex(of: $0) } ?? next.endIndex)
        order = next
    }

    /// The most of the eight each list has when nothing is turned off.
    static let usual: [FieldSection: Int] = [.recent: 3, .actions: 2, .frequent: 3]

    /// What is left of the eight, shared by the lists: Recent Tabs, then
    /// Quick Actions, then Frequent, each to its usual most. With something
    /// turned off the rest goes on down the list as it stands, so the room
    /// a part leaves is not left empty.
    nonisolated static func shares(left: Int, have: [FieldSection: Int], order: [FieldSection],
                                   off: Set<FieldSection>) -> [FieldSection: Int] {
        var room = max(0, left)
        var shares: [FieldSection: Int] = [:]
        for section in [FieldSection.recent, .actions, .frequent] where !off.contains(section) {
            let share = min(usual[section] ?? 0, have[section] ?? 0, room)
            shares[section] = share
            room -= share
        }
        guard !off.isEmpty else { return shares }
        for section in order {
            guard let share = shares[section] else { continue }
            let more = min((have[section] ?? 0) - share, room)
            shares[section] = share + more
            room -= more
        }
        return shares
    }
}

extension Browser {
    /// The space whose own Frequent the empty field lists, none for all of
    /// them. With one space there is nothing to keep apart, and its visits
    /// from before spaces were counted stay listed.
    var frequentSpace: UUID? {
        prefs.usesSpaces && spaces.count > 1 && FrequentReach.current == .thisSpace ? spaceID : nil
    }
}
