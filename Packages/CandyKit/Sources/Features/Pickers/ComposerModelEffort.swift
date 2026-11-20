import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// Nightly 4928 picks the model and its effort from one control (#28057). The trigger names the model and its effort
/// (`describeComposerEffort`, ComposerModelEffort.tsx:86-185); the picker docks an effort column beside the model list
/// (`ComposerEffortColumn`, :525-562) and a footer under both with speed, Ultracode and Permissions (:709-726).

/// `splitSpeed` and `columnControls` (ComposerModelEffort.tsx:42-79): service tiers, Fast mode and Ultracode go to the
/// footer; the column lists the reasoning levels, then every other option as one row each.
struct ComposerEffortControls {
    /// `REASONING_DESCRIPTOR_IDS` (client-runtime modelTraits.ts:12-15).
    // ponytail: no `role: "reasoning"` on descriptors yet; add it to `isReasoning` once T3Protocol decodes it
    static let reasoningIds: Set<String> = ["reasoningEffort", "reasoning", "effort", "variant", "reasoning_effort", "thinking"]

    var speedSelect: ProviderOptionDescriptor?
    var fastToggle: ProviderOptionDescriptor?
    var ultracodeToggle: ProviderOptionDescriptor?
    var effort: ProviderOptionDescriptor?
    var others: [ProviderOptionDescriptor]

    init(_ descriptors: [ProviderOptionDescriptor]) {
        let selects = descriptors.filter { $0.type == .select }, toggles = descriptors.filter { $0.type == .boolean }
        speedSelect = selects.first { $0.id == "serviceTier" }
        fastToggle = toggles.first { $0.id == "fastMode" }
        ultracodeToggle = toggles.first { $0.id == "ultracode" }
        let column = selects.filter { $0.id != "serviceTier" } + toggles.filter { $0.id != "fastMode" && $0.id != "ultracode" }
        let effort = column.first { Self.reasoningIds.contains($0.id) }
        self.effort = effort
        others = column.filter { $0.id != effort?.id }
    }

    /// `selectableProviderOptionChoices` (modelTraits.ts:64-70): prompt-injected levels such as Ultrathink leave the
    /// picker (#28044); the prompt still selects them.
    static func choices(_ d: ProviderOptionDescriptor) -> [ProviderOptionChoice] {
        d.options.filter { d.promptInjectedValues?.contains($0.id) != true }
    }

    /// "Fast" or "Ultrafast" while a speed option is on (`buildTraitsTriggerDisplay`, modelTraits.ts:131-162).
    var speed: String? {
        if fastToggle?.currentValue?.bool == true { return "Fast" }
        guard let tier = speedSelect, let value = ModelTraits.currentValue(tier)?.string else { return nil }
        let label = tier.options.first { $0.id == value }?.label
        return label == "Fast" || label == "Ultrafast" ? label : nil
    }
}

/// What the model trigger shows after the model name (`describeComposerEffort`, ComposerModelEffort.tsx:86-185): the
/// effort word or bars per the Appearance setting, a bolt for Fast, a workflow icon for Ultracode, and the context window.
struct ComposerModelSuffix: Equatable {
    var word: String?
    var glyph: ComposerEffort?
    var speed: String?
    var ultracode = false
    var contextWindow: String?
    var isEmpty: Bool { word == nil && glyph == nil && speed == nil && !ultracode && contextWindow == nil }

    init(_ descriptors: [ProviderOptionDescriptor], ultrathink: Bool, bars: Bool) {
        let controls = ComposerEffortControls(descriptors)
        let primary = descriptors.first { $0.type == .select }
        let reasoning = controls.effort
        let ultrathink = ultrathink && reasoning != nil && reasoning?.id == primary?.id
        if let reasoning, reasoning.type == .select {
            glyph = ComposerEffort.resolve(reasoning, current: ultrathink ? "ultrathink" : ModelTraits.currentValue(reasoning)?.string)
        }
        if let glyph {
            // Workflow levels such as Ultracode always show their name; the setting names every level.
            word = glyph.special || !bars ? glyph.label : nil
            if word != nil { self.glyph = nil }
        } else if let reasoning {
            word = reasoning.type == .boolean ? "\(reasoning.label) \(reasoning.currentValue?.bool == true ? "On" : "Off")"
                : ultrathink ? "Ultrathink" : ModelTraits.currentLabel(reasoning) ?? (reasoning.id == "thinking" ? reasoning.label : nil)
        }
        speed = controls.speed
        ultracode = controls.ultracodeToggle?.currentValue?.bool == true
        contextWindow = descriptors.first { $0.type == .select && $0.id == "contextWindow" }.flatMap(ModelTraits.currentLabel)
    }
}

/// A trailing view inside `ComposerControlView` that follows the trigger's state.
@MainActor protocol ComposerControlAdornment: NSView {
    /// The gap before it: `gap-1.5`, or 4 for the model suffix's `-ms-0.5`.
    var leadingGap: CGFloat { get }
    var showsLabels: Bool { get set }
    func width(showingLabel: Bool) -> CGFloat
    func restyle(hovered: Bool, labelColor: NSColor, font: NSFont)
}

extension ComposerTraitsAdornmentView: ComposerControlAdornment {
    var leadingGap: CGFloat { ComposerControlView.gap }
    func restyle(hovered: Bool, labelColor: NSColor, font: NSFont) { color = labelColor }
}

/// The suffix span (ComposerModelEffort.tsx:153-182): `gap-1.5`, `-ms-0.5`, muted until the trigger is hovered or open.
final class ComposerModelSuffixView: DSView, ComposerControlAdornment {
    let suffix: ComposerModelSuffix
    private let word: LabelView?
    private let glyph: ComposerEffortGlyphView?
    private let bolt: ComposerFastGlyphView?
    private let workflow: IconView?
    private let context: LabelView?
    var showsLabels = true { didSet { word?.isHidden = !showsLabels; context?.isHidden = !showsLabels; needsLayout = true } }
    let leadingGap: CGFloat = 4

