import AppKit
import DesignSystem

/// SettingsScopeNotice.tsx:83-97,121-169: a status sentence and a group of project rows.
final class SettingsProjectChoicesView: DSView, SettingsGroupRow {
    private let message = TextBlockView()
    private let group: SettingsGroupView

    init(context: SettingsPageContext) {
        let duplicates = Dictionary(grouping: context.scope.projects, by: \.displayName)
        group = SettingsGroupView(rows: context.scope.projects.map { project in
            let members = project.members
            let machines = duplicates[project.displayName, default: []].count > 1
                ? members.compactMap { member in context.scope.environments.first { $0.id == member.environmentId }?.label }.joined(separator: ", ") : ""
            let path = members.first?.workspaceRoot ?? ""
            let secondary = [machines, path].filter { !$0.isEmpty }.joined(separator: " · ")
            return ProjectChoice(project: project, secondary: secondary) { [weak context] in
                context?.selectScope?(SettingsScopeSelection(machine: nil, project: project.key))
            }
        })
        super.init(frame: .zero)
        message.text = "Choose a project to manage its name, icon, checkouts and actions."
        message.font = DSFont.ui(14)
        message.lineHeight = 20
        message.color = Themed.color(\.mutedForeground)
        addSubview(message)
        addSubview(group)
    }

    func height(forWidth width: CGFloat) -> CGFloat { message.height(forWidth: max(0, width - 32)) + 12 + group.height(forWidth: width) }

    override func layout() {
        super.layout()
        let h = message.height(forWidth: max(0, bounds.width - 32))
        message.frame = NSRect(x: 16, y: 0, width: max(0, bounds.width - 32), height: h)
        group.frame = NSRect(x: 0, y: h + 12, width: bounds.width, height: group.height(forWidth: bounds.width))
    }

    private final class ProjectChoice: ControlView, SettingsGroupRow {
        private let icon: ProjectMonogramView
        private let title: LabelView
        private let detail: LabelView
        private let chevron = IconView(name: .chevronRight, size: 16, strokeColor: Themed.color(\.mutedForeground))

        init(project: SettingsScopeProject, secondary: String, selected: @escaping @MainActor @Sendable () -> Void) {
            icon = ProjectMonogramView(project.icon ?? ProjectIconSource(title: project.displayName, workspaceRoot: project.members.first?.workspaceRoot ?? ""))
            title = LabelView(project.displayName, font: DSFont.ui(14, weight: .medium))
            detail = LabelView(secondary, font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
            super.init(frame: .zero)
            title.lineHeight = 20
            detail.lineHeight = 16
            [icon, title, detail, chevron].forEach(addSubview)
            scalesWhenPressed = false
            action = selected
            setAccessibilityLabel(project.displayName)
        }

        func height(forWidth width: CGFloat) -> CGFloat { detail.text.isEmpty ? 44 : 60 }
        override func updateLayer() {
            layer?.backgroundColor = state.hoverOrPressed ? Themed.color(\.accent, 0.5).cgColor(in: self) : nil
            layer?.borderWidth = state.focusVisible ? 2 : 0
            layer?.borderColor = Themed.color(\.ring).cgColor(in: self)
        }
        override func layout() {
            super.layout()
            icon.frame = NSRect(x: 16, y: (bounds.height - 16) / 2, width: 16, height: 16)
            title.frame = NSRect(x: 44, y: 12, width: max(0, bounds.width - 88), height: 20)
            detail.frame = NSRect(x: 44, y: 32, width: max(0, bounds.width - 88), height: 16)
            chevron.frame = NSRect(x: bounds.width - 32, y: (bounds.height - 16) / 2, width: 16, height: 16)
        }
    }
}
