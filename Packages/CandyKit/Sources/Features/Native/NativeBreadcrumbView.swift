import AppKit
import DesignSystem

/// Glass Native's toolbar title: T3's thread breadcrumb (ChatHeader.tsx:262-375), the project, the parent of a
/// subagent, then the thread title, with the same clicks as the hidden `ThreadHeaderView`. The project starts a new
/// thread in it, the parent opens, a click on the title opens the thread menu and a double click renames in place.
/// A page with no thread (Settings, Pull Requests) shows its name alone.
public final class NativeBreadcrumbView: NSView, NSTextFieldDelegate {
    private weak var header: ThreadHeaderView?
    private let project = NSButton(title: "", target: nil, action: nil)
    /// The project's icon chip before its name, as the classic header and T3 show it.
    private let favicon = ProjectMonogramView(frame: NSRect(x: 0, y: 0, width: 14, height: 14))
    private let parent = NSButton(title: "", target: nil, action: nil)
    private let slash = NativeBreadcrumbView.label("/")
    private let parentSlash = NativeBreadcrumbView.label("/")
    private let title = NativeBreadcrumbTitle()
    private let editor = NSTextField(string: "")
    private var page: String?

    public init(header: ThreadHeaderView) {
        self.header = header
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 28))
        // The toolbar sizes the item from the intrinsic width, so the title gets the room it needs.
        translatesAutoresizingMaskIntoConstraints = false
        setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        widthConstraint.isActive = true
        for button in [project, parent] {
            button.isBordered = false
            button.target = self
            // Every crumb is `font-medium`, the project in `text-muted-foreground` (WorkspaceBreadcrumb.tsx:52-57).
            button.font = .systemFont(ofSize: 14, weight: .medium)
            button.contentTintColor = .secondaryLabelColor
            button.lineBreakMode = .byTruncatingTail
            addSubview(button)
        }
        project.action = #selector(pressProject)
        parent.action = #selector(pressParent)
        project.toolTip = "New thread in this project"
        addSubview(slash)
        addSubview(favicon)
        addSubview(parentSlash)
        title.onClick = { [weak self] event in
            guard let self, let header = self.header else { return }
            if event.clickCount >= 2 { header.beginTitleRename() } else { header.onThreadMenu?(event, self.title) }
        }
        addSubview(title)
        editor.isHidden = true
        editor.font = .systemFont(ofSize: 14, weight: .medium)
        editor.delegate = self
        editor.focusRingType = .none
        addSubview(editor)
        header.renameInPlace = { [weak self] in self?.beginRename() }
        setAccessibilityRole(.group)
        setAccessibilityLabel("Thread breadcrumb")
        update()
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 14, weight: .regular)
        field.textColor = .tertiaryLabelColor
        return field
    }

    /// The page's name in place of the crumbs, or nil for the thread.
    public func show(page: String?) {
        self.page = page
        update()
    }

    /// Reads the header again; call when its titles change.
    public func update() {
        let threadShown = page == nil && !(header?.threadTitle.isEmpty ?? true)
        let projectTitle = page == nil ? header?.projectTitle ?? "" : ""
        let parentTitle = page == nil ? header?.parentThreadTitle : nil
        project.title = projectTitle
        project.isHidden = projectTitle.isEmpty
        favicon.isHidden = projectTitle.isEmpty
        favicon.projectTitle = projectTitle
        favicon.source = page == nil ? header?.projectIcon : nil
        slash.isHidden = projectTitle.isEmpty || !threadShown
        parent.title = parentTitle ?? ""
        parent.isHidden = parentTitle == nil || !threadShown
        parentSlash.isHidden = parent.isHidden
        title.text = page ?? header?.threadTitle ?? ""
        title.isHidden = title.text.isEmpty
        title.isInteractive = page == nil
        title.setAccessibilityLabel(page == nil ? "Thread actions for \(title.text)" : title.text)
        needsLayout = true; resize()
    }

    @objc private func pressProject() { header?.onNewThreadInProject?() }
    @objc private func pressParent() { header?.onOpenParent?() }

    private func beginRename() {
        editor.stringValue = header?.threadTitle ?? ""
        editor.isHidden = false
        title.isHidden = true
        needsLayout = true; resize()
        window?.makeFirstResponder(editor)
        editor.currentEditor()?.selectAll(nil)
    }

    public func controlTextDidEndEditing(_ obj: Notification) {
        guard !editor.isHidden else { return }
        let cancelled = (obj.userInfo?["NSTextMovement"] as? Int) == NSTextMovement.cancel.rawValue
        editor.isHidden = true
        title.isHidden = false
        if !cancelled { header?.commitRename(editor.stringValue) }
        needsLayout = true; resize()
    }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        editor.isHidden = true
        title.isHidden = false
        window?.makeFirstResponder(nil)
        needsLayout = true; resize()
        return true
    }

    /// The toolbar measures the item once; an explicit width it follows when the crumbs change.
    private lazy var widthConstraint = widthAnchor.constraint(equalToConstant: 200)
    private func resize() {
        invalidateIntrinsicContentSize()
        let width = intrinsicContentSize.width
        if widthConstraint.constant != width { widthConstraint.constant = width }
        if frame.width != width { setFrameSize(NSSize(width: width, height: 28)) }
        superview?.needsLayout = true
        superview?.invalidateIntrinsicContentSize()
    }

    /// As wide as its crumbs, up to 640, so the toolbar gives the title the room T3's header would.
    public override var intrinsicContentSize: NSSize {
        let views: [NSView] = [project, slash, parent, parentSlash, editor.isHidden ? title : editor]
        let width = views.filter { !$0.isHidden }.reduce(CGFloat(0)) { $0 + ceil($1 === editor ? 240 : $1.intrinsicContentSize.width) + Self.gap }
        // Slack, because the toolbar rounds the item narrower than the sum by a few points.
        return NSSize(width: min(640, max(120, width + 24 + (favicon.isHidden ? 0 : 20))), height: 28)
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        placeCrumbs()
    }

    public override func layout() {
        super.layout()
        placeCrumbs()
    }

    /// The crumbs' `gap-3` (WorkspaceBreadcrumb.tsx:16); the favicon keeps its `gap-1.5` to the name.
    private static let gap: CGFloat = 12

    private func placeCrumbs() {
        var x: CGFloat = 0
        let h = bounds.height
        func place(_ view: NSView, maxWidth: CGFloat) {
            guard !view.isHidden else { return }
            let size = view.intrinsicContentSize
            let w = min(ceil(size.width), max(0, maxWidth))
            view.frame = NSRect(x: x, y: ((h - size.height) / 2).rounded(), width: w, height: size.height)
            x += w + Self.gap
        }
        let room = bounds.width
        if !favicon.isHidden {
            favicon.frame = NSRect(x: x, y: ((h - 14) / 2).rounded(), width: 14, height: 14)
            x += 14 + 6
        }
        place(project, maxWidth: room * 0.35)
        place(slash, maxWidth: 12)
        place(parent, maxWidth: room * 0.25)
        place(parentSlash, maxWidth: 12)
        if !editor.isHidden {
            editor.frame = NSRect(x: x, y: ((h - 22) / 2).rounded(), width: max(120, min(360, bounds.width - x)), height: 22)
        } else {
            place(title, maxWidth: bounds.width - x)
        }
    }
}

