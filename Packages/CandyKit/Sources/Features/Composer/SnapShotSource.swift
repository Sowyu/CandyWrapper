import Foundation
import T3Protocol

/// chatAttachment.ts:130-147 and lib/snapShotSource.ts:4-54.
public enum SnapShotSource {
    public static func details(_ source: JSONValue) -> String? {
        if source["accessibility"]?["format"]?.stringValue == "element-tree",
           let tree = source["accessibility"] {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return (try? encoder.encode(tree)).flatMap { String(data: $0, encoding: .utf8) }
        }
        let text = source["accessibility"]?["text"]?.stringValue ?? source["accessibleText"]?.stringValue
        return text?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    public static func resized(_ source: JSONValue, width: Int, height: Int) -> JSONValue {
        guard var result = source.objectValue, var tree = result["accessibility"]?.objectValue,
              tree["format"]?.stringValue == "element-tree",
              let oldWidth = tree["imageSize"]?["width"]?.intValue, oldWidth > 0,
              let oldHeight = tree["imageSize"]?["height"]?.intValue, oldHeight > 0,
              width > 0, height > 0, let root = tree["root"] else { return source }
        func resize(_ value: JSONValue) -> JSONValue {
            guard var node = value.objectValue else { return value }
            if let bounds = node["bounds"], let x = bounds["x"]?.intValue, let y = bounds["y"]?.intValue,
               let w = bounds["width"]?.intValue, let h = bounds["height"]?.intValue {
                func sx(_ n: Int) -> Int { min(width, Int((Double(n) * Double(width) / Double(oldWidth)).rounded())) }
                func sy(_ n: Int) -> Int { min(height, Int((Double(n) * Double(height) / Double(oldHeight)).rounded())) }
                let left = sx(x), top = sy(y), right = sx(x + w), bottom = sy(y + h)
                node["bounds"] = right > left && bottom > top ? .object([
                    "x": .number(Double(left)), "y": .number(Double(top)),
                    "width": .number(Double(right - left)), "height": .number(Double(bottom - top))]) : .null
            }
            node["children"] = .array((node["children"]?.arrayValue ?? []).map(resize))
            return .object(node)
        }
        tree["root"] = resize(root)
        tree["imageSize"] = .object(["width": .number(Double(width)), "height": .number(Double(height))])
        result["accessibility"] = .object(tree)
        return .object(result)
    }
}

private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
