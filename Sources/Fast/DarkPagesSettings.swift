import AppKit
import SwiftUI
import WebKit

/// Settings › Appearance, after Page size and Fonts: the mode, and the
/// sheet behind Customize… (docs/dark-pages.md, "What people see").
struct DarkPagesSettings: View {
    static let open = Notification.Name("yab.dark-pages.sheet")
    @Bindable var prefs: Preferences
    private var extensions = Extensions.shared
    @State private var sheet = false
    @State private var moving = 0

    var body: some View {
        SettingsRow("Dark pages", detail: "Use dark mode on sites without a dark theme.") {
            HStack(spacing: 8) {
                DropMenu("Dark pages", options: DarkMode.allCases.map { (title: $0.title, value: $0) }, selection: $prefs.darkPages)
                    .fixedSize()
                Button("Customize\u{2026}") { sheet = true }.settingsButton()
            }
        }
        .settingsAnchor("dark-pages")
        .sheet(isPresented: $sheet) { DarkPagesSheet(prefs: prefs) { sheet = false } }
        // The bench's way in, for a picture of the sheet where it shows.
        .onReceive(NotificationCenter.default.publisher(for: DarkPagesSettings.open)) { _ in sheet = true }
        if extensions.installed.contains(where: { $0.id == DarkPages.extensionID && $0.enabled }) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                SettingsNote("Dark Reader is on in Extensions. Yab leaves dark pages to it. Switch to Yab\u{2019}s brings its \(moving) sites over and turns it off.")
                Spacer(minLength: 0)
                Button("Switch to Yab\u{2019}s") { DarkPages.takeOverFromExtension() }.settingsButton()
            }
            .onAppear { moving = DarkReaderStorage.read()?.lightSites.count ?? 0 }
        }
    }
}

/// Dark Pages, 460 wide as Fonts is: a live picture of the page in front
/// (a sample when there is none), the look, and the sites kept light.
struct DarkPagesSheet: View {
    @Bindable var prefs: Preferences
    let close: () -> Void
    @State private var kept = DarkPages.keptLight()

    var body: some View {
        VStack(spacing: 0) {
            ThreadForm {
                Section {
                    DarkPreview(look: prefs.darkLook)
                        .listRowInsets(EdgeInsets())
                    if prefs.darkPages == .off {
                        SettingsNote("Dark pages is Off. This look applies to the sites you turn on in Site Controls (\u{2318}E).")
                    }
                    slider("Brightness", \.brightness, DarkLook.brightnessRange)
                    slider("Contrast", \.contrast, DarkLook.contrastRange)
                    slider("Warmth", \.warmth, DarkLook.warmthRange)
                    SettingsRow("Background", detail: "Space uses the current space's color.") {
                        GlassTrack(title: "Background",
                                   options: DarkLook.Ground.allCases.map { (title: $0.title, value: $0) },
                                   selection: $prefs.darkLook.ground)
                            .frame(width: 64 * CGFloat(DarkLook.Ground.allCases.count) + 6)
                    }
                    SettingsRow("Dim pictures", detail: "Reduce image brightness without inverting colors.") {
                        Toggle("Dim pictures", isOn: $prefs.darkLook.dimPictures)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                } header: {
                    Text("Dark Pages").font(.headline).foregroundStyle(.primary)
                }
                Section {
                    SettingsRow("Turned off", detail: "Manage exceptions in Site Controls (\u{2318}E).") { EmptyView() }
                    ForEach(kept, id: \.self) { host in
                        HStack(spacing: 8) {
                            SiteMark(host: host, size: 16)
                            Text(host)
                            Spacer(minLength: 0)
                            Button {
                                DarkPages.keepLight(host, false)
                                DarkPages.refresh(host: host)
                                kept = DarkPages.keptLight()
                            } label: {
                                Symbol("xmark", size: 10, weight: .medium)
                            }
                            .buttonStyle(.yab(.quiet, .small, icon: .square))
                            .accessibilityLabel("Darken \(host) again")
                        }
                    }
                }
            }
            .formStyle(.grouped)
            HStack(spacing: 8) {
                Button("Restore Defaults") { prefs.darkLook = DarkLook() }
                    .settingsButton()
                    .disabled(prefs.darkLook == DarkLook())
                Spacer()
                Button(action: close) {
                    HStack(spacing: 6) {
                        Text(SettingsWords.text("Done"))
                        KeyGlyphs(keys: "↩", size: 12.5, tint: nil, rest: 0.6)
                            .transaction { $0.animation = nil }
                    }
                }
                .settingsButton(.primary)
                .keyboardShortcut(.defaultAction)
            }
            .padding(EdgeInsets(top: 0, leading: 20, bottom: 20, trailing: 20))
        }
        .frame(width: 460, height: 640)
        .onReceive(NotificationCenter.default.publisher(for: DarkPages.changed)) { _ in kept = DarkPages.keptLight() }
    }

    private func slider(_ title: String, _ path: WritableKeyPath<DarkLook, Int>, _ range: ClosedRange<Int>) -> some View {
        SettingsRow(title) {
            HStack(spacing: 8) {
                Slider(value: Binding(get: { Double(prefs.darkLook[keyPath: path]) },
                                      set: { prefs.darkLook[keyPath: path] = Int(($0 / 5).rounded() * 5) }),
                       in: Double(range.lowerBound)...Double(range.upperBound))
                    .controlSize(.small)
                    .labelsHidden()
                    .frame(width: 160)
                    .accessibilityLabel(title)
                Text("\(prefs.darkLook[keyPath: path])%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }
        }
    }
}

/// The page in front as it looks now, darkened by the engine, taken again
/// after each change; a sample page with the real engine when the page in
/// front isn't darkened.
struct DarkPreview: View {
    let look: DarkLook
    @State private var shot: NSImage?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let shot {
                    Image(nsImage: shot).resizable().aspectRatio(contentMode: .fill)
                } else {
                    DarkSample(look: look)
                }
            }
            // A page snapshot must fill the row's proposed width without
            // giving the grouped form the image's own minimum width.
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .frame(height: 168)
        .frame(maxWidth: .infinity)
        .task(id: look) { shot = await DarkPreview.front() }
    }

    /// A picture of the page in front, once the engine has restyled it.
    @MainActor static func front() async -> NSImage? {
        guard let tab = BrowserWindows.shared.browsers.lazy.compactMap(\.active).first(where: { $0.dark == .engine }),
              let web = tab.webKitOnly("WebKit dark-mode preview", build: false), web.bounds.width > 0 else { return nil }
        try? await Task.sleep(for: .milliseconds(250))
        let shot = WKSnapshotConfiguration()
        shot.rect = CGRect(x: 0, y: 0, width: web.bounds.width, height: min(web.bounds.height, web.bounds.width * 168 / 460))
        shot.snapshotWidth = 460
        shot.afterScreenUpdates = true
        return await withCheckedContinuation { done in
            web.takeSnapshot(with: shot) { image, _ in done.resume(returning: image) }
        }
    }
}

/// A small page of words, a link, a button, code and a photo, darkened by
/// the same scripts every page gets.
struct DarkSample: NSViewRepresentable {
    let look: DarkLook

