import CryptoKit
import Foundation
import T3Protocol

/// CandyWrapper's own copies of T3's server runtime, so the app runs on a Mac with no T3 Code app,
/// CLI or background service. The layout is T3's pinned runtime (cloud/pinnedRuntime.ts:23-70):
/// `<root>/versions/<version>/t3` beside the web client and native packages, with `.install-complete`
/// holding the version. `state.json` names the active version and the one before it; the store
/// deletes every other version.
public struct RuntimeStore: Sendable {
    public struct State: Codable, Equatable, Sendable {
        public var active: String?
        public var previous: String?
        public init(active: String? = nil, previous: String? = nil) { self.active = active; self.previous = previous }
    }

    public enum Progress: Equatable, Sendable {
        case downloading(received: Int64, total: Int64?)
        case verifying
        case extracting
    }

    public struct InstallError: Error, Equatable, CustomStringConvertible {
        public let description: String
        public init(_ description: String) { self.description = description }
    }

    public let root: URL
    public init(root: URL) { self.root = root }

    /// `~/Library/Application Support/CandyWrapper/Runtimes`.
    public static var standard: RuntimeStore {
        RuntimeStore(root: URL.applicationSupportDirectory.appending(path: "CandyWrapper/Runtimes", directoryHint: .isDirectory))
    }

    var versionsDir: URL { root.appending(path: "versions", directoryHint: .isDirectory) }
    var stateURL: URL { root.appending(path: "state.json") }

    public func state() -> State {
        (try? Data(contentsOf: stateURL)).flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
    }

