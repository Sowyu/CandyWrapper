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
        sampling.text = snapshot?["sampleIntervalMs"]?.doubleValue.map(DiagnosticsFormat.samplingStatus) ?? "Sampling every ..."
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

    static func bytes(_ value: Double) -> String { DiagnosticsFormat.bytes(value) }

    private func restyle() {
        // 4928 draws the footprint inside the section's own card (`overflow-hidden rounded-[inherit]`,
        // ResourceTelemetryDiagnostics.tsx:1094), so it adds no fill or border of its own.
        boxStyle = BoxStyle()
        layer?.masksToBounds = true
        layer?.cornerRadius = DesignGeometry.radius(12, in: self)
        gradient.colors = [Themed.color(\.muted, 0.45), Themed.color(\.muted, 0.2), Themed.color(\.muted, 0)].map { $0.cgColor(in: self) }
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
        /// (max-content, min-content) widths: the whole text on one line, and its longest word.
        static func contentWidths(_ v: TextBlockView) -> (CGFloat, CGFloat) {
            let probe = TextBlockView()
            probe.font = v.font; probe.tracking = v.tracking; probe.lineHeight = v.lineHeight
            func width(_ text: String) -> CGFloat { probe.text = text; return ceil(probe.layout(forWidth: 10_000).widths.max() ?? 0) }
            return (width(v.text), v.text.split(separator: " ").map { width(String($0)) }.max() ?? 0)
        }

        /// CSS flex shrink of two items with (basis, min-content) widths into `available`.
        static func shrink(available: CGFloat, _ a: (CGFloat, CGFloat), _ b: (CGFloat, CGFloat)) -> (CGFloat, CGFloat) {
            let overflow = a.0 + b.0 - available
            guard overflow > 0 else { return (a.0, b.0) }
            var wa = a.0 - overflow * a.0 / (a.0 + b.0), wb = b.0 - overflow * b.0 / (a.0 + b.0)
            if wa < a.1 { wa = a.1; wb = max(b.1, available - wa) } else if wb < b.1 { wb = b.1; wa = max(a.1, available - wb) }
            return (wa, wb)
        }
        let title = TextBlockView()
        let count = TextBlockView()
        let countBadge = BoxView()
        let accent: NSColor
        let stripe = CALayer()
        var pairs: [(LabelView, LabelView)] = []
        init(_ name: String, data: JSONValue?, accent: NSColor) {
            self.accent = accent
            let processes = data?["processCount"]?.intValue ?? 0
            super.init(frame: .zero)
            count.text = "\(processes) \(processes == 1 ? "process" : "processes")"
            count.font = DSFont.mono(10)
            count.lineHeight = 14
            count.color = Themed.color(\.mutedForeground, 0.7)
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
            // `flex justify-between gap-3`: both sides shrink in proportion to their max-content widths, down to their
            // longest word, and wrap (ResourceTelemetryDiagnostics.tsx:279-286).
            let t = Self.contentWidths(title), c = Self.contentWidths(count)
            let (titleWidth, countWidth) = Self.shrink(available: max(0, bounds.width - 40 - 12), t, (c.0 + 12, c.1 + 12))
            let titleHeight = title.height(forWidth: titleWidth), countHeight = count.height(forWidth: countWidth - 12) + 4
            let headerHeight = max(titleHeight, countHeight)
            title.frame = NSRect(x: 20, y: 16 + (headerHeight - titleHeight) / 2, width: titleWidth, height: titleHeight)
            countBadge.frame = NSRect(x: bounds.width - 20 - countWidth, y: 16 + (headerHeight - countHeight) / 2, width: countWidth, height: countHeight)
            count.frame = NSRect(x: 6, y: 2, width: countWidth - 12, height: countHeight - 4)
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
    /// `prefix` leads the status ("Native healthy"); the collector rows show the status alone (`label=""`).
    init(status: String, prefix: String? = "Native") {
        let danger = ["unavailable", "stopped", "failed"].contains(status)
        let warning = ["degraded", "starting"].contains(status)
        let color = danger ? Themed.color(\.destructive) : warning ? Themed.color(\.warningForeground) : Themed.color(\.successForeground)
        statusColor = color
        label = LabelView(((prefix.map { $0 + " " } ?? "") + status).uppercased(), font: DSFont.ui(10, weight: .semibold), color: color)
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

/// "Host & collection" (ResourceTelemetryDiagnostics.tsx:1224-1368): two columns split by `divide-x`, the host's
/// power state and the collector's health, read from the same `server.subscribeResourceTelemetry` snapshot.
final class SettingsHostCollectionView: DSView, SettingsGroupRow {
    private let hostHeader = ColumnHeader(.battery, "Host state")
    private let healthHeader = ColumnHeader(.gauge, "Collection health")
    private var hostRows: [NSView & Sized] = []
    private var healthRows: [NSView & Sized] = []
    private let divider = CALayer()

    init(snapshot: JSONValue?) {
        super.init(frame: .zero)
        divider.actions = ["position": NSNull(), "bounds": NSNull(), "backgroundColor": NSNull()]
        layer?.addSublayer(divider)
        addSubview(hostHeader)
        addSubview(healthHeader)
        let power = snapshot?["power"]
        func state(_ key: String) -> String { power?[key]?.stringValue ?? "unknown" }
        func boolean(_ key: String, _ yes: String, _ no: String) -> String {
            switch state(key) { case "true": yes; case "false": no; default: "Unknown" }
        }
        // `hasHostPowerSignal`: any power field the desktop host reported.
        let hasPower = snapshot != nil && ["onBattery", "lowPowerMode", "idle", "locked", "thermalState"].contains { state($0) != "unknown" }
        if hasPower {
            let idleSeconds = power?["idleSeconds"]?.doubleValue.map { " · \(Int($0.rounded()))s" } ?? ""
            let thermal = state("thermalState")
            hostRows = [
                DetailRow("Power source", boolean("onBattery", "Battery", "External power")),
                DetailRow("Low power mode", boolean("lowPowerMode", "Enabled", "Disabled")),
                DetailRow("Idle", boolean("idle", "Idle", "Active") + idleSeconds),
                DetailRow("Session", power?["suspended"]?.boolValue == true ? "Suspended" : boolean("locked", "Locked", "Unlocked")),
                DetailRow("Thermal", thermal, color: ["serious", "critical"].contains(thermal) ? Themed.color(\.destructive) : nil),
            ]
        } else {
            hostRows = [DisconnectedNote()]
        }
        if let health = snapshot?["health"] {
            func count(_ key: String) -> Int { health[key]?.intValue ?? 0 }
            let sidecar = health["sidecarVersion"]?.stringValue.map { version in
                version + (health["sidecarPid"]?.intValue.map { " · PID \($0)" } ?? "")
            } ?? "Unavailable"
            healthRows = [HealthSource("Native process monitor", health["native"])]
            if let desktop = health["desktop"] { healthRows.append(HealthSource("Electron main process", desktop)) }
            healthRows += [
                DetailRow("Collection time", Self.durationMicros(health["collectionDurationMicros"]?.doubleValue ?? 0)),
                DetailRow("Process scan", "\(count("retainedProcessCount"))/\(count("scannedProcessCount")) retained"),
                DetailRow("Inaccessible", "\(count("inaccessibleProcessCount"))",
                          color: count("inaccessibleProcessCount") > 0 ? Themed.color(\.warningForeground) : nil),
                DetailRow("Sidecar", sidecar),
                DetailRow("Restarts", "\(count("restartCount"))"),
            ]
        } else {
            let waiting = LabelRow("Waiting for collector health.")
            healthRows = [waiting]
        }
        (hostRows + healthRows).forEach(addSubview)
        restyle()
    }

    /// `formatDurationMicros` (ResourceTelemetryDiagnostics.tsx:80).
    static func durationMicros(_ value: Double) -> String {
        func trim(_ v: Double) -> String {
            var s = String(format: "%.2f", v)
            if s.hasSuffix(".00") { s.removeLast(3) }
            return s
        }
        if value < 1_000 { return "\(Int(value.rounded())) µs" }
        if value < 1_000_000 { return trim(value / 1_000) + " ms" }
        return trim(value / 1_000_000) + " s"
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); restyle() }
    private func restyle() { divider.backgroundColor = Themed.color(\.border, 0.6).cgColor(in: self) }

    /// `md:grid-cols-2` from 768pt of window width, stacked below it (the footprint's own breakpoint).
    private var twoColumns: Bool { (window?.frame.width ?? 1100) >= 768 }
    private func columnHeight(_ rows: [NSView & Sized], width: CGFloat) -> CGFloat {
        16 + 24 + 12 + rows.reduce(0) { $0 + $1.height(width - 40) } + 16
    }
    func height(forWidth width: CGFloat) -> CGFloat {
        twoColumns ? max(columnHeight(hostRows, width: width / 2), columnHeight(healthRows, width: width / 2))
            : columnHeight(hostRows, width: width) + 1 + columnHeight(healthRows, width: width)
    }

    override func layout() {
        super.layout()
        let w = twoColumns ? bounds.width / 2 : bounds.width
        func place(_ header: ColumnHeader, _ rows: [NSView & Sized], x: CGFloat, y: CGFloat) {
            header.frame = NSRect(x: x + 20, y: y + 16, width: w - 40, height: 24)
            var top = y + 16 + 24 + 12
            for row in rows {
                let h = row.height(w - 40)
                row.frame = NSRect(x: x + 20, y: top, width: w - 40, height: h)
                top += h
            }
        }
        place(hostHeader, hostRows, x: 0, y: 0)
        if twoColumns {
            place(healthHeader, healthRows, x: w, y: 0)
            divider.frame = NSRect(x: w, y: 0, width: 1, height: bounds.height)
        } else {
            let y = columnHeight(hostRows, width: w)
            divider.frame = NSRect(x: 0, y: y, width: bounds.width, height: 1)
            place(healthHeader, healthRows, x: 0, y: y + 1)
        }
    }

    @MainActor protocol Sized { func height(_ width: CGFloat) -> CGFloat }

    /// `mb-3 flex items-center gap-2 text-3xs font-semibold uppercase tracking-widest text-muted-foreground/70`
    /// after a `size-6 rounded-md bg-muted/60` icon box.
    private final class ColumnHeader: DSView {
        private let box = BoxView()
        private let icon: IconView
        private let label: LabelView
        init(_ glyph: IconName, _ title: String) {
            icon = IconView(name: glyph, size: 14, strokeColor: Themed.color(\.mutedForeground, 0.7))
            label = LabelView(title.uppercased(), font: DSFont.ui(10, weight: .semibold), color: Themed.color(\.mutedForeground, 0.7))
            label.tracking = 1
            super.init(frame: .zero)
            var style = BoxStyle()
            style.radius = 6
            style.fill = Themed.color(\.muted, 0.6)
            box.boxStyle = style
            addSubview(box)
            box.addSubview(icon)
            addSubview(label)
        }
        override func layout() {
            super.layout()
            box.frame = NSRect(x: 0, y: 0, width: 24, height: 24)
            icon.frame = NSRect(x: 5, y: 5, width: 14, height: 14)
            label.frame = NSRect(x: 32, y: 5, width: max(0, bounds.width - 32), height: 14)
        }
    }

    /// `DetailRow`: `py-2.5 border-t border-border/50 first:border-t-0`, the label in `text-2xs text-muted-foreground/75`
    /// and the value in `font-mono text-2xs tabular-nums text-foreground/85`, truncated at the right.
    private final class DetailRow: DSView, Sized {
        private let label: LabelView
        private let value: LabelView
        private let rule = CALayer()
        init(_ title: String, _ text: String, color: NSColor? = nil) {
            label = LabelView(title, font: DSFont.ui(11), color: Themed.color(\.mutedForeground, 0.75))
            value = LabelView(text, font: DSFont.mono(11), color: color ?? Themed.color(\.foreground, 0.85))
            value.alignment = .right
            super.init(frame: .zero)
            rule.actions = ["position": NSNull(), "bounds": NSNull(), "backgroundColor": NSNull()]
            layer?.addSublayer(rule)
            addSubview(label)
            addSubview(value)
        }
        func height(_ width: CGFloat) -> CGFloat { (superview as? SettingsHostCollectionView)?.isFirst(self) == true ? 36 : 37 }
        override func layout() {
            super.layout()
            let first = (superview as? SettingsHostCollectionView)?.isFirst(self) == true
            rule.isHidden = first
            rule.backgroundColor = Themed.color(\.border, 0.5).cgColor(in: self)
            rule.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1)
            let labelWidth = ceil(label.textWidth)
            let y: CGFloat = first ? 10 : 11
            label.frame = NSRect(x: 0, y: y, width: labelWidth, height: 16)
            value.frame = NSRect(x: labelWidth + 16, y: y, width: max(0, bounds.width - labelWidth - 16), height: 16)
        }
    }

    /// `HealthSource`: the source's name over its last error, with its status badge at the right (`py-3`).
    private final class HealthSource: DSView, Sized {
        private let title: LabelView
        private let detail = TextBlockView()
        private let badge: SettingsResourceStatusBadge
        private let rule = CALayer()
        init(_ name: String, _ health: JSONValue?) {
            title = LabelView(name, font: DSFont.ui(14, weight: .medium), color: Themed.color(\.foreground))
            title.lineHeight = 20
            let status = health?["status"]?.stringValue ?? "unknown"
            badge = SettingsResourceStatusBadge(status: status, prefix: nil)
            super.init(frame: .zero)
            detail.text = health?["lastError"]?.stringValue ?? "No reported errors"
            detail.font = DSFont.ui(11)
            detail.lineHeight = 17.875
            detail.color = Themed.color(\.mutedForeground, 0.65)
            rule.actions = ["position": NSNull(), "bounds": NSNull(), "backgroundColor": NSNull()]
            layer?.addSublayer(rule)
            [title, detail, badge].forEach(addSubview)
        }
        private func textWidth(_ width: CGFloat) -> CGFloat { max(0, width - badge.intrinsicContentSize.width - 16) }
        func height(_ width: CGFloat) -> CGFloat {
            ((superview as? SettingsHostCollectionView)?.isFirst(self) == true ? 0 : 1) + 12 + max(20 + 4 + detail.height(forWidth: textWidth(width)), 24) + 12
        }
        override func layout() {
            super.layout()
            let first = (superview as? SettingsHostCollectionView)?.isFirst(self) == true
            rule.isHidden = first
            rule.backgroundColor = Themed.color(\.border, 0.5).cgColor(in: self)
            rule.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1)
            let w = textWidth(bounds.width)
            let top: CGFloat = first ? 12 : 13
            title.frame = NSRect(x: 0, y: top, width: w, height: 20)
            detail.frame = NSRect(x: 0, y: top + 24, width: w, height: detail.height(forWidth: w))
            let size = badge.intrinsicContentSize
            badge.frame = NSRect(x: bounds.width - size.width, y: top, width: size.width, height: size.height)
        }
    }

    /// `rounded-xl border border-dashed border-border/70 bg-muted/20 px-4 py-5`: no desktop host reported power state.
    private final class DisconnectedNote: DSView, Sized {
        private let title = LabelView("Desktop host signals not connected", font: DSFont.ui(14, weight: .medium), color: Themed.color(\.foreground))
        private let body = TextBlockView()
        private let shape = CAShapeLayer()
        override init(frame: NSRect) {
            super.init(frame: frame)
            title.lineHeight = 20
            body.text = "Power, idle, lock, and thermal state are supplied by the desktop host. Process telemetry remains fully active in this browser session."
            body.font = DSFont.ui(11)
            body.lineHeight = 17.875
            body.color = Themed.color(\.mutedForeground, 0.7)
            shape.lineWidth = 1
            shape.lineDashPattern = [3, 3]
            shape.actions = ["path": NSNull(), "strokeColor": NSNull(), "fillColor": NSNull()]
            layer?.addSublayer(shape)
            addSubview(title)
            addSubview(body)
        }
        convenience init() { self.init(frame: .zero) }
        private func bodyWidth(_ width: CGFloat) -> CGFloat { min(384, max(0, width - 34)) }
        func height(_ width: CGFloat) -> CGFloat { 21 + 20 + 6 + body.height(forWidth: bodyWidth(width)) + 21 }
        override func layout() {
            super.layout()
            shape.path = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 11.5, cornerHeight: 11.5, transform: nil)
            shape.strokeColor = Themed.color(\.border, 0.7).cgColor(in: self)
            shape.fillColor = Themed.color(\.muted, 0.2).cgColor(in: self)
            title.frame = NSRect(x: 17, y: 21, width: max(0, bounds.width - 34), height: 20)
            let w = bodyWidth(bounds.width)
            body.frame = NSRect(x: 17, y: 47, width: w, height: body.height(forWidth: w))
        }
    }

    /// "Waiting for collector health." (`py-4 text-xs text-muted-foreground`).
    private final class LabelRow: DSView, Sized {
        private let label: LabelView
        init(_ text: String) {
            label = LabelView(text, font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
            super.init(frame: .zero)
            addSubview(label)
        }
        func height(_ width: CGFloat) -> CGFloat { 48 }
        override func layout() { super.layout(); label.frame = NSRect(x: 0, y: 16, width: bounds.width, height: 16) }
    }

    fileprivate func isFirst(_ row: NSView) -> Bool { hostRows.first === row || healthRows.first === row }
}
