import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// Fixed surface crops from the 3824 full-window captures. These complement the component
/// references and retain their existing per-surface ceilings. Coordinates are CSS points.
@MainActor @Suite(.fidelity)
struct PanelScreensFidelityTests {
    static let ceilings: FidelityCeilings = [
        "approval": .init(0.04), "palette": .init(0.065), "files": .init(0.045),
        "terminal": .init(0.035), "git": .init(0.06), "find": .init(0.055),
        "notice": .init(0.045),
    ]
    nonisolated static let names = ["05-approval-request", "07-palette-default", "08-palette-search", "11-terminal-drawer",
                        "11n-right-panel-narrow", "12-right-panel-files", "21-git-actions-menu", "22-commit-dialog",
                        "43-find-in-thread", "44-thread-details-panel", "45-go-to-file", "46-project-search",
                        "50-floating-thread-settings", "51-composer-branch-notice"]

    static func surface(_ name: String, dark: Bool) -> (NSView, CGRect, String) {
        switch name {
        case "05-approval-request":
            let view = PendingApprovalInlineView()
            view.configure(PendingApproval(requestId: "r", requestKind: .fileChange, createdAt: nil, detail: "approval-3824.txt",
                                           appName: nil, options: nil, canRespond: true), threadId: "t", enabled: true)
            return (view, CGRect(x: 310, y: 242, width: 736, height: 40), "approval")
        case "07-palette-default":
            let items = [
                CommandPaletteItem("New thread in ", icon: .squarePen, shortcut: "⇧⌘N", titleEmphasis: "demo-repo"),
                CommandPaletteItem("New thread in...", icon: .squarePen, isSubmenu: true),
                CommandPaletteItem("New thread without a project", icon: .square, shortcut: "⌥⌘N"),
                CommandPaletteItem("Triage an issue", icon: .bug, description: "An agent investigates a T3 Code problem and helps file an issue"),
                CommandPaletteItem("Go to file", icon: .fileSearch, shortcut: "⌘P"),
                CommandPaletteItem("Search project contents", icon: .listFilter, shortcut: "⇧⌘F"),
                CommandPaletteItem("New project", icon: .folderGit2),
                CommandPaletteItem("Add project", icon: .folderPlus),
                CommandPaletteItem("Change theme", icon: .palette, shortcut: "⌥⌘A", isSubmenu: true),
                CommandPaletteItem("Open settings", icon: .settings),
            ]
            let view = CommandPaletteView(content: .results([CommandPaletteGroup("Actions", items)]))
            view.highlightedIndex = 0
            return (view, CGRect(x: 262, y: 78, width: 576, height: 420), "palette")
        case "08-palette-search":
            var thread = CommandPaletteItem("Document Hello Demo", icon: .messageSquare, description: "demo-repo · Local", timestamp: "1h ago")
            thread.makeDescription = { PaletteThreadSubtitleView(project: ProjectIconSource(title: "demo-repo", workspaceRoot: "/tmp/demo-repo"), text: "demo-repo · Local", driver: "claudeAgent") }
            var rows: [(String, String, Bool, String)] = [
                ("Create Approval Text File", "You: …containing hello.", true, dark ? "2m ago" : "7m ago"),
                ("Create Approval Demo File", "You: …containing hello.", true, "1h ago"),
                ("Run Basic Shell Commands", "Agent: The directory has hello.py, README.md, and src, with no uncommitted changes.", false, "1h ago"),
                ("Format a Markdown Reply", "Agent: …-> str: return f\"hello {name}\" typescript const greet = (name: string): string", false, "1h ago"),
            ]
            if !dark { rows = [rows[3]] + Array(rows.prefix(3)) }
            let matches = rows.map { title, match, user, time in
                var row = CommandPaletteItem(title, icon: .messageSquare, timestamp: time, match: match)
                row.matchIsUser = user
                row.note = "demo-repo"
                row.noteAfterTitle = true
                if title == "Create Approval Text File" { row.makeLeading = { PaletteThreadStatusView(.init(label: .pendingApproval, pulse: false)) } }
                if title == "Create Approval Demo File" { row.makeLeading = { PaletteThreadStatusView(.init(label: .completed, pulse: false)) } }
                if let r = match.range(of: "hello", options: .caseInsensitive) {
                    row.matchHighlights = Array(match.distance(from: match.startIndex, to: r.lowerBound)..<match.distance(from: match.startIndex, to: r.upperBound))
                }
                return row
            }
            let view = CommandPaletteView(content: .results([CommandPaletteGroup("Threads", [thread]), CommandPaletteGroup("In messages", matches)]))
            view.input.text = "hello"
            view.footerActionLabel = "Select"
            return (view, CGRect(x: 262, y: 78, width: 576, height: 410), "palette")
        case "11-terminal-drawer":
            let view = TerminalDrawerView()
            let surface = TerminalSurfaceView()
            surface.terminal.isHidden = true
            view.surface = surface
            return (view, CGRect(x: 256, y: 500, width: 844, height: 280), "terminal")
        case "11n-right-panel-narrow":
            let view = SurfaceLauncherView()
            view.browserAvailable = true
            view.terminalAvailable = true
            view.browserProfiles = [("default", "Default"), ("test", "Test")]
            return (view, CGRect(x: 464, y: 52, width: 336, height: 728), "files")
        case "12-right-panel-files":
            let view = FilesPanelView()
            var model = FileTreeModel()
            model.setChildren([ProjectEntry(path: "src", isDirectory: true), ProjectEntry(path: "hello.py", isDirectory: false),
                               ProjectEntry(path: "notes.md", isDirectory: false), ProjectEntry(path: "README.md", isDirectory: false)], of: "")
            view.model = model
            var focus = FieldView.State()
            focus.focused = true
            view.searchField.input.previewState(focus)
            return (view, CGRect(x: 617, y: 52, width: 483, height: 728), "files")
        case "21-git-actions-menu":
            let view = MenuPopupView(items: [MenuItem("Commit", icon: .gitCommitHorizontal), MenuItem("Publish repository...", icon: .cloudUpload)])
            view.minimumWidth = 260
            return (view, CGRect(x: 817, y: 252, width: 260, height: 64), "git")
        case "22-commit-dialog":
            let view = CommitDialog(branch: "main", isDefaultRef: true,
                                    files: [VcsStatus.File(path: "hello.py", insertions: 3, deletions: 0),
                                            VcsStatus.File(path: "notes.md", insertions: 0, deletions: 0)], canChangeBranch: true, canWrite: true)
            return (view.dialog, CGRect(x: 294, y: 106, width: 512, height: 568), "git")
        case "43-find-in-thread":
            let view = ThreadFindBarView()
            view.present(query: "markdown", index: 0, total: 2)
            view.group.previewState(.init(focused: true))
            view.input.text = "markdown"
            return (view, CGRect(x: 808, y: 64, width: 280, height: 36), "find")
        case "44-thread-details-panel", "50-floating-thread-settings":
            let view = ThreadViewFidelityTests.card(.full, size: CGSize(width: 280, height: 230))
            view.runContext.text = "miniko"
            view.runContext.icons = [EnvironmentMachineIcon.definition("mac-mini"), IconName.folder.definition]
            view.scriptsRow = .add
            view.totals.insertions = 6
            view.openIn.primary.icon = IconName.brandFinder.definition
            return (view, CGRect(x: 808, y: 60, width: 280, height: 230), "git")
        case "45-go-to-file":
            let paths = ["hello.py", "README.md", "src/answer.ts", "notes.md"]
            let items = paths.map { path in
                var row = CommandPaletteItem((path as NSString).lastPathComponent, icon: .file, description: path)
                row.glyph = FileTypeIcon.icon(for: path)
                return row
            }
            let view = CommandPaletteView(content: .results([CommandPaletteGroup("demo-repo", items)]))
            view.input.placeholder = "Search files..."
            view.footerActionLabel = "Open file"
            view.escapeLabel = "Back"
            return (view, CGRect(x: 262, y: 78, width: 576, height: 328), "palette")
        case "46-project-search":
            let body = ContentSearchView()
            let python = "    return f\"Hello, {name}!\""
            let notes = "- `hello.py` holds a single `greet(name)` helper that returns a greeting string."
            body.apply(matches: [ProjectContentMatch(path: "hello.py", lineNumber: 5, lineContent: python, matchRanges: [.init(start: 13, end: 18)]),
                                 ProjectContentMatch(path: "notes.md", lineNumber: 2, lineContent: notes, matchRanges: [.init(start: 3, end: 8)])],
                       status: .results(count: 2, truncated: false, files: 2), empty: "No results found.")
            let view = CommandPaletteView(content: .custom(body))
            view.inputAccessory = body.accessory
            view.input.text = "hello"
            view.footerActionLabel = "Open file"
            view.escapeLabel = "Back"
            return (view, CGRect(x: 262, y: 78, width: 576, height: 420), "palette")
        default:
            let view = ComposerNoticeBannerView()
            view.apply(.init(variant: .neutral, icon: .gitBranch, title: "main", actions: ["Restore branch"], dismissible: true,
                                 titlePrefix: "Branch changed from ", titleCode: true))
            return (view, CGRect(x: 332, y: 614, width: 692, height: 34), "notice")
        }
    }

