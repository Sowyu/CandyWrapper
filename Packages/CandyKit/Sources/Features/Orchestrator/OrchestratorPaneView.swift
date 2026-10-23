import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// A thread under the Orchestrator, as an Overview card. Built from server events only, so it costs no tokens.
public struct OrchestratorCrewCard: Equatable {
    public var id: ThreadId
    public var title: String
    public var project: String
    public var state: String
    public var mood: BotMood
    public var bot: BotIdentity
    public var lastLine: String?
    /// "Hands off", or "You wrote 3 min ago, it asks first".
    public var note: String?
    public init(id: ThreadId, title: String, project: String, state: String, mood: BotMood, bot: BotIdentity, lastLine: String?, note: String?) {
        self.id = id; self.title = title; self.project = project; self.state = state; self.mood = mood; self.bot = bot
        self.lastLine = lastLine; self.note = note
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
    public var bot: BotIdentity
    public init(threadId: ThreadId, threadTitle: String, requestId: String, label: String, isApproval: Bool, bot: BotIdentity) {
        self.threadId = threadId; self.threadTitle = threadTitle; self.requestId = requestId; self.label = label
        self.isApproval = isApproval; self.bot = bot
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
    /// Replies whose saved notes can still be undone, and those already undone.
    public var undoable: Set<String> = []
    public var undone: Set<String> = []
    public var crew: [OrchestratorCrewCard] = []
    public var needs: [OrchestratorNeed] = []
    public var working = false
    public init() {}
}

/// The Orchestrator's pane (docs/orchestrator.md, "More than a thread"): its chat, drawn like iMessage, and the
/// Overview of what needs you and every thread on its machine. The Digest tab waits for phase 3.
public final class OrchestratorPaneView: DSView {
    public var onSend: ((String) -> Void)?
    /// A thread by its scoped id.
    public var onOpenThread: ((ThreadId) -> Void)?
    public var onRespond: ((OrchestratorNeed, ApprovalDecision) -> Void)?
    public var onUndoMemory: ((String) -> Void)?
    public var onStart: (() -> Void)?
    /// Opens the Orchestrator's thread in the normal thread view.
    public var onOpenAsThread: (() -> Void)?
    public var onEscape: (() -> Void)?

    private let headerBot = BotView(identity: .orchestrator, size: 30)
    private let title = LabelView("", font: DSFont.ui(15, weight: .semibold), color: Themed.color(\.foreground))
    private let subtitle = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    private let tabs = ToggleGroupView(variant: .segmented, items: [("Chat", nil), ("Overview", nil)], selected: 0)
    private let openThread = ButtonView("Open as thread", icon: .arrowUpRight, variant: .ghost, size: .sm)
    private let chat = OrchestratorChatView()
    private lazy var chatScroll = ScrollAreaView(documentView: chat, scrollFade: true)
    private let overview = OrchestratorOverviewView()
    private lazy var overviewScroll = ScrollAreaView(documentView: overview, scrollFade: true)
    private let composer = OrchestratorComposerView()
    private let start = ButtonView("Start the Orchestrator", size: .default)
    private let divider = CALayer()
    public private(set) var state = OrchestratorPaneState()
    private var showsOverview = false

    public override init(frame: NSRect) {
        super.init(frame: frame)
        for v in [headerBot, title, subtitle, tabs, openThread, chatScroll, overviewScroll, composer, start] as [NSView] { addSubview(v) }
        divider.actions = ["position": NSNull(), "bounds": NSNull(), "backgroundColor": NSNull()]
        layer?.addSublayer(divider)
        for s in [chatScroll, overviewScroll] {
            s.scrollView.automaticallyAdjustsContentInsets = false
            s.scrollView.contentInsets = NSEdgeInsets()
        }
        overviewScroll.isHidden = true
        tabs.setAccessibilityLabel("Orchestrator view")
        tabs.onChange = { [weak self, weak tabs] i in
            guard let self else { return }
            guard let i else { tabs?.selectedIndex = self.showsOverview ? 1 : 0; return }
            self.showsOverview = i == 1
            self.chatScroll.isHidden = self.showsOverview
            self.overviewScroll.isHidden = !self.showsOverview
            self.needsLayout = true
        }
        openThread.action = { [weak self] in self?.onOpenAsThread?() }
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
        title.text = "\(next.name) · \(next.machine)"
        subtitle.text = !next.started ? "Not started" : !next.connected ? "Offline" : next.working ? "Working"
            : next.needs.isEmpty ? "Watching every thread on \(next.machine)" : "\(next.needs.count) waiting on you"
        openThread.isHidden = !next.started
        start.isHidden = next.started
        composer.isHidden = !next.started
        composer.isEnabled = next.connected
        if old.items != next.items || old.undoable != next.undoable || old.undone != next.undone || old.needs != next.needs
            || old.environmentId != next.environmentId {
            chat.set(items: next.items, needs: next.needs, undoable: next.undoable, undone: next.undone, environmentId: next.environmentId)
        }
        if old.crew != next.crew || old.needs != next.needs { overview.set(crew: next.crew, needs: next.needs) }
        needsLayout = true
    }

    public func focusComposer() { composer.focus() }

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
        let w = chatScroll.bounds.width
        let h = max(chat.height(forWidth: w), chatScroll.bounds.height)
        let clip = chatScroll.scrollView.contentView.bounds
        pinnedToBottom = clip.maxY >= chat.frame.height - 40 || chat.frame.height <= clip.height
        chat.frame = NSRect(x: 0, y: 0, width: w, height: h)
    }

    public override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        let top: CGFloat = 52
        headerBot.frame = NSRect(x: 20, y: top + 6, width: 30, height: 30)
        let tw = tabs.intrinsicContentSize.width
        tabs.frame = NSRect(x: (w - tw) / 2, y: top + 8, width: tw, height: 28)
        let ow = openThread.intrinsicContentSize.width
        openThread.frame = NSRect(x: w - 16 - ow, y: top + 8, width: ow, height: 28)
        let textRight = min(tabs.frame.minX - 12, openThread.frame.minX - 12)
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
        let sw = start.intrinsicContentSize.width
        start.frame = NSRect(x: (w - sw) / 2, y: h - 56, width: sw, height: 36)
        layoutChat()
        if pinnedToBottom { scrollToBottom() }
        overview.frame = NSRect(x: 0, y: 0, width: w, height: max(overview.height(forWidth: w), overviewScroll.bounds.height))
    }

