import Foundation
import T3Protocol

/// Pinned and archived projects (4928 #26154). A pinned project leads project pickers; an archived one leaves them
/// and keeps its threads and files.
public enum ProjectOrganization {
    /// `environment.capabilities.projectOrganization` (contracts environment.ts:163-164): the server keeps `pinned`
    /// and `archived` from `project.update`. Older servers drop them, so their projects offer neither.
    public static let capability = "projectOrganization"

    /// `projects.mutate` with `project.update` and only the organization fields (project.ts:194-201,
    /// ProjectMutation.ts:45-46). Repeating a pin or an archive keeps the first time (ProjectCommands.ts:213-219).
    public static func update(projectId: String, pinned: Bool? = nil, archived: Bool? = nil,
                              commandId: String = ThreadCommands.newCommandId()) -> JSONValue {
        var o: [String: JSONValue] = ["type": .string("project.update"), "commandId": .string(commandId), "projectId": .string(projectId)]
        if let pinned { o["pinned"] = .bool(pinned) }
        if let archived { o["archived"] = .bool(archived) }
        return .object(o)
    }

    /// `pickableProjectGroups` (client-runtime state/projectGrouping.ts at 4928): archived groups left out, pinned
    /// ones first, each part in its incoming order.
    public static func pickable(_ groups: [SidebarModel.ProjectGroup]) -> [SidebarModel.ProjectGroup] {
        let open = groups.filter { !$0.archived }
        return open.filter(\.pinned) + open.filter { !$0.pinned }
    }

    /// `newThreadNoProjectIndex` (CommandPalette.logic.ts at 4928): where "No project" goes among the new-thread picker's
    /// real projects. At the scratch project's own place when it is pinned or current, else after the pinned projects
    /// and the first unpinned one.
    public static func noProjectIndex(_ entries: [(isScratch: Bool, pinned: Bool, isPreferred: Bool)]) -> Int {
        let projects = entries.filter { !$0.isScratch }
        if let at = entries.firstIndex(where: \.isScratch), entries[at].pinned || entries[at].isPreferred {
            return entries[..<at].filter { !$0.isScratch }.count
        }
        return min(projects.filter(\.pinned).count + 1, projects.count)
    }

    /// `shouldCreateNewThreadInCurrentProject` (sidebarProjectGrouping.ts at 4928): "New thread" skips the project
    /// picker with Shift, with exactly one open project, or with none at all.
    public static func newThreadInCurrentProject(shift: Bool, openGroups: Int, allGroups: Int) -> Bool {
        shift || openGroups == 1 || allGroups == 0
    }
}

extension SidebarModel.ProjectGroup {
    /// Clients write every member together; while members disagree the group reads as pinned and as not archived,
    /// so it stays visible (projectGrouping.ts at 4928).
    public var pinned: Bool { members.contains { $0.pinnedAt != nil } }
    public var archived: Bool { !members.isEmpty && members.allSatisfy { $0.archivedAt != nil } }
}
