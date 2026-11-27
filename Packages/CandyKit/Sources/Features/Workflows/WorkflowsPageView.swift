import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// The Workflows page (5258 components/workflows/WorkflowsPage.tsx, WorkflowRunsView.tsx, WorkflowRunFeed.tsx;
/// T3 commits 69c1d53826 #38884, 5ac27b4007 #42008, 7be3a767cc #42515, 3b5033a28c #42506, 462596a0f7 #42518).
/// The 52pt header, then one environment's runs: a `w-72` list beside the picked run told as a feed. The app's
/// controller owns the subscription and feeds `content`; the page holds only its picks.
public final class WorkflowsPageView: DSView, DitherBandPage {
    /// Redesign: the title and Definitions sit in the tab band as pills, as on Pull requests and Issues.
    public var bandLeading: DitherStripLeading? { bandTitle }
    public var bandTrailing: NSView? { bandControls }
    private let bandTitle = DitherThreadTitleView()
    private let bandControls = DitherBandControls(button: ButtonView("Definitions", icon: .fileCode2, variant: .ghost, size: .xs))
    public enum Content: Equatable {
        case loading
        case failed(String)
        /// `turnedOff` (WorkflowsPage.tsx:68-71): connected servers have workflows off in Labs.
        case off
        case noEnvironment
        case runs(WorkflowRunsSnapshot)
    }

    /// The run picked by its address (`search.run`), or nil for the page's own choice.
    public var selectedRunId: String? { didSet { if selectedRunId != oldValue { rebuild() } } }
    public var content: Content = .loading { didSet { if content != oldValue { rebuild() } } }
    /// The picked run's steps (`workflows.get`), nil while they load.
    public var detail: WorkflowRunDetail? { didSet { if detail != oldValue { rebuildFeed() } } }
    public var detailError: String? { didSet { if detailError != oldValue { rebuildFeed() } } }
    /// Answer, resume and cancel need `orchestration:operate` (clientRpcPermissions.ts:90-92).
    public var canOperate = true { didSet { if canOperate != oldValue { rebuildFeed() } } }
    /// This client's auth session on the run's server, so its own answers read "You" (`isOwnWorkflowAnswer`).
    public var ownSessionId: String?

    public var onSelect: ((String?) -> Void)?
    public var onOpenSettings: (() -> Void)?
    public var onOpenURL: ((String) -> Void)?
    /// Answers a question; the completion gets an error message on failure.
    public var onAnswer: ((_ runId: String, _ name: String, _ choice: String, _ reason: String?, _ done: @escaping @MainActor (String?) -> Void) -> Void)?
    public var onCancelRun: ((String) -> Void)?
    /// Resumes a paused run (`workflows.resume`); the completion gets an error message on failure.
    public var onResume: ((String, @escaping @MainActor (String?) -> Void) -> Void)?
    /// Opens an agent's or a question's thread.
    public var onOpenThread: ((WorkflowThreadTarget) -> Void)?
    /// Opens the definition files (WorkflowsPage.tsx:243-248); the button shows only while it is set and the page
    /// has an environment.
    public var onOpenDefinitions: (() -> Void)? { didSet { needsLayout = true } }
    /// `<Button size="sm" variant="outline"><FileCode2Icon />Definitions</Button>`.
    private let definitions = ButtonView("Definitions", icon: .fileCode2, variant: .outline, size: .sm)

    public let header = SettingsHeaderView()
    public let toasts = ToastViewport()
    /// Escape (`useEscapeToGoBack`).
    public var onEscape: (() -> Void)?
    /// The run told beside the list changed, so its steps are read (`workflows.get`).
    public var onShownRunChange: ((String?) -> Void)?
    public private(set) var shownRunId: String?
    private let listColumn = DSView()
    private let tabs = ToggleGroupView(variant: .segmented, items: WorkflowListTab.allCases.map { ($0.label, nil) }, selected: 0)
    private let workflowSelect = SelectView(options: [], size: .sm)
    private let kindSelect = SelectView(options: [], size: .sm)
    private let kindsLine = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    private let triggerLine = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    private let listDocument = WorkflowsDocument()
    private let listScroll: ScrollAreaView
    private let nothing = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    private let skippedButton = ButtonView("", variant: .ghost, size: .xs)
    private var rowViews: [WorkflowRunRowView] = []
    private let feedDocument = WorkflowsDocument()
    private let feedScroll: ScrollAreaView
    private let feed = WorkflowRunFeedView()
    private var empty: EmptyView?
    private let loadingLabel = LabelView("Loading workflow runs…", font: DSFont.ui(14), color: Themed.color(\.mutedForeground))

