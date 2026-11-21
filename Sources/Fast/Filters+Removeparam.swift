import Foundation

// Tracking parameters: Yab's own names (copy, share, open) and the lists' $removeparam rules (open only).

extension Filters {
    // MARK: - Yab's own names

    /// Narrow on purpose: `ref`, `source` and `feature` are often the page's own.
    static func tracking(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasPrefix("utm_") || trackingNames.contains(lower)
    }

    private static let trackingNames: Set<String> = [
        "fbclid", "gclid", "dclid", "yclid", "msclkid", "igshid", "mc_cid", "mc_eid", "_ga", "_gl",
        "ref_src", "ref_url", "si",
    ]

    /// Nil when nothing is dropped; kept pairs and the fragment stay as written.
    static func removing(_ url: URL, _ drop: (_ name: String, _ value: String) -> Bool) -> URL? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = parts.percentEncodedQueryItems, !items.isEmpty else { return nil }
        let decoded = parts.queryItems ?? []
        let kept = zip(items, decoded).filter { !drop($0.1.name, $0.1.value ?? "") }.map(\.0)
        guard kept.count < items.count else { return nil }
        parts.percentEncodedQueryItems = kept.isEmpty ? nil : kept
        return parts.url
    }

    // MARK: - removeparam

    /// Kept only when it reaches a top document: no load kinds named, or `doc` among them.
    struct Removal: Codable, Hashable, Sendable {
        enum Parameter: Codable, Hashable, Sendable {
            case all
            case named(String)
            case allBut(String)
            /// Matched against "name=value", as uBlock Origin does.
            case matching(String, caseSensitive: Bool)
        }

        var parameter: Parameter
        var pattern: String?
        var caseSensitive = false
        /// A `||host^` pattern's host, checked before the regex.
        var host: String?
        /// For a top document, $domain, $from and $to all name the document's own site.
        var hosts: [String] = []
        var notHosts: [String] = []
        var exception = false
    }

    private static let otherLoads: Set<String> = [
        "xhr", "xmlhttprequest", "script", "image", "stylesheet", "css", "font", "media", "subdocument", "frame",
        "object", "other", "ping", "beacon", "websocket", "popup",
    ]

    static func removalRule(_ line: String) -> Removal? {
        guard let parts = optionParts(line, with: "removeparam") else { return nil }
        var removal = Removal(parameter: .all, exception: parts.exception)
        var others = false, document = false, sites = false
        for (name, value) in parts.options {
            switch name {
            case "removeparam":
                guard let value, !value.isEmpty else { continue }
                guard let parameter = parameter(value) else { return nil }
                removal.parameter = parameter
            case "doc", "document":
                document = true
            case "1p", "first-party", "~3p", "~third-party", "important", "reason":
                continue
            case "match-case":
                removal.caseSensitive = true
            case "domain", "from", "to":
                guard !sites, let value else { return nil }
                sites = true
                for entry in value.split(separator: "|", omittingEmptySubsequences: false) {
                    let negated = entry.hasPrefix("~")
                    let domain = (negated ? entry.dropFirst() : entry).lowercased()
                    guard !domain.isEmpty, !domain.hasPrefix("."), !domain.hasSuffix("."),
                          domain.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_") })
                    else { return nil }
                    if negated { removal.notHosts.append(domain) } else { removal.hosts.append(domain) }
                }
            default:
                if otherLoads.contains(name) { others = true; continue }
                if name.hasPrefix("~"), otherLoads.contains(String(name.dropFirst())) { continue }
                return nil
            }
        }
        if others, !document { return nil }
        let pattern = parts.pattern
        if pattern.hasPrefix("/"), pattern.hasSuffix("/"), pattern.count > 2 {
            let source = String(pattern.dropFirst().dropLast())
            guard (try? NSRegularExpression(pattern: source)) != nil else { return nil }
            removal.pattern = source
        } else if !(pattern.isEmpty || pattern == "*" || everywhere(pattern)) {
            guard let filter = urlFilter(pattern) else { return nil }
            removal.pattern = filter
            removal.host = anchorHost(pattern)
        }
        // Every parameter of every page would break pages.
        if removal.parameter == .all, !removal.exception, removal.pattern == nil, removal.hosts.isEmpty { return nil }
        return removal
    }

    private static func parameter(_ value: Substring) -> Removal.Parameter? {
        if value.hasPrefix("/") {
            let caseless = value.hasSuffix("/i")
            let body = value.dropFirst().dropLast(caseless ? 2 : 1)
            guard value.count > (caseless ? 3 : 2), (caseless || value.hasSuffix("/")),
                  (try? NSRegularExpression(pattern: String(body))) != nil else { return nil }
            return .matching(String(body), caseSensitive: !caseless)
        }
        if value.hasPrefix("~") {
            let name = value.dropFirst()
            return name.isEmpty ? nil : .allBut(String(name))
        }
        return .named(String(value))
    }

    private static func anchorHost(_ pattern: Substring) -> String? {
        guard pattern.hasPrefix("||") else { return nil }
        let rest = pattern.dropFirst(2)
        let host = rest.prefix { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_") }
        let next = rest[host.endIndex...].first
        guard !host.isEmpty, !host.hasSuffix("."), next == nil || next == "^" || next == "/" || next == ":" else { return nil }
        return host.lowercased()
    }

    final class Remover: @unchecked Sendable {
        private struct Ready {
            let removal: Removal
            let pattern: NSRegularExpression?
            let value: NSRegularExpression?
        }

        /// Named, for every address: most of the lists' rules.
        private let everywhere: Set<String>
        /// By the host a rule's pattern or $domain names.
        private let bySite: [String: [Ready]]
        private let others: [Ready]
        private let exceptions: [Ready]
        let count: Int

        init(_ all: [Removal]) {
            let ready = all.compactMap { removal -> Ready? in
                var pattern: NSRegularExpression?
                if let source = removal.pattern {
                    guard let compiled = try? NSRegularExpression(pattern: source, options: removal.caseSensitive ? [] : [.caseInsensitive]) else { return nil }
                    pattern = compiled
                }
                var value: NSRegularExpression?
                if case .matching(let source, let caseSensitive) = removal.parameter {
                    guard let compiled = try? NSRegularExpression(pattern: source, options: caseSensitive ? [] : [.caseInsensitive]) else { return nil }
                    value = compiled
                }
                return Ready(removal: removal, pattern: pattern, value: value)
            }
            var everywhere = Set<String>(), bySite: [String: [Ready]] = [:], others: [Ready] = []
            for ready in ready where !ready.removal.exception {
                let removal = ready.removal
                if let anchor = removal.host {
                    bySite[anchor, default: []].append(ready)
                } else if !removal.hosts.isEmpty {
                    for host in removal.hosts { bySite[host, default: []].append(ready) }
                } else if case .named(let name) = removal.parameter, removal.pattern == nil, removal.notHosts.isEmpty {
                    everywhere.insert(name)
                } else {
                    others.append(ready)
                }
            }
            self.everywhere = everywhere
            self.bySite = bySite
            self.others = others
            exceptions = ready.filter(\.removal.exception)
            count = ready.count - exceptions.count
        }

        func clean(_ url: URL) -> URL? {
            let address = url.absoluteString
            guard url.query != nil, address.utf8.count <= 8192 else { return nil }
            let host = url.host()?.lowercased() ?? ""
            let whole = NSRange(address.startIndex..., in: address)
            func applies(_ ready: Ready) -> Bool {
                let removal = ready.removal
                if let anchor = removal.host, !Remover.on(host, anchor) { return false }
                if !removal.hosts.isEmpty, !removal.hosts.contains(where: { Remover.on(host, $0) }) { return false }
                if removal.notHosts.contains(where: { Remover.on(host, $0) }) { return false }
                return ready.pattern.map { $0.firstMatch(in: address, range: whole) != nil } ?? true
            }
            let spared = exceptions.filter(applies)
            if spared.contains(where: { $0.removal.parameter == .all }) { return nil }
            var sites: [Substring] = [Substring(host)]
            while let dot = sites[sites.count - 1].firstIndex(of: ".") { sites.append(sites[sites.count - 1][host.index(after: dot)...]) }
            let removing = (sites.flatMap { bySite[String($0)] ?? [] } + others).filter(applies)
            return Filters.removing(url) { name, value in
                let pair = name + "=" + value
                guard Filters.tracking(name) || everywhere.contains(name) || removing.contains(where: { Remover.drops($0, name, pair) }) else { return false }
                // Broader than uBlock Origin, which spares only the identical value.
                return !spared.contains { Remover.drops($0, name, pair) }
            }
        }

        private static func drops(_ ready: Ready, _ name: String, _ pair: String) -> Bool {
            switch ready.removal.parameter {
            case .all: return true
            case .named(let named): return name == named
            case .allBut(let kept): return name != kept
            case .matching: return ready.value?.firstMatch(in: pair, range: NSRange(pair.startIndex..., in: pair)) != nil
            }
        }

        private static func on(_ host: String, _ domain: String) -> Bool {
            host == domain || host.hasSuffix("." + domain)
        }
    }
}
