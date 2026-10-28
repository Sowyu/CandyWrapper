import AppKit
import Testing
@testable import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// Run alone: theme globals belong to the entire test process. No suspension between pinning and drawing.
@MainActor
struct RedesignBaselineTests {
    static let now = ISO8601DateFormatter().date(from: "2026-10-28T12:00:00Z")!
    static let directory = SidebarFidelityTests.repo.appendingPathComponent("design/redesign-baseline")
    static let output = FileManager.default.temporaryDirectory.appendingPathComponent("redesign-baseline-\(getpid())")

    @Test func exactPixels() throws {
        let previous = ThemeRuntime.input, fonts = FontRuntime.input
        let motion = Motion.reducedOverride, duration = SettingsPanelMotion.durationMs
        let appearance = NSApp?.appearance
        defer {
            ThemeRuntime.apply(previous); FontRuntime.apply(fonts)
            Motion.reducedOverride = motion; SettingsPanelMotion.durationMs = duration
            NSApp?.appearance = appearance
        }
        let record = ProcessInfo.processInfo.environment["CANDY_RECORD_REDESIGN_BASELINE"] == "1"
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: Self.output, withIntermediateDirectories: true)
        var count = 0
        for dark in [false, true] {
            var input = ThemeRuntimeInput(
                light: ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .light)!),
                dark: ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .dark)!))
            input.ditherLight = true; input.ditherDark = true
            input.ditherPicture = ComposerAttachmentsFidelityTests.fixture.path
            ThemeRuntime.apply(input); FontRuntime.apply(.init())
            Motion.reducedOverride = true; SettingsPanelMotion.durationMs = 0
            NSApplication.shared.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            #expect(ThemeRuntime.isDither(dark: dark))
            func capture(_ name: String, _ view: NSView, _ size: NSSize) throws {
                let base = "\(name).\(dark ? "dark" : "light")"
                let ours = Self.image(view, size: size, dark: dark)
                let url = Self.directory.appendingPathComponent(base + ".png")
                count += 1
                if record { try Snapshot.writePNG(ours, to: url); return }
                guard FileManager.default.fileExists(atPath: url.path) else {
                    Issue.record("Missing Redesign baseline: \(url.path)"); return
                }
                let reference = try #require(NSBitmapImageRep(data: Data(contentsOf: url)))
                try Self.compare(reference, ours, name: base)
            }
            let panelSize = NSSize(width: 844, height: 780)
            for mode in ["empty", "typing", "queued", "approval", "question", "attachments"] {
                let panel = ComposerFidelityTests.panel(width: 844, dark: dark)
                panel.timeline.context.now = { Self.now }
                if mode == "empty" {
                    panel.setDraft(projectTitle: "demo-repo")
                } else {
                    panel.setProjection(try ThreadPreview.projection(titled: ThreadPreview.markdownThread), projectTitle: "demo-repo", workspaceRoot: nil)
                    panel.layoutSubtreeIfNeeded(); panel.timeline.scroll(toFraction: 1)
                }
                let pickers = try PickersFidelityTests.pickers()
                panel.composer.footerControls = [pickers.controlsView]
                if mode == "typing" { panel.composer.text = "Refactor the upload queue so retries keep their place" }
                if mode == "queued" {
                    panel.queue.placement = .floating
                    panel.composer.runState = .init(activeRunId: RunId("run"), running: true)
                    panel.queue.state = .init(items: [
                        .init(runId: RunId("q1"), messageId: nil, text: "second queued message"),
                        .init(runId: RunId("q2"), messageId: nil, text: "third queued message")],
                        activeRunId: RunId("run"), canReorder: true, canPromoteToSteer: true)
                    panel.queue.expand()
                }
                if mode == "approval" || mode == "question" {
                    if mode == "approval" {
                        panel.approvalPanel.configure(PendingApproval(requestId: "r", requestKind: .fileChange, createdAt: nil,
                            detail: "approval-demo.txt", appName: nil, options: nil, canRespond: true), pendingCount: 1, threadId: "t")
                        panel.drawer = .approval
                        panel.composer.pending = .approval
                    } else {
                        panel.questionPanel.configure(PendingUserInput(requestId: "q", createdAt: nil,
                            questions: [PanelsFidelityTests.purpose, PanelsFidelityTests.language], responseCapability: "live", dismissible: false), threadId: "t")
                        panel.drawer = .question
                        panel.composer.pending = .question(.init(label: "Next question", compactLabel: "Next", enabled: false,
                            showsPrevious: false, responding: false, showsAttach: true))
                    }
                }
                if mode == "attachments" {
                    let shelf = ComposerAttachmentsFidelityTests.view("shelf", size: NSSize(width: 680, height: 100))
                    // Same shelf fixture as the attachment fidelity suite, shown above the composer.
                    shelf.frame.origin = NSPoint(x: 82, y: 440); panel.addSubview(shelf)
                }
                try capture("composer-" + mode, panel, panelSize)
                if mode == "approval" { #expect(!panel.approvalPanel.isHidden) }
                if mode == "question" { #expect(!panel.questionPanel.isHidden) }
                if mode == "queued" { #expect(panel.queueBadge.count == 2) }
            }
            for (name, title, fraction) in [("markdown-top", ThreadPreview.markdownThread, CGFloat(0)),
                                            ("code-bottom", ThreadPreview.markdownThread, 1),
                                            ("commands", ThreadPreview.commandsThread, 0)] {
                let panel = ComposerFidelityTests.panel(width: 844, dark: dark)
                panel.timeline.context.now = { Self.now }
                panel.setProjection(try ThreadPreview.projection(titled: title), projectTitle: "demo-repo", workspaceRoot: nil)
                panel.model.runShellCommand = { _ in }
                panel.layoutSubtreeIfNeeded(); panel.timeline.scroll(toFraction: fraction)
                try capture("thread-" + name, panel, panelSize)
            }
            let sidebar = SidebarContentView()
            sidebar.windowedMac = false; sidebar.stage = .nightly
            sidebar.now = { SidebarPreview.referenceNow }
            sidebar.state = SidebarListState(activeThreadId: SidebarPreview.referenceActiveThread)
            sidebar.setSnapshot(SidebarPreview.referenceSnapshot(), animated: false)
            try capture("sidebar-many-threads", sidebar, NSSize(width: 280, height: 900))
            for c in PickersFidelityTests.cases {
                let (view, size) = c.make(try PickersFidelityTests.pickers())
                try capture(c.reference, view, size)
            }
            try capture("git-menu", GitFidelityTests.view(["kind": "menu", "variant": "remote"], size: .zero)[0], NSSize(width: 264, height: 100))
            try capture("pr-panel", PullRequestsFidelityTests.view("detail-header", size: NSSize(width: 800, height: 600)), NSSize(width: 816, height: 616))
            for kind in ["chart"] {
                let size = NSSize(width: 800, height: kind == "header" ? 140 : 300)
                try capture("usage-" + kind, UsageFidelityTests.make(kind, size: size), size)
            }
            for kind in ["notice", "stack"] {
                let size = NSSize(width: 692, height: 140)
                try capture("banner-" + kind, BannerStackFidelityTests.make(kind, size: size), size)
            }
            let toast = ToastView(title: "Permissions have changed for Sandbox", message: "Pair again using a new link with the permissions you need.", actionTitle: "Open Connections", secondaryTitle: "Dismiss")
            try capture("toast", toast, NSSize(width: 360, height: toast.height(forWidth: 360)))
            for name in ["root"] {
                let view = Self.palette(name)
                try capture("command-palette-" + name, view, NSSize(width: 576, height: view.intrinsicContentSize.height))
            }
            let toolbar = DSView(frame: .zero)
            let header = ThreadHeaderView(frame: NSRect(x: 0, y: 0, width: 800, height: 52))
            header.projectTitle = "demo-repo"; header.threadTitle = "Reply with markdown only"
            header.toggles.forEach { $0.isHidden = true }
            toolbar.addSubview(header)
            let card = ThreadViewFidelityTests.card(.full, size: NSSize(width: 800, height: 88))
            card.frame.origin = NSPoint(x: 0, y: 52); toolbar.addSubview(card)
            try capture("thread-toolbar", toolbar, NSSize(width: 800, height: 140))
            let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: SidebarFidelityTests.repo.appendingPathComponent("design/component-reference/diff.json"))) as! [String: Any]
            for c in spec["cases"] as! [[String: Any]] where ["modified.unified", "modified.split"].contains(c["name"] as! String) {
                let native = c["native"] as! [String: Any]
                let list = DiffListView()
                list.style = native["style"] as? String == "split" ? .split : .unified
                list.setDiff(UnifiedDiff(native["patch"] as! String), collapsedByDefault: false)
                try capture("diff-" + (c["name"] as! String), list, NSSize(width: 800, height: 360))
            }
            let context = SettingsPagesFidelityTests.context()
            context.configs = ["a": try PickersFidelityTests.recordedConfig()]
            for section in DitherSettingsSection.allCases {
                let pages = section.slices.map { Self.page($0.page, context: context) as NSView & SettingsGroupRow }
                let page = DitherSettingsSectionView(section: section, pages: pages)
                try capture("settings-" + section.rawValue, page, NSSize(width: 800, height: min(1800, max(100, page.height(forWidth: 800)))))
            }
        }
        #expect(count == 80)
        print("Redesign baseline: \(count) images; failure artifacts: \(Self.output.path)")
    }

    static func page(_ section: SettingsSection, context: SettingsPageContext) -> NSView & SettingsGroupRow {
        switch section {
        case .connections: ConnectionsFidelityTests.make(["kind": "rows"], size: NSSize(width: 800, height: 600)) as! ConnectionsSettingsView
        case .appearance: AppearanceSettingsView(context: context)
        case .providers: ProvidersSettingsView(context: context)
        case .keybindings: KeybindingsSettingsView(context: context)
        case .projects: ProjectSettingsView(context: context)
        case .storage: StorageSettingsView(context: context)
        case .sourceControl: SourceControlSettingsView(context: context, discoveryEnabled: false)
        case .archive: ArchiveSettingsView(context: context)
        case .scheduledTasks: ScheduledTasksSettingsView(context: context)
        case .orchestrator: OrchestratorSettingsView(context: context)
        case .connectors: ConnectorsSettingsView(context: context)
        case .experimental: ExperimentalSettingsView(context: context)
        case .beta: BetaSettingsView(context: context)
        case .integrations: IntegrationsSettingsView(context: context)
        case .snapShots: SnapShotSettingsView(context: context)
        default: GeneralSettingsView(context: context)
        }
    }

    static func compare(_ reference: NSBitmapImageRep, _ ours: NSBitmapImageRep, name: String) throws {
        let sameSize = reference.pixelsWide == ours.pixelsWide && reference.pixelsHigh == ours.pixelsHigh
        if !sameSize { Issue.record("\(name): dimensions changed; diff: \(output.path)/\(name).diff.png") }
        let w = ours.pixelsWide, h = ours.pixelsHigh
        let a = SidebarFidelityTests.pixels(reference, w, h), b = SidebarFidelityTests.pixels(ours, w, h)
        guard !sameSize || a != b else { return }
        let diff = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: w * 4, bitsPerPixel: 32)!
        var different = 0
        for i in stride(from: 0, to: a.count, by: 4) {
            let changed = !sameSize || (0..<4).contains { a[i + $0] != b[i + $0] }
            if changed { different += 1 }
            diff.bitmapData![i] = changed ? 255 : b[i] / 3
            diff.bitmapData![i + 1] = changed ? 0 : b[i + 1] / 3
            diff.bitmapData![i + 2] = changed ? 255 : b[i + 2] / 3
            diff.bitmapData![i + 3] = 255
        }
        try Snapshot.writePNG(diff, to: output.appendingPathComponent(name + ".diff.png"))
        try Snapshot.writePNG(ours, to: output.appendingPathComponent(name + ".ours.png"))
        Issue.record("\(name): \(different) pixels differ (threshold 0); diff: \(output.path)/\(name).diff.png")
    }

    /// Snapshot's offscreen layer renderer, with synchronous art and animations at their model end state.
    /// Art normally arrives after a debounce on a worker; capture fixed pixels before that work can run.
    static func image(_ view: NSView, size: NSSize, dark: Bool) -> NSBitmapImageRep {
        let canvas = ConnectionsFidelityTests.Canvas(frame: NSRect(origin: .zero, size: size))
        canvas.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        view.frame = canvas.bounds; canvas.addSubview(view)
        let window = NSWindow(contentRect: canvas.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = canvas
        defer { window.contentView = nil }
        func layout(_ v: NSView) {
            v.needsLayout = true; v.layoutSubtreeIfNeeded(); v.subviews.forEach(layout)
        }
        let art = DitherArtView.sync(nil, in: canvas)
        if view is DitherSettingsSectionView { DitherArtView.setEmphasis(.settings, from: view) }
        defer { DitherArtView.setEmphasis(nil, from: view); art?.removeFromSuperview() }
        layout(canvas); window.display(); CATransaction.flush()
        let thumbnail = NSBitmapImageRep(data: try! Data(contentsOf: ComposerAttachmentsFidelityTests.fixture))!.cgImage!
        func display(_ v: NSView) {
            if let image = v as? AsyncImageView {
                image.set(key: "baseline-" + (image.key ?? "image"), fallbackText: "", loader: nil, preview: thumbnail)
            }
            v.displayIfNeeded()
            if let art = v as? DitherArtView, let layer = art.layer?.sublayers?.first {
                let bg = ThemeRuntime.palettes.palette(dark: dark, sidebar: false).background.srgb
                layer.frame = art.bounds
                layer.contents = DitherArt.render(.init(url: ComposerAttachmentsFidelityTests.fixture,
                    width: Int(ceil(art.bounds.width / DitherArt.dot)), height: Int(ceil(art.bounds.height / DitherArt.dot)),
                    background: [bg.x, bg.y, bg.z], scale: 2))
            }
            if let scroller = v as? ScrollAreaScroller { scroller.isHidden = true }
            v.subviews.forEach(display)
        }
        display(canvas)
        func freeze(_ layer: CALayer) {
            layer.removeAllAnimations(); layer.contentsScale = 2
            if layer.delegate != nil || type(of: layer) != CALayer.self { layer.setNeedsDisplay() }
            layer.displayIfNeeded(); layer.sublayers?.forEach(freeze)
        }
        if let layer = canvas.layer { freeze(layer) }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!.retagging(with: .sRGB)!
        rep.size = size
        let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
        ctx.translateBy(x: 0, y: size.height); ctx.scaleBy(x: 1, y: -1)
        canvas.layer?.render(in: ctx)
        return rep
    }

    // Reuses the DesignSystem fidelity fixture (that test target cannot be imported).
    static func palette(_ name: String) -> CommandPaletteView {
        let v: CommandPaletteView
        switch name {
        case "root":
            v = CommandPaletteView(content: .results([CommandPaletteGroup("Actions", [
                CommandPaletteItem("New thread in ", icon: .squarePen, shortcut: "⇧⌘O", titleEmphasis: "demo-repo"),
                CommandPaletteItem("New thread in...", icon: .squarePen, isSubmenu: true),
                CommandPaletteItem("Add project", icon: .folderPlus),
                CommandPaletteItem("Change appearance", icon: .monitor, shortcut: "⌥⇧⌘A", isSubmenu: true),
                CommandPaletteItem("Open settings", icon: .settings),
            ])]))
            v.highlightedIndex = 0
        case "submenu":
            v = CommandPaletteView(content: .results([CommandPaletteGroup("Change appearance", [
                CommandPaletteItem("System", icon: .monitor, note: "Current"),
                CommandPaletteItem("Light", icon: .sun),
                CommandPaletteItem("Dark", icon: .moon),
            ])]))
            v.input.placeholder = "Search..."
            v.showsBackButton = true
            v.showsBackHint = true
        default:
            v = CommandPaletteView(content: .empty(message: nil, actionsOnly: false))
            v.input.text = "zzzz"
        }
        v.footerActionLabel = "Select"
        return v
    }

}
