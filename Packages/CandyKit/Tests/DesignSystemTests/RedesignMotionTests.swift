import AppKit
import Testing
@testable import DesignSystem

/// Redesign's one motion system (docs/research/redesign-motion-2026-11-21.md): the tokens, each pattern ending on its
/// resting frame with nothing left on the layer, Reduce Motion, and a press that clears on a release outside.
@MainActor @Suite(.serialized) struct RedesignMotionTests {
    typealias M = RedesignTokens.Motion

    static func withRedesign(_ on: Bool = true, reduced: Bool = false, _ body: () throws -> Void) rethrows {
        let previous = ThemeRuntime.input, appearance = NSApp?.appearance, motion = Motion.reducedOverride
        defer { ThemeRuntime.apply(previous); NSApp?.appearance = appearance; Motion.reducedOverride = motion }
        var input = ThemeRuntimeInput(light: ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .light)!),
                                      dark: ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .dark)!))
        input.ditherLight = on; input.ditherDark = on
        ThemeRuntime.apply(on ? input : ThemeRuntimeInput())
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        Motion.reducedOverride = reduced
        try body()
    }

    static func withRedesign(_ on: Bool = true, _ body: () async throws -> Void) async rethrows {
        let previous = ThemeRuntime.input, appearance = NSApp?.appearance, motion = Motion.reducedOverride
        defer { ThemeRuntime.apply(previous); NSApp?.appearance = appearance; Motion.reducedOverride = motion }
        var input = ThemeRuntimeInput(light: ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .light)!),
                                      dark: ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .dark)!))
        input.ditherLight = on; input.ditherDark = on
        ThemeRuntime.apply(on ? input : ThemeRuntimeInput())
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        Motion.reducedOverride = false
        try await body()
    }

    func window() -> (NSWindow, DSView) {
        // Off screen but ordered in, so the window server runs the animations out and their ends fire.
        let w = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 600, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        let root = DSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        w.contentView = root
        w.orderFrontRegardless()
        return (w, root)
    }

    /// Lets Core Animation run the animations out and their completion blocks fire.
    /// Awaits rather than spinning the run loop: the ends arrive on the main queue, which a test on it must yield.
    func settle(_ ms: Int = 400) async throws {
        CATransaction.flush()
        try await Task.sleep(for: .milliseconds(ms))
    }

    func redesignKeys(_ layer: CALayer) -> [String] { (layer.animationKeys() ?? []).filter { $0.hasPrefix("redesign.") } }

    @Test func tokensStayFastAndOrdered() {
        #expect(M.fast < M.standard && M.standard < M.large)
        #expect(M.large <= 0.22, "nothing slower than about 220 ms")
        #expect(M.popover(entering: true) == M.standard && M.popover(entering: false) == M.fast)
        #expect(RedesignMotion.modal(backdrop: true, entering: true) == M.large)
        #expect(RedesignMotion.modal(backdrop: false, entering: true) == M.standard)
        #expect(RedesignMotion.modal(backdrop: true, entering: false) == M.fast)
        var p: [Float] = [0, 0]
        M.curve.getControlPoint(at: 1, values: &p)
        #expect(p == [0.23, 1])
        M.exitCurve.getControlPoint(at: 1, values: &p)
        #expect(p == [0.4, 0])
    }

    @Test func hoverShowsAtOnceAndClearsFast() {
        var old = ControlView.State(), new = old
        new.hovered = true
        #expect(RedesignMotion.hoverTransition(from: old, to: new)?.0 == [])
        #expect(RedesignMotion.hoverTransition(from: new, to: old)?.0 == .colors)
        #expect(RedesignMotion.hoverTransition(from: new, to: old)?.1 == M.fast)
        old = new; new.active = true
        #expect(RedesignMotion.hoverTransition(from: old, to: new) == nil, "a press keeps the control's own transitions")
    }

    /// A pill rises in and leaves; each ends on the model's resting values and removes its animations.
    @Test func pillEndsAtRestWithNothingLeft() async throws {
        try await Self.withRedesign {
            let (w, root) = window()
            defer { w.close() }
            let pill = DSView(frame: NSRect(x: 10, y: 10, width: 80, height: 30))
            root.addSubview(pill)
            let layer = try #require(pill.layer)
            RedesignMotion.pill(layer, entering: true)
            #expect(Set(redesignKeys(layer)) == ["redesign.pill.y", "redesign.pill.opacity"])
            #expect(layer.opacity == 1 && CATransform3DIsIdentity(layer.transform), "the model is the resting frame from the start")
            try await settle()
            #expect(redesignKeys(layer).isEmpty)

            var left = false
            RedesignMotion.pill(layer, entering: false) { left = true }
            try await settle()
            #expect(left)
            #expect(redesignKeys(layer).isEmpty)
            #expect(layer.opacity == 1, "the caller hides the view; the layer keeps its resting opacity")
        }
    }

    /// Opening again mid-leave starts from what is on screen, and the earlier leave's end does not run.
    @Test func pillReversesWithoutRunningTheOldEnd() async throws {
        try await Self.withRedesign {
            let (w, root) = window()
            defer { w.close() }
            let pill = DSView(frame: NSRect(x: 10, y: 10, width: 80, height: 30))
            root.addSubview(pill)
            let layer = try #require(pill.layer)
            var left = false
            RedesignMotion.pill(layer, entering: false) { left = true }
            RedesignMotion.pill(layer, entering: true)
            try await settle()
            #expect(!left)
            #expect(redesignKeys(layer).isEmpty)
        }
    }

    @Test func panelEndsAtRestWithNothingLeft() async throws {
        try await Self.withRedesign {
            let (w, root) = window()
            defer { w.close() }
            let panel = DSView(frame: NSRect(x: 300, y: 0, width: 300, height: 400))
            root.addSubview(panel)
            let layer = try #require(panel.layer)
            RedesignMotion.panel(layer, entering: true)
            #expect(Set(redesignKeys(layer)) == ["redesign.panel.x", "redesign.panel.opacity"])
            try await settle()
            #expect(redesignKeys(layer).isEmpty)
            #expect(layer.opacity == 1 && CATransform3DIsIdentity(layer.transform))
        }
    }

    /// Reduce Motion: pills appear and leave at once, the panel only fades.
    @Test func reduceMotionSnapsOrFades() throws {
        try Self.withRedesign(reduced: true) {
            let (w, root) = window()
            defer { w.close() }
            let view = DSView(frame: NSRect(x: 10, y: 10, width: 80, height: 30))
            root.addSubview(view)
            let layer = try #require(view.layer)
            RedesignMotion.pill(layer, entering: true)
            #expect(redesignKeys(layer).isEmpty)
            var left = false
            RedesignMotion.pill(layer, entering: false) { left = true }
            #expect(left, "the leave ends at once")
            RedesignMotion.panel(layer, entering: true)
            #expect(redesignKeys(layer) == ["redesign.fade"])
            let move = layer.animation(forKey: "redesign.fade") as? CABasicAnimation
            #expect(move?.keyPath == "opacity")
        }
    }

    /// Menus pop in the default themes and open like a popover in Redesign; an explicit `.none` stays instant.
    @Test func menusOpenLikePopoversOnlyInRedesign() throws {
        for redesign in [false, true] {
            try Self.withRedesign(redesign) {
                let (w, root) = window()
                defer { w.close() }
                let button = ButtonView("Open")
                button.frame = NSRect(x: 100, y: 100, width: 80, height: 32)
                root.addSubview(button)
                let menu = try #require(MenuPopupView.show([MenuItem("Copy"), MenuItem("Paste")], from: button))
                let container = try #require(menu.superview?.layer)
                let fade = container.animation(forKey: "popup.opacity") as? CABasicAnimation
                if redesign {
                    #expect(fade?.duration == M.standard)
                    #expect(fade?.timingFunction == M.curve)
                } else {
                    #expect(fade == nil)
                }
                PopupHost.host(for: w).closeAll()
            }
        }
        try Self.withRedesign {
            let (w, root) = window()
            defer { w.close() }
            let tip = PopoverView(content: DSView(frame: NSRect(x: 0, y: 0, width: 40, height: 20)))
            let anchor = DSView(frame: NSRect(x: 100, y: 100, width: 20, height: 20))
            root.addSubview(anchor)
            let popup = PopupHost.host(for: w).open(tip, trigger: anchor, placement: .tooltip, motion: .none)
            #expect(popup.container.layer?.animation(forKey: "popup.opacity") == nil)
        }
    }

    /// A press shrinks the button to `pressScale` and a release outside clears it, with no click.
    @Test func pressClearsOnReleaseOutside() throws {
        try Self.withRedesign {
            let (w, root) = window()
            defer { w.close() }
            var clicks = 0
            let button = ButtonView("Go")
            button.frame = NSRect(x: 100, y: 100, width: 80, height: 32)
            button.action = { clicks += 1 }
            root.addSubview(button)
            func event(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber,
                                   context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            button.mouseDown(with: event(.leftMouseDown, at: NSPoint(x: 140, y: 116)))
            #expect(button.state.active)
            let layer = try #require(button.layer)
            #expect(abs(layer.sublayerTransform.m11 - M.pressScale) < 0.001)
            #expect((layer.animation(forKey: "sublayerTransform") as? CABasicAnimation)?.duration == M.fast)
            button.mouseDragged(with: event(.leftMouseDragged, at: NSPoint(x: 400, y: 300)))
            button.mouseUp(with: event(.leftMouseUp, at: NSPoint(x: 400, y: 300)))
            #expect(!button.state.active && !button.state.hovered)
            #expect(CATransform3DIsIdentity(layer.sublayerTransform))
            #expect(clicks == 0)
        }
    }

    /// The segmented selection slides from the old segment and rests where it is drawn.
    @Test func segmentedSelectionSlides() async throws {
        try await Self.withRedesign {
            let (w, root) = window()
            defer { w.close() }
            let group = ToggleGroupView(variant: .segmented, items: [("Picture", nil), ("Blur", nil), ("Gradient", nil)], selected: 0)
            group.frame = NSRect(origin: NSPoint(x: 20, y: 20), size: group.intrinsicContentSize)
            root.addSubview(group)
            group.layoutSubtreeIfNeeded()
            group.selectedIndex = 2
            let fill = try #require(group.items[2].layer?.sublayers?.first { $0.animation(forKey: "redesign.selection") != nil })
            let slide = try #require(fill.animation(forKey: "redesign.selection") as? CABasicAnimation)
            #expect(slide.duration == M.standard)
            #expect(CATransform3DIsIdentity(fill.transform), "the model is the resting frame")
            #expect(group.items.map(\.isPressed) == [false, false, true])
            try await settle()
            #expect(fill.animation(forKey: "redesign.selection") == nil)
        }
    }
}
