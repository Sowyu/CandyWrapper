import Testing
import Foundation
import AppKit
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

struct ProviderSetupTests {
    @Test func collisionAndValidation() {
        let reserved: Set<String> = ["codex", "claudeAgent", "codex_2"]
        #expect(ProviderSetupLogic.instanceID(driver: "codex", label: "Codex", existing: reserved) == "codex_3")
        #expect(ProviderSetupLogic.instanceID(driver: "codex", label: " Work / account! ", existing: []) == "codex_work_account")
        #expect(ProviderSetupLogic.instanceID(driver: "acpRegistry", label: "ACP Registry", existing: []) == "acpRegistry_custom")
        #expect(ProviderSetupLogic.validation("1bad", existing: []) != nil)
        #expect(ProviderSetupLogic.validation("é", existing: []) != nil)
        #expect(ProviderSetupLogic.validation(String(repeating: "a", count: 65), existing: []) != nil)
        #expect(ProviderSetupLogic.validation("codex", existing: reserved) == "An instance named 'codex' already exists.")
        #expect(ProviderSetupLogic.validation("Work-2_test", existing: []) == nil)
    }
    @Test func creationIsAtomicAndCodexUsesExistingRuntime() {
        let json = ProviderSetupLogic.create(id: "codex_work", driver: "codex", label: " Work ", config: ["binaryPath": .string("/fixture/codex")], accent: "invalid")
        #expect(json["patch"] == .object([:]))
        let mutation = json["providerInstanceMutation"]!
        #expect(mutation["operation"] == .string("create"))
        #expect(mutation["instance"]?["displayName"] == .string("Work"))
        #expect(mutation["instance"]?["config"]?["setupMode"] == .string("existing"))
        #expect(mutation["instance"]?["accentColor"] == nil)
    }
    @Test func responseRequiresActiveFlowAndInteraction() {
        #expect(ProviderSetupLogic.response(instance: "claudeAgent", state: .object([:]), response: .null) == nil)
        let state: JSONValue = .object(["flowId": .string("flow"), "interaction": .object(["id": .string("prompt")])])
        let response: JSONValue = .object(["type": .string("terminal"), "data": .string("x")])
        let payload = ProviderSetupLogic.response(instance: "claudeAgent", state: state, response: response)
        #expect(payload?["interactionId"] == .string("prompt"))
        #expect(payload?["flowId"] == .string("flow"))
        #expect(payload?["response"] == response)
    }
    @Test func terminalRollingWindowsAndUnicodePastes() {
        #expect(ProviderSetupLogic.terminalDelta(output: "abcdef", offset: 6, previousEnd: nil) == .reset("abcdef"))
        #expect(ProviderSetupLogic.terminalDelta(output: "cdefgh", offset: 8, previousEnd: 6) == .write("gh"))
        #expect(ProviderSetupLogic.terminalDelta(output: "cdefgh", offset: 8, previousEnd: 8) == nil)
        #expect(ProviderSetupLogic.terminalDelta(output: "reset", offset: 5, previousEnd: 100) == .reset("reset"))
        #expect(ProviderSetupLogic.terminalDelta(output: "a😀b", offset: 4, previousEnd: 3) == .write("b"))
        let paste = String(repeating: "😀", count: 4097)
        let chunks = ProviderSetupLogic.terminalResponses(paste).compactMap { $0["data"]?.stringValue }
        #expect(chunks.joined() == paste)
        #expect(chunks.allSatisfy { $0.utf16.count <= 4096 })
    }
    @Test func balancingRejectsStaleSaturatedAndManualHosts() {
        func c(_ id: String, cpu: Double = 0.2, memory: Double = 80, time: Double = 10000, weight: Double = 50) -> ProviderLoadBalanceLogic.Candidate {
            .init(id: id, resources: .object(["cpuUtilization": .number(cpu), "cpuCount": .number(8), "availableMemoryBytes": .number(memory), "totalMemoryBytes": .number(100)]), receivedAt: time, weight: weight)
        }
        #expect(ProviderLoadBalanceLogic.choose([c("first"), c("preferred", weight: 100)], now: 10000) == "preferred")
        #expect(ProviderLoadBalanceLogic.choose([c("first"), c("second")], now: 10000) == "first")
        #expect(ProviderLoadBalanceLogic.choose([c("stale", time: -6000), c("busy", cpu: 0.95), c("low", memory: 5), c("manual", weight: 0)], now: 10000) == nil)
        #expect(ProviderLoadBalanceLogic.choose([c("future", time: 16000)], now: 10000) == nil)
    }
    @Test func versionSkewUsesNightlyDatesButIgnoresStablePrereleases() {
        typealias V = ServerVersionSkewLogic
        #expect(V.serverIsBehind("0.0.45", client: "0.0.46"))
        #expect(!V.serverIsBehind("0.0.47", client: "0.0.46"))
        #expect(!V.serverIsBehind("0.0.46", client: "0.0.46-nightly.20261009.2861"))
        #expect(!V.serverIsBehind("0.0.46-nightly.20261008.10", client: "0.0.46"))
        #expect(V.serverIsBehind("0.0.46-nightly.20261009.9", client: "0.0.46-nightly.20261009.10"))
        #expect(!V.serverIsBehind(nil))
        #expect(!V.serverIsBehind("  "))
        #expect(V.serverIsBehind("development", client: "0.0.46"))
        #expect(V.serverIsBehind("+", client: "0.0.46"))
        #expect(V.manualCommand(target: "1.2.3", installation: .object(["kind": .string("pnpm-dlx")])) == "pnpm dlx t3@1.2.3")
        #expect(V.manualCommand(target: "1.2.3", installation: .object(["kind": .string("npm-global"), "prefix": .string("/path with spaces")])) == "npm install --global --prefix '/path with spaces' t3@1.2.3")
    }
    @MainActor @Test func managedAccountIsSeparateAndDoesNotStartAuth() {
        let input = ProviderCodexAccountDialog.payload(id: "codex_fixture", name: " Work ", instances: ["keep": .object(["driver": .string("pi")])])
        #expect(input["patch"]?["providerInstances"]?["keep"]?["driver"] == .string("pi"))
        #expect(input["patch"]?["providerInstances"]?["codex_fixture"]?["displayName"] == .string("ChatGPT - Work"))
        #expect(input["patch"]?["providerInstances"]?["codex_fixture"]?["config"]?["setupMode"] == .string("managed"))
    }

