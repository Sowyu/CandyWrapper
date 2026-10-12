import AppKit
import Testing
@testable import DesignSystem

/// A tooltip or hover card closes when its trigger goes away under a still pointer: a row rebuilt while a
/// run streams (the Lineage list replaces every row on each update) never sent the exit.
@MainActor
struct HoverCardLifetimeTests {
    private func openCard() -> (NSWindow, DSView, PopupHost) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let trigger = DSView(frame: NSRect(x: 20, y: 20, width: 120, height: 32))
        window.contentView?.addSubview(trigger)
        let tip = TooltipController.attach(to: trigger, text: "Subagent")
        tip.show(instant: true)
        let host = PopupHost.host(for: window)
        #expect(host.popups.count == 1)
        return (window, trigger, host)
    }

    @Test func closesWhenTheTriggerIsReplaced() {
        let (window, trigger, host) = openCard()
        defer { window.close() }
        trigger.removeFromSuperview()
        HoverSync.syncNow(window)
        #expect(host.popups.isEmpty)
    }

    @Test func closesWhenTheTriggerHides() {
        let (window, trigger, host) = openCard()
        defer { window.close() }
        trigger.isHidden = true
        HoverSync.syncNow(window)
        #expect(host.popups.isEmpty)
    }
}
