import AppKit

/// T3's `Combobox` and `Autocomplete` (`combobox.tsx`, `autocomplete.tsx`): an Input that filters a
/// popup list as the user types. Focus stays in the input; the popup host routes arrows, Enter and
/// Escape to the list. Desktop values. Spec: docs/research/recovered/ui-components-a.md 10 and 11.
public final class ComboboxView: DSView {
    public enum Kind: Sendable { case combobox, autocomplete }

    public let kind: Kind
    public var options: [String] {
        didSet {
            selectedIndex = options.firstIndex(of: input.text)
            if let popup = list?.hostPopup, popupHost?.popups.contains(where: { $0 === popup }) == true {
                showList(filter: filtersList)
            }
        }
    }
    public private(set) var selectedIndex: Int?
    public let input: InputView
    public final var onChange: (@MainActor (Int) -> Void)?

    private var trigger: ComboboxTriggerView?
    private var settingText = false
    private weak var list: MenuPopupView?
    private var shown: [Int] = []
    private var filtersList = false

    /// `showTrigger` defaults to true for Combobox and false for Autocomplete.
    public init(_ kind: Kind = .combobox, options: [String], placeholder: String = "", showTrigger: Bool? = nil) {
        self.kind = kind
        self.options = options
        input = InputView(placeholder: placeholder)
        super.init(frame: .zero)
        addSubview(input)
        if showTrigger ?? (kind == .combobox) {
            let t = ComboboxTriggerView()
            t.action = { [weak self] in self?.toggle() }
            addSubview(t)
            trigger = t
            input.paddingOverride = (nil, 28) // `pe-7`
        }
        input.onChange = { [weak self] _ in
            guard let self, !self.settingText else { return }
            self.showList(filter: true)
        }
    }

    public override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: input.intrinsicContentSize.height) }

    public override func layout() {
        super.layout()
        input.frame = bounds
        trigger?.frame = NSRect(x: bounds.width - 2 - 28, y: (bounds.height - 28) / 2, width: 28, height: 28)
    }

    /// Apply an external value without opening the list as if the user had typed.
    public func setValue(_ text: String) {
        settingText = true
        input.text = text
        selectedIndex = options.firstIndex(of: text)
        settingText = false
    }

    /// Items matching the input text: case-insensitive substring, base-ui's default `contains` filter.
    static func filter(_ options: [String], _ query: String) -> [Int] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return options.indices.filter { q.isEmpty || options[$0].range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    private func toggle() {
        if let list, let popup = list.hostPopup { popupHost?.close(popup, returnFocus: false); return }
        window?.makeFirstResponder(input)
        showList(filter: false)
    }

    func showList(filter: Bool) {
        guard let host = popupHost else { return }
        filtersList = filter
        shown = filter ? Self.filter(options, input.text) : Array(options.indices)
        let items = shown.map { MenuItem(options[$0], kind: .radio($0 == selectedIndex)) }
        if let list, list.hostPopup.map({ p in host.popups.contains { $0 === p } }) == true {
            list.setItems(items)
            if let p = list.hostPopup { host.reposition(p) }
        } else {
            let view = MenuPopupView(items: items, style: kind == .combobox ? .combobox : .autocomplete)
            view.minimumWidth = bounds.width
            view.maximumHeight = 368 // `max-h-[min(var(--available-height),23rem)]`
            view.emptyText = "No results."
            view.onChoose = { [weak self] i in self?.choose(i) }
            // Combobox triggers get no `data-pressed`; focus never leaves the input.
            let popup = host.open(view, trigger: self, placement: .dropdown, pressesTrigger: false, returnsFocus: false)
            popup.keepsOpenOnTriggerPress = true
            view.hostPopup = popup
            list = view
        }
        // Autocomplete highlights the first match while typing (autoHighlight in T3's command palette).
        list?.highlightedIndex = filter && !shown.isEmpty ? 0 : shown.firstIndex(of: selectedIndex ?? -1)
    }

    private func choose(_ row: Int) {
        guard row < shown.count else { return }
        let index = shown[row]
        selectedIndex = index
        settingText = true
        input.text = options[index]
        settingText = false
        onChange?(index)
    }
}

/// The 28px chevrons button at the end of a Combobox input (`combobox.tsx:86`).
final class ComboboxTriggerView: ControlView {
    private let icon = IconView(name: .chevronsUpDown)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scalesWhenPressed = false
        addSubview(icon)
        restyle()
    }

    override var acceptsFirstResponder: Bool { false }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: (bounds.width - 16) / 2, y: (bounds.height - 16) / 2, width: 16, height: 16)
    }

    override func stateDidChange(from old: State) {
        super.stateDidChange(from: old)
        restyle()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    private func restyle() {
        icon.strokeColor = Themed.color(\.contrastForeground)
        HoverReveal.fade(self, to: state.hovered ? 1 : 0.8) // `opacity-80 transition-opacity hover:opacity-100`
    }
}
