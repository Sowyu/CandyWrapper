import AppKit
import DesignSystem
import T3Store

/// The welcome wizard's project picker under "Choose your projects" (WelcomeWizard.tsx:1452-1546): the
/// "N of M selected" bar with Select all and Select none (`mt-5 text-xs`), a `ScrollArea scrollFade max-h-80`
/// with one fieldset per computer (`space-y-5`, a legend only with several), its scan state and the grouped
/// candidates, then the import error (`mt-3 text-sm text-destructive`).
public final class OnboardingImportListView: DSView {
    public struct Scan: Equatable {
        public var environmentId: String
        public var label: String
        /// The scan is running and has no result yet.
        public var pending: Bool
        public var error: String?
        public var truncated: Bool
        public var candidates: [OnboardingProjectCandidate]
        public init(environmentId: String, label: String, pending: Bool, error: String? = nil, truncated: Bool = false,
                    candidates: [OnboardingProjectCandidate] = []) {
            self.environmentId = environmentId; self.label = label; self.pending = pending; self.error = error
            self.truncated = truncated; self.candidates = candidates
        }
    }

    public var onSelectionChange: ((Set<String>) -> Void)?
    public var onRetry: ((String) -> Void)?

    private var scans: [Scan] = []
    private var selected: Set<String> = []
    private var importing = false
    /// Open state of multi-clone groups (open by default) and each computer's "Other folders" (closed).
    private var groupOpen: [String: Bool] = [:]
    private var otherOpen: Set<String> = []

    private let status = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    private let selectAll = ButtonView("Select all", variant: .ghost, size: .xs)
    private let selectNone = ButtonView("Select none", variant: .ghost, size: .xs)
    private let document = DSView()
    private lazy var scroll = ScrollAreaView(documentView: document, scrollFade: true)
    private let errorText = TextBlockView("", font: DSFont.ui(14), lineHeight: 20, color: Themed.color(\.destructive))
    private var documentHeight: CGFloat = 0

