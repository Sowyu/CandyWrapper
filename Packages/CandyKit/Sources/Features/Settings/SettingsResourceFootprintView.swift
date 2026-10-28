import AppKit
import DesignSystem
import T3Protocol

/// ResourceTelemetryDiagnostics.tsx:995-1087. Rebuilt only when telemetry delivers a snapshot.
final class SettingsResourceFootprintView: BoxView, SettingsGroupRow {
    private let heading = LabelView("T3 SYSTEM FOOTPRINT", font: DSFont.ui(10, weight: .semibold), color: Themed.color(\.mutedForeground, 0.7))
    private let summary = TextBlockView()
    private let sampling: TextBlockView
    private let dot = DSView()
    private let stats: [Metric]
    private let aggregates: [Aggregate]
    private let sampled: Bool
    private let gradient = CAGradientLayer()
    private var lines: [CALayer] = []

    init(snapshot: JSONValue?) {
        sampled = snapshot != nil
        let all = snapshot?["groups"]?["allT3"]
        func number(_ key: String) -> Double? { all?[key]?.doubleValue }
        func value(_ key: String, _ format: (Double) -> String) -> String { number(key).map(format) ?? "..." }
        func detail(_ key: String, _ format: (Double) -> String) -> String? { number(key).map(format) }
        let speed = snapshot?["speedLimitPercent"]?.doubleValue ?? snapshot?["speedLimitPercent"]?["value"]?.doubleValue
        stats = [
            Metric(.cpu, "Current CPU", value("currentCpuPercent") { String(format: "%.1f%%", $0) }, detail("cpuTimeMs") { DiagnosticsFormat.cpuTime($0 / 1000) + " observed CPU time" }),
            Metric(.memoryStick, "Resident memory", value("currentRssBytes", Self.bytes), detail("peakRssBytes") { Self.bytes($0) + " combined process peaks" }),
            Metric(.activity, "Process count", value("processCount") { String(Int($0)) }, all.map { "\($0["processStarts"]?.intValue ?? 0) starts · \($0["processExits"]?.intValue ?? 0) exits" }),
            Metric(.hardDrive, "Read throughput", value("ioReadBytesPerSecond") { Self.bytes($0) + "/s" }, detail("ioReadBytes") { Self.bytes($0) + " observed" }),
            Metric(.database, "Write throughput", value("ioWriteBytesPerSecond") { Self.bytes($0) + "/s" }, detail("ioWriteBytes") { Self.bytes($0) + " observed" }),
            Metric(.gauge, "CPU speed limit", snapshot == nil ? "..." : speed.map { String(format: "%.0f%%", $0) } ?? "Unknown",
                   snapshot.map { ($0["power"]?["thermalState"]?.stringValue ?? "unknown") + " thermal state" }),
        ]
        aggregates = snapshot.map { snapshot in
            [("Backend + agents", "backend", Themed.color(\.success, 0.6)),
             ("Desktop", "electron", Themed.color(\.info, 0.6)),
             ("Monitor overhead", "monitor", Themed.color(\.warning, 0.6))].map {
                Aggregate($0.0, data: snapshot["groups"]?[$0.1], accent: $0.2)
            }
        } ?? []
        sampling = TextBlockView()
        super.init(frame: .zero)
        heading.tracking = 1
        summary.text = "Live native counters for the server, providers, terminals, desktop processes, and the monitor itself."
        summary.font = DSFont.ui(12)
        summary.lineHeight = 19.5
        summary.color = Themed.color(\.mutedForeground)
        sampling.text = "Sampling every " + (snapshot?["sampleIntervalMs"]?.doubleValue.map { $0 >= 1000 ? "\(Int($0 / 1000)) second" : "\(Int($0)) ms" } ?? "...")
        sampling.font = DSFont.ui(10)
        sampling.lineHeight = 14
        sampling.color = Themed.color(\.mutedForeground, 0.65)
        dot.layer?.cornerRadius = 3
        addSubview(heading)
        addSubview(summary)
        addSubview(sampling)
        addSubview(dot)
        stats.forEach(addSubview)
        aggregates.forEach(addSubview)
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradient.actions = ["bounds": NSNull(), "position": NSNull(), "colors": NSNull()]
        layer?.insertSublayer(gradient, at: 0)
        for _ in 0..<8 {
            let line = CALayer()
            line.actions = ["bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull()]
            layer?.addSublayer(line)
            lines.append(line)
        }
        restyle()
    }

    static func bytes(_ value: Double) -> String {
        if value < 1024 { return "\(Int(value.rounded())) B" }
        let units = ["KB", "MB", "GB", "TB"]
        var next = value, unit = -1
        repeat { next /= 1024; unit += 1 } while next >= 1024 && unit < units.count - 1
        return String(format: next >= 100 ? "%.0f %@" : next >= 10 ? "%.1f %@" : "%.2f %@", next, units[unit])
    }

    private func restyle() {
        var style = BoxStyle()
        style.radius = 16
        style.fill = Themed.color(\.card)
        style.border = Themed.color(\.border, 0.7)
        style.shadows = [BoxShadow(y: 1, blur: 2, color: Themed.black(0.05))]
        boxStyle = style
        layer?.masksToBounds = true
        layer?.cornerRadius = 16
        gradient.colors = [Themed.color(\.muted, 0.45), Themed.color(\.muted, 0.2), NSColor.clear].map { $0.cgColor(in: self) }
        dot.layer?.backgroundColor = Themed.color(\.success).cgColor(in: self)
        lines.forEach { $0.backgroundColor = Themed.color(\.border, 0.55).cgColor(in: self) }
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); restyle() }

