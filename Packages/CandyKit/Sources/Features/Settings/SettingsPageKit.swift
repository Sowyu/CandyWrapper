import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// What the settings pages read and how they write (T3's `useScopedSettings` and `useUpdateScopedSettings`).
/// The app fills it from the client settings store and every environment's server config.
@MainActor
public final class SettingsPageContext {
    public var client = ClientSettings.defaults
    public var scope = SettingsScopeState(environments: [], primaryId: nil)
    /// T3's theme preference: "system", "light" or "dark".
    public var appearanceMode = "system"
    /// The representative environment's providers, for the model pickers.
    public var providers: [ServerProvider] = []
    /// The primary environment's resolved keybindings (`serverConfig.keybindings`), before the merge with the defaults.
    public var serverKeybindings: [ResolvedKeybindingRule] = []
    public var keybindingsConfigPath: String?
    public var appVersion = ""
    /// The app updater's state (`useDesktopUpdateState`) for the Version and Update track rows.
    public var update: DesktopUpdateState?
    public var runtimeUpdate: DesktopUpdateState?
    public var runtimeUpdateButton: (() -> Void)?
    /// `isUpdateActionPending` and `isChangingUpdateChannel` (SettingsPanels.tsx:282-283).
    public var updateActionPending = false
    public var changingUpdateTrack = false
    /// The Version row's button: download, install (after the confirm) or check (SettingsPanels.tsx:323-391).
    public var updateButton: (() -> Void)?
    /// `bridge.setUpdateChannel` from the Update track select.
    public var setUpdateTrack: ((DesktopUpdateState.Channel) -> Void)?

