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
