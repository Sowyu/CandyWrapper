import Foundation

// The built-in browser (docs/protocol.md 9.8, packages/contracts/src/preview.ts). The server hosts
// every tab with `runtime: "server"` in its own headless Chrome and streams it to viewers over
// `/api/preview-stream/ws` as JPEG frames plus JSON control messages
// (packages/client-runtime/src/preview/serverBrowserStream.ts). The preview RPCs keep the tab list.

/// `PreviewNavStatus` (preview.ts:150-175).
public enum PreviewNavStatus: Sendable, Equatable, Codable {
    case idle
    case loading(url: String, title: String)
    case success(url: String, title: String)
    /// A page that did not load. `download` is set when the browser saved the address as a file (a PDF).
    case loadFailed(url: String, title: String, code: Int, description: String, download: PreviewFileDownload?)

    public var url: String? {
        switch self {
        case .idle: nil
        case .loading(let url, _), .success(let url, _), .loadFailed(let url, _, _, _, _): url
        }
    }

    public var title: String? {
        switch self {
        case .idle: nil
        case .loading(_, let title), .success(_, let title), .loadFailed(_, let title, _, _, _): title
        }
    }

    public var isIdle: Bool { if case .idle = self { true } else { false } }
    public var isLoading: Bool { if case .loading = self { true } else { false } }
    public var isFailed: Bool { if case .loadFailed = self { true } else { false } }

    private enum Keys: String, CodingKey { case _tag, url, title, code, description, download }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: ._tag) {
        case "Loading": self = .loading(url: try c.decode(String.self, forKey: .url), title: try c.decodeIfPresent(String.self, forKey: .title) ?? "")
        case "Success": self = .success(url: try c.decode(String.self, forKey: .url), title: try c.decodeIfPresent(String.self, forKey: .title) ?? "")
        case "LoadFailed":
            self = .loadFailed(url: try c.decode(String.self, forKey: .url), title: try c.decodeIfPresent(String.self, forKey: .title) ?? "",
                               code: try c.decodeIfPresent(Int.self, forKey: .code) ?? 0,
                               description: try c.decodeIfPresent(String.self, forKey: .description) ?? "",
                               download: try c.decodeIfPresent(PreviewFileDownload.self, forKey: .download))
        default: self = .idle
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .idle: try c.encode("Idle", forKey: ._tag)
        case .loading(let url, let title): try c.encode("Loading", forKey: ._tag); try c.encode(url, forKey: .url); try c.encode(title, forKey: .title)
        case .success(let url, let title): try c.encode("Success", forKey: ._tag); try c.encode(url, forKey: .url); try c.encode(title, forKey: .title)
        case .loadFailed(let url, let title, let code, let description, let download):
            try c.encode("LoadFailed", forKey: ._tag); try c.encode(url, forKey: .url); try c.encode(title, forKey: .title)
            try c.encode(code, forKey: .code); try c.encode(description, forKey: .description)
            try c.encodeIfPresent(download, forKey: .download)
        }
    }
}

public struct PreviewFileDownload: Codable, Sendable, Equatable {
    public var id: String
    public var fileName: String
    public init(id: String, fileName: String) { self.id = id; self.fileName = fileName }
}

/// `PreviewSessionSnapshot` (preview.ts:186-213). The viewport stays raw: only `_tag` matters here.
public struct PreviewSessionSnapshot: Codable, Sendable, Equatable {
    public struct RevealRequest: Codable, Sendable, Equatable {
        public var id: String
        public var force: Bool
    }
    public var threadId: String
    public var tabId: String
    public var navStatus: PreviewNavStatus
    public var canGoBack: Bool
    public var canGoForward: Bool
    public var viewport: JSONValue?
    public var colorScheme: String?
    public var zoomFactor: Double?
    public var profileId: String?
    public var runtime: String?
    public var automationOwner: String?
    public var reveal: Bool?
    public var revealRequest: RevealRequest?
    public var updatedAt: String