    public var setupSnapShot: (() -> Void)?
    public var snapShotReady: (() -> Bool)?
    public var writeClient: (([String: JSONValue]) -> Void)?
    /// Saves a notification mode after asking for notification permission when it needs it; returns the
    /// row's message when the mode can't be used (the app's `ThreadNotificationCoordinator.choose`).
    public var chooseNotificationMode: ((ThreadNotificationMode) async -> String?)?
    /// A server patch for the scope's targets (`planScopedSettingsPatch`).
    public var writeServer: (([String: JSONValue]) -> Void)?
    /// Invalidates optimistic editors when a server save fails without changing the saved value.
    public var serverWriteFailureRevision = 0
    public var setAppearanceMode: ((String) -> Void)?
    public var selectScope: ((SettingsScopeSelection) -> Void)?
    public var saveKeybinding: ((KeybindingTarget, KeybindingTarget?) -> Void)?
    public var removeKeybinding: ((KeybindingRow) -> Void)?
    public var openKeybindingsFile: (() -> Void)?
    public var openURL: ((URL) -> Void)?
    public var toast: ((String, String?, ToastQueue.Kind) -> Void)?
    /// Opens a modal dialog (the background activity dialog).
    public var presentDialog: ((DialogView) -> ModalHost?)?
    /// Drops the keys' project overrides at a project scope (`useClearScopedSettings`).
    public var clearServer: (([String]) -> Void)?
    /// One RPC on an environment's socket (environment id, method, payload).
    public var subscribeProviderAuth: ((String, String, @escaping @MainActor @Sendable (JSONValue) -> Void) -> Task<Void, Never>?)?
    public var subscribeResourceTelemetry: ((String, @escaping @MainActor @Sendable (JSONValue) -> Void) -> Task<Void, Never>?)?
    public var request: ((String, String, JSONValue) async throws -> JSONValue)?
    /// A visible feature owns and cancels this server push subscription.
    public var subscribe: ((String, String, JSONValue, @escaping @MainActor @Sendable (JSONValue) -> Void) -> Task<Void, Never>?)?
    /// Applies the settings a `server.updateSettings` reply returned to that environment's config.
    public var applySettings: ((String, JSONValue) -> Void)?
    /// `requestConfirmDialog(message, {variant})`: the app's alert dialog; the closure runs on Confirm.
    public var confirm: ((_ message: String, _ destructive: Bool, _ onConfirm: @escaping @MainActor () -> Void) -> Void)?
    /// Each environment's server config (providers, keybindings), by id.
    public var configs: [String: ServerProviderConfig] = [:]
    /// An environment's model favorites and `providerModelPreferences`: the server's from 2994 on,
    /// else this client's (`ModelPreferences`).
    public var modelPreferences: ((String) -> (favorites: [ModelFavorite], providers: JSONValue))?
    public var toggleFavorite: ((_ environmentId: String, ProviderInstanceId, String) -> Void)?
    /// Saves one instance's hidden models and order on an environment.
    public var writeModelPreferences: ((_ environmentId: String, _ instanceId: String, _ hidden: [String], _ order: [String]) -> Void)?
    /// Opens another settings page.
    public var openSection: ((SettingsSection) -> Void)?
    /// T3 Connect has loaded and nobody is signed in (`isSignedIn === false`); false while it loads.
    public var connectSignedOut = false
    /// Opens T3 Connect's sign-in.
    public var signInToConnect: (() -> Void)?
    /// Leaves Settings for the thread view (after removing the open project).
    public var closeSettings: (() -> Void)?
    /// Copies text and shows a toast with the title.
    public var copy: ((String, String) -> Void)?
    /// `projects.mutate project.update` on every member, stopping at the first failure (`updateAllMembers`).
    public var updateProject: ((_ members: [SettingsScopeProject.Member], _ fields: [String: JSONValue], _ failureTitle: String) -> Void)?
    /// "Choose file": the project icon file picker over a checkout (environment, workspace root, group name,
    /// whether a file on this Mac may be picked); the pick is a path.
    public var chooseIconFile: ((_ environmentId: String, _ cwd: String, _ projectName: String, _ external: Bool,
                                 _ onSelect: @escaping (String) -> Void) -> Void)?
    /// `projects.mutate project.delete {force: true}` for each member; `leave` returns to the thread view.
    public var deleteProjects: ((_ members: [SettingsScopeProject.Member], _ leave: Bool) -> Void)?
    /// Active threads of a project on an environment (environment id, project id), for the removal prompt.
    public var threadCount: ((String, String) -> Int)?
    /// Runs project action writes in order; returns the first error message, or nil.
    public var saveActions: (([ProjectActionsLogic.Write]) async -> String?)?
    /// Each environment's live scheduled task list (`scheduledTasks.subscribe`), filled by the app while watched.
    public var scheduledTasks: [String: ScheduledTaskListLoad] = [:]
    /// Starts (true) or stops following the scope's task lists.
    public var watchScheduledTasks: ((Bool) -> Void)?
    /// The address this client reaches an environment at, for webhook URLs without T3 Connect.
    public var httpBaseURL: ((String) -> URL?)?
    /// `desktopBridge.receiveProviderAuthCallback` (apps/desktop/src/ipc/methods/providerAuth.ts:16-38): opens
    /// ChatGPT's sign-in page, catches its loopback callback on this computer and returns the callback URL.
    public var receiveProviderAuthCallback: ((String) async throws -> String)?
    /// `desktopBridge.cancelProviderAuthCallback`: stops listening for that sign-in.
    public var cancelProviderAuthCallback: ((String) -> Void)?

    public init() {}

    private var observers: [() -> Void] = []
    /// Calls `block` after every `didChange` (dialogs that outlive a page refresh).
    func observe(_ block: @escaping () -> Void) { observers.append(block) }
    /// The app calls this after it changed the context.
    public func didChange() { observers.forEach { $0() } }

    func patchClient(_ key: String, _ value: JSONValue) { writeClient?([key: value]) }
    func patchServer(_ patch: [String: JSONValue]) { writeServer?(patch) }
}

/// Rows register context readers; projected bindings update controls only when their value changes.
@MainActor
final class SettingsBinder {
    private var updaters: [() -> Void] = []
    func add(_ update: @escaping () -> Void) { updaters.append(update); update() }
    func add<Value: Equatable>(read: @escaping () -> Value, update: @escaping (Value) -> Void) {
        var previous = read()
        update(previous)
        updaters.append {
            let next = read()
            guard next != previous else { return }
            previous = next
            update(next)
        }
    }
    func refresh() { updaters.forEach { $0() } }
}

