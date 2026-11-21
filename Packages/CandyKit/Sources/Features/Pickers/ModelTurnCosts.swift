import Foundation
import T3Protocol

/// The API-priced cost of this user's recent finished turns, per model, for the picker's "About $X a turn for you".
/// Turns come from threads this app opened (Redesign reads each open thread's cost already); the latest 40 per model
/// stay in the app's defaults, a few kilobytes. Nothing is read or written while idle.
// ponytail: only threads opened in this app count; seed from ThreadCache's files if people want a figure sooner
@MainActor public final class ModelTurnCosts {
    public static let shared = ModelTurnCosts(defaults: .standard)
    static let key = "redesign.modelTurnCosts"

    struct Sample: Codable, Equatable { var id: String; var at: String; var usd: Double }
    private let defaults: UserDefaults?
    private(set) var samples: [String: [Sample]]

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        samples = defaults?.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([String: [Sample]].self, from: $0) } ?? [:]
    }

    /// Adds the projection's finished turns; a turn seen before keeps its place.
    public func record(_ projection: ThreadProjection) {
        record(ThreadCostEstimate.finishedTurns(projection))
    }

    func record(_ turns: [ThreadCostEstimate.FinishedTurn]) {
        var changed = false
        for (model, list) in Dictionary(grouping: turns, by: \.model) {
            var mine = samples[model] ?? []
            let seen = Set(mine.map(\.id))
            let new = list.filter { !seen.contains($0.id) }.map { Sample(id: $0.id, at: $0.completedAt, usd: $0.usd) }
            guard !new.isEmpty else { continue }
            // ISO timestamps sort by time as strings.
            mine = Array((mine + new).sorted { $0.at < $1.at }.suffix(ModelCostLine.recentTurns))
            samples[model] = mine
            changed = true
        }
        if changed, let data = try? JSONEncoder().encode(samples) { defaults?.set(data, forKey: Self.key) }
    }

    /// The model's recent turns in USD, oldest first.
    public func turns(_ model: String) -> [Double] { samples[ThreadCostEstimate.priceKey(model)]?.map(\.usd) ?? [] }
}
