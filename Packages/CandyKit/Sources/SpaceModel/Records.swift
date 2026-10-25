import Foundation

// The JSON keys in these types follow docs/space.md sections 1, 2 and 7.
// Record ids live in snapshot maps and changes, never inside a record.

public struct FieldOption: Codable, Hashable, Sendable {
    public var name: String
    public var color: FieldColor
    public var order: OrderKey
    public var extra: [String: JSONValue]
    private static let known: Set<String> = ["name", "color", "order"]

    public init(name: String, color: FieldColor, order: OrderKey, extra: [String: JSONValue] = [:]) {
        self.name = name
        self.color = color
        self.order = order
        self.extra = extra
    }

    public init(from decoder: Decoder) throws {
        let c = try ObjectReader(decoder)
        name = try c.required("name")
        color = try c.required("color")
        order = try c.required("order")
        extra = try c.unknown(Self.known)
    }

    public func encode(to encoder: Encoder) throws {
        var c = try ObjectWriter(encoder, extra: extra, known: Self.known)
        try c.required(name, "name")
        try c.required(color, "color")
        try c.required(order, "order")
    }
}

public struct FieldDefinition: Codable, Hashable, Sendable {
    public var name: String
    public var type: FieldType
    public var order: OrderKey
    public var options: [String: FieldOption]?
    public var extra: [String: JSONValue]
    private var explicitNulls: Set<String>
    private static let known: Set<String> = ["name", "type", "order", "options"]

    public init(name: String, type: FieldType, order: OrderKey, options: [String: FieldOption]? = nil, extra: [String: JSONValue] = [:]) {
        self.name = name
        self.type = type
        self.order = order
        self.options = options
        self.extra = extra
        self.explicitNulls = []
    }

    public init(from decoder: Decoder) throws {
        let c = try ObjectReader(decoder)
        name = try c.required("name")
        type = try c.required("type")
        order = try c.required("order")
        options = try c.optional("options")
        extra = try c.unknown(Self.known)
        explicitNulls = try c.nulls(["options"])
    }

    public func encode(to encoder: Encoder) throws {
        var c = try ObjectWriter(encoder, extra: extra, known: Self.known)
        try c.required(name, "name")
        try c.required(type, "type")
        try c.required(order, "order")
        try c.optional(options, "options", nulls: explicitNulls)
    }
}

public struct Sort: Codable, Hashable, Sendable {
    public var field: String
    public var desc: Bool
    public var extra: [String: JSONValue]
    private static let known: Set<String> = ["field", "desc"]

    public init(field: String, desc: Bool = false, extra: [String: JSONValue] = [:]) {
        self.field = field
        self.desc = desc
        self.extra = extra
    }

    public init(from decoder: Decoder) throws {
        let c = try ObjectReader(decoder)
        field = try c.required("field")
        desc = try c.required("desc")
        extra = try c.unknown(Self.known)
    }

    public func encode(to encoder: Encoder) throws {
        var c = try ObjectWriter(encoder, extra: extra, known: Self.known)
        try c.required(field, "field")
        try c.required(desc, "desc")
    }
}

public struct Filter: Codable, Hashable, Sendable {
    public var field: String
    public var op: FilterOp
    public var value: JSONValue
    public var extra: [String: JSONValue]
    private static let known: Set<String> = ["field", "op", "value"]

    public init(field: String, op: FilterOp, value: JSONValue, extra: [String: JSONValue] = [:]) {
        self.field = field
        self.op = op
        self.value = value
        self.extra = extra
    }

    public init(from decoder: Decoder) throws {
        let c = try ObjectReader(decoder)
        field = try c.required("field")
        op = try c.required("op")
        value = try c.required("value")
        extra = try c.unknown(Self.known)
    }

    public func encode(to encoder: Encoder) throws {
        var c = try ObjectWriter(encoder, extra: extra, known: Self.known)
        try c.required(field, "field")
        try c.required(op, "op")
        try c.required(value, "value")
    }
}

public struct TableColumn: Codable, Hashable, Sendable {
    public var field: String
    public var width: Double
    public var extra: [String: JSONValue]
    private static let known: Set<String> = ["field", "width"]