    @Test(arguments: names) func screens(_ name: String) throws {
        var fonts = FontRuntimeInput()
        fonts.smoothing = false
        FontRuntime.apply(fonts)
        defer { Fidelity.pin() }
        let out = Fidelity.root.appendingPathComponent("panel-screens")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var cases: [(String, Double)] = []
        var ceiling = ""
        for theme in ["light", "dark"] {
            let (view, rect, key) = Self.surface(name, dark: theme == "dark")
            ceiling = key
            let full = try #require(NSBitmapImageRep(data: Data(contentsOf: SidebarFidelityTests.repo.appendingPathComponent("design/reference-3824/\(name).\(theme).png"))))
            let ref = NSBitmapImageRep(cgImage: full.cgImage!.cropping(to: CGRect(x: rect.minX * 2, y: rect.minY * 2, width: rect.width * 2, height: rect.height * 2))!)
            let canvas = SidebarSearchFidelityTests.Canvas(frame: NSRect(origin: .zero, size: rect.size))
            view.frame = canvas.bounds
            if name == "51-composer-branch-notice" { view.frame.size.height += ComposerBannerView.overlap }
            canvas.addSubview(view)
            let ours = Snapshot.image(of: canvas, size: rect.size, scale: 2, dark: theme == "dark")
            let (share, _, diff) = SidebarFidelityTests.compare(ref, ours, bands: [])
            let base = "\(name).\(theme)"
            for (suffix, image) in [("ref", ref), ("ours", ours), ("diff", diff)] { try Snapshot.writePNG(image, to: out.appendingPathComponent("\(base).\(suffix).png")) }
            cases.append((base, share))
        }
        Self.ceilings.check(ceiling, cases)
    }
}
