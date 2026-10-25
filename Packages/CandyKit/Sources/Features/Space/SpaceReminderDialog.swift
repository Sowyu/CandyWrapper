import AppKit
import DesignSystem
import SpaceModel

/// Remind me… for a date value, shared by the page's to-do date menu and the Table's date cell. The choices follow
/// docs/space.md section 2, `remind`: `before` counts back from a timed value's start, and from 9:00 on a date-only
/// value's day; a set time is `at` on the start day.
@MainActor
enum SpaceReminderDialog {
    struct Choice: Equatable {
        let label: String
        /// Nil for "At a set time…", which asks for the time.
        let remind: Reminder?
    }

    static func choices(_ due: DateValue) -> [Choice] {
        let custom = Choice(label: "At a set time…", remind: nil)
        guard due.start.isTimed else {
            return [Choice(label: "On the day, at 9:00", remind: .before(0)),
                    Choice(label: "1 day before, at 9:00", remind: .before(24 * 60)), custom]
        }
        return [Choice(label: "At time", remind: .before(0)), Choice(label: "15 minutes before", remind: .before(15)),
                Choice(label: "1 hour before", remind: .before(60)), Choice(label: "1 day before", remind: .before(24 * 60)), custom]
    }

    /// The reminder as the date menu names it, like "15 minutes before" or "At 07:05", or nil when none is set.
    static func label(_ due: DateValue) -> String? {
        guard let remind = due.remind else { return nil }
        if case .at = remind { return "At " + SpacePageEditor.reminderTimeText(due) }
        if let choice = choices(due).first(where: { $0.remind == remind }) { return choice.label }
        if case .before(let minutes) = remind { return "\(minutes) minutes before" }
        return "Set"
    }

    /// Remind me… or the current reminder, then Remove reminder when one is set, for a date menu.
    static func menuItems(_ due: DateValue, open: @escaping @MainActor () -> Void, set: @escaping @MainActor (DateValue) -> Void) -> [MenuItem] {
        let current = label(due)
        var items = [MenuItem(current.map { "Reminder: \($0)…" } ?? "Remind me…", icon: .alarmClock) {
            // Open after the menu's own click finishes, so the dialog gets the next click.
            DispatchQueue.main.async { open() }
        }]
        if current != nil {
            items.append(MenuItem("Remove reminder", icon: .alarmClockOff) {
                var cleared = due
                cleared.remind = nil
                set(cleared)
            })
        }
        return items
    }

    /// Asks which reminder to set. `current` reads the value again on Save, so an edit made meanwhile isn't lost.
    @discardableResult
    static func present(in window: NSWindow, due: DateValue, current: @escaping @MainActor () -> DateValue?,
                        save: @escaping @MainActor (DateValue) -> Void) -> ModalHost {
        let options = choices(due)
        let day = SpacePageEditor.dueDayText(due) + (due.start.isTimed ? " at " + String(due.start.rawValue.suffix(5)) : "")
        let dialog = DialogView(title: "Reminder", message: "Due \(day).")
        dialog.maxWidth = 384
        let initial = options.firstIndex { $0.remind != nil && $0.remind == due.remind } ?? (due.remind.map { _ in options.count - 1 } ?? 0)
        let select = SelectView(options: options.map(\.label), selected: initial)
        select.setAccessibilityLabel("Remind me")
        let time = InputView(placeholder: "HH:MM", text: SpacePageEditor.reminderTimeText(due))
        time.setAccessibilityLabel("Time")
        let error = TextBlockView()
        error.font = DSFont.ui(14)
        error.lineHeight = 20
        error.color = Themed.color(\.destructiveForeground)
        error.text = "Enter a time like 09:30."
        func show(_ index: Int, error shown: Bool = false) {
            dialog.panelContent = options[index].remind == nil ? [select, time] + (shown ? [error] : []) : [select]
        }
        show(initial)
        let cancel = ButtonView("Cancel", variant: .outline)
        let saveButton = ButtonView("Save")
        dialog.footerButtons = [cancel, saveButton]
        let host = ModalHost.present(dialog, in: window)
        let close: @MainActor () -> Void = { [weak host] in host?.close() }
        dialog.onClose = close
        cancel.action = close
        select.onChange = { index in
            show(index)
            if options[index].remind == nil { DispatchQueue.main.async { [weak time] in _ = time?.becomeFirstResponder() } }
        }
        let submit: @MainActor () -> Void = { [weak select, weak time] in
            guard let select, let index = select.selectedIndex, var next = current() else { return }
            if let remind = options[index].remind {
                next.remind = remind
            } else {
                guard let time, let timed = SpacePageEditor.withReminder(next, time: time.text) else { show(index, error: true); return }
                next = timed
            }
            close()
            save(next)
        }
        saveButton.action = submit
        time.onSubmit = submit
        time.onChange = { _ in if let index = select.selectedIndex, dialog.panelContent.count > 2 { show(index) } }
        // The time field and the error leave the panel while a fixed choice shows, so the closures hold them, and with
        // them the dialog. Every way out of the dialog ends here, which lets them all go.
        host.onDismiss = {
            select.onChange = nil
            time.onChange = nil
            time.onSubmit = nil
            saveButton.action = nil
        }
        return host
    }
}
