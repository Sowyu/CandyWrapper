import AppKit
import CoreText
import DesignSystem
import T3Protocol
import T3Store

/// Find matches behind a single-line label, in the colors `MarkdownView` paints them.
// ponytail: the label's text keeps its own color over the mark; recolor it as MarkdownView.draw does if a plan title match looks off in dark mode
final class FindHighlightView: DSView {
    var rects: [(rect: CGRect, active: Bool)] = [] {
        didSet { if !rects.elementsEqual(oldValue, by: { $0.rect == $1.rect && $0.active == $1.active }) { needsDisplay = true } }
    }
    override var wantsUpdateLayer: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        for (rect, active) in rects {
            ctx.setFillColor(SearchMatchColors.background(active: active, dark: effectiveAppearance.isDark).cgColor)
            ctx.fill(rect)
        }
    }
}

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
    /// The regex runs only when a byte search finds the marker: `String.contains` cost 0.7 ms per
    /// streaming update on a 7,500-character answer.
    static func preservesAssistantLineBreaks(_ text: String) -> Bool {
        let found = text.utf8.withContiguousStorageIfAvailable { bytes in
            insightMarker.withUnsafeBufferPointer { marker in
                memmem(bytes.baseAddress, bytes.count, marker.baseAddress, marker.count) != nil
            }
        } ?? text.contains("★ Insight")
        return found && text.contains(/(?m)^★ Insight(?:\s|─)/)
    }
    private static let insightMarker = Array("★ Insight".utf8)

    /// `formatDayAwareTimestamp` (timestampFormat.ts:175-197) with the `timestampFormat` setting: the
    /// locale's hour cycle, or 12 or 24 hours (`hour12`).
    static func dayAwareTimestamp(_ ts: T3Timestamp?, now: Date = Date(),
                                  format: String = ClientSettingsStore.shared.current.string("timestampFormat")) -> String {
        guard let ms = ts?.epochMs else { return "" }
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        let calendar = Calendar.current
        let time = timeOfDay(date, format: format)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days <= 0 { return time }
        if days == 1 { return "yesterday at \(time)" }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let day = sameYear ? date.formatted(.dateTime.month(.defaultDigits).day().locale(t3Locale))
            : date.formatted(.dateTime.month(.defaultDigits).day().year().locale(t3Locale))
        return "\(day) \(time)"
    }

    /// `getTimestampFormatter(format, false)`: hour and minute in the locale's cycle, or forced 12 or 24 hours.
    /// Foundation puts a narrow no-break space before AM and PM; Chromium's ICU writes a plain space
    /// ("8:12 AM"), which T3 shows.
    static func timeOfDay(_ date: Date, format: String) -> String {
        let text = switch format {
        case "12-hour": twelveHour.string(from: date)
        case "24-hour": twentyFourHour.string(from: date)
        default: localeTime.string(from: date)
        }
        return text.replacingOccurrences(of: "\u{202F}", with: " ")
    }

    private static func formatter(_ template: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = t3Locale
        f.dateFormat = DateFormatter.dateFormat(fromTemplate: template, options: 0, locale: t3Locale)
        return f
    }
    private static let twelveHour = formatter("hmma")
    private static let twentyFourHour = formatter("Hmm")
    private static let localeTime = formatter("jmm")
    static var t3Locale: Locale { TimestampFormat.t3Locale }

    /// Rounds to device pixels at 2x, as Blink snaps boxes.
    // ponytail: 2x like Text.swift's baselines; pass the backing scale for 1x screens
    static func snap(_ v: CGFloat) -> CGFloat { (v * 2).rounded() / 2 }
}

/// What every row view shares: the model for toggles and a cache of parsed markdown.
@MainActor
final class TimelineContext {
    weak var model: ThreadViewModel?
    /// A row is about to toggle a disclosure (a turn fold, a work group or an entry): the timeline holds it in place.
    var onDisclosure: ((String) -> Void)?
    func disclosure(_ rowId: String?) { if let rowId { onDisclosure?(rowId) } }
    var workspaceRoot: String? { model?.workspaceRoot }
    /// T3's `markdownCwd` (ChatView.tsx `gitCwd`): the thread's worktree, else the project root. File chips resolve against it.
    var markdownCwd: String? { model?.projection?.thread.worktreePath ?? model?.workspaceRoot }
    var now: () -> Date = Date.init

