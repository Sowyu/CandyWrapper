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

    @Test func ditherMaskIsDeterministicAndStaysUnderTheLines() {
        let size = CGSize(width: 700, height: 224)
        for overlap in [UsageDitherPlotView.Overlap.layered, .checker, .hatched] {
            let a = UsageDitherPlotView.grid(Self.input(), size: size, overlap: overlap)
            let b = UsageDitherPlotView.grid(Self.input(), size: size, overlap: overlap)
            #expect(a == b)
            #expect(a.cells.contains { $0 >= 2 })
        }
        // A cell of series k sits on or under that series' line.
        let input = Self.input()
        let grid = UsageDitherPlotView.grid(input, size: size)
        let frame = UsageDitherPlotView.gridFrame(size)
        let curves = UsageDitherPlotView.curves(input)
        let sx = size.width / UsageChartLogic.viewWidth, sy = size.height / UsageChartLogic.viewHeight
        for y in 0..<grid.height {
            for x in 0..<grid.width where grid[x, y] >= 2 {
                let segs = curves[Int(grid[x, y]) - 2]
                let line = UsageChartLogic.sample(segs, x: min(size.width, (CGFloat(x) + 0.5) * DitherFill.cell) / sx) * sy
                #expect(frame.rect.minY + (CGFloat(y) + 0.5) * DitherFill.cell >= line - 1e-6)
            }
        }
        // The resting fill is the entrance's last step, and an early step holds fewer cells.
        let early = UsageDitherPlotView.grid(input, size: size, reveal: 0.3)
        #expect(early.cells.filter { $0 >= 2 }.count < grid.cells.filter { $0 >= 2 }.count)
        #expect(UsageDitherPlotView.grid(input, size: size, reveal: 1) == grid)
        #expect(grid.revealed(1).cells == grid.cells)
        let part = grid.revealed(0.3)
        #expect(part.cells.indices.allSatisfy { part.cells[$0] == 0 || part.cells[$0] == grid.cells[$0] })
        #expect(part.cells.filter { $0 >= 2 }.count < grid.cells.filter { $0 >= 2 }.count)
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
            let image = DitherFill.image(UsageDitherPlotView.grid(input, size: size), colors: [CGColor.black, .white, .white, .white, .white])
            bytes = (image?.bytesPerRow ?? 0) * (image?.height ?? 0)
        }
        let ms = Date().timeIntervalSince(start) / Double(runs) * 1000
        print("usage dither render: \(String(format: "%.2f", ms)) ms, \(bytes) bytes cached")
        // Debug build under parallel test load; an optimized build is several times faster.
        #expect(ms < 60)
    }

    // MARK: Pictures

    nonisolated static let pictures = ProcessInfo.processInfo.environment["CANDY_DITHER_PICTURES"]

    @Test(.enabled(if: pictures != nil)) func writePictures() throws {
        let dir = URL(fileURLWithPath: Self.pictures!)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let motion = Motion.reducedOverride
        defer { Motion.reducedOverride = motion; UsageChartPlotView.redesignOverride = nil }
        Motion.reducedOverride = true
        let size = NSSize(width: 960, height: 300)
        for dark in [true, false] {
            try Self.withRedesign(dark: dark) {
                let name = dark ? "dark" : "light"
                var shots: [(String, NSBitmapImageRep)] = []
                for before in [true, false] {
                    UsageChartPlotView.redesignOverride = before ? false : nil
                    let chart = UsageChartView()
                    chart.model = Self.model()
                    shots.append((before ? "Before" : "After", RedesignBaselineTests.image(Self.padded(chart), size: size, dark: dark)))
                }
                UsageChartPlotView.redesignOverride = nil
                try Self.write(Self.stack(shots, dark: dark, vertical: true), to: dir.appendingPathComponent("before-after-\(name).png"))
                // The scrub on Nov 3, a busy day where three series overlap.
                let chart = UsageChartView()
                chart.model = Self.model()
                let host = Self.padded(chart)
                _ = RedesignBaselineTests.image(host, size: size, dark: dark)
                let plot = try #require(chart.subviews.compactMap { $0 as? UsageChartPlotView }.first)
                plot.hoverIndex = 12
                try Self.write(RedesignBaselineTests.image(host, size: size, dark: dark), to: dir.appendingPathComponent("scrub-\(name).png"))
            }
        }
        // Plot-only comparisons, dark and light rows.
        let plot = CGSize(width: 560, height: 224)
        for (file, variants) in [
            ("cell-sizes", [("2pt", 2.0, UsageDitherPlotView.Overlap.checker, 1.0), ("3pt", 3, .checker, 1), ("4pt", 4, .checker, 1)]),
            ("overlap-options", [("Layered", 3.0, UsageDitherPlotView.Overlap.layered, 1.0), ("Checker", 3, .checker, 1), ("Hatched", 3, .hatched, 1)]),
            ("entrance-frames", [0.1, 0.3, 0.5, 0.7, 0.9, 1].map { ("\(Int($0 * 400)) ms", 3.0, UsageDitherPlotView.Overlap.checker, $0) }),
        ] {
            var rows: [NSBitmapImageRep] = []
            for dark in [true, false] {
                try Self.withRedesign(dark: dark) {
                    let shots = variants.map { label, cell, overlap, reveal in
                        (label, Self.plotPicture(size: plot, cell: CGFloat(cell), overlap: overlap, reveal: reveal, dark: dark))
                    }
                    rows.append(Self.stack(shots, dark: dark, vertical: false))
                }
            }
            try Self.write(Self.stack(rows.map { ("", $0) }, dark: true, vertical: true, labels: false), to: dir.appendingPathComponent("\(file).png"))
        }
    }

    static func padded(_ chart: UsageChartView) -> NSView {
        let host = ConnectionsFidelityTests.Canvas(frame: .zero)
        host.addSubview(chart)
        chart.frame = NSRect(x: 24, y: 24, width: 912, height: UsageChartView.height)
        return host
    }

    /// The plot alone, drawn the way the view draws it: ground, the cell bitmap scaled up nearest, then the lines.
    static func plotPicture(size: CGSize, cell: CGFloat, overlap: UsageDitherPlotView.Overlap, reveal: Double, dark: Bool) -> NSBitmapImageRep {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        var rep: NSBitmapImageRep!
        appearance.performAsCurrentDrawingAppearance {
            let m = Self.model()
            let columns = UsageChartLogic.columns(m.periods, m.byPeriod, tokens: true)
            let scale = UsageChartLogic.scale(columns, loading: false)
            let order: [UsageProviderKind] = [.claude, .cursor, .codex, .antigravity]
            let input = UsageDitherPlotView.Input(series: order.map { p in
                .init(id: p.rawValue, color: UsageStyle.color(p), values: columns.map { $0.value(p) })
            }, scaleMax: scale.max, ticks: scale.ticks)
            let colors = [Themed.color(\.border).cgColor] + order.map { UsageStyle.color($0).cgColor }
            rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                .retagging(with: .sRGB)!
            rep.size = size
            let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
            ctx.setFillColor(Themed.color(\.background).cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            // Flip so y runs down like the view.
            ctx.translateBy(x: 0, y: size.height); ctx.scaleBy(x: 1, y: -1)
            let frame = UsageDitherPlotView.gridFrame(size, cell: cell)
            if let image = DitherFill.image(UsageDitherPlotView.grid(input, size: size, overlap: overlap, reveal: reveal, cell: cell), colors: colors) {
                ctx.saveGState()
                ctx.interpolationQuality = .none
                ctx.translateBy(x: frame.rect.minX, y: frame.rect.maxY); ctx.scaleBy(x: 1, y: -1)
                ctx.draw(image, in: CGRect(origin: .zero, size: frame.rect.size))
                ctx.restoreGState()
            }
            ctx.setLineWidth(1.5); ctx.setLineJoin(.round); ctx.setLineCap(.round)
            for (i, path) in UsageDitherPlotView.linePaths(input, size: size).enumerated() {
                guard let path else { continue }
                ctx.addPath(path); ctx.setStrokeColor(colors[i + 1]); ctx.strokePath()
            }
        }
        return rep
    }

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
