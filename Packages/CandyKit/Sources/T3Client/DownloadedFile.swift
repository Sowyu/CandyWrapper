import Foundation

/// Puts a finished download where the user chose to save it. An HTTP error page, or a body that is not
/// the size the server announced, never reaches the destination, and an existing file there stays whole
/// until the new one takes its place in one step.
public enum DownloadedFile {
    public struct Refused: LocalizedError {
        public let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// `temp` is `URLSession.download`'s file, which holds the body even for an HTTP error.
    /// `expectedBytes`: the size the server announced for the file, when it did.
    public static func save(_ temp: URL, response: URLResponse, expectedBytes: Int? = nil, to destination: URL) throws {
        let fm = FileManager.default
        defer { try? fm.removeItem(at: temp) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Refused("The server answered HTTP \(status) instead of the file.") }
        let bytes = try temp.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        if let expectedBytes, bytes != expectedBytes {
            throw Refused("The download has \(bytes) bytes, but the file has \(expectedBytes).")
        }
        // Staged on the destination's volume first, so the last step is a rename and a failed copy
        // from another volume never leaves half a file at the destination.
        let staging = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true)
        defer { try? fm.removeItem(at: staging) }
        let staged = staging.appendingPathComponent(destination.lastPathComponent)
        try fm.moveItem(at: temp, to: staged)
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: staged)
        } else {
            try fm.moveItem(at: staged, to: destination)
        }
    }
}
