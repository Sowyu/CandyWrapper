import AppKit
import Testing
@testable import Features

/// The branch picker's size and row insets, measured in T3's web client (2861, the composer's Mod+Shift+G with two
/// refs): popup 320 wide and 121 tall with borders (125 since 3473's py-2 list), rows 8 to 308 of the 318-wide body, the first row 12 below the list top.
@MainActor
struct BranchPickerGeometryTests {
    @Test func refreshedCurrentBranchUpdatesExistingRows() throws {
        let picker = BranchPickerView()
        picker.selectedValue = "main"
        picker.rows = [.init(value: "main", title: "main"), .init(value: "changed-outside-app", title: "changed-outside-app")]
        let rows = ThreadDetailsScrollTests.views(BranchPickerRowView.self, in: picker)
        #expect(rows.map { $0.isAccessibilitySelected() } == [true, false])
        picker.selectedValue = "changed-outside-app"
        #expect(rows.map { $0.isAccessibilitySelected() } == [false, true])
        #expect(ThreadDetailsScrollTests.views(BranchPickerRowView.self, in: picker).elementsEqual(rows, by: { $0 === $1 }))
    }

    @Test func twoRefsMatchT3() {
        let picker = BranchPickerView()
        picker.rows = [.init(value: "main", title: "main", badge: "current"), .init(value: "mcp-hub-moved", title: "mcp-hub-moved", badge: "worktree")]
        #expect(picker.naturalSize == CGSize(width: 318, height: 123))
        picker.frame = NSRect(origin: .zero, size: picker.naturalSize)
        picker.layoutSubtreeIfNeeded()
        let rows = picker.subviews.flatMap(\.subviews).filter { $0 is BranchPickerRowView }
        #expect(rows.map(\.frame) == [NSRect(x: 8, y: 12, width: 300, height: 28), NSRect(x: 8, y: 40, width: 300, height: 28)])
    }
}
