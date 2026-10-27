import Foundation
import Testing
@testable import T3Client

/// Audit SA1 (responsiveness-audit-2026-10-26/session-actions.md): a browser download's 403 or 404 body
/// replaced the file the user chose to overwrite. T3 answers a missing download with a 404 "Not Found"
/// body (ServerBrowserStream.ts:229-238), and `URLSession.download` hands that body over as a file.
struct DownloadedFileTests {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("DownloadedFileTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func download(_ body: String) throws -> URL {
        let file = directory.appendingPathComponent(UUID().uuidString)
        try Data(body.utf8).write(to: file)
        return file
    }

    func response(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "http://127.0.0.1/download")!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    @Test(arguments: [404, 403, 500])
    func errorBodyLeavesTheExistingFile(status: Int) throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("report.csv")
        try Data("original file".utf8).write(to: target)
        let temp = try download("Not Found")
        #expect(throws: DownloadedFile.Refused.self) { try DownloadedFile.save(temp, response: response(status), to: target) }
        #expect(try String(contentsOf: target, encoding: .utf8) == "original file")
        #expect(!FileManager.default.fileExists(atPath: temp.path))
    }

    @Test func errorBodyCreatesNoNewFile() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("report.csv")
        #expect(throws: DownloadedFile.Refused.self) { try DownloadedFile.save(try download("Not Found"), response: response(404), to: target) }
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test func wrongSizeLeavesTheExistingFile() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("report.csv")
        try Data("original file".utf8).write(to: target)
        #expect(throws: DownloadedFile.Refused.self) {
            try DownloadedFile.save(try download("a,b"), response: response(200), expectedBytes: 3_000, to: target)
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "original file")
    }

    @Test func successReplacesOrCreates() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let existing = directory.appendingPathComponent("report.csv")
        try Data("original file".utf8).write(to: existing)
        try DownloadedFile.save(try download("a,b"), response: response(200), expectedBytes: 3, to: existing)
        #expect(try String(contentsOf: existing, encoding: .utf8) == "a,b")
        let fresh = directory.appendingPathComponent("new.csv")
        try DownloadedFile.save(try download("c,d"), response: response(200), to: fresh)
        #expect(try String(contentsOf: fresh, encoding: .utf8) == "c,d")
        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(left == ["new.csv", "report.csv"])
    }
}
