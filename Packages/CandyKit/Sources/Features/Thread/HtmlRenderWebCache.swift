import AppKit
import WebKit

/// A shown HTML chat shares WebKit's ephemeral HTTP cache and one empty host through scroll transitions.
/// Offscreen documents release their browsing contexts. Hiding the chat discards the host and shared store.
@MainActor
final class HtmlRenderWebCache {
    private(set) var isActive = false
    private var spare: ThreadWebView?
    private var clearing: ThreadWebView?
    private var cleanup: Task<Void, Never>?
    private struct Active { weak var web: ThreadWebView? }
    private var active: [Active] = []

    func clear() { discardSpare() }

    private func discardSpare() {
        cleanup?.cancel()
        cleanup = nil
        spare?.stopLoading()
        clearing?.navigationDelegate = nil
        clearing?.stopLoading()
        spare = nil
        clearing = nil
    }

    func activated(_ web: ThreadWebView) {
        active.removeAll { $0.web == nil || $0.web === web }
        active.append(Active(web: web))
        // Two visible frames already keep WebKit warm. Keeping an empty third host adds memory needlessly.
        if active.count >= 2 { discardSpare() }
    }

    func takeWebView() -> ThreadWebView? {
        guard isActive else { return nil }
        let web = spare ?? clearing
        spare = nil
        clearing = nil
        if web != nil { cleanup?.cancel(); cleanup = nil }
        return web
    }

    /// One empty host keeps WebKit warm while this pane is shown. Removing its iframe discards the page's
    /// scripts and browsing context without adding whole documents to WebKit's back-forward cache.
    func recycle(_ web: ThreadWebView, reusable: Bool = true) {
        active.removeAll { $0.web == nil || $0.web === web }
        guard isActive, reusable, active.count < 2, spare == nil, clearing == nil else { return }
        spare = web
        cleanup = Task { [weak self, weak web] in
            await Task.yield()
            guard !Task.isCancelled, let self, let web, self.spare === web else { return }
            self.spare = nil
            self.clearing = web
            web.callAsyncJavaScript("document.getElementById('f')?.remove(); return true;", arguments: [:], in: nil,
                                    in: .world(name: "t3-host")) { [weak self, weak web] result in
                guard let self, let web, self.clearing === web else { return }
                self.clearing = nil
                if case .success = result, self.isActive { self.spare = web }
            }
            self.cleanup = nil
        }
    }

    /// Keep WebKit's HTTP cache through gaps between visible rows, without keeping offscreen pages running.
    /// The last shown document lets the ephemeral store go when it hides, as the last live frame did before.
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active { ThreadWebFrameBudget.retainCache(self) }
        else { clear(); ThreadWebFrameBudget.releaseCache(self) }
    }

    isolated deinit {
        cleanup?.cancel()
        clearing?.navigationDelegate = nil
        clearing?.stopLoading()
        spare?.stopLoading()
        ThreadWebFrameBudget.releaseCache(self)
    }
}

