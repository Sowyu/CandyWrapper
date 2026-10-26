import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// A thread under the Orchestrator, as an Overview card. Built from server events only, so it costs no tokens. Threads
/// never get a bot: the card carries the sidebar's own status icon.
public struct OrchestratorCrewCard: Equatable {
    /// Where the Overview lists it: work under way, work done, or work that stopped short (failed, a usage limit,
    /// never run). Approvals and questions list under Needs you as well.
    public enum Group: Equatable, Sendable { case running, finished, stopped }

    /// The group for a thread's sidebar status, given whether its latest turn completed.
    public static func group(_ status: SidebarThreadStatus, completedTurn: Bool) -> Group {
        switch status {
        case .working, .waiting, .approval, .input, .request: .running
        case .ready: completedTurn ? .finished : .stopped
        case .failed, .limited: .stopped
        }
    }

    public var id: ThreadId
    public var title: String
    public var project: String
    public var state: String
    /// The sidebar's top status, nil when idle.
    public var status: SidebarTopStatus?
    public var lastLine: String?
    /// "Kept out", or "You wrote 3 min ago, it asks first".
    public var note: String?
    public var group: Group
    public init(id: ThreadId, title: String, project: String, state: String, status: SidebarTopStatus?, lastLine: String?, note: String?,
                group: Group) {
        self.id = id; self.title = title; self.project = project; self.state = state; self.status = status
        self.lastLine = lastLine; self.note = note; self.group = group
    }
}

/// An approval or a question waiting in some thread on the machine.
public struct OrchestratorNeed: Equatable {
    public var threadId: ThreadId
    public var threadTitle: String
    public var requestId: String
    public var label: String
    /// Approvals get Allow and Deny through T3's own `runtime-request.respond`; questions open their thread.
    public var isApproval: Bool
    public init(threadId: ThreadId, threadTitle: String, requestId: String, label: String, isApproval: Bool) {
        self.threadId = threadId; self.threadTitle = threadTitle; self.requestId = requestId; self.label = label
        self.isApproval = isApproval
    }
}

public struct OrchestratorPaneState: Equatable {
    public var name = "Orchestrator"
    public var machine = ""
    public var environmentId = ""
    public var bot = BotIdentity.orchestrator
    public var started = false
    public var connected = false
    public var items: [OrchestratorChatItem] = []
    /// Whether the chat shows its activity lines.
    public var showsActivity = false
    /// Its composer's stashed prompts, newest first.
    public var stash: [OrchestratorStashEntry] = []
    /// Older history is there to page in, and no page is loading.
    public var hasEarlier = false
    /// Replies whose saved notes can still be undone, and those already undone.
    public var undoable: Set<String> = []
    public var undone: Set<String> = []
    public var crew: [OrchestratorCrewCard] = []
    public var needs: [OrchestratorNeed] = []
    public var working = false
    /// Images waiting to go with your next message.
    public var pendingImages: [ComposerAttachment] = []
    /// A question it asked with its question tool (AskUserQuestion), answered above the composer.
    public var question: PendingUserInput?
    /// Its thread's id on the server, which the answer names.
    public var threadLocalId = ""
    public init() {}
}

/// The Orchestrator's pane (docs/orchestrator.md, "More than a thread"): its chat, drawn like iMessage, and the
/// Overview of what needs you and every thread on its machine. The Digest tab waits for phase 3.
public final class OrchestratorPaneView: DSView {
    public var onSend: ((String) -> Void)?
    /// Every edit to the message you're writing, so the draft survives leaving the pane.
    public var onDraftChange: ((String) -> Void)? {
        get { composer.onDraftChange }
        set { composer.onDraftChange = newValue }
    }
    /// Images from the composer's + button, a paste or a drop.
    public var onImages: (([ComposerIncomingFile]) -> Void)? {
        get { composer.onImages }
        set { composer.onImages = newValue }
    }
    public var onRemoveImage: ((String) -> Void)? {
        get { composer.onRemoveImage }
        set { composer.onRemoveImage = newValue }
    }
    /// A sent image's thumbnail by attachment id, at a pixel side.
    public var imageLoader: ((String, Int) async -> CGImage?)? {
        get { chat.imageLoader }
        set { chat.imageLoader = newValue }
    }
    /// An answer to its question, a `runtime-request.respond` payload ready for `orchestration.dispatchCommand`.
    public var onAnswer: ((JSONValue) -> Void)?
    /// A signed URL for a published page (attachment id, file name), as the thread view loads them.
    public var webAssetURL: ((String, String) async -> URL?)? {
        get { chat.webAssetURL }
        set { chat.webAssetURL = newValue }
    }
    /// The answer didn't reach the server: the question takes input again.
    public func answerFailed() { questionPanel?.isResponding = false }
    /// Shows a saved draft, unless you're typing in the field.
    public func setDraft(_ text: String) { composer.draft = text }
    public var draft: String { composer.draft }
    /// Replaces what you're writing even while you type, as stashing and restoring do. The caller saves the draft.
    public func replaceDraft(_ text: String) { composer.setText(text) }
    /// A thread by its scoped id.
    public var onOpenThread: ((ThreadId) -> Void)?
    public var onRespond: ((OrchestratorNeed, ApprovalDecision) -> Void)?
    public var onUndoMemory: ((String) -> Void)?
    public var onStart: (() -> Void)?
    /// Opens the Orchestrator's thread in the normal thread view.
    public var onOpenAsThread: (() -> Void)?
    /// A click on its bot: Settings > Orchestrator, where its shape and colour change.
    public var onEditBot: (() -> Void)?
    public var onEscape: (() -> Void)?
    /// "Show activity" in the header: events, relay results and tool lines in the chat.
    public var onToggleActivity: (() -> Void)?
    /// Scrolling up near the top, or a chat too short to fill the view, asks for the next older page.
    public var onLoadEarlier: (() -> Void)?
    /// The composer's Stash, as the thread composer's: stash the draft, restore an entry into it, delete one.
    public var onStash: ((String) -> Void)?
    public var onRestoreStash: ((String) -> Void)?
    public var onDeleteStash: ((PromptStashEntry) -> Void)?

    private let headerBot = BotView(identity: .orchestrator, size: 30)
    private let headerBotButton = ControlView()
    private let title = LabelView("", font: DSFont.ui(15, weight: .semibold), color: Themed.color(\.foreground))
    private let subtitle = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    private let tabs = ToggleGroupView(variant: .segmented, items: [("Chat", nil), ("Overview", nil)], selected: 0)
    private let openThread = ButtonView("Open as thread", icon: .arrowUpRight, variant: .ghost, size: .sm)
    private let activity = ButtonView("Show activity", variant: .ghost, size: .sm)
    private let stashBadge = ComposerStashBadgeView()
    /// Made the first time the list opens.
    private var stashMenuView: ComposerStashMenuView?
    private var stashMenu: ComposerStashMenuView {
        if let m = stashMenuView { return m }
        let m = ComposerStashMenuView()
        m.placement = .floating
        m.onRestore = { [weak self] entry in self?.setStashMenu(false); self?.onRestoreStash?(entry.id) }
        m.onDelete = { [weak self] entry in self?.onDeleteStash?(entry) }
        m.onClose = { [weak self] in self?.setStashMenu(false) }
        addSubview(m, positioned: .below, relativeTo: composer)
        stashMenuView = m
        return m
    }
    private var stashMenuOpen = false
    private var stashMonitor: Any?
    private let chat = OrchestratorChatView()
    private lazy var chatScroll = ScrollAreaView(documentView: chat, scrollFade: true)
    private let overview = OrchestratorOverviewView()
    private lazy var overviewScroll = ScrollAreaView(documentView: overview, scrollFade: true)
    let composer = OrchestratorComposerView()
    private let start = ButtonView("Start the Orchestrator", size: .default)
    private let divider = CALayer()
    public private(set) var state = OrchestratorPaneState()
    private var showsOverview = false
    /// The thread composer's question banner, above the composer while a question is open.
    private var questionPanel: QuestionPanelView?
    /// What you were writing when the question came; it comes back once the question is answered.
    private var draftBeforeQuestion = ""

    public override init(frame: NSRect) {
        super.init(frame: frame)
        for v in [headerBot, title, subtitle, tabs, activity, openThread, chatScroll, overviewScroll, composer, start] as [NSView] { addSubview(v) }
        addSubview(headerBotButton)
        headerBotButton.setAccessibilityLabel("Change the Orchestrator's look")
        headerBotButton.toolTip = "Change its shape and colour"
        headerBotButton.action = { [weak self] in self?.onEditBot?() }
        divider.actions = ["position": NSNull(), "bounds": NSNull(), "backgroundColor": NSNull()]
        layer?.addSublayer(divider)
        for s in [chatScroll, overviewScroll] {
            // The chat and the Overview are columns: they wrap, never scroll sideways.
            s.scrollsHorizontally = false
            s.scrollView.automaticallyAdjustsContentInsets = false
            s.scrollView.contentInsets = NSEdgeInsets()
        }
        overviewScroll.isHidden = true
        NotificationCenter.default.addObserver(self, selector: #selector(chatScrolled), name: NSView.boundsDidChangeNotification,
                                               object: chatScroll.scrollView.contentView)
        tabs.setAccessibilityLabel("Orchestrator view")
        tabs.onChange = { [weak self, weak tabs] i in
            guard let self else { return }
            guard let i else { tabs?.selectedIndex = self.showsOverview ? 1 : 0; return }
            self.showsOverview = i == 1
            self.chatScroll.isHidden = self.showsOverview
            self.overviewScroll.isHidden = !self.showsOverview
            self.composer.isHidden = !self.state.started || self.showsOverview
            self.activity.isHidden = !self.state.started || self.showsOverview
            self.needsLayout = true
        }
        openThread.action = { [weak self] in self?.onOpenAsThread?() }
        activity.action = { [weak self] in self?.onToggleActivity?() }
        stashBadge.placement = .floating
        stashBadge.isHidden = true
        stashBadge.onToggleMenu = { [weak self] in self.map { $0.setStashMenu(!$0.stashMenuOpen) } }
        addSubview(stashBadge, positioned: .below, relativeTo: composer)
        activity.toolTip = "Events, relay results and the tools each turn used"
        start.action = { [weak self] in self?.onStart?() }
        composer.onSend = { [weak self] text in self?.onSend?(text) }
        chat.onOpenThread = { [weak self] local in self?.open(local) }
        chat.onRespond = { [weak self] need, d in self?.onRespond?(need, d) }
        chat.onUndo = { [weak self] id in self?.onUndoMemory?(id) }
        chat.onHeightChange = { [weak self] in self?.chatGrew() }
        overview.onOpenThread = { [weak self] id in self?.onOpenThread?(id) }
        overview.onRespond = { [weak self] need, d in self?.onRespond?(need, d) }
        setAccessibilityLabel("Orchestrator")
    }

