import AppKit
import Testing
import T3Protocol
import T3Store
import DesignSystem
@testable import Features

@MainActor
struct McpFollowupsTests {
    static func projected(status: String, result: String? = nil, progress: String? = nil, seconds: Int? = nil, child: Bool = true) throws -> ProjectedTurnItem {
        var fields: [String: Any] = ["id":"agent-item", "threadId":"parent", "type":"subagent", "ordinal":1,
                                   "status":status, "title":"Audit the schema", "subagentId":"agent", "updatedAt":"2026-10-11T10:00:00Z"]
        fields["result"] = result; fields["progress"] = progress
        if child { fields["childThreadId"] = "child" }
        if let seconds {
            fields["startedAt"] = "2026-10-11T10:00:00Z"
            fields["completedAt"] = "2026-10-11T10:\(String(format: "%02d", seconds / 60)):\(String(format: "%02d", seconds % 60))Z"
        }
        return ProjectedTurnItem(local: try JSONDecoder().decode(TurnItem.self, from: JSONSerialization.data(withJSONObject: fields)))
    }
    @Test func detailPrecedenceAndCleanup() throws {
        let p = try Self.projected(status: "running", result: "old result", progress: "- Read [`index`](index.md)\n* Next file")
        #expect(SubagentCardPresentation(p).detail == "Read index Next file")
        let live: JSONValue = .object(["status":.string("completed"), "result":.string("Finished"), "progress":.string("outdated")])
        #expect(SubagentCardPresentation(p, live: live).detail == "Finished")
        #expect(SubagentCardPresentation(p, live: live).statusLabel == "Completed")
        #expect(SubagentCardPresentation(try Self.projected(status: "failed", result: "Child task ended with status failed")).detail == nil)
        #expect(SubagentCardPresentation(try Self.projected(status: "idle")).statusLabel == "Idle · resumable")
        #expect(SubagentCardPresentation(try Self.projected(status: "completed", seconds: 65)).elapsed(now: 0) == "1m 05s")
    }
    @Test func groupedCardsHaveSeparateTargetsAndReleaseOnReuse() throws {
        let p = try Self.projected(status: "completed")
        let q = try Self.projected(status: "waiting", child: false)
        let row = TimelineRow(id: "agents", createdAt: nil, kind: .event(p, subagents: [p,q], resourceSummary: false))
        #expect(TimelineView.kind(row) == .subagent)
        let view = SubagentCardRowView(); view.context = TimelineContext()
        view.configure(TimelineItem(row: row))
        #expect(view.links.count == 2)
        #expect(view.links[0].presentation?.child == ThreadId("child"))
        #expect(view.links[1].presentation?.child == nil)
        view.prepareForReuse()
        #expect(view.links.isEmpty)
    }
    @Test func liveSubagentUpdatesRefreshAnUnchangedTimelineItem() throws {
        var projection = try #require(ThreadPreview.projections().first)
        let agent = try Self.projected(status: "running")
        projection.visibleTurnItems = [agent]
        projection.turnItems = [agent.item]
        projection.runs = []; projection.attempts = []; projection.messages = []; projection.nodes = []
        projection.subagents = [.object(["id": .string("agent"), "status": .string("running")])]
        let model = ThreadViewModel()
        model.setProjection(projection)
        let before = try #require(model.items.first { if case .event = $0.row.kind { return true }; return false })
        projection.subagents = [.object(["id": .string("agent"), "status": .string("completed"), "result": .string("Finished")])]
        model.setProjection(projection)
        let after = try #require(model.items.first { $0.id == before.id })
        #expect(before.row == after.row)
        #expect(after.ui.subagentRecords.first?["status"]?.stringValue == "completed")
        #expect(before != after)
    }
    static func notification(outcome: String, kind: String = "delegated_task", work: String? = nil) throws -> WorkLogEntry {
        var source: [String: Any] = ["kind": kind, "childThreadId": "child"]
        if let work { source["work"] = work }
        let fields: [String: Any] = ["id": "note", "threadId": "parent", "type": "notification", "ordinal": 2, "status": "completed",
                                     "outcome": outcome, "source": source, "updatedAt": "2026-10-11T10:05:00Z"]
        let item = ProjectedTurnItem(local: try JSONDecoder().decode(TurnItem.self, from: JSONSerialization.data(withJSONObject: fields)))
        return WorkLogEntry(id: "note", createdAt: "2026-10-11T10:05:00Z", label: "Delegated task finished", tone: .info,
                            itemType: .notification, projectedItem: item)
    }
    static let record: JSONValue = .object(["id": .string("agent"), "childThreadId": .string("child"), "title": .string("Audit the schema"),
                                            "status": .string("running"), "progress": .string("Reading files"), "driver": .string("claudeAgent")])

