import Foundation

/// SnapShotTransition.ts:6-40. Distance-dependent timing, with compositor-only transforms.
public enum SnapShotFlightAnimation {
    public static func duration(source: CGRect, destination: CGRect) -> TimeInterval {
        let distance = hypot(source.midX - destination.midX, source.midY - destination.midY)
        return (680 - 400 * exp(-distance / 2_000)) / 1_000
    }
}
