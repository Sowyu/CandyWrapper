import Foundation
import Testing
import T3Protocol
@testable import T3Store

/// Nightly 4928 command output (docs/research/nightly-diff-4928.md, 1.8).
struct Nightly4928OutputTests {
    private func frame(_ kind: String, _ text: String) throws -> CommandOutputFrame {
        try JSONValue.object(["kind": .string(kind), "text": .string(text), "truncated": .bool(false), "running": .bool(true)]).decode(as: CommandOutputFrame.self)
    }

    /// #34332: wide characters take two columns, so a cursor move back over them overwrites the right text.
    @Test func overwritesCountWideCharactersAsTwoColumns() throws {
        var output = CommandOutputBuffer()
        try output.apply(frame("replace", "進捗 50%\u{1b}[3D90%!"))
        #expect(output.text == "進捗 90%!")
        try output.apply(frame("replace", "ab漢c\r\u{1b}[3Cx"))
        // Column 3 is the second half of 漢: the half left over blanks.
        #expect(output.text == "ab x" + "c")
        try output.apply(frame("replace", "e\u{301}x\rE"))
        #expect(output.text == "Ex")
    }

    /// #29736 and #29737: private parameters and unknown erase modes leave the text alone.
    @Test func ignoresUnsupportedControls() throws {
        var output = CommandOutputBuffer()
        try output.apply(frame("replace", "abc\u{1b}[2D\u{1b}[?1K\u{1b}[>2J\u{1b}[5K\u{1b}[4J"))
        #expect(output.text == "abc")
        try output.apply(frame("replace", "abc\u{1b}[2D\u{1b}[K"))
        #expect(output.text == "a")
    }

    /// #38946: Windows launchers unwrap like `sh -c`.
    @Test func windowsLaunchersUnwrap() {
        #expect(commandDisplayText("pwsh.exe -NoProfile -Command Get-ChildItem") == "Get-ChildItem")
        #expect(commandDisplayText("powershell -ExecutionPolicy Bypass -Command \"npm test\"") == "npm test")
        #expect(commandDisplayText("cmd /d /c dir") == "dir")
        #expect(commandDisplayText("pwsh -File build.ps1") == "pwsh -File build.ps1")
        #expect(commandDisplayText("cmd /c dir extra") == "cmd /c dir extra")
    }

    /// #34883: an image clicked in an HTML render opens with the page's other images.
    @Test func htmlRenderImagesOpenAsAGallery() {
        let a = JSONValue.object(["src": .string("https://x/a.png"), "name": .string("A")])
        let b = JSONValue.object(["src": .string("data:image/png;base64,AA"), "name": .string("")])
        let message = JSONValue.object(["jsonrpc": .string("2.0"), "method": .string("t3/notifications/open-image"), "params": .object([
            "src": .string("data:image/png;base64,AA"), "name": .string(""), "images": .array([a, .string("bad"), b]), "index": .number(2)])])
        let request = HtmlRenderTheme.imageRequest(message)
        #expect(request?.images.map(\.src) == ["https://x/a.png", "data:image/png;base64,AA"])
        #expect(request?.index == 1)
        #expect(request?.images.last?.name == "Image")
    }
}
