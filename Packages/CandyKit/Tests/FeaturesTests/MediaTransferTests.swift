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
    /// Downloads live in a folder per process, and making one removes the folders dead processes left: a quit or a
    /// kill strands every file a loader still held.
    @Test func aNewProcessRemovesTheDownloadsDeadOnesLeft() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: tmp) }
        func file(_ path: String) -> URL { tmp.appendingPathComponent(path) }
        for path in ["cw-media.111/dead", "cw-media.222/alive", "cw-media.333/own-pid-reused", "cw-media.x/not-a-pid", "other/unrelated"] {
            try fm.createDirectory(at: file(path).deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([1]).write(to: file(path))
        }
        let own = MediaTransfer.makeProcessDirectory(in: tmp, pid: 333, isRunning: { $0 == 222 })
        #expect(own == file("cw-media.333"))
        #expect(try fm.contentsOfDirectory(atPath: own.path).isEmpty, "a reused pid starts empty")
        #expect(!fm.fileExists(atPath: file("cw-media.111").path), "a dead process's downloads go")
        #expect(fm.fileExists(atPath: file("cw-media.222/alive").path), "a running process keeps its downloads")
        #expect(fm.fileExists(atPath: file("cw-media.x/not-a-pid").path))
        #expect(fm.fileExists(atPath: file("other/unrelated").path))
    }

    /// The folder is named by the process and exists once asked for.
    @Test func theProcessFolderIsNamedByPid() {
        let own = MediaTransfer.makeProcessDirectory(in: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: own.deletingLastPathComponent()) }
        #expect(own.lastPathComponent == "cw-media.\(getpid())")
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: own.path, isDirectory: &isDirectory) && isDirectory.boolValue)
        // Every transfer made without a folder of its own shares the one made once, so none empties it under another.
        #expect(MediaTransfer.processDirectory == MediaTransfer.processDirectory)
        #expect(MediaTransfer.processDirectory.lastPathComponent == "cw-media.\(getpid())")
    }

    /// The system clears the temporary folder of what went unused for days. A download then makes its folder again.
    @Test func aDownloadMakesItsFolderAgain() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ChunkResponse.self]
        let transfer = MediaTransfer(config: config, temporaryDirectory: folder)
        defer { transfer.invalidate() }
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        let result = try #require(await transfer.download(URL(string: "https://fixture.invalid/image")!))
        #expect(try Data(contentsOf: result.file) == Data([1]))
    }

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