    public init(threadId: String, tabId: String, navStatus: PreviewNavStatus = .idle, canGoBack: Bool = false, canGoForward: Bool = false,
                viewport: JSONValue? = nil, colorScheme: String? = nil, zoomFactor: Double? = nil, profileId: String? = nil,
                runtime: String? = "server", reveal: Bool? = nil, updatedAt: String) {
        self.threadId = threadId; self.tabId = tabId; self.navStatus = navStatus; self.canGoBack = canGoBack
        self.canGoForward = canGoForward; self.viewport = viewport; self.colorScheme = colorScheme; self.zoomFactor = zoomFactor
        self.profileId = profileId; self.runtime = runtime; self.reveal = reveal; self.updatedAt = updatedAt
    }

    public var isServerTab: Bool { runtime == "server" }
    /// `viewport._tag !== "fill"`: a fixed device size shows the device toolbar.
    public var hasFixedViewport: Bool { (viewport?["_tag"]?.stringValue ?? "fill") != "fill" }

    /// `surfaceTitle` for a `preview` surface (RightPanelTabs.tsx:604-612).
    public var tabTitle: String {
        guard let url = navStatus.url else { return "Browser" }
        if let title = navStatus.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return title }
        return URLComponents(string: url).flatMap(PreviewURL.hostWithPort) ?? "Browser"
    }
}

/// `PreviewListResult`.
public struct PreviewListResult: Codable, Sendable, Equatable {
    public var sessions: [PreviewSessionSnapshot]
    public var serverEpoch: String
    public var revision: Int
    public init(sessions: [PreviewSessionSnapshot], serverEpoch: String, revision: Int) {
        self.sessions = sessions; self.serverEpoch = serverEpoch; self.revision = revision
    }
}

/// One `subscribePreviewEvents` value (preview.ts:329-390): every thread's tabs on the server.
public struct PreviewEvent: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case opened, navigated, resized, failed, closed }
    public var type: Kind
    public var threadId: String
    public var tabId: String
    public var createdAt: String
    public var serverEpoch: String
    public var revision: Int
    /// opened, navigated and resized.
    public var snapshot: PreviewSessionSnapshot?
    /// failed.
    public var url: String?
    public var title: String?
    public var code: Int?
    public var description: String?
    public var download: PreviewFileDownload?

    public init(type: Kind, threadId: String, tabId: String, createdAt: String = "", serverEpoch: String, revision: Int,
                snapshot: PreviewSessionSnapshot? = nil, url: String? = nil, title: String? = nil, code: Int? = nil, description: String? = nil) {
        self.type = type; self.threadId = threadId; self.tabId = tabId; self.createdAt = createdAt; self.serverEpoch = serverEpoch
        self.revision = revision; self.snapshot = snapshot; self.url = url; self.title = title; self.code = code; self.description = description
    }
}

/// `DiscoveredLocalServer` (preview.ts:393-410): a port listening on the server's machine.
public struct DiscoveredLocalServer: Codable, Sendable, Equatable {
    public struct Terminal: Codable, Sendable, Equatable {
        public var threadId: String
        public var terminalId: String
        public init(threadId: String, terminalId: String) { self.threadId = threadId; self.terminalId = terminalId }
    }
    public var host: String
    public var port: Int
    public var url: String
    public var processName: String?
    public var pid: Int?
    public var terminal: Terminal?

    public init(host: String, port: Int, url: String, processName: String? = nil, pid: Int? = nil) {
        self.host = host; self.port = port; self.url = url; self.processName = processName; self.pid = pid
    }
}

/// `DiscoveredLocalServerList`.
public struct DiscoveredLocalServerList: Codable, Sendable, Equatable {
    public var servers: [DiscoveredLocalServer]
    public var scannedAt: String
    public var configuredUrlProbing: Bool?
    public init(servers: [DiscoveredLocalServer], scannedAt: String = "", configuredUrlProbing: Bool? = nil) {
        self.servers = servers; self.scannedAt = scannedAt; self.configuredUrlProbing = configuredUrlProbing
    }
}

