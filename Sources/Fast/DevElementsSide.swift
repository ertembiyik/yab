import SwiftUI
import AppKit

/// Elements' sidebar, Chrome's seven tabs in Chrome's order. The tabs that
/// have no room go under », the one picked from there taking the last
/// place in the row.
struct DevElementsSide: View {
    let browser: Browser
    @Bindable var model: DevWorkbench
    @State private var width: CGFloat = 0

    static let tabs = ["Styles", "Computed", "Layout", "Event Listeners", "DOM Breakpoints", "Properties", "Accessibility"]
    static let states = ["hover", "active", "focus", "focus-visible", "focus-within", "visited", "target"]

    var body: some View {
        VStack(spacing: 0) {
            strip
            Divider()
            if model.selectedNode == 0 {
                DevQuiet(words: "Select an element to inspect its styles and properties")
            } else {
                switch model.elementsTab {
                case "Computed": DevComputedPane(browser: browser, model: model)
                case "Layout": DevLayoutPane(browser: browser, model: model)
                case "Event Listeners": DevListenersPane(browser: browser, model: model)
                case "DOM Breakpoints": DevBreaksPane(browser: browser, model: model)
                case "Properties": DevPropertiesPane(browser: browser, model: model)
                case "Accessibility": DevAccessibilityPane(browser: browser, model: model)
                default: DevStylesPane(browser: browser, model: model)
                }
            }
        }
        .onChange(of: model.elementsTab) { browser.elementsSideLoad() }
        .onChange(of: model.selectedNode) { browser.elementsSideLoad() }
    }

    /// As many tabs as the row holds, measured by their words.
    private var shown: (row: [String], rest: [String]) {
        let font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        let pad = ButtonSize.small.padding * 2 + DevRowLayout.spacing
        let more: CGFloat = 32
        var room = width - DevLook.padding * 2
        var row: [String] = []
        for (i, tab) in Self.tabs.enumerated() {
            let need = (tab as NSString).size(withAttributes: [.font: font]).width + pad
            let last = i == Self.tabs.count - 1
            guard need <= room - (last ? 0 : more) else { break }
            row.append(tab); room -= need
        }
        if row.isEmpty { row = [Self.tabs[0]] }
        if !row.contains(model.elementsTab), Self.tabs.contains(model.elementsTab) { row[row.count - 1] = model.elementsTab }
        return (row, Self.tabs.filter { !row.contains($0) })
    }

    private var strip: some View {
        let (row, rest) = shown
        return HStack(spacing: DevRowLayout.spacing) {
            ForEach(row, id: \.self) { tab in
                Button { model.elementsTab = tab } label: { Text(tab).font(.system(size: 11.5, weight: .medium)).fixedSize() }
                    .buttonStyle(.yab(model.elementsTab == tab ? .secondary : .quiet, .small, tint: Palette.ink))
                    .focusable(false)
            }
            if !rest.isEmpty {
                Menu {
                    ForEach(rest, id: \.self) { tab in Button(tab) { model.elementsTab = tab } }
                } label: { Symbol("chevron.right.2", size: 9) }
                    .menuStyle(.button).menuIndicator(.hidden)
                    .buttonStyle(.yab(.quiet, .small, tint: Palette.ink, icon: .square))
                    .fixedSize().focusable(false)
                    .keyTip("More tabs")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DevLook.padding)
        .frame(height: 30)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

// MARK: - Styles

struct DevStylesPane: View {
    let browser: Browser
    @Bindable var model: DevWorkbench
    private var filter: String { model.paneFilters["styles"] ?? "" }
    private var filterText: Binding<String> { Binding(get: { model.paneFilters["styles"] ?? "" }, set: { model.paneFilters["styles"] = $0 }) }
    @State private var classes = false
    @State private var newClass = ""

    var body: some View {
        VStack(spacing: 0) {
            DevPanelBar {
                DevFilterField(text: filterText)
                Menu {
                    ForEach(DevElementsSide.states, id: \.self) { state in
                        Toggle(":" + state, isOn: Binding(get: { model.forced.contains(state) }, set: { _ in browser.elementsForce(state) }))
                    }
                } label: { Text(":hov").font(DevMono.font(11.5)) }
                    .menuStyle(.button).menuIndicator(.hidden)
                    .buttonStyle(.yab(model.forced.isEmpty ? .quiet : .secondary, .small)).fixedSize()
                    .keyTip("Force element state")
                Button { classes.toggle() } label: { Text(".cls").font(DevMono.font(11.5)) }
                    .buttonStyle(.yab(classes ? .secondary : .quiet, .small)).keyTip("Element classes")
                Button { browser.elementsAddRule() } label: { Symbol("plus", size: 10) }
                    .buttonStyle(.yab(.quiet, .small, icon: .square)).keyTip("New style rule")
                if !model.styleEdits.isEmpty {
                    Button("Save CSS") { browser.stylesSave() }.buttonStyle(.yab(.quiet, .small)).keyTip("Save changed stylesheets to the workspace", keys: "⌘S")
                }
            }
            Divider()
            ThreadScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if classes { classRow }
                    ForEach(model.styles.filter(shows)) { style in
                        if let from = style.inheritedFrom.nonempty, model.styles.first(where: { $0.inheritedFrom == from })?.id == style.id {
                            HStack(spacing: 4) {
                                Text("Inherited from").foregroundStyle(Palette.muted)
                                Text(from).font(DevMono.font(11)).foregroundStyle(ConsoleInk.tag)
                            }
                            .font(.system(size: 11.5))
                            .padding(.horizontal, 8).frame(height: 24)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Palette.ink.opacity(0.025))
                            Divider()
                        }
                        DevRuleView(browser: browser, model: model, style: style, filter: filter)
                        Divider()
                    }
                    DevBoxModel(model: model)
                }
            }
        }
    }

