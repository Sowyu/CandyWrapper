import Foundation

/// Search includes folded files and both sides, with context lines counted once
/// (codeViewSearch.test.ts:69-116).
public enum DiffPanelSearch {
    public struct Match: Equatable, Sendable {
        public var file: Int
        public var line: Int
        public var range: NSRange
    }
    public static func matches(_ query: String, in diff: UnifiedDiff, caseSensitive: Bool = false,
                               wholeWord: Bool = false, regex: Bool = false) -> [Match] {
        guard !query.isEmpty else { return [] }
        var pattern = regex ? query : NSRegularExpression.escapedPattern(for: query)
        if wholeWord { pattern = "\\b(?:" + pattern + ")\\b" }
        guard let re = try? NSRegularExpression(pattern: pattern, options: caseSensitive ? [] : [.caseInsensitive]) else { return [] }
        var result: [Match] = []
        for (f, file) in diff.files.enumerated() {
            for hunk in file.hunks { for l in hunk.lines {
                let text = diff.text(diff.lines[l])
                for match in re.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) where match.range.length > 0 {
                    result.append(Match(file: f, line: l, range: match.range))
                }
            }}
        }
        return result
    }
    public static func tree(_ diff: UnifiedDiff) -> FileTreeModel {
        var entries: Set<ProjectEntry> = []
        for file in diff.files {
            entries.insert(ProjectEntry(path: file.path, isDirectory: false))
            let parts = file.path.split(separator: "/")
            for i in 1..<max(1, parts.count) { entries.insert(ProjectEntry(path: parts.prefix(i).joined(separator: "/"), isDirectory: true)) }
        }
        var model = FileTreeModel()
        var order: [String: Int] = [:]
        for (index, file) in diff.files.enumerated() {
            let parts = file.path.split(separator: "/")
            for count in 1...max(1, parts.count) {
                let path = parts.prefix(count).joined(separator: "/")
                if order[path] == nil { order[path] = index }
            }
        }
        model.pathOrder = order
        let groups = Dictionary(grouping: entries, by: \.parent)
        for (parent, children) in groups { model.setChildren(children, of: parent) }
        _ = model.setAllExpanded(true)
        return model
    }
}
