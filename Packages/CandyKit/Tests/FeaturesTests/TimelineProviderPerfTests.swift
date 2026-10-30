import AppKit
import Testing
import T3Protocol
import T3Store
@testable import Features

@MainActor
struct TimelineProviderPerfTests {
    @Test func providerProbesDoNotRefreshHandoffRows() throws {
        var projection = try #require(try ThreadPreview.projections().first)
        let handoff = try TurnItem(json: .object([
            "id": .string("handoff"), "threadId": .string(projection.thread.id.rawValue),
            "type": .string("handoff"), "status": .string("completed"), "ordinal": .number(1),
            "createdAt": .string("2026-10-22T00:00:00.000Z"), "updatedAt": .string("2026-10-22T00:00:00.000Z"),
            "fromProviderInstanceIds": .array([.string("source")]), "toProviderInstanceId": .string("target")
        ]))
        projection.turnItems = [handoff]
        projection.visibleTurnItems = [ProjectedTurnItem(local: handoff)]
        let model = ThreadViewModel()
        var source = ServerProvider(instanceId: "source", driver: "codex", displayName: "Source")
        var target = ServerProvider(instanceId: "target", driver: "claudeAgent", displayName: "Target")
        model.providers = [source, target]
        model.setProjection(projection)
        #expect(model.items.contains { if case .event(let p, _, _) = $0.row.kind { return p.item.type == .handoff }; return false })
        var refreshedRows = 0
        model.onChange = { change in
            if case .rows(let rows) = change { refreshedRows += rows.count }
        }
        for n in 0..<20 {
            source.checkedAt = "probe-\(n)"
            target.status = n.isMultiple(of: 2) ? .ready : .error
            model.providers = [source, target]
        }
        #expect(refreshedRows == 0)
        target.displayName = "Renamed target"
        model.providers = [source, target]
        #expect(refreshedRows == 1)
        model.providers.append(ServerProvider(instanceId: "unrelated", driver: "codex"))
        #expect(refreshedRows == 1)
        model.providers = [source]
        #expect(refreshedRows == 2)
    }
}
