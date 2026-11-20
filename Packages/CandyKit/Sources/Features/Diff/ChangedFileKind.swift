import Foundation

/// `classifyChangedFile` (4928 packages/shared/src/changedFileKind.ts:24-104): sorts a changed file by its path alone.
/// Lockfiles and build output are generated, test support is kept apart from the tests, and prose is its own kind.
public enum ChangedFileKind: String, Sendable {
    case code, tests, mocks, generated, docs

    public init(path: String) {
        var segments = path.replacingOccurrences(of: "\\", with: "/").split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let name = segments.popLast() ?? ""
        let dirs = Set(segments.map { $0.lowercased() })
        func matches(_ re: NSRegularExpression) -> Bool { re.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil }
        if Self.generatedFiles.contains(name.lowercased()) || matches(Self.generatedName) || !dirs.isDisjoint(with: Self.generatedDirs) {
            self = .generated
        } else if matches(Self.mockName) || !dirs.isDisjoint(with: Self.mockDirs) {
            self = .mocks
        } else if matches(Self.testName) || matches(Self.classTestName) || !dirs.isDisjoint(with: Self.testDirs) {
            self = .tests
        } else if matches(Self.docsName) && !matches(Self.notDocsName) {
            self = .docs
        } else {
            self = .code
        }
    }

    /// `isTestChangedFile`: tests and their support files, what "Hide test files" hides (#26730, #29083).
    public static func isTest(_ path: String) -> Bool {
        let kind = ChangedFileKind(path: path)
        return kind == .tests || kind == .mocks
    }

    private static func re(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static let generatedFiles: Set<String> = [
        "bun.lock", "bun.lockb", "cargo.lock", "composer.lock", "deno.lock", "flake.lock", "gemfile.lock", "go.sum",
        "gradle.lockfile", "mix.lock", "npm-shrinkwrap.json", "package-lock.json", "packages.lock.json", "pipfile.lock",
        "pnpm-lock.yaml", "podfile.lock", "poetry.lock", "pubspec.lock", "uv.lock", "yarn.lock",
    ]
    private static let generatedName = re(#"(\.generated\.|\.gen\.|\.g\.dart$|\.pb\.go$|_pb2(_grpc)?\.py$|\.pb\.(cc|h)$|\.min\.(js|css)$|\.(js|css)\.map$)"#)
    private static let generatedDirs: Set<String> = ["__generated__", "_generated", "generated"]
    private static let mockName = re(#"(\.snap$|\.(mocks?|fixtures?|stubs?|fakes?)\.[^.]+$|^(mocks?|fixtures?|stubs?|fakes?)([-_.A-Z]|$))"#)
    private static let mockDirs: Set<String> = [
        "__fixtures__", "__mocks__", "__snapshots__", "fakes", "fixture", "fixtures", "mock", "mocks", "stubs", "testdata",
    ]
    private static let testName = re(#"(\.(test|spec|e2e|eval|stories)\.[^.]+$|_(test|spec)\.[^.]+$|^test_.+\.py$|^conftest\.py$|^(vitest|jest)\.setup\.[^.]+$)"#, .caseInsensitive)
    /// Case-sensitive: `FooTest.java` is a test class, `Latest.java` is not.
    private static let classTestName = re(#"(Tests?|Spec)\.(java|kt|kts|scala|groovy|cs|php|swift|m)$"#)
    private static let testDirs: Set<String> = ["__tests__", "__test__", "cypress", "e2e", "evals", "spec", "specs", "test", "tests"]
    private static let docsName = re(#"\.(md|mdx|markdown|rst|adoc|txt)$"#, .caseInsensitive)
    private static let notDocsName = re(#"^(requirements.*|constraints.*|CMakeLists|robots|llms)\.txt$"#, .caseInsensitive)
}

/// `orderDiffFilesLikeTree` (4928 diffFileTree.logic.ts:88-129): a flat list in tree order. Each directory stays
/// together, ranked where its first file came, so the list never disagrees with the tree.
public func orderDiffPathsLikeTree(_ paths: [String]) -> [Int] {
    var positions: [String: Int] = [:]
    for (i, path) in paths.enumerated() {
        positions[path] = i
        var directory = ""
        for segment in path.split(separator: "/", omittingEmptySubsequences: false).dropLast() {
            directory += segment + "/"
            if positions[directory] == nil { positions[directory] = i }
        }
    }
    let keys: [[Int]] = paths.map { path in
        var key: [Int] = []
        var directory = ""
        for segment in path.split(separator: "/", omittingEmptySubsequences: false).dropLast() {
            directory += segment + "/"
            key.append(positions[directory] ?? 0)
        }
        key.append(positions[path] ?? 0)
        return key
    }
    return paths.indices.sorted { l, r in
        let a = keys[l], b = keys[r]
        for i in 0..<min(a.count, b.count) where a[i] != b[i] { return a[i] < b[i] }
        return a.count != b.count ? a.count < b.count : l < r
    }
}

/// `useHideTestFiles` (4928 diffs/useHideTestFiles.ts): one choice for the Diff panel and every pull request's Code
/// tab, kept on this Mac under T3's local storage key.
@MainActor public enum DiffHideTestFiles {
    static let key = "t3code.diffHideTestFiles"
    public static var value: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
