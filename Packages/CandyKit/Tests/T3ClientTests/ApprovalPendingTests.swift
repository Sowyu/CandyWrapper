import Foundation
import Testing
import T3Protocol
@testable import T3Client

/// T3 Connect device approval on the waiting device (4928 client-runtime/src/authorization/service.ts:148-163,
/// connection/supervisor.ts:49-52 and 1285-1305, contracts/src/auth.ts:337-350).
struct ApprovalPendingTests {
    static let pending = T3ConnectError.approvalPending(host: "Studio", verificationCode: "UVWX-YZ23", traceId: "trace-1")
    static var located: LocatedConnectionFailure { LocatedConnectionFailure(T3Connect.failure(for: pending), T3Connect.locate(pending)) }

    @Test func verificationCodeMatchesT3() {
        #expect(ConnectDeviceApproval.verificationCode(thumbprint: "abcdefghXYZ") == "UVWX-YZ23")
        #expect(ConnectDeviceApproval.verificationCode(thumbprint: "AAAAAAAA") == "2222-2222")
        #expect(ConnectDeviceApproval.verificationCode(thumbprint: "-_-_-_-_") == "YZYZ-YZYZ")
    }

    @Test func errorBodyIsRecognised() throws {
        let body = try JSONDecoder().decode(EnvironmentHTTPErrorBody.self, from: Data(
            #"{"_tag":"EnvironmentConnectApprovalPendingError","code":"connect_approval_pending","traceId":"t"}"#.utf8))
        #expect(body.isConnectApprovalPending)
        let other = try JSONDecoder().decode(EnvironmentHTTPErrorBody.self, from: Data(#"{"_tag":"EnvironmentForbiddenError"}"#.utf8))
        #expect(!other.isConnectApprovalPending)
    }

    @Test func approvalPendingIsATransientServerFailure() {
        let info = Self.located.info
        #expect(info.reason == ConnectionFailureInfo.approvalPendingReason)
        #expect(!info.blocked && info.hop == .server && info.via == .relay)
        #expect(info.cause == "approval_pending" && info.traceId == "trace-1")
        #expect(Self.located.failure == .transient("Approve this device on Studio. It shows code UVWX-YZ23."))
    }

    @Test func approvalWaitsRetryEveryFourSecondsWithoutClimbingTheLadder() async {
        let transient = ConnectionFailure.transient("refused")
        let h = Harness([.fail(transient), .fail(Self.located), .fail(Self.located), .fail(transient)])
        let s = ConnectionSupervisor(dependencies: h.dependencies)
        await s.connect()
        #expect(await eventually { h.recordedSleeps.count == 4 })
        // The second ordinary failure still takes the ladder's second step.
        #expect(h.recordedSleeps == [1_500, 4_000, 4_000, 3_000].map { .milliseconds($0) })
        await s.disconnect()
    }

    @Test func waitingStateShowsTheCode() async {
        let h = Harness([.fail(Self.located)])
        let s = ConnectionSupervisor(dependencies: h.dependencies)
        await s.connect()
        #expect(await eventually { h.recordedSleeps.count == 1 })
        let state = await s.state
        #expect(state.awaitingApproval)
        #expect(state.status == .reconnecting)
        #expect(state.lastFailure?.contains("UVWX-YZ23") == true)
        await s.disconnect()
        #expect(await !s.state.awaitingApproval)
    }
}