    public init(field: String, width: Double, extra: [String: JSONValue] = [:]) {
        self.field = field
        self.width = width
        self.extra = extra
    }

    public init(from decoder: Decoder) throws {
        let c = try ObjectReader(decoder)
        field = try c.required("field")
        width = try c.required("width")
        extra = try c.unknown(Self.known)
    }

    public func encode(to encoder: Encoder) throws {
        var c = try ObjectWriter(encoder, extra: extra, known: Self.known)
        try c.required(field, "field")
        try c.required(width, "width")
    }
}

public struct ViewSettings: Codable, Hashable, Sendable {
    public var page: PageViewSettings?
    public var board: BoardViewSettings?
    public var table: TableViewSettings?
    public var timetable: TimetableViewSettings?
    public var extra: [String: JSONValue]
    private var explicitNulls: Set<String>
    private static let known: Set<String> = ["page", "board", "table", "timetable"]

    public init(page: PageViewSettings? = nil, board: BoardViewSettings? = nil, table: TableViewSettings? = nil, timetable: TimetableViewSettings? = nil, extra: [String: JSONValue] = [:]) {
        self.page = page
        self.board = board
        self.table = table
        self.timetable = timetable
        self.extra = extra
        self.explicitNulls = []
    }

    public init(from decoder: Decoder) throws {
        let c = try ObjectReader(decoder)
        page = try c.optional("page")
        board = try c.optional("board")
        table = try c.optional("table")
        timetable = try c.optional("timetable")
        extra = try c.unknown(Self.known)
        explicitNulls = try c.nulls(["page", "board", "table", "timetable"])
    }

    public func encode(to encoder: Encoder) throws {
        var c = try ObjectWriter(encoder, extra: extra, known: Self.known)
        try c.optional(page, "page", nulls: explicitNulls)
        try c.optional(board, "board", nulls: explicitNulls)
        try c.optional(table, "table", nulls: explicitNulls)
        try c.optional(timetable, "timetable", nulls: explicitNulls)
    }
}

public struct PageViewSettings: Codable, Hashable, Sendable {
    public var extra: [String: JSONValue]
    private static let known: Set<String> = []

    public init(extra: [String: JSONValue] = [:]) {
        self.extra = extra
    }

    public init(from decoder: Decoder) throws {
        let c = try ObjectReader(decoder)
        extra = try c.unknown(Self.known)
    }

    public func encode(to encoder: Encoder) throws {
        let c = try ObjectWriter(encoder, extra: extra, known: Self.known)
        _ = c
    }
}

public struct BoardViewSettings: Codable, Hashable, Sendable {
    public var group: String
    public var show: [String]
    public var hidden: [String]
    public var sort: [Sort]
    public var filter: [Filter]
    public var extra: [String: JSONValue]
    private static let known: Set<String> = ["group", "show", "hidden", "sort", "filter"]

    public init(group: String, show: [String] = [], hidden: [String] = [], sort: [Sort] = [], filter: [Filter] = [], extra: [String: JSONValue] = [:]) {
        self.group = group
        self.show = show
        self.hidden = hidden
        self.sort = sort
        self.filter = filter
        self.extra = extra
    }

    public init(from decoder: Decoder) throws {
        let c = try ObjectReader(decoder)
        group = try c.required("group")
        show = try c.required("show")
        hidden = try c.required("hidden")
        sort = try c.required("sort")
        filter = try c.required("filter")
        extra = try c.unknown(Self.known)
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var c = try ObjectWriter(encoder, extra: extra, known: Self.known)
        try c.required(group, "group")
        try c.required(show, "show")
        try c.required(hidden, "hidden")
        try c.required(sort, "sort")
        try c.required(filter, "filter")
    }
}

public struct TableViewSettings: Codable, Hashable, Sendable {
    public var cols: [TableColumn]
    public var sort: [Sort]
    public var filter: [Filter]
    public var titleHidden: Bool
    public var extra: [String: JSONValue]
    private static let known: Set<String> = ["cols", "sort", "filter", "titleHidden"]

