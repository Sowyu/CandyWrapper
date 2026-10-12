import AppKit
import DesignSystem
import T3Protocol

/// `AddCodexAccountDialog` with `AddManagedCodexAccountDialog`'s setup (AddCodexAccountDialog.tsx:23-151,
/// CodexSetupSection.tsx:160-195): name the account, which adds a managed Codex instance, then run that
/// instance's ChatGPT setup in the same dialog. It closes itself once the new instance's snapshot says the
/// account is connected (`usesChatGptSharing`), or hands the new instance to `onCreated` and closes.
public final class ProviderCodexAccountDialog: DialogView {
    public var close: (() -> Void)?
    /// `onAccountCreated`: when set the dialog closes after creating the instance (Welcome runs the setup itself).
    public var onAccountCreated: ((String, String) -> Void)?
    /// The instance was added (the providers page selects it).
    public var onCreated: ((String) -> Void)?

    private let context: SettingsPageContext
    private let environment: String
    private let name = InputView(placeholder: "e.g. Personal or Work", text: "Personal", size: .default)
    private let cancel = ButtonView("Cancel", variant: .outline)
    private let add = ButtonView("Continue")
    private var pending = false
    private var instanceId: String?
    private var setup: CodexSetupView?
    private var observer = false
    private var preparing = false
    private var closed = false

    public static func payload(id: String, name: String, instances: [String: JSONValue]) -> JSONValue {
        var instances = instances
        instances[id] = .object(["driver": .string("codex"), "enabled": .bool(true), "displayName": .string(displayName(name)),
                                  "config": .object(["enabled": .bool(true), "setupMode": .string("managed")])])
        return .object(["patch": .object(["providerInstances": .object(instances)])])
    }

    static func displayName(_ name: String) -> String { "ChatGPT - " + name.trimmingCharacters(in: .whitespacesAndNewlines) }

    public init(context: SettingsPageContext, environment: String) {
        self.context = context
        self.environment = environment
        super.init(title: "Add ChatGPT account", message: "Each account has its own Codex instance and sign-in. Choose the other account on the sign-in page.")
        maxWidth = 768 // WizardPopup size="wide": max-w-3xl
        footerVariant = .bare
        isWizardPanel = true
        name.frame.size = NSSize(width: 224, height: 32)
        name.setAccessibilityLabel("Account name")
        name.onChange = { [weak self] _ in self?.sync() }
        name.onSubmit = { [weak self] in self?.create() }
        panelContent = [SettingsRowView(title: "Account name", detail: "Shown in the provider list and model picker.", control: name)]
        cancel.action = { [weak self] in self?.close?() }
        add.action = { [weak self] in self?.create() }
        footerButtons = [cancel, add]
        sync()
    }

    private var canManage: Bool { context.scope.environments.first { $0.id == environment }?.canWrite ?? true }
    private var trimmed: String { name.text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func sync() {
        name.isEnabled = !pending
        cancel.isEnabled = !pending
        add.title = pending ? "Adding account…" : "Continue"
        add.isEnabled = !pending && !trimmed.isEmpty && canManage
    }

    /// `createAccount`: the id is routing identity (`codex_<uuid>`); the name is editable and need not be unique.
    private func create() {
        guard !pending, !trimmed.isEmpty, canManage, let request = context.request else { return }
        pending = true; sync()
        let id = "codex_" + UUID().uuidString.lowercased()
        let display = Self.displayName(trimmed)
        let instances = context.scope.environments.first { $0.id == environment }?.settings?["providerInstances"].objectValue ?? [:]
        let environment = environment
        Task { [weak self] in
            do {
                let value = try await request(environment, "server.updateSettings", Self.payload(id: id, name: self?.trimmed ?? "", instances: instances))
                guard let self else { return }
                self.context.applySettings?(environment, value)
                self.onCreated?(id)
                if let created = self.onAccountCreated {
                    created(id, display)
                    self.close?()
                } else {
                    self.showSetup(id: id, displayName: display)
                }
            } catch {
                self?.context.toast?("Add ChatGPT account", String(describing: error), .error)
            }
            self?.pending = false
            self?.sync()
        }
    }

    private var provider: ServerProvider? {
        guard let instanceId else { return nil }
        return context.configs[environment]?.providers.first { $0.instanceId.rawValue == instanceId }
    }

    /// The created instance's setup: "Codex runtime / Preparing managed setup." until the server reports
    /// `setup`, then the managed setup with `autoStart`, and "Finish later".
    private func showSetup(id: String, displayName: String) {
        instanceId = id
        title = displayName
        let later = ButtonView("Finish later", variant: .outline)
        later.action = { [weak self] in self?.close?() }
        footerButtons = [later]
        if !observer {
            observer = true
            context.observe { [weak self] in self?.refreshSetup() }
        }
        refreshSetup()
    }

    private func refreshSetup() {
        guard let instanceId, !closed, window != nil else { return }
        let provider = provider
        // `open={!connected}`: the destination's snapshot confirms the sign-in.
        if let provider, UsageLimitsLogic.usesChatGptSharing(provider) { closed = true; close?(); return }
        if provider?.setup == nil {
            if setup == nil, !preparing {
                preparing = true
                panelContent = [SettingsRowView(title: "Codex runtime", detail: "Preparing managed setup.")]
                relayout()
            }
            return
        }
        if let setup {
            setup.update(provider: provider, enabled: true, readOnly: !canManage)
            return
        }
        let view = CodexSetupView(context: context, environment: environment, instance: instanceId, provider: provider, enabled: true,
                                  readOnly: !canManage, autoStart: true, allowExistingCli: false)
        view.onSignInCancelled = { [weak self] in self?.close?() }
        view.onHeightChange = { [weak self] in self?.relayout() }
        setup = view
        panelContent = [view]
        relayout()
    }

    private func relayout() {
        panelContent.forEach { $0.invalidateIntrinsicContentSize() }
        needsLayout = true
        superview?.needsLayout = true
    }
}
