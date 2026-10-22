import AppKit
import Testing
@testable import Features

/// Diagrams render with pele (fcb20e49aa): its script loads off the main thread, a diagram still renders in the
/// app's colors, and a closed fence draws while the reply streams (48b486bd73).
@MainActor
struct MermaidDiagramsTests {
    @Test func scriptUnpacks() {
        let script = MermaidDiagrams.loadScript()
        #expect((script?.count ?? 0) > 500_000)
        #expect(script?.hasPrefix("/*! Pele 1.8.0") == true)
        #expect(script?.hasSuffix("\n;0") == true)
    }

    @Test func diagramRendersAndFailsLikeT3() async throws {
        let palette = MermaidDiagrams.Palette.current(dark: false)
        func wait(_ source: String, width: CGFloat) async -> MermaidDiagrams.Result? {
            // A real WKWebView loads a 1 MB script first, which takes a while on a busy machine.
            var result: MermaidDiagrams.Result?
            _ = await eventually(seconds: 60) {
                result = MermaidDiagrams.shared.result(source, palette: palette, width: width)
                return result != nil
            }
            return result
        }
        guard case .rendered(let image, let size)? = await wait("graph TD\n  Candy --> Wrapper", width: 600) else {
            Issue.record("no render")
            return
        }
        #expect(image.width > 0 && size.width > 0 && size.width <= 600 && size.height > 0)
        // A parse error reports pele's message without Retry; only a renderer that failed to load offers it.
        guard case .failed(let message, let retryable)? = await wait("graph TD\n  A -->", width: 600) else {
            Issue.record("expected a failure")
            return
        }
        #expect(!message.isEmpty && !retryable)
    }

    @Test func openFence() {
        #expect(!MarkdownLayout.endsInOpenFence("text\n```mermaid\ngraph TD\n```\nmore"))
        #expect(MarkdownLayout.endsInOpenFence("text\n```mermaid\ngraph TD\n  A --> B"))
        // A shorter or different closer, or one with text after it, does not close the fence.
        #expect(MarkdownLayout.endsInOpenFence("````mermaid\ngraph TD\n```"))
        #expect(MarkdownLayout.endsInOpenFence("~~~mermaid\ngraph TD\n```"))
        #expect(MarkdownLayout.endsInOpenFence("```mermaid\ngraph TD\n``` x"))
        #expect(!MarkdownLayout.endsInOpenFence("- item\n  ```mermaid\n  graph TD\n  ```"))
        // Only the fence being written stays code; an earlier closed one draws.
        let doc = MarkdownDocument(parsing: "```mermaid\ngraph TD\n  A --> B\n```\n\n- x\n  ```mermaid\n  graph TD\n")
        #expect(MarkdownLayout.codeBlockCount(doc.blocks) == 2)
        let diagrams = MarkdownLayout.Diagrams(enabled: true, palette: .current(dark: false), openIndex: 1)
        let layout = MarkdownLayout(document: doc, width: 600, diagrams: diagrams)
        let toggles = layout.controls.filter { if case .toggleDiagram = $0.action { true } else { false } }
        #expect(toggles.count == 1) // the open fence has no view toggle
    }
}

extension MermaidDiagramsTests {
    /// The natural sizes and stand-ins go with a diagram's last cached render, so the cache stays at 64 diagrams.
    @Test func metadataLeavesWithTheLastRender() throws {
        let diagrams = MermaidDiagrams()
        let palette = MermaidDiagrams.Palette(css: "--pele-bg:red", font: "x")
        let image = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                           space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        for i in 0..<100 {
            let source = "graph TD\n  A\(i) --> B"
            let base = MermaidDiagrams.base(source, palette)
            diagrams.store((base, base + "\n300", source, palette, 300), .rendered(image, CGSize(width: 1, height: 1)), natural: (200, false))
        }
        #expect(diagrams.metadataCount.naturals == 64 && diagrams.metadataCount.latest == 64)
        #expect(MermaidDiagrams.base(ofKey: "a\nb\nn") == "a\nb")
    }
}

extension MermaidDiagramsTests {
    /// A diagram whose first column fit has not been tested for a narrower layout, so a narrower column renders
    /// at its own width; once a narrower render finds it never adapts, every width shares the natural render.
    @Test func narrowingAfterAFitRendersAgain() throws {
        let diagrams = MermaidDiagrams()
        let palette = MermaidDiagrams.Palette(css: "--pele-bg:red", font: "x")
        let image = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                           space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        let source = "graph LR\n  A --> B"
        let base = MermaidDiagrams.base(source, palette)
        let rendered = MermaidDiagrams.Result.rendered(image, CGSize(width: 1, height: 1))
        diagrams.store((base, base + "\n800", source, palette, 800), rendered, natural: (500, nil))
        #expect(diagrams.key(base: base, width: 900) == base + "\nn")
        #expect(diagrams.key(base: base, width: 300) == base + "\n300")
        diagrams.store((base, base + "\n300", source, palette, 300), rendered, natural: (500, false))
        #expect(diagrams.key(base: base, width: 300) == base + "\nn")
        // A later render that fit keeps what the narrower one found.
        diagrams.store((base, base + "\nn", source, palette, 900), rendered, natural: (500, nil))
        #expect(diagrams.key(base: base, width: 200) == base + "\nn")
    }

    /// End to end with pele: a wide diagram first shown in a wide column lays out again for a narrow one.
    @Test func wideDiagramReflowsWhenTheColumnNarrows() async throws {
        let palette = MermaidDiagrams.Palette.current(dark: false)
        let diagrams = MermaidDiagrams()
        func wait(_ source: String, width: CGFloat, until done: (CGSize) -> Bool) async throws -> CGSize? {
            for _ in 0..<1500 {
                switch diagrams.result(source, palette: palette, width: width) {
                case .rendered(_, let size)? where done(size): return size
                case .failed?: return nil
                default: try await Task.sleep(for: .milliseconds(10))
                }
            }
            return nil
        }
        let source = "graph LR\n  Alpha --> Bravo --> Charlie --> Delta --> Echo --> Foxtrot --> Golf --> Hotel"
        guard let wide = try await wait(source, width: 4000, until: { _ in true }) else { Issue.record("no wide render"); return }
        // The natural render stands in until the narrow one lands; before the fix it stood for good.
        let reflowed = try await wait(source, width: (wide.width / 2).rounded(.down), until: { $0.width < wide.width })
        #expect(reflowed != nil, "the diagram kept its \(wide) natural layout")
    }
}
