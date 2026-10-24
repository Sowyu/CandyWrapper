import Foundation
import T3Protocol
import Testing
@testable import CandyHelper

/// Log lines keep what diagnoses a failure and lose anything that could be a credential.
@Suite struct RedactTests {
    @Test func keepsErrorsHostsIdsAndVersions() {
        let line = "HTTP 401 EnvironmentAuthInvalidError invalid_credential from 127.0.0.1:3773, machine 4f370ad2-f73f-49f3-b851-ed4a737afc6f, 0.1.3-nightly.20261023.3566"
        #expect(redact(line) == line)
    }

    @Test func masksCodesTokensAndHexSecrets() {
        #expect(redact("code ABCD2345EFGH") == "code [redacted]")
        #expect(redact("Bearer eyJ2IjoxLCJraW5kIjoic2Vzc2lvbiJ9.c2lnbmF0dXJlMTIzNDU2Nzg") == "Bearer [redacted]")
        #expect(redact("key 9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08") == "key [redacted]")
    }

    @Test func refusalsSayWhatT3Said() {
        let body = try! JSONDecoder().decode(EnvironmentHTTPErrorBody.self, from: Data(#"{"_tag":"EnvironmentAuthInvalidError","reason":"invalid_credential"}"#.utf8))
        #expect(MachineLink.statusText(401, body) == "HTTP 401 EnvironmentAuthInvalidError invalid_credential")
        #expect(MachineLink.statusText(401, nil) == "HTTP 401 with no body")
    }
}
