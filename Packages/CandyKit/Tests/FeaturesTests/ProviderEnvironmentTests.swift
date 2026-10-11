import Foundation
import Testing
import T3Protocol
@testable import Features

/// Provider environment variables, accent color and the version advisory, against ProviderInstanceCard.tsx,
/// lib/color.ts, providerInstanceDisplay.ts and providerStatus.test.ts.
struct ProviderEnvironmentTests {
    typealias L = ProviderEnvironmentLogic

    @Test func namesFollowTheEnvironmentPattern() {
        #expect(L.isValidName("API_KEY"))
        #expect(L.isValidName("_x1"))
        #expect(!L.isValidName("1X"))
        #expect(!L.isValidName("A-B"))
        #expect(!L.isValidName(""))
        #expect(!L.isValidName("É"))
    }

    @Test func publishSkipsBlankRowsAndHoldsHalfTypedOnes() {
        let blank = L.Draft(id: 1)
        let good = L.Draft(id: 2, L.Variable(name: " API_KEY ", value: "v", sensitive: false))
        #expect(L.publish([blank, good]) == [L.Variable(name: "API_KEY", value: "v", sensitive: false)])
        var bad = L.Draft(id: 3)
        bad.name = "1BAD"
        #expect(L.publish([good, bad]) == nil)
        var valueOnly = L.Draft(id: 4)
        valueOnly.value = "x"
        #expect(L.publish([valueOnly]) == nil)
        var plainBlank = L.Draft(id: 5)
        plainBlank.sensitive = false
        #expect(L.publish([plainBlank]) == nil)
    }

    @Test func instanceDropsEmptyEnvironment() {
        let base: JSONValue = .object(["driver": .string("codex"), "environment": .array([])])
        #expect(L.instance(base, environment: [])["environment"] == nil)
        let next = L.instance(base, environment: [.init(name: "A", value: "1", sensitive: true), .init(name: " ", value: "x", sensitive: true)])
        #expect(L.variables(next) == [.init(name: "A", value: "1", sensitive: true)])
    }

    @Test func fieldValueSetsReplacesAndClears() {
        let f = L.fields("cursor")[0]
        #expect(f.name == "CURSOR_API_KEY")
        let other = L.Variable(name: "X", value: "1", sensitive: false)
        let set = L.setting([other], field: f, to: " key ")
        #expect(set == [other, .init(name: "CURSOR_API_KEY", value: "key", sensitive: true)])
        #expect(L.setting(set, field: f, to: "") == [other])
    }

    @Test func accentColorAndHsvRoundTrip() {
        #expect(L.accentColor(" #2563eb ") == "#2563eb")
        #expect(L.accentColor("#2563e") == nil)
        #expect(L.accentColor("red") == nil)
        for hex in ["#2563eb", "#000000", "#ffffff", "#ff0000", "#10b981"] {
            let v = L.hsv(hex)
            #expect(L.hex(h: v.h, s: v.s, v: v.v) == hex)
        }
        #expect(L.hsv("#ff0000").h == 0)
    }

    private func provider(advisory: JSONValue?, compatibility: JSONValue?) -> ServerProvider {
        var p = ServerProvider(instanceId: ProviderInstanceId(rawValue: "codex"), driver: "codex")
        p.versionAdvisory = advisory
        p.compatibilityAdvisory = compatibility
        return p
    }

    @Test func advisoryMatchesT3() {
        let behind: JSONValue = .object(["status": .string("behind_latest"), "currentVersion": .string("1.0.0"), "latestVersion": .string("2.0.0"),
                                         "updateCommand": .string("npm install -g fixture@latest"), "canUpdate": .bool(true), "message": .null])
        let supportedBrokenLatest: JSONValue = .object(["status": .string("supported"), "latestVersionStatus": .string("broken"), "message": .null,
                                                        "recommendedRange": .null, "recommendedVersion": .null])
        typealias A = ProviderVersionAdvisoryLogic
        #expect(A.presentation(provider(advisory: behind, compatibility: supportedBrokenLatest), enabled: true) == nil)
        let update = A.presentation(provider(advisory: behind, compatibility: nil), enabled: true)
        #expect(update?.title == "Update available")
        #expect(update?.detail == "Update available: install v2.0.0.")
        #expect(update?.updateCommand == "npm install -g fixture@latest")
        #expect(A.canUpdate(provider(advisory: behind, compatibility: nil)))

        let current: JSONValue = .object(["status": .string("current"), "updateCommand": .string("npm i"), "canUpdate": .bool(true),
                                          "canInstallVersion": .bool(true)])
        let broken: JSONValue = .object(["status": .string("broken"), "latestVersionStatus": .string("broken"),
                                         "message": .string("This version drops turns. Use 1.9.0."), "recommendedRange": .null, "recommendedVersion": .string("1.9.0")])
        let b = A.presentation(provider(advisory: current, compatibility: broken), enabled: true)
        #expect(b == .init(title: "Known broken version", detail: "This version drops turns. Use 1.9.0.", updateCommand: nil, strong: true,
                           targetVersion: "1.9.0", warning: true))
        #expect(A.canInstallRecommended(provider(advisory: current, compatibility: broken)))
        // Disabled providers do not show compatibility.
        #expect(A.presentation(provider(advisory: current, compatibility: broken), enabled: false) == nil)
        let graceful: JSONValue = .object(["status": .string("graceful"), "message": .null, "recommendedVersion": .null, "recommendedRange": .string(">=2.1.0")])
        let g = A.presentation(provider(advisory: nil, compatibility: graceful), enabled: true)
        #expect(g?.title == "Limited support")
        #expect(g?.detail == "Use >=2.1.0 for full support.")
        #expect(g?.strong == false)
    }
}
