import AppKit
import DesignSystem
import T3Protocol

/// `pullRequestComposerTrigger.ts` (4928 packages/shared): the `@login`, `#123` or GitLab `!123`
/// being typed at the caret. Offsets are UTF-16, like the JS string indices and NSTextView ranges.
public enum PullRequestCompletionLogic {
    public enum Kind: String, Sendable { case mention, reference }

    public struct Trigger: Equatable, Sendable {
        public var kind: Kind
        public var sigil: String
        public var query: String
        public var rangeStart: Int
        public var rangeEnd: Int
    }

    /// What the host completes (`PullRequestCompletionSupport`): absent fields complete nothing.
    public struct Support: Equatable, Sendable {
        public var mentions: Bool
        public var referenceSigils: [String]
        public init(mentions: Bool, referenceSigils: [String]) { self.mentions = mentions; self.referenceSigils = referenceSigils }
        /// `pullRequestCompletionScope` (PullRequestMarkdownTextarea.tsx:40): nil on hosts that complete nothing.
        public init?(_ c: PullRequestCapabilities) {
            let sigils = (c.referenceSigils ?? []).filter { $0 == "#" || $0 == "!" }
            guard c.mentions == true || !sigils.isEmpty else { return nil }
            self.init(mentions: c.mentions == true, referenceSigils: sigils)
        }
    }

    public enum Completion: Equatable, Sendable {
        case mention(PullRequestActor)
        case reference(PullRequestReferenceCandidate)
        public var token: String {
            switch self { case .mention(let a): "@\(a.login)"; case .reference(let c): c.reference }
        }
    }

