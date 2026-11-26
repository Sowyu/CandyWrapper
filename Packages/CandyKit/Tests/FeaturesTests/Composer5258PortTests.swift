import AppKit
import Foundation
import Testing
import T3Protocol
@testable import Features

/// Composer rows of the 4928 to 5258 port (docs/research/nightly-diff-5258-ui-thread.md section 2).
struct Composer5258PortTests {
    /// 2.9, #41269: No project never offers New worktree, even while its git status still reads as a repository.
    @Test func noProjectDraftsOfferNoWorktree() {
        #expect(!BranchToolbarLogic.offersWorkspaceModes(isScratchProject: true, isGitRepo: true))
        #expect(!BranchToolbarLogic.offersWorkspaceModes(isScratchProject: false, isGitRepo: false))
        #expect(BranchToolbarLogic.offersWorkspaceModes(isScratchProject: false, isGitRepo: true))
    }

    /// 2.9, #42386: the approval dialog's copy (WorktreeLayoutApprovalDialogHost.tsx:21-24, 46) and its body: a label and a
    /// `pre` per command, `pt-2` and `gap-3`, a block at most `max-h-48`.
    @MainActor @Test func worktreeApprovalListsEachCommand() throws {
        #expect(WorktreeLayoutApprovalView.title == "Let this project run its worktree commands?")
        #expect(WorktreeLayoutApprovalView.label(kind: "create") == "Runs when a worktree thread starts, and when its folder is restored")
        #expect(WorktreeLayoutApprovalView.label(kind: "remove") == "Runs when a thread's worktree is removed")
        let commands = try JSONDecoder().decode([WorktreeLayoutCommand].self, from: Data(#"[{"kind":"create","command":"make setup","approved":false},{"kind":"remove","command":"make clean","approved":false}]"#.utf8))
        let view = WorktreeLayoutApprovalView(commands: commands)
        view.setFrameSize(NSSize(width: 600, height: 0))
        let one = view.intrinsicContentSize.height
        #expect(one > 8 + 2 * (16 + 4 + 18) + 12 - 1 && one < 8 + 2 * (16 + 4 + 40) + 12)
        let long = String(repeating: "line\\n", count: 80)
        let tallCommands = try JSONDecoder().decode([WorktreeLayoutCommand].self, from: Data(#"[{"kind":"create","command":"\#(long)","approved":false}]"#.utf8))
        let tall = WorktreeLayoutApprovalView(commands: tallCommands)
        tall.setFrameSize(NSSize(width: 600, height: 0))
        #expect(abs(tall.intrinsicContentSize.height - (8 + 16 + 4 + 192)) < 0.5)
    }

    /// 2.5, #37122: a caret move onto a trigger leaves the menu shut, a move within the open token keeps it, and a move
    /// off it closes it.
    @Test func caretMovesNeverOpenSuggestions() {
        var state = ComposerTriggerState()
        let path = ComposerTrigger(kind: .path, query: "fo", rangeStart: 0, rangeEnd: 3)
        state.follow(path)
        #expect(state.trigger == nil)
        state.set(path)
        #expect(state.trigger == path)
        let longer = ComposerTrigger(kind: .path, query: "f", rangeStart: 0, rangeEnd: 2)
        state.follow(longer)
        #expect(state.trigger == longer)
        state.follow(nil)
        #expect(state.trigger == nil)
        state.follow(path)
        #expect(state.trigger == nil)
    }

    /// 2.6, #40798: a typed letter finds the next effort row by its label and wraps.
    @MainActor @Test func effortTypeaheadWraps() {
        let labels = ["Low", "Medium", "High", "Max", "Fast mode"]
        let enabled = [0, 1, 2, 3, 4]
        #expect(ComposerEffortColumnView.typeahead("m", labels: labels, enabled: enabled, focus: nil) == 1)
        #expect(ComposerEffortColumnView.typeahead("m", labels: labels, enabled: enabled, focus: 1) == 3)
        #expect(ComposerEffortColumnView.typeahead("M", labels: labels, enabled: enabled, focus: 3) == 1)
        #expect(ComposerEffortColumnView.typeahead("h", labels: labels, enabled: [0, 1, 3], focus: 0) == nil)
        #expect(ComposerEffortColumnView.typeahead(" ", labels: labels, enabled: enabled, focus: 0) == nil)
    }

}
