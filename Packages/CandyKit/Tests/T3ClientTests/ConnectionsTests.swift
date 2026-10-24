import Foundation
import Testing
import T3Protocol
@testable import T3Client
@testable import T3Transport

/// Pairing input, route order and the Connections status words, against T3's source.
struct ConnectionsTests {
    @Test func pastedPairingURLSplitsIntoHostAndCode() {
        // parsePairingUrlFields: direct, legacy query, hosted, and text without a token.
        #expect(Pairing.splitPairingURL("http://192.168.1.5:3773/pair#token=ABCD2345EFGH")! == ("http://192.168.1.5:3773", "ABCD2345EFGH"))
        #expect(Pairing.splitPairingURL("http://192.168.1.5:3773/pair?token=ABCD2345EFGH")! == ("http://192.168.1.5:3773", "ABCD2345EFGH"))
        #expect(Pairing.splitPairingURL("https://app.t3.codes/pair?host=https%3A%2F%2Fmac.tail.ts.net&label=Mac#token=XYZ")!
                == ("https://mac.tail.ts.net", "XYZ"))
        #expect(Pairing.splitPairingURL("mac.local:3773/pair#token=Q")! == ("https://mac.local:3773", "Q"))
        #expect(Pairing.splitPairingURL("backend.example.com") == nil)
        #expect(Pairing.splitPairingURL("") == nil)
    }

    @Test func fieldsAndBaseURLUseT3sMessages() throws {
        #expect(throws: PairingError("Enter a backend host.")) { try Pairing.fields(host: " ", code: "X") }
        #expect(throws: PairingError("Enter a pairing code.")) { try Pairing.fields(host: "h", code: "") }
        #expect(try Pairing.fields(host: "http://h:1/pair#token=T", code: "").code == "T")
        #expect(try Pairing.baseURL(host: "mac.tail.ts.net").absoluteString == "https://mac.tail.ts.net/")
        #expect(try Pairing.baseURL(host: "wss://h:9/x?y#z").absoluteString == "https://h:9/")
        #expect(try Pairing.baseURL(host: "http://127.0.0.1:47391").absoluteString == "http://127.0.0.1:47391/")
        #expect(throws: PairingError("Backend URL is invalid.")) { try Pairing.baseURL(host: "ftp://h") }
    }

    @Test func compatibilityTextNamesTheServer() throws {
        func descriptor(_ v: Int?) throws -> EnvironmentDescriptor {
            var o: [String: JSONValue] = ["environmentId": .string("e"), "label": .string("Studio"), "serverVersion": .string("1"),
                                          "capabilities": .object([:])]
            if let v { o["orchestrationProtocolVersion"] = .number(Double(v)) }
            return try JSONValue.object(o).decode(as: EnvironmentDescriptor.self)
        }
        #expect(Pairing.compatibilityError(try descriptor(2)) == nil)
        #expect(Pairing.compatibilityError(try descriptor(nil)) == "This client requires a newer server. Update T3 Code on Studio to connect.")
        #expect(Pairing.compatibilityError(try descriptor(3))?.hasPrefix("This client is not supported by this server.") == true)
    }

    @Test func httpErrorsReadLikeT3() throws {
        let url = URL(string: "http://h/oauth/token")!
        let body = try JSONDecoder().decode(EnvironmentHTTPErrorBody.self, from: Data(#"{"_tag":"EnvironmentAuthInvalidError","traceId":"abc"}"#.utf8))
        #expect(Pairing.presented(EnvironmentHTTPError.status(401, body), url: url) as? PairingError
                == PairingError("The environment credential is invalid.", traceId: "abc"))
        #expect((Pairing.presented(EnvironmentHTTPError.status(502, nil), url: url) as? PairingError)?.message
                == "Remote environment endpoint http://h/oauth/token returned undeclared status 502.")
        #expect((Pairing.presented(EnvironmentHTTPError.timedOut, url: url) as? PairingError)?.message
                == "Remote environment endpoint http://h/oauth/token timed out after 10000ms.")
    }

    @Test func routesSortByKindAndLabelLikeT3() {
        let u = { (s: String) in URL(string: s)! }
        #expect(EnvironmentRoute.kind(u("http://127.0.0.1:3773")) == .loopback)
        #expect(EnvironmentRoute.kind(u("http://192.168.1.4")) == .lan)
        #expect(EnvironmentRoute.kind(u("http://mini.local")) == .lan)
        #expect(EnvironmentRoute.kind(u("http://100.80.1.2")) == .tailnet)
        #expect(EnvironmentRoute.kind(u("https://box.example.com")) == .public)
        #expect(EnvironmentRoute.label(u("https://box.example.com")) == "box.example.com")
        let routes = EnvironmentRoute.upsert(u("http://192.168.1.4:3773"), into: [u("https://mac.tail.ts.net"), u("https://box.example.com")])
        #expect(routes.map(EnvironmentRoute.label) == ["LAN", "Tailscale", "box.example.com"])
        #expect(EnvironmentRoute.upsert(u("http://192.168.1.4:3773/"), into: routes).count == 3)
        #expect(EnvironmentRoute.connectionId(environmentId: "e", u("HTTP://Mini.Local:80/")) == "bearer:e:http://mini.local")
    }

    @Test func rowStatusUsesTheShortWords() {
        var s = ConnectionState()
        #expect(EnvironmentRowStatus(enabled: false, state: s).text == "Off")
        #expect(EnvironmentRowStatus(enabled: true, state: nil).text == "Not connected")
        s.phase = .connecting; s.attempt = 1
        #expect(EnvironmentRowStatus(enabled: true, state: s).text == "Connecting")
        s.phase = .backoff; s.lastFailure = "boom"
        #expect(EnvironmentRowStatus(enabled: true, state: s) == EnvironmentRowStatus(enabled: true, state: s))
        #expect(EnvironmentRowStatus(enabled: true, state: s).text == "Reconnecting: boom")
        #expect(EnvironmentRowStatus(enabled: true, state: s).isError)
        #expect(s.statusText == "Failed to connect. Reconnecting... Reason: boom")
        s.phase = .blocked(.authentication)
        #expect(EnvironmentRowStatus(enabled: true, state: s).text == "Connection failed: boom")
        s.phase = .blocked(.unsupported)
        #expect(EnvironmentRowStatus(enabled: false, state: s).text == "Client not supported")
        s.phase = .connected
        #expect(EnvironmentRowStatus(enabled: true, state: s).text == "Connected")
        #expect(EnvironmentRowStatus.transport(routes: [URL(string: "http://127.0.0.1:47391")!], inUse: nil) == "http://127.0.0.1:47391/")
        let two = [URL(string: "http://192.168.1.4:3773")!, URL(string: "https://mac.tail.ts.net")!]
        #expect(EnvironmentRowStatus.transport(routes: two, inUse: nil) == "LAN")
        #expect(EnvironmentRowStatus.transport(routes: two, inUse: two[1]) == "via Tailscale")
    }
}
