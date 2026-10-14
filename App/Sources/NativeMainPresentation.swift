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
        if let sidebar { presentation.adoptBrand(of: sidebar) }
        var actions = NativeToolbarActions()
        actions.details = { [weak self] in self?.threads.panel.onDetailsToggle?() }
        actions.terminal = { [weak self] in self?.threads.panel.onTerminalToggle?() }
        actions.rightPanel = { [weak self] in self?.threads.panel.toggleRightPanel() }
        actions.maximize = { [weak self] in self?.threads.panel.toggleMaximized() }
        actions.rightPanelOpen = { [weak self] in self?.threads.panel.rightPanelOpen == true && self?.threads.panel.window != nil }
        actions.threadShown = { [weak self] in self?.threads.panel.window != nil }
        actions.panelStates = { [weak self] in
            guard let panel = self?.threads.panel, panel.window != nil else { return NativePanelStates() }
            return NativePanelStates(details: panel.detailsOpen, terminal: panel.terminalOpen, rightPanel: panel.rightPanelOpen,
                                     maximized: panel.rightPanelMaximized)
        }
        presentation.actions = actions
        presentation.breadcrumb = breadcrumb
        presentation.setMaximizeShown(threads.panel.isMaximizable)
        threads.panel.onMaximizableChange = { [weak presentation] in presentation?.setMaximizeShown($0) }
        threads.panel.onPanelTogglesChange = { [weak presentation, weak self] in
            presentation?.syncPanelStates()
            if let self { self.breadcrumb.trailingEdge = self.threads.panel.chatTrailingEdge }
        }
        return presentation
    }

    /// T3's breadcrumb for the toolbar, over the thread panel's hidden header. One for the window's life.
    private lazy var breadcrumb = NativeBreadcrumbView(header: threads.panel.header)

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

    /// The toolbar's breadcrumb in native mode: the page's name, or T3's project / thread crumbs. The window's own
    /// title follows for the Window menu.
    func updateTitle() {
        guard let native = current as? NativeSplitPresentation else { return }
        let page: String? = settings?.isOpen == true ? "Settings"
            : commands?.openUtilityKind.map { $0 == .pullRequests ? "Pull Requests" : "Usage" }
        breadcrumb.show(page: page)
        native.syncPanelStates()
        let thread = threads.panel.header.threadTitle
        native.setTitle(page ?? (thread.isEmpty ? "CandyWrapper" : thread))
    }
}