    public init(cols: [TableColumn] = [], sort: [Sort] = [], filter: [Filter] = [], titleHidden: Bool = false, extra: [String: JSONValue] = [:]) {
        self.cols = cols
        self.sort = sort
        self.filter = filter
        self.titleHidden = titleHidden
        self.extra = extra
    }

    public init(from decoder: Decoder) throws {
        let c = try ObjectReader(decoder)
        cols = try c.required("cols")
        sort = try c.required("sort")
        filter = try c.required("filter")
        titleHidden = try c.optional("titleHidden") ?? false
        extra = try c.unknown(Self.known)
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var c = try ObjectWriter(encoder, extra: extra, known: Self.known)
        try c.required(cols, "cols")
        try c.required(sort, "sort")
        try c.required(filter, "filter")
        if titleHidden { try c.required(true, "titleHidden") }
    }
}

public struct TimetableViewSettings: Codable, Hashable, Sendable {
    public var field: String
    public var from: Int
    public var to: Int
    public var days: Int
    public var filter: [Filter]
    public var extra: [String: JSONValue]
    private static let known: Set<String> = ["field", "from", "to", "days", "filter"]

    public init(field: String, from: Int = 7, to: Int = 22, days: Int = 7, filter: [Filter] = [], extra: [String: JSONValue] = [:]) {
        self.field = field
        self.from = from
        self.to = to
        self.days = days
        self.filter = filter
        self.extra = extra
    }

    public init(from decoder: Decoder) throws {
        let c = try ObjectReader(decoder)
        field = try c.required("field")
        from = try c.required("from")
        to = try c.required("to")
        days = try c.required("days")
        filter = try c.required("filter")
        extra = try c.unknown(Self.known)
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var c = try ObjectWriter(encoder, extra: extra, known: Self.known)
        try c.required(field, "field")
        try c.required(from, "from")
        try c.required(to, "to")
        try c.required(days, "days")
        try c.required(filter, "filter")
    }
}

public struct BlobReference: Codable, Hashable, Sendable {
    public var id: String
    public var preview: String?
    public var name: String
    public var mime: String
    public var size: Int64
    public var w: Int?
    public var h: Int?
    public var extra: [String: JSONValue]
    private var explicitNulls: Set<String>
    private static let known: Set<String> = ["id", "preview", "name", "mime", "size", "w", "h"]

    public init(id: String, preview: String? = nil, name: String, mime: String, size: Int64, w: Int? = nil, h: Int? = nil, extra: [String: JSONValue] = [:]) {
        self.id = id
        self.preview = preview
        self.name = name
        self.mime = mime
        self.size = size
        self.w = w
        self.h = h
        self.extra = extra
        self.explicitNulls = []
    }

    public init(from decoder: Decoder) throws {
        let c = try ObjectReader(decoder)
        id = try c.required("id")
        preview = try c.optional("preview")
        name = try c.required("name")
        mime = try c.required("mime")
        size = try c.required("size")
        w = try c.optional("w")
        h = try c.optional("h")
        extra = try c.unknown(Self.known)
        explicitNulls = try c.nulls(["preview", "w", "h"])
    }

    public func encode(to encoder: Encoder) throws {
        var c = try ObjectWriter(encoder, extra: extra, known: Self.known)
        try c.required(id, "id")
        try c.optional(preview, "preview", nulls: explicitNulls)
        try c.required(name, "name")
        try c.required(mime, "mime")
        try c.required(size, "size")
        try c.optional(w, "w", nulls: explicitNulls)
        try c.optional(h, "h", nulls: explicitNulls)
    }
}

public struct BlockConflict: Codable, Hashable, Sendable {
    public var device: String
    public var at: Int64
    public var extra: [String: JSONValue]
    private static let known: Set<String> = ["device", "at"]

    public init(device: String, at: Int64, extra: [String: JSONValue] = [:]) {
        self.device = device
        self.at = at
        self.extra = extra
    }

    public init(from decoder: Decoder) throws {
        let c = try ObjectReader(decoder)
        device = try c.required("device")
        at = try c.required("at")
        extra = try c.unknown(Self.known)
    }

    public func encode(to encoder: Encoder) throws {
        var c = try ObjectWriter(encoder, extra: extra, known: Self.known)
        try c.required(device, "device")
        try c.required(at, "at")
    }
}

