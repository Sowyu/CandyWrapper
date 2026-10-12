import Foundation

/// Find in thread's matching (packages/shared/src/threadSearch.ts): T3 lower-cases both sides (a final sigma
/// counts as a sigma), keeps a character whose lower case changes its length, and takes non-overlapping
/// matches left to right. Offsets are UTF-16, as in JavaScript, so the occurrence numbers agree with the
/// server's `countThreadSearchOccurrences`.
public enum ThreadFindText {
    public static func occurrences(_ text: String, _ query: String) -> [NSRange] {
        guard !text.isEmpty, !query.isEmpty else { return [] }
        let haystack = fold(text), needle = fold(query)
        guard needle.count <= haystack.count, let first = needle.first else { return [] }
        var ranges: [NSRange] = []
        var cursor = 0
        while cursor <= haystack.count - needle.count {
            guard let start = haystack[cursor...].firstIndex(of: first), start <= haystack.count - needle.count else { break }
            if haystack[start..<start + needle.count].elementsEqual(needle) {
                ranges.append(NSRange(location: start, length: needle.count))
                cursor = start + needle.count
            } else {
                cursor = start + 1
            }
        }
        return ranges
    }

    public static func count(_ text: String, _ query: String) -> Int { occurrences(text, query).count }

    /// `foldThreadSearchCase`.
    static func fold(_ text: String) -> [UInt16] {
        let lowered = text.lowercased().replacingOccurrences(of: "ς", with: "σ")
        if lowered.utf16.count == text.utf16.count { return Array(lowered.utf16) }
        var out: [UInt16] = []
        out.reserveCapacity(text.utf16.count)
        for scalar in text.unicodeScalars {
            let original = String(scalar)
            let folded = original.lowercased().replacingOccurrences(of: "ς", with: "σ")
            out += folded.utf16.count == original.utf16.count ? Array(folded.utf16) : Array(original.utf16)
        }
        return out
    }

    /// The text find matches in `string` (its `markdownFindText` replacements applied) and, for each UTF-16 unit
    /// of it, the range of `string` that unit stands for. A replacement that spells the characters it covers once
    /// the chip's no-break space and word joiners are dropped maps unit by unit; any other covers its whole range.
    static func index(_ string: NSAttributedString) -> (text: String, sources: [NSRange]) {
        let source = string.string as NSString
        var units: [UInt16] = []
        var sources: [NSRange] = []
        units.reserveCapacity(source.length)
        sources.reserveCapacity(source.length)
        string.enumerateAttribute(.markdownFindText, in: NSRange(location: 0, length: source.length)) { value, range, _ in
            guard let replacement = value as? String else {
                for k in range.location..<range.upperBound { units.append(source.character(at: k)); sources.append(NSRange(location: k, length: 1)) }
                return
            }
            let shown = (0..<range.length).map { range.location + $0 }.filter { k in
                let c = source.character(at: k)
                return c != 0x2060 && !(c == 0x00A0 && k == range.location)
            }
            let wanted = Array(replacement.utf16)
            if shown.count == wanted.count, shown.map({ source.character(at: $0) }) == wanted {
                for (k, unit) in zip(shown, wanted) { units.append(unit); sources.append(NSRange(location: k, length: 1)) }
            } else {
                for unit in wanted { units.append(unit); sources.append(range) }
            }
        }
        return (String(utf16CodeUnits: units, count: units.count), sources)
    }
}
