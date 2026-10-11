import AppKit
import DesignSystem

/// The Add Environment dialog (ConnectionsSettings.tsx:4098-4130, 2881-3001): mode cards, then the
/// Remote link form. With `routeTarget` it adds a route to that machine instead.
public enum AddEnvironmentDialog {
    public static func make(routeTarget: String? = nil) -> (dialog: DialogView, form: AddEnvironmentFormView) {
        let dialog = DialogView(
            title: routeTarget.map { "Add a route to \($0)" } ?? "Add Environment",
            message: routeTarget == nil
                ? "Pair another environment to this client."
                : "Pair this machine again over another address, such as its Tailscale name. It joins the existing routes instead of adding a second machine.")
        // `max-h-[80dvh] sm:max-w-3xl`.
        dialog.maxWidth = 768
        let form = AddEnvironmentFormView(addsRoute: routeTarget != nil)
        dialog.panelContent = [form]
        return (dialog, form)
    }
}

/// The dialog's panel: `space-y-4` of the mode cards and the Remote link body.
public final class AddEnvironmentFormView: DSView {
    public let host = InputView(placeholder: "backend.example.com")
    public let code = InputView(placeholder: "PAIRCODE")
    public let submit: ButtonView
    private let remoteCard = ModeCard(title: "Remote link", detail: "Enter a backend host and pairing code.", icon: .chevronsLeftRightEllipsis)
    private let sshCard = ModeCard(title: "SSH", detail: "Use local SSH config, agent, and tunnels for the backend.", icon: .terminal)
    private let hostLabel = LabelView("Host", font: DSFont.ui(12, weight: .medium), color: Themed.color(\.foreground))
    private let codeLabel = LabelView("Pairing code", font: DSFont.ui(12, weight: .medium), color: Themed.color(\.foreground))
    private let hint = TextBlockView()
    private let errorText = TextBlockView()
    private let addsRoute: Bool

    /// Add pressed (or Return in a field), with the two fields' text.
    public var onSubmit: ((String, String) -> Void)?
    /// The panel changed height (an error appeared or went).
    public var onHeightChange: (() -> Void)?

    public var error: String? {
        didSet { errorText.text = error ?? ""; errorText.isHidden = error == nil; needsLayout = true; onHeightChange?() }
    }

    public var isAdding = false {
        didSet {
            submit.title = isAdding ? "Adding…" : addsRoute ? "Add route" : "Add environment"
            submit.isEnabled = !isAdding
            host.isEnabled = !isAdding
            code.isEnabled = !isAdding
            remoteCard.isEnabled = !isAdding
        }
    }

    init(addsRoute: Bool) {
        self.addsRoute = addsRoute
        submit = ButtonView(addsRoute ? "Add route" : "Add environment", icon: .plus, variant: .outline)
        super.init(frame: .zero)
        submit.iconSize = 14
        hostLabel.lineHeight = 16
        codeLabel.lineHeight = 16
        remoteCard.isSelected = true
        // ponytail: SSH mode is out of scope for M6 (K 3.1); the card shows like T3 desktop's and is disabled
        // T3 draws a disabled card (while adding) at full strength.
        sshCard.disabledOpacity = 1
        remoteCard.disabledOpacity = 1
        sshCard.isEnabled = false
        hint.text = "Paste a full pairing URL here to fill both fields automatically."
        hint.font = DSFont.ui(11)
        hint.lineHeight = 16
        hint.color = Themed.color(\.mutedForeground)
        errorText.font = DSFont.ui(12)
        errorText.lineHeight = 16
        errorText.color = Themed.color(\.destructive)
        errorText.isHidden = true
        for v in [remoteCard, sshCard, hostLabel, host, codeLabel, code, hint, errorText, submit] as [NSView] { addSubview(v) }
        // `handleSavedBackendHostChange`: a pasted pairing URL fills both fields.
        host.onChange = { [weak self] text in
            guard let self, let split = self.splitPairingURL?(text) else { return }
            self.host.text = split.host
            self.code.text = split.code
        }
        submit.action = { [weak self] in self?.submitNow() }
    }

    /// Fills both fields, as pasting the pairing URL would.
    public func prefill(host: String, code: String) {
        self.host.text = host
        self.code.text = code
    }

    /// The pairing URL parser (T3Client's `Pairing.splitPairingURL`); the app sets it.
    public var splitPairingURL: ((String) -> (host: String, code: String)?)?

