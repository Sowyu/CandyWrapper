import AppKit
import Testing
@testable import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// No suspension between pinning and drawing. Scope constructor colors independently of AppKit's ambient drawing appearance.
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
                    // T3's queue at the end of the timeline (the user, 2026-11-21), the second message being edited.
                    panel.composer.runState = .init(activeRunId: RunId("run"), running: true)
                    panel.queue.state = .init(items: [
                        .init(runId: RunId("q1"), messageId: nil, text: "second queued message"),
                        .init(runId: RunId("q2"), messageId: nil, text: "third queued message")],
                        activeRunId: RunId("run"), canReorder: true, canPromoteToSteer: true)
                    panel.queue.editingRunId = RunId("q2")
                    panel.layoutSubtreeIfNeeded(); panel.timeline.scroll(toFraction: 1)
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
                if mode == "queued" { #expect(panel.queue.superview != nil && !panel.queue.isHidden) }
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
            // Math in Redesign's inks on its canvas: inline and display formulas, a matrix, cases and bad TeX in the error ink.
            let math = MarkdownView(frame: .zero)
            math.document = MarkdownDocument(parsing: ThreadPreview.mathReply, math: true)
            let mathCanvas = MarkdownFidelityTests.Canvas(frame: .zero)
            mathCanvas.addSubview(math)
            math.frame = NSRect(x: 16, y: 16, width: 640, height: math.height(forWidth: 640))
            try capture("markdown-math", mathCanvas, NSSize(width: 672, height: math.frame.height + 32))
            // The right panel card with its tab row beside the header pill, both under the window's tab band, as the app
            // lays them out: the pill in the band's strip, the thread below the band.
            let cardThread = ComposerFidelityTests.panel(width: 1200, dark: dark)
            cardThread.referenceViewportWidth = 1200
            cardThread.timeline.context.now = { Self.now }
            cardThread.setProjection(try ThreadPreview.projection(titled: ThreadPreview.markdownThread), projectTitle: "demo-repo", workspaceRoot: nil)
            let cardBand = DitherTabStripView()
            let cardHost = BandHost(band: cardBand, content: cardThread)
            cardBand.trailingAccessory = cardThread.header.pill
            cardThread.header.setThreadVisible(true)
            cardThread.mutatePanel { $0.open(.diff); $0.isOpen = true; return [] }
            try capture("thread-right-panel-diff", cardHost, NSSize(width: 1200, height: 780))
            #expect(cardThread.rightPanel.cardRow?.tabs.minY == 0)
            // The terminal drawer card split in two beside the right panel card. SwiftTerm's cells paint white offscreen, so
            // the panes show only their padding box and background, as in TerminalDrawerFidelityTests.
            let panes = ["term-1", "term-2"].map { id -> (id: String, surface: TerminalSurfaceView) in
                let surface = TerminalSurfaceView()
                surface.terminal.isHidden = true
                return (id, surface)
            }
            var terminals = TerminalDrawerState()
            terminals.newTerminal("term-1")
            terminals.split("term-2", direction: .horizontal)
            cardThread.terminalDrawer.show(panes, direction: .horizontal, activeId: "term-2",
                                           list: TerminalListModel.make(terminals, label: { TerminalLabels.label($0) }, closeShortcut: nil))
            cardThread.setTerminal(open: true, height: 260)
            try capture("thread-terminal-drawer", cardHost, NSSize(width: 1200, height: 780))
            cardThread.setTerminal(open: false, height: 260)
            let sidebar = SidebarContentView()
            sidebar.windowedMac = false; sidebar.stage = .nightly
            sidebar.now = { SidebarPreview.referenceNow }
            // The footer shows the Mac account's full name; the baselines were recorded as "mrm".
            sidebar.accountRow.set(name: "mrm", image: nil, initials: nil)
            sidebar.state = SidebarListState(activeThreadId: SidebarPreview.referenceActiveThread)
            sidebar.setSnapshot(SidebarPreview.referenceSnapshot(), animated: false)
            try capture("sidebar-many-threads", sidebar, NSSize(width: 280, height: 900))
            // A failed update pass: the capsule takes its own line in the account card and the name keeps its row.
            let footer = SidebarContentView()
            footer.windowedMac = false; footer.stage = .nightly
            footer.accountRow.set(name: "mrm", image: nil, initials: nil)
            footer.updatePill.isHidden = false
            footer.updatePill.capsule = SidebarUpdateCapsule(view: .init(tone: .failed, label: "studio failed", action: .retry), countdown: nil,
                                                             popover: .init(local: nil, rows: [], showsDismiss: false))
            try capture("sidebar-update-capsule", footer, NSSize(width: 280, height: 420))
            #expect(footer.updatePill.frame.minY >= footer.accountRow.frame.minY + SidebarAccountRowView.height)
            #expect(footer.updatePill.frame.width > 200)
            for c in PickersFidelityTests.redesignCases {
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
            // Redesign's state view in its three sizes, and the panels' empty and error states (redesign-states-2026-11-21.md).
            for (name, size, height) in [("panel", EmptyView.Size.default, 360.0), ("card", .compact, 220), ("inline", .inline, 40)] {
                let state = EmptyView(title: "", size: size)
                state.redesign = StateErrorText.describe(RedesignStatesRenderTests.SpawnFailure(), title: "Could not load changes", icon: .fileDiff)
                state.action = StateAction("Retry", icon: .refreshCw) {}
                try capture("state-" + name, state, NSSize(width: 460, height: height))
            }
            let stateSize = NSSize(width: 460, height: 600)
            try capture("diff-no-turns", RedesignStatesRenderTests.diffPanel({ "" }, summaries: false), stateSize)
            let filesError = FilesPanelView(frame: NSRect(origin: .zero, size: stateSize))
            filesError.errorText = "Reconnect to the environment and try again."
            try capture("files-error", filesError, stateSize)
            try capture("terminal-empty", TerminalDrawerView(frame: NSRect(origin: .zero, size: stateSize)), NSSize(width: 460, height: 320))
            try capture("browser-empty", BrowserEmptyStateView(frame: NSRect(origin: .zero, size: stateSize)), stateSize)
            let wall = ThreadImageWallView(frame: .zero)
            wall.images = Self.wallImages()
            try capture("image-gallery", wall, NSSize(width: 900, height: 640))
            // A failed pass on a utility page: Back keeps its own width and the capsule says the whole status.
            let utility = SidebarContentView()
            utility.windowedMac = false; utility.stage = .nightly
            utility.isOnUtilityPage = true
            utility.updatePill.isHidden = false
            utility.updatePill.capsule = SidebarUpdateCapsule(view: .init(tone: .failed, label: "studio failed", action: .retry), countdown: nil,
                                                              popover: .init(local: nil, rows: [], showsDismiss: false))
            try capture("sidebar-utility-capsule", utility, NSSize(width: 280, height: 420))
            #expect(utility.updatePill.frame.minX >= utility.backButton.frame.maxX && utility.backButton.frame.width >= 60)
            let notices = DSView(frame: NSRect(x: 0, y: 0, width: 560, height: 200))
            for (i, warning) in [false, true].enumerated() {
                let retry = ButtonView("Try again", variant: .outline, size: .sm)
                let card = LinkedThreadNoticeCard(title: warning ? "Could not refresh" : "Could not read the thread",
                                                  message: "Studio did not answer. Showing what was read before.", warning: warning, action: retry)
                card.frame = NSRect(x: 16, y: 16 + CGFloat(i) * 92, width: 528, height: card.height(forWidth: 528))
                notices.addSubview(card)
            }
            try capture("linked-thread-notice", notices, NSSize(width: 560, height: 200))
            try capture("thread-unavailable", ThreadUnavailableStateView(frame: NSRect(origin: .zero, size: stateSize)), stateSize)
            let find = DSView(frame: NSRect(x: 0, y: 0, width: 440, height: 120))
            let diffFind = DiffFindWidget()
            diffFind.countText = "2 of 5"; diffFind.hasMatches = true
            diffFind.frame = NSRect(origin: NSPoint(x: 8, y: 8), size: diffFind.preferredSize)
            find.addSubview(diffFind)
            let threadFind = ThreadFindBarView(frame: NSRect(x: 16, y: 72, width: 384, height: 36))
            threadFind.input.text = "greet"
            threadFind.present(query: "greet", index: 1, total: 4)
            find.addSubview(threadFind)
            try capture("find-panels", find, NSSize(width: 440, height: 120))
            // A choice that says what it does takes a row of its own, its note beside the button.
            let question = DSView(frame: .zero)
            let questionCard = try WorkflowsFidelityTests.make(["kind": "question"], size: NSSize(width: 560, height: 200))
            questionCard.frame.origin = NSPoint(x: 8, y: 8)
            question.addSubview(questionCard)
            try capture("workflows-question", question, NSSize(width: 576, height: questionCard.frame.height + 16))
            // A model needs a newer Claude Code: the notice is the list card's bottom row, with Provider settings.
            for stacked in [false, true] {
                try RedesignPickerSettings.$stackedOverride.withValue(stacked) {
                    try RedesignPickerSettings.$accountOverride.withValue(false) {
                        let (popup, size) = try Self.updateNoticePicker()
                        try capture("model-picker-update-notice" + (stacked ? "-stacked" : ""), popup, size)
                    }
                }
            }
            // A file past the paged viewer's limit says so with the state view.
            try capture("large-file-limit", LargeTextFileView(file: nil, sizeBytes: 600_000_000, preview: ""), NSSize(width: 460, height: 320))
            // Project avatars at the sizes they show: palette and chips, sidebar, account card, a large preview.
            for size in [CGFloat(16), 20, 28, 64] {
                let strip = DSView(frame: .zero)
                for (i, title) in ["Atlas", "atlas-web", "orbit-api", "Juniper", "pixel-forge", "tidewater"].enumerated() {
                    let v = ProjectMonogramView(ProjectIconSource(title: title, workspaceRoot: ""), size: size)
                    v.frame.origin = NSPoint(x: 8 + CGFloat(i) * (size + 8), y: 8)
                    strip.addSubview(v)
                }
                try capture("avatar-\(Int(size))", strip, NSSize(width: 16 + 6 * size + 40, height: size + 16))
            }
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
            context.nowMs = { TimestampFormat.nowMs(Self.now) }
            for section in DitherSettingsSection.allCases {
                // The original fixtures constructed fixed layer colors in Aqua, even for a dark canvas.
                // An earlier snapshot can leave a different ambient drawing appearance on this thread.
                var pages: [NSView & SettingsGroupRow] = []
                NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
                    pages = section.slices.map { Self.page($0.page, context: context) as NSView & SettingsGroupRow }
                }
                let page = DitherSettingsSectionView(section: section, pages: pages)
                try capture("settings-" + section.rawValue, page, NSSize(width: 800, height: min(1800, max(100, page.height(forWidth: 800)))))
            }
            // Settings and Usage float over the route on Redesign's solid pill surface.
            for name in ["settings-modal", "usage-modal"] {
                let page = SettingsPageView()
                page.header.isRouteModal = true
                var nav: SettingsSidebarView?
                if name.hasPrefix("settings") {
                    var pages: [NSView & SettingsGroupRow] = []
                    NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
                        pages = DitherSettingsSection.appearance.slices.map { Self.page($0.page, context: context) as NSView & SettingsGroupRow }
                    }
                    page.header.section = .appearance
                    page.page = DitherSettingsSectionView(section: .appearance, pages: pages)
                    nav = SettingsSidebarView()
                    nav?.isRouteModal = true
                    nav?.selected = .appearance
                } else {
                    page.header.plainTitle = "Usage"
                }
                try capture(name, AppRouteModalView(label: "Settings", content: page, navigation: nav), NSSize(width: 1100, height: 780))
            }
            // Tint from picture on (every other image runs with it off): the fixture picture's color in the surfaces.
            input.ditherTintFromPicture = true
            input.pictureTint = PictureTint.tint(of: try #require(DitherArt.picture(ComposerAttachmentsFidelityTests.fixture, maxPixels: 64)))
            ThemeRuntime.apply(input)
            let tintThread = ComposerFidelityTests.panel(width: 844, dark: dark)
            tintThread.timeline.context.now = { Self.now }
            tintThread.setProjection(try ThreadPreview.projection(titled: ThreadPreview.markdownThread), projectTitle: "demo-repo", workspaceRoot: nil)
            tintThread.layoutSubtreeIfNeeded(); tintThread.timeline.scroll(toFraction: 0)
            try capture("thread-markdown-top-tint", tintThread, panelSize)
            input.ditherTintFromPicture = false; input.pictureTint = nil
            ThemeRuntime.apply(input)
            // Background set to Blur: the same picture blurred, under a thread, the new-thread page, the sidebar and Settings.
            input.ditherBlur = true
            ThemeRuntime.apply(input)
            defer { input.ditherBlur = false; ThemeRuntime.apply(input) }
            let blurThread = ComposerFidelityTests.panel(width: 844, dark: dark)
            blurThread.timeline.context.now = { Self.now }
            blurThread.setProjection(try ThreadPreview.projection(titled: ThreadPreview.markdownThread), projectTitle: "demo-repo", workspaceRoot: nil)
            blurThread.layoutSubtreeIfNeeded(); blurThread.timeline.scroll(toFraction: 0)
            try capture("thread-markdown-top-blur", blurThread, panelSize)
            let blurDraft = ComposerFidelityTests.panel(width: 844, dark: dark)
            blurDraft.setDraft(projectTitle: "demo-repo")
            blurDraft.composer.footerControls = [try PickersFidelityTests.pickers().controlsView]
            try capture("composer-empty-blur", blurDraft, panelSize)
            try capture("sidebar-many-threads-blur", sidebar, NSSize(width: 280, height: 900))
            var redesignPages: [NSView & SettingsGroupRow] = []
            NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
                redesignPages = DitherSettingsSection.redesign.slices.map { Self.page($0.page, context: context) as NSView & SettingsGroupRow }
            }
            let redesignPage = DitherSettingsSectionView(section: .redesign, pages: redesignPages)
            try capture("settings-redesign-blur", redesignPage, NSSize(width: 800, height: min(1800, max(100, redesignPage.height(forWidth: 800)))))
            // Background set to Flower: the lotus above the new thread's composer and beside a wide thread's column,
            // held at the open flower (Animate off renders that one frame).
            input.ditherBlur = false; input.ditherFlower = true; input.ditherGradientAnimates = false
            ThemeRuntime.apply(input)
            defer { input.ditherFlower = false; input.ditherGradientAnimates = true; ThemeRuntime.apply(input) }
            let flowerDraft = ComposerFidelityTests.panel(width: 1100, dark: dark)
            flowerDraft.setDraft(projectTitle: "demo-repo")
            flowerDraft.composer.footerControls = [try PickersFidelityTests.pickers().controlsView]
            try capture("composer-empty-flower", flowerDraft, NSSize(width: 1100, height: 780))
            let flowerThread = ComposerFidelityTests.panel(width: 1300, dark: dark)
            flowerThread.timeline.context.now = { Self.now }
            flowerThread.setProjection(try ThreadPreview.projection(titled: ThreadPreview.markdownThread), projectTitle: "demo-repo", workspaceRoot: nil)
            flowerThread.layoutSubtreeIfNeeded(); flowerThread.timeline.scroll(toFraction: 0)
            try capture("thread-markdown-top-flower", flowerThread, NSSize(width: 1300, height: 780))
        }
        #expect(count == 144)
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
        case .redesign: RedesignSettingsView(context: context)
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
    /// The full image gallery's wall: pictures of many proportions, measured up front, so the masonry places them all.
    @MainActor static func wallImages() -> [GalleryImage] {
        let sizes: [(Int, Int)] = [(2040, 600), (1179, 2556), (64, 64), (3840, 2160), (1024, 1024), (1600, 1200), (900, 1200), (1920, 1080),
                                   (3000, 700), (800, 1200), (600, 1200), (1250, 1000), (1500, 500), (1200, 800), (200, 150), (500, 1500)]
        return sizes.enumerated().map { i, size in
            let image = GalleryImage(source: .url("https://baseline.invalid/wall-\(i).png"), threadId: "t", agent: "Main", entryId: "e\(i)",
                                     at: T3Timestamp("2026-10-28T11:\(10 + i):00Z"))
            MarkdownImages.record(CGSize(width: size.0, height: size.1), for: image.key)
            return image
        }
    }

    /// The docked picker on Claude with one model that needs Claude Code 3.2.0, which its channel can reach.
    static func updateNoticePicker() throws -> (NSView, CGSize) {
        let p = try PickersFidelityTests.pickers()
        var providers = try PickersFidelityTests.recordedConfig().providers
        let i = try #require(providers.firstIndex { $0.driver == "claudeAgent" })
        providers[i].updateRequiredModels = [.init(slug: "claude-synthetic-next", name: "Claude Synthetic Next", minVersion: "3.2.0")]
        providers[i].versionAdvisory = .object(["latestVersion": .string("3.2.1")])
        let view = ModelPickerView(catalog: ProviderCatalog(providers), favorites: [], active: "claudeAgent", activeModel: "claude-haiku-5-5")
        view.onManage = { _ in }
        view.jumpLabel = { "⌘\($0 + 1)" }
        let dock = DockedModelPickerView(picker: view)
        dock.column.update(descriptors: p.current.descriptors, ultrathink: false, locked: false, model: p.current.modelTriggerLabel(spoken: true))
        dock.footer.update(descriptors: p.current.descriptors, runtimeMode: p.current.runtimeMode)
        let popup = PickerPopupView(dock)
        return (popup, popup.popupSize)
    }

    static func image(_ view: NSView, size: NSSize, dark: Bool, inWindow: (() -> Void)? = nil) -> NSBitmapImageRep {
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
        layout(canvas)
        // A step that needs the window, such as opening a popover, then lays out again.
        if let inWindow { inWindow(); layout(canvas) }
        window.display(); CATransaction.flush()
        let thumbnail = NSBitmapImageRep(data: try! Data(contentsOf: ComposerAttachmentsFidelityTests.fixture))!.cgImage!
        func display(_ v: NSView) {
            if let image = v as? AsyncImageView {
                image.set(key: "baseline-" + (image.key ?? "image"), fallbackText: "", loader: nil, preview: thumbnail)
            }
            v.displayIfNeeded()
            if let art = v as? DitherArtView, ThemeRuntime.ditherFlower {
                // The open flower, rendered now on this thread.
                art.rendersInlineForTesting = true
                art.dropFlower()
                art.refresh()
            } else if let art = v as? DitherArtView, let layer = art.layer?.sublayers?.first {
                let palette = ThemeRuntime.palettes.palette(dark: dark, sidebar: false), bg = palette.background.srgb
                let blur = ThemeRuntime.ditherBlur, unit = blur ? DitherArt.blurPixel : ThemeRuntime.ditherDotSize.points(scale: 2)
                layer.magnificationFilter = blur ? .linear : .nearest
                layer.frame = art.bounds
                layer.contents = DitherArt.render(.init(url: ComposerAttachmentsFidelityTests.fixture,
                    width: Int(ceil(art.bounds.width / unit)), height: Int(ceil(art.bounds.height / unit)),
                    background: [bg.x, bg.y, bg.z], scale: 2, blur: blur, dark: dark, dot: unit))
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

/// A window's tab band over a page below it, as `SidebarLayoutView` lays them out under Redesign.
final class BandHost: DSView {
    let band: NSView, content: NSView
    init(band: NSView, content: NSView) {
        self.band = band; self.content = content
        super.init(frame: .zero)
        addSubview(content); addSubview(band)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        band.frame = NSRect(x: 0, y: 0, width: bounds.width, height: DitherChrome.band)
        content.frame = NSRect(x: 0, y: DitherChrome.band, width: bounds.width, height: max(0, bounds.height - DitherChrome.band))
    }
}
