import Foundation
import T3Protocol

/// Reconciles the footer's active updates without changing the server's provider state.
/// T3 3669's pill trusts queued/running indefinitely (ProviderUpdateLaunchNotification.logic.ts:306-324).
struct ProviderUpdateProgress {
    static let timeout: TimeInterval = 180

    private struct Entry {
        var state: ServerProvider.UpdateState
        var version: String?
        var lastProgress: TimeInterval
        var settled: ServerProvider.UpdateState?
        var versionChanged = false
    }
    private var entries: [String: Entry] = [:]

    var stalledInstances: Set<String> {
        Set(entries.compactMap { $0.value.settled?.status == "failed" ? $0.key : nil })
    }

    var nextDeadline: TimeInterval? {
        entries.values.filter { $0.settled == nil }.map { $0.lastProgress + Self.timeout }.min()
    }

    mutating func reconcile(_ providers: [ServerProvider], now: TimeInterval) -> [ServerProvider] {
        let ids = Set(providers.map { $0.instanceId.rawValue })
        entries = entries.filter { ids.contains($0.key) }
        return providers.map { provider in
            var provider = provider
            let id = provider.instanceId.rawValue
            guard let state = provider.updateState, ["queued", "running"].contains(state.status) else {
                // A terminal reply can omit its timestamp on an older server. An update we saw still finishes.
                if entries.removeValue(forKey: id) != nil,
                   let terminal = provider.updateState, ["succeeded", "failed", "unchanged"].contains(terminal.status),
                   provider.updateState?.finishedAt == nil {
                    provider.updateState?.finishedAt = Self.iso(now)
                }
                return provider
            }
            var entry: Entry
            if let previous = entries[id], previous.state.startedAt == state.startedAt {
                entry = previous
                // Probe timestamps and duplicate reconnect snapshots are not update progress.
                if !entry.versionChanged, entry.state.status != state.status || entry.state.message != state.message {
                    entry.lastProgress = now
                    entry.settled = nil
                }
                if !entry.versionChanged, let version = provider.version, version != entry.version {
                    entry.versionChanged = true
                    entry.settled = .init(status: "succeeded", finishedAt: Self.iso(now), message: "Provider version changed.", startedAt: state.startedAt)
                }
                entry.state = state
            } else {
                let started = state.startedAt.flatMap { T3Timestamp($0).epochMs }.map { Double($0) / 1000 }
                entry = Entry(state: state, version: provider.version, lastProgress: min(now, started ?? now))
            }
            if entry.settled == nil, now >= entry.lastProgress + Self.timeout {
                entry.settled = .init(status: "failed", finishedAt: Self.iso(now),
                                     message: "No update progress for 3 minutes. Open provider settings to check the result or try again.", startedAt: state.startedAt)
            }
            entries[id] = entry
            if let settled = entry.settled { provider.updateState = settled }
            return provider
        }
    }

    private static func iso(_ seconds: TimeInterval) -> String {
        Date(timeIntervalSince1970: seconds).ISO8601Format(.init(includingFractionalSeconds: true))
    }
}
