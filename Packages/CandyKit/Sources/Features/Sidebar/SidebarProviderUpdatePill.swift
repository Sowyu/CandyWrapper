import AppKit
import DesignSystem
import T3Protocol

/// `getProviderUpdateSidebarPillView` (ProviderUpdateLaunchNotification.logic.ts:451-590): what the
/// sidebar's provider update pill says for the primary environment's providers.
public struct SidebarProviderUpdatePillModel: Equatable, Sendable {
    public enum Tone: String, Sendable { case loading, success, warning, error }
    public var key: String
    public var tone: Tone
    public var title: String
    public var description: String
    public var dismissible = false
    /// Success leaves on its own after `PROVIDER_UPDATE_SUCCESS_VISIBLE_MS`.
    public var dismissAfterMs: Int?

    /// `PROVIDER_DISPLAY_NAMES` (contracts model.ts:228-238).
    static let displayNames = ["antigravity": "Antigravity", "codex": "Codex", "claudeAgent": "Claude", "cursor": "Cursor", "grok": "Grok",
                               "muse": "Muse Code", "acpRegistry": "ACP Registry", "pi": "Pi", "opencode": "OpenCode"]
    static func name(_ driver: String) -> String { displayNames[driver] ?? driver }
    /// `PROVIDER_DISPLAY_NAMES[driver] ?? driver`.
    public static func displayName(_ driver: String) -> String { name(driver) }
    static func version(_ v: String) -> String { v.hasPrefix("v") ? v : "v\(v)" }

    /// `formatProviderList`: "A and B", "A, B, and C".
    static func list(_ providers: [ServerProvider]) -> String {
        let names = providers.map { name($0.driver) }
        if names.count <= 2 { return names.joined(separator: " and ") }
        return names.dropLast().joined(separator: ", ") + ", and " + names.last!
    }

    /// `dedupeProvidersByDriver`: one per driver, the default instance (its id is the driver) else the newest probe.
    static func dedupe(_ providers: [ServerProvider]) -> [ServerProvider] {
        var order: [String] = []
        var byDriver: [String: ServerProvider] = [:]
        for p in providers {
            guard let current = byDriver[p.driver] else { order.append(p.driver); byDriver[p.driver] = p; continue }
            if p.instanceId.rawValue == p.driver { byDriver[p.driver] = p; continue }
            if current.instanceId.rawValue == current.driver { continue }
            if (p.checkedAt ?? "") >= (current.checkedAt ?? "") { byDriver[p.driver] = p }
        }
        return order.compactMap { byDriver[$0] }
    }

    /// `latestTerminalProvidersByDriver` (logic.ts:486-503, T3 f15aa815f3): the most recently finished instance per driver.
    static func latestFinishedByDriver(_ providers: [ServerProvider]) -> [ServerProvider] {
        var order: [String] = []
        var byDriver: [String: ServerProvider] = [:]
        for p in providers {
            if let current = byDriver[p.driver] {
                if (p.updateState?.finishedAt ?? "") >= (current.updateState?.finishedAt ?? "") { byDriver[p.driver] = p }
            } else {
                order.append(p.driver)
                byDriver[p.driver] = p
            }
        }
        return order.compactMap { byDriver[$0] }
    }