    // ponytail: ICU's \s and \p classes stand in for the JS `u` regex; they agree on every login and number.
    private static let token = try! NSRegularExpression(pattern: #"^(?:@([\p{L}\p{N}_][\p{L}\p{M}\p{N}_.\-]*)?|([#!])([\p{L}\p{N}_\-]*))$"#)

    private static func isSpace(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    /// `detectPullRequestComposerTrigger` (line 35): only when the caret ends the token.
    public static func detect(_ text: String, cursor: Int, support: Support) -> Trigger? {
        let s = text as NSString
        let end = max(0, min(s.length, cursor))
        if end < s.length, !isSpace(s.character(at: end)) { return nil }
        var start = end
        while start > 0, !isSpace(s.character(at: start - 1)) { start -= 1 }
        let word = s.substring(with: NSRange(location: start, length: end - start))
        guard let m = token.firstMatch(in: word, range: NSRange(location: 0, length: (word as NSString).length)) else { return nil }
        func group(_ i: Int) -> String? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : (word as NSString).substring(with: r)
        }
        if let sigil = group(2) {
            return support.referenceSigils.contains(sigil)
                ? Trigger(kind: .reference, sigil: sigil, query: group(3) ?? "", rangeStart: start, rangeEnd: end) : nil
        }
        return support.mentions ? Trigger(kind: .mention, sigil: "@", query: group(1) ?? "", rangeStart: start, rangeEnd: end) : nil
    }

    /// `insertPullRequestCompletion` (line 58): the token and a space, or past the space already there.
    public static func insert(_ text: String, _ trigger: Trigger, token: String) -> (text: String, cursor: Int, replacement: String) {
        let s = text as NSString
        let range = NSRange(location: trigger.rangeStart, length: trigger.rangeEnd - trigger.rangeStart)
        let followedBySpace = trigger.rangeEnd < s.length && [0x20, 0x09].contains(s.character(at: trigger.rangeEnd))
        let inserted = followedBySpace ? token : token + " "
        let next = s.replacingCharacters(in: range, with: inserted)
        return (next, trigger.rangeStart + (inserted as NSString).length + (followedBySpace ? 1 : 0), inserted)
    }

    /// `pullRequestCompletionKey` (line 72).
    public static func key(_ trigger: Trigger?) -> String? {
        trigger.map { "\($0.sigil)\(String($0.query.prefix(100)))" }
    }

    /// `debouncedPullRequestCompletionSearch` (line 83): the host's unsearched list until a key for
    /// this sigil settles, so a burst of typing sends one query.
    public static func search(_ trigger: Trigger, debouncedKey: String?) -> String? {
        guard let k = debouncedKey, k.hasPrefix(trigger.sigil) else { return nil }
        let q = String(k.dropFirst(trigger.sigil.count))
        return q.isEmpty ? nil : q
    }

    /// `pullRequestCompletions` (line 135): the host's options narrowed to what is typed now.
    public static func completions(_ trigger: Trigger?, _ options: PullRequestFilterOptions?, limit: Int = 8) -> [Completion] {
        guard let trigger else { return [] }
        let needle = trigger.query.lowercased()
        switch trigger.kind {
        case .mention:
            return (options?.authors ?? []).filter {
                $0.login.lowercased().contains(needle) || ($0.name?.lowercased().contains(needle) ?? false)
            }.prefix(limit).map(Completion.mention)
        case .reference:
            return (options?.references ?? []).filter {
                $0.reference.hasPrefix(trigger.sigil) && (String($0.number).hasPrefix(needle) || $0.title.lowercased().contains(needle))
            }.prefix(limit).map(Completion.reference)
        }
    }

    /// `EMPTY_STATE` (PullRequestMarkdownTextarea.tsx:143).
    public static func emptyText(_ kind: Kind, pending: Bool, failed: Bool) -> String {
        switch (kind, pending, failed) {
        case (.mention, true, _): "Searching users..."
        case (.mention, false, true): "Couldn't search users on the host"
        case (.mention, false, false): "No matching users"
        case (.reference, true, _): "Searching..."
        case (.reference, false, true): "Couldn't search the host"
        case (.reference, false, false): "No matching issues or change requests"
        }
    }

    public static func listLabel(_ kind: Kind) -> String {
        kind == .mention ? "Mention a user" : "Reference an issue or change request"
    }
}

/// The repository a composer completes against and how to ask its host (`pullRequests.filterOptions`).
public struct PullRequestCompletionScope {
    public var projectId: String
    public var support: PullRequestCompletionLogic.Support
    public var search: @MainActor (PullRequestFilterOptionsInput) async throws -> PullRequestFilterOptions
    public init(projectId: String, support: PullRequestCompletionLogic.Support,
                search: @escaping @MainActor (PullRequestFilterOptionsInput) async throws -> PullRequestFilterOptions) {
        self.projectId = projectId; self.support = support; self.search = search
    }
}

/// A view above a pull request textarea that knows the repository (the detail panel). Textareas
/// find it by walking up, so the tabs and annotations need no plumbing.
@MainActor public protocol PullRequestCompletionScopeProviding: AnyObject {
    var completionScope: PullRequestCompletionScope? { get }
}

/// `PullRequestMarkdownTextarea` (4928 PullRequestMarkdownTextarea.tsx:162): completes `@login`,
/// `#123` and `!123` in a textarea, in a list under or over it that leaves focus in the field.
@MainActor public final class PullRequestCompletion {
    private weak var field: TextareaView?
    private let explicitScope: (@MainActor () -> PullRequestCompletionScope?)?
    private var dismissedAt: Int?
    private var highlight: (query: String, index: Int) = ("", 0)
    private var sentKey: String?
    private var debounce: Timer?
    /// Answers per request, kept while a newer search runs (`useQuery` keeps old data per key).
    private var cache: [String: PullRequestFilterOptions] = [:]
    private var inFlight: Set<String> = []
    private var failedKeys: Set<String> = []
    private var lastOptions: [String: PullRequestFilterOptions] = [:]
    private var popup: OpenPopup?
    private let list = PullRequestCompletionListView()
    private var trigger: PullRequestCompletionLogic.Trigger?
    private var candidates: [PullRequestCompletionLogic.Completion] = []
    private var scope: PullRequestCompletionScope?

    static let debounceInterval: TimeInterval = 0.2

