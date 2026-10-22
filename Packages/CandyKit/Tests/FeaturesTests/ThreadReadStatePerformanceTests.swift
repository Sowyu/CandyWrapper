import AppKit
import Foundation
import Testing
import T3Protocol
@testable import Features

@MainActor
struct ThreadReadStatePerformanceTests {
    private func thread(_ original: AppThread, fields: [String: JSONValue]) throws -> AppThread {
        guard case .object(var raw) = original.raw else { preconditionFailure() }
        raw.merge(fields) { _, new in new }
        return try JSONDecoder().decode(AppThread.self, from: JSONEncoder().encode(JSONValue.object(raw)))
    }

    @Test func visitMarksAndEqualSnapshotsDoNotDeriveOrConfigureRows() throws {
        var projection = try #require(try ThreadPreview.projections().first { !$0.visibleTurnItems.isEmpty })
        let panel = ThreadPanelView(frame: NSRect(x: 0, y: 0, width: 844, height: 780))
        panel.model.backgroundRowsThreshold = Int.max
        panel.setProjection(projection, projectTitle: "demo-repo", workspaceRoot: nil)
        panel.layoutSubtreeIfNeeded()
        let derivations = panel.model.projectionDerivationCount
        let configurations = panel.timeline.configureCount
        panel.needsLayout = false
        for i in 1...20 {
            let mark = JSONValue.string("2026-10-22T10:00:\(String(format: "%02d", i)).000Z")
            projection.thread = try thread(projection.thread, fields: ["lastVisitedAt": mark, "updatedAt": mark])
            panel.setProjection(projection, projectTitle: "demo-repo", workspaceRoot: nil)
            panel.setProjection(projection, projectTitle: "demo-repo", workspaceRoot: nil)
        }
        #expect(panel.model.projectionDerivationCount == derivations)
        #expect(panel.timeline.configureCount == configurations)
        #expect(!panel.needsLayout)
        #expect(panel.model.projection == projection)

        // Mark unread also changes only read state.
        projection.thread = try thread(projection.thread, fields: ["lastVisitedAt": .null])
        panel.setProjection(projection, projectTitle: "demo-repo", workspaceRoot: nil)
        #expect(panel.model.projectionDerivationCount == derivations)
        #expect(panel.model.projection == projection)

        // A visit coalesced with a rename must still update the header and rows.
        projection.thread = try thread(projection.thread, fields: ["title": .string("Renamed")])
        panel.setProjection(projection, projectTitle: "demo-repo", workspaceRoot: nil)
        #expect(panel.model.projectionDerivationCount == derivations + 1)
        #expect(panel.header.threadTitle == "Renamed")
    }

    @Test func realUpdatesAndThreadSwitchesStillDerive() throws {
        var projection = try #require(try ThreadPreview.projections().first { !$0.visibleTurnItems.isEmpty })
        let panel = ThreadPanelView(frame: NSRect(x: 0, y: 0, width: 844, height: 780))
        panel.model.backgroundRowsThreshold = Int.max
        panel.setProjection(projection, projectTitle: "demo-repo", workspaceRoot: nil)
        let before = panel.model.projectionDerivationCount
        projection.visibleTurnItems.removeLast()
        panel.setProjection(projection, projectTitle: "demo-repo", workspaceRoot: nil)
        #expect(panel.model.projectionDerivationCount == before + 1)
        panel.beginThreadSwitch(projectTitle: "demo-repo", threadTitle: "Loading", keepRows: true)
        panel.setProjection(projection, projectTitle: "demo-repo", workspaceRoot: nil)
        #expect(panel.model.projectionDerivationCount == before + 2)
        #expect(!panel.switchingThread)
        #expect(!panel.timeline.isInert)
        panel.setProjection(projection, projectTitle: "Other project", workspaceRoot: "/sandbox")
        #expect(panel.model.projectionDerivationCount == before + 3)
        #expect(panel.model.workspaceRoot == "/sandbox")
        panel.opensChangedTurnOnLoad = true
        panel.setProjection(projection, projectTitle: "Other project", workspaceRoot: "/sandbox")
        #expect(panel.model.projectionDerivationCount == before + 4)
    }
}
