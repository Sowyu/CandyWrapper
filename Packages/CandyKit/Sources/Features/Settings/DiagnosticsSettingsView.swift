import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// The number formats of DiagnosticsSettings.tsx.
public enum DiagnosticsFormat {
    public static func count(_ value: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        return f.string(from: NSNumber(value: value)) ?? "\(Int(value))"
    }

    /// `formatDuration`: ms under a second, else seconds with 2 (or 1 from 10 s) decimals.
    public static func duration(_ ms: Double) -> String {
        ms < 1000 ? "\(Int(ms.rounded())) ms" : String(format: ms >= 10_000 ? "%.1f s" : "%.2f s", ms / 1000)
    }

    /// `formatBytes`.
    public static func bytes(_ value: Double) -> String {
        if value < 1024 { return "\(Int(value)) B" }
        let units = ["KB", "MB", "GB"]
        var next = value, i = -1
        repeat { next /= 1024; i += 1 } while next >= 1024 && i < units.count - 1
        return String(format: next >= 10 ? "%.1f %@" : "%.2f %@", next, units[i])
    }

    /// `formatCpuTime`.
    public static func cpuTime(_ seconds: Double) -> String {
        if seconds < 60 { return String(format: seconds >= 10 ? "%.1fs" : "%.2fs", seconds) }
        let minutes = seconds / 60
        if minutes < 60 { return String(format: minutes >= 10 ? "%.1fm" : "%.2fm", minutes) }
        return String(format: "%.2fh", minutes / 60)
    }

    /// `formatProcessName`: the command's first token without quotes, last path segment.
    public static func processName(_ command: String) -> String {
        guard let first = command.trimmingCharacters(in: .whitespaces).split(whereSeparator: \.isWhitespace).first else { return command }
        let token = String(first).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        return token.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? token
    }

    /// `formatProcessType`.
    public static func processType(command: String, depth: Int) -> String {
        if depth > 0 { return "Subprocess" }
        return command.range(of: "\\b(codex|claude|opencode|cursor)\\b", options: [.regularExpression, .caseInsensitive]) != nil ? "Agent" : "Process"
    }

    /// `shortenTraceId`.
    public static func traceId(_ id: String) -> String { id.count <= 32 ? id : "\(id.prefix(18))...\(id.suffix(10))" }

    /// `formatRelative` for an ISO time (or `Schema.Option`), "No trace records" when absent.
    public static func relative(_ value: JSONValue?) -> String {
        guard let iso = (optionValue(value) ?? value)?.stringValue else { return "No trace records" }
        return TimestampFormat.formatRelativeTimeLabel(iso, nowMs: TimestampFormat.nowMs())
    }

    /// `ProcessDiagnosticsTable`'s visible rows: a collapsed process hides its deeper rows.
    public static func visibleProcesses(_ processes: [JSONValue], collapsed: Set<Int>) -> [JSONValue] {
        var out: [JSONValue] = []
        var hiddenDepth: Int?
        for p in processes {
            let depth = p["depth"]?.intValue ?? 0
            if let d = hiddenDepth {
                if depth > d { continue }
                hiddenDepth = nil
            }
            out.append(p)
            if let pid = p["pid"]?.intValue, collapsed.contains(pid) { hiddenDepth = depth }
        }
        return out
    }
}

/// Settings > Diagnostics (DiagnosticsSettings.tsx), reached from General > Diagnostics: live processes, resource
/// history and trace diagnostics of one environment.
public final class DiagnosticsSettingsView: ScopedSettingsPage {
    private var telemetry: JSONValue?
    private var telemetryHistory: JSONValue?
    private var telemetryTask: Task<Void, Never>?
    private var loads: [String: Task<Void, Never>] = [:]
    private var revisions: [String: Int] = [:]
    private var processData: JSONValue?
    private var traceData: JSONValue?
    private var resourceData: JSONValue?
    private var errors: [String: String] = [:]
    private var pending: Set<String> = []
    private var collapsed: Set<Int> = []
    private var windowIndex = 1
    private var signaling: Int?
    private var loadedFor: String?
    private weak var telemetrySectionView: SettingsSectionView?
    /// The OTLP export form, kept across rebuilds so drafts survive (one per environment).
    private var exportForm: TelemetryExportView?
    static let windows: [(label: String, windowMs: Double, bucketMs: Double)] = [("5m", 300_000, 30_000), ("15m", 900_000, 60_000),
                                                                                  ("30m", 1_800_000, 120_000), ("1h", 3_600_000, 300_000)]

    public init(context: SettingsPageContext) {
        super.init(context: context)
        sentence.singleEnvironment = true
        gap = 40
        binder.add { [weak self] in self?.rebuild() }
    }

    /// The environment it inspects: the chosen one, else the primary, else the first connected.
    var environment: SettingsScopeEnvironment? {
        let scope = context.scope
        if let machine = scope.selection.machine { return scope.environments.first { $0.id == machine && $0.connected } }
        return scope.connected.first { $0.id == scope.primaryId } ?? scope.connected.first
    }

