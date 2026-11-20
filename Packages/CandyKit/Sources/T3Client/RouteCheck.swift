import Foundation

/// Route choice for an environment with several routes, as T3 makes it on every attempt and while connected on a
/// fallback (client-runtime connection/driver.ts:83-130, supervisor.ts:74-81, 176-185, 414-475).
public enum RouteCheck {
    public struct Outcome: Sendable, Equatable {
        /// The first route in preference order whose check passed.
        public var first: URL?
        /// Routes whose check failed before the answer was known. Later routes were cancelled, so they aren't here.
        public var silent: [URL]
    }

    /// Checks every route at once and returns the first, in preference order, whose check passes: a dead LAN address
    /// ahead of a working tunnel costs one check timeout, not one per route.
    public static func check(_ routes: [URL], check: @escaping @Sendable (URL) async -> Bool) async -> Outcome {
        guard !routes.isEmpty else { return Outcome(first: nil, silent: []) }
        return await withTaskGroup(of: (Int, Bool).self) { group in
            for (index, route) in routes.enumerated() { group.addTask { (index, await check(route)) } }
            var results = [Bool?](repeating: nil, count: routes.count)
            func silent() -> [URL] { results.enumerated().compactMap { $0.element == false ? routes[$0.offset] : nil } }
            for await (index, answered) in group {
                results[index] = answered
                // The earliest route whose earlier routes all failed.
                for (i, result) in results.enumerated() {
                    guard let result else { break }
                    if result { group.cancelAll(); return Outcome(first: routes[i], silent: silent()) }
                }
            }
            return Outcome(first: nil, silent: silent())
        }
    }

    /// The routes ahead of `current` worth checking now, best first. Empty when `current` is the preferred route.
    public static func better(than current: URL, in routes: [URL], skipping: (URL) -> Bool) -> [URL] {
        guard let index = routes.firstIndex(where: { EnvironmentRoute.origin($0) == EnvironmentRoute.origin(current) }) else { return [] }
        return routes[..<index].filter { !skipping($0) }
    }
}

/// Routes that stayed silent or failed right after a switch, skipped for a while so a dead LAN address isn't checked
/// on every signal and a flaky one can't bounce the connection (supervisor.ts:74-81, 176-185, 1050-1060).
public struct RouteBackoff: Sendable {
    /// T3 checks a silent route half as often each time, from 2 minutes up to 30.
    public static let silentBase: TimeInterval = 60
    public static let silentMax: TimeInterval = 1_800
    /// A better route that answered its check but failed to connect.
    public static let switchCooldown: TimeInterval = 300

    private var silent: [String: (failures: Int, until: Date)] = [:]
    private var cooldown: [String: Date] = [:]

    public init() {}

    public func skips(_ route: URL, now: Date = Date()) -> Bool {
        let key = EnvironmentRoute.origin(route)
        return (silent[key]?.until ?? .distantPast) > now || (cooldown[key] ?? .distantPast) > now
    }

    public mutating func silent(_ route: URL, now: Date = Date()) {
        let key = EnvironmentRoute.origin(route)
        let failures = (silent[key]?.failures ?? 0) + 1
        silent[key] = (failures, now + min(Self.silentMax, Self.silentBase * pow(2, Double(failures))))
    }

    public mutating func answered(_ route: URL) { silent[EnvironmentRoute.origin(route)] = nil }

    public mutating func switchFailed(_ route: URL, now: Date = Date()) {
        cooldown[EnvironmentRoute.origin(route)] = now + Self.switchCooldown
    }

    /// Another network: a silent route may answer now (supervisor.ts:1340, `forgetSilentRoutes`).
    public mutating func networkChanged() { silent = [:] }
}
