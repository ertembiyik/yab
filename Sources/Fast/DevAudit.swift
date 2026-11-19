import SwiftUI
import Foundation

struct DevWorkbenchHost: View {
    let browser: Browser
    var model: DevWorkbench
    let pane: DevPane
    var body: some View {
        VStack(spacing: 0) {
            if !model.error.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Text(model.error).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { model.error = "" } label: { Symbol("xmark", size: 9) }.buttonStyle(.plain)
                }.font(.system(size: 11.5)).foregroundStyle(DevLook.errorInk).padding(8).background(DevLook.errorGround)
            }
            Group {
                switch pane {
                case .elements: DevElementsPane(browser: browser, model: model)
                case .sources: DevSourcesPane(browser: browser, model: model)
                case .performance: DevPerformancePane(browser: browser, model: model)
                case .memory: DevMemoryPane(browser: browser, model: model)
                case .application: DevApplicationPane(browser: browser, model: model)
                case .layers: DevLayersPane(browser: browser, model: model)
                case .audit: DevAuditPane(browser: browser, model: model)
                default: EmptyView()
                }
            }.frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        }
        .onChange(of: model.picking) { browser.devPicking = model.picking }
        .onChange(of: model.pickSerial) { showPick() }
        .onAppear { showPick() }
    }

    private func showPick() {
        guard model.pickUnseen else { return }
        model.pickUnseen = false
        browser.devPicking = false
        browser.pickDevPane(.elements)
        browser.elementsPicked(model.pickedNode)
    }
}

struct DevAuditPane: View {
    let browser: Browser
    var model: DevWorkbench
    @State private var mode = "Snapshot"
    @State private var mobile = false
    @State private var accessibility = true
    @State private var seo = true
    @State private var practices = true
    @State private var performance = true
    var body: some View {
        VStack(spacing: 0) {
            DevPanelBar {
                Picker("Mode", selection: $mode) { Text("Snapshot").tag("Snapshot"); Text("Navigation").tag("Navigation"); Text("Timespan").tag("Timespan") }.labelsHidden().frame(maxWidth: 160)
                Toggle("Mobile", isOn: $mobile).fixedSize()
                Spacer(minLength: 4)
                Button(model.busy ? "Running…" : mode == "Timespan" && model.recording ? "End timespan" : "Run audit") { run() }.disabled(model.busy)
                Button("Save JSON…") { browser.devExport(model.auditReport, filename: "yab-audit.json") }.disabled(model.auditReport.isEmpty)
            }
            Divider()
            ThreadScrollView(.horizontal) {
            HStack(spacing: 16) {
                Toggle("Accessibility", isOn: $accessibility); Toggle("SEO", isOn: $seo); Toggle("Best practices", isOn: $practices); Toggle("Performance", isOn: $performance)
            }.font(.system(size: 11.5)).padding(8)
            }.fixedSize(horizontal: false, vertical: true)
            Divider()
            if model.audit.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Audit this page").font(.system(size: 13.5, weight: .medium))
                    Text("Accessibility checks use the bundled axe-core engine. SEO and best-practice checks inspect the current document; performance measurements come from its navigation and a WebKit trace.").font(.system(size: 12)).foregroundStyle(Palette.muted)
                    Text("Results identify checks that passed, failed, or need manual review. They are Yab audits, without a simulated Lighthouse score.").font(.system(size: 11.5)).foregroundStyle(Palette.muted)
                }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ThreadScrollView { DevDataRows(rows: model.audit) }
                DevPanelBar { Button("View trace") { browser.pickDevPane(.performance) }; Button("Copy for Agent") { browser.copyForAgent(model.audit.map { $0.name + ": " + $0.value }.joined(separator: "\n"), "Copied audit") }; Spacer(minLength: 0) }
            }
        }
    }
    private func run() {
        browser.auditRun(mode: mode, mobile: mobile, accessibility: accessibility, seo: seo, practices: practices, performance: performance)
    }
}