    public override func didShow() { if loadedFor != nil { loadAll() }; watchTelemetry() }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            telemetryTask?.cancel(); telemetryTask = nil
            for task in loads.values { task.cancel() }
            loads.removeAll(); pending.removeAll()
            telemetry = nil; telemetryHistory = nil
            processData = nil; traceData = nil; resourceData = nil
            body = []; telemetrySectionView = nil; exportForm = nil
        } else { watchTelemetry(); loadAll() }
    }

    private func watchTelemetry() {
        guard window != nil, telemetryTask == nil, let env = environment?.id else { return }
        telemetryTask = context.subscribeResourceTelemetry?(env) { [weak self] value in
            guard let self, self.window != nil, self.environment?.id == env else { return }
            self.telemetry = value
            if let section = self.telemetrySectionView {
                let updated = self.telemetrySection()
                section.group.rows = updated.group.rows
                section.headerAction = updated.headerAction
            }
            self.onHeightChange?()
        }
    }

    public override func refresh() {
        if environment?.id != loadedFor {
            telemetryTask?.cancel(); telemetryTask = nil
            for task in loads.values { task.cancel() }
            loads.removeAll(); pending.removeAll()
            loadedFor = environment?.id; processData = nil; traceData = nil; resourceData = nil
            telemetry = nil; telemetryHistory = nil
            loadAll(); watchTelemetry()
        }
        super.refresh()
    }

    private func loadAll() { load("process"); load("trace"); load("resource"); load("telemetry") }

    private func load(_ kind: String) {
        guard let env = environment?.id, let request = context.request else { return }
        loads[kind]?.cancel()
        let revision = (revisions[kind] ?? 0) + 1
        revisions[kind] = revision
        pending.insert(kind)
        rebuild()
        let w = Self.windows[windowIndex]
        let (method, payload): (String, JSONValue) = switch kind {
        case "process": ("server.getProcessDiagnostics", .object([:]))
        case "trace": ("server.getTraceDiagnostics", .object([:]))
        case "telemetry": ("server.getResourceTelemetryHistory", .object(["windowMs": .number(w.windowMs), "bucketMs": .number([15_000.0, 30_000, 60_000, 120_000][windowIndex])]))
        default: ("server.getProcessResourceHistory", .object(["windowMs": .number(w.windowMs), "bucketMs": .number(w.bucketMs)]))
        }
        loads[kind] = Task { [weak self] in
            do {
                let result = try await request(env, method, payload)
                guard let self, !Task.isCancelled, self.environment?.id == env, self.revisions[kind] == revision else { return }
                switch kind {
                case "process": self.processData = result
                case "trace": self.traceData = result
                case "telemetry": self.telemetryHistory = result
                default: self.resourceData = result
                }
                self.errors[kind] = nil
            } catch {
                guard !Task.isCancelled, self?.revisions[kind] == revision else { return }
                self?.errors[kind] = "\(error)"
            }
            self?.pending.remove(kind)
            self?.rebuild()
            self?.onHeightChange?()
        }
    }

    private func header(_ kind: String, checkedAt: JSONValue?, label: String, extra: [NSView] = []) -> NSView {
        let checked = LabelView(checkedAt?.stringValue.map { "Checked \(TimestampFormat.formatRelativeTimeLabel($0, nowMs: TimestampFormat.nowMs()))" } ?? "Checking",
                                font: DSFont.ui(11), color: Themed.color(\.mutedForeground, checkedAt == nil ? 0.5 : 0.6))
        checked.lineHeight = 14
        checked.frame.size = NSSize(width: ceil(checked.textWidth) + 1, height: 14)
        let refresh = ButtonView(nil, icon: .refreshCw, variant: .ghostMuted, size: .iconXs)
        refresh.iconSize = 14
        refresh.isEnabled = !pending.contains(kind)
        refresh.setAccessibilityLabel(label)
        _ = TooltipController.attach(to: refresh, text: label)
        refresh.action = { [weak self] in self?.load(kind) }
        return SettingsControlGroup(extra + [checked, refresh], gap: 6)
    }

    private func rebuild() {
        sentence.impliedMachine = environment?.id
        sentence.refresh()
        guard let env = environment else {
            let note = SettingsNoticeView("Connect an environment to see diagnostics.")
            body = [note]
            return
        }
        _ = env
        // The rebuild re-adds the export form, which takes its field out of the window. Put the focus back after,
        // so a load finishing mid-typing doesn't send the next keystrokes elsewhere. The editor keeps its selection.
        let refocus = exportForm.flatMap { form in (window?.firstResponder as? NSView).flatMap { $0.isDescendant(of: form) ? $0 : nil } }
        defer { if let refocus, let window, refocus.window === window, window.firstResponder !== refocus { window.makeFirstResponder(refocus) } }
        let p = processData, t = traceData, r = resourceData
        func n(_ v: JSONValue?, _ key: String) -> Double? { v?[key]?.doubleValue }

        // Live Processes.
        let processes = DiagnosticsFormat.visibleProcesses(p?["processes"]?.arrayValue ?? [], collapsed: collapsed)
        let live = SettingsSectionView(title: "Live Processes", rows: [
            StatsGridView([("Child Processes", n(p, "processCount").map(DiagnosticsFormat.count) ?? "...", nil, .normal),
                           ("CPU", n(p, "totalCpuPercent").map { String(format: "%.1f%%", $0) } ?? "...",
                            "Total CPU across live child processes of the current server process. The desktop shell and other parent processes are not included.", .normal),
                           ("Memory", n(p, "totalRssBytes").map(DiagnosticsFormat.bytes) ?? "...",
                            "Total resident memory across live child processes of the current server process. The desktop shell and other parent processes are not included.", .normal),
                           ("Server PID", n(p, "serverPid").map { "\(Int($0))" } ?? "...", nil, .normal)]),
        ] + errorRows([optionValue(p?["error"])?["message"]?.stringValue, errors["process"]]) + [
            DiagnosticsTableView(headers: ["Name", "CPU", "Memory", "Command", "PID", "Type", "Kill"],
                                 widths: [0.24, 0.08, 0.10, 0.33, 0.08, 0.11, 0.06], rightAligned: [1, 2, 4, 6],
                                 rows: processes.map { proc in processRow(proc) },
                                 empty: pending.contains("process") && p == nil ? "Loading live processes..." : "No live descendant processes found."),
        ])
        live.headerAction = header("process", checkedAt: p?["readAt"], label: "Refresh process diagnostics")

        // Resource History.
        let windowSelect = SegmentedWindows(labels: Self.windows.map(\.label), selected: windowIndex)
        windowSelect.onSelect = { [weak self] i in self?.windowIndex = i; self?.load("resource"); self?.load("telemetry") }
        let resources = SettingsSectionView(title: "Resource History", rows: [
            StatsGridView([("CPU Time", n(r, "totalCpuSecondsApprox").map(DiagnosticsFormat.cpuTime) ?? "...",
                            "Approximate active CPU time for the T3 server root process and its descendants during the selected window. It grows only while sampled processes use CPU and older samples leave as the window moves.", .normal),
                           ("Samples", n(r, "retainedSampleCount").map(DiagnosticsFormat.count) ?? "...",
                            "In-memory process samples retained by the server. This resets when the server restarts.", .normal),
                           ("Interval", n(r, "sampleIntervalMs").map(DiagnosticsFormat.duration) ?? "...", nil, .normal),
                           ("Processes", (r?["topProcesses"]?.arrayValue?.count).map { DiagnosticsFormat.count(Double($0)) } ?? "...", nil, .normal)]),
        ] + errorRows([optionValue(r?["error"])?["message"]?.stringValue, errors["resource"]]) + [
            CpuBarsView(buckets: r?["buckets"]?.arrayValue ?? []),
            DiagnosticsTableView(headers: ["Process", "CPU Time", "Current", "Average", "Peak", "Max Mem", "Command", "PID"],
                                 widths: [0.24, 0.10, 0.10, 0.10, 0.10, 0.10, 0.16, 0.10], rightAligned: [1, 2, 3, 4, 5, 7],
                                 rows: (r?["topProcesses"]?.arrayValue ?? []).map { s in
                                     [.init(DiagnosticsFormat.processName(s["command"]?.stringValue ?? ""), strong: true,
                                            dot: s["isServerRoot"]?.boolValue == true ? Themed.color(\.warning, 0.9) : Themed.color(\.success, 0.8),
                                            indent: CGFloat(min(s["depth"]?.intValue ?? 0, 6)) * 10),
                                      .init(DiagnosticsFormat.cpuTime(s["cpuSecondsApprox"]?.doubleValue ?? 0), mono: true),
                                      .init(String(format: "%.1f%%", s["currentCpuPercent"]?.doubleValue ?? 0), mono: true),
                                      .init(String(format: "%.1f%%", s["avgCpuPercent"]?.doubleValue ?? 0), mono: true),
                                      .init(String(format: "%.1f%%", s["maxCpuPercent"]?.doubleValue ?? 0), mono: true),
                                      .init(DiagnosticsFormat.bytes(s["maxRssBytes"]?.doubleValue ?? 0), mono: true),
                                      .init(s["command"]?.stringValue ?? "", muted: true),
                                      .init("\(s["pid"]?.intValue ?? 0)", mono: true, muted: true)]
                                 },
                                 empty: pending.contains("resource") && r == nil ? "Collecting process resource samples..." : "No process resource samples found for this window."),
        ])
        resources.headerAction = header("resource", checkedAt: r?["readAt"], label: "Refresh resource history", extra: [windowSelect])

        // Trace Diagnostics.
        let partial = optionValue(t?["partialFailure"])?.boolValue ?? false
        let traceError = optionValue(t?["error"])?["message"]?.stringValue.map { partial ? "Some trace files could not be read, so diagnostics may be incomplete. \($0)" : $0 }
        let failures = n(t, "failureCount") ?? 0, slow = n(t, "slowSpanCount") ?? 0, parse = n(t, "parseErrorCount") ?? 0
        let trace = SettingsSectionView(title: "Trace Diagnostics", rows: [
            StatsGridView([("Spans", n(t, "recordCount").map(DiagnosticsFormat.count) ?? "...", nil, .normal),
                           ("Failures", t == nil ? "..." : DiagnosticsFormat.count(failures), nil, failures > 0 ? .danger : .normal),
                           ("Slow Spans", t == nil ? "..." : DiagnosticsFormat.count(slow),
                            n(t, "slowSpanThresholdMs").map { "Spans with a duration of \(DiagnosticsFormat.duration($0)) or longer." }
                                ?? "Spans at or above the configured slow-span threshold.", slow > 0 ? .warning : .normal),
                           ("Parse Errors", t == nil ? "..." : DiagnosticsFormat.count(parse), nil, parse > 0 ? .warning : .normal)]),
        ] + errorRows([traceError, errors["trace"]]))
        let openLogs = ButtonView(nil, icon: .folderOpen, variant: .ghostMuted, size: .iconXs)
        openLogs.setAccessibilityLabel("Open logs folder")
        let config = context.configs[env.id]
        let editor = OpenInEditors.preferred(available: config?.availableEditors ?? [], last: UserDefaults.standard.string(forKey: OpenInEditors.lastEditorKey))
        openLogs.isEnabled = config?.logsDirectoryPath != nil && editor != nil
        openLogs.action = { [weak self] in
            guard let path = config?.logsDirectoryPath, let editor, let request = self?.context.request else { return }
            Task { [weak self] in
                do { _ = try await request(env.id, "shell.openInEditor", OpenInEditors.launchInput(cwd: path, editor: editor)) }
                catch { self?.context.toast?("Unable to open logs folder", "\(error)", .error) }
            }
        }
        trace.headerAction = header("trace", checkedAt: t?["readAt"], label: "Refresh trace diagnostics", extra: [openLogs])
        let loading = pending.contains("trace") && t == nil
        func table(_ title: String, _ headers: [String], _ widths: [CGFloat], _ key: String, empty: String, loadingText: String,
                   _ cells: (JSONValue) -> [DiagnosticsTableView.Cell]) -> SettingsSectionView {
            let items = t?[key]?.arrayValue ?? []
            if items.isEmpty { return SettingsSectionView(title: title, rows: [SettingsGroupNote(loading ? loadingText : empty, size: 12)]) }
            return SettingsSectionView(title: title, rows: [DiagnosticsTableView(headers: headers, widths: widths, rightAligned: [], rows: items.map(cells), empty: "")])
        }
        let latest = table("Latest Failures", ["Span", "Cause", "Duration", "Ended"], [0.3, 0.45, 0.12, 0.13], "latestFailures",
                           empty: "No failed spans found.", loadingText: "Loading failures...") { f in
            [.init(f["name"]?.stringValue ?? "", strong: true), .init(f["cause"]?.stringValue ?? "", muted: true, lines: 3),
             .init(DiagnosticsFormat.duration(f["durationMs"]?.doubleValue ?? 0), mono: true), .init(DiagnosticsFormat.relative(f["endedAt"]), mono: true, muted: true)]
        }
        let common = table("Most Common Failures", ["Span", "Count", "Cause", "Last Seen"], [0.3, 0.1, 0.45, 0.15], "commonFailures",
                           empty: "No repeated failures found.", loadingText: "Loading failure groups...") { f in
            [.init(f["name"]?.stringValue ?? "", strong: true), .init(DiagnosticsFormat.count(f["count"]?.doubleValue ?? 0), mono: true),
             .init(f["cause"]?.stringValue ?? "", muted: true, lines: 3), .init(DiagnosticsFormat.relative(f["lastSeenAt"]), mono: true, muted: true)]
        }
        let slowest = table("Slowest Spans", ["Span", "Duration", "Ended", "Trace"], [0.44, 0.14, 0.12, 0.30], "slowestSpans",
                            empty: "No spans found.", loadingText: "Loading slow spans...") { s in
            [.init(s["name"]?.stringValue ?? "", strong: true), .init(DiagnosticsFormat.duration(s["durationMs"]?.doubleValue ?? 0), mono: true),
             .init(DiagnosticsFormat.relative(s["endedAt"]), mono: true, muted: true), .init(DiagnosticsFormat.traceId(s["traceId"]?.stringValue ?? ""), mono: true, muted: true, small: true, copyValue: s["traceId"]?.stringValue)]
        }
        let logs = table("Span Logs", ["Time", "Level", "Span", "Message", "Trace"], [0.11, 0.09, 0.24, 0.26, 0.30], "latestWarningAndErrorLogs",
                         empty: "No warnings or errors found.", loadingText: "Loading recent logs...") { e in
            [.init(DiagnosticsFormat.relative(e["seenAt"]), mono: true, muted: true), .init((e["level"]?.stringValue ?? "").uppercased(), mono: true, small: true),
             .init(e["spanName"]?.stringValue ?? "", strong: true), .init(e["message"]?.stringValue ?? "", muted: true, lines: 2),
             .init(DiagnosticsFormat.traceId(e["traceId"]?.stringValue ?? ""), mono: true, muted: true, small: true, copyValue: e["traceId"]?.stringValue)]
        }
        let top = table("Top Span Names", ["Span", "Count", "Failures", "Average", "Max"], [0.48, 0.13, 0.13, 0.13, 0.13], "topSpansByCount",
                        empty: "No spans found.", loadingText: "Loading span names...") { s in
            [.init(s["name"]?.stringValue ?? "", strong: true), .init(DiagnosticsFormat.count(s["count"]?.doubleValue ?? 0), mono: true),
             .init(DiagnosticsFormat.count(s["failureCount"]?.doubleValue ?? 0), mono: true),
             .init(DiagnosticsFormat.duration(s["averageDurationMs"]?.doubleValue ?? 0), mono: true),
             .init(DiagnosticsFormat.duration(s["maxDurationMs"]?.doubleValue ?? 0), mono: true)]
        }
        let monitor = telemetrySection()
        telemetrySectionView = monitor
        body = [monitor, live, resources, trace, latest, common, slowest, logs, top] + (exportSection(env).map { [$0] } ?? [])
    }

    /// `TelemetryExportSettings` (TelemetryExportSettings.tsx:44-56, 2994) under the tables, on every server as in
    /// 2994's web app. Servers without `otlpEndpointCheck` get the editor without Test.
    private func exportSection(_ env: SettingsScopeEnvironment) -> SettingsSectionView? {
        let section: SettingsSectionView
        if case .environment = context.scope.kind {
            if exportForm?.environmentId != env.id { exportForm = TelemetryExportView(context: context, environmentId: env.id) }
            exportForm?.update(environment: env, observability: context.configs[env.id]?.observability)
            section = SettingsSectionView(title: "OpenTelemetry export", rows: [exportForm!])
        } else {
            exportForm = nil
            let choices = context.scope.environments.filter(\.connected).map { e in
                (e.label, { [weak self] in self?.context.selectScope?(SettingsScopeSelection(machine: e.id, project: nil)) } as @MainActor () -> Void)
            }
            section = SettingsSectionView(title: "OpenTelemetry export", rows: [
                SettingsScopeNoticeView("Choose one environment to configure its telemetry exports.", choices: choices),
            ], variant: .plain)
        }
        anchors["telemetry-export"] = section
        return section
    }

    // ponytail: backend summary and history only; add the remaining telemetry groups with their detail views.
    private func telemetrySection() -> SettingsSectionView {
        let snapshot = telemetry
        let group = snapshot?["groups"]?["backend"]
        let status = snapshot?["health"]?["native"]?["status"]?.stringValue ?? "Checking"
        let stats = StatsGridView([
            ("CPU", group?["currentCpuPercent"]?.doubleValue.map { String(format: "%.1f%%", $0) } ?? "...", nil, .normal),
            ("Memory", group?["currentRssBytes"]?.doubleValue.map(DiagnosticsFormat.bytes) ?? "...", nil, .normal),
            ("Processes", group?["processCount"]?.doubleValue.map(DiagnosticsFormat.count) ?? "...", nil, .normal),
            ("Native", status, nil, .normal),
        ])
        let chart = SettingsResourceHistoryChartView(buckets: telemetryHistory?["buckets"]?.arrayValue ?? [])
        let section = SettingsSectionView(title: "Resource Monitor", rows: [stats] + errorRows([errors["telemetry"]]) + [chart])
        let retry = ButtonView("Retry", variant: .outline, size: .xs)
        retry.isHidden = !["degraded", "unavailable", "stopped"].contains(status)
        retry.action = { [weak self] in
            guard let self, let env = self.environment?.id, let request = self.context.request else { return }
            Task { [weak self] in
                do { _ = try await request(env, "server.retryResourceTelemetry", .object([:])); self?.load("telemetry") }
                catch { self?.context.toast?("Could not retry resource monitor", "\(error)", .error) }
            }
        }
        section.headerAction = header("telemetry", checkedAt: telemetryHistory?["readAt"], label: "Refresh resource history", extra: [retry])
        return section
    }

    private func errorRows(_ messages: [String?]) -> [any SettingsGroupRow] {
        let m = messages.compactMap { $0 }
        return m.isEmpty ? [] : [SettingsGroupNote(m.joined(separator: "\n"), color: Themed.color(\.destructive), size: 12)]
    }

    private func processRow(_ proc: JSONValue) -> [DiagnosticsTableView.Cell] {
        let pid = proc["pid"]?.intValue ?? 0
        let command = proc["command"]?.stringValue ?? ""
        let hasChildren = !(proc["childPids"]?.arrayValue ?? []).isEmpty
        var name = DiagnosticsTableView.Cell(DiagnosticsFormat.processName(command), strong: true, dot: Themed.color(\.success, 0.8),
                                             indent: CGFloat(min(proc["depth"]?.intValue ?? 0, 6)) * 10)
        if hasChildren {
            let toggle: @MainActor () -> Void = { [weak self] in
                guard let self else { return }
                if self.collapsed.remove(pid) == nil { self.collapsed.insert(pid) }
                self.rebuild()
                self.onHeightChange?()
            }
            name.toggle = (expanded: !collapsed.contains(pid), action: toggle)
        }
        var kill = DiagnosticsTableView.Cell("")
        if signaling != pid {
            let send: @MainActor (String) -> Void = { [weak self] signal in self?.signal(proc, signal) }
            kill.signals = send
        }
        return [name, .init(String(format: "%.1f%%", proc["cpuPercent"]?.doubleValue ?? 0), mono: true),
                .init(DiagnosticsFormat.bytes(proc["rssBytes"]?.doubleValue ?? 0), mono: true), .init(command, muted: true),
                .init("\(pid)", mono: true, muted: true), .init(DiagnosticsFormat.processType(command: command, depth: proc["depth"]?.intValue ?? 0), muted: true),
                kill]
    }

    /// `signalProcess`: SIGKILL asks first; the process must still be the same one (`startTimeMs`).
    private func signal(_ proc: JSONValue, _ signal: String) {
        guard let env = environment?.id, let request = context.request, signaling == nil, let pid = proc["pid"]?.intValue else { return }
        let run: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            self.signaling = pid
            Task { [weak self] in
                do {
                    let result = try await request(env, "server.signalProcess",
                                                   .object(["pid": .number(Double(pid)), "startTimeMs": proc["startTimeMs"] ?? .number(0), "signal": .string(signal)]))
                    if result["signaled"]?.boolValue != true {
                        let message = optionValue(result["message"])?.stringValue
                        if message?.contains("not a live descendant") == true {
                            self?.context.toast?("Process already exited", "The process is not a child of the T3 Server. It might already have exited.", .info)
                        } else {
                            self?.context.toast?("Could not send \(signal)", message ?? "Failed to send \(signal).", .error)
                        }
                    }
                } catch {
                    self?.context.toast?("Could not send \(signal)", "\(error)", .error)
                }
                self?.signaling = nil
                self?.load("process")
            }
        }
        if signal == "SIGKILL" { context.confirm?("Send SIGKILL to process \(pid)? This cannot be handled by the process.", true, run) } else { run() }
    }
}

