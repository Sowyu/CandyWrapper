import AppKit
import DesignSystem
import T3Protocol

/// ProviderAuthenticationSection.tsx:42-190. The visible row owns the auth stream and terminal.
public final class ProviderAuthenticationView: DSView, SettingsGroupRow {
    private let context: SettingsPageContext
    private let environment: String, instance: String, environmentLabel: String
    private let readOnly: Bool
    private let provider: ServerProvider?
    private var subscription: Task<Void, Never>?
    private var sender: Task<Void, Never>?
    private var queue: [JSONValue] = []
    private var state: JSONValue = .object([:])
    private var controls: [NSView] = []
    private var terminal: TerminalSurfaceView?
    private var terminalIdentity: String?
    private var previousEnd: Int?
    private var pending = false
    private var error: String?
    private var method = ""
    private var credentialIdentity: String?
    private var credentialDraft: [String: String] = [:]
    private var callbackDraft = ""
    public var onHeightChange: (() -> Void)?

    public init(context: SettingsPageContext, environment: String, label: String, instance: String, provider: ServerProvider?, readOnly: Bool) {
        self.context = context; self.environment = environment; environmentLabel = label
        self.instance = instance; self.provider = provider; self.readOnly = readOnly
        super.init(frame: .zero)
        rebuild()
    }
    deinit { subscription?.cancel(); sender?.cancel() }
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            subscription?.cancel(); subscription = nil; sender?.cancel(); sender = nil; queue = []
            terminal?.removeFromSuperview(); terminal = nil; terminalIdentity = nil; previousEnd = nil
            credentialDraft = [:]; callbackDraft = ""
        } else if subscription == nil {
            subscription = context.subscribe?(environment, "provider.auth.subscribe", .object(["instanceId": .string(instance)])) { [weak self] value in
                self?.apply(value)
            }
        }
    }
    public func apply(_ value: JSONValue) { state = value; rebuild() }
    private func run(_ method: String, _ payload: JSONValue, then: (() -> Void)? = nil) {
        guard !readOnly, !pending, let request = context.request else { return }
        pending = true; error = nil; rebuild()
        Task { [weak self] in
            do {
                let value = try await request(self?.environment ?? "", method, payload)
                guard let self else { return }; self.state = value; then?()
            } catch { self?.error = String(describing: error) }
            self?.pending = false; self?.rebuild()
        }
    }
    private func enqueue(_ response: JSONValue) {
        guard !readOnly, let payload = ProviderSetupLogic.response(instance: instance, state: state, response: response), let request = context.request else { return }
        queue.append(payload)
        guard sender == nil else { return }
        let environment = environment
        sender = Task { [weak self] in
            while !Task.isCancelled, let self, !self.queue.isEmpty {
                let next = self.queue.removeFirst()
                do { _ = try await request(environment, "provider.auth.respond", next) }
                catch { self.error = String(describing: error); self.queue = []; self.rebuild() }
            }
            self?.sender = nil
        }
    }
    private func button(_ title: String, action: @escaping @MainActor @Sendable () -> Void) -> ButtonView {
        let b = ButtonView(title, variant: .outline, size: .sm)
        b.isEnabled = !readOnly && !pending; b.action = action; return b
    }
    private func rebuild() {
        controls.forEach { $0.removeFromSuperview() }; controls = []
        let phase = state["phase"]?.stringValue ?? "idle"
        let active = ["starting", "waiting", "verifying"].contains(phase)
        let interaction = state["interaction"] ?? .null
        let type = interaction["type"]?.stringValue
        let identity = (state["flowId"]?.stringValue ?? "") + ":" + (interaction["id"]?.stringValue ?? "")
        if credentialIdentity != identity { credentialIdentity = identity; credentialDraft = [:]; callbackDraft = "" }
        let signedIn = provider?.auth?["status"]?.stringValue == "authenticated" || (provider?.auth?["status"]?.stringValue == "unknown" && phase == "succeeded")
        let unavailable = provider?.setup?["canAuthenticate"]?.boolValue == false
        let description = active ? (phase == "starting" ? "Starting sign-in…" : phase == "verifying" ? "Checking your account…" : type == "terminal" ? "Complete sign-in in the terminal below." : type == "credentials" ? "Enter your credentials below." : "Finish signing in in your browser.")
            : signedIn ? "Signed in." : unavailable ? "No in-app sign-in advertised. Follow the provider's docs to finish setup." : "Sign in on \(environmentLabel)."
        var actions: [NSView] = []
        let base: [String: JSONValue] = ["instanceId": .string(instance)]
        if !active {
            let methods = state["methods"]?.arrayValue ?? []
            if methods.count > 1 {
                let ids = [""] + methods.compactMap { $0["id"]?.stringValue }
                let select = SelectView(options: ["Provider default"] + methods.compactMap { $0["name"]?.stringValue }, selected: ids.firstIndex(of: method), size: .sm)
                select.onChange = { [weak self] in self?.method = ids[$0] }; actions.append(select)
            }
            if !unavailable {
                let b = button(signedIn ? "Change account" : ["failed", "cancelled"].contains(phase) ? "Retry sign-in" : "Sign in") { [weak self] in
                    guard let self else { return }
                    var input = base
                    if !self.method.isEmpty { input["methodId"] = .string(self.method) }
                    self.run("provider.auth.start", .object(input))
                }
                b.isEnabled = b.isEnabled && provider?.enabled != false && provider?.installed != false && state["phase"] != nil
                actions.append(b)
            }
            if signedIn && (provider?.auth?["canLogout"]?.boolValue ?? provider?.setup?["canAuthenticate"]?.boolValue ?? false) {
                let signOut = button("Sign out") { [weak self] in
                    guard let self else { return }
                    self.context.confirm?("Sign out of \(self.provider?.displayName ?? self.provider?.driver ?? self.instance) on \(self.environmentLabel)? This stops running threads that share this sign-in. Thread history is kept.", false, { [weak self] in self?.run("provider.auth.logout", .object(base)) })
                }
                signOut.variant = .ghost
                signOut.isEnabled = signOut.isEnabled && state["phase"] != nil
                actions.append(signOut)
            }

        } else if let flow = state["flowId"]?.stringValue {
            actions.append(button("Cancel") { [weak self] in self?.run("provider.auth.cancel", .object(["instanceId": .string(self?.instance ?? ""), "flowId": .string(flow)])) })
        }
        let row = SettingsRowView(title: "Account", detail: description, control: SettingsControlGroup(actions, gap: 6))
        row.status = error ?? (phase == "failed" ? state["message"]?.stringValue : nil)
        controls.append(row)
        if active, let url = interaction["url"]?.stringValue ?? state["authorizationUrl"]?.stringValue {
            let open = button("Open browser") { [weak self] in
                guard let self, let parsed = URL(string: url), ["https", "http"].contains(parsed.scheme) else { return }
                if interaction["requiresConsent"]?.boolValue == true,
                   let response = ProviderSetupLogic.response(instance: self.instance, state: self.state, response: .object(["type": .string("browser"), "action": .string("accept")])) {
                    self.run("provider.auth.respond", response) { self.context.openURL?(parsed) }
                } else { self.context.openURL?(parsed) }
            }
            let copy = button("Copy sign-in link") { [weak self] in self?.context.copy?(url, "Sign-in link copied") }
            controls.append(SettingsRowView(title: interaction["userCode"]?.stringValue ?? "Sign-in link", control: SettingsControlGroup([open, copy])))
            if type == "browser" && interaction["acceptsCallback"]?.boolValue == true, let flow = state["flowId"]?.stringValue {
                let callback = InputView(placeholder: "Paste redirect URL", text: callbackDraft, size: .sm)
                callback.onChange = { [weak self] in self?.callbackDraft = $0 }
                callback.frame.size = NSSize(width: 224, height: 32)
                let submit = button("Continue") { [weak self, weak callback] in
                    guard let self, let text = callback?.text, !text.isEmpty else { return }
                    self.run("provider.auth.complete", .object(["instanceId": .string(self.instance), "flowId": .string(flow), "callbackUrl": .string(text)]))
                }
                controls.append(SettingsRowView(title: "Redirect URL", control: SettingsControlGroup([callback, submit])))
            }
        }
        if active, type == "credentials" {
            var fields: [(String, () -> String)] = []
            for field in interaction["fields"]?.arrayValue ?? [] {
                guard let name = field["name"]?.stringValue else { continue }
                let title = field["label"]?.stringValue ?? name
                let view: NSView
                if field["secret"]?.boolValue == true {
                    let input = SecureInputView(); input.text = credentialDraft[name] ?? ""; input.isEnabled = !readOnly && !pending
                    input.onChange = { [weak self] in self?.credentialDraft[name] = $0 }; view = input; fields.append((name, { [weak input] in input?.text ?? "" }))
                } else {
                    let input = InputView(text: credentialDraft[name] ?? "", size: .sm); input.isEnabled = !readOnly && !pending
                    input.onChange = { [weak self] in self?.credentialDraft[name] = $0 }; view = input; fields.append((name, { [weak input] in input?.text ?? "" }))
                }
                view.setAccessibilityLabel(title); view.frame.size = NSSize(width: 224, height: 32)
                controls.append(SettingsRowView(title: title, control: view))
            }
            let submit = button("Continue") { [weak self] in
                guard let self, let payload = ProviderSetupLogic.response(instance: self.instance, state: self.state, response: .object([
                    "type": .string("credentials"), "values": .object(Dictionary(uniqueKeysWithValues: fields.map { ($0.0, .string($0.1())) }))])) else { return }
                self.run("provider.auth.respond", payload)
            }
            controls.append(SettingsRowView(title: "", control: submit))
        }
        if active, type == "terminal" {
            let identity = (state["flowId"]?.stringValue ?? "") + ":" + (interaction["id"]?.stringValue ?? "")
            if terminalIdentity != identity || terminal == nil {
                terminal?.removeFromSuperview(); terminal = TerminalSurfaceView(frame: .zero); previousEnd = nil; terminalIdentity = identity
                terminal?.setFontSize(13)
                terminal?.setAccessibilityLabel("Provider sign-in terminal")
                terminal?.onLink = { [weak self] text in
                    guard let url = URL(string: text), ["http", "https"].contains(url.scheme) else { return }; self?.context.openURL?(url)
                }
                terminal?.onInput = { [weak self] data in ProviderSetupLogic.terminalResponses(data).forEach { self?.enqueue($0) } }
                terminal?.onResize = { [weak self] cols, rows in self?.enqueue(.object(["type": .string("terminal"), "data": .string(""), "size": .object(["cols": .number(Double(min(500, max(1, cols)))), "rows": .number(Double(min(200, max(1, rows))))])])) }
                if let terminal { addSubview(terminal) }
            }
            let output = interaction["output"]?.stringValue ?? "", offset = interaction["outputOffset"]?.intValue ?? output.utf16.count
            if let delta = ProviderSetupLogic.terminalDelta(output: output, offset: offset, previousEnd: previousEnd) { terminal?.apply(delta) }
            previousEnd = offset
        } else { terminal?.removeFromSuperview(); terminal = nil; previousEnd = nil; terminalIdentity = nil }
        controls.forEach(addSubview); needsLayout = true; onHeightChange?()
    }
    public override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: max(1, bounds.width))) }
    public func height(forWidth width: CGFloat) -> CGFloat {
        controls.reduce(0) { $0 + (($1 as? SettingsGroupRow)?.height(forWidth: width) ?? 32) } + (terminal == nil ? 0 : 256)
    }
    public override func layout() {
        super.layout(); var y: CGFloat = 0
        for view in controls {
            let h = (view as? SettingsGroupRow)?.height(forWidth: bounds.width) ?? 32
            view.frame = NSRect(x: 0, y: y, width: bounds.width, height: h); y += h
        }
        terminal?.frame = NSRect(x: 0, y: y, width: bounds.width, height: 256)
    }
}
