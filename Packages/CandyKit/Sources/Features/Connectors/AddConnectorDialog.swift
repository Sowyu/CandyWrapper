import AgentConfig
import AppKit
import DesignSystem

/// The Add server dialog: a name, a URL or a command, an optional token and the agents that get it.
enum AddConnectorDialog {
    static func make() -> (DialogView, AddConnectorForm) {
        let dialog = DialogView(title: "Add an MCP server", message: "It goes into each agent's own config on the machines you picked.")
        dialog.maxWidth = 480
        let form = AddConnectorForm()
        dialog.panelContent = [form]
        let cancel = ButtonView("Cancel", variant: .outline)
        let add = ButtonView("Add server")
        cancel.action = { [weak form] in form?.onCancel?() }
        add.action = { [weak form] in form?.submit() }
        dialog.footerButtons = [cancel, add]
        dialog.onClose = { [weak form] in form?.onCancel?() }
        return (dialog, form)
    }
}

final class AddConnectorForm: DSView {
    let name = InputView(placeholder: "github")
    let target = InputView(placeholder: "https://example.com/mcp or npx -y some-mcp-server")
    let token = SecureInputView(placeholder: "Optional")
    let envVar = InputView(placeholder: "Optional, like GITHUB_TOKEN")
    private let claude = CheckboxView(value: .on)
    private let codex = CheckboxView(value: .on)
    private let labels = ["Name", "URL or command", "Bearer token for Claude", "Token variable"].map {
        LabelView($0, font: DSFont.ui(12, weight: .medium), color: Themed.color(\.foreground))
    }
    private let claudeLabel = LabelView("Claude", font: DSFont.ui(13), color: Themed.color(\.foreground))
    private let codexLabel = LabelView("Codex", font: DSFont.ui(13), color: Themed.color(\.foreground))
    private let hint = TextBlockView("Claude keeps the token in ~/.claude.json. Codex reads it from the variable you name, so set that variable where T3 runs. With only a variable, Claude reads it too.",
                                     font: DSFont.ui(11), lineHeight: 16, color: Themed.color(\.mutedForeground))
    private let errorText = TextBlockView("", font: DSFont.ui(12), lineHeight: 16, color: Themed.color(\.destructive))

    var onSubmit: ((NewMCPServer) -> Void)?
    var onCancel: (() -> Void)?
    var error: String? {
        didSet { errorText.text = error ?? ""; errorText.isHidden = error == nil; needsLayout = true; superview?.needsLayout = true }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        name.setAccessibilityLabel("Name")
        target.setAccessibilityLabel("URL or command")
        envVar.setAccessibilityLabel("Token variable")
        token.setAccessibilityLabel("Bearer token for Claude")
        claude.setAccessibilityLabel("Claude")
        codex.setAccessibilityLabel("Codex")
        errorText.isHidden = true
        for v in labels as [NSView] + [name, target, token, envVar, claude, claudeLabel, codex, codexLabel, hint, errorText] { addSubview(v) }
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func submit() {
        let n = name.text.trimmingCharacters(in: .whitespaces)
        let t = target.text.trimmingCharacters(in: .whitespaces)
        let agents = [(ConfigAgent.claude, claude), (.codex, codex)].filter { $0.1.value == .on }.map(\.0)
        guard !n.isEmpty else { error = "Give it a name."; return }
        guard n.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "-_".unicodeScalars.contains($0) }) else {
            error = "A name uses only letters, digits, - and _."; return
        }
        guard !t.isEmpty else { error = "Add its URL or the command that starts it."; return }
        guard !agents.isEmpty else { error = "Pick Claude, Codex or both."; return }
        let v = envVar.text.trimmingCharacters(in: .whitespaces)
        let secret = token.text.trimmingCharacters(in: .whitespaces)
        var server = NewMCPServer(name: n, agents: agents, bearerToken: secret.isEmpty ? nil : secret, tokenEnvVar: v.isEmpty ? nil : v)
        if t.hasPrefix("http://") || t.hasPrefix("https://") {
            server.url = t
        } else {
            let words = Self.split(t)
            server.command = words.first
            server.args = Array(words.dropFirst())
        }
        onSubmit?(server)
    }

    /// Splits a command line on spaces, keeping quoted parts together.
    static func split(_ line: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var started = false
        for c in line {
            if let q = quote {
                if c == q { quote = nil } else { current.append(c) }
            } else if c == "\"" || c == "'" {
                quote = c; started = true
            } else if c == " " {
                if started || !current.isEmpty { words.append(current); current = ""; started = false }
            } else {
                current.append(c)
            }
        }
        if started || !current.isEmpty { words.append(current) }
        return words
    }

    private func frames(_ width: CGFloat, place: Bool) -> CGFloat {
        var y: CGFloat = 0
        let fields: [NSView] = [name, target, token, envVar]
        for (label, field) in zip(labels, fields) {
            if place { label.frame = NSRect(x: 0, y: y, width: width, height: 16) }
            y += 22
            if place { field.frame = NSRect(x: 0, y: y, width: width, height: 32) }
            y += 32 + 12
        }
        if place {
            claude.frame = NSRect(x: 0, y: y + 2, width: 16, height: 16)
            claudeLabel.frame = NSRect(x: 24, y: y, width: 60, height: 20)
            codex.frame = NSRect(x: 96, y: y + 2, width: 16, height: 16)
            codexLabel.frame = NSRect(x: 120, y: y, width: 60, height: 20)
        }
        y += 20 + 12
        let hh = hint.height(forWidth: width)
        if place { hint.frame = NSRect(x: 0, y: y, width: width, height: hh) }
        y += hh
        if !errorText.isHidden {
            y += 8
            let eh = errorText.height(forWidth: width)
            if place { errorText.frame = NSRect(x: 0, y: y, width: width, height: eh) }
            y += eh
        }
        return y
    }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: frames(max(bounds.width, 400), place: false)) }
    func height(forWidth width: CGFloat) -> CGFloat { frames(width, place: false) }
    override func layout() { super.layout(); _ = frames(bounds.width, place: true) }
}
