import AppKit
import Testing
import DesignSystem
@testable import Features

/// The thread notification toasts and the hold-to-quit overlay against T3's markup in Chromium (specs from
/// scripts/gen-notifications-spec.py, references in design/component-reference/{thread-toast,quit-hold-overlay}).
/// Writes ref, ours and diff PNGs plus report-notifications.html to `Fidelity.root`.
@MainActor @Suite(.fidelity)
struct NotificationsFidelityTests {
    /// Per-case ceilings, measured 2026-10-22 plus margin (FidelitySupport.swift).
    static let ceilings: FidelityCeilings = [
        "notifications": .init(0.05),
    ]
    static let out = Fidelity.root.appendingPathComponent("notifications")

    static func view(_ component: String, _ n: [String: String]) -> NSView {
        if component == "quit-hold-overlay" {
            let v = QuitHoldOverlayView()
            v.show(n["mode"] == "hold" ? .hold : .doubleClick)
            v.place(in: NSRect(x: 0, y: 0, width: 0, height: 0), flipped: true)
            v.frame.origin = NSPoint(x: 8, y: 8)
            return v
        }
        let icon: IconName = switch n["icon"] {
        case "circleCheck": .circleCheck
        case "shieldQuestion": .shieldQuestion
        case "circleAlert": .circleAlert
        default: .messageCircleQuestion
        }
        let color: NSColor = switch n["color"] {
        case "successForeground": Themed.color(\.successForeground)
        case "warningForeground": Themed.color(\.warningForeground)
        case "destructiveForeground": Themed.color(\.destructiveForeground)
        default: Themed.color(\.infoForeground)
        }
        let v = ToastView(title: n["title"]!, message: n["description"], kind: ToastQueue.Kind(rawValue: n["kind"]!)!,
                          actionTitle: n["action"], leadingIcon: (icon, color))
        v.frame = NSRect(x: 8, y: 8, width: 360, height: v.height(forWidth: 360))
        return v
    }

    @Test func notifications() throws {
        let repo = SidebarFidelityTests.repo
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        var lines: [(String, Double)] = [], images = ""
        for component in ["thread-toast", "quit-hold-overlay"] {
            let refDir = repo.appendingPathComponent("design/component-reference/\(component)")
            let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: repo.appendingPathComponent("design/component-reference/\(component).json"))) as! [String: Any]
            for c in spec["cases"] as! [[String: Any]] {
                let name = c["name"] as! String, native = c["native"] as! [String: String]
                for theme in spec["themes"] as! [String] {
                    let base = "\(component).\(name).\(theme)"
                    let ref = try #require(NSBitmapImageRep(data: Data(contentsOf: refDir.appendingPathComponent("\(name).rest.\(theme).png"))))
                    let canvas = SidebarSearchFidelityTests.Canvas(frame: .zero)
                    canvas.addSubview(Self.view(component, native))
                    let ours = Snapshot.image(of: canvas, size: NSSize(width: CGFloat(ref.pixelsWide) / 2, height: CGFloat(ref.pixelsHigh) / 2),
                                              scale: 2, dark: theme == "dark")
                    let (total, _, diff) = SidebarFidelityTests.compare(ref, ours, bands: [])
                    try ref.representation(using: .png, properties: [:])!.write(to: Self.out.appendingPathComponent("\(base).ref.png"))
                    try Snapshot.writePNG(ours, to: Self.out.appendingPathComponent("\(base).ours.png"))
                    try Snapshot.writePNG(diff, to: Self.out.appendingPathComponent("\(base).diff.png"))
                    lines.append((base, total))
                    images += "<p>\(base): \(String(format: "%.2f", total * 100))%<br>"
                        + ["ref", "ours", "diff"].map { "<img style='zoom:.5' src='notifications/\(base).\($0).png'>" }.joined() + "</p>"
                }
            }
        }
        for (base, total) in lines.sorted(by: { $0.1 > $1.1 }) { print("notifications", base, String(format: "%.2f%%", total * 100)) }
        Self.ceilings.check("notifications", lines)
        let mean = lines.map(\.1).reduce(0, +) / Double(max(1, lines.count))
        print(String(format: "FIDELITY notifications: %d cases, mean differing %.2f%%", lines.count, mean * 100))
        let html = "<!doctype html><meta charset=utf-8><title>Notifications</title><body style='font:13px -apple-system'>" + images
        try html.write(to: Self.out.deletingLastPathComponent().appendingPathComponent("report-notifications.html"), atomically: true, encoding: .utf8)
        #expect(mean < 0.05)
    }
}
