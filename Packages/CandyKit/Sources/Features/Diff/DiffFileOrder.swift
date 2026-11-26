import Foundation

/// `orderDiffFilesForReview` (5258 packages/client-runtime/src/diffFileOrder.ts:280-292, #26760): source files with
/// dependencies before dependents, tests after the source they cover, generated files last, then regrouped in tree
/// order so each directory stays together. `lines(i)` gives file `i`'s added and removed lines, read for imports.
/// Returns the indices of `paths` in review order.
public func orderDiffFilesForReview(_ paths: [String], lines: (Int) -> [String]) -> [Int] {
    let ordered = DiffFileOrder.orderByImportsAndTier(paths, lines: lines)
    let tree = orderDiffPathsLikeTree(ordered.map { paths[$0] })
    return tree.map { ordered[$0] }
}

enum DiffFileOrder {
    enum Tier { case source, test, generated }

    static let generatedNames: Set<String> = ["pnpm-lock.yaml", "yarn.lock", "package-lock.json", "bun.lockb", "Cargo.lock",
                                              "go.sum", "composer.lock", "Gemfile.lock"]
    static let generatedDirectories: Set<String> = ["__snapshots__", "__generated__", "dist", "build", "vendor"]
    static let testDirectories: Set<String> = ["__tests__", "tests", "test"]
    /// `.mts` also ends in `.ts`, so longer extensions come first.
    static let moduleExtensions = [".mts", ".cts", ".mjs", ".cjs", ".tsx", ".jsx", ".ts", ".js"]
    static let importSpecifier = try! NSRegularExpression(
        pattern: #"(?:\bfrom|\bimport|\brequire\s*\()\s*\(?\s*["']([^"']+)["']"#)
    static let testName = try! NSRegularExpression(pattern: #"\.(?:test|spec)\."#)

    /// `diffFileTier` (:29-50).
    static func tier(_ path: String) -> Tier {
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let name = segments.last ?? ""
        let directories = segments.dropLast()
        if generatedNames.contains(name) || name.hasSuffix(".snap") || name.hasSuffix(".min.js") || name.hasSuffix(".min.css")
            || name.contains(".generated.") || directories.contains(where: generatedDirectories.contains) {
            return .generated
        }
        if matches(testName, name) || directories.contains(where: testDirectories.contains) { return .test }
        return .source
    }

    static func matches(_ regex: NSRegularExpression, _ s: String) -> Bool {
        regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    static func fileName(_ path: String) -> String { path.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? "" }

    /// `baseName`: the file name without its last extension.
    static func baseName(_ path: String) -> String {
        let name = fileName(path)
        guard let dot = name.lastIndex(of: ".") else { return name }
        return String(name[..<dot])
    }

    /// `stripModuleExtension`: only the extensions an import may leave out, so `b.logic` keeps its dot.
    static func stripModuleExtension(_ path: String) -> String {
        guard let ext = moduleExtensions.first(where: path.hasSuffix) else { return path }
        return String(path.dropLast(ext.count))
    }

    static func moduleName(_ path: String) -> String { stripModuleExtension(fileName(path)) }

    static func resolveRelative(_ from: String, _ specifier: String) -> String {
        var segments = from.split(separator: "/", omittingEmptySubsequences: false).dropLast().map(String.init)
        for part in specifier.split(separator: "/", omittingEmptySubsequences: false) {
            if part == "." || part.isEmpty { continue }
            if part == ".." { _ = segments.popLast() } else { segments.append(String(part)) }
        }
        return segments.joined(separator: "/")
    }

    /// `importedPaths` (:84-110).
    static func importedPaths(_ path: String, _ lines: [String], byModulePath: [String: String], byModuleName: [String: String]) -> Set<String> {
        var imported: Set<String> = []
        for line in lines where line.contains("from") || line.contains("import") || line.contains("require") {
            for match in importSpecifier.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                guard let range = Range(match.range(at: 1), in: line) else { continue }
                // Bundler queries such as `?worker` or `?url` name the same file.
                var specifier = String(line[range])
                if let q = specifier.firstIndex(of: "?") { specifier = String(specifier[..<q]) }
                let resolved = stripModuleExtension(specifier.hasPrefix(".") ? resolveRelative(path, specifier) : specifier)
                let target = byModulePath[resolved] ?? byModulePath[resolved + "/index"] ?? byModuleName[moduleName(resolved)]
                if let target, target != path { imported.insert(target) }
            }
        }
        return imported
    }

    /// `orderByImports` (:146-195): a topological order that always takes the alphabetically first ready file, and
    /// breaks a cycle with the first file not yet listed.
    static func orderByImports(_ paths: [String], _ imports: [String: Set<String>]) -> [String] {
        let sorted = paths.sorted { $0.localizedCompare($1) == .orderedAscending }
        let index = Dictionary(sorted.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        var inDegree = [Int](repeating: 0, count: sorted.count)
        var dependents = [[Int]](repeating: [], count: sorted.count)
        for (i, path) in sorted.enumerated() {
            for dependency in imports[path] ?? [] {
                guard let d = index[dependency] else { continue }
                inDegree[i] += 1
                dependents[d].append(i)
            }
        }
        // ponytail: linear min over the ready list, a heap (T3's #42233) if PRs with thousands of files feel slow
        var ready = sorted.indices.filter { inDegree[$0] == 0 }
        var emitted = [Bool](repeating: false, count: sorted.count)
        var nextRemaining = 0
        var ordered: [String] = []
        for _ in sorted.indices {
            let next: Int
            if let m = ready.indices.min(by: { ready[$0] < ready[$1] }) {
                next = ready.remove(at: m)
            } else {
                while emitted[nextRemaining] { nextRemaining += 1 }
                next = nextRemaining
                nextRemaining += 1
            }
            emitted[next] = true
            ordered.append(sorted[next])
            for dependent in dependents[next] where !emitted[dependent] {
                inDegree[dependent] -= 1
                if inDegree[dependent] == 0 { ready.append(dependent) }
            }
        }
        return ordered
    }

    /// `testedSourcePosition` (:199-209): `a.logic.test.ts` covers `a.logic.ts`, `a.browser.test.ts` covers `a.ts`.
    static func testedSourcePosition(_ path: String, _ positions: [String: Int]) -> Int {
        var name = fileName(path)
        if let match = name.range(of: #"\.(?:test|spec)\..*$"#, options: .regularExpression) { name.removeSubrange(match) }
        while true {
            if let p = positions[name] { return p }
            guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return Int.max }
            name = String(name[..<dot])
        }
    }

    /// `orderByImportsAndTier` (:211-268). Two files under one path (a type change) stay together.
    static func orderByImportsAndTier(_ paths: [String], lines: (Int) -> [String]) -> [Int] {
        var byPath: [String: [Int]] = [:]
        var unique: [String] = []
        for (i, path) in paths.enumerated() {
            if byPath[path] == nil { unique.append(path) }
            byPath[path, default: []].append(i)
        }
        let tiers = Dictionary(unique.map { ($0, tier($0)) }, uniquingKeysWith: { a, _ in a })
        let sources = unique.filter { tiers[$0] == .source }
        var byModulePath: [String: String] = [:], byModuleName: [String: String] = [:]
        var ambiguous: Set<String> = []
        for path in sources {
            byModulePath[stripModuleExtension(path)] = path
            let name = moduleName(path)
            if byModuleName[name] != nil { ambiguous.insert(name) }
            byModuleName[name] = path
        }
        for name in ambiguous { byModuleName[name] = nil }
        var imports: [String: Set<String>] = [:]
        for path in sources {
            imports[path] = importedPaths(path, byPath[path]!.flatMap(lines), byModulePath: byModulePath, byModuleName: byModuleName)
        }
        let orderedSource = orderByImports(sources, imports)
        var positions: [String: Int] = [:]
        for (i, path) in orderedSource.enumerated() where positions[baseName(path)] == nil { positions[baseName(path)] = i }
        let byName = { (l: String, r: String) in l.localizedCompare(r) == .orderedAscending }
        let tests = unique.filter { tiers[$0] == .test }.sorted { l, r in
            let a = testedSourcePosition(l, positions), b = testedSourcePosition(r, positions)
            return a != b ? a < b : byName(l, r)
        }
        let generated = unique.filter { tiers[$0] == .generated }.sorted(by: byName)
        return (orderedSource + tests + generated).flatMap { byPath[$0]! }
    }
}
