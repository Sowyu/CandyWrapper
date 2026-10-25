import Foundation
import Testing
@testable import SpaceModel

private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures/space")

private func data(_ name: String) throws -> Data { try Data(contentsOf: fixtures.appendingPathComponent(name + ".json")) }
private func fixture<T: Decodable>(_ type: T.Type, _ name: String) throws -> T { try SpaceJSON.decode(type, from: data(name)) }
private func zone(_ id: String) -> TimeZone { TimeZone(identifier: id)! }
private func instant(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }
private func point(_ value: String) throws -> DatePoint { try DatePoint(value) }
private func value(_ start: String, _ tz: String? = nil, end: String? = nil, weekly: Bool = false, remind: Reminder? = nil) throws -> DateValue {
    try DateValue(start: point(start), end: end.map(point), tz: tz, repeat: weekly ? .weekly : nil, remind: remind)
}

struct SpaceModelTests {
    @Test func goldenFilesAreByteStable() throws {
        func check<T: Codable>(_ type: T.Type, _ name: String) throws {
            let source = try data(name)
            let decoded = try SpaceJSON.decode(type, from: source)
            let encoded = try SpaceJSON.encode(decoded)
            #expect(encoded == source, "Fixture \(name): \(String(decoding: encoded, as: UTF8.self))")
            #expect(try SpaceJSON.encode(SpaceJSON.decode(type, from: encoded)) == source)
        }
        try check(SnapshotPayload.self, "snapshot")
        try check([DateValue].self, "dates")
        try check(OpPayload.self, "op")
        try check(LogFrame.self, "frame")
        try check(SpaceHeader.self, "header")
        try check(EncryptedSnapshot.self, "encrypted-snapshot")
        try check([Filter].self, "filters")
        try check(JSONValue.self, "order-keys")
    }

    @Test func everyRecordFieldAndViewHasATypedRepresentation() throws {
        let snapshot = try fixture(SnapshotPayload.self, "snapshot")
        let parent = try #require(snapshot.pages.values.first { $0.parent == nil })
        let child = try #require(snapshot.pages.values.first { $0.title == "Bring milk 🥛" })
        #expect(Set(parent.fields.values.map(\.type)).isSuperset(of: Set(FieldType.allCases)))
        #expect(parent.iconImage?.name == "photo.png")
        #expect(parent.titleName == "Item")
        #expect(parent.views.table?.titleHidden == true)
        #expect(child.icon == "🖼️")
        let attachments = snapshot.pages.values.compactMap { page -> [BlobReference]? in
            guard case .files(let files) = page.props["files"] else { return nil }
            return files
        }.flatMap { $0 }
        #expect(Set(attachments.map(\.name)) == ["photo.png", "logo.svg"])
        #expect(attachments.allSatisfy { $0.mime == "image/png" && $0.w != nil && $0.h != nil })
        #expect(parent.isTodoList)
        #expect(!child.isTodoList)
        #expect(parent.fields[FieldID.done]?.name == "Done")
        #expect(parent.fields[FieldID.due]?.type == .date)
        #expect(child.props["description"] == .string("Whole milk"))
        #expect(child.props["score"] == .number(Decimal(string: "12.5")!))
        #expect(child.props["done"] == .checkbox(false))
        #expect(child.props["status"] == .string("o1"))
        #expect(child.props["labels"] == .multi(["o2", "o3"]))
        #expect(child.props["due"] == .date(try value("2026-10-27")))
        #expect(child.props["website"] == .string("https://example.com"))
        #expect(child.props["future"] == .unknown(.object(["rating": .integer(4)])))
        #expect(Set(parent.fields["status"]!.options!.values.map(\.color)) == Set(FieldColor.allCases))
        #expect(Set(snapshot.blocks.values.map(\.type)) == Set(BlockType.allCases))
        #expect(parent.views.board?.group == "status")
        #expect(parent.views.board?.sort.count == 2)
        #expect(parent.views.table?.cols[0].field == FieldID.title)
        #expect(parent.views.table?.cols[1].width == 120.5)
        #expect(parent.views.timetable?.days == 5)
        #expect(parent.views.page?.extra["future"] == .object(["visible": .bool(true)]))
        let image = try #require(snapshot.blocks.values.first { $0.type == .image })
        #expect(image.blob?.w == 640 && image.blob?.h == 480)
        #expect(image.blob?.preview == String(repeating: "b", count: 64))
        #expect(image.width == 320.5)
        #expect(snapshot.blocks.values.first { $0.type == .quote }?.conflict?.device == "Sandbox phone")
        for block in snapshot.blocks.values { try block.validate() }
    }

