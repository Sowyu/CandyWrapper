import AppKit
import DesignSystem
import T3Protocol

/// AddProviderInstanceDialog.tsx:375-680. Drafts survive backward navigation and driver changes.
public final class ProviderAddWizardView: DialogView {
    private let context: SettingsPageContext
    private let environment: String, environmentLabel: String
    private let existing: Set<String>
    private var driver = "codex", step = 0
    private var labels: [String: String] = [:], ids: [String: String] = [:]
    private var configs: [String: [String: JSONValue]] = [:]
    private var accent: [String: String] = [:]
    private var saving = false
    private var error: String?
    private var agents: [JSONValue] = []
    private var searchTask: Task<Void, Never>?
    private var searchGeneration = 0
    public var onCreated: ((String) -> Void)?
    public var close: (() -> Void)?
    /// "Continue with ChatGPT" on the Codex choice: the presenter swaps this wizard for the account dialog.
    public var onAddChatGptAccount: (() -> Void)?
    private var label: String { labels[driver] ?? ProvidersLogic.label(driver) ?? driver }
    private var id: String { ids[driver] ?? ProviderSetupLogic.instanceID(driver: driver, label: label, existing: existing) }

    public init(context: SettingsPageContext, environment: String, label: String, existing: Set<String>) {
        self.context = context; self.environment = environment; environmentLabel = label
        self.existing = existing.union(["codex", "claudeAgent"])
        super.init(title: "Add provider", message: "Add an account or configure a provider on \(label).")
        maxWidth = 640; footerVariant = .bare; rebuild()
    }
    deinit { searchTask?.cancel() }
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { searchTask?.cancel(); searchGeneration += 1 }
    }
    private func row(_ title: String, _ detail: String? = nil, input: NSView) -> SettingsRowView {
        input.frame.size = NSSize(width: 256, height: 32)
        return SettingsRowView(title: title, detail: detail, control: input)
    }
    private func rebuild() {
        let steps = WizardStepsView(steps: ["Provider", "Identity", "Config"], currentStep: step)
        steps.onStepChange = { [weak self] requested in
            guard let self, !self.saving else { return }
            if requested > 1, let error = ProviderSetupLogic.validation(self.id, existing: self.existing) {
                self.step = 1; self.error = error
            } else { self.step = min(requested, 2); self.error = nil }
            self.rebuild()
        }
        steps.frame.size.height = 52
        var body: [NSView] = [steps]
        if step == 0 {
            let choices = ProvidersLogic.drivers.filter { $0.0 != "acpRegistry" }
            let grid = ProviderAddDriverGrid(choices: choices.map { ($0.0, $0.1) }, selected: driver)
            grid.onSelect = { [weak self] driver in self?.driver = driver; self?.error = nil; self?.rebuild() }
            body.append(grid)
            let search = InputView(placeholder: "Search ACP Registry", size: .sm)
            search.frame.size = NSSize(width: 180, height: 32)
            let button = ButtonView("Search registry", variant: .outline, size: .sm)
            button.action = { [weak self, weak search] in self?.search(search?.text ?? "") }
            body.append(row("Or choose from ACP Registry", input: SettingsControlGroup([search, button])))
            for agent in agents.prefix(6) {
                guard let agentID = agent["id"]?.stringValue else { continue }
                let pick = ButtonView("Add", variant: .outline, size: .sm)
                pick.isEnabled = !saving
                pick.action = { [weak self] in self?.prepare(agent) }
                body.append(row(agent["name"]?.stringValue ?? agentID, agent["description"]?.stringValue, input: pick))
            }
            let manual = ButtonView("Enter manually", variant: .ghost, size: .sm)
            manual.action = { [weak self] in self?.driver = "acpRegistry"; self?.step = 1; self?.rebuild() }
            body.append(manual)
        } else if step == 1 {
            let name = InputView(text: label, size: .sm)
            let instanceID = InputView(text: id, size: .sm, font: .mono)
            name.onChange = { [weak self, weak instanceID] text in
                guard let self else { return }; self.labels[self.driver] = text
                if self.ids[self.driver] == nil { instanceID?.text = self.id }
            }
            instanceID.onChange = { [weak self] text in guard let self else { return }; self.ids[self.driver] = text }
            body.append(row("Label", "Shown in the provider list.", input: name))
            body.append(row("Instance ID", "Unique identifier for this provider instance.", input: instanceID))
            let color = InputView(placeholder: "#2563eb", text: accent[driver] ?? "", size: .sm)
            color.onChange = { [weak self] text in guard let self else { return }; self.accent[self.driver] = text }
            body.append(row("Accent color", input: color))
        } else {
            for field in ProvidersLogic.fields(driver, config: .object(configs[driver] ?? [:])) {
                let value = configs[driver]?[field.key]?.stringValue ?? field.defaultValue
                if !field.options.isEmpty {
                    let input = SelectView(options: field.options.map { $0.1 }, selected: field.options.firstIndex { $0.0 == value }, size: .sm)
                    input.onChange = { [weak self] index in
                        guard let self else { return }
                        self.configs[self.driver, default: [:]][field.key] = .string(field.options[index].0)
                        self.rebuild()
                    }
                    body.append(row(field.title, field.detail, input: input))
                } else if field.secret {
                    let input = SecureInputView(placeholder: field.placeholder)
                    input.text = value
                    input.onChange = { [weak self] text in
                        guard let self else { return }
                        self.configs[self.driver, default: [:]][field.key] = .string(text)
                    }
                    body.append(row(field.title, field.detail, input: input))
                } else {
                    let input = InputView(placeholder: field.placeholder, text: value, size: .sm)
                    input.onChange = { [weak self] text in
                        guard let self else { return }; let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        self.configs[self.driver, default: [:]][field.key] = value.isEmpty ? nil : .string(value)
                    }
                    body.append(row(field.title, field.detail, input: input))
                }
            }
            if driver == "acpRegistry", configs[driver]?["source"]?.stringValue == "local" {
                let args = SettingsProviderArgumentsView((configs[driver]?["commandArgs"]?.arrayValue ?? []).compactMap(\.stringValue)) { [weak self] values in
                    self?.configs["acpRegistry", default: [:]]["commandArgs"] = .array(values.map(JSONValue.string))
                }
                args.onHeightChange = { [weak self] in self?.needsLayout = true }
                body.append(args)
            }
            if body.count == 1 { body.append(SettingsNoticeView("This provider has no additional configuration.")) }
        }
        if let error { body.append(SettingsNoticeView(error)) }
        panelContent = body
        let cancel = ButtonView("Cancel", variant: .outline, size: .sm)
        cancel.action = { [weak self] in self?.close?() }; cancel.isEnabled = !saving
        let back = ButtonView("Back", variant: .outline, size: .sm)
        back.action = { [weak self] in guard let self else { return }; self.step = max(0, self.step - 1); self.error = nil; self.rebuild() }
        back.isEnabled = !saving
        let finish = step == 2
        let next = ButtonView(saving ? "Adding…" : finish ? "Add provider" : "Next", size: .sm)
        next.isEnabled = !saving
        next.action = { [weak self] in
            guard let self else { return }
            if self.step >= 1, let error = ProviderSetupLogic.validation(self.id, existing: self.existing) {
                self.error = error; self.rebuild(); return
            }
            if finish { self.save() } else { self.step += 1; self.error = nil; self.rebuild() }
        }
        if step == 0 && driver == "codex" {
            // AddProviderInstanceDialog.tsx:663-686: Cancel is `ghost-muted` on the first step; Codex offers
            // "Configure manually" (the next step) and Continue with ChatGPT (the managed account dialog).
            cancel.variant = .ghostMuted
            let manual = ButtonView("Configure manually", variant: .outline, size: .sm)
            manual.action = { [weak self] in guard let self else { return }; self.step = 1; self.error = nil; self.rebuild() }
            let chatGpt = ChatGptButtons.connection(size: .sm)
            chatGpt.action = { [weak self] in self?.onAddChatGptAccount?() }
            footerButtons = [cancel, manual, chatGpt]
        } else {
            footerButtons = step == 0 ? [cancel, next] : [cancel, back, next]
        }
    }
    private func search(_ query: String) {
        guard let request = context.request else { return }
        searchTask?.cancel(); searchGeneration += 1; let generation = searchGeneration, environment = environment
        searchTask = Task { [weak self] in
            do {
                // An empty search lists every compatible agent (AcpRegistrySearchStep.tsx:72-78, #19145).
                let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
                let input: JSONValue = trimmed.isEmpty ? .object(["query": .string(""), "limit": .number(512)]) : .object(["query": .string(trimmed)])
                let result = try await request(environment, "server.searchAcpRegistry", input)
                guard let self, !Task.isCancelled, generation == self.searchGeneration else { return }
                self.agents = result["agents"]?.arrayValue ?? []; self.error = self.agents.isEmpty ? "No ACPs found. Try a broader search." : nil; self.rebuild()
            } catch { guard !Task.isCancelled else { return }; self?.error = String(describing: error); self?.rebuild() }
        }
    }
    private func prepare(_ agent: JSONValue) {
        guard let request = context.request, let agentID = agent["id"]?.stringValue else { return }
        saving = true; rebuild(); let environment = environment
        Task { [weak self] in
            do {
                _ = try await request(environment, "server.prepareAcpRegistryAgent", .object(["agentId": .string(agentID)]))
                guard let self else { return }; self.driver = "acpRegistry"; self.labels[self.driver] = agent["name"]?.stringValue ?? agentID
                self.configs[self.driver] = ["agentId": .string(agentID), "distribution": .string("auto")]; self.step = 1
            } catch { self?.error = String(describing: error) }
            self?.saving = false; self?.rebuild()
        }
    }
    private func save() {
        guard let request = context.request else { return }
        if driver == "acpRegistry" {
            let local = configs[driver]?["source"]?.stringValue == "local"
            let key = local ? "commandPath" : "agentId"
            if (configs[driver]?[key]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                error = local ? "Enter a local ACP executable." : "Select an ACP or configure one manually."; rebuild(); return
            }
        }
        let id = id, driver = driver, environment = environment
        let payload = ProviderSetupLogic.create(id: id, driver: driver, label: label, config: configs[driver] ?? [:], accent: accent[driver])
        saving = true; rebuild()
        Task { [weak self] in
            do {
                let result = try await request(environment, "server.updateSettings", payload)
                guard let self else { return }; self.context.applySettings?(environment, result); self.onCreated?(id)
                if driver == "acpRegistry" {
                    let auth = ProviderAuthenticationView(context: self.context, environment: environment, label: self.environmentLabel, instance: id, provider: nil, readOnly: false)
                    auth.frame.size.height = 180
                    auth.onHeightChange = { [weak self, weak auth] in guard let self, let auth else { return }; auth.frame.size.height = auth.height(forWidth: 592); self.needsLayout = true }
                    self.panelContent = [auth]
                    let done = ButtonView("Skip for now", variant: .outline, size: .sm); done.action = { [weak self] in self?.close?() }; self.footerButtons = [done]
                } else { self.close?() }
            } catch { self?.saving = false; self?.error = String(describing: error); self?.rebuild() }
        }
    }
}

