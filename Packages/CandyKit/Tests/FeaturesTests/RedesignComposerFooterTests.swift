import AppKit
import Testing
import DesignSystem
import T3Protocol
@testable import Features

/// Redesign's controls around the composer after the round-1 review (2026-11-26): the quiet footer row, the context
/// ring, Compact, the attachment tiles, Question mode's "+", the permissions list and the message rail.
@MainActor
struct RedesignComposerFooterTests {
    private func redesign<T>(_ body: () throws -> T) rethrows -> T {
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        var input = ThemeRuntime.input
        input.ditherLight = true; input.ditherDark = true
        ThemeRuntime.apply(input)
        return try body()
    }

    private func host(_ view: NSView, width: CGFloat = 640, height: CGFloat = 240) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = view
        view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        return window
    }

    @Test func quietPatchOnlyCoversTheWords() {
        let patch = DitherPill.quietPatch(CGRect(x: 0, y: 0, width: 120, height: DitherPill.height))
        #expect(patch.height == 22 && patch.minX == DitherPill.quietInsetX)
        #expect(DitherPill.quietRadius == RedesignTokens.Radius.control)
        // The hover fill takes the patch's shape on a quiet control, the whole pill otherwise.
        let fill = CALayer()
        DitherPill.placeFill(fill, in: CGRect(x: 0, y: 0, width: 120, height: 30), quiet: true)
        #expect(fill.frame == patch && fill.cornerRadius == DitherPill.quietRadius)
        DitherPill.placeFill(fill, in: CGRect(x: 0, y: 0, width: 120, height: 30), quiet: false)
        #expect(fill.frame.height == 30 && fill.cornerRadius == DitherPill.radius)
    }

    @Test func ringShowsAnArcForLightUse() {
        #expect(ThreadContextWindowMeterView.arcFraction(4.6, redesign: true) == RedesignTokens.Meter.least)
        #expect(abs(ThreadContextWindowMeterView.arcFraction(4.6, redesign: false) - 0.046) < 0.0001)
        #expect(ThreadContextWindowMeterView.arcFraction(0, redesign: true) == 0)
        #expect(ThreadContextWindowMeterView.arcFraction(60, redesign: true) == 0.6)
        // The ring fills the 14pt glyph box.
        #expect(RedesignTokens.Meter.ringRadius + RedesignTokens.Meter.ringStroke / 2 == DitherPill.glyph / 2)
    }

    @Test func railStripsStepEvenly() {
        let steps = (0...3).map { ThreadMinimapView.stripWidth(distance: $0, redesign: true) }
        #expect(steps == [24, 20, 16, 12])
        #expect(ThreadMinimapView.stripWidth(distance: nil, redesign: true) == 12)
        #expect((0...3).map { ThreadMinimapView.stripWidth(distance: $0, redesign: false) } == [24, 16, 10, 8])
    }

    @Test func compactIsAGhostButtonWithTheCountInItsTooltip() {
        redesign {
            let pill = ComposerCompactPill()
            let window = host(pill)
            defer { window.contentView = nil }
            pill.tokens = "412k"
            pill.layoutSubtreeIfNeeded()
            let labels = pill.subviews.compactMap { $0 as? LabelView }
            let word = labels.first { $0.text == "Compact" }, count = labels.first { $0.text == "412k" }
            #expect(word != nil && count?.isHidden == true)
            #expect(pill.intrinsicContentSize.width == 8 + 14 + 6 + ceil(word!.textWidth) + 8)
            #expect(pill.label == "Compact 412k")
        }
    }

    @Test func questionModeKeepsThePlus() {
        redesign {
            let composer = ComposerView()
            let window = host(composer)
            defer { window.contentView = nil }
            composer.pending = .question(.init(label: "Next question", compactLabel: "Next", enabled: true,
                                               showsPrevious: false, responding: false, showsAttach: true))
            composer.layoutSubtreeIfNeeded()
            #expect(composer.attach.icon == .plus)
            #expect(composer.attach.frame.minX == ComposerView.capyEdge)
        }
    }

    @Test func permissionsListNamesEveryChoice() {
        redesign {
            let modes: [RuntimeMode] = [.approvalRequired, .autoAcceptEdits, .fullAccess]
            let view = ComposerPermissionsView(modes: modes, selected: .approvalRequired)
            #expect(view.rows)
            let window = host(view, width: 288, height: view.height)
            defer { window.contentView = nil }
            view.layoutSubtreeIfNeeded()
            let names = view.subviews.flatMap { $0.subviews.compactMap { ($0 as? LabelView)?.text } }
            #expect(names.contains("Supervised") && names.contains("Auto-accept edits") && names.contains("Full access"))
            #expect(view.height > 122, "three rows, the heading and the description")
        }
    }

    /// Remove waits for hover; retry stays in sight on a failed tile as its error cue, with "Failed" in the strip
    /// (round-2 review C4).
    @Test func failedTileShowsRetryAtRest() {
        redesign {
            let shelf = ComposerImageShelfView()
            let window = host(shelf)
            defer { window.contentView = nil }
            shelf.tiles = [.init(id: "a", name: "a.png", status: .failed("Upload failed"), fileURL: nil)]
            shelf.layoutSubtreeIfNeeded()
            let tile = try! #require(shelf.subviews.first)
            tile.layoutSubtreeIfNeeded()
            tile.displayIfNeeded()
            let buttons = tile.subviews.compactMap { $0 as? ButtonView }
            #expect(buttons.count == 2 && buttons.allSatisfy { $0.frame.width == 18 })
            let retry = buttons.first { $0.accessibilityLabel()?.hasPrefix("Retry") == true }
            let remove = buttons.first { $0.accessibilityLabel()?.hasPrefix("Remove") == true }
            #expect(retry?.alphaValue == 1, "retry shows at rest on a failed tile")
            #expect(remove?.alphaValue == 0, "remove shows on hover only")
            let labels = tile.subviews.flatMap { $0.subviews.compactMap { ($0 as? LabelView)?.text } }
            #expect(labels.contains("Failed"))
        }
    }
}
