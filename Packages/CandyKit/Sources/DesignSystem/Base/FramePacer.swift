import AppKit
import IOKit.ps

/// The power signal the app paces its work by (spec, "Batch streaming updates" and "OS
/// cooperation"): Low Power Mode, running on battery, or serious thermal pressure. Every source
/// pushes a notification, so watching costs nothing while idle.
@MainActor
public final class PowerState {
    public static let shared = PowerState()

    /// Posted on the main thread when `constrained` flips.
    public static let didChange = Notification.Name("PowerState.didChange")

    public private(set) var lowPowerMode: Bool
    public private(set) var onBattery: Bool
    public private(set) var thermalState: ProcessInfo.ThermalState

    /// True in Low Power Mode, on battery, or at `.serious` thermal state and above.
    public var constrained: Bool { Self.constrained(lowPower: lowPowerMode, battery: onBattery, thermal: thermalState) }

    nonisolated static func constrained(lowPower: Bool, battery: Bool, thermal: ProcessInfo.ThermalState) -> Bool {
        lowPower || battery || thermal.rawValue >= ProcessInfo.ThermalState.serious.rawValue
    }

    private var observers: [NSObjectProtocol] = []

    private init() {
        let info = ProcessInfo.processInfo
        lowPowerMode = info.isLowPowerModeEnabled
        thermalState = info.thermalState
        onBattery = Self.readOnBattery()
        let center = NotificationCenter.default
        // Both may post on any thread; the main queue delivers them here.
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { PowerState.shared.refresh() }
            })
        }
        // Power source changes (plugging in or out). Never fires on a Mac without a battery.
        if let source = IOPSNotificationCreateRunLoopSource({ _ in
            MainActor.assumeIsolated { PowerState.shared.refresh() }
        }, nil)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }

    private func refresh() {
        let before = constrained
        let info = ProcessInfo.processInfo
        lowPowerMode = info.isLowPowerModeEnabled
        thermalState = info.thermalState
        onBattery = Self.readOnBattery()
        if constrained != before { NotificationCenter.default.post(name: Self.didChange, object: self) }
    }

    private static func readOnBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        else { return false }
        return type == kIOPMBatteryPowerKey
    }
}

/// Runs `apply` at most once per display frame, or about 30 times a second while `PowerState`
/// is constrained. A request that comes after a quiet spell runs at once, so a lone update (a
/// thread open, a click) pays no extra latency; requests during a burst (a streaming answer)
/// fold into one run at the end of the interval. Nothing repeats: an idle pacer schedules nothing.
@MainActor
public final class FramePacer {
    private let apply: () -> Void
    private var last: CFTimeInterval = -.infinity
    private var scheduled = false

    public init(_ apply: @escaping () -> Void) { self.apply = apply }

    /// The shortest gap between runs: one frame of the fastest screen, or 1/30 s when constrained.
    public static var interval: CFTimeInterval {
        if PowerState.shared.constrained { return 1.0 / 30 }
        let fps = NSScreen.screens.map(\.maximumFramesPerSecond).max() ?? 60
        return 1.0 / Double(max(fps, 1))
    }

    public func request() {
        guard !scheduled else { return }
        let wait = Self.delay(now: CACurrentMediaTime(), last: last, interval: Self.interval)
        if wait <= 0 { run(); return }
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            MainActor.assumeIsolated {
                self?.scheduled = false
                self?.run()
            }
        }
    }

    private func run() {
        last = CACurrentMediaTime()
        apply()
    }

    nonisolated static func delay(now: CFTimeInterval, last: CFTimeInterval, interval: CFTimeInterval) -> CFTimeInterval {
        max(0, last + interval - now)
    }
}
