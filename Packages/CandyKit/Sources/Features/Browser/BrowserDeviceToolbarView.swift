import AppKit
import DesignSystem
import T3Protocol

/// T3's `BrowserDeviceToolbar` for a server tab with a fixed viewport (apps/web/src/browser/BrowserDeviceToolbar.tsx):
/// "Dimensions", the device select (Responsive, then the Standard presets with their sizes), width and height
/// fields, the aspect lock, rotate and close. 38pt tall across the panel, `border-b border-border/70
/// bg-background/95 px-1.5 shadow-xs`, `gap-0.5`. Each change goes out through `onChange` and the toolbar
/// stays disabled until it settles (`pending`).
public final class BrowserDeviceToolbarView: DSView {
    /// Sends a viewport setting (`preview.resize`); throws when the server refuses it.
    public var onChange: (@MainActor (JSONValue) async throws -> Void)?

    /// The tab's fixed viewport (`freeform` or `preset`).
    public var setting: JSONValue = BrowserViewport.freeform(.init(width: 1024, height: 768)) {
        didSet { if setting != oldValue { custom = nil; refresh() } }
    }
    /// `serverAspectRatioLocked`: the lock keeps the current ratio while it is on.
    public var aspectLocked = false { didSet { refresh() } }

    private let dimensions = LabelView("Dimensions", font: DSFont.ui(11, weight: .medium))
    let select = SelectView(options: ["Responsive"] + SettingsBrowserViewport.presets.map(\.label), selected: 0, variant: .ghost, size: .xs)
    let widthField = InputView(size: .compact, font: .mono)
    let heightField = InputView(size: .compact, font: .mono)
    private let times = LabelView("×", font: DSFont.ui(12))
    let lock = ButtonView(nil, icon: .unlink2, variant: .ghost, size: .iconXs)
    let rotate = ButtonView(nil, icon: nil, variant: .ghost, size: .iconXs)
    let close = ButtonView(nil, icon: .x, variant: .ghost, size: .iconXs)
    private let border = CALayer()
    private var lockTip: TooltipController?
    private(set) var pending = false { didSet { refresh() } }
    /// The fields' text while one is being edited (`customSize`).
    private var custom: (width: String, height: String)?
    /// True while the toolbar writes a field itself: a field reports every text change, its own included.
    private var syncing = false

    /// `ScreenRotationIcon` (browser/ScreenRotationIcon.tsx): the rect rotated -45° as a path.
    static let rotationIcon: IconDefinition = {
        let paint = IconPaint(stroke: .current, strokeWidth: 2, lineCap: .round, lineJoin: .round)
        return IconDefinition(viewBox: IconViewBox(x: 0, y: 0, width: 24, height: 24), elements: [
            IconElement(.path(d: "M11.0101 6.2724A1.4 1.4 0 0 1 12.9899 6.2724L17.7276 11.0101A1.4 1.4 0 0 1 17.7276 12.9899L12.9899 17.7276A1.4 1.4 0 0 1 11.0101 17.7276L6.2724 12.9899A1.4 1.4 0 0 1 6.2724 11.0101Z"), paint),
            IconElement(.path(d: "M12.5 2a10 10 0 0 1 8.4 5.4"), paint),
            IconElement(.path(d: "M20.8 3.5v4h-4"), paint),
            IconElement(.path(d: "M11.5 22a10 10 0 0 1-8.4-5.4"), paint),
            IconElement(.path(d: "M3.2 20.5v-4h4"), paint),
        ])
    }()

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.masksToBounds = false
        border.actions = ["position": NSNull(), "bounds": NSNull(), "backgroundColor": NSNull()]
        layer?.addSublayer(border)
        dimensions.lineHeight = 16
        times.lineHeight = 16
        select.alignItemWithTrigger = false
        select.groupLabels = [1: "Standard"]
        select.optionTrailingDetails = [nil] + SettingsBrowserViewport.presets.map { "\($0.width) × \($0.height)" }
        select.setAccessibilityLabel("Browser device preset")
        widthField.setAccessibilityLabel("Viewport width")
        heightField.setAccessibilityLabel("Viewport height")
        rotate.iconDefinition = Self.rotationIcon
        rotate.setAccessibilityLabel("Rotate viewport")
        close.setAccessibilityLabel("Close device toolbar")
        lockTip = TooltipController.attach(to: lock, text: "Lock aspect ratio", placement: PopupPlacement(side: .top, align: .center, sideOffset: 4))
        for v in [dimensions, select, widthField, times, heightField, lock, rotate, close] as [NSView] { addSubview(v) }
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel("Browser device toolbar")

