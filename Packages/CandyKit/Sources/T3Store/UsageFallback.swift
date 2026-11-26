import Foundation
import T3Protocol

/// Provider fallback (#26164 at 4928): a new thread whose default provider is out of usage starts on the
/// server's `fallbackModelSelection` instead (packages/shared/src/usageLimits.ts at 4928).
public enum UsageFallback {
    public struct Resolution: Hashable, Sendable {
        /// The fallback the new thread starts on.
        public var selection: ModelSelection
        /// The default it replaces, for the banner's "Use …" action.
        public var defaultSelection: ModelSelection
        /// The exhausted default provider and when its window resets.
        public var provider: ServerProvider
        public var resetsAt: String?
    }

    /// `exhaustedUsageWindow` (usageLimits.ts at 4928): a window at 100% that hasn't reset. Cursor, Antigravity and
    /// OpenCode count only the pool the model draws from.
    public static func exhaustedWindow(_ provider: ServerProvider?, now: Date, model: String? = nil) -> UsageLimitWindow? {
        let exhausted = (provider?.usageLimits?.windows ?? []).filter { w in
            guard w.usedPercent >= 100 else { return false }
            guard let resets = w.resetsAt, let date = T3Timestamp(resets).date else { return true }
            return date > now
        }
        guard let model else { return exhausted.first }
        switch provider?.driver {
        case "cursor":
            let api = exhausted.first { $0.id == "apiPercentUsed" }
            let auto = exhausted.first { $0.id == "autoPercentUsed" }
            return model.range(of: "^(auto|default|grok|composer)", options: .regularExpression) != nil ? (auto != nil ? api : nil) : api
        case "antigravity":
            let family = model.range(of: "^(gemini|claude|gpt)-", options: .regularExpression).map { String(model[$0].dropLast()) }
            return exhausted.first { w in
                let pool = w.id.range(of: "^(gemini|claude|gpt|3p)-", options: .regularExpression).map { String(w.id[$0].dropLast()) }
                return pool == nil || family == nil || pool == family || (pool == "3p" && (family == "claude" || family == "gpt"))
            }
        case "codex":
            // Seat-based plans spend credits only past their plan windows, so the credit cap blocks only plans
            // without them (4928 usageLimits.ts:62-68, #34243).
            let hasPlanWindows = (provider?.usageLimits?.windows ?? []).contains { $0.id == "primary" || $0.id == "secondary" }
            return exhausted.first { $0.id != "individual" || !hasPlanWindows }
        case "opencode":
            return exhausted.first { !$0.id.hasPrefix("go_") || model.hasPrefix("opencode-go/") }
        default:
            return exhausted.first
        }
    }

    /// `resolveProjectDefaultProviderModelSelection` (providerInstances.ts at 4928): the first driver group's
    /// selectable instance and its default model.
    public static func providerDefault(_ catalog: ProviderCatalog) -> ModelSelection? {
        let group = catalog.entries.filter { $0.driver == catalog.entries.first?.driver }
        let pick = { (entries: [ProviderInstanceEntry]) in
            entries.first(where: \.isHealthy) ?? entries.first { $0.isSelectable && $0.provider.status != .error }
        }
        guard let entry = pick(group) ?? pick(catalog.entries), let model = entry.defaultModel else { return nil }
        return ModelSelection(instanceId: entry.id, model: model)
    }

    /// `resolveNewThreadModelSelection` (usageLimits.ts at 4928): the fallback when the default's provider is out of
    /// usage for its model and the fallback's is enabled for the project, installed, signed in, available and not out
    /// of usage itself. Nil keeps the default. The catalog already carries the project's provider overrides.
    public static func resolve(defaultSelection: ModelSelection?, fallback: ModelSelection?, catalog: ProviderCatalog, now: Date) -> Resolution? {
        guard let selection = defaultSelection, let fallback,
              let provider = catalog.entry(selection.instanceId)?.provider,
              let window = exhaustedWindow(provider, now: now, model: selection.model),
              let backup = catalog.entry(fallback.instanceId)?.provider,
              backup.enabled, backup.installed, backup.auth?["status"]?.stringValue != "unauthenticated",
              backup.availability != "unavailable",
              exhaustedWindow(backup, now: now, model: fallback.model) == nil else { return nil }
        return Resolution(selection: fallback, defaultSelection: selection, provider: provider, resetsAt: window.resetsAt)
    }
}
