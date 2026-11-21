import AppKit
import Testing
import DesignSystem
@testable import T3Protocol
@testable import Features

/// Review pictures for Redesign's dithered Usage chart, written only when CANDY_DITHER_PICTURES names a folder.
@MainActor
struct UsageDitherChartPictures {
    nonisolated static let folder = ProcessInfo.processInfo.environment["CANDY_DITHER_PICTURES"]
    static let notes = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("CandyWrapper-research/sandbox/redesign-user-notes")

    @Test(.enabled(if: folder != nil)) func write() throws {
        let dir = URL(fileURLWithPath: Self.folder!)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let motion = Motion.reducedOverride
        defer { Motion.reducedOverride = motion }
        Motion.reducedOverride = true
        let size = NSSize(width: 946, height: 330)
        for dark in [true, false] {
            let name = dark ? "dark" : "light"
            try UsageDitherChartTests.withRedesign(dark: dark) {
                let (host, _) = Self.host(UsageDitherChartTests.model())
                let shot = RedesignBaselineTests.image(host, size: size, dark: dark)
                try UsageDitherChartTests.write(shot, to: dir.appendingPathComponent("fixture-\(name).png"))
                if dark {
                    let target = try #require(NSBitmapImageRep(data: Data(contentsOf: Self.notes.appendingPathComponent("chart-target-dither-kit.png"))))
                    let first = try #require(NSBitmapImageRep(data: Data(contentsOf: Self.notes.appendingPathComponent("chart-first-try-jarring.png"))))
                    target.size = NSSize(width: 946, height: CGFloat(target.pixelsHigh) * 946 / CGFloat(target.pixelsWide))
                    first.size = NSSize(width: 946, height: CGFloat(first.pixelsHigh) * 946 / CGFloat(first.pixelsWide))
                    try UsageDitherChartTests.write(UsageDitherChartTests.stack([("Target: dither-kit's area chart", target),
                                                                                ("First try", first), ("Second pass", shot)],
                                                                               dark: true, vertical: true),
                                                    to: dir.appendingPathComponent("side-by-side.png"))
                }
                // The scrub on Nov 4.
                let (scrubHost, chart) = Self.host(UsageDitherChartTests.model())
                _ = RedesignBaselineTests.image(scrubHost, size: size, dark: dark)
                let plot = try #require(chart.subviews.compactMap { $0 as? UsageChartPlotView }.first)
                plot.hoverIndex = 12
                try UsageDitherChartTests.write(RedesignBaselineTests.image(scrubHost, size: size, dark: dark),
                                                to: dir.appendingPathComponent("scrub-\(name).png"))
                // The legend's spotlight locked on Cursor.
                let (spotHost, spotChart) = Self.host(UsageDitherChartTests.model())
                spotChart.legend.toggle(UsageProviderKind.cursor.rawValue)
                try UsageDitherChartTests.write(RedesignBaselineTests.image(spotHost, size: size, dark: dark),
                                                to: dir.appendingPathComponent("spotlight-\(name).png"))
            }
        }
        // Plot-only comparisons, a dark row over a light row.
        let plot = CGSize(width: 600, height: 224)
        let user = UsageDitherChartTests.model()
        let sets: [(String, [(String, UsageChartView.Model, CGFloat, UsageDitherPlotView.Shape)])] = [
            ("cells-2-vs-3", [("2pt cells", user, 2, .linear), ("3pt cells", user, 3, .linear)]),
            ("shape-step-linear-smooth", [("Step per day", user, 2, .step), ("Straight segments", user, 2, .linear),
                                          ("Smooth, then quantised", user, 2, .smooth)]),
            ("textures", [("Four series, one texture each", Self.humps(), 2, .linear)]),
        ]
        for (file, variants) in sets {
            var rows: [NSBitmapImageRep] = []
            for dark in [true, false] {
                try UsageDitherChartTests.withRedesign(dark: dark) {
                    rows.append(UsageDitherChartTests.stack(variants.map { label, m, cell, shape in
                        (label, Self.plotPicture(m, size: plot, cell: cell, shape: shape, dark: dark))
                    }, dark: dark, vertical: false))
                }
            }
            try UsageDitherChartTests.write(UsageDitherChartTests.stack(rows.map { ("", $0) }, dark: true, vertical: true, labels: false),
                                            to: dir.appendingPathComponent("\(file).png"))
        }
    }

