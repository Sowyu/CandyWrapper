import Foundation
import Testing
@testable import T3Protocol

struct DevicePanelProtocolTests {
    @Test func proxyURLsKeepHostAndCredentialOnEnvironment() throws {
        let url = try #require(DevicePanelWire.url(base: URL(string: "https://host.test")!, hubPath: "/api/device-hub", platform: "android", deviceId: "emulator-5554", hostId: "remote", ticket: "secret&value", video: true))
        #expect(url.host == "host.test")
        #expect(url.scheme == "wss")
        #expect(url.path == "/api/device-hub/vendor/serve-emu/ws")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(query.contains(URLQueryItem(name: "wsTicket", value: "secret&value")))
        #expect(query.contains(URLQueryItem(name: "hostId", value: "remote")))
        #expect(DevicePanelWire.url(base: url, hubPath: "https://elsewhere.test", platform: "ios", deviceId: "a", hostId: "local", ticket: "x", video: true) == nil)
    }
    @Test func fragmentedJPEGAndMultipleFrames() {
        var parser = DevicePanelJPEGParser()
        #expect(parser.push(Data([1, 2, 0xff])).isEmpty)
        #expect(parser.push(Data([0xd8, 3, 4, 0xff])).isEmpty)
        #expect(parser.push(Data([0xd9, 0xff, 0xd8, 5, 0xff, 0xd9])) == [Data([0xff, 0xd8, 3, 4, 0xff, 0xd9]), Data([0xff, 0xd8, 5, 0xff, 0xd9])])
    }
    @Test func inputUsesPlatformFramingAndClampsCapturedDrag() throws {
        let ios = DevicePanelWire.touch(platform: "ios", phase: "end", x: -1, y: 2)
        #expect(ios.first == 3)
        let payload = try JSONDecoder().decode(JSONValue.self, from: ios.dropFirst())
        #expect(payload["x"]?.doubleValue == 0)
        #expect(payload["y"]?.doubleValue == 1)
        let android = try JSONDecoder().decode(JSONValue.self, from: DevicePanelWire.touch(platform: "android", phase: "begin", x: 0.2, y: 0.3))
        #expect(android["action"]?.stringValue == "down")
    }
    @Test func missingRuntimeIsNotReady() throws {
        let json = #"{"hosts":[{"id":"local","label":"Local","kind":"local","platforms":[{"platform":"ios","available":true}]}],"hostStatus":"ready","devices":[],"sessions":[],"onboardingCompleted":false,"agentAccessEnabled":false,"hubBasePath":"/api/device-hub","revision":1}"#
        let state = try JSONDecoder().decode(DevicePanelState.self, from: Data(json.utf8))
        #expect(state.platformMessage("ios").contains("Install a runtime"))
        #expect(state.platformMessage("android") == "Android support was not detected.")
    }
}
