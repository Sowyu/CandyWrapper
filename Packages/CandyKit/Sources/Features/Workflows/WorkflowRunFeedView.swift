import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// The picked run (5258 components/workflows/WorkflowRunFeed.tsx `WorkflowRunFeed`, :214-640): "Part of", the title
/// with its state and Stop, the meta line, then the run's timeline beside what happened at the step it shows.
final class WorkflowRunFeedView: DSView {
    var onSelect: ((String?) -> Void)?
    var onOpenURL: ((String) -> Void)?
    var onAnswer: ((String, String, String, String?, @escaping @MainActor (String?) -> Void) -> Void)?
    var onCancelRun: ((String) -> Void)?
    /// Resumes a paused run; the completion gets an error message on failure.
    var onResume: ((String, @escaping @MainActor (String?) -> Void) -> Void)?
    /// Opens an agent's thread (`onOpenThread`).
    var onOpenThread: ((WorkflowThreadTarget) -> Void)?
    var canOperate = true
    var ownSessionId: String?
    /// `@2xl/feed`: the feed's scroll area is 672pt or wider, so what happened sits beside the timeline.
    var wide = false { didSet { if wide != oldValue { timeline.wide = wide; needsLayout = true } } }
    /// The thread the pane beside the run shows, so its step's button reads as pressed.
    var openThread: WorkflowThreadTarget?

    private let partOf = WorkflowTextButton("")
    private let title = TextBlockView()
    private let state = WorkflowStateWordView()
    private let stop = ButtonView("Stop", icon: .square, variant: .ghostDestructive, size: .xs)
    private let chip = WorkflowChipView()
    private let meta = WorkflowWordsRow()
    private let status = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    private let notHere = TextBlockView()
    let timeline = WorkflowTimelineView()
    private let panel = WorkflowCardView()
    private let pausePanel = WorkflowCardView()
    private let nothing = LabelView("Nothing yet.", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    /// Without steps yet: the pause card and the questions, answerable all the same (:540-566).
    private var looseCards: [WorkflowQuestionCardView] = []
    private let loosePause = WorkflowCardView()
    private var node: WorkflowRunNode?
    private var parentId: String?
    private var hasFeed = false
    private var panelShows = false
    private var panelSignature = ""
    private var pauseAbove = false
    /// Reasons typed per question, kept while the steps reload (`AnswerDrafts`, :209-213).
    private var reasons: [String: String] = [:]
    private var picked: String?
    private var expanded: Set<String> = []
    private var busy = false
    private var cards: [String: WorkflowQuestionCardView] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title.font = DSFont.ui(16, weight: .semibold)
        title.lineHeight = 24
        status.lineHeight = 16
        nothing.lineHeight = 16
        notHere.font = DSFont.ui(14)
        notHere.lineHeight = 20
        notHere.color = Themed.color(\.mutedForeground)
        partOf.underlined = true
        stop.setAccessibilityLabel("Cancel run")
        stop.setTooltip("Cancel run")
        partOf.action = { [weak self] in self?.onSelect?(self?.parentId) }
        stop.action = { [weak self] in if let id = self?.node?.run.runId { self?.onCancelRun?(id) } }
        timeline.setAccessibilityLabel("Steps so far")
        panel.setAccessibilityLabel("What happened")
        timeline.onPick = { [weak self] in self?.pick($0) }
        timeline.makeCard = { [weak self] q in self?.questionCard(q, inline: true) ?? WorkflowQuestionCardView() }
        for v in [partOf, title, state, stop, chip, meta, status, notHere, timeline, pausePanel, panel, nothing, loosePause] as [NSView] { addSubview(v) }
    }

    override var isFlipped: Bool { true }

    private func questionCard(_ q: WorkflowQuestion, inline: Bool) -> WorkflowQuestionCardView {
        let card = WorkflowQuestionCardView()
        card.inline = inline
        let key = "\(q.runId):\(q.name):\(q.askedAt)"
        card.set(q, reason: reasons[key], canAnswer: canOperate, nowMs: TimestampFormat.nowMs())
        card.onReason = { [weak self] in self?.reasons[key] = $0; self?.needsLayout = true; self?.superview?.needsLayout = true }
        card.onOpenURL = { [weak self] in self?.onOpenURL?($0) }
        card.onAskAgent = q.thread.map { t in { [weak self] in self?.onOpenThread?(WorkflowThreadTarget(threadId: t.threadId, environmentId: t.environmentId)) } }
        card.onAnswer = { [weak self] choice, reason, done in
            self?.onAnswer?(q.runId, q.name, choice, reason) { error in
                if error == nil { self?.reasons[key] = nil }
                done(error)
            }
        }
        return card
    }