/// A page: sections stacked `gap-8` (`WorkspacePageContainer`), hidden ones skipped.
public class SettingsStackView: DSView, SettingsGroupRow {
    var items: [NSView & SettingsGroupRow] = [] {
        didSet { oldValue.forEach { $0.removeFromSuperview() }; items.forEach(addSubview); needsLayout = true }
    }
    var gap: CGFloat = 32
    /// Anchors for settings search: id to view.
    var anchors: [String: NSView] = [:]

    /// Redesign shows part of a page (`DitherSettingsSectionView`): items this refuses stay hidden.
    var itemFilter: ((NSView) -> Bool)? { didSet { needsLayout = true } }
    private var shown: [NSView & SettingsGroupRow] { items.filter { !$0.isHidden && itemFilter?($0) != false } }

    public func height(forWidth width: CGFloat) -> CGFloat {
        let visible = shown
        return visible.reduce(0) { $0 + $1.height(forWidth: width) } + gap * CGFloat(max(0, visible.count - 1))
    }

    public override func layout() {
        super.layout()
        if let itemFilter { for item in items where !itemFilter(item) { item.isHidden = true } }
        var y: CGFloat = 0
        for item in shown {
            let h = item.height(forWidth: bounds.width)
            item.frame = NSRect(x: 0, y: y, width: bounds.width, height: h)
            item.needsLayout = true
            y += h + gap
        }
    }

    /// The view a search result lands on.
    public func anchor(_ id: String) -> NSView? { anchors[id] }
}

/// `SettingResetButton`: an `icon-micro ghost-muted` undo arrow (size-3) with "Reset to default".
/// The slot stays 20pt wide when empty, as T3 always renders the span.
final class ResetSlot: DSView {
    let button = ButtonView(nil, icon: .undo2, variant: .ghostMuted, size: .iconMicro)
    var action: (@MainActor () -> Void)? { didSet { button.action = action } }
    var isShown = false { didSet { button.isHidden = !isShown } }
    private var tip: TooltipController?
    var tooltip: String {
        get { tip?.text ?? "" }
        set { if tip?.text != newValue { tip?.text = newValue } }
    }

    init(label: String, tooltip: String = "Reset to default") {
        super.init(frame: .zero)
        button.iconSize = 12
        button.setAccessibilityLabel("Reset \(label) to default")
        tip = TooltipController.attach(to: button, text: tooltip)
        button.isHidden = true
        addSubview(button)
    }

    override func layout() { super.layout(); button.frame = bounds }
}

/// `SettingInheritance`'s trigger: a `layers` glyph (size-3) tinted for overridden and mixed values, with
/// the summary as its tooltip. Clicking shows the chain per environment.
final class InheritanceButton: DSView, FocusWithinObserver {
    let button = ButtonView(nil, icon: .layers, variant: .ghostMuted, size: .iconMicro)
    private var tooltip: TooltipController?
    private var rowTracking: NSTrackingArea?
    private weak var trackedRow: NSView?
    private var rowHovered = false
    var hasOverridingProjects = false { didSet { refreshVisibility() } }
    var onOpen: ((NSView) -> Void)?
    var state: SettingInheritanceState = .default { didSet { refreshVisibility() } }
    var summary = "" { didSet { tooltip?.text = summary; button.setAccessibilityLabel("\(summary). Show where this value comes from") } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        button.iconSize = 12
        tooltip = TooltipController.attach(to: button, text: "")
        button.action = { [weak self] in guard let self else { return }; self.tooltip?.hide(); self.onOpen?(self.button) }
        addSubview(button)
        refreshVisibility()
    }