    private func shows(_ style: DevStyle) -> Bool {
        guard !filter.isEmpty else { return true }
        return style.selector.localizedCaseInsensitiveContains(filter) || style.properties.contains { $0.name.localizedCaseInsensitiveContains(filter) || $0.value.localizedCaseInsensitiveContains(filter) }
    }

    private var classRow: some View {
        let node = model.node(model.selectedNode)
        let names = (node?.attribute("class") ?? "").split(separator: " ").map(String.init) + model.offClasses
        return VStack(alignment: .leading, spacing: 4) {
            TextField("Add new class", text: $newClass)
                .textFieldStyle(.plain).font(DevMono.font(11.5))
                .onSubmit { browser.elementsClass(newClass, on: true); newClass = "" }
            ForEach(names, id: \.self) { name in
                Toggle(name, isOn: Binding(get: { !model.offClasses.contains(name) }, set: { browser.elementsClass(name, on: $0) }))
                    .toggleStyle(.checkbox).font(DevMono.font(11.5))
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.ink.opacity(0.025))
    }
}

/// A rule as Chromium writes it: `selector {`, the declarations a step in,
/// `}`; where it comes from at the right, a link into Sources.
struct DevRuleView: View {
    let browser: Browser
    @Bindable var model: DevWorkbench
    let style: DevStyle
    let filter: String
    @State private var adding = false
    @State private var newName = ""
    @State private var newValue = ""

    private var italic: Bool { style.origin == "user-agent" || style.kind == "attributes" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                (Text(style.selector).italic(italic) + Text(" {")).foregroundStyle(Palette.ink)
                Spacer(minLength: 4)
                source
            }
            ForEach(style.properties) { property in
                DevDeclarationRow(browser: browser, style: style, property: property, italic: italic)
                ForEach(property.expanded ? property.longhands : []) { long in
                    DevDeclarationRow(browser: browser, style: style, property: long, italic: italic, longhand: true)
                }
            }
            if adding {
                HStack(spacing: 0) {
                    TextField("name", text: $newName).textFieldStyle(.plain).fixedSize().foregroundStyle(ConsoleInk.cssName)
                    Text(": ")
                    TextField("value", text: $newValue).textFieldStyle(.plain)
                        .onSubmit { browser.elementsAddProperty(style, name: newName, value: newValue); adding = false; newName = ""; newValue = "" }
                }
                .padding(.leading, 16)
                .onExitCommand { adding = false }
            }
            Text("}")
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { if style.editable { adding = true } }
        }
        .font(DevMono.font(11))
        .padding(.horizontal, 8).padding(.vertical, 6)
    }

    @ViewBuilder private var source: some View {
        if style.origin == "user-agent" {
            Text("user agent stylesheet").italic().foregroundStyle(Palette.muted).lineLimit(1)
        } else if !style.source.isEmpty {
            Button { browser.elementsOpenSource(style.source, line: style.line) } label: {
                Text(DevStyle.place(style.source, line: style.line, page: browser.toolsFront?.address))
                    .underline().foregroundStyle(Palette.muted).lineLimit(1).truncationMode(.middle)
            }
            .buttonStyle(.plain)
            .pointerTip(style.source)
        }
    }
}

/// `name: value;`, its box at the left on hover (or while it is off), its
/// words edited where they stand: a click on the name or the value, ↩ to
/// keep, ⇥ from the name to the value, esc to leave it.
struct DevDeclarationRow: View {
    let browser: Browser
    let style: DevStyle
    let property: DevProperty
    var italic = false
    var longhand = false
    @State private var hover = false
    @State private var editing: Part?
    @State private var draft = ""
    @State private var before: String?
    /// What the words typed may become, as Chromium's Styles offers it: the
    /// property names, or the keywords of the property, starting so.
    @State private var completions: [String] = []
    @State private var picked = 0
    @FocusState private var focused: Bool
    /// The field shown now has had the keyboard: only then is losing it a
    /// click elsewhere, which keeps the edit.
    @State private var hadFocus = false
    @State private var focusTries = 0
    enum Part { case name, value }

