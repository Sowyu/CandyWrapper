import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// The approval and question banners against design/reference 05 and 06, light and dark. Only
/// the banner is ours here: it is placed where T3 docks it (22px inside the 736px composer, its
/// bottom 17px under the composer's top) on the main panel's surface, and the compared band runs
/// from just above the banner to the composer's top edge. The data is the reference threads'
/// (fixtures/transcripts/04-threads.jsonl). Writes ref, ours and diff PNGs plus
/// report-panels.html to /tmp/candywrapper-fidelity.
@MainActor
struct PanelsFidelityTests {
    static let out = URL(fileURLWithPath: "/tmp/candywrapper-fidelity/panels")
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

    /// The banner view and the composer top (css px) measured on the capture.
    static func banner(_ reference: String) -> (ComposerBannerView, CGFloat, CGFloat) {
        if reference == "05-approval-request" {
            let panel = ApprovalPanelView()
            panel.configure(PendingApproval(requestId: "r", requestKind: .fileChange, createdAt: nil, detail: "approval-demo.txt",
                                            appName: nil, options: nil, canRespond: true), pendingCount: 1, threadId: "t")
            return (panel, panel.preferredHeight(width: bannerWidth), 694)
        }
        let panel = QuestionPanelView()
        panel.configure(PendingUserInput(requestId: "q", createdAt: nil, questions: [purpose, language], responseCapability: "live",
                                         dismissible: false), threadId: "t")
        return (panel, panel.preferredHeight(width: bannerWidth), 612)
    }

    static func render(_ reference: String, dark: Bool) -> (NSBitmapImageRep, CGFloat, CGFloat) {
        let (view, height, composerTop) = banner(reference)
        let container = DSView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: 780))
        container.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let top = composerTop + ComposerBannerView.overlap - height
        view.frame = NSRect(x: bannerX, y: top, width: bannerWidth, height: height)
        container.addSubview(view)
        container.layoutSubtreeIfNeeded()
        return (Snapshot.image(of: ThreadFidelityTests.onSurface(container), size: container.frame.size, scale: 2, dark: dark), top, composerTop)
    }

    @Test func panels() throws {
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        var lines: [String] = [], images = ""
        for reference in ["05-approval-request", "06-user-input-request"] {
            for theme in ["light", "dark"] {
                let full = try #require(NSBitmapImageRep(data: Data(contentsOf: SidebarFidelityTests.repo.appendingPathComponent(
                    "design/reference/\(reference).\(theme).png"))))
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
                images += "<p>\(line)<br>" + ["ref", "ours", "diff"].map { "<img style='zoom:.5' src='panels/\(base).\($0).png'>" }.joined() + "</p>"
                #expect(total < 0.05, "\(line)")
            }
        }
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
}
