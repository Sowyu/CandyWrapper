import AppKit
import Network
import Testing
import WebKit
import T3Protocol
@testable import Features

extension WebFrameSuites {
    /// The MCP app bridge's document binding in a real web view (5258 mcpAppDocumentLink.ts, T3 commits d4d08aed56
    /// #41745 and 2940ff33ad #42504): the bridge acts only through the port the first document hands over, and a
    /// document without the bootstrap gets no bridge at all.
    @MainActor
    struct McpAppDocumentLinkTests {
        /// `injectMcpAppDocumentBootstrap` (packages/shared/src/mcpApp.ts:260-269), verbatim.
        static let bootstrap = #"<script>(function(){var host=window.parent,port=new MessageChannel(),own=port.port1;own.onmessage=function(event){var data=event.data;if(!data)return;if("alive" in data)own.postMessage({alive:data.alive});else window.dispatchEvent(new MessageEvent("message",{data:data.message,origin:data.origin,source:host}));};host.postMessage({t3:"t3-mcp-app-document"},"*",[port.port2]);})();</script>"#

        /// An app that says hello, echoes what the host posts, and with `forge` also answers a probe nobody sent.
        static func app(bootstrap: Bool, forge: Bool = false) -> String {
            let forgery = forge ? #"var c=new MessageChannel();window.parent.postMessage({t3:"t3-mcp-app-document"},"*",[c.port2]);c.port1.postMessage({alive:0});"# : ""
            return "<!doctype html>" + (bootstrap ? Self.bootstrap : "") + """
            <script>
            \(forgery)
            window.addEventListener("message", function(e){ if (e.data && e.data.ping) window.parent.postMessage({echo: e.data.ping}, "*"); });
            window.parent.postMessage({hello: 1}, "*");
            </script>
            """
        }

        final class Server: @unchecked Sendable {
            let listener: NWListener
            var pages: [String: String] = [:]
            init() throws {
                listener = try NWListener(using: .tcp, on: .any)
                listener.newConnectionHandler = { [weak self] c in
                    c.start(queue: .global())
                    c.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                        let line = data.flatMap { String(data: $0, encoding: .utf8) }?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                        let body = Data((self?.pages[String(line.split(separator: "?").first ?? "/")] ?? "").utf8)
                        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                        c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
                    }
                }
                listener.start(queue: .global())
            }
            func url(_ path: String) async throws -> URL {
                for _ in 0..<100 where listener.port == nil { try await Task.sleep(for: .milliseconds(20)) }
                return URL(string: "http://127.0.0.1:\(listener.port!.rawValue)\(path)")!
            }
        }

        /// Loads `html` in a document-bound frame and collects what reaches the host for up to `seconds`.
        func run(_ html: String, post: JSONValue? = nil, seconds: Double = 6,
                 until done: @escaping ([JSONValue], Bool) -> Bool) async throws -> (messages: [JSONValue], missing: Bool) {
            let server = try Server()
            defer { server.listener.cancel() }
            server.pages["/app.html"] = html
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
            let frame = ThreadWebFrameView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
            frame.budgeted = false
            window.contentView?.addSubview(frame)
            defer { frame.release() }
            var messages: [JSONValue] = [], missing = false, posted = false
            frame.onMessage = { messages.append($0) }
            frame.onBridgeMissing = { missing = true }
            frame.activate(.init(src: try await server.url("/app.html"), title: "app", dark: false, documentBound: true))
            let end = Date().addingTimeInterval(seconds)
            while Date() < end, !done(messages, missing) {
                if let post, !posted, !messages.isEmpty { posted = true; frame.post(post) }
                try await Task.sleep(for: .milliseconds(50))
            }
            return (messages, missing)
        }

        @Test func theBootstrappedDocumentTalksOverItsPort() async throws {
            let ping: JSONValue = .object(["ping": .number(7)])
            let result = try await run(Self.app(bootstrap: true), post: ping) { messages, _ in messages.count >= 2 }
            #expect(!result.missing)
            // The hello arrives only after the port confirmed it, then the host's post reaches the app through the
            // port and its echo comes back the same way.
            #expect(result.messages.first == .object(["hello": .number(1)]))
            #expect(result.messages.contains(.object(["echo": .number(7)])))
            // The bootstrap's own port message is never forwarded as an app message.
            #expect(!result.messages.contains { $0["t3"] != nil })
        }

        @Test func aDocumentWithoutTheBootstrapGetsNoBridge() async throws {
            let result = try await run(Self.app(bootstrap: false), post: .object(["ping": .number(1)]), seconds: 3) { _, missing in missing }
            #expect(result.missing)
            #expect(result.messages.isEmpty)
        }

        @Test func aSecondPortIsOnlyAnAppMessage() async throws {
            // The bridge keeps the first document's port. A later port message is the document's own message,
            // delivered once that port confirms it; a probe answered on the later port delivers nothing more.
            let result = try await run(Self.app(bootstrap: true, forge: true), seconds: 3) { _, _ in false }
            #expect(!result.missing)
            #expect(result.messages == [.object(["t3": .string("t3-mcp-app-document")]), .object(["hello": .number(1)])])
        }

        @Test func plainRendersKeepTheWindowBridge() {
            let render = ThreadWebFrameView.bridgeScript(documentBound: false)
            let app = ThreadWebFrameView.bridgeScript(documentBound: true)
            #expect(render.contains("var bound = false") && app.contains("var bound = true"))
            #expect(app.contains(#""t3-mcp-app-document""#) && app.contains("256"))
        }
    }
}