/// Preview RPC names (rpc.ts:439-449, 560-561).
public enum PreviewRPC {
    public static let open = "preview.open"
    public static let navigate = "preview.navigate"
    public static let resize = "preview.resize"
    public static let adjust = "preview.adjust"
    public static let close = "preview.close"
    public static let list = "preview.list"
    public static let events = "subscribePreviewEvents"
    public static let discoveredServers = "subscribeDiscoveredLocalServers"

    /// `PREVIEW_ZOOM_LEVELS`, Chrome's ladder (preview.ts:104-122).
    public static let zoomLevels: [Double] = [0.25, 0.33, 0.5, 0.67, 0.75, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0, 4.0, 5.0]

    /// `stepServerZoom` (PreviewView.tsx:357-376): one rung up or down, 0 resets to 100%. Nil when
    /// nothing changes.
    public static func steppedZoom(from current: Double, direction: Int) -> Double? {
        let next: Double
        if direction == 0 {
            next = 1.0
        } else {
            let index = zoomLevels.firstIndex(of: current) ?? 7
            next = zoomLevels[min(max(index + direction, 0), zoomLevels.count - 1)]
        }
        return next == current ? nil : next
    }

    /// `preview.open` for a new server tab (openPreviewSession.ts:50-56): the configured default viewport
    /// (`browserDefaultOpenViewport`) and profile.
    public static func openPayload(threadId: String, url: String? = nil, profileId: String = "default",
                                   viewport: JSONValue = .object(["_tag": .string("fill")])) -> JSONValue {
        var p: [String: JSONValue] = ["threadId": .string(threadId), "viewport": viewport,
                                      "profileId": .string(profileId), "runtime": .string("server")]
        if let url { p["url"] = .string(url) }
        return .object(p)
    }
}

// MARK: - Address bar