        select.onChange = { [weak self] i in self?.selectViewport(i) }
        for (field, isWidth) in [(widthField, true), (heightField, false)] {
            field.onChange = { [weak self] text in if self?.syncing == false { self?.edit(text, width: isWidth) } }
            field.onCommit = { [weak self] _ in self?.applyCustomSize() }
            field.onStateChange = { [weak self] _ in self?.focusChanged() }
        }
        lock.action = { [weak self] in self?.toggleLock() }
        rotate.action = { [weak self] in self?.rotateViewport() }
        close.action = { [weak self] in self?.apply(BrowserViewport.fill, locked: false) }
        refresh()
    }

    // MARK: State

    private var size: BrowserViewport.Size { BrowserViewport.size(setting) ?? .init(width: 1024, height: 768) }
    private var presented: (width: String, height: String) { custom ?? (String(size.width), String(size.height)) }
    private var customWidth: Int? { Int(presented.width) }
    private var customHeight: Int? { Int(presented.height) }
    private var customValid: Bool { BrowserViewport.isValid(width: customWidth, height: customHeight) }

    private func refresh() {
        let selected = BrowserViewport.selectedPreset(setting).flatMap { id in SettingsBrowserViewport.presets.firstIndex { $0.id == id } }
        select.selectedIndex = selected.map { $0 + 1 } ?? 0
        syncing = true
        if !widthField.state.focused, widthField.text != presented.width { widthField.text = presented.width }
        if !heightField.state.focused, heightField.text != presented.height { heightField.text = presented.height }
        syncing = false
        widthField.isInvalid = !customValid
        heightField.isInvalid = !customValid
        widthField.isEnabled = !pending
        heightField.isEnabled = !pending
        select.isEnabled = !pending
        rotate.isEnabled = !pending
        close.isEnabled = !pending
        lock.isEnabled = !pending && customValid
        lock.icon = aspectLocked ? .link2 : .unlink2
        lock.variant = aspectLocked ? .secondary : .ghost
        lock.iconColor = aspectLocked ? Themed.color(\.foreground) : nil
        lock.setAccessibilityLabel(aspectLocked ? "Unlock viewport aspect ratio" : "Lock viewport aspect ratio")
        lockTip?.text = aspectLocked ? "Unlock aspect ratio" : "Lock aspect ratio"
        needsLayout = true
    }

    /// `apply`: send, then clear the edit; the lock follows only a change that landed.
    private func apply(_ next: JSONValue, locked: Bool? = nil) {
        guard let onChange else { return }
        pending = true
        Task { @MainActor [weak self] in
            do {
                try await onChange(next)
                guard let self else { return }
                if let locked { self.aspectLocked = locked }
                self.custom = nil
                self.pending = false
            } catch {
                self?.pending = false
            }
        }
    }

    private func selectViewport(_ index: Int) {
        if index == 0 {
            // Responsive keeps the size as a freeform viewport.
            if setting["_tag"]?.stringValue == "freeform" { return }
            apply(BrowserViewport.freeform(size))
            return
        }
        let preset = SettingsBrowserViewport.presets[index - 1]
        guard let next = BrowserViewport.preset(preset.id) else { return }
        apply(next, locked: aspectLocked)
    }

    /// `updateCustomDimension`: with the lock on, a valid number moves the other field to keep the ratio.
    private func edit(_ text: String, width isWidth: Bool) {
        var next = presented
        if isWidth { next.width = text } else { next.height = text }
        if aspectLocked, let n = Int(text), (BrowserViewport.minDimension...BrowserViewport.maxDimension).contains(n) {
            let s = size
            let r = BrowserViewport.resize((Double(s.width), Double(s.height)), dx: isWidth ? Double(n - s.width) : 0,
                                           dy: isWidth ? 0 : Double(n - s.height), east: isWidth, south: !isWidth,
                                           aspectRatio: Double(s.width) / Double(s.height))
            next = (String(r.width), String(r.height))
            syncing = true
            (isWidth ? heightField : widthField).text = isWidth ? next.height : next.width
            syncing = false
        }
        custom = next
        widthField.isInvalid = !customValid
        heightField.isInvalid = !customValid
        lock.isEnabled = !pending && customValid
    }

    /// `applyCustomSize`: a valid, changed size goes out as freeform; anything else snaps back.
    private func applyCustomSize() {
        guard let w = customWidth, let h = customHeight, customValid, w != size.width || h != size.height else {
            custom = nil
            refresh()
            return
        }
        apply(BrowserViewport.freeform(.init(width: w, height: h)))
    }

    /// The toolbar's `onBlur`: focus left both fields.
    private func focusChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.widthField.state.focused, !self.heightField.state.focused, self.custom != nil else { return }
            self.applyCustomSize()
        }
    }

    /// `rotate`: an edited size turns as freeform; otherwise the setting keeps its kind and preset.
    private func rotateViewport() {
        if let w = customWidth, let h = customHeight, customValid, w != size.width || h != size.height {
            apply(BrowserViewport.freeform(.init(width: h, height: w)), locked: aspectLocked)
            return
        }
        guard case .object(var o) = setting else { return }
        o["width"] = .number(Double(size.height)); o["height"] = .number(Double(size.width))
        apply(.object(o), locked: aspectLocked)
    }

    private func toggleLock() { aspectLocked.toggle() }

    // MARK: Layout

    public override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: BrowserViewport.toolbarHeight) }

    public override func layout() {
        super.layout()
        let w = bounds.width, h = BrowserViewport.toolbarHeight
        CATransaction.begin(); CATransaction.setDisableActions(true)
        border.frame = CGRect(x: 0, y: h - 1, width: w, height: 1)
        layer?.shadowPath = CGPath(rect: bounds, transform: nil)
        CATransaction.commit()
        var x: CGFloat = 6
        func place(_ v: NSView, _ width: CGFloat, _ height: CGFloat) {
            v.frame = NSRect(x: x, y: ((h - 1 - height) / 2).rounded(), width: width, height: height)
            x += width + 2
        }
        dimensions.isHidden = w < 560
        if !dimensions.isHidden { place(dimensions, ceil(dimensions.textWidth), 16); x += 2 }
        place(select, w >= 440 ? 144 : 96, 24)
        let fieldW: CGFloat = w >= 360 ? 56 : 52
        place(widthField, fieldW, 30)
        place(times, ceil(times.textWidth), 16)
        place(heightField, fieldW, 30)
        place(lock, 24, 24)
        place(rotate, 24, 24)
        // `sticky right-0 ml-auto`: the close button stays at the end.
        close.frame = NSRect(x: max(x, w - 6 - 24), y: ((h - 1 - 24) / 2).rounded(), width: 24, height: 24)
    }

    public override func updateLayer() {
        layer?.backgroundColor = Themed.color(\.background, 0.95).cgColor(in: self)
        border.backgroundColor = Themed.color(\.border, 0.7).cgColor(in: self)
        // `shadow-xs`: 0 1px 2px rgb(0 0 0 / 0.05) under the bar.
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.05
        layer?.shadowRadius = 1
        layer?.shadowOffset = CGSize(width: 0, height: 1)
        dimensions.color = Themed.color(\.mutedForeground)
        times.color = Themed.color(\.mutedForeground)
    }
}
