import Testing
import DesignSystem
import T3Protocol
@testable import Features

@MainActor
struct SettingsBindingPerformanceTests {
    @Test func unrelatedSettingsSkipControlUpdates() {
        let context = SettingsPageContext()
        let binder = SettingsBinder()
        var wrapUpdates = 0, widthUpdates = 0
        binder.add(read: { context.client.bool("wordWrap") }) { _ in wrapUpdates += 1 }
        binder.add(read: { context.client.string("chatWidth") }) { _ in widthUpdates += 1 }
        for _ in 0..<5 { binder.refresh() }
        #expect(wrapUpdates == 1)
        #expect(widthUpdates == 1)
        _ = context.client.apply(["wordWrap": .bool(!context.client.bool("wordWrap"))])
        binder.refresh()
        #expect(wrapUpdates == 2)
        #expect(widthUpdates == 1)
        _ = context.client.apply(["chatWidth": .string("wide")])
        binder.refresh()
        #expect(wrapUpdates == 2)
        #expect(widthUpdates == 2)
    }

    @Test func clientSelectTracksItsSetting() throws {
        let context = SettingsPageContext()
        let page = SettingsPageBase(context: context)
        let row = page.clientSelect("chat-width", nil, key: "chatWidth",
                                    options: [("comfortable", "Comfortable"), ("wide", "Wide")], width: 160)
        let select = try #require(row.control as? SelectView)
        #expect(select.selectedIndex == 0)
        _ = context.client.apply(["wordWrap": .bool(!context.client.bool("wordWrap"))])
        page.refresh()
        #expect(select.selectedIndex == 0)
        _ = context.client.apply(["chatWidth": .string("wide")])
        page.refresh()
        #expect(select.selectedIndex == 1)
    }
}
