import AppKit
import Foundation
import Testing
import T3Protocol
import T3Store
@testable import Features

/// Expected to expose current bugs. Parent runs these explicitly during the audit.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CW_THREAD_AUDIT_REGRESSIONS"] == "1"), .serialized)
@MainActor
struct ThreadResponsivenessAuditRegressions {
    @Test func oldRowsStayInertUntilNewRowsAreApplied() async throws {
        let all = try ThreadPreview.projections()
        let a = try #require(all.first { !$0.visibleTurnItems.isEmpty })
        let b = try #require(all.first { $0.thread.id != a.thread.id && !$0.visibleTurnItems.isEmpty })
        let panel = ThreadPanelView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        panel.model.backgroundRowsThreshold = .max
        panel.setProjection(a, projectTitle: "Audit", workspaceRoot: nil)
        let oldRows = panel.timeline.items
        #expect(!oldRows.isEmpty)
        panel.beginThreadSwitch(projectTitle: "Audit", threadTitle: b.thread.title, keepRows: true)
        #expect(panel.timeline.isInert)
        // Force the production >= 1,500-item path without depending on fixture size.
        panel.model.backgroundRowsThreshold = 0
        panel.setProjection(b, projectTitle: "Audit", workspaceRoot: nil)
        #expect(panel.model.rowsTask != nil)
        #expect(panel.timeline.items == oldRows)
        #expect(panel.timeline.isInert, "old thread's rows are still visible while the new worker runs")
        await panel.model.rowsSettled()
        #expect(panel.model.projection?.thread.id == b.thread.id)
        #expect(panel.timeline.items == panel.model.items)
        #expect(!panel.timeline.isInert)
    }

    @Test func failedHistoryDemandCanRetryTheSameCursor() throws {
        let projection = try #require(try ThreadPreview.projections().first)
        var reducer = ThreadReducer(threadId: projection.thread.id)
        reducer.applySnapshot(ThreadDetailSnapshot(snapshotSequence: 1, projection: projection,
            historyCursor: Tristate("audit-page"), hasMoreHistory: true))
        let timeline = TimelineView(frame: NSRect(x: 0, y: 0, width: 844, height: 728))
        timeline.setItems([TimelineItem(row: TimelineRow(id: "fold", createdAt: nil,
            kind: .turnFold(runId: "run", label: "Worked for 1s", expanded: false)))])
        timeline.layoutSubtreeIfNeeded()
        timeline.historyCursor = reducer.history.historyCursor
        var requests = 0
        timeline.onNearTop = {
            if reducer.beginLoadEarlier() != nil { requests += 1 }
        }
        // Invoke the same focused callback as an upward wheel, without a shared screen.
        timeline.scrollView.onGesture?(-60, false, false)
        #expect(requests == 1)
        reducer.failHistoryLoad(requestCursor: "audit-page", message: "Audit timeout")
        #expect(!reducer.history.loading && reducer.history.error != nil)
        // ThreadSession.render forwards only this history field to the timeline.
        timeline.historyCursor = reducer.history.historyCursor
        timeline.scrollView.onGesture?(-60, false, false)
        #expect(requests == 2, "a failed request must not permanently consume paging demand")
    }
}

/// Bounded measurements only. No server, disk cache, window, or account access.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CW_THREAD_AUDIT_STRESS"] == "1"), .serialized)
@MainActor
struct ThreadResponsivenessAuditStress {
    private func ms(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    private func emit(_ name: String, bytes: Int, values: [Double]) throws {
        let sorted = values.sorted()
        func percentile(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * p)) - 1)] }
        let result: [String: Any] = ["name": name, "bytes": bytes, "samples": values.count,
            "p50_ms": percentile(0.5), "p95_ms": percentile(0.95), "p99_ms": percentile(0.99),
            "max_ms": sorted.last!, "raw_ms": values]
        print("THREAD_AUDIT " + String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
    }

    @Test func coldLargeMarkdownLatency() throws {
        for targetBytes in [64 << 10, 256 << 10, 1 << 20] {
            for softBreaks in [false, true] {
                let unit = softBreaks ? "number 12345 and **bold** words\n" : "## Finding\n\nA **bold** paragraph with [reference][r].\n\n- first\n- second\n\n```swift\nlet answer = 42\n```\n\n| Key | Value |\n| --- | --- |\n| x | 42 |\n\n"
                let text = String(repeating: unit, count: max(1, targetBytes / unit.utf8.count)) + "\n\n[r]: https://example.com\n"
                var parse: [Double] = [], layout: [Double] = []
                for _ in 0..<21 {
                    let start = ContinuousClock.now
                    let document = MarkdownDocument(parsing: text, preservesLineBreaks: softBreaks)
                    parse.append(ms(ContinuousClock.now - start))
                    let layoutStart = ContinuousClock.now
                    let result = MarkdownLayout(document: document, width: 680)
                    layout.append(ms(ContinuousClock.now - layoutStart))
                    #expect(result.height > 0)
                }
                let kind = softBreaks ? "soft_breaks" : "mixed_blocks"
                try emit("cold_parse_\(kind)", bytes: text.utf8.count, values: parse)
                try emit("cold_layout_\(kind)", bytes: text.utf8.count, values: layout)
            }
        }
    }
}
