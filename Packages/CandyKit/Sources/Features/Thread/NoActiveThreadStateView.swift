import AppKit
import DesignSystem

/// `NoActiveThreadState` (apps/web/src/components/NoActiveThreadState.tsx:6-33): the chat surface with no
/// thread. The 52px `WorkspacePageHeader` with `border-b` holds "No active thread" (`text-xs
/// text-muted-foreground/50`, the desktop branch), then a centered `Empty` with "Pick a thread to continue".
public final class NoActiveThreadStateView: DSView {
    static let headerHeight: CGFloat = 52
    private let header = NoActiveThreadHeaderView()
    private let empty = EmptyView(title: "Pick a thread to continue",
                                  message: "Select an existing thread or create a new one to get started.")

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // `EmptyHeader className="max-w-none"` inside `max-w-lg px-8`: the text runs to 448.
        empty.headerMaxWidth = .greatestFiniteMagnitude
        addSubview(empty)
        addSubview(header)
        setAccessibilityLabel("No active thread")
    }

    public override func layout() {
        super.layout()
        let h = Self.headerHeight
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: h)
        // `Empty` (p-12) around `w-full max-w-lg px-8 py-12`.
        let w = min(512 - 64 + 96, bounds.width)
        let eh = empty.height(forWidth: w) + 96
        let y = h + max(0, (bounds.height - h - eh) / 2) + 48
        empty.frame = NSRect(x: ((bounds.width - w) / 2).rounded(), y: y.rounded(), width: w, height: eh - 96)
    }

    public override func updateLayer() { layer?.backgroundColor = Themed.color(\.background).cgColor(in: self) }
}

/// The header bar: label at the 20px gutter, centered on 52, a 1px `border-border` underline.
final class NoActiveThreadHeaderView: TopbarDragView {
    let label = LabelView("No active thread", font: DSFont.ui(12), color: Themed.color(\.mutedForeground, 0.5))
    private let line = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.lineHeight = 16
        addSubview(label)
        layer?.addSublayer(line)
    }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: contentStart, y: ((bounds.height - 16) / 2).rounded(), width: ceil(label.textWidth) + 1, height: 16)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        line.frame = NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
        CATransaction.commit()
    }

    override func updateLayer() { line.backgroundColor = Themed.color(\.border).cgColor(in: self) }
}

/// What the chat surface does when its thread may have gone (ThreadRouteView.tsx:144-158 with
/// `resolveThreadRouteRenderState`, threadRoutes.ts:23-39). A thread counts as gone only after a shell
/// listed it: a just-launched thread is not in the shell yet.
public enum MissingThreadRoute: Equatable, Sendable {
    case keep, landOnIndex, noActiveThread

    public static func resolve(shellLoaded: Bool, listed: Bool, seenBefore: Bool, environmentHasThreads: Bool) -> Self {
        guard shellLoaded, !listed, seenBefore else { return .keep }
        return environmentHasThreads ? .landOnIndex : .noActiveThread
    }
}
