import AppKit
import DesignSystem
import T3Protocol

/// What the pinned Orchestrator row shows (docs/orchestrator.md, "The UI, like Grok Bot").
public struct OrchestratorSidebarInfo: Equatable {
    public var name: String
    public var machine: String
    public var bot: BotIdentity
    /// Approvals and questions waiting across its machine.
    public var needsYou: Int
    public var working: Bool
    /// Its thread exists on the machine.
    public var started: Bool
    /// Its pane is open.
    public var isOpen: Bool

    public init(name: String, machine: String, bot: BotIdentity, needsYou: Int, working: Bool, started: Bool, isOpen: Bool) {
        self.name = name; self.machine = machine; self.bot = bot; self.needsYou = needsYou
        self.working = working; self.started = started; self.isOpen = isOpen
    }
}

/// Redesign's pinned Orchestrator row above the threads: its bot, "Orchestrator · machine", and an amber count of
/// what needs you. Every thread on its machine sits under it in the list.
final class OrchestratorSidebarRowView: ControlView {
    static let height: CGFloat = 44
    private let bot: BotView
    private let title = LabelView("", font: SB.font(13, .medium), color: SB.c(\.foreground))
    private let detail = LabelView("", font: SB.font(11), color: SB.c(\.secondaryLabel))
    private let count = LabelView("", font: SB.font(11, .semibold), color: .black)
    private let countFill = CALayer()
    private let divider = CALayer()
    private(set) var info: OrchestratorSidebarInfo

    init(_ info: OrchestratorSidebarInfo) {
        self.info = info
        bot = BotView(identity: info.bot, size: 28)
        super.init(frame: .zero)
        title.lineHeight = 18
        detail.lineHeight = 14
        count.lineHeight = 14
        count.alignment = .center
        countFill.actions = ["bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull(), "hidden": NSNull()]
        divider.actions = countFill.actions
        layer?.addSublayer(countFill)
        layer?.addSublayer(divider)
        for v in [bot, title, detail, count] as [NSView] { addSubview(v) }
        setAccessibilityRole(.button)
        apply(info)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func apply(_ next: OrchestratorSidebarInfo) {
        info = next
        bot.identity = next.bot
        bot.mood = next.needsYou > 0 ? .needsYou : next.working ? .working : .idle
        title.text = "\(next.name) · \(next.machine)"
        detail.text = !next.started ? "Start it to manage every thread here"
            : next.needsYou > 0 ? (next.needsYou == 1 ? "1 thing needs you" : "\(next.needsYou) things need you")
            : next.working ? "Working" : "Every thread on \(next.machine)"
        count.text = next.needsYou > 9 ? "9+" : "\(next.needsYou)"
        count.isHidden = next.needsYou == 0
        countFill.isHidden = next.needsYou == 0
        setAccessibilityLabel("\(title.text), \(detail.text)")
        needsDisplay = true
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        bot.frame = NSRect(x: 6, y: (Self.height - 28) / 2 - 2, width: 28, height: 28)
        let cw: CGFloat = count.isHidden ? 0 : max(18, ceil(count.textWidth) + 10)
        let right = w - 8 - (cw > 0 ? cw + 6 : 0)
        title.frame = NSRect(x: 42, y: 4, width: max(0, right - 42), height: 18)
        detail.frame = NSRect(x: 42, y: 22, width: max(0, right - 42), height: 14)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        countFill.frame = CGRect(x: w - 8 - cw, y: (Self.height - 18) / 2 - 2, width: cw, height: 18)
        countFill.cornerRadius = 9
        divider.frame = CGRect(x: 8, y: bounds.height - 1, width: max(0, w - 16), height: 1)
        CATransaction.commit()
        count.frame = NSRect(x: countFill.frame.minX, y: countFill.frame.minY + 2, width: cw, height: 14)
    }

    override func stateDidChange(from old: State) {
        super.stateDidChange(from: old)
        needsDisplay = true
    }

    override func updateLayer() {
        layer?.cornerRadius = DitherChrome.controlRadius
        let fill = info.isOpen ? SB.c(\.sidebarRowActive) : state.hoverOrPressed ? SB.c(\.sidebarRowHover) : nil
        layer?.backgroundColor = fill?.cgColor(in: self)
        countFill.backgroundColor = NSColor(srgbRed: 1, green: 0.72, blue: 0.16, alpha: 1).cgColor
        divider.backgroundColor = SB.c(\.sidebarBorder).cgColor(in: self)
    }
}
