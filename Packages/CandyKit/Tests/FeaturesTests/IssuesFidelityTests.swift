import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// The Issues page against T3 4928's own screen (design/reference-4928/58-issues-page): the
/// sandbox has no tracker, so the page shows "No trackers to read" under the search, Sort,
/// Filters, Views and refresh. The 1100 × 780 capture is cropped to the route, right of the
/// 256pt sidebar. Writes ref, ours and diff PNGs to `Fidelity.root/issues`.
@MainActor @Suite(.fidelity)
struct IssuesFidelityTests {
    /// Measured 2026-11-19 plus margin.
    static let ceilings: FidelityCeilings = [
        "issuesPage": .init(0.025),
    ]

    static func page(dark: Bool) -> NSView {
        let container = IssuesPageContainer()
        container.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        var m = IssuesPageView.Model()
        m.body = .noTrackers
        m.hostOptions = [IssueListLogic.HostOption(value: "", label: "All", tracker: nil, unavailable: nil)]
        container.page.model = m
        // The route starts right of the 256pt sidebar, which also keeps the header's title at its 20pt gutter.
        let host = BackgroundHost(frame: NSRect(x: 0, y: 0, width: 1100, height: 780))
        host.appearance = container.appearance
        container.frame = NSRect(x: 256, y: 0, width: 844, height: 780)
        host.addSubview(container)
        host.layoutSubtreeIfNeeded()
        return host
    }

    /// The app's main area paints `bg-background` behind every route.
    final class BackgroundHost: DSView {
        override func updateLayer() { layer?.backgroundColor = Themed.color(\.background).cgColor(in: self) }
    }

    @Test func issuesPage() throws {
        let previous = FontRuntime.input
        defer { FontRuntime.apply(previous) }
        var fonts = FontRuntimeInput()
        fonts.smoothing = false
        FontRuntime.apply(fonts)
        // Saved views live in the defaults; the capture has none.
        let saved = UserDefaults.standard.data(forKey: SavedViewsKind.issues.storageKey)
        UserDefaults.standard.removeObject(forKey: SavedViewsKind.issues.storageKey)
        defer { if let saved { UserDefaults.standard.set(saved, forKey: SavedViewsKind.issues.storageKey) } }
        var scores: [(String, Double)] = []
        let out = Fidelity.root.appendingPathComponent("issues")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for dark in [false, true] {
            let base = "58-issues-page.\(dark ? "dark" : "light")"
            let full = try #require(NSBitmapImageRep(data: Data(contentsOf: SidebarFidelityTests.repo
                .appendingPathComponent("design/reference-4928/\(base).png"))))
            let ref = ThreadFidelityTests.crop(full, x: 512, width: 1688, height: 1560)
            let ours = ThreadFidelityTests.crop(Snapshot.image(of: Self.page(dark: dark), size: NSSize(width: 1100, height: 780), scale: 2, dark: dark),
                                                x: 512, width: 1688, height: 1560)
            let (score, _, diff) = SidebarFidelityTests.compare(ref, ours, bands: [])
            try Snapshot.writePNG(ref, to: out.appendingPathComponent(base + ".ref.png"))
            try Snapshot.writePNG(ours, to: out.appendingPathComponent(base + ".ours.png"))
            try Snapshot.writePNG(diff, to: out.appendingPathComponent(base + ".diff.png"))
            scores.append((base, score))
        }
        Self.ceilings.check("issuesPage", scores)
    }
}
