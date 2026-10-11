import AppKit
import DesignSystem
import T3Protocol

/// A provider instance's environment variables (ProviderInstanceCard.tsx:88-543, contracts providerInstance.ts).
public enum ProviderEnvironmentLogic {
    public struct Variable: Equatable, Sendable {
        public var name: String
        public var value: String
        public var sensitive: Bool
        /// The server hides a sensitive value and says so; the field shows empty with a "stored secret" placeholder.
        public var valueRedacted: Bool?
        public init(name: String, value: String, sensitive: Bool, valueRedacted: Bool? = nil) {
            self.name = name; self.value = value; self.sensitive = sensitive; self.valueRedacted = valueRedacted
        }
        var json: JSONValue {
            var o: [String: JSONValue] = ["name": .string(name), "value": .string(value), "sensitive": .bool(sensitive)]
            if let valueRedacted { o["valueRedacted"] = .bool(valueRedacted) }
            return .object(o)
        }
    }

    /// One editable row; `id` keeps a row's identity while its name changes.
    public struct Draft: Equatable, Sendable {
        public var id: Int
        public var name: String
        public var value: String
        public var sensitive: Bool
        public var valueRedacted: Bool?
        public init(id: Int, _ v: Variable) {
            self.id = id; name = v.name; value = v.value; sensitive = v.sensitive; valueRedacted = v.valueRedacted
        }
        public init(id: Int) { self.id = id; name = ""; value = ""; sensitive = true }
    }

    /// Driver fields that edit one named variable (`environmentFields`); the generic list leaves them out.
    public struct Field: Sendable { public var name, label, detail, placeholder: String; public var sensitive = true }
    public static func fields(_ driver: String) -> [Field] {
        driver == "cursor" ? [Field(name: "CURSOR_API_KEY", label: "Cursor API key", detail: "Optional. Overrides browser sign-in for this provider.",
                                    placeholder: "Paste API key")] : []
    }

    public static func isValidName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, first == "_" || (first.isASCII && CharacterSet.letters.contains(first)) else { return false }
        return name.unicodeScalars.allSatisfy { $0 == "_" || ($0.isASCII && CharacterSet.alphanumerics.contains($0)) }
    }

    public static func variables(_ instance: JSONValue) -> [Variable] {
        (instance["environment"]?.arrayValue ?? []).compactMap { v in
            guard let name = v["name"]?.stringValue else { return nil }
            return Variable(name: name, value: v["value"]?.stringValue ?? "", sensitive: v["sensitive"]?.boolValue ?? true,
                            valueRedacted: v["valueRedacted"]?.boolValue)
        }
    }

    /// `publishRows`: the variables the rows describe, or nil while a row has a name that isn't valid yet (or an
    /// unnamed row has content), so a half-typed row never saves. Untouched blank rows are skipped.
    public static func publish(_ rows: [Draft]) -> [Variable]? {
        var out: [Variable] = []
        for row in rows {
            let name = row.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isValidName(name) else {
                if !name.isEmpty || !row.value.isEmpty || !row.sensitive || row.valueRedacted != nil { return nil }
                continue
            }
            out.append(Variable(name: name, value: row.value, sensitive: row.sensitive, valueRedacted: row.valueRedacted))
        }
        return out
    }

    /// `updateEnvironment`: unnamed variables dropped, the key removed when nothing is left.
    public static func instance(_ instance: JSONValue, environment: [Variable]) -> JSONValue {
        var o = instance.objectValue ?? [:]
        let cleaned = environment.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
        if cleaned.isEmpty { o.removeValue(forKey: "environment") } else { o["environment"] = .array(cleaned.map(\.json)) }
        return .object(o)
    }

    /// `nextProviderEnvironmentWithFieldValue`: set, replace or (when empty) drop one named variable.
    public static func setting(_ environment: [Variable], field: Field, to value: String) -> [Variable] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        var next: [Variable] = [], found = false
        for v in environment {
            guard v.name == field.name else { next.append(v); continue }
            found = true
            if !trimmed.isEmpty { next.append(Variable(name: v.name, value: trimmed, sensitive: field.sensitive)) }
        }
        if !found, !trimmed.isEmpty { next.append(Variable(name: field.name, value: trimmed, sensitive: field.sensitive)) }
        return next
    }

    /// `normalizeProviderAccentColor`: `#rrggbb` or nothing.
    public static func accentColor(_ value: String?) -> String? {
        guard let t = value?.trimmingCharacters(in: .whitespacesAndNewlines), t.count == 7, t.first == "#",
              t.dropFirst().allSatisfy(\.isHexDigit) else { return nil }
        return t
    }

    /// `hexToHsv` (lib/color.ts).
    public static func hsv(_ hex: String) -> (h: Double, s: Double, v: Double) {
        let n = UInt32(hex.dropFirst(), radix: 16) ?? 0
        let r = Double((n >> 16) & 255) / 255, g = Double((n >> 8) & 255) / 255, b = Double(n & 255) / 255
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        var h = 0.0
        if d != 0 {
            if mx == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) } else if mx == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
            h *= 60
            if h < 0 { h += 360 }
        }
        return (h, mx == 0 ? 0 : d / mx, mx)
    }

    /// `hsvToHex`.
    public static func hex(h: Double, s: Double, v: Double) -> String {
        let hue = (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        let c = v * s, x = c * (1 - abs((hue / 60).truncatingRemainder(dividingBy: 2) - 1)), m = v - c
        let (r, g, b): (Double, Double, Double) = hue < 60 ? (c, x, 0) : hue < 120 ? (x, c, 0) : hue < 180 ? (0, c, x)
            : hue < 240 ? (0, x, c) : hue < 300 ? (x, 0, c) : (c, 0, x)
        return "#" + [r, g, b].map { String(format: "%02x", Int(((($0 + m) * 255)).rounded())) }.joined()
    }
}

