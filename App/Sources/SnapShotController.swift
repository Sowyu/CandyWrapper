import AppKit
import ScreenCaptureKit
import DesignSystem
import Features
import T3Protocol

/// One-shot capture. Permissions are requested only by the setup buttons.
/// SnapShotCoordinator.tsx:145-196 pins the draft before capture and focuses it after delivery.
@MainActor
final class SnapShotController {
    private weak var window: NSWindow?
    private let composer: ComposerController
    private let shortcuts: Shortcuts
    private var setup: SnapShotSetupView?
    private var modal: ModalHost?
    private var capturing = false
    private var sound: NSSound?
    private var observer: Int?
    private var activationObserver: NSObjectProtocol?

    init(window: NSWindow, composer: ComposerController, shortcuts: Shortcuts) {
        self.window = window
        self.composer = composer
        self.shortcuts = shortcuts
        observer = ClientSettingsStore.shared.observe { [weak self] keys in
            if keys.contains(where: { $0.hasPrefix("snapShot") }) { self?.configure() }
        }
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermissions(); self?.configure() }
        }
        shortcuts.on("snapShot.capture") { [weak self] _ in self?.capture(); return true }
        configure()
    }

    var ready: Bool { CGPreflightScreenCaptureAccess() }

    private func configure() {
        let settings = ClientSettingsStore.shared.current
        shortcuts.configureSnapShot(enabled: settings.bool("snapShotEnabled") && ready,
                                    shortcut: settings["snapShotShortcut"]) { [weak self] in self?.capture() }
    }

    func showSetup() {
        guard modal == nil, let window else { return }
        let setup = SnapShotSetupView()
        self.setup = setup
        setup.includesText = ClientSettingsStore.shared.current.bool("snapShotIncludeAccessibility")
        setup.onScreenPermission = { [weak self] in
            CGRequestScreenCaptureAccess()
            self?.refreshPermissions()
        }
        setup.onAccessibilityPermission = { [weak self] in
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            self?.refreshPermissions()
        }
        setup.onRefresh = { [weak self] in self?.refreshPermissions() }
        setup.onTest = { [weak self] in self?.capture(test: true) }
        setup.onEnable = { [weak self] in
            ClientSettingsStore.shared.update(["snapShotEnabled": .bool(true)])
            self?.modal?.close()
        }
        refreshPermissions()
        let host = ModalHost.present(setup.dialog, in: window)
        modal = host
        host.onDismiss = { [weak self] in self?.modal = nil; self?.setup = nil }
        setup.dialog.onClose = { [weak host] in host?.close() }
    }

    private func refreshPermissions() {
        setup?.screenAllowed = ready
        setup?.accessibilityAllowed = AXIsProcessTrusted()
        setup?.render()
    }

    func capture(test: Bool = false) {
        guard !capturing else { return }
        guard ready else { showSetup(); return }
        if !test, !ClientSettingsStore.shared.current.bool("snapShotEnabled") { showSetup(); return }
        let destination = composer.snapShotDestination
        if !test, destination == nil { composer.toastPublic(.error, "Could not attach snapshot", "Open a draft, then try again."); return }
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if !test, ClientSettingsStore.shared.current.bool("snapShotPlaySound") {
            let name = ClientSettingsStore.shared.current.string("snapShotSound") == "soft-pop" ? "snap-shot-whoosh" : "snap-shot-click"
            if let url = Bundle.main.url(forResource: name, withExtension: "mp3") {
                sound = NSSound(contentsOf: url, byReference: true)
                sound?.play()
            }
        }
        capturing = true
        Task { [weak self] in
            guard let self else { return }
            defer { capturing = false }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                let order = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
                let ids = order.compactMap { entry -> CGWindowID? in
                    guard entry[kCGWindowOwnerPID as String] as? pid_t == pid,
                          entry[kCGWindowLayer as String] as? Int == 0 else { return nil }
                    return (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value
                }
                guard let target = ids.compactMap({ id in content.windows.first { $0.windowID == id } }).first else {
                    throw SnapShotCaptureError.noWindow
                }
                let filter = SCContentFilter(desktopIndependentWindow: target)
                let config = SCStreamConfiguration()
                config.width = Int(target.frame.width * CGFloat(filter.pointPixelScale))
                config.height = Int(target.frame.height * CGFloat(filter.pointPixelScale))
                config.showsCursor = false
                config.ignoreShadowsSingleWindow = true
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                if test { setup?.tested = true; setup?.render(); return }
                guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]), let destination else {
                    throw SnapShotCaptureError.noWindow
                }
                try await composer.attachSnapShot(data, destination: destination)
                window?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            } catch {
                composer.toastPublic(.error, "Could not capture window", error.localizedDescription)
            }
        }
    }
}

private enum SnapShotCaptureError: LocalizedError {
    case noWindow
    var errorDescription: String? { "No capturable window is available." }
}
