import AppKit
import Testing
import DesignSystem
@testable import T3Protocol
@testable import Features

/// Redesign's dithered Usage chart: the monotone curve, the cell mask, the one-time entrance and the scrub.
@MainActor
struct UsageDitherChartTests {
    /// 30 days shaped like the user's: Claude dominant with tall spikes, Codex and Cursor small, Antigravity near zero.
    static let days = UsageFormat.enumerateDays("2026-10-23", "2026-11-21")
    static let claude = [0.45, 0.25, 0.02, 0.05, 0.12, 0.15, 0.2, 0.05, 0.02, 0.05, 2.45, 2.45, 2.6, 0.7, 0.8, 0.35, 0.15, 0.2, 1.45,
                         1.1, 0.2, 0.7, 0.95, 0.1, 0.15, 0.6, 2.0, 0.3, 4.8, 0.3]
    static let codex = [0, 0, 0.05, 0.15, 0.05, 0.02, 0.05, 0.03, 0, 0.05, 0.04, 0.55, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    static let cursor = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0.3, 0.3, 0.9, 0.75, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    static let antigravity = [Double](repeating: 0.012, count: 30)

    static func model() -> UsageChartView.Model {
        var m = UsageChartView.Model()
        m.providers = [.codex, .claude, .cursor, .antigravity]
        m.periods = days
        m.tokens = true
        m.timeZone = "UTC"
        let series: [(UsageProviderKind, [Double])] = [(.claude, claude), (.codex, codex), (.cursor, cursor), (.antigravity, antigravity)]
        m.byPeriod = Dictionary(uniqueKeysWithValues: days.enumerated().map { i, d in
            let by = Dictionary(uniqueKeysWithValues: series.map { ($0.0, UsageByProvider(totalTokens: $0.1[i] * 1e9)) })
            return (d, UsagePeriodTotals(day: d, hourStart: nil, costUsd: 0, totalTokens: series.reduce(0) { $0 + $1.1[i] * 1e9 }, byProvider: by))
        })
        return m
    }

    static func input() -> UsageDitherPlotView.Input {
        let scale = UsageChartLogic.niceScale(4.8e9)
        return .init(series: [("claude", claude), ("cursor", cursor), ("codex", codex), ("antigravity", antigravity)].map {
            UsageDitherPlotView.Series(id: $0.0, color: .orange, values: $0.1.map { $0 * 1e9 })
        }, scaleMax: scale.max, ticks: scale.ticks)
    }

    static func withRedesign(dark: Bool, _ body: () throws -> Void) rethrows {
        let previous = ThemeRuntime.input, appearance = NSApp?.appearance
        defer { ThemeRuntime.apply(previous); NSApp?.appearance = appearance }
        var input = ThemeRuntimeInput(light: ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .light)!),
                                      dark: ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .dark)!))
        input.ditherLight = true; input.ditherDark = true
        ThemeRuntime.apply(input)
        NSApplication.shared.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        try body()
    }

    @Test func monotoneCurveStaysBetweenItsNeighbours() {
        var rng = SystemRandomNumberGenerator()
        for trial in 0..<200 {
            let n = 2 + trial % 40
            // Spiky non-negative data with runs of zeros, like daily usage.
            let values = (0..<n).map { _ in Double.random(in: 0...1, using: &rng) < 0.3 ? 0 : pow(Double.random(in: 0...1, using: &rng), 3) * 5e9 }
            let max = UsageChartLogic.niceScale(values.max() ?? 0).max
            let pts = UsageChartLogic.points(values, max: max)
            let segs = UsageChartLogic.curve(pts)
            for s in segs {
                let lo = Swift.min(s.0.y, s.3.y), hi = Swift.max(s.0.y, s.3.y)
                for k in 0...40 {
                    let x = s.0.x + (s.3.x - s.0.x) * CGFloat(k) / 40
                    let y = UsageChartLogic.sample(segs, x: x)
                    #expect(y >= lo - 1e-6 && y <= hi + 1e-6, "left [\(lo), \(hi)] at x \(x): \(y)")
                    // Below zero is below the baseline, the view's foot.
                    #expect(y <= UsageChartLogic.viewHeight + 1e-6)
                }
            }
        }
    }


    /// Every series cell, fill or edge, of series `k` in column `x`.
    /// The series a cell belongs to: its fill and edge layers, then its hole layer after every fill and edge.
    static func series(_ cell: UInt8, of n: Int = input().series.count) -> Int? {
        let c = Int(cell)
        return c >= 2 + 2 * n ? c - 2 - 2 * n : c >= 2 ? (c - 2) / 2 : nil
    }

    @Test func maskIsDeterministicAndStaysWithinTheData() {
        let size = CGSize(width: 700, height: 224)
        let input = Self.input()
        for shape in [UsageDitherPlotView.Shape.linear, .step, .smooth] {
            let a = UsageDitherPlotView.grid(input, size: size, shape: shape)
            #expect(a == UsageDitherPlotView.grid(input, size: size, shape: shape))
            let tops = UsageDitherPlotView.drawnTops(input, size: size, shape: shape)
            for x in 0..<a.width {
                // Nothing above the highest quantised edge in the column, and that top cell is an edge.
                let highest = tops.map { $0[x] }.min() ?? a.height
                for y in 0..<a.height where a[x, y] >= 2 {
                    #expect(y >= highest, "cell above the edge at \(x), \(y)")
                    // A cell of series k sits on or under k's own edge.
                    if let k = Self.series(a[x, y]) { #expect(y >= tops[k][x], "series \(k) above its edge at \(x), \(y)") }
                }
                // The column's top drawn cell is an edge; a rear edge one cell over a front series is its dark margin.
                if let first = (0..<a.height).first(where: { a[x, $0] >= 2 }) {
                    #expect(a[x, first] >= 3 && a[x, first] % 2 == 1, "top cell is not an edge at \(x)")
                }
                // A rear series' edge never shows inside a front series or its margin (r5-chart-overlap-weird.png).
                for y in 0..<a.height where a[x, y] >= 3 && a[x, y] % 2 == 1 && Int(a[x, y]) < 2 + 2 * tops.count {
                    let k = (Int(a[x, y]) - 3) / 2
                    #expect(!tops[(k + 1)...].contains { a.covers($0, x, y) }, "series \(k) edge over a front series at \(x), \(y)")
                }
            }
        }
        // Linear tops never pass the higher of their two days, nor drop under the lower (one cell of rounding).
        let frame = UsageDitherPlotView.gridFrame(size)
        let tops = UsageDitherPlotView.tops(input, size: size, shape: .linear)
        let sy = size.height / UsageChartLogic.viewHeight
        for (k, s) in input.series.enumerated() {
            let n = s.values.count
            for x in 0..<frame.columns where tops[k][x] < frame.rows {
                let f = min(Double(n - 1), (Double(x) + 0.5) * Double(DitherFill.chartCell) / Double(size.width) * Double(n - 1))
                let i = min(n - 2, Int(f))
                let rows = [s.values[i], s.values[i + 1]].map { (UsageChartLogic.y($0, max: input.scaleMax) * sy - frame.rect.minY) / DitherFill.chartCell }
                #expect(Double(tops[k][x]) >= Double(rows.min()!) - 1 && Double(tops[k][x]) <= Double(rows.max()!) + 1)
            }
        }
        // A day with usage always shows a cell, however small.
        #expect(tops[3].allSatisfy { $0 == frame.rows - 1 })
        // The entrance builds left to right and ends on the resting plot.
        let grid = UsageDitherPlotView.grid(input, size: size)
        let half = grid.revealed(columns: grid.width / 2)
        #expect(half.cells.indices.allSatisfy { i in (i % grid.width) < grid.width / 2 ? half.cells[i] == grid.cells[i] : half.cells[i] == 0 })
        #expect(grid.revealed(columns: grid.width) == grid)
    }

    /// Inside a series the cells its texture leaves open are its own hole layer, a dark tint of its color, never clear.
    @Test func holesTakeTheSeriesTint() {
        let size = CGSize(width: 700, height: 224)
        let input = Self.input()
        let n = input.series.count
        let grid = UsageDitherPlotView.grid(input, size: size)
        let tops = UsageDitherPlotView.tops(input, size: size)
        var holes = 0
        for x in 1..<grid.width - 1 where tops[0][x] < grid.height - 4 {
            // Clear of the one-cell margin a series in front keeps around itself, in this column and its neighbours.
            for y in tops[0][x]..<grid.height where tops.dropFirst().allSatisfy({ f in (x - 1...x + 1).allSatisfy { y < f[$0] - 1 } }) {
                #expect(grid[x, y] != 0, "clear cell inside series 0 at \(x), \(y)")
                if grid[x, y] == UsageDitherPlotView.holeLayer(0, of: n) { holes += 1 }
            }
        }
        #expect(holes > 0)
    }

    /// A front series under one cell tall leaves the foot of a taller series behind it alone (G6, round 2).
    @Test func thinFrontSeriesDrawsNoStripOverTheRear() {
        let size = CGSize(width: 700, height: 224)
        let input = Self.input()
        let grid = UsageDitherPlotView.grid(input, size: size)
        let tops = UsageDitherPlotView.tops(input, size: size)
        let foot = grid.height - 1
        for i in tops.indices.dropFirst() {
            for x in tops[i].indices where tops[i][x] == foot && tops[..<i].contains(where: { $0[x] < foot }) {
                #expect(grid[x, foot] != UInt8(2 + 2 * i) && grid[x, foot] != UInt8(3 + 2 * i), "series \(i) strip at \(x)")
            }
        }
    }

    @Test func texturesAreDistinctAndOrdered() {
        #expect((0..<4).map(DitherFill.Texture.forSeries) == [.gradient, .hatch, .counterHatch, .dots])
        // The gradient is solid at the foot and broken toward the edge.
        let foot = (0..<8).flatMap { x in (0..<8).map { y in DitherFill.Texture.gradient.admits(x, y, depth: 0.9) } }
        let edge = (0..<8).flatMap { x in (0..<8).map { y in DitherFill.Texture.gradient.admits(x, y, depth: 0) } }
        #expect(foot.allSatisfy { $0 })
        #expect(edge.filter { $0 }.count == 32)
        // It breaks up over the top 55% of the area's own height, thinning slowly: still open a third of the way down.
        let third = (0..<8).flatMap { x in (0..<8).map { y in DitherFill.Texture.gradient.admits(x, y, depth: 0.33) } }
        #expect(third.filter { !$0 }.count >= 16)
        #expect(DitherFill.density(depth: 0.55) == 1)
        // The hatches are mirror images; no two textures agree on an 8 by 8 tile.
        let tiles = DitherFill.Texture.allCases.map { t in (0..<8).flatMap { x in (0..<8).map { y in t.admits(x, y, depth: 0.2) } } }
        #expect(Set(tiles.map { $0.map { $0 ? "1" : "0" }.joined() }).count == 4)
    }

    @Test func legendSpotlightsAndLocks() {
        let legend = UsageChartLegendView()
        var seen: [String?] = []
        legend.onSpotlight = { seen.append($0) }
        legend.set([("claude", "Claude", .orange), ("codex", "Codex", .white)])
        legend.toggle("codex")
        #expect(legend.spotlight == "codex")
        legend.toggle("codex")
        #expect(legend.spotlight == nil)
        #expect(seen == ["codex", nil])
        // A spotlight dims the other series in the bitmap's colors only: the cells stay.
        var a = Self.input(), b = Self.input()
        b.spotlight = "claude"
        let size = CGSize(width: 400, height: 224)
        #expect(UsageDitherPlotView.grid(a, size: size) == UsageDitherPlotView.grid(b, size: size))
        a.spotlight = nil
    }

    @Test func entrancePlaysOnceAndLeavesNothingRunning() throws {
        let motion = Motion.reducedOverride
        defer { Motion.reducedOverride = motion }
        try Self.withRedesign(dark: true) {
            for reduced in [false, true] {
                Motion.reducedOverride = reduced
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 224), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                defer { window.contentView = nil }
                let view = UsageDitherPlotView(frame: window.contentLayoutRect)
                window.contentView = view
                view.input = Self.input()
                view.layoutSubtreeIfNeeded()
                #expect(view.entered)
                let build = view.fill.animation(forKey: "entrance") as? CAKeyframeAnimation
                if reduced {
                    #expect(view.fill.animationKeys() == nil)
                } else {
                    let b = try #require(build)
                    #expect(b.duration <= 0.45 && b.repeatCount == 0 && b.isRemovedOnCompletion && b.calculationMode == .discrete)
                    // The last frame is the resting fill, so the end is exactly what stays.
                    #expect((b.values?.last as AnyObject?) === (view.fill.contents as AnyObject?))
                }
                // New figures redraw the fill at once, with no second entrance.
                view.fill.removeAllAnimations()
                var next = Self.input(); next.series[0].values[3] = 3e9
                view.input = next
                view.layoutSubtreeIfNeeded()
                #expect(view.fill.animationKeys() == nil)
                #expect(view.layer?.animationKeys() == nil)
            }
        }
    }

    @Test func scrubSnapsToTheNearestDay() {
        // 30 days over 870pt: a column every 30pt.
        #expect(UsageChartLogic.nearestIndex(x: 0, width: 870, count: 30) == 0)
        #expect(UsageChartLogic.nearestIndex(x: 44, width: 870, count: 30) == 1)
        #expect(UsageChartLogic.nearestIndex(x: 46, width: 870, count: 30) == 2)
        #expect(UsageChartLogic.nearestIndex(x: 2000, width: 870, count: 30) == 29)
        #expect(UsageChartLogic.nearestIndex(x: -5, width: 870, count: 30) == 0)
        #expect(UsageChartLogic.nearestIndex(x: 10, width: 870, count: 0) == nil)
        #expect(UsageChartPlotView.scrub(nil, by: -1, count: 30) == 29)
        #expect(UsageChartPlotView.scrub(nil, by: 1, count: 30) == 0)
        #expect(UsageChartPlotView.scrub(29, by: 1, count: 30) == 29)
        #expect(UsageChartPlotView.scrub(4, by: -1, count: 30) == 3)
    }

    @Test func voiceOverSummary() {
        let m = Self.model()
        let columns = UsageChartLogic.columns(m.periods, m.byPeriod, tokens: true)
        let s = UsageChartView.accessibilitySummary(m, columns: columns, period: UsageFormat.dayShort, format: UsageFormat.tokens)
        #expect(s == "\(UsageFormat.dayShort("2026-10-23")) to \(UsageFormat.dayShort("2026-11-21")), peak \(UsageFormat.tokens(4.8e9 + 0.012e9)) on \(UsageFormat.dayShort("2026-11-20"))")
    }

    @Test func renderCost() {
        let size = CGSize(width: 870, height: 224)
        let input = Self.input()
        let start = Date()
        let runs = 20
        var bytes = 0
        for _ in 0..<runs {
            let image = UsageDitherPlotView.image(UsageDitherPlotView.grid(input, size: size), colors: [CGColor](repeating: .white, count: 13), ground: .black)
            bytes = (image?.bytesPerRow ?? 0) * (image?.height ?? 0)
        }
        let ms = Date().timeIntervalSince(start) / Double(runs) * 1000
        print("usage dither render: \(String(format: "%.2f", ms)) ms, \(bytes) bytes cached")
        // Debug build under parallel test load; an optimized build is several times faster.
        #expect(ms < 60)
    }

    // MARK: Pictures

    nonisolated static let pictures = ProcessInfo.processInfo.environment["CANDY_DITHER_PICTURES"]

    /// Pictures side by side (or stacked) on the ground, each with a caption above it.
    static func stack(_ shots: [(String, NSBitmapImageRep)], dark: Bool, vertical: Bool, labels: Bool = true) -> NSBitmapImageRep {
        let gap: CGFloat = 16, caption: CGFloat = labels ? 24 : 0
        let sizes = shots.map { $0.1.size }
        let w = vertical ? (sizes.map(\.width).max() ?? 0) : sizes.reduce(0) { $0 + $1.width } + gap * CGFloat(max(0, shots.count - 1))
        let h = vertical ? sizes.reduce(0) { $0 + $1.height + caption } + gap * CGFloat(max(0, shots.count - 1)) : (sizes.map(\.height).max() ?? 0) + caption
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w * 2), pixelsHigh: Int(h * 2), bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!.retagging(with: .sRGB)!
        rep.size = NSSize(width: w, height: h)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        (dark ? NSColor(white: 0.03, alpha: 1) : NSColor(white: 0.97, alpha: 1)).setFill()
        NSRect(x: 0, y: 0, width: w, height: h).fill()
        NSGraphicsContext.current?.imageInterpolation = .none
        var x: CGFloat = 0, top: CGFloat = 0
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium),
                                                    .foregroundColor: dark ? NSColor(white: 0.85, alpha: 1) : NSColor(white: 0.2, alpha: 1)]
        for (label, shot) in shots {
            let s = shot.size
            if labels { (label as NSString).draw(at: NSPoint(x: x + 4, y: h - top - 18), withAttributes: attrs) }
            shot.draw(in: NSRect(x: x, y: h - top - caption - s.height, width: s.width, height: s.height))
            if vertical { top += s.height + caption + gap } else { x += s.width + gap }
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    static func write(_ rep: NSBitmapImageRep, to url: URL) throws {
        try rep.representation(using: .png, properties: [:])!.write(to: url)
    }

}
