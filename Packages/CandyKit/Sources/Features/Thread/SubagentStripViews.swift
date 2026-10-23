import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// Redesign's subagent strip (after Capy's activity strip, docs/research/capy-subagents.md): a pill in the row above
/// the composer with the status glyph, the count and a chevron, which opens `SubagentStripPanelView` over the timeline.
public final class SubagentStripPillView: ComposerBannerView {
    public var onToggle: (() -> Void)?
    public var expanded = false { didSet { if expanded != oldValue { restyle() } } }
    public private(set) var strip = SubagentStrip()

    private let row = BannerRowButton()
    private var glyph: NSView = NSView()
    private var glyphStatus: SubagentStrip.Status?
    private let label = glassLabel("0", font: DSFont.ui(12, weight: .medium), color: Themed.color(\.mutedForeground), lineHeight: 16)
    /// Up while closed, down while open (Capy's `rotate-180`), as two glyphs: rotating a layer-backed view's layer
    /// moved it off its frame.
    private let chevronUp = IconView(name: .chevronUp, size: 12, strokeColor: Themed.color(\.mutedForeground))
    private let chevronDown = IconView(name: .chevronDown, size: 12, strokeColor: Themed.color(\.mutedForeground))

    static let padX: CGFloat = 6, glyphColumn: CGFloat = 24, chevron: CGFloat = 12, gap: CGFloat = 4

    public init() {
        super.init(variant: .neutral)
        placement = .floating
        row.addSubview(label)
        row.addSubview(chevronUp)
        row.addSubview(chevronDown)
        row.action = { [weak self] in self?.onToggle?() }
        row.onHover = { [weak self] _ in self?.restyle() }
        addSubview(row)
        restyle()
    }

    public func configure(_ strip: SubagentStrip) {
        guard strip != self.strip else { return }
        let widthChanged = strip.pillText != self.strip.pillText
        self.strip = strip
        label.text = strip.pillText
        // The pill spins while anything runs; waiting or asking alone shows that glyph instead.
        let status: SubagentStrip.Status = strip.rows.contains { $0.status == .running } ? .running
            : strip.rows.first { !$0.finished }?.status ?? .running
        if status != glyphStatus {
            glyphStatus = status
            glyph.removeFromSuperview()
            glyph = SubagentStripGlyph.make(status, size: 12)
            row.addSubview(glyph)
        }
        updateAccessibility()
        needsLayout = true
        if widthChanged { superview?.needsLayout = true }
    }

    /// Stash's layout: 6 a side, the 24pt glyph column, the label, 4, the chevron, then 6 inside the row.
    public var preferredWidth: CGFloat { 2 * Self.padX + Self.glyphColumn + ceil(label.textWidth) + Self.gap + Self.chevron + 6 }

    private func updateAccessibility() {
        row.setAccessibilityLabel(strip.accessibilityLabel + (expanded ? ". Hide subagents." : ". Show subagents."))
    }

    private func restyle() {
        let strong = expanded || row.state.hovered
        Motion.transitioning(window == nil ? [] : .colors, duration: 0.2) {
            label.color = strong ? Themed.color(\.foreground) : Themed.color(\.mutedForeground)
            for c in [chevronUp, chevronDown] { c.strokeColor = strong ? Themed.color(\.foreground) : Themed.color(\.mutedForeground) }
        }
        chevronUp.isHidden = expanded
        chevronDown.isHidden = !expanded
        updateAccessibility()
    }

    public override func layout() {
        super.layout()
        row.frame = NSRect(x: Self.padX, y: ((bounds.height - 24) / 2).rounded(), width: max(0, bounds.width - 2 * Self.padX), height: 24)
        glyph.frame = NSRect(x: 6, y: 6, width: 12, height: 12)
        label.frame = NSRect(x: Self.glyphColumn, y: 4, width: ceil(label.textWidth), height: 16)
        let chevron = NSRect(x: label.frame.maxX + Self.gap, y: 6, width: Self.chevron, height: Self.chevron)
        chevronUp.frame = chevron
        chevronDown.frame = chevron
    }
}

