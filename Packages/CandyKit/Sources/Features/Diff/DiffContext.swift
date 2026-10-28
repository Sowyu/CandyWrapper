import Foundation
import T3Protocol

/// Pierre's expand controls reveal at most 100 lines from either end of a hidden gap.
public enum DiffContextDirection: Sendable { case up, down, both }

extension UnifiedDiff {
    enum ContextError: LocalizedError {
        case changed
        var errorDescription: String? { "The file changed since this diff was loaded. Refresh the diff and try again." }
    }

    /// Hydrate only after a context control is pressed. Keep the recorded changes and line numbers;
    /// refuse contents from a newer checkout instead of showing unrelated lines beside an old patch.
    func expandingContext(file index: Int, gap: Int, contents: ReviewDiffFileContents,
                          direction: DiffContextDirection, count: Int = 100) throws -> UnifiedDiff {
        guard files.indices.contains(index), (0...files[index].hunks.count).contains(gap) else { return self }
        let file = files[index]
        func lines(_ text: String) -> [String] {
            guard !text.isEmpty else { return [] }
            var result = text.components(separatedBy: "\n")
            if result.last == "" { result.removeLast() }
            return result.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        }
        let old = lines(contents.oldContents), new = lines(contents.newContents)
        func oldLower(_ hunk: Hunk) -> Int { hunk.oldStart - (hunk.oldCount > 0 ? 1 : 0) }
        func newLower(_ hunk: Hunk) -> Int { hunk.newStart - (hunk.newCount > 0 ? 1 : 0) }
        for hunk in file.hunks {
            guard oldLower(hunk) >= 0, newLower(hunk) >= 0,
                  oldLower(hunk) + hunk.oldCount <= old.count,
                  newLower(hunk) + hunk.newCount <= new.count else { throw ContextError.changed }
            for i in hunk.lines {
                let line = self.lines[i], text = text(line)
                if line.kind != .addition {
                    guard line.oldNumber > 0, Int(line.oldNumber) <= old.count,
                          old[Int(line.oldNumber) - 1] == text else { throw ContextError.changed }
                }
                if line.kind != .deletion {
                    guard line.newNumber > 0, Int(line.newNumber) <= new.count,
                          new[Int(line.newNumber) - 1] == text else { throw ContextError.changed }
                }
            }
        }
        let previous = gap > 0 ? file.hunks[gap - 1] : nil
        let next = gap < file.hunks.count ? file.hunks[gap] : nil
        let oldStart = previous.map { oldLower($0) + $0.oldCount } ?? 0
        let newStart = previous.map { newLower($0) + $0.newCount } ?? 0
        let oldEnd = next.map(oldLower) ?? old.count
        let newEnd = next.map(newLower) ?? new.count
        guard oldEnd - oldStart == newEnd - newStart, oldEnd >= oldStart,
              Array(old[oldStart..<oldEnd]) == Array(new[newStart..<newEnd]) else { throw ContextError.changed }
        let available = oldEnd - oldStart
        let fromStart = previous != nil && direction != .down ? min(count, available) : 0
        let fromEnd = next != nil && direction != .up ? min(count, available - fromStart) : 0
        var result = self
        result.lines = []
        func appendContext(oldNumber: Int, newNumber: Int) {
            let text = old[oldNumber - 1]
            let start = result.bytes.count
            result.bytes.append(contentsOf: text.utf8)
            result.lines.append(Line(kind: .context,
                noNewline: oldNumber == old.count && newNumber == new.count && !contents.oldContents.hasSuffix("\n") && !contents.newContents.hasSuffix("\n"),
                oldNumber: Int32(oldNumber), newNumber: Int32(newNumber), start: Int32(start), length: Int32(text.utf8.count)))
        }
        for f in files.indices {
            var hunks: [Hunk] = []
            for (h, original) in files[f].hunks.enumerated() {
                var hunk = original
                let first = result.lines.count
                if f == index, h == gap, fromEnd > 0 {
                    for offset in (available - fromEnd)..<available {
                        appendContext(oldNumber: oldStart + offset + 1, newNumber: newStart + offset + 1)
                    }
                    hunk.oldStart = oldLower(original) - fromEnd + 1
                    hunk.newStart = newLower(original) - fromEnd + 1
                    hunk.oldCount += fromEnd; hunk.newCount += fromEnd
                }
                result.lines.append(contentsOf: self.lines[original.lines])
                if f == index, h == gap - 1, fromStart > 0 {
                    for offset in 0..<fromStart {
                        appendContext(oldNumber: oldStart + offset + 1, newNumber: newStart + offset + 1)
                    }
                    hunk.oldStart = oldLower(original) + 1
                    hunk.newStart = newLower(original) + 1
                    hunk.oldCount += fromStart; hunk.newCount += fromStart
                }
                hunk.lines = first..<result.lines.count
                if f == index, let last = hunks.last, last.oldStart + last.oldCount == hunk.oldStart,
                   last.newStart + last.newCount == hunk.newStart {
                    hunks[hunks.count - 1].oldCount += hunk.oldCount
                    hunks[hunks.count - 1].newCount += hunk.newCount
                    hunks[hunks.count - 1].lines = last.lines.lowerBound..<hunk.lines.upperBound
                } else {
                    hunk.collapsedBefore = max(0, hunk.newStart - (hunks.last.map { $0.newStart + $0.newCount } ?? 1))
                    hunks.append(hunk)
                }
            }
            result.files[f].hunks = hunks
        }
        result.files[index].oldLineCount = old.count
        result.files[index].newLineCount = new.count
        return result
    }
}