    public static func resolve(_ providers: [ServerProvider], visibleAfter: String?, dismissed: Set<String>) -> SidebarProviderUpdatePillModel? {
        // Update state lives per instance, so pick the instances with an update before collapsing to one per driver
        // (logic.ts:505-535, T3 f15aa815f3). Deduping first hid an update on a non-default instance.
        let active = dedupe(providers.filter { $0.updateState?.status == "queued" || $0.updateState?.status == "running" })
        if let first = active.first {
            let key = "loading:" + active.map { "\($0.driver):\($0.updateState?.status ?? "idle")" }.sorted().joined(separator: "|")
            return .init(key: key, tone: .loading,
                         title: active.count == 1 ? "Updating \(name(first.driver))" : "Updating \(active.count) providers",
                         description: active.count == 1 ? "\(list(active)) update in progress." : "\(list(active)) updates are in progress.")
        }
        let recent = latestFinishedByDriver(providers.filter { p in
            guard let status = p.updateState?.status, ["failed", "unchanged", "succeeded"].contains(status) else { return false }
            guard let visibleAfter else { return true }
            return (p.updateState?.finishedAt).map { $0 >= visibleAfter } ?? false
        })
        func key(_ prefix: String, _ ps: [ServerProvider]) -> String {
            prefix + ":" + ps.map { "\($0.driver):\($0.updateState?.finishedAt ?? "pending"):\($0.updateState?.message ?? "")" }.sorted().joined(separator: "|")
        }
        func latest(_ ps: [ServerProvider]) -> String { ps.compactMap { $0.updateState?.finishedAt }.max() ?? "" }
        var candidates: [(SidebarProviderUpdatePillModel, String)] = []
        let failed = recent.filter { $0.updateState?.status == "failed" }
        if let first = failed.first {
            let title = failed.count == 1
                ? (first.latestVersion.map { "\(name(first.driver)) \(version($0)) update failed" } ?? "\(name(first.driver)) update failed")
                : "\(failed.count) provider updates failed"
            let description = failed.count == 1 && first.updateState?.message != nil ? first.updateState!.message!
                : "\(list(failed)) failed to update. Check provider settings for details."
            candidates.append((.init(key: key("failed", failed), tone: .error, title: title, description: description, dismissible: true), latest(failed)))
        }
        let unchanged = recent.filter { $0.updateState?.status == "unchanged" }
        if let first = unchanged.first {
            candidates.append((.init(key: key("unchanged", unchanged), tone: .warning,
                                     title: unchanged.count == 1 ? "\(name(first.driver)) still needs an update" : "\(unchanged.count) providers still need updates",
                                     description: "\(list(unchanged)) \(unchanged.count == 1 ? "still appears" : "still appear") outdated. Review provider settings for details.",
                                     dismissible: true), latest(unchanged)))
        }
        let succeeded = recent.filter { $0.updateState?.status == "succeeded" }
        if let first = succeeded.first {
            candidates.append((.init(key: key("succeeded", succeeded), tone: .success,
                                     title: succeeded.count == 1 ? (first.version.map { "\(name(first.driver)) updated: \(version($0))" } ?? "\(name(first.driver)) updated")
                                         : "\(succeeded.count) providers updated",
                                     description: succeeded.count == 1 ? "New sessions will use the updated provider." : "New sessions will use the updated providers.",
                                     dismissAfterMs: 3_000), latest(succeeded)))
        }
        return candidates.sorted { $0.1 > $1.1 }.map(\.0).first { !dismissed.contains($0.key) }
    }
}

/// `SidebarProviderUpdatePill` (sidebar/SidebarProviderUpdatePill.tsx): a `min-h-7 rounded-lg text-2xs
/// font-medium` pill in the sidebar footer. It opens Settings > Providers; failures and stale versions
/// can be dismissed until the status changes; a success shows a 3 s draining bar and leaves.
public final class SidebarProviderUpdatePillView: DSView {
    public var onOpenSettings: (@MainActor () -> Void)?
    /// The pill appeared or went away (the footer relays out).
    public var onVisibilityChange: (@MainActor () -> Void)?
    private(set) var shown: SidebarProviderUpdatePillModel?
    private var dismissed: Set<String> = []
    /// `visibleAfterIso`: only updates that finish after the first providers seen count.
    private var visibleAfter: String?
    private var dismissWork: DispatchWorkItem?
    private let main = PillMain()
    private let close = PillClose()
    private let progress = CALayer()

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        progress.anchorPoint = CGPoint(x: 0, y: 0.5)
        progress.actions = ["bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(progress)
        addSubview(main)
        addSubview(close)
        main.action = { [weak self] in self?.onOpenSettings?() }
        close.action = { [weak self] in
            guard let self, let key = self.shown?.key else { return }
            self.dismissed.insert(key)
            self.show(nil)
        }
        close.toolTip = "Dismiss until provider status changes"
        close.setAccessibilityLabel("Dismiss provider update notice")
        isHidden = true
    }

    /// The primary environment's providers changed.
    public func update(_ providers: [ServerProvider]) {
        if visibleAfter == nil { visibleAfter = providers.compactMap(\.checkedAt).max() }
        let next = SidebarProviderUpdatePillModel.resolve(providers, visibleAfter: visibleAfter, dismissed: dismissed)
        guard next != shown else { return }
        show(next)
    }

