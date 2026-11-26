import AppKit
import DesignSystem

// "Link several environments" (T3 5258 components/settings/LinkSeveralEnvironments.tsx): the machines this app
// already reaches, ticked, then one run that mints a code on each and links it from the source. Line numbers cite
// that file. The run itself is `LinkBatch.run`; this is the form and its states.

/// The dialog's form: the machine list with its header, the run's notes, the access picker and the link-back box.
@MainActor
public final class LinkSeveralEnvironmentsFormView: DSView {
    public private(set) var candidates: [LinkBatch.Candidate]
    let kinds: [String: String]
    let sourceLabel: String?
    let presetOnly: Bool
    /// Picked on the map, but known only through another machine's link: no session here (:139-142).
    let unlisted: Int
    public private(set) var selected: Set<String>
    public private(set) var access = "approval-required"
    public private(set) var alsoLinkBack = false
    public var outcomes: [String: LinkBatch.Outcome] = [:] { didSet { apply() } }
    public var linking: Set<String> = [] { didSet { apply() } }
    /// Where the source can be linked back to, by machine (`useLinkBackOffers`). Empty hides the box.
    public var backOffered: Set<String> = [] { didSet { apply() } }
    /// `linkListState`: until the source's links load, nothing can be picked.
    public var linksState: LinkBatch.ListState
    public var linksError: String?
    public var onRetryLinks: (() -> Void)?
    var onChange: (() -> Void)?
    public var onHeightChange: (() -> Void)?

    private let machinesTitle = LabelView("Machines", font: DSFont.ui(12, weight: .medium), color: Themed.color(\.foreground))
    let selectAll = ButtonView("Select all", variant: .ghostMuted, size: .xs)
    private let status = TextBlockView("", font: DSFont.ui(12), lineHeight: 16, color: Themed.color(\.mutedForeground))
    let retry = ButtonView("Retry", variant: .outline, size: .xs)
    private let list = DSView()
    private lazy var listScroll = ScrollAreaView(documentView: list, scrollbars: .native)
    private var rows: [LinkSeveralRowView] = []
    private let empty = TextBlockView("", font: DSFont.ui(14), lineHeight: 20, color: Themed.color(\.mutedForeground))
    private let unlistedNote = TextBlockView("", font: DSFont.ui(12), lineHeight: 16, color: Themed.color(\.mutedForeground))
    private let summary = TextBlockView("", font: DSFont.ui(12), lineHeight: 16, color: Themed.color(\.mutedForeground))
    private let accessTitle = LabelView("What agents here may do there", font: DSFont.ui(12, weight: .medium), color: Themed.color(\.foreground))
    private let accessSelect = SelectView(options: LinkAccess.all.map(\.label), selected: 1)
    private let accessNote = TextBlockView("", font: DSFont.ui(12), lineHeight: 16, color: Themed.color(\.mutedForeground))
    let backBox = CheckboxView(value: .off)
    private let backTitle = TextBlockView("", font: DSFont.ui(14, weight: .medium), lineHeight: 20, color: Themed.color(\.foreground))
    private let backNote = TextBlockView("", font: DSFont.ui(12), lineHeight: 16, color: Themed.color(\.mutedForeground))
    private let listBorder = CALayer()

    public init(candidates: [LinkBatch.Candidate], kinds: [String: String] = [:], sourceLabel: String?, preset: [String],
                presetOnly: Bool, unlisted: Int = 0, linksState: LinkBatch.ListState) {
        self.candidates = candidates; self.kinds = kinds; self.sourceLabel = sourceLabel; self.presetOnly = presetOnly
        self.unlisted = unlisted; self.linksState = linksState
        selected = Set(preset)
        super.init(frame: .zero)
        machinesTitle.lineHeight = 16
        accessTitle.lineHeight = 16
        selectAll.reservedTitles = ["Select none"]
        selectAll.action = { [weak self] in self?.toggleAll() }
        retry.action = { [weak self] in self?.onRetryLinks?() }
        accessSelect.optionDetails = LinkAccess.all.map(\.description)
        accessSelect.optionGlyphs = LinkAccess.all.map { $0.icon.definition }
        accessSelect.alignItemWithTrigger = false
        accessSelect.setAccessibilityLabel("What agents here may do there")
        accessSelect.onChange = { [weak self] i in self?.access = LinkAccess.all[i].value; self?.apply() }
        backBox.onChange = { [weak self] value in self?.alsoLinkBack = value == .on; self?.apply() }
        backBox.setAccessibilityLabel(sourceLabel.map { "Also link each machine back to \($0)" })
        empty.text = presetOnly ? "This app is not connected to any of the machines you picked."
            : "This app knows no other machines. Add them under Environments first."
        rows = candidates.map { c in
            let row = LinkSeveralRowView(machine: c.machine, kind: kinds[c.machine.environmentId])
            let id = c.machine.environmentId
            row.box.onChange = { [weak self] value in
                guard let self else { return }
                if value == .on { self.selected.insert(id) } else { self.selected.remove(id) }
                self.apply()
            }
            list.addSubview(row)
            return row
        }
        list.wantsLayer = true
        for v in [machinesTitle, selectAll, status, retry, listScroll, empty, unlistedNote, summary, accessTitle, accessSelect, accessNote,
                  backBox, backTitle, backNote] as [NSView] { addSubview(v) }
        wantsLayer = true
        layer?.addSublayer(listBorder)
        apply()
    }
    @MainActor required init?(coder: NSCoder) { fatalError() }

