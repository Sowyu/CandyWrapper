import AppKit
import Testing
@testable import Features

@MainActor
struct ComposerRefreshTests {
    @Test(arguments: [false, true])
    func keystrokesDoNotRefreshThreadStateOrRequestComposerLayout(planFollowUp: Bool) {
        let composer = ComposerView(frame: NSRect(x: 0, y: 0, width: 736, height: 144))
        composer.planFollowUp = planFollowUp
        var commits: [@MainActor () -> Void] = []
        var threadRefreshes = 0
        var promptRefreshes = 0
        var latestPrompt = ""
        let refreshes = ComposerRefreshCoordinator(threadState: {
            threadRefreshes += 1
            composer.needsLayout = true
        }, promptState: {
            promptRefreshes += 1
            latestPrompt = composer.text
        }, afterCommit: { commits.append($0) })
        composer.onTextChange = { _ in refreshes.promptChanged() }
        refreshes.refresh()
        composer.editor.insertText("h", replacementRange: NSRange(location: 0, length: 0))
        commits.removeFirst()()
        composer.setFrameSize(NSSize(width: 736, height: composer.preferredHeight))
        composer.layoutSubtreeIfNeeded()
        let threadBaseline = threadRefreshes
        let promptBaseline = promptRefreshes

        for character in "ello" {
            composer.needsLayout = false
            composer.editor.insertText(String(character), replacementRange: composer.editor.selectedRange())
            #expect(commits.count == 1)
            commits.removeFirst()()
            #expect(!composer.needsLayout)
        }
        #expect(latestPrompt == "hello")
        #expect(promptRefreshes - promptBaseline == 4)
        #expect(threadRefreshes - threadBaseline == 0)
    }

    @Test func editsCoalesceAndFullRefreshConsumesPendingPromptWork() {
        var commits: [@MainActor () -> Void] = []
        var threadRefreshes = 0
        var promptRefreshes = 0
        let refreshes = ComposerRefreshCoordinator(threadState: { threadRefreshes += 1 },
                                                   promptState: { promptRefreshes += 1 },
                                                   afterCommit: { commits.append($0) })
        refreshes.promptChanged()
        refreshes.promptChanged()
        #expect(commits.count == 1)
        refreshes.refresh()
        #expect(threadRefreshes == 1 && promptRefreshes == 1)
        // A fresh edit must survive the stale callback left by the full refresh.
        refreshes.promptChanged()
        commits.removeFirst()()
        #expect(promptRefreshes == 1)
        commits.removeFirst()()
        #expect(threadRefreshes == 1 && promptRefreshes == 2)
        #expect(commits.isEmpty)
    }
}
