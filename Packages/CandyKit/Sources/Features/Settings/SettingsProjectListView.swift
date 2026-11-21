import AppKit
import DesignSystem

/// Redesign's Settings > Projects at "All projects": one row per project in a single card, where T3 and the
/// glass themes show the chooser (SettingsScopeNotice.tsx:121-169). The user, 2026-11-21, chose a list over
/// the pile of pills: icon, name, machine, thread count, chevron, and a search field once the list is long.
public struct SettingsProjectListEntry: Equatable, Sendable {
    /// The project key a click selects, as the pill did.
    public var key: String
    public var name: String
    /// Every machine the row stands for, by label.
    public var machines: [String]
    public var path: String
    public var threadCount: Int
    public var pinned: Bool
    public var isScratch: Bool
    public var icon: ProjectIconSource?
    /// Why the row offers no delete: an offline machine or a connection that can't change projects. Nil
    /// when it can be deleted. Scratch rows never can, and show no menu at all.
    public var deleteBlockedReason: String? = nil
    public var canDelete: Bool { !isScratch && deleteBlockedReason == nil }

    /// The muted line under the name: the machines, then the path. A scratch row has its machine in its name.
    public var detail: String {
        let place = isScratch ? "" : machines.count > 1 ? "\(machines.count) machines: " + machines.joined(separator: ", ") : machines.first ?? ""
        return [place, path].filter { !$0.isEmpty }.joined(separator: " · ")
    }
    /// Empty for a project with no threads, so the column only holds counts that say something.
    public var threadLabel: String { threadCount == 0 ? "" : threadCount == 1 ? "1 thread" : "\(threadCount) threads" }
    public var accessibilityLabel: String {
        let machine = machines.count > 1 ? "\(machines.count) machines, " + machines.joined(separator: ", ") : machines.first ?? ""
        return [name, pinned ? "pinned" : "", machine, threadLabel].filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

public enum SettingsProjectList {
    /// More projects than this get a search field.
    public static let searchThreshold = 8

    /// Pinned projects first, then by name ignoring case, then the scratch folders by machine. Scratch groups
    /// on the same set of machines fold into one row, summing their threads.
    public static func entries(_ scope: SettingsScopeState) -> [SettingsProjectListEntry] {
        func label(_ id: String, fallback: String?) -> String {
            scope.environments.first { $0.id == id }.map(scope.environmentLabel) ?? fallback ?? id
        }
        var rows: [SettingsProjectListEntry] = []
        for p in scope.projectMenu {
            var machines: [String] = []
            for m in p.members {
                let l = label(m.environmentId, fallback: m.environmentLabel)
                if !machines.contains(l) { machines.append(l) }
            }
            let paths = Set(p.members.map(\.workspaceRoot))
            let entry = SettingsProjectListEntry(
                key: p.key, name: p.isScratch ? (["No project"] + machines).joined(separator: " · ") : p.displayName,
                machines: machines, path: paths.count == 1 ? paths.first! : "", threadCount: p.threadCount,
                pinned: p.pinned, isScratch: p.isScratch, icon: p.icon,
                deleteBlockedReason: p.isScratch ? nil : deleteBlockedReason(p, scope))
            if entry.isScratch, let i = rows.firstIndex(where: { $0.isScratch && $0.machines == machines }) {
                rows[i].threadCount += entry.threadCount
                if rows[i].path != entry.path { rows[i].path = "" }
                continue
            }
            rows.append(entry)
        }
        return rows.sorted { a, b in
            if a.isScratch != b.isScratch { return !a.isScratch }
            if a.pinned != b.pinned { return a.pinned }
            let order = a.name.localizedCaseInsensitiveCompare(b.name)
            return order != .orderedSame ? order == .orderedAscending : a.key < b.key
        }
    }

    /// `checkProjectAccess` (useProjectGroupUpdate.ts:145-162) plus the connection: the first member whose
    /// environment is offline or won't let this connection change projects.
    static func deleteBlockedReason(_ p: SettingsScopeProject, _ scope: SettingsScopeState) -> String? {
        for m in members(p, scope) {
            let env = scope.environments.first { $0.id == m.environmentId }
            let label = env.map(scope.environmentLabel) ?? m.environmentLabel
            guard let env, env.connected else { return "\(label ?? "This environment") is offline." }
            if !env.canWrite {
                return label.map { "This connection cannot change projects in \($0)." }
                    ?? "This connection cannot change projects in this environment."
            }
        }
        return nil
    }

    /// The checkouts a delete from the list removes: all of them, or the chosen machine's (`scope.members`).
    static func members(_ p: SettingsScopeProject, _ scope: SettingsScopeState) -> [SettingsScopeProject.Member] {
        p.members.filter { scope.selection.machine == nil || $0.environmentId == scope.selection.machine }
    }

    /// What deleting row `key` does: T3's removal prompt (`planProjectRemoval`, projectRemoval.ts:30-90) and
    /// a button that names the loss. Nil for a scratch row, a blocked one or a gone key.
    public static func deletion(key: String, scope: SettingsScopeState, threadCount: (String, String) -> Int) -> SettingsProjectDeletion? {
        guard let p = scope.projectMenu.first(where: { $0.key == key }), !p.isScratch, deleteBlockedReason(p, scope) == nil else { return nil }
        let chosen = members(p, scope)
        guard !chosen.isEmpty else { return nil }
        let threads = chosen.reduce(0) { $0 + threadCount($1.environmentId, $1.projectId) }
        let hasOtherMembers = chosen.count < p.members.count
        let message = ProjectRemoval.message(members: chosen, allMembers: chosen, hasOtherMembers: hasOtherMembers,
                                             groupName: p.displayName, threadCount: threads)
        let noun = hasOtherMembers ? "checkout" : "project"
        let button = threads > 0 ? "Delete \(noun) and \(threads) thread\(threads == 1 ? "" : "s")" : "Delete \(noun)"
        return SettingsProjectDeletion(name: p.displayName, members: chosen, threadCount: threads, message: message, confirmTitle: button)
    }

    /// Rows whose name, machine or path contains every word of the query, ignoring case and accents.
    public static func filter(_ entries: [SettingsProjectListEntry], query: String) -> [SettingsProjectListEntry] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return entries }
        return entries.filter { e in
            let hay = ([e.name, e.path] + e.machines).joined(separator: "\n")
            return words.allSatisfy { hay.localizedStandardContains($0) }
        }
    }
}