    public var busy: Bool { !linking.isEmpty }
    /// Machines a run can link now: not blocked and not linked by this dialog already.
    public var pickable: [LinkableMachine] {
        candidates.compactMap { c in
            c.blocked == nil && outcomes[c.machine.environmentId]?.isLinked != true ? c.machine : nil
        }
    }
    public var chosen: [LinkableMachine] { pickable.filter { selected.contains($0.environmentId) } }
    var oneWayOnly: Int { chosen.filter { !backOffered.contains($0.environmentId) }.count }
    var showsBack: Bool { sourceLabel != nil && pickable.contains { backOffered.contains($0.environmentId) } }

    func toggleAll() {
        let ids = pickable.map(\.environmentId)
        selected = chosen.count == ids.count ? [] : Set(ids)
        apply()
    }

    /// The source's links loaded or failed while the dialog shows: the same machines, blocked anew.
    public func setLinks(_ state: LinkBatch.ListState, candidates next: [LinkBatch.Candidate]) {
        linksState = state
        for (i, c) in candidates.enumerated() { candidates[i].blocked = next.first { $0.machine.environmentId == c.machine.environmentId }?.blocked }
        apply()
    }

    /// After a run, what failed stays picked so linking again retries only those (:200).
    public func keepFailed() {
        selected = Set(outcomes.filter { !$0.value.isLinked }.map(\.key))
        apply()
    }

    func apply() {
        let all = pickable.count
        selectAll.title = chosen.count == all && all > 0 ? "Select none" : "Select all"
        selectAll.isEnabled = !busy && all > 0
        status.text = linksState == .loading ? "Checking which machines are already linked…"
            : linksState == .failed ? "Could not check which machines are already linked, so none can be picked: \(linksError ?? "")" : ""
        status.color = linksState == .failed ? Themed.color(\.destructive) : Themed.color(\.mutedForeground)
        status.isHidden = linksState == .loaded
        retry.isHidden = linksState != .failed
        for (i, c) in candidates.enumerated() {
            let id = c.machine.environmentId
            let row = rows[i]
            let blocked = c.blocked
            let outcome = outcomes[id]
            let available = blocked == nil && outcome?.isLinked != true
            row.box.value = available && selected.contains(id) ? .on : .off
            row.box.isEnabled = !busy && available
            row.status = LinkBatch.status(linking: linking.contains(id), outcome: outcome, blocked: blocked)
            var lines: [String] = []
            if case .failed(_, let detail?)? = outcome { lines.append(detail) }
            if case .linked(.failed(let failure, let detail)?)? = outcome {
                lines.append("Could not link back: \(detail ?? LinkBatch.failureLabel(failure))")
            }
            row.errors = lines
            row.failed = { if case .failed? = outcome { return true }; if case .linked(.failed?)? = outcome { return true }; return false }()
        }
        empty.isHidden = !candidates.isEmpty
        for v in [machinesTitle, selectAll, listScroll] as [NSView] { v.isHidden = candidates.isEmpty }
        listBorder.isHidden = candidates.isEmpty
        unlistedNote.text = unlisted == 1 ? "1 machine needs a pairing code, so it is not listed."
            : "\(unlisted) machines need a pairing code, so they are not listed."
        unlistedNote.isHidden = unlisted == 0
        summary.text = busy ? "" : LinkBatch.summary(outcomes) ?? ""
        summary.isHidden = summary.text.isEmpty
        accessSelect.isEnabled = !busy
        accessNote.text = LinkAccess.note(access)
        let source = sourceLabel ?? ""
        backTitle.text = "Also link each machine back to \(source)"
        backNote.text = "Agents there can then work on \(source) too."
            + (alsoLinkBack && oneWayOnly > 0 ? (oneWayOnly == 1 ? " 1 machine stays one-way." : " \(oneWayOnly) machines stay one-way.") : "")
        backBox.isEnabled = !busy
        for v in [backBox, backTitle, backNote] as [NSView] { v.isHidden = !showsBack }
        needsLayout = true
        onChange?()
        onHeightChange?()
    }

