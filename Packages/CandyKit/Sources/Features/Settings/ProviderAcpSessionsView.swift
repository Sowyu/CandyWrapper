import AppKit
import DesignSystem
import T3Protocol

/// AcpSessionManagementSection.tsx:97-197, 315-476. Session requests run only on explicit actions.
public final class ProviderAcpSessionsView: DSView, SettingsGroupRow {
    private let context: SettingsPageContext
    private let environment: String, instance: String
    private let canImport: Bool, canDelete: Bool, readOnly: Bool
    private let projects: [SettingsScopeProject.Member]
    private var selected = 0
    private var sessions: [JSONValue] = []
    private var cursor: String?
    private var busy = false
    private var error: String?
    private var rows: [SettingsRowView] = []
    public var onHeightChange: (() -> Void)?
    public init(context: SettingsPageContext, environment: String, instance: String, provider: ServerProvider, readOnly: Bool) {
        self.context = context; self.environment = environment; self.instance = instance; self.readOnly = readOnly
        canImport = provider.nativeSessions?["canLoad"]?.boolValue == true || provider.nativeSessions?["canResume"]?.boolValue == true
        canDelete = provider.nativeSessions?["canDelete"]?.boolValue == true
        projects = context.scope.projects.flatMap(\.members).filter { $0.environmentId == environment }
        super.init(frame: .zero); rebuild()
    }
    private func input(session: JSONValue? = nil) -> [String: JSONValue] {
        var value: [String: JSONValue] = ["instanceId": .string(instance), "projectId": .string(projects[selected].projectId)]
        if let session { value["sessionId"] = session["sessionId"] }
        return value
    }
    private func load(more: Bool = false) {
        guard !busy, !projects.isEmpty, let request = context.request else { return }
        var payload = input(); if more, let cursor { payload["cursor"] = .string(cursor) }
        busy = true; error = nil; rebuild(); let env = environment
        Task { [weak self] in
            do {
                let result = try await request(env, "server.listAcpRegistrySessions", .object(payload))
                guard let self else { return }; let next = result["sessions"]?.arrayValue ?? []
                self.sessions = more ? self.sessions + next : next; self.cursor = result["nextCursor"]?.stringValue
            } catch { self?.error = String(describing: error) }
            self?.busy = false; self?.rebuild()
        }
    }
    private func act(_ session: JSONValue, delete: Bool) {
        guard !busy, !readOnly, let request = context.request, session["importedThreadId"]?.stringValue == nil else { return }
        var payload = input(session: session)
        if !delete { payload["title"] = session["title"] ?? .null; payload["updatedAt"] = session["updatedAt"] ?? .null }
        busy = true; error = nil; rebuild(); let env = environment
        Task { [weak self] in
            do {
                let result = try await request(env, delete ? "server.deleteAcpRegistrySession" : "server.importAcpRegistrySession", .object(payload))
                guard let self else { return }
                if delete { self.sessions.removeAll { $0["sessionId"] == session["sessionId"] } }
                else if let i = self.sessions.firstIndex(where: { $0["sessionId"] == session["sessionId"] }) {
                    var value = self.sessions[i].objectValue ?? [:]; value["importedThreadId"] = result["threadId"]; self.sessions[i] = .object(value)
                }
                self.context.toast?(delete ? "ACP session deleted" : result["imported"]?.boolValue == true ? "ACP session imported" : "ACP session already imported", nil, .success)
            } catch { self?.error = String(describing: error) }
            self?.busy = false; self?.rebuild()
        }
    }
    private func rebuild() {
        rows.forEach { $0.removeFromSuperview() }; rows = []
        let select = SelectView(options: projects.map(\.title), selected: projects.isEmpty ? nil : selected, size: .sm)
        select.isEnabled = !busy
        select.onChange = { [weak self] index in self?.selected = index; self?.sessions = []; self?.cursor = nil; self?.rebuild() }
        let list = ButtonView(busy ? "Loading" : sessions.isEmpty ? "List sessions" : "Refresh", variant: .outline, size: .sm)
        list.isEnabled = !busy && !projects.isEmpty; list.action = { [weak self] in self?.load() }
        let top = SettingsRowView(title: "Native sessions", detail: "Resume agent-owned conversations as T3 threads.", control: projects.isEmpty ? nil : SettingsControlGroup([select, list]))
        top.status = error ?? (projects.isEmpty ? "Add a project before importing sessions." : nil); rows.append(top)
        for session in sessions {
            let imported = session["importedThreadId"]?.stringValue != nil
            let add = ButtonView(imported ? "Imported" : "Import", variant: .ghostMuted, size: .xs)
            add.isEnabled = !readOnly && !busy && !imported && canImport
            add.action = { [weak self] in self?.act(session, delete: false) }
            var actions: [NSView] = [add]
            if canDelete {
                let remove = ButtonView("Delete", variant: .ghostMuted, size: .xs)
                remove.isEnabled = !readOnly && !busy && !imported
                remove.action = { [weak self] in
                    let title = session["title"]?.stringValue ?? session["sessionId"]?.stringValue ?? ""
                    self?.context.confirm?("Permanently delete native ACP session \"\(title)\"?", true, { [weak self] in self?.act(session, delete: true) })
                }; actions.append(remove)
            }
            rows.append(SettingsRowView(title: session["title"]?.stringValue ?? session["sessionId"]?.stringValue ?? "", detail: session["sessionId"]?.stringValue, control: SettingsControlGroup(actions)))
        }
        if cursor != nil {
            let more = ButtonView("Load more", variant: .ghostMuted, size: .xs); more.isEnabled = !busy
            more.action = { [weak self] in self?.load(more: true) }; rows.append(SettingsRowView(title: "", control: more))
        }
        rows.forEach(addSubview); needsLayout = true; onHeightChange?()
    }
    public func height(forWidth width: CGFloat) -> CGFloat { rows.reduce(0) { $0 + $1.height(forWidth: width) } }
    public override func layout() {
        super.layout(); var y: CGFloat = 0
        for row in rows { let h = row.height(forWidth: bounds.width); row.frame = NSRect(x: 0, y: y, width: bounds.width, height: h); y += h }
    }
}
