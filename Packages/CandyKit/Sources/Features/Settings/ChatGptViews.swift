import AppKit
import DesignSystem
import T3Protocol

/// T3's two ChatGPT buttons.
@MainActor
public enum ChatGptButtons {
    /// ChatGptConnectionButton.tsx: the OpenAI mark (`size-4`) before the label.
    public static func connection(_ title: String = "Continue with ChatGPT", variant: ButtonView.Variant = .default,
                                  size: ButtonView.Size = .default) -> ButtonView {
        let b = ButtonView(title, icon: .brandOpenAI, variant: variant, size: size)
        b.iconSize = 16
        return b
    }

    /// ChatGptUsageButton.tsx: "Manage usage" and the external link mark (`size-3.5`), opening ChatGPT's usage page.
    public static func usage(variant: ButtonView.Variant = .ghostMuted, size: ButtonView.Size = .sm,
                             open: @escaping @MainActor (URL) -> Void) -> ButtonView {
        let b = ButtonView("Manage usage", variant: variant, size: size)
        b.trailingIcon = .externalLink
        b.iconSize = 14
        b.action = { if let url = URL(string: CodexSetupLogic.usageURL) { open(url) } }
        return b
    }
}

/// ChatGptAccountPicker.tsx: "Reconnect ChatGPT", one bordered radio row per saved profile and
/// "Use a different account", then Continue with ChatGPT.
public final class ChatGptAccountPickerDialog: DialogView {
    public var onSelect: ((String) -> Void)?
    private let profiles: [(id: String, name: String)]
    private var selection: String?
    private let list = ChoiceList()

    public init(methods: [JSONValue]) {
        profiles = CodexSetupLogic.pickerProfiles(methods)
        super.init(title: "Reconnect ChatGPT", message: "On OpenAI, sign in with the account you choose here.")
        list.setAccessibilityLabel("ChatGPT account to connect")
        list.rows = profiles.map { ChoiceRow(id: $0.id, title: $0.name) } + [ChoiceRow(id: CodexSetupLogic.changeAccountMethod, title: "Use a different account")]
        for row in list.rows { row.action = { [weak self, weak row] in guard let self, let row else { return }; self.selection = row.id; self.sync() } }
        panelContent = [list]
        let go = ChatGptButtons.connection()
        go.action = { [weak self] in guard let self else { return }; self.onSelect?(self.selected) }
        footerButtons = [go]
        sync()
    }

    var selected: String { CodexSetupLogic.pickerSelection(selection, profiles: profiles) }
    private func sync() { for row in list.rows { row.radio.isChecked = row.id == selected } }

    /// `RadioGroup` (`flex flex-col gap-3`) in `px-6 pb-6`: the header keeps its 24pt bottom padding,
    /// so the list starts 8pt below where a `DialogPanel` would.
    final class ChoiceList: DSView {
        var rows: [ChoiceRow] = [] { didSet { oldValue.forEach { $0.removeFromSuperview() }; rows.forEach(addSubview); invalidateIntrinsicContentSize() } }
        override init(frame frameRect: NSRect) { super.init(frame: frameRect); setAccessibilityRole(.radioGroup) }
        func height(forWidth w: CGFloat) -> CGFloat { 8 + rows.reduce(0) { $0 + $1.height(forWidth: w) } + 12 * CGFloat(max(0, rows.count - 1)) }
        override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: max(1, bounds.width))) }
        override func layout() {
            super.layout()
            var y: CGFloat = 8
            for r in rows { let h = r.height(forWidth: bounds.width); r.frame = NSRect(x: 0, y: y, width: bounds.width, height: h); y += h + 12 }
        }
    }

    /// `<label class="flex cursor-pointer items-center gap-3 rounded-lg border px-3 py-3 text-sm">`.
    final class ChoiceRow: ControlView {
        let id: String
        let radio = RadioView()
        private let text = TextBlockView()
        private let box = BoxDecorationLayer()
        init(id: String, title: String) {
            self.id = id
            super.init(frame: .zero)
            scalesWhenPressed = false
            box.host = self
            var s = BoxStyle()
            s.radius = 8
            s.border = Themed.color(\.border)
            box.boxStyle = s
            layer?.addSublayer(box)
            text.text = title
            text.font = DSFont.ui(14, weight: .medium)
            text.lineHeight = 20
            text.color = Themed.color(\.foreground)
            radio.action = { [weak self] in self?.performAction() }
            addSubview(radio)
            addSubview(text)
            setAccessibilityRole(.radioButton)
            setAccessibilityLabel(title)
        }
        func height(forWidth w: CGFloat) -> CGFloat { 2 + 24 + text.height(forWidth: max(1, w - 2 - 24 - 16 - 12)) }
        override func layout() {
            super.layout()
            box.layout(boxSize: bounds.size)
            let th = text.height(forWidth: max(1, bounds.width - 54))
            radio.frame = NSRect(x: 13, y: (bounds.height - 16) / 2, width: 16, height: 16)
            text.frame = NSRect(x: 41, y: (bounds.height - th) / 2, width: max(1, bounds.width - 54), height: th)
        }
    }
}

