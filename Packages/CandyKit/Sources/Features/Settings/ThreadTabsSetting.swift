import Foundation

/// The Experimental Tabs switch: Redesign's tab strip of open routes, Cmd-click and "Open in new tab". Off by default
/// (the user, 2026-10-29: they don't use tabs). Turning it off only hides the tabs; the open ones come back with it.
@MainActor
public enum ThreadTabsSetting {
    static let key = "experimental.threadTabs"
    public static let didChange = Notification.Name("ThreadTabsSetting.didChange")
    public static var defaults = UserDefaults.standard

    public static var isOn: Bool { defaults.bool(forKey: key) }

    public static func set(_ on: Bool) {
        guard on != isOn else { return }
        defaults.set(on, forKey: key)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// Calls `f` after every change. Returns the unsubscribe.
    public static func observe(_ f: @escaping @MainActor () -> Void) -> () -> Void {
        let token = NotificationCenter.default.addObserver(forName: didChange, object: nil, queue: .main) { _ in MainActor.assumeIsolated { f() } }
        return { NotificationCenter.default.removeObserver(token) }
    }
}
