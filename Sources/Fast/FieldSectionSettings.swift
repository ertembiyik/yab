import SwiftUI

/// Settings › Field's Before You Type: the parts of an empty ⌘T, in their
/// order, each with its switch, then what Yab notices. A part is dragged to
/// its place, its grip where its mark was under the pointer.
struct FieldSectionSettings: View {
    var prefs: Preferences
    private var sections = FieldSections.shared
    /// Mail that needs you shows once an account is connected.
    private var mail = MailCenter.shared
    @AppStorage(FrequentReach.key, store: Store.settings) private var reach = ""
    @AppStorage("hints.noticing", store: Store.settings) private var suggesting = true
    /// Kinds and people Don't Show Things Like This turned off, read so a
    /// change draws the list again; a habit's place is written to a file,
    /// hence the count.
    @AppStorage("hints.off", store: Store.settings) private var hintsOff = Data()
    @State private var shownAgain = 0
    @State private var hovered: FieldSection?

    var body: some View {
        Section {
            ForEach(sections.order) { section in
                line(section)
                    .draggable("field-section:" + section.id)
                    .dropDestination(for: String.self) { dropped, _ in
                        guard let value = dropped.first, value.hasPrefix("field-section:"),
                              let moved = FieldSection(rawValue: String(value.dropFirst("field-section:".count))),
                              moved != section, let from = sections.order.firstIndex(of: moved),
                              let to = sections.order.firstIndex(of: section) else { return false }
                        // Down the list it lands under the row, up it over.
                        let after = from < to ? sections.order.index(after: to) : to
                        sections.move(moved, before: sections.order.indices.contains(after) ? sections.order[after] : nil)
                        return true
                    }
            }
            FieldLine("Suggestions", mark: { FieldLineMark(symbol: "sparkles") }, status: { EmptyView() }, end: {
                FieldSwitch("Suggestions", isOn: Binding(get: { suggesting }, set: { Hints.shared.suggesting = $0 }))
            })
            .settingsAnchor("suggestions")
            if suggesting {
                if mail.connected {
                    FieldLine("Mail That Needs You", mark: { FieldLineMark(symbol: "envelope") }, status: { EmptyView() }, end: {
                        FieldSwitch("Mail That Needs You", isOn: Binding(get: { _ = hintsOff; return Noticing.shared.mailOn }, set: { Noticing.shared.mailOn = $0 }))
                    })
                    .settingsAnchor("suggestions-mail")
                }
                FieldLine("Promises", mark: { FieldLineMark(symbol: "checklist") }, status: { EmptyView() }, end: {
                    FieldSwitch("Promises", isOn: Binding(get: { _ = hintsOff; return Noticing.shared.promisesOn }, set: { Noticing.shared.promisesOn = $0 }))
                })
                .settingsAnchor("suggestions-promises")
                let _ = (hintsOff, shownAgain)
                ForEach(Noticing.shared.hidden) { hidden in
                    SettingsRow(hidden.title, detail: hidden.detail.isEmpty ? "Not suggested" : hidden.detail + ", not suggested") {
                        Button("Show Again") {
                            Noticing.shared.showAgain(hidden.id)
                            shownAgain += 1
                        }
                        .settingsButton()
                    }
                }
            }
        } header: {
            Text("Before You Type")
                .settingsAnchor("field-sections")
        }
    }

    private func line(_ section: FieldSection) -> some View {
        FieldLine(section.title, off: !sections.isOn(section), mark: {
            FieldGripMark(over: hovered == section) { FieldLineMark(symbol: section.symbol) }
        }, status: {
            // Only with spaces: without them there is one list to go through.
            if section == .frequent, prefs.usesSpaces, sections.isOn(.frequent) {
                DropMenu("Frequent comes from", options: FrequentReach.allCases.map { (title: $0.title, value: $0) },
                         selection: Binding(get: { FrequentReach(rawValue: reach) ?? .thisSpace }, set: { reach = $0.rawValue }))
                    .fixedSize()
                    .settingsAnchor("frequent-reach")
            }
        }, end: {
            FieldSwitch(section.title, isOn: Binding(get: { sections.isOn(section) }, set: { sections.set(section, on: $0) }))
        })
        .contentShape(Rectangle())
        .settingsRowHover { hovered = $0 ? section : (hovered == section ? nil : hovered) }
    }
}
