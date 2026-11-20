import Foundation
import T3Protocol
import T3Store

/// @-mention a model (#31207 at 4928): `@` lists matching models, a pick writes `model:<instance>/<slug>` into
/// the prompt, and the editor draws a known reference as a chip. The agent reads the plain text.
public enum ComposerModelMentions {
    /// `COMPOSER_MODEL_MENTION_LIMIT` (client-runtime composerModelMentions.ts:3).
    static let limit = 8

    /// `formatComposerModelMention` (composerModelMentions.ts:47-50). No `@`, which would make a file chip.
    public static func format(instanceId: String, model: String) -> String { "model:\(instanceId)/\(model)" }

    /// `mentionSearchQueries` (composerModelMentions.ts:8-14): `:`, `/` and `-` split words; one letter matches none.
    static func queries(_ query: String) -> [String] {
        let spaced = query.replacingOccurrences(of: "[:/]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        let unhyphenated = spaced.replacingOccurrences(of: "-+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        if unhyphenated.filter({ !$0.isWhitespace }).count < 2 { return [] }
        return unhyphenated == spaced ? [spaced] : [spaced, unhyphenated]
    }

    /// `matchComposerModelItems` (apps/web composerModelMentions.ts at 4928) over `rankComposerModelMentions`: models of
    /// picker-ready instances, without legacy ones, whose names start a word for every query word, best first.
    // ponytail: candidates are the server's models; T3 reads getAppModelOptionsForInstance, which also hides models the user hid. Filter by the hidden-models setting if a hidden model shows here
    public static func items(query: String, entries: [ProviderInstanceEntry]) -> [ComposerMenuItem] {
        let candidates = entries.filter(\.isReady).flatMap { e in
            e.models.filter { $0.isLegacy != true }.map { (entry: e, model: $0) }
        }
        guard !candidates.isEmpty else { return [] }
        for words in queries(query) {
            let tokens = words.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
            let literal = candidates.filter { c in
                let haystack = [c.model.name, c.model.shortName ?? "", c.model.subProvider ?? "", c.entry.driver, c.entry.displayName]
                    .joined(separator: " ").lowercased()
                return tokens.allSatisfy { startsWord(haystack, $0) }
            }
            var scored: [(candidate: (entry: ProviderInstanceEntry, model: ServerProviderModel), score: Int, order: Int)] = []
            for (i, c) in literal.enumerated() {
                if let score = ModelPickerSearch.score(c.model, entry: c.entry, query: words, isFavorite: false) { scored.append((c, score, i)) }
            }
            let ranked = scored.sorted { $0.score != $1.score ? $0.score < $1.score : $0.order < $1.order }.map(\.candidate)
            if !ranked.isEmpty {
                return ranked.prefix(limit).map { c in
                    ComposerMenuItem(id: "model:\(c.entry.id.rawValue):\(c.model.slug)",
                                     kind: .model(instanceId: c.entry.id.rawValue, model: c.model.slug, driver: c.entry.driver, providerName: c.entry.displayName),
                                     label: ModelNames.display(c.model), description: c.model.subProvider ?? c.entry.displayName)
                }
            }
        }
        return []
    }

    /// `(?:^|[^\p{L}\p{N}])token`: the token starts a word of the haystack.
    static func startsWord(_ haystack: String, _ token: String) -> Bool {
        var search = haystack.startIndex
        while let r = haystack.range(of: token, range: search..<haystack.endIndex) {
            if r.lowerBound == haystack.startIndex { return true }
            let before = haystack[haystack.index(before: r.lowerBound)]
            if !before.isLetter && !before.isNumber { return true }
            search = haystack.index(after: r.lowerBound)
        }
        return false
    }

    public struct Occurrence: Equatable, Sendable {
        public var instanceId: String
        public var model: String
        public var range: NSRange
    }

    /// `MODEL_MENTION_PATTERN` (composerModelMentions.ts:61).
    private static let pattern = try! NSRegularExpression(pattern: #"(?<![^\s,(\["'])model:([a-zA-Z][a-zA-Z0-9_-]*)/([^\s,"']+)"#)

    /// `collectComposerModelMentions` (composerModelMentions.ts:85-101).
    public static func collect(_ text: String) -> [Occurrence] {
        guard text.contains("model:") else { return [] }
        let ns = text as NSString
        return pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let instance = ns.substring(with: m.range(at: 1))
            let model = trimSlug(ns.substring(with: m.range(at: 2)))
            guard !model.isEmpty else { return nil }
            let length = ("model:" as NSString).length + (instance as NSString).length + 1 + (model as NSString).length
            return Occurrence(instanceId: instance, model: model, range: NSRange(location: m.range.location, length: length))
        }
    }

    /// `trimModelSlug` (composerModelMentions.ts:67-82): sentence punctuation and unbalanced closing brackets leave the end.
    static func trimSlug(_ slug: String) -> String {
        let original = Array(slug)
        var chars = original
        var unmatched: [Character: Int] = [:]
        let opening: [Character: Character] = [")": "(", "]": "["]
        while let last = chars.last {
            if ".;:!?".contains(last) { chars.removeLast(); continue }
            guard let open = opening[last] else { break }
            let excess = unmatched[last] ?? (original.filter { $0 == last }.count - original.filter { $0 == open }.count)
            guard excess > 0 else { break }
            unmatched[last] = excess - 1
            chars.removeLast()
        }
        return String(chars)
    }
}
