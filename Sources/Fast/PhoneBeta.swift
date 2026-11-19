import AppKit
import SwiftUI

// Yab for iPhone's public beta and Yab for Android's alpha, said in two quiet
// places until a phone is in sync: a row under Set up Yab in ⌘T's empty list,
// its code beside the list while it is chosen (← → turn to the other phone,
// Return copies the link, ⌘K › Don't Show This puts it away), and a row among
// the devices in Settings › Sync whose Get It opens the same code in place.
// A Mac can't install a phone's app, so both hand the link to the phone: its
// camera reads the code, or the copied link is on an iPhone through Universal
// Clipboard.

/// The phones Yab comes to, each with the link its camera opens.
enum YabPhone: Hashable {
    case iPhone, android

    var name: String {
        switch self {
        case .iPhone: "iPhone"
        case .android: "Android"
        }
    }

    var link: URL {
        switch self {
        case .iPhone: PhoneBeta.link
        case .android: PhoneBeta.androidLink
        }
    }

    /// The link as written under the code, to read or select.
    var shown: String { String(link.absoluteString.dropFirst("https://".count)) }

    var other: YabPhone { self == .iPhone ? .android : .iPhone }

    /// Beside ⌘T's list, under the code.
    var fieldWords: String {
        switch self {
        case .iPhone: "TestFlight opens. Install Yab there, then choose Join Your Mac and your spaces and tabs follow."
        case .android: "The alpha downloads. Allow the install, then choose Join Your Mac and your spaces and tabs follow."
        }
    }

    /// Settings › Sync, beside the code.
    var syncWords: String {
        switch self {
        case .iPhone: "Scan with the camera to install the beta from TestFlight. Then choose Add a Device here."
        case .android: "Scan with the camera to download the alpha and allow the install once. Then choose Add a Device here."
        }
    }
}

enum PhoneBeta {
    /// TestFlight's public link for Yab Browser (dev.serafim.fast.iphone).
    static let link = URL(string: "https://testflight.apple.com/join/EJY6AEHB")!
    /// The newest Android alpha's APK, kept current by the site's route.
    static let androidLink = URL(string: "https://yetanotherbrowser.com/android.apk")!
    /// Its row in the field (Hints).
    static let hintID = "setup.iphone"

    /// ⌘T's list beside the code: room for a row's name and a little of
    /// its words.
    static let listWidth: CGFloat = 372

    /// The row in ⌘T's list.
    static func offered(_ offer: Suggestion) -> Bool {
        if case .hint(let id) = offer.kind { return id == hintID }
        return false
    }

    /// Something to say: no phone is in sync yet.
    @MainActor static var waiting: Bool {
        let sync = SyncCenter.shared
        return !(sync.on && sync.devices.contains { SyncPhones.isPhone($0.model) || SyncPhones.isAndroid($0.model) })
    }

    /// The row under Set up Yab, in the words of the rows beside it.
    static var hint: Hint {
        Hint(id: hintID, icon: .picture(Pictures.iphone, site: nil), title: "Put Yab on my phone",
             detail: "My spaces and tabs come along", setup: true)
    }

    /// Yab for iPhone's own icon, rounded as the Home Screen rounds it
    /// (Icon/iPhone.png, the app's 180-point icon).
    static let icon: NSImage? = {
        guard let url = Logomark.file("iPhone.png"), let square = NSImage(contentsOf: url) else { return nil }
        let side: CGFloat = 180
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: side, height: side), xRadius: side * 0.225, yRadius: side * 0.225).addClip()
        square.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        image.unlockFocus()
        return image
    }()

    /// The link on the clipboard, said in the corner: nothing else on
    /// screen shows it.
    @MainActor static func copy(_ phone: YabPhone, in browser: Browser) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(phone.link.absoluteString, forType: .string)
        browser.toaster.pop(feedback: .success)
    }
}

/// A phone's link as a QR on a white plate, which every camera reads in the
/// dark too: SyncInvite's code (QRCode), at a side of its own.
struct PhoneBetaCode: View {
    var phone: YabPhone = .iPhone
    var side: CGFloat = 132

    var body: some View {
        Group {
            if let image = QRCode.image(phone.link.absoluteString, side: side) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: side, height: side)
            } else {
                Color.clear.frame(width: side, height: side)
            }
        }
        .padding(8) // design: InviteCode's plate round its code
        .background(Color.white, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .accessibilityLabel("QR code for \(phone.shown)")
    }
}

/// Which phone's code shows: the same switch in ⌘T and in Settings.
struct PhoneBetaTrack: View {
    @Bindable private var state = PhoneBetaState.shared

    var body: some View {
        GlassTrack(title: "Phone", options: [(YabPhone.iPhone.name, YabPhone.iPhone), (YabPhone.android.name, YabPhone.android)],
                   room: 17, selection: $state.phone) // design: the artifact's 84 wide choice
            .fixedSize()
    }
}

/// Beside ⌘T's list while the row is chosen: the code and what follows it.
struct PhoneBetaPreview: View {
    let chosen: Bool
    @Bindable private var state = PhoneBetaState.shared
    private var phone: YabPhone { state.phone }

    var body: some View {
        VStack(spacing: 12) { // design: the artifact's gap between the switch, the code and its words
            PhoneBetaTrack()
            PhoneBetaCode(phone: phone)
            Text("Scan with your \(phone.name)\u{2019}s camera")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(Palette.ink)
            Text(phone.fieldWords)
                .font(.system(size: CardFrame.words))
                .foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 290)
            Text(phone.shown)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Palette.faint)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 32)
        .padding(.bottom, FieldFoot.room)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(chosen ? 1 : 0)
        .accessibilityHidden(!chosen)
    }
}

/// Settings › Sync, among the devices while no phone is: a device's row,
/// its well the app's icon, and Get It opening the code under it.
struct PhoneBetaRow: View {
    @Bindable private var state = PhoneBetaState.shared
    private var open: Bool { state.open }
    private var phone: YabPhone { state.phone }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Group {
                    if let icon = PhoneBeta.icon {
                        Image(nsImage: icon).resizable().interpolation(.high)
                    } else {
                        Symbol("iphone", size: 15)
                    }
                }
                .frame(width: 28, height: 28) // design: DeviceWell's side, beside the devices
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) { // design: SettingsRow's gap under a title
                    Text("Yab for your phone")
                    Text("iPhone or Android. Your spaces and tabs, end-to-end encrypted.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(open ? "Hide" : "Get It") {
                    withAnimation(Motion.settle) { state.open.toggle() }
                }
                .settingsButton()
            }
            if open {
                HStack(alignment: .center, spacing: 16) { // design: InviteCode's gap
                    PhoneBetaCode(phone: phone, side: 112)
                    VStack(alignment: .leading, spacing: 4) {
                        PhoneBetaTrack()
                            .padding(.bottom, 4)
                        Text("On your \(phone.name)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Palette.muted)
                        Text(phone.syncWords)
                            .font(.system(size: CardFrame.words))
                            .foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(phone.shown)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Palette.ink)
                            .textSelection(.enabled)
                            .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, 40) // design: under the words, past the 28 well and its 12
                .transition(.opacity)
            }
        }
    }
}

/// Whether Settings' row shows its code, and whose: kept while Yab runs, and
/// set by the bench for its pictures (`sync action=phonebeta`).
@MainActor
@Observable final class PhoneBetaState {
    static let shared = PhoneBetaState()
    var open = false
    var phone = YabPhone.iPhone

    func turn() {
        withAnimation(Motion.settle) { phone = phone.other }
    }
}