    @MainActor @Test func signingOutRequiresConfirmationAndTargetsInstance() async {
        let context = SettingsPageContext()
        var confirm: (@MainActor () -> Void)?
        var payloads: [JSONValue] = []
        var methods: [String] = []
        context.confirm = { text, _, action in
            #expect(text.contains("This stops running threads"))
            confirm = action
        }
        context.request = { environment, method, payload in
            #expect(environment == "fixture-env")
            methods.append(method); payloads.append(payload)
            return .object(["phase": .string("idle")])
        }
        var p = ServerProvider(instanceId: ProviderInstanceId(rawValue: "fixture-provider"), driver: "claudeAgent")
        p.auth = .object(["status": .string("authenticated"), "canLogout": .bool(true)])
        let view = ProviderAuthenticationView(context: context, environment: "fixture-env", label: "Fixture", instance: "fixture-provider", provider: p, readOnly: false)
        view.apply(.object(["phase": .string("idle")]))
        func buttons(_ view: NSView) -> [ButtonView] {
            (view as? ButtonView).map { [$0] } ?? view.subviews.flatMap(buttons)
        }
        buttons(view).first { $0.title == "Sign out" }?.performAction()
        #expect(confirm != nil)
        #expect(methods.isEmpty)
        confirm?()
        for _ in 0..<20 where methods.isEmpty { await Task.yield() }
        #expect(methods == ["provider.auth.logout"])
        #expect(payloads == [.object(["instanceId": .string("fixture-provider")])])
    }

}
