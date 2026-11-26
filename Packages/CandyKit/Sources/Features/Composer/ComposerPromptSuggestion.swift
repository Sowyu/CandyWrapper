import AppKit
import DesignSystem
import T3Protocol

/// Prompt suggestions (#28047, #33706 at 4928): the provider's predicted next prompt, from
/// `orchestration.subscribePromptSuggestion`, while the run that produced it is the thread's latest completed run.
public enum ComposerPromptSuggestion {
    public struct Suggestion: Equatable, Sendable {
        public var runId: RunId
        public var text: String
        public init(runId: RunId, text: String) { self.runId = runId; self.text = text }
    }

    /// `OrchestrationV2PromptSuggestion`: `{runId, text}` or null.
    public static func decode(_ value: JSONValue) -> Suggestion? {
        guard let run = value["runId"]?.stringValue, let text = value["text"]?.stringValue,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return Suggestion(runId: RunId(run), text: text)
    }

    /// `offeredPromptSuggestion` (usePromptSuggestion.ts:28-49 at 4928) over `announcedRun` and `latestExecutedRun`
    /// (threadActivityAnnouncement.ts:91-98, orchestrationV2ThreadError.ts:55-96). A message promoted to Steer leaves
    /// its queued run cancelled before it started, so the comparison skips to the last run that ran, once the runs
    /// include that cancelled run.
    public static func offered(_ suggestion: Suggestion?, latestRunId: RunId?, runs: [Run]) -> Suggestion? {
        guard let suggestion, let latestRunId else { return nil }
        let latest = runs.first { $0.id == latestRunId }
        let neverStarted = latest.map { $0.status.rawValue == "cancelled" && $0.startedAt == nil } ?? false
        let announced: Run? = neverStarted ? latestExecuted(runs) : latest
        // The shell can name a newer run than the projection holds yet: no suggestion until it lands.
        guard latest != nil, let announced, announced.id == suggestion.runId, announced.status.rawValue == "completed" else { return nil }
        return suggestion
    }

    static func latestExecuted(_ runs: [Run]) -> Run? {
        func end(_ r: Run) -> Double { r.completedAt?.date?.timeIntervalSince1970 ?? .infinity }
        var latest: Run?
        for run in runs {
            if run.status.rawValue == "queued" || (run.status.rawValue == "cancelled" && run.startedAt == nil) { continue }
            if let l = latest, !(end(run) == end(l) ? run.ordinal > l.ordinal : end(run) > end(l)) { continue }
            latest = run
        }
        return latest
    }

    /// Dismissed suggestions by environment and run, for every composer, for the app's lifetime (`dismissedKeys`).
    @MainActor public static var dismissed: Set<String> = []
    public static func key(environmentId: String, runId: RunId) -> String { environmentId + "\u{0}" + runId.rawValue }
}

/// The `⇥ Tab` hint after a prompt suggestion, as a button (ChatComposer.tsx:3978-3997 at 5258, #39488, #40841):
/// `aria-label` "Use suggested prompt", `cursor-pointer`, and the key's text turns `text-foreground` on hover.
@MainActor
final class PromptSuggestionHintButton: ControlView {
    let kbd = KbdView("⇥ Tab")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        kbd.outline = true
        addSubview(kbd)
        scalesWhenPressed = false
        setAccessibilityRole(.button)
        setAccessibilityLabel("Use suggested prompt")
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { kbd.intrinsicContentSize }
    override var accessibilityText: String? { "Use suggested prompt" }
    override func layout() { super.layout(); kbd.frame = bounds }
    override func stateDidChange(from old: State) {
        super.stateDidChange(from: old)
        if state.hovered != old.hovered { kbd.textOverride = state.hovered ? Themed.color(\.foreground) : nil }
    }
}