    private func open(_ local: String) {
        onOpenThread?(ThreadId(local).scoped(to: state.environmentId))
    }

    public func set(_ next: OrchestratorPaneState) {
        guard next != state else { return }
        let old = state
        state = next
        headerBot.identity = next.bot
        headerBot.mood = !next.needs.isEmpty ? .needsYou : next.working ? .working : .idle
        title.text = next.name
        let status = !next.started ? "Not started" : !next.connected ? "Offline" : next.working ? "Working"
            : next.needs.isEmpty ? nil : "\(next.needs.count) waiting on you"
        subtitle.text = [next.machine, status].compactMap { $0 }.joined(separator: " · ")
        openThread.isHidden = !next.started
        activity.isHidden = !next.started || showsOverview
        if old.stash != next.stash {
            stashBadge.count = next.stash.count
            stashMenuView?.entries = Self.menuEntries(next.stash)
            if next.stash.isEmpty { setStashMenu(false) }
            needsLayout = true
        }
        if old.showsActivity != next.showsActivity {
            activity.title = next.showsActivity ? "Hide activity" : "Show activity"
            needsLayout = true
        }
        start.isHidden = next.started
        composer.isHidden = !next.started || showsOverview
        composer.isEnabled = next.connected
        composer.attachments = next.pendingImages
        if old.question != next.question || old.threadLocalId != next.threadLocalId { syncQuestion() }
        if questionPanel == nil { composer.placeholder = "Message \(next.name)" }
        // Before the items, so new stacks get the picked bot.
        if old.bot != next.bot { chat.setAvatarIdentity(next.bot) }
        if old.items != next.items || old.undoable != next.undoable || old.undone != next.undone || old.needs != next.needs
            || old.environmentId != next.environmentId || old.name != next.name {
            // An older page landed above what you're reading: keep your place, measured from the bottom.
            if !pinnedToBottom, let first = old.items.first(where: { $0.id != "loading-earlier" }),
               next.items.first(where: { $0.id != "loading-earlier" })?.id != first.id, next.items.contains(where: { $0.id == first.id }) {
                keepFromBottom = chat.frame.height - chatScroll.scrollView.contentView.bounds.minY
            }
            chat.set(items: next.items, needs: next.needs, undoable: next.undoable, undone: next.undone, environmentId: next.environmentId,
                     name: next.name)
        }
        if next.hasEarlier, !old.hasEarlier || old.items != next.items { DispatchQueue.main.async { [weak self] in self?.loadEarlierIfNeeded() } }
        if old.crew != next.crew || old.needs != next.needs { overview.set(crew: next.crew, needs: next.needs) }
        needsLayout = true
    }

    public func focusComposer() { composer.focus() }

    // MARK: Stash

    /// The composer's stash key (`composer.stash`), passed on by the thread composer while this pane shows.
    public func stashDraft() {
        guard state.started, !showsOverview, questionPanel == nil else { return }
        onStash?(composer.draft)
    }

    /// After a stash: the badge lifts and its count turns primary for 1.2 s, as on the thread composer.
    public func pulseStash() {
        stashBadge.pulse()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.stashBadge.pulsing = false }
    }

    /// Opens or closes the list, which the thread composer's arrows, Return, Cmd+Backspace and Escape drive.
    public func setStashMenu(_ open: Bool) {
        let open = open && !state.stash.isEmpty
        guard open != stashMenuOpen else { return }
        stashMenuOpen = open
        stashBadge.menuOpen = open
        if let m = stashMonitor { NSEvent.removeMonitor(m); stashMonitor = nil }
        if open {
            stashMenu.entries = Self.menuEntries(state.stash)
            stashMenu.reload()
            stashMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                if event.type == .keyDown { return self.stashMenu.handleKey(event) ? nil : event }
                let inside = [self.stashMenu, self.stashBadge].contains { $0.bounds.contains($0.convert(event.locationInWindow, from: nil)) }
                if !inside { self.setStashMenu(false) }
                return event
            }
        }
        needsLayout = true
    }

    /// Its entries in the thread composer's stash rows: text only, so no images or files.
    static func menuEntries(_ stash: [OrchestratorStashEntry]) -> [PromptStashEntry] {
        stash.map { PromptStashEntry(id: $0.id, createdAt: $0.createdAt, prompt: $0.prompt) }
    }

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { setStashMenu(false) }
    }

    /// Opens, moves or closes the question banner. While it shows, the composer's field is its free-text answer,
    /// Return and Send advance it, and an option pick may submit it, as in the thread composer.
    private func syncQuestion() {
        guard let input = state.question, !state.threadLocalId.isEmpty else {
            guard let panel = questionPanel else { return }
            panel.removeFromSuperview()
            questionPanel = nil
            composer.answering = nil
            composer.placeholder = "Message \(state.name)"
            composer.setText(draftBeforeQuestion)
            needsLayout = true
            return
        }
        let panel = questionPanel ?? {
            let p = QuestionPanelView()
            p.onSubmit = { [weak self, weak p] payload in p?.isResponding = true; self?.onAnswer?(payload) }
            p.onDismiss = { [weak self, weak p] payload in p?.isResponding = true; self?.onAnswer?(payload) }
            p.onChange = { [weak self] in self?.questionChanged() }
            addSubview(p, positioned: .below, relativeTo: composer)
            questionPanel = p
            draftBeforeQuestion = composer.draft
            composer.answering = (text: { [weak p] t in p?.setCustomAnswer(t) }, advance: { [weak p] in p?.advance() })
            return p
        }()
        panel.configure(input, threadId: ThreadId(state.threadLocalId))
        questionChanged()
    }

    private func questionChanged() {
        guard let panel = questionPanel else { return }
        composer.placeholder = panel.placeholder
        composer.answerEditable = panel.editorEnabled
        if composer.draft != panel.customAnswer { composer.setText(panel.customAnswer) }
        needsLayout = true
    }

    private var pinnedToBottom = true

    private func chatGrew() {
        layoutChat()
        if pinnedToBottom { scrollToBottom() }
    }

    private func scrollToBottom() {
        let clip = chatScroll.scrollView.contentView.bounds.height
        chatScroll.scroll(to: NSPoint(x: 0, y: max(0, chat.frame.height - clip)))
    }

    private func layoutChat() {
        let w = chatScroll.contentWidth
        let h = max(chat.height(forWidth: w), chatScroll.bounds.height)
        let clip = chatScroll.scrollView.contentView.bounds
        pinnedToBottom = keepFromBottom == nil && (clip.maxY >= chat.frame.height - 40 || chat.frame.height <= clip.height)
        chat.frame = NSRect(x: 0, y: 0, width: w, height: h)
        if let fromBottom = keepFromBottom {
            keepFromBottom = nil
            chatScroll.scroll(to: NSPoint(x: 0, y: max(0, h - fromBottom)))
        }
    }

    /// Where you were, from the bottom, while an older page goes in above.
    private var keepFromBottom: CGFloat?
    /// How close to the top a scroll asks for the next older page.
    static let earlierThreshold: CGFloat = 600

    /// Asks for the next older page when you're near the top, or when what shows doesn't fill the view.
    private func loadEarlierIfNeeded() {
        guard state.hasEarlier, !chatScroll.isHidden, window != nil else { return }
        let clip = chatScroll.scrollView.contentView.bounds
        // The chat's frame is at least the view's height, so equal means what shows doesn't fill it.
        guard clip.minY < Self.earlierThreshold || chat.frame.height <= clip.height + 1 else { return }
        onLoadEarlier?()
    }

    @objc private func chatScrolled() {
        chat.syncVisiblePages()
        loadEarlierIfNeeded()
    }

    /// For tests: scrolls the chat to a y offset from its top.
    func scrollChat(toY y: CGFloat) {
        let maxY = max(0, chat.frame.height - chatScroll.scrollView.contentView.bounds.height)
        chatScroll.scroll(to: NSPoint(x: 0, y: min(max(0, y), maxY)))
    }

    public override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        // The main area already starts under Redesign's tab band, so the header sits at the top.
        let top: CGFloat = 0
        headerBot.frame = NSRect(x: 20, y: top + 6, width: 30, height: 30)
        headerBotButton.frame = headerBot.frame.insetBy(dx: -4, dy: -4)
        let tw = tabs.intrinsicContentSize.width
        tabs.frame = NSRect(x: (w - tw) / 2, y: top + 8, width: tw, height: 28)
        let ow = openThread.intrinsicContentSize.width
        openThread.frame = NSRect(x: w - 16 - ow, y: top + 8, width: ow, height: 28)
        let aw = activity.intrinsicContentSize.width
        activity.frame = NSRect(x: openThread.frame.minX - 4 - aw, y: top + 8, width: aw, height: 28)
        let textRight = min(tabs.frame.minX - 12, (activity.isHidden ? openThread : activity).frame.minX - 12)
        title.frame = NSRect(x: 58, y: top + 4, width: max(0, textRight - 58), height: 20)
        subtitle.frame = NSRect(x: 58, y: top + 23, width: max(0, textRight - 58), height: 16)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        divider.frame = CGRect(x: 0, y: top + 47, width: w, height: 1)
        divider.backgroundColor = Themed.color(\.border, 0.5).cgColor(in: self)
        CATransaction.commit()
        let bodyTop = top + 48
        let composerH = composer.isHidden ? 0 : composer.height(forWidth: min(720, w - 40)) + 24
        let startH: CGFloat = start.isHidden ? 0 : 72
        chatScroll.frame = NSRect(x: 0, y: bodyTop, width: w, height: max(0, h - bodyTop - composerH - startH))
        overviewScroll.frame = NSRect(x: 0, y: bodyTop, width: w, height: max(0, h - bodyTop))
        let cw = min(720, w - 40)
        composer.frame = NSRect(x: (w - cw) / 2, y: h - composerH + 8, width: cw, height: composerH - 24)
        // The Stash pill floats over the composer's right edge, its list above it, as in Redesign's thread composer.
        let badgeShown = !composer.isHidden && !state.stash.isEmpty && questionPanel == nil
        stashBadge.isHidden = !badgeShown
        if badgeShown {
            let bw = stashBadge.width(showingTitle: true)
            stashBadge.frame = NSRect(x: composer.frame.maxX - DitherPill.inset - bw, y: composer.frame.minY - DitherPill.gap - DitherPill.height,
                                      width: bw, height: DitherPill.height)
            chatScroll.frame.size.height = max(0, stashBadge.frame.minY - 8 - chatScroll.frame.minY)
        }
        let menuShown = badgeShown && stashMenuOpen
        stashMenuView?.isHidden = !menuShown
        if menuShown {
            let maxList = min(384, (window?.contentView?.bounds.height ?? bounds.height) * 0.4)
            let base = stashBadge.frame.minY
            let mh = min(stashMenu.preferredHeight(maxList: maxList) - ComposerBannerView.overlap, max(96, base - DitherPill.gap - bodyTop - 8))
            stashMenu.frame = NSRect(x: composer.frame.minX, y: base - DitherPill.gap - mh, width: cw, height: mh)
        }
        // The question banner tucks its last 17pt under the composer, as above the thread composer.
        if let panel = questionPanel {
            let qh = panel.preferredHeight(width: cw)
            panel.frame = NSRect(x: composer.frame.minX, y: composer.frame.minY - qh + ComposerBannerView.overlap, width: cw, height: qh)
            chatScroll.frame.size.height = max(0, panel.frame.minY - 8 - chatScroll.frame.minY)
        }
        let sw = start.intrinsicContentSize.width
        start.frame = NSRect(x: (w - sw) / 2, y: h - 56, width: sw, height: 36)
        layoutChat()
        if pinnedToBottom { scrollToBottom() }
        let columnWidth = overviewScroll.contentWidth
        overview.frame = NSRect(x: 0, y: 0, width: columnWidth, height: max(overview.height(forWidth: columnWidth), overviewScroll.bounds.height))
    }

    public override func cancelOperation(_ sender: Any?) { onEscape?() }

    /// Redesign's art shows under the chat behind the heavy page scrim (the user, 2026-10-25), also while a thread
    /// panel that's out of sight registers again.
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DitherArtView.setEmphasis(window == nil ? nil : .page, from: self)
    }
    public override func viewDidHide() { super.viewDidHide(); DitherArtView.pagesMoved() }
    public override func viewDidUnhide() { super.viewDidUnhide(); DitherArtView.pagesMoved() }
}

