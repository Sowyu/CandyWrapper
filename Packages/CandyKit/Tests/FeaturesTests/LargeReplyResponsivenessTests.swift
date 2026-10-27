import AppKit
import Foundation
import Testing
import T3Protocol
import T3Store
@testable import Features

/// Main-thread blocking while a timeline shows a long answer: the 2026-10-26 audit's large-reply fixtures, in a real
/// `TimelineView` in a window. Each step runs what one run loop turn does (the change, layout, display), then lets the main
/// queue run; a 1 ms main-queue heartbeat records the longest gap, the longest the app couldn't take input. Opt in with `CW_LARGE_REPLY_STRESS=1`,
/// in a Release build like the audit's.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CW_LARGE_REPLY_STRESS"] == "1"), .serialized)
@MainActor
struct LargeReplyResponsivenessStress {
    static func fixture(bytes: Int, softBreaks: Bool) -> String {
        let unit = softBreaks ? "number 12345 and **bold** words\n" : "## Finding\n\nA **bold** paragraph with [reference][r].\n\n- first\n- second\n\n```swift\nlet answer = 42\n```\n\n| Key | Value |\n| --- | --- |\n| x | 42 |\n\n"
        return String(repeating: unit, count: max(1, bytes / unit.utf8.count)) + "\n\n[r]: https://example.com\n"
    }

    static func items(_ text: String, streaming: Bool) -> [TimelineItem] {
        let at = T3Timestamp("2026-10-27T12:00:00Z")
        var answer = ChatMessage(id: MessageId("answer"), role: .assistant, text: text, createdAt: at)
        answer.streaming = streaming
        return [
            TimelineRow(id: "question", createdAt: at, kind: .message(ChatMessage(id: MessageId("question"), role: .user, text: "Write a long reply.", createdAt: at),
                                                                      projectedItem: nil, showAssistantMeta: false, showAssistantCopyButton: false, assistantCopyStreaming: false, turnDiffSummary: nil)),
            TimelineRow(id: "answer", createdAt: at, kind: .message(answer, projectedItem: nil, showAssistantMeta: !streaming, showAssistantCopyButton: !streaming,
                                                                    assistantCopyStreaming: streaming, turnDiffSummary: nil)),
        ].map { TimelineItem(row: $0) }
    }

