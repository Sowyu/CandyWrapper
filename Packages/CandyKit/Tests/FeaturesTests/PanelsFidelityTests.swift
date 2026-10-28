import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// The 3824 question and composer at their established crops. The old approval drawer crop now
/// checks that the drawer is absent; PanelScreensFidelityTests also checks its new inline row.
/// Redesign's question fixtures remain separate from these sandbox screen fixtures.
@MainActor @Suite(.fidelity)
struct PanelsFidelityTests {
    /// Per-case ceilings, measured 2026-10-22 plus margin (FidelitySupport.swift).
    static let ceilings: FidelityCeilings = [
        "dockedInPanel": .init(0.115),
        "panels": .init(0.04),
    ]
    static let out = Fidelity.root.appendingPathComponent("panels")
    /// Main panel: 844 wide at x 256; banner x and width inside it.
    static let panelWidth: CGFloat = 844, bannerX: CGFloat = 76, bannerWidth: CGFloat = 692

    static let purpose = UserInputQuestion(
        id: "What should the small CLI tool do?", header: "Purpose", question: "What should the small CLI tool do?",
        options: [
            .init(label: "Transform files", description: "Read input files and write converted or cleaned output, such as formatting or renaming."),
            .init(label: "Query data", description: "Look up or summarise information from a local file, database, or API."),
            .init(label: "Automate a workflow", description: "Chain existing commands or scripts together to run a repeatable task."),
            .init(label: "Something else", description: "Describe the purpose in your own words."),
        ])
    static let language = UserInputQuestion(
        id: "Which language or runtime should it be written in?", header: "Language", question: "Which language or runtime should it be written in?",
        options: [.init(label: "Python (Recommended)", description: "Fast to write, standard library covers most CLI needs, no build step.")])

    /// The original and -3473 image sets remain unchanged.
    static func file(_ reference: String, _ theme: String) -> String {
        "design/reference-3824/\(reference).\(theme).png"
    }

    static let screenPurpose = UserInputQuestion(
        id: "purpose", header: "Purpose", question: "What is the purpose of this session?",
        options: [
            .init(label: "Learning", description: "Walk through the code and explain how it works."),
            .init(label: "Automation", description: "Script repeated tasks so they run without manual steps."),
            .init(label: "Integration", description: "Connect this project to another service, API, or tool."),
            .init(label: "General use", description: "Everyday coding and edits with no specific goal."),
        ])

    /// The banner view and the composer top (css px) measured on the capture.
    static func banner(_ reference: String) -> (ComposerBannerView, CGFloat, CGFloat) {
        if reference == "05-approval-request" {
            let panel = ApprovalPanelView()
            panel.configure(PendingApproval(requestId: "r", requestKind: .fileChange, createdAt: nil, detail: "approval-demo.txt",
                                            appName: nil, options: nil, canRespond: true), pendingCount: 1, threadId: "t")
            return (panel, panel.preferredHeight(width: bannerWidth), 616)
        }
        let panel = QuestionPanelView()
        panel.configure(PendingUserInput(requestId: "q", createdAt: nil, questions: [screenPurpose, language], responseCapability: "live",
                                         dismissible: true), threadId: "t")
        return (panel, panel.preferredHeight(width: bannerWidth), 644.5)
    }

