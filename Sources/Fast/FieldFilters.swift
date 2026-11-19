import SwiftUI
import AppKit

// What a place's list is narrowed to, from the field's end: the kinds of
// clip, of download or of account, the site it is kept to, the folder it
// looks in. Pressed, the choices drop from it on ⌘K's glass
// (FieldActionsPanel), as Files' folders do, each wearing its mark, the one
// chosen now ticked, searched from the list's foot; ⌘P steps through the
// kinds without it.

extension FieldPlace {
    /// Each of `filters`' marks, in their order.
    var filterSymbols: [String] {
        switch self {
        case .downloads: return ["doc", "arrow.down.circle", "envelope", "arrow.up.circle", "photo", "doc.text"]
        case .passwords: return ["key", "clock", "number", "exclamationmark.triangle", "square.on.square", "lock.open"]
        case .autofill: return ["square.2.layers.3d", "person", "creditcard", "house"]
        case .history: return ["clock", "calendar.today", "calendar", "yab.threads"]
        case .now: return ["clock.circle", "checklist", "envelope", "calendar", "agent.face", "link", "devices"]
        case .purchases: return ["arrow.triangle.2.circlepath", "shippingbox", "doc.text"]
        default: return []
        }
    }

    /// Where the kinds part: everything, then the kinds, and for Passwords
    /// what is wrong with an account after what it has.
    func filterGroup(_ index: Int) -> Int {
        // History's spans together, its threads apart (docs/day-threads.md).
        if self == .history { return index == FieldPlace.byThread ? 1 : 0 }
        return index == 0 ? 0 : self == .passwords && index >= 3 ? 2 : 1
    }
}

extension Clips.Filter {
    var symbol: String {
        switch self {
        case .all: return "clipboard"
        case .text: return "textformat.abc"
        case .links: return "link"
        case .images: return "photo"
        case .colors: return "paintpalette"
        case .files: return "doc"
        case .fast: return "globe"
        }
    }

    /// Copied in Yab wears Yab's own icon.
    @MainActor var image: NSImage? { self == .fast ? NSApp.applicationIconImage : nil }
}

extension Browser {
    /// The field's end pressed: ⌘K's list turned to what the place's list
    /// can be narrowed to, dropping from it, the one chosen now walked to,
    /// as the models drop from an answer's name (chooseAnswerModel).
    /// Again, it goes.
    func chooseFilter() {
        guard query.place != nil else { return }
        if query.choosingFilter, query.acting != nil {
            query.acting = nil
            return
        }
        let actions = filterActions
        guard !actions.isEmpty else { return }
        query.acting = nil
        query.choosingFilter = true
        query.actionWords = ""
        query.acting = actions.firstIndex(where: \.checked) ?? 0
        Browser.shownActions = actions.map(\.title)
    }

    /// What the place's list can be narrowed to, as the list's rows, a
    /// tick on each chosen now: a kind and a site can both be.
    var filterActions: [FieldAction] {
        switch query.place {
        case .files?:
            return query.form?.file == nil ? [] : fileFolderActions
        case .clipboard?:
            return Clips.Filter.allCases.map { kind in
                FieldAction(id: "kind." + kind.rawValue, title: kind.rawValue, symbol: kind.symbol, group: kind == .all ? 0 : 1,
                            image: kind.image, checked: query.clipFilter == kind) {
                    self.query.clipFilter = kind
                    self.query.spot = 0
                }
            }
        case .bookmarks?:
            return bookmarkFolderActions
        case let place?:
            return kindActions(place) + siteActions
        case nil:
            return []
        }
    }

    private func kindActions(_ place: FieldPlace) -> [FieldAction] {
        let symbols = place.filterSymbols
        return place.filters.enumerated().map { index, name in
            FieldAction(id: "filter.\(index)", title: name, symbol: symbols.indices.contains(index) ? symbols[index] : "list.bullet",
                        group: place.filterGroup(index), checked: query.placeFilter == index) {
                self.query.placeFilter = index
                self.query.spot = 0
                if place == .history {
                    self.query.stock.threadPages = nil
                    self.askHistory()
                }
            }
        }
    }

