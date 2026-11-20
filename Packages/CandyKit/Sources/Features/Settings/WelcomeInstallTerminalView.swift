import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// `AgentInstallTerminal` (WelcomePage.tsx:1289-1470): a shell on the computer with the install or sign-in
/// command typed in and not run, so the user reviews it and presses Return. It belongs to the onboarding
/// thread id, and closing it deletes its history.
@MainActor
final class WelcomeInstallTerminalView: DSView, WelcomeRowSizing {
    static let threadId = "onboarding-agent-setup"
    enum Setup: Equatable { case preparing, ready, openFailed, writeFailed }

    let instanceId: String
    var onCommandFinished: (() -> Void)?
    var onClose: (() -> Void)?

    private let context: SettingsPageContext
    private let environmentId: String
    private let terminalId: String
    private let cwd: String
    private let command: String
    private var setup = Setup.preparing { didSet { restyle() } }
    private var model = TerminalSessionModel()
    private var commandStarted = false
    private var stream: Task<Void, Never>?
    private var opening: Task<Void, Never>?
    private var closed = false

    private let header = WelcomeTerminalHeader()
    private let status = LabelView("", font: DSFont.ui(11, weight: .medium), color: Themed.color(\.mutedForeground))
    private let retry = ButtonView("Retry", variant: .ghost, size: .xs)
    private let closeButton = ButtonView("Close", variant: .ghostMuted, size: .xs)
    private let surface = TerminalSurfaceView()

    init(context: SettingsPageContext, environmentId: String, driver: String, instanceId: String, cwd: String, command: String) {
        self.context = context; self.environmentId = environmentId; self.instanceId = instanceId
        self.cwd = cwd; self.command = command
        terminalId = "onboarding-\(driver)-\(UUID().uuidString.lowercased())"
        super.init(frame: .zero)
        status.lineHeight = 16
        [header, status, retry, closeButton, surface].forEach(addSubview)
        surface.isHidden = true
        retry.action = { [weak self] in self?.start() }
        closeButton.action = { [weak self] in self?.onClose?() }
        surface.onInput = { [weak self] data in self?.write(data) }
        surface.onResize = { [weak self] cols, rows in self?.resize(cols: cols, rows: rows) }
        setAccessibilityRole(.group); setAccessibilityLabel("Install \(driver)")
        restyle()
    }

    private var fields: [String: JSONValue] {
        ["threadId": .string(Self.threadId), "terminalId": .string(terminalId), "cwd": .string(cwd), "providerInstanceId": .string(instanceId)]
    }

    /// Opens the shell, types the command, then attaches to show it.
    func start() {
        opening?.cancel()
        setup = .preparing
        guard let request = context.request else { setup = .openFailed; return }
        let env = environmentId, open = JSONValue.object(fields)
        let write = TerminalRPC.writeInput(threadId: Self.threadId, terminalId: terminalId, data: command)
        opening = Task { [weak self] in
            do { _ = try await request(env, TerminalRPC.open, open) } catch {
                if !Task.isCancelled { self?.setup = .openFailed }
                return
            }
            guard let self, !Task.isCancelled, !closed else { return }
            attach()
            do { _ = try await request(env, TerminalRPC.write, write); setup = .ready } catch { setup = .writeFailed }
        }
    }

    private func attach() {
        stream?.cancel()
        surface.isHidden = false
        guard let subscribe = context.subscribe else { return }
        stream = subscribe(environmentId, TerminalRPC.attach, .object(fields)) { [weak self] json in
            guard let self, let event = TerminalAttachEvent(json: json) else { return }
            let wasRunning = model.hasRunningSubprocess
            let outcome = model.apply(event)
            surface.setSharedGrid(cols: model.cols, rows: model.rows)
            for action in outcome.actions { surface.apply(action) }
            if outcome.resendSize { surface.resendSize() }
            // The shell stays open after the command, so its exit is the signal to check the agent again.
            if model.hasRunningSubprocess { commandStarted = true }
            else if wasRunning && commandStarted { commandStarted = false; onCommandFinished?() }
            if outcome.sessionEnded { DispatchQueue.main.async { [weak self] in self?.onClose?() } }
        }
        DispatchQueue.main.async { [weak self] in self?.surface.focus() }
    }

    private func write(_ data: String) {
        guard let request = context.request else { return }
        let env = environmentId
        for chunk in TerminalRPC.writeChunks(data) {
            let payload = TerminalRPC.writeInput(threadId: Self.threadId, terminalId: terminalId, data: chunk)
            Task { _ = try? await request(env, TerminalRPC.write, payload) }
        }
    }

    private func resize(cols: Int, rows: Int) {
        guard model.canResize, let request = context.request else { return }
        let env = environmentId
        let payload = TerminalRPC.resizeInput(threadId: Self.threadId, terminalId: terminalId, cols: cols, rows: rows)
        Task { _ = try? await request(env, TerminalRPC.resize, payload) }
    }

    /// Stops the stream and closes the shell on the server, deleting its history.
    func close() {
        guard !closed else { return }
        closed = true
        opening?.cancel(); stream?.cancel()
        guard let request = context.request else { return }
        let env = environmentId
        let payload = TerminalRPC.closeInput(threadId: Self.threadId, terminalId: terminalId, deleteHistory: true)
        Task { _ = try? await request(env, TerminalRPC.close, payload) }
    }

    private func restyle() {
        status.text = switch setup {
        case .writeFailed: "Run \(command) in this terminal."
        case .ready: "Review the command, then press Enter to run it."
        case .openFailed: "Could not open the setup terminal."
        case .preparing: "Preparing command..."
        }
        retry.isHidden = setup != .openFailed
        needsLayout = true
    }

    func height(forWidth width: CGFloat) -> CGFloat { 30 + 256 + 2 }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = Themed.color(\.border, 0.7).cgColor(in: self)
        layer?.backgroundColor = Themed.color(\.background).cgColor(in: self)
    }
    override func layout() {
        super.layout()
        header.frame = NSRect(x: 1, y: 1, width: bounds.width - 2, height: 30)
        let cs = closeButton.intrinsicContentSize
        closeButton.frame = NSRect(x: bounds.width - 12 - cs.width, y: 1 + (30 - cs.height) / 2, width: cs.width, height: cs.height)
        let rs = retry.intrinsicContentSize
        retry.frame = NSRect(x: closeButton.frame.minX - 4 - rs.width, y: closeButton.frame.minY, width: rs.width, height: rs.height)
        status.frame = NSRect(x: 12, y: 1 + 7, width: max(0, (retry.isHidden ? closeButton.frame.minX : retry.frame.minX) - 20), height: 16)
        surface.frame = NSRect(x: 1, y: 31, width: bounds.width - 2, height: 256)
    }
}

/// The header strip: `border-b border-border/60 bg-background/60`.
final class WelcomeTerminalHeader: DSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = Themed.color(\.background, 0.6).cgColor(in: self)
        let line = layer?.sublayers?.first ?? { let l = CALayer(); layer?.addSublayer(l); return l }()
        line.frame = CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
        line.backgroundColor = Themed.color(\.border, 0.6).cgColor(in: self)
    }
    override func layout() { super.layout(); needsDisplay = true }
}
