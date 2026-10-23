import AppKit
import Foundation
import Testing
import DesignSystem
import T3Protocol
@testable import T3Store
@testable import Features

/// The subagent strip against real records from the user's T3 (Fixtures/subagent-strip-real-2026-10-23.json): one
/// gallery agent got four follow-up tasks, and 1.13.0 listed every one of them as a spinning row ("Subagent 6/4/3/2",
/// "Waiting on 4"). Set CANDY_STRIP_RENDER=<dir> to write real-before.png and real-after.png there.
@MainActor
struct SubagentStripRealDataTests {
    struct Fixture: Decodable {
        struct Parent: Decodable {
            var id: String; var title: String; var status: String; var latestRunId: String
            var pendingBackgroundTasks: [PendingBackgroundTask]
        }
        struct Child: Decodable {
            var id: String; var title: String; var creationSource: String; var status: String
            var activityRunStatus: String?; var activityRunStartedAt: String?
        }
        var parent: Parent
        var children: [Child]
        var subagents: [JSONValue]
    }

    static func fixture() throws -> Fixture {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/subagent-strip-real-2026-10-23.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    static func shell(id: String, title: String, parent: String?, creationSource: String, status: String,
                      activity: String?, activityStartedAt: String?, latestRunId: String? = nil,
                      background: [PendingBackgroundTask] = []) throws -> ThreadShell {
        func q(_ s: String?) -> String { s.map { "\"\($0)\"" } ?? "null" }
        let json = """
            {"id":\(q(id)),"projectId":"p","title":\(q(title)),"providerInstanceId":"claudeAgent",
             "modelSelection":{"instanceId":"claudeAgent","model":"claude-opus-5-5"},"runtimeMode":"full-access",
             "interactionMode":"default","branch":null,"worktreePath":null,"activeProviderThreadId":null,
             "lineage":{"rootThreadId":\(q(parent ?? id)),"parentThreadId":\(q(parent)),"relationshipToParent":\(parent == nil ? "null" : "\"subagent\"")},
             "forkedFrom":null,"createdBy":"agent","creationSource":\(q(creationSource)),"activeRunId":null,
             "pendingRuntimeRequest":null,"latestVisibleMessage":null,"latestUserMessageAt":null,
             "hasActionableProposedPlan":false,"itemCount":0,"visibleItemCount":0,"status":\(q(status)),
             "latestRunId":\(q(latestRunId)),"activityRunStatus":\(q(activity)),"activityRunStartedAt":\(q(activityStartedAt)),
             "createdAt":"2026-10-23T00:00:00.000Z","updatedAt":"2026-10-23T00:00:00.000Z","archivedAt":null,
             "settledOverride":null,"settledAt":null,"lastVisitedAt":null,"deletedAt":null}
            """
        var shell = try JSONDecoder().decode(ThreadShell.self, from: Data(json.utf8))
        shell.pendingBackgroundTasks = background
        return shell
    }

    static func inputs() throws -> (subagents: [JSONValue], shells: [ThreadShell], latestRunId: RunId, parent: ThreadShell) {
        let f = try fixture()
        let parent = try shell(id: f.parent.id, title: f.parent.title, parent: nil, creationSource: "web", status: f.parent.status,
                               activity: nil, activityStartedAt: nil, latestRunId: f.parent.latestRunId, background: f.parent.pendingBackgroundTasks)
        let children = try f.children.map {
            try shell(id: $0.id, title: $0.title, parent: f.parent.id, creationSource: $0.creationSource, status: $0.status,
                      activity: $0.activityRunStatus, activityStartedAt: $0.activityRunStartedAt)
        }
        return (f.subagents, [parent] + children, RunId(f.parent.latestRunId), parent)
    }

    /// The strip as 1.13.0 (d391fc57) built it: a row per task record, each following its child's live run.
    static func legacy(subagents: [JSONValue], shells: [ThreadShell], latestRunId: RunId, parent: ThreadShell) -> SubagentStrip {
        let children = Dictionary(shells.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let active: Set<String> = ["pending", "running", "waiting"]
        var live: [SubagentStrip.Row] = [], done: [SubagentStrip.Row] = []
        for (index, json) in subagents.enumerated() {
            guard let record = ProjectedSubagent(json) else { continue }
            let agent = record.following(record.childThreadId.flatMap { children[$0] })
            let on = active.contains(agent.status)
            let row = SubagentStrip.Row(id: record.id, key: record.id, number: index + 1, childThreadId: agent.childThreadId,
                                        title: children[record.childThreadId ?? ""]?.title ?? agent.title,
                                        status: on ? .running : (agent.status == "completed" ? .done : .failed), driver: agent.driver,
                                        providerInstanceId: agent.providerInstanceId, model: agent.model, canStop: SubagentStrip.canStop(agent))
            if on { live.append(row) } else if record.runId == latestRunId { done.append(row) }
        }
        var strip = SubagentStrip()
        strip.rows = live.reversed() + done.reversed().prefix(SubagentStrip.finishedCap)
        strip.activeCount = live.count
        strip.parentWaiting = !live.isEmpty && parent.backgroundTasks.contains { $0.kind == .subagent }
        return strip
    }

    @Test func legacyLogicReproducesTheUsersScreenshot() throws {
        let i = try Self.inputs()
        let strip = Self.legacy(subagents: i.subagents, shells: i.shells, latestRunId: i.latestRunId, parent: i.parent)
        #expect(strip.rows.map(\.label) == ["Subagent 6", "Subagent 4", "Subagent 3", "Subagent 2"])
        #expect(strip.rows.allSatisfy { $0.status == .running && $0.title == "Redesign: agent image gallery" })
        #expect(strip.pillText == "Waiting on 4")
    }

    @Test func oneRowForTheGalleryWithItsLatestTask() throws {
        let i = try Self.inputs()
        let strip = SubagentStrip.make(subagents: i.subagents, shells: i.shells, latestTurn: [i.latestRunId], parent: i.parent)
        // (a) The gallery agent is one row, numbered by its first task, showing its running 5th task.
        let gallery = strip.rows.filter { $0.title == "Redesign: agent image gallery" }
        #expect(gallery.count == 1)
        #expect(gallery.first?.label == "Subagent 2")
        #expect(gallery.first?.status == .running)
        #expect(gallery.first?.id.hasSuffix("gallery-dedupe-fit-1") == true)
        // (b) Finished tasks never spin and never count: the strip agent's settled tasks are from older turns, so they
        // are left out, and the count is the one live task.
        #expect(strip.rows.count == 1)
        #expect(strip.rows.filter { $0.status == .running }.count == strip.activeCount)
        #expect(strip.activeCount == 1)
        #expect(strip.pillText == "Waiting on 1")
    }

    @Test func aFinishedTaskOnALiveChildNeverSpinsOnItsOwn() throws {
        // Drop the running task: the gallery child still has a live run (the user steering it, say), so its newest
        // settled task follows that run, but only as one row, and the other settled tasks never add rows.
        let i = try Self.inputs()
        let settled = i.subagents.filter { $0["status"]?.stringValue != "running" }
        let strip = SubagentStrip.make(subagents: settled, shells: i.shells, latestTurn: [i.latestRunId], parent: i.parent)
        #expect(strip.rows.filter { $0.title == "Redesign: agent image gallery" }.count <= 1)
        #expect(strip.activeCount <= 1)
    }

    @Test func renderBeforeAndAfter() throws {
        guard let dir = ProcessInfo.processInfo.environment["CANDY_STRIP_RENDER"] else { return }
        let i = try Self.inputs()
        let after = SubagentStrip.make(subagents: i.subagents, shells: i.shells, latestTurn: [i.latestRunId], parent: i.parent)
        let before = Self.legacy(subagents: i.subagents, shells: i.shells, latestRunId: i.latestRunId, parent: i.parent)
        for (name, strip) in [("real-before", before), ("real-after", after)] {
            try Self.render(strip, to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
        }
    }

    /// The redesigned panel from the real records as of the snapshot, and with eleven rows to show the height cap.
    @Test func renderFinal() throws {
        guard let dir = ProcessInfo.processInfo.environment["CANDY_STRIP_RENDER"] else { return }
        let i = try Self.inputs()
        let real = SubagentStrip.make(subagents: i.subagents, shells: i.shells, latestTurn: [i.latestRunId], parent: i.parent)
        let now = try #require(T3Timestamp("2026-10-23T12:35:00.000Z").epochMs)
        var many = real
        many.rows += SubagentStripPanelTests.finishedRows(10)
        for (name, strip) in [("final-B", real), ("final-B-many", many)] {
            try Self.render(strip, nowMs: now, to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
        }
    }

    /// The real `ThreadPanelView` in Redesign dark, the strip open, cropped to the bottom 520pt.
    static func render(_ strip: SubagentStrip, nowMs: Int64? = nil, to url: URL) throws {
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        var input = ThemeRuntime.input
        input.ditherLight = true; input.ditherDark = true
        ThemeRuntime.apply(input)
        let size = NSSize(width: 1000, height: 700)
        let panel = ThreadPanelView(frame: NSRect(origin: .zero, size: size))
        panel.appearance = NSAppearance(named: .darkAqua)
        let projection = try JSONDecoder().decode(ThreadProjection.self, from: Data(#"{"thread":{"id":"t"},"runs":[],"updatedAt":"2026-10-23T00:00:00Z"}"#.utf8))
        panel.setProjection(projection, projectTitle: "CandyWrapper", workspaceRoot: nil)
        panel.lazySubagentPill.view.configure(strip)
        panel.lazySubagentPanel.view.nowMs = nowMs
        panel.lazySubagentPanel.view.items = strip.rows.map { .init(row: $0, modelName: ThreadRelationships.modelSlugName($0.model ?? "")) }
        panel.showsSubagentStrip = strip.isVisible
        panel.subagentStripExpanded = true
        panel.layoutSubtreeIfNeeded()
        panel.layoutSubtreeIfNeeded()
        // The open panel stays inside the space above the pill row, and wholly inside the crop.
        let visible: CGFloat = 520
        if strip.isVisible {
            let sheet = panel.lazySubagentPanel.view, pill = panel.lazySubagentPill.view
            #expect(!sheet.isHidden)
            #expect(sheet.frame.maxY + DitherPill.gap <= pill.frame.minY + 0.5)
            #expect(sheet.frame.minY >= size.height - visible + 8)
        }
        let rep = Snapshot.image(of: ThreadFidelityTests.onSurface(panel), size: size, scale: 2, dark: true)
        let crop2x = visible * 2
        let crop = try #require(rep.cgImage?.cropping(to: CGRect(x: 0, y: CGFloat(rep.pixelsHigh) - crop2x, width: CGFloat(rep.pixelsWide), height: crop2x)))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Snapshot.writePNG(NSBitmapImageRep(cgImage: crop), to: url)
    }
}
