import Foundation

/// Restores only the record slots defined by upstream 5b35402623,
/// packages/contracts/src/orchestrationV2IdTable.ts:60-90. Nested provider payloads,
/// lineage, model options and tool input/output are deliberately opaque.
enum ThreadPayloadRestoration {
    static func expandIds(_ raw: JSONValue, container: String?) throws -> JSONValue {
        guard case .object(var root) = raw, let table = root.removeValue(forKey: "ids") else { return raw }
        guard case .array(let ids) = table, ids.allSatisfy({
            switch $0 { case .string, .number: true; default: false }
        }) else { throw invalid("Invalid thread ID table") }
        func reference(_ value: JSONValue) throws -> JSONValue {
            guard case .number(let number) = value else { return value }
            guard number.isFinite, number >= 0, number.rounded() == number, number < Double(ids.count) else {
                throw invalid("Invalid thread ID table reference")
            }
            return ids[Int(number)]
        }
        func record(_ value: JSONValue) throws -> JSONValue {
            guard case .object(var fields) = value else { return value }
            for (key, value) in fields {
                if key == "id" || key.hasSuffix("Id") {
                    fields[key] = try reference(value)
                } else if key.hasSuffix("Ids"), case .array(let values) = value {
                    fields[key] = .array(try values.map(reference))
                } else if key == "item", case .object = value {
                    fields[key] = try record(value)
                }
            }
            return .object(fields)
        }
        func records(_ value: JSONValue) throws -> JSONValue {
            guard case .object(var fields) = value else { throw invalid("Missing thread ID table container") }
            for (key, value) in fields {
                switch value {
                case .array(let values): fields[key] = .array(try values.map(record))
                case .object: fields[key] = try record(value)
                default: break
                }
            }
            return .object(fields)
        }
        if let container {
            guard let value = root[container] else { throw invalid("Missing thread ID table container") }
            root[container] = try records(value)
            return .object(root)
        }
        return try records(.object(root))
    }

    static func snapshot(_ raw: JSONValue) throws -> JSONValue {
        let expanded = try expandIds(raw, container: "projection")
        guard case .object(var root) = expanded, case .object(var projection) = root["projection"] else { return expanded }
        for key in ["messages", "checkpoints", "subagents"] {
            if case .array(let records) = projection[key] {
                for record in records { try rejectOmittedBodies(record) }
            }
        }
        let sources = ThreadBodySources(projection: .object(projection))
        if case .array(let items) = projection["turnItems"] {
            projection["turnItems"] = .array(try items.map { try sources.restoreItem($0) })
        }
        if case .array(let rows) = projection["visibleTurnItems"] {
            projection["visibleTurnItems"] = .array(try rows.map { row in
                guard case .object(var fields) = row, let item = fields["item"] else { return row }
                if fields["visibility"] == .string("local") || fields["sourceThreadId"] == projection["thread"]?["id"] {
                    fields["item"] = try sources.restoreItem(item)
                } else {
                    try rejectOmittedBodies(item)
                }
                return .object(fields)
            })
        }
        root["projection"] = .object(projection)
        return .object(root)
    }

    static func rejectOmittedBodies(_ value: JSONValue) throws {
        for key in ["textOmitted", "filesOmitted", "promptOmitted", "resultOmitted"] where value[key] == .bool(true) {
            throw invalid("Unrestored thread body: \(key)")
        }
    }

    static func invalid(_ message: String) -> DecodingError {
        .dataCorrupted(.init(codingPath: [], debugDescription: message))
    }
}

/// Body records follow transport arrival order, independently of reducer sequence deduplication
/// and partial-window filtering. Upstream: shared/orchestrationV2DedupedBodies.ts:20-119 and
/// apps/server/src/orchestration-v2/WireProjection.ts:265-309 at 5b35402623.
private struct ThreadBodyMemory: Sendable {
    var values: [String: JSONValue] = [:]
    var order: [String] = []
    let limit: Int?

    subscript(_ id: String) -> JSONValue? {
        get { values[id] }
        set {
            values[id] = newValue
            guard let limit else { return }
            order.removeAll { $0 == id }
            if newValue != nil { order.append(id) }
            if order.count > limit { values.removeValue(forKey: order.removeFirst()) }
        }
    }
}

private struct ThreadBodySources: Sendable {
    var messages: ThreadBodyMemory
    var checkpoints: ThreadBodyMemory
    var subagents: ThreadBodyMemory

    init(projection: JSONValue? = nil, limit: Int? = nil) {
        messages = ThreadBodyMemory(limit: limit)
        checkpoints = ThreadBodyMemory(limit: limit)
        subagents = ThreadBodyMemory(limit: limit)
        for key in ["messages", "checkpoints", "subagents"] {
            guard case .array(let records) = projection?[key] else { continue }
            for record in records { remember(record, type: key) }
        }
    }

