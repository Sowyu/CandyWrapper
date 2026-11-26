import AppKit
import Testing
@testable import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// Redesign's Settled: a flat list of full rows with when each settled, and the "when" filter.
@MainActor
struct SidebarSettledTests {
    /// Friday 2026-10-09 12:00 UTC.
    static let now = SidebarPreview.referenceNow
    static var nowMs: Int64 { TimestampFormat.nowMs(now) }
    static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 2 // Monday
        return c
    }

    static func settled(_ id: String, _ project: String, minutesAgo: Double, settledAt: Bool = true) -> [String: Any] {
        SidebarPreview.thread(id, "Settled \(id)", project: project, kind: .read, minutesAgo: minutesAgo + 5,
                              extra: settledAt ? ["settledOverride": "settled", "settledAt": SidebarPreview.iso(minutesAgo), "branch": "main"]
                                               : ["settledOverride": "settled", "branch": "main"])
    }

    /// Two projects: demo-repo settled 30 minutes and 2 days ago, candywrapper 2 hours and 26 hours ago, plus an
    /// active thread so the list has something above Settled.
    static func snapshot() -> ShellSnapshot {
        SidebarPreview.snapshot(projects: [SidebarPreview.project("p1", "demo-repo"), SidebarPreview.project("p2", "candywrapper")], threads: [
            SidebarPreview.thread("live", "Something active", project: "p1", kind: .read, minutesAgo: 1),
            settled("a1", "p1", minutesAgo: 30),
            settled("a2", "p1", minutesAgo: 2 * 24 * 60),
            settled("b1", "p2", minutesAgo: 120),
            settled("b2", "p2", minutesAgo: 26 * 60),
        ])
    }

    static func state(dither: Bool = true, range: SettledRange = .any) -> SidebarListState {
        var s = SidebarListState()
        s.capabilities = .init(threadSettlement: true, threadSnooze: true)
        s.dither = dither
        s.settledExpanded = true
        s.settledRange = range
        return s
    }

    /// The Settled section's items after its header.
    static func settledItems(_ state: SidebarListState, snapshot: ShellSnapshot = snapshot()) -> [SidebarItem] {
        let items = SidebarListBuilder.items(snapshot: snapshot, state: state, nowMs: nowMs)
        guard let i = items.firstIndex(where: { if case .shelfHeader(.settled, _, _, _) = $0 { true } else { false } }) else { return [] }
        return Array(items[(i + 1)...])
    }

    static func outline(_ items: [SidebarItem]) -> [String] {
        items.map {
            switch $0 {
            case .projectHeader(let h): "# \(h.label) \(h.count)"
            case .row(let r): r.id.rawValue
            case .settledEmpty(let range): "empty: \(range.emptyText)"
            case .showMore(let n): "more \(n)"
            default: "?"
            }
        }
    }

    @Test func listsFlatNewestSettledFirst() {
        let items = Self.settledItems(Self.state())
        #expect(Self.outline(items) == ["a1", "b1", "b2", "a2"])
        // The main list keeps its project headers; Settled has none.
        let all = SidebarListBuilder.items(snapshot: Self.snapshot(), state: Self.state(), nowMs: Self.nowMs)
        #expect(all.contains { if case .projectHeader = $0 { true } else { false } })
        #expect(!items.contains { if case .projectHeader = $0 { true } else { false } })
    }

    @Test func rowsAreFullAndSayWhenTheySettled() throws {
        let items = Self.settledItems(Self.state())
        let rows = items.compactMap { if case .row(let r) = $0 { r } else { nil } }
        let a1 = try #require(rows.first { $0.id == "a1" })
        // Not in a section, so the row leads with its project's avatar, and the time sits in the meta line.
        #expect(a1.variant == .card && !a1.inProjectSection && a1.recedes && a1.timeInMeta)
        #expect(a1.projectTitle == "demo-repo")
        #expect(a1.timeLabel == "settled 30m ago")
        #expect(rows.first { $0.id == "b2" }?.timeLabel == "settled 1d ago")
        // Without settledAt the row shows its last activity, without the word.
        let bare = SidebarPreview.snapshot(projects: [SidebarPreview.project("p1", "demo-repo")], threads: [
            Self.settled("c1", "p1", minutesAgo: 60, settledAt: false)])
        let c1 = Self.settledItems(Self.state(), snapshot: bare).compactMap { if case .row(let r) = $0 { r } else { nil } }.first
        #expect(c1?.timeLabel.contains("settled") == false)
        #expect(c1?.timeLabel.isEmpty == false)
    }

    @Test func defaultThemesKeepTheFlatSettledList() {
        let items = Self.settledItems(Self.state(dither: false))
        #expect(Self.outline(items) == ["a1", "b1", "b2", "a2"])
        for case .row(let r) in items { #expect(r.variant == .slim && !r.inProjectSection) }
    }

    @Test func rangeBoundaries() {
        let cal = Self.utc, now = Self.nowMs
        func ms(_ iso: String) -> Int64 { TimestampFormat.nowMs(ISO8601DateFormatter().date(from: iso)!) }
        // Friday 2026-10-09 12:00 UTC; the week starts Monday the 5th, the month on the 1st.
        let cases: [(String, Set<SettledRange>)] = [
            ("2026-10-09T00:00:00Z", [.any, .today, .thisWeek, .thisMonth]),
            ("2026-10-08T23:59:59Z", [.any, .yesterday, .thisWeek, .thisMonth]),
            ("2026-10-08T00:00:00Z", [.any, .yesterday, .thisWeek, .thisMonth]),
            ("2026-10-07T23:59:59Z", [.any, .thisWeek, .thisMonth]),
            ("2026-10-05T00:00:00Z", [.any, .thisWeek, .thisMonth]),
            ("2026-10-04T23:59:59Z", [.any, .thisMonth]),
            ("2026-10-01T00:00:00Z", [.any, .thisMonth]),
            ("2026-09-30T23:59:59Z", [.any, .older]),
        ]
        for (iso, expected) in cases {
            let got = Set(SettledRange.allCases.filter { $0.contains(ms(iso), nowMs: now, calendar: cal) })
            #expect(got == expected, "\(iso)")
        }
        #expect(SettledRange.older.contains(nil, nowMs: now, calendar: cal))
        #expect(!SettledRange.today.contains(nil, nowMs: now, calendar: cal))
    }

    @Test func rangeFiltersAndSaysWhenNothingMatches() {
        SettledRange.$calendarOverride.withValue(Self.utc) {
            #expect(Self.outline(Self.settledItems(Self.state(range: .today))) == ["a1", "b1"])
            #expect(Self.outline(Self.settledItems(Self.state(range: .yesterday))) == ["b2"])
            #expect(Self.outline(Self.settledItems(Self.state(range: .older))) == ["empty: No settled threads from before this month"])
            let onlyToday = SidebarPreview.snapshot(projects: [SidebarPreview.project("p1", "demo-repo")], threads: [
                SidebarPreview.thread("live", "Something active", project: "p1", kind: .read, minutesAgo: 1),
                Self.settled("a1", "p1", minutesAgo: 30)])
            #expect(Self.outline(Self.settledItems(Self.state(range: .yesterday), snapshot: onlyToday)) == ["empty: No settled threads from yesterday"])
        }
    }

    @Test func pagesAndNeverClaimsACountItCannotShow() {
        let many = SidebarPreview.snapshot(projects: [SidebarPreview.project("p1", "demo-repo")],
                                           threads: (0..<40).map { Self.settled("s\($0)", "p1", minutesAgo: Double($0 * 10 + 5)) })
        let any = Self.outline(Self.settledItems(Self.state(), snapshot: many))
        #expect(any.filter { !$0.hasPrefix("#") && !$0.hasPrefix("more") }.count == SidebarListBuilder.settledInitialCount)
        #expect(any.last == "more \(min(40 - SidebarListBuilder.settledInitialCount, SidebarListBuilder.settledPageCount))")
    }

    /// The sidebar's Search already looks through Settled (SidebarListBuilder.searchItems), in every theme.
    @Test func searchFindsSettledThreads() {
        for dither in [true, false] {
            let items = SidebarListBuilder.searchItems(snapshot: Self.snapshot(), state: Self.state(dither: dither), query: "Settled b2",
                                                       matches: [], pending: false, highlighted: 0, nowMs: Self.nowMs)
            #expect(items.compactMap { if case .searchResult(let r) = $0 { r.id.rawValue } else { nil } } == ["b2"])
        }
    }

    @Test func pickerChoosesARangeAndShowAnyTimeClearsIt() {
        RedesignStatesTests.withRedesign(true) {
            let content = SidebarContentView()
            content.appearance = NSAppearance(named: .darkAqua)
            content.now = { Self.now }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = content
            content.frame = NSRect(x: 0, y: 0, width: 280, height: 900)
            defer { window.contentView = nil }
            content.state = Self.state()
            content.setSnapshot(Self.snapshot(), animated: false)
            content.layoutSubtreeIfNeeded(); content.list.layoutSubtreeIfNeeded()
            let header = content.list.view(forKey: "shelf:settled") as? SidebarShelfRowView
            #expect(header?.header.accessory === header?.rangeButton)
            #expect(header?.rangeButton.accessibilityValue() as? String == "Any time")
            content.toggleSettledRangePicker(header!.rangeButton)
            let picker = content.settledRangePickerView
            #expect(picker?.rows.map(\.item.label) == SettledRange.allCases.map(\.title))
            #expect(picker?.rows.first?.selected == true)
            picker?.onSelect?(.yesterday)
            #expect(content.state.settledRange == .yesterday)
            #expect(content.settledRangePickerView == nil)
            content.list.layoutSubtreeIfNeeded()
            #expect((content.list.view(forKey: "shelf:settled") as? SidebarShelfRowView)?.rangeButton.range == .yesterday)
            content.list.onShowAnyTime?()
            #expect(content.state.settledRange == .any)
        }
    }
}
