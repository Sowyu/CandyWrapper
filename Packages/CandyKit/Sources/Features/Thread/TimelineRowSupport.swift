import AppKit
import CoreText
import DesignSystem
import T3Protocol
import T3Store

/// Main-panel colors and type for the timeline (H-timeline-visuals.md section 3 conventions).
@MainActor
enum TL {
    static func c(_ key: KeyPath<Palette, TokenColor>, _ alpha: Double = 1) -> NSColor { Themed.color(key, alpha) }

    static func font(_ px: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont { DSFont.ui(px, weight: weight) }
    /// `tabular-nums`.
    static func tabular(_ px: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont { SB.tabular(px, weight) }

    /// `text-sm leading-relaxed`.
    static let relaxed: CGFloat = 14 * 1.625

    /// `shouldPreserveAssistantLineBreaks` (packages/shared/src/markdownPipeline.ts:291).
    static func preservesAssistantLineBreaks(_ text: String) -> Bool { text.contains(/(?m)^★ Insight(?:\s|─)/) }

    /// `formatDayAwareTimestamp` (timestampFormat.ts:175-197) with the locale's hour cycle.
    // ponytail: ignores the timestampFormat setting (12h, 24h); read it when settings exist
    static func dayAwareTimestamp(_ ts: T3Timestamp?, now: Date = Date()) -> String {
        guard let ms = ts?.epochMs else { return "" }
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days <= 0 { return time }
        if days == 1 { return "yesterday at \(time)" }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let day = sameYear ? date.formatted(.dateTime.month(.defaultDigits).day()) : date.formatted(.dateTime.month(.defaultDigits).day().year())
        return "\(day) \(time)"
    }

    /// Rounds to device pixels at 2x, as Blink snaps boxes.
    // ponytail: 2x like Text.swift's baselines; pass the backing scale for 1x screens
    static func snap(_ v: CGFloat) -> CGFloat { (v * 2).rounded() / 2 }
}

/// What every row view shares: the model for toggles and a cache of parsed markdown.
@MainActor
final class TimelineContext {
    weak var model: ThreadViewModel?
    var workspaceRoot: String? { model?.workspaceRoot }
    var now: () -> Date = Date.init

    private var documents: [String: (text: String, breaks: Bool, document: MarkdownDocument)] = [:]

    /// Parses once per row and text; recycled views reuse the result.
    // ponytail: unbounded, one entry per message seen; trim to the rows near the viewport if huge threads show it in memory
    func document(_ key: String, _ text: String, lineBreaks: Bool) -> MarkdownDocument {
        if let hit = documents[key], hit.text == text, hit.breaks == lineBreaks { return hit.document }
        let document = MarkdownDocument(parsing: text, preservesLineBreaks: lineBreaks)
        documents[key] = (text, lineBreaks, document)
        return document
    }

    func forgetDocuments() { documents.removeAll() }
}

/// Base of every timeline row. A row view is configured from a `TimelineItem` and measures itself
/// for a width; it never owns expand state. Hover drives the hover-only timestamps and buttons.
@MainActor
class TimelineRowView: DSView {
    var item: TimelineItem?
    var context: TimelineContext!

    /// Clicks on the background of the row land here when the whole row is a button.
    var onClick: (() -> Void)?

    private var trackingArea: NSTrackingArea?
    private(set) var hovered = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.masksToBounds = false
        clipsToBounds = true
    }

    func configure(_ item: TimelineItem) { self.item = item }
    func height(forWidth width: CGFloat) -> CGFloat { 0 }

    /// Resets hover when the view is recycled.
    override func prepareForReuse() {
        super.prepareForReuse()
        if hovered { hovered = false; hoverChanged() }
    }

    func hoverChanged() {}

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { if !hovered { hovered = true; hoverChanged() } }
    override func mouseExited(with event: NSEvent) { if hovered { hovered = false; hoverChanged() } }

    override func mouseUp(with event: NSEvent) {
        guard let onClick, bounds.contains(convert(event.locationInWindow, from: nil)) else { return super.mouseUp(with: event) }
        onClick()
    }

    override func mouseDown(with event: NSEvent) { if onClick == nil { super.mouseDown(with: event) } }

    /// Fades hover-only views (`transition-opacity duration-200`, or instant).
    static func reveal(_ views: [NSView], _ on: Bool, duration: TimeInterval = 0.2) {
        guard duration > 0, !Motion.reduced else { views.forEach { $0.alphaValue = on ? 1 : 0 }; return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = Motion.easeInOut
            views.forEach { $0.animator().alphaValue = on ? 1 : 0 }
        }
    }
}

/// A layer-only rectangle: fills, hairlines and cards without a backing store.
final class FillView: DSView {
    var fill: NSColor? { didSet { needsDisplay = true } }
    var border: NSColor? { didSet { needsDisplay = true } }
    var radius: CGFloat = 0 { didSet { layer?.cornerRadius = radius } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateLayer() {
        layer?.backgroundColor = fill?.cgColor(in: self)
        layer?.borderColor = border?.cgColor(in: self)
        layer?.borderWidth = border == nil ? 0 : 1
        layer?.cornerRadius = radius
    }
}

/// A text label whose sweeping highlight copies `live-tool-shine` (index.css:521-548): the label in
/// `secondaryLabel`, a copy in `foreground` shown through a 72px band that crosses it in 2.2s,
/// 30 steps. Core Animation runs it, and only while the label is visible.
final class ShineLabelView: DSView {
    let base = LabelView()
    private let bright = LabelView()
    private let band = CAGradientLayer()
    private var loop: LoopingAnimation?

    var text: String {
        get { base.text }
        set { base.text = newValue; bright.text = newValue }
    }

    var shining = false { didSet { if shining != oldValue { bright.isHidden = !shining; loop?.update() } } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for label in [base, bright] {
            label.font = TL.font(14)
            label.lineHeight = TL.relaxed
            addSubview(label)
        }
        base.color = TL.c(\.secondaryLabel)
        bright.color = TL.c(\.foreground)
        bright.isHidden = true
        band.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
        bright.layer?.mask = band
        loop = LoopingAnimation(view: self, key: "shine", layer: { [weak self] in self?.shining == true ? self?.band : nil }) { [weak self] in
            let a = CABasicAnimation(keyPath: "position.x")
            let width = self?.bright.bounds.width ?? 0
            a.fromValue = -36
            a.toValue = width + 36
            a.duration = 2.2
            a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .linear)
            // ponytail: linear, T3 uses steps(30); a keyframe animation with 30 discrete values matches it exactly
            return a
        }
    }

    var textWidth: CGFloat { base.textWidth }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        base.frame = bounds
        bright.frame = bounds
        CATransaction.begin(); CATransaction.setDisableActions(true)
        band.frame = CGRect(x: -72, y: 0, width: 72, height: bounds.height)
        CATransaction.commit()
        band.removeAnimation(forKey: "shine")
        loop?.update()
    }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); loop?.windowChanged() }
    override func viewDidHide() { super.viewDidHide(); loop?.update() }
    override func viewDidUnhide() { super.viewDidUnhide(); loop?.update() }
}

extension ProjectedTurnItem {
    /// A string field of the raw item.
    func string(_ key: String) -> String? { item.raw[key]?.stringValue }
}
