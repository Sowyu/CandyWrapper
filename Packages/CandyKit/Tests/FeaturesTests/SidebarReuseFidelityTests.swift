import AppKit
import Testing
import DesignSystem
import T3Store
@testable import Features

/// Reuse must return to the existing rest state, including child action buttons.
/// T3 Sidebar.tsx:1582-1593 derives the surface from current pointer state.
@MainActor @Suite(.fidelity)
struct SidebarReuseFidelityTests {
    @Test func recycledRowMatchesFreshRestState() throws {
        let items = SidebarListBuilder.items(snapshot: SidebarPreview.richSnapshot(), state: SidebarListState(),
                                             nowMs: TimestampFormat.nowMs(SidebarPreview.referenceNow))
        let model = try #require(items.compactMap { if case .row(let r) = $0 { r } else { nil } }.first)
        for dark in [false, true] {
            for slim in [false, true] {
                let fresh: SidebarRowBase = slim ? SidebarSlimRowView() : SidebarCardRowView()
                let reused: SidebarRowBase = slim ? SidebarSlimRowView() : SidebarCardRowView()
                fresh.configure(.row(model))
                reused.configure(.row(model))
                var hot = reused.state
                hot.hovered = true; hot.active = true
                reused.previewState(hot)
                if let card = reused as? SidebarCardRowView { card.pin.previewState(hot) }
                reused.prepareForReuse()
                reused.configure(.row(model))
                let size = NSSize(width: 240, height: slim ? 36 : 83)
                let expected = Snapshot.image(of: fresh, size: size, scale: 2, dark: dark)
                let actual = Snapshot.image(of: reused, size: size, scale: 2, dark: dark)
                let (difference, _, _) = SidebarFidelityTests.compare(expected, actual, bands: [])
                #expect(difference == 0)
                print("FIDELITY sidebar-reuse \(dark ? "dark" : "light") \(slim ? "slim" : "card"): \(difference * 100)%")
            }
        }
    }
}
