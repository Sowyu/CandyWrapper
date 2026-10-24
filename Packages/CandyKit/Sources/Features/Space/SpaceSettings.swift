import AppKit
import DesignSystem
import SpaceModel

/// Space's per-device settings in CandyWrapper's own defaults, never synced (docs/space.md "Experimental toggle"):
/// the switch, whether the sidebar shows Space, the expanded rows and the last page opened. Observers hear about the
/// switch and about theme changes, since Space exists only while Redesign is the theme.
@MainActor
public final class SpaceSettings {
    public static let shared = SpaceSettings()
    static let enabledKey = "space.enabled"
    static let modeKey = "space.sidebarMode"
    static let expandedKey = "space.expanded"
    static let lastPageKey = "space.lastPage"

    private let defaults: UserDefaults
    private var observers: [Int: @MainActor () -> Void] = [:]
    private var nextId = 0
    private var themeObserver: NSObjectProtocol?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        themeObserver = NotificationCenter.default.addObserver(forName: ThemeRuntime.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.notify() }
        }
    }

    public var enabled: Bool {
        get { defaults.bool(forKey: Self.enabledKey) }
        set {
            guard newValue != enabled else { return }
            defaults.set(newValue, forKey: Self.enabledKey)
            notify()
        }
    }

    /// The switch is on and Redesign is the theme: the only state in which any Space view exists.
    public var isActive: Bool { enabled && (ThemeRuntime.isDither(dark: true) || ThemeRuntime.isDither(dark: false)) }

    /// The sidebar shows Space instead of threads. Remembered across launches.
    public var sidebarMode: Bool {
        get { defaults.bool(forKey: Self.modeKey) }
        set { defaults.set(newValue, forKey: Self.modeKey) }
    }

    public var expanded: Set<PageID> {
        get { Set((defaults.stringArray(forKey: Self.expandedKey) ?? []).compactMap { try? PageID($0) }) }
        set { defaults.set(newValue.map(\.rawValue).sorted(), forKey: Self.expandedKey) }
    }

    public var lastPage: PageID? {
        get { defaults.string(forKey: Self.lastPageKey).flatMap { try? PageID($0) } }
        set { defaults.set(newValue?.rawValue, forKey: Self.lastPageKey) }
    }

    @discardableResult
    public func observe(_ block: @escaping @MainActor () -> Void) -> Int {
        nextId += 1
        observers[nextId] = block
        return nextId
    }

    public func removeObserver(_ id: Int) { observers[id] = nil }

    private func notify() { for f in observers.values { f() } }
}
