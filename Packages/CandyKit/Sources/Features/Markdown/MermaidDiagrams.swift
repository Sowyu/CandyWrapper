import AppKit
import WebKit

/// Mermaid diagrams in chat Markdown (MermaidDiagram.tsx). T3 bundles mermaid 11 (apps/web/package.json) and loads it
/// only once a diagram shows; so does this: the bundled script (LZMA, `Resources/mermaid.min.js.lzma`, MIT) runs in
/// one offscreen web view that exists only while diagrams render, one at a time like T3's `renderQueue`. Each result
/// is the sanitized SVG drawn to a 2x bitmap, cached by theme and source (64 entries, T3's `MAX_CACHED_RENDERS`);
/// the Markdown view draws the bitmap, so nothing web stays alive once a diagram is on screen.
@MainActor
public final class MermaidDiagrams: NSObject, WKNavigationDelegate {
    public static let shared = MermaidDiagrams()
    /// Posted on the main thread when a render finished; Markdown views re-lay out.
    public static let didRender = Notification.Name("MermaidDiagrams.didRender")

    public enum Result: Sendable {
        case rendered(CGImage, CGSize)
        case failed(message: String, retryable: Bool)
    }

    private var cache: [String: Result] = [:]
    private var order: [String] = []
    private var queue: [(key: String, source: String, dark: Bool)] = []
    private var rendering = false
    private var webView: WKWebView?
    private var ready = false
    private var idle: DispatchWorkItem?
    /// For the memory report and tests.
    public var isLive: Bool { webView != nil }

    static func key(_ source: String, dark: Bool) -> String { (dark ? "dark\n" : "light\n") + source }

    /// The finished render, or nil while it is queued (asking queues it).
    public func result(_ source: String, dark: Bool) -> Result? {
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = Self.key(source, dark: dark)
        if let hit = cache[key] {
            order.removeAll { $0 == key }
            order.append(key)
            return hit
        }
        if !queue.contains(where: { $0.key == key }) {
            queue.append((key, source, dark))
            pump()
        }
        return nil
    }

    /// Retry after a load failure: drops the cached failure.
    public func retry(_ source: String, dark: Bool) {
        cache[Self.key(source.trimmingCharacters(in: .whitespacesAndNewlines), dark: dark)] = nil
        NotificationCenter.default.post(name: Self.didRender, object: nil)
    }

    private func store(_ key: String, _ result: Result) {
        cache[key] = result
        order.append(key)
        while order.count > 64 { cache[order.removeFirst()] = nil }
        NotificationCenter.default.post(name: Self.didRender, object: nil)
    }

