import Foundation
import T3Protocol
import DesignSystem

/// ProviderUpdateLaunchNotification.logic.ts:160-325, 579-602.
public struct ProviderUpdateToastModel: Equatable, Sendable {
    public var key: String
    public var title: String
    public var message: String
    public var phase: String
    public var timeout: TimeInterval { phase == "succeeded" ? 3 : 0 }
    public static func candidate(_ provider: ServerProvider) -> Bool {
        provider.enabled && !["broken", "unsupported"].contains(provider.compatibilityAdvisory?["latestVersionStatus"]?.stringValue ?? "")
            && provider.versionAdvisory?["status"]?.stringValue == "behind_latest" && provider.latestVersion != nil
    }
    public static func initial(_ providers: [ServerProvider]) -> Self? {
        let candidates = SidebarProviderUpdatePillModel.dedupe(providers.filter(candidate))
        guard let first = candidates.first else { return nil }
        let name = SidebarProviderUpdatePillModel.name(first.driver)
        let version = SidebarProviderUpdatePillModel.version(first.latestVersion ?? "")
        return .init(key: candidates.map { $0.driver + ":" + ($0.latestVersion ?? "") }.sorted().joined(separator: "|"),
                     title: candidates.count == 1 ? "Update Available: \(name) \(version)" : "Updates Available: \(candidates.count) providers",
                     message: "\(SidebarProviderUpdatePillModel.list(candidates)) can be updated from provider settings.", phase: "initial")
    }
    public static func progress(_ values: [ServerProvider], count: Int) -> Self {
        let providers = SidebarProviderUpdatePillModel.dedupe(values)
        let failed = providers.filter { $0.updateState?.status == "failed" }
        if !failed.isEmpty {
            return .init(key: "failed:" + failed.map { $0.updateState?.finishedAt ?? "" }.joined(),
                         title: failed.count == 1 ? "Provider update failed" : "Provider updates failed",
                         message: failed.count == 1 && failed[0].updateState?.message != nil ? failed[0].updateState!.message! : "\(SidebarProviderUpdatePillModel.list(failed)) failed to update. Check provider settings for details.", phase: "failed")
        }
        let unchanged = providers.filter { $0.updateState?.status == "unchanged" }
        if !unchanged.isEmpty {
            return .init(key: "unchanged:" + unchanged.map { $0.updateState?.finishedAt ?? "" }.joined(),
                         title: unchanged.count == 1 ? "Provider still needs an update" : "Providers still need updates",
                         message: "\(SidebarProviderUpdatePillModel.list(unchanged)) \(unchanged.count == 1 ? "still appears" : "still appear") outdated. Check provider settings for details.", phase: "unchanged")
        }
        if providers.count >= count && providers.allSatisfy({ $0.updateState?.status == "succeeded" || (!candidate($0) && !["queued", "running"].contains($0.updateState?.status ?? "")) }) {
            return .init(key: "succeeded:" + providers.map { $0.updateState?.finishedAt ?? "" }.joined(), title: count == 1 ? "Provider updated" : "Provider updates finished",
                         message: count == 1 ? "New sessions will use the updated provider." : "New sessions will use the updated providers.", phase: "succeeded")
        }
        return .init(key: "running", title: count == 1 ? "Updating provider" : "Updating providers", message: "Running provider update command.", phase: "running")
    }
}
