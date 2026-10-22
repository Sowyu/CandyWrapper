import AppKit
import Testing
@testable import T3Protocol
@testable import Features
import DesignSystem

/// 3473 cleanup results name the machine, project, folder and thread (StorageSettings.tsx:190-266, 5803c8b299).
@MainActor
struct StorageCleanupResultsTests {
    @Test func resultsNameWhereTheyRan() {
        let owned = StorageCleanupReport.Entry(kind: "worktree", outcome: "removed", reason: "Thread archived", path: "/w/t3/feature-x",
                                               threadId: "th", threadTitle: "Fix login", projectPath: "/p/t3", bytes: 2048)
        let loose = StorageCleanupReport.Entry(kind: "worktree", outcome: "kept", reason: "Has changes", path: "/w/t3/stray")
        #expect(CleanupLastRunView.name(owned) == "feature-x")
        #expect(CleanupLastRunView.name(loose) == "/w/t3/stray")
        #expect(CleanupLastRunView.details(owned, environmentLabel: "This Mac").map(\.label) == ["Machine", "Project", "Folder", "Thread"])
        #expect(CleanupLastRunView.details(loose, environmentLabel: "This Mac").map(\.value) == ["This Mac", "/w/t3/stray"])
        #expect(CleanupLastRunView.sizeText(owned) == "2.00 KB")
        #expect(CleanupLastRunView.sizeText(loose) == nil)
        // The grid's height follows its width: a long folder wraps in a narrow row.
        let detail = CleanupLastRunView.ResultDetailView(owned, environmentLabel: "This Mac")
        #expect(detail.height(forWidth: 120) > detail.height(forWidth: 600))
        let row = SettingsRowView(title: "feature-x")
        row.detailView = detail
        #expect(row.height(forWidth: 160) > row.height(forWidth: 700))
        let rows = CleanupLastRunView.rows(StorageCleanupReport(json: StorageCleanupResultsTests.empty)!, environmentLabel: "This Mac")
        #expect((rows.first as? SettingsGroupNote)?.message == "This Mac: Nothing needed cleanup.")
    }
}

extension StorageCleanupResultsTests {
    static let empty: JSONValue = .object(["trigger": .string("manual"), "startedAt": .string("t"), "finishedAt": .string("t"), "entries": .array([]),
                                           "counts": .object(["removed": .number(0), "kept": .number(0), "failed": .number(0)]), "omittedCount": .number(0)])
}
