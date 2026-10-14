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
}
