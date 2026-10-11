import AppKit
import DesignSystem
import T3Protocol

/// A dialog panel child whose height follows its width (DialogView reads `intrinsicContentSize` after
/// setting the width).
final class UsageDialogBlock: DSView {
    let content: NSView
    let measure: (CGFloat) -> CGFloat
    var onLayout: (@MainActor () -> Void)?
    init(_ content: NSView, height: @escaping (CGFloat) -> CGFloat) {
        self.content = content
        measure = height
        super.init(frame: .zero)
        addSubview(content)
    }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: measure(bounds.width)) }
    override func layout() { super.layout(); content.frame = bounds; onLayout?() }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); invalidateIntrinsicContentSize() }
}

public enum UsageModelDialog {
    /// `UsageModelDialog`: one model in the current window: cost, tokens, per million and cache hit, its trend
    /// (tokens when unpriced), the type and speed bars, and Set price when tokens have no known price.
    /// `usage` is the page's merge narrowed to this model's buckets.
    @MainActor
    public static func make(model: UsageModelTotals, usage: MergedUsage, tokens: Bool, window: UsageWindow, onSetPrice: @escaping @MainActor () -> Void) -> DialogView {
        let unknown = model.isCostUnknown
        let d = DialogView(title: model.model, message: model.provider.label + (unknown ? "" : " · \(UsageFormat.percent(model.costShare)) of cost"))
        d.maxWidth = 768
        var stats: [(String, String)] = [("Cost", unknown ? "Unpriced" : UsageFormat.usd(model.costUsd)), ("Tokens", UsageFormat.tokens(model.totalTokens))]
        if let p = UsageBreakdown.costPerMillion(model) { stats.append(("Per 1M tokens", UsageFormat.usd(p))) }
        if let h = UsageBreakdown.cacheHitRate(model) { stats.append(("Cache hit", UsageFormat.percent(h))) }
        let statsView = UsageModelStatsView(stats)
        let chart = UsageChartView()
        var cm = UsageChartView.Model()
        cm.providers = [model.provider]
        cm.periods = window.isHourly ? (window.sinceTime.flatMap { s in window.untilTime.map { UsageFormat.enumerateHourStarts(s, $0) } } ?? [])
            : UsageFormat.enumerateDays(window.sinceDay, window.untilDay)
        cm.byPeriod = Dictionary((window.isHourly ? usage.hourly : usage.daily).map { ($0.periodKey, $0) }, uniquingKeysWith: { a, _ in a })
        cm.tokens = unknown || tokens
        cm.hourly = window.isHourly
        cm.timeZone = window.timeZone
        cm.referenceTime = window.untilTime
        chart.model = cm
        var bars: [UsageShareBarView] = []
        if !unknown, let b = UsageShareBarView(label: "Cost by type", segments: UsageBreakdown.costSegments(usage.categoryCost), format: UsageFormat.usd) { bars.append(b) }
        if let b = UsageShareBarView(label: "Tokens by type", segments: UsageBreakdown.tokenSegments(model.tokens), format: UsageFormat.tokens) { bars.append(b) }
        if usage.speedCost.fast + usage.speedCost.ultrafast > 0,
           let b = UsageShareBarView(label: "Cost by speed", segments: UsageBreakdown.speedSegments(usage.speedCost), format: UsageFormat.usd) {
            b.aside = UsageBreakdown.premiumLabel(usage.speedCost.premium)
            bars.append(b)
        }
        let grid = UsageModelBarsView(bars)
        let body = DSView()
        for v in [statsView, chart, grid] as [NSView] { body.addSubview(v) }
        let block = UsageDialogBlock(body) { w in statsView.height(forWidth: w) + 32 + UsageChartView.height + (bars.isEmpty ? 0 : 32 + grid.height(forWidth: w)) }
        let relayout: @MainActor (CGFloat) -> Void = { w in
            let sh = statsView.height(forWidth: w)
            statsView.frame = NSRect(x: 0, y: 0, width: w, height: sh)
            chart.frame = NSRect(x: 0, y: sh + 32, width: w, height: UsageChartView.height)
            grid.frame = NSRect(x: 0, y: sh + 32 + UsageChartView.height + 32, width: w, height: grid.height(forWidth: w))
        }
        block.onLayout = { relayout(block.bounds.width) }
        d.panelContent = [block]
        if model.unpricedTokens > 0 {
            let note = UsageStyle.label("\(UsageFormat.tokens(model.unpricedTokens)) tokens have no known price", 12, color: Themed.color(\.mutedForeground))
            note.frame.size = NSSize(width: ceil(note.textWidth) + 1, height: 16)
            let set = ButtonView("Set price")
            set.action = onSetPrice
            d.footerVariant = .bare
            d.footerButtons = [UsageFixedSizeView(note), set]
            d.footerLeadingCount = 1
        }
        return d
    }
}

