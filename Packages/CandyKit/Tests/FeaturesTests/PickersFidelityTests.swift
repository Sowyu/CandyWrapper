import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// The 3824 model picker (13), combined effort/permissions menus (41, 53), and closed footer
/// controls (03c). Popups use their border boxes at their new anchor positions. The model catalog
/// comes from the recorded 3814 sandbox reused for the 3824 captures.
/// Writes ref, ours and diff PNGs plus report-pickers.html to `Fidelity.root`.
@MainActor @Suite(.fidelity)
struct PickersFidelityTests {
    /// Per-case ceilings, measured 2026-10-22 plus margin (FidelitySupport.swift).
    static let ceilings: FidelityCeilings = [
        "popupsAgainstReferences": .init(0.055),
    ]
    static let out = Fidelity.root.appendingPathComponent("pickers")

    static func recordedConfig(transcript: String = "01-basic") throws -> ServerProviderConfig {
        let text = try String(contentsOf: SidebarFidelityTests.repo.appendingPathComponent("fixtures/transcripts/\(transcript).jsonl"), encoding: .utf8)
        var configId: String?
        for line in text.split(separator: "\n") {
            let record = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            guard record["kind"] as? String == "ws", let body = record["body"] as? [String: Any] else { continue }
            if body["tag"] as? String == "server.getConfig" { configId = body["id"] as? String }
            if body["_tag"] as? String == "Exit", body["requestId"] as? String == configId,
               let exit = body["exit"] as? [String: Any], let value = exit["value"] {
                return try JSONDecoder().decode(ServerProviderConfig.self, from: JSONSerialization.data(withJSONObject: value))
            }
        }
        throw CocoaError(.fileReadCorruptFile)
    }

    /// Pickers for a new draft with Claude Haiku 5.5 picked, nothing remembered.
    static func pickers() throws -> ComposerPickers {
        let config = try recordedConfig()
        let ctx = ComposerSelectionContext(catalog: ProviderCatalog(config.providers), serverDefaults: config.settings)
        let store = ComposerSelectionStore(defaults: nil)
        store.pickModel("draft", instance: "claudeAgent", model: "claude-haiku-5-5", ctx)
        return ComposerPickers(store: store, draftKey: "draft", context: ctx)
    }

    static func crop(_ rep: NSBitmapImageRep, _ r: CGRect) -> NSBitmapImageRep {
        NSBitmapImageRep(cgImage: rep.cgImage!.cropping(to: CGRect(x: r.minX * 2, y: r.minY * 2, width: r.width * 2, height: r.height * 2))!)
    }

    /// The popup on the page background, sized to the reference's border box.
    static func render(_ view: NSView, size: CGSize, backdrop: NSColor, dark: Bool, contentFrame: CGRect? = nil) -> NSBitmapImageRep {
        let container = DSView(frame: NSRect(origin: .zero, size: size))
        container.layer?.backgroundColor = backdrop.cgColor
        view.frame = contentFrame ?? container.bounds
        container.addSubview(view)
        return Snapshot.image(of: container, size: size, scale: 2, dark: dark)
    }

    static func color(_ rep: NSBitmapImageRep, _ x: CGFloat, _ y: CGFloat) -> NSColor {
        var p = [Int](repeating: 0, count: 4)
        rep.getPixel(&p, atX: Int(x * 2), y: Int(y * 2))
        return NSColor(srgbRed: CGFloat(p[0]) / 255, green: CGFloat(p[1]) / 255, blue: CGFloat(p[2]) / 255, alpha: 1)
    }

    struct Case {
        let reference: String
        /// Border box in CSS px, measured on the capture.
        let rect: CGRect
        /// A point of page background next to the popup, for the rounded corners.
        let backdropAt: CGPoint
        let make: @MainActor (ComposerPickers) -> (NSView, CGSize)
    }

    // Freeze the 979c85e5 Redesign inputs independently of the default-theme screen migration.
    static let redesignCases: [Case] = [
        Case(reference: "13-model-picker", rect: CGRect(x: 317, y: 411, width: 362, height: 298), backdropAt: CGPoint(x: 314, y: 420)) { p in
            let config = try! PickersFidelityTests.recordedConfig()
            let view = ModelPickerView(catalog: ProviderCatalog(config.providers), favorites: [], active: "claudeAgent", activeModel: "claude-haiku-5-5")
            // The capture focuses the search field on open (blue underline).
            var focused = view.search.state
            focused.focused = true
            view.search.previewState(focused)
            let popup = PickerPopupView(view)
            return (popup, popup.popupSize)
        },
        Case(reference: "41-traits-picker", rect: CGRect(x: 502, y: 505, width: 160, height: 204), backdropAt: CGPoint(x: 499, y: 510)) { p in
            let popup = PickerPopupView(PickerMenuView(entries: p.traitsEntries(), style: .menu, minimumWidth: 158))
            return (popup, popup.popupSize)
        },
        Case(reference: "42-access-mode-picker", rect: CGRect(x: 628, y: 515, width: 371, height: 194), backdropAt: CGPoint(x: 625, y: 520)) { p in
            let popup = PickerPopupView(PickerMenuView(entries: p.accessEntries(), style: .select, minimumWidth: 264))
            return (popup, popup.popupSize)
        },
    ]

