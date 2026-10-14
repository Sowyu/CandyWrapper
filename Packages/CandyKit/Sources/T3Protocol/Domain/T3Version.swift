import Foundation

/// A T3 release version (`0.0.45`, `0.0.46-nightly.20261009.2861`) in semver order: the core, then a
/// release after its prereleases, then prerelease identifiers left to right, numbers by value. Nightly
/// builds of one core order by date and run. Strings that don't parse are not versions.
public struct T3Version: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let raw: String
    let core: [Int]
    let pre: [String]

    public init?(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
        let noBuild = value.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let parts = noBuild.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = parts.first else { return nil }
        let numbers = first.split(separator: ".", omittingEmptySubsequences: false)
        guard numbers.count == 3, numbers.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) else { return nil }
        core = numbers.compactMap { Int($0) }
        guard core.count == 3 else { return nil }
        pre = parts.count > 1 ? parts[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init) : []
        guard !pre.contains(where: \.isEmpty), !value.contains("/") else { return nil }
        raw = value
    }

    public var description: String { raw }

    public static func < (a: T3Version, b: T3Version) -> Bool {
        if a.core != b.core { return a.core.lexicographicallyPrecedes(b.core) }
        // A release outranks its prereleases.
        if a.pre.isEmpty || b.pre.isEmpty { return !a.pre.isEmpty && b.pre.isEmpty }
        for (x, y) in zip(a.pre, b.pre) where x != y {
            switch (Int(x), Int(y)) {
            case let (nx?, ny?): return nx < ny
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return x < y
            }
        }
        return a.pre.count < b.pre.count
    }

    public static func == (a: T3Version, b: T3Version) -> Bool { a.core == b.core && a.pre == b.pre }
    public func hash(into hasher: inout Hasher) { hasher.combine(core); hasher.combine(pre) }
}