    // MARK: Model

    func set(node: WorkflowRunNode?, parent: WorkflowRun?, detail: WorkflowRunDetail?, error: String?, notHere missing: Bool, nowMs clock: Int64) {
        if node?.run.runId != self.node?.run.runId { picked = nil; expanded = []; busy = false; panelSignature = "" }
        self.node = node
        parentId = parent?.runId
        notHere.isHidden = !missing
        notHere.text = "This run is not here. This environment has no run with that link."
        for v in [partOf, title, state, stop, chip, meta, status] as [NSView] { v.isHidden = node == nil }
        guard let node else {
            hasFeed = false
            timeline.set(items: [], live: false)
            for v in [timeline, panel, pausePanel, nothing, loosePause] as [NSView] { v.isHidden = true }
            looseCards.forEach { $0.removeFromSuperview() }; looseCards = []
            needsLayout = true
            return
        }
        let run = node.run
        let ended = run.endedAt != nil
        // An ended run's last step can still read as running for a moment; it ran until the run ended (:228-229).
        let nowMs = run.endedAt.map(WorkflowTimeline.ms) ?? Double(clock)
        partOf.isHidden = parent == nil
        partOf.title = parent.map { "Part of \($0.title)" } ?? ""
        title.text = run.title
        state.set(node)
        stop.isHidden = ended
        stop.isEnabled = canOperate && !busy
        chip.name = run.workflow
        meta.parts = ([run.workflow] + WorkflowsPageLogic.metaLine(run, nowMs: clock)).flatMap { [$0, "·"] }.dropLast().map { $0 }
        let rows = detail.map { d in
            WorkflowTimeline.feed(WorkflowTimeline.rows(run: run, steps: d.steps, children: node.children.map(\.run), nowMs: nowMs))
        }
        hasFeed = error == nil && rows != nil && !(rows!.isEmpty && run.status == "paused" && node.questions.isEmpty)
        status.isHidden = !(error != nil || rows == nil)
        status.text = error ?? "Loading steps…"
        status.color = error == nil ? Themed.color(\.mutedForeground) : Themed.color(\.destructive)
        let kept = (detail?.steps ?? []).contains { $0.status == "completed" }
        if !hasFeed {
            timeline.isHidden = true
            for v in [panel, pausePanel, nothing] as [NSView] { v.isHidden = true }
            timeline.set(items: [], live: false)
            loosePause.isHidden = run.status != "paused"
            if run.status == "paused" { fillPause(loosePause, run: run, name: nil, attempts: Int(run.pauses), reason: run.detail, nowMs: nowMs, kept: kept) }
            looseCards.forEach { $0.removeFromSuperview() }
            looseCards = node.questions.map { q in let c = questionCard(q, inline: false); addSubview(c); return c }
            needsLayout = true
            return
        }
        loosePause.isHidden = true
        looseCards.forEach { $0.removeFromSuperview() }; looseCards = []
        timeline.isHidden = false
        build(node: node, rows: rows!, nowMs: nowMs, kept: kept)
        needsLayout = true
    }

    private func pick(_ key: String) {
        guard let node else { return }
        let asks = key.hasPrefix("question:") || node.questions.contains { "step:\($0.name)" == key }
        picked = asks ? nil : key
        onRepick?()
    }

    /// Asks the page to set the feed again, so a pick redraws with the page's own data.
    var onRepick: (() -> Void)?

    private func endWord(_ status: String) -> String {
        switch status { case "completed": "Finished"; case "stopped": "Stopped"; case "skipped": "Skipped"; default: "Cancelled" }
    }

