import Foundation
import Testing
import T3Protocol
@testable import Features

/// The menu bar item's menu (Capy's tray menu, docs/research/capy-menubar.md).
struct MenuBarMenuTests {
    static func thread(_ id: String, _ title: String, minute: Int, status: String = "idle", archived: Bool = false) -> ThreadShell {
        var shell = ComposerFeedbackTests.shell(#""status":"\#(status)""#)
        shell.id = ThreadId(id)
        shell.title = title
        shell.updatedAt = T3Timestamp(String(format: "2026-06-20T00:%02d:00.000Z", minute))
        if archived { shell.archivedAt = shell.updatedAt }
        return shell
    }

    static func snapshot(_ threads: [ThreadShell]) -> ShellSnapshot { ShellSnapshot(schemaVersion: 1, snapshotSequence: 1, threads: threads) }

    @Test func loadingAndEmpty() {
        #expect(MenuBarMenu.rows(nil) == [.label("Loading threads…"), .separator, .newThread, .separator, .quit])
        #expect(MenuBarMenu.rows(Self.snapshot([Self.thread("a", "A", minute: 1, archived: true)])).first == .label("No recent threads"))
    }

    @Test func fiveMostRecentThenViewAllAndRunningCount() {
        let threads = (0..<7).map { Self.thread("t\($0)", "T\($0)", minute: $0, status: $0 < 2 ? "running" : "idle") }
            + [Self.thread("old", "Archived", minute: 59, archived: true)]
        let rows = MenuBarMenu.rows(Self.snapshot(threads))
        #expect(rows == [.label("Recent threads")] + (2...6).reversed().map { .thread(ThreadId("t\($0)"), title: "T\($0)") }
            + [.viewAll, .separator, .newThread, .separator, .label("2 threads running"), .separator, .quit])
    }

    @Test func titlesTruncateAt48() {
        #expect(MenuBarMenu.title("") == "Untitled thread")
        let long = String(repeating: "x", count: 60)
        #expect(MenuBarMenu.title(long) == String(repeating: "x", count: 47) + "…")
        #expect(MenuBarMenu.title(String(repeating: "y", count: 48)).count == 48)
    }
}
