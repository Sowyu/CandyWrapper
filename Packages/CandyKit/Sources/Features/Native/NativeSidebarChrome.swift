import AppKit

/// The top of Glass Native's sidebar: a search field with the filter menu beside it, as in Mail and Notes, then
/// T3 Mobile's "Threads | Pull requests" picker (WorkspaceSidebarTabs.ios.tsx:15-35).
final class NativeSidebarChrome: NSView, NSSearchFieldDelegate {
    let search = NSSearchField()
    let filter = NSButton()
    let segments = NSSegmentedControl(labels: ["Threads", "Pull requests"], trackingMode: .selectOne, target: nil, action: nil)
    static let height: CGFloat = 66
    var onChange: ((String) -> Void)?
    /// The field's key commands (arrows, Return, Escape) while searching; true when handled.
    var onCommand: ((Selector) -> Bool)?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        search.placeholderString = "Search threads"
        search.sendsSearchStringImmediately = true
        search.controlSize = .regular
        search.delegate = self
        search.target = self
        search.action = #selector(searchChanged)
        filter.bezelStyle = .accessoryBarAction
        filter.isBordered = false
        filter.imagePosition = .imageOnly
        filter.toolTip = "Filter threads"
        filter.setAccessibilityLabel("Filter threads")
        filterActive = false
        segments.segmentDistribution = .fillEqually
        segments.controlSize = .regular
        segments.selectedSegment = 0
        for v in [search, filter, segments] as [NSView] { addSubview(v) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// A project or environment filter applies: the button fills.
    var filterActive = false {
        didSet {
            let name = filterActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"
            filter.image = NSImage(systemSymbolName: name, accessibilityDescription: "Filter threads")?
                .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
            filter.contentTintColor = filterActive ? .controlAccentColor : .secondaryLabelColor
        }
    }

    @objc private func searchChanged() { onChange?(search.stringValue) }
    func controlTextDidChange(_ obj: Notification) { onChange?(search.stringValue) }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool { onCommand?(selector) ?? false }

    override func layout() {
        super.layout()
        let w = bounds.width, x: CGFloat = 10
        filter.frame = NSRect(x: w - x - 26, y: 2, width: 26, height: 24)
        search.frame = NSRect(x: x, y: 0, width: max(0, filter.frame.minX - 4 - x), height: 28)
        segments.frame = NSRect(x: x, y: 38, width: w - 2 * x, height: 24)
    }
}
