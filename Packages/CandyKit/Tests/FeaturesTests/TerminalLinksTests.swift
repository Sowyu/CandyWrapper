import Testing
@testable import Features

/// `extractTerminalLinks`, with cases from T3's apps/web/src/terminal-links.test.ts (Nightly 3473).
struct TerminalLinksTests {
    typealias M = TerminalLinks.Match
    static func path(_ text: String, _ start: Int, _ end: Int? = nil) -> M { M(kind: .path, text: text, start: start, end: end ?? start + text.utf16.count) }

    @Test func pathsAndURLs() {
        #expect(TerminalLinks.extract(#"error at C:\Users\Jane\project\index.ts:12: failed"#) == [Self.path(#"C:\Users\Jane\project\index.ts:12"#, 9)])
        let quoted = #"C:\Users\Jane Doe\project\index.ts:12:7"#
        #expect(TerminalLinks.extract("see `\(quoted)`.") == [Self.path(quoted, 5)])
        #expect(TerminalLinks.extract(#""./my folder/index.ts":12:7: error"#) == [Self.path("./my folder/index.ts:12:7", 1, 27)])
        #expect(TerminalLinks.extract(#"error: "something went wrong""#).isEmpty)
        #expect(TerminalLinks.extract("(https://example.com/docs), ./src/main.ts:12.") == [
            M(kind: .url, text: "https://example.com/docs", start: 1, end: 25), Self.path("./src/main.ts:12", 28, 44),
        ])
        #expect(TerminalLinks.extract("GET https://example.test/items/foo:") == [M(kind: .url, text: "https://example.test/items/foo:", start: 4, end: 35)])
        #expect(TerminalLinks.extract("/home/dev/app/src/main.c:10:5: error: expected ';'") == [Self.path("/home/dev/app/src/main.c:10:5", 0)])
        #expect(TerminalLinks.extract("wrote /tmp/report?draft") == [Self.path("/tmp/report?draft", 6)])
        #expect(TerminalLinks.isURL("HTTPS://example.com/docs") && !TerminalLinks.isURL("httpsdocs/readme.md"))
    }

    /// 9ac1355e01: Unicode letters and marks stay in the path.
    @Test func unicodePaths() {
        for text in ["src/żółć.ts:12:7", "żółć/main.ts:12", "src/cafe\u{0301}.ts:12", "src/𐐀.ts:12"] {
            #expect(TerminalLinks.extract("see \(text) for details") == [Self.path(text, 4)])
        }
    }

    /// 10b86829e8: a logged request route with a query is no path; links around it stay.
    @Test func requestRoutes() {
        for line in [" GET /api/trpc/post.list,user.me?batch=1 200 in 35ms", "GET /api?+debug 200",
                     #"Started GET "/posts?page=2" for ::1"#, "proxying api/trpc/post.list?batch=1 to the backend"] {
            #expect(TerminalLinks.extract(line).isEmpty, "\(line)")
        }
        let line = "src/server.ts:12 GET /api/users?id=42 200 /app/bin/server:3:7 https://example.com/api/users?id=42"
        #expect(TerminalLinks.extract(line).map(\.text) == ["src/server.ts:12", "/app/bin/server:3:7", "https://example.com/api/users?id=42"])
    }
}
