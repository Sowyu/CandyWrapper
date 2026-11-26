import AppKit
import DesignSystem
import T3Protocol

/// Which MCP sign-in notices are answered (5258 client-runtime threadCommands.ts:205-234). A sign-in records when
/// the server said it was signed in; a notice raised before that reads "Signed in", a newer one asks again.
public enum McpSignIn {
    public static func key(_ threadId: ThreadId, _ server: String) -> String { threadId.rawValue + "\u{0}" + server }

    public static func signedIn(noticeAt: Date?, signedInAt: Date?) -> Bool {
        guard let signedInAt else { return false }
        return (noticeAt ?? .distantPast) <= signedInAt
    }
}

/// "Sign in to {server}" (5258 McpSignInAction.tsx:117-213): the agent keeps the credential; the user approves in a
/// browser, then pastes back the address it lands on, often a localhost page on another machine. `start` answers
/// the page to approve on, nil when the server is already signed in, or throws a message; `complete` takes the
/// pasted address. Results of a closed or restarted attempt change nothing.
@MainActor
public final class McpSignInDialog: DialogView {
    public enum Phase: Equatable {
        case starting
        case ready(String)
        case finishing(String)
        case failed(url: String?, message: String)

        var url: String? {
            switch self {
            case .starting: nil
            case .ready(let url), .finishing(let url): url
            case .failed(let url, _): url
            }
        }
    }

    public struct Failure: Error { public var message: String; public init(_ message: String) { self.message = message } }

    public let server: String
    public private(set) var phase: Phase = .starting { didSet { render() } }
    /// Starts the sign-in: the page to open, or nil when the server is already signed in.
    public var start: (@MainActor () async throws -> String?)?
    public var complete: (@MainActor (String) async throws -> Void)?
    /// The sign-in finished: the caller closes the dialog and shows "Signed in to {server}".
    public var onSignedIn: (@MainActor () -> Void)?
    /// Opens the sign-in page in the browser.
    public var openURL: (@MainActor (String) -> Void)?

    private let body = McpSignInBody()
    private let cancel = ButtonView("Cancel", variant: .outline)
    private let retry = ButtonView("Try again")
    private let finishButton = ButtonView("Finish sign-in")
    private var attempt = 0

    public init(server: String) {
        self.server = server
        super.init(title: "Sign in to \(server)",
                   message: "Approve access in your browser. It then opens a page that may not load: copy that page's address and paste it here.")
        maxWidth = 512 // `max-w-lg`
        footerVariant = .bare
        panelContent = [body]
        cancel.action = { [weak self] in self?.close() }
        retry.action = { [weak self] in self?.begin() }
        finishButton.action = { [weak self] in self?.finish() }
        body.address.onSubmit = { [weak self] in self?.finish() }
        body.address.onChange = { [weak self] _ in self?.render() }
        body.open.action = { [weak self] in if let url = self?.phase.url { self?.openURL?(url) } }
        body.copy.action = { [weak self] in
            guard let self, let url = self.phase.url else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url, forType: .string)
            self.body.showCopied()
        }
        render()
    }

    /// Cancel: a result that lands later changes nothing.
    public func close() {
        cancelPending()
        onClose?()
    }

    /// Escape or the backdrop closed the dialog: a result that lands later changes nothing.
    public func cancelPending() { attempt += 1 }

    public func begin() {
        attempt += 1
        let current = attempt
        body.address.text = ""
        phase = .starting
        Task { [weak self] in
            guard let self, let start = self.start else { return }
            do {
                let url = try await start()
                guard current == self.attempt else { return }
                if let url { self.phase = .ready(url) } else { self.done() }
            } catch {
                guard current == self.attempt else { return }
                self.phase = .failed(url: nil, message: (error as? Failure)?.message ?? error.localizedDescription)
            }
        }
    }

    private func finish() {
        let pasted = body.address.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pasted.isEmpty, let url = phase.url, phase != .finishing(url) else { return }
        let current = attempt
        phase = .finishing(url)
        Task { [weak self] in
            guard let self, let complete = self.complete else { return }
            do {
                try await complete(pasted)
                guard current == self.attempt else { return }
                self.done()
            } catch {
                guard current == self.attempt else { return }
                self.phase = .failed(url: url, message: (error as? Failure)?.message ?? error.localizedDescription)
            }
        }
    }

    private func done() {
        attempt += 1
        onSignedIn?()
    }

    private func render() {
        body.phase = phase
        let url = phase.url
        var retrying = false
        if case .failed = phase, url == nil { retrying = true }
        let buttons = [cancel, retrying ? retry : finishButton]
        if footerButtons != buttons { footerButtons = buttons }
        let finishing = url.map { phase == .finishing($0) } ?? false
        finishButton.isEnabled = url != nil && !finishing && !body.address.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        body.address.isEnabled = !finishing
        needsLayout = true
        superview?.needsLayout = true
    }
}

