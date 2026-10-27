import AppKit
import Testing
@testable import Features

/// Regressions for audit IMG-1 and IMG-3 (docs/research/responsiveness-audit-2026-10-26/images.md).
/// No window, network, server, account or fixture file is needed.
@MainActor
@Suite(.serialized)
struct ImageLoadingAuditTests {
    @MainActor
    final class FetchGate {
        var pending: CheckedContinuation<Data?, Never>?
        var returned = false

        func value() async -> Data? {
            let result = await withCheckedContinuation { pending = $0 }
            returned = true
            return result
        }

        func finish(_ data: Data?) {
            let continuation = pending
            pending = nil
            continuation?.resume(returning: data)
        }
    }

    @Test func cancelledImageCannotReplaceTheNextFileWithItsError() async throws {
        let surface = FileSurfaceView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let gate = FetchGate()
        defer { gate.finish(nil) }
        surface.fetchData = { _ in await gate.value() }
        surface.show(path: "old.png", revealLine: nil)
        surface.setContent(.asset(URL(string: "https://fixture.invalid/old.png")!))
        try #require(await eventually(seconds: 2) { gate.pending != nil })

        surface.show(path: "new.txt", revealLine: nil)
        surface.setContent(.text("new file", truncated: false, byteLength: 8, editable: true))
        let editor = try #require(surface.subviews.compactMap { $0 as? CodeFileView }.first)
        gate.finish(nil) // Mirrors URLSession throwing cancellation, which the app maps to nil.
        try #require(await eventually(seconds: 2) { gate.returned })
        // The fetch and its continuation run on the main actor. Yield to finish the caller too.
        for _ in 0..<20 { await Task.yield() }

        #expect(surface.path == "new.txt")
        #expect(editor.superview === surface, "the cancelled image must not remove the current editor")
        #expect(!surface.subviews.contains { $0 is FileFailureView })
    }

    @Test func successfulHTTPWithMalformedImageReportsFailure() async throws {
        let surface = FileSurfaceView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        surface.fetchData = { _ in Data("not image bytes".utf8) }
        surface.show(path: "broken.png", revealLine: nil)
        surface.setContent(.asset(URL(string: "https://fixture.invalid/broken.png")!))

        #expect(await eventually(seconds: 2) {
            surface.subviews.contains { $0 is FileFailureView }
        }, "malformed image bytes must produce an error instead of a permanently blank preview")
    }
}
