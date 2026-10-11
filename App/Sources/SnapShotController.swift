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
        // SnapShotCoordinator.tsx:282-292.
        if !test, destination == nil { composer.toastPublic(.error, "Snapshot taken, but no project is available", "Add a project, then capture the window again."); return }
        let app = NSWorkspace.shared.frontmostApplication
        let pid = app?.processIdentifier
        let capturedAt = ISO8601DateFormatter().string(from: Date())
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
                if !test, ClientSettingsStore.shared.current.bool("snapShotFlash") {
                    SnapShotCaptureFeedback.flash(frame: target.frame, animated: ClientSettingsStore.shared.current.bool("snapShotAnimations") && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
                }
                if test { setup?.tested = true; setup?.render(); return }
                guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]), let destination else {
                    throw SnapShotCaptureError.noWindow
                }
                var source: [String: JSONValue] = ["kind": .string("snap-shot"), "capturedAt": .string(capturedAt),
                    "appName": .string(String((app?.localizedName ?? "App").trimmingCharacters(in: .whitespacesAndNewlines).prefix(255))),
                    "windowTitle": .string(String((target.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(1_000)))]
                if let identifier = app?.bundleIdentifier { source["appIdentifier"] = .string(String(identifier.prefix(255))) }
                if let icon = app?.icon {
                    let resized = NSImage(size: NSSize(width: 32, height: 32))
                    resized.lockFocus(); icon.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32)); resized.unlockFocus()
                    if let tiff = resized.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                       let png = rep.representation(using: .png, properties: [:]), png.count < 70_000 {
                        source["appIconDataUrl"] = .string("data:image/png;base64," + png.base64EncodedString())
                    }
                }
                if ClientSettingsStore.shared.current.bool("snapShotIncludeAccessibility"), let pid {
                    let frame = target.frame, width = image.width, height = image.height
                    source["accessibility"] = await Task.detached(priority: .userInitiated) {
                        SnapShotAccessibilityCapture.read(pid: pid, frame: frame, width: width, height: height)
                    }.value
                }
                let attachmentId = try await composer.attachSnapShot(data, source: .object(source), destination: destination)
                window?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                composer.showSnapShotTarget(destination.key)
                if ClientSettingsStore.shared.current.bool("snapShotAnimations"), !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                   let end = composer.snapShotFrame(id: attachmentId, key: destination.key) {
                    await SnapShotCaptureFeedback.fly(image: image, frame: target.frame, destination: end)
                }
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

