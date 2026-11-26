import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// Your messages at Nightly 4928 against design/component-reference/user-message (scripts/gen-user-message-spec.py):
/// a burst, a file card and the model switch divider. The reference leaves out the hover actions row, which
/// is invisible at rest, so the canvas crops whatever the native row draws below the bubble.
/// The media cases load the spec's own PNGs through a thread model, as the row loads sent images.
@MainActor @Suite(.fidelity)
struct UserMessageFidelityTests {
    /// Per-case ceilings, set 2026-11-19 in line with the thread view's neighbors (FidelitySupport.swift).
    static let ceilings: FidelityCeilings = [
        "userMessage": .init(0.06),
    ]
    static let harnessed: Set<String> = ["burst", "file-card", "model-switch", "quote-card", "media.above-text", "media.image-only", "media.collage"]
    /// The rows hold their model weakly.
    static var model: ThreadViewModel?

    static func row(_ text: String, next: Bool = false, previous: Bool = false, attachments: [JSONValue] = [], model: ThreadViewModel? = nil) -> UserMessageRowView {
        let message = ChatMessage(id: MessageId("m-\(text.count)-\(next)-\(previous)"), role: .user, text: text,
                                  createdAt: T3Timestamp("2026-10-29T12:00:00Z"), attachments: attachments)
        var row = TimelineRow(id: message.id.rawValue, createdAt: message.createdAt,
            kind: .message(message, projectedItem: nil, showAssistantMeta: false,
                           showAssistantCopyButton: false, assistantCopyStreaming: false))
        row.groupedWithNext = next
        row.groupedWithPrevious = previous
        let view = UserMessageRowView()
        view.context = TimelineContext()
        view.context.model = model
        view.configure(TimelineItem(row: row))
        return view
    }

    static func view(_ native: [String: String], html: String, width: CGFloat) -> [NSView] {
        switch native["kind"] {
        case "media":
            // The spec's images in order, by the names it gives them.
            let names = native["images"]!.split(separator: ",").map { $0 == "wide" ? "screenshot" : String($0) }
            let data = html.components(separatedBy: "src=\"data:image/png;base64,").dropFirst().map { Data(base64Encoded: String($0.prefix { $0 != "\"" }))! }
            var images: [String: CGImage] = [:]
            var attachments: [JSONValue] = []
            for (name, png) in zip(names, data) {
                images[name] = NSBitmapImageRep(data: png)!.cgImage!
                attachments.append(.object(["id": .string(name), "type": .string("image"), "name": .string("\(name).png"),
                                            "mimeType": .string("image/png"), "sizeBytes": .number(Double(png.count))]))
            }
            let model = ThreadViewModel()
            let loaded = images
            model.attachmentImage = { id, _, _ in loaded[id] }
            Self.model = model
            let v = row(native["text"]!, attachments: attachments, model: model)
            v.frame = NSRect(x: 8, y: 8, width: width, height: v.height(forWidth: width))
            return [v]
        case "burst":
            let texts = native["texts"]!.split(separator: "|").map(String.init)
            let first = row(texts[0], next: true), second = row(texts[1], previous: true)
            let h1 = first.height(forWidth: width)
            first.frame = NSRect(x: 8, y: 8, width: width, height: h1)
            second.frame = NSRect(x: 8, y: 8 + h1, width: width, height: second.height(forWidth: width))
            return [first, second]
        case "file-card":
            let file: JSONValue = .object(["id": .string("file-1"), "type": .string("file"), "name": .string(native["name"]!),
                                           "mimeType": .string("text/plain"), "sizeBytes": .number(Double(native["bytes"]!)!)])
            let v = row("", attachments: [file])
            v.frame = NSRect(x: 8, y: 8, width: width, height: v.height(forWidth: width))
            return [v]
        case "quote":
            // The spec's card quotes with context on both sides (AssistantCitationChip.tsx:59-150).
            let citation = ThreadAssistantCitation(environmentId: "e", threadId: "t", messageId: "m", text: native["text"]!, start: 40,
                                                   end: 40 + native["text"]!.count, prefix: "the loader reads the file, then ",
                                                   suffix: " before it", comment: native["comment"])
            let v = row(citation.markdown)
            v.frame = NSRect(x: 8, y: 8, width: width, height: v.height(forWidth: width))
            return [v]
        default:
            let divider = HandoffDividerView(frame: NSRect(x: 8, y: 8, width: width, height: 40))
            divider.configure(label: native["label"]!)
            return [divider]
        }
    }

