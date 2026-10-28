import Foundation
import Testing
import T3Protocol
@testable import T3Transport

private final class SessionTimeoutProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var timeouts: [TimeInterval] = []
    nonisolated(unsafe) static var failure: URLError.Code = .timedOut
    nonisolated(unsafe) static var failures = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let fail = Self.lock.withLock {
            Self.timeouts.append(request.timeoutInterval)
            return Self.timeouts.count <= Self.failures
        }
        if fail { client?.urlProtocol(self, didFailWithError: URLError(Self.failure)); return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"authenticated":false,"auth":{"policy":"required","bootstrapMethods":[],"sessionMethods":[]}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct SessionTimeoutTests {
    func http(failures: Int, error: URLError.Code = .timedOut) -> EnvironmentHTTP {
        SessionTimeoutProtocol.timeouts = []; SessionTimeoutProtocol.failures = failures; SessionTimeoutProtocol.failure = error
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SessionTimeoutProtocol.self]
        return EnvironmentHTTP(baseURL: URL(string: "https://host.example")!, session: URLSession(configuration: config))
    }

    @Test func slowHostRetriesWithDoubledDeadlines() async throws {
        let state = try await http(failures: 3).session(token: "test")
        #expect(!state.authenticated)
        #expect(SessionTimeoutProtocol.timeouts == [10, 20, 40, 60])
    }
    @Test func givesUpAt60SecondsAndDoesNotRetryOtherErrors() async {
        await #expect(throws: EnvironmentHTTPError.self) { try await http(failures: 9).session(token: "test") }
        #expect(SessionTimeoutProtocol.timeouts == [10, 20, 40, 60])
        await #expect(throws: EnvironmentHTTPError.self) { try await http(failures: 9, error: .cannotConnectToHost).session(token: "test") }
        #expect(SessionTimeoutProtocol.timeouts == [10])
    }
}
