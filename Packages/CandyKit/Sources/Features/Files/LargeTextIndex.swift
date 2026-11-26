import Foundation

/// The line starts of a text file on disk, for the paged plain viewer (5258 components/files/largeText.worker.ts and
/// largeTextProtocol.ts). A line ends at `\n`, `\r` or `\r\n`; a last line without one still counts.
public struct LargeTextIndex: Sendable, Equatable {
    /// `LARGE_TEXT_MAX_BYTES`, `LARGE_TEXT_MAX_ROWS` and the 1 MB line limit.
    public static let maxBytes = 256 * 1024 * 1024
    public static let maxRows = 5_000_000
    public static let maxLineBytes = 1024 * 1024

    /// `previewFailureMessages.ts:30-34`.
    public enum Failure: Error, Equatable {
        case tooLarge, binary, lineTooLong, tooManyRows, unreadable
        public var message: String {
            switch self {
            case .tooLarge: "Text previews support files up to 256 MB."
            case .binary: "This file contains binary data."
            case .lineTooLong: "A line or record exceeds the 1 MB preview limit."
            case .tooManyRows: "Text previews support up to 5 million rows."
            case .unreadable: "The file download was incomplete. Close it and try again."
            }
        }
    }

    /// Byte offsets: line `i` runs from `starts[i]` to `starts[i + 1]`, its line ending included. 32 bits hold
    /// every offset under the 256 MB limit.
    public private(set) var starts: [UInt32] = [0]
    public private(set) var size = 0
    public var count: Int { starts.count - 1 }

    public init() {}

    /// Indexes `url` in 1 MB reads, off the main thread.
    public static func build(_ url: URL) throws -> LargeTextIndex {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw Failure.unreadable }
        defer { try? handle.close() }
        var index = LargeTextIndex()
        var cr = false
        while true {
            try Task.checkCancellation()
            guard let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
            try index.append(chunk, cr: &cr)
        }
        try index.finish()
        return index
    }

    mutating func append(_ chunk: Data, cr: inout Bool) throws {
        guard size + chunk.count <= Self.maxBytes else { throw Failure.tooLarge }
        try chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for (i, byte) in raw.enumerated() {
                let pos = size + i
                if byte == 0 { throw Failure.binary }
                if pos - Int(starts[starts.count - 1]) > Self.maxLineBytes { throw Failure.lineTooLong }
                if cr {
                    cr = false
                    // `\r\n` is one ending: the line starts after the `\n`.
                    if byte == 10 { starts[starts.count - 1] = UInt32(pos + 1); continue }
                }
                if byte == 10 || byte == 13 {
                    if starts.count > Self.maxRows { throw Failure.tooManyRows }
                    starts.append(UInt32(pos + 1))
                    cr = byte == 13
                }
            }
        }
        size += chunk.count
    }

    mutating func finish() throws {
        if size > Int(starts[starts.count - 1]) {
            if starts.count > Self.maxRows { throw Failure.tooManyRows }
            starts.append(UInt32(size))
        }
    }

    /// The bytes of line `i`, its line ending included; the viewer drops the ending.
    public func range(of i: Int) -> Range<Int> { Int(starts[i])..<Int(starts[i + 1]) }

    /// Line `i`'s text from those bytes, without its ending.
    public static func line(_ bytes: Data) -> String {
        var text = String(decoding: bytes, as: UTF8.self)
        while let last = text.unicodeScalars.last, last == "\n" || last == "\r" { text.unicodeScalars.removeLast() }
        return text
    }
}
