import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// The composer footer's model, traits and access controls and their popups. The composer drops
/// `controlsView` (or the three buttons) into its footer, sets `draftKey` and `context` whenever the
/// thread or the server config changes, and reads `current` when it sends:
/// `current.modelSelection` goes into `message.dispatch` / `launchThread`, `current.runtimeModeToPersist`
/// becomes `thread.runtime-mode.set` before the send (or `launchThread.runtimeMode` for a new thread),
/// `current.interactionMode` goes into the dispatch. After a successful send call `store.didSend(key)`.
@MainActor
public final class ComposerPickers {
    public let store: ComposerSelectionStore
    public let modelButton = ComposerControlView()
    public let traitsButton = ComposerControlView(icon: IconView(name: .brain, size: 16))
    public let accessButton = ComposerControlView()
    /// Model, separator, traits, separator, access with T3's gaps. 28 tall; put its left edge 6pt
    /// from the composer's left edge (footer `px-4` plus the model trigger's `-ms-2.5`).
    public let controlsView: PickerControlsView

    /// The draft key: the thread id, or a new-thread draft id.
    public private(set) var draftKey: String
    public private(set) var context: ComposerSelectionContext
    /// The composer's text, read for the Ultrathink rules. Set it on every edit.
    public var prompt = "" { didSet { if ModelTraits.isUltrathinkPrompt(prompt) != ModelTraits.isUltrathinkPrompt(oldValue) { refresh(notify: false) } } }
    public private(set) var current: ResolvedComposerSelection

    /// Called after any pick with the new values.
    public final var onChange: (@MainActor (ResolvedComposerSelection) -> Void)?
    /// Choosing or leaving Ultrathink rewrites the prompt (`Ultrathink:\n` prefix); apply the text.
    public final var onPromptChange: (@MainActor (String) -> Void)?
    /// A started thread refused the model change; show the text as a toast.
    public final var onBlocked: (@MainActor (String) -> Void)?

    /// Whether the draft may fan out to several models (a new thread on a server with
    /// `requiredWorktreeBootstrap`); the app sets it per draft.
    public var supportsMultipleModels = false
    /// The fan-out's models per draft key; nil is a single model.
    public private(set) var multipleSelections: [String: [ModelSelection]] = [:]
    /// The open draft's fan-out.
    public var currentMultiple: [ModelSelection]? { supportsMultipleModels ? multipleSelections[draftKey] : nil }
    /// The fan-out changed (models added, removed or cleared).
    public final var onMultipleChange: (@MainActor () -> Void)?

    /// Drops the draft's fan-out (after a send, or keeping only the failed models).
    public func setMultiple(_ selections: [ModelSelection]?, for key: String) {
        // A partial fan-out failure may retain one target. Keep its worktree and retry route;
        // explicit single-model picks clear fan-out with nil in the picker handlers.
        multipleSelections[key] = selections.flatMap { $0.isEmpty ? nil : $0 }
        refresh(notify: false)
        onMultipleChange?()
    }

    /// The open environment's favorites and `providerModelPreferences`, from the server when it owns
    /// them (`ModelPreferences`). The app replaces these; the defaults are this client's own.
    public var favorites: () -> [ModelFavorite]
    public var modelPreferences: () -> JSONValue = { ClientSettingsStore.shared.current["providerModelPreferences"] }
    public var toggleFavorite: (ProviderInstanceId, String) -> Void

    private weak var modelPicker: ModelPickerView?
    private var openPopup: OpenPopup?

    public init(store: ComposerSelectionStore, draftKey: String, context: ComposerSelectionContext) {
        self.store = store
        self.draftKey = draftKey
        self.context = context
        current = store.resolve(draftKey, context)
        favorites = { [unowned store] in store.favorites }
        toggleFavorite = { [unowned store] id, model in store.toggleFavorite(id, model) }
        controlsView = PickerControlsView(model: modelButton, traits: traitsButton, access: accessButton)
        modelButton.tintsIcon = false
        modelButton.minimumWidth = 52
        modelButton.action = { [weak self] in self?.toggleModelPicker() }
        traitsButton.action = { [weak self] in self?.openTraits() }
        accessButton.action = { [weak self] in self?.openAccessMode() }
        controlsView.overflow.action = { [weak self] in self?.toggleOverflowMenu() }
        controlsView.onFitChange = { [weak self] in self?.closeHiddenPopup() }
        refresh(notify: false)
    }