/// `ProviderEnvironmentSection`'s list under the "Variables" row: name = value, the sensitive lock, remove,
/// and the note. Each field saves when it loses focus (`DraftInput`).
final class ProviderEnvironmentVariablesView: DSView, SettingsGroupRow {
    private(set) var rows: [ProviderEnvironmentLogic.Draft]
    /// Rows changed; publish when they describe a valid list.
    var onRowsChange: (([ProviderEnvironmentLogic.Draft]) -> Void)?
    private var lines: [Line] = []
    private let note = TextBlockView()
    private let enabled: Bool

    init(rows: [ProviderEnvironmentLogic.Draft], enabled: Bool) {
        self.rows = rows
        self.enabled = enabled
        super.init(frame: .zero)
        note.text = "Sensitive values are stored separately and never returned to the app."
        note.font = DSFont.ui(12)
        note.lineHeight = 16
        note.color = Themed.color(\.mutedForeground)
        addSubview(note)
        rebuild()
    }

    private func rebuild() {
        lines.forEach { $0.removeFromSuperview() }
        lines = rows.enumerated().map { index, row in
            let line = Line(row, index: index, enabled: enabled)
            line.onChange = { [weak self] next in self?.update(next) }
            line.onRemove = { [weak self] in self?.remove(row.id) }
            addSubview(line)
            return line
        }
        note.isHidden = rows.isEmpty
        needsLayout = true
    }

    private func update(_ next: ProviderEnvironmentLogic.Draft) {
        guard let i = rows.firstIndex(where: { $0.id == next.id }), rows[i] != next else { return }
        rows[i] = next
        onRowsChange?(rows)
    }

    private func remove(_ id: Int) {
        rows.removeAll { $0.id == id }
        rebuild()
        onRowsChange?(rows)
    }

    func height(forWidth width: CGFloat) -> CGFloat { rows.isEmpty ? 0 : CGFloat(rows.count) * 36 + 16 + 8 }

    override func layout() {
        super.layout()
        var y: CGFloat = 0
        for line in lines {
            line.frame = NSRect(x: 0, y: y, width: bounds.width, height: 28)
            y += 36
        }
        note.frame = NSRect(x: 0, y: y, width: bounds.width, height: 16)
    }

