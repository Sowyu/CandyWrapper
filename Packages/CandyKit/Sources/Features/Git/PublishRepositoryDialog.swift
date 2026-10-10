import AppKit
import DesignSystem
import T3Protocol

/// `PublishRepositoryDialog` (GitActionsControl.tsx:531-1050): a three-step wizard. Provider picks a host whose
/// command-line tool is installed and signed in (others read "Setup Required"); Repository takes `owner/name`
/// under the host, the visibility, and in Advanced the remote name and protocol; Summary shows the result.
/// `onPublish` gets the `sourceControl.publishRepository` payload minus `cwd`; call `finish` or `fail` after.
// ponytail: the steps sit in the panel, not in the header, and the panel has no zinc tint (`WizardPanel`);
// no fidelity spec yet. Move them into DialogView's header when the wizard gets one.
@MainActor
public final class PublishRepositoryDialog {
    public let dialog: DialogView
    public let back = ButtonView("Cancel", variant: .outline, size: .default)
    public let next = ButtonView("Next", variant: .default, size: .default)
    public var onPublish: (@MainActor (_ provider: String, _ repository: String, _ visibility: String, _ remote: String, _ proto: String) -> Void)?
    public var onOpenSettings: (@MainActor () -> Void)?
    public var onOpenURL: (@MainActor (String) -> Void)?
    public var onClose: (@MainActor () -> Void)?

    let discovered: [SourceControlProviderDiscovery]
    let canWrite: Bool
    private let steps = WizardStepsView(steps: ["Provider", "Repository", "Summary"])
    private let body = PublishBodyView()
    private(set) var step = 0
    private(set) var selectedProvider: String?
    private var repositoryOverride: String?
    private(set) var visibility = "private"
    private(set) var pending = false
    private var result: SourceControlPublishResult?

    public init(discovered: [SourceControlProviderDiscovery], canWrite: Bool) {
        self.discovered = discovered
        self.canWrite = canWrite
        dialog = DialogView(kind: .dialog, title: "Publish repository", message: "Pick where to host it, then point us at a repo to push to.")
        dialog.maxWidth = 576
        dialog.panelContent = [steps, body]
        dialog.footerVariant = .bare
        dialog.footerButtons = [back, next]
        steps.onStepChange = { [weak self] i in
            guard let self, self.step != 2, i < 2, i <= self.step else { return }
            self.step = i
            self.refresh()
        }
        body.onProvider = { [weak self] kind in self?.selectedProvider = kind; self?.repositoryOverride = nil; self?.refresh() }
        body.onSetup = { [weak self] in self?.onOpenSettings?() }
        body.repository.onChange = { [weak self] text in self?.repositoryOverride = text; self?.refreshButtons() }
        body.repository.onCommit = { [weak self] _ in self?.submit() }
        body.onVisibility = { [weak self] v in self?.visibility = v; self?.refresh() }
        body.openButton.action = { [weak self] in if let url = self?.result?.repository.url { self?.onOpenURL?(url) } }
        back.action = { [weak self] in self?.goBack() }
        next.action = { [weak self] in self?.goNext() }
        refresh()
    }

    func readiness(_ kind: String) -> (ready: Bool, hint: String?) { GitActionsLogic.publishReadiness(kind, discovered: discovered) }

    /// `publishProvider`: the pick while it is ready, else the first ready provider, else the pick or GitHub.
    var provider: GitActionsLogic.PublishProvider {
        let sorted = GitActionsLogic.sortedPublishProviders(discovered)
        let kind = selectedProvider.flatMap { readiness($0).ready ? $0 : nil }
            ?? sorted.first { readiness($0.kind).ready }?.kind ?? selectedProvider ?? "github"
        return GitActionsLogic.publishProviders.first { $0.kind == kind } ?? GitActionsLogic.publishProviders[0]
    }

    /// The account prefill (`owner/`) unless the user typed.
    var repository: String {
        repositoryOverride ?? discovered.first { $0.kind == provider.kind }?.account.map { "\($0)/" } ?? ""
    }

    var canSubmit: Bool { canWrite && readiness(provider.kind).ready && !pending && GitActionsLogic.isPublishPathValid(repository) }

    private func goBack() {
        if step == 0 || step == 2 { onClose?(); return }
        step -= 1
        refresh()
    }

    private func goNext() {
        switch step {
        case 0: if readiness(provider.kind).ready { step = 1; refresh() }
        case 1: submit()
        default: onClose?()
        }
    }

