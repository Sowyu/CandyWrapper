import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// What the sidebar asks the app to do. Server commands live in the app; the sidebar only calls these.
@MainActor
public struct SidebarActions {
    public var openThread: (ThreadId) -> Void = { _ in }
    public var settle: (ThreadId) -> Void = { _ in }
    public var unsettle: (ThreadId) -> Void = { _ in }
    public var snooze: (ThreadId, NSView) -> Void = { _, _ in }
    public var unsnooze: (ThreadId) -> Void = { _ in }
    public var unpin: (ThreadId) -> Void = { _ in }
    public var toggleSidebar: () -> Void = {}
    public var search: (String) -> Void = { _ in }
    public var filterProjects: (NSView) -> Void = { _ in }
    public var addProject: () -> Void = {}
    public var newThread: () -> Void = {}
    public var openSettings: () -> Void = {}
    public var openPullRequests: () -> Void = {}
    public var openUsage: () -> Void = {}
    public init() {}
}

/// The thread sidebar's content (`ThreadSidebar`, Sidebar.tsx:4960-5581): the titlebar row with the brand,
/// the fixed search header, the virtualized thread list and the utility footer. It goes inside
/// `SidebarContainerView.content`.
public final class SidebarContentView: DSView {
    public let list = SidebarListView()
    public let scrollArea: ScrollAreaView
    public let trigger = SidebarTriggerView()
    let backdrop = StageBackdropView()
    let brand = SidebarBrandView()
    let search = SidebarSearchFieldView()
    let filterButton = SidebarContentView.headerButton(.folder, "Filter threads by project")
    let addProjectButton = SidebarContentView.headerButton(.folderPlus, "Add project")
    let newThreadButton = SidebarContentView.headerButton(.squarePen, "New thread")
    let settingsButton = SidebarContentView.footerButton(.settings, "Settings")
    let pullRequestsButton = SidebarContentView.footerButton(.gitPullRequestArrow, "Pull Requests")
    let usageButton = SidebarContentView.footerButton(.chartNoAxesColumn, "Usage")

    public var actions = SidebarActions() { didSet { wireActions() } }
    public private(set) var snapshot: ShellSnapshot?
    public var state = SidebarListState() { didSet { if state != oldValue { rebuild(animated: true) } } }
    /// Traffic lights: the brand and toggle sit after `--workspace-controls-left` (90px) on windowed macOS.
    public var windowedMac = true { didSet { needsLayout = true } }
    public var stage: SidebarStage = .nightly { didSet { applyStage() } }
    public var showsPullRequests = true { didSet { needsLayout = true } }
    /// The clock, injectable for tests and previews.
    public var now: () -> Date = Date.init

    private var labelTimer: Timer?
    private var occlusionObserver: NSObjectProtocol?

    public override init(frame frameRect: NSRect) {
        scrollArea = ScrollAreaView(documentView: list, scrollFade: true)
        super.init(frame: frameRect)
        scrollArea.fadeSize = 12
        scrollArea.hideScrollbars = true
        addSubview(backdrop)
        addSubview(scrollArea)
        addSubview(brand)
        addSubview(trigger)
        for v in [search, filterButton, addProjectButton, newThreadButton, settingsButton, pullRequestsButton, usageButton] as [NSView] {
            addSubview(v)
        }
        list.onVisibleRowsChange = { [weak self] in self?.scheduleLabelTimer() }
        list.onToggleShelf = { [weak self] shelf in
            guard let self else { return }
            switch shelf {
            case .settled: self.state.settledExpanded.toggle(); self.state.settledVisibleCount = SidebarListBuilder.settledInitialCount
            case .snoozed: self.state.snoozedExpanded.toggle()
            }
        }
        list.onShowMore = { [weak self] in self?.state.settledVisibleCount += SidebarListBuilder.settledPageCount }
        setAccessibilityRole(.group)
        setAccessibilityLabel("Threads")
        applyStage()
        wireActions()
    }

    static func headerButton(_ icon: IconName, _ label: String) -> SidebarMenuButtonView {
        let b = SidebarMenuButtonView("", icon: icon, size: .icon)
        b.setAccessibilityLabel(label)
        b.toolTip = label
        return b
    }

    static func footerButton(_ icon: IconName, _ label: String) -> SidebarMenuButtonView { headerButton(icon, label) }

    private func applyStage() {
        backdrop.isHidden = stage != .nightly
        brand.onBackdrop = stage == .nightly
        trigger.mediaTint = stage == .nightly ? StageBackdropView.ink() : nil
    }

