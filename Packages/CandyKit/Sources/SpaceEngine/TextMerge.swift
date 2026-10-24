import Foundation
import SpaceModel

/// Three-way merge of rich text by characters (docs/space.md, "Conflicts"). Characters are Unicode
/// scalars, so no merge splits a surrogate pair; marks still count UTF-16 units.
public enum TextMerge {
    /// One differing stretch: `a` in the old sequence became `b` in the new one.
    struct Hunk: Equatable {
        var a: Range<Int>
        var b: Range<Int>
    }

    /// Returns the merge, or nil when the two sides' changes overlap and the caller keeps a conflict copy.
    /// Non-overlapping changes merge and marks follow their text. Where both sides changed the marks
    /// on a character, the confirmed side's marks win.
    public static func merge(base: RichText, ours: RichText, confirmed theirs: RichText) -> RichText? {
        if ours == theirs || ours == base { return theirs }
        if theirs == base { return ours }
        let b = Array(base.t.unicodeScalars), o = Array(ours.t.unicodeScalars), t = Array(theirs.t.unicodeScalars)
        let ourHunks = diff(b, o), theirHunks = diff(b, t)

        // Both sides' hunks in base order. A hunk both sides made identically appears once.
        enum Side { case ours, theirs, both(Int) }
        var merged: [(hunk: Hunk, side: Side)] = []
        var twins: Set<Int> = []
        for ourHunk in ourHunks {
            var side = Side.ours
            for (index, theirHunk) in theirHunks.enumerated() {
                if ourHunk.a == theirHunk.a && o[ourHunk.b] == t[theirHunk.b] {
                    side = .both(index); twins.insert(index)
                } else if overlaps(ourHunk.a, theirHunk.a) { return nil }
            }
            merged.append((ourHunk, side))
        }
        for (index, hunk) in theirHunks.enumerated() where !twins.contains(index) { merged.append((hunk, .theirs)) }
        // An insertion goes before a replacement that starts at the same place.
        merged.sort { ($0.hunk.a.lowerBound, $0.hunk.a.isEmpty ? 0 : 1) < ($1.hunk.a.lowerBound, $1.hunk.a.isEmpty ? 0 : 1) }

        enum Origin { case base(Int), ours(Int), theirs(Int) }
        var scalars: [Unicode.Scalar] = [], origins: [Origin] = []
        var position = 0
        for (hunk, side) in merged {
            for i in position..<hunk.a.lowerBound { scalars.append(b[i]); origins.append(.base(i)) }
            switch side {
            case .ours: for j in hunk.b { scalars.append(o[j]); origins.append(.ours(j)) }
            case .theirs: for j in hunk.b { scalars.append(t[j]); origins.append(.theirs(j)) }
            case .both(let index): for j in theirHunks[index].b { scalars.append(t[j]); origins.append(.theirs(j)) }
            }
            position = max(position, hunk.a.upperBound)
        }
        for i in position..<b.count { scalars.append(b[i]); origins.append(.base(i)) }

        let baseMarks = markSets(base), ourMarks = markSets(ours), theirMarks = markSets(theirs)
        let ourAlign = alignment(ourHunks, count: b.count), theirAlign = alignment(theirHunks, count: b.count)
        let marks: [Set<MarkKey>] = origins.map { origin in
            switch origin {
            case .ours(let j): return ourMarks[j]
            case .theirs(let j): return theirMarks[j]
            case .base(let i):
                // A base character in the merge survived on both sides.
                let mine = ourMarks[ourAlign[i]!], confirmed = theirMarks[theirAlign[i]!]
                return confirmed != baseMarks[i] ? confirmed : mine
            }
        }
        var text = String()
        text.unicodeScalars.append(contentsOf: scalars)
        return RichText(t: text, m: runs(marks, scalars), extra: theirs.extra)
    }

    /// Ranges overlap when they share a character, or when both insert at the same place.
    static func overlaps(_ x: Range<Int>, _ y: Range<Int>) -> Bool {
        if x.isEmpty && y.isEmpty { return x.lowerBound == y.lowerBound }
        return x.lowerBound < y.upperBound && y.lowerBound < x.upperBound
    }

    /// Maps each base index to its index on the side, or nil where the side changed it.
    static func alignment(_ hunks: [Hunk], count: Int) -> [Int?] {
        var result = [Int?](repeating: nil, count: count)
        var i = 0, j = 0
        for hunk in hunks {
            while i < hunk.a.lowerBound { result[i] = j; i += 1; j += 1 }
            i = hunk.a.upperBound; j = hunk.b.upperBound
        }
        while i < count { result[i] = j; i += 1; j += 1 }
        return result
    }