/// A view with a fixed intrinsic size, for a label in a dialog footer.
final class UsageFixedSizeView: DSView {
    let content: NSView
    init(_ content: NSView) {
        self.content = content
        super.init(frame: NSRect(origin: .zero, size: content.frame.size))
        addSubview(content)
    }
    override var intrinsicContentSize: NSSize { content.frame.size }
    override func layout() { super.layout(); content.frame = bounds }
}

/// The dialog's figures: `grid-cols-2 sm:grid-cols-4 gap-x-6 gap-y-4`, labels `text-xs`, values `text-2xl font-semibold`.
final class UsageModelStatsView: DSView {
    private var stats: [(LabelView, LabelView)] = []
    init(_ values: [(String, String)]) {
        super.init(frame: .zero)
        stats = values.map { k, v in
            let l = UsageStyle.label(k, 12, color: Themed.color(\.mutedForeground))
            let value = UsageStyle.label(v, 24, .semibold, lineHeight: 32)
            addSubview(l)
            addSubview(value)
            return (l, value)
        }
    }
    private var cols: Int { (window?.frame.width ?? 1440) >= 640 ? 4 : 2 }
    func height(forWidth width: CGFloat) -> CGFloat {
        let rows = CGFloat((stats.count + cols - 1) / cols)
        return rows * 50 + (rows - 1) * 16
    }
    override func layout() {
        super.layout()
        let w = (bounds.width - 24 * CGFloat(cols - 1)) / CGFloat(cols)
        for (i, (l, v)) in stats.enumerated() {
            let x = CGFloat(i % cols) * (w + 24), y = CGFloat(i / cols) * 66
            l.frame = NSRect(x: x, y: y, width: w, height: 16)
            v.frame = NSRect(x: x, y: y + 18, width: w, height: 32)
        }
    }
}

/// `grid gap-x-10 gap-y-8 sm:grid-cols-2`.
final class UsageModelBarsView: DSView {
    private let bars: [UsageShareBarView]
    init(_ bars: [UsageShareBarView]) {
        self.bars = bars
        super.init(frame: .zero)
        bars.forEach(addSubview)
    }
    private var cols: Int { (window?.frame.width ?? 1440) >= 640 ? 2 : 1 }
    private func colW(_ width: CGFloat) -> CGFloat { cols == 2 ? (width - 40) / 2 : width }
    func height(forWidth width: CGFloat) -> CGFloat {
        var h: CGFloat = 0
        for i in stride(from: 0, to: bars.count, by: cols) {
            h += (i > 0 ? 32 : 0) + (bars[i..<min(bars.count, i + cols)].map { $0.height(forWidth: colW(width)) }.max() ?? 0)
        }
        return h
    }
    override func layout() {
        super.layout()
        let w = colW(bounds.width)
        var y: CGFloat = 0
        for i in stride(from: 0, to: bars.count, by: cols) {
            let row = Array(bars[i..<min(bars.count, i + cols)])
            for (j, b) in row.enumerated() { b.frame = NSRect(x: CGFloat(j) * (w + 40), y: y, width: w, height: b.height(forWidth: w)) }
            y += (row.map { $0.height(forWidth: w) }.max() ?? 0) + 32
        }
    }
}

