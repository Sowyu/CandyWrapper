import Foundation
import SpaceModel

public enum ApplyError: Error, Equatable, Sendable {
    /// Frames apply in seq order with no gaps (docs/space.md, "On the Space machine").
    case gap(expected: Int64, got: Int64)
    /// A local op touches each record once, so its text base is unambiguous.
    case repeatedRecord(RecordID)
}

/// Records as raw JSON objects, so partial records and keys from newer clients survive every apply.
/// Encodes to the snapshot payload shape: `{"format", "v", "seq", "pages", "blocks", "revs"}`.
public struct SpaceState: Codable, Hashable, Sendable {
    public typealias Object = [String: JSONValue]

    public internal(set) var seq: Int64
    public internal(set) var pages: [PageID: Object]
    public internal(set) var blocks: [BlockID: Object]
    public internal(set) var revs: [RecordID: Int64]
    /// Unknown top-level snapshot keys, written back unchanged.
    public var extra: Object

    public init(seq: Int64 = 0, pages: [PageID: Object] = [:], blocks: [BlockID: Object] = [:], revs: [RecordID: Int64] = [:], extra: Object = [:]) {
        self.seq = seq; self.pages = pages; self.blocks = blocks; self.revs = revs; self.extra = extra
    }

    public init(snapshot: SnapshotPayload) throws {
        self = try SpaceJSON.decode(Self.self, from: SpaceJSON.encode(snapshot))
    }

    // MARK: Apply

    /// Applies one confirmed frame and its decrypted payload. Revs follow the frame's authenticated
    /// `recs`, the same list the Space machine uses, so every copy keeps identical revs.
    public mutating func apply(_ frame: LogFrame, _ payload: OpPayload) throws {
        guard frame.seq == seq + 1 else { throw ApplyError.gap(expected: seq + 1, got: frame.seq) }
        apply(payload.changes)
        for rec in frame.recs { revs[rec.id] = frame.seq }
        seq = frame.seq
    }

    /// Applies changes without a frame, for pending changes on top of the confirmed state.
    public mutating func apply(_ changes: [RecordChange]) {
        for change in changes { apply(change) }
    }

    /// Keys apply in UTF-8 byte order, so `props` replaces the map before `props.x` sets inside it.
    /// A `parent` that would make the page its own ancestor is ignored and the old parent stays.
    mutating func apply(_ change: RecordChange) {
        let keys = change.set.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        switch change.kind {
        case .page:
            var record = pages[change.id] ?? [:]
            for key in keys {
                let value = change.set[key]!
                if key == "parent", case .string(let raw) = value, let parent = try? PageID(raw),
                   isAncestor(change.id, of: parent) { continue }
                Self.set(&record, key, value)
            }
            pages[change.id] = record
        case .block:
            var record = blocks[change.id] ?? [:]
            for key in keys { Self.set(&record, key, change.set[key]!) }
            blocks[change.id] = record
        default:
            // ponytail: other record kinds are dropped, add a raw map per kind when the format gains one.
            break
        }
    }

    /// True when `ancestor` is `page` or sits above it. A missing parent ends the walk, so a page
    /// with a missing parent counts as top level.
    func isAncestor(_ ancestor: PageID, of page: PageID) -> Bool {
        var current: PageID? = page
        var seen: Set<PageID> = []
        while let id = current, seen.insert(id).inserted {
            if id == ancestor { return true }
            current = parent(of: id)
        }
        return false
    }

    /// The page's parent when that parent exists, else nil: a page whose parent is missing shows at the top.
    public func parent(of page: PageID) -> PageID? {
        guard case .string(let raw)? = pages[page]?["parent"], let id = try? PageID(raw), pages[id] != nil else { return nil }
        return id
    }

    /// `set` semantics: a key, or a two-level path split at the first dot. Null removes the path.
    static func set(_ record: inout Object, _ key: String, _ value: JSONValue) {
        guard let dot = key.firstIndex(of: ".") else {
            record[key] = value == .null ? nil : value
            return
        }
        let head = String(key[..<dot]), tail = String(key[key.index(after: dot)...])
        var inner: Object
        if case .object(let existing)? = record[head] { inner = existing }
        else if value == .null { return }
        else { inner = [:] }
        inner[tail] = value == .null ? nil : value
        record[head] = .object(inner)
    }

