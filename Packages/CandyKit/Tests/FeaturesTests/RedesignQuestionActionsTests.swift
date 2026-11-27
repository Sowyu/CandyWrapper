import AppKit
import Testing
@testable import DesignSystem
@testable import Features
import T3Store

/// Redesign's question card holds Previous and Next under its choices, and the composer's footer leaves them out.
@MainActor
struct RedesignQuestionActionsTests {
    @Test func nextSitsUnderTheChoices() throws {
        let previous = ThemeRuntime.input
        var input = ThemeRuntimeInput(light: ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .light)!),
                                      dark: ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .dark)!))
        input.ditherLight = true; input.ditherDark = true
        ThemeRuntime.apply(input)
        defer { ThemeRuntime.apply(previous) }
        let panel = ComposerFidelityTests.panel(width: 844, dark: true)
        panel.setProjection(try ThreadPreview.projection(titled: ThreadPreview.markdownThread), projectTitle: "demo-repo", workspaceRoot: nil)
        panel.questionPanel.configure(PendingUserInput(requestId: "q", createdAt: nil,
            questions: [PanelsFidelityTests.purpose, PanelsFidelityTests.language], responseCapability: "live", dismissible: false), threadId: "t")
        panel.drawer = .question
        let footer = ComposerView.QuestionFooter(label: "Next question", compactLabel: "Next", enabled: true,
                                                 showsPrevious: true, responding: false, showsAttach: true)
        panel.composer.pending = .question(footer)
        panel.questionPanel.actions = footer
        panel.needsLayout = true
        panel.layoutSubtreeIfNeeded()
        let card = panel.questionPanel
        card.layoutSubtreeIfNeeded()
        let next = card.nextPill, back = card.previousButton
        #expect(!next.isHidden && !back.isHidden)
        #expect(card.bounds.contains(next.frame) && card.bounds.contains(back.frame), "\(next.frame) in \(card.bounds)")
        // Under the last choice, in the card, with Previous just before it on the same line.
        func rows(in view: NSView) -> [OptionRow] { view.subviews.flatMap { ($0 as? OptionRow).map { [$0] } ?? rows(in: $0) } }
        let rows = rows(in: card)
        let last = try #require(rows.max { $0.frame.maxY < $1.frame.maxY })
        let lastBottom = card.convert(last.frame, from: last.superview).maxY
        #expect(next.frame.minY >= lastBottom, "Next \(next.frame) under the last choice at \(lastBottom)")
        #expect(back.frame.minY == next.frame.minY && back.frame.maxX < next.frame.minX)
        // Its right edge on the choices' number keys.
        let key = card.convert(last.key.frame, from: last)
        #expect(abs(next.frame.maxX - key.maxX) <= 1, "Next \(next.frame) keys \(key)")
        // The composer's footer pill and Previous are gone, so nothing acts twice.
        #expect(panel.composer.questionPill.isHidden && panel.composer.previousFull.isHidden && panel.composer.previousCompact.isHidden)
    }
}
