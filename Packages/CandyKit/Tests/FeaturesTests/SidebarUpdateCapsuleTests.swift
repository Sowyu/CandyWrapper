import AppKit
import Testing
import DesignSystem
@testable import Features

@MainActor
private func capsule(_ mode: String, label: String, elapsed: String? = nil) -> SidebarUpdateCapsule {
    typealias V = UpdateEverythingLogic.CapsuleView
    let view: V = switch mode {
    case "slow": V(tone: .slow, label: label, slow: ("downloading", elapsed ?? "4m"), action: nil)
    case "failed": V(tone: .failed, label: label, action: .retry)
    case "countdown": V(tone: .default, label: label, action: .later)
    default: V(tone: .default, label: label, action: nil)
    }
    return SidebarUpdateCapsule(view: view, countdown: mode == "countdown" ? 9 : nil,
                                popover: .init(local: nil, rows: [.init(label: "alvin", status: "failed", failed: true, failure: "Connection lost")],
                                               showsDismiss: false))
}

/// The pill as T3 5258's update capsule (SidebarUpdateCapsule.tsx:126-182).
@MainActor
struct SidebarUpdateCapsuleTests {
    @Test func widthsFollowTheContainerRule() {
        let pill = SidebarUpdatePillView(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
        #expect(pill.capsuleWidth(available: 200, side: 32) == 32)
        pill.capsule = capsule("failed", label: "alvin failed")
        #expect(pill.capsuleWidth(available: 79, side: 32) == 32)
        #expect(pill.capsuleWidth(available: 80, side: 32) == 80)
        pill.capsule = capsule("countdown", label: "Restart in 9s")
        #expect(pill.capsuleWidth(available: 191, side: 32) == 32)
        #expect(pill.capsuleWidth(available: 192, side: 32) == 192)
    }

    @Test func expandedShowsLabelAndActionAndHidesTheIcon() {
        let pill = SidebarUpdatePillView(frame: NSRect(x: 0, y: 0, width: 150, height: 32))
        pill.capsule = capsule("failed", label: "alvin failed")
        var pressed: SidebarUpdateCapsule.Action?
        pill.onCapsuleAction = { pressed = $0 }
        pill.layoutSubtreeIfNeeded()
        #expect(pill.isCapsuleExpanded && !pill.capsuleLabel.isHidden && !pill.capsuleLink.isHidden && pill.iconBox.isHidden)
        pill.capsuleLink.performAction()
        #expect(pressed == .retry)
        pill.setFrameSize(NSSize(width: 32, height: 32))
        pill.layoutSubtreeIfNeeded()
        #expect(!pill.isCapsuleExpanded && pill.capsuleLabel.isHidden && pill.capsuleLink.isHidden && !pill.iconBox.isHidden)
        #expect(pill.accessibilityLabel() == "alvin failed")
        pill.capsule = nil
        pill.layoutSubtreeIfNeeded()
        #expect(pill.capsuleLabel.isHidden && !pill.iconBox.isHidden)
    }

    @Test func countdownReplacesTheIconWithSeconds() {
        let pill = SidebarUpdatePillView(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
        pill.capsule = capsule("countdown", label: "Restart in 9s")
        pill.layoutSubtreeIfNeeded()
        #expect(pill.iconBox.isHidden && !pill.countdownLabel.isHidden && pill.countdownLabel.text == "9s")
    }

    @Test func popoverListsTheMachines() {
        let view = SidebarUpdateCapsulePopoverView()
        var c = capsule("failed", label: "alvin failed")
        c.popover.local = .restartToUpdate
        c.popover.showsDismiss = true
        view.configure(c)
        #expect(view.texts == ["This app", "Restart to update", "alvin", "failed", "Dismiss", "Retry"])
        #expect(view.intrinsicContentSize.height > 60)
    }

    /// The sidebar gives the capsule the utility row's free width beside its four buttons.
    @Test func sidebarFooterSizesTheCapsule() {
        let sidebar = SidebarContentView(frame: NSRect(x: 0, y: 0, width: 300, height: 600))
        sidebar.updatePill.capsule = capsule("failed", label: "alvin failed")
        sidebar.layoutSubtreeIfNeeded()
        let pill = sidebar.updatePill.frame
        #expect(pill.maxX == 292 && pill.width > 80)
    }
}

/// The capsule against T3 5258's markup (scripts/gen-sidebar-update-capsule-spec.py).
@MainActor @Suite(.fidelity)
struct SidebarUpdateCapsuleFidelityTests {
    /// Per-case ceilings, set 2026-11-25 in line with SidebarFooterFidelityTests.
    static let ceilings: FidelityCeilings = [
        "sidebarUpdateCapsule": .init(0.06),
    ]

    @Test func capsuleCases() throws {
        let repo = SidebarFidelityTests.repo
        let refDir = repo.appendingPathComponent("design/component-reference/sidebar-update-capsule")
        let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: repo.appendingPathComponent("design/component-reference/sidebar-update-capsule.json"))) as! [String: Any]
        let out = Fidelity.root.appendingPathComponent("sidebar-update-capsule")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var lines: [(String, Double)] = []
        for c in spec["cases"] as! [[String: Any]] {
            let name = c["name"] as! String, native = c["native"] as! [String: String]
            for theme in spec["themes"] as! [String] {
                let base = "\(name).rest.\(theme)"
                let ref = try #require(NSBitmapImageRep(data: Data(contentsOf: refDir.appendingPathComponent("\(base).png"))))
                let size = NSSize(width: CGFloat(ref.pixelsWide) / 2, height: CGFloat(ref.pixelsHigh) / 2)
                let canvas = SidebarSearchFidelityTests.SidebarBox(frame: NSRect(origin: .zero, size: size))
                let width = CGFloat(Double(native["width"]!)!)
                let pill = SidebarUpdatePillView(frame: .zero)
                pill.run = ("", false)
                pill.capsule = capsule(native["mode"]!, label: native["label"]!, elapsed: native["elapsed"])
                let pw = pill.capsuleWidth(available: width, side: 32)
                pill.frame = NSRect(x: 8 + width - pw, y: 8, width: pw, height: 32)
                canvas.addSubview(pill)
                canvas.layoutSubtreeIfNeeded()
                let ours = Snapshot.image(of: canvas, size: size, scale: 2, dark: theme == "dark")
                let (total, _, diff) = SidebarFidelityTests.compare(ref, ours, bands: [])
                try Snapshot.writePNG(ours, to: out.appendingPathComponent("\(base).ours.png"))
                try Snapshot.writePNG(diff, to: out.appendingPathComponent("\(base).diff.png"))
                lines.append((base, total))
                print("sidebar-update-capsule \(base): \(String(format: "%.2f", total * 100))%")
            }
        }
        Self.ceilings.check("sidebarUpdateCapsule", lines)
    }
}