    static let maxListHeight: CGFloat = 320

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        status.lineHeight = 16
        status.setAccessibilityRole(.staticText)
        for v in [status, selectAll, selectNone, scroll, errorText] as [NSView] { addSubview(v) }
        selectAll.action = { [weak self] in
            guard let self else { return }
            onSelectionChange?(Set(scans.flatMap(\.candidates).map(\.key)))
        }
        selectNone.action = { [weak self] in self?.onSelectionChange?([]) }
    }
    required init?(coder: NSCoder) { fatalError() }

    private var candidates: [OnboardingProjectCandidate] { scans.flatMap(\.candidates) }

    public func update(scans: [Scan], selected: Set<String>, importing: Bool, error: String?) {
        self.scans = scans
        self.selected = selected
        self.importing = importing
        let all = candidates
        let count = all.filter { selected.contains($0.key) }.count
        status.text = "\(count) of \(all.count) selected"
        selectAll.isEnabled = !importing && count < all.count
        selectNone.isEnabled = !importing && count > 0
        for v in [status, selectAll, selectNone] as [NSView] { v.isHidden = all.isEmpty }
        errorText.text = error ?? ""
        errorText.isHidden = error == nil
        rebuild()
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    // MARK: Rows

    private func rebuild() {
        document.subviews.forEach { $0.removeFromSuperview() }
        var y: CGFloat = 0
        func place(_ view: NSView, height: CGFloat, x: CGFloat = 0) {
            view.frame = NSRect(x: x, y: y, width: 0, height: height)
            document.addSubview(view)
            y += height
        }
        for (s, scan) in scans.enumerated() {
            if s > 0 { y += 20 }
            if scans.count > 1 {
                place(LabelView(scan.label, font: DSFont.ui(14, weight: .medium)), height: 20)
                y += 8
            }
            if scan.pending && scan.candidates.isEmpty {
                place(PendingRow(), height: 44)
            } else if let error = scan.error {
                let row = ScanErrorRow(message: "Could not check projects. \(error)")
                row.retry.action = { [weak self] in self?.onRetry?(scan.environmentId) }
                place(row, height: 28)
            } else if scan.candidates.isEmpty {
                let empty = LabelView("No existing Claude Code or Codex projects found.", font: DSFont.ui(14), color: Themed.color(\.mutedForeground))
                empty.lineHeight = 20
                y += 8; place(empty, height: 20); y += 8
            }
            if scan.truncated {
                let note = LabelView(OnboardingProjectImport.scanLimitMessage, font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
                note.lineHeight = 16
                place(note, height: 16)
            }
            let (repositories, other) = OnboardingProjectImport.group(scan.candidates)
            var first = true
            func row(_ view: ImportRow) { if !first { y += 2 }; first = false; place(view, height: view.rowHeight) }
            for group in repositories {
                if group.candidates.count == 1, let only = group.candidates.first {
                    row(candidateRow(only, label: group.label, secondary: group.repository == nil ? nil : only.path, nested: false))
                    continue
                }
                let open = groupOpen[group.key] ?? true
                let keys = group.candidates.map(\.key)
                let header = ImportRow(label: group.label, labelFont: DSFont.ui(14, weight: .medium), labelColor: Themed.color(\.foreground),
                                       nested: false, chevronOpen: open)
                header.meta.set(sources: Array(Set(group.candidates.flatMap(\.sources))).sorted(), threads: group.threadCount, lastActiveAt: group.lastActiveAt)
                configureGroupCheck(header, keys: keys)
                header.action = { [weak self] in self?.groupOpen[group.key] = !open; self?.relayoutAfterToggle() }
                row(header)
                if open { for c in group.candidates { row(candidateRow(c, label: c.path, secondary: nil, nested: true)) } }
            }
            if !other.isEmpty {
                let open = otherOpen.contains(scan.environmentId)
                let header = ImportRow(label: "Other folders", labelFont: DSFont.ui(14), labelColor: Themed.color(\.mutedForeground),
                                       nested: false, chevronOpen: open)
                header.meta.setCount(other.count == 1 ? "1 folder" : "\(other.count) folders")
                configureGroupCheck(header, keys: other.map(\.key))
                header.action = { [weak self] in
                    guard let self else { return }
                    if open { otherOpen.remove(scan.environmentId) } else { otherOpen.insert(scan.environmentId) }
                    relayoutAfterToggle()
                }
                row(header)
                if open { for c in other { row(candidateRow(c, label: c.path, secondary: nil, nested: true)) } }
            }
        }
        documentHeight = y
    }

    private func relayoutAfterToggle() {
        rebuild()
        invalidateIntrinsicContentSize()
        needsLayout = true
        // The dialog sizes its panel from the intrinsic height.
        superview?.needsLayout = true
    }

    private func configureGroupCheck(_ row: ImportRow, keys: [String]) {
        let count = keys.filter { selected.contains($0) }.count
        row.checkbox.value = count == keys.count ? .on : count > 0 ? .mixed : .off
        row.checkbox.isEnabled = !importing
        row.isEnabled = !importing
        row.checkbox.onChange = { [weak self] value in self?.set(keys, value == .on) }
    }

    private func candidateRow(_ c: OnboardingProjectCandidate, label: String, secondary: String?, nested: Bool) -> ImportRow {
        let row = ImportRow(label: label, labelFont: nested ? DSFont.mono(12) : DSFont.ui(14, weight: .medium),
                            labelColor: Themed.color(\.foreground), nested: nested, chevronOpen: nil, secondary: secondary)
        row.meta.set(sources: nested ? nil : c.sources, threads: c.threadCount, lastActiveAt: c.lastActiveAt)
        let on = selected.contains(c.key)
        row.checkbox.value = on ? .on : .off
        row.checkbox.isEnabled = !importing
        row.isEnabled = !importing
        row.checkbox.onChange = { [weak self] value in self?.set([c.key], value == .on) }
        // The whole row is the checkbox's `<label>`.
        row.action = { [weak self] in self?.set([c.key], !on) }
        TooltipController.attach(to: row.labelBox, text: c.path, variant: .code)
        return row
    }

    private func set(_ keys: [String], _ on: Bool) {
        var next = selected
        for k in keys { if on { next.insert(k) } else { next.remove(k) } }
        onSelectionChange?(next)
    }

    // MARK: Layout

    private var hasCandidates: Bool { !candidates.isEmpty }
    private var listTop: CGFloat { hasCandidates ? 20 + 24 + 8 : 8 }
    private var listHeight: CGFloat { min(Self.maxListHeight, documentHeight) }

    private func errorHeight(_ width: CGFloat) -> CGFloat { errorText.isHidden ? 0 : 12 + errorText.height(forWidth: width) }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: listTop + listHeight + errorHeight(max(bounds.width, 1)))
    }

    public override func layout() {
        super.layout()
        let w = bounds.width
        let buttons = [selectNone, selectAll]
        var x = w
        for b in buttons {
            let bw = b.intrinsicContentSize.width
            x -= bw
            b.frame = NSRect(x: x, y: 20, width: bw, height: 24)
            x -= 4
        }
        status.frame = NSRect(x: 0, y: 24, width: max(0, x - 12), height: 16)
        scroll.frame = NSRect(x: 0, y: listTop, width: w, height: listHeight)
        // `pr-3`: rows stop 12 short of the scrollbar.
        let rowWidth = max(0, w - 12)
        document.frame = NSRect(x: 0, y: 0, width: w, height: documentHeight)
        for v in document.subviews { v.frame.size.width = rowWidth - v.frame.minX }
        errorText.frame = NSRect(x: 0, y: listTop + listHeight + 12, width: w, height: max(0, errorHeight(w) - 12))
        if abs(intrinsicContentSize.height - bounds.height) > 0.5 { superview?.needsLayout = true }
    }
}

