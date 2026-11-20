import AppKit
import Testing
@testable import Features

/// ThreadLinkPicker.tsx: the query matches title and project, linked threads are disabled, Return picks the
/// highlighted row and Down skips disabled ones.
@MainActor
struct ThreadLinkPickerTests {
    @Test func filtersAndPicks() {
        let picker = ThreadLinkPicker(title: "Link pull request to a thread")
        picker.candidates = [.init(id: "a", title: "Plan a migration", project: "git-demo", linked: true),
                             .init(id: "b", title: "Reply with markdown only", project: "demo-repo", linked: false),
                             .init(id: "c", title: "Add notes", project: "demo-repo", linked: false)]
        var picked: [String] = []
        picker.onSelect = { picked.append($0) }
        #expect(ThreadLinkPicker.filter(picker.candidates, query: " DEMO-repo ").map(\.id) == ["b", "c"])
        #expect(ThreadLinkPicker.filter(picker.candidates, query: "migration").map(\.id) == ["a"])
        // The first enabled row is highlighted; Return picks it.
        _ = picker.input.onCommand?(#selector(NSResponder.insertNewline(_:)))
        #expect(picked == ["b"])
        _ = picker.input.onCommand?(#selector(NSResponder.moveDown(_:)))
        _ = picker.input.onCommand?(#selector(NSResponder.insertNewline(_:)))
        #expect(picked == ["b", "c"])
        picker.pending = true
        _ = picker.input.onCommand?(#selector(NSResponder.insertNewline(_:)))
        #expect(picked.count == 2)
        #expect(picker.contentHeight == CGFloat(208)) // the input row, `p-2` and three 48pt rows
    }
}
