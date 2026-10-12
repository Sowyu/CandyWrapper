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

    /// `getProviderUpdateInitialToastView`: with one-click candidates the prompt offers to install.
    public static func initial(_ providers: [ServerProvider]) -> Self? {
        let candidates = candidates(providers)
        guard let first = candidates.first else { return nil }
        let name = SidebarProviderUpdatePillModel.name(first.driver)
        let version = SidebarProviderUpdatePillModel.version(first.latestVersion ?? "")
        let oneClick = candidates.contains { canOneClick($0, among: providers) }
        return .init(key: candidates.map { $0.driver + ":" + ($0.latestVersion ?? "") }.sorted().joined(separator: "|"),
                     title: candidates.count == 1 ? "Update Available: \(name) \(version)" : "Updates Available: \(candidates.count) providers",
                     message: oneClick ? "Install the update now or review provider settings."
                        : "\(SidebarProviderUpdatePillModel.list(candidates)) can be updated from provider settings.", phase: "initial")
    }

    /// `getProviderUpdateRejectedToastView`.
    public static func rejected(count: Int, message: String) -> Self {
        .init(key: "rejected:" + message, title: count == 1 ? "Provider update failed" : "Provider updates failed", message: message, phase: "failed")
    }

    /// `t3code:provider-update-dismissals:v1` (providerUpdateDismissal.ts): prompts closed with X stay closed.
    public static let dismissalsKey = "t3code:provider-update-dismissals:v1"
    public static func isDismissed(_ key: String, in defaults: UserDefaults = .standard) -> Bool { dismissed(defaults).contains(key) }
    public static func dismiss(_ key: String, in defaults: UserDefaults = .standard) {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        var keys = dismissed(defaults)
        guard !k.isEmpty, !keys.contains(k) else { return }
        keys.append(k)
        if let data = try? JSONSerialization.data(withJSONObject: ["keys": keys]) { defaults.set(String(decoding: data, as: UTF8.self), forKey: dismissalsKey) }
    }
    static func dismissed(_ defaults: UserDefaults) -> [String] {
        guard let text = defaults.string(forKey: dismissalsKey), let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let keys = object["keys"] as? [String] else { return [] }
        return keys
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
