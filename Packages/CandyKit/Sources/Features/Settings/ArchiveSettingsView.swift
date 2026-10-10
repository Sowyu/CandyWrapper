import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// The archived shell of one environment (`orchestration.getArchivedShellSnapshot` → `{projects, threads}`),
/// reduced to what the Archive page lists.
public struct ArchivedSnapshot: Equatable, Sendable {
    public struct Project: Equatable, Sendable {
        public var id: String
        public var title: String
        public var workspaceRoot: String
        public var faviconPath: String?
        public var projectIcon: JSONValue?
    }
    public struct Thread: Equatable, Sendable {
        public var id: String
        public var projectId: String
        public var title: String
        public var archivedAt: String?
        public var createdAt: String
    }
    public var environmentId: String
    public var projects: [Project]
    public var threads: [Thread]

    public init(environmentId: String, _ json: JSONValue) {
        self.environmentId = environmentId
        projects = (json["projects"]?.arrayValue ?? []).compactMap { p in
            guard let id = p["id"]?.stringValue else { return nil }
            return Project(id: id, title: p["title"]?.stringValue ?? "", workspaceRoot: p["workspaceRoot"]?.stringValue ?? "",
                           faviconPath: p["faviconPath"]?.stringValue, projectIcon: p["projectIcon"])
        }
        threads = (json["threads"]?.arrayValue ?? []).compactMap { t in
            guard let id = t["id"]?.stringValue, let projectId = t["projectId"]?.stringValue else { return nil }
            return Thread(id: id, projectId: projectId, title: t["title"]?.stringValue ?? "", archivedAt: t["archivedAt"]?.stringValue,
                          createdAt: t["createdAt"]?.stringValue ?? "")
        }
    }
}

/// `ArchivedThreadsPanel`'s grouping: projects in snapshot order (only the selected project's checkouts at a
/// project scope), each with its threads newest archive first, empty projects dropped.
public enum ArchiveLogic {
    public struct Group: Equatable, Sendable {
        public var environmentId: String
        public var project: ArchivedSnapshot.Project
        public var threads: [ArchivedSnapshot.Thread]
    }

    /// `selected` is the set of `<environmentId>:<projectId>` at a project scope, nil otherwise.
    public static func groups(_ snapshots: [ArchivedSnapshot], selected: Set<String>?) -> [Group] {
        var out: [Group] = []
        for s in snapshots {
            for p in s.projects where selected?.contains("\(s.environmentId):\(p.id)") ?? true {
                let threads = s.threads.filter { $0.projectId == p.id }.sorted { l, r in
                    let lk = l.archivedAt ?? l.createdAt, rk = r.archivedAt ?? r.createdAt
                    return lk != rk ? lk > rk : l.id > r.id
                }
                if !threads.isEmpty { out.append(Group(environmentId: s.environmentId, project: p, threads: threads)) }
            }
        }
        return out
    }
}

/// Settings > Archive (SettingsPanels.tsx `ArchivedThreadsPanel`): archived threads by project with Unarchive,
/// and a context menu with Unarchive and Delete.
public final class ArchiveSettingsView: ScopedSettingsPage {
    private var snapshots: [String: ArchivedSnapshot] = [:]
    private var loading = false
    private var error: String?
    private var loadedFor: [String] = []

    public init(context: SettingsPageContext) {
        super.init(context: context)
        binder.add { [weak self] in self?.update() }
    }

    public override func didShow() { reload() }

    public override func refresh() {
        let ids = context.scope.connected.map(\.id)
        if ids != loadedFor { reload() }
        super.refresh()
    }

    /// `useArchivedThreadSnapshots` for the scope's environments.
    func reload() {
        guard let request = context.request else { return }
        let ids = context.scope.connected.map(\.id)
        loadedFor = ids
        loading = true
        update()
        Task { [weak self] in
            var next: [String: ArchivedSnapshot] = [:]
            var failure: String?
            for id in ids {
                do { next[id] = ArchivedSnapshot(environmentId: id, try await request(id, "orchestration.getArchivedShellSnapshot", .object([:]))) }
                catch { failure = failure ?? "\(error)" }
            }
            guard let self else { return }
            self.snapshots = next
            self.error = failure
            self.loading = false
            self.refresh()
        }
    }

