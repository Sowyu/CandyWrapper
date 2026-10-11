import AppKit
import QuartzCore
import DesignSystem

/// T3's `SidebarUpdatePill` (sidebar/SidebarUpdatePill.tsx:115-419): the 32px round update button at the
/// end of the sidebar utility row, with `DesktopUpdateStatusIcon` (sidebar/DesktopUpdateStatusIcon.tsx)
/// inside. Its tooltip is the state's description; on the nightly track with release notes the notes
/// popover takes the tooltip's place (:159-162, 362-415). The app owns the update state and the actions.
public final class SidebarUpdatePillView: ControlView {
    /// The icon `resolveSidebarUpdatePresentation` picks (SidebarUpdatePill.tsx:64-89).
    enum IconStatus: Equatable { case idle, checking, available, downloading, downloaded }

    /// Nil until the app has read the updater's state (`useDesktopUpdateState`).
    public var update: DesktopUpdateState? { didSet { if update != oldValue { stateChanged(from: oldValue) } } }
    /// Set by the app while a check, download or install it started is running (`isActionPending`).
    public var isActionPending = false { didSet { if isActionPending != oldValue { refresh() } } }
    public var onCheck: (() -> Void)?
    public var onDownload: (() -> Void)?
    public var onInstall: (() -> Void)?
    /// A release link in the notes popover (`openDesktopUpdateReleaseNotes`).
    public var onOpenURL: ((String) -> Void)?