    private func write(_ state: State) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
    }

    /// A complete install's executable: the sentinel names the version and `t3` runs.
    public func binary(_ version: String) -> URL? {
        guard T3Version(version) != nil else { return nil }
        let dir = versionsDir.appending(path: version, directoryHint: .isDirectory)
        let sentinel = (try? String(contentsOf: dir.appending(path: ".install-complete"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let t3 = dir.appending(path: "t3")
        return sentinel == version && FileManager.default.isExecutableFile(atPath: t3.path) ? t3 : nil
    }

    /// The active version and its executable, when it is installed.
    public func active() -> (version: T3Version, binary: URL)? {
        guard let raw = state().active, let version = T3Version(raw), let binary = binary(raw) else { return nil }
        return (version, binary)
    }

    /// Makes `version` the active one, keeps the one it replaces as `previous`, and deletes the rest.
    public func activate(_ version: String) throws {
        var s = state()
        if s.active != version {
            s.previous = s.active
            s.active = version
        }
        try write(s)
        cleanup()
    }

    /// No active version, so the next start picks T3's own runtime again: an update that fails after one of
    /// T3's runtimes ran the server goes back to it.
    public func deactivate() throws {
        var s = state()
        s.active = nil
        try write(s)
    }

    /// Deletes every version folder but the active and previous ones, and any staging leftovers.
    public func cleanup() {
        let keep = Set([state().active, state().previous].compactMap { $0 })
        let names = (try? FileManager.default.contentsOfDirectory(atPath: versionsDir.path)) ?? []
        for name in names where !keep.contains(name) {
            try? FileManager.default.removeItem(at: versionsDir.appending(path: name))
        }
    }

    /// The release archive for this Mac. T3 publishes no Intel macOS build (shared/cliRelease.ts:18-26).
    static var platformKey: String? {
        #if arch(arm64)
        return "darwin-arm64"
        #else
        return nil
        #endif
    }

    /// `cliReleaseDownloadBaseUrl`: GitHub releases, or `T3CODE_RELEASE_BASE_URL` (T3's mirror switch).
    public static func releaseDirectory(_ version: String, baseURL: URL? = nil) -> URL {
        let base = baseURL ?? ProcessInfo.processInfo.environment["T3CODE_RELEASE_BASE_URL"].flatMap(URL.init(string:))
            ?? URL(string: "https://github.com/pingdotgg/t3code/releases/download")!
        return base.appending(path: "v" + version)
    }

    /// `parseChecksums`: `<hex>  <file>` lines, a leading `*` for binary mode.
    static func checksums(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
            guard parts.count == 2, parts[0].count == 64, parts[0].allSatisfy(\.isHexDigit) else { continue }
            var file = parts[1].trimmingCharacters(in: .whitespaces)
            if file.hasPrefix("*") { file.removeFirst() }
            out[file] = parts[0].lowercased()
        }
        return out
    }

    /// `installFromArchive` and `installPinnedRuntime` (cloud/pinnedRuntime.ts:180-375): the release's
    /// `SHA256SUMS`, the archive checked against it, `tar` into a staging folder beside the versions,
    /// the sentinel, then one rename. Does not change the active version.
    public func install(_ version: String, baseURL: URL? = nil, session: URLSession = .shared,
                        onProgress: @escaping @Sendable (Progress) -> Void = { _ in }) async throws -> URL {
        if let done = binary(version) { return done }
        guard T3Version(version) != nil else { throw InstallError("'\(version)' is not an exact t3 version.") }
        guard let key = Self.platformKey else { throw InstallError("T3 Code's server is only published for Apple silicon Macs.") }
        let fm = FileManager.default
        try fm.createDirectory(at: versionsDir, withIntermediateDirectories: true)
        let staging = versionsDir.appending(path: ".staging-" + UUID().uuidString, directoryHint: .isDirectory)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let directory = Self.releaseDirectory(version, baseURL: baseURL)
        let fileName = "t3-\(version)-\(key).tar.gz"
        onProgress(.downloading(received: 0, total: nil))
        let (sums, sumsResponse) = try await session.data(from: directory.appending(path: "SHA256SUMS"))
        try Self.checkStatus(sumsResponse, "downloading the t3 release checksums")
        guard let expected = Self.checksums(String(decoding: sums, as: UTF8.self))[fileName] else {
            throw InstallError("Could not find \(fileName) in the t3 release checksums.")
        }
        let delegate = DownloadProgress(onProgress)
        let (downloaded, response) = try await session.download(from: directory.appending(path: fileName), delegate: delegate)
        defer { try? fm.removeItem(at: downloaded) }
        try Self.checkStatus(response, "downloading the t3 release archive")
        onProgress(.verifying)
        guard try Self.sha256(of: downloaded) == expected else { throw InstallError("The t3 release archive failed its checksum.") }

        onProgress(.extracting)
        let archive = staging.appending(path: "t3-runtime-archive")
        try fm.moveItem(at: downloaded, to: archive)
        let tar = Process()
        tar.executableURL = URL(filePath: "/usr/bin/tar")
        tar.arguments = ["-xf", archive.path, "-C", staging.path, "--strip-components=1"]
        try tar.run()
        await withCheckedContinuation { c in DispatchQueue.global().async { tar.waitUntilExit(); c.resume() } }
        guard tar.terminationStatus == 0 else { throw InstallError("Could not extract the t3 release archive (tar exited \(tar.terminationStatus)).") }
        try? fm.removeItem(at: archive)
        guard fm.isExecutableFile(atPath: staging.appending(path: "t3").path) else { throw InstallError("The t3 release archive has no t3 executable.") }
        try Data((version + "\n").utf8).write(to: staging.appending(path: ".install-complete"))
        let target = versionsDir.appending(path: version, directoryHint: .isDirectory)
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try fm.moveItem(at: staging, to: target)
        guard let binary = binary(version) else { throw InstallError("The t3@\(version) install did not complete.") }
        return binary
    }

    static func checkStatus(_ response: URLResponse, _ step: String) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw InstallError("Failed \(step) (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        // @unchecked: the callback is Sendable and nothing else is stored.
        let report: @Sendable (Progress) -> Void
        init(_ report: @escaping @Sendable (Progress) -> Void) { self.report = report }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            report(.downloading(received: totalBytesWritten, total: totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil))
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    }
}
