import AppKit
import Testing
import DesignSystem
@testable import Features

struct StartupRecoveryTests {
    struct Failure: Error, CustomStringConvertible { var description: String }

    @Test func reportsDropHostsCredentialsAndPrivatePaths() {
        let error = Failure(description: "Could not load https://user:password@studio.example:3773/assets/main.js?pair=SECRET#token=HIDDEN\nBearer AUTH\n/Users/tester/Library/log.txt\na@example.com")
        let report = StartupRecovery.report(error, version: "1.14.8", runtimeVersion: "3814", now: Date(timeIntervalSince1970: 0), userHome: "/Users/tester")
        for secret in ["studio.example", "password", "SECRET", "HIDDEN", "AUTH", "/Users/tester", "a@example.com"] {
            #expect(!report.contains(secret))
        }
        #expect(report.contains("/assets/main.js"))
        #expect(report.contains("~/Library/log.txt"))
        #expect(report.contains("CandyWrapper: 1.14.8"))
        #expect(report.contains("T3 runtime: 3814"))
    }

    @Test func reportsBoundErrorsAndUnderlyingCauses() {
        let report = StartupRecovery.report(Failure(description: String(repeating: "x", count: 7_000)), version: "1", runtimeVersion: nil)
        #expect(report.hasPrefix(String(repeating: "x", count: 6_000) + "\n[truncated]"))
        var error = NSError(domain: "test", code: 0, userInfo: [NSLocalizedDescriptionKey: "last"])
        for n in 1...6 { error = NSError(domain: "test", code: n, userInfo: [NSLocalizedDescriptionKey: "cause \(n)", NSUnderlyingErrorKey: error]) }
        let chained = StartupRecovery.report(error, version: "1", runtimeVersion: nil)
        #expect(chained.components(separatedBy: "Caused by:").count == 4)
    }

    @Test func triageUsesTheLauncherAndQuotesEveryArgument() {
        let command = StartupRecovery.triageCommand(launcher: "/Applications/Some App/O'Neil/t3", home: "/tmp/sandbox's home", userHome: "/Users/tester", path: "/usr/bin:/bin")
        #expect(command.hasPrefix("env -i HOME='/Users/tester' PATH='/usr/bin:/bin' "))
        #expect(command.contains("'/Applications/Some App/O'\"'\"'Neil/t3' triage"))
        #expect(command.hasSuffix("--base-dir '/tmp/sandbox'\"'\"'s home'"))
        #expect(StartupRecovery.triageCommand(launcher: nil, home: "/tmp/sandbox", userHome: "/Users/tester", path: "/usr/bin").contains("npx t3 triage --base-dir"))
    }

    @Test func repeatsAndUpdatesOfferOnlyApplicableActions() {
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(!StartupRecovery.repeats(previous: nil, now: now))
        #expect(StartupRecovery.repeats(previous: now.addingTimeInterval(-299), now: now))
        #expect(!StartupRecovery.repeats(previous: now.addingTimeInterval(-300), now: now))
        #expect(!StartupRecovery.repeats(previous: now.addingTimeInterval(1), now: now))
        var state = DesktopUpdateState(currentVersion: "1", channel: .nightly, enabled: true)
        #expect(StartupRecovery.updateAction(state) == nil)
        state.status = .available
        #expect(StartupRecovery.updateAction(state) == .download)
        state.status = .downloading
        state.downloadPercent = 42.6
        #expect(StartupRecovery.updateAction(state) == .downloading(43))
        state.status = .downloaded
        #expect(StartupRecovery.updateAction(state) == .install)
        state.enabled = false
        #expect(StartupRecovery.updateAction(state) == nil)
    }

    @MainActor @Test func recoveryActionsWorkWithoutAServer() throws {
        let command = StartupRecovery.triageCommand(launcher: "/Applications/CandyWrapper.app/Contents/Resources/runtime/t3", home: "/tmp/sandbox", userHome: "/Users/tester", path: "/usr/bin:/bin")
        let report = StartupRecovery.report(Failure(description: "The server did not become ready."), version: "1.14.8", runtimeVersion: "3814")
        let view = StartupRecoveryView(command: command, report: report, expanded: false)
        #expect(!view.expanded && view.command.isHidden)
        let collapsed = view.frame.height
        view.more.performAction()
        view.layoutSubtreeIfNeeded()
        #expect(view.expanded && !view.command.isHidden && view.frame.height > collapsed)
        #expect(view.reinstall.frame.maxY <= view.bounds.height)
        var copied: [String] = []
        view.copyText = { copied.append($0); return true }
        view.copyCommand.performAction()
        view.copyDetails.performAction()
        #expect(copied == [command, report])
        var state = DesktopUpdateState(currentVersion: "1", channel: .nightly, enabled: true)
        state.status = .available
        view.setUpdateState(state)
        var action: StartupRecovery.UpdateAction?
        view.onUpdate = { action = $0 }
        view.update.performAction()
        #expect(action == .download)
        state.status = .downloading
        view.setUpdateState(state)
        #expect(!view.update.isEnabled)
        try Fidelity.capture(view, name: "startup-recovery", size: view.frame.size)
    }
}
