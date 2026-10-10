import AppKit
import DesignSystem

/// The account's "T3 Connect" page (T3ConnectUserProfilePage.tsx), which T3 shows inside Clerk's account
/// modal. Here it is a Dialog opened from the account menu.
public struct T3ConnectAccountModel: Equatable {
    public struct Environment: Equatable {
        public var id: String
        public var label: String
        /// `Linked <date> · Managed tunnel|Activity publishing only`.
        public var detail: String
        public init(id: String, label: String, detail: String) { self.id = id; self.label = label; self.detail = detail }
    }

    public enum Content: Equatable {
        case loading
        case environments([Environment])
        case failed(String)
    }

    public var content: Content
    /// The row whose "Deregister server" confirmation is open.
    public var confirming: String?
    /// The row being deregistered; every button waits meanwhile.
    public var deregistering: String?

    public init(content: Content = .loading, confirming: String? = nil, deregistering: String? = nil) {
        self.content = content; self.confirming = confirming; self.deregistering = deregistering
    }

    /// `linkedAtLabel` and `endpointLabel` (T3ConnectUserProfilePage.tsx:26-39).
    public static func detail(linkedAt: Date?, providerKind: String) -> String {
        let date = linkedAt.map { "Linked \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "Link date unavailable"
        return date + " · " + (providerKind == "cloudflare_tunnel" ? "Managed tunnel" : "Activity publishing only")
    }
}

public enum T3ConnectAccountDialog {
    public static func make() -> (dialog: DialogView, page: T3ConnectAccountView) {
        let dialog = DialogView(title: "T3 Connect",
                                message: "Environments registered to your account. Connections on this device are managed in Settings.")
        dialog.maxWidth = 560
        let page = T3ConnectAccountView()
        dialog.panelContent = [page]
        return (dialog, page)
    }
}

public final class T3ConnectAccountView: DSView {
    public private(set) var model = T3ConnectAccountModel()
    public var onConfirm: ((String?) -> Void)?
    public var onDeregister: ((String) -> Void)?
    public var onHeightChange: (() -> Void)?
    private var rows: [Row] = []
    private let topRule = CALayer()
    private let status = TextBlockView()
    private let errorTitle = LabelView("Could not load T3 Connect environments", font: DSFont.ui(12, weight: .medium), color: Themed.color(\.destructiveForeground))
    private var empty: EmptyView?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        topRule.actions = ["position": NSNull(), "bounds": NSNull()]
        layer?.addSublayer(topRule)
        status.font = DSFont.ui(12)
        status.lineHeight = 16
        status.color = Themed.color(\.mutedForeground)
        errorTitle.lineHeight = 16
        addSubview(status)
        addSubview(errorTitle)
        set(model)
    }

