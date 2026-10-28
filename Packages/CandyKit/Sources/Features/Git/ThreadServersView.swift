import AppKit
import DesignSystem
import T3Protocol

public enum ThreadServerPresentation {
    /// T3 3814 portDiscoveryState.ts: thread ownership can come from its terminal or agent.
    public static func servers(_ servers: [DiscoveredLocalServer], threadId: String) -> [DiscoveredLocalServer] {
        servers.filter { $0.terminal?.threadId == threadId || $0.agent?.threadId == threadId }
    }
    public static func source(_ server: DiscoveredLocalServer) -> String {
        ([server.terminal == nil ? "Agent" : "Terminal"] + [server.processName].compactMap { $0 }).joined(separator: " · ")
    }
    public static func opensExternally(modifiers: NSEvent.ModifierFlags, button: Int) -> Bool {
        modifiers.contains(.command) || modifiers.contains(.control) || button == 2
    }
    /// T3 3814 preview.ts:322-326. Never form a command for an unsupported host or an unknown process.
    public static func stopInput(_ server: DiscoveredLocalServer, supported: Bool, permitted: Bool) -> JSONValue? {
        guard supported, permitted, let pid = server.pid, pid > 0, (1...65535).contains(server.port) else { return nil }
        return .object(["pid": .number(Double(pid)), "port": .number(Double(server.port))])
    }
}

/// T3 3814 ThreadServersPanel.tsx:69-177. Source stays visible beside Stop, and Cmd-click opens externally.
public final class ThreadServersView: DSView {
    public var onOpen: ((DiscoveredLocalServer, Bool) -> Void)?
    public var onStop: ((DiscoveredLocalServer) -> Void)?
    public var onHeightChange: (() -> Void)?
    public private(set) var servers: [DiscoveredLocalServer] = []
    private var rows: [ThreadServerRow] = []
    private let heading = LabelView("Servers", font: DSFont.ui(11, weight: .medium), color: Themed.color(\.mutedForeground))
    public var isEmpty: Bool { servers.isEmpty }
    public var preferredHeight: CGFloat { isEmpty ? 0 : 8 + 20 + CGFloat(rows.count) * 44 + 8 }
    private var supportsStop = false, canOpen = false, canStop = false
    private var stopping: String?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        heading.lineHeight = 16
        addSubview(heading)
    }
    public func configure(servers: [DiscoveredLocalServer], supportsStop: Bool, canOpen: Bool, canStop: Bool, stopping: String?) {
        guard self.servers != servers || self.supportsStop != supportsStop || self.canOpen != canOpen || self.canStop != canStop || self.stopping != stopping else { return }
        let height = preferredHeight
        self.servers = servers; self.supportsStop = supportsStop; self.canOpen = canOpen; self.canStop = canStop; self.stopping = stopping
        while rows.count > servers.count { rows.removeLast().removeFromSuperview() }
        while rows.count < servers.count { let row = ThreadServerRow(); rows.append(row); addSubview(row) }
        for (index, server) in servers.enumerated() {
            let row = rows[index]
            let stoppable = ThreadServerPresentation.stopInput(server, supported: supportsStop, permitted: canStop) != nil
            row.configure(server, canOpen: canOpen, stoppable: stoppable, busy: stopping != nil,
                          stopping: stopping == Self.key(server))
            row.open.onOpen = { [weak self] external in self?.onOpen?(server, external) }
            row.stop.action = { [weak self] in
                guard let self, self.stopping == nil, stoppable else { return }
                self.onStop?(server)
            }
        }
        needsLayout = true
        if preferredHeight != height { onHeightChange?() }
    }
    public static func key(_ server: DiscoveredLocalServer) -> String { "\(server.pid ?? 0):\(server.port)" }
    public override func layout() {
        super.layout()
        heading.frame = NSRect(x: 18, y: 8, width: max(0, bounds.width - 36), height: 16)
        for (index, row) in rows.enumerated() { row.frame = NSRect(x: 8, y: 28 + CGFloat(index) * 44, width: max(0, bounds.width - 16), height: 44) }
    }
}

private final class ServerOpenControl: ControlView {
    var onOpen: ((Bool) -> Void)?
    private var external = false
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scalesWhenPressed = false
        action = { [weak self] in guard let self else { return }; onOpen?(external) }
    }
    override func mouseDown(with event: NSEvent) {
        external = ThreadServerPresentation.opensExternally(modifiers: event.modifierFlags, button: event.buttonNumber)
        super.mouseDown(with: event)
        external = false
    }
    override func otherMouseDown(with event: NSEvent) {
        if isEnabled, event.buttonNumber == 2 { onOpen?(true) }
    }
    override func updateLayer() { layer?.backgroundColor = state.hovered ? detailsHoverFill().cgColor : nil; layer?.cornerRadius = 10 }
    override func stateDidChange(from old: State) { super.stateDidChange(from: old); needsDisplay = true }
}

private final class ThreadServerRow: DSView {
    let open = ServerOpenControl()
    let stop = ButtonView(icon: .square, variant: .ghostMuted, size: .iconXs)
    private let icon = IconView(name: .globe, size: 16, strokeColor: Themed.color(\.mutedForeground))
    private let title = LabelView("", font: DSFont.ui(13, weight: .medium), color: Themed.color(\.foreground, 0.85))
    private let source = LabelView("", font: DSFont.ui(11), color: Themed.color(\.mutedForeground))
    private var spinner: SpinnerView?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(open)
        [icon, title, source].forEach(open.addSubview)
        addSubview(stop)
        title.lineHeight = 16; source.lineHeight = 16
        TooltipController.attach(to: open, text: "Open in the browser panel. ⌘-click for your browser.")
        TooltipController.attach(to: stop, text: "Stop server")
    }
    func configure(_ server: DiscoveredLocalServer, canOpen: Bool, stoppable: Bool, busy: Bool, stopping: Bool) {
        title.text = "localhost:\(server.port)"
        source.text = ThreadServerPresentation.source(server)
        open.setAccessibilityLabel(title.text + ", " + source.text)
        open.isEnabled = canOpen
        stop.setAccessibilityLabel("Stop localhost:\(server.port)")
        stop.isHidden = !stoppable
        stop.isEnabled = !busy
        if stopping {
            if spinner == nil { let view = SpinnerView(size: .xs); spinner = view; addSubview(view) }
            stop.alphaValue = 0
        } else { spinner?.removeFromSuperview(); spinner = nil; stop.alphaValue = 1 }
        needsLayout = true
    }
    override func layout() {
        super.layout()
        open.frame = bounds
        let right = stop.isHidden ? CGFloat(10) : 38
        icon.frame = NSRect(x: 10, y: 14, width: 16, height: 16)
        title.frame = NSRect(x: 36, y: 5, width: max(0, bounds.width - 36 - right), height: 16)
        source.frame = NSRect(x: 36, y: 23, width: title.frame.width, height: 16)
        stop.frame = NSRect(x: max(0, bounds.width - 28), y: 10, width: 24, height: 24)
        spinner?.frame = NSRect(x: stop.frame.midX - 6, y: stop.frame.midY - 6, width: 12, height: 12)
    }
}
