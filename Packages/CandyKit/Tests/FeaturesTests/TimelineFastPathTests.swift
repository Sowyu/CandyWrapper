import AppKit
import Testing
import T3Protocol
import T3Store
@testable import Features

/// The streamed-word fast paths give what the code they replaced gave.
@MainActor @Suite struct TimelineFastPathTests {
    /// `TimelineRunState.init` before it became one pass.
    private struct Reference {
        var latest: RunId?, status: ThreadStatus?, turnEnded: Bool?, running: RunId?
        init(_ projection: ThreadProjection) {
            func newest(_ statuses: Set<ThreadStatus>) -> Run? {
                projection.runs.filter { statuses.contains($0.status) }.max { $0.ordinal < $1.ordinal }
            }
            let unheld = projection.runs.filter { !($0.status == .queued && $0.queueHeld == true) }.max { $0.ordinal < $1.ordinal }
            let activity = newest([.preparing, .starting, .running, .waiting]) ?? unheld
            latest = activity?.id
            status = activity?.status
            turnEnded = activity.map { run in
                guard [.preparing, .starting, .running, .waiting].contains(run.status), let attempt = run.activeAttemptId?.rawValue else { return false }
                func ordinal(_ turn: JSONValue) -> Double { if case .number(let n)? = turn["ordinal"] { return n }; return 0 }
                let latest = projection.providerTurns.filter { $0["runAttemptId"]?.stringValue == attempt }.max { ordinal($0) < ordinal($1) }
                guard let status = latest?["status"]?.stringValue else { return false }
                return status != "pending" && status != "running"
            }
            running = newest([.preparing, .starting, .running])?.id
        }
    }

    @Test func runStateMatchesTheFilteredScans() throws {
        let (frame, threadId) = try syntheticThreadFrame(copies: 12, window: 1)
        guard case .chunk(_, let values)? = try RPCFrame.decodeServer(frame).first else { throw CancellationError() }
        var reducer = ThreadReducer(threadId: ThreadId(threadId))
        reducer.apply([try values[0].decode(as: ThreadStreamItem.self)])
        let base = try #require(reducer.projection)
        #expect(base.runs.count >= 24)
        let statuses: [ThreadStatus] = [.preparing, .starting, .running, .waiting, .queued, .completed, .failed, ThreadStatus(rawValue: "future")]
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int((seed >> 33) % UInt64(n)) }
        var checked = 0
        for round in 0..<300 {
            var p = base
            let attempts = p.runs.compactMap(\.activeAttemptId)
            for i in p.runs.indices {
                p.runs[i].status = statuses[next(statuses.count)]
                p.runs[i].queueHeld = [nil, true, false][next(3)]
                // Ties on the ordinal, which the first run of keeps.
                p.runs[i].ordinal = next(round % 3 == 0 ? 4 : 40)
            }
            p.providerTurns = (0..<next(30)).map { k in
                .object(["runAttemptId": .string(attempts.isEmpty ? "none" : attempts[next(attempts.count)].rawValue),
                         "ordinal": next(2) == 0 ? .number(Double(next(5))) : .null,
                         "status": .string(["pending", "running", "completed", "failed"][next(4)]), "k": .number(Double(k))])
            }
            let state = TimelineRunState(projection: p), want = Reference(p)
            #expect(state.latestRun?.runId == want.latest, "round \(round)")
            #expect(state.latestRun?.status == want.status, "round \(round)")
            #expect(state.latestRun?.turnEnded == want.turnEnded, "round \(round)")
            #expect(state.runningRunId == want.running, "round \(round)")
            if want.turnEnded == true { checked += 1 }
        }
        #expect(checked > 5)
    }
}
