import Foundation

/// The window title (4928 branding.logic.ts `resolveWindowTitle`, Sidebar.logic.ts
/// `resolveWindowTitleThreadStatus`, #34697): `project / thread` with a thread open, the app's name
/// without one. With the screen reader setting on it leads with what the thread is doing, then the
/// thread, then the project, since a screen reader reads from the start.
public enum WindowTitle {
    /// `THREAD_STATUS_TEXT` (client-runtime threadActivityAnnouncement.ts:9-16) for the open thread,
    /// or nil when it is not working or waiting on the user.
    public static func threadStatus(_ thread: SidebarThread) -> String? {
        threadStatus(hasPendingApprovals: thread.hasPendingApprovals || thread.pendingSubagentRequest == .approval,
                     hasPendingUserInput: thread.hasPendingUserInput || thread.pendingSubagentRequest == .userInput,
                     runtime: thread.runtime, blockedOnThreadWait: thread.shell.blockedOnThreadWait == true)
    }

    public static func threadStatus(hasPendingApprovals: Bool, hasPendingUserInput: Bool, runtime: ThreadRuntimeSummary?,
                                    blockedOnThreadWait: Bool = false) -> String? {
        // A guest waiting doesn't hide that the agent is still working.
        let status = SidebarModel.resolveSidebarThreadStatus(hasPendingApprovals: hasPendingApprovals, hasPendingUserInput: hasPendingUserInput,
                                                             runtime: runtime, blockedOnThreadWait: blockedOnThreadWait, pendingGuestMessageCount: 0)
        switch status {
        case .approval: return "Needs approval"
        case .input: return "Needs your input"
        case .working: return "Working"
        // Waiting on a child thread is still this turn, so it must not read as finished.
        case .waiting: return runtime?.status == .running ? "Working" : nil
        default: return nil
        }
    }

    /// `resolveWindowTitle` on the desktop, where the OS already shows the app's name.
    /// `screenReader` is nil with the setting off, else the thread's status or nil.
    public static func resolve(appName: String, projectTitle: String?, threadTitle: String?, screenReader: String?? = nil) -> String {
        let thread = threadTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let status = screenReader.flatMap { $0 }
        guard !thread.isEmpty else { return status.map { "\($0): \(appName)" } ?? appName }
        let project = projectTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let context = project.isEmpty ? thread : screenReader != nil ? "\(thread) - \(project)" : "\(project) / \(thread)"
        return status.map { "\($0): \(context)" } ?? context
    }
}
