import Foundation
#if canImport(Musl)
import Musl
private let posixWrite = Musl.write
#elseif canImport(Glibc)
import Glibc
private let posixWrite = Glibc.write
#else
private let posixWrite = Darwin.write
#endif

/// Writes for the rebuildable caches (`ShellCache`, `ThreadCache`).
///
/// `Data.write` calls fsync on every write, which took 113 ms per 1 MB shell snapshot on a 5400 rpm disk
/// and once 8.7 s while the disk flushed other work (docs/perf/README.md, "The app's own caches on a slow
/// disk"). T3 dropped the same per-commit sync from its database (a74ce48f9, `synchronous = NORMAL`).
/// This writes a temporary file beside the target and renames it over, without a sync: an app crash
/// loses nothing, and an OS crash or power loss can leave the newest file empty or torn. Both caches
/// validate what they read and treat a bad file as a miss, and the server refills them.
enum CacheFile {
    static func write(_ data: Data, to url: URL) throws {
        let temp = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp").path
        let fd = open(temp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var failure: Int32 = 0
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = posixWrite(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    failure = errno
                    return
                }
                offset += n
            }
        }
        if close(fd) != 0, failure == 0 { failure = errno }
        if failure == 0, rename(temp, url.path) != 0 { failure = errno }
        guard failure == 0 else {
            unlink(temp)
            throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
        }
    }
}