    private func build(node: WorkflowRunNode, rows: [WorkflowFeedRow], nowMs: Double, kept: Bool) {
        let run = node.run
        let ended = run.endedAt != nil
        let beats = WorkflowTimeline.beats(rows)
        func questionOf(_ b: WorkflowBeat) -> WorkflowQuestion? {
            b.kind == "ask" && b.status == "running" ? node.questions.first { $0.name == b.name } : nil
        }
        let loose = node.questions.filter { q in !beats.contains { questionOf($0) == q } }
        let pausedAt = WorkflowTimeline.pausedBeat(rows, status: run.status)
        let pausedApart = run.status == "paused" && pausedAt == nil
        var keys = Set(rows.compactMap { if case .quick = $0 { return $0.key }; return nil })
        keys.formUnion(beats.map { "step:\($0.name)" })
        keys.formUnion(loose.map { "question:\($0.name)" })
        if pausedApart { keys.insert("pause") }
        if ended { keys.insert("end") }
        // A finished run opens on what it came to (:375-395).
        let lastAnswer = beats.last { $0.kind == "ask" && $0.status == "completed" }
        let answered = lastAnswer.flatMap { WorkflowsPageLogic.answer($0.result) }
        let resultLines = WorkflowRuns.resultLines(run.result)
        let resultSaysMore = !resultLines.isEmpty && !(resultLines.count == 1 && answered != nil && resultLines[0].value == answered!.choice)
        func latest(_ found: [WorkflowBeat]) -> WorkflowBeat? { found.reduce(nil) { best, b in best == nil || b.endMs >= best!.endMs ? b : best } }
        let lastAgent = latest(beats.filter { $0.kind == "agent" && $0.status == "completed" })
        let finishedFocus = run.status != "completed" || resultSaysMore || lastAgent == nil ? "end" : "step:\(lastAgent!.name)"
        let focus: String? = picked.flatMap { keys.contains($0) ? $0 : nil }
            ?? (ended ? finishedFocus : WorkflowTimeline.focus(rows, status: run.status, ended: ended, questions: node.questions.map(\.name)))
        let asking = focus.map { f in
            f.hasPrefix("question:") || beats.contains { "step:\($0.name)" == f && (questionOf($0) != nil || ($0.kind == "ask" && $0.status == "running")) }
        } ?? false
        let before: WorkflowBeat? = asking
            ? latest(beats.filter { $0.kind == "agent" && $0.status != "running" })
                ?? beats.last { $0.status != "running" && !["ask", "sleep", "wait", "queue"].contains($0.kind) }
            : nil
        let shown = asking ? before.map { "step:\($0.name)" } : focus
        let marked = picked.flatMap { keys.contains($0) ? $0 : nil }

        // The timeline (:1006-1218).
        func child(_ b: WorkflowBeat) -> WorkflowRunNode? { node.children.first { $0.run.runId == b.childRun?.runId } }
        func line(_ b: WorkflowBeat, sub: Bool) -> WorkflowTimelineLine {
            var l = beatLine(b, child: child(b), asks: node.questions.contains { $0.name == b.name }, nowMs: nowMs)
            l.selected = marked == "step:\(b.name)"
            l.current = shown == "step:\(b.name)"
            l.sub = sub
            return l
        }
        var items: [WorkflowTimelineView.Item] = []
        for row in rows {
            switch row {
            case .quick(let steps, let start, let end):
                let names = steps.map(\.name)
                let name = names.count <= 2 ? names.joined(separator: " · ")
                    : "\(names.prefix(2).joined(separator: " · ")) and \(names.count - 2) more"
                items.append(.init(parts: [.row(.init(tone: .done, name: name, duration: WorkflowTimeline.stepTime(max(0, end - start)),
                                                      selected: marked == row.key, current: shown == row.key), key: row.key)]))
            case .together(let bs):
                let running = bs.filter { $0.status == "running" }.count
                let working = bs.contains { $0.status == "running" && !["sleep", "wait", "queue"].contains($0.kind) }
                let failed = bs.contains { $0.status == "failed" }
                let asks = bs.contains { b in b.status == "running" && node.questions.contains { $0.name == b.name } }
                let start = bs.map(\.startMs).min()!, end = bs.map(\.endMs).max()!
                let tone: WorkflowStepTone = asks ? .input : working ? .working : running > 0 ? .quiet : failed ? .failed : .done
                let head = WorkflowTimelineLine(tone: tone, name: "\(bs.count) in parallel",
                                                duration: WorkflowTimeline.stepTime(running > 0 ? WorkflowTimeline.wholeSeconds(end - start) : end - start))
                items.append(.init(parts: [.together(head: head, running: working ? running : nil,
                                                     rows: bs.map { (line($0, sub: true), "step:\($0.name)", questionOf($0)) })], branch: true))
            case .beat(let b):
                var parts: [WorkflowTimelineView.Part] = [.row(line(b, sub: false), key: "step:\(b.name)")]
                if let q = questionOf(b) { parts.append(.question(q)) }
                items.append(.init(parts: parts))
            }
        }
        for q in loose {
            let key = "question:\(q.name)"
            items.append(.init(parts: [.row(.init(tone: .input, name: q.name, verb: "Asks you", verbTone: .input,
                                                  selected: marked == key, current: shown == key), key: key), .question(q)]))
        }
        if pausedApart {
            items.append(.init(parts: [.row(.init(tone: .failed, name: "Paused", selected: marked == "pause", current: shown == "pause"), key: "pause")]))
        }
        if ended, run.status != "completed" {
            items.append(.init(parts: [.row(.init(tone: .ended, name: endWord(run.status), aside: run.detail,
                                                  selected: marked == "end", current: shown == "end"), key: "end")]))
        }
        timeline.set(items: items, live: !ended)

        // What happened (:567-636).
        let shownBeat = beats.first { "step:\($0.name)" == shown }
        let shownQuick = rows.first { if case .quick = $0 { return $0.key == shown }; return false }
        pauseAbove = shownBeat != nil && shownBeat == pausedAt
        pausePanel.isHidden = !pauseAbove
        if pauseAbove, let b = shownBeat {
            fillPause(pausePanel, run: run, name: b.name, attempts: b.attempts, reason: b.detail ?? run.detail, nowMs: nowMs, kept: kept)
        }
        nothing.isHidden = true
        panel.isHidden = false
        if let b = shownBeat {
            let sig = "beat|\(b.name)|\(b.kind)|\(b.status)|\(b.attempts)|\(String(describing: b.result))|\(b.said ?? "")|\(b.detail ?? "")|"
                + "\(child(b).map { WorkflowRuns.now($0) + WorkflowRuns.state($0).word } ?? "")|\(expanded.contains(b.name))|\(openThread == b.thread)"
            let spec = beatCard(b, child: child(b), nowMs: nowMs)
            fillPanel(sig, spec)
        } else if case .quick(let steps, _, _)? = shownQuick {
            // `WorkflowQuickStepsCard` (:1495-1509): no head, each step's name and what it left.
            let sig = "quick|\(shown ?? "")|\(steps.map(\.name))"
            if sig != panelSignature {
                panelSignature = sig
                panel.set(mark: .none, name: "", sub: nil, actions: [], blocks: steps.map { .quick($0.name, WorkflowRuns.resultLines($0.result)) },
                          label: "Quick steps")
            }
        } else if asking {
            panel.isHidden = true
            panelSignature = ""
        } else if focus == "pause" {
            panelSignature = ""
            fillPause(panel, run: run, name: nil, attempts: Int(run.pauses), reason: run.detail, nowMs: nowMs, kept: kept)
        } else if focus == "end" {
            var blocks: [WorkflowCardView.Block] = []
            if run.status != "completed", let d = run.detail, !d.isEmpty { blocks.append(.text(d, top: 12)) }
            blocks += resultBlocks(resultLines)
            let done = run.status == "completed"
            fillPanel("end|\(run.status)|\(run.detail ?? "")|\(resultLines.map { "\($0.label ?? ""):\($0.value)" })",
                      (done ? .icon(.check, Themed.color(\.successForeground), 14) : .none, endWord(run.status),
                       TimestampFormat.formatRelativeTimeLabel(run.endedAt ?? run.updatedAt, nowMs: Int64(nowMs)), [], blocks, nil))
        } else {
            panel.isHidden = true
            nothing.isHidden = false
            panelSignature = ""
        }
    }