/// `UsagePriceOverrides`: the custom model prices table. Apply to (environments), one row per custom model
/// with Map to and the four rates, new rows, reset to automatic with undo, per-destination save results,
/// and Retry failed saves. The app supplies the targets and does the writes.
public final class UsagePriceTableView: DSView {
    public var targets: [UsagePriceTarget] = [] { didSet { rebuild() } }
    /// Ids of the selected destinations, nil for all.
    public var selectedIds: Set<String>? { didSet { rebuild() } }
    /// Model IDs seen in the usage, for suggestions.
    public var knownModels: [String] = []
    public private(set) var drafts: [UsagePriceDraft] = []
    /// The last save: destinations and each one's result (nil while saving).
    public var attempt: (drafts: [UsagePriceDraft], destinations: [(id: String, label: String)], results: [String: String?])? { didSet { rebuild() } }
    public var pending = false { didSet { rebuild() } }
    public var onChange: (() -> Void)?
    public var onSelectEnvironments: ((NSView) -> Void)?
    private var nextRow = 0
    private var focusRow: String?

    private let applyLabel = UsageStyle.label("Apply to", 14, .medium)
    private let applyButton = ButtonView("All environments", variant: .outline, size: .sm)
    private let unit = UsageStyle.label("USD / million tokens", 12, color: Themed.color(\.mutedForeground))
    private let table = DSView()
    private let note = TextBlockView()
    private var results: [(LabelView, LabelView)] = []
    private var rowViews: [UsagePriceRowView] = []
    private let headerRow = UsagePriceHeaderRow()
    private let emptyText = UsageStyle.label("", 14, color: Themed.color(\.mutedForeground))

    public init(initialModel: String?) {
        super.init(frame: .zero)
        applyButton.trailingIcon = .chevronDown
        applyButton.action = { [weak self] in guard let self else { return }; self.onSelectEnvironments?(self.applyButton) }
        headerRow.add.action = { [weak self] in self?.addRow() }
        note.font = DSFont.ui(12); note.lineHeight = 16; note.color = Themed.color(\.mutedForeground)
        emptyText.alignment = .center
        for v in [applyLabel, applyButton, unit, table, note, emptyText] as [NSView] { addSubview(v) }
        table.addSubview(headerRow)
        table.wantsLayer = true
        table.layer?.cornerRadius = 8
        table.layer?.borderWidth = 1
        table.layer?.masksToBounds = true
        if let m = initialModel { drafts = [UsagePriceDraft(id: "new:initial", model: m, isNew: true)] }
    }

    public var selected: [UsagePriceTarget] { targets.filter { selectedIds?.contains($0.environmentId) ?? true } }

    /// The initial model already has a row: edit it there.
    public func dropInitialIfExisting() {
        guard let m = drafts.first(where: { $0.id == "new:initial" })?.model else { return }
        if selected.contains(where: { $0.prices?[m] != nil || $0.aliases?[m] != nil }) { drafts.removeAll { $0.id == "new:initial" } }
    }

    var customModels: [String] {
        Array(Set(selected.flatMap { Array(($0.prices ?? [:]).keys) + Array(($0.aliases ?? [:]).keys) })).sorted()
    }

    /// Existing custom models then new rows, as `rows` in UsagePriceOverrides.tsx:154-167.
    var rows: [UsagePriceDraft] {
        let newModels = Set(drafts.filter(\.isNew).map { $0.model.trimmingCharacters(in: .whitespaces) })
        return customModels.filter { attempt == nil || !newModels.contains($0) }.map { m in
            drafts.first { $0.id == "model:\(m)" } ?? UsagePriceDraft(id: "model:\(m)", model: m, isNew: false)
        } + drafts.filter(\.isNew)
    }

