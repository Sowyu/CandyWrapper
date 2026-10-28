import Foundation
import Testing
@testable import T3Client
import T3Protocol

struct ServerConfigFeedTests {
    @Test func onDemandOptInRequiresTheCurrentDescriptorsCapability() async throws {
        let harness = Harness([.succeed], serverCapabilities: ["providerWorkspaceSnapshotsOnDemand"])
        let supervisor = ConnectionSupervisor(dependencies: harness.dependencies)
        let feed = ServerConfigFeed(supervisor: supervisor)
        await feed.start()
        await supervisor.connect()
        #expect(await eventually { harness.lastSocket?.sent.isEmpty == false })
        let socket = try #require(harness.lastSocket)
        #expect(requests(socket).first?.payload["workspaceSnapshotsOnDemand"] == .bool(true))
        await feed.stop()
        await supervisor.disconnect()
    }

    private func snapshot(_ name: String, providers: JSONValue = .array([])) -> JSONValue {
        .object([
            "version": .number(1), "type": .string("snapshot"),
            "config": .object([
                "cwd": .string(name), "providers": providers, "settings": .object([:]),
                "keybindings": .array([]), "issues": .array([]),
                "shellSummarySnapshots": .bool(true), "futureCapability": .string("preserved"),
            ]),
        ])
    }

    private func update(_ type: String, _ fields: [String: JSONValue]) -> JSONValue {
        .object(["version": .number(1), "type": .string(type), "payload": .object(fields)])
    }

    private func requests(_ socket: FakeSocket) -> [RPCRequest] {
        socket.sent.compactMap { if case .request(let request) = $0 { request } else { nil } }
    }

    private func observe(_ feed: ServerConfigFeed, into log: EventLog) async -> Task<Void, Never> {
        let stream = await feed.events()
        return Task { for await event in stream { await log.append(event) } }
    }

    private func values(_ events: [SubscriptionEvent]) -> [JSONValue] {
        events.compactMap { if case .value(let value) = $0 { value } else { nil } }
    }

    @Test func cancelledStartCannotReviveAStoppedOwner() async {
        let harness = Harness([.succeed])
        let supervisor = ConnectionSupervisor(dependencies: harness.dependencies)
        let feed = ServerConfigFeed(supervisor: supervisor)
        let delayed = Task {
            try? await Task.sleep(for: .seconds(30))
            await feed.start()
        }
        delayed.cancel()
        await delayed.value
        await supervisor.connect()
        await settle()
        #expect(harness.lastSocket?.sent.isEmpty != false)
        let returned = Cursor()
        let read = Task {
            let value = await feed.initialConfig(generation: 1)
            await returned.set(1)
            return value
        }
        #expect(await eventually(seconds: 3) { await returned.value == 1 })
        await feed.stop()
        #expect(await read.value == nil)
        await supervisor.disconnect()
    }

    @Test func unavailableConfigStreamAllowsLegacyShellFallback() async throws {
        let harness = Harness([.succeed])
        let supervisor = ConnectionSupervisor(dependencies: harness.dependencies)
        let feed = ServerConfigFeed(supervisor: supervisor)
        defer { Task { await feed.stop(); await supervisor.disconnect() } }
        await feed.start()
        let waiting = Task { await feed.initialConfig(generation: 1) }
        await supervisor.connect()
        #expect(await eventually { harness.lastSocket?.sent.count == 1 })
        let socket = try #require(harness.lastSocket)
        let request = try #require(requests(socket).first)
        socket.deliver(.exit(requestId: request.id, exit: .failure([
            .fail(RPCTypedError(tag: "Unavailable", fields: [:]))
        ])))
        #expect(await waiting.value == nil)
        #expect(await feed.initialConfig(generation: 1) == nil)
    }