    /// The two auto-sized flex items shrink in proportion to their content widths (gap-3, px-5).
    private func headerWidths(_ width: CGFloat) -> (summary: CGFloat, sampling: CGFloat) {
        let left = min(576, TextLine(NSAttributedString(string: summary.text, attributes: [.font: summary.font])).width)
        let right = TextLine(NSAttributedString(string: sampling.text, attributes: [.font: sampling.font])).width + 14
        let available = max(0, width - 42 - 12)
        let overflow = max(0, left + right - available)
        let summaryWidth = max(0, left - overflow * left / max(1, left + right))
        return (summaryWidth, max(0, right - overflow * right / max(1, left + right) - 14))
    }
    private func headerHeight(_ width: CGFloat) -> CGFloat {
        let widths = headerWidths(width)
        return 32 + max(14 + 4 + summary.height(forWidth: widths.summary), sampling.height(forWidth: widths.sampling))
    }
    private var columns: Int { (window?.frame.width ?? 1100) >= 768 ? 3 : 2 }
    private var statHeight: CGFloat { sampled ? 108 : 88 }
    func height(forWidth width: CGFloat) -> CGFloat {
        2 + headerHeight(width) + CGFloat(6 / columns) * statHeight + (aggregates.isEmpty ? 0 : CGFloat(columns == 3 ? 1 : aggregates.count) * 150)
    }

    override func layout() {
        super.layout()
        let cols = columns, rows = 6 / cols
        let h = headerHeight(bounds.width), w = (bounds.width - 2) / CGFloat(cols)
        let statsHeight = CGFloat(rows) * statHeight
        let widths = headerWidths(bounds.width)
        gradient.frame = NSRect(x: 1, y: 1, width: bounds.width - 2, height: h)
        heading.frame = NSRect(x: 21, y: 17, width: max(0, bounds.width - 42), height: 14)
        summary.frame = NSRect(x: 21, y: 35, width: widths.summary, height: max(0, h - 50))
        let sampleHeight = sampling.height(forWidth: widths.sampling)
        let sampleX = bounds.width - 21 - widths.sampling - 14
        sampling.frame = NSRect(x: sampleX + 14, y: 1 + (h - sampleHeight) / 2, width: widths.sampling, height: sampleHeight)
        dot.frame = NSRect(x: sampleX, y: 1 + (h - 6) / 2, width: 6, height: 6)
        for (i, metric) in stats.enumerated() { metric.frame = NSRect(x: 1 + CGFloat(i % cols) * w, y: h + 1 + CGFloat(i / cols) * statHeight, width: w, height: statHeight) }
        for (i, group) in aggregates.enumerated() {
            group.frame = NSRect(x: cols == 3 ? 1 + CGFloat(i) * w : 1, y: h + 1 + statsHeight + (cols == 3 ? 0 : CGFloat(i) * 150),
                                 width: cols == 3 ? w : bounds.width - 2, height: 150)
        }
        lines.forEach { $0.isHidden = true }
        for i in 0...rows {
            lines[i].isHidden = false
            lines[i].frame = NSRect(x: 1, y: h + 1 + CGFloat(i) * statHeight, width: bounds.width - 2, height: 1)
        }
        for i in 0..<(cols - 1) {
            lines[4 + i].isHidden = false
            lines[4 + i].frame = NSRect(x: 1 + CGFloat(i + 1) * w, y: h + 1, width: 1, height: cols == 3 ? bounds.height - h - 2 : statsHeight)
        }
    }

    private final class Metric: DSView {
        let label: LabelView
        let value: LabelView
        let detail: LabelView
        let icon: IconView
        init(_ glyph: IconName, _ name: String, _ amount: String, _ note: String?) {
            label = LabelView(name.uppercased(), font: DSFont.ui(10, weight: .semibold), color: Themed.color(\.mutedForeground, 0.7))
            label.tracking = 1
            value = LabelView(amount, font: DSFont.mono(24, weight: .semibold))
            value.tracking = -1.2
            detail = LabelView(note ?? "", font: DSFont.ui(10), color: Themed.color(\.mutedForeground, 0.6))
            icon = IconView(name: glyph, size: 14, strokeColor: Themed.color(\.mutedForeground, 0.55))
            super.init(frame: .zero)
            [icon, label, value, detail].forEach(addSubview)
        }
        override func layout() {
            super.layout()
            icon.frame = NSRect(x: 20, y: 16, width: 14, height: 14)
            label.frame = NSRect(x: 42, y: 16, width: max(0, bounds.width - 62), height: 14)
            value.frame = NSRect(x: 20, y: 40, width: max(0, bounds.width - 40), height: 32)
            detail.frame = NSRect(x: 20, y: 78, width: max(0, bounds.width - 40), height: 14)
        }
    }