    private func submit() {
        guard step == 1, canSubmit else { return }
        body.error = nil
        pending = true
        refresh()
        onPublish?(provider.kind, repository, visibility, body.remote.text, body.protocolChoice)
    }

    public func finish(_ result: SourceControlPublishResult) {
        pending = false
        self.result = result
        step = 2
        body.result = (result, provider.label)
        refresh()
    }

    public func fail(_ message: String) {
        pending = false
        body.error = message
        refresh()
    }

    private func refresh() {
        steps.currentStep = step
        steps.summaries = [provider.label, result?.repository.nameWithOwner, nil]
        for (i, v) in steps.stepViews.enumerated() { v.isEnabled = !(step == 2 || i >= 2 || i > step) }
        body.step = step
        body.providers = GitActionsLogic.sortedPublishProviders(discovered).map { option in
            let r = readiness(option.kind)
            return PublishBodyView.ProviderCard(kind: option.kind, label: option.label, ready: r.ready, hint: r.hint,
                                                selected: provider.kind == option.kind && r.ready)
        }
        let host = provider.kind == "forgejo" ? discovered.first { $0.kind == "forgejo" }?.host ?? provider.host : provider.host
        body.hostPrefix = "\(host)/"
        body.providerKind = provider.kind
        if repositoryOverride == nil { body.repository.text = repository }
        body.repository.placeholder = provider.pathPlaceholder
        body.visibility = visibility
        body.pendingText = pending ? "Publishing repository to \(provider.label)..." : nil
        refreshButtons()
        dialog.needsLayout = true
        dialog.superview?.needsLayout = true
    }

    private func refreshButtons() {
        back.title = step == 0 ? "Cancel" : "Back"
        back.isHidden = step == 2
        back.isEnabled = !pending
        switch step {
        case 0:
            next.title = "Next"
            next.isEnabled = readiness(provider.kind).ready
        case 1:
            next.title = pending ? "Publishing..." : "Publish"
            next.isEnabled = canSubmit
        default:
            next.title = "Done"
            next.isEnabled = true
        }
        dialog.footerButtons = step == 2 ? [next] : [back, next]
    }
}

/// The wizard's step content.
final class PublishBodyView: DSView {
    struct ProviderCard: Equatable { var kind: String; var label: String; var ready: Bool; var hint: String?; var selected: Bool }

    var step = 0 { didSet { if step != oldValue { rebuild() } } }
    var providers: [ProviderCard] = [] { didSet { if providers != oldValue { rebuild() } } }
    var providerKind = "github" {
        didSet {
            guard providerKind != oldValue else { return }
            hostIcon.removeFromSuperview()
            hostIcon = IconView(definition: Self.icon(providerKind), size: 14)
            repoBox.addSubview(hostIcon)
            needsLayout = true
            needsDisplay = true
        }
    }
    var hostPrefix = "" { didSet { hostLabel.text = hostPrefix; needsLayout = true } }
    var visibility = "private" { didSet { if visibility != oldValue { rebuild() } } }
    var pendingText: String? { didSet { if pendingText != oldValue { rebuild() } } }
    var error: String? { didSet { if error != oldValue { rebuild() } } }
    var result: (SourceControlPublishResult, String)? { didSet { rebuild() } }
    var onProvider: (@MainActor (String) -> Void)?
    var onSetup: (@MainActor () -> Void)?
    var onVisibility: (@MainActor (String) -> Void)?

    let repository = InputView(placeholder: "owner/repo", size: .default, font: .mono)
    let remote = InputView(placeholder: "origin", text: "origin", size: .default)
    let protocolGroup = ToggleGroupView(variant: .default, items: [("SSH", nil), ("HTTPS", nil)], selected: 0)
    let openButton = ButtonView("Open", variant: .outline, size: .sm)
    var protocolChoice: String { protocolGroup.selectedIndex == 1 ? "https" : "ssh" }
    private var advancedOpen = false
    private let hostLabel = LabelView("", font: DSFont.mono(12))
    private var hostIcon = IconView(name: .brandGitHub, size: 14)
    private let repoBox = BoxView()
    private let advanced = ButtonView("Advanced", icon: .chevronRight, variant: .ghostMuted, size: .xs)
    private var items: [(NSView, CGFloat)] = []
    private var owned: [NSView] = []

