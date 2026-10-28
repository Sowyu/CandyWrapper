import AppKit
import Testing
import DesignSystem
@testable import Features

/// The composer notices in every variant and the banner stack, collapsed with its peek and expanded,
/// against T3's markup in Chromium (spec from scripts/gen-banner-stack-spec.py, references in
/// design/component-reference/banner-stack). Offscreen snapshots draw no shadows, so the peek's
/// `shadow-md` is the one known difference. Writes ref, ours and diff PNGs plus report-banner-stack.html
/// to `Fidelity.root`.
@MainActor @Suite(.fidelity)
struct BannerStackFidelityTests {
    /// Per-case ceilings, measured 2026-10-22 plus margin (FidelitySupport.swift).
    static let ceilings: FidelityCeilings = [
        "bannerStack": .init(0.06),
    ]
    static let out = Fidelity.root.appendingPathComponent("banner-stack")

    static func notice(_ content: ComposerNoticeBannerView.Content) -> ComposerNoticeBannerView {
        let v = ComposerNoticeBannerView()
        v.apply(content)
        return v
    }
    static var goal: ComposerNoticeBannerView {
        notice(.init(variant: .neutral, icon: .target, title: "Goal · 12k tokens", description: "Ship the stack port with motion", actions: ["Clear"], priority: .activity))
    }
    static var recovery: ComposerNoticeBannerView {
        notice(.init(variant: .warning, icon: .gauge, title: "Usage limit reached", description: "Resets 10/12/2026, 5:00 PM",
                     actions: ["Resume at reset", "Snooze until reset"]))
    }
    static var environment: EnvironmentBannerView {
        let e = EnvironmentBannerView()
        e.text = "Local is reconnecting"
        e.showsReconnect = false
        return e
    }
    static var update: ComposerNoticeBannerView {
        notice(.init(variant: .neutral, icon: .info, title: "Server update available", description: "Restart the server to update",
                     dismissLabel: "Dismiss update notice"))
    }

    static func item(_ id: String, _ view: ComposerBannerView, _ priority: ComposerBannerStackItem.Priority? = nil) -> ComposerBannerStackItem {
        ComposerBannerStackItem(id: id, view: view, priority: priority, height: { _ in 51 }, onDismiss: {})
    }

    /// A column as ThreadPanelView lays it out: the stack view, then the front item attached under it.
    /// The references predate 09b464cf83, which put urgent notices before activity, so the column keeps
    /// the given order; `orderAndDismiss` checks the sort.
    static func stack(_ items: [ComposerBannerStackItem], expanded: Bool, width: CGFloat) -> NSView {
        let ordered = items
        let stack = ComposerBannerStackView()
        stack.update(ordered)
        let column = DSView()
        column.addSubview(ordered[0].view)
        column.addSubview(stack)
        let h = expanded ? stack.expandedHeight(width: width) : ComposerBannerStackView.peekHeight
        stack.frame = NSRect(x: 0, y: 0, width: width, height: h)
        if expanded { stack.setExpanded(true) }
        stack.frame = NSRect(x: 0, y: 0, width: width, height: stack.height(width: width))
        ordered[0].view.frame = NSRect(x: 0, y: stack.frame.maxY, width: width, height: 51)
        column.frame = NSRect(x: 0, y: 0, width: width, height: stack.frame.maxY + 51)
        column.layoutSubtreeIfNeeded()
        return column
    }

    static func make(_ kind: String, size: NSSize) -> NSView {
        let view: NSView
        switch kind {
        case "goal": view = goal
        case "recovery": view = recovery
        case "environment": view = environment
        case "offline":
            let e = EnvironmentBannerView()
            e.text = "Remote is offline"
            e.isError = true
            e.showsDisconnect = true
            view = e
        case "clone":
            view = notice(.init(variant: .error, icon: .download, title: "Failed to clone demo-repo", description: "Repository not found.",
                                actions: ["Remove project", "Retry"], compact: true))
        case "notice": view = update
        case "floating":
            let r = recovery
            r.placement = .attached
            view = r
        case "stack":
            return stack([item("goal", goal, .activity), item("recovery", recovery, .urgent), item("environment", environment)], expanded: false, width: size.width)
        case "stack-neutral":
            return stack([item("recovery", recovery, .urgent), item("update", update, .notice)], expanded: false, width: size.width)
        default:
            return stack([item("goal", goal, .activity), item("recovery", recovery, .urgent), item("environment", environment)], expanded: true, width: size.width)
        }
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        return view
    }