    /// Switches to another thread or draft, or follows a new server config or thread snapshot.
    public func update(draftKey: String? = nil, context: ComposerSelectionContext? = nil) {
        if let draftKey { self.draftKey = draftKey }
        if let context { self.context = context }
        refresh(notify: false)
        if let picker = modelPicker {
            picker.catalog = self.context.catalog
            // 2994 servers share favorites and model preferences, so another client's edit lands here.
            let favorites = favorites(), preferences = modelPreferences()
            if picker.favorites != favorites { picker.favorites = favorites }
            if picker.preferences != preferences { picker.preferences = preferences }
        }
    }

    private func refresh(notify: Bool) {
        current = store.resolve(draftKey, context)
        modelButton.title = current.triggerLabel
        if let multiple = currentMultiple {
            modelButton.title = ModelFanout.triggerLabel(multiple.map { s in
                context.catalog.entry(s.instanceId)?.model(s.model).map(ModelNames.trigger) ?? s.model
            })
        }
        // ProviderModelPicker.tsx:95-96, 248-262: the `h-3` badge two points past the 16pt glyph, ringed in `contrast-input`.
        let glyph = current.entry.map { e in
            ProviderIcon.make(driver: e.driver, displayName: e.displayName, size: 16, color: Themed.color(\.contrastMutedForeground),
                              badge: ProviderBadge.make(e, in: context.catalog, size: .small, overhang: 2, ring: Themed.color(\.contrastInput)))
        }
        modelButton.icon = glyph
        modelButton.toolTip = "\(current.triggerLabel) · ⇧⌘M"
        let label = ModelTraits.triggerLabel(current.descriptors, ultrathink: ultrathinkControlled, provider: current.entry?.driver)
        traitsButton.title = label
        traitsButton.toolTip = label
        controlsView.showsTraits = !current.descriptors.isEmpty
        let mode = Self.modes[current.runtimeMode] ?? Self.modes[.fullAccess]!
        accessButton.title = mode.label
        accessButton.icon = IconView(name: mode.icon, size: 16)
        accessButton.toolTip = mode.description
        controlsView.needsLayout = true
        controlsView.invalidateIntrinsicContentSize()
        if notify { onChange?(current) }
    }

    // MARK: Model picker

    /// `modelPicker.toggle`.
    public func toggleModelPicker() {
        if closeIfOpen(modelButton) { return }
        guard let host = modelButton.popupHost, let instance = current.instanceId else { return }
        let view = ModelPickerView(catalog: context.catalog, favorites: favorites(), active: instance,
                                   activeModel: current.model?.slug ?? current.modelSlug ?? "", preferences: modelPreferences())
        view.jumpLabel = { index in
            ActiveKeymap.label(for: Keymap.modelPickerJumpCommands[index], context: KeybindingContext(["modelPickerOpen": true]))
        }
        view.onSelect = { [weak self] id, slug in
            guard let self else { return }
            if self.currentMultiple != nil { self.setMultiple(nil, for: self.draftKey) }
            self.pickModel(id, slug)
        }
        if supportsMultipleModels {
            view.selectedKeys = currentMultiple.map { Set($0.map(ModelFanout.key)) }
            view.onToggle = { [weak self, weak view] id, slug in
                guard let self, let base = self.current.modelSelection else { return }
                let (multiple, single) = ModelFanout.toggle(self.currentMultiple, base: base, instance: id, model: slug)
                if let multiple {
                    self.setMultiple(multiple, for: self.draftKey)
                } else if let single {
                    self.setMultiple(nil, for: self.draftKey)
                    if let reason = self.store.pickModel(self.draftKey, instance: single.instanceId, model: single.model, self.context) {
                        self.onBlocked?(reason)
                    }
                    self.refresh(notify: true)
                }
                view?.selectedKeys = self.currentMultiple.map { Set($0.map(ModelFanout.key)) }
            }
        }
        view.onToggleFavorite = { [weak self, weak view] id, slug in
            guard let self else { return }
            self.toggleFavorite(id, slug)
            view?.favorites = self.favorites()
        }
        let popup = host.open(PickerPopupView(view), trigger: modelButton,
                              placement: PopupPlacement(side: .bottom, align: .start, sideOffset: 4, fallbackAxisSide: .end),
                              motion: .popover)
        track(popup)
        modelPicker = view
        modelButton.window?.makeFirstResponder(view.search)
    }