    typealias CardSpec = (mark: WorkflowCardView.Mark, name: String, sub: String?, actions: [NSView], blocks: [WorkflowCardView.Block], label: String?)

    /// Sets the card only when what it says changed; a ticking time changes only its line under the name.
    private func fillPanel(_ signature: String, _ spec: CardSpec) {
        if signature == panelSignature { panel.setSub(spec.sub ?? ""); return }
        panelSignature = signature
        panel.set(mark: spec.mark, name: spec.name, sub: spec.sub, actions: spec.actions, blocks: spec.blocks, label: spec.label)
        panel.setMoreTitle(expanded.isEmpty ? "Show more" : "Show less")
    }

    private func resultBlocks(_ lines: [(label: String?, value: String)]) -> [WorkflowCardView.Block] {
        guard !lines.isEmpty else { return [] }
        if lines.allSatisfy({ $0.label == nil }) {
            return lines.enumerated().map { i, l in .text(l.value, top: i == 0 ? 12 : 4) }
        }
        return [.facts(lines.map { ($0.label ?? "", $0.value) })]
    }

    /// `WorkflowPauseCard` (:1827-1888): why it paused, when it goes on, and Resume.
    private func fillPause(_ card: WorkflowCardView, run: WorkflowRun, name: String?, attempts: Int, reason: String?, nowMs: Double, kept: Bool) {
        let resumes = run.resumesAt.map(WorkflowTimeline.ms)
        let next = run.retired ? "cannot go on until its workflow version is registered again"
            : resumes == nil ? "waits for you to resume it"
            : resumes! > nowMs ? "tries again by itself in \(formatDuration(resumes! - nowMs))" : "about to try again by itself"
        let sub = (attempts > 0 ? "\(WorkflowTimeline.nthTry(attempts)) · " : "")
            + "\(TimestampFormat.formatRelativeTimeLabel(run.updatedAt, nowMs: Int64(nowMs))) · \(next)"
        let resume = ButtonView("Resume", variant: .default, size: .compact)
        resume.isEnabled = !busy && canOperate && !run.retired
        resume.action = { [weak self] in
            guard let self, !self.busy else { return }
            self.busy = true
            self.onRepick?()
            self.onResume?(run.runId) { [weak self] _ in self?.busy = false; self?.onRepick?() }
        }
        var blocks: [WorkflowCardView.Block] = []
        if let reason, !reason.isEmpty { blocks.append(.text(reason, top: 12)) }
        if kept { blocks.append(.text("Only the failed step runs again; what finished before it is kept.", top: 8, small: true)) }
        card.set(mark: .icon(.circleAlert, Themed.color(\.destructive), 14), name: name.map { "Paused at \($0)" } ?? "Paused", sub: sub,
                 actions: [resume], blocks: blocks, label: "Why it paused")
    }

