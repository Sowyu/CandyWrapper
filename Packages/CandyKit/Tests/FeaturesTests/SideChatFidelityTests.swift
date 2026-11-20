import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// The side chat tab and its pane's header against T3's 4928 full-window capture of a side chat before its first
/// question (design/reference-4928/62-side-chat-panel, SideChatPane.tsx:131-171, RightPanelTabs.tsx:738-760). The body
/// below the header is the embedded thread panel, covered by the thread's own suites. Coordinates are CSS points.
@MainActor @Suite(.fidelity)
struct SideChatFidelityTests {
    static let ceilings: FidelityCeilings = ["sideChat": .init(0.03)]

    /// The panel's tab bar and the pane's header: the right panel from its `border-l`, cut before the window's panel
    /// controls, which the thread panel draws.
    enum Crop: String, CaseIterable {
        case tab, header
        var rect: CGRect {
            switch self {
            case .tab: CGRect(x: 616, y: 0, width: 200, height: 52)
            case .header: CGRect(x: 616, y: 52, width: 484, height: 36)
            }
        }
    }

    @Test(arguments: Crop.allCases) func sideChatPanel(_ crop: Crop) throws {
        var fonts = FontRuntimeInput()
        fonts.smoothing = false
        FontRuntime.apply(fonts)
        defer { Fidelity.pin() }
        let out = Fidelity.root.appendingPathComponent("side-chat")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var cases: [(String, Double)] = []
        for theme in ["light", "dark"] {
            let rect = crop.rect
            let full = try #require(NSBitmapImageRep(data: Data(contentsOf: SidebarFidelityTests.repo.appendingPathComponent("design/reference-4928/62-side-chat-panel.\(theme).png"))))
            let ref = NSBitmapImageRep(cgImage: full.cgImage!.cropping(to: CGRect(x: rect.minX * 2, y: rect.minY * 2, width: rect.width * 2, height: rect.height * 2))!)
            let canvas = SidebarSearchFidelityTests.Canvas(frame: NSRect(origin: .zero, size: rect.size))
            // The whole panel, 484 wide from the window's right edge, placed so the crop shows.
            let panel = RightPanelView(frame: NSRect(x: 616 - rect.minX, y: -rect.minY, width: 484, height: 780))
            let pane = SideChatPaneView(threadId: "side")
            // Before its first reply Bring back is `aria-disabled` (SideChatPane.tsx:61-68).
            pane.apply(.init(bringBackBlockedReason: "Available after a finished reply."))
            panel.sideChatHost.show(pane)
            panel.apply(RightPanelState(isOpen: true, activeSurfaceId: "side-chat:side", surfaces: [.sideChat("side")]))
            canvas.addSubview(panel)
            canvas.layoutSubtreeIfNeeded()
            let ours = Snapshot.image(of: canvas, size: rect.size, scale: 2, dark: theme == "dark")
            let (share, _, diff) = SidebarFidelityTests.compare(ref, ours, bands: [])
            let base = "\(crop.rawValue).\(theme)"
            for (suffix, image) in [("ref", ref), ("ours", ours), ("diff", diff)] { try Snapshot.writePNG(image, to: out.appendingPathComponent("\(base).\(suffix).png")) }
            cases.append((base, share))
        }
        Self.ceilings.check("sideChat", cases)
    }
}
