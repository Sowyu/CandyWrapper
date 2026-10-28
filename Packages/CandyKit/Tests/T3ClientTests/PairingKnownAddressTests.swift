import Foundation
import Testing
@testable import T3Client
import T3Transport

private final class KnownAddressProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var paths: [String] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        Self.lock.withLock { Self.paths.append(path) }
        let body = path == "/.well-known/t3/environment"
            ? #"{"environmentId":"env","label":"Studio","serverVersion":"0.1.4-nightly.20261028.3814","orchestrationProtocolVersion":2,"capabilities":{}}"#
            : #"{"access_token":"test-token","expires_in":100,"token_type":"Bearer"}"#
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct PairingKnownAddressTests {
    @Test func unfamiliarAddressIsRejectedBeforeThePairingCodeIsSpent() async throws {
        KnownAddressProtocol.paths = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [KnownAddressProtocol.self]
        let session = URLSession(configuration: config)
        let saved = EnvironmentRegistration(environmentId: "env", label: "Studio", httpBaseURL: URL(string: "https://saved.example")!)
        await #expect(throws: PairingError.self) {
            try await Pairing.pair(host: "https://unknown.example", code: "TESTCODE", identity: ClientIdentity(appVersion: "test"),
                                   knownEnvironments: [saved], session: session)
        }
        #expect(KnownAddressProtocol.paths == ["/.well-known/t3/environment"])
        _ = try await Pairing.pair(host: "https://unknown.example", code: "TESTCODE", expectedEnvironmentId: "env",
                                   identity: ClientIdentity(appVersion: "test"), knownEnvironments: [saved], session: session)
        #expect(KnownAddressProtocol.paths.last == "/oauth/token")
    }
}
