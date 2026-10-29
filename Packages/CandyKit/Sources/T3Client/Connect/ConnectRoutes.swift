import Foundation

/// A direct address a T3 Connect environment reports in `ServerConfig.directEndpoints`
/// (contracts/src/server.ts:638-641, 667). The client "learns" it and prefers it over the tunnel,
/// reusing the T3 Connect access token with a proof per URL (protocol.md 10.6,
/// client-runtime/src/connection/routes.ts:216-299, authorization/service.ts:72-80).
public struct DirectRoute: Sendable, Equatable {
    public enum Kind: Int, Sendable, Comparable {
        // ROUTE_KIND_RANK (routes.ts:110-117). SSH sits between public and relay.
        case loopback, lan, tailnet, `public`, ssh, relay
        public static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }

    public var httpBaseUrl: String
    public var wsBaseUrl: String
    public var kind: Kind
}

public enum ConnectRoutes {
    /// While on a fallback route, look for a better one this often (supervisor.ts:44-46).
    public static let betterRouteCheckInterval: Duration = .seconds(60)
    /// A better route that passed the check but failed to connect is skipped this long (supervisor.ts:47-49).
    public static let betterRouteCooldown: Duration = .seconds(300)

    /// Learned routes from the reported addresses, best first: loopback addresses dropped (they
    /// name whichever device opens them), one per origin, ranked LAN, tailnet, public (stable).
    /// `http` is allowed: a native client has no mixed-content rule (routes.ts:240-252).
    /// Before sending a credential to one, check its descriptor names the same environment
    /// (`T3ConnectAuthorizer.authorizeSocket(directEndpoint:)` does).
    public static func learned(from reported: [String]) -> [DirectRoute] {
        var seen = Set<String>()
        var routes: [DirectRoute] = []
        for raw in reported {
            guard let c = URLComponents(string: raw), let scheme = c.scheme?.lowercased(),
                  scheme == "http" || scheme == "https", let host = c.host, !host.isEmpty else { continue }
            let kind = kind(host: host)
            if kind == .loopback { continue }
            let bare = normalize(host)
            let hostPart = bare.contains(":") ? "[\(bare)]" : bare
            let defaultPort = scheme == "https" ? 443 : 80
            let authority = hostPart + (c.port.flatMap { $0 == defaultPort ? nil : ":\($0)" } ?? "")
            let origin = "\(scheme)://\(authority)"
            guard seen.insert(origin).inserted else { continue }
            routes.append(DirectRoute(httpBaseUrl: origin + "/", wsBaseUrl: "\(scheme == "https" ? "wss" : "ws")://\(authority)/", kind: kind))
        }
        // Swift's sort is not stable; keep reported order within a kind.
        return routes.enumerated().sorted { ($0.element.kind, $0.offset) < ($1.element.kind, $1.offset) }.map(\.element)
    }

    /// The addresses a link offers a host for one machine (linkRequest.ts:96-115): reported, then saved routes, then
    /// T3 Connect, each once. A loopback address names whichever machine opens it, so only a host on this device gets one.
    public static func linkURLs(reported: [String], routes: [String], connect: String?, hostIsLocal: Bool) -> [String] {
        var urls: [String] = []
        for u in reported + routes + [connect].compactMap({ $0 }) where !urls.contains(u) {
            if !hostIsLocal, let host = URLComponents(string: u)?.host, kind(host: host) == .loopback { continue }
            urls.append(u)
        }
        return urls
    }

    /// `connectionRouteKind` for a direct host (routes.ts:89-103, shared/src/hostClassification.ts).
    public static func kind(host: String) -> DirectRoute.Kind {
        let h = normalize(host)
        if isLoopback(h) { return .loopback }
        if isTailnet(h) { return .tailnet }
        return isPrivate(h) ? .lan : .public
    }

    static func normalize(_ host: String) -> String {
        var h = host.lowercased()
        if h.hasPrefix("["), h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
        while h.hasSuffix(".") { h.removeLast() }
        return h
    }

    static func ipv4(_ h: String) -> [Int]? {
        let parts = h.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ ($0 ?? -1) >= 0 && ($0 ?? 256) <= 255 }) else { return nil }
        return parts.map { $0! }
    }

    /// Hextets of an IPv6 literal, or nil.
    static func ipv6(_ h: String) -> [Int]? {
        guard h.contains(":") else { return nil }
        let halves = h.components(separatedBy: "::")
        guard halves.count <= 2 else { return nil }
        let head = halves[0].isEmpty ? [] : halves[0].split(separator: ":").map(String.init)
        let tail = halves.count == 2 && !halves[1].isEmpty ? halves[1].split(separator: ":").map(String.init) : []
        let all = head + tail
        guard all.allSatisfy({ (1...4).contains($0.count) && Int($0, radix: 16) != nil }) else { return nil }
        let missing = 8 - all.count
        if halves.count == 1 ? missing != 0 : missing < 1 { return nil }
        return head.map { Int($0, radix: 16)! } + Array(repeating: 0, count: halves.count == 2 ? missing : 0) + tail.map { Int($0, radix: 16)! }
    }

    static func isLoopback(_ h: String) -> Bool {
        h == "localhost" || h == "::1" || ipv4(h)?.first == 127
    }

    static func isTailnet(_ h: String) -> Bool {
        if h.hasSuffix(".ts.net") { return true }
        if let p = ipv4(h) { return p[0] == 100 && (64...127).contains(p[1]) }
        if let p = ipv6(h) { return p[0] == 0xfd7a && p[1] == 0x115c && p[2] == 0xa1e0 }
        return false
    }

    static func isPrivate(_ h: String) -> Bool {
        if h == "::" || isLoopback(h) || h.hasSuffix(".localhost") || h.hasSuffix(".local") || h == "home.arpa"
            || h.hasSuffix(".home.arpa") || (!h.contains(".") && !h.contains(":")) || h.hasSuffix(".ts.net") {
            return true
        }
        var v4 = ipv4(h)
        if v4 == nil, h.hasPrefix("::ffff:") {
            let suffix = String(h.dropFirst(7))
            v4 = ipv4(suffix)
            if v4 == nil {
                let x = suffix.split(separator: ":").compactMap { Int($0, radix: 16) }
                if x.count == 2, suffix.split(separator: ":").count == 2 { v4 = [x[0] >> 8, x[0] & 0xff, x[1] >> 8, x[1] & 0xff] }
            }
        }
        if let p = v4 {
            return p[0] == 0 || p[0] == 10 || p[0] == 127 || (p[0] == 100 && (64...127).contains(p[1]))
                || (p[0] == 172 && (16...31).contains(p[1])) || (p[0] == 192 && p[1] == 168)
                || (p[0] == 169 && p[1] == 254) || (p[0] == 198 && (18...19).contains(p[1]))
        }
        guard h.contains(":"), let first = h.split(separator: ":", omittingEmptySubsequences: false).first,
              (1...4).contains(first.count), let hextet = Int(first, radix: 16) else { return false }
        return hextet & 0xfe00 == 0xfc00 || hextet & 0xffc0 == 0xfe80
    }
}
