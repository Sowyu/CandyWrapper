import AppKit
import Testing
import DesignSystem
import T3Protocol
@testable import Features

/// The T3 Connect tunnel meter and limit alert (4928) against T3's markup in Chromium (spec from
/// scripts/gen-tunnel-usage-spec.py, references in design/component-reference/tunnel-usage).
@MainActor @Suite(.fidelity)
struct TunnelUsageFidelityTests {
    /// Per-case ceilings, measured 2026-11-19 plus margin (FidelitySupport.swift).
    static let ceilings: FidelityCeilings = [
        "tunnelUsage": .init(0.03),
    ]
    static let out = Fidelity.root.appendingPathComponent("tunnel-usage")

    static func make(_ n: [String: String], size: NSSize) -> NSView {
        let view = TunnelUsageView(frame: NSRect(origin: .zero, size: size))
        let used = Int(n["used"]!)!
        view.configure(TunnelUsageState(used: used, limit: Int(n["limit"]!)!, upgrade: TunnelUsageLogic.Upgrade(rawValue: n["upgrade"] ?? ""),
                                        tunnelLimit: n["refused"].flatMap(Int.init), usedAtRefusal: used))
        view.layoutSubtreeIfNeeded()
        return view
    }

    @Test func tunnelUsage() throws {
        let repo = SidebarFidelityTests.repo
        let refDir = repo.appendingPathComponent("design/component-reference/tunnel-usage")
        let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: repo.appendingPathComponent("design/component-reference/tunnel-usage.json"))) as! [String: Any]
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: refDir.appendingPathComponent("manifest.json"))) as! [String: [String: Double]]
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        var lines: [(String, Double)] = []
        for c in spec["cases"] as! [[String: Any]] {
            let name = c["name"] as! String, native = c["native"] as! [String: String]
            let css = manifest[name]!
            let size = NSSize(width: css["width"]!, height: css["height"]!)
            for theme in spec["themes"] as! [String] {
                let base = "\(name).rest.\(theme)"
                let ref = try #require(NSBitmapImageRep(data: Data(contentsOf: refDir.appendingPathComponent("\(base).png"))))
                let canvas = ConnectionsFidelityTests.Canvas(frame: .zero)
                let view = Self.make(native, size: size)
                #expect(abs(TunnelUsageView.height(of: view, width: size.width) - size.height) < 1, "\(base): height")
                view.frame.origin = NSPoint(x: 8, y: 8)
                canvas.addSubview(view)
                let ours = Snapshot.image(of: canvas, size: NSSize(width: CGFloat(ref.pixelsWide) / 2, height: CGFloat(ref.pixelsHigh) / 2),
                                          scale: 2, dark: theme == "dark")
                let (total, _, diff) = SidebarFidelityTests.compare(ref, ours, bands: [])
                try Snapshot.writePNG(ours, to: Self.out.appendingPathComponent("\(base).ours.png"))
                try Snapshot.writePNG(diff, to: Self.out.appendingPathComponent("\(base).diff.png"))
                lines.append((base, total))
            }
        }
        for (base, total) in lines.sorted(by: { $0.1 > $1.1 }) { print("tunnel-usage", base, String(format: "%.2f%%", total * 100)) }
        Self.ceilings.check("tunnelUsage", lines)
    }

    /// `managedTunnelCap` (managedRelayState.ts:154-172) and the alert rule (SavedEnvironmentRows.tsx:511-522).
    @Test func capAndAlertRules() {
        #expect(TunnelUsageLogic.cap(available: true, plan: nil, override: nil) == (3, .link))
        #expect(TunnelUsageLogic.cap(available: true, plan: "free", override: nil) == (3, .pro))
        #expect(TunnelUsageLogic.cap(available: true, plan: "pro", override: nil) == (10, .premier))
        #expect(TunnelUsageLogic.cap(available: true, plan: "premier", override: nil) == (100, nil))
        #expect(TunnelUsageLogic.cap(available: false, plan: nil, override: nil) == (3, nil))
        #expect(TunnelUsageLogic.cap(available: true, plan: "pro", override: 7) == (7, nil))
        #expect(TunnelUsageLogic.used(providerKinds: ["cloudflare_tunnel", "direct", "cloudflare_tunnel"]) == 2)
        // A meter with room doesn't clear the alert; a freed tunnel or a higher cap does.
        #expect(TunnelUsageLogic.showsLimitAlert(tunnelLimit: 3, usedAtRefusal: 3, used: 3, limit: 3))
        #expect(!TunnelUsageLogic.showsLimitAlert(tunnelLimit: 3, usedAtRefusal: 3, used: 2, limit: 3))
        #expect(!TunnelUsageLogic.showsLimitAlert(tunnelLimit: 3, usedAtRefusal: 3, used: 3, limit: 10))
        #expect(!TunnelUsageLogic.showsLimitAlert(tunnelLimit: nil, usedAtRefusal: nil, used: 3, limit: 3))
        #expect(TunnelUsageLogic.meterAction(used: 1, limit: 3, upgrade: .link, alert: false) == "Get more tunnels")
        #expect(TunnelUsageLogic.meterAction(used: 3, limit: 3, upgrade: nil, alert: false) == "Manage tunnels")
        #expect(TunnelUsageLogic.meterAction(used: 3, limit: 3, upgrade: .link, alert: true) == nil)
        #expect(TunnelUsageLogic.meterAction(used: 1, limit: 100, upgrade: nil, alert: false) == nil)
    }
}

extension TunnelUsageView {
    static func height(of view: NSView, width: CGFloat) -> CGFloat { (view as! TunnelUsageView).height(forWidth: width) }
}
