import AppKit
import DesignSystem
import T3Protocol

/// ProviderAuthTerminal.tsx:20-39 uses an absolute UTF-16 offset over a rolling
/// 16 KiB output window. A gap or rewind resets the terminal, never duplicates output.
enum ComposerProviderAuthOutput {
    static func delta(output: String, offset: Int?, written: Int) -> (reset: Bool, text: String, offset: Int) {
        let source = output as NSString, next = offset ?? output.utf16.count
        let delta = next - written
        if delta == 0 { return (false, "", next) }
        if delta > 0 && delta <= source.length { return (false, source.substring(from: source.length - delta), next) }
        return (true, output, next)
    }
}

/// Visible only during provider setup. The existing terminal owns drawing and input;
/// this view owns only the provider-auth stream and its serialized response queue.
final class ComposerProviderAuthTerminal: DSView {
    private let context: SettingsPageContext
    private let environment: String
    private let instance: String
    private var state: JSONValue = .null
    private var subscription: Task<Void, Never>?
    private var sending: Task<Void, Never>?
    private var queue: [JSONValue] = []
    private var terminal: TerminalSurfaceView?
    private var written = 0
    private var interactionKey = ""
    private let status = LabelView("Checking sign-in…", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    private let start = ButtonView("Sign in", variant: .outline, size: .sm)
    private let cancel = ButtonView("Cancel sign-in", variant: .ghost, size: .sm)
    private let open = ButtonView("Open browser", variant: .outline, size: .sm)
    private let methods = SelectView(options: [], placeholder: "Sign-in method", size: .compact)
    init(context: SettingsPageContext, environment: String, instance: String) {
        self.context = context; self.environment = environment; self.instance = instance
        super.init(frame: .zero)
        [status, start, cancel, open, methods].forEach(addSubview)
        open.isHidden = true; cancel.isHidden = true; methods.isHidden = true
        start.action = { [weak self] in self?.startAuth() }
        cancel.action = { [weak self] in self?.cancelAuth() }
        open.action = { [weak self] in self?.openBrowser() }
    }
    override var intrinsicContentSize: NSSize { NSSize(width: 620, height: 312) }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, subscription == nil {
            subscription = context.subscribeProviderAuth?(environment, instance) { [weak self] in self?.apply($0) }
        } else if window == nil { close() }
    }
    func close() {
        subscription?.cancel(); subscription = nil
        sending?.cancel(); sending = nil; queue = []
        terminal?.removeFromSuperview(); terminal = nil; written = 0; interactionKey = ""
    }
    private func command(_ method: String, _ input: [String: JSONValue]) {
        guard let request = context.request else { return }
        start.isEnabled = false
        Task { [weak self] in
            guard let self else { return }
            do { let next = try await request(environment, method, .object(input)); if self.window != nil { self.apply(next) } }
            catch { self.status.text = error.localizedDescription }
            self.start.isEnabled = true
        }
    }
    private func startAuth() {
        var input: [String: JSONValue] = ["instanceId": .string(instance)]
        if let index = methods.selectedIndex, let list = state["methods"]?.arrayValue, index < list.count { input["methodId"] = list[index]["id"] }
        command("provider.auth.start", input)
    }
    private func cancelAuth() {
        guard let flow = state["flowId"]?.stringValue else { return }
        command("provider.auth.cancel", ["instanceId": .string(instance), "flowId": .string(flow)])
    }
    private func openBrowser() {
        let interaction = state["interaction"]
        guard let text = interaction?["url"]?.stringValue ?? state["authorizationUrl"]?.stringValue,
              let url = URL(string: text), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return }
        if interaction?["requiresConsent"]?.boolValue == true {
            guard let request = context.request, let payload = response(["type": .string("browser"), "action": .string("accept")]) else { return }
            Task { [weak self] in
                guard let self else { return }
                do { self.apply(try await request(environment, "provider.auth.respond", payload)); self.context.openURL?(url) }
                catch { self.status.text = error.localizedDescription }
            }
        } else { context.openURL?(url) }
    }
    private func response(_ body: [String: JSONValue]) -> JSONValue? {
        guard let flow = state["flowId"]?.stringValue, let interaction = state["interaction"]?["id"]?.stringValue else { return nil }
        return .object(["instanceId": .string(instance), "flowId": .string(flow), "interactionId": .string(interaction), "response": .object(body)])
    }
    private func enqueue(_ data: String, size: (Int, Int)? = nil) {
        // Chunk at character boundaries to keep UTF-16 pairs and terminal escape bytes intact.
        var chunks: [String] = [], chunk = ""
        for c in data {
            if chunk.utf16.count + String(c).utf16.count > 4096 { chunks.append(chunk); chunk = "" }
            chunk.append(c)
        }
        if !chunk.isEmpty || chunks.isEmpty { chunks.append(chunk) }
        for chunk in chunks {
            var body: [String: JSONValue] = ["type": .string("terminal"), "data": .string(chunk)]
            if let (cols, rows) = size { body["size"] = .object(["cols": .number(Double(max(1, min(500, cols)))), "rows": .number(Double(max(1, min(200, rows))))]) }
            if let payload = response(body) { queue.append(payload) }
        }
        guard sending == nil, let request = context.request else { return }
        sending = Task { [weak self] in
            guard let self else { return }
            defer { self.sending = nil }
            while !self.queue.isEmpty, !Task.isCancelled {
                let payload = self.queue.removeFirst()
                do { _ = try await request(environment, "provider.auth.respond", payload) }
                catch { self.queue = []; self.status.text = error.localizedDescription; return }
            }
        }
    }
    private func apply(_ next: JSONValue) {
        state = next
        let phase = next["phase"]?.stringValue ?? "idle", interaction = next["interaction"]
        let active = ["starting", "waiting", "verifying"].contains(phase)
        start.isHidden = active; cancel.isHidden = !active
        status.text = next["message"]?.stringValue ?? (phase == "succeeded" ? "Signed in." : active ? "Complete sign-in below." : "Sign in on this machine.")
        let entries = next["methods"]?.arrayValue ?? []
        methods.options = entries.map { $0["name"]?.stringValue ?? $0["id"]?.stringValue ?? "" }
        methods.isHidden = entries.count < 2 || active
        if methods.selectedIndex == nil && !entries.isEmpty { methods.selectedIndex = 0 }
        open.isHidden = interaction?["url"]?.stringValue == nil && next["authorizationUrl"]?.stringValue == nil
        if interaction?["type"]?.stringValue == "terminal" {
            let key = (next["flowId"]?.stringValue ?? "") + ":" + (interaction?["id"]?.stringValue ?? "")
            if key != interactionKey {
                terminal?.removeFromSuperview()
                let terminal = TerminalSurfaceView()
                terminal.terminal.font = DSFont.mono(13)
                terminal.onInput = { [weak self] in self?.enqueue($0) }
                terminal.onResize = { [weak self] cols, rows in self?.enqueue("", size: (cols, rows)) }
                terminal.onLink = { [weak self] text in if let url = URL(string: text), ["http", "https"].contains(url.scheme ?? "") { self?.context.openURL?(url) } }
                terminal.setAccessibilityLabel("Provider sign-in terminal")
                self.terminal = terminal; addSubview(terminal); interactionKey = key; written = 0
            }
            let delta = ComposerProviderAuthOutput.delta(output: interaction?["output"]?.stringValue ?? "", offset: interaction?["outputOffset"]?.intValue, written: written)
            if delta.reset { terminal?.apply(.reset(delta.text)) } else if !delta.text.isEmpty { terminal?.apply(.write(delta.text)) }
            written = delta.offset
        } else { terminal?.removeFromSuperview(); terminal = nil; written = 0; interactionKey = "" }
        needsLayout = true
    }
    override func layout() {
        super.layout()
        status.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 20)
        terminal?.frame = NSRect(x: 0, y: 28, width: bounds.width, height: 256)
        methods.frame = NSRect(x: 0, y: 280, width: 180, height: 28)
        start.frame = NSRect(x: bounds.width - 100, y: 280, width: 100, height: 28)
        cancel.frame = start.frame
        open.frame = NSRect(x: bounds.width - 232, y: 280, width: 124, height: 28)
    }
}
