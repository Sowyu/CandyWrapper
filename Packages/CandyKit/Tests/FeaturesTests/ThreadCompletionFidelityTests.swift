import AppKit
import Testing
import T3Protocol
import DesignSystem
import T3Store
@testable import Features

@MainActor @Suite(.fidelity)
struct ThreadCompletionFidelityTests {
    /// Per-case ceilings, measured 2026-10-22 plus margin (FidelitySupport.swift).
    static let ceilings: FidelityCeilings = [
        "threadCompletionControls": .init(0.06),
    ]
    @Test func threadCompletionControls() throws {
        let repo = SidebarFidelityTests.repo
        let dir = repo.appendingPathComponent("design/component-reference/thread-completion")
        let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: repo.appendingPathComponent("design/component-reference/thread-completion.json"))) as! [String: Any]
        let out = Fidelity.root.appendingPathComponent("wp710c")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var differences: [(String, Double)] = []
        for c in spec["cases"] as! [[String: Any]] {
            let name = c["name"] as! String, n = c["native"] as! [String: Any]
            for theme in ["light", "dark"] {
                let ref = try #require(NSBitmapImageRep(data: Data(contentsOf: dir.appendingPathComponent("\(name).rest.\(theme).png"))))
                let canvas = SidebarSearchFidelityTests.Canvas(frame: .zero)
                let view: NSView
                switch n["kind"] as! String {
                case "minimap":
                    let map = ThreadMinimapView(frame: NSRect(x: 8, y: 8, width: 40, height: 42))
                    map.items = (0..<6).map { ThreadMinimapItem(id: String($0), rowIndex: $0, userText: "Message") }
                    map.currentIndex = n["current"] as? Int
                    map.inView = (n["current"] as? Int).map { IndexSet(integer: $0) } ?? []
                    view = map
                case "tasks":
                    let tasks = ThreadTasksView()
                    let count = n["count"] as! Int, complete = n["complete"] as! Int
                    tasks.steps = (0..<count).map { i in ThreadTaskStep(text: complete == count ? "Finish" : "Build", status: i < complete ? "completed" : i == complete ? "running" : "pending") }
                    tasks.frame = NSRect(x: 8, y: 8, width: 600, height: 51)
                    view = tasks
                default:
                    let inspector = WorkDetailView()
                    var detail = WorkDetail([("Sources/Chat.swift", .output)])
                    if n["failed"] as? Bool == true { detail.mono("Patch did not apply", .error) }
                    detail.blocks.append(.init(text: "", kind: .caption, gap: 6, action: .openDiff(RunId("r"), "Sources/Chat.swift")))
                    inspector.detail = detail
                    inspector.frame = NSRect(x: 8, y: 8, width: 320, height: inspector.height(forWidth: 320))
                    view = inspector
                }
                canvas.addSubview(view)
                let ours = Snapshot.image(of: canvas, size: NSSize(width: CGFloat(ref.pixelsWide) / 2, height: CGFloat(ref.pixelsHigh) / 2), scale: 2, dark: theme == "dark")
                let (difference, _, diff) = SidebarFidelityTests.compare(ref, ours, bands: [])
                differences.append(("\(name).\(theme)", difference))
                try Snapshot.writePNG(ours, to: out.appendingPathComponent("\(name).\(theme).png"))
                try Snapshot.writePNG(diff, to: out.appendingPathComponent("\(name).\(theme).diff.png"))
                print("thread-completion \(name).\(theme): \(String(format: "%.2f", difference * 100))%")
            }
        }
        Self.ceilings.check("threadCompletionControls", differences)
        let mean = differences.map(\.1).reduce(0, +) / Double(differences.count)
        print("FIDELITY thread-completion: \(differences.count) cases, mean \(String(format: "%.2f", mean * 100))%, worst \(String(format: "%.2f", (differences.map(\.1).max() ?? 0) * 100))%")
        #expect(mean < 0.05)
    }
}
