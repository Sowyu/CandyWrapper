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

public final class SettingsOpenSourceLicensesView: SettingsPageBase {
    private let search = InputView(placeholder: "Search licenses…")
    private var entries: [SettingsLicenseManifest.Entry] = []
    private var expanded = Set<String>()
    private var loading: Task<Void, Never>?
    private var message = "Loading licenses…"

    public override init(context: SettingsPageContext) {
        super.init(context: context)
        search.onChange = { [weak self] _ in self?.rebuild() }
        rebuild()
    }
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            loading?.cancel(); loading = nil; entries.removeAll(); expanded.removeAll()
            items = []; message = "Loading licenses…"
            return
        }
        load()
    }
    private func load() {
        guard loading == nil, let env = context.scope.primaryId,
              let base = context.httpBaseURL?(env) else { message = "Connect an environment to view licenses."; rebuild(); return }
        loading = Task { [weak self] in
            do {
                let (data, response) = try await URLSession.shared.data(from: base.appendingPathComponent("third-party-licenses.json"))
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CocoaError(.fileReadUnknown) }
                let manifest = try SettingsLicenseManifest.parse(data)
                guard !Task.isCancelled else { return }
                self?.entries = manifest.entries
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
        let matches = entries.filter { $0.matches(search.text) }
        let filter = SettingsRowView(title: "Open source licenses", detail: "\(matches.count) of \(entries.count) notices", control: search)
        search.frame.size = NSSize(width: 240, height: 32)
        var rows: [any SettingsGroupRow] = [filter]
        if matches.isEmpty { rows.append(SettingsGroupNote(message)) }
        for entry in matches {
            let key = "\(entry.kind):\(entry.name):\(entry.version ?? "")"
            let toggle = ButtonView(nil, icon: expanded.contains(key) ? .chevronDown : .chevronRight, variant: .ghostMuted, size: .iconXs)
            toggle.setAccessibilityLabel("Show license for \(entry.name)")
            toggle.action = { [weak self] in
                guard let self else { return }
                if !self.expanded.insert(key).inserted { self.expanded.remove(key) }
                self.rebuild()
            }
            let row = SettingsRowView(title: entry.name + (entry.version.map { " \($0)" } ?? ""),
                                      detail: "\(entry.license) · \(entry.bundles.joined(separator: ", "))", control: toggle)
            if let url = entry.sourceUrl.flatMap(URL.init(string:)) {
                let source = ButtonView(nil, icon: .externalLink, variant: .ghostMuted, size: .iconMicro)
                source.setAccessibilityLabel("View project source for \(entry.name)")
                source.action = { [weak self] in self?.context.openURL?(url) }
                row.accessories = [source]
            }
            if expanded.contains(key) { row.footer = SettingsLicenseNoticeView(entry.noticeText) }
            rows.append(row)
        }
        items = [SettingsSectionView(title: "Notices for dependencies, assets, and optional tools used by T3 Code.", rows: rows)]
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