    @Test func userMessage() async throws {
        let repo = SidebarFidelityTests.repo
        let refDir = repo.appendingPathComponent("design/component-reference/user-message")
        let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: repo.appendingPathComponent("design/component-reference/user-message.json"))) as! [String: Any]
        let out = Fidelity.root.appendingPathComponent("user-message")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var lines: [(String, Double)] = []
        for c in spec["cases"] as! [[String: Any]] {
            let name = c["name"] as! String, native = c["native"] as! [String: String]
            guard Self.harnessed.contains(name) else { continue }
            for theme in spec["themes"] as! [String] {
                let base = "\(name).rest.\(theme)"
                let ref = try #require(NSBitmapImageRep(data: Data(contentsOf: refDir.appendingPathComponent("\(base).png"))))
                let size = NSSize(width: CGFloat(ref.pixelsWide) / 2, height: CGFloat(ref.pixelsHigh) / 2)
                let canvas = SidebarSearchFidelityTests.Canvas(frame: NSRect(origin: .zero, size: size))
                let views = Self.view(native, html: c["html"] as! String, width: 640)
                for v in views { canvas.addSubview(v) }
                canvas.layoutSubtreeIfNeeded()
                if native["kind"] == "media" {
                    await AsyncImageView.loadAll(in: canvas)
                    for v in views { v.frame.size.height = (v as! UserMessageRowView).height(forWidth: 640) }
                    canvas.layoutSubtreeIfNeeded()
                }
                let ours = Snapshot.image(of: canvas, size: size, scale: 2, dark: theme == "dark")
                let (total, _, diff) = SidebarFidelityTests.compare(ref, ours, bands: [])
                try Snapshot.writePNG(ours, to: out.appendingPathComponent("\(base).ours.png"))
                try Snapshot.writePNG(diff, to: out.appendingPathComponent("\(base).diff.png"))
                lines.append((base, total))
                print("user-message \(base): \(String(format: "%.2f", total * 100))%")
            }
        }
        Self.ceilings.check("userMessage", lines)
        let mean = lines.map(\.1).reduce(0, +) / Double(max(1, lines.count))
        print(String(format: "FIDELITY user-message: %d cases, mean differing %.2f%%", lines.count, mean * 100))
    }
}

/// The sidebar footer's undo notice at Nightly 4928 (scripts/gen-sidebar-footer-spec.py).
@MainActor @Suite(.fidelity)
struct SidebarFooterFidelityTests {
    /// Per-case ceilings, set 2026-11-19 in line with SidebarLeftoversFidelityTests (FidelitySupport.swift).
    static let ceilings: FidelityCeilings = [
        "sidebarFooter": .init(0.06),
    ]

    @Test func undoNotice() throws {
        let repo = SidebarFidelityTests.repo
        let refDir = repo.appendingPathComponent("design/component-reference/sidebar-footer")
        let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: repo.appendingPathComponent("design/component-reference/sidebar-footer.json"))) as! [String: Any]
        let out = Fidelity.root.appendingPathComponent("sidebar-footer")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var lines: [(String, Double)] = []
        for c in spec["cases"] as! [[String: Any]] {
            let name = c["name"] as! String, native = c["native"] as! [String: String]
            for theme in spec["themes"] as! [String] {
                let base = "\(name).rest.\(theme)"
                let ref = try #require(NSBitmapImageRep(data: Data(contentsOf: refDir.appendingPathComponent("\(base).png"))))
                let size = NSSize(width: CGFloat(ref.pixelsWide) / 2, height: CGFloat(ref.pixelsHigh) / 2)
                let canvas = SidebarSearchFidelityTests.SidebarBox(frame: NSRect(origin: .zero, size: size))
                let notice = SidebarUndoNoticeView(frame: NSRect(x: 8, y: 8, width: CGFloat(Double(native["width"]!)!), height: 24))
                notice.inFooterRow = true
                notice.shortcut = "⌘Z"
                notice.text = native["summary"]!
                canvas.addSubview(notice)
                canvas.layoutSubtreeIfNeeded()
                let ours = Snapshot.image(of: canvas, size: size, scale: 2, dark: theme == "dark")
                let (total, _, diff) = SidebarFidelityTests.compare(ref, ours, bands: [])
                try Snapshot.writePNG(ours, to: out.appendingPathComponent("\(base).ours.png"))
                try Snapshot.writePNG(diff, to: out.appendingPathComponent("\(base).diff.png"))
                lines.append((base, total))
                print("sidebar-footer \(base): \(String(format: "%.2f", total * 100))%")
            }
        }
        Self.ceilings.check("sidebarFooter", lines)
    }
}