    init(_ suffix: ComposerModelSuffix) {
        self.suffix = suffix
        word = suffix.word.map { LabelView($0, font: DSFont.ui(14, weight: .medium)) }
        glyph = suffix.word == nil ? suffix.glyph.map(ComposerEffortGlyphView.init) : nil
        bolt = suffix.speed.map { ComposerFastGlyphView(ultra: $0 == "Ultrafast") }
        workflow = suffix.ultracode ? IconView(name: .workflow, size: 12) : nil
        context = suffix.contextWindow.map { LabelView($0, font: DSFont.ui(12, weight: .medium)) }
        super.init(frame: .zero)
        for label in [word, context].compactMap({ $0 }) { label.smoothsFont = false; addSubview(label) }
        word?.lineHeight = 20; context?.lineHeight = 16
        for view in [glyph, bolt, workflow].compactMap({ $0 as NSView? }) { addSubview(view) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func parts(showingLabel: Bool) -> [(NSView, CGFloat)] {
        var out: [(NSView, CGFloat)] = []
        if let word, showingLabel { out.append((word, min(96, ceil(word.textWidth)))) }
        if let glyph { out.append((glyph, glyph.intrinsicContentSize.width)) }
        if let bolt { out.append((bolt, bolt.intrinsicContentSize.width)) }
        if let workflow { out.append((workflow, 12)) }
        if let context, showingLabel { out.append((context, min(96, ceil(context.textWidth)))) }
        return out
    }

    func width(showingLabel: Bool) -> CGFloat {
        let p = parts(showingLabel: showingLabel)
        return p.map(\.1).reduce(0, +) + CGFloat(max(0, p.count - 1)) * 6
    }

    override var intrinsicContentSize: NSSize { NSSize(width: width(showingLabel: showsLabels), height: 20) }

    func restyle(hovered: Bool, labelColor: NSColor, font: NSFont) {
        let color = hovered ? Themed.color(\.contrastForeground) : Themed.color(\.contrastMutedForeground)
        word?.font = font
        word?.color = color; context?.color = color; glyph?.color = color; bolt?.color = color; workflow?.strokeColor = color
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        for (view, w) in parts(showingLabel: showsLabels) {
            let h: CGFloat = view === word ? 20 : view === context ? 16 : view === glyph ? 14 : 12
            view.frame = NSRect(x: x, y: (bounds.height - h) / 2, width: w, height: h)
            x += w + 6
        }
    }
}

// MARK: - Effort column

/// One row of the column: a level (`ColumnRow`, :191-244), an option opening a side menu (`OptionMenuRow`, :385-485),
/// or a two-state option with a switch (`OptionSwitchRow`, :488-514).
final class ComposerEffortRowView: ControlView {
    enum Kind: Equatable {
        case level(label: String, selected: Bool, isDefault: Bool)
        case menu(label: String, value: String)
        case toggle(label: String, on: Bool)
    }
    let kind: Kind
    var focused = false { didSet { if focused != oldValue { needsDisplay = true } } }
    var capy = false
    private let title = LabelView()
    private let caption = LabelView()
    private var check: IconView?
    private var chevron: IconView?
    private(set) var toggle: SwitchView?
    private let fill = CALayer()

    init(_ kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        scalesWhenPressed = false
        fill.cornerRadius = 4
        fill.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(fill)
        for l in [title, caption] { l.smoothsFont = false; addSubview(l) }
        title.font = DSFont.ui(14); title.lineHeight = 20
        caption.font = DSFont.ui(12); caption.lineHeight = 16
        switch kind {
        case .level(let label, let selected, let isDefault):
            title.text = label
            caption.text = isDefault && !selected ? "Default" : ""
            if selected { let c = IconView(name: .check, size: 14); addSubview(c); check = c }
            setAccessibilityRole(.radioButton); setAccessibilityValue(selected ? 1 : 0)
            setAccessibilityLabel(isDefault && selected ? "\(label), Default" : label)
        case .menu(let label, let value):
            caption.text = label; title.text = value
            let c = IconView(name: .chevronRight, size: 14); addSubview(c); chevron = c
            setAccessibilityRole(.popUpButton); setAccessibilityLabel("\(label): \(value)")
        case .toggle(let label, let on):
            caption.text = label; title.text = on ? "On" : "Off"
            let s = SwitchView(isOn: on, size: .sm)
            addSubview(s); toggle = s
            setAccessibilityRole(.checkBox); setAccessibilityLabel(label); setAccessibilityValue(on ? 1 : 0)
        }
    }

    /// `h-8`, or `h-auto py-1` with the option's name over its value.
    var height: CGFloat { if case .level = kind { 32 } else { 44 } }

    override func stateDidChange(from old: State) { super.stateDidChange(from: old); needsDisplay = true }

    override func layout() {
        super.layout()
        fill.frame = bounds
        let w = bounds.width
        switch kind {
        case .level:
            var right = w - 8
            if let check { check.frame = NSRect(x: right - 14, y: (bounds.height - 14) / 2, width: 14, height: 14); right -= 14 + 8 }
            if !caption.text.isEmpty {
                let cw = ceil(caption.textWidth)
                caption.frame = NSRect(x: right - cw, y: (bounds.height - 16) / 2, width: cw, height: 16)
                right -= cw + 8
            }
            title.frame = NSRect(x: 8, y: (bounds.height - 20) / 2, width: max(0, right - 8), height: 20)
        case .menu, .toggle:
            var right = w - 8
            if let chevron { chevron.frame = NSRect(x: right + 4 - 14, y: (bounds.height - 14) / 2, width: 14, height: 14); right -= 14 - 4 + 8 }
            if let toggle {
                let s = toggle.intrinsicContentSize
                toggle.frame = NSRect(x: right - s.width, y: (bounds.height - s.height) / 2, width: s.width, height: s.height)
                right -= s.width + 8
            }
            caption.frame = NSRect(x: 8, y: 4, width: max(0, right - 8), height: 16)
            title.frame = NSRect(x: 8, y: 20, width: max(0, right - 8), height: 20)
        }
    }

    override func updateLayer() {
        let lit = (state.hovered || focused || state.popupOpen) && state.enabled
        // `hover:bg-foreground/[0.09] focus-visible:bg-foreground/[0.09]` (COLUMN_ROW, ComposerModelEffort.tsx:188).
        fill.backgroundColor = lit ? (capy ? Themed.color(\.contrastForeground, 0.07) : Themed.color(\.contrastForeground, 0.09)).cgColor(in: self) : nil
        title.color = Themed.color(\.contrastForeground)
        switch kind {
        case .level: caption.color = Themed.color(\.contrastMutedForeground, 0.7)
        default: caption.color = Themed.color(\.contrastMutedForeground)
        }
        check?.strokeColor = Themed.color(\.contrastForeground)
        chevron?.strokeColor = Themed.color(\.contrastMutedForeground)
        alphaValue = state.enabled ? 1 : 0.64
    }
}

/// `ComposerEffortColumn` (ComposerModelEffort.tsx:525-562): `w-48`, `bg-muted/40` and a left rule; a header naming
/// the reasoning control and the model, then the levels and the model's other options.
final class ComposerEffortColumnView: DSView {
    static let width: CGFloat = 192
    var capy: Bool { ThemeRuntime.isDither(dark: effectiveAppearance.isDark) }
    /// Redesign stacks the section under the model list: the header across, the levels as segmented lines, then the
    /// option rows (the user's layout, 2026-11-20). Only Redesign docks a capy column, so the two go together.
    var stacked: Bool { capy }
    /// The level segments in the stacked layout, keyed by their index in `rows`; their rows stay hidden.
    private(set) var segments: [Int: ComposerFooterSegmentView] = [:]
    private(set) var levelLines: [ComposerFooterGroupView] = []
    /// The stacked section changed height.
    var onSizeChange: (() -> Void)?
    var onSelect: ((ProviderOptionDescriptor, String) -> Void)?
    var onBoolean: ((String, Bool) -> Void)?
    /// An option row's side menu; the column passes the row as the anchor.
    var onOpenOption: ((ProviderOptionDescriptor, NSView) -> Void)?
    private(set) var rows: [ComposerEffortRowView] = []
    private var rowDescriptors: [(ProviderOptionDescriptor, ProviderOptionValue?)] = []
    private var separatorAfter: Int?
    private let heading = LabelView()
    private let modelLabel = LabelView()
    private let note = TextBlockView()
    private let empty = LabelView("No effort levels", font: DSFont.ui(14))
    private let headerRule = CALayer()
    private let optionsRule = CALayer()
    private let leftRule = CALayer()
    private var scrollOffset: CGFloat = 0
    /// The row holding keyboard focus, or nil while the model list has it.
    private(set) var focusIndex: Int? { didSet { showFocus() } }
    /// `focus-visible`: the focused row lights only after keyboard input. Chromium does not match it for focus that
    /// follows a click, so a level focused by picking a model with the pointer, or clicked itself, stays unlit and the
    /// pointer's row is the only one lit (COLUMN_ROW, ComposerModelEffort.tsx:188 at 4928).
    var focusVisible = false { didSet { if focusVisible != oldValue { showFocus() } } }
    private func showFocus() {
        for (i, r) in rows.enumerated() { r.focused = focusVisible && i == focusIndex }
        for (i, s) in segments { s.focused = focusVisible && i == focusIndex }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clipsToBounds = true
        for l in [headerRule, optionsRule, leftRule] { l.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]; layer?.addSublayer(l) }
        heading.font = DSFont.ui(14); heading.lineHeight = 20
        modelLabel.font = DSFont.ui(12); modelLabel.lineHeight = 16; modelLabel.alignment = .right
        note.font = DSFont.ui(12); note.lineHeight = 16
        empty.lineHeight = 20
        for v in [heading, modelLabel, note, empty] as [NSView] { addSubview(v) }
        for l in [heading, modelLabel, empty] { l.smoothsFont = false }
        note.smoothsFont = false
    }

    /// Rebuilds the rows for the selected model's descriptors. `locked`: Ultrathink in the prompt body locks the levels.
    func update(descriptors: [ProviderOptionDescriptor], ultrathink: Bool, locked: Bool, model: String) {
        let controls = ComposerEffortControls(descriptors)
        let primary = descriptors.first { $0.type == .select }?.id
        let locked = locked && controls.effort?.id == primary
        heading.text = controls.effort?.label ?? (controls.others.isEmpty ? "Effort" : "Options")
        modelLabel.text = model
        note.text = locked ? "Your prompt contains \"ultrathink\" in the text. Remove it to change this option." : ""
        let previousFocus = focusIndex
        rows.forEach { $0.removeFromSuperview() }
        rows = []; rowDescriptors = []
        if let effort = controls.effort {
            if effort.type == .boolean {
                for value in [true, false] {
                    rows.append(ComposerEffortRowView(.level(label: value ? "On" : "Off", selected: (effort.currentValue?.bool == true) == value, isDefault: false)))
                    rowDescriptors.append((effort, .bool(value)))
                }
            } else {
                let current = ultrathink && effort.id == primary ? "ultrathink" : ModelTraits.currentValue(effort)?.string
                for choice in ComposerEffortControls.choices(effort) {
                    let row = ComposerEffortRowView(.level(label: choice.label, selected: choice.id == current, isDefault: choice.isDefault == true))
                    row.toolTip = choice.description
                    row.isEnabled = !locked
                    rows.append(row); rowDescriptors.append((effort, .string(choice.id)))
                }
            }
        }
        separatorAfter = controls.effort != nil && !controls.others.isEmpty ? rows.count : nil
        for d in controls.others {
            if d.type == .boolean {
                rows.append(ComposerEffortRowView(.toggle(label: d.label, on: d.currentValue?.bool == true)))
                rowDescriptors.append((d, nil))
            } else {
                let value = ModelTraits.currentValue(d)?.string
                rows.append(ComposerEffortRowView(.menu(label: d.label, value: d.options.first { $0.id == value }?.label ?? "")))
                rowDescriptors.append((d, nil))
            }
        }
        for (i, row) in rows.enumerated() {
            row.capy = capy
            row.action = { [weak self] in
                // A click focuses its row without the focus fill.
                self?.focusVisible = false; self?.focusIndex = i
                self?.activate(i)
            }
            row.toggle?.onChange = { [weak self] on in
                guard let self, i < self.rowDescriptors.count else { return }
                self.onBoolean?(self.rowDescriptors[i].0.id, on)
            }
            addSubview(row)
        }
        buildSegments()
        empty.isHidden = !rows.isEmpty
        if let previousFocus, !rows.isEmpty { focusIndex = min(previousFocus, rows.count - 1) } else { focusIndex = nil }
        needsLayout = true
        needsDisplay = true
        if stacked { onSizeChange?() }
    }

    private func isLevel(_ i: Int) -> Bool { if case .level = rows[i].kind { true } else { false } }

    /// Stacked: each level becomes a segment that acts through its hidden row, packed into full-width lines. Levels that
    /// don't fit on one line wrap to the next.
    private func buildSegments() {
        levelLines.forEach { $0.removeFromSuperview() }
        levelLines = []; segments = [:]
        guard stacked else { return }
        var line: [ComposerFooterSegmentView] = [], lineWidth: CGFloat = 4
        let available = ModelPickerView.stackedWidth - 16
        func flush() {
            guard !line.isEmpty else { return }
            let group = ComposerFooterGroupView(line)
            group.fills = true
            addSubview(group); levelLines.append(group)
            line = []; lineWidth = 4
        }
        for (i, row) in rows.enumerated() {
            guard case .level(let label, let selected, let isDefault) = row.kind else { continue }
            row.isHidden = true
            let s = ComposerFooterSegmentView(title: label, checked: selected)
            // The column's "Default" caption has no room in a segment; it moves to the tooltip and the label.
            s.toolTip = isDefault ? [row.toolTip, "Default"].compactMap { $0 }.joined(separator: "\n") : row.toolTip
            if isDefault { s.setAccessibilityLabel("\(label), Default") }
            s.isEnabled = row.isEnabled
            s.action = { [weak row] in row?.action?() }
            segments[i] = s
            if !line.isEmpty, lineWidth + s.naturalWidth > available { flush() }
            line.append(s); lineWidth += s.naturalWidth
        }
        flush()
    }

    func activate(_ i: Int) {
        guard i < rows.count, rows[i].isEnabled else { return }
        let (d, value) = rowDescriptors[i]
        switch (rows[i].kind, value) {
        case (.level, .string(let id)?): onSelect?(d, id)
        case (.level, .bool(let on)?): onBoolean?(d.id, on)
        case (.toggle(_, let on), _): onBoolean?(d.id, !on)
        case (.menu, _): onOpenOption?(d, rows[i])
        default: break
        }
    }

    /// `focusEffort` (ProviderModelPicker.tsx:199-214): the selected level, else the first enabled level; with `any`
    /// the first enabled row. False when nothing took focus.
    @discardableResult
    func focus(levelsOnly: Bool) -> Bool {
        let enabled = rows.indices.filter { rows[$0].isEnabled }
        let levels = enabled.filter { if case .level = rows[$0].kind { true } else { false } }
        let target = levels.first { if case .level(_, true, _) = rows[$0].kind { true } else { false } } ?? levels.first ?? (levelsOnly ? nil : enabled.first)
        focusIndex = target
        if target != nil { scrollToFocus() }
        return target != nil
    }

    func blur() { focusIndex = nil }

    /// The selected level, else the first enabled one.
    private var selectedLevel: Int? {
        rows.indices.first { if case .level(_, true, _) = rows[$0].kind { rows[$0].isEnabled } else { false } }
            ?? rows.indices.first { isLevel($0) && rows[$0].isEnabled }
    }

    /// Stacked: Left and Right move across the levels without wrapping, Down and Up move between the levels and the
    /// option rows under them. Tab, typing and Escape go back to the dock.
    private func handleStackedKey(_ key: PopupKey) -> Bool {
        let enabled = rows.indices.filter { rows[$0].isEnabled }
        let levels = enabled.filter(isLevel), options = enabled.filter { !isLevel($0) }
        switch key {
        case .left, .right, .up, .down, .home, .end, .enter, .space: break
        default: return false
        }
        focusVisible = true
        guard let focus = focusIndex else { focusIndex = selectedLevel ?? options.first; return true }
        switch key {
        case .left, .right:
            if let pos = levels.firstIndex(of: focus) {
                focusIndex = levels[min(levels.count - 1, max(0, pos + (key == .right ? 1 : -1)))]
            } else if key == .right, case .menu = rows[focus].kind {
                activate(focus)
            }
        case .up, .down:
            if let pos = options.firstIndex(of: focus) {
                if key == .down { focusIndex = options[min(options.count - 1, pos + 1)] }
                else { focusIndex = pos > 0 ? options[pos - 1] : (selectedLevel ?? focus) }
            } else if key == .down, let first = options.first {
                focusIndex = first
            }
        case .home: focusIndex = levels.first ?? enabled.first
        case .end: focusIndex = levels.last ?? enabled.last
        default: activate(focus)
        }
        return true
    }

    /// `moveBetweenRows` (:246-261): Up and Down move between enabled rows without wrapping.
    func handleKey(_ key: PopupKey) -> Bool {
        if stacked { return handleStackedKey(key) }
        focusVisible = true
        let enabled = rows.indices.filter { rows[$0].isEnabled }
        switch key {
        case .up, .down:
            guard let focus = focusIndex, let pos = enabled.firstIndex(of: focus) else { focusIndex = enabled.first; return true }
            focusIndex = enabled[min(enabled.count - 1, max(0, pos + (key == .down ? 1 : -1)))]
            scrollToFocus()
            return true
        case .home: focusIndex = enabled.first; scrollToFocus(); return true
        case .end: focusIndex = enabled.last; scrollToFocus(); return true
        case .enter, .space:
            if let focus = focusIndex { activate(focus) }
            return true
        case .right:
            if let focus = focusIndex, case .menu = rows[focus].kind { activate(focus) }
            return true
        case .character, .tab:
            return true
        default:
            return false
        }
    }

    // MARK: Layout

    private static let contentTop: CGFloat = 53
    private var noteHeight: CGFloat { note.text.isEmpty ? 0 : note.layout(forWidth: Self.width - 32).height + 6 }

    private var contentHeight: CGFloat {
        var y = noteHeight
        for (i, row) in rows.enumerated() {
            if i == separatorAfter { y += 4 + 1 + 4 - 2 }
            y += row.height + (i < rows.count - 1 ? 2 : 0)
        }
        return y + 6
    }

    private func scrollToFocus() {
        guard let focus = focusIndex, bounds.height > 0 else { return }
        layoutSubtreeIfNeeded()
        let top = rows[focus].frame.minY + scrollOffset - Self.contentTop, bottom = top + rows[focus].height
        let visible = bounds.height - Self.contentTop - 6
        if top < scrollOffset { scrollOffset = top } else if bottom > scrollOffset + visible { scrollOffset = bottom - visible }
        needsLayout = true
    }

    override func scrollWheel(with event: NSEvent) {
        // Stacked, the section is never taller than its content.
        if stacked { return }
        let maxScroll = max(0, contentHeight - (bounds.height - Self.contentTop))
        scrollOffset = min(max(0, scrollOffset - event.scrollPointsY), maxScroll)
        needsLayout = true
    }

    /// The stacked section's height at `width`.
    func stackedHeight(width: CGFloat) -> CGFloat { placeStacked(width: width, apply: false) }

    /// Stacked: a hairline over the section, the heading and the model's short name on one line, the levels' lines, then
    /// the option rows. Returns the height.
    @discardableResult
    private func placeStacked(width w: CGFloat, apply: Bool) -> CGFloat {
        if apply {
            leftRule.frame = CGRect(x: 0, y: 0, width: w, height: 1)
            headerRule.isHidden = true; optionsRule.isHidden = true
            let headingW = min(ceil(heading.textWidth), w - 24)
            heading.frame = NSRect(x: 12, y: 10, width: headingW, height: 20)
            let modelX = 12 + headingW + 8
            modelLabel.frame = NSRect(x: modelX, y: 12, width: max(0, w - 12 - modelX), height: 16)
            empty.frame = NSRect(x: 12, y: 36, width: w - 24, height: 20)
        }
        var y: CGFloat = 36, bottom = y
        if rows.isEmpty { return y + 20 + 10 }
        if !note.text.isEmpty {
            let h = note.layout(forWidth: w - 24).height
            if apply { note.frame = NSRect(x: 12, y: y, width: w - 24, height: h) }
            y += h + 6
        } else if apply {
            note.frame = .zero
        }
        for line in levelLines {
            // The track runs nearly edge to edge, 8pt in, as the user's picture has it.
            if apply { line.frame = NSRect(x: 8, y: y, width: w - 16, height: 28); line.needsLayout = true }
            bottom = y + 28
            y += 28 + 4
        }
        if !levelLines.isEmpty { y += 4 }
        for (i, row) in rows.enumerated() where !isLevel(i) {
            if apply { row.frame = NSRect(x: 6, y: y, width: w - 12, height: row.height) }
            bottom = y + row.height
            y += row.height + 2
        }
        return bottom + 12
    }

    override func layout() {
        super.layout()
        if stacked { placeStacked(width: bounds.width, apply: true); return }
        headerRule.isHidden = false
        leftRule.frame = CGRect(x: 0, y: 0, width: 1, height: bounds.height)
        // `border-l` (ProviderModelPicker.tsx:481): the content box starts after the 1pt rule.
        let b: CGFloat = 1, w = bounds.width - b
        // `px-3 pt-2.5`, the `h-8.25` box lifted 1pt with `pb-1.5` over its rule: matches the search row.
        let headingW = ceil(heading.textWidth)
        heading.frame = NSRect(x: b + 12, y: 12, width: min(headingW, w - 24), height: 20)
        let modelX = b + 12 + headingW + 8
        modelLabel.frame = NSRect(x: modelX, y: 14, width: max(0, b + w - 12 - modelX), height: 16)
        headerRule.frame = CGRect(x: b + 12, y: 41, width: w - 24, height: 1)
        // `px-2 pt-2.5 pb-1.5 gap-0.5`, so the first level sits on the first model's line.
        var y = Self.contentTop - scrollOffset
        if !note.text.isEmpty {
            let h = note.layout(forWidth: w - 32).height
            note.frame = NSRect(x: b + 16, y: y, width: w - 32, height: h)
            y += h + 6
        } else {
            note.frame = .zero
        }
        optionsRule.isHidden = separatorAfter == nil
        for (i, row) in rows.enumerated() {
            if i == separatorAfter {
                // `mt-1 border-t pt-1` on the options group, inside the column's `gap-0.5`.
                optionsRule.frame = CGRect(x: b + 8, y: y + 2, width: w - 16, height: 1)
                y += 4 + 1 + 4 - 2
            }
            row.frame = NSRect(x: b + 8, y: y, width: w - 16, height: row.height)
            y += row.height + 2
        }
        empty.frame = NSRect(x: b + 16, y: Self.contentTop + 6, width: w - 32, height: 20)
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); rows.forEach { $0.capy = capy; $0.needsDisplay = true }; needsDisplay = true }

