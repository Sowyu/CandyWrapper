import AppKit
import ObjectiveC
import QuartzCore
import Testing
import DesignSystem
@testable import Features

/// Counts `drawRect:`, `updateLayer` and `layout` on every class that defines its own, and TextKit 2 fragment draws.
/// Counting per keystroke catches redraws and reflows that a wall-clock threshold would miss on a fast Mac.
@MainActor
private enum WorkCounter {
    struct Draw { let view: String; let size: CGSize }
    static var draws: [Draw] = []
    static var updateLayers: [String] = []
    static var layouts: [String] = []
    static var fragmentDraws = 0
    private static var swizzled: Set<String> = []

    static func reset() { draws = []; updateLayers = []; layouts = []; fragmentDraws = 0 }

    static func install(under root: NSView) {
        var stack = [root]
        while let view = stack.popLast() {
            stack.append(contentsOf: view.subviews)
            var cls: AnyClass? = type(of: view)
            while let c = cls, c != NSView.self {
                wrap(c)
                cls = class_getSuperclass(c)
            }
        }
        if !swizzled.contains("NSTextLayoutFragment") {
            swizzled.insert("NSTextLayoutFragment")
            let sel = NSSelectorFromString("drawAtPoint:inContext:")
            if let m = class_getInstanceMethod(NSTextLayoutFragment.self, sel) {
                typealias F = @convention(c) (AnyObject, Selector, CGPoint, CGContext) -> Void
                let original = unsafeBitCast(method_getImplementation(m), to: F.self)
                let block: @convention(block) (AnyObject, CGPoint, CGContext) -> Void = { obj, p, ctx in
                    MainActor.assumeIsolated { fragmentDraws += 1 }
                    original(obj, sel, p, ctx)
                }
                method_setImplementation(m, imp_implementationWithBlock(block))
            }
        }
    }

    private static func ownMethod(_ cls: AnyClass, _ sel: Selector) -> Method? {
        var count: UInt32 = 0
        guard let list = class_copyMethodList(cls, &count) else { return nil }
        defer { free(list) }
        return (0..<Int(count)).map { list[$0] }.first { method_getName($0) == sel }
    }

    private static func wrap(_ cls: AnyClass) {
        let name = NSStringFromClass(cls)
        guard !swizzled.contains(name) else { return }
        swizzled.insert(name)
        let drawSel = NSSelectorFromString("drawRect:")
        if let m = ownMethod(cls, drawSel) {
            typealias F = @convention(c) (NSView, Selector, NSRect) -> Void
            let original = unsafeBitCast(method_getImplementation(m), to: F.self)
            let block: @convention(block) (NSView, NSRect) -> Void = { view, rect in
                MainActor.assumeIsolated { draws.append(Draw(view: name, size: rect.size)) }
                original(view, drawSel, rect)
            }
            method_setImplementation(m, imp_implementationWithBlock(block))
        }
        for (selName, record) in [("updateLayer", { (n: String) in updateLayers.append(n) }), ("layout", { (n: String) in layouts.append(n) })] {
            let sel = NSSelectorFromString(selName)
            guard let m = ownMethod(cls, sel) else { continue }
            typealias F = @convention(c) (NSView, Selector) -> Void
            let original = unsafeBitCast(method_getImplementation(m), to: F.self)
            let block: @convention(block) (NSView) -> Void = { view in
                MainActor.assumeIsolated { record(name) }
                original(view, sel)
            }
            method_setImplementation(m, imp_implementationWithBlock(block))
        }
    }
}

/// One press measured the way the window server sees it: the synchronous key handling, then the layout, display
/// and commit AppKit runs before the run loop sleeps, then anything the press scheduled for later turns.
private struct Press {
    var keyMs = 0.0, commitMs = 0.0, serializations = 0, caretUpdates = 0
    var draws: [WorkCounter.Draw] = [], updateLayers: [String] = [], layouts: [String] = [], fragments = 0, dirtyLayers = 0
    var lateDrawNames: [String] = []
    var lateDraws = 0, lateLayouts = 0, lateUpdateLayers = 0, lateFragments = 0, lateMs = 0.0
    var totalMs: Double { keyMs + commitMs }
}

@MainActor
private func ms(_ d: Duration) -> Double { Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000 }

/// A window off screen never commits its layers, so the pass draws them itself, as the commit would.
@MainActor
private func displayPass(_ window: NSWindow) -> Int {
    window.contentView?.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    var dirty = 0
    func walk(_ layer: CALayer) {
        if layer.needsDisplay() { dirty += 1 }
        layer.displayIfNeeded()
        layer.sublayers?.forEach(walk)
    }
    if let layer = window.contentView?.layer { walk(layer) }
    CATransaction.flush()
    return dirty
}

@MainActor
private func keyEvent(_ type: NSEvent.EventType, _ window: NSWindow, at time: TimeInterval) -> NSEvent {
    NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: time, windowNumber: window.windowNumber,
                     context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
}

