import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// The Workflows page (5258) against T3's markup in Chromium: spec from scripts/gen-workflows-spec.py, references in
/// design/component-reference/workflows.
@MainActor @Suite(.fidelity)
struct WorkflowsFidelityTests {
    /// Per-case ceilings, measured 2026-11-25 plus margin (FidelitySupport.swift). The feed headers carry Stop, an xs
    /// button whose icon gap is still 4928's 4pt where 5258 has 6pt (#37358, a DesignSystem change).
    static let ceilings: FidelityCeilings = [
        "workflows": .init(0.05, except: ["feed.header.running.rest.light": 0.07, "feed.header.running.rest.dark": 0.07,
                                          "feed.header.done.rest.light": 0.06, "feed.header.done.rest.dark": 0.06]),
    ]
    static let out = Fidelity.root.appendingPathComponent("workflows")
    static let now = T3Timestamp.parseEpochMs("2026-11-25T12:00:00.000Z")!

    static func ago(_ seconds: Int) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date(timeIntervalSince1970: Double(now) / 1000 - Double(seconds)))
    }

    static func decode<T: Decodable>(_ json: String) -> T { try! JSONDecoder().decode(T.self, from: Data(json.utf8)) }
    static func q(_ s: String?) -> String { s.map { "\"\($0)\"" } ?? "null" }

    static func run(_ id: String, workflow: String, title: String, status: String, detail: String? = nil, result: String = "null",
                    started: Int, updated: Int, ended: Int? = nil) -> WorkflowRun {
        decode("""
        {"runId":"\(id)","workflow":"\(workflow)","version":1,"title":"\(title)","status":"\(status)","detail":\(q(detail)),"result":\(result),
        "pauses":0,"retired":false,"resumesAt":null,"parentRunId":null,"parentStep":null,"startedAt":"\(ago(started))",
        "updatedAt":"\(ago(updated))","endedAt":\(q(ended.map(ago)))}
        """)
    }

    static func question(_ runId: String, kind: String? = nil) -> WorkflowQuestion {
        decode("""
        {"runId":"\(runId)","name":"approve","kind":\(q(kind)),"askedAt":"\(ago(300))","thread":null,"request":{"title":"Ship the fix?",
        "choices":["Ship it","Hold"],"choiceDetails":[{"value":"Ship it","description":"Merges and deploys."},{"value":"Hold","requireReason":true}],
        "links":[{"label":"Pull request","url":"https://example.com/pull/1"}]}}
        """)
    }

    /// The rows of gen-workflows-spec.py's `ROWS`.
    static let nodes: [String: WorkflowRunNode] = [
        "needs": .init(run: run("needs", workflow: "triage", title: "Fix the login bug", status: "waiting", started: 300, updated: 300),
                       questions: [question("needs")]),
        "working": .init(run: run("working", workflow: "nightly-review", title: "Review last night's commits", status: "waiting",
                                  detail: "agent review", started: 600, updated: 120)),
        "paused": .init(run: run("paused", workflow: "deploy", title: "Deploy to staging", status: "paused", detail: "build failed: exit 1",
                                 started: 4000, updated: 3600)),
        "done": .init(run: run("done", workflow: "triage", title: "Label new issues", status: "completed", result: #"{"labelled":4}"#,
                               started: 3 * 86400, updated: 3 * 86400, ended: 3 * 86400 - 123)),
        "quiet": .init(run: run("quiet", workflow: "deploy", title: "Wait for the window", status: "waiting", detail: "sleep wait-window",
                                started: 60, updated: 0)),
    ]

    /// Two workflows, a question of kind `bug` and one of no kind.
    static let snapshot: WorkflowRunsSnapshot = {
        var s = WorkflowRunsSnapshot()
        s.workflows = decode(#"[{"name":"triage","version":1,"triggers":["every 1h"],"asks":[{"kind":"bug","label":"Bug?"}]},{"name":"deploy","version":1,"triggers":[]}]"#)
        s.runs = [nodes["needs"]!.run, nodes["paused"]!.run,
                  run("other", workflow: "deploy", title: "Roll back", status: "waiting", started: 100, updated: 100)]
        s.questions = [question("needs", kind: "bug"),
                       decode(#"{"runId":"other","name":"go","request":{"title":"Go?"},"askedAt":"\#(ago(100))","thread":null}"#)]
        return s
    }()

    /// A view cut to `rect` of a larger one, as T3 draws the part as its own element.
    static func cut(_ view: NSView, _ rect: NSRect) -> NSView {
        let box = DSView(frame: NSRect(origin: .zero, size: rect.size))
        box.wantsLayer = true
        box.layer?.masksToBounds = true
        view.frame.origin = NSPoint(x: -rect.minX, y: -rect.minY)
        box.addSubview(view)
        return box
    }

    static func make(_ n: [String: String], size: NSSize) throws -> NSView {
        switch n["kind"] {
        case "header", "filters":
            let page = WorkflowsPageView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
            page.onOpenDefinitions = {}
            if n["workflow"] == "triage" { page.pickedTab = .all; page.workflow = "triage" }
            page.content = .runs(snapshot)
            page.rebuild()
            page.layoutSubtreeIfNeeded()
            return cut(page, NSRect(x: 0, y: n["kind"] == "header" ? 0 : 52, width: size.width, height: size.height))
        case "row":
            let node = try #require(nodes[n["row"]!])
            let chip = WorkflowRuns.chip(node.run.workflow)
            #expect(chip.letters == n["letters"] && "\(chip.tone)" == n["tone"])
            #expect(WorkflowRuns.now(node) == n["now"] && WorkflowRuns.state(node).word == n["word"])
            #expect(TimestampFormat.formatRelativeTimeLabel(node.run.updatedAt, nowMs: now) == n["time"])
            let r = WorkflowRunRowView(frame: NSRect(origin: .zero, size: size))
            r.set(node, current: n["current"] == "true", nowMs: now)
            return r
        case "feedHeader":
            let feed = WorkflowRunFeedView(frame: NSRect(x: 0, y: 0, width: size.width, height: 400))
            feed.set(node: nodes[n["run"]!], parent: nil, detail: nil, error: nil, notHere: false, nowMs: now)
            feed.frame.size.height = feed.height(forWidth: size.width)
            feed.layoutSubtreeIfNeeded()
            return cut(feed, NSRect(origin: .zero, size: size))
        case "question":
            let card = WorkflowQuestionCardView(frame: NSRect(origin: .zero, size: size))
            card.set(question("needs"), reason: nil, canAnswer: true, nowMs: now)
            if n["reason"] == "true" { card.choose(WorkflowRuns.read(question("needs")).choices[1]) }
            card.frame.size.height = card.height(forWidth: size.width)
            return card
        default:
            throw Skip()
        }
    }

    struct Skip: Error {}

    @Test func workflows() throws {
        let repo = SidebarFidelityTests.repo
        let refDir = repo.appendingPathComponent("design/component-reference/workflows")
        let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: repo.appendingPathComponent("design/component-reference/workflows.json"))) as! [String: Any]
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: refDir.appendingPathComponent("manifest.json"))) as! [String: [String: Double]]
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        var lines: [(String, Double)] = [], images = ""
        for c in spec["cases"] as! [[String: Any]] {
            let name = c["name"] as! String, native = c["native"] as! [String: String]
            let css = manifest[name]!
            let size = NSSize(width: css["width"]!, height: css["height"]!)
            for theme in spec["themes"] as! [String] {
                let base = "\(name).rest.\(theme)"
                let ref = try #require(NSBitmapImageRep(data: Data(contentsOf: refDir.appendingPathComponent("\(base).png"))))
                let canvas = ConnectionsFidelityTests.Canvas(frame: .zero)
                guard let view = try? Self.make(native, size: size) else { continue }
                view.frame.origin = NSPoint(x: 8, y: 8)
                canvas.addSubview(view)
                let ours = Snapshot.image(of: canvas, size: NSSize(width: CGFloat(ref.pixelsWide) / 2, height: CGFloat(ref.pixelsHigh) / 2),
                                          scale: 2, dark: theme == "dark")
                let (total, _, diff) = SidebarFidelityTests.compare(ref, ours, bands: [])
                try ref.representation(using: .png, properties: [:])!.write(to: Self.out.appendingPathComponent("\(base).ref.png"))
                try Snapshot.writePNG(ours, to: Self.out.appendingPathComponent("\(base).ours.png"))
                try Snapshot.writePNG(diff, to: Self.out.appendingPathComponent("\(base).diff.png"))
                lines.append((base, total))
                images += "<p>\(base): \(String(format: "%.2f", total * 100))%<br>"
                    + ["ref", "ours", "diff"].map { "<img style='zoom:.5' src='workflows/\(base).\($0).png'>" }.joined() + "</p>"
            }
        }
        for (base, total) in lines.sorted(by: { $0.1 > $1.1 }) { print("workflows", base, String(format: "%.2f%%", total * 100)) }
        let html = "<!doctype html><meta charset=utf-8><title>Workflows</title><body style='font:13px -apple-system'>" + images
        try html.write(to: Self.out.deletingLastPathComponent().appendingPathComponent("report-workflows.html"), atomically: true, encoding: .utf8)
        Self.ceilings.check("workflows", lines)
        let mean = lines.map(\.1).reduce(0, +) / Double(max(1, lines.count))
        print(String(format: "FIDELITY workflows: %d cases, mean differing %.2f%%", lines.count, mean * 100))
        #expect(mean < 0.08)
    }
}
