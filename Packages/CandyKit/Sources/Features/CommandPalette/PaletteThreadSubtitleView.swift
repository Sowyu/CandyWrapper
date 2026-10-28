import AppKit
import DesignSystem

/// Nightly 3824 ThreadCommandSubtitle.tsx:64-100. Inline icons give the caption its 18pt line box.
public final class PaletteThreadSubtitleView: DSView {
    private let project: ProjectMonogramView
    private let text: LabelView
    private let separator = LabelView("·", font: DSFont.ui(12), color: Themed.color(\.mutedForeground, 0.7))
    private let provider: NSView?
    public init(project source: ProjectIconSource, text: String, driver: String?) {
        project = ProjectMonogramView(source)
        self.text = LabelView(text, font: DSFont.ui(12), color: Themed.color(\.mutedForeground, 0.7))
        provider = driver.map { ProviderIcon.make(driver: $0, displayName: $0, size: 12) }
        super.init(frame: .zero)
        self.text.lineHeight = 16
        separator.lineHeight = 16
        addSubview(project); addSubview(self.text)
        if let provider { provider.alphaValue = 0.7; addSubview(separator); addSubview(provider) }
    }
    public override func layout() {
        super.layout()
        project.frame = NSRect(x: 0, y: 1, width: 12, height: 12)
        project.bounds = NSRect(x: 0, y: 0, width: 16, height: 16)
        let width = min(ceil(text.textWidth), max(0, bounds.width - 16 - (provider == nil ? 0 : 20)))
        text.frame = NSRect(x: 16, y: 0, width: width, height: 16)
        separator.frame = NSRect(x: text.frame.maxX + 4, y: 0, width: ceil(separator.textWidth), height: 16)
        provider?.frame = NSRect(x: separator.frame.maxX + 4, y: 1, width: 12, height: 12)
    }
}