    static func icon(_ kind: String) -> IconDefinition {
        switch kind {
        case "github": IconName.brandGitHub.definition
        case "gitlab": IconName.brandGitLab.definition
        case "forgejo": IconName.brandForgejo.definition
        // ponytail: Bitbucket and Azure DevOps glyphs use gradients scripts/extract-icons skips; a generic cloud stands in
        default: IconName.cloud.definition
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        repository.unstyled = true
        repoBox.addSubview(hostIcon)
        repoBox.addSubview(hostLabel)
        repoBox.addSubview(repository)
        advanced.action = { [weak self] in self?.advancedOpen.toggle(); self?.rebuild() }
        protocolGroup.onChange = { [weak self] i in if i == nil { self?.protocolGroup.selectedIndex = 0 } }
        rebuild()
    }

    private func label(_ text: String, size: CGFloat = 12, weight: NSFont.Weight = .medium, muted: Bool = false) -> LabelView {
        let l = LabelView(text, font: DSFont.ui(size, weight: weight), color: muted ? Themed.color(\.contrastMutedForeground) : Themed.color(\.contrastForeground))
        l.lineHeight = size == 12 ? 16 : 20
        return l
    }

    private func rebuild() {
        owned.forEach { $0.removeFromSuperview() }
        owned = []
        items = []
        func add(_ v: NSView, _ h: CGFloat) { addSubview(v); owned.append(v); items.append((v, h)) }
        switch step {
        case 0:
            add(label("Provider"), 16)
            let grid = PublishCardGrid(cards: providers.map { p in
                let card = PublishChoiceCard(icon: Self.icon(p.kind), title: p.label, description: nil, selected: p.selected, ready: p.ready, hint: p.hint)
                card.action = { [weak self] in self?.onProvider?(p.kind) }
                card.onSetup = { [weak self] in self?.onSetup?() }
                return card
            }, rowHeight: 48)
            add(grid, grid.height)
        case 1:
            add(label("Repository"), 16)
            add(repoBox, 38)
            add(Spacer(), 12)
            add(label("Visibility"), 16)
            let cards = [("private", "Private", "Only invited people", IconName.lock), ("public", "Public", "Anyone on the web", IconName.globe)].map { v in
                let card = PublishChoiceCard(icon: v.3.definition, title: v.1, description: v.2, selected: visibility == v.0, ready: true, hint: nil)
                card.action = { [weak self] in self?.onVisibility?(v.0) }
                return card
            }
            let grid = PublishCardGrid(cards: cards, rowHeight: 58)
            add(grid, grid.height)
            add(Spacer(), 12)
            advanced.icon = advancedOpen ? .chevronDown : .chevronRight
            add(advanced, 24)
            if advancedOpen {
                let row = AdvancedRow(remote: remote, protocolGroup: protocolGroup, remoteLabel: label("Remote"), protocolLabel: label("Protocol"))
                add(row, 60)
            }
            if let pendingText {
                add(Spacer(), 12)
                add(NoteView(text: pendingText, tone: .muted), 34)
            } else if let error {
                add(Spacer(), 12)
                add(NoteView(text: "Publish failed\n\(error)", tone: .destructive), 52)
            }
        default:
            if let (r, providerLabel) = result {
                let title = r.status == "pushed" ? "Repository published" : "Repository created"
                let text = r.status == "pushed" ? "\(r.branch) is now live on \(providerLabel)." : "Remote \"\(r.remoteName)\" is set up. Make a commit and push it to share your code."
                let head = label(title, size: 14, weight: .semibold)
                head.alignment = .center
                add(head, 20)
                let body = label(text, size: 12, weight: .regular, muted: true)
                body.alignment = .center
                add(body, 16)
                add(Spacer(), 8)
                add(NoteView(text: r.repository.nameWithOwner, tone: .muted), 34)
                openButton.title = "Open on \(providerLabel)"
                add(openButton, 28)
            } else {
                add(NoteView(text: "Publish result unavailable.", tone: .muted), 34)
            }
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
        superview?.needsLayout = true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: items.reduce(0) { $0 + $1.1 } + CGFloat(max(0, items.count - 1)) * 8)
    }

    override func layout() {
        super.layout()
        var y: CGFloat = 0
        for (v, h) in items {
            var x: CGFloat = 0, w = bounds.width
            if v === advanced { w = advanced.intrinsicContentSize.width }
            if let l = v as? LabelView, l.alignment != .center { w = min(w, ceil(l.textWidth) + 1) }
            if v === openButton { x = 0; w = bounds.width }
            v.frame = NSRect(x: x, y: y, width: w, height: h)
            y += h + 8
        }
        // The host prefix: `border-r bg-muted/50 px-2.5 font-mono text-xs`, then the input.
        let prefixW = 10 + 14 + 6 + ceil(hostLabel.textWidth) + 10
        hostIcon.frame = NSRect(x: 10, y: 12, width: 14, height: 14)
        hostLabel.frame = NSRect(x: 30, y: 11, width: ceil(hostLabel.textWidth), height: 16)
        repository.frame = NSRect(x: prefixW + 1, y: 1, width: max(0, repoBox.bounds.width - prefixW - 2), height: 36)
    }

    override func updateLayer() {
        var box = BoxStyle()
        box.radius = 8
        box.border = Themed.color(\.input)
        box.fill = Themed.color(\.background)
        repoBox.boxStyle = box
        hostLabel.color = Themed.color(\.contrastMutedForeground)
        hostIcon.strokeColor = Themed.color(\.contrastMutedForeground)
    }

    private final class Spacer: NSView {}

    private final class AdvancedRow: DSView {
        init(remote: InputView, protocolGroup: ToggleGroupView, remoteLabel: LabelView, protocolLabel: LabelView) {
            super.init(frame: .zero)
            for v in [remote, protocolGroup, remoteLabel, protocolLabel] as [NSView] { addSubview(v) }
        }
        override func layout() {
            super.layout()
            let w = (bounds.width - 12) / 2
            subviews[2].frame = NSRect(x: 0, y: 0, width: w, height: 16)
            subviews[0].frame = NSRect(x: 0, y: 22, width: w, height: 32)
            subviews[3].frame = NSRect(x: w + 12, y: 0, width: w, height: 16)
            let s = subviews[1].intrinsicContentSize
            subviews[1].frame = NSRect(x: w + 12, y: 22, width: s.width, height: max(32, s.height))
        }
    }
}

/// A grid of radio cards, two columns.
final class PublishCardGrid: DSView {
    let cards: [PublishChoiceCard]
    let rowHeight: CGFloat
    init(cards: [PublishChoiceCard], rowHeight: CGFloat) {
        self.cards = cards
        self.rowHeight = rowHeight
        super.init(frame: .zero)
        cards.forEach(addSubview)
    }
    var height: CGFloat { CGFloat((cards.count + 1) / 2) * rowHeight + CGFloat(max(0, (cards.count + 1) / 2 - 1)) * 8 }
    override func layout() {
        super.layout()
        let w = (bounds.width - 8) / 2
        for (i, c) in cards.enumerated() {
            c.frame = NSRect(x: CGFloat(i % 2) * (w + 8), y: CGFloat(i / 2) * (rowHeight + 8), width: w, height: rowHeight)
        }
    }
}

/// A provider or visibility card (`RadioPrimitive.Root`): radius 10, `px-3 py-3` (`py-2.5` with a description),
/// a 20pt (16pt) icon, the title in 14pt medium and the description in 12pt muted. Selected: primary border and
/// a 2pt `primary/35` ring (dark: `primary/10` fill and a 1pt `primary/30` ring). Not ready: 64% with a
/// "Setup Required" button that opens Settings, its hint in the tooltip.
final class PublishChoiceCard: ControlView {
    var onSetup: (@MainActor () -> Void)?
    private let decoration = BoxDecorationLayer()
    private let iconView: IconView
    private let title = LabelView()
    private let detail = LabelView()
    private let selected: Bool
    private let ready: Bool
    private let setup = ButtonView("Setup Required", variant: .warningOutline, size: .micro)