    /// One variable: `NAME` (176 wide), `=`, the value, the lock, the remove button (`gap-1.5`).
    final class Line: DSView {
        var onChange: ((ProviderEnvironmentLogic.Draft) -> Void)?
        var onRemove: (() -> Void)?
        private var row: ProviderEnvironmentLogic.Draft
        private let name = InputView(placeholder: "VARIABLE_NAME", text: "", size: .sm, font: .mono)
        private let equals = LabelView("=", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
        private let plain = InputView(placeholder: "value", text: "", size: .sm, font: .mono)
        private let secret = SecureInputView(placeholder: "value")
        private let lock = ButtonView(nil, icon: .lock, variant: .ghostMuted, size: .iconMicro)
        private let remove = ButtonView(nil, icon: .x, variant: .ghostDestructive, size: .iconMicro)
        private var lockTip: TooltipController?

        init(_ row: ProviderEnvironmentLogic.Draft, index: Int, enabled: Bool) {
            self.row = row
            super.init(frame: .zero)
            name.text = row.name
            name.setAccessibilityLabel("Environment variable name \(index + 1)")
            secret.monospaced = true
            for v in [plain, secret] as [NSView] { v.setAccessibilityLabel("Environment variable value \(index + 1)") }
            equals.lineHeight = 16
            lock.iconSize = 12
            remove.iconSize = 12
            remove.setAccessibilityLabel("Remove environment variable \(row.name.isEmpty ? "\(index + 1)" : row.name)")
            lockTip = TooltipController.attach(to: lock, text: "")
            name.onCommit = { [weak self] text in self?.edit { $0.name = text.trimmingCharacters(in: .whitespacesAndNewlines) } }
            plain.onCommit = { [weak self] text in self?.editValue(text) }
            secret.onCommit = { [weak self] text in self?.editValue(text) }
            secret.onSubmit = { [weak self] in guard let self else { return }; self.editValue(self.secret.text) }
            lock.action = { [weak self] in
                self?.edit { r in
                    let sensitive = !r.sensitive
                    r.sensitive = sensitive
                    if !(sensitive && r.valueRedacted == nil) { r.valueRedacted = sensitive ? r.valueRedacted : false }
                }
            }
            remove.action = { [weak self] in self?.onRemove?() }
            for v in [name, equals, plain, secret, lock, remove] as [NSView] { addSubview(v) }
            for c in [name, plain] { c.isEnabled = enabled }
            secret.isEnabled = enabled
            lock.isEnabled = enabled
            remove.isEnabled = enabled
            apply()
        }

        /// A value edit clears `valueRedacted`; committing the untouched empty field of a stored secret keeps it.
        private func editValue(_ text: String) {
            if row.valueRedacted == true, text.isEmpty { return }
            guard text != row.value || row.valueRedacted == true else { return }
            edit { $0.value = text; $0.valueRedacted = false }
        }

        private func edit(_ change: (inout ProviderEnvironmentLogic.Draft) -> Void) {
            var next = row
            change(&next)
            guard next != row else { return }
            row = next
            apply()
            onChange?(next)
        }

        private func apply() {
            let shown = row.valueRedacted == true ? "" : row.value
            let placeholder = row.valueRedacted == true ? "Stored secret, enter a new value to replace" : "value"
            plain.isHidden = row.sensitive
            secret.isHidden = !row.sensitive
            if !plain.state.focused { plain.text = shown }
            plain.placeholder = placeholder
            if !secret.isFirstResponderInside { secret.text = shown }
            secret.placeholder = placeholder
            lock.icon = row.sensitive ? .lock : .lockOpen
            lock.setAccessibilityLabel("Mark environment variable \(row.name.isEmpty ? "" : row.name + " ")as sensitive")
            lockTip?.text = row.sensitive ? "Sensitive, stored separately" : "Plain text"
        }

        override func layout() {
            super.layout()
            let w = bounds.width
            name.frame = NSRect(x: 0, y: 0, width: 176, height: 28)
            let ew = ceil(equals.textWidth) + 1
            equals.frame = NSRect(x: 176 + 6, y: 6, width: ew, height: 16)
            let vx = 176 + 6 + ew + 6
            remove.frame = NSRect(x: w - 20, y: 4, width: 20, height: 20)
            lock.frame = NSRect(x: w - 20 - 6 - 20, y: 4, width: 20, height: 20)
            let vw = max(0, lock.frame.minX - 6 - vx)
            plain.frame = NSRect(x: vx, y: 0, width: vw, height: 28)
            secret.frame = NSRect(x: vx, y: 0, width: vw, height: 28)
        }
    }
}

/// `ProviderEnvironmentFieldRow`'s control: a write-only field for one named variable and its clear button.
final class ProviderEnvironmentFieldControl: DSView {
    let input = SecureInputView()
    let clear = ButtonView(nil, icon: .x, variant: .ghostDestructive, size: .iconSm)

