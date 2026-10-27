import AppKit
import DesignSystem
import T3Protocol

/// "Share with guest" (GuestShareControls.tsx:79-185): a `max-w-lg` dialog. Before a link exists it says how the
/// link works, with Cancel and Create link; after, it shows the link with Copy, and Done. A failure shows under
/// the body in `text-destructive text-xs`. The caller runs `guestShare.create` from `onCreate` and reports back.
@MainActor
public final class GuestShareDialog {
    public enum State: Equatable { case idle, creating, created(url: String), failed(String) }

    public let dialog: DialogView
    public let cancel = ButtonView("Cancel", variant: .outline, size: .sm)
    public let create = ButtonView("Create link", variant: .default, size: .sm)
    public let done = ButtonView("Done", variant: .default, size: .sm)
    public let copy = ButtonView("Copy", icon: .copy, variant: .outline, size: .sm)
    public let link = InputView()
    let body = Paragraph(font: DSFont.ui(14), lineHeight: 20, color: Themed.color(\.mutedForeground))
    private let error = Paragraph(font: DSFont.ui(12), lineHeight: 16, color: Themed.color(\.destructive))
    private let linkRow: LinkRow
    private var copiedReset: DispatchWorkItem?

    public private(set) var state: State = .idle { didSet { update() } }
    /// The thread already has a share, so a new link ends it.
    public var hasActiveShare: Bool { didSet { update() } }
    /// `guestShare.create`'s permission.
    public var canCreate: Bool { didSet { update() } }
    public var onCreate: (() -> Void)?
    public var onClose: (() -> Void)?
    /// Copies the link; the button says "Copied" for 2 seconds (`useCopyToClipboard`'s timeout).
    public var onCopy: ((String) -> Void)?

    public init(hasActiveShare: Bool, canCreate: Bool) {
        self.hasActiveShare = hasActiveShare
        self.canCreate = canCreate
        dialog = DialogView(kind: .dialog, title: "Share with guest",
                            message: "The guest sees the thread as you do, including command output and the agent's reasoning. Each message they send waits for you.")
        dialog.maxWidth = 512
        link.setAccessibilityLabel("Guest link")
        link.isReadOnly = true
        link.onStateChange = { [weak link] s in if s.focused { link?.selectAll() } }
        linkRow = LinkRow(input: link, copy: copy)
        cancel.action = { [weak self] in self?.close() }
        done.action = { [weak self] in self?.close() }
        create.action = { [weak self] in
            guard let self, self.canCreate, self.state != .creating else { return }
            self.state = .creating
            self.onCreate?()
        }
        copy.action = { [weak self] in
            guard let self, case .created(let url) = self.state else { return }
            self.onCopy?(url)
            self.copy.title = "Copied"
            self.copy.icon = .check
            self.copiedReset?.cancel()
            let reset = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.copy.title = "Copy"; self?.copy.icon = .copy }
            }
            self.copiedReset = reset
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: reset)
        }
        update()
    }

    /// Follows the thread's own projection while the dialog shows, as T3's dialog reads `thread.guestShare` through
    /// `useQuietThreadProjection` (GuestShareControls.tsx:44-46, 72), so a thread shared from the sidebar warns too.
    /// `watchThread` is `ThreadLineageController.watchThread`; call the returned closure when the dialog closes.
    public func follow(_ threadId: ThreadId, watchThread: ((ThreadId, @escaping @MainActor @Sendable (ThreadProjection) -> Void) -> (@MainActor () -> Void))?) -> @MainActor () -> Void {
        guard let watchThread else { return {} }
        return watchThread(threadId) { [weak self] projection in
            guard let self else { return }
            let active = projection.thread.guestShare != nil
            if self.hasActiveShare != active { self.hasActiveShare = active }
        }
    }

    public func succeeded(url: String) { state = .created(url: url) }
    public func failed(_ message: String) { state = .failed(message) }
    /// The call was interrupted: back to the start, as T3 does.
    public func reset() { state = .idle }

    /// Escape or the close button: ignored while a link is being made (`onOpenChange`).
    public var canClose: Bool { state != .creating }

    private func close() {
        guard canClose else { return }
        onClose?()
    }

    private func update() {
        if case .created(let url) = state {
            if link.text != url { link.text = url }
            dialog.panelContent = [linkRow]
            dialog.footerButtons = [done]
        } else {
            body.text = hasActiveShare ? "A new link ends the current one." : "The link works once and expires in 24 hours."
            if case .failed(let message) = state { error.text = message } else { error.text = "" }
            let content: [NSView] = error.text.isEmpty ? [body] : [body, error]
            if dialog.panelContent != content { dialog.panelContent = content }
            if dialog.footerButtons != [cancel, create] { dialog.footerButtons = [cancel, create] }
        }
        let creating = state == .creating
        cancel.isEnabled = !creating
        create.isEnabled = canCreate && !creating
        create.title = creating ? "Creating..." : "Create link"
        dialog.showsCloseButton = !creating
        dialog.invalidateIntrinsicContentSize()
        dialog.needsLayout = true
        dialog.superview?.needsLayout = true
    }

    /// A wrapping paragraph sized at the dialog panel's width (`max-w-lg` less `p-6`) until it is laid out.
    final class Paragraph: DSView {
        private let block: TextBlockView
        var text: String {
            get { block.text }
            set { block.text = newValue; invalidateIntrinsicContentSize() }
        }
        init(font: NSFont, lineHeight: CGFloat, color: NSColor) {
            block = TextBlockView("", font: font, lineHeight: lineHeight, color: color)
            super.init(frame: .zero)
            addSubview(block)
        }
        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: block.height(forWidth: bounds.width > 0 ? bounds.width : 512 - 48))
        }
        override func setFrameSize(_ newSize: NSSize) {
            let changed = newSize.width != frame.width
            super.setFrameSize(newSize)
            if changed { invalidateIntrinsicContentSize() }
        }
        override func layout() { super.layout(); block.frame = bounds }
    }

    /// The read-only link and Copy (`flex items-center gap-2`).
    final class LinkRow: DSView {
        let input: InputView
        let copy: ButtonView
        init(input: InputView, copy: ButtonView) {
            self.input = input; self.copy = copy
            super.init(frame: .zero)
            addSubview(input); addSubview(copy)
        }
        override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 32) }
        override func layout() {
            super.layout()
            let size = copy.intrinsicContentSize
            copy.frame = NSRect(x: bounds.width - size.width, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
            input.frame = NSRect(x: 0, y: 0, width: max(0, copy.frame.minX - 8), height: 32)
        }
    }
}