/// A delete the list asks to confirm.
public struct SettingsProjectDeletion: Equatable, Sendable {
    public var name: String
    public var members: [SettingsScopeProject.Member]
    public var threadCount: Int
    /// T3's lines: the question, then path, environment, what goes with it, and that it can't be undone.
    public var message: String
    public var confirmTitle: String
}

/// The page body: an optional search field over one card of rows. Kept across scope refreshes so a query
/// survives a shell update; `reload` swaps the data.
final class SettingsProjectListView: DSView, SettingsGroupRow, RouteModalEscapeHandler {
    let search = InputGroupView(placeholder: "Search projects", leading: .icon(.search))
    private let group = SettingsGroupView(rows: [])
    private let noMatch = KeybindingsSettingsView.EmptyMessageRow("No projects match",
        redesign: StateCopy(title: "No projects match", detail: "Search by the project's name or its machine.", icon: .search))
    private let noProjects = KeybindingsSettingsView.EmptyMessageRow("Add a project from the sidebar to configure it here.",
        redesign: StateCopy(title: "No projects yet", detail: "Add a project from the sidebar to configure it here.", icon: .folder))
    private var entries: [SettingsProjectListEntry] = []
    private var rowViews: [String: Row] = [:]
    private var select: @MainActor (String) -> Void
    /// Asks to delete the row with this key; the page confirms first.
    var onDelete: (@MainActor (String) -> Void)?
    private(set) var query = "" { didSet { if query != oldValue { apply() } } }
    var shown: [SettingsProjectListEntry] { SettingsProjectList.filter(entries, query: query) }
    private var showsSearch: Bool { entries.count > SettingsProjectList.searchThreshold }