    // The page's picks (WorkflowRunsView.tsx:107-112).
    var pickedTab: WorkflowListTab?
    var workflow = ""
    private var showSkipped = false
    private var listing: WorkflowsListing?
    /// `t3code:workflows:question-kind` (WorkflowRunsView.tsx:47), `*` for all kinds.
    static let kindKey = "t3code:workflows:question-kind"
    private var pickedKind: String {
        get { UserDefaults.standard.string(forKey: Self.kindKey) ?? WorkflowRuns.everyKind }
        set { UserDefaults.standard.set(newValue, forKey: Self.kindKey) }
    }

    public override init(frame frameRect: NSRect) {
        listScroll = ScrollAreaView(documentView: listDocument)
        feedScroll = ScrollAreaView(documentView: feedDocument)
        super.init(frame: frameRect)
        header.plainTitle = "Workflows"
        bandTitle.set(project: "", title: "Workflows")
        bandControls.toggle.action = { [weak self] in self?.onOpenDefinitions?() }
        bandControls.toggle.setAccessibilityLabel("Definitions")
        tabs.setAccessibilityLabel("Which runs")
        // `<ToggleGroup className="w-full *:flex-1">`, segmented by default (ui/toggle-group.tsx:16).
        tabs.fillsWidth = true
        workflowSelect.setAccessibilityLabel("Workflow")
        kindSelect.setAccessibilityLabel("Kind of question")
        nothing.alignment = .center
        for l in [kindsLine, triggerLine, nothing] { l.lineHeight = 16 }
        for v in [tabs, workflowSelect, kindSelect, kindsLine, triggerLine, listScroll] as [NSView] { listColumn.addSubview(v) }
        for v in [nothing, skippedButton] as [NSView] { listDocument.addSubview(v) }
        feedDocument.addSubview(feed)
        loadingLabel.lineHeight = 20
        for v in [listColumn, feedScroll, loadingLabel, header, toasts] as [NSView] { addSubview(v) }
        header.addSubview(definitions)
        definitions.action = { [weak self] in self?.onOpenDefinitions?() }
        toasts.layer?.zPosition = 3
        tabs.onChange = { [weak self] i in
            // Clicking the pressed tab un-presses it; the list keeps its tab, as a Base UI group with one value does.
            guard let self else { return }
            guard let i else { self.rebuild(); return }
            self.pickedTab = WorkflowListTab.allCases[i]
            self.rebuild()
        }
        workflowSelect.onChange = { [weak self] i in
            guard let self else { return }
            self.workflow = i == 0 ? "" : self.listing?.workflows[safe: i - 1]?.name ?? ""
            self.rebuild()
        }
        kindSelect.onChange = { [weak self] i in self?.pickKind(i) }
        skippedButton.action = { [weak self] in self?.showSkipped.toggle(); self?.rebuild() }
        feed.onSelect = { [weak self] in self?.onSelect?($0) }
        feed.onOpenURL = { [weak self] in self?.onOpenURL?($0) }
        feed.onAnswer = { [weak self] a, b, c, d, e in self?.onAnswer?(a, b, c, d, e) }
        feed.onCancelRun = { [weak self] in self?.onCancelRun?($0) }
        feed.onResume = { [weak self] id, done in self?.onResume?(id, done) }
        feed.onOpenThread = { [weak self] in self?.onOpenThread?($0) }
        feed.onRepick = { [weak self] in self?.rebuildFeed() }
        rebuild()
    }

    public override var acceptsFirstResponder: Bool { true }
    public override func cancelOperation(_ sender: Any?) { onEscape?() }

    // MARK: Model

    private var snapshot: WorkflowRunsSnapshot? { if case .runs(let s) = content { return s }; return nil }

