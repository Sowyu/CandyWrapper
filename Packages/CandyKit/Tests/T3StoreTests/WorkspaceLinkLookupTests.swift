import Testing
@testable import T3Store

/// `workspaceBasenameLookup.test.ts` at 4928 (#33943, #35036).
struct WorkspaceLinkLookupTests {
    typealias L = WorkspaceLinkLookup
    private func files(_ paths: String...) -> [L.Entry] { paths.map { L.Entry(path: $0, isFile: true) } }

    @Test func queries() {
        #expect(L.query("http.ts", cwd: "/repo/app") == "http.ts")
        #expect(L.query("app/src/http.ts", cwd: "/repo/app") == "src/http.ts")
        #expect(L.query("cloud/http.ts", cwd: "/repo/app") == "cloud/http.ts")
        #expect(L.query("/abs/http.ts", cwd: "/repo/app") == nil)
        #expect(L.query("./http.ts", cwd: "/repo/app") == nil)
        #expect(L.query("src/", cwd: "/repo/app") == nil)
    }

    @Test func matches() {
        #expect(L.match("http.ts", cwd: "/r", entries: files("a/http.ts", "b/http.ts")) == "a/http.ts")
        #expect(L.match("HTTP.ts", cwd: "/r", entries: files("a/http.ts")) == "a/http.ts")
        #expect(L.match("HTTP.ts", cwd: "/r", entries: files("a/http.ts", "b/Http.ts")) == nil)
        #expect(L.match("app/src/x.ts", cwd: "/repo/app", entries: files("src/x.ts")) == "src/x.ts")
        // Agents cite paths relative to a package: the one entry ending with the path wins.
        #expect(L.match("cloud/http.ts", cwd: "/repo", entries: files("packages/cloud/http.ts")) == "packages/cloud/http.ts")
        #expect(L.match("cloud/http.ts", cwd: "/repo", entries: files("a/cloud/http.ts", "b/cloud/http.ts")) == nil)
        #expect(L.match("cloud/http.ts", cwd: "/repo", entries: [.init(path: "x/cloud/http.ts", isFile: false)]) == nil)
    }

    @Test func otherProjects() {
        let one = L.projectMatch("src/a.ts", searches: [("/p1", files("src/a.ts")), ("/p2", [])])
        #expect(one == "/p1/src/a.ts")
        #expect(L.projectMatch("src/a.ts", searches: [("/p1", files("src/a.ts")), ("/p2", files("src/a.ts"))]) == nil)
    }
}