    /// The model picker's provider rail (`modelPicker.previousProvider` / `nextProvider`) while it is open.
    public func selectAdjacentProvider(_ direction: Int) {
        modelPicker?.selectAdjacentProvider(direction)
    }

    /// `modelPickerOpen` for the keybinding context.
    public var isModelPickerOpen: Bool { modelPicker?.window != nil }

    /// `modelPicker.jump.N` while the picker is open.
    public func jumpModel(_ index: Int) { modelPicker?.jump(index) }

    private func pickModel(_ id: ProviderInstanceId, _ slug: String) {
        closeOpenPopup()
        if let reason = store.pickModel(draftKey, instance: id, model: slug, context) {
            onBlocked?(reason)
            return
        }
        refresh(notify: true)
    }

    // MARK: Traits

    private var ultrathinkControlled: Bool {
        let primary = current.descriptors.first { $0.type == .select }
        return (primary?.promptInjectedValues?.isEmpty == false) && ModelTraits.isUltrathinkPrompt(prompt)
    }

    /// `composer.effort`: opens the traits menu (no-op when the model has no traits), or the overflow
    /// menu while traits sit there (the trigger carrying `data-composer-shortcut~="composer.effort"`).
    public func openTraits() {
        guard controlsView.showsTraits else { return }
        if controlsView.traitsInOverflow { toggleOverflowMenu(); return }
        if closeIfOpen(traitsButton) { return }
        guard let host = traitsButton.popupHost else { return }
        let menu = PickerMenuView(entries: traitsEntries(), style: .menu, minimumWidth: 160 - 2)
        let popup = host.open(PickerPopupView(menu), trigger: traitsButton,
                              placement: PopupPlacement(side: .bottom, align: .start, sideOffset: 4, fallbackAxisSide: .none),
                              swallowsOutsideClick: true)
        menu.onClose = { [weak self] in self?.closeOpenPopup() }
        if NSApp.currentEvent?.type == .keyDown { menu.highlightedIndex = menu.selectable.first }
        track(popup)
    }

    /// The menu content (TraitsPicker.tsx:390-486): one radio group per select descriptor, then
    /// On and Off groups for boolean descriptors.
    func traitsEntries() -> [PickerMenuEntry] {
        let descriptors = current.descriptors
        let selects = descriptors.filter { $0.type == .select }, booleans = descriptors.filter { $0.type == .boolean }
        let primary = selects.first?.id
        let controlled = ultrathinkControlled
        let locked = controlled && ModelTraits.ultrathinkInBody(prompt)
        var out: [PickerMenuEntry] = []
        for (i, d) in selects.enumerated() {
            if i > 0 { out.append(.separator) }
            out.append(.label(d.label))
            if locked && d.id == primary {
                out.append(PickerMenuEntry(kind: .label, title: "Your prompt contains \"ultrathink\" in the text. Remove it to change this option."))
            }
            let selected = controlled && d.id == primary ? "ultrathink" : ModelTraits.currentValue(d)?.string
            for o in d.options {
                out.append(.option(o.label, badge: o.isDefault == true ? "Default" : nil, description: o.description,
                                   checked: o.id == selected, disabled: locked && d.id == primary) { [weak self] in
                    self?.pickSelect(d, o.id)
                })
            }
        }
        for (i, d) in booleans.enumerated() {
            if i > 0 || !selects.isEmpty { out.append(.separator) }
            out.append(.label(d.label, even: true))
            let on = d.currentValue?.bool == true
            for value in [true, false] {
                out.append(.option(value ? "On" : "Off", checked: value == on) { [weak self] in
                    guard let self else { return }
                    self.store.setOptions(self.draftKey, ModelTraits.pick(self.current.descriptors, id: d.id, value: .bool(value)), self.context)
                    self.refresh(notify: true)
                })
            }
        }
        return out
    }

