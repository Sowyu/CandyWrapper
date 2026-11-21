import AppKit
import Testing
@testable import DesignSystem

/// Redesign: an open popup whose content changes size keeps the edge against its control and its left edge, and
/// scrolls inside instead of moving (the 1.17.0 walk, 01b, 01f, 01g and 07j).
@MainActor
struct PopupHostTests {
    let bounds = CGRect(x: 0, y: 0, width: 1100, height: 800)

    /// The docked model picker: top, end, shift. Older models grows it past the room above the chip.
    @Test func olderModelsGrowsUpwardAndNeverCoversTheChip() {
        let p = PopupPlacement(side: .top, align: .end, sideOffset: 4, fallbackAxisSide: .none, collision: .shift)
        let chip = CGRect(x: 800, y: 500, width: 120, height: 28)
        let first = PopupPositioner.place(size: CGSize(width: 560, height: 420), anchor: chip, in: bounds, p)
        let pin = PopupPositioner.Pin(first.frame, anchor: chip, side: first.side)
        let grown = PopupPositioner.replace(size: CGSize(width: 560, height: 700), anchor: chip, in: bounds, pin: pin, p)
        #expect(grown.frame.maxY == first.frame.maxY && grown.frame.maxY <= chip.minY)
        #expect(grown.frame.minX == first.frame.minX)
        #expect(grown.frame.minY == 5 && grown.side == .top)
        // A tab with a narrower, shorter list: the left edge and the bottom edge stay.
        let tab = PopupPositioner.replace(size: CGSize(width: 470, height: 300), anchor: chip, in: bounds, pin: pin, p)
        #expect(tab.frame.minX == first.frame.minX && tab.frame.maxY == first.frame.maxY)
        // Placed afresh, the same growth slides it down over the chip: what the pin prevents.
        #expect(PopupPositioner.place(size: CGSize(width: 560, height: 700), anchor: chip, in: bounds, p).frame.maxY > chip.minY)
    }

    /// Opened over its chip in a short window (no room above), it keeps that bottom edge and grows only upward.
    @Test func aPopupShiftedOverItsChipKeepsThatEdge() {
        let p = PopupPlacement(side: .top, align: .end, sideOffset: 4, fallbackAxisSide: .none, collision: .shift)
        let chip = CGRect(x: 800, y: 200, width: 120, height: 28)
        let first = PopupPositioner.place(size: CGSize(width: 560, height: 300), anchor: chip, in: bounds, p)
        let pin = PopupPositioner.Pin(first.frame, anchor: chip, side: first.side)
        let grown = PopupPositioner.replace(size: CGSize(width: 560, height: 600), anchor: chip, in: bounds, pin: pin, p)
        #expect(grown.frame.maxY == first.frame.maxY && grown.frame.minX == first.frame.minX)
    }

    /// Settings > Title rewrite model: bottom, end, with the cross-axis fallback. Older models used to flip it to the
    /// row's left side, about 180pt left and 110pt up.
    @Test func theSettingsPickerKeepsItsTopAndLeftEdges() {
        let p = PopupPlacement(side: .bottom, align: .end, sideOffset: 4, fallbackAxisSide: .end)
        let row = CGRect(x: 760, y: 380, width: 200, height: 28)
        let first = PopupPositioner.place(size: CGSize(width: 420, height: 360), anchor: row, in: bounds, p)
        #expect(first.side == .bottom)
        let pin = PopupPositioner.Pin(first.frame, anchor: row, side: first.side)
        let grown = PopupPositioner.replace(size: CGSize(width: 420, height: 560), anchor: row, in: bounds, pin: pin, p)
        #expect(grown.frame.minY == first.frame.minY && grown.frame.minX == first.frame.minX)
        #expect(grown.frame.maxY == bounds.maxY - 5)
        #expect(PopupPositioner.place(size: CGSize(width: 420, height: 560), anchor: row, in: bounds, p).side != .bottom)
    }

    /// Through the host under Redesign: a content-size change re-places the popup on its pin, and a centred popup
    /// stays centred.
    @Test func theHostKeepsTheAnchoredEdgeUnderRedesign() {
        _ = NSApplication.shared
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        var input = ThemeRuntimeInput(light: ThemeDefinition.dither.colors(for: .light).map { ThemeRuntimeHalf(colors: $0) },
                                      dark: ThemeDefinition.dither.colors(for: .dark).map { ThemeRuntimeHalf(colors: $0) })
        input.ditherLight = true; input.ditherDark = true
        ThemeRuntime.apply(input)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        let root = DSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 800))
        w.contentView = root
        let chip = DSView(frame: NSRect(x: 800, y: 500, width: 120, height: 28))
        root.addSubview(chip)
        let host = PopupHost.host(for: w)
        let content = SizedContent(CGSize(width: 560, height: 420))
        let popup = host.open(content, trigger: chip, placement: PopupPlacement(side: .top, align: .end, sideOffset: 4,
                                                                                 fallbackAxisSide: .none, collision: .shift))
        let first = popup.container.frame
        content.size = CGSize(width: 560, height: 900)
        host.reposition(popup)
        #expect(popup.container.frame.maxY == first.maxY && popup.container.frame.minX == first.minX)
        #expect(popup.container.frame.height < 900)
        content.size = CGSize(width: 480, height: 300)
        host.reposition(popup)
        #expect(popup.container.frame.maxY == first.maxY && popup.container.frame.minX == first.minX)
        host.closeAll()
    }

    final class SizedContent: NSView, PopupContent {
        var size: CGSize
        init(_ size: CGSize) { self.size = size; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        var popupSize: CGSize { size }
    }
}
