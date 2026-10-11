import Foundation

/// T3's release note shaping (apps/desktop/src/updates/releaseNotes.ts): GitHub release bodies become the
/// popover's groups. At most 6 groups and 8 bullets each; a bullet is cut to 220 characters.
public enum DesktopUpdateReleaseNotes {
    static let maxGroups = 6
    static let maxItemsPerGroup = 8
    static let maxItemLength = 220

    /// `normalizeDesktopUpdateReleaseNotes` (releaseNotes.ts:136-165). `notes` are the releases newer than the
    /// running one that the selected track can install, newest first. T3 keeps releases whose version names the
    /// followed track (:147); Sparkle's channels decide that here, so the caller passes only those.
    public static func normalize(_ notes: [(version: String, note: String?)]) -> (notes: [DesktopUpdateState.ReleaseNote], omitted: Int) {
        let groups = notes.compactMap { entry -> DesktopUpdateState.ReleaseNote? in
            let (items, total) = extractItems(entry.note)
            return total == 0 ? nil : DesktopUpdateState.ReleaseNote(version: entry.version, items: items, totalItems: total)
        }
        return (Array(groups.prefix(maxGroups)), max(0, groups.count - maxGroups))
    }

    /// releaseNotes.ts:100-120: the last 8 bullets, newest line first.
    static func extractItems(_ note: String?) -> (items: [String], total: Int) {
        guard let note, !note.isEmpty else { return ([], 0) }
        var items: [String] = []
        var total = 0
        for raw in stripMarkup(note).components(separatedBy: "\n") {
            var item = raw.trimmingCharacters(in: .whitespaces)
            item = item.replacingOccurrences(of: #"^[-*]\s+"#, with: "", options: .regularExpression)
            item = item.replacingOccurrences(of: #"^\d+[.)]\s+"#, with: "", options: .regularExpression)
            item = item.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            let normalized = normalizeLine(item)
            if normalized == "new contributors" || normalized == "full changelog" { break }
            if item.range(of: #"^#{1,6}\s+"#, options: .regularExpression) != nil { continue }
            if isIgnored(item) { continue }
            total += 1
            items.append(truncate(item))
            if items.count > maxItemsPerGroup { items.removeFirst() }
        }
        return (items.reversed(), total)
    }

    /// releaseNotes.ts:59-70.
    static func stripMarkup(_ input: String) -> String {
        var s = input
        func sub(_ pattern: String, _ template: String) {
            s = s.replacingOccurrences(of: pattern, with: template, options: [.regularExpression, .caseInsensitive])
        }
        sub(#"<br\s*/?>"#, "\n")
        sub(#"<li\b[^>]*>"#, "\n- ")
        for level in 1...6 { sub("<h\(level)\\b[^>]*>", "\n" + String(repeating: "#", count: level) + " ") }
        sub(#"</(?:p|div|li|h[1-6]|ul|ol|blockquote)>"#, "\n")
        sub(#"<[^>]*>"#, "")
        s = s.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\*\*([^*]+)\*\*"#, with: "$1", options: .regularExpression)
        return decodeEntities(s)
    }

    /// releaseNotes.ts:23-57.
    static func decodeEntities(_ input: String) -> String {
        let named = ["amp": "&", "apos": "'", "gt": ">", "lt": "<", "nbsp": " ", "quot": "\""]
        guard let regex = try? NSRegularExpression(pattern: "&([a-zA-Z]+|#\\d+|#x[0-9a-fA-F]+);") else { return input }
        let ns = input as NSString
        var out = ""
        var last = 0
        for m in regex.matches(in: input, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let entity = ns.substring(with: m.range(at: 1))
            var decoded = "&\(entity);"
            if let n = named[entity] {
                decoded = n
            } else if entity.hasPrefix("#") {
                let hex = entity.hasPrefix("#x")
                if let code = UInt32(entity.dropFirst(hex ? 2 : 1), radix: hex ? 16 : 10), let scalar = Unicode.Scalar(code) {
                    decoded = String(Character(scalar))
                }
            }
            out += decoded
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }

    static func normalizeLine(_ line: String) -> String {
        line.lowercased().replacingOccurrences(of: "[*_`#]", with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    static func isIgnored(_ line: String) -> Bool {
        let n = normalizeLine(line)
        return n.isEmpty || n == "what's changed" || n == "whats changed" || n.hasPrefix("compare: ") || n.contains("/compare/")
    }

    /// releaseNotes.ts:72-75. JavaScript counts UTF-16 units.
    static func truncate(_ item: String) -> String {
        let units = Array(item.utf16)
        guard units.count > maxItemLength else { return item }
        let head = String(decoding: units.prefix(maxItemLength - 3), as: UTF16.self)
        return head.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) + "..."
    }
}