    override func updateLayer() {
        layer?.backgroundColor = capy ? nil : Themed.color(\.muted, 0.4).cgColor(in: self)
        let rule = (capy ? Themed.color(\.contrastForeground, 0.08) : Themed.color(\.border, 0.7)).cgColor(in: self)
        for l in [headerRule, optionsRule, leftRule] { l.backgroundColor = rule }
        heading.color = Themed.color(\.contrastMutedForeground)
        modelLabel.color = Themed.color(\.contrastMutedForeground)
        note.color = Themed.color(\.contrastMutedForeground, 0.8)
        empty.color = Themed.color(\.contrastMutedForeground)
    }
}

// MARK: - Footer

/// A footer segment (`FOOTER_SEGMENT`, :564-565): `h-6 px-2 text-xs gap-1`, checked on `bg-input/72`.
final class ComposerFooterSegmentView: ControlView {
    let checked: Bool
    private let label: LabelView
    private let glyph: NSView?
    var first = true, last = true
    /// Keyboard focus held by the dock while the search keeps first responder (Redesign's stacked picker).
    var focused = false { didSet { if focused != oldValue { needsDisplay = true } } }
    init(title: String, checked: Bool, glyph: NSView? = nil) {
        self.checked = checked
        label = LabelView(title, font: DSFont.ui(12))
        self.glyph = glyph
        super.init(frame: .zero)
        scalesWhenPressed = false
        label.lineHeight = 16; label.smoothsFont = false
        addSubview(label)
        if let glyph { addSubview(glyph) }
        setAccessibilityRole(.radioButton); setAccessibilityLabel(title); setAccessibilityValue(checked ? 1 : 0)
    }
    private var glyphWidth: CGFloat { glyph.map { ($0 as? ComposerFastGlyphView)?.intrinsicContentSize.width ?? 12 } ?? 0 }
    /// `px-2`; Redesign's stacked footer uses 6 so its controls share one 335pt line.
    var inset: CGFloat = 8 { didSet { needsLayout = true } }
    var naturalWidth: CGFloat { 2 * inset + ceil(label.textWidth) + (glyph == nil ? 0 : glyphWidth + 4) }
    override func stateDidChange(from old: State) { super.stateDidChange(from: old); needsDisplay = true }
    override func layout() {
        super.layout()
        var x = (bounds.width - naturalWidth) / 2 + inset
        if let glyph { glyph.frame = NSRect(x: x, y: (bounds.height - 12) / 2, width: glyphWidth, height: 12); x += glyphWidth + 4 }
        label.frame = NSRect(x: x, y: (bounds.height - 16) / 2, width: ceil(label.textWidth), height: 16)
    }
    override func updateLayer() {
        layer?.cornerRadius = 6
        var corners: CACornerMask = []
        if first { corners.formUnion([.layerMinXMinYCorner, .layerMinXMaxYCorner]) }
        if last { corners.formUnion([.layerMaxXMinYCorner, .layerMaxXMaxYCorner]) }
        layer?.maskedCorners = corners
        layer?.backgroundColor = checked ? Themed.color(\.input, 0.72).cgColor(in: self) : nil
        layer?.borderWidth = state.focusVisible || focused ? 2 : 0; layer?.borderColor = Themed.color(\.ring).cgColor(in: self)
        alphaValue = state.enabled ? 1 : 0.64
        let color = checked || state.hovered ? Themed.color(\.contrastForeground) : Themed.color(\.contrastMutedForeground)
        label.color = color
        (glyph as? ComposerFastGlyphView)?.color = color
        (glyph as? IconView)?.strokeColor = color
    }
}

