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

    /// Glass Native's empty detail (T3 Mobile WorkspaceEmptyDetail.tsx:39-62): a 34 pt `sidebar.left`, "Select a
    /// thread", the hint and a prominent New Task button, centered. Built the first time it shows.
    public var native = false {
        didSet {
            guard native != oldValue else { return }
            header.isHidden = native
            empty.isHidden = native
            if native, nativeContent == nil { nativeContent = makeNative() }
            nativeContent?.forEach { $0.isHidden = !native }
            needsLayout = true
            needsDisplay = true
        }
    }
    /// New Task in the native empty detail.
    public var onNewTask: (() -> Void)?
    private var nativeContent: [NSView]?

    private func makeNative() -> [NSView] {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 34, weight: .regular).applying(.init(hierarchicalColor: .secondaryLabelColor)))
        let title = NSTextField(labelWithString: "Select a thread")
        title.font = .systemFont(ofSize: 18 * FontRuntime.interfaceScale, weight: .bold)
        title.alignment = .center
        let hint = NSTextField(wrappingLabelWithString: "Choose a thread from the sidebar or start a new task.")
        hint.font = .systemFont(ofSize: 14 * FontRuntime.interfaceScale)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .center
        let button = NSButton(title: "New Task", target: self, action: #selector(newTask))
        button.bezelStyle = .push
        button.controlSize = .large
        if #available(macOS 26, *) { button.tintProminence = .primary }
        let views: [NSView] = [icon, title, hint, button]
        views.forEach(addSubview)
        return views
    }

    @objc private func newTask() { onNewTask?() }

    private func layoutNative(_ views: [NSView]) {
        let w = min(360, bounds.width - 40)
        let sizes = views.map { view -> NSSize in
            if let hint = view as? NSTextField, hint.cell?.wraps == true { return NSSize(width: w, height: ceil(hint.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: w, height: 1000)).height)) }
            return view.intrinsicContentSize
        }
        let gaps: [CGFloat] = [12, 6, 16]
        let total = sizes.reduce(0) { $0 + $1.height } + gaps.reduce(0, +)
        var y = ((bounds.height - total) / 2).rounded()
        for (i, view) in views.enumerated() {
            let size = sizes[i]
            view.frame = NSRect(x: ((bounds.width - size.width) / 2).rounded(), y: y, width: size.width, height: size.height)
            y += size.height + (i < gaps.count ? gaps[i] : 0)
        }
    }

    public override func layout() {
        super.layout()
        if native, let nativeContent { return layoutNative(nativeContent) }
        let h = Self.headerHeight
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: h)
        // `Empty` (p-12) around `w-full max-w-lg px-8 py-12`.
        let w = min(512 - 64 + 96, bounds.width)
        let eh = empty.height(forWidth: w) + 96
        let y = h + max(0, (bounds.height - h - eh) / 2) + 48
        empty.frame = NSRect(x: ((bounds.width - w) / 2).rounded(), y: y.rounded(), width: w, height: eh - 96)
    }

    public override func updateLayer() { layer?.backgroundColor = WindowGlass.inset.cgColor(in: self) }
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
