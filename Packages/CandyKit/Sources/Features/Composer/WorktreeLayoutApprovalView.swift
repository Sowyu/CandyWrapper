import AppKit
import DesignSystem
import T3Protocol

/// The worktree command approval dialog's body (WorktreeLayoutApprovalDialogHost.tsx:42-79 at 5258, #42386):
/// `Let this project run its worktree commands?`, then per command a `text-xs text-muted-foreground` line saying
/// when it runs over the command in a `pre` (`max-h-48 overflow-auto whitespace-pre-wrap rounded-md border
/// bg-muted/40 px-3 py-2 font-mono text-xs`), `gap-1` inside and `gap-3 pt-2` between them.
public final class WorktreeLayoutApprovalView: DSView {
    public static let title = "Let this project run its worktree commands?"

    /// `WorktreeLayoutApprovalOutcome` (worktreeLayoutApproval.ts:78-82).
    public enum Outcome: Equatable, Sendable { case proceed, cancelled, blocked(String) }

    /// A connection without `terminal:operate` cannot approve (worktreeLayoutApproval.ts:108-117).
    public static let cannotApproveMessage = "This project sets up worktrees with its own command, which nobody has approved as it is written now. "
        + "This connection cannot approve it: approve it from a client that can use the terminal."

    /// `WORKTREE_LAYOUT_COMMAND_LABELS` (:21-24).
    public static func label(kind: String) -> String {
        kind == "remove" ? "Runs when a thread's worktree is removed" : "Runs when a worktree thread starts, and when its folder is restored"
    }

    /// The description, with `t3.json` as plain text where T3 sets it in `code`.
    public static func description(projectTitle: String) -> String {
        "\(projectTitle) sets up worktree threads with its own commands from t3.json. They run on this environment's machine "
            + "with your permissions, outside any agent sandbox. You are asked again whenever their text changes."
    }

    /// The dialog as T3 opens it: `max-w-2xl`, Cancel (outline) and Approve and continue. `answer` gets true for
    /// Approve and false for Cancel, Esc or the close button, once.
    @MainActor
    public static func present(projectTitle: String, commands: [WorktreeLayoutCommand], in window: NSWindow,
                               answer: @escaping @MainActor (Bool) -> Void) {
        let dialog = DialogView(kind: .alertDialog, title: title, message: description(projectTitle: projectTitle))
        dialog.maxWidth = 672
        dialog.headerContent = WorktreeLayoutApprovalView(commands: commands)
        let cancel = ButtonView("Cancel", variant: .outline)
        let approve = ButtonView("Approve and continue", variant: .default)
        dialog.footerButtons = [cancel, approve]
        // Any way out but Approve (Cancel, Esc, the close button) answers false when the dialog goes.
        var approved = false
        let host = ModalHost.present(dialog, in: window)
        host.onDismiss = { answer(approved) }
        cancel.action = { [weak host] in host?.close() }
        approve.action = { [weak host] in approved = true; host?.close() }
    }

    private let rows: [(label: LabelView, block: CommandBlock)]

    public init(commands: [WorktreeLayoutCommand]) {
        rows = commands.map { command in
            let label = LabelView()
            label.text = Self.label(kind: command.kind)
            label.font = DSFont.ui(12)
            label.lineHeight = 16
            label.color = Themed.color(\.mutedForeground)
            return (label, CommandBlock(command.command))
        }
        super.init(frame: .zero)
        for row in rows { addSubview(row.label); addSubview(row.block) }
    }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width))
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        guard !rows.isEmpty else { return 0 }
        return 8 + rows.reduce(0) { $0 + 16 + 4 + $1.block.height(forWidth: width) } + CGFloat(rows.count - 1) * 12
    }

    public override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { invalidateIntrinsicContentSize() }
    }

    public override func layout() {
        super.layout()
        var y: CGFloat = 8
        for row in rows {
            row.label.frame = NSRect(x: 0, y: y, width: bounds.width, height: 16)
            y += 16 + 4
            let h = row.block.height(forWidth: bounds.width)
            row.block.frame = NSRect(x: 0, y: y, width: bounds.width, height: h)
            y += h + 12
        }
    }
}

/// The `pre`: selectable text that wraps anywhere and scrolls past 192 pt.
private final class CommandBlock: DSView {
    private let scroll = NSScrollView()
    private let text = NSTextView()
    private let font = DSFont.mono(12)

    init(_ command: String) {
        super.init(frame: .zero)
        text.string = command
        text.font = font
        text.textColor = Themed.color(\.foreground)
        text.drawsBackground = false
        text.isEditable = false
        text.isSelectable = true
        text.textContainerInset = NSSize(width: 12, height: 8)
        text.textContainer?.lineFragmentPadding = 0
        text.textContainer?.widthTracksTextView = true
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        scroll.documentView = text
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        addSubview(scroll)
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        let inner = max(1, width - 24 - 2)
        let bounds = (text.string as NSString).boundingRect(with: NSSize(width: inner, height: .greatestFiniteMagnitude),
                                                            options: [.usesLineFragmentOrigin], attributes: [.font: font])
        return min(192, ceil(bounds.height) + 16 + 2)
    }

    override func layout() {
        super.layout()
        scroll.frame = bounds.insetBy(dx: 1, dy: 1)
        text.frame.size.width = scroll.contentSize.width
        text.sizeToFit()
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = DesignGeometry.radius(6, in: self)
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        resolving {
            Themed.color(\.muted, 0.4).setFill()
            path.fill()
            Themed.color(\.border).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }
}