    /// `handleSelectChange` (TraitsPicker.tsx:342-360).
    private func pickSelect(_ d: ProviderOptionDescriptor, _ value: String) {
        if d.promptInjectedValues?.contains(value) == true {
            onPromptChange?(ModelTraits.applyUltrathinkPrefix(prompt))
            return
        }
        let primary = current.descriptors.first { $0.type == .select }?.id
        if ultrathinkControlled && d.id == primary {
            if ModelTraits.ultrathinkInBody(prompt) { return }
            onPromptChange?(ModelTraits.stripUltrathinkPrefix(prompt))
        }
        store.setOptions(draftKey, ModelTraits.pick(current.descriptors, id: d.id, value: .string(value)), context)
        refresh(notify: true)
    }

    // MARK: Access

    struct ModeInfo { let label: String; let description: String; let icon: IconName }

    /// `runtimeModeConfig` (chat/runtimeModeConfig.ts:4-28).
    static let modes: [RuntimeMode: ModeInfo] = [
        .approvalRequired: ModeInfo(label: "Supervised", description: "Ask before commands and file changes.", icon: .lock),
        .autoAcceptEdits: ModeInfo(label: "Auto-accept edits", description: "Auto-approve edits, ask before other actions.", icon: .penLine),
        .auto: ModeInfo(label: "Auto", description: "Supported providers approve routine actions; others still ask.", icon: .sparkles),
        .fullAccess: ModeInfo(label: "Full access", description: "Allow commands and edits without prompts.", icon: .lockOpen),
    ]

    /// `composer.mode`: opens the access select, or the overflow menu while access sits there.
    public func openAccessMode() {
        if controlsView.accessInOverflow { toggleOverflowMenu(); return }
        if closeIfOpen(accessButton) { return }
        guard let host = accessButton.popupHost else { return }
        let list = PickerMenuView(entries: accessEntries(), style: .select, minimumWidth: 256 + 8)
        let popup = host.open(PickerPopupView(list), trigger: accessButton, placement: .dropdown, swallowsOutsideClick: true)
        list.onClose = { [weak self] in self?.closeOpenPopup() }
        if NSApp.currentEvent?.type == .keyDown { list.highlightedIndex = list.selectable.first { list.entry($0).checked } }
        track(popup)
    }

    func accessEntries() -> [PickerMenuEntry] {
        current.runtimeModeOptions.map { mode in
            let info = Self.modes[mode] ?? ModeInfo(label: mode.rawValue, description: "", icon: .lock)
            return .option(info.label, icon: info.icon, description: info.description, checked: mode == current.runtimeMode) { [weak self] in
                guard let self else { return }
                self.store.setRuntimeMode(self.draftKey, mode)
                self.refresh(notify: true)
            }
        }
    }

    // MARK: Overflow menu (CompactComposerControlsMenu.tsx)

    /// Opens the "..." menu below its trigger, start-aligned like the traits menu.
    public func toggleOverflowMenu() {
        let trigger = controlsView.overflow
        if closeIfOpen(trigger) { return }
        guard !trigger.isHidden, let host = trigger.popupHost else { return }
        let menu = PickerMenuView(entries: overflowEntries(), style: .menu, minimumWidth: 160 - 2)
        menu.refreshEntries = { [weak self] in self?.overflowEntries() ?? [] }
        let popup = host.open(PickerPopupView(menu), trigger: trigger,
                              placement: PopupPlacement(side: .bottom, align: .start, sideOffset: 4, fallbackAxisSide: .none),
                              swallowsOutsideClick: true)
        menu.onClose = { [weak self] in self?.closeOpenPopup() }
        if NSApp.currentEvent?.type == .keyDown { menu.highlightedIndex = menu.selectable.first }
        track(popup)
    }

