import AppKit
import DesignSystem
import T3Protocol

/// The inline rename input (Sidebar.tsx:1650-1663): `rounded-sm border border-input bg-card px-1 text-sm
/// font-medium text-card-foreground outline-none focus:border-foreground`. Return commits, Escape cancels,
/// leaving the field commits; the text is selected when it takes focus.
final class SidebarRenameFieldView: DSView {
    let input = InputView(size: .inline)
    private(set) var threadId: ThreadId?
    private(set) var originalTitle = ""
    /// The field committed or cancelled already (`renameCommittedRef`), so the blur that follows does nothing.
    private var settled = false
    var onCommit: (@MainActor (ThreadId, String, String) -> Void)?
    var onCancel: (@MainActor () -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        input.unstyled = true
        input.fontWeight = .medium
        input.paddingOverride = (4, 4)
        input.setAccessibilityLabel("Thread title")
        addSubview(input)
        layer?.cornerRadius = 4
        layer?.borderWidth = 1
        input.onSubmit = { [weak self] in self?.commit() }
        input.onCommand = { [weak self] selector in
            guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            self?.cancel()
            return true
        }
        input.onStateChange = { [weak self] state in
            guard let self else { return }
            self.needsDisplay = true
            if !state.focused, !self.settled, self.threadId != nil { self.commit() }
        }
    }

    /// Starts editing a thread's title.
    func begin(_ id: ThreadId, title: String) {
        threadId = id
        originalTitle = title
        settled = false
        input.text = title
    }

    /// Focuses the field and selects its text (`onFocus={select()}`); call once it is in a window.
    func focus() {
        guard let window else { return }
        window.makeFirstResponder(input)
        (window.firstResponder as? NSTextView)?.selectAll(nil)
    }

    private func commit() {
        guard !settled, let id = threadId else { return }
        settled = true
        onCommit?(id, input.text, originalTitle)
    }

    private func cancel() {
        guard !settled else { return }
        settled = true
        onCancel?()
    }

    override func layout() {
        super.layout()
        input.frame = bounds.insetBy(dx: 1, dy: 1)
    }

    override func updateLayer() {
        layer?.backgroundColor = SB.c(\.card).cgColor(in: self)
        layer?.borderColor = (input.state.focused ? SB.c(\.foreground) : SB.c(\.input)).cgColor(in: self)
    }
}

extension SidebarRowBase {
    /// Places the shared rename field over the title, or takes it away.
    func placeRenameField(_ field: SidebarRenameFieldView?, over title: NSView, frame: NSRect) {
        if let field {
            if field.superview !== self { addSubview(field) }
            field.frame = frame
            title.isHidden = true
        } else {
            title.isHidden = false
        }
    }
}