/// URL helpers shared by T3's server and clients (packages/shared/src/preview.ts).
public enum PreviewURL {
    /// `BROWSER_SEARCH_URL_TEMPLATES` (preview.ts:98-106): `%s` takes the encoded query.
    public static let searchTemplates: [String: String] = [
        "duckduckgo": "https://duckduckgo.com/?q=%s", "google": "https://www.google.com/search?q=%s",
        "bing": "https://www.bing.com/search?q=%s", "brave": "https://search.brave.com/search?q=%s",
        "kagi": "https://kagi.com/search?q=%s", "ecosia": "https://www.ecosia.org/search?q=%s",
    ]
    public static let defaultSearchTemplate = "https://duckduckgo.com/?q=%s"
    static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "0.0.0.0", "::1"]
    static let nonWebSchemes: Set<String> = ["about:", "blob:", "chrome:", "data:", "file:", "ftp:", "javascript:", "mailto:",
                                             "sms:", "ssh:", "tel:", "view-source:", "ws:", "wss:"]

    public static func isLoopbackHost(_ host: String) -> Bool { loopbackHosts.contains(host) || host == "[::1]" }

    /// `host` (with its port) of a parsed URL, as `new URL(u).host` gives it.
    static func hostWithPort(_ c: URLComponents) -> String? {
        guard let host = c.host, !host.isEmpty else { return nil }
        let h = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return c.port.map { "\(h):\($0)" } ?? h
    }

    public static func host(of url: String) -> String? { URLComponents(string: url).flatMap(hostWithPort) }

    /// `normalizePreviewUrl`: bare loopback hosts get `http://`, other bare hosts `https://`; only
    /// http and https pass. Nil where T3 throws.
    // ponytail: Foundation's URL parser, not WHATWG's; the server normalizes again, so only the
    // scheme, host case and empty path are fixed up here
    public static func normalize(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let useHttp = trimmed.range(of: #"^(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1?\])(?::|/|$)"#, options: [.regularExpression, .caseInsensitive]) != nil
        let candidate = trimmed.range(of: #"^[a-z][a-z\d+.-]*://"#, options: [.regularExpression, .caseInsensitive]) != nil ? trimmed : "\(useHttp ? "http" : "https")://\(trimmed)"
        guard var c = URLComponents(string: candidate), let scheme = c.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = c.host, !host.isEmpty else { return nil }
        c.scheme = scheme
        c.host = host.lowercased()
        if c.path.isEmpty { c.path = "/" }
        if (scheme == "http" && c.port == 80) || (scheme == "https" && c.port == 443) { c.port = nil }
        return c.string
    }

    /// `fillSearchUrlTemplate` with `encodeURIComponent`.
    static func fillSearchTemplate(_ template: String, _ query: String) -> String {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        allowed.insert(charactersIn: "-_.!~*'()")
        return template.replacingOccurrences(of: "%s", with: query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query)
    }

    /// `isValidSearchUrlTemplate` (preview.ts:113-130): http or https with `%s`, and two queries keep the same
    /// credentials and host, so `%s` can't sit before the path.
    public static func isValidSearchTemplate(_ template: String) -> Bool {
        guard template.contains("%s"), let a = URLComponents(string: fillSearchTemplate(template, "a")),
              let b = URLComponents(string: fillSearchTemplate(template, "b")),
              let scheme = a.scheme?.lowercased(), scheme == "http" || scheme == "https", let host = a.host, !host.isEmpty else { return false }
        func authority(_ c: URLComponents) -> String { "\(c.user ?? ""):\(c.password ?? "")@\(c.host?.lowercased() ?? ""):\(c.port.map(String.init) ?? "")" }
        return authority(a) == authority(b)
    }

    /// `resolveSearchUrlTemplate` (preview.ts:136-145): an unusable custom template searches DuckDuckGo.
    public static func searchTemplate(engine: String?, customURL: String?) -> String {
        if engine != "custom" { return engine.flatMap { searchTemplates[$0] } ?? defaultSearchTemplate }
        let custom = (customURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return isValidSearchTemplate(custom) ? custom : defaultSearchTemplate
    }

    /// `resolveAddressBarInput` (preview.ts:147-185): an address, or a search for the text with the
    /// engine's template. Nil for empty input or an explicit unsupported scheme.
    public static func resolveAddressBarInput(_ rawInput: String, searchTemplate: String = defaultSearchTemplate) -> String? {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.range(of: #"^[a-z][a-z\d+.-]*://"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return normalize(trimmed)
        }
        if trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil {
            let proto = trimmed.range(of: #"^[A-Za-z][A-Za-z\d+.-]*:"#, options: .regularExpression).map { trimmed[$0].lowercased() }
            let bareHostPort = trimmed.range(of: #"^[^/?#:@]+:\d+(?:[/?#]|$)"#, options: .regularExpression) != nil
            if let proto, nonWebSchemes.contains(proto) || !bareHostPort {
                guard proto == "http:" || proto == "https:" else { return nil }
                return normalize(trimmed)
            }
            let authority = String(trimmed.split(whereSeparator: { "/?#".contains($0) }).first ?? "")
            let withoutUser = authority.replacingOccurrences(of: #"^[^@]*@"#, with: "", options: .regularExpression)
            let host = withoutUser.replacingOccurrences(of: #":\d+$"#, with: "", options: .regularExpression)
            let hasPort = host.count < withoutUser.count
            let addressHost = host.range(of: #"^(?:localhost|\d{1,3}(?:\.\d{1,3}){3}|\[[\da-f:.]+\])$"#, options: [.regularExpression, .caseInsensitive]) != nil
            let dotted = host.range(of: #"^[^.]+(?:\.[^.]+)+\.?$"#, options: .regularExpression) != nil
            if hasPort || addressHost || dotted, let url = normalize(trimmed) { return url }
        }
        return fillSearchTemplate(searchTemplate, trimmed)
    }

    /// `PREVIEW_ERROR_CODE_MESSAGES` (previewConstants.ts) through `describePreviewError`.
    public static func describeError(_ description: String) -> String {
        let table = ["ERR_NAME_NOT_RESOLVED": "DNS address could not be found", "ERR_NAME_RESOLUTION_FAILED": "DNS address could not be found",
                     "ERR_CONNECTION_REFUSED": "Connection refused", "ERR_CONNECTION_RESET": "Connection was reset",
                     "ERR_CONNECTION_CLOSED": "Connection was closed", "ERR_CONNECTION_TIMED_OUT": "Connection timed out",
                     "ERR_INTERNET_DISCONNECTED": "No internet connection", "ERR_TIMED_OUT": "Connection timed out",
                     "ERR_CERT_AUTHORITY_INVALID": "Certificate authority is not trusted",
                     "ERR_CERT_COMMON_NAME_INVALID": "Certificate hostname mismatch",
                     "ERR_CERT_DATE_INVALID": "Certificate is expired or not yet valid", "ERR_TOO_MANY_REDIRECTS": "Too many redirects"]
        if let friendly = table[description] { return friendly }
        return description.isEmpty ? "Network error" : description
    }

    /// The unreachable page's code line (PreviewUnreachable.tsx `errorLabel`).
    public static func errorLabel(code: Int, description: String) -> String {
        description.isEmpty ? "ERR_\(abs(code) == 0 ? "FAILED" : String(abs(code)))" : description
    }

    /// `faviconUrlForOrigin(url, 32)`: Google's favicon service for public hosts only.
    public static func faviconURL(for url: String?) -> URL? {
        guard let url, let c = URLComponents(string: url), let scheme = c.scheme, scheme == "http" || scheme == "https",
              let host = c.host?.lowercased(), isPublicFaviconHost(host) else { return nil }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.!~*'()")
        return URL(string: "https://www.google.com/s2/favicons?domain=\(host.addingPercentEncoding(withAllowedCharacters: allowed) ?? host)&sz=32")
    }

    /// `isPublicFaviconHost` (hostClassification.ts:140-180): no loopback, private-network,
    /// reserved-TLD or internal hosts.
    // ponytail: IP literals are never sent, where T3 sends public IPv4 and IPv6 addresses; port
    // its range tables if someone browses by public IP and misses the icon
    static func isPublicFaviconHost(_ raw: String) -> Bool {
        if raw.hasSuffix("..") { return false }
        var host = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        while host.hasSuffix(".") { host.removeLast() }
        if host.contains(":") || isLoopbackHost(host) || !host.contains(".") { return false }
        if host.split(separator: ".").allSatisfy({ Int($0) != nil }) { return false }
        let privateSuffixes = [".localhost", ".local", ".home.arpa", ".ts.net", ".alt", ".corp", ".example", ".home", ".internal",
                               ".intranet", ".invalid", ".lan", ".onion", ".private", ".test"]
        if host == "home.arpa" || privateSuffixes.contains(where: { host.hasSuffix($0) || host == String($0.dropFirst()) }) { return false }
        return !host.split(separator: ".").contains { ["corp", "internal", "intranet"].contains(String($0)) }
    }
}

// MARK: - Stream

/// The viewer WebSocket (`createPreviewStreamClient`, serverBrowserStream.ts).
public enum PreviewStream {
    public static let basePath = "/api/preview-stream"
    /// Sent for every binary frame; the server paces frames on these.
    public static let ack = #"{"type":"ack"}"#
    /// `PREVIEW_STREAM_HOST_SETUP_CLOSE_CODE`.
    public static let hostSetupCloseCode = 4503

    public enum MouseButton: String, Sendable { case none, left, middle, right }

    /// Client-to-server messages. Coordinates are page CSS px.
    public enum Input: Sendable, Equatable {
        case takeControl
        case releaseControl
        case dialog(accept: Bool, promptText: String?)
        case mouse(action: String, x: Double, y: Double, button: MouseButton, buttons: Int, clickCount: Int, modifiers: Int)
        case wheel(x: Double, y: Double, deltaX: Double, deltaY: Double, modifiers: Int)
        case key(action: String, key: String, code: String, keyCode: Int?, text: String?, modifiers: Int)
        case text(String)
        case resize(width: Int, height: Int)
        case navigate(url: String)
        case history(delta: Int)
        case reload(ignoreCache: Bool)

        public var json: JSONValue {
            switch self {
            case .takeControl: return .object(["type": .string("takeControl")])
            case .releaseControl: return .object(["type": .string("releaseControl")])
            case .dialog(let accept, let promptText):
                var o: [String: JSONValue] = ["type": .string("dialog"), "accept": .bool(accept)]
                if let promptText { o["promptText"] = .string(promptText) }
                return .object(o)
            case .mouse(let action, let x, let y, let button, let buttons, let clickCount, let modifiers):
                return .object(["type": .string("mouse"), "action": .string(action), "x": .number(x), "y": .number(y),
                                "button": .string(button.rawValue), "buttons": .number(Double(buttons)),
                                "clickCount": .number(Double(clickCount)), "modifiers": .number(Double(modifiers))])
            case .wheel(let x, let y, let dx, let dy, let modifiers):
                return .object(["type": .string("wheel"), "x": .number(x), "y": .number(y), "deltaX": .number(dx),
                                "deltaY": .number(dy), "modifiers": .number(Double(modifiers))])
            case .key(let action, let key, let code, let keyCode, let text, let modifiers):
                var o: [String: JSONValue] = ["type": .string("key"), "action": .string(action), "key": .string(key),
                                              "code": .string(code), "modifiers": .number(Double(modifiers))]
                if let keyCode { o["keyCode"] = .number(Double(keyCode)) }
                if let text { o["text"] = .string(text) }
                return .object(o)
            case .text(let text): return .object(["type": .string("text"), "text": .string(text)])
            case .resize(let w, let h): return .object(["type": .string("resize"), "width": .number(Double(w)), "height": .number(Double(h))])
            case .navigate(let url): return .object(["type": .string("navigate"), "url": .string(url)])
            case .history(let delta): return .object(["type": .string("history"), "delta": .number(Double(delta))])
            case .reload(let ignoreCache):
                return ignoreCache ? .object(["type": .string("reload"), "ignoreCache": .bool(true)]) : .object(["type": .string("reload")])
            }
        }

        public var encoded: String {
            let data = (try? JSONEncoder().encode(json)) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }

        public var isTakeControl: Bool { if case .takeControl = self { true } else { false } }
    }

    /// `PreviewStreamControl`.
    public struct Control: Sendable, Equatable {
        public enum Controller: String, Sendable { case agent, you, anotherViewer = "another-viewer", unclaimed }
        public struct Dialog: Sendable, Equatable {
            public var type: String
            public var message: String
            public var defaultValue: String
        }
        public var canOperate: Bool
        public var controller: Controller
        public var generation: Int
        public var dialog: Dialog?
        public init(canOperate: Bool, controller: Controller, generation: Int = 0, dialog: Dialog? = nil) {
            self.canOperate = canOperate; self.controller = controller; self.generation = generation; self.dialog = dialog
        }

        /// `previewStreamControlLabel`; nil control means the socket is not connected.
        public static func label(_ control: Control?) -> String {
            guard let control else { return "Connecting..." }
            if !control.canOperate { return "Read-only" }
            switch control.controller {
            case .you: return "You have control"
            case .agent: return "Agent has control"
            case .anotherViewer: return "Another viewer has control"
            case .unclaimed: return "Watching"
            }
        }
    }

    /// Server-to-client JSON messages.
    public enum Message: Sendable, Equatable {
        case viewport(width: Double, height: Double)
        case control(Control)
        case clipboard(String)
        case download(id: String, fileName: String, sizeBytes: Double)
        case fileChooser(id: String, multiple: Bool, accept: String)
        case fileChooserClosed(id: String)
        case popup(tabId: String)
        case pointer(phase: String, x: Double, y: Double, sequence: Int)
        case probe(x: Double, y: Double, editable: Bool)

        /// The checks of the reference client's message listener; anything else is ignored.
        public static func decode(_ text: String) -> Message? {
            guard let data = text.data(using: .utf8), let value = try? JSONDecoder().decode(JSONValue.self, from: data),
                  case .object(let o) = value, let type = o["type"]?.stringValue else { return nil }
            func num(_ k: String) -> Double? { if case .number(let n)? = o[k] { n } else { nil } }
            func bool(_ k: String) -> Bool? { if case .bool(let b)? = o[k] { b } else { nil } }
            func str(_ k: String) -> String? { o[k]?.stringValue }
            switch type {
            case "fileChooser":
                guard let id = str("id"), let multiple = bool("multiple"), let accept = str("accept") else { return nil }
                return .fileChooser(id: id, multiple: multiple, accept: accept)
            case "fileChooserClosed":
                return str("id").map { .fileChooserClosed(id: $0) }
            case "pointer":
                guard let phase = str("phase"), phase == "move" || phase == "click", let x = num("x"), let y = num("y"),
                      let sequence = o["sequence"]?.intValue else { return nil }
                return .pointer(phase: phase, x: x, y: y, sequence: sequence)
            case "popup": return str("tabId").map { .popup(tabId: $0) }
            case "clipboard": return str("text").map { .clipboard($0) }
            case "download":
                guard let id = str("id"), let name = str("fileName"), let size = num("sizeBytes") else { return nil }
                return .download(id: id, fileName: name, sizeBytes: size)
            case "viewport":
                guard let w = num("width"), let h = num("height") else { return nil }
                return .viewport(width: w, height: h)
            case "probe":
                guard let x = num("x"), let y = num("y"), let editable = bool("editable") else { return nil }
                return .probe(x: x, y: y, editable: editable)
            case "control":
                guard let canOperate = bool("canOperate"), let raw = str("controller"), let controller = Control.Controller(rawValue: raw),
                      let generation = o["generation"]?.intValue else { return nil }
                var dialog: Control.Dialog?
                switch o["dialog"] {
                case .none, .null?: dialog = nil
                case .object(let d)?:
                    guard let t = d["type"]?.stringValue, let m = d["message"]?.stringValue, let v = d["defaultValue"]?.stringValue else { return nil }
                    dialog = Control.Dialog(type: t, message: m, defaultValue: v)
                default: return nil
                }
                return .control(Control(canOperate: canOperate, controller: controller, generation: generation, dialog: dialog))
            default: return nil
            }
        }
    }

    /// `PreviewStreamHostSetup`: the server's browser cannot start until its host allows it.
    public struct HostSetup: Sendable, Equatable {
        public var need: String
        public var command: String

        /// `decodeHostSetup`: a malformed reason still stops the viewer with the usual command.
        public static func decode(_ reason: String) -> HostSetup {
            if let data = reason.data(using: .utf8), let v = try? JSONDecoder().decode(JSONValue.self, from: data),
               let need = v["need"]?.stringValue, need == "sandbox" || need == "libraries", let command = v["command"]?.stringValue {
                return HostSetup(need: need, command: command)
            }
            return HostSetup(need: "sandbox", command: "sudo npx t3 browser setup")
        }

        /// `previewStreamHostSetupMessage`.
        public var message: String {
            need == "sandbox"
                ? "This server's host blocks the sandbox its browser runs in. Run this once on the host, then try again:"
                : "This server's host is missing libraries its browser needs. Run this once on the host, then try again:"
        }
    }

    /// What a closed socket means (the reference client's close listener).
    public enum CloseOutcome: Sendable, Equatable {
        /// 4404: the tab closed on the server.
        case gone
        case hostSetup(HostSetup)
        /// A refused upgrade (1008, 4401, or 1006 before open): fetch a new ticket.
        case unauthorized
        /// Anything else: reconnect after `min(500 * 2^failures, 10000)` ms.
        case retry
    }

    public static func closeOutcome(code: Int, reason: String, opened: Bool) -> CloseOutcome {
        if code == 4404 { return .gone }
        if code == hostSetupCloseCode { return .hostSetup(HostSetup.decode(reason)) }
        if code == 1008 || code == 4401 || (!opened && code == 1006) { return .unauthorized }
        return .retry
    }

    public static func retryDelay(failures: Int) -> Duration { .milliseconds(min(500 * (1 << min(failures, 10)), 10_000)) }

    /// `previewStreamModifiers`: Alt 1, Ctrl 2, Meta 4, Shift 8.
    public static func modifiers(alt: Bool, control: Bool, command: Bool, shift: Bool) -> Int {
        (alt ? 1 : 0) | (control ? 2 : 0) | (command ? 4 : 0) | (shift ? 8 : 0)
    }

    /// `ws(s)://<env>/api/preview-stream/ws?threadId&tabId&maxWidth&maxHeight&wsTicket`.
    public static func socketURL(base: URL, threadId: String, tabId: String, maxWidth: Int, maxHeight: Int, ticket: String?) -> URL? {
        guard var c = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        c.scheme = c.scheme == "https" ? "wss" : "ws"
        c.path = (c.path.hasSuffix("/") ? String(c.path.dropLast()) : c.path) + basePath + "/ws"
        c.queryItems = [URLQueryItem(name: "threadId", value: threadId), URLQueryItem(name: "tabId", value: tabId),
                        URLQueryItem(name: "maxWidth", value: String(max(1, maxWidth))),
                        URLQueryItem(name: "maxHeight", value: String(max(1, maxHeight)))]
            + (ticket.map { [URLQueryItem(name: "wsTicket", value: $0)] } ?? [])
        return c.url
    }

    /// `previewStreamDownloadUrl` and the upload route: HTTP with the same ticket.
    public static func httpURL(base: URL, route: String, query: [(String, String)], ticket: String?) -> URL? {
        guard var c = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        c.path = (c.path.hasSuffix("/") ? String(c.path.dropLast()) : c.path) + basePath + "/" + route
        c.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) } + (ticket.map { [URLQueryItem(name: "wsTicket", value: $0)] } ?? [])
        return c.url
    }
}

// MARK: - Content search

/// `projects.searchContents` (project.ts:278-310).
public struct ProjectContentMatch: Codable, Sendable, Equatable {
    public struct Range: Codable, Sendable, Equatable {
        public var start: Int
        public var end: Int
        public init(start: Int, end: Int) { self.start = start; self.end = end }
    }
    public var path: String
    public var lineNumber: Int
    public var lineContent: String
    public var matchRanges: [Range]
    public init(path: String, lineNumber: Int, lineContent: String, matchRanges: [Range]) {
        self.path = path; self.lineNumber = lineNumber; self.lineContent = lineContent; self.matchRanges = matchRanges
    }

    /// `normalizeRanges` (HighlightedSearchLine.tsx): clamped, sorted, merged UTF-16 ranges.
    public var normalizedRanges: [Range] {
        let length = (lineContent as NSString).length
        let sorted = matchRanges.map { Range(start: max(0, min(length, $0.start)), end: max(0, min(length, $0.end))) }
            .filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        var merged: [Range] = []
        for r in sorted {
            if let last = merged.last, r.start <= last.end { merged[merged.count - 1].end = max(last.end, r.end) } else { merged.append(r) }
        }
        return merged
    }
}

public struct ProjectContentSearchResult: Codable, Sendable, Equatable {
    public var matches: [ProjectContentMatch]
    public var truncated: Bool
    public var regexFallbackError: String?
    public init(matches: [ProjectContentMatch], truncated: Bool, regexFallbackError: String? = nil) {
        self.matches = matches; self.truncated = truncated; self.regexFallbackError = regexFallbackError
    }

    /// `PROJECT_CONTENT_SEARCH_LIMIT` and the debounce (queries.ts:37-38).
    public static let limit = 500
    public static let debounce: Duration = .milliseconds(120)

    public static func payload(cwd: String, query: String, caseSensitive: Bool, wholeWord: Bool, useRegex: Bool) -> JSONValue {
        .object(["cwd": .string(cwd), "query": .string(String(query.prefix(256))), "limit": .number(Double(limit)),
                 "caseSensitive": .bool(caseSensitive), "wholeWord": .bool(wholeWord), "useRegex": .bool(useRegex)])
    }
}
