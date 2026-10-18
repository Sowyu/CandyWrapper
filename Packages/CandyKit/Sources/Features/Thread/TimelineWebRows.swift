import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// `HtmlRenderTimelineRow` (MessagesTimeline.tsx:2957-2971, HtmlRenderFrame.tsx): the agent's page in `px-1`, on the
/// thread's own background, at the server's measured height for this width until the page reports its own.
/// Loading and failure hold the same box. "Open full screen" shows on hover (T3 3105 aba3a6ddc). 8pt under it (`pb-2`).
final class HtmlRenderRowView: TimelineRowView {
    private let frameView = ThreadWebFrameView()
    private let failed = LabelView("", font: TL.font(12))
    private let open = ButtonView(nil, icon: .maximize2, variant: .glass, size: .iconXs)
    private var reference: HtmlRenderReference?
    private var src: URL?
    private var loading: Task<Void, Never>?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(frameView)
        failed.alignment = .center
        failed.lineHeight = 16
        failed.isHidden = true
        addSubview(failed)
        open.iconSize = 14
        open.alphaValue = 0
        open.setAccessibilityLabel("Open full screen")
        _ = TooltipController.attach(to: open, text: "Open full screen", placement: PopupPlacement(side: .left, align: .center, sideOffset: 4))
        open.action = { [weak self] in self?.openFullScreen() }
        addSubview(open)
        frameView.onMessage = { [weak self] in self?.received($0) }
        frameView.onEvicted = { [weak self] in self?.src = nil }
    }

    override func configure(_ item: TimelineItem) {
        super.configure(item)
        guard case .htmlRender(let ref) = item.row.kind else { return }
        if ref.attachmentId != reference?.attachmentId {
            frameView.release()
            src = nil
            failed.isHidden = true
        }
        reference = ref
        failed.text = "Unable to load \(ref.title)"
        load()
        needsLayout = true
    }

    /// Mints the page's URL once per mount, then frames it with the theme in its fragment.
    private func load() {
        guard let ref = reference, !frameView.isLive, loading == nil, window != nil else { return }
        let id = ref.attachmentId
        loading = Task { [weak self] in
            let url = await self?.context.model?.webAssetURL?(id, ref.fileName)
            guard let self, self.reference?.attachmentId == id else { return }
            self.loading = nil
            guard let url else { self.failed.isHidden = false; return }
            self.src = url
            self.show(url)
        }
    }

    private func show(_ url: URL) {
        guard let ref = reference, window != nil else { return }
        let dark = effectiveAppearance.isDark
        let themed = URL(string: url.absoluteString.split(separator: "#", maxSplits: 1)[0] + HtmlRenderTheme(dark: dark).fragment) ?? url
        frameView.activate(.init(src: themed, title: ref.title, dark: dark))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { frameView.release() } else if src != nil, !frameView.isLive, let src { show(src) } else { load() }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loading?.cancel()
        loading = nil
        frameView.release()
        reference = nil
        src = nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        failed.color = TL.c(\.mutedForeground)
        if frameView.isLive { frameView.post(HtmlRenderTheme(dark: effectiveAppearance.isDark).message) }
    }

    private func received(_ data: JSONValue) {
        guard let item else { return }
        if let h = HtmlRenderTheme.contentHeight(data) { context.model?.setWebContentHeight(item.id, h) }
        Self.handle(data, frame: frameView, model: context.model)
    }

    /// `HtmlRenderDocument`'s messages, in the row and the full screen dialog (files/BrowserDocumentFrame.tsx in 3105).
    /// A loaded page learns the app shortcuts it may pass on. A link opens like a chat link, and a passed-on chord
    /// runs its command; both only while the frame has focus and the reader just used it, as T3 checks user activation.
    // ponytail: a live page keeps the shortcut list from its load; repost on ActiveKeymap changes if people edit keybindings with a render open
    static func handle(_ data: JSONValue, frame: ThreadWebFrameView, model: ThreadViewModel?) {
        if HtmlRenderTheme.contentHeight(data) != nil, !frame.shortcutsPosted {
            frame.shortcutsPosted = true
            frame.post(HtmlRenderShortcuts.message())
        } else if let link = HtmlRenderTheme.linkRequest(data) {
            guard frame.userIsActive, let url = SafeExternalURL.parse(link.url) else { return }
            if let open = model?.onOpenWebLink { open(url, link.modified) } else { NSWorkspace.shared.open(url) }
            frame.post(HtmlRenderTheme.result(link.id))
        } else if frame.userIsActive, let image = HtmlRenderTheme.imageRequest(data),
                  let url = URL(string: image.src), let window = frame.window {
            ExpandedImagePreviewView(items: [.init(key: image.src, name: image.name, load: { side in
                if url.scheme?.lowercased() == "data" { return await MarkdownImages.decodeData(image.src, side: side)?.image }
                return await MarkdownImages.download(url, side: side)?.image
            })], index: 0).present(in: window)
        } else if frame.userIsActive, let stroke = HtmlRenderShortcuts.keyDown(data) {
            model?.onFrameShortcut?(stroke)
        }
    }

    /// "Open full screen": a fresh URL (one near expiry is minted again), else T3's "Page unavailable" toast.
    private func openFullScreen() {
        guard let ref = reference else { return }
        let id = ref.attachmentId
        Task { [weak self] in
            let url = await self?.context.model?.webAssetURL?(id, ref.fileName)
            guard let self, let window = self.window, self.reference?.attachmentId == id else { return }
            guard let url else {
                self.context.model?.showError?("Page unavailable", "Reconnect to the environment and try again.")
                return
            }
            let dark = self.effectiveAppearance.isDark
            let themed = URL(string: url.absoluteString.split(separator: "#", maxSplits: 1)[0] + HtmlRenderTheme(dark: dark).fragment) ?? url
            let model = self.context.model
            HtmlRenderDialogView(page: .init(src: themed, title: ref.title, dark: dark)) { data, frame in
                Self.handle(data, frame: frame, model: model)
            }.present(in: window)
        }
    }

    /// `group/html-render` is the frame box, not the row's `pb-2` (HtmlRenderFrame.tsx:95-104).
    override var tracksPointerMoves: Bool { true }
    override func hoverChanged() {
        let inBox = pointer.map { frameView.frame.contains($0) } ?? false
        Self.reveal([open], inBox || focusWithin, duration: 0.15)
    }

    private func frameHeight(_ width: CGFloat) -> CGFloat {
        guard let ref = reference ?? item.flatMap({ if case .htmlRender(let r) = $0.row.kind { r } else { nil } }) else { return HtmlRenderReference.minHeight }
        return ref.frameHeight(width: Double(max(0, width - 8)), contentHeight: item?.ui.webContentHeight)
    }

    override func height(forWidth width: CGFloat) -> CGFloat { frameHeight(width) + 8 }

    override func layout() {
        super.layout()
        let box = NSRect(x: 4, y: 0, width: max(0, bounds.width - 8), height: frameHeight(bounds.width))
        frameView.frame = box
        failed.frame = NSRect(x: box.minX, y: box.midY - 8, width: box.width, height: 16)
        open.frame = NSRect(x: box.maxX - 8 - 24, y: 8, width: 24, height: 24)
    }
}