    /// The value at a key or two-level path. A stored null reads as missing, since null removes.
    func value(_ kind: RecordKind, _ id: RecordID, _ key: String) -> JSONValue? {
        guard let record = kind == .page ? pages[id] : kind == .block ? blocks[id] : nil else { return nil }
        let found: JSONValue?
        if let dot = key.firstIndex(of: ".") {
            guard case .object(let inner)? = record[String(key[..<dot])] else { return nil }
            found = inner[String(key[key.index(after: dot)...])]
        } else { found = record[key] }
        return found == .null ? nil : found
    }

    func exists(_ kind: RecordKind, _ id: RecordID) -> Bool {
        kind == .page ? pages[id] != nil : kind == .block ? blocks[id] != nil : false
    }

    // MARK: Typed reads

    /// The typed page, or nil while the record is still partial or unreadable.
    public func page(_ id: PageID) -> PageRecord? { pages[id].flatMap { try? JSONValue.object($0).decoded() } }
    public func block(_ id: BlockID) -> BlockRecord? { blocks[id].flatMap { try? JSONValue.object($0).decoded() } }

    /// The block's text, empty when it has none or it can't be read.
    public func text(of block: BlockID) -> RichText {
        (try? blocks[block]?["text"]?.decoded()) ?? RichText()
    }

    /// A page's blocks and child pages, trashed ones included, by order key and then record id.
    public func content(of page: PageID) -> [(kind: RecordKind, position: RecordPosition)] {
        var result: [(kind: RecordKind, position: RecordPosition)] = []
        for (id, record) in pages {
            if case .string(page.rawValue)? = record["parent"], let order = Self.order(record) {
                result.append((.page, RecordPosition(order: order, id: id)))
            }
        }
        for (id, record) in blocks {
            if case .string(page.rawValue)? = record["page"], let order = Self.order(record) {
                result.append((.block, RecordPosition(order: order, id: id)))
            }
        }
        return result.sorted { $0.position < $1.position }
    }

    static func order(_ record: Object) -> OrderKey? {
        guard case .string(let raw)? = record["order"] else { return nil }
        return try? OrderKey(raw)
    }

    // MARK: Coding

    public init(from decoder: Decoder) throws {
        var object = try Object(from: decoder)
        func records(_ key: String) throws -> [RecordID: Object] {
            guard case .object(let map)? = object.removeValue(forKey: key) else { return [:] }
            var result: [RecordID: Object] = [:]
            for (id, value) in map {
                guard case .object(let record) = value else { throw ModelError.invalidID(id) }
                result[try RecordID(id)] = record
            }
            return result
        }
        guard case .integer(let seq)? = object.removeValue(forKey: "seq") else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Snapshot needs a seq"))
        }
        self.seq = seq
        pages = try records("pages")
        blocks = try records("blocks")
        revs = [:]
        if case .object(let map)? = object.removeValue(forKey: "revs") {
            for (id, value) in map {
                guard case .integer(let rev) = value else { throw ModelError.invalidID(id) }
                revs[try RecordID(id)] = rev
            }
        }
        object["format"] = object["format"] ?? .string("candywrapper.space-snapshot")
        object["v"] = object["v"] ?? .integer(1)
        extra = object
    }

    public func encode(to encoder: Encoder) throws {
        var object = extra
        object["seq"] = .integer(seq)
        object["pages"] = .object(Dictionary(uniqueKeysWithValues: pages.map { ($0.key.rawValue, JSONValue.object($0.value)) }))
        object["blocks"] = .object(Dictionary(uniqueKeysWithValues: blocks.map { ($0.key.rawValue, JSONValue.object($0.value)) }))
        object["revs"] = .object(Dictionary(uniqueKeysWithValues: revs.map { ($0.key.rawValue, JSONValue.integer($0.value)) }))
        try object.encode(to: encoder)
    }
}

extension JSONValue {
    /// Converts a typed model value to raw JSON through the shared encoder.
    public init<T: Encodable>(encoding value: T) throws {
        self = try SpaceJSON.decode(JSONValue.self, from: SpaceJSON.encode(value))
    }
    public func decoded<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        try SpaceJSON.decode(type, from: SpaceJSON.encode(self))
    }
}

extension RecordChange {
    /// A change that sets every key of a new or replaced page.
    public static func page(_ id: PageID, _ record: PageRecord) throws -> RecordChange {
        guard case .object(let set) = try JSONValue(encoding: record) else { preconditionFailure("A page encodes as an object") }
        return RecordChange(kind: .page, id: id, set: set)
    }
    /// A change that sets every key of a new or replaced block.
    public static func block(_ id: BlockID, _ record: BlockRecord) throws -> RecordChange {
        guard case .object(let set) = try JSONValue(encoding: record) else { preconditionFailure("A block encodes as an object") }
        return RecordChange(kind: .block, id: id, set: set)
    }
}