// MARK: - Chat

/// The chat's document: items top to bottom, the Orchestrator's on the left with its bot under each stack, yours on
/// the right. Views are kept by item id, so streaming text only reflows the bubble that grew.
final class OrchestratorChatView: DSView {
    var onOpenThread: ((String) -> Void)?
    var onRespond: ((OrchestratorNeed, ApprovalDecision) -> Void)?
    var onUndo: ((String) -> Void)?
    var onHeightChange: (() -> Void)?
    var imageLoader: ((String, Int) async -> CGImage?)?
    var webAssetURL: ((String, String) async -> URL?)?
    private var items: [OrchestratorChatItem] = []
    private var views: [String: NSView] = [:]
    private var order: [String] = []
    private var needsCard: OrchestratorNeedsCard?
    private var needs: [OrchestratorNeed] = []
    private var avatars: [String: BotView] = [:]
    /// Its name over the first bubble of each of its stacks, as a group chat names the sender.
    private var names: [String: LabelView] = [:]
    private var environmentId = ""
    private let htmlCache = HtmlRenderWebCache()
    static let maxBubble: CGFloat = 520

    func set(items: [OrchestratorChatItem], needs: [OrchestratorNeed], undoable: Set<String>, undone: Set<String>, environmentId: String,
             name: String) {
        let environmentChanged = self.environmentId != environmentId
        if environmentChanged { htmlCache.clear() }
        self.items = items
        self.environmentId = environmentId
        var next: [String: NSView] = [:]
        for item in items {
            let id = item.id
            switch item {
            case .bubble(_, let user, let text, let first, let last):
                let b = (views[id] as? OrchestratorBubbleView) ?? OrchestratorBubbleView(fromUser: user)
                b.onLink = { [weak self] url in self?.openLink(url) }
                b.set(text: text, first: first, last: last)
                next[id] = b
            case .time(_, let label):
                next[id] = (views[id] as? OrchestratorCenteredLine) ?? OrchestratorCenteredLine(label, threadId: nil, weight: .medium)
            case .line(_, let text, let thread):
                let l = (views[id] as? OrchestratorCenteredLine) ?? OrchestratorCenteredLine(text, threadId: thread, weight: .regular)
                l.onOpen = { [weak self] t in self?.onOpenThread?(t) }
                next[id] = l
            case .brief(_, let text, let updated):
                next[id] = (views[id] as? OrchestratorBriefCard) ?? {
                    let c = OrchestratorBriefCard(text: text, updated: updated)
                    c.onToggle = { [weak self] in self?.relayout() }
                    return c
                }()
            case .plan(_, let steps):
                let p = (views[id] as? OrchestratorPlanCard) ?? OrchestratorPlanCard()
                p.set(steps, environmentId: environmentId)
                p.onOpen = { [weak self] t in self?.onOpenThread?(t) }
                next[id] = p
            case .memory(_, let messageId, let notes):
                let m = (views[id] as? OrchestratorMemoryChip) ?? OrchestratorMemoryChip()
                m.set(notes: notes, canUndo: undoable.contains(messageId), undone: undone.contains(messageId))
                m.onUndo = { [weak self] in self?.onUndo?(messageId) }
                next[id] = m
            case .image(_, let attachmentId, let name):
                next[id] = (views[id] as? OrchestratorImageBubble) ?? {
                    let b = OrchestratorImageBubble(attachmentId: attachmentId, name: name)
                    b.onLoaded = { [weak self] in self?.relayout() }
                    b.load(self.imageLoader)
                    return b
                }()
            case .html(_, let page):
                let old = environmentChanged ? nil : views[id] as? OrchestratorHtmlCard
                let card: OrchestratorHtmlCard
                if let old, old.page == page { card = old }
                else { card = OrchestratorHtmlCard(page) }
                card.frameView.htmlCache = htmlCache
                card.assetURL = webAssetURL
                card.onHeightChange = { [weak self] in self?.relayout() }
                next[id] = card
            case .read:
                next[id] = (views[id] as? OrchestratorReadLabel) ?? OrchestratorReadLabel()
            case .typing:
                next[id] = (views[id] as? OrchestratorTypingBubble) ?? OrchestratorTypingBubble()
            }
        }
        for (id, v) in views where next[id] !== v { v.removeFromSuperview() }
        for v in next.values where v.superview !== self { addSubview(v) }
        views = next
        order = items.map(\.id)
        // The bot sits under each of the Orchestrator's stacks.
        var nextAvatars: [String: BotView] = [:]
        for item in items {
            guard case .bubble(let id, false, _, _, true) = item else { continue }
            let bot = avatars[id] ?? BotView(identity: avatarIdentity, size: 26)
            if bot.superview !== self { addSubview(bot) }
            nextAvatars[id] = bot
        }
        for (id, b) in avatars where nextAvatars[id] == nil { b.removeFromSuperview() }
        avatars = nextAvatars
        var nextNames: [String: LabelView] = [:]
        for item in items {
            guard case .bubble(let id, false, _, true, _) = item else { continue }
            let label = names[id] ?? {
                let l = LabelView("", font: DSFont.ui(11, weight: .medium), color: Themed.color(\.mutedForeground))
                l.lineHeight = 14
                return l
            }()
            label.text = name
            if label.superview !== self { addSubview(label) }
            nextNames[id] = label
        }
        for (id, l) in names where nextNames[id] == nil { l.removeFromSuperview() }
        names = nextNames
        self.needs = needs
        if needs.isEmpty {
            needsCard?.removeFromSuperview()
            needsCard = nil
        } else {
            let card = needsCard ?? OrchestratorNeedsCard()
            card.onRespond = { [weak self] n, d in self?.onRespond?(n, d) }
            card.onOpen = { [weak self] n in self?.onOpenThread?(n.threadId.localId.rawValue) }
            card.set(needs, limit: 5)
            if card.superview !== self { addSubview(card) }
            needsCard = card
        }
        relayout()
    }

