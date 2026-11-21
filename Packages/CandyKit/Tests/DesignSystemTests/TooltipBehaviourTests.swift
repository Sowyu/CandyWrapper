import AppKit
import Testing
@testable import DesignSystem

/// The in-app tooltip's timing, dismissal, placement and content (`Tooltips`, `TooltipController`), with an injected
/// clock and timer so nothing waits on real time.
@MainActor @Suite(.serialized) struct TooltipBehaviourTests {
    final class Clock {
        var t: TimeInterval = 100
        var pending: [(wait: TimeInterval, work: DispatchWorkItem)] = []
        /// Runs the last timer as if its wait passed.
        func fire() {
            guard let last = pending.popLast() else { return }
            t += last.wait
            if !last.work.isCancelled { last.work.perform() }
        }
    }

    /// Two 28pt buttons side by side in a window, with the clock, the timer and the pointer check injected.
    private func fixture(mode: TooltipMode = .on) -> (NSWindow, [TooltipController], Clock, () -> Void) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let clock = Clock()
        let saved = (Tooltips.now, Tooltips.schedule, Tooltips.pointerIsOn, Tooltips.mode)
        Tooltips.reset()
        Tooltips.now = { clock.t }
        Tooltips.schedule = { wait, work in clock.pending.append((wait, work)) }
        Tooltips.pointerIsOn = { _ in true }
        Tooltips.mode = { mode }
        let controllers = (0..<2).map { i -> TooltipController in
            let v = DSView(frame: NSRect(x: 100 + CGFloat(i) * 32, y: 100, width: 28, height: 28))
            window.contentView?.addSubview(v)
            return TooltipController.attach(to: v, text: "Button \(i)", shortcut: i == 1 ? "⇧⌘I" : nil)
        }
        let restore = {
            Tooltips.reset()
            (Tooltips.now, Tooltips.schedule, Tooltips.pointerIsOn, Tooltips.mode) = saved
            window.close()
        }
        return (window, controllers, clock, restore)
    }

    @Test func opensAfterTheRestDelay() {
        let (_, c, clock, restore) = fixture()
        defer { restore() }
        c[0].pointerEntered()
        #expect(!c[0].isShown)
        #expect(clock.pending.map(\.wait) == [0.6])
        #expect(Tooltips.isMonitoring)
        clock.fire()
        #expect(c[0].isShown)
    }

    @Test func leavingBeforeTheDelayCancelsAndGoesIdle() {
        let (_, c, clock, restore) = fixture()
        defer { restore() }
        c[0].pointerEntered()
        c[0].pointerLeft()
        #expect(clock.pending.first?.work.isCancelled == true)
        #expect(!Tooltips.isTimerArmed && !Tooltips.isMonitoring)
        clock.fire()
        #expect(!c[0].isShown)
    }

    @Test func aNeighbourOpensAtOnceWhileWarmThenCools() {
        let (_, c, clock, restore) = fixture()
        defer { restore() }
        c[0].pointerEntered()
        clock.fire()
        c[0].pointerLeft()
        #expect(!c[0].isShown && !Tooltips.isMonitoring)
        clock.t += 0.2
        c[1].pointerEntered()
        #expect(c[1].isShown, "warm: opens without the delay")
        #expect(c[1].popup?.motion == PopupMotion.none, "warm: opens without motion")
        c[1].pointerLeft()
        clock.t += Tooltips.warmWindow + 0.1
        c[0].pointerEntered()
        #expect(!c[0].isShown, "cooled down: waits again")
        #expect(clock.pending.last?.wait == 0.6)
    }

    @Test func movingStraightToANeighbourSwapsAtOnce() {
        let (_, c, clock, restore) = fixture()
        defer { restore() }
        c[0].pointerEntered()
        clock.fire()
        c[1].pointerEntered()
        #expect(!c[0].isShown && c[1].isShown)
    }

    @Test func delayedAndOffModes() {
        do {
            let (_, c, clock, restore) = fixture(mode: .delayed)
            c[0].pointerEntered()
            #expect(clock.pending.map(\.wait) == [Tooltips.delayedDelay])
            restore()
        }
        do {
            let (_, c, clock, restore) = fixture(mode: .off)
            c[0].pointerEntered()
            #expect(clock.pending.isEmpty && !c[0].isShown && !Tooltips.isMonitoring)
            restore()
        }
        #expect(Tooltips.wait(delay: 0.2, mode: .delayed, now: 0)?.wait == 1.2)
        #expect(Tooltips.wait(delay: 0.6, mode: .on, now: 0)?.wait == 0.6)
    }

    private func event(_ type: NSEvent.EventType, flags: NSEvent.ModifierFlags = [], window: NSWindow) -> NSEvent {
        switch type {
        case .keyDown:
            return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                                    context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
        case .flagsChanged:
            return NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                                    context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 56)!
        case .scrollWheel:
            let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 3, wheel2: 0, wheel3: 0)!
            return NSEvent(cgEvent: cg)!
        default:
            return NSEvent.mouseEvent(with: type, location: NSPoint(x: 10, y: 10), modifierFlags: flags, timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
    }

    @Test(arguments: [NSEvent.EventType.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel, .leftMouseDragged])
    func eachEventDismissesUntilThePointerLeaves(_ type: NSEvent.EventType) {
        let (window, c, clock, restore) = fixture()
        defer { restore() }
        c[0].pointerEntered()
        clock.fire()
        #expect(c[0].isShown)
        Tooltips.handle(event(type, window: window))
        #expect(!c[0].isShown, "\(type) closes it")
        #expect(!Tooltips.isMonitoring)
        c[0].pointerEntered()
        #expect(clock.pending.isEmpty && !c[0].isShown, "\(type): quiet until the pointer leaves")
        c[0].pointerExitedControl()
        c[0].pointerEntered()
        #expect(clock.pending.last?.wait == 0.6, "\(type): cooled, so it waits again")
    }

    @Test func aWaitingTooltipIsDismissedToo() {
        let (window, c, clock, restore) = fixture()
        defer { restore() }
        c[0].pointerEntered()
        Tooltips.handle(event(.leftMouseDown, window: window))
        clock.fire()
        #expect(!c[0].isShown)
    }

    @Test func screenshotModifiersDismissButOtherModifiersDoNot() {
        let (window, c, clock, restore) = fixture()
        defer { restore() }
        c[0].pointerEntered()
        clock.fire()
        Tooltips.handle(event(.flagsChanged, flags: [.command], window: window))
        #expect(c[0].isShown, "⌘ alone keeps it")
        Tooltips.handle(event(.flagsChanged, flags: [.command, .shift], window: window))
        #expect(!c[0].isShown, "⌘⇧ (a screenshot) closes it")
    }

    /// The monitor that feeds `handle` watches modifier changes, and a hand presses ⇧ then ⌘ for ⌘⇧4: the first
    /// keeps the tooltip, the second closes it. The release walk could not hold modifiers down, so this is the check.
    /// (Posting a real `flagsChanged` through `NSApp.sendEvent` crashes the test host.)
    @Test func screenshotModifiersReachTheMonitor() {
        let (window, c, clock, restore) = fixture()
        defer { restore() }
        #expect(Tooltips.monitoredEvents.contains(.flagsChanged))
        c[0].pointerEntered()
        clock.fire()
        #expect(c[0].isShown && Tooltips.isMonitoring)
        Tooltips.handle(event(.flagsChanged, flags: [.shift], window: window))
        #expect(c[0].isShown, "⇧ alone keeps it")
        Tooltips.handle(event(.flagsChanged, flags: [.shift, .command], window: window))
        #expect(!c[0].isShown, "⌘⇧ closes it")
        #expect(!Tooltips.isMonitoring, "and the monitor goes with it")
    }

    @Test func resigningKeyDismisses() {
        let (window, c, clock, restore) = fixture()
        defer { restore() }
        c[0].pointerEntered()
        clock.fire()
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(!c[0].isShown)
    }

    @Test func noTooltipUnderAMenuOrOnAPointerThatIsElsewhere() throws {
        let (_, c, clock, restore) = fixture()
        defer { restore() }
        let trigger = try #require(c[1].view)
        _ = MenuPopupView.show([MenuItem("A")], from: trigger)
        c[0].pointerEntered()
        clock.fire()
        #expect(!c[0].isShown, "a menu is open")
        trigger.popupHost?.closeAll()
        Tooltips.pointerIsOn = { _ in false }
        c[0].pointerExitedControl()
        c[0].pointerEntered()
        clock.fire()
        #expect(!c[0].isShown, "something covers the control")
    }

    @Test(arguments: [false, true])
    func placementNeverCoversTheAnchorAndStaysInside(_ below: Bool) {
        var placement = PopupPlacement.tooltip
        if below { placement.side = .bottom }
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        let size = CGSize(width: 120, height: 26)
        let anchors = [CGRect(x: 0, y: 0, width: 28, height: 28), CGRect(x: 372, y: 0, width: 28, height: 28),
                       CGRect(x: 186, y: 140, width: 28, height: 28), CGRect(x: 0, y: 272, width: 28, height: 28),
                       CGRect(x: 372, y: 272, width: 28, height: 28), CGRect(x: 100, y: 4, width: 200, height: 20)]
        for anchor in anchors {
            let frame = PopupPositioner.place(size: size, anchor: anchor, in: bounds, placement).frame
            #expect(!frame.intersects(anchor), "\(anchor) -> \(frame)")
            #expect(bounds.contains(frame), "\(anchor) -> \(frame)")
        }
    }

    @Test func redesignPutsTooltipsBelowTheControl() throws {
        let (window, c, clock, restore) = fixture()
        defer { restore() }
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        var theme = ThemeRuntimeInput()
        theme.ditherLight = true; theme.ditherDark = true
        ThemeRuntime.apply(theme)
        c[0].pointerEntered()
        clock.fire()
        let popup = try #require(c[0].popup)
        #expect(popup.result?.side == .bottom)
    }

    /// A T3-style "Name (⌥⌘B)" draws as the name and key caps under Redesign, also when the text changes while the
    /// tooltip shows (a rebound shortcut); the default themes keep T3's text (07-slide-press-redesign.png).
    @Test func redesignDrawsTrailingShortcutsAsKeyCapsAlways() throws {
        let (_, c, clock, restore) = fixture()
        defer { restore() }
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        var theme = ThemeRuntimeInput()
        theme.ditherLight = true; theme.ditherDark = true
        ThemeRuntime.apply(theme)
        c[0].text = "Toggle right panel (⌥⌘B)"
        c[0].pointerEntered()
        clock.fire()
        let tip = try #require(c[0].popup?.content as? TooltipView)
        #expect(tip.text == "Toggle right panel" && tip.shortcut == "⌥⌘B")
        c[0].text = "Toggle right panel (⌃⌘B)"
        #expect(tip.text == "Toggle right panel" && tip.shortcut == "⌃⌘B")
        #expect(c[0].shownParts(dither: false) == ("Toggle right panel (⌃⌘B)", nil))
    }

    @Test func truncatedLabelsShowTheirTextOnlyWhenCut() {
        let (window, _, _, restore) = fixture()
        defer { restore() }
        let label = LabelView("A branch name long enough to be cut short", font: DSFont.ui(12))
        window.contentView?.addSubview(label)
        label.tooltipWhenTruncated()
        let c = TooltipController.controller(for: label)!
        label.frame = NSRect(x: 10, y: 10, width: 60, height: 16)
        #expect(c.mayOpen())
        #expect(c.text == label.text)
        label.frame.size.width = 380
        #expect(!c.mayOpen())
        #expect(label.accessibilityHelp() == nil, "the label's own text reaches VoiceOver")
    }

    @Test func shortcutsDrawAsKeyCaps() {
        #expect(TooltipView.keys("⇧⌘I") == ["⇧", "⌘", "I"])
        #expect(TooltipView.keys("Esc") == ["Esc"])
        #expect(TooltipView.keys("⌘") == ["⌘"])
        #expect(TooltipController.splitShortcut("Toggle terminal drawer (⌘J)")! == ("Toggle terminal drawer", "⌘J"))
        #expect(TooltipController.splitShortcut("Close (Esc)")! == ("Close", "Esc"))
        #expect(TooltipController.splitShortcut("Merge stack (3 pull requests)") == nil)
        let plain = TooltipView("Agent images"), keyed = TooltipView("Agent images", shortcut: "⇧⌘I")
        #expect(keyed.intrinsicContentSize.width > plain.intrinsicContentSize.width + 40)
        #expect(keyed.intrinsicContentSize.height == plain.intrinsicContentSize.height)
    }

    @Test func theTextStaysTheAccessibilityHelp() {
        let view = DSView()
        view.setTooltip("Refresh diff")
        #expect(view.accessibilityHelp() == "Refresh diff" && view.currentTooltip == "Refresh diff")
        view.setTooltip(nil)
        #expect(view.accessibilityHelp() == nil && view.currentTooltip == nil)
        let icon = ButtonView(nil, icon: .x, variant: .ghost, size: .iconSm)
        icon.setTooltip("Close", shortcut: "Esc")
        #expect(icon.accessibilityLabel() == "Close")
        #expect(icon.accessibilityHelp() == nil, "an icon button speaks it once, as its label")
        #expect(view.toolTip == nil && icon.toolTip == nil, "no native tooltip")
    }
}

/// AppKit's own tooltip is a system window on its own timer: it lands in screenshots and over content. Every tooltip
/// goes through `setTooltip` instead. The allow-list holds only places with no app window to draw in.
struct NativeTooltipGuardTests {
    /// File name and why AppKit's tooltip is the only one possible there.
    static let allowed: [String: String] = [
        // An NSMenu item before macOS 14.4, which has no subtitle; NSMenu draws in its own window.
        "NativeItemContextMenu.swift": "native.toolTip",
        // The NSStatusItem in the system menu bar, outside every app window.
        "MenuBarController.swift": "item.button?.toolTip",
    ]

    @Test func noNativeTooltips() throws {
        let token = try NSRegularExpression(pattern: #"\btoolTip\b"#)
        var hits: [String] = []
        for url in RedesignTokenGuardTests.sources() {
            let name = url.lastPathComponent
            for (i, raw) in try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n").enumerated() {
                let line = raw.components(separatedBy: "//").first ?? raw
                guard token.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil else { continue }
                if let ok = Self.allowed[name], line.contains(ok) { continue }
                hits.append("\(name):\(i + 1): \(raw.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(hits.isEmpty, "use setTooltip instead:\n\(hits.joined(separator: "\n"))")
    }
}
