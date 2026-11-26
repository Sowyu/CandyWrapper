import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// A step's tone on the rail (WorkflowRunFeed.tsx:640-650): blue for work under way, amber for a person's turn.
enum WorkflowStepTone { case working, input, quiet, done, failed, ended }

/// `StepMark` (WorkflowRunFeed.tsx:661-735): a 20pt ring, a dot while it works, a tick once done. Drawn in place;
/// the ping and the tick's draw-on motion are left out.
// ponytail: no `animate-step-ping` or `animate-check-draw`; add them with a one-shot layer animation if the
// arrival of a step reads too flat.
enum WorkflowStepMark {
    static func draw(_ tone: WorkflowStepTone, in r: NSRect) {
        let s = r.width / 20
        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: r.minX + x * s, y: r.minY + y * s) }
        let ring = NSBezierPath(ovalIn: NSRect(x: r.minX + 1.8 * s, y: r.minY + 1.8 * s, width: 16.4 * s, height: 16.4 * s))
        ring.lineWidth = 1.6 * s
        if tone == .input { ring.setLineDash([2.6 * s, 2.2 * s], count: 2, phase: 0) }
        Themed.color(\.background).setFill()
        ring.fill()
        let muted = Themed.color(\.mutedForeground)
        switch tone {
        case .working: Themed.color(\.info).setStroke()
        case .input: Themed.color(\.warning).setStroke()
        case .quiet, .ended: muted.withAlphaComponent(0.6).setStroke()
        case .done: muted.withAlphaComponent(0.45).setStroke()
        case .failed: Themed.color(\.destructive).setStroke()
        }
        ring.stroke()
        switch tone {
        case .working, .input, .quiet:
            (tone == .input ? Themed.color(\.warning) : tone == .quiet ? muted.withAlphaComponent(0.6) : Themed.color(\.info)).setFill()
            NSBezierPath(ovalIn: NSRect(x: r.minX + 6.6 * s, y: r.minY + 6.6 * s, width: 6.8 * s, height: 6.8 * s)).fill()
        case .done:
            let tick = NSBezierPath()
            tick.move(to: p(6.3, 10.3)); tick.line(to: p(8.8, 12.7)); tick.line(to: p(13.7, 7.7))
            tick.lineWidth = 1.8 * s; tick.lineCapStyle = .round; tick.lineJoinStyle = .round
            muted.setStroke()
            tick.stroke()
        case .failed:
            let bang = NSBezierPath()
            bang.move(to: p(10, 6.2)); bang.line(to: p(10, 10.8)); bang.move(to: p(10, 13.6)); bang.line(to: p(10, 13.7))
            bang.lineWidth = 1.8 * s; bang.lineCapStyle = .round
            Themed.color(\.destructive).setStroke()
            bang.stroke()
        case .ended:
            let dash = NSBezierPath()
            dash.move(to: p(6.6, 10)); dash.line(to: p(13.4, 10))
            dash.lineWidth = 1.6 * s; dash.lineCapStyle = .round
            muted.setStroke()
            dash.stroke()
        }
    }

    /// A step of a fork: a `size-2.5` dot with a 2pt border (:774-790).
    static func drawSub(_ tone: WorkflowStepTone, in r: NSRect) {
        let dot = NSRect(x: r.midX - 5, y: r.midY - 5, width: 10, height: 10)
        let muted = Themed.color(\.mutedForeground)
        let (border, fill): (NSColor, NSColor) = switch tone {
        case .done: (.clear, muted.withAlphaComponent(0.45))
        case .failed: (Themed.color(\.destructive), Themed.color(\.destructive))
        case .input: (Themed.color(\.warning), Themed.color(\.warning))
        case .working: (Themed.color(\.info), Themed.color(\.info))
        default: (muted.withAlphaComponent(0.5), Themed.color(\.background))
        }
        fill.setFill()
        NSBezierPath(ovalIn: dot).fill()
        border.setStroke()
        let ring = NSBezierPath(ovalIn: dot.insetBy(dx: 1, dy: 1))
        ring.lineWidth = 2
        ring.stroke()
    }
}

