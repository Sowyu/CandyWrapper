import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// `SecretRequestCard` (SecretRequestCard.tsx:28-179): while pending here, a card with what is asked, why,
/// a masked field with "Save securely", any error, the privacy note and Decline; otherwise one work log line,
/// "{label} · {outcome}" with a lock, check or minus. The typed value lives only in the field and the request,
/// and the field clears when the row is recycled or the answer is sent. 8pt under it (`pb-2`).
/// A 5258 card with `fields` shows one labelled input per field, masked unless `secret: false`, and moves Save
/// next to Decline (SecretRequestCard.tsx:233-300, 305-380). Every masked input has 5258's show/hide eye
/// (`SecretRequestField`, :303-372, #31257, #42309). Redesign draws the card as its card on the ground
/// (`RedesignTokens.Card`), like code blocks and tables, with no shadow.
final class SecretRequestRowView: TimelineRowView {
    /// One input of the card. Text sits only in the AppKit field.
    @MainActor private final class Entry {
        let input: SecretRequests.Input
        let label: LabelView
        let view: NSView
        private let secure: SecureInputView?
        private let plain: InputView?
        init(_ input: SecretRequests.Input) {
            self.input = input
            label = LabelView(input.label, font: TL.font(12, .medium))
            label.lineHeight = 16
            if input.secret {
                let f = SecureInputView(placeholder: input.placeholder); secure = f; plain = nil; view = f
                f.revealLabel = "Show \(input.label)" // :359
            } else {
                let f = InputView(placeholder: input.placeholder); plain = f; secure = nil; view = f
            }
        }
        var text: String {
            get { secure?.text ?? plain?.text ?? "" }
            set { secure?.text = newValue; plain?.text = newValue }
        }
        var isEnabled: Bool {
            get { secure?.isEnabled ?? plain?.isEnabled ?? false }
            set { secure?.isEnabled = newValue; plain?.isEnabled = newValue }
        }
        func wire(change: @escaping @MainActor () -> Void, submit: @escaping @MainActor () -> Void) {
            secure?.onChange = { _ in change() }; secure?.onSubmit = submit
            plain?.onChange = { _ in change() }; plain?.onSubmit = submit
        }
    }

    private let card = FillView()
    private let title = LabelView("", font: TL.font(14, .medium))
    private let reason = TextBlockView("", font: TL.font(14), lineHeight: 20, color: TL.c(\.mutedForeground))
    private var entries: [Entry] = []
    private var multiple = false
    private let save = ButtonView("Save securely", variant: .default, size: .default)
    private let errorLabel = TextBlockView("", font: TL.font(12), lineHeight: 16, color: TL.c(\.destructive))
    private let shield = IconView(name: .shieldCheck, size: 14)
    private let privacy = LabelView(SecretRequests.privacyNote(delivery: nil), font: TL.font(12))
    private let decline = ButtonView("Decline", variant: .ghostMuted, size: .xs)
    /// The answered and pending-elsewhere line.
    private var lineIcon = IconView(name: .lock, size: 14)
    private var lineIconName = IconName.lock
    private let lineLabel = LabelView("", font: TL.font(14))

    private var display = SecretRequests.Display.pending
    private var request: TurnItem?
    private var rowId = ""
    private var submitting = false { didSet { updateEnabled() } }
    private var error: String? { didSet { errorLabel.text = error ?? ""; errorLabel.isHidden = error == nil } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        card.radius = 12
        addSubview(card)
        title.lineHeight = 20
        privacy.lineHeight = 16
        lineLabel.lineHeight = 24
        for v in [title, reason, save, errorLabel, shield, privacy, decline, lineIcon, lineLabel] as [NSView] { addSubview(v) }
        errorLabel.isHidden = true
        save.action = { [weak self] in self?.send(save: true) }
        decline.action = { [weak self] in self?.send(save: false) }
        restyle()
    }