    /// Hooks `field`; call it after the owner set its own `onChange` and `onStateChange`, which
    /// this chains. With no `scope`, the nearest `PullRequestCompletionScopeProviding` above the field answers.
    @discardableResult
    public static func attach(to field: TextareaView, scope: (@MainActor () -> PullRequestCompletionScope?)? = nil) -> PullRequestCompletion {
        let c = PullRequestCompletion(field: field, scope: scope)
        objc_setAssociatedObject(field, &associationKey, c, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return c
    }
    nonisolated(unsafe) private static var associationKey: UInt8 = 0

    private init(field: TextareaView, scope: (@MainActor () -> PullRequestCompletionScope?)?) {
        self.field = field
        self.explicitScope = scope
        let change = field.onChange
        field.onChange = { [weak self] text in
            change?(text)
            self?.dismissedAt = nil
            self?.sync()
        }
        let selection = field.onSelectionChange
        field.onSelectionChange = { [weak self] in selection?(); self?.sync() }
        let state = field.onStateChange
        field.onStateChange = { [weak self] s in state?(s); if !s.focused { self?.close() } else { self?.sync() } }
        list.onPick = { [weak self] i in self?.select(i) }
        list.onHover = { [weak self] i in
            guard let self, let t = self.trigger else { return }
            self.highlight = (t.query, i)
            self.render()
        }
        list.onKey = { [weak self] key in self?.handle(key) ?? false }
    }

    private func resolveScope() -> PullRequestCompletionScope? {
        if let explicitScope { return explicitScope() }
        var v = field?.superview
        while let view = v {
            if let p = view as? PullRequestCompletionScopeProviding { return p.completionScope }
            v = view.superview
        }
        return nil
    }

    private func requestKey(_ t: PullRequestCompletionLogic.Trigger, _ query: String?) -> String { "\(t.sigil)\u{1f}\(query ?? "")" }

    private var activeIndex: Int {
        guard let t = trigger, highlight.query == t.query else { return 0 }
        return min(highlight.index, max(0, candidates.count - 1))
    }

    /// Recomputes the trigger at the caret and the list under it.
    private func sync() {
        guard let field, field.state.focused, !field.isReadOnly, let caret = field.caretLocation, let scope = resolveScope() else { close(); return }
        self.scope = scope
        guard let t = PullRequestCompletionLogic.detect(field.text, cursor: caret, support: scope.support), t.rangeStart != dismissedAt else {
            close(); return
        }
        let key = PullRequestCompletionLogic.key(t)
        if trigger?.kind != t.kind || trigger?.sigil != t.sigil { highlight = (t.query, 0) }
        trigger = t
        if key != sentKey {
            debounce?.invalidate()
            debounce = Timer.scheduledTimer(withTimeInterval: Self.debounceInterval, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.sentKey = key
                    self?.debounce = nil
                    self?.fetch()
                    self?.render()
                }
            }
        }
        fetch()
        render()
    }

    private func fetch() {
        guard let t = trigger, let scope else { return }
        let query = PullRequestCompletionLogic.search(t, debouncedKey: sentKey)
        let k = requestKey(t, query)
        guard cache[k] == nil, !inFlight.contains(k), !failedKeys.contains(k) else { return }
        inFlight.insert(k)
        let input = PullRequestFilterOptionsInput(kind: t.kind == .mention ? "authors" : "references", projectId: scope.projectId,
                                                  query: query, sigil: t.kind == .reference ? t.sigil : nil)
        Task { @MainActor [weak self] in
            do {
                let options = try await scope.search(input)
                self?.cache[k] = options
                self?.lastOptions[t.sigil] = options
            } catch {
                self?.failedKeys.insert(k)
            }
            self?.inFlight.remove(k)
            self?.render()
        }
    }

