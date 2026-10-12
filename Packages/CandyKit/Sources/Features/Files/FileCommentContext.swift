import Foundation
import T3Protocol

/// reviewCommentContext.ts:59-95. File comments share the composer's review-comment records.
public enum FileCommentContext {
    /// `buildFileReviewComment`: lines are 1-based and inclusive.
    public static func record(path: String, contents: String, startLine: Int, endLine: Int, text: String, id: String = UUID().uuidString) -> JSONValue {
        let start = max(1, min(startLine, endLine))
        let end = max(start, max(startLine, endLine))
        let lines = contents.components(separatedBy: "\n")
        let excerpt = start <= lines.count ? lines[(start - 1)..<min(end, lines.count)].joined(separator: "\n") : ""
        let base = path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? path
        let range = start == end ? "L\(start)" : "L\(start) to L\(end)"
        return .object(["version": .number(1), "contextId": .string(ComposerContext.kindScopedId("review-comment", id)),
                        "kind": .string("review-comment"), "label": .string(ComposerContext.sanitizeLabel("\(base) \(range)", kind: "review-comment")),
                        "sectionId": .string("file:" + path), "sectionTitle": .string("File comment"), "filePath": .string(path),
                        "startIndex": .number(Double(start - 1)), "endIndex": .number(Double(end - 1)), "rangeLabel": .string(range),
                        "text": .string(text.trimmingCharacters(in: .whitespacesAndNewlines)), "diff": .string(excerpt),
                        "fenceLanguage": .string(fenceLanguage(path))])
    }

    /// The lines a text selection covers.
    public static func record(path: String, contents: String, selection: NSRange, text: String, id: String = UUID().uuidString) -> JSONValue? {
        let source = contents as NSString
        guard selection.location >= 0, selection.upperBound <= source.length else { return nil }
        let start = source.substring(to: selection.location).filter { $0 == "\n" }.count + 1
        let lastOffset = selection.length > 0 ? selection.upperBound - 1 : selection.location
        let end = source.substring(to: lastOffset).filter { $0 == "\n" }.count + 1
        return record(path: path, contents: contents, startLine: start, endLine: end, text: text, id: id)
    }

    /// `inferReviewCommentFenceLanguage`.
    static func fenceLanguage(_ path: String) -> String {
        let name = (path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? path).lowercased()
        if let dot = name.lastIndex(of: "."), dot != name.startIndex, name.index(after: dot) != name.endIndex {
            return String(name[name.index(after: dot)...])
        }
        if name.hasPrefix("."), name.count > 1 { return String(name.dropFirst()) }
        return "text"
    }
}