    /// `isCheckAnimationLatched`: the spin finishes its turn after the check ends (:126-132, 291-298).
    private(set) var checkLatched = false
    private var spinning = false
    private var finishing = false
    private var spinGeneration = 0
    private var shownIcon: IconStatus?
    private let decoration = BoxDecorationLayer()
    private let iconBox = DSView()
    private var glyph: IconView?
    private let ringTrack = CAShapeLayer()
    private let ringArc = CAShapeLayer()
    private let dotRing = CALayer()
    private let dot = CALayer()
    private let badge = CALayer()
    private let badgeFill = CALayer()
    private var badgeCheck: IconView?
    private lazy var tooltip = TooltipController.attach(to: self, text: "")
    private var hoverWork: DispatchWorkItem?
    private var notesPopup: OpenPopup?
    private var pointerInNotes = false

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        decoration.host = self
        layer?.addSublayer(decoration)
        layer?.masksToBounds = false
        scalesWhenPressed = false
        transitions = .colors // `transition-colors`
        iconBox.layer?.masksToBounds = false
        addSubview(iconBox)
        for l in [ringTrack, ringArc] {
            l.fillColor = nil
            l.lineWidth = 1.5
            l.actions = ["path": NSNull(), "strokeColor": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
            layer?.addSublayer(l)
        }
        ringArc.lineCap = .round
        ringArc.strokeEnd = 0
        for l in [dotRing, dot, badge, badgeFill] {
            l.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
            iconBox.layer?.addSublayer(l)
        }
        setAccessibilityRole(.button)
        refresh()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    public override var intrinsicContentSize: NSSize { NSSize(width: 32, height: 32) }

    // MARK: Presentation (SidebarUpdatePill.tsx:134-162)

    var buttonAction: DesktopUpdateLogic.ButtonAction { update.map(DesktopUpdateLogic.buttonAction) ?? .none }
    private var isDownloading: Bool { update?.status == .downloading }
    /// `shouldShowDesktopUpdateCheckIcon` (DesktopUpdateStatusIcon.tsx:20-30).
    var showCheckIcon: Bool { update?.status == .checking || (checkLatched && !Motion.reduced) }
    var showUpdateDetails: Bool { buttonAction != .none || isDownloading }
    var iconStatus: IconStatus {
        if showCheckIcon { return .checking }
        if buttonAction == .install { return .downloaded }
        if isDownloading { return .downloading }
        return buttonAction == .download ? .available : .idle
    }
    private var showUpdateIconState: Bool { showUpdateDetails && !showCheckIcon }
    var tooltipText: String {
        if showUpdateDetails { return update.map(DesktopUpdateLogic.buttonTooltip) ?? "Update available" }
        return showCheckIcon ? "Checking for updates…" : "Check for updates"
    }
    private var disabled: Bool {
        if showCheckIcon { return true }
        return showUpdateDetails ? DesktopUpdateLogic.isButtonDisabled(update) : !DesktopUpdateLogic.canCheck(update)
    }
    var isInteractionDisabled: Bool { disabled || isActionPending }
    var showsReleaseNotes: Bool { DesktopUpdateLogic.showsReleaseNotesPopover(showUpdateDetails: showUpdateDetails, update) }

    private func stateChanged(from old: DesktopUpdateState?) {
        // :126-132: a check that starts latches the spin.
        if update?.status == .checking, !Motion.reduced, window != nil { checkLatched = true } // nothing spins off screen
        refresh()
    }

    private func refresh() {
        let status = iconStatus
        if status != shownIcon { rebuildIcon(status) }
        updateProgress(animated: true)
        updateSpin()
        let text = tooltipText
        // `<Tooltip disabled={showReleaseNotesPopover}>`: an empty text never opens.
        tooltip.text = showsReleaseNotes ? "" : text
        tooltip.variant = showUpdateDetails ? .glass : .default
        setAccessibilityLabel(text)
        setAccessibilityEnabled(!isInteractionDisabled)
        if showsReleaseNotes {
            tooltip.hide()
        } else {
            closeNotes()
        }
        if let open = notesPopup, let notes = open.content as? SidebarUpdateReleaseNotesView, let update {
            notes.configure(update, tooltip: text)
            window.map { PopupHost.host(for: $0).reposition(open) }
        }
        window?.invalidateCursorRects(for: self)
        restyle()
    }

    // MARK: Look

    public override func stateDidChange(from old: State) {
        super.stateDidChange(from: old)
        restyle()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        decoration.setNeedsDisplay()
        restyle()
    }

    private func restyle() {
        var box = BoxStyle()
        box.radius = 16
        box.border = nil
        let enabled = !isInteractionDisabled
        let fg = Themed.color(\.contrastSidebarForeground, sidebar: true)
        var color = Themed.color(\.sidebarIconColor, sidebar: true)
        if showUpdateIconState {
            box.fill = Themed.color(\.sidebarControlSurface, sidebar: true)
            color = fg
            if enabled, state.hovered { box.fill = Themed.color(\.sidebarRowHover, sidebar: true) }
        } else if enabled, state.hovered {
            box.fill = Themed.color(\.sidebarRowHover, sidebar: true)
            color = fg
        }
        if state.focusVisible { box.shadows = [BoxShadow(spread: 2, color: Themed.color(\.ring))] }
        decoration.boxStyle = box
        alphaValue = disabled && !showUpdateIconState ? 0.6 : 1
        glyph?.strokeColor = color
        let cg = color.cgColor(in: self)
        ringTrack.strokeColor = cg.copy(alpha: cg.alpha * 0.22)
        ringArc.strokeColor = cg
        dot.backgroundColor = cg
        dotRing.backgroundColor = Themed.color(\.sidebarControlSurface, sidebar: true).cgColor(in: self)
        badge.backgroundColor = Themed.color(\.background).cgColor(in: self)
        badgeFill.backgroundColor = Themed.color(\.contrastForeground).cgColor(in: self)
        badgeCheck?.strokeColor = Themed.color(\.background)
    }

    public override func layout() {
        super.layout()
        decoration.layout(boxSize: bounds.size)
        iconBox.frame = NSRect(x: (bounds.width - 16) / 2, y: (bounds.height - 16) / 2, width: 16, height: 16)
        glyph?.frame = iconBox.bounds
        // The ring: a 32px SVG, r 14, turned -90deg so it starts at the top and runs clockwise.
        let ring = CGMutablePath()
        ring.addArc(center: CGPoint(x: 16, y: 16), radius: 14, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        for l in [ringTrack, ringArc] { l.frame = bounds; l.path = ring }
        // iconBox is flipped like every DSView: y runs down, as in CSS.
        dotRing.frame = CGRect(x: 10, y: -4, width: 10, height: 10); dotRing.cornerRadius = 5      // ring-2 around a size-1.5 dot
        dot.frame = CGRect(x: 12, y: -2, width: 6, height: 6); dot.cornerRadius = 3                // -top-0.5 -right-0.5
        badge.frame = CGRect(x: 8, y: 8, width: 14, height: 14); badge.cornerRadius = 7            // ring-2 ring-background
        badgeFill.frame = CGRect(x: 10, y: 10, width: 10, height: 10); badgeFill.cornerRadius = 5  // -right-1 -bottom-1 size-2.5
        badgeCheck?.frame = NSRect(x: 11, y: 11, width: 8, height: 8)
    }

    /// `DesktopUpdateStatusIcon` (DesktopUpdateStatusIcon.tsx:102-126). T3 remounts it on a status change.
    private func rebuildIcon(_ status: IconStatus) {
        stopSpin()
        shownIcon = status
        glyph?.removeFromSuperview()
        let name: IconName = switch status {
        case .idle, .checking: .refreshCw
        case .available, .downloading: .download
        case .downloaded: .rotateCw
        }
        let g = IconView(name: name, size: 16)
        iconBox.addSubview(g, positioned: .below, relativeTo: nil)
        glyph = g
        dotRing.isHidden = status != .available
        dot.isHidden = status != .available
        badge.isHidden = status != .downloaded
        badgeFill.isHidden = status != .downloaded
        badgeCheck?.removeFromSuperview()
        badgeCheck = nil
        if status == .downloaded {
            let check = IconView(name: .check, size: 8)
            check.strokeWidth = 3
            iconBox.addSubview(check)
            badgeCheck = check
        }
        ringTrack.isHidden = status != .downloading
        ringArc.isHidden = status != .downloading
        updateProgress(animated: false)
        needsLayout = true
        layoutSubtreeIfNeeded()
        restyle()
    }

    /// The progress arc: `stroke-dashoffset` with `transition-[stroke-dashoffset] duration-300 ease-out`.
    private func updateProgress(animated: Bool) {
        let percent = min(100, max(0, update?.downloadPercent ?? 0))
        let end = CGFloat(percent / 100)
        guard ringArc.strokeEnd != end else { return }
        if animated, !ringArc.isHidden, window != nil, !Motion.reduced {
            let a = CABasicAnimation(keyPath: "strokeEnd")
            a.fromValue = ringArc.presentation()?.strokeEnd ?? ringArc.strokeEnd
            a.toValue = end
            a.duration = 0.3
            a.timingFunction = CAMediaTimingFunction(controlPoints: 0, 0, 0.2, 1)
            ringArc.add(a, forKey: "progress")
        }
        ringArc.strokeEnd = end
    }

    // MARK: Check spin (`RefreshIcon refreshing`, animate-spin: one turn a second)

    private var spinLayers: [CALayer] { glyph?.shapeLayers ?? [] }

    private func updateSpin() {
        guard iconStatus == .checking, !Motion.reduced else { return stopSpin() }
        if update?.status == .checking { startSpin(restart: false) }
        else if spinning { finishTurn() }
        else { releaseLatch() }
    }

    private func startSpin(restart: Bool) {
        // While a turn is finishing, `turnFinished` spins on if a check started again.
        if spinning, !restart { return }
        spinning = true
        finishing = false
        spinGeneration += 1
        for l in spinLayers {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -2 * Double.pi // layer space is y up: negative turns clockwise
            spin.duration = 1
            spin.repeatCount = .infinity
            l.add(spin, forKey: "spin")
        }
    }

    /// `onAnimationIteration` re-reads the state: the turn in progress completes, then the latch lets go.
    private func finishTurn() {
        guard !finishing else { return }
        guard let first = spinLayers.first, first.animation(forKey: "spin") != nil else { stopSpin(); return releaseLatch() }
        finishing = true
        let generation = spinGeneration
        let angle = (first.presentation()?.value(forKeyPath: "transform.rotation.z") as? Double) ?? 0
        // `angle` runs 0 to -2pi (pi to -pi as read back); what is left of this turn takes the rest of the second.
        var progress = -angle / (2 * .pi)
        if progress < 0 { progress += 1 }
        let remaining = max(0.01, 1 - progress)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in MainActor.assumeIsolated { self?.turnFinished(generation) } }
        for l in spinLayers {
            let rest = CABasicAnimation(keyPath: "transform.rotation.z")
            rest.fromValue = -progress * 2 * .pi
            rest.toValue = -2 * Double.pi
            rest.duration = remaining
            l.add(rest, forKey: "spin")
        }
        CATransaction.commit()
    }

    private func turnFinished(_ generation: Int) {
        guard generation == spinGeneration, finishing else { return }
        if update?.status == .checking, !Motion.reduced { return startSpin(restart: true) } // checking again: keep turning
        stopSpin()
        releaseLatch()
    }

    private func releaseLatch() {
        guard checkLatched else { return }
        checkLatched = false
        refresh()
    }

    private func stopSpin() {
        spinning = false
        finishing = false
        spinGeneration += 1
        for l in spinLayers { l.removeAnimation(forKey: "spin") }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopSpin(); releaseLatchSilently(); closeNotes() } else { refresh() }
    }

