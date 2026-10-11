import AppKit
import DesignSystem
import Features
import T3Client
import T3Protocol

/// The desktop app's own dialogs for environments it manages: the SSH password queue
/// (DesktopSshPasswordPrompts.ts, SshPasswordPromptDialog.tsx) and the relay client install
/// (linkEnvironment.ts:51-104, relayClientInstallDialog.ts, RelayClientInstallDialog.tsx).
@MainActor
final class DesktopManagedController {
    weak var window: NSWindow?
    let environments: Environments
    private var passwords: [(SshPasswordPromptState, CheckedContinuation<String, Error>?)] = []
    private var passwordModal: ModalHost?
    private var passwordClock: Task<Void, Never>?
    private var passwordExpiry: [UUID: Task<Void, Never>] = [:]
    private var occlusionObserver: NSObjectProtocol?
    private var previewModal: ModalHost?
    private var relayModal: ModalHost?
    private var relayState = RelayClientInstallState.idle
    init(window: NSWindow, environments: Environments) {
        self.window = window; self.environments = environments
        environments.ssh.passwordPrompt = { [weak self] target, _ in
            guard let self else { throw CancellationError() }
            return try await self.password(target: target.destination)
        }
    }
    func shutdown() {
        passwordClock?.cancel()
        passwordExpiry.values.forEach { $0.cancel() }; passwordExpiry.removeAll()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }; occlusionObserver = nil
        let pending = passwords; passwords.removeAll()
        pending.forEach { $0.1?.resume(throwing: CancellationError()) }
        passwordModal?.close(); previewModal?.close(); relayModal?.close(); environments.ssh.shutdown()
    }
    private func password(target: String) async throws -> String {
        let request = SshPasswordPromptState(target: target)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                passwords.append((request, continuation))
                passwordExpiry[request.id] = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(180)) } catch { return }
                    self?.expirePassword(request.id)
                }
                showPassword()
            }
        } onCancel: { Task { @MainActor [weak self] in self?.resolvePassword(request.id, value: nil) } }
    }
    private func showPassword() {
        guard passwordModal == nil, let (request, _) = passwords.first else { return }
        guard let window else { resolvePassword(request.id, value: nil); return }
        let dialog = SshPasswordPromptDialog(state: request)
        let host = ModalHost.present(dialog, in: window); passwordModal = host
        dialog.onResponse = { [weak self] value in self?.resolvePassword(request.id, value: value) }
        host.onDismiss = { [weak self] in
            guard let self else { return }
            self.passwordModal = nil; self.passwordClock?.cancel(); self.passwordClock = nil
            self.resolvePassword(request.id, value: nil); self.showPassword()
        }
        window.makeKeyAndOrderFront(nil); NSApp.activate(); window.makeFirstResponder(dialog.password)
        // T3 focuses the field on the next frame (SshPasswordPromptDialog.tsx:78-85), after other views settle.
        DispatchQueue.main.async { [weak window, weak dialog] in if let dialog { window?.makeFirstResponder(dialog.password) } }
        if occlusionObserver == nil {
            occlusionObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.startPasswordClock() }
            }
        }
        startPasswordClock()
    }
    private func startPasswordClock() {
        passwordClock?.cancel(); passwordClock = nil
        guard let (request, _) = passwords.first, let dialog = passwordModal?.panel as? SshPasswordPromptDialog else { return }
        dialog.update(state: request, now: Date())
        guard window?.occlusionState.contains(.visible) == true, request.remaining(at: Date()) > 0 else { return }
        passwordClock = Task { [weak dialog] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let dialog else { return }
                dialog.update(state: request, now: Date())
                if request.remaining(at: Date()) == 0 { return }
            }
        }
    }
    private func expirePassword(_ id: UUID) {
        passwordExpiry[id] = nil
        guard let index = passwords.firstIndex(where: { $0.0.id == id }) else { return }
        let (request, continuation) = passwords[index]; passwords[index].1 = nil
        continuation?.resume(throwing: SshEnvironmentError("SSH authentication timed out for \(request.target)."))
        if index == 0 { startPasswordClock() }
    }
    private func resolvePassword(_ id: UUID, value: String?) {
        guard let index = passwords.firstIndex(where: { $0.0.id == id }) else { return }
        let (request, continuation) = passwords.remove(at: index)
        passwordExpiry.removeValue(forKey: id)?.cancel()
        if passwords.isEmpty, let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver); self.occlusionObserver = nil }
        if let value, request.remaining(at: Date()) > 0 { continuation?.resume(returning: value) }
        else { continuation?.resume(throwing: SshEnvironmentError(request.remaining(at: Date()) == 0 ? "SSH authentication timed out for \(request.target)." : "SSH authentication cancelled for \(request.target).")) }
        if index == 0 { passwordClock?.cancel(); passwordModal?.close() }
    }

    /// Called before linking a host. RPC owns checksum validation, locking and atomic activation.
    func ensureRelayClient(environmentId: String) async throws {
        guard let shell = environments.session(environmentId), let rpc = await shell.supervisor.currentConnection else { throw SshEnvironmentError("Environment is not connected.") }
        let status = try await rpc.request("cloud.getRelayClientStatus").decode(as: RelayClientInstallStatus.self)
        if status.status == "available" { return }
        guard status.status == "missing" else { throw SshEnvironmentError(status.unsupportedMessage) }
        guard relayState.request(version: status.version), let window else { throw SshEnvironmentError("Another relay client installation is already open.") }
        let confirmed = await withCheckedContinuation { continuation in
            let dialog = RelayClientInstallDialog.make(version: status.version)
            let cancel = ButtonView("Cancel", variant: .outline), install = ButtonView("Download and install")
            dialog.footerButtons = [cancel, install]
            let host = ModalHost.present(dialog, in: window); relayModal = host
            var answered = false
            let answer: (Bool) -> Void = { [weak self] value in
                guard !answered else { return }; answered = true
                self?.relayState.respond(value); continuation.resume(returning: value)
            }
            host.onDismiss = { answer(false) }
            cancel.action = { [weak host] in answer(false); host?.close() }
            install.action = { answer(true) }
        }
        defer { relayModal?.close(); relayModal = nil; relayState = .idle }
        guard confirmed else { throw SshEnvironmentError("Relay client installation was cancelled.") }
        relayModal?.allowsUserDismissal = false
        showRelayProgress(version: status.version, stage: .checking)
        var completed: RelayClientInstallStatus?
        let stream = await rpc.stream("cloud.installRelayClient")
        for try await json in stream {
            let event = try json.decode(as: RelayClientInstallEvent.self)
            if event.type == "progress", let stage = event.stage { relayState.progress(stage); showRelayProgress(version: status.version, stage: stage) }
            completed = event.type == "complete" ? event.status : nil
        }
        guard let completed else { throw SshEnvironmentError("The relay client install completed without a final status.") }
        guard completed.status == "available" else {
            throw SshEnvironmentError(completed.status == "unsupported" ? completed.unsupportedMessage : "The relay client is still unavailable after installation.")
        }
    }
    private func showRelayProgress(version: String, stage: RelayClientInstallStage) {
        guard let dialog = relayModal?.panel else { return }
        dialog.title = "Installing relay client"; dialog.message = "T3 Code is preparing this environment for secure access through T3 Connect."
        dialog.showsCloseButton = false; dialog.footerButtons = []
        dialog.panelContent = [RelayClientInstallBody(version: version, stage: stage)]
    }

    /// `--desktop-managed-preview ssh|ssh-expired|relay|relay-progress`: the dialogs with fake values, for
    /// checking them on screen. Never runs SSH, the installer RPCs or account calls.
    func preview(_ kind: String) {
        guard let window else { return }
        let dialog: DialogView
        switch kind {
        case "ssh":
            // The real queue (focus, countdown, expiry); the answer is dropped.
            Task { _ = try? await password(target: "fixture@fixture.invalid") }
            return
        case "ssh-expired":
            let prompt = SshPasswordPromptDialog(state: SshPasswordPromptState(target: "fixture@fixture.invalid", now: Date().addingTimeInterval(-181)))
            prompt.onResponse = { [weak self] _ in self?.previewModal?.close() }
            dialog = prompt
        case "relay":
            dialog = RelayClientInstallDialog.make(version: "2026.10.9")
            let cancel = ButtonView("Cancel", variant: .outline), install = ButtonView("Download and install")
            dialog.footerButtons = [cancel, install]
            cancel.action = { [weak self] in self?.previewModal?.close() }
            install.action = { [weak self] in self?.previewModal?.close(); self?.preview("relay-progress") }
        case "relay-progress": dialog = RelayClientInstallDialog.make(version: "2026.10.9", stage: .verifying)
        default: return
        }
        let host = ModalHost.present(dialog, in: window)
        previewModal = host
        host.onDismiss = { [weak self, weak host] in if self?.previewModal === host { self?.previewModal = nil } }
    }
}