    func rebuild() {
        empty?.removeFromSuperview()
        empty = nil
        loadingLabel.isHidden = content != .loading
        var showList = false
        switch content {
        case .loading: break
        case .failed(let message): showEmpty("Could not load workflow runs", message)
        case .off: showEmpty("Workflows are off", "Turn them on for this server in Settings → Labs.", action: true)
        case .noEnvironment: showEmpty("No environment connected", "Connect an environment to see its workflow runs.")
        case .runs(let s):
            if s.runs.isEmpty && s.workflows.isEmpty {
                if selectedRunId != nil { showEmpty("This run is not here", "This environment has no run with that link.") }
                else {
                    showEmpty("No workflow runs yet",
                              "A workflow ties agents, code, schedules and questions to you into one run that survives restarts. Write one under Definitions, or ask an agent to.",
                              guide: true)
                }
            } else { showList = true }
        }
        listColumn.isHidden = !showList
        feedScroll.isHidden = !showList
        guard showList, let s = snapshot else { listing = nil; noteShown(nil); needsLayout = true; return }
        let l = WorkflowsPageLogic.listing(s, selectedRunId: selectedRunId, pickedTab: pickedTab, workflow: workflow,
                                           pickedKind: pickedKind, showSkipped: showSkipped)
        listing = l
        tabs.selectedIndex = WorkflowListTab.allCases.firstIndex(of: l.tab)
        workflowSelect.isHidden = l.workflows.count < 2
        // The trigger reads "All {count} workflows" over an "All workflows" item (WorkflowRunsView.tsx:316-326).
        workflowSelect.options = ["All workflows"] + l.workflows.map(\.name)
        workflowSelect.valueLabels = ["All \(l.workflows.count) workflows"] + l.workflows.map(\.name)
        workflowSelect.selectedIndex = l.section.flatMap { sec in l.workflows.firstIndex { $0.name == sec.name }.map { $0 + 1 } } ?? 0
        kindSelect.isHidden = l.kinds.isEmpty
        // Items name the kind with its count at the end; the trigger reads "{kind} {count}" (:340-370).
        kindSelect.options = ["All kinds"] + l.kinds.map(WorkflowsPageLogic.kindLabel)
        kindSelect.optionTrailingDetails = [nil] + l.kinds.map { "\($0.count)" }
        kindSelect.valueLabels = ["All kinds"] + l.kinds.map { "\(WorkflowsPageLogic.kindLabel($0)) \($0.count)" }
        kindSelect.selectedIndex = l.kind == WorkflowRuns.everyKind ? 0 : l.kinds.firstIndex { $0.kind == l.kind }.map { $0 + 1 } ?? 0
        kindsLine.isHidden = l.kinds.isEmpty || l.kind != WorkflowRuns.everyKind
        kindsLine.text = WorkflowsPageLogic.kindsLine(l.kinds)
        triggerLine.isHidden = l.section == nil
        triggerLine.text = l.section.map(WorkflowRuns.triggerLine) ?? ""
        nothing.isHidden = !l.rows.isEmpty
        nothing.text = l.nothing
        skippedButton.isHidden = !(l.tab == .all && l.skipped > 0 && !l.openedSkipped)
        skippedButton.title = showSkipped ? "Hide skipped" : "Show \(l.skipped) skipped"
        let now = TimestampFormat.nowMs()
        while rowViews.count < l.rows.count {
            let r = WorkflowRunRowView()
            r.onClick = { [weak self, weak r] in
                guard let self, let r, let id = r.runId, let s = self.snapshot, let row = self.listing?.rows.first(where: { $0.run.runId == id }) else { return }
                let kind = self.listing?.kind ?? WorkflowRuns.everyKind
                if kind != WorkflowRuns.everyKind { self.pickedTab = .needsYou }
                self.onSelect?(WorkflowsPageLogic.runToOpen(s, row: row, kind: kind))
            }
            listDocument.addSubview(r)
            rowViews.append(r)
        }
        while rowViews.count > l.rows.count { rowViews.removeLast().removeFromSuperview() }
        for (r, node) in zip(rowViews, l.rows) { r.set(node, current: node.run.runId == l.currentRunId, nowMs: now) }
        noteShown(l.shown?.run.runId)
        rebuildFeed()
        needsLayout = true
    }

    private func noteShown(_ id: String?) {
        guard id != shownRunId else { return }
        shownRunId = id
        onShownRunChange?(id)
    }

    private func pickKind(_ index: Int) {
        guard let l = listing, let s = snapshot else { return }
        let next = index == 0 ? WorkflowRuns.everyKind : l.kinds[safe: index - 1]?.kind ?? WorkflowRuns.everyKind
        pickedKind = next
        pickedTab = .needsYou
        let ofWorkflow = WorkflowsPageLogic.listing(s, selectedRunId: nil, pickedTab: .needsYou, workflow: workflow,
                                                    pickedKind: WorkflowRuns.everyKind, showSkipped: showSkipped).rows
        if case .some(let move) = WorkflowsPageLogic.runAfterPicking(s, kind: next, selected: l.shown, ofWorkflow: ofWorkflow), selectedRunId != nil {
            onSelect?(move)
        }
        rebuild()
    }

