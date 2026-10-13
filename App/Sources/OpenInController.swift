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
    /// The details card, built the first time it opens; `render` fills it then.
    private let lazyCard: LazyView<ThreadDetailsCardView>
    private let git: GitController
    private let environments: Environments
    private let composer: ComposerController

    init(card: LazyView<ThreadDetailsCardView>, git: GitController, environments: Environments, composer: ComposerController, shortcuts: Shortcuts?) {
        lazyCard = card
        self.git = git
        self.environments = environments
        self.composer = composer
        card.configure { [weak self] card in
            card.openIn.primary.action = { [weak self] in self?.open(nil) }
            card.openIn.secondary.action = { [weak self] in self?.showMenu() }
            self?.render()
        }
        git.onRender = { [weak self] in self?.render() }
        // `useOpenFavoriteEditorShortcut`: only while the picker shows, an editor is known and there is a workspace.
        shortcuts?.on("editor.openFavorite") { [weak self] _ in
            guard let self, self.isShown, self.remote != .unavailable, let editor = self.preferred, self.cwd != nil else { return false }
            self.open(editor)
            return true
        }
        render()
    }

    private var environmentId: String? { git.target?.environmentId }
    private var cwd: String? { git.target?.cwd }
    /// `resolveRemoteOpenState` (remoteOpen.ts:58-97) for this client, which runs beside its primary environment:
    /// the primary execs locally; any other environment opens through deep links to its desktop SSH alias, else
    /// the first host the server advertises, else it has no SSH route.
    private enum RemoteOpen: Equatable { case localExec, links(host: String), unavailable }
    private var remote: RemoteOpen {
        guard let environmentId, environmentId != environments.primaryId else { return .localExec }
        if let alias = environments.saved.first(where: { $0.environmentId == environmentId })?.sshAlias, !alias.isEmpty { return .links(host: alias) }
        if let host = composer.config(environmentId)?.remoteOpenTargets.first?["host"]?.stringValue { return .links(host: host) }
        return .unavailable
    }
    private var remoteHost: String? { if case .links(let host) = remote { host } else { nil } }
    /// `primaryServerAvailableEditorsAtom` locally; in remote mode the remote-capable ones (`useRemoteCapableEditors`,
    /// the primary's probe standing in for the desktop's), VS Code when none.
    private var available: [String] {
        let local = environments.primaryId.flatMap { composer.config($0)?.availableEditors } ?? []
        guard remote != .localExec else { return local }
        let capable = local.filter { OpenInEditors.remoteURL(editor: $0, host: "host", path: "/") != nil }
        return capable.isEmpty ? ["vscode"] : capable
    }
    private var preferred: String? {
        OpenInEditors.preferred(available: available, last: UserDefaults.standard.string(forKey: OpenInEditors.lastEditorKey))
    }
    /// `shouldShowOpenInPicker` (OpenInPicker.logic.ts:5-22): the primary environment, or a remote one in link or
    /// "no SSH route" mode.
    private var isShown: Bool { git.target != nil }
    /// `environmentLabel` in the menu's remote rows.
    private var environmentLabel: String { environmentId.flatMap { environments.label($0) } ?? "this machine" }

    private static func icon(_ editor: String) -> IconName {
        switch editor {
        case "file-manager": .brandFinder
        case "cursor": .brandCursor
        case "kiro": .brandKiro
        case "trae": .brandTrae
        case "zed": .brandZed
        default: .squareArrowOutUpRight
        }
    }

    func render() {
        guard let card = lazyCard.loaded else { return }
        card.showsOpenIn = isShown
        guard isShown else { return }
        let editor = preferred
        let part = card.openIn.primary
        // `primaryLabel` in panel mode, with the primary option's icon (`text-foreground`, every editor is a
        // brand on macOS) or the generic one in `muted-foreground`.
        part.text = "Open in \(editor.map(OpenInEditors.label) ?? "editor")"
        part.image = editor.flatMap(OpenInEditors.image)
        part.icon = (editor.map(Self.icon) ?? .squareArrowOutUpRight).definition
        part.iconColor = editor == nil ? nil : Themed.color(\.contrastForeground)
        part.isEnabled = editor != nil && cwd != nil && remote != .unavailable
        part.setAccessibilityLabel(part.text)
    }

    /// The chevron's menu (`editorItems`, OpenInPicker.tsx:322-358): every available editor, the preferred one with
    /// the shortcut, then the one-time SSH hint; or the "no SSH route" row.
    private func showMenu() {
        let options = OpenInEditors.options(available: available)
        let shortcut = ActiveKeymap.label(for: "editor.openFavorite")
        var items = options.map { option in
            var item = MenuItem(option.label, icon: Self.icon(option.id), shortcut: option.id == preferred ? shortcut : nil,
                                disabled: cwd == nil) { [weak self] in self?.open(option.id) }
            item.image = OpenInEditors.image(option.id)
            // `getOpenInIconClass("brand")`: `text-foreground opacity-100`.
            item.iconColor = Themed.color(\.foreground)
            return item
        }
        if items.isEmpty { items = [MenuItem("No installed editors found", disabled: true)] }
        if remote != .localExec, !UserDefaults.standard.bool(forKey: OpenInEditors.remoteHintSeenKey) {
            items.append(MenuItem("Opens over SSH. Needs your key on \(environmentLabel)", disabled: true))
        }
        if remote == .unavailable { items = [MenuItem("No SSH route to \(environmentLabel)", disabled: true)] }
        let split = lazyCard.view.openIn
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
        guard let environmentId, let cwd, let editor = editorId ?? preferred, remote != .unavailable else { return }
        if let remoteHost {
            guard let url = OpenInEditors.remoteURL(editor: editor, host: remoteHost, path: cwd), NSWorkspace.shared.open(url) else { return }
            UserDefaults.standard.set(true, forKey: OpenInEditors.remoteHintSeenKey)
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
