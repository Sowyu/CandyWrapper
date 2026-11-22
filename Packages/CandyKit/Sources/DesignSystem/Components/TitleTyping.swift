import AppKit

/// Deeper rename's typing effect on a thread title (the user, 2026-11-21: "when doing a deeper rename it should show a
/// typing effect and while its thinking it should show a blinking cursor before it types it out and if it fails it
/// just types out what it used to be"). The old title erases right to left, a cursor blinks while the model thinks,
/// then the new title, or the old one after a failure, types out behind it. This enum holds the timing as one pure
/// function; `TitleTypingOverlay` draws it.
public enum TitleTyping {
    /// Where a rename is. `id` tells one landing from the next, so a view plays each once.
    public enum Phase: Equatable, Sendable {
        case thinking(old: String)
        case landing(old: String, target: String, id: Int)
    }

    public enum Cursor: Equatable, Sendable { case hidden, on, off }

    public struct Frame: Equatable, Sendable {
        public var text: String
        public var cursor: Cursor
        public init(_ text: String, _ cursor: Cursor) { self.text = text; self.cursor = cursor }
    }

    /// The whole old title erases in this long.
    public static let eraseDuration: TimeInterval = 0.15
    /// One character a beat while typing, faster on a long title so it never takes longer than `typeCap`.
    public static let perCharacter: TimeInterval = 0.025
    public static let typeCap: TimeInterval = 0.8
    /// The thinking cursor: on half a second, off half a second.
    public static let blinkHalf: TimeInterval = 0.5
    /// After typing, two quick blinks (off, on, off, on), then the cursor goes.
    public static let tailBlinks = 2
    public static let tailHalf: TimeInterval = 0.2

    static func typeInterval(_ count: Int) -> TimeInterval { count == 0 ? 0 : min(perCharacter, typeCap / Double(count)) }

    /// How long a landing takes from its start to the cursor leaving.
    public static func landingDuration(_ target: String) -> TimeInterval {
        typeInterval(target.count) * Double(target.count) + Double(tailBlinks * 2) * tailHalf
    }

    /// What shows `elapsed` seconds into `phase`. With Reduce Motion nothing erases or types: a still cursor while
    /// thinking, then the title at once.
    public static func frame(_ phase: Phase, elapsed: TimeInterval, reduced: Bool = false) -> Frame {
        let t = max(0, elapsed)
        switch phase {
        case .thinking(let old):
            if reduced { return Frame("", .on) }
            if t < eraseDuration {
                let n = old.count
                let gone = Int((Double(n) * t / eraseDuration).rounded(.up))
                return Frame(String(old.prefix(max(0, n - gone))), .on)
            }
            return Frame("", Int((t - eraseDuration) / blinkHalf) % 2 == 0 ? .on : .off)
        case .landing(_, let target, _):
            if reduced { return Frame(target, .hidden) }
            let n = target.count, step = typeInterval(n)
            let typed = step == 0 ? n : min(n, Int(t / step))
            if typed < n { return Frame(String(target.prefix(typed)), .on) }
            let tail = t - step * Double(n)
            let beat = Int(tail / tailHalf)
            if beat >= tailBlinks * 2 { return Frame(target, .hidden) }
            return Frame(target, beat % 2 == 0 ? .off : .on)
        }
    }

    /// Whether `phase` has nothing left to show at `elapsed`.
    public static func isDone(_ phase: Phase, elapsed: TimeInterval, reduced: Bool = false) -> Bool {
        guard case .landing(_, let target, _) = phase else { return false }
        return reduced || elapsed >= landingDuration(target)
    }

    /// The title changed from somewhere else (a server update, a manual rename): the effect stops and the real title
    /// shows at once. A landing still accepts the old title, since the server's rename can arrive after it starts.
    public static func isInterrupted(_ phase: Phase, by title: String) -> Bool {
        switch phase {
        case .thinking(let old): title != old
        case .landing(let old, let target, _): title != target && title != old
        }
    }
}

