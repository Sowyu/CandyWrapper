import Foundation
import AppKit
import Testing
import DesignSystem
import T3Protocol
@testable import Features

/// Device sources (DeviceSourcesSettings.tsx and deviceHostsSettings.logic.ts at 4928). Device state is decoded from
/// fixed JSON; no server is called.
@MainActor
struct DeviceSourcesTests {
    typealias L = DeviceSourcesLogic
    static func json(_ text: String) -> JSONValue { try! JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }
    static func state(_ text: String) -> DevicePanelState { try! JSONValueDecoder().decode(DevicePanelState.self, from: json(text)) }
    static let ready = state("""
    {"hosts":[{"id":"local","label":"This Mac","kind":"local","platforms":[{"platform":"ios","available":true},{"platform":"android","available":false,"reason":"Install Android Studio."}]},
              {"id":"h1","label":"Studio","kind":"ssh","platforms":[{"platform":"ios","available":true}]}],
     "hostStatus":"ready","hostStatuses":{"local":{"status":"ready"},"h1":{"status":"failed","detail":"ssh: connect refused"}},
     "supportsHostRetry":true,"devices":[],"sessions":[],"onboardingCompleted":true,"agentAccessEnabled":false,"hubBasePath":"/","revision":1}
    """)
    static let studio = json(#"{"id":"h1","kind":"ssh","label":"Studio","target":"me@studio.local"}"#)
    static func settings(hosts: [JSONValue] = [studio], devices: Bool = true) -> ServerSettingsValues {
        ServerSettingsValues(.object(["enableDeviceSupport": .bool(devices), "deviceHosts": .array(hosts)]))
    }

    @Test func hostStatusReadsTheServer() {
        #expect(L.hostStatus(nil, hostId: "x") == .init(tone: .pending, label: "Loading"))
        #expect(L.hostStatus(Self.ready, hostId: "local") == nil)
        #expect(L.hostStatus(Self.ready, hostId: "h1")?.tone == .error)
        let partial = Self.state(#"{"hosts":[],"hostStatus":"ready","hostStatuses":{"a":{"status":"ready","incompletePlatforms":["ios"]},"b":{"status":"ready","androidDiscoveryIncomplete":true,"incompletePlatforms":["ios"]},"c":{"status":"starting"}},"devices":[],"sessions":[],"onboardingCompleted":true,"agentAccessEnabled":false,"hubBasePath":"/","revision":1}"#)
        #expect(L.hostStatus(partial, hostId: "a")?.label == "iOS list may be incomplete")
        #expect(L.hostStatus(partial, hostId: "b")?.label == "Device list may be incomplete")
        #expect(L.hostStatus(partial, hostId: "c") == .init(tone: .pending, label: "Starting"))
    }

    @Test func hostsGroupOnlyWhenTheyMatch() {
        let other = Self.json(#"{"id":"h1","kind":"ssh","label":"Studio 2","target":"me@studio.local"}"#)
        let same = L.group([("a", "A", [Self.studio]), ("b", "B", [Self.studio])])
        #expect(same?.count == 1 && same?.first?.members.map(\.environmentId) == ["a", "b"])
        #expect(L.group([("a", "A", [Self.studio]), ("b", "B", [other])]) == nil)
        #expect(L.group([("a", "A", [Self.studio, Self.studio])]) == nil)
    }

    @Test func rowsCarryStatusRetryAndPlatforms() {
        let rows = L.rows([.init(environmentId: "a", label: "Mac", settings: Self.settings(), state: Self.ready)], supportsEas: false)
        #expect(rows.map(\.title) == ["Local simulators", "Studio"])
        #expect(rows[0].description == "Simulators and emulators installed on this environment's machine.")
        let ssh = rows[1]
        #expect(ssh.badge == "SSH" && ssh.description == "me@studio.local")
        #expect(ssh.environments[0].status?.label == "Can't connect" && ssh.environments[0].status?.action?.retryHostId == "h1")
        let local = L.platforms(rows[0])
        #expect(local.map(\.platform) == ["ios", "android"] && local.map(\.available) == [true, false])
        #expect(local[1].detail == "Android not available\nInstall Android Studio.")
        // Devices off: the row stays and lists no environment.
        let off = L.rows([.init(environmentId: "a", label: "Mac", settings: Self.settings(devices: false), state: Self.ready)], supportsEas: false)
        #expect(off[0].environments.isEmpty)
    }

    @Test func expoRowsOnlyWhereSupported() {
        let s = ServerSettingsValues(.object(["enableDeviceSupport": .bool(true),
                                              "easDeviceHosts": .array([Self.json(#"{"id":"e1","label":"Expo","maxConcurrentSessions":2}"#)])]))
        let m = L.Member(environmentId: "a", label: "Mac", settings: s, state: Self.ready)
        #expect(L.rows([m], supportsEas: false).count == 1)
        let rows = L.rows([m], supportsEas: true)
        #expect(rows.last?.badge == "Expo" && rows.last?.description == "Up to 2 at once")
    }

    @Test func rowViewShowsProblemsAndRetry() {
        let rows = L.rows([.init(environmentId: "a", label: "Mac", settings: Self.settings(), state: Self.ready)], supportsEas: false)
        let view = DeviceSourceRowView(row: rows[1], testing: [])
        var retried: (String, String?)?
        view.onAction = { retried = ($0, $1) }
        view.frame = NSRect(x: 0, y: 0, width: 700, height: view.height(forWidth: 700))
        view.layoutSubtreeIfNeeded()
        #expect(view.height(forWidth: 700) > 60)
        let retry = UseInAnotherAppTests.find(McpTextButton.self, in: view)
        retry?.performAction()
        #expect(retried?.0 == "a" && retried?.1 == "h1")
    }
}
