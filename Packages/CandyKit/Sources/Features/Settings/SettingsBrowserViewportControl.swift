import AppKit
import DesignSystem
import T3Protocol

/// IntegrationsSettings.tsx:248-395; shared/previewViewport.ts device catalog.
public enum SettingsBrowserViewport {
    public static let presets: [(id: String, label: String, width: Int, height: Int)] = [
        ("iphone-se", "iPhone SE", 375, 667),
        ("iphone-xr", "iPhone XR", 414, 896),
        ("iphone-12-pro", "iPhone 12 Pro", 390, 844),
        ("iphone-14-pro-max", "iPhone 14 Pro Max", 430, 932),
        ("pixel-7", "Pixel 7", 412, 915),
        ("samsung-galaxy-s8-plus", "Samsung Galaxy S8+", 360, 740),
        ("samsung-galaxy-s20-ultra", "Samsung Galaxy S20 Ultra", 412, 915),
        ("ipad-mini", "iPad Mini", 768, 1024),
        ("ipad-air", "iPad Air", 820, 1180),
        ("ipad-pro", "iPad Pro", 1024, 1366),
        ("surface-pro-7", "Surface Pro 7", 912, 1368),
        ("surface-duo", "Surface Duo", 540, 720),
        ("galaxy-z-fold-5", "Galaxy Z Fold 5", 344, 882),
        ("asus-zenbook-fold", "Asus Zenbook Fold", 853, 1280),
        ("samsung-galaxy-a51-71", "Samsung Galaxy A51/71", 412, 914),
        ("nest-hub", "Nest Hub", 1024, 600),
        ("nest-hub-max", "Nest Hub Max", 1280, 800),
    ]
    public static func resized(_ value: JSONValue, width: Int, height: Int) -> JSONValue? {
        guard (240...3840).contains(width), (240...3840).contains(height), width * height <= 3840 * 2160 else { return nil }
        return .object(["_tag": .string("freeform"), "width": .number(Double(width)), "height": .number(Double(height))])
    }
}

final class SettingsBrowserViewportControl: DSView {
    var value: JSONValue = .object(["_tag": .string("fill")]) { didSet { refresh() } }
    var onChange: ((JSONValue) -> Void)?
    private let select = SelectView(options: ["Fill panel", "Responsive"] + SettingsBrowserViewport.presets.map { $0.label }, selected: 0, size: .sm)
    private let widthInput = InputView(size: .sm)
    private let heightInput = InputView(size: .sm)
    private let times = LabelView("×", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    private let rotate = ButtonView(nil, icon: .rotateCw, variant: .ghostMuted, size: .iconSm)
    override init(frame: NSRect) {
        super.init(frame: frame)
        [select, widthInput, heightInput, times, rotate].forEach(addSubview)
        select.setAccessibilityLabel("Default browser viewport")
        widthInput.setAccessibilityLabel("Default viewport width")
        heightInput.setAccessibilityLabel("Default viewport height")
        rotate.setAccessibilityLabel("Rotate viewport")
        select.onChange = { [weak self] index in
            guard let self else { return }
            if index == 0 { onChange?(.object(["_tag": .string("fill")])) }
            else if index == 1, let next = SettingsBrowserViewport.resized(value, width: width, height: height) { onChange?(next) }
            else {
                let p = SettingsBrowserViewport.presets[index - 2]
                onChange?(.object(["_tag": .string("preset"), "presetId": .string(p.id), "width": .number(Double(p.width)), "height": .number(Double(p.height))]))
            }
        }
        widthInput.onCommit = { [weak self] text in
            guard let self else { return }
            if let w = Int(text), let next = SettingsBrowserViewport.resized(value, width: w, height: height) { onChange?(next) }
            refresh()
        }
        heightInput.onCommit = { [weak self] text in
            guard let self else { return }
            if let h = Int(text), let next = SettingsBrowserViewport.resized(value, width: width, height: h) { onChange?(next) }
            refresh()
        }
        rotate.action = { [weak self] in
            guard let self, let next = SettingsBrowserViewport.resized(value, width: height, height: width) else { return }
            onChange?(next)
        }
        refresh()
    }
    private var width: Int { Int(value["width"]?.doubleValue ?? 1280) }
    private var height: Int { Int(value["height"]?.doubleValue ?? 800) }
    private var sized: Bool { value["_tag"]?.stringValue != "fill" }
    private func refresh() {
        select.selectedIndex = !sized ? 0 : value["_tag"]?.stringValue == "preset" ? SettingsBrowserViewport.presets.firstIndex { $0.id == value["presetId"]?.stringValue }.map { $0 + 2 } ?? 1 : 1
        widthInput.text = String(width); heightInput.text = String(height)
        for view in [widthInput, heightInput, times, rotate] { view.isHidden = !sized }
        frame.size = intrinsicContentSize; needsLayout = true
    }
    override var intrinsicContentSize: NSSize { NSSize(width: 216, height: sized ? 72 : 32) }
    override func layout() {
        super.layout()
        select.frame = NSRect(x: 40, y: 0, width: 176, height: 32)
        widthInput.frame = NSRect(x: 0, y: 40, width: 80, height: 28)
        times.frame = NSRect(x: 84, y: 44, width: 12, height: 20)
        heightInput.frame = NSRect(x: 100, y: 40, width: 80, height: 28)
        rotate.frame = NSRect(x: 184, y: 40, width: 32, height: 32)
    }
}