/// ChatGptWelcomeCoordinator.tsx:57-81: shown once per connected profile that uses ChatGPT sharing.
public final class ChatGptWelcomeDialog: DialogView {
    public var onContinue: (() -> Void)?
    public init(profile: CodexSetupLogic.WelcomeProfile, openURL: @escaping @MainActor (URL) -> Void) {
        super.init(title: "Your ChatGPT plan is connected",
                   message: "Eligible usage in T3 Code uses your ChatGPT plan. Manage your shared usage and any credit settings in ChatGPT.")
        // `OpenAI className="mb-2 size-8"` above the title.
        let mark = DSView(frame: NSRect(x: 0, y: 0, width: 32, height: 40))
        let icon = IconView(name: .brandOpenAI, size: 32, strokeColor: Themed.color(\.foreground))
        mark.addSubview(icon)
        headerAccessory = FixedSizeView(mark, size: NSSize(width: 32, height: 40))
        // `<p className="text-xs text-muted-foreground">`.
        let line = TextBlockView("\(profile.providerName) on \(profile.environmentLabel)", font: DSFont.ui(12), lineHeight: 16,
                                 color: Themed.color(\.mutedForeground))
        line.frame.size.height = 16
        headerContent = FixedSizeView(line, size: NSSize(width: NSView.noIntrinsicMetric, height: 16))
        let ok = ButtonView("Continue")
        ok.action = { [weak self] in self?.onContinue?() }
        footerButtons = [ChatGptButtons.usage(open: openURL), ok]
    }

    /// A view with a fixed intrinsic size for the dialog's header slots.
    final class FixedSizeView: DSView {
        private let size: NSSize
        private let child: NSView
        init(_ child: NSView, size: NSSize) {
            self.child = child; self.size = size
            super.init(frame: NSRect(origin: .zero, size: NSSize(width: max(0, size.width), height: size.height)))
            addSubview(child)
        }
        override var intrinsicContentSize: NSSize { size }
        override func layout() { super.layout(); child.frame = NSRect(x: 0, y: 0, width: bounds.width, height: child.frame.height) }
    }
}

/// ChatGptSharingControl.tsx: the model picker's footer while the active instance uses a ChatGPT plan.
final class ChatGptSharingControlView: DSView {
    static let height: CGFloat = 41
    private let icon = IconView(name: .brandOpenAI, size: 14, strokeColor: Themed.color(\.mutedForeground))
    private let label = LabelView("Using ChatGPT plan", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    private let button: ButtonView
    private let rule = CALayer()
    init(openURL: @escaping @MainActor (URL) -> Void) {
        button = ChatGptButtons.usage(size: .xs, open: openURL)
        super.init(frame: .zero)
        label.lineHeight = 16
        rule.actions = ["position": NSNull(), "bounds": NSNull(), "backgroundColor": NSNull()]
        layer?.addSublayer(rule)
        for v in [icon, label, button] as [NSView] { addSubview(v) }
    }
    override func updateLayer() { super.updateLayer(); rule.backgroundColor = Themed.color(\.border).cgColor(in: self) }
    override func layout() {
        super.layout()
        rule.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 1)
        let mid = 1 + (bounds.height - 1) / 2
        icon.frame = NSRect(x: 12, y: mid - 7, width: 14, height: 14)
        label.frame = NSRect(x: 34, y: mid - 8, width: ceil(label.textWidth) + 1, height: 16)
        let bw = button.intrinsicContentSize.width
        button.frame = NSRect(x: bounds.width - 12 - bw, y: mid - 12, width: bw, height: 24)
    }
}

/// `FoldedSettingsSection headerPlacement="outside"` (FoldedSettingsSection.tsx:39-68): a `min-h-7` header
/// with the title and a chevron that turns 90 degrees, then the card 10pt below while open. Closed by default.
public final class FoldedSettingsSectionView: DSView, SettingsGroupRow {
    public let group: SettingsGroupView
    private let trigger = Trigger()
    public var onHeightChange: (() -> Void)?
    public private(set) var isOpen = false

    public init(title: String, rows: [any SettingsGroupRow]) {
        group = SettingsGroupView(rows: rows)
        super.init(frame: .zero)
        trigger.title.text = title
        trigger.setAccessibilityLabel(title)
        trigger.action = { [weak self] in self?.toggle() }
        group.isHidden = true
        addSubview(trigger)
        addSubview(group)
    }

    public func toggle() {
        CollapseMotion.run(in: self) {
            isOpen.toggle()
            trigger.isOpen = isOpen
            group.isHidden = !isOpen
            invalidateIntrinsicContentSize()
            needsLayout = true
            onHeightChange?()
        }
    }

