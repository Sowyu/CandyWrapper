import AppKit
import DesignSystem
import T3Protocol

/// `PullRequestThreadDialog` (PullRequestThreadDialog.tsx:216-333): "Checkout pull request", the
/// reference input, the resolved pull request's card, "Resolving pull request...", the error, then
/// Cancel, Local and Worktree. The caller resolves the reference (`git.resolvePullRequest`, 450 ms
/// after typing stops) and runs `git.preparePullRequestThread`.
@MainActor
public final class PullRequestThreadDialog {
    public let dialog: DialogView
    public let input = InputView(placeholder: "PR URL, checkout command, or #42")
    public let cancel = ButtonView("Cancel", variant: .outline, size: .sm)
    public let local = ButtonView("Local", variant: .outline, size: .sm)
    public let worktree = ButtonView("Worktree", variant: .default, size: .sm)
    private let fields: Fields
    private var dirty = false
    /// The parsed reference (`parsePullRequestReference`), nil when the text is not one.
    public private(set) var reference: String?
    public var resolved: GitResolvedPullRequest? { didSet { update() } }
    public var resolving = false { didSet { update() } }
    public var resolveError: String? { didSet { update() } }
    public var prepareError: String? { didSet { update() } }
    /// "local" or "worktree" while that one runs.
    public var preparing: String? { didSet { update() } }
    /// `AuthOrchestrationOperateScope`: without it the worktree mode is off.
    public var canOperateThread = true { didSet { update() } }
    public var canWrite = true { didSet { update() } }
    public var onReference: ((String?) -> Void)?
    public var onConfirm: ((_ mode: String, _ reference: String) -> Void)?

    public init(initialReference: String?) {
        dialog = DialogView(kind: .dialog, title: "Checkout pull request",
                            message: "Resolve a GitHub pull request, then create the draft thread in the main repo or in a dedicated worktree.")
        dialog.maxWidth = 576
        fields = Fields(input: input)
        dialog.panelContent = [fields]
        dialog.footerButtons = [cancel, local, worktree]
        input.text = initialReference ?? ""
        input.setAccessibilityLabel("Pull request")
        input.onChange = { [weak self] _ in self?.dirty = true; self?.changed() }
        // Enter takes the worktree, like T3 (lines 249-260).
        input.onSubmit = { [weak self] in self?.confirm("worktree") }
        local.action = { [weak self] in self?.confirm("local") }
        worktree.action = { [weak self] in self?.confirm("worktree") }
        reference = ChangeRequestURL.reference(input.text)
        update()
    }

    /// The text moved: the caller resolves the new reference after its debounce.
    private func changed() {
        reference = ChangeRequestURL.reference(input.text)
        resolved = nil
        resolveError = nil
        prepareError = nil
        onReference?(reference)
        update()
    }

    private func confirm(_ mode: String) {
        guard preparing == nil, !resolving else { return }
        guard let reference else { dirty = true; update(); return }
        guard resolved != nil, mode == "local" || canOperateThread else { return }
        prepareError = nil
        onConfirm?(mode, reference)
    }

    private func update() {
        let error = PullRequestWriteLogic.checkoutValidation(input.text, dirty: dirty) ?? prepareError ?? (resolved == nil ? resolveError : nil)
        fields.set(resolved: resolved, resolving: resolving && resolved == nil && reference != nil, error: error)
        let ready = canWrite && resolved != nil && !resolving && preparing == nil
        local.isEnabled = ready
        worktree.isEnabled = ready && canOperateThread
        local.title = preparing == "local" ? "Preparing local..." : "Local"
        worktree.title = preparing == "worktree" ? "Preparing worktree..." : "Worktree"
        cancel.isEnabled = preparing == nil
        fields.invalidateIntrinsicContentSize()
        fields.needsLayout = true
        dialog.invalidateIntrinsicContentSize()
        dialog.needsLayout = true
        dialog.superview?.needsLayout = true
    }

