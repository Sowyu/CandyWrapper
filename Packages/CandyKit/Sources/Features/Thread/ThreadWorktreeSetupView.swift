import AppKit
import DesignSystem
import T3Protocol

/// worktreeSetup.ts:34-72; WorktreeSetupCard.tsx:334-438.
public struct ThreadWorktreeSetupSnapshot: Decodable, Equatable, Sendable {
    public struct Stage: Decodable, Equatable, Sendable {
        public var id: String
        public var status: String
        public var percent: Int?
        public var detail: String?
        public var tail: [String]
        public var label: String {
            switch id {
            case "fetch": "Fetch base branch"
            case "checkout": "Check out files"
            case "submodules": "Init submodules"
            case "setup-script": "Run setup script"
            case "agent": "Start agent"
            default: id
            }
        }
    }
    public var threadId: String
    public var phase: String
    public var sequence: Int
    public var stages: [Stage]
    public var error: String?
    public struct Script: Decodable, Equatable, Sendable { public var name: String; public var command: String; public var terminalId: String }
    public var setupScript: Script?
    public var terminalId: String? { setupScript?.terminalId }
    public var agentStarted: Bool { stages.contains { $0.id == "agent" && $0.status == "done" } }
}

// ponytail: live setup summary only, add recorded fallback and retry/work-locally with the full setup details flow.
public final class ThreadWorktreeSetupView: DSView {
    public var snapshot: ThreadWorktreeSetupSnapshot? { didSet { if snapshot != oldValue { rebuild() } } }
    public var onCancel: (() -> Void)?
    public var onOpenTerminal: (() -> Void)?
    public var onHeightChange: (() -> Void)?
    private let title = LabelView("Worktree setup", font: DSFont.ui(13, weight: .medium), color: Themed.color(\.mutedForeground))
    private let cancel = ButtonView("Cancel", icon: .x, variant: .ghostMuted, size: .xs)
    private let terminal = ButtonView("Open terminal", icon: .terminal, variant: .ghostMuted, size: .xs)
    private let details = ButtonView("Details", icon: .chevronRight, variant: .ghostMuted, size: .xs)
    private let body = TextBlockView("", font: DSFont.ui(13), lineHeight: 24, color: Themed.color(\.mutedForeground))
    private let tail = TextBlockView("", font: DSFont.mono(11), lineHeight: 16, color: Themed.color(\.mutedForeground))
    private var expanded = false
    public override init(frame: NSRect) {
        super.init(frame: frame)
        [title, body, tail, cancel, terminal, details].forEach(addSubview)
        cancel.action = { [weak self] in self?.onCancel?() }
        terminal.action = { [weak self] in self?.onOpenTerminal?() }
        details.action = { [weak self] in guard let self else { return }; expanded.toggle(); rebuild() }
        tail.maxLines = 5
    }
    private func rebuild() {
        guard let snapshot else { isHidden = true; onHeightChange?(); return }
        isHidden = false
        let collapsed = snapshot.agentStarted && snapshot.phase != "running" && !expanded
        body.text = collapsed ? "Worktree setup \(snapshot.phase)" : snapshot.stages.map { stage in
            let mark = stage.status == "done" ? "✓" : stage.status == "failed" ? "×" : stage.status == "running" ? "◉" : "○"
            return "\(mark)   \(stage.label)\(stage.percent.map { "  \($0)%" } ?? "")\(stage.detail.map { "  " + $0 } ?? "")"
        }.joined(separator: "\n")
        if let error = snapshot.error { body.text += "\n" + error }
        let script = snapshot.stages.first { $0.id == "setup-script" }
        tail.text = script.map { $0.status == "running" || $0.status == "failed" ? $0.tail.suffix(5).joined(separator: "\n") : "" } ?? ""
        tail.isHidden = tail.text.isEmpty || collapsed
        cancel.isHidden = snapshot.phase != "running"
        terminal.isHidden = script == nil || script?.status == "pending" || onOpenTerminal == nil
        details.icon = expanded ? .chevronDown : .chevronRight
        needsLayout = true; onHeightChange?()
    }
    public func height(forWidth width: CGFloat) -> CGFloat {
        guard snapshot != nil else { return 0 }
        return 24 + body.height(forWidth: max(1, width - 32)) + (tail.isHidden ? 0 : 88) + 32
    }
    public override func layout() {
        super.layout()
        title.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 20)
        let h = body.height(forWidth: max(1, bounds.width - 32))
        body.frame = NSRect(x: 28, y: 24, width: bounds.width - 32, height: h)
        tail.frame = NSRect(x: 28, y: 24 + h, width: bounds.width - 32, height: tail.isHidden ? 0 : 80)
        var x: CGFloat = 20
        for button in [details, terminal, cancel] where !button.isHidden {
            let w = button.intrinsicContentSize.width
            button.frame = NSRect(x: x, y: bounds.height - 28, width: w, height: 24); x += w + 4
        }
    }
}