    private func update() {
        let scope = context.scope
        let selected: Set<String>? = scope.isProjectScope ? Set(scope.members.map { "\($0.environmentId):\($0.projectId)" }) : nil
        let groups = ArchiveLogic.groups(loadedFor.compactMap { snapshots[$0] }, selected: selected)
        let nowMs = TimestampFormat.nowMs()
        if groups.isEmpty {
            let title = loading ? "Loading archived threads" : error != nil ? "Could not load archived threads" : "No archived threads"
            let r = SettingsRowView(title: title, detail: loading ? "Checking connected environments." : error ?? "Archived threads will appear here.")
            let icon: NSView = loading ? SpinnerView(size: .sm, tone: .muted) : IconView(name: .archive, size: 14, strokeColor: Themed.color(\.mutedForeground))
            icon.frame.size = NSSize(width: 14, height: 14)
            r.titleIcon = icon
            let s = SettingsSectionView(title: "Archived threads", rows: [r])
            if !loading { anchors["archive"] = s }
            body = [s]
            return
        }
        body = groups.enumerated().map { index, g -> NSView & SettingsGroupRow in
            let rows: [any SettingsGroupRow] = g.threads.map { t in
                let unarchive = ButtonView("Unarchive", icon: .archiveX, variant: .outline, size: .xs)
                unarchive.iconSize = 14
                unarchive.action = { [weak self] in self?.unarchive(g.environmentId, t) }
                let r = ArchivedThreadRow(title: t.title,
                                          detail: "Archived \(TimestampFormat.formatRelativeTimeLabel(t.archivedAt ?? t.createdAt, nowMs: nowMs)) · Created \(TimestampFormat.formatRelativeTimeLabel(t.createdAt, nowMs: nowMs))",
                                          control: unarchive)
                r.onContextMenu = { [weak self, weak r] event in
                    guard let self, let r else { return }
                    let items = [MenuItem("Unarchive") { [weak self] in self?.unarchive(g.environmentId, t) },
                                 MenuItem("Delete", destructive: true) { [weak self] in self?.delete(g.environmentId, t) }]
                    MenuPopupView.showContextMenu(items, in: r, at: r.convert(event.locationInWindow, from: nil))
                }
                return r
            }
            let s = SettingsSectionView(title: g.project.title, rows: rows)
            let icon = ProjectMonogramView()
            var source = ProjectIconSource(title: g.project.title, workspaceRoot: g.project.workspaceRoot, faviconPath: g.project.faviconPath,
                                           override: ProjectIconSource.override(g.project.projectIcon))
            source.environmentId = g.environmentId
            icon.source = source
            s.icon = icon
            if index == 0 { anchors["archive"] = s }
            return s
        }
    }

    private func unarchive(_ env: String, _ t: ArchivedSnapshot.Thread) {
        guard let request = context.request else { return }
        Task { [weak self] in
            do {
                _ = try await request(env, "orchestration.dispatchCommand", ThreadCommands.unarchive(ThreadId(t.id)))
                self?.reload()
            } catch {
                self?.context.toast?("Failed to unarchive thread", "\(error)", .error)
            }
        }
    }

    /// `confirmAndDeleteThread`: asks first when "Confirm thread deletion" is on.
    private func delete(_ env: String, _ t: ArchivedSnapshot.Thread) {
        let run: @MainActor () -> Void = { [weak self] in
            guard let self, let request = self.context.request else { return }
            Task { [weak self] in
                do {
                    _ = try await request(env, "orchestration.dispatchCommand",
                                          .object(["type": .string("thread.delete"), "commandId": .string(ThreadCommands.newCommandId()),
                                                   "threadId": .string(t.id)]))
                    self?.reload()
                } catch {
                    self?.context.toast?("Failed to delete thread", "\(error)", .error)
                }
            }
        }
        if context.client.bool("confirmThreadDelete") {
            context.confirm?("Delete thread \"\(t.title.isEmpty ? "this thread" : t.title)\"?\nThis permanently clears conversation history for this thread.", true, run)
        } else {
            run()
        }
    }
}

/// An archived thread's row: a settings row that opens its menu on right click.
final class ArchivedThreadRow: DSView, SettingsGroupRow {
    let row: SettingsRowView
    var onContextMenu: ((NSEvent) -> Void)?
    init(title: String, detail: String, control: NSView) {
        row = SettingsRowView(title: title, detail: detail, control: control)
        super.init(frame: .zero)
        addSubview(row)
    }
    func height(forWidth width: CGFloat) -> CGFloat { row.height(forWidth: width) }
    override func layout() { super.layout(); row.frame = bounds }
    override func rightMouseDown(with event: NSEvent) { onContextMenu?(event) }
    override func menu(for event: NSEvent) -> NSMenu? { nil }
}
