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

    /// One row per entry, then the "more results" or "Nothing needed cleanup." note, each named by the
    /// machine it ran on (3473 StorageSettings.tsx:190-266, 5803c8b299).
    static func rows(_ report: StorageCleanupReport, environmentLabel: String) -> [any SettingsGroupRow] {
        var rows: [any SettingsGroupRow] = report.entries.map { entry in
            let r = SettingsRowView(title: name(entry), control: sizeLabel(entry))
            r.detailView = ResultDetailView(entry, environmentLabel: environmentLabel)
            return r
        }
        func note(_ text: String) -> SettingsGroupNote {
            let n = SettingsGroupNote("\(environmentLabel): " + text, size: 12)
            n.paddingY = 10
            return n
        }
        if report.omittedCount > 0 { rows.append(note("\(DiagnosticsFormat.count(Double(report.omittedCount))) more results.")) }
        if report.entries.isEmpty && report.omittedCount == 0 { rows.append(note("Nothing needed cleanup.")) }
        return rows
    }

    /// A worktree's folder name, or its whole path when no thread owned it.
    static func name(_ entry: StorageCleanupReport.Entry) -> String {
        switch entry.kind {
        case "worktree":
            (entry.threadId == nil ? entry.path : entry.path?.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init)) ?? "Worktrees"
        case "logs": "Rotated logs"
        default: "Browser artifacts"
        }
    }

    /// The files and bytes a removal freed, or a kept entry's size.
    static func sizeText(_ entry: StorageCleanupReport.Entry) -> String? {
        guard entry.outcome == "removed" || (entry.outcome == "kept" && entry.bytes != nil) else { return nil }
        var parts: [String] = []
        if entry.kind != "worktree", let files = entry.files {
            parts.append("\(DiagnosticsFormat.count(files)) \(files == 1 ? "file" : "files")")
        }
        if let bytes = entry.bytes { parts.append(StorageCleanupReport.formatBytes(bytes)) }
        return parts.joined(separator: " · ")
    }

    private static func sizeLabel(_ entry: StorageCleanupReport.Entry) -> NSView? {
        guard let text = sizeText(entry) else { return nil }
        let label = LabelView(text, font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
        label.lineHeight = 16
        label.frame.size = NSSize(width: ceil(label.textWidth) + 1, height: 16)
        return label
    }

    /// The pairs under the reason: Machine always, then Project, Folder and Thread where the entry has them.
    static func details(_ entry: StorageCleanupReport.Entry, environmentLabel: String) -> [(label: String, value: String, code: Bool)] {
        var pairs = [("Machine", environmentLabel, false)]
        if let p = entry.projectPath, !p.isEmpty { pairs.append(("Project", p, true)) }
        if let p = entry.path, !p.isEmpty { pairs.append(("Folder", p, true)) }
        if let t = entry.threadTitle, !t.isEmpty { pairs.append(("Thread", t, false)) }
        return pairs
    }

    /// The description: the reason (destructive when the entry failed), then `space-y-2` a
    /// `grid-cols-[auto_minmax(0,1fr)] gap-x-3 gap-y-1 border-l border-border/60 pl-3` of names and
    /// values, the values wrapping anywhere at the width they get.
    final class ResultDetailView: DSView, SettingsGroupRow {
        private let reason = TextBlockView()
        private let failed: Bool
        private var pairs: [(name: TextBlockView, value: TextBlockView, plain: Bool)] = []
        private let rule = CALayer()

        init(_ entry: StorageCleanupReport.Entry, environmentLabel: String) {
            failed = entry.outcome == "failed"
            super.init(frame: .zero)
            reason.text = entry.reason
            for t in [reason] { t.font = DSFont.ui(12); t.lineHeight = 18 }
            addSubview(reason)
            pairs = CleanupLastRunView.details(entry, environmentLabel: environmentLabel).map { label, value, code in
                let n = TextBlockView(), v = TextBlockView()
                n.text = label; v.text = value
                n.font = DSFont.ui(12); v.font = code ? DSFont.mono(12) : DSFont.ui(12)
                n.lineHeight = 18; v.lineHeight = 18
                addSubview(n); addSubview(v)
                // The thread's title keeps the description's color; the others are `text-foreground/80`.
                return (n, v, label == "Thread")
            }
            rule.actions = ["frame": NSNull(), "bounds": NSNull(), "position": NSNull()]
            layer?.addSublayer(rule)
        }

        private var nameWidth: CGFloat { pairs.map { ceil($0.name.naturalWidth) + 1 }.max() ?? 0 }
        private func valueWidth(_ width: CGFloat) -> CGFloat { max(0, width - 13 - nameWidth - 12) }

        private func gridHeight(_ width: CGFloat) -> CGFloat {
            let vw = valueWidth(width)
            return pairs.map { max(18, $0.value.height(forWidth: vw)) }.reduce(0, +) + CGFloat(max(0, pairs.count - 1)) * 4
        }

        func height(forWidth width: CGFloat) -> CGFloat { reason.height(forWidth: width) + 8 + gridHeight(width) }

        override func layout() {
            super.layout()
            let w = bounds.width
            let rh = reason.height(forWidth: w)
            reason.frame = NSRect(x: 0, y: 0, width: w, height: rh)
            var y = rh + 8
            rule.frame = CGRect(x: 0, y: y, width: 1, height: gridHeight(w))
            let vw = valueWidth(w)
            for p in pairs {
                let h = max(18, p.value.height(forWidth: vw))
                p.name.frame = NSRect(x: 13, y: y, width: nameWidth, height: 18)
                p.value.frame = NSRect(x: 13 + nameWidth + 12, y: y, width: vw, height: h)
                y += h + 4
            }
        }

        override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

        override func updateLayer() {
            let dither = ThemeRuntime.isDither(dark: effectiveAppearance.isDark)
            let muted = Themed.color(\.contrastMutedForeground, dither ? 1 : 0.8)
            reason.color = failed ? Themed.color(\.destructive) : muted
            for p in pairs {
                p.name.color = muted
                p.value.color = p.plain ? muted : Themed.color(\.foreground, 0.8)
            }
            rule.backgroundColor = Themed.color(\.border, 0.6).cgColor(in: self)
        }
    }

    /// `flex items-center gap-4 px-3 sm:px-4` around the `min-h-11` trigger.
    final class HeaderRow: DSView, SettingsGroupRow {
        let fold = AuthorizedClientsSectionView.FoldHeader()
        override init(frame frameRect: NSRect) { super.init(frame: frameRect); addSubview(fold) }
        func height(forWidth width: CGFloat) -> CGFloat { 44 }
        override func layout() { super.layout(); fold.frame = NSRect(x: 16, y: 0, width: max(0, bounds.width - 32), height: 44) }
    }
}
