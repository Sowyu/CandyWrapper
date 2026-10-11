import Foundation
import T3Protocol

/// The host side of the MCP Apps bridge (packages/client-runtime/src/mcpApps/host.ts, spec 2026-01-26): JSON-RPC
/// 2.0 between the client and one app document. Transport free: the frame posts what `post` gets and hands every
/// message from its own document to `receive`.
@MainActor
public final class McpAppHostBridge {
    public static let protocolVersion = "2026-01-26"
    static let maxMessageBytes = 256 * 1024
    static let maxPending = 16

    /// Thrown by the callbacks to refuse a request with a message the app can show.
    public struct Refusal: Error, Sendable { public let message: String; public init(_ m: String) { message = m } }

    public struct Callbacks {
        public var post: (JSONValue) -> Void
        public var hostContext: () -> JSONValue
        public var callTool: (String, JSONValue) async throws -> JSONValue
        public var readResource: (String) async throws -> JSONValue
        public var openLink: (String) async throws -> Void
        public var sendMessage: (String) async throws -> Void
        public var updateModelContext: (JSONValue?, JSONValue?) async throws -> Void
        public var onSizeChanged: (Double?, Double?) -> Void
        public var onRequestTeardown: () -> Void
        public init(post: @escaping (JSONValue) -> Void, hostContext: @escaping () -> JSONValue,
                    callTool: @escaping (String, JSONValue) async throws -> JSONValue, readResource: @escaping (String) async throws -> JSONValue,
                    openLink: @escaping (String) async throws -> Void, sendMessage: @escaping (String) async throws -> Void,
                    updateModelContext: @escaping (JSONValue?, JSONValue?) async throws -> Void,
                    onSizeChanged: @escaping (Double?, Double?) -> Void, onRequestTeardown: @escaping () -> Void) {
            self.post = post; self.hostContext = hostContext; self.callTool = callTool; self.readResource = readResource
            self.openLink = openLink; self.sendMessage = sendMessage; self.updateModelContext = updateModelContext
            self.onSizeChanged = onSizeChanged; self.onRequestTeardown = onRequestTeardown
        }
    }

    private let app: McpAppReference
    private let hostVersion: String
    private let callbacks: Callbacks
    private var initialized = false
    private var disposed = false
    private var toolCall: (arguments: JSONValue, result: JSONValue?)?
    private var toolCallSent = false
    private var pending = 0
    private var sentContext: JSONValue?
    private var hostRequests: [String: () -> Void] = [:]
    private var nextHostRequestId = 0

    public init(app: McpAppReference, hostVersion: String, callbacks: Callbacks) {
        self.app = app
        self.hostVersion = hostVersion
        self.callbacks = callbacks
    }

    private func post(_ message: JSONValue) { if !disposed { callbacks.post(message) } }
    private func notify(_ method: String, _ params: JSONValue) {
        post(.object(["jsonrpc": .string("2.0"), "method": .string(method), "params": params]))
    }
    private func respond(_ id: JSONValue, _ result: JSONValue) {
        post(.object(["jsonrpc": .string("2.0"), "id": id, "result": result]))
    }
    private func fail(_ id: JSONValue, _ code: Int, _ message: String) {
        post(.object(["jsonrpc": .string("2.0"), "id": id, "error": .object(["code": .number(Double(code)), "message": .string(message)])]))
    }

    /// `normalizeMcpAppToolResult`: absent fields reported as null would make the SDK drop the message.
    static func normalize(_ result: JSONValue) -> JSONValue {
        var o: [String: JSONValue] = ["content": .array(result["content"]?.arrayValue ?? [])]
        if let s = result["structuredContent"], s.objectValue != nil { o["structuredContent"] = s }
        if result["isError"]?.boolValue == true { o["isError"] = .bool(true) }
        if let m = result["_meta"], m.objectValue != nil { o["_meta"] = m }
        return .object(o)
    }

    private func sendToolCall() {
        guard initialized, let toolCall, !toolCallSent else { return }
        toolCallSent = true
        notify("ui/notifications/tool-input", .object(["arguments": toolCall.arguments.objectValue != nil ? toolCall.arguments : .object([:])]))
        if let result = toolCall.result { notify("ui/notifications/tool-result", Self.normalize(result)) }
    }