    func refreshVisibility() {
        button.iconColor = state == .overridden ? Themed.color(\.primary) : state == .mixed ? Themed.color(\.warning) : nil
        let localValue = state == .default || state == .environment
        button.alphaValue = ThemeRuntime.isDither(dark: effectiveAppearance.isDark) || !localValue || hasOverridingProjects
            || rowHovered || button.state.focusVisible || button.state.popupOpen ? 1 : 0
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refreshVisibility() }
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if let rowTracking { trackedRow?.removeTrackingArea(rowTracking) }
        rowTracking = nil
        trackedRow = superview
        guard let superview else { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        superview.addTrackingArea(area)
        rowTracking = area
    }
    override func mouseEntered(with event: NSEvent) { rowHovered = true; refreshVisibility() }
    override func mouseExited(with event: NSEvent) { rowHovered = false; refreshVisibility() }
    func focusWithinChanged(_ focused: Bool) { refreshVisibility() }

    override func layout() { super.layout(); button.frame = bounds }
}

/// T3's `InlineButton tone="picker"`: an optional glyph, the 16px medium value with a dotted underline,
/// and a chevron. Opens a menu from inside the scope sentence.
final class InlinePickerButton: ControlView {
    private let label = LabelView("", font: DSFont.ui(16, weight: .medium), color: Themed.color(\.foreground))
    private let chevron = IconView(name: .chevronDown, size: 14)
    private let underline = CAShapeLayer()
    private let bordered = ButtonView(nil, variant: .outline, size: .sm)
    private var modern: Bool { !ThemeRuntime.isDither(dark: effectiveAppearance.isDark) }
    var glyph: NSView? { didSet { oldValue?.removeFromSuperview(); glyph.map(addSubview); invalidateIntrinsicContentSize(); needsLayout = true } }
    var title = "" { didSet { label.text = title; invalidateIntrinsicContentSize(); needsLayout = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        opensPopupOnPress = true // a menu trigger
        label.lineHeight = 24
        addSubview(label)
        addSubview(chevron)
        underline.fillColor = nil
        underline.lineWidth = 1
        underline.lineDashPattern = [1, 2]
        underline.actions = ["path": NSNull(), "strokeColor": NSNull(), "lineDashPattern": NSNull()]
        layer?.addSublayer(underline)
        bordered.iconSize = 14
        bordered.action = { [weak self] in self?.action?() }
        addSubview(bordered)
        setAccessibilityRole(.popUpButton)
        restyle()
    }

    override var acceptsFirstResponder: Bool { !modern && super.acceptsFirstResponder }

    override var intrinsicContentSize: NSSize {
        if modern {
            label.font = DSFont.ui(14)
            return NSSize(width: min(288, 16 + (glyph == nil ? 0 : 20) + ceil(label.textWidth) + 6 + 14), height: 28)
        }
        let g: CGFloat = glyph == nil ? 0 : 14 + 6
        return NSSize(width: min(288, ceil(g + label.textWidth + 6 + 14)), height: 24)
    }

    override func stateDidChange(from old: State) { super.stateDidChange(from: old); restyle() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); restyle() }

    private func restyle() {
        bordered.isHidden = !modern
        label.font = modern ? DSFont.ui(14) : DSFont.ui(16, weight: .medium)
        label.lineHeight = modern ? 20 : 24
        chevron.strokeWidth = modern ? 1.75 : nil
        chevron.alphaValue = modern ? 0.7 : 1
        underline.isHidden = modern
        let solid = state.hoverOrPressed || state.popupOpen
        underline.strokeColor = Themed.color(\.foreground, solid ? 1 : 0.3).cgColor(in: self)
        underline.lineDashPattern = solid ? nil : [1, 2]
        chevron.strokeColor = Themed.color(\.mutedForeground)
    }

    override func layout() {
        super.layout()
        restyle()
        if modern {
            bordered.frame = bounds
            addSubview(bordered, positioned: .below, relativeTo: label)
            let x: CGFloat = glyph == nil ? 8 : 28
            if let glyph { glyph.frame = NSRect(x: 8, y: (bounds.height - 14) / 2, width: 14, height: 14) }
            let w = max(0, min(ceil(label.textWidth) + 1, bounds.width - x - 28))
            label.frame = NSRect(x: x, y: (bounds.height - 20) / 2, width: w, height: 20)
            chevron.frame = NSRect(x: bounds.width - 20, y: (bounds.height - 14) / 2, width: 14, height: 14)
            return
        }
        var x: CGFloat = 0
        if let glyph { glyph.frame = NSRect(x: 0, y: 5, width: 14, height: 14); x = 20 }
        let w = max(0, min(ceil(label.textWidth) + 1, bounds.width - x - 20))
        label.frame = NSRect(x: x, y: 0, width: w, height: 24)
        chevron.frame = NSRect(x: x + w + 6, y: 5, width: 14, height: 14)
        let path = CGMutablePath()
        // `underline-offset-4` under the text's baseline.
        path.move(to: CGPoint(x: x, y: 21.5)); path.addLine(to: CGPoint(x: x + w, y: 21.5))
        underline.frame = bounds
        underline.path = path
    }
}

