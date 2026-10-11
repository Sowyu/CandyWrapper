import AppKit
import DesignSystem
import T3Protocol

/// AddCodexAccountDialog.tsx:40-85. Creating the isolated account does not start sign-in or install a CLI.
public final class ProviderCodexAccountDialog: DialogView {
    public var close: (() -> Void)?
    public var onCreated: ((String) -> Void)?
    public static func payload(id: String, name: String, instances: [String: JSONValue]) -> JSONValue {
        var instances = instances
        instances[id] = .object(["driver": .string("codex"), "enabled": .bool(true), "displayName": .string("ChatGPT - " + name.trimmingCharacters(in: .whitespacesAndNewlines)),
                                  "config": .object(["enabled": .bool(true), "setupMode": .string("managed")])])
        return .object(["patch": .object(["providerInstances": .object(instances)])])
    }
    public init(context: SettingsPageContext, environment: String) {
        super.init(title: "Add ChatGPT account", message: "Each account has its own Codex instance and sign-in. Choose the other account on the sign-in page.")
        maxWidth = 640; footerVariant = .bare
        let name = InputView(text: "Personal", size: .sm); name.frame.size = NSSize(width: 224, height: 32)
        name.setAccessibilityLabel("Account name")
        panelContent = [SettingsRowView(title: "Account name", detail: "Shown in the provider list and model picker.", control: name)]
        let cancel = ButtonView("Cancel", variant: .outline, size: .sm)
        cancel.action = { [weak self] in self?.close?() }
        let add = ButtonView("Continue", size: .sm)
        name.onChange = { [weak add] in add?.isEnabled = !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        add.action = { [weak self, weak add, weak name] in
            guard let self, let request = context.request, let name = name?.text, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            add?.isEnabled = false
            let id = "codex_" + UUID().uuidString.lowercased()
            let instances = context.scope.environments.first { $0.id == environment }?.settings?["providerInstances"].objectValue ?? [:]
            Task { [weak self] in
                do {
                    let value = try await request(environment, "server.updateSettings", Self.payload(id: id, name: name, instances: instances))
                    context.applySettings?(environment, value); self?.onCreated?(id); self?.close?()
                } catch { context.toast?("Could not add ChatGPT account", String(describing: error), .error); add?.isEnabled = true }
            }
        }
        footerButtons = [cancel, add]
    }
}

/// CodexSetupSection.tsx:280-315, 905-935. Installation is a separate, explicit action.
public final class ProviderCodexRuntimeView: DSView, SettingsGroupRow {
    private let context: SettingsPageContext
    private let environment: String, instance: String
    private let readOnly: Bool
    private var state: JSONValue = .null
    private var subscription: Task<Void, Never>?
    private var pending = false
    private var row = SettingsRowView(title: "Codex runtime", detail: "Preparing managed setup.")
    public var onHeightChange: (() -> Void)?
    public init(context: SettingsPageContext, environment: String, instance: String, readOnly: Bool) {
        self.context = context; self.environment = environment; self.instance = instance; self.readOnly = readOnly
        super.init(frame: .zero); addSubview(row)
    }
    deinit { subscription?.cancel() }
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { subscription?.cancel(); subscription = nil }
        else if subscription == nil {
            subscription = context.subscribe?(environment, "provider.install.subscribe", .object(["instanceId": .string(instance)])) { [weak self] state in self?.state = state; self?.rebuild() }
        }
    }
    private func rebuild() {
        let phase = state["phase"]?.stringValue ?? "idle"
        let active = ["downloading", "extracting", "verifying"].contains(phase)
        let installed = state["installedVersion"]?.stringValue
        let action = ButtonView(active ? "Cancel" : installed == nil ? "Install Codex" : "Update", variant: .outline, size: .sm)
        action.isEnabled = !readOnly && !pending && (active || installed == nil || state["version"]?.stringValue != installed)
        action.action = { [weak self] in
            guard let self, let request = self.context.request else { return }
            var input: [String: JSONValue] = ["instanceId": .string(self.instance)]
            if active { guard let operation = self.state["operationId"]?.stringValue else { return }; input["operationId"] = .string(operation) }
            self.pending = true; self.rebuild()
            Task { [weak self] in
                do { let next = try await request(self?.environment ?? "", active ? "provider.install.cancel" : "provider.install.start", .object(input)); self?.state = next }
                catch { self?.context.toast?("Codex setup failed", String(describing: error), .error) }
                self?.pending = false; self?.rebuild()
            }
        }
        row.removeFromSuperview()
        row = SettingsRowView(title: "Codex runtime", detail: active ? state["message"]?.stringValue : installed.map { "Codex v\($0)" } ?? "Managed by T3 Code.", control: action)
        row.status = phase == "failed" ? state["message"]?.stringValue : nil
        addSubview(row); needsLayout = true; onHeightChange?()
    }
    public func height(forWidth width: CGFloat) -> CGFloat { row.height(forWidth: width) }
    public override func layout() { super.layout(); row.frame = bounds }
}
