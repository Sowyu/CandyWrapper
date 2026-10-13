import AppKit
import DesignSystem
import Features
import T3Protocol

/// Builds the main window's presentation for the theme, and swaps it when the theme changes: Glass Native gets
/// the toolbar and split view, every other theme T3's custom layout (docs/glass-native.md). The sidebar, the
/// thread panel and the controllers stay; only the layout around them and the references to it change.
@MainActor
final class MainPresentationController {
    private(set) var current: MainPresentation!
    private let window: MainWindow
    private let threads: ThreadController
    private let environments: Environments
    private weak var sidebar: SidebarContentView?
    /// Set once they exist; a swap re-points them.
    weak var settings: SettingsController?
    weak var commands: SidebarCommands?

    init(window: MainWindow, sidebar: SidebarContentView, main: NSView, threads: ThreadController, environments: Environments) {
        self.window = window
        self.sidebar = sidebar
        self.threads = threads
        self.environments = environments
        let native = ThemeLibrary.shared.usesNativePresentation
        let presentation = make(native: native)
        presentation.sidebarContent = sidebar
        presentation.mainContent = main
        window.nativeChrome = native
        presentation.install(in: window)
        current = presentation
        threads.panel.header.onTitlesChange = { [weak self] in self?.updateTitle() }
        // An environment's label can arrive after its thread opens.
        environments.observe { [weak self] in self?.updateTitle() }
        // Fires only when the stored theme or the theme library changes.
        ThemeLibrary.shared.observe { [weak self] in self?.sync() }
    }

    var isNative: Bool { current is NativeSplitPresentation }

    private func make(native: Bool) -> MainPresentation {
        guard native else {
            let layout = SidebarLayoutView()
            // Every T3 main route covers the inset's grain with a flat `bg-background` (ChatView.tsx:11246,
            // settings.tsx:122, _chat.index.tsx:128), so the official main panel is flat #0a0a0a in dark mode.
            layout.main.showsGrain = false
            return layout
        }
        let presentation = NativeSplitPresentation()
        var actions = NativeToolbarActions()
        actions.newThread = { [weak self] in self?.sidebar?.actions.newThread() }
        actions.files = { [weak self] in self?.threads.panel.toggleRightPanel() }
        actions.git = { [weak self] in self?.threads.panel.onDetailsToggle?() }
        actions.terminal = { [weak self] in self?.threads.panel.onTerminalToggle?() }
        actions.settings = { [weak self] in self?.sidebar?.actions.openSettings() }
        actions.threadShown = { [weak self] in self?.threads.panel.window != nil }
        presentation.actions = actions
        return presentation
    }

    /// Rebuilds the window's content in the other presentation when the theme asks for it.
    func sync() {
        let native = ThemeLibrary.shared.usesNativePresentation
        guard native != isNative else { return }
        let next = make(native: native)
        MainPresentationSwap.swap(from: current, to: next, in: window)
        window.nativeChrome = native
        current = next
        settings?.layout = next
        commands?.layout = next
        ThemeEditorController.shared.host = next.root
        updateTitle()
    }

    /// The toolbar's title and subtitle in native mode: the page, or the thread and "project · environment"
    /// (T3 Mobile ThreadRouteScreen.tsx:441-446).
    func updateTitle() {
        guard let native = current as? NativeSplitPresentation else { return }
        if settings?.isOpen == true { return native.setTitle("Settings", subtitle: "") }
        if let page = commands?.openUtilityKind { return native.setTitle(page == .pullRequests ? "Pull Requests" : "Usage", subtitle: "") }
        let header = threads.panel.header
        let environment = threads.openThreadId?.environmentId.flatMap { environments.label($0) } ?? ""
        let subtitle = [header.projectTitle, environment].filter { !$0.isEmpty }.joined(separator: " · ")
        native.setTitle(header.threadTitle.isEmpty ? "CandyWrapper" : header.threadTitle, subtitle: subtitle)
    }
}
