import AppKit
import Testing
@testable import DesignSystem

/// The Flower's frames on disk (`FlowerDisk`): a later launch of the same build reads them instead of rendering, and
/// anything that isn't exactly those frames counts as none.
struct FlowerDiskTests {
    @Test func aLaterLaunchReadsTheFramesInsteadOfRendering() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cw-flower-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let content = CGRect(x: 0, y: 0, width: 520, height: 340), cell = DitherArt.gradientUnit
        let p = try #require(LotusArt.canvas(content: content, cell: cell)), full = try #require(LotusArt.fullCanvas(content: content, cell: cell))
        let key = FlowerKey(placement: p, full: full, dark: true)
        let length = (p.width * p.height + 3) / 4
        let frames = (0..<3).map { [UInt8](repeating: UInt8($0 + 1), count: length) }

        let first = FlowerCodes(key: key, disk: FlowerDisk(root: root, build: "1"))
        #expect(first.frames(.idle) { frames } == frames)
        #expect(first.rendered == 3)

        let later = FlowerCodes(key: key, disk: FlowerDisk(root: root, build: "1"))
        #expect(later.frames(.idle) { Issue.record("rendered again"); return nil } == frames)
        #expect(later.rendered == 0)

        // Light's frames and another part's are their own.
        let disk = FlowerDisk(root: root, build: "1")
        #expect(disk.read(FlowerKey(placement: p, full: full, dark: false), .idle) == nil)
        #expect(disk.read(key, .bloom) == nil)

        // A file that lost its end counts as none.
        let file = try #require(try FileManager.default.contentsOfDirectory(at: disk.directory, includingPropertiesForKeys: nil).first)
        try Data(contentsOf: file).dropLast().write(to: file)
        #expect(disk.read(key, .idle) == nil)

        // Past the budget the frames read longest ago go.
        var small = disk
        small.budget = 4 + 3 * length
        small.write(frames, key, .idle)
        small.write(frames, key, .bloom)
        #expect(small.read(key, .idle) == nil)
        #expect(small.read(key, .bloom) == frames)

        // Another build starts with none and removes the old build's.
        #expect(FlowerDisk(root: root, build: "2").read(key, .bloom) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["2"])
    }
}
