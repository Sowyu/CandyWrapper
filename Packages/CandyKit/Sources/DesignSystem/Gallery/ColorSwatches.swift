import AppKit

/// Gallery section: every semantic color token of the main palette as a swatch grid.
enum ColorSwatches {
    /// Palette members by name, read with reflection so the list follows the generated file.
    static func entries(_ palette: Palette) -> [(String, TokenColor)] {
        Mirror(reflecting: palette).children.compactMap { child in
            guard let name = child.label, let color = child.value as? TokenColor else { return nil }
            return (name, color)
        }
    }

    static let columns = 4
    static let rowHeight: CGFloat = 44

    static var section: ComponentGallery.Section {
        let count = entries(Tokens.light).count
        let rows = (count + columns - 1) / columns
        return .init(title: "Color tokens", height: CGFloat(rows) * rowHeight) { SwatchGrid() }
    }

    final class SwatchGrid: DSView {
        private let cells: [(DSView, LabelView, String)]

        override init(frame frameRect: NSRect) {
            cells = ColorSwatches.entries(Tokens.light).map { name, _ in
                (Swatch(name: name), LabelView(name, font: DSFont.ui(11), color: ThemeColors.main.color(\.mutedForeground)), name)
            }
            super.init(frame: frameRect)
            for (swatch, label, _) in cells {
                addSubview(swatch)
                addSubview(label)
            }
        }

        override func layout() {
            super.layout()
            let cellWidth = bounds.width / CGFloat(ColorSwatches.columns)
            for (i, (swatch, label, _)) in cells.enumerated() {
                let x = CGFloat(i % ColorSwatches.columns) * cellWidth
                let y = CGFloat(i / ColorSwatches.columns) * ColorSwatches.rowHeight
                swatch.frame = NSRect(x: x, y: y + 4, width: 28, height: 28)
                label.frame = NSRect(x: x + 34, y: y + 4, width: cellWidth - 38, height: 28)
            }
        }
    }

    /// A swatch whose fill follows the current appearance.
    final class Swatch: DSView {
        private let color: NSColor

        init(name: String) {
            let light = Dictionary(uniqueKeysWithValues: ColorSwatches.entries(Tokens.light))[name]!
            let dark = Dictionary(uniqueKeysWithValues: ColorSwatches.entries(Tokens.dark))[name]!
            color = dynamicColor(light: light, dark: dark)
            super.init(frame: .zero)
        }

        override func updateLayer() {
            layer?.backgroundColor = color.cgColor(in: self)
            layer?.cornerRadius = 6
            layer?.borderWidth = 1
            layer?.borderColor = ThemeColors.main.color(\.border).cgColor(in: self)
        }
    }
}
