import Foundation
import Testing
import SpaceModel
import SpaceFields

func field(_ type: FieldType, options: [String: FieldOption]? = nil) throws -> FieldDefinition {
    FieldDefinition(name: "Field", type: type, order: try OrderKey("a0"), options: options)
}

func options() throws -> [String: FieldOption] {
    ["z": FieldOption(name: "Alpha", color: .blue, order: try OrderKey("a0")),
     "a": FieldOption(name: "Beta", color: .red, order: try OrderKey("a1")),
     "b": FieldOption(name: "Gamma", color: .green, order: try OrderKey("a1"))]
}

func item(_ n: Int, _ value: PropertyValue? = nil, order: String = "a0", title: String = "") throws -> FieldItem {
    FieldItem(id: try PageID(String(format: "00000000-0000-4000-8000-%012d", n)),
              page: PageRecord(order: try OrderKey(order), title: title,
                               props: value.map { ["f": $0] } ?? [:], created: 0))
}

func date(_ start: String, tz: String? = nil, end: String? = nil,
          repeat rule: RepeatRule? = nil, remind: Reminder? = nil) throws -> DateValue {
    try DateValue(start: DatePoint(start), end: end.map(DatePoint.init), tz: tz, repeat: rule, remind: remind)
}

func context(_ now: String = "2026-10-27T12:00", zone: String = "Europe/London") throws -> FieldContext {
    let tz = TimeZone(identifier: zone)!
    return FieldContext(now: try DatePoint(now).resolved(in: tz), timeZone: tz)
}

struct SpaceFieldsQueryTests {
    @Test(arguments: FieldType.allCases)
    func sortingEveryTypeWithMixedAndEmptyValues(_ type: FieldType) throws {
        let low: PropertyValue, high: PropertyValue
        switch type {
        case .text, .url: low = .string("Alpha"); high = .string("beta")
        case .number: low = .number(-2); high = .number(10)
        case .checkbox: low = .checkbox(false); high = .checkbox(true)
        case .select: low = .string("z"); high = .string("a")
        case .multi: low = .multi(["z"]); high = .multi(["a", "z"])
        default:
            low = .date(try date("2026-10-27T09:00", tz: "Australia/Melbourne"))
            high = .date(try date("2026-10-27"))
        }
        let schema = ["f": try field(type, options: options())]
        let rows = try [item(4, .unknown(.object(["future": .bool(true)]))), item(2, high),
                        item(3), item(1, low), item(5, .unknown(.null)),
                        item(6, type == .multi ? .multi([]) : .string(""))]
        let asc = try FieldQuery.evaluate(rows, fields: schema, sorts: [Sort(field: "f")], context: context())
        #expect(asc.map(\.id) == [1, 2, 3, 4, 5, 6].map { try! item($0).id })
        let desc = try FieldQuery.evaluate(rows, fields: schema, sorts: [Sort(field: "f", desc: true)], context: context())
        #expect(desc.map(\.id) == [2, 1, 3, 4, 5, 6].map { try! item($0).id })
    }

