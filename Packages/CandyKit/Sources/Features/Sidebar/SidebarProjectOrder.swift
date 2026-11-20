import Foundation
import T3Protocol
import T3Store

/// The sidebar's project order: the `sidebarProjectSortOrder` client setting and the manual order it reads. T3 keeps the
/// manual order in its UI state store, beside the folded projects, not in the client settings (uiStateStore.ts:23-60),
/// so it lives in the defaults here too.
public enum SidebarProjectOrder {
    static let key = "sidebar.projectOrder"

    /// Physical project keys (`getProjectOrderKey`), first to last.
    public static var stored: [String] {
        get { UserDefaults.standard.stringArray(forKey: key) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// The setting. CandyWrapper defaults to Manual, so sections stay where the user put them (docs/decisions.md).
    @MainActor public static var sortOrder: SidebarModel.SortOrder {
        SidebarModel.SortOrder(rawValue: ClientSettingsStore.shared.current.string("sidebarProjectSortOrder")) ?? .manual
    }

    /// The project pickers' groups (`useSortedProjectGroups`, CommandPaletteLookups.ts:62-92 at 4928): the
    /// `sidebarProjectSortOrder` order, Manual reading the stored order, archived groups out and pinned ones first, then
    /// the `current` project leading the unpinned ones (`pickableProjectGroups`, `buildSidebarProjectPickerEntries`).
    /// The command palette and the draft hero share it (DraftHeroHeadline.tsx:96, #29846).
    @MainActor public static func pickerGroups(_ snapshot: ShellSnapshot, primaryId: String?, current: ProjectId?) -> [SidebarModel.ProjectGroup] {
        let order = sortOrder
        let built = SidebarModel.buildProjectGroups(snapshot.projects, preferredEnvironmentId: primaryId)
        var groups = order == .manual ? SidebarModel.orderProjectGroups(built, projects: snapshot.projects, preferred: stored)
            : SidebarModel.sortLogicalProjectsForSidebar(built, threads: snapshot.threads, order: order)
        groups = ProjectOrganization.pickable(groups)
        if let current, let i = groups.firstIndex(where: { $0.memberProjectIds.contains(current) }), !groups[i].pinned {
            let pinned = groups.filter(\.pinned).count
            if i > pinned { groups.insert(groups.remove(at: i), at: pinned) }
        }
        return groups
    }
}
