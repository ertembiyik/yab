import AppKit
import SwiftUI

struct DevMemoryPane: View {
    let browser: Browser
    var model: DevWorkbench
    @State private var filter = ""
    @State private var selected = ""
    @State private var snapshot = 0
    @State private var mode = "Summary"
    @State private var instances: [DevHeapObject] = []
    @State private var retained: [DevHeapObject] = []
    @State private var retainers: [DevHeapObject] = []
    @State private var rootPath: [DevProperty] = []
    @State private var selectedObject: Int?
    @State private var detailMode = "Retainers"
    @State private var tracking = false
    var body: some View {
        VStack(spacing: 0) {
            DevPanelBar {
                Button("Take snapshot") { browser.memorySnapshot() }.disabled(model.busy)
                Button { browser.workCall("Heap.gc") } label: { Symbol("trash", size: 11) }.keyTip("Collect garbage")
                Button(tracking ? "Stop tracking" : "Track allocations") {
                    tracking.toggle(); browser.workCall(tracking ? "Heap.startTracking" : "Heap.stopTracking") { _ in if !tracking { browser.memorySnapshot() } }
                }
                Spacer(minLength: 4)
                Button("Import…") { importSnapshot() }
                Button("Export…") { browser.devExport(model.heapRaw, filename: "yab-heapsnapshot.json") }.disabled(model.heapRaw.isEmpty)
            }
            Divider()
            HStack(spacing: 8) {
                if !model.heapSnapshots.isEmpty {
                    Picker("Snapshot", selection: $snapshot) { ForEach(model.heapSnapshots.indices, id: \.self) { i in Text(model.heapSnapshots[i].name).tag(i) } }.labelsHidden().frame(maxWidth: 180)
                    Picker("View", selection: $mode) { Text("Summary").tag("Summary"); Text("Comparison").tag("Comparison") }.labelsHidden().frame(maxWidth: 150)
                }
                TextField("Filter constructors", text: $filter).textFieldStyle(.plain)
                if model.busy { ProgressView().controlSize(.small) }
            }.font(.system(size: 11.5)).padding(8)
            Divider()
            if model.heap.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Heap snapshots").font(.system(size: 13.5, weight: .medium))
                    Text("Inspect JavaScript objects, constructor counts and shallow sizes. Compare snapshots to find growth; select a constructor to inspect its objects and incoming references.").font(.system(size: 12)).foregroundStyle(Palette.muted)
                    Text("Allocation tracking uses WebKit snapshots. Allocation sampling is unavailable.").font(.system(size: 11)).foregroundStyle(Palette.muted)
                    Button("Take snapshot") { browser.memorySnapshot() }.disabled(model.busy)
                }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                VSplitView {
                    ThreadScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            HStack { Text("Constructor"); Spacer(); Text("Count").frame(width: 70); Text("Shallow / Retained").frame(width: 150) }.font(.system(size: 11, weight: .semibold)).padding(8)
                            ForEach(classes) { type in
                                Button { selected = type.name; loadInstances(type.name) } label: {
                                    HStack { Text(type.name).lineLimit(1); Spacer(minLength: 0); Text(type.count.formatted()).frame(width: 70); Text(ByteCountFormatter.string(fromByteCount: Int64(type.size), countStyle: .memory) + " / " + ByteCountFormatter.string(fromByteCount: Int64(type.retained), countStyle: .memory)).frame(width: 150) }.font(DevMono.font(11.5)).padding(8).contentShape(Rectangle())
                                }.buttonStyle(.plain).background(selected == type.name ? Color.accentColor.opacity(0.12) : .clear)
                                Divider()
                            }
                        }
                    }.frame(minHeight: 100)
                    VStack(spacing: 0) {
                        DevPanelBar {
                            Text("Objects").fontWeight(.medium)
                            if let selectedObject { Text("@\(selectedObject)") }
                            Spacer(minLength: 4)
                            Picker("References", selection: $detailMode) { Text("Retainers").tag("Retainers"); Text("Retained objects").tag("Retained objects"); Text("GC root path").tag("GC root path") }.labelsHidden().frame(maxWidth: 180)
                        }
                        HSplitView {
                            objectList(instances).frame(minWidth: 140)
                            if detailMode == "GC root path" { ThreadScrollView { DevDataRows(rows: rootPath) }.frame(minWidth: 140) }
                            else { objectList(detailMode == "Retainers" ? retainers : retained).frame(minWidth: 140) }
                        }
                    }.frame(minHeight: 100, idealHeight: 180)
                }
                Text("\(classes.reduce(0) { $0 + $1.count }.formatted()) objects · \(ByteCountFormatter.string(fromByteCount: Int64(classes.reduce(0) { $0 + $1.size }), countStyle: .memory)) shallow size").font(.system(size: 10)).foregroundStyle(Palette.muted).padding(8)
            }
        }
        .onChange(of: model.heapSnapshots.count, initial: true) { snapshot = max(0, model.heapSnapshots.count - 1) }
        .onChange(of: snapshot) { if model.heapSnapshots.indices.contains(snapshot) { model.heap = model.heapSnapshots[snapshot].classes; model.heapRaw = model.heapSnapshots[snapshot].raw; instances = []; retainers = []; retained = []; rootPath = []; selectedObject = nil } }
    }
    private var classes: [DevHeapClass] {
        var list = model.heap
        if mode == "Comparison", snapshot > 0, model.heapSnapshots.indices.contains(snapshot - 1) {
            let previous = Dictionary(uniqueKeysWithValues: model.heapSnapshots[snapshot - 1].classes.map { ($0.name, $0) })
            let current = Dictionary(uniqueKeysWithValues: list.map { ($0.name, $0) })
            list = Set(current.keys).union(previous.keys).map { name in DevHeapClass(name: name, count: (current[name]?.count ?? 0) - (previous[name]?.count ?? 0), size: (current[name]?.size ?? 0) - (previous[name]?.size ?? 0), retained: (current[name]?.retained ?? 0) - (previous[name]?.retained ?? 0)) }
        }
        return list.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }.sorted { $0.size > $1.size }
    }
    private func loadInstances(_ name: String) {
        model.heapEngine.read(model.heapRaw, method: "instancesWithClassName", arguments: [name]) { result, error in
            if let error { model.error = error; return }
            instances = ((result?["nodes"] as? [[String: Any]]) ?? []).prefix(200).compactMap(DevHeapObject.init)
            if let first = instances.first { inspect(first.id) }
        }
    }
    private func objectList(_ objects: [DevHeapObject]) -> some View {
        ThreadScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(objects) { object in
                    Button { inspect(object.id) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(object.name) @\(object.id)").lineLimit(1)
                            Text("\(object.size) shallow · \(object.retained) retained").foregroundStyle(Palette.muted)
                            Text("Dominator @\(object.dominator)").foregroundStyle(Palette.muted)
                        }.font(DevMono.font(11)).padding(8).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).background(selectedObject == object.id ? Color.accentColor.opacity(0.1) : .clear)
                    Divider()
                }
            }
        }
    }
    private func inspect(_ id: Int) {
        selectedObject = id
        for (method, key) in [("retainers", "retainers"), ("retainedNodes", "retainedNodes")] {
            model.heapEngine.read(model.heapRaw, method: method, arguments: [id]) { result, error in
                guard selectedObject == id else { return }
                if let error { model.error = error; return }
                let objects = (result?[key] as? [[String: Any]] ?? []).prefix(200).compactMap(DevHeapObject.init)
                if method == "retainers" { retainers = objects } else { retained = objects }
            }
        }
        model.heapEngine.read(model.heapRaw, method: "shortestGCRootPath", arguments: [id]) { result, error in
            guard selectedObject == id else { return }
            if let error { model.error = error; return }
            rootPath = (result?["nodes"] as? [[String: Any]] ?? []).enumerated().map { index, item in
                if let name = item["className"] as? String { return DevProperty(name: "\(index / 2 + 1)", value: name + " @\(item["id"] ?? 0)") }
                let type = item["type"] as? String ?? "Reference"
                let data = item["data"].map { String(describing: $0) } ?? ""
                return DevProperty(name: "via", value: type == "Index" ? "array[\(data)]" : type == "Property" ? "." + data : type + (data.isEmpty ? "" : " · " + data))
            }
        }
    }
    private func importSnapshot() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false
        guard let window = browser.devWindow else { return }
        panel.beginSheetModal(for: window) { result in guard result == .OK, let url = panel.url, let text = try? String(contentsOf: url, encoding: .utf8) else { return }; model.loadHeap(text) }
    }
}

