import AppKit
import CoreVideo
import DesignSystem
import T3Protocol

/// A server browser tab's viewer (`ServerBrowserSurface`, apps/web/src/browser/ServerBrowserSurface.tsx):
/// the control bar ("You have control" with Take or Release control), the newest JPEG frame drawn
/// `object-contain`, the agent's cursor, and the page's dialog, file chooser, host setup and refused
/// states. Mouse, wheel and keys become stream input in page CSS px while this viewer has control.
/// The app owns the socket: it sets `control`, `viewport` and frames, and sends what `onInput` gives.
public final class ServerBrowserView: DSView {
    public enum ControlPosition { case top, bottom }

    public var controlPosition: ControlPosition = .top { didSet { needsLayout = true } }
    /// Input for the page. Moves and wheel deltas are coalesced to one message each per frame.
    public var onInput: (@MainActor (PreviewStream.Input) -> Void)?
    /// The frame area's size in points, after T3's 150 ms settle (the first size goes at once).
    public var onSizeChange: (@MainActor (CGSize) -> Void)?
    /// Files for the page's picker; an empty list cancels it.
    public var onChooseFiles: (@MainActor ([URL]) -> Void)?
    public var onRetryHostSetup: (@MainActor () -> Void)?
    public var onReconnect: (@MainActor () -> Void)?

    /// The latest `control`; nil while disconnected.
    public var control: PreviewStream.Control? { didSet { if control != oldValue { controlChanged(from: oldValue) } } }
    /// The page's CSS viewport from the stream's `viewport` message.
    public var viewport: CGSize?
    /// The page picker the server asked about (`fileChooser`), nil once answered or replaced.
    public var fileChooser: (multiple: Bool, accept: String)? { didSet { rebuildOverlays() } }
    public var hostSetup: PreviewStream.HostSetup? { didSet { rebuildOverlays() } }
    public var accessDenied = false { didSet { if accessDenied != oldValue { rebuildOverlays() } } }
    /// The page under an empty or unreachable state: the bar stays, the frame and input go.
    public var contentHidden = false { didSet { frameView.isHidden = contentHidden; cursor.isHidden = contentHidden || cursorHidden } }
    public private(set) var hasFrame = false
    /// The first frame painted (`onFirstFrame`).
    public var onFirstFrame: (@MainActor () -> Void)?

    let bar = DSView()
    let status = LabelView("Connecting...", font: DSFont.ui(12))
    let controlButton = ButtonView("Take control", variant: .outline, size: .xs)
    private let barBorder = CALayer()
    let frameView = FrameView()
    let cursor = AgentCursorView()
    private var cursorHidden = true
    private var overlays: [NSView] = []
    private var promptField: InputView?

