import Foundation
import T3Protocol
import DesignSystem

/// The provider update candidates Update everything installs (ProviderUpdateLaunchNotification.logic.ts in 3669).
/// 3669 dropped the launch toast and its dismissals (b9aaff46e0).
public enum ProviderUpdateCandidates {
    public static func candidate(_ provider: ServerProvider) -> Bool {
        provider.enabled && !["broken", "unsupported"].contains(provider.compatibilityAdvisory?["latestVersionStatus"]?.stringValue ?? "")
            && provider.versionAdvisory?["status"]?.stringValue == "behind_latest" && provider.latestVersion != nil
    }
    /// `collectProviderUpdateCandidates`: one per driver.
    public static func candidates(_ providers: [ServerProvider]) -> [ServerProvider] {
        SidebarProviderUpdatePillModel.dedupe(providers.filter(candidate))
    }

    /// `canOneClickUpdateProviderCandidate` (logic.ts:176-213): not already updating, the server can run its
    /// update command, and every outdated instance of the driver shares that one command.
    public static func canOneClick(_ c: ServerProvider, among providers: [ServerProvider]) -> Bool {
        guard !["queued", "running"].contains(c.updateState?.status ?? "") else { return false }
        func command(_ p: ServerProvider) -> String? {
            guard p.versionAdvisory?["canUpdate"]?.boolValue == true else { return nil }
            return p.versionAdvisory?["updateCommand"]?.stringValue
        }
        guard command(c) != nil else { return false }
        var commands = Set<String>()
        for p in providers where p.driver == c.driver && candidate(p) {
            guard let cmd = command(p) else { return false }
            commands.insert(cmd)
        }
        return commands.count == 1
    }
}
