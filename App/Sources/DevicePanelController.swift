import AppKit
import Features
import T3Client
import T3Protocol
import T3Store

/// One visible device workspace. subscribeDeviceState replaces polling (rpc.ts:1552-1557).
@MainActor
final class DevicePanelController {
    private let panel: ThreadPanelView
    private let environments: Environments
    private weak var files: FilesController?
    private var thread: ThreadId?
    private var operationError: String?
    private var state: DevicePanelState?
    private var selected: String?
    private var subscription: Task<Void, Never>?
    private var load: Task<Void, Never>?
    private var connect: Task<Void, Never>?
    private var stream: DevicePanelStreamClient?
    private var streamKey: String?
    private var occlusion: NSObjectProtocol?
    private var view: DevicePanelView { panel.devicePanel }
    init(panel: ThreadPanelView, environments: Environments, files: FilesController) {
        self.panel = panel; self.environments = environments; self.files = files
        view.onRefresh = { [weak self] in self?.stopStream(); self?.request("device.list", [:]) }
        view.onConfigure = { [weak self] values in self?.request("device.configure", values) }
        view.onOpen = { [weak self] device in
            guard let self, let thread else { return }
            selected = device.key
            request("device.open", ["threadId": .string(thread.localId.rawValue), "deviceId": .string(device.id), "hostId": .string(device.hostId), "platform": .string(device.platform)])
        }
        view.onSelect = { [weak self] device in self?.selected = device.key; self?.render() }
        view.onClose = { [weak self] device in
            guard let self, let thread else { return }
            request("device.close", ["threadId": .string(thread.localId.rawValue), "deviceId": .string(device.id), "hostId": .string(device.hostId)])
        }
        view.onButton = { [weak self] name in self?.stream?.press(name) }
        view.onAction = { [weak self] values in
            guard let self, let device = active else { return }
            var payload = values; payload["deviceId"] = .string(device.id); payload["hostId"] = .string(device.hostId)
            request("device.action", payload)
        }
        view.viewer.onKey = { [weak self] code, text, down in self?.stream?.key(code: code, text: text, down: down) }
        view.viewer.onTouch = { [weak self] phase, x, y in
            guard let self, let device = active else { return }
            stream?.send(DevicePanelWire.touch(platform: device.platform, phase: phase, x: x, y: y))
        }
        occlusion = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
    }
    private var visible: Bool {
        panel.panelState.isOpen && panel.panelState.active?.kind == .device && panel.window?.occlusionState.contains(.visible) == true
    }
    func sync() {
        let next = files?.currentThreadId
        if next != thread {
            stopStream(); subscription?.cancel(); subscription = nil; load?.cancel()
            thread = next; state = nil; selected = nil
        }
        guard visible, let thread, let env = thread.environmentId, let shell = environments.session(env) else {
            stopStream(); subscription?.cancel(); subscription = nil; load?.cancel(); return
        }
        if subscription == nil {
            subscription = shell.supervisor.subscribe("subscribeDeviceState", payload: { .object([:]) }, handler: { [weak self] event in
                guard case .value(let json) = event, let state = try? JSONValueDecoder().decode(DevicePanelState.self, from: json) else { return }
                await MainActor.run { guard self?.thread == thread else { return }; self?.state = state; self?.render() }
            })
            request("device.list", [:])
        }
        render()
    }
    private var active: DevicePanelDevice? {
        guard let state, let thread else { return nil }
        let sessions = state.sessions.filter { $0.threadId == thread.localId.rawValue }
        let devices = state.devices.filter { d in sessions.contains { $0.key == d.key } }
        return devices.first { $0.key == selected } ?? devices.first
    }
    private func render() {
        view.apply(state, thread: thread?.localId.rawValue ?? "", selected: selected)
        if let operationError { view.showError(operationError) }
        guard visible, state?.onboardingCompleted == true, let device = active,
              let thread, let env = thread.environmentId, let shell = environments.session(env) else { stopStream(); return }
        let key = thread.rawValue + ":" + device.key
        guard key != streamKey else { return }
        stopStream(); streamKey = key
        let http = shell.http, token = shell.token, hub = state?.hubBasePath ?? "/api/device-hub"
        connect = Task { [weak self] in
            do {
                let ticket = try await http.webSocketTicket(token: token)
                guard let self, !Task.isCancelled, self.streamKey == key,
                      let video = DevicePanelWire.url(base: http.baseURL, hubPath: hub, platform: device.platform, deviceId: device.id, hostId: device.hostId, ticket: ticket.ticket, video: true),
                      let input = DevicePanelWire.url(base: http.baseURL, hubPath: hub, platform: device.platform, deviceId: device.id, hostId: device.hostId, ticket: ticket.ticket, video: false) else { return }
                let client = DevicePanelStreamClient(platform: device.platform)
                self.stream = client
                client.onOrientation = { [weak self] orientation in self?.view.viewer.orientation = orientation }
                client.onFrame = { [weak self] frame in self?.view.viewer.present(frame) }
                client.onError = { [weak self] error in self?.view.showError(error) }
                client.start(videoURL: video, inputURL: input)
            } catch { if !Task.isCancelled { self?.view.showError("Could not connect to device support.") } }
        }
    }
    private func request(_ method: String, _ payload: [String: JSONValue]) {
        guard let thread, let env = thread.environmentId, let shell = environments.session(env) else { return }
        operationError = nil
        load?.cancel()
        load = Task { [weak self] in
            do {
                let result = try await shell.supervisor.request(method, payload: .object(payload))
                guard let self, self.thread == thread, !Task.isCancelled else { return }
                if let state = try? JSONValueDecoder().decode(DevicePanelState.self, from: result) { self.state = state }
                self.render()
            } catch { if !Task.isCancelled { self?.operationError = String(describing: error); self?.render() } }
        }
    }
    private func stopStream() {
        connect?.cancel(); connect = nil; stream?.stop(); stream = nil; streamKey = nil
        view.viewer.clear()
    }
}
