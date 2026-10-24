import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// Several machines with the same local ids and project names: every update leaves the list equal to a fresh
/// build, each slot on screen drawn and clicked as its own thread, and no project header without its rows.
@MainActor
struct SidebarMultiMachineTests {
    let nowMs = TimestampFormat.nowMs(SidebarPreview.referenceNow)
    static let envs = ["mini", "aniko", "mbp"]

    /// Each machine has projects "Main" and "t3pretzel" under the same local ids, and threads t0... under the same ids.
    static func machineShell(_ env: String, threads: Int) -> ShellSnapshot {
        let projects = [SidebarPreview.project("p-main", "Main"), SidebarPreview.project("p-pretzel", "t3pretzel"),
                        SidebarPreview.project("p-\(env)", "only-\(env)")]
        let kinds: [SidebarPreview.Kind] = [.read, .done, .working, .input, .failed]
        let list = (0..<threads).map { i in
            SidebarPreview.thread("t\(i)", "\(env) thread \(i)", project: ["p-main", "p-pretzel", "p-\(env)"][i % 3],
                                  kind: kinds[i % kinds.count], minutesAgo: Double(i * 7 + 3))
        }
        return SidebarPreview.snapshot(projects: projects, threads: list)
    }

    func host(_ content: SidebarContentView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 255, height: 780), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        content.frame = NSRect(x: 0, y: 0, width: 255, height: 780)
        content.layoutSubtreeIfNeeded()
        content.list.layoutSubtreeIfNeeded()
        return window
    }

    /// What the list should show: a fresh build of the snapshot without the hidden threads.
    func fresh(_ content: SidebarContentView) -> [SidebarItem] {
        guard var snap = content.snapshot else { return [] }
        snap.threads.removeAll { content.state.hiddenThreadIds.contains($0.id) }
        return SidebarListBuilder.items(snapshot: snap, state: content.state, nowMs: content.nowMs)
    }

    /// Every invariant the user can see: the items, the headers' rows, each slot's view and what a click there opens.
    func check(_ content: SidebarContentView, _ step: String) {
        let list = content.list
        list.layoutSubtreeIfNeeded()
        let items = list.items
        #expect(items == fresh(content), "items differ from a fresh build after \(step)")
        #expect(Set(items.map(\.key)).count == items.count, "duplicate keys after \(step)")
        let threads = Dictionary((content.snapshot?.threads ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for (i, item) in items.enumerated() {
            if case .row(let r) = item {
                #expect(r.title == threads[r.id]?.title, "row \(r.id) shows \(r.title) after \(step)")
                #expect(!content.state.hiddenThreadIds.contains(r.id), "hidden thread \(r.id) listed after \(step)")
            }
            if case .projectHeader(let h) = item, h.expanded {
                let rows = items[(i + 1)...].prefix { if case .row(let r) = $0 { r.inProjectSection } else { false } }
                #expect(h.count > 0 && rows.count == h.count, "header \(h.label) counts \(h.count), shows \(rows.count) after \(step)")
            }
        }
        let views = list.visible.values.map(ObjectIdentifier.init)
        #expect(Set(views).count == views.count, "one view under two keys after \(step)")
        let shown = list.visibleRect
        for i in list.visibleRange {
            let frame = list.frame(at: i)
            guard frame.intersects(shown) else { continue }
            let key = items[i].key
            guard let view = list.view(forKey: key) else {
                Issue.record("no view for \(key) at slot \(i) after \(step)")
                continue
            }
            #expect(!view.isHidden && view.frame == frame && view.item == items[i], "slot \(i) (\(key)) drawn wrong after \(step): hidden \(view.isHidden) frame \(view.frame) want \(frame) same item \(view.item == items[i])")
            guard case .row = items[i] else { continue }
            let center = NSPoint(x: frame.midX, y: frame.midY)
            guard frame.height > 4, shown.contains(center), let superview = list.superview else { continue }
            var hit = list.hitTest(list.convert(center, to: superview))
            while let v = hit, !(v is SidebarRowBase) { hit = v.superview }
            #expect((hit as? SidebarRowBase)?.item?.key == key,
                    "a click on \(key) lands on \(String(describing: (hit as? SidebarRowBase)?.item?.key)) after \(step): listed \(hit.map { h in list.view(forKey: (h as? SidebarRowBase)?.item?.key ?? "") === h } ?? false) hidden \(hit?.isHidden ?? false) frame \(hit?.frame ?? .zero) want \(frame) anims \(hit?.layer?.animationKeys() ?? [])")
        }
    }

    /// The same local thread id on three machines lists three rows, each opening its own machine's thread.
    @Test func sameLocalIdsOnThreeMachinesStayApart() {
        var shells = MergedShell()
        for env in Self.envs { shells.set(Self.machineShell(env, threads: 3), environmentId: env) }
        let content = SidebarContentView()
        content.now = { SidebarPreview.referenceNow }
        let window = host(content)
        defer { window.contentView = nil }
        content.state.environments = SidebarEnvironments(primaryId: "mini", labels: ["mini": "miniko", "aniko": "aniko", "mbp": "MacBook Pro"])
        var opened: [ThreadId] = []
        content.actions.openThread = { opened.append($0) }
        content.setSnapshot(shells.merged(order: Self.envs), animated: false)
        check(content, "first")
        let rows = content.list.items.compactMap { if case .row(let r) = $0 { r } else { nil } }
        #expect(Set(rows.map(\.id)) == Set(Self.envs.flatMap { env in (0..<3).map { ThreadId("t\($0)").scoped(to: env) } }))
        for row in rows {
            #expect(row.title == "\(row.id.environmentId!) thread \(row.id.localId.rawValue.dropFirst())")
            content.list.view(forKey: "thread:\(row.id.rawValue)")?.onOpen?()
        }
        #expect(opened.count == rows.count && opened.allSatisfy { id in rows.contains { $0.id == id } } && Set(opened).count == rows.count)
    }

    /// Random updates from three machines, as the app's merge sends them, in T3's list and Redesign's sections.
    @Test(arguments: [(false, SidebarModel.SortOrder.manual), (true, .manual), (true, .updatedAt)])
    func randomUpdatesKeepEverySlotRight(dither: Bool, order: SidebarModel.SortOrder) {
        var input = ThemeRuntimeInput()
        input.ditherDark = dither
        input.ditherLight = dither
        ThemeRuntime.apply(input)
        defer { ThemeRuntime.apply(ThemeRuntimeInput()) }
        var rng = SplitMix(seed: dither ? (order == .manual ? 7 : 11) : 3)
        var raw = Dictionary(uniqueKeysWithValues: Self.envs.map { ($0, Self.machineShell($0, threads: 9)) })
        var shells = MergedShell()
        let content = SidebarContentView()
        content.now = { SidebarPreview.referenceNow }
        let window = host(content)
        defer { window.contentView = nil }
        var state = content.state
        state.dither = dither
        state.environments = SidebarEnvironments(primaryId: "mini", labels: ["mini": "miniko", "aniko": "aniko", "mbp": "MacBook Pro"])
        state.settledExpanded = true
        state.snoozedExpanded = true
        state.collapsedProjects = []
        state.projectOrder = []
        state.projectSortOrder = order
        content.state = state
        func publish(_ env: String) {
            shells.set(raw[env]!, environmentId: env)
            content.setSnapshot(shells.merged(order: Self.envs), animated: rng.next(2) == 0, changedThreadIds: shells.lastChangedThreadIds)
        }
        for env in Self.envs { publish(env) }
        check(content, "first")
        var serial = 100
        for step in 0..<400 {
            let env = Self.envs[rng.next(Self.envs.count)]
            var snap = raw[env]!
            let op = rng.next(12)
            let i = snap.threads.isEmpty ? 0 : rng.next(snap.threads.count)
            let iso = { (minutes: Double) in T3Timestamp(epochMs: self.nowMs - Int64(minutes * 60_000)) }
            var what = "\(env) op \(op)"
            switch op {
            case 0 where !snap.threads.isEmpty: snap.threads[i].title = "\(env) renamed \(step)"
            case 1 where !snap.threads.isEmpty:
                let on = snap.threads[i].settledOverride == nil
                snap.threads[i].settledOverride = on ? .settled : nil
                snap.threads[i].settledAt = on ? iso(1) : nil
            case 2 where !snap.threads.isEmpty: snap.threads[i].pinnedAt = snap.threads[i].pinnedAt == nil ? iso(2) : nil
            case 3 where !snap.threads.isEmpty: snap.threads[i].archivedAt = iso(0.5)
            case 4 where !snap.threads.isEmpty: snap.threads.remove(at: i)
            case 5:
                serial += 1
                let project = ["p-main", "p-pretzel", "p-\(env)"][rng.next(3)]
                let new = SidebarPreview.snapshot(projects: [], threads: [
                    SidebarPreview.thread("t\(serial)", "\(env) new \(serial)", project: project, kind: .working, minutesAgo: 0.2),
                ]).threads[0]
                snap.threads.insert(new, at: rng.next(snap.threads.count + 1))
            case 6 where !snap.threads.isEmpty: snap.threads[i].updatedAt = iso(Double(rng.next(300)))
            case 7 where !snap.threads.isEmpty:
                // Another machine's thread, or this one's, becomes the Orchestrator's hidden thread.
                let id = snap.threads[i].id.scoped(to: env)
                if content.state.hiddenThreadIds.contains(id) { content.state.hiddenThreadIds.remove(id) } else { content.state.hiddenThreadIds = [id] }
                what += " hide"
            case 8 where dither:
                let groups = SidebarModel.buildProjectGroups(content.snapshot?.projects ?? [], preferredEnvironmentId: "mini")
                if let key = groups.randomElement(using: &rng)?.key {
                    if content.state.collapsedProjects.contains(key) { content.state.collapsedProjects.remove(key) } else { content.state.collapsedProjects.insert(key) }
                }
                what += " fold"
            case 9:
                let rows = content.list.items.compactMap { if case .row(let r) = $0 { r.id } else { nil } }
                content.state.activeThreadId = rows.randomElement(using: &rng)
                what += " select"
            case 10:
                content.scrollArea.scroll(to: NSPoint(x: 0, y: CGFloat(rng.next(1_500))))
                what += " scroll"
            case 11 where !snap.threads.isEmpty: snap.threads[i].projectId = ProjectId(["p-main", "p-pretzel", "p-\(env)"][rng.next(3)])
            default: break
            }
            if snap != raw[env]! {
                raw[env] = snap
                publish(env)
            }
            check(content, "step \(step), \(what)")
        }
    }
}

/// A seeded generator, so a failing run repeats.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func next(_ n: Int) -> Int { Int(next() % UInt64(n)) }
}