    /// The Orchestrator's bot under its stacks.
    private var avatarIdentity = BotIdentity.orchestrator

    func setAvatarIdentity(_ identity: BotIdentity) {
        avatarIdentity = identity
        avatars.values.forEach { $0.identity = identity }
    }

    private func relayout() {
        needsLayout = true
        onHeightChange?()
    }

    private func openLink(_ url: URL) {
        if url.scheme == "t3-thread", let id = url.pathComponents.last, !id.isEmpty, id != "/" { onOpenThread?(id); return }
        NSWorkspace.shared.open(url)
    }

    /// Each view's frame for a width, top to bottom.
    private func frames(forWidth w: CGFloat) -> (frames: [(NSView, NSRect)], height: CGFloat) {
        var out: [(NSView, NSRect)] = []
        let lane = min(w - 40, 760), x0 = (w - lane) / 2
        var y: CGFloat = 20
        let maxBubble = min(Self.maxBubble, lane * 0.75)
        var previous: OrchestratorChatItem?
        for item in items {
            guard let v = views[item.id] else { continue }
            // Stacks sit 2 apart, other items 10.
            if let previous {
                if case .bubble(_, let a, _, _, _) = previous, case .bubble(_, let b, _, _, _) = item, a == b { y += 2 } else { y += 10 }
            }
            switch item {
            case .bubble(let id, let user, _, _, let last):
                let b = v as! OrchestratorBubbleView
                let size = b.size(maxWidth: maxBubble)
                let x = user ? x0 + lane - size.width : x0 + 34
                if let name = names[id] {
                    out.append((name, NSRect(x: x + OrchestratorBubbleView.tail + 12, y: y, width: maxBubble, height: 14)))
                    y += 16
                }
                out.append((b, NSRect(x: x, y: y, width: size.width, height: size.height)))
                if !user, last, let bot = avatars[id] { out.append((bot, NSRect(x: x0, y: y + size.height - 24, width: 26, height: 26))) }
                y += size.height
            case .html:
                // As wide as the thread view's reply column allows, in the Orchestrator's lane.
                let width = min(lane - 34, CGFloat(HtmlRenderReference.columnWidth))
                let h = (v as! OrchestratorHtmlCard).height(forWidth: width)
                out.append((v, NSRect(x: x0 + 34, y: y, width: width, height: h)))
                y += h
            case .image:
                let size = (v as! OrchestratorImageBubble).size(maxSide: min(240, maxBubble))
                // Flush with the bubbles' body, inside their tail.
                out.append((v, NSRect(x: x0 + lane - OrchestratorBubbleView.tail - size.width, y: y, width: size.width, height: size.height)))
                y += size.height
            case .read:
                out.append((v, NSRect(x: x0 + lane - 60, y: y - 6, width: 60, height: 14)))
                y += 8
            case .typing:
                out.append((v, NSRect(x: x0 + 34, y: y, width: OrchestratorTypingBubble.size.width, height: OrchestratorTypingBubble.size.height)))
                y += OrchestratorTypingBubble.size.height
            case .plan, .memory:
                let sized = v as! NSView & SettingsGroupRow
                let width = min(maxBubble, item.isMemory ? (v as! OrchestratorMemoryChip).preferredWidth : maxBubble)
                let h = sized.height(forWidth: width)
                out.append((v, NSRect(x: x0 + 34, y: y, width: width, height: h)))
                y += h
            case .brief:
                let card = v as! OrchestratorBriefCard
                let width = min(lane, 560)
                let h = card.height(forWidth: width)
                out.append((v, NSRect(x: x0 + (lane - width) / 2, y: y, width: width, height: h)))
                y += h
            case .time, .line:
                let line = v as! OrchestratorCenteredLine
                let h = line.height(forWidth: lane)
                out.append((v, NSRect(x: x0, y: y, width: lane, height: h)))
                y += h
            }
            previous = item
        }
        if let card = needsCard {
            y += 14
            let width = min(maxBubble, lane)
            let h = card.height(forWidth: width)
            out.append((card, NSRect(x: x0 + 34, y: y, width: width, height: h)))
            y += h
        }
        return (out, y + 20)
    }

    func height(forWidth width: CGFloat) -> CGFloat { frames(forWidth: width).height }

    override func layout() {
        super.layout()
        for (v, f) in frames(forWidth: bounds.width).frames where v.frame != f { v.frame = f }
        syncVisiblePages()
    }

    /// Only cards intersecting the clip view own web views, including after an older history page lands.
    func syncVisiblePages() {
        let shown = window != nil && !isHiddenOrHasHiddenAncestor
        let cards = views.values.compactMap { $0 as? OrchestratorHtmlCard }
        htmlCache.setActive(shown && !cards.isEmpty)
        let viewport = visibleRect
        // Release departing pages before starting incoming ones, so the budget never evicts a visible page.
        for card in cards where !shown || !card.frame.intersects(viewport) { card.setContentVisible(false) }
        for card in cards where shown && card.frame.intersects(viewport) { card.setContentVisible(true) }
    }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); syncVisiblePages() }
    override func viewDidHide() { super.viewDidHide(); syncVisiblePages() }
    override func viewDidUnhide() { super.viewDidUnhide(); syncVisiblePages() }
}

private extension OrchestratorChatItem {
    var isMemory: Bool { if case .memory = self { true } else { false } }
}

/// One bubble: accent on the right for you, grey on the left for the Orchestrator. Corners between bubbles of one
/// stack tighten, and only the last one gets a tail.
final class OrchestratorBubbleView: DSView, NSTextViewDelegate {
    let fromUser: Bool
    private let shape = CAShapeLayer()
    private let text = NSTextView()
    private var first = true, last = true
    private var markdown = ""
    private var cachedSize: (width: CGFloat, size: NSSize)?
    var onLink: ((URL) -> Void)?
    static let padX: CGFloat = 12, padY: CGFloat = 7, tail: CGFloat = 6

    init(fromUser: Bool) {
        self.fromUser = fromUser
        super.init(frame: .zero)
        shape.actions = ["path": NSNull(), "fillColor": NSNull(), "position": NSNull(), "bounds": NSNull()]
        layer?.addSublayer(shape)
        text.drawsBackground = false
        text.isEditable = false
        text.isSelectable = true
        text.textContainerInset = .zero
        text.textContainer?.lineFragmentPadding = 0
        text.delegate = self
        text.isVerticallyResizable = false
        text.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        addSubview(text)
    }

    func set(text markdown: String, first: Bool, last: Bool) {
        let changed = markdown != self.markdown
        self.markdown = markdown
        self.first = first
        self.last = last
        if changed {
            restyleText()
            cachedSize = nil
        }
        needsLayout = true
        needsDisplay = true
    }

    private var textColor: NSColor { fromUser ? Themed.color(\.primaryForeground) : Themed.color(\.foreground) }

    private func restyleText() {
        let link = fromUser ? Themed.color(\.primaryForeground) : Themed.color(\.primary)
        text.textStorage?.setAttributedString(OrchestratorChatText.attributed(markdown, color: textColor.resolved(in: self), linkColor: link.resolved(in: self)))
    }

    func size(maxWidth: CGFloat) -> NSSize {
        if let c = cachedSize, c.width == maxWidth { return c.size }
        let inner = maxWidth - 2 * Self.padX - Self.tail
        guard let container = text.textContainer, let lm = text.layoutManager else { return .zero }
        container.containerSize = NSSize(width: inner, height: .greatestFiniteMagnitude)
        lm.ensureLayout(for: container)
        let used = lm.usedRect(for: container)
        let size = NSSize(width: ceil(used.width) + 2 * Self.padX + Self.tail, height: max(32, ceil(used.height) + 2 * Self.padY))
        cachedSize = (maxWidth, size)
        return size
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyleText()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let inset: CGFloat = fromUser ? 0 : Self.tail
        text.frame = NSRect(x: inset + Self.padX, y: Self.padY, width: bounds.width - Self.tail - 2 * Self.padX, height: bounds.height - 2 * Self.padY)
        text.textContainer?.containerSize = NSSize(width: text.frame.width, height: .greatestFiniteMagnitude)
        shape.frame = bounds
        shape.path = path()
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        shape.fillColor = (fromUser ? Themed.color(\.primary) : Themed.color(\.secondary)).cgColor(in: self)
    }

