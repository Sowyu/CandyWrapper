import Foundation
import Testing
import T3Protocol

// Decode cost of the largest recorded stream, frame bytes to typed items, the way the app does it:
// RPCFrame.decodeServer, then each subscribeThread/subscribeShell Chunk value through decode(as:).
// Off by default. Run in release:
//   CW_BENCH=1 swift test -c release -Xswiftc -enable-testing --filter DecodeBenchmark

/// Counts heap allocations through libmalloc's `malloc_logger` hook.
private nonisolated(unsafe) var allocations = 0
private nonisolated(unsafe) var allocatedBytes = 0
private let logger: @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void = { type, _, arg2, arg3, _, _ in
    // MALLOC_LOG_TYPE_ALLOCATE = 2, DEALLOCATE = 4: both set means realloc, whose size is arg3.
    guard type & 2 != 0 else { return }
    allocations += 1
    allocatedBytes += Int(type & 4 != 0 ? arg3 : arg2)
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["CW_BENCH"] != nil))
struct DecodeBenchmark {
    @Test func largestFixtureStream() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appending(path: "fixtures/transcripts/04-threads.jsonl"), encoding: .utf8)
        var frames: [Data] = []
        var tags: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let o = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            guard o["kind"] as? String == "ws", let body = o["body"] as? [String: Any] else { continue }
            if o["dir"] as? String == "send" {
                if let id = body["id"] as? String, let tag = body["tag"] as? String { tags[id] = tag }
            } else {
                frames.append(try JSONSerialization.data(withJSONObject: body))
            }
        }
        let bytes = frames.reduce(0) { $0 + $1.count }

        func pass() throws -> Int {
            var items = 0
            for frame in frames {
                for message in try RPCFrame.decodeServer(frame) {
                    guard case .chunk(.string(let id), let values) = message else { continue }
                    for value in values {
                        switch tags[id] {
                        case "orchestration.subscribeThread": _ = try value.decode(as: ThreadStreamItem.self)
                        case "orchestration.subscribeShell": _ = try value.decode(as: ShellStreamItem.self)
                        default: continue
                        }
                        items += 1
                    }
                }
            }
            return items
        }

        _ = try pass()
        let hook = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger")!
            .assumingMemoryBound(to: Optional<@convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void>.self)
        allocations = 0; allocatedBytes = 0
        hook.pointee = logger
        let items = try pass()
        hook.pointee = nil
        let (count, total) = (allocations, allocatedBytes)

        var times: [Double] = []
        for _ in 0..<10 {
            let start = ContinuousClock.now
            _ = try pass()
            let d = ContinuousClock.now - start
            times.append(Double(d.components.seconds) * 1e3 + Double(d.components.attoseconds) / 1e15)
        }
        times.sort()
        print(String(format: "BENCH %d frames, %d KB, %d items: median %.1f ms, min %.1f ms, %d allocations, %.1f MB allocated",
                     frames.count, bytes / 1024, items, times[5], times[0], count, Double(total) / 1_048_576))
    }
}
