import AppKit
import Testing
import DesignSystem
@testable import T3Protocol
import T3Store
@testable import Features

/// The Pull Requests page's rows, the pull request panel's header and tab bar, and the Link pull request
/// dialog against T3's markup in Chromium (spec from scripts/gen-pull-requests-spec.py, references in
/// design/component-reference/pull-requests). Writes ref, ours and diff PNGs plus report-pull-requests.html
/// to `Fidelity.root`.
@MainActor @Suite(.fidelity)
struct PullRequestsFidelityTests {
    /// Per-case ceilings, measured 2026-10-22 plus margin (FidelitySupport.swift).
    static let ceilings: FidelityCeilings = [
        "pullRequests": .init(0.07),
    ]
    static let out = Fidelity.root.appendingPathComponent("pull-requests")
    static let nowMs = T3Timestamp.parseEpochMs("2026-10-10T16:00:00Z")!

    /// The list's groups as the page lays them out (`space-y-3` groups, `space-y-0.5` rows).
    final class Rows: DSView {}

    static func view(_ name: String, size: CGSize) throws -> NSView {
        let frame = NSRect(x: 8, y: 8, width: size.width, height: size.height)
        if name.hasPrefix("avatar.") {
            let parts = name.split(separator: ".")
            let outcome = String(parts[1]), stale = parts.count > 2
            let avatar = PullRequestAvatarView(frame: frame)
            avatar.actor = PullRequestActor(login: "bot")
            avatar.reviewOutcome = outcome
            avatar.staleReview = stale
            avatar.ring = PullRequestStyle.outcomeRing(outcome, stale: stale)
            return avatar
        }
        switch name {
        case "rows":
            let list = try PullRequestFixtures.list()
            let viewers = ["env-1 github.com": "octocat"]
            let entries = list.entries.map { e -> PullRequestListEntry in var e = e; e.environmentId = "env-1"; return e }
            let groups = PullRequestListLogic.groupByInvolvement(Array(entries.prefix(3)), viewers: viewers)
            let rows = Rows(frame: frame)
            var y: CGFloat = 0
            for group in groups {
                let header = GroupHeaderView()
                header.set(group, visible: true)
                header.frame = NSRect(x: 0, y: y, width: size.width, height: 20)
                rows.addSubview(header)
                y += 22
                for e in group.entries {
                    let row = PullRequestRowView()
                    row.configure(e, selected: false, showProvider: false, matchedElsewhere: false, speedMode: false, nowMs: nowMs)
                    row.frame = NSRect(x: 0, y: y, width: size.width, height: PullRequestRowView.height)
                    rows.addSubview(row)
                    y += PullRequestRowView.height + 2
                }
                y += 10
            }
            rows.layoutSubtreeIfNeeded()
            return rows
        case "detail-header":
            var d = try PullRequestFixtures.detail()
            d.state = "open"; d.mergedAt = nil; d.closedAt = nil
            // Tall enough that the floating composer button falls below the captured header.
            let view = PullRequestDetailView(frame: NSRect(x: 8, y: 8, width: size.width, height: 600))
            view.nowMs = nowMs
            view.show(d)
            view.activityPending = false
            view.layoutSubtreeIfNeeded()
            return view
        default:
            let dialog = LinkPullRequestDialog(project: .init(host: "github.com", repository: "pingdotgg/t3code", kind: "github"))
            dialog.input.text = "#42"
            dialog.input.onChange?("#42")
            dialog.dialog.frame = NSRect(x: 8, y: 8, width: 576, height: 0)
            dialog.dialog.frame.size.height = dialog.dialog.height(forWidth: 576)
            dialog.dialog.layoutSubtreeIfNeeded()
            return dialog.dialog
        }
    }

    @Test func pullRequests() throws {
        let repo = SidebarFidelityTests.repo
        let refDir = repo.appendingPathComponent("design/component-reference/pull-requests")
        let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: repo.appendingPathComponent("design/component-reference/pull-requests.json"))) as! [String: Any]
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: refDir.appendingPathComponent("manifest.json"))) as! [String: [String: Double]]
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        var lines: [(String, Double)] = [], images = ""
        for c in spec["cases"] as! [[String: Any]] {
            let name = c["name"] as! String
            let css = manifest[name]!
            for theme in spec["themes"] as! [String] {
                let base = "\(name).rest.\(theme)"
                let ref = try #require(NSBitmapImageRep(data: Data(contentsOf: refDir.appendingPathComponent("\(base).png"))))
                let size = NSSize(width: CGFloat(ref.pixelsWide) / 2, height: CGFloat(ref.pixelsHigh) / 2)
                let canvas = SidebarSearchFidelityTests.Canvas(frame: NSRect(origin: .zero, size: size))
                canvas.addSubview(try Self.view(name, size: CGSize(width: css["width"]!, height: css["height"]!)))
                let ours = Snapshot.image(of: canvas, size: size, scale: 2, dark: theme == "dark")
                let (total, _, diff) = SidebarFidelityTests.compare(ref, ours, bands: [])
                try ref.representation(using: .png, properties: [:])!.write(to: Self.out.appendingPathComponent("\(base).ref.png"))
                try Snapshot.writePNG(ours, to: Self.out.appendingPathComponent("\(base).ours.png"))
                try Snapshot.writePNG(diff, to: Self.out.appendingPathComponent("\(base).diff.png"))
                lines.append((base, total))
                images += "<p>\(base): \(String(format: "%.2f", total * 100))%<br>"
                    + ["ref", "ours", "diff"].map { "<img style='zoom:.5' src='pull-requests/\(base).\($0).png'>" }.joined() + "</p>"
            }
        }
        for (base, total) in lines.sorted(by: { $0.1 > $1.1 }) { print("pull-requests", base, String(format: "%.2f%%", total * 100)) }
        Self.ceilings.check("pullRequests", lines)
        let mean = lines.map(\.1).reduce(0, +) / Double(max(1, lines.count))
        print(String(format: "FIDELITY pull-requests: %d cases, mean differing %.2f%%", lines.count, mean * 100))
        let html = "<!doctype html><meta charset=utf-8><title>Pull requests</title><body style='font:13px -apple-system'>" + images
        try html.write(to: Self.out.deletingLastPathComponent().appendingPathComponent("report-pull-requests.html"), atomically: true, encoding: .utf8)
        #expect(mean < 0.05)
    }
}