/// Stop on a row takes two clicks (the user, 2026-10-23, after one stray click stopped a live agent): the first arms
/// that row, a second within `window` seconds stops it. Leaving the row, Esc or the time running out disarms it.
public struct SubagentStopConfirm: Equatable {
    public static let window: TimeInterval = 3
    public private(set) var armed: String?
    private var armedAt: TimeInterval = 0
    public init() {}

    public enum Outcome: Equatable { case armed, stop }

    /// A click on `key`'s Stop at `now`: arms it, or stops it when it was armed less than `window` ago.
    public mutating func press(_ key: String, now: TimeInterval) -> Outcome {
        if armed == key, now - armedAt < Self.window {
            armed = nil
            return .stop
        }
        armed = key
        armedAt = now
        return .armed
    }

    /// Disarms `key`, or whatever is armed when nil. True when something was armed.
    @discardableResult
    public mutating func cancel(_ key: String? = nil) -> Bool {
        guard let current = armed, key == nil || key == current else { return false }
        armed = nil
        return true
    }

    /// Disarms once `window` has passed.
    public mutating func expire(now: TimeInterval) {
        if armed != nil, now - armedAt >= Self.window { armed = nil }
    }
}

/// The open strip, Capy's density: rows of 32pt with 1pt between, 6pt around, sized to its rows and scrolling past
/// `maxHeight`. The pill, Esc or a click outside closes it.
public final class SubagentStripPanelView: ComposerBannerView {
    public struct Item: Equatable {
        public var row: SubagentStrip.Row
        public var modelName: String
        public var stopping: Bool
        public init(row: SubagentStrip.Row, modelName: String, stopping: Bool = false) {
            self.row = row; self.modelName = modelName; self.stopping = stopping
        }
    }

    public var items: [Item] = [] { didSet { if items != oldValue { rebuild() } } }
    public var onOpen: ((SubagentStrip.Row) -> Void)?
    public var onStop: ((SubagentStrip.Row) -> Void)?
    public private(set) var confirm = SubagentStopConfirm()

    static let row: CGFloat = 32, pad: CGFloat = 6, rowGap: CGFloat = 1

    private let list = FlippedDocument()
    private lazy var scroll = ScrollAreaView(documentView: list, scrollFade: true)
    private var rows: [SubagentStripRowView] = []
    private var expiry: DispatchWorkItem?

    public init() {
        super.init(variant: .neutral)
        placement = .floating
        scroll.scrollView.automaticallyAdjustsContentInsets = false
        addSubview(scroll)
        setAccessibilityRole(.list)
        setAccessibilityLabel("Subagents")
    }

    private var listHeight: CGFloat {
        let n = CGFloat(items.count)
        return n == 0 ? 0 : n * Self.row + (n - 1) * Self.rowGap
    }

    public func preferredHeight(maxHeight: CGFloat) -> CGFloat {
        min(maxHeight, Self.pad * 2 + listHeight)
    }

    /// Esc: disarms an armed Stop. True when it did, so the caller leaves the panel open.
    public func cancelStop() -> Bool {
        guard confirm.cancel() else { return false }
        syncArmed()
        return true
    }

    public override func viewDidHide() {
        super.viewDidHide()
        if confirm.cancel() { syncArmed() }
    }

    private func pressStop(_ item: Item) {
        switch confirm.press(item.row.key, now: ProcessInfo.processInfo.systemUptime) {
        case .stop: onStop?(item.row)
        case .armed: scheduleExpiry()
        }
        syncArmed()
    }