    public var staged: [UsagePriceDraft] { drafts.filter { !$0.isEmpty } }

    public var errors: [String: String] {
        var e = UsagePriceLogic.errors(selected, staged)
        let custom = customModels
        for d in staged where d.isNew {
            let m = d.model.trimmingCharacters(in: .whitespaces)
            if m.isEmpty { e[d.id] = "Enter a model ID." }
            else if attempt == nil, custom.contains(m) || drafts.contains(where: { $0.id != d.id && $0.model.trimmingCharacters(in: .whitespaces) == m }) {
                e[d.id] = "This model already has a row. Edit its prices there."
            }
        }
        return e
    }

    public var failedDestinations: [(id: String, label: String)] {
        guard let a = attempt else { return [] }
        return a.destinations.filter { (a.results[$0.id] ?? nil)?.hasPrefix("failed:") == true }
    }

    public var locked: Bool { pending || !failedDestinations.isEmpty }

    public func discard() { drafts = []; attempt = nil; rebuild(); onChange?() }
    public func clearDrafts() { drafts = []; rebuild() }

    private func addRow() {
        let id = "new:\(nextRow)"
        nextRow += 1
        focusRow = id
        update(UsagePriceDraft(id: id, model: "", isNew: true))
    }

    private func update(_ d: UsagePriceDraft) {
        if let i = drafts.firstIndex(where: { $0.id == d.id }) { drafts[i] = d } else { drafts.append(d) }
        attempt = nil
        onChange?()
    }

    private func updateOrDrop(_ d: UsagePriceDraft) {
        if !d.isNew, d.values.isEmpty, d.alias == nil, !d.removed { drafts.removeAll { $0.id == d.id }; attempt = nil; onChange?() } else { update(d) }
    }

    private func matchesSaved(_ row: UsagePriceDraft, _ cell: UsagePriceLogic.Cell, _ value: String) -> Bool {
        !row.isNew && cell.placeholder != "Mixed" && cell.placeholder != "Unavailable" && value == cell.value
    }

    func editCell(_ id: String, _ field: UsagePriceLogic.Field, _ value: String) {
        guard var row = rows.first(where: { $0.id == id }) else { return }
        row.values[field] = value
        if matchesSaved(row, UsagePriceLogic.priceCell(selected, model: row.model, field: field), value) { row.values[field] = nil }
        updateOrDrop(row)
    }

    func editAlias(_ id: String, _ value: String) {
        guard var row = rows.first(where: { $0.id == id }) else { return }
        row.alias = matchesSaved(row, UsagePriceLogic.aliasCell(selected, model: row.model), value) ? nil : value
        updateOrDrop(row)
    }

    func editModel(_ id: String, _ value: String) {
        guard var row = rows.first(where: { $0.id == id }) else { return }
        row.model = value
        update(row)
    }

    func toggleRemoved(_ id: String) {
        guard var row = rows.first(where: { $0.id == id }) else { return }
        if row.isNew { drafts.removeAll { $0.id == id }; onChange?(); rebuild(); return }
        row.removed.toggle()
        if row.removed { update(row) } else { updateOrDrop(row) }
        rebuild()
    }