    // MARK: A step's words

    private func queuedText(_ b: WorkflowBeat) -> String {
        (b.ahead ?? 0) == 0 ? "queued, next in line" : "queued, \(b.ahead!) ahead"
    }

    private func answerWho(_ a: (choice: String, reason: String?, answeredBy: String?, answeredBySession: String?)) -> String? {
        // `isOwnWorkflowAnswer` (workflows.ts:712-716): decided by session, never by name.
        a.answeredBy == nil || (a.answeredBySession != nil && a.answeredBySession == ownSessionId) ? nil : a.answeredBy
    }

    /// `WorkflowBeatRow` (:1219-1361), without the agent's provider mark, model and pending approvals, which come from
    /// the thread's shell.
    // ponytail: agent rows lack the provider icon, model note and "waits for your approval"; join the thread
    // shell's model and pending state from the app when a workflow's agent rows read too bare.
    private func beatLine(_ b: WorkflowBeat, child: WorkflowRunNode?, asks: Bool, nowMs: Double) -> WorkflowTimelineLine {
        let under = b.status == "running", failed = b.status == "failed"
        let needsYou = under && (asks || b.kind == "ask")
        let quietKind = ["sleep", "wait", "queue"].contains(b.kind)
        var verb: String?
        if under {
            switch b.kind {
            case "agent": verb = "working"
            case "ask": verb = asks ? "Asks you" : nil
            case "sleep":
                let wakes = b.detail.map(WorkflowTimeline.ms) ?? .nan
                verb = wakes.isFinite && wakes > nowMs ? "wakes in \(formatDuration(WorkflowTimeline.wholeSeconds(wakes - nowMs)))" : "about to wake"
            case "wait": verb = "waiting"
            case "queue": verb = queuedText(b)
            case "run": verb = child.map(WorkflowRuns.now) ?? "running"
            default: verb = "running"
            }
        }
        var aside: String?
        if failed { aside = WorkflowTimeline.oneLine(b.detail ?? "failed") } else if !under {
            switch b.kind {
            case "agent": aside = WorkflowTimeline.agentSummary(result: b.result, said: b.said).said.map(WorkflowTimeline.oneLine)
            case "ask":
                if let a = WorkflowsPageLogic.answer(b.result) {
                    aside = answerWho(a).map { "\($0) said \(a.choice)" } ?? "You said \(a.choice)"
                } else {
                    aside = WorkflowsPageLogic.withdrawal(b.result).map { "withdrawn by \($0.by)" } ?? "nobody answered"
                }
            case "run": aside = child.map(WorkflowRuns.now)
            case "step": aside = WorkflowRuns.resultLines(b.result).first.map { $0.label.map { l in "\(l): " } ?? "" }.map { prefix in
                prefix + WorkflowRuns.resultLines(b.result)[0].value }
            default: break
            }
        }
        return WorkflowTimelineLine(
            tone: failed ? .failed : needsYou ? .input : under ? (quietKind ? .quiet : .working) : .done,
            name: b.childRun?.title ?? b.name, chip: b.kind == "run" ? (b.childRun?.workflow ?? b.name) : nil,
            aside: aside, asideFailed: failed, verb: verb, verbTone: needsYou ? .input : quietKind ? .quiet : .working,
            duration: WorkflowTimeline.stepTime(WorkflowTimeline.elapsed(b)))
    }