    /// `DialogPanel`: the labelled input (`grid gap-1.5`), the card, the resolving line, the error.
    final class Fields: DSView {
        let input: InputView
        private let label = LabelView("Pull request", font: DSFont.ui(12, weight: .medium))
        private let card = DSView()
        private let cardTitle = LabelView("", font: DSFont.ui(14, weight: .medium))
        private let cardDetail = LabelView("", font: DSFont.ui(12))
        private let cardState = LabelView("", font: DSFont.ui(12))
        private let spinner = SpinnerView(size: .sm)
        private let resolvingLabel = LabelView("Resolving pull request...", font: DSFont.ui(12))
        private let error = TextBlockView()
        private var stateValue = ""

        init(input: InputView) {
            self.input = input
            super.init(frame: .zero)
            label.lineHeight = 16
            card.wantsLayer = true
            card.layer?.cornerRadius = 12
            card.layer?.borderWidth = 1
            cardTitle.lineHeight = 20
            for l in [cardDetail, cardState, resolvingLabel] { l.lineHeight = 16 }
            error.font = DSFont.ui(12)
            error.lineHeight = 16
            [cardTitle, cardDetail, cardState].forEach(card.addSubview)
            [label, input, card, spinner, resolvingLabel, error].forEach(addSubview)
        }

        func set(resolved: GitResolvedPullRequest?, resolving: Bool, error text: String?) {
            card.isHidden = resolved == nil
            if let r = resolved {
                cardTitle.text = r.title
                cardDetail.text = "#\(r.number) · \(r.headBranch) to \(r.baseBranch)"
                cardState.text = r.state.prefix(1).uppercased() + r.state.dropFirst()
                stateValue = r.state
            }
            spinner.isHidden = !resolving
            resolvingLabel.isHidden = !resolving
            error.text = text ?? ""
            error.isHidden = text == nil
            restyle()
        }

        private var sections: [CGFloat] {
            var s: [CGFloat] = [16 + 6 + 32]
            if !card.isHidden { s.append(1 + 12 + 20 + 16 + 12 + 1) }
            if !resolvingLabel.isHidden { s.append(16) }
            if !error.isHidden { s.append(error.height(forWidth: max(1, bounds.width))) }
            return s
        }

        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: sections.reduce(0, +) + CGFloat(sections.count - 1) * 16)
        }

        override func layout() {
            super.layout()
            let w = bounds.width
            label.frame = NSRect(x: 0, y: 0, width: w, height: 16)
            input.frame = NSRect(x: 0, y: 22, width: w, height: 32)
            var y: CGFloat = 54 + 16
            if !card.isHidden {
                let h: CGFloat = 1 + 12 + 20 + 16 + 12 + 1
                card.frame = NSRect(x: 0, y: y, width: w, height: h)
                let sw = ceil(cardState.textWidth) + 1
                cardState.frame = NSRect(x: w - 13 - sw, y: 13 + 2, width: sw, height: 16)
                cardTitle.frame = NSRect(x: 13, y: 13, width: max(0, w - 26 - sw - 12), height: 20)
                cardDetail.frame = NSRect(x: 13, y: 33, width: max(0, w - 26 - sw - 12), height: 16)
                y += h + 16
            }
            if !resolvingLabel.isHidden {
                spinner.frame = NSRect(x: 0, y: y, width: 16, height: 16)
                resolvingLabel.frame = NSRect(x: 24, y: y, width: max(0, w - 24), height: 16)
                y += 16 + 16
            }
            if !error.isHidden { error.frame = NSRect(x: 0, y: y, width: w, height: error.height(forWidth: w)) }
        }

        private func restyle() {
            label.color = Themed.color(\.foreground)
            card.layer?.borderColor = Themed.color(\.border, 0.7).cgColor(in: self)
            card.layer?.backgroundColor = Themed.color(\.muted, 0.24).cgColor(in: self)
            cardTitle.color = Themed.color(\.foreground)
            cardDetail.color = Themed.color(\.mutedForeground)
            cardState.color = switch stateValue {
            case "merged": Themed.base("violet-600", 1, dark: "violet-300", 0.9)
            case "closed": Themed.base("zinc-500", 1, dark: "zinc-400", 0.8)
            case "open": Themed.base("emerald-600", 1, dark: "emerald-300", 0.9)
            default: Themed.color(\.mutedForeground)
            }
            resolvingLabel.color = Themed.color(\.mutedForeground)
            error.color = Themed.color(\.destructiveForeground)
        }

        override func updateLayer() { restyle() }
    }
}