    final class Relay: NSObject, WKScriptMessageHandlerWithReply {
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                                   replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
            MainActor.assumeIsolated { replyHandler(["decision": "engine"], nil) }
        }
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.processPool = Web.pool
        AppleWritingTools.configure(configuration)
        configuration.websiteDataStore = .nonPersistent()
        let controller = configuration.userContentController
        controller.addScriptMessageHandler(Relay(), contentWorld: DarkPages.world, name: DarkRelay.name)
        for script in DarkPages.scripts(for: .engine) { controller.addUserScript(script) }
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.appearance = NSAppearance(named: .darkAqua)
        web.underPageBackgroundColor = DarkPages.groundColor(look)
        web.loadHTMLString(DarkSample.page, baseURL: URL(string: "https://sample.yab.invalid/"))
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        let ground = DarkPages.groundHex(look)
        web.underPageBackgroundColor = DarkPages.groundColor(look)
        web.evaluateQuietly("window.__yabDark && window.__yabDark.look(\(DarkPages.json(look.theme(ground: ground))), \(DarkPages.json(DarkLook.fallback(ground: ground))), \(DarkPages.json(look.dimCSS)))",
                            in: nil, in: DarkPages.world)
    }

    static let page = """
    <!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width">
    <style>
    body { margin: 0; font: 14px/1.45 -apple-system, sans-serif; color: #1f2328; background: #fff; }
    header { display: flex; align-items: center; gap: 10px; padding: 10px 18px; background: #f6f8fa; border-bottom: 1px solid #d0d7de; }
    header b { font-size: 15px; } header a { color: #0969da; margin-left: auto; text-decoration: none; }
    main { display: flex; gap: 16px; padding: 14px 18px; }
    h1 { font-size: 19px; margin: 0 0 6px; } p { margin: 0 0 8px; color: #424a53; }
    code { background: #eff1f3; padding: 1px 5px; border-radius: 4px; }
    button { background: #1f883d; color: #fff; border: 0; border-radius: 6px; padding: 6px 12px; font: inherit; }
    .photo { width: 150px; height: 100px; border-radius: 8px; flex: none; background-size: cover;
      background-image: url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 150 100'><defs><linearGradient id='s' x1='0' y1='0' x2='0' y2='1'><stop offset='0' stop-color='%2387b7e6'/><stop offset='.6' stop-color='%23f6d3a1'/></linearGradient></defs><rect width='150' height='100' fill='url(%23s)'/><circle cx='110' cy='34' r='12' fill='%23fff3c4'/><path d='M0 78 L40 52 L70 70 L104 46 L150 74 L150 100 L0 100 Z' fill='%23396b45'/></svg>"); }
    </style>
    <header><b>Northwind News</b><a href="#">Subscribe</a></header>
    <main><div><h1>Ferries add a late winter run</h1>
    <p>The harbor line runs until <code>23:40</code> from Monday, with a stop at the old pier.</p>
    <button>Read on</button></div><div class="photo"></div></main>
    """
}
