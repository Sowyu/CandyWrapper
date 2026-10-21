import AppKit
import Testing
@testable import DesignSystem

/// Positioning (base-ui flip, shift and collision padding) and keyboard behaviour of the popup family.
@MainActor
struct PopupBehaviourTests {
    let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
    let size = CGSize(width: 160, height: 120)

    // MARK: Positioning

    @Test func menuOpensBelowCentred() {
        let anchor = CGRect(x: 300, y: 100, width: 80, height: 32)
        let r = PopupPositioner.place(size: size, anchor: anchor, in: bounds, .menu)
        #expect(r.side == .bottom)
        #expect(r.frame == CGRect(x: 260, y: 136, width: 160, height: 120))
        #expect(r.transformOrigin == CGPoint(x: 80, y: -4))
    }

    @Test func flipsAboveAtTheBottomEdge() {
        let anchor = CGRect(x: 300, y: 500, width: 80, height: 32)
        let r = PopupPositioner.place(size: size, anchor: anchor, in: bounds, .menu)
        #expect(r.side == .top)
        #expect(r.frame.maxY == 496)
    }

    @Test func flipUsesPaddingPlusOne() {
        // Bottom edge of the popup lands at 600 - 6 exactly: fits. One point more: flips.
        let fits = PopupPositioner.place(size: size, anchor: CGRect(x: 300, y: 438, width: 80, height: 32), in: bounds, .menu)
        #expect(fits.side == .bottom)
        let flips = PopupPositioner.place(size: size, anchor: CGRect(x: 300, y: 439, width: 80, height: 32), in: bounds, .menu)
        #expect(flips.side == .top)
    }

    /// base-ui flips the alignment before shifting: the sidebar's bottom-end snooze menu opens bottom-start.
    @Test func flipsAlignmentAtTheLeftEdge() {
        let end = PopupPlacement(side: .bottom, align: .end, sideOffset: 4, fallbackAxisSide: .none)
        let r = PopupPositioner.place(size: size, anchor: CGRect(x: 140, y: 100, width: 20, height: 20), in: bounds, end)
        #expect(r.side == .bottom)
        #expect(r.frame.minX == 140)
        let room = PopupPositioner.place(size: size, anchor: CGRect(x: 400, y: 100, width: 20, height: 20), in: bounds, end)
        #expect(room.frame.maxX == 420)
    }

    @Test func shiftsInsideCollisionPadding() {
        let right = PopupPositioner.place(size: size, anchor: CGRect(x: 770, y: 100, width: 28, height: 28), in: bounds, .menu)
        #expect(right.frame.maxX == 795)
        let left = PopupPositioner.place(size: size, anchor: CGRect(x: 0, y: 100, width: 28, height: 28), in: bounds, .menu)
        #expect(left.frame.minX == 5)
        #expect(left.transformOrigin.x == 9) // trigger centre 14, popup at 5
    }

    @Test func popupStyleFallsBackToTheCrossAxis() {
        // A tall popup next to a trigger in the middle: neither top nor bottom fits.
        let tall = CGSize(width: 100, height: 400)
        let anchor = CGRect(x: 100, y: 280, width: 40, height: 40)
        let q2 = PopupPositioner.place(size: tall, anchor: anchor, in: bounds, .tooltip)
        #expect(q2.side == .right)
        let z2 = PopupPositioner.place(size: tall, anchor: anchor, in: bounds, .menu)
        #expect(z2.side == .bottom || z2.side == .top)
    }

    @Test func submenuOpensInlineEndAndFlipsLeft() {
        let row = CGRect(x: 100, y: 100, width: 150, height: 28)
        let r = PopupPositioner.place(size: size, anchor: row, in: bounds, .submenu)
        #expect(r.side == .right)
        #expect(r.frame.origin == CGPoint(x: 250, y: 95))
        let nearEdge = PopupPositioner.place(size: size, anchor: row.offsetBy(dx: 520, dy: 0), in: bounds, .submenu)
        #expect(nearEdge.side == .left)
        #expect(nearEdge.frame.maxX == 620)
    }

    // MARK: Keyboard and state

