import Foundation
import Testing
import T3Protocol
@testable import Features

struct DesktopLeftoversTests {
    @Test func modifierPairsFireOnlyOnRisingEdges() {
        var state = SnapShotShortcutState()
        let shortcut: JSONValue = .object(["kind": .string("both-shift-keys")])
        let result1 = (!state.update(flags: 0x02, shortcut: shortcut))
        #expect(result1)
        let result2 = (state.update(flags: 0x06, shortcut: shortcut))
        #expect(result2)
        let result3 = (!state.update(flags: 0x06, shortcut: shortcut))
        #expect(result3)
        let result4 = (!state.update(flags: 0x04, shortcut: shortcut))
        #expect(result4)
        let result5 = (state.update(flags: 0x06, shortcut: shortcut))
        #expect(result5)
        state.reset()
        let result6 = (!state.update(flags: 0, shortcut: shortcut))
        #expect(result6)
    }
    @Test func pairsDistinguishSides() {
        for (name, left, right) in [("meta", 8, 16), ("control", 1, 8192), ("alt", 32, 64)] {
            var state = SnapShotShortcutState()
            let shortcut: JSONValue = .object(["kind": .string("modifier-pair"), "modifier": .string(name)])
            let result7 = (!state.update(flags: UInt64(left), shortcut: shortcut))
            #expect(result7)
            let result8 = (state.update(flags: UInt64(left | right), shortcut: shortcut))
            #expect(result8)
            let result9 = (!state.update(flags: UInt64(right), shortcut: shortcut))
            #expect(result9)
        }
    }
    @Test func remoteLinksEncodeHostAndPath() {
        #expect(OpenInEditors.remoteURL(editor: "vscode", host: "user@host", path: "/a b/#x")?.absoluteString == "vscode://vscode-remote/ssh-remote+user%40host/a%20b/%23x")
        #expect(OpenInEditors.remoteURL(editor: "zed", host: "work", path: "C:\\Users\\me")?.absoluteString == "zed://ssh/work/Users/me")
        #expect(OpenInEditors.remoteURL(editor: "zed", host: "work", path: "/C:/keep")?.absoluteString == "zed://ssh/work/C%3A/keep")
        #expect(OpenInEditors.remoteURL(editor: "file-manager", host: "work", path: "/") == nil)
        #expect(OpenInEditors.remoteURL(editor: "idea", host: "work", path: "/a b")?.absoluteString == "jetbrains://gateway/ssh/environment?h=work&launchIde=true&ideHint=IU&projectHint=%2Fa+b")
        // The SSH user and a file position (contracts/editor.ts:180-224, remoteOpen.ts:78-90).
        #expect(OpenInEditors.remoteURL(editor: "cursor", host: "box", username: "me", path: "/a.ts", isFile: true)?.absoluteString == "cursor://vscode-remote/ssh-remote+me%40box/a.ts:1:1")
        #expect(OpenInEditors.remoteURL(editor: "zed", host: "box", username: "me", path: "/a")?.absoluteString == "zed://ssh/me@box/a")
        #expect(OpenInEditors.remoteURL(editor: "idea", host: "box", username: "me", path: "/a!")?.absoluteString == "jetbrains://gateway/ssh/environment?h=box&launchIde=true&ideHint=IU&projectHint=%2Fa%21&u=me")
        #expect(OpenInEditors.sshDestination(alias: "me@box", username: nil) == ("box", "me"))
        #expect(OpenInEditors.sshDestination(alias: "me@box", username: " root ") == ("box", "root"))
        #expect(OpenInEditors.sshDestination(alias: "box", username: "") == ("box", nil))
    }
    @Test func keybindingsSuccessCooldown() {
        var notice = KeybindingsUpdateNotice()
        let result10 = (notice.shouldShowSuccess(now: 0))
        #expect(result10)
        let result11 = (!notice.shouldShowSuccess(now: 1.999))
        #expect(result11)
        let result12 = (notice.shouldShowSuccess(now: 2))
        #expect(result12)
    }
    @Test func invalidKeybindingsPreserveMessage() throws {
        let event = try JSONDecoder().decode(ServerConfigEvent.self, from: Data(#"{"type":"keybindingsUpdated","payload":{"keybindings":[],"issues":[{"kind":"keybindings.parse","message":"Bad JSON"}]}}"#.utf8))
        guard case .keybindingsInvalid(_, let message) = event else { Issue.record("Expected invalid configuration"); return }
        #expect(message == "Bad JSON")
    }
}