    /// `WorkflowBeatCard` and `WorkflowAgentCard` (:1511-1825).
    private func beatCard(_ b: WorkflowBeat, child: WorkflowRunNode?, nowMs: Double) -> CardSpec {
        let under = b.status == "running"
        let length = formatDuration(WorkflowTimeline.elapsed(b))
        let tries = b.attempts > 1 ? " · \(WorkflowTimeline.nthTry(b.attempts))" : ""
        let muted = Themed.color(\.mutedForeground)
        func note(_ sub: String, _ blocks: [WorkflowCardView.Block] = []) -> CardSpec { (.none, b.name, sub, [], blocks, nil) }
        switch b.kind {
        case "agent":
            let summary = WorkflowTimeline.agentSummary(result: b.result, said: b.said)
            let elsewhere = b.thread?.environmentId != nil
            let sub = [under ? "working" : nil, length, b.attempts > 1 ? WorkflowTimeline.nthTry(b.attempts) : nil,
                       elsewhere ? "on \(b.thread!.environmentId!)" : nil].compactMap { $0 }.joined(separator: " · ")
            var actions: [NSView] = []
            if let t = b.thread {
                let open = openThread == t
                let button = ButtonView(under ? "Watch live" : "Transcript", variant: open ? .secondary : .ghostMuted, size: .compact)
                button.trailingIcon = .arrowUpRight
                button.setAccessibilityValue(open ? "pressed" : nil)
                button.action = { [weak self] in self?.onOpenThread?(t) }
                actions.append(button)
            }
            var blocks: [WorkflowCardView.Block] = []
            if b.status == "failed", let d = b.detail, !d.isEmpty { blocks.append(.failure(d)) }
            if let said = summary.said {
                // `SAID_SHOWN` (:92): a long reply shows its start until Show more.
                let start = WorkflowTimeline.saidStart(said, limit: 320)
                panel.onToggleMore = start == nil ? nil : { [weak self] in
                    guard let self else { return }
                    if self.expanded.contains(b.name) { self.expanded.remove(b.name) } else { self.expanded.insert(b.name) }
                    self.onRepick?()
                }
                blocks.append(.reply(start != nil && !expanded.contains(b.name) ? start! : said))
            } else { panel.onToggleMore = nil }
            if !summary.facts.isEmpty { blocks.append(.facts(summary.facts)) }
            return (.icon(.bot, under ? Themed.color(\.infoForeground) : muted, 16), b.name, sub, actions, blocks, nil)
        case "ask":
            if let a = WorkflowsPageLogic.answer(b.result) {
                let who = answerWho(a)
                var blocks: [WorkflowCardView.Block] = [.said(who.map { "\($0) said " } ?? "You said ", bold: a.choice, rest: a.reason.map { ": \($0)" } ?? ".")]
                if case .string(let at)? = b.result?["answeredAt"] {
                    blocks.append(.text("answered \(TimestampFormat.formatRelativeTimeLabel(at, nowMs: Int64(nowMs)))", top: 4, small: true))
                }
                return (.none, b.name, length, [], blocks, nil)
            }
            if let w = WorkflowsPageLogic.withdrawal(b.result) {
                return note("withdrawn · \(length)", [.text(w.reason.map { "Withdrawn by \(w.by): \($0)" } ?? "Withdrawn by \(w.by).", top: 12)])
            }
            return note("nobody answered · \(length)")
        case "sleep":
            guard under else { return note("slept · \(length)") }
            let wakes = b.detail.map(WorkflowTimeline.ms) ?? .nan
            return (.icon(.moon, muted, 14), b.name,
                    wakes.isFinite && wakes > nowMs ? "wakes in \(formatDuration(WorkflowTimeline.wholeSeconds(wakes - nowMs)))" : "about to wake", [], [], nil)
        case "wait":
            guard under else { return note("waited · \(length)") }
            return (.icon(.hourglass, muted, 14), b.name, "\(length) so far", [], [], nil)
        case "queue":
            guard under else { return note("queued · \(length)") }
            return (.icon(.hourglass, muted, 14), b.name, "\(queuedText(b)) · \(length)", [], [], nil)
        case "run":
            let title = b.childRun?.title ?? b.name
            var actions: [NSView] = []
            if let child {
                let word = WorkflowStateWordView()
                word.set(child)
                word.frame.size = NSSize(width: word.width, height: 16)
                actions.append(word)
            }
            let open = ButtonView("Open run", variant: .outline, size: .compact)
            open.action = { [weak self] in self?.onSelect?(b.childRun?.runId) }
            actions.append(open)
            return (.chip(b.childRun?.workflow ?? b.name), title,
                    child.map { "\($0.run.workflow) · \(WorkflowRuns.now($0))" } ?? "\(b.childRun?.workflow ?? "") · \(length)", actions, [], title)
        default:
            if under { return (.dot, b.name, "running for \(length)\(tries)", [], [], nil) }
            return note((b.status == "failed" ? "failed · \(length)" : length) + tries, resultBlocks(WorkflowRuns.resultLines(b.result)))
        }
    }

