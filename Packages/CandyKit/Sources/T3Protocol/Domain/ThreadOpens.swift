import Foundation

/// `OrchestrationV2ThreadOpens` (packages/contracts/src/orchestrationV2.ts:380-399): `score` is an open count
/// that halves every two weeks as of `openedAt`, and `picks` holds the folded palette queries that picked the
/// thread, newest first. Times are epoch milliseconds.
public struct ThreadOpens: Codable, Hashable, Sendable {
    public struct Pick: Codable, Hashable, Sendable {
        public var query: String
        public var at: Double
        public init(query: String, at: Double) { self.query = query; self.at = at }
    }

    public var openedAt: Double
    public var score: Double
    public var picks: [Pick]

    public init(openedAt: Double, score: Double, picks: [Pick] = []) {
        self.openedAt = openedAt; self.score = score; self.picks = picks
    }

    private enum CodingKeys: String, CodingKey { case openedAt, score, picks }

    /// `LenientThreadOpens`: a shape this build can't read only loses its ranking, never the thread. A broken
    /// value, such as a pick past 32 UTF-16 units, reads as never opened, as T3's null does.
    public init(from decoder: Decoder) throws {
        let c = try? decoder.container(keyedBy: CodingKeys.self)
        let openedAt = (try? c?.decode(Double.self, forKey: .openedAt)) ?? nil
        let score = (try? c?.decode(Double.self, forKey: .score)) ?? nil
        let picks = (try? c?.decode([Pick].self, forKey: .picks)) ?? nil
        guard let openedAt, let score, score >= 0, openedAt.isFinite, score.isFinite, let picks, picks.count <= 3,
              picks.allSatisfy({ $0.query.utf16.count <= 32 && $0.at.isFinite }) else {
            self.init(openedAt: 0, score: 0); return
        }
        self.init(openedAt: openedAt, score: score, picks: picks)
    }
}