/// The dialog's panel (McpSignInAction.tsx:142-187): "Starting the sign-in…", or the page's buttons (`flex flex-wrap
/// gap-2`, outline sm and ghost sm) above the labeled address field (`grid gap-1.5 text-sm`) in a `grid gap-4`, then
/// the failure in `mt-3 text-sm text-destructive-foreground`.
@MainActor
final class McpSignInBody: DSView {
    let open = ButtonView("Open sign-in page", icon: .externalLink, variant: .outline, size: .sm)
    let copy = ButtonView("Copy link", icon: .copy, variant: .ghost, size: .sm)
    let address = InputView()
    private let starting = TextBlockView()
    private let label = TextBlockView()
    private let error = TextBlockView()
    private var copiedReset: DispatchWorkItem?

    var phase: McpSignInDialog.Phase = .starting { didSet { update() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        starting.text = "Starting the sign-in…"
        label.text = "Address of the page your browser opened"
        for text in [starting, label, error] { text.font = DSFont.ui(14); text.lineHeight = 20 }
        starting.color = Themed.color(\.mutedForeground)
        label.color = Themed.color(\.foreground)
        error.color = Themed.color(\.destructiveForeground)
        // Browsers can hide `http://`, which the environment adds back. ponytail: no 16,384 character cap
        // (`maxLength`), the server rejects a longer address; add one when InputView grows a limit.
        [starting, open, copy, label, address, error].forEach { addSubview($0) }
        update()
    }
    required init?(coder: NSCoder) { fatalError() }

    func showCopied() {
        copy.icon = .check
        copiedReset?.cancel()
        let reset = DispatchWorkItem { [weak self] in self?.copy.icon = .copy }
        copiedReset = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: reset)
    }

    private var inputHeight: CGFloat { address.intrinsicContentSize.height }

    private var message: String? { if case .failed(_, let message) = phase { message } else { nil } }

    private func update() {
        let form = phase.url != nil
        starting.isHidden = phase != .starting
        [open, copy, label, address].forEach { $0.isHidden = !form }
        error.text = message ?? ""
        error.isHidden = message == nil
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func heights(_ w: CGFloat) -> (starting: CGFloat, form: CGFloat, error: CGFloat) {
        let s = phase == .starting ? starting.height(forWidth: w) : 0
        let f = phase.url != nil ? 28 + 16 + label.height(forWidth: w) + 6 + inputHeight : 0
        let e = message.map { _ in (s + f > 0 ? 12 : 0) + error.height(forWidth: w) } ?? 0
        return (s, f, e)
    }

    override var intrinsicContentSize: NSSize {
        let h = heights(bounds.width > 0 ? bounds.width : 464)
        return NSSize(width: NSView.noIntrinsicMetric, height: h.starting + h.form + h.error)
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = heights(w)
        starting.frame = NSRect(x: 0, y: 0, width: w, height: h.starting)
        var y = h.starting
        if phase.url != nil {
            let ow = open.intrinsicContentSize.width
            open.frame = NSRect(x: 0, y: y, width: ow, height: 28)
            copy.frame = NSRect(x: ow + 8, y: y, width: copy.intrinsicContentSize.width, height: 28)
            y += 28 + 16
            let lh = label.height(forWidth: w)
            label.frame = NSRect(x: 0, y: y, width: w, height: lh)
            address.frame = NSRect(x: 0, y: y + lh + 6, width: w, height: inputHeight)
            y += lh + 6 + inputHeight
        }
        error.frame = NSRect(x: 0, y: y + (y > 0 ? 12 : 0), width: w, height: error.height(forWidth: w))
    }
}
