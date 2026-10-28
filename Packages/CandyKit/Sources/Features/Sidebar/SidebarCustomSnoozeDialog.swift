import AppKit
import DesignSystem
import T3Store

/// `CustomSnoozeDialog` (apps/web/src/components/CustomSnoozeDialog.tsx): "Date and time" or "Duration",
/// validated with `resolveCustomSnooze`, opened from the thread menu's and the snooze button's Custom….
@MainActor
public enum SidebarCustomSnoozeDialog {
    /// Shows the dialog over `window`; `done` gets the wake time, or nil on Cancel and Escape. With `editOptions`, the
    /// footer starts with "Edit snooze options", which closes the dialog and opens them (T3 3824 #26427,
    /// CustomSnoozeDialog.tsx:229-244).
    @discardableResult
    public static func present(in window: NSWindow, now: Date = Date(), editOptions: (@MainActor () -> Void)? = nil,
                               done: @escaping @MainActor (Date?) -> Void) -> ModalHost {
        let dialog = DialogView(title: "Custom snooze", message: "Choose when snoozed threads return to your inbox.")
        dialog.maxWidth = 384 // `sm:max-w-sm`
        let form = SidebarCustomSnoozeForm(initial: now.addingTimeInterval(3600))
        dialog.panelContent = [form]
        let cancel = ButtonView("Cancel", variant: .outline)
        let snooze = ButtonView("Snooze")
        let edit = editOptions.map { _ in ButtonView("Edit snooze options", icon: .settings2, variant: .ghostMuted) }
        dialog.footerButtons = (edit.map { [$0] } ?? []) + [cancel, snooze]
        dialog.footerLeadingCount = edit == nil ? 0 : 1
        let host = ModalHost.present(dialog, in: window)
        var finished = false
        let finish: @MainActor (Date?) -> Void = { [weak host] wake in
            guard !finished else { return }
            finished = true
            host?.close()
            done(wake)
        }
        host.onDismiss = { finish(nil) }
        dialog.onClose = { finish(nil) }
        cancel.action = { finish(nil) }
        edit?.action = {
            finish(nil)
            editOptions?()
        }
        let submit: @MainActor () -> Void = { [weak form, weak dialog] in
            guard let form else { return }
            if let wake = form.input.resolve(now: Date()) { finish(wake); return }
            form.error = form.mode == .date ? "Choose a valid date and time in the future." : "Enter a positive duration."
            dialog?.needsLayout = true
        }
        snooze.action = submit
        form.onSubmit = submit
        form.onChange = { [weak dialog] in dialog?.needsLayout = true }
        return host
    }
}

/// The dialog's form: the schedule type toggle, then the date and time or the amount and unit, then the error.
final class SidebarCustomSnoozeForm: DSView {
    enum Mode { case date, duration }
    private(set) var mode: Mode = .date
    var error: String? { didSet { errorText.text = error ?? ""; errorText.isHidden = error == nil; changed() } }
    var onChange: (@MainActor () -> Void)?
    var onSubmit: (@MainActor () -> Void)?

    let toggle = ToggleGroupView(items: [("Date and time", nil), ("Duration", nil)], selected: 0)
    private let dateLabel = FormLabel.make("Date")
    let dateButton = ButtonView("", variant: .outline)
    private let timeLabel = FormLabel.make("Time")
    let time = InputView()
    private let amountLabel = FormLabel.make("Snooze for")
    let amount = NumberFieldView(value: 2)
    private let unitLabel = FormLabel.make("Unit")
    let unit = SelectView(options: ["Minutes", "Hours", "Days"], selected: 1)
    private let errorText = TextBlockView()
    private var date: Date
    private var calendarPopup: OpenPopup?

    init(initial: Date) {
        date = initial
        super.init(frame: .zero)
        toggle.fillsWidth = true
        toggle.setAccessibilityLabel("Schedule type")
        toggle.onChange = { [weak self] index in
            guard let self else { return }
            // Pressing the pressed item clears Base UI's value; T3 ignores that and keeps the mode.
            guard let index else { self.toggle.selectedIndex = self.mode == .date ? 0 : 1; return }
            self.mode = index == 0 ? .date : .duration
            self.error = nil
            self.changed()
        }
        dateButton.trailingIcon = .calendar
        dateButton.justifiesBetween = true
        dateButton.iconColor = Themed.color(\.contrastMutedForeground)
        dateButton.action = { [weak self] in self?.toggleCalendar() }
        time.text = CustomSnooze.localTime(initial)
        time.setAccessibilityLabel("Time")
        time.onChange = { [weak self] _ in self?.error = nil }
        time.onSubmit = { [weak self] in self?.onSubmit?() }
        amount.range = 0 ... .infinity
        amount.setAccessibilityLabel("Snooze for")
        amount.onChange = { [weak self] _ in self?.error = nil }
        unit.setAccessibilityLabel("Unit")
        unit.onChange = { [weak self] _ in self?.error = nil }
        errorText.font = DSFont.ui(14)
        errorText.lineHeight = 20
        errorText.color = Themed.color(\.destructiveForeground)
        errorText.isHidden = true
        errorText.setAccessibilityRole(.staticText)
        for v in [toggle, dateLabel, dateButton, timeLabel, time, amountLabel, amount, unitLabel, unit, errorText] as [NSView] { addSubview(v) }
        updateDate()
        changed()
    }

