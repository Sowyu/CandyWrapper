import Foundation
import Testing
import SpaceModel
import SpaceFields

struct SpaceFieldsConversionTests {
    // Every source is convertible to the widest useful set of destination types.
    // Separate edge cases below cover rejected and partially retained values.
    @Test(arguments: FieldType.allCases, FieldType.allCases)
    func everyTypeToEveryOtherType(_ sourceType: FieldType, _ targetType: FieldType) throws {
        let opts = ["one": FieldOption(name: "1", color: .blue, order: try OrderKey("a0")),
                    "true": FieldOption(name: "true", color: .red, order: try OrderKey("a1")),
                    "date": FieldOption(name: "2026-10-27", color: .green, order: try OrderKey("a2")),
                    "url": FieldOption(name: "https://example.com", color: .gray, order: try OrderKey("a3"))]
        let source = try field(sourceType, options: opts)
        let target = try field(targetType, options: opts)
        let original: PropertyValue
        switch sourceType {
        case .text: original = .string("1")
        case .url: original = .string("https://example.com")
        case .number: original = .number(1)
        case .checkbox: original = .checkbox(true)
        case .select: original = .string("one")
        case .multi: original = .multi(["one"])
        default: original = .date(try date("2026-10-27"))
        }
        let expected: PropertyValue?
        if sourceType == targetType { expected = original }
        else {
            switch targetType {
            case .text:
                switch sourceType {
                case .url: expected = .string("https://example.com")
                case .checkbox: expected = .string("true")
                case .date: expected = .string("2026-10-27")
                default: expected = .string("1")
                }
            case .url: expected = nil
            case .number:
                expected = [.text, .checkbox, .select, .multi].contains(sourceType) ? .number(1) : nil
            case .checkbox:
                expected = sourceType == .number ? .checkbox(true) : nil
            case .select:
                switch sourceType {
                case .checkbox: expected = .string("true")
                case .date: expected = .string("date")
                case .url: expected = .string("url")
                default: expected = .string("one")
                }
            case .multi:
                switch sourceType {
                case .checkbox: expected = .multi(["true"])
                case .date: expected = .multi(["date"])
                case .url: expected = .multi(["url"])
                default: expected = .multi(["one"])
                }
            default: expected = nil
            }
        }
        let result = try FieldConversion.convert(original, from: source, to: target, context: context())
        #expect(result.value == expected, "\(sourceType.rawValue) -> \(targetType.rawValue)")
        #expect(result.outcome == (sourceType == targetType ? .kept : expected == nil ? .cleared : .converted))
        #expect(result.losesInformation == (expected == nil))
    }

    @Test(arguments: FieldType.allCases, FieldType.allCases)
    func emptyAndNoOpConversions(_ sourceType: FieldType, _ targetType: FieldType) throws {
        let source = try field(sourceType, options: options()), target = try field(targetType, options: options())
        for value: PropertyValue? in [nil, .unknown(.null), .string(""), .multi([])] {
            let result = try FieldConversion.convert(value, from: source, to: target, context: context())
            #expect(result.outcome == .empty)
            #expect(!result.losesInformation)
            #expect(result.value == (sourceType == targetType ? value : nil))
        }
        let unknown = PropertyValue.unknown(.object(["future": .integer(42)]))
        #expect(try FieldConversion.convert(unknown, from: source, to: source, context: context()).value == unknown)
        var renamed = source
        renamed.name = "Renamed"
        #expect(try FieldConversion.convert(unknown, from: source, to: renamed, context: context()).value == unknown)
    }

    @Test func parsesNumbersCompletelyAndKeepsDecimalPrecision() throws {
        for text in ["12tail", "1,234", "", "NaN", "inf", "--1", "1.2.3", "1e9999", "1.234567890123456789012345678901234567890123456789"] {
            let result = try FieldConversion.convert(.string(text), from: field(.text), to: field(.number), context: context())
            #expect(result.value == nil, "Input: \(text)")
        }
        let value = Decimal(string: "9007199254740993.125")!
        #expect(try FieldConversion.convert(.string(" 9007199254740993.125 "), from: field(.text), to: field(.number), context: context()).value == .number(value))
        #expect(try FieldConversion.convert(.number(value), from: field(.number), to: field(.text), context: context()).value == .string("9007199254740993.125"))
        #expect(try FieldConversion.convert(.string("-1.25e2"), from: field(.text), to: field(.number), context: context()).value == .number(-125))
        #expect(try FieldConversion.convert(.string(".5"), from: field(.text), to: field(.number), context: context()).value == .number(Decimal(string: "0.5")!))
    }