    static let cases: [Case] = [
        Case(reference: "13-model-picker", rect: CGRect(x: 578, y: 434, width: 362, height: 283), backdropAt: CGPoint(x: 575, y: 440)) { p in
            let config = try! PickersFidelityTests.recordedConfig(transcript: "24-nightly-3814")
            let view = ModelPickerView(catalog: ProviderCatalog(config.providers), favorites: [], active: "claudeAgent", activeModel: "claude-haiku-5-5")
            // The capture focuses the search field on open (blue underline).
            var focused = view.search.state
            focused.focused = true
            view.search.previewState(focused)
            let popup = PickerPopupView(view)
            return (popup, popup.popupSize)
        },
        // 3824 ComposerControlsBar.tsx:169-190 always puts Permissions in the effort menu.
        // The old standalone 42 access select is retired; its replacement is the explicit 53 case.
        // The 3824 capture plan also routes screen 42 to that same combined menu.
        Case(reference: "41-traits-picker", rect: CGRect(x: 699, y: 382, width: 298, height: 335), backdropAt: CGPoint(x: 696, y: 390)) { p in
            let popup = PickerPopupView(p.optionsMenu(includingTraits: true))
            return (popup, popup.popupSize)
        },
        Case(reference: "53-effort-menu-permissions", rect: CGRect(x: 699, y: 382, width: 298, height: 335), backdropAt: CGPoint(x: 696, y: 390)) { p in
            let popup = PickerPopupView(p.optionsMenu(includingTraits: true))
            return (popup, popup.popupSize)
        },
    ]

