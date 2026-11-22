import Foundation
import Testing
@testable import Features

private final class ChunkResponse: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                    headerFields: ["Content-Length": "1"])!
        client?.urlProtocol(self, didReceive: reply, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data([1]))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

struct MediaTransferTests {
    @Test func cancellationCleansUpAfterTheActiveDelegateReturns() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ChunkResponse.self]
        let transfer = MediaTransfer(config: config, temporaryDirectory: folder)
        defer { transfer.invalidate() }
        let (started, progress) = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let download = Task {
            defer { progress.finish() }
            return await transfer.download(URL(string: "https://fixture.invalid/image")!) { _, _ in
                progress.yield()
                _ = release.wait(timeout: .now() + 10)
            }
        }
        for await _ in started { break }
        download.cancel()
        let partialFiles = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        release.signal()
        #expect(await download.value == nil)
        #expect(partialFiles.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }
}
