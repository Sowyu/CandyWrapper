import AppKit
import Testing
@testable import Features

/// Markdown images, favicons and find in thread's text (partials items 6, 7, 14, 16).
@MainActor
struct MarkdownMediaTests {
    @Test func classifiesImageSources() {
        #expect(MarkdownImageSource.classify("https://x.dev/a.png", workspaceRoot: "/w") == .direct("https://x.dev/a.png"))
        #expect(MarkdownImageSource.classify("data:image/png;base64,AA==", workspaceRoot: nil) == .direct("data:image/png;base64,AA=="))
        #expect(MarkdownImageSource.classify("./shots/a%20b.png", workspaceRoot: "/w/") == .workspaceFile("/w/./shots/a b.png"))
        #expect(MarkdownImageSource.classify("/tmp/a.png?x=1#y", workspaceRoot: nil) == .workspaceFile("/tmp/a.png"))
        #expect(MarkdownImageSource.classify("file:///tmp/a.png", workspaceRoot: nil) == .workspaceFile("/tmp/a.png"))
        #expect(MarkdownImageSource.classify("a.png", workspaceRoot: nil) == .blocked)
        #expect(MarkdownImageSource.classify("~/a.png", workspaceRoot: "/w") == .blocked)
        #expect(MarkdownImageSource.classify("mailto:a@b.c", workspaceRoot: "/w") == .blocked)
        #expect(MarkdownImageSource.classify("#top", workspaceRoot: "/w") == .blocked)
    }

    /// T3 826ef55b74 (ChatMarkdown.tsx:541-565): a remote host's missing file names the host and the checked path.
    @Test func mediaUnavailableNamesTheRemoteHost() {
        let notFound = "AssetWorkspaceAssetNotFoundError"
        #expect(MarkdownImages.mediaUnavailableDescription(errorTag: notFound, message: nil, checkedPath: "/home/u/a.png", path: "~/a.png",
                                                           remoteHost: "Studio") == "The file was not found on Studio at /home/u/a.png.")
        #expect(MarkdownImages.mediaUnavailableDescription(errorTag: notFound, message: nil, checkedPath: nil, path: "~/a.png",
                                                           remoteHost: "Studio") == "The file was not found on Studio at ~/a.png.")
        #expect(MarkdownImages.mediaUnavailableDescription(errorTag: notFound, message: nil, checkedPath: "/a.png", path: "/a.png",
                                                           remoteHost: nil) == "Media file was not found.")
        #expect(MarkdownImages.mediaUnavailableDescription(errorTag: "X", message: "Boom.", checkedPath: nil, path: "/a.png", remoteHost: "Studio") == "Boom.")
    }

    @Test func imagesTakeTheirOwnSizeWithinThirtyRem() {
        #expect(MarkdownImages.displaySize(natural: CGSize(width: 100, height: 50), maxWidth: 680, border: 0) == CGSize(width: 100, height: 50))
        #expect(MarkdownImages.displaySize(natural: CGSize(width: 1920, height: 1080), maxWidth: 680, border: 0) == CGSize(width: 480, height: 270))
        #expect(MarkdownImages.displaySize(natural: CGSize(width: 400, height: 2000), maxWidth: 680, border: 0) == CGSize(width: 96, height: 480))
        #expect(MarkdownImages.displaySize(natural: CGSize(width: 1000, height: 500), maxWidth: 300, border: 1) == CGSize(width: 300, height: 151))
    }

    @Test func decodedImageReplacesTheSlot() {
        let key = "https://example.com/measured-\(UUID().uuidString).png"
        let doc = MarkdownDocument(parsing: "![shot](\(key))")
        func remote(_ layout: MarkdownLayout) -> CGRect? {
            layout.items.compactMap { if case .remoteImage(_, _, let r) = $0 { r } else { nil } }.first
        }
        #expect(remote(MarkdownLayout(document: doc, width: 680))?.size == CGSize(width: 480, height: 270))
        MarkdownImages.record(CGSize(width: 120, height: 60), for: key)
        #expect(remote(MarkdownLayout(document: doc, width: 680))?.size == CGSize(width: 120, height: 60))
    }

    @Test func mediaReferences() {
        #expect(MediaReference.file("/w/src/a.png", workspaceRoot: "/w") == .file(path: "/w/src/a.png", relativePath: "src/a.png"))
        #expect(MediaReference.file("/tmp/a.png", workspaceRoot: "/w") == .file(path: "/tmp/a.png", relativePath: nil))
        #expect(MediaReference.link("https://a.dev/x.png") == .url("https://a.dev/x.png"))
        #expect(MediaReference.link("data:image/png;base64,AA==") == nil)
    }

    @Test func externalLinksReserveAFavicon() {
        func favicons(_ markdown: String) -> [String] {
            MarkdownLayout(document: MarkdownDocument(parsing: markdown), width: 680).items.compactMap {
                if case .favicon(let host, let rect) = $0 { #expect(rect.size == CGSize(width: 14, height: 14)); return host } else { return nil }
            }
        }
        #expect(favicons("See [Apple](https://apple.com/mac) and [**GitHub**](https://github.com/x).") == ["apple.com", "github.com"])
        #expect(favicons("A [section](#setup) link.").isEmpty)
        // The reserve is 0.25em + 14px + 0.2em wide.
        let plain = MarkdownLayout(document: MarkdownDocument(parsing: "[Apple](#a)"), width: 680)
        let web = MarkdownLayout(document: MarkdownDocument(parsing: "[Apple](https://apple.com)"), width: 680)
        func width(_ layout: MarkdownLayout) -> CGFloat {
            layout.items.compactMap { if case .text(let box, _) = $0 { box.usedWidth } else { nil } }.first ?? 0
        }
        #expect(abs(width(web) - width(plain) - (0.45 * 14 + 14)) < 0.01)
    }

    @Test func findMatchesLikeT3() {
        #expect(ThreadFindText.occurrences("aaaa", "aa") == [NSRange(location: 0, length: 2), NSRange(location: 2, length: 2)])
        #expect(ThreadFindText.count("ΟΔΟΣ οδος", "οδοσ") == 2)
        #expect(ThreadFindText.count("Hello", "") == 0)
    }

    @Test func findCountsWhatT3Indexes() {
        func count(_ markdown: String, _ query: String, cwd: String? = nil) -> Int {
            let view = MarkdownView(frame: NSRect(x: 0, y: 0, width: 680, height: 400))
            view.cwd = cwd
            view.setMarkdown(markdown)
            view.threadFindQuery = query
            return view.findMatchCount()
        }
        // The code block's title is not page text; its code is.
        #expect(count("```swift\nlet swift = 1\n```", "swift") == 1)
        // A file chip matches its label.
        #expect(count("Open `src/App.swift` now.", "App.swift", cwd: "/w") == 1)
        // An alert's title is ignored, a favicon adds nothing between words.
        #expect(count("> [!NOTE]\n> A note.", "note") == 1)
        #expect(count("see [Apple docs](https://apple.com)", "see Apple") == 1)
    }
}
