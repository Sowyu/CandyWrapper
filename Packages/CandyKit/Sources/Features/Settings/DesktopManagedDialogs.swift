import AppKit
import DesignSystem
import T3Protocol

public struct SshPasswordPromptState: Equatable, Sendable {
    public let id: UUID
    public let target: String
    public let expiresAt: Date
    public init(id: UUID = UUID(), target: String, now: Date = Date()) { self.id = id; self.target = target; expiresAt = now.addingTimeInterval(180) }
    public func remaining(at now: Date) -> Int { max(0, Int(ceil(expiresAt.timeIntervalSince(now)))) }
    public func label(at now: Date) -> String { let n = remaining(at: now); return n == 0 ? "Expired" : String(format: "%d:%02d", n / 60, n % 60) }
}

public enum RelayClientInstallState: Equatable, Sendable {
    case idle, confirming(String), installing(String, RelayClientInstallStage), closing
    public mutating func request(version: String) -> Bool { guard self == .idle else { return false }; self = .confirming(version); return true }
    public mutating func respond(_ confirmed: Bool) {
        guard case .confirming(let version) = self else { return }
        self = confirmed ? .installing(version, .checking) : .closing
    }
    public mutating func progress(_ stage: RelayClientInstallStage) { guard case .installing(let version, _) = self else { return }; self = .installing(version, stage) }
}

/// SshPasswordPromptDialog.tsx:160-238, sharing the existing secure input and dialog shell.
// ponytail: the target in the description draws in the UI font; T3 wraps it in `<code>`. Add inline code runs to
// TextBlockView when another dialog needs them.
@MainActor
public final class SshPasswordPromptDialog: DialogView {
    public let password = SecureInputView()
    public let cancel = ButtonView("Cancel", variant: .outline)
    public let proceed = ButtonView("Continue")
    public let body: SshPasswordPromptBody
    public var onResponse: ((String?) -> Void)?
    public init(state: SshPasswordPromptState, now: Date = Date()) {
        body = SshPasswordPromptBody(target: state.target, remaining: state.label(at: now), expired: state.remaining(at: now) == 0, password: password)
        super.init(title: "SSH Password Required", message: "T3 needs your SSH password to connect to \(state.target). The password is passed to the local SSH process for this connection attempt and is not saved by T3 Code.")
        maxWidth = 448; showsCloseButton = false
        panelContent = [body]; footerButtons = [cancel, proceed]
        cancel.action = { [weak self] in self?.respond(nil) }
        proceed.action = { [weak self] in guard let self, self.proceed.isEnabled else { return }; self.respond(self.password.text) }
        password.onSubmit = { [weak self] in self?.proceed.action?() }
        update(state: state, now: now)
    }
    private func respond(_ value: String?) { password.text = ""; onResponse?(value) }
    public func update(state: SshPasswordPromptState, now: Date) {
        let expired = state.remaining(at: now) == 0
        body.set(remaining: state.label(at: now), expired: expired)
        password.isEnabled = !expired; proceed.isEnabled = !expired; cancel.title = expired ? "Dismiss" : "Cancel"
        if expired { password.text = "" }
    }
}

@MainActor
public final class SshPasswordPromptBody: DSView {
    private let prompt: LabelView
    private let countdown = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    private let hint = TextBlockView()
    public let password: SecureInputView
    public init(target: String, remaining: String, expired: Bool, password: SecureInputView = SecureInputView()) {
        self.password = password
        prompt = LabelView("Enter the SSH password for \(target).", font: DSFont.ui(14, weight: .medium), color: Themed.color(\.foreground))
        super.init(frame: .zero)
        hint.font = DSFont.ui(14); hint.lineHeight = 20
        countdown.alignment = .right; countdown.lineHeight = 16; prompt.lineHeight = 20
        [prompt, countdown, password, hint].forEach { addSubview($0) }
        set(remaining: remaining, expired: expired)
    }
    public func set(remaining: String, expired: Bool) {
        countdown.text = remaining; countdown.color = Themed.color(expired ? \.destructive : \.mutedForeground)
        hint.text = expired ? "This SSH password prompt expired. Try connecting again." : "Use SSH keys to avoid repeated password prompts on new SSH sessions."
        hint.color = Themed.color(expired ? \.destructive : \.mutedForeground)
        password.isEnabled = !expired; needsLayout = true
    }
    public override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 20 + 8 + 32 + 12 + hint.height(forWidth: bounds.width > 0 ? bounds.width : 398)) }
    public override func layout() {
        super.layout(); let w = bounds.width
        prompt.frame = NSRect(x: 0, y: 0, width: w - 60, height: 20)
        countdown.frame = NSRect(x: w - 48, y: 2, width: 48, height: 16)
        password.frame = NSRect(x: 0, y: 28, width: w, height: 32)
        hint.frame = NSRect(x: 0, y: 72, width: w, height: hint.height(forWidth: w))
    }
}

