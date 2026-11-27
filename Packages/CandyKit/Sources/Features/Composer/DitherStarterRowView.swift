import AppKit
import DesignSystem

/// Redesign's starter action under the new-thread page's composer, after Capy's row of quiet buttons. It offers only
/// what the project control above it doesn't already settle: while the draft has a project, Start without a project
/// (where a machine has a scratch folder); while it has none, Add project. A quiet chip with no chevron, centred
/// under the composer; with nothing to offer the row is empty.
public final class DitherStarterRowView: DSView {
    public var onAddProject: (() -> Void)?
    public var onStartWithoutProject: (() -> Void)?
    /// The draft is in the scratch project ("No project").
    public var isScratch = false { didSet { if isScratch != oldValue { changed() } } }
    /// A machine offers a scratch folder (`DraftHeroView.offersScratch`).
    public var offersScratch = false { didSet { if offersScratch != oldValue { changed() } } }

    let addProject = DitherChipView(icon: IconView(name: .folderPlus, size: 14), accessibilityLabel: "Add project")
    let withoutProject = DitherChipView(icon: IconView(name: .squarePen, size: 14), accessibilityLabel: "Start without a project")

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.masksToBounds = false
        for (chip, title) in [(addProject, "Add project"), (withoutProject, "Start without a project")] {
            chip.text = title
            chip.quiet = true
            chip.showsChevron = false
            addSubview(chip)
        }
        addProject.action = { [weak self] in self?.onAddProject?() }
        withoutProject.action = { [weak self] in self?.onStartWithoutProject?() }
        setAccessibilityRole(.group)
        setAccessibilityLabel("Start")
        changed()
    }

    /// The chips shown now.
    var chips: [DitherChipView] { isScratch ? [addProject] : offersScratch ? [withoutProject] : [] }
    public var isEmpty: Bool { chips.isEmpty }

    private func changed() {
        let shown = chips
        for chip in [addProject, withoutProject] { chip.isHidden = !shown.contains { $0 === chip } }
        invalidateIntrinsicContentSize()
        needsLayout = true
        superview?.needsLayout = true
    }

    /// The row's width: the chips and the gaps between them.
    public var preferredWidth: CGFloat {
        let shown = chips
        return shown.reduce(0) { $0 + $1.intrinsicContentSize.width } + CGFloat(max(0, shown.count - 1)) * DitherPill.spacing
    }

    public override var intrinsicContentSize: NSSize { NSSize(width: preferredWidth, height: DitherPill.height) }

    public override func layout() {
        super.layout()
        // Centred in the row's bounds, so the caller can give it the composer's width.
        var x = ((bounds.width - preferredWidth) / 2).rounded()
        for chip in chips {
            let w = chip.intrinsicContentSize.width
            chip.frame = NSRect(x: x, y: 0, width: w, height: bounds.height)
            x += w + DitherPill.spacing
        }
    }
}
