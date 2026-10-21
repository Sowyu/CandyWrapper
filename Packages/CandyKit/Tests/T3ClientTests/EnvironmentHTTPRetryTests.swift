import Foundation
import Testing
@testable import T3Client

/// Answers 401 to the first request and 200 `{}` after, recording each request's Authorization header.
final class RefuseOnceProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var seen: [String] = []
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let count = Self.lock.withLock { () -> Int in
            Self.seen.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
            return Self.seen.count
        }
        let status = count == 1 ? 401 : 200
        let body = count == 1 ? #"{"_tag":"EnvironmentAuthInvalidError","reason":"invalid_credential"}"# : "{}"
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Serves `body` for any request, with or without a Content-Length header.
final class OversizedAssetProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var declareLength = true
    static let body = Data(repeating: 0x41, count: 64 * 1024)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let headers = Self.declareLength ? ["Content-Length": "\(Self.body.count)"] : [:]
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!,
                            cacheStoragePolicy: .notAllowed)
        for start in stride(from: 0, to: Self.body.count, by: 8 * 1024) {
            client?.urlProtocol(self, didLoad: Self.body.subdata(in: start..<min(start + 8 * 1024, Self.body.count)))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct EnvironmentHTTPAssetLimitTests {
    func http() -> EnvironmentHTTP {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OversizedAssetProtocol.self]
        return EnvironmentHTTP(baseURL: URL(string: "https://host.example")!, session: URLSession(configuration: config))
    }

    @Test(arguments: [true, false]) func refusesBodiesOverTheLimit(declared: Bool) async throws {
        OversizedAssetProtocol.declareLength = declared
        await #expect(throws: EnvironmentHTTPError.self) { _ = try await http().asset("/api/assets/t/icon.png", token: nil, maxBytes: 16 * 1024) }
    }

    @Test func acceptsBodiesWithinTheLimit() async throws {
        OversizedAssetProtocol.declareLength = false
        let data = try await http().asset("/api/assets/t/icon.png", token: nil, maxBytes: 64 * 1024)
        #expect(data == OversizedAssetProtocol.body)
    }
}

struct EnvironmentHTTPRetryTests {
    /// A refused DPoP token is replaced once: the second call asks with `rejected` and gets a new token.
    @Test func a401RetriesOnceWithAFreshToken() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RefuseOnceProtocol.self]
        var http = EnvironmentHTTP(baseURL: URL(string: "https://tunnel.example")!, session: URLSession(configuration: config))
        let asked = Asked()
        http.authorize = { _, _, rejected in
            await asked.add(rejected)
            return ["Authorization": rejected == nil ? "DPoP old" : "DPoP new"]
        }
        try await http.revokeClient(sessionId: "s", token: "")
        #expect(await asked.values == [nil, "old"])
        #expect(RefuseOnceProtocol.lock.withLock { RefuseOnceProtocol.seen } == ["DPoP old", "DPoP new"])
    }

    actor Asked {
        var values: [String?] = []
        func add(_ v: String?) { values.append(v) }
    }
}
