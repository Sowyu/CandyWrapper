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

/// The header: label at the 20px gutter, centered on 52. T3 underlines it with `border-border`; the user removed header
/// bars on 2026-10-21.
final class NoActiveThreadHeaderView: TopbarDragView {
    let label = LabelView("No active thread", font: DSFont.ui(12), color: Themed.color(\.mutedForeground, 0.5))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.lineHeight = 16
        addSubview(label)
    }

    override func layout() {
        super.layout()
        let line = label.lineHeight ?? 16
        label.frame = NSRect(x: contentStart, y: ((bounds.height - line) / 2).rounded(),
                             width: min(ceil(label.textWidth) + 1, max(0, bounds.width - contentStart - 20)), height: line)
    }
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

/// `UnreachableEnvironmentState` (5258 ThreadRouteView.tsx:250-268): the route's thread is on an environment the app
/// has no enabled entry for. T3 draws it in place of `ChatView`, so there is no header label; the bar stays as a drag
/// strip. Redesign draws the same copy as its state view with the action under it.
public final class ThreadUnavailableStateView: DSView {
    private let header = NoActiveThreadHeaderView()
    let empty = EmptyView(title: "Thread unavailable", message: "This thread is on an environment this app is not connected to.")
    /// Open Environments, to Settings > Connections.
    public var onOpenEnvironments: (() -> Void)?
    /// T3's button, in the default themes only: Redesign shows `empty.action` in its place.
    private var buttonRow: ButtonRow!

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        header.label.isHidden = true
        // `<Button size="sm">`, the default variant.
        let button = ButtonView("Open Environments", variant: .default, size: .sm)
        button.action = { [weak self] in self?.onOpenEnvironments?() }
        buttonRow = ButtonRow([button])
        empty.redesign = StateCopy(title: "Thread unavailable", detail: "This thread is on an environment this app is not connected to.",
                                   icon: .unplug)
        empty.action = StateAction("Open Environments", icon: .settings) { [weak self] in self?.onOpenEnvironments?() }
        addSubview(empty)
        addSubview(header)
        setAccessibilityLabel("Thread unavailable")
    }

    public override func layout() {
        super.layout()
        let h = NoActiveThreadStateView.headerHeight
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: h)
        let redesign = ThemeRuntime.isDither(dark: effectiveAppearance.isDark)
        if (empty.content == nil) != redesign { empty.content = redesign ? nil : buttonRow }
        // `Empty className="flex-1"` (p-12, text in `max-w-sm`), centered in the whole inset.
        let w = min(max(0, bounds.width), 384 + 96)
        let eh = empty.height(forWidth: w)
        empty.frame = NSRect(x: ((bounds.width - w) / 2).rounded(), y: max(h, ((bounds.height - eh) / 2).rounded()), width: w, height: eh)
    }

    public override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsLayout = true }

    public override func updateLayer() { layer?.backgroundColor = Themed.color(\.background).cgColor(in: self) }
}

/// `environmentUnreachableAtom` (5258 state/presentation.ts:30-47): once the catalog has loaded and the primary is
/// known, a thread's environment is unreachable when no enabled entry has its id.
public enum ThreadEnvironmentReach {
    public static func unreachable(environmentId: String?, catalogReady: Bool, primaryId: String?, enabledIds: Set<String>) -> Bool {
        guard let environmentId, catalogReady, let primaryId else { return false }
        return environmentId != primaryId && !enabledIds.contains(environmentId)
    }
}
