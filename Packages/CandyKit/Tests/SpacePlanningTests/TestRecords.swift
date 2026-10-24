import Foundation
import SpaceModel
import SpacePlanning

func id(_ number: Int) -> SpaceID {
    try! SpaceID(String(format: "00000000-0000-4000-8000-%012d", number))
}

func page(_ title: String, parent: Int? = nil, trashed: Bool = false,
          props: [String: PropertyValue] = [:]) -> PageRecord {
    PageRecord(parent: parent.map(id), order: try! OrderKey("a0"), title: title,
               props: props, trashed: trashed, created: 0)
}

func block(_ text: String, page: Int = 1, order: String = "a0", trashed: Bool = false) -> BlockRecord {
    BlockRecord(page: id(page), order: try! OrderKey(order), text: RichText(t: text), trashed: trashed)
}

func zone(_ name: String) -> TimeZone { TimeZone(identifier: name)! }
func instant(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
func dateValue(_ start: String, tz: String? = nil, weekly: Bool = false,
               reminder: Reminder = .before(0)) throws -> DateValue {
    try DateValue(start: DatePoint(start), tz: tz, repeat: weekly ? .weekly : nil, remind: reminder)
}

func plan(_ value: DateValue, now: String = "2026-10-01T00:00:00Z", device: String = "Etc/UTC") throws -> [PlannedReminder] {
    try ReminderPlanner.plan(pages: [id(1): page("Tasks"), id(2): page("Buy milk", parent: 1, props: ["due": .date(value)])],
                             now: instant(now), deviceTimeZone: zone(device))
}