    private var struck: Bool { property.disabled || property.overridden || property.inactive }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ZStack {
                if !property.longhands.isEmpty {
                    Button { browser.workbench?.toggleLonghands(style.id, property.index) } label: {
                        Symbol("chevron.right", size: 6).rotationEffect(.degrees(property.expanded ? 90 : 0)).foregroundStyle(Palette.muted)
                    }.buttonStyle(.plain)
                } else if style.editable, !longhand, hover || property.disabled {
                    Toggle("", isOn: Binding(get: { !property.disabled }, set: { browser.elementsProperty(style, property, enabled: $0) }))
                        .toggleStyle(.checkbox).labelsHidden().controlSize(.mini)
                        .keyTip(property.disabled ? "Turn on" : "Turn off")
                }
            }
            .frame(width: 16, height: 16)
            part(.name, property.name, ConsoleInk.cssName)
            Text(": ").foregroundStyle(Palette.ink)
            if let color = DevSwatch.color(property.value) {
                RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: color)) // design: a 9-point color swatch with Chrome's square corner
                    .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Palette.ink.opacity(0.2), lineWidth: 1)) // design: a 9-point color swatch with Chrome's square corner
                    .frame(width: 9, height: 9).padding(.trailing, 4).padding(.top, 3) // design: the swatch on the words' x-height
                    .contentShape(Rectangle())
                    // A press opens the color picker, as Chromium's swatch does.
                    .onTapGesture { pickColor(color) }
                    .keyTip(style.editable && !longhand ? "Pick a color" : "")
                    .benchSpot("style \(style.selector) \(property.name) swatch")
            }
            part(.value, property.value, Palette.ink)
            Text(";").foregroundStyle(Palette.ink)
            Spacer(minLength: 0)
        }
        .padding(.leading, longhand ? 14 : 0)
        .opacity(property.dim ? 0.45 : 1)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        // Its completions over the rows after it.
        .zIndex(completions.isEmpty ? 0 : 1)
        .onDisappear { DevColorPick.shared.letGo(pickKey) }
    }

    private var pickKey: String { style.id + ":" + String(property.index) }

    private func pickColor(_ color: NSColor) {
        guard style.editable, !longhand else { return }
        DevColorPick.shared.open(pickKey, value: property.value, color: color) { [browser, style, property] value in
            browser.elementsProperty(style, property, name: nil, value: value)
        }
    }

    private func part(_ which: Part, _ words: String, _ color: Color) -> some View {
        // The bench's spot on the part whichever way it shows, so a value
        // left is found where it stands for the next press.
        field(which, words, color)
            .benchSpot("style \(style.selector) \(property.name) \(which == .value ? "value" : "name")")
    }

    @ViewBuilder private func field(_ which: Part, _ words: String, _ color: Color) -> some View {
        if editing == which {
            TextField("", text: $draft)
                .textFieldStyle(.plain).fixedSize()
                .focused($focused)
                .onAppear { focused = true }
                .onSubmit { take(); commit(which) }
                .onExitCommand { if !completions.isEmpty { drop() } else { leave(which) } }
                .onKeyPress(.tab) { take(); commit(which); if which == .name { start(.value) }; return .handled }
                .onKeyPress(keys: [.upArrow, .downArrow], phases: [.down, .repeat]) { press in
                    if !completions.isEmpty {
                        picked = (picked + (press.key == .upArrow ? completions.count - 1 : 1)) % completions.count
                        return .handled
                    }
                    guard which == .value, let next = DevNudge.step(draft, up: press.key == .upArrow, by: DevNudge.amount(press.modifiers)) else { return .ignored }
                    draft = next
                    browser.elementsProperty(style, property, name: nil, value: next)
                    return .handled
                }
                .onChange(of: draft) { _, words in complete(which, words) }
                .onChange(of: focused) {
                    if focused { hadFocus = true; return }
                    guard editing == which else { browser.workbench?.styleEditing = false; return }
                    // A field shown again where one was left with esc or ↩
                    // finds the focus it never let go of in SwiftUI's mind,
                    // and hears it go: not a click elsewhere, the edit only
                    // begun. The keyboard is asked for again, twice at most.
                    if hadFocus { commit(which) } else if focusTries < 2 {
                        focusTries += 1
                        DispatchQueue.main.async { if editing == which { focused = true } }
                    }
                }
                .overlay(alignment: .topLeading) {
                    if !completions.isEmpty {
                        DevCompletionList(typed: draft, completions: completions, picked: picked) { index in
                            picked = index
                            take()
                            commit(which)
                        }
                        .offset(y: 16)
                    }
                }
                .zIndex(1)
        } else {
            Text(words)
                .italic(italic)
                .strikethrough(struck)
                .foregroundStyle(struck ? Palette.muted : color)
                .fixedSize(horizontal: false, vertical: true)
                .onTapGesture { start(which) }
        }
    }

    /// The words typed, asked of WebKit's own CSS completions in the
    /// inspector's page (`elements.complete`): names for a name, the
    /// property's keywords for a value. Nothing for the words the press put
    /// there, or for a number being stepped.
    private func complete(_ which: Part, _ words: String) {
        let wanted = words.trimmingCharacters(in: .whitespaces)
        guard editing == which, wanted != (which == .name ? property.name : before ?? property.value),
              which == .name || DevNudge.step(wanted, up: true, by: 1) == nil else { drop(); return }
        browser.workCall("elements.complete", ["part": which == .name ? "name" : "value", "property": property.name, "prefix": wanted, "max": 12]) { value in
            guard editing == which, draft.trimmingCharacters(in: .whitespaces) == wanted else { return }
            let found = (value as? [String] ?? []).filter { $0 != wanted }
            completions = found
            picked = 0
            browser.workbench?.styleCompletions = found
        }
    }

    /// The completion picked, put in place of the words typed.
    private func take() {
        if picked < completions.count { draft = completions[picked] }
        drop()
    }

    private func drop() {
        completions = []
        browser.workbench?.styleCompletions = []
    }

    private func start(_ which: Part) {
        guard style.editable, !longhand else { return }
        draft = which == .name ? property.name : property.value
        before = property.value
        hadFocus = false
        focusTries = 0
        editing = which
        browser.workbench?.styleEditing = true
    }
    /// esc: the value as it was before ↑ and ↓ changed it, as Chromium's.
    private func leave(_ which: Part) {
        // The focus let go of while the field is still there to give it up.
        focused = false
        editing = nil
        drop()
        browser.workbench?.styleEditing = false
        if which == .value, let before, before != property.value {
            browser.elementsProperty(style, property, name: nil, value: before)
        }
    }
    private func commit(_ which: Part) {
        let words = draft.trimmingCharacters(in: .whitespaces)
        focused = false
        editing = nil
        drop()
        browser.workbench?.styleEditing = false
        guard words != (which == .name ? property.name : property.value) else { return }
        browser.elementsProperty(style, property, name: which == .name ? words : nil, value: which == .value ? words : nil)
    }
}

/// The completions under a Styles name or value being typed, as the
/// console's prompt shows its own: the words typed in bold, the rest after
/// them, the one picked lit; a click takes it.
struct DevCompletionList: View {
    let typed: String
    let completions: [String]
    let picked: Int
    let take: (Int) -> Void