public final class ProviderAddDriverGrid: DSView {
    public var onSelect: ((String) -> Void)?
    private var buttons: [ProviderAddDriverChoice] = []
    public init(choices: [(String, String)], selected: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 592, height: CGFloat((choices.count + 1) / 2) * 56))
        for (id, title) in choices {
            let b = ProviderAddDriverChoice(driver: id, title: title, selected: id == selected)
            b.action = { [weak self] in self?.onSelect?(id) }; buttons.append(b); addSubview(b)
        }
    }
    public override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: CGFloat((buttons.count + 1) / 2) * 56) }
    public override func layout() {
        super.layout(); let width = (bounds.width - 8) / 2
        for (i, b) in buttons.enumerated() { b.frame = NSRect(x: CGFloat(i % 2) * (width + 8), y: CGFloat(i / 2) * 56, width: width, height: 48) }
    }
}

/// AddProviderInstanceDialog.tsx:436-475: provider icon, left aligned label and selected check.
final class ProviderAddDriverChoice: ControlView {
    private let icon: NSView
    private let label: LabelView
    private let check = IconView(name: .check, size: 14, strokeColor: Themed.color(\.primaryForeground))
    private let disc = CALayer()
    private let selected: Bool
    init(driver: String, title: String, selected: Bool) {
        self.selected = selected
        icon = ProviderIcon.make(driver: driver, displayName: title, size: 16, color: Themed.color(\.foreground))
        label = LabelView(title, font: DSFont.ui(14, weight: .medium), color: Themed.color(\.foreground))
        label.lineHeight = 20
        super.init(frame: .zero)
        layer?.addSublayer(disc); [icon, label, check].forEach(addSubview)
        check.isHidden = !selected; disc.isHidden = !selected
        setAccessibilityRole(.radioButton); setAccessibilityLabel(title); setAccessibilityValue(selected ? 1 : 0)
    }
    override func updateLayer() {
        layer?.cornerRadius = 8
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.backgroundColor = (selected ? Themed.color(\.primary, dark ? 0.15 : 0.08) : state.hovered ? Themed.color(\.muted) : dark ? Themed.white(0.03) : Themed.color(\.card)).cgColor(in: self)
        layer?.borderWidth = selected ? 2 : 1
        layer?.borderColor = (selected ? Themed.color(\.primary) : dark ? Themed.white(0.05) : Themed.black(0.05)).cgColor(in: self)
        disc.backgroundColor = Themed.color(\.primary).cgColor(in: self); disc.cornerRadius = 10
    }
    override func stateDidChange(from old: State) { super.stateDidChange(from: old); needsDisplay = true }
    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 12, y: (bounds.height - 16) / 2, width: 16, height: 16)
        label.frame = NSRect(x: 40, y: (bounds.height - 20) / 2, width: max(0, bounds.width - 84), height: 20)
        disc.frame = CGRect(x: bounds.width - 32, y: (bounds.height - 20) / 2, width: 20, height: 20)
        check.frame = NSRect(x: bounds.width - 29, y: (bounds.height - 14) / 2, width: 14, height: 14)
    }
}