    @Test func sharesOneStreamWithEarlyAndLateObserversAndReturnsRawSnapshotConfig() async throws {
        let harness = Harness([.succeed])
        let supervisor = ConnectionSupervisor(dependencies: harness.dependencies)
        let feed = ServerConfigFeed(supervisor: supervisor)
        defer { Task { await feed.stop(); await supervisor.disconnect() } }
        let early = EventLog()
        let earlyTask = await observe(feed, into: early)
        await feed.start()
        await feed.start()
        let initial = Task { await feed.initialConfig(generation: 1) }
        await supervisor.connect()
        #expect(await eventually { harness.lastSocket?.sent.count == 1 })
        let socket = try #require(harness.lastSocket)
        let request = try #require(requests(socket).first)
        #expect(request.tag == "subscribeServerConfig")
        #expect(request.payload == .object([
            "environmentThemes": .bool(true), "usageLimitSources": .bool(true), "usageLimitsCommand": .bool(true),
        ]))
        let event = snapshot("first")
        socket.deliver(.chunk(requestId: request.id, values: [event]))
        #expect(await initial.value == event["config"])
        #expect(await feed.initialConfig(generation: 1) == event["config"])
        let late = EventLog()
        let lateTask = await observe(feed, into: late)
        #expect(await eventually {
            let earlyCount = await early.events.count
            let lateCount = await late.events.count
            return earlyCount == 2 && lateCount == 2
        })
        for log in [early, late] {
            let events = await log.events
            guard case .subscribed(generation: 1) = events.first else { Issue.record("Missing generation"); continue }
            #expect(values(events) == [event])
        }
        #expect(requests(socket).count == 1)
        await feed.stop()
        await earlyTask.value
        await lateTask.value
        #expect(await eventually { socket.sent.contains(.interrupt(request.id)) })
    }

    @Test func lateReplayKeepsOnlyLatestWholeFieldsAndDoesNotRetainUnknownEvents() async throws {
        let harness = Harness([.succeed])
        let supervisor = ConnectionSupervisor(dependencies: harness.dependencies)
        let feed = ServerConfigFeed(supervisor: supervisor)
        defer { Task { await feed.stop(); await supervisor.disconnect() } }
        await feed.start()
        await supervisor.connect()
        #expect(await eventually { harness.lastSocket?.sent.count == 1 })
        let socket = try #require(harness.lastSocket)
        let request = try #require(requests(socket).first)
        let live = EventLog()
        let liveTask = await observe(feed, into: live)
        let providers: JSONValue = .array([.object(["id": .string("latest")])])
        let settings: JSONValue = .object(["defaultModel": .string("latest")])
        let bindings: JSONValue = .array([.string("latest")])
        let issues: JSONValue = .array([.string("latest issue")])
        let themes: JSONValue = .array([.string("latest theme")])
        let sources: JSONValue = .array([.string("latest quota")])
        let latest = [
            update("keybindingsUpdated", ["keybindings": bindings, "issues": issues]),
            update("providerStatuses", ["providers": providers]),
            update("settingsUpdated", ["settings": settings]),
            update("environmentThemesUpdated", ["themes": themes]),
            update("usageLimitSourcesUpdated", ["sources": sources]),
        ]
        var wire = [snapshot("replay")]
        for index in 0..<40 {
            wire.append(update("providerStatuses", ["providers": .array([.number(Double(index))])]))
        }
        wire += latest
        let unknown = update("futureEvent", ["unknown": .bool(true)])
        wire.append(unknown)
        socket.deliver(.chunk(requestId: request.id, values: wire))
        let liveEventCount = wire.count + 1
        #expect(await eventually { await live.events.count == liveEventCount })
        #expect(values(await live.events).last == unknown)

        let late = EventLog()
        let lateTask = await observe(feed, into: late)
        #expect(await eventually { await late.events.count == 7 })
        let replay = values(await late.events)
        #expect(Array(replay.dropFirst()) == latest)
        let config = try #require(replay.first?["config"])
        #expect(config["providers"] == providers)
        #expect(config["settings"] == settings)
        #expect(config["keybindings"] == bindings)
        #expect(config["issues"] == issues)
        #expect(config["futureCapability"] == .string("preserved"))
        #expect(await feed.initialConfig(generation: 1) == config)
        #expect(requests(socket).count == 1)
        await feed.stop()
        await liveTask.value
        await lateTask.value
    }

    @Test func laterSnapshotReplacesConfigAndPreservesOnlyTheSeparateHubs() async throws {
        let harness = Harness([.succeed])
        let supervisor = ConnectionSupervisor(dependencies: harness.dependencies)
        let feed = ServerConfigFeed(supervisor: supervisor)
        defer { Task { await feed.stop(); await supervisor.disconnect() } }
        await feed.start()
        await supervisor.connect()
        #expect(await eventually { harness.lastSocket?.sent.count == 1 })
        let socket = try #require(harness.lastSocket)
        let request = try #require(requests(socket).first)
        let themes = update("environmentThemesUpdated", ["themes": .array([.string("theme")])])
        let sources = update("usageLimitSourcesUpdated", ["sources": .array([])])
        let authoritative = snapshot("editors discovered", providers: .array([.string("authoritative")]))
        socket.deliver(.chunk(requestId: request.id, values: [
            snapshot("first"), themes, sources,
            update("providerStatuses", ["providers": .array([.string("obsolete")])]),
            update("settingsUpdated", ["settings": .object(["obsolete": .bool(true)])]),
            update("keybindingsUpdated", ["keybindings": .array([.string("obsolete")]), "issues": .array([])]),
            authoritative,
        ]))
        #expect(await eventually { socket.sent.contains(.ack(request.id)) })
        let log = EventLog()
        let task = await observe(feed, into: log)
        #expect(await eventually { await log.events.count == 4 })
        #expect(values(await log.events) == [authoritative, themes, sources])
        #expect(await feed.initialConfig(generation: 1) == authoritative["config"])
        await feed.stop()
        await task.value
    }

    @Test func reconnectSupersedesWaitersAndNeverReplaysAnEarlierGeneration() async throws {
        let harness = Harness([.succeed, .succeed, .succeed])
        let supervisor = ConnectionSupervisor(dependencies: harness.dependencies)
        let feed = ServerConfigFeed(supervisor: supervisor)
        defer { Task { await feed.stop(); await supervisor.disconnect() } }
        await feed.start()
        let superseded = Task { await feed.initialConfig(generation: 1) }
        let future = Task { await feed.initialConfig(generation: 2) }
        await supervisor.connect()
        #expect(await eventually { harness.lastSocket?.sent.count == 1 })
        let first = try #require(harness.lastSocket)
        first.close()
        #expect(await eventually { harness.lastSocket !== first && harness.lastSocket?.sent.count == 1 })
        #expect(await superseded.value == nil)
        let second = try #require(harness.lastSocket)
        let request = try #require(requests(second).first)
        let secondSnapshot = snapshot("generation two")
        second.deliver(.chunk(requestId: request.id, values: [
            secondSnapshot, update("environmentThemesUpdated", ["themes": .array([.string("old")])]),
        ]))
        #expect(await future.value == secondSnapshot["config"])
        #expect(await eventually { second.sent.contains(.ack(request.id)) })
        second.close()
        #expect(await eventually { harness.lastSocket !== second && harness.lastSocket?.sent.count == 1 })
        let third = try #require(harness.lastSocket)
        let thirdRequest = try #require(requests(third).first)
        let log = EventLog()
        let task = await observe(feed, into: log)
        #expect(await eventually { await log.events.count == 1 })
        #expect(values(await log.events).isEmpty)
        guard case .subscribed(generation: 3) = await log.events.first else {
            Issue.record("Expected generation three"); return
        }
        #expect(await feed.initialConfig(generation: 2) == nil)
        let waiting = Task { await feed.initialConfig(generation: 3) }
        let thirdSnapshot = snapshot("generation three")
        third.deliver(.chunk(requestId: thirdRequest.id, values: [thirdSnapshot]))
        #expect(await waiting.value == thirdSnapshot["config"])
        #expect(await eventually { await log.events.count == 2 })
        #expect(values(await log.events) == [thirdSnapshot])
        await feed.stop()
        await task.value
    }

    @Test func cancellationAndStopResolveWaitersAndFinishListenersWithoutAConnection() async {
        let harness = Harness([])
        let supervisor = ConnectionSupervisor(dependencies: harness.dependencies)
        let feed = ServerConfigFeed(supervisor: supervisor)
        await feed.start()
        let cancelled = Task { await feed.initialConfig(generation: 1) }
        await settle()
        cancelled.cancel()
        #expect(await cancelled.value == nil)
        let log = EventLog()
        let cancelledListener = await observe(feed, into: log)
        cancelledListener.cancel()
        await cancelledListener.value
        let listener = await observe(feed, into: log)
        let pending = Task { await feed.initialConfig(generation: 1) }
        await settle()
        await feed.stop()
        #expect(await pending.value == nil)
        await listener.value
        #expect(await feed.initialConfig(generation: 1) == nil)
        var finished = await feed.events().makeAsyncIterator()
        #expect(await finished.next() == nil)
        #expect(harness.attemptCount == 0)
    }

    @Test func cleanCompletionFinishesWaitersAndAllowsARestart() async throws {
        let harness = Harness([.succeed])
        let supervisor = ConnectionSupervisor(dependencies: harness.dependencies)
        let feed = ServerConfigFeed(supervisor: supervisor)
        defer { Task { await feed.stop(); await supervisor.disconnect() } }
        await feed.start()
        let pending = Task { await feed.initialConfig(generation: 1) }
        let log = EventLog()
        let listener = await observe(feed, into: log)
        await supervisor.connect()
        #expect(await eventually { harness.lastSocket?.sent.count == 1 })
        let socket = try #require(harness.lastSocket)
        let request = try #require(requests(socket).first)
        socket.deliver(.exit(requestId: request.id, exit: .success(.null)))
        #expect(await pending.value == nil)
        await listener.value
        await feed.start()
        #expect(await eventually { requests(socket).count == 2 })
        let restarted = try #require(requests(socket).last)
        let event = snapshot("restart")
        socket.deliver(.chunk(requestId: restarted.id, values: [event]))
        #expect(await feed.initialConfig(generation: 1) == event["config"])
        await feed.stop()
        #expect(await eventually { socket.sent.contains(.interrupt(restarted.id)) })
    }

    @Test func serverFailureRetriesTheSameGenerationAndForwardsTheInterruption() async throws {
        let harness = Harness([.succeed])
        let supervisor = ConnectionSupervisor(dependencies: harness.dependencies)
        let feed = ServerConfigFeed(supervisor: supervisor)
        defer { Task { await feed.stop(); await supervisor.disconnect() } }
        await feed.start()
        await supervisor.connect()
        #expect(await eventually { harness.lastSocket?.sent.count == 1 })
        let socket = try #require(harness.lastSocket)
        let request = try #require(requests(socket).first)
        let log = EventLog()
        let task = await observe(feed, into: log)
        let first = snapshot("before retry")
        socket.deliver(.chunk(requestId: request.id, values: [first]))
        #expect(await feed.initialConfig(generation: 1) == first["config"])
        socket.deliver(.exit(requestId: request.id, exit: .failure([
            .fail(RPCTypedError(tag: "ServerSettingsError", fields: ["message": .string("retry")]))
        ])))
        #expect(await eventually { requests(socket).count == 2 })
        #expect(await log.count(where: { if case .interrupted = $0 { true } else { false } }) == 1)
        #expect(await log.count(where: { if case .subscribed(generation: 1) = $0 { true } else { false } }) == 2)
        #expect(await feed.initialConfig(generation: 1) == first["config"])
        let retry = try #require(requests(socket).last)
        #expect(retry.payload == request.payload)
        let second = snapshot("after retry")
        socket.deliver(.chunk(requestId: retry.id, values: [second]))
        #expect(await eventually { socket.sent.filter { $0 == .ack(retry.id) }.count == 1 })
        #expect(await feed.initialConfig(generation: 1) == second["config"])
        #expect(harness.attemptCount == 1)
        await feed.stop()
        await task.value
    }
}
