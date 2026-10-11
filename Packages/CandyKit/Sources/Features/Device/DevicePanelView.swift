import AppKit
import DesignSystem
import T3Protocol

/// DevicePanel.tsx:203-310 and DeviceSetup.tsx:108-239, using the shared native controls.
public final class DevicePanelView: DSView {
    public let viewer = DevicePanelStreamView()
    public var onToolsClosed: (() -> Void)?
    public var onReadDetail: (() -> Void)?
    public var onFloat: (() -> Void)?
    public private(set) var toolsDrawer: DeviceToolsDrawerView?
    private var toolsDeviceKey: String?
    public func closeTools() { onToolsClosed?(); toolsDrawer?.removeFromSuperview(); toolsDrawer = nil; toolsDeviceKey = nil; needsLayout = true }
    public var onRefresh: (() -> Void)?
    public var onConfigure: (([String: JSONValue]) -> Void)?
    public var onOpen: ((DevicePanelDevice) -> Void)?
    public var onSelect: ((DevicePanelDevice) -> Void)?
    public var onClose: ((DevicePanelDevice) -> Void)?
    public var onButton: ((String) -> Void)?
    public var onAction: (([String: JSONValue]) -> Void)?
    private let heading = LabelView("Devices", font: DSFont.ui(14, weight: .medium))
    private let message = TextBlockView("Finding devices…", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    private let empty = DevicePanelEmptyView()
    private let refresh = ButtonView("Refresh devices", variant: .outline, size: .sm)
    private let setup = ButtonView("Enable the device hub", variant: .outline, size: .sm)
    private let agent = ButtonView("Allow agent control", variant: .outline, size: .sm)
    private let done = ButtonView("Done", variant: .outline, size: .sm)
    private let tools = ButtonView("Tools", variant: .ghost, size: .sm)
    private var rows: [ButtonView] = []
    private var rail: [ButtonView] = []
    private var state: DevicePanelState?
    private var active: DevicePanelDevice?
    public override init(frame: NSRect) {
        super.init(frame: frame)
        message.alignment = .center
        [empty, heading, message, refresh, setup, agent, done, viewer, tools].forEach(addSubview)
        refresh.action = { [weak self] in self?.onRefresh?() }
        empty.refresh.action = { [weak self] in self?.onRefresh?() }
        setup.action = { [weak self] in self?.onConfigure?(["enabled": .bool(true)]) }
        agent.action = { [weak self] in guard let self else { return }; self.onConfigure?(["agentAccessEnabled": .bool(!(self.state?.agentAccessEnabled ?? false))]) }
        done.action = { [weak self] in self?.onConfigure?(["onboardingCompleted": .bool(true)]) }
        tools.action = { [weak self] in self?.showTools() }
        apply(nil, thread: "", selected: nil)
    }
    public func showError(_ text: String) { empty.isHidden = true; message.text = text; message.isHidden = false }
    public func apply(_ state: DevicePanelState?, thread: String, selected: String?) {
        self.state = state
        rows.forEach { $0.removeFromSuperview() }; rows = []
        rail.forEach { $0.removeFromSuperview() }; rail = []
        let sessions = state?.sessions.filter { $0.threadId == thread } ?? []
        let opened = state?.devices.filter { device in sessions.contains { $0.key == device.key } } ?? []
        active = opened.first { $0.key == selected } ?? opened.first
        if toolsDeviceKey != nil && toolsDeviceKey != active?.key { closeTools() }
        let setupNeeded = state?.onboardingCompleted == false
        let busy = state?.hostStatus == "installing" || state?.hostStatus == "starting"
        setup.isEnabled = !busy; agent.isEnabled = !busy; done.isEnabled = !busy; refresh.isEnabled = !busy
        setup.title = busy ? "Installing device support…" : "Enable the device hub"
        viewer.isHidden = active == nil || setupNeeded
        tools.isHidden = viewer.isHidden
        setup.isHidden = !setupNeeded || state?.hostStatus == "ready"
        agent.isHidden = !setupNeeded || state?.hostStatus != "ready"
        done.isHidden = agent.isHidden
        agent.title = state?.agentAccessEnabled == true ? "Disable agent control" : "Allow agent control"
        heading.text = setupNeeded ? "Set up devices" : active?.name ?? "Devices"
        message.isHidden = !viewer.isHidden
        if let state {
            if setupNeeded {
                message.text = [state.hostStatusDetail, state.platformMessage("ios"), state.platformMessage("android")].compactMap { $0 }.joined(separator: "\n\n")
            } else {
                message.text = state.hostStatusDetail ?? (state.hostStatus == "installing" ? "Installing device support…" : state.devices.isEmpty ? "No simulators or emulators were found on this environment." : "")
            }
            if !setupNeeded {
                for device in state.devices {
                    let isOpen = opened.contains { $0.key == device.key }
                    let row = ButtonView(isOpen ? device.name : "\(device.name) · \(device.version) · \(device.booted ? "Open" : "Start")", variant: active?.key == device.key ? .secondary : .ghost, size: .sm)
                    row.action = { [weak self] in if isOpen { self?.onSelect?(device) } else { self?.onOpen?(device) } }
                    rows.append(row); addSubview(row)
                }
            }
        } else { message.text = "Finding devices…" }
        if let active, !viewer.isHidden {
            let buttons: [(String, IconName)] = active.platform == "ios" ? [("home", .home), ("appSwitcher", .square), ("power", .power)] : [("home", .home), ("back", .arrowLeft), ("recents", .square), ("power", .power)]
            for (name, icon) in buttons {
                let button = ButtonView(nil, icon: icon, variant: .ghost, size: .iconSm)
                button.setAccessibilityLabel(name)
                button.action = { [weak self] in self?.onButton?(name) }
                rail.append(button); addSubview(button)
            }
            let floating = ButtonView(nil, icon: .pictureInPicture2, variant: .ghost, size: .iconSm)
            floating.setAccessibilityLabel("Float device over chat")
            floating.action = { [weak self] in self?.onFloat?() }
            rail.append(floating); addSubview(floating)
            let close = ButtonView(nil, icon: .x, variant: .ghost, size: .iconSm)
            close.setAccessibilityLabel("Close device")
            close.action = { [weak self] in self?.onClose?(active) }
            rail.append(close); addSubview(close)
        }
        empty.isHidden = state == nil || setupNeeded || !(state?.devices.isEmpty ?? true) || state?.hostStatus == "installing" || state?.hostStatus == "starting"
        if !empty.isHidden {
            empty.detail = state?.hostStatusDetail ?? "No simulators or emulators were found on this environment."
            message.isHidden = true
        }
        refresh.isHidden = !empty.isHidden
        if let toolsDrawer { addSubview(toolsDrawer, positioned: .above, relativeTo: nil) }
        needsLayout = true
    }
    private func showTools() {
        guard let active else { return }
        if toolsDrawer != nil { closeTools(); return }
        let drawer = DeviceToolsDrawerView()
        drawer.configure(platform: active.platform)
        drawer.onAction = { [weak self] in self?.onAction?($0) }
        drawer.onClose = { [weak self] in self?.closeTools() }
        toolsDrawer = drawer; toolsDeviceKey = active.key
        addSubview(drawer); onReadDetail?(); needsLayout = true
    }
    public override func layout() {
        super.layout()
        empty.frame = NSRect(x: 0, y: 40, width: bounds.width, height: max(0, bounds.height - 40))
        heading.frame = NSRect(x: 16, y: 8, width: max(0, bounds.width - 110), height: 24)
        tools.frame = NSRect(x: bounds.width - 70, y: 8, width: 60, height: 24)
        var y: CGFloat = 44
        for row in rows { row.frame = NSRect(x: 16, y: y, width: max(0, bounds.width - 32), height: 28); y += 30 }
        viewer.frame = NSRect(x: 16, y: y + 8, width: max(0, bounds.width - 72), height: max(0, bounds.height - y - 58))
        for (i, button) in rail.enumerated() { button.frame = NSRect(x: bounds.width - 44, y: y + 12 + CGFloat(i) * 36, width: 28, height: 28) }
        message.frame = NSRect(x: 24, y: max(y + 16, bounds.height / 2 - 65), width: max(0, bounds.width - 48), height: 130)
        refresh.frame = NSRect(x: max(16, (bounds.width - 150) / 2), y: bounds.height - 42, width: 150, height: 28)
        setup.frame = NSRect(x: 24, y: 48, width: min(250, bounds.width - 48), height: 28)
        agent.frame = setup.frame
        toolsDrawer?.frame = NSRect(x: max(0, bounds.width - 320), y: 40, width: min(320, bounds.width), height: max(0, bounds.height - 40))
        done.frame = NSRect(x: bounds.width - 84, y: 84, width: 60, height: 28)
    }
    public override func updateLayer() { layer?.backgroundColor = Themed.color(\.background).cgColor(in: self) }
}

/// Frames have already been decoded. The layer retains only the newest image.
public final class DevicePanelStreamView: DSView {
    public var onTouch: ((String, Double, Double) -> Void)?
    public var onKey: ((UInt16, String?, Bool) -> Void)?
    public var orientation = "portrait" { didSet { needsLayout = true } }
    public override var acceptsFirstResponder: Bool { true }
    public override func keyDown(with event: NSEvent) { onKey?(event.keyCode, event.characters, true) }
    public override func keyUp(with event: NSEvent) { onKey?(event.keyCode, event.characters, false) }
    private let screen = CALayer()
    private var size = CGSize(width: 390, height: 844)
    private var touching = false
    public override init(frame: NSRect) {
        super.init(frame: frame)
        screen.contentsGravity = .resizeAspect
        screen.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(screen)
    }
    public func present(_ image: CGImage) {
        size = CGSize(width: image.width, height: image.height)
        screen.contents = image
        needsLayout = true
    }
    public func clear() { screen.contents = nil; touching = false }
    public override func layout() {
        super.layout()
        let rotate = size.width <= size.height
        let sideways = rotate && orientation.hasPrefix("landscape")
        let shown = sideways ? CGSize(width: size.height, height: size.width) : size
        let scale = min(bounds.width / shown.width, bounds.height / shown.height)
        screen.bounds = CGRect(origin: .zero, size: CGSize(width: size.width * scale, height: size.height * scale))
        screen.position = CGPoint(x: bounds.midX, y: bounds.midY)
        let angle: CGFloat = !rotate ? 0 : orientation == "landscape_left" ? .pi / 2 : orientation == "landscape_right" ? -.pi / 2 : orientation == "portrait_upside_down" ? .pi : 0
        screen.setAffineTransform(CGAffineTransform(rotationAngle: angle))
    }
    public override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard screen.frame.contains(p) else { return }
        window?.makeFirstResponder(self)
        touching = true; touch("begin", event)
    }
    public override func mouseDragged(with event: NSEvent) { if touching { touch("move", event) } }
    public override func mouseUp(with event: NSEvent) { if touching { touch("end", event); touching = false } }
    private func touch(_ phase: String, _ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil), f = screen.frame
        guard f.width > 0, f.height > 0 else { return }
        var x = Double((p.x - f.minX) / f.width), y = Double((p.y - f.minY) / f.height)
        if size.width <= size.height {
            switch orientation {
            case "landscape_left": (x, y) = (y, 1 - x)
            case "landscape_right": (x, y) = (1 - y, x)
            case "portrait_upside_down": (x, y) = (1 - x, 1 - y)
            default: break
            }
        }
        onTouch?(phase, x, y)
    }
}
