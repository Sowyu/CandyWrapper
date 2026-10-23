import AppKit
import Testing
import DesignSystem
@testable import Features

/// Redesign retires the details card's workspace and git rows: the card keeps only the thread's links, and the header
/// pill grows and shrinks with the controls it shows.
@MainActor
struct DitherHeaderPillTests {
    @Test func relationsOnlyCardDropsTheWorkspaceAndGitRows() {
        let card = ThreadDetailsCardView()
        card.showsOpenIn = true
        card.scriptsRow = .add
        card.relationsOnly = true
        #expect(!card.hasRelations)
        #expect(card.preferredHeight == 2)
        let rows: [NSView] = [card.runContext, card.openIn, card.addScript, card.branch, card.gitActions, card.changes]
        let allHidden = rows.allSatisfy { $0.isHidden }
        #expect(allHidden)
        final class Count { var value = 0 }
        let changed = Count()
        card.onRelationsChange = { changed.value += 1 }
        let row = DetailsRowControl(kind: .row)
        card.pullRequestRows = [row]
        #expect(card.hasRelations)
        #expect(changed.value == 1)
        let height: CGFloat = 50 // the border, 8, a 32pt row, 8
        #expect(card.preferredHeight == height)
    }

    @Test func pillWidthFollowsItsControls() {
        let header = ThreadHeaderView()
        let pill = header.pill
        pill.cost = header.cost
        pill.toggles = header.toggles
        header.toggles.forEach { pill.addSubview($0) }
        let bare = pill.intrinsicContentSize.width
        pill.showsOpenIn = true
        pill.openIn.primary.icon = IconName.squareArrowOutUpRight.definition
        let withEditor = pill.intrinsicContentSize.width
        let expected: CGFloat = bare + 2 + pill.openIn.preferredWidth
        #expect(withEditor == expected)
        // The editor button is icon-only: 8 + 16 + 8, then the rule and the 22pt chevron.
        let editor: CGFloat = 55
        #expect(pill.openIn.preferredWidth == editor)
        pill.showsRelations = true
        #expect(pill.intrinsicContentSize.width > withEditor)
    }
}