    /// The traits content and a divider when traits moved here, then "Access" and its radio items
    /// (labels only). Access picks keep the menu open: Base UI radio items don't close on click and
    /// T3 sets no `closeOnClick` there, unlike the traits items.
    // ponytail: no "Mode" group (Chat / Plan); add it with the plan mode toggle
    func overflowEntries() -> [PickerMenuEntry] {
        var out: [PickerMenuEntry] = []
        if controlsView.traitsInOverflow { out += traitsEntries() + [.separator] }
        out.append(.label("Access", even: true))
        for mode in current.runtimeModeOptions {
            let info = Self.modes[mode] ?? ModeInfo(label: mode.rawValue, description: "", icon: .lock)
            var entry = PickerMenuEntry.option(info.label, checked: mode == current.runtimeMode) { [weak self] in
                guard let self, mode != self.current.runtimeMode else { return }
                self.store.setRuntimeMode(self.draftKey, mode)
                self.refresh(notify: true)
            }
            entry.keepsOpen = true
            out.append(entry)
        }
        return out
    }

    /// `useComposerMenuState(hidden)`: a menu whose trigger just hid closes.
    private func closeHiddenPopup() {
        guard let trigger = openPopup?.trigger as? ComposerControlView, trigger.isHidden else { return }
        closeOpenPopup()
    }

    // MARK: Popup bookkeeping

    private func track(_ popup: OpenPopup) {
        openPopup = popup
        popup.onClose = { [weak self, weak popup] in
            if self?.openPopup === popup { self?.openPopup = nil }
        }
    }

    /// Closes this control's popup when it is open; a second shortcut press toggles it closed.
    private func closeIfOpen(_ trigger: NSView) -> Bool {
        guard let popup = openPopup, popup.trigger === trigger, let host = trigger.popupHost, host.popups.contains(where: { $0 === popup }) else { return false }
        host.close(popup)
        return true
    }

    private func closeOpenPopup() {
        guard let popup = openPopup, let host = (popup.trigger ?? modelButton).popupHost else { return }
        host.close(popup)
    }
}

/// The footer's left cluster (`data-chat-composer-controls="left"`): model, then the trailing blocks
/// (separator plus traits, separator plus access) 4pt apart, then the "..." overflow trigger when a
/// block moved there. Give it the whole width up to the right cluster: at narrow widths it drops the
/// access label, then the traits label, then moves access, then traits, into the overflow menu
/// (`resolveRestingComposerControlsLayout`, ChatComposer.tsx:5426-5636). After that the model label
/// shrinks, down to 52pt.
public final class PickerControlsView: DSView {
    public let model: ComposerControlView, traits: ComposerControlView, access: ComposerControlView
    /// "More composer controls" (CompactComposerControlsMenu.tsx:41-54).
    public let overflow = ComposerControlView(icon: IconView(name: .ellipsis, size: 16))
    private let separators = [ComposerControlSeparatorView(), ComposerControlSeparatorView()]
    /// False when the model has no trait descriptors (`shouldRenderTraitsControls`).
    public var showsTraits = true { didSet { if showsTraits != oldValue { invalidateIntrinsicContentSize(); needsLayout = true } } }
    /// The current fit; kept between passes for the promotion slack.
    public private(set) var fit = ComposerFooterLayout.Fit()
    /// The blocks in the overflow menu changed; ComposerPickers closes a popup whose trigger hid.
    var onFitChange: (() -> Void)?
    /// No enabled provider: one plain button replaces the cluster (ChatComposer.tsx:5473-5487).
    public let unavailable = ComposerControlView(icon: IconView(name: .circleAlert, size: 16))
    /// "Open provider settings" or "No provider available"; nil shows the pickers.
    public var unavailableTitle: String? {
        didSet {
            guard unavailableTitle != oldValue else { return }
            unavailable.title = unavailableTitle ?? ""
            invalidateIntrinsicContentSize(); needsLayout = true
        }
    }

    init(model: ComposerControlView, traits: ComposerControlView, access: ComposerControlView) {
        self.model = model; self.traits = traits; self.access = access
        super.init(frame: .zero)
        overflow.showsChevron = false
        // The traits menu, the access select and the overflow menu open on press (TraitsPicker.tsx, CompactComposerControlsMenu.tsx).
        for trigger in [traits, access, overflow] { trigger.opensPopupOnPress = true; trigger.scalesWhenPressed = false }
        overflow.setAccessibilityLabel("More composer controls")
        // A plain button, not a popup trigger: no chevron, and it scales when pressed. Its lucide
        // icon keeps the `-mx-0.5` margins the model glyph drops.
        unavailable.showsChevron = false
        unavailable.iconOverhang = 2
        unavailable.scalesWhenPressed = true
        unavailable.setAccessibilityRole(.button)
        unavailable.isHidden = true
        for v in [model, separators[0], traits, separators[1], access, overflow, unavailable] as [NSView] { addSubview(v) }
    }