    @Test func manualOrderTitleAndThreeSortKeys() throws {
        var a = try item(1, .number(2), order: "a1", title: "same")
        var b = try item(2, .number(2), order: "a2", title: "SAME")
        let c = try item(3, .number(1), title: "zzz")
        a.page.props["g"] = .checkbox(true)
        b.page.props["g"] = .checkbox(false)
        let d = try item(4, .number(3), order: "a3", title: "Same")
        let rows = [a, c, b, d]
        let schema = ["f": try field(.number), "g": try field(.checkbox)]
        #expect(try FieldQuery.evaluate(rows, fields: schema, context: context()).map(\.id) == [c.id, a.id, b.id, d.id])
        let sorted = try FieldQuery.evaluate(rows, fields: schema,
            sorts: [Sort(field: "title"), Sort(field: "f", desc: true), Sort(field: "g")], context: context())
        #expect(sorted.map(\.id) == [d.id, b.id, a.id, c.id])
        let ties = try [item(2, .number(1)), item(1, .number(1))]
        #expect(try FieldQuery.evaluate(ties, fields: schema, sorts: [Sort(field: "f", desc: true)], context: context()).first?.id == ties[1].id)
        #expect(throws: FieldEngineError.tooManySorts) {
            try FieldQuery.evaluate([], fields: schema, sorts: Array(repeating: Sort(field: "f"), count: 4), context: context())
        }
    }

    @Test func canonicallyEquivalentTextKeepsAConsistentSortOrder() throws {
        let rows = try [item(3, title: "f"), item(2, title: "é"), item(1, title: "e\u{301}")]
        let result = try FieldQuery.evaluate(rows, fields: [:], sorts: [Sort(field: "title")], context: context())
        #expect(result.map(\.id) == [rows[0].id, rows[2].id, rows[1].id])
        #expect(try FieldFilters.matches(item(1, .string("Straße")), filter: Filter(field: "f", op: .is, value: .string("STRASSE")),
                                        fields: ["f": field(.text)], context: context()))
    }

    @Test func optionsUseOrderAndIDAndMultiIsASet() throws {
        let schema = ["f": try field(.multi, options: options())]
        let rows = try [item(3, .multi(["b"])), item(2, .multi(["a", "z", "a"])), item(1, .multi(["z"]))]
        #expect(try FieldQuery.evaluate(rows, fields: schema, sorts: [Sort(field: "f")], context: context()).map(\.id) == rows.reversed().map(\.id))
        let a = try item(1, .multi(["a", "z"]))
        let b = try item(2, .multi(["z", "a", "z"]))
        #expect(try FieldQuery.evaluate([b, a], fields: schema, sorts: [Sort(field: "f")], context: context()).map(\.id) == [a.id, b.id])
    }

    @Test func allOperatorsHaveTypedSemantics() throws {
        let cases: [(FieldType, PropertyValue, FilterOp, JSONValue, Bool)] = [
            (.text, .string("Hello WORLD"), .contains, .string("world"), true),
            (.text, .string("Hello"), .doesNotContain, .string("bye"), true),
            (.text, .string("Hello"), .is, .string("HELLO"), true),
            (.text, .string("Hello"), .isEmpty, .null, false),
            (.text, .string("Hello"), .isNotEmpty, .null, true),
            (.url, .string("https://example.com"), .contains, .string("EXAMPLE"), true),
            (.url, .string("https://example.com"), .doesNotContain, .string("other"), true),
            (.url, .string("https://example.com"), .is, .string("HTTPS://EXAMPLE.COM"), true),
            (.url, .string(""), .isEmpty, .null, true),
            (.url, .string("https://example.com"), .isNotEmpty, .null, true),
            (.number, .number(5), .eq, .integer(5), true),
            (.number, .number(5), .ne, .integer(6), true),
            (.number, .number(5), .lt, .number(Decimal(string: "5.1")!), true),
            (.number, .number(5), .le, .unsigned(5), true),
            (.number, .number(5), .gt, .integer(4), true),
            (.number, .number(5), .ge, .integer(5), true),
            (.number, .number(0), .isEmpty, .null, false),
            (.checkbox, .checkbox(false), .is, .bool(false), true),
            (.checkbox, .checkbox(false), .is, .bool(true), false),
            (.select, .string("z"), .is, .string("z"), true),
            (.select, .string("z"), .isNot, .string("a"), true),
            (.select, .string("missing"), .isEmpty, .null, true),
            (.multi, .multi(["z", "a"]), .is, .string("a"), true),
            (.multi, .multi(["z", "a"]), .isNot, .string("b"), true),
            (.multi, .multi([]), .isEmpty, .null, true),
            (.date, .date(try date("2026-10-27")), .before, .string("2026-10-28"), true),
            (.date, .date(try date("2026-10-27")), .after, .string("2026-10-26"), true),
            (.date, .date(try date("2026-10-27")), .on, .string("2026-10-27"), true),
            (.date, .date(try date("2026-10-27")), .thisWeek, .null, true),
            (.date, .date(try date("2026-10-26")), .overdue, .null, true),
            (.date, .date(try date("2026-10-27")), .isEmpty, .null, false),
        ]
        #expect(Set(cases.map { $0.2 }) == Set(FilterOp.allCases))
        for (type, value, op, operand, expected) in cases {
            let result = try FieldFilters.matches(item(1, value), filter: Filter(field: "f", op: op, value: operand),
                                                 fields: ["f": field(type, options: options())], context: context())
            #expect(result == expected, "\(type.rawValue) \(op.rawValue)")
        }
    }

    @Test func comparisonsRejectNonmatchingValuesAndRespectNumericBoundaries() throws {
        let cases: [(FieldType, PropertyValue, FilterOp, JSONValue)] = [
            (.text, .string("Hello"), .contains, .string("bye")),
            (.text, .string("Hello"), .doesNotContain, .string("ELL")),
            (.text, .string("Hello"), .is, .string("Hello there")),
            (.url, .string("https://example.com"), .contains, .string("other")),
            (.url, .string("https://example.com"), .doesNotContain, .string("EXAMPLE")),
            (.url, .string("https://example.com"), .is, .string("https://other.com")),
            (.number, .number(5), .eq, .integer(4)),
            (.number, .number(5), .ne, .integer(5)),
            (.number, .number(5), .lt, .integer(5)),
            (.number, .number(5), .le, .integer(4)),
            (.number, .number(5), .gt, .integer(5)),
            (.number, .number(5), .ge, .integer(6)),
            (.select, .string("z"), .is, .string("a")),
            (.select, .string("z"), .isNot, .string("z")),
            (.multi, .multi(["z", "a"]), .is, .string("b")),
            (.multi, .multi(["z", "a"]), .isNot, .string("a")),
        ]
        for (type, value, op, operand) in cases {
            #expect(try !FieldFilters.matches(item(1, value), filter: Filter(field: "f", op: op, value: operand),
                                            fields: ["f": field(type, options: options())], context: context()))
        }
        let large = Decimal(string: "9007199254740993.125")!
        #expect(try FieldFilters.matches(item(1, .number(large)), filter: Filter(field: "f", op: .gt, value: .integer(9007199254740993)),
                                        fields: ["f": field(.number)], context: context()))
        let titles = try [item(1, title: "café"), item(2, title: "cafe")]
        let result = try FieldQuery.evaluate(titles, fields: [:], filters: [Filter(field: "title", op: .is, value: .string("CAFE"))], context: context())
        #expect(result == [titles[1]])
    }

    @Test func emptyValuesDoNotMatchNegativeComparisonsAndInvalidShapesAreEmpty() throws {
        for type in FieldType.allCases {
            let schema = ["f": try field(type, options: options())]
            for op in FieldFilters.operators(for: type) {
                let operand: JSONValue = type == .number ? .integer(1) : type == .checkbox ? .bool(false) : .string(type == .date ? "2026-10-27" : "z")
                for value: PropertyValue? in [nil, .unknown(.null), .unknown(.array([.bool(true)]))] {
                    #expect(try FieldFilters.matches(item(1, value), filter: Filter(field: "f", op: op, value: operand),
                                                   fields: schema, context: context()) == (op == .isEmpty))
                }
            }
        }
        let schema = ["f": try field(.number)]
        #expect(try FieldFilters.matches(item(1, .string("5")), filter: Filter(field: "f", op: .isEmpty, value: .null), fields: schema, context: context()))
        #expect(try FieldFilters.matches(item(1, .number(.nan)), filter: Filter(field: "f", op: .isEmpty, value: .null), fields: schema, context: context()))
    }

    @Test func filtersConjoinTitleIsReservedAndTrashIsExcluded() throws {
        var a = try item(1, .number(4), title: "Report")
        let b = try item(2, .number(8), title: "Report")
        let c = try item(3, .number(4), title: "Other")
        let predicates = [Filter(field: "title", op: .contains, value: .string("report")),
                          Filter(field: "f", op: .lt, value: .integer(5))]
        let fields = ["f": try field(.number), "title": try field(.checkbox)]
        #expect(try FieldQuery.evaluate([a, b, c], fields: fields, filters: predicates, context: context()) == [a])
        a.page.trashed = true
        #expect(try FieldQuery.evaluate([a, b, c], fields: fields, filters: predicates, context: context()).isEmpty)
    }

    @Test func invalidQueriesFailEvenWithoutRows() throws {
        let c = try context()
        #expect(throws: FieldEngineError.unknownField("f")) {
            try FieldQuery.evaluate([], fields: [:], sorts: [Sort(field: "f")], context: c)
        }
        let future = FieldType(rawValue: "future")
        #expect(throws: FieldEngineError.unsupportedType(future)) {
            try FieldQuery.evaluate([], fields: ["f": field(future)], sorts: [Sort(field: "f")], context: c)
        }
        let schema = ["f": try field(.number)]
        #expect(throws: FieldEngineError.unsupportedOperator(.number, .contains)) {
            try FieldQuery.evaluate([], fields: schema, filters: [Filter(field: "f", op: .contains, value: .string("x"))], context: c)
        }
        for operand: JSONValue in [.null, .bool(true), .string("5"), .number(.nan)] {
            #expect(throws: FieldEngineError.invalidFilterValue("f")) {
                try FieldQuery.evaluate([], fields: schema, filters: [Filter(field: "f", op: .eq, value: operand)], context: c)
            }
        }
        #expect(throws: FieldEngineError.invalidFilterValue("f")) {
            try FieldQuery.evaluate([], fields: ["f": field(.date)], filters: [Filter(field: "f", op: .on, value: .string("2026-10-27T09:00"))], context: c)
        }
    }

    @Test func groupingHasEmptyFirstOrderedOptionsHiddenColumnsAndCheckboxes() throws {
        let f = try field(.multi, options: options())
        let rows = try [item(1), item(2, .multi(["a", "z", "z"])), item(3, .multi(["missing"]))]
        let groups = try FieldQuery.groups(rows, field: f, fieldID: "f")
        #expect(groups.map(\.key) == [.empty, .option("z"), .option("a"), .option("b")])
        #expect(groups.map { $0.items.map(\.id) } == [[rows[0].id, rows[2].id], [rows[1].id], [rows[1].id], []])
        let hidden = try FieldQuery.groups(rows, field: f, fieldID: "f", hiddenOptions: ["a"])
        #expect(hidden.map(\.key) == [.empty, .option("z"), .option("b")])
        #expect(hidden[0].items.map(\.id) == [rows[0].id, rows[2].id])
        #expect(try FieldQuery.groups([], field: f, fieldID: "f").map(\.key) == [.option("z"), .option("a"), .option("b")])
        let checkboxes = try [item(1, .checkbox(true)), item(2, .checkbox(false)), item(3)]
        let checked = try FieldQuery.groups(checkboxes, field: field(.checkbox), fieldID: "f")
        #expect(checked.map(\.key) == [.empty, .checkbox(false), .checkbox(true)])
        #expect(checked.map { $0.items.first?.id } == [checkboxes[2].id, checkboxes[1].id, checkboxes[0].id])
        let select = try FieldQuery.groups([item(1, .string("z"))], field: field(.select, options: options()), fieldID: "f")
        #expect(select[0].items.count == 1)
        #expect(throws: FieldEngineError.cannotGroup(.text)) {
            try FieldQuery.groups([], field: field(.text), fieldID: "f")
        }
    }
}