    public func set(_ next: T3ConnectAccountModel) {
        model = next
        rows.forEach { $0.removeFromSuperview() }
        rows = []
        empty?.removeFromSuperview()
        empty = nil
        status.isHidden = true
        errorTitle.isHidden = true
        switch next.content {
        case .loading:
            status.text = "Loading environments…"
            status.isHidden = false
        case .failed(let message):
            errorTitle.isHidden = false
            status.text = message
            status.isHidden = false
        case .environments(let list) where list.isEmpty:
            let view = EmptyView(title: "No T3 Connect environments",
                                 message: "Link an environment from its local Settings to make it available through T3 Connect.",
                                 icon: .server, size: .compact)
            addSubview(view)
            empty = view
        case .environments(let list):
            for env in list {
                let row = Row(env, confirming: next.confirming == env.id, deregistering: next.deregistering == env.id,
                              busy: next.deregistering != nil)
                row.onToggle = { [weak self] open in self?.onConfirm?(open ? env.id : nil) }
                row.onDeregister = { [weak self] in self?.onDeregister?(env.id) }
                addSubview(row)
                rows.append(row)
            }
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
        onHeightChange?()
    }

    private func contentHeight(_ w: CGFloat) -> CGFloat {
        switch model.content {
        case .loading: 1 + 16 + status.height(forWidth: w) + 16
        case .failed: 1 + 12 + 16 + 4 + status.height(forWidth: w) + 12
        case .environments(let list) where list.isEmpty: 1 + (empty?.intrinsicContentSize.height ?? 160)
        case .environments: 1 + rows.reduce(0) { $0 + $1.height(forWidth: w) }
        }
    }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: bounds.width > 0 ? contentHeight(bounds.width) : 80)
    }

    public override func layout() {
        super.layout()
        let w = bounds.width
        CATransaction.begin(); CATransaction.setDisableActions(true)
        topRule.frame = CGRect(x: 0, y: 0, width: w, height: 1)
        CATransaction.commit()
        switch model.content {
        case .loading:
            status.frame = NSRect(x: 0, y: 17, width: w, height: status.height(forWidth: w))
        case .failed:
            errorTitle.frame = NSRect(x: 0, y: 13, width: w, height: 16)
            status.frame = NSRect(x: 0, y: 33, width: w, height: status.height(forWidth: w))
        case .environments:
            if let empty { empty.frame = NSRect(x: 0, y: 1, width: w, height: empty.intrinsicContentSize.height) }
            var y: CGFloat = 1
            for row in rows {
                let h = row.height(forWidth: w)
                row.frame = NSRect(x: 0, y: y, width: w, height: h)
                y += h
            }
        }
    }

    public override func updateLayer() {
        let failed: Bool = if case .failed = model.content { true } else { false }
        topRule.backgroundColor = (failed ? Themed.color(\.destructive, 0.35) : Themed.color(\.border)).cgColor(in: self)
    }

    /// `ClerkUserProfileRow` with `T3ConnectEnvironmentRow`: icon, label and detail, "Deregister", and the
    /// collapsible "Deregister server" confirmation.
    final class Row: DSView {
        private let icon = IconView(name: .server, size: 16)
        private let title = LabelView("", font: DSFont.ui(14, weight: .medium), color: Themed.color(\.foreground))
        private let detail = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
        private let toggle = ButtonView("Deregister", variant: .destructiveOutline, size: .sm)
        private let box = BoxDecorationLayer()
        private let boxTitle = LabelView("Deregister server", font: DSFont.ui(14, weight: .semibold), color: Themed.color(\.foreground))
        private let boxLine = TextBlockView()
        private let boxBody = TextBlockView()
        private let cancel = ButtonView("Cancel", variant: .ghost, size: .sm)
        private let confirm = ButtonView("Deregister", variant: .destructive, size: .sm)
        private let rule = CALayer()
        private let open: Bool
        var onToggle: ((Bool) -> Void)?
        var onDeregister: (() -> Void)?

        init(_ env: T3ConnectAccountModel.Environment, confirming: Bool, deregistering: Bool, busy: Bool) {
            open = confirming
            super.init(frame: .zero)
            icon.strokeColor = Themed.color(\.mutedForeground)
            title.text = env.label
            title.lineHeight = 18
            title.truncates = true
            detail.text = env.detail
            detail.lineHeight = 18
            boxTitle.lineHeight = 18
            for t in [boxLine, boxBody] {
                t.font = DSFont.ui(12)
                t.lineHeight = 18
                t.color = Themed.color(\.mutedForeground)
            }
            boxLine.text = "“\(env.label)” will be removed from this account."
            boxBody.text = "T3 Connect access will be revoked, any managed tunnel will be removed, and a host space will become available. Local connections on your devices are not changed."
            confirm.title = deregistering ? "Deregistering…" : "Deregister"
            for b in [toggle, cancel, confirm] { b.isEnabled = !busy }
            toggle.action = { [weak self] in self?.onToggle?(!(self?.open ?? false)) }
            cancel.action = { [weak self] in self?.onToggle?(false) }
            confirm.action = { [weak self] in self?.onDeregister?() }
            rule.actions = ["position": NSNull(), "bounds": NSNull()]
            layer?.addSublayer(rule)
            box.host = self
            var style = BoxStyle()
            style.radius = 10
            style.border = Themed.color(\.input)
            style.fill = Themed.color(\.muted, 0.32)
            box.boxStyle = style
            layer?.addSublayer(box)
            for v in [icon, title, detail, toggle, boxTitle, boxLine, boxBody, cancel, confirm] as [NSView] { addSubview(v) }
            for v in [boxTitle, boxLine, boxBody, cancel, confirm] as [NSView] { v.isHidden = !open }
            box.isHidden = !open
            setAccessibilityElement(true)
            setAccessibilityRole(.group)
            setAccessibilityLabel(open ? "Confirm deregistration of \(env.label)" : env.label)
        }

        private func boxHeight(_ w: CGFloat) -> CGFloat {
            let tw = max(0, w - 40)
            return 16 + 18 + 4 + boxLine.height(forWidth: tw) + 16 + boxBody.height(forWidth: tw) + 16 + 32 + 16
        }

        /// `py-4` around `flex items-start gap-4`, then `pt-3` and the box when open, a bottom rule.
        func height(forWidth w: CGFloat) -> CGFloat {
            16 + 40 + (open ? 12 + boxHeight(w - 32) : 0) + 16 + 1
        }

        override func layout() {
            super.layout()
            let w = bounds.width
            icon.frame = NSRect(x: 0, y: 17, width: 16, height: 16)
            let ts = toggle.intrinsicContentSize
            toggle.frame = NSRect(x: w - ts.width, y: 16, width: ts.width, height: ts.height)
            let textW = max(0, w - 32 - ts.width - 16)
            title.frame = NSRect(x: 32, y: 16, width: textW, height: 18)
            detail.frame = NSRect(x: 32, y: 38, width: textW, height: 18)
            if open {
                let bx: CGFloat = 32, bw = w - 32, by: CGFloat = 16 + 40 + 12
                let bh = boxHeight(bw)
                box.layout(boxSize: CGSize(width: bw, height: bh))
                box.frame.origin = CGPoint(x: bx - box.outset, y: by - box.outset)
                let tx = bx + 20, tw = bw - 40
                var y = by + 16
                boxTitle.frame = NSRect(x: tx, y: y, width: tw, height: 18); y += 22
                let lh = boxLine.height(forWidth: tw)
                boxLine.frame = NSRect(x: tx, y: y, width: tw, height: lh); y += lh + 16
                let bodyH = boxBody.height(forWidth: tw)
                boxBody.frame = NSRect(x: tx, y: y, width: tw, height: bodyH); y += bodyH + 16
                let cs = confirm.intrinsicContentSize, ks = cancel.intrinsicContentSize
                confirm.frame = NSRect(x: bx + bw - 20 - cs.width, y: y, width: cs.width, height: cs.height)
                cancel.frame = NSRect(x: confirm.frame.minX - 8 - ks.width, y: y, width: ks.width, height: ks.height)
            }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            rule.frame = CGRect(x: 0, y: bounds.height - 1, width: w, height: 1)
            CATransaction.commit()
        }

        override func updateLayer() { rule.backgroundColor = Themed.color(\.border).cgColor(in: self) }
        override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); box.setNeedsDisplay() }
    }
}
