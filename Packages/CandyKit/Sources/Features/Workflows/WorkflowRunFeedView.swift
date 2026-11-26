import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// The picked run (5258 components/workflows/WorkflowRunFeed.tsx `WorkflowRunFeed`, :214-640): "Part of", the title
/// with its state and Stop, the meta line, its steps in the order they started, and its open questions.
// ponytail: steps as a flat list with T3's words, not T3's railed timeline, folded quick steps and side panel
// (`WorkflowTimeline`, `buildWorkflowFeed`, :929-1372); port those when the feed's own fidelity references land.
final class WorkflowRunFeedView: DSView {
    var onSelect: ((String?) -> Void)?
    var onOpenURL: ((String) -> Void)?
    var onAnswer: ((String, String, String, String?, @escaping @MainActor (String?) -> Void) -> Void)?
    var onCancelRun: ((String) -> Void)?
    var canOperate = true
    var ownSessionId: String?

    private let partOf = WorkflowTextButton("")
    private let title = TextBlockView()
    private let state = WorkflowStateWordView()
    private let stop = ButtonView("Stop", icon: .square, variant: .ghostDestructive, size: .xs)
    private let chip = WorkflowChipView()
    private let meta = WorkflowWordsRow()
    private let status = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    private let notHere = TextBlockView()
    private var stepViews: [WorkflowStepRowView] = []
    private var cards: [WorkflowQuestionCardView] = []
    private var ending: WorkflowEndView?
    private var node: WorkflowRunNode?
    private var parentId: String?
    /// Reasons typed per question, kept while the steps reload (`AnswerDrafts`, :209-213).
    private var reasons: [String: String] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title.font = DSFont.ui(16, weight: .semibold)
        title.lineHeight = 24
        status.lineHeight = 16
        notHere.font = DSFont.ui(14)
        notHere.lineHeight = 20
        notHere.color = Themed.color(\.mutedForeground)
        partOf.underlined = true
        stop.setAccessibilityLabel("Cancel run")
        stop.setTooltip("Cancel run")
        partOf.action = { [weak self] in self?.onSelect?(self?.parentId) }
        stop.action = { [weak self] in if let id = self?.node?.run.runId { self?.onCancelRun?(id) } }
        for v in [partOf, title, state, stop, chip, meta, status, notHere] as [NSView] { addSubview(v) }
    }

    override var isFlipped: Bool { true }

    func set(node: WorkflowRunNode?, parent: WorkflowRun?, detail: WorkflowRunDetail?, error: String?, notHere missing: Bool, nowMs: Int64) {
        self.node = node
        parentId = parent?.runId
        notHere.isHidden = !missing
        notHere.text = "This run is not here. This environment has no run with that link."
        for v in [partOf, title, state, stop, chip, meta, status] as [NSView] { v.isHidden = node == nil }
        stepViews.forEach { $0.removeFromSuperview() }
        stepViews = []
        cards.forEach { $0.removeFromSuperview() }
        cards = []
        ending?.removeFromSuperview()
        ending = nil
        guard let node else { needsLayout = true; return }
        let run = node.run
        partOf.isHidden = parent == nil
        partOf.title = parent.map { "Part of \($0.title)" } ?? ""
        title.text = run.title
        state.set(node)
        stop.isHidden = run.endedAt != nil
        stop.isEnabled = canOperate
        chip.name = run.workflow
        meta.parts = ([run.workflow] + WorkflowsPageLogic.metaLine(run, nowMs: nowMs)).flatMap { [$0, "·"] }.dropLast().map { $0 }
        status.isHidden = detail != nil && error == nil
        status.text = error ?? "Loading steps…"
        status.color = error == nil ? Themed.color(\.mutedForeground) : Themed.color(\.destructive)
        for step in detail?.steps ?? [] {
            let v = WorkflowStepRowView()
            v.set(step, nowMs: nowMs, ownSessionId: ownSessionId)
            addSubview(v)
            stepViews.append(v)
        }
        for q in node.questions {
            let card = WorkflowQuestionCardView()
            let key = "\(q.runId):\(q.name):\(q.askedAt)"
            card.set(q, reason: reasons[key], canAnswer: canOperate, nowMs: nowMs)
            card.onReason = { [weak self] in self?.reasons[key] = $0; self?.needsLayout = true }
            card.onOpenURL = { [weak self] in self?.onOpenURL?($0) }
            card.onAnswer = { [weak self] choice, reason, done in
                self?.onAnswer?(q.runId, q.name, choice, reason) { error in
                    if error == nil { self?.reasons[key] = nil }
                    done(error)
                }
            }
            addSubview(card)
            cards.append(card)
        }
        if run.endedAt != nil, detail != nil {
            let e = WorkflowEndView()
            e.set(run, nowMs: nowMs)
            addSubview(e)
            ending = e
        }
        needsLayout = true
    }

    /// The height the feed needs at `width`.
    func height(forWidth width: CGFloat) -> CGFloat { place(width: width, apply: false) }

    override func layout() {
        super.layout()
        _ = place(width: bounds.width, apply: true)
    }

    private func place(width w: CGFloat, apply: Bool) -> CGFloat {
        func set(_ v: NSView, _ r: NSRect) { if apply { v.frame = r } }
        var y: CGFloat = 0
        if !notHere.isHidden {
            let h = notHere.height(forWidth: w)
            set(notHere, NSRect(x: 0, y: y, width: w, height: h))
            return h
        }
        guard node != nil else { return 0 }
        // `header space-y-1`.
        if !partOf.isHidden {
            set(partOf, NSRect(x: 0, y: y, width: min(w, partOf.preferredWidth), height: 16))
            y += 20
        }
        let sw = state.width
        let stopW = stop.isHidden ? 0 : stop.fittingSize.width + 8
        let tw = max(0, w - sw - 8 - stopW)
        let th = max(24, title.height(forWidth: tw))
        set(title, NSRect(x: 0, y: y, width: tw, height: th))
        set(state, NSRect(x: tw + 8, y: y + 4, width: sw, height: 16))
        if !stop.isHidden { set(stop, NSRect(x: w - stopW + 8, y: y, width: stopW - 8, height: 24)) }
        y += th + 4
        // `gap-x-1.5`: the chip, then the words.
        set(chip, NSRect(x: 0, y: y, width: 16, height: 16))
        set(meta, NSRect(x: 22, y: y, width: max(0, w - 22), height: 16))
        y += 16
        if !status.isHidden {
            y += 16
            set(status, NSRect(x: 0, y: y, width: w, height: 16))
            y += 16
        }
        // `mt-4`.
        if !stepViews.isEmpty { y += 16 }
        for v in stepViews {
            let h = v.height(forWidth: w)
            set(v, NSRect(x: 0, y: y, width: w, height: h))
            y += h
        }
        for c in cards {
            y += 16
            let cw = min(w, 672)  // `max-w-2xl`
            let h = c.height(forWidth: cw)
            set(c, NSRect(x: 0, y: y, width: cw, height: h))
            y += h
        }
        if let ending {
            y += 16
            let h = ending.height(forWidth: w)
            set(ending, NSRect(x: 0, y: y, width: w, height: h))
            y += h
        }
        return y
    }
}