    func show(_ model: SidebarProviderUpdatePillModel?) {
        dismissWork?.cancel()
        dismissWork = nil
        let wasHidden = shown == nil
        shown = model
        isHidden = model == nil
        if let model {
            main.model = model
            close.isHidden = !model.dismissible
            main.toolTip = model.description
            main.setAccessibilityLabel(model.description)
            restyle()
            if wasHidden, !Motion.reduced { enterAnimation() }
            if let ms = model.dismissAfterMs {
                startDrain(ms)
                let key = model.key
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.shown?.key == key else { return }
                    self.dismissed.insert(key)
                    self.show(nil)
                }
                dismissWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms), execute: work)
            } else {
                progress.removeAllAnimations()
                progress.isHidden = true
            }
        }
        needsLayout = true
        onVisibilityChange?()
    }

    /// `translate-y-1.5 opacity-0` to rest over 180ms.
    private func enterAnimation() {
        guard let layer else { return }
        let move = CABasicAnimation(keyPath: "transform.translation.y")
        move.fromValue = 6; move.toValue = 0; move.isAdditive = true
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0; fade.toValue = 1
        let group = CAAnimationGroup()
        group.animations = [move, fade]
        group.duration = 0.18
        group.timingFunction = Motion.easeInOut
        layer.add(group, forKey: "enter")
    }

    /// The draining bar: `scale-x` from 1 to 0, linear, for the visible time.
    private func startDrain(_ ms: Int) {
        progress.isHidden = false
        progress.removeAllAnimations()
        guard !Motion.reduced else { return }
        let a = CABasicAnimation(keyPath: "transform.scale.x")
        a.fromValue = 1; a.toValue = 0
        a.duration = Double(ms) / 1000
        a.fillMode = .forwards
        a.isRemovedOnCompletion = false
        progress.add(a, forKey: "drain")
    }

    public var preferredHeight: CGFloat { shown == nil ? 0 : 28 }

    public override func layout() {
        super.layout()
        progress.bounds = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
        progress.position = CGPoint(x: 0, y: bounds.midY)
        let closeWidth: CGFloat = close.isHidden ? 0 : 20 + 4
        main.frame = NSRect(x: 0, y: 0, width: bounds.width - closeWidth, height: bounds.height)
        close.frame = NSRect(x: bounds.width - 4 - 20, y: (bounds.height - 20) / 2, width: 20, height: 20)
    }

    public override func updateLayer() { restyle() }

    private func restyle() {
        guard let tone = shown?.tone, let layer else { return }
        let hot = main.state.hovered
        let fill: NSColor, ink: NSColor
        switch tone {
        case .loading, .success:
            fill = hot ? SB.c(\.sidebarRowHover) : SB.c(\.sidebarControlSurface)
            ink = SB.c(\.sidebarForeground)
        case .warning:
            fill = SB.c(\.warning, hot ? 0.18 : 0.12); ink = SB.c(\.warning)
        case .error:
            fill = SB.c(\.destructive, hot ? 0.18 : 0.12); ink = SB.c(\.destructive)
        }
        layer.backgroundColor = fill.cgColor(in: self)
        let bar: NSColor = switch tone {
        case .warning: SB.c(\.warning, 0.14)
        case .error: SB.c(\.destructive, 0.14)
        default: SB.c(\.foreground, 0.08)
        }
        progress.backgroundColor = bar.cgColor(in: self)
        main.ink = ink
        close.ink = ink
    }

    /// The pill's main button (`px-2 py-1.5 gap-2`): the 14px status glyph and the title.
    final class PillMain: ControlView {
        private var glyph: NSView?
        private let title = TextBlockView()
        var ink: NSColor = .labelColor { didSet { title.color = ink; (glyph as? IconView)?.strokeColor = ink } }
        var model: SidebarProviderUpdatePillModel? {
            didSet {
                guard model != oldValue, let model else { return }
                glyph?.removeFromSuperview()
                let g: NSView = switch model.tone {
                case .loading: SpinnerView(size: .sm)
                case .success: IconView(name: .circleCheck, size: 14)
                case .error: IconView(name: .triangleAlert, size: 14)
                case .warning: IconView(name: .download, size: 14)
                }
                addSubview(g)
                glyph = g
                title.text = model.title
                (g as? IconView)?.strokeColor = ink
                needsLayout = true
            }
        }
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            scalesWhenPressed = false
            title.font = SB.font(11, .medium)
            title.lineHeight = 16
            addSubview(title)
        }
        override func stateDidChange(from old: State) {
            super.stateDidChange(from: old)
            if state.hovered != old.hovered { (superview as? SidebarProviderUpdatePillView)?.needsDisplay = true; superview?.updateLayer() }
        }
        override func layout() {
            super.layout()
            glyph?.frame = NSRect(x: 8, y: (bounds.height - 14) / 2, width: 14, height: 14)
            let x: CGFloat = 8 + 14 + 8
            title.frame = NSRect(x: x, y: (bounds.height - 16) / 2, width: max(0, bounds.width - x - 8), height: 16)
        }
    }

    /// The dismiss button: `size-5 rounded-md opacity-70`, full on hover.
    final class PillClose: ControlView {
        private let icon = IconView(name: .x, size: 14)
        var ink: NSColor = .labelColor { didSet { icon.strokeColor = ink } }
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            scalesWhenPressed = false
            addSubview(icon)
            alphaValue = 0.7
        }
        override func stateDidChange(from old: State) { super.stateDidChange(from: old); alphaValue = state.hovered ? 1 : 0.7 }
        override func layout() { super.layout(); icon.frame = NSRect(x: 3, y: 3, width: 14, height: 14) }
    }
}
