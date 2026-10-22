import AppKit
import DesignSystem
import T3Store

/// A chip over the Dither composer, after Capy's new-thread page: a 28pt ghost button (`px-1.5`, 6pt corners) with a
/// 14pt icon, 13pt medium text, an optional status dot and a 12pt chevron, `secondary` fill on hover and while open.
/// Measured on Capy's 2x screenshot: text 24 from the chip's left, chevron 6 after the text, the dot 6 wide.
public final class DitherChipView: ControlView {
    static let height: CGFloat = 28
    static var font: NSFont { DSFont.ui(13, weight: .medium) }

    private(set) var icon: NSView
    private let label = LabelView()
    private let chevron = IconView(name: .chevronDown, size: 12)
    /// Redesign's floating pill under the chip, so it never reads as part of the composer.
    private let pill = DitherPillSurface()
    private let fill = CALayer()
    private let dot = CALayer()
    var text = "" {
        didSet {
            guard text != oldValue else { return }
            label.text = text
            setAccessibilityValue(text)
            changed()
        }
    }
    /// The machine chip's text is `muted-foreground-1`; the project chip's is `foreground`.
    var muted = false { didSet { restyle() } }
    /// The machine's online dot.
    var online: Bool? { didSet { if online != oldValue { changed() } } }
    /// Without a choice the chip is a static label: no chevron, no hover.
    var interactive = true { didSet { if interactive != oldValue { changed() } } }

    init(icon: NSView, accessibilityLabel: String) {
        self.icon = icon
        super.init(frame: .zero)
        scalesWhenPressed = false
        for l in [fill, dot] { l.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()] }
        fill.cornerRadius = DitherChrome.controlRadius
        dot.cornerRadius = 3
        layer?.masksToBounds = false
        addSubview(pill)
        layer?.addSublayer(fill)
        layer?.addSublayer(dot)
        label.font = Self.font
        label.lineHeight = 16
        addSubview(icon)
        addSubview(label)
        addSubview(chevron)
        setAccessibilityLabel(accessibilityLabel)
        changed()
    }

    func replaceIcon(_ new: NSView) {
        guard new !== icon else { return }
        icon.removeFromSuperview()
        icon = new
        addSubview(new)
        restyle()
        needsLayout = true
    }

    private func changed() {
        chevron.isHidden = !interactive
        dot.isHidden = online == nil
        setAccessibilityRole(interactive ? .popUpButton : .staticText)
        invalidateIntrinsicContentSize()
        restyle()
        needsLayout = true
        superview?.needsLayout = true
    }

    private var textWidth: CGFloat { min(240, ceil(label.textWidth)) }

    public override var intrinsicContentSize: NSSize {
        var w = 6 + 14 + 4 + textWidth
        if online != nil { w += 5 + 6 }
        if interactive { w += 6 + 12 - 2 }
        return NSSize(width: w + 6, height: Self.height)
    }

    public override func layout() {
        super.layout()
        let midY = bounds.height / 2
        pill.frame = bounds
        icon.frame = NSRect(x: 6, y: midY - 7, width: 14, height: 14)
        label.frame = NSRect(x: 24, y: midY - 8, width: textWidth, height: 16)
        var x = label.frame.maxX
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fill.frame = bounds
        if online != nil {
            dot.frame = CGRect(x: x + 5, y: midY - 3, width: 6, height: 6)
            x += 11
        }
        CATransaction.commit()
        chevron.frame = NSRect(x: x + 4, y: midY - 6, width: 12, height: 12)
    }

    public override func stateDidChange(from old: State) {
        super.stateDidChange(from: old)
        restyle()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    public override func updateLayer() {
        fill.backgroundColor = interactive && state.hoverOrPressed
            ? (effectiveAppearance.isDark ? Themed.white(0.08) : Themed.black(0.05)).cgColor : nil
        dot.backgroundColor = (online == true ? Themed.color(\.success) : Themed.color(\.secondaryLabel)).cgColor(in: self)
    }

    private func restyle() {
        let lit = interactive && state.hoverOrPressed
        label.color = muted && !lit ? Themed.color(\.mutedForeground) : Themed.color(\.foreground)
        let iconColor = muted && !lit ? Themed.color(\.mutedForeground) : Themed.color(\.foreground, 0.85)
        (icon as? IconView)?.strokeColor = iconColor
        chevron.strokeColor = Themed.color(\.secondaryLabel)
        needsDisplay = true
    }

    public override func resetCursorRects() {
        if interactive { super.resetCursorRects() }
    }

    public override func performAction() {
        guard interactive else { return }
        super.performAction()
    }
}

