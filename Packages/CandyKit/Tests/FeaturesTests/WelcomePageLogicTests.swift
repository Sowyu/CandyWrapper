import Foundation
import Testing
import T3Protocol
@testable import Features

/// welcomePage.logic.test.ts and providerReadiness.logic.ts at Nightly 4928.
@MainActor
struct WelcomePageLogicTests {
    static func provider(_ id: String, driver: String? = nil, installed: Bool = true, status: ServerProviderStatus = .ready,
                         auth: String = "authenticated", enabled: Bool = true) -> ServerProvider {
        var p = ServerProvider(instanceId: ProviderInstanceId(id), driver: driver ?? id, enabled: enabled, installed: installed, status: status)
        p.auth = .object(["status": .string(auth)])
        return p
    }

    @Test func statesAndGroups() {
        let settings: JSONValue = .object(["providerInstances": .object(["cursor": .object(["driver": .string("cursor"), "enabled": .bool(true)])])])
        let claude = Self.provider("claudeAgent")
        let codex = Self.provider("codex", auth: "unauthenticated")
        let cursor = Self.provider("cursor", status: .warning)
        let grok = Self.provider("grok")
        var broken = Self.provider("pi")
        broken.compatibilityAdvisory = .object(["status": .string("broken"), "message": .string("Too old")])
        #expect(WelcomePageLogic.state(claude, settings: settings) == .ready)
        #expect(WelcomePageLogic.state(codex, settings: settings) == .signIn)
        #expect(WelcomePageLogic.state(cursor, settings: settings) == .attention)
        // Not configured and not a default instance: off for new threads.
        #expect(WelcomePageLogic.state(grok, settings: settings) == .disabled)
        var unavailable = claude
        unavailable.availability = "unavailable"
        #expect(WelcomePageLogic.state(unavailable, settings: settings) == .attention)
        let groups = WelcomePageLogic.group([grok, cursor, codex, claude], settings: settings)
        #expect(groups.found.map(\.instanceId.rawValue) == ["claudeAgent", "codex", "cursor"])
        #expect(groups.available.map(\.instanceId.rawValue) == ["grok"])
        #expect(groups.readyCount == 1)
        #expect(!groups.checking)
        #expect(WelcomePageLogic.group(nil, settings: nil).checking)
        #expect(WelcomePageLogic.brokenVersion(broken))
        #expect(WelcomePageLogic.detail(broken, state: .attention, compact: false, headline: nil) == "Too old")
    }

    @Test func codexAndTerminalSteps() {
        let signIn = Self.provider("codex", auth: "unauthenticated")
        #expect(WelcomePageLogic.codexNeedsSetup(signIn, settings: nil))
        #expect(!WelcomePageLogic.codexNeedsSetup(Self.provider("codex"), settings: nil))
        #expect(WelcomePageLogic.cliTerminalStep(signIn, settings: nil) == .open)
        #expect(WelcomePageLogic.cliTerminalStep(Self.provider("codex"), settings: nil) == .done)
        var chatgpt = signIn
        chatgpt.setup = .object(["canAuthenticate": .bool(true)])
        #expect(WelcomePageLogic.cliTerminalStep(chatgpt, settings: nil) == .wait)
        #expect(WelcomePageLogic.needsTerminal(Self.provider("claudeAgent", installed: false), settings: nil))
        #expect(!WelcomePageLogic.needsTerminal(Self.provider("cursor", installed: false), settings: nil))
    }

    @Test func commands() {
        #expect(WelcomePageLogic.installCommand(driver: "claudeAgent", platform: "darwin") == "curl -fsSL https://claude.ai/install.sh | bash")
        #expect(WelcomePageLogic.installCommand(driver: "codex", platform: "windows") == "irm https://chatgpt.com/codex/install.ps1 | iex")
        let claude = Self.provider("claudeAgent")
        #expect(WelcomePageLogic.loginCommand(claude, settings: nil, platform: "darwin") == "claude auth login")
        let custom: JSONValue = .object(["providerInstances": .object(["claudeAgent": .object(["config": .object(["binaryPath": .string("~/My Tools/claude")])])])])
        #expect(WelcomePageLogic.loginCommand(claude, settings: custom, platform: "darwin") == "~/'My Tools/claude' auth login")
        let quote: JSONValue = .object(["providerInstances": .object(["codex": .object(["config": .object(["binaryPath": .string("/opt/it's/codex")])])])])
        #expect(WelcomePageLogic.loginCommand(Self.provider("codex"), settings: quote, platform: "linux") == "'/opt/it'\"'\"'s/codex' login")
        #expect(WelcomePageLogic.turnedOn(.object(["driver": .string("pi"), "config": .object(["enabled": .bool(false)])]))
                == .object(["driver": .string("pi"), "enabled": .bool(true), "config": .object(["enabled": .bool(true)])]))
    }

    @Test func namesAndSelection() {
        #expect(WelcomePageLogic.name(Self.provider("fx")) == "fx")
        #expect(WelcomePageLogic.name(Self.provider("codex_work", driver: "codex")) == "Codex Work")
        #expect(WelcomePageLogic.humanize("myCodex-2") == "My Codex 2")
        let a = OnboardingProjectCandidate(environmentId: "e", path: "/a", title: "a")
        let b = OnboardingProjectCandidate(environmentId: "e", path: "/b/", title: "b")
        #expect(WelcomePageLogic.isNew(a, roots: ["/b"]))
        #expect(!WelcomePageLogic.isNew(b, roots: ["/b"]))
        // Projects listed when the choice was made keep it; new ones get the recent default.
        let stored = WelcomePageLogic.Selection(knownKeys: [a.key], keys: [], optedOut: false)
        #expect(WelcomePageLogic.selected([a, b], selection: stored, recent: [a.key, b.key]).map(\.path) == ["/b/"])
        #expect(WelcomePageLogic.selected([a, b], selection: .init(knownKeys: [], keys: [], optedOut: true), recent: [a.key]).isEmpty)
        #expect(WelcomePageLogic.defaultKeys([a, b], recent: [], isNew: { $0.path == "/a" }) == [a.key])
        #expect(WelcomePageLogic.startTitle(importing: false, selected: 2, new: 1) == "Import 1 project and start")
        #expect(WelcomePageLogic.startTitle(importing: false, selected: 2, new: 0) == "Import threads and start")
        #expect(WelcomePageLogic.startTitle(importing: true, selected: 0, new: 0) == "Starting…")
    }

    @Test func modelKeepsChoices() {
        let defaults = UserDefaults(suiteName: "WelcomePageLogicTests")!
        defaults.removePersistentDomain(forName: "WelcomePageLogicTests")
        let model = WelcomePageModel(environmentId: "e", label: "Mac", defaults: defaults)
        let a = OnboardingProjectCandidate(environmentId: "e", path: "/a", title: "a")
        model.scan = .init(pending: false, candidates: [a])
        model.setSelectedKeys([a.key])
        #expect(WelcomePageModel(environmentId: "e", label: "Mac", defaults: defaults).selection?.keys == [a.key])
    }
}