    @Test func bannerStack() throws {
        let repo = SidebarFidelityTests.repo
        let refDir = repo.appendingPathComponent("design/component-reference/banner-stack")
        let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: repo.appendingPathComponent("design/component-reference/banner-stack.json"))) as! [String: Any]
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
                let view = Self.make(native["kind"]!, size: size)
                #expect(abs(view.frame.height - size.height) < 0.5, "\(name): \(view.frame.height) tall, T3 \(size.height)")
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
                    + ["ref", "ours", "diff"].map { "<img style='zoom:.5' src='banner-stack/\(base).\($0).png'>" }.joined() + "</p>"
                #expect(total < 0.06, "\(base): \(String(format: "%.2f", total * 100))% differ")
            }
        }
        for (base, total) in lines.sorted(by: { $0.1 > $1.1 }) { print("banner-stack", base, String(format: "%.2f%%", total * 100)) }
        Self.ceilings.check("bannerStack", lines)
        let mean = lines.map(\.1).reduce(0, +) / Double(max(1, lines.count))
        print(String(format: "FIDELITY banner-stack: %d cases, mean differing %.2f%%", lines.count, mean * 100))
        let html = "<!doctype html><meta charset=utf-8><title>Banner stack</title><body style='font:13px -apple-system'>" + images
        try html.write(to: Self.out.deletingLastPathComponent().appendingPathComponent("report-banner-stack.html"), atomically: true, encoding: .utf8)
    }

    /// `bannerPriority` and the stable sort: urgent, error and warning first, then activity, then the rest,
    /// each in producer order.
    @Test func orderAndDismiss() async throws {
        let notice = Self.update, warn = Self.recovery, env = Self.environment, goal = Self.goal
        var dismissed: [String] = []
        let items = [
            ComposerBannerStackItem(id: "notice", view: notice, priority: .notice, height: { _ in 51 }, onDismiss: { dismissed.append("notice") }),
            ComposerBannerStackItem(id: "recovery", view: warn, height: { _ in 51 }),
            ComposerBannerStackItem(id: "env", view: env, height: { _ in 51 }),
            ComposerBannerStackItem(id: "goal", view: goal, priority: .activity, height: { _ in 51 }),
        ]
        let ordered = ComposerBannerStackItem.ordered(items)
        #expect(ordered.map(\.id) == ["recovery", "env", "goal", "notice"])
        let stack = ComposerBannerStackView()
        stack.update(ordered)
        #expect(stack.hasStack)
        #expect(stack.peek.variant == .warning)
        #expect(stack.expandedHeight(width: 600) == CGFloat(102)) // three 34pt cards, two gaps, `pb-2`
        // Only items with an X leave, one at a time.
        stack.requestDismiss("recovery")
        #expect(stack.exitingId == nil)
        stack.requestDismiss("notice")
        #expect(stack.exitingId == "notice")
        #expect(notice.dismissControl?.isEnabled == false)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(dismissed == ["notice"])
        stack.update(Array(ordered.dropLast()))
        #expect(stack.exitingId == nil)
        #expect(notice.dismissControl?.isEnabled == true)
        // One item left: no stack, and it closes.
        stack.update([ordered[0]])
        #expect(!stack.hasStack && !stack.expanded && stack.isHidden)
    }

    /// Accepted dismissals settle even when a thread switch removes the old animation.
    @Test func dismissKeptOrLeft() async throws {
        let notice = Self.update, goal = Self.goal
        var dismissed = 0
        let kept = [
            ComposerBannerStackItem(id: "goal", view: goal, priority: .activity, height: { _ in 51 }),
            ComposerBannerStackItem(id: "notice:a", view: notice, priority: .notice, height: { _ in 51 }, onDismiss: { dismissed += 1 }),
        ]
        let stack = ComposerBannerStackView()
        stack.update(kept)
        stack.requestDismiss("notice:a")
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(dismissed == 1)
        stack.update(kept)
        #expect(stack.exitingId == nil)
        #expect(notice.dismissControl?.isEnabled == true)
        // The next dismiss is not refused.
        stack.requestDismiss("notice:a")
        #expect(stack.exitingId == "notice:a")
        // The thread switches while the old accepted dismissal still waits.
        var other = kept
        other[1] = ComposerBannerStackItem(id: "notice:b", view: notice, priority: .notice, height: { _ in 51 }, onDismiss: { dismissed += 10 })
        stack.update(other)
        #expect(stack.exitingId == nil)
        stack.requestDismiss("notice:b")
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(dismissed == 12)
    }

    /// `resolveContextStripLabelsCompact` with its 16pt hysteresis.
    @Test func contextStripCompact() {
        #expect(!ComposerContextStripView.compact(was: false, needed: 300, available: 300))
        #expect(ComposerContextStripView.compact(was: false, needed: 301, available: 300))
        #expect(ComposerContextStripView.compact(was: true, needed: 290, available: 300))
        #expect(!ComposerContextStripView.compact(was: true, needed: 284, available: 300))
        let strip = ComposerContextStripView(frame: NSRect(x: 0, y: 0, width: 692, height: ComposerContextStripView.height))
        strip.showsGitControls = true
        strip.runContext.text = "Current checkout"
        strip.branch.text = "feature/a-really-long-branch-name-that-keeps-going-and-going-past-the-label-cap"
        strip.layoutSubtreeIfNeeded()
        #expect(!strip.labelsCompact)
        strip.frame.size.width = 300
        strip.layoutSubtreeIfNeeded()
        #expect(strip.labelsCompact)
        #expect(strip.branch.intrinsicContentSize.width < 60)
        strip.frame.size.width = 692
        strip.layoutSubtreeIfNeeded()
        #expect(!strip.labelsCompact)
    }
}