    init(entries: [SettingsProjectListEntry], select: @escaping @MainActor (String) -> Void) {
        self.select = select
        super.init(frame: .zero)
        search.input.size = .sm
        search.input.setAccessibilityLabel("Search projects")
        search.input.onChange = { [weak self] text in self?.query = text }
        search.input.onCommand = { [weak self] selector in
            guard let self, selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            if !self.takeRouteModalEscape() { self.window?.makeFirstResponder(self.superview) }
            return true
        }
        addSubview(search)
        addSubview(group)
        reload(entries, select: select)
    }

    func reload(_ entries: [SettingsProjectListEntry], select: @escaping @MainActor (String) -> Void) {
        self.select = select
        guard entries != self.entries || rowViews.isEmpty else { return }
        self.entries = entries
        var next: [String: Row] = [:]
        for e in entries {
            let row = rowViews[e.key] ?? Row()
            row.entry = e
            row.action = { [weak self] in self?.select(e.key) }
            row.onDelete = { [weak self] in self?.onDelete?(e.key) }
            next[e.key] = row
        }
        rowViews = next
        if !showsSearch, !query.isEmpty { search.input.text = ""; query = "" }
        apply()
    }

    /// Esc with a query clears it and keeps Settings open (as Keybindings does, #35161).
    func takeRouteModalEscape() -> Bool {
        guard !query.isEmpty else { return false }
        search.input.text = ""
        query = ""
        return true
    }

    private func apply() {
        search.isHidden = !showsSearch
        let rows = shown.compactMap { rowViews[$0.key] }
        group.rows = !rows.isEmpty ? rows : entries.isEmpty ? [noProjects] : [noMatch]
        needsLayout = true
        // The page measures its sections again; the list scrolls with the page, not by itself.
        var v: NSView? = superview
        while let view = v, !(view is SettingsPageBase) { v = view.superview }
        (v as? SettingsPageBase)?.onHeightChange?()
        v?.needsLayout = true
    }

    private var searchHeight: CGFloat { showsSearch ? 32 + 12 : 0 }

    func height(forWidth width: CGFloat) -> CGFloat {
        searchHeight + group.height(forWidth: width)
    }

