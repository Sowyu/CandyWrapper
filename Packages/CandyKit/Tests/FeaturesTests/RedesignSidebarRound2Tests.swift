import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// Round-2 review fixes on Redesign's sidebar rows.
@MainActor
struct RedesignSidebarRound2Tests {
    private func labels(dither: Bool, environments: [String: String]) -> [String?] {
        var shells = MergedShell()
        shells.set(SidebarMultiMachineTests.machineShell("mini", threads: 3), environmentId: "mini")
        var state = SidebarContentView().state
        state.dither = dither
        state.environments = SidebarEnvironments(primaryId: "mini", labels: environments)
        let items = SidebarListBuilder.items(snapshot: shells.merged(order: ["mini"])!, state: state,
                                             nowMs: TimestampFormat.nowMs(SidebarPreview.referenceNow))
        var out: [String?] = []
        for item in items { if case .row(let r) = item { out.append(r.environmentLabel) } }
        return out
    }

    /// S2: with one environment set up, every Redesign row repeated its name; it shows again once there are two.
    @Test func environmentNameShowsOnlyWithTwoEnvironments() {
        let one = labels(dither: true, environments: ["mini": "78722"])
        #expect(!one.isEmpty && one.allSatisfy { $0 == nil })
        let two = labels(dither: true, environments: ["mini": "78722", "mbp": "MacBook Pro"])
        #expect(!two.isEmpty && two.allSatisfy { $0 == "78722" })
        // The default themes keep T3's label on every row.
        #expect(labels(dither: false, environments: ["mini": "78722"]).allSatisfy { $0 == "78722" })
    }

    /// S4: the selected row's fill is opaque, so a tinted Blur under the sidebar can't turn it brown.
    @Test func selectedFillIsOpaqueUnderRedesign() {
        var r = SidebarRowModel(id: ThreadId("t"), variant: .card, action: .settle, section: .active, title: "t",
                                status: .ready, topStatus: nil, isGoal: false, isUnread: false, isWoke: false, isPinned: false,
                                recedes: false, isActive: true, isRegeneratingTitle: false, timeLabel: "2m", providers: [])
        r.dither = true
        let dark = NSAppearance(named: .darkAqua)!
        var alpha: CGFloat = 0
        dark.performAsCurrentDrawingAppearance {
            alpha = SidebarRowBase.surfaceColor(r, hovered: false)?.cgColor.alpha ?? 0
        }
        #expect(alpha == 1)
    }
}
