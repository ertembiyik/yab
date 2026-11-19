import LocalAuthenticationEmbeddedUI
import SwiftUI

// The pay sheet, in the chat field's place: Apple Pay's shape on Liquid
// Glass, never its name. The merchant and what is bought, the card and where
// it goes, the total large, and in the foot Cancel and Pay. Rare and
// high-stakes, so it takes the care: one surface whose contents are replaced
// (a list, a form) and whose height follows, and one button that says what
// happens, in place and at one width: Pay $42.10 with ⌘↩, which pays
// nothing but arms the check; then Touch ID, where the finger goes, a line
// over the buttons saying what to do; then Paying on the site, then Paid in
// green with the order. Only a finger (or the Mac's password) pays; ⌘↩
// never does. Always here never shows.
//
// Measurements (spec "Pay"): radius 26 with a 6 inset, so its group of rows
// is 18; the favicon 28; rows 44; the total 30 semibold, tabular; the foot's
// buttons regular (28), Touch ID's mark 16.

struct PaySheet: View {
    @Bindable var flow: PayFlow
    var tab: Tab
    /// Inside a plate of its own (the page's dock): no glass of its own.
    var embedded = false
    @Environment(\.accessibilityReduceMotion) private var still
    /// The shown pane's height: the sheet follows it.
    @State private var height: CGFloat = 0

    private var model: PaySheetModel { flow.model }

    var body: some View {
        ZStack(alignment: .top) {
            pane(model.pane)
                .id(model.pane)
                .transition(still ? .opacity : .asymmetric(insertion: .opacity.combined(with: .offset(y: 6)),
                                                           removal: .opacity.animation(Motion.depart)))
        }
        .frame(height: height > 0 ? height : nil, alignment: .top)
        .padding(.horizontal, 6)
        .padding(.top, 6)
        .padding(.bottom, 12)
        .background {
            if !embedded {
                FieldGlass(shape: RoundedRectangle(cornerRadius: Radius.box, style: .continuous), lifted: true)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: Radius.box, style: .continuous))
        .animation(still ? Motion.quick : Motion.reshape, value: model.pane)
        .onAppear { flow.listen() }
        .onDisappear { flow.touch.stop() }
    }

    @ViewBuilder private func pane(_ pane: PaySheetModel.Pane) -> some View {
        Group {
            switch pane {
            case .main: main
            case .cards, .places: PayList(flow: flow, pane: pane)
            case .newPlace, .newCard: PayForm(flow: flow, pane: pane)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { new in
            // Only the pane coming in sets the height; the one leaving
            // fades over it meanwhile.
            guard pane == flow.model.pane, abs(new - height) > 0.5 else { return }
            if height == 0 || still { height = new } else { withAnimation(Motion.reshape) { height = new } }
        }
    }

    // MARK: - the sheet itself

    private var main: some View {
        VStack(spacing: 0) {
            PayHead(site: model.site, item: model.item, icon: tab.icon)
            PayRows(flow: flow)
            if model.showsTotal {
                PayTotal(word: model.totalWord, amount: model.amount)
                PayFoot(flow: flow, touch: flow.touch)
            }
        }
    }
}

// MARK: - the head

private struct PayHead: View {
    let site: String
    let item: String
    var icon: NSImage?

    var body: some View {
        // Cancel is in the foot, beside Pay.
        HStack(spacing: 10) {
            SiteMark(host: site, size: 28, icon: icon)
            PayTitle(title: site, detail: item)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }
}

/// A head's two lines: the name, and what it is about.
private struct PayTitle: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 14, weight: .semibold)) // design: the sheet's head, as drawn (spec "Pay")
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
            if !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
            }
        }
    }
}

/// The back chevron and a list's or a form's name.
private struct PayBackHead: View {
    let title: String
    let detail: String
    let back: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: back) { Symbol("chevron.left", size: 10.5, weight: .semibold) }
                .buttonStyle(.yab(.secondary, .regular, icon: .round))
                .keyTip("Back", keys: "esc")
            PayTitle(title: title, detail: detail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }
}

// MARK: - the card and where it goes

/// The rows' group: its corner the sheet's less the sheet's inset and its own.
private struct PayGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .padding(.horizontal, 4)
            .background(Palette.ink.opacity(0.035), in: RoundedRectangle(cornerRadius: Radius.window, style: .continuous)) // design: 26 less 6 less 2, concentric with the sheet
    }
}

private struct PayRows: View {
    @Bindable var flow: PayFlow

