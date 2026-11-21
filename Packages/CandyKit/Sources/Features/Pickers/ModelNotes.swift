import Foundation

/// What models.dev says about one model, read from the snapshot `scripts/gen-model-notes` bundles. The picker never
/// fetches it: the app reads only the generated `ModelNotesSnapshot`.
public struct ModelNote: Decodable, Equatable, Sendable {
    public struct Price: Decodable, Equatable, Sendable {
        public var input: Double, output: Double
        public var cacheRead: Double?, cacheWrite: Double?
        enum CodingKeys: String, CodingKey { case input, output, cacheRead = "cache_read", cacheWrite = "cache_write" }
    }
    public var name: String
    public var description: String?
    public var context: Int?
    public var output: Int?
    /// "2026-06" or "2026-04-30".
    public var knowledge: String?
    public var released: String?
    public var input: [String]?
    public var tools: Bool
    public var reasoning: Bool
    public var price: Price?
}

public enum ModelNotes {
    public struct Source: Decodable, Equatable, Sendable {
        public var name: String, url: String, repository: String, licence: String, fetched: String
    }
    struct Snapshot: Decodable { var source: Source; var models: [String: ModelNote] }

    /// Decoded once, on the first picker that asks.
    nonisolated(unsafe) private static var cached: Snapshot?
    private static let lock = NSLock()
    static var snapshot: Snapshot? {
        lock.lock(); defer { lock.unlock() }
        if cached == nil { cached = parse(ModelNotesSnapshot.json) }
        return cached
    }
    static func parse(_ json: String) -> Snapshot? { try? JSONDecoder().decode(Snapshot.self, from: Data(json.utf8)) }

    public static var source: Source? { snapshot?.source }

    /// The models.dev provider holding a driver's own models.
    static let labs = ["claudeAgent": "anthropic", "codex": "openai", "antigravity": "google", "grok": "xai"]

    /// The note for `slug` on `driver`, or nil when models.dev has no entry that is surely this model.
    public static func note(driver: String, slug: String) -> ModelNote? {
        guard let models = snapshot?.models else { return nil }
        let key = "\(driver)\u{0}\(slug)"
        lock.lock()
        if let hit = found[key] { lock.unlock(); return hit }
        lock.unlock()
        let note = lookup(driver: driver, slug: slug, in: models)
        lock.lock(); found[key] = note; lock.unlock()
        return note
    }
    /// Lookups already made, misses included; the picker asks for every listed model on each open.
    nonisolated(unsafe) private static var found: [String: ModelNote?] = [:]

    /// Matching, in order: the driver's lab and the slug without a `[1m]` tag or a `-20251001` date; a
    /// `provider/model` slug (OpenCode) as written; a Gemini effort variant (`-high`, `-medium`, `-low`) as its base model;
    /// then the only lab with that exact id. Nothing else, so a guess never shows another model's facts.
    static func lookup(driver: String, slug: String, in models: [String: ModelNote]) -> ModelNote? {
        var key = slug.lowercased()
        if let bracket = key.firstIndex(of: "[") { key = String(key[..<bracket]) }
        if key.contains("/") { return models[key] }
        let dated = key.replacingOccurrences(of: #"-\d{8}$"#, with: "", options: .regularExpression)
        if let lab = labs[driver] {
            for k in [key, dated] { if let n = models["\(lab)/\(k)"] { return n } }
            let base = key.replacingOccurrences(of: #"-(high|medium|low)$"#, with: "", options: .regularExpression)
            if lab == "google", base != key, let n = models["\(lab)/\(base)"] { return n }
        }
        let anywhere = models.filter { $0.key.hasSuffix("/\(key)") && !$0.key.hasPrefix("opencode/") }
        return anywhere.count == 1 ? anywhere.first?.value : nil
    }

    /// "1M", "128K", "1.05M", "200K".
    static func tokens(_ n: Int) -> String {
        if n >= 1_000_000 {
            let m = Double(n) / 1_000_000
            return (m == m.rounded() ? String(Int(m)) : String(format: "%.2f", m).replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)) + "M"
        }
        if n >= 1000 { return "\(Int((Double(n) / 1000).rounded()))K" }
        return "\(n)"
    }

    /// "2026-06" or "2026-04-30" as "Jun 2026".
    static func month(_ date: String) -> String? {
        let parts = date.split(separator: "-")
        guard parts.count >= 2, let year = Int(parts[0]), let m = Int(parts[1]), (1...12).contains(m) else { return nil }
        let names = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return "\(names[m - 1]) \(year)"
    }

    /// The pane's facts as label and value pairs, in reading order; a fact models.dev lacks stays out.
    static func facts(_ n: ModelNote) -> [(String, String)] {
        var out: [(String, String)] = []
        if let c = n.context { out.append(("Context", tokens(c))) }
        if let o = n.output { out.append(("Max output", tokens(o))) }
        if let k = n.knowledge.flatMap(month) { out.append(("Knowledge", k)) }
        if let r = n.released.flatMap(month) { out.append(("Released", r)) }
        if let input = n.input, !input.isEmpty {
            out.append(("Reads", input.map { $0 == "pdf" ? "PDF" : $0 }.joined(separator: ", ")))
        }
        let can = [n.tools ? "tools" : nil, n.reasoning ? "reasoning" : nil].compactMap { $0 }
        if !can.isEmpty { out.append(("Supports", can.joined(separator: ", "))) }
        return out
    }
}
