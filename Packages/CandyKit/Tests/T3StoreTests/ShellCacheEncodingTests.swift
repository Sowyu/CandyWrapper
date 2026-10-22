import Foundation
import Testing
import T3Protocol
@testable import T3Store

struct ShellCacheEncodingTests {
    private func makeEntry() throws -> ShellCache.Entry {
        var snapshot = try ShellCacheTests().recordedSnapshot()
        let sample = try #require(snapshot.threads.first)
        snapshot.threads = (0..<40).map { index in
            var row = sample
            row.id = ThreadId("cache-row-\(index)")
            return row
        }
        snapshot.archivedThreads = []
        return .init(version: ShellCache.Entry.currentVersion, environmentId: "sandbox", savedAt: Date(timeIntervalSince1970: 1000), snapshot: snapshot)
    }

    private func decode(_ data: Data) throws -> ShellCache.Entry {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ShellCache.Entry.self, from: data)
    }

    @Test func laterSavesOnlyEncodeChangedRows() throws {
        var entry = try makeEntry()
        var encoder = ShellCacheEncoder()
        var encodedRows = 0
        let encode: (ThreadShell) throws -> Data = { row in
            encodedRows += 1
            return try JSONEncoder().encode(row)
        }
        #expect(try decode(encoder.encode(entry, encodeRow: encode)) == entry)
        #expect(encodedRows == 40)
        entry.snapshot.snapshotSequence += 1
        #expect(try decode(encoder.encode(entry, encodeRow: encode)) == entry)
        #expect(encodedRows == 40)
        entry.snapshot.threads[5].title = "Only this row changed"
        entry.snapshot.threads.reverse()
        #expect(try decode(encoder.encode(entry, encodeRow: encode)) == entry)
        #expect(encodedRows == 41)
        entry.snapshot.archivedThreads = [entry.snapshot.threads.removeLast()]
        #expect(try decode(encoder.encode(entry, encodeRow: encode)) == entry)
        #expect(encodedRows == 41)
    }

    @Test func deletedRowsLeaveTheEncodingCache() throws {
        var entry = try makeEntry()
        var encoder = ShellCacheEncoder()
        var encodedRows = 0
        let encode: (ThreadShell) throws -> Data = { row in
            encodedRows += 1
            return try JSONEncoder().encode(row)
        }
        _ = try encoder.encode(entry, encodeRow: encode)
        let deleted = entry.snapshot.threads.removeLast()
        _ = try encoder.encode(entry, encodeRow: encode)
        #expect(encodedRows == 40)
        entry.snapshot.threads.append(deleted)
        #expect(try decode(encoder.encode(entry, encodeRow: encode)) == entry)
        #expect(encodedRows == 41)
    }
}
