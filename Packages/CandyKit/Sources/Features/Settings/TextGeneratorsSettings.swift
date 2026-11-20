import AppKit
import DesignSystem
import T3Protocol

/// Settings > Providers > Text generators (TextGeneratorsSettings.tsx at 4928, PR #33147): one row per model API with
/// its mark, name and address, a ⋯ menu (Edit, Show models, Remove) and an on switch; Add generator opens the wizard.
/// Shown on servers that send `textGenerators`; a 3824 server hides the section.
@MainActor
final class TextGeneratorsSection {
    let section = SettingsSectionView(title: "Text generators", rows: [])
    private let add = ButtonView("Add generator", icon: .plus, variant: .outline, size: .xs)
    private let context: SettingsPageContext
    weak var host: NSView?
    private var env: SettingsScopeEnvironment?
    private var settings: ServerSettingsValues?

    init(context: SettingsPageContext) {
        self.context = context
        add.iconSize = 12
        section.headerAction = add
        add.action = { [weak self] in self?.openWizard(nil) }
        section.isHidden = true
    }

    func update(_ env: SettingsScopeEnvironment, settings: ServerSettingsValues) {
        self.env = env
        self.settings = settings
        section.isHidden = !TextGenerators.supported(settings)
        add.isHidden = !env.canWrite
        let generators = TextGenerators.list(settings)
        var rows: [any SettingsGroupRow] = []
        if generators.isEmpty {
            rows.append(SettingsRowView(title: "No text generators yet",
                                        detail: "Add a model API to write thread titles, commit messages, and other short text without starting a coding agent."))
        }
        for g in generators { rows.append(row(g.id, g.config, env: env)) }
        section.group.rows = rows
    }

    private func row(_ id: String, _ config: TextGenerators.Config, env: SettingsScopeEnvironment) -> SettingsRowView {
        let name = TextGenerators.displayName(config)
        let r = SettingsRowView(title: name, detail: TextGenerators.rowDetail(config))
        r.titleIcon = TextGeneratorIcon.make(kind: config.kind, baseUrl: config.baseUrl, name: name)
        r.titleIconSize = 20
        r.titleIconGap = 10
        r.detailInset = 30
        r.titleLead = 5
        guard env.canWrite else { return r }
        let more = ButtonView(nil, icon: .moreVertical, variant: .ghostMuted, size: .iconSm).menuTrigger()
        more.setAccessibilityLabel("More actions for \(name)")
        more.action = { [weak self, weak more] in
            guard let self, let more else { return }
            var edit = MenuItem("Edit")
            edit.action = { [weak self] in self?.openWizard((id, config)) }
            var show = MenuItem("Show models")
            show.isDisabled = !config.enabled
            show.action = { [weak self] in self?.openModels(id, config) }
            var remove = MenuItem("Remove")
            remove.isDestructive = true
            remove.action = { [weak self] in self?.confirmRemove(id, config) }
            MenuPopupView.show([edit, show, remove], from: more, placement: .dropdown)
        }
        let toggle = SwitchView(isOn: config.enabled)
        toggle.setAccessibilityLabel("Enable \(name)")
        toggle.onChange = { [weak self] on in
            var c = config
            c.enabled = on
            self?.write([id: c.json])
        }
        r.control = SettingsControlGroup([more, toggle])
        return r
    }

    /// `updateSettings({textGenerators: {...}})`: entries merge, `null` removes one.
    private func write(_ entries: [String: JSONValue], onSaved: (() -> Void)? = nil) {
        guard let env, let request = context.request else { return }
        let id = env.id
        Task { [weak self] in
            do {
                let result = try await request(id, "server.updateSettings", .object(["patch": .object(["textGenerators": .object(entries)])]))
                self?.context.applySettings?(id, result)
                onSaved?()
            } catch {
                self?.context.toast?("Could not save text generators", "\(error)", .error)
            }
        }
    }

