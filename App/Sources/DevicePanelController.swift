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
    private var floating = false
    private let floatingViewer = DevicePanelStreamView()
    private var selected: String?
    private var subscription: Task<Void, Never>?
    private var load: Task<Void, Never>?
    private var connect: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var stream: DevicePanelStreamClient?
    private var streamKey: String?
    private var occlusion: NSObjectProtocol?
    private var view: DevicePanelView { panel.devicePanel }
    init(panel: ThreadPanelView, environments: Environments, files: FilesController) {
        self.panel = panel; self.environments = environments; self.files = files
        panel.deviceMiniPlayer.deviceContent = floatingViewer
        panel.deviceMiniPlayer.setAccessibilityLabel("Floating device preview")
        view.onFloat = { [weak self] in
            guard let self, active != nil else { return }
            floating = true; panel.deviceMiniPlayerShown = true
            panel.mutatePanel { $0.isOpen = false; return [] }; render()
        }
        panel.deviceMiniPlayer.onClose = { [weak self] in
            guard let self else { return }
            floating = false; panel.deviceMiniPlayerShown = false; sync()
        }
        panel.deviceMiniPlayer.onOpenInPanel = { [weak self] in
            guard let self else { return }
            floating = false; panel.deviceMiniPlayerShown = false
            panel.mutatePanel { $0.open(.device); return [] }; sync()
        }
        panel.deviceMiniPlayer.onMove = { [weak self] in self?.panel.deviceMiniPlayerOrigin = $0 }
        panel.deviceMiniPlayer.onResize = { [weak self] in self?.panel.deviceMiniPlayerSize = $0 }
        view.onHostRequest = { [weak self] in self?.request("device.list", $0) }
        view.onRefresh = { [weak self] in self?.stopStream(); self?.request("device.list", [:]) }
        view.onConfigure = { [weak self] values in self?.request("device.configure", values) }
        view.onOpen = { [weak self] device in
            guard let self, let thread else { return }
            selected = device.key
            request("device.open", ["threadId": .string(thread.localId.rawValue), "deviceId": .string(device.id), "hostId": .string(device.hostId), "platform": .string(device.platform)])
        }
        view.onSelect = { [weak self] device in self?.selectDevice(device) }
        view.onClose = { [weak self] device in
            guard let self else { return }
            let id = DevicePanelSurface(hostId: device.hostId, deviceId: device.id, platform: device.platform, name: device.name).id
            panel.mutatePanel { $0.close(id) }
            sync()
        }
        view.onToolsClosed = { [weak self] in self?.detailTask?.cancel(); self?.detailTask = nil }
        view.onReadDetail = { [weak self] in self?.readDetail() }
        view.onButton = { [weak self] name in self?.stream?.press(name) }
        view.onAction = { [weak self] values in
            guard let self, let device = active else { return }
            var payload = values; payload["deviceId"] = .string(device.id); payload["hostId"] = .string(device.hostId)
            readDetail(action: payload)
        }
        view.viewer.onKey = { [weak self] code, text, down in self?.stream?.key(code: code, text: text, down: down) }
        view.viewer.onTouch = { [weak self] phase, x, y in
            guard let self, let device = active else { return }
            stream?.send(DevicePanelWire.touch(platform: device.platform, phase: phase, x: x, y: y))
        }
        floatingViewer.onKey = view.viewer.onKey
        floatingViewer.onTouch = view.viewer.onTouch
        occlusion = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
    }
    private var visible: Bool {
        !panel.isHiddenOrHasHiddenAncestor && (floating || (panel.panelState.isOpen && panel.panelState.active?.kind == .device)) && panel.window?.occlusionState.contains(.visible) == true
    }
    func sync() {
        let next = files?.currentThreadId
        if next != thread {
            stopStream(); subscription?.cancel(); subscription = nil; load?.cancel()
            floating = false; panel.deviceMiniPlayerShown = false
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
    private func selectDevice(_ device: DevicePanelDevice) {
        selected = device.key
        panel.mutatePanel { $0.openDevice(DevicePanelSurface(hostId: device.hostId, deviceId: device.id, platform: device.platform, name: device.name)); return [] }
        render()
    }
    private var active: DevicePanelDevice? {
        guard let state, let thread else { return nil }
        let sessions = state.sessions.filter { $0.threadId == thread.localId.rawValue }
        let devices = state.devices.filter { d in sessions.contains { $0.key == d.key } }
        if !floating, let target = panel.panelState.active?.deviceTarget {
            return devices.first { $0.hostId == target.hostId && $0.id == target.deviceId }
        }
        return devices.first { $0.key == selected } ?? devices.first
    }
    private func render() {
        view.apply(state, thread: thread?.localId.rawValue ?? "", selected: active?.key ?? selected)
        if let operationError { view.showError(operationError) }
        guard visible, state?.onboardingCompleted == true, let device = active,
              let thread, let env = thread.environmentId, let shell = environments.session(env) else { stopStream(); return }
        let key = thread.rawValue + ":" + device.key + (floating ? ":float" : "")
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
                client.onOrientation = { [weak self] orientation in self?.view.viewer.orientation = orientation; self?.floatingViewer.orientation = orientation }
                client.onFrame = { [weak self] frame in guard let self else { return }; (self.floating ? self.floatingViewer : self.view.viewer).present(frame) }
                client.onError = { [weak self] error in self?.view.showError(error) }
                client.start(videoURL: video, inputURL: input)
            } catch { if !Task.isCancelled { self?.view.showError("Could not connect to device support.") } }
        }
    }
    private func readDetail(action: [String: JSONValue]? = nil) {
        guard let thread, let device = active, let env = thread.environmentId, let shell = environments.session(env) else { return }
        detailTask?.cancel()
        view.toolsDrawer?.pending = true
        detailTask = Task { [weak self] in
            do {
                let result = try await shell.supervisor.request(action == nil ? "device.detail" : "device.action", payload: .object(action ?? ["deviceId": .string(device.id), "hostId": .string(device.hostId)]))
                guard let self, !Task.isCancelled, self.thread == thread, self.active?.key == device.key else { return }
                self.view.toolsDrawer?.pending = false; self.view.toolsDrawer?.apply(result)
            } catch {
                guard !Task.isCancelled else { return }
                self?.view.toolsDrawer?.pending = false; self?.view.toolsDrawer?.apply(nil, error: String(describing: error))
            }
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
                if method == "device.open" {
                    let json = try await shell.supervisor.request("device.list", payload: .object([:]))
                    guard !Task.isCancelled, self.thread == thread else { return }
                    self.state = try JSONValueDecoder().decode(DevicePanelState.self, from: json)
                }
                if method == "device.open", let device = self.state?.devices.first(where: { $0.key == self.selected }) { self.selectDevice(device) }
                self.render()
            } catch { if !Task.isCancelled { self?.operationError = String(describing: error); self?.render() } }
        }
    }
    private func stopStream() {
        connect?.cancel(); connect = nil; stream?.stop(); stream = nil; streamKey = nil
        detailTask?.cancel(); detailTask = nil
        view.closeTools(); view.viewer.clear(); floatingViewer.clear()
    }
}
