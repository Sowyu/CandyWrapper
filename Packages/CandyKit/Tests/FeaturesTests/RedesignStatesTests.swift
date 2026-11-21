import AppKit
import Testing
@testable import DesignSystem
import T3Protocol
@testable import Features

extension RedesignStatesRenderTests.SpawnFailure: TypedErrorCarrying {
    var typedError: RPCTypedError? { typed }
}

extension RedesignStatesRenderTests {
    /// The state view's three sizes and an error toast, which only this branch has.
    func extraCaptures(_ capture: (String, NSView, NSSize) throws -> Void) throws {
        let copy = StateErrorText.describe(RedesignStatesRenderTests.SpawnFailure(), title: "Could not load changes", icon: .fileDiff)
        for (name, size, height) in [("state-panel", EmptyView.Size.default, 360.0), ("state-card", .compact, 220), ("state-inline", .inline, 40)] {
            let v = EmptyView(title: "", size: size)
            v.redesign = copy
            v.action = StateAction("Retry", icon: .refreshCw) {}
            try capture(name, v, NSSize(width: 460, height: height))
        }
        for (name, size, alt) in [("image-unavailable", NSSize(width: 360, height: 200), "diagram.png"),
                                  ("image-unavailable-small", NSSize(width: 240, height: 48), "logo.png")] {
            let v = EmptyView(title: "", size: size.height >= 120 ? .compact : .inline)
            v.redesign = AsyncImageView.failureCopy(MarkdownImages.unavailableLabel(alt))
            try capture(name, v, size)
        }
        let toast = ToastView(title: "Could not open file", message: "VcsProcessSpawnError", kind: .error)
        try capture("toast-raw-error", toast, NSSize(width: 360, height: toast.height(forWidth: 360)))
    }
}