/// The segment track: `flex rounded-lg bg-input/40 p-0.5`.
final class ComposerFooterGroupView: DSView {
    let segments: [ComposerFooterSegmentView]
    init(_ segments: [ComposerFooterSegmentView]) {
        self.segments = segments
        super.init(frame: .zero)
        for (i, s) in segments.enumerated() { s.first = i == 0; s.last = i == segments.count - 1; addSubview(s) }
    }
    var naturalWidth: CGFloat { segments.map(\.naturalWidth).reduce(0, +) + 4 }
    /// Spreads the track's spare width evenly over the segments (Redesign's stacked levels).
    var fills = false
    override func layout() {
        super.layout()
        let extra = fills && !segments.isEmpty ? max(0, bounds.width - naturalWidth) / CGFloat(segments.count) : 0
        var exact: CGFloat = 2, x: CGFloat = 2
        for s in segments {
            exact += s.naturalWidth + extra
            let next = exact.rounded()
            s.frame = NSRect(x: x, y: 2, width: next - x, height: 24); x = next
        }
    }
    override func updateLayer() { layer?.cornerRadius = 8; layer?.backgroundColor = Themed.color(\.input, 0.4).cgColor(in: self) }
}

/// The footer's Permissions trigger (`PermissionsMenu`, :666-706): `ms-auto h-7 px-2 rounded-md text-xs gap-1.5`, the
/// mode's icon, its name and a chevron-up.
final class ComposerPermissionsTriggerView: ControlView {
    private let icon: IconView
    private let label: LabelView
    private let chevron = IconView(name: .chevronUp, size: 12)
    /// Keyboard focus held by the dock while the search keeps first responder (Redesign's stacked picker).
    var focused = false { didSet { if focused != oldValue { needsDisplay = true } } }
    init(mode: RuntimeMode, unrestricted: Bool = false) {
        let info = unrestricted ? ComposerPermissionsView.info(nil, unrestricted: nil) : ComposerPickers.modes[mode] ?? ComposerPickers.modes[.fullAccess]!
        icon = IconView(definition: mode == .fullAccess && !unrestricted ? ComposerPickers.fullAccessGlyph : info.icon.definition, size: 14)
        label = LabelView(info.label, font: DSFont.ui(12))
        super.init(frame: .zero)
        scalesWhenPressed = false
        label.lineHeight = 16; label.smoothsFont = false
        for v in [icon, label, chevron] as [NSView] { addSubview(v) }
        setAccessibilityRole(.popUpButton); setAccessibilityLabel("Permissions: \(info.label)")
    }
    /// Redesign's stacked footer draws the chip without its chevron, as the user's picture has it.
    var showsChevron = true { didSet { chevron.isHidden = !showsChevron } }
    /// `px-2`; Redesign's stacked footer uses 6.
    var inset: CGFloat = 8 { didSet { needsLayout = true } }
    var naturalWidth: CGFloat { inset + 14 + 6 + ceil(label.textWidth) + (showsChevron ? 6 + 12 : 0) + inset }
    override func stateDidChange(from old: State) { super.stateDidChange(from: old); needsDisplay = true }
    override func layout() {
        super.layout()
        let mid = bounds.height / 2
        icon.frame = NSRect(x: inset, y: mid - 7, width: 14, height: 14)
        label.frame = NSRect(x: inset + 20, y: mid - 8, width: ceil(label.textWidth), height: 16)
        chevron.frame = NSRect(x: label.frame.maxX + 6, y: mid - 6, width: 12, height: 12)
    }
    override func updateLayer() {
        layer?.cornerRadius = 6
        layer?.backgroundColor = state.hoverOrPressed ? Themed.color(\.accent).cgColor(in: self) : nil
        layer?.borderWidth = state.focusVisible || focused ? 2 : 0; layer?.borderColor = Themed.color(\.ring).cgColor(in: self)
        let color = state.hoverOrPressed ? Themed.color(\.contrastForeground) : Themed.color(\.contrastMutedForeground)
        label.color = color; icon.strokeColor = color; chevron.strokeColor = color
    }
}