    static func render(_ reference: String, dark: Bool) -> (NSBitmapImageRep, CGFloat, CGFloat) {
        let (view, height, composerTop) = banner(reference)
        let container = DSView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: 780))
        container.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let top = composerTop + ComposerBannerView.overlap - height
        view.frame = NSRect(x: bannerX, y: top, width: bannerWidth, height: height)
        if reference != "05-approval-request" { container.addSubview(view) }
        container.layoutSubtreeIfNeeded()
        return (Snapshot.image(of: ThreadFidelityTests.onSurface(container), size: container.frame.size, scale: 2, dark: dark), top, composerTop)
    }

    @Test func panels() throws {
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        var lines: [String] = [], cases: [(String, Double)] = [], images = ""
        for reference in ["05-approval-request", "06-user-input-request"] {
            for theme in ["light", "dark"] {
                let full = try #require(NSBitmapImageRep(data: Data(contentsOf: SidebarFidelityTests.repo.appendingPathComponent(Self.file(reference, theme)))))
                let (rendered, top, composerTop) = Self.render(reference, dark: theme == "dark")
                // The banner plus 8px of surface around it, down to the composer's top edge.
                let rect = CGRect(x: Self.bannerX - 8, y: top - 8, width: Self.bannerWidth + 16, height: composerTop - top + 8)
                let px = CGRect(x: rect.minX * 2, y: rect.minY * 2, width: rect.width * 2, height: rect.height * 2)
                let offset = CGFloat(full.pixelsWide) - Self.panelWidth * 2
                let ref = NSBitmapImageRep(cgImage: full.cgImage!.cropping(to: px.offsetBy(dx: offset, dy: 0))!)
                let ours = NSBitmapImageRep(cgImage: rendered.cgImage!.cropping(to: px)!)
                let (total, _, diff) = SidebarFidelityTests.compare(ref, ours, bands: [("all", 0, Int(rect.height))])
                let base = "\(reference).\(theme)"
                try ref.representation(using: .png, properties: [:])!.write(to: Self.out.appendingPathComponent("\(base).ref.png"))
                try Snapshot.writePNG(ours, to: Self.out.appendingPathComponent("\(base).ours.png"))
                try Snapshot.writePNG(diff, to: Self.out.appendingPathComponent("\(base).diff.png"))
                let line = "\(base): \(String(format: "%.2f", total * 100))% differ"
                print("panels", line)
                lines.append(line)
                cases.append((base, total))
                images += "<p>\(line)<br>" + ["ref", "ours", "diff"].map { "<img style='zoom:.5' src='panels/\(base).\($0).png'>" }.joined() + "</p>"
                #expect(total < 0.05, "\(line)")
            }
        }
        Self.ceilings.check("panels", cases)
        let html = "<!doctype html><meta charset=utf-8><title>Panels</title><body style='font:13px -apple-system'>" + images
        try html.write(to: Self.out.deletingLastPathComponent().appendingPathComponent("report-panels.html"), atomically: true, encoding: .utf8)
    }

    @Test func approvalActionsSendTheRecordedPayloads() throws {
        let panel = ApprovalPanelView()
        let approval = PendingApproval(requestId: "r1", requestKind: .command, createdAt: nil, detail: "ls", appName: nil,
                                       options: nil, canRespond: true)
        panel.configure(approval, pendingCount: 2, threadId: "t1")
        var sent: [(ApprovalDecision, JSONValue)] = []
        panel.onRespond = { sent.append(($0, $1)) }
        let buttons = panel.subviews.compactMap { $0 as? ButtonView }.filter { $0.title != nil }
        #expect(buttons.map(\.title) == ["Decline", "Approve"])
        buttons[1].performAction()
        #expect(sent.first?.0 == .accept)
        #expect(sent.first?.1["decision"] == .string("accept") && sent.first?.1["requestId"] == .string("r1"))
        // Not live: nothing goes out.
        panel.configure(PendingApproval(requestId: "r2", requestKind: .command, createdAt: nil, detail: nil, appName: nil,
                                        options: nil, canRespond: false), pendingCount: 1, threadId: "t1")
        panel.subviews.compactMap { $0 as? ButtonView }.filter { $0.title == "Approve" }.first?.performAction()
        #expect(sent.count == 1)
    }

    @Test func inlineApprovalUsesTheSameResponseGuards() throws {
        let view = PendingApprovalInlineView()
        let approval = PendingApproval(requestId: "r", requestKind: .fileChange, createdAt: nil,
                                       detail: "approval-3824.txt", appName: nil, options: nil, canRespond: true)
        var sent: [JSONValue] = []
        view.onRespond = { sent.append($0) }
        view.configure(approval, threadId: "t", enabled: true)
        let accept = try #require(view.subviews.compactMap { $0 as? ThreadStatusLineAction }.first { $0.label.text == "Approve" })
        accept.performAction()
        #expect(sent.count == 1)
        #expect(sent[0]["threadId"] == .string("t"))
        #expect(sent[0]["requestId"] == .string("r"))
        #expect(sent[0]["decision"] == .string("accept"))
        view.configure(approval, threadId: "t", enabled: false)
        accept.performAction()
        #expect(sent.count == 1)
        var expired = approval
        expired.canRespond = false
        view.configure(expired, threadId: "t", enabled: true)
        accept.performAction()
        #expect(sent.count == 1)
    }

    @Test func questionKeysAndAutoAdvance() async throws {
        let panel = QuestionPanelView()
        panel.configure(PendingUserInput(requestId: "q", createdAt: nil, questions: [Self.purpose, Self.language],
                                         responseCapability: "live", dismissible: true), threadId: "t")
        var submitted: JSONValue?
        panel.onSubmit = { submitted = $0 }
        let two = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                               context: nil, characters: "2", charactersIgnoringModifiers: "2", isARepeat: false, keyCode: 19))
        #expect(panel.handleKey(two))
        #expect(panel.session?.progress.selectedOptionValues == ["Query data"])
        try await Task.sleep(nanoseconds: 350_000_000)
        #expect(panel.session?.progress.questionIndex == 1)
        // The second question has one option, so 2 does nothing; free text answers it.
        #expect(!panel.handleKey(two))
        panel.setCustomAnswer("Rust please")
        panel.advance()
        #expect(submitted?["answers"] == .object([
            Self.purpose.id: .string("Query data"), Self.language.id: .string("Rust please")]))
    }

    /// The docked states in the real thread panel: the banner in the drawer slot and the composer
    /// under it (the full composer with Stop under an approval; `pt-2`, Stop and the Next pill with a question). The
    /// band runs from the banner's top to the panel's bottom.
    @Test func dockedInPanel() throws {
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        var lines: [String] = [], cases: [(String, Double)] = [], images = ""
        for reference in ["05-approval-request", "06-user-input-request"] {
            for theme in ["light", "dark"] {
                let dark = theme == "dark"
                let pickers = PickersPreview.pickers()
                let panel = ComposerFidelityTests.panel(width: Self.panelWidth, dark: dark)
                let projection = try #require(try ThreadPreview.projection(titled: ThreadPreview.markdownThread))
                panel.setProjection(projection, projectTitle: "demo-repo", workspaceRoot: nil)
                panel.composer.footerControls = [pickers.controlsView]
                panel.composer.runState = ComposerLogic.RunState(activeRunId: RunId("run"), running: true)
                var placeholder = ComposerLogic.PlaceholderInput()
                if reference == "05-approval-request" {
                    panel.approvalPanel.configure(PendingApproval(requestId: "r", requestKind: .fileChange, createdAt: nil,
                        detail: "approval-demo.txt", appName: nil, options: nil, canRespond: true), pendingCount: 1, threadId: "t")
                    panel.drawer = .none
                    panel.timeline.isHidden = true
                    // The reference thread runs Supervised, which is what asks for the approval.
                    PickerMenuView(entries: pickers.accessEntries(), style: .select, minimumWidth: 264).pick(0)
                    placeholder.approvalPending = true
                    panel.composer.pending = .approval
                } else {
                    panel.questionPanel.configure(PendingUserInput(requestId: "q", createdAt: nil, questions: [Self.screenPurpose, Self.language],
                        responseCapability: "live", dismissible: true), threadId: "t")
                    panel.drawer = .question
                    placeholder.questionChoiceOnly = false
                    panel.composer.pending = .question(.init(label: "Next question", compactLabel: "Next", enabled: false,
                                                             showsPrevious: false, responding: false, showsAttach: true))
                }
                panel.composer.placeholderInput = placeholder
                panel.layoutSubtreeIfNeeded()
                panel.timeline.scroll(toFraction: 1)
                let banner: NSView = reference == "05-approval-request" ? panel.approvalPanel : panel.questionPanel
                let top = reference == "05-approval-request"
                    ? panel.composer.frame.minY + ComposerBannerView.overlap - panel.approvalPanel.preferredHeight(width: Self.bannerWidth) - 8
                    : banner.frame.minY - 8
                let rendered = Snapshot.image(of: ThreadFidelityTests.onSurface(panel), size: panel.frame.size, scale: 2, dark: dark)
                let full = try #require(NSBitmapImageRep(data: Data(contentsOf: SidebarFidelityTests.repo.appendingPathComponent(Self.file(reference, theme)))))
                let w = Int(Self.panelWidth * 2), h = Int((780 - top) * 2)
                let ref = NSBitmapImageRep(cgImage: full.cgImage!.cropping(to: CGRect(x: full.pixelsWide - w, y: Int(top * 2), width: w, height: h))!)
                let ours = NSBitmapImageRep(cgImage: rendered.cgImage!.cropping(to: CGRect(x: 0, y: Int(top * 2), width: w, height: h))!)
                let (total, _, diff) = SidebarFidelityTests.compare(ref, ours, bands: [("all", 0, h / 2)])
                let base = "\(reference).docked.\(theme)"
                try ref.representation(using: .png, properties: [:])!.write(to: Self.out.appendingPathComponent("\(base).ref.png"))
                try Snapshot.writePNG(ours, to: Self.out.appendingPathComponent("\(base).ours.png"))
                try Snapshot.writePNG(diff, to: Self.out.appendingPathComponent("\(base).diff.png"))
                let line = "\(base): \(String(format: "%.2f", total * 100))% differ, composer \(panel.composer.frame.height) tall"
                print("panels", line)
                lines.append(line)
                cases.append((base, total))
                images += "<p>\(line)<br>" + ["ref", "ours", "diff"].map { "<img style='zoom:.4' src='panels/\(base).\($0).png'>" }.joined() + "</p>"
                // Light carries the composer's drop shadow, which offscreen snapshots don't draw (about 5 points of it).
                #expect(total < 0.09, "\(line)")
            }
        }
        Self.ceilings.check("dockedInPanel", cases)
        let html = "<!doctype html><meta charset=utf-8><title>Docked panels</title><body style='font:13px -apple-system'>" + images
        try html.write(to: Self.out.deletingLastPathComponent().appendingPathComponent("report-panels-docked.html"), atomically: true, encoding: .utf8)
    }
}