    public override func cancelOperation(_ sender: Any?) { onEscape?() }
}

// MARK: - Chat

/// The chat's document: items top to bottom, the Orchestrator's on the left with its bot under each stack, yours on
/// the right. Views are kept by item id, so streaming text only reflows the bubble that grew.
final class OrchestratorChatView: DSView {
    var onOpenThread: ((String) -> Void)?
    var onRespond: ((OrchestratorNeed, ApprovalDecision) -> Void)?
    var onUndo: ((String) -> Void)?
    var onHeightChange: (() -> Void)?
    private var items: [OrchestratorChatItem] = []
    private var views: [String: NSView] = [:]
    private var order: [String] = []
    private var needsCard: OrchestratorNeedsCard?
    private var needs: [OrchestratorNeed] = []
    private var avatars: [String: BotView] = [:]
    private var environmentId = ""
    static let maxBubble: CGFloat = 520

    func set(items: [OrchestratorChatItem], needs: [OrchestratorNeed], undoable: Set<String>, undone: Set<String>, environmentId: String) {
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
            let bot = avatars[id] ?? BotView(identity: .orchestrator, size: 26)
            if bot.superview !== self { addSubview(bot) }
            nextAvatars[id] = bot
        }
        for (id, b) in avatars where nextAvatars[id] == nil { b.removeFromSuperview() }
        avatars = nextAvatars
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

