import Foundation
import T3Protocol
import Testing
@testable import T3Store

/// HTML renders and MCP Apps in the timeline (packages/shared/src/htmlRender.test.ts, toolOutput.ts, mcpApp.ts) and
/// the MCP Apps host bridge (packages/client-runtime/src/mcpApps/host.test.ts).
@Suite @MainActor struct ThreadWebContentTests {
    let reference: JSONValue = .object(["attachmentId": .string("att-1"), "title": .string("Report"), "height": .number(480)])

    private func json(_ text: String) -> JSONValue { try! JSONValue(parsing: Data(text.utf8)) }

    private func tool(_ name: String, _ output: JSONValue, status: String = "completed") -> TurnItem {
        var o: [String: JSONValue] = ["id": .string("item-1"), "threadId": .string("t"), "type": .string("dynamic_tool"),
                                      "ordinal": .number(1), "status": .string(status), "updatedAt": .string("2026-01-01T00:00:00.000Z"),
                                      "toolName": .string(name)]
        o["output"] = output
        return try! JSONValueDecoder().decode(TurnItem.self, from: .object(o))
    }

    @Test func clampsHeightAndRejectsMalformedReferences() {
        var big = reference.objectValue!; big["height"] = .number(99_999)
        #expect(HtmlRenderReference(.object(big))?.height == 2000)
        var blank = reference.objectValue!; blank["title"] = .string("  ")
        #expect(HtmlRenderReference(.object(blank))?.title == "HTML")
        var badId = reference.objectValue!; badId["attachmentId"] = .number(4)
        #expect(HtmlRenderReference(.object(badId)) == nil)
        var badTable = reference.objectValue!; badTable["heights"] = json(#"[[728,"x"]]"#)
        #expect(HtmlRenderReference(.object(badTable))?.heights == nil)
    }

    @Test func readsTheReferenceFromEachProvidersEnvelope() {
        let result = json(#"{"htmlRender":{"attachmentId":"att-1","title":"Report","height":480},"message":"Rendered above your reply."}"#)
        let text = String(data: try! JSONEncoder().encode(result), encoding: .utf8)!
        let envelopes: [(String, JSONValue)] = [
            ("mcp__t3-code__html_render", .array([.object(["type": .string("text"), "text": .string(text)])])),
            ("t3-code.html_render", .object(["structuredContent": result, "content": .array([])])),
            ("html_render", result),
        ]
        for (name, output) in envelopes {
            #expect(ThreadWebContent.htmlRender(tool(name, output))?.attachmentId == "att-1", "\(name)")
        }
        #expect(ThreadWebContent.htmlRender(tool("mcp__t3-code__html_preview", result)) == nil)
        #expect(ThreadWebContent.htmlRender(tool("mcp__other__html_render", result)) == nil)
        var failed = result.objectValue!; failed["isError"] = .bool(true)
        #expect(ThreadWebContent.htmlRender(tool("html_render", .object(failed))) == nil)
        #expect(ThreadWebContent.htmlRender(tool("html_render", result, status: "running")) == nil)
    }

    @Test func frameHeightFollowsTheMeasuredTable() {
        var m = reference.objectValue!
        m["height"] = .number(1500)
        m["heights"] = json("[[728,1403],[390,1290],[1000,1660]]")
        let measured = HtmlRenderReference(.object(m))!
        #expect(measured.heights?.map { $0[0] } == [390, 728, 1000])
        #expect(measured.frameHeight(width: 728) == 1403)
        #expect(measured.frameHeight(width: 559) == 1403)
        #expect(measured.frameHeight(width: 320) == 1290)
        let fitted = HtmlRenderReference(attachmentId: "a", title: "t", height: 1403, heights: measured.heights)
        #expect(fitted.frameHeight(width: 728, contentHeight: 1415) == 1415)
        #expect(fitted.frameHeight(width: 1400) == 1660)
        #expect(fitted.frameHeight(width: 728, contentHeight: 5000) == HtmlRenderReference.maxHeight)
        let scrolling = HtmlRenderReference(attachmentId: "a", title: "t", height: 600, heights: measured.heights)
        #expect(scrolling.frameHeight(width: 728, contentHeight: 1415) == 600)
        let plain = HtmlRenderReference(reference)!
        #expect(plain.frameHeight(width: 728) == 480)
        #expect(plain.frameHeight(width: 728, contentHeight: 900) == 480)
        #expect(plain.frameHeight(width: 728, contentHeight: 300) == 300)
        #expect(HtmlRenderReference(attachmentId: "a", title: "A/B: <x>", height: 80).fileName == "A B x.html")
    }

    @Test func mcpAppCountsOnlyForItsOwnServerAndTool() {
        let app = #"{"t3McpApp":{"attachmentId":"a1","server":"maps","tool":"show","resourceUri":"ui://maps/view","permissions":{"camera":{}},"prefersBorder":true}}"#
        let ref = ThreadWebContent.mcpApp(tool("maps.show", json(app)))
        #expect(ref?.server == "maps" && ref?.prefersBorder == true)
        #expect(ref?.allowAttribute == "camera")
        #expect(ThreadWebContent.mcpApp(tool("other.show", json(app))) == nil)
        #expect(McpAppReference(json(#"{"attachmentId":"a","server":"s","tool":"t","resourceUri":"https://x"}"#)) == nil)
        #expect(McpAppReference.clamp(5000) == 2000)
    }

    @Test func themeFragmentDecodesAndMessagesCarryTheVariables() throws {
        let dark = HtmlRenderTheme(dark: true)
        #expect(dark.variables["--background"] == "#0a0a0a")
        #expect(dark.variables["--accent"] == "#346bf1")
        #expect(dark.variables["--chart-6"] == "#a3e635")
        let encoded = String(dark.fragment.dropFirst("#t3-theme=".count))
        let decoded = try JSONValue(parsing: Data(encoded.removingPercentEncoding!.utf8))
        #expect(decoded["appearance"]?.stringValue == "dark")
        #expect(dark.message["params"]?["styles"]?["variables"]?["--foreground"]?.stringValue == "#f5f5f5")
        #expect(HtmlRenderTheme.contentHeight(json(#"{"jsonrpc":"2.0","method":"ui/notifications/size-changed","params":{"height":312}}"#)) == 312)
        #expect(HtmlRenderTheme.contentHeight(json(#"{"jsonrpc":"2.0","method":"ui/notifications/size-changed","params":{"height":-1}}"#)) == nil)
        #expect(HtmlRenderTheme.linkRequest(json(#"{"jsonrpc":"2.0","id":3,"method":"ui/open-link","params":{"url":"javascript:alert(1)"}}"#)) == nil)
        #expect(HtmlRenderTheme.linkRequest(json(#"{"jsonrpc":"2.0","id":3,"method":"ui/open-link","params":{"url":"https://t3.codes"}}"#))?.url == "https://t3.codes")
        #expect(McpAppHostBridge.styleVariables(dark.variables)["--color-background-primary"] == "#0a0a0a")
    }

    // MARK: Bridge

    private final class Posted { var messages: [JSONValue] = [] }

    private func bridge(_ posted: Posted, callTool: @escaping (String, JSONValue) async throws -> JSONValue = { _, _ in .object([:]) },
                        context: @escaping () -> JSONValue = { .object(["theme": .string("dark")]) }) -> McpAppHostBridge {
        let app = McpAppReference(json(#"{"attachmentId":"a","server":"maps","tool":"show","resourceUri":"ui://maps"}"#))!
        return McpAppHostBridge(app: app, hostVersion: "1", callbacks: .init(
            post: { posted.messages.append($0) }, hostContext: context, callTool: callTool,
            readResource: { _ in .object(["contents": .array([])]) }, openLink: { _ in }, sendMessage: { _ in },
            updateModelContext: { _, _ in }, onSizeChanged: { _, _ in }, onRequestTeardown: {}))
    }

    @Test func initializesThenReplaysTheToolCallOnce() {
        let posted = Posted()
        let b = bridge(posted)
        b.setToolCall(arguments: json(#"{"q":1}"#), result: json(#"{"content":[],"_meta":null,"isError":false}"#))
        #expect(posted.messages.isEmpty)
        b.receive(json(#"{"jsonrpc":"2.0","id":1,"method":"ui/initialize","params":{"protocolVersion":"2026-01-26"}}"#))
        #expect(posted.messages[0]["result"]?["protocolVersion"]?.stringValue == "2026-01-26")
        #expect(posted.messages[0]["result"]?["hostContext"]?["theme"]?.stringValue == "dark")
        b.receive(json(#"{"jsonrpc":"2.0","method":"ui/notifications/initialized"}"#))
        #expect(posted.messages.map { $0["method"]?.stringValue } == [nil, "ui/notifications/tool-input", "ui/notifications/tool-result"])
        // Null fields providers report are dropped.
        #expect(posted.messages[2]["params"]?["_meta"] == nil && posted.messages[2]["params"]?["isError"] == nil)
        b.setToolCall(arguments: .object([:]), result: nil)
        #expect(posted.messages.count == 3)
    }

    @Test func sendsOnlyChangedContextAndNothingBeforeInitialization() {
        let posted = Posted()
        var theme = "dark"
        let b = bridge(posted, context: { .object(["theme": .string(theme), "displayMode": .string("inline")]) })
        b.updateHostContext()
        #expect(posted.messages.isEmpty)
        b.receive(json(#"{"jsonrpc":"2.0","id":1,"method":"ui/initialize","params":{}}"#))
        b.receive(json(#"{"jsonrpc":"2.0","method":"ui/notifications/initialized"}"#))
        theme = "light"
        b.updateHostContext()
        let last = posted.messages.last!
        #expect(last["method"]?.stringValue == "ui/notifications/host-context-changed")
        #expect(last["params"]?.objectValue?.keys.sorted() == ["theme"])
    }

    @Test func proxiesToolCallsAndReportsRefusals() async throws {
        let posted = Posted()
        let b = bridge(posted, callTool: { name, _ in
            if name == "nope" { throw McpAppHostBridge.Refusal("Declined by the user.") }
            return self.json(#"{"content":[{"type":"text","text":"ok"}],"structuredContent":null}"#)
        })
        b.receive(json(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"go","arguments":{}}}"#))
        b.receive(json(#"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"nope"}}"#))
        b.receive(json(#"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"arguments":{}}}"#))
        b.receive(json(#"{"jsonrpc":"2.0","id":10,"method":"ui/unknown"}"#))
        try await Task.sleep(for: .milliseconds(50))
        let byId = Dictionary(posted.messages.compactMap { m in m["id"]?.doubleValue.map { (Int($0), m) } }, uniquingKeysWith: { a, _ in a })
        #expect(byId[7]?["result"]?["content"]?[0]?["text"]?.stringValue == "ok")
        #expect(byId[7]?["result"]?["structuredContent"] == nil)
        #expect(byId[8]?["error"]?["message"]?.stringValue == "Declined by the user.")
        #expect(byId[9]?["error"]?["code"]?.doubleValue == -32602)
        #expect(byId[10]?["error"]?["code"]?.doubleValue == -32601)
    }

    @Test func threadSweepDisplayModesDownloadsAndQueuedMessageCallbacks() async throws {
        let posted = Posted()
        let app = try #require(McpAppReference(json(#"{"attachmentId":"a","server":"maps","tool":"show","resourceUri":"ui://maps"}"#)))
        var requestedModes: [String] = [], messages: [String] = [], downloads: [ThreadMcpAppDownload] = []
        let b = McpAppHostBridge(app: app, hostVersion: "1", callbacks: .init(
            post: { posted.messages.append($0) },
            hostContext: { .object(["availableDisplayModes": .array([.string("inline"), .string("fullscreen")])]) },
            callTool: { _, _ in .null }, readResource: { _ in .null }, openLink: { _ in },
            sendMessage: { messages.append($0) }, updateModelContext: { _, _ in },
            onSizeChanged: { _, _ in }, onRequestTeardown: {},
            downloadFiles: { downloads = $0 }, requestDisplayMode: { requestedModes.append($0); return $0 }))
        b.receive(json(#"{"jsonrpc":"2.0","id":1,"method":"ui/initialize","params":{"appCapabilities":{"availableDisplayModes":["inline"]}}}"#))
        b.receive(json(#"{"jsonrpc":"2.0","id":2,"method":"ui/request-display-mode","params":{"mode":"fullscreen"}}"#))
        b.receive(json(#"{"jsonrpc":"2.0","id":3,"method":"ui/request-display-mode","params":{"mode":"inline"}}"#))
        b.receive(json(#"{"jsonrpc":"2.0","id":4,"method":"ui/download-file","params":{"contents":[{"type":"resource","resource":{"name":"note.txt","text":"hello"}}]}}"#))
        b.receive(json(#"{"jsonrpc":"2.0","id":5,"method":"ui/message","params":{"role":"user","content":[{"type":"text","text":"Continue"}]}}"#))
        try await Task.sleep(for: .milliseconds(50))
        #expect(requestedModes.isEmpty)
        #expect(messages == ["Continue"])
        #expect(downloads.first?.bytes == Data("hello".utf8))
        #expect(posted.messages.first { $0["id"]?.doubleValue == 2 }?["result"]?["mode"]?.stringValue == "inline")
    }

    @Test func webContentEntriesBecomeTheirOwnRows() {
        let page = tool("mcp__t3-code__html_render", json(#"{"htmlRender":{"attachmentId":"att-1","title":"Report","height":480}}"#))
        let row = ProjectedTurnItem(position: 0, visibility: "local", sourceThreadId: "t", sourceItemId: page.id, item: page)
        let entry = TimelineEntries.entry(row, attempt: nil, planById: [:], folded: [])
        guard case .htmlRender(let ref, _)? = entry?.kind else { Issue.record("expected an html-render entry"); return }
        #expect(ref.title == "Report")
        #expect(entry?.isWebContent == true)
    }

    /// A page can post any JSON number as a request id; a huge one must not trap converting to Int.
    @Test func hugeNumericIdsDoNotCrash() {
        #expect(McpAppHostBridge.key(.number(7)) == "7")
        #expect(McpAppHostBridge.key(.number(1e300)) == String(1e300))
        #expect(McpAppHostBridge.key(.number(-1e300)) == String(-1e300))
    }
}
