import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// `LinkRequestCard` (LinkRequestCard.tsx:41-171 at 3814): an agent asked to link another environment. While pending
/// here, a card with what to link, why, the address, any error and Decline with "Review link…" (or "Choose machine…"
/// when the agent left the machine open); otherwise one work log line with a link, check, x or minus. The pairing
/// code lives only in the app's dialog. 8pt under it (`pb-2`).
final class LinkRequestRowView: TimelineRowView {
    enum Display: Equatable {
        case pending
        case line(IconName, String)
    }

    private let card = FillView()
    private let title = LabelView("", font: TL.font(14, .medium))
    private let reason = TextBlockView("", font: TL.font(14), lineHeight: 20, color: TL.c(\.mutedForeground))
    private let url = LabelView("", font: TL.font(12))
    private let errorLabel = TextBlockView("", font: TL.font(12), lineHeight: 16, color: TL.c(\.destructive))
    private let note = LabelView("Only a session that manages access here can answer this.", font: TL.font(12))
    private let decline = ButtonView("Decline", variant: .ghostMuted, size: .xs)
    private let review = ButtonView("Review link…", variant: .default, size: .xs)
    private var lineIcon = IconView(name: .link, size: 14)
    private var lineIconName = IconName.link
    private let lineLabel = LabelView("", font: TL.font(14))

    private var display = Display.pending
    private var request: TurnItem?
    private var rowId = ""
    private var canAnswer = false
    private var submitting = false
    private var error: String? { didSet { errorLabel.text = error ?? ""; errorLabel.isHidden = error == nil } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        card.radius = 12
        addSubview(card)
        title.lineHeight = 20
        title.truncates = true
        url.lineHeight = 16
        url.truncates = true
        note.lineHeight = 16
        lineLabel.lineHeight = 24
        lineLabel.truncates = true
        for v in [title, reason, url, errorLabel, note, decline, review, lineIcon, lineLabel] as [NSView] { addSubview(v) }
        errorLabel.isHidden = true
        decline.action = { [weak self] in
            guard let self, let request = self.request, !self.submitting else { return }
            self.context.model?.declineLink(self.rowId, request)
        }
        review.action = { [weak self] in
            guard let self, let request = self.request, !self.submitting else { return }
            self.context.model?.reviewLinkRequest?(request)
        }
        restyle()
    }

    /// `linkRequestDisplay` (client-runtime/src/linkRequest.ts:210-246).
    static func display(_ item: TurnItem, visibility: String) -> Display {
        switch item.string("linkStatus") {
        case "linked":
            let access = item.string("linkedAccess").map { " · \(LinkAccess.label($0))" } ?? ""
            return .line(.check, "Linked \(item.string("linkedLabel") ?? targetName(item))\(access)")
        case "declined": return .line(.minus, "Declined")
        case "failed": return .line(.x, "Could not link: \(item.string("failure") ?? "the other environment refused")")
        case "cancelled": return .line(.minus, "Request ended")
        default: return visibility == "local" ? .pending : .line(.link, "Waiting for an answer in the original thread")
        }
    }

    /// `linkRequestTargetName`: its own name, else the address asked for.
    static func targetName(_ item: TurnItem) -> String {
        let label = item.string("label")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !label.isEmpty ? label : item.string("url") ?? "a machine"
    }

    /// The agent named neither a machine nor an address, so the user picks one.
    static func picksMachine(_ item: TurnItem) -> Bool { item.string("environmentId") == nil && item.string("url") == nil }

    override func configure(_ item: TimelineItem) {
        super.configure(item)
        guard case .event(let p, _, _) = item.row.kind else { return }
        request = p.item
        rowId = item.id
        display = Self.display(p.item, visibility: p.visibility)
        let picks = Self.picksMachine(p.item)
        title.text = picks ? "Link a machine to this environment" : "Link \(Self.targetName(p.item)) to this environment"
        let why = (p.item.string("reason") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        reason.text = why
        reason.isHidden = why.isEmpty
        let address = p.item.string("label") != nil ? p.item.string("url") : nil
        url.text = address ?? ""
        url.isHidden = address == nil
        review.title = picks ? "Choose machine…" : "Review link…"
        canAnswer = context.model?.canAnswerLinkRequests?() == true
        submitting = item.ui.secretSubmitting
        error = item.ui.secretError
        decline.isEnabled = !submitting
        review.isEnabled = !submitting
        let pending = display == .pending
        for v in [card, title] as [NSView] { v.isHidden = !pending }
        decline.isHidden = !pending || !canAnswer
        review.isHidden = !pending || !canAnswer
        note.isHidden = !pending || canAnswer
        if !pending { reason.isHidden = true; url.isHidden = true; errorLabel.isHidden = true }
        lineIcon.isHidden = pending
        lineLabel.isHidden = pending
        if case .line(let icon, let text) = display {
            if icon != lineIconName {
                lineIcon.removeFromSuperview()
                lineIcon = IconView(name: icon, size: 14)
                lineIconName = icon
                addSubview(lineIcon)
            }
            lineLabel.text = text
        }
        restyle()
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); restyle() }

    private func restyle() {
        card.fill = TL.c(\.card)
        card.border = TL.c(\.border, 0.6)
        title.color = TL.c(\.foreground)
        url.color = TL.c(\.mutedForeground, 0.8)
        note.color = TL.c(\.mutedForeground)
        lineIcon.strokeColor = TL.c(\.iconMuted)
        lineLabel.color = TL.c(\.secondaryLabel)
    }

    /// `p-4 gap-3`: the text block (`gap-1`), the error, then the actions or the note.
    override func height(forWidth width: CGFloat) -> CGFloat {
        guard display == .pending else { return 2 + 24 + 2 + 8 }
        let inner = max(0, width - 2 - 32)
        var h: CGFloat = 1 + 16 + 20
        if !reason.isHidden { h += 4 + reason.height(forWidth: inner) }
        if !url.isHidden { h += 4 + 16 }
        if error != nil { h += 12 + errorLabel.height(forWidth: inner) }
        h += 12 + (canAnswer ? 24 : 16)
        return h + 16 + 1 + 8
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
        if !url.isHidden {
            url.frame = NSRect(x: x, y: y + 4, width: inner, height: 16)
            y += 4 + 16
        }
        if error != nil {
            let h = errorLabel.height(forWidth: inner)
            errorLabel.frame = NSRect(x: x, y: y + 12, width: inner, height: h)
            y += 12 + h
        }
        y += 12
        if canAnswer {
            // `flex justify-end gap-2`.
            let rw = review.intrinsicContentSize.width, dw = decline.intrinsicContentSize.width
            review.frame = NSRect(x: x + inner - rw, y: y, width: rw, height: 24)
            decline.frame = NSRect(x: review.frame.minX - 8 - dw, y: y, width: dw, height: 24)
        } else {
            note.frame = NSRect(x: x, y: y, width: inner, height: 16)
        }
    }
}
