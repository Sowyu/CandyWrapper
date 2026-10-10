import Foundation
import Testing
@testable import T3Protocol

/// The browser's wire pieces: viewer messages (serverBrowserStream.ts), close codes, the address
/// bar (packages/shared/src/preview.ts) and zoom stepping (PreviewView.tsx:357-376).
struct PreviewTests {
    func object(_ s: String) -> [String: JSONValue] {
        guard case .object(let o) = try! JSONDecoder().decode(JSONValue.self, from: Data(s.utf8)) else { return [:] }
        return o
    }

    @Test func inputEncoding() {
        let mouse = object(PreviewStream.Input.mouse(action: "down", x: 10.5, y: 20, button: .left, buttons: 1, clickCount: 2, modifiers: 8).encoded)
        #expect(mouse["type"] == .string("mouse"))
        #expect(mouse["button"] == .string("left"))
        #expect(mouse["x"] == .number(10.5))
        #expect(mouse["clickCount"] == .number(2))
        #expect(mouse["modifiers"] == .number(8))
        let key = object(PreviewStream.Input.key(action: "down", key: "Enter", code: "Enter", keyCode: 13, text: "\r", modifiers: 0).encoded)
        #expect(key["text"] == .string("\r"))
        #expect(key["keyCode"] == .number(13))
        let up = object(PreviewStream.Input.key(action: "up", key: "a", code: "KeyA", keyCode: 65, text: nil, modifiers: 0).encoded)
        #expect(up["text"] == nil)
        #expect(object(PreviewStream.Input.reload(ignoreCache: false).encoded) == ["type": .string("reload")])
        #expect(object(PreviewStream.Input.history(delta: -1).encoded)["delta"] == .number(-1))
        #expect(object(PreviewStream.Input.dialog(accept: true, promptText: "x").encoded)["promptText"] == .string("x"))
        #expect(object(PreviewStream.Input.takeControl.encoded) == ["type": .string("takeControl")])
    }

