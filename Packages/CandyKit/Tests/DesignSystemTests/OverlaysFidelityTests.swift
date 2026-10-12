import AppKit
import Testing
@testable import DesignSystem

/// Overlays fidelity: Dialog, AlertDialog, Sheet, Toast and TextBlock wrapping against T3's markup in
/// Chromium (specs from scripts/gen-overlays-spec.py). Reports: /tmp/candywrapper-fidelity/report-<component>.html.
@MainActor
struct OverlaysFidelityTests {
    static func dialog(_ n: [String: String]) -> DialogView {
        let kind: DialogView.Kind = switch n["kind"] {
        case "alertDialog": .alertDialog
        case "dialog": .dialog
        default: .sheet(DialogView.SheetSide(rawValue: n["side"]!)!)
        }
        let v = DialogView(kind: kind, title: n["title"]!, message: n["description"])
        v.isInset = n["inset"] == "true"
        if n["panel"] == "true" {
            v.panelContent = [TextBlockView(n["panelText"]!, font: DSFont.ui(14), lineHeight: 20, color: Themed.color(\.contrastPopoverForeground))]
        }
        if let footer = n["footer"] {
            v.footerVariant = DialogView.FooterVariant(rawValue: footer)!
            v.footerButtons = [ButtonView("Cancel", variant: .outline),
                               kind == .alertDialog ? ButtonView("Delete", variant: .destructive) : ButtonView("Save")]
        }
        return v
    }

    @Test func dialogs() throws {
        for component in ["dialog", "alert-dialog", "sheet"] {
            try FormsFidelityTests.run(component, title: component) { n, _, css in
                var n = n
                if component == "sheet" { n["kind"] = "sheet" }
                let v = Self.dialog(n)
                v.frame.size.width = css.width
                return v
            }
        }
    }

    @Test func toast() throws {
        try FormsFidelityTests.run("toast", title: "toast") { n, _, css in
            let v = ToastView(title: n["title"]!, message: n["description"], kind: ToastQueue.Kind(rawValue: n["kind"]!)!,
                              actionTitle: n["action"])
            v.frame.size.width = css.width
            return v
        }
    }

    @Test func textBlock() throws {
        try FormsFidelityTests.run("text-block", title: "TextBlock") { n, _, css in
            let weight: NSFont.Weight = n["weight"] == "semibold" ? .semibold : .regular
            let v = TextBlockView(n["text"]!, font: DSFont.ui(CGFloat(Double(n["font"]!)!), weight: weight),
                                  lineHeight: CGFloat(Double(n["line"]!)!),
                                  color: Themed.color(n["muted"] == "true" ? \.contrastMutedForeground : \.foreground))
            v.maxLines = Int(n["maxLines"] ?? "0")!
            if n["align"] == "center" { v.alignment = .center }
            v.frame.size.width = css.width
            return v
        }
    }

