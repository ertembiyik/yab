import AppKit
import CoreImage
import SwiftUI
import SyncKit

// Add a Device's code for an iPhone to scan (docs/sync.md, "The key and the
// account", 2): this Mac shows a code of its own, as text and as a QR, and
// waits for a device to post its key under it (JoinInviteHost). The device
// shows four digits worked out from its key; this Mac asks the person
// whether they are the ones it shows too, and only on that yes seals the
// account's key to it. The same card still takes the code a new Mac shows,
// typed, the way it always did.

@MainActor
@Observable final class SyncInvite {
    enum Phase: Equatable {
        /// Showing the code; nobody has posted under it yet.
        case waiting
        /// A device posted its key: the digits it shows.
        case arrived(check: String)
        case lettingIn
        case letIn
        /// Ten minutes and nobody came.
        case expired
        /// Someone else answered the box, or sealing or sending failed.
        case failed
    }

    private(set) var phase: Phase = .waiting
    let code: String
    let link: String
    private let host: JoinInviteHost
    @ObservationIgnored private var arrived: ((String) -> Void)?
    @ObservationIgnored private var done: (() -> Void)?

    init(host: JoinInviteHost) {
        self.host = host
        code = host.code
        link = host.link
    }

    /// Waits for a device; `arrived` once one posts, on the main thread.
    func start(arrived: @escaping (String) -> Void) {
        self.arrived = arrived
        host.start { [weak self] event in
            DispatchQueue.main.async { self?.heard(event) }
        }
    }

    func heard(_ event: JoinInviteHost.Event) {
        switch event {
        case let .arrived(check):
            phase = .arrived(check: check)
            arrived?(check)
        case .letIn: phase = .letIn
        case .expired: phase = .expired
        case .failed: phase = .failed
        }
        switch phase {
        case .letIn, .expired, .failed:
            let then = done
            done = nil
            then?()
        case .waiting, .arrived, .lettingIn:
            break
        }
    }

    /// The digits match: the account's key goes to the device; `done` once
    /// it is in or couldn't be let in.
    func letIn(_ seal: Seal, done: @escaping () -> Void = {}) {
        guard case .arrived = phase else { return }
        phase = .lettingIn
        self.done = done
        host.letIn(seal)
    }

    /// The card closed, or the person said no: nothing more is read or sent.
    func stop() {
        host.cancel()
        arrived = nil
    }

    /// What the row under Add a Device says once this is over; nil while
    /// the card says it.
    var words: String? {
        switch phase {
        case .waiting, .arrived: nil
        case .lettingIn: "Letting it in…"
        case .letIn: "Let in. It has everything in a moment."
        case .expired: "That code ran out. Choose Add a Device for a new one."
        case .failed: "That device couldn’t be let in. Check it has the latest Yab, then choose Add a Device again."
        }
    }
}

/// The code as a QR on a white plate, which every camera reads in the dark
/// too, and the same code in letters under it, to type instead.
struct InviteCode: View {
    var invite: SyncInvite
    var side: CGFloat = 132
    @State private var copied = false
    @State private var hovering = false
    @State private var dipped = false
    @State private var back: DispatchWorkItem?
    @Environment(\.accessibilityReduceMotion) private var still

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(invite.code, forType: .string)
        dip { copied = true }
        back?.cancel()
        let work = DispatchWorkItem { dip { copied = false } }
        back = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: work)
    }

    /// Into a blur, the change at its deepest, and out, as CopyValue's.
    private func dip(_ change: @escaping () -> Void) {
        guard !still else { change(); return }
        withAnimation(.easeIn(duration: 0.18)) { dipped = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            change()
            withAnimation(.easeOut(duration: 0.27)) { dipped = false }
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Group {
                if let image = QRCode.image(invite.link, side: side) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: side, height: side)
                } else {
                    Color.clear.frame(width: side, height: side)
                }
            }
            .padding(8)
            .background(Color.white, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .accessibilityLabel("QR code for \(invite.code)")
            VStack(alignment: .leading, spacing: 4) {
                Text("On your iPhone or another Mac")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.muted)
                Text("On iPhone, choose Join Your Mac, then Scan QR. On a Mac, enter this code under Add a Device in Settings › Sync.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: copy) {
                    // As a code in Passwords (CopyValue): the plate under the
                    // pointer, a dip into a blur, a gray Copied at the code's width.
                    ZStack {
                        Text(invite.code)
                            .font(.system(size: 17, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Palette.ink)
                            .opacity(copied ? 0 : 1)
                        if copied {
                            HStack(spacing: 4) {
                                Symbol("doc.on.doc.fill", size: 11.5)
                                Text("Copied")
                            }
                            .font(.system(size: 12.5))
                            .foregroundStyle(Palette.muted)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                        .fill(Omnibox.chosenFill.opacity(copied || hovering ? 1 : 0)))
                    .padding(.horizontal, -8)
                    .blur(radius: dipped ? 2.5 : 0)
                    .scaleEffect(dipped ? 0.96 : 1)
                    .opacity(dipped ? 0.45 : 1)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .onHover { hovering = $0 }
                .pointerStyle(.link)
                .keyTip(copied ? "Copied" : "Copy")
                .accessibilityLabel("Copy code \(invite.code)")
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

enum QRCode {
    /// The words as a QR, its modules whole points, `side` across.
    static func image(_ words: String, side: CGFloat) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(words.utf8), forKey: "inputMessage")
        // M: a phone's camera reads it off a screen at an angle.
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scale = max(1, (side * 2 / output.extent.width).rounded(.down))
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: side, height: side))
    }

    /// The words in a QR picture, for tests: what a camera would read.
    static func read(_ image: NSImage) -> String? {
        guard let tiff = image.tiffRepresentation, let picture = CIImage(data: tiff),
              let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        else { return nil }
        return detector.features(in: picture).compactMap { ($0 as? CIQRCodeFeature)?.messageString }.first
    }
}