    @Test func notificationDrawsTheSubagentAtTheEvent() throws {
        // V2LifecycleRow.tsx:335-353: the outcome picks the dot and the label; the time replaces the elapsed time.
        let done = SubagentCardPresentation(record: Self.record, event: SubagentCardPresentation.notificationEvent(outcome: "completed", timestamp: "10:05"))
        #expect(done.status == "completed" && done.liveStatus == "running")
        #expect(done.statusLabel == "Finished" && done.showsStatusBesideTitle)
        #expect(done.trailing(now: 0) == "10:05" && !done.ticks)
        #expect(done.child == ThreadId("child"))
        let updated = SubagentCardPresentation(record: Self.record, event: SubagentCardPresentation.notificationEvent(outcome: "updated", timestamp: "10:05"))
        #expect(updated.status == nil && updated.statusLabel == "Updated")
        // Unsettled at the event, so progress wins over the result.
        #expect(updated.detail == "Reading files")
        #expect(SubagentCardPresentation.notificationEvent(outcome: "unknown", timestamp: "").label == "Finished")
        #expect(SubagentCardPresentation.notificationEvent(outcome: "cancelled", timestamp: "").label == "Stopped")
    }

    /// 6670dc734e: a subagent resumed since the notification drops the stale outcome.
    @Test func resumedSubagentShowsItsLiveStatus() {
        let at = T3Timestamp("2026-10-11T10:05:00Z")
        #expect(SubagentCardPresentation.resumedSince(status: "running", startedAt: nil, notifiedAt: at))
        #expect(SubagentCardPresentation.resumedSince(status: "completed", startedAt: "2026-10-11T10:06:00Z", notifiedAt: at))
        #expect(!SubagentCardPresentation.resumedSince(status: "completed", startedAt: "2026-10-11T10:04:00Z", notifiedAt: at))
        #expect(!SubagentCardPresentation.resumedSince(status: "failed", startedAt: nil, notifiedAt: at))
        let live = SubagentCardPresentation(record: Self.record, event: nil)
        #expect(live.status == "running" && live.event == nil)
    }

    @Test func notificationCardNeedsTheParentsRecord() throws {
        let e = try Self.notification(outcome: "failed")
        #expect(SubagentCardPresentation.notificationChild(e) == "child")
        #expect(SubagentCardPresentation.notificationCard(e, records: []) == nil)
        // A settled record keeps the reported outcome; a running one was resumed since (6670dc734e).
        guard case .object(var fields) = Self.record else { return }
        fields["status"] = .string("failed")
        let settled = JSONValue.object(fields)
        #expect(SubagentCardPresentation.notificationCard(e, records: [settled])?.status == "failed")
        #expect(SubagentCardPresentation.notificationCard(e, records: [Self.record])?.event == nil)
        #expect(SubagentCardPresentation.notificationChild(try Self.notification(outcome: "completed", kind: "command")) == nil)
        // The wire shape of a subagent source (orchestrationV2.ts:1072-1090), as a real Claude subagent sends it.
        let wire = try Self.notification(outcome: "completed", kind: "background_task", work: "subagent")
        #expect(SubagentCardPresentation.notificationChild(wire) == "child")
        #expect(WorkIcons.entry(wire) == .bot)
        #expect(SubagentCardPresentation.notificationChild(try Self.notification(outcome: "completed", kind: "background_task")) == nil)
        #expect(NotificationSource.kind(.object(["kind": .string("background_command")])) == "command")
        #expect(NotificationSource.kind(.object(["kind": .string("newer_kind")])) == "background_task")

        let row = TimelineRow(id: "work", createdAt: nil, kind: .work(groupedEntries: [e], isExpandedToolGroup: false, displayLabel: nil))
        var ui = TimelineRowUI(); ui.subagentRecords = [Self.record]
        let view = WorkRowView(); view.context = TimelineContext()
        view.configure(TimelineItem(row: row, ui: ui))
        #expect(view.height(forWidth: 520) == SubagentCardLinkView.height + 8)
        view.configure(TimelineItem(row: row))
        #expect(abs(view.height(forWidth: 520) - 36) < 0.01) // the work line, `py-0.5` and `pb-2`
    }