public struct PageRecord: Codable, Hashable, Sendable {
    public var parent: PageID?
    public var order: OrderKey
    public var title: String
    public var icon: String?
    /// iconImage wins over icon when both are set. Setting one clears the other.
    public var iconImage: BlobReference?
    /// The title column name for this page's items. Nil means "Title".
    public var titleName: String?
    public var props: [String: PropertyValue]
    public var fields: [String: FieldDefinition]
    public var views: ViewSettings
    public var view: ViewType
    public var trashed: Bool
    public var trashedAt: Int64?
    public var created: Int64
    public var extra: [String: JSONValue]
    private var explicitNulls: Set<String>
    private static let known: Set<String> = ["parent", "order", "title", "icon", "iconImage", "titleName", "props", "fields", "views", "view", "trashed", "trashedAt", "created"]

    public init(parent: PageID? = nil, order: OrderKey, title: String = "", icon: String? = nil, iconImage: BlobReference? = nil, titleName: String? = nil, props: [String: PropertyValue] = [:], fields: [String: FieldDefinition] = [:], views: ViewSettings = ViewSettings(), view: ViewType = .page, trashed: Bool = false, trashedAt: Int64? = nil, created: Int64, extra: [String: JSONValue] = [:]) {
        self.parent = parent
        self.order = order
        self.title = title
        self.icon = icon
        self.iconImage = iconImage
        self.titleName = titleName
        self.props = props
        self.fields = fields
        self.views = views
        self.view = view
        self.trashed = trashed
        self.trashedAt = trashedAt
        self.created = created
        self.extra = extra
        self.explicitNulls = ["parent", "icon", "iconImage", "titleName", "trashedAt"]
    }

    public init(from decoder: Decoder) throws {
        let c = try ObjectReader(decoder)
        parent = try c.optional("parent")
        order = try c.required("order")
        title = try c.required("title")
        icon = try c.optional("icon")
        iconImage = try c.optional("iconImage")
        titleName = try c.optional("titleName")
        props = try c.required("props")
        fields = try c.required("fields")
        views = try c.required("views")
        view = try c.required("view")
        trashed = try c.required("trashed")
        trashedAt = try c.optional("trashedAt")
        created = try c.required("created")
        extra = try c.unknown(Self.known)
        explicitNulls = try c.nulls(["parent", "icon", "iconImage", "titleName", "trashedAt"])
    }

    public func encode(to encoder: Encoder) throws {
        var c = try ObjectWriter(encoder, extra: extra, known: Self.known)
        try c.optional(parent, "parent", nulls: explicitNulls)
        try c.required(order, "order")
        try c.required(title, "title")
        try c.optional(icon, "icon", nulls: explicitNulls)
        try c.optional(iconImage, "iconImage", nulls: explicitNulls)
        try c.optional(titleName, "titleName", nulls: explicitNulls)
        try c.required(props, "props")
        try c.required(fields, "fields")
        try c.required(views, "views")
        try c.required(view, "view")
        try c.required(trashed, "trashed")
        try c.optional(trashedAt, "trashedAt", nulls: explicitNulls)
        try c.required(created, "created")
    }
}

public struct BlockRecord: Codable, Hashable, Sendable {
    public var page: PageID
    public var order: OrderKey
    public var type: BlockType
    public var indent: Int
    public var text: RichText
    public var lang: String?
    public var blob: BlobReference?
    public var width: Double?
    public var trashed: Bool
    public var conflict: BlockConflict?
    public var extra: [String: JSONValue]
    private var explicitNulls: Set<String>
    private static let known: Set<String> = ["page", "order", "type", "indent", "text", "lang", "blob", "width", "trashed", "conflict"]

    public init(page: PageID, order: OrderKey, type: BlockType = .p, indent: Int = 0, text: RichText = RichText(), lang: String? = nil, blob: BlobReference? = nil, width: Double? = nil, trashed: Bool = false, conflict: BlockConflict? = nil, extra: [String: JSONValue] = [:]) {
        self.page = page
        self.order = order
        self.type = type
        self.indent = indent
        self.text = text
        self.lang = lang
        self.blob = blob
        self.width = width
        self.trashed = trashed
        self.conflict = conflict
        self.extra = extra
        self.explicitNulls = ["lang", "blob", "width", "conflict"]
    }

