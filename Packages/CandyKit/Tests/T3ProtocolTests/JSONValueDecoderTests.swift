import Foundation
import Testing
@testable import T3Protocol

/// The one-parse path (JSONSerialization + JSONValueDecoder) must decode exactly what the old
/// JSONDecoder path decoded.
struct JSONValueDecoderTests {
    /// Old path: JSON text through JSONDecoder.
    private func old<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T { try JSONDecoder().decode(T.self, from: data) }
    /// New path: one parse, then the tree decoder.
    private func new<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T { try JSONValue(parsing: data).decode(as: T.self) }

    @Test(arguments: ["01-basic", "02-turn", "03-turn2", "04-threads"])
    func everyRecordedFrameDecodesTheSameThroughBothPaths(_ name: String) throws {
        var tags: [String: String] = [:]
        var typed = 0
        for frame in try WireTests.load(name) where frame.kind == "ws" {
            let data = frame.bodyData
            #expect(try new(JSONValue.self, data) == old(JSONValue.self, data), "tree at t=\(frame.t)")
            if frame.dir == "send" {
                #expect(try RPCFrame.decodeClient(data) == [old(RPCClientMessage.self, data)], "client t=\(frame.t)")
                if case .request(let r) = try RPCFrame.decodeClient(data)[0], case .string(let id) = r.id { tags[id] = r.tag }
                continue
            }
            let messages = try RPCFrame.decodeServer(data)
            #expect(messages == [try old(RPCServerMessage.self, data)], "server t=\(frame.t)")
            guard case .chunk(.string(let id), let values) = messages[0] else { continue }
            for value in values {
                let text = try JSONEncoder().encode(value)
                switch tags[id] {
                case "orchestration.subscribeThread":
                    let a = try old(ThreadStreamItem.self, text), b = try value.decode(as: ThreadStreamItem.self)
                    #expect(a == b, "thread item t=\(frame.t)")
                    // TurnItem equality is `raw` only, so compare the typed snapshot fields too.
                    if case .snapshot(let sa) = a, case .snapshot(let sb) = b {
                        #expect(sa.projection.turnItems.map(\.updatedAt.epochMs) == sb.projection.turnItems.map(\.updatedAt.epochMs))
                        #expect(sa.projection.turnItems.map(\.ordinal) == sb.projection.turnItems.map(\.ordinal))
                    }
                case "orchestration.subscribeShell":
                    #expect(try old(ShellStreamItem.self, text) == value.decode(as: ShellStreamItem.self), "shell item t=\(frame.t)")
                default: continue
                }
                typed += 1
            }
        }
        #expect(typed > 0)
    }

