import AppKit
import Testing
@testable import DesignSystem

@MainActor
struct SnapshotTests {
    private final class ColorView: DSView {
        var fill: NSColor = .white
        override var wantsUpdateLayer: Bool { false }
        override func draw(_ dirtyRect: NSRect) { fill.setFill(); bounds.fill() }
    }

    @Test func smoothingScopeKeepsFontStateAndGeneration() {
        let input = FontRuntime.input, generation = FontRuntime.generation
        let smoothing = FontRuntime.smoothing
        FontRuntime.$smoothingOverride.withValue(!smoothing) {
            #expect(FontRuntime.smoothing == !smoothing)
            #expect(FontRuntime.input == input)
            #expect(FontRuntime.generation == generation)
        }
        #expect(FontRuntime.smoothing == smoothing)
    }

    @Test(arguments: [CGFloat(45), 45.5])
    func preparesFractionalScrollAfterWindowLayout(offset: CGFloat) throws {
        let size = NSSize(width: 64, height: 64)
        let canvas = ColorView(frame: NSRect(origin: .zero, size: size))
        canvas.fill = .white
        let scroll = NSScrollView(frame: canvas.bounds)
        scroll.drawsBackground = false
        let document = ColorView(frame: NSRect(x: 0, y: 0, width: 64, height: 200))
        document.fill = .white
        let line = ColorView(frame: NSRect(x: 0, y: 64, width: 64, height: 1))
        line.fill = .black
        document.addSubview(line)
        scroll.documentView = document
        canvas.addSubview(scroll)
        var prepared = 0
        let image = Snapshot.image(of: canvas, size: size, scale: 2, dark: false) {
            #expect(canvas.window != nil)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
            #expect(scroll.contentView.bounds.minY == offset)
            prepared += 1
        }
        #expect(prepared == 1)
        // A half-point scroll moves the one-point line by exactly one device pixel.
        let top = Int((64 - offset) * 2)
        for y in (top - 1)...(top + 2) {
            let color = try #require(image.colorAt(x: 16, y: y)?.usingColorSpace(.sRGB))
            let expected: CGFloat = (top...(top + 1)).contains(y) ? 0 : 1
            #expect(abs(color.redComponent - expected) < 0.01)
            #expect(abs(color.greenComponent - expected) < 0.01)
            #expect(abs(color.blueComponent - expected) < 0.01)
        }
    }
}
