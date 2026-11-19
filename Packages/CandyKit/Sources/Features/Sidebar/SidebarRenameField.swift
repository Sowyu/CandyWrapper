import AppKit
import DesignSystem
import T3Protocol

/// The inline rename input (T3 4928 SidebarThreadRow.tsx, #31009): `-mx-1 rounded-sm bg-card px-1 text-sm font-medium
/// text-card-foreground outline-none ring-1 ring-inset ring-input focus:ring-foreground`. Return commits, Escape cancels,
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
        // `ring-1 ring-inset` takes no room, so the text sits where the title was (T3 4928 SidebarThreadRow.tsx, #31009).
        input.frame = bounds
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
            // `-mx-1` around the title's own line: the field's `px-1` puts the text where the title's was.
            field.frame = NSRect(x: frame.minX - 4, y: frame.minY + 1, width: frame.width + 8, height: max(0, frame.height - 2))
            title.isHidden = true
        } else {
            title.isHidden = false
        }
    }
}
