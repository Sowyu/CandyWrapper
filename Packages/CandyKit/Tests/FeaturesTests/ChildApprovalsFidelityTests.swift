import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// Child approvals in the parent thread (#28516) against `design/component-reference/child-approvals`
/// (scripts/gen-child-approvals-spec.py, ChildThreadApprovals.tsx at 4928).
@MainActor @Suite(.fidelity)
struct ChildApprovalsFidelityTests {
    static let ceilings: FidelityCeilings = [
        "childApprovals": .init(0.035), // measured 2026-11-19: 1.78 to 2.74%, text edges and corners
    ]

    @Test func childApprovals() throws {
        let repo = SidebarFidelityTests.repo
        let refDir = repo.appendingPathComponent("design/component-reference/child-approvals")
        let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: repo.appendingPathComponent("design/component-reference/child-approvals.json"))) as! [String: Any]
        let out = Fidelity.root.appendingPathComponent("child-approvals")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var differences: [(String, Double)] = []
        for c in spec["cases"] as! [[String: Any]] {
            let name = c["name"] as! String
            let cards = (c["native"] as! [String: Any])["cards"] as! [[String: Any]]
            let entries = cards.enumerated().map { index, card in
                ChildApproval(threadId: ThreadId("env:child-\(index)"), title: card["title"] as! String, approval: PendingApproval(
                    requestId: "r\(index)", requestKind: .command, detail: card["detail"] as? String,
                    canRespond: card["live"] as? Bool ?? true, reason: card["reason"] as? String))
            }
            for theme in ["light", "dark"] {
                let ref = try #require(NSBitmapImageRep(data: Data(contentsOf: refDir.appendingPathComponent("\(name).rest.\(theme).png"))))
                let canvas = SidebarSearchFidelityTests.Canvas(frame: .zero)
                let view = ChildApprovalsView(frame: .zero)
                view.set(entries)
                view.frame = NSRect(x: 8, y: 8, width: 480, height: view.height(forWidth: 480))
                canvas.addSubview(view)
                let ours = Snapshot.image(of: canvas, size: NSSize(width: CGFloat(ref.pixelsWide) / 2, height: CGFloat(ref.pixelsHigh) / 2), scale: 2, dark: theme == "dark")
                let (difference, _, diff) = SidebarFidelityTests.compare(ref, ours, bands: [])
                differences.append(("\(name).\(theme)", difference))
                try Snapshot.writePNG(ours, to: out.appendingPathComponent("\(name).\(theme).png"))
                try Snapshot.writePNG(diff, to: out.appendingPathComponent("\(name).\(theme).diff.png"))
                print("child-approvals \(name).\(theme): \(String(format: "%.2f", difference * 100))%")
            }
        }
        Self.ceilings.check("childApprovals", differences)
    }
}