    init(field: ProviderEnvironmentLogic.Field, variable: ProviderEnvironmentLogic.Variable?, enabled: Bool,
         commit: @escaping @MainActor (String) -> Void, remove: @escaping @MainActor () -> Void) {
        super.init(frame: NSRect(x: 0, y: 0, width: 224, height: 32))
        input.text = variable?.valueRedacted == true ? "" : variable?.value ?? ""
        input.placeholder = variable?.valueRedacted == true ? "Stored secret - enter a new value to replace" : field.placeholder
        input.setAccessibilityLabel(field.label)
        input.isEnabled = enabled
        var last = input.text
        input.onCommit = { text in guard text != last else { return }; last = text; commit(text) }
        input.onSubmit = { [weak self] in guard let self else { return }; let t = self.input.text; guard t != last else { return }; last = t; commit(t) }
        clear.iconSize = 14
        clear.setAccessibilityLabel("Clear \(field.label)")
        clear.isHidden = variable == nil
        clear.isEnabled = enabled
        clear.action = { remove() }
        addSubview(input)
        addSubview(clear)
    }

    override func layout() {
        super.layout()
        let cw: CGFloat = clear.isHidden ? 0 : 28 + 8
        input.frame = NSRect(x: 0, y: 0, width: bounds.width - cw, height: bounds.height)
        clear.frame = NSRect(x: bounds.width - 28, y: (bounds.height - 28) / 2, width: 28, height: 28)
    }
}

/// `ProviderAccentColorPicker` (`layout="inline"`): a 28pt swatch button that opens the saturation plane, the
/// hue slider and a hex field, plus "Clear color" once one is set. Changes commit after 120 ms.
final class ProviderAccentColorButton: ControlView {
    private(set) var color: String?
    private let plus = IconView(name: .plus, size: 16, strokeColor: Themed.color(\.mutedForeground))
    private let displayName: String
    private let commit: (String?) -> Void
    private var pending: DispatchWorkItem?

