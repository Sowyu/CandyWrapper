import Darwin
import Foundation
import Testing
@testable import T3Client
import T3Protocol

/// `LocalServerLauncher.run` and `stop` against fake CLIs and servers: shell scripts in a temporary
/// folder. No real t3 binary runs, and only processes these tests spawn get signalled.
struct LocalServerRunTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cw-run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeScript(_ body: String, in dir: URL) throws -> String {
        let script = dir.appendingPathComponent("fake-t3")
        try body.write(to: script, atomically: true, encoding: .utf8)
        chmod(script.path, 0o755)
        return script.path
    }

    /// A script that records its pid first, prints, then sleeps as the same process with stdout open.
    private func stallingScript() throws -> (script: String, pidFile: URL) {
        let dir = try tempDir()
        let pidFile = dir.appendingPathComponent("pid")
        let body = "#!/bin/sh\necho $$ > '\(pidFile.path).tmp'\nmv '\(pidFile.path).tmp' '\(pidFile.path)'\necho partial\nexec sleep 30\n"
        return (try writeScript(body, in: dir), pidFile)
    }

    /// Waits for a file the fake writes. It always comes, so the long cap only matters when broken.
    private func waitForFile(_ file: URL) async throws {
        for _ in 0..<1500 where !FileManager.default.fileExists(atPath: file.path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(FileManager.default.fileExists(atPath: file.path))
    }

    private func readPid(_ file: URL) async throws -> pid_t {
        try await waitForFile(file)
        let text = try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        return try #require(pid_t(text))
    }

    /// kill(pid, 0) still succeeds on an unreaped zombie, so ESRCH means it was reaped.
    private func reaped(_ pid: pid_t) -> Bool { kill(pid, 0) == -1 && errno == ESRCH }

    @Test func returnsStdoutOfACommandThatExits() async throws {
        let out = try await LocalServerLauncher.run(executable: "/bin/echo", arguments: ["/bin/echo", "hi"], environment: [:])
        #expect(String(decoding: out, as: UTF8.self) == "hi\n")
    }

    // ponytail: the script must record its pid inside the 2 s deadline, so a machine that can't start
    // /bin/sh in 2 s fails this test; hand `run` a spawn hook if that ever happens
    @Test func stallingCommandTimesOutAndIsReaped() async throws {
        let (script, pidFile) = try stallingScript()
        await #expect(throws: LocalServerLaunchError.self) {
            _ = try await LocalServerLauncher.run(executable: script, arguments: [script, "auth"], environment: [:],
                                                  timeout: .seconds(2))
        }
        #expect(reaped(try await readPid(pidFile)))
    }

    @Test func cancellationStopsAndReapsTheCommand() async throws {
        let (script, pidFile) = try stallingScript()
        let task = Task {
            try await LocalServerLauncher.run(executable: script, arguments: [script, "auth"], environment: [:])
        }
        let pid = try await readPid(pidFile)
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(reaped(pid))
    }

    /// The command exits at once, but a background child keeps its stdout and blocks on a FIFO. After
    /// run gives up, the test releases the child, which keeps writing to stdout for up to 30 s: once
    /// the read end closes, a write kills it with SIGPIPE, so a marker file means the read end stayed open.
    @Test func descendantHoldingStdoutCannotOutliveTheDeadline() async throws {
        let dir = try tempDir()
        let pidFile = dir.appendingPathComponent("pid")
        let marker = dir.appendingPathComponent("alive")
        let fifo = dir.appendingPathComponent("go")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        let script = try writeScript("""
            #!/bin/sh
            echo partial
            ( read x < '\(fifo.path)'; i=0; while [ $i -lt 600 ]; do echo late; sleep 0.05; i=$((i+1)); done; echo yes > '\(marker.path)'; exec sleep 30 ) &
            echo $! > '\(pidFile.path).tmp'
            mv '\(pidFile.path).tmp' '\(pidFile.path)'
            exit 0

            """, in: dir)
        await #expect(throws: LocalServerLaunchError.self) {
            _ = try await LocalServerLauncher.run(executable: script, arguments: [script, "auth"], environment: [:],
                                                  timeout: .milliseconds(500))
        }
        let background = try await readPid(pidFile)
        let identity = ProcessIdentity.of(background)
        defer { identity?.signal(SIGKILL) }
        // The child holds the FIFO's read end open, so this open returns at once.
        let writer = open(fifo.path, O_WRONLY)
        try #require(writer >= 0)
        _ = write(writer, "go\n", 3)
        close(writer)
        // The child either dies on SIGPIPE or writes the marker; wait for whichever happens.
        for _ in 0..<1500 where identity?.isAlive == true && !FileManager.default.fileExists(atPath: marker.path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    /// `stop` escalates: SIGTERM, then SIGKILL to the server's group after the timeout, then SIGTERM and
    /// SIGKILL to a descendant in its own session that outlived it. The fake server and that descendant
    /// both ignore SIGTERM. When stop returns, both are gone.
    @Test func stopKillsAServerAndADescendantThatIgnoreSigterm() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ready = dir.appendingPathComponent("ready")
        let descendantPid = dir.appendingPathComponent("descendant")
        let script = try writeScript("""
            #!/bin/sh
            trap '' TERM
            /usr/bin/perl -MPOSIX -e 'POSIX::setsid(); $SIG{TERM} = "IGNORE"; open(my $f, ">", "$ARGV[0].tmp") or die; print $f "$$\\n"; close $f; rename("$ARGV[0].tmp", $ARGV[0]); sleep 600' '\(descendantPid.path)' &
            while [ ! -f '\(descendantPid.path)' ]; do sleep 0.05; done
            touch '\(ready.path)'
            while :; do sleep 600; done

            """, in: dir)
        let pid = try LocalServerLauncher.spawn(executable: script, arguments: [script], environment: [:],
                                                fd3Payload: nil, stderrPath: nil)
        let watcher = ChildExitWatcher(pid: pid)
        let serverIdentity = try #require(ProcessIdentity.of(pid))
        defer { serverIdentity.signal(SIGKILL) }
        let child = try await readPid(descendantPid)
        let descendant = try #require(ProcessIdentity.of(child))
        defer { descendant.signal(SIGKILL) }
        try await waitForFile(ready)
        #expect(ProcessTools.descendants(of: pid).contains(child))

        let descriptor = try JSONDecoder().decode(EnvironmentDescriptor.self, from: Data(
            #"{"environmentId":"env-fake","label":"fake","serverVersion":"0","capabilities":{}}"#.utf8))
        let server = LaunchedLocalServer(pid: pid, identity: serverIdentity, origin: URL(string: "http://127.0.0.1:9")!,
                                         home: dir, descriptor: descriptor, accessToken: "", watcher: watcher)
        await LocalServerLauncher.stop(server, timeout: .milliseconds(200))
        #expect(server.hasExited)
        #expect(reaped(pid))
        #expect(!descendant.isAlive)
    }
}