/// `ComposerPickerFooter` (:709-726): `flex-wrap gap-2 border-t bg-muted/40 px-3 py-2`, speed one click away and
/// permissions one menu deeper.
final class ComposerPickerFooterView: DSView {
    static let height: CGFloat = 45
    var capy: Bool { ThemeRuntime.isDither(dark: effectiveAppearance.isDark) }
    private(set) var speed: ComposerFooterGroupView?
    private(set) var ultracode: ComposerFooterGroupView?
    private(set) var permissions: ComposerPermissionsTriggerView?
    private let rule = CALayer()
    var onSelect: ((ProviderOptionDescriptor, String) -> Void)?
    var onBoolean: ((String, Bool) -> Void)?
    var onPermissions: ((NSView) -> Void)?
    /// Redesign's stacked picker: the controls wrap to a second line when they don't fit its 335pt.
    var stacked: Bool { capy }
    var onSizeChange: (() -> Void)?
    /// Keyboard focus among the segments and the permissions trigger, in reading order (stacked only).
    private(set) var focusIndex: Int? { didSet { showFocus() } }
    var focusVisible = false { didSet { showFocus() } }
    var items: [ControlView] { ([speed, ultracode].compactMap { $0 }.flatMap(\.segments) as [ControlView]) + [permissions].compactMap { $0 } }
    private func showFocus() {
        for (i, item) in items.enumerated() {
            let on = focusVisible && i == focusIndex
            (item as? ComposerFooterSegmentView)?.focused = on
            (item as? ComposerPermissionsTriggerView)?.focused = on
        }
    }

