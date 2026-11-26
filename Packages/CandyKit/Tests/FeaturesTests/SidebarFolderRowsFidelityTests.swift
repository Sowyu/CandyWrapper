import AppKit
import Testing
import DesignSystem
import T3Store
@testable import Features

/// The boring sidebar's two-line folder rows (#26463) against T3's markup in Chromium (spec from
/// scripts/gen-sidebar-folder-rows-spec.py, references in design/component-reference/sidebar-folder-rows).
@MainActor @Suite(.fidelity)
struct SidebarFolderRowsFidelityTests {
    static let ceilings: FidelityCeilings = ["folderRows": .init(0.04)]
    static let out = Fidelity.root.appendingPathComponent("sidebar-folder-rows")

    static func model(title: String, environment: String?) throws -> SidebarRowModel {
        let items = SidebarListBuilder.items(snapshot: SidebarPreview.richSnapshot(), state: SidebarListState(),
                                             nowMs: TimestampFormat.nowMs(SidebarPreview.referenceNow))
        var r = try #require(items.compactMap { if case .row(let r) = $0 { r } else { nil } }.first)
        r.variant = .slim; r.action = .settle; r.title = title; r.environmentLabel = environment; r.environmentMachine = "server"
        r.status = .ready; r.topStatus = nil; r.isGoal = false; r.isUnread = false; r.isWoke = false; r.isPinned = false
        r.recedes = false; r.isActive = false; r.isRegeneratingTitle = false; r.timeLabel = "5m"; r.snoozeLabel = nil
        r.providers = []; r.terminalProcessCount = 0
        r.pullRequestBadge = nil; r.issueBadge = nil
        r.inProjectSection = true; r.folderMultiline = true
        return r
    }

    @Test func folderRows() throws {
        let repo = SidebarFidelityTests.repo
        let refDir = repo.appendingPathComponent("design/component-reference/sidebar-folder-rows")
        let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: repo.appendingPathComponent("design/component-reference/sidebar-folder-rows.json"))) as! [String: Any]
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        var lines: [(String, Double)] = []
        for c in spec["cases"] as! [[String: Any]] {
            let name = c["name"] as! String, native = c["native"] as! [String: String]
            let r = try Self.model(title: native["title"]!, environment: native["environment"])
            for theme in spec["themes"] as! [String] {
                let base = "\(name).rest.\(theme)"
                let ref = try #require(NSBitmapImageRep(data: Data(contentsOf: refDir.appendingPathComponent("\(base).png"))))
                let size = NSSize(width: CGFloat(ref.pixelsWide) / 2, height: CGFloat(ref.pixelsHigh) / 2)
                // The page's 8pt margin, then the 240pt sidebar box with its own 8pt padding.
                let canvas = ConnectionsFidelityTests.Canvas(frame: NSRect(origin: .zero, size: size))
                let box = SidebarSearchFidelityTests.SidebarBox(frame: NSRect(x: 8, y: 8, width: size.width - 16, height: size.height - 16))
                let row = SidebarSlimRowView()
                row.configure(.row(r))
                row.frame = NSRect(x: 8, y: 8, width: size.width - 32, height: SidebarItem.row(r).height)
                box.addSubview(row)
                canvas.addSubview(box)
                let ours = Snapshot.image(of: canvas, size: size, scale: 2, dark: theme == "dark")
                let (total, _, diff) = SidebarFidelityTests.compare(ref, ours, bands: [])
                try ref.representation(using: .png, properties: [:])!.write(to: Self.out.appendingPathComponent("\(base).ref.png"))
                try Snapshot.writePNG(ours, to: Self.out.appendingPathComponent("\(base).ours.png"))
                try Snapshot.writePNG(diff, to: Self.out.appendingPathComponent("\(base).diff.png"))
                lines.append((base, total))
            }
        }
        for (base, total) in lines.sorted(by: { $0.1 > $1.1 }) { print("sidebar-folder-rows", base, String(format: "%.2f%%", total * 100)) }
        Self.ceilings.check("folderRows", lines)
    }

    /// 54pt with a meta line, 36pt without (`py-1.5`, an `h-6` title line, `mt-0.5` and a 16pt line); off, 36.
    @Test func heights() throws {
        var r = try Self.model(title: "T", environment: "Studio server")
        #expect(SidebarItem.row(r).height == 54)
        r.environmentLabel = nil
        #expect(SidebarItem.row(r).height == 36)
        r.environmentLabel = "Studio server"; r.folderMultiline = false
        #expect(SidebarItem.row(r).height == 36)
    }
}
