import AppKit
import DesignSystem

/// `WithheldFileNotice` (4928 PullRequestCodeTab.tsx, #37007): a file the host left out of the paged diff, with
/// "Load diff" when the host reads one file at a time (`withheldFilesReadable`). `flex items-center gap-2
/// bg-warning/8 px-3 py-2 text-xs text-warning-foreground`, a 14pt warning triangle and a micro warning button.
public final class PullRequestWithheldFileNotice: DSView, DiffAnnotationContent {
    public enum Status: Equatable, Sendable { case idle, loading, error, empty }

    private let icon = IconView(name: .triangleAlert, size: 14)
    private let label = LabelView("", font: DSFont.ui(12))
    private let button = ButtonView("Load diff", variant: .warningOutline, size: .micro)
    let path: String
    private(set) var status: Status

    init(path: String, status: Status, onLoad: ((String) -> Void)?) {
        self.path = path
        self.status = status
        super.init(frame: .zero)
        label.lineHeight = 16
        [icon, label, button].forEach(addSubview)
        button.action = { [weak self] in if let self { onLoad?(self.path) } }
        button.isHidden = onLoad == nil
        apply()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func update(_ status: Status) {
        guard status != self.status else { return }
        self.status = status
        apply()
    }

    private func apply() {
        label.text = status == .error ? "Couldn't load this diff." : status == .empty ? "No text diff for this file." : "Diff too large to display."
        button.title = status == .loading ? "Loading..." : status == .error ? "Retry" : "Load diff"
        button.isEnabled = status != .loading
        if status == .empty { button.isHidden = true }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(label.text)
        needsLayout = true
    }

    public func height(forWidth width: CGFloat) -> CGFloat { 8 + 20 + 8 }

    public override func layout() {
        super.layout()
        icon.frame = NSRect(x: 12, y: (bounds.height - 14) / 2, width: 14, height: 14)
        let lw = ceil(label.textWidth)
        label.frame = NSRect(x: 34, y: (bounds.height - 16) / 2, width: min(lw, max(0, bounds.width - 46)), height: 16)
        let bw = ceil(button.intrinsicContentSize.width)
        button.frame = NSRect(x: 34 + lw + 8, y: (bounds.height - 20) / 2, width: bw, height: 20)
    }

    public override func updateLayer() {
        layer?.backgroundColor = Themed.color(\.warning, 0.08).cgColor(in: self)
        icon.strokeColor = Themed.color(\.warning)
        label.color = Themed.color(\.warningForeground)
    }
}
