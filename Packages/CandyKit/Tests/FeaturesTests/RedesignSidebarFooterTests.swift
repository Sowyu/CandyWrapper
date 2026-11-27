import AppKit
import QuartzCore
import Testing
@testable import DesignSystem
@testable import Features

/// Round-0 review fixes on Redesign's sidebar footer, shelves and the two thread panels that popped.
@MainActor
struct RedesignSidebarFooterTests {
    private func withRedesign(_ body: () throws -> Void) rethrows {
        let previous = ThemeRuntime.input
        Motion.reducedOverride = false
        defer { ThemeRuntime.apply(previous); Motion.reducedOverride = nil }
        var input = ThemeRuntimeInput(light: ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .light)!),
                                      dark: ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .dark)!))
        input.ditherLight = true; input.ditherDark = true
        ThemeRuntime.apply(input)
        try body()
    }

    /// S3: a failed pass was a red-ringed box in the account card. Now it is a line of the card: no fill, no ring,
    /// the status color on the glyph and on "failed" only.
    @Test func failedCapsuleIsAQuietLine() {
        withRedesign {
            let pill = SidebarUpdatePillView(frame: NSRect(x: 0, y: 0, width: 220, height: 28))
            pill.capsule = SidebarUpdateCapsule(view: .init(tone: .failed, label: "studio failed", action: .retry), countdown: nil,
                                                popover: .init(local: nil, rows: [], showsDismiss: false))
            pill.layoutSubtreeIfNeeded()
            pill.restyle()
            #expect(pill.capsuleFill.fillColor == nil && pill.capsuleRing.isHidden)
            #expect(!pill.capsuleFailedGlyph.isHidden && pill.capsuleSlowGlyph.isHidden)
            #expect(pill.capsuleLabel.frame.minX >= pill.capsuleFailedGlyph.frame.maxX)
            #expect(pill.capsuleLabel.prefixColor?.count == "studio ".utf16.count)
        }
    }

    /// S3: Working and Settled read like the "Threads" label: the sidebar palette's muted color, which Blur keeps
    /// readable, at 400.
    @Test func shelfHeaderUsesTheSidebarMutedColor() {
        withRedesign {
            let header = CollapsibleSectionHeaderView("Working")
            header.dithersRule = true
            header.frame = NSRect(x: 0, y: 0, width: 240, height: 32)
            header.layoutSubtreeIfNeeded()
            let label = header.subviews.compactMap { $0 as? LabelView }.first
            #expect(label?.color == Themed.color(\.sidebarMutedForeground, sidebar: true))
            #expect(label?.font == DSFont.ui(12))
            #expect(label?.frame.minX == 7)
        }
    }

    /// X5: the details dropdown dropped in at once; it now enters and leaves on `RedesignMotion.panel`.
    @Test func detailsDropdownSlidesInAndLeavesAsAStill() throws {
        try withRedesign {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.contentView = nil; window.close() }
            let panel = ThreadPanelView(frame: NSRect(x: 0, y: 0, width: 1400, height: 800))
            window.contentView = panel
            panel.layoutSubtreeIfNeeded()
            panel.setDetailsOpen(true)
            let layer = try #require(panel.detailsCard.layer)
            #expect((layer.animationKeys() ?? []).contains("redesign.panel.y"), "\(layer.animationKeys() ?? [])")
            #expect(CATransform3DIsIdentity(layer.transform) && layer.opacity == 1)
            layer.removeAllAnimations()
            panel.layoutSubtreeIfNeeded()
            #expect(panel.detailsCard.frame.width > 0)
            panel.setDetailsOpen(false)
            #expect(panel.detailsCard.isHidden)
            let stills = (panel.layer?.sublayers ?? []).filter { ($0.animationKeys() ?? []).contains("redesign.panel.y") }
            #expect(stills.count == 1)
        }
    }
}