    private func answer(_ id: JSONValue, _ run: @escaping () async throws -> JSONValue) {
        guard pending < Self.maxPending else { fail(id, -32000, "Too many requests in flight."); return }
        pending += 1
        Task { [weak self] in
            do {
                let result = try await run()
                self?.pending -= 1
                self?.respond(id, result)
            } catch let refusal as Refusal {
                self?.pending -= 1
                self?.fail(id, -32000, refusal.message)
            } catch {
                self?.pending -= 1
                let message = (error as? LocalizedError)?.errorDescription ?? ""
                self?.fail(id, -32000, message.trimmingCharacters(in: .whitespaces).isEmpty ? "Request failed." : message)
            }
        }
    }

    private func isId(_ v: JSONValue?) -> Bool {
        if case .string = v { return true }
        if case .number(let n) = v { return n.isFinite }
        return false
    }

    /// Handles one message the app posted; the caller has checked its source.
    public func receive(_ data: JSONValue) {
        guard !disposed, data["jsonrpc"]?.stringValue == "2.0" else { return }
        let bytes = (try? JSONEncoder().encode(data).count) ?? Int.max
        guard bytes <= Self.maxMessageBytes else {
            if isId(data["id"]), data["method"]?.stringValue != nil { fail(data["id"]!, -32600, "Message too large.") }
            return
        }
        guard let method = data["method"]?.stringValue else {
            if isId(data["id"]), data["result"] != nil || data["error"] != nil, let key = Self.key(data["id"]!) {
                hostRequests.removeValue(forKey: key)?()
            }
            return
        }
        let params = data["params"]?.objectValue ?? [:]
        if isId(data["id"]) { request(data["id"]!, method, params) } else { notification(method, params) }
    }

    static func key(_ id: JSONValue) -> String? {
        switch id {
        case .string(let s): s
        case .number(let n): n == n.rounded() ? String(Int(n)) : String(n)
        default: nil
        }
    }

    private func request(_ id: JSONValue, _ method: String, _ params: [String: JSONValue]) {
        switch method {
        case "ui/initialize":
            let requested = params["protocolVersion"]?.stringValue
            sentContext = callbacks.hostContext()
            var sandbox: [String: JSONValue] = [:]
            if let csp = app.csp { sandbox["csp"] = csp }
            if !app.permissions.isEmpty { sandbox["permissions"] = .object(Dictionary(uniqueKeysWithValues: app.permissions.map { ($0, JSONValue.object([:])) })) }
            respond(id, .object([
                "protocolVersion": .string(requested == Self.protocolVersion ? requested! : Self.protocolVersion),
                "hostInfo": .object(["name": .string("t3-code"), "version": .string(hostVersion)]),
                "hostCapabilities": .object([
                    "openLinks": .object([:]), "serverTools": .object([:]), "serverResources": .object([:]), "logging": .object([:]),
                    "message": .object(["text": .object([:])]),
                    "updateModelContext": .object(["text": .object([:]), "structuredContent": .object([:])]),
                    "sandbox": .object(sandbox),
                ]),
                "hostContext": sentContext!,
            ]))
        case "ping":
            respond(id, .object([:]))
        case "tools/call":
            let args = params["arguments"] ?? .object([:])
            guard let name = params["name"]?.stringValue, !name.trimmingCharacters(in: .whitespaces).isEmpty, args.objectValue != nil else {
                fail(id, -32602, "tools/call needs a tool name and object arguments.")
                return
            }
            let call = callbacks.callTool
            answer(id) { Self.normalize(try await call(name, args)) }
        case "resources/read":
            guard let uri = params["uri"]?.stringValue, !uri.trimmingCharacters(in: .whitespaces).isEmpty else {
                fail(id, -32602, "resources/read needs a uri.")
                return
            }
            let read = callbacks.readResource
            answer(id) { try await read(uri) }
        case "ui/open-link":
            guard let url = params["url"]?.stringValue, url.range(of: "^https?://", options: [.regularExpression, .caseInsensitive]) != nil else {
                fail(id, -32602, "Only http(s) links can be opened.")
                return
            }
            let open = callbacks.openLink
            answer(id) { try await open(url); return .object([:]) }
        case "ui/message":
            let blocks = params["content"]?.arrayValue ?? [params["content"] ?? .null]
            let texts = blocks.map { b -> String? in b["type"]?.stringValue == "text" ? b["text"]?.stringValue : nil }
            guard params["role"]?.stringValue == "user", !texts.isEmpty, !texts.contains(where: { $0 == nil }) else {
                fail(id, -32602, "Only text messages from the user role are supported.")
                return
            }
            let text = texts.compactMap { $0 }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { fail(id, -32602, "ui/message needs non-empty text."); return }
            let send = callbacks.sendMessage
            answer(id) { try await send(text); return .object([:]) }
        case "ui/request-display-mode":
            // ponytail: inline only; T3 offers full screen through the Popover API. Add it with a full-window host view.
            respond(id, .object(["mode": .string("inline")]))
        case "ui/update-model-context":
            let content = params["content"], structured = params["structuredContent"]
            guard content == nil || content?.arrayValue != nil, structured == nil || structured?.objectValue != nil else {
                fail(id, -32602, "Model context needs content blocks or an object of structured content.")
                return
            }
            let update = callbacks.updateModelContext
            answer(id) { try await update(content, structured); return .object([:]) }
        default:
            // ponytail: no `ui/download-file`; T3 saves through the browser's download. Add it with a save panel.
            fail(id, -32601, "Method not found: \(method)")
        }
    }

