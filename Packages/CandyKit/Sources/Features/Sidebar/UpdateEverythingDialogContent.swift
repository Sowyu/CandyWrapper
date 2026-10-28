import AppKit
import DesignSystem

/// UpdateEverythingDialog.tsx:127-207 (3814), with native dialog chrome.
public final class UpdateEverythingDialogContent: DSView {
    private let document = DSView()
    private lazy var scroll = ScrollAreaView(documentView: document, scrollFade: true)
    private let header: [LabelView]
    private let rows: [[TextBlockView]]
    private let skipped = ButtonView("", icon: .chevronRight, variant: .ghostMuted, size: .sm)
    private let reasons: TextBlockView
    public private(set) var skipsExpanded = false
    public var onHeightChange: (() -> Void)?

    public init(_ description: UpdateEverythingLogic.Description, running: [String: Int] = [:]) {
        header = ["Machine", "App / server", "Providers", ""].map { LabelView($0, font: DSFont.ui(12), color: Themed.color(\.mutedForeground)) }
        rows = description.updatingRows.map { row in
            let app = row.app?.rawValue ?? (row.skipped == nil ? "" : "Skipped")
            let n = row.environmentId.flatMap { running[$0] } ?? 0
            return [row.label, app + (row.app == .thisApp ? "\nrestarts last" : ""), row.providers.joined(separator: ", "), n > 0 ? "\(n) running" : ""].map {
                TextBlockView($0, font: DSFont.ui(14), lineHeight: 20)
            }
        }
        let skippedRows = description.rows.filter { $0.skipped != nil }
        reasons = TextBlockView(skippedRows.map { "\($0.label): \($0.skipped ?? "")" }.joined(separator: "\n"),
            font: DSFont.ui(12), lineHeight: 18, color: Themed.color(\.mutedForeground))
        super.init(frame: .zero)
        scroll.scrollsHorizontally = false
        addSubview(scroll)
        header.forEach { document.addSubview($0) }
        rows.flatMap { $0 }.forEach { document.addSubview($0) }
        skipped.title = "\(skippedRows.count) skipped"
        skipped.isHidden = skippedRows.isEmpty
        skipped.action = { [weak self] in self?.toggleSkipped() }
        document.addSubview(skipped); document.addSubview(reasons)
        reasons.isHidden = true
        for row in rows { row[3].color = Themed.color(\.warningForeground) }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    public func toggleSkipped() {
        skipsExpanded.toggle()
        reasons.isHidden = !skipsExpanded
        skipped.icon = skipsExpanded ? .chevronDown : .chevronRight
        invalidateIntrinsicContentSize()
        needsLayout = true
        onHeightChange?()
    }

    private func columnWidths(_ width: CGFloat) -> [CGFloat] {
        let available = max(280, width - 36)
        return [min(128, available * 0.25), 94, max(60, available - min(128, available * 0.25) - 94 - 65), 65]
    }
    private func contentHeight(_ width: CGFloat) -> CGFloat {
        let widths = columnWidths(width)
        let cells = rows.reduce(CGFloat(28)) { result, row in
            result + (zip(row, widths).map { $0.height(forWidth: $1) }.max() ?? 20) + 12
        }
        return cells + (skipped.isHidden ? 0 : 36) + (skipsExpanded ? reasons.height(forWidth: max(1, width - 18)) + 6 : 0)
    }
    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: min(340, contentHeight(max(320, bounds.width))))
    }
    public override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize.width != frame.width
        super.setFrameSize(newSize)
        if changed { invalidateIntrinsicContentSize() }
    }
    public override func layout() {
        super.layout()
        scroll.frame = bounds
        let width = scroll.contentWidth
        let widths = columnWidths(width)
        document.frame.size = NSSize(width: width, height: contentHeight(width))
        var x: CGFloat = 0
        for (label, w) in zip(header, widths) { label.frame = NSRect(x: x, y: 0, width: w, height: 20); x += w + 12 }
        var y: CGFloat = 28
        for row in rows {
            let h = zip(row, widths).map { $0.height(forWidth: $1) }.max() ?? 20
            x = 0
            for (cell, w) in zip(row, widths) { cell.frame = NSRect(x: x, y: y, width: w, height: h); x += w + 12 }
            y += h + 12
        }
        skipped.frame = NSRect(x: 0, y: y, width: 140, height: 28)
        if skipsExpanded { reasons.frame = NSRect(x: 18, y: y + 36, width: max(0, width - 18), height: reasons.height(forWidth: max(1, width - 18))) }
    }
}
