import AppKit
import DesignSystem
import T3Protocol

/// T3's server update wording (ServerUpdateAction.tsx, versionSkew.ts:122-138, ChatView.tsx:3145-3222).
public enum ServerUpdateCopy {
    /// The wire's sub-second "installing" handoff folds into the download (ServerUpdateAction.tsx:33-40).
    public static func stageLabel(_ stage: ServerUpdateStage) -> String {
        switch stage {
        case .downloading, .installing: "Downloading…"
        case .resuming: "Restarting…"
        }
    }

    /// `serverUpdateGuidance`.
    public static func guidance(_ capability: ServerSelfUpdateCapability) -> String {
        capability == .desktopManaged ? "Update the desktop app" : "Update to stay in sync"
    }

    /// The only confirmation in the flow: the remote machine installs without asking anyone there.
    public static func desktopConfirm(serverLabel: String) -> String {
        "Update the T3 Code desktop app that runs the \(serverLabel)? It will close and relaunch on that machine."
    }

    /// `ServerUpdatesAction`'s confirmation for the desktop apps among "Update all".
    public static func desktopConfirmAll(labels: [String]) -> String {
        "Update the T3 Code desktop apps on \(labels.joined(separator: ", "))? They will close and relaunch on those machines."
    }

    public static func successTitle(serverLabel: String) -> String { "\(serverLabel) updated" }
    public static func successDescription(_ capability: ServerSelfUpdateCapability?, targetVersion: String) -> String {
        capability == .desktopManaged ? "Desktop app relaunched on \(targetVersion)." : "Reconnected on t3@\(targetVersion)."
    }
    public static let failureTitle = "Server update failed"

    /// A desktop app too old for the remote trigger.
    public static let desktopManual = "Update the desktop app on that machine to update this server."

    /// The manual path's button and toast (ServerUpdateAction.tsx:232-252, 293-300).
    public struct Manual: Equatable {
        public var command: String
        public var label: String
        public var toastTitle: String
        public var toastDescription: String
    }

    public static func manual(targetVersion: String, installation: JSONValue?, serverLabel: String) -> Manual {
        let command = ServerVersionSkewLogic.manualCommand(target: targetVersion, installation: installation)
        if installation?["kind"]?.stringValue == "npm-global" {
            return Manual(command: command, label: "Copy update command", toastTitle: "Update command copied",
                          toastDescription: "Run `\(command)` on \(serverLabel), then restart t3 with your usual options.")
        }
        return Manual(command: command, label: "Copy relaunch command", toastTitle: "Relaunch command copied",
                      toastDescription: "Stop t3 on \(serverLabel), then relaunch with `\(command)` using the same subcommand and options. This does not update an installed t3 command.")
    }
}

/// What a version-skewed server's update control offers.
public enum ServerUpdateOffer: Equatable {
    /// "Update" over RPC. `confirm` is the desktop app's question, nil for a launcher-backed server.
    case update(confirm: String?)
    case manual(ServerUpdateCopy.Manual)
    /// A desktop app that can't be driven remotely: only the instruction.
    case desktopManual

    /// `ServerUpdateAction`'s branches.
    public init(_ capabilities: ServerUpdateCapabilities, targetVersion: String, serverLabel: String) {
        switch capabilities.selfUpdate {
        case nil, .other?:
            self = .manual(ServerUpdateCopy.manual(targetVersion: targetVersion, installation: capabilities.installation, serverLabel: serverLabel))
        case .desktopManaged?:
            self = capabilities.desktopAppUpdate ? .update(confirm: ServerUpdateCopy.desktopConfirm(serverLabel: serverLabel)) : .desktopManual
        case .bootService?, .respawn?:
            self = .update(confirm: nil)
        }
    }
}

/// `ServerUpdateProgress`: "Downloading…" then "Restarting…" beside a pulsing dot, or the failure in
/// red. One line, truncated, with the full message as tooltip.
public final class ServerUpdateProgressView: DSView {
    private let dot = CALayer()
    private let label = LabelView("", font: DSFont.ui(12, weight: .medium), color: Themed.color(\.foreground))
    private var tip: TooltipController?
    /// Only a running update pulses; a failure holds still.
    private lazy var loop = LoopingAnimation(view: self, key: "pulse", layer: { [weak self] in self?.state.isRunning == true ? self?.dot : nil }) { Self.pulse() }

    public var state: ServerUpdateState = .idle { didSet { if state != oldValue { apply() } } }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        dot.cornerRadius = 3
        dot.actions = ["position": NSNull(), "bounds": NSNull(), "backgroundColor": NSNull()]
        layer?.addSublayer(dot)
        label.lineHeight = 16
        addSubview(label)
        apply()
    }

    private func apply() {
        switch state {
        case .failed(_, _, _, let message):
            label.text = message
            label.font = DSFont.ui(12)
            if let tip { tip.text = message } else { tip = TooltipController.attach(to: label, text: message) }
            setAccessibilityRole(.staticText)
            setAccessibilityRoleDescription("alert")
        case .running(let stage, _, _):
            label.text = ServerUpdateCopy.stageLabel(stage)
            label.font = DSFont.ui(12, weight: .medium)
            tip?.text = ""
        case .idle:
            label.text = ""
        }
        setAccessibilityLabel(label.text)
        needsDisplay = true
        needsLayout = true
        if !state.isRunning { dot.removeAnimation(forKey: "pulse") }
        loop.update()
    }

    public override func updateLayer() {
        let color = state.isFailed ? Themed.color(\.destructive) : Themed.color(\.foreground)
        dot.backgroundColor = color.cgColor(in: self)
        label.color = color
    }

    public override func layout() {
        super.layout()
        // `gap-2`, a `size-1.5` dot, text-xs.
        CATransaction.begin(); CATransaction.setDisableActions(true)
        dot.frame = CGRect(x: 0, y: (bounds.height - 6) / 2, width: 6, height: 6)
        CATransaction.commit()
        label.frame = NSRect(x: 14, y: (bounds.height - 16) / 2, width: max(0, min(ceil(label.textWidth) + 1, bounds.width - 14)), height: 16)
    }

    public override var intrinsicContentSize: NSSize { NSSize(width: 14 + ceil(label.textWidth) + 1, height: 16) }

    public override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); loop.windowChanged() }
    public override func viewDidHide() { super.viewDidHide(); loop.update() }
    public override func viewDidUnhide() { super.viewDidUnhide(); loop.update() }

    /// `animate-status-pulse`, the same keyframes as the sidebar's terminal glyph.
    static func pulse() -> CAKeyframeAnimation { TerminalStatusGlyph.pulse() }
}
