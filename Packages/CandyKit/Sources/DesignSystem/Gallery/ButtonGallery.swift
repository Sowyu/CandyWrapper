import AppKit

/// Gallery section: every Button variant in rest, hover, pressed, focus-visible and disabled,
/// plus every size. States are forced, so the section renders identically in snapshots.
enum ButtonGallery {
    static let states: [(String, ControlView.State)] = {
        var rest = ControlView.State()
        var hover = rest; hover.hovered = true
        var pressed = rest; pressed.hovered = true; pressed.active = true
        var focus = rest; focus.focusVisible = true
        var disabled = rest; disabled.enabled = false
        return [("rest", rest), ("hover", hover), ("pressed", pressed), ("focus", focus), ("disabled", disabled)]
    }()

    static let rowHeight: CGFloat = 44

    static var variantsSection: ComponentGallery.Section {
        .init(title: "Button variants (rest, hover, pressed, focus, disabled)",
              height: CGFloat(ButtonView.Variant.allCases.count) * rowHeight) { Grid(mode: .variants) }
    }

    static var sizesSection: ComponentGallery.Section {
        .init(title: "Button sizes", height: 2 * rowHeight) { Grid(mode: .sizes) }
    }

    final class Grid: DSView {
        enum Mode { case variants, sizes }
        private var buttons: [[ButtonView]] = []

        init(mode: Mode) {
            super.init(frame: .zero)
            switch mode {
            case .variants:
                buttons = ButtonView.Variant.allCases.map { variant in
                    ButtonGallery.states.map { _, state in
                        let b = ButtonView(variant.rawValue, icon: .plus, variant: variant, size: .sm)
                        b.previewState(state)
                        return b
                    }
                }
            case .sizes:
                let text = ButtonView.Size.allCases.filter { !$0.isIconOnly }
                let icons = ButtonView.Size.allCases.filter(\.isIconOnly)
                buttons = [
                    text.map { ButtonView($0.rawValue, variant: .outline, size: $0) },
                    icons.map { ButtonView(nil, icon: .settings, variant: .outline, size: $0) },
                ]
            }
            buttons.joined().forEach(addSubview)
        }

        override func layout() {
            super.layout()
            for (row, items) in buttons.enumerated() {
                var x: CGFloat = 0
                for button in items {
                    let size = button.intrinsicContentSize
                    button.frame = NSRect(x: x, y: CGFloat(row) * ButtonGallery.rowHeight + (ButtonGallery.rowHeight - size.height) / 2,
                                          width: size.width, height: size.height)
                    x += max(size.width, 0) + 12
                }
            }
        }
    }
}
