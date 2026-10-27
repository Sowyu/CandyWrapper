import Foundation
import T3Protocol
import T3Store

/// Port of T3's shared palette ranking, packages/shared/src/paletteSearch.ts (Nightly 3669, bb7783e295 and
/// e9d61252f6). Text works in UTF-16 units like the JavaScript, so ranges index `NSString` offsets.
public enum PaletteScoring {
    /// Half-open UTF-16 range.
    public struct SearchRange: Equatable, Hashable, Sendable {
        public var start: Int
        public var end: Int
        public init(start: Int, end: Int) { self.start = start; self.end = end }
    }

    // MARK: Characters (paletteSearch.ts:7-104)

    typealias Units = [UInt16]

    static func isLetter(_ s: Unicode.Scalar) -> Bool {
        switch s.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: true
        default: false
        }
    }
    static func isDigit(_ s: Unicode.Scalar) -> Bool {
        switch s.properties.generalCategory {
        case .decimalNumber, .letterNumber, .otherNumber: true
        default: false
        }
    }
    static func isAlnum(_ s: Unicode.Scalar) -> Bool {
        if s.value < 0x80 { return (s.value >= 0x30 && s.value <= 0x39) || ((s.value | 0x20) >= 0x61 && (s.value | 0x20) <= 0x7A) }
        return isLetter(s) || isDigit(s)
    }
    static func isLower(_ s: Unicode.Scalar) -> Bool { s.properties.generalCategory == .lowercaseLetter }
    static func isUpper(_ s: Unicode.Scalar) -> Bool { s.properties.generalCategory == .uppercaseLetter }
    static func isSymbol(_ s: Unicode.Scalar) -> Bool { s.properties.generalCategory == .otherSymbol }
    static func isMark(_ s: Unicode.Scalar) -> Bool {
        switch s.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: true
        default: false
        }
    }
    static func isApostrophe(_ s: Unicode.Scalar) -> Bool { s == "'" || s == "\u{2019}" }

    /// A regex test on one UTF-16 unit, as `ALPHANUMERIC.test(text[i])` reads it: a surrogate half never matches.
    static func unitIsAlnum(_ u: UInt16) -> Bool { Unicode.Scalar(u).map(isAlnum) ?? false }
    static func unitIsSymbol(_ u: UInt16) -> Bool { Unicode.Scalar(u).map(isSymbol) ?? false }
    static func unitIsDigit(_ u: UInt16) -> Bool { Unicode.Scalar(u).map(isDigit) ?? false }

    static func foldCharacter(_ s: Unicode.Scalar) -> String {
        // A typed straight apostrophe finds a curly one: iOS keyboards type "’".
        let scalars = String(s).decomposedStringWithCompatibilityMapping.unicodeScalars.filter { !isMark($0) }
        return String(String.UnicodeScalarView(scalars)).lowercased()
            .replacingOccurrences(of: "ς", with: "σ")
            .replacingOccurrences(of: "\u{2018}", with: "'").replacingOccurrences(of: "\u{2019}", with: "'")
    }

    /// `foldInPlace`: case and accents folded one UTF-16 unit at a time, so offsets and word starts still read
    /// from the source. A letter that folds to more or less than one unit ("ß", "ﬁ") stays as it is.
    static func foldInPlace(_ text: String) -> Units {
        var out = Units()
        out.reserveCapacity(text.utf16.count)
        for s in text.unicodeScalars {
            if s.value < 0x80 {
                let v = UInt16(s.value)
                out.append(v >= 0x41 && v <= 0x5A ? v + 0x20 : v)
            } else if s.value <= 0xFFFF {
                let folded = Array(foldCharacter(s).utf16)
                var unit = folded.count == 1 ? folded[0] : UInt16(s.value)
                if let u = Unicode.Scalar(unit) {
                    let lower = Array(String(u).lowercased().utf16)
                    if lower.count == 1 { unit = lower[0] }
                }
                out.append(unit)
            } else {
                let original = Array(String(s).utf16)
                let lower = Array(String(s).lowercased().utf16)
                out.append(contentsOf: lower.count == original.count ? lower : original)
            }
        }
        return out
    }

    /// Chinese and Japanese text has no spaces, so each ideograph or kana starts a word.
    static func isCjk(_ s: Unicode.Scalar) -> Bool {
        let c = s.value
        return (0x3040...0x30FF).contains(c) || (0x3400...0x4DBF).contains(c) || (0x4E00...0x9FFF).contains(c)
            || (0xF900...0xFAFF).contains(c)
    }

    /// Two Chinese, Japanese, or Korean characters already make a common word.
    static func hasCjkWord(_ token: String) -> Bool {
        token.unicodeScalars.contains { isCjk($0) || (0xAC00...0xD7AF).contains($0.value) }
    }

    /// `isWordStart`: after a non-letter, at a camelCase or digit boundary, or at any Chinese or Japanese
    /// character. Nil stands for "" at either end.
    static func isWordStart(_ beforePrevious: Unicode.Scalar?, _ previous: Unicode.Scalar?, _ character: Unicode.Scalar,
                            _ next: Unicode.Scalar?) -> Bool {
        // "Julius’s": a possessive or contraction does not start a word.
        let afterApostrophe = previous.map(isApostrophe) == true && beforePrevious.map(isAlnum) == true
        guard isAlnum(character) || isSymbol(character), !afterApostrophe else { return false }
        guard let previous else { return true }
        return !isAlnum(previous)
            || (isLower(previous) && isUpper(character))
            // The last capital of an acronym starts the next word: "JSONSchema".
            || (isUpper(previous) && isUpper(character) && next.map(isLower) == true)
            || isDigit(previous) != isDigit(character)
            || isCjk(character)
    }

    final class SearchField {
        /// Case- and accent-folded text, one UTF-16 unit per source unit.
        let text: Units
        /// True where a word starts in `text`.
        let wordStarts: [Bool]
        init(text: Units, wordStarts: [Bool]) { self.text = text; self.wordStarts = wordStarts }
    }

    static func foldSearchField(_ source: String) -> SearchField {
        let scalars = Array(source.unicodeScalars)
        var starts = [Bool](repeating: false, count: source.utf16.count)
        var index = 0
        for (position, s) in scalars.enumerated() {
            let before = position >= 2 ? scalars[position - 2] : nil
            let previous = position >= 1 ? scalars[position - 1] : nil
            let next = position + 1 < scalars.count ? scalars[position + 1] : nil
            if isWordStart(before, previous, s, next) { starts[index] = true }
            index += s.utf16.count
        }
        return SearchField(text: foldInPlace(source), wordStarts: starts)
    }

    // Thread titles, branches, and project names repeat across keystrokes; folding them once keeps a keystroke
    // to plain scans. The limit holds every field a keystroke reads.
    // ponytail: cleared whole at the limit where T3 drops the oldest; LRU if a palette ever holds 100,000 fields
    @MainActor private static var fieldCache: [String: SearchField] = [:]
    private static let fieldCacheLimit = 100_000

    @MainActor static func prepareSearchField(_ source: String) -> SearchField {
        if let cached = fieldCache[source] { return cached }
        if fieldCache.count >= fieldCacheLimit { fieldCache.removeAll(keepingCapacity: true) }
        let field = foldSearchField(source)
        fieldCache[source] = field
        return field
    }

    // MARK: Query (paletteSearch.ts:134-151)

    /// JavaScript's `\s`, which ICU's and Swift's whitespace differ from: it holds U+FEFF and not U+0085.
    static let jsSpace = "[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]"
    static let jsNotSpace = "[^" + jsSpace.dropFirst()
    static let jsSpaces = CharacterSet(charactersIn: "\t\n\u{0B}\u{0C}\r \u{A0}\u{1680}\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}\u{FEFF}")
        .union(CharacterSet(charactersIn: "\u{2000}"..."\u{200A}"))
    static func isJSSpace(_ s: Unicode.Scalar) -> Bool { jsSpaces.contains(s) }

    static let wrappingQuotes = try! NSRegularExpression(pattern: "^\(jsSpace)*[\"'`“”‘’]+|[\"'`“”‘’]+\(jsSpace)*\\z")

    static func replacing(_ regex: NSRegularExpression, in text: String, with template: String = "") -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: template)
    }

    static func string(_ units: some Collection<UInt16>) -> String { String(decoding: units, as: UTF16.self) }

    /// `split(/\s+/)` without the empty ends.
    static func splitWhitespace(_ text: String) -> [String] {
        text.unicodeScalars.split(whereSeparator: isJSSpace).map { String(String.UnicodeScalarView($0)) }
    }

    /// `foldSearchQuery`: folded, whitespace-collapsed query; empty when there is nothing to match.
    public static func foldSearchQuery(_ query: String) -> String {
        let folded = string(foldInPlace(replacing(wrappingQuotes, in: query).precomposedStringWithCanonicalMapping))
        return splitWhitespace(folded).joined(separator: " ")
    }

    static func indexOf(_ hay: Units, _ needle: Units, from: Int = 0) -> Int? {
        guard !needle.isEmpty, needle.count <= hay.count else { return needle.isEmpty && from <= hay.count ? from : nil }
        var i = max(0, from)
        let first = needle[0], last = hay.count - needle.count
        while i <= last {
            if hay[i] == first {
                var j = 1
                while j < needle.count, hay[i + j] == needle[j] { j += 1 }
                if j == needle.count { return i }
            }
            i += 1
        }
        return nil
    }

    static func starts(_ hay: Units, with needle: some Collection<UInt16>, at: Int) -> Bool {
        guard at >= 0, at + needle.count <= hay.count else { return false }
        return hay[at..<(at + needle.count)].elementsEqual(needle)
    }

    static func wordEnd(_ field: SearchField, _ index: Int) -> Int {
        var end = index + 1
        while end < field.text.count, !field.wordStarts[end], unitIsAlnum(field.text[end]) { end += 1 }
        return end
    }

    /// One substitution, insertion, deletion, or swap of neighbours; with `swapOnly`, only a swap.
    static func withinOneEdit(_ left: ArraySlice<UInt16>, _ right: ArraySlice<UInt16>, swapOnly: Bool) -> Bool {
        if abs(left.count - right.count) > (swapOnly ? 0 : 1) { return false }
        var i = 0
        let l = Array(left), r = Array(right)
        while i < l.count, i < r.count, l[i] == r[i] { i += 1 }
        let restL = l[i...], restR = r[i...]
        let swapped = restL.count > 1 && restR.count > 1 && restL[restL.startIndex] == restR[restR.startIndex + 1]
            && restL[restL.startIndex + 1] == restR[restR.startIndex] && restL.dropFirst(2).elementsEqual(restR.dropFirst(2))
        if swapOnly { return swapped }
        return swapped || restL.elementsEqual(restR) || restL.dropFirst().elementsEqual(restR.dropFirst())
            || restL.dropFirst().elementsEqual(restR) || restL.elementsEqual(restR.dropFirst())
    }

    // MARK: Matching (paletteSearch.ts:176-426)

    static let wholeWord = 1.0
    /// The bonus for a field equal to the whole query lifts a whole word to this.
    static let wholeName = 1.5
    static let midWord = 0.3
    static let typo = 0.45
    /// Whole words typed together are exact, so they rank with typos and above mid-word hits, though below a
    /// match at a word start.
    static let joinedWords = 0.6

    struct TokenMatch {
        var score: Double
        var start: Int
        var end: Int
        /// Separate ranges, for words typed together.
        var letters: [SearchRange]? = nil
        var range: SearchRange { SearchRange(start: start, end: end) }
    }

    /// `matchToken`: mid-word hits need four or more characters and `midWord`, so "del" does not find "model".
    /// Typos keep the first letter except for swaps, and numbers never match with a typo.
    static func matchToken(_ field: SearchField, _ token: Units, typos: Bool, isPrimary: Bool, midWord allowMidWord: Bool) -> TokenMatch? {
        guard !token.isEmpty else { return nil }
        let text = field.text
        var best: TokenMatch?
        let ownBoundary = !unitIsAlnum(token[0]) && !unitIsSymbol(token[0])
        var found = indexOf(text, token)
        while let index = found {
            // A token that opens with punctuation (".ts") brings its own boundary, as in messages.
            if field.wordStarts[index] || ownBoundary {
                // Whole when the match ends where a word ends: "t3c" is a prefix of "t3code".
                let end = index + token.count
                let whole = end >= text.count || field.wordStarts[end] || !unitIsAlnum(text[end])
                var runEnd = end
                while runEnd < text.count, unitIsAlnum(text[runEnd]) { runEnd += 1 }
                let score = whole ? wholeWord : 0.7 + (0.2 * Double(token.count)) / Double(runEnd - index)
                if best == nil || score > best!.score { best = TokenMatch(score: score, start: index, end: end) }
                if score == wholeWord { return best }
            } else if allowMidWord, token.count >= 4, best == nil {
                best = TokenMatch(score: midWord, start: index, end: index + token.count)
            }
            found = indexOf(text, token, from: index + 1)
        }
        // Joined words are exact, so they count without the typo pass: a strong match elsewhere must not hide
        // "VS Code" for "vscode".
        if (best == nil || best!.score <= midWord) && isPrimary, let joined = matchJoinedWords(field, token) { return joined }
        if let b = best, b.score > midWord { return best }
        if !typos || token.count < 3 { return best }
        // Numbers skip typos to keep pull requests distinct. Words with digits ("t3code") do not.
        guard string(token).unicodeScalars.contains(where: isLetter) else { return best }
        for index in text.indices where field.wordStarts[index] {
            // People rarely mistype the first letter, so a typo keeps it, unless it swaps the first two of a
            // longer word ("ing" is not "nig…").
            let first = text[index]
            let firstKept = first == token[0]
                || (token.count > 3 && first == token[1] && index + 1 < text.count && text[index + 1] == token[0])
            guard firstKept else { continue }
            // The whole run, across camelCase joins: "githbu" is "GitHub".
            var runEnd = index + 1
            while runEnd < text.count, unitIsAlnum(text[runEnd]) { runEnd += 1 }
            let word = text[index..<runEnd]
            // Short tokens forgive a swapped pair or one missing letter ("srv" for "serv…").
            let short = token.count <= 4
            let lengths = short ? [token.count, token.count + 1] : [token.count, token.count - 1, token.count + 1]
            for length in lengths where length <= word.count {
                let prefix = word.prefix(length)
                if withinOneEdit(token[...], prefix, swapOnly: short && length == token.count) {
                    return TokenMatch(score: typo, start: index, end: index + length)
                }
            }
        }
        return best
    }

    /// `matchJoinedWords`: short words followed by a short prefix are noise inside a title ("inth" in "in thread").
    /// Allowed at its start ("t3co"), before three letters ("gomod"), or as a whole word ("vscode").
    static func matchJoinedWords(_ field: SearchField, _ token: Units) -> TokenMatch? {
        let text = field.text
        let firstWord = field.wordStarts.firstIndex(of: true) ?? -1
        for start in text.indices where field.wordStarts[start] && text[start] == token[0] {
            var runs: [SearchRange] = []
            var at = start
            var rest = token[...]
            while !rest.isEmpty, at < text.count {
                let end = wordEnd(field, at)
                if rest.count <= end - at, starts(text, with: rest, at: at) {
                    runs.append(SearchRange(start: at, end: at + rest.count))
                    rest = []
                } else if rest.starts(with: text[at..<end]) {
                    runs.append(SearchRange(start: at, end: end))
                    rest = rest.dropFirst(end - at)
                    at = end
                    while at < text.count, !field.wordStarts[at] { at += 1 }
                } else {
                    break
                }
            }
            guard rest.isEmpty, let last = runs.last, runs.count >= 2 else { continue }
            if last.end == wordEnd(field, last.start) || last.end - last.start >= 3 || start == firstWord
                || runs.dropLast().allSatisfy({ $0.end - $0.start >= 3 }) {
                return TokenMatch(score: joinedWords, start: start, end: last.end, letters: runs)
            }
        }
        return nil
    }

    struct WeightedSearchField {
        var value: String
        var weight: Double
        /// Only a whole-word match counts, as for a short query against keywords.
        var wholeWords = false
        /// Only a match at a word start counts, without typos.
        var keyword = false
        /// Where the thread lives (project, environment): it helps a match but never makes it strong.
        var context = false
        /// A token of four or more letters may match inside a word here. Only thread titles allow it.
        var midWord = false
    }

    struct SearchFieldsMatch {
        /// Roughly 0.3 (inside a word) to 1.5 (exact title).
        var quality: Double
        /// Every token matched at a word start, without a typo.
        var strong: Bool
        /// Source ranges matched in the first field, for highlighting.
        var primaryRanges: [SearchRange]
    }

    static let fillerWords: Set<String> = ["a", "an", "and", "for", "in", "of", "on", "the", "to", "with"]

    /// Sorted, with overlapping ranges joined.
    static func mergeRanges(_ ranges: [SearchRange]) -> [SearchRange] {
        var merged: [SearchRange] = []
        for range in ranges.sorted(by: { $0.start < $1.start }) {
            if let last = merged.last, range.start <= last.end {
                merged[merged.count - 1] = SearchRange(start: last.start, end: max(last.end, range.end))
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// `matchSearchFields`: every query token must match some field. Quality is the mean of each token's best
    /// weighted match, plus a bonus when the first field holds the whole query as a phrase or equals it.
    @MainActor static func matchSearchFields(_ normalizedQuery: String, _ fields: [WeightedSearchField], typos: Bool = false) -> SearchFieldsMatch? {
        guard !normalizedQuery.isEmpty else { return nil }
        let prepared = fields.filter { !$0.value.isEmpty }.map { (prepareSearchField($0.value), $0) }
        // Field identity, as T3's cache gives one field per source string.
        let primaryValue = fields.first.flatMap { $0.value.isEmpty ? nil : $0.value }
        let primary = primaryValue.map { _ in prepared[0].0 }
        // An empty token would match everywhere.
        let tokens = normalizedQuery.split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return nil }
        // A phrase-style query ("fix the sidebar") carries filler words a name may leave out.
        let fillerOptional = tokens.contains { !fillerWords.contains($0) }
        var primaryRanges: [SearchRange] = []
        var total = 0.0, counted = 0
        var strong = true
        for token in tokens {
            let units = Units(token.utf16)
            var best = 0.0
            var bestPrimary: TokenMatch?
            var atWordStart = false
            for (field, spec) in prepared {
                let isPrimary = field === primary
                if best >= spec.weight && !isPrimary && atWordStart { continue }
                let match = matchToken(field, units, typos: typos && !spec.keyword, isPrimary: isPrimary, midWord: spec.midWord)
                guard let match, match.score >= (spec.wholeWords ? wholeWord : spec.keyword ? 0.7 : 0) else { continue }
                if isPrimary { bestPrimary = match }
                if match.score >= 0.7 && !spec.context { atWordStart = true }
                if match.score * spec.weight > best { best = match.score * spec.weight }
            }
            if best == 0 {
                if fillerOptional && fillerWords.contains(token) { continue }
                return nil
            }
            strong = strong && atWordStart
            if let bestPrimary { primaryRanges += bestPrimary.letters ?? [bestPrimary.range] }
            total += best
            counted += 1
        }
        var quality = total / Double(counted)
        if let primary {
            let q = Units(normalizedQuery.utf16)
            if primary.text == q { quality += wholeName - wholeWord }
            else if tokens.count > 1, indexOf(primary.text, q) != nil { quality += 0.25 }
        }
        return SearchFieldsMatch(quality: quality, strong: strong, primaryRanges: mergeRanges(primaryRanges))
    }

    // MARK: Messages (paletteSearch.ts:428-713)

    /// A two-letter Latin substring of a message is noise rather than a match.
    static let messageTokenMinLength = 3
    static let curlyApostrophes = try! NSRegularExpression(pattern: "[\\u2018\\u2019]")

    public struct MessageSearchTokens: Equatable {
        public var long: [String]
        public var short: [String]
        /// Every token, in the order typed.
        public var words: [String]
    }

    /// `messageSearchTokens`: every `long` token must match, `short` ones only narrow hits. No long tokens means
    /// no search. Two CJK characters count as long. Accents stay, as the server index folds Latin accents.
    public static func messageSearchTokens(_ query: String) -> MessageSearchTokens {
        let cleaned = replacing(curlyApostrophes, in: replacing(wrappingQuotes, in: query), with: "'")
        let tokens = splitWhitespace(cleaned.precomposedStringWithCanonicalMapping.lowercased())
        let searchable = { (token: String) -> Bool in
            let length = token.unicodeScalars.count
            return length >= messageTokenMinLength || (length == 2 && hasCjkWord(token))
        }
        return MessageSearchTokens(long: tokens.filter(searchable), short: tokens.filter { !searchable($0) }, words: tokens)
    }

    /// `messagePhrase`: the query's words side by side as whole words, whatever whitespace is between them and
    /// ignoring case; nil for a single word.
    public static func messagePhrase(_ query: String) -> NSRegularExpression? {
        let words = messageSearchTokens(query).words
        guard words.count > 1 else { return nil }
        let body = words.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "\(jsSpace)+")
        return try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}])\(body)(?![\\p{L}\\p{N}])", options: [.caseInsensitive])
    }

    /// Words written together, as typed, rank above the same words apart; words near each other rank above
    /// words far apart.
    static let messagePhraseBonus = 0.25
    static let messageNearBonus = 0.1
    /// About what a result row shows.
    static let messageNearSpan = 60
    /// A message token shorter than this must start a word: "fts" is not in "drafts".
    static let messageWordStartLength = 4
    static let messagePrefix = 0.8

    static func scalar(_ text: Units, _ index: Int) -> Unicode.Scalar? {
        index >= 0 && index < text.count ? Unicode.Scalar(text[index]) : nil
    }

    static func startsWordAt(_ text: Units, _ index: Int) -> Bool {
        // A token that opens with punctuation (such as ".ts") brings its own boundary.
        guard let character = scalar(text, index), isAlnum(character) || isSymbol(character) else { return true }
        return isWordStart(scalar(text, index - 2), scalar(text, index - 1), character, scalar(text, index + 1))
    }

    /// Whether a word ends right before `end` in `text`.
    static func endsWordAt(_ text: Units, _ end: Int) -> Bool {
        end >= text.count || !unitIsAlnum(text[end]) || startsWordAt(text, end)
    }

    /// A commit SHA or UUID part: seven or more hex characters with a digit.
    static func isHexId(_ run: ArraySlice<UInt16>) -> Bool {
        run.count >= 7 && run.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || (($0 | 0x20) >= 0x61 && ($0 | 0x20) <= 0x66) }
            && run.contains { $0 >= 0x30 && $0 <= 0x39 }
    }

    /// `findMessageToken`: where `token` best sits in `folded`, a fold of `text`: every place it is a whole word,
    /// else a word start, else inside a word. Hits past the start of a hex ID don't count.
    static func findMessageToken(_ text: Units, _ folded: Units, _ token: Units) -> (at: [Int], quality: Double)? {
        var quality = 0.0
        var at: [Int] = []
        var run = (start: 0, end: -1, hex: false)
        var found = indexOf(folded, token)
        while let index = found {
            defer { found = indexOf(folded, token, from: index + 1) }
            if index + token.count > run.end {
                var start = index
                while start > 0, unitIsAlnum(text[start - 1]) { start -= 1 }
                var end = index + token.count
                while end < text.count, unitIsAlnum(text[end]) { end += 1 }
                run = (start, end, isHexId(text[start..<end]))
            }
            if run.hex && run.start < index { continue }
            let q = !startsWordAt(text, index) ? midWord : endsWordAt(text, index + token.count) ? 1 : messagePrefix
            if q > quality { quality = q; at = [index] } else if q == quality { at.append(index) }
        }
        return at.isEmpty ? nil : (at, quality)
    }

    public struct MessageMatch: Equatable {
        /// 1 for whole words, 0.8 when one only starts a word, 0.3 inside words, plus the phrase or near bonus.
        public var quality: Double
        /// Where a snippet should start to show the match.
        public var offset: Int
    }

    static func hasNonASCII(_ text: String) -> Bool { text.utf16.contains { $0 >= 0x80 } }

    static func firstMatch(_ regex: NSRegularExpression?, _ text: String) -> Int? {
        guard let regex else { return nil }
        return regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))?.range.location
    }

    /// `messageMatcher`: grades messages against a query, so message hits rank like titles: nil when a token is
    /// missing or a short one never starts a word. The server grades with it; the client keeps it for parity.
    public static func messageMatcher(_ query: String) -> (String) -> MessageMatch? {
        let split = messageSearchTokens(query)
        let tokens = (split.long + split.short).map { token in
            (token: Units(token.utf16),
             // Marks go from the folded token: lowercasing "İ" adds one.
             folded: Units(string(foldInPlace(token)).unicodeScalars.filter { !isMark($0) }.map(String.init).joined().utf16),
             nonAscii: hasNonASCII(token),
             mustStartWord: token.unicodeScalars.count < messageWordStartLength,
             // Too short to search, so it only narrows.
             grades: split.long.contains(token))
        }
        let phrase = messagePhrase(query)
        // Accents typed or left out still read as written together: "cafe open" in "Café open".
        let foldedPhrase = messagePhrase(split.words.map { string(foldInPlace($0)).unicodeScalars.filter { !isMark($0) }.map(String.init).joined() }
            .joined(separator: " "))
        let queryNonAscii = hasNonASCII(query)
        return { text in
            let source = Units(text.utf16)
            let lower = text.lowercased()
            // "İ" lowercases to two units, which would shift every offset after it.
            let plain = lower.utf16.count == source.count ? Units(lower.utf16) : foldInPlace(text)
            var folded: Units?
            var quality = 1.0
            var positions: [[Int]] = []
            for t in tokens {
                var found = findMessageToken(source, plain, t.token)
                // Accents typed or left out: "cafe" finds "Café", also after "cafeteria".
                if found?.quality != 1, !t.folded.isEmpty, t.nonAscii || hasNonASCII(text) {
                    if folded == nil { folded = foldInPlace(text) }
                    found = findMessageToken(source, folded!, t.folded)
                }
                guard let found else { return nil }
                if found.quality == midWord && t.mustStartWord { return nil }
                if t.grades { quality = min(quality, found.quality) }
                positions.append(found.at)
            }
            // Written together as typed: the snippet starts there. Straightening apostrophes keeps offsets.
            let straight = { (u: Units) in replacing(curlyApostrophes, in: string(u), with: "'") }
            var together = firstMatch(phrase, straight(plain))
            if together == nil, queryNonAscii || hasNonASCII(text) {
                if folded == nil { folded = foldInPlace(text) }
                together = firstMatch(foldedPhrase, straight(folded!))
            }
            if let together { return MessageMatch(quality: quality + messagePhraseBonus, offset: together) }
            // Else the shortest stretch that holds every word.
            let near = shortestSpan(positions)
            return MessageMatch(quality: split.long.count > 1 && near.length <= Double(messageNearSpan) ? quality + messageNearBonus : quality,
                                offset: near.start)
        }
    }

    /// The shortest stretch of text holding one place of each word, from each word's places in order.
    static func shortestSpan(_ places: [[Int]]) -> (start: Int, length: Double) {
        let hits = places.enumerated().flatMap { word, at in at.map { (index: $0, word: word) } }.sorted { $0.index < $1.index }
        var counts = [Int](repeating: 0, count: places.count)
        var covered = 0
        var best = (start: hits.first?.index ?? 0, length: Double.infinity)
        var left = 0
        for hit in hits {
            counts[hit.word] += 1
            if counts[hit.word] == 1 { covered += 1 }
            while covered == places.count {
                let first = hits[left]
                if Double(hit.index - first.index) < best.length { best = (first.index, Double(hit.index - first.index)) }
                counts[first.word] -= 1
                if counts[first.word] == 0 { covered -= 1 }
                left += 1
            }
        }
        return best
    }

    /// `findSearchTokenRanges`: ranges of `text` holding a long message search token, for message snippets,
    /// ignoring case and accents. A short long token only counts where it starts a word.
    public static func findSearchTokenRanges(_ text: String, query: String) -> [SearchRange] {
        var tokens: [(Units, Bool)] = []
        for token in messageSearchTokens(query).long {
            let folded = Units(foldSearchQuery(token).utf16)
            // Some tokens fold to nothing ("´´´"), which would match everywhere.
            guard !folded.isEmpty, !tokens.contains(where: { $0.0 == folded }) else { continue }
            tokens.append((folded, token.unicodeScalars.count < messageWordStartLength))
        }
        guard !tokens.isEmpty else { return [] }
        let field = foldSearchField(text)
        var ranges: [SearchRange] = []
        for (token, needsWordStart) in tokens {
            let ownBoundary = !unitIsAlnum(token[0]) && !unitIsSymbol(token[0])
            var found = indexOf(field.text, token)
            while let index = found {
                if needsWordStart && !ownBoundary && !field.wordStarts[index] {
                    found = indexOf(field.text, token, from: index + 1)
                    continue
                }
                ranges.append(SearchRange(start: index, end: index + token.count))
                found = indexOf(field.text, token, from: index + token.count)
            }
        }
        return mergeRanges(ranges)
    }

    /// `findForMessageMatch` (apps/web/src/components/chat/threadFindActionBus.ts:52-75): the text find opens on
    /// for a message match: the words as written together, else the longest word as the snippet writes it, a
    /// whole word first ("Café", not "Cafe" in "Cafeteria").
    public static func findQuery(snippet: String, query: String) -> String {
        let ns = snippet as NSString
        let straight = replacing(curlyApostrophes, in: snippet, with: "'")
        if let phrase = messagePhrase(query),
           let together = phrase.firstMatch(in: straight, range: NSRange(location: 0, length: (straight as NSString).length)) {
            return ns.substring(with: together.range)
        }
        let longest = messageSearchTokens(query).long.reduce("") { $1.utf16.count > $0.utf16.count ? $1 : $0 }
        let word = longest.isEmpty ? query : longest
        let ranges = findSearchTokenRanges(snippet, query: word)
        let units = Units(snippet.utf16)
        let shown = ranges.first { $0.end >= units.count || !unitIsAlnum(units[$0.end]) } ?? ranges.first
        return shown.map { ns.substring(with: NSRange(location: $0.start, length: $0.end - $0.start)) } ?? word
    }

    // MARK: Use (paletteSearch.ts:715-800)

    static let dayMs = 24.0 * 60 * 60 * 1000
    /// Both activity recency and open counts halve every two weeks.
    public static let searchRecencyHalfLifeMs = 14 * dayMs
    /// Opens closer together than this count once, so flipping between threads is not frequency. Clients skip
    /// sending them.
    public static let threadOpenDedupeMs = 10.0 * 60 * 1000
    static let threadSearchPickLimit = 3
    /// Picked queries are stored this long; clients send no more.
    static let threadSearchPickMaxLength = 32
    /// Picks expire from the pick time; opening a thread another way must not extend their priority.
    static let pickWindowMs = 21 * dayMs
    /// The start of a picked query counts from three letters.
    static let pickPrefixMinLength = 3

    /// `pickedQuery`: `query` folded and cut to the stored length without splitting an emoji in two.
    public static func pickedQuery(_ query: String) -> String {
        var cut = Units(foldSearchQuery(query).utf16.prefix(threadSearchPickMaxLength))
        if let last = cut.last, UTF16.isLeadSurrogate(last) { cut.removeLast() }
        return string(cut).trimmingCharacters(in: jsSpaces)
    }

    static func decay(_ ageMs: Double) -> Double { pow(2, -max(0, ageMs) / searchRecencyHalfLifeMs) }

    /// `recordThreadOpen`: next open stats after an open at `at`. `query` is the palette query that picked the
    /// thread, when it was opened from search.
    public static func recordThreadOpen(_ previous: ThreadOpens?, at: Double, query: String?) -> ThreadOpens {
        let pick = pickedQuery(query ?? "")
        // Picks that no longer count are not kept or synced.
        let earlier = (previous?.picks ?? []).filter { at - $0.at <= pickWindowMs }
        let picks = pick.isEmpty ? earlier
            : Array(([ThreadOpens.Pick(query: pick, at: at)] + earlier.filter { $0.query != pick }).prefix(threadSearchPickLimit))
        if let previous, at - previous.openedAt < threadOpenDedupeMs {
            return ThreadOpens(openedAt: previous.openedAt, score: previous.score, picks: picks)
        }
        let score = previous.map { $0.score * decay(at - $0.openedAt) + 1 } ?? 1
        return ThreadOpens(openedAt: at, score: score, picks: picks)
    }

    public struct ThreadSearchSubject {
        public struct PullRequest {
            public var number: Int
            public var title: String?
            /// Values such as URLs, matched only by the whole query.
            public var references: [String]
            public init(number: Int, title: String? = nil, references: [String] = []) {
                self.number = number; self.title = title; self.references = references
            }
        }

        /// Matched only by the whole query, like references.
        public var id: String?
        public var title: String
        public var branch: String?
        public var projectTitle: String?
        /// Only set with two or more environments; it tells same-named threads apart.
        public var environmentLabel: String?
        public var pullRequests: [PullRequest]
        /// Latest user activity, in epoch ms.
        public var activityAt: Double?
        public var opens: ThreadOpens?

        public init(id: String? = nil, title: String, branch: String? = nil, projectTitle: String? = nil, environmentLabel: String? = nil,
                    pullRequests: [PullRequest] = [], activityAt: Double?, opens: ThreadOpens? = nil) {
            self.id = id; self.title = title; self.branch = branch; self.projectTitle = projectTitle
            self.environmentLabel = environmentLabel; self.pullRequests = pullRequests; self.activityAt = activityAt; self.opens = opens
        }
    }

    /// Use reorders matches of about the same quality but never turns a mid-word hit on a busy thread into a
    /// better result than a whole word on a quiet one.
    static let useBoostLimit = 2.5

    /// 1 for a stale, never-opened thread, about 2 for one active today, up to 2.5 for threads opened often.
    static func threadUsageBoost(_ thread: ThreadSearchSubject, now: Double) -> Double {
        let recency = thread.activityAt.map { decay(now - $0) } ?? 0
        let opens = thread.opens.map { $0.score * decay(now - $0.openedAt) } ?? 0
        return min(useBoostLimit, 1 + recency + 0.5 * log2(1 + opens))
    }

    // MARK: Ranking (paletteSearch.ts:802-1205)

    /// A ranked match for a thread, a command or a setting.
    public struct SearchMatch {
        /// Match quality times use; what results sort by.
        public var score: Double
        /// Match quality alone.
        public var quality: Double
        /// The quality its group ranks by, when lower.
        public var groupQuality: Double?
        /// Every token matched at a word start.
        public var strong: Bool
        /// Matched ranges in the title.
        public var ranges: [SearchRange]
        /// Why the thread matched when its title shows no match. Built on demand, for the rows shown.
        public var explain: (() -> SearchMatchHint?)?
        /// When the thread was picked for this query, while that pick lasts.
        public var pickedAt: Double?
        /// Picked for exactly this query.
        public var pickedExactly = false

        public init(score: Double, quality: Double, groupQuality: Double? = nil, strong: Bool, ranges: [SearchRange],
                    explain: (() -> SearchMatchHint?)? = nil, pickedAt: Double? = nil, pickedExactly: Bool = false) {
            self.score = score; self.quality = quality; self.groupQuality = groupQuality; self.strong = strong
            self.ranges = ranges; self.explain = explain; self.pickedAt = pickedAt; self.pickedExactly = pickedExactly
        }
    }

    public struct SearchMatchHint: Equatable {
        public var label: String
        public var text: String
        public var ranges: [SearchRange]
    }

    static let referencePrefixMin = 8

    /// IDs and URLs have many word starts, so a reference needs a long prefix, or any long part holding a digit.
    static func matchReference(_ normalizedQuery: String, _ thread: ThreadSearchSubject) -> SearchFieldsMatch? {
        let query = Units(normalizedQuery.utf16)
        guard query.count >= referencePrefixMin else { return nil }
        let references = (thread.id.map { [$0] } ?? []) + thread.pullRequests.flatMap(\.references)
        let anywhere = query.contains(where: unitIsDigit)
        // A number is never cut short: ".../pull/2288" is not pull request 22889.
        let notCut = { (text: Units, end: Int) in end >= text.count || !unitIsDigit(text[end]) }
        let hit = references.contains { reference in
            let folded = Units(reference.lowercased().utf16)
            let at = indexOf(folded, query)
            // A pasted link may go on past the reference: ".../pull/22889/files".
            return anywhere
                ? (at.map { notCut(folded, $0 + query.count) } ?? false) || (query.starts(with: folded) && notCut(query, folded.count))
                : at == 0
        }
        return hit ? SearchFieldsMatch(quality: 0.6, strong: true, primaryRanges: []) : nil
    }

    /// The latest pick of the thread for this query, while it lasts: the latest exact pick, else the latest pick
    /// the query starts.
    static func activePick(_ thread: ThreadSearchSubject, _ normalizedQuery: String, now: Double) -> ThreadOpens.Pick? {
        let query = pickedQuery(normalizedQuery)
        let prefix = query.utf16.count >= pickPrefixMinLength
        var exact: ThreadOpens.Pick?, latest: ThreadOpens.Pick?
        for pick in thread.opens?.picks ?? [] where now - pick.at <= pickWindowMs {
            if pick.query == query, exact == nil || pick.at > exact!.at { exact = pick }
            let matches = pick.query == query || (prefix && pick.query.hasPrefix(query))
            if matches, latest == nil || pick.at > latest!.at { latest = pick }
        }
        return exact ?? latest
    }

    /// Most threads' branches start with the app's own worktree prefix ("t3/", and "t3code/" before it), so only
    /// before more text does it come off.
    static let worktreeBranchPrefix = try! NSRegularExpression(pattern: "^(?:t3|t3code)/(?=\(jsNotSpace))")
    static let pullRequestPrefix = try! NSRegularExpression(pattern: "^(?:pr|pull request|pull)\(jsSpace)*(?=#?[0-9])")
    static let hashPrefix = try! NSRegularExpression(pattern: "^#\(jsSpace)*")

    static func searchableBranch(_ branch: String?) -> String? {
        branch.flatMap { $0.isEmpty ? nil : replacing(worktreeBranchPrefix, in: $0) }
    }

    /// `matchHint`: the field that explains a match whose title shows none: the first that holds the whole query,
    /// else, past the words the project or environment holds, the first that holds the rest.
    @MainActor static func matchHint(_ normalizedQuery: String, _ thread: ThreadSearchSubject, typos: Bool) -> SearchMatchHint? {
        let candidates: [(String, String?)] = thread.pullRequests.map { ("PR", "#\($0.number)" + ($0.title.map { $0.isEmpty ? "" : " \($0)" } ?? "")) }
            + [("Branch", searchableBranch(thread.branch)), ("Project", thread.projectTitle), ("Environment", thread.environmentLabel)]
        let holds = { (text: String, query: String) in matchSearchFields(query, [WeightedSearchField(value: text, weight: 1)], typos: typos)?.primaryRanges }
        let hintFor = { (query: String) -> SearchMatchHint? in
            for (label, text) in candidates {
                if let text, !text.isEmpty, let ranges = holds(text, query) { return SearchMatchHint(label: label, text: text, ranges: ranges) }
            }
            return nil
        }
        if let whole = hintFor(normalizedQuery) { return whole }
        let contexts = [thread.projectTitle, thread.environmentLabel].compactMap { $0?.isEmpty == false ? $0 : nil }
        let rest = normalizedQuery.split(separator: " ").map(String.init)
            .filter { token in !contexts.contains { holds($0, token) != nil } }.joined(separator: " ")
        return !rest.isEmpty && rest != normalizedQuery ? hintFor(rest) : nil
    }

    /// `scoreThreadSearch`: a thread's score for a normalized query, or nil when it doesn't match. Titles and pull
    /// request numbers count fully, pull request titles and branches less, project and environment names least.
    /// `picks` off where a pick would show up unexplained.
    @MainActor public static func scoreThreadSearch(_ normalizedQuery: String, _ thread: ThreadSearchSubject, now: Double,
                                                    typos: Bool = false, picks: Bool = true) -> SearchMatch? {
        var fields = [WeightedSearchField(value: thread.title, weight: 1, midWord: true)]
        for pullRequest in thread.pullRequests {
            fields.append(WeightedSearchField(value: "#\(pullRequest.number)", weight: 1))
            if let title = pullRequest.title, !title.isEmpty { fields.append(WeightedSearchField(value: title, weight: 0.5)) }
        }
        if let branch = searchableBranch(thread.branch) { fields.append(WeightedSearchField(value: branch, weight: 0.6)) }
        if let project = thread.projectTitle, !project.isEmpty { fields.append(WeightedSearchField(value: project, weight: 0.25, context: true)) }
        if let env = thread.environmentLabel, !env.isEmpty { fields.append(WeightedSearchField(value: env, weight: 0.25, context: true)) }
        // Strip pull request prefixes and the worktree prefix so queries match the stored fields.
        let fieldQuery = replacing(worktreeBranchPrefix, in: replacing(hashPrefix, in: replacing(pullRequestPrefix, in: normalizedQuery)))
        let fieldMatch = matchSearchFields(fieldQuery, fields, typos: typos)
        let referenceMatch = fieldMatch == nil ? matchReference(normalizedQuery, thread) : nil
        guard let match = fieldMatch ?? referenceMatch else { return nil }
        // A row whose title shows no match must say why. With several words, one that can't is a coincidence.
        let titleShowsMatch = !match.primaryRanges.isEmpty
        let checkHint = !titleShowsMatch && referenceMatch == nil && fieldQuery.contains(" ")
        let checkedHint = checkHint ? matchHint(fieldQuery, thread, typos: typos) : nil
        if checkHint && checkedHint == nil { return nil }
        let explain: (() -> SearchMatchHint?)? = titleShowsMatch ? nil : {
            referenceMatch != nil ? SearchMatchHint(label: "ID or link", text: normalizedQuery, ranges: [])
                : (checkedHint ?? matchHint(fieldQuery, thread, typos: typos))
        }
        let pick = picks ? activePick(thread, normalizedQuery, now: now) : nil
        return SearchMatch(score: match.quality * threadUsageBoost(thread, now: now), quality: match.quality,
                           // A thread's whole title never lifts its group over a command or project of that name.
                           groupQuality: min(match.quality, wholeName - 0.01),
                           strong: match.strong, ranges: match.primaryRanges, explain: explain,
                           pickedAt: pick?.at, pickedExactly: pick != nil && pick!.query == pickedQuery(normalizedQuery))
    }

    /// When the user last used a thread: their last message or their last open.
    public static func threadRecentUse(_ thread: ThreadSearchSubject) -> Double {
        max(thread.activityAt ?? 0, thread.opens?.openedAt ?? 0)
    }

    /// A thread that keeps using the word outweighs a recent passing mention.
    static func messageMatchWeight(_ hits: Int) -> Double { 1 + log2(1 + Double(hits)) }

    /// `rankMessageMatches`: `withoutTitleMatches` keeps message rows for threads the palette hasn't listed.
    @MainActor public static func rankMessageMatches<T>(_ matches: [T], quality: (T) -> Double?, hits: (T) -> Int?,
                                                        messageCreatedAt: (T) -> String?, subjectOf: (T) -> ThreadSearchSubject?,
                                                        normalizedQuery: String, now: Double, picks: Bool = true,
                                                        withoutTitleMatches: Bool = false) -> [T] {
        let scored = matches.enumerated().compactMap { index, match -> (T, Double, Double, Double, String, Int)? in
            guard let subject = subjectOf(match) else { return nil }
            if withoutTitleMatches, scoreThreadSearch(normalizedQuery, subject, now: now, picks: false) != nil { return nil }
            // Older servers send no quality; their matches count as words.
            let q = quality(match) ?? 1
            let pickedAt = picks ? activePick(subject, normalizedQuery, now: now)?.at ?? 0 : 0
            return (match, q, pickedAt, messageMatchWeight(hits(match) ?? 1) * threadUsageBoost(subject, now: now), messageCreatedAt(match) ?? "", index)
        }
        return scored.sorted { l, r in
            // Word matches first; among them a pick, then the closer match.
            let lw = l.1 >= messagePrefix, rw = r.1 >= messagePrefix
            if lw != rw { return lw }
            if l.2 != r.2 { return l.2 > r.2 }
            if l.1 != r.1 { return l.1 > r.1 }
            if l.3 != r.3 { return l.3 > r.3 }
            if l.4 != r.4 { return l.4 > r.4 }
            return l.5 < r.5
        }.map(\.0)
    }

    /// Palette limits shared by web and mobile.
    public static let paletteThreadLimit = 20
    public static let paletteMessageLimit = 10
    /// Next to matching threads, other groups show only their best few rows.
    public static let paletteSecondaryLimit = 3

    /// Whole words and prefixes share a class so "Compact" does not lift settings over "Compaction".
    static func matchClass(_ quality: Double) -> Int {
        quality >= wholeName ? 3 : quality >= 0.7 ? 2 : quality >= 0.4 ? 1 : 0
    }

    /// `rankSearchGroups`: groups by match class, so typing stays stable and thread use never outweighs equal
    /// commands. Typos are tried only without word-start matches.
    @MainActor public static func rankSearchGroups<G, T>(_ groups: [(group: G, items: [T])],
                                                         score: (T, Bool, G) -> SearchMatch?) -> [(group: G, ranked: [(item: T, match: SearchMatch)])] {
        func rank(_ typos: Bool) -> [(G, [(item: T, match: SearchMatch)])] {
            groups.map { g in (g.group, g.items.compactMap { item in score(item, typos, g.group).map { (item: item, match: $0) } }) }
        }
        var ranked = rank(false)
        if !ranked.contains(where: { $0.1.contains { $0.match.strong } }) { ranked = rank(true) }
        // Use can't lift a project-only match above a title match or cross match classes. Picks reorder word
        // matches, keeping typos and mid-word hits below them.
        let wordMatch = { (m: SearchMatch) in min(matchClass(m.quality), 2) }
        let exactPickAt = { (m: SearchMatch) in m.pickedExactly ? m.pickedAt ?? 0 : 0 }
        let sortedGroups = ranked.enumerated().compactMap { order, entry -> (G, [(item: T, match: SearchMatch)], Int, Int)? in
            guard !entry.1.isEmpty else { return nil }
            let sorted = entry.1.enumerated().sorted { le, re in
                let l = le.element.match, r = re.element.match
                if wordMatch(l) != wordMatch(r) { return wordMatch(l) > wordMatch(r) }
                if exactPickAt(l) != exactPickAt(r) { return exactPickAt(l) > exactPickAt(r) }
                if matchClass(l.quality) != matchClass(r.quality) { return matchClass(l.quality) > matchClass(r.quality) }
                if (l.pickedAt ?? 0) != (r.pickedAt ?? 0) { return (l.pickedAt ?? 0) > (r.pickedAt ?? 0) }
                if l.score != r.score { return l.score > r.score }
                return le.offset < re.offset
            }.map(\.element)
            let best = entry.1.map { matchClass($0.match.groupQuality ?? $0.match.quality) }.max() ?? 0
            return (entry.0, sorted, best, order)
        }
        return sortedGroups.sorted { $0.2 != $1.2 ? $0.2 > $1.2 : $0.3 < $1.3 }.map { (group: $0.0, ranked: $0.1) }
    }

    /// `rankSearchGroups` for a single list.
    @MainActor public static func rankSearchItems<T>(_ items: [T], score: (T, Bool) -> SearchMatch?) -> [(item: T, match: SearchMatch)] {
        rankSearchGroups([(group: 0, items: items)], score: { item, typos, _ in score(item, typos) }).first?.ranked ?? []
    }

    static let keywordQuality = 0.65
    /// Below this, keyword prefixes match too much: "co" or "pro" would list most settings.
    static let keywordQueryMinLength = 4

    /// `scoreSearchTerms`: keywords count less so hidden terms can't lift a group above a matching name, and short
    /// queries need whole keywords.
    @MainActor public static func scoreSearchTerms(_ normalizedQuery: String, _ terms: [String], typos: Bool = false) -> SearchMatch? {
        // Filler words ("the ci") do not make a short query long.
        let meaningful = normalizedQuery.split(separator: " ").filter { !fillerWords.contains(String($0)) }.joined(separator: " ")
        let short = (meaningful.isEmpty ? normalizedQuery : meaningful).utf16.count < keywordQueryMinLength
        let fields = terms.enumerated().map { index, value in
            index == 0 ? WeightedSearchField(value: value, weight: 1)
                // An alias typed in full ("pr") is deliberate, above a mere name prefix.
                : WeightedSearchField(value: value, weight: short ? 0.8 : 0.6, wholeWords: short, keyword: true)
        }
        guard let match = matchSearchFields(normalizedQuery, fields, typos: typos) else { return nil }
        // Below the word-start class: a match only in hidden keywords must not put its group above a result whose
        // name matches.
        return SearchMatch(score: match.quality, quality: match.quality,
                           groupQuality: match.primaryRanges.isEmpty ? min(match.quality, keywordQuality) : nil,
                           strong: match.strong, ranges: match.primaryRanges)
    }
}

