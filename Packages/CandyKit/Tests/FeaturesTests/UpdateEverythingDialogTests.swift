import AppKit
import Testing
import DesignSystem
@testable import Features

@MainActor
struct UpdateEverythingDialogTests {
    @Test func skippedReasonsStartClosedAndExpandOnDemand() {
        let description = UpdateEverythingLogic.describe(localVersion: "2", servers: [], target: "2",
            providerMachines: [("one", "One", ["Claude"])],
            skipped: [.init(environmentId: "two", label: "Two", reason: "not connected")])
        let content = UpdateEverythingDialogContent(description)
        content.frame = NSRect(x: 0, y: 0, width: 528, height: 300)
        content.layoutSubtreeIfNeeded()
        let closed = content.intrinsicContentSize.height
        #expect(!content.skipsExpanded)
        content.toggleSkipped()
        #expect(content.skipsExpanded && content.intrinsicContentSize.height > closed)
        content.toggleSkipped()
        #expect(content.intrinsicContentSize.height == closed)
    }
}