    // MARK: Layout

    /// The height the feed needs at `width`.
    func height(forWidth width: CGFloat) -> CGFloat { place(width: width, apply: false) }

    override func layout() {
        super.layout()
        _ = place(width: bounds.width, apply: true)
    }

    private var panelRule: NSRect?

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
        set(state, NSRect(x: tw + 8, y: y + (th - 16) / 2, width: sw, height: 16))
        if !stop.isHidden { set(stop, NSRect(x: w - stopW + 8, y: y + (th - 24) / 2, width: stopW - 8, height: 24)) }
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
        var rule: NSRect?
        if !hasFeed {
            if !loosePause.isHidden {
                y += 16
                rule = NSRect(x: 0, y: y, width: w, height: 1)
                y += 17
                let cw = min(w, 672)
                let h = loosePause.height(forWidth: cw)
                set(loosePause, NSRect(x: 0, y: y, width: cw, height: h))
                y += h
            }
            for c in looseCards {
                y += 16
                let h = c.height(forWidth: w)
                set(c, NSRect(x: 0, y: y, width: w, height: h))
                y += h
            }
            if apply { panelRule = rule; needsDisplay = true }
            return y
        }
        // `mt-4 flex flex-col gap-4 @2xl/feed:flex-row`.
        y += 16
        let tlW = wide ? 384 : w
        let th2 = timeline.height(forWidth: tlW)
        set(timeline, NSRect(x: 0, y: y, width: tlW, height: th2))
        var px: CGFloat, py: CGFloat, pw: CGFloat
        if wide {
            // `@2xl/feed:border-s @2xl/feed:ps-6 @2xl/feed:pt-1`.
            rule = NSRect(x: tlW + 16, y: y, width: 1, height: 0)
            px = tlW + 16 + 1 + 24; py = y + 4; pw = max(0, w - px)
        } else {
            // `border-t pt-4`.
            let top = y + th2 + 16
            rule = NSRect(x: 0, y: top, width: w, height: 1)
            px = 0; py = top + 1 + 16; pw = w
        }
        var bottom = py
        if !pausePanel.isHidden {
            let h = pausePanel.height(forWidth: pw)
            set(pausePanel, NSRect(x: px, y: bottom, width: pw, height: h))
            bottom += h + 12
        }
        if !panel.isHidden {
            let h = panel.height(forWidth: pw)
            set(panel, NSRect(x: px, y: bottom, width: pw, height: h))
            bottom += h
        }
        if !nothing.isHidden {
            set(nothing, NSRect(x: px, y: bottom, width: pw, height: 16))
            bottom += 16
        }
        if wide, var r = rule { r.size.height = max(th2, bottom - y); rule = r }
        if apply { panelRule = rule; needsDisplay = true }
        return wide ? y + max(th2, bottom - y) : bottom
    }

    override var wantsUpdateLayer: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        guard let panelRule else { return }
        Themed.color(\.border).setFill()
        panelRule.fill()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

