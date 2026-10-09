import AppKit

/// Gallery sections for the sidebar batch: sidebar shell and rows, command palette, color picker, calendar.
@MainActor
enum SidebarGallery {
    static var sections: [ComponentGallery.Section] {
        [
            .init(title: "Sidebar (drag the rail to resize, double-click it to reset; trigger toggles)", height: 300) {
                let rows: [NSView] = [
                    SidebarMenuButtonView("demo-repo", icon: .folder, active: true),
                    SidebarMenuButtonView("Settings", icon: .settings),
                    SidebarMenuSubView([SidebarMenuButtonView("General", icon: .slidersHorizontal, kind: .sub(small: false), active: true),
                                        SidebarMenuButtonView("Archive", icon: .archive, kind: .sub(small: false))]),
                ]
                let layout = SidebarLayoutView(sidebarContent: SidebarMenuView(rows),
                                               defaults: UserDefaults(suiteName: "candywrapper.gallery") ?? .standard, viewport: 1300)
                let trigger = SidebarTriggerView()
                trigger.action = { [weak layout, weak trigger] in
                    layout?.toggle()
                    trigger?.isSidebarOpen = layout?.isOpen ?? true
                }
                return PopupsGallery.Place([(layout, NSRect(x: 0, y: 0, width: 488, height: 300)),
                                            (trigger, NSRect(x: 452, y: 8, width: 28, height: 28))])
            },
            .init(title: "SidebarMenuButton: rest, hover, active, selected, focus-visible, disabled, badge, action, dot", height: 9 * 36 + 16) {
                @MainActor func row(_ title: String, _ state: ControlView.State = .init(), active: Bool = false) -> SidebarMenuButtonView {
                    let b = SidebarMenuButtonView(title, icon: .messageSquare, active: active)
                    b.previewState(state)
                    return b
                }
                var hover = ControlView.State(); hover.hovered = true
                var pressed = hover; pressed.active = true
                var focus = ControlView.State(); focus.focusVisible = true
                var disabled = ControlView.State(); disabled.enabled = false
                let badge = row("With badge")
                badge.accessory = BadgeView("3", variant: .secondary, size: .sm)
                let action = row("With action")
                action.accessory = ButtonView(nil, icon: .ellipsis, variant: .ghost, size: .iconXs)
                let dot = row("Unread")
                dot.statusDot = Themed.color(\.primary)
                let rows = [row("Rest"), row("Hover", hover), row("Active (pressed)", pressed), row("Selected", active: true),
                            row("Focus visible", focus), row("Disabled", disabled), badge, action, dot]
                return SidebarSample(SidebarMenuView(rows))
            },
            .init(title: "SidebarMenuButton sizes and outline: sm, default, lg, icon, outline", height: 5 * 52 + 16) {
                SidebarSample(SidebarMenuView([
                    SidebarMenuButtonView("Small", icon: .folder, size: .sm),
                    SidebarMenuButtonView("Default", icon: .folder),
                    SidebarMenuButtonView("Large", icon: .folder, size: .lg),
                    SidebarMenuButtonView("", icon: .folder, size: .icon),
                    SidebarMenuButtonView("Outline", icon: .folder, variant: .outline),
                ]))
            },
            .init(title: "Command palette: results with highlight and shortcut", height: 330) {
                let palette = CommandPaletteView(content: .results([
                    CommandPaletteGroup("Actions", [CommandPaletteItem("New thread", icon: .squarePen, shortcut: "⇧⌘O"),
                                                    CommandPaletteItem("Add project", icon: .folderPlus),
                                                    CommandPaletteItem("Settings", icon: .settings, isSubmenu: true)]),
                    CommandPaletteGroup("Threads", [CommandPaletteItem("Reply with markdown only", icon: .messageSquare, timestamp: "17m"),
                                                    CommandPaletteItem("Archived thread", icon: .messageSquare, isDisabled: true)]),
                ]))
                palette.highlightedIndex = 0
                palette.footerActionLabel = "Select"
                return PopupsGallery.Place([(palette, NSRect(x: 0, y: 0, width: 488, height: palette.intrinsicContentSize.height))])
            },
            .init(title: "Command palette: empty and loading", height: 2 * 200 + 16) {
                let empty = CommandPaletteView(content: .empty(message: nil, actionsOnly: false))
                let loading = CommandPaletteView(content: .loading("Loading folders..."))
                loading.input.placeholder = "Enter project path (e.g. ~/projects/my-app)"
                loading.showsBackHint = true
                return PopupsGallery.Place([(empty, NSRect(x: 0, y: 0, width: 488, height: empty.intrinsicContentSize.height)),
                                            (loading, NSRect(x: 0, y: 208, width: 488, height: loading.intrinsicContentSize.height))])
            },
            .init(title: "Color picker: saturation/value plane (inset, focused) and hue slider", height: 128 + 16 + 24 + 8) {
                let plane = ColorSaturationValuePlaneView(hue: 210, saturation: 0.6, value: 0.8)
                let focused = ColorSaturationValuePlaneView(hue: 25, saturation: 0.42, value: 0.9)
                focused.showsFocus = true
                let hue = ColorHueSliderView(hue: 210)
                hue.onChange = { [weak plane] h in plane?.hue = h }
                return PopupsGallery.Place([(plane, NSRect(x: 0, y: 4, width: 224, height: 128)),
                                            (focused, NSRect(x: 248, y: 4, width: 224, height: 128)),
                                            (hue, NSRect(x: 0, y: 148, width: 224, height: 24))])
            },
            .init(title: "Calendar: today dot, selected day, disabled weekend days, outside days", height: 300) {
                let cal = CalendarView(month: DateComponents(year: 2026, month: 10), selected: DateComponents(year: 2026, month: 10, day: 14),
                                       today: DateComponents(year: 2026, month: 10, day: 9))
                cal.isDisabled = { $0.month == 10 && ($0.day == 24 || $0.day == 25) }
                return PopupsGallery.Place([(cal, NSRect(x: 8, y: 0, width: 0, height: 0))])
            },
        ]
    }

    /// A 256px `bg-sidebar` column, so rows show their sidebar colors.
    final class SidebarSample: DSView {
        let list: SidebarMenuView
        init(_ menu: SidebarMenuView) {
            self.list = menu
            super.init(frame: .zero)
            addSubview(list)
        }
        override func layout() {
            super.layout()
            list.frame = NSRect(x: 0, y: 0, width: 256, height: list.contentHeight)
        }
        override func updateLayer() {
            layer?.backgroundColor = nil
            list.layer?.backgroundColor = Themed.color(\.sidebar, sidebar: true).cgColor(in: self)
        }
    }
}