/// "Looking for projects…" with a `md` spinner, `py-3 gap-2 text-sm text-muted-foreground`.
private final class PendingRow: DSView {
    private let spinner = SpinnerView(size: .md)
    private let label = LabelView("Looking for projects…", font: DSFont.ui(14), color: Themed.color(\.mutedForeground))
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        spinner.color = Themed.color(\.mutedForeground)
        label.lineHeight = 20
        addSubview(spinner); addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        spinner.frame = NSRect(x: 0, y: 14, width: 16, height: 16)
        label.frame = NSRect(x: 24, y: 12, width: max(0, bounds.width - 24), height: 20)
    }
}

/// `role="alert"`: the scan error and a ghost sm Retry at the end (`justify-between gap-3`).
private final class ScanErrorRow: DSView {
    let retry = ButtonView("Retry", variant: .ghost, size: .sm)
    private let label: LabelView
    init(message: String) {
        label = LabelView(message, font: DSFont.ui(14), color: Themed.color(\.mutedForeground))
        super.init(frame: .zero)
        label.lineHeight = 20
        setAccessibilityRole(.group)
        addSubview(label); addSubview(retry)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        let bw = retry.intrinsicContentSize.width
        retry.frame = NSRect(x: bounds.width - bw, y: 0, width: bw, height: 28)
        label.frame = NSRect(x: 0, y: 4, width: max(0, bounds.width - bw - 12), height: 20)
    }
}

/// `ImportCandidateRow`, `ImportRepositoryGroup` and the "Other folders" header (WelcomeWizard.tsx:1569-1744):
/// `rounded-md px-2 py-1.5 gap-2.5 hover:bg-muted/40`, nested rows `pl-8` in `font-mono text-xs`.
private final class ImportRow: ControlView {
    let checkbox = CheckboxView()
    let meta = ImportRowMeta()
    /// The label and the secondary path: the tooltip's trigger.
    let labelBox = DSView()
    private let label: LabelView
    private let secondary: LabelView?
    private let chevron: IconView?
    private let nested: Bool
    var rowHeight: CGFloat { nested ? 28 : 32 }

