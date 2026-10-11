import AppKit
import DesignSystem
import Features
import T3Protocol

/// The thread details card's "Open in" split row and `editor.openFavorite` (Cmd+O): T3's `OpenInPicker`
/// with `displayMode="panel"` (apps/web/src/components/chat/OpenInPicker.tsx:205-463) and
/// `useOpenFavoriteEditorShortcut`. The workspace opens through `shell.openInEditor` on the thread's
/// environment, so the server launches the editor; the choice is remembered as T3's `t3code:last-editor`.
@MainActor
final class OpenInController {
    private let card: ThreadDetailsCardView
    private let git: GitController
    private let environments: Environments
    private let composer: ComposerController

    init(card: ThreadDetailsCardView, git: GitController, environments: Environments, composer: ComposerController, shortcuts: Shortcuts?) {
        self.card = card
        self.git = git
        self.environments = environments
        self.composer = composer
        card.openIn.primary.action = { [weak self] in self?.open(nil) }
        card.openIn.secondary.action = { [weak self] in self?.showMenu() }
        git.onRender = { [weak self] in self?.render() }
        // `useOpenFavoriteEditorShortcut`: only while the picker shows, an editor is known and there is a workspace.
        shortcuts?.on("editor.openFavorite") { [weak self] _ in
            guard let self, self.isShown, let editor = self.preferred, self.cwd != nil else { return false }
            self.open(editor)
            return true
        }
        render()
    }

    private var environmentId: String? { git.target?.environmentId }
    private var cwd: String? { git.target?.cwd }
    /// `primaryServerAvailableEditorsAtom`: the primary environment's editors.
    private var remoteHost: String? {
        guard let environmentId, environmentId != environments.primaryId else { return nil }
        if let alias = environments.saved.first(where: { $0.environmentId == environmentId })?.sshAlias, !alias.isEmpty { return alias }
        return composer.config(environmentId)?.remoteOpenTargets.first?["host"]?.stringValue
    }
    private var available: [String] {
        let local = environments.primaryId.flatMap { composer.config($0)?.availableEditors } ?? []
        guard remoteHost != nil else { return local }
        let remote = local.filter { OpenInEditors.remoteURL(editor: $0, host: "host", path: "/") != nil }
        return remote.isEmpty ? ["vscode"] : remote
    }
    private var preferred: String? {
        OpenInEditors.preferred(available: available, last: UserDefaults.standard.string(forKey: OpenInEditors.lastEditorKey))
    }
    private var isShown: Bool {
        git.target != nil && (environmentId == environments.primaryId || remoteHost != nil)
    }

    private static func icon(_ editor: String) -> IconName {
        switch editor {
        case "file-manager": .brandFinder
        case "cursor": .brandCursor
        case "kiro": .brandKiro
        case "trae": .brandTrae
        // ponytail: VS Code, Zed and the JetBrains IDEs use the generic glyph; add their brand marks from Icons.tsx and JetBrainsIcons.tsx
        default: .squareArrowOutUpRight
        }
    }

    func render() {
        card.showsOpenIn = isShown
        guard isShown else { return }
        let editor = preferred
        let part = card.openIn.primary
        // `primaryLabel` in panel mode, with the primary option's icon or the generic one.
        part.text = "Open in \(editor.map(OpenInEditors.label) ?? "editor")"
        part.icon = (editor.map(Self.icon) ?? .squareArrowOutUpRight).definition
        part.isEnabled = editor != nil && cwd != nil
        part.setAccessibilityLabel(part.text)
    }

    /// The chevron's menu (`editorItems`): every available editor, the preferred one with the shortcut.
    private func showMenu() {
        let options = OpenInEditors.options(available: available)
        let shortcut = ActiveKeymap.label(for: "editor.openFavorite")
        var items = options.map { option in
            var item = MenuItem(option.label, icon: Self.icon(option.id), shortcut: option.id == preferred ? shortcut : nil,
                                disabled: cwd == nil) { [weak self] in self?.open(option.id) }
            item.iconColor = Self.icon(option.id).isBrand ? nil : Themed.color(\.foreground)
            return item
        }
        if items.isEmpty { items = [MenuItem("No installed editors found", disabled: true)] }
        let split = card.openIn
        MenuPopupView.show(items, from: split.secondary, placement: PopupPlacement(side: .bottom, align: .end, sideOffset: 4, fallbackAxisSide: .none),
                           minimumWidth: split.bounds.width, anchorRect: split.convert(split.bounds, to: split.secondary))
    }

    func openFile(_ meta: FileLinkMeta) {
        guard let environmentId, let editor = preferred else { return }
        if let remoteHost {
            if let url = OpenInEditors.remoteURL(editor: editor, host: remoteHost, path: meta.targetPath) { NSWorkspace.shared.open(url) }
            return
        }
        Task { _ = try? await environments.request(environmentId, "shell.openInEditor", OpenInEditors.launchInput(cwd: meta.targetPath, editor: editor)) }
    }

    private func open(_ editorId: String?) {
        guard let environmentId, let cwd, let editor = editorId ?? preferred else { return }
        if let remoteHost {
            guard let url = OpenInEditors.remoteURL(editor: editor, host: remoteHost, path: cwd), NSWorkspace.shared.open(url) else { return }
            UserDefaults.standard.set(editor, forKey: OpenInEditors.lastEditorKey)
            render()
            return
        }
        UserDefaults.standard.set(editor, forKey: OpenInEditors.lastEditorKey)
        render()
        // T3 reports a failure only to the console (`useAtomCommand(…, "open in editor")`).
        Task { _ = try? await environments.request(environmentId, "shell.openInEditor", OpenInEditors.launchInput(cwd: cwd, editor: editor)) }
    }
}