/// `SettingsScopeSentence`: "Applying settings for <project> across <environment>" at the top of
/// server-backed pages (`px-4 text-base text-muted-foreground`, pickers `gap-1.5`).
final class SettingsScopeSentenceView: DSView, SettingsGroupRow {
    private let lead = LabelView("Applying settings for", font: DSFont.ui(16), color: Themed.color(\.mutedForeground))
    private let connective = LabelView("across", font: DSFont.ui(16), color: Themed.color(\.mutedForeground))
    let project = InlinePickerButton()
    let environment = InlinePickerButton()
    weak var context: SettingsPageContext?
    /// Providers and Diagnostics show one environment at a time (`singleEnvironment`): no "All environments".
    var singleEnvironment = false
    /// The environment such a page picked when none is chosen (`selectSingleEnvironmentScope`).
    var impliedMachine: String?

    init(context: SettingsPageContext) {
        self.context = context
        super.init(frame: .zero)
        for l in [lead, connective] { l.lineHeight = 24; addSubview(l) }
        addSubview(project)
        addSubview(environment)
        project.setAccessibilityLabel("Project scope")
        environment.setAccessibilityLabel("Environment scope")
        project.action = { [weak self] in self?.openProjects() }
        environment.action = { [weak self] in self?.openEnvironments() }
        refresh()
    }

    func refresh() {
        guard let scope = context?.scope else { return }
        let selected = scope.selection.project.flatMap { key in scope.projects.first { $0.key == key } }
        project.title = selected?.displayName ?? (scope.selection.project == nil ? "All projects" : "Unavailable project")
        // `ProjectFavicon className="size-3.5"` before the selected project (SettingsScopeSentence.tsx:193).
        if let icon = selected?.icon {
            if (project.glyph as? ProjectMonogramView)?.source != icon { project.glyph = ProjectMonogramView(icon, size: 14) }
        } else if project.glyph != nil {
            project.glyph = nil
        }
        let machine = scope.selection.machine ?? (singleEnvironment ? impliedMachine : nil)
        connective.text = machine == nil ? "across" : "on"
        if let id = machine, let e = scope.environments.first(where: { $0.id == id }) {
            environment.title = scope.environmentLabel(e)
            environment.glyph = EnvironmentMachineIcon.view(e.machine, size: 14, color: Themed.color(\.foreground))
        } else {
            environment.title = scope.selection.machine != nil ? "Unavailable environment" : singleEnvironment ? "No environments" : "All environments"
            environment.glyph = nil
        }
        needsLayout = true
    }

    private func openEnvironments() {
        guard let context else { return }
        let scope = context.scope
        var items: [MenuItem] = []
        if !singleEnvironment {
            var all = MenuItem.radio("All environments", checked: scope.selection.machine == nil) { [weak context] _ in
                context?.selectScope?(SettingsScopeSelection(machine: nil, project: scope.selection.project))
            }
            all.icon = .layers
            all.closesOnClick = true
            items = [all, MenuItem("", kind: .separator)]
        }
        for e in scope.environments {
            var item = MenuItem.radio(scope.environmentLabel(e), checked: scope.selection.machine == e.id) { [weak context] _ in
                context?.selectScope?(SettingsScopeSelection(machine: e.id, project: scope.selection.project))
            }
            if singleEnvironment, scope.selection.machine == nil { item = MenuItem.radio(scope.environmentLabel(e), checked: impliedMachine == e.id) { [weak context] _ in
                context?.selectScope?(SettingsScopeSelection(machine: e.id, project: scope.selection.project))
            } }
            item.glyph = EnvironmentMachineIcon.definition(e.machine)
            item.shortcut = e.connected ? nil : "Offline"
            item.closesOnClick = true
            items.append(item)
        }
        MenuPopupView.show(items, from: environment, placement: PopupPlacement(side: .bottom, align: .start, sideOffset: 4, fallbackAxisSide: .none))
    }