    var body: some View {
        ScrollViewReader { reader in
            ThreadScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(completions.enumerated()), id: \.offset) { index, name in
                        HStack(spacing: 0) {
                            Text(name.hasPrefix(typed) ? typed : "").fontWeight(.semibold)
                            Text(name.hasPrefix(typed) ? String(name.dropFirst(typed.count)) : name)
                        }
                        .font(DevMono.font(11))
                        .foregroundStyle(index == picked ? Color.white : Palette.ink)
                        .padding(.horizontal, 8)
                        .frame(height: 18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(index == picked ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
                        .id(index)
                        .onTapGesture { take(index) }
                    }
                }
                .padding(4)
            }
            .frame(width: 220, height: CGFloat(min(completions.count, 8)) * 18 + 8)
            .onChange(of: picked) { reader.scrollTo(picked) }
        }
        .cardFrame()
        .fixedSize()
    }
}

/// ↑ and ↓ in a value being edited, as Chromium's Styles: the first number
/// in it up or down by 1, ⇧ 10, ⌥ 0.1, ⌘ 100, its unit kept, and applied
/// at once.
enum DevNudge {
    static func amount(_ modifiers: EventModifiers) -> Double {
        modifiers.contains(.command) ? 100 : modifiers.contains(.shift) ? 10 : modifiers.contains(.option) ? 0.1 : 1
    }

    static let number = try! NSRegularExpression(pattern: #"-?(?:\d+\.?\d*|\.\d+)"#)

    static func step(_ value: String, up: Bool, by amount: Double) -> String? {
        let text = value as NSString
        // A number inside a word (h1, translate3d, #1e90ff) isn't one to step.
        let match = number.matches(in: value, range: NSRange(location: 0, length: text.length)).first { match in
            guard match.range.location > 0, let ahead = text.substring(with: NSRange(location: match.range.location - 1, length: 1)).first else { return true }
            return !(ahead.isLetter || ahead.isNumber || ahead == "#" || ahead == "-" || ahead == "_")
        }
        guard let match, let found = Double(text.substring(with: match.range)) else { return nil }
        let next = ((found + (up ? amount : -amount)) * 10).rounded() / 10
        let words = next == next.rounded() ? String(Int(next)) : String(format: "%.1f", next)
        return text.replacingCharacters(in: match.range, with: words)
    }
}

/// The colors a value names, for the square before it: #hex, rgb(), hsl()
/// and named colors, through the page's own parser so it agrees with it.
/// The swatch's color picker: macOS's color panel, where Chrome opens its
/// own, the value's color changed as the panel's is, written the way the
/// value wrote it (#hex, rgb() or hsl()).
@MainActor final class DevColorPick: NSObject {
    static let shared = DevColorPick()
    private var key = ""
    private var value = ""
    private var token = ""
    private var apply: ((String) -> Void)?
    private var sent = 0

    func open(_ key: String, value: String, color: NSColor, apply: @escaping (String) -> Void) {
        self.key = key
        self.value = value
        token = DevSwatch.token(in: value) ?? value.trimmingCharacters(in: .whitespaces)
        self.apply = apply
        let panel = NSColorPanel.shared
        panel.setTarget(nil)
        panel.showsAlpha = true
        panel.isContinuous = true
        panel.color = color
        panel.setTarget(self)
        panel.setAction(#selector(changed(_:)))
        panel.orderFront(nil)
    }

    /// The row the panel was opened for went away (another element, the
    /// card shut): the panel no longer writes into it.
    func letGo(_ key: String) {
        guard key == self.key else { return }
        self.key = ""
        apply = nil
        sent += 1
        if NSColorPanel.sharedColorPanelExists { NSColorPanel.shared.setTarget(nil) }
    }

    @objc func changed(_ panel: NSColorPanel) {
        guard apply != nil, let color = panel.color.usingColorSpace(.sRGB) else { return }
        let written = DevSwatch.write(color, like: token)
        guard written != token else { return }
        if let range = value.range(of: token) { value.replaceSubrange(range, with: written) } else { value = written }
        token = written
        // A drag over the panel sends many: one each few milliseconds goes
        // to the page, and the last one always.
        sent += 1
        let serial = sent, next = value, now = CACurrentMediaTime()
        if now - applied >= Self.gap {
            applied = now
            apply?(next)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.gap - (now - applied)) { [weak self] in
            guard let self, self.sent == serial else { return }
            self.applied = CACurrentMediaTime()
            self.apply?(next)
        }
    }
    private var applied: CFTimeInterval = 0
    private static let gap: CFTimeInterval = 0.03
}

enum DevSwatch {
    /// The color written in a value: `#c0ffee`, `rgb(…)`, `hsl(…)`.
    static func token(in value: String) -> String? {
        value.range(of: #"#[0-9a-fA-F]{3,8}\b|rgba?\([^)]*\)|hsla?\([^)]*\)"#, options: .regularExpression).map { String(value[$0]) }
    }

    /// A color written as `like` is: rgb() or hsl() for those, #hex for the
    /// rest; the alpha only where it isn't whole.
    static func write(_ color: NSColor, like: String) -> String {
        let r = color.redComponent, g = color.greenComponent, b = color.blueComponent, a = color.alphaComponent
        let alpha = (a * 100).rounded() / 100
        func n(_ x: Double) -> String { x == x.rounded() ? String(Int(x)) : String(format: "%g", x) }
        if like.hasPrefix("rgb") {
            let parts = [r, g, b].map { String(Int(($0 * 255).rounded())) }.joined(separator: ", ")
            return alpha < 1 ? "rgba(\(parts), \(n(alpha)))" : "rgb(\(parts))"
        }
        if like.hasPrefix("hsl") {
            let most = max(r, g, b), least = min(r, g, b), light = (most + least) / 2
            let chroma = most - least
            var hue = 0.0
            if chroma > 0 {
                hue = most == r ? (g - b) / chroma : most == g ? (b - r) / chroma + 2 : (r - g) / chroma + 4
                hue = (hue * 60).truncatingRemainder(dividingBy: 360); if hue < 0 { hue += 360 }
            }
            let saturation = chroma == 0 ? 0 : chroma / (1 - abs(2 * light - 1))
            let parts = "\(Int(hue.rounded())), \(Int((saturation * 100).rounded()))%, \(Int((light * 100).rounded()))%"
            return alpha < 1 ? "hsla(\(parts), \(n(alpha)))" : "hsl(\(parts))"
        }
        let hex = [r, g, b].map { String(format: "%02x", Int(($0 * 255).rounded())) }.joined()
        return "#" + hex + (alpha < 1 ? String(format: "%02x", Int((a * 255).rounded())) : "")
    }

    static func color(_ value: String) -> NSColor? {
        guard let found = token(in: value) else {
            return named[value.lowercased()]
        }
        if found.hasPrefix("#") { return NSColor(hex: found) }
        let numbers = found.split(whereSeparator: { !"0123456789.%".contains($0) }).compactMap { Double($0.replacingOccurrences(of: "%", with: "")) }
        guard numbers.count >= 3 else { return nil }
        let alpha = numbers.count > 3 ? (numbers[3] > 1 ? numbers[3] / 100 : numbers[3]) : 1
        if found.hasPrefix("rgb") { return NSColor(srgbRed: numbers[0] / 255, green: numbers[1] / 255, blue: numbers[2] / 255, alpha: alpha) }
        // hsl(): hue, saturation and lightness, not NSColor's brightness.
        let light = numbers[2] / 100, chroma = (1 - abs(2 * light - 1)) * numbers[1] / 100
        let hue = numbers[0].truncatingRemainder(dividingBy: 360) / 60, x = chroma * (1 - abs(hue.truncatingRemainder(dividingBy: 2) - 1))
        let (r, g, b): (Double, Double, Double) = hue < 1 ? (chroma, x, 0) : hue < 2 ? (x, chroma, 0) : hue < 3 ? (0, chroma, x) : hue < 4 ? (0, x, chroma) : hue < 5 ? (x, 0, chroma) : (chroma, 0, x)
        let m = light - chroma / 2
        return NSColor(srgbRed: r + m, green: g + m, blue: b + m, alpha: alpha)
    }
    private static let named: [String: NSColor] = ["black": .black, "white": .white, "red": .red, "green": NSColor(srgbRed: 0, green: 0.5, blue: 0, alpha: 1), "blue": .blue, "transparent": .clear, "gray": .gray, "grey": .gray, "orange": .orange, "yellow": .yellow, "purple": .purple]
}

/// The box model, as Chromium draws it at the foot of Styles and the head
/// of Computed: margin, border, padding round the content, each side's
/// size where it stands.
struct DevBoxModel: View {
    @Bindable var model: DevWorkbench

