import AppKit
import DesignSystem
import T3Protocol

/// The "Last run" `FoldedSettingsSection` (`headerPlacement="inside"`, StorageSettings.tsx:368-400,
/// FoldedSettingsSection.tsx:70-100): a card whose 44pt header holds the chevron, the title and the counts
/// summary. Open, it lists `CleanupResults` (StorageSettings.tsx:153-229) under a divider. Closed by default.
final class CleanupLastRunView: DSView, SettingsGroupRow {
    private let header = HeaderRow()
    private let card = SettingsGroupView(rows: [])
    var onHeightChange: (() -> Void)?
    private(set) var isOpen = false
    var summary: String { get { header.fold.summary } set { header.fold.summary = newValue } }
    var results: [any SettingsGroupRow] = [] { didSet { apply() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        header.fold.heading = "Last run"
        header.fold.action = { [weak self] in
            guard let self else { return }
            CollapseMotion.run(in: self) {
                self.isOpen.toggle()
                self.header.fold.isOpen = self.isOpen
                self.apply()
                self.onHeightChange?()
            }
        }
        addSubview(card)
        apply()
    }

    private func apply() {
        for r in results { r.isHidden = !isOpen }
        card.rows = [header] + results
        needsLayout = true
    }

    func height(forWidth width: CGFloat) -> CGFloat { card.height(forWidth: width) }
    override func layout() { super.layout(); card.frame = bounds }

    /// One row per entry, then the "more results" or "Nothing needed cleanup." note.
    static func rows(_ report: StorageCleanupReport, environmentLabel: String?) -> [any SettingsGroupRow] {
        let prefix = environmentLabel.map { "\($0): " } ?? ""
        var rows: [any SettingsGroupRow] = report.entries.map { entry in
            let name = switch entry.kind {
            case "worktree": entry.path?.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? "Worktrees"
            case "logs": "Rotated logs"
            default: "Browser artifacts"
            }
            let thread = entry.threadTitle.map { $0 != name ? "\($0). " : "" } ?? ""
            var control: NSView?
            if entry.outcome == "removed" {
                var parts: [String] = []
                if entry.kind != "worktree", let files = entry.files {
                    parts.append("\(DiagnosticsFormat.count(files)) \(files == 1 ? "file" : "files")")
                }
                if let bytes = entry.bytes { parts.append(StorageCleanupReport.formatBytes(bytes)) }
                let label = LabelView(parts.joined(separator: " · "), font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
                label.lineHeight = 16
                label.frame.size = NSSize(width: ceil(label.textWidth) + 1, height: 16)
                control = label
            }
            let r = SettingsRowView(title: prefix + name, detail: thread + entry.reason, control: control)
            r.detailIsError = entry.outcome == "failed"
            return r
        }
        func note(_ text: String) -> SettingsGroupNote {
            let n = SettingsGroupNote(prefix + text, size: 12)
            n.paddingY = 10
            return n
        }
        if report.omittedCount > 0 { rows.append(note("\(DiagnosticsFormat.count(Double(report.omittedCount))) more results.")) }
        if report.entries.isEmpty && report.omittedCount == 0 { rows.append(note("Nothing needed cleanup.")) }
        return rows
    }

    /// `flex items-center gap-4 px-3 sm:px-4` around the `min-h-11` trigger.
    final class HeaderRow: DSView, SettingsGroupRow {
        let fold = AuthorizedClientsSectionView.FoldHeader()
        override init(frame frameRect: NSRect) { super.init(frame: frameRect); addSubview(fold) }
        func height(forWidth width: CGFloat) -> CGFloat { 44 }
        override func layout() { super.layout(); fold.frame = NSRect(x: 16, y: 0, width: max(0, bounds.width - 32), height: 44) }
    }
}