/// `StatsGrid` of four `StatBlock`s with the dividers between them.
final class StatsGridView: DSView, SettingsGroupRow {
    enum Tone { case normal, warning, danger }
    private var labels: [LabelView] = []
    private var values: [LabelView] = []
    private var infos: [ButtonView?] = []
    private let dividers = (0..<3).map { _ in CALayer() }

    init(_ blocks: [(String, String, String?, Tone)]) {
        super.init(frame: .zero)
        for (label, value, tip, tone) in blocks {
            let l = LabelView(label.uppercased(), font: DSFont.ui(11, weight: .medium), color: Themed.color(\.mutedForeground, 0.7))
            l.lineHeight = 14
            l.tracking = 1.1
            let v = LabelView(value, font: DSFont.mono(18, weight: .semibold),
                              color: tone == .danger ? Themed.color(\.destructive) : tone == .warning ? Themed.color(\.warningForeground) : Themed.color(\.foreground))
            v.lineHeight = 28
            var info: ButtonView?
            if let tip {
                let b = ButtonView(nil, icon: .info, variant: .ghostMuted, size: .iconMicro)
                b.iconSize = 12
                b.setAccessibilityLabel("\(label) details")
                _ = TooltipController.attach(to: b, text: tip)
                addSubview(b)
                info = b
            }
            labels.append(l); values.append(v); infos.append(info)
            addSubview(l); addSubview(v)
        }
        for d in dividers { layer?.addSublayer(d) }
    }