    enum Step { case equal, delete, insert }

    struct MarkKey: Hashable { var kind: MarkKind; var value: String? }

    /// The marks covering each scalar, read at the scalar's first UTF-16 unit.
    static func markSets(_ text: RichText) -> [Set<MarkKey>] {
        var offsets: [Int] = [], offset = 0
        for scalar in text.t.unicodeScalars { offsets.append(offset); offset += scalar.utf16.count }
        return offsets.map { at in Set(text.m.filter { $0.start <= at && at < $0.end }.map { MarkKey(kind: $0.kind, value: $0.value) }) }
    }

    /// Rebuilds marks as maximal runs, so adjacent marks of one kind and value join.
    static func runs(_ sets: [Set<MarkKey>], _ scalars: [Unicode.Scalar]) -> [TextMark] {
        var offsets: [Int] = [], offset = 0
        for scalar in scalars { offsets.append(offset); offset += scalar.utf16.count }
        offsets.append(offset)
        var result: [TextMark] = []
        for key in Set(sets.flatMap { $0 }) {
            var start: Int?
            for index in 0...sets.count {
                let inside = index < sets.count && sets[index].contains(key)
                if inside, start == nil { start = index }
                if !inside, let s = start {
                    result.append(TextMark(start: offsets[s], end: offsets[index], kind: key.kind, value: key.value))
                    start = nil
                }
            }
        }
        return result.sorted { ($0.start, $0.end, $0.kind.rawValue, $0.value ?? "") < ($1.start, $1.end, $1.kind.rawValue, $1.value ?? "") }
    }

    /// Myers' O(ND) diff, after trimming the common prefix and suffix.
    /// ponytail: past `limit` edits it returns one hunk for the whole middle, which merges less; raise it if real blocks hit it.
    static func diff<T: Equatable>(_ a: [T], _ b: [T], limit: Int = 1_000) -> [Hunk] {
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let n = a.count - prefix - suffix, m = b.count - prefix - suffix
        if n == 0 && m == 0 { return [] }
        let whole = [Hunk(a: prefix..<prefix + n, b: prefix..<prefix + m)]
        if n == 0 || m == 0 { return whole }

        let maxD = min(n + m, limit), offset = maxD + 1
        var v = [Int](repeating: 0, count: 2 * maxD + 3)
        var trace: [[Int]] = []
        var found = false
        search: for d in 0...maxD {
            trace.append(Array(v[(offset - d)...(offset + d)]))
            for k in stride(from: -d, through: d, by: 2) {
                var x = (k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1])) ? v[offset + k + 1] : v[offset + k - 1] + 1
                var y = x - k
                while x < n, y < m, a[prefix + x] == b[prefix + y] { x += 1; y += 1 }
                v[offset + k] = x
                if x >= n, y >= m { found = true; break search }
            }
        }
        guard found else { return whole }

        var steps: [Step] = []
        var x = n, y = m
        for d in stride(from: trace.count - 1, through: 0, by: -1) {
            if d == 0 {
                while x > 0 { steps.append(.equal); x -= 1; y -= 1 }
                break
            }
            let row = trace[d]
            func at(_ k: Int) -> Int { row[k + d] }
            let k = x - y
            let previousK = (k == -d || (k != d && at(k - 1) < at(k + 1))) ? k + 1 : k - 1
            let previousX = at(previousK), previousY = previousX - previousK
            while x > previousX, y > previousY { steps.append(.equal); x -= 1; y -= 1 }
            steps.append(x == previousX ? .insert : .delete)
            x = previousX; y = previousY
        }

        var hunks: [Hunk] = []
        var i = 0, j = 0
        var start: (Int, Int)?
        for step in steps.reversed() {
            if step == .equal {
                if let s = start { hunks.append(Hunk(a: prefix + s.0..<prefix + i, b: prefix + s.1..<prefix + j)); start = nil }
                i += 1; j += 1
            } else {
                if start == nil { start = (i, j) }
                if step == .delete { i += 1 } else { j += 1 }
            }
        }
        if let s = start { hunks.append(Hunk(a: prefix + s.0..<prefix + i, b: prefix + s.1..<prefix + j)) }
        return hunks
    }
}