    @Test func lineageAgentsUseTheSameHoverCard() {
        let a = ProjectedSubagent(id: "agent", childThreadId: ThreadId("child"), origin: "app_owned", driver: "claudeAgent", providerInstanceId: "claudeAgent",
                                  title: "Audit the schema", model: "claude-haiku-5-5", status: "completed", progress: nil, result: "Found two problems",
                                  startedAt: "2026-10-11T10:00:00Z", completedAt: "2026-10-11T10:01:05Z")
        let p = SubagentCardPresentation(agent: a, title: "Audit the schema")
        #expect(p.liveStatus == "completed" && p.hoverDetail == "Found two problems" && p.elapsed(now: 0) == "1m 05s")
        #expect(ThreadRelationships.modelSlugName(p.model ?? "") == "Claude Haiku 5.5")
        #expect(SubagentCardHoverView(p).popupSize.height == 110)
    }

    @Test func watchUsesIndependent32PointCell() {
        let row = DetailsRowControl(); let eye = PullRequestWatchToggle(number: 1)
        row.secondary = eye; row.frame = NSRect(x: 0, y: 0, width: 262, height: 32); row.layout()
        #expect(eye.frame == NSRect(x: 230, y: 0, width: 32, height: 32))
        var opened = false, stopped = false
        row.action = { opened = true }; eye.action = { stopped = true }
        eye.performAction()
        #expect(stopped && !opened)
    }
}

@MainActor
struct McpFollowupsFidelityTests {
    @Test func cardsAndWatch() throws {
        let repo = SidebarFidelityTests.repo
        let out = repo.appendingPathComponent(".build/mcp-followups-fidelity")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: repo.appendingPathComponent("design/component-reference/mcp-followups.json"))) as! [String: Any]
        var scores: [Double] = []
        for c in spec["cases"] as! [[String: Any]] {
            let name = c["name"] as! String, n = c["native"] as! [String: Any]
            for theme in ["light", "dark"] {
                let ref = try #require(NSBitmapImageRep(data: Data(contentsOf: repo.appendingPathComponent("design/component-reference/mcp-followups/\(name).rest.\(theme).png"))))
                let canvas = SidebarSearchFidelityTests.Canvas(frame: .zero)
                let view: NSView
                if name == "hover-card" {
                    let p = try McpFollowupsTests.projected(status: "completed", result: "Found two problems", seconds: 65)
                    let card = SubagentCardHoverView(SubagentCardPresentation(p))
                    card.frame = NSRect(origin: NSPoint(x: 8, y: 8), size: card.popupSize); view = card
                } else if name == "watch" {
                    let row = DetailsRowControl(); row.text = "#1: Improve the queue"
                    row.icons = [IconName.gitPullRequestArrow.definition]; row.iconColor = Themed.color(\.success)
                    row.secondary = PullRequestWatchToggle(number: 1)
                    // The card sets rows 1pt in for the control border (ThreadDetailsCardView.layout), as T3 draws it.
                    row.frame = NSRect(x: 9, y: 8, width: 261, height: 32); view = row
                } else if n["notification"] as? Bool == true {
                    let record: JSONValue = .object(["id": .string("agent"), "childThreadId": .string("child"), "title": .string("Audit the schema"),
                                                     "status": .string("completed"), "result": .string("Found two problems")])
                    let card = SubagentCardLinkView()
                    card.configure(SubagentCardPresentation(record: record, event: SubagentCardPresentation.notificationEvent(outcome: "completed", timestamp: "10:05")))
                    card.frame = NSRect(x: 8, y: 8, width: 520, height: SubagentCardLinkView.height); view = card
                } else {
                    let p = try McpFollowupsTests.projected(status: n["status"] as! String, result: n["detail"] as? String, seconds: n["seconds"] as? Int, child: n["child"] as! Bool)
                    let row = SubagentCardRowView(); row.context = TimelineContext()
                    row.configure(TimelineItem(row: TimelineRow(id: "agent", createdAt: nil, kind: .event(p, subagents: nil, resourceSummary: false))))
                    row.frame = NSRect(x: 8, y: 8, width: 520, height: row.height(forWidth: 520)); view = row
                }
                canvas.addSubview(view)
                let ours = Snapshot.image(of: canvas, size: NSSize(width: CGFloat(ref.pixelsWide)/2, height: CGFloat(ref.pixelsHigh)/2), scale: 2, dark: theme == "dark")
                let (score, _, diff) = SidebarFidelityTests.compare(ref, ours, bands: [])
                scores.append(score)
                try Snapshot.writePNG(ours, to: out.appendingPathComponent("\(name).\(theme).ours.png"))
                try Snapshot.writePNG(diff, to: out.appendingPathComponent("\(name).\(theme).diff.png"))
                print(String(format: "mcp-followups %@ %@ %.2f%%", name, theme, score * 100))
            }
        }
        let mean = scores.reduce(0,+) / Double(scores.count)
        print(String(format: "FIDELITY mcp-followups: %d cases, mean differing %.2f%%", scores.count, mean * 100))
        #expect(mean < 0.05)
    }
}