    private func rebuildFeed() {
        guard let l = listing else { feed.isHidden = true; return }
        feed.isHidden = l.shown == nil && !l.notHere
        feed.canOperate = canOperate
        feed.ownSessionId = ownSessionId
        let matching = l.shown.flatMap { node in detail?.run.runId == node.run.runId ? detail : nil }
        feed.set(node: l.shown, parent: l.parent, detail: matching, error: detailError, notHere: l.notHere, nowMs: TimestampFormat.nowMs())
        needsLayout = true
        syncTick()
    }

    // MARK: The clock

    /// `useRunNowMs` (WorkflowRunFeed.tsx:122-131): a run under way is told to the second. The timer runs only while
    /// the page is in a window and shows a run that has not ended; the feed then updates its times in place.
    private var tick: Timer?

    private func syncTick() {
        let live = window != nil && !isHiddenOrHasHiddenAncestor && listing?.shown.map { $0.run.endedAt == nil } == true
        if live, tick == nil {
            let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.rebuildFeed() } }
            t.tolerance = 0.1
            RunLoop.main.add(t, forMode: .common)
            tick = t
        } else if !live {
            tick?.invalidate()
            tick = nil
        }
    }

    public override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); syncTick() }
    public override func viewDidHide() { super.viewDidHide(); syncTick() }
    public override func viewDidUnhide() { super.viewDidUnhide(); syncTick() }

    private func showEmpty(_ title: String, _ message: String, action: Bool = false, guide: Bool = false) {
        let e = EmptyView(title: title, message: message, icon: .workflow)
        if action {
            let b = ButtonView("Open Settings → Labs", variant: .outline, size: .sm)
            b.action = { [weak self] in self?.onOpenSettings?() }
            e.content = b
        } else if guide {
            let b = ButtonView("Read the guide", variant: .outline, size: .sm)
            b.action = { [weak self] in self?.onOpenURL?(WorkflowRuns.guideURL) }
            e.content = b
        } else if selectedRunId != nil, title == "This run is not here" {
            let b = ButtonView("Back to the runs", variant: .outline, size: .sm)
            b.action = { [weak self] in self?.onSelect?(nil) }
            e.content = b
        }
        addSubview(e, positioned: .below, relativeTo: header)
        empty = e
    }

    // MARK: Layout

    public override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        // Redesign: the title and Definitions sit in the tab band above the page, so the page starts at its top.
        let band = ThemeRuntime.isDither(dark: effectiveAppearance.isDark)
        header.isHidden = band
        header.frame = NSRect(x: 0, y: 0, width: w, height: 52)
        definitions.isHidden = onOpenDefinitions == nil || content == .noEnvironment || content == .off
        let controlsHidden = !band || definitions.isHidden
        if bandControls.isHidden != controlsHidden { bandControls.isHidden = controlsHidden; bandControls.superview?.needsLayout = true }
        let dw = definitions.fittingSize.width
        definitions.frame = NSRect(x: w - 20 - dw, y: (52 - 28) / 2, width: dw, height: 28)
        toasts.frame = ToastViewport.frame(in: bounds, dither: band)
        // The header's `border-b` is its own last row (WorkspacePageHeader, border-box).
        let top: CGFloat = band ? 0 : 52
        let body = NSRect(x: 0, y: top, width: w, height: max(0, h - top))
        loadingLabel.frame = NSRect(x: 24, y: body.minY + 24, width: max(0, w - 48), height: 20)
        if let empty, band {
            // Redesign's state centers itself in the page. Sized to its fitting width, which has no width to wrap to,
            // it came out a few points wide and drew its button as a 1pt line through the label.
            empty.frame = body
        } else if let empty {
            let size = empty.fittingSize
            empty.frame = NSRect(x: body.midX - min(size.width, w) / 2, y: body.midY - size.height / 2, width: min(size.width, w), height: size.height)
        }
        // `md:w-72 md:border-e` (WorkflowRunsView.tsx:296-302).
        let listW: CGFloat = 287
        listColumn.frame = NSRect(x: 0, y: body.minY, width: listW, height: body.height)
        feedScroll.frame = NSRect(x: listW + 1, y: body.minY, width: max(0, w - listW - 1), height: body.height)
        layoutList()
        layoutFeed()
    }

    public override var wantsUpdateLayer: Bool { false }
    public override func draw(_ dirtyRect: NSRect) {
        // Redesign lies on the art under the pages' scrim, as Pull Requests does, draws no rule under a page's header
        // and parts the columns with its rim.
        let redesign = ThemeRuntime.isDither(dark: effectiveAppearance.isDark)
        if !redesign {
            Themed.color(\.background).setFill()
            bounds.fill()
        }
        (redesign ? RedesignTokens.Card.border : Themed.color(\.border)).setFill()
        if !redesign { NSRect(x: 0, y: 51, width: bounds.width, height: 1).fill() }
        let top: CGFloat = redesign ? 0 : 52
        if !listColumn.isHidden { NSRect(x: 287, y: top, width: 1, height: bounds.height - top).fill() }
    }
    public override var isFlipped: Bool { true }
    public override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true; needsLayout = true }

    private func layoutList() {
        let w = listColumn.bounds.width
        // `space-y-2 p-2 pb-1`.
        var y: CGFloat = 8
        let th = tabs.intrinsicContentSize.height
        tabs.frame = NSRect(x: 8, y: y, width: w - 16, height: th)
        y += th
        for v in [workflowSelect, kindSelect] where !v.isHidden {
            y += 8
            let sh = v.intrinsicContentSize.height
            v.frame = NSRect(x: 8, y: y, width: w - 16, height: sh)
            y += sh
        }
        for l in [kindsLine, triggerLine] where !l.isHidden {
            y += 8
            l.frame = NSRect(x: 12, y: y, width: w - 24, height: 16)
            y += 16
        }
        y += 4
        listScroll.frame = NSRect(x: 0, y: y, width: w, height: max(0, listColumn.bounds.height - y))
        // `p-2 pt-1`, rows `space-y-0.5`.
        var ry: CGFloat = 4
        if !nothing.isHidden {
            nothing.frame = NSRect(x: 16, y: ry + 24, width: w - 32, height: 16)
            ry += 64
        }
        for r in rowViews {
            r.frame = NSRect(x: 8, y: ry, width: w - 16, height: WorkflowRunRowView.height)
            ry += WorkflowRunRowView.height + 2
        }
        if !skippedButton.isHidden {
            ry += 6
            let bw = skippedButton.fittingSize.width
            skippedButton.frame = NSRect(x: (w - bw) / 2, y: ry, width: bw, height: 24)
            ry += 24
        }
        listDocument.frame = NSRect(x: 0, y: 0, width: w, height: max(listScroll.bounds.height, ry + 8))
    }

    private func layoutFeed() {
        let w = feedScroll.bounds.width
        // `mx-auto max-w-5xl px-5 pt-5 pb-10`.
        let fw = min(w, 1024)
        // `@container/feed` is the scroll area; `@2xl` is 42rem.
        feed.wide = w >= 672
        let fh = feed.height(forWidth: fw - 40)
        feed.frame = NSRect(x: (w - fw) / 2 + 20, y: 20, width: fw - 40, height: fh)
        feedDocument.frame = NSRect(x: 0, y: 0, width: w, height: max(feedScroll.bounds.height, fh + 60))
    }
}