    private func openProjects() {
        guard let context else { return }
        let scope = context.scope
        // `selectProjectAxis`: choosing a project keeps the environment axis.
        var items: [MenuItem] = [MenuItem.radio("All projects", checked: scope.selection.project == nil) { [weak context] _ in
            context?.selectScope?(SettingsScopeSelection(machine: scope.selection.machine, project: nil))
        }]
        items[0].closesOnClick = true
        items.append(MenuItem("", kind: .separator))
        for p in scope.projects {
            var item = MenuItem.radio(p.displayName, checked: scope.selection.project == p.key) { [weak context] _ in
                context?.selectScope?(SettingsScopeSelection(machine: scope.selection.machine, project: p.key))
            }
            if let icon = p.icon {
                item.leading = { ProjectMonogramView(icon, size: 14) } // `size-3.5` (SettingsScopeSentence.tsx:212)
                item.leadingSize = 14
            }
            item.closesOnClick = true
            items.append(item)
        }
        MenuPopupView.show(items, from: project, placement: PopupPlacement(side: .bottom, align: .start, sideOffset: 4, fallbackAxisSide: .none))
    }

    private var modern: Bool { !ThemeRuntime.isDither(dark: effectiveAppearance.isDark) }
    func height(forWidth width: CGFloat) -> CGFloat {
        guard modern else { return 24 }
        updateFonts()
        let first = ceil(lead.textWidth) + 1 + 6 + project.intrinsicContentSize.width
        let second = ceil(connective.textWidth) + 1 + 6 + environment.intrinsicContentSize.width
        return first + 6 + second > width - 32 ? 60 : 28
    }
    private func updateFonts() {
        for l in [lead, connective] { l.font = DSFont.ui(modern ? 14 : 16); l.lineHeight = modern ? 20 : 24 }
    }
    override func layout() {
        super.layout()
        updateFonts()
        if modern {
            var x: CGFloat = 16, y: CGFloat = 0
            for pair: (LabelView, InlinePickerButton) in [(lead, project), (connective, environment)] {
                let lw = ceil(pair.0.textWidth) + 1
                let width = min(pair.1.intrinsicContentSize.width, max(0, bounds.width - 32 - lw - 6))
                if x > 16, x + lw + 6 + width > bounds.width - 16 { x = 16; y += 32 }
                pair.0.frame = NSRect(x: x, y: y + 4, width: lw, height: 20)
                pair.1.frame = NSRect(x: x + lw + 6, y: y, width: width, height: 28)
                x += lw + 6 + width + 6
            }
            return
        }
        var x: CGFloat = 16
        func place(_ v: NSView, _ w: CGFloat) { v.frame = NSRect(x: x, y: 0, width: w, height: 24); x += w + 6 }
        place(lead, ceil(lead.textWidth) + 1)
        place(project, project.intrinsicContentSize.width)
        place(connective, ceil(connective.textWidth) + 1)
        place(environment, min(environment.intrinsicContentSize.width, max(0, bounds.width - x - 16)))
    }
}

/// `SettingsSection` with `hideTitle` or a custom header: the generic section is `SettingsSectionView`.
/// This one stacks any rows (theme tiles) under an optional 28pt title.
final class SettingsPlainSectionView: DSView, SettingsGroupRow {
    var body: [NSView & SettingsGroupRow] = [] { didSet { oldValue.forEach { $0.removeFromSuperview() }; body.forEach(addSubview); needsLayout = true } }
    var spacing: CGFloat = 12

    func height(forWidth width: CGFloat) -> CGFloat {
        body.filter { !$0.isHidden }.reduce(0) { $0 + $1.height(forWidth: width) } + spacing * CGFloat(max(0, body.filter { !$0.isHidden }.count - 1))
    }