    init(icon: IconDefinition, title text: String, description: String?, selected: Bool, ready: Bool, hint: String?) {
        self.selected = selected
        self.ready = ready
        iconView = IconView(definition: icon, size: description == nil ? 20 : 16)
        super.init(frame: .zero)
        scalesWhenPressed = false
        decoration.host = self
        layer?.addSublayer(decoration)
        layer?.masksToBounds = false
        title.text = text
        title.font = DSFont.ui(14, weight: .medium)
        title.lineHeight = 20
        detail.text = description ?? ""
        detail.font = DSFont.ui(12)
        detail.lineHeight = 16
        detail.isHidden = description == nil
        for v in [iconView, title, detail] as [NSView] { addSubview(v) }
        if !ready {
            addSubview(setup)
            setup.action = { [weak self] in self?.onSetup?() }
            TooltipController.attach(to: setup, text: hint ?? "Open Settings -> Source Control to configure this provider.")
            alphaValue = 0.64
        }
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(text)
        setAccessibilityValue(selected)
    }

    override func performAction() {
        guard ready else { return }
        super.performAction()
    }

    override func layout() {
        super.layout()
        decoration.layout(boxSize: bounds.size)
        let s: CGFloat = detail.isHidden ? 20 : 16
        iconView.frame = NSRect(x: 12, y: (bounds.height - s) / 2, width: s, height: s)
        var right = bounds.width - 12
        if !ready {
            let w = setup.intrinsicContentSize.width
            setup.frame = NSRect(x: right - w, y: (bounds.height - 20) / 2, width: w, height: 20)
            right -= w + 12
        }
        let x = 12 + s + 12
        if detail.isHidden {
            title.frame = NSRect(x: x, y: (bounds.height - 20) / 2, width: max(0, right - x), height: 20)
        } else {
            title.frame = NSRect(x: x, y: (bounds.height - 36) / 2, width: max(0, right - x), height: 20)
            detail.frame = NSRect(x: x, y: (bounds.height - 36) / 2 + 20, width: max(0, right - x), height: 16)
        }
    }