    private func wireActions() {
        list.onOpen = { [weak self] id in
            guard let self else { return }
            self.state.activeThreadId = id
            self.actions.openThread(id)
        }
        let a = actions
        list.rowActions = SidebarRowActions(settle: a.settle, unsettle: a.unsettle, snooze: a.snooze, unsnooze: a.unsnooze, unpin: a.unpin)
        trigger.action = { [weak self] in self?.actions.toggleSidebar() }
        search.onChange = { [weak self] in self?.actions.search($0) }
        filterButton.action = { [weak self] in guard let self else { return }; self.actions.filterProjects(self.filterButton) }
        addProjectButton.action = { [weak self] in self?.actions.addProject() }
        newThreadButton.action = { [weak self] in self?.actions.newThread() }
        settingsButton.action = { [weak self] in self?.actions.openSettings() }
        pullRequestsButton.action = { [weak self] in self?.actions.openPullRequests() }
        usageButton.action = { [weak self] in self?.actions.openUsage() }
    }

    // MARK: Data

    /// Shows a snapshot. Unchanged rows keep their views; only rows whose derived model differs reconfigure.
    public func setSnapshot(_ snapshot: ShellSnapshot?, animated: Bool = true) {
        self.snapshot = snapshot
        rebuild(animated: animated)
    }

    /// Applies one coalesced store update. An empty change set does nothing.
    public func apply(_ update: ShellUpdate) {
        guard !update.changes.isEmpty || snapshot == nil else { return }
        setSnapshot(update.snapshot)
    }

    /// Drains the store, for the app to call from the store's `onChange` hop to the main actor.
    public func pull(from store: ShellStore) async {
        if let update = await store.takeUpdate() { apply(update) }
    }

    private var nowMs: Int64 { TimestampFormat.nowMs(now()) }

    private func rebuild(animated: Bool) {
        let ms = nowMs
        list.nowMs = ms
        list.setItems(SidebarListBuilder.items(snapshot: snapshot, state: state, nowMs: ms), animated: animated)
        scheduleLabelTimer()
    }

    // MARK: Label refresh

    /// One timer, aimed at the next moment a visible label changes, with 10% tolerance. None while the
    /// window is hidden or occluded, or when no visible label can change.
    func scheduleLabelTimer() {
        labelTimer?.invalidate()
        labelTimer = nil
        guard let window, window.occlusionState.contains(.visible) || window.isVisible && window.occlusionState.isEmpty else { return }
        let ms = nowMs
        guard let next = SidebarListBuilder.nextLabelChange(list.visibleRowModels, nowMs: ms) else { return }
        let interval = max(0.05, Double(next - ms) / 1000)
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.labelTimerFired() }
        }
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        labelTimer = timer
    }

    /// Exposed so tests can see whether a timer is pending and when.
    public var pendingLabelRefresh: Date? { labelTimer?.fireDate }

    private func labelTimerFired() {
        labelTimer = nil
        rebuild(animated: true)
        list.tickWorkingRows()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        guard let window else { labelTimer?.invalidate(); labelTimer = nil; return }
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Labels may be stale after a hidden stretch: rebuild once, then aim the timer again.
                if self.window?.occlusionState.contains(.visible) == true { self.rebuild(animated: false) } else {
                    self.labelTimer?.invalidate(); self.labelTimer = nil
                }
            }
        }
        scheduleLabelTimer()
    }

    // MARK: Layout

    public override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        // Titlebar row, 52px. The art bleeds 80px under the search row.
        backdrop.frame = NSRect(x: 0, y: 0, width: w, height: 80)
        let controlsLeft = SidebarMetrics.controlsLeft(windowedMac: windowedMac)
        trigger.frame = NSRect(x: controlsLeft + 1, y: (52 - 28) / 2, width: 28, height: 28)
        let bs = brand.intrinsicContentSize
        brand.frame = NSRect(x: SidebarMetrics.titlebarContentLeft(windowedMac: windowedMac), y: 12, width: min(bs.width, max(0, w - 12 - 130)), height: 28)
        // Fixed header group, `p-2`: search, then the 28px icon buttons.
        let rowY: CGFloat = 52 + 8
        var right = w - 8
        for b in [newThreadButton, addProjectButton, filterButton] {
            b.frame = NSRect(x: right - 28, y: rowY + 2, width: 28, height: 28)
            right -= 28
        }
        search.frame = NSRect(x: 8, y: rowY, width: max(0, right - 4 - 8), height: 32)
        // Footer: `px-2 py-1`, 32px icon buttons 4px apart.
        let footerTop = h - 40
        var fx: CGFloat = 8
        for b in [settingsButton, pullRequestsButton, usageButton] {
            b.isHidden = b === pullRequestsButton && !showsPullRequests
            if b.isHidden { continue }
            b.frame = NSRect(x: fx, y: footerTop + 4, width: 32, height: 32)
            fx += 36
        }
        scrollArea.frame = NSRect(x: 0, y: 100, width: w, height: max(0, footerTop - 100))
        list.frame.size.width = w
        list.needsLayout = true
    }
}
