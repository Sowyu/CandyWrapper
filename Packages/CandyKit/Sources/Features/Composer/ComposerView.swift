import AppKit
import DesignSystem
import T3Protocol

/// The composer box (ChatComposer.tsx, ComposerSurface.tsx): a 22px-radius glass surface with
/// the prompt editor, the footer's left control slots, the attach button and the primary action.
/// Spec: J-composer-visuals sections 2 to 5, behavior I-composer-flow section 7.
///
/// The app sets `runState`, `isBusy`, `placeholderInput` and the handlers; the pickers go into
/// `footerControls`. Height follows the text between 144 and 274 (`preferredHeight`), then the
/// editor scrolls; `onHeightChange` tells the parent to re-layout.
public final class ComposerView: DSView {
    /// `rounded-3xl`: `calc(var(--radius) + 12px)`.
    public static let radius: CGFloat = 22
    /// Body `px-4 pt-4 pb-2`, footer `px-4 pb-4`, the 1px `p-px` of ComposerSurface.Main.
    static let inset: CGFloat = 1, pad: CGFloat = 16, footerHeight: CGFloat = 32
    /// `min-h-19.5` and `max-h-52` less the `p-1 -m-1` pair.
    static let editorMin: CGFloat = 70, editorMax: CGFloat = 200

    // MARK: Inputs

    /// The thread's runs as the primary action reads them.
    public var runState = ComposerLogic.RunState() { didSet { if runState != oldValue { refresh() } } }
    /// A send or resume is in flight: the button shows a spinner and is disabled.
    public var isBusy = false { didSet { if isBusy != oldValue { refresh() } } }
    /// Sending is blocked (disconnected, no provider, no project); the reason is the tooltip.
    public var sendDisabledReason: String? { didSet { if sendDisabledReason != oldValue { refresh() } } }
    public var placeholderInput = ComposerLogic.PlaceholderInput() { didSet { if placeholderInput != oldValue { refresh() } } }
    public var sendShortcut = ComposerLogic.SendShortcut.enter
    /// `followUpBehavior`: false queues follow-ups while a turn runs (T3's default), true steers.
    public var steerByDefault = false { didSet { refresh() } }
    /// Nightly and dev servers draw the stage art in the send button.
    public var stageArt = true { didSet { primary.stageArt = stageArt } }

    /// The footer's left cluster (model, traits, access). Separators go between them.
    public var footerControls: [NSView] = [] {
        didSet {
            oldValue.forEach { $0.removeFromSuperview() }
            separators.forEach { $0.removeFromSuperview() }
            separators = footerControls.dropFirst().map { _ in SeparatorView(.vertical) }
            separators.forEach(addSubview)
            footerControls.forEach(addSubview)
            needsLayout = true
        }
    }

    // MARK: Outputs

    /// Return or the button with content: the text (untrimmed) and how to deliver it.
    public var onSend: ((String, ComposerLogic.SendMode) -> Void)?
    public var onStop: (() -> Void)?
    public var onResume: (() -> Void)?
    /// Every edit, for the per-thread draft.
    public var onTextChange: ((String) -> Void)?
    public var onHeightChange: (() -> Void)?

    public var text: String {
        get { editor.string }
        set { editor.setText(newValue) }
    }

    /// Composer box height for the current text: 144 to 274.
    public var preferredHeight: CGFloat { Self.inset * 2 + Self.pad + editorHeight + 8 + Self.footerHeight + Self.pad }

    // MARK: Views

    private let shadowLayer = CALayer()
    private let shadowMask = CAShapeLayer()
    let glass = DSView()
    /// A view, not a layer: `layer.render(in:)` ignores zPosition, and the outline must sit over the glass.
    private let outline = OutlineView()
    let editor = ComposerEditor()
    private let scroll = NSScrollView()
    let placeholder = LabelView()
    private let validation = LabelView()
    let attach = ButtonView(nil, icon: .paperclip, variant: .ghost, size: .iconSm)
    let primary = ComposerPrimaryButton()
    private var separators: [SeparatorView] = []
    private var alternateHeld = false
    private var editorHeight = ComposerView.editorMin

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.masksToBounds = false
        // `shadow-composer`: 0 12px 28px -18px black/40%, light only, and only outside the box.
        shadowLayer.shadowColor = .black
        shadowLayer.shadowRadius = 14
        shadowLayer.shadowOffset = CGSize(width: 0, height: -12) // y-up layer space: 12px down
        shadowLayer.mask = shadowMask
        shadowMask.fillRule = .evenOdd
        layer?.addSublayer(shadowLayer)

