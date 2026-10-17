import Foundation
import Testing
@testable import Features

/// The files panel's ported logic: preview modes, CSV parsing, picker matches, breadcrumbs, the
/// tree and the save coordinator.
struct FilesLogicTests {
    @Test func previewKinds() {
        #expect(FilePreviewKind.of("a/b.PNG") == .image)
        #expect(FilePreviewKind.of("x.mp3") == .audio)
        #expect(FilePreviewKind.of("x.mov") == .video)
        #expect(FilePreviewKind.of("doc.pdf") == .pdf)
        #expect(FilePreviewKind.of("index.htm") == .html)
        #expect(FilePreviewKind.of("README.md") == .markdown)
        #expect(FilePreviewKind.of("data.tsv") == .table(delimiter: "\t"))
        #expect(FilePreviewKind.of("main.swift") == .text)
    }

    @Test func delimitedParsing() {
        let r = DelimitedTable.parse("\u{FEFF}a,\"b,c\",\"say \"\"hi\"\"\"\r\n1,\"two\nlines\",3\n", delimiter: ",")
        #expect(r.rows == [["a", "b,c", "say \"hi\""], ["1", "two\nlines", "3"]])
        #expect(!r.truncated)
        let wide = (0..<35).map(String.init).joined(separator: ",")
        #expect(DelimitedTable.parse(wide, delimiter: ",").rows[0].count == 30)
        #expect(DelimitedTable.parse(wide, delimiter: ",").truncated)
        let tall = (0..<150).map(String.init).joined(separator: "\n")
        let t = DelimitedTable.parse(tall, delimiter: ",")
        #expect(t.rows.count == 100 && t.truncated)
        #expect(DelimitedTable.parse("\"open", delimiter: ",").truncated)
    }

    @Test func pickerMatchesKeepServerOrder() {
        let entries = [ProjectEntry(path: "src", isDirectory: true), ProjectEntry(path: "src/answer.ts", isDirectory: false),
                       ProjectEntry(path: "README.md", isDirectory: false)]
        let m = FilePicker.matches(entries, query: "  ./ans ts ")
        #expect(m.map(\.path) == ["src/answer.ts", "README.md"])
        #expect(m[0].nameMatches == [0, 1, 2, 7, 8])
        #expect(m[0].pathMatches == [4, 5, 6, 11, 12])
        // No subsequence: shown without highlights.
        #expect(m[1].nameMatches.isEmpty)
        #expect(FilePicker.matches(entries, query: "", limit: 1).count == 1)
    }

    @Test func breadcrumbs() {
        let c = FileBreadcrumbs.crumbs(projectName: "demo", path: "src/lib/a.ts")
        #expect(c.map(\.label) == ["demo", "src", "lib", "a.ts"])
        #expect(c.map(\.path) == ["", "src", "src/lib", "src/lib/a.ts"])
        #expect(FileBreadcrumbs.crumbs(projectName: "demo", path: "/etc/hosts").map(\.path) == ["/", "/etc", "/etc/hosts"])
        let kids = FileBreadcrumbs.children([ProjectEntry(path: "f10", isDirectory: false), ProjectEntry(path: "f9", isDirectory: false),
                                             ProjectEntry(path: "z", isDirectory: true), ProjectEntry(path: "z/q", isDirectory: false)], of: "")
        #expect(kids.map(\.path) == ["z", "f9", "f10"])
        #expect(FileBreadcrumbs.parent("a/b") == "a" && FileBreadcrumbs.parent("a") == "" && FileBreadcrumbs.parent("") == nil)
    }

    @Test func lineClamp() {
        #expect(clampFileLine("a\r\nb\rc\n", 99) == 4)
        #expect(clampFileLine("", 0) == 1)
    }

    @Test func treeRowsFlattenSortAndSearch() {
        var t = FileTreeModel()
        t.setChildren([ProjectEntry(path: "b.txt", isDirectory: false), ProjectEntry(path: "src", isDirectory: true),
                       ProjectEntry(path: "a10", isDirectory: false), ProjectEntry(path: "a9", isDirectory: false)], of: "")
        #expect(t.rows.map(\.label) == ["src", "a9", "a10", "b.txt"])
        #expect(t.toggle("src") == "src")
        t.setChildren([ProjectEntry(path: "src/lib", isDirectory: true)], of: "src")
        // `src` holds only `lib`: one row, acting on the deeper folder.
        #expect(t.rows.first == FileTreeModel.Row(path: "src/lib", label: "src / lib", depth: 0, isDirectory: true,
                                                   isExpanded: false, ignored: false, isLoading: false, isSearchMatch: false))
        #expect(t.toggle("src/lib") == "src/lib")
        t.setChildren([ProjectEntry(path: "src/lib/x.ts", isDirectory: false)], of: "src/lib")
        #expect(t.rows[1].path == "src/lib/x.ts" && t.rows[1].depth == 1)
        #expect(t.allExpanded)
        _ = t.setAllExpanded(false)
        #expect(t.rows.count == 4)
        t.setSearch("y", entries: [ProjectEntry(path: "deep/y.ts", isDirectory: false)])
        #expect(t.rows.map(\.path) == ["deep", "deep/y.ts"])
        #expect(t.rows[1].isSearchMatch)
        t.setSearch("", entries: nil)
        #expect(t.reveal("src/lib/x.ts").isEmpty)
        #expect(t.expanded.contains("src/lib"))
    }

    /// Polls (the suite runs in parallel, so fixed sleeps are flaky), at most 5 s.
    @MainActor static func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    }

    @MainActor @Test func saveCoordinatorNewestWins() async throws {
        var writes: [String] = []
        var pending: [Bool] = []
        var gate: CheckedContinuation<Void, Never>?
        let c = FileSaveCoordinator(debounce: 0.01, persist: { text in
            writes.append(text)
            if writes.count == 1 { await withCheckedContinuation { gate = $0 } }
            return true
        }, onPendingChange: { pending.append($0) })
        c.change("a")
        try await Self.waitUntil { gate != nil }
        #expect(writes == ["a"])
        // An edit while the first write is in flight: the first confirm must not clear pending.
        c.change("ab")
        gate?.resume()
        try await Self.waitUntil { pending.last == false }
        #expect(writes == ["a", "ab"])
        #expect(pending.first == true && pending.last == false)
        #expect(pending.filter { !$0 }.count == 1)
        #expect(!c.hasUnsaved)
    }

    @MainActor @Test func saveCoordinatorKeepsPendingWhenNotConfirmed() async throws {
        var pending: [Bool] = []
        let c = FileSaveCoordinator(debounce: 0.01, persist: { _ in false }, onPendingChange: { pending.append($0) })
        c.change("x")
        try await Task.sleep(for: .milliseconds(300))
        #expect(pending == [true])
        #expect(c.hasUnsaved)
    }
}