    private var documents: [String: (text: String, breaks: Bool, document: MarkdownDocument)] = [:]
    /// The parse of each answer that is streaming, which the next token extends.
    private var streamingParses: [String: MarkdownDocument.Incremental] = [:]

    /// Parses once per row and text; recycled views reuse the result. While `streaming`, a longer
    /// text reparses only what follows its last finished block; the settled text parses whole once.
    // ponytail: unbounded, one entry per message seen; trim to the rows near the viewport if huge threads show it in memory
    func document(_ key: String, _ text: String, lineBreaks: Bool, streaming: Bool = false) -> MarkdownDocument {
        // A settled message whose last streamed text was the same still parses whole once: the hit must not
        // come from the incremental parse.
        if let hit = documents[key], hit.text == text, hit.breaks == lineBreaks, streaming || streamingParses[key] == nil { return hit.document }
        let document: MarkdownDocument
        if streaming {
            let parse = MarkdownDocument.parse(text, preservesLineBreaks: lineBreaks, extending: streamingParses[key])
            streamingParses[key] = parse
            document = parse.document
        } else {
            streamingParses[key] = nil
            document = MarkdownDocument(parsing: text, preservesLineBreaks: lineBreaks)
        }
        documents[key] = (text, lineBreaks, document)
        return document
    }

    func forgetDocuments() { documents.removeAll(); streamingParses.removeAll() }

    /// Fork from an assistant message when `canForkProjectedAssistantItem` allows it. Capabilities come from
    /// the thread's provider session for its own rows; inherited rows have none, which allows the fork.
    // ponytail: T3 reads the source row's own session (`useV2ItemSupport`); use it if inherited rows fork wrongly
    func forkAction(_ projected: ProjectedTurnItem?) -> (() -> Void)? {
        guard let projected, let model, let onFork = model.onForkFromRun, let run = projected.item.runId,
              let projection = model.projection else { return nil }
        let own = projected.sourceThreadId == projection.thread.id
        let capabilities = own ? ThreadRelationships.providerSession(projection)?["capabilities"] : nil
        guard ThreadRelationships.canFork(projected, capabilities: capabilities) else { return nil }
        let source = projected.sourceThreadId
        return { onFork(source, run) }
    }
}

/// Base of every timeline row. A row view is configured from a `TimelineItem` and measures itself
/// for a width; it never owns expand state. Hover drives the hover-only timestamps and buttons.
@MainActor
class TimelineRowView: DSView, FocusWithinObserver, HoverSyncPointerClient {
    var item: TimelineItem?
    /// The row kind this view class draws; it goes back to that kind's pool.
    var kind: TimelineView.Kind?
    /// Sitting in the timeline's pool; a pooled view must never be recycled twice.
    var pooled = false
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

    // A row that is one button (a fold, a work group header) is one element for VoiceOver; other rows stay
    // transparent so their text and controls are reachable.
    override func isAccessibilityElement() -> Bool { onClick != nil }
    override func accessibilityRole() -> NSAccessibility.Role? {
        let role = super.accessibilityRole()
        return onClick != nil && (role == nil || role == .group || role == .unknown) ? .button : role
    }
    override func accessibilityLabel() -> String? {
        if let explicit = super.accessibilityLabel(), !explicit.isEmpty { return explicit }
        return onClick != nil ? ControlView.drawnText(in: self) : nil
    }
    override func accessibilityPerformPress() -> Bool {
        guard let onClick else { return false }
        onClick()
        return true
    }

    /// Resets hover when the view is recycled.
    override func prepareForReuse() {
        super.prepareForReuse()
        if hovered || focusWithin { hovered = false; focusWithin = false; hoverChanged() }
    }

    func setContentVisible(_ visible: Bool) {}

    /// Paints find in thread's matches in this row's Markdown; `occurrence` is the active match's index in the row,
    /// numbered as the server numbers them. Only messages and plans are searchable (`data-thread-find-text`).
    func applyThreadFind(query: String, occurrence: Int?) {
        func walk(_ view: NSView) {
            if let markdown = view as? MarkdownView {
                markdown.threadFindQuery = query
                markdown.threadFindOccurrence = occurrence
            }
            view.subviews.forEach(walk)
        }
        walk(self)
    }

