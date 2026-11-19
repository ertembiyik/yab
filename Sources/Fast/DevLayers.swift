import AppKit
import SwiftUI

struct DevLayer: Identifiable {
    var id: String
    var node: Int
    var bounds: CGRect
    var paints: Int
    var memory: Int
}

struct DevLayersPane: View {
    let browser: Browser
    var model: DevWorkbench
    @State private var layers: [DevLayer] = []
    @State private var selected = ""
    @State private var reasons: [DevProperty] = []
    @State private var image: NSImage?
    @State private var zoom = 1.0
    @State private var separation = 0.0
    var body: some View {
        VStack(spacing: 0) {
            DevPanelBar {
                Button("Refresh") { refresh() }
                Text("Zoom"); Slider(value: $zoom, in: 0.25...2).frame(width: 90)
                Text("Separate layers"); Slider(value: $separation, in: 0...24).frame(width: 90)
                Spacer(minLength: 4)
                Button("Reveal in Elements") { if let layer = layers.first(where: { $0.id == selected }) { browser.pickDevPane(.elements); browser.elementsSelect(layer.node) } }.disabled(selected.isEmpty)
            }
            Divider()
            VSplitView {
                GeometryReader { geometry in
                    ThreadScrollView([.horizontal, .vertical]) {
                        drawing.frame(width: max(geometry.size.width, extent.width * zoom + 40), height: max(geometry.size.height, extent.height * zoom + 40))
                    }
                }.frame(minHeight: 100)
                HSplitView {
                    ThreadScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(layers) { layer in
                                Button { select(layer) } label: {
                                    HStack {
                                        Text("Node \(layer.node)").lineLimit(1)
                                        Spacer(minLength: 0)
                                        Text("\(Int(layer.bounds.width)) × \(Int(layer.bounds.height)) · \(layer.paints) paints").foregroundStyle(Palette.muted)
                                    }.font(.system(size: 11.5)).padding(8).contentShape(Rectangle())
                                }.buttonStyle(.plain).background(selected == layer.id ? Color.accentColor.opacity(0.12) : .clear)
                            }
                        }
                    }.frame(minWidth: 180)
                    ThreadScrollView {
                        DevDataRows(rows: reasons)
                        if let image { Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 180).padding(8) }
                    }.frame(minWidth: 160)
                }.frame(minHeight: 100, idealHeight: 180)
            }
            Text("\(layers.count) composited layers · \(ByteCountFormatter.string(fromByteCount: Int64(layers.reduce(0) { $0 + $1.memory }), countStyle: .memory)) estimated backing memory").font(.system(size: 10)).foregroundStyle(Palette.muted).padding(8)
        }
        .onAppear(perform: refresh)
        .onChange(of: model.layerRevision) { refresh() }
    }
    private var extent: CGSize {
        CGSize(width: (layers.map { $0.bounds.maxX }.max() ?? 1) + separation * Double(layers.count), height: (layers.map { $0.bounds.maxY }.max() ?? 1) + separation * Double(layers.count))
    }
    private var drawing: some View {
        Canvas { context, _ in
            for (i, layer) in layers.enumerated() {
                let rect = projected(layer, i)
                let color = layer.id == selected ? Color.accentColor : Color.blue.opacity(0.25)
                context.fill(Path(rect), with: .color(color.opacity(0.2)))
                context.stroke(Path(rect), with: .color(color), lineWidth: layer.id == selected ? 2 : 1)
                context.draw(Text("Node \(layer.node)").font(.system(size: 10)).foregroundStyle(Palette.ink), at: CGPoint(x: rect.minX + 4, y: rect.minY + 4), anchor: .topLeading)
            }
        }
        .onTapGesture { point in
            if let pair = layers.enumerated().reversed().first(where: { projected($0.element, $0.offset).contains(point) }) { select(pair.element) }
        }
    }
    private func projected(_ layer: DevLayer, _ index: Int) -> CGRect {
        let shift = CGFloat(index) * separation
        return CGRect(x: layer.bounds.minX * zoom + shift + 16, y: layer.bounds.minY * zoom + shift + 16, width: layer.bounds.width * zoom, height: layer.bounds.height * zoom)
    }
    private func refresh() {
        browser.workCall("tools.layers", ["id": 0]) { value in
            layers = ((value as? [String: Any])?["layers"] as? [[String: Any]] ?? []).compactMap { raw in
                guard let id = raw["layerId"] as? String else { return nil }
                let b = raw["bounds"] as? [String: Any] ?? [:]
                return DevLayer(id: id, node: raw["nodeId"] as? Int ?? 0, bounds: CGRect(x: b["x"] as? Double ?? 0, y: b["y"] as? Double ?? 0, width: b["width"] as? Double ?? 0, height: b["height"] as? Double ?? 0), paints: raw["paintCount"] as? Int ?? 0, memory: raw["memory"] as? Int ?? 0)
            }
        }
    }
    private func select(_ layer: DevLayer) {
        selected = layer.id; image = nil
        browser.workCall("LayerTree.reasonsForCompositingLayer", ["layerId": layer.id]) { value in
            let data = (value as? [String: Any])?["compositingReasons"] as? [String: Any] ?? [:]
            reasons = [DevProperty(name: "Node", value: String(layer.node)), DevProperty(name: "Backing size", value: ByteCountFormatter.string(fromByteCount: Int64(layer.memory), countStyle: .memory))]
            reasons += data.keys.sorted().filter { data[$0] as? Bool == true }.map { DevProperty(name: $0, value: "Compositing reason") }
        }
        browser.workCall("LayerTree.requestContent", ["layerId": layer.id]) { value in
            if let text = (value as? [String: Any])?["content"] as? String, let comma = text.firstIndex(of: ","), let data = Data(base64Encoded: String(text[text.index(after: comma)...])) { image = NSImage(data: data) }
        }
    }
}