@MainActor
private func press(_ window: NSWindow) -> Press {
    var p = Press()
    let editor = window.firstResponder as? ComposerEditor
    let serialized = editor?.serializations ?? 0, placed = editor?.caretUpdates ?? 0
    let now = ProcessInfo.processInfo.systemUptime
    WorkCounter.reset()
    let start = ContinuousClock.now
    window.sendEvent(keyEvent(.keyDown, window, at: now))
    window.sendEvent(keyEvent(.keyUp, window, at: now + 0.08))
    let keyed = ContinuousClock.now
    p.dirtyLayers = displayPass(window)
    p.keyMs = ms(keyed - start)
    p.commitMs = ms(ContinuousClock.now - keyed)
    p.draws = WorkCounter.draws; p.updateLayers = WorkCounter.updateLayers; p.layouts = WorkCounter.layouts
    p.fragments = WorkCounter.fragmentDraws
    p.serializations = (editor?.serializations ?? 0) - serialized
    p.caretUpdates = (editor?.caretUpdates ?? 0) - placed
    // Later turns: main queue blocks, AfterCommit, timers. Whatever they redraw lands a frame late.
    WorkCounter.reset()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    let late = ContinuousClock.now
    _ = displayPass(window)
    p.lateMs = ms(ContinuousClock.now - late)
    p.lateDrawNames = WorkCounter.draws.map { "\($0.view) \(Int($0.size.width))x\(Int($0.size.height))" } + WorkCounter.layouts
    p.lateDraws = WorkCounter.draws.count; p.lateLayouts = WorkCounter.layouts.count
    p.lateUpdateLayers = WorkCounter.updateLayers.count; p.lateFragments = WorkCounter.fragmentDraws
    return p
}

@MainActor
private func report(_ name: String, _ presses: [Press]) {
    func median(_ xs: [Double]) -> Double { let s = xs.sorted(); return s[s.count / 2] }
    let steady = Array(presses.dropFirst())
    print(String(format: "KEYLAT %@ first key %.2f commit %.2f | median key %.2f commit %.2f total %.2f late %.2f",
                 name, presses[0].keyMs, presses[0].commitMs, median(steady.map(\.keyMs)), median(steady.map(\.commitMs)),
                 median(steady.map(\.totalMs)), median(steady.map(\.lateMs))))
    for (i, p) in presses.enumerated() where i < 3 || i == presses.count - 1 {
        let draws = Dictionary(grouping: p.draws, by: \.view).map { "\($0.key)x\($0.value.count) \(Int($0.value[0].size.width))x\(Int($0.value[0].size.height))" }.sorted()
        let layouts = Dictionary(grouping: p.layouts, by: { $0 }).map { "\($0.key)x\($0.value.count)" }.sorted()
        let updates = Dictionary(grouping: p.updateLayers, by: { $0 }).map { "\($0.key)x\($0.value.count)" }.sorted()
        print("KEYLAT \(name) #\(i) serializations \(p.serializations) caret updates \(p.caretUpdates) dirty layers \(p.dirtyLayers) fragments \(p.fragments) draws \(draws) updateLayer \(updates) layout \(layouts) late draws \(p.lateDraws) \(p.lateDrawNames) layouts \(p.lateLayouts) updateLayer \(p.lateUpdateLayers) fragments \(p.lateFragments)")
    }
}

/// The app's window is key while the user types; the caret only shows in a key window (`updateCaret`).
private final class KeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

/// What one keystroke may cost in the composer. The first press also hides the placeholder and enables send.
@MainActor
private func expectTypingWork(_ presses: [Press]) {
    #expect(presses[0].fragments >= 1 && presses[0].lateFragments == 0, "the first glyph lands in the keystroke's own commit")
    // About 90 `a`s fill the 736 pt line; past that a wrap grows the composer and relays it out, as it should.
    for (i, p) in presses.prefix(60).enumerated().dropFirst() {
        // ComposerView.refresh and the host share one serialization of the draft (`refresh(prompt:)`).
        #expect(p.serializations == 1, "press \(i): \(p.serializations) serializations")
        // TextKit moves the caret mid-edit; only `textDidChange` places ours.
        #expect(p.caretUpdates == 1, "press \(i): \(p.caretUpdates) caret updates")
        #expect(p.fragments == 1 && p.lateFragments == 0, "press \(i): the glyph's line draws once, in the first commit")
        #expect(p.draws.isEmpty && p.updateLayers.isEmpty, "press \(i) redrew \(p.draws.map(\.view)) \(p.updateLayers)")
        #expect(p.layouts == ["NSTextView"], "press \(i) laid out \(p.layouts)")
        #expect(p.lateDraws == 0 && p.lateLayouts == 0 && p.lateUpdateLayers == 0, "press \(i) changed the screen a turn late: \(p.lateDrawNames)")
    }
}

