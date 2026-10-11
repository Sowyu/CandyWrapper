import Foundation
import AppKit
import DesignSystem

/// shared/assistantCitations.ts:38-112 and contracts/assistantCitations.ts:4-35.
/// Offsets refer to rendered UTF-16 text. Keep them untouched when editing a comment.
public struct ThreadAssistantCitation: Equatable, Sendable {
    public var environmentId: String
    public var threadId: String
    public var messageId: String
    public var text: String
    public var start: Int
    public var end: Int
    public var prefix: String
    public var suffix: String
    public var comment: String?
    public var label: String {
        let value = (comment?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? text
        let compact = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let ns = compact as NSString
        return ns.length > 64 ? ns.substring(to: 64) + "…" : compact
    }
    public static func parse(_ href: String) -> Self? {
        guard href.hasPrefix("t3-citation://v1/"), href.utf16.count <= 160_000,
              let parts = URLComponents(string: href), parts.scheme == "t3-citation", parts.host == "v1",
              parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil else { return nil }
        let path = parts.percentEncodedPath.dropFirst().split(separator: "/", omittingEmptySubsequences: false).compactMap { String($0).removingPercentEncoding }
        guard path.count == 3, path.allSatisfy({ !$0.isEmpty && $0.utf16.count <= 512 }) else { return nil }
        var query: [String: String] = [:]
        // URLSearchParams decodes '+' as a space; URLComponents does not.
        for pair in (parts.percentEncodedQuery ?? "").split(separator: "&") {
            let bits = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard bits.count == 2, let key = String(bits[0]).removingPercentEncoding,
                  let value = String(bits[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding,
                  query[key] == nil else { return nil }
            query[key] = value
        }
        let required: Set<String> = ["text", "start", "end", "prefix", "suffix"]
        guard Set(query.keys) == required || Set(query.keys) == required.union(["comment"]),
              let text = query["text"], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf16.count <= 8000,
              let from = query["start"], from.range(of: "^[0-9]{1,16}$", options: .regularExpression) != nil,
              let to = query["end"], to.range(of: "^[0-9]{1,16}$", options: .regularExpression) != nil,
              let start = Int(from), let end = Int(to), start >= 0, end > start, end <= 9_007_199_254_740_991,
              let prefix = query["prefix"], prefix.utf16.count <= 32, let suffix = query["suffix"], suffix.utf16.count <= 32,
              (query["comment"]?.utf16.count ?? 0) <= 8000 else { return nil }
        return Self(environmentId: path[0], threadId: path[1], messageId: path[2], text: text, start: start, end: end, prefix: prefix, suffix: suffix, comment: query["comment"])
    }
    public var href: String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.~")
        func encode(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        let path = [environmentId, threadId, messageId].map(encode).joined(separator: "/")
        var values = [("text", text), ("start", String(start)), ("end", String(end)), ("prefix", prefix), ("suffix", suffix)]
        if let comment { values.append(("comment", comment)) }
        return "t3-citation://v1/" + path + "?" + values.map { encode($0.0) + "=" + encode($0.1) }.joined(separator: "&")
    }
    public var markdown: String { "[Assistant quote](\(href))" }
    public func withComment(_ value: String) -> Self {
        var copy = self
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.comment = trimmed.isEmpty ? nil : trimmed
        return copy
    }
}

@MainActor
public enum ThreadAssistantCitationEditor {
    /// Uses the existing modal host. Source-range anchored popovers remain a separate selection feature.
    // ponytail: comments use a dialog, switch to source-anchored popovers when rendered selection mapping is built
    public static func present(_ citation: ThreadAssistantCitation, in window: NSWindow, save: (@MainActor (ThreadAssistantCitation) -> Void)? = nil, openSource: (@MainActor () -> Void)? = nil) {
        let dialog = DialogView(title: "Assistant quote", message: citation.text)
        dialog.maxWidth = 400
        let comment = TextareaView(placeholder: "Add an optional comment...", text: citation.comment ?? "")
        comment.setAccessibilityLabel("Comment on selected text")
        let cancel = ButtonView("Cancel", variant: .outline, size: .xs)
        let commit = ButtonView("Save", size: .xs)
        let source = ButtonView("Open source", icon: .arrowUpRight, variant: .ghost, size: .xs)
        if save != nil { dialog.panelContent = [comment]; dialog.footerButtons = [cancel, commit] }
        else { dialog.message = citation.text + (citation.comment.map { "\n\nComment: " + $0 } ?? "") }
        if openSource != nil { dialog.footerButtons.insert(source, at: 0) }
        let host = ModalHost.present(dialog, in: window)
        cancel.action = { [weak host] in host?.close() }
        source.action = { [weak host] in host?.close(); openSource?() }
        let submit: @MainActor () -> Void = { [weak host, weak comment] in
            guard let comment, comment.text.utf16.count <= 8000 else { return }
            save?(citation.withComment(comment.text)); host?.close()
        }
        commit.action = submit
        comment.onChange = { [weak commit] text in commit?.isEnabled = text.utf16.count <= 8000; commit?.title = text.utf16.count <= 8000 ? "Save" : "Shorten comment" }
        comment.onSubmit = submit
    }
}