    public init(from decoder: Decoder) throws {
        let c = try ObjectReader(decoder)
        page = try c.required("page")
        order = try c.required("order")
        type = try c.required("type")
        indent = try c.required("indent")
        text = try c.required("text")
        lang = try c.optional("lang")
        blob = try c.optional("blob")
        width = try c.optional("width")
        trashed = try c.required("trashed")
        conflict = try c.optional("conflict")
        extra = try c.unknown(Self.known)
        explicitNulls = try c.nulls(["lang", "blob", "width", "conflict"])
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var c = try ObjectWriter(encoder, extra: extra, known: Self.known)
        try c.required(page, "page")
        try c.required(order, "order")
        try c.required(type, "type")
        try c.required(indent, "indent")
        try c.required(text, "text")
        try c.optional(lang, "lang", nulls: explicitNulls)
        try c.optional(blob, "blob", nulls: explicitNulls)
        try c.optional(width, "width", nulls: explicitNulls)
        try c.required(trashed, "trashed")
        try c.optional(conflict, "conflict", nulls: explicitNulls)
    }
}

public struct RecordChange: Codable, Hashable, Sendable {
    public var kind: RecordKind
    public var id: RecordID
    public var set: [String: JSONValue]
    public var extra: [String: JSONValue]
    private static let known: Set<String> = ["kind", "id", "set"]

    public init(kind: RecordKind, id: RecordID, set: [String: JSONValue], extra: [String: JSONValue] = [:]) {
        self.kind = kind
        self.id = id
        self.set = set
        self.extra = extra
    }

    public init(from decoder: Decoder) throws {
        let c = try ObjectReader(decoder)
        kind = try c.required("kind")
        id = try c.required("id")
        set = try c.required("set")
        extra = try c.unknown(Self.known)
    }

    public func encode(to encoder: Encoder) throws {
        var c = try ObjectWriter(encoder, extra: extra, known: Self.known)
        try c.required(kind, "kind")
        try c.required(id, "id")
        try c.required(set, "set")
    }
}

public struct OpPayload: Codable, Hashable, Sendable {
    public var v: Int
    public var at: Int64
    public var changes: [RecordChange]
    public var extra: [String: JSONValue]
    private static let known: Set<String> = ["v", "at", "changes"]

    public init(v: Int = 1, at: Int64, changes: [RecordChange], extra: [String: JSONValue] = [:]) {
        self.v = v
        self.at = at
        self.changes = changes
        self.extra = extra
    }

    public init(from decoder: Decoder) throws {
        let c = try ObjectReader(decoder)
        v = try c.required("v")
        at = try c.required("at")
        changes = try c.required("changes")
        extra = try c.unknown(Self.known)
    }

    public func encode(to encoder: Encoder) throws {
        var c = try ObjectWriter(encoder, extra: extra, known: Self.known)
        try c.required(v, "v")
        try c.required(at, "at")
        try c.required(changes, "changes")
    }
}

public struct LogFrame: Codable, Hashable, Sendable {
    public var seq: Int64
    public var t: Int64
    public var dev: DeviceID
    public var op: OpID
    public var recs: [RecordRevision]
    public var ct: String
    public var extra: [String: JSONValue]
    private static let known: Set<String> = ["seq", "t", "dev", "op", "recs", "ct"]

    public init(seq: Int64, t: Int64, dev: DeviceID, op: OpID, recs: [RecordRevision], ct: String, extra: [String: JSONValue] = [:]) {
        self.seq = seq
        self.t = t
        self.dev = dev
        self.op = op
        self.recs = recs
        self.ct = ct
        self.extra = extra
    }

    public init(from decoder: Decoder) throws {
        let c = try ObjectReader(decoder)
        seq = try c.required("seq")
        t = try c.required("t")
        dev = try c.required("dev")
        op = try c.required("op")
        recs = try c.required("recs")
        ct = try c.required("ct")
        extra = try c.unknown(Self.known)
    }