    var body: some View {
        let model = flow.model
        let declined = model.phase == .declined
        PayGroup {
            PayRow(lead: { PayMark(kind: model.chosenCard?.brand ?? "", height: 20) },
                   title: model.chosenCard?.title ?? "Card on \(model.site)",
                   detail: declined ? "Declined by \(model.site)" : model.chosenCard?.name ?? "",
                   bad: declined, opens: model.cardOpens) { flow.open(.cards) }
            PayRule()
            PayRow(lead: { PayLead(name: model.chosenPlace?.mark ?? "house") },
                   title: model.chosenPlace?.line ?? "Address on \(model.site)",
                   detail: model.delivery.isEmpty ? model.chosenPlace?.who ?? "" : model.delivery,
                   bad: false, opens: model.placeOpens) { flow.open(.places) }
        }
    }
}

/// One row of the group: what leads it, two lines, and a chevron while a
/// click opens a list.
private struct PayRow<Lead: View>: View {
    @ViewBuilder let lead: Lead
    let title: String
    let detail: String
    var bad = false
    var opens = false
    var lit = false
    var tick = false
    /// The words' ink where it isn't the ink: an "Add…" row's accent.
    var tint: Color? = nil
    /// In a list: the row is a choice, with no chevron, only the tick.
    var choice = false
    let action: () -> Void
    @State private var over = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                lead.frame(width: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13))
                        .foregroundStyle(bad ? PayInk.bad : tint ?? Palette.ink)
                        .lineLimit(1)
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 11.5))
                            .foregroundStyle(bad ? PayInk.bad : Palette.muted)
                            .lineLimit(1)
                            .contentTransition(.opacity)
                    }
                }
                Spacer(minLength: 0)
                if tick {
                    Symbol("checkmark", size: 11, weight: .semibold)
                        .foregroundStyle(Color.accentColor)
                } else if opens, !choice {
                    Symbol("chevron.right", size: 9.5, weight: .semibold)
                        .foregroundStyle(bad ? PayInk.bad : Palette.muted)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 44)
            .background(Palette.ink.opacity(lit ? 0.06 : over && opens ? 0.04 : 0),
                        in: RoundedRectangle(cornerRadius: Radius.floating, style: .continuous)) // design: concentric inside the group's 18, 4 in
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Not dimmed while it can't open: it still says what is paid with.
        .allowsHitTesting(opens)
        .onHover { over = $0 }
        .animation(Motion.arrive, value: opens)
        .animation(Motion.arrive, value: bad)
    }
}

private struct PayRule: View {
    var body: some View {
        Rectangle()
            .fill(Palette.ink.opacity(0.08))
            .frame(height: 0.5)
            .padding(.leading, 40) // design: under the words, past the 30 pt lead and its gap
            .padding(.trailing, 10) // design: the rule ends where the words do
    }
}

/// An address's mark, or a list's plus, in the lead's 30.
private struct PayLead: View {
    let name: String
    var tint: Color = Palette.muted

    var body: some View {
        Symbol(name, size: 12)
            .foregroundStyle(tint)
    }
}

// MARK: - the total

private struct PayTotal: View {
    let word: String
    let amount: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(word)
                .font(.system(size: 13))
                .foregroundStyle(Palette.muted)
                .id(word)
                .transition(.opacity)
            Spacer(minLength: 12)
            // A new total rolls digit by digit; Paid keeps it still.
            Text(amount)
                .font(.system(size: 30, weight: .semibold)) // design: the total, as drawn (spec "Pay")
                .monospacedDigit()
                .tracking(-0.6)
                .foregroundStyle(Palette.ink)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 12)
        .padding(.top, 14) // design: the total's air above, as drawn
        .padding(.bottom, 4)
        .animation(Motion.reshape, value: amount)
        .animation(Motion.arrive, value: word)
    }
}

// MARK: - the foot: Pay, then Touch ID

/// A line over the buttons when there is something to say, then Cancel and
/// the one button, pinned to the sheet's trailing edge: neither moves nor
/// changes width from Pay to Touch ID to Paid.
private struct PayFoot: View {
    @Bindable var flow: PayFlow
    var touch: PayTouch
    private var confirmation = Keymap.shared.slot(.confirmDanger)

    var body: some View {
        let model = flow.model
        VStack(alignment: .leading, spacing: 10) {
            if let line = model.line {
                Text(line)
                    .font(.system(size: 12))
                    .foregroundStyle(model.lineBad ? PayInk.bad : Palette.muted)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentTransition(.opacity)
                    .transition(.opacity)
            }
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Button { flow.cancel() } label: {
                    HStack(spacing: 6) {
                        Text("Cancel")
                        KeyGlyphs(keys: "esc", size: ButtonSize.regular.wordSize, tint: nil, rest: 0.6)
                            .transaction { $0.animation = nil }
                    }
                }
                .buttonStyle(.yab(.secondary, .regular))
                // Dimmed, not gone, once the yes is given: nothing beside it moves.
                .disabled(!model.cancellable)
                PayButton(flow: flow, touch: touch, keys: confirmation.keys?.text)
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 16)
        .animation(Motion.arrive, value: model.phase)
        .animation(Motion.arrive, value: model.line)
    }
}

