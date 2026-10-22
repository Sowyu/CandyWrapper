import T3Protocol
import T3Store

/// The menu bar item's menu, after Capy's tray menu (`ONe` and `TNe` in Capy.app's app.asar, out/main/main.js;
/// docs/research/capy-menubar.md): the five most recent threads, "View all threads…", New Thread, what is
/// running, then Quit. Built when the menu opens, as Capy rebuilds it on mouse-down, so nothing watches the store.
public enum MenuBarMenu {
    public enum Row: Equatable, Sendable {
        /// A disabled line.
        case label(String)
        case thread(ThreadId, title: String)
        case viewAll
        case newThread
        case separator
        case quit
    }

    /// Capy's `bNe`.
    public static let threadLimit = 5
    /// Capy's `_Ne` cuts titles at 48 characters.
    public static let titleLimit = 48

    public static func rows(_ snapshot: ShellSnapshot?) -> [Row] {
        var rows: [Row] = []
        let live = (snapshot?.threads ?? []).filter { $0.archivedAt == nil }
        if snapshot == nil {
            rows.append(.label("Loading threads…"))
        } else if live.isEmpty {
            rows.append(.label("No recent threads"))
        } else {
            // The palette's and the sidebar's recency (`getThreadSortTimestamp`, updated_at).
            let recent = live.map { ($0, SidebarModel.getThreadSortTimestamp($0, .updatedAt)) }.sorted { $0.1 > $1.1 }
            rows.append(.label("Recent threads"))
            rows += recent.prefix(threadLimit).map { .thread($0.0.id, title: title($0.0.title)) }
            if live.count > threadLimit { rows.append(.viewAll) }
        }
        rows += [.separator, .newThread, .separator]
        // Capy's keep-awake line (`MNe`) counts running workspaces; T3 holds no power assertion, so this
        // counts the running threads instead.
        let running = live.filter { [.preparing, .starting, .running].contains($0.status) }.count
        if running > 0 { rows += [.label(running == 1 ? "1 thread running" : "\(running) threads running"), .separator] }
        rows.append(.quit)
        return rows
    }

    static func title(_ raw: String) -> String {
        let t = raw.isEmpty ? "Untitled thread" : raw
        return t.count > titleLimit ? String(t.prefix(titleLimit - 1)) + "…" : t
    }
}
