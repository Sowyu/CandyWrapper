import AppKit
import Testing
@testable import DesignSystem
@testable import Features

/// Redesign's panel fixes from the round 0 review: one find bar, `+add -del`, the diff's view toggles on one track and
/// the Workflows state's button at its own width.
@MainActor
struct RedesignPanelsPolishTests {
    private func withRedesign(_ body: () throws -> Void) rethrows {
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        var input = ThemeRuntimeInput(light: ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .light)!),
                                      dark: ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .dark)!))
        input.ditherLight = true; input.ditherDark = true
        ThemeRuntime.apply(input)
        try body()
    }

    private static func descendants(of view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }

    @Test func findCountReadsLikeTheThreadFindBar() {
        #expect(DiffFindWidget.compactCount("2 of 5", query: "greet") == "2/5")
        #expect(DiffFindWidget.compactCount("No results", query: "greet") == "0/0")
        #expect(DiffFindWidget.compactCount("No results", query: "") == "")
    }

    @Test func fileStatsPutAdditionsFirstInRedesign() {
        #expect(DiffStatView.pierreItems(additions: 4, deletions: 3, redesign: true).map(\.0) == ["+4", "-3"])
        #expect(DiffStatView.pierreItems(additions: 4, deletions: 3, redesign: false).map(\.0) == ["-3", "+4"])
        #expect(DiffStatView.pierreItems(additions: 0, deletions: 3, redesign: true).map(\.0) == ["-3"])
    }

    @Test func diffViewTogglesShareOneTrack() {
        withRedesign {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            defer { window.contentView = nil; window.close() }
            let diff = DiffPanelView(frame: NSRect(x: 0, y: 0, width: 540, height: 600))
            window.contentView = diff
            diff.layoutSubtreeIfNeeded()
            let track = Self.descendants(of: diff).first { $0 is ToggleTrackView }
            #expect(track?.isHidden == false)
            guard let track else { return }
            let inside = diff.subviews.compactMap { $0 as? ToggleView }.filter { !$0.isHidden && track.frame.contains($0.frame) }
            // Wrap, whitespace and the file tree, segmented, inside the track.
            #expect(inside.count >= 3)
            #expect(inside.allSatisfy { $0.variant == .segmented })
        }
    }

    @Test func workflowsOffStateButtonKeepsItsWidth() {
        withRedesign {
            let page = WorkflowsPageView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
            page.appearance = NSAppearance(named: .darkAqua)
            page.content = .off
            page.layoutSubtreeIfNeeded()
            let button = Self.descendants(of: page).compactMap { $0 as? ButtonView }.first { $0.title == "Open Settings → Labs" }
            #expect(button != nil)
            // Round 0 drew it 1pt wide, a line through the label.
            #expect((button?.frame.width ?? 0) > 100)
        }
    }
}