    /// One wake to disarm, only while a Stop is armed.
    private func scheduleExpiry() {
        expiry?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.confirm.expire(now: ProcessInfo.processInfo.systemUptime + 0.01)
                self.syncArmed()
            }
        }
        expiry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + SubagentStopConfirm.window, execute: work)
    }

    private func syncArmed() {
        if confirm.armed == nil { expiry?.cancel(); expiry = nil }
        for row in rows { row.armed = row.item?.row.key == confirm.armed }
    }

    private func rebuild() {
        // Rows keep their view while the subagent stays, so a hovered row keeps its Stop under the mouse.
        var old = Dictionary(rows.map { ($0.item?.row.key ?? "", $0) }, uniquingKeysWith: { a, _ in a })
        rows = items.map { item in
            let view = old.removeValue(forKey: item.row.key) ?? SubagentStripRowView()
            view.item = item
            view.onOpen = { [weak self] in self?.onOpen?(item.row) }
            view.onStop = { [weak self] in self?.pressStop(item) }
            view.onLeave = { [weak self] in
                guard let self, self.confirm.cancel(item.row.key) else { return }
                self.syncArmed()
            }
            if view.superview !== list { list.addSubview(view) }
            return view
        }
        old.values.forEach { $0.removeFromSuperview() }
        // An armed row that stopped working or left can no longer stop.
        if let armed = confirm.armed, !items.contains(where: { $0.row.key == armed && $0.row.canStop }) { confirm.cancel() }
        syncArmed()
        needsLayout = true
        superview?.needsLayout = true
    }

    public override func layout() {
        super.layout()
        let w = bounds.width, inner = max(0, w - 2 * Self.pad)
        scroll.frame = NSRect(x: Self.pad, y: Self.pad, width: inner, height: max(0, bounds.height - 2 * Self.pad))
        list.frame = NSRect(x: 0, y: 0, width: inner, height: listHeight)
        for (i, row) in rows.enumerated() {
            row.frame = NSRect(x: 0, y: CGFloat(i) * (Self.row + Self.rowGap), width: inner, height: Self.row)
        }
    }
}

private final class FlippedDocument: NSView {
    override var isFlipped: Bool { true }
}

/// One subagent, Capy's row (`h-8 px-2 gap-2`): the status glyph, "Subagent N", its title, then the provider mark and
/// model at the right. Hover fills it like a menu row; a stoppable row shows an x that arms a red Stop. Finished rows
/// are dimmed.
final class SubagentStripRowView: DSView {
    var item: SubagentStripPanelView.Item? { didSet { if item != oldValue { apply(old: oldValue) } } }
    var armed = false { didSet { if armed != oldValue { updateControls() } } }
    var onOpen: (() -> Void)?
    var onStop: (() -> Void)?
    var onLeave: (() -> Void)?
    private(set) var hovered = false

    private var glyph = NSView()
    private var provider = NSView()
    private let name = glassLabel(font: DSFont.ui(13, weight: .medium), color: Themed.color(\.foreground), lineHeight: 16)
    private let title = glassLabel(font: DSFont.ui(13), color: Themed.color(\.mutedForeground), lineHeight: 16)
    private let model = glassLabel(font: DSFont.ui(12), color: Themed.color(\.mutedForeground), lineHeight: 16)
    let stop = ButtonView(nil, icon: .x, variant: .ghost, size: .iconXs)
    let confirmStop = ButtonView("Stop", variant: .destructive, size: .micro)
    private var trackingArea: NSTrackingArea?

    static let padX: CGFloat = 8, gap: CGFloat = 8, icon: CGFloat = 14