    private func pump() {
        idle?.cancel()
        guard !rendering else { return }
        guard let next = queue.first else { scheduleRelease(); return }
        guard ready else { start(); return }
        rendering = true
        webView?.callAsyncJavaScript(Self.renderCall, arguments: ["source": next.source, "dark": next.dark], in: nil, in: .page) { [weak self] reply in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.rendering = false
                self.queue.removeFirst()
                self.store(next.key, Self.decode(reply))
                self.pump()
            }
        }
    }

    nonisolated static func decode(_ reply: Swift.Result<Any, Error>) -> Result {
        switch reply {
        case .failure(let error): return .failed(message: error.localizedDescription, retryable: true)
        case .success(let value):
            guard let o = value as? [String: Any] else { return .failed(message: "The diagram could not be rendered.", retryable: false) }
            if let message = o["error"] as? String {
                let retryable = message.range(of: "dynamically imported module|importing a module script|failed to fetch", options: [.regularExpression, .caseInsensitive]) != nil
                return .failed(message: message, retryable: retryable)
            }
            guard let png = o["png"] as? String, let comma = png.firstIndex(of: ","),
                  let data = Data(base64Encoded: String(png[png.index(after: comma)...])),
                  let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let w = o["width"] as? Double, let h = o["height"] as? Double else {
                return .failed(message: "The diagram could not be rendered.", retryable: false)
            }
            return .rendered(image, CGSize(width: w, height: h))
        }
    }

    /// Mermaid is about 3.5 MB of script: it loads only now, into a page that can reach nothing.
    private func start() {
        guard webView == nil else { return }
        guard let url = Bundle.module.url(forResource: "mermaid.min", withExtension: "js.lzma"),
              let packed = try? Data(contentsOf: url), let script = try? (packed as NSData).decompressed(using: .lzma) as Data,
              let text = String(data: script, encoding: .utf8) else {
            let failed = queue
            queue.removeAll()
            for q in failed { store(q.key, .failed(message: "Mermaid failed to load.", retryable: true)) }
            return
        }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.addUserScript(WKUserScript(source: text, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 768), configuration: config)
        web.navigationDelegate = self
        webView = web
        web.loadHTMLString(Self.page, baseURL: URL(string: "about:blank"))
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready = true
        pump()
    }

    public func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        // The page loads once from its string; diagrams never navigate.
        decisionHandler(!ready && action.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        release()
        rendering = false
        pump()
    }

    private func scheduleRelease() {
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { if self?.queue.isEmpty == true { self?.release() } } }
        idle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    private func release() {
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        ready = false
    }

    // MARK: Page

    static let page = """
    <!doctype html><html><head><meta charset="utf-8">\
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval'; style-src 'unsafe-inline'; img-src blob: data:; font-src data:">\
    <style>body{margin:0;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif;font-size:14px}</style>\
    </head><body></body></html>
    """

    /// `renderMermaid` (MermaidDiagram.tsx:63-105) plus `sanitizeMermaidSvg` (:37-57) without DOMPurify: links,
    /// images and scripts go, so do `href`, `src` and remote `url()`; then the SVG is drawn to a 2x canvas.
    static let renderCall = """
    const id = "mermaid-diagram-" + (window.__n = (window.__n || 0) + 1);
    try {
      mermaid.initialize({
        startOnLoad: false, securityLevel: "strict", suppressErrorRendering: true,
        secure: ["secure", "securityLevel", "startOnLoad", "maxTextSize", "suppressErrorRendering", "maxEdges", "htmlLabels", "themeCSS"],
        htmlLabels: false, flowchart: { htmlLabels: false }, theme: dark ? "dark" : "default",
        fontFamily: getComputedStyle(document.body).fontFamily,
      });
      const { svg } = await mermaid.render(id, source);
      const doc = new DOMParser().parseFromString(svg, "image/svg+xml");
      const remote = /url\\(\\s*(?!['"]?#)[^)]*\\)/gi;
      for (const bad of doc.querySelectorAll("a, img, image, script, foreignObject")) bad.remove();
      for (const el of doc.querySelectorAll("*")) {
        for (const name of ["href", "xlink:href", "src", "srcset"]) el.removeAttribute(name);
        const style = el.getAttribute("style");
        if (style) el.setAttribute("style", style.replace(remote, "none"));
        if (el.tagName.toLowerCase() === "style") el.textContent = el.textContent.replace(remote, "none");
      }
      const root = doc.documentElement;
      const box = (root.getAttribute("viewBox") || "").trim().split(/\\s+/).map(Number);
      const width = box.length === 4 && box.every(Number.isFinite) ? box[2] : parseFloat(root.getAttribute("width")) || 600;
      const height = box.length === 4 && box.every(Number.isFinite) ? box[3] : parseFloat(root.getAttribute("height")) || 400;
      root.setAttribute("width", String(width));
      root.setAttribute("height", String(height));
      root.setAttribute("xmlns", "http://www.w3.org/2000/svg");
      root.style.maxWidth = "none";
      const url = URL.createObjectURL(new Blob([new XMLSerializer().serializeToString(root)], { type: "image/svg+xml" }));
      try {
        const image = new Image();
        await new Promise((resolve, reject) => { image.onload = resolve; image.onerror = () => reject(new Error("The diagram could not be rendered.")); image.src = url; });
        const canvas = document.createElement("canvas");
        canvas.width = Math.ceil(width * 2);
        canvas.height = Math.ceil(height * 2);
        const context = canvas.getContext("2d");
        context.scale(2, 2);
        context.drawImage(image, 0, 0, width, height);
        return { png: canvas.toDataURL("image/png"), width, height };
      } finally { URL.revokeObjectURL(url); }
    } catch (error) {
      return { error: (error && error.message) || "The diagram could not be rendered." };
    } finally {
      document.getElementById("d" + id)?.remove();
    }
    """
}