    public func height(forWidth width: CGFloat) -> CGFloat { 28 + (isOpen ? 10 + group.height(forWidth: width) : 0) }
    public override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: max(1, bounds.width))) }
    public override func layout() {
        super.layout()
        trigger.frame = NSRect(x: 16, y: 0, width: trigger.width, height: 28)
        group.frame = NSRect(x: 0, y: 38, width: bounds.width, height: isOpen ? group.height(forWidth: bounds.width) : 0)
    }

    /// `CollapsibleTrigger className="flex min-h-7 items-center gap-2 text-sm font-normal text-foreground/70"`.
    final class Trigger: ControlView {
        let title = LabelView("", font: DSFont.ui(14), color: Themed.color(\.foreground, 0.7))
        private let chevron = IconView(name: .chevronRight, size: 16, strokeColor: Themed.color(\.foreground, 0.7))
        var isOpen = false { didSet { chevron.setRotation(isOpen ? 90 : 0); setAccessibilityExpanded(isOpen) } }
        var width: CGFloat { ceil(title.textWidth) + 1 + 8 + 16 }
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            scalesWhenPressed = false
            title.lineHeight = 20
            addSubview(title)
            addSubview(chevron)
            setAccessibilityRole(.button)
        }
        override func layout() {
            super.layout()
            let tw = ceil(title.textWidth) + 1
            title.frame = NSRect(x: 0, y: (bounds.height - 20) / 2, width: tw, height: 20)
            chevron.frame = NSRect(x: tw + 8, y: (bounds.height - 16) / 2, width: 16, height: 16)
        }
    }
}

/// `CodexManagedRuntimeFields` (CodexSetupSection.tsx:1014-1085): the server picks a managed instance's
/// executable, so the three paths are read-only. They go straight into the Runtime card as its rows.
@MainActor
public final class CodexManagedRuntimeFields {
    public let rows: [SettingsRowView]
    private let binary: BinaryPathField
    private let home = InputView()
    private let shadow = InputView()
    private let shadowRow: SettingsRowView

    public init(context: SettingsPageContext, environment: String, instance: String, provider: ServerProvider?) {
        binary = BinaryPathField(context: context, environment: environment, instance: instance)
        for (input, label) in [(home, "Codex home path"), (shadow, "Codex shadow home path")] {
            input.isEnabled = false
            input.setAccessibilityLabel(label)
            input.frame.size = NSSize(width: 320, height: 32)
        }
        shadowRow = SettingsRowView(title: "Shadow home path", control: shadow)
        rows = [SettingsRowView(title: "Binary path", detail: "Selected by T3 Code.", control: binary),
                SettingsRowView(title: "CODEX_HOME path", detail: "Shared Codex config, sessions, and state.", control: home),
                shadowRow]
        update(provider: provider)
    }

    public func update(provider: ServerProvider?) {
        let paths = provider?.runtimePaths
        home.text = paths?["homePath"]?.stringValue ?? ""
        home.placeholder = "Unavailable"
        home.toolTip = paths?["homePath"]?.stringValue
        let shadowPath = paths?["shadowHomePath"]?.stringValue
        shadow.text = shadowPath ?? ""
        shadow.placeholder = paths != nil ? "Not used" : "Unavailable"
        shadow.toolTip = shadowPath
        shadowRow.detail = shadowPath != nil ? "Account-specific home sharing the Codex state above." : "This instance uses the shared Codex home directly."
    }

    /// The binary path from `provider.install.subscribe`, read only while the field shows: a closed fold
    /// unmounts T3's panel, so nothing listens then.
    final class BinaryPathField: DSView {
        private let context: SettingsPageContext
        private let environment: String, instance: String
        let input = InputView(placeholder: "Not installed")
        private var subscription: Task<Void, Never>?
        init(context: SettingsPageContext, environment: String, instance: String) {
            self.context = context; self.environment = environment; self.instance = instance
            super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 32))
            input.isEnabled = false
            input.setAccessibilityLabel("Codex binary path")
            addSubview(input)
        }
        deinit { subscription?.cancel() }
        override var intrinsicContentSize: NSSize { NSSize(width: 320, height: 32) }
        override func layout() { super.layout(); input.frame = bounds }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); sync() }
        override func viewDidHide() { super.viewDidHide(); sync() }
        override func viewDidUnhide() { super.viewDidUnhide(); sync() }
        private func sync() {
            if window == nil || isHiddenOrHasHiddenAncestor { subscription?.cancel(); subscription = nil; return }
            guard subscription == nil else { return }
            subscription = context.subscribe?(environment, "provider.install.subscribe", .object(["instanceId": .string(instance)])) { [weak self] state in
                let path = state["executablePath"]?.stringValue ?? ""
                self?.input.text = path
                self?.input.toolTip = path.isEmpty ? nil : path
            }
        }
    }
}

