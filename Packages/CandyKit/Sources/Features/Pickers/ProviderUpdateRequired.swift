import Foundation
import T3Protocol

/// The model picker's update-required notice (client-runtime providerUpdateRequiredModels.ts at 5258, with #39966's
/// channel rule): a provider whose CLI is too old for some models says which version they need, and when its own
/// install channel cannot reach that version it says so instead of offering the update.
public enum ProviderUpdateRequired {
    static let homebrewStableCaskUpdate = "brew upgrade --cask claude-code"
    static let homebrewLatestCaskSwitch = "brew uninstall --cask claude-code && brew install --cask claude-code@latest"

    static func withV(_ v: String) -> String { v.hasPrefix("v") ? v : "v\(v)" }

    static func isSemver(_ v: String) -> Bool {
        (v.hasPrefix("v") ? String(v.dropFirst()) : v).range(of: #"^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$"#, options: .regularExpression) != nil
    }

    static func matching(_ p: ServerProvider, query: String) -> [ServerProvider.UpdateRequiredModel] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return (p.updateRequiredModels ?? []).filter { q.isEmpty || $0.name.lowercased().contains(q) || $0.slug.lowercased().contains(q) }
    }

    static func highestMinVersion(_ models: [ServerProvider.UpdateRequiredModel]) -> String {
        models.map(\.minVersion).reduce(models[0].minVersion) { UpdateTrackSwitchLogic.compareSemver($1, $0) > 0 ? $1 : $0 }
    }

    /// `channelLatestVersionBelow`: the newest version the install's channel offers, when it is below `minVersion`.
    static func channelLatestBelow(_ p: ServerProvider, _ minVersion: String) -> String? {
        guard let latest = p.versionAdvisory?["latestVersion"]?.stringValue, isSemver(latest), isSemver(minVersion),
              UpdateTrackSwitchLogic.compareSemver(latest, minVersion) < 0 else { return nil }
        return latest
    }

    /// `providerUpdateChannelLags`: the provider's own update cannot reach what its models need, so no Settings link.
    public static func channelLags(_ p: ServerProvider, query: String = "") -> Bool {
        let models = matching(p, query: query)
        return !models.isEmpty && channelLatestBelow(p, highestMinVersion(models)) != nil
    }

    /// `formatProviderUpdateRequiredNotice`.
    public static func notice(_ p: ServerProvider, query: String = "") -> String? {
        let models = matching(p, query: query)
        guard !models.isEmpty else { return nil }
        let minVersion = highestMinVersion(models)
        let providerName = p.driver == "claudeAgent" ? "Claude Code" : SidebarProviderUpdatePillModel.displayName(p.driver)
        let version = withV(minVersion)
        let formatter = ListFormatter()
        formatter.locale = Locale(identifier: "en_US")
        let names = formatter.string(from: models.map(\.name)) ?? models.map(\.name).joined(separator: ", ")
        let codex = p.driver == "codex"
        if let latest = channelLatestBelow(p, minVersion) {
            if p.driver == "claudeAgent", p.versionAdvisory?["updateCommand"]?.stringValue == homebrewStableCaskUpdate {
                return "Using \(names) requires \(providerName) \(version) or newer, but the claude-code Homebrew cask only has \(withV(latest)). Switch to the claude-code@latest cask: \(homebrewLatestCaskSwitch)"
            }
            return codex
                ? "Using \(names) requires the Codex CLI \(version) or newer, but the newest this install can update to is \(withV(latest)). Install the Codex CLI another way or wait for a newer release."
                : "Using \(names) requires \(providerName) \(version) or newer, but the newest this install can update to is \(withV(latest)). Install \(providerName) another way or wait for a newer release."
        }
        return codex ? "Update the Codex CLI to \(version) or newer to use \(names)." : "Update \(providerName) to \(version) or newer to use \(names)."
    }
}

import AppKit
import DesignSystem
import T3Store

/// One notice under the picker's list (ModelPickerContent.tsx:252-271): `shrink-0 border-t border-border/70 px-3 py-2
/// text-xs leading-snug text-muted-foreground`, then " " and the "Provider settings" `InlineButton` when the update can run
/// from Settings. The button flows after the text's last word, or starts the next line when it does not fit there.
final class ProviderUpdateNoticeView: DSView {
    let text: TextBlockView
    let link: ButtonView?
    private let border = CALayer()

    init(_ notice: String, onSettings: (@MainActor @Sendable () -> Void)?) {
        text = TextBlockView(notice, font: DSFont.ui(12), lineHeight: 16.5, color: Themed.color(\.contrastMutedForeground))
        link = onSettings.map { open in
            let b = ButtonView("Provider settings", variant: .link, size: .xs)
            b.action = open
            return b
        }
        super.init(frame: .zero)
        border.actions = ["backgroundColor": NSNull(), "frame": NSNull()]
        layer?.addSublayer(border)
        addSubview(text)
        link.map(addSubview)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func height(forWidth w: CGFloat) -> CGFloat {
        1 + 8 + text.layout(forWidth: max(1, w - 24)).height + (linkOrigin(textWidth: max(1, w - 24)).map { $0.y > 0 ? 16.5 : 0 } ?? 0) + 8
    }

    /// Where the link starts, relative to the text's top left: after the last line's end and a space when it fits,
    /// else at the start of a new line (`y` > 0 means one line further down than the text's last line).
    func linkOrigin(textWidth w: CGFloat) -> CGPoint? {
        guard let link else { return nil }
        let length = (text.text as NSString).length
        guard length > 0, let last = text.runRects(NSRange(location: length - 1, length: 1), width: w).last else { return CGPoint(x: 0, y: 16.5) }
        let x = last.rect.maxX + TextLine(NSAttributedString(string: " ", attributes: [.font: text.font])).width
        return x + link.fittingSize.width <= w ? CGPoint(x: x, y: 0) : CGPoint(x: 0, y: 16.5)
    }

    override func layout() {
        super.layout()
        border.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 1)
        // Redesign draws the picker's other hairlines in the text color at 0.08, so the notice's matches them.
        let dither = ThemeRuntime.isDither(dark: effectiveAppearance.isDark)
        border.backgroundColor = (dither ? Themed.color(\.contrastForeground, 0.08) : Themed.color(\.border, 0.7)).cgColor(in: self)
        let h = text.layout(forWidth: max(1, bounds.width - 24)).height
        text.frame = NSRect(x: 12, y: 9, width: bounds.width - 24, height: h)
        if let link, let origin = linkOrigin(textWidth: bounds.width - 24) {
            // `y` is 0 on the text's last line and 16.5 below it.
            link.frame = NSRect(x: 12 + origin.x, y: 9 + h - 16.5 + origin.y, width: link.fittingSize.width, height: 16.5)
        }
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsLayout = true }
}