    static let rowHeight: CGFloat = 36

    /// `space-y-4` between parts, `space-y-1.5` inside the machine list's block.
    private func blocks(_ width: CGFloat) -> [(view: NSView, x: CGFloat, height: CGFloat, gap: CGFloat)] {
        var b: [(NSView, CGFloat, CGFloat, CGFloat)] = []
        func add(_ v: NSView, _ h: CGFloat, gap: CGFloat = 16, x: CGFloat = 0) {
            guard !v.isHidden else { return }
            b.append((v, x, h, b.isEmpty ? 0 : gap))
        }
        add(empty, empty.height(forWidth: width))
        if !candidates.isEmpty {
            add(machinesTitle, 24)
            add(status, max(24, status.height(forWidth: width - (retry.isHidden ? 0 : retry.intrinsicContentSize.width + 8))), gap: 6)
            add(listScroll, min(288, listHeight(width) + 2), gap: 6)
        }
        add(unlistedNote, unlistedNote.height(forWidth: width))
        add(summary, summary.height(forWidth: width))
        add(accessTitle, 16)
        add(accessSelect, 32, gap: 6)
        add(accessNote, accessNote.height(forWidth: width), gap: 6)
        add(backTitle, 20)
        add(backNote, backNote.height(forWidth: width - 26), gap: 2, x: 26)
        return b
    }

    func listHeight(_ width: CGFloat) -> CGFloat { rows.reduce(0) { $0 + $1.height(forWidth: width) } + CGFloat(max(0, rows.count - 1)) }

    public func height(forWidth width: CGFloat) -> CGFloat { blocks(width).reduce(0) { $0 + $1.gap + $1.height } }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: bounds.width > 0 ? height(forWidth: bounds.width) : NSView.noIntrinsicMetric)
    }

    public override func layout() {
        super.layout()
        let w = bounds.width
        var y: CGFloat = 0
        for b in blocks(w) {
            y += b.gap
            var width = w - b.x
            if b.view === status, !retry.isHidden { width -= retry.intrinsicContentSize.width + 8 }
            if b.view === backTitle { width = w - 26 }
            b.view.frame = NSRect(x: b.x == 0 && b.view === backTitle ? 26 : b.x, y: y, width: width, height: b.height)
            if b.view === machinesTitle {
                machinesTitle.frame = NSRect(x: 0, y: y + 4, width: 120, height: 16)
                let s = selectAll.intrinsicContentSize
                selectAll.frame = NSRect(x: w - s.width, y: y, width: s.width, height: 24)
            }
            if b.view === status, !retry.isHidden {
                let s = retry.intrinsicContentSize
                retry.frame = NSRect(x: w - s.width, y: y, width: s.width, height: 24)
            }
            if b.view === backTitle { backBox.frame = NSRect(x: 0, y: y + 2, width: 16, height: 16) }
            y += b.height
        }
        // `max-h-72 divide-y overflow-y-auto rounded-lg border`.
        list.frame = NSRect(x: 0, y: 0, width: listScroll.bounds.width, height: listHeight(listScroll.bounds.width - 2) + 2)
        var ry: CGFloat = 1
        for (i, row) in rows.enumerated() {
            let h = row.height(forWidth: list.bounds.width - 2)
            row.frame = NSRect(x: 1, y: ry, width: list.bounds.width - 2, height: h)
            row.topRule = i > 0
            ry += h + 1
        }
        listBorder.frame = listScroll.frame
        listBorder.cornerRadius = DesignGeometry.usesClassic(self) ? 8 : RedesignTokens.Radius.control
        listBorder.borderWidth = 1
        listBorder.borderColor = Themed.color(\.border).cgColor(in: self)
        listScroll.layer?.cornerRadius = listBorder.cornerRadius
        listScroll.layer?.masksToBounds = true
    }
}