/// Capy's project popover from the new-thread project chip, under Dither: a 256pt popover (`--popover`, 8pt corners,
/// 0.5pt `--border-1`, `--sh-overlay`) with "Search projects" on top, the projects (icon, name, check on the open one),
/// "No project" with its machine muted on the right, then "New project" and "Manage projects". Sections are 4pt
/// padded 28pt menu rows split by 0.5pt hairlines. Typing filters the projects; arrows and Enter move and pick.
public final class DitherProjectPopoverView: DSView, PopupContent {
    public enum Choice: Equatable { case project(String), noProject, newProject, manageProjects }

    struct Project: Equatable { var key: String; var label: String; var icon: ProjectIconSource? }

    static let width: CGFloat = 256, rowHeight: CGFloat = 28, searchHeight: CGFloat = 36, maxProjectRows = 8

    let projects: [Project]
    let selectedKey: String?
    /// The scratch machine's label; nil hides "No project".
    let noProjectMachine: String?
    let isScratch: Bool
    private(set) var shown: [Project]
    var onChoose: (@MainActor (Choice) -> Void)?

    let search = InputView(placeholder: "Search projects", size: .find)
    private var rows: [DitherMenuRowView] = []
    private let projectList = DSView()
    private var hairlines: [CALayer] = []
    private var scrollOffset: CGFloat = 0
    var highlighted: Int? { didSet { if highlighted != oldValue { rows.enumerated().forEach { $1.highlighted = $0 == highlighted }; scrollToHighlight() } } }

    public convenience init(groups: [SidebarModel.ProjectGroup], selectedKey: String?, noProjectMachine: String?, isScratch: Bool) {
        self.init(projects: groups.map { Project(key: $0.key, label: $0.label, icon: ProjectIconSource($0.representative)) },
                  selectedKey: selectedKey, noProjectMachine: noProjectMachine, isScratch: isScratch)
    }

    init(projects: [Project], selectedKey: String?, noProjectMachine: String?, isScratch: Bool) {
        self.projects = projects
        self.selectedKey = selectedKey
        self.noProjectMachine = noProjectMachine
        self.isScratch = isScratch
        shown = projects
        super.init(frame: .zero)
        layer?.masksToBounds = false
        search.unstyled = true
        search.paddingOverride = (0, 0)
        search.setAccessibilityLabel("Search projects")
        search.onChange = { [weak self] text in self?.setQuery(text) }
        addSubview(search)
        projectList.clipsToBounds = true
        addSubview(projectList)
        setAccessibilityRole(.menu)
        reload()
    }

