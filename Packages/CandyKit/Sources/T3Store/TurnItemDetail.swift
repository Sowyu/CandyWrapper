import Foundation
import T3Protocol

/// Tool output the thread stream leaves out, fetched with `orchestration.getTurnItem`
/// (client-runtime/src/work-log/itemDetail.ts:124-205). T3 fetches only while a row is open
/// (V2ItemInspector.tsx:103-137) and keeps a result 60 s after the last row lets go of it
/// (client-runtime/src/state/orchestration.ts:47-53).
public enum TurnItemDetail {
    /// `turnItemNeedsDetailFetch` (itemDetail.ts:140-149): the server set `outputOmitted`, or cut a
    /// dynamic tool's input down to `{summary, truncated: true}`.
    public static func needsFetch(_ item: TurnItem) -> Bool {
        switch item.type {
        case .commandExecution: item.outputOmitted
        case .dynamicTool: item.outputOmitted || isSummarized(item.input)
        default: false
        }
    }

    /// `turnItemDetailRevision` (itemDetail.ts:124-137): one key while the item runs, so an open
    /// row fetches once while it streams and again when it settles.
    public static func revision(_ item: TurnItem) -> String {
        [.idle, .pending, .running, .waiting].contains(item.status) ? "live" : item.updatedAt.raw
    }

    /// The request for a projected row: the source thread and item, which differ from the row's
    /// own ids for inherited rows (V2ItemInspector.tsx:109-117).
    public static func request(_ row: ProjectedTurnItem) -> GetTurnItemInput {
        GetTurnItemInput(threadId: row.sourceThreadId, itemId: row.sourceItemId, revision: revision(row.item))
    }

    /// What a fetch resolves to, ready to draw.
    public enum Fetched: Hashable, Sendable {
        /// The fetched item's output text, nil when it has none ("No output." unless it has images),
        /// and how many images its output holds (`turnItemOutputImages`).
        case output(String?, images: Int = 0)
        /// `item: null`: "Output is no longer available." (V2ItemInspector.tsx:131-132).
        case gone
        /// The fetched item has another type; T3 keeps the wire item and shows nothing more (:120).
        case mismatch
    }

    /// Lines kept of a fetched output. The detail box clips each block at 320 px (about 15 lines),
    /// so the rest would only cost memory and layout time.
    // ponytail: keeps the first 200 lines / 16 KiB; keep the whole text once the detail box scrolls
    public static let keptLines = 200
    public static let keptBytes = 16 * 1024

    /// Turns a `getTurnItem` result into what the row shows. Runs off the main thread.
    public static func resolve(_ result: GetTurnItemResult, wireType: TurnItemType) -> Fetched {
        guard let item = result.item else { return .gone }
        guard item.type == wireType else { return .mismatch }
        return .output(outputText(item).map(prefix), images: outputImageCount(item))
    }

    /// `turnItemOutputImages` (itemDetail.ts:207-221): the images of a dynamic tool's output, which load
    /// by index as `tool-output-image` assets.
    public static func outputImageCount(_ item: TurnItem) -> Int {
        guard item.type == .dynamicTool, !item.outputOmitted, let output = item.output else { return 0 }
        return toolOutputImageCount(output)
    }

    /// `toolOutputImages` (packages/shared/src/toolOutput.ts:256-293): the readable images of a block, a
    /// list of blocks or an MCP result's `content`, at most 8. The order is the asset index.
    static func toolOutputImageCount(_ value: JSONValue) -> Int {
        let blocks: [JSONValue] = value.arrayValue ?? value["content"]?.arrayValue ?? [value]
        return min(maxToolOutputImages, blocks.filter { readableImageMimeType($0) != nil }.count)
    }

    /// `readToolOutputImage` (toolOutput.ts:236-247): an MCP `{data, mimeType}` or Anthropic
    /// `{source: {type: "base64", media_type}}` image of a raster type a provider turn accepts
    /// (`PROVIDER_SEND_TURN_SUPPORTED_IMAGE_MIME_TYPES`, contracts/src/chatAttachment.ts:18-23).
    static func readableImageMimeType(_ block: JSONValue) -> String? {
        guard case .object(let o) = block, o["type"]?.stringValue == "image" else { return nil }
        let source: [String: JSONValue]?
        switch o["source"] {
        case .object(let s)?: source = s
        default: source = nil
        }
        if let source, source["type"]?.stringValue != "base64" { return nil }
        guard let mime = (source == nil ? o["mimeType"] : source?["media_type"])?.stringValue?.lowercased(),
              ["image/gif", "image/jpeg", "image/png", "image/webp"].contains(mime) else { return nil }
        return mime
    }

    static func prefix(_ text: String) -> String {
        var end = text.startIndex, lines = 0
        let byteCap = text.utf8.index(text.startIndex, offsetBy: keptBytes, limitedBy: text.endIndex) ?? text.endIndex
        while end < byteCap, lines < keptLines {
            if text[end] == "\n" { lines += 1 }
            end = text.index(after: end)
        }
        return end == text.endIndex ? text : String(text[..<end])
    }