    @Test func booleansStayBooleansAndNumbersStayNumbers() throws {
        let v = try JSONValue(parsing: Data(#"[true, false, 1, 0, -0, 1.5, 1e3, 18446744073709551615, "1", null]"#.utf8))
        #expect(v == .array([.bool(true), .bool(false), .number(1), .number(0), .number(0), .number(1.5),
                             .number(1000), .number(Double(UInt64.max)), .string("1"), .null]))
        #expect(v == (try old(JSONValue.self, Data(#"[true, false, 1, 0, -0, 1.5, 1e3, 18446744073709551615, "1", null]"#.utf8))))
    }

    struct Leaf<T: Decodable & Equatable>: Decodable, Equatable { var v: T }

    /// Both paths must succeed with the same value or fail with the same DecodingError case.
    private func agree<T: Decodable & Equatable>(_ type: T.Type, _ json: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let data = Data(json.utf8)
        let a = Result { try old(T.self, data) }, b = Result { try new(T.self, data) }
        switch (a, b) {
        case (.success(let x), .success(let y)): #expect(x == y, "\(json)", sourceLocation: sourceLocation)
        case (.failure(let x as DecodingError), .failure(let y as DecodingError)):
            #expect(kind(x) == kind(y), "\(json): \(x) vs \(y)", sourceLocation: sourceLocation)
            // JSONDecoder reports an out-of-range integer with an empty path; ours names the key.
            if !x.path.isEmpty { #expect(x.path == y.path, "\(json): \(x) vs \(y)", sourceLocation: sourceLocation) }
        default: Issue.record("\(json) as \(T.self): old \(a), new \(b)", sourceLocation: sourceLocation)
        }
    }

    private func kind(_ e: DecodingError) -> String {
        switch e {
        case .typeMismatch: "typeMismatch"
        case .valueNotFound: "valueNotFound"
        case .keyNotFound: "keyNotFound"
        case .dataCorrupted: "dataCorrupted"
        @unknown default: "other"
        }
    }

    @Test func leafConversionsMatchJSONDecoder() {
        for json in [#"{"v":true}"#, #"{"v":1}"#, #"{"v":0}"#, #"{"v":"true"}"#, #"{"v":null}"#, #"{}"#] { agree(Leaf<Bool>.self, json) }
        for json in [#"{"v":1}"#, #"{"v":1.0}"#, #"{"v":1e3}"#, #"{"v":-7}"#, #"{"v":true}"#, #"{"v":"1"}"#] { agree(Leaf<Int>.self, json) }
        for json in [#"{"v":300}"#, #"{"v":-1}"#, #"{"v":255}"#] { agree(Leaf<UInt8>.self, json) }
        for json in [#"{"v":1.5}"#, #"{"v":2}"#, #"{"v":false}"#, #"{"v":null}"#] { agree(Leaf<Double>.self, json) }
        for json in [#"{"v":"x"}"#, #"{"v":2}"#, #"{"v":[]}"#, #"{"v":null}"#] { agree(Leaf<String>.self, json) }
        for json in [#"{"v":[1,2,null]}"#, #"{"v":[1,"a"]}"#] { agree(Leaf<[Int?]>.self, json) }
        for json in [#"{"v":"https://t3.chat/a?b=c"}"#, #"{"v":1}"#] { agree(Leaf<URL>.self, json) }
        agree(Leaf<[String: Int]>.self, #"{"v":{"a":1,"b":2}}"#)
        agree(Leaf<Leaf<Int>>.self, #"{"v":null}"#)
        agree(Leaf<[Int]>.self, #"{"v":null}"#)
        agree(Leaf<Date>.self, #"{"v":1700000000.5}"#)
    }

    struct Nested: Decodable, Equatable {
        var a: Int??
        var b: [Leaf<Int>]?
        var c: Tristate<String>
        var d: JSONValue?

        enum CodingKeys: CodingKey { case a, b, c, d }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            a = try c.decodeIfPresent(Int?.self, forKey: .a)
            b = try c.decodeIfPresent([Leaf<Int>].self, forKey: .b)
            self.c = try c.decode(Tristate<String>.self, forKey: .c)
            d = try c.decodeIfPresent(JSONValue.self, forKey: .d)
        }
    }

    @Test func optionalsUnknownFieldsAndErrorPaths() {
        agree(Nested.self, #"{}"#)
        agree(Nested.self, #"{"a":null,"c":null,"d":null}"#)
        agree(Nested.self, #"{"a":3,"b":[{"v":1},{"v":2,"extra":[1,{"x":true}]}],"c":"s","d":{"k":[1,"2",false]},"zz":9}"#)
        // Errors: the path must name the same element.
        agree(Nested.self, #"{"b":[{"v":1},{"w":2}]}"#)
        agree(Nested.self, #"{"b":[{"v":1},{"v":"2"}]}"#)
        agree(Nested.self, #"{"b":[{"v":1},{"v":null}]}"#)
        agree(Nested.self, #"{"c":5}"#)
        agree(Nested.self, #"[]"#)
        agree(Nested.self, #"{"a":1"#)
    }

    @Test func rawTakesTheNodeAndStillWorksWithJSONDecoder() throws {
        let json = #"{"id":"i1","threadId":"t1","type":"user_message","ordinal":5,"status":"completed","updatedAt":"2026-01-01T00:00:00.000Z","text":"hi","streaming":true,"n":1}"#
        let viaTree = try new(TurnItem.self, Data(json.utf8))
        let viaText = try old(TurnItem.self, Data(json.utf8))
        #expect(viaTree.raw == viaText.raw)
        #expect(viaTree.streaming && viaTree.text == "hi" && viaTree.raw["n"] == .number(1))
        #expect(try TurnItem(json: viaTree.raw).raw == viaTree.raw)
    }

    @Test func canonicalTimestampsMatchTheFormatter() {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var rng = SystemRandomNumberGenerator()
        for i in 0..<5000 {
            let ms = i < 10 ? [0, 951_782_400_000, 4_107_542_399_999, 1_709_164_800_123][i % 4] : Int64.random(in: 0..<4_200_000_000_000, using: &rng)
            let raw = f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
            #expect(T3Timestamp.canonicalEpochMs(raw) == ms, "\(raw)")
            #expect(T3Timestamp.canonicalEpochMs(String(raw.dropLast(5)) + "Z") == ms / 1000 * 1000, "\(raw)")
        }
        // Not canonical: left to the formatters.
        for raw in ["2026-02-30T00:00:00.000Z", "2026-04-07T24:00:00.000Z", "2026-04-07T12:00:00.000+00:00",
                    "1500-01-01T00:00:00.000Z", "2026-04-07 12:00:00.000Z", "not-a-date-not-a-date123"] {
            #expect(T3Timestamp.canonicalEpochMs(raw) == nil, "\(raw)")
        }
    }
}

private extension DecodingError {
    var path: [String] {
        let context: Context? = switch self {
        case .typeMismatch(_, let c), .valueNotFound(_, let c), .dataCorrupted(let c): c
        case .keyNotFound(let k, let c): Context(codingPath: c.codingPath + [k], debugDescription: "")
        @unknown default: nil
        }
        return context?.codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue } ?? []
    }
}
