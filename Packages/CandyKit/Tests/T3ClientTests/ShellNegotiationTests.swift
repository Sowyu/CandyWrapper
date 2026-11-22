import Foundation
import Testing
import T3Protocol
@testable import T3Client

/// The shell's config wait, `ShellNegotiation.read`, on the fakes with a hand-stepped clock. `Driver` follows
/// ShellSession's order (App/Sources/ShellSession.swift, prepareShell, subscribeInput and configurationChanged),
/// which tests can't import: prepare on `.subscribed`, one HTTP shell per prepared session, then the payload.
struct ShellNegotiationTests {
    actor Driver {
        var negotiation: ShellNegotiation?
        var loads: [String] = []
        var restarts = 0
        private var afterSequence: Int?

        func prepare(_ generation: Int, feed: ServerConfigFeed, supervisor: ConnectionSupervisor) async {
            guard let n = await ShellNegotiation.read(feed: feed, supervisor: supervisor, generation: generation) else { return }
            negotiation = n
            loads.append(n.omissions.snapshotPath)
            afterSequence = 7
        }

        func input() -> JSONValue {
            var payload = negotiation?.omissions.payload ?? [:]
            if negotiation?.completionMarker == true { payload["requestCompletionMarker"] = .bool(true) }
            if let afterSequence { payload["afterSequence"] = .number(Double(afterSequence)) }
            return .object(payload)
        }

        func configArrived(_ config: JSONValue) {
            if negotiation?.restarts(for: config) == true { restarts += 1 }
        }
    }

    struct Setup {
        let harness = Harness([.succeed])
        let clock = ManualClock()
        let supervisor: ConnectionSupervisor
        let feed: ServerConfigFeed
        let driver = Driver()

        init() {
            supervisor = ConnectionSupervisor(dependencies: harness.dependencies)
            let clock = clock
            feed = ServerConfigFeed(supervisor: supervisor, sleep: { try await clock.sleep($0) })
        }

        func requests(_ tag: String) -> [RPCRequest] {
            (harness.lastSocket?.sent ?? []).compactMap {
                if case .request(let r) = $0, r.tag == tag { r } else { nil }
            }
        }

        var shellRequests: [RPCRequest] { requests("orchestration.subscribeShell") }

        /// The shell subscription and a config watcher, as ShellSession.start runs them.
        func startShell() async -> [Task<Void, Never>] {
            let feed = feed, supervisor = supervisor, driver = driver
            let shell = supervisor.subscribe("orchestration.subscribeShell", keepsRetryingServerFailures: true, payload: {
                await driver.input()
            }, handler: { event in
                if case .subscribed(let generation) = event { await driver.prepare(generation, feed: feed, supervisor: supervisor) }
            })
            let events = await feed.events()
            let watch = Task {
                for await event in events {
                    if case .value(let json) = event, json["type"]?.stringValue == "snapshot", let config = json["config"] {
                        await driver.configArrived(config)
                    }
                }
            }
            return [shell, watch]
        }

        func connect() async {
            await feed.start()
            await supervisor.connect()
            _ = await eventually { !self.requests("subscribeServerConfig").isEmpty }
        }

        func deliverConfig(flags: Bool = true) throws {
            let request = try #require(requests("subscribeServerConfig").first)
            harness.lastSocket?.deliver(.chunk(requestId: request.id, values: [.object([
                "version": .number(1), "type": .string("snapshot"),
                "config": .object([
                    "cwd": .string("/sandbox"), "shellThreadFamilies": .bool(flags),
                    "shellOlderSettled": .bool(flags), "shellResumeCompletionMarker": .bool(flags),
                ]),
            ])]))
        }

        func stop(_ tasks: [Task<Void, Never>]) async {
            tasks.forEach { $0.cancel() }
            await feed.stop()
            await supervisor.disconnect()
        }
    }

