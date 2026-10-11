import Foundation
import Testing
import T3Protocol
@testable import Features

struct DesktopManagedStateTests {
    @Test func passwordExpiry() {
        let now = Date(timeIntervalSince1970: 100)
        let state = SshPasswordPromptState(target: "fixture", now: now)
        #expect(state.label(at: now) == "3:00")
        #expect(state.label(at: now.addingTimeInterval(120)) == "1:00")
        #expect(state.label(at: now.addingTimeInterval(181)) == "Expired")
        #expect(state.remaining(at: now.addingTimeInterval(179.1)) == 1)
    }
    @Test func installerConflictCancellationAndStages() {
        var state = RelayClientInstallState.idle
        let requested = state.request(version: "fixture"); #expect(requested)
        let conflict = state.request(version: "other"); #expect(!conflict)
        state.progress(.activating); #expect(state == .confirming("fixture"))
        state.respond(true); #expect(state == .installing("fixture", .checking))
        for stage in RelayClientInstallStage.allCases { state.progress(stage); #expect(state == .installing("fixture", stage)) }
        #expect(RelayClientInstallStage.activating.step == 7)
        state = .confirming("fixture"); state.respond(false); #expect(state == .closing)
        state.respond(true); #expect(state == .closing)
    }
    @MainActor @Test func expiredPromptOnlyDismisses() {
        let dialog = SshPasswordPromptDialog(state: .init(target: "fixture", now: .distantPast))
        #expect(!dialog.password.isEnabled && !dialog.proceed.isEnabled && dialog.cancel.title == "Dismiss")
        var answers: [String?] = []
        let live = SshPasswordPromptDialog(state: .init(target: "fixture"))
        live.onResponse = { answers.append($0) }
        live.password.text = "fixture-secret"
        live.proceed.action?()
        #expect(answers == ["fixture-secret"] && live.password.text.isEmpty)
        live.cancel.action?()
        #expect(answers == ["fixture-secret", nil])
    }
}
