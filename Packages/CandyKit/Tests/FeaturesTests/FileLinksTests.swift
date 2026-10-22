import AppKit
import Testing
@testable import Features

/// T3's file chip rules, cases from packages/shared/src/markdownLinks.test.ts and fileLinks.test.ts.
struct FileLinksTests {
    @Test(arguments: [
        ("src\\main.ts", "src/main.ts"), ("conf.d/nginx.conf", "conf.d/nginx.conf"), ("script.pl:10", "script.pl:10"),
        ("node.meta", nil), ("Recorded evidence here: /tmp/image.png", nil), ("origin/main", nil), ("127.0.0.1:3000", nil),
        ("example.com/index.html", nil), ("example.pl/index.html", nil), ("z-ai/glm-5.3", nil), ("z-ai/glm-5.3:12", nil),
        ("python/3.12", nil), ("Qwen/Qwen2.5-Coder", nil), ("meta-llama/Llama-3.1-8B", nil), ("share/man/ls.1", "share/man/ls.1"),
        ("usr/lib/libfoo.so.1", "usr/lib/libfoo.so.1"), ("vendor/jquery-3.6.0.min.js", "vendor/jquery-3.6.0.min.js"),
        ("./models/glm-5.3", "./models/glm-5.3"), ("/tmp/cw-approval-demo", "/tmp/cw-approval-demo"),
    ] as [(String, String?)])
    func inlineCodeCandidates(_ source: String, _ expected: String?) {
        #expect(FileLinks.inlineCodeCandidate(source) == expected)
    }

    @Test(arguments: [
        ("/Users/julius/project/AGENTS.md", "/Users/julius/project/AGENTS.md"), ("/usr/local/bin/tool", "/usr/local/bin/tool"),
        ("/tmp/favicons/", "/tmp/favicons/"), ("file:///Users/julius/project/file%2520name.md", "/Users/julius/project/file%20name.md"),
        ("file://localhost/home/me/notes.md", "/home/me/notes.md"), ("apps/mobile/src/index.ts:10", "apps/mobile/src/index.ts"),
        ("docs/My%20Folder/checklist.xml", "docs/My Folder/checklist.xml"), ("./scripts/deploy", "./scripts/deploy"),
        ("~/notes/today.md", "~/notes/today.md"), ("AGENTS.md", "AGENTS.md"), ("script.ts:10", "script.ts"),
        ("/tmp/clip%23one.mp4#t=2", "/tmp/clip#one.mp4"),
    ])
    func linkDestinations(_ href: String, _ path: String) {
        #expect(FileLinks.parseLink(href)?.path == path)
    }

    @Test(arguments: ["", "#anchor", "//cdn.example.com/clip.mp4", "https://example.com/docs", "mailto:someone@example.com",
                      "/chat/settings", "/chat/settings#L3", "/app#L1", "readme", "TODO:12"])
    func notLinks(_ href: String) {
        #expect(FileLinks.parseLink(href) == nil)
    }

    @Test func resolution() throws {
        let folder = try #require(FileLinks.resolveInlineCode("/tmp/cw-approval-demo", cwd: nil))
        #expect(folder.isDirectory && folder.basename == "cw-approval-demo" && folder.workspaceRelativePath == nil)
        #expect(folder.panelPath == "/tmp/cw-approval-demo")
        // Relative paths need a cwd and resolve from the workspace root.
        #expect(FileLinks.resolveInlineCode("src/a.ts:12:3", cwd: nil) == nil)
        let file = try #require(FileLinks.resolveInlineCode("src/a.ts:12:3", cwd: "/repo"))
        #expect(file.targetPath == "/repo/src/a.ts:12:3" && file.workspaceRelativePath == "src/a.ts" && !file.isDirectory)
        #expect(FileLinks.label(file, suffixes: [:]) == "a.ts · L12:C3")
        let home = try #require(FileLinks.resolveInlineCode("~/notes/today.md", cwd: "/Users/me/repo"))
        #expect(home.filePath == "/Users/me/notes/today.md")
        // Media outside the workspace has no panel path (T3 opens the media viewer).
        #expect(FileLinks.resolveInlineCode("/tmp/shot.png", cwd: "/repo")?.panelPath == nil)
        #expect(FileLinks.parentSuffixes(["/r/a/x/index.ts", "/r/b/x/index.ts", "/r/c.ts"]) == ["/r/a/x/index.ts": "a/x", "/r/b/x/index.ts": "b/x"])
        #expect(FileLinks.isFileLinkLabel("index.ts", href: "src/index.ts") && !FileLinks.isFileLinkLabel("the entry", href: "src/index.ts"))
    }

    /// A chip is one inline box: it never splits across lines, and plain inline code stays code.
    @MainActor @Test func chipLayout() {
        let doc = MarkdownDocument(parsing: "Created `/tmp/cw-approval-demo` and ran `npm test` in `src/some-long-name.ts` today.")
        for width: CGFloat in [120, 200, 640] {
            let layout = MarkdownLayout(document: doc, width: width, cwd: "/repo")
            #expect(layout.fileChips.map(\.label) == ["cw-approval-demo", "some-long-name.ts"])
            for chip in layout.fileChips {
                #expect(chip.frame.height > 16 && chip.frame.height < 18)
                #expect(chip.frame.width < width + 0.5)
            }
        }
        #expect(MarkdownLayout(document: doc, width: 640).fileChips.count == 1)
    }

    /// `resolvePathLinkTarget` (fileLinks.ts:91-108): `~\` is a home path only under a Windows cwd.
    @Test func homeRelativeLinksFollowTheCwdStyle() {
        #expect(FileLinks.resolveAgainst("~\\notes.txt", cwd: "C:\\Users\\alice\\repo") == "C:\\Users\\alice\\notes.txt")
        #expect(FileLinks.resolveAgainst("~/notes.txt", cwd: "/Users/alice/repo") == "/Users/alice/notes.txt")
        #expect(FileLinks.resolveAgainst("~\\notes.txt", cwd: "/Users/alice/repo") == "/Users/alice/repo/~\\notes.txt")
    }
}