    @Test func aKnownConfigNegotiatesWithoutWaiting() async throws {
        let s = Setup()
        await s.connect()
        try s.deliverConfig()
        #expect(await s.feed.initialConfig(generation: 1) != nil)
        let tasks = await s.startShell()
        #expect(await eventually { s.shellRequests.count == 1 })
        #expect(s.clock.sleepCount == 0, "a known config starts no deadline")
        #expect(await s.driver.loads == ["/api/orchestration/shell?omitIdleSubagents=1&omitOlderSettled=1"])
        #expect(s.shellRequests.first?.payload == .object([
            "omitIdleSubagents": .bool(true), "omitOlderSettled": .bool(true),
            "requestCompletionMarker": .bool(true), "afterSequence": .number(7),
        ]))
        #expect(await s.driver.negotiation?.negotiated == true)
        await s.stop(tasks)
    }

    @Test func aConfigInsideTheDeadlineNegotiates() async throws {
        let s = Setup()
        await s.connect()
        let tasks = await s.startShell()
        #expect(await eventually { s.clock.waiting == 1 })
        s.clock.advance(by: .seconds(4))
        await settle()
        #expect(s.shellRequests.isEmpty)
        try s.deliverConfig()
        #expect(await eventually { s.shellRequests.count == 1 })
        #expect(await s.driver.negotiation == ShellNegotiation(
            omissions: ShellOmissions(omitIdleSubagents: true, omitOlderSettled: true), completionMarker: true, negotiated: true))
        #expect(s.clock.waiting == 0, "the deadline ends with the wait")
        await s.stop(tasks)
    }

    /// The nil path: the full shell over HTTP, then `subscribeShell` from its cursor with no flags, which is what T3 asks
    /// of a server when its config read fails (client-runtime state/shell.ts:638-645, 537-552) and what a server
    /// without the omission flags gets.
    @Test func aConfigThatNeverArrivesLoadsTheWholeShellOnceAtTheDeadline() async throws {
        let s = Setup()
        await s.connect()
        let tasks = await s.startShell()
        #expect(await eventually { s.clock.waiting == 1 })
        s.clock.advance(by: ServerConfigFeed.shellConfigDeadline - .milliseconds(1))
        await settle()
        #expect(s.shellRequests.isEmpty)
        s.clock.advance(by: .milliseconds(1))
        #expect(await eventually { s.shellRequests.count == 1 })
        #expect(await s.driver.loads == ["/api/orchestration/shell"])
        #expect(s.shellRequests.first?.payload == .object(["afterSequence": .number(7)]))
        #expect(await s.driver.negotiation?.negotiated == false)
        await s.stop(tasks)
    }

    @Test func aConfigAfterTheDeadlineDoesNotLoadAgain() async throws {
        let s = Setup()
        await s.connect()
        let tasks = await s.startShell()
        #expect(await eventually { s.clock.waiting == 1 })
        s.clock.advance(by: ServerConfigFeed.shellConfigDeadline)
        #expect(await eventually { s.shellRequests.count == 1 })
        try s.deliverConfig()
        #expect(await eventually { await s.feed.initialConfig(generation: 1) != nil })
        await settle()
        #expect(await s.driver.restarts == 0)
        #expect(await s.driver.loads.count == 1)
        #expect(s.shellRequests.count == 1)
        await s.stop(tasks)
    }

    @Test func aDisconnectDuringTheWaitSendsNothing() async throws {
        let s = Setup()
        await s.connect()
        let tasks = await s.startShell()
        #expect(await eventually { s.clock.waiting == 1 })
        await s.supervisor.disconnect()
        #expect(await eventually { s.clock.waiting == 0 })
        await settle()
        #expect(s.shellRequests.isEmpty)
        #expect(await s.driver.loads.isEmpty)
        tasks.forEach { $0.cancel() }
        await s.feed.stop()
    }

    @Test func cancellingTheWaitReturnsNothing() async throws {
        let s = Setup()
        await s.connect()
        let read = Task { await ShellNegotiation.read(feed: s.feed, supervisor: s.supervisor, generation: 1) }
        #expect(await eventually { s.clock.waiting == 1 })
        read.cancel()
        #expect(await read.value == nil)
        #expect(s.clock.waiting == 0)
        await s.stop([])
    }

    /// Changed flags still restart a negotiated session, as before.
    @Test func aNegotiatedSessionRestartsOnlyWhenItsFlagsChange() {
        let negotiated = ShellNegotiation(config: .object(["shellThreadFamilies": .bool(true), "shellResumeCompletionMarker": .bool(true)]))
        #expect(negotiated.restarts(for: .object(["shellThreadFamilies": .bool(true), "shellResumeCompletionMarker": .bool(true)])) == false)
        #expect(negotiated.restarts(for: .object(["shellResumeCompletionMarker": .bool(true)])))
        #expect(ShellNegotiation(config: nil).restarts(for: .object(["shellThreadFamilies": .bool(true)])) == false)
    }

    /// The shell and a thread open read the same feed. Each deadline ends only its own wait, and the cached config
    /// stays for the other.
    @Test func theShellAndAThreadOpenWaitIndependently() async throws {
        let s = Setup()
        await s.connect()
        let shell = Task { await ShellNegotiation.read(feed: s.feed, supervisor: s.supervisor, generation: 1) }
        let thread = Task { await s.feed.initialConfig(generation: 1, within: ServerConfigFeed.threadOpenConfigDeadline) }
        #expect(await eventually { s.clock.waiting == 2 })
        s.clock.advance(by: ServerConfigFeed.threadOpenConfigDeadline)
        #expect(await thread.value == nil)
        #expect(s.clock.waiting == 1)
        try s.deliverConfig()
        #expect(await shell.value?.negotiated == true)

        // A thread that opens later reads the same cached config at once.
        #expect(await s.feed.initialConfig(generation: 1, within: .seconds(1))?["shellThreadFamilies"] == .bool(true))
        await s.stop([])
    }

    @Test func aThreadOpenWaitOutlastsTheShellsDeadline() async throws {
        let s = Setup()
        await s.connect()
        let shell = Task { await ShellNegotiation.read(feed: s.feed, supervisor: s.supervisor, generation: 1) }
        let thread = Task { await s.feed.initialConfig(generation: 1, within: .seconds(60)) }
        #expect(await eventually { s.clock.waiting == 2 })
        s.clock.advance(by: ServerConfigFeed.shellConfigDeadline)
        #expect(await shell.value?.negotiated == false)
        try s.deliverConfig()
        #expect(await thread.value?["shellThreadFamilies"] == .bool(true))
        await s.stop([])
    }
}
