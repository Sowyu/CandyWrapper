import AppKit

/// The sidebar's search row in Glass Native, where T3 Code desktop has it (SidebarThreadHeader.tsx): the search
/// field, then the project filter and Add project. New thread lives in the toolbar.
final class NativeSidebarChrome: NSView, NSSearchFieldDelegate {
    let search = NSSearchField()
    let filter = NativeSidebarChrome.iconButton("folder", "Filter threads by project")
    let addProject = NativeSidebarChrome.iconButton("folder.badge.plus", "Add project")
    var onChange: ((String) -> Void)?
    /// The field's key commands (arrows, Return, Escape) while searching; true when handled.
    var onCommand: ((Selector) -> Bool)?
    /// Without projects there is nothing to scope or add to (SidebarThreadHeader.tsx:127-135).
    var hasProjects = true { didSet { if hasProjects != oldValue { needsLayout = true } } }

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        search.placeholderString = "Search"
        search.sendsSearchStringImmediately = true
        search.delegate = self
        search.target = self
        search.action = #selector(searchChanged)
        for v in [search, filter, addProject] as [NSView] { addSubview(v) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    static func iconButton(_ symbol: String, _ label: String) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: nil, action: nil)
        b.bezelStyle = .accessoryBarAction
        b.isBordered = false
        b.imagePosition = .imageOnly
        b.contentTintColor = .secondaryLabelColor
        b.toolTip = label
        b.setAccessibilityLabel(label)
        return b
    }

    /// The project scope applies: the folder fills and names the project.
    func setScope(_ label: String?) {
        filter.image = NSImage(systemSymbolName: label == nil ? "folder" : "folder.fill", accessibilityDescription: nil)
        filter.contentTintColor = label == nil ? .secondaryLabelColor : .controlAccentColor
        let text = label.map { "Filter threads by project: \($0)" } ?? "Filter threads by project"
        filter.toolTip = text
        filter.setAccessibilityLabel(text)
    }

    @objc private func searchChanged() { onChange?(search.stringValue) }
    func controlTextDidChange(_ obj: Notification) { onChange?(search.stringValue) }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool { onCommand?(selector) ?? false }

    override func layout() {
        super.layout()
        // The classic row: `p-2`, a 32pt search, then 28pt icon buttons from the right.
        var right = bounds.width - 8
        for b in [addProject, filter] {
            b.isHidden = !hasProjects
            if b.isHidden { continue }
            b.frame = NSRect(x: right - 28, y: 2, width: 28, height: 28)
            right -= 28
        }
        search.frame = NSRect(x: 8, y: 2, width: max(0, right - 4 - 8), height: 28)
    }
}

/// The sidebar's footer in Glass Native, where T3 Code desktop has it (SidebarChrome.tsx): Settings, Pull Requests
/// and Usage as icon buttons, or Back on a utility page.
final class NativeSidebarFooter: NSView {
    let settings = NativeSidebarFooter.button("gearshape", "Settings")
    let pullRequests = NativeSidebarFooter.button("arrow.triangle.pull", "Pull Requests")
    let usage = NativeSidebarFooter.button("chart.bar", "Usage")
    let back = NSButton(title: "Back", image: NSImage(systemSymbolName: "arrow.left", accessibilityDescription: nil)!, target: nil, action: nil)
    var showsBack = false { didSet { needsLayout = true } }
    var showsPullRequests = true { didSet { needsLayout = true } }
    /// Room the update pill takes at the right end.
    var trailingRoom: CGFloat = 0 { didSet { needsLayout = true } }

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        back.imagePosition = .imageLeading
        back.alignment = .left
        Self.plain(back)
        for v in [settings, pullRequests, usage, back] as [NSView] { addSubview(v) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    static func button(_ symbol: String, _ label: String) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: nil, action: nil)
        b.imagePosition = .imageOnly
        b.toolTip = label
        b.setAccessibilityLabel(label)
        plain(b)
        return b
    }

    /// Plain system buttons; the design pass sets the final material.
    static func plain(_ b: NSButton) {
        b.bezelStyle = .accessoryBarAction
        b.isBordered = false
        b.contentTintColor = .secondaryLabelColor
    }

    override func layout() {
        super.layout()
        // `SidebarMenu`: 32pt icon buttons 4pt apart from the left, or Back across the row.
        var x: CGFloat = 8
        for b in [settings, pullRequests, usage] {
            b.isHidden = showsBack || b === pullRequests && !showsPullRequests
            if b.isHidden { continue }
            b.frame = NSRect(x: x, y: 0, width: 32, height: 32)
            x += 36
        }
        back.isHidden = !showsBack
        back.frame = NSRect(x: 8, y: 0, width: max(0, bounds.width - 16 - trailingRoom), height: 32)
    }
}