    private func render() {
        guard let t = trigger, let field else { return }
        let query = PullRequestCompletionLogic.search(t, debouncedKey: sentKey)
        let k = requestKey(t, query)
        let options = cache[k] ?? lastOptions[t.sigil]
        candidates = PullRequestCompletionLogic.completions(t, options)
        let pending = inFlight.contains(k) || PullRequestCompletionLogic.key(t) != sentKey
        list.show(kind: t.kind, candidates: candidates, active: activeIndex,
                  empty: PullRequestCompletionLogic.emptyText(t.kind, pending: pending, failed: failedKeys.contains(k)))
        if let popup, field.popupHost?.popups.contains(where: { $0 === popup }) == true {
            field.popupHost?.reposition(popup)
            return
        }
        // `suggestionSide`: over the field when a full list (320) has no room under it and more above.
        var side = PopupPlacement.Side.bottom
        if let window = field.window, let screenH = window.contentView?.bounds.height {
            let r = field.convert(field.bounds, to: nil)
            let below = r.minY, above = screenH - r.maxY
            if below < 320, above > below { side = .top }
        }
        let surface = PopoverView(content: list, padding: .compact, width: t.kind == .reference ? .md : .sm)
        surface.onKey = { [weak self] key in self?.handle(key) ?? false }
        popup = field.popupHost?.open(surface, trigger: field, placement: PopupPlacement(side: side, align: .start, sideOffset: 4, fallbackAxisSide: .none),
                                      motion: .popover, pressesTrigger: false, returnsFocus: false, passive: true)
    }

    private func close() {
        debounce?.invalidate(); debounce = nil
        trigger = nil
        candidates = []
        if let popup { field?.popupHost?.close(popup, returnFocus: false) }
        popup = nil
    }

    private func select(_ index: Int) {
        guard let t = trigger, let field, candidates.indices.contains(index) else { return }
        let next = PullRequestCompletionLogic.insert(field.text, t, token: candidates[index].token)
        // Only the trigger's span changes, so undo restores exactly what was typed.
        field.replaceText(in: NSRange(location: t.rangeStart, length: t.rangeEnd - t.rangeStart), with: next.replacement, caret: next.cursor)
    }

    /// The textarea's keys while the list is open (`onKeyDown`, line 230).
    func handle(_ key: PopupKey) -> Bool {
        guard let t = trigger, let field, field.state.focused, !field.hasMarkedText else { return false }
        if key == .escape { dismissedAt = t.rangeStart; close(); return true }
        guard !candidates.isEmpty else { return false }
        switch key {
        case .down, .up:
            highlight = (t.query, (activeIndex + (key == .down ? 1 : -1) + candidates.count) % candidates.count)
            render()
            return true
        case .enter, .tab:
            let mods = NSApp?.currentEvent?.modifierFlags.intersection([.shift, .command, .control, .option]) ?? []
            guard mods.isEmpty else { return false }
            select(activeIndex)
            return true
        default:
            return false
        }
    }
}

/// The suggestion list (`role="listbox"`), rows `flex gap-2 rounded-md px-2 py-1.5 text-sm`.
final class PullRequestCompletionListView: DSView, PopupContent {
    private var rows: [PullRequestCompletionRowView] = []
    private let empty = LabelView("", font: DSFont.ui(12))
    var onPick: ((Int) -> Void)?
    var onHover: ((Int) -> Void)?
    var onKey: ((PopupKey) -> Bool)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        empty.lineHeight = 16
        addSubview(empty)
        setAccessibilityRole(.list)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func popupHandleKey(_ key: PopupKey) -> Bool { onKey?(key) ?? false }

    func show(kind: PullRequestCompletionLogic.Kind, candidates: [PullRequestCompletionLogic.Completion], active: Int, empty text: String) {
        if rows.map(\.completion) != candidates {
            rows.forEach { $0.removeFromSuperview() }
            rows = candidates.enumerated().map { i, c in
                let r = PullRequestCompletionRowView(completion: c)
                r.action = { [weak self] in self?.onPick?(i) }
                r.onHover = { [weak self] in self?.onHover?(i) }
                addSubview(r)
                return r
            }
        }
        for (i, r) in rows.enumerated() { r.isActive = i == active }
        setAccessibilityLabel(PullRequestCompletionLogic.listLabel(kind))
        empty.text = text
        empty.color = Themed.color(\.contrastMutedForeground)
        empty.isHidden = !rows.isEmpty
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: rows.isEmpty ? 16 : CGFloat(rows.count) * 32)
    }

