import AppKit
import DesignSystem
import Features
import T3Protocol
import T3Store
import UserNotifications

/// T3's `ThreadNotificationCoordinator` (apps/web/src/components/ThreadNotificationCoordinator.tsx) with the
/// desktop badge (apps/desktop/src/ipc/methods/notificationBadge.ts). Every environment's live shell runs
/// through `ThreadNotificationTracker`; each event plays the sound, shows a toast while the window has
/// focus, or posts a system notification while it doesn't. Nothing runs between shell updates.
@MainActor
final class ThreadNotificationCoordinator: NSObject {
    private var tracker = ThreadNotificationTracker()
    private var badgeCount = NotificationBadgeCount()
    private let sound = NotificationSoundPlayer()
    private let environments: Environments
    private weak var window: NSWindow?
    private var permissionGranted = false
    private var observers: [NSObjectProtocol] = []

    /// The thread the window shows (T3's route params); nil on Settings, a utility page or a draft.
    var openThread: () -> (environmentId: String, threadId: ThreadId)? = { nil }
    /// The toast stack in view.
    var toasts: () -> ToastViewport? = { nil }
    /// Leaves Settings or a utility page and opens the thread (environment, local thread id).
    var navigate: (String, ThreadId) -> Void = { _, _ in }

    private var settings: ClientSettings { ClientSettingsStore.shared.current }
    private var mode: ThreadNotificationMode { ThreadNotificationMode(rawValue: settings.string("notificationMode")) ?? .off }
    private var inAppEnabled: Bool { settings.bool("inAppNotificationsEnabled") }
    /// `if (mode === "off" && !inAppNotificationsEnabled) return null`: nothing is tracked.
    private var isMounted: Bool { mode != .off || inAppEnabled }

