import Foundation
import Testing
@testable import Features

/// The paged plain viewer's line index (5258 largeText.worker.ts): `\n`, `\r` and `\r\n` end a line, a last line
/// without one counts, and binary data or an over-long line fail with T3's messages.
struct LargeTextIndexTests {
    private func index(_ text: String, chunk: Int = 3) throws -> LargeTextIndex {
        var i = LargeTextIndex()
        var cr = false
        let data = Data(text.utf8)
        var at = 0
        while at < data.count {
            try i.append(data.subdata(in: at..<min(data.count, at + chunk)), cr: &cr)
            at += chunk
        }
        try i.finish()
        return i
    }

    @Test func endsLinesAtEveryKindOfBreak() throws {
        let text = "one\ntwo\r\nthree\rfour"
        let i = try index(text)
        #expect(i.count == 4)
        let data = Data(text.utf8)
        #expect((0..<i.count).map { LargeTextIndex.line(data.subdata(in: i.range(of: $0))) } == ["one", "two", "three", "four"])
        #expect(try index("a\nb\n").count == 2)
        #expect(try index("").count == 0)
    }

    @Test func refusesBinaryAndOverlongLines() {
        #expect(throws: LargeTextIndex.Failure.binary) { try index("ok\n\0") }
        #expect(throws: LargeTextIndex.Failure.lineTooLong) { try index(String(repeating: "x", count: LargeTextIndex.maxLineBytes + 2), chunk: 1 << 20) }
        #expect(LargeTextIndex.Failure.tooLarge.message == "Text previews support files up to 256 MB.")
    }

    @Test func buildsFromAFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("large-text-\(UUID().uuidString)")
        try Data((1...1000).map { "line \($0)\n" }.joined().utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let i = try LargeTextIndex.build(url)
        #expect(i.count == 1000)
    }
}
