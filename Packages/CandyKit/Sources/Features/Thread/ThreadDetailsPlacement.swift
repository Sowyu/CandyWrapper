import Foundation

/// threadDetailsCardLayout.ts:20-66 and chatCanvasLayout.ts:38-60.
public enum ThreadDetailsPlacement {
    public static func inlineCard(width: CGFloat, height: CGFloat, topInset: CGFloat = 0, padding: CGFloat = 48) -> CGRect? {
        let x = width - 280 - 12, y = 12 + topInset
        guard x - 32 - padding >= 640, height - y - 12 >= 160 else { return nil }
        return CGRect(x: x, y: y, width: 280, height: height - y - 12)
    }
    public static func lane(width: CGFloat, maximum: CGFloat, padding: CGFloat, cardLeft: CGFloat?) -> (x: CGFloat, width: CGFloat) {
        let right = cardLeft.map { $0 - 32 } ?? width - padding
        let w = max(0, min(maximum, width - padding * 2, right - padding))
        return (max(padding, min((width - w) / 2, right - w)), w)
    }
}
