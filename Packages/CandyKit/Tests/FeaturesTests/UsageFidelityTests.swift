import AppKit
import Testing
import DesignSystem
import T3Store
@testable import T3Protocol
@testable import Features

/// The Usage header, a cost chart, the /usage-limits banner, the Scheduled Tasks list and the editor's schedule
/// rows against T3's markup in Chromium (spec from scripts/gen-usage-spec.py, references in
/// design/component-reference/usage). Writes ref, ours and diff PNGs plus report-usage.html to /tmp/candywrapper-fidelity.
@MainActor
struct UsageFidelityTests {
    static let out = URL(fileURLWithPath: "/tmp/candywrapper-fidelity/usage")

    static func sized(_ v: NSView, _ size: NSSize) -> NSView {
        v.frame = NSRect(origin: .zero, size: size)
        v.layoutSubtreeIfNeeded()
        return v
    }

    static func make(_ kind: String, size: NSSize) throws -> NSView {
        switch kind {
        case "header":
            let h = UsageHeaderView()
            h.viewport = 1440
            var m = UsagePageView.Model()
            m.metric = "limits"
            h.apply(m)
            return sized(h, size)
        case "chart":
            let c = UsageChartView()
            var m = UsageChartView.Model()
            m.providers = [.codex, .claude]
            m.periods = UsageFormat.enumerateDays("2026-10-04", "2026-10-10")
            let codex = [0, 1.2, 3.5, 2, 0, 4.1, 2.2], claude = [2, 2.5, 1, 0.5, 3, 3.2, 1.8]
            m.byPeriod = Dictionary(uniqueKeysWithValues: m.periods.enumerated().map { i, d in
                (d, UsagePeriodTotals(day: d, hourStart: nil, costUsd: codex[i] + claude[i], totalTokens: 0,
                                      byProvider: [.codex: UsageByProvider(costUsd: codex[i]), .claude: UsageByProvider(costUsd: claude[i])]))
            })
            m.timeZone = "UTC"
            c.model = m
            return sized(c, size)
        case "banner":
            let now = T3Timestamp.parseEpochMs("2026-10-10T12:00:00.000Z")!
            let limits = ProviderUsageLimits(checkedAt: "2026-10-10T11:59:00.000Z", windows: [
                UsageLimitWindow(id: "primary", kind: "session", label: "5h limit", usedPercent: 37, resetsAt: UsageFormat.isoString(now + (2 * 60 + 13) * 60_000),
                                 windowDurationMins: 300),
                UsageLimitWindow(id: "secondary", kind: "weekly", label: "Weekly limit", usedPercent: 62,
                                 resetsAt: UsageFormat.isoString(now + (3 * 1440 + 4 * 60) * 60_000), windowDurationMins: 10080)])
            let report = UsageLimitsReport(createdAt: UsageFormat.isoString(now), accounts: [
                .init(id: "codex", driver: "codex", label: "codex [codex]", plan: "ChatGPT Pro", email: nil, sourceLabel: nil, instanceId: "codex",
                      resetCreditTarget: .instance("codex"), displayName: nil, accentColor: nil, limits: limits)], notices: [])
            let b = UsageLimitsBannerView(report: report)
            return sized(b, NSSize(width: size.width, height: b.height(forWidth: size.width)))
        case "tasks":
            let c = SettingsPageContext()
            let env = SettingsScopeEnvironment(id: "a", label: "host", settings: ServerSettingsValues(.object([:])))
            c.scope = SettingsScopeState(environments: [env], primaryId: "a")
            let soon = UsageFormat.isoString(TimestampFormat.nowMs() + 3 * 3_600_000 - 60_000)
            c.scheduledTasks = ["a": .loaded([
                ScheduledTask(id: "t1", title: "Morning triage", prompt: "Read new issues in the demo repo and summarize anything that needs a reply today.",
                              schedule: .fixedTime(timeOfDay: "09:00", weekdays: [1, 2, 3, 4, 5]), projectId: "p", nextRunAt: soon, lastRunStatus: "succeeded"),
                ScheduledTask(id: "t2", title: "Deploy hook", prompt: "Handle this webhook:\n{{body}}", enabled: false,
                              schedule: .webhook(signature: nil, maxDeliveryAgeMinutes: nil), projectId: "p"),
            ])]
            let page = ScheduledTasksSettingsView(context: c)
            page.refresh()
            let list = try #require(page.anchor("scheduled-tasks") as? ScheduledTasksListView)
            list.removeFromSuperview()
            return sized(list, NSSize(width: size.width, height: list.height(forWidth: size.width)))
        default:
            let toggle = ToggleGroupView(variant: .segmented, items: [("At a time", nil), ("Every interval", nil), ("On webhook", nil)], selected: 0)
            let header = ScheduledTaskInlineRow([FormLabel.make("Schedule")], trailing: [toggle])
            let time = InputView(text: "09:00")
            let runAt = FormLabel.make("Run at")
            let on = LabelView("on", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
            on.lineHeight = 16
            let days = ScheduledTaskWeekdaysView(selected: [1, 2, 3, 4, 5]) { _ in }
            let line = ScheduledTaskInlineRow([runAt, ScheduledTaskSized(time, width: 128), on, days], trailing: [])
            line.gapAfter = [2: 12]
            let v = DSView(frame: NSRect(origin: .zero, size: size))
            v.addSubview(header)
            v.addSubview(line)
            header.frame = NSRect(x: 0, y: 0, width: size.width, height: 28)
            line.frame = NSRect(x: 0, y: 40, width: size.width, height: 32)
            v.layoutSubtreeIfNeeded()
            return v
        }
    }

    @Test func usage() throws {
        let repo = SidebarFidelityTests.repo
        let refDir = repo.appendingPathComponent("design/component-reference/usage")
        let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: repo.appendingPathComponent("design/component-reference/usage.json"))) as! [String: Any]
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: refDir.appendingPathComponent("manifest.json"))) as! [String: [String: Double]]
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        var lines: [(String, Double)] = [], images = ""
        for c in spec["cases"] as! [[String: Any]] {
            let name = c["name"] as! String, native = c["native"] as! [String: String]
            let css = manifest[name]!
            let size = NSSize(width: css["width"]!, height: css["height"]!)
            for theme in spec["themes"] as! [String] {
                let base = "\(name).rest.\(theme)"
                let ref = try #require(NSBitmapImageRep(data: Data(contentsOf: refDir.appendingPathComponent("\(base).png"))))
                let canvas = ConnectionsFidelityTests.Canvas(frame: .zero)
                let view = try Self.make(native["kind"]!, size: size)
                view.frame.origin = NSPoint(x: 8, y: 8)
                canvas.addSubview(view)
                let ours = Snapshot.image(of: canvas, size: NSSize(width: CGFloat(ref.pixelsWide) / 2, height: CGFloat(ref.pixelsHigh) / 2),
                                          scale: 2, dark: theme == "dark")
                let (total, _, diff) = SidebarFidelityTests.compare(ref, ours, bands: [])
                try ref.representation(using: .png, properties: [:])!.write(to: Self.out.appendingPathComponent("\(base).ref.png"))
                try Snapshot.writePNG(ours, to: Self.out.appendingPathComponent("\(base).ours.png"))
                try Snapshot.writePNG(diff, to: Self.out.appendingPathComponent("\(base).diff.png"))
                lines.append((base, total))
                images += "<p>\(base): \(String(format: "%.2f", total * 100))%<br>"
                    + ["ref", "ours", "diff"].map { "<img style='zoom:.5' src='usage/\(base).\($0).png'>" }.joined() + "</p>"
            }
        }
        for (base, total) in lines.sorted(by: { $0.1 > $1.1 }) { print("usage", base, String(format: "%.2f%%", total * 100)) }
        let mean = lines.map(\.1).reduce(0, +) / Double(max(1, lines.count))
        print(String(format: "FIDELITY usage: %d cases, mean differing %.2f%%", lines.count, mean * 100))
        let html = "<!doctype html><meta charset=utf-8><title>Usage</title><body style='font:13px -apple-system'>" + images
        try html.write(to: Self.out.deletingLastPathComponent().appendingPathComponent("report-usage.html"), atomically: true, encoding: .utf8)
        #expect(mean < 0.08)
    }
}
