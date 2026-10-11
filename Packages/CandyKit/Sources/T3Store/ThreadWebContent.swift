import Foundation
import T3Protocol

// Agent web content in the timeline: HTML renders (`html_render`, packages/shared/src/htmlRender.ts) and MCP
// Apps (packages/shared/src/mcpApp.ts), read from a completed `dynamic_tool` item's compact output
// (packages/shared/src/toolOutput.ts). The app hosts them in a sandboxed web view.

/// `HtmlRenderReference` (htmlRender.ts:22-32).
public struct HtmlRenderReference: Sendable, Hashable {
    public let attachmentId: String
    public let title: String
    /// The agent's frame height in CSS pixels, and the cap on any measured height.
    public let height: Double
    /// `[width, contentHeight]` the server measured at publish, ascending by width.
    public let heights: [[Double]]?

    public static let minHeight: Double = 80
    public static let maxHeight: Double = 2000
    /// The reply column's frame width at the default chat width.
    public static let columnWidth: Double = 728

    public init(attachmentId: String, title: String, height: Double, heights: [[Double]]? = nil) {
        self.attachmentId = attachmentId; self.title = title; self.height = height; self.heights = heights
    }

    /// `readHtmlRenderReference` (:65-85).
    public init?(_ json: JSONValue?) {
        guard let o = json?.objectValue, let id = o["attachmentId"]?.stringValue, !id.isEmpty, id.count <= 256,
              let title = o["title"]?.stringValue, let h = o["height"]?.doubleValue, h.isFinite else { return nil }
        var measured: [[Double]]?
        if let list = o["heights"]?.arrayValue, !list.isEmpty, list.count <= 24 {
            let pairs: [[Double]] = list.compactMap { e in
                guard let a = e.arrayValue, a.count == 2, let w = a[0].doubleValue, w == w.rounded(), w >= 1, w <= 10_000,
                      let ch = a[1].doubleValue, ch.isFinite else { return nil }
                return [w, Self.clamp(ch)]
            }
            if pairs.count == list.count { measured = pairs.sorted { $0[0] < $1[0] } }
        }
        let trimmed = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        self.init(attachmentId: id, title: trimmed.isEmpty ? "HTML" : trimmed, height: Self.clamp(h), heights: measured)
    }

    /// `clampHtmlRenderHeight` (:145-147).
    public static func clamp(_ h: Double) -> Double { min(maxHeight, max(minHeight, h.rounded())) }

    /// The taller of the heights measured at the nearest widths on each side (:103-108).
    static func measured(_ heights: [[Double]], _ width: Double) -> Double {
        let above = heights.firstIndex { $0[0] >= width }
        let high = above ?? heights.count - 1
        let low = heights[high][0] == width ? high : max(0, high - 1)
        return max(heights[low][1], heights[high][1])
    }

    /// `htmlRenderFrameHeight` (:118-132): the page's reported height, else the server's measurement for this
    /// width; the agent's height caps it only when it asked for a scrolling frame or nothing was measured.
    public func frameHeight(width: Double, contentHeight: Double? = nil) -> Double {
        guard let heights, !heights.isEmpty else { return Self.clamp(min(height, contentHeight ?? height)) }
        let cap = Self.measured(heights, Self.columnWidth) > height ? height : Self.maxHeight
        return Self.clamp(min(cap, contentHeight ?? Self.measured(heights, width)))
    }

