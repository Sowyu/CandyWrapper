import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// Glass Native's thread (docs/glass-native.md): T3 desktop's layout with native material. The native style keeps
/// every classic metric, swaps Lucide for SF Symbols where one means the same, and a style switch keeps the tiling
/// contract. The classic style's pixels are the fidelity suite's job.
@MainActor
struct NativeTimelineTests {
    /// A user message and a work row, both on screen.
    static func sample() throws -> [TimelineItem] {
        let all = try ThreadTimelineTests.manyItems(copies: 1)
        let user = try #require(all.first { if case .message(let m, _, _, _, _, _) = $0.row.kind { m.role == .user && m.text.count > 300 } else { false } })
        let work = try #require(all.first { if case .work(let e, false, _) = $0.row.kind { e.count == 1 } else { false } })
        return [user, work]
    }

    static func layout(_ items: [TimelineItem], style: TimelineStyle) -> TimelineView {
        let t = TimelineView(frame: NSRect(x: 0, y: 0, width: 1200, height: 728))
        t.style = style
        t.layoutSubtreeIfNeeded()
        t.setItems(items)
        t.layoutSubtreeIfNeeded()
        return t
    }

    /// Same column, same bubble, same row heights: only the material differs.
    @Test func nativeKeepsT3DesktopsMetrics() throws {
        let items = try Self.sample()
        let classic = Self.layout(items, style: .classic), native = Self.layout(items, style: .native)
        #expect(native.laneFrame.width == classic.laneFrame.width)
        #expect(native.laneFrame.x == classic.laneFrame.x)
        for item in items {
            let c = try #require(classic.view(forRow: item.id)), n = try #require(native.view(forRow: item.id))
            #expect(n.frame == c.frame, "\(item.id)")
        }
        let user = try #require(native.view(forRow: items[0].id) as? UserMessageRowView)
        #expect(user.bubbleWidth(forWidth: native.laneFrame.width) == native.laneFrame.width * 0.8)
        #expect(native.layoutProblems().isEmpty)
        // Native bubbles keep an edge below the default Glass opacity; classic ones never get one.
        #expect(user.bubbleBorder != nil)
        #expect((classic.view(forRow: items[0].id) as? UserMessageRowView)?.bubbleBorder == nil)
    }

    /// In dark mode the bubble's hairline shows only below the default Glass opacity.
    @Test func theLowOpacityEdgeFollowsTheSlider() {
        let view = NSView()
        view.appearance = NSAppearance(named: .darkAqua)
        let before = ThemeRuntime.glassOpacity
        defer { ThemeRuntime.apply(ThemeRuntimeInput(glassOpacity: Int(before * 100))) }
        ThemeRuntime.apply(ThemeRuntimeInput(glassOpacity: 30))
        #expect(NativeTimeline.lowOpacityEdge.cgColor(in: view).alpha > 0.1)
        ThemeRuntime.apply(ThemeRuntimeInput(glassOpacity: 80))
        #expect(NativeTimeline.lowOpacityEdge.cgColor(in: view).alpha == 0)
        // Light keeps its hairline at every opacity.
        view.appearance = NSAppearance(named: .aqua)
        #expect(abs(NativeTimeline.lowOpacityEdge.cgColor(in: view).alpha - 0.08) < 0.001)
    }

    @Test func nativeWorkRowsUseSFSymbols() throws {
        let items = try Self.sample()
        let native = Self.layout(items, style: .native)
        let line = try #require((native.view(forRow: items[1].id) as? WorkRowView)?.lines.first)
        #expect(line.native)
        #expect(line.frame.height == 24)
        #expect(line.subviews.contains { $0 is SymbolView && !$0.isHidden })
        let classic = Self.layout(items, style: .classic)
        let classicLine = try #require((classic.view(forRow: items[1].id) as? WorkRowView)?.lines.first)
        #expect(!classicLine.native)
        #expect(!classicLine.subviews.contains { $0 is SymbolView && !$0.isHidden })
    }

    @Test func everyCommonWorkIconHasASymbol() {
        for icon: IconName in [.eye, .squarePen, .terminal, .globe, .search, .wrench, .brain, .hammer, .check] {
            let name = NativeTimeline.symbol(icon)
            #expect(name.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) } != nil, "\(icon)")
        }
    }

    /// Switching the style at runtime measures every row again and comes back to the same layout.
    @Test func switchingTheStyleRoundTrips() throws {
        let items = Array(try ThreadTimelineTests.manyItems(copies: 1).prefix(120))
        let t = Self.layout(items, style: .classic)
        t.scrollToEnd(animated: false)
        t.layoutSubtreeIfNeeded()
        let classicHeight = t.documentHeight
        t.style = .native
        t.layoutSubtreeIfNeeded()
        #expect(t.layoutProblems().isEmpty)
        t.style = .classic
        t.layoutSubtreeIfNeeded()
        t.scrollToEnd(animated: false)
        t.layoutSubtreeIfNeeded()
        #expect(t.layoutProblems().isEmpty)
        #expect(abs(t.documentHeight - classicHeight) < 1)
    }

    @Test func thePanelTurnsTheNativeThreadOnAndOff() {
        let panel = ThreadPanelView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        #expect(panel.timeline.style == .classic)
        panel.hidesCustomChrome = true
        #expect(panel.timeline.style == .native)
        #expect(panel.approvalPanel.nativeCard)
        #expect(panel.timeline.scrollView.layer?.mask is CAGradientLayer)
        panel.hidesCustomChrome = false
        #expect(panel.timeline.style == .classic)
        #expect(!panel.approvalPanel.nativeCard)
        #expect(panel.timeline.scrollView.layer?.mask == nil)
    }

    /// The approval keeps T3's labels and order, as native push buttons.
    @Test func approvalButtonsKeepT3sWording() {
        let panel = ApprovalPanelView()
        panel.nativeCard = true
        panel.configure(PendingApproval(requestId: "r", requestKind: .command, detail: "ls"), pendingCount: 1, threadId: "t")
        let titles = panel.subviews.compactMap { ($0 as? NSButton).flatMap { $0.isHidden ? nil : $0.title } }
        #expect(titles == ApprovalOption.defaults.filter { $0.decision == .decline || $0.decision == .accept }.map(\.label))
    }

    @Test func theBreadcrumbFollowsTheHeader() {
        let header = ThreadHeaderView(frame: .zero)
        header.projectTitle = "demo-repo"
        header.threadTitle = "Fix flaky login test"
        let crumb = NativeBreadcrumbView(header: header)
        let texts = { crumb.subviews.compactMap { v -> String? in
            if v.isHidden { return nil }
            if let b = v as? NSButton { return b.title }
            if let t = v as? NSTextField { return t.stringValue }
            if let t = v as? NativeBreadcrumbTitle { return t.text }
            return nil
        } }
        #expect(texts() == ["demo-repo", "/", "Fix flaky login test"])
        crumb.show(page: "Settings")
        #expect(texts() == ["Settings"])
    }
}