/// `WorkflowQuestionCard` (WorkflowRunFeed.tsx:1890-2047): `rounded-xl border border-warning/30 bg-warning-surface
/// px-3 py-2.5`, "Needs you" and when it was asked, the title, the body, its links, a button per choice with what it
/// does beside it, and a reason that a choice may require (#42515).
final class WorkflowQuestionCardView: DSView {
    var onReason: ((String?) -> Void)?
    var onOpenURL: ((String) -> Void)?
    var onAnswer: ((String, String?, @escaping @MainActor (String?) -> Void) -> Void)?
    /// "Ask the agent first" (:2008-2016), shown when the question names a thread this client can open.
    var onAskAgent: (() -> Void)? { didSet { askAgent.isHidden = onAskAgent == nil; needsLayout = true } }
    /// Under its step in the run, which already says that it asks: no "Needs you" line (:1898-1900, :1950-1966).
    var inline = false { didSet { needs.isHidden = inline; asked.isHidden = inline; needsLayout = true } }
    private let askAgent = WorkflowTextButton("Ask the agent first")

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
        for v in [needs, asked, title, body, addReason, askAgent, reasonField, needsReason, failure] as [NSView] { addSubview(v) }
        askAgent.isHidden = true
        askAgent.action = { [weak self] in self?.onAskAgent?() }
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
        if !inline {
            set(needs, NSRect(x: x, y: y, width: nw, height: 16))
            set(asked, NSRect(x: x + nw + 8, y: y, width: max(0, w - nw - 8), height: 16))
            y += 16 + 4
        }
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
        // Redesign lists choices that say what they do one per row, the note beside its button and the notes in one
        // column, so a long note never pushes the next button away.
        func rows(top: CGFloat) -> CGFloat {
            let column = choices.map { $0.button.fittingSize.width }.max() ?? 0
            let noteX = x + column + RedesignTokens.Space.m, noteW = max(0, x + w - noteX)
            var cy = top
            for (i, (b, note)) in choices.enumerated() {
                if i > 0 { cy += RedesignTokens.Space.s }
                set(b, NSRect(x: x, y: cy, width: b.fittingSize.width, height: 28))
                var rowH: CGFloat = 28
                if let note {
                    let nh = note.height(forWidth: noteW)
                    set(note, NSRect(x: noteX, y: cy + max(0, (28 - nh) / 2), width: noteW, height: nh))
                    rowH = max(rowH, nh)
                }
                cy += rowH
            }
            return cy
        }
        if !links.isEmpty { y = flow(links.map { ($0, nil) }, top: y + 8) }
        if !choices.isEmpty {
            let redesign = ThemeRuntime.isDither(dark: effectiveAppearance.isDark)
            y = redesign && choices.contains(where: { $0.note != nil }) ? rows(top: y + 10) : flow(choices.map { ($0.button, $0.note) }, top: y + 10)
        }
        // `mt-2 flex flex-wrap gap-x-4`: Add a reason, then Ask the agent first.
        if !addReason.isHidden || !askAgent.isHidden {
            y += 8
            var bx = x
            for b in [addReason, askAgent] where !b.isHidden {
                set(b, NSRect(x: bx, y: y, width: b.preferredWidth, height: 16))
                bx += b.preferredWidth + 16
            }
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
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Redesign lays the choices out differently, so the height may change.
        needsDisplay = true; needsLayout = true; superview?.needsLayout = true
    }
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