    @Test func checkboxesDoNotGuessFromNonzeroNumbersOrWords() throws {
        let text = try field(.text), check = try field(.checkbox), number = try field(.number)
        #expect(try FieldConversion.convert(.string(" TRUE "), from: text, to: check, context: context()).value == .checkbox(true))
        #expect(try FieldConversion.convert(.string("False"), from: text, to: check, context: context()).value == .checkbox(false))
        #expect(try FieldConversion.convert(.string("yes"), from: text, to: check, context: context()).outcome == .cleared)
        #expect(try FieldConversion.convert(.number(0), from: number, to: check, context: context()).value == .checkbox(false))
        #expect(try FieldConversion.convert(.number(2), from: number, to: check, context: context()).outcome == .cleared)
        #expect(try FieldConversion.convert(.checkbox(false), from: check, to: number, context: context()).value == .number(0))
    }

    @Test func urlsRequireAnAbsoluteValueButKeepTheirOwnStrings() throws {
        let text = try field(.text), url = try field(.url)
        for string in ["https://example.com/a?b=c", "mailto:hello@example.com", "custom:page"] {
            #expect(try FieldConversion.convert(.string(string), from: text, to: url, context: context()).value == .string(string))
        }
        for string in ["example.com", "/relative", "https://", "https://ex ample.com", "mailto:"] {
            #expect(try FieldConversion.convert(.string(string), from: text, to: url, context: context()).outcome == .cleared)
        }
        #expect(try FieldConversion.convert(.string("relative"), from: url, to: url, context: context()).outcome == .kept)
        #expect(try FieldConversion.convert(.string("relative"), from: url, to: text, context: context()).value == .string("relative"))
    }

    @Test func optionNamesMatchWithoutCreatingOptionsAndIDsSurviveRename() throws {
        let source = try field(.text), target = try field(.select, options: options())
        #expect(try FieldConversion.convert(.string(" ALPHA "), from: source, to: target, context: context()).value == .string("z"))
        #expect(try FieldConversion.convert(.string("new option"), from: source, to: target, context: context()).outcome == .cleared)
        var renamed = target
        renamed.options!["z"]!.name = "Renamed"
        #expect(try FieldConversion.convert(.string("z"), from: target, to: renamed, context: context()).value == .string("z"))
        var remapped = target
        remapped.options!["copy"] = remapped.options!.removeValue(forKey: "z")
        #expect(try FieldConversion.convert(.string("z"), from: target, to: remapped, context: context()).value == .string("copy"))
        var duplicates = target
        duplicates.options!["a"]!.name = "Alpha"
        #expect(try FieldConversion.convert(.string("alpha"), from: source, to: duplicates, context: context()).value == .string("z"))
        #expect(try FieldConversion.convert(.string("Alpha, Beta"), from: source, to: field(.multi, options: options()), context: context()).outcome == .cleared)
    }

    @Test func multiConversionReportsPartialLossAndUsesSourceOptionOrder() throws {
        let source = try field(.multi, options: options())
        let target = try field(.select, options: options())
        let selected = try FieldConversion.convert(.multi(["a", "z"]), from: source, to: target, context: context())
        #expect(selected.value == .string("z"))
        #expect(selected.outcome == .partial)
        let text = try FieldConversion.convert(.multi(["a", "z"]), from: source, to: field(.text), context: context())
        #expect(text.value == .string("Alpha, Beta"))
        #expect(text.outcome == .converted)
        var reduced = source
        reduced.options!.removeValue(forKey: "a")
        let result = try FieldConversion.convert(.multi(["z", "a"]), from: source, to: reduced, context: context())
        #expect(result.value == .multi(["z"]))
        #expect(result.outcome == .partial)
        let invalid = try FieldConversion.convert(.multi(["z", "unknown"]), from: source, to: target, context: context())
        #expect(invalid.outcome == .partial)
        #expect(try FieldConversion.convert(.multi(["unknown"]), from: source, to: target, context: context()).outcome == .cleared)
        #expect(try FieldConversion.convert(.multi(["z", "a"]), from: source, to: field(.number), context: context()).outcome == .cleared)
    }

