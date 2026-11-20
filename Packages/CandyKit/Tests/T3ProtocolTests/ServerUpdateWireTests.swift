import Foundation
import Testing
import T3Protocol

/// Server self-update frames as the contracts define them (server.ts:949-1003, environment.ts:72-96, 182-211).
struct ServerUpdateWireTests {
    func json(_ text: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }

    @Test func capabilitiesPickTheUpdatePath() throws {
        let descriptor = try JSONDecoder().decode(EnvironmentDescriptor.self, from: Data("""
        {"environmentId":"e","label":"box","platform":{"os":"darwin","arch":"arm64"},"serverVersion":"0.0.46-nightly.20261009.2861",
         "orchestrationProtocolVersion":2,"capabilities":{"repositoryIdentity":true,"serverSelfUpdate":"boot-service",
         "serverSelfUpdateProgress":true,"serverUpdateThreadContinuation":true}}
        """.utf8))
        let caps = ServerUpdateCapabilities(descriptor.capabilities)
        #expect(caps.selfUpdate == .bootService)
        #expect(caps.progress && caps.threadContinuation && !caps.desktopAppUpdate)
        #expect(caps.canUpdateRemotely)

        // A desktop app that predates the remote trigger, and a manual install with its proven prefix.
        #expect(!ServerUpdateCapabilities(["serverSelfUpdate": .string("desktop-managed")]).canUpdateRemotely)
        let manual = ServerUpdateCapabilities(["serverInstallation": try json(#"{"kind":"npm-global","prefix":"/opt/t3"}"#)])
        #expect(manual.selfUpdate == nil && !manual.canUpdateRemotely)
        #expect(manual.installation?["prefix"]?.stringValue == "/opt/t3")
        #expect(ServerUpdateCapabilities(["serverSelfUpdate": .string("later-method")]).selfUpdate == .other("later-method"))
    }

    @Test func progressFrames() throws {
        #expect(ServerSelfUpdateProgressEvent(try json(#"{"type":"progress","stage":"downloading"}"#)) == .progress(.downloading))
        #expect(ServerSelfUpdateProgressEvent(try json(#"{"type":"progress","stage":"installing"}"#)) == .progress(.installing))
        let complete = ServerSelfUpdateProgressEvent(try json("""
        {"type":"complete","result":{"targetVersion":"0.0.47","method":"desktop-app","desktopUpdateToken":"tok"}}
        """))
        #expect(complete == .complete(ServerSelfUpdateResult(targetVersion: "0.0.47", method: "desktop-app", desktopUpdateToken: "tok")))
        if case .complete(let r)? = complete { #expect(r.needsDesktopCommit) }
        #expect(ServerSelfUpdateProgressEvent(try json(#"{"type":"progress","stage":"teleporting"}"#)) == nil)
    }

    @Test func inputCarriesTheContinuationOptInOnlyWhenOn() throws {
        #expect(ServerUpdateLogic.input(targetVersion: "1.2.3", continueRunningThreads: false) == .object(["targetVersion": .string("1.2.3")]))
        #expect(ServerUpdateLogic.input(targetVersion: "1.2.3", continueRunningThreads: true)
                == .object(["targetVersion": .string("1.2.3"), "continueRunningThreads": .bool(true)]))
    }

    @Test func readyEventsProveTheRestart() throws {
        let ready = try #require(ServerLifecycleReady(try json("""
        {"version":1,"sequence":4,"type":"ready","payload":{"at":"2026-10-14T00:00:00.000Z",
         "environment":{"environmentId":"e","label":"box","serverVersion":"2.0.0","capabilities":{}},
         "updateOutcome":{"id":"u1","fromVersion":"1.0.0","targetVersion":"2.0.0","status":"committed"}}}
        """)))
        let withId = ServerSelfUpdateResult(targetVersion: "2.0.0", method: "boot-service", updateId: "u1")
        #expect(ServerUpdateLogic.matchesReady(withId, ready))
        #expect(ServerUpdateLogic.failure(withId, ready) == nil)
        // Another update's outcome does not match; a legacy result matches by version.
        #expect(!ServerUpdateLogic.matchesReady(ServerSelfUpdateResult(targetVersion: "2.0.0", method: "boot-service", updateId: "u9"), ready))
        #expect(ServerUpdateLogic.matchesReady(ServerSelfUpdateResult(targetVersion: "2.0.0", method: "respawn"), ready))
        #expect(ServerLifecycleReady(try json(#"{"type":"welcome","payload":{}}"#)) == nil)

        let failed = ServerLifecycleReady(serverVersion: "1.0.0", updateOutcome: .init(id: "u1", fromVersion: "1.0.0", targetVersion: "2.0.0", status: "failed", reason: nil))
        #expect(ServerUpdateLogic.failure(withId, failed) == "The service launcher resumed without committing the requested server version.")
    }

    @Test func aFailureClearsOnceTheServerRunsAnotherVersion() {
        let failed = ServerUpdateState.failed(stage: .resuming, fromVersion: "1.0.0", targetVersion: "2.0.0", message: "x")
        #expect(failed.forServerVersion("1.0.0") == failed)
        #expect(failed.forServerVersion(nil) == failed)
        #expect(failed.forServerVersion("2.0.0") == .idle)
        let running = ServerUpdateState.running(stage: .downloading, fromVersion: "1.0.0", targetVersion: "2.0.0")
        #expect(running.forServerVersion("2.0.0") == running)
    }

    /// #27275: a launcher host that comes back as another process ends the wait; only this update's outcome counts.
    @Test func acceptingProcessEndsTheWait() {
        let result = ServerSelfUpdateResult(targetVersion: "2.0.0", method: "boot-service", updateId: "u1")
        let same = ServerLifecycleReady(serverVersion: "1.0.0", at: "t0")
        let other = ServerLifecycleReady(serverVersion: "1.0.0", at: "t1")
        #expect(!ServerUpdateLogic.matchesResume(result, same, acceptedAt: "t0"))
        #expect(ServerUpdateLogic.matchesResume(result, other, acceptedAt: "t0"))
        #expect(!ServerUpdateLogic.matchesResume(result, other))
        let foreign = ServerLifecycleReady(serverVersion: "1.0.0", updateOutcome: .init(id: "u0", fromVersion: "1.0.0", targetVersion: "1.5.0",
                                                                                        status: "rolled-back", reason: "old reason"), at: "t1")
        #expect(ServerUpdateLogic.failure(result, foreign) == "The service launcher resumed without committing the requested server version.")
        let ready = ServerLifecycleReady(.object(["type": .string("ready"), "payload": .object([
            "at": .string("2026-11-19T00:00:00.000Z"), "environment": .object(["serverVersion": .string("2.0.0")])])]))
        #expect(ready?.at == "2026-11-19T00:00:00.000Z")
    }

    @Test func npmRelease() throws {
        #expect(ServerNpmRelease.input(spec: "nightly") == .object(["spec": .string("nightly")]))
        #expect(ServerNpmRelease.input(spec: "0.0.51-nightly.20261101.4") != nil)
        #expect(ServerNpmRelease.input(spec: "beta") == nil)
        #expect(ServerNpmRelease.spec(channel: "stable") == "latest")
        let release = try JSONValue.object(["version": .string("0.0.51"), "databaseMigration": .number(42)]).decode(as: ServerNpmRelease.self)
        #expect(release == ServerNpmRelease(version: "0.0.51", databaseMigration: 42))
        let caps = ServerUpdateCapabilities(["serverUpdateStaging": .bool(true), "npmReleaseLookup": .bool(true)])
        #expect(caps.staging && caps.npmReleaseLookup)
        #expect(ServerUpdateLogic.input(targetVersion: "1", continueRunningThreads: false, channel: "nightly", targetDatabaseMigration: 3, stageOnly: true)
                == .object(["targetVersion": .string("1"), "channel": .string("nightly"), "targetDatabaseMigration": .number(3), "stageOnly": .bool(true)]))
    }
}
