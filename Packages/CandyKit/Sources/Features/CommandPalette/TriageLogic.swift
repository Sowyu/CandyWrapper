import Foundation
import T3Protocol

/// T3 3814 apps/web/src/lib/triageTarget.ts:7-16 and hooks/useStartTriage.ts:68-84.
public enum TriageLogic {
    public static let cliCommand = "npx t3 triage"

    /// `currentClientMetadata()` for `server.prepareTriage`.
    public static func clientMetadata(appVersion: String) -> JSONValue {
        .object(["label": .string("CandyWrapper"), "deviceType": .string("desktop"), "os": .string("macOS"), "appVersion": .string(appVersion)])
    }
    public static func environment(onScreen: String?, primary: String?, connected: [String], supports: (String) -> Bool) -> String? {
        if let onScreen { return onScreen }
        if let primary, supports(primary) { return primary }
        return connected.first(where: supports)
    }

    /// The preparation may finish after navigation. Only the requesting route may open its draft.
    @MainActor
    public static func prepare(supported: Bool, prepare: () async throws -> String,
                               scratch: () async throws -> ProjectId, stillHere: () -> Bool,
                               show: (ProjectId, String) -> Void) async throws {
        guard supported else { return }
        let prompt = try await prepare()
        let project = try await scratch()
        guard !Task.isCancelled, stillHere() else { return }
        show(project, prompt)
    }

    /// `isTriagePrompt` (packages/shared/src/triagePrompt.ts:5 at 4928, #33782): a draft is a triage draft while its
    /// message still links the playbook file.
    public static func isTriagePrompt(_ prompt: String) -> Bool { prompt.contains(playbookLinkStart) }

    static let playbookLinkStart = "[triage-playbook.md]("

    /// `replaceTriagePlaybookLink` (triagePrompt.ts:19-33): each playbook link in `prompt` becomes the one in
    /// `prepared`, the rest stays. The first `)` closes a link, since the serializer encodes `)` and whitespace.
    public static func replacePlaybookLink(_ prompt: String, with prepared: String) -> String {
        func link(in text: String, from: String.Index) -> Range<String.Index>? {
            guard let start = text.range(of: playbookLinkStart, range: from..<text.endIndex),
                  let close = text.range(of: ")", range: start.upperBound..<text.endIndex) else { return nil }
            return start.lowerBound..<close.upperBound
        }
        guard let preparedLink = link(in: prepared, from: prepared.startIndex) else { return prompt }
        var out = "", cursor = prompt.startIndex
        while let r = link(in: prompt, from: cursor) {
            out += prompt[cursor..<r.lowerBound] + prepared[preparedLink]
            cursor = r.upperBound
        }
        return out + prompt[cursor...]
    }
}
