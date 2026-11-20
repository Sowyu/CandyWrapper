import Foundation
import Testing
import T3Protocol
@testable import Features

/// #34002: a finished command's output (64 KB at most, CommandOutputBuffer) stays 5 minutes after its row closes, so reopening it needs no new stream.
@MainActor
struct CommandOutputKeepTests {
    private func frame(_ text: String, running: Bool) -> CommandOutputFrame {
        try! JSONDecoder().decode(CommandOutputFrame.self, from: Data(#"{"kind":"replace","text":"\#(text)","truncated":false,"running":\#(running)}"#.utf8))
    }

    @Test func keepsFinishedOutputAndDropsRunningOutput() async throws {
        let model = ThreadViewModel()
        model.receiveCommandOutput("done", .success(frame("ok", running: false)))
        model.receiveCommandOutput("live", .success(frame("...", running: true)))
        model.forgetCommandOutput("done")
        model.forgetCommandOutput("live")
        #expect(model.holdsFinishedCommandOutput("done"))
        #expect(!model.holdsFinishedCommandOutput("live"))
    }

    @Test func dropsFinishedOutputAfterItsTimeHidden() async throws {
        let model = ThreadViewModel()
        model.finishedOutputTTL = .milliseconds(20)
        model.receiveCommandOutput("done", .success(frame("ok", running: false)))
        model.forgetCommandOutput("done")
        try await Task.sleep(for: .milliseconds(150))
        #expect(!model.holdsFinishedCommandOutput("done"))
    }
}