    init(label text: String, labelFont: NSFont, labelColor: NSColor, nested: Bool, chevronOpen: Bool?, secondary path: String? = nil) {
        label = LabelView(text, font: labelFont, color: labelColor)
        label.lineHeight = nested ? 16 : 20
        secondary = path.map { LabelView($0, font: DSFont.mono(10), color: Themed.color(\.mutedForeground)) }
        secondary?.lineHeight = 14
        chevron = chevronOpen.map { _ in IconView(name: .chevronRight, size: 14, strokeColor: Themed.color(\.mutedForeground)) }
        self.nested = nested
        super.init(frame: .zero)
        scalesWhenPressed = false
        transitions = .colors
        layer?.cornerRadius = 6
        addSubview(checkbox)
        if let chevron { addSubview(chevron); chevron.setRotation(chevronOpen == true ? 90 : 0, motion: .none) }
        labelBox.addSubview(label)
        if let secondary { labelBox.addSubview(secondary) }
        addSubview(labelBox)
        addSubview(meta)
    }
    @MainActor required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        Motion.setBackground(layer, state.hovered && state.enabled ? Themed.color(\.muted, 0.4).cgColor(in: self) : nil)
    }

    // `has-disabled:cursor-default`.
    override func resetCursorRects() { if isEnabled { addCursorRect(bounds, cursor: .pointingHand) } }

    override func layout() {
        super.layout()
        let h = bounds.height
        var x: CGFloat = nested ? 32 : 8
        checkbox.frame = NSRect(x: x, y: (h - 16) / 2, width: 16, height: 16)
        x += 16 + 10
        if let chevron {
            chevron.frame = NSRect(x: x, y: (h - 14) / 2, width: 14, height: 14)
            x += 14 + 6
        }
        let metaWidth = ImportRowMeta.width
        let metaX = bounds.width - 8 - metaWidth
        meta.frame = NSRect(x: metaX, y: (h - 16) / 2, width: metaWidth, height: 16)
        let available = max(0, metaX - 10 - x)
        let lh = label.lineHeight ?? 20
        labelBox.frame = NSRect(x: x, y: (h - lh) / 2, width: available, height: lh)
        // `flex items-baseline gap-2 truncate`: the path follows the name and both shrink.
        let natural = label.intrinsicContentSize.width
        if let secondary {
            let lw = min(natural, available * 0.6)
            label.frame = NSRect(x: 0, y: 0, width: lw, height: lh)
            secondary.frame = NSRect(x: lw + 8, y: lh - 14 - 2, width: max(0, available - lw - 8), height: 14)
        } else {
            label.frame = NSRect(x: 0, y: 0, width: available, height: lh)
        }
    }
}

/// `ImportRowMeta`: fixed columns `1rem 1rem 2.5rem 2.25rem` with `gap-x-1`, `text-xs text-muted-foreground`:
/// the Claude Code and Codex marks in their own slots, the thread count and the age, right aligned.
private final class ImportRowMeta: DSView {
    static let width: CGFloat = 16 + 16 + 40 + 36 + 12
    private var icons: [NSView] = []
    private let count = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    private let age = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    private var slots: [Int] = []
    private var countOnly = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for l in [count, age] { l.alignment = .right; l.lineHeight = 16; addSubview(l) }
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(sources: [String]?, threads: Int, lastActiveAt: String?) {
        icons.forEach { $0.removeFromSuperview() }
        icons = []; slots = []
        for (slot, driver) in ["claudeAgent", "codex"].enumerated() where sources?.contains(driver) == true {
            let icon = ProviderIcon.make(driver: driver, displayName: driver == "codex" ? "Codex" : "Claude Code", size: 12,
                                         color: Themed.color(\.mutedForeground))
            icon.setAccessibilityLabel(driver == "codex" ? "Codex" : "Claude Code")
            addSubview(icon); icons.append(icon); slots.append(slot)
        }
        countOnly = false
        count.text = "\(threads)"
        // "just now" does not fit the column, so it reads "now".
        let relative = lastActiveAt.flatMap { TimestampFormat.formatRelativeTime($0, nowMs: TimestampFormat.nowMs()) }
        age.text = relative.map { $0.suffix == nil ? "now" : $0.value } ?? ""
        needsLayout = true
    }

    /// The "Other folders" header: one trailing `ml-auto text-xs tabular-nums` count.
    func setCount(_ text: String) {
        icons.forEach { $0.removeFromSuperview() }
        icons = []; slots = []
        countOnly = true
        count.text = text
        age.text = ""
        needsLayout = true
    }

    override func layout() {
        super.layout()
        for (icon, slot) in zip(icons, slots) { icon.frame = NSRect(x: CGFloat(slot) * 20 + 2, y: 2, width: 12, height: 12) }
        if countOnly {
            count.frame = bounds
        } else {
            count.frame = NSRect(x: 40, y: 0, width: 40, height: 16)
            age.frame = NSRect(x: 84, y: 0, width: 36, height: 16)
        }
    }
}
