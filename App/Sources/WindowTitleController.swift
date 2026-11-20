import AppKit
import Features
import T3Protocol
import T3Store

/// `startDocumentTitle` (4928 appInit.tsx:140-200, #34697): names the open thread and its project
/// in the window title, or the app when none is open. With "Screen reader window title" on it leads
/// with the thread's status. VoiceOver reads it on Command-Tab and in the window list. Updates on
/// shell changes, a new open thread and the setting, never on a timer.
@MainActor
final class WindowTitleController {
    private weak var window: NSWindow?
    private weak var sidebar: SidebarContentView?
    /// The open thread, nil while a route without one (Settings, Issues, Pull Requests, Usage) shows.
    var openThreadId: () -> ThreadId?
    private var settingsObserver: Int?

    init(window: NSWindow, sidebar: SidebarContentView, environments: Environments, openThreadId: @escaping () -> ThreadId?) {
        self.window = window
        self.sidebar = sidebar
        self.openThreadId = openThreadId
        environments.observeShell { [weak self] in self?.update() }
        settingsObserver = ClientSettingsStore.shared.observe { [weak self] keys in
            if keys.contains("screenReaderWindowTitle") { self?.update() }
        }
        update()
    }

    func update() {
        guard let window else { return }
        let snapshot = sidebar?.snapshot
        let shell = openThreadId().flatMap { id in snapshot?.threads.first { $0.id == id } }
        let project = shell.flatMap { s in snapshot?.projects.first { $0.id == s.projectId } }
        let screenReader: String?? = ClientSettingsStore.shared.current.bool("screenReaderWindowTitle")
            ? .some(shell.flatMap { WindowTitle.threadStatus(SidebarThread($0)) }) : nil
        // CandyWrapper's own name stands where T3 puts its app name.
        let title = WindowTitle.resolve(appName: "CandyWrapper", projectTitle: project?.title, threadTitle: shell?.title, screenReader: screenReader)
        if window.title != title { window.title = title }
    }
}