    override func layout() {
        super.layout()
        var y: CGFloat = 0
        for v in body where !v.isHidden {
            let h = v.height(forWidth: bounds.width)
            v.frame = NSRect(x: 0, y: y, width: bounds.width, height: h)
            v.needsLayout = true
            y += h + spacing
        }
    }
}

/// A one-line muted heading inside a plain section (`h3 px-4 text-sm font-normal text-foreground/70`), with an
/// optional trailing view.
final class SettingsSubheadingView: DSView, SettingsGroupRow {
    private let label = LabelView("", font: DSFont.ui(14), color: Themed.color(\.foreground, 0.7))
    var trailing: NSView? { didSet { oldValue?.removeFromSuperview(); trailing.map(addSubview); needsLayout = true } }
    var minHeight: CGFloat = 20
    var topPadding: CGFloat = 0

    init(_ title: String) {
        super.init(frame: .zero)
        label.text = title
        label.lineHeight = 20
        addSubview(label)
    }

    func height(forWidth width: CGFloat) -> CGFloat { topPadding + (ThemeRuntime.isDither(dark: effectiveAppearance.isDark) ? minHeight : max(28, minHeight)) }

    override func layout() {
        super.layout()
        let modern = !ThemeRuntime.isDither(dark: effectiveAppearance.isDark)
        label.font = modern ? DSFont.ui(16, weight: .semibold) : DSFont.ui(14)
        label.color = Themed.color(\.foreground, modern ? 1 : 0.7)
        let h = bounds.height - topPadding
        label.frame = NSRect(x: 16, y: topPadding + (h - (modern ? 24 : 20)) / 2, width: ceil(label.textWidth) + 1, height: modern ? 24 : 20)
        if let trailing {
            let s = trailing.intrinsicContentSize
            trailing.frame = NSRect(x: bounds.width - 16 - s.width, y: topPadding + (h - s.height) / 2, width: s.width, height: s.height)
        }
    }
}

/// A plain text block as a page item (the scope boundary notice, `text-sm text-muted-foreground`).
final class SettingsNoticeView: DSView, SettingsGroupRow {
    private let text = TextBlockView()
    init(_ message: String, size: CGFloat = 14) {
        super.init(frame: .zero)
        text.text = message
        text.font = DSFont.ui(size)
        text.lineHeight = size == 14 ? 20 : 16
        text.color = Themed.color(\.mutedForeground)
        addSubview(text)
    }
    var message: String { get { text.text } set { text.text = newValue; needsLayout = true } }
    /// A button under the message (`flex flex-col items-start gap-3`), such as "Show all environments".
    var button: ButtonView? { didSet { oldValue?.removeFromSuperview(); button.map(addSubview); needsLayout = true } }
    func height(forWidth width: CGFloat) -> CGFloat {
        text.height(forWidth: width) + (button.map { $0.isHidden ? 0 : 12 + $0.intrinsicContentSize.height } ?? 0)
    }
    override func layout() {
        super.layout()
        let h = text.height(forWidth: bounds.width)
        text.frame = NSRect(x: 0, y: 0, width: bounds.width, height: button == nil ? bounds.height : h)
        if let button { button.frame = NSRect(origin: NSPoint(x: 0, y: h + 12), size: button.intrinsicContentSize) }
    }
}

/// The settings select (`SelectTrigger size="sm"`, `SelectPopup align="end" alignItemWithTrigger={false}`).
@MainActor
func settingsSelect(_ labels: [String], width: CGFloat?, hideIndicator: Bool = true) -> SelectView {
    let select = SelectView(options: labels, size: .sm)
    select.alignItemWithTrigger = false
    select.popupAlign = .end
    select.hidesIndicator = hideIndicator
    select.ditherSettings = true
    if let width { select.frame.size = NSSize(width: width, height: 28) } else { select.fitsContent = true }
    return select
}