    func window() -> (NSWindow, DSView) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        let root = DSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        w.contentView = root
        return (w, root)
    }

    @Test func menuKeyboardNavigation() throws {
        let (w, root) = window()
        let button = ButtonView("Open")
        button.frame = NSRect(x: 100, y: 100, width: 80, height: 32)
        root.addSubview(button)
        let items: [MenuItem] = [.label("Group"), MenuItem("Copy"), MenuItem("Cut", disabled: true), MenuItem("Paste"), .separator, MenuItem("Delete")]
        let menu = try #require(MenuPopupView.show(items, from: button))
        let host = PopupHost.host(for: w)
        #expect(button.isPopupOpen)
        #expect(menu.highlightedIndex == nil)

        host.handleKey(.down)
        #expect(menu.highlightedIndex == 1)  // skips the label
        host.handleKey(.down)
        #expect(menu.highlightedIndex == 3)  // skips the disabled item
        host.handleKey(.down)
        #expect(menu.highlightedIndex == 5)  // skips the separator
        host.handleKey(.down)
        #expect(menu.highlightedIndex == 1)  // loops
        host.handleKey(.up)
        #expect(menu.highlightedIndex == 5)
        host.handleKey(.home)
        #expect(menu.highlightedIndex == 1)
        host.handleKey(.end)
        #expect(menu.highlightedIndex == 5)
        host.handleKey(.character("p"))
        #expect(menu.highlightedIndex == 3)  // typeahead

        host.handleKey(.escape)
        #expect(host.popups.isEmpty)
        #expect(!button.isPopupOpen)
    }

    @Test func enterRunsTheActionAndCloses() throws {
        let (w, root) = window()
        let button = ButtonView("Open")
        button.frame = NSRect(x: 100, y: 100, width: 80, height: 32)
        root.addSubview(button)
        var ran = false
        var toggled: Bool?
        let menu = try #require(MenuPopupView.show([.checkbox("Wrap", checked: false) { toggled = $0 }, MenuItem("Run") { ran = true }], from: button))
        let host = PopupHost.host(for: w)
        host.handleKey(.down)
        host.handleKey(.space)
        #expect(toggled == true)
        #expect(host.popups.count == 1) // checkbox items keep the menu open
        host.handleKey(.down)
        host.handleKey(.enter)
        #expect(ran)
        #expect(host.popups.isEmpty)
        _ = menu
    }

    @Test func submenuOpensWithRightAndClosesWithLeft() throws {
        let (w, root) = window()
        let button = ButtonView("Open")
        button.frame = NSRect(x: 100, y: 100, width: 80, height: 32)
        root.addSubview(button)
        let menu = try #require(MenuPopupView.show([.submenu("More", [MenuItem("Inner")]), MenuItem("Other")], from: button))
        let host = PopupHost.host(for: w)
        host.handleKey(.down)
        host.handleKey(.right)
        #expect(host.popups.count == 2)
        let sub = try #require(host.popups.last?.content as? MenuPopupView)
        #expect(sub.highlightedIndex == 0)
        #expect(host.popups.last?.result?.side == .right)
        host.handleKey(.left)
        #expect(host.popups.count == 1)
        #expect(menu.highlightedIndex == 0)
        host.handleKey(.right)
        host.handleKey(.escape) // Escape closes the whole tree
        #expect(host.popups.isEmpty)
    }

    @Test func outsidePressClosesAndModalMenusSwallowIt() throws {
        let (w, root) = window()
        let button = ButtonView("Open")
        button.frame = NSRect(x: 100, y: 100, width: 80, height: 32)
        root.addSubview(button)
        _ = try #require(MenuPopupView.show([MenuItem("A")], from: button))
        let host = PopupHost.host(for: w)
        #expect(host.handleMouseDown(at: CGPoint(x: 700, y: 500)))
        #expect(host.popups.isEmpty)
        let popover = PopoverView(content: popoverTitle("Hi"))
        popover.show(from: button)
        #expect(!host.handleMouseDown(at: CGPoint(x: 700, y: 500))) // popovers let the click through
        #expect(host.popups.isEmpty)
    }

    @Test func tooltipsDoNotCloseMenusOrTakeKeys() throws {
        let (w, root) = window()
        let button = ButtonView("Open")
        button.frame = NSRect(x: 100, y: 100, width: 80, height: 32)
        root.addSubview(button)
        let menu = try #require(MenuPopupView.show([MenuItem("A"), MenuItem("B")], from: button))
        let tip = TooltipController.attach(to: button, text: "Hint")
        tip.show(instant: true)
        let host = PopupHost.host(for: w)
        #expect(host.popups.count == 2)
        host.handleKey(.down)
        #expect(menu.highlightedIndex == 0)
    }

    /// A menu trigger whose press disables it (a menu that loads first) does not stay pressed.
    @Test func triggerDisabledByItsPressReleases() {
        let (_, root) = window()
        let button = ButtonView("Open").menuTrigger()
        button.frame = NSRect(x: 100, y: 100, width: 80, height: 32)
        root.addSubview(button)
        button.action = { [weak button] in button?.isEnabled = false }
        let at = button.convert(NSPoint(x: 10, y: 10), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: 0,
                                           windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            type == .leftMouseDown ? button.mouseDown(with: event) : button.mouseUp(with: event)
        }
        #expect(!button.isEnabled)
        #expect(!button.state.active)
    }

    /// floating-ui's `hide`:a scroll that takes the trigger out of the window closes its popup.
    @Test func popupClosesWhenItsTriggerLeavesOnScroll() throws {
        let (w, root) = window()
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let doc = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 1000))
        scroll.documentView = doc
        root.addSubview(scroll)
        let button = ButtonView("Open")
        button.frame = NSRect(x: 20, y: 20, width: 80, height: 32)
        doc.addSubview(button)
        let popover = PopoverView(content: popoverTitle("Hi"))
        popover.show(from: button)
        let host = PopupHost.host(for: w)
        #expect(host.popups.count == 1)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 10))
        #expect(host.popups.count == 1)
        button.removeFromSuperview()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 20))
        #expect(host.popups.isEmpty)
    }

    @Test func selectAlignsTheSelectedItemWithTheTrigger() throws {
        let (w, root) = window()
        let select = SelectView(options: ["One", "Two", "Three"], selected: 1)
        select.frame = NSRect(x: 200, y: 300, width: 200, height: 32)
        root.addSubview(select)
        select.performAction()
        let host = PopupHost.host(for: w)
        let popup = try #require(host.popups.first)
        // Row 1's text sits on the trigger's text: same baseline row, x 13 into the popup vs 12 into the trigger.
        #expect(popup.container.frame.minX == 199)
        #expect(popup.container.frame.minY + 5 + 28 + 14 == 316)
        #expect(popup.container.frame.width == 230)
        host.handleKey(.down)
        host.handleKey(.enter)
        #expect(select.selectedIndex == 2)
        #expect(host.popups.isEmpty)
    }

    @Test func comboboxFilters() {
        #expect(ComboboxView.filter(["Claude Haiku", "Claude Opus", "GPT"], "cla") == [0, 1])
        #expect(ComboboxView.filter(["Claude Haiku", "Claude Opus", "GPT"], "OPUS") == [1])
        #expect(ComboboxView.filter(["A", "B"], " ") == [0, 1])
    }

    @Test func comboboxAcceptsOptionsWhileItsListIsOpen() throws {
        let (w, root) = window()
        let picker = ComboboxView(options: [])
        picker.frame = NSRect(x: 100, y: 100, width: 200, height: 32)
        root.addSubview(picker)
        picker.setValue("Menlo")
        picker.showList(filter: false)
        let host = PopupHost.host(for: w)
        picker.options = ["Helvetica", "Menlo", "Monaco"]
        #expect(picker.selectedIndex == 1)
        #expect(host.popups.count == 1)
        host.handleKey(.down)
        host.handleKey(.enter)
        #expect(picker.input.text == "Monaco")
        #expect(picker.selectedIndex == 2)
    }

    @Test func safeTriangle() {
        let sub = CGRect(x: 200, y: 0, width: 100, height: 200)
        #expect(MenuPopupView.inSafeTriangle(CGPoint(x: 150, y: 100), from: CGPoint(x: 100, y: 100), toward: sub))
        #expect(!MenuPopupView.inSafeTriangle(CGPoint(x: 110, y: 190), from: CGPoint(x: 100, y: 100), toward: sub))
    }
}

@MainActor
struct MenuRadioCloseTests {
    /// base-ui `closeOnClick`: a radio item that closes on click runs its action; without it,
    /// only the radio state and `onToggle` change (the diff panel's turn picker used `action`
    /// and did nothing).
    @Test func radioItemsRunTheirActionWhenTheyCloseOnClick() {
        var ran: [String] = []
        var closing = MenuItem("Turn 2", kind: .radio(false))
        closing.closesOnClick = true
        closing.action = { ran.append("closing") }
        var staying = MenuItem("Turn 1", kind: .radio(true))
        staying.action = { ran.append("staying") }
        let menu = MenuPopupView(items: [staying, closing])
        menu.activate(1)
        menu.activate(0)
        #expect(ran == ["closing"])
    }

    /// A "\n" stacks two lines in a box as wide as the wider line, like the compact pill's two `<div>`s.
    @Test func tooltipHardBreakStacksLines() {
        let one = TooltipView("Next send keeps all 120k tokens.")
        let two = TooltipView("Next send keeps all 120k tokens.\nClick to compact first")
        #expect(abs(two.intrinsicContentSize.width - one.intrinsicContentSize.width) < 1)
        #expect(two.intrinsicContentSize.height == 16.5 * 2 + 10)
    }
}