    /// Focuses the first control, or the permissions trigger.
    func focus(permissions: Bool) {
        focusVisible = NSApp.currentEvent?.type == .keyDown
        let all = items
        focusIndex = all.isEmpty ? nil : permissions ? all.count - 1 : 0
    }

    func blur() { focusIndex = nil }

    /// Left and Right move across the controls without wrapping; Return and Space press the focused one.
    func handleKey(_ key: PopupKey) -> Bool {
        let all = items
        guard let focus = focusIndex, focus < all.count else { return false }
        switch key {
        case .left, .right:
            focusVisible = true
            focusIndex = min(all.count - 1, max(0, focus + (key == .right ? 1 : -1)))
            return true
        case .up, .down, .home, .end:
            focusVisible = true
            if key == .home { focusIndex = 0 } else if key == .end { focusIndex = all.count - 1 }
            return true
        case .enter, .space:
            focusVisible = true
            all[focus].action?()
            return true
        default:
            return false
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        rule.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(rule)
    }

    func update(descriptors: [ProviderOptionDescriptor], runtimeMode: RuntimeMode, unrestricted: Bool = false) {
        [speed, ultracode].forEach { $0?.removeFromSuperview() }
        permissions?.removeFromSuperview()
        let controls = ComposerEffortControls(descriptors)
        speed = nil; ultracode = nil
        if let tier = controls.speedSelect {
            let value = ModelTraits.currentValue(tier)?.string
            speed = ComposerFooterGroupView(ComposerEffortControls.choices(tier).map { choice in
                let s = ComposerFooterSegmentView(title: choice.label, checked: choice.id == value,
                                                  glyph: choice.label == "Fast" || choice.label == "Ultrafast" ? ComposerFastGlyphView(ultra: choice.label == "Ultrafast") : nil)
                s.toolTip = choice.description
                s.action = { [weak self] in self?.onSelect?(tier, choice.id) }
                return s
            })
        } else if let fast = controls.fastToggle {
            let on = fast.currentValue?.bool == true
            speed = ComposerFooterGroupView([false, true].map { value in
                let s = ComposerFooterSegmentView(title: value ? "Fast" : "Standard", checked: on == value, glyph: value ? ComposerFastGlyphView(ultra: false) : nil)
                s.action = { [weak self] in self?.onBoolean?(fast.id, value) }
                return s
            })
        }
        if let toggle = controls.ultracodeToggle {
            let on = toggle.currentValue?.bool == true
            let s = ComposerFooterSegmentView(title: toggle.label, checked: on, glyph: IconView(name: .workflow, size: 12))
            s.setAccessibilityRole(.checkBox)
            s.action = { [weak self] in self?.onBoolean?(toggle.id, !on) }
            ultracode = ComposerFooterGroupView([s])
        }
        let trigger = ComposerPermissionsTriggerView(mode: runtimeMode, unrestricted: unrestricted)
        trigger.opensPopupOnPress = true
        trigger.action = { [weak self, weak trigger] in if let trigger { self?.onPermissions?(trigger) } }
        permissions = trigger
        for v in [speed, ultracode, permissions].compactMap({ $0 as NSView? }) { addSubview(v) }
        if let f = focusIndex { focusIndex = min(f, items.count - 1) }
        needsLayout = true
        needsDisplay = true
        if stacked { onSizeChange?() }
    }

    /// Stacked: `flex-wrap` in 335pt, 8pt in and 6pt apart so Standard, Fast, Ultracode and Full access share one line as
    /// in the user's picture; the permissions trigger sits at the end of its line (`ms-auto`) and a longer mode wraps.
    func stackedHeight(width: CGFloat) -> CGFloat { placeStacked(width: width, apply: false) }

    @discardableResult
    private func placeStacked(width w: CGFloat, apply: Bool) -> CGFloat {
        permissions?.showsChevron = false
        permissions?.inset = 6
        for group in [speed, ultracode].compactMap({ $0 }) { group.segments.forEach { $0.inset = 6 } }
        var x: CGFloat = 8, y: CGFloat = 9
        let parts: [(NSView, CGFloat)] = [speed, ultracode].compactMap { $0 }.map { ($0, $0.naturalWidth) }
            + [permissions].compactMap { $0 }.map { ($0, $0.naturalWidth) }
        for (view, width) in parts {
            if x > 8, x + width > w - 8 { x = 8; y += 28 + 6 }
            let px = view === permissions ? w - 8 - width : x
            if apply { view.frame = NSRect(x: px, y: y, width: width, height: 28) }
            x += width + 6
        }
        return y + 28 + 8
    }

    override func layout() {
        super.layout()
        rule.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 1)
        if stacked { placeStacked(width: bounds.width, apply: true); return }
        var x: CGFloat = 12
        for group in [speed, ultracode].compactMap({ $0 }) {
            group.frame = NSRect(x: x, y: 9, width: group.naturalWidth, height: 28)
            x += group.naturalWidth + 8
        }
        if let permissions {
            let w = permissions.naturalWidth
            permissions.frame = NSRect(x: bounds.width - 12 - w, y: 9, width: w, height: 28)
        }
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    override func updateLayer() {
        layer?.backgroundColor = capy ? nil : Themed.color(\.muted, 0.4).cgColor(in: self)
        rule.backgroundColor = (capy ? Themed.color(\.contrastForeground, 0.08) : Themed.color(\.border, 0.7)).cgColor(in: self)
    }
}

/// The footer's Permissions popup: the same toggle the chip opens (`ComposerPermissionsSection`).
final class ComposerPermissionsMenu: DSView, PickerPopupBody {
    let permissions: ComposerPermissionsView
    var onClose: (() -> Void)?
    init(modes: [RuntimeMode], selected: RuntimeMode, unrestricted: UnrestrictedAccess.State? = nil,
         onUnrestricted: ((Bool) -> Void)? = nil, onPick: @escaping (RuntimeMode) -> Void) {
        permissions = ComposerPermissionsView(modes: modes, selected: selected, unrestricted: unrestricted)
        super.init(frame: .zero)
        addSubview(permissions)
        permissions.onPick = { [weak self] mode in onPick(mode); self?.onClose?() }
        permissions.onUnrestricted = { [weak self] on in self?.onClose?(); onUnrestricted?(on) }
    }
    var naturalSize: CGSize { CGSize(width: 296, height: 130 + permissions.extraHeight) }
    func handleKey(_ key: PopupKey) -> Bool {
        if key == .escape { onClose?(); return true }
        return permissions.handleKey(key)
    }
    override func layout() { super.layout(); permissions.frame = NSRect(x: 4, y: 4, width: bounds.width - 8, height: 122 + permissions.extraHeight) }
}

// MARK: - Docked picker

/// `ProviderModelPicker` with an effort column (ProviderModelPicker.tsx:472-495): one fixed height so a model with more
/// options never resizes the popup, the column beside the list and the footer under both.
final class DockedModelPickerView: DSView, PickerPopupBody {
    let picker: ModelPickerView
    let column = ComposerEffortColumnView()
    let footer = ComposerPickerFooterView()

