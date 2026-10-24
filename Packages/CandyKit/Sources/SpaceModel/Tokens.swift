import Foundation

/// Unknown string values stay readable so newer clients do not lose their data.
public protocol SpaceString: RawRepresentable, Codable, Hashable, Sendable where RawValue == String {
    init(rawValue: String)
}
extension SpaceString {
    public init(from decoder: Decoder) throws { self.init(rawValue: try decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

public struct BlockType: SpaceString, CaseIterable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let p = Self(rawValue: "p")
    public static let h1 = Self(rawValue: "h1")
    public static let h2 = Self(rawValue: "h2")
    public static let h3 = Self(rawValue: "h3")
    public static let bullet = Self(rawValue: "bullet")
    public static let number = Self(rawValue: "number")
    public static let quote = Self(rawValue: "quote")
    public static let code = Self(rawValue: "code")
    public static let divider = Self(rawValue: "divider")
    public static let image = Self(rawValue: "image")
    public static let file = Self(rawValue: "file")
    public static let allCases: [Self] = [.p, .h1, .h2, .h3, .bullet, .number, .quote, .code, .divider, .image, .file]
}

public struct ViewType: SpaceString, CaseIterable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let page = Self(rawValue: "page")
    public static let board = Self(rawValue: "board")
    public static let table = Self(rawValue: "table")
    public static let timetable = Self(rawValue: "timetable")
    public static let allCases: [Self] = [.page, .board, .table, .timetable]
}

public struct FieldType: SpaceString, CaseIterable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let text = Self(rawValue: "text")
    public static let number = Self(rawValue: "number")
    public static let checkbox = Self(rawValue: "checkbox")
    public static let select = Self(rawValue: "select")
    public static let multi = Self(rawValue: "multi")
    public static let date = Self(rawValue: "date")
    public static let url = Self(rawValue: "url")
    public static let allCases: [Self] = [.text, .number, .checkbox, .select, .multi, .date, .url]
}

public struct FieldColor: SpaceString, CaseIterable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let gray = Self(rawValue: "gray")
    public static let brown = Self(rawValue: "brown")
    public static let orange = Self(rawValue: "orange")
    public static let yellow = Self(rawValue: "yellow")
    public static let green = Self(rawValue: "green")
    public static let blue = Self(rawValue: "blue")
    public static let purple = Self(rawValue: "purple")
    public static let pink = Self(rawValue: "pink")
    public static let red = Self(rawValue: "red")
    public static let allCases: [Self] = [.gray, .brown, .orange, .yellow, .green, .blue, .purple, .pink, .red]
}

public struct MarkKind: SpaceString, CaseIterable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let b = Self(rawValue: "b")
    public static let i = Self(rawValue: "i")
    public static let u = Self(rawValue: "u")
    public static let s = Self(rawValue: "s")
    public static let c = Self(rawValue: "c")
    public static let a = Self(rawValue: "a")
    public static let p = Self(rawValue: "p")
    public static let allCases: [Self] = [.b, .i, .u, .s, .c, .a, .p]
}

public struct RecordKind: SpaceString, CaseIterable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let page = Self(rawValue: "page")
    public static let block = Self(rawValue: "block")
    public static let allCases: [Self] = [.page, .block]
}

public struct RepeatRule: SpaceString, CaseIterable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let weekly = Self(rawValue: "weekly")
    public static let allCases: [Self] = [.weekly]
}

public struct FilterOp: SpaceString, CaseIterable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let contains = Self(rawValue: "contains")
    public static let doesNotContain = Self(rawValue: "does not contain")
    public static let `is` = Self(rawValue: "is")
    public static let isNot = Self(rawValue: "is not")
    public static let isEmpty = Self(rawValue: "is empty")
    public static let isNotEmpty = Self(rawValue: "is not empty")
    public static let before = Self(rawValue: "before")
    public static let after = Self(rawValue: "after")
    public static let on = Self(rawValue: "on")
    public static let thisWeek = Self(rawValue: "this week")
    public static let overdue = Self(rawValue: "overdue")
    public static let eq = Self(rawValue: "=")
    public static let ne = Self(rawValue: "≠")
    public static let lt = Self(rawValue: "<")
    public static let le = Self(rawValue: "≤")
    public static let gt = Self(rawValue: ">")
    public static let ge = Self(rawValue: "≥")
    public static let allCases: [Self] = [.contains, .doesNotContain, .is, .isNot, .isEmpty, .isNotEmpty, .before, .after, .on, .thisWeek, .overdue, .eq, .ne, .lt, .le, .gt, .ge]
}

public enum FieldID {
    public static let done = "done"
    public static let due = "due"
    public static let title = "title"
}
