import Foundation

/// Source viewBox of an icon.
public struct IconViewBox: Sendable, Equatable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

/// One SVG shape element. `polyline` and `polygon` hold flat x,y pairs.
public enum IconShape: Sendable, Hashable {
    case path(d: String)
    case circle(cx: Double, cy: Double, r: Double)
    case ellipse(cx: Double, cy: Double, rx: Double, ry: Double)
    case rect(x: Double, y: Double, w: Double, h: Double, rx: Double, ry: Double)
    case line(x1: Double, y1: Double, x2: Double, y2: Double)
    case polyline([Double])
    case polygon([Double])
}

public enum IconColor: Sendable, Equatable {
    case none
    /// SVG `currentColor`: the view's stroke color (or fill color for fills when set).
    case current
    /// Fixed color, 0xRRGGBBAA.
    case rgba(UInt32)
}

public enum IconLineCap: Sendable { case butt, round, square }
public enum IconLineJoin: Sendable { case miter, round, bevel }

public struct IconPaint: Sendable, Equatable {
    public var fill: IconColor
    public var stroke: IconColor
    /// In viewBox units.
    public var strokeWidth: Double
    public var opacity: Double
    public var lineCap: IconLineCap
    public var lineJoin: IconLineJoin
    public var evenOdd: Bool
    public var offsetX: Double
    public var offsetY: Double

    public init(
        fill: IconColor = .none, stroke: IconColor = .none, strokeWidth: Double = 1, opacity: Double = 1,
        lineCap: IconLineCap = .butt, lineJoin: IconLineJoin = .miter, evenOdd: Bool = false,
        offsetX: Double = 0, offsetY: Double = 0
    ) {
        self.fill = fill; self.stroke = stroke; self.strokeWidth = strokeWidth; self.opacity = opacity
        self.lineCap = lineCap; self.lineJoin = lineJoin; self.evenOdd = evenOdd
        self.offsetX = offsetX; self.offsetY = offsetY
    }

    /// A Hugeicons duotone tint: a see-through fill under the glyph's strokes.
    public var isTint: Bool { stroke == .none && fill == .current && opacity < 1 }

    /// lucide defaults: no fill, currentColor stroke, width 2, round caps and joins.
    public static let lucide = IconPaint(stroke: .current, strokeWidth: 2, lineCap: .round, lineJoin: .round)
}

public struct IconElement: Sendable, Equatable {
    public var shape: IconShape
    public var paint: IconPaint
    public init(_ shape: IconShape, _ paint: IconPaint = .lucide) {
        self.shape = shape; self.paint = paint
    }
}

public struct IconDefinition: Sendable, Equatable {
    public var viewBox: IconViewBox
    public var elements: [IconElement]
    public init(viewBox: IconViewBox, elements: [IconElement]) {
        self.viewBox = viewBox; self.elements = elements
    }
}

extension IconName {
    /// True for T3 brand glyphs (fixed colors), false for lucide icons.
    public var isBrand: Bool { lucideName == nil }

    /// The lucide icon whose shapes `definition` draws, whatever its stroke, so a glyph passed around as a definition
    /// (a menu item's) still finds its Hugeicons twin.
    public static func lucide(drawing definition: IconDefinition) -> IconName? {
        byShapes[definition.elements.map(\.shape)]
    }

    private static let byShapes: [[IconShape]: IconName] = {
        var map: [[IconShape]: IconName] = [:]
        for name in allCases where !name.isBrand { map[name.definition.elements.map(\.shape)] = name }
        return map
    }()
}