    func height(forWidth width: CGFloat) -> CGFloat { 12 + 14 + 4 + 28 + 12 }

    override func layout() {
        super.layout()
        let w = bounds.width / 4
        for i in 0..<labels.count {
            let x = CGFloat(i) * w + 20
            let lw = min(ceil(labels[i].textWidth) + 1, w - 40)
            labels[i].frame = NSRect(x: x, y: 12, width: lw, height: 14)
            infos[i]?.frame = NSRect(x: x + lw + 4, y: 11, width: 16, height: 16)
            values[i].frame = NSRect(x: x, y: 30, width: w - 40, height: 28)
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (i, d) in dividers.enumerated() { d.frame = CGRect(x: w * CGFloat(i + 1), y: 0, width: 1, height: bounds.height) }
        CATransaction.commit()
    }

    override func updateLayer() {
        super.updateLayer()
        for d in dividers { d.backgroundColor = Themed.color(\.border, 0.6).cgColor(in: self) }
    }
}

/// A diagnostics table (`text-xs`, uppercase `text-2xs` headers, `divide-y` rows) with fixed column fractions.
final class DiagnosticsTableView: DSView, SettingsGroupRow {
    struct Cell {
        var text: String
        var mono = false, muted = false, strong = false, small = false
        var lines = 1
        var copyValue: String?
        var dot: NSColor?
        var indent: CGFloat = 0
        var toggle: (expanded: Bool, action: @MainActor () -> Void)?
        var signals: (@MainActor (String) -> Void)?
        init(_ text: String, mono: Bool = false, muted: Bool = false, strong: Bool = false, small: Bool = false, lines: Int = 1, dot: NSColor? = nil,
             indent: CGFloat = 0, copyValue: String? = nil) {
            self.copyValue = copyValue
            self.text = text; self.mono = mono; self.muted = muted; self.strong = strong; self.small = small; self.lines = lines; self.dot = dot
            self.indent = indent
        }
    }

