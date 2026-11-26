import AppKit
import Testing
import T3Protocol
@testable import Features
@testable import DesignSystem

/// MCP sign-in from a notice (5258 McpSignInAction.tsx, client-runtime threadCommands.ts:205-234).
@MainActor
struct McpSignInTests {
    @Test func aNoticeOlderThanTheSignInReadsSignedIn() {
        let at = Date(timeIntervalSince1970: 1_000)
        #expect(!McpSignIn.signedIn(noticeAt: at, signedInAt: nil))
        #expect(McpSignIn.signedIn(noticeAt: at, signedInAt: at))
        #expect(!McpSignIn.signedIn(noticeAt: at.addingTimeInterval(1), signedInAt: at))
    }

    @Test func theDialogWalksStartFinishAndFailure() async throws {
        let dialog = McpSignInDialog(server: "linear")
        #expect(dialog.title == "Sign in to linear")
        var completed: String?
        dialog.start = { "https://auth.example.com/approve" }
        dialog.complete = { completed = $0 }
        var signedIn = 0
        dialog.onSignedIn = { signedIn += 1 }
        dialog.begin()
        #expect(dialog.phase == .starting)
        try await waitUntil { dialog.phase == .ready("https://auth.example.com/approve") }

        let body = try #require(dialog.panelContent.first as? McpSignInBody)
        body.address.text = "  http://localhost:3000/callback?code=1 "
        body.address.onSubmit?()
        try await waitUntil { signedIn == 1 }
        #expect(completed == "http://localhost:3000/callback?code=1")

        // Already signed in: no page, straight to done.
        dialog.start = { nil }
        dialog.begin()
        try await waitUntil { signedIn == 2 }

        // A failed start offers Try again; a closed attempt ignores its late answer.
        dialog.start = { throw McpSignInDialog.Failure("Server not found") }
        dialog.begin()
        try await waitUntil { dialog.phase == .failed(url: nil, message: "Server not found") }
        dialog.start = { "https://late.example.com" }
        dialog.begin()
        dialog.cancelPending()
        try await Task.sleep(for: .milliseconds(50))
        #expect(dialog.phase == .starting)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<100 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }

    @Test func signInSitsAfterTheLabel() {
        let line = WorkLineView(frame: NSRect(x: 0, y: 0, width: 600, height: 24))
        line.configure(icon: .circleAlert, text: "linear needs you to sign in", style: .plain, time: nil, expanded: false, now: Date())
        line.setSignIn(false, server: "linear") {}
        line.layoutSubtreeIfNeeded()
        let action = line.subviews.compactMap { $0 as? ThreadStatusLineAction }.first { !$0.isHidden }
        #expect(action?.label.text == "Sign in")
        #expect(abs((action?.frame.minX ?? 0) - (line.label.frame.maxX + 6)) < 0.5)
        line.setSignIn(true, server: "linear", nil)
        line.layoutSubtreeIfNeeded()
        #expect(action?.isHidden == true)
        #expect(line.subviews.contains { ($0 as? LabelView)?.text == "Signed in" && !$0.isHidden })
    }

    /// Pictures of the line and the dialog for review, default theme and Redesign. Opt in with `CANDY_STATES_OUT`.
    @Test func render() async throws {
        guard let out = ProcessInfo.processInfo.environment["CANDY_STATES_OUT"] else { return }
        let dir = URL(fileURLWithPath: out)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let previous = ThemeRuntime.input, appearance = NSApp?.appearance
        defer { ThemeRuntime.apply(previous); NSApp?.appearance = appearance }
        for redesign in [false, true] {
            for dark in [true, false] {
                if redesign {
                    var input = ThemeRuntimeInput(light: ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .light)!),
                                                  dark: ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .dark)!))
                    input.ditherLight = true; input.ditherDark = true
                    ThemeRuntime.apply(input)
                } else { ThemeRuntime.apply(previous) }
                NSApplication.shared.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let suffix = "\(redesign ? "redesign" : "default").\(dark ? "dark" : "light")"
                let line = WorkLineView(frame: NSRect(x: 0, y: 0, width: 520, height: 24))
                line.configure(icon: .zap, text: "MCP server linear needs authentication", style: .plain, time: nil, expanded: false, now: Date())
                line.setSignIn(false, server: "linear") {}
                try Snapshot.writePNG(RedesignBaselineTests.image(line, size: NSSize(width: 520, height: 24), dark: dark),
                                      to: dir.appendingPathComponent("mcp-line.\(suffix).png"))
                let dialog = McpSignInDialog(server: "linear")
                dialog.start = { "https://mcp.linear.app/authorize?client_id=t3" }
                dialog.complete = { _ in throw McpSignInDialog.Failure("The sign-in page's address is not valid.") }
                dialog.begin()
                try await waitUntil { dialog.phase.url != nil }
                (dialog.panelContent.first as? McpSignInBody)?.address.text = "localhost:3000/callback?code=abc"
                dialog.panelContent.first.map { ($0 as? McpSignInBody)?.address.onSubmit?() }
                try await waitUntil { if case .failed = dialog.phase { true } else { false } }
                let size = NSSize(width: 560, height: dialog.height(forWidth: 512) + 48)
                let host = DSView(frame: NSRect(origin: .zero, size: size))
                dialog.frame = NSRect(x: 24, y: 24, width: 512, height: dialog.height(forWidth: 512))
                host.addSubview(dialog)
                try Snapshot.writePNG(RedesignBaselineTests.image(host, size: size, dark: dark), to: dir.appendingPathComponent("mcp-dialog.\(suffix).png"))
            }
        }
    }
}
