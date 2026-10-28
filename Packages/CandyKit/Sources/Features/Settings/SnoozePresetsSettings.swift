import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// SnoozePresetsSettings.tsx:122-300 (3824), using the existing native settings rows. Rows sort soonest first like
/// the menu. T3 sorts when focus leaves the list (#26427, :264-276); here an edit's rows sort once the pointer is
/// outside the list and no field in it is editing, so a row never moves under the pointer.
final class SnoozePresetsEditor: DSView, SettingsGroupRow {
    private(set) var presets: [SnoozePresetSetting] = []
    private var source: [SnoozePresetSetting]?
    private var sourceKey = ""
    private var failureRevision = 0
    private var pending: [[SnoozePresetSetting]] = []
    private var rows: [SnoozePresetFields] = []
    private let add = ButtonView("Add option", icon: .plus, variant: .ghostMuted, size: .sm)
    private let preview = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    var onChange: (([SnoozePresetSetting]) -> Void)?
    var onHeightChange: (() -> Void)?
    /// An edit since the rows last sorted.
    private var unsettled = false
    /// Read from the window, since a list scrolled under a still pointer gets no entered event.
    private var pointerInside: Bool {
        guard let window else { return false }
        return bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        addSubview(add); addSubview(preview)
        preview.lineHeight = 16
        add.action = { [weak self] in
            guard let self, self.presets.count < SnoozePresetSetting.maximumCount else { return }
            let candidates = [15, 30, 60, 120, 180, 240, 1440, 2880].map { SnoozePresetSetting.after(minutes: $0) }
            self.save(self.presets + [candidates.first { !self.presets.contains($0) } ?? .after(minutes: 60)])
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func refresh(_ saved: [SnoozePresetSetting], sourceKey: String = "", failureRevision: Int = 0) {
        if sourceKey != self.sourceKey || failureRevision != self.failureRevision {
            self.sourceKey = sourceKey
            self.failureRevision = failureRevision
            source = nil
            pending = []
        }
        guard saved != source else { return }
        source = saved
        if let ack = pending.firstIndex(of: saved) {
            pending.removeFirst(ack + 1)
            if !pending.isEmpty { return }
        } else { pending = [] }
        presets = SnoozePresets.soonestFirst(saved, now: Date()).map { saved[$0] }
        unsettled = false
        rebuild()
    }

    func save(_ next: [SnoozePresetSetting]) {
        guard next.count <= SnoozePresetSetting.maximumCount else { return }
        presets = next
        pending.append(next)
        unsettled = true
        rebuild()
        onChange?(next)
        // A field commits before the next one takes focus, so look once focus has moved.
        if !pointerInside { DispatchQueue.main.async { [weak self] in self?.settle() } }
    }

    override func mouseExited(with event: NSEvent) { settle() }

    /// Sorts the rows once nothing in the list is being edited.
    private func settle() {
        guard unsettled, !pointerInside else { return }
        if let editing = window?.firstResponder as? NSView, editing.isDescendant(of: self) { return }
        unsettled = false
        let order = SnoozePresets.soonestFirst(presets, now: Date())
        guard order != Array(presets.indices) else { return }
        presets = order.map { presets[$0] }
        rebuild()
    }

    private func rebuild() {
        while rows.count > presets.count { rows.removeLast().removeFromSuperview() }
        for i in presets.indices {
            if i == rows.count { let row = SnoozePresetFields(); rows.append(row); addSubview(row) }
            rows[i].set(presets[i])
            rows[i].onChange = { [weak self] next in
                guard let self, self.presets.indices.contains(i) else { return }
                var values = self.presets; values[i] = next; self.save(values)
            }
            rows[i].onRemove = { [weak self] in
                guard let self else { return }
                self.save(self.presets.enumerated().filter { $0.offset != i }.map(\.element))
            }
        }
        let menu = SnoozePresets.resolve(now: Date(), presets: presets)
        preview.text = menu.isEmpty ? "Menus offer only Custom…" : "Menu now: " + menu.map { "\($0.label) \($0.whenLabel)" }.joined(separator: " · ")
        add.isEnabled = presets.count < SnoozePresetSetting.maximumCount
        needsLayout = true
        onHeightChange?()
    }

    /// Below this the preview wraps under the fields.
    static let wideWidth: CGFloat = 534
    func height(forWidth width: CGFloat) -> CGFloat { CGFloat(rows.count) * (width < Self.wideWidth ? 68 : 36) + 52 }
    override func layout() {
        super.layout()
        let height: CGFloat = bounds.width < Self.wideWidth ? 68 : 36
        for (i, row) in rows.enumerated() { row.frame = NSRect(x: 0, y: CGFloat(i) * height, width: bounds.width, height: height) }
        let end = CGFloat(rows.count) * height
        preview.frame = NSRect(x: 0, y: end + 4, width: bounds.width, height: 16)
        add.frame = NSRect(x: 0, y: end + 24, width: 118, height: 28)
    }
}

private final class SnoozePresetFields: DSView {
    private let when = settingsSelect(["After", "Today", "Tomorrow", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"], width: 120)
    private let amount = NumberFieldView(value: 1, size: .sm)
    private let units = settingsSelect(["minutes", "hours", "days"], width: 90)
    private let time = InputView(placeholder: "09:00", text: "09:00", size: .sm)
    private let remove = ButtonView(nil, icon: .x, variant: .ghostMuted, size: .iconSm)
    private let preview = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    private var setting = SnoozePresetSetting.after(minutes: 60)
    private var minutes = 60
    private var clock = "09:00"
    private var multiplier = 60
    var onChange: ((SnoozePresetSetting) -> Void)?
    var onRemove: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        [when, amount, units, time, remove, preview].forEach(addSubview)
        when.setAccessibilityLabel("When")
        amount.setAccessibilityLabel("Snooze duration")
        time.setAccessibilityLabel("Local snooze time, HH:MM")
        remove.setAccessibilityLabel("Remove snooze option")
        when.onChange = { [weak self] index in
            guard let self else { return }
            self.onChange?(index == 0 ? .after(minutes: self.minutes) : .at(day: SnoozePresetSetting.days[index - 1], time: self.clock))
        }
        amount.onChange = { [weak self] value in
            guard let self else { return }
            self.onChange?(.after(minutes: max(1, min(SnoozePresetSetting.maximumMinutes, Int(value) * self.multiplier))))
        }
        units.onChange = { [weak self] index in
            guard let self else { return }
            self.multiplier = [1, 60, 1440][index]
            self.onChange?(.after(minutes: max(1, min(SnoozePresetSetting.maximumMinutes, Int(self.amount.value) * self.multiplier))))
        }
        time.onCommit = { [weak self] text in
            guard let self, case .at(let day, _) = self.setting else { return }
            if let next = SnoozePresetSetting(.object(["kind": .string("at"), "day": .string(day), "time": .string(text)])) {
                self.onChange?(next)
            } else { self.time.text = self.clock }
        }
        remove.action = { [weak self] in self?.onRemove?() }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func set(_ value: SnoozePresetSetting) {
        setting = value
        switch value {
        case .after(let n):
            minutes = n
            multiplier = n % 1440 == 0 ? 1440 : n % 60 == 0 ? 60 : 1
            amount.value = Double(n) / Double(multiplier)
            amount.range = 1...Double(SnoozePresetSetting.maximumMinutes / multiplier)
            units.selectedIndex = [1, 60, 1440].firstIndex(of: multiplier)
            when.selectedIndex = 0
            time.isHidden = true; amount.isHidden = false; units.isHidden = false
        case .at(let day, let t):
            clock = t; time.text = t
            when.selectedIndex = SnoozePresetSetting.days.firstIndex(of: day).map { $0 + 1 }
            time.isHidden = false; amount.isHidden = true; units.isHidden = true
        }
        preview.text = SnoozePresets.resolve(value, now: Date()).map { "\($0.label) \($0.whenLabel)" } ?? "Passed for today"
        needsLayout = true
    }

    override func layout() {
        super.layout()
        when.frame = NSRect(x: 0, y: 2, width: 120, height: 28)
        // `w-32`, so two digits fit beside the steppers (T3 3824 #26427, SnoozePresetsSettings.tsx:416).
        amount.frame = NSRect(x: 128, y: 2, width: 128, height: 28)
        units.frame = NSRect(x: 264, y: 2, width: 90, height: 28)
        time.frame = NSRect(x: 128, y: 2, width: 104, height: 28)
        remove.frame = NSRect(x: bounds.width - 28, y: 2, width: 28, height: 28)
        let x: CGFloat = bounds.width < SnoozePresetsEditor.wideWidth ? 0 : 362
        preview.frame = NSRect(x: x, y: bounds.width < SnoozePresetsEditor.wideWidth ? 38 : 8, width: max(0, bounds.width - x - 32), height: 16)
    }
}