    /// The trailing blocks in order: separator and trigger each.
    private var blocks: [(ComposerControlSeparatorView, ComposerControlView)] {
        showsTraits ? [(separators[0], traits), (separators[1], access)] : [(separators[1], access)]
    }

    /// Whether the traits or access trigger sits in the overflow menu.
    public var traitsInOverflow: Bool { showsTraits && fit.hiddenCount >= 2 }
    public var accessInOverflow: Bool { fit.hiddenCount >= 1 }

    /// Each block is its 5pt separator, `gap-1` and the trigger (`flex w-max gap-1`).
    var measurement: ComposerFooterLayout.Measurement {
        let b = blocks.map(\.1)
        return ComposerFooterLayout.Measurement(gap: 4, naturalFixedWidth: model.naturalWidth, minimumFixedWidth: model.minimumWidth,
                                                blockWidths: b.map { 9 + $0.width(showingLabel: true) },
                                                iconOnlyBlockWidths: b.map { 9 + $0.width(showingLabel: false) },
                                                overflowWidth: overflow.naturalWidth)
    }

    public override var intrinsicContentSize: NSSize {
        if unavailableTitle != nil { return NSSize(width: unavailable.naturalWidth, height: 28) }
        let m = measurement
        return NSSize(width: ComposerFooterLayout.width(m, hidden: 0, fixed: m.naturalFixedWidth, iconOnly: 0), height: 28)
    }

    // Empty space in the cluster is not a control.
    public override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    public override func layout() {
        super.layout()
        unavailable.isHidden = unavailableTitle == nil
        model.isHidden = unavailableTitle != nil
        if unavailableTitle != nil {
            for v in [separators[0], traits, separators[1], access, overflow] as [NSView] { v.isHidden = true }
            let w = min(unavailable.naturalWidth, bounds.width)
            unavailable.frame = NSRect(x: 0, y: (bounds.height - 28) / 2, width: (w * 2).rounded() / 2, height: 28)
            return
        }
        let old = fit
        // The expanded footer never hides the cluster; the model keeps shrinking and then clips.
        fit = ComposerFooterLayout.resolve(measurement, hostWidth: bounds.width, previous: fit)
        let blocks = self.blocks
        let shown = blocks.count - fit.hiddenCount
        for (i, (sep, trigger)) in blocks.enumerated() {
            trigger.showsLabel = i < blocks.count - fit.iconOnlyCount
            sep.isHidden = i >= shown
            trigger.isHidden = i >= shown
        }
        if !showsTraits { separators[0].isHidden = true; traits.isHidden = true }
        overflow.isHidden = fit.hiddenCount == 0
        var items: [NSView] = [model]
        for (sep, trigger) in blocks.prefix(shown) { items += [sep, trigger] }
        if !overflow.isHidden { items.append(overflow) }
        func natural(_ v: NSView) -> CGFloat { (v as? ComposerControlView)?.naturalWidth ?? 5 }
        let fixed = items.dropFirst().map(natural).reduce(0, +) + CGFloat(items.count - 1) * 4
        // Fractional widths like CSS; boxes snap to device pixels the way Chromium paints them.
        func snap(_ v: CGFloat) -> CGFloat { (v * 2).rounded() / 2 }
        var x: CGFloat = 0
        for v in items {
            var w = natural(v)
            if v === model { w = max(model.minimumWidth, min(w, bounds.width - fixed)) }
            let h: CGFloat = v is ComposerControlView ? 28 : 16
            v.frame = NSRect(x: snap(x), y: (bounds.height - h) / 2, width: snap(x + w) - snap(x), height: h)
            x += w + 4
        }
        if fit != old { onFitChange?() }
    }
}
