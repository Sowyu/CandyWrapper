import AppKit
import Testing
import DesignSystem
import T3Protocol
@testable import T3Store
@testable import Features

/// The thread details card's Lineage section, the provider subagent bar and the secret request card against T3's
/// markup in Chromium (specs from scripts/gen-thread-lineage-spec.py, references in
/// design/component-reference/{thread-lineage,subagent-bar,secret-request}). Writes ref, ours and diff PNGs plus
/// report-thread-lineage.html to /tmp/candywrapper-fidelity.
@MainActor
struct ThreadLineageFidelityTests {
    static let out = URL(fileURLWithPath: "/tmp/candywrapper-fidelity/thread-lineage")

    static func lineageRow(_ spec: [String], index: Int) -> ThreadRelationships.Lineage.Row {
        let (kind, status, title) = (spec[0], spec[1], spec[2])
        let id = ThreadId("t\(index)")
        let current = ThreadId("current")
        let parent = kind == "parent" || kind == "merge"
        let subagent = kind == "subagent" || kind == "parent"
        let edge = ThreadRelationshipEdge(sourceThreadId: parent ? id : current, targetThreadId: parent ? current : id,
                                          kind: subagent ? .subagent : .fork, status: status)
        return .init(threadId: id, edge: edge, status: status, isParent: parent, isSubagent: subagent, isMergeTarget: kind == "merge",
                     missing: false, title: title, agent: nil, child: nil,
                     relationship: ThreadRelationships.relationshipLabel(edge, current))
    }

    static func lineage(_ n: [String: Any]) -> ThreadLineageSectionView {
        var l = ThreadRelationships.Lineage()
        var i = 0
        func rows(_ key: String) -> [ThreadRelationships.Lineage.Row] {
            ((n[key] as? [[String]]) ?? []).map { i += 1; return lineageRow($0, index: i) }
        }
        l.related = rows("related")
        l.active = rows("active")
        l.previous = rows("previous")
        l.runningCount = n["running"] as? Int ?? 0
        l.canDetach = n["canDetach"] as? Bool ?? false
        if n["mergeRun"] as? Bool == true, let target = l.related.first(where: \.isMergeTarget) {
            l.mergeTarget = target.threadId
            l.mergeRunId = RunId("run:1")
        }
        let v = ThreadLineageSectionView()
        v.lineage = l
        if n["expandPrevious"] as? Bool == true { v.previousExpanded = true }
        v.frame = NSRect(x: 8, y: 8, width: 262, height: v.preferredHeight)
        return v
    }

    static func bar(_ n: [String: Any]) -> NSView {
        let v = ProviderSubagentBarView()
        v.modelLabel = n["model"] as! String
        let effort = n["effort"] as? String ?? ""
        v.effortLabel = effort.isEmpty ? nil : effort
        if let status = n["status"] as? String {
            let started: T3Timestamp? = (n["startedAt"] as? String).map { T3Timestamp($0) }
            let completed: T3Timestamp? = (n["completedAt"] as? String).map { T3Timestamp($0) }
            v.status = ThreadRelationships.SubagentStatus(status: status, startedAt: started, completedAt: completed)
        }
        if (n["parent"] as? String ?? "").isEmpty == false { v.onOpenParent = {} }
        v.frame = NSRect(x: 8, y: 8, width: 640, height: 48)
        return v
    }

    static func secret(_ n: [String: Any]) throws -> NSView {
        var item: [String: Any] = ["id": "item-1", "threadId": "thread-1", "type": "secret_request", "ordinal": 1,
                                   "status": "waiting", "updatedAt": "2026-10-11T10:00:00.000Z", "label": n["label"] as! String,
                                   "reason": n["reason"] as? String ?? "", "secretStatus": n["status"] as! String]
        if (n["reason"] as? String)?.isEmpty == true { item["reason"] = "" }
        let turnItem = try JSONDecoder().decode(TurnItem.self, from: JSONSerialization.data(withJSONObject: item))
        let projected = ProjectedTurnItem(position: 1, visibility: n["visibility"] as! String, sourceThreadId: ThreadId("thread-1"),
                                          sourceItemId: TurnItemId("item-1"), item: turnItem)
        var ui = TimelineRowUI()
        ui.secretError = n["error"] as? String
        let timelineItem = TimelineItem(row: TimelineRow(id: "item-1", createdAt: nil, kind: .event(projected, subagents: nil, resourceSummary: false)), ui: ui)
        let v = SecretRequestRowView()
        v.context = TimelineContext()
        v.configure(timelineItem)
        v.frame = NSRect(x: 8, y: 8, width: 520, height: v.height(forWidth: 520))
        return v
    }

    @Test func lineageBarAndSecret() throws {
        let repo = SidebarFidelityTests.repo
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        var lines: [(String, Double)] = [], images = ""
        for component in ["thread-lineage", "subagent-bar", "secret-request"] {
            let refDir = repo.appendingPathComponent("design/component-reference/\(component)")
            let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: repo.appendingPathComponent("design/component-reference/\(component).json"))) as! [String: Any]
            for c in spec["cases"] as! [[String: Any]] {
                let name = c["name"] as! String, native = c["native"] as! [String: Any]
                for theme in spec["themes"] as! [String] {
                    let base = "\(component).\(name).\(theme)"
                    let ref = try #require(NSBitmapImageRep(data: Data(contentsOf: refDir.appendingPathComponent("\(name).rest.\(theme).png"))))
                    let canvas = SidebarSearchFidelityTests.Canvas(frame: .zero)
                    let view: NSView = switch component {
                    case "thread-lineage": Self.lineage(native)
                    case "subagent-bar": Self.bar(native)
                    default: try Self.secret(native)
                    }
                    canvas.addSubview(view)
                    let ours = Snapshot.image(of: canvas, size: NSSize(width: CGFloat(ref.pixelsWide) / 2, height: CGFloat(ref.pixelsHigh) / 2),
                                              scale: 2, dark: theme == "dark")
                    let (total, _, diff) = SidebarFidelityTests.compare(ref, ours, bands: [])
                    try ref.representation(using: .png, properties: [:])!.write(to: Self.out.appendingPathComponent("\(base).ref.png"))
                    try Snapshot.writePNG(ours, to: Self.out.appendingPathComponent("\(base).ours.png"))
                    try Snapshot.writePNG(diff, to: Self.out.appendingPathComponent("\(base).diff.png"))
                    lines.append((base, total))
                    images += "<p>\(base): \(String(format: "%.2f", total * 100))%<br>"
                        + ["ref", "ours", "diff"].map { "<img style='zoom:.5' src='thread-lineage/\(base).\($0).png'>" }.joined() + "</p>"
                }
            }
        }
        for (base, total) in lines.sorted(by: { $0.1 > $1.1 }) { print("thread-lineage", base, String(format: "%.2f%%", total * 100)) }
        let mean = lines.map(\.1).reduce(0, +) / Double(max(1, lines.count))
        print(String(format: "FIDELITY thread-lineage: %d cases, mean differing %.2f%%", lines.count, mean * 100))
        let html = "<!doctype html><meta charset=utf-8><title>Thread lineage</title><body style='font:13px -apple-system'>" + images
        try html.write(to: Self.out.deletingLastPathComponent().appendingPathComponent("report-thread-lineage.html"), atomically: true, encoding: .utf8)
        #expect(mean < 0.05)
    }
}
