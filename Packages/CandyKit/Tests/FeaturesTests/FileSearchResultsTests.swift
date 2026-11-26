import AppKit
import Testing
import T3Protocol
@testable import Features

/// A file search opens to its matched lines by file (FileSearchResults.tsx at 5258, #42429).
@MainActor
struct FileSearchResultsTests {
    static func result(_ file: String, line: Int? = nil, preview: String? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["fileName": .string(file)]
        if let line { o["line"] = .number(Double(line)) }
        if let preview { o["preview"] = .string(preview) }
        return .object(o)
    }

    @Test func groupsByFileAndMarksThePattern() {
        let found = FileSearchResults(results: [
            Self.result("/repo/src/a.swift", line: 3, preview: "  let token = Token()  "),
            Self.result("/repo/b.md", line: 9, preview: "a TOKEN here"),
            Self.result("/repo/src/a.swift", line: 12, preview: "token()"),
            Self.result("/repo", preview: "(results truncated)"),
        ], pattern: "token", workspaceRoot: "/repo")
        // `formatWorkspaceRelativePath` names the workspace folder, as the work rows do.
        #expect(found.groups.map(\.path) == ["repo/src/a.swift", "repo/b.md", "repo"])
        #expect(found.groups[0].lines.map(\.number) == [3, 12] && found.groups[0].lines[0].text == "let token = Token()")
        #expect(found.groups[2].lines.isEmpty && found.groups[2].inlineNote == "(results truncated)")
        // The case-sensitive form wins when it matches; a line it misses was matched without case.
        #expect(FileSearchResults.ranges("let token = Token()", found.matchers) == [NSRange(location: 4, length: 5)])
        #expect(FileSearchResults.ranges("a TOKEN here", found.matchers) == [NSRange(location: 2, length: 5)])
        // Long lines and risky patterns go unmarked.
        #expect(FileSearchResults.ranges(String(repeating: "token ", count: 200), found.matchers).isEmpty)
        #expect(FileSearchResults.backtracksSafely("foo.*bar"))
        #expect(!FileSearchResults.backtracksSafely("(a+)+b"))
        #expect(!FileSearchResults.backtracksSafely("a*b*"))
        #expect(!FileSearchResults.backtracksSafely("a|b|c|d|e"))
        #expect(FileSearchResults.ranges(String(repeating: "x", count: 30), [try! NSRegularExpression(pattern: "x")]).count == 20)
    }

    @Test func boxHeightFollowsTheSectionsAndCapsAt384() {
        let one = FileSearchResults(results: [Self.result("a.swift", line: 1, preview: "x")], pattern: "x", workspaceRoot: nil)
        let line = WorkDetailView.lineHeight
        // Border, `py-1.5`, the path line, `mt-0.5`, one matched line.
        #expect(FileSearchResultsView.height(one, width: 400) == 2 + 6 + line + 2 + line + 6)
        let many = FileSearchResults(results: (1...80).map { (n: Int) in Self.result("f\(n).swift", line: n, preview: "x") }, pattern: "x", workspaceRoot: nil)
        #expect(FileSearchResultsView.height(many, width: 400) == FileSearchResultsView.maxHeight)
    }
}