/// RelayClientInstallDialog.tsx:72-149. A static bar changes only on server progress events.
@MainActor
public final class RelayClientInstallBody: DSView {
    private let title = LabelView("", font: DSFont.ui(14, weight: .medium), color: Themed.color(\.foreground))
    private let count = LabelView("", font: DSFont.ui(14), color: Themed.color(\.mutedForeground))
    private let detail = TextBlockView()
    private let box = BoxDecorationLayer()
    private let track = CALayer(), fill = CALayer()
    public let stage: RelayClientInstallStage?
    public init(version: String, stage: RelayClientInstallStage? = nil) {
        self.stage = stage
        super.init(frame: .zero)
        box.host = self; layer?.addSublayer(box); layer?.addSublayer(track); layer?.addSublayer(fill)
        [title, count, detail].forEach { addSubview($0) }
        count.alignment = .right; count.lineHeight = 20; title.lineHeight = 20
        title.text = stage?.label ?? "Managed relay client"
        count.text = stage.map { "\($0.step) of 7" } ?? ""; count.isHidden = stage == nil
        detail.text = stage == nil ? "T3 Code will download and install version \(version) locally." : "Keep T3 Code open while the relay client is installed."
        detail.font = DSFont.ui(stage == nil ? 14 : 12); detail.lineHeight = stage == nil ? 22.75 : 19.5; detail.color = Themed.color(\.mutedForeground)
        restyle()
    }
    private func restyle() {
        var b = BoxStyle(); b.radius = 14; b.border = Themed.color(\.border, 0.7); b.fill = Themed.color(\.muted, 0.35)
        box.boxStyle = b; box.isHidden = stage != nil
        track.backgroundColor = Themed.color(\.muted).cgColor(in: self); fill.backgroundColor = Themed.color(\.primary).cgColor(in: self)
        track.cornerRadius = 4; fill.cornerRadius = 4; track.isHidden = stage == nil; fill.isHidden = stage == nil
    }
    public override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); restyle() }
    public override var intrinsicContentSize: NSSize {
        let w = bounds.width > 0 ? bounds.width : 398
        return NSSize(width: NSView.noIntrinsicMetric, height: stage == nil ? 26 + 20 + 4 + detail.height(forWidth: w - 26) : 20 + 10 + 8 + 10 + detail.height(forWidth: w))
    }
    public override func layout() {
        super.layout(); let w = bounds.width
        box.layout(boxSize: bounds.size)
        let inset: CGFloat = stage == nil ? 13 : 0
        title.frame = NSRect(x: inset, y: inset, width: w - 2 * inset - (stage == nil ? 0 : 55), height: 20)
        count.frame = NSRect(x: w - 42, y: 0, width: 42, height: 20)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        track.frame = NSRect(x: 0, y: 30, width: w, height: 8)
        fill.frame = NSRect(x: 0, y: 30, width: w * CGFloat(stage?.step ?? 0) / 7, height: 8)
        CATransaction.commit()
        detail.frame = NSRect(x: inset, y: stage == nil ? 37 : 48, width: w - 2 * inset, height: detail.height(forWidth: w - 2 * inset))
    }
}
@MainActor
public enum RelayClientInstallDialog {
    public static func make(version: String, stage: RelayClientInstallStage? = nil) -> DialogView {
        let dialog = DialogView(title: stage == nil ? "Install relay client?" : "Installing relay client", message: stage == nil ? "T3 Code needs the relay client to make this environment available through T3 Connect." : "T3 Code is preparing this environment for secure access through T3 Connect.")
        dialog.headerAccessory = RelayClientInstallIcon()
        dialog.maxWidth = 448; dialog.showsCloseButton = stage == nil
        dialog.panelContent = [RelayClientInstallBody(version: version, stage: stage)]
        return dialog
    }
}

@MainActor
private final class RelayClientInstallIcon: DSView {
    private let box = BoxDecorationLayer()
    private let icon = IconView(name: .download, size: 18)
    override init(frame: NSRect = .zero) {
        super.init(frame: frame); box.host = self; layer?.addSublayer(box); addSubview(icon)
        var style = BoxStyle(); style.radius = 10; style.border = Themed.color(\.border, 0.7); style.fill = Themed.color(\.muted, 0.6)
        box.boxStyle = style; icon.strokeColor = Themed.color(\.mutedForeground)
    }
    override var intrinsicContentSize: NSSize { NSSize(width: 36, height: 36) }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); box.setNeedsDisplay() }
    override func layout() { super.layout(); box.layout(boxSize: bounds.size); icon.frame = NSRect(x: 9, y: 9, width: 18, height: 18) }
}
