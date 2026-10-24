import AppKit
import DesignSystem
import T3Store

/// The Orchestrator's settings and state on this Mac (docs/orchestrator.md), kept as one JSON document in CandyWrapper's
/// own defaults. T3's `settings.json` never sees any of it. The shared settings also carry a stamp each, so the app can
/// sync them with the other devices (`OrchestratorSettingsSync`). Observers hear about every change and about theme
/// changes, since the Orchestrator exists only while Redesign is the theme.
@MainActor
public final class OrchestratorStore {
    public static let shared = OrchestratorStore()
    static let defaultsKey = "orchestrator.v1"
    static let syncKey = "orchestrator.sync.v1"

    private let defaults: UserDefaults
    public private(set) var config: OrchestratorConfig
    /// When each shared setting was last set and by which device.
    public private(set) var stamps: [String: OrchestratorSettingsSync.Stamp]
    /// This device's id in the stamps.
    public let device: String
    /// For tests.
    var now: () -> Date = Date.init
    private var observers: [(id: Int, block: @MainActor () -> Void)] = []
    private var nextId = 0
    private var themeObserver: NSObjectProtocol?
    private var wasActive = false

    /// What the app does for the Orchestrator's controls; set once by the app.
    public struct Actions {
        /// Starts the Orchestrator on its machine, or opens it when it runs.
        public var start: (() -> Void)?
        public var open: (() -> Void)?
        /// Shown in the settings tab: the thread's state, like "Running on mac-mini" or "Not started".
        public var status: (() -> String)?
        public init() {}
    }
    public var actions = Actions()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        config = defaults.data(forKey: Self.defaultsKey).flatMap { try? JSONDecoder().decode(OrchestratorConfig.self, from: $0) } ?? OrchestratorConfig()
        if let saved = defaults.data(forKey: Self.syncKey).flatMap({ try? JSONDecoder().decode(SyncState.self, from: $0) }) {
            device = saved.device
            stamps = saved.stamps
        } else {
            // First launch with sync: what you set before goes up as set now.
            device = UUID().uuidString.lowercased()
            stamps = OrchestratorSettingsSync.migrationStamps(config, now: Self.ms(Date()), device: device)
            saveSync()
        }
        // `CANDY_ORCHESTRATOR=1` turns the toggle on for this launch without saving it, for perf runs whose defaults
        // start empty (scripts/perf-review), as `CANDY_THEME` pins the theme.
        if defaults === UserDefaults.standard, ProcessInfo.processInfo.environment["CANDY_ORCHESTRATOR"] == "1" { config.enabled = true }
        wasActive = isActive
        themeObserver = NotificationCenter.default.addObserver(forName: ThemeRuntime.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.themeChanged() }
        }
    }

    /// Redesign is the theme in either appearance.
    public var isRedesign: Bool { ThemeRuntime.isDither(dark: true) || ThemeRuntime.isDither(dark: false) }
    /// The toggle is on and Redesign is the theme: the only state in which any Orchestrator view or work exists.
    public var isActive: Bool { config.enabled && isRedesign }
    /// The same for a view, by its own appearance.
    public func isActive(in view: NSView) -> Bool { config.enabled && ThemeRuntime.isDither(dark: view.effectiveAppearance.isDark) }

    public func update(_ change: (inout OrchestratorConfig) -> Void) {
        var next = config
        change(&next)
        guard next != config else { return }
        let before = stamps
        stamps = OrchestratorSettingsSync.stamps(old: config, new: next, into: stamps, now: Self.ms(now()), device: device)
        config = next
        save()
        if stamps != before { saveSync() }
        notify()
    }

    /// Settings merged from the other devices: they keep the stamps they came with.
    public func applyMerged(_ merge: OrchestratorSettingsSync.Merge) {
        guard merge.config != config || merge.stamps != stamps else { return }
        stamps = merge.stamps
        saveSync()
        guard merge.config != config else { return }
        config = merge.config
        save()
        notify()
    }

    private struct SyncState: Codable {
        var device: String
        var stamps: [String: OrchestratorSettingsSync.Stamp]
    }

    private func save() {
        if let data = try? JSONEncoder().encode(config) { defaults.set(data, forKey: Self.defaultsKey) }
    }

    private func saveSync() {
        if let data = try? JSONEncoder().encode(SyncState(device: device, stamps: stamps)) { defaults.set(data, forKey: Self.syncKey) }
    }

    static func ms(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

    @discardableResult
    public func observe(_ block: @escaping @MainActor () -> Void) -> Int {
        nextId += 1
        observers.append((nextId, block))
        return nextId
    }

    public func removeObserver(_ id: Int) { observers.removeAll { $0.id == id } }

    private func themeChanged() {
        guard isActive != wasActive else { return }
        notify()
    }

    private func notify() {
        wasActive = isActive
        for o in observers { o.block() }
    }
}
