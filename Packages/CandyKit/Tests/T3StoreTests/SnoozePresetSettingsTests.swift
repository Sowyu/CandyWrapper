import Foundation
import Testing
import T3Protocol
@testable import T3Store

struct SnoozePresetSettingsTests {
    var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    let now = Date(timeIntervalSince1970: 1_791_367_200)
    @Test func validatesBoundsAndAllowsAnEmptyMenu() {
        #expect(SnoozePresetSetting.decode(.array([])).isEmpty)
        #expect(SnoozePresetSetting(.object(["kind": .string("after"), "minutes": .number(0)])) == nil)
        #expect(SnoozePresetSetting(.object(["kind": .string("at"), "day": .string("today"), "time": .string("24:00")])) == nil)
        #expect(SnoozePresetSetting(.object(["kind": .string("at"), "day": .string("today"), "time": .string("0١:00")])) == nil)
        #expect(SnoozePresetSetting.decode(.array(Array(repeating: SnoozePresetSetting.after(minutes: 1).json, count: 9))) == SnoozePresetSetting.defaults)
    }
    @Test func menuSortsAndDeduplicatesByMinute() {
        let values: [SnoozePresetSetting] = [.after(minutes: 180), .at(day: "today", time: "11:00"), .after(minutes: 60), .after(minutes: 15)]
        let rows = SnoozePresets.resolve(now: now.addingTimeInterval(20), calendar: calendar, presets: values)
        #expect(rows.map(\.id) == ["after:15", "at:today:11:00", "after:180"])
        #expect(SnoozePresets.resolve(now: now, presets: []).isEmpty)
    }
    @Test func pickingRecomputesDurationsButNeverMovesAnAbsoluteDate() throws {
        let settings: [SnoozePresetSetting] = [.after(minutes: 60), .at(day: "today", time: "11:00")]
        let shown = SnoozePresets.resolve(now: now, calendar: calendar, presets: settings)
        let later = now.addingTimeInterval(90 * 60)
        let picked = try #require(SnoozePresets.pick(shown: shown, id: "after:60", now: later, presets: settings, calendar: calendar))
        #expect(picked.snoozedUntil == later.addingTimeInterval(3600))
        // The absolute entry tied with the duration at menu open, so use its own resolution.
        let absolute = try #require(SnoozePresets.resolve(settings[1], now: now, calendar: calendar))
        #expect(SnoozePresets.pick(shown: [absolute], id: absolute.id, now: later, presets: settings, calendar: calendar) == nil)
        #expect(SnoozePresets.pick(shown: [absolute], id: absolute.id, now: now.addingTimeInterval(60), presets: settings, calendar: calendar)?.snoozedUntil == absolute.snoozedUntil)
    }
    @Test func aSkippedLocalHourKeepsTheChosenMinuteLikeJSSetHours() throws {
        var local = calendar; local.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let midnight = try #require(local.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 0, minute: 30)))
        let choice = try #require(SnoozePresets.resolve(.at(day: "today", time: "02:30"), now: midnight, calendar: local))
        #expect(local.component(.hour, from: choice.snoozedUntil) == 3)
        #expect(local.component(.minute, from: choice.snoozedUntil) == 30)
    }

    @Test func localDaysCrossDaylightSavingWithTheChosenClockTime() throws {
        var local = calendar; local.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let saturday = try #require(local.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 23, minute: 30)))
        let choice = try #require(SnoozePresets.resolve(.at(day: "tomorrow", time: "09:00"), now: saturday, calendar: local))
        #expect(local.component(.day, from: choice.snoozedUntil) == 8)
        #expect(local.component(.hour, from: choice.snoozedUntil) == 9)
    }
}