    private func rebuild() {
        let sel = selected
        applyButton.title = selectedIds == nil ? "All environments" : sel.count == 1 ? sel[0].label : "\(sel.count) environments"
        applyButton.isEnabled = !pending && staged.isEmpty
        headerRow.add.isEnabled = !locked
        let current = rows
        let errs = errors
        // Keep row views whose ids still exist so a focused field keeps its focus while typing.
        var next: [UsagePriceRowView] = []
        for r in current {
            let view = rowViews.first { $0.rowId == r.id } ?? UsagePriceRowView(rowId: r.id, owner: self)
            view.apply(r, targets: sel, error: errs[r.id], locked: locked)
            next.append(view)
        }
        for v in rowViews where !next.contains(where: { $0 === v }) { v.removeFromSuperview() }
        rowViews = next
        rowViews.forEach { if $0.superview == nil { table.addSubview($0) } }
        if let f = focusRow, let v = rowViews.first(where: { $0.rowId == f }) {
            focusRow = nil
            DispatchQueue.main.async { v.focusModel() }
        }
        emptyText.text = sel.contains { $0.prices == nil } ? "Some environment prices are unavailable." : "No custom prices or mappings. Add a row to set one."
        emptyText.isHidden = !current.isEmpty
        note.text = "Blank cache rates use the input price. Enter 0 for free tokens. A mapped model’s usage counts as the model it maps to."
            + (sel.count > 1 ? " Mixed cells keep each environment’s rate until you edit them." : "")
        results.forEach { $0.0.removeFromSuperview(); $0.1.removeFromSuperview() }
        results = (attempt?.destinations ?? []).map { d in
            let r = attempt?.results[d.id] ?? nil
            let l = UsageStyle.label(d.label, 12, color: Themed.color(\.mutedForeground))
            let failed = r?.hasPrefix("failed:") == true
            let v = UsageStyle.label(failed ? "Not saved · \(r!.dropFirst(7))" : r == "saved" ? "Saved" : "Saving…", 12,
                                     color: Themed.color(failed ? \.destructive : \.mutedForeground))
            v.alignment = .right
            addSubview(l); addSubview(v)
            return (l, v)
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private var tableHeight: CGFloat { UsagePriceHeaderRow.height + (rowViews.isEmpty ? 72 : rowViews.reduce(0) { $0 + $1.height }) + 2 }

    func height(forWidth width: CGFloat) -> CGFloat {
        guard !selected.isEmpty else { return 32 + 16 + 20 }
        return 32 + 16 + tableHeight + 16 + note.height(forWidth: width) + (results.isEmpty ? 0 : 16 + CGFloat(results.count) * 20 - 4)
    }

    public override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width)) }

    public override func layout() {
        super.layout()
        let w = bounds.width
        applyLabel.frame = NSRect(x: 0, y: 6, width: ceil(applyLabel.textWidth) + 1, height: 20)
        let bw = min(applyButton.intrinsicContentSize.width, w / 2)
        applyButton.frame = NSRect(x: applyLabel.frame.maxX + 8, y: 0, width: bw, height: 32)
        unit.frame = NSRect(x: w - ceil(unit.textWidth) - 1, y: 8, width: ceil(unit.textWidth) + 1, height: 16)
        let sel = selected
        table.isHidden = sel.isEmpty
        note.isHidden = sel.isEmpty
        if sel.isEmpty {
            emptyText.isHidden = false
            emptyText.alignment = .left
            emptyText.text = targets.isEmpty ? "Connect an environment to set model prices." : "Select an environment to see and change its model prices."
            emptyText.frame = NSRect(x: 0, y: 48, width: w, height: 20)
            return
        }
        emptyText.alignment = .center
        table.frame = NSRect(x: 0, y: 48, width: w, height: tableHeight)
        table.layer?.borderColor = Themed.color(\.border).cgColor(in: self)
        let cols = UsagePriceRowView.columns(w - 2)
        headerRow.frame = NSRect(x: 1, y: 1, width: w - 2, height: UsagePriceHeaderRow.height)
        headerRow.columns = cols
        var y = 1 + UsagePriceHeaderRow.height
        for r in rowViews {
            r.frame = NSRect(x: 1, y: y, width: w - 2, height: r.height)
            r.columns = cols
            y += r.height
        }
        if rowViews.isEmpty { emptyText.frame = NSRect(x: 0, y: 48 + UsagePriceHeaderRow.height + 26, width: w, height: 20) }
        let ny = table.frame.maxY + 16
        note.frame = NSRect(x: 0, y: ny, width: w, height: note.height(forWidth: w))
        var ry = note.frame.maxY + 16
        for (l, v) in results {
            l.frame = NSRect(x: 0, y: ry, width: w / 2, height: 16)
            v.frame = NSRect(x: w / 2, y: ry, width: w / 2, height: 16)
            ry += 20
        }
    }
}

