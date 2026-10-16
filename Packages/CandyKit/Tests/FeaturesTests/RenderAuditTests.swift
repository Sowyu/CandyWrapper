import AppKit
import DesignSystem
import Testing
import T3Store
@testable import Features

@MainActor
struct RenderAuditTests {
    @Test func backgroundThemePreviewMatchesTheSynchronousPixels() async throws {
        let colors: [ThemeColorRole: String] = [.canvas: "#fafafa", .accent: "#7565da", .messageAction: "#263346"]
        let expected = try #require(ThemePreviewCircleView.render(colors: colors, mode: .light, scale: 2))
        let actual = try #require(await Task.detached {
            ThemePreviewCircleView.render(colors: colors, mode: .light, scale: 2)
        }.value)
        #expect(actual.width == expected.width)
        #expect((actual.dataProvider?.data as Data?) == (expected.dataProvider?.data as Data?))
    }

    @Test func appearanceLoadsFontsWithoutBlockingPageConstruction() async throws {
        let page = AppearanceSettingsView(context: SettingsPageContext())
        let row = try #require(page.anchor("interface-font") as? SettingsRowView)
        let picker = try #require(row.control?.subviews.compactMap { $0 as? ComboboxView }.first)
        // The page exists before the main actor receives the detached discovery's result.
        #expect(picker.options.isEmpty)
        picker.setValue("Menlo")
        let deadline = ContinuousClock.now + .seconds(5)
        while picker.options.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(picker.options.contains("Menlo"))
        #expect(picker.selectedIndex == picker.options.firstIndex(of: "Menlo"))
        #expect(picker.input.text == "Menlo")
    }

    @Test func resizingReleasesOldMarkdownLayouts() {
        let view = MarkdownView(frame: .zero)
        view.setMarkdown(MarkdownIncrementalTests.answer)
        weak var first = view.layout(forWidth: 400)
        for width in 401...460 { _ = view.layout(forWidth: CGFloat(width)) }
        #expect(first == nil)
        let recent = view.layout(forWidth: 459)
        _ = view.layout(forWidth: 461)
        #expect(view.layout(forWidth: 459) === recent)
        let fresh = MarkdownView(frame: .zero)
        fresh.document = view.document
        #expect(view.height(forWidth: 400) == fresh.height(forWidth: 400))
    }

    @Test func reusedReasoningFollowsTheNewThought() throws {
        let view = ReasoningTraceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let context = TimelineContext()
        func item(_ id: String, lines: Int = 40) -> ReasoningTraceView.Item {
            ReasoningTraceView.Item(WorkLogEntry(id: id, createdAt: "2026-10-16T00:00:00Z",
                label: "Thinking", detail: (1...lines).map { "Thought line \($0)" }.joined(separator: "\n"),
                tone: .thinking, toolLifecycleStatus: .inProgress))
        }
        view.set([item("first")], context: context)
        view.layoutSubtreeIfNeeded()
        let area = try #require(view.subviews.first as? ScrollAreaView)
        let scroll = area.scrollView
        let document = try #require(scroll.documentView)
        #expect(scroll.contentView.bounds.maxY >= document.frame.height - 4)
        area.scroll(to: .zero)
        view.set([item("first", lines: 42)], context: context)
        view.layoutSubtreeIfNeeded()
        #expect(scroll.contentView.bounds.minY == 0)
        view.set([item("second")], context: context)
        view.layoutSubtreeIfNeeded()
        #expect(scroll.contentView.bounds.maxY >= document.frame.height - 4)
    }
}