/// The one button: Pay with its keys, then, pressed, Touch ID where the
/// finger goes (Use Password after three that didn't match), then Paying,
/// then Paid in green. Every face sits over hidden twins of all of them, so
/// it holds the widest one's width throughout. A finger that didn't match
/// shakes it, ±5 pt.
private struct PayButton: View {
    @Bindable var flow: PayFlow
    var touch: PayTouch
    let keys: String?
    @Environment(\.accessibilityReduceMotion) private var still

    var body: some View {
        let model = flow.model
        Button { flow.press() } label: {
            ZStack {
                ForEach(PaySheetModel.Face.allCases, id: \.self) { face in
                    words(face, model, live: false).hidden()
                }
                words(model.face, model, live: true)
                    .id(model.face)
                    .transition(.opacity)
            }
        }
        .buttonStyle(.yab(.primary, .regular, tint: model.face == .paid ? PayInk.good : nil))
        .allowsHitTesting(model.face == .pay || model.face == .password)
        .modifier(PayShake(count: still ? 0 : CGFloat(model.shakes)))
        .animation(still ? nil : .linear(duration: 0.36), value: model.shakes)
        .animation(Motion.quick, value: model.face)
        .accessibilityLabel(model.words(model.face))
    }

    @ViewBuilder private func words(_ face: PaySheetModel.Face, _ model: PaySheetModel, live: Bool) -> some View {
        HStack(spacing: 6) {
            switch face {
            case .pay, .password:
                Text(model.words(face))
                if let keys {
                    KeyGlyphs(keys: keys, size: ButtonSize.regular.wordSize, tint: nil, rest: 0.6)
                        .transaction { $0.animation = nil }
                }
            case .touch:
                PayTouchMark(touch: touch, live: live && model.listening)
                Text(model.words(face))
            case .checking, .paying:
                PayArc()
                Text(model.words(face))
            case .paid:
                Symbol("checkmark", size: 10.5, weight: .semibold)
                Text(model.words(face))
            }
        }
        .monospacedDigit()
    }
}

/// Touch ID's mark on the armed button, breathing while it listens (still
/// under Reduce Motion): the system's own glyph (LAAuthenticationView),
/// whose context is the one listening, or the symbol where there is none.
private struct PayTouchMark: View {
    var touch: PayTouch
    let live: Bool
    @Environment(\.accessibilityReduceMotion) private var still
    @State private var low = false

    var body: some View {
        Group {
            if live, !touch.stubbed, let glyph = touch.glyph {
                PayTouchGlyph(view: glyph)
            } else {
                Symbol("touchid", size: 13)
                    .foregroundStyle(PayInk.touch)
            }
        }
        .frame(width: 16, height: 16)
        .opacity(live && low ? 0.55 : 1)
        .onAppear {
            guard live, !still else { return }
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { low = true }
        }
    }
}

/// The arc beside Checking and Paying: a turning ring, still under Reduce
/// Motion.
private struct PayArc: View {
    @State private var turning = false
    @Environment(\.accessibilityReduceMotion) private var still

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.72)
            .stroke(style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            .frame(width: 11, height: 11)
            .rotationEffect(.degrees(turning ? 360 : 0))
            .onAppear {
                guard !still else { return }
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) { turning = true }
            }
    }
}

/// One shake for each count, ±5 and tapering, 0.36 s: a finger that didn't
/// match, or the site's no. Counted up, never back, so each one starts from
/// still.
private struct PayShake: GeometryEffect {
    var count: CGFloat

    var animatableData: CGFloat {
        get { count }
        set { count = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let x = count - count.rounded(.down)
        return ProjectionTransform(CGAffineTransform(translationX: 5 * sin(x * .pi * 6) * (1 - x), y: 0))
    }
}

/// The system's Touch ID glyph, put in the button.
private struct PayTouchGlyph: NSViewRepresentable {
    let view: LAAuthenticationView

    func makeNSView(context: Context) -> NSView {
        let holder = NSView()
        place(view, in: holder)
        return holder
    }

    func updateNSView(_ holder: NSView, context: Context) {
        guard holder.subviews.first !== view else { return }
        holder.subviews.forEach { $0.removeFromSuperview() }
        place(view, in: holder)
    }