    var body: some View {
        layer("margin", "margin", Color(nsColor: NSColor(srgbRed: 0.98, green: 0.8, blue: 0.62, alpha: 1)), dashed: true) {
            layer("border", "border", Color(nsColor: NSColor(srgbRed: 0.99, green: 0.87, blue: 0.61, alpha: 1)), dashed: false, suffix: "-width") {
                layer("padding", "padding", Color(nsColor: NSColor(srgbRed: 0.76, green: 0.82, blue: 0.55, alpha: 1)), dashed: true) {
                    Text("\(DevBoxModel.number(css("width")))×\(DevBoxModel.number(css("height")))")
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color(nsColor: NSColor(srgbRed: 0.55, green: 0.71, blue: 0.75, alpha: 1)))
                        .overlay(Rectangle().strokeBorder(Color.black.opacity(0.4), lineWidth: 1))
                }
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(Color.black.opacity(0.85))
        .monospacedDigit()
        .fixedSize()
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    private func layer<Inner: View>(_ title: String, _ prefix: String, _ fill: Color, dashed: Bool, suffix: String = "", @ViewBuilder _ inner: () -> Inner) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 8) {
                Text(title)
                Spacer(minLength: 0)
                Text(value(prefix, "top", suffix))
                Spacer(minLength: 0)
                Text(title).hidden()
            }
            HStack(spacing: 6) {
                Text(value(prefix, "left", suffix))
                inner()
                Text(value(prefix, "right", suffix))
            }
            Text(value(prefix, "bottom", suffix))
        }
        .padding(.horizontal, 8).padding(.vertical, 2)
        .background(fill)
        .overlay(Rectangle().strokeBorder(Color.black.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: dashed ? [3, 2] : [])))
    }

    private func value(_ prefix: String, _ side: String, _ suffix: String) -> String {
        DevBoxModel.number(css("\(prefix)-\(side)\(suffix)"))
    }
    private func css(_ name: String) -> String { model.computed.first { $0.name == name }?.value ?? "0" }
    /// `20px` as 20, `416.5px` as 416.5, three places at most as Chromium.
    static func number(_ css: String) -> String {
        guard let value = Double(css.replacingOccurrences(of: "px", with: "")) else { return css }
        return value.formatted(.number.precision(.fractionLength(0...3)).grouping(.never))
    }
}

/// The filter field of Elements' panes: the console's, a funnel and words.
struct DevFilterField: View {
    @Binding var text: String
    var prompt = "Filter"

