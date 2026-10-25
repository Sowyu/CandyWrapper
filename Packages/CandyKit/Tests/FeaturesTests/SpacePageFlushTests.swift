import AppKit
import Foundation
import SpaceModel
import Testing
@testable import Features

/// Typing still waiting for its 400 ms flush goes in before the page view leaves, so switching away or turning
/// Space off right after a keystroke keeps it.
@MainActor
struct SpacePageFlushTests {
    func make() -> (SpacePageView, SpaceReplicaStore, PageID, NSWindow) {
        let store = SpaceReplicaStore(label: "Test Mac")
        let page = store.createPage(title: "Notes", now: 1)
        let view = SpacePageView(store: store)
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(view)
        view.show(page)
        return (view, store, page, window)
    }

    func type(_ view: SpacePageView, _ text: String) {
        let tv = view.editor!.textView
        for c in text { tv.insertText(String(c), replacementRange: tv.selectedRange()) }
    }

    func text(_ store: SpaceReplicaStore, _ page: PageID) -> [String] {
        store.content(of: page).compactMap { if case .block(_, let r) = $0 { r.text.t } else { nil } }
    }

    @Test func leavingTheWindowSendsWaitingTyping() {
        let (view, store, page, window) = make()
        type(view, "Buy milk")
        #expect(text(store, page).isEmpty, "typing waits for the 400 ms flush")
        view.removeFromSuperview()
        #expect(text(store, page) == ["Buy milk"])
        window.close()
    }

    @Test func anotherPageSendsWaitingTyping() {
        let (view, store, page, window) = make()
        let other = store.createPage(title: "Other", now: 2)
        type(view, "First")
        view.show(other)
        #expect(text(store, page) == ["First"])
        window.close()
    }

    @Test func aViewChangeFromElsewhereSendsWaitingTyping() {
        let (view, store, page, window) = make()
        type(view, "Before board")
        // The page record alone changes, as another window's view switch would, so the editor itself doesn't reload.
        var record = store.pages[page]!
        record.view = .board
        store.put([page: record])
        #expect(view.editor == nil)
        #expect(text(store, page) == ["Before board"])
        window.close()
    }
}
