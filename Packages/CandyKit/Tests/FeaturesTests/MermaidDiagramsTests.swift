import Foundation
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