    /// The longest main run loop pass, wake to sleep, as the app's `StallMonitor` counts stalls: while a pass runs, the app
    /// takes no input. One monitor runs through the whole test, so a window's teardown counts too.
    @MainActor final class Heartbeat {
        private var observer: CFRunLoopObserver?
        private var passStart = ContinuousClock.now
        private(set) var longestGap: Double = 0
        /// The app runs in front; without this, App Nap delays the test process's timers.
        private let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Large reply measurement")
        init() {
            let o = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue,
                                                       true, CFIndex.max) { [weak self] _, activity in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let now = ContinuousClock.now
                    if activity == .afterWaiting {
                        self.passStart = now
                    } else {
                        self.longestGap = max(self.longestGap, Harness.ms(now - self.passStart))
                    }
                }
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), o, .commonModes)
            observer = o
        }
        func reset() { passStart = ContinuousClock.now; longestGap = 0 }
        func stop() {
            if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
            ProcessInfo.processInfo.endActivity(activity)
        }
    }

    /// Closes the harness's window and lets go of it, then waits `settle` seconds: the longest stall in that time is
    /// what leaving a thread with this answer costs.
    static func closeMeasured(_ h: inout Harness?, _ beat: Heartbeat, settle: Double = 3) async -> Double {
        beat.reset()
        h?.window.close()
        h = nil
        try? await Task.sleep(for: .seconds(settle))
        return beat.longestGap
    }

    @MainActor final class Harness {
        let window: NSWindow
        let timeline: TimelineView
        let heartbeat: Heartbeat
        var longestGap: Double { heartbeat.longestGap }

        init(_ heartbeat: Heartbeat, width: CGFloat = 1000, height: CGFloat = 800) {
            self.heartbeat = heartbeat
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            timeline = TimelineView(frame: NSRect(x: 0, y: 0, width: width, height: height))
            window.contentView = timeline
            window.layoutIfNeeded()
        }

        /// Starts a new phase: the next `longestGap` covers only what follows.
        func resetGap() { heartbeat.reset() }

        /// One run loop turn's worth of work: `change`, then layout and display. Then the main queue runs what came of it.
        /// Each step's own synchronous milliseconds, in order (`CW_LARGE_REPLY_STEPS=1` prints the longest).
        var stepTimes: [Double] = []

        func step(_ change: () -> Void = {}) async {
            let start = ContinuousClock.now
            change()
            timeline.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
            stepTimes.append(Self.ms(ContinuousClock.now - start))
            try? await Task.sleep(for: .milliseconds(4))
        }

        func printSteps(_ label: String) {
            if ProcessInfo.processInfo.environment["CW_LARGE_REPLY_STEPS"] == "1" {
                func count(_ v: NSView) -> Int { 1 + v.subviews.reduce(0) { $0 + count($1) } }
                print("LARGE_REPLY_VIEWS \(label) window \(count(timeline)) markdown \(markdown.map(count) ?? 0)")
            }
            guard ProcessInfo.processInfo.environment["CW_LARGE_REPLY_STEPS"] == "1" else { return }
            let top = stepTimes.enumerated().sorted { $0.element > $1.element }.prefix(6).map { "#\($0.offset) \(Int($0.element)) ms" }
            print("LARGE_REPLY_STEPS \(label) gap \(Int(longestGap)) ms, steps \(stepTimes.count): \(top.joined(separator: ", "))")
            stepTimes = []
        }

        var markdown: MarkdownView? {
            func find(_ view: NSView) -> MarkdownView? {
                if let m = view as? MarkdownView { return m }
                for sub in view.subviews { if let m = find(sub) { return m } }
                return nil
            }
            return timeline.view(forRow: "answer").flatMap(find)
        }

        /// The answer shows its real layout at its width: a stand-in has no items, or another width's.
        var ready: Bool {
            guard let markdown, markdown.bounds.width > 0 else { return false }
            let layout = markdown.layout(forWidth: markdown.bounds.width)
            return !layout.items.isEmpty && layout.width == markdown.bounds.width
        }

        /// Steps until the answer is ready.
        func untilReady(timeout: Double = 60_000) async {
            let start = ContinuousClock.now
            while !ready, Self.ms(ContinuousClock.now - start) < timeout { await step() }
            await step()
        }

        static func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
    }

    private func emit(_ name: String, bytes: Int, values: [Double]) throws {
        let sorted = values.sorted()
        func percentile(_ p: Double) -> Double { sorted[min(sorted.count - 1, max(0, Int(ceil(Double(sorted.count) * p)) - 1))] }
        let result: [String: Any] = ["name": name, "bytes": bytes, "samples": values.count,
            "p50_ms": percentile(0.5), "p95_ms": percentile(0.95), "max_ms": sorted.last!, "raw_ms": values]
        print("LARGE_REPLY " + String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
    }

    /// Opening a thread whose last answer is long and settled, then scrolling through it and narrowing the window.
    /// `CW_LARGE_REPLY_ONLY=<bytes>:<mixed|soft>` measures one fixture, for profiling.
    static let only: (bytes: Int, soft: Bool)? = ProcessInfo.processInfo.environment["CW_LARGE_REPLY_ONLY"].flatMap { v in
        let parts = v.split(separator: ":")
        return parts.count == 2 ? Int(parts[0]).map { ($0, parts[1] == "soft") } : nil
    }

    @Test func openScrollResize() async throws {
        for bytes in [256 << 10, 1 << 20] {
            for softBreaks in [false, true] {
                if let only = Self.only, only.bytes != bytes || only.soft != softBreaks { continue }
                let text = Self.fixture(bytes: bytes, softBreaks: softBreaks)
                let kind = softBreaks ? "soft_breaks" : "mixed_blocks"
                var openBlock: [Double] = [], ready: [Double] = [], scrollBlock: [Double] = [], resizeBlock: [Double] = [], closeBlock: [Double] = []
                let beat = Heartbeat()
                defer { beat.stop() }
                for _ in 0..<5 {
                    // A fresh text each run, so no parse cache from the run before helps.
                    let fresh = text + "\n\n" + UUID().uuidString + "\n"
                    var held: Harness? = Harness(beat)
                    do {
                    let h = held!
                    try? await Task.sleep(for: .milliseconds(20))
                    h.resetGap()
                    let start = ContinuousClock.now
                    await h.step { h.timeline.setItems(Self.items(fresh, streaming: false)) }
                    await h.untilReady()
                    ready.append(Harness.ms(ContinuousClock.now - start))
                    #expect(h.ready)
                    h.printSteps("open \(bytes)")
                    openBlock.append(h.longestGap)
                    h.resetGap()
                    let clip = h.timeline.scrollView.contentView
                    let total = h.timeline.scrollView.documentView?.frame.height ?? 0
                    for i in 0...20 {
                        await h.step {
                            clip.scroll(to: NSPoint(x: 0, y: max(0, total - clip.bounds.height) * CGFloat(i) / 20))
                            h.timeline.scrollView.reflectScrolledClipView(clip)
                        }
                    }
                    scrollBlock.append(h.longestGap)
                    h.resetGap()
                    await h.step { h.window.setContentSize(NSSize(width: 760, height: 800)) }
                    await h.untilReady()
                    h.printSteps("resize \(bytes)")
                    resizeBlock.append(h.longestGap)
                    }
                    closeBlock.append(await Self.closeMeasured(&held, beat))
                }
                try emit("open_main_block_\(kind)", bytes: text.utf8.count, values: openBlock)
                try emit("open_ready_\(kind)", bytes: text.utf8.count, values: ready)
                try emit("scroll_main_block_\(kind)", bytes: text.utf8.count, values: scrollBlock)
                try emit("resize_main_block_\(kind)", bytes: text.utf8.count, values: resizeBlock)
                try emit("close_main_block_\(kind)", bytes: text.utf8.count, values: closeBlock)
            }
        }
    }

    /// A long answer streaming in 128 updates, then settling.
    @Test func streamAndSettle() async throws {
        for bytes in [256 << 10, 1 << 20] {
            if let only = Self.only, only.bytes != bytes || only.soft { continue }
            let text = Self.fixture(bytes: bytes, softBreaks: false)
            let utf8 = Array(text.utf8)
            var updateBlock: [Double] = [], settleBlock: [Double] = [], closeBlock: [Double] = []
            let beat = Heartbeat()
            defer { beat.stop() }
            for _ in 0..<3 {
                var held: Harness? = Harness(beat)
                do {
                let h = held!
                try? await Task.sleep(for: .milliseconds(20))
                h.resetGap()
                for n in 1...128 {
                    let prefix = String(decoding: utf8[0..<(utf8.count * n / 128)], as: UTF8.self)
                    await h.step { h.timeline.setItems(Self.items(prefix, streaming: true)) }
                }
                await h.untilReady()
                h.printSteps("stream \(bytes)")
                updateBlock.append(h.longestGap)
                h.resetGap()
                await h.step { h.timeline.setItems(Self.items(text, streaming: false)) }
                await h.untilReady()
                for _ in 0..<50 { await h.step() }
                h.printSteps("settle \(bytes)")
                settleBlock.append(h.longestGap)
                #expect(h.ready)
                }
                closeBlock.append(await Self.closeMeasured(&held, beat))
            }
            try emit("stream_update_main_block", bytes: text.utf8.count, values: updateBlock)
            try emit("settle_main_block", bytes: text.utf8.count, values: settleBlock)
            try emit("stream_close_main_block", bytes: text.utf8.count, values: closeBlock)
        }
    }
}