    private func place(_ glyph: NSView, in holder: NSView) {
        glyph.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(glyph)
        NSLayoutConstraint.activate([
            glyph.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
            glyph.widthAnchor.constraint(lessThanOrEqualTo: holder.widthAnchor),
            glyph.heightAnchor.constraint(lessThanOrEqualTo: holder.heightAnchor),
        ])
    }
}

/// The sheet's few colors of its own: Touch ID's pink, and what the site
/// said.
enum PayInk {
    static let touch = Color(nsColor: .systemPink)
    static let good = Color(nsColor: .systemGreen)
    static let bad = Color(nsColor: .systemRed)
}

// MARK: - a list in the sheet's place

private struct PayList: View {
    @Bindable var flow: PayFlow
    let pane: PaySheetModel.Pane

    var body: some View {
        let model = flow.model
        let cards = pane == .cards
        VStack(spacing: 0) {
            PayBackHead(title: cards ? "Pay With" : "Ship To", detail: cards ? "Cards in Yab" : "Addresses in Yab") { flow.back() }
            PayGroup {
                if cards {
                    ForEach(Array(model.cards.enumerated()), id: \.element.id) { index, card in
                        PayRow(lead: { PayMark(kind: card.brand, height: 20) }, title: card.title, detail: card.name,
                               opens: true, lit: model.focus == index, tick: card.id == model.card, choice: true) { flow.pick(index) }
                    }
                } else {
                    ForEach(Array(model.places.enumerated()), id: \.element.id) { index, place in
                        PayRow(lead: { PayLead(name: place.mark) }, title: place.line, detail: place.who,
                               opens: true, lit: model.focus == index, tick: place.id == model.place, choice: true) { flow.pick(index) }
                    }
                }
                PayRow(lead: { PayLead(name: "plus", tint: Color.accentColor) }, title: cards ? "Add Card…" : "Add Address…",
                       detail: "", opens: true, lit: model.focus == model.rows, tint: Color.accentColor, choice: true) { flow.pick(model.rows) }
            }
        }
    }
}

// MARK: - a form in the sheet's place

private struct PayForm: View {
    @Bindable var flow: PayFlow
    let pane: PaySheetModel.Pane
    @FocusState private var focus: String?

    var body: some View {
        let card = pane == .newCard
        VStack(spacing: 0) {
            PayBackHead(title: card ? "Add Card" : "Add Address",
                        detail: card ? "Kept in Yab, opened with Touch ID" : "Kept in Yab, Settings \u{203A} Autofill") { flow.back() }
            PayGroup {
                if card {
                    field("Number", "Card number", $flow.form.number)
                        .onChange(of: flow.form.number) { _, typed in
                            let spaced = PaySheetModel.spaced(typed)
                            if spaced != typed { flow.form.number = spaced }
                        }
                    PayFieldRule()
                    HStack(spacing: 0) {
                        field("Expires", "MM / YY", $flow.form.expires)
                        PayFieldDivider()
                        field("CVC", "123", $flow.form.code, label: nil)
                    }
                    PayFieldRule()
                    field("Name", "Name on card", $flow.form.holder)
                } else {
                    field("Name", "Full name", $flow.form.name)
                    PayFieldRule()
                    field("Street", "Street and number", $flow.form.street)
                    PayFieldRule()
                    field("Apt", "Optional", $flow.form.apt)
                    PayFieldRule()
                    HStack(spacing: 0) {
                        field("City", "City", $flow.form.city)
                        PayFieldDivider()
                        field("ZIP", "ZIP", $flow.form.zip, label: nil)
                    }
                }
            }
            Button { flow.save() } label: {
                Text(card ? "Save Card" : "Save Address").frame(maxWidth: .infinity)
            }
            .buttonStyle(.yab(.primary, .large))
            .disabled(!flow.canSave)
            .padding(.horizontal, 4)
            .padding(.top, 12)
            .padding(.bottom, 2)
        }
        .onExitCommand { flow.back() }
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { focus = card ? "Number" : "Name" } }
    }

    /// A row of the group: its name in a fixed column, then the box.
    /// `label: nil` for the second half of a row, whose name sits as wide as it is.
    private func field(_ name: String, _ hint: String, _ text: Binding<String>, label: CGFloat? = 58) -> some View {
        HStack(spacing: 10) {
            Text(name)
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.muted)
                .frame(width: label, alignment: .leading)
            TextField(hint, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focus, equals: name)
                .onSubmit { flow.save() }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 44)
    }
}

private struct PayFieldRule: View {
    var body: some View {
        Rectangle().fill(Palette.ink.opacity(0.08)).frame(height: 0.5).padding(.horizontal, 10)
    }
}

private struct PayFieldDivider: View {
    var body: some View {
        Rectangle().fill(Palette.ink.opacity(0.08)).frame(width: 0.5).frame(maxHeight: 44)
    }
}