    init() {
        super.init(frame: .zero)
        layer?.cornerRadius = DitherChrome.controlRadius - 2
        title.truncation = .end
        [name, title, model].forEach(addSubview)
        stop.iconSize = 14
        stop.smoothsFont = false
        stop.isHidden = true
        stop.action = { [weak self] in self?.onStop?() }
        addSubview(stop)
        confirmStop.isHidden = true
        confirmStop.action = { [weak self] in self?.onStop?() }
        addSubview(confirmStop)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func apply(old: SubagentStripPanelView.Item?) {
        guard let item else { return }
        let r = item.row
        if old?.row.status != r.status {
            glyph.removeFromSuperview()
            glyph = SubagentStripGlyph.make(r.status, size: Self.icon)
            addSubview(glyph)
        }
        if old?.row.driver != r.driver {
            provider.removeFromSuperview()
            provider = ProviderIcon.make(driver: r.driver, displayName: item.modelName, size: Self.icon, color: Themed.color(\.mutedForeground), model: true)
            addSubview(provider)
        }
        name.text = r.label
        title.text = r.title
        model.text = item.modelName
        alphaValue = r.finished ? 0.55 : 1
        stop.isEnabled = !item.stopping
        confirmStop.isEnabled = !item.stopping
        stop.setAccessibilityLabel("Stop \(r.label)")
        confirmStop.setAccessibilityLabel("Confirm stop \(r.label)")
        setAccessibilityLabel("\(r.label): \(r.title). \(SubagentStripGlyph.label(r.status)). Open subagent.")
        updateControls()
    }

    private func updateControls() {
        let canStop = item?.row.canStop == true
        confirmStop.isHidden = !(armed && canStop)
        stop.isHidden = !(hovered && canStop) || armed
        needsDisplay = true
        needsLayout = true
    }

    override func updateLayer() {
        layer?.backgroundColor = armed ? Themed.color(\.error, 0.08).cgColor(in: self)
            : hovered ? Themed.color(\.foreground, 0.06).cgColor(in: self) : nil
    }

    override func layout() {
        super.layout()
        let h = bounds.height, mid = (h / 2).rounded()
        let i = Self.icon
        glyph.frame = NSRect(x: Self.padX, y: mid - i / 2, width: i, height: i)
        var right = bounds.width - Self.padX
        if !confirmStop.isHidden {
            let w = ceil(confirmStop.intrinsicContentSize.width)
            right -= w
            confirmStop.frame = NSRect(x: right, y: mid - 10, width: w, height: 20)
            right -= Self.gap
        } else if !stop.isHidden {
            right -= 24
            stop.frame = NSRect(x: right, y: mid - 12, width: 24, height: 24)
            right -= 4
        }
        let mw = min(ceil(model.textWidth), 160)
        right -= mw
        model.frame = NSRect(x: right, y: mid - 8, width: mw, height: 16)
        right -= 4 + i
        provider.frame = NSRect(x: right, y: mid - i / 2, width: i, height: i)
        let nx = glyph.frame.maxX + Self.gap
        let nw = ceil(name.textWidth)
        name.frame = NSRect(x: nx, y: mid - 8, width: nw, height: 16)
        let tx = name.frame.maxX + Self.gap
        title.frame = NSRect(x: tx, y: mid - 8, width: max(0, right - Self.gap - tx), height: 16)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false); onLeave?() }
    func setHovered(_ on: Bool) {
        guard on != hovered else { return }
        hovered = on
        updateControls()
    }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onOpen?() }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
enum SubagentStripGlyph {
    /// Running spins (only while shown, `SpinnerView`); the rest are still icons.
    static func make(_ status: SubagentStrip.Status, size: CGFloat) -> NSView {
        let muted = Themed.color(\.mutedForeground)
        let v: NSView = switch status {
        case .running: SpinnerView(size: size >= 14 ? .sm : .xs, tone: .muted)
        case .waiting: IconView(name: .clock, size: size, strokeColor: muted)
        case .needsInput: IconView(name: .messageCircleQuestion, size: size, strokeColor: Themed.color(\.warning))
        case .done: IconView(name: .circleCheck, size: size, strokeColor: muted)
        case .failed: IconView(name: .circleX, size: size, strokeColor: Themed.color(\.error))
        }
        v.setAccessibilityElement(false)
        return v
    }

    static func label(_ status: SubagentStrip.Status) -> String {
        switch status {
        case .running: "Working"
        case .waiting: "Waiting"
        case .needsInput: "Needs input"
        case .done: "Done"
        case .failed: "Failed"
        }
    }
}