    private final class Aggregate: DSView {
        let title = TextBlockView()
        let count: LabelView
        let countBadge = BoxView()
        let accent: NSColor
        let stripe = CALayer()
        var pairs: [(LabelView, LabelView)] = []
        init(_ name: String, data: JSONValue?, accent: NSColor) {
            self.accent = accent
            let processes = data?["processCount"]?.intValue ?? 0
            count = LabelView("\(processes) \(processes == 1 ? "process" : "processes")", font: DSFont.mono(10), color: Themed.color(\.mutedForeground, 0.7))
            super.init(frame: .zero)
            title.text = name.uppercased()
            title.font = DSFont.ui(10, weight: .semibold)
            title.lineHeight = 14
            title.tracking = 1
            title.color = Themed.color(\.mutedForeground, 0.75)
            addSubview(title)
            var badgeStyle = BoxStyle()
            badgeStyle.radius = 6
            badgeStyle.fill = Themed.color(\.muted, 0.55)
            countBadge.boxStyle = badgeStyle
            addSubview(countBadge)
            countBadge.addSubview(count)
            stripe.actions = ["position": NSNull(), "bounds": NSNull(), "backgroundColor": NSNull(), "cornerRadius": NSNull()]
            layer?.addSublayer(stripe)
            for (label, key) in [("CPU", "currentCpuPercent"), ("Memory", "currentRssBytes"), ("Read", "ioReadBytesPerSecond"), ("Write", "ioWriteBytesPerSecond")] {
                let amount = data?[key]?.doubleValue ?? 0
                let value = key == "currentCpuPercent" ? String(format: "%.1f%%", amount) : SettingsResourceFootprintView.bytes(amount) + (key.hasSuffix("PerSecond") ? "/s" : "")
                let heading = LabelView(label.uppercased(), font: DSFont.ui(10, weight: .semibold), color: Themed.color(\.mutedForeground, 0.45))
                heading.tracking = 1
                let body = LabelView(value, font: DSFont.mono(12, weight: .medium), color: Themed.color(\.foreground, 0.9))
                pairs.append((heading, body))
                addSubview(heading)
                addSubview(body)
            }
        }
        override func layout() {
            super.layout()
            stripe.backgroundColor = accent.cgColor(in: self)
            stripe.frame = NSRect(x: 20, y: 0, width: max(0, bounds.width - 40), height: 2)
            stripe.cornerRadius = 1
            let countWidth = ceil(count.textWidth) + 12
            let titleWidth = max(0, bounds.width - 40 - 12 - countWidth)
            let headerHeight = max(18, title.height(forWidth: titleWidth))
            title.frame = NSRect(x: 20, y: 16 + (headerHeight - title.height(forWidth: titleWidth)) / 2, width: titleWidth, height: title.height(forWidth: titleWidth))
            countBadge.frame = NSRect(x: bounds.width - 20 - countWidth, y: 16 + (headerHeight - 18) / 2, width: countWidth, height: 18)
            count.frame = NSRect(x: 6, y: 2, width: countWidth - 12, height: 14)
            let w = max(0, (bounds.width - 56) / 2)
            for (i, pair) in pairs.enumerated() {
                let x = 20 + CGFloat(i % 2) * (w + 16), y = 16 + headerHeight + 14 + CGFloat(i / 2) * 40
                pair.0.frame = NSRect(x: x, y: y, width: w, height: 14)
                pair.1.frame = NSRect(x: x, y: y + 14, width: w, height: 16)
            }
        }
    }
}

final class SettingsResourceStatusBadge: BoxView {
    private let label: LabelView
    private let dot = DSView()
    private let statusColor: NSColor
    init(status: String) {
        let danger = ["unavailable", "stopped", "failed"].contains(status)
        let warning = ["degraded", "starting"].contains(status)
        let color = danger ? Themed.color(\.destructive) : warning ? Themed.color(\.warningForeground) : Themed.color(\.successForeground)
        statusColor = color
        label = LabelView("Native \(status)".uppercased(), font: DSFont.ui(10, weight: .semibold), color: color)
        label.tracking = 1
        super.init(frame: .zero)
        var style = BoxStyle()
        style.radius = 999
        style.fill = color.withAlphaComponent(0.1)
        style.border = color.withAlphaComponent(0.25)
        boxStyle = style
        dot.layer?.backgroundColor = color.cgColor(in: self)
        dot.layer?.cornerRadius = 3
        addSubview(dot)
        addSubview(label)
    }
    override var intrinsicContentSize: NSSize { NSSize(width: ceil(label.textWidth) + 34, height: 24) }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        dot.layer?.backgroundColor = statusColor.cgColor(in: self)
    }
    override func layout() {
        super.layout()
        dot.frame = NSRect(x: 11, y: (bounds.height - 6) / 2, width: 6, height: 6)
        label.frame = NSRect(x: 23, y: (bounds.height - 14) / 2, width: max(0, bounds.width - 34), height: 14)
    }
}