    private let widths: [CGFloat]
    private let right: Set<Int>
    private var headerLabels: [LabelView] = []
    private var cells: [[NSView]] = []
    private var rowHeights: [CGFloat] = []
    private var lines: [CALayer] = []
    private let empty = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))

    init(headers: [String], widths: [CGFloat], rightAligned: Set<Int>, rows: [[Cell]], empty text: String) {
        self.widths = widths
        right = rightAligned
        super.init(frame: .zero)
        for h in headers {
            let l = LabelView(h.uppercased(), font: DSFont.ui(11, weight: .semibold), color: Themed.color(\.mutedForeground, 0.7))
            l.lineHeight = 14
            l.tracking = 1.1
            headerLabels.append(l)
            addSubview(l)
        }
        empty.text = text
        empty.lineHeight = 16
        empty.isHidden = !rows.isEmpty
        addSubview(empty)
        for row in rows {
            var views: [NSView] = []
            for c in row {
                if let signals = c.signals {
                    let int = ButtonView("INT", variant: .ghostMuted, size: .micro)
                    int.setAccessibilityLabel("Send SIGINT")
                    _ = TooltipController.attach(to: int, text: "Send SIGINT")
                    int.action = { signals("SIGINT") }
                    let kill = ButtonView("KILL", variant: .ghostDestructive, size: .micro)
                    kill.setAccessibilityLabel("Send SIGKILL")
                    _ = TooltipController.attach(to: kill, text: "Send SIGKILL")
                    kill.action = { signals("SIGKILL") }
                    let g = SettingsControlGroup([int, kill], gap: 6)
                    views.append(g)
                    continue
                }
                if let value = c.copyValue {
                    let copy = ButtonView(c.text, icon: .copy, variant: .ghostMuted, size: .micro)
                    copy.setAccessibilityLabel("Copy trace ID \(value)")
                    _ = TooltipController.attach(to: copy, text: value)
                    copy.action = { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }
                    views.append(copy)
                    continue
                }
                let t = TextBlockView()
                t.text = c.text
                t.font = c.mono ? DSFont.mono(c.small ? 11 : 12) : DSFont.ui(c.small ? 11 : 12, weight: c.strong ? .medium : .regular)
                t.lineHeight = 16
                t.maxLines = c.lines
                t.color = c.strong ? Themed.color(\.foreground) : c.muted ? Themed.color(\.mutedForeground) : Themed.color(\.foreground)
                if c.lines > 1 {
                    let expandable = SettingsDiagnosticsExpandableCell(text: t, lines: c.lines)
                    expandable.onExpand = { [weak self] in
                        var parent: NSView? = self
                        while let view = parent {
                            view.needsLayout = true
                            view.invalidateIntrinsicContentSize()
                            if let page = view as? SettingsPageBase { page.onHeightChange?() }
                            parent = view.superview
                        }
                    }
                    views.append(expandable)
                } else if c.dot != nil || c.toggle != nil {
                    let holder = CellWithMark(text: t, dot: c.dot, indent: c.indent, toggle: c.toggle)
                    views.append(holder)
                } else {
                    views.append(t)
                }
            }
            views.forEach(addSubview)
            cells.append(views)
            let l = CALayer()
            layer?.addSublayer(l)
            lines.append(l)
        }
        let h = CALayer()
        layer?.addSublayer(h)
        lines.append(h)
    }

    private func columnFrames(_ width: CGFloat) -> [(x: CGFloat, w: CGFloat)] {
        let inner = width - 40
        var x: CGFloat = 20
        return widths.map { f in defer { x += f * inner }; return (x + 6, f * inner - 12) }
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        let cols = columnFrames(width)
        var h: CGFloat = 1 + 34
        if cells.isEmpty { return h + 40 }
        for row in cells {
            var rh: CGFloat = 16
            for (i, v) in row.enumerated() where i < cols.count { if let t = v as? TextBlockView { rh = max(rh, t.height(forWidth: cols[i].w)) } else if let t = v as? SettingsDiagnosticsExpandableCell { rh = max(rh, t.height(forWidth: cols[i].w)) } }
            h += rh + 20 + 1
        }
        return h
    }

    override func layout() {
        super.layout()
        let cols = columnFrames(bounds.width)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        lines.last?.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 1)
        for (i, l) in headerLabels.enumerated() where i < cols.count {
            let w = min(ceil(l.textWidth) + 1, cols[i].w)
            l.frame = NSRect(x: right.contains(i) ? cols[i].x + cols[i].w - w : cols[i].x, y: 1 + 10, width: w, height: 14)
        }
        var y: CGFloat = 1 + 34
        empty.frame = NSRect(x: 20, y: y + 12, width: bounds.width - 40, height: 16)
        for (r, row) in cells.enumerated() {
            lines[r].frame = CGRect(x: 0, y: y, width: bounds.width, height: 1)
            y += 1
            var rh: CGFloat = 16
            for (i, v) in row.enumerated() where i < cols.count { if let t = v as? TextBlockView { rh = max(rh, t.height(forWidth: cols[i].w)) } else if let t = v as? SettingsDiagnosticsExpandableCell { rh = max(rh, t.height(forWidth: cols[i].w)) } }
            for (i, v) in row.enumerated() where i < cols.count {
                if let t = v as? TextBlockView {
                    let h = t.height(forWidth: cols[i].w)
                    t.alignment = right.contains(i) ? .right : .left
                    t.frame = NSRect(x: cols[i].x, y: y + 10, width: cols[i].w, height: h)
                } else if let t = v as? SettingsDiagnosticsExpandableCell {
                    t.frame = NSRect(x: cols[i].x, y: y + 10, width: cols[i].w, height: t.height(forWidth: cols[i].w))
                } else {
                    let s = v.intrinsicContentSize
                    let w = s.width == NSView.noIntrinsicMetric ? cols[i].w : min(s.width, cols[i].w)
                    v.frame = NSRect(x: right.contains(i) ? cols[i].x + cols[i].w - w : cols[i].x, y: y + 10 + (rh - 20) / 2,
                                     width: v is CellWithMark ? cols[i].w : w, height: v is CellWithMark ? rh : 20)
                }
            }
            y += rh + 20
        }
        CATransaction.commit()
    }

    override func updateLayer() {
        super.updateLayer()
        for l in lines { l.backgroundColor = Themed.color(\.border, 0.5).cgColor(in: self) }
    }

    /// The name cell: indent by depth, the expand chevron, the status dot, the name.
    final class CellWithMark: DSView {
        private let text: TextBlockView
        private let dot = CALayer()
        private let indent: CGFloat
        private var toggle: ButtonView?
        init(text: TextBlockView, dot color: NSColor?, indent: CGFloat, toggle: (expanded: Bool, action: @MainActor () -> Void)?) {
            self.text = text
            self.indent = indent
            super.init(frame: .zero)
            addSubview(text)
            dot.cornerRadius = 3
            dot.backgroundColor = color?.cgColor
            dot.isHidden = color == nil
            layer?.addSublayer(dot)
            if let toggle {
                let b = ButtonView(nil, icon: toggle.expanded ? .chevronDown : .chevronRight, variant: .ghostMuted, size: .iconMicro)
                b.iconSize = 14
                b.setAccessibilityLabel(toggle.expanded ? "Collapse" : "Expand")
                b.action = toggle.action
                addSubview(b)
                self.toggle = b
            }
        }
        override func layout() {
            super.layout()
            toggle?.frame = NSRect(x: indent, y: 0, width: 20, height: 20)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            dot.frame = CGRect(x: indent + 20 + 8, y: 7, width: 6, height: 6)
            CATransaction.commit()
            text.frame = NSRect(x: indent + 20 + 8 + 6 + 8, y: 2, width: max(0, bounds.width - indent - 42), height: 16)
        }
    }
}