/// One step: its state mark, its name, its kind's words and its time. An answered question says who answered
/// (`workflowAnswer`, #42515); a withdrawn one by whom and why (`workflowWithdrawal`, #42506, :1538-1556).
final class WorkflowStepRowView: DSView {
    private let name = LabelView("", font: DSFont.ui(14, weight: .medium), color: Themed.color(\.foreground))
    private let line = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    private let said = TextBlockView()
    private var tone: WorkflowRunTone = .quiet

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        name.lineHeight = 20
        line.lineHeight = 16
        said.font = DSFont.ui(14)
        said.lineHeight = 20
        for v in [name, line, said] as [NSView] { addSubview(v) }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    override var isFlipped: Bool { true }

    func set(_ step: WorkflowStep, nowMs: Int64, ownSessionId: String?) {
        name.text = step.name
        line.text = WorkflowsPageLogic.stepLine(step, nowMs: nowMs)
        tone = step.status == "failed" ? .failed : step.status == "running" ? (step.kind == "ask" ? .input : step.kind == "agent" ? .working : .quiet) : .done
        var text = ""
        if step.kind == "ask" {
            if let a = WorkflowsPageLogic.answer(step.result) {
                let who = a.answeredBySession != nil && a.answeredBySession == ownSessionId ? nil : a.answeredBy
                text = WorkflowsPageLogic.saidLine(who: who, choice: a.choice, reason: a.reason)
            } else if let w = WorkflowsPageLogic.withdrawal(step.result) {
                line.text = "withdrawn · \(line.text)"
                text = w.reason.map { "Withdrawn by \(w.by): \($0)" } ?? "Withdrawn by \(w.by)."
            } else if step.status != "running" {
                line.text = "nobody answered · \(line.text)"
            }
        } else if step.status == "failed", let d = step.detail {
            text = d
        } else if let s = step.said {
            text = WorkflowsPageLogic.oneLine(s)
        }
        said.text = text
        said.isHidden = text.isEmpty
        setAccessibilityLabel([step.name, line.text, text].filter { !$0.isEmpty }.joined(separator: ", "))
        needsLayout = true
        needsDisplay = true
    }

