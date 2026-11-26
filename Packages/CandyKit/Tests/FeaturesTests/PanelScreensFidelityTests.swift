import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// Fixed surface crops from the 4928 full-window captures. The data comes from the seeded sandbox-4928-ref
/// (design/reference-4928/README.md) and the text the capture run saved for each state. These complement the component
/// references and retain their existing per-surface ceilings. Coordinates are CSS points.
@MainActor @Suite(.fidelity)
struct PanelScreensFidelityTests {
    /// `approval` is 5% at the user's word on 2026-11-26 (docs/decisions.md). The case reads 4.80% light and 4.89%
    /// dark with the layout matching: Chrome's text rasterizer against CoreText, and the 4% was set when the command
    /// fit on one line, where at 4928 it wraps to two and has twice the glyph edges.
    static let ceilings: FidelityCeilings = [
        "approval": .init(0.05), "palette": .init(0.065), "files": .init(0.045),
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
            let path = "/Users/Shared/cw-sandbox-4928/demo-repo/approval-4928.txt"
            view.configure(PendingApproval(requestId: "r", requestKind: .command, createdAt: nil, detail: "printf 'hello' > \(path) && cat \(path)",
                                           appName: nil, options: nil, canRespond: true), threadId: "t", enabled: true)
            // At 4928 the command wraps to two lines above the status row.
            return (view, CGRect(x: 310, y: 242, width: 736, height: view.height(forWidth: 736)), "approval")
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
                CommandPaletteItem("Change appearance", icon: .monitor, shortcut: "⌥⇧⌘A", isSubmenu: true),
                CommandPaletteItem("Toggle theme editor", icon: .palette, shortcut: "⌥⇧⌘T"),
            ]
            let view = CommandPaletteView(content: .results([CommandPaletteGroup("Actions", items)]))
            view.highlightedIndex = 0
            return (view, CGRect(x: 262, y: 78, width: 576, height: 420), "palette")
        case "08-palette-search":
            // No thread title contains "hello" at 4928, so only "In messages" shows. Ages from the capture's text.
            let ages = dark ? ["17m ago", "16m ago", "18m ago", "19m ago"] : ["23m ago", "22m ago", "24m ago", "25m ago"]
            let rows: [(String, String, Bool, String)] = [
                ("Document greet and update notes", "You: …docstring to greet in hello.py and append the line '- Added a docstring.' to notes.md. No other changes. Reply in one short line.", true, ages[0]),
                ("Create Approval File", "You: …containing hello.", true, ages[1]),
                ("Run Shell Commands", "Agent: …three ran: ls shows hello.py, notes.md, README.md; git status --short is empty (clean); ls /nonexistent-dir failed with \"No such file or directory\".", false, ages[2]),
                ("Markdown Response Formatting Request", "Agent: …python print(\"hello from python\") typescript const add = (a: number, b: number): number => a + b; bash git status --short > [!NOTE] > This reply used no tools. Nothing in the repo changed.", false, ages[3]),
            ]
            let matches = rows.map { title, match, user, time in
                var row = CommandPaletteItem(title, icon: .messageSquare, timestamp: time, match: match)
                row.matchIsUser = user
                row.note = "demo-repo"
                row.noteAfterTitle = true
                if title == "Create Approval File" { row.makeLeading = { PaletteThreadStatusView(.init(label: .pendingApproval, pulse: false)) } }
                if title == "Document greet and update notes" { row.makeLeading = { PaletteThreadStatusView(.init(label: .completed, pulse: false)) } }
                if let r = match.range(of: "hello", options: .caseInsensitive) {
                    row.matchHighlights = Array(match.distance(from: match.startIndex, to: r.lowerBound)..<match.distance(from: match.startIndex, to: r.upperBound))
                }
                return row
            }
            let view = CommandPaletteView(content: .results([CommandPaletteGroup("In messages", matches)]))
            view.input.text = "hello"
            view.footerActionLabel = "Select"
            // Four matches: the 4928 palette ends at 326pt (its bottom border, measured on both captures).
            return (view, CGRect(x: 262, y: 78, width: 576, height: 326), "palette")
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
                                    files: [VcsStatus.File(path: "hello.py", insertions: 1, deletions: 0),
                                            VcsStatus.File(path: "notes.md", insertions: 1, deletions: 0)], canChangeBranch: true, canWrite: true)
            // The dialog sits centered in the 780pt viewport. At 4928 its `leading-snug` title (dialog.tsx:227) makes it
            // 576.5pt tall in the capture, from y 102, so the crop follows the dialog's own height.
            let h = (view.dialog.height(forWidth: 512) * 2).rounded() / 2
            return (view.dialog, CGRect(x: 294, y: ((780 - h) / 2 * 2).rounded() / 2, width: 512, height: h), "git")
        case "43-find-in-thread":
            let view = ThreadFindBarView()
            view.present(query: "markdown", index: 0, total: 2)
            view.group.previewState(.init(focused: true))
            view.input.text = "markdown"
            return (view, CGRect(x: 808, y: 64, width: 280, height: 36), "find")
        case "44-thread-details-panel", "50-floating-thread-settings":
            let view = ThreadViewFidelityTests.card(.full, size: CGSize(width: 280, height: 230))
            view.runContext.text = "Sandbox Mac"
            view.runContext.icons = [EnvironmentMachineIcon.definition("mac-mini"), IconName.folder.definition]
            view.scriptsRow = .add
            view.totals.insertions = 2
            view.changesBase = nil  // these screens predate the comparison base (#30085)
            view.openIn.primary.icon = IconName.brandFinder.definition
            return (view, CGRect(x: 808, y: 60, width: 280, height: 230), "git")
        case "45-go-to-file":
            let paths = ["hello.py", "notes.md", "README.md"]
            let items = paths.map { path in
                var row = CommandPaletteItem((path as NSString).lastPathComponent, icon: .file, description: path)
                row.glyph = FileTypeIcon.icon(for: path)
                return row
            }
            let view = CommandPaletteView(content: .results([CommandPaletteGroup("demo-repo", items)]))
            view.input.placeholder = "Search files..."
            view.footerActionLabel = "Open file"
            view.escapeLabel = "Back"
            view.highlightedIndex = 0
            // Three files: the 4928 palette ends at 278pt (its bottom border, measured on both captures).
            return (view, CGRect(x: 262, y: 78, width: 576, height: 278), "palette")
        case "46-project-search":
            let body = ContentSearchView()
            let python = "    return f\"Hello, {name}!\""
            body.apply(matches: [ProjectContentMatch(path: "hello.py", lineNumber: 3, lineContent: python, matchRanges: [.init(start: 13, end: 18)])],
                       status: .results(count: 1, truncated: false, files: 1), empty: "No results found.")
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
            let full = try #require(NSBitmapImageRep(data: Data(contentsOf: SidebarFidelityTests.repo.appendingPathComponent("design/reference-4928/\(name).\(theme).png"))))
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