    var body: some View {
        HStack(spacing: 4) {
            Symbol("line.3.horizontal.decrease", size: 10).foregroundStyle(Palette.muted)
            TextField(prompt, text: $text).textFieldStyle(.plain).font(.system(size: 11.5))
            if !text.isEmpty {
                Button { text = "" } label: { Symbol("xmark.circle.fill", size: 10).foregroundStyle(Palette.muted) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6)
        .frame(minWidth: 60, maxWidth: .infinity)
        .frame(height: ButtonSize.small.height)
        .background(Palette.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }
}

// MARK: - Computed

struct DevComputedPane: View {
    let browser: Browser
    @Bindable var model: DevWorkbench
    private var filter: String { model.paneFilters["computed"] ?? "" }
    private var filterText: Binding<String> { Binding(get: { model.paneFilters["computed"] ?? "" }, set: { model.paneFilters["computed"] = $0 }) }
    @AppStorage("devComputedAll", store: Store.settings) private var all = false
    @AppStorage("devComputedGroup", store: Store.settings) private var group = false
    @State private var open: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            DevPanelBar {
                DevFilterField(text: filterText)
                Toggle("Show all", isOn: $all).toggleStyle(.checkbox).font(.system(size: 11.5)).fixedSize()
                Toggle("Group", isOn: $group).toggleStyle(.checkbox).font(.system(size: 11.5)).fixedSize()
            }
            Divider()
            ThreadScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    DevBoxModel(model: model)
                    if group {
                        ForEach(DevComputedPane.groups, id: \.self) { title in
                            let rows = shown.filter { DevComputedPane.group(of: $0.name) == title }
                            if !rows.isEmpty {
                                Text(title).font(.system(size: 11, weight: .semibold))
                                    .padding(.horizontal, 8).frame(height: 22).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Palette.ink.opacity(0.025))
                                ForEach(rows) { row($0) }
                            }
                        }
                    } else {
                        ForEach(shown) { row($0) }
                    }
                }
                .padding(.bottom, 8)
            }
        }
    }

    private var shown: [DevProperty] {
        model.computed.filter { (all || model.computedFrom[$0.name] != nil || model.computedSet.contains($0.name)) && (filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) || $0.value.localizedCaseInsensitiveContains(filter)) }
    }

    @ViewBuilder private func row(_ property: DevProperty) -> some View {
        let from = model.computedFrom[property.name]
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                Symbol("chevron.right", size: 6).foregroundStyle(Palette.muted)
                    .rotationEffect(.degrees(open.contains(property.name) ? 90 : 0))
                    .frame(width: 14, height: 16).opacity(from == nil ? 0 : 1)
                Text(property.name).foregroundStyle(ConsoleInk.cssName).lineLimit(1).truncationMode(.tail)
                    .frame(width: 180, alignment: .leading)
                Text(property.value).foregroundStyle(Palette.ink).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
            .onTapGesture { if from != nil { if open.contains(property.name) { open.remove(property.name) } else { open.insert(property.name) } } }
            if let from, open.contains(property.name) {
                HStack(spacing: 8) {
                    Text(from.value).foregroundStyle(Palette.ink)
                    Text(from.selector).foregroundStyle(Palette.muted).lineLimit(1)
                    Spacer(minLength: 4)
                    if from.origin == "user-agent" {
                        Text("user agent stylesheet").italic().foregroundStyle(Palette.muted).lineLimit(1)
                    } else if !from.source.isEmpty {
                        Button { browser.elementsOpenSource(from.source, line: from.line) } label: {
                            Text(DevStyle.place(from.source, line: from.line, page: browser.toolsFront?.address)).underline().foregroundStyle(Palette.muted).lineLimit(1)
                        }.buttonStyle(.plain)
                    }
                }
                .padding(.leading, 28).padding(.trailing, 8) // design: the trace stands under the property's name, as Chromium's
            }
        }
        .font(DevMono.font(11))
        .padding(.horizontal, 8)
        .frame(minHeight: 16)
    }

    static let groups = ["Layout", "Text", "Appearance", "Other"]
    static func group(of name: String) -> String {
        let layout = ["display", "position", "width", "height", "min-", "max-", "margin", "padding", "top", "left", "right", "bottom", "inset", "flex", "grid", "gap", "row-gap", "column-gap", "align", "justify", "place", "order", "float", "clear", "overflow", "box-sizing", "z-index", "aspect-ratio", "contain", "block-size", "inline-size"]
        let text = ["font", "line-height", "text", "letter-spacing", "word", "white-space", "-webkit-locale", "direction", "unicode-bidi", "writing-mode", "hyphens", "tab-size", "quotes", "vertical-align"]
        let appearance = ["color", "background", "border", "outline", "opacity", "box-shadow", "visibility", "cursor", "filter", "backdrop", "transform", "transition", "animation", "mix-blend", "clip", "mask", "accent-color", "caret", "fill", "stroke"]
        if layout.contains(where: { name.hasPrefix($0) }) { return "Layout" }
        if text.contains(where: { name.hasPrefix($0) }) { return "Text" }
        if appearance.contains(where: { name.hasPrefix($0) }) { return "Appearance" }
        return "Other"
    }
}

// MARK: - Layout

struct DevLayoutPane: View {
    let browser: Browser
    @Bindable var model: DevWorkbench
    @AppStorage("devGridLabels", store: Store.settings) private var labels = "numbers"
    @AppStorage("devGridTracks", store: Store.settings) private var tracks = false
    @AppStorage("devGridAreas", store: Store.settings) private var areas = false
    @AppStorage("devGridExtend", store: Store.settings) private var extend = false

