import CoreGraphics
import Foundation
import T3Store
import Testing
@testable import Features

@Suite struct BotGeometryTests {
    /// 21 yaws by 15 pitches, past the farthest any bot may turn, so the clamp does the work.
    static let poses: [BotGaze] = {
        let reach = BotGeometry.maxTurn * 1.2
        return (0..<21).flatMap { i in
            (0..<15).map { j in
                BotGaze(yaw: -reach + 2 * reach * Double(i) / 20, pitch: -reach + 2 * reach * Double(j) / 14)
            }
        }
    }()

    @Test(arguments: BotShape.allCases)
    func everyPoseKeepsTheEyesOffTheEdge(_ shape: BotShape) {
        #expect(Self.poses.count == 315)
        var failures: [BotGaze] = []
        for pose in Self.poses {
            let g = BotGeometry.clamp(pose, for: shape)
            if !BotGeometry.eyesClear(shape, g) { failures.append(g) }
        }
        #expect(failures.isEmpty, "\(shape.name): \(failures.count) poses bring an eye within \(BotGeometry.eyeMargin) of the edge, first \(String(describing: failures.first))")
    }

    @Test(arguments: BotShape.allCases)
    func everyShapeCanTurn(_ shape: BotShape) {
        let limits = BotGeometry.turnLimits(shape)
        #expect(limits.count == 32)
        // The baked table must match the geometry; regenerate it from `computedTurnLimits` when this fails.
        #expect(zip(limits, BotGeometry.computedTurnLimits(shape)).allSatisfy { abs($0 - $1) < 1e-9 }, "\(shape.name): turnLimitTable is stale")
        #expect(BotGeometry.eyesClear(shape, .front), "\(shape.name) fails facing front")
        #expect(limits.min()! > 0.15, "\(shape.name) can barely turn: \(limits.map { String(format: "%.2f", $0) })")
    }

    @Test func theStarTurnsTheLeast() {
        let reach = BotShape.allCases.map { s in (s, BotGeometry.turnLimits(s).reduce(0, +)) }
        #expect(reach.min { $0.1 < $1.1 }?.0 == .star)
    }

    /// The spring animates path to path point by point, so every pose must have the same points.
    @Test func posesShareTheirPointCount() {
        let id = BotIdentity(shape: .pumpkin, color: .blue)
        #expect(id.color == .orange)
        let a = BotGeometry.paths(id, gaze: .front, size: 40), b = BotGeometry.paths(id, gaze: BotGaze(yaw: 0.6, pitch: -0.4), size: 40)
        func count(_ p: CGPath) -> Int { var n = 0; p.applyWithBlock { _ in n += 1 }; return n }
        #expect(count(a.body) == count(b.body))
        #expect(count(a.eyes) == count(b.eyes))
        #expect(a.stem != nil)
        #expect(a.body.boundingBox.insetBy(dx: -BotGeometry.lineWidth(id, size: 40) / 2, dy: -BotGeometry.lineWidth(id, size: 40) / 2)
            .standardized.minX >= -0.5)
    }

    /// The look picked in Settings is the bot the sidebar and chat draw, and survives a save.
    @Test func theOrchestratorKeepsThePickedLook() throws {
        var c = OrchestratorConfig()
        #expect(c.bot == .orchestrator)
        c.botShape = BotShape.drop.rawValue
        c.botColor = BotColor.teal.rawValue
        let saved = try JSONDecoder().decode(OrchestratorConfig.self, from: JSONEncoder().encode(c))
        #expect(saved.bot == BotIdentity(shape: .drop, color: .teal))
        c.botShape = BotShape.pumpkin.rawValue
        #expect(c.bot.color == .orange)
    }
}