    /// `htmlRenderFileName` (:135-143).
    public var fileName: String {
        let name = title.replacing(/[\\\/:*?"<>|\p{Cc}]+/, with: " ").replacing(/\s+/, with: " ")
            .trimmingCharacters(in: .whitespaces)
        let cut = String(name.prefix(120)).trimmingCharacters(in: .whitespaces)
        return (cut.isEmpty ? "Page" : cut) + ".html"
    }
}

/// `McpAppReference` (mcpApp.ts:47-56).
public struct McpAppReference: Sendable, Hashable {
    public let attachmentId: String
    public let server: String
    public let tool: String
    public let resourceUri: String
    public let csp: JSONValue?
    public let permissions: Set<String>
    public let prefersBorder: Bool?

    public static let defaultHeight: Double = 320
    public static let maxHeight: Double = 2000

    /// `readMcpAppReference` (:117-143).
    public init?(_ json: JSONValue?) {
        func bounded(_ v: JSONValue?) -> String? {
            guard let s = v?.stringValue, !s.trimmingCharacters(in: .whitespaces).isEmpty, s.count <= 256 else { return nil }
            return s
        }
        guard let o = json?.objectValue, let id = bounded(o["attachmentId"]), let server = bounded(o["server"]),
              let tool = bounded(o["tool"]), let uri = o["resourceUri"]?.stringValue, uri.count <= 4096, uri.hasPrefix("ui://")
        else { return nil }
        attachmentId = id; self.server = server; self.tool = tool; resourceUri = uri
        csp = o["csp"]?.objectValue == nil ? nil : o["csp"]
        let p = o["permissions"]?.objectValue ?? [:]
        permissions = Set(["camera", "microphone", "geolocation", "clipboardWrite"].filter { p[$0]?.objectValue != nil })
        prefersBorder = o["prefersBorder"]?.boolValue
    }

    /// `clampMcpAppHeight` (:227-230).
    public static func clamp(_ h: Double) -> Double { h.isFinite ? min(maxHeight, max(80, h.rounded())) : defaultHeight }

    /// `mcpAppAllowAttribute` (:219-225).
    public var allowAttribute: String {
        [("camera", "camera"), ("microphone", "microphone"), ("geolocation", "geolocation"), ("clipboardWrite", "clipboard-write")]
            .filter { permissions.contains($0.0) }.map(\.1).joined(separator: "; ")
    }

    /// `mcpAppFileName` (:232-235).
    public var fileName: String {
        let name = String(tool.replacing(/[^\w.-]+/, with: "-").prefix(80))
        return (name.isEmpty ? "app" : name) + ".html"
    }
}

/// An MCP App row's identity (MessagesTimeline.logic.ts:641-648).
public struct McpAppEntry: Sendable, Hashable {
    public let app: McpAppReference
    public let sourceThreadId: ThreadId
    public let itemId: TurnItemId
    /// `turnItemDetailRevision`: the stored call is fetched once per version.
    public let revision: String
}

public enum ThreadWebContent {
    /// `compactDynamicToolOutput`'s envelope read (toolOutput.ts:48-101): JSON text parses, content blocks give
    /// their first data, `structuredContent` or `content` nests; a failure flag rides along.
    static func readResult(_ value: JSONValue?, depth: Int = 0, budget: inout Int) -> (data: [String: JSONValue]?, failed: Bool) {
        budget -= 1
        guard depth <= 4, budget >= 0, let value else { return (nil, false) }
        switch value {
        case .string(let s):
            guard s.utf8.count <= 16_384, let parsed = try? JSONValue(parsing: Data(s.utf8)) else { return (nil, false) }
            return readResult(parsed, depth: depth + 1, budget: &budget)
        case .array(let blocks):
            guard blocks.count <= 32 else { return (nil, false) }
            var data: [String: JSONValue]?
            var failed = false
            for b in blocks {
                let text = b["text"]
                let r = readResult(text?["text"] ?? text, depth: depth + 1, budget: &budget)
                data = data ?? r.data
                failed = failed || r.failed
            }
            return (data, failed)
        case .object(let o):
            let failed = o["isError"]?.boolValue == true || o["is_error"]?.boolValue == true
                || o["_tag"]?.stringValue == "OrchestratorMcpFailure" || (o["error"] != nil && o["error"] != .null)
            if let content = o["structuredContent"] ?? o["content"] {
                let nested = readResult(content, depth: depth + 1, budget: &budget)
                return (nested.data, failed || nested.failed)
            }
            return (o, failed)
        default:
            return (nil, false)
        }
    }

    static func compactOutput(_ output: JSONValue?) -> (data: [String: JSONValue]?, failed: Bool) {
        var budget = 128
        return readResult(output, budget: &budget)
    }

    /// `htmlRenderFromToolItem` (toolOutput.ts:186-193): T3's own `html_render` tool, not failed.
    public static func htmlRender(_ item: TurnItem) -> HtmlRenderReference? {
        guard item.type == .dynamicTool, item.status == .completed,
              T3McpTools.toolName(item.string("toolName") ?? "") == "html_render" else { return nil }
        let out = compactOutput(item["output"])
        return out.failed ? nil : HtmlRenderReference(out.data?["htmlRender"])
    }

    /// `mcpAppFromToolItem` (toolOutput.ts:202-208): the reference counts only when it names the server and tool
    /// the item records.
    public static func mcpApp(_ item: TurnItem) -> McpAppReference? {
        guard item.type == .dynamicTool, item.status == .completed,
              let app = McpAppReference(compactOutput(item["output"]).data?["t3McpApp"]),
              item.string("toolName") == "\(app.server).\(app.tool)" else { return nil }
        return app
    }
}