    /// The chart under its title row, legend at the right, as the Usage page lays it out.
    static func host(_ m: UsageChartView.Model) -> (NSView, UsageChartView) {
        let host = ConnectionsFidelityTests.Canvas(frame: .zero)
        let title = UsageStyle.label("Daily processed tokens", 14, .medium)
        let chart = UsageChartView()
        chart.model = m
        for v in [title, chart, chart.legend] as [NSView] { host.addSubview(v) }
        title.frame = NSRect(x: 24, y: 24, width: 300, height: 20)
        chart.frame = NSRect(x: 24, y: 56, width: 898, height: UsageChartView.height)
        let lw = chart.legend.fittingSize.width
        chart.legend.frame = NSRect(x: 922 - lw, y: 24, width: lw, height: 20)
        return (host, chart)
    }

    /// Four broad overlapping series, to show every texture at a readable size.
    static func humps() -> UsageChartView.Model {
        var m = UsageChartView.Model()
        let providers: [UsageProviderKind] = [.claude, .codex, .opencode, .antigravity]
        m.providers = providers
        m.periods = UsageDitherChartTests.days
        m.tokens = true
        func hump(_ c: Double, _ w: Double, _ h: Double) -> [Double] { (0..<30).map { h * exp(-pow((Double($0) - c) / w, 2)) } }
        let series = [hump(14, 9, 5), hump(8, 5, 3.4), hump(19, 4.5, 2.6), hump(24, 4, 1.6)]
        m.byPeriod = Dictionary(uniqueKeysWithValues: m.periods.enumerated().map { i, d in
            let by = Dictionary(uniqueKeysWithValues: zip(providers, series).map { ($0, UsageByProvider(totalTokens: $1[i] * 1e9)) })
            return (d, UsagePeriodTotals(day: d, hourStart: nil, costUsd: 0, totalTokens: 0, byProvider: by))
        })
        return m
    }

    /// The plot alone at a given cell size and shape, drawn as the view draws it.
    static func plotPicture(_ m: UsageChartView.Model, size: CGSize, cell: CGFloat, shape: UsageDitherPlotView.Shape, dark: Bool) -> NSBitmapImageRep {
        var rep: NSBitmapImageRep!
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            let columns = UsageChartLogic.columns(m.periods, m.byPeriod, tokens: true)
            let scale = UsageChartLogic.scale(columns, loading: false)
            let order = m.providers.sorted { a, b in columns.reduce(0) { $0 + $1.value(a) } > columns.reduce(0) { $0 + $1.value(b) } }
            let input = UsageDitherPlotView.Input(series: order.map { p in
                .init(id: p.rawValue, color: UsageStyle.color(p), values: columns.map { $0.value(p) })
            }, scaleMax: scale.max, ticks: scale.ticks)
            let ink = Themed.color(\.foreground)
            let colors = [Themed.color(\.border).cgColor] + order.flatMap { p in
                [UsageStyle.color(p).cgColor, OKLab.mix(UsageStyle.color(p), 1 - UsageDitherPlotView.edgeLift, ink).cgColor]
            }
            rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                .retagging(with: .sRGB)!
            rep.size = size
            let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
            let ground = Themed.color(\.background).cgColor
            ctx.setFillColor(ground)
            ctx.fill(CGRect(origin: .zero, size: size))
            let frame = UsageDitherPlotView.gridFrame(size, cell: cell)
            if let image = UsageDitherPlotView.image(UsageDitherPlotView.grid(input, size: size, shape: shape, cell: cell), colors: colors, ground: ground) {
                ctx.interpolationQuality = .none
                // The bitmap's first row is the top; Core Graphics draws images upright in this unflipped context.
                ctx.draw(image, in: CGRect(x: frame.rect.minX, y: size.height - frame.rect.maxY, width: frame.rect.width, height: frame.rect.height))
            }
        }
        return rep
    }
}