    override func stateDidChange(from old: State) {
        super.stateDidChange(from: old)
        needsDisplay = true
    }

    override func updateLayer() {
        let dark = effectiveAppearance.isDark
        var box = BoxStyle()
        box.radius = 10
        if selected {
            box.fill = dark ? Themed.color(\.primary, 0.1) : Themed.color(\.background)
            box.border = dark ? .clear : Themed.color(\.primary)
            box.shadows = [BoxShadow(spread: dark ? 1 : 2, color: Themed.color(\.primary, dark ? 0.3 : 0.35))]
        } else {
            let hover = ready && state.hovered
            box.fill = dark ? (hover ? Themed.color(\.accent) : Themed.white(0.035)) : (hover ? Themed.color(\.muted, 0.5) : Themed.color(\.background))
            box.border = dark ? .clear : Themed.color(\.border)
        }
        decoration.boxStyle = box
        title.color = Themed.color(\.contrastForeground)
        detail.color = Themed.color(\.contrastMutedForeground)
        iconView.strokeColor = ready && detail.isHidden ? Themed.color(\.contrastForeground) : Themed.color(\.contrastMutedForeground)
    }
}

/// A one- or two-line note box: the pending status (`border-input bg-muted/40 text-xs muted`) or the error
/// (`border-destructive/40 bg-destructive/10 text-destructive`).
final class NoteView: DSView {
    enum Tone { case muted, destructive }
    private let lines: [LabelView]
    private let tone: Tone
    private let decoration = BoxDecorationLayer()

    init(text: String, tone: Tone) {
        self.tone = tone
        lines = text.split(separator: "\n").enumerated().map { i, s in
            let l = LabelView(String(s), font: DSFont.ui(12, weight: i == 0 && tone == .destructive ? .medium : .regular))
            l.lineHeight = 16
            return l
        }
        super.init(frame: .zero)
        decoration.host = self
        layer?.addSublayer(decoration)
        lines.forEach(addSubview)
    }

    override func layout() {
        super.layout()
        decoration.layout(boxSize: bounds.size)
        let total = CGFloat(lines.count) * 16 + CGFloat(lines.count - 1) * 2
        var y = (bounds.height - total) / 2
        for l in lines { l.frame = NSRect(x: 12, y: y, width: bounds.width - 24, height: 16); y += 18 }
    }

    override func updateLayer() {
        var box = BoxStyle()
        box.radius = 8
        switch tone {
        case .muted:
            box.fill = effectiveAppearance.isDark ? Themed.white(0.035) : Themed.color(\.muted, 0.4)
            box.border = effectiveAppearance.isDark ? .clear : Themed.color(\.input)
            lines.forEach { $0.color = Themed.color(\.contrastMutedForeground) }
        case .destructive:
            box.fill = Themed.color(\.destructive, 0.1)
            box.border = Themed.color(\.destructive, 0.4)
            lines.forEach { $0.color = Themed.color(\.destructive) }
        }
        decoration.boxStyle = box
    }
}
