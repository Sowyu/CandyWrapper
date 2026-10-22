import AppKit
import DesignSystem
import Testing
import T3Protocol
@testable import Features

/// `presentConnectionDiagnosis` against client-runtime/src/connection/diagnosis.test.ts in 3473.
struct ConnectionDiagnosisTests {
    static func unavailable(_ cause: String) -> ConnectionFailureInfo {
        ConnectionFailureInfo(reason: "endpoint-unavailable", blocked: false, detail: "Relay could not reach the environment endpoint (endpoint_request_failed).",
                              hop: cause == "tunnel_down" ? .tunnel : .server, via: .relay, cause: cause,
                              httpStatus: cause == "tunnel_down" ? 530 : 502, traceId: "trace-1")
    }

    static func diagnose(_ failure: ConnectionFailureInfo?, via: ConnectionFailureInfo.Via = .relay, offline: Bool = false,
                         relayStatus: ConnectionDiagnosis.RelayStatus? = nil) -> ConnectionDiagnosis? {
        ConnectionDiagnosis.present(.init(hostLabel: "Mac mini", offline: offline, failure: failure, via: via, relayStatus: relayStatus,
                                          attempt: failure == nil ? 0 : 3, retryAt: failure == nil ? nil : Date(timeIntervalSince1970: 1_792_411_230)))
    }

    static func results(_ d: ConnectionDiagnosis?) -> [String]? { d?.hops.map { "\($0.hop.rawValue):\($0.result.rawValue)" } }

    @Test func tellsAWorkingTunnelApartFromT3CodeNotAnswering() {
        let d = Self.diagnose(Self.unavailable("origin_unreachable"), via: .direct)
        #expect(d?.headline == "Tunnel works, but T3 Code on Mac mini did not answer")
        #expect(Self.results(d) == ["device:ok", "relay:ok", "tunnel:ok", "server:failed"])
        #expect(d?.moreInfoURL?.hasSuffix("#the-tunnel-works-but-t3-code-does-not-answer") == true)
        #expect(d?.facts.map(\.label) == ["Cause", "HTTP status", "Attempts", "Next retry", "Route", "Error", "Trace ID"])
        #expect(d?.facts.first { $0.label == "Next retry" }?.value == "2026-10-19T12:00:30.000Z")
        let text = d!.text(hostLabel: "Mac mini")
        #expect(text.hasPrefix("T3 Code connection to Mac mini: Tunnel works, but T3 Code on Mac mini did not answer\n\nThis device: ok\n"))
        #expect(text.contains("T3 Code on Mac mini: FAILED") && text.contains("\nTrace ID: trace-1\n\nMore info: https://"))
    }

    @Test func blamesThisDeviceWhenItCannotReachATunnelTheRelayReached() {
        let failure = ConnectionFailureInfo(reason: "network", blocked: false, detail: "Failed to fetch", hop: .tunnel, via: .relay)
        let d = Self.diagnose(failure, via: .direct)
        #expect(d?.headline == "This device can't reach Mac mini's tunnel")
        #expect(d?.hops.count == 4)
        #expect(d?.steps.joined(separator: " ").contains("On Mac mini") == false)
    }

    @Test func stopsAtT3ConnectAndKeepsTheNetworkOutOfARelayError() {
        let transport = ConnectionFailureInfo(reason: "relay-unavailable", blocked: false, detail: "x", hop: .relay)
        #expect(Self.diagnose(transport)?.headline == "This device can't reach T3 Connect")
        #expect(Self.results(Self.diagnose(transport)) == ["device:ok", "relay:failed", "tunnel:unchecked", "server:unchecked"])
        let answered = ConnectionFailureInfo(reason: "relay-unavailable", blocked: false, detail: "x", hop: .relay, cause: "relay_error", httpStatus: 502)
        #expect(Self.diagnose(answered)?.headline == "T3 Connect returned an error")
        #expect(Self.diagnose(answered)?.steps.joined(separator: " ").contains("this device") == false)
    }

    @Test func offlineComesFirstAndTheRelayHealthCheckExplainsAnUntriedRoute() {
        let offline = Self.diagnose(Self.unavailable("tunnel_down"), offline: true)
        #expect(offline?.headline == "This device is offline" && Self.results(offline)?.first == "device:failed")
        #expect(Self.diagnose(nil, relayStatus: .init(status: "offline", endpointFailure: "tunnel_down", endpointStatus: 530))?.headline
            == "Mac mini's tunnel is offline")
        let origin = Self.diagnose(nil, via: .direct, relayStatus: .init(status: "offline", endpointFailure: "origin_unreachable"))
        #expect(origin?.hops.map(\.hop) == [.device, .relay, .tunnel, .server])
        // A failure with its own cause keeps the relay's status out.
        let direct = ConnectionFailureInfo(reason: "network", blocked: false, detail: "Failed to fetch", hop: .server, via: .direct)
        let d = Self.diagnose(direct, via: .direct, relayStatus: .init(status: "offline", endpointFailure: "tunnel_down", endpointStatus: 530))
        #expect(d?.facts.contains { $0.label == "HTTP status" } == false)
        #expect(d?.headline == "T3 Code on Mac mini did not answer" && d?.moreInfoURL == nil)
        #expect(Self.diagnose(nil) == nil)
    }

    /// Copy diagnostics carries no credentials, whatever an error quotes.
    @Test func copiedErrorDropsCredentials() {
        let leaky = ConnectionFailureInfo(reason: "network", blocked: false,
                                          detail: "echo Authorization: Bearer abc.def, DPoP xyz; https://me:pw@host/pair?token=s3cret#token=frag",
                                          hop: .server, via: .direct)
        let text = Self.diagnose(leaky, via: .direct)!.text(hostLabel: "Mac mini")
        for secret in ["abc.def", "xyz", "me:pw", "s3cret", "frag"] { #expect(!text.contains(secret)) }
        #expect(text.contains("Bearer [redacted]") && text.contains("https://[redacted]@host/pair?token=[redacted]#token=[redacted]"))
    }

    /// The retry countdown ticks only while its row can be seen: scrolled out it stops, scrolled back it starts,
    /// and out of a window it holds nothing (ConnectionDiagnosisDetails.tsx:65-74 ticks while mounted).
    @MainActor @Test func countdownStopsOutOfView() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: .borderless, backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 3000))
        let row = ConnectionDiagnosisSummaryView(frame: NSRect(x: 0, y: 2800, width: 300, height: 40))
        document.addSubview(row)
        scroll.documentView = document
        window.contentView = scroll
        scroll.contentView.scroll(to: .zero)
        row.configure(Self.diagnose(Self.unavailable("tunnel_down"))!, retryAt: Date(timeIntervalSinceNow: 30), attempt: 2, expanded: false)
        row.layoutSubtreeIfNeeded()
        #expect(LabelClock.shared.due(for: row) == nil)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 2790))
        for _ in 0..<100 where LabelClock.shared.due(for: row) == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(LabelClock.shared.due(for: row) != nil)
        row.removeFromSuperview()
        #expect(LabelClock.shared.due(for: row) == nil)
    }
}