    public func encode(to encoder: Encoder) throws {
        var c = try ObjectWriter(encoder, extra: extra, known: Self.known)
        try c.required(seq, "seq")
        try c.required(t, "t")
        try c.required(dev, "dev")
        try c.required(op, "op")
        try c.required(recs, "recs")
        try c.required(ct, "ct")
    }
}

public struct SpaceHeader: Codable, Hashable, Sendable {
    public var format: String
    public var version: Int
    public var spaceId: SpaceID
    public var created: Int64
    public var check: String
    public var movedTo: String?
    public var extra: [String: JSONValue]
    private var explicitNulls: Set<String>
    private static let known: Set<String> = ["format", "version", "spaceId", "created", "check", "movedTo"]

    public init(format: String = "candywrapper.space", version: Int = 1, spaceId: SpaceID, created: Int64, check: String, movedTo: String? = nil, extra: [String: JSONValue] = [:]) {
        self.format = format
        self.version = version
        self.spaceId = spaceId
        self.created = created
        self.check = check
        self.movedTo = movedTo
        self.extra = extra
        self.explicitNulls = ["movedTo"]
    }

    public init(from decoder: Decoder) throws {
        let c = try ObjectReader(decoder)
        format = try c.required("format")
        version = try c.required("version")
        spaceId = try c.required("spaceId")
        created = try c.required("created")
        check = try c.required("check")
        movedTo = try c.optional("movedTo")
        extra = try c.unknown(Self.known)
        explicitNulls = try c.nulls(["movedTo"])
    }

    public func encode(to encoder: Encoder) throws {
        var c = try ObjectWriter(encoder, extra: extra, known: Self.known)
        try c.required(format, "format")
        try c.required(version, "version")
        try c.required(spaceId, "spaceId")
        try c.required(created, "created")
        try c.required(check, "check")
        try c.optional(movedTo, "movedTo", nulls: explicitNulls)
    }
}

public struct EncryptedSnapshot: Codable, Hashable, Sendable {
    public var seq: Int64
    public var ct: String
    public var extra: [String: JSONValue]
    private static let known: Set<String> = ["seq", "ct"]

    public init(seq: Int64, ct: String, extra: [String: JSONValue] = [:]) {
        self.seq = seq
        self.ct = ct
        self.extra = extra
    }

    public init(from decoder: Decoder) throws {
        let c = try ObjectReader(decoder)
        seq = try c.required("seq")
        ct = try c.required("ct")
        extra = try c.unknown(Self.known)
    }

    public func encode(to encoder: Encoder) throws {
        var c = try ObjectWriter(encoder, extra: extra, known: Self.known)
        try c.required(seq, "seq")
        try c.required(ct, "ct")
    }
}

public struct SnapshotPayload: Codable, Hashable, Sendable {
    public var format: String
    public var v: Int
    public var seq: Int64
    public var pages: [String: PageRecord]
    public var blocks: [String: BlockRecord]
    public var revs: [String: Int64]
    public var extra: [String: JSONValue]
    private static let known: Set<String> = ["format", "v", "seq", "pages", "blocks", "revs"]

    public init(format: String = "candywrapper.space-snapshot", v: Int = 1, seq: Int64, pages: [String: PageRecord] = [:], blocks: [String: BlockRecord] = [:], revs: [String: Int64] = [:], extra: [String: JSONValue] = [:]) {
        self.format = format
        self.v = v
        self.seq = seq
        self.pages = pages
        self.blocks = blocks
        self.revs = revs
        self.extra = extra
    }

    public init(from decoder: Decoder) throws {
        let c = try ObjectReader(decoder)
        format = try c.required("format")
        v = try c.required("v")
        seq = try c.required("seq")
        pages = try c.required("pages")
        blocks = try c.required("blocks")
        revs = try c.required("revs")
        extra = try c.unknown(Self.known)
    }

    public func encode(to encoder: Encoder) throws {
        var c = try ObjectWriter(encoder, extra: extra, known: Self.known)
        try c.required(format, "format")
        try c.required(v, "v")
        try c.required(seq, "seq")
        try c.required(pages, "pages")
        try c.required(blocks, "blocks")
        try c.required(revs, "revs")
    }
}
