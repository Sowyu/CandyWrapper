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
        func wait(_ source: String, width: CGFloat) async throws -> MermaidDiagrams.Result? {
            var result = MermaidDiagrams.shared.result(source, palette: palette, width: width)
            for _ in 0..<1500 where result == nil {
                try await Task.sleep(for: .milliseconds(10))
                result = MermaidDiagrams.shared.result(source, palette: palette, width: width)
            }
            return result
        }
        guard case .rendered(let image, let size)? = try await wait("graph TD\n  Candy --> Wrapper", width: 600) else {
            Issue.record("no render")
            return
        }
        #expect(image.width > 0 && size.width > 0 && size.width <= 600 && size.height > 0)
        // A parse error reports pele's message without Retry; only a renderer that failed to load offers it.
        guard case .failed(let message, let retryable)? = try await wait("graph TD\n  A -->", width: 600) else {
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
