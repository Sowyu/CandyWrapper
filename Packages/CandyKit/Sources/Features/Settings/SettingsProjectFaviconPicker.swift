import AppKit
import DesignSystem
import T3Protocol

/// ProjectFaviconPickerDialog.tsx:30-142, using the shared command palette and its keyboard routing.
@MainActor final class SettingsProjectFaviconPicker {
    private let controller = CommandPaletteController(source: .init(rootGroups: { [] }))
    private var overlay: CommandPaletteOverlay?
    private var task: Task<Void, Never>?
    private var paths: [String] = []
    private var message = "Indexing project files…"
    private let context: SettingsPageContext
    private let member: SettingsScopeProject.Member
    private let onSelect: (String) -> Void
    init(context: SettingsPageContext, member: SettingsScopeProject.Member, onSelect: @escaping (String) -> Void) {
        self.context = context; self.member = member; self.onSelect = onSelect
    }
    func present(in window: NSWindow) {
        controller.setMode(.init(name: "project-favicon", placeholder: "Search image files…", footerActionLabel: "Select icon") { [weak self] _ in
            guard let self else { return ([], "") }
            let entries = self.paths.map { path in
                PaletteEntry(value: path, searchTerms: [path], title: (path as NSString).lastPathComponent, description: path, icon: .image,
                             action: .run({ [weak self] in self?.onSelect(path); self?.close() }, keepOpen: false))
            }
            return ([PaletteGroup(value: "project-favicon-files", label: self.member.title, items: entries)], self.message)
        })
        controller.onQueryChange = { [weak self] in self?.search($0) }
        controller.onClose = { [weak self] in self?.close() }
        let overlay = CommandPaletteOverlay(controller: controller)
        self.overlay = overlay
        overlay.onDismiss = { [weak self] in self?.task?.cancel(); self?.task = nil; self?.overlay = nil }
        overlay.present(in: window)
        search("")
    }
    func close() { task?.cancel(); task = nil; overlay?.close() }
    private func search(_ query: String) {
        task?.cancel()
        paths = []; message = query.isEmpty ? "Indexing project files…" : "Searching project files…"
        controller.refresh()
        guard let request = context.request else { return }
        let member = member
        task = Task { [weak self] in
            do {
                let result = try await request(member.environmentId, "projects.searchEntries", .object([
                    "cwd": .string(member.workspaceRoot), "query": .string(query), "limit": .number(100), "imageOnly": .bool(true),
                ]))
                guard !Task.isCancelled, let self else { return }
                self.paths = (result["entries"]?.arrayValue ?? []).compactMap { $0["path"]?.stringValue }
                self.message = query.isEmpty ? "No image files found." : "No matching image files."
                self.controller.refresh()
            } catch {
                guard !Task.isCancelled else { return }
                self?.message = error.localizedDescription; self?.controller.refresh()
            }
        }
    }
}
