import AppKit
import Testing
@testable import DesignSystem
@testable import Features
import T3Store

/// Redesign's right panel card shares its top row with the header pill: no empty band above the tabs, tabs and the
/// maximize button never under the pill, the pill concentric in the card's top right corner.
@MainActor
struct RightPanelCardRowTests {
    @Test(arguments: [344, 400, 524, 700, 1200] as [CGFloat], [0, 76, 150, 230, 300] as [CGFloat])
    func rowKeepsTabsClearOfThePill(width: CGFloat, pillWidth: CGFloat) {
        let pill = CGSize(width: pillWidth, height: DitherTabStripView.tabHeight)
        let row = CardTopRow(width: width, pill: pillWidth > 0 ? pill : .zero, trailing: [CGSize(width: 28, height: 24)])
        if pillWidth > 0 {
            // Concentric: the pill's control corner sits the difference of the two radii in from the card's corner.
            #expect(row.pill.maxX == width - (RedesignTokens.Radius.card - RedesignTokens.Radius.control))
            #expect(row.pill.minY == RedesignTokens.Radius.card - RedesignTokens.Radius.control)
        }
        let maximize = row.trailing[0]
        #expect(!maximize.intersects(row.pill))
        #expect(!row.tabs.intersects(row.pill) && !row.tabs.intersects(maximize))
        #expect(row.tabs.width >= CardTopRow.minTabRoom)
        // The tabs share the pill's row unless that leaves them too little room; only then they take a row of their own.
        let shared = row.tabs.minY == 0
        #expect(shared == (maximize.minX - RedesignTokens.Space.s - CardTopRow.tabsInset >= CardTopRow.minTabRoom))
        #expect(row.height == (shared ? CardTopRow.rowHeight : 2 * CardTopRow.rowHeight))
        #expect(row.pill == .zero || abs(row.pill.midY - maximize.midY) <= 0.5)
    }

    @Test(arguments: [(1400, 1), (1400, 6), (1000, 1), (1000, 6)] as [(CGFloat, Int)])
    func cardRowInTheWindow(windowWidth: CGFloat, tabCount: Int) throws {
        let previous = ThemeRuntime.input, duration = SettingsPanelMotion.durationMs
        Motion.reducedOverride = true
        defer { ThemeRuntime.apply(previous); SettingsPanelMotion.durationMs = duration; Motion.reducedOverride = nil }
        var input = ThemeRuntimeInput(light: ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .light)!),
                                      dark: ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .dark)!))
        input.ditherLight = true; input.ditherDark = true
        ThemeRuntime.apply(input)
        SettingsPanelMotion.durationMs = 0
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let content = FlippedView(frame: NSRect(x: 0, y: 0, width: windowWidth, height: 800))
        window.contentView = content
        // The panel sits under the window's tab band, which holds the header pill, as the app lays them out.
        let panel = ThreadPanelView(frame: NSRect(x: 0, y: DitherChrome.band, width: windowWidth, height: 800 - DitherChrome.band))
        panel.referenceViewportWidth = windowWidth
        let strip = DitherTabStripView(frame: NSRect(x: 0, y: 0, width: windowWidth, height: DitherChrome.band))
        content.addSubview(panel)
        content.addSubview(strip)
        strip.trailingAccessory = panel.header.pill
        panel.header.setThreadVisible(true)
        panel.layoutSubtreeIfNeeded()
        strip.layoutSubtreeIfNeeded()
        let restingPill = panel.header.pill.frame
        panel.mutatePanel { state in
            state.open(.diff)
            if tabCount > 1 { state.open(.files); state.openBrowser(nil) }
            for i in 0..<max(0, tabCount - 3) { state.openTerminal("t\(i)") }
            state.isOpen = true
            return []
        }
        for _ in 0..<2 { panel.layoutSubtreeIfNeeded(); strip.layoutSubtreeIfNeeded() }
        let card = content.convert(panel.rightPanel.bounds, from: panel.rightPanel)
        let pill = content.convert(panel.header.pill.bounds, from: panel.header.pill)
        let maximize = content.convert(panel.maximize.bounds, from: panel.maximize)
        let inset = RedesignTokens.Radius.card - RedesignTokens.Radius.control
        #expect(panel.header.pill.isHidden == false)
        #expect(pill.maxX == card.maxX - inset && pill.minY == card.minY + inset, "pill \(pill) card \(card)")
        #expect(!panel.maximize.isHidden && !maximize.intersects(pill), "maximize \(maximize) pill \(pill)")
        #expect(abs(maximize.midY - pill.midY) <= 0.5)
        let row = try #require(panel.rightPanel.cardRow)
        let tabs = panel.rightPanel.tabViews
        #expect(tabs.count == tabCount)
        // No band above the tabs: the first tab row starts at the card's top row.
        #expect(row.tabs.minY == 0)
        for tab in tabs where !tab.isHidden {
            let frame = content.convert(tab.bounds, from: tab)
            let shown = frame.intersection(card)
            guard !shown.isEmpty, tab.visibleRect.width > 0 else { continue }
            let visible = content.convert(tab.visibleRect, from: tab)
            #expect(!visible.intersects(pill) && !visible.intersects(maximize), "tab \(visible) pill \(pill)")
            #expect(abs(visible.midY - pill.midY) <= 0.5)
        }
        #expect(content.convert(panel.rightPanel.add.visibleRect, from: panel.rightPanel.add).intersects(pill) == false)
        // The row sits above the panel's own bounds, in the band: clicks on the +, a tab and maximize still reach them,
        // and the pill keeps its own.
        func hit(_ view: NSView) -> NSView? {
            let p = content.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), from: view)
            return content.hitTest(content.convert(p, to: content.superview))
        }
        let add = panel.rightPanel.add
        #expect(hit(add).map { $0 === add || $0.isDescendant(of: add) } == true, "\(String(describing: hit(add)))")
        #expect(hit(panel.maximize).map { $0 === panel.maximize || $0.isDescendant(of: panel.maximize) } == true)
        if let first = tabs.first(where: { $0.visibleRect.width > 0 && $0.frame.minX >= 0 }) {
            #expect(hit(first).map { $0 === first || $0.isDescendant(of: first) } == true)
        }
        #expect(hit(panel.header.pill).map { $0 === panel.header.pill || $0.isDescendant(of: panel.header.pill) } == true)
        // Closing gives the pill back its place in the band.
        panel.mutatePanel { state in state.isOpen = false; return [] }
        for _ in 0..<2 { panel.layoutSubtreeIfNeeded(); strip.layoutSubtreeIfNeeded() }
        #expect(panel.header.pill.frame == restingPill)
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
