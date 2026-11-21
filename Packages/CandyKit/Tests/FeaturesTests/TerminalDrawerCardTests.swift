import AppKit
import QuartzCore
import Testing
@testable import DesignSystem
@testable import Features
import T3Store

/// Redesign's terminal drawer is an inset card like the right panel: `Space.s` from the thread's sides, the window's
/// bottom and the right panel's card, clipped to its corners, its actions inside it, its handle in the gap above it,
/// and the composer clear of all of it.
@MainActor
struct TerminalDrawerCardTests {
    private static let height: CGFloat = 800

    private func makePanel(width: CGFloat, dark: Bool = true) -> (ThreadPanelView, NSWindow, () -> Void) {
        let previous = ThemeRuntime.input, duration = SettingsPanelMotion.durationMs
        var input = ThemeRuntimeInput(light: ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .light)!),
                                      dark: ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .dark)!))
        input.ditherLight = true; input.ditherDark = true
        ThemeRuntime.apply(input)
        SettingsPanelMotion.durationMs = 0
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: Self.height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let panel = ThreadPanelView(frame: NSRect(x: 0, y: 0, width: width, height: Self.height))
        panel.referenceViewportWidth = width
        window.contentView = panel
        panel.layoutSubtreeIfNeeded()
        panel.terminalDrawer.surface = TerminalSurfaceView()
        panel.terminalDrawer.onDrag = { [weak panel] start, delta, _ in
            guard let panel else { return }
            panel.setTerminal(open: true, height: TerminalDrawerState.clampHeight(start + delta, maxHeight: panel.terminalMaxHeight))
        }
        return (panel, window, {
            window.contentView = nil; window.close()
            ThemeRuntime.apply(previous); SettingsPanelMotion.durationMs = duration
        })
    }

    @Test(arguments: [1600, 1400, 1100, 960, 700] as [CGFloat], [false, true])
    func cardKeepsEvenGaps(width: CGFloat, panelOpen: Bool) throws {
        Motion.reducedOverride = true
        defer { Motion.reducedOverride = nil }
        let (panel, _, done) = makePanel(width: width)
        defer { done() }
        if panelOpen { panel.mutatePanel { $0.open(.diff); return [] } }
        panel.setTerminal(open: true, height: 260)
        for _ in 0..<2 { panel.layoutSubtreeIfNeeded() }
        let gap = RedesignTokens.Space.s
        let drawer = panel.terminalDrawer
        let card = drawer.frame
        #expect(!drawer.isHidden && drawer.isCard)
        #expect(card.minX == gap, "\(card)")
        #expect(card.maxY == Self.height - gap, "\(card)")
        #expect(card.height == 260)
        let inline = panelOpen && !panel.rightPanel.isSheet
        if inline {
            let right = panel.rightPanel.frame
            // The two cards meet on one gap and share their bottom edge.
            #expect(right.minX - card.maxX == gap, "drawer \(card) panel \(right)")
            #expect(right.maxY == card.maxY)
        } else {
            #expect(card.maxX == width - gap, "\(card)")
        }
        // Clipped to the card's corners, with the rim and no top border.
        let layer = try #require(drawer.layer)
        drawer.updateLayer()
        #expect(layer.cornerRadius == RedesignTokens.Radius.panel && layer.masksToBounds && layer.borderWidth == 1)
        // The actions sit inside the card, 4pt from its top and right.
        let actions = drawer.actions.frame
        #expect(!drawer.actions.isHidden)
        #expect(drawer.bounds.contains(actions))
        #expect(actions.minY == CardTopRow.tabsInset && drawer.bounds.width - actions.maxX == CardTopRow.tabsInset)
        #expect(actions.height == 24)
        // The handle fills the gap above the card.
        let handle = panel.terminalResize.frame
        #expect(!panel.terminalResize.isHidden)
        #expect(handle == NSRect(x: card.minX, y: card.minY - gap, width: card.width, height: gap), "\(handle) card \(card)")
        // The composer row stays clear of the gap and the card.
        if !panel.composer.isHidden {
            #expect(panel.composer.frame.maxY <= handle.minY, "composer \(panel.composer.frame) handle \(handle)")
        }
        for view in panel.subviews where !view.isHidden && view !== drawer && view !== panel.terminalResize
            && view !== panel.rightPanel && view !== panel.timeline && view.frame.height > 0 && view.frame.width > 0
            && !(view is RightPanelResizeView) && !(view is ToastViewport) && view.layer?.zPosition ?? 0 < 20 && view.frame != panel.bounds {
            #expect(!view.frame.intersects(card), "\(type(of: view)) \(view.frame) overlaps the card \(card)")
        }
    }

    @Test func splitPanesMeetOnAHairlineInsideTheCard() {
        Motion.reducedOverride = true
        defer { Motion.reducedOverride = nil }
        let (panel, _, done) = makePanel(width: 1400)
        defer { done() }
        let a = TerminalSurfaceView(), b = TerminalSurfaceView()
        let list = TerminalListModel(groups: [.init(id: "g", label: "Side by side", icon: .squareSplitHorizontal, isActive: true, target: "a",
                                                    rows: [.init(id: "a", label: "Terminal 1", isActive: true, closeLabel: "Close"),
                                                           .init(id: "b", label: "Terminal 2", isActive: false, closeLabel: "Close")])],
                                     showHeaders: false)
        panel.terminalDrawer.show([(id: "a", surface: a), (id: "b", surface: b)], direction: .horizontal, activeId: "a", list: list)
        panel.setTerminal(open: true, height: 260)
        for _ in 0..<2 { panel.layoutSubtreeIfNeeded() }
        let drawer = panel.terminalDrawer
        // One surface: the list meets the grid with no gap, and the actions row stays inside the card over the list.
        #expect(drawer.grid.frame.maxX == drawer.list.frame.minX)
        #expect(!drawer.actions.isHidden && drawer.bounds.contains(drawer.actions.frame))
        #expect(drawer.list.frame.contains(drawer.actions.frame))
        let first = a.superview!.frame, second = b.superview!.frame
        #expect(first.maxX == second.minX, "panes \(first) \(second)")
    }

    @Test func handleTapsOnceAtEachLimit() {
        Motion.reducedOverride = true
        defer { Motion.reducedOverride = nil }
        let (panel, _, done) = makePanel(width: 1400)
        defer { done() }
        panel.setTerminal(open: true, height: 260)
        panel.layoutSubtreeIfNeeded()
        let handle = panel.terminalResize
        let up = Haptics.recording {
            for _ in 0..<40 { handle.onDrag?(40) }
            handle.onDragEnd?()
        }
        panel.layoutSubtreeIfNeeded()
        #expect(up == [.alignment], "one tap on reaching the maximum, none dragging on past it")
        #expect(panel.terminalDrawer.frame.height == panel.terminalMaxHeight)
        let down = Haptics.recording {
            for _ in 0..<40 { handle.onDrag?(-40) }
            handle.onDragEnd?()
        }
        panel.layoutSubtreeIfNeeded()
        #expect(down == [.alignment])
        #expect(panel.terminalDrawer.frame.height == TerminalDrawerState.minHeight)
        // The card follows the pointer from the height it had: a small drag moves it exactly that far.
        handle.onDrag?(30); handle.onDrag?(12)
        panel.layoutSubtreeIfNeeded()
        #expect(panel.terminalDrawer.frame.height == TerminalDrawerState.minHeight + 42)
        handle.onDragEnd?()
    }

    @Test func opensWithThePanelMotionAndLeavesNoAnimation() throws {
        Motion.reducedOverride = false
        defer { Motion.reducedOverride = nil }
        let (panel, _, done) = makePanel(width: 1400)
        defer { done() }
        panel.setTerminal(open: true, height: 260)
        let layer = try #require(panel.terminalDrawer.layer)
        #expect((layer.animationKeys() ?? []).contains("redesign.panel.y"), "\(layer.animationKeys() ?? [])")
        // The model is the resting card from the first frame: no transform, full opacity, the final frame.
        #expect(CATransform3DIsIdentity(layer.transform) && layer.opacity == 1)
        #expect(panel.terminalDrawer.frame.maxY == Self.height - RedesignTokens.Space.s)
        panel.setTerminal(open: false, height: 260)
        #expect(panel.terminalDrawer.isHidden && panel.terminalResize.isHidden)
        let still = panel.layer?.sublayers?.first { $0 !== layer && ($0.animationKeys() ?? []).contains("redesign.panel.y") }
        #expect(still != nil, "a still image leaves in the drawer's place")
        #expect(still?.frame.maxY == Self.height - RedesignTokens.Space.s)
        layer.removeAllAnimations()
    }

    @Test func reduceMotionOnlyFades() throws {
        Motion.reducedOverride = true
        defer { Motion.reducedOverride = nil }
        let (panel, _, done) = makePanel(width: 1400)
        defer { done() }
        panel.setTerminal(open: true, height: 260)
        let keys = panel.terminalDrawer.layer?.animationKeys() ?? []
        #expect(!keys.contains("redesign.panel.y"), "\(keys)")
    }

    @Test func focusTintsTheRim() throws {
        Motion.reducedOverride = true
        defer { Motion.reducedOverride = nil }
        let (panel, window, done) = makePanel(width: 1400)
        defer { done() }
        panel.setTerminal(open: true, height: 260)
        panel.layoutSubtreeIfNeeded()
        let drawer = panel.terminalDrawer
        #expect(!drawer.hasKeyFocus)
        drawer.surface?.focus()
        #expect(window.firstResponder is InputTerminalView)
        #expect(drawer.hasKeyFocus)
        window.makeFirstResponder(panel)
        #expect(!drawer.hasKeyFocus)
    }

    @Test func defaultThemesKeepTheEdgeToEdgeDrawer() {
        let previous = ThemeRuntime.input
        ThemeRuntime.apply(ThemeRuntimeInput())
        defer { ThemeRuntime.apply(previous) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: Self.height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let panel = ThreadPanelView(frame: NSRect(x: 0, y: 0, width: 1400, height: Self.height))
        panel.referenceViewportWidth = 1400
        window.contentView = panel
        panel.terminalDrawer.surface = TerminalSurfaceView()
        panel.setTerminal(open: true, height: 260)
        panel.layoutSubtreeIfNeeded()
        #expect(!panel.terminalDrawer.isCard)
        #expect(panel.terminalDrawer.frame == NSRect(x: 0, y: Self.height - 260, width: 1400, height: 260))
        #expect(panel.terminalResize.superview == nil || panel.terminalResize.isHidden)
    }
}