    /// Case- and diacritic-insensitive `contains` on the project names, as the stock picker filters.
    static func filter(_ projects: [Project], query: String) -> [Project] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return projects }
        return projects.filter { $0.label.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    func setQuery(_ text: String) {
        shown = Self.filter(projects, query: text)
        scrollOffset = 0
        reload()
        highlighted = text.trimmingCharacters(in: .whitespaces).isEmpty || shown.isEmpty ? nil : 0
        if let host = popupHost, let popup = host.popups.first(where: { $0.content === self }) { host.reposition(popup) }
    }

    /// Every pickable row in order: the shown projects, then the fixed rows.
    private var choices: [Choice] {
        shown.map { .project($0.key) } + (noProjectMachine != nil ? [.noProject] : []) + [.newProject, .manageProjects]
    }

    private func reload() {
        rows.forEach { $0.removeFromSuperview() }
        rows = choices.enumerated().map { i, choice in
            let row: DitherMenuRowView
            switch choice {
            case .project(let key):
                let project = shown.first { $0.key == key }!
                let monogram = ProjectMonogramView(frame: NSRect(x: 0, y: 0, width: 14, height: 14))
                monogram.projectTitle = project.label
                monogram.source = project.icon
                monogram.scale = 14 / 16
                row = DitherMenuRowView(icon: monogram, title: project.label, checked: !isScratch && key == selectedKey)
                projectList.addSubview(row)
            case .noProject:
                row = DitherMenuRowView(icon: IconView(name: .folder, size: 14), title: "No project", trailing: noProjectMachine, checked: isScratch)
                addSubview(row)
            case .newProject:
                row = DitherMenuRowView(icon: IconView(name: .plus, size: 14), title: "New project")
                addSubview(row)
            case .manageProjects:
                row = DitherMenuRowView(icon: IconView(name: .settings, size: 14), title: "Manage projects")
                addSubview(row)
            }
            row.onHover = { [weak self] in self?.highlighted = i }
            row.action = { [weak self] in self?.onChoose?(choice) }
            return row
        }
        let sections = (shown.isEmpty ? 0 : 1) + (noProjectMachine != nil ? 1 : 0)
        hairlines.forEach { $0.removeFromSuperlayer() }
        hairlines = (0...sections).map { _ in
            let l = CALayer()
            l.actions = ["position": NSNull(), "bounds": NSNull()]
            layer?.addSublayer(l)
            return l
        }
        updateLayer()
        needsLayout = true
    }

    private var visibleProjectRows: Int { min(shown.count, Self.maxProjectRows) }
    /// The project rows that fit once PopupHost caps the height to the space on its side: the list scrolls
    /// and the footer rows stay inside the popup.
    private var fittedProjectRows: Int {
        let natural = popupSize.height
        guard bounds.height > 0, bounds.height < natural else { return visibleProjectRows }
        let spare = bounds.height - (natural - CGFloat(visibleProjectRows) * Self.rowHeight)
        return min(visibleProjectRows, max(1, Int((spare / Self.rowHeight).rounded(.down))))
    }
    private var projectSectionHeight: CGFloat { shown.isEmpty ? 0 : 8 + CGFloat(visibleProjectRows) * Self.rowHeight + 0.5 }

    public var popupSize: CGSize {
        let noProject: CGFloat = noProjectMachine != nil ? 8 + Self.rowHeight + 0.5 : 0
        return CGSize(width: Self.width, height: Self.searchHeight + 0.5 + projectSectionHeight + noProject + 8 + 2 * Self.rowHeight)
    }
    public override var intrinsicContentSize: NSSize { popupSize }
    public var frostRadius: CGFloat { DitherChrome.cardRadius }

    public override func layout() {
        super.layout()
        // The search text sits 13 in, like the rows' icons (4 inset + 8 padding, +1 for the caret).
        search.frame = NSRect(x: 12, y: 4, width: bounds.width - 24, height: 28)
        var y = Self.searchHeight
        var line = 0
        func hairline() {
            guard line < hairlines.count else { return }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            hairlines[line].frame = CGRect(x: 0, y: y, width: bounds.width, height: 0.5)
            CATransaction.commit()
            line += 1
            y += 0.5
        }
        hairline()
        var i = 0
        if !shown.isEmpty {
            let listHeight = CGFloat(fittedProjectRows) * Self.rowHeight
            projectList.frame = NSRect(x: 0, y: y + 4, width: bounds.width, height: listHeight)
            scrollOffset = min(scrollOffset, maxScroll)
            for r in 0..<shown.count {
                rows[i].frame = NSRect(x: 4, y: CGFloat(r) * Self.rowHeight - scrollOffset, width: bounds.width - 8, height: Self.rowHeight)
                i += 1
            }
            y += 8 + listHeight
            hairline()
        }
        projectList.isHidden = shown.isEmpty
        if noProjectMachine != nil {
            rows[i].frame = NSRect(x: 4, y: y + 4, width: bounds.width - 8, height: Self.rowHeight)
            i += 1
            y += 8 + Self.rowHeight
            hairline()
        }
        for r in 0..<2 where i + r < rows.count {
            rows[i + r].frame = NSRect(x: 4, y: y + 4 + CGFloat(r) * Self.rowHeight, width: bounds.width - 8, height: Self.rowHeight)
        }
    }

    private var maxScroll: CGFloat { max(0, CGFloat(shown.count - fittedProjectRows) * Self.rowHeight) }

    private func scrollToHighlight() {
        guard let i = highlighted, i < shown.count else { return }
        let top = CGFloat(i) * Self.rowHeight, visible = CGFloat(fittedProjectRows) * Self.rowHeight
        if top < scrollOffset { scrollOffset = top } else if top + Self.rowHeight > scrollOffset + visible { scrollOffset = top + Self.rowHeight - visible }
        needsLayout = true
    }

    public override func scrollWheel(with event: NSEvent) {
        scrollOffset = min(max(0, scrollOffset - event.scrollPointsY), maxScroll)
        needsLayout = true
    }

    public override func updateLayer() {
        let dark = effectiveAppearance.isDark
        layer?.backgroundColor = Themed.color(\.popover).cgColor(in: self)
        layer?.cornerRadius = DitherChrome.cardRadius
        layer?.borderWidth = 0.5
        layer?.borderColor = (dark ? Themed.white(0.08) : Themed.black(0.08)).cgColor
        // `--sh-overlay`, its widest layer: 0 3 8 /.13 dark, 0 6 18 /.03 light, plus the 1px contact shadow folded in.
        layer?.shadowColor = Themed.black(1).cgColor
        layer?.shadowOpacity = dark ? 0.26 : 0.08
        layer?.shadowRadius = dark ? 6 : 9
        layer?.shadowOffset = CGSize(width: 0, height: dark ? -3 : -4)
        for l in hairlines { l.backgroundColor = (dark ? Themed.white(0.08) : Themed.black(0.08)).cgColor }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    public func popupHandleKey(_ key: PopupKey) -> Bool {
        switch key {
        case .down, .up:
            let n = rows.count
            guard n > 0 else { return true }
            if let h = highlighted { highlighted = (h + (key == .down ? 1 : -1) + n) % n } else { highlighted = key == .down ? 0 : n - 1 }
            return true
        case .enter:
            if let h = highlighted, choices.indices.contains(h) { onChoose?(choices[h]) }
            return true
        default:
            return false
        }
    }
}

/// One 28pt row of the Dither project popover: `px-2 gap-2`, a 14pt muted icon, 13pt text, an optional muted
/// trailing label and a check. `--popover-hover` fill, 6pt corners, while highlighted.
final class DitherMenuRowView: ControlView {
    private let icon: NSView
    private let label = LabelView()
    private let trailing: LabelView?
    private let check: IconView?
    private let fill = CALayer()
    var highlighted = false { didSet { if highlighted != oldValue { needsDisplay = true } } }
    var onHover: (@MainActor () -> Void)?

    init(icon: NSView, title: String, trailing: String? = nil, checked: Bool = false) {
        self.icon = icon
        self.trailing = trailing.map { LabelView($0, font: DSFont.ui(13)) }
        check = checked ? IconView(name: .check, size: 14) : nil
        super.init(frame: .zero)
        scalesWhenPressed = false
        fill.cornerRadius = DitherChrome.controlRadius
        fill.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(fill)
        label.text = title
        label.font = DSFont.ui(13)
        label.lineHeight = 16
        self.trailing?.lineHeight = 16
        for v in [icon, label, self.trailing, check].compactMap({ $0 }) { addSubview(v) }
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(title)
        if checked { setAccessibilityValue("Selected") }
        restyle()
    }

    override func layout() {
        super.layout()
        let midY = bounds.height / 2
        icon.frame = NSRect(x: 8, y: midY - 7, width: 14, height: 14)
        var right = bounds.width - 8
        if let check { check.frame = NSRect(x: right - 14, y: midY - 7, width: 14, height: 14); right -= 14 + 8 }
        if let trailing {
            let w = ceil(trailing.textWidth)
            trailing.frame = NSRect(x: right - w, y: midY - 8, width: w, height: 16)
            right -= w + 8
        }
        label.frame = NSRect(x: 30, y: midY - 8, width: max(0, right - 30), height: 16)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fill.frame = bounds
        CATransaction.commit()
    }

    override func stateDidChange(from old: State) {
        super.stateDidChange(from: old)
        if state.hovered, !old.hovered { onHover?() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    override func updateLayer() {
        fill.backgroundColor = highlighted ? (effectiveAppearance.isDark ? Themed.white(0.065) : Themed.black(0.04)).cgColor : nil
    }

    private func restyle() {
        label.color = Themed.color(\.foreground)
        trailing?.color = Themed.color(\.secondaryLabel)
        (icon as? IconView)?.strokeColor = Themed.color(\.mutedForeground, 0.8)
        check?.strokeColor = Themed.color(\.foreground)
        needsDisplay = true
    }
}

extension DitherProjectPopoverView {
    /// Opens the popover under `anchor`, start-aligned 4 below, with the search field focused.
    @discardableResult
    public static func show(groups: [SidebarModel.ProjectGroup], selectedKey: String?, noProjectMachine: String?, isScratch: Bool,
                            from anchor: NSView, onChoose: @escaping @MainActor (Choice) -> Void) -> OpenPopup? {
        guard let host = anchor.popupHost else { return nil }
        let view = DitherProjectPopoverView(groups: groups, selectedKey: selectedKey, noProjectMachine: noProjectMachine, isScratch: isScratch)
        weak var popup: OpenPopup?
        view.onChoose = { choice in
            if let popup { host.close(popup, returnFocus: false) }
            onChoose(choice)
        }
        popup = host.open(view, trigger: anchor, placement: .dropdown, motion: .popover, swallowsOutsideClick: true)
        anchor.window?.makeFirstResponder(view.search)
        return popup
    }
}
