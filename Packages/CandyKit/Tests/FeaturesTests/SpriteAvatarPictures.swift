import AppKit
import Testing
@testable import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// Opt-in pictures of Redesign's project and account avatars from the real views, with Sprites and with Letters, in
/// both appearances: `CANDY_SPRITE_PICTURES=<dir> scripts/test --filter SpriteAvatarPictures`.
@MainActor
struct SpriteAvatarPictures {
    static let names = ["Atlas", "atlas-web", "orbit-api", "Juniper", "pixel-forge", "pixel-farm", "Halcyon", "tidewater", "Marigold CRM", "zen-notes"]

    @Test func pictures() throws {
        guard let dir = ProcessInfo.processInfo.environment["CANDY_SPRITE_PICTURES"] else { return }
        let out = URL(filePath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let previous = ThemeRuntime.input, fonts = FontRuntime.input, motion = Motion.reducedOverride
        let appearance = NSApp?.appearance
        defer { ThemeRuntime.apply(previous); FontRuntime.apply(fonts); Motion.reducedOverride = motion; NSApp?.appearance = appearance }
        for sprites in [false, true] {
            for dark in [false, true] {
                var input = ThemeRuntimeInput(
                    light: ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .light)!),
                    dark: ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .dark)!))
                input.ditherLight = true; input.ditherDark = true
                input.projectSprites = sprites
                ThemeRuntime.apply(input); FontRuntime.apply(.init())
                Motion.reducedOverride = true
                NSApplication.shared.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let suffix = "\(sprites ? "after" : "before").\(dark ? "dark" : "light")"
                func save(_ name: String, _ view: NSView, _ size: NSSize) throws {
                    try Snapshot.writePNG(RedesignBaselineTests.image(view, size: size, dark: dark), to: out.appendingPathComponent("\(name).\(suffix).png"))
                }
                let sidebar = SidebarContentView()
                sidebar.windowedMac = false; sidebar.stage = .nightly
                sidebar.now = { SidebarPreview.referenceNow }
                sidebar.accountRow.set(name: "Sandbox User", image: nil, initials: nil, seed: "user_sandbox")
                sidebar.state = SidebarListState(activeThreadId: SidebarPreview.referenceActiveThread)
                sidebar.setSnapshot(SidebarPreview.referenceSnapshot(), animated: false)
                try save("sidebar", sidebar, NSSize(width: 280, height: 900))

                let context = SettingsPagesFidelityTests.context()
                context.nowMs = { TimestampFormat.nowMs(RedesignBaselineTests.now) }
                var pages: [NSView & SettingsGroupRow] = []
                NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
                    pages = DitherSettingsSection.projects.slices.map { RedesignBaselineTests.page($0.page, context: context) as NSView & SettingsGroupRow }
                }
                let page = DitherSettingsSectionView(section: .projects, pages: pages)
                try save("settings-projects", page, NSSize(width: 800, height: min(1800, max(100, page.height(forWidth: 800)))))

                // The mockup's first ten projects at each size, for the side-by-side with its C4 column.
                for size in [CGFloat(16), 20, 28, 64] {
                    let strip = DSView(frame: .zero)
                    for (i, title) in Self.names.enumerated() {
                        let v = ProjectMonogramView(ProjectIconSource(title: title, workspaceRoot: ""), size: size)
                        v.frame.origin = NSPoint(x: 8, y: 8 + CGFloat(i) * (size + 8))
                        strip.addSubview(v)
                    }
                    try save("strip-\(Int(size))", strip, NSSize(width: size + 16, height: 8 + 10 * (size + 8)))
                }
                let panel = ComposerFidelityTests.panel(width: 844, dark: dark)
                panel.setDraft(projectTitle: "demo-repo")
                try save("composer", panel, NSSize(width: 844, height: 780))
            }
        }
    }
}