    private func confirmRemove(_ id: String, _ config: TextGenerators.Config) {
        guard let window = host?.window, let env else { return }
        let d = DialogView(kind: .alertDialog, title: "Remove \(TextGenerators.displayName(config))?",
                           message: "This deletes the API key stored on \(env.label). Anything set to use this generator falls back to the text generation model.")
        let cancel = ButtonView("Cancel", variant: .outline)
        let ok = ButtonView("Remove", variant: .destructive)
        d.footerButtons = [cancel, ok]
        let modal = ModalHost.present(d, in: window)
        cancel.action = { [weak modal] in modal?.close() }
        ok.action = { [weak self, weak modal] in
            modal?.close()
            self?.write([id: .null])
        }
    }

    private func openWizard(_ editing: (id: String, config: TextGenerators.Config)?) {
        guard let window = host?.window, let env, let settings else { return }
        let envId = env.id
        let wizard = TextGeneratorWizard(context: context, environment: envId, editing: editing)
        wizard.newId = { [context] preset in TextGenerators.nextId(preset.id, settings: settings, providers: context.providers) }
        wizard.save = { [weak self] id, config in
            self?.write([id: config.json]) { [weak self] in self?.context.rereadTextGeneratorModels(environment: envId, id: id); self?.context.didChange() }
        }
        let modal = ModalHost.present(wizard.dialog, in: window)
        wizard.close = { [weak modal] in modal?.close() }
        modal.onDismiss = { wizard.close = nil }
    }

    private func openModels(_ id: String, _ config: TextGenerators.Config) {
        guard let window = host?.window, let env else { return }
        let dialog = TextGeneratorModelsDialog(context: context, environment: env.id, id: id, name: TextGenerators.displayName(config))
        let modal = ModalHost.present(dialog.dialog, in: window)
        dialog.close = { [weak modal] in modal?.close() }
    }
}

/// `ProviderInstanceIcon` for a text generator: the service's mark at 20pt, or for a custom endpoint its initials in a
/// bordered tile with a small OpenAI badge for the protocol (ProviderInstanceIcon.tsx:114-180).
enum TextGeneratorIcon {
    /// The mark takes the text color around it (`currentColor`): the row title's foreground, a card's muted text.
    @MainActor static func make(kind: String, baseUrl: String, name: String, color: NSColor = Themed.color(\.foreground)) -> NSView {
        switch TextGenerators.brand(kind: kind, baseUrl: baseUrl) {
        case "openai": return IconView(name: .brandOpenAI, size: 20, strokeColor: color)
        case "anthropic": return IconView(definition: TextGeneratorIcons.anthropic, size: 20, color: color)
        case "openrouter": return IconView(definition: TextGeneratorIcons.openRouter, size: 20, color: color)
        case "ollama": return IconView(definition: TextGeneratorIcons.ollama, size: 20, color: color)
        default: return CustomEndpointTile(name: name)
        }
    }

