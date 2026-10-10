import Foundation
import T3Protocol
import Testing
@testable import T3Store

private func file(_ path: String, _ a: Int?, _ d: Int?) -> CheckpointFile {
    CheckpointFile(path: path, kind: "modified", additions: a, deletions: d)
}

private func dir(_ name: String, _ path: String, _ a: Int, _ d: Int, _ children: [TurnDiffTreeNode]) -> TurnDiffTreeNode {
    .directory(name: name, path: path, stat: TurnDiffStat(additions: a, deletions: d), children: children)
}

private func leaf(_ name: String, _ path: String, _ a: Int, _ d: Int) -> TurnDiffTreeNode {
    .file(name: name, path: path, stat: TurnDiffStat(additions: a, deletions: d))
}

/// Ports of apps/web/src/lib/turnDiffTree.test.ts plus the summary and request rules.
@Suite struct TurnDiffTests {
    @Test func sumsOnlyNumericStats() {
        let stat = TurnDiffTree.totalStat([file("README.md", 3, 1), file("docs/notes.md", 0, 0), file("src/index.ts", 5, 2), file("x", nil, 4)])
        #expect(stat == TurnDiffStat(additions: 8, deletions: 3))
    }

    @Test func buildsNestedDirectoriesWithAggregatedStats() {
        let tree = TurnDiffTree.build([file("src/index.ts", 2, 1), file("src/components/Button.tsx", 4, 2), file("README.md", 1, 0)])
        #expect(tree == [
            dir("src", "src", 6, 3, [
                dir("components", "src/components", 4, 2, [leaf("Button.tsx", "src/components/Button.tsx", 4, 2)]),
                leaf("index.ts", "src/index.ts", 2, 1),
            ]),
            leaf("README.md", "README.md", 1, 0),
        ])
    }

    @Test func keepsZeroStatsAndNormalizesWindowsSeparators() {
        #expect(TurnDiffTree.build([file("docs/notes.md", 0, 0), file("docs/todo.md", 1, 1)]) == [
            dir("docs", "docs", 1, 1, [leaf("notes.md", "docs/notes.md", 0, 0), leaf("todo.md", "docs/todo.md", 1, 1)]),
        ])
        #expect(TurnDiffTree.build([file("apps\\web\\src\\index.ts", 2, 1)]) == [
            dir("apps/web/src", "apps/web/src", 2, 1, [leaf("index.ts", "apps/web/src/index.ts", 2, 1)]),
        ])
    }

    @Test func compactsOnlySingleDirectoryChains() {
        #expect(TurnDiffTree.build([file("apps/server/src/index.ts", 2, 1), file("apps/server/main.ts", 4, 0)]) == [
            dir("apps/server", "apps/server", 6, 1, [
                dir("src", "apps/server/src", 2, 1, [leaf("index.ts", "apps/server/src/index.ts", 2, 1)]),
                leaf("main.ts", "apps/server/main.ts", 4, 0),
            ]),
        ])
    }

    @Test func sortsNaturallyAndKeepsWhitespaceInSegments() {
        let names = TurnDiffTree.build([file("f10.ts", 1, 0), file("f2.ts", 1, 0), file("B.ts", 1, 0), file("a.ts", 1, 0)]).map(\.name)
        #expect(names == ["a.ts", "B.ts", "f2.ts", "f10.ts"])
        let spaced = TurnDiffTree.build([file("a/file.ts", 1, 0), file(" a/file.ts", 2, 0)])
        #expect(spaced.map(\.name).sorted() == [" a", "a"])
    }

    @Test func requestsExactlyOneRunsDelta() throws {
        let replayed = replay(try recordedThreadStreams("03-turn2.jsonl")[1])
        let projection = try #require(replayed.projection)
        let summaries = TurnDiffs.summaries(projection)
        #expect(summaries.map(\.checkpointTurnCount).sorted() == [1, 2, 3])
        let first = try #require(summaries.first { $0.checkpointTurnCount == 1 })
        #expect(first.files.map(\.path).sorted() == ["hello.py", "notes.md"])
        #expect(first.assistantMessageId == projection.messages.last { $0.runId == first.runId && $0.role == "assistant" }?.id)
        #expect(TurnDiffs.request(threadId: projection.thread.id, summary: first)
            == .fullThread(GetFullThreadDiffInput(threadId: projection.thread.id, toTurnCount: 1, ignoreWhitespace: true)))
        let third = try #require(summaries.first { $0.checkpointTurnCount == 3 })
        #expect(TurnDiffs.request(threadId: projection.thread.id, summary: third, ignoreWhitespace: false)
            == .turn(GetTurnDiffInput(threadId: projection.thread.id, fromTurnCount: 2, toTurnCount: 3, ignoreWhitespace: false)))
        #expect(TurnDiffs.sortedForPanel(summaries).map(\.checkpointTurnCount) == [3, 2, 1])
    }
}
