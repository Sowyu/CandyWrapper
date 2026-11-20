import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// The right panel's surface for a side chat tab. The app puts the open side chat's pane in it while the
/// tab shows and takes it out when the tab hides, so a hidden side chat holds nothing.
public final class SideChatHostView: DSView {
    public private(set) var pane: SideChatPaneView?

    public func show(_ pane: SideChatPaneView?) {
        guard pane !== self.pane else { return }
        self.pane?.removeFromSuperview()
        self.pane = pane
        if let pane { addSubview(pane); pane.frame = bounds }
    }

    public override func layout() {
        super.layout()
        pane?.frame = bounds
    }
}

/// A side chat tab (SideChatPane.tsx:131-193): a 36pt header with the title, Bring back, Delete and Close
/// (`h-9 border-b pr-1 pl-3 gap-1`) over the side chat's own chat, or "This side chat was deleted.".
public final class SideChatPaneView: DSView {
    public static let headerHeight: CGFloat = 36

    public struct State: Equatable {
        /// The side chat's shell title; nil before its shell arrives.
        public var title: String?
        /// `bringBackBlockedReason` (:61-68), nil when Bring back works.
        public var bringBackBlockedReason: String?
        public var bringingBack = false
        public var canDelete = true
        public var deleting = false
        /// The shell is gone and the snapshot is loaded (:174-176).
        public var deleted = false
        public init(title: String? = nil, bringBackBlockedReason: String? = nil, bringingBack: Bool = false,
                    canDelete: Bool = true, deleting: Bool = false, deleted: Bool = false) {
            self.title = title; self.bringBackBlockedReason = bringBackBlockedReason; self.bringingBack = bringingBack
            self.canDelete = canDelete; self.deleting = deleting; self.deleted = deleted
        }
    }

    public let threadId: ThreadId
    public var onBringBack: (() -> Void)?
    public var onDelete: (() -> Void)?
    public var onClose: (() -> Void)?

    let titleLabel = LabelView("Side chat", font: DSFont.ui(12, weight: .medium))
    let bringBack = ButtonView("Bring back", variant: .ghost, size: .xs)
    let delete = ButtonView(nil, icon: .trash2, variant: .ghost, size: .iconXs)
    let close = ButtonView(nil, icon: .x, variant: .ghost, size: .iconXs)
    private let deletedLabel = LabelView("This side chat was deleted.", font: DSFont.ui(12))
    private let border = CALayer()
    /// The side chat's own chat, an embedded thread panel the app builds.
    public var content: NSView? {
        didSet {
            guard content !== oldValue else { return }
            oldValue?.removeFromSuperview()
            if let content { addSubview(content, positioned: .below, relativeTo: nil) }
            needsLayout = true
        }
    }
    public private(set) var state = State()

    public init(threadId: ThreadId) {
        self.threadId = threadId
        super.init(frame: .zero)
        titleLabel.lineHeight = 16
        deletedLabel.lineHeight = 16
        deletedLabel.color = Themed.color(\.mutedForeground)
        deletedLabel.isHidden = true
        bringBack.action = { [weak self] in
            guard let self, self.state.bringBackBlockedReason == nil, !self.state.bringingBack else { return }
            self.onBringBack?()
        }
        delete.action = { [weak self] in self?.onDelete?() }
        close.action = { [weak self] in self?.onClose?() }
        delete.setAccessibilityLabel("Delete side chat")
        close.setAccessibilityLabel("Close side chat")
        border.actions = ["frame": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(border)
        [titleLabel, bringBack, delete, close, deletedLabel].forEach(addSubview)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Side chat")
        apply(state)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    public func apply(_ state: State) {
        self.state = state
        titleLabel.text = state.title ?? "Side chat"
        // `aria-disabled`: still hoverable with its tooltip, at 64% (button.tsx:9).
        let blocked = state.bringBackBlockedReason != nil || state.bringingBack
        bringBack.alphaValue = blocked ? 0.64 : 1
        bringBack.toolTip = state.bringBackBlockedReason ?? "Adds this side chat to the main thread's next message."
        delete.isEnabled = state.canDelete && !state.deleting && !state.deleted
        deletedLabel.isHidden = !state.deleted
        content?.isHidden = state.deleted
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        let h = Self.headerHeight
        // `pr-1`, `gap-1`, buttons centered in the 35pt above the border.
        var x = bounds.width - 4 - 24
        close.frame = NSRect(x: x, y: (h - 1 - 24) / 2, width: 24, height: 24)
        x -= 4 + 24
        delete.frame = NSRect(x: x, y: (h - 1 - 24) / 2, width: 24, height: 24)
        let bw = bringBack.intrinsicContentSize.width
        x -= 4 + bw
        bringBack.frame = NSRect(x: x, y: (h - 1 - 24) / 2, width: bw, height: 24)
        titleLabel.frame = NSRect(x: 12, y: (h - 1 - 16) / 2, width: max(0, x - 4 - 12), height: 16)
        border.frame = CGRect(x: 0, y: h - 1, width: bounds.width, height: 1)
        deletedLabel.frame = NSRect(x: 12, y: h + 12, width: max(0, bounds.width - 24), height: 16)
        content?.frame = NSRect(x: 0, y: h, width: bounds.width, height: max(0, bounds.height - h))
    }

    public override func updateLayer() {
        border.backgroundColor = Themed.color(\.border).cgColor(in: self)
    }
}

/// A side chat tab's glyph (`SideChatTabIcon`, RightPanelTabs.tsx:738-760): the message-square icon with a static
/// 6pt dot at its top right, muted while it runs and `bg-info` while it waits on the user.
final class SideChatTabIcon: DSView {
    let state: SideChats.TabState?
    private let icon = IconView(name: .messagesSquare, size: 12, strokeColor: Themed.color(\.foreground))
    private let dot = CALayer()

    init(state: SideChats.TabState?) {
        self.state = state
        super.init(frame: NSRect(x: 0, y: 0, width: 12, height: 12))
        addSubview(icon)
        icon.frame = bounds
        dot.isHidden = state == nil
        dot.cornerRadius = 3
        dot.actions = ["frame": NSNull(), "bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull()]
        // `absolute -top-0.5 -right-0.5 size-1.5`.
        dot.frame = CGRect(x: 12 + 2 - 6, y: -2, width: 6, height: 6)
        layer?.addSublayer(dot)
        layer?.masksToBounds = false
        if let state { setAccessibilityLabel(state.rawValue) }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        dot.backgroundColor = Themed.color(state == .running ? \.mutedForeground : \.info).cgColor(in: self)
    }
}