    final class CustomEndpointTile: DSView {
        private let letters: LabelView
        private let badge = DSView()
        private let mark = IconView(name: .brandOpenAI, size: 8, strokeColor: Themed.color(\.foreground))
        init(name: String) {
            let words = name.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" })
            let initials = words.count > 1 ? words.prefix(2).compactMap(\.first).map(String.init).joined() : String(name.prefix(2))
            letters = LabelView(initials.uppercased(), font: DSFont.ui(9, weight: .semibold), color: Themed.color(\.foreground))
            super.init(frame: .zero)
            letters.alignment = .center
            letters.lineHeight = 20
            addSubview(letters)
            addSubview(badge)
            badge.addSubview(mark)
        }
        required init?(coder: NSCoder) { fatalError() }
        override var wantsUpdateLayer: Bool { true }
        override func updateLayer() {
            layer?.cornerRadius = 6
            layer?.borderWidth = 1
            layer?.borderColor = Themed.color(\.border).cgColor(in: self)
            layer?.backgroundColor = Themed.color(\.card).cgColor(in: self)
            badge.wantsLayer = true
            badge.layer?.cornerRadius = 6
            badge.layer?.borderWidth = 1
            badge.layer?.borderColor = Themed.color(\.border).cgColor(in: self)
            badge.layer?.backgroundColor = Themed.color(\.card).cgColor(in: self)
        }
        override func layout() {
            super.layout()
            letters.frame = bounds
            badge.frame = NSRect(x: bounds.width - 7, y: bounds.height - 7, width: 12, height: 12)
            mark.frame = NSRect(x: 2, y: 2, width: 8, height: 8)
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// `TextGeneratorWizard` (TextGeneratorsSettings.tsx:266-535): Connect lists the service's models with the unsaved
/// settings, then saves; Use it shows the text tasks' model pickers with a Test for a generator's model.
@MainActor
final class TextGeneratorWizard {
    let dialog: DialogView
    var close: (() -> Void)?
    var save: ((String, TextGenerators.Config) -> Void)?
    var newId: ((TextGenerators.Preset) -> String)?

    private let context: SettingsPageContext
    private let environment: String
    private(set) var draft: TextGenerators.Draft
    private(set) var step = 0
    private var savedId: String?
    private var checking = false
    private var checkError: String?
    private var modelCount = 0
    private let steps = WizardStepsView(steps: ["Connect", "Use it"])
    private let body = McpColumn([], gap: 16)
    private let url = InputView(placeholder: "http://localhost:11434/v1")
    private let key = SecureInputView()
    private let label = InputView(placeholder: "")
    private var tests: [String: (key: String, error: String?)] = [:]
    private var testing: Set<String> = []

    init(context: SettingsPageContext, environment: String, editing: (id: String, config: TextGenerators.Config)?) {
        self.context = context
        self.environment = environment
        draft = TextGenerators.Draft(existing: editing?.config)
        savedId = editing?.id
        dialog = DialogView(title: editing.map { "Edit \(TextGenerators.displayName($0.config))" } ?? "Add a text generator",
                            message: "Writes thread titles, commit messages, and other short text without starting a coding agent. Your API key is stored on this environment.")
        dialog.maxWidth = 576
        dialog.headerContent = steps
        dialog.isWizardPanel = true
        dialog.footerVariant = .bare
        dialog.panelContent = [body]
        url.text = draft.baseUrl
        label.text = draft.label
        url.onChange = { [weak self] t in self?.draft.baseUrl = t; self?.checkError = nil; self?.refreshFooter() }
        key.onChange = { [weak self] t in self?.draft.key = t; self?.checkError = nil; self?.refreshFooter() }
        label.onChange = { [weak self] t in self?.draft.label = t; self?.refreshFooter() }
        steps.onStepChange = { [weak self] i in guard let self, i <= self.step else { return }; self.step = i; self.rebuild() }
        rebuild()
    }

    func rebuild() {
        steps.currentStep = step
        for (i, v) in steps.stepViews.enumerated() { v.isEnabled = i <= step }
        body.items = step == 0 ? connectStep() : useStep()
        refreshFooter()
        dialog.needsLayout = true
        dialog.superview?.needsLayout = true
    }

    private func connectStep() -> [NSView] {
        var items: [NSView] = []
        if draft.existing == nil {
            let grid = TextGeneratorServiceGrid(selected: draft.preset.id)
            grid.onSelect = { [weak self] preset in
                guard let self else { return }
                self.draft.pick(preset)
                self.url.text = preset.baseUrl
                self.checkError = nil
                self.rebuild()
            }
            items.append(McpColumn([McpText("Service", size: 14, weight: .medium), grid], gap: 6))
        }
        label.placeholder = draft.existing.map(TextGenerators.displayName) ?? (draft.preset.id == "custom" ? "e.g. My local model" : draft.preset.label)
        key.placeholder = draft.keyConfigured ? "Saved. Enter a new key to replace it." : ""
        var fields: [(String, NSView)] = []
        if draft.showsBaseUrl { fields.append(("Base URL", url)) }
        fields.append((draft.keyRequired ? "API key" : "API key (optional)", key))
        fields.append(("Name (optional)", label))
        for (_, v) in fields { (v as? InputView)?.isEnabled = !checking }
        key.isEnabled = !checking
        items.append(UsageHubFormView(fields))
        if let checkError { items.append(McpText(checkError, size: 14, color: Themed.color(\.destructive))) }
        return items
    }

    private func useStep() -> [NSView] {
        let intro = modelCount == 1
            ? "\(draft.name) is connected and lists 1 model. Switch any of these to it, or keep what they use now."
            : "\(draft.name) is connected and lists \(modelCount) models. Switch any of these to it, or keep what they use now."
        var items: [NSView] = [McpText(intro, size: 14, muted: true)]
        for task in TextGenerators.tasks { items.append(taskRow(task.key, task.label)) }
        return [McpColumn(items, gap: 16)]
    }

    /// `TextGenerationTaskPicker`: the task, its state line, the picker and, for a generator's model, Test.
    private func taskRow(_ settingKey: String, _ title: String) -> NSView {
        let values = context.scope.environments.first { $0.id == environment }?.settings
        let own = values?[settingKey]
        let follows = own == nil || own == .null
        let selection = (try? (follows ? values?["textGenerationModelSelection"] : own)?.decode(as: ModelSelection.self)) ?? nil
        let testKey = selection.map { "\($0.instanceId.rawValue):\($0.model)" } ?? ""
        let shown = tests[settingKey].flatMap { $0.key == testKey ? $0 : nil }
        var line: McpText?
        if let shown {
            line = shown.error.map { McpText($0, size: 12, color: Themed.color(\.destructive)) }
                ?? McpText("\(selection?.model ?? "") answered. It works.", size: 12, muted: true)
        } else if follows, settingKey != "textGenerationModelSelection" {
            line = McpText("Follows the text generation model", size: 12, muted: true)
        }
        let picker = SettingsModelPickerControl(context: context, key: settingKey)
        picker.refresh()
        var trailing: [NSView] = [picker]
        let testable = selection.map { s in values.map { TextGenerators.list($0).contains { $0.id == s.instanceId.rawValue } } ?? false } ?? false
        if testable, let selection {
            let busy = testing.contains(settingKey)
            let test = ButtonView(busy ? nil : "Test", variant: .outline, size: .xs)
            test.reservedTitles = ["Test"]
            test.showsSpinner = busy
            test.isEnabled = !busy
            test.setAccessibilityLabel("Test")
            test.action = { [weak self] in self?.test(settingKey, selection, key: testKey) }
            trailing.append(test)
        }
        let left = McpColumn([McpText(title, size: 14)] + (line.map { [$0] } ?? []), gap: 2)
        return TextGeneratorTaskRow(left: left, trailing: trailing)
    }

    private func test(_ settingKey: String, _ selection: ModelSelection, key: String) {
        guard let request = context.request else { return }
        testing.insert(settingKey)
        rebuild()
        let env = environment
        Task { [weak self] in
            var error: String?
            do {
                _ = try await request(env, "server.listTextGeneratorModels",
                                      TextGenerators.listInput(id: selection.instanceId.rawValue, test: true, model: selection.model))
            } catch let e { error = "\(e)" }
            guard let self else { return }
            self.testing.remove(settingKey)
            self.tests[settingKey] = (key, error)
            self.rebuild()
        }
    }

    private func refreshFooter() {
        if step == 0 {
            let cancel = ButtonView("Cancel", variant: .outline)
            cancel.action = { [weak self] in self?.close?() }
            let connect = ButtonView(checking ? "Connecting" : draft.existing != nil ? "Save and continue" : "Connect")
            connect.showsSpinner = checking
            connect.isEnabled = draft.canConnect && !checking
            connect.action = { [weak self] in self?.connect() }
            dialog.footerButtons = [cancel, connect]
            dialog.footerLeadingCount = 0
        } else {
            let back = ButtonView("Back", variant: .ghost)
            back.action = { [weak self] in self?.step = 0; self?.rebuild() }
            let done = ButtonView("Done")
            done.action = { [weak self] in self?.close?() }
            dialog.footerButtons = [back, done]
            dialog.footerLeadingCount = 1
        }
    }

    /// Lists the models the unsaved settings reach; on success saves and moves to Use it.
    func connect() {
        guard draft.canConnect, !checking, let config = draft.config, let request = context.request else { return }
        let id = savedId ?? newId?(draft.preset) ?? draft.preset.id
        checking = true
        checkError = nil
        rebuild()
        let env = environment
        Task { [weak self] in
            do {
                let result = try await request(env, "server.listTextGeneratorModels", TextGenerators.listInput(id: id, config: config))
                guard let self else { return }
                self.checking = false
                self.save?(id, config)
                self.savedId = id
                self.modelCount = TextGenerators.models(result).count
                self.step = 1
            } catch {
                guard let self else { return }
                self.checking = false
                self.checkError = "\(error)"
            }
            self?.rebuild()
        }
    }
}

/// The Service radio grid: `grid grid-cols-4 gap-2` of `rounded-lg border px-2 py-3` cards with the mark and name.
final class TextGeneratorServiceGrid: DSView, McpSized {
    var onSelect: ((TextGenerators.Preset) -> Void)?
    private var cards: [ServiceCard] = []
    init(selected: String) {
        super.init(frame: .zero)
        for preset in TextGenerators.presets {
            let card = ServiceCard(preset: preset, selected: preset.id == selected)
            card.action = { [weak self] in self?.onSelect?(preset) }
            cards.append(card); addSubview(card)
        }
        setAccessibilityRole(.radioGroup); setAccessibilityLabel("Service")
    }
    required init?(coder: NSCoder) { fatalError() }
    func height(forWidth width: CGFloat) -> CGFloat { 74 }
    override func layout() {
        super.layout()
        let w = (bounds.width - 24) / 4
        for (i, c) in cards.enumerated() { c.frame = NSRect(x: CGFloat(i) * (w + 8), y: 0, width: w, height: 74) }
    }

    final class ServiceCard: ControlView {
        private let icon: NSView
        private let label: LabelView
        private let selected: Bool
        private let ring = CALayer()
        init(preset: TextGenerators.Preset, selected: Bool) {
            self.selected = selected
            let name = preset.id == "custom" ? "Custom" : preset.label
            icon = preset.id == "custom" ? IconView(name: .server, size: 20, strokeColor: Themed.color(selected ? \.foreground : \.mutedForeground))
                : TextGeneratorIcon.make(kind: preset.kind, baseUrl: preset.baseUrl, name: preset.label,
                                         color: Themed.color(selected ? \.foreground : \.mutedForeground))
            label = LabelView(name, font: DSFont.ui(14, weight: selected ? .medium : .regular), color: Themed.color(selected ? \.foreground : \.mutedForeground))
            super.init(frame: .zero)
            scalesWhenPressed = false
            label.lineHeight = 20; label.alignment = .center
            ring.actions = ["position": NSNull(), "bounds": NSNull()]
            ring.isHidden = !selected
            layer?.addSublayer(ring)
            addSubview(icon); addSubview(label)
            setAccessibilityRole(.radioButton); setAccessibilityLabel(name); setAccessibilityValue(selected ? 1 : 0)
        }
        required init?(coder: NSCoder) { fatalError() }
        override var wantsUpdateLayer: Bool { true }
        override func updateLayer() {
            layer?.cornerRadius = 8
            layer?.borderWidth = 1
            layer?.borderColor = Themed.color(selected ? \.primary : \.border).cgColor(in: self)
            layer?.backgroundColor = (selected ? Themed.color(\.primary, 0.05) : state.hovered ? Themed.color(\.accent, 0.5) : Themed.color(\.background)).cgColor(in: self)
            // `ring-1 ring-primary ring-inset`.
            ring.borderWidth = 1
            ring.cornerRadius = 7
            ring.borderColor = Themed.color(\.primary).cgColor(in: self)
        }
        override func stateDidChange(from old: State) { super.stateDidChange(from: old); needsDisplay = true }
        override func layout() {
            super.layout()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            ring.frame = bounds.insetBy(dx: 1, dy: 1)
            CATransaction.commit()
            icon.frame = NSRect(x: (bounds.width - 20) / 2, y: 13, width: 20, height: 20)
            label.frame = NSRect(x: 9, y: 41, width: bounds.width - 18, height: 20)
        }
    }
}

/// One `Use it` row: the task and its line on the left, the picker and Test on the right (`grid-cols-[1fr_auto_auto]`).
final class TextGeneratorTaskRow: DSView, McpSized {
    private let left: McpColumn
    private let trailing: [NSView]
    init(left: McpColumn, trailing: [NSView]) {
        self.left = left; self.trailing = trailing
        super.init(frame: .zero)
        addSubview(left); trailing.forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }
    private var trailingWidth: CGFloat { trailing.reduce(0) { $0 + $1.intrinsicContentSize.width + 8 } }
    func height(forWidth width: CGFloat) -> CGFloat { max(left.height(forWidth: width - trailingWidth - 8), 28) }
    override func layout() {
        super.layout()
        var x = bounds.width
        for v in trailing.reversed() {
            let s = v.intrinsicContentSize
            x -= s.width
            v.frame = NSRect(x: x, y: (bounds.height - s.height) / 2, width: s.width, height: s.height)
            x -= 8
        }
        let lh = left.height(forWidth: x - 8)
        left.frame = NSRect(x: 0, y: (bounds.height - lh) / 2, width: max(0, x - 8), height: lh)
    }
}

/// `TextGeneratorModelsDialog` (TextGeneratorsSettings.tsx:725-803): the saved generator's models, searchable past eight,
/// with Refresh that asks the API again.
@MainActor
final class TextGeneratorModelsDialog {
    let dialog: DialogView
    var close: (() -> Void)?
    private let context: SettingsPageContext
    private let environment: String, id: String, name: String
    private let body = McpColumn([], gap: 8)
    private let search = InputView(placeholder: "Search models")
    private var query = ""
    private var refreshing = false
    private var observed = false

    init(context: SettingsPageContext, environment: String, id: String, name: String) {
        self.context = context; self.environment = environment; self.id = id; self.name = name
        dialog = DialogView(title: "\(name) models", message: "Loading the model list.")
        dialog.maxWidth = 448
        dialog.footerVariant = .bare
        dialog.panelContent = [body]
        search.setAccessibilityLabel("Search models")
        search.onChange = { [weak self] t in self?.query = t; self?.rebuild() }
        context.loadTextGeneratorModels(environment: environment, id: id)
        context.observe { [weak self] in self?.rebuild() }
        rebuild()
    }

    func rebuild() {
        let state = context.textGeneratorModels["\(environment):\(id)"]
        var items: [NSView] = []
        switch state {
        case .success(let models)?:
            dialog.message = models.count == 1 ? "1 model available. Pick one in a text generation model picker."
                : "\(models.count) models available. Pick one in a text generation model picker."
            if models.count > 8 {
                search.frame.size.height = 32
                items.append(search)
            }
            let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
            let shown = needle.isEmpty ? models : models.filter { $0.id.lowercased().contains(needle) || $0.name.lowercased().contains(needle) }
            items.append(TextGeneratorModelList(shown))
        case .failure(let e)?:
            dialog.message = "The model list couldn't load."
            items.append(McpText(e.detail, size: 14, color: Themed.color(\.destructive)))
        case nil:
            dialog.message = "Loading the model list."
            items.append(McpStatusLine(""))
        }
        body.items = items
        let refresh = ButtonView("Refresh", icon: .refreshCw, variant: .outline)
        refresh.isEnabled = !refreshing
        refresh.showsSpinner = refreshing
        refresh.action = { [weak self] in self?.refresh() }
        let done = ButtonView("Done")
        done.action = { [weak self] in self?.close?() }
        dialog.footerButtons = [refresh, done]
        dialog.needsLayout = true
        dialog.superview?.needsLayout = true
    }

    private func refresh() {
        refreshing = true
        rebuild()
        context.loadTextGeneratorModels(environment: environment, id: id, refresh: true) { [weak self] error in
            guard let self else { return }
            self.refreshing = false
            if let error { self.context.toast?("Couldn't load \(self.name) models", error, .error) }
            self.rebuild()
        }
    }
}

/// `TextGeneratorModelList` read-only: `max-h-80 rounded-lg border divide-y`, name over a mono id when they differ.
final class TextGeneratorModelList: DSView, McpSized {
    private let scroll = NSScrollView()
    private let content = McpColumn([], gap: 0)
    private let models: [(id: String, name: String)]
    init(_ models: [(id: String, name: String)]) {
        self.models = models
        super.init(frame: .zero)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let doc = FlippedDocument()
        doc.addSubview(content)
        scroll.documentView = doc
        addSubview(scroll)
        content.items = models.isEmpty ? [ModelRow(name: "No models match.", id: nil, muted: true)]
            : models.map { ModelRow(name: $0.name, id: $0.name == $0.id ? nil : $0.id, muted: false) }
        setAccessibilityRole(.list); setAccessibilityLabel("Models")
    }
    required init?(coder: NSCoder) { fatalError() }
    func height(forWidth width: CGFloat) -> CGFloat { min(320, content.height(forWidth: width - 2) + 2) }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = Themed.color(\.border).cgColor(in: self)
    }
    override func layout() {
        super.layout()
        scroll.frame = bounds.insetBy(dx: 1, dy: 1)
        let h = content.height(forWidth: scroll.frame.width)
        scroll.documentView?.frame = NSRect(x: 0, y: 0, width: scroll.frame.width, height: h)
        content.frame = NSRect(x: 0, y: 0, width: scroll.frame.width, height: h)
    }
    final class FlippedDocument: NSView { override var isFlipped: Bool { true } }

    final class ModelRow: DSView, McpSized {
        private let title: LabelView
        private let sub: LabelView?
        private let divider = CALayer()
        init(name: String, id: String?, muted: Bool) {
            title = LabelView(name, font: DSFont.ui(14), color: Themed.color(muted ? \.mutedForeground : \.foreground))
            sub = id.map { LabelView($0, font: DSFont.mono(12), color: Themed.color(\.mutedForeground)) }
            super.init(frame: .zero)
            title.lineHeight = 20; sub?.lineHeight = 16
            addSubview(title); sub.map(addSubview)
            divider.actions = ["position": NSNull(), "bounds": NSNull()]
            layer?.addSublayer(divider)
            setAccessibilityElement(true); setAccessibilityRole(.staticText); setAccessibilityLabel([name, id].compactMap { $0 }.joined(separator: ", "))
        }
        required init?(coder: NSCoder) { fatalError() }
        func height(forWidth width: CGFloat) -> CGFloat { 16 + 20 + (sub == nil ? 0 : 16) }
        override var wantsUpdateLayer: Bool { true }
        override func updateLayer() { divider.backgroundColor = Themed.color(\.border, 0.6).cgColor(in: self) }
        override func layout() {
            super.layout()
            title.frame = NSRect(x: 12, y: 8, width: bounds.width - 24, height: 20)
            sub?.frame = NSRect(x: 12, y: 28, width: bounds.width - 24, height: 16)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            divider.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 1)
            divider.isHidden = frame.minY == 0
            CATransaction.commit()
        }
    }
}
