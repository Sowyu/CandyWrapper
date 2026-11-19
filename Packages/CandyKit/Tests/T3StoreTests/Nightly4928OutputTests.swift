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

    /// #38946: Windows launchers unwrap like `sh -c`.
    @Test func windowsLaunchersUnwrap() {
        #expect(commandDisplayText("pwsh.exe -NoProfile -Command Get-ChildItem") == "Get-ChildItem")
        #expect(commandDisplayText("powershell -ExecutionPolicy Bypass -Command \"npm test\"") == "npm test")
        #expect(commandDisplayText("cmd /d /c dir") == "dir")
        #expect(commandDisplayText("pwsh -File build.ps1") == "pwsh -File build.ps1")
        #expect(commandDisplayText("cmd /c dir extra") == "cmd /c dir extra")
    }
}
