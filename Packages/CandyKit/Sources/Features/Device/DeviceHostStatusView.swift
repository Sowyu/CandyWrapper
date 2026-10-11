import AppKit
import DesignSystem
import T3Protocol

/// Shared host status and version details, DeviceHostUpdates.tsx:24-74 and DeviceToolVersions.tsx:55-132.
public final class DeviceHostStatusView: DSView {
    private weak var modal: ModalHost?
    private let title = LabelView("", font: DSFont.ui(12, weight: .medium))
    private let detail = TextBlockView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    private let retry = ButtonView("Retry", variant: .outline, size: .compact)
    private let versions = ButtonView("Versions", variant: .ghostMuted, size: .xs)
    public var onRequest: (([String: JSONValue]) -> Void)?
    public private(set) var preferredHeight: CGFloat = 80
    public init(host: DevicePanelHost, state: DevicePanelState, pending: Bool = false) {
        super.init(frame: .zero)
        [title, detail, retry, versions].forEach(addSubview)
        title.text = host.label
        let status = state.hostStatuses?[host.id]
        var text = status?.message ?? ""
        let unavailable = host.platforms.filter { !$0.available }.compactMap(\.reason)
        if !unavailable.isEmpty { text += (text.isEmpty ? "" : "\n") + unavailable.joined(separator: "\n") }
        if status?.status == "failed" { text += "\nCheck the host connection and network access, then retry. Your device settings are saved." }
        detail.text = text
        detail.lineHeight = 16
        preferredHeight = status?.status == "failed" || !unavailable.isEmpty ? 132 : 80
        retry.isHidden = status?.status != "failed" || state.supportsHostRetry != true
        retry.isEnabled = !pending; retry.title = pending ? "Retrying…" : "Retry"
        retry.action = { [weak self] in self?.onRequest?(["retryHostId": .string(host.id)]) }
        versions.title = host.toolInspectionError == nil ? "Versions" : "Versions unavailable"
        versions.action = { [weak self] in self?.showVersions(host, state: state) }
    }
    private func showVersions(_ host: DevicePanelHost, state: DevicePanelState) {
        let dialog = DialogView(title: "Device tools")
        var text = ""
        if let tools = host.tools {
            for (label, tool) in [("Device hub", tools.hub), ("Agent device", tools.agent)] {
                text += "\(label)\nRunning    \(tool.runningVersion ?? "Not running")\nRequired    \(tool.requiredVersion)\nInstalled    \(tool.installedVersions.isEmpty ? "None" : tool.installedVersions.joined(separator: ", "))\n\n"
            }
        } else { text = "Versions have not been checked.\n\n" }
        text += "Tools update automatically on this host when needed."
        if let error = host.toolInspectionError { text += "\n\n" + error }
        dialog.message = text
        let close = ButtonView("Close", variant: .ghost)
        var actions: [NSView] = []
        if state.supportsToolUpdate == true {
            for (label, tool) in [("Update device hub", "hub"), ("Update agent device", "agent")] {
                let update = ButtonView(label, variant: .outline, size: .sm)
                update.action = { [weak self] in self?.onRequest?(["updateTool": .string(tool)]); self?.modal?.close() }
                actions.append(update)
            }
        }
        actions.append(close); dialog.footerButtons = actions
        close.action = { [weak self] in self?.modal?.close() }
        if let window { modal = ModalHost.present(dialog, in: window) }
    }
    public func height(forWidth width: CGFloat) -> CGFloat {
        max(preferredHeight, 60 + detail.height(forWidth: max(1, width - 26)))
    }
    public override var intrinsicContentSize: NSSize { NSSize(width: 440, height: height(forWidth: 440)) }
    public override func layout() {
        super.layout()
        title.frame = NSRect(x: 13, y: 9, width: max(0, bounds.width - 104), height: 16)
        detail.frame = NSRect(x: 13, y: 29, width: max(0, bounds.width - 26), height: max(0, bounds.height - 60))
        versions.frame = NSRect(x: 9, y: bounds.height - 29, width: 142, height: 24)
        retry.frame = NSRect(x: bounds.width - 13 - retry.intrinsicContentSize.width, y: 9, width: retry.intrinsicContentSize.width, height: 28)
    }
    public override func updateLayer() {
        layer?.borderWidth = 1; layer?.borderColor = Themed.color(\.border, 0.6).cgColor(in: self); layer?.cornerRadius = 8
    }
}
