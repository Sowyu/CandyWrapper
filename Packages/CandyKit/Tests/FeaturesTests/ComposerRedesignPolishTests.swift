import AppKit
import Testing
@testable import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// The composer surfaces the 2026-11-26 Redesign review scored lowest: attachment tiles, the server update notice
/// squeezed by the right panel, and a one-line notice's height.
@MainActor
struct ComposerRedesignPolishTests {
    /// Runs `body` with Redesign on in both appearances, then puts the theme back.
    func withRedesign(_ body: () throws -> Void) rethrows {
        let previous = ThemeRuntime.input, appearance = NSApp?.appearance
        defer { ThemeRuntime.apply(previous); NSApp?.appearance = appearance }
        var input = ThemeRuntimeInput(light: ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .light)!),
                                      dark: ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .dark)!))
        input.ditherLight = true; input.ditherDark = true
        ThemeRuntime.apply(input)
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        try body()
    }

    @Test func attachmentTilesSitInsideTheComposerAboveTheText() throws {
        try withRedesign {
            let panel = ComposerFidelityTests.panel(width: 844, dark: true)
            panel.setProjection(try ThreadPreview.projection(titled: ThreadPreview.markdownThread), projectTitle: "demo-repo", workspaceRoot: nil)
            let url = ComposerAttachmentsFidelityTests.fixture
            panel.composer.imageTiles = [.init(id: "a", name: "a.png", status: .ready, fileURL: url),
                                         .init(id: "b", name: "b.png", status: .failed("Upload failed"), fileURL: url)]
            panel.needsLayout = true
            panel.layoutSubtreeIfNeeded()
            let composer = panel.composer
            let tiles = composer.imageShelf.frame
            #expect(!composer.imageShelf.isHidden)
            #expect(composer.bounds.contains(tiles), "tiles \(tiles) outside the composer \(composer.bounds)")
            #expect(tiles.height >= RedesignTokens.Composer.tile)
            // Above the editor: the shelf ends before the text starts (the composer is flipped).
            let editor = composer.subviews.first { $0 is NSScrollView }
            #expect(editor.map { tiles.maxY <= $0.frame.minY + 4 } ?? false)
        }
    }

    @Test func squeezedNoticeKeepsAShortCompleteTitle() throws {
        try withRedesign {
            // The right panel's squeeze from the review (262pt): the action drops its label for the copy icon, its label
            // lives on as the tooltip, and the whole title fits.
            let notice = RedesignBaselineTests.notice(guidance: nil, action: "Copy relaunch command", width: 262)
            #expect(notice.frame.width == 262)
            #expect(notice.title.text == "Server update available")
            #expect(!notice.title.isTruncated)
            let shown = notice.subviews.compactMap { $0 as? ButtonView }.filter { !$0.isHidden }
            #expect(!shown.contains { $0.title == "Copy relaunch command" })
            #expect(shown.contains { $0.icon == .copy })
            // Narrower still, the short complete title, never a single letter.
            let narrower = RedesignBaselineTests.notice(guidance: nil, action: "Copy relaunch command", width: 200)
            #expect(narrower.title.text == "Server update")
            #expect(!narrower.title.isTruncated)
            // Wide enough, the full title and the labelled action come back.
            let wide = RedesignBaselineTests.notice(guidance: nil, action: "Copy relaunch command")
            #expect(wide.title.text == "Server update available")
            #expect(wide.subviews.compactMap { $0 as? ButtonView }.contains { !$0.isHidden && $0.title == "Copy relaunch command" })
        }
    }

    @Test func oneLineNoticeIsAPillInTheThread() throws {
        try withRedesign {
            let panel = ComposerFidelityTests.panel(width: 844, dark: true)
            panel.setProjection(try ThreadPreview.projection(titled: ThreadPreview.markdownThread), projectTitle: "demo-repo", workspaceRoot: nil)
            panel.serverUpdateNotice = ComposerServerUpdateNotice(status: .available(serverVersion: "0.1.10", clientVersion: "0.1.11"),
                                                                  guidance: "Restart the server to update")
            panel.needsLayout = true
            panel.layoutSubtreeIfNeeded()
            let notice = try #require(Self.descendants(of: panel).compactMap { $0 as? ComposerNoticeBannerView }.first { !$0.isHidden && $0.content?.title == "Server update available" })
            #expect(notice.frame.height == DitherPill.height)
        }
    }

    static func descendants(of view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap { descendants(of: $0) } }
}