    func setAvatarIdentity(_ identity: BotIdentity) { avatars.values.forEach { $0.identity = identity } }

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
                out.append((b, NSRect(x: x, y: y, width: size.width, height: size.height)))
                if !user, last, let bot = avatars[id] { out.append((bot, NSRect(x: x0, y: y + size.height - 24, width: 26, height: 26))) }
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
    }
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
            let r = OrchestratorPlanStepRow(s, bot: s.threadId.map { BotIdentity.forThread(ThreadId($0).scoped(to: environmentId).rawValue) })
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
    private let mark = IconView(name: .circle, size: 14)
    private let label = TextBlockView()
    private let bot: BotView?
    let step: OrchestratorReply.PlanStep
    var onOpen: (() -> Void)?

    init(_ step: OrchestratorReply.PlanStep, bot identity: BotIdentity?) {
        self.step = step
        bot = identity.map { BotView(identity: $0, size: 16) }
        super.init(frame: .zero)
        mark.removeFromSuperview()
        let icon = IconView(name: step.done ? .circleCheck : .circle, size: 14)
        icon.strokeColor = step.done ? Themed.color(\.primary) : Themed.color(\.mutedForeground)
        addSubview(icon)
        markView = icon
        label.text = OrchestratorReply.displayText(step)
        label.font = DSFont.ui(13)
        label.lineHeight = 18
        label.color = step.done ? Themed.color(\.mutedForeground) : Themed.color(\.foreground)
        addSubview(label)
        bot.map(addSubview)
        action = { [weak self] in self?.onOpen?() }
        isEnabled = step.threadId != nil
        setAccessibilityLabel("\(step.done ? "Done: " : "")\(label.text)")
    }
    private var markView: IconView?

    func height(forWidth width: CGFloat) -> CGFloat { max(22, label.height(forWidth: width - 22 - (bot == nil ? 0 : 22)) + 4) }

    override func layout() {
        super.layout()
        markView?.frame = NSRect(x: 0, y: 3, width: 14, height: 14)
        let right: CGFloat = bot == nil ? 0 : 22
        label.frame = NSRect(x: 22, y: 1, width: bounds.width - 22 - right, height: bounds.height - 2)
        bot?.frame = NSRect(x: bounds.width - 18, y: 1, width: 16, height: 16)
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
    private let bot: BotView
    private let thread = LabelView("", font: DSFont.ui(13, weight: .medium), color: Themed.color(\.foreground))
    private let kind = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    private let deny = ButtonView("Deny", variant: .outline, size: .xs)
    private let allow = ButtonView("Allow", size: .xs)
    private let open = ButtonView("Open", variant: .outline, size: .xs)
    var onRespond: ((ApprovalDecision) -> Void)?
    var onOpen: (() -> Void)?

    init(_ need: OrchestratorNeed) {
        bot = BotView(identity: need.bot, size: 22)
        super.init(frame: .zero)
        bot.mood = .needsYou
        thread.text = need.threadTitle
        thread.lineHeight = 18
        kind.text = need.label
        kind.lineHeight = 16
        for v in [bot, thread, kind, deny, allow, open] as [NSView] { addSubview(v) }
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
        bot.frame = NSRect(x: 12, y: 13, width: 22, height: 22)
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
    private let crewTitle = LabelView("Threads", font: DSFont.ui(15, weight: .semibold), color: Themed.color(\.foreground))
    private let empty = LabelView("Nothing needs you.", font: DSFont.ui(13), color: Themed.color(\.mutedForeground))
    private let needsCard = OrchestratorNeedsCard()
    private var cards: [OrchestratorCrewCardView] = []
    private var hasNeeds = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        for v in [needsTitle, crewTitle, empty, needsCard] as [NSView] { addSubview(v) }
        needsCard.onRespond = { [weak self] n, d in self?.onRespond?(n, d) }
        needsCard.onOpen = { [weak self] n in self?.onOpenThread?(n.threadId) }
    }

    func set(crew: [OrchestratorCrewCard], needs: [OrchestratorNeed]) {
        hasNeeds = !needs.isEmpty
        needsCard.set(needs, limit: 5)
        needsCard.isHidden = needs.isEmpty
        empty.isHidden = !needs.isEmpty
        cards.forEach { $0.removeFromSuperview() }
        cards = crew.map { c in
            let v = OrchestratorCrewCardView(c)
            v.action = { [weak self] in self?.onOpenThread?(c.id) }
            addSubview(v)
            return v
        }
        crewTitle.text = crew.isEmpty ? "Threads · none yet" : "Threads · \(crew.count)"
        needsLayout = true
    }

    private func grid(_ width: CGFloat) -> (lane: CGFloat, x0: CGFloat, columns: Int, cardW: CGFloat) {
        let lane = min(width - 40, 980), x0 = (width - lane) / 2
        let columns = max(1, Int((lane + 12) / (240 + 12)))
        return (lane, x0, columns, (lane - CGFloat(columns - 1) * 12) / CGFloat(columns))
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        let g = grid(width)
        let needsH = hasNeeds ? needsCard.height(forWidth: g.lane) : 20
        let rows = (cards.count + g.columns - 1) / g.columns
        return 24 + 24 + 10 + needsH + 28 + 24 + 10 + CGFloat(rows) * (OrchestratorCrewCardView.height + 12) + 24
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
        y += needsH + 28
        crewTitle.frame = NSRect(x: g.x0, y: y, width: g.lane, height: 24)
        y += 34
        for (i, c) in cards.enumerated() {
            let col = i % g.columns, row = i / g.columns
            c.frame = NSRect(x: g.x0 + CGFloat(col) * (g.cardW + 12), y: y + CGFloat(row) * (OrchestratorCrewCardView.height + 12),
                             width: g.cardW, height: OrchestratorCrewCardView.height)
        }
    }
}