    @Test func messageDecoding() {
        #expect(PreviewStream.Message.decode(#"{"type":"viewport","width":800,"height":600}"#) == .viewport(width: 800, height: 600))
        let control = PreviewStream.Message.decode(#"{"type":"control","canOperate":true,"controller":"another-viewer","generation":3,"dialog":null}"#)
        #expect(control == .control(.init(canOperate: true, controller: .anotherViewer, generation: 3)))
        let dialog = PreviewStream.Message.decode(#"{"type":"control","canOperate":true,"controller":"you","generation":1,"dialog":{"type":"prompt","message":"Name?","defaultValue":"a"}}"#)
        guard case .control(let c)? = dialog else { Issue.record("no control"); return }
        #expect(c.dialog?.type == "prompt" && c.dialog?.defaultValue == "a")
        #expect(PreviewStream.Message.decode(#"{"type":"pointer","phase":"click","x":1,"y":2,"sequence":7}"#) == .pointer(phase: "click", x: 1, y: 2, sequence: 7))
        #expect(PreviewStream.Message.decode(#"{"type":"pointer","phase":"drag","x":1,"y":2,"sequence":7}"#) == nil)
        #expect(PreviewStream.Message.decode(#"{"type":"fileChooser","id":"c1","multiple":false,"accept":"image/*"}"#) == .fileChooser(id: "c1", multiple: false, accept: "image/*"))
        #expect(PreviewStream.Message.decode(#"{"type":"popup","tabId":"t2"}"#) == .popup(tabId: "t2"))
        #expect(PreviewStream.Message.decode(#"{"type":"control","canOperate":true,"controller":"boss","generation":1,"dialog":null}"#) == nil)
        #expect(PreviewStream.Message.decode("not json") == nil)
    }

    @Test func controlLabels() {
        #expect(PreviewStream.Control.label(nil) == "Connecting...")
        #expect(PreviewStream.Control.label(.init(canOperate: false, controller: .you)) == "Read-only")
        #expect(PreviewStream.Control.label(.init(canOperate: true, controller: .agent)) == "Agent has control")
        #expect(PreviewStream.Control.label(.init(canOperate: true, controller: .unclaimed)) == "Watching")
    }

    @Test func closeOutcomes() {
        #expect(PreviewStream.closeOutcome(code: 4404, reason: "", opened: true) == .gone)
        #expect(PreviewStream.closeOutcome(code: 1006, reason: "", opened: false) == .unauthorized)
        #expect(PreviewStream.closeOutcome(code: 1006, reason: "", opened: true) == .retry)
        #expect(PreviewStream.closeOutcome(code: 4503, reason: #"{"need":"libraries","command":"x"}"#, opened: true)
                == .hostSetup(.init(need: "libraries", command: "x")))
        #expect(PreviewStream.HostSetup.decode("junk").command == "sudo npx t3 browser setup")
        #expect(PreviewStream.retryDelay(failures: 0) == .milliseconds(500))
        #expect(PreviewStream.retryDelay(failures: 9) == .milliseconds(10_000))
        #expect(PreviewStream.modifiers(alt: true, control: false, command: true, shift: true) == 13)
    }

    @Test func socketURL() {
        let url = PreviewStream.socketURL(base: URL(string: "http://127.0.0.1:47391")!, threadId: "th", tabId: "tab_1",
                                          maxWidth: 1080, maxHeight: 0, ticket: "tk")
        #expect(url?.absoluteString == "ws://127.0.0.1:47391/api/preview-stream/ws?threadId=th&tabId=tab_1&maxWidth=1080&maxHeight=1&wsTicket=tk")
        let https = PreviewStream.socketURL(base: URL(string: "https://host/base/")!, threadId: "a", tabId: "b", maxWidth: 1, maxHeight: 1, ticket: nil)
        #expect(https?.absoluteString.hasPrefix("wss://host/base/api/preview-stream/ws?") == true)
    }

    @Test func addressBar() {
        #expect(PreviewURL.resolveAddressBarInput("localhost:5173") == "http://localhost:5173/")
        #expect(PreviewURL.resolveAddressBarInput("example.com") == "https://example.com/")
        #expect(PreviewURL.resolveAddressBarInput("http://Example.com/a?b=1") == "http://example.com/a?b=1")
        #expect(PreviewURL.resolveAddressBarInput("devbox:8080") == "https://devbox:8080/")
        #expect(PreviewURL.resolveAddressBarInput("hello world") == "https://duckduckgo.com/?q=hello%20world")
        #expect(PreviewURL.resolveAddressBarInput("swift") == "https://duckduckgo.com/?q=swift")
        #expect(PreviewURL.resolveAddressBarInput("mailto:a@b.c") == nil)
        #expect(PreviewURL.resolveAddressBarInput("ftp://x") == nil)
        #expect(PreviewURL.resolveAddressBarInput("   ") == nil)
        #expect(PreviewURL.normalize("127.0.0.1:3000/x") == "http://127.0.0.1:3000/x")
        #expect(PreviewURL.host(of: "http://localhost:47420/a") == "localhost:47420")
    }

    @Test func favicons() {
        #expect(PreviewURL.faviconURL(for: "https://github.com/x")?.absoluteString == "https://www.google.com/s2/favicons?domain=github.com&sz=32")
        #expect(PreviewURL.faviconURL(for: "http://localhost:3000") == nil)
        #expect(PreviewURL.faviconURL(for: "http://10.0.0.2") == nil)
        #expect(PreviewURL.faviconURL(for: "https://grafana.internal.acme.com") == nil)
        #expect(PreviewURL.faviconURL(for: "https://app.test") == nil)
    }

    @Test func errorText() {
        #expect(PreviewURL.describeError("ERR_CONNECTION_REFUSED") == "Connection refused")
        #expect(PreviewURL.describeError("") == "Network error")
        #expect(PreviewURL.errorLabel(code: -105, description: "") == "ERR_105")
        #expect(PreviewURL.errorLabel(code: 0, description: "") == "ERR_FAILED")
    }

    @Test func zoomSteps() {
        #expect(PreviewRPC.steppedZoom(from: 1.0, direction: 1) == 1.1)
        #expect(PreviewRPC.steppedZoom(from: 0.25, direction: -1) == nil)
        #expect(PreviewRPC.steppedZoom(from: 1.5, direction: 0) == 1.0)
        #expect(PreviewRPC.steppedZoom(from: 1.0, direction: 0) == nil)
        // An unknown factor steps from 100%.
        #expect(PreviewRPC.steppedZoom(from: 1.05, direction: -1) == 0.9)
    }

    @Test func snapshotDecoding() throws {
        let json = #"{"threadId":"t","tabId":"tab_1","navStatus":{"_tag":"LoadFailed","url":"http://x/","title":"","code":-102,"description":"ERR_CONNECTION_REFUSED"},"canGoBack":false,"canGoForward":true,"runtime":"server","updatedAt":"2026"}"#
        let snapshot = try JSONDecoder().decode(PreviewSessionSnapshot.self, from: Data(json.utf8))
        #expect(snapshot.navStatus.isFailed && snapshot.isServerTab && snapshot.tabTitle == "x")
        let idle = PreviewSessionSnapshot(threadId: "t", tabId: "a", updatedAt: "1")
        #expect(idle.tabTitle == "Browser" && !idle.hasFixedViewport)
        let titled = PreviewSessionSnapshot(threadId: "t", tabId: "a", navStatus: .success(url: "http://a/", title: "Hi"), updatedAt: "1")
        #expect(titled.tabTitle == "Hi")
    }

    @Test func contentRanges() {
        let m = ProjectContentMatch(path: "a", lineNumber: 1, lineContent: "abcdef",
                                    matchRanges: [.init(start: 3, end: 5), .init(start: 0, end: 2), .init(start: 1, end: 3), .init(start: 4, end: 99), .init(start: 2, end: 2)])
        #expect(m.normalizedRanges == [.init(start: 0, end: 6)])
        let payload = ProjectContentSearchResult.payload(cwd: "/w", query: " x ", caseSensitive: true, wholeWord: false, useRegex: false)
        #expect(payload["query"] == .string(" x ") && payload["limit"] == .number(500))
    }
}
