import AppKit
import Testing
import DesignSystem
@testable import Features

@MainActor
struct ArchiveSettingsViewTests {
    static func thread(_ i: Int) -> ArchivedSnapshot.Thread {
        .init(id: "t\(i)", projectId: "p", title: "Thread \(i)", archivedAt: nil, createdAt: "2026-11-01T00:00:00Z")
    }

    /// 5258 #41539: a chunk builds no rows until it nears the scroller's visible part, and still reports a height.
    @Test func chunksBuildRowsOnlyNearTheVisiblePart() {
        var built = 0
        let make: (ArchivedSnapshot.Thread) -> ArchivedThreadRow = { t in
            built += 1
            return ArchivedThreadRow(title: t.title, detail: "Archived 1d ago · Created 2d ago", control: NSView())
        }
        let near = ArchivedThreadChunk(threads: (0..<50).map(Self.thread), make: make)
        let far = ArchivedThreadChunk(threads: (50..<100).map(Self.thread), make: make)
        let h = near.height(forWidth: 600)
        #expect(h > 50 * 20)
        #expect(!near.isMounted && built == 1)  // one probe row measures the chunk

        let doc = DSView(frame: NSRect(x: 0, y: 0, width: 600, height: 2 * h + 5000))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        scroll.documentView = doc
        near.frame = NSRect(x: 0, y: 0, width: 600, height: h)
        far.frame = NSRect(x: 0, y: h + 4000, width: 600, height: h)
        doc.addSubview(near)
        doc.addSubview(far)
        near.updateMount()
        far.updateMount()
        #expect(near.isMounted && near.rows.count == 50)
        #expect(!far.isMounted)
        #expect(abs(near.height(forWidth: 600) - h) < 1)
    }
}