    private var pendingMove: PreviewStream.Input?
    private var pendingWheel: (x: Double, y: Double, dx: Double, dy: Double, modifiers: Int)?
    private var flushScheduled = false
    private var pressedButtons = 0
    private var sizeTimer: Timer?
    private var reportedSize: CGSize?
    private var tracking: NSTrackingArea?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clipsToBounds = true
        status.lineHeight = 16
        controlButton.action = { [weak self] in
            guard let self, let control = self.control else { return }
            self.onInput?(control.controller == .you ? .releaseControl : .takeControl)
        }
        controlButton.isHidden = true
        barBorder.actions = ["frame": NSNull(), "position": NSNull(), "bounds": NSNull()]
        bar.layer?.addSublayer(barBorder)
        [status, controlButton].forEach(bar.addSubview)
        cursor.isHidden = true
        [frameView, cursor, bar].forEach(addSubview)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Browser page")
        setAccessibilityHelp("Press Shift+Escape to leave the browser page.")
    }

    // MARK: Frames

    /// Shows a decoded frame. Only the newest one reaches here.
    public func setFrame(_ frame: CVPixelBuffer) {
        frameView.buffer = frame
        if !hasFrame {
            hasFrame = true
            onFirstFrame?()
        }
    }

    /// Clears the page (a new socket or tab).
    public func reset() {
        frameView.buffer = nil
        hasFrame = false
        viewport = nil
        control = nil
        fileChooser = nil
        cursorHidden = true
        cursor.isHidden = true
        reportedSize = nil
        clearInput()
    }

    /// The agent's pointer at a page point (`placeAgentCursor`).
    public func showPointer(phase: String, x: Double, y: Double, sequence: Int) {
        guard let viewport, let image = frameView.pixelSize, viewport.width > 0, viewport.height > 0 else { return }
        let fit = BrowserPointerMap.fittedRect(box: frameView.bounds.size, image: image)
        let left = frameView.frame.minX + fit.minX + x * fit.width / viewport.width
        let top = frameView.frame.minY + fit.minY + y * fit.height / viewport.height
        cursorHidden = control?.controller == .you
        cursor.isHidden = cursorHidden || contentHidden
        cursor.show(at: CGPoint(x: left, y: top), click: phase == "click", sequence: sequence,
                    controller: control?.controller == .agent ? .agent : .none)
    }

    // MARK: Control

    private func controlChanged(from old: PreviewStream.Control?) {
        status.text = PreviewStream.Control.label(control)
        if let control, control.canOperate {
            controlButton.isHidden = false
            controlButton.title = control.controller == .you ? "Release control" : "Take control"
            controlButton.isEnabled = control.controller != .anotherViewer
        } else {
            controlButton.isHidden = true
        }
        if control?.controller != .you {
            clearInput()
            if window?.firstResponder === self { window?.makeFirstResponder(nil) }
        } else {
            cursorHidden = true
            cursor.isHidden = true
        }
        if control?.dialog != old?.dialog || control?.controller != old?.controller { rebuildOverlays() }
        needsLayout = true
    }

    private var hasControl: Bool { control?.controller == .you }

    private func clearInput() {
        pendingMove = nil
        pendingWheel = nil
        pressedButtons = 0
    }

    // MARK: Overlays

    private func rebuildOverlays() {
        overlays.forEach { $0.removeFromSuperview() }
        overlays = []
        promptField = nil
        if let fileChooser, hasControl {
            let card = OverlayCard()
            card.message = "The page asks for \(fileChooser.multiple ? "files" : "a file")."
            let cancel = ButtonView("Cancel", variant: .outline, size: .sm)
            cancel.action = { [weak self] in self?.answerFileChooser([]) }
            let choose = ButtonView("Choose \(fileChooser.multiple ? "files" : "file")", variant: .default, size: .sm)
            choose.action = { [weak self] in self?.pickFiles() }
            card.buttons = [cancel, choose]
            card.setAccessibilityLabel("Choose files for the page")
            overlays.append(card)
        }
        if let dialog = control?.dialog {
            let card = OverlayCard()
            card.message = dialog.message
            if hasControl {
                if dialog.type == "prompt" {
                    let field = InputView(placeholder: "", text: dialog.defaultValue, size: .default)
                    field.setAccessibilityLabel("Dialog response")
                    card.field = field
                    promptField = field
                }
                let dismiss = ButtonView("Dismiss", variant: .outline, size: .sm)
                dismiss.action = { [weak self] in self?.onInput?(.dialog(accept: false, promptText: nil)) }
                let accept = ButtonView("Accept", variant: .default, size: .sm)
                accept.action = { [weak self] in
                    guard let self else { return }
                    self.onInput?(.dialog(accept: true, promptText: dialog.type == "prompt" ? (self.promptField?.text ?? "") : nil))
                }
                card.buttons = [dismiss, accept]
            } else {
                card.note = "Take control to respond."
            }
            card.setAccessibilityLabel("Browser dialog")
            overlays.append(card)
        }
        if let hostSetup {
            let cover = CoverView()
            cover.message = hostSetup.message
            cover.command = hostSetup.command
            let retry = ButtonView("Try again", variant: .outline, size: .sm)
            retry.action = { [weak self] in self?.hostSetup = nil; self?.onRetryHostSetup?() }
            cover.button = retry
            overlays.append(cover)
        } else if accessDenied {
            let cover = CoverView()
            cover.message = "Browser connection was refused."
            cover.small = true
            let reconnect = ButtonView("Reconnect", variant: .outline, size: .sm)
            reconnect.action = { [weak self] in self?.accessDenied = false; self?.onReconnect?() }
            cover.button = reconnect
            overlays.append(cover)
        }
        overlays.forEach { addSubview($0, positioned: .below, relativeTo: bar) }
        for case let cover as CoverView in overlays { addSubview(cover) }
        needsLayout = true
    }

    private func pickFiles() {
        guard let fileChooser else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = fileChooser.multiple
        panel.canChooseDirectories = false
        // ponytail: the `accept` attribute is not mapped to content types; the page validates what it gets
        panel.begin { [weak self] response in
            guard response == .OK, !panel.urls.isEmpty else { return }
            MainActor.assumeIsolated { self?.answerFileChooser(panel.urls) }
        }
    }

    private func answerFileChooser(_ urls: [URL]) {
        fileChooser = nil
        onChooseFiles?(urls)
    }

    // MARK: Layout

    static let barHeight: CGFloat = 33

    public override func layout() {
        super.layout()
        // `px-2 py-1`, `justify-between`, the xs button or a 16px status line, 1px border.
        let barH: CGFloat = controlButton.isHidden ? 25 : Self.barHeight
        let barY = controlPosition == .top ? 0 : bounds.height - barH
        bar.frame = NSRect(x: 0, y: barY, width: bounds.width, height: barH)
        barBorder.frame = CGRect(x: 0, y: controlPosition == .top ? barH - 1 : 0, width: bounds.width, height: 1)
        let inner = controlPosition == .top ? 0 : 1
        status.frame = NSRect(x: 8, y: CGFloat(inner) + (barH - 1 - 16) / 2, width: max(0, bounds.width - 120), height: 16)
        if !controlButton.isHidden {
            let w = controlButton.intrinsicContentSize.width
            controlButton.frame = NSRect(x: bounds.width - 8 - w, y: CGFloat(inner) + 4, width: w, height: 24)
        }
        let content = controlPosition == .top
            ? NSRect(x: 0, y: barH, width: bounds.width, height: max(0, bounds.height - barH))
            : NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - barH))
        frameView.frame = content
        for view in overlays {
            if let card = view as? OverlayCard {
                let w = max(0, content.width - 16)
                card.frame = NSRect(x: 8, y: content.minY + 8, width: w, height: card.height(forWidth: w))
            } else {
                view.frame = bounds
            }
        }
        scheduleSizeReport(content.size)
    }

    private func scheduleSizeReport(_ size: CGSize) {
        guard size.width >= 1, size.height >= 1 else { return }
        let rounded = CGSize(width: size.width.rounded(), height: size.height.rounded())
        guard rounded != reportedSize else { return }
        sizeTimer?.invalidate()
        // The first size goes at once; later ones settle for 150 ms before the page resizes.
        let delay = reportedSize == nil ? 0 : 0.15
        sizeTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reportedSize = rounded
                self.onSizeChange?(rounded)
            }
        }
        sizeTimer?.tolerance = delay / 10
    }

    /// The last size reported, for the resize sent when this viewer gains control.
    public var frameSize: CGSize? { reportedSize }

    public override func updateLayer() {
        bar.layer?.backgroundColor = Themed.color(\.background).cgColor(in: self)
        barBorder.backgroundColor = Themed.color(\.border).cgColor(in: self)
        status.color = Themed.color(\.mutedForeground)
    }

    // MARK: Pointer

    private func pagePoint(_ event: NSEvent, clamp: Bool) -> CGPoint? {
        guard hasControl, hasFrame, !contentHidden, let viewport, let image = frameView.pixelSize else { return nil }
        let p = frameView.convert(event.locationInWindow, from: nil)
        return BrowserPointerMap.pagePoint(p, box: frameView.bounds.size, image: image,
                                           viewport: viewport, clamp: clamp)
    }

    private func modifiers(_ event: NSEvent) -> Int {
        let f = event.modifierFlags
        return PreviewStream.modifiers(alt: f.contains(.option), control: f.contains(.control), command: f.contains(.command), shift: f.contains(.shift))
    }

    private func mouse(_ action: String, _ event: NSEvent, button: PreviewStream.MouseButton, bit: Int) {
        guard let p = pagePoint(event, clamp: action != "down") else { return }
        flush()
        if action == "down" { pressedButtons |= bit } else { pressedButtons &= ~bit }
        onInput?(.mouse(action: action, x: p.x, y: p.y, button: button, buttons: pressedButtons,
                        clickCount: max(1, event.clickCount), modifiers: modifiers(event)))
    }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    public override var acceptsFirstResponder: Bool { hasControl }

    public override func mouseDown(with event: NSEvent) {
        guard hasControl, frameView.frame.contains(convert(event.locationInWindow, from: nil)) else { return super.mouseDown(with: event) }
        window?.makeFirstResponder(self)
        mouse("down", event, button: .left, bit: 1)
    }
    public override func mouseUp(with event: NSEvent) { if pressedButtons & 1 != 0 { mouse("up", event, button: .left, bit: 1) } }
    public override func rightMouseDown(with event: NSEvent) {
        guard hasControl else { return }
        window?.makeFirstResponder(self)
        mouse("down", event, button: .right, bit: 2)
    }
    public override func rightMouseUp(with event: NSEvent) { if pressedButtons & 2 != 0 { mouse("up", event, button: .right, bit: 2) } }
    public override func otherMouseDown(with event: NSEvent) { if event.buttonNumber == 2 { mouse("down", event, button: .middle, bit: 4) } }
    public override func otherMouseUp(with event: NSEvent) { if event.buttonNumber == 2, pressedButtons & 4 != 0 { mouse("up", event, button: .middle, bit: 4) } }
    public override func mouseMoved(with event: NSEvent) { queueMove(event) }
    public override func mouseDragged(with event: NSEvent) { queueMove(event) }
    public override func rightMouseDragged(with event: NSEvent) { queueMove(event) }
    public override func otherMouseDragged(with event: NSEvent) { queueMove(event) }

    private func queueMove(_ event: NSEvent) {
        guard let p = pagePoint(event, clamp: pressedButtons != 0) else { return }
        let button: PreviewStream.MouseButton = pressedButtons & 1 != 0 ? .left : pressedButtons & 2 != 0 ? .right : pressedButtons & 4 != 0 ? .middle : .none
        pendingMove = .mouse(action: "move", x: p.x, y: p.y, button: button, buttons: pressedButtons, clickCount: 0, modifiers: modifiers(event))
        scheduleFlush()
    }

    public override func scrollWheel(with event: NSEvent) {
        guard let p = pagePoint(event, clamp: false) else { return super.scrollWheel(with: event) }
        // DOM wheel deltas point the other way; line deltas are 16px (`WHEEL_LINE_PX`).
        let unit: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 16
        let dx = Double(-event.scrollingDeltaX * unit), dy = Double(-event.scrollingDeltaY * unit)
        let old = pendingWheel
        pendingWheel = (p.x, p.y, (old?.dx ?? 0) + dx, (old?.dy ?? 0) + dy, modifiers(event))
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { [weak self] in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    private func flush() {
        flushScheduled = false
        if let move = pendingMove { pendingMove = nil; onInput?(move) }
        if let w = pendingWheel { pendingWheel = nil; onInput?(.wheel(x: w.x, y: w.y, deltaX: w.dx, deltaY: w.dy, modifiers: w.modifiers)) }
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    // MARK: Keys

    public override func keyDown(with event: NSEvent) { key("down", event) }
    public override func keyUp(with event: NSEvent) { key("up", event) }

    private func key(_ action: String, _ event: NSEvent) {
        guard hasControl else { return super.keyDown(with: event) }
        // Plain Escape and Tab stay in the page; Shift+Escape returns to the app.
        if event.keyCode == 53, event.modifierFlags.contains(.shift) {
            if action == "down" { window?.makeFirstResponder(nil) }
            return
        }
        if let input = BrowserKeyMap.input(for: event, action: action) { onInput?(input) }
    }

    /// Shortcuts stay with the app's menus; the page sees copy, cut, select all and undo as key
    /// presses and sends copied text back as `clipboard`. Paste carries this Mac's clipboard.
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard hasControl, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if flags == .command, chars == "v" {
            if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty { onInput?(.text(text)) }
            return true
        }
        if flags == .command || flags == [.command, .shift], ["c", "x", "a", "z"].contains(chars) {
            if let down = BrowserKeyMap.input(for: event, action: "down"), let up = BrowserKeyMap.input(for: event, action: "up") {
                onInput?(down); onInput?(up)
            }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    public override func resignFirstResponder() -> Bool { true }
}

/// Where a view point lands on the page (`pagePoint`, ServerBrowserSurface.tsx:254-275): the frame is
/// letterboxed `object-contain` in its box, and the page is `viewport` CSS px across that frame.
public enum BrowserPointerMap {
    public static func fittedRect(box: CGSize, image: CGSize) -> CGRect {
        guard image.width > 0, image.height > 0 else { return .zero }
        let fit = min(box.width / image.width, box.height / image.height)
        let w = image.width * fit, h = image.height * fit
        return CGRect(x: (box.width - w) / 2, y: (box.height - h) / 2, width: w, height: h)
    }

    /// Nil outside the page unless `clamp`, which pins drags and releases to its edge.
    public static func pagePoint(_ p: CGPoint, box: CGSize, image: CGSize, viewport: CGSize, clamp: Bool) -> CGPoint? {
        let r = fittedRect(box: box, image: image)
        guard r.width > 0, r.height > 0 else { return nil }
        let x = (p.x - r.minX) * viewport.width / r.width
        let y = (p.y - r.minY) * viewport.height / r.height
        let inside = x >= 0 && y >= 0 && x <= viewport.width && y <= viewport.height
        if !inside && !clamp { return nil }
        return CGPoint(x: min(max(x, 0), viewport.width), y: min(max(y, 0), viewport.height))
    }
}

/// NSEvent to the stream's `key` message: DOM `key`, physical `code`, Windows `keyCode`, and text
/// for printable keys without Ctrl or Cmd (Enter types "\r", as Puppeteer's key table does).
// ponytail: no IME or dead-key composition; composed text arrives only through paste. Route keys
// through NSTextInputClient if someone types CJK into a streamed page
public enum BrowserKeyMap {
    /// macOS virtual key code to (DOM code, Windows keyCode, DOM key for non-printing keys).
    static let table: [UInt16: (code: String, vk: Int, key: String?)] = {
        var t: [UInt16: (String, Int, String?)] = [
            36: ("Enter", 13, "Enter"), 76: ("NumpadEnter", 13, "Enter"), 48: ("Tab", 9, "Tab"), 49: ("Space", 32, nil),
            51: ("Backspace", 8, "Backspace"), 117: ("Delete", 46, "Delete"), 53: ("Escape", 27, "Escape"),
            123: ("ArrowLeft", 37, "ArrowLeft"), 124: ("ArrowRight", 39, "ArrowRight"), 125: ("ArrowDown", 40, "ArrowDown"),
            126: ("ArrowUp", 38, "ArrowUp"), 115: ("Home", 36, "Home"), 119: ("End", 35, "End"), 116: ("PageUp", 33, "PageUp"),
            121: ("PageDown", 34, "PageDown"), 57: ("CapsLock", 20, "CapsLock"),
            27: ("Minus", 189, nil), 24: ("Equal", 187, nil), 33: ("BracketLeft", 219, nil), 30: ("BracketRight", 221, nil),
            42: ("Backslash", 220, nil), 41: ("Semicolon", 186, nil), 39: ("Quote", 222, nil), 43: ("Comma", 188, nil),
            47: ("Period", 190, nil), 44: ("Slash", 191, nil), 50: ("Backquote", 192, nil),
        ]
        let letters: [(UInt16, Character)] = [(0, "A"), (11, "B"), (8, "C"), (2, "D"), (14, "E"), (3, "F"), (5, "G"), (4, "H"), (34, "I"),
                                              (38, "J"), (40, "K"), (37, "L"), (46, "M"), (45, "N"), (31, "O"), (35, "P"), (12, "Q"),
                                              (15, "R"), (1, "S"), (17, "T"), (32, "U"), (9, "V"), (13, "W"), (7, "X"), (16, "Y"), (6, "Z")]
        for (k, c) in letters { t[k] = ("Key\(c)", Int(c.asciiValue!), nil) }
        let digits: [(UInt16, Int)] = [(29, 0), (18, 1), (19, 2), (20, 3), (21, 4), (23, 5), (22, 6), (26, 7), (28, 8), (25, 9)]
        for (k, d) in digits { t[k] = ("Digit\(d)", 48 + d, nil) }
        let fkeys: [(UInt16, Int)] = [(122, 1), (120, 2), (99, 3), (118, 4), (96, 5), (97, 6), (98, 7), (100, 8), (101, 9), (109, 10), (103, 11), (111, 12)]
        for (k, n) in fkeys { t[k] = ("F\(n)", 111 + n, "F\(n)") }
        return t.mapValues { (code: $0.0, vk: $0.1, key: $0.2) }
    }()

    public static func input(for event: NSEvent, action: String) -> PreviewStream.Input? {
        guard event.type == .keyDown || event.type == .keyUp else { return nil }
        let flags = event.modifierFlags
        let shortcut = flags.contains(.command) || flags.contains(.control)
        let entry = table[event.keyCode]
        let key: String
        if let named = entry?.key {
            key = named
        } else {
            let chars = shortcut ? (event.charactersIgnoringModifiers ?? "") : (event.characters ?? "")
            guard chars.count == 1 else { return nil }
            key = chars
        }
        let text: String? = shortcut ? nil : key.count == 1 ? key : key == "Enter" ? "\r" : nil
        let mods = PreviewStream.modifiers(alt: flags.contains(.option), control: flags.contains(.control),
                                           command: flags.contains(.command), shift: flags.contains(.shift))
        let vk = entry?.vk ?? key.uppercased().unicodeScalars.first.map { Int($0.value) }
        return .key(action: action, key: key, code: entry?.code ?? "", keyCode: vk, text: action == "down" ? text : nil, modifiers: mods)
    }
}

/// The frame layer: the newest frame, letterboxed (`object-contain`), redrawn only when it changes.
/// The layer shows the decoded buffer's IOSurface as it is and commits with the rest of the run loop
/// pass. Holding the buffer until the next frame keeps its pool from reusing it before that commit.
final class FrameView: DSView {
    var buffer: CVPixelBuffer? { didSet { layer?.contents = buffer.flatMap { CVPixelBufferGetIOSurface($0)?.takeUnretainedValue() } } }
    /// The frame's size in device px.
    var pixelSize: CGSize? { buffer.map { CGSize(width: CVPixelBufferGetWidth($0), height: CVPixelBufferGetHeight($0)) } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.contentsGravity = .resizeAspect
        layer?.minificationFilter = .linear
        layer?.magnificationFilter = .linear
        layer?.actions = ["contents": NSNull()]
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The agent's pointer (`AgentCursorMark`, AgentBrowserCursor.tsx:55-99): lucide mouse-pointer-2,
/// 20px, filled with the background and stroked in primary, a ping on clicks; full opacity for
/// 700 ms after each action, then 35% (18% while a person has control).
public final class AgentCursorView: DSView {
    public enum Controller { case human, agent, none }
    private let arrow = IconView(name: .mousePointer2, size: 20)
    private let ping = CALayer()
    private var sequence = -1
    private var fade: DispatchWorkItem?

    public override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        layer?.masksToBounds = false
        ping.cornerRadius = 8
        ping.opacity = 0
        layer?.addSublayer(ping)
        addSubview(arrow)
        arrow.shadow = {
            let s = NSShadow()
            s.shadowBlurRadius = 2
            s.shadowOffset = NSSize(width: 0, height: -1)
            s.shadowColor = NSColor.black.withAlphaComponent(0.15)
            return s
        }()
    }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// `agentBrowserCursorOpacity`.
    static func opacity(active: Bool, controller: Controller) -> Float {
        active ? 1 : controller == .human ? 0.18 : 0.35
    }

    func show(at point: CGPoint, click: Bool, sequence: Int, controller: Controller) {
        let animate = !Motion.reduced && !isHidden && self.sequence >= 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = animate ? 0.15 : 0
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = animate
            // `-translate-x-0.5 -translate-y-0.5` on the 20px glyph.
            animator().setFrameOrigin(NSPoint(x: point.x - 2, y: point.y - 2))
        }
        layer?.opacity = Self.opacity(active: true, controller: controller)
        if click, sequence != self.sequence, !Motion.reduced {
            let a = CAKeyframeAnimation(keyPath: "transform.scale")
            a.values = [1, 2]
            let o = CAKeyframeAnimation(keyPath: "opacity")
            o.values = [1, 0]
            let g = CAAnimationGroup()
            g.animations = [a, o]
            g.duration = 1
            g.repeatCount = 1
            ping.add(g, forKey: "ping")
        }
        self.sequence = sequence
        fade?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                CATransaction.begin()
                CATransaction.setAnimationDuration(0.15)
                self.layer?.opacity = Self.opacity(active: false, controller: controller)
                CATransaction.commit()
            }
        }
        fade = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    public override func layout() {
        super.layout()
        arrow.frame = NSRect(x: 0, y: 0, width: 20, height: 20)
        ping.frame = CGRect(x: 2, y: 2, width: 16, height: 16)
    }

    public override func updateLayer() {
        arrow.strokeColor = Themed.color(\.primary)
        arrow.fillColor = Themed.color(\.background)
        ping.backgroundColor = Themed.color(\.primary, 0.25).cgColor(in: self)
    }
}

/// The dialog and file chooser card: `absolute inset-x-2 top-2 rounded-lg border bg-background p-3
/// shadow-lg`, a 14px message, an optional field and end-aligned buttons, or a muted note.
final class OverlayCard: DSView {
    var message = "" { didSet { text.text = message } }
    var note: String? { didSet { noteLabel.text = note ?? ""; noteLabel.isHidden = note == nil } }
    var field: NSView? { didSet { oldValue?.removeFromSuperview(); field.map(addSubview) } }
    var buttons: [ButtonView] = [] { didSet { oldValue.forEach { $0.removeFromSuperview() }; buttons.forEach(addSubview) } }
    private let text = TextBlockView()
    private let noteLabel = LabelView("", font: DSFont.ui(12))
    private let decoration = BoxDecorationLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        decoration.host = self
        layer?.addSublayer(decoration)
        layer?.masksToBounds = false
        text.font = DSFont.ui(14)
        text.lineHeight = 20
        noteLabel.lineHeight = 16
        noteLabel.isHidden = true
        [text, noteLabel].forEach(addSubview)
        setAccessibilityRole(.group)
    }

    func height(forWidth w: CGFloat) -> CGFloat {
        var h = 12 + text.height(forWidth: w - 26)
        if field != nil { h += 8 + 32 }
        if note != nil { h += 8 + 16 }
        if !buttons.isEmpty { h += 8 + 28 }
        return h + 12 + 1
    }

    override func layout() {
        super.layout()
        var style = BoxStyle()
        style.radius = 10
        style.fill = Themed.color(\.background)
        style.border = Themed.color(\.border)
        style.shadows = [BoxShadow(y: 10, blur: 15, spread: -3, color: Themed.black(0.1)), BoxShadow(y: 4, blur: 6, spread: -4, color: Themed.black(0.1))]
        decoration.boxStyle = style
        decoration.layout(boxSize: bounds.size)
        let w = bounds.width - 26
        var y: CGFloat = 13
        let th = text.height(forWidth: w)
        text.frame = NSRect(x: 13, y: y, width: w, height: th)
        y += th
        if let field { field.frame = NSRect(x: 13, y: y + 8, width: w, height: 32); y += 40 }
        if note != nil { noteLabel.frame = NSRect(x: 13, y: y + 8, width: w, height: 16); y += 24 }
        var x = bounds.width - 13
        for b in buttons.reversed() {
            let bw = b.intrinsicContentSize.width
            x -= bw
            b.frame = NSRect(x: x, y: y + 8, width: bw, height: 28)
            x -= 8
        }
    }

    override func updateLayer() {
        text.color = Themed.color(\.foreground)
        noteLabel.color = Themed.color(\.mutedForeground)
    }
}

/// The host setup and refused states over the whole surface: centered text, the command to copy,
/// and one outline button.
final class CoverView: DSView {
    var message = "" { didSet { text.text = message } }
    var command: String? { didSet { commandLabel.text = command ?? ""; commandBox.isHidden = command == nil } }
    var small = false { didSet { text.font = DSFont.ui(small ? 12 : 14); text.lineHeight = small ? 16 : 20 } }
    var button: ButtonView? { didSet { oldValue?.removeFromSuperview(); button.map(addSubview) } }
    private let text = TextBlockView()
    private let commandBox = DSView()
    private let commandLabel = LabelView("", font: DSFont.mono(12))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        text.font = DSFont.ui(14)
        text.lineHeight = 20
        text.alignment = .center
        commandLabel.lineHeight = 16
        commandBox.layer?.cornerRadius = 8
        commandBox.addSubview(commandLabel)
        commandBox.isHidden = true
        [text, commandBox].forEach(addSubview)
        setAccessibilityRole(.group)
    }

    override func layout() {
        super.layout()
        let w = min(384, bounds.width - 32)
        let th = text.height(forWidth: w)
        var h = th
        if !commandBox.isHidden { h += 12 + 36 }
        if button != nil { h += 12 + 28 }
        var y = max(16, (bounds.height - h) / 2)
        text.frame = NSRect(x: (bounds.width - w) / 2, y: y, width: w, height: th)
        y += th
        if !commandBox.isHidden {
            let cw = min(448, bounds.width - 32)
            commandBox.frame = NSRect(x: (bounds.width - cw) / 2, y: y + 12, width: cw, height: 36)
            commandLabel.frame = NSRect(x: 12, y: 10, width: cw - 24, height: 16)
            y += 48
        }
        if let button {
            let bw = button.intrinsicContentSize.width
            button.frame = NSRect(x: (bounds.width - bw) / 2, y: y + 12, width: bw, height: 28)
        }
    }

    override func updateLayer() {
        layer?.backgroundColor = Themed.color(\.background).cgColor(in: self)
        commandBox.layer?.backgroundColor = Themed.color(\.muted).cgColor(in: self)
        text.color = Themed.color(\.mutedForeground)
        commandLabel.color = Themed.color(\.foreground)
    }

    override func mouseDown(with event: NSEvent) {}
}
