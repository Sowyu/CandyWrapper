import Foundation
import Testing
@testable import Features

/// Mermaid's script loads off the main thread and runs once the page has loaded; a diagram still renders.
@MainActor
struct MermaidDiagramsTests {
    @Test func scriptUnpacks() {
        let script = MermaidDiagrams.loadScript()
        #expect((script?.count ?? 0) > 1_000_000)
        #expect(script?.hasSuffix("\n;0") == true)
    }

    @Test func firstDiagramRenders() async throws {
        let source = "graph TD\n  Candy --> Wrapper"
        _ = MermaidDiagrams.shared.result(source, dark: false)
        var result: MermaidDiagrams.Result?
        for _ in 0..<1500 where result == nil {
            try await Task.sleep(for: .milliseconds(10))
            result = MermaidDiagrams.shared.result(source, dark: false)
        }
        guard case .rendered(let image, let size) = result else {
            Issue.record("no render: \(String(describing: result))")
            return
        }
        #expect(image.width > 0 && size.width > 0 && size.height > 0)
    }
}
