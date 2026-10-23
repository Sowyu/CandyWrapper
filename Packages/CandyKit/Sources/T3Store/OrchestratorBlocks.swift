import Foundation
import T3Protocol

/// The fenced blocks Redesign takes out of the Orchestrator's replies (docs/orchestrator.md, "More than a thread").
/// To the official app they stay plain text.
public struct OrchestratorReply: Equatable, Sendable {
    public struct PlanStep: Equatable, Sendable {
        public var text: String
        public var done: Bool
        /// The local thread id the step links to, from a `t3-thread://v1/<id>` link.
        public var threadId: String?
    }

    public struct Memory: Equatable, Sendable {
        /// One of `OrchestratorNotebook.names`.
        public var note: String
        public var text: String
    }

    /// The reply without its blocks.
    public var text: String
    public var plan: [PlanStep]?
    public var memories: [Memory]
    public var digest: String?

    /// Splits `text` into prose and blocks. An unclosed block (a reply still streaming) stays out of the prose until
    /// it closes, so it never flashes as code.
    public static func parse(_ text: String) -> OrchestratorReply {
        var prose: [Substring] = []
        var plan: [PlanStep]?
        var memories: [Memory] = []
        var digest: String?
        var open: (kind: String, fence: Substring, lines: [Substring])?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop { $0 == " " }
            if var block = open {
                if trimmed.hasPrefix(block.fence), trimmed.drop(while: { $0 == "`" || $0 == "~" }).allSatisfy(\.isWhitespace) {
                    let body = block.lines.joined(separator: "\n")
                    switch block.kind {
                    case "orchestrator-plan": plan = (plan ?? []) + steps(body)
                    case "orchestrator-memory": if let m = memory(body) { memories.append(m) }
                    default: digest = body.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    open = nil
                } else {
                    block.lines.append(line)
                    open = block
                }
                continue
            }
            let fence = trimmed.prefix { $0 == "`" || $0 == "~" }
            if fence.count >= 3 {
                let info = trimmed.dropFirst(fence.count).trimmingCharacters(in: .whitespaces).lowercased()
                if ["orchestrator-plan", "orchestrator-memory", "orchestrator-digest"].contains(info) {
                    open = (info, fence, [])
                    continue
                }
            }
            prose.append(line)
        }
        let joined = prose.joined(separator: "\n").replacingOccurrences(of: "\n\n\n+", with: "\n\n", options: .regularExpression)
        return OrchestratorReply(text: joined.trimmingCharacters(in: .whitespacesAndNewlines), plan: plan, memories: memories, digest: digest)
    }

    /// Numbered or bulleted lines become steps; `[x]` or `✓` marks one done.
    static func steps(_ body: String) -> [PlanStep] {
        body.split(separator: "\n").compactMap { raw in
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return nil }
            if let r = line.range(of: #"^(\d+[.)]|[-*+])\s+"#, options: .regularExpression) { line.removeSubrange(r) }
            else { return nil }
            var done = false
            if let r = line.range(of: #"^\[( |x|X)\]\s*"#, options: .regularExpression) {
                done = line[r].lowercased().contains("x")
                line.removeSubrange(r)
            }
            if line.hasPrefix("✓") || line.hasPrefix("✅") { done = true; line = String(line.drop { !$0.isLetter && !$0.isNumber }) }
            if line.localizedCaseInsensitiveContains("(done)") { done = true }
            let thread = line.range(of: #"t3-thread://v1/([A-Za-z0-9_-]+)"#, options: .regularExpression)
                .map { String(line[$0].dropFirst("t3-thread://v1/".count)) }
            return PlanStep(text: line, done: done, threadId: thread)
        }
    }

    /// `note: plan` (or a bare `plan`, or `# plan`) on the first line, then the note's full text.
    static func memory(_ body: String) -> Memory? {
        var lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        guard let first = lines.first else { return nil }
        var name = first.trimmingCharacters(in: .whitespaces).lowercased()
        for prefix in ["note:", "name:", "#"] where name.hasPrefix(prefix) { name = name.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces) }
        name = name.replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "crew_rules", with: "crew-rules")
        guard OrchestratorNotebook.names.contains(name) else { return nil }
        let text = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return Memory(note: name, text: text)
    }

    /// Strips the step's markdown link syntax for display: `[Fixer](t3-thread://v1/x)` reads "Fixer".
    public static func displayText(_ step: PlanStep) -> String {
        step.text.replacingOccurrences(of: #"\[([^\]]+)\]\(t3-thread://v1/[^)]+\)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\(?t3-thread://v1/[A-Za-z0-9_-]+\)?"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}
