import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// The chat header (ChatView.tsx:11285-11293, ChatHeader.tsx, WorkspaceBreadcrumb.tsx): 52px,
/// 20px gutters, "favicon project / title", and the three panel toggles fixed at the right.
public final class ThreadHeaderView: DSView {
    static let height: CGFloat = 52

    private let favicon = ProjectMonogramView()
    private let project = LabelView("", font: TL.font(14, .medium), color: TL.c(\.mutedForeground))
    private let slash = LabelView("/", font: TL.font(14, .medium), color: TL.c(\.iconMuted))
    private let title = LabelView("", font: TL.font(14, .medium), color: TL.c(\.foreground))
    /// Thread panel, terminal, right panel (PanelLayoutControls.tsx:76).
    public let toggles: [ToggleView] = [IconName.squareMenu, .panelBottom, .panelRight].map {
        ToggleView(nil, icon: $0, variant: .ghost, size: .sm)
    }

    public var projectTitle: String {
        get { project.text }
        set { project.text = newValue; favicon.projectTitle = newValue; needsLayout = true }
    }

    public var threadTitle: String {
        get { title.text }
        set { title.text = newValue; needsLayout = true }
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for label in [project, slash, title] { label.lineHeight = 20; addSubview(label) }
        addSubview(favicon)
        // ponytail: the toggles only reserve their place and look; the panels they open come with M5 and M7
        toggles[0].setAccessibilityLabel("Thread panel")
        toggles[1].setAccessibilityLabel("Toggle terminal")
        toggles[2].setAccessibilityLabel("Toggle right panel")
        toggles.forEach(addSubview)
    }

    public override func layout() {
        super.layout()
        let midY = Self.height / 2
        // `size-3.5` favicon: the 16px monogram drawn at 14px.
        favicon.frame = NSRect(x: 20, y: midY - 7, width: 14, height: 14)
        favicon.bounds = NSRect(x: 0, y: 0, width: 16, height: 16)
        let projectWidth = min(160, project.textWidth)
        project.frame = NSRect(x: 40, y: midY - 10, width: ceil(projectWidth), height: 20)
        let slashX = 40 + projectWidth + 12
        slash.frame = NSRect(x: slashX, y: midY - 10, width: ceil(slash.textWidth), height: 20)
        let titleX = slashX + slash.textWidth + 12
        // `pr-24` keeps the title clear of the toggles.
        title.frame = NSRect(x: titleX, y: midY - 10, width: max(0, min(ceil(title.textWidth) + 1, bounds.width - 20 - 96 - titleX)), height: 20)
        var x = bounds.width - 12 - 1
        for toggle in toggles.reversed() {
            let size = toggle.intrinsicContentSize
            x -= size.width
            toggle.frame = NSRect(x: x, y: midY - size.height / 2, width: size.width, height: size.height)
            x -= 4
        }
    }
}

/// The read-only thread: header over the timeline, on the panel background. Feed it a projection
/// with `setProjection(_:)`; the expand and collapse state lives in `model`.
///
/// The app uses:
/// - `setProjection(_:projectTitle:workspaceRoot:)` on every `ThreadStore` update,
/// - `onLoadEarlier` to page in older history (call `ThreadStore.beginLoadEarlier`),
/// - `bottomInset` once a composer floats over the timeline.
public final class ThreadPanelView: DSView {
    public let header = ThreadHeaderView()
    public let timeline = TimelineView()
    public let model = ThreadViewModel()
    private let fade = CAGradientLayer()

    /// The user scrolled near the first loaded row.
    public var onLoadEarlier: (@MainActor () -> Void)? {
        get { timeline.onNearTop }
        set { timeline.onNearTop = newValue }
    }

    /// Height of whatever floats over the bottom of the timeline (the composer).
    public var bottomInset: CGFloat {
        get { timeline.bottomInset }
        set { timeline.bottomInset = newValue }
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(timeline)
        addSubview(header)
        // `topbar-scroll-fade` (index.css:439-475): the first 25px of the scroller fade out; drawn as
        // a background-colored overlay instead of a mask, so scrolling doesn't render offscreen.
        fade.locations = [0, 0.1, 0.24, 0.42, 0.62, 0.82, 1]
        layer?.addSublayer(fade)
        timeline.context.model = model
        model.onChange = { [weak self] in
            guard let self else { return }
            self.timeline.setItems(self.model.items)
        }
    }

    /// Shows a thread. Pass nil to clear.
    public func setProjection(_ projection: ThreadProjection?, projectTitle: String, workspaceRoot: String?) {
        model.projectTitle = projectTitle
        model.workspaceRoot = workspaceRoot
        header.projectTitle = projectTitle
        header.threadTitle = projection?.thread.title ?? ""
        if projection?.thread.id != model.projection?.thread.id { timeline.context.forgetDocuments() }
        model.setProjection(projection)
    }

    public override func updateLayer() {
        layer?.backgroundColor = TL.c(\.background).cgColor(in: self)
        let bg = TL.c(\.background).cgColor(in: self)
        fade.colors = [1, 0.9, 0.7, 0.42, 0.18, 0.04, 0].map { bg.copy(alpha: $0)! }
    }

    public override func layout() {
        super.layout()
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: ThreadHeaderView.height)
        timeline.frame = NSRect(x: 0, y: ThreadHeaderView.height, width: bounds.width, height: max(0, bounds.height - ThreadHeaderView.height))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // The last 6px column (the scrollbar) stays unmasked.
        fade.frame = CGRect(x: 0, y: ThreadHeaderView.height, width: max(0, bounds.width - 6), height: 25)
        fade.zPosition = 1
        CATransaction.commit()
    }
}
