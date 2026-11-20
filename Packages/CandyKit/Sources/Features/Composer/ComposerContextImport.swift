import Foundation
import T3Protocol

/// The composer context clipboard's paste side (`useComposerContextImport.ts` at 4928): which pasted
/// records the destination draft takes, under which ids, and which attachments it has to bring in.
public enum ComposerContextImport {
    /// A decoded clipboard fragment (`ComposerContextClipboardFragment`): records the pasted text
    /// references, and the environment that copied them.
    public struct Fragment: Equatable, Sendable {
        public var records: [JSONValue]
        public var sourceEnvironmentId: String?
        public init(records: [JSONValue], sourceEnvironmentId: String?) {
            self.records = records; self.sourceEnvironmentId = sourceEnvironmentId
        }
    }

    /// An image or file record whose bytes the destination draft must fetch or copy.
    public struct Attachment: Equatable, Sendable {
        public var record: JSONValue
        /// The new draft attachment's id; its chip's context id is `kindScopedId(kind, localId)`.
        public var localId: String
        public var kind: String { record["kind"]?.stringValue ?? "file" }
        public var attachmentId: String { record["attachmentId"]?.stringValue ?? "" }
        public var name: String { record["name"]?.stringValue ?? "file" }
        public var mimeType: String { record["mimeType"]?.stringValue ?? "" }
        public var contextId: String { ComposerContext.kindScopedId(kind, localId) }
    }

    public struct Plan: Equatable, Sendable {
        /// Pasted context id to the id the draft keeps it under.
        public var rewritten: [String: String] = [:]
        /// Records to add to the draft, keyed by their (new) context id.
        public var records: [String: JSONValue] = [:]
        public var attachments: [Attachment] = []
    }

    /// `isSameComposerContextPayload`: equal apart from the label and the id.
    public static func samePayload(_ a: JSONValue, _ b: JSONValue) -> Bool {
        guard case .object(var l) = a, case .object(var r) = b, l["kind"] == r["kind"] else { return false }
        for key in ["label", "contextId"] { l[key] = nil; r[key] = nil }
        return l == r
    }

    /// `importContextRecords` (useComposerContextImport.ts:292-447). `existing` holds the draft's
    /// records, attachment records included; `alreadyAttached` says whether the draft holds the copied
    /// bytes of an image or file record; `mint` makes fresh producer ids.
    public static func plan(_ fragment: Fragment, existing: [String: JSONValue], environmentId: String,
                            linkedEnvironments: Set<String> = [], isQuestion: Bool = false,
                            alreadyAttached: (JSONValue) -> Bool = { _ in false },
                            mint: () -> String = { UUID().uuidString.lowercased() }) -> Plan {
        var plan = Plan()
        for record in fragment.records {
            guard let contextId = record["contextId"]?.stringValue, let kind = record["kind"]?.stringValue else { continue }
            let found = existing[contextId]
            // A record the draft already holds with the same payload keeps its chip (threads resolve below).
            if let found, kind != "thread", samePayload(found, record) { continue }
            let conflicts = found != nil
            func adopt(_ id: String) {
                var copy = record
                if case .object(var fields) = copy { fields["contextId"] = .string(id); copy = .object(fields) }
                plan.records[id] = copy
                plan.rewritten[contextId] = id
            }
            switch kind {
            case "thread":
                // The agent reads threads on its own server and the machines it links to (:392-399).
                guard let env = record["environmentId"]?.stringValue, let threadId = record["threadId"]?.stringValue,
                      env == environmentId || linkedEnvironments.contains(env) else { continue }
                // #30583: a thread reuses the destination's record for the same thread, reminting only on an id collision.
                let threads = (existing.values.map { $0 } + plan.records.values).filter { $0["kind"]?.stringValue == "thread" }
                if let attached = threads.first(where: { $0["environmentId"]?.stringValue == env && $0["threadId"]?.stringValue == threadId }),
                   let id = attached["contextId"]?.stringValue {
                    plan.rewritten[contextId] = id
                } else {
                    adopt(threads.contains { $0["contextId"]?.stringValue == contextId } ? ComposerContext.kindScopedId("thread", mint()) : contextId)
                }
            case "environment":
                // An answer to an agent's question carries no machines.
                guard !isQuestion else { continue }
                adopt(contextId)
            case "image", "file":
                guard fragment.sourceEnvironmentId != nil else {
                    if !conflicts { plan.rewritten[contextId] = contextId }
                    continue
                }
                // A paste back into the draft that holds the copied file keeps its chip, even when
                // the upload changed the server id since the copy (:321-330).
                if alreadyAttached(record) { continue }
                var attachment = Attachment(record: record, localId: mint())
                plan.rewritten[contextId] = attachment.contextId
                if case .object(var fields) = attachment.record {
                    fields["contextId"] = .string(attachment.contextId)
                    attachment.record = .object(fields)
                }
                plan.attachments.append(attachment)
            case "terminal", "review-comment", "element", "preview-annotation":
                // ponytail: annotations come in as plain records without their screenshot, port
                // `elementContextToPreviewAnnotation` when CandyWrapper drafts get preview annotations.
                adopt(conflicts ? ComposerContext.kindScopedId(kind, mint()) : contextId)
            default:
                continue
            }
        }
        return plan
    }

    /// `importPastedComposerText`'s rewrite: each pasted reference points at the id the draft keeps.
    public static func rewrite(_ text: String, ids: [String: String]) -> String {
        guard !ids.isEmpty else { return text }
        let ns = NSMutableString(string: text)
        for t in ComposerInlineTokens.collect(text).reversed() {
            guard case .context(let kind, let id, let label) = t.kind, let next = ids[id], next != id else { continue }
            let reference = ComposerContext.Reference(kind: kind == "element" ? "preview-annotation" : kind, contextId: next, label: label)
            ns.replaceCharacters(in: t.range, with: ComposerContext.reference(reference))
        }
        return ns as String
    }
}

/// `copiedComposerAttachments.ts`: the latest copy's draft files, so a paste in another draft copies
/// the bytes from disk instead of downloading them, even after the source chip is gone. A new copy
/// replaces the last one.
@MainActor
public enum ComposerCopiedAttachments {
    private static var latest: (environmentId: String, files: [String: URL])?

    public static func remember(environmentId: String, files: [String: URL]) {
        latest = files.isEmpty ? nil : (environmentId, files)
    }

    public static func file(environmentId: String, attachmentId: String) -> URL? {
        latest?.environmentId == environmentId ? latest?.files[attachmentId] : nil
    }
}