    /// The bubble with its corners and, on the last of a stack, the tail at the sender's bottom corner.
    private func path() -> CGPath {
        let p = CGMutablePath()
        let t = Self.tail
        let r: CGFloat = 16, tight: CGFloat = 5
        let body = fromUser ? CGRect(x: 0, y: 0, width: bounds.width - t, height: bounds.height)
            : CGRect(x: t, y: 0, width: bounds.width - t, height: bounds.height)
        // y grows down (flipped): the "top" corners have the smaller y.
        let senderTop = first ? r : tight, senderBottom = last ? r : tight
        let tl = fromUser ? r : senderTop, bl = fromUser ? r : senderBottom
        let tr = fromUser ? senderTop : r, br = fromUser ? senderBottom : r
        p.move(to: CGPoint(x: body.minX + tl, y: body.minY))
        p.addLine(to: CGPoint(x: body.maxX - tr, y: body.minY))
        p.addArc(tangent1End: CGPoint(x: body.maxX, y: body.minY), tangent2End: CGPoint(x: body.maxX, y: body.minY + tr), radius: tr)
        if fromUser && last {
            p.addLine(to: CGPoint(x: body.maxX, y: body.maxY - 10))
            p.addQuadCurve(to: CGPoint(x: body.maxX + t, y: body.maxY), control: CGPoint(x: body.maxX, y: body.maxY - 1))
            p.addQuadCurve(to: CGPoint(x: body.maxX - 10, y: body.maxY - 3), control: CGPoint(x: body.maxX - 3, y: body.maxY))
            p.addQuadCurve(to: CGPoint(x: body.maxX - 18, y: body.maxY), control: CGPoint(x: body.maxX - 13, y: body.maxY))
        } else {
            p.addLine(to: CGPoint(x: body.maxX, y: body.maxY - br))
            p.addArc(tangent1End: CGPoint(x: body.maxX, y: body.maxY), tangent2End: CGPoint(x: body.maxX - br, y: body.maxY), radius: br)
        }
        if !fromUser && last {
            p.addLine(to: CGPoint(x: body.minX + 18, y: body.maxY))
            p.addQuadCurve(to: CGPoint(x: body.minX + 10, y: body.maxY - 3), control: CGPoint(x: body.minX + 13, y: body.maxY))
            p.addQuadCurve(to: CGPoint(x: body.minX - t, y: body.maxY), control: CGPoint(x: body.minX + 3, y: body.maxY))
            p.addQuadCurve(to: CGPoint(x: body.minX, y: body.maxY - 10), control: CGPoint(x: body.minX, y: body.maxY - 1))
        } else {
            p.addLine(to: CGPoint(x: body.minX + bl, y: body.maxY))
            p.addArc(tangent1End: CGPoint(x: body.minX, y: body.maxY), tangent2End: CGPoint(x: body.minX, y: body.maxY - bl), radius: bl)
        }
        p.addLine(to: CGPoint(x: body.minX, y: body.minY + tl))
        p.addArc(tangent1End: CGPoint(x: body.minX, y: body.minY), tangent2End: CGPoint(x: body.minX + tl, y: body.minY), radius: tl)
        p.closeSubpath()
        return p
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)) else { return false }
        onLink?(url)
        return true
    }
}

private extension NSColor {
    /// The color as this view's appearance draws it, for attributed text that can't resolve dynamic colors later.
    func resolved(in view: NSView) -> NSColor {
        var out = self
        view.effectiveAppearance.performAsCurrentDrawingAppearance { out = NSColor(cgColor: self.cgColor) ?? self }
        return out
    }
}

/// A page the Orchestrator published with `html_render`, framed as the thread view frames it (`HtmlRenderRowView`): the
/// same web frame, theme and messages, at the server's measured height until the page reports its own. The web view
/// exists only while the card intersects the viewport. The chat shares cached responses and purgeable pixels while it is shown.
// ponytail: no "Open full screen"; borrow HtmlRenderRowView's when the Conductor needs it
final class OrchestratorHtmlCard: DSView {
    let page: HtmlRenderReference
    let frameView = ThreadWebFrameView()
    private let failed = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    private var contentHeights = HtmlRenderHeights()
    private var contentVisible = false
    private var loading: Task<Void, Never>?
    var assetURL: ((String, String) async -> URL?)? { didSet { syncContent() } }
    var onHeightChange: (() -> Void)?

    init(_ page: HtmlRenderReference) {
        self.page = page
        super.init(frame: .zero)
        addSubview(frameView)
        frameView.htmlAttachmentId = page.attachmentId
        frameView.isHidden = true
        failed.text = "Unable to load \(page.title)"
        failed.alignment = .center
        failed.isHidden = true
        addSubview(failed)
        frameView.onMessage = { [weak self] data in self?.received(data) }
        setAccessibilityLabel(page.title)
    }

    isolated deinit { loading?.cancel(); frameView.release() }

    func height(forWidth width: CGFloat) -> CGFloat {
        CGFloat(page.frameHeight(width: Double(width), contentHeight: contentHeights.height(width: Double(width))))
    }

    private var onScreen: Bool { window != nil && !isHiddenOrHasHiddenAncestor }

    func setContentVisible(_ visible: Bool) {
        let retry = visible && !frameView.isLive && ThreadWebFrameBudget.count < ThreadWebFrameBudget.limit
        guard visible != contentVisible || retry else { return }
        contentVisible = visible
        frameView.isHidden = !visible
        frameView.dark = effectiveAppearance.isDark
        frameView.needsLayout = true
        syncContent()
    }

    private func syncContent() {
        guard onScreen && contentVisible else {
            loading?.cancel()
            loading = nil
            frameView.release()
            return
        }
        guard !frameView.isLive, loading == nil, let assetURL else { return }
        let page = self.page
        loading = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let url = await assetURL(page.attachmentId, page.fileName)
            guard let self, !Task.isCancelled else { return }
            self.loading = nil
            guard self.onScreen && self.contentVisible else { return }
            guard let url else { self.failed.isHidden = false; return }
            self.failed.isHidden = true
            let dark = self.effectiveAppearance.isDark
            let themed = URL(string: url.absoluteString.split(separator: "#", maxSplits: 1)[0] + HtmlRenderTheme(dark: dark).fragment) ?? url
            self.frameView.activate(.init(src: themed, title: page.title, dark: dark))
        }
    }

    private func received(_ data: JSONValue) {
        if let h = HtmlRenderTheme.contentHeight(data), contentHeights.set(h, width: Double(frameView.frame.width)) {
            onHeightChange?()
        }
        HtmlRenderRowView.handle(data, frame: frameView, model: nil)
    }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); syncContent() }
    override func viewDidHide() { super.viewDidHide(); syncContent() }
    override func viewDidUnhide() { super.viewDidUnhide(); syncContent() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if frameView.isLive {
            frameView.dark = effectiveAppearance.isDark
            frameView.post(HtmlRenderTheme(dark: frameView.dark).message)
            frameView.refreshPreview()
        }
    }

    override func layout() {
        super.layout()
        frameView.frame = bounds
        failed.frame = NSRect(x: 0, y: bounds.midY - 8, width: bounds.width, height: 16)
    }
}

/// An image you sent, on the right with rounded corners like a photo in Messages. It keeps a square until its
/// thumbnail arrives, then takes the image's shape.
final class OrchestratorImageBubble: DSView {
    let attachmentId: String
    private let image = CALayer()
    private var aspect: CGFloat?
    private var load: Task<Void, Never>?
    var onLoaded: (() -> Void)?

    init(attachmentId: String, name: String) {
        self.attachmentId = attachmentId
        super.init(frame: .zero)
        image.masksToBounds = true
        image.cornerRadius = 16
        image.contentsGravity = .resizeAspectFill
        image.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(image)
        setAccessibilityRole(.image)
        setAccessibilityLabel(name)
    }

    isolated deinit { load?.cancel() }

    func load(_ loader: ((String, Int) async -> CGImage?)?) {
        guard let loader else { return }
        let id = attachmentId
        load = Task { [weak self] in
            guard let cg = await loader(id, 480), !Task.isCancelled, let self else { return }
            self.image.contents = cg
            self.aspect = CGFloat(cg.width) / max(1, CGFloat(cg.height))
            self.onLoaded?()
        }
    }

    func size(maxSide: CGFloat) -> NSSize {
        guard let aspect else { return NSSize(width: maxSide * 0.75, height: maxSide * 0.75) }
        return aspect >= 1 ? NSSize(width: maxSide, height: (maxSide / aspect).rounded())
            : NSSize(width: (maxSide * aspect).rounded(), height: maxSide)
    }

    override func layout() { super.layout(); image.frame = bounds }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = 16
        layer?.backgroundColor = image.contents == nil ? Themed.color(\.secondary).cgColor(in: self) : nil
    }
}

/// A small centred line: a time, an event or the tools a turn used. One naming a thread opens it.
final class OrchestratorCenteredLine: ControlView {
    private let label = TextBlockView()
    let threadId: String?
    var onOpen: ((String) -> Void)?

    init(_ text: String, threadId: String?, weight: NSFont.Weight) {
        self.threadId = threadId
        super.init(frame: .zero)
        label.text = text
        label.font = DSFont.ui(11, weight: weight)
        label.lineHeight = 15
        label.alignment = .center
        label.color = Themed.color(\.mutedForeground)
        addSubview(label)
        action = { [weak self] in if let id = self?.threadId { self?.onOpen?(id) } }
        setAccessibilityLabel(text)
    }

    func height(forWidth width: CGFloat) -> CGFloat { label.height(forWidth: width - 40) }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 20, y: 0, width: bounds.width - 40, height: bounds.height)
    }

    override func stateDidChange(from old: State) {
        super.stateDidChange(from: old)
        label.color = threadId != nil && state.hoverOrPressed ? Themed.color(\.foreground) : Themed.color(\.mutedForeground)
    }
}

/// The brief, collapsed to a card; a click shows the whole text.
final class OrchestratorBriefCard: ControlView, SettingsGroupRow {
    private let title = LabelView("", font: DSFont.ui(12, weight: .semibold), color: Themed.color(\.foreground))
    private let hint = LabelView("", font: DSFont.ui(11), color: Themed.color(\.mutedForeground))
    private let body = TextBlockView()
    private let chevron = IconView(name: .chevronDown, size: 14)
    private var expanded = false
    var onToggle: (() -> Void)?

