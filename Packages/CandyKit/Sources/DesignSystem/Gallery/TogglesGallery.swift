import AppKit

/// Gallery sections for the toggles batch. Each batch owns its own file so agents never edit the same list.
/// States are forced with `previewState`, so sections render the same in snapshots.
@MainActor
enum TogglesGallery {
    static var sections: [ComponentGallery.Section] {
        [
            .init(title: "Toggle variants (off, on, hover, focus, disabled)", height: 5 * 44) {
                Rows(ToggleView.Variant.allCases.map { v in
                    let size: ToggleView.Size = v == .segmented ? .segmented : .default
                    return [(false, State()), (true, State()), (false, State(hovered: true)), (false, State(focusVisible: true)),
                            (true, State(enabled: false))].map { pressed, s in
                        preview(ToggleView(v.rawValue, icon: .plus, variant: v, size: size, pressed: pressed), s)
                    }
                })
            },
            .init(title: "Toggle sizes and toggle groups", height: 2 * 44) {
                Rows([
                    ToggleView.Size.allCases.filter { $0 != .segmented }.map { ToggleView(nil, icon: .plus, variant: .outline, size: $0) },
                    [ToggleGroupView(variant: .segmented, items: [("Unified", nil), ("Split", nil), ("Raw", nil)], selected: 0),
                     ToggleGroupView(variant: .default, items: [("Bold", .plus), ("Italic", .plus)], selected: 0)],
                ])
            },
            .init(title: "Switch, checkbox, radio (rest, on, mixed, focus, disabled, invalid)", height: 3 * 44) {
                Rows([
                    SwitchView.Size.allCases.flatMap { size in
                        [(false, false, State()), (true, false, State()), (true, true, State()), (true, false, State(focusVisible: true)),
                         (true, false, State(enabled: false))].map { on, mixed, s -> NSView in
                            let v = SwitchView(isOn: on, size: size)
                            v.isMixed = mixed
                            return preview(v, s)
                        }
                    },
                    [ChoiceView.Value.off, .on, .mixed].flatMap { value in
                        [State(), State(focusVisible: true), State(enabled: false)].map { preview(CheckboxView(value: value), $0) }
                    } + [{ let c = CheckboxView(); c.isInvalid = true; return c }()],
                    [false, true].flatMap { on in
                        [State(), State(focusVisible: true), State(enabled: false)].map { preview(RadioView(checked: on), $0) }
                    } + [RadioGroupView(radios: [RadioView(), RadioView()], selected: 1)],
                ])
            },
            .init(title: "Alert (default, error, info, success, warning)", height: 5 * 76) {
                Stack(AlertView.Variant.allCases.filter { $0 != .sidebar }.map {
                    AlertView("Heads up", message: "Something needs your attention.", icon: .circleAlert, variant: $0)
                }, spacing: 8)
            },
            .init(title: "Alert, long message: icon centered (T3's default) and on the first line", height: 2 * 88 + 8) {
                let title = "Your session expired while the agent was still running"
                let message = "Reconnect to keep streaming. Anything the agent wrote while you were away is saved on the server and appears once the thread syncs again."
                let firstLine = AlertView(title, message: message, icon: .circleAlert)
                firstLine.controlAlignment = .firstLine
                return Stack([AlertView(title, message: message, icon: .circleAlert), firstLine], spacing: 8)
            },
            .init(title: "Alert, sidebar variant (T3 uses it only inside the sidebar)", height: 64) {
                SidebarStrip(AlertView("Thread archived", message: "Undo is available for a few seconds.", icon: .circleAlert,
                                       variant: .sidebar))
            },
            .init(title: "Empty (default, compact)", height: 208 + 256) {
                Stack([EmptyView(title: "No threads yet", message: "Start a conversation to see it here.", icon: .inbox),
                       EmptyView(title: "No threads yet", message: "Start a conversation to see it here.", icon: .inbox, size: .compact)],
                      spacing: 0)
            },
            .init(title: "Collapsible section header (tones, collapsed and expanded, focus) and panel", height: 6 * 36 + 60) {
                let headers = CollapsibleSectionHeaderView.Tone.allCases.map {
                    CollapsibleSectionHeaderView("Projects", tone: $0, expanded: $0 == .info)
                }
                let focused = preview(CollapsibleSectionHeaderView("Focused", expanded: true), State(focusVisible: true))
                let trigger = CollapsibleSectionHeaderView("Click to toggle the panel", tone: .emphasized, expanded: true)
                let panel = CollapsibleView(content: AlertView("Panel content", message: "Opens and closes over 200ms.", icon: .info), isOpen: true)
                trigger.onToggle = { panel.isOpen = $0 }
                return Stack(headers + [focused, trigger, panel], spacing: 4)
            },
        ]
    }

    typealias State = ControlView.State

    static func preview<V: ControlView>(_ view: V, _ state: State) -> V {
        view.previewState(state)
        return view
    }

    /// Rows of views at their intrinsic size, 44pt per row, 12pt apart.
    final class Rows: DSView {
        private let rows: [[NSView]]
        init(_ rows: [[NSView]]) {
            self.rows = rows
            super.init(frame: .zero)
            rows.joined().forEach(addSubview)
        }

        override func layout() {
            super.layout()
            for (r, row) in rows.enumerated() {
                var x: CGFloat = 0
                for view in row {
                    let s = view.intrinsicContentSize
                    view.frame = NSRect(x: x, y: CGFloat(r) * 44 + (44 - s.height) / 2, width: s.width, height: s.height)
                    x += s.width + 12
                }
            }
        }
    }

    /// Full-width views stacked vertically; keeps collapsible panels in step with their height.
    /// Shows sidebar-only components on the sidebar's own surface (color and grain).
    final class SidebarStrip: DSView {
        private let surface = GrainSurfaceView(fill: Themed.color(\.sidebar, sidebar: true))
        private let content: NSView

        init(_ content: NSView) {
            self.content = content
            super.init(frame: .zero)
            addSubview(surface)
            addSubview(content)
        }

        override func layout() {
            super.layout()
            surface.frame = bounds
            content.setFrameSize(NSSize(width: bounds.width - 16, height: content.frame.height))
            let h = content.intrinsicContentSize.height
            content.frame = NSRect(x: 8, y: (bounds.height - h) / 2, width: bounds.width - 16, height: h)
        }
    }

    final class Stack: DSView {
        private let views: [NSView]
        private let spacing: CGFloat
        init(_ views: [NSView], spacing: CGFloat) {
            self.views = views
            self.spacing = spacing
            super.init(frame: .zero)
            views.forEach(addSubview)
            for case let panel as CollapsibleView in views {
                panel.onHeightChange = { [weak self] in self?.needsLayout = true }
            }
        }

        override func layout() {
            super.layout()
            var y: CGFloat = 0
            for view in views {
                view.setFrameSize(NSSize(width: bounds.width, height: view.frame.height)) // wrapped text measures at the width
                let h = view.intrinsicContentSize.height
                view.frame = NSRect(x: 0, y: y, width: bounds.width, height: h)
                y += h + spacing
            }
        }
    }
}

private extension ControlView.State {
    init(hovered: Bool = false, focusVisible: Bool = false, enabled: Bool = true) {
        self.init()
        self.hovered = hovered
        self.focusVisible = focusVisible
        self.enabled = enabled
    }
}