final class WorkflowsDocument: DSView {
    override var isFlipped: Bool { true }
}

/// `WorkflowChip` (WorkflowRunFeed.tsx:138-161): a 16pt square, two letters at `text-4xs` bold, in one of five tones.
final class WorkflowChipView: DSView {
    static let tones = ["sky", "violet", "amber", "emerald", "rose"]
    private let label = LabelView("", font: DSFont.ui(8, weight: .bold))
    var name = "" { didSet { if name != oldValue { sync() } } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.alignment = .center
        label.lineHeight = 16
        addSubview(label)
        setAccessibilityElement(false)
    }

    private func sync() { label.text = WorkflowRuns.chip(name).letters; needsDisplay = true }

    override func layout() { super.layout(); label.frame = bounds }
    override var isFlipped: Bool { true }

    override var wantsUpdateLayer: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        let tone = Self.tones[WorkflowRuns.chip(name).tone]
        let dark = effectiveAppearance.isDark
        Themed.base("\(tone)-500").withAlphaComponent(0.15).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: DesignGeometry.radius(4, in: self), yRadius: DesignGeometry.radius(4, in: self)).fill()
        label.color = Themed.base("\(tone)-\(dark ? 300 : 700)")
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

/// `WorkflowStateWord` (WorkflowRunFeed.tsx:163-189): the thread list's colours for the same states.
final class WorkflowStateWordView: DSView {
    private let label = LabelView("", font: DSFont.ui(12, weight: .medium))
    private var tone: WorkflowRunTone = .quiet

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.lineHeight = 16
        // Its right edge is the row's, whatever rounding the width took.
        label.alignment = .right
        addSubview(label)
    }

    func set(_ node: WorkflowRunNode) {
        let s = WorkflowRuns.state(node)
        tone = s.tone
        label.text = s.word
        label.color = Self.color(s.tone)
        setAccessibilityLabel(s.word)
        needsLayout = true
        needsDisplay = true
    }

    static func color(_ tone: WorkflowRunTone) -> NSColor {
        switch tone {
        case .input: Themed.color(\.warningForeground)
        case .failed: Themed.color(\.destructive)
        case .working: Themed.color(\.infoForeground)
        case .quiet: Themed.color(\.mutedForeground)
        case .done: Themed.color(\.successForeground)
        }
    }

    /// `gap-1`, a `size-1.5` dot or `size-3` check before the word.
    private var markWidth: CGFloat { tone == .working ? 6 + 4 : tone == .done ? 12 + 4 : 0 }
    var width: CGFloat { markWidth + ceil(label.textWidth) + 1 }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: markWidth, y: (bounds.height - 16) / 2, width: bounds.width - markWidth, height: 16)
    }
    override var isFlipped: Bool { true }

    override var wantsUpdateLayer: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        let mid = bounds.midY
        switch tone {
        case .working:
            Themed.color(\.info).setFill()
            NSBezierPath(ovalIn: NSRect(x: 0, y: mid - 3, width: 6, height: 6)).fill()
        case .done:
            Self.color(.done).set()
            let p = NSBezierPath()
            p.lineWidth = 1.5
            p.move(to: NSPoint(x: 2, y: mid))
            p.line(to: NSPoint(x: 4.75, y: mid + 2.75))
            p.line(to: NSPoint(x: 10, y: mid - 2.75))
            p.stroke()
        default: break
        }
    }
}