    private func notification(_ method: String, _ params: [String: JSONValue]) {
        switch method {
        case "ui/notifications/initialized":
            guard !initialized else { return }
            initialized = true
            sendToolCall()
            updateHostContext()
        case "ui/notifications/size-changed":
            let w = params["width"]?.doubleValue, h = params["height"]?.doubleValue
            if w != nil || h != nil { callbacks.onSizeChanged(w, h) }
        case "ui/notifications/request-teardown":
            callbacks.onRequestTeardown()
        default:
            break
        }
    }

    /// The original tool call's arguments and result; they reach the app once it has initialized, once.
    public func setToolCall(arguments: JSONValue, result: JSONValue?) {
        if toolCall == nil { toolCall = (arguments, result) }
        sendToolCall()
    }

    /// Sends `host-context-changed` with the fields that differ from what the app last saw.
    public func updateHostContext() {
        guard initialized, let sent = sentContext?.objectValue else { return }
        let next = callbacks.hostContext()
        var changes: [String: JSONValue] = [:]
        for (k, v) in next.objectValue ?? [:] where sent[k] != v { changes[k] = v }
        sentContext = next
        if !changes.isEmpty { notify("ui/notifications/host-context-changed", .object(changes)) }
    }

    /// Asks the app to wrap up (`ui/resource-teardown`), then disposes after its answer or 2 s.
    public func teardown() async {
        guard !disposed, initialized else { disposed = true; return }
        let id = "t3-host-\(nextHostRequestId)"
        nextHostRequestId += 1
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            var finished = false
            let finish = { if !finished { finished = true; done.resume() } }
            hostRequests[id] = finish
            post(.object(["jsonrpc": .string("2.0"), "id": .string(id), "method": .string("ui/resource-teardown"), "params": .object([:])]))
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                self?.hostRequests.removeValue(forKey: id)
                finish()
            }
        }
        disposed = true
    }

    public func dispose() { disposed = true }

    /// `mcpAppStyleVariables` (host.ts:534-576): T3's theme variables under the spec's standard names.
    public static func styleVariables(_ theme: [String: String]) -> [String: String] {
        let pairs: [(String, String)] = [
            ("--color-background-primary", "--background"), ("--color-background-secondary", "--card"),
            ("--color-background-tertiary", "--muted"), ("--color-background-inverse", "--foreground"),
            ("--color-background-info", "--info"), ("--color-background-danger", "--destructive-surface"),
            ("--color-background-warning", "--warning-surface"), ("--color-text-primary", "--foreground"),
            ("--color-text-secondary", "--muted-foreground"), ("--color-text-tertiary", "--muted-foreground"),
            ("--color-text-inverse", "--background"), ("--color-text-info", "--info-foreground"),
            ("--color-text-danger", "--destructive-foreground"), ("--color-text-success", "--success-foreground"),
            ("--color-text-warning", "--warning-foreground"), ("--color-border-primary", "--border"),
            ("--color-border-secondary", "--input"), ("--color-border-danger", "--destructive"), ("--color-ring-primary", "--ring"),
            ("--font-sans", "--font-sans"), ("--font-mono", "--font-mono"), ("--border-radius-md", "--radius"),
        ]
        var out: [String: String] = [:]
        for (name, source) in pairs { if let v = theme[source], !v.isEmpty { out[name] = v } }
        return out
    }
}
