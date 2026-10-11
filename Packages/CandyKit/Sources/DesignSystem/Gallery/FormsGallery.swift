import AppKit

/// Gallery sections for the forms batch. Each batch owns its own file so agents never edit the same list.
@MainActor
enum FormsGallery {
    static var sections: [ComponentGallery.Section] {
        [
            .init(title: "Input (sizes; rest, focus, invalid, disabled)", height: 4 * 44) { inputs() },
            .init(title: "Textarea (sm, default, lg; focus)", height: 100) { textareas() },
            .init(title: "InputGroup (default, kbd addon, ghost, lg)", height: 2 * 44) { groups() },
            .init(title: "Label, Kbd and KbdGroup", height: 36) { labelsAndKeys() },
            .init(title: "Badge (variants, sizes)", height: 2 * 32) { badges() },
            .init(title: "Separator, Skeleton, Spinner", height: 60) { misc() },
        ]
    }

    static func state(focused: Bool = false, invalid: Bool = false, enabled: Bool = true) -> FieldView.State {
        var s = FieldView.State()
        s.focused = focused
        s.invalid = invalid
        s.enabled = enabled
        return s
    }

    static func inputs() -> NSView {
        let states = [state(), state(focused: true), state(invalid: true), state(enabled: false)]
        let rows: [[NSView]] = InputView.Size.allCases.filter { $0 != .inline }.map { size in
            states.map { s in
                let v = InputView(placeholder: size.rawValue, size: size)
                v.previewState(s)
                return v
            }
        }
        return Rows(rows, rowHeight: 44, width: 140)
    }

    static func textareas() -> NSView {
        let views: [NSView] = TextareaView.Size.allCases.map { TextareaView(placeholder: "Describe the change", size: $0) }
        let focused = TextareaView(text: "Focused textarea", size: .default)
        focused.previewState(state(focused: true))
        return Rows([views + [focused]], rowHeight: 100, width: 200)
    }

    static func groups() -> NSView {
        let focused = InputGroupView(placeholder: "Focused", leading: .icon(.search))
        focused.previewState(state(focused: true))
        return Rows([
            [InputGroupView(placeholder: "Search", leading: .icon(.search)),
             InputGroupView(placeholder: "Search", leading: .icon(.search), trailing: .kbd("⌘K")), focused],
            [InputGroupView(placeholder: "Ghost", variant: .ghost, leading: .icon(.search)),
             InputGroupView(placeholder: "Large", size: .lg, leading: .icon(.search)),
             InputGroupView(placeholder: "Popover", variant: .popover, leading: .icon(.search))],
        ], rowHeight: 44, width: 220)
    }

    static func labelsAndKeys() -> NSView {
        Rows([[FormLabel.make("Email address"), KbdView("Esc"), KbdView("⇧⌘K"), KbdView(icon: .arrowUp),
               KbdGroupView(keys: ["⌘", "K"])]], rowHeight: 36, width: nil)
    }

    static func badges() -> NSView {
        Rows([
            BadgeView.Variant.allCases.map { BadgeView($0.rawValue, variant: $0) },
            BadgeView.Size.allCases.map { BadgeView($0.rawValue, variant: .outline, size: $0) },
        ], rowHeight: 32, width: nil)
    }

    static func misc() -> NSView {
        let line = SeparatorView(.horizontal)
        line.frame.size = NSSize(width: 120, height: 1)
        let block = SkeletonView(shape: .block); block.frame.size = NSSize(width: 120, height: 16)
        let card = SkeletonView(shape: .card); card.frame.size = NSSize(width: 120, height: 48)
        let pill = SkeletonView(shape: .pill); pill.frame.size = NSSize(width: 80, height: 20)
        let spinners: [NSView] = SpinnerView.Size.allCases.map { SpinnerView(size: $0) } + [SpinnerView(size: .md, tone: .muted)]
        return Rows([[line, block, card, pill] + spinners], rowHeight: 60, width: nil)
    }

    /// Rows of views, left to right, vertically centered. `width` fixes the width of views that
    /// have none (fields); otherwise the intrinsic or preset size is used.
    final class Rows: DSView {
        private let rows: [[NSView]]
        private let rowHeight: CGFloat
        private let fixedWidth: CGFloat?

        init(_ rows: [[NSView]], rowHeight: CGFloat, width: CGFloat?) {
            self.rows = rows
            self.rowHeight = rowHeight
            self.fixedWidth = width
            super.init(frame: .zero)
            rows.joined().forEach(addSubview)
        }

        override func layout() {
            super.layout()
            for (r, items) in rows.enumerated() {
                var x: CGFloat = 0
                for view in items {
                    var size = view.intrinsicContentSize
                    if let fixedWidth { size.width = fixedWidth }
                    if size.width < 0 { size.width = view.frame.width }
                    if size.height < 0 { size.height = view.frame.height }
                    view.frame = NSRect(x: x, y: CGFloat(r) * rowHeight + (rowHeight - size.height) / 2, width: size.width, height: size.height)
                    x += size.width + 12
                }
            }
        }
    }
}