    /// Redesign: one 335pt column, the list over the Reasoning section over the footer (the user's layout, 2026-11-20).
    var stacked: Bool { picker.stacked }
    /// Stacked: keyboard focus sits on the list, between the search and the Reasoning section in Tab order.
    private(set) var listFocused = false

    init(picker: ModelPickerView) {
        self.picker = picker
        picker.docked = true
        super.init(frame: .zero)
        clipsToBounds = true
        for v in [picker, column, footer] as [NSView] { addSubview(v) }
        column.onSizeChange = { [weak self] in self?.contentChanged() }
        footer.onSizeChange = { [weak self] in self?.contentChanged() }
    }

    private func contentChanged() {
        needsLayout = true
        picker.resizePopup()
    }

    var naturalSize: CGSize {
        let list = picker.naturalSize
        if stacked {
            let w = ModelPickerView.stackedWidth
            return CGSize(width: w, height: list.height + column.stackedHeight(width: w) + footer.stackedHeight(width: w))
        }
        return CGSize(width: list.width + ComposerEffortColumnView.width, height: list.height + ComposerPickerFooterView.height)
    }

    /// The section keyboard focus is in (stacked).
    enum Section: Equatable { case tabs, search, list, reasoning, footer }
    var section: Section {
        if column.focusIndex != nil { return .reasoning }
        if footer.focusIndex != nil { return .footer }
        if picker.railFocus != nil { return .tabs }
        return listFocused ? .list : .search
    }