    @Test func unknownKeysAndNullsSurviveEdits() throws {
        var snapshot = try fixture(SnapshotPayload.self, "snapshot")
        let id = try #require(snapshot.pages.first { $0.value.parent == nil }?.key)
        let unknown = snapshot.pages[id]!.extra
        snapshot.pages[id]!.title = "Changed"
        snapshot.pages[id]!.fields["status"]!.name = "Phase"
        let result = try SpaceJSON.decode(SnapshotPayload.self, from: SpaceJSON.encode(snapshot))
        #expect(result.pages[id]?.extra == unknown)
        #expect(result.pages[id]?.extra["future"] == .object(["huge": .integer(9007199254740993), "nested": .array([.null, .bool(true), .string("kept")])]))
        #expect(result.pages[id]?.fields["future"]?.type.rawValue == "rating")
        #expect(result.pages[id]?.fields["future"]?.extra["scale"] == .integer(5))
        let absent = try SpaceJSON.decode(DateValue.self, from: Data(#"{"start":"2026-10-27"}"#.utf8))
        let explicit = try SpaceJSON.decode(DateValue.self, from: Data(#"{"repeat":null,"start":"2026-10-27"}"#.utf8))
        #expect(try SpaceJSON.encode(absent) == Data(#"{"start":"2026-10-27"}"#.utf8))
        #expect(try SpaceJSON.encode(explicit) == Data(#"{"repeat":null,"start":"2026-10-27"}"#.utf8))
        let frame = try fixture(LogFrame.self, "frame")
        #expect(frame.recs.map(\.base) == [805, nil])
        #expect(frame.extra["future"] == .integer(9007199254740993))
    }

    @Test func richTextUsesUTF16AndSortsMarks() throws {
        let snapshot = try fixture(SnapshotPayload.self, "snapshot")
        let rich = try #require(snapshot.blocks.values.first { $0.type == .p }?.text)
        #expect(rich.t.count == 19 && rich.t.utf16.count == 20)
        #expect(Set(rich.m.map(\.kind)) == Set(MarkKind.allCases))
        #expect((rich.t as NSString).substring(with: NSRange(location: 0, length: 2)) == "😀")
        var unsorted = rich; unsorted.m.reverse()
        #expect(try SpaceJSON.encode(unsorted) == SpaceJSON.encode(rich))
        #expect(throws: ModelError.invalidMark) { try RichText(t: "😀", m: [.init(start: 0, end: 3, kind: .b)]).validate() }
        #expect(throws: ModelError.invalidMark) { try RichText(t: "Hi", m: [.init(start: 0, end: 2, kind: .a)]).validate() }
        #expect(throws: (any Error).self) { try SpaceJSON.decode(TextMark.self, from: Data("[0,2,\"b\",\"x\",1]".utf8)) }
    }

    @Test func idsAreLowercaseV4AndSupplyHKDFSaltBytes() throws {
        let id = try SpaceID("00112233-4455-4677-8899-aabbccddeeff")
        #expect(id.bytes == [0x00,0x11,0x22,0x33,0x44,0x55,0x46,0x77,0x88,0x99,0xaa,0xbb,0xcc,0xdd,0xee,0xff])
        #expect(try SpaceJSON.decode(SpaceID.self, from: SpaceJSON.encode(id)) == id)
        #expect(try SpaceID(SpaceID().rawValue).rawValue.count == 36)
        for invalid in [id.rawValue.uppercased(), "00112233-4455-1677-8899-aabbccddeeff", "00112233-4455-4677-7899-aabbccddeeff", "not-an-id"] {
            #expect(throws: ModelError.invalidID(invalid)) { try SpaceID(invalid) }
        }
    }

    @Test func orderKeysMatchGoldenVectors() throws {
        let vectors = try fixture([[String?]].self, "order-keys")
        for vector in vectors {
            let lower = try vector[0].map(OrderKey.init), upper = try vector[1].map(OrderKey.init)
            let key = try OrderKey.between(lower, upper)
            #expect(key.rawValue == vector[2])
            #expect(lower.map { $0 < key } ?? true)
            #expect(upper.map { key < $0 } ?? true)
        }
        let ascii = try ["z", "a", "Z", "A", "9", "0"].map(OrderKey.init).sorted().map(\.rawValue)
        #expect(ascii == ["0", "9", "A", "Z", "a", "z"])
        let low = try SpaceID("00000000-0000-4000-8000-000000000001")
        let high = try SpaceID("00000000-0000-4000-8000-000000000002")
        #expect(RecordPosition(order: try OrderKey("a0"), id: low) < RecordPosition(order: try OrderKey("a0"), id: high))
        #expect(throws: ModelError.noKeyBetween) { try OrderKey.between(OrderKey("a0"), OrderKey("a0")) }
        #expect(throws: ModelError.noKeyBetween) { try OrderKey.between(OrderKey("0"), OrderKey("00")) }
        for invalid in ["", "a!", "é", "a 0"] { #expect(throws: ModelError.invalidOrderKey(invalid)) { try OrderKey(invalid) } }
    }

    @Test func repeatedInsertionsStayStrictlyBetweenNeighbors() throws {
        var keys: [OrderKey] = []
        for i in 0..<1500 {
            let index = i % 3 == 0 ? 0 : i % 3 == 1 ? keys.count : keys.count / 2
            let lower = index > 0 ? keys[index - 1] : nil
            let upper = index < keys.count ? keys[index] : nil
            let key = try OrderKey.between(lower, upper)
            #expect(lower.map { $0 < key } ?? true)
            #expect(upper.map { key < $0 } ?? true)
            keys.insert(key, at: index)
        }
        #expect(keys == keys.sorted())
        #expect(Set(keys).count == 1500)
        for pair in [("0","1"),("0","00V"),("abc","abd"),("9","A")] {
            let key = try OrderKey.between(OrderKey(pair.0), OrderKey(pair.1))
            #expect(try OrderKey(pair.0) < key && key < OrderKey(pair.1))
        }
    }

    @Test func invalidRecordAndViewShapesFailAtCodingBoundary() throws {
        let id = SpaceID()
        let key = try OrderKey("a0")
        let invalid = BlockRecord(page: id, order: key, indent: 6)
        #expect(throws: ModelError.invalidIndent) { try SpaceJSON.encode(invalid) }
        let sorting = Array(repeating: Sort(field: "title"), count: 4)
        #expect(throws: ModelError.invalidViewSettings) { try SpaceJSON.encode(BoardViewSettings(group: "status", sort: sorting)) }
        #expect(throws: ModelError.invalidViewSettings) { try SpaceJSON.encode(TableViewSettings(sort: sorting)) }
        #expect(throws: ModelError.invalidViewSettings) { try SpaceJSON.encode(TimetableViewSettings(field: "due", days: 6)) }
        for suffix in ["", ",null,0"] {
            #expect(throws: (any Error).self) { try SpaceJSON.decode(RecordRevision.self, from: Data(("[\"" + id.rawValue + "\"" + suffix + "]").utf8)) }
        }
        let numbers = Data(#"[9007199254740993,18446744073709551615,12.5]"#.utf8)
        #expect(try SpaceJSON.encode(SpaceJSON.decode(JSONValue.self, from: numbers)) == numbers)
        #expect(FieldDefinition.done(order: key).type == .checkbox)
        #expect(FieldDefinition.due(order: key).name == "Due")
    }

    @Test func dateFormsRejectMixedOrImplicitZones() throws {
        for invalid in ["2026-02-29", "2026-13-01", "2026-10-00", "2026-10-27T24:00", "2026-10-27T09:60", "2026-10-27T09:00Z", "2026-1-02", "0000-01-01"] {
            #expect(throws: ModelError.invalidDate(invalid)) { try DatePoint(invalid) }
        }
        #expect(throws: ModelError.invalidDateValue) { try value("2026-10-27T09:00") }
        #expect(throws: ModelError.invalidDateValue) { try value("2026-10-27", "Europe/London") }
        #expect(throws: ModelError.invalidDateValue) { try value("2026-10-27", end: "2026-10-27T10:30") }
        #expect(throws: ModelError.invalidDateValue) { try value("2026-10-27T09:00", "Europe/London", end: "2026-10-27") }
        #expect(throws: ModelError.invalidDateValue) { try value("2026-10-27", end: "2026-10-26") }
        var edited = try value("2026-10-27T09:00", "Europe/London")
        edited.tz = nil
        #expect(throws: ModelError.invalidDateValue) {
            try edited.settingTime(start: instant("2026-10-27T12:00:00Z"), deviceTimeZone: zone("Europe/London"))
        }
        _ = try DatePoint("2028-02-29")
    }

    @Test func timedValuesDisplayInDeviceZoneAndEditsKeepStoredZone() throws {
        let london = zone("Europe/London")
        let meeting = try value("2026-10-27T09:00", "Australia/Melbourne", end: "2026-10-27T10:30")
        let occurrence = try #require(try meeting.occurrence(deviceTimeZone: london))
        #expect(occurrence.start == instant("2026-10-26T22:00:00Z"))
        #expect(try DatePoint.from(occurrence.start, in: london).rawValue == "2026-10-26T22:00")
        #expect(occurrence.end?.timeIntervalSince(occurrence.start) == 5400.0)
        let edited = try meeting.settingTime(start: instant("2026-10-27T12:00:00Z"), deviceTimeZone: london)
        #expect(edited.tz == "Australia/Melbourne")
        #expect(edited.start.rawValue == "2026-10-27T23:00")
        let allDay = try value("2026-10-27")
        let newTimed = try allDay.settingTime(start: instant("2026-10-27T12:00:00Z"), deviceTimeZone: london)
        #expect(newTimed.tz == london.identifier && newTimed.start.rawValue == "2026-10-27T12:00")
        let unknown = try value("2026-10-27T09:00", "Future/Unknown")
        #expect(try unknown.occurrence(deviceTimeZone: london)?.start == instant("2026-10-27T09:00:00Z"))
        #expect(try unknown.settingTime(start: occurrence.start, deviceTimeZone: london).tz == "Future/Unknown")
        #expect(try SpaceJSON.encode(unknown) == Data(#"{"start":"2026-10-27T09:00","tz":"Future/Unknown"}"#.utf8))
    }

    @Test func gapAndOverlapMatchJavaTimeIncludingHalfHourGap() throws {
        #expect(try point("2026-03-08T02:30").resolved(in: zone("America/New_York")) == instant("2026-03-08T07:30:00Z"))
        #expect(try point("2026-11-01T01:30").resolved(in: zone("America/New_York")) == instant("2026-11-01T05:30:00Z"))
        #expect(try point("2026-10-04T02:15").resolved(in: zone("Australia/Lord_Howe")) == instant("2026-10-03T15:45:00Z"))
        #expect(try point("2011-12-30T12:00").resolved(in: zone("Pacific/Apia")) == instant("2011-12-30T22:00:00Z"))
    }

    @Test func weeklyStartsStayInOriginalZoneAndKeepFirstElapsedLength() throws {
        let london = zone("Europe/London")
        let slot = try value("2026-09-27T09:00", "Australia/Melbourne", end: "2026-09-27T10:30", weekly: true)
        let first = try #require(try slot.occurrence(0, deviceTimeZone: london))
        let next = try #require(try slot.occurrence(1, deviceTimeZone: london))
        #expect(first.start == instant("2026-09-26T23:00:00Z"))
        #expect(next.start == instant("2026-10-03T22:00:00Z"))
        #expect(next.end?.timeIntervalSince(next.start) == 5400.0)
        let crossesGap = try value("2026-03-08T01:30", "America/New_York", end: "2026-03-08T03:30", weekly: true)
        let after = try #require(try crossesGap.occurrence(1, deviceTimeZone: london))
        #expect(after.start == instant("2026-03-15T05:30:00Z"))
        #expect(after.end == instant("2026-03-15T06:30:00Z"))
        #expect(try value("2026-10-27").occurrence(1, deviceTimeZone: london) == nil)
        #expect(try slot.occurrence(-1, deviceTimeZone: london) == nil)
    }

    @Test func allDayDatesAndRemindersUseEachDevicesCurrentZone() throws {
        let allDay = try value("2026-10-27", end: "2026-10-29", weekly: true, remind: .before(15))
        for id in ["Europe/London", "Australia/Melbourne", "America/Los_Angeles"] {
            let device = zone(id)
            let first = try #require(try allDay.occurrence(deviceTimeZone: device))
            let next = try #require(try allDay.occurrence(1, deviceTimeZone: device))
            #expect(first.allDay && next.allDay)
            #expect(try DatePoint.from(first.start, in: device, timed: false).rawValue == "2026-10-27")
            #expect(try DatePoint.from(next.start, in: device, timed: false).rawValue == "2026-11-03")
            #expect(try DatePoint.from(#require(next.end), in: device, timed: false).rawValue == "2026-11-05")
            #expect(try DatePoint.from(#require(try allDay.reminderInstant(deviceTimeZone: device)), in: device).rawValue == "2026-10-27T08:45")
            let explicit = try value("2026-10-27", remind: .at(point("2026-10-27T08:15")))
            #expect(try DatePoint.from(#require(try explicit.reminderInstant(deviceTimeZone: device)), in: device).rawValue == "2026-10-27T08:15")
        }
        let timed = try value("2026-10-27T09:00", "Australia/Melbourne", remind: .before(15))
        #expect(try timed.reminderInstant(deviceTimeZone: zone("Europe/London")) == instant("2026-10-26T21:45:00Z"))
        let explicitTimed = try value("2026-10-27T09:00", "Australia/Melbourne", remind: .at(point("2026-10-27T08:00")))
        #expect(try explicitTimed.reminderInstant(deviceTimeZone: zone("Europe/London")) == instant("2026-10-26T21:00:00Z"))
    }
}

extension SpaceModelTests {
    @Test func filesUseUntaggedBlobArraysAndKeepUnknownShapes() throws {
        let blob = BlobReference(id: "blob", preview: "preview", name: "photo.png", mime: "image/png", size: 2048, w: 640, h: 480,
                                 extra: ["future": .bool(true)])
        let files = PropertyValue.files([blob])
        #expect(try SpaceJSON.decode(PropertyValue.self, from: SpaceJSON.encode(files)) == files)
        #expect(try SpaceJSON.encode(PropertyValue.files([])) == Data("[]".utf8))
        #expect(try SpaceJSON.decode(PropertyValue.self, from: Data("[]".utf8)) == .multi([]))
        #expect(try SpaceJSON.decode(PropertyValue.self, from: Data(#"["option"]"#.utf8)) == .multi(["option"]))
        for raw in [#"[{"name":"incomplete"}]"#, #"[{"id":"x"},"mixed"]"#] {
            let decoded = try SpaceJSON.decode(PropertyValue.self, from: Data(raw.utf8))
            #expect(decoded == .unknown(try SpaceJSON.decode(JSONValue.self, from: Data(raw.utf8))))
            #expect(try SpaceJSON.encode(decoded) == Data(raw.utf8))
        }
    }

    @Test func pageMediaAndTitleKeysPreserveMissingNullAndSet() throws {
        let old = Data(#"{"created":0,"fields":{},"icon":"📝","order":"a0","parent":null,"props":{},"title":"Old","trashed":false,"trashedAt":null,"view":"page","views":{}}"#.utf8)
        let oldPage = try SpaceJSON.decode(PageRecord.self, from: old)
        #expect(oldPage.iconImage == nil && oldPage.titleName == nil)
        #expect(try SpaceJSON.encode(oldPage) == old)
        let blob = BlobReference(id: "image", name: "logo.svg", mime: "image/png", size: 123, w: 128, h: 128)
        for present in [false, true] {
            var object = try SpaceJSON.decode([String: JSONValue].self, from: old)
            object["iconImage"] = present ? try SpaceJSON.decode(JSONValue.self, from: SpaceJSON.encode(blob)) : .null
            object["titleName"] = present ? .string("Task") : .null
            let bytes = try SpaceJSON.encode(object)
            let page = try SpaceJSON.decode(PageRecord.self, from: bytes)
            #expect(page.iconImage == (present ? blob : nil))
            #expect(page.titleName == (present ? "Task" : nil))
            #expect(page.icon == "📝") // Decoding preserves both; readers prefer the image.
            #expect(try SpaceJSON.encode(page) == bytes)
        }
        let constructed = PageRecord(order: try OrderKey("a0"), iconImage: blob, titleName: "Task", created: 0)
        let encoded = try SpaceJSON.encode(constructed)
        let decoded = try SpaceJSON.decode(PageRecord.self, from: encoded)
        #expect(decoded.iconImage == blob && decoded.titleName == "Task")
        #expect(try SpaceJSON.encode(decoded) == encoded)
    }

    @Test func titleHiddenDefaultsToFalseAndOnlyTrueIsEncoded() throws {
        let base = #"{"cols":[],"filter":[],"sort":[]}"#
        for suffix in ["", #", "titleHidden":null"#, #", "titleHidden":false"#, #", "titleHidden":true"#] {
            let raw = String(base.dropLast()) + suffix + "}"
            let settings = try SpaceJSON.decode(TableViewSettings.self, from: Data(raw.utf8))
            #expect(settings.titleHidden == suffix.contains("true"))
            let expected = settings.titleHidden ? #"{"cols":[],"filter":[],"sort":[],"titleHidden":true}"# : base
            #expect(try SpaceJSON.encode(settings) == Data(expected.utf8))
        }
        #expect(try SpaceJSON.decode(TableViewSettings.self, from: SpaceJSON.encode(TableViewSettings(titleHidden: true))).titleHidden)
    }
}