/// The `output` pill and range input of the Contrast, Glass opacity and Panel animations rows
/// (`flex w-52 items-center gap-3`; output `min-w-12 rounded-md bg-muted px-2 py-1 font-mono text-xs`).
final class SettingsSliderControl: DSView {
    let output = LabelView("", font: DSFont.mono(12, weight: .medium), color: Themed.color(\.foreground))
    let slider: SliderView
    private let pill = CALayer()
    private let outputWidth: CGFloat
    /// The row may stretch the control on a narrow page; its own size stays this, so a wider page gets the label room back.
    private let preferredWidth: CGFloat
    var format: (Double) -> String = { "\(Int($0))%" } { didSet { sync() } }
    var onChange: ((Double) -> Void)?

    init(value: Double, range: ClosedRange<Double>, step: Double, width: CGFloat = 208, outputWidth: CGFloat = 48) {
        slider = SliderView(value: value, range: range, step: step)
        self.outputWidth = outputWidth
        preferredWidth = width
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 24))
        pill.cornerRadius = 6
        pill.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(pill)
        output.alignment = .center
        output.lineHeight = 16
        addSubview(output)
        addSubview(slider)
        slider.onChange = { [weak self] v in self?.sync(); self?.onChange?(v) }
        sync()
    }

    var value: Double { get { slider.value } set { slider.value = newValue; sync() } }
    private func sync() { output.text = format(slider.value) }

    override var intrinsicContentSize: NSSize { NSSize(width: preferredWidth, height: 24) }
    override func updateLayer() { pill.backgroundColor = Themed.color(\.muted).cgColor(in: self) }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        pill.frame = CGRect(x: 0, y: 0, width: outputWidth, height: 24)
        CATransaction.commit()
        output.frame = NSRect(x: 0, y: 4, width: outputWidth, height: 16)
        slider.frame = NSRect(x: outputWidth + 12, y: 0, width: max(0, bounds.width - outputWidth - 12), height: 24)
    }
}

/// A row's controls side by side (`flex items-center gap-2` or `gap-1.5`), sized to fit.
final class SettingsControlGroup: DSView {
    var views: [NSView] { didSet { oldValue.forEach { $0.removeFromSuperview() }; views.forEach(addSubview); invalidateIntrinsicContentSize(); needsLayout = true } }
    var gap: CGFloat

    init(_ views: [NSView], gap: CGFloat = 8) {
        self.views = views
        self.gap = gap
        super.init(frame: .zero)
        views.forEach(addSubview)
    }

    private func size(_ v: NSView) -> NSSize {
        let s = v.intrinsicContentSize
        return NSSize(width: s.width == NSView.noIntrinsicMetric ? v.frame.width : s.width, height: s.height == NSView.noIntrinsicMetric ? v.frame.height : s.height)
    }

    override var intrinsicContentSize: NSSize {
        let shown = views.filter { !$0.isHidden }
        let w = shown.reduce(0) { $0 + size($1).width } + gap * CGFloat(max(0, shown.count - 1))
        return NSSize(width: w, height: shown.map { size($0).height }.max() ?? 28)
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        for v in views where !v.isHidden {
            let s = size(v)
            v.frame = NSRect(x: x, y: ((bounds.height - s.height) / 2).rounded(), width: s.width, height: s.height)
            x += s.width + gap
        }
    }
}

/// The settings-search pulse (index.css `settings-search-target-pulse`): a 2px `primary/70` ring that fades
/// in and out twice over 650ms each, on a 12pt radius.
@MainActor
func pulseSettingsTarget(_ view: NSView) {
    guard let layer = view.layer else { return }
    let ring = CALayer()
    ring.frame = layer.bounds.insetBy(dx: -2, dy: -2)
    ring.cornerRadius = 14
    ring.borderWidth = 2
    ring.borderColor = Themed.color(\.primary, 0.7).cgColor(in: view)
    ring.opacity = 0
    layer.addSublayer(ring)
    let a = CAKeyframeAnimation(keyPath: "opacity")
    a.values = [0, 1, 0]
    a.keyTimes = [0, 0.5, 1]
    a.duration = 0.65
    a.repeatCount = 2
    a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    CATransaction.begin()
    CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
    ring.add(a, forKey: "pulse")
    CATransaction.commit()
}
