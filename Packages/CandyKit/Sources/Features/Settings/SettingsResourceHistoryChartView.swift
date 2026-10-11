import AppKit
import DesignSystem
import T3Protocol

/// ResourceTelemetryDiagnostics.logic.ts:53-66. Zero samples stay invisible; nonzero ones have a floor.
public enum SettingsResourceHistoryChart {
    public static func fraction(_ value: Double, maximum: Double, minimum: Double = 0.01) -> Double {
        guard value.isFinite, value > 0, maximum.isFinite else { return 0 }
        return min(1, max(minimum, value / max(1, maximum)))
    }
}

/// ResourceTelemetryDiagnostics.tsx:401-467. CPU average and read/write bytes in three columns.
final class SettingsResourceHistoryChartView: DSView, SettingsGroupRow {
    private let buckets: [JSONValue]
    private let legends = ["CPU average", "I/O reads", "I/O writes"].map {
        LabelView($0, font: DSFont.ui(10), color: Themed.color(\.mutedForeground, 0.65))
    }
    private let colors = [Themed.color(\.foreground, 0.7), Themed.color(\.info, 0.7), Themed.color(\.warning, 0.8)]
    private var targets: [DSView] = []
    init(buckets: [JSONValue]) {
        self.buckets = buckets
        super.init(frame: .zero)
        legends.forEach(addSubview)
        for b in buckets {
            let target = DSView(frame: .zero)
            let tip = String(format: "CPU avg %.1f%%\nCPU peak %.1f%%\nRead %@\nWrite %@", b["avgCpuPercent"]?.doubleValue ?? 0,
                             b["maxCpuPercent"]?.doubleValue ?? 0, DiagnosticsFormat.bytes(b["ioReadBytes"]?.doubleValue ?? 0),
                             DiagnosticsFormat.bytes(b["ioWriteBytes"]?.doubleValue ?? 0))
            _ = TooltipController.attach(to: target, text: tip)
            targets.append(target); addSubview(target)
        }
    }
    func height(forWidth width: CGFloat) -> CGFloat { 187 }
    override var wantsUpdateLayer: Bool { false }
    override func layout() {
        super.layout()
        var x: CGFloat = 20
        for legend in legends {
            legend.frame = NSRect(x: x + 18, y: 17, width: ceil(legend.textWidth), height: 14)
            x += 18 + legend.textWidth + 16
        }
        let inner = chartInner
        let step = inner.width / CGFloat(max(1, buckets.count))
        for (i, target) in targets.enumerated() {
            target.frame = NSRect(x: inner.minX + CGFloat(i) * step, y: inner.minY, width: step, height: inner.height)
        }
    }
    private var chartRect: CGRect { CGRect(x: 20, y: 43, width: max(0, bounds.width - 40), height: 128) }
    private var chartInner: CGRect { CGRect(x: 29, y: 56, width: max(0, bounds.width - 58), height: 106) }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let box = chartRect
        ctx.setFillColor(Themed.color(\.border, 0.6).cgColor(in: self)); ctx.fill(CGRect(x: 0, y: 0, width: bounds.width, height: 1))
        ctx.setFillColor(Themed.color(\.muted, 0.08).cgColor(in: self))
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: 8, cornerHeight: 8, transform: nil)); ctx.fillPath()
        ctx.setStrokeColor(Themed.color(\.border, 0.4).cgColor(in: self)); ctx.setLineWidth(1)
        ctx.addPath(CGPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 7.5, cornerHeight: 7.5, transform: nil)); ctx.strokePath()
        for (i, legend) in legends.enumerated() {
            ctx.setFillColor(colors[i].cgColor(in: self))
            ctx.addPath(CGPath(roundedRect: CGRect(x: legend.frame.minX - 18, y: 21, width: 12, height: 6), cornerWidth: 3, cornerHeight: 3, transform: nil)); ctx.fillPath()
        }
        let inner = chartInner
        let maxCpu = max(1, buckets.map { $0["avgCpuPercent"]?.doubleValue ?? 0 }.max() ?? 1)
        let maxIO = max(1, buckets.map { ($0["ioReadBytes"]?.doubleValue ?? 0) + ($0["ioWriteBytes"]?.doubleValue ?? 0) }.max() ?? 1)
        let groupWidth = max(0, (inner.width - CGFloat(max(0, buckets.count - 1)) * 4) / CGFloat(max(1, buckets.count)))
        let width = max(0, (groupWidth - 2) / 3)
        for (i, b) in buckets.enumerated() {
            let x = inner.minX + CGFloat(i) * (groupWidth + 4)
            let fractions = [SettingsResourceHistoryChart.fraction(b["avgCpuPercent"]?.doubleValue ?? 0, maximum: maxCpu, minimum: 0.02),
                             SettingsResourceHistoryChart.fraction(b["ioReadBytes"]?.doubleValue ?? 0, maximum: maxIO),
                             SettingsResourceHistoryChart.fraction(b["ioWriteBytes"]?.doubleValue ?? 0, maximum: maxIO)]
            for (column, fraction) in fractions.enumerated() where fraction > 0 {
                let height = inner.height * fraction
                ctx.setFillColor((column == 0 ? Themed.color(\.foreground, 0.65) : colors[column]).cgColor(in: self))
                let rect = CGRect(x: x + CGFloat(column) * (width + 1), y: inner.maxY - height, width: width, height: height)
                let radius = min(2, height / 2)
                ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)); ctx.fillPath()
                ctx.fill(CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2))
            }
        }
    }
}