    private func releaseLatchSilently() { checkLatched = false }

    // MARK: Action (SidebarUpdatePill.tsx:176-289)

    public override func performAction() {
        guard update != nil, !isInteractionDisabled else { return }
        switch buttonAction {
        case .download: onDownload?()
        case .install: onInstall?()
        case .none:
            if !Motion.reduced, window != nil {
                checkLatched = true
                startSpin(restart: true)
            }
            onCheck?()
        }
    }

    public override func resetCursorRects() {
        addCursorRect(bounds, cursor: isInteractionDisabled ? .operationNotAllowed : .pointingHand)
    }

    // MARK: Release notes popover (openOnHover, closeDelay 150, side top, center; :352-415)

    public override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard showsReleaseNotes else { return }
        hoverWork?.cancel()
        let instant = notesPopup != nil
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.openNotes() } }
        hoverWork = work
        // base-ui's hover trigger waits 300ms before opening a popover.
        if instant { work.perform() } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work) }
    }

    public override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoverWork?.cancel()
        scheduleNotesClose()
    }

    private func scheduleNotesClose() {
        guard notesPopup != nil else { return }
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.closeNotesUnlessHovered() } }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func closeNotesUnlessHovered() {
        guard !pointerInNotes, let window else { return }
        if bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) { return }
        closeNotes()
    }

    func openNotes() {
        guard notesPopup == nil, showsReleaseNotes, let update, let host = popupHost else { return }
        let notes = SidebarUpdateReleaseNotesView()
        notes.configure(update, tooltip: tooltipText)
        notes.onOpenURL = { [weak self] url in self?.onOpenURL?(url) }
        notes.onPointerInside = { [weak self] inside in
            self?.pointerInNotes = inside
            if !inside { self?.scheduleNotesClose() } else { self?.hoverWork?.cancel() }
        }
        notesPopup = host.open(notes, trigger: self, placement: .tooltip, motion: .popover,
                               pressesTrigger: false, returnsFocus: false, passive: true)
        // The trigger is the update action, so its presses must not also close the popover (:46-52).
        notesPopup?.keepsOpenOnTriggerPress = true
        notesPopup?.onClose = { [weak self] in self?.notesPopup = nil; self?.pointerInNotes = false }
    }

    func closeNotes() {
        hoverWork?.cancel()
        guard let open = notesPopup, let window else { notesPopup = nil; return }
        PopupHost.host(for: window).close(open, returnFocus: false)
        notesPopup = nil
    }

    /// The open notes, for tests.
    var notesView: SidebarUpdateReleaseNotesView? { notesPopup?.content as? SidebarUpdateReleaseNotesView }
}
