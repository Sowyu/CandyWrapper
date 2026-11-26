import AppKit
import DesignSystem
import T3Protocol

/// shared/thirdPartyLicenses.ts:1-112, including AND search across name, version, license and bundles.
public struct SettingsLicenseManifest: Decodable, Sendable {
    public struct Entry: Decodable, Sendable {
        public var bundles: [String]
        public var kind: String
        public var license: String
        public var name: String
        public var noticeText: String
        public var sourceUrl: String?
        public var version: String?
        public func matches(_ query: String) -> Bool {
            let haystack = ([name, version ?? "", license] + bundles).joined(separator: " ").lowercased()
            return query.lowercased().split(whereSeparator: \.isWhitespace).allSatisfy { haystack.contains($0) }
        }
    }
    public var schemaVersion: Int
    public var entries: [Entry]
    public static func parse(_ data: Data) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: data)
        var seen = Set<String>()
        guard value.schemaVersion == 1, value.entries.allSatisfy({ entry in
            let key = "\(entry.kind)\u{0}\(entry.name)\u{0}\(entry.version ?? "")"
            let validURL = entry.sourceUrl.map { ["http", "https"].contains(URL(string: $0)?.scheme ?? "") } ?? true
            return !entry.bundles.isEmpty && ["custom", "package"].contains(entry.kind) && validURL && seen.insert(key).inserted
        }) else { throw CocoaError(.fileReadCorruptFile) }
        return value
    }
}

/// `LicenseHeaderAction` (OpenSourceLicenses.tsx:157-231): the notice count and a search button, which opens the
/// search field. Esc clears and closes the search without closing Settings (#41647), and a blur with no text closes it.
final class LicenseHeaderActionView: DSView {
    let count = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    let open = ButtonView(nil, icon: .search, variant: .ghostMuted, size: .iconMicro)
    // ponytail: the default h-8 group with a 16px glass; T3's is `size="sm"` with a size-3 glass, add an sm group if it shows
    let field = InputGroupView(placeholder: "Search licenses", leading: .icon(.search))
    var query: String { field.input.text }
    var onQueryChange: (() -> Void)?
    private(set) var isSearchOpen = false
    private var wasFocused = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        open.iconSize = 12
        open.setAccessibilityLabel("Search open-source licenses")
        TooltipController.attach(to: open, text: "Search licenses", placement: PopupPlacement(side: .top))
        open.action = { [weak self] in self?.setSearchOpen(true) }
        field.input.setAccessibilityLabel("Search open-source licenses")
        field.input.onChange = { [weak self] _ in self?.onQueryChange?() }
        field.input.takesEscape = { [weak self] in
            guard let self else { return false }
            self.field.input.text = "" // fires onChange, which refilters
            self.setSearchOpen(false)
            return true
        }
        let restyle = field.input.onStateChange
        field.input.onStateChange = { [weak self] state in
            restyle?(state)
            guard let self else { return }
            if self.wasFocused, !state.focused, self.query.isEmpty { self.setSearchOpen(false) }
            self.wasFocused = state.focused
        }
        count.lineHeight = 16
        [count, open, field].forEach(addSubview)
        setSearchOpen(false)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// `LicenseCount`: "{count} notices", or "{filtered} of {total}" while a search narrows the list.
    func setCounts(filtered: Int, total: Int) {
        count.text = filtered == total ? "\(total) notices" : "\(filtered) of \(total)"
        invalidateIntrinsicContentSize()
        needsLayout = true
        superview?.needsLayout = true
    }

    func setSearchOpen(_ on: Bool) {
        isSearchOpen = on
        open.isHidden = on
        field.isHidden = !on
        if on { DispatchQueue.main.async { [weak self] in guard let self else { return }; self.window?.makeFirstResponder(self.field.input) } }
        else if field.input.isFirstResponderInside { window?.makeFirstResponder(nil) }
        invalidateIntrinsicContentSize()
        needsLayout = true
        // The section places its header action from this view's intrinsic width.
        superview?.needsLayout = true
    }

    /// Closed: `flex items-center gap-1.5`, the count then the button. Open: `gap-2`, the count then the `w-44` field.
    override var intrinsicContentSize: NSSize {
        let c = ceil(count.intrinsicContentSize.width)
        return NSSize(width: isSearchOpen ? c + 8 + 176 : c + 6 + 20, height: isSearchOpen ? 32 : 20)
    }

    override func layout() {
        super.layout()
        let c = ceil(count.intrinsicContentSize.width)
        count.frame = NSRect(x: 0, y: (bounds.height - 16) / 2, width: c, height: 16)
        open.frame = NSRect(x: c + 6, y: (bounds.height - 20) / 2, width: 20, height: 20)
        field.frame = NSRect(x: c + 8, y: (bounds.height - 32) / 2, width: 176, height: 32)
    }
}