final class OrchestratorCrewCardView: ControlView {
    static let height: CGFloat = 104
    private let bot: BotView
    private let title = LabelView("", font: DSFont.ui(13, weight: .medium), color: Themed.color(\.foreground))
    private let meta = LabelView("", font: DSFont.ui(11), color: Themed.color(\.mutedForeground))
    private let last = TextBlockView()
    private let note = LabelView("", font: DSFont.ui(11, weight: .medium), color: Themed.color(\.warning))

    init(_ card: OrchestratorCrewCard) {
        bot = BotView(identity: card.bot, size: 32)
        super.init(frame: .zero)
        bot.mood = card.mood
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
        for v in [bot, title, meta, last, note] as [NSView] { addSubview(v) }
        setAccessibilityLabel("\(card.title), \(card.state)")
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        bot.frame = NSRect(x: 12, y: 12, width: 32, height: 32)
        title.frame = NSRect(x: 52, y: 12, width: w - 64, height: 18)
        meta.frame = NSRect(x: 52, y: 31, width: w - 64, height: 14)
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
    var onSend: ((String) -> Void)?
    var isEnabled = true { didSet { field.isEnabled = isEnabled; refreshSend() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        field.bare = true
        field.setAccessibilityLabel("Message the Orchestrator")
        addSubview(field)
        addSubview(send)
        send.setAccessibilityLabel("Send")
        send.action = { [weak self] in self?.submit() }
        field.onChange = { [weak self] _ in self?.refreshSend(); self?.superview?.needsLayout = true }
        field.onCommand = { [weak self] sel in
            guard sel == #selector(NSResponder.insertNewline(_:)), !(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false),
                  !(self?.field.hasMarkedText ?? true) else { return false }
            self?.submit()
            return true
        }
        refreshSend()
    }

    private func refreshSend() { send.isEnabled = isEnabled && !field.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func focus() { window?.makeFirstResponder(field) }

    private func submit() {
        let text = field.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isEnabled, !text.isEmpty else { return }
        field.text = ""
        refreshSend()
        onSend?(text)
        superview?.needsLayout = true
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        field.setFrameSize(NSSize(width: width - 16 - 40, height: field.frame.height))
        return max(40, min(200, field.intrinsicContentSize.height) + 8)
    }

    override func layout() {
        super.layout()
        let fh = min(200, field.intrinsicContentSize.height)
        field.frame = NSRect(x: 14, y: (bounds.height - fh) / 2, width: bounds.width - 14 - 44, height: fh)
        send.frame = NSRect(x: bounds.width - 6 - 28, y: bounds.height - 6 - 28, width: 28, height: 28)
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = 20
        layer?.borderWidth = 1
        layer?.borderColor = Themed.color(\.border).cgColor(in: self)
        layer?.backgroundColor = Themed.color(\.card, 0.85).cgColor(in: self)
        send.layer?.cornerRadius = 14
    }
}
