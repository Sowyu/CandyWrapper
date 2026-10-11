import Foundation
import T3Protocol

/// onboarding/firstRun.logic.ts:70-190. Cached data can open the app, never complete setup.
public enum FirstRunDecision {
    public enum Route: Equatable, Sendable { case pending, app, wizard }
    public struct Evidence: Sendable {
        public var hydrated = true
        public var completed = false
        public var catalogReady = false
        public var primaryLive = false
        public var workspaceLive = false
        public var configAvailable = false
        public var bootstrapped = false
        public var welcome: JSONValue?
        public var primaryId: String?
        public var projects: [JSONValue] = []
        public var threads: [JSONValue] = []
        public init() {}
    }
    public static func resolve(_ input: Evidence) -> (route: Route, persist: Bool) {
        if input.hydrated && input.completed { return (.app, false) }
        guard input.hydrated else { return (.pending, false) }
        let authoritative = input.bootstrapped && input.primaryLive && input.catalogReady && input.configAvailable
        if input.projects.count > 1 || input.threads.count > 1 {
            return (.app, authoritative && input.workspaceLive)
        }
        guard authoritative, let welcome = input.welcome, welcome["bootstrapStatus"]?.stringValue != "pending" else { return (.pending, false) }
        return fresh(input) ? (.wizard, false) : (.app, input.workspaceLive)
    }
    public static func fresh(_ input: Evidence) -> Bool {
        guard input.projects.count <= 1, input.threads.count <= 1 else { return false }
        if let project = input.projects.first {
            guard let welcome = input.welcome, welcome["bootstrapProjectCreated"]?.boolValue == true,
                  welcome["bootstrapProjectId"] == project["id"],
                  project["environmentId"]?.stringValue == input.primaryId,
                  let cwd = welcome["cwd"]?.stringValue, let root = project["workspaceRoot"]?.stringValue,
                  (cwd as NSString).standardizingPath == (root as NSString).standardizingPath else { return false }
        }
        guard let thread = input.threads.first else { return true }
        guard let project = input.projects.first, let welcome = input.welcome else { return false }
        return welcome["bootstrapThreadCreated"]?.boolValue == true && welcome["bootstrapThreadId"] == thread["id"]
            && thread["environmentId"]?.stringValue == input.primaryId && thread["projectId"] == project["id"]
            && (thread["latestRun"] == nil || thread["latestRun"] == .null)
            && (thread["latestUserMessageAt"] == nil || thread["latestUserMessageAt"] == .null)
            && (thread["runtime"] == nil || thread["runtime"] == .null)
    }
}