    @Test func popupsAgainstReferences() throws {
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        var lines: [String] = [], cases: [(String, Double)] = [], images = ""
        for c in Self.cases {
            for theme in ["light", "dark"] {
                let full = try #require(NSBitmapImageRep(data: Data(contentsOf: SidebarFidelityTests.repo.appendingPathComponent(
                    "design/reference-3824/\(c.reference).\(theme).png"))))
                let ref = Self.crop(full, c.rect)
                let (view, natural) = c.make(try Self.pickers())
                let ours = Self.render(view, size: c.rect.size, backdrop: Self.color(full, c.backdropAt.x, c.backdropAt.y), dark: theme == "dark")
                let (total, _, diff) = SidebarFidelityTests.compare(ref, ours, bands: [])
                let base = "\(c.reference).\(theme)"
                try ref.representation(using: .png, properties: [:])!.write(to: Self.out.appendingPathComponent("\(base).ref.png"))
                try Snapshot.writePNG(ours, to: Self.out.appendingPathComponent("\(base).ours.png"))
                try Snapshot.writePNG(diff, to: Self.out.appendingPathComponent("\(base).diff.png"))
                let line = "\(base): \(String(format: "%.2f", total * 100))% differ, natural size \(natural.width)x\(natural.height) vs \(c.rect.width)x\(c.rect.height)"
                print("pickers", line)
                lines.append(line)
                cases.append((base, total))
                images += "<p>\(line)<br>" + ["ref", "ours", "diff"].map { "<img style='zoom:.5' src='pickers/\(base).\($0).png'>" }.joined() + "</p>"
                #expect(total < 0.05, "\(line)")
                #expect(abs(natural.width - c.rect.width) < 1 && abs(natural.height - c.rect.height) < 1, "\(line)")
            }
        }
        // The closed footer controls in 03c: model and effort; default permissions live in its menu.
        for theme in ["light", "dark"] {
            let full = try #require(NSBitmapImageRep(data: Data(contentsOf: SidebarFidelityTests.repo.appendingPathComponent(
                "design/reference-3824/03c-kitchen-sink-bottom.\(theme).png"))))
            let p = try Screen3824Fixtures.pickers()
            let width = p.controlsView.intrinsicContentSize.width
            // Preserve the official fractional anchor inside its enclosing 2x pixel crop.
            // Measured boxes and fonts are in fixtures/screen-3824-composer-geometry.json.
            let rect = CGRect(x: 841.5, y: 721, width: (width * 2).rounded(.up) / 2, height: 28)
            let ref = Self.crop(full, rect)
            let ours = Self.render(p.controlsView, size: rect.size, backdrop: Self.color(full, 800, 730), dark: theme == "dark",
                                   contentFrame: CGRect(x: 842.0703125 - rect.minX, y: 0, width: width, height: 28))
            let (total, _, diff) = SidebarFidelityTests.compare(ref, ours, bands: [])
            let base = "03c-footer-controls.\(theme)"
            try ref.representation(using: .png, properties: [:])!.write(to: Self.out.appendingPathComponent("\(base).ref.png"))
            try Snapshot.writePNG(ours, to: Self.out.appendingPathComponent("\(base).ours.png"))
            try Snapshot.writePNG(diff, to: Self.out.appendingPathComponent("\(base).diff.png"))
            let line = "\(base): \(String(format: "%.2f", total * 100))% differ, width \(width)"
            print("pickers", line)
            lines.append(line)
            cases.append((base, total))
            images += "<p>\(line)<br>" + ["ref", "ours", "diff"].map { "<img src='pickers/\(base).\($0).png'>" }.joined() + "</p>"
            #expect(total < 0.05, "\(line)")
        }
        Self.ceilings.check("popupsAgainstReferences", cases)
        let html = "<!doctype html><meta charset=utf-8><title>Pickers</title><body style='font:13px -apple-system'>"
            + "<p>T3 web client capture, ours, diff (red where a channel differs by more than \(SidebarFidelityTests.tolerance)/255).</p>" + images
        try html.write(to: Self.out.deletingLastPathComponent().appendingPathComponent("report-pickers.html"), atomically: true, encoding: .utf8)
    }

    /// The gallery sections render; written next to the fidelity images for eyeballing. An export tool, not a test:
    /// runs only with CW_EXPORT=1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CW_EXPORT"] != nil, "export tool, set CW_EXPORT=1"))
    func gallerySections() throws {
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        for (i, section) in PickersGallery.sections.enumerated() {
            let view = section.make()
            for theme in ["light", "dark"] {
                let image = Snapshot.image(of: view, size: view.frame.size, scale: 2, dark: theme == "dark")
                try Snapshot.writePNG(image, to: Self.out.appendingPathComponent("gallery-\(i).\(theme).png"))
            }
        }
    }

    /// Picks route through the store: model rows, trait rows, access rows, the legacy expander and
    /// keyboard navigation.
    @Test func interactions() throws {
        let p = try Self.pickers()
        var changes = 0
        p.onChange = { _ in changes += 1 }
        #expect(p.modelButton.title == "Haiku 5.5" && p.traitsButton.title == "Medium" && p.accessButton.title == "Full access")

        let config = try Self.recordedConfig()
        let view = ModelPickerView(catalog: ProviderCatalog(config.providers), favorites: [], active: "claudeAgent", activeModel: "claude-haiku-5-5")
        var picked: (ProviderInstanceId, String)?
        view.onSelect = { picked = ($0, $1) }
        #expect(view.rowViews.count == 5)
        #expect(view.handleKey(.down) && view.highlightedRow == 0)
        #expect(view.handleKey(.up) && view.highlightedRow == 4)
        #expect(view.handleKey(.enter) && view.rowViews.count == 14) // legacy expanded
        view.highlightedRow = 1
        _ = view.handleKey(.enter)
        #expect(picked?.1 == "claude-sonnet-5-5")
        view.setQuery("haiku")
        #expect(view.rowViews.count == 2 && view.highlightedRow == 0 && !view.sections.showsRail)
        view.setQuery("")
        #expect(view.handleKey(.left) && view.handleKey(.enter)) // rail focus lands on Claude, Enter keeps it

        let menu = PickerMenuView(entries: p.traitsEntries(), style: .menu, minimumWidth: 158)
        #expect(menu.selectableIndices.count == 6)
        menu.pick(menu.selectableIndices[2]) // High
        #expect(p.traitsButton.title == "High" && changes == 1)
        #expect(p.current.modelSelection == ModelSelection(instanceId: "claudeAgent", model: "claude-haiku-5-5",
                                                           selections: [.init(id: "effort", value: .string("high"))]))
        var prompt: String?
        p.onPromptChange = { prompt = $0 }
        p.prompt = "fix it"
        let again = PickerMenuView(entries: p.traitsEntries(), style: .menu, minimumWidth: 158)
        again.pick(again.selectableIndices[5]) // Ultrathink
        #expect(prompt == "Ultrathink:\nfix it")
        p.prompt = "Ultrathink:\nfix it"
        #expect(p.traitsButton.title == "Ultrathink")

        let access = PickerMenuView(entries: p.accessEntries(), style: .select, minimumWidth: 264)
        access.pick(0)
        #expect(p.accessButton.title == "Supervised" && p.current.runtimeMode == .approvalRequired)
    }
}