    init(environments: Environments, window: NSWindow) {
        self.environments = environments
        self.window = window
        super.init()
        environments.onLiveShell = { [weak self] id, snapshot in self?.liveShell(id, snapshot) }
        var lastMode = mode
        ClientSettingsStore.shared.observe { [weak self] keys in
            guard let self, keys.contains("notificationMode") || keys.contains("inAppNotificationsEnabled") else { return }
            if !self.isMounted { self.tracker.resetAll() }
            if self.mode != lastMode {
                lastMode = self.mode
                // The [mode] effect clears on every change.
                self.clearBadge()
                self.refreshPermission()
                self.armGestureMonitor()
            }
        }
        // `browser-window-focus` and the renderer's `focus` listener clear the badge and close the notifications.
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.clearBadge() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.window?.isKeyWindow == true { self.clearBadge() }
                self.refreshPermission()
            }
        })
        if mode.hasDesktopNotifications { UNUserNotificationCenter.current().delegate = self }
        refreshPermission()
        armGestureMonitor()
    }

    private var gestureMonitor: Any?

    /// T3 listens for `pointerdown` while a sound mode is on; keys come through `noteUserGesture` from the
    /// shortcut monitor. The mouse monitor removes itself after the first click.
    private func armGestureMonitor() {
        guard mode.hasSound, !sound.unlocked, gestureMonitor == nil else { return }
        gestureMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.noteUserGesture() }
            return event
        }
    }

    /// `before-quit` clears the badge too.
    func willTerminate() { clearBadge() }

    /// A key or mouse press in the window: the gesture that lets the sound play (`unlockNotificationAudio`).
    func noteUserGesture() {
        guard mode.hasSound else { return }
        sound.unlocked = true
        if let monitor = gestureMonitor {
            NSEvent.removeMonitor(monitor)
            gestureMonitor = nil
        }
    }

    /// Settings: choosing a mode that alerts asks for permission first (NotificationSettings.tsx:31-66).
    /// Returns the row's message when the mode can't be used, nil when it was saved.
    func choose(_ mode: ThreadNotificationMode) async -> String? {
        if mode.hasSound { sound.unlocked = true }
        if let monitor = gestureMonitor, sound.unlocked {
            NSEvent.removeMonitor(monitor)
            gestureMonitor = nil
        }
        if mode.hasDesktopNotifications {
            let center = UNUserNotificationCenter.current()
            center.delegate = self
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            permissionGranted = granted
            if !granted {
                return "Allow notifications in your browser or system settings, then choose this option again. Sound only is still available."
            }
        }
        ClientSettingsStore.shared.update(["notificationMode": .string(mode.rawValue)])
        return nil
    }

    private func refreshPermission() {
        guard mode.hasDesktopNotifications else { return }
        Task {
            let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            self.permissionGranted = status == .authorized || status == .provisional
        }
    }

    // MARK: Shell updates

    private func liveShell(_ environmentId: String, _ snapshot: ShellSnapshot?) {
        guard let snapshot else {
            tracker.reset(environmentId: environmentId)
            // Notifications from environments that left the client close (ThreadNotificationCoordinator.tsx:42-51).
            if !environments.isRegistered(environmentId) {
                let gone = badgeCount.keep(environments: Set(environments.environmentIds).subtracting([environmentId]))
                if !gone.isEmpty { withdraw(gone) }
            }
            return
        }
        guard isMounted else { return }
        for event in tracker.scan(environmentId: environmentId, threads: snapshot.threads) { deliver(event) }
    }

    private var windowFocused: Bool {
        guard let window else { return false }
        return NSApp.isActive && window.isKeyWindow && window.isVisible && !window.isMiniaturized
    }

    private func deliver(_ event: ThreadNotificationEvent) {
        let route = ThreadNotificationRoute.route(event, mode: mode, inAppEnabled: inAppEnabled, focused: windowFocused,
                                                  openThread: openThread(), permissionGranted: permissionGranted)
        if route.sound { sound.play(event.kind) }
        if route.toast { showToast(event) }
        if route.system { post(event) }
    }

    private func showToast(_ event: ThreadNotificationEvent) {
        guard let viewport = toasts() else { return }
        let kind: ToastQueue.Kind = switch event.tone {
        case .success: .success
        case .error: .error
        case .warning: .warning
        }
        let icon: (IconName, NSColor) = switch event.icon {
        case .circleCheck: (.circleCheck, Themed.color(\.successForeground))
        case .shieldQuestion: (.shieldQuestion, Themed.color(\.warningForeground))
        case .circleAlert: (.circleAlert, Themed.color(\.destructiveForeground))
        case .messageCircleQuestion: (.messageCircleQuestion, Themed.color(\.infoForeground))
        }
        var toastId = 0
        let toast = ToastView(title: event.title, message: event.threadTitle, kind: kind, actionTitle: "Open thread", action: { [weak self, weak viewport] in
            viewport?.dismiss(toastId)
            self?.navigate(event.environmentId, event.threadId)
        }, leadingIcon: icon)
        toastId = viewport.show(toast)
    }

    private func post(_ event: ThreadNotificationEvent) {
        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body = event.threadTitle
        // `silent: true`: the app plays its own sound when the mode asks for one.
        content.sound = nil
        content.userInfo = ["environmentId": event.environmentId, "threadId": event.threadId.rawValue]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: event.tag, content: content, trigger: nil))
        setBadge(badgeCount.add(tag: event.tag, environmentId: event.environmentId, windowFocused: windowFocused))
    }

    private func clearBadge() {
        let tags = badgeCount.clear()
        if !tags.isEmpty { withdraw(tags) }
        setBadge(0)
    }

    private func withdraw(_ tags: [String]) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: tags)
        setBadge(badgeCount.count)
    }

    /// `app.setBadgeCount` on macOS is the dock tile's badge label.
    private func setBadge(_ count: Int) {
        let label = count > 0 ? String(count) : nil
        if NSApp.dockTile.badgeLabel != label { NSApp.dockTile.badgeLabel = label }
    }

    /// A notification click: focus the window and open the thread (ThreadNotificationCoordinator.tsx:222-229).
    private func open(environmentId: String, threadId: String) {
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        navigate(environmentId, ThreadId(threadId))
    }
}

extension ThreadNotificationCoordinator: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let env = info["environmentId"] as? String, let thread = info["threadId"] as? String else { return }
        await MainActor.run { self.open(environmentId: env, threadId: thread) }
    }

    /// The window lost focus to another of the app's windows: still show the banner.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}

/// `playNotificationSound` with T3's two clips (apps/web/src/assets/notification-*.mp3). The web needs a
/// gesture before audio can start; T3 keeps that rule, so nothing plays until the user pressed a key or
/// clicked since the sound mode was chosen or the app started.
@MainActor
final class NotificationSoundPlayer {
    var unlocked = false
    private var clips: [ThreadNotificationEvent.Kind: NSSound] = [:]

    func play(_ kind: ThreadNotificationEvent.Kind) {
        guard unlocked else { return }
        if clips[kind] == nil {
            let name = kind == .completion ? "notification-completion" : "notification-input"
            clips[kind] = Bundle.main.url(forResource: name, withExtension: "mp3").flatMap { NSSound(contentsOf: $0, byReference: true) }
        }
        guard let clip = clips[kind] else { return }
        clip.stop()
        clip.play()
    }
}
