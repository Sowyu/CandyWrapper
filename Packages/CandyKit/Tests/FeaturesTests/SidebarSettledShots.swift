import AppKit
import Testing
@testable import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// Pictures of Redesign's sidebar sections for review, written to `CANDY_SETTLED_SHOTS` when it is set. Invented data:
/// 15 settled threads across 4 projects, a snoozed one and a few active ones.
@MainActor @Suite(.serialized)
struct SidebarSettledShots {
    static func snapshot() -> ShellSnapshot {
        let projects = [("p1", "demo-repo"), ("p2", "candywrapper"), ("p3", "t3code"), ("p4", "lighthouse-site")]
        let titles = ["Rename the store actor", "Draft the protocol notes", "Fix the reconnect backoff", "Port the timestamp formatter",
                      "Write the release checklist", "Trim the icon set", "Split the composer view", "Measure idle CPU",
                      "Retry uploads after sleep", "Tidy the settings search", "Check the dark palette", "Cache the project avatars",
                      "Add the keyboard map", "Clean up old worktrees", "Profile the list rebuild"]
        let ago: [Double] = [25, 70, 180, 400, 900, 1500, 1700, 2600, 3200, 4400, 6000, 9000, 15000, 30000, 50000]
        var threads = [
            SidebarPreview.thread("w1", "Ship the sidebar sections", project: "p2", kind: .working, minutesAgo: 2, extra: ["branch": "sidebar-sections"]),
            SidebarPreview.thread("w2", "Look at the chart overlap", project: "p1", kind: .done, minutesAgo: 8),
            SidebarPreview.thread("w3", "Answer the lighthouse question", project: "p4", kind: .input, minutesAgo: 14),
            SidebarPreview.thread("z1", "Look at this tomorrow", project: "p3", kind: .read, minutesAgo: 400,
                                  extra: ["snoozedUntil": SidebarPreview.iso(-90), "snoozedAt": SidebarPreview.iso(60)]),
        ]
        for (i, title) in titles.enumerated() {
            let branch: Any = i % 3 == 1 ? NSNull() : (i % 2 == 0 ? "main" : "fix/\(i)")
            threads.append(SidebarPreview.thread("s\(i)", title, project: projects[(i * 7 + i / 3) % 4].0, kind: .read, minutesAgo: ago[i] + 10,
                                                 extra: ["settledOverride": "settled", "settledAt": SidebarPreview.iso(ago[i]), "branch": branch]))
        }
        return SidebarPreview.snapshot(projects: projects.map { SidebarPreview.project($0.0, $0.1) }, threads: threads)
    }

    @Test func capture() throws {
        guard let dir = ProcessInfo.processInfo.environment["CANDY_SETTLED_SHOTS"] else { return }
        let out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let previous = ThemeRuntime.input, motion = Motion.reducedOverride, appearance = NSApp?.appearance
        defer { ThemeRuntime.apply(previous); Motion.reducedOverride = motion; NSApp?.appearance = appearance }
        for dark in [true, false] {
            var input = ThemeRuntimeInput(
                light: ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .light)!),
                dark: ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .dark)!))
            input.ditherLight = true; input.ditherDark = true
            input.ditherPicture = ComposerAttachmentsFidelityTests.fixture.path
            ThemeRuntime.apply(input)
            Motion.reducedOverride = true
            NSApplication.shared.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            try Self.shot("sections-collapsed", out, dark: dark, settled: false)
            try Self.shot("settled-open", out, dark: dark, settled: true, height: 1400)
            try Self.extraShots(out, dark: dark)
        }
    }

    static func shot(_ name: String, _ out: URL, dark: Bool, settled: Bool, height: CGFloat = 900, olderOnly: Bool = false,
                     _ step: ((SidebarContentView) -> Void)? = nil) throws {
        let sidebar = SidebarContentView()
        sidebar.windowedMac = false; sidebar.stage = .nightly
        sidebar.now = { SidebarPreview.referenceNow }
        sidebar.accountRow.set(name: "demo", image: nil, initials: nil)
        var state = SidebarListState(activeThreadId: "w1")
        state.capabilities = .init(threadSettlement: true, threadSnooze: true)
        state.settledExpanded = settled
        sidebar.state = state
        var snapshot = Self.snapshot()
        // Only threads settled a week or more ago, for a range with nothing in it.
        if olderOnly { snapshot.threads.removeAll { $0.settledOverride?.rawValue == "settled" && ($0.settledAt?.epochMs ?? 0) > TimestampFormat.nowMs(SidebarPreview.referenceNow) - 7 * 86_400_000 } }
        sidebar.setSnapshot(snapshot, animated: false)
        let rep = RedesignBaselineTests.image(sidebar, size: NSSize(width: 280, height: height), dark: dark, inWindow: step.map { s in { s(sidebar) } })
        try Snapshot.writePNG(rep, to: out.appendingPathComponent("\(name).\(dark ? "dark" : "light").png"))
    }
}
