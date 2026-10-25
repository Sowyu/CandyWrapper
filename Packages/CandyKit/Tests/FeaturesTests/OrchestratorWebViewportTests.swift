import AppKit
import Testing
import WebKit
import T3Protocol
import T3Store
@testable import Features

extension WebFrameSuites {
    @MainActor struct OrchestratorWebViewportTests {
        @MainActor final class Assets {
            var calls: [String: Int] = [:]
            func resolve(_ id: String) -> URL {
                calls[id, default: 0] += 1
                return URL(string: "http://page.invalid/\(id).html")!
            }
        }

        static func descendants(_ view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + descendants($0) }
        }

        static func cards(_ pane: OrchestratorPaneView) -> [OrchestratorHtmlCard] {
            descendants(pane).compactMap { $0 as? OrchestratorHtmlCard }.sorted { $0.frame.minY < $1.frame.minY }
        }

        static func visibleIDs(_ cards: [OrchestratorHtmlCard]) -> Set<String> {
            Set(cards.filter { card in
                guard let chat = card.superview else { return false }
                return !card.isHiddenOrHasHiddenAncestor && card.frame.intersects(chat.visibleRect)
            }.map { $0.page.attachmentId })
        }

        static func liveIDs(_ cards: [OrchestratorHtmlCard]) -> Set<String> {
            Set(cards.filter { $0.frameView.isLive }.map { $0.page.attachmentId })
        }

        static func fixture(_ assets: Assets) -> (NSWindow, OrchestratorPaneView, OrchestratorPaneState) {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let pane = OrchestratorPaneView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
            pane.webAssetURL = { id, _ in assets.resolve(id) }
            window.contentView = pane
            var state = OrchestratorPaneState()
            state.started = true
            state.connected = true
            state.environmentId = "sandbox"
            state.items = (0..<10).map {
                .html(id: "html-\($0)", page: HtmlRenderReference(attachmentId: "page-\($0)", title: "Page \($0)", height: 480))
            }
            pane.set(state)
            pane.layoutSubtreeIfNeeded()
            pane.scrollChat(toY: 0)
            pane.layoutSubtreeIfNeeded()
            return (window, pane, state)
        }

        static func report(_ height: Double, to card: OrchestratorHtmlCard) {
            card.frameView.onMessage?(.object([
                "jsonrpc": .string("2.0"), "method": .string("ui/notifications/size-changed"),
                "params": .object(["height": .number(height)])
            ]))
        }

        @Test func tenCardsLoadOnlyInTheViewportAndReloadWhenReturning() async throws {
            let assets = Assets()
            let (window, pane, _) = Self.fixture(assets)
            defer { pane.isHidden = true; window.contentView = nil }
            let cards = Self.cards(pane)
            #expect(cards.count == 10)
            let firstVisible = Self.visibleIDs(cards)
            #expect(!firstVisible.isEmpty && firstVisible.count < cards.count)
            #expect(await eventually { Self.liveIDs(cards) == firstVisible })
            #expect(Set(assets.calls.keys) == firstVisible, "offscreen cards must not even ask for signed URLs")
            #expect(assets.calls.values.allSatisfy { $0 == 1 })
            let oldPage = try #require(cards.first?.frameView.webView)
            pane.scrollChat(toY: .greatestFiniteMagnitude)
            let lastVisible = Self.visibleIDs(cards)
            #expect(!lastVisible.isEmpty && lastVisible.isDisjoint(with: firstVisible))
            #expect(await eventually { Self.liveIDs(cards) == lastVisible })
            #expect(cards.filter { firstVisible.contains($0.page.attachmentId) }.allSatisfy { !$0.frameView.isLive })
            pane.scrollChat(toY: 0)
            #expect(await eventually { Self.liveIDs(cards) == firstVisible })
            #expect(cards.first?.frameView.webView !== oldPage)
            for id in firstVisible { #expect(assets.calls[id] == 2) }
            for id in lastVisible { #expect(assets.calls[id] == 1) }
            #expect(Set(assets.calls.keys) == firstVisible.union(lastVisible))
            pane.isHidden = true
            #expect(Self.liveIDs(cards).isEmpty, "hiding the pane releases every page")
            #expect(cards.allSatisfy { $0.frameView.previewCache?.isActive == false })
        }

        @Test func unrelatedStateAndChatUpdatesKeepVisiblePages() async throws {
            let assets = Assets()
            let (window, pane, initial) = Self.fixture(assets)
            defer { pane.isHidden = true; window.contentView = nil }
            let cards = Self.cards(pane), visible = Self.visibleIDs(cards)
            #expect(await eventually { Self.liveIDs(cards) == visible })
            let web = try #require(cards.first?.frameView.webView)
            let calls = assets.calls
            var state = initial
            state.working = true
            pane.set(state)
            pane.layoutSubtreeIfNeeded()
            // Updating the name rebuilds the chat's configuration while keeping the same HTML cards.
            state.name = "Conductor"
            pane.set(state)
            pane.layoutSubtreeIfNeeded()
            #expect(Self.cards(pane).first === cards.first)
            #expect(cards.first?.frameView.webView === web)
            #expect(Self.liveIDs(cards) == visible)
            #expect(assets.calls == calls)
        }

        @Test func widthAwareReportedHeightsSurviveOlderHistoryAndDeduplicateReports() async throws {
            let assets = Assets()
            let (window, pane, initial) = Self.fixture(assets)
            defer { pane.isHidden = true; window.contentView = nil }
            let card = try #require(Self.cards(pane).first)
            #expect(await eventually { card.frameView.isLive })
            let wide = card.frameView.frame.width
            var updates = 0
            let relayout = card.onHeightChange
            card.onHeightChange = { updates += 1; relayout?() }
            Self.report(150.1, to: card)
            pane.layoutSubtreeIfNeeded()
            Self.report(150.4, to: card)
            #expect(updates == 1, "reports drawing at the same integer height do not relayout")
            #expect(card.frame.height == 150)
            pane.setFrameSize(NSSize(width: 600, height: 700))
            pane.needsLayout = true
            pane.layoutSubtreeIfNeeded()
            let narrow = card.frameView.frame.width
            #expect(narrow < wide - CGFloat(HtmlRenderHeights.bucket))
            Self.report(220, to: card)
            pane.layoutSubtreeIfNeeded()
            #expect(card.height(forWidth: narrow) == 220)
            #expect(card.height(forWidth: wide) == 150)
            var state = initial
            state.items.insert(.bubble(id: "older", fromUser: true, text: "Earlier history", first: true, last: true), at: 0)
            pane.set(state)
            pane.layoutSubtreeIfNeeded()
            let retained = try #require(Self.cards(pane).first { $0.page.attachmentId == card.page.attachmentId })
            #expect(retained === card)
            #expect(retained.frame.height == 220)
            #expect(retained.height(forWidth: wide) == 150)
            pane.setFrameSize(NSSize(width: 900, height: 700))
            pane.needsLayout = true
            pane.layoutSubtreeIfNeeded()
            #expect(retained.frameView.frame.width == wide)
            #expect(retained.frame.height == 150, "returning to the old width restores its measured height")
        }
    }
}