/// Redesign's states: error copy, the state view's accessibility, and the default themes left alone.
@MainActor
struct RedesignStatesTests {
    static func withRedesign(_ on: Bool, _ body: () -> Void) {
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        var input = ThemeRuntimeInput(
            light: ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .light)!),
            dark: ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .dark)!))
        input.ditherLight = on; input.ditherDark = on
        if !on { input = ThemeRuntimeInput() }
        ThemeRuntime.apply(input)
        body()
    }

    @Test func spawnErrorNamesGitAndThePath() {
        let copy = StateErrorText.describe(RedesignStatesRenderTests.SpawnFailure(), title: "Could not load changes")
        #expect(copy.title == "Git could not start")
        #expect(copy.detail?.contains("/Users/demo/sandbox/demo-repo") == true)
        #expect(copy.detail?.contains("VcsProcessSpawnError") == false)
        #expect(copy.details?.hasPrefix("VcsProcessSpawnError") == true)
    }

    @Test func knownTagsGetPlainSentences() {
        let auth = RPCTypedError(tag: "VcsProcessExitError", fields: ["failureKind": .string("authentication"), "cwd": .string("/r"), "exitCode": .number(128)])
        #expect(StateErrorText.describe(typed: auth, title: "x").title == "Git could not sign in")
        let exit = RPCTypedError(tag: "VcsProcessExitError", fields: ["failureKind": .string("command-failed"), "cwd": .string("/r"), "exitCode": .number(128)])
        #expect(StateErrorText.describe(typed: exit, title: "Could not load changes").detail == "Git exited with code 128 in /r. Retry, or open Details for git's output.")
        let repo = RPCTypedError(tag: "VcsRepositoryDetectionError", fields: ["cwd": .string("/r")])
        #expect(StateErrorText.describe(typed: repo, title: "x").title == "Not a git repository")
        let offline = RPCTypedError(tag: "EnvironmentRpcUnavailableError", fields: [:])
        #expect(StateErrorText.describe(typed: offline, title: "x").title == "Not connected")
    }

    @Test func unknownErrorsKeepTheRawTextInDetailsOnly() {
        let bare = StateErrorText.describe(raw: "SomeNewServerError", title: "Could not load issues")
        #expect(bare.title == "Could not load issues")
        #expect(bare.detail == StateErrorText.generic)
        #expect(bare.details == "SomeNewServerError")
        let tagged = StateErrorText.describe(typed: RPCTypedError(tag: "SomeNewServerError", fields: ["foo": .number(1)]), title: "Could not load issues")
        #expect(tagged.detail == StateErrorText.generic)
        #expect(tagged.details == "SomeNewServerError\nfoo: 1")
        let sentence = StateErrorText.describe(raw: "The repository is archived", title: "Could not load issues")
        #expect(sentence.detail == "The repository is archived.")
        #expect(StateErrorText.describe(raw: nil, title: "t").detail == StateErrorText.generic)
        #expect(StateErrorText.isTypeName("ECONNRESET"))
        #expect(!StateErrorText.isTypeName("Request failed."))
    }

    @Test func stateViewExposesTitleDetailAndAction() {
        Self.withRedesign(true) {
            var pressed = 0
            let v = EmptyView(title: "T3 title", size: .default)
            v.redesign = StateCopy(title: "Git could not start", detail: "Check that git is installed.", icon: .gitBranch, details: "VcsProcessSpawnError")
            v.action = StateAction("Retry") { pressed += 1 }
            v.frame = NSRect(x: 0, y: 0, width: 460, height: 360)
            v.layoutSubtreeIfNeeded()
            #expect(v.accessibilityRole() == .group)
            #expect(v.accessibilityLabel() == "Git could not start")
            #expect(v.accessibilityHelp() == "Check that git is installed.")
            #expect(v.toolTip == "VcsProcessSpawnError")
            let buttons = v.subviews.compactMap { $0 as? ButtonView }.filter { !$0.isHidden }
            let retry = buttons.first { $0.title == "Retry" }
            #expect(retry != nil)
            #expect(retry?.accessibilityLabel() == "Retry" || retry?.accessibilityTitle() == "Retry")
            _ = retry?.accessibilityPerformPress()
            #expect(pressed == 1)
            #expect(buttons.contains { $0.title == "Details" })
        }
    }

    @Test func defaultThemesKeepT3Copy() {
        Self.withRedesign(false) {
            let v = EmptyView(title: "No preview yet", message: "Type a URL above.", icon: .globe)
            v.redesign = StateCopy(title: "Other", detail: "Other detail")
            v.action = StateAction("Retry") {}
            v.frame = NSRect(x: 0, y: 0, width: 460, height: 360)
            v.layoutSubtreeIfNeeded()
            #expect(v.accessibilityLabel() == "No preview yet")
            let shown = v.subviews.compactMap { $0 as? ButtonView }.filter { !$0.isHidden }
            #expect(shown.isEmpty)
        }
    }

    @Test func skeletonOnlyBreathesWhileShownAndMotionIsOn() {
        let motion = Motion.reducedOverride
        defer { Motion.reducedOverride = motion }
        Motion.reducedOverride = false
        let s = StateSkeletonView(shape: .diff)
        #expect(!s.isAnimating) // no window
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(s)
        s.isHidden = true
        #expect(!s.isAnimating)
        window.contentView = nil
    }

    @Test func diffStateMapsT3Messages() {
        #expect(DiffPanelState(message: "Loading changes...", error: nil, failure: nil) == .loading)
        #expect(DiffPanelState(message: "", error: nil, failure: nil) == .none)
        if case .empty(let c) = DiffPanelState(message: "No net changes in this selection.", error: nil, failure: nil) { #expect(c.title == "No net changes") }
        else { Issue.record("expected empty") }
        let failed = DiffPanelState(message: "No patch available for this selection.", error: "VcsProcessSpawnError", failure: RedesignStatesRenderTests.SpawnFailure())
        #expect(failed.isFailure)
    }

    @Test func imageFailureSplitsTheLabel() {
        let c = AsyncImageView.failureCopy(MarkdownImages.unavailableLabel("diagram.png"))
        #expect(c.title == "Image unavailable")
        #expect(c.details == "Alt text: diagram.png")
        let reason = AsyncImageView.failureCopy(MarkdownImages.unavailableLabel("x.png", detail: "Allow file access."))
        #expect(reason.detail == "Allow file access.")
    }
}

extension RedesignStatesTests {
    final class Counter: @unchecked Sendable { var calls = 0 }

    /// Retry on the Diff panel's failure state asks the loader again.
    @Test func diffRetryRunsTheRequestAgain() async throws {
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        var input = ThemeRuntimeInput(
            light: ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .light)!),
            dark: ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .dark)!))
        input.ditherLight = true; input.ditherDark = true
        ThemeRuntime.apply(input)
        let counter = Counter()
        let panel = RedesignStatesRenderTests.diffPanel { counter.calls += 1; throw RedesignStatesRenderTests.SpawnFailure() }
        _ = await eventually { panel.redesignState.isFailure }
        panel.syncRedesignState()
        #expect(panel.message.isHidden && panel.errorLine.isHidden)
        #expect(!panel.stateView.isHidden)
        #expect(counter.calls == 1)
        panel.stateView.action?.handler()
        _ = await eventually { counter.calls == 2 }
        #expect(counter.calls == 2)
    }
}
