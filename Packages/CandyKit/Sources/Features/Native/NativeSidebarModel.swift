import AppKit
import T3Protocol
import T3Store

/// What `SidebarContentView` needs from the list that shows its items: T3's custom-drawn `SidebarListView`, or
/// Glass Native's `NativeSidebarListView`. Both take the same items and the same `SidebarListCache` patches.
@MainActor
protocol SidebarItemsPresenting: NSView {
    /// The items in `SidebarListBuilder` order, whatever order the list draws them in.
    var items: [SidebarItem] { get }
    var itemsGeneration: Int? { get }
    var nowMs: Int64 { get set }
    func setItems(_ new: [SidebarItem], animated: Bool, generation: Int?)
    func patchItems(_ patch: [(index: Int, item: SidebarItem)]) -> Bool
    var visibleRowModels: [SidebarRowModel] { get }
    func scrollItemToVisible(_ key: String)
    func refreshHoverCard()
}

extension SidebarListView: SidebarItemsPresenting {}

/// Glass Native's list rules from T3 Mobile's iPad sidebar (docs/research/t3-mobile-ipad-design-2026-10-13.md
/// section 2), kept apart from the views so tests can read them.
enum NativeSidebarRules {
    /// T3 Mobile's order (threadListV2.ts:801-840): pinned, active, then drafts, then the shelves. The web list
    /// puts drafts first under a divider, so this moves them and drops the divider. Returns indices into `items`.
    static func displayOrder(_ items: [SidebarItem]) -> [Int] {
        var drafts: [Int] = [], rest: [Int] = []
        for (i, item) in items.enumerated() {
            switch item {
            case .draft: drafts.append(i)
            case .draftDivider: continue
            default: rest.append(i)
            }
        }
        guard !drafts.isEmpty else { return rest }
        let shelf = rest.firstIndex { if case .shelfHeader = items[$0] { true } else { false } } ?? rest.count
        return Array(rest[..<shelf]) + drafts + Array(rest[shelf...])
    }

    /// A swipe's actions (home/thread-swipe-actions.tsx:46-54), first one runs on a full swipe.
    enum Swipe: Equatable {
        case settle, snooze, unsettle, wake, archive

        var title: String {
            switch self {
            case .settle: "Settle"
            case .snooze: "Snooze"
            case .unsettle: "Un-settle"
            case .wake: "Wake"
            case .archive: "Archive"
            }
        }

        var symbol: String {
            switch self {
            case .settle: "checkmark"
            case .snooze, .wake: "clock"
            case .unsettle: "arrow.uturn.backward"
            case .archive: "archivebox"
            }
        }
    }

    /// Card rows settle or snooze, settled rows un-settle, snoozed rows wake. A server without settlement archives.
    static func swipeActions(_ row: SidebarRowModel, settlement: Bool, snooze: Bool) -> [Swipe] {
        guard settlement else { return [.archive] }
        switch row.action {
        case .settle: return row.canSnooze && snooze ? [.settle, .snooze] : [.settle]
        case .unsettle: return [.unsettle]
        case .unsnooze: return [.wake]
        }
    }

    /// Where a dragged thread lands when dropped above display row `index`: next to a pinned row it joins the
    /// pins, next to an active row the inbox. Nil elsewhere (the shelves take no drops here; the menu settles).
    static func dropTarget(_ rows: [(id: ThreadId, section: SidebarSection)?], moving: ThreadId, at index: Int) -> SidebarDropTarget? {
        func section(_ i: Int) -> SidebarSection? { rows.indices.contains(i) ? rows[i]?.section : nil }
        let above = section(index - 1), below = section(index)
        let target: SidebarSection
        if above == .pinned || below == .pinned { target = .pinned }
        else if above == .active || below == .active { target = .active }
        else { return nil }
        func ids(_ s: SidebarSection) -> [ThreadId] { rows.compactMap { $0?.section == s && $0?.id != moving ? $0?.id : nil } }
        var pinned = ids(.pinned), active = ids(.active)
        let position = rows[..<min(index, rows.count)].filter { $0?.section == target && $0?.id != moving }.count
        if target == .pinned { pinned.insert(moving, at: position) } else { active.insert(moving, at: position) }
        return SidebarDropTarget(section: target, pinnedOrder: pinned, activeOrder: active)
    }

    /// The status label's SF Symbol and color (thread-list-v2-items.tsx:67-117). Woke is CandyWrapper's web status.
    static func status(_ status: SidebarTopStatus) -> (symbol: String, color: NSColor) {
        switch status {
        case .approval: ("exclamationmark.shield", .systemOrange)
        case .input: ("questionmark.bubble", .systemIndigo)
        case .working: ("circle.dashed", .systemCyan)
        case .waiting: ("clock", .secondaryLabelColor)
        case .failed: ("exclamationmark.circle", .systemRed)
        case .limited: ("exclamationmark.circle", .systemOrange)
        case .done: ("checkmark.circle", .systemGreen)
        case .woke: ("alarm", .systemOrange)
        }
    }

    /// The machine kinds of `EnvironmentMachineIcon` as SF Symbols.
    static func machineSymbol(_ kind: String) -> String {
        switch kind {
        case "mac-mini": "macmini"
        case "mac-studio": "macstudio"
        case "cloud": "cloud"
        case "desktop": "desktopcomputer"
        case "laptop": "laptopcomputer"
        default: "server.rack"
        }
    }

    static func pullRequestColor(_ tone: PullRequestStateTone?) -> NSColor {
        switch tone {
        case .open?: .systemGreen
        case .closed?: .systemRed
        case .merged?: .systemPurple
        case .draft?, nil: .secondaryLabelColor
        }
    }
}