/// `WorkflowRunListItem` (WorkflowRunsView.tsx:446-511): which workflow, its state in a word, the title, and what it
/// is at with the last change.
final class WorkflowRunRowView: DSView {
    static let height: CGFloat = 68
    private let chip = WorkflowChipView()
    private let workflowLabel = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    private let state = WorkflowStateWordView()
    private let title = LabelView("", font: DSFont.ui(14), color: Themed.color(\.foreground))
    private let now = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    private let time = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    private(set) var runId: String?
    private var current = false
    private var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }
    var onClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for l in [workflowLabel, now, time] { l.lineHeight = 16 }
        time.alignment = .right
        title.lineHeight = 20
        for v in [chip, workflowLabel, state, title, now, time] as [NSView] { addSubview(v) }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    func set(_ node: WorkflowRunNode, current: Bool, nowMs: Int64) {
        runId = node.run.runId
        self.current = current
        chip.name = node.run.workflow
        workflowLabel.text = node.run.workflow
        state.set(node)
        title.text = node.run.title
        now.text = WorkflowRuns.now(node)
        time.text = TimestampFormat.formatRelativeTimeLabel(node.run.updatedAt, nowMs: nowMs)
        setAccessibilityLabel("\(node.run.title), \(node.run.workflow), \(WorkflowRuns.state(node).word)")
        setAccessibilityValue(current ? "current" : nil)
        needsLayout = true
        needsDisplay = true
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        // `px-2 py-1.5`, lines `gap-0.5`.
        let w = bounds.width - 16
        chip.frame = NSRect(x: 8, y: 6, width: 16, height: 16)
        let sw = state.width
        state.frame = NSRect(x: 8 + w - sw, y: 6, width: sw, height: 16)
        workflowLabel.frame = NSRect(x: 8 + 16 + 6, y: 6, width: max(0, w - 16 - 6 - sw - 6), height: 16)
        title.frame = NSRect(x: 8, y: 24, width: w, height: 20)
        let tw = ceil(time.textWidth) + 1
        time.frame = NSRect(x: 8 + w - tw, y: 46, width: tw, height: 16)
        now.frame = NSRect(x: 8, y: 46, width: max(0, w - tw - 6), height: 16)
    }

    override var wantsUpdateLayer: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        guard current || hovered else { return }
        // `rounded-lg`, `bg-accent` or `hover:bg-accent/50`.
        Themed.color(\.accent, current ? 1 : 0.5).setFill()
        let r = DesignGeometry.radius(8, in: self)
        NSBezierPath(roundedRect: bounds, xRadius: r, yRadius: r).fill()
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