/// What one timeline line says (`TimelineRow` props, :737-781).
struct WorkflowTimelineLine: Equatable {
    var tone: WorkflowStepTone
    var name: String
    var chip: String?
    var aside: String?
    var asideFailed = false
    var verb: String?
    var verbTone: WorkflowStepTone = .working
    var duration: String?
    var selected = false
    var current = false
    var sub = false
}

/// `TimelineRow` (:783-883): its mark, the name, what came of it, a word on what it is doing, and its time. The
/// highlight starts past the mark, so the rail stays whole.
final class WorkflowTimelineRowView: ControlView {
    static func height(sub: Bool) -> CGFloat { sub ? 28 : 32 }
    private let name = LabelView("", font: DSFont.ui(14), color: Themed.color(\.foreground))
    private let aside = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    private let verb = LabelView("", font: DSFont.ui(12), color: Themed.color(\.infoForeground))
    private let duration = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    private let chip = WorkflowChipView()
    private let chevron = IconView(name: .chevronRight, size: 12)
    private(set) var line = WorkflowTimelineLine(tone: .done, name: "")
    /// `@2xl/feed`: the pane sits beside the timeline, so the row points at it.
    var wide = false { didSet { if wide != oldValue { needsLayout = true } } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scalesWhenPressed = false
        name.lineHeight = 20
        for l in [aside, verb, duration] { l.lineHeight = 16 }
        duration.alignment = .right
        verb.alignment = .right
        duration.font = DSFont.ui(12).monospacedDigits
        for v in [chip, name, aside, verb, duration, chevron] as [NSView] { addSubview(v) }
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(_ l: WorkflowTimelineLine) {
        line = l
        let live = l.tone == .working || l.tone == .input
        name.text = l.name
        name.font = DSFont.ui(14, weight: live || l.selected || l.current ? .medium : .regular)
        name.color = live || l.selected || l.current ? Themed.color(\.foreground) : Themed.color(\.foreground, 0.75)
        aside.text = l.aside ?? ""
        aside.isHidden = (l.aside ?? "").isEmpty
        aside.color = l.asideFailed ? Themed.color(\.destructive) : Themed.color(\.mutedForeground)
        verb.text = l.verb ?? ""
        verb.isHidden = (l.verb ?? "").isEmpty
        verb.color = switch l.verbTone {
        case .input: Themed.color(\.warningForeground)
        case .quiet: Themed.color(\.mutedForeground)
        case .failed: Themed.color(\.destructive)
        default: Themed.color(\.infoForeground)
        }
        duration.text = l.duration ?? ""
        chip.isHidden = l.chip == nil
        chip.name = l.chip ?? ""
        chevron.strokeColor = l.selected ? Themed.color(\.foreground) : Themed.color(\.mutedForeground)
        setAccessibilityLabel([l.name, l.aside, l.verb, l.duration].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "))
        setAccessibilityValue(l.selected ? "selected" : nil)
        needsLayout = true
        needsDisplay = true
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let h = bounds.height, w = bounds.width
        let lead: CGFloat = line.sub ? 4 : 0
        // `gap-2.5 pe-2`: mark, words (flex-1), verb, time (`min-w-12`), the chevron's `w-3` on a wide feed.
        var right = w - 8
        chevron.isHidden = !(wide && (line.selected || line.current))
        if wide {
            chevron.frame = NSRect(x: right - 12, y: (h - 12) / 2, width: 12, height: 12)
            right -= 12 + 10
        }
        let dw = max(48, ceil(duration.textWidth) + 1)
        duration.frame = NSRect(x: right - dw, y: (h - 16) / 2, width: dw, height: 16)
        right -= dw + 10
        if !verb.isHidden {
            let vw = min(ceil(verb.textWidth) + 1, w * 0.4)
            verb.frame = NSRect(x: right - vw, y: (h - 16) / 2, width: vw, height: 16)
            right -= vw + 10
        }
        var x = lead + 20 + 10
        let words = max(0, right - x)
        if !chip.isHidden {
            chip.frame = NSRect(x: x, y: (h - 16) / 2, width: 16, height: 16)
            x += 16 + 6
        }
        // The name keeps its room: up to 60% of the words.
        let nameW = min(ceil(name.textWidth) + 1, max(0, words * 0.6 - (chip.isHidden ? 0 : 22)))
        let top = (h - 20) / 2
        name.frame = NSRect(x: x, y: top, width: nameW, height: 20)
        // `items-baseline`: 12/16 under 14/20 sits 3pt lower.
        let ax = x + min(nameW, name.textWidth) + 8
        aside.frame = NSRect(x: ax, y: top + 2, width: max(0, lead + 30 + words - ax), height: 16)
    }

    override var wantsUpdateLayer: Bool { false }
    override func stateDidChange(from old: State) { super.stateDidChange(from: old); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        if line.selected || state.hovered {
            Themed.color(\.accent, line.selected ? 1 : 0.6).setFill()
            let r = DesignGeometry.radius(8, in: self)
            NSBezierPath(roundedRect: NSRect(x: 24, y: 0, width: bounds.width - 24, height: bounds.height), xRadius: r, yRadius: r).fill()
        }
        let mark = NSRect(x: line.sub ? 4 : 0, y: (bounds.height - 20) / 2, width: 20, height: 20)
        if line.sub { WorkflowStepMark.drawSub(line.tone, in: mark) } else { WorkflowStepMark.draw(line.tone, in: mark) }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// `WorkflowTimeline` (:899-1218): the run as it went, one line per step that took time or involved someone, with
/// steps that ran at once off a branch, each open question under its step, and a dashed rail on while it is live.
final class WorkflowTimelineView: DSView {
    enum Part {
        case row(WorkflowTimelineLine, key: String)
        /// "{count} in parallel" over its steps.
        case together(head: WorkflowTimelineLine, running: Int?, rows: [(WorkflowTimelineLine, key: String, question: WorkflowQuestion?)])
        case question(WorkflowQuestion)
    }

    struct Item { var parts: [Part]; var branch = false }

    var onPick: ((String) -> Void)?
    /// The question cards, kept by question across rebuilds so a reason being typed keeps its field.
    var makeCard: ((WorkflowQuestion) -> WorkflowQuestionCardView)?
    var wide = false { didSet { if wide != oldValue { rows.values.forEach { $0.wide = wide }; needsLayout = true } } }

    private(set) var items: [Item] = []
    private var live = false
    private var rows: [String: WorkflowTimelineRowView] = [:]
    private var heads: [Int: (label: LabelView, running: LabelView, time: LabelView, tone: WorkflowStepTone)] = [:]
    private var cards: [String: WorkflowQuestionCardView] = [:]
    /// Rails, branches and marks the timeline draws itself, in its own coordinates.
    private var drawing: [(NSRect, (NSRect) -> Void)] = []

    override var isFlipped: Bool { true }

    func set(items: [Item], live: Bool) {
        self.items = items
        self.live = live
        var keys = Set<String>(), questions = Set<String>()
        for (i, item) in items.enumerated() {
            for part in item.parts {
                switch part {
                case .row(let l, let key): keys.insert(key); row(key).set(l)
                case .together(let head, let running, let subs):
                    var h = heads[i] ?? {
                        let label = LabelView("", font: DSFont.ui(14), color: Themed.color(\.foreground)); label.lineHeight = 20
                        let run = LabelView("", font: DSFont.ui(12), color: Themed.color(\.infoForeground)); run.lineHeight = 16
                        let time = LabelView("", font: DSFont.ui(12).monospacedDigits, color: Themed.color(\.mutedForeground))
                        time.lineHeight = 16; time.alignment = .right
                        for v in [label, run, time] { addSubview(v) }
                        return (label, run, time, WorkflowStepTone.done)
                    }()
                    h.label.text = head.name
                    h.label.font = DSFont.ui(14, weight: (running ?? 0) > 0 || head.tone == .quiet ? .medium : .regular)
                    h.label.color = head.tone == .done || head.tone == .failed ? Themed.color(\.mutedForeground) : Themed.color(\.foreground)
                    h.running.text = running.map { "\($0) running" } ?? ""
                    h.running.isHidden = running == nil
                    h.time.text = head.duration ?? ""
                    h.tone = head.tone
                    heads[i] = h
                    for s in subs {
                        keys.insert(s.key); row(s.key).set(s.0)
                        if let q = s.question { questions.insert(q.key); card(q) }
                    }
                case .question(let q): questions.insert(q.key); card(q)
                }
            }
        }
        for (k, v) in rows where !keys.contains(k) { v.removeFromSuperview(); rows[k] = nil }
        for (k, v) in cards where !questions.contains(k) { v.removeFromSuperview(); cards[k] = nil }
        for (i, h) in heads where items.indices.contains(i) == false || !items[i].branch {
            [h.label, h.running, h.time].forEach { $0.removeFromSuperview() }
            heads[i] = nil
        }
        needsLayout = true
        needsDisplay = true
    }

    private func row(_ key: String) -> WorkflowTimelineRowView {
        if let r = rows[key] { return r }
        let r = WorkflowTimelineRowView()
        r.wide = wide
        r.action = { [weak self] in self?.onPick?(key) }
        addSubview(r)
        rows[key] = r
        return r
    }

    @discardableResult private func card(_ q: WorkflowQuestion) -> WorkflowQuestionCardView {
        if let c = cards[q.key] { return c }
        let c = makeCard?(q) ?? WorkflowQuestionCardView()
        addSubview(c)
        cards[q.key] = c
        return c
    }

    func height(forWidth w: CGFloat) -> CGFloat { place(width: w, apply: false) }
    override func layout() { super.layout(); _ = place(width: bounds.width, apply: true) }

    private func place(width w: CGFloat, apply: Bool) -> CGFloat {
        // Rails and branches under, the parallel heads' marks over them.
        var drawn: [(NSRect, (NSRect) -> Void)] = [], marks: [(NSRect, (NSRect) -> Void)] = []
        let border = { Themed.color(\.border) }
        func rail(_ r: NSRect) { drawn.append((r, { border().setFill(); $0.fill() })) }
        func cardHeight(_ q: WorkflowQuestion, x: CGFloat, y: CGFloat) -> CGFloat {
            // `ms-8 mt-1 mb-2`.
            guard let c = cards[q.key] else { return 0 }
            let cw = max(0, w - x - 32)
            let h = c.height(forWidth: cw)
            if apply { c.frame = NSRect(x: x + 32, y: y + 4, width: cw, height: h) }
            return 4 + h + 8
        }
        var y: CGFloat = 0
        for (i, item) in items.enumerated() {
            let top = y
            let first = i == 0, last = item.branch || (i == items.count - 1 && !live)
            for part in item.parts {
                switch part {
                case .row(_, let key):
                    if apply { rows[key]?.frame = NSRect(x: 0, y: y, width: w, height: 32) }
                    y += 32
                case .question(let q):
                    y += cardHeight(q, x: 0, y: y)
                case .together(_, _, let subs):
                    // The head (`py-1.5 pe-2`), the branch out of its mark, and the steps off the branch.
                    if apply, let h = heads[i] {
                        var right = w - 8 - (wide ? 22 : 0)
                        let tw = max(48, ceil(h.time.textWidth) + 1)
                        h.time.frame = NSRect(x: right - tw, y: y + 8, width: tw, height: 16)
                        right -= tw + 10
                        if !h.running.isHidden {
                            let rw = ceil(h.running.textWidth) + 1
                            h.running.frame = NSRect(x: right - rw, y: y + 8, width: rw, height: 16)
                            right -= rw + 10
                        }
                        h.label.frame = NSRect(x: 30, y: y + 6, width: max(0, right - 30), height: 20)
                        let tone = h.tone
                        marks.append((NSRect(x: 0, y: y + 6, width: 20, height: 20), { WorkflowStepMark.draw(tone, in: $0) }))
                    }
                    let headTop = y
                    y += 32
                    drawn.append((NSRect(x: 9, y: headTop + 26, width: 32, height: 20), { r in
                        let p = NSBezierPath()
                        p.move(to: NSPoint(x: r.minX + 1, y: r.minY)); p.line(to: NSPoint(x: r.minX + 1, y: r.minY + 1))
                        p.curve(to: NSPoint(x: r.minX + 7, y: r.minY + 7), controlPoint1: NSPoint(x: r.minX + 1, y: r.minY + 5),
                                controlPoint2: NSPoint(x: r.minX + 3, y: r.minY + 7))
                        p.line(to: NSPoint(x: r.minX + 24, y: r.minY + 7))
                        p.curve(to: NSPoint(x: r.minX + 30, y: r.minY + 13), controlPoint1: NSPoint(x: r.minX + 28, y: r.minY + 7),
                                controlPoint2: NSPoint(x: r.minX + 30, y: r.minY + 9))
                        p.line(to: NSPoint(x: r.minX + 30, y: r.maxY))
                        p.lineWidth = 2
                        border().setStroke()
                        p.stroke()
                    }))
                    // `ol.relative ms-[9px] ps-4`.
                    let ox: CGFloat = 25
                    for (j, s) in subs.enumerated() {
                        let liTop = y
                        if apply { rows[s.key]?.frame = NSRect(x: ox, y: y, width: max(0, w - ox), height: 28) }
                        y += 28
                        if let q = s.question { y += cardHeight(q, x: ox, y: y) }
                        let f = j == 0, l = j == subs.count - 1
                        if !(f && l) {
                            let a = liTop + (f ? 14 : 0), b = l ? liTop + 14 : y
                            rail(NSRect(x: ox + 13, y: a, width: 2, height: max(0, b - a)))
                        }
                        if l {
                            drawn.append((NSRect(x: ox - 16, y: liTop + 14, width: 32, height: 14), { r in
                                let p = NSBezierPath()
                                p.move(to: NSPoint(x: r.minX + 30, y: r.minY))
                                p.curve(to: NSPoint(x: r.minX + 24, y: r.minY + 7), controlPoint1: NSPoint(x: r.minX + 30, y: r.minY + 4),
                                        controlPoint2: NSPoint(x: r.minX + 28, y: r.minY + 7))
                                p.line(to: NSPoint(x: r.minX + 7, y: r.minY + 7))
                                p.curve(to: NSPoint(x: r.minX + 1, y: r.minY + 13), controlPoint1: NSPoint(x: r.minX + 3, y: r.minY + 7),
                                        controlPoint2: NSPoint(x: r.minX + 1, y: r.minY + 9))
                                p.line(to: NSPoint(x: r.minX + 1, y: r.maxY))
                                p.lineWidth = 2
                                border().setStroke()
                                p.stroke()
                            }))
                            rail(NSRect(x: ox - 16, y: liTop + 28, width: 2, height: max(0, y - liTop - 28)))
                        }
                    }
                }
            }
            // `Rail` (:886-898): from the row above to this mark, and on unless it is last.
            if !(first && last) {
                let a = top + (first ? 16 : 0)
                let b = last ? top + 16 : y
                rail(NSRect(x: 9, y: a, width: 2, height: max(0, b - a)))
            }
        }
        if live {
            // `ms-[9px] h-5 border-s-2 border-dashed`.
            let tailTop = y
            drawn.append((NSRect(x: 9, y: tailTop, width: 2, height: 20), { r in
                let p = NSBezierPath()
                p.move(to: NSPoint(x: r.midX, y: r.minY)); p.line(to: NSPoint(x: r.midX, y: r.maxY))
                p.lineWidth = 2
                p.setLineDash([6, 4], count: 2, phase: 0)
                border().setStroke()
                p.stroke()
            }))
            y += 20
        }
        if apply { drawing = drawn + marks; needsDisplay = true }
        return y
    }

    override var wantsUpdateLayer: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        for (r, d) in drawing where r.intersects(dirtyRect.insetBy(dx: -4, dy: -4)) { d(r) }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}