/// The table's header: Model ID, Map to, the rates and the add button (`TableHead`: 40pt, `text-xs muted`).
final class UsagePriceHeaderRow: DSView {
    static let height: CGFloat = 40
    let add = ButtonView(nil, icon: .plus, variant: .ghost, size: .iconXs)
    private let labels = (["Model ID", "Map to"] + UsagePriceLogic.Field.allCases.map(\.label)).map {
        UsageStyle.label($0, 12, .medium, color: Themed.color(\.mutedForeground))
    }
    var columns: [CGFloat] = [] { didSet { needsLayout = true } }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        labels.forEach(addSubview)
        add.setAccessibilityLabel("Add model price")
        addSubview(add)
    }
    override func layout() {
        super.layout()
        var x: CGFloat = 0
        for (i, w) in columns.enumerated() {
            if i < labels.count { labels[i].frame = NSRect(x: x + 8, y: 12, width: w - 16, height: 16) }
            else { add.frame = NSRect(x: x + (w - 24) / 2, y: 8, width: 24, height: 24) }
            x += w
        }
    }
    override func updateLayer() { layer?.backgroundColor = Themed.color(\.muted, 0.5).cgColor(in: self) }
}

/// One row of the price table.
final class UsagePriceRowView: DSView {
    let rowId: String
    private weak var owner: UsagePriceTableView?
    private let modelInput = InputView(placeholder: "Model ID", size: .compact)
    private let modelLabel = UsageStyle.label("", 14)
    private let aliasInput = InputView(placeholder: "Optional", size: .compact)
    private let rateInputs = UsagePriceLogic.Field.allCases.map { _ in InputView(placeholder: "", size: .compact, font: .mono) }
    private let span = UsageStyle.label("", 14, color: Themed.color(\.mutedForeground))
    private let reset = ButtonView(nil, icon: .rotateCcw, variant: .ghost, size: .iconXs)
    private let error = UsageStyle.label("", 12, color: Themed.color(\.destructive))
    private var row = UsagePriceDraft(id: "", model: "", isNew: true)
    private var mode = 0 // 0 rates, 1 mapped, 2 removed
    var columns: [CGFloat] = [] { didSet { needsLayout = true } }
    private var tip: TooltipController?

    init(rowId: String, owner: UsagePriceTableView) {
        self.rowId = rowId
        self.owner = owner
        super.init(frame: .zero)
        for v in [modelInput, modelLabel, aliasInput, span, reset, error] as [NSView] { addSubview(v) }
        rateInputs.forEach(addSubview)
        modelInput.onChange = { [weak self] t in guard let self else { return }; self.owner?.editModel(self.rowId, t) }
        aliasInput.onChange = { [weak self] t in guard let self else { return }; self.owner?.editAlias(self.rowId, t) }
        for (i, f) in UsagePriceLogic.Field.allCases.enumerated() {
            rateInputs[i].onChange = { [weak self] t in guard let self else { return }; self.owner?.editCell(self.rowId, f, t) }
        }
        reset.action = { [weak self] in guard let self else { return }; self.owner?.toggleRemoved(self.rowId) }
        tip = TooltipController.attach(to: reset, text: "")
    }

    /// `w-[22%]`, `w-[18%]`, four equal rate columns and `w-10`, over a 720pt minimum.
    static func columns(_ width: CGFloat) -> [CGFloat] {
        let w = max(720, width)
        let model = (w * 0.22).rounded(), map = (w * 0.18).rounded(), action: CGFloat = 40
        let rate = ((w - model - map - action) / 4).rounded(.down)
        return [model, map, rate, rate, rate, w - model - map - action - 3 * rate]  + [action]
    }