    override func layout() {
        super.layout()
        // `-mx-1.5` pulls the rows to the popup's 6pt inset.
        empty.frame = NSRect(x: 4, y: 0, width: max(0, bounds.width - 8), height: 16)
        var y = bounds.height
        for r in rows {
            y -= 32
            r.frame = NSRect(x: -6, y: y, width: bounds.width + 12, height: 32)
        }
    }
}

final class PullRequestCompletionRowView: ControlView {
    let completion: PullRequestCompletionLogic.Completion
    private let fill = CALayer()
    private let avatar: PullRequestAvatarView?
    private let icon: IconView?
    private let primary = LabelView("", font: DSFont.ui(14, weight: .medium))
    private let secondary = LabelView("", font: DSFont.ui(14))
    var onHover: (() -> Void)?
    var isActive = false { didSet { if isActive != oldValue { applyColors() } } }

    init(completion: PullRequestCompletionLogic.Completion) {
        self.completion = completion
        switch completion {
        case .mention(let actor):
            avatar = PullRequestAvatarView(); icon = nil
            avatar?.actor = actor
            primary.text = actor.login
            secondary.text = actor.name.flatMap { $0.isEmpty || $0 == actor.login ? nil : $0 } ?? ""
        case .reference(let c):
            avatar = nil
            icon = IconView(name: Self.stateIcon(c), size: 16)
            icon?.setAccessibilityLabel(Self.stateLabel(c))
            primary.text = c.reference
            secondary.text = c.title
        }
        super.init(frame: .zero)
        scalesWhenPressed = false
        fill.cornerRadius = 6
        fill.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(fill)
        [primary, secondary].forEach { $0.lineHeight = 20; $0.truncates = true }
        avatar.map(addSubview); icon.map(addSubview)
        addSubview(primary); addSubview(secondary)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel([primary.text, secondary.text].filter { !$0.isEmpty }.joined(separator: ", "))
        applyColors()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Keeps focus, and the caret, in the textarea (`onMouseDown` preventDefault).
    override var acceptsFirstResponder: Bool { false }

    static func stateTone(_ c: PullRequestReferenceCandidate) -> PullRequestStateTone {
        c.kind == "change-request" ? PullRequestStateTone(state: c.state, isDraft: false) : (c.state == "open" ? .open : .merged)
    }
    static func stateIcon(_ c: PullRequestReferenceCandidate) -> IconName {
        c.kind == "change-request" ? PullRequestStyle.icon(stateTone(c)) : (c.state == "open" ? .circleDot : .circleCheck)
    }
    static func stateLabel(_ c: PullRequestReferenceCandidate) -> String {
        c.kind == "change-request" ? stateTone(c).label : (c.state == "open" ? "Open issue" : "Closed issue")
    }

    override func stateDidChange(from old: State) {
        super.stateDidChange(from: old)
        if state.hovered && !old.hovered { onHover?() }
    }

    override func updateLayer() { applyColors() }

    private func applyColors() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fill.backgroundColor = isActive ? Themed.color(\.accent).cgColor(in: self) : nil
        CATransaction.commit()
        primary.color = isActive ? Themed.color(\.contrastAccentForeground) : Themed.color(\.contrastForeground)
        secondary.color = Themed.color(\.contrastMutedForeground)
        if case .reference(let c) = completion { icon?.strokeColor = PullRequestStyle.color(Self.stateTone(c)) }
        setAccessibilitySelected(isActive)
    }

    override func layout() {
        super.layout()
        fill.frame = bounds
        var x: CGFloat = 8
        if let avatar { avatar.frame = NSRect(x: x, y: (bounds.height - 20) / 2, width: 20, height: 20); x += 20 + 8 }
        if let icon { icon.frame = NSRect(x: x, y: (bounds.height - 16) / 2, width: 16, height: 16); x += 16 + 8 }
        let right = bounds.width - 8
        let pw = min(ceil(primary.textWidth) + 1, max(0, right - x))
        primary.frame = NSRect(x: x, y: (bounds.height - 20) / 2, width: pw, height: 20)
        let sx = x + pw + 8
        secondary.isHidden = secondary.text.isEmpty
        secondary.frame = NSRect(x: sx, y: (bounds.height - 20) / 2, width: max(0, right - sx), height: 20)
    }
}