    /// Moves keyboard focus to `section`; the focus shows.
    func focus(_ section: Section) {
        column.blur(); footer.blur(); picker.focusRail(false); listFocused = false
        switch section {
        case .tabs: picker.focusRail(true)
        case .search: window?.makeFirstResponder(picker.search)
        case .list: listFocused = true; picker.highlightForKeyboard()
        case .reasoning:
            column.focusVisible = true
            if column.focus(levelsOnly: false) { picker.clearKeyboardHighlight() }
        case .footer: footer.focus(permissions: false); footer.focusVisible = true
        }
    }

    /// `composer.mode` aimed at the open picker: focus lands on the footer's permissions trigger.
    func focusPermissions() {
        guard stacked else { return }
        column.blur(); picker.focusRail(false); listFocused = false
        footer.focus(permissions: true)
    }

    /// Tab order: search, list, Reasoning, footer, back to search. Shift-Tab runs backwards, and from the search it goes
    /// up to the provider tabs, as the rail took it before.
    func tab(backward: Bool) {
        let hasReasoning = !column.rows.isEmpty
        let next: Section = switch (section, backward) {
        case (.tabs, false): .search
        case (.search, false): .list
        case (.list, false): hasReasoning ? .reasoning : .footer
        case (.reasoning, false): .footer
        case (.footer, false): .search
        case (.search, true): picker.sections.showsRail ? .tabs : .footer
        case (.tabs, true): .footer
        case (.list, true): .search
        case (.reasoning, true): .list
        case (.footer, true): hasReasoning ? .reasoning : .list
        }
        focus(next)
    }

    private func handleStackedKey(_ key: PopupKey) -> Bool {
        if key == .tab {
            tab(backward: NSApp.currentEvent?.modifierFlags.contains(.shift) == true)
            return true
        }
        if case .character = key, section != .search, section != .tabs {
            // Typing goes to the search from anywhere in the picker.
            focus(.search)
            return false
        }
        switch section {
        case .reasoning: return column.handleKey(key)
        case .footer: return footer.handleKey(key)
        case .list where key == .left || key == .right: return true
        default: return picker.handleKey(key)
        }
    }

    /// Moves keyboard focus into the column (`focusEffort`); false when it has no rows.
    @discardableResult
    func focusEffort(levelsOnly: Bool) -> Bool {
        // From the keyboard (Right, the effort shortcut) the focus shows; after a model click it does not.
        column.focusVisible = NSApp.currentEvent?.type == .keyDown
        let focused = column.focus(levelsOnly: levelsOnly)
        if focused, stacked {
            // The pointer's row keeps its hover; only a keyboard highlight leaves.
            footer.blur(); picker.focusRail(false); listFocused = false
            picker.clearKeyboardHighlight()
        } else if focused {
            picker.highlightedRow = nil
        }
        return focused
    }

    func handleKey(_ key: PopupKey) -> Bool {
        if stacked { return handleStackedKey(key) }
        if column.focusIndex != nil {
            // ArrowLeft in the column returns to the search field (ProviderModelPicker.tsx:482-488).
            if key == .left { column.blur(); window?.makeFirstResponder(picker.search); return true }
            return column.handleKey(key)
        }
        if key == .right, picker.railFocus == nil, caretAtEnd {
            // A highlighted model is picked first; the owner then moves focus to its levels (ModelPickerContent.tsx:1073-1094).
            if let h = picker.highlightedRow, picker.isOtherModel(h) { picker.activate(h); return true }
            focusEffort(levelsOnly: false)
            return true
        }
        return picker.handleKey(key)
    }

    private var caretAtEnd: Bool {
        guard let editor = window?.firstResponder as? NSTextView else { return picker.query.isEmpty }
        return editor.selectedRange().location == (editor.string as NSString).length && editor.selectedRange().length == 0
    }

    override func layout() {
        super.layout()
        if stacked {
            // The host caps the height; the list gives up the space and scrolls.
            let w = bounds.width
            let footerH = footer.stackedHeight(width: w), columnH = column.stackedHeight(width: w)
            let listH = max(0, bounds.height - columnH - footerH)
            picker.frame = NSRect(x: 0, y: 0, width: w, height: listH)
            column.frame = NSRect(x: 0, y: listH, width: w, height: columnH)
            footer.frame = NSRect(x: 0, y: listH + columnH, width: w, height: footerH)
            return
        }
        let list = picker.naturalSize
        picker.frame = NSRect(x: 0, y: 0, width: list.width, height: list.height)
        column.frame = NSRect(x: list.width, y: 0, width: bounds.width - list.width, height: list.height)
        footer.frame = NSRect(x: 0, y: list.height, width: bounds.width, height: ComposerPickerFooterView.height)
    }
}