    override func configure(_ item: TimelineItem) {
        super.configure(item)
        guard case .event(let p, _, _) = item.row.kind else { return }
        let changedRequest = request?.id != p.item.id
        let wasSubmitting = submitting
        request = p.item
        rowId = item.id
        display = SecretRequests.display(status: p.item.string("secretStatus"), visibility: p.visibility)
        let label = p.item.string("label") ?? "Secret"
        title.text = label
        let why = (p.item.string("reason") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        reason.text = why
        reason.isHidden = why.isEmpty
        let fields = p.item.secretRequestFields
        multiple = fields != nil
        let inputs = SecretRequests.inputs(label: label, placeholder: p.item.string("placeholder"), fields: fields)
        if changedRequest || inputs != entries.map(\.input) { rebuildEntries(inputs) }
        privacy.text = SecretRequests.privacyNote(delivery: p.item.string("delivery"), multiple: multiple)
        // The fields clear once the answer is accepted; the card turns into its answered line after.
        if wasSubmitting, !item.ui.secretSubmitting, item.ui.secretError == nil { clearEntries() }
        submitting = item.ui.secretSubmitting
        error = item.ui.secretError
        let pending = display == .pending
        for v in [card, title, save, shield, privacy, decline] as [NSView] { v.isHidden = !pending }
        for e in entries { e.view.isHidden = !pending; e.label.isHidden = !pending || !multiple }
        if !pending { reason.isHidden = true; errorLabel.isHidden = true }
        lineIcon.isHidden = pending
        lineLabel.isHidden = pending
        let (icon, text): (IconName, String) = switch display {
        case .pendingElsewhere(let l): (.lock, l)
        case .answered(let outcome, let l): (outcome == .saved ? .check : .minus, l)
        case .pending: (.lock, "")
        }
        if icon != lineIconName {
            lineIcon.removeFromSuperview()
            lineIcon = IconView(name: icon, size: 14)
            lineIconName = icon
            addSubview(lineIcon)
            lineIcon.isHidden = pending
        }
        lineLabel.text = "\(label) · \(text)"
        restyle()
        needsLayout = true
    }

    /// Never carries a typed value into another request.
    override func prepareForReuse() {
        super.prepareForReuse()
        clearEntries()
        request = nil
    }

    private func rebuildEntries(_ inputs: [SecretRequests.Input]) {
        for e in entries { e.text = ""; e.view.removeFromSuperview(); e.label.removeFromSuperview() }
        entries = inputs.map(Entry.init)
        for e in entries {
            e.wire(change: { [weak self] in self?.updateEnabled() }, submit: { [weak self] in self?.send(save: true) })
            addSubview(e.label)
            addSubview(e.view)
            e.label.color = TL.c(\.mutedForeground)
        }
        updateEnabled()
    }

    private func clearEntries() { for e in entries { e.text = "" } }

    private var typedValues: [String: String] { Dictionary(entries.map { ($0.input.key, $0.text) }, uniquingKeysWith: { a, _ in a }) }

    private func answer(_ isSave: Bool) -> JSONValue? {
        guard let request else { return nil }
        return SecretRequests.answerInput(threadId: request.threadId, itemId: request.id, fields: request.secretRequestFields,
                                          isSave ? .values(typedValues) : .decline)
    }

    private func updateEnabled() {
        save.isEnabled = !submitting && answer(true) != nil
        decline.isEnabled = !submitting
        for e in entries { e.isEnabled = !submitting }
    }

    private func send(save isSave: Bool) {
        guard !submitting, let input = answer(isSave) else { return }
        context.model?.answerSecretRequest(rowId, input)
    }

    /// A click anywhere on the card targets its first empty field, so a paste that follows lands there
    /// (SecretRequestCard.tsx:192-203).
    override func mouseDown(with event: NSEvent) {
        guard display == .pending, !entries.isEmpty else { return super.mouseDown(with: event) }
        let empty = entries.first { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? entries[0]
        window?.makeFirstResponder(empty.view)
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); restyle() }

    private func restyle() {
        let redesign = ThemeRuntime.isDither(dark: effectiveAppearance.isDark)
        card.fill = redesign ? RedesignTokens.Card.fill : TL.c(\.card)
        card.border = redesign ? RedesignTokens.Card.border : TL.c(\.border, 0.6)
        title.color = TL.c(\.foreground)
        shield.strokeColor = TL.c(\.mutedForeground)
        privacy.color = TL.c(\.mutedForeground)
        lineIcon.strokeColor = TL.c(\.iconMuted)
        lineLabel.color = TL.c(\.secondaryLabel)
        for e in entries { e.label.color = TL.c(\.mutedForeground) }
    }

    /// `gap-2.5` between inputs, each with its `text-xs` label and `gap-1` above it when the card has fields.
    private var inputsHeight: CGFloat {
        multiple ? CGFloat(entries.count) * (16 + 4 + 32) + CGFloat(max(0, entries.count - 1)) * 10 : 32
    }

    private func reasonHeight(_ inner: CGFloat) -> CGFloat { reason.isHidden ? 0 : 4 + reason.height(forWidth: inner) }
    private func errorHeight(_ inner: CGFloat) -> CGFloat { error == nil ? 0 : 12 + errorLabel.height(forWidth: inner) }

    override func height(forWidth width: CGFloat) -> CGFloat {
        guard display == .pending else { return 2 + 24 + 2 + 8 }
        let inner = max(0, width - 2 - 32)
        return 1 + 16 + 20 + reasonHeight(inner) + 12 + inputsHeight + errorHeight(inner) + 12 + (multiple ? 32 : 24) + 16 + 1 + 8
    }

    override func layout() {
        super.layout()
        guard display == .pending else {
            // `WorkLogRow`: `py-0.5 px-0.5`, a 24pt icon cell, `gap-1.5`, the label in `text-secondary-label`.
            lineIcon.frame = NSRect(x: 2 + 5, y: 2 + 5, width: 14, height: 14)
            lineLabel.frame = NSRect(x: 2 + 24 + 6, y: 2, width: max(0, bounds.width - 34), height: 24)
            return
        }
        let inner = max(0, bounds.width - 2 - 32)
        card.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - 8)
        let x: CGFloat = 17
        var y: CGFloat = 17
        title.frame = NSRect(x: x, y: y, width: inner, height: 20)
        y += 20
        if !reason.isHidden {
            let h = reason.height(forWidth: inner)
            reason.frame = NSRect(x: x, y: y + 4, width: inner, height: h)
            y += 4 + h
        }
        y += 12
        let sw = save.intrinsicContentSize.width
        if multiple {
            for (i, e) in entries.enumerated() {
                if i > 0 { y += 10 }
                e.label.frame = NSRect(x: x, y: y, width: inner, height: 16)
                e.view.frame = NSRect(x: x, y: y + 20, width: inner, height: 32)
                y += 52
            }
        } else if let e = entries.first {
            e.view.frame = NSRect(x: x, y: y, width: max(0, inner - 8 - sw), height: 32)
            save.frame = NSRect(x: x + inner - sw, y: y, width: sw, height: 32)
            y += 32
        }
        if error != nil {
            let h = errorLabel.height(forWidth: inner)
            errorLabel.frame = NSRect(x: x, y: y + 12, width: inner, height: h)
            y += 12 + h
        }
        y += 12
        let dw = decline.intrinsicContentSize.width
        // With fields, Save sits after Decline (`gap-2`) and the footer row is the button's 32pt.
        let footer: CGFloat = multiple ? 32 : 24
        let trailing = multiple ? sw + 8 : 0
        if multiple { save.frame = NSRect(x: x + inner - sw, y: y, width: sw, height: 32) }
        decline.frame = NSRect(x: x + inner - trailing - dw, y: y + (footer - 24) / 2, width: dw, height: 24)
        shield.frame = NSRect(x: x, y: y + (footer - 14) / 2, width: 14, height: 14)
        privacy.frame = NSRect(x: x + 14 + 6, y: y + (footer - 16) / 2, width: max(0, inner - 20 - trailing - dw - 8), height: 16)
    }
}