    var body: some View {
        ThreadScrollView {
            VStack(alignment: .leading, spacing: 0) {
                section("Grid") {
                    Text("Overlay display settings").font(.system(size: 11.5, weight: .semibold))
                    Picker("", selection: $labels) {
                        Text("Show line numbers").tag("numbers"); Text("Show line names").tag("names"); Text("Hide line labels").tag("none")
                    }.labelsHidden().fixedSize()
                    Toggle("Show track sizes", isOn: $tracks).toggleStyle(.checkbox)
                    Toggle("Show area names", isOn: $areas).toggleStyle(.checkbox)
                    Toggle("Extend grid lines", isOn: $extend).toggleStyle(.checkbox)
                    boxes("grid", none: "No grid layouts on this page")
                }
                section("Flexbox") { boxes("flex", none: "No flexbox layouts on this page") }
            }
            .font(.system(size: 11.5))
        }
        .onChange(of: [labels, String(tracks), String(areas), String(extend)]) { browser.elementsOverlaysRedraw() }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 11.5, weight: .semibold))
                .padding(.horizontal, 8).frame(height: 24).frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.ink.opacity(0.025))
            Divider()
            VStack(alignment: .leading, spacing: 6) { content() }.padding(8)
            Divider()
        }
    }

    @ViewBuilder private func boxes(_ kind: String, none: String) -> some View {
        let list = model.layoutBoxes.filter { $0.kind == kind }
        if list.isEmpty {
            Text(none).foregroundStyle(Palette.muted)
        } else {
            ForEach(list) { box in
                HStack(spacing: 6) {
                    Toggle("", isOn: Binding(get: { model.overlays.contains(box.id) }, set: { browser.elementsOverlay(box, on: $0) }))
                        .toggleStyle(.checkbox).labelsHidden()
                    Button { browser.elementsSelect(box.id) } label: {
                        Text(box.label).font(DevMono.font(11)).foregroundStyle(ConsoleInk.tag)
                    }.buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Event Listeners

struct DevListenersPane: View {
    let browser: Browser
    @Bindable var model: DevWorkbench
    @AppStorage("devListenersAncestors", store: Store.settings) private var ancestors = true
    @AppStorage("devListenersKind", store: Store.settings) private var kind = "All"
    @State private var closed: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            DevPanelBar {
                Button { browser.elementsSideLoad() } label: { Symbol("arrow.clockwise", size: 10) }
                    .buttonStyle(.yab(.quiet, .small, icon: .square)).keyTip("Refresh")
                Toggle("Ancestors", isOn: $ancestors).toggleStyle(.checkbox).font(.system(size: 11.5)).fixedSize()
                Picker("", selection: $kind) { Text("All").tag("All"); Text("Passive").tag("Passive"); Text("Blocking").tag("Blocking") }
                    .labelsHidden().fixedSize().font(.system(size: 11.5))
                Spacer(minLength: 0)
            }
            Divider()
            if rows.isEmpty {
                VStack(spacing: 4) {
                    Text("No event listeners").font(.system(size: 12, weight: .semibold))
                    Text("Listeners the page adds to this element\(ancestors ? " or its ancestors" : "") show here.").font(.system(size: 11.5)).foregroundStyle(Palette.muted)
                }
                .multilineTextAlignment(.center).padding(16).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ThreadScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(types, id: \.self) { type in
                            Button { if closed.contains(type) { closed.remove(type) } else { closed.insert(type) } } label: {
                                HStack(spacing: 4) {
                                    Symbol("chevron.right", size: 6).rotationEffect(.degrees(closed.contains(type) ? 0 : 90)).foregroundStyle(Palette.muted).frame(width: 12)
                                    Text(type).font(DevMono.font(11, weight: .semibold))
                                    Spacer()
                                }.contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 8).frame(height: 22)
                            .background(Palette.ink.opacity(0.025))
                            if !closed.contains(type) { ForEach(rows.filter { $0.type == type }) { listener($0) } }
                        }
                    }
                }
            }
        }
    }

    private var rows: [DevListener] {
        model.listenerRows.filter { (ancestors || $0.ownerID == model.selectedNode) && (kind == "All" || (kind == "Passive") == $0.passive) }
    }
    private var types: [String] { Array(Set(rows.map(\.type))).sorted() }

    private func listener(_ row: DevListener) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { !row.disabled }, set: { browser.elementsListener(row, enabled: $0) }))
                .toggleStyle(.checkbox).labelsHidden().keyTip(row.disabled ? "Turn on" : "Turn off")
            Text(row.owner).foregroundStyle(ConsoleInk.tag).lineLimit(1)
            ForEach(row.marks, id: \.self) { mark in Text(mark).foregroundStyle(Palette.muted) }
            Spacer(minLength: 4)
            if !row.url.isEmpty {
                Button { browser.elementsOpenSource(row.url, line: row.line) } label: {
                    Text((row.handler.isEmpty ? "" : row.handler + " ") + DevStyle.place(row.url, line: row.line, page: browser.toolsFront?.address))
                        .underline().foregroundStyle(Palette.muted).lineLimit(1).truncationMode(.middle)
                }.buttonStyle(.plain)
            } else if !row.handler.isEmpty {
                Text(row.handler).foregroundStyle(Palette.muted).lineLimit(1)
            }
        }
        .font(DevMono.font(11))
        .padding(.leading, 24).padding(.trailing, 8) // design: a listener stands a step in under its event's row
        .frame(minHeight: 20)
    }
}

// MARK: - DOM Breakpoints

struct DevBreaksPane: View {
    let browser: Browser
    @Bindable var model: DevWorkbench

    var body: some View {
        if model.domBreaks.isEmpty {
            VStack(spacing: 4) {
                Text("No DOM breakpoints").font(.system(size: 12, weight: .semibold))
                Text("Pause when an element or its children change: right-click a node, then Break on.").font(.system(size: 11.5)).foregroundStyle(Palette.muted)
            }
            .multilineTextAlignment(.center).padding(16).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ThreadScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.domBreaks) { mark in
                        HStack(spacing: 8) {
                            Toggle("", isOn: Binding(get: { mark.enabled }, set: { browser.elementsBreakEnable(mark, on: $0) }))
                                .toggleStyle(.checkbox).labelsHidden()
                            VStack(alignment: .leading, spacing: 2) {
                                Button { browser.elementsSelect(mark.node) } label: {
                                    Text(mark.label).font(DevMono.font(11)).foregroundStyle(ConsoleInk.tag)
                                }.buttonStyle(.plain)
                                Text(DevDOMBreak.kinds.first { $0.type == mark.type }?.title ?? mark.type).font(.system(size: 11.5)).foregroundStyle(Palette.muted)
                            }
                            Spacer()
                            Button { browser.elementsBreak(mark.node, mark.type, on: false) } label: { Symbol("xmark", size: 9) }
                                .buttonStyle(.yab(.quiet, .small, icon: .square)).keyTip("Remove breakpoint")
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        Divider()
                    }
                }
            }
        }
    }
}

