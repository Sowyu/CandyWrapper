import AppKit

/// Gallery sections for the popups batch. Each batch owns its own file so agents never edit the same list.
/// Popups are shown statically open as plain subviews; the triggers above them open the real ones.
@MainActor
enum PopupsGallery {
    static var sections: [ComponentGallery.Section] {
        [
            .init(title: "Menu (trigger opens a live menu; static: actions with submenu row open, options)", height: 36 + 230) {
                let trigger = ButtonView("Actions", variant: .outline)
                trigger.trailingIcon = .chevronDown
                trigger.scalesWhenPressed = false
                trigger.action = { [weak trigger] in if let trigger { MenuPopupView.show(actionsMenu, from: trigger) } }
                let open = ButtonView("Open", variant: .ghost)
                open.trailingIcon = .chevronDown
                open.isPopupOpen = true
                let actions = MenuPopupView(items: actionsMenu)
                actions.highlightedIndex = 4
                let options = MenuPopupView(items: optionsMenu)
                options.highlightedIndex = 6
                return Place([(trigger, NSRect(x: 0, y: 0, width: 0, height: 0)), (open, NSRect(x: 120, y: 0, width: 0, height: 0)),
                              (actions, NSRect(x: 0, y: 44, width: 0, height: 0)), (options, NSRect(x: 200, y: 44, width: 0, height: 0))])
            },
            .init(title: "Select (default, placeholder, open, ghost) and its popup", height: 3 * 40 + 140) {
                let models = ["Claude Haiku", "Claude Sonnet", "Claude Opus", "GPT Astra"]
                let live = SelectView(options: models, selected: 0)
                let placeholder = SelectView(options: models, placeholder: "Choose a model")
                let open = SelectView(options: models, selected: 0)
                open.isPopupOpen = true
                let ghost = SelectView(options: models, selected: 1, variant: .ghost)
                let popup = MenuPopupView(items: models.enumerated().map { MenuItem($1, kind: .radio($0 == 1)) }, style: .select)
                popup.minimumWidth = 200
                popup.highlightedIndex = 2
                return Place([(live, NSRect(x: 0, y: 0, width: 200, height: 32)), (placeholder, NSRect(x: 216, y: 0, width: 200, height: 32)),
                              (open, NSRect(x: 0, y: 40, width: 200, height: 32)), (ghost, NSRect(x: 216, y: 40, width: 140, height: 32)),
                              (popup, NSRect(x: 0, y: 84, width: 0, height: 0))])
            },
            .init(title: "Combobox and Autocomplete (type to filter; static popups below)", height: 40 + 140) {
                let models = ["Claude Haiku", "Claude Sonnet", "Claude Opus", "GPT Astra"]
                let combo = ComboboxView(.combobox, options: models, placeholder: "Search models")
                let auto = ComboboxView(.autocomplete, options: models, placeholder: "Autocomplete")
                @MainActor func list(_ style: MenuPopupView.Style) -> MenuPopupView {
                    let v = MenuPopupView(items: models.enumerated().map { MenuItem($1, kind: .radio($0 == 1)) }, style: style)
                    v.minimumWidth = 200
                    v.highlightedIndex = 2
                    return v
                }
                return Place([(combo, NSRect(x: 0, y: 0, width: 200, height: 32)), (auto, NSRect(x: 216, y: 0, width: 200, height: 32)),
                              (list(.combobox), NSRect(x: 0, y: 44, width: 0, height: 0)), (list(.autocomplete), NSRect(x: 216, y: 44, width: 0, height: 0))])
            },
            .init(title: "Popover (default, compact, md) and Tooltip (default, glass, code; hover the button)", height: 120) {
                let trigger = ButtonView("Share", variant: .outline)
                trigger.action = { [weak trigger] in
                    if let trigger { PopoverView(content: popoverTitle("Share thread"), width: .sm).show(from: trigger) }
                }
                let hover = ButtonView(nil, icon: .copy, variant: .ghost, size: .icon)
                TooltipController.attach(to: hover, text: "Copy path")
                return Place([(trigger, NSRect(x: 0, y: 0, width: 0, height: 0)), (hover, NSRect(x: 90, y: 0, width: 0, height: 0)),
                              (PopoverView(content: popoverTitle("Share thread")), NSRect(x: 0, y: 44, width: 0, height: 0)),
                              (PopoverView(content: popoverTitle("Share thread"), padding: .compact), NSRect(x: 136, y: 44, width: 0, height: 0)),
                              (TooltipView("Copy path"), NSRect(x: 264, y: 44, width: 0, height: 0)),
                              (TooltipView("Open in editor", variant: .glass), NSRect(x: 264, y: 80, width: 0, height: 0)),
                              (TooltipView("git status --short", variant: .code), NSRect(x: 360, y: 44, width: 0, height: 0))])
            },
        ]
    }

    static var actionsMenu: [MenuItem] {
        [MenuItem("New thread", icon: .squarePen, shortcut: "⌘N"), MenuItem("Copy path", icon: .copy, shortcut: "⇧⌘C"),
         MenuItem("Rename", icon: .pencil), .separator,
         .submenu("Move to", icon: .folder, [MenuItem("Inbox"), MenuItem("Archive"), .separator, MenuItem("New project…")]),
         MenuItem("Archive", icon: .archive, disabled: true), .separator, MenuItem("Delete", icon: .trash2, destructive: true)]
    }

    static var optionsMenu: [MenuItem] {
        [.label("Appearance"), .radio("System", checked: true), .radio("Light", checked: false), .radio("Dark", checked: false),
         .separator, .label("View"), .checkbox("Show sidebar", checked: true), .checkbox("Wrap lines", checked: false)]
    }

    /// Views at fixed frames; a zero size means the intrinsic size.
    final class Place: DSView {
        private let entries: [(NSView, NSRect)]

        init(_ entries: [(NSView, NSRect)]) {
            self.entries = entries
            super.init(frame: .zero)
            entries.forEach { addSubview($0.0) }
        }

        override func layout() {
            super.layout()
            for (view, frame) in entries {
                view.frame = frame.size == .zero ? NSRect(origin: frame.origin, size: view.intrinsicContentSize) : frame
            }
        }
    }
}