    func submitNow() {
        guard !isAdding else { return }
        onSubmit?(host.text, code.text)
    }

    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { submitNow() } else { super.keyDown(with: event) }
    }

    // Layout: cards `grid gap-3 sm:grid-cols-2` (min-h-24), `space-y-4`, fields `grid sm:grid-cols-[1fr_10rem] gap-3`
    // with `mb-1.5` labels, the hint `mt-1` under `space-y-3`, the error, then the full-width button.
    private func frames(width: CGFloat) -> (cards: CGFloat, fields: CGFloat, hint: CGFloat, error: CGFloat?, button: CGFloat, height: CGFloat) {
        let cardW = (width - 12) / 2
        let cardH = max(remoteCard.height(forWidth: cardW), sshCard.height(forWidth: cardW))
        var y = cardH + 16
        let fields = y
        // The hint span's `mt-1` collapses into its wrapper's `space-y-3` margin, so 12 in all.
        y += 16 + 6 + 32 + 12
        let hintY = y
        y = hintY + hint.height(forWidth: width)
        var errorY: CGFloat?
        if error != nil {
            y += 16
            errorY = y
            y += errorText.height(forWidth: width)
        }
        y += 16
        let button = y
        y += 32
        return (cardH, fields, hintY, errorY, button, y)
    }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: bounds.width > 0 ? frames(width: bounds.width).height : NSView.noIntrinsicMetric)
    }

    public override func layout() {
        super.layout()
        let w = bounds.width
        let f = frames(width: w)
        let cardW = (w - 12) / 2
        remoteCard.frame = NSRect(x: 0, y: 0, width: cardW, height: f.cards)
        sshCard.frame = NSRect(x: cardW + 12, y: 0, width: cardW, height: f.cards)
        let codeW: CGFloat = 160
        let hostW = w - codeW - 12
        hostLabel.frame = NSRect(x: 0, y: f.fields, width: hostW, height: 16)
        host.frame = NSRect(x: 0, y: f.fields + 22, width: hostW, height: 32)
        codeLabel.frame = NSRect(x: hostW + 12, y: f.fields, width: codeW, height: 16)
        code.frame = NSRect(x: hostW + 12, y: f.fields + 22, width: codeW, height: 32)
        hint.frame = NSRect(x: 0, y: f.hint, width: w, height: hint.height(forWidth: w))
        if let ey = f.error { errorText.frame = NSRect(x: 0, y: ey, width: w, height: errorText.height(forWidth: w)) }
        submit.frame = NSRect(x: 0, y: f.button, width: w, height: 32)
    }

    /// `renderConnectionModeCard`: `flex min-h-24 items-start gap-3 rounded-lg border p-4`, the icon in a
    /// `size-8 rounded-md border` box, title `text-sm font-medium`, description `mt-1 text-xs leading-relaxed`.
    final class ModeCard: ControlView {
        private let box = BoxDecorationLayer()
        private let iconBox = BoxDecorationLayer()
        private let icon: IconView
        private let title = LabelView("", font: DSFont.ui(14, weight: .medium), color: Themed.color(\.foreground))
        private let detail = TextBlockView()
        var isSelected = false { didSet { restyle() } }

        init(title: String, detail: String, icon: IconName) {
            self.icon = IconView(name: icon, size: 16)
            super.init(frame: .zero)
            scalesWhenPressed = false
            box.host = self
            iconBox.host = self
            layer?.addSublayer(box)
            layer?.addSublayer(iconBox)
            self.title.text = title
            self.title.lineHeight = 20
            self.detail.text = detail
            self.detail.font = DSFont.ui(12)
            self.detail.lineHeight = 19.5
            self.detail.color = Themed.color(\.mutedForeground)
            addSubview(self.icon)
            addSubview(self.title)
            addSubview(self.detail)
            setAccessibilityRole(.button)
            setAccessibilityLabel(title)
            restyle()
        }

        func height(forWidth w: CGFloat) -> CGFloat {
            // `p-4` inside the 1px border; `min-h-24` is the border box.
            max(96, 2 + 16 + max(34, 20 + 4 + detail.height(forWidth: w - 34 - 32 - 12)) + 16)
        }

        override func stateDidChange(from old: State) { super.stateDidChange(from: old); restyle() }
        override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); box.setNeedsDisplay(); iconBox.setNeedsDisplay(); restyle() }

        private func restyle() {
            var b = BoxStyle()
            b.radius = 10
            b.border = isSelected ? Themed.color(\.primary, 0.5) : Themed.color(\.border, 0.6)
            b.fill = isSelected ? Themed.color(\.primary, 0.05) : state.hovered && state.enabled ? Themed.color(\.muted, 0.4) : nil
            box.boxStyle = b
            var i = BoxStyle()
            i.radius = 8
            i.border = isSelected ? Themed.color(\.primary, 0.3) : Themed.color(\.border, 0.7)
            i.fill = isSelected ? Themed.color(\.primary, 0.1) : Themed.color(\.background)
            iconBox.boxStyle = i
            icon.strokeColor = isSelected ? Themed.color(\.primary) : state.hovered ? Themed.color(\.foreground) : Themed.color(\.mutedForeground)
        }

        override func layout() {
            super.layout()
            box.layout(boxSize: bounds.size)
            iconBox.layout(boxSize: CGSize(width: 32, height: 32))
            iconBox.frame.origin = CGPoint(x: 17 - iconBox.outset, y: 19 - iconBox.outset)
            icon.frame = NSRect(x: 25, y: 27, width: 16, height: 16)
            let tx: CGFloat = 17 + 32 + 12, tw = max(0, bounds.width - tx - 17)
            title.frame = NSRect(x: tx, y: 17, width: tw, height: 20)
            detail.frame = NSRect(x: tx, y: 41, width: tw, height: detail.height(forWidth: tw))
        }
    }
}