    mutating func remember(_ record: JSONValue, type: String) {
        guard let id = record["id"]?.stringValue else { return }
        switch type {
        case "messages": messages[id] = record["text"]
        case "checkpoints": checkpoints[id] = record["files"]
        case "subagents":
            var bodies: [String: JSONValue] = [:]
            for key in ["prompt", "result", "promptOmitted", "resultOmitted"] { bodies[key] = record[key] }
            subagents[id] = .object(bodies)
        default: break
        }
    }

    func restoreSubagent(_ record: JSONValue, idKey: String) throws -> JSONValue {
        guard case .object(var fields) = record else { return record }
        let source = fields[idKey]?.stringValue.flatMap { subagents[$0] }
        for key in ["prompt", "result"] where fields[key + "Omitted"] == .bool(true) {
            guard let value = source?[key], source?[key + "Omitted"] != .bool(true) else {
                throw ThreadPayloadRestoration.invalid("Missing subagent body: \(key)")
            }
            let valid = value.stringValue != nil || (key == "result" && value == .null)
            guard valid else { throw ThreadPayloadRestoration.invalid("Invalid subagent body: \(key)") }
            fields[key] = value
            fields.removeValue(forKey: key + "Omitted")
        }
        let restored = JSONValue.object(fields)
        try ThreadPayloadRestoration.rejectOmittedBodies(restored)
        return restored
    }

    func restoreItem(_ record: JSONValue) throws -> JSONValue {
        guard case .object(var fields) = record else { return record }
        switch fields["type"]?.stringValue {
        case "user_message", "assistant_message":
            if fields["textOmitted"] == .bool(true) {
                guard let id = fields["messageId"]?.stringValue, let text = messages[id] else {
                    throw ThreadPayloadRestoration.invalid("Missing message body")
                }
                guard case .string = text else { throw ThreadPayloadRestoration.invalid("Invalid message body") }
                fields["text"] = text
                fields.removeValue(forKey: "textOmitted")
            }
        case "checkpoint":
            if fields["filesOmitted"] == .bool(true) {
                guard let id = fields["checkpointId"]?.stringValue, let files = checkpoints[id] else {
                    throw ThreadPayloadRestoration.invalid("Missing checkpoint body")
                }
                guard case .array = files else { throw ThreadPayloadRestoration.invalid("Invalid checkpoint body") }
                fields["files"] = files
                fields.removeValue(forKey: "filesOmitted")
            }
        case "subagent": return try restoreSubagent(record, idKey: "subagentId")
        default: break
        }
        let restored = JSONValue.object(fields)
        try ThreadPayloadRestoration.rejectOmittedBodies(restored)
        return restored
    }
}

/// Keep one per thread store. Snapshot and cache resets replace its sources; resumed streams
/// retain them. Only this decoder may accept deduped event bodies. Failed decoding is atomic.
public struct ThreadWireRestorer: Sendable {
    private var sources = ThreadBodySources(limit: 32)

    public init() {}

    public mutating func decode(_ raw: JSONValue) throws -> ThreadStreamItem {
        var next = self
        let restored: JSONValue
        if raw["kind"] == .string("snapshot") {
            let snapshot = try ThreadPayloadRestoration.snapshot(raw)
            let decoded = try ThreadDetailSnapshot(restored: snapshot)
            next.sources = ThreadBodySources(projection: snapshot["projection"], limit: 32)
            self = next
            return .snapshot(decoded)
        } else if raw["kind"] == .string("event"), case .object(var root) = raw,
                  case .object(var event) = root["event"], let payload = event["payload"] {
            switch event["type"]?.stringValue {
            case "message.updated": next.sources.remember(payload, type: "messages")
            case "checkpoint.captured": next.sources.remember(payload, type: "checkpoints")
            case "subagent.updated":
                event["payload"] = try sources.restoreSubagent(payload, idKey: "id")
                next.sources.remember(event["payload"]!, type: "subagents")
            case "turn-item.updated": event["payload"] = try sources.restoreItem(payload)
            default: break
            }
            root["event"] = .object(event)
            restored = .object(root)
        } else {
            restored = raw
        }
        let item = try restored.decode(as: ThreadStreamItem.self)
        self = next
        return item
    }

    /// Seeds records from an already restored cache or HTTP snapshot without serializing its
    /// timeline. Typed callers never pass omitted bodies here.
    public mutating func seed(_ projection: ThreadProjection) {
        sources = ThreadBodySources(limit: 32)
        for message in projection.messages { sources.messages[message.id.rawValue] = .string(message.text) }
        for checkpoint in projection.checkpoints {
            sources.checkpoints[checkpoint.id.rawValue] = .array(checkpoint.files.map { file in
                var fields: [String: JSONValue] = ["path": .string(file.path)]
                if let kind = file.kind { fields["kind"] = .string(kind) }
                if let additions = file.additions { fields["additions"] = .number(Double(additions)) }
                if let deletions = file.deletions { fields["deletions"] = .number(Double(deletions)) }
                return .object(fields)
            })
        }
        for subagent in projection.subagents { sources.remember(subagent, type: "subagents") }
    }
}