/// One machine (:303-354): `flex items-center gap-2.5 px-3 py-2 text-sm` with a checkbox, the machine glyph, the
/// label in `font-medium` with any error under it in destructive `text-xs`, and the status on the right.
@MainActor
final class LinkSeveralRowView: DSView {
    let machine: LinkableMachine
    let box = CheckboxView(value: .off)
    private let glyph = EnvironmentMachineGlyphView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
    private let label = LabelView("", font: DSFont.ui(14, weight: .medium), color: Themed.color(\.foreground))
    private let statusLabel = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    private var errorBlocks: [TextBlockView] = []
    private let rule = CALayer()
    var status: String? { didSet { statusLabel.text = status ?? ""; statusLabel.isHidden = status == nil; needsLayout = true } }
    var failed = false { didSet { statusLabel.color = Themed.color(failed ? \.destructive : \.mutedForeground) } }
    var topRule = false { didSet { rule.isHidden = !topRule } }
    var errors: [String] = [] {
        didSet {
            guard errors != oldValue else { return }
            errorBlocks.forEach { $0.removeFromSuperview() }
            errorBlocks = errors.map { TextBlockView($0, font: DSFont.ui(12), lineHeight: 16, color: Themed.color(\.destructive)) }
            errorBlocks.forEach { addSubview($0) }
            needsLayout = true
        }
    }

    init(machine: LinkableMachine, kind: String?) {
        self.machine = machine
        super.init(frame: .zero)
        glyph.kind = kind ?? "server"
        glyph.color = Themed.color(\.mutedForeground)
        label.text = machine.label
        label.lineHeight = 20
        statusLabel.lineHeight = 16
        box.setAccessibilityLabel(machine.label)
        [box, glyph, label, statusLabel].forEach { addSubview($0) }
        wantsLayer = true
        layer?.addSublayer(rule)
    }
    required init?(coder: NSCoder) { fatalError() }

    var textWidth: (CGFloat) -> CGFloat {
        { [unowned self] w in max(0, w - 24 - 16 - 10 - 16 - 10 - (status == nil ? 0 : ceil(statusLabel.textWidth) + 10)) }
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        16 + 20 + errorBlocks.reduce(0) { $0 + $1.height(forWidth: textWidth(width)) }
    }

    /// The whole row is the label for its checkbox (`<label className="cursor-pointer">`).
    override func mouseDown(with event: NSEvent) { if box.isEnabled { box.performAction() } }

    override func layout() {
        super.layout()
        let h = bounds.height
        box.frame = NSRect(x: 12, y: (h - 16) / 2, width: 16, height: 16)
        glyph.frame = NSRect(x: 38, y: (h - 16) / 2, width: 16, height: 16)
        let tw = textWidth(bounds.width)
        var y = 8.0
        let textH = 20 + errorBlocks.reduce(0) { $0 + $1.height(forWidth: tw) }
        y = (h - textH) / 2
        label.frame = NSRect(x: 64, y: y, width: tw, height: 20)
        y += 20
        for e in errorBlocks {
            let eh = e.height(forWidth: tw)
            e.frame = NSRect(x: 64, y: y, width: tw, height: eh)
            y += eh
        }
        let sw = ceil(statusLabel.textWidth)
        statusLabel.frame = NSRect(x: bounds.width - 12 - sw, y: (h - 16) / 2, width: sw, height: 16)
        rule.frame = CGRect(x: 0, y: -1, width: bounds.width, height: 1)
        rule.backgroundColor = Themed.color(\.border).cgColor(in: self)
    }
}

public enum LinkSeveralEnvironmentsDialog {
    /// The dialog (:203-431): `DialogPopup className="max-w-md"`, the title naming the source, Cancel or Done, and
    /// "Link N machines" or "Linking…".
    @MainActor
    public static func make(form: LinkSeveralEnvironmentsFormView) -> (dialog: DialogView, cancel: ButtonView, link: ButtonView) {
        let dialog = DialogView(title: form.sourceLabel.map { "Link several machines from \($0)" } ?? "Link several environments",
                                message: "Agents here can then launch, message and wait on threads on each machine you pick. Each appears "
                                    + "under Authorized clients in that machine's Sharing & access, where it can be revoked.")
        dialog.maxWidth = 448
        dialog.panelContent = [form]
        let cancel = ButtonView("Cancel", variant: .outline)
        cancel.reservedTitles = ["Done"]
        let link = ButtonView("Link 1 machine", variant: .default)
        link.reservedTitles = ["Linking…", "Link 99 machines"]
        dialog.footerButtons = [cancel, link]
        dialog.footerVariant = .bare
        form.onChange = { [weak link, weak cancel, weak form] in
            guard let form, let link, let cancel else { return }
            let n = form.chosen.count
            link.title = form.busy ? "Linking…" : n == 1 ? "Link 1 machine" : "Link \(n) machines"
            link.isEnabled = !form.busy && n > 0
            // Once a run linked everything picked, only Done is left (:420).
            link.isHidden = !form.outcomes.isEmpty && !form.busy && n == 0
            cancel.title = form.outcomes.isEmpty ? "Cancel" : "Done"
            cancel.isEnabled = !form.busy
        }
        form.onChange?()
        return (dialog, cancel, link)
    }
}
