import Foundation
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
}