    override func layout() {
        super.layout()
        search.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 32)
        group.frame = NSRect(x: 0, y: searchHeight, width: bounds.width, height: group.height(forWidth: bounds.width))
    }

    /// One project: the sidebar's favicon, the name over its machines and path, the thread count, a chevron.
    final class Row: ControlView, SettingsGroupRow {
        private let icon = ProjectMonogramView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        private let title = LabelView("", font: DSFont.ui(13, weight: .medium))
        private let detail = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
        private let count = LabelView("", font: DSFont.ui(12).monospacedDigits, color: Themed.color(\.mutedForeground))
        /// Pinned projects sort first, so they carry the sidebar's pin to say why.
        private let pin = IconView(name: .pin, size: 12, strokeColor: Themed.color(\.mutedForeground))
        private let chevron = IconView(name: .chevronRight, size: 16, strokeColor: Themed.color(\.mutedForeground))
        let more = ButtonView(nil, icon: .ellipsis, variant: .ghostMuted, size: .iconXs)
        private var tip: TooltipController?
        var onDelete: (@MainActor () -> Void)?

        var entry: SettingsProjectListEntry? {
            didSet {
                guard let entry, entry != oldValue else { return }
                icon.source = entry.icon ?? ProjectIconSource(title: entry.isScratch ? "No project" : entry.name, workspaceRoot: entry.path)
                icon.allowsSprite = !entry.isScratch
                title.text = entry.name
                detail.text = entry.detail
                count.text = entry.threadLabel
                pin.isHidden = !entry.pinned
                setAccessibilityLabel(entry.accessibilityLabel)
                more.isHidden = entry.isScratch
                more.setAccessibilityLabel("More actions for \(entry.name)")
                // The full line when the row cuts it.
                if tip == nil { tip = TooltipController.attach(to: detail, text: entry.detail) } else { tip?.text = entry.detail }
                needsLayout = true
            }
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            icon.scale = 20 / 16
            title.lineHeight = 18
            detail.lineHeight = 16
            count.lineHeight = 16
            count.alignment = .right
            [icon, title, detail, count, pin, more, chevron].forEach(addSubview)
            more.action = { [weak self] in self?.showMenu(nil) }
            scalesWhenPressed = false
            setAccessibilityRole(.button)
        }
        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

        func height(forWidth width: CGFloat) -> CGFloat { entry?.detail.isEmpty == false ? 56 : 44 }

        /// "Delete project…", disabled with the reason under it when the machine can't take it. Nothing for scratch rows.
        var menuItems: [MenuItem] {
            guard let entry, !entry.isScratch else { return [] }
            var items = [MenuItem("Delete project…", icon: .trash2, destructive: true, disabled: !entry.canDelete) { [weak self] in
                self?.onDelete?()
            }]
            if let reason = entry.deleteBlockedReason { items.append(.note(reason)) }
            return items
        }

        /// From the … button under it, or as a context menu at the click.
        private func showMenu(_ event: NSEvent?) {
            let items = menuItems
            guard !items.isEmpty else { return }
            if let event {
                MenuPopupView.showContextMenu(items, in: self, at: convert(event.locationInWindow, from: nil))
            } else {
                MenuPopupView.show(items, from: more, placement: PopupPlacement(side: .bottom, align: .end, sideOffset: 4, fallbackAxisSide: .none))
            }
        }

        override func rightMouseDown(with event: NSEvent) {
            guard entry?.isScratch == false else { return super.rightMouseDown(with: event) }
            showMenu(event)
        }

        /// Delete or ⌘⌫ on a focused row opens the same confirmation.
        override func keyDown(with event: NSEvent) {
            let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
            guard event.keyCode == 51 || event.keyCode == 117, mods.isEmpty || mods == .command, let entry, !entry.isScratch else {
                return super.keyDown(with: event)
            }
            if entry.canDelete { onDelete?() } else { NSSound.beep() }
        }

        override func updateLayer() {
            let dark = effectiveAppearance.isDark
            layer?.backgroundColor = RedesignTokens.State.fill(state, dark: dark)?.cgColor
            layer?.cornerRadius = RedesignTokens.Radius.control
            layer?.borderWidth = state.focusVisible ? 2 : 0
            layer?.borderColor = Themed.color(\.ring).cgColor(in: self)
        }

        override func layout() {
            super.layout()
            let h = bounds.height
            icon.frame = NSRect(x: 16, y: (h - 20) / 2, width: 20, height: 20)
            chevron.frame = NSRect(x: bounds.width - 32, y: (h - 16) / 2, width: 16, height: 16)
            more.frame = more.isHidden ? NSRect(x: chevron.frame.minX, y: 0, width: 0, height: 0)
                : NSRect(x: chevron.frame.minX - 4 - 24, y: (h - 24) / 2, width: 24, height: 24)
            let trailing = more.isHidden ? chevron.frame.minX : more.frame.minX
            let cw = count.text.isEmpty ? 0 : ceil(count.textWidth) + 1
            count.frame = NSRect(x: trailing - 8 - cw, y: (h - 16) / 2, width: cw, height: 16)
            var end = cw > 0 ? count.frame.minX : trailing - 8
            if !pin.isHidden {
                pin.frame = NSRect(x: end - (cw > 0 ? 8 : 0) - 12, y: (h - 12) / 2, width: 12, height: 12)
                end = pin.frame.minX
            }
            let tw = max(0, end - 16 - 48)
            if detail.text.isEmpty {
                title.frame = NSRect(x: 48, y: (h - 18) / 2, width: tw, height: 18)
                detail.frame = .zero
            } else {
                title.frame = NSRect(x: 48, y: 10, width: tw, height: 18)
                detail.frame = NSRect(x: 48, y: 30, width: tw, height: 16)
            }
        }
    }
}
