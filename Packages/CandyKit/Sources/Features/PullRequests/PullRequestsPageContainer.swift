import AppKit
import DesignSystem
import T3Store

/// The Pull Requests route's main area (_chat.pull-requests.tsx:2195-2320): the list column, and
/// beside it the page's own right panel whose tabs are the pull requests opened from the list. The
/// panel is session state (`PULL_REQUESTS_PANEL_REF`, not persisted), half the window wide by default.
public final class PullRequestsPageContainer: DSView {
    public let page = PullRequestsPageView()
    public let toasts = ToastViewport()
    let rightPanel = RightPanelView()
    public var detail: PullRequestDetailView { rightPanel.pullRequest }
    public var lazyDetail: LazyView<PullRequestDetailView> { rightPanel.lazyPullRequest }
    public private(set) var panelState = RightPanelState()
    /// The panel changed: activate, close, close others.
    public var onPanelChange: ((RightPanelState) -> Void)?
    public var pullRequestStatus: [String: PullRequestStateTone] {
        get { rightPanel.pullRequestStatus }
        set { rightPanel.pullRequestStatus = newValue }
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(page)
        addSubview(rightPanel)
        addSubview(toasts)
        toasts.layer?.zPosition = 3
        rightPanel.isHidden = true
        rightPanel.filesAvailable = false
        rightPanel.diffAvailable = false
        lazyDetail.set(\.context, .page)
        rightPanel.onActivate = { [weak self] id in self?.mutate { $0.activate(id) } }
        rightPanel.onClose = { [weak self] id in self?.mutate { _ = $0.close(id) } }
        rightPanel.onCloseOthers = { [weak self] id in self?.mutate { _ = $0.closeOthers(id) } }
        rightPanel.onCloseToRight = { [weak self] id in self?.mutate { _ = $0.closeToRight(id) } }
        rightPanel.onCloseAll = { [weak self] in self?.mutate { _ = $0.closeAll() } }
        rightPanel.onMove = { [weak self] id, index in self?.mutate { $0.move(id, to: index) } } // _chat.pull-requests.tsx:2282-2285 in 2994
    }

    public func mutate(_ change: (inout RightPanelState) -> Void) {
        var next = panelState
        change(&next)
        setPanelState(next)
        onPanelChange?(next)
    }

    public func setPanelState(_ state: RightPanelState) {
        panelState = state
        rightPanel.isHidden = !state.isOpen
        rightPanel.apply(state)
        needsLayout = true
    }

    /// `defaultWidth` half the window, clamped like `getPreviewPanelMaxWidth`.
    static func panelWidth(window: CGFloat, container: CGFloat) -> CGFloat {
        let maxWidth = max(RightPanelView.minWidth, min((window * 0.7).rounded(.down), container.rounded(.down) - 360))
        return min(max((window / 2).rounded(.down), RightPanelView.minWidth), maxWidth)
    }

    public override func layout() {
        super.layout()
        let open = panelState.isOpen
        let pw = open ? Self.panelWidth(window: window?.frame.width ?? bounds.width, container: bounds.width) : 0
        page.frame = NSRect(x: 0, y: 0, width: bounds.width - pw, height: bounds.height)
        rightPanel.frame = NSRect(x: bounds.width - pw, y: 0, width: pw, height: bounds.height)
        toasts.frame = ToastViewport.frame(in: bounds)
    }

    public override var acceptsFirstResponder: Bool { true }

    /// Escape goes back (`useEscapeToGoBack`, _chat.pull-requests.tsx:349) once nothing inside took it.
    public var onEscape: (() -> Void)?
    public override func cancelOperation(_ sender: Any?) { onEscape?() }
}
