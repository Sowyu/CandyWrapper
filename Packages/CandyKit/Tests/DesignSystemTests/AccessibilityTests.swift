import AppKit
import Testing
@testable import DesignSystem

/// Custom controls reach VoiceOver with T3's roles, names and states, and containers stay transparent.
@MainActor
struct AccessibilityTests {
    @Test func buttonsAreElementsNamedByTextLabelOrTooltip() {
        let text = ButtonView("Cancel")
        #expect(text.isAccessibilityElement())
        #expect(text.accessibilityRole() == .button)
        #expect(text.accessibilityTitle() == "Cancel")

        let labelled = ButtonView("Stash 1")
        labelled.setAccessibilityLabel("Open stash")
        #expect(labelled.accessibilityLabel() == "Open stash")
        #expect(labelled.accessibilityTitle() == nil) // `aria-label` replaces the content

        let icon = ButtonView(icon: .plus)
        TooltipController.attach(to: icon, text: "New thread")
        #expect(icon.accessibilityLabel() == "New thread")

        var pressed = 0
        icon.action = { pressed += 1 }
        #expect(icon.accessibilityPerformPress())
        icon.isEnabled = false
        #expect(!icon.accessibilityPerformPress())
        #expect(!icon.isAccessibilityEnabled())
        #expect(pressed == 1)
    }

    @Test func triggersTogglesAndExpandedState() {
        let trigger = ButtonView("Open").menuTrigger()
        #expect(trigger.accessibilityRole() == .menuButton)
        trigger.isPopupOpen = true
        #expect(trigger.isAccessibilityExpanded())

        let toggle = SwitchView(isOn: false)
        #expect((toggle.accessibilityValue() as? Int) == 0)
        toggle.isOn = true
        #expect((toggle.accessibilityValue() as? Bool) == true)
    }

    @Test func labelsReadAsTextOutsideControlsOnly() {
        let loose = LabelView("Worked for 10s")
        let host = DSView()
        host.addSubview(loose)
        #expect(loose.isAccessibilityElement())
        #expect(loose.accessibilityRole() == .staticText)

        let button = ButtonView("Send")
        let inner = button.subviews.compactMap { $0 as? LabelView }.first
        #expect(inner?.isAccessibilityElement() == false)
    }

    @Test func namedGroupsAreElementsAndBareGroupsStayTransparent() {
        let dialog = DSView()
        dialog.setAccessibilityRole(.group)
        dialog.setAccessibilityLabel("Rename thread")
        #expect(dialog.isAccessibilityElement())

        let layout = DSView()
        layout.setAccessibilityRole(.group)
        #expect(!layout.isAccessibilityElement())

        let list = DSView()
        list.setAccessibilityRole(.list)
        #expect(list.isAccessibilityElement())
    }
}
