import AppKit
import SwiftUI

// Network's Search at the side and its drawer, Network conditions and
// Request conditions, as Chromium's (DevNet.swift, DevNetPane.swift).

// MARK: - Search

/// ⌘F in Network: every request's address, headers and words of its
/// response, matched as typed, the case or a regular expression if asked.
struct NetSearchSide: View {
    let browser: Browser
    var log: NetLog
    @Bindable var panel: NetPanel
    @FocusState private var focused: Bool

    struct Hit: Identifiable {
        let id: String
        let row: NetRow
        let place: String
        let line: String
        let tab: NetDetailTab
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                // Aa and .* inside the field at its end, as Chromium's: the
                // words get what the side has left, never cut to "Sea".
                HStack(spacing: 0) {
                    Symbol("magnifyingglass", size: 10).foregroundStyle(Palette.muted)
                        .padding(.trailing, 4)
                    TextField("Search", text: $panel.query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5))
                        .focused($focused)
                        .onSubmit { refresh() }
                        .onExitCommand { panel.searchOpen = false }
                        .frame(minWidth: 0, maxWidth: .infinity)
                    toggle("Aa", "Match case", $panel.matchCase)
                    toggle(".*", "Use regular expression", $panel.regex)
                }
                .padding(.leading, 6)
                .frame(height: ButtonSize.small.height)
                .background(Palette.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                Button { refresh() } label: { Symbol("arrow.clockwise", size: 11) }
                    .buttonStyle(.yab(.quiet, .small, icon: .square))
                    .keyTip("Refresh")
                Button { panel.query = "" } label: { Symbol("nosign", size: 11) }
                    .buttonStyle(.yab(.quiet, .small, icon: .square))
                    .keyTip("Clear search")
            }
            .padding(6)
            Rectangle().fill(Palette.ink.opacity(0.06)).frame(height: 1)
            results
        }
        .onAppear {
            if panel.focusSearch { focused = true; panel.focusSearch = false }
            refresh()
        }
        .onChange(of: panel.focusSearch) { if panel.focusSearch { focused = true; panel.focusSearch = false } }
        // As typed: responses that came since are read too, a beat after
        // the last key, as Chromium looks again.
        .task(id: panel.query) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, !panel.query.isEmpty else { return }
            refresh()
        }
    }

    private func toggle(_ title: String, _ tip: String, _ value: Binding<Bool>) -> some View {
        Button { value.wrappedValue.toggle() } label: { Text(title).font(DevMono.font(11.5, weight: .semibold)) }
            .buttonStyle(.yab(value.wrappedValue ? .secondary : .quiet, .small, icon: .square))
            .keyTip(tip)
    }

    /// The words of every response read, so the search can look in them.
    private func refresh() {
        let wanted = log.rows.filter { row in
            guard row.hop == nil, row.finished, !row.failed else { return false }
            let mime = row.resource.mime
            return !(mime.hasPrefix("image/") || mime.hasPrefix("video/") || mime.hasPrefix("audio/") || mime.contains("font") || mime.contains("wasm"))
        }
        guard !wanted.isEmpty else { return }
        panel.searching = true
        browser.netLoadBodies(wanted, limit: 400) { _ in panel.searching = false }
    }

    @ViewBuilder private var results: some View {
        let query = panel.query
        if query.isEmpty {
            NetNote(words: "Search headers, payloads and responses of every request.")
            Spacer(minLength: 0)
        } else {
            // Bodies are kept unobserved: the search runs again when their loading ends.
            let searching = panel.searching
            let hits = Self.search(query, in: log, matchCase: panel.matchCase, regex: panel.regex)
            let grouped = Dictionary(grouping: hits, by: \.row.id)
            let order = hits.map(\.row.id).reduce(into: [Int]()) { if !$0.contains($1) { $0.append($1) } }
            ThreadScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Text(hits.isEmpty ? (searching ? "Searching…" : "No matches found.") : "Found \(hits.count) matching line\(hits.count == 1 ? "" : "s") in \(order.count) request\(order.count == 1 ? "" : "s").")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                        .padding(8)
                    ForEach(order, id: \.self) { id in
                        let group = grouped[id] ?? []
                        if let first = group.first {
                            HStack(spacing: 6) {
                                Text(first.row.name).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                                Text(first.row.host).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
                            }
                            .padding(.horizontal, 8)
                            .padding(.top, 4)
                            ForEach(group.prefix(20)) { hit in
                                Button {
                                    panel.selected = hit.row.id
                                    panel.detail = hit.tab
                                } label: {
                                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                                        Text(hit.place).foregroundStyle(Palette.muted)
                                        Text(hit.line).lineLimit(1)
                                    }
                                    .font(DevMono.font(11))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.leading, 20) // design: a hit under its request's name, as Chromium's
                                    .padding(.trailing, 8) // design: a hit under its request's name, as Chromium's
                                    .frame(height: 20)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
    }

    static func search(_ query: String, in log: NetLog, matchCase: Bool, regex: Bool) -> [Hit] {
        let options: NSRegularExpression.Options = matchCase ? [] : [.caseInsensitive]
        guard let pattern = try? NSRegularExpression(pattern: regex ? query : NSRegularExpression.escapedPattern(for: query), options: options) else { return [] }
        func hits(_ text: String) -> Bool { pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil }
        var out: [Hit] = []
        for row in log.rows {
            if hits(row.url) { out.append(Hit(id: "\(row.id)-u", row: row, place: "URL", line: row.url, tab: .headers)) }
            for (i, h) in row.responseHeaders.enumerated() where hits("\(h.name): \(h.value)") {
                out.append(Hit(id: "\(row.id)-r\(i)", row: row, place: "Response", line: "\(h.name): \(h.value)", tab: .headers))
            }
            for (i, h) in row.requestHeaders.enumerated() where hits("\(h.name): \(h.value)") {
                out.append(Hit(id: "\(row.id)-q\(i)", row: row, place: "Request", line: "\(h.name): \(h.value)", tab: .headers))
            }
            if row.hop == nil, let body = log.bodies[row.resource.id], !body.base64, body.text.utf8.count < 2_000_000 {
                var number = 0
                body.text.enumerateLines { line, stop in
                    number += 1
                    if hits(line) {
                        let shown = line.count > 200 ? String(line.prefix(200)) + "…" : line
                        out.append(Hit(id: "\(row.id)-b\(number)", row: row, place: String(number), line: shown.trimmingCharacters(in: .whitespaces), tab: .response))
                        if out.count > 5000 { stop = true }
                    }
                }
            }
            if out.count > 5000 { break }
        }
        return out
    }
}

// MARK: - the drawer

struct NetDrawerView: View {
    let browser: Browser
    var log: NetLog
    @Bindable var panel: NetPanel
    @Bindable var prefs: NetPrefs
    let drawer: NetDrawer
    var pick: ((NetDrawer) -> Void)? = nil
    var close: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 1) {
                ForEach([NetDrawer.conditions, .rules], id: \.self) { item in
                    Button { if let pick { pick(item) } else { panel.drawer = item } } label: { Text(item.rawValue).font(.system(size: 11.5, weight: .medium)).fixedSize() }
                        .buttonStyle(.yab(drawer == item ? .secondary : .quiet, .small))
                }
                Spacer()
                Button { if let close { close() } else { panel.drawer = nil } } label: { Symbol("xmark", size: 11) }
                    .buttonStyle(.yab(.quiet, .small, icon: .square))
                    .keyTip("Close")
            }
            .focusable(false)
            .padding(.horizontal, 6)
            .frame(height: 28)
            .background(Palette.ink.opacity(0.025))
            Rectangle().fill(Palette.ink.opacity(0.06)).frame(height: 1)
            ThreadScrollView {
                Group {
                    switch drawer {
                    case .conditions: conditions
                    case .rules: rules
                    }
                }
                .font(.system(size: 11.5))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onChange(of: prefs.noCache) { browser.netApplyConditions() }
        .onChange(of: prefs.throttle) { browser.netApplyConditions() }
        .onChange(of: prefs.rules) { browser.netApplyConditions() }
        .onChange(of: prefs.rulesOn) { browser.netApplyConditions() }
        .onChange(of: prefs.userAgent) { browser.netApplyConditions() }
        .onChange(of: prefs.saveData) { browser.netApplyConditions() }
    }

    // MARK: Network conditions

    private var conditions: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 10) {
            GridRow {
                Text("Caching").fontWeight(.semibold)
                Toggle("Disable cache", isOn: $prefs.noCache).toggleStyle(NetCheckboxStyle()).controlSize(.small)
            }
            GridRow {
                Text("Network").fontWeight(.semibold)
                HStack(spacing: 8) {
                    Picker("", selection: $prefs.throttle) {
                        Text(NetThrottle.none.name).tag(NetThrottle.none.id)
                        Divider()
                        ForEach(NetThrottle.presets + [NetThrottle.offline] + prefs.profiles) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                    Picker("", selection: Binding(get: { prefs.saveData ?? "default" }, set: { prefs.saveData = $0 == "default" ? nil : $0 })) {
                        Text("‘Save-Data’: default").tag("default")
                        Text("‘Save-Data’: on").tag("on")
                        Text("‘Save-Data’: off").tag("off")
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                }
            }
            GridRow {
                Text("User agent").fontWeight(.semibold)
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Use browser default", isOn: Binding(get: { prefs.userAgent == nil }, set: { prefs.userAgent = $0 ? nil : NetAgents.all[0].1 }))
                        .toggleStyle(NetCheckboxStyle())
                        .controlSize(.small)
                    if prefs.userAgent != nil {
                        Picker("", selection: Binding(get: { NetAgents.all.first { $0.1 == prefs.userAgent }?.1 ?? "custom" }, set: { if $0 != "custom" { prefs.userAgent = $0 } })) {
                            ForEach(NetAgents.all, id: \.1) { Text($0.0).tag($0.1) }
                            Text("Custom…").tag("custom")
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .fixedSize()
                        TextField("User agent", text: Binding(get: { prefs.userAgent ?? "" }, set: { prefs.userAgent = $0 }))
                            .textFieldStyle(.roundedBorder)
                            .font(DevMono.font(11))
                    }
                }
            }
            GridRow {
                Text("Custom profiles").fontWeight(.semibold)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach($prefs.profiles) { $profile in
                        let remove = prefs.profileRemovalAction(id: profile.id)
                        HStack(spacing: 6) {
                            TextField("Profile name", text: $profile.name).textFieldStyle(.roundedBorder).frame(width: 120)
                            number("Download", $profile.download, "kbit/s")
                            number("Upload", $profile.upload, "kbit/s")
                            number("Latency", $profile.latency, "ms")
                            Button(action: remove) { Symbol("xmark", size: 11) }
                                .buttonStyle(.yab(.quiet, .small, icon: .square))
                                .keyTip("Remove")
                        }
                    }
                    Button("Add profile") { prefs.addProfile() }
                        .buttonStyle(.yab(.quiet, .small))
                    Text("User agent client hints aren’t offered: WebKit sends none.")
                        .foregroundStyle(Palette.muted)
                }
            }
        }
    }

    private func number(_ title: String, _ value: Binding<Double>, _ unit: String) -> some View {
        HStack(spacing: 4) {
            TextField(title, value: value, format: .number).textFieldStyle(.roundedBorder).frame(width: 64)
            Text(unit).foregroundStyle(Palette.muted).fixedSize()
        }
    }

    // MARK: Request conditions

    private var rules: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Toggle("Enable blocking and throttling", isOn: $prefs.rulesOn).toggleStyle(NetCheckboxStyle()).controlSize(.small)
                Spacer()
                Button { prefs.rules.append(NetPrefs.Rule(on: true, pattern: "", condition: "block")) } label: { Symbol("plus", size: 11) }
                    .buttonStyle(.yab(.quiet, .small, icon: .square))
                    .keyTip("Add network request blocking or throttling pattern")
                Button { prefs.rules = [] } label: { Symbol("nosign", size: 11) }
                    .buttonStyle(.yab(.quiet, .small, icon: .square))
                    .keyTip("Remove all network request blocking or throttling patterns")
                    .disabled(prefs.rules.isEmpty)
            }
            if prefs.rules.isEmpty {
                VStack(spacing: 6) {
                    Text("Nothing throttled or blocked").fontWeight(.semibold)
                    Text("To throttle or block a network request, add a rule here manually or via the Network panel’s context menu.")
                        .foregroundStyle(Palette.muted)
                        .multilineTextAlignment(.center)
                    Button("Add rule") { prefs.rules.append(NetPrefs.Rule(on: true, pattern: "", condition: "block")) }
                        .buttonStyle(.yab(.secondary, .small))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            } else {
                ForEach(Array(prefs.rules.enumerated()), id: \.element.id) { index, rule in
                    HStack(spacing: 6) {
                        Toggle("", isOn: Binding(get: { rule.on }, set: { on in prefs.rules[index].on = on }))
                            .toggleStyle(NetCheckboxStyle())
                            .labelsHidden()
                            .controlSize(.small)
                            .pointerTip("Throttle or block \(rule.pattern)")
                        TextField("Text pattern to block or throttle matching requests; use * for wildcard", text: Binding(get: { rule.pattern }, set: { prefs.rules[index].pattern = $0 }))
                            .textFieldStyle(.roundedBorder)
                            .font(DevMono.font(11))
                        Picker("", selection: Binding(get: { rule.condition }, set: { prefs.rules[index].condition = $0 })) {
                            Section("Blocking") { Text("Block").tag("block") }
                            Section("Presets") { ForEach(NetThrottle.presets) { Text($0.name).tag($0.id) } }
                            if !prefs.profiles.isEmpty { Section("Custom") { ForEach(prefs.profiles) { Text($0.name).tag($0.id) } } }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .fixedSize()
                        Text("\(affected(rule)) affected").foregroundStyle(Palette.muted).fixedSize()
                        Button { move(index, by: -1) } label: { Symbol("chevron.up", size: 11) }
                            .buttonStyle(.yab(.quiet, .small, icon: .square))
                            .keyTip("Move up \(rule.pattern)")
                            .disabled(index == 0)
                        Button { move(index, by: 1) } label: { Symbol("chevron.down", size: 11) }
                            .buttonStyle(.yab(.quiet, .small, icon: .square))
                            .keyTip("Move down \(rule.pattern)")
                            .disabled(index == prefs.rules.count - 1)
                        Button { prefs.rules.remove(at: index) } label: { Symbol("xmark", size: 11) }
                            .buttonStyle(.yab(.quiet, .small, icon: .square))
                            .keyTip("Remove")
                    }
                }
                Text("The first rule that matches wins. Applies from the next request.")
                    .foregroundStyle(Palette.muted)
            }
        }
    }

    private func affected(_ rule: NetPrefs.Rule) -> Int {
        guard !rule.pattern.isEmpty, let regex = NetFilter.glob(rule.pattern) else { return 0 }
        return log.rows.filter { row in
            regex.firstMatch(in: row.url, range: NSRange(row.url.startIndex..., in: row.url)) != nil || row.url.contains(rule.pattern)
        }.count
    }

    private func move(_ index: Int, by step: Int) {
        let to = index + step
        guard prefs.rules.indices.contains(to) else { return }
        prefs.rules.swapAt(index, to)
    }
}

/// User agents to pretend to be, as Chromium's list has them.
enum NetAgents {
    static let all: [(String, String)] = [
        ("Chrome on Mac", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36"),
        ("Chrome on Windows", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36"),
        ("Chrome on Android", "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Mobile Safari/537.36"),
        ("Chrome on iPhone", "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/141.0.0.0 Mobile/15E148 Safari/604.1"),
        ("Firefox on Mac", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:143.0) Gecko/20100101 Firefox/143.0"),
        ("Firefox on Windows", "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:143.0) Gecko/20100101 Firefox/143.0"),
        ("Microsoft Edge on Windows", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36 Edg/141.0.0.0"),
        ("Safari on Mac", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"),
        ("Safari on iPhone", "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"),
        ("Safari on iPad", "Mozilla/5.0 (iPad; CPU OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"),
        ("Googlebot", "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)"),
        ("Googlebot Smartphone", "Mozilla/5.0 (Linux; Android 6.0.1; Nexus 5X Build/MMB29P) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Mobile Safari/537.36 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)"),
    ]
}
