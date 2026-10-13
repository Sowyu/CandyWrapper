import AppKit
import Testing
@testable import Features

/// The branch picker's size and row insets, measured in T3's web client (2861, the composer's Mod+Shift+G with two
/// refs): popup 320 wide and 121 tall with borders, rows 8 to 308 of the 318-wide body, the first row 12 below the list top.
@MainActor
struct BranchPickerGeometryTests {
    @Test func twoRefsMatchT3() {
        let picker = BranchPickerView()
        picker.rows = [.init(value: "main", title: "main", badge: "current"), .init(value: "mcp-hub-moved", title: "mcp-hub-moved", badge: "worktree")]
        #expect(picker.naturalSize == CGSize(width: 318, height: 119))
        picker.frame = NSRect(origin: .zero, size: picker.naturalSize)
        picker.layoutSubtreeIfNeeded()
        let rows = picker.subviews.flatMap(\.subviews).filter { $0 is BranchPickerRowView }
        #expect(rows.map(\.frame) == [NSRect(x: 8, y: 12, width: 300, height: 28), NSRect(x: 8, y: 40, width: 300, height: 28)])
    }
}