public final class SettingsOpenSourceLicensesView: SettingsPageBase {
    private let header = LicenseHeaderActionView()
    private let section = SettingsSectionView(title: "Third-party notices", rows: [])
    private var entries: [SettingsLicenseManifest.Entry] = []
    private var expanded = Set<String>()
    private var loading: Task<Void, Never>?
    private var message = "Loading licenses…"

    public override init(context: SettingsPageContext) {
        super.init(context: context)
        header.onQueryChange = { [weak self] in self?.rebuild() }
        rebuild()
    }
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            loading?.cancel(); loading = nil; entries.removeAll(); expanded.removeAll()
            items = []; message = "Loading licenses…"
            header.field.input.text = ""; header.setSearchOpen(false)
            return
        }
        load()
    }
    public static func nativeEntries() -> [SettingsLicenseManifest.Entry] {
        guard let url = Bundle.module.url(forResource: "native-licenses", withExtension: "json"),
              let data = try? Data(contentsOf: url), let manifest = try? SettingsLicenseManifest.parse(data) else { return [] }
        return manifest.entries
    }
    private func load() {
        entries = Self.nativeEntries()
        rebuild()
        guard loading == nil, let env = context.scope.primaryId,
              let base = context.httpBaseURL?(env) else { message = "Connect an environment to view licenses."; rebuild(); return }
        loading = Task { [weak self] in
            do {
                let (data, response) = try await URLSession.shared.data(from: base.appendingPathComponent("third-party-licenses.json"))
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CocoaError(.fileReadUnknown) }
                let manifest = try SettingsLicenseManifest.parse(data)
                guard !Task.isCancelled else { return }
                self?.entries = Self.nativeEntries() + manifest.entries
                self?.message = "No matching licenses."
            } catch {
                guard !Task.isCancelled else { return }
                self?.message = "Could not load open-source licenses. \(error.localizedDescription)"
            }
            self?.loading = nil
            self?.rebuild()
        }
    }
    private func rebuild() {
        let matches = entries.filter { $0.matches(header.query) }
        header.setCounts(filtered: matches.count, total: entries.count)
        var rows: [any SettingsGroupRow] = []
        if matches.isEmpty { rows.append(SettingsGroupNote(entries.isEmpty ? message : "No licenses match that search.")) }
        for entry in matches {
            let key = "\(entry.kind):\(entry.name):\(entry.version ?? "")"
            let toggle = ButtonView(nil, icon: expanded.contains(key) ? .chevronDown : .chevronRight, variant: .ghostMuted, size: .iconXs)
            toggle.setAccessibilityLabel("Show license for \(entry.name)")
            let row = SettingsRowView(title: entry.name + (entry.version.map { " \($0)" } ?? ""),
                                      detail: "\(entry.license) · \(entry.bundles.joined(separator: ", "))", control: toggle)
            // `CollapsiblePanel` (OpenSourceLicenses.tsx:76): the notice slides open over 200 ms. It renders only
            // while open, so closing leaves an empty gap that closes, as in T3.
            toggle.action = { [weak self, weak row, weak toggle] in
                guard let self, let row, let toggle else { return }
                CollapseMotion.run(in: row) {
                    let open = self.expanded.insert(key).inserted
                    if !open { self.expanded.remove(key) }
                    toggle.icon = open ? .chevronDown : .chevronRight
                    row.footer = open ? SettingsLicenseNoticeView(entry.noticeText) : nil
                    self.onHeightChange?()
                }
            }
            if let url = entry.sourceUrl.flatMap(URL.init(string:)) {
                let source = ButtonView(nil, icon: .externalLink, variant: .ghostMuted, size: .iconMicro)
                source.setAccessibilityLabel("View project source for \(entry.name)")
                source.action = { [weak self] in self?.context.openURL?(url) }
                row.accessories = [source]
            }
            if expanded.contains(key) { row.footer = SettingsLicenseNoticeView(entry.noticeText) }
            rows.append(row)
        }
        // One section for the page's life, so rebuilding the rows never moves the focused search field.
        section.group.rows = rows
        if (section.headerAction == nil) != entries.isEmpty { section.headerAction = entries.isEmpty ? nil : header }
        if items.isEmpty { items = [section] }
        onHeightChange?()
    }
}

final class SettingsLicenseNoticeView: DSView, SettingsGroupRow {
    private let text: TextBlockView
    init(_ notice: String) {
        text = TextBlockView(notice, font: DSFont.mono(12), lineHeight: 20, color: Themed.color(\.foreground, 0.8))
        super.init(frame: .zero); addSubview(text)
    }
    func height(forWidth width: CGFloat) -> CGFloat { text.height(forWidth: min(width, 760)) + 16 }
    override func layout() { super.layout(); text.frame = NSRect(x: 0, y: 0, width: min(bounds.width, 760), height: bounds.height - 16) }
}
