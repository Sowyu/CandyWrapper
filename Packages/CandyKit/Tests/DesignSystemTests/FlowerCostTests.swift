import AppKit
import Foundation
import Testing
@testable import DesignSystem

/// What a Flower frame set costs to render, part by part, at the app's sample count and worker count. Opt in with
/// `CW_FLOWER_TIMING=1`; build it with `-c release` for the shipped number. Prints the median and the minimum of
/// `CW_FLOWER_REPS` runs (5 by default).
struct FlowerCostTests {
    static let enabled = ProcessInfo.processInfo.environment["CW_FLOWER_TIMING"] == "1"

    @Test(.enabled(if: FlowerCostTests.enabled)) func timesAFullSet() throws {
        let reps = Int(ProcessInfo.processInfo.environment["CW_FLOWER_REPS"] ?? "") ?? 5
        let cell = DitherArt.gradientUnit
        // The new-thread page in a 1,400 x 900pt content area, the composer group's top 420pt down, and a thread with a
        // 300pt right panel open.
        let hero = CGRect(x: 0, y: 0, width: 1400, height: 900), thread = CGRect(x: 0, y: 0, width: 1100, height: 900)
        for (name, content, floor) in [("hero", hero, CGFloat(420) as CGFloat?), ("thread", thread, nil)] {
            let p = try #require(LotusArt.canvas(content: content, cell: cell))
            let full = try #require(LotusArt.fullCanvas(content: content, cell: cell))
            let opening = floor.flatMap { LotusArt.opening(content: content, floorTop: $0, cell: cell) }
            let key = FlowerKey(placement: p, full: full, dark: true)
            print("flower-cost \(name): flower \(p.width) x \(p.height) cells, full \(full.width) x \(full.height), workers \(LotusArt.renderWorkers), samples \(DitherArtView.flowerSamples), opening \(opening != nil)")
            var parts: [(String, FlowerParts)] = [("open", .open), ("bloom", .bloom)]
            if opening != nil { parts += [("opening", .opening), ("flight", .flight), ("idle", .idle)] }
            var totals: [Double] = Array(repeating: 0, count: reps)
            for (label, part) in parts {
                var ms: [Double] = []
                for r in 0..<reps {
                    let codes = FlowerCodes(key: key)
                    let t0 = DispatchTime.now().uptimeNanoseconds
                    var phases = DitherArtView.flowerPhases(key, part, opening: opening, job: FlowerJob(), codes: codes)
                    while phases.next() != nil {}
                    let t = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
                    ms.append(t); totals[r] += t
                }
                ms.sort()
                print("flower-cost \(name) \(label): median \(Int(ms[ms.count / 2])) ms, min \(Int(ms[0])) ms")
            }
            if opening != nil {
                // The loop as the app now renders it, at utility.
                var ms: [Double] = []
                for _ in 0..<reps {
                    let done = DispatchSemaphore(value: 0)
                    nonisolated(unsafe) var t = 0.0
                    DispatchQueue.global(qos: .utility).async {
                        let t0 = DispatchTime.now().uptimeNanoseconds
                        var phases = DitherArtView.flowerPhases(key, .idle, opening: opening, job: FlowerJob(), codes: FlowerCodes(key: key))
                        while phases.next() != nil {}
                        t = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
                        done.signal()
                    }
                    done.wait()
                    ms.append(t)
                }
                ms.sort()
                print("flower-cost \(name) idle at utility: median \(Int(ms[ms.count / 2])) ms, min \(Int(ms[0])) ms")
            }
            totals.sort()
            print("flower-cost \(name) total: median \(Int(totals[totals.count / 2])) ms, min \(Int(totals[0])) ms")
            // The same set as a later launch gets it: read from disk and composed over the field.
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("cw-flower-cost-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let all = parts.reduce(into: FlowerParts()) { $0.formUnion($1.1) }
            var disk: [Double] = []
            for r in 0...reps {
                let t0 = DispatchTime.now().uptimeNanoseconds
                var phases = DitherArtView.flowerPhases(key, all, opening: opening, job: FlowerJob(),
                                                        codes: FlowerCodes(key: key, disk: FlowerDisk(root: root, build: "cost")))
                while phases.next() != nil {}
                // The first pass renders and writes.
                if r > 0 { disk.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6) }
            }
            disk.sort()
            print("flower-cost \(name) from disk: median \(Int(disk[disk.count / 2])) ms, min \(Int(disk[0])) ms")
            // One tick of the idle turn: the frame composed over the field on the main thread.
            if opening != nil {
                let codes = FlowerCodes(key: key)
                var phases = DitherArtView.flowerPhases(key, .idle, job: FlowerJob(), codes: codes)
                guard case let .idle(frames)? = phases.next() else { Issue.record("no idle"); return }
                var tick: [Double] = []
                for i in 0..<50 {
                    let t0 = DispatchTime.now().uptimeNanoseconds
                    _ = LotusArt.frame(packed: frames[i % frames.count], flower: p, full: full, t: Double(i) / 96, dark: true)
                    tick.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
                }
                tick.sort()
                print("flower-cost \(name) tick: median \(tick[25]) ms, min \(tick[0]) ms")
            }
        }
    }
}
