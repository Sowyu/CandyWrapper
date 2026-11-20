import AppKit
import Testing
import DesignSystem
@testable import Features

/// #34788: a No project thread offers no git, and its linked pull requests still show
/// (4928 ThreadDetailsPanel.tsx:104-112, 169-176, 230-251).
@MainActor
struct ThreadDetailsNoProjectTests {
    @Test func scratchFolderOffersNoGitButKeepsPullRequests() {
        let card = ThreadDetailsCardView()
        card.isRepo = false
        let base = card.preferredHeight
        card.offersGit = false
        #expect(card.initGit.isHidden && card.branch.isHidden && card.gitActions.isHidden)
        #expect(card.preferredHeight < base)
        let row = DetailsRowControl(kind: .row)
        card.pullRequestRows = [row]
        #expect(!row.isHidden)
        #expect(card.preferredHeight > base - 32 - 19)
        // A repository outside the scratch root shows its rows as before.
        card.offersGit = true
        card.isRepo = true
        #expect(!card.branch.isHidden && card.initGit.isHidden)
    }
}