extension Browser {
    func auditRun(mode: String = "Snapshot", mobile: Bool = false, accessibility: Bool = true, seo: Bool = true, practices: Bool = true, performance: Bool = true) {
        guard let model = workbench, !model.busy else { return }
        let auditedTab = toolsFront
        let previousDevice = model.auditHasDeviceOverride ? model.auditPreviousDevice : auditedTab?.device
        if mobile, !model.auditHasDeviceOverride {
            model.auditPreviousDevice = previousDevice; model.auditHasDeviceOverride = true
            toolsFront?.setDevice(DeviceMode(name: "Audit Mobile", width: 390, height: 844, userAgent: nil))
        }
        @MainActor func restoreDevice() {
            if model.auditHasDeviceOverride {
                if self.devOpen { auditedTab?.setDevice(previousDevice) }
                model.auditHasDeviceOverride = false; model.auditPreviousDevice = nil
            }
        }
        if mode == "Timespan", !model.recording {
            model.busy = true; performanceRecord(true) {
                model.busy = false
                if !model.recording { restoreDevice() }
            }
            return
        }
        @MainActor func inspect() {
            model.busy = true; model.audit = []; model.auditReport = ""
            self.workCall("audit.run") { value in
                guard let data = value as? [String: Any] else { model.busy = false; restoreDevice(); return }
                var rows: [DevProperty] = []
                var whole: [String: Any] = ["type": "yab-audit", "mode": mode, "url": data["url"] ?? "", "document": data]
                if seo {
                    rows.append(DevProperty(name: "SEO · document title", value: (data["title"] as? String ?? "").isEmpty ? "FAIL: no title" : "PASS: " + (data["title"] as? String ?? "")))
                    rows.append(DevProperty(name: "SEO · headings", value: (data["headings"] as? [String] ?? []).count == 1 ? "PASS: one H1" : "REVIEW: \((data["headings"] as? [String] ?? []).count) H1 headings"))
                    rows.append(DevProperty(name: "SEO · viewport", value: data["viewport"] as? Bool == true ? "PASS" : "FAIL: missing viewport meta"))
                }
                if practices { rows.append(DevProperty(name: "Best practices · secure context", value: data["secure"] as? Bool == true ? "PASS" : "FAIL: insecure context")) }
                model.audit = rows
                if performance {
                    self.performanceMetrics(); whole["trace"] = model.traceRaw
                    whole["navigation"] = data["navigation"] ?? []; whole["paint"] = data["paint"] ?? []
                    if let nav = (data["navigation"] as? [[String: Any]])?.first {
                        for key in ["responseStart", "domContentLoadedEventEnd", "loadEventEnd"] {
                            if let ms = nav[key] as? Double { rows.append(DevProperty(name: "Performance · " + key, value: String(format: "%.1f ms", ms))) }
                        }
                    }
                }
                guard accessibility else { model.audit = rows; model.auditReport = DevWorkbench.string(whole); model.busy = false; restoreDevice(); return }
                guard let url = Bundle.main.url(forResource: "axe.min", withExtension: "js", subdirectory: "DevTools"), let script = try? String(contentsOf: url, encoding: .utf8) else {
                    model.error = "The bundled accessibility engine is missing"; model.busy = false; restoreDevice(); return
                }
                self.workCall("audit.axe", ["script": script]) { result in
                    guard let result = result as? [String: Any] else { model.busy = false; restoreDevice(); return }
                    whole["accessibility"] = result
                    rows.append(DevProperty(name: "Accessibility", value: "\(result["passes"] ?? 0) checks passed · \((result["violations"] as? [Any] ?? []).count) violations · \(result["incomplete"] ?? 0) need manual review"))
                    for violation in result["violations"] as? [[String: Any]] ?? [] {
                        let nodes = violation["nodes"] as? [[String: Any]] ?? []
                        rows.append(DevProperty(name: violation["id"] as? String ?? "Violation", value: (violation["help"] as? String ?? "") + "\n" + nodes.map { DevWorkbench.string($0["target"]) + " " + DevWorkbench.string($0["failureSummary"]) }.joined(separator: "\n")))
                    }
                    model.audit = rows; model.auditReport = DevWorkbench.string(whole); model.busy = false; restoreDevice()
                }
            }
        }
        if mode == "Navigation" {
            model.busy = true
            performanceRecord(true, reload: true) { [weak self] in
                guard let self else { return }
                let deadline = Date().addingTimeInterval(20)
                @MainActor func loaded() {
                    guard self.devOpen else { model.busy = false; restoreDevice(); return }
                    if self.toolsFront?.builtPage?.isLoading == true, Date() < deadline {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: loaded)
                    } else { self.performanceRecord(false, finished: inspect) }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: loaded)
            }
        } else if model.recording { performanceRecord(false, finished: inspect) }
        else { inspect() }
    }
}