    func height(forWidth w: CGFloat) -> CGFloat {
        let base: CGFloat = 8 + 20 + 16 + 8
        return said.isHidden ? base : base + 4 + said.height(forWidth: max(0, w - 24))
    }

    override func layout() {
        super.layout()
        let w = bounds.width - 24
        name.frame = NSRect(x: 24, y: 8, width: w, height: 20)
        line.frame = NSRect(x: 24, y: 28, width: w, height: 16)
        if !said.isHidden { said.frame = NSRect(x: 24, y: 48, width: w, height: said.height(forWidth: w)) }
    }

    override var wantsUpdateLayer: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        // A ring in the step's tone, filled once it is done, and the rail down to the next step.
        Themed.color(\.border).setFill()
        NSRect(x: 7.5, y: 0, width: 1, height: bounds.height).fill()
        let ring = NSRect(x: 2.5, y: 12.5, width: 11, height: 11)
        Themed.color(\.background).setFill()
        NSBezierPath(ovalIn: ring.insetBy(dx: -2, dy: -2)).fill()
        let color = WorkflowStateWordView.color(tone)
        color.set()
        let p = NSBezierPath(ovalIn: ring)
        p.lineWidth = 1.5
        if tone == .done || tone == .failed { p.fill() } else { p.stroke() }
    }
}

/// How a run ended (WorkflowRunFeed.tsx:609-627): the end word, when, the reason and the result's lines.
final class WorkflowEndView: DSView {
    private let head = LabelView("", font: DSFont.ui(16, weight: .semibold), color: Themed.color(\.foreground))
    private let sub = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    private let body = TextBlockView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        head.lineHeight = 24
        sub.lineHeight = 16
        body.font = DSFont.ui(14)
        body.lineHeight = 20
        for v in [head, sub, body] as [NSView] { addSubview(v) }
    }

    override var isFlipped: Bool { true }

    func set(_ run: WorkflowRun, nowMs: Int64) {
        head.text = WorkflowRuns.state(.init(run: run, children: [], questions: [])).word
        sub.text = TimestampFormat.formatRelativeTimeLabel(run.endedAt ?? run.updatedAt, nowMs: nowMs)
        var lines = WorkflowRuns.resultLines(run.result).map { $0.label.map { l in "\(l): " } ?? "" }
        lines = zip(lines, WorkflowRuns.resultLines(run.result)).map { $0 + $1.value }
        if run.status != "completed", let d = run.detail { lines.insert(d, at: 0) }
        body.text = lines.joined(separator: "\n")
        body.isHidden = lines.isEmpty
    }

    func height(forWidth w: CGFloat) -> CGFloat { 24 + 2 + 16 + (body.isHidden ? 0 : 12 + body.height(forWidth: w)) }

    override func layout() {
        super.layout()
        let w = bounds.width
        head.frame = NSRect(x: 0, y: 0, width: w, height: 24)
        sub.frame = NSRect(x: 0, y: 26, width: w, height: 16)
        body.frame = NSRect(x: 0, y: 54, width: w, height: body.height(forWidth: w))
    }
}

