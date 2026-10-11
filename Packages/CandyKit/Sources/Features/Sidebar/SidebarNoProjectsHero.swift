import AppKit
import DesignSystem

/// `NoProjectsHero` (apps/web/src/components/NoProjectsHero.tsx): the main area while no project exists.
/// "What should we work on?", then Add project and, where the environment has a scratch folder,
/// Start without a project.
public final class SidebarNoProjectsHeroView: DSView {
    private let empty = EmptyView(title: "What should we work on?", size: .hero)
    public let addProject = ButtonView("Add project", icon: .plus, size: .sm)
    public let startWithoutProject = ButtonView("Start without a project", icon: .messageSquareDashed, variant: .outline, size: .sm)

    /// Whether Start without a project shows (`scratchTargetEnvironmentId !== null`).
    public var offersScratch = false {
        didSet {
            guard offersScratch != oldValue else { return }
            startWithoutProject.isHidden = !offersScratch
            empty.message = offersScratch ? "Add a project, or start without one." : "Add a project to start your first thread."
            empty.content?.needsLayout = true; empty.needsLayout = true
            needsLayout = true
        }
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        empty.message = "Add a project to start your first thread."
        startWithoutProject.isHidden = true
        empty.content = SidebarNoProjectsButtons(addProject, startWithoutProject)
        addSubview(empty)
    }

    public override func layout() {
        super.layout()
        // `max-w-lg px-8 py-12` inside a centered flex column.
        let w = min(512, bounds.width)
        let h = empty.height(forWidth: w)
        empty.frame = NSRect(x: ((bounds.width - w) / 2).rounded(), y: ((bounds.height - h) / 2).rounded(), width: w, height: h)
    }

    public override func updateLayer() { layer?.backgroundColor = Themed.color(\.background).cgColor(in: self) }
}

/// `mt-6 flex justify-center gap-2`: the hero's buttons, centered.
private final class SidebarNoProjectsButtons: DSView {
    private let items: [ButtonView]
    init(_ items: ButtonView...) {
        self.items = items
        super.init(frame: .zero)
        items.forEach(addSubview)
    }
    private var shown: [ButtonView] { items.filter { !$0.isHidden } }
    override var intrinsicContentSize: NSSize {
        let sizes = shown.map(\.intrinsicContentSize)
        return NSSize(width: sizes.map(\.width).reduce(0, +) + 8 * CGFloat(max(0, sizes.count - 1)), height: sizes.map(\.height).max() ?? 0)
    }
    override func layout() {
        super.layout()
        var x = ((bounds.width - intrinsicContentSize.width) / 2).rounded()
        for b in shown {
            let s = b.intrinsicContentSize
            b.frame = NSRect(x: x, y: 0, width: s.width, height: s.height)
            x += s.width + 8
        }
    }
}