    init(displayName: String, color: String?, commit: @escaping (String?) -> Void) {
        self.displayName = displayName
        self.color = ProviderEnvironmentLogic.accentColor(color)
        self.commit = commit
        super.init(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        addSubview(plus)
        setAccessibilityRole(.button)
        apply()
    }

    private func apply() {
        plus.isHidden = color != nil
        setAccessibilityLabel("\(color == nil ? "Add" : "Change") accent color for \(displayName)")
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = 8
        if let color, let c = PullRequestStyle.hex(color) {
            layer?.backgroundColor = c.cgColor
        } else {
            layer?.backgroundColor = state.hovered ? Themed.color(\.accent).cgColor(in: self) : NSColor.clear.cgColor
        }
    }

    override func stateDidChange(from old: State) { super.stateDidChange(from: old); needsDisplay = true }
    override func layout() { super.layout(); plus.frame = NSRect(x: 6, y: 6, width: 16, height: 16) }

    /// Optimistic like T3: the swatch follows at once, the write waits 120 ms for the drag to settle.
    func set(_ next: String?) {
        color = ProviderEnvironmentLogic.accentColor(next)
        apply()
        pending?.cancel()
        let value = color
        let work = DispatchWorkItem { [weak self] in self?.commit(value) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    override func performAction() {
        let panel = ProviderAccentColorPanel(color: color ?? "#2563eb", clearable: color != nil)
        panel.onChange = { [weak self] hex in self?.set(hex) }
        let popover = PopoverView(content: panel, padding: .none)
        panel.onClear = { [weak self] in self?.set(nil); self?.popupHost?.closeAll() }
        popover.show(from: self, placement: PopupPlacement(side: .bottom, align: .start, sideOffset: 6))
    }
}

/// The popover body: the plane, then the hue slider and the hex field (`w-56`, `p-3 gap-3`).
final class ProviderAccentColorPanel: DSView {
    var onChange: ((String) -> Void)?
    var onClear: (() -> Void)?
    private let plane: ColorSaturationValuePlaneView
    private let hue: ColorHueSliderView
    private let hexField = InputView(placeholder: "", text: "", size: .compact, font: .mono)
    private let clear = ButtonView("Clear color", icon: .x, variant: .ghostMuted, size: .compact)
    private let rule = CALayer()
    private let clearable: Bool

    init(color: String, clearable: Bool) {
        let v = ProviderEnvironmentLogic.hsv(color)
        plane = ColorSaturationValuePlaneView(hue: v.h, saturation: v.s, value: v.v, variant: .edge)
        hue = ColorHueSliderView(hue: v.h)
        self.clearable = clearable
        super.init(frame: .zero)
        plane.setAccessibilityLabel("Accent color")
        hue.setAccessibilityLabel("Accent color hue")
        hexField.text = color
        hexField.setAccessibilityLabel("Custom hex accent color")
        plane.onChange = { [weak self] s, val in self?.changed(s: s, v: val) }
        hue.onChange = { [weak self] h in guard let self else { return }; self.plane.hue = h; self.changed(s: self.plane.saturation, v: self.plane.value) }
        hexField.onChange = { [weak self] text in
            guard let self, ProviderEnvironmentLogic.accentColor(text) == text else { return }
            let v = ProviderEnvironmentLogic.hsv(text)
            self.plane.hue = v.h; self.plane.saturation = v.s; self.plane.value = v.v; self.hue.hue = v.h
            self.onChange?(text)
        }
        hexField.onCommit = { [weak self] _ in self?.syncHex() }
        clear.action = { [weak self] in self?.onClear?() }
        clear.isHidden = !clearable
        layer?.addSublayer(rule)
        for v in [plane, hue, hexField, clear] as [NSView] { addSubview(v) }
    }

    private var current: String { ProviderEnvironmentLogic.hex(h: hue.hue, s: plane.saturation, v: plane.value) }
    private func syncHex() { if !hexField.state.focused { hexField.text = current } }

    private func changed(s: Double, v: Double) {
        hexField.text = current
        onChange?(current)
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 224, height: plane.intrinsicContentSize.height + 12 + 16 + 12 + 30 + 12 + (clearable ? 1 + 4 + 28 + 4 : 0)) }

    override func updateLayer() { rule.backgroundColor = Themed.color(\.border, 0.6).cgColor(in: self) }

    override func layout() {
        super.layout()
        let ph = plane.intrinsicContentSize.height
        plane.frame = NSRect(x: 0, y: 0, width: 224, height: ph)
        hue.frame = NSRect(x: 12, y: ph + 12, width: 200, height: 16)
        hexField.frame = NSRect(x: 12, y: ph + 12 + 16 + 12, width: 200, height: 30)
        let y = ph + 12 + 16 + 12 + 30 + 12
        CATransaction.begin(); CATransaction.setDisableActions(true)
        rule.frame = CGRect(x: 0, y: y, width: 224, height: 1)
        CATransaction.commit()
        rule.isHidden = !clearable
        clear.frame = NSRect(x: 4, y: y + 1 + 4, width: 216, height: 28)
    }
}
