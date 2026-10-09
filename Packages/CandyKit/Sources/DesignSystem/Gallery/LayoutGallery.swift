import AppKit

/// Gallery sections for the layout batch. Each batch owns its own file so agents never edit the same list.
enum LayoutGallery {
    @MainActor static var sections: [ComponentGallery.Section] {
        [
            .init(title: "Settings section", height: 230) {
                let rows = [SettingsRowView(title: "Theme", detail: "Choose how T3 Code looks on this device.",
                                            control: ButtonView("System", variant: .outline, size: .sm)),
                            SettingsRowView(title: "Diff word wrap", control: ButtonView("Off", variant: .outline, size: .sm))]
                return Stack([SettingsSectionView(title: "General", rows: rows)], width: 520)
            },
            .init(title: "Table, group, number field", height: 260) {
                let table = DataTableView(headers: ["Process", "CPU", "Memory"], rows: [["t3 serve", "0.4%", "182 MB"], ["claude", "2.1%", "96 MB"]])
                table.selectedRows = [0]
                let group = GroupView(buttons: ["Left", "Middle", "Right"].map { ButtonView($0, variant: .outline, size: .sm) })
                return Stack([table, group, NumberFieldView(value: 8)], width: 360)
            },
            .init(title: "Wizard steps, discovery list", height: 220) {
                Stack([WizardStepsView(steps: ["Project", "Environment", "Review"], currentStep: 1),
                       DiscoveryListView(rows: [DiscoveryRowView(icon: .folder, title: "candywrapper", detail: "~/Projects/candywrapper"),
                                                DiscoveryRowView(icon: .terminal, title: "t3code", detail: "~/Projects/t3code")])], width: 480)
            },
            .init(title: "Middle truncate, tab close, QR code", height: 200) {
                let tab = PanelTabCloseButton(identity: IconView(name: .terminal, size: 12, strokeColor: Themed.color(\.contrastMutedForeground)))
                tab.isTabHovered = true
                let truncate = MiddleTruncateView("/Users/mrm/Projects/candywrapper/Sources/ScrollAreaView.swift")
                truncate.frame.size = NSSize(width: 200, height: 20)
                return Stack([truncate, tab, QRCodeView(value: "https://t3.codes/download/nightly", size: 128, level: .medium, marginSize: 1)], width: 220)
            },
            .init(title: "Scroll area with fades", height: 180) {
                let rows = (0..<12).map { LabelView("Row \($0 + 1)", font: DSFont.ui(14)) }
                let doc = Stack(rows, width: 240, gap: 12)
                let area = ScrollAreaView(documentView: doc, scrollFade: true)
                area.frame.size = NSSize(width: 240, height: 160)
                area.layoutSubtreeIfNeeded()
                area.scroll(to: NSPoint(x: 0, y: 40))
                area.previewScrollbar(visible: true)
                return area
            },
        ]
    }

    /// Top-to-bottom stack at intrinsic heights, 12pt apart, 16pt in from the left.
    final class Stack: DSView {
        private let gap: CGFloat
        init(_ views: [NSView], width: CGFloat, gap: CGFloat = 12) {
            self.gap = gap
            super.init(frame: .zero)
            views.forEach(addSubview)
            var y: CGFloat = 0
            for v in views {
                let s = v.intrinsicContentSize
                let w = s.width == NSView.noIntrinsicMetric ? width : s.width
                v.frame = NSRect(x: 0, y: y, width: w, height: 0)
                let h = s.height == NSView.noIntrinsicMetric ? (v as? SettingsSectionView)?.height(forWidth: w) ?? max(20, v.frame.height) : s.height
                v.frame.size.height = (v as? SettingsSectionView)?.height(forWidth: w) ?? h
                if v is DataTableView { v.frame.size.height = v.intrinsicContentSize.height }
                y += v.frame.height + gap
            }
            frame.size = NSSize(width: width, height: y)
        }
    }
}