    var height: CGFloat { 44 + (error.text.isEmpty ? 0 : 20) }

    func focusModel() { window?.makeFirstResponder(modelInput) }

    private func set(_ input: InputView, _ text: String) { if input.text != text, !input.isFirstResponderInside { input.text = text } }

    func apply(_ r: UsagePriceDraft, targets: [UsagePriceTarget], error message: String?, locked: Bool) {
        row = r
        modelInput.isHidden = !r.isNew
        modelLabel.isHidden = r.isNew
        modelLabel.text = r.model
        modelLabel.color = Themed.color(r.removed ? \.mutedForeground : \.foreground)
        // ponytail: removed rows are muted without T3's line-through; add strikethrough to LabelView if it matters
        set(modelInput, r.model)
        let aliasCell = UsagePriceLogic.aliasCell(targets, model: r.model)
        let alias = (r.alias ?? aliasCell.value).trimmingCharacters(in: .whitespaces)
        set(aliasInput, r.alias ?? aliasCell.value)
        aliasInput.placeholder = r.isNew ? "Optional" : aliasCell.placeholder
        mode = r.removed ? 2 : !alias.isEmpty ? 1 : 0
        aliasInput.isHidden = mode == 2
        span.isHidden = mode == 0
        span.text = mode == 2 ? "Automatic pricing after saving" : "Counted as \(alias)"
        for (i, f) in UsagePriceLogic.Field.allCases.enumerated() {
            let cell = UsagePriceLogic.priceCell(targets, model: r.model, field: f)
            rateInputs[i].isHidden = mode != 0
            set(rateInputs[i], r.values[f] ?? (r.isNew ? "" : cell.value))
            rateInputs[i].placeholder = r.isNew ? (f.optional ? "Input rate" : "0.00") : cell.placeholder
            rateInputs[i].isEnabled = !locked
            rateInputs[i].setAccessibilityLabel("\(f.label) price for \(r.model.isEmpty ? "new model" : r.model)")
        }
        modelInput.isEnabled = !locked
        aliasInput.isEnabled = !locked
        reset.isEnabled = !locked
        reset.icon = r.isNew ? .x : .rotateCcw
        tip?.text = r.removed ? "Undo reset" : r.isNew ? "Remove row" : "Reset to automatic"
        reset.setAccessibilityLabel(r.removed ? "Undo reset for \(r.model)" : r.isNew ? "Remove new model" : "Reset price for \(r.model) to automatic")
        let showError = message != nil && (!r.model.trimmingCharacters(in: .whitespaces).isEmpty || r.values.values.contains { !$0.isEmpty })
        error.text = showError ? message! : ""
        modelInput.isInvalid = showError && !r.model.trimmingCharacters(in: .whitespaces).isEmpty
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard columns.count == 7 else { return }
        var xs: [CGFloat] = [0]
        for c in columns { xs.append(xs.last! + c) }
        func cell(_ i: Int) -> NSRect { NSRect(x: xs[i] + 8, y: 8, width: columns[i] - 16, height: 28) }
        modelInput.frame = cell(0)
        modelLabel.frame = NSRect(x: xs[0] + 8, y: 12, width: columns[0] - 16, height: 20)
        error.frame = NSRect(x: xs[0] + 8, y: 40, width: xs[6] - 16, height: 16)
        aliasInput.frame = cell(1)
        for i in 0..<4 { rateInputs[i].frame = cell(2 + i) }
        span.frame = mode == 2 ? NSRect(x: xs[1] + 8, y: 12, width: xs[6] - xs[1] - 16, height: 20)
            : NSRect(x: xs[2] + 8, y: 12, width: xs[6] - xs[2] - 16, height: 20)
        reset.frame = NSRect(x: xs[6] + 8, y: 10, width: 24, height: 24)
    }

    override func updateLayer() { layer?.borderWidth = 0 }
    override func draw(_ dirtyRect: NSRect) {}
}

