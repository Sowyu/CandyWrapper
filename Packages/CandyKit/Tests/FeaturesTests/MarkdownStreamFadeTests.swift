import AppKit
import Testing
import DesignSystem
@testable import Features

/// The streaming fade (index.css:2007-2020): only blocks added while streaming get a band, each band
/// starts at its block's top, and a recycled view drops the fade.
@MainActor
struct MarkdownStreamFadeTests {
    @Test func fadesOnlyBlocksAddedWhileStreaming() throws {
        try #require(!Motion.reduced)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = MarkdownView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        window.contentView = view
        defer { window.contentView = nil }

        view.setMarkdown("One.")
        #expect(view.fadeMask == nil) // not streaming: history never fades

        view.fadesNewBlocks = true
        view.setMarkdown("One.\n\nTwo.\n\nThree.")
        view.layoutSubtreeIfNeeded()
        #expect(view.fadeBands.map(\.block) == [1, 2])
        let tops = view.layout(forWidth: 600).blockTops
        #expect(zip(view.fadeBands.map(\.layer.frame.minY), [tops[1], tops[2]]).allSatisfy { abs($0 - $1) < 0.01 })
        #expect(view.fadeBands.allSatisfy { $0.layer.animation(forKey: "opacity") != nil })

        view.setMarkdown("One.\n\nTwo.\n\nThree, longer.") // growth inside the last block adds no band
        #expect(view.fadeBands.count == 2)

        view.cancelBlockFades()
        #expect(view.fadeMask == nil && view.layer?.mask == nil)
    }
}