/// `WorkflowQuestionCard` (WorkflowRunFeed.tsx:1890-2047): `rounded-xl border border-warning/30 bg-warning-surface
/// px-3 py-2.5`, "Needs you" and when it was asked, the title, the body, its links, a button per choice with what it
/// does beside it, and a reason that a choice may require (#42515).
final class WorkflowQuestionCardView: DSView {
    var onReason: ((String?) -> Void)?
    var onOpenURL: ((String) -> Void)?
    var onAnswer: ((String, String?, @escaping @MainActor (String?) -> Void) -> Void)?

    private let needs = LabelView("Needs you", font: DSFont.ui(12, weight: .medium), color: Themed.color(\.warningForeground))
    private let asked = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    private let title = TextBlockView()
    private let body = TextBlockView()
    private var links: [ButtonView] = []
    private var choices: [(button: ButtonView, note: TextBlockView?)] = []
    private let addReason = WorkflowTextButton("Add a reason")
    private let reasonField = InputView(placeholder: "Why, in a sentence. It goes with whichever answer you pick.", size: .sm)
    private let needsReason = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    private let failure = LabelView("", font: DSFont.ui(12), color: Themed.color(\.destructive))
        private var reason: String?
    private var reasonFor: String?
    private var busy = false { didSet { sync() } }
    private var canAnswer = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for l in [needs, asked, needsReason, failure] { l.lineHeight = 16 }
        title.font = DSFont.ui(14, weight: .semibold)
        title.lineHeight = 20
        body.font = DSFont.ui(14)
        body.lineHeight = 20
        for v in [needs, asked, title, body, addReason, reasonField, needsReason, failure] as [NSView] { addSubview(v) }
        addReason.action = { [weak self] in self?.setReason("") ; self.map { $0.window?.makeFirstResponder($0.reasonField) } }
        reasonField.onChange = { [weak self] text in self?.setReason(text) }
        setAccessibilityElement(false)
    }

    override var isFlipped: Bool { true }

    func set(_ question: WorkflowQuestion, reason: String?, canAnswer: Bool, nowMs: Int64) {
        let view = WorkflowRuns.read(question)
        self.reason = reason
        self.canAnswer = canAnswer
        asked.text = "asked \(TimestampFormat.formatRelativeTimeLabel(question.askedAt, nowMs: nowMs)) · the run waits for you"
        title.text = view.title
        body.text = view.body ?? ""
        body.isHidden = view.body == nil
        links.forEach { $0.removeFromSuperview() }
        links = view.links.map { link in
            let b = ButtonView(link.label, variant: .outline, size: .sm)
            b.trailingIcon = .externalLink
            b.action = { [weak self] in self?.onOpenURL?(link.url) }
            addSubview(b)
            return b
        }
        choices.forEach { $0.button.removeFromSuperview(); $0.note?.removeFromSuperview() }
        choices = view.choices.enumerated().map { i, choice in
            let b = ButtonView(choice.value, variant: i == 0 ? .default : .outline, size: .sm)
            b.action = { [weak self] in self?.choose(choice) }
            addSubview(b)
            var note: TextBlockView?
            if let d = choice.description {
                let t = TextBlockView()
                t.text = d
                t.font = DSFont.ui(12)
                t.lineHeight = 16
                t.color = Themed.color(\.mutedForeground)
                addSubview(t)
                note = t
            }
            return (b, note)
        }
        reasonField.setAccessibilityLabel("Reason for \(view.title)")
        if let reason, reasonField.text != reason { reasonField.text = reason }
        sync()
    }

    private func setReason(_ text: String?) {
        reason = text
        onReason?(text)
        sync()
    }

    func choose(_ choice: WorkflowQuestionChoice) {
        guard !busy else { return }
        let given = reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if choice.requireReason && given.isEmpty {
            reasonFor = choice.value
            if reason == nil { setReason("") } else { sync() }
            window?.makeFirstResponder(reasonField)
            return
        }
        busy = true
        failure.text = ""
        onAnswer?(choice.value, given.isEmpty ? nil : given) { [weak self] error in
            self?.busy = false
            // `reportFailure(gt("Could not answer the question"), …)`.
            self?.failure.text = error.map { "Could not answer the question: \($0)" } ?? ""
            self?.sync()
        }
    }

    private func sync() {
        for c in choices { c.button.isEnabled = !busy && canAnswer }
        addReason.isHidden = reason != nil
        addReason.isEnabled = !busy
        reasonField.isHidden = reason == nil
        reasonField.isEnabled = !busy && canAnswer
        let missing = reasonFor != nil && (reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
        needsReason.isHidden = reason == nil || !missing
        needsReason.text = "\(reasonFor ?? "") needs a reason."
        failure.isHidden = failure.text.isEmpty
        needsLayout = true
        superview?.needsLayout = true
    }

    func height(forWidth w: CGFloat) -> CGFloat { place(width: w, apply: false) }

    override func layout() {
        super.layout()
        _ = place(width: bounds.width, apply: true)
    }

    private func place(width: CGFloat, apply: Bool) -> CGFloat {
        func set(_ v: NSView, _ r: NSRect) { if apply { v.frame = r } }
        // `border px-3 py-2.5`: the content starts inside the 1pt border.
        let x: CGFloat = 13, w = max(0, width - 26)
        var y: CGFloat = 11
        let nw = ceil(needs.textWidth) + 1
        set(needs, NSRect(x: x, y: y, width: nw, height: 16))
        set(asked, NSRect(x: x + nw + 8, y: y, width: max(0, w - nw - 8), height: 16))
        y += 16 + 4
        let th = title.height(forWidth: w)
        set(title, NSRect(x: x, y: y, width: w, height: th))
        y += th
        if !body.isHidden {
            y += 4
            let bh = body.height(forWidth: w)
            set(body, NSRect(x: x, y: y, width: w, height: bh))
            y += bh
        }
        // `mt-2 flex flex-wrap gap-2` for links, `mt-2.5 … items-start gap-2` for choices.
        func flow(_ items: [(NSView, TextBlockView?)], top: CGFloat) -> CGFloat {
            var cx = x, cy = top, rowH: CGFloat = 0
            for (b, note) in items {
                let bw = b.fittingSize.width
                // `max-w-60` beside the choice.
                let itemW = note.map { n in max(bw, min(240, ceil((n.text as NSString).size(withAttributes: [.font: n.font]).width) + 1)) } ?? bw
                if cx > x, cx + itemW > x + w { cx = x; cy += rowH + 8; rowH = 0 }
                set(b, NSRect(x: cx, y: cy, width: bw, height: 28))
                var ih: CGFloat = 28
                if let note {
                    let nh = note.height(forWidth: itemW)
                    set(note, NSRect(x: cx, y: cy + 32, width: itemW, height: nh))
                    ih += 4 + nh
                }
                rowH = max(rowH, ih)
                cx += itemW + 8
            }
            return items.isEmpty ? top : cy + rowH
        }
        if !links.isEmpty { y = flow(links.map { ($0, nil) }, top: y + 8) }
        if !choices.isEmpty { y = flow(choices.map { ($0.button, $0.note) }, top: y + 10) }
        if !addReason.isHidden {
            y += 8
            set(addReason, NSRect(x: x, y: y, width: addReason.preferredWidth, height: 16))
            y += 16
        }
        if !reasonField.isHidden {
            y += 8
            set(reasonField, NSRect(x: x, y: y, width: w, height: 28))
            y += 28
            if !needsReason.isHidden {
                y += 4
                set(needsReason, NSRect(x: x, y: y, width: w, height: 16))
                y += 16
            }
        }
        if !failure.isHidden {
            y += 6
            set(failure, NSRect(x: x, y: y, width: w, height: 16))
            y += 16
        }
        return y + 11
    }

    override var wantsUpdateLayer: Bool { false }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let r = DesignGeometry.radius(12, in: self)
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: r, yRadius: r)
        // Redesign: a card on the ground, its inset fill and rim; "Needs you" keeps the warning word.
        let redesign = ThemeRuntime.isDither(dark: effectiveAppearance.isDark)
        (redesign ? RedesignTokens.Card.fill : Themed.color(\.warningSurface)).setFill()
        path.fill()
        (redesign ? RedesignTokens.Card.border : Themed.color(\.warning, 0.3)).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}