    init(text: String, updated: Bool) {
        super.init(frame: .zero)
        title.text = updated ? "Updated brief" : "Brief"
        title.lineHeight = 16
        hint.text = "\(text.split(separator: "\n").count) lines · click to read"
        hint.lineHeight = 14
        body.text = text
        body.font = DSFont.ui(12)
        body.lineHeight = 17
        body.color = Themed.color(\.mutedForeground)
        body.isHidden = true
        for v in [title, hint, body, chevron] as [NSView] { addSubview(v) }
        action = { [weak self] in
            guard let self else { return }
            self.expanded.toggle()
            self.body.isHidden = !self.expanded
            self.hint.text = self.expanded ? "click to fold" : "\(text.split(separator: "\n").count) lines · click to read"
            self.onToggle?()
        }
        setAccessibilityLabel(title.text)
    }

    func height(forWidth width: CGFloat) -> CGFloat { 44 + (expanded ? body.height(forWidth: width - 28) + 8 : 0) }

    override func layout() {
        super.layout()
        title.frame = NSRect(x: 14, y: 7, width: bounds.width - 50, height: 16)
        hint.frame = NSRect(x: 14, y: 24, width: bounds.width - 50, height: 14)
        chevron.frame = NSRect(x: bounds.width - 28, y: 15, width: 14, height: 14)
        body.frame = NSRect(x: 14, y: 44, width: bounds.width - 28, height: max(0, bounds.height - 52))
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        layer?.borderColor = Themed.color(\.border, 0.7).cgColor(in: self)
        layer?.backgroundColor = Themed.color(\.card, state.hoverOrPressed ? 0.9 : 0.6).cgColor(in: self)
        chevron.strokeColor = Themed.color(\.mutedForeground)
    }
}

/// The plan as a checklist; a step linked to a thread opens it.
final class OrchestratorPlanCard: DSView, SettingsGroupRow {
    private let title = LabelView("Plan", font: DSFont.ui(12, weight: .semibold), color: Themed.color(\.foreground))
    private var rows: [OrchestratorPlanStepRow] = []
    var onOpen: ((String) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.lineHeight = 16
        addSubview(title)
    }

    func set(_ steps: [OrchestratorReply.PlanStep], environmentId: String) {
        rows.forEach { $0.removeFromSuperview() }
        rows = steps.map { s in
            let r = OrchestratorPlanStepRow(s)
            r.onOpen = { [weak self] in if let t = s.threadId { self?.onOpen?(t) } }
            addSubview(r)
            return r
        }
        needsLayout = true
    }

    func height(forWidth width: CGFloat) -> CGFloat { 30 + rows.reduce(0) { $0 + $1.height(forWidth: width - 24) } + 8 }

    override func layout() {
        super.layout()
        title.frame = NSRect(x: 12, y: 8, width: bounds.width - 24, height: 16)
        var y: CGFloat = 30
        for r in rows {
            let h = r.height(forWidth: bounds.width - 24)
            r.frame = NSRect(x: 12, y: y, width: bounds.width - 24, height: h)
            y += h
        }
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = 14
        layer?.backgroundColor = Themed.color(\.secondary).cgColor(in: self)
    }
}

final class OrchestratorPlanStepRow: ControlView {
    private let label = TextBlockView()
    private let link = IconView(name: .arrowUpRight, size: 12)
    let step: OrchestratorReply.PlanStep
    var onOpen: (() -> Void)?

    init(_ step: OrchestratorReply.PlanStep) {
        self.step = step
        super.init(frame: .zero)
        let icon = IconView(name: step.done ? .circleCheck : .circle, size: 14)
        icon.strokeColor = step.done ? Themed.color(\.primary) : Themed.color(\.mutedForeground)
        addSubview(icon)
        markView = icon
        label.text = OrchestratorReply.displayText(step)
        label.font = DSFont.ui(13)
        label.lineHeight = 18
        label.color = step.done ? Themed.color(\.mutedForeground) : Themed.color(\.foreground)
        addSubview(label)
        link.strokeColor = Themed.color(\.mutedForeground)
        link.isHidden = step.threadId == nil
        addSubview(link)
        action = { [weak self] in self?.onOpen?() }
        isEnabled = step.threadId != nil
        setAccessibilityLabel("\(step.done ? "Done: " : "")\(label.text)")
    }
    private var markView: IconView?

    func height(forWidth width: CGFloat) -> CGFloat { max(22, label.height(forWidth: width - 22 - 18) + 4) }

    override func layout() {
        super.layout()
        markView?.frame = NSRect(x: 0, y: 3, width: 14, height: 14)
        label.frame = NSRect(x: 22, y: 1, width: bounds.width - 22 - 18, height: bounds.height - 2)
        link.frame = NSRect(x: bounds.width - 14, y: 4, width: 12, height: 12)
    }

    override func stateDidChange(from old: State) {
        super.stateDidChange(from: old)
        label.color = step.threadId != nil && state.hoverOrPressed ? Themed.color(\.primary) : step.done ? Themed.color(\.mutedForeground) : Themed.color(\.foreground)
    }
}

/// "Saved to memory: rules · Undo".
final class OrchestratorMemoryChip: DSView, SettingsGroupRow {
    private let icon = IconView(name: .brain, size: 13)
    private let label = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    private let undo = ButtonView("Undo", variant: .link, size: .xs)
    var onUndo: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.lineHeight = 16
        for v in [icon, label, undo] as [NSView] { addSubview(v) }
        undo.action = { [weak self] in self?.onUndo?() }
    }

    func set(notes: [String], canUndo: Bool, undone: Bool) {
        label.text = undone ? "Memory change undone" : "Saved to memory: \(notes.joined(separator: ", "))"
        undo.isHidden = !canUndo || undone
        needsLayout = true
    }

    var preferredWidth: CGFloat { 12 + 13 + 6 + ceil(label.textWidth) + (undo.isHidden ? 0 : 8 + undo.intrinsicContentSize.width) + 12 }
    func height(forWidth width: CGFloat) -> CGFloat { 26 }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 12, y: 6.5, width: 13, height: 13)
        let lw = ceil(label.textWidth) + 1
        label.frame = NSRect(x: 31, y: 5, width: min(lw, bounds.width - 31), height: 16)
        let uw = undo.intrinsicContentSize.width
        undo.frame = NSRect(x: label.frame.maxX + 8, y: 3, width: uw, height: 20)
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = 13
        layer?.backgroundColor = Themed.color(\.secondary, 0.7).cgColor(in: self)
        icon.strokeColor = Themed.color(\.mutedForeground)
    }
}

final class OrchestratorReadLabel: DSView {
    private let label = LabelView("Read", font: DSFont.ui(11, weight: .medium), color: Themed.color(\.mutedForeground))
    override init(frame: NSRect) {
        super.init(frame: frame)
        label.alignment = .right
        label.lineHeight = 14
        addSubview(label)
    }
    override func layout() { super.layout(); label.frame = bounds }
}

/// Three dots in a grey bubble while the Orchestrator's turn runs. Core Animation fades them in turn, only while it
/// shows in a visible window, at the loop frame rate; Reduce Motion holds them still.
final class OrchestratorTypingBubble: DSView {
    static let size = NSSize(width: 56, height: 32)
    private let dots = (0..<3).map { _ in CALayer() }

    override init(frame: NSRect) {
        super.init(frame: frame)
        for (i, d) in dots.enumerated() {
            d.actions = ["position": NSNull(), "bounds": NSNull(), "backgroundColor": NSNull()]
            d.frame = CGRect(x: 14 + CGFloat(i) * 11, y: 13, width: 7, height: 7)
            d.cornerRadius = 3.5
            layer?.addSublayer(d)
        }
        setAccessibilityLabel("Orchestrator is typing")
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = 16
        layer?.backgroundColor = Themed.color(\.secondary).cgColor(in: self)
        for d in dots { d.backgroundColor = Themed.color(\.mutedForeground).cgColor(in: self) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for (i, d) in dots.enumerated() {
            d.removeAllAnimations()
            guard window != nil, !Motion.reduced else { d.opacity = 0.6; continue }
            let a = CAKeyframeAnimation(keyPath: "opacity")
            a.values = [0.35, 1, 0.35]
            a.keyTimes = [0, 0.5, 1]
            a.duration = 1.2
            a.beginTime = CACurrentMediaTime() + Double(i) * 0.2
            a.repeatCount = .infinity
            a.preferredFrameRateRange = Motion.loopFrameRate
            d.add(a, forKey: "typing")
        }
    }
}

// MARK: - Needs you

/// Every thread's approvals and questions, newest first: Allow and Deny answer an approval through T3's own path,
/// and a question opens its thread. The Orchestrator never approves.
final class OrchestratorNeedsCard: DSView, SettingsGroupRow {
    private let title = LabelView("Needs you", font: DSFont.ui(12, weight: .semibold), color: Themed.color(\.foreground))
    private var rows: [OrchestratorNeedRow] = []
    var onRespond: ((OrchestratorNeed, ApprovalDecision) -> Void)?
    var onOpen: ((OrchestratorNeed) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.lineHeight = 16
        addSubview(title)
    }

    func set(_ needs: [OrchestratorNeed], limit: Int) {
        rows.forEach { $0.removeFromSuperview() }
        rows = needs.prefix(limit).map { n in
            let r = OrchestratorNeedRow(n)
            r.onRespond = { [weak self] d in self?.onRespond?(n, d) }
            r.onOpen = { [weak self] in self?.onOpen?(n) }
            addSubview(r)
            return r
        }
        title.text = needs.count > limit ? "Needs you · \(limit) of \(needs.count)" : "Needs you"
        needsLayout = true
    }

    func height(forWidth width: CGFloat) -> CGFloat { 32 + CGFloat(rows.count) * OrchestratorNeedRow.height + 6 }

