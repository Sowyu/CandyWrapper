import Foundation
import T3Protocol

/// reviewCommentContext.ts:59-98. File comments share the composer's review-comment records.
// ponytail: creates a current-selection comment; add remapping and producer updates with editable inline annotations
public enum FileCommentContext {
    public static func record(path: String, contents: String, selection: NSRange, text: String, id: String = UUID().uuidString) -> JSONValue? {
        let source = contents as NSString
        guard selection.location >= 0, selection.upperBound <= source.length else { return nil }
        let start = source.substring(to: selection.location).filter { $0 == "\n" }.count + 1
        let lastOffset = selection.length > 0 ? selection.upperBound - 1 : selection.location
        let end = source.substring(to: lastOffset).filter { $0 == "\n" }.count + 1
        let lines = contents.components(separatedBy: "\n")
        let excerpt = lines[(start - 1)..<min(end, lines.count)].joined(separator: "\n")
        let base = path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? path
        let range = start == end ? "L\(start)" : "L\(start) to L\(end)"
        let ext = (base as NSString).pathExtension
        let language = ext.isEmpty ? base.hasPrefix(".") ? String(base.dropFirst()) : "text" : ext.lowercased()
        return .object(["version": .number(1), "contextId": .string(ComposerContext.kindScopedId("review-comment", id)),
                        "kind": .string("review-comment"), "label": .string(ComposerContext.sanitizeLabel("\(base) \(range)", kind: "review-comment")),
                        "sectionId": .string("file:" + path), "sectionTitle": .string("File comment"), "filePath": .string(path),
                        "startIndex": .number(Double(start - 1)), "endIndex": .number(Double(end - 1)), "rangeLabel": .string(range),
                        "text": .string(text.trimmingCharacters(in: .whitespacesAndNewlines)), "diff": .string(excerpt), "fenceLanguage": .string(language)])
    }
}
