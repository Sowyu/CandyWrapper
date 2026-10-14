import Foundation
import T3Protocol

/// Development: with CANDY_RPC_TRACE=<file>, appends one tab-separated line per RPC event, for
/// counting what the app asks of the server (docs/perf/README.md, "Server load and cold start").
/// Each line starts with the ms since launch and the connection number, then
/// `req <id> <tag> <bytes>`, `rx <messages> <bytes>` per received frame, or `int <id>` for an
/// interrupt. Off, it costs one static Bool check per frame.
enum RPCTrace {
    private static let handle: FileHandle? = {
        guard let path = ProcessInfo.processInfo.environment["CANDY_RPC_TRACE"] else { return nil }
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }()
    static let enabled = handle != nil
    private static let start = ContinuousClock.now
    private static let lock = NSLock()
    nonisolated(unsafe) private static var lastConnection = 0

    static func connectionNumber() -> Int {
        guard enabled else { return 0 }
        lock.lock(); defer { lock.unlock() }
        lastConnection += 1
        return lastConnection
    }

    static func write(_ connection: Int, _ fields: String...) {
        guard let handle else { return }
        let line = String(format: "%.1f\t%d\t", OpenTiming.ms(ContinuousClock.now - start), connection)
            + fields.joined(separator: "\t") + "\n"
        lock.lock(); defer { lock.unlock() }
        handle.write(Data(line.utf8))
    }

    /// `c<id>:<values>` per chunk, `e<id>` per exit.
    static func describe(_ messages: [RPCServerMessage]) -> String {
        messages.map { m -> String in
            switch m {
            case .chunk(let id, let values): "c\(id):\(values.count)"
            case .exit(let id, _): "e\(id)"
            case .pong: "pong"
            default: "other"
            }
        }.joined(separator: ",")
    }
}
