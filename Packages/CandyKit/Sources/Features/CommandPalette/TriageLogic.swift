import Foundation
import T3Protocol

/// T3 3814 apps/web/src/lib/triageTarget.ts:7-16 and hooks/useStartTriage.ts:68-84.
public enum TriageLogic {
    public static let cliCommand = "npx t3 triage"
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
}
