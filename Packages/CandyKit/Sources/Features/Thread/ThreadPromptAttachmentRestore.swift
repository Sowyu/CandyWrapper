import Foundation
import T3Protocol

/// ChatView.logic.ts:743-778 and ChatView.tsx:8450-8505: stage before rollback,
/// then restore the prompt and fresh attachment references alongside the current draft.
public enum ThreadPromptAttachmentRestore {
    public static func restore(text: String, context: JSONValue?, attachments: [JSONValue], staged: [ComposerAttachment]) -> (text: String, records: [JSONValue]) {
        var text = text == ComposerAttachmentRules.attachmentOnlyPrompt ? "" : text
        var records: [JSONValue] = []
        let originals = context?["records"]?.arrayValue ?? []
        for record in originals {
            guard let oldAttachment = record["attachmentId"]?.stringValue,
                  let index = attachments.firstIndex(where: { $0["id"]?.stringValue == oldAttachment }), index < staged.count,
                  let oldContext = record["contextId"]?.stringValue else { records.append(record); continue }
            let replacement = staged[index]
            // Replace only parsed chip targets, never a coincidental id in ordinary text.
            if let kind = record["kind"]?.stringValue {
                let oldTarget = "t3-context://v1/\(kind)/\(oldContext)"
                let newTarget = "t3-context://v1/\(replacement.kind.rawValue)/\(replacement.contextId)"
                text = text.replacingOccurrences(of: "](\(oldTarget))", with: "](\(newTarget))")
            }
            if let fresh = replacement.contextRecord { records.append(fresh) }
        }
        for attachment in staged where attachment.kind == .file && !text.contains(attachment.contextId) {
            if !text.isEmpty { text += "\n" }
            text += attachment.reference
        }
        return (text, records)
    }
}
