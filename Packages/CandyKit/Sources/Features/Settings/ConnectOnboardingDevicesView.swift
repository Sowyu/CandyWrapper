import AppKit
import DesignSystem

/// ConnectOnboardingDialog.tsx:405-431. Reuses the Connections page's device rows.
public final class ConnectOnboardingDevicesView: DSView {
    private let group = SettingsGroupView(rows: [])
    private let empty = TextBlockView("No other environments are published to your account yet. Publish one from another device and it will show up here.", font: DSFont.ui(14))
    public var onAdd: ((String) -> Void)?
    public var onRetry: (() -> Void)?
    public var onHeightChange: (() -> Void)?
    public override init(frame: NSRect = .zero) {
        super.init(frame: frame)
        empty.color = Themed.color(\.mutedForeground); empty.alignment = .center; empty.lineHeight = 20
        addSubview(group); addSubview(empty)
    }
    public func set(_ model: ConnectionsPageModel.Cloud) {
        var rows: [any SettingsGroupRow] = []
        switch model {
        case .machines(let machines):
            for machine in machines {
                let row = CloudMachineRowView(); row.configure(machine)
                row.onAdd = { [weak self] in self?.onAdd?(machine.id) }; rows.append(row)
            }
        case .loading: rows.append(CloudSkeletonRowView())
        case .failed(let error):
            let row = CloudFailureRowView(); row.reason = error; row.onRetry = { [weak self] in self?.onRetry?() }; rows.append(row)
        default: break
        }
        group.rows = rows; empty.isHidden = !rows.isEmpty; group.isHidden = rows.isEmpty
        invalidateIntrinsicContentSize(); needsLayout = true; onHeightChange?()
    }
    public override var intrinsicContentSize: NSSize { NSSize(width: 464, height: empty.isHidden ? group.height(forWidth: 464) : 108) }
    public override func layout() {
        super.layout()
        group.frame = bounds
        empty.frame = bounds.insetBy(dx: 16, dy: 24)
    }
}
