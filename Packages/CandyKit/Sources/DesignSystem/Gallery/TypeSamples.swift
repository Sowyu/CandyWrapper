import AppKit

/// Gallery section: T3's type scale (`text-xs` ... `text-2xl`) at the default 16px rem, in each weight.
enum TypeSamples {
    static let styles: [(String, TextStyle)] = [
        ("text-2xs", Tokens.Text._2xs), ("text-xs", Tokens.Text.xs), ("text-sm", Tokens.Text.sm),
        ("text-base", Tokens.Text.base), ("text-lg", Tokens.Text.lg), ("text-xl", Tokens.Text.xl),
        ("text-2xl", Tokens.Text._2xl),
    ]

    static var section: ComponentGallery.Section {
        .init(title: "Type scale", height: styles.reduce(0) { $0 + Interface.rem($1.1.lineHeight) } + 8) { Samples() }
    }

    final class Samples: DSView {
        private var rows: [(LabelView, CGFloat)] = []

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            for (name, style) in TypeSamples.styles {
                let label = LabelView("\(name) The quick brown fox, 0123456789",
                                      font: DSFont.ui(Interface.rem(style.size)),
                                      color: Themed.color(\.contrastForeground))
                label.lineHeight = Interface.rem(style.lineHeight)
                addSubview(label)
                rows.append((label, Interface.rem(style.lineHeight)))
            }
        }

        override func layout() {
            super.layout()
            var y: CGFloat = 0
            for (label, height) in rows {
                label.frame = NSRect(x: 0, y: y, width: bounds.width, height: height)
                y += height
            }
        }
    }
}
