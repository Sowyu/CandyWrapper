import Foundation

/// Direct routes to a saved environment, T3's bearer routes (client-runtime connection/routes.ts).
/// A route is an HTTP origin. One environment can have several, preferred first; pairing the same
/// machine again over another address adds one instead of a second machine.
public enum EnvironmentRoute {
    /// `ConnectionRouteKind` without relay and SSH, in T3's preference order (`ROUTE_KIND_RANK`).
    public enum Kind: Int, Comparable, Sendable {
        case loopback, lan, tailnet, `public`
        public static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }

    /// `scheme://host[:port]`, lowercased, the route's identity (`bearerConnectionId` uses the origin).
    public static func origin(_ url: URL) -> String {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false), let scheme = c.scheme?.lowercased(),
              let host = c.host?.lowercased() else { return url.absoluteString }
        let defaultPort = scheme == "https" ? 443 : 80
        let shownHost = host.contains(":") ? "[\(host)]" : host
        return c.port.map { $0 == defaultPort ? "\(scheme)://\(shownHost)" : "\(scheme)://\(shownHost):\($0)" } ?? "\(scheme)://\(shownHost)"
    }

    /// The Keychain account for a route's bearer token: T3's connection id `bearer:<environmentId>:<origin>`.
    public static func connectionId(environmentId: String, _ url: URL) -> String {
        "bearer:\(environmentId):\(origin(url))"
    }

    public static func kind(_ url: URL) -> Kind {
        guard let host = url.host else { return .public }
        if HostClass.isLoopback(host) { return .loopback }
        if HostClass.isTailnet(host) { return .tailnet }
        return HostClass.isPrivateNetwork(host) ? .lan : .public
    }

    /// `connectionRouteLabel`: "This device", "LAN", "Tailscale", or the hostname.
    public static func label(_ url: URL) -> String {
        switch kind(url) {
        case .loopback: "This device"
        case .lan: "LAN"
        case .tailnet: "Tailscale"
        case .public: url.host ?? "Remote link"
        }
    }

    /// `upsertRoute`: replaces the route with the same origin in place, else inserts it after every
    /// route of the same or a faster kind (`insertRoute`).
    public static func upsert(_ url: URL, into routes: [URL]) -> [URL] {
        if let i = routes.firstIndex(where: { origin($0) == origin(url) }) {
            var next = routes
            next[i] = url
            return next
        }
        let rank = kind(url)
        guard let i = routes.firstIndex(where: { kind($0) > rank }) else { return routes + [url] }
        var next = routes
        next.insert(url, at: i)
        return next
    }
}

/// shared/hostClassification.ts, for IPv4, names and the IPv6 forms T3 tests by prefix.
enum HostClass {
    static func normalize(_ host: String) -> String {
        var h = host.lowercased()
        if h.hasPrefix("[") && h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
        while h.hasSuffix(".") { h.removeLast() }
        return h
    }

    static func ipv4(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ ($0 ?? -1) >= 0 && ($0 ?? 256) <= 255 }) else { return nil }
        return parts.map { $0! }
    }

    static func isLoopback(_ host: String) -> Bool {
        let h = normalize(host)
        if h == "localhost" || h == "::1" { return true }
        return ipv4(h)?.first == 127
    }

    static func isTailnet(_ host: String) -> Bool {
        let h = normalize(host)
        if h.hasSuffix(".ts.net") { return true }
        if let p = ipv4(h) { return p[0] == 100 && (64...127).contains(p[1]) }
        // ponytail: fd7a:115c:a1e0::/48 by text prefix, not a parsed address; parse IPv6 if odd forms show up
        return h.hasPrefix("fd7a:115c:a1e0:")
    }

    static func isPrivateNetwork(_ host: String) -> Bool {
        let h = normalize(host)
        if h == "::" || isLoopback(h) || h.hasSuffix(".localhost") || h.hasSuffix(".local") || h == "home.arpa"
            || h.hasSuffix(".home.arpa") || (!h.contains(".") && !h.contains(":")) || h.hasSuffix(".ts.net") {
            return true
        }
        let mapped = h.hasPrefix("::ffff:") ? ipv4(String(h.dropFirst(7))) : nil
        if let p = ipv4(h) ?? mapped {
            return p[0] == 0 || p[0] == 10 || p[0] == 127 || (p[0] == 100 && (64...127).contains(p[1]))
                || (p[0] == 172 && (16...31).contains(p[1])) || (p[0] == 192 && p[1] == 168)
                || (p[0] == 169 && p[1] == 254) || (p[0] == 198 && (18...19).contains(p[1]))
        }
        guard h.contains(":"), let first = h.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first,
              (1...4).contains(first.count), let hextet = Int(first, radix: 16) else { return false }
        return hextet & 0xfe00 == 0xfc00 || hextet & 0xffc0 == 0xfe80
    }
}