    /// `turnItemOutputText` for the two fetched types (itemDetail.ts:168-174).
    public static func outputText(_ item: TurnItem) -> String? {
        switch item.type {
        case .commandExecution:
            guard let out = item.output?.stringValue,
                  !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let text = commandOutputText(out)
            return text.isEmpty ? nil : text
        case .dynamicTool:
            return item.outputOmitted ? nil : formatToolValue(item.output)
        default:
            return nil
        }
    }

    /// Older Claude bash rows stored the raw `{stdout, stderr, interrupted}` result (itemDetail.ts:151-166).
    static func commandOutputText(_ output: String) -> String {
        guard output.drop(while: \.isWhitespace).hasPrefix("{\"stdout\""),
              let data = output.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stdout = o["stdout"] as? String, let stderr = o["stderr"] as? String,
              o["interrupted"] is Bool else { return output }
        return [stdout, stderr].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n")
    }

    static func isSummarized(_ value: JSONValue?) -> Bool {
        value?["truncated"]?.boolValue == true && value?["summary"]?.stringValue != nil
    }

    /// `formatToolValue` (itemDetail.ts:68-80): text blocks as text, everything else as JSON.
    // ponytail: JSON keys come out sorted (JSONValue drops key order) and minified JSON text is not re-indented; port prettyJsonText if MCP output reads badly
    static func formatToolValue(_ value: JSONValue?) -> String? {
        guard let value, value != .null else { return nil }
        var previews = maxToolOutputImages
        if let text = textFromBlocks(value, depth: 0, level: .root, previews: &previews) {
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
        }
        if value == .object([:]) || value == .array([]) { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// `MAX_TOOL_OUTPUT_IMAGES` (toolOutput.ts:237).
    static let maxToolOutputImages = 8

    /// Where a value sits against `outputBlocks` (toolOutput.ts:230-234): the value itself, one of its output
    /// blocks, or deeper. Only output blocks can be previewed images.
    enum BlockLevel { case root, block, nested }

    /// `textFromBlocks` (itemDetail.ts:15-45). The first 8 readable images among the output blocks draw on their
    /// own as assets, so they leave no text; the rest show as "[image]" (f05599504a).
    static func textFromBlocks(_ value: JSONValue, depth: Int, level: BlockLevel = .nested, previews: inout Int) -> String? {
        guard depth <= 4 else { return nil }
        switch value {
        case .string(let s): return s
        case .array(let blocks):
            var parts: [String] = []
            for b in blocks {
                guard let p = textFromBlocks(b, depth: depth + 1, level: level == .root ? .block : .nested, previews: &previews) else { return nil }
                if !p.isEmpty { parts.append(p) }
            }
            return parts.joined(separator: "\n")
        case .object(let o):
            let type = o["type"]?.stringValue
            if type == "text", let t = o["text"]?.stringValue { return t }
            if type == "image" {
                guard level != .nested, previews > 0, readableImageMimeType(value) != nil else { return "[image]" }
                previews -= 1
                return ""
            }
            if type == "resource_link", let uri = o["uri"]?.stringValue { return uri }
            if type == "resource", case .object(let r)? = o["resource"] {
                if let t = r["text"]?.stringValue { return t }
                if let uri = r["uri"]?.stringValue { return uri }
            }
            let keys = Set(o.keys).subtracting(["isError", "is_error"])
            // A root's `content` list holds its output blocks.
            let contentLevel: BlockLevel = level == .root && o["content"]?.arrayValue != nil ? .root : .nested
            if keys == ["content"], let c = o["content"] { return textFromBlocks(c, depth: depth + 1, level: contentLevel, previews: &previews) }
            if keys == ["content", "structuredContent"], let c = o["content"] {
                let t = textFromBlocks(c, depth: depth + 1, level: contentLevel, previews: &previews)
                return t.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } == false ? t : nil
            }
            return nil
        default: return nil
        }
    }
}

/// One image of a tool's output, addressed as T3's `tool-output-image` asset (contracts/src/assets.ts:44-50).
/// The server reads the bytes from the stored item by index and signs a URL for them (AssetAccess.ts:710-728).
public struct ToolOutputImage: Hashable, Sendable {
    public var threadId: ThreadId
    public var itemId: TurnItemId
    public var index: Int
    public init(threadId: ThreadId, itemId: TurnItemId, index: Int) {
        self.threadId = threadId; self.itemId = itemId; self.index = index
    }

    /// The `assets.createUrl` resource.
    public var resource: JSONValue {
        .object(["_tag": .string("tool-output-image"), "threadId": .string(threadId.rawValue),
                 "itemId": .string(itemId.rawValue), "index": .number(Double(index))])
    }

    /// The image's identity, for the size cache and the decoded image's key.
    public var key: String { "tool-output-image:\(threadId.rawValue):\(itemId.rawValue):\(index)" }

    public static func list(threadId: ThreadId, itemId: TurnItemId, count: Int) -> [ToolOutputImage] {
        (0..<count).map { ToolOutputImage(threadId: threadId, itemId: itemId, index: $0) }
    }
}