private struct DevHeapObject: Identifiable {
    let id: Int
    let name: String
    let size: Int
    let retained: Int
    let dominator: Int
    init?(_ raw: [String: Any]) {
        guard let id = raw["id"] as? Int else { return nil }
        self.id = id; name = raw["className"] as? String ?? "Object"; size = raw["size"] as? Int ?? 0
        retained = raw["retainedSize"] as? Int ?? 0; dominator = raw["dominatorNodeIdentifier"] as? Int ?? 0
    }
}

extension DevWorkbench {
    func loadHeap(_ text: String) {
        busy = true
        heapEngine.read(text) { [weak self] result, error in
            guard let self else { return }
            if let error { self.error = error; self.busy = false; return }
            let categories = result?["categories"] as? [String: [String: Any]] ?? [:]
            self.heapRaw = text
            self.heap = categories.map { name, value in DevHeapClass(name: name, count: value["count"] as? Int ?? 0, size: value["size"] as? Int ?? 0, retained: value["retainedSize"] as? Int ?? 0) }
            self.heapSnapshots.append(("Snapshot \(self.heapSnapshots.count + 1)", self.heap, result?["totalSize"] as? Int ?? 0, text))
            self.busy = false
        }
    }
}
extension Browser {
    func memorySnapshot() {
        guard let model = workbench else { return }; model.busy = true
        workCall("memory.snapshot") { [weak model] value in if let text = (value as? [String: Any])?["snapshotData"] as? String { model?.loadHeap(text) } }
    }
}
