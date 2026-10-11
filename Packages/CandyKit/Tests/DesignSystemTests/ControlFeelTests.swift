import AppKit
import Testing
@testable import DesignSystem

/// Color fades follow T3's `transition-*` classes, and hover occlusion follows the overlay stack.
@MainActor
struct ControlFeelTests {
    private func hostedDecoration(_ transition: Motion.Transition) -> (BoxDecorationLayer, NSWindow) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let host = DSView(frame: NSRect(x: 0, y: 0, width: 50, height: 30))
        window.contentView?.addSubview(host)
        let layer = BoxDecorationLayer()
        layer.host = host
        layer.transition = transition
        host.layer?.addSublayer(layer)
        layer.layout(boxSize: host.bounds.size)
        // A layer that has drawn once; a first draw never fades in.
        layer.contents = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        return (layer, window)
    }

    @Test func focusRingFadesButHoverFillSnaps() throws {
        guard !Motion.reduced else { return }
        let (layer, window) = hostedDecoration([.shadow])
        defer { window.close() }
        var hover = BoxStyle()
        hover.fill = .red
        layer.boxStyle = hover
        #expect(layer.animation(forKey: kCATransition) == nil, "button hover fills snap (button.tsx:11)")
        var ring = hover
        ring.shadows = [BoxShadow(spread: 2, color: .blue)]
        layer.boxStyle = ring
        #expect(layer.animation(forKey: kCATransition) != nil, "the focus ring fades (transition-shadow)")
    }

    @Test func transitionColorsFadesFillsInsideAStateChange() throws {
        guard !Motion.reduced else { return }
        let (layer, window) = hostedDecoration([])
        defer { window.close() }
        var hover = BoxStyle()
        hover.fill = .red
        Motion.transitioning(.colors) { layer.boxStyle = hover }
        #expect(layer.animation(forKey: kCATransition) != nil)
        #expect(Motion.activeTransitions.isEmpty)
    }

    @Test func changesNameWhatDiffers() {
        var a = BoxStyle(), b = BoxStyle()
        b.fill = .red
        #expect(BoxDecorationLayer.changes(from: a, to: b) == .background)
        a = b
        b.radius = 4
        #expect(!Motion.Transition.colors.isSuperset(of: BoxDecorationLayer.changes(from: a, to: b)), "geometry never fades")
    }

    @Test func overlaysCoverWhatIsBelowThem() {
        #expect(HoverSync.isAbove([2], [0]))
        #expect(HoverSync.isAbove([1, 1], [1, 0]), "a submenu covers its parent menu")
        #expect(!HoverSync.isAbove([0], [0]), "the same layer never covers itself")
        #expect(!HoverSync.isAbove([0], [1, 0]))
    }
}