    @Test func datesKeepTheirZoneAndMetadataOrReportTheirLoss() throws {
        let source = try field(.date)
        var renamed = source
        renamed.name = "Renamed"
        let rich = try date("2026-10-27T09:00", tz: "Australia/Melbourne", end: "2026-10-27T10:30", repeat: .weekly, remind: .before(15))
        #expect(try FieldConversion.convert(.date(rich), from: source, to: renamed, context: context()).value == .date(rich))
        let text = try FieldConversion.convert(.date(rich), from: source, to: field(.text), context: context())
        #expect(text.value == .string("2026-10-27T09:00"))
        #expect(text.outcome == .partial)
        #expect(try FieldConversion.convert(.date(date("2026-10-27")), from: source, to: field(.text), context: context()).outcome == .converted)
        let back = try FieldConversion.convert(text.value, from: field(.text), to: source, context: context(zone: "America/New_York"))
        #expect(back.value == .date(try date("2026-10-27T09:00", tz: "America/New_York")))
        #expect(try FieldConversion.convert(.string("2026-10-27"), from: field(.text), to: source, context: context()).value == .date(date("2026-10-27")))
        #expect(try FieldConversion.convert(.string("2026-02-30"), from: field(.text), to: source, context: context()).outcome == .cleared)
    }

    @Test func fixedFieldsCannotChangeTypeAndTitleIsNotAProperty() throws {
        for (id, source, target) in [(FieldID.title, FieldType.text, FieldType.text),
                                     (FieldID.done, .checkbox, .text), (FieldID.due, .date, .text)] {
            #expect(throws: FieldEngineError.reservedField(id)) {
                try FieldConversion.preview([], fieldID: id, source: field(source), target: field(target), context: context())
            }
        }
        #expect(try FieldConversion.preview([], fieldID: FieldID.done, source: field(.checkbox), target: field(.checkbox), context: context()).lostValueCount == 0)
        #expect(try FieldConversion.preview([], fieldID: FieldID.due, source: field(.date), target: field(.date), context: context()).lostValueCount == 0)
        let unknownZone = try date("2026-10-27T09:00", tz: "Unknown/Zone")
        #expect(try FieldConversion.convert(.date(unknownZone), from: field(.date), to: field(.date), context: context()).value == .date(unknownZone))
        let blankOption = ["blank": FieldOption(name: "", color: .gray, order: try OrderKey("a0"))]
        #expect(try FieldConversion.convert(.string("blank"), from: field(.select, options: blankOption), to: field(.text), context: context()).outcome == .cleared)
    }

    @Test func previewCountsValuesRatherThanLostOptionsAndDoesNotMutateRecords() throws {
        let source = try field(.multi, options: options()), target = try field(.select, options: options())
        let rows = try [item(1, .multi(["z", "a", "b"])), item(2, .multi(["unknown"])),
                        item(3), item(4, .multi(["z"]))]
        let before = rows
        let plan = try FieldConversion.preview(rows, fieldID: "f", source: source, target: target, context: context())
        #expect(plan.lostValueCount == 2)
        #expect(plan.clearedValueCount == 1)
        #expect(plan.items.map(\.result.outcome) == [.partial, .cleared, .empty, .converted])
        #expect(plan.items.map(\.id) == rows.map(\.id))
        #expect(plan.fieldID == "f" && plan.target == target)
        #expect(rows == before)
        #expect(throws: FieldEngineError.unsupportedType(FieldType(rawValue: "future"))) {
            try FieldConversion.preview([], fieldID: "f", source: source, target: field(FieldType(rawValue: "future")), context: context())
        }
    }
}