    /// What Snooze resolves.
    var input: CustomSnooze {
        switch mode {
        case .date: .date(day: CustomSnooze.localDate(date), time: time.text)
        case .duration:
            .duration(amount: amount.text, unit: CustomSnooze.Unit.allCases[unit.selectedIndex ?? 1])
        }
    }

    private func updateDate() {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("yMMMd") // `{month: "short", day: "numeric", year: "numeric"}`
        dateButton.title = f.string(from: date)
    }

    private func toggleCalendar() {
        if let calendarPopup, let host = dateButton.popupHost, host.popups.contains(where: { $0 === calendarPopup }) {
            host.close(calendarPopup)
            return
        }
        let cal = Calendar.current
        let day = cal.dateComponents([.year, .month, .day], from: date)
        let todayParts = cal.dateComponents([.year, .month, .day], from: Date())
        let calendar = CalendarView(month: DateComponents(year: day.year, month: day.month), selected: day, today: todayParts)
        calendar.onSelect = { [weak self] parts in
            guard let self, let picked = cal.date(from: parts) else { return }
            // The day changes; the time field keeps its own value.
            self.date = picked
            self.updateDate()
            self.error = nil
            if let popup = self.calendarPopup { self.dateButton.popupHost?.close(popup) }
        }
        calendar.setAccessibilityLabel("Choose snooze date")
        calendarPopup = PopoverView(content: calendar).show(from: dateButton, placement: PopupPlacement(side: .bottom, align: .start, sideOffset: 4))
        calendarPopup?.onClose = { [weak calendar] in if let calendar { LabelClock.shared.cancel(calendar) } }
        refreshCalendar(calendar)
    }

    /// T3 3814 CustomSnoozeDialog.tsx:64-68. Refresh once at local midnight while the calendar is visible.
    func refreshCalendar(_ view: CalendarView, now: Date = Date()) {
        let cal = Calendar.current, start = Calendar.current.startOfDay(for: now)
        view.today = cal.dateComponents([.year, .month, .day], from: now)
        view.isDisabled = { parts in cal.date(from: parts).map { $0 < start } ?? true }
        guard let next = cal.date(byAdding: .day, value: 1, to: start) else { return }
        LabelClock.shared.schedule(view, in: next.timeIntervalSince(now)) { [weak self, weak view] in
            guard let self, let view else { return }
            refreshCalendar(view)
        }
    }

    private func changed() {
        let dateMode = mode == .date
        for v in [dateLabel, dateButton, timeLabel, time] as [NSView] { v.isHidden = !dateMode }
        for v in [amountLabel, amount, unitLabel, unit] as [NSView] { v.isHidden = dateMode }
        invalidateIntrinsicContentSize()
        needsLayout = true
        onChange?()
    }

    /// Toggle 32 (with its 2pt track), `gap-4`, the 2-column grid (label, gap, 32pt control), the error.
    private var gridHeight: CGFloat { 16 + (mode == .date ? 6 : 8) + 32 }

    override var intrinsicContentSize: NSSize {
        var h = toggle.intrinsicContentSize.height + 16 + gridHeight
        if error != nil { h += 16 + errorText.height(forWidth: max(1, bounds.width)) }
        return NSSize(width: NSView.noIntrinsicMetric, height: h)
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        toggle.frame = NSRect(x: 0, y: 0, width: w, height: toggle.intrinsicContentSize.height)
        let top = toggle.frame.maxY + 16
        let col = (w - 12) / 2 // `grid-cols-2 gap-3`
        // The Date div is `gap-1.5`; Time, Snooze for and Unit sit in a Label with `gap-2`.
        dateLabel.frame = NSRect(x: 0, y: top, width: col, height: 16)
        dateButton.frame = NSRect(x: 0, y: top + 22, width: col, height: 32)
        timeLabel.frame = NSRect(x: col + 12, y: top, width: col, height: 16)
        time.frame = NSRect(x: col + 12, y: top + 24, width: col, height: 32)
        amountLabel.frame = NSRect(x: 0, y: top, width: col, height: 16)
        amount.frame = NSRect(x: 0, y: top + 24, width: col, height: 32)
        unitLabel.frame = NSRect(x: col + 12, y: top, width: col, height: 16)
        unit.frame = NSRect(x: col + 12, y: top + 24, width: col, height: 32)
        let errorTop = top + gridHeight + 16
        errorText.frame = NSRect(x: 0, y: errorTop, width: w, height: errorText.height(forWidth: w))
    }
}
