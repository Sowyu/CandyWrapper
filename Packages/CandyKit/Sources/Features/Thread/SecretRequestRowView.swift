import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// `SecretRequestCard` (SecretRequestCard.tsx:28-179): while pending here, a card with what is asked, why,
/// a masked field with "Save securely", any error, the privacy note and Decline; otherwise one work log line,
/// "{label} · {outcome}" with a lock, check or minus. The typed value lives only in the field and the request,
/// and the field clears when the row is recycled or the answer is sent. 8pt under it (`pb-2`).
final class SecretRequestRowView: TimelineRowView {
    private let card = FillView()
    private let title = LabelView("", font: TL.font(14, .medium))
    private let reason = TextBlockView("", font: TL.font(14), lineHeight: 20, color: TL.c(\.mutedForeground))
    private let field = SecureInputView(placeholder: SecretRequests.defaultPlaceholder)
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
        for v in [title, reason, field, save, errorLabel, shield, privacy, decline, lineIcon, lineLabel] as [NSView] { addSubview(v) }
        errorLabel.isHidden = true
        field.onChange = { [weak self] _ in self?.updateEnabled() }
        field.onSubmit = { [weak self] in self?.send(save: true) }
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
        field.placeholder = p.item.string("placeholder") ?? SecretRequests.defaultPlaceholder
        privacy.text = SecretRequests.privacyNote(delivery: p.item.string("delivery"))
        if changedRequest { field.text = "" }
        // The field clears once the answer is accepted; the card turns into its answered line after.
        if wasSubmitting, !item.ui.secretSubmitting, item.ui.secretError == nil { field.text = "" }
        submitting = item.ui.secretSubmitting
        error = item.ui.secretError
        let pending = display == .pending
        for v in [card, title, field, save, shield, privacy, decline] as [NSView] { v.isHidden = !pending }
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
        field.text = ""
        request = nil
    }

    private func updateEnabled() {
        save.isEnabled = !submitting && !field.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        decline.isEnabled = !submitting
        field.isEnabled = !submitting
    }

    private func send(save isSave: Bool) {
        guard !submitting, let request,
              let input = SecretRequests.answerInput(threadId: request.threadId, itemId: request.id, isSave ? .save(field.text) : .decline)
        else { return }
        context.model?.answerSecretRequest(rowId, input)
    }

    /// A click anywhere on the card targets its field, so a paste that follows lands here.
    override func mouseDown(with event: NSEvent) {
        if display == .pending { window?.makeFirstResponder(field) } else { super.mouseDown(with: event) }
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); restyle() }

    private func restyle() {
        card.fill = TL.c(\.card)
        card.border = TL.c(\.border, 0.6)
        title.color = TL.c(\.foreground)
        shield.strokeColor = TL.c(\.mutedForeground)
        privacy.color = TL.c(\.mutedForeground)
        lineIcon.strokeColor = TL.c(\.iconMuted)
        lineLabel.color = TL.c(\.secondaryLabel)
    }

    private func reasonHeight(_ inner: CGFloat) -> CGFloat { reason.isHidden ? 0 : 4 + reason.height(forWidth: inner) }
    private func errorHeight(_ inner: CGFloat) -> CGFloat { error == nil ? 0 : 12 + errorLabel.height(forWidth: inner) }

    override func height(forWidth width: CGFloat) -> CGFloat {
        guard display == .pending else { return 2 + 24 + 2 + 8 }
        let inner = max(0, width - 2 - 32)
        return 1 + 16 + 20 + reasonHeight(inner) + 12 + 32 + errorHeight(inner) + 12 + 24 + 16 + 1 + 8
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
        field.frame = NSRect(x: x, y: y, width: max(0, inner - 8 - sw), height: 32)
        save.frame = NSRect(x: x + inner - sw, y: y, width: sw, height: 32)
        y += 32
        if error != nil {
            let h = errorLabel.height(forWidth: inner)
            errorLabel.frame = NSRect(x: x, y: y + 12, width: inner, height: h)
            y += 12 + h
        }
        y += 12
        let dw = decline.intrinsicContentSize.width
        decline.frame = NSRect(x: x + inner - dw, y: y, width: dw, height: 24)
        shield.frame = NSRect(x: x, y: y + 5, width: 14, height: 14)
        privacy.frame = NSRect(x: x + 14 + 6, y: y + 4, width: max(0, inner - 20 - dw - 8), height: 16)
    }
}