/// The breadcrumb's title: medium, a chevron after it that shows on hover only (ChatHeader.tsx:346-350, `opacity-0`
/// until `group-hover`), a click opens the thread menu (ThreadHeaderTitleView's clicks, sent through the header's
/// `onThreadMenu`).
final class NativeBreadcrumbTitle: NSView {
    var onClick: ((NSEvent) -> Void)?
    var isInteractive = true
    private let label = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue; invalidateIntrinsicContentSize(); needsLayout = true }
    }

    init() {
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        chevron.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        chevron.contentTintColor = .secondaryLabelColor
        chevron.alphaValue = 0
        addSubview(label)
        addSubview(chevron)
        setAccessibilityRole(.button)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        let size = label.intrinsicContentSize
        return NSSize(width: ceil(size.width) + 6 + (isInteractive ? 14 : 0), height: size.height)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        placeContent()
    }

    override func layout() {
        super.layout()
        placeContent()
    }

    private func placeContent() {
        chevron.isHidden = !isInteractive
        let w = max(0, bounds.width - (isInteractive ? 14 : 0))
        label.frame = NSRect(x: 0, y: 0, width: w, height: bounds.height)
        chevron.frame = NSRect(x: w + 3, y: (bounds.height - 10) / 2, width: 10, height: 10)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { chevron.alphaValue = 1 }
    override func mouseExited(with event: NSEvent) { chevron.alphaValue = 0 }

    /// A single click waits out the double-click interval before the menu opens, as the classic title does.
    private var pending: DispatchWorkItem?
    override func mouseDown(with event: NSEvent) {
        guard isInteractive else { return }
        pending?.cancel()
        if event.clickCount >= 2 { onClick?(event); return }
        let work = DispatchWorkItem { [weak self] in self?.onClick?(event) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
    }
    override func rightMouseDown(with event: NSEvent) { pending?.cancel(); if isInteractive { onClick?(event) } }
    override func accessibilityPerformPress() -> Bool {
        guard isInteractive, let event = NSApp.currentEvent else { return false }
        onClick?(event)
        return true
    }
}