/// `McpAppTimelineRow` (MessagesTimeline.tsx:2973-2993, McpAppFrame.tsx:73-550): the app's captured document in an
/// opaque-origin frame speaking the MCP Apps bridge. Its tool calls and reads reach its own server through the
/// environment; calls to tools not marked read-only and chat messages ask first. Starts 320 tall, then the
/// app's reported size. An app that asks to close leaves "The {server} app was closed" with Show app.
final class McpAppRowView: TimelineRowView {
    private let frameView = ThreadWebFrameView()
    private let border = FillView()
    private let note = LabelView("", font: TL.font(12))
    private let closedBox = FillView()
    private let closedLabel = LabelView("", font: TL.font(12))
    private let showApp = ButtonView("Show app", variant: .ghost, size: .xs)
    private let expand = ButtonView(nil, icon: .maximize2, variant: .glass, size: .iconXs)
    private var entry: McpAppEntry?
    private var bridge: McpAppHostBridge?
    private var loading: Task<Void, Never>?
    private var navigatedAway = false
    private var toolDefinition: JSONValue?
    private var fullscreen: ThreadMcpFullscreenView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        border.radius = 8
        addSubview(frameView)
        addSubview(border)
        note.alignment = .center
        note.lineHeight = 16
        note.isHidden = true
        addSubview(note)
        closedBox.radius = 8
        addSubview(closedBox)
        closedLabel.lineHeight = 16
        addSubview(closedLabel)
        showApp.action = { [weak self] in
            guard let self, let id = self.item?.id else { return }
            self.navigatedAway = false
            self.context.model?.setAppClosed(id, false)
        }
        addSubview(showApp)
        expand.iconSize = 14
        expand.isHidden = true
        expand.setAccessibilityLabel("Open app full screen")
        _ = TooltipController.attach(to: expand, text: "Open app full screen")
        expand.action = { [weak self] in _ = self?.setDisplayMode("fullscreen", userInitiated: true) }
        addSubview(expand)
        frameView.onMessage = { [weak self] in self?.bridge?.receive($0) }
        frameView.onNavigatedAway = { [weak self] in
            guard let self else { return }
            self.bridge?.dispose()
            self.bridge = nil
            self.navigatedAway = true
            self.expand.isHidden = true
            self.frameView.release()
            self.note.text = "The \(self.entry?.app.server ?? "") app left its page and was stopped"
            self.note.isHidden = false
        }
        frameView.onEvicted = { [weak self] in
            _ = self?.setDisplayMode("inline")
            self?.bridge?.dispose(); self?.bridge = nil
        }
        restyle()
    }

    private var closed: Bool { item?.ui.appClosed ?? false }

    override func configure(_ item: TimelineItem) {
        super.configure(item)
        guard case .mcpApp(let e) = item.row.kind else { return }
        if e.app.attachmentId != entry?.app.attachmentId { teardown(); navigatedAway = false; toolDefinition = nil }
        entry = e
        let isClosed = item.ui.appClosed
        closedBox.isHidden = !isClosed
        closedLabel.isHidden = !isClosed
        showApp.isHidden = !isClosed
        expand.isHidden = isClosed || navigatedAway || fullscreen != nil
        closedLabel.text = "The \(e.app.server) app was closed"
        border.isHidden = isClosed || e.app.prefersBorder != true
        if isClosed { teardown() } else { load() }
        needsLayout = true
    }

    private func teardown() {
        _ = setDisplayMode("inline")
        loading?.cancel()
        loading = nil
        if let bridge { Task { await bridge.teardown() } }
        bridge = nil
        frameView.release()
    }

    private func load() {
        guard let e = entry, !frameView.isLive, loading == nil, !navigatedAway, window != nil, let model = context.model else { return }
        note.isHidden = true
        loading = Task { [weak self] in
            let url = await model.webAssetURL?(e.app.attachmentId, e.app.fileName)
            guard let self, self.entry == e, !Task.isCancelled else { return }
            self.loading = nil
            guard let url else {
                self.note.text = "Unable to load the \(e.app.server) app"
                self.note.isHidden = false
                return
            }
            self.start(e, url)
        }
    }

    private func start(_ e: McpAppEntry, _ url: URL) {
        guard window != nil, let model = context.model, let actions = model.mcpApp else { return }
        let target: [String: JSONValue] = ["threadId": .string(e.sourceThreadId.rawValue), "itemId": .string(e.itemId.rawValue)]
        let conversation = model.projection?.thread.id ?? e.sourceThreadId
        let frame = frameView
        let bridge = McpAppHostBridge(app: e.app, hostVersion: "0.1.0", callbacks: .init(
            post: { [weak frame] in frame?.post($0) },
            hostContext: { [weak self] in self?.hostContext() ?? .object([:]) },
            callTool: { [weak self] name, args in
                var info = target; info["name"] = .string(name)
                let tool = try await Self.unwrap { try await actions.request("mcpApps.toolInfo", .object(info)) }
                guard tool["callable"]?.boolValue == true else { throw McpAppHostBridge.Refusal("This app cannot call that tool.") }
                if tool["readOnly"]?.boolValue != true {
                    let pretty = String(data: (try? JSONEncoder().encode(args)) ?? Data(), encoding: .utf8) ?? "{}"
                    guard await self?.ask("Allow \(e.app.server) to run \(tool["title"]?.stringValue ?? name)?", pretty) == true else {
                        throw McpAppHostBridge.Refusal("Declined by the user.")
                    }
                }
                guard let self, self.window != nil, self.entry == e, self.context.model?.projection?.thread.id == conversation else {
                    throw McpAppHostBridge.Refusal("The app was closed.")
                }
                var input = target; input["name"] = .string(name); input["arguments"] = args
                return try await Self.unwrap { try await actions.request("mcpApps.callTool", .object(input)) }
            },
            readResource: { uri in
                var input = target; input["uri"] = .string(uri)
                return try await Self.unwrap { try await actions.request("mcpApps.readResource", .object(input)) }
            },
            openLink: { [weak frame] url in
                guard frame?.userIsActive == true else { throw McpAppHostBridge.Refusal("Links open only from a click in the app.") }
                guard let u = SafeExternalURL.parse(url) else { throw McpAppHostBridge.Refusal("Only http and https links open.") }
                NSWorkspace.shared.open(u)
            },
            sendMessage: { [weak self] text in
                guard let send = actions.sendMessage else { throw McpAppHostBridge.Refusal("Messages are not available here.") }
                guard await self?.ask("Send this message from \(e.app.server)?", text) == true else { throw McpAppHostBridge.Refusal("Declined by the user.") }
                guard let self, self.window != nil, self.entry == e, self.context.model?.projection?.thread.id == conversation else {
                    throw McpAppHostBridge.Refusal("The app was closed.")
                }
                try await send(text)
            },
            updateModelContext: { content, structured in
                var input = target; input["conversationThreadId"] = .string(conversation.rawValue)
                if let content { input["content"] = content }
                if let structured { input["structuredContent"] = structured }
                _ = try await Self.unwrap { try await actions.request("mcpApps.updateModelContext", .object(input)) }
            },
            onSizeChanged: { [weak self] _, h in
                guard let self, let h, let id = self.item?.id else { return }
                self.context.model?.setWebContentHeight(id, McpAppReference.clamp(h))
            },
            onRequestTeardown: { [weak self] in
                guard let self, let bridge = self.bridge, let id = self.item?.id else { return }
                if self.fullscreen != nil { _ = self.setDisplayMode("inline"); return }
                Task { await bridge.teardown(); self.context.model?.setAppClosed(id, true) }
            }, downloadFiles: { [weak self] files in
                guard let self, await self.ask("Save " + files.map(\.name).joined(separator: ", ") + " from " + e.app.server + "?", "") else {
                    throw McpAppHostBridge.Refusal("Declined by the user.")
                }
                for file in files {
                    guard self.window != nil, self.entry == e, self.context.model?.projection?.thread.id == conversation else {
                        throw McpAppHostBridge.Refusal("The app was closed.")
                    }
                    var bytes = file.bytes
                    if let uri = file.uri {
                        var input = target; input["uri"] = .string(uri)
                        let reply = try await actions.request("mcpApps.readResource", .object(input))
                        bytes = reply["contents"]?.arrayValue?.first.flatMap(ThreadMcpAppDownload.resourceBytes)
                    }
                    guard let bytes else { throw McpAppHostBridge.Refusal(file.name + " has no contents.") }
                    guard bytes.count <= ThreadMcpAppDownload.maximumBytes else { throw McpAppHostBridge.Refusal(file.name + " is too large to save.") }
                    guard let window = self.window else { throw McpAppHostBridge.Refusal("The app was closed.") }
                    let panel = NSSavePanel(); panel.nameFieldStringValue = file.name
                    let target: URL? = await withCheckedContinuation { done in
                        panel.beginSheetModal(for: window) { done.resume(returning: $0 == .OK ? panel.url : nil) }
                    }
                    guard let target else { throw McpAppHostBridge.Refusal("Declined by the user.") }
                    try bytes.write(to: target, options: .atomic)
                }
            }, requestDisplayMode: { [weak self] mode in
                guard let self else { return "inline" }
                return self.setDisplayMode(mode, userInitiated: self.window?.isKeyWindow == true && self.frameView.userIsActive)
            }))
        self.bridge = bridge
        frameView.activate(.init(src: url, title: "\(e.app.server) app", allow: e.app.allowAttribute, dark: effectiveAppearance.isDark))
        // The tool's definition (for `toolInfo` at initialize) and the stored call (arguments and result).
        Task { [weak self] in
            var info = target; info["name"] = .string(e.app.tool)
            if let tool = try? await actions.request("mcpApps.toolInfo", .object(info)), let def = tool["tool"] { self?.toolDefinition = def }
            guard let item = await actions.turnItem(e.sourceThreadId, e.itemId), self?.bridge === bridge else { return }
            bridge.setToolCall(arguments: item["input"] ?? .object([:]), result: item["output"]?["result"])
        }
    }

    // McpAppFrame.tsx:341-353 accepts unsolicited expansion. Keep background previews inline here.
    func setDisplayMode(_ mode: String, userInitiated: Bool = false) -> String {
        if mode == "inline" {
            if let fullscreen {
                addSubview(frameView, positioned: .below, relativeTo: border)
                fullscreen.removeFromSuperview(); self.fullscreen = nil
                frameView.webView?.forwardsScroll = true
                frameView.budgeted = true
                if frameView.isLive { ThreadWebFrameBudget.add(frameView) }
                needsLayout = true
            }
        } else if mode == "fullscreen", userInitiated, frameView.isLive, fullscreen == nil, let content = window?.contentView,
                  context.model?.projection?.runtimeRequests.contains(where: { $0.status == "pending" }) != true,
                  !content.subviews.contains(where: { $0 is ModalHost || $0 is ThreadMcpFullscreenView }), window?.attachedSheet == nil {
            let host = ThreadMcpFullscreenView(content: frameView)
            host.frame = content.bounds; host.autoresizingMask = [.width, .height]
            host.onClose = { [weak self] in _ = self?.setDisplayMode("inline") }
            // A visible fullscreen app must not be evicted by new inline results.
            frameView.budgeted = false
            frameView.webView?.forwardsScroll = false
            fullscreen = host; content.addSubview(host)
        }
        expand.isHidden = closed || navigatedAway || fullscreen != nil
        bridge?.updateHostContext()
        return fullscreen == nil ? "inline" : "fullscreen"
    }

    /// The RPC's failure message reaches the app; anything else reads "Request failed.".
    static func unwrap(_ run: () async throws -> JSONValue) async throws -> JSONValue {
        do { return try await run() } catch let refusal as McpAppHostBridge.Refusal { throw refusal } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            throw McpAppHostBridge.Refusal(message.isEmpty ? "Request failed." : message)
        }
    }

    /// `requestConfirmDialog`: Cancel or Allow over the window.
    private func ask(_ title: String, _ detail: String) async -> Bool {
        guard let window else { return false }
        return await withCheckedContinuation { done in
            let dialog = DialogView(kind: .alertDialog, title: title, message: detail)
            let cancel = ButtonView("Cancel", variant: .outline)
            let ok = ButtonView("Allow", variant: .default)
            dialog.footerButtons = [cancel, ok]
            let host = ModalHost.present(dialog, in: window)
            var answered = false
            let finish: (Bool) -> Void = { value in if !answered { answered = true; done.resume(returning: value) } }
            host.onDismiss = { finish(false) }
            cancel.action = { [weak host] in finish(false); host?.close() }
            ok.action = { [weak host] in finish(true); host?.close() }
        }
    }

    /// `hostContext` (McpAppFrame.tsx:267-296).
    private func hostContext() -> JSONValue {
        let theme = HtmlRenderTheme(dark: effectiveAppearance.isDark)
        var o: [String: JSONValue] = [
            "theme": .string(theme.dark ? "dark" : "light"),
            "styles": .object(["variables": .object(McpAppHostBridge.styleVariables(theme.variables).mapValues { .string($0) })]),
            "displayMode": .string(fullscreen == nil ? "inline" : "fullscreen"),
            "availableDisplayModes": .array([.string("inline"), .string("fullscreen")]),
            "containerDimensions": .object(["width": .number(Double(fullscreen.map { max(0, $0.bounds.width - 16) } ?? max(0, bounds.width - 8)).rounded()), "maxHeight": .number(fullscreen.map { Double(max(0, $0.bounds.height - 56)) } ?? McpAppReference.maxHeight)]),
            "platform": .string("desktop"),
            "locale": .string(Locale.current.identifier.replacingOccurrences(of: "_", with: "-")),
            "timeZone": .string(TimeZone.current.identifier),
            "userAgent": .string("t3-code/0.1.0"),
            "deviceCapabilities": .object(["touch": .bool(false), "hover": .bool(true)]),
            "safeAreaInsets": .object(["top": .number(0), "right": .number(0), "bottom": .number(0), "left": .number(0)]),
        ]
        if let toolDefinition { o["toolInfo"] = .object(["tool": toolDefinition]) }
        return .object(o)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { teardown() } else if !closed { load() }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        teardown()
        entry = nil
        navigatedAway = false
        note.isHidden = true
        expand.isHidden = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
        bridge?.updateHostContext()
    }

    private func restyle() {
        border.border = TL.c(\.border)
        closedBox.border = TL.c(\.border)
        note.color = TL.c(\.mutedForeground)
        closedLabel.color = TL.c(\.mutedForeground)
    }

    private var boxHeight: CGFloat {
        closed ? 1 + 8 + 24 + 8 + 1 : CGFloat(item?.ui.webContentHeight ?? McpAppReference.defaultHeight)
    }

    override func height(forWidth width: CGFloat) -> CGFloat { boxHeight + 8 }

    override func layout() {
        super.layout()
        let box = NSRect(x: 4, y: 0, width: max(0, bounds.width - 8), height: boxHeight)
        if fullscreen == nil { frameView.frame = box }
        border.frame = box
        expand.frame = NSRect(x: max(4, box.maxX - 32), y: 8, width: 24, height: 24)
        note.frame = NSRect(x: box.minX, y: box.midY - 8, width: box.width, height: 16)
        // `rounded-lg border px-3 py-2 text-xs`, Show app at the end.
        closedBox.frame = box
        let sw = showApp.intrinsicContentSize.width
        showApp.frame = NSRect(x: box.maxX - 12 - sw, y: box.midY - 12, width: sw, height: 24)
        closedLabel.frame = NSRect(x: box.minX + 13, y: box.midY - 8, width: max(0, showApp.frame.minX - box.minX - 21), height: 16)
        bridge?.updateHostContext()
    }
}

/// Full-window host keeps the same app document alive until it closes or its row is recycled.
private final class ThreadMcpFullscreenView: DSView {
    let content: NSView
    var onClose: (() -> Void)?
    private let close = ButtonView("Exit full screen", icon: .minimize2, variant: .outline, size: .sm)
    init(content: NSView) {
        self.content = content
        super.init(frame: .zero)
        addSubview(content); addSubview(close)
        close.action = { [weak self] in self?.onClose?() }
    }
    override func updateLayer() { layer?.backgroundColor = Themed.color(\.background).cgColor(in: self) }
    override func cancelOperation(_ sender: Any?) { onClose?() }
    override func layout() {
        super.layout()
        close.frame = NSRect(x: max(8, bounds.width - 160), y: 8, width: 152, height: 32)
        content.frame = NSRect(x: 8, y: 48, width: max(0, bounds.width - 16), height: max(0, bounds.height - 56))
    }
}