private let presses = Int(ProcessInfo.processInfo.environment["CW_KEYLAT_PRESSES"] ?? "") ?? 30

/// The README's keypress benchmark offscreen: `a` presses through the window into an empty composer, each followed by
/// the layout, display and commit AppKit runs before the run loop sleeps, then a 50 ms spin for work the key scheduled.
/// It prints `KEYLAT` timings and counts for the composer, the composer docked in a thread panel, and a bare TextKit 2
/// NSTextView as the floor. Counts are asserted; timings only print. CW_KEYLAT_PRESSES sets the presses (30), and
/// CW_KEYLAT_PROFILE=1 or `panel` keeps typing for 15 s after writing the pid to /tmp/cw-keylat-profile.pid, for `sample`.
@MainActor
struct ComposerKeystrokeWorkTests {
    private func hostComposer() -> (NSWindow, ComposerView) {
        let window = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 300), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = DSView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        window.contentView = content
        let composer = ComposerView(frame: NSRect(x: 32, y: 16, width: 736, height: 144))
        composer.richTextEnabled = true
        composer.chipLook = ComposerChipLook.basic
        content.addSubview(composer)
        composer.onHeightChange = { [weak composer] in
            guard let composer else { return }
            composer.setFrameSize(NSSize(width: 736, height: composer.preferredHeight))
        }
        // The app's host coalesces its prompt work after the commit (ComposerController.remember).
        let refreshes = ComposerRefreshCoordinator(threadState: {}, promptState: { _ = composer.text })
        composer.onTextChange = { _ in refreshes.promptChanged() }
        composer.setFrameSize(NSSize(width: 736, height: composer.preferredHeight))
        window.makeFirstResponder(composer.editor)
        _ = displayPass(window)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        _ = displayPass(window)
        WorkCounter.install(under: content)
        return (window, composer)
    }

    @Test func composerKeystroke() {
        let (window, composer) = hostComposer()
        var results: [Press] = []
        for _ in 0..<presses { results.append(press(window)) }
        // CW_KEYLAT_PROFILE=1 keeps typing for about 15 s so `sample` can see where the time goes.
        if ProcessInfo.processInfo.environment["CW_KEYLAT_PROFILE"] == "1" {
            try? "\(getpid())".write(toFile: "/tmp/cw-keylat-profile.pid", atomically: true, encoding: .utf8)
            let until = ContinuousClock.now + .seconds(15)
            while ContinuousClock.now < until {
                _ = press(window)
                if composer.text.count > 60 { composer.text = "" }
            }
        }
        #expect(composer.text == String(repeating: "a", count: presses))
        report("composer", results)
        expectTypingWork(results)
    }

    /// The composer docked in a thread panel over a small thread, as the benchmark types into it.
    @Test func threadPanelKeystroke() throws {
        let window = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled, .resizable],
                               backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let panel = ThreadPanelView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        window.contentView = panel
        let projection = try #require(try ThreadPreview.projection(titled: ThreadPreview.markdownThread))
        panel.setProjection(projection, projectTitle: "demo-repo", workspaceRoot: nil)
        let composer = panel.composer
        composer.richTextEnabled = true
        composer.chipLook = ComposerChipLook.basic
        _ = panel.menus
        let refreshes = ComposerRefreshCoordinator(threadState: {}, promptState: { _ = composer.text })
        composer.onTextChange = { _ in refreshes.promptChanged() }
        window.makeFirstResponder(composer.editor)
        for _ in 0..<3 {
            _ = displayPass(window)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        WorkCounter.install(under: panel)
        var results: [Press] = []
        for _ in 0..<presses { results.append(press(window)) }
        if ProcessInfo.processInfo.environment["CW_KEYLAT_PROFILE"] == "panel" {
            try? "\(getpid())".write(toFile: "/tmp/cw-keylat-profile.pid", atomically: true, encoding: .utf8)
            let until = ContinuousClock.now + .seconds(15)
            while ContinuousClock.now < until {
                _ = press(window)
                if composer.text.count > 60 { composer.text = "" }
            }
        }
        #expect(composer.text == String(repeating: "a", count: presses))
        report("panel", results)
        expectTypingWork(results)
    }

    @Test func bareTextViewKeystroke() {
        let window = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 300), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        window.contentView = content
        let text = NSTextView(usingTextLayoutManager: true)
        text.frame = NSRect(x: 36, y: 100, width: 728, height: 23)
        text.font = ComposerEditor.font
        text.drawsBackground = false
        text.isRichText = false
        content.addSubview(text)
        window.makeFirstResponder(text)
        _ = displayPass(window)
        WorkCounter.install(under: content)
        var results: [Press] = []
        for _ in 0..<presses { results.append(press(window)) }
        #expect(text.string == String(repeating: "a", count: presses))
        report("bare", results)
    }
}