extension PaletteScoring {
    /// `threadSearchSubject` (packages/client-runtime/src/state/threadSearch.ts:203-233): what the palette ranks a
    /// thread shell by. Pass the environment label only with two or more environments.
    @MainActor public static func threadSearchSubject(_ thread: ThreadShell, projectTitle: String?, environmentLabel: String? = nil) -> ThreadSearchSubject {
        // What the user wrote, not agent wakes or task notices in the user role. A thread the user never wrote in
        // counts from its creation. T3 falls back to the latest user-role message where a server omits the field,
        // but every server this app supports sends it (since 2861, 1302ccacbd), so nil here is its null.
        let activity = (thread.latestUserAuthoredMessageAt ?? thread.createdAt).epochMs.map(Double.init)
        let local = ThreadOpenLog.localOpenedAt(thread.id) ?? 0
        let server = thread.opens.value
        // This client's own latest open counts too: the server merged it, or ignores opens.
        let opens = local > (server?.openedAt ?? 0)
            ? ThreadOpens(openedAt: local, score: server?.score ?? 1, picks: server?.picks ?? []) : server
        return ThreadSearchSubject(id: thread.id.localId.rawValue, title: thread.title, branch: thread.branch, projectTitle: projectTitle,
                                   environmentLabel: environmentLabel, pullRequests: searchPullRequests(thread), activityAt: activity?.isFinite == true ? activity : nil, opens: opens)
    }

