import AppKit
import DesignSystem
import T3Protocol

/// SnapShotAttachmentDetails.tsx:136-171. Shared by draft and sent-image tiles.
public final class SnapShotAttachmentDetailsView: DSView {
    public let source: JSONValue
    private let gradient = CAGradientLayer()
    private let icon = NSImageView()
    private let monogram = LabelView("", font: DSFont.ui(10, weight: .medium), color: .white)
    private let app = LabelView("", font: DSFont.ui(11, weight: .medium), color: .white)
    private let title = LabelView("", font: DSFont.ui(10), color: .white.withAlphaComponent(0.7))
    private let contents: ButtonView
    public init(source: JSONValue) {
        self.source = source
        contents = ButtonView(nil, icon: SnapShotSource.details(source) == nil ? .image : .text, variant: .overlay, size: .iconMicro)
        super.init(frame: .zero)
        contents.iconSize = 12
        gradient.colors = [NSColor.clear.cgColor, NSColor.black.withAlphaComponent(0.55).cgColor, NSColor.black.withAlphaComponent(0.85).cgColor]
        gradient.locations = [0, 0.5, 1]
        layer?.addSublayer(gradient)
        app.text = source["appName"]?.stringValue ?? "App"
        title.text = source["windowTitle"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "Captured window"
        app.lineHeight = 14; title.lineHeight = 14
        monogram.text = String(app.text.prefix(1)).uppercased()
        monogram.alignment = .center
        monogram.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.2).cgColor
        monogram.layer?.cornerRadius = 6
        if let raw = source["appIconDataUrl"]?.stringValue, let comma = raw.firstIndex(of: ","),
           let data = Data(base64Encoded: String(raw[raw.index(after: comma)...])) { icon.image = NSImage(data: data) }
        monogram.isHidden = icon.image != nil
        [icon, monogram, app, title, contents].forEach(addSubview)
        let hasData = source["accessibility"] != nil || SnapShotSource.details(source) != nil
        contents.toolTip = hasData ? "Accessibility data" : "No accessibility data"
        contents.setAccessibilityLabel(hasData ? "View accessibility data" : "No accessibility data")
        contents.action = { [weak self] in self?.showContents() }
    }
    private func showContents() {
        let details = SnapShotSource.details(source)
        let body = SnapShotAccessibilityDetailsBody(text: details
            ?? "The app or capture backend did not provide verified accessibility data.", hasData: details != nil, isJSON: source["accessibility"]?["format"]?.stringValue == "element-tree")
        _ = PopoverView(content: body, width: .md).show(from: contents, placement: PopupPlacement(side: .top, align: .center, sideOffset: 4))
    }
    public override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true); gradient.frame = CGRect(x: 0, y: bounds.height - 66, width: bounds.width, height: 66); CATransaction.commit()
        let y = bounds.height - 39
        icon.frame = NSRect(x: 10, y: y, width: 28, height: 28); monogram.frame = icon.frame
        let width = max(0, bounds.width - 54)
        app.frame = NSRect(x: 44, y: y, width: max(0, width - 22), height: 14)
        contents.frame = NSRect(x: min(bounds.width - 28, 44 + app.textWidth + 6), y: y - 3, width: 20, height: 20)
        title.frame = NSRect(x: 44, y: y + 17, width: width, height: 14)
    }
    public override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === contents || hit?.isDescendant(of: contents) == true ? hit : nil
    }
}

private final class SnapShotAccessibilityDetailsBody: DSView {
    private let title = popoverTitle("Accessibility data")
    private let scroll = NSScrollView()
    private let bodyHeight: CGFloat
    init(text: String, hasData: Bool, isJSON: Bool) {
        let font = hasData ? DSFont.mono(11) : DSFont.ui(12)
        bodyHeight = min(256, ceil((text as NSString).boundingRect(with: CGSize(width: 266, height: 10_000), options: .usesLineFragmentOrigin, attributes: [.font: font]).height) + 20)
        super.init(frame: .zero)
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 286, height: 256))
        view.string = text; view.font = font; view.isEditable = false
        view.drawsBackground = false; view.textColor = Themed.color(\.foreground)
        if isJSON {
            for token in CodeHighlighter.tokens(text, language: "json") {
                view.textStorage?.addAttribute(.foregroundColor, value: token.kind.color, range: token.range)
            }
        }
        view.textContainerInset = NSSize(width: 10, height: 10)
        view.isVerticallyResizable = true
        view.textContainer?.widthTracksTextView = true
        scroll.documentView = view; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        addSubview(title); addSubview(scroll)
    }
    override var intrinsicContentSize: NSSize { NSSize(width: 286, height: bodyHeight + 26) }
    override func layout() {
        super.layout()
        title.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 18)
        scroll.frame = NSRect(x: 0, y: 26, width: bounds.width, height: bodyHeight)
    }
}
