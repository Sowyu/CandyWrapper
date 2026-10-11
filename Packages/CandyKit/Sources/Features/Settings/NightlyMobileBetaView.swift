import AppKit
import DesignSystem

/// NightlyMobileBeta.tsx:25-28, 99-170. QR images exist only while their popup is open.
// ponytail: settings QR controls only; add the one-time notice and brand glyphs with full promo parity
public final class NightlyMobileBetaView: DSView {
    public static let iOS = "https://testflight.apple.com/join/XgaxaRtd"
    public static let androidGroup = "https://groups.google.com/g/t3-code-v2-beta"
    public static let androidTesting = "https://play.google.com/apps/testing/com.t3tools.t3code"
    private let iphone = ButtonView("iPhone", icon: .smartphone, variant: .outline, size: .sm)
    private let android = ButtonView("Android", icon: .smartphone, variant: .outline, size: .sm)
    public override init(frame: NSRect = .zero) {
        super.init(frame: frame)
        addSubview(iphone); addSubview(android)
        iphone.action = { [weak self] in self?.show(android: false) }
        android.action = { [weak self] in self?.show(android: true) }
    }
    public override var intrinsicContentSize: NSSize { NSSize(width: iphone.intrinsicContentSize.width + android.intrinsicContentSize.width + 8, height: 32) }
    public override func layout() {
        super.layout()
        iphone.frame = NSRect(x: 0, y: 0, width: iphone.intrinsicContentSize.width, height: 32)
        android.frame = NSRect(x: iphone.frame.maxX + 8, y: 0, width: android.intrinsicContentSize.width, height: 32)
    }
    private func show(android isAndroid: Bool) {
        let content = NightlyMobileBetaPopup(android: isAndroid)
        PopoverView(content: content).show(from: isAndroid ? android : iphone)
    }
}

public final class NightlyMobileBetaPopup: DSView {
    private let heading: LabelView
    private let detail: TextBlockView
    private let urls: [String]
    private var codes: [QRCodeView] = []
    private var labels: [LabelView] = []
    private var copies: [ButtonView] = []
    public init(android: Bool) {
        urls = android ? [NightlyMobileBetaView.androidGroup, NightlyMobileBetaView.androidTesting] : [NightlyMobileBetaView.iOS]
        heading = LabelView(android ? "Google Play beta" : "TestFlight beta", font: DSFont.ui(14, weight: .medium))
        detail = TextBlockView(android ? "Use the same Google account for both steps. Step 2 can take up to an hour to work after you join the group." : "Scan with your iPhone camera.", font: DSFont.ui(12))
        super.init(frame: .zero)
        detail.color = Themed.color(\.mutedForeground); detail.lineHeight = 16
        addSubview(heading); addSubview(detail)
        for (index, url) in urls.enumerated() {
            let qr = QRCodeView(value: url, size: 128, level: .medium, marginSize: 1, title: android ? index == 0 ? "Android beta group link" : "Google Play beta link" : "TestFlight beta link")
            let label = LabelView(android ? index == 0 ? "1. Join the group" : "2. Become a tester" : "", font: DSFont.ui(12, weight: .medium))
            label.alignment = .center
            let copy = ButtonView("Copy link", variant: .outline, size: .xs)
            copy.action = { [weak copy] in NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url, forType: .string); copy?.title = "Copied" }
            [qr, label, copy].forEach(addSubview)
            codes.append(qr); labels.append(label); copies.append(copy)
        }
    }
    public override var intrinsicContentSize: NSSize { NSSize(width: urls.count == 2 ? 296 : 208, height: urls.count == 2 ? 258 : 214) }
    public override func layout() {
        super.layout()
        heading.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 20)
        detail.frame = NSRect(x: 0, y: 24, width: bounds.width, height: urls.count == 2 ? 48 : 16)
        let top: CGFloat = urls.count == 2 ? 100 : 52
        for i in codes.indices {
            let x: CGFloat = urls.count == 2 ? CGFloat(i) * 156 : (bounds.width - 140) / 2
            labels[i].frame = NSRect(x: x, y: top - 24, width: 140, height: 16)
            codes[i].frame = NSRect(x: x + 6, y: top + 6, width: 128, height: 128)
            let width = copies[i].intrinsicContentSize.width
            copies[i].frame = NSRect(x: x + (140 - width) / 2, y: top + 148, width: width, height: 24)
        }
    }
}
