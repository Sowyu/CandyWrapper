import AppKit
import Testing
import DesignSystem
import T3Protocol
@testable import T3Store
@testable import Features

/// Pinned and archived projects in the sidebar's project filter (4928 #26154, #29639, #29704).
@MainActor
struct SidebarProjectFilterTests {
    static func snapshot(pinned: Set<String> = [], archived: Set<String> = []) -> ShellSnapshot {
        func project(_ id: String, _ title: String) -> [String: Any] {
            var p = SidebarPreview.project(id, title)
            if pinned.contains(title) { p["pinnedAt"] = "2026-11-01T00:00:00.000Z" }
            if archived.contains(title) { p["archivedAt"] = "2026-11-01T00:00:00.000Z" }
            return p
        }
        return SidebarPreview.snapshot(projects: [project("p1", "demo-repo"), project("p2", "candywrapper"), project("p3", "old-repo")],
                                       threads: [SidebarPreview.thread("a", "A", project: "p1", kind: .read, minutesAgo: 1),
                                                 SidebarPreview.thread("b", "B", project: "p2", kind: .read, minutesAgo: 9),
                                                 SidebarPreview.thread("c", "C", project: "p3", kind: .read, minutesAgo: 20)])
    }

    @Test func pinnedLeadAndArchivedLeave() {
        let groups = SidebarListBuilder.projectScopeGroups(snapshot: Self.snapshot(pinned: ["candywrapper"], archived: ["old-repo"]))
        #expect(groups.first { $0.label == "candywrapper" }?.pinned == true)
        #expect(groups.first { $0.label == "old-repo" }?.archived == true)
        #expect(ProjectOrganization.pickable(groups).map(\.label) == ["candywrapper", "demo-repo"])
        let view = SidebarProjectScopeView(groups: groups, selectedKey: nil, minimumWidth: 200, selectedKeys: groups.filter { $0.label == "old-repo" }.map(\.key))
        #expect(view.items.map(\.label) == ["All projects", "candywrapper", "demo-repo"])
        // An archived project's scope reads as all projects.
        #expect(view.selectedKeys.isEmpty)
    }

    @Test func updatePayloadMatchesProjectUpdate() {
        #expect(ProjectOrganization.update(projectId: "p1", pinned: true, commandId: "c") == .object([
            "type": .string("project.update"), "commandId": .string("c"), "projectId": .string("p1"), "pinned": .bool(true)]))
        #expect(ProjectOrganization.update(projectId: "p1", archived: false, commandId: "c")["archived"] == .bool(false))
        #expect(ProjectOrganization.newThreadInCurrentProject(shift: false, openGroups: 1, allGroups: 3))
        #expect(!ProjectOrganization.newThreadInCurrentProject(shift: false, openGroups: 0, allGroups: 2))
    }

    /// CommandPalette.logic.test.ts at 4928: "No project" follows the pinned projects and the first other one, or keeps
    /// the scratch project's place when that one is pinned or current.
    @Test func noProjectGoesAfterThePins() {
        typealias E = (isScratch: Bool, pinned: Bool, isPreferred: Bool)
        let plain: [E] = [(false, false, false), (false, false, false), (true, false, false)]
        #expect(ProjectOrganization.noProjectIndex(plain) == 1)
        let pinned: [E] = [(false, true, false), (false, true, false), (false, false, false), (true, false, false)]
        #expect(ProjectOrganization.noProjectIndex(pinned) == 3)
        let scratchCurrent: [E] = [(true, false, true), (false, false, false)]
        #expect(ProjectOrganization.noProjectIndex(scratchCurrent) == 0)
        let scratchPinned: [E] = [(false, true, false), (true, true, false), (false, false, false)]
        #expect(ProjectOrganization.noProjectIndex(scratchPinned) == 1)
        #expect(ProjectOrganization.noProjectIndex([]) == 0)
    }

    @Test func pinningFromARowKeepsTheOrderWhileOpen() {
        let groups = SidebarListBuilder.projectScopeGroups(snapshot: Self.snapshot())
        let view = SidebarProjectScopeView(groups: groups, selectedKey: nil, minimumWidth: 200, canPin: { _ in true })
        var writes: [(String, Bool)] = []
        view.onTogglePin = { writes.append(($0, $1)) }
        let before = view.items.map(\.label)
        let key = view.items[2].key!
        view.togglePin(key)
        #expect(view.items.map(\.label) == before && view.items[2].pinned)
        #expect(writes.count == 1 && writes[0].0 == key && writes[0].1)
    }

    /// Mod+Shift+P in an open picker pins the highlighted row (DraftHeroHeadline.tsx:262-271 at 4928); with no
    /// highlighted row, or no picker in a window, the key stays with the open thread.
    @Test func pinShortcutPinsTheHighlightedRow() {
        let groups = SidebarListBuilder.projectScopeGroups(snapshot: Self.snapshot())
        let view = SidebarProjectScopeView(groups: groups, selectedKey: nil, minimumWidth: 200, extra: .addProject, canPin: { _ in true })
        var writes: [(String, Bool)] = []
        view.onTogglePin = { writes.append(($0, $1)) }
        #expect(!ProjectPickerPinShortcut.run())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300), styleMask: [], backing: .buffered, defer: true)
        window.contentView?.addSubview(view)
        #expect(!ProjectPickerPinShortcut.run())
        view.highlighted = 0
        #expect(ProjectPickerPinShortcut.run())
        #expect(writes.count == 1 && writes[0].0 == view.items[0].key && writes[0].1)
        // "Add project" has nothing to pin.
        view.highlighted = view.shown.count - 1
        #expect(!ProjectPickerPinShortcut.run())
        view.removeFromSuperview()
        #expect(!ProjectPickerPinShortcut.run())
    }

    @Test func pinWaitsForTheCapability() {
        let groups = SidebarListBuilder.projectScopeGroups(snapshot: Self.snapshot())
        let view = SidebarProjectScopeView(groups: groups, selectedKey: nil, minimumWidth: 200)
        var writes = 0
        view.onTogglePin = { _, _ in writes += 1 }
        view.togglePin(view.items[1].key!)
        #expect(writes == 0 && !view.items[1].pinned)
    }

    /// The pin turns to pin-off under the pointer and goes back when the rows rebuild or the popup closes under a
    /// still pointer.
    @Test func pinHoverClearsWhenTheRowLeaves() {
        let slot = ProjectPinSlot(name: "demo-repo", pinned: true)
        let host = DSView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 40, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.addSubview(slot)
        slot.mouseEntered(with: NSEvent())
        #expect(slot.button.icon == .pinOff)
        slot.removeFromSuperview()
        #expect(!slot.hovered && slot.button.icon == .pin)
        let unpinned = ProjectPinSlot(name: "demo-repo", pinned: false)
        #expect(unpinned.button.alphaValue == 0)
        unpinned.revealed = true
        #expect(unpinned.button.alphaValue == 1)
    }
}

