import Testing
import Foundation
import AppKit
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// The managed Codex and ChatGPT account flow (CodexSetupSection.tsx, ChatGptAccountPicker.tsx,
/// ChatGptWelcomeCoordinator.tsx) against hand-written server states. No real account is touched.
@MainActor
struct CodexSetupTests {
    static func provider(_ json: String) -> ServerProvider {
        try! JSONDecoder().decode(ServerProvider.self, from: Data(json.utf8))
    }
    static let unauthenticated = provider(#"{"instanceId":"codex_a","driver":"codex","displayName":"ChatGPT - Work","enabled":true,"installed":true,"status":"warning","auth":{"status":"unauthenticated"},"setup":{"canInstall":true,"canAuthenticate":true},"models":[]}"#)
    static let sharing = provider(#"{"instanceId":"codex_a","driver":"codex","displayName":"ChatGPT - Work","enabled":true,"installed":true,"status":"ready","auth":{"status":"authenticated","email":"fixture@example.com","subscriptionSharing":true,"profileId":"p1"},"setup":{"canInstall":true,"canAuthenticate":true},"runtimePaths":{"homePath":"/fixture/.codex","shadowHomePath":null},"models":[]}"#)
    static let installed: JSONValue = .object(["driver": .string("codex"), "operationId": .null, "phase": .string("idle"), "downloadedBytes": .number(0),
                                               "totalBytes": .null, "version": .string("0.9.0"), "installedVersion": .string("0.9.0"),
                                               "source": .string("managed"), "canRemove": .bool(true), "message": .null])
    static func auth(_ phase: String, flow: String? = nil, url: String? = nil, methods: [JSONValue]? = nil, message: String? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["instanceId": .string("codex_a"), "phase": .string(phase), "flowId": flow.map(JSONValue.string) ?? .null,
                                      "authorizationUrl": url.map(JSONValue.string) ?? .null, "expiresAt": .null,
                                      "message": message.map(JSONValue.string) ?? .null]
        if let methods { o["methods"] = .array(methods) }
        return .object(o)
    }
    static let authURL = "https://auth.openai.com/api/accounts/authorize?response_type=code&client_id=oaiapp_fixture&redirect_uri=http%3A%2F%2F127.0.0.1%3A1455%2Fauth%2Fcallback&state=abcdefghijklmnop&code_challenge=" + String(repeating: "a", count: 43) + "&code_challenge_method=S256"
    static let methods: [JSONValue] = [
        .object(["id": .string("chatgpt"), "name": .string("Sign in with ChatGPT"), "accountEmail": .string("saved@example.com"), "type": .string("agent")]),
        .object(["id": .string("chatgpt-change-account"), "name": .string("Use a different ChatGPT account"), "type": .string("agent")]),
        .object(["id": .string("chatgpt-profile:oaiapp_one"), "name": .string("saved@example.com · Mac"), "accountEmail": .string("saved@example.com"), "type": .string("agent")]),
    ]

    @Test func modeReturnAddressAndPrimaryRoute() {
        #expect(CodexSetupLogic.setupMode(.object(["setupMode": .string("managed")])) == "managed")
        #expect(CodexSetupLogic.setupMode(.object([:])) == "existing")
        #expect(CodexSetupLogic.setupMode(nil) == "existing")
        #expect(CodexSetupLogic.returnURL(onboarding: false, environment: "env", instance: "codex_a", scheme: "t3code")
                == "t3code://app/settings/providers?instanceId=codex_a")
        #expect(CodexSetupLogic.returnURL(onboarding: true, environment: "env-1", instance: "codex_a", scheme: "t3code") == "t3code://app/welcome#agents:env-1")
        #expect(CodexSetupLogic.primaryAuthEnvironment(local: false, primary: "p", primaryConnected: true, primaryLocal: true, desktop: true) == "p")
        #expect(CodexSetupLogic.primaryAuthEnvironment(local: true, primary: "p", primaryConnected: true, primaryLocal: true, desktop: true) == nil)
        #expect(CodexSetupLogic.primaryAuthEnvironment(local: false, primary: "p", primaryConnected: false, primaryLocal: true, desktop: true) == nil)
        #expect(CodexSetupLogic.isLoopback(URL(string: "http://127.0.0.1:3773")))
        #expect(!CodexSetupLogic.isLoopback(URL(string: "https://mac.example.ts.net")))
    }

    @Test func accountPickerChoosesFirstProfileOrDifferentAccount() {
        let profiles = CodexSetupLogic.pickerProfiles(Self.methods)
        #expect(profiles.map(\.id) == ["chatgpt-profile:oaiapp_one"])
        #expect(CodexSetupLogic.pickerSelection(nil, profiles: profiles) == "chatgpt-profile:oaiapp_one")
        #expect(CodexSetupLogic.pickerSelection("chatgpt-change-account", profiles: profiles) == "chatgpt-change-account")
        #expect(CodexSetupLogic.pickerSelection(nil, profiles: []) == "chatgpt-change-account")
        #expect(CodexSetupLogic.pickedMethod("chatgpt-profile:gone", methods: Self.methods) == "chatgpt-change-account")
        let dialog = ChatGptAccountPickerDialog(methods: Self.methods)
        #expect(dialog.title == "Reconnect ChatGPT")
        var picked: String?
        dialog.onSelect = { picked = $0 }
        (dialog.footerButtons.first as? ButtonView)?.action?()
        #expect(picked == "chatgpt-profile:oaiapp_one")
    }

    @Test func welcomeKeysMatchTheWebStorage() {
        let profiles = CodexSetupLogic.welcomeProfiles([("env-1", "Studio", true, [Self.sharing, Self.unauthenticated]), ("env-2", "Off", false, [Self.sharing])])
        #expect(profiles.count == 1)
        #expect(profiles[0].key == #"["env-1","codex_a","p1"]"#)
        #expect(profiles[0].providerName == "ChatGPT - Work")
        #expect(CodexSetupLogic.nextWelcome(profiles, acknowledged: [profiles[0].key]) == nil)
        #expect(CodexSetupLogic.readAcknowledged(#"["a",1,"b"]"#) == ["a", "b"])
        #expect(CodexSetupLogic.readAcknowledged("{") == [])
        #expect(CodexSetupLogic.readAcknowledged(CodexSetupLogic.writeAcknowledged(["x/y"])) == ["x/y"])
    }

    @Test func derivedTextFollowsT3() {
        var s = CodexSetupState()
        s.provider = Self.unauthenticated
        s.install = Self.installed
        s.auth = Self.auth("idle")
        #expect(s.accountDescription == .text("Use your ChatGPT subscription."))
        #expect(s.connectionTitle == "Continue with ChatGPT")
        #expect(!s.connectionDisabled)
        s.auth = Self.auth("idle", methods: Self.methods)
        #expect(s.connectionTitle == "Reconnect account")
        #expect(s.accountDescription == .text("saved@example.com"))
        s.requestedMethodId = "chatgpt-profile:oaiapp_one"
        s.auth = Self.auth("waiting", flow: "flow-1", url: Self.authURL, methods: Self.methods)
        #expect(s.accountDescription == .text("Continue as saved@example.com on OpenAI."))
        #expect(s.waitingControl(onboarding: false) == ("Open sign-in page", true))
        #expect(s.showsCallbackCompletion)
        s.auth = Self.auth("idle", message: "Signed out locally. Remote revocation could not be confirmed. Disconnect the app in ChatGPT Settings.")
        #expect(s.logoutWarning?.hasPrefix("Signed out locally.") == true)
        s.install = .object(["phase": .string("downloading"), "downloadedBytes": .number(1_500_000), "totalBytes": .number(10_000_000),
                             "installedVersion": .null, "version": .string("0.9.0")])
        #expect(s.runtimeDescription == "Downloading 1.5 of 10.0 MB.")
        #expect(s.accountDescription == .text("Downloading 1.5 of 10.0 MB."))
        s.install = Self.installed
        s.provider = Self.sharing
        #expect(s.accountDescription == .signedIn("fixture@example.com"))
        s.awaitingProvider = .handoff
        s.provider = Self.unauthenticated
        #expect(s.finishingSignIn)
        #expect(s.accountDescription == .text("Finishing sign-in..."))
    }

    /// A fake environment: requests are recorded and answered from fixtures; streams are held so the test pushes values.
    @MainActor final class Fake {
        var calls: [(env: String, method: String, payload: JSONValue)] = []
        var streams: [String: @MainActor @Sendable (JSONValue) -> Void] = [:]
        var streamPayloads: [String: (env: String, payload: JSONValue)] = [:]
        var received: [String] = []
        let context = SettingsPageContext()
        init(local: Bool = true) {
            context.request = { [unowned self] env, method, payload in
                self.calls.append((env, method, payload))
                switch method {
                case "provider.chatgpt.reconnect-profile": return .object(["clientId": .string("oaiapp_one")])
                default: return CodexSetupTests.auth("starting")
                }
            }
            context.subscribe = { [unowned self] env, method, payload, receive in
                self.streams[method] = receive
                self.streamPayloads[method] = (env, payload)
                return Task {}
            }
            context.httpBaseURL = { env in URL(string: env == "primary" || local ? "http://127.0.0.1:3773" : "https://remote.example.ts.net") }
            context.receiveProviderAuthCallback = { [unowned self] url in
                self.received.append(url)
                return "http://127.0.0.1:1455/auth/callback?code=fixture&state=abcdefghijklmnop"
            }
            context.cancelProviderAuthCallback = { _ in }
            context.openURL = { _ in }
        }
        func push(_ method: String, _ value: JSONValue) { streams[method]?(value) }
    }

    static func settle() async { for _ in 0..<50 { await Task.yield() } }

    static func host(_ view: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
        view.frame = NSRect(x: 0, y: 0, width: 720, height: 200)
        window.contentView?.addSubview(view)
        return window
    }

    static func buttons(_ view: NSView) -> [ButtonView] {
        var out: [ButtonView] = []
        func walk(_ v: NSView) { for s in v.subviews { if let b = s as? ButtonView, !b.isHiddenOrHasHiddenAncestor { out.append(b) }; walk(s) } }
        walk(view)
        return out
    }

    @Test func localSignInCatchesTheCallbackOnThisComputer() async {
        let fake = Fake()
        let view = CodexSetupView(context: fake.context, environment: "env", instance: "codex_a", provider: Self.unauthenticated, enabled: true, readOnly: false)
        let window = Self.host(view)
        #expect(fake.streams["provider.auth.subscribe"] != nil)
        fake.push("provider.install.subscribe", Self.installed)
        fake.push("provider.auth.subscribe", Self.auth("idle"))
        let connect = Self.buttons(view).first { $0.title == "Continue with ChatGPT" }
        #expect(connect?.isEnabled == true)
        connect?.action?()
        await Self.settle()
        let start = fake.calls.first { $0.method == "provider.auth.start" }
        #expect(start?.payload["callbackMode"] == .string("client"))
        #expect(start?.payload["methodId"] == .string("chatgpt"))
        #expect(start?.payload["returnUrl"]?.stringValue?.hasSuffix("://app/settings/providers?instanceId=codex_a") == true)
        fake.push("provider.auth.subscribe", Self.auth("waiting", flow: "flow-1", url: Self.authURL))
        await Self.settle()
        #expect(fake.received == [Self.authURL])
        let complete = fake.calls.first { $0.method == "provider.auth.complete" }
        #expect(complete?.payload["flowId"] == .string("flow-1"))
        #expect(complete?.payload["callbackUrl"]?.stringValue?.contains("code=fixture") == true)
        // The provider snapshot reports the account: Change account, Disconnect and Manage usage.
        view.update(provider: Self.sharing, enabled: true, readOnly: false)
        fake.push("provider.auth.subscribe", Self.auth("succeeded"))
        let titles = Set(Self.buttons(view).compactMap(\.title))
        #expect(titles.isSuperset(of: ["Change account", "Disconnect", "Manage usage"]))
        _ = window
    }

    @Test func remoteEnvironmentSignsInOnThePrimaryAndImportsTheProfile() async {
        let fake = Fake(local: false)
        fake.context.scope = SettingsScopeState(environments: [SettingsScopeEnvironment(id: "primary", label: "This Mac"),
                                                               SettingsScopeEnvironment(id: "remote", label: "Studio")], primaryId: "primary")
        let view = CodexSetupView(context: fake.context, environment: "remote", instance: "codex_a", provider: Self.unauthenticated, enabled: true, readOnly: false)
        let window = Self.host(view)
        fake.push("provider.install.subscribe", Self.installed)
        fake.push("provider.auth.subscribe", Self.auth("idle"))
        Self.buttons(view).first { $0.title == "Continue with ChatGPT" }?.action?()
        await Self.settle()
        #expect(fake.calls.first?.method == "provider.chatgpt.reconnect-profile")
        let handoff = fake.streamPayloads["provider.chatgpt.handoff.subscribe"]
        #expect(handoff?.env == "primary")
        #expect(handoff?.payload["environmentId"] == .string("remote"))
        #expect(handoff?.payload["profile"]?["clientId"] == .string("oaiapp_one"))
        let profile: JSONValue = .object(["registration": .object(["clientId": .string("oaiapp_one")]), "credentials": .object(["accessToken": .string("fixture")])])
        fake.push("provider.chatgpt.handoff.subscribe", .object(["phase": .string("finished"), "profile": profile]))
        await Self.settle()
        let imported = fake.calls.first { $0.method == "provider.chatgpt.import-profile" }
        #expect(imported?.env == "remote")
        #expect(imported?.payload["profile"] == profile)
        #expect(view.state.awaitingProvider == .handoff)
        _ = window
    }

    /// The sharing footer and the welcome dialog drawn offscreen; `CODEX_SNAPSHOT_DIR` keeps the PNGs for a look.
    @Test func sharingFooterAndWelcomeDraw() throws {
        let picker = ModelPickerView(catalog: ProviderCatalog([Self.sharing]), favorites: [], active: Self.sharing.instanceId, activeModel: "")
        let size = picker.naturalSize
        #expect(size.height >= ChatGptSharingControlView.height + ModelPickerView.searchHeight)
        let welcome = ChatGptWelcomeDialog(profile: .init(key: "k", environmentLabel: "Studio", providerName: "ChatGPT - Work")) { _ in }
        welcome.frame.size = NSSize(width: 512, height: welcome.height(forWidth: 512))
        #expect(welcome.footerButtons.compactMap { ($0 as? ButtonView)?.title } == ["Manage usage", "Continue"])
        for dark in [false, true] {
            let a = PickersFidelityTests.render(picker, size: size, backdrop: .gray, dark: dark)
            let b = PickersFidelityTests.render(welcome, size: welcome.frame.size, backdrop: .gray, dark: dark)
            if let dir = ProcessInfo.processInfo.environment["CODEX_SNAPSHOT_DIR"] {
                try a.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/picker-\(dark).png"))
                try b.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/welcome-\(dark).png"))
            }
        }
    }

    @Test func runtimeFieldsAndSharingFooter() {
        let fake = Fake()
        let fields = CodexManagedRuntimeFields(context: fake.context, environment: "env", instance: "codex_a", provider: Self.sharing)
        #expect(fields.rows.map(\.title) == ["Binary path", "CODEX_HOME path", "Shadow home path"])
        #expect(fields.rows[2].detail == "This instance uses the shared Codex home directly.")
        let picker = ModelPickerView(catalog: ProviderCatalog([Self.sharing]), favorites: [], active: Self.sharing.instanceId, activeModel: "")
        #expect(picker.showsSharing)
        picker.selectedKeys = ["codex_a:gpt"]
        #expect(!picker.showsSharing)
        let plain = ModelPickerView(catalog: ProviderCatalog([Self.unauthenticated]), favorites: [], active: Self.unauthenticated.instanceId, activeModel: "")
        #expect(!plain.showsSharing)
    }
}
