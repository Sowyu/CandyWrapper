import AppKit
import DesignSystem
import WebKit

/// Mermaid diagrams in chat Markdown (MermaidDiagram.tsx). Since fcb20e49aa T3 renders them with pele 1.8.0
/// (apps/web/package.json) and loads it only once a diagram shows; so does this: the bundled build (LZMA,
/// `Resources/pele.global.js.lzma`, MIT, `scripts/fetch-pele`) runs in one offscreen web view that exists only while
/// diagrams render, one at a time. Each result is the sanitized SVG in the app's colors, drawn to a 2x bitmap and
/// cached by colors, width and source (64 entries); the Markdown view draws the bitmap, so nothing web stays alive
/// once a diagram is on screen.
@MainActor
public final class MermaidDiagrams: NSObject, WKNavigationDelegate {
    public static let shared = MermaidDiagrams()
    /// Posted on the main thread when a render finished; Markdown views re-lay out.
    public static let didRender = Notification.Name("MermaidDiagrams.didRender")

    public enum Result: Sendable {
        case rendered(CGImage, CGSize)
        case failed(message: String, retryable: Bool)
    }

    /// What pele reads from CSS: the `.pele` color variables (index.css:1734-1744) and the font.
    public struct Palette: Hashable, Sendable {
        public var css: String
        public var font: String
        public init(css: String, font: String) { self.css = css; self.font = font }