        // Glass: `card` / `surface-raised` at 80% over a 12px backdrop blur, saturate 1.14.
        glass.layerUsesCoreImageFilters = true
        glass.layer?.cornerRadius = Self.radius
        glass.layer?.masksToBounds = true
        if let blur = CIFilter(name: "CIGaussianBlur", parameters: ["inputRadius": 12]),
           let saturate = CIFilter(name: "CIColorControls", parameters: ["inputSaturation": 1.14, "inputBrightness": 0, "inputContrast": 1]) {
            glass.layer?.backgroundFilters = [saturate, blur]
        }
        addSubview(glass)

        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.contentView.drawsBackground = false
        scroll.documentView = editor
        addSubview(scroll)
        // `text-placeholder/75`, first line, leading-relaxed.
        placeholder.font = ComposerEditor.font
        placeholder.lineHeight = ComposerEditor.lineHeight
        placeholder.color = Themed.color(\.placeholder, 0.75)
        addSubview(placeholder, positioned: .below, relativeTo: scroll)
        validation.font = DSFont.ui(12)
        validation.lineHeight = 16
        validation.color = Themed.color(\.destructive)
        validation.isHidden = true
        addSubview(validation)

        // ponytail: attachments are out of M5 scope, so attach only shows its place and tooltip; wire the picker with uploads
        attach.iconColor = Themed.color(\.mutedForeground)
        TooltipController.attach(to: attach, text: "Attach files")
        attach.setAccessibilityLabel("Attach files")
        addSubview(attach)
        primary.action = { [weak self] in self?.primaryPressed() }
        addSubview(primary)

        // The outline sits over everything (Host::after).
        outline.layer?.cornerRadius = Self.radius
        outline.layer?.borderWidth = 1
        addSubview(outline)