    /// Line count and break positions against Chromium: the reference heights give Chromium's line count.
    @Test func textBlockLineCountsMatchChromium() throws {
        let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: FidelityTests.repo.appendingPathComponent("design/component-reference/text-block.json"))) as! [String: Any]
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: FidelityTests.repo.appendingPathComponent("design/component-reference/text-block/manifest.json"))) as! [String: [String: Double]]
        for c in spec["cases"] as! [[String: Any]] {
            let n = c["native"] as! [String: String], name = c["name"] as! String
            let weight: NSFont.Weight = n["weight"] == "semibold" ? .semibold : .regular
            let v = TextBlockView(n["text"]!, font: DSFont.ui(CGFloat(Double(n["font"]!)!), weight: weight), lineHeight: CGFloat(Double(n["line"]!)!))
            v.maxLines = Int(n["maxLines"] ?? "0")!
            let css = manifest[name]!
            #expect(abs(v.height(forWidth: css["width"]!) - css["height"]!) < 0.01, "\(name): ours \(v.height(forWidth: css["width"]!)) chromium \(css["height"]!)")
        }
    }

    /// The `dialog-backdrop` blur substitute: how much the 4px blur changes the backdrop over real content,
    /// i.e. the error of drawing the tint alone. Content: the toggles gallery, a busy section.
    @Test func backdropBlurDifference() throws {
        let section = TogglesGallery.sections[0]
        for dark in [false, true] {
            let content = ComponentGallery.render(section, width: 520, dark: dark, scale: 1)
            let cg = content.cgImage!
            let w = cg.width, h = cg.height
            let blurred = ModalHost.blurred(cg, pointSize: CGSize(width: w, height: h))!
            let sharp = FidelityTests.pixels(NSBitmapImageRep(cgImage: cg), w, h)
            // Scaled back up to full size, as the backdrop layer shows it.
            let up = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            up.interpolationQuality = .high
            up.draw(blurred, in: CGRect(x: 0, y: 0, width: w, height: h))
            let soft = FidelityTests.pixels(NSBitmapImageRep(cgImage: up.makeImage()!), w, h)
            // Under a 60% tint only 40% of the content difference survives.
            var over = 0, total = 0
            for i in stride(from: 0, to: sharp.count, by: 4) {
                let m = (0..<3).map { abs(Int(sharp[i + $0]) - Int(soft[i + $0])) * 4 / 10 }.max()!
                total += m
                if m > FidelityTests.tolerance { over += 1 }
            }
            print(String(format: "BACKDROP %@: tint-only vs blurred, %.2f%% pixels differ, mean %.2f",
                         dark ? "dark" : "light", Double(over) / Double(w * h) * 100, Double(total) / Double(w * h)))
        }
    }

    /// The vImage blur matches Core Image's Gaussian (sigma 1, clamped edges), which it replaced to stop a
    /// Metal context being built on every ⌘K: within 2 levels per channel before the tint. Both blur the
    /// sRGB-encoded values, as Chromium (Skia) does for CSS filter functions; the old
    /// Core Image path blurred in linear light, up to 31 levels away at sharp edges.
    @Test func vImageBlurMatchesCoreImage() throws {
        let content = ComponentGallery.render(TogglesGallery.sections[0], width: 520, dark: true, scale: 1).cgImage!
        let size = CGSize(width: content.width, height: content.height)
        let ours = ModalHost.blurred(content, pointSize: size)!
        // The same quarter-size bitmap, blurred by Core Image.
        let small = CGContext(data: nil, width: ours.width, height: ours.height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        small.interpolationQuality = .medium
        small.draw(content, in: CGRect(x: 0, y: 0, width: small.width, height: small.height))
        let input = CIImage(cgImage: small.makeImage()!)
        let ci = CIContext(options: [.cacheIntermediates: false, .workingColorSpace: NSNull()])
            .createCGImage(input.clampedToExtent().applyingGaussianBlur(sigma: 1).cropped(to: input.extent), from: input.extent)!
        let a = FidelityTests.pixels(NSBitmapImageRep(cgImage: ours), ours.width, ours.height)
        let b = FidelityTests.pixels(NSBitmapImageRep(cgImage: ci), ours.width, ours.height)
        var worst = 0
        for i in stride(from: 0, to: a.count, by: 4) { worst = max(worst, (0..<3).map { abs(Int(a[i + $0]) - Int(b[i + $0])) }.max()!) }
        print("BACKDROP vImage vs Core Image: worst channel difference \(worst)")
        #expect(worst <= 2)
    }

    /// The backdrop drawn at half the point size matches the old path (a full backing-scale snapshot, then
    /// downscaled): under the 60% tint no channel moves by more than the fidelity tolerance.
    @Test func smallSnapshotMatchesFullSize() throws {
        for dark in [false, true] {
            let view = GalleryColumn(sections: Array(TogglesGallery.sections.prefix(2)), dark: dark)
            view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let size = NSSize(width: 520, height: view.contentHeight)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            view.frame = NSRect(origin: .zero, size: size)
            view.layoutSubtreeIfNeeded()
            window.display()
            defer { window.contentView = nil }
            let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: rep)
            let old = ModalHost.blurred(rep.cgImage!, pointSize: size)!
            let new = ModalHost.blurredSnapshot(of: view)!
            #expect(old.width == new.width && old.height == new.height)
            let a = FidelityTests.pixels(NSBitmapImageRep(cgImage: old), old.width, old.height)
            let b = FidelityTests.pixels(NSBitmapImageRep(cgImage: new), old.width, old.height)
            var worst = 0, total = 0, over = 0
            for i in stride(from: 0, to: a.count, by: 4) {
                let m = (0..<3).map { abs(Int(a[i + $0]) - Int(b[i + $0])) * 4 / 10 }.max()!
                worst = max(worst, m)
                total += m
                if m > FidelityTests.tolerance { over += 1 }
            }
            let n = Double(old.width * old.height)
            print(String(format: "BACKDROP %@: half-size vs full-size snapshot at %.0fx, %.2f%% over tolerance, worst %d, mean %.2f",
                         dark ? "dark" : "light", Double(rep.pixelsWide) / rep.size.width, Double(over) / n * 100, worst, Double(total) / n))
            #expect(worst <= FidelityTests.tolerance)
        }
    }
}

