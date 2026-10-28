import Foundation
import T3Protocol
import T3Store

/// The source identity survives inherited timeline rows (diffPanelStore.ts:1-30, 181-191).
public struct ToolCallDiffTarget: Hashable, Sendable {
    public var threadId: ThreadId
    public var itemId: TurnItemId
    public var revision: String
    public var runId: RunId?
    public var filePath: String?

    public init(threadId: ThreadId, itemId: TurnItemId, revision: String, runId: RunId? = nil, filePath: String? = nil) {
        self.threadId = threadId; self.itemId = itemId; self.revision = revision
        self.runId = runId; self.filePath = filePath
    }

    public init(_ row: ProjectedTurnItem) {
        threadId = row.sourceThreadId; itemId = row.sourceItemId
        revision = TurnItemDetail.revision(row.item)
        runId = row.item.runId; filePath = row.item["fileName"]?.stringValue
    }
}

/// Recorded provider patches and content, without reading the checkout (toolCallDiff.ts:1-77).
struct ToolCallDiff: Sendable {
    struct Content: Equatable, Sendable { var label: String; var text: String }
    var patch: String?
    var content: [Content] = []
    var truncated = false

    static func hasRecordedContent(_ item: TurnItem) -> Bool {
        ["diffStr", "oldStr", "newStr"].contains { item[$0]?.stringValue != nil }
    }

    init(fileName: String, diffStr: String? = nil, changes: [JSONValue] = [], oldStr: String? = nil, newStr: String? = nil) {
        let suffix = "\n… output truncated for transport"
        func recorded(_ value: String?) -> (String?, Bool) {
            guard let value, value.hasSuffix(suffix) else { return (value, false) }
            return (String(value.dropLast(suffix.count)), true)
        }
        let (diff, dt) = recorded(diffStr)
        let operation = changes.first?["operation"]?.stringValue
        let (before, bt) = recorded(oldStr ?? (operation == "delete" && diff == "" ? "" : nil))
        let (after, at) = recorded(newStr ?? (operation == "add" && diff == "" ? "" : nil))
        truncated = dt || bt || at
        patch = Self.normalize(diff, fileName: fileName, changes: changes)
        if diff?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            if let before { content.append(.init(label: "Recorded content before", text: before)) }
            if let after { content.append(.init(label: "Recorded content after", text: after)) }
        }
    }

    init(_ item: TurnItem) {
        self.init(fileName: item["fileName"]?.stringValue ?? "", diffStr: item["diffStr"]?.stringValue,
                  changes: item["changes"]?.arrayValue ?? [], oldStr: item["oldStr"]?.stringValue, newStr: item["newStr"]?.stringValue)
    }

    /// Re-diff each hunk after removing whitespace, retaining the recorded line text and numbers
    /// (diffRendering.ts:84-151). The file and hunk stay visible even if only whitespace changed.
    static func render(_ patch: String, ignoringWhitespace: Bool) -> UnifiedDiff {
        var diff = UnifiedDiff(patch)
        guard ignoringWhitespace else { return diff }
        let source = diff
        diff.lines = []
        for f in diff.files.indices {
            diff.files[f].additions = 0; diff.files[f].deletions = 0
            for h in diff.files[f].hunks.indices {
                let lines = source.files[f].hunks[h].lines.map { source.lines[$0] }
                let old = lines.filter { $0.kind != .addition }, new = lines.filter { $0.kind != .deletion }
                let before = old.map { source.text($0).filter { !$0.isWhitespace } }
                let after = new.map { source.text($0).filter { !$0.isWhitespace } }
                let changes = after.difference(from: before)
                var removed = Set<Int>(), inserted = Set<Int>()
                for change in changes {
                    switch change {
                    case .remove(let offset, _, _): removed.insert(offset)
                    case .insert(let offset, _, _): inserted.insert(offset)
                    }
                }
                let start = diff.lines.count
                var i = 0, j = 0
                while i < old.count || j < new.count {
                    if i < old.count, removed.contains(i) {
                        var line = old[i]; line.kind = .deletion; line.newNumber = 0
                        diff.lines.append(line); diff.files[f].deletions += 1; i += 1
                    } else if j < new.count, inserted.contains(j) {
                        var line = new[j]; line.kind = .addition; line.oldNumber = 0
                        diff.lines.append(line); diff.files[f].additions += 1; j += 1
                    } else if i < old.count, j < new.count {
                        var line = new[j]; line.kind = .context; line.oldNumber = old[i].oldNumber
                        diff.lines.append(line); i += 1; j += 1
                    } else { break }
                }
                diff.files[f].hunks[h].lines = start..<diff.lines.count
            }
        }
        return diff
    }

    private static func normalize(_ value: String?, fileName: String, changes: [JSONValue]) -> String? {
        guard var patch = value, !patch.isEmpty else { return value }
        let change = changes.first, operation = change?["operation"]?.stringValue
        let raw = operation == "add" || operation == "delete"
        if patch.hasPrefix("diff --git ") || patch.hasPrefix("--- ") {
            if !raw { return patch }
            let parsed = UnifiedDiff(patch)
            if !parsed.files.isEmpty, parsed.files.allSatisfy({ file in
                let path = file.path.replacingOccurrences(of: "\\", with: "/")
                return !file.hunks.isEmpty && changes.contains { recorded in
                    let recordedPath = (recorded["path"]?.stringValue ?? "").replacingOccurrences(of: "\\", with: "/")
                    let op = recorded["operation"]?.stringValue
                    return (op == "add" ? file.deletions == 0 : op == "delete" ? file.additions == 0 : true)
                        && (recordedPath == path || recordedPath.hasSuffix("/" + path))
                }
            }) { return patch }
        }
        if raw || !patch.drop(while: \.isWhitespace).hasPrefix("@@ ") {
            guard raw else { return patch }
            var lines = patch.components(separatedBy: "\n")
            let newline = patch.hasSuffix("\n")
            if newline { lines.removeLast() }
            let added = operation == "add", range = "1,\(lines.count)"
            patch = "@@ -\(added ? "0,0" : range) +\(added ? range : "0,0") @@\n"
                + lines.map { (added ? "+" : "-") + $0 }.joined(separator: "\n") + "\n"
                + (newline ? "" : "\\ No newline at end of file\n")
        }
        let old = change?["oldPath"]?.stringValue ?? fileName
        let new = change?["path"]?.stringValue ?? fileName
        func quote(_ path: String) -> String {
            let encoder = JSONEncoder(); encoder.outputFormatting = .withoutEscapingSlashes
            return String(decoding: try! encoder.encode(path), as: UTF8.self)
        }
        return "diff --git \(quote("a/" + old)) \(quote("b/" + new))\n--- \(operation == "add" ? "/dev/null" : quote("a/" + old))\n+++ \(operation == "delete" ? "/dev/null" : quote("b/" + new))\n"
            + patch.drop(while: \.isWhitespace)
    }
}
