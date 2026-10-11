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

    public var setupSnapShot: (() -> Void)?
    public var snapShotReady: (() -> Bool)?
    public var writeClient: (([String: JSONValue]) -> Void)?
    /// Saves a notification mode after asking for notification permission when it needs it; returns the
    /// row's message when the mode can't be used (the app's `ThreadNotificationCoordinator.choose`).
    public var chooseNotificationMode: ((ThreadNotificationMode) async -> String?)?
    /// A server patch for the scope's targets (`planScopedSettingsPatch`).
    public var writeServer: (([String: JSONValue]) -> Void)?
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
    /// The model picker's favorites (client setting `favorites`) and their toggle.
    public var favorites: [ModelFavorite] = []
    public var toggleFavorite: ((ProviderInstanceId, String) -> Void)?
    /// Opens another settings page.
    public var openSection: ((SettingsSection) -> Void)?
    /// Leaves Settings for the thread view (after removing the open project).
    public var closeSettings: (() -> Void)?
    /// Copies text and shows a toast with the title.
    public var copy: ((String, String) -> Void)?
    /// `projects.mutate project.update` on every member, stopping at the first failure (`updateAllMembers`).
    public var updateProject: ((_ members: [SettingsScopeProject.Member], _ fields: [String: JSONValue], _ failureTitle: String) -> Void)?
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

    public init() {}

    private var observers: [() -> Void] = []
    /// Calls `block` after every `didChange` (dialogs that outlive a page refresh).
    func observe(_ block: @escaping () -> Void) { observers.append(block) }
    /// The app calls this after it changed the context.
    public func didChange() { observers.forEach { $0() } }

    func patchClient(_ key: String, _ value: JSONValue) { writeClient?([key: value]) }
    func patchServer(_ patch: [String: JSONValue]) { writeServer?(patch) }
}

/// Re-reads every control from the context after a change. Rows register a closure each.
@MainActor
final class SettingsBinder {
    private var updaters: [() -> Void] = []
    func add(_ update: @escaping () -> Void) { updaters.append(update); update() }
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

    public func height(forWidth width: CGFloat) -> CGFloat {
        let visible = items.filter { !$0.isHidden }
        return visible.reduce(0) { $0 + $1.height(forWidth: width) } + gap * CGFloat(max(0, visible.count - 1))
    }

    public override func layout() {
        super.layout()
        var y: CGFloat = 0
        for item in items where !item.isHidden {
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
final class InheritanceButton: DSView {
    let button = ButtonView(nil, icon: .layers, variant: .ghostMuted, size: .iconMicro)
    private var tooltip: TooltipController?
    var onOpen: ((NSView) -> Void)?
    var state: SettingInheritanceState = .default { didSet { restyle() } }
    var summary = "" { didSet { tooltip?.text = summary; button.setAccessibilityLabel("\(summary). Show where this value comes from") } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        button.iconSize = 12
        tooltip = TooltipController.attach(to: button, text: "")
        button.action = { [weak self] in guard let self else { return }; self.tooltip?.hide(); self.onOpen?(self.button) }
        addSubview(button)
        restyle()
    }

    private func restyle() {
        button.iconColor = state == .overridden ? Themed.color(\.primary) : state == .mixed ? Themed.color(\.warning) : nil
    }

    override func layout() { super.layout(); button.frame = bounds }
}

/// T3's `InlineButton tone="picker"`: an optional glyph, the 16px medium value with a dotted underline,
/// and a chevron. Opens a menu from inside the scope sentence.
final class InlinePickerButton: ControlView {
    private let label = LabelView("", font: DSFont.ui(16, weight: .medium), color: Themed.color(\.foreground))
    private let chevron = IconView(name: .chevronDown, size: 14)
    private let underline = CAShapeLayer()
    var glyph: NSView? { didSet { oldValue?.removeFromSuperview(); glyph.map(addSubview); invalidateIntrinsicContentSize(); needsLayout = true } }
    var title = "" { didSet { label.text = title; invalidateIntrinsicContentSize(); needsLayout = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scalesWhenPressed = false
        label.lineHeight = 24
        addSubview(label)
        addSubview(chevron)
        underline.fillColor = nil
        underline.lineWidth = 1
        underline.lineDashPattern = [1, 2]
        underline.actions = ["path": NSNull(), "strokeColor": NSNull(), "lineDashPattern": NSNull()]
        layer?.addSublayer(underline)
        setAccessibilityRole(.popUpButton)
        restyle()
    }

    override var intrinsicContentSize: NSSize {
        let g: CGFloat = glyph == nil ? 0 : 14 + 6
        return NSSize(width: min(288, ceil(g + label.textWidth + 6 + 14)), height: 24)
    }

    override func stateDidChange(from old: State) { super.stateDidChange(from: old); restyle() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); restyle() }

    private func restyle() {
        let solid = state.hoverOrPressed || state.popupOpen
        underline.strokeColor = Themed.color(\.foreground, solid ? 1 : 0.3).cgColor(in: self)
        underline.lineDashPattern = solid ? nil : [1, 2]
        chevron.strokeColor = Themed.color(\.mutedForeground)
    }

    override func layout() {
        super.layout()
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
        project.title = scope.selection.project.map { key in scope.projects.first { $0.key == key }?.displayName ?? "Unavailable project" } ?? "All projects"
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
        // ponytail: rows show names without the project favicon; add the icon if the menu learns custom glyph views
        for p in scope.projects {
            var item = MenuItem.radio(p.displayName, checked: scope.selection.project == p.key) { [weak context] _ in
                context?.selectScope?(SettingsScopeSelection(machine: scope.selection.machine, project: p.key))
            }
            item.closesOnClick = true
            items.append(item)
        }
        MenuPopupView.show(items, from: project, placement: PopupPlacement(side: .bottom, align: .start, sideOffset: 4, fallbackAxisSide: .none))
    }

    func height(forWidth width: CGFloat) -> CGFloat { 24 }

    override func layout() {
        super.layout()
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

    func height(forWidth width: CGFloat) -> CGFloat { topPadding + minHeight }

    override func layout() {
        super.layout()
        let h = bounds.height - topPadding
        label.frame = NSRect(x: 16, y: topPadding + (h - 20) / 2, width: ceil(label.textWidth) + 1, height: 20)
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
    func height(forWidth width: CGFloat) -> CGFloat { text.height(forWidth: width) }
    override func layout() { super.layout(); text.frame = bounds }
}

/// The settings select (`SelectTrigger size="sm"`, `SelectPopup align="end" alignItemWithTrigger={false}`).
@MainActor
func settingsSelect(_ labels: [String], width: CGFloat?, hideIndicator: Bool = true) -> SelectView {
    let select = SelectView(options: labels, size: .sm)
    select.alignItemWithTrigger = false
    select.popupAlign = .end
    select.hidesIndicator = hideIndicator
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
    var format: (Double) -> String = { "\(Int($0))%" } { didSet { sync() } }
    var onChange: ((Double) -> Void)?

    init(value: Double, range: ClosedRange<Double>, step: Double, width: CGFloat = 208, outputWidth: CGFloat = 48) {
        slider = SliderView(value: value, range: range, step: step)
        self.outputWidth = outputWidth
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

    override var intrinsicContentSize: NSSize { NSSize(width: frame.width, height: 24) }
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