        /// The `.pele` rule in an appearance: `--pele-bg` is `--background`, `--pele-border` the foreground at 28%, and so on.
        @MainActor public static func current(dark: Bool) -> Palette {
            var css = ""
            NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
                func rgb(_ c: NSColor) -> String {
                    let s = c.usingColorSpace(.sRGB) ?? c
                    func v(_ x: CGFloat) -> String { String(Int((min(max(x, 0), 1) * 255).rounded())) }
                    return "rgb(\(v(s.redComponent)) \(v(s.greenComponent)) \(v(s.blueComponent)) / \(String(format: "%.3f", s.alphaComponent)))"
                }
                let vars: [(String, NSColor)] = [
                    ("bg", Themed.color(\.background)), ("fg", Themed.color(\.foreground)), ("muted", Themed.color(\.mutedForeground)),
                    ("line", Themed.color(\.mutedForeground)), ("surface", Themed.color(\.secondary)), ("surface-alt", Themed.color(\.accent)),
                    ("border", Themed.color(\.foreground, 0.28)), ("accent", Themed.color(\.primary)), ("critical", Themed.color(\.destructive)),
                ]
                css = vars.map { "--pele-\($0.0):\(rgb($0.1))" }.joined(separator: ";")
            }
            // The chat's font, which pele measures labels in. A font only this app registered falls back to the system's.
            let family = DSFont.ui(14).familyName ?? ""
            let font = (family.isEmpty || family.hasPrefix(".") ? "" : "\"\(family)\", ") + "-apple-system, system-ui, sans-serif"
            return Palette(css: css, font: font)
        }
    }

    private var cache: [String: Result] = [:]
    private var order: [String] = []
    /// Per source and palette: the diagram's natural width, and whether a narrower column lays it out again
    /// (`adapts`, pele's mount); a diagram that fits or never adapts renders once for every width.
    private var naturals: [String: (width: CGFloat, adapts: Bool)] = [:]
    /// Per source and palette, the last key rendered, shown while another width renders.
    private var latest: [String: String] = [:]
    private var queue: [(base: String, key: String, source: String, palette: Palette, width: CGFloat)] = []
    private var rendering = false
    private var webView: WKWebView?
    private var ready = false
    /// The page finished loading (the script runs after that).
    private var pageLoaded = false
    /// The unpacked script between its background load and its run: `.some(nil)` when it failed.
    private var script: String??
    private var idle: DispatchWorkItem?
    /// For the memory report and tests.
    public var isLive: Bool { webView != nil }

    static func base(_ source: String, _ palette: Palette) -> String { palette.css + "\n" + palette.font + "\n" + source }

    private func key(base: String, width: CGFloat) -> String {
        let w = max(0, width.rounded(.down))
        if let natural = naturals[base], !natural.adapts || w >= natural.width { return base + "\nn" }
        return base + "\n" + String(Int(w))
    }

    /// The render for `width`, or nil while the first one is queued (asking queues it). While another
    /// width renders, the last render of the same diagram stands in.
    public func result(_ source: String, palette: Palette, width: CGFloat) -> Result? {
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = Self.base(source, palette)
        let key = key(base: base, width: width)
        if let hit = cache[key] {
            order.removeAll { $0 == key }
            order.append(key)
            return hit
        }
        if let i = queue.indices.last(where: { queue[$0].base == base }), !(rendering && i == 0) {
            queue[i] = (base, key, source, palette, width) // only the newest width of a queued diagram renders
        } else if !queue.contains(where: { $0.key == key }) {
            queue.append((base, key, source, palette, width))
        }
        pump()
        return latest[base].flatMap { cache[$0] }
    }

    /// Retry after a load failure: drops the diagram's cached renders.
    public func retry(_ source: String, palette: Palette) {
        let base = Self.base(source.trimmingCharacters(in: .whitespacesAndNewlines), palette)
        for key in cache.keys where Self.base(ofKey: key) == base { cache[key] = nil }
        order.removeAll { Self.base(ofKey: $0) == base }
        latest[base] = nil
        naturals[base] = nil
        NotificationCenter.default.post(name: Self.didRender, object: nil)
    }

    func store(_ next: (base: String, key: String, source: String, palette: Palette, width: CGFloat), _ result: Result, natural: (CGFloat, Bool)?) {
        if let natural { naturals[next.base] = natural }
        let key = natural == nil ? next.key : self.key(base: next.base, width: next.width)
        cache[key] = result
        order.removeAll { $0 == key }
        order.append(key)
        latest[next.base] = key
        while order.count > 64 { evict(order.removeFirst()) }
        NotificationCenter.default.post(name: Self.didRender, object: nil)
    }

    /// Drops a render, and the diagram's natural size and stand-in once its last render goes.
    private func evict(_ key: String) {
        cache[key] = nil
        let base = Self.base(ofKey: key)
        guard !order.contains(where: { Self.base(ofKey: $0) == base }) else { return }
        naturals[base] = nil
        latest[base] = nil
    }

    /// A key is the base, a newline and a width or `n`; the base holds newlines, the suffix none.
    static func base(ofKey key: String) -> String { key.lastIndex(of: "\n").map { String(key[..<$0]) } ?? key }

    /// For tests: diagrams with a natural size or a stand-in on record.
    var metadataCount: (naturals: Int, latest: Int) { (naturals.count, latest.count) }

    private func pump() {
        idle?.cancel()
        guard !rendering else { return }
        guard let next = queue.first else { scheduleRelease(); return }
        guard ready else { start(); return }
        rendering = true
        webView?.callAsyncJavaScript(Self.renderCall, arguments: ["source": next.source, "vars": next.palette.css, "font": next.palette.font,
                                                                  "width": Double(next.width)], in: nil, in: .page) { [weak self] reply in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.rendering = false
                self.queue.removeFirst()
                let (result, natural) = Self.decode(reply)
                self.store(next, result, natural: natural)
                self.pump()
            }
        }
    }

    nonisolated static func decode(_ reply: Swift.Result<Any, Error>) -> (Result, (CGFloat, Bool)?) {
        let failed = Result.failed(message: "The diagram could not be rendered.", retryable: false)
        switch reply {
        case .failure(let error): return (.failed(message: error.localizedDescription, retryable: true), nil)
        case .success(let value):
            guard let o = value as? [String: Any] else { return (failed, nil) }
            if let message = o["error"] as? String { return (.failed(message: message, retryable: o["retryable"] as? Bool ?? false), nil) }
            guard let png = o["png"] as? String, let comma = png.firstIndex(of: ","),
                  let data = Data(base64Encoded: String(png[png.index(after: comma)...])),
                  let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let w = o["width"] as? Double, let h = o["height"] as? Double else { return (failed, nil) }
            let natural = (o["natural"] as? Double).map { (CGFloat($0), o["adapts"] as? Bool ?? false) }
            return (.rendered(image, CGSize(width: w, height: h)), natural)
        }
    }

    /// The page and its web content process start at once while a background task reads and unpacks the
    /// script; the script runs once both are there, so the main thread never decompresses it.
    private func start() {
        guard webView == nil else { return }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 768), configuration: config)
        web.navigationDelegate = self
        webView = web
        pageLoaded = false
        script = nil
        Task { [weak self] in
            let text = await Task.detached(priority: .userInitiated) { Self.loadScript() }.value
            guard let self, self.webView === web else { return }
            self.script = .some(text)
            self.injectIfReady()
        }
        web.loadHTMLString(Self.page, baseURL: URL(string: "about:blank"))
    }

    /// The bundled script, unpacked; nil when it is missing or damaged. Runs off the main thread.
    nonisolated static func loadScript() -> String? {
        guard let url = Bundle.module.url(forResource: "pele.global", withExtension: "js.lzma"),
              let packed = try? Data(contentsOf: url), let script = try? (packed as NSData).decompressed(using: .lzma) as Data,
              let text = NSMutableString(data: script, encoding: String.Encoding.utf8.rawValue) else { return nil }
        // `;0` gives the evaluation a result WebKit can return. The string stays an NSString, so
        // WebKit reads it on the main thread without transcoding a Swift string.
        text.append("\n;0")
        return text as String
    }

    /// Runs the script once the page has loaded and the script is unpacked, whichever comes last.
    private func injectIfReady() {
        guard pageLoaded, let pending = script, let web = webView else { return }
        script = nil
        guard let text = pending else {
            release()
            let failed = queue
            queue.removeAll()
            // MermaidDiagram.tsx:257-268: a renderer that failed to load offers Retry.
            for q in failed { store(q, .failed(message: "The diagram renderer failed to load.", retryable: true), natural: nil) }
            return
        }
        web.evaluateJavaScript(text) { [weak self, weak web] _, _ in
            MainActor.assumeIsolated {
                guard let self, let web, self.webView === web else { return }
                self.ready = true
                self.pump()
            }
        }
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageLoaded = true
        injectIfReady()
    }

    public func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        // The page loads once from its string; diagrams never navigate.
        decisionHandler(!pageLoaded && action.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
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
        pageLoaded = false
        script = nil
    }

    // MARK: Page

    static let page = """
    <!doctype html><html><head><meta charset="utf-8">\
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval'; style-src 'unsafe-inline'; img-src blob: data:; font-src data:">\
    <style>body{margin:0;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif;font-size:14px}</style>\
    </head><body></body></html>
    """

    /// What pele's `mount` does for one width (MermaidDiagram.tsx:238-255 with pele's mount): the natural render, and
    /// when the column is narrower and the diagram lays out differently at `maxWidth: 1`, a render at the column's width.
    /// Then `sanitizeDiagramSvg` (:159-167) without DOMPurify: links, images, scripts, styles and foreign objects go, so
    /// do `href`, `src`, `srcset` and event handlers. The SVG gets the color variables inline, as `diagramImageUrl`
    /// (:206-220) does, and is drawn to a 2x canvas.
    // ponytail: no KaTeX, so `$$...$$` labels show their TeX; load KaTeX here if math rendering is ported.
    static let renderCall = """
    if (typeof pele === "undefined") return { error: "The diagram renderer failed to load.", retryable: true };
    try {
      const options = { links: false, images: false, autoDirection: false, fontFamily: font,
                        idPrefix: "pele-" + (window.__n = (window.__n || 0) + 1) };
      const natural = pele.render(source, options);
      let result = natural, adapts = false;
      if (width > 0 && width < natural.width) {
        adapts = pele.render(source, { ...options, maxWidth: 1 }).svg !== natural.svg;
        if (adapts) result = pele.render(source, { ...options, maxWidth: width });
      }
      const doc = new DOMParser().parseFromString(result.svg, "image/svg+xml");
      const root = doc.documentElement;
      if (root.localName !== "svg") throw new Error("The diagram could not be rendered.");
      for (const link of [...doc.querySelectorAll("a")]) link.replaceWith(...link.childNodes);
      for (const bad of doc.querySelectorAll("image, img, script, style, foreignObject, iframe")) bad.remove();
      for (const el of doc.querySelectorAll("*")) {
        for (const attr of [...el.attributes]) {
          const name = attr.name.toLowerCase();
          if (name === "href" || name === "xlink:href" || name === "src" || name === "srcset" || name.startsWith("on")) el.removeAttribute(attr.name);
        }
      }
      root.setAttribute("xmlns", "http://www.w3.org/2000/svg");
      root.setAttribute("width", String(result.width));
      root.setAttribute("height", String(result.height));
      root.setAttribute("style", vars + ";--pele-font:" + font + ";" + (root.getAttribute("style") || "") + ";max-width:none");
      const url = URL.createObjectURL(new Blob([new XMLSerializer().serializeToString(root)], { type: "image/svg+xml" }));
      try {
        const image = new Image();
        await new Promise((resolve, reject) => { image.onload = resolve; image.onerror = () => reject(new Error("The diagram could not be rendered.")); image.src = url; });
        const canvas = document.createElement("canvas");
        canvas.width = Math.ceil(result.width * 2);
        canvas.height = Math.ceil(result.height * 2);
        const context = canvas.getContext("2d");
        context.scale(2, 2);
        context.drawImage(image, 0, 0, result.width, result.height);
        return { png: canvas.toDataURL("image/png"), width: result.width, height: result.height, natural: natural.width, adapts };
      } finally { URL.revokeObjectURL(url); }
    } catch (error) {
      return { error: (error && error.message) || "The diagram could not be rendered." };
    }
    """
}