// MARK: - Properties

struct DevPropertiesPane: View {
    let browser: Browser
    @Bindable var model: DevWorkbench
    private var filter: String { model.paneFilters["properties"] ?? "" }
    private var filterText: Binding<String> { Binding(get: { model.paneFilters["properties"] ?? "" }, set: { model.paneFilters["properties"] = $0 }) }
    @AppStorage("devPropertiesAll", store: Store.settings) private var all = false

    var body: some View {
        VStack(spacing: 0) {
            DevPanelBar {
                DevFilterField(text: filterText)
                Toggle("Show all", isOn: $all).toggleStyle(.checkbox).font(.system(size: 11.5)).fixedSize()
            }
            Divider()
            ThreadScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.nodeProperties.filter(shows)) { row in DevPropertyRow(browser: browser, row: row) }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func shows(_ row: DevNodeProperty) -> Bool {
        (all || !row.quiet) && (filter.isEmpty || row.name.localizedCaseInsensitiveContains(filter))
    }
}

private struct DevPropertyRow: View {
    let browser: Browser
    let row: DevNodeProperty
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                Symbol("chevron.right", size: 6).foregroundStyle(Palette.muted)
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .frame(width: 14, height: 16).opacity(row.object == nil ? 0 : 1)
                Text(row.name).foregroundStyle(ConsoleInk.property).fontWeight(row.own ? .semibold : .regular)
                Text(": ").foregroundStyle(Palette.ink)
                Text(row.preview).foregroundStyle(row.color).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture { if row.object != nil { open.toggle() } }
            if open, let object = row.object {
                ConsoleTree(browser: browser, value: object, depth: 1).padding(.leading, 14) // design: an object's tree a step in, as the console's
            }
        }
        .font(DevMono.font(11))
        .padding(.horizontal, 8)
    }
}

// MARK: - Accessibility

struct DevAccessibilityPane: View {
    let browser: Browser
    @Bindable var model: DevWorkbench

    var body: some View {
        let node = model.node(model.selectedNode)
        let aria = (node?.attrs ?? []).filter { $0.first == "role" || $0.first?.hasPrefix("aria-") == true }
        ThreadScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Toggle("Show accessibility tree", isOn: $model.axTreeShown).toggleStyle(.switch).controlSize(.mini)
                }
                .font(.system(size: 11.5)).padding(8)
                Divider()
                section("ARIA Attributes") {
                    if aria.isEmpty { Text("No ARIA attributes").foregroundStyle(Palette.muted) }
                    ForEach(aria, id: \.self) { pair in
                        HStack(spacing: 6) {
                            Text(pair[0] + ":").foregroundStyle(ConsoleInk.cssName)
                            Text(pair.count > 1 ? pair[1] : "").foregroundStyle(Palette.ink)
                        }.font(DevMono.font(11))
                    }
                }
                section("Computed Properties") {
                    VStack(alignment: .leading, spacing: 2) {
                        line("Name", "\"\(model.ax["label"] as? String ?? "")\"")
                        ForEach(["aria-labelledby", "aria-label"], id: \.self) { from in
                            let set = node?.attribute(from)
                            HStack(spacing: 6) {
                                Text(from + ":").foregroundStyle(Palette.muted)
                                if let set { Text("\"\(set)\"").foregroundStyle(ConsoleInk.string) } else { Text("Not specified").italic().foregroundStyle(Palette.muted) }
                            }.padding(.leading, 14) // design: aria-labelledby and aria-label a step in under Name, as Chromium's
                        }
                        line("Role", model.ax["role"] as? String ?? "")
                        ForEach(DevAccessibilityPane.flags.indices, id: \.self) { at in
                            let key = DevAccessibilityPane.flags[at].0, title = DevAccessibilityPane.flags[at].1
                            if let value = model.ax[key], DevWorkbench.string(value) != "false", DevWorkbench.string(value) != "" {
                                line(title, DevWorkbench.string(value))
                            }
                        }
                        if model.ax["exists"] as? Bool == false { Text("Not in the accessibility tree").italic().foregroundStyle(Palette.muted) }
                    }
                    .font(DevMono.font(11))
                }
            }
            .font(.system(size: 11.5))
        }
    }

    static let flags: [(String, String)] = [("focused", "Focused"), ("disabled", "Disabled"), ("required", "Required"), ("checked", "Checked"), ("pressed", "Pressed"), ("selected", "Selected"), ("expanded", "Expanded"), ("headingLevel", "Level"), ("hierarchyLevel", "Level"), ("invalid", "Invalid"), ("liveRegionStatus", "Live region"), ("hidden", "Hidden"), ("ignored", "Ignored"), ("busy", "Busy"), ("readonly", "Read-only")]

    private func line(_ name: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(name + ":").foregroundStyle(ConsoleInk.cssName)
            Text(value).foregroundStyle(Palette.ink)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 11.5, weight: .semibold))
                .padding(.horizontal, 8).frame(height: 24).frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.ink.opacity(0.025))
            Divider()
            VStack(alignment: .leading, spacing: 4) { content() }.padding(8)
            Divider()
        }
    }
}

private extension String { var nonempty: String? { isEmpty ? nil : self } }
