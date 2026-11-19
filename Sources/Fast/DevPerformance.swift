import SwiftUI
import AppKit

struct DevPerformancePane: View {
    let browser: Browser
    var model: DevWorkbench
    @State private var selected: Int?
    @State private var mode = "Summary"
    @State private var zoom = 1.0
    @State private var screenshots = true
    @State private var filter = ""
    @State private var from = 0.0
    @State private var to = 1.0
    @State private var net = true
    @State private var memory = true
    var body: some View {
        VStack(spacing: 0) {
            DevPanelBar {
                Button { browser.performanceRecord(!model.recording, screenshots: screenshots) } label: { Symbol(model.recording ? "stop.fill" : "record.circle", size: 12).foregroundStyle(model.recording ? DevLook.red : Palette.ink) }.keyTip("Record / Stop (⌘E)")
                Button { browser.performanceRecord(true, reload: true, screenshots: screenshots) } label: { Symbol("arrow.clockwise", size: 11) }.disabled(model.recording).keyTip("Record and reload")
                Button { model.trace = []; model.traceRaw = []; model.memorySamples = [] } label: { Symbol("nosign", size: 11) }.disabled(model.recording).keyTip("Clear recording")
                Toggle("Screenshots", isOn: $screenshots).fixedSize()
                Toggle("Memory", isOn: $memory).fixedSize()
                Toggle("Network", isOn: $net).fixedSize()
                Spacer(minLength: 4)
                Button("Import…") { importTrace() }
                Button("Export…") { browser.devExport(DevTraceCodec.export(model), filename: "yab-trace.json") }.disabled(model.trace.isEmpty)
            }
            Divider()
            if model.trace.isEmpty {
                ThreadScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Record a page to inspect its main thread, layout and paint work").font(.system(size: 13.5, weight: .medium))
                    Text("Live page metrics").font(.system(size: 12, weight: .semibold))
                    DevDataRows(rows: model.metrics)
                    Text("CPU throttling and Chromium compositor tracks are unavailable for this WebKit page.").font(.system(size: 11.5)).foregroundStyle(Palette.muted)
                    Button("Record and reload") { browser.performanceRecord(true, reload: true, screenshots: screenshots) }.buttonStyle(.yab(.secondary, .small))
                }.padding(16).frame(maxWidth: .infinity, alignment: .topLeading)
                }
            } else {
                HStack(spacing: 8) {
                    Text(model.recording ? "Recording…" : String(format: "%.1f ms", duration * 1000)).foregroundStyle(model.recording ? DevLook.red : Palette.muted)
                    Text("Zoom"); Slider(value: $zoom, in: 1...10).frame(maxWidth: 140)
                    TextField("Filter events", text: $filter).textFieldStyle(.plain)
                    Spacer(minLength: 0)
                }.font(.system(size: 11)).padding(8)
                GeometryReader { room in
                VSplitView {
                    VStack(spacing: 0) {
                        overview.frame(height: 26)
                        HStack { Text("Range"); Slider(value: $from, in: 0...max(0.001,to-0.001)); Slider(value: $to, in: min(0.999,from+0.001)...1) }.font(.system(size: 10)).padding(.horizontal, 8).frame(height: 30).clipped()
                        if screenshots, room.size.height >= 360 { filmstrip }
                        ThreadScrollView([.horizontal, .vertical]) {
                            flamechart(width: max(600, room.size.width) * zoom)
                        }.frame(minHeight: 60)
                        if memory, !model.memorySamples.isEmpty { memoryTrack.frame(height: 30) }
                        if net { networkTrack }
                    }.frame(minHeight: min(190, room.size.height * 0.7), idealHeight: room.size.height * 0.65)
                    details.frame(minHeight: 60, idealHeight: room.size.height * 0.35)
                }
                }
            }
        }
        .onAppear { browser.performanceMetrics() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if !Task.isCancelled, model.trace.isEmpty, !model.recording { browser.performanceMetrics() }
            }
        }
    }
    private var start: Double { model.trace.map(\.start).min() ?? 0 }
    private var duration: Double { max(0.001, (model.trace.map(\.end).max() ?? start) - start) }
    private var maxDepth: Int { min(40, model.trace.filter { $0.name != "Screenshot" }.map(\.depth).max() ?? 0) }
    private var visible: [DevTraceEvent] {
        model.trace.filter { $0.name != "Screenshot" && $0.end >= start + from * duration && $0.start <= start + to * duration && (filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter)) }
    }
    private var overview: some View {
        Canvas { context, size in
            for event in model.trace where event.name != "Screenshot" && event.duration > 0 {
                let x = (event.start - start) / duration * size.width
                let width = max(1, (event.end - event.start) / duration * size.width)
                context.fill(Path(CGRect(x: x, y: 4, width: width, height: max(1, size.height - 8))), with: .color(event.color.opacity(0.4)))
            }
            context.stroke(Path(CGRect(x: from * size.width, y: 0, width: (to-from)*size.width, height: size.height)), with: .color(.accentColor), lineWidth: 1)
        }.background(Palette.ink.opacity(0.025))
    }
    private func flamechart(width: Double) -> some View {
        let rangeStart = start + from * duration
        let range = max(0.001, (to-from)*duration)
        return Canvas { context, size in
            for event in visible where event.depth <= 40 {
                let x = max(0, (event.start-rangeStart)/range * width)
                let w = max(2, min(width-x, (event.end-max(rangeStart,event.start))/range*width))
                let rect = CGRect(x: x, y: Double(event.depth)*20+20, width: w, height: 18)
                context.fill(Path(rect), with: .color(event.color.opacity(selected == event.id ? 1 : 0.65)))
                if w > 50 { context.draw(Text(event.name).font(.system(size: 10)).foregroundStyle(.black), at: CGPoint(x:x+4,y:rect.midY), anchor: .leading) }
            }
            for tick in 0...10 {
                let x = width * Double(tick)/10
                context.draw(Text(String(format:"%.0f ms",(rangeStart-start+range*Double(tick)/10)*1000)).font(.system(size:10)).foregroundStyle(Palette.muted), at:CGPoint(x:x+4,y:8),anchor:.leading)
            }
        }
        .frame(width: width, height: CGFloat(maxDepth+1)*20+28)
        .onTapGesture { location in
            let time = rangeStart + Double(location.x)/width*range
            let depth = Int((location.y-20)/20)
            selected = visible.last { $0.depth == depth && $0.start <= time && $0.end >= time }?.id
        }
    }
    private var filmstrip: some View {
        let shots = model.traceRaw.compactMap { $0["data"] as? [String: Any] }.compactMap { ($0["imageData"] as? String) ?? ($0["dataURL"] as? String) }
        return ThreadScrollView(.horizontal) {
            HStack(spacing: 4) {
                ForEach(Array(shots.enumerated()), id: \.offset) { _, shot in
                    if let comma = shot.firstIndex(of: ","), let data = Data(base64Encoded: String(shot[shot.index(after: comma)...])), let image = NSImage(data: data) {
                        Image(nsImage: image).resizable().scaledToFit().frame(height: 50)
                    }
                }
            }
        }.frame(height: shots.isEmpty ? 0 : 54)
    }
    private var networkTrack: some View {
        let rows = (browser.toolsFront?.netLog.rows ?? []).filter { ($0.resource.ended ?? $0.resource.sent ?? 0) >= start && ($0.resource.sent ?? 0) <= start + duration }
        return HStack(spacing: 8) {
            Button("Network (\(rows.count))") { browser.pickDevPane(.network) }.font(.system(size: 10))
            Canvas { context, size in
                for row in rows {
                    let begin = row.resource.sent ?? start
                    let end = row.resource.ended ?? start + duration
                    let x = max(0, (begin - start) / duration * size.width)
                    let width = max(2, min(size.width - x, (end - max(begin, start)) / duration * size.width))
                    context.fill(Path(CGRect(x: x, y: 4, width: width, height: 12)), with: .color(row.resource.failed ? DevLook.red : .blue.opacity(0.6)))
                }
            }.frame(height: 20)
        }.padding(.horizontal, 8).background(Palette.ink.opacity(0.025))
    }
    private var memoryTrack: some View {
        let peak = max(1, model.memorySamples.map(\.bytes).max() ?? 1)
        return HStack(spacing: 8) {
            Text("Memory \(ByteCountFormatter.string(fromByteCount: Int64(peak), countStyle: .memory))").font(.system(size: 10)).foregroundStyle(Palette.muted)
            Canvas { context, size in
                var path = Path()
                for (index, sample) in model.memorySamples.enumerated() {
                    let point = CGPoint(x: max(0, (sample.time - start) / duration * size.width), y: size.height - Double(sample.bytes) / Double(peak) * size.height)
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                context.stroke(path, with: .color(.green), lineWidth: 1.5)
            }
        }.padding(.horizontal, 8)
    }
    private var details: some View {
        VStack(spacing: 0) {
            DevPanelBar {
                ForEach(["Summary", "Bottom-Up", "Call Tree", "Event Log"], id: \.self) { tab in Button(tab) { mode = tab }.foregroundStyle(mode == tab ? Color.accentColor : Palette.ink) }
                Spacer(minLength: 0)
            }
            Divider()
            ThreadScrollView {
                if mode == "Summary", let event = model.trace.first(where: { $0.id == selected }) {
                    DevDataRows(rows: [DevProperty(name:"Event",value:event.name),DevProperty(name:"Duration",value:String(format:"%.2f ms",event.duration)),DevProperty(name:"Start",value:String(format:"%.2f ms",(event.start-start)*1000)),DevProperty(name:"Details",value:event.data)])
                } else if mode == "Bottom-Up" || mode == "Summary" {
                    let grouped = Dictionary(grouping: visible, by: \.name)
                    DevDataRows(rows: grouped.map { key, rows in DevProperty(name:key,value:String(format:"%.2f ms self · %d events",rows.reduce(0) { $0+$1.selfDuration },rows.count)) }.sorted { $0.name < $1.name })
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(visible) { event in
                            Button { selected = event.id; mode = "Summary" } label: {
                                HStack { Text(event.name).padding(.leading, mode == "Call Tree" ? CGFloat(event.depth)*12 : 0); Spacer(); Text(String(format:"%.2f ms",event.duration)) }.font(.system(size:11)).padding(8)
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
    private func importTrace() {
        let panel=NSOpenPanel(); panel.canChooseDirectories=false
        guard let window=browser.devWindow else{return}
        panel.beginSheetModal(for:window){result in
            guard result == .OK,let url=panel.url,let text=try? String(contentsOf:url,encoding:.utf8),let data=DevWorkbench.parse(text) as? [String:Any],let records=DevTraceCodec.records(data) else{return}
            model.trace=[];model.traceRaw=[];model.appendTrace(records)
        }
    }
}

extension Browser {
    func performanceRecord(_ on: Bool, reload: Bool = false, screenshots: Bool = true, finished: @escaping () -> Void = {}) {
        guard let model=workbench else{return}
        if on { model.trace=[]; model.traceRaw=[]; model.memorySamples=[] }
        workCall("performance.record",["on":on,"screenshots":screenshots]){[weak self,weak model] value in
            guard let state=value as? [String:Any] else { model?.recording = false; finished(); return }
            model?.recording=state["recording"] as? Bool ?? false
            if !on, let records=state["records"] as? [[String:Any]] { model?.trace=[];model?.traceRaw=[];model?.appendTrace(records) }
            if !on, let samples=state["memory"] as? [[String:Any]] { model?.memorySamples=samples.compactMap(DevMemorySample.init) }
            if on && reload { self?.active?.page.reload(fromOrigin: false) }
            if !on { self?.performanceMetrics() }
            finished()
        }
    }
    func performanceMetrics() {
        workCall("performance.metrics") { [weak self] value in
            guard let data=value as? [String:Any] else{return}
            var rows:[DevProperty]=[]
            if let nav=(data["navigation"] as? [[String:Any]])?.first {
                for key in ["domContentLoadedEventEnd","loadEventEnd","responseStart","duration"] {
                    if let n=nav[key] as? Double { rows.append(DevProperty(name:key,value:String(format:"%.1f ms",n))) }
                }
            }
            for paint in data["paint"] as? [[String:Any]] ?? [] { rows.append(DevProperty(name:paint["name"] as? String ?? "Paint",value:String(format:"%.1f ms",paint["startTime"] as? Double ?? 0))) }
            let vitals = data["vitals"] as? [String: Any] ?? [:]
            if let lcp = vitals["lcp"] as? [String: Any], let time = lcp["time"] as? Double {
                rows.append(DevProperty(name: "LCP", value: String(format: "%.1f ms", time)))
                rows.append(DevProperty(name: "LCP element", value: DevWorkbench.string(lcp["element"])))
            } else { rows.append(DevProperty(name: "LCP", value: "Waiting for a buffered paint entry")) }
            if let inp = vitals["inp"] as? Double { rows.append(DevProperty(name: "Longest interaction", value: String(format: "%.1f ms", inp))) }
            rows.append(DevProperty(name: "CLS", value: "Layout-shift entries are unavailable in this WebKit page"))
            rows.append(DevProperty(name:"DOM nodes",value:DevWorkbench.string(data["nodes"])))
            self?.workbench?.metrics=rows
        }
    }
}
