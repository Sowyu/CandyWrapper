import AppKit
import DesignSystem
import T3Protocol

/// DeviceToolsPanel.tsx:94-361. Values change only after device.detail/action confirms them.
public final class DeviceToolsDrawerView: DSView {
    public var onAction: (([String: JSONValue]) -> Void)?
    public var onClose: (() -> Void)?
    private let title = LabelView("Tools", font: DSFont.ui(14, weight: .medium))
    private let close = ButtonView(nil, icon: .x, variant: .ghost, size: .iconSm)
    private let content = DSView()
    private lazy var scroll = ScrollAreaView(documentView: content, scrollbars: .native) // DeviceToolsPanel.tsx:116
    private var rows: [(NSView, NSView?, CGFloat)] = []
    private var controls: [ControlView] = []
    private var fields: [FieldView] = []
    private var choices: [(SelectView, String, [String])] = []
    private var switches: [(SwitchView, String)] = []
    private let foreground = LabelView("—", font: DSFont.mono(11))
    private let status = LabelView("Reading device settings…", font: DSFont.ui(11), color: Themed.color(\.mutedForeground))
    private var detail: JSONValue?
    private var platform = "ios"
    public var pending = false { didSet { updateControls() } }
    public override init(frame: NSRect) {
        super.init(frame: frame)
        [title, close, scroll].forEach(addSubview)
        close.setAccessibilityLabel("Close tools")
        close.action = { [weak self] in self?.onClose?() }
    }
    public func configure(platform: String) {
        self.platform = platform; detail = nil
        rows.forEach { $0.0.removeFromSuperview(); $0.1?.removeFromSuperview() }
        rows = []; controls = []; fields = []; choices = []; switches = []
        add(status, height: 28)
        section("App"); add(LabelView("Foreground", font: DSFont.ui(12)), foreground)
        submit("https://… or myapp://", "Open") { [weak self] in self?.act(["type": .string("openUrl"), "url": .string($0)]) }
        submit(platform == "ios" ? "Bundle ID to launch" : "Package name to launch", "Launch") { [weak self] in self?.act(["type": .string("launchApp"), "appId": .string($0)]) }
        for (title, action) in [("Terminate", "terminateApp"), ("Relaunch", "launchApp")] {
            button(title) { [weak self] in
                guard let self, let id = detail?["foregroundApp"]?["id"]?.stringValue else { return }
                act(["type": .string(action), "appId": .string(id)])
            }
        }
        section(platform == "ios" ? "Simulator" : "Emulator")
        choice("Appearance", key: "appearance", type: "setAppearance", values: ["light", "dark"], labels: ["Light", "Dark"])
        choice("Text size", key: "textSize", type: "setTextSize", values: ["small", "default", "large", "extra-large"], labels: ["Small", "Default", "Large", "Extra large"])
        if platform == "ios" {
            choice("Liquid Glass", key: "liquidGlass", type: "setLiquidGlass", values: ["clear", "tinted"], labels: ["Clear", "Tinted"])
            choice("Color filter", key: "colorFilter", type: "setColorFilter", values: ["none", "grayscale", "red-green", "green-red", "blue-yellow"], labels: ["None", "Grayscale", "Red / green (protanopia)", "Green / red (deuteranopia)", "Blue / yellow (tritanopia)"])
        } else {
            choice("Orientation", key: "orientation", type: "setOrientation", values: ["portrait", "landscape_left", "portrait_upside_down", "landscape_right"], labels: ["Portrait", "Landscape left", "Upside down", "Landscape right"])
        }
        toggle("Reduce Motion", "reduceMotion")
        if platform == "ios" {
            for (label, key) in [("Increase Contrast", "increaseContrast"), ("Reduce Transparency", "reduceTransparency"), ("Show Borders", "showBorders"), ("VoiceOver", "voiceOver")] { toggle(label, key) }
        } else { toggle("Network", "networkEnabled") }
        section("Location")
        let latitude = InputView(placeholder: "Latitude", size: .compact)
        let longitude = InputView(placeholder: "Longitude", size: .compact)
        fields += [latitude, longitude]; add(latitude); add(longitude)
        button("Set location") { [weak self, weak latitude, weak longitude] in
            guard let payload = DeviceToolsActions.location(latitude?.text ?? "", longitude?.text ?? "") else {
                self?.status.text = "Enter a valid latitude and longitude."; return
            }
            self?.act(payload)
        }
        let presets: [(String, Double, Double)] = [("San Francisco", 37.7749, -122.4194), ("New York", 40.7128, -74.006), ("London", 51.5074, -0.1278), ("Stockholm", 59.3293, 18.0686), ("Tokyo", 35.6762, 139.6503)]
        let preset = SelectView(options: presets.map(\.0), placeholder: "Choose a location", size: .compact)
        preset.onChange = { [weak self] i in self?.act(["type": .string("setLocation"), "latitude": .number(presets[i].1), "longitude": .number(presets[i].2)]) }
        controls.append(preset); add(preset)
        if platform == "ios" { button("Clear location") { [weak self] in self?.act(["type": .string("clearLocation")]) } }
        section("Permissions")
        let app = InputView(placeholder: platform == "ios" ? "Bundle ID" : "Package name", size: .compact)
        fields.append(app); add(app)
        let permissions = DeviceToolsActions.permissions(platform: platform)
        let permission = SelectView(options: permissions.map(\.1), selected: 0, size: .compact)
        controls.append(permission); add(permission)
        for decision in platform == "ios" ? ["grant", "revoke", "reset"] : ["grant", "revoke"] {
            button(decision.capitalized) { [weak self, weak app, weak permission] in
                guard let self, let i = permission?.selectedIndex else { return }
                let id = app?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !id.isEmpty else { status.text = "Enter an app ID."; return }
                act(["type": .string("setPermission"), "appId": .string(id), "permission": .string(permissions[i].0), "decision": .string(decision)])
            }
        }
        if platform == "ios" {
            section("Push notification")
            submit("Alert text", "Send") { [weak self] payload in
                guard let self, let id = detail?["foregroundApp"]?["id"]?.stringValue else { self?.status.text = "Open an app first."; return }
                act(["type": .string("sendPush"), "appId": .string(id), "payload": .string(payload)])
            }
            button("Shake") { [weak self] in self?.act(["type": .string("shake")]) }
        }
        updateControls(); needsLayout = true
    }
    public func apply(_ detail: JSONValue?, error: String? = nil) {
        if let detail { self.detail = detail }
        status.text = error ?? (self.detail == nil ? "Reading device settings…" : "")
        foreground.text = self.detail?["foregroundApp"]?["id"]?.stringValue ?? "—"
        updateControls()
    }
    private func updateControls() {
        let enabled = !pending && detail != nil
        controls.forEach { $0.isEnabled = enabled }; fields.forEach { $0.isEnabled = enabled }
        for (control, key, values) in choices {
            control.selectedIndex = detail?["settings"]?[key]?.stringValue.flatMap { values.firstIndex(of: $0) }
            if key == "liquidGlass" { control.isEnabled = enabled && detail?["settings"]?[key] != nil }
        }
        for (control, key) in switches {
            control.isOn = detail?["settings"]?[key]?.boolValue ?? false
            control.isEnabled = enabled && detail?["settings"]?[key]?.boolValue != nil
        }
    }
    private func act(_ value: [String: JSONValue]) { guard !pending, detail != nil else { return }; onAction?(value) }
    private func add(_ view: NSView, _ trailing: NSView? = nil, height: CGFloat = 32) {
        rows.append((view, trailing, height)); content.addSubview(view); trailing.map(content.addSubview)
    }
    private func section(_ text: String) { add(LabelView(text, font: DSFont.ui(12, weight: .medium), color: Themed.color(\.mutedForeground)), height: 34) }
    private func button(_ text: String, action: @escaping @MainActor () -> Void) {
        let button = ButtonView(text, variant: .outline, size: .xs); button.action = action
        controls.append(button); add(button)
    }
    private func submit(_ placeholder: String, _ action: String, run: @escaping (String) -> Void) {
        let input = InputView(placeholder: placeholder, size: .compact)
        let button = ButtonView(action, variant: .outline, size: .xs)
        button.action = { [weak input] in
            let value = input?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !value.isEmpty { run(value) }
        }
        controls.append(button); fields.append(input); add(input, button)
    }
    private func choice(_ title: String, key: String, type: String, values: [String], labels: [String]) {
        let select = SelectView(options: labels, placeholder: "—", size: .compact)
        select.onChange = { [weak self] i in self?.act(["type": .string(type), "value": .string(values[i])]); self?.updateControls() }
        choices.append((select, key, values)); controls.append(select)
        add(LabelView(title, font: DSFont.ui(12)), select)
    }
    private func toggle(_ title: String, _ key: String) {
        let toggle = SwitchView()
        toggle.onChange = { [weak self] value in self?.act(["type": .string("setToggle"), "setting": .string(key), "value": .bool(value)]); self?.updateControls() }
        switches.append((toggle, key)); controls.append(toggle)
        add(LabelView(title, font: DSFont.ui(12)), toggle)
    }
    public override func layout() {
        super.layout()
        title.frame = NSRect(x: 12, y: 7, width: bounds.width - 52, height: 22)
        close.frame = NSRect(x: bounds.width - 36, y: 4, width: 28, height: 28)
        scroll.frame = NSRect(x: 0, y: 36, width: bounds.width, height: max(0, bounds.height - 36))
        let width = scroll.scrollView.contentSize.width
        var y: CGFloat = 4
        for (leading, trailing, height) in rows {
            let trailingWidth = trailing.map { min(width * 0.52, max(50, $0.intrinsicContentSize.width)) } ?? 0
            leading.frame = NSRect(x: 12, y: y, width: max(0, width - 24 - (trailing == nil ? 0 : trailingWidth + 8)), height: height - 4)
            trailing?.frame = NSRect(x: width - 12 - trailingWidth, y: y, width: trailingWidth, height: min(height - 4, trailing?.intrinsicContentSize.height ?? 28))
            y += height
        }
        content.frame = NSRect(x: 0, y: 0, width: width, height: y + 8)
    }
    public override func updateLayer() { layer?.backgroundColor = WindowGlass.ground.cgColor(in: self) }
}

public enum DeviceToolsActions {
    public static func location(_ latitude: String, _ longitude: String) -> [String: JSONValue]? {
        guard let lat = Double(latitude), let lon = Double(longitude), lat.isFinite, lon.isFinite,
              (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        return ["type": .string("setLocation"), "latitude": .number(lat), "longitude": .number(lon)]
    }
    public static func permissions(platform: String) -> [(String, String)] {
        let common = [("camera", "Camera"), ("microphone", "Microphone"), ("photos", "Photos"), ("contacts", "Contacts"), ("calendar", "Calendar")]
        return common + (platform == "ios" ? [("reminders", "Reminders")] : []) + [("location", "Location"), ("notifications", "Notifications"), ("motion", platform == "ios" ? "Motion" : "Physical activity")] + (platform == "ios" ? [("media-library", "Media library"), ("faceid", "Face ID")] : [])
    }
}