    override func layout() {
        super.layout()
        title.frame = NSRect(x: 12, y: 9, width: bounds.width - 24, height: 16)
        for (i, r) in rows.enumerated() { r.frame = NSRect(x: 0, y: 32 + CGFloat(i) * OrchestratorNeedRow.height, width: bounds.width, height: OrchestratorNeedRow.height) }
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = 14
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(srgbRed: 1, green: 0.72, blue: 0.16, alpha: 0.55).cgColor
        layer?.backgroundColor = Themed.color(\.secondary).cgColor(in: self)
    }
}

final class OrchestratorNeedRow: DSView {
    static let height: CGFloat = 48
    private let icon: IconView
    private let thread = LabelView("", font: DSFont.ui(13, weight: .medium), color: Themed.color(\.foreground))
    private let kind = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    private let deny = ButtonView("Deny", variant: .outline, size: .xs)
    private let allow = ButtonView("Allow", size: .xs)
    private let open = ButtonView("Open", variant: .outline, size: .xs)
    var onRespond: ((ApprovalDecision) -> Void)?
    var onOpen: (() -> Void)?

    init(_ need: OrchestratorNeed) {
        // The sidebar's own Approval and Input marks; threads never get a bot.
        let status: SidebarTopStatus = need.isApproval ? .approval : .input
        icon = IconView(name: SB.statusIcon(status) ?? .circleAlert, size: 16)
        icon.strokeColor = SB.status(status)
        super.init(frame: .zero)
        thread.text = need.threadTitle
        thread.lineHeight = 18
        kind.text = need.label
        kind.lineHeight = 16
        for v in [icon, thread, kind, deny, allow, open] as [NSView] { addSubview(v) }
        deny.isHidden = !need.isApproval
        allow.isHidden = !need.isApproval
        deny.action = { [weak self] in self?.answered(.decline) }
        allow.action = { [weak self] in self?.answered(.accept) }
        open.action = { [weak self] in self?.onOpen?() }
        setAccessibilityLabel("\(need.threadTitle), \(need.label)")
    }

    private func answered(_ d: ApprovalDecision) {
        allow.isEnabled = false
        deny.isEnabled = false
        onRespond?(d)
    }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 15, y: 16, width: 16, height: 16)
        var right = bounds.width - 12
        for b in [allow, deny, open] where !b.isHidden {
            let w = b.intrinsicContentSize.width
            b.frame = NSRect(x: right - w, y: 13, width: w, height: 22)
            right -= w + 6
        }
        thread.frame = NSRect(x: 44, y: 6, width: max(0, right - 50), height: 18)
        kind.frame = NSRect(x: 44, y: 25, width: max(0, right - 50), height: 16)
    }
}

// MARK: - Overview

/// The top five things that need you, then a live card per thread on the machine.
final class OrchestratorOverviewView: DSView {
    var onOpenThread: ((ThreadId) -> Void)?
    var onRespond: ((OrchestratorNeed, ApprovalDecision) -> Void)?
    private let needsTitle = LabelView("Needs you", font: DSFont.ui(15, weight: .semibold), color: Themed.color(\.foreground))
    private let empty = LabelView("Nothing needs you.", font: DSFont.ui(13), color: Themed.color(\.mutedForeground))
    private let needsCard = OrchestratorNeedsCard()
    private var hasNeeds = false
    /// Running, Finished and, when it has threads, Stopped: a title, then a grid of cards or a quiet "None".
    private var sections: [(group: OrchestratorCrewCard.Group, title: LabelView, none: LabelView, cards: [OrchestratorCrewCardView])] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        for v in [needsTitle, empty, needsCard] as [NSView] { addSubview(v) }
        needsCard.onRespond = { [weak self] n, d in self?.onRespond?(n, d) }
        needsCard.onOpen = { [weak self] n in self?.onOpenThread?(n.threadId) }
    }

    static func title(_ group: OrchestratorCrewCard.Group) -> String {
        switch group {
        case .running: "Running"
        case .finished: "Finished"
        case .stopped: "Stopped"
        }
    }

    func set(crew: [OrchestratorCrewCard], needs: [OrchestratorNeed]) {
        hasNeeds = !needs.isEmpty
        needsCard.set(needs, limit: 5)
        needsCard.isHidden = needs.isEmpty
        empty.isHidden = !needs.isEmpty
        for s in sections { s.title.removeFromSuperview(); s.none.removeFromSuperview(); s.cards.forEach { $0.removeFromSuperview() } }
        sections = [OrchestratorCrewCard.Group.running, .finished, .stopped].compactMap { group in
            let members = crew.filter { $0.group == group }
            // Stopped shows only when something stopped.
            if group == .stopped, members.isEmpty { return nil }
            let title = LabelView(members.isEmpty ? Self.title(group) : "\(Self.title(group)) · \(members.count)",
                                  font: DSFont.ui(15, weight: .semibold), color: Themed.color(\.foreground))
            let none = LabelView(group == .running ? "Nothing is running." : "Nothing has finished yet.",
                                 font: DSFont.ui(13), color: Themed.color(\.mutedForeground))
            none.isHidden = !members.isEmpty
            addSubview(title)
            addSubview(none)
            let cards = members.map { c in
                let v = OrchestratorCrewCardView(c)
                v.action = { [weak self] in self?.onOpenThread?(c.id) }
                addSubview(v)
                return v
            }
            return (group, title, none, cards)
        }
        needsLayout = true
    }

    private func grid(_ width: CGFloat) -> (lane: CGFloat, x0: CGFloat, columns: Int, cardW: CGFloat) {
        let lane = min(width - 40, 980), x0 = (width - lane) / 2
        let columns = max(1, Int((lane + 12) / (240 + 12)))
        return (lane, x0, columns, (lane - CGFloat(columns - 1) * 12) / CGFloat(columns))
    }

    private func sectionHeight(_ count: Int, columns: Int) -> CGFloat {
        let rows = (count + columns - 1) / columns
        return 34 + (count == 0 ? 20 : CGFloat(rows) * (OrchestratorCrewCardView.height + 12) - 12)
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        let g = grid(width)
        let needsH = hasNeeds ? needsCard.height(forWidth: g.lane) : 20
        return 24 + 34 + needsH + sections.reduce(0) { $0 + 28 + sectionHeight($1.cards.count, columns: g.columns) } + 24
    }

    override func layout() {
        super.layout()
        let g = grid(bounds.width)
        var y: CGFloat = 24
        needsTitle.frame = NSRect(x: g.x0, y: y, width: g.lane, height: 24)
        y += 34
        empty.frame = NSRect(x: g.x0, y: y, width: g.lane, height: 20)
        let needsH = hasNeeds ? needsCard.height(forWidth: g.lane) : 20
        needsCard.frame = NSRect(x: g.x0, y: y, width: g.lane, height: needsH)
        y += needsH
        for s in sections {
            y += 28
            s.title.frame = NSRect(x: g.x0, y: y, width: g.lane, height: 24)
            s.none.frame = NSRect(x: g.x0, y: y + 34, width: g.lane, height: 20)
            for (i, c) in s.cards.enumerated() {
                let col = i % g.columns, row = i / g.columns
                c.frame = NSRect(x: g.x0 + CGFloat(col) * (g.cardW + 12), y: y + 34 + CGFloat(row) * (OrchestratorCrewCardView.height + 12),
                                 width: g.cardW, height: OrchestratorCrewCardView.height)
            }
            y += sectionHeight(s.cards.count, columns: g.columns)
        }
    }
}

final class OrchestratorCrewCardView: ControlView {
    static let height: CGFloat = 104
    private let icon: IconView?
    private let title = LabelView("", font: DSFont.ui(13, weight: .medium), color: Themed.color(\.foreground))
    private let meta = LabelView("", font: DSFont.ui(11), color: Themed.color(\.mutedForeground))
    private let last = TextBlockView()
    private let note = LabelView("", font: DSFont.ui(11, weight: .medium), color: Themed.color(\.warning))

    init(_ card: OrchestratorCrewCard) {
        // The sidebar's own status mark; threads never get a bot.
        icon = card.status.flatMap { s in SB.statusIcon(s).map { IconView(name: $0, size: 16) } }
        icon?.strokeColor = card.status.map { SB.status($0) } ?? Themed.color(\.mutedForeground)
        super.init(frame: .zero)
        title.text = card.title
        title.lineHeight = 18
        meta.text = [card.project, card.state].filter { !$0.isEmpty }.joined(separator: " · ")
        meta.lineHeight = 14
        last.text = card.lastLine ?? ""
        last.font = DSFont.ui(12)
        last.lineHeight = 16
        last.color = Themed.color(\.mutedForeground, 0.9)
        last.maxLines = 2
        note.text = card.note ?? ""
        note.lineHeight = 14
        for v in [title, meta, last, note] as [NSView] { addSubview(v) }
        icon.map(addSubview)
        setAccessibilityLabel("\(card.title), \(card.state)")
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let x: CGFloat = icon == nil ? 12 : 36
        icon?.frame = NSRect(x: 12, y: 13, width: 16, height: 16)
        title.frame = NSRect(x: x, y: 12, width: w - x - 12, height: 18)
        meta.frame = NSRect(x: x, y: 31, width: w - x - 12, height: 14)
        last.frame = NSRect(x: 12, y: 52, width: w - 24, height: 32)
        note.frame = NSRect(x: 12, y: 84, width: w - 24, height: 14)
    }

    override func stateDidChange(from old: State) { super.stateDidChange(from: old); needsDisplay = true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = 14
        layer?.borderWidth = 1
        layer?.borderColor = Themed.color(\.border, 0.6).cgColor(in: self)
        layer?.backgroundColor = Themed.color(\.card, state.hoverOrPressed ? 0.95 : 0.7).cgColor(in: self)
    }
}

// MARK: - Composer