    /// The active match in this row's coordinates, nil when the row has none on screen. A row that folds the match
    /// away opens first and returns nil; the timeline asks again after it lays out.
    func activeFindRect() -> CGRect? {
        func walk(_ view: NSView) -> CGRect? {
            if let markdown = view as? MarkdownView, let rect = markdown.activeFindRect() { return markdown.convert(rect, to: self) }
            for child in view.subviews { if let rect = walk(child) { return rect } }
            return nil
        }
        return walk(self)
    }

    func hoverChanged() {}

    /// The row's `transition-*` class: what fades when hover or focus restyles it. Recycling snaps.
    var hoverTransitions: Motion.Transition { [] }
    private func pointerChanged() { Motion.transitioning(hoverTransitions) { hoverChanged() } }

    /// A row whose reveal covers only part of it (T3 puts `group/<name>` on an inner element, or on
    /// each work line) also hears pointer moves and reads `pointer` in `hoverChanged`.
    var tracksPointerMoves: Bool { false }
    /// The pointer in row coordinates while the row is hovered.
    var pointer: NSPoint? {
        guard hovered, let window else { return nil }
        return convert(window.mouseLocationOutsideOfEventStream, from: nil)
    }
    override func mouseMoved(with event: NSEvent) {
        if tracksPointerMoves { pointerChanged() } else { super.mouseMoved(with: event) }
    }
    func hoverPointerMoved() { if tracksPointerMoves, hovered { pointerChanged() } }

    /// A control in the row has keyboard focus (`group-focus-within`).
    private(set) var focusWithin = false
    func focusWithinChanged(_ focused: Bool) {
        guard focused != focusWithin else { return }
        focusWithin = focused
        pointerChanged()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        var options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect]
        if tracksPointerMoves { options.insert(.mouseMoved) }
        let area = NSTrackingArea(rect: .zero, options: options, owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { if !hovered { hovered = true; pointerChanged() } }
    override func mouseExited(with event: NSEvent) { if hovered { hovered = false; pointerChanged() } }

    override func mouseUp(with event: NSEvent) {
        guard let onClick, bounds.contains(convert(event.locationInWindow, from: nil)) else { return super.mouseUp(with: event) }
        onClick()
    }

    override func mouseDown(with event: NSEvent) { if onClick == nil { super.mouseDown(with: event) } }

    /// Fades hover-only views (`transition-opacity duration-200`, or instant).
    static func reveal(_ views: [NSView], _ on: Bool, duration: TimeInterval = 0.2) {
        HoverReveal.fade(views, visible: on, duration: duration)
    }
}

/// A layer-only rectangle: fills, hairlines and cards without a backing store.
final class FillView: DSView {
    var fill: NSColor? {
        didSet {
            // Inside `Motion.transitioning` the fill fades now; `updateLayer` then sets the same color.
            if window != nil, Motion.activeTransitions.contains(.background) { Motion.setBackground(layer, fill?.cgColor(in: self)) }
            needsDisplay = true
        }
    }
    var border: NSColor? { didSet { needsDisplay = true } }
    var radius: CGFloat = 0 { didSet { layer?.cornerRadius = radius } }

    /// The fill takes no clicks; what sits inside it (a user bubble's file chips) still does.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

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

    /// `shine` is `live-tool-shine` on live tool rows. `focus` is `live-activity-focus` (index.css:556-622),
    /// the band over Thinking and the compaction row (`ActivityShimmerOverlay`, MessagesTimeline.tsx:3681):
    /// a 72px window with soft edges that travels from -72px to the label's width + 72px in 2.2s, linear.
    enum Style { case shine, focus }
    var style = Style.shine {
        didSet {
            guard style != oldValue else { return }
            switch style {
            case .shine:
                band.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
                band.locations = nil
            case .focus:
                band.colors = [0, 0.12, 0.55, 1, 0.55, 0.12, 0].map { CGColor(gray: 0, alpha: $0) }
                // 0, .675, 1.575, 2.25, 2.925, 3.825 and 4.5rem of the 4.5rem window.
                band.locations = [0, 0.15, 0.35, 0.5, 0.65, 0.85, 1]
            }
            band.removeAnimation(forKey: "shine")
            loop?.update()
        }
    }

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
            // `focus` moves its band by the overlay's own width, the label plus 9rem.
            a.toValue = self?.style == .focus ? width + 108 : width + 36
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