    /// The sites gone to most, or the files came from most, under the
    /// kinds: each with its own icon and how many, All Sites once one is
    /// kept to.
    private var siteActions: [FieldAction] {
        let site = query.stock.site
        var out: [FieldAction] = []
        if site != nil {
            out.append(FieldAction(id: "site.all", title: "All Sites", symbol: "globe", group: 3) { self.keepToSite(nil) })
        }
        for one in query.stock.sites {
            out.append(FieldAction(id: "site." + one.host, title: Browser.site(one.host), symbol: "globe", group: 3,
                                   image: ActionIcons.site(URL(string: "https://" + one.host)), checked: one.host == site,
                                   note: one.count.formatted()) { self.keepToSite(one.host) })
        }
        return out
    }

    /// Bookmarks and Recently Added, then every folder in it, one row
    /// each, named with the folder around it when it is inside another.
    private var bookmarkFolderActions: [FieldAction] {
        let here = query.stock.folder, recent = query.stock.recent
        var out = [FieldAction(id: "folder.top", title: "Bookmarks", symbol: "bookmark", checked: here == nil && !recent) { self.openFolder(nil) },
                   FieldAction(id: "folder.recent", title: "Recently Added", symbol: "clock", checked: recent) { self.openRecent() }]
        func add(_ nodes: [Bookmark], around: String?) {
            for folder in nodes where folder.isFolder {
                let title = around.map { $0 + " › " + folder.title } ?? folder.title
                out.append(FieldAction(id: "folder." + folder.id.uuidString, title: title, symbol: "folder", group: 1,
                                       checked: here == folder.id) { self.openFolder(folder.id) })
                add(folder.children ?? [], around: folder.title)
            }
        }
        add(bookmarks.roots, around: nil)
        return out
    }

    /// What the field's end says the list is narrowed to, and its mark.
    var filterLabel: (title: String, symbol: String, image: NSImage?) {
        switch query.place {
        case .files?:
            guard let folder = query.stock.fileFolder else { return ("Recent", "yab.clock", nil) }
            return (RecentFiles.title(of: folder), "folder", ActionIcons.file(folder))
        case .clipboard?:
            return (query.clipFilter.rawValue, query.clipFilter.symbol, query.clipFilter.image)
        case .bookmarks?:
            if query.stock.recent { return ("Recently Added", "clock", nil) }
            guard let id = query.stock.folder, let folder = bookmarks.node(id) else { return ("Bookmarks", "bookmark", nil) }
            return (folder.title, "folder", nil)
        case let place?:
            let filters = place.filters, symbols = place.filterSymbols, index = query.placeFilter
            let kind = filters.indices.contains(index) ? filters[index] : ""
            let site = query.stock.site.map { " · " + Browser.site($0) } ?? ""
            // Kept to a thread's pages: the thread said beside the span.
            if place == .history, let thread = query.stock.threadPages, index != FieldPlace.byThread {
                return (kind + " · " + thread.topic, "yab.threads", nil)
            }
            return (kind + site, symbols.indices.contains(index) ? symbols[index] : "list.bullet", nil)
        case nil:
            return ("", "list.bullet", nil)
        }
    }
}

/// What the place's list is narrowed to, at the field's end: its mark, its
/// name and a chevron, bare as a launcher's filter is, no plate of its own
/// on the field. Pressed, the choices drop from it (Browser.chooseFilter).
struct FieldFilterButton: View {
    let browser: Browser
    var query: Query
    private var shortcut = Keymap.shared.slot(.fieldFilter)

    var body: some View {
        let label = browser.filterLabel
        let open = query.choosingFilter && query.acting != nil
        Button { browser.chooseFilter() } label: {
            HStack(spacing: 6) {
                if let image = label.image {
                    Image(nsImage: image).resizable().interpolation(.high).frame(width: 16, height: 16)
                } else {
                    Symbol(label.symbol, size: 12)
                }
                Text(label.title)
                    .font(.system(size: 13.5))
                    .lineLimit(1)
                Symbol("chevron.down", size: 8)
            }
            .foregroundStyle(open ? Palette.ink : Palette.muted)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .fixedSize()
        .background(ClickZone(away: query.away))
        .keyTip(help)
    }

    private var help: String {
        let keys = shortcut.keys?.text ?? ""
        switch query.place {
        case .files?: return "Folder \(keys)"
        // Bookmarks' ⌘P is not a filter's.
        case .bookmarks?: return "Folder"
        case .clipboard?: return "Filter by Type \(keys)"
        default: return "Filter \(keys)"
        }
    }
}