/// The filter popup against T3's 4928 markup (scripts/gen-sidebar-project-filter-spec.py,
/// design/component-reference/sidebar-project-filter).
@MainActor @Suite(.fidelity)
struct SidebarProjectFilterFidelityTests {
    static let ceilings: FidelityCeilings = ["sidebarProjectFilter": .init(0.04)]

    @Test func projectFilter() throws {
        let repo = SidebarFidelityTests.repo
        let refDir = repo.appendingPathComponent("design/component-reference/sidebar-project-filter")
        let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: repo.appendingPathComponent("design/component-reference/sidebar-project-filter.json"))) as! [String: Any]
        let out = Fidelity.root.appendingPathComponent("sidebar-project-filter")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var lines: [(String, Double)] = []
        for c in spec["cases"] as! [[String: Any]] {
            let name = c["name"] as! String, native = c["native"] as! [String: String]
            for theme in spec["themes"] as! [String] {
                let base = "\(name).rest.\(theme)"
                let ref = try #require(NSBitmapImageRep(data: Data(contentsOf: refDir.appendingPathComponent("\(base).png"))))
                let snap = SidebarProjectFilterTests.snapshot(pinned: Set(native["pinned"].map { [$0] } ?? []), archived: ["old-repo"])
                let view = SidebarProjectScopeView(groups: SidebarListBuilder.projectScopeGroups(snapshot: snap), selectedKey: nil, minimumWidth: 200,
                                                   canPin: { _ in native["canPin"] != "no" })
                view.highlighted = native["highlighted"].flatMap(Int.init)
                let popup = PickerPopupView(view)
                popup.frame = NSRect(origin: NSPoint(x: 8, y: 8), size: popup.popupSize)
                popup.layoutSubtreeIfNeeded()
                let canvas = SidebarSearchFidelityTests.Canvas(frame: .zero)
                canvas.addSubview(popup)
                let ours = Snapshot.image(of: canvas, size: NSSize(width: CGFloat(ref.pixelsWide) / 2, height: CGFloat(ref.pixelsHigh) / 2),
                                          scale: 2, dark: theme == "dark")
                let (total, _, diff) = SidebarFidelityTests.compare(ref, ours, bands: [])
                for (suffix, image) in [("ref", ref), ("ours", ours), ("diff", diff)] { try Snapshot.writePNG(image, to: out.appendingPathComponent("\(base).\(suffix).png")) }
                lines.append((base, total))
            }
        }
        Self.ceilings.check("sidebarProjectFilter", lines)
    }
}