/// A rounded field with a round send button. Return sends; Shift-Return adds a line.
final class OrchestratorComposerView: DSView {
    private let field = TextareaView(placeholder: "Message the Orchestrator")
    private let send = ButtonView(icon: .arrowUp, size: .iconSm)
    private let attach = ButtonView(icon: .plus, variant: .ghost, size: .iconSm)
    private var thumbs: [OrchestratorAttachmentThumb] = []
    /// Your message and the ready images' ids.
    var onSend: ((String) -> Void)?
    /// Every edit, for the draft to persist.
    var onDraftChange: ((String) -> Void)?
    /// Images from the + button, a paste or a drop.
    var onImages: (([ComposerIncomingFile]) -> Void)?
    var onRemoveImage: ((String) -> Void)?
    /// Where a pasted image's bytes are written before they upload.
    var pasteDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("CandyWrapperAttachments", isDirectory: true)
    var isEnabled = true { didSet { field.isEnabled = isEnabled; attach.isEnabled = isEnabled; refreshSend() } }
    var placeholder: String {
        get { field.placeholder }
        set { field.placeholder = newValue; field.setAccessibilityLabel(newValue) }
    }
    /// The images waiting to go with the next message.
    var attachments: [ComposerAttachment] = [] {
        didSet {
            guard attachments != oldValue else { return }
            syncThumbs()
            refreshSend()
            superview?.needsLayout = true
        }
    }

    /// While a question is open: edits go to its free-text answer and Return or Send advance it. Nil is a message.
    var answering: (text: (String) -> Void, advance: () -> Void)? { didSet { refreshSend() } }
    /// A choice-only question locks the field.
    var answerEditable = true { didSet { field.isEnabled = isEnabled && (answering == nil || answerEditable) } }

    /// Replaces the field's text, typed or not, without reporting it as a draft.
    func setText(_ text: String) {
        guard field.text != text else { return }
        suppressReport = true
        field.text = text
        suppressReport = false
        refreshSend()
        superview?.needsLayout = true
    }
    private var suppressReport = false

    /// The text in the field. Setting it leaves alone a field you're typing in.
    var draft: String {
        get { field.text }
        set {
            guard field.text != newValue, !field.state.focused || field.text.isEmpty else { return }
            field.text = newValue
            refreshSend()
            superview?.needsLayout = true
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        field.bare = true
        // One line tall until you write more, so the round send button sits centred beside it.
        field.bareMinHeight = 32
        field.setAccessibilityLabel("Message the Orchestrator")
        addSubview(field)
        addSubview(send)
        addSubview(attach)
        send.setAccessibilityLabel("Send")
        send.action = { [weak self] in self?.submit() }
        attach.setAccessibilityLabel("Attach images")
        attach.toolTip = "Attach images"
        attach.action = { [weak self] in self?.chooseImages() }
        field.onChange = { [weak self] text in
            guard let self else { return }
            self.refreshSend()
            if !self.suppressReport {
                if let answering = self.answering { answering.text(text) } else { self.onDraftChange?(text) }
            }
            self.superview?.needsLayout = true
        }
        field.onCommand = { [weak self] sel in
            guard sel == #selector(NSResponder.insertNewline(_:)), !(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false),
                  !(self?.field.hasMarkedText ?? true) else { return false }
            self?.submit()
            return true
        }
        // A pasted image or image file attaches, as in the thread composer; text pastes as text.
        field.onPaste = { [weak self] pboard in
            guard let self, let onImages = self.onImages else { return false }
            let images = ComposerPasteboard.files(pboard, tempDir: self.pasteDirectory).filter(Self.isImage)
            guard !images.isEmpty else { return false }
            onImages(images)
            return true
        }
        registerForDraggedTypes([.fileURL])
        refreshSend()
    }

    static func isImage(_ file: ComposerIncomingFile) -> Bool {
        if case .file = ComposerAttachmentRules.classify(name: file.name, mimeType: file.mimeType) { return false }
        return true
    }

    private var uploading: Bool { attachments.contains { if case .uploading = $0.status { true } else { false } } }
    private var hasContent: Bool {
        !field.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachments.contains { $0.status == .ready }
    }

    private func refreshSend() { send.isEnabled = isEnabled && (answering != nil || hasContent && !uploading) }

    func focus() { window?.makeFirstResponder(field) }

    func submit() {
        if let answering { answering.advance(); return }
        let text = field.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isEnabled, hasContent, !uploading else { return }
        field.text = ""
        onDraftChange?("")
        refreshSend()
        onSend?(text)
        superview?.needsLayout = true
    }

    private func chooseImages() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            MainActor.assumeIsolated { self?.onImages?(panel.urls.map { ComposerIncomingFile(url: $0) }) }
        }
    }

    private func syncThumbs() {
        let ids = attachments.map(\.id)
        thumbs.removeAll { t in
            if ids.contains(t.attachmentId) { return false }
            t.removeFromSuperview()
            return true
        }
        for a in attachments {
            if let t = thumbs.first(where: { $0.attachmentId == a.id }) { t.attachment = a; continue }
            let t = OrchestratorAttachmentThumb(a)
            t.onRemove = { [weak self] in self?.onRemoveImage?(a.id) }
            addSubview(t)
            thumbs.append(t)
        }
        thumbs.sort { a, b in (ids.firstIndex(of: a.attachmentId) ?? 0) < (ids.firstIndex(of: b.attachmentId) ?? 0) }
        needsLayout = true
    }

    // MARK: Drop

    private static func droppedImages(_ info: any NSDraggingInfo) -> [ComposerIncomingFile] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.map { ComposerIncomingFile(url: $0) }.filter(isImage)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        isEnabled && onImages != nil && !Self.droppedImages(sender).isEmpty ? .copy : []
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let images = Self.droppedImages(sender)
        guard !images.isEmpty else { return false }
        onImages?(images)
        return true
    }

    // MARK: Layout

    static let minHeight: CGFloat = 40
    static let thumbSide: CGFloat = 56
    private var shelfHeight: CGFloat { attachments.isEmpty ? 0 : Self.thumbSide + 10 }

    func height(forWidth width: CGFloat) -> CGFloat {
        field.setFrameSize(NSSize(width: width - 40 - 44, height: field.frame.height))
        return max(Self.minHeight, min(200, field.intrinsicContentSize.height) + 8) + shelfHeight
    }

    override func layout() {
        super.layout()
        let shelf = shelfHeight
        for (i, t) in thumbs.enumerated() {
            t.frame = NSRect(x: 12 + CGFloat(i) * (Self.thumbSide + 8), y: 10, width: Self.thumbSide, height: Self.thumbSide)
        }
        let rowHeight = bounds.height - shelf
        let fh = min(200, field.intrinsicContentSize.height)
        field.frame = NSRect(x: 40, y: shelf + (rowHeight - fh) / 2, width: bounds.width - 40 - 44, height: fh)
        // Centred in a one-line field; with more lines both buttons stay level with the last one, as in Messages.
        let buttonY = bounds.height - (Self.minHeight + 28) / 2
        attach.frame = NSRect(x: 6, y: buttonY, width: 28, height: 28)
        send.frame = NSRect(x: bounds.width - 6 - 28, y: buttonY, width: 28, height: 28)
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = 20
        layer?.borderWidth = 1
        layer?.borderColor = Themed.color(\.border).cgColor(in: self)
        layer?.backgroundColor = Themed.color(\.card, 0.85).cgColor(in: self)
        send.layer?.cornerRadius = 14
        attach.layer?.cornerRadius = 14
    }
}

/// A waiting image in the composer: its thumbnail, a spinner while it uploads, a mark if it failed, and a remove button.
final class OrchestratorAttachmentThumb: DSView {
    let attachmentId: String
    private let image = CALayer()
    private let remove = ButtonView(icon: .x, variant: .secondary, size: .iconXs)
    private let spinner = SpinnerView(size: .sm)
    private let failed = IconView(name: .circleAlert, size: 16)
    var onRemove: (() -> Void)?
    var attachment: ComposerAttachment { didSet { refresh() } }
    private var load: Task<Void, Never>?

    init(_ attachment: ComposerAttachment) {
        attachmentId = attachment.id
        self.attachment = attachment
        super.init(frame: .zero)
        image.masksToBounds = true
        image.cornerRadius = 10
        image.contentsGravity = .resizeAspectFill
        image.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(image)
        for v in [spinner, failed, remove] as [NSView] { addSubview(v) }
        remove.setAccessibilityLabel("Remove \(attachment.name)")
        remove.action = { [weak self] in self?.onRemove?() }
        failed.strokeColor = Themed.color(\.destructive)
        setAccessibilityLabel(attachment.name)
        let url = attachment.fileURL
        load = Task { [weak self] in
            let cg = await ComposerImageIO.thumbnail(url, side: 112, cover: true)
            guard !Task.isCancelled else { return }
            self?.image.contents = cg
        }
        refresh()
    }

    isolated deinit { load?.cancel() }

    private func refresh() {
        let uploading: Bool = if case .uploading = attachment.status { true } else { false }
        let didFail: Bool = if case .failed = attachment.status { true } else { false }
        spinner.isHidden = !uploading
        failed.isHidden = !didFail
        failed.toolTip = if case .failed(let why) = attachment.status { why } else { nil }
        image.opacity = uploading || didFail ? 0.55 : 1
    }

    override func layout() {
        super.layout()
        image.frame = bounds
        remove.frame = NSRect(x: bounds.width - 18, y: -4, width: 22, height: 22)
        spinner.frame = NSRect(x: (bounds.width - 16) / 2, y: (bounds.height - 16) / 2, width: 16, height: 16)
        failed.frame = spinner.frame
    }
}