    /// `threadSearchPullRequests` (packages/shared/src/threadPullRequests.ts:23-53): every pull request matches by
    /// number and link, only the newest three by title.
    static func searchPullRequests(_ thread: ThreadShell) -> [ThreadSearchSubject.PullRequest] {
        let entry = { (repository: String, number: Int, url: String, title: String?) in
            ThreadSearchSubject.PullRequest(number: number, title: title, references: ["\(repository)#\(number)", url])
        }
        let branch = thread.branchPullRequest.map { [entry($0.repository, $0.number, $0.url, nil)] } ?? []
        if let links = thread.pullRequests, !links.isEmpty {
            let updated = { (l: ThreadPullRequestLink) in (l.snapshot?.updatedAt ?? l.linkedAt).epochMs ?? 0 }
            let newestFirst = ThreadPullRequests.visible(links).enumerated()
                .sorted { updated($0.element) != updated($1.element) ? updated($0.element) > updated($1.element) : $0.offset < $1.offset }
                .map(\.element)
            return branch + newestFirst.enumerated().map { index, l in entry(l.repository, l.number, l.url, index < 3 ? l.snapshot?.title : nil) }
        }
        return branch + (thread.linkedPullRequest.map { [entry($0.repository, $0.number, $0.url, nil)] } ?? [])
    }
}