/// `ProcessResourceHistoryChart`: one bar per bucket, average over peak CPU (`h-28 gap-1 p-2 bg-muted/10`).
final class CpuBarsView: DSView, SettingsGroupRow {
    private let buckets: [(avg: Double, max: Double)]
    private let border = CALayer()
    init(buckets: [JSONValue]) {
        self.buckets = buckets.map { ($0["avgCpuPercent"]?.doubleValue ?? 0, $0["maxCpuPercent"]?.doubleValue ?? 0) }
        super.init(frame: .zero)
        layer?.addSublayer(border)
    }
    func height(forWidth width: CGFloat) -> CGFloat { 1 + 12 + 112 + 12 }
    override var wantsUpdateLayer: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        border.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 1)
        border.backgroundColor = Themed.color(\.border, 0.6).cgColor(in: self)
        let box = CGRect(x: 20, y: 13, width: bounds.width - 40, height: 112)
        ctx.setFillColor(Themed.color(\.muted, 0.1).cgColor(in: self))
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: 4, cornerHeight: 4, transform: nil))
        ctx.fillPath()
        guard !buckets.isEmpty else { return }
        let peak = max(1, buckets.map(\.max).max() ?? 1)
        let inner = box.insetBy(dx: 8, dy: 8)
        let w = (inner.width - CGFloat(buckets.count - 1) * 4) / CGFloat(buckets.count)
        for (i, b) in buckets.enumerated() {
            let x = inner.minX + CGFloat(i) * (w + 4)
            for (value, alpha) in [(b.max, 0.15), (b.avg, 0.6)] {
                let h = max(1, inner.height * CGFloat(value / peak))
                ctx.setFillColor(Themed.color(\.foreground, alpha).cgColor(in: self))
                ctx.fill(CGRect(x: x, y: inner.maxY - h, width: w, height: h))
            }
        }
    }
}

/// `ResourceHistoryWindowSelector`: the 5m, 15m, 30m, 1h segmented choice.
final class SegmentedWindows: DSView {
    private var buttons: [ButtonView] = []
    var onSelect: ((Int) -> Void)?
    init(labels: [String], selected: Int) {
        super.init(frame: .zero)
        for (i, l) in labels.enumerated() {
            let b = ButtonView(l, variant: i == selected ? .secondary : .ghostMuted, size: .micro)
            b.action = { [weak self] in self?.onSelect?(i) }
            buttons.append(b)
            addSubview(b)
        }
        setAccessibilityLabel("Process history period")
    }
    override var intrinsicContentSize: NSSize { NSSize(width: buttons.reduce(0) { $0 + $1.intrinsicContentSize.width } + CGFloat(buttons.count - 1) * 2, height: 20) }
    override func layout() {
        super.layout()
        var x: CGFloat = 0
        for b in buttons { let w = b.intrinsicContentSize.width; b.frame = NSRect(x: x, y: 0, width: w, height: 20); x += w + 2 }
    }
}
