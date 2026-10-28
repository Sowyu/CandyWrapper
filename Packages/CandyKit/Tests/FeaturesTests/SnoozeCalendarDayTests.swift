import AppKit
import Testing
import DesignSystem
@testable import Features

@MainActor
struct SnoozeCalendarDayTests {
    @Test func aCalendarKeptOpenNoLongerAllowsYesterdayAfterMidnight() throws {
        let cal = Calendar.current
        let day = cal.startOfDay(for: Date())
        let tomorrow = try #require(cal.date(byAdding: .day, value: 1, to: day))
        let today = cal.dateComponents([.year, .month, .day], from: day)
        let form = SidebarCustomSnoozeForm(initial: day)
        let view = CalendarView(month: today)
        defer { LabelClock.shared.cancel(view) }
        form.refreshCalendar(view, now: tomorrow.addingTimeInterval(-1))
        #expect(view.isDisabled?(today) == false)
        form.refreshCalendar(view, now: tomorrow)
        #expect(view.isDisabled?(today) == true)
        #expect(view.isDisabled?(cal.dateComponents([.year, .month, .day], from: tomorrow)) == false)
        #expect(view.today.day == cal.component(.day, from: tomorrow))
    }
}
