import Darwin
import Foundation
import Testing
@testable import T3Client

/// `LocalServerLauncher.run` against a fake CLI that stalls with stdout open. No real t3 binary runs.
struct LocalServerRunTests {
    /// A script that prints, records its pid, then sleeps as the same process with stdout open.
    private func stallingScript() throws -> (script: String, pidFile: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cw-run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pidFile = dir.appendingPathComponent("pid")
        let script = dir.appendingPathComponent("fake-t3")
        let body = "#!/bin/sh\necho partial\necho $$ > '\(pidFile.path).tmp'\nmv '\(pidFile.path).tmp' '\(pidFile.path)'\nexec sleep 30\n"
        try body.write(to: script, atomically: true, encoding: .utf8)
        chmod(script.path, 0o755)
        return (script.path, pidFile)
    }

    private func waitForPid(_ pidFile: URL) async throws -> pid_t {
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: pidFile.path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        let text = try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        return try #require(pid_t(text))
    }

    /// kill(pid, 0) still succeeds on an unreaped zombie, so ESRCH means it was reaped.
    private func reaped(_ pid: pid_t) -> Bool { kill(pid, 0) == -1 && errno == ESRCH }

    @Test func returnsStdoutOfACommandThatExits() async throws {
        let out = try await LocalServerLauncher.run(executable: "/bin/echo", arguments: ["/bin/echo", "hi"], environment: [:])
        #expect(String(decoding: out, as: UTF8.self) == "hi\n")
    }

    @Test func stallingCommandTimesOutAndIsReaped() async throws {
        let (script, pidFile) = try stallingScript()
        let start = ContinuousClock.now
        await #expect(throws: LocalServerLaunchError.self) {
            _ = try await LocalServerLauncher.run(executable: script, arguments: [script, "auth"], environment: [:],
                                                  timeout: .milliseconds(500))
        }
        #expect(ContinuousClock.now - start < .seconds(3))
        #expect(reaped(try await waitForPid(pidFile)))
    }

    @Test func cancellationStopsAndReapsTheCommand() async throws {
        let (script, pidFile) = try stallingScript()
        let task = Task {
            try await LocalServerLauncher.run(executable: script, arguments: [script, "auth"], environment: [:])
        }
        let pid = try await waitForPid(pidFile)
        let start = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(ContinuousClock.now - start < .seconds(3))
        #expect(reaped(pid))
    }
}