        editor.onTextChange = { [weak self] in self?.textChanged() }
        editor.onSubmitKey = { [weak self] key in self?.submitKey(key) ?? false }
        editor.onModifierChange = { [weak self] held in
            guard let self, held != alternateHeld else { return }
            alternateHeld = held
            refresh()
        }
        refresh()
    }

    // MARK: Focus

    public func focus() { window?.makeFirstResponder(editor) }
    public var isEditorFocused: Bool { window?.firstResponder === editor }
    public override var acceptsFirstResponder: Bool { true }
    public override func becomeFirstResponder() -> Bool { window?.makeFirstResponder(editor) ?? false }

    /// Clicks on padding focus the editor.
    public override func mouseDown(with event: NSEvent) {
        if editor.isEditable { focus() }
    }

    // MARK: State

    private var hasContent: Bool { !editor.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var sendMode: ComposerLogic.SendMode {
        ComposerLogic.sendMode(running: runState.canInterrupt, alternate: alternateHeld, steerByDefault: steerByDefault)
    }

    /// Editor disabled for approvals, choice-only questions and a missing project (ChatComposer.tsx:7500-7506).
    private var editorDisabled: Bool {
        placeholderInput.approvalPending || placeholderInput.questionChoiceOnly == true || placeholderInput.projectRequired
    }

    func refresh() {
        placeholder.text = ComposerLogic.placeholder(placeholderInput)
        editor.isEditable = !editorDisabled
        // Project selection required dims the whole surface (`opacity-75`).
        alphaValue = placeholderInput.projectRequired ? 0.75 : 1
        let face = ComposerLogic.primaryAction(run: runState, hasContent: hasContent, busy: isBusy, mode: sendMode)
        primary.face = face
        let validationMessage = ComposerLogic.lengthValidationMessage(editor.string)
        switch face {
        case .stop:
            primary.isEnabled = true
            primary.tooltip = "Interrupt"
        case .resume:
            primary.isEnabled = sendDisabledReason == nil
            primary.tooltip = sendDisabledReason ?? "Resume thread"
        case .busy:
            primary.isEnabled = false
            primary.tooltip = "Submitting message"
        case .send, .queue, .steer:
            primary.isEnabled = hasContent && sendDisabledReason == nil && validationMessage == nil
            if let reason = sendDisabledReason {
                primary.tooltip = reason
            } else if face == .send {
                primary.tooltip = "Submit message"
            } else {
                // ponytail: no shortcut label after "Ctrl/⌘-click"; add it with the keybindings settings
                let action = steerByDefault ? "steer" : "queue", other = steerByDefault ? "queue" : "steer"
                primary.tooltip = "Click to \(action), Ctrl/⌘-click to \(other)"
            }
        }
        if validation.text != (validationMessage ?? "") || validation.isHidden != (validationMessage == nil) {
            validation.text = validationMessage ?? ""
            validation.isHidden = validationMessage == nil
            relayoutHeight()
        }
    }

    private func textChanged() {
        placeholder.isHidden = !editor.string.isEmpty
        refresh()
        relayoutHeight()
        onTextChange?(editor.string)
    }

    private func relayoutHeight() {
        let height = min(Self.editorMax, max(Self.editorMin, editor.contentHeight))
        needsLayout = true
        guard height != editorHeight else { return }
        editorHeight = height
        onHeightChange?()
    }

    // MARK: Actions

    private func submitKey(_ key: ComposerLogic.Key) -> Bool {
        guard let intent = ComposerLogic.submitIntent(key, prompt: editor.string, mode: sendShortcut, turnRunning: runState.canInterrupt) else {
            return false
        }
        let mode = ComposerLogic.sendMode(running: runState.canInterrupt, alternate: intent == .alternate, steerByDefault: steerByDefault)
        send(mode)
        // A send key never inserts a newline, even when nothing was sent.
        return true
    }

    private func primaryPressed() {
        switch primary.face {
        case .stop: onStop?()
        case .resume: onResume?()
        case .busy: break
        case .send, .queue, .steer:
            let held = NSApp.currentEvent.map { !$0.modifierFlags.intersection([.command, .control]).isEmpty } ?? false
            send(ComposerLogic.sendMode(running: runState.canInterrupt, alternate: held, steerByDefault: steerByDefault))
        }
    }

    private func send(_ mode: ComposerLogic.SendMode) {
        guard !isBusy, sendDisabledReason == nil, !editorDisabled, hasContent,
              ComposerLogic.lengthValidationMessage(editor.string) == nil else { return }
        onSend?(editor.string, mode)
    }

    // MARK: Drawing and layout

    public override func updateLayer() {
        let dark = effectiveAppearance.isDark
        CATransaction.begin(); CATransaction.setDisableActions(true)
        glass.layer?.backgroundColor = Themed.color(light: \.card, 0.8, dark: \.surfaceRaised, 0.8).cgColor(in: self)
        outline.layer?.borderColor = (dark ? Themed.white(0.05) : Themed.black(0.08)).cgColor
        shadowLayer.shadowOpacity = dark ? 0 : 0.4
        CATransaction.commit()
    }

    public override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        let box = CGRect(x: 0, y: 0, width: w, height: h)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        shadowLayer.frame = box
        // Spread -18: the shadow shape is the box inset by 18.
        shadowLayer.shadowPath = CGPath(roundedRect: box.insetBy(dx: 18, dy: 18), cornerWidth: max(0, Self.radius - 18),
                                   cornerHeight: max(0, Self.radius - 18), transform: nil)
        let maskPath = CGMutablePath()
        maskPath.addRect(box.insetBy(dx: -60, dy: -60))
        maskPath.addRoundedRect(in: box, cornerWidth: Self.radius, cornerHeight: Self.radius)
        shadowMask.frame = box
        shadowMask.path = maskPath
        CATransaction.commit()
        glass.frame = box
        outline.frame = box

        // Editor: text box at x 17, the scroller in the 4px `p-1` padding outside it.
        let textTop = Self.inset + Self.pad
        let textWidth = max(0, w - 2 * (Self.inset + Self.pad))
        scroll.frame = NSRect(x: Self.inset + Self.pad - 4, y: textTop - 4, width: textWidth + 8, height: editorHeight + 8)
        editor.textContainerInset = NSSize(width: 4, height: 4 + editor.lineTop)
        editor.minSize = NSSize(width: textWidth + 8, height: editorHeight + 8)
        editor.frame.size.width = textWidth + 8
        placeholder.frame = NSRect(x: Self.inset + Self.pad, y: textTop, width: textWidth, height: ComposerEditor.lineHeight)
        placeholder.isHidden = !editor.string.isEmpty

        // ponytail: the length message overlaps the footer's top edge; T3 grows the box for it (ComposerPromptLengthValidation)
        validation.frame = NSRect(x: Self.inset + Self.pad, y: textTop + editorHeight - 16, width: textWidth, height: 16)

        // Footer row: 32 tall, 16 from the bottom.
        let rowY = h - Self.inset - Self.pad - Self.footerHeight
        let midY = rowY + Self.footerHeight / 2
        primary.frame = NSRect(x: w - Self.inset - Self.pad - 32, y: rowY, width: 32, height: 32)
        attach.frame = NSRect(x: primary.frame.minX - 8 - 28, y: midY - 14, width: 28, height: 28)
        // Left cluster: the first control's own 10px padding puts its icon at x 17 (`-ms-2.5`); gap 4,
        // separators 1x16 with 2px margins.
        var x = Self.inset + Self.pad - 10
        let limit = attach.frame.minX - 8
        for (i, control) in footerControls.enumerated() {
            if i > 0 {
                let sep = separators[i - 1]
                x += 4 + 2
                sep.frame = NSRect(x: x, y: midY - 8, width: 1, height: 16)
                x += 1 + 2 + 4
            }
            let size = control.intrinsicContentSize
            let width = max(0, min(size.width, limit - x))
            control.frame = NSRect(x: x, y: midY - size.height / 2, width: width, height: size.height)
            x += width
        }
    }
}

/// The composer's 1px outline (Host::after): drawn over the content, never takes clicks.
private final class OutlineView: DSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