/// Bounded, one-shot AX read. chatAttachment.ts:43-147 specifies captured-image coordinates.
private enum SnapShotAccessibilityCapture {
    static func read(pid: pid_t, frame: CGRect, width: Int, height: Int) -> JSONValue? {
        // AX dispatches same-process queries directly into AppKit on the calling thread.
        // ponytail: omit self-capture AX data, replace with a main-thread native tree exporter if self-capture needs verified text.
        guard pid != getpid(), AXIsProcessTrusted(), frame.width > 0, frame.height > 0 else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
            return value
        }
        guard let raw = attribute(app, kAXFocusedWindowAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let root = unsafeBitCast(raw, to: AXUIElement.self)
        var rootPosition = CGPoint.zero, rootSize = CGSize.zero
        guard let p = attribute(root, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
              let s = attribute(root, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID(),
              AXValueGetValue(unsafeBitCast(p, to: AXValue.self), .cgPoint, &rootPosition),
              AXValueGetValue(unsafeBitCast(s, to: AXValue.self), .cgSize, &rootSize),
              abs(rootPosition.x - frame.minX) < 3, abs(rootPosition.y - frame.minY) < 3,
              abs(rootSize.width - frame.width) < 3, abs(rootSize.height - frame.height) < 3 else { return nil }
        var nodes = 0, bytes = 256, truncated = false
        let deadline = Date().addingTimeInterval(0.75)
        func visit(_ element: AXUIElement, depth: Int) -> JSONValue? {
            guard nodes < 10_000, depth < 40, Date() < deadline else { truncated = true; return nil }
            nodes += 1
            let role = attribute(element, kAXRoleAttribute) as? String ?? "AXUnknown"
            let secure = (attribute(element, kAXSubroleAttribute) as? String) == "AXSecureTextField"
            var node: [String: JSONValue] = ["role": .string(String(role.prefix(100))), "bounds": .null, "children": .array([])]
            if !secure {
                for (key, attr, limit) in [("name", kAXTitleAttribute, 1_000), ("value", kAXValueAttribute, 8_000), ("description", kAXDescriptionAttribute, 2_000)] {
                    if let text = attribute(element, attr) as? String {
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { node[key] = .string(String(trimmed.prefix(limit))) }
                    }
                }
            }
            var position = CGPoint.zero, size = CGSize.zero
            if let p = attribute(element, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
               let s = attribute(element, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID(),
               AXValueGetValue(unsafeBitCast(p, to: AXValue.self), .cgPoint, &position),
               AXValueGetValue(unsafeBitCast(s, to: AXValue.self), .cgSize, &size) {
                let clipped = CGRect(origin: position, size: size).intersection(frame)
                if !clipped.isNull && clipped.width > 0 && clipped.height > 0 {
                    let x = max(0, Int(((clipped.minX - frame.minX) / frame.width * Double(width)).rounded()))
                    let y = max(0, Int(((clipped.minY - frame.minY) / frame.height * Double(height)).rounded()))
                    let right = min(width, Int(((clipped.maxX - frame.minX) / frame.width * Double(width)).rounded()))
                    let bottom = min(height, Int(((clipped.maxY - frame.minY) / frame.height * Double(height)).rounded()))
                    if right > x && bottom > y {
                        node["bounds"] = .object(["x": .number(Double(x)), "y": .number(Double(y)), "width": .number(Double(right - x)), "height": .number(Double(bottom - y))])
                    }
                }
            }
            let count = (try? JSONEncoder().encode(JSONValue.object(node)).count) ?? 0
            guard bytes + count < 31_000 else { truncated = true; return nil }
            bytes += count
            if !secure, let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
                var result: [JSONValue] = []
                for child in children {
                    guard let value = visit(child, depth: depth + 1) else { break }
                    result.append(value)
                }
                node["children"] = .array(result)
            }
            return .object(node)
        }
        guard let tree = visit(root, depth: 0) else { return nil }
        return .object(["format": .string("element-tree"), "coordinateSpace": .string("captured-image"),
                        "imageSize": .object(["width": .number(Double(width)), "height": .number(Double(height))]),
                        "truncated": .bool(truncated), "root": tree])
    }
}

@MainActor
private enum SnapShotCaptureFeedback {
    static func cocoaFrame(_ frame: CGRect) -> CGRect {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(x: frame.minX, y: top - frame.maxY, width: frame.width, height: frame.height)
    }
    static func overlay(_ frame: CGRect) -> NSPanel {
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.ignoresMouseEvents = true; panel.level = .floating; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true; panel.contentView = view
        return panel
    }
    static func flash(frame: CGRect, animated: Bool) {
        let panel = overlay(cocoaFrame(frame))
        panel.contentView?.layer?.backgroundColor = NSColor.white.cgColor
        panel.alphaValue = 0.08
        panel.orderFrontRegardless()
        let duration = animated ? 0.18 : 0.06
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .linear)
                panel.animator().alphaValue = 0
            }
        }
        Task { try? await Task.sleep(for: .seconds(duration)); panel.close() }
    }
    static func fly(image: CGImage, frame: CGRect, destination: CGRect) async {
        let source = cocoaFrame(frame)
        let union = source.union(destination)
        let panel = overlay(union)
        guard let root = panel.contentView?.layer else { return }
        let layer = CALayer()
        layer.contents = image; layer.contentsGravity = .resizeAspectFill
        layer.masksToBounds = true; layer.cornerRadius = 10
        layer.bounds = CGRect(origin: .zero, size: destination.size)
        let end = CGPoint(x: destination.midX - union.minX, y: destination.midY - union.minY)
        layer.position = end; root.addSublayer(layer)
        let duration = SnapShotFlightAnimation.duration(source: source, destination: destination)
        let position = CABasicAnimation(keyPath: "position")
        position.fromValue = CGPoint(x: source.midX - union.minX, y: source.midY - union.minY); position.toValue = end
        let transform = CABasicAnimation(keyPath: "transform")
        transform.fromValue = CATransform3DMakeScale(source.width / destination.width, source.height / destination.height, 1)
        transform.toValue = CATransform3DIdentity
        let group = CAAnimationGroup(); group.animations = [position, transform]; group.duration = duration
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
        layer.add(group, forKey: "snapShotFlight")
        panel.orderFrontRegardless()
        try? await Task.sleep(for: .seconds(duration))
        panel.close(); layer.removeFromSuperlayer()
    }
}
