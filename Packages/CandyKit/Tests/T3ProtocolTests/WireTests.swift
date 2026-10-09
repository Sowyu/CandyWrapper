import Foundation
import Testing
@testable import T3Protocol

/// Every frame in the recorded transcripts must decode and round-trip.
struct WireTests {
    static let transcripts = ["01-basic", "02-turn", "03-turn2"]

    struct Frame {
        let t: Int
        let dir: String
        let kind: String
        let body: Any
        var bodyData: Data { try! JSONSerialization.data(withJSONObject: body, options: [.fragmentsAllowed]) }
    }

    static func load(_ name: String) throws -> [Frame] {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appending(path: "fixtures/transcripts/\(name).jsonl"), encoding: .utf8)
        return try text.split(separator: "\n").map { line in
            let o = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            return Frame(t: o["t"] as! Int, dir: o["dir"] as! String, kind: o["kind"] as! String, body: o["body"]!)
        }
    }

    @Test(arguments: transcripts)
    func everyWebSocketFrameDecodesAndRoundTrips(_ name: String) throws {
        var server = 0, client = 0
        for frame in try Self.load(name) where frame.kind == "ws" {
            let original = try JSONDecoder().decode(JSONValue.self, from: frame.bodyData)
            let reencoded: Data
            if frame.dir == "recv" {
                let messages = try RPCFrame.decodeServer(frame.bodyData)
                #expect(messages.count == 1)
                for m in messages { if case .unknown = m { Issue.record("unknown server frame at t=\(frame.t)") } }
                reencoded = try RPCFrame.encode(messages[0])
                server += 1
            } else {
                let messages = try RPCFrame.decodeClient(frame.bodyData)
                #expect(messages.count == 1)
                reencoded = try RPCFrame.encode(messages[0])
                client += 1
            }
            #expect(try JSONDecoder().decode(JSONValue.self, from: reencoded) == original, "round trip at t=\(frame.t)")
        }
        #expect(server > 0 && client > 0)
    }

    @Test func requestEncodesExactlyAsRecorded() throws {
        let data = try RPCFrame.encode(.request(RPCRequest(id: .string("1"), tag: "server.getConfig", payload: .object([:]))))
        #expect(String(decoding: data, as: UTF8.self) == #"{"_tag":"Request","headers":[],"id":"1","payload":{},"tag":"server.getConfig"}"#)
        #expect(String(decoding: try RPCFrame.encode(.ack(.string("4"))), as: UTF8.self) == #"{"_tag":"Ack","requestId":"4"}"#)
        #expect(String(decoding: try RPCFrame.encode(.interrupt(.string("4"))), as: UTF8.self) == #"{"_tag":"Interrupt","requestId":"4"}"#)
        #expect(String(decoding: try RPCFrame.encode(.ping), as: UTF8.self) == #"{"_tag":"Ping"}"#)
    }

    @Test func typedFailureFromTranscript() throws {
        let frame = try #require(try Self.load("03-turn2").first { $0.dir == "recv" && $0.t == 35818 })
        let messages = try RPCFrame.decodeServer(frame.bodyData)
        guard case .exit(let id, .failure(let causes)) = messages.first, case .fail(let error) = causes.first else {
            Issue.record("expected Exit Failure Fail, got \(messages)")
            return
        }
        #expect(id == .string("9"))
        #expect(error.tag == "OrchestrationV2DispatchCommandError")
        #expect(error.fields["commandType"]?.stringValue == "run.interrupt")
        #expect(error.message?.contains("is not interruptible") == true)

        struct DispatchError: Decodable { let _tag: String; let commandId: String; let message: String }
        let typed = try error.decode(as: DispatchError.self)
        #expect(typed._tag == "OrchestrationV2DispatchCommandError")
        #expect(!typed.commandId.isEmpty)
    }

    @Test func dieFromTranscript() throws {
        let frames = try Self.load("01-basic").filter { $0.dir == "recv" && $0.kind == "ws" }
        let dies = try frames.flatMap { try RPCFrame.decodeServer($0.bodyData) }.compactMap { m -> JSONValue? in
            if case .exit(_, .failure(let causes)) = m, case .die(let d) = causes.first { return d }
            return nil
        }
        #expect(dies.contains(.string("Unknown request tag: projects.list")))
    }

    @Test func arrayFramesAndUnknownMembers() throws {
        let data = Data(#"""
        [{"_tag":"Pong"},
         {"_tag":"Chunk","requestId":7,"values":[1,{"a":true}]},
         {"_tag":"Exit","requestId":"8","exit":{"_tag":"Failure","cause":[{"_tag":"Interrupt","fiberId":null},{"_tag":"Sequential"}]}},
         {"_tag":"Defect","defect":"boom"},
         {"_tag":"ClientProtocolError","error":{"_tag":"RpcClientError"}},
         {"_tag":"SomethingNew","x":1}]
        """#.utf8)
        let m = try RPCFrame.decodeServer(data)
        #expect(m.count == 6)
        #expect(m[0] == .pong)
        #expect(m[1] == .chunk(requestId: .number(7), values: [.number(1), .object(["a": .bool(true)])]))
        guard case .exit(_, .failure(let causes)) = m[2] else { Issue.record("exit"); return }
        #expect(causes[0] == .interrupt(fiberId: nil))
        if case .unknown = causes[1] {} else { Issue.record("unknown cause should be kept") }
        #expect(m[3] == .defect(.string("boom")))
        if case .unknown = m[5] {} else { Issue.record("unknown message should be kept") }
        // A numeric id must go back out as a number, or the server's ack latch never opens.
        #expect(String(decoding: try RPCFrame.encode(.ack(.number(7))), as: UTF8.self) == #"{"_tag":"Ack","requestId":7}"#)
    }

    @Test(arguments: transcripts)
    func authHTTPBodiesDecode(_ name: String) throws {
        var seen = Set<String>()
        for frame in try Self.load(name) where frame.kind == "http" && frame.dir == "recv" {
            let b = frame.body as! [String: Any]
            guard (b["status"] as? Int) == 200, let path = b["path"] as? String, let body = b["body"] else { continue }
            let data = try JSONSerialization.data(withJSONObject: body)
            switch path {
            case ".well-known/t3/environment":
                let d = try JSONDecoder().decode(EnvironmentDescriptor.self, from: data)
                #expect(d.isCompatible)
                #expect(d.capability("connectionProbe"))
                #expect(!d.capability("serverSelfUpdateProgress"))
            case "oauth/token":
                let t = try JSONDecoder().decode(AccessTokenResult.self, from: data)
                #expect(t.tokenType == "Bearer" && t.expiresIn == 2_592_000)
            case "api/auth/session":
                let s = try JSONDecoder().decode(AuthSessionState.self, from: data)
                #expect(s.authenticated && s.permissions?.contains("orchestration:read") == true)
            case "api/auth/websocket-ticket":
                _ = try JSONDecoder().decode(WebSocketTicket.self, from: data)
            default: continue
            }
            seen.insert(path)
        }
        // 03-turn2 reused a cached token, so it has no oauth/token exchange.
        #expect(seen.count == (name == "03-turn2" ? 3 : 4), "\(seen)")
    }

    @Test func tokenExchangeFormMatchesRecording() throws {
        let frame = try #require(try Self.load("01-basic").first {
            $0.dir == "send" && ($0.body as? [String: Any])?["path"] as? String == "oauth/token"
        })
        let recorded = (frame.body as! [String: Any])["body"] as! String
        let ours = TokenExchangeRequest(subjectToken: "SECRET", clientLabel: "CandyWrapper protocol recorder").formBody
        #expect(String(decoding: ours, as: UTF8.self) == recorded.replacingOccurrences(of: "<secret-0>", with: "SECRET"))
        let tricky = TokenExchangeRequest(subjectToken: "a+b&c=d é").formBody
        #expect(String(decoding: tricky, as: UTF8.self).contains("subject_token=a%2Bb%26c%3Dd%20%C3%A9"))
    }

    @Test func httpErrorBodyDecodes() throws {
        let body = Data(#"{"_tag":"EnvironmentAuthInvalidError","code":"auth_invalid","reason":"invalid_credential","traceId":"t"}"#.utf8)
        let e = try JSONDecoder().decode(EnvironmentHTTPErrorBody.self, from: body)
        #expect(e.tag == "EnvironmentAuthInvalidError" && e.reason == "invalid_credential")
    }
}
