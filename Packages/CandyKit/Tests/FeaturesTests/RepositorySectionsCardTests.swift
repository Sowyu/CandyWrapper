import AppKit
import Testing
import T3Store
@testable import Features

/// The details card's repository rows (#42919) and Redesign's relations card, which now carries them and the usage
/// rows, since Redesign has no other place for either.
@MainActor struct RepositorySectionsCardTests {
    private func summary(_ branch: String?) -> ThreadRepositories.Summary {
        .init(branch: branch, isRepository: true, changedFiles: 1, insertions: 2, deletions: 0, pullRequestNumber: nil)
    }

    @Test func rowsShowBranchAndHideInitializeGitWhileTracking() {
        let card = ThreadDetailsCardView(frame: NSRect(x: 0, y: 0, width: 280, height: 400))
        card.isRepo = false
        card.tracksFolders = true
        card.repositories = .init(visible: [.init(key: "/w/a", name: "repo-a", summary: summary("main")),
                                            .init(key: "/w/b", name: "repo-b", summary: summary(nil))], hidden: 1)
        card.layoutSubtreeIfNeeded()
        #expect(card.initGit.isHidden)
        let rows = ThreadDetailsCardView.repositoryRow(.init(key: "/w/b", name: "repo-b", summary: summary(nil)))
        #expect(rows.detail == "Detached HEAD")
        #expect(rows.accessibilityLabel() == "Repository repo-b")
    }

    @Test func redesignRelationsCardCountsRepositoriesAndUsage() {
        let card = ThreadDetailsCardView(frame: NSRect(x: 0, y: 0, width: 280, height: 400))
        card.relationsOnly = true
        #expect(!card.hasRelations)
        card.repositories = .init(visible: [.init(key: "/w/a", name: "repo-a", summary: summary("main"))])
        #expect(card.hasRelations)
        // Usage joins only where the user turned it on (`threadDetailsUsageEnabled`, off by default).
        card.repositories = nil
        card.usage.rows = [ThreadDetailsUsageRow(label: "5h", fill: 40, tone: nil, value: "40%", tooltip: [])]
        #expect(!card.hasRelations)
    }
}