/// Toast timing and stacking, driven by a fake clock.
@MainActor
struct ToastBehaviourTests {
    @Test func timeoutPauseAndResume() {
        var q = ToastQueue()
        let a = q.add(now: 0)
        #expect(q.nextDeadline() == 5)
        q.setPaused(true, now: 2)
        #expect(q.nextDeadline() == nil)       // hovered: nothing scheduled
        #expect(q.expire(now: 10).isEmpty)
        q.setPaused(false, now: 10)
        #expect(q.nextDeadline() == 13)        // 3s were left
        #expect(q.expire(now: 12.9).isEmpty)
        #expect(q.expire(now: 13) == [a])
        #expect(q.nextDeadline() == nil)       // empty: nothing scheduled
    }

    @Test func persistentAndLoadingNeverExpire() {
        var q = ToastQueue()
        q.add(timeout: 0, now: 0)
        q.add(kind: .loading, now: 0)
        #expect(q.nextDeadline() == nil)
        #expect(q.expire(now: 100).isEmpty)
        #expect(q.items.count == 2)
    }

    @Test func newestInFrontAndLimit() {
        var q = ToastQueue()
        let ids = (0..<4).map { q.add(now: Double($0)) }
        #expect(q.items.map(\.id) == ids.reversed())
        let slots = ToastQueue.layout(heights: [46, 88, 46, 46], expanded: false)
        #expect(slots.map(\.limited) == [false, false, false, true])
    }

    @Test func collapsedStackPeeks() {
        let s = ToastQueue.layout(heights: [46, 88, 66], expanded: false)
        // Behind toasts take the front height, scale by 1 - 0.1i and peek 12px below the one in front.
        #expect(s[0] == .init(index: 0, translateY: 0, scale: 1, height: 46, contentHidden: false, limited: false))
        #expect(s[1].height == 46 && abs(s[1].scale - 0.9) < 1e-9 && abs(s[1].translateY - (12 + 4.6)) < 1e-9 && s[1].contentHidden)
        #expect(abs((s[1].translateY + s[1].height * s[1].scale) - (46 + 12)) < 1e-9)
        #expect(abs((s[2].translateY + s[2].height * s[2].scale) - (46 + 24)) < 1e-9)
    }

    @Test func expandedStackIsAList() {
        let s = ToastQueue.layout(heights: [46, 88, 66], expanded: true)
        #expect(s.map(\.translateY) == [0, 58, 158])
        #expect(s.allSatisfy { $0.scale == 1 && !$0.contentHidden })
    }

    @Test func viewportSchedulesOneTimerOnlyWhileToastsRun() {
        let viewport = ToastViewport(frame: NSRect(x: 0, y: 0, width: 360, height: 400))
        var clock: TimeInterval = 0
        viewport.now = { clock }
        #expect(!viewport.hasScheduledTimer)
        let id = viewport.show(ToastView(title: "Saved", kind: .success))
        #expect(viewport.hasScheduledTimer)
        viewport.setHovered(true)
        #expect(!viewport.hasScheduledTimer && viewport.isExpanded)
        viewport.setHovered(false)
        clock = 5
        viewport.fire()
        #expect(viewport.queue.items.isEmpty)
        #expect(!viewport.hasScheduledTimer)
        _ = id
    }
}

/// Modal focus: the popup's controls form a closed Tab loop, Escape closes, focus returns.
@MainActor
struct ModalFocusTests {
    @Test func focusIsTrappedAndReturned() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let outside = ButtonView("Outside")
        window.contentView!.addSubview(outside)
        window.makeFirstResponder(outside)
        let panel = DialogView(title: "Rename", message: "Pick a name.")
        let cancel = ButtonView("Cancel", variant: .outline), save = ButtonView("Save")
        panel.footerButtons = [cancel, save]
        let host = ModalHost.present(panel, in: window, blurBackdrop: false)
        let loop = host.focusableViews
        #expect(loop.count == 3) // close button, Cancel, Save
        #expect(window.firstResponder === loop[0])
        for (i, v) in loop.enumerated() { #expect(v.nextKeyView === loop[(i + 1) % loop.count]) }
        #expect(!loop.contains { $0 === outside })
        host.cancelOperation(nil) // Escape
        #expect(window.firstResponder === outside)
    }

    @Test func alertDialogIgnoresOutsideClicks() {
        let host = ModalHost(panel: DialogView(kind: .alertDialog, title: "Delete?"))
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        host.layoutSubtreeIfNeeded()
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 5, y: 5), modifierFlags: [], timestamp: 0,
                                       windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        host.mouseDown(with: event)
        #expect(!host.isClosing)
        let dialogHost = ModalHost(panel: DialogView(title: "Rename"))
        dialogHost.frame = host.frame
        dialogHost.layoutSubtreeIfNeeded()
        dialogHost.mouseDown(with: event)
        #expect(dialogHost.isClosing)
    }
}
