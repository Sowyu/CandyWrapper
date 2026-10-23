import AppKit
import DesignSystem
import T3Protocol

/// What the pinned Orchestrator row shows (docs/orchestrator.md, "The UI, like Grok Bot").
public struct OrchestratorSidebarInfo: Equatable {
    public var name: String
    /// The machine's label and its kind, as the composer's machine row shows them (`DitherDeviceRowView`).
    public var machine: String
    public var machineKind: String
    public var bot: BotIdentity
    /// Approvals and questions waiting across its machine.
    public var needsYou: Int
    public var working: Bool
    /// Its thread exists on the machine.
    public var started: Bool
    /// Its pane is open.
    public var isOpen: Bool

    public init(name: String, machine: String, machineKind: String, bot: BotIdentity, needsYou: Int, working: Bool, started: Bool, isOpen: Bool) {
        self.name = name; self.machine = machine; self.machineKind = machineKind; self.bot = bot; self.needsYou = needsYou
        self.working = working; self.started = started; self.isOpen = isOpen
    }
}

/// Redesign's pinned Orchestrator row above the threads: its bot, its name, its machine under it with the composer
/// machine row's glyph, and an amber count of what needs you. A double click on the name renames it in place.
final class OrchestratorSidebarRowView: ControlView {
    static let height: CGFloat = 44
    private let bot: BotView
    private let title = LabelView("", font: SB.font(13, .medium), color: SB.c(\.foreground))
    private var machineIcon = IconView(definition: EnvironmentMachineIcon.definition("laptop"), size: 14)
    private var machineKind = "laptop"
    private let machine = LabelView("", font: SB.font(12), color: SB.c(\.secondaryLabel))
    private let count = LabelView("", font: SB.font(11, .semibold), color: .black)
    private let countFill = CALayer()
    private let divider = CALayer()
    private var renameField: SidebarRenameFieldView?
    private(set) var info: OrchestratorSidebarInfo
    var onRename: ((String) -> Void)?

    init(_ info: OrchestratorSidebarInfo) {
        self.info = info
        bot = BotView(identity: info.bot, size: 28)
        super.init(frame: .zero)
        title.lineHeight = 18
        machine.lineHeight = 16
        count.lineHeight = 14
        count.alignment = .center
        countFill.actions = ["bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull(), "hidden": NSNull()]
        divider.actions = countFill.actions
        layer?.addSublayer(countFill)
        layer?.addSublayer(divider)
        for v in [bot, title, machineIcon, machine, count] as [NSView] { addSubview(v) }
        setAccessibilityRole(.button)
        apply(info)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func apply(_ next: OrchestratorSidebarInfo) {
        info = next
        bot.identity = next.bot
        bot.mood = next.needsYou > 0 ? .needsYou : next.working ? .working : .idle
        title.text = next.name
        machine.text = next.machine
        if next.machineKind != machineKind {
            machineKind = next.machineKind
            machineIcon.removeFromSuperview()
            machineIcon = IconView(definition: EnvironmentMachineIcon.definition(next.machineKind), size: 14)
            addSubview(machineIcon)
        }
        count.text = next.needsYou > 9 ? "9+" : "\(next.needsYou)"
        count.isHidden = next.needsYou == 0
        countFill.isHidden = next.needsYou == 0
        let waiting = next.needsYou == 0 ? "" : next.needsYou == 1 ? ", 1 thing needs you" : ", \(next.needsYou) things need you"
        setAccessibilityLabel("\(next.name) on \(next.machine)\(waiting)")
        needsDisplay = true
        needsLayout = true
    }

    // MARK: Renaming

    /// The press that started a rename: its release must not open the pane, which would take the focus back.
    private var renamePress = false

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, title.frame.insetBy(dx: -4, dy: -2).contains(convert(event.locationInWindow, from: nil)) {
            renamePress = true
            beginRename()
            return
        }
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if renamePress { renamePress = false; return }
        super.mouseUp(with: event)
    }

    func beginRename() {
        guard renameField == nil else { return }
        let field = SidebarRenameFieldView()
        field.begin(ThreadId("orchestrator"), title: info.name)
        field.onCommit = { [weak self] _, text, original in
            self?.endRename()
            if text.trimmingCharacters(in: .whitespacesAndNewlines) != original { self?.onRename?(text) }
        }
        field.onCancel = { [weak self] in self?.endRename() }
        addSubview(field)
        renameField = field
        title.isHidden = true
        layout()
        field.focus()
    }

    private func endRename() {
        renameField?.removeFromSuperview()
        renameField = nil
        title.isHidden = false
    }

    // MARK: Drawing

    override func layout() {
        super.layout()
        let w = bounds.width
        bot.frame = NSRect(x: 6, y: (Self.height - 28) / 2 - 2, width: 28, height: 28)
        let cw: CGFloat = count.isHidden ? 0 : max(18, ceil(count.textWidth) + 10)
        let right = w - 8 - (cw > 0 ? cw + 6 : 0)
        let tw = min(ceil(title.textWidth) + 1, max(0, right - 42))
        title.frame = NSRect(x: 42, y: 4, width: tw, height: 18)
        renameField?.frame = NSRect(x: 38, y: 2, width: max(0, right - 38), height: 22)
        machineIcon.frame = NSRect(x: 42, y: 23, width: 14, height: 14)
        machine.frame = NSRect(x: 42 + 14 + 5, y: 22, width: max(0, right - 61), height: 16)
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
        machineIcon.strokeColor = SB.c(\.secondaryLabel)
    }
}