/// Draws `TitleTyping` over a title label: a copy of the label with the visible text, and a thin cursor bar in the
/// label's color. The label itself is untouched and only hidden while the overlay shows, so the last frame is the
/// resting label. The thinking blink is a Core Animation loop; erasing and typing tick on a timer that runs only for
/// those 0.15 s and at most about 1.6 s, and only while the label is on screen.
public final class TitleTypingOverlay: DSView {
    private let copy = LabelView()
    private let cursor = CALayer()
    private weak var label: LabelView?
    private(set) var phase: TitleTyping.Phase?
    private var started: CFTimeInterval = 0
    private var timer: Timer?
    /// Landings this overlay played, so a refresh of the same row never replays one.
    private var played: Set<Int> = []
    public static var now: () -> CFTimeInterval = { CACurrentMediaTime() }
    /// The width the shown text and cursor take now, each time it renders, then nil when the effect ends: a host
    /// that hugs the title (Redesign's breadcrumb pill) follows it.
    public var onTextWidth: ((CGFloat?) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        addSubview(copy)
        cursor.actions = ["position": NSNull(), "bounds": NSNull(), "opacity": NSNull(), "backgroundColor": NSNull(), "hidden": NSNull()]
        layer?.addSublayer(cursor)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Shows `phase` over `label`, whose text is the real title, or takes the overlay away. Starts a phase only when
    /// it changes; an outside change of the title stops it.
    public static func sync(_ overlay: inout TitleTypingOverlay?, over label: LabelView, phase: TitleTyping.Phase?) {
        guard let phase, !TitleTyping.isInterrupted(phase, by: label.text) else {
            overlay?.finish()
            return
        }
        if case .landing(_, _, let id) = phase, let o = overlay, o.phase == nil, o.played.contains(id) { return }
        if overlay == nil, case .landing = phase {
            // A landing for a row that wasn't thinking here (it scrolled in, or was rebuilt): nothing to type over.
            return
        }
        let view = overlay ?? TitleTypingOverlay()
        overlay = view
        view.attach(to: label)
        if view.phase != phase { view.start(phase) } else { view.render() }
    }

    /// Keeps the overlay on its label after the host laid the label out again.
    public func follow() {
        guard let label, phase != nil else { return }
        attach(to: label)
        render()
    }

    private func attach(to label: LabelView) {
        self.label = label
        if superview !== label.superview || frame != label.frame {
            frame = label.frame
            if superview !== label.superview { label.superview?.addSubview(self, positioned: .above, relativeTo: label) }
        }
        copy.font = label.font
        copy.lineHeight = label.lineHeight
        copy.color = label.color
        copy.truncation = label.truncation
        copy.frame = bounds
        label.alphaValue = 0
    }

    private var onScreen: Bool { window?.isVisible == true && window?.occlusionState.contains(.visible) == true && !visibleRect.isEmpty }
    private var reduced: Bool { Motion.reduced }

    private func start(_ next: TitleTyping.Phase) {
        phase = next
        started = Self.now()
        if case .landing(_, _, let id) = next {
            played.insert(id)
            // Off screen when the title lands: no effect.
            if !onScreen { finish(); return }
        }
        render()
    }

    private var elapsed: TimeInterval { Self.now() - started }

    /// Puts up the frame for now, and keeps the timer only while text is changing.
    func render() {
        guard let phase, let label else { return }
        if TitleTyping.isDone(phase, elapsed: elapsed, reduced: reduced) { finish(); return }
        let f = TitleTyping.frame(phase, elapsed: elapsed, reduced: reduced)
        copy.text = f.text
        copy.color = label.color
        let font = label.font
        let h = ceil(font.ascender - font.descender)
        let typed = f.text.isEmpty ? 0 : ceil(copy.textWidth)
        let x = min(typed, max(0, bounds.width - 1.5))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        cursor.backgroundColor = label.color.cgColor(in: self)
        cursor.frame = CGRect(x: x, y: ((bounds.height - h) / 2).rounded(), width: 1.5, height: h)
        CATransaction.commit()
        onTextWidth?(typed + 2)
        let thinkingBlink: Bool = {
            guard case .thinking = phase, !reduced else { return false }
            return elapsed >= TitleTyping.eraseDuration
        }()
        if thinkingBlink {
            stopTimer()
            if cursor.animation(forKey: "blink") == nil { addBlink() }
        } else {
            cursor.removeAnimation(forKey: "blink")
            cursor.opacity = f.cursor == .on ? 1 : 0
            let moving = !reduced && (phaseChanging(phase))
            if moving, onScreen { startTimer() } else { stopTimer() }
            if moving, !onScreen, case .landing = phase { finish() }
        }
    }

    /// True while the frame still changes on its own: erasing, typing or the closing blinks.
    private func phaseChanging(_ phase: TitleTyping.Phase) -> Bool {
        switch phase {
        case .thinking: elapsed < TitleTyping.eraseDuration
        case .landing: true
        }
    }

    /// On half a second, off half a second, aligned to the end of the erase.
    private func addBlink() {
        let blink = CAKeyframeAnimation(keyPath: "opacity")
        blink.values = [1, 0]
        blink.keyTimes = [0, 0.5, 1] // discrete: one more key time than values
        blink.calculationMode = .discrete
        blink.duration = TitleTyping.blinkHalf * 2
        blink.repeatCount = .infinity
        blink.beginTime = cursor.convertTime(CACurrentMediaTime(), from: nil) - (elapsed - TitleTyping.eraseDuration)
        cursor.opacity = 1
        cursor.add(blink, forKey: "blink")
    }

    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.render() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() { timer?.invalidate(); timer = nil }

    /// Ends the effect: the label shows its own title again and the overlay leaves. Redesign fades the cursor out.
    func finish() {
        stopTimer()
        phase = nil
        label?.alphaValue = 1
        onTextWidth?(nil)
        copy.text = ""
        cursor.removeAnimation(forKey: "blink")
        let fades = cursor.opacity > 0 && window != nil && !reduced && ThemeRuntime.isDither(dark: effectiveAppearance.isDark)
        cursor.opacity = 0
        guard fades else { removeFromSuperview(); return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = RedesignTokens.Motion.fast
        fade.timingFunction = RedesignTokens.Motion.exitCurve
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated { if self?.phase == nil { self?.removeFromSuperview() } }
        }
        cursor.add(fade, forKey: "fade")
        CATransaction.commit()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopTimer() } else { render() }
    }
    public override func viewDidHide() { super.viewDidHide(); stopTimer() }
    public override func viewDidUnhide() { super.viewDidUnhide(); render() }
}
