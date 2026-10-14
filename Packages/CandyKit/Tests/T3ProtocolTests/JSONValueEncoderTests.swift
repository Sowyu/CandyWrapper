import Foundation
import Testing
@testable import T3Protocol

/// `JSONValueEncoder` plus `JSONValue.utf8` must produce what JSONEncoder produced, as a tree.
struct JSONValueEncoderTests {
    private func viaJSONEncoder<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONValue(parsing: JSONEncoder().encode(value))
    }

    private func viaTree<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONValue(parsing: JSONValueEncoder().encode(value).utf8)
    }

    @Test(arguments: ["01-basic", "02-turn", "03-turn2", "04-threads"])
    func everyRecordedItemEncodesAsJSONEncoderDoes(_ name: String) throws {
        var tags: [String: String] = [:]
        var typed = 0
        for frame in try WireTests.load(name) where frame.kind == "ws" {
            let data = frame.bodyData
            if frame.dir == "send" {
                if case .request(let r) = try RPCFrame.decodeClient(data)[0], case .string(let id) = r.id { tags[id] = r.tag }
                continue
            }
            guard case .chunk(.string(let id), let values) = try RPCFrame.decodeServer(data)[0] else { continue }
            for value in values {
                switch tags[id] {
                case "orchestration.subscribeThread":
                    guard case .snapshot(let snapshot) = try value.decode(as: ThreadStreamItem.self) else { continue }
                    let p = snapshot.projection
                    #expect(try viaTree(p) == viaJSONEncoder(p), "thread snapshot t=\(frame.t)")
                    #expect(try JSONValue(parsing: JSONValueEncoder().encode(p).utf8).decode(as: ThreadProjection.self) == p)
                case "orchestration.subscribeShell":
                    let item = try value.decode(as: ShellStreamItem.self)
                    #expect(try viaTree(item) == viaJSONEncoder(item), "shell item t=\(frame.t)")
                default: continue
                }
                typed += 1
            }
        }
        #expect(typed > 0)
    }

    struct Empty: Encodable {}

    struct Mixed: Encodable {
        var a: Int? = nil
        var b = [1.5, -0.25, 1e21, 123456789012]
        var c = "quote \" slash \\ newline \n tab \t nul \u{0} bell \u{7} é 🍬 /"
        var d = URL(string: "https://t3.chat/a?b=c")!
        var e = Date(timeIntervalSinceReferenceDate: 12.5)
        var f: [String: [Int?]] = ["x": [1, nil], "y": []]
        var g = Empty()
        var h: JSONValue = .object(["k": .array([.null, .bool(true)])])

        enum Keys: String, CodingKey { case a, b, c, d, e, f, g, h, nested, list }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            try c.encodeIfPresent(a, forKey: .a)
            try c.encode(b, forKey: .b)
            try c.encode(self.c, forKey: .c)
            try c.encode(d, forKey: .d)
            try c.encode(e, forKey: .e)
            try c.encode(f, forKey: .f)
            try c.encode(g, forKey: .g)
            try c.encode(h, forKey: .h)
            var n = c.nestedContainer(keyedBy: Keys.self, forKey: .nested)
            try n.encode(Int64(-7), forKey: .a)
            var l = c.nestedUnkeyedContainer(forKey: .list)
            try l.encode(UInt8(3))
            var inner = l.nestedContainer(keyedBy: Keys.self)
            try inner.encodeNil(forKey: .b)
            try l.encode("last")
            try n.encode(true, forKey: .b)
        }
    }

    @Test func containersAndLeavesMatchJSONEncoder() throws {
        #expect(try viaTree(Mixed()) == viaJSONEncoder(Mixed()))
        #expect(try viaTree(Empty()) == .object([:]))
        #expect(try viaTree("top") == .string("top"))
        #expect(try viaTree([Int]()) == .array([]))
        #expect(throws: EncodingError.self) { try JSONValueEncoder().encode(Double.nan) }
        #expect(throws: EncodingError.self) { try JSONValueEncoder().encode(["x": Double.infinity]) }
        #expect(String(decoding: JSONValue.array([.number(-3), .number(0.5), .number(-0.0)]).utf8, as: UTF8.self) == "[-3,0.5,0]")
    }
}
