import AppKit
import DesignSystem

/// Recovery actions remain in an AppKit sheet, independent of the unavailable server.
public final class StartupRecoveryView: DSView {
    let more = ButtonView("More options if it keeps failing", icon: .chevronDown, variant: .ghost, size: .sm)
    let update = ButtonView("Download update", variant: .outline, size: .sm)
    let updateNote = NSTextField(wrappingLabelWithString: "")
    let guidance = NSTextField(wrappingLabelWithString: "Run this on the computer that runs T3 Code. Your agent can check the local logs and help you file a bug report.")
    let command: NSTextField
    let copyCommand = ButtonView("Copy command", variant: .outline, size: .xs)
    let details = NSTextView()
    private let detailsScroll = NSScrollView()
    let copyDetails = ButtonView("Copy error details", variant: .outline, size: .xs)
    let issue = ButtonView("File a bug report on GitHub", variant: .outline, size: .xs)
    let reinstall = ButtonView("Download and reinstall CandyWrapper", variant: .ghost, size: .xs)
    private let caution = NSTextField(wrappingLabelWithString: "Details may include local file paths and names. Check before sharing.")
    public private(set) var expanded: Bool
    public var onResize: (() -> Void)?
    public var onUpdate: ((StartupRecovery.UpdateAction) -> Void)?
    var copyText: (String) -> Bool = {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString($0, forType: .string)
    }
    private var updateAction: StartupRecovery.UpdateAction?

    public init(command: String, report: String, expanded: Bool) {
        self.command = NSTextField(wrappingLabelWithString: command)
        self.expanded = expanded
        super.init(frame: NSRect(x: 0, y: 0, width: 520, height: 0))
        self.command.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        self.command.isSelectable = true
        self.command.lineBreakMode = .byCharWrapping
        details.string = report
        details.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        details.isEditable = false
        details.isSelectable = true
        details.isHorizontallyResizable = false
        details.isVerticallyResizable = true
        details.minSize = NSSize(width: 0, height: 128)
        details.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        details.frame = NSRect(x: 0, y: 0, width: 520, height: 128)
        details.textContainer?.containerSize = NSSize(width: 520, height: CGFloat.greatestFiniteMagnitude)
        details.textContainer?.widthTracksTextView = true
        details.autoresizingMask = [.width]
        detailsScroll.documentView = details
        detailsScroll.hasVerticalScroller = true
        detailsScroll.borderType = .bezelBorder
        for view in [more, update, updateNote, guidance, self.command, copyCommand, detailsScroll,
                     copyDetails, issue, reinstall, caution] as [NSView] { addSubview(view) }
        for label in [guidance, caution, updateNote] { label.font = .systemFont(ofSize: 11) }
        more.action = { [weak self] in self?.setExpanded(!(self?.expanded ?? false)) }
        update.action = { [weak self] in
            guard let self, let action = self.updateAction else { return }
            self.onUpdate?(action)
        }
        copyCommand.action = { [weak self] in
            guard let self else { return }
            if self.copyText(self.command.stringValue) { self.copyCommand.title = "Copied" }
            else { self.window?.makeFirstResponder(self.command); self.command.selectText(nil) }
        }
        copyDetails.action = { [weak self] in
            guard let self else { return }
            if self.copyText(self.details.string) { self.copyDetails.title = "Copied" }
            else { self.window?.makeFirstResponder(self.details); self.details.selectAll(nil) }
        }
        issue.action = { NSWorkspace.shared.open(StartupRecovery.issueURL) }
        reinstall.action = { NSWorkspace.shared.open(StartupRecovery.downloadURL) }
        setAccessibilityRole(.group)
        setAccessibilityLabel("Startup recovery")
        update.isHidden = true
        updateNote.isHidden = true
        setExpanded(expanded)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setExpanded(_ expanded: Bool) {
        self.expanded = expanded
        more.setAccessibilityExpanded(expanded)
        more.icon = expanded ? .chevronUp : .chevronDown
        for view in [guidance, command, copyCommand, detailsScroll, copyDetails, issue, reinstall, caution] as [NSView] {
            view.isHidden = !expanded
        }
        resize()
    }

    public func setUpdateState(_ state: DesktopUpdateState?) {
        updateAction = StartupRecovery.updateAction(state)
        update.isHidden = updateAction == nil
        update.title = updateAction?.title
        if case .downloading = updateAction { update.isEnabled = false } else { update.isEnabled = true }
        resize()
    }

    public func setUpdateError(_ message: String?) {
        updateNote.stringValue = message ?? ""
        updateNote.isHidden = message == nil
        resize()
    }

    private var commandHeight: CGFloat {
        let size = command.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: max(1, bounds.width - 110), height: .greatestFiniteMagnitude))
        return min(88, max(26, ceil(size?.height ?? 50)))
    }

    private func resize() {
        frame.size.height = 32 + (update.isHidden ? 0 : 36) + (updateNote.isHidden ? 0 : 32) + (expanded ? 272 + commandHeight : 0)
        needsLayout = true
        onResize?()
    }

    public override func layout() {
        super.layout()
        var y: CGFloat = 0
        if !update.isHidden { update.frame = NSRect(x: 0, y: y, width: min(bounds.width, update.intrinsicContentSize.width), height: 28); y += 36 }
        if !updateNote.isHidden { updateNote.frame = NSRect(x: 0, y: y, width: bounds.width, height: 28); y += 32 }
        more.frame = NSRect(x: 0, y: y, width: 280, height: 28)
        y += 36
        guard expanded else { return }
        guidance.frame = NSRect(x: 0, y: y, width: bounds.width, height: 32); y += 36
        command.frame = NSRect(x: 0, y: y, width: bounds.width - 110, height: commandHeight)
        copyCommand.frame = NSRect(x: bounds.width - 104, y: y, width: 104, height: 26); y += commandHeight + 8
        detailsScroll.frame = NSRect(x: 0, y: y, width: bounds.width, height: 128)
        details.frame.size.width = detailsScroll.contentSize.width
        details.sizeToFit()
        y += 136
        caution.frame = NSRect(x: 0, y: y, width: bounds.width, height: 18); y += 24
        copyDetails.frame = NSRect(x: 0, y: y, width: 144, height: 26)
        issue.frame = NSRect(x: 152, y: y, width: 210, height: 26); y += 32
        reinstall.frame = NSRect(x: 0, y: y, width: 288, height: 26)
    }
}
