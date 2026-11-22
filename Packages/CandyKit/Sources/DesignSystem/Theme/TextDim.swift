import Foundation

/// Redesign's "Dim behind text" (the user, 2026-11-21: "allow me to change the dimness of the opacity of the line down
/// the middle"): how much the background is held back behind a thread's text, one position from 0 to 100 for every
/// background. 0 holds nothing back, `standard` is the look each background had before the setting, and 100 leaves the
/// ground close to plain behind the column. Each half of the track interpolates linearly, so the result only ever
/// grows with the position, and only the depth changes: every background keeps its falloff into the margins.
public enum TextDim {
    /// The position each background's earlier, fixed look sits at.
    public static let standard = 70
    /// What the strongest position keeps of the standard look's remaining share: the ink and dots left over the column.
    static let strongest = 0.12

    /// The share (1 is the art at full strength) at `position`, given the standard look's share `standard`.
    public static func share(_ standard: Double, at position: Int) -> Double {
        if position == Self.standard { return standard }
        let p = Double(min(max(position, 0), 100))
        if p <= Double(Self.standard) { return 1 + (standard - 1) * p / Double(Self.standard) }
        return standard + (standard * strongest - standard) * (p - Double(Self.standard)) / Double(100 - Self.standard)
    }

    /// Picture's luminance bound behind the column at `position`, from the standard floors' bound `standard` and the
    /// ground's luminance: nil (no cap) at 0, `standard` at the default, close to the ground at 100. It moves on a log
    /// scale of the distance a cell may stray from the ground, the scale `PictureInk.cellCap` relaxes on.
    public static func pictureBound(_ standard: Double?, groundY: Double, dark: Bool, at position: Int) -> Double? {
        guard let standard else { return nil }
        if position == Self.standard { return standard }
        guard position > 0 else { return nil }
        // Dark caps from above toward 1 (no cap); light from below toward 0.
        let room = dark ? max(standard, 1e-6) : max(1 - standard, 1e-6)
        let groundRoom = dark ? max(groundY, 1e-6) : max(1 - groundY, 1e-6)
        let near = groundRoom + (room - groundRoom) * strongest
        let p = Double(min(position, 100))
        let r: Double
        if p <= Double(Self.standard) {
            r = pow(room, p / Double(Self.standard))
        } else {
            let v = (p - Double(Self.standard)) / Double(100 - Self.standard)
            r = exp(log(room) + (log(min(near, room)) - log(room)) * v)
        }
        return dark ? r : 1 - r
    }

    /// Blur's dim (percent, 0...90, the stored `ditherBackgroundDim`) at `position`: 35, its default, at the standard
    /// position, none at 0 and 90 at 100.
    public static func blurDim(at position: Int) -> Int {
        let p = Double(min(max(position, 0), 100))
        let dim = p <= Double(standard) ? p * 35 / Double(standard) : 35 + (p - Double(standard)) * 55 / Double(100 - standard)
        return Int(dim.rounded())
    }

    /// The position that shows a stored Blur dim.
    public static func position(blurDim dim: Int) -> Int {
        let d = Double(min(max(dim, 0), 90))
        let p = d <= 35 ? d * Double(standard) / 35 : Double(standard) + (d - 35) * Double(100 - standard) / 55
        return Int(p.rounded())
    }
}
