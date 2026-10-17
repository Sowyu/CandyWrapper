import Foundation
import Testing
import T3Protocol
@testable import T3Store

struct Nightly3234Tests {
    private func frame(_ kind: String, _ text: String, truncated: Bool = false) throws -> CommandOutputFrame {
        try JSONValue.object(["kind": .string(kind), "text": .string(text), "truncated": .bool(truncated), "running": .bool(true)]).decode(as: CommandOutputFrame.self)
    }
    @Test func commandOutputReplacesProgressAndCarriesSplitEscapes() throws {
        var output = CommandOutputBuffer()
        try output.apply(frame("replace", "Working 10%\rWorking 20%\u{1b}["))
        try output.apply(frame("append", "K\nSecond\u{1b}[1A\rDone\u{1b}[K"))
        #expect(output.text == "Done\nSecond")
        try output.apply(frame("replace", "final"))
        #expect(output.text == "final")
        try output.apply(frame("future", "ignored"))
        #expect(output.text == "final")
    }
    @Test func commandOutputBoundsLongLinesAndHistory() throws {
        var output = CommandOutputBuffer()
        try output.apply(frame("replace", String(repeating: "x", count: 70_000)))
        #expect(output.truncated)
        #expect(output.text.count <= 65_536)
        try output.apply(frame("append", String(repeating: "\nnext", count: 20_000)))
        #expect(output.text.count <= 65_536)
        #expect(output.text.hasSuffix("next"))
    }
    @Test func commandOutputClampsUntrustedCursorDistances() throws {
        var output = CommandOutputBuffer()
        try output.apply(frame("replace", "x\u{1b}[9223372036854775807Cx"))
        #expect(output.text.count <= 65_536)
        try output.apply(frame("append", "\n\u{1b}[9223372036854775807Bx"))
        #expect(output.text.hasSuffix("x"))
    }
    @Test func providerCheckTimeDoesNotChangePickerPresentation() {
        var a = ServerProvider(instanceId: "test", driver: "claudeAgent", models: [])
        a.checkedAt = "old"
        var b = a; b.checkedAt = "new"
        #expect(a != b)
        #expect(a.hasSamePresentation(as: b))
        b.message = "Unavailable"
        #expect(!a.hasSamePresentation(as: b))
    }
    @Test func htmlImageMessagesAcceptOnlyImageSources() {
        func message(_ src: String) -> JSONValue {
            .object(["jsonrpc": .string("2.0"), "method": .string("t3/notifications/open-image"), "params": .object(["src": .string(src)])])
        }
        #expect(HtmlRenderTheme.imageRequest(message("https://example.com/a.png"))?.name == "Image")
        #expect(HtmlRenderTheme.imageRequest(message("data:image/png;base64,AA")) != nil)
        #expect(HtmlRenderTheme.imageRequest(message("file:///etc/passwd")) == nil)
        #expect(HtmlRenderTheme.imageRequest(message("javascript:alert(1)")) == nil)
    }
}
